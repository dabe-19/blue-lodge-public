"""Dynamic Hardware-Aware Multi-Source Model Curator.

Searches Hugging Face (default) — plus optional opt-in hubs only when explicitly enabled
(e.g. MODEL_HUB_ENABLE_MODELSCOPE=1) — across flagship open model families (`gemma4`, `qwen`,
`nemo`, `inkling`, `lfm`, plus custom families), evaluates real GGUF fit against THIS node's
live GPU VRAM & RAM (`hw.probe()` + `fit.estimate()`), and surfaces matching community GGUF
LoRA/SVD adapters (e.g. `harness-hub`).
"""

from __future__ import annotations

import re
from typing import Any

from . import fit as fitmod
from . import gguf
from .common import HubError, opt_in_enabled
from .hw import probe
from .providers import get_provider

DEFAULT_FAMILIES = ("gemma4", "qwen", "nemo", "inkling")

FAMILY_QUERIES: dict[str, dict[str, Any]] = {
    "gemma4": {
        "label": "Google Gemma 4",
        "queries": ("gemma-4 GGUF", "gemma 4 it GGUF"),
        "exclude_rx": re.compile(r"(?i)(abliterat|heretic|uncensored|asr|whisper|embed|rerank|vision-only)"),
    },
    "qwen": {
        "label": "Qwen 3.x / 3.8",
        "queries": ("Qwen3.8 GGUF", "Qwen3.6 GGUF", "Qwen3.5 GGUF"),
        "exclude_rx": re.compile(r"(?i)(abliterat|heretic|uncensored|asr|whisper|embed|rerank|tts|vl-ocr)"),
    },
    "nemo": {
        "label": "NVIDIA Nemotron / Nemo",
        "queries": ("Nemotron-3.5 GGUF", "Nemotron GGUF"),
        "exclude_rx": re.compile(r"(?i)(abliterat|heretic|asr|streaming|embed|rerank|parse|guard|reward)"),
    },
    "inkling": {
        "label": "Inkling",
        "queries": ("Inkling GGUF",),
        "exclude_rx": re.compile(r"(?i)(abliterat|heretic|uncensored|asr|embed)"),
    },
    "lfm": {
        "label": "LiquidAI LFM (Edge / MoE)",
        "queries": ("LFM3 GGUF", "LFM2.5 GGUF"),
        "exclude_rx": re.compile(r"(?i)(abliterat|heretic|asr|embed)"),
    },
}

TRUSTED_ORGS = ("unsloth", "ggml-org", "bartowski", "nvidia", "google", "qwen", "liquidai", "lmstudio-community", "ista-daslab")
VERDICT_ORDER = {"fits_gpu": 0, "partial_offload": 1, "cpu_only": 2, "does_not_fit": 3}


def _repo_priority(row: dict[str, Any]) -> tuple[int, int]:
    org = (row.get("repo", "").split("/", 1)[0] or "").lower()
    trust_rank = TRUSTED_ORGS.index(org) if org in TRUSTED_ORGS else 99
    return (0 if trust_rank < 99 else 1, trust_rank, -(row.get("downloads") or 0))


def _discover_community_adapters(family_key: str, repo_name: str, hf_prov) -> list[dict[str, Any]]:
    """Discover matching community GGUF LoRA/SVD adapters (e.g. harness-hub) for a model repo."""
    stem = repo_name.split("/")[-1]
    stem = re.sub(r"(?i)-gguf$", "", stem)
    # Match e.g. Qwen3.8-27B, LFM2.5-24B-A2B, LFM3-1.7B, gemma-4-31B
    m = re.match(r"^([A-Za-z0-9._-]+-\d+(?:\.\d+)?[bB](?:-A\d+[bB])?)", stem)
    query_stem = m.group(1) if m else stem[:24]
    if len(query_stem) < 4:
        return []
    try:
        hits = hf_prov.search(f"harness-hub {query_stem}", limit=6, gguf_only=True)
    except Exception:
        return []
    out = []
    for h in hits:
        rid = h.get("repo") or ""
        if "adapter" in rid.lower() or "lora" in rid.lower() or rid.lower().startswith("harness-hub/"):
            if query_stem.lower() in rid.lower():
                out.append({"hf_repo": rid, "downloads": h.get("downloads", 0), "likes": h.get("likes", 0)})
    return out[:4]


