"""George model hub CLI (JSON on stdout; errors as {"error": ...} with exit 1).

Verbs George's tools may use (read-only / draft-only):
  hw | search | inspect | gguf | fit | quants | draft-from | profiles | show | validate | accounts
  library | fit-local | server-status | jobs | datasets
Operator-only verbs (not exposed as agent tools):
  approve | install | cancel | remove | login | logout | env | args | attach | detach | tune
  import-local | delete-file | presets | preset-run | dataset-files | dataset-pull | export-runs | forge-recipes | forge-pantry | forge-build | train-kit | kits

There is deliberately no curated model list: the Library is whatever the operator has on disk,
and Discover searches the hubs live.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from model_hub import fit as fitmod  # noqa: E402
from model_hub import gguf, installer, library, profiles, serving, training  # noqa: E402
from model_hub.common import REPO_RE, HubError, get_json, redact, set_token  # noqa: E402
from model_hub.hw import probe  # noqa: E402
from model_hub.providers import get_provider  # noqa: E402

LOGIN_PROVIDERS = {"huggingface": "HF_TOKEN", "hf": "HF_TOKEN", "modelscope": "MODELSCOPE_API_TOKEN",
                   "ms": "MODELSCOPE_API_TOKEN"}


def _out(obj: Any) -> None:
    print(redact(json.dumps(obj, indent=None, default=str)))


def _model_files(info: dict[str, Any], quant: str) -> list[dict[str, Any]]:
    q = quant.upper()
    files = [f for f in info["files"] if f["kind"] == "model" and (f.get("quant") == q or f["path"] == quant)]
    if not files:
        raise HubError(f"no model file for quant/file '{quant}'. Available: {', '.join(sorted(info['quants']))}")
    # if several distinct non-shard files share the quant (e.g. different dirs), take the first group
    shards = [f for f in files if f["shard"]]
    if shards:
        total = shards[0]["shard"][1]
        stem = shards[0]["path"].rsplit("-00", 1)[0]
        group = sorted([f for f in shards if f["path"].startswith(stem)], key=lambda f: f["path"])
        if len(group) != total:
            raise HubError(f"incomplete shard set for {quant} ({len(group)}/{total})")
        return group
    return [sorted(files, key=lambda f: len(f["path"]))[0]]


def _dims_for(provider: str, info: dict[str, Any], first_file: str) -> dict[str, Any]:
    prov = get_provider(provider)
    url = prov.file_url(info["repo"], info["revision"], first_file)
    return gguf.model_dims(gguf.read_remote(url, token=prov.token()))


def _pick_aux(info: dict[str, Any], kind: str) -> dict[str, Any] | None:
    cands = [f for f in info["files"] if f["kind"] == kind]
    if not cands:
        return None
    pref = ["Q8_0", "F16", "BF16"]
    cands.sort(key=lambda f: (pref.index(f["quant"]) if f.get("quant") in pref else 9, f["size"]))
    return cands[0]


def _sampling_from_hub(provider: str, info: dict[str, Any]) -> dict[str, Any]:
    if provider != "huggingface":
        return {}
    prov = get_provider(provider)
    for repo in [info["repo"], info.get("base_model")]:
        if not repo:
            continue
        try:
            rev = info["revision"] if repo == info["repo"] else "main"
            g = get_json(prov.file_url(repo, rev, "generation_config.json"), token=prov.token(), timeout=15)
        except HubError:
            continue
        out = {}
        for k, dst, lo, hi in (("temperature", "temperature", 0, 2), ("top_p", "top_p", 0, 1),
                               ("top_k", "top_k", 0, 1000), ("min_p", "min_p", 0, 1),
                               ("repetition_penalty", "repeat_penalty", 0.5, 2)):
            v = g.get(k)
            if isinstance(v, (int, float)) and not isinstance(v, bool) and lo <= v <= hi:
                out[dst] = int(v) if dst == "top_k" else float(v)
        if out:
            out["_source"] = f"{repo}/generation_config.json"
            return out
    return {}


def cmd_fit(a: argparse.Namespace) -> dict[str, Any]:
    info = get_provider(a.provider).inspect(a.repo, a.revision or ("master" if a.provider in ("modelscope", "ms") else "main"))
    mfiles = _model_files(info, a.quant)
    dims = _dims_for(a.provider, info, mfiles[0]["path"])
    hw = probe()
    mm = _pick_aux(info, "mmproj") if a.with_mmproj else None
    dr = _pick_aux(info, "draft") if a.with_draft else None
    r = fitmod.estimate(dims, sum(f["size"] for f in mfiles), hw, ctx=a.ctx, kv_type=a.kv,
                        mmproj_bytes=mm["size"] if mm else 0, draft_bytes=dr["size"] if dr else 0,
                        use_total_vram=not a.free_vram)
    r["model"] = {"repo": info["repo"], "revision": info["revision"], "files": [f["path"] for f in mfiles],
                  "dims": dims}
    return r


def cmd_quants(a: argparse.Namespace) -> dict[str, Any]:
    prov_name = a.provider
    info = get_provider(prov_name).inspect(a.repo, a.revision or ("master" if prov_name in ("modelscope", "ms") else "main"))
    if not info["quants"]:
        raise HubError("no GGUF model files in this repo")
    hw = probe()
    first_q = sorted(info["quants"], key=lambda q: sum(f["size"] for f in _model_files(info, q)))[0]
    dims = _dims_for(prov_name, info, _model_files(info, first_q)[0]["path"])
    rows = []
    for q in sorted(info["quants"]):
        try:
            mf = _model_files(info, q)
        except HubError:
            continue
        r = fitmod.estimate(dims, sum(f["size"] for f in mf), hw, ctx=a.ctx, kv_type=a.kv)
        rows.append({"quant": q, "size_mb": round(sum(f["size"] for f in mf) / (1 << 20)), "verdict": r["verdict"],
                     "max_ctx": r.get("max_ctx"), "n_gpu_layers": r.get("n_gpu_layers"), "files": len(mf)})
    order = {"fits_gpu": 0, "partial_offload": 1, "cpu_only": 2, "does_not_fit": 3}
    rows.sort(key=lambda x: (order[x["verdict"]], -x["size_mb"]))
    return {"repo": info["repo"], "revision": info["revision"], "dims": dims, "ctx": a.ctx, "kv_type": a.kv,
            "hw": {"gpus": [(g["name"], g["vram_total_mb"]) for g in hw["gpus"]], "ram_mb": hw.get("ram_total_mb")},
            "quants": rows,
            "best_gpu_fit": next((x["quant"] for x in rows if x["verdict"] == "fits_gpu"), None)}


def cmd_draft_from(a: argparse.Namespace) -> dict[str, Any]:
    provider = "modelscope" if a.provider in ("ms", "modelscope") else "huggingface"
    info = get_provider(provider).inspect(a.repo, a.revision or ("master" if provider == "modelscope" else "main"))
    mfiles = _model_files(info, a.quant)
    dims = _dims_for(provider, info, mfiles[0]["path"])
    hw = probe()
    mm = _pick_aux(info, "mmproj") if a.with_mmproj else None
    dr = _pick_aux(info, "draft") if a.with_draft else None
    r = fitmod.estimate(dims, sum(f["size"] for f in mfiles), hw, ctx=a.ctx, kv_type=a.kv,
                        mmproj_bytes=mm["size"] if mm else 0, draft_bytes=dr["size"] if dr else 0)
    if r["verdict"] == "does_not_fit":
        raise HubError("this quant does not fit this machine: " + "; ".join(r["notes"]))
    files = [{"role": "model", "path": f["path"], "size": f["size"], "sha256": f["sha256"]} for f in mfiles]
    for role, f in (("mmproj", mm), ("draft", dr)):
        if f:
            files.append({"role": role, "path": f["path"], "size": f["size"], "sha256": f["sha256"]})
    missing = [f["path"] for f in files if not f["sha256"]]
    if missing:
        raise HubError("hub did not provide sha256 for: " + ", ".join(missing) + " — refusing (unverifiable)")
    cap = r.get("max_ctx_single_gpu") or r.get("max_ctx") or a.ctx or 32768
    ctx = min(a.ctx or 32768, cap)
    server: dict[str, Any] = {"ctx": max(512, ctx), "n_gpu_layers": int(r.get("n_gpu_layers") or 0),
                              "ubatch": 512, "flash_attn": True, "cache_type_k": a.kv, "cache_type_v": a.kv,
                              "jinja": bool(dims.get("has_chat_template"))}
    if r.get("tensor_split"):
        server["tensor_split"] = r["tensor_split"]
    if r.get("split_mode"):
        server["split_mode"] = r["split_mode"]
        server["main_gpu"] = int(r.get("main_gpu") or 0)
    if dr:
        server["draft_max"] = 8
    sampling = _sampling_from_hub(provider, info)
    src_note = sampling.pop("_source", None)
    name = a.name or f"{info['repo'].split('/')[-1].lower().replace('-gguf', '')}-{a.quant.lower()}"[:64]
    name = "".join(c if c.isalnum() or c in "._-" else "-" for c in name).strip("-.").lower()
    p = {"schema": 1, "name": name, "source": {"provider": provider, "repo": info["repo"], "revision": info["revision"]},
         "files": files, "server": server, "sampling": sampling,
         "fit": {k: r.get(k) for k in ("verdict", "max_ctx", "need_mb", "gpu_usable_mb", "kv_mb_per_1k_tokens",
                                       "tensor_split", "n_gpu_layers", "notes")},
         "notes": "; ".join(filter(None, [f"license: {info.get('license')}" if info.get("license") else None,
                                          f"sampling from {src_note}" if src_note else "sampling: model defaults",
                                          f"arch {dims.get('arch')}, {dims.get('n_layer')} layers, ctx_train {dims.get('ctx_train')}"])),
         "license": info.get("license")}
    p["license"] = str(p["license"])[:60] if p["license"] else None
    if p["license"] is None:
        p.pop("license")
    saved = profiles.save_draft(p, hw, created_by="operator" if a.operator else "george")
    return {"draft": saved["name"], "status": saved["status"], "profile": saved,
            "next": f"Review, then approve with: /models approve {saved['name']}"}


# ── local library ─────────────────────────────────────────────────────────────────────────────────────

def _local_aux(rel: str | None, kind: str) -> dict[str, Any] | None:
    if not rel:
        return None
    e = library.find(rel)
    if e.get("kind") != kind:
        raise HubError(f"{rel} is a {e.get('kind')} file, not a {kind}")
    return e


def _local_fit(a: argparse.Namespace) -> tuple[dict[str, Any], dict[str, Any] | None, dict[str, Any] | None,
                                              dict[str, Any], dict[str, Any]]:
    m = library.find(a.file)
    if m.get("error"):
        raise HubError(f"{a.file}: cannot read GGUF metadata ({m['error']})")
    if m.get("kind") != "model":
        what = {"adapter": "an adapter (LoRA / control vector)", "mmproj": "a vision/audio projector",
                "draft": "a draft (speculative decoding) model"}.get(str(m.get("kind")), "not a full model")
        raise HubError(f"{a.file} is {what}. Adapters attach to a profile in Serve & Tune; projectors and "
                       "drafts are picked when you serve a full model.")
    mm, dr = _local_aux(a.mmproj, "mmproj"), _local_aux(a.draft, "draft")
    hw = probe()
    r = fitmod.estimate(m["dims"], m["size"], hw, ctx=a.ctx, kv_type=a.kv,
                        mmproj_bytes=mm["size"] if mm else 0, draft_bytes=dr["size"] if dr else 0)
    return m, mm, dr, hw, r


def cmd_fit_local(a: argparse.Namespace) -> dict[str, Any]:
    m, mm, dr, hw, r = _local_fit(a)
    kv_opts = []
    for kv in ("f16", "q8_0", "q4_0"):
        # Probe at a small context: when the weights fit, max_ctx is the largest fully-on-GPU context.
        e = fitmod.estimate(m["dims"], m["size"], hw, ctx=2048, kv_type=kv,
                            mmproj_bytes=mm["size"] if mm else 0, draft_bytes=dr["size"] if dr else 0)
        kv_opts.append({"kv": kv, "verdict": e["verdict"],
                        "max_gpu_ctx": e.get("max_ctx") if e["verdict"] == "fits_gpu" else 0,
                        "max_single_gpu_ctx": e.get("max_ctx_single_gpu")})
    r["model"] = {k: m.get(k) for k in ("rel", "file", "size", "arch", "title", "quant", "ctx_train", "n_layer",
                                        "experts", "chat_template", "base_model", "license", "sampling")}
    r["kv_options"] = kv_opts
    r["hw"] = {"gpus": [(g.get("name"), g.get("vram_total_mb")) for g in hw.get("gpus", [])],
               "ram_mb": hw.get("ram_total_mb"), "backend": hw.get("gpu_backend")}
    return r


def _default_name(rel: str) -> str:
    stem = Path(rel).name.rsplit(".gguf", 1)[0]
    stem = stem.rsplit("-00001-of-", 1)[0]
    n = "".join(c if c.isalnum() or c in "._-" else "-" for c in stem.lower()).strip("-._")[:60]
    return n if len(n) >= 2 else f"local-{n or 'model'}"


def cmd_import_local(a: argparse.Namespace) -> dict[str, Any]:
    """Pin a GGUF the operator already has as a profile: sha256 every file, derive llama-server settings
    from the fit calculator, save as an operator draft (optionally approve + verify in one go)."""
    m, mm, dr, hw, r = _local_fit(a)
    if r["verdict"] == "does_not_fit":
        raise HubError("does not fit this machine at this context: " + "; ".join(r["notes"]))
    name = a.name or _default_name(m["rel"])
    if not profiles.NAME_RE.match(name):
        raise HubError("invalid profile name (lowercase a-z0-9._-, 2-64 chars)")
    parts = [("model", rel) for rel in (m.get("shard_paths") or [m["rel"]])]
    if mm:
        parts.append(("mmproj", mm["rel"]))
    if dr:
        parts.append(("draft", dr["rel"]))
    paths = [(role, rel, library.resolve_rel(rel)) for role, rel in parts]
    bad = [rel for _, rel, _ in paths if not re.fullmatch(r"[A-Za-z0-9._/+@-]+", rel)]
    if bad:
        raise HubError(f"rename before importing (letters, digits and . _ - + @ / only): {', '.join(bad)}")
    total = sum(p.resolve().stat().st_size for _, _, p in paths)
    (installer.downloads_dir() / f"{name}.cancel").unlink(missing_ok=True)
    installer._progress(name, state="running", kind="import", total=total, done=0, file=None, error=None)
    done = 0

    def bump(n: int) -> None:
        nonlocal done
        done += n
        if done % (256 << 20) < n or done >= total:
            installer._progress(name, done=done)

    files = []
    try:
        for role, rel, p in paths:
            installer._progress(name, file=rel)
            sha = library.sha256_cached(p, on_bytes=bump, cancelled=lambda: installer._cancelled(name))
            files.append({"role": role, "path": rel, "size": p.resolve().stat().st_size, "sha256": sha})
        dims = m["dims"]
        cap = r.get("max_ctx_single_gpu") or r.get("max_ctx") or a.ctx or 8192
        ctx = max(512, min(a.ctx or min(dims.get("ctx_train") or 32768, 32768), cap))
        server: dict[str, Any] = {"ctx": ctx, "n_gpu_layers": int(r.get("n_gpu_layers") or 0), "ubatch": 512,
                                  "flash_attn": True, "cache_type_k": a.kv, "cache_type_v": a.kv,
                                  "jinja": bool(dims.get("has_chat_template"))}
        if r.get("tensor_split"):
            server["tensor_split"] = r["tensor_split"]
        if r.get("split_mode"):
            server["split_mode"] = r["split_mode"]
            server["main_gpu"] = int(r.get("main_gpu") or 0)
        if dr:
            server["draft_max"] = 8
        base = m.get("base_model") if isinstance(m.get("base_model"), str) and REPO_RE.match(m["base_model"]) else ""
        p = {"schema": 1, "name": name, "source": {"provider": "local", "repo": base, "revision": ""},
             "files": files, "server": server, "sampling": dict(m.get("sampling") or {}),
             "fit": {k: r.get(k) for k in ("verdict", "max_ctx", "need_mb", "gpu_usable_mb", "kv_mb_per_1k_tokens",
                                           "tensor_split", "n_gpu_layers", "notes")},
             "notes": "; ".join(filter(None, [f"imported from {library.root()}/{m['rel']}",
                                              f"license: {m.get('license')}" if m.get("license") else None,
                                              f"arch {dims.get('arch')}, {dims.get('n_layer')} layers, "
                                              f"ctx_train {dims.get('ctx_train')}"]))}
        saved = profiles.save_draft(p, hw, created_by="operator")
        installer._progress(name, state="done", done=total, profile=name)
    except HubError as e:
        installer._progress(name, state="failed", error=str(e))
        raise
    out: dict[str, Any] = {"profile": saved["name"], "status": saved["status"], "server": saved["server"],
                           "files": saved["files"], "fit": saved.get("fit")}
    if a.approve:
        profiles.approve(name)
        installer.install(name, log=lambda msg: print(msg, file=sys.stderr))
        out["status"] = "installed"
        out["next"] = f"Serve it: /models activate {name}"
    else:
        out["next"] = f"Review, then: /models approve {name} && /models install {name} && /models activate {name}"
    return out


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="model_hub")
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("hw")
    s = sp.add_parser("search"); s.add_argument("query"); s.add_argument("--provider", default="huggingface")
    s.add_argument("--limit", type=int, default=15); s.add_argument("--all-formats", action="store_true")
    s.add_argument("--sort", default="downloads", choices=["downloads", "likes", "lastModified", "trending"])
    s = sp.add_parser("inspect"); s.add_argument("provider"); s.add_argument("repo"); s.add_argument("--revision")
    s = sp.add_parser("gguf"); s.add_argument("provider"); s.add_argument("repo"); s.add_argument("file")
    s.add_argument("--revision")
    for name in ("fit", "draft-from"):
        s = sp.add_parser(name); s.add_argument("provider"); s.add_argument("repo"); s.add_argument("quant")
        s.add_argument("--revision"); s.add_argument("--ctx", type=int); s.add_argument("--kv", default="f16",
                                                                                         choices=sorted(fitmod.KV_BYTES))
        s.add_argument("--with-mmproj", action="store_true"); s.add_argument("--with-draft", action="store_true")
        if name == "fit":
            s.add_argument("--free-vram", action="store_true")
        else:
            s.add_argument("--name"); s.add_argument("--operator", action="store_true")
    s = sp.add_parser("quants"); s.add_argument("provider"); s.add_argument("repo"); s.add_argument("--revision")
    s.add_argument("--ctx", type=int, default=32768); s.add_argument("--kv", default="f16", choices=sorted(fitmod.KV_BYTES))
    sp.add_parser("profiles")
    for name in ("show", "validate", "approve", "install", "cancel", "progress"):
        s = sp.add_parser(name); s.add_argument("name")
    s = sp.add_parser("env"); s.add_argument("name"); s.add_argument("--native", action="store_true")
    s = sp.add_parser("args"); s.add_argument("name"); s.add_argument("--native", action="store_true")
    s = sp.add_parser("attach"); s.add_argument("name"); s.add_argument("role", choices=sorted(profiles.ADAPTER_ROLES))
    s.add_argument("file"); s.add_argument("--scale", type=float, default=1.0)
    s.add_argument("--from-library", action="store_true", help="file is a path relative to MODELS_DIR")
    s = sp.add_parser("detach"); s.add_argument("name"); s.add_argument("file")
    s = sp.add_parser("remove"); s.add_argument("name"); s.add_argument("--delete-files", action="store_true")
    s = sp.add_parser("save-draft"); s.add_argument("--operator", action="store_true")
    for name in ("login", "logout", "whoami"):
        s = sp.add_parser(name); s.add_argument("provider")
    sp.add_parser("accounts")
    sp.add_parser("disk")
    # local library
    s = sp.add_parser("library"); s.add_argument("--no-meta", action="store_true")
    for name in ("fit-local", "import-local"):
        s = sp.add_parser(name); s.add_argument("file"); s.add_argument("--ctx", type=int)
        s.add_argument("--kv", default="f16", choices=sorted(fitmod.KV_BYTES))
        s.add_argument("--mmproj"); s.add_argument("--draft")
        if name == "import-local":
            s.add_argument("--name"); s.add_argument("--approve", action="store_true")
    s = sp.add_parser("delete-file"); s.add_argument("file"); s.add_argument("--force", action="store_true")
    s = sp.add_parser("tune"); s.add_argument("name")
    sp.add_parser("jobs")
    s = sp.add_parser("clear-job"); s.add_argument("name")
    sp.add_parser("server-status")
    sp.add_parser("presets")
    s = sp.add_parser("preset-run"); s.add_argument("id"); s.add_argument("--status", action="store_true")
    # fine-tuning
    sp.add_parser("datasets")
    s = sp.add_parser("dataset-files"); s.add_argument("repo")
    s = sp.add_parser("dataset-pull"); s.add_argument("repo"); s.add_argument("path")
    s = sp.add_parser("export-runs"); s.add_argument("--since")
    sp.add_parser("train-kit")
    sp.add_parser("forge-recipes")
    sp.add_parser("forge-pantry")
    sp.add_parser("forge-build")
    sp.add_parser("kits")
    return ap


def run(argv: list[str]) -> Any:
    a = build_parser().parse_args(argv)
    c = a.cmd
    if c == "hw":
        return probe()
    if c == "search":
        if a.provider == "all":
            out = []
            for pn in ("huggingface", "modelscope"):
                try:
                    out += get_provider(pn).search(a.query, a.limit, not a.all_formats, a.sort)
                except HubError as e:
                    out.append({"provider": pn, "error": str(e)})
            return out
        return get_provider(a.provider).search(a.query, a.limit, not a.all_formats, a.sort)
    if c == "inspect":
        prov = get_provider(a.provider)
        return prov.inspect(a.repo, a.revision or ("master" if prov.name == "modelscope" else "main"))
    if c == "gguf":
        prov = get_provider(a.provider)
        info = prov.inspect(a.repo, a.revision or ("master" if prov.name == "modelscope" else "main"))
        return _dims_for(prov.name, info, a.file)
    if c == "fit":
        return cmd_fit(a)
    if c == "quants":
        return cmd_quants(a)
    if c == "draft-from":
        return cmd_draft_from(a)
    if c == "save-draft":
        p = json.loads(sys.stdin.read(1 << 20))
        return profiles.save_draft(p, probe(), created_by="operator" if a.operator else "george")
    if c == "profiles":
        return profiles.list_profiles()
    if c == "show":
        p = profiles.load(a.name)
        p["approved_valid"] = profiles.is_approved(p)
        return p
    if c == "validate":
        p = profiles.load(a.name)
        return {"name": a.name, "errors": profiles.validate(p, probe()), "approved": profiles.is_approved(p)}
    if c == "approve":
        return profiles.approve(a.name)
    if c == "install":
        return installer.install(a.name, log=lambda m: print(m, file=sys.stderr))
    if c == "cancel":
        (installer.downloads_dir() / f"{a.name}.cancel").touch()
        return {"cancel_requested": a.name}
    if c == "progress":
        f = installer.downloads_dir() / f"{a.name}.json"
        return json.loads(f.read_text()) if f.exists() else {"state": "none"}
    if c == "remove":
        return installer.remove(a.name, a.delete_files)
    if c == "env":
        from model_hub.hw import models_dir
        root = str(models_dir()) if a.native else "/models"
        return profiles.render_env(profiles.load(a.name), container_models_root=root)
    if c == "args":
        from model_hub.hw import models_dir
        root = str(models_dir()) if a.native else "/models"
        return profiles.render_args(profiles.load(a.name), container_models_root=root)
    if c == "attach":
        src = str(library.resolve_rel(a.file)) if a.from_library else a.file
        return profiles.attach(a.name, a.role, src, a.scale)
    if c == "detach":
        return profiles.detach(a.name, a.file)
    if c == "login":
        key = LOGIN_PROVIDERS.get(a.provider)
        if not key:
            raise HubError("login supports huggingface|modelscope")
        tok = sys.stdin.readline().strip()
        who = get_provider(a.provider).whoami(tok)  # validate before storing
        set_token(key, tok)
        return {"logged_in": who}
    if c == "logout":
        key = LOGIN_PROVIDERS.get(a.provider)
        if not key:
            raise HubError("logout supports huggingface|modelscope")
        set_token(key, None)
        return {"logged_out": a.provider}
    if c == "whoami":
        return get_provider(a.provider).whoami()
    if c == "accounts":
        out = []
        for pn in ("huggingface", "modelscope"):
            prov = get_provider(pn)
            if not prov.token():
                out.append({"provider": pn, "logged_in": False})
                continue
            try:
                out.append({"logged_in": True, **prov.whoami()})
            except HubError as e:
                out.append({"provider": pn, "logged_in": False, "error": str(e)})
        out.append({"provider": "ipfs", "logged_in": None, "gateways": get_provider("ipfs").gateways})
        return out
    if c == "disk":
        return installer.disk_report()
    if c == "library":
        return library.scan(with_meta=not a.no_meta)
    if c == "fit-local":
        return cmd_fit_local(a)
    if c == "import-local":
        return cmd_import_local(a)
    if c == "delete-file":
        return library.delete_file(a.file, a.force)
    if c == "tune":
        return profiles.tune(a.name, json.loads(sys.stdin.read(1 << 16) or "{}"))
    if c == "jobs":
        return installer.jobs()
    if c == "clear-job":
        if not profiles.NAME_RE.match(a.name):
            raise HubError("invalid job name")
        f = installer.downloads_dir() / f"{a.name}.json"
        if f.exists() and json.loads(f.read_text()).get("state") == "running":
            raise HubError("job is still running; cancel it first")
        f.unlink(missing_ok=True)
        return {"cleared": a.name}
    if c == "server-status":
        return serving.server_status()
    if c == "presets":
        return serving.presets()
    if c == "preset-run":
        return serving.run_preset(a.id, status=a.status)
    if c == "datasets":
        return training.list_datasets()
    if c == "dataset-files":
        return training.dataset_files(a.repo)
    if c == "dataset-pull":
        return training.pull_dataset(a.repo, a.path)
    if c == "export-runs":
        return training.export_runs(a.since)
    if c == "forge-recipes":
        return training.forge_recipes()
    if c == "forge-pantry":
        return training.forge_pantry()
    if c == "forge-build":
        return training.forge_build(json.loads(sys.stdin.read(1 << 16) or "{}"))
    if c == "train-kit":
        return training.make_kit(json.loads(sys.stdin.read(1 << 16) or "{}"))
    if c == "kits":
        return training.list_kits()
    raise HubError(f"unknown command {c}")


def main() -> int:
    try:
        _out(run(sys.argv[1:]))
        return 0
    except HubError as e:
        _out({"error": str(e)})
        return 1
    except ValueError as e:
        _out({"error": f"invalid input: {e}"})
        return 1


if __name__ == "__main__":
    os.umask(0o077)
    sys.exit(main())