def _evaluate_candidate(prov, repo: str, hw: dict[str, Any], ctx: int, kv: str) -> dict[str, Any] | None:
    rev = "master" if prov.name == "modelscope" else "main"
    try:
        info = prov.inspect(repo, rev)
    except HubError:
        return None
    if not info.get("quants"):
        return None

    # Pick a representative quant to read remote GGUF dimensions (fast 8 KiB range request)
    quant_sizes: list[tuple[str, list[dict[str, Any]], int]] = []
    for q, paths in info["quants"].items():
        # Filter to actual model files matching q
        mf = [f for f in info["files"] if f["kind"] == "model" and f.get("quant") == q]
        if not mf:
            continue
        # Handle sharded vs single
        shards = [f for f in mf if f.get("shard")]
        if shards:
            tot = shards[0]["shard"][1]
            stem = shards[0]["path"].rsplit("-00", 1)[0]
            grp = sorted([f for f in shards if f["path"].startswith(stem)], key=lambda x: x["path"])
            if len(grp) != tot:
                continue
            mf = grp
        else:
            mf = [sorted(mf, key=lambda x: len(x["path"]))[0]]
        quant_sizes.append((q, mf, sum(f["size"] for f in mf)))

    if not quant_sizes:
        return None
    quant_sizes.sort(key=lambda x: x[2])

    try:
        sample_url = prov.file_url(info["repo"], info["revision"], quant_sizes[0][1][0]["path"])
        dims = gguf.model_dims(gguf.read_remote(sample_url, token=prov.token()))
    except Exception:
        return None

    evaluated = []
    for q, mf, sz in quant_sizes:
        est = fitmod.estimate(dims, sz, hw, ctx=ctx, kv_type=kv)
        evaluated.append({
            "quant": q,
            "size_gib": round(sz / (1 << 30), 2),
            "verdict": est["verdict"],
            "max_ctx": est.get("max_ctx"),
            "n_gpu_layers": est.get("n_gpu_layers"),
            "need_mb": est.get("need_mb"),
        })

    # Choose highest-quality (largest) quant that fits completely on GPU, else best partial_offload
    evaluated.sort(key=lambda x: (VERDICT_ORDER.get(x["verdict"], 9), -x["size_gib"]))
    best = evaluated[0]
    if best["verdict"] == "does_not_fit":
        return None

    return {
        "provider": prov.name,
        "repo": info["repo"],
        "revision": info["revision"],
        "arch": dims.get("arch") or info.get("arch"),
        "ctx_train": dims.get("ctx_train") or info.get("ctx_max"),
        "downloads": info.get("downloads") or 0,
        "license": info.get("license"),
        "best_quant": best["quant"],
        "size_gib": best["size_gib"],
        "verdict": best["verdict"],
        "max_ctx": best["max_ctx"],
        "need_mb": best["need_mb"],
        "available_quants": len(evaluated),
        "draft_cmd": f"/models draft {prov.name} {info['repo']} {best['quant']} --ctx {min(ctx, best['max_ctx'] or ctx)} --kv {kv}",
    }


def curate(families: list[str] | None = None, *, provider_mode: str = "auto",
           ctx: int = 32768, kv: str = "q4_0", per_family: int = 3,
           include_adapters: bool = True) -> dict[str, Any]:
    """Curate top hardware-fitting open models across families (HF default; opt-in fallbacks only)."""
    fams = [f.strip().lower() for f in (families or list(DEFAULT_FAMILIES)) if f.strip()]
    hw = probe()

    if provider_mode == "auto":
        provider_chain = ["huggingface"]
        if opt_in_enabled("MODEL_HUB_ENABLE_MODELSCOPE"):
            provider_chain.append("modelscope")
    else:
        provider_chain = [provider_mode]

    hf_for_adapters = None
    if include_adapters:
        try:
            hf_for_adapters = get_provider("huggingface")
        except Exception:
            hf_for_adapters = None

    results: dict[str, Any] = {}
    fallback_events: list[str] = []

    for fam in fams:
        spec = FAMILY_QUERIES.get(fam) or {
            "label": fam,
            "queries": (f"{fam} GGUF",),
            "exclude_rx": re.compile(r"(?i)(abliterat|heretic|asr|embed)"),
        }
        picked: list[dict[str, Any]] = []
        used_provider = None
        seen_repos: set[str] = set()

        for pname in provider_chain:
            try:
                prov = get_provider(pname)
            except HubError:
                continue
            raw_hits: list[dict[str, Any]] = []
            for q in spec["queries"]:
                try:
                    raw_hits.extend(prov.search(q, limit=12, gguf_only=True, sort="downloads"))
                except HubError as e:
                    fallback_events.append(f"{fam}/{pname}({q}): {e}")
                    continue

            # Filter, dedupe, and prioritize trusted quantizers + high downloads
            filtered = []
            for r in raw_hits:
                rid = r.get("repo") or ""
                if not rid or rid in seen_repos:
                    continue
                if spec["exclude_rx"].search(rid):
                    continue
                if "gguf" not in rid.lower() and "gguf" not in [t.lower() for t in r.get("tags", [])]:
                    continue
                seen_repos.add(rid)
                filtered.append(r)

            filtered.sort(key=_repo_priority)
            for cand in filtered[: max(per_family * 2, 6)]:
                if len(picked) >= per_family:
                    break
                ev = _evaluate_candidate(prov, cand["repo"], hw, ctx=ctx, kv=kv)
                if not ev:
                    continue
                if include_adapters and hf_for_adapters:
                    ev["community_adapters"] = _discover_community_adapters(fam, ev["repo"], hf_for_adapters)
                else:
                    ev["community_adapters"] = []
                picked.append(ev)

            if picked:
                used_provider = pname
                break
            elif pname != provider_chain[-1]:
                fallback_events.append(f"{fam}: 0 fitting hits on {pname} -> falling back to {provider_chain[provider_chain.index(pname) + 1]}")

        picked.sort(key=lambda x: (VERDICT_ORDER.get(x["verdict"], 9), -(x.get("downloads") or 0)))
        results[fam] = {
            "label": spec["label"],
            "provider": used_provider,
            "count": len(picked),
            "models": picked,
        }

    return {
        "hw": {
            "gpus": [(g.get("name"), g.get("vram_total_mb")) for g in hw.get("gpus", [])],
            "ram_mb": hw.get("ram_total_mb"),
            "backend": hw.get("gpu_backend"),
        },
        "provider_chain": provider_chain,
        "ctx": ctx,
        "kv": kv,
        "families": results,
        "fallback_events": fallback_events,
    }
