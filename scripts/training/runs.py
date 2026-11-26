#!/usr/bin/env python3
"""Lodge training-run manager — Local GPU (contention-safe) or Google Colab 1-3x GPU Fleet
(with VRAM-aware fallback H100->G4->A100->L4->T4, Drive checkpoints, 1h timeout auto-resume,
in-Colab GGUF export, SVD-32 retention lineage, Tier B/A gating, and live POST /lora-adapters hot-swap).
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_credits as cc  # noqa: E402

LODGE = os.environ.get("LODGE_DIR", os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
GEORGE = os.environ.get("GEORGE_DIR", os.path.join(LODGE, ".george"))
NAME_RX = re.compile(r"^[a-z0-9][a-z0-9._-]{1,47}$")
SLUG_RX = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
REPO_RX = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,95}$")
DS_RX = re.compile(r"^(training|exports):([A-Za-z0-9._+@/-]{1,300})$")
KIT = os.path.join(LODGE, "scripts", "training", "kit", "train_lora.py")
MERGE = os.path.join(LODGE, "scripts", "training", "merge_loras.py")
LOSS_RX = re.compile(r"\{[^{}]*'loss': '?([0-9.eE+-]+)'?[^{}]*?'epoch': '?([0-9.]+)'?[^{}]*\}")
EVAL_RX = re.compile(r"'eval_loss': '?([0-9.eE+-]+)")
MARGIN_RX = re.compile(r"'rewards/margins': '?([0-9.eE+-]+)")
HYPER = {
    "epochs": (float, 0.1, 50, 2), "learning_rate": (float, 1e-7, 1e-2, 1e-4), "lora_r": (int, 1, 512, 32),
    "lora_alpha": (int, 1, 1024, 64), "lora_dropout": (float, 0.0, 0.5, 0.05),
    "max_seq_len": (int, 256, 262144, 4096), "batch_size": (int, 1, 256, 1), "grad_accum": (int, 1, 1024, 8),
    "dpo_beta": (float, 0.01, 2.0, 0.1), "save_steps": (int, 5, 5000, 40),
}
COLAB_BIN = cc.COLAB_BIN or os.path.join(LODGE, ".venv", "bin", "colab")

# Exact colab-cli supported NVIDIA GPUs (strongest -> weakest) with nominal VRAM GB & --high-mem support
# Note: H100, G4, and L4 only exist in a single machine shape; passing --high-mem to H100/G4 causes HTTP 400.
GPU_TIERS = {
    "H100": {"vram_gb": 80, "high_mem": False},
    "G4":   {"vram_gb": 96, "high_mem": False},
    "A100": {"vram_gb": 80, "high_mem": True},
    "L4":   {"vram_gb": 24, "high_mem": False},
    "T4":   {"vram_gb": 16, "high_mem": True},
}
DEFAULT_GPU_FALLBACK = ["H100", "G4", "A100", "L4", "T4"]

DEFAULT_POLICY = {
    "autonomy_tier": "tier_b",        # "tier_b" (Human Approval in Forge/Discord) | "tier_a" (Auto-promote)
    "tier_a_min_delta": 3.0,          # Required composite improvement % for Tier A auto-promotion
    "sleep_enabled": False,
    "sleep_start_hour": 2,
    "sleep_end_hour": 6,
    "min_new_samples": 120,
    "min_cu_balance": 150.0,
    "max_concurrent_colab": 3,
    "default_prior_weight": 0.70,
    "auto_backup_drive": False,
    "auto_backup_hf": False,
    "auto_benchmark_on_merge": False,
    "hf_backup_repo": "",
    "drive_backup_folder": "BlueLodge/models/adapters",
}


class SpecError(ValueError):
    pass


def _write_json(path, obj):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, indent=2)
    try:
        os.chmod(tmp, 0o664)
    except OSError:
        pass
    os.replace(tmp, path)


def _write_text(path, text: str):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    try:
        os.chmod(tmp, 0o664)
    except OSError:
        pass
    os.replace(tmp, path)


def _read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def runs_dir():
    d = os.path.join(GEORGE, "training", "runs")
    os.makedirs(d, exist_ok=True)
    return d


def policy_path():
    d = os.path.join(GEORGE, "training")
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, "policy.json")


def load_policy() -> dict:
    p = dict(DEFAULT_POLICY)
    saved = _read_json(policy_path(), {})
    if isinstance(saved, dict):
        p.update(saved)
    return p


def save_policy(updates: dict) -> dict:
    p = load_policy()
    for k, v in (updates or {}).items():
        if k in DEFAULT_POLICY:
            if k == "autonomy_tier" and v not in ("tier_a", "tier_b"):
                raise SpecError("autonomy_tier must be 'tier_a' or 'tier_b'")
            p[k] = v
    _write_json(policy_path(), p)
    return p


def run_dir(name):
    if not NAME_RX.match(str(name or "")):
        raise SpecError("run name: lowercase a-z0-9._- (2-48 chars)")
    rd = os.path.join(runs_dir(), name)
    if not os.path.isfile(os.path.join(rd, "run.json")):
        raise SpecError(f"no run named {name}")
    return rd


def models_dir():
    return os.environ.get("MODELS_DIR") or os.path.expanduser("~/models")


def role_adapter_dir(model_slug: str, role: str) -> str:
    ms = re.sub(r"[^a-z0-9._-]", "-", (model_slug or "default").lower())[:64] or "default"
    rl = re.sub(r"[^a-z0-9._-]", "-", (role or "core-agent").lower())[:48] or "core-agent"
    d = os.path.join(models_dir(), "adapters", ms, rl)
    for sub in ("releases", "candidates", "tracks"):
        os.makedirs(os.path.join(d, sub), exist_ok=True)
    return d


def resolve_dataset(ds_id):
    m = DS_RX.match(ds_id or "")
    if not m or ".." in m.group(2).split("/"):
        raise SpecError(f"dataset id must look like training:<file> or exports:<dir>/<file> (got {ds_id!r})")
    root = os.path.join(LODGE, "data", "training") if m.group(1) == "training" else os.path.join(GEORGE, "datasets")
    base = os.path.realpath(root)
    p = os.path.realpath(os.path.join(root, m.group(2)))
    if not p.startswith(base + os.sep) or not os.path.isfile(p):
        raise SpecError(f"dataset {ds_id} not found")
    return p


def _exe(path):
    return bool(path) and os.path.isfile(path) and os.access(path, os.X_OK)


def find_converter(spec):
    cands = []
    for d in (spec.get("llama_cpp_dir"), os.environ.get("LLAMA_CPP_DIR"), os.path.join(GEORGE, "tools", "llama_cpp"), "/opt/llama.cpp"):
        if d:
            cands.append(os.path.join(d, "convert_lora_to_gguf.py"))
    cands += sorted(glob.glob(os.path.join(LODGE, "build*", "*", "convert_lora_to_gguf.py")))
    cands += [os.path.expanduser("~/llama.cpp/convert_lora_to_gguf.py")]
    return next((c for c in cands if os.path.isfile(c)), None)


def find_export_lora_bin(spec=None):
    cands = [shutil.which("llama-export-lora")]
    if isinstance(spec, dict) and spec.get("llama_cpp_dir"):
        cands.append(os.path.join(spec["llama_cpp_dir"], "build", "bin", "llama-export-lora"))
    if os.environ.get("LLAMA_CPP_DIR"):
        cands.append(os.path.join(os.environ["LLAMA_CPP_DIR"], "build", "bin", "llama-export-lora"))
    cands += ["/usr/local/bin/llama-export-lora", "/opt/llama.cpp/build/bin/llama-export-lora",
              os.path.expanduser("~/llama.cpp/build/bin/llama-export-lora")]
    return next((c for c in cands if _exe(c)), None)


def build_gpu_ladder(preferred: str, fallback: list[str] | None, min_vram_gb: int) -> list[str]:
    pref = (preferred or "A100").upper()
    if pref not in GPU_TIERS:
        raise SpecError(f"colab.gpu must be one of {sorted(GPU_TIERS)} (got {preferred!r})")
    raw = [g.upper() for g in (fallback or DEFAULT_GPU_FALLBACK)]
    bad = [g for g in raw if g not in GPU_TIERS]
    if bad:
        raise SpecError(f"invalid GPU(s) in colab.gpu_fallback: {bad}; valid: {sorted(GPU_TIERS)}")
    # Place preferred first, then remaining fallback tiers in order
    ordered = [pref] + [g for g in raw if g != pref]
    eligible = [g for g in ordered if GPU_TIERS[g]["vram_gb"] >= min_vram_gb]
    return eligible or [pref]


def validate(spec):
    if not isinstance(spec, dict):
        raise SpecError("spec must be a JSON object")
    name = str(spec.get("name", ""))
    if not NAME_RX.match(name):
        raise SpecError("name: lowercase a-z0-9._- (2-48 chars)")
    backend = spec.get("backend", "local")
    if backend not in ("local", "colab"):
        raise SpecError("backend must be local or colab")
    if not REPO_RX.match(str(spec.get("base_model", ""))):
        raise SpecError("base_model must be a Hugging Face repo id (org/name)")
    base_source = str(spec.get("base_source", "hf_direct"))
    if base_source not in ("hf_direct", "local_upload", "drive_mirror"):
        raise SpecError("base_source must be hf_direct, local_upload, or drive_mirror")
    role = str(spec.get("role", "core-agent"))
    if not SLUG_RX.match(role):
        raise SpecError("role: lowercase a-z0-9._-")
    model_slug = str(spec.get("model_slug") or spec["base_model"].split("/")[-1].lower())
    model_slug = re.sub(r"[^a-z0-9._-]", "-", model_slug)[:64]

    tracks = spec.get("tracks")
    if not isinstance(tracks, list) or not 1 <= len(tracks) <= 8:
        raise SpecError("tracks: 1-8 entries")
    hyper = {}
    for k, (typ, lo, hi, dflt) in HYPER.items():
        v = (spec.get("hyper") or {}).get(k, dflt)
        try:
            v = typ(v)
        except (TypeError, ValueError):
            raise SpecError(f"hyper.{k} must be a number") from None
        if not lo <= v <= hi:
            raise SpecError(f"hyper.{k} must be in [{lo}, {hi}]")
        hyper[k] = v
    hyper["load_in_4bit"] = bool((spec.get("hyper") or {}).get("load_in_4bit", True))
    hyper["use_unsloth"] = bool((spec.get("hyper") or {}).get("use_unsloth", True))

    seen, out_tracks = set(), []
    for t in tracks:
        if not isinstance(t, dict):
            raise SpecError("each track must be an object")
        tn = str(t.get("name", ""))
        if not NAME_RX.match(tn) or tn in seen:
            raise SpecError(f"track name {tn!r}: unique, lowercase a-z0-9._-")
        seen.add(tn)
        method = t.get("method", "sft")
        if method not in ("sft", "dpo"):
            raise SpecError(f"track {tn}: method must be sft or dpo")
        gpu = t.get("gpu", 0)
        if not isinstance(gpu, int) or not 0 <= gpu <= 15:
            raise SpecError(f"track {tn}: gpu must be an integer 0-15")
        train = resolve_dataset(str(t.get("train", "")))
        val = resolve_dataset(str(t["val"])) if t.get("val") else None
        init = t.get("init_adapter")
        if init and not os.path.isdir(os.path.expanduser(str(init))):
            raise SpecError(f"track {tn}: init_adapter directory not found")
        out_tracks.append({
            "name": tn, "method": method, "gpu": gpu, "train_file": train, "val_file": val,
            "init_adapter": os.path.expanduser(str(init)) if init else None,
            "depends_on": t.get("depends_on"),
        })

    merge = spec.get("merge") or {"method": "svd"}
    if merge.get("method", "svd") not in ("concat", "svd", "none"):
        raise SpecError("merge.method must be concat, svd or none")
    w = merge.get("weights")
    if w is not None and (not isinstance(w, list) or len(w) != len(out_tracks)
                          or not all(isinstance(x, (int, float)) and x >= 0 for x in w)):
        raise SpecError("merge.weights: one non-negative number per track (or null for equal weights)")
    tr = int(merge.get("target_rank", 32))
    if not 1 <= tr <= 1024:
        raise SpecError("merge.target_rank must be 1-1024")
    prior_w = float(merge.get("prior_adapter_weight", 0.70))
    if not 0.0 <= prior_w <= 0.95:
        raise SpecError("merge.prior_adapter_weight must be in [0.0, 0.95]")

    colab_raw = spec.get("colab") or {}
    c_auth = str(colab_raw.get("auth", "adc"))
    if c_auth not in ("adc", "oauth2"):
        raise SpecError("colab.auth must be adc or oauth2")
    c_min_vram = int(colab_raw.get("min_gpu_vram_gb", 24))
    c_ladder = build_gpu_ladder(str(colab_raw.get("gpu", "A100")), colab_raw.get("gpu_fallback"), c_min_vram)

    py = spec.get("train_python") or os.environ.get("BLUE_LODGE_TRAIN_PYTHON") or ""
    local_raw = spec.get("local") or {}
    bench_raw = spec.get("benchmark") or {}
    raw_tpl = str(spec.get("chat_template_file") or "").strip()
    chat_tpl = ""
    if raw_tpl:
        cand_tpl = os.path.expanduser(raw_tpl)
        if not os.path.isabs(cand_tpl):
            cand_tpl = os.path.join(LODGE, cand_tpl)
        if not os.path.isfile(cand_tpl):
            raise SpecError(f"chat_template_file not found: {raw_tpl}")
        chat_tpl = os.path.abspath(cand_tpl)
    return {
        "name": name, "role": role, "model_slug": model_slug, "backend": backend,
        "base_model": spec["base_model"], "base_source": base_source,
        "base_hf_path": os.path.expanduser(str(spec.get("base_hf_path") or "")),
        "drive_base_path": str(spec.get("drive_base_path") or ""),
        "chat_template_file": chat_tpl,
        "train_python": os.path.expanduser(py), "llama_cpp_dir": spec.get("llama_cpp_dir"),
        "tracks": out_tracks, "hyper": hyper,
        "merge": {
            "method": merge.get("method", "svd"), "target_rank": tr, "weights": w,
            "prior_adapter_weight": prior_w,
        },
        "colab": {
            "auth": c_auth, "gpu": c_ladder[0], "gpu_fallback": c_ladder,
            "min_gpu_vram_gb": c_min_vram,
            "high_mem": bool(colab_raw.get("high_mem", True)),
            "max_concurrent_sessions": max(1, min(3, int(colab_raw.get("max_concurrent_sessions", 3)))),
            "min_cu_balance": float(colab_raw.get("min_cu_balance", load_policy().get("min_cu_balance", 150.0))),
            "max_runtime_min": max(30, min(720, int(colab_raw.get("max_runtime_min", 180)))),
            "retry_attempts": max(1, min(6, int(colab_raw.get("retry_attempts", 3)))),
            "retry_backoff_sec": max(2, min(60, int(colab_raw.get("retry_backoff_sec", 8)))),
            "drive_checkpoints": bool(colab_raw.get("drive_checkpoints", True)),
            "drive_checkpoint_sync": bool(colab_raw.get("drive_checkpoint_sync", colab_raw.get("drive_checkpoints", True))),
            "drive_checkpoint_keep": max(1, min(5, int(colab_raw.get("drive_checkpoint_keep", 2)))),
            "export_gguf_on_colab": bool(colab_raw.get("export_gguf_on_colab", True)),
        },
        "local": {
            "pause_inference": bool(local_raw.get("pause_inference", True)),
        },
        "benchmark": {
            "model_family": str(bench_raw.get("model_family", "auto")),
            "min_composite_delta": float(bench_raw.get("min_composite_delta", 0.0)),
            "max_early_quit_delta": float(bench_raw.get("max_early_quit_delta", 0.0)),
        },
    }


def preflight(v):
    """Comprehensive prerequisite + budget + dataset check. Hard errors block execution."""
    prereqs = cc.get_prerequisites()
    errors, warns, info = [], [], {"prerequisites": prereqs}
    if v["backend"] == "local":
        tpy = v["train_python"] or prereqs["local_train_env"].get("python") or ""
        if not _exe(tpy):
            errors.append("Local training Python env missing torch/transformers/peft/trl/datasets — set train_python or $BLUE_LODGE_TRAIN_PYTHON.")
        else:
            r = subprocess.run(
                [tpy, "-c", "import torch, transformers, peft, trl, datasets; print(torch.cuda.device_count(), trl.__version__)"],
                capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL, check=False,
            )
            if r.returncode != 0:
                errors.append("Local training env missing packages: " + (r.stderr.strip().splitlines() or ["?"])[-1])
            else:
                n, trl_v = r.stdout.split()[:2]
                info["cuda_devices"], info["trl"] = int(n), trl_v
                bad = sorted({t["gpu"] for t in v["tracks"] if t["gpu"] >= int(n)})
                if bad:
                    errors.append(f"Tracks request GPU(s) {bad} but local CUDA sees {n}")
        gpus = prereqs["local_train_env"].get("gpus", [])
        info["gpus"] = gpus
        for g in gpus:
            if g["index"] in {t["gpu"] for t in v["tracks"]} and (g["total_mb"] - g["used_mb"]) < 4096:
                if v["local"]["pause_inference"]:
                    warns.append(f"GPU {g['index']} currently has {g['total_mb'] - g['used_mb']} MiB free — inference server will be paused cleanly during training and restored on exit.")
                else:
                    warns.append(f"GPU {g['index']} has only {g['total_mb'] - g['used_mb']} MiB free and local.pause_inference=false.")
    else:
        if not prereqs["colab_cli"]["installed"]:
            errors.append("Colab CLI not installed (.venv/bin/colab missing). Fix: uv pip install --python .venv/bin/python colab-cli")
        auth = v["colab"]["auth"]
        if auth == "adc" and not prereqs["adc_credentials"]["configured"]:
            errors.append("Google ADC credentials not configured. Install gcloud and run: gcloud auth application-default login --no-launch-browser")
        elif auth == "oauth2" and not prereqs["oauth2_credentials"]["configured"]:
            errors.append("Colab OAuth2 credentials not configured. Run: .venv/bin/colab --auth=oauth2 usage")
        if not prereqs["gcloud_cli"]["installed"] and auth == "adc" and not prereqs["adc_credentials"]["configured"]:
            warns.append("gcloud CLI is not installed on PATH or ~/google-cloud-sdk/bin.")
        if prereqs["colab_ready"]:
            usage = cc.get_colab_usage(auth=auth)
            info["colab_usage"] = {k: usage.get(k) for k in ("status", "balance", "rate", "active_assignments", "message")}
            if usage.get("status") != "ok":
                errors.append(f"Colab usage check failed: {usage.get('message')}")
            elif isinstance(usage.get("balance"), (int, float)) and usage["balance"] < v["colab"]["min_cu_balance"]:
                errors.append(f"Colab balance {usage['balance']} CU is below safety floor ({v['colab']['min_cu_balance']} CU).")
        if v["base_source"] == "local_upload" and not (v["base_hf_path"] and os.path.isdir(v["base_hf_path"])):
            errors.append("base_source='local_upload' requires base_hf_path to point to a local weights directory.")
        if v["base_source"] == "hf_direct" and v["base_model"].lower().startswith("google/gemma") and not prereqs["hf_token"]["configured"]:
            warns.append("Gated model (google/gemma*) detected without HF_TOKEN in .george/keys.conf — Colab download will fail unless HF_TOKEN is configured.")
        info["colab_gpu_fallback"] = v["colab"]["gpu_fallback"]

    conv = find_converter(v)
    info["converter"] = conv
    if v["backend"] == "local" and not conv:
        warns.append("llama.cpp convert_lora_to_gguf.py not found locally — adapters stay PEFT-only unless llama_cpp_dir is set.")

    for t in v["tracks"]:
        try:
            with open(t["train_file"], encoding="utf-8") as fh:
                first = json.loads(fh.readline() or "{}")
        except (OSError, ValueError):
            errors.append(f"track {t['name']}: training file unreadable")
            continue
        if t["method"] == "dpo" and not {"prompt", "chosen", "rejected"} <= set(first):
            errors.append(f"track {t['name']}: DPO needs prompt/chosen/rejected rows (use forge dpo_*.jsonl)")
        if t["method"] == "sft" and {"chosen", "rejected"} <= set(first) and "messages" not in first:
            warns.append(f"track {t['name']}: looks like a preference file; did you mean method=dpo?")

    if os.path.isdir(os.path.join(runs_dir(), v["name"])):
        errors.append(f"run {v['name']} already exists — pick a new name")
    return {"errors": errors, "warnings": warns, "info": info}


def _track_conf(v, t, train_file, val_file, out_dir, ckpt_dir=None, export_gguf=None, gpu_tier=None):
    hyp = dict(v["hyper"])
    # Automatically scale micro-batch, grad_accum & max_seq_len when falling back to 16-24 GB VRAM GPUs
    if gpu_tier in ("L4", "T4"):
        if hyp["batch_size"] > 1:
            eff = hyp["batch_size"] * hyp["grad_accum"]
            hyp["batch_size"] = 1
            hyp["grad_accum"] = max(1, eff)
        seq_cap = 2048 if gpu_tier == "L4" else 1536
        if int(hyp.get("max_seq_len", 4096)) > seq_cap:
            hyp["max_seq_len"] = seq_cap
    conf = {
        "name": f"{v['name']}-{t['name']}", "base_model": v["base_model"],
        "train_file": train_file, "val_file": val_file, "mode": t["method"],
        **hyp, "adapter_gguf_dir": out_dir,
        "created_at": int(dt.datetime.now().timestamp()),
    }
    if ckpt_dir:
        conf["checkpoint_dir"] = ckpt_dir
    if export_gguf:
        conf["export_gguf"] = export_gguf
    if v["base_source"] == "drive_mirror" and v.get("drive_base_path"):
        conf["base_local_path"] = v["drive_base_path"]
    elif v["base_source"] == "local_upload" and v["backend"] == "colab":
        conf["base_local_path"] = "/content/base_model"
    if v.get("chat_template_file"):
        conf["chat_template_file"] = "chat_template.jinja"
    return conf


# ── Local Contention-Safe Training ─────────────────────────────────────────────

def start_local(v, rd, dry):
    q = shlex.quote
    tpy = v["train_python"] or cc.get_prerequisites()["local_train_env"].get("python") or sys.executable
    lines = [
        "#!/usr/bin/env bash",
        "# Generated by scripts/training/runs.py — contention-safe local GPU training driver.",
        "set -uo pipefail",
        f"cd {q(rd)}",
        "echo running > state",
        f"LEASE_FILE={q(os.path.join(GEORGE, 'ipc', 'training_gpu_lease.lock'))}",
        'mkdir -p "$(dirname "$LEASE_FILE")"',
        "INFERENCE_PAUSED=0",
        "restore_inference() {",
        '  rm -f "$LEASE_FILE" 2>/dev/null || true',
        '  if [ "$INFERENCE_PAUSED" = "1" ]; then',
        '    echo "[driver] Restoring local inference server..."',
        '    if command -v kubectl >/dev/null 2>&1 && kubectl -n "${K8S_NAMESPACE:-blue-lodge}" get deploy george-inference >/dev/null 2>&1; then',
        '      kubectl -n "${K8S_NAMESPACE:-blue-lodge}" scale deploy/george-inference --replicas=1 >/dev/null 2>&1 || true',
        '    elif command -v docker >/dev/null 2>&1; then',
        '      docker start george-prism-server >/dev/null 2>&1 || true',
        '    fi',
        '  fi',
        "}",
        "trap restore_inference EXIT INT TERM",
    ]
    if v["local"]["pause_inference"]:
        lines += [
            'echo "$$" > "$LEASE_FILE"',
            'echo "[driver] Acquiring cooperative GPU training lease (pausing local inference server)..."',
            'if command -v kubectl >/dev/null 2>&1 && kubectl -n "${K8S_NAMESPACE:-blue-lodge}" get deploy george-inference >/dev/null 2>&1; then',
            '  kubectl -n "${K8S_NAMESPACE:-blue-lodge}" scale deploy/george-inference --replicas=0 >/dev/null 2>&1 || true',
            '  INFERENCE_PAUSED=1',
            '  sleep 5',
            'elif command -v docker >/dev/null 2>&1 && docker ps --format "{{.Names}}" | grep -qx "george-prism-server"; then',
            '  docker stop george-prism-server >/dev/null 2>&1 || true',
            '  INFERENCE_PAUSED=1',
            '  sleep 3',
            'fi',
        ]
    lines += [
        "run_track() {",
        '  local n="$1" g="$2"; shift 2',
        '  ( cd "tracks/$n" || exit 1',
        "    echo running > state",
        f'    CUDA_VISIBLE_DEVICES="$g" PYTHONUNBUFFERED=1 {q(tpy)} train_lora.py --config config.json --resume-from-checkpoint latest "$@" > train.log 2>&1',
        '    rc=$?; echo "$rc" > exit_code',
        '    if [ "$rc" = 0 ]; then echo done > state; else echo failed > state; fi )',
        "}",
    ]
    by_gpu = {}
    for t in v["tracks"]:
        td = os.path.join(rd, "tracks", t["name"])
        os.makedirs(td, exist_ok=True)
        shutil.copyfile(KIT, os.path.join(td, "train_lora.py"))
        if v.get("chat_template_file") and os.path.isfile(v["chat_template_file"]):
            shutil.copyfile(v["chat_template_file"], os.path.join(td, "chat_template.jinja"))
        _write_json(os.path.join(td, "config.json"),
                    _track_conf(v, t, t["train_file"], t["val_file"], role_adapter_dir(v["model_slug"], v["role"]),
                                ckpt_dir=os.path.join(td, "checkpoints"), export_gguf=os.path.join(td, "adapter.gguf")))
        with open(os.path.join(td, "state"), "w") as fh:
            fh.write("queued\n")
        extra = ["--init-adapter", t["init_adapter"]] if t["init_adapter"] else []
        by_gpu.setdefault(t["gpu"], []).append(" ".join(["run_track", q(t["name"]), str(t["gpu"])] + [q(x) for x in extra]))
    for g, cmds in sorted(by_gpu.items()):
        lines.append("( " + " ; ".join(cmds) + " ) &")
    lines += ["wait"]
    if v["merge"]["method"] != "none":
        lines += [f"{q(sys.executable)} {q(os.path.abspath(__file__))} merge {q(v['name'])} > merge.log 2>&1 "
                  "&& echo staged_tier_b > state || echo merge_failed > state"]
    else:
        lines += ["grep -qx failed tracks/*/state && echo failed > state || echo done > state"]
    drv = os.path.join(rd, "driver.sh")
    with open(drv, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    os.chmod(drv, 0o755)
    meta = {
        "name": v["name"], "role": v["role"], "model_slug": v["model_slug"], "backend": "local",
        "created": dt.datetime.now().isoformat(timespec="seconds"), "spec": v,
        "state": "planned" if dry else "running", "pid": None, "gate_status": "pending",
    }
    if not dry:
        log = open(os.path.join(rd, "driver.log"), "ab")
        p = subprocess.Popen(["bash", drv], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                             start_new_session=True, cwd=rd, env={**os.environ, "GEORGE_DIR": GEORGE, "LODGE_DIR": LODGE})
        meta["pid"] = p.pid
    _write_json(os.path.join(rd, "run.json"), meta)
    return meta


# ── Google Colab 1-3x Fleet with GPU Fallback, Drive Checkpoints & Auto-Resume ─

def _colab(args, auth="adc", stdin=None, timeout=300):
    try:
        r = subprocess.run([COLAB_BIN, f"--auth={auth}"] + args, input=stdin, capture_output=True, text=True,
                           timeout=timeout, check=False)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return -1, "", f"colab command timed out after {timeout}s: {' '.join(args[:4])}"
    except OSError as e:
        return -1, "", str(e)


def _session(v, t):
    return re.sub(r"[^a-z0-9-]", "-", f"bl-{v['name']}-{t['name']}")[:60]


def _append_provision_log(td: str, msg: str) -> None:
    """Append a timestamped provisioning/dispatch line to tracks/<track>/provision.log immediately."""
    try:
        os.makedirs(td, exist_ok=True)
        ts = dt.datetime.now().strftime("%H:%M:%S")
        with open(os.path.join(td, "provision.log"), "a", encoding="utf-8") as fh:
            fh.write(f"[{ts}] {msg}\n")
            fh.flush()
    except OSError:
        pass


def _provision_with_fallback(session_name: str, v: dict, log_fn=None, on_step=None) -> tuple[str | None, list[dict]]:
    """Try provisioning Colab GPU tiers from strongest to weakest with live logging and incremental
    fallback_history persistence so the UI streams provisioning progress from second 1."""
    import time
    history = []
    auth = v["colab"]["auth"]
    max_attempts = int(v["colab"].get("retry_attempts", 3))
    base_backoff = int(v["colab"].get("retry_backoff_sec", 6))
    ladder = list(v["colab"]["gpu_fallback"])
    if log_fn:
        log_fn(f"Starting Colab GPU provisioning ladder for {session_name}: {' -> '.join(ladder)} (auth={auth})")
    for idx, tier in enumerate(ladder):
        shapes = [True, False] if (v["colab"]["high_mem"] and GPU_TIERS[tier]["high_mem"]) else [False]
        is_last = (idx == len(ladder) - 1)
        for use_hm in shapes:
            gpu_args = ["new", "-s", session_name, "--gpu", tier]
            if use_hm:
                gpu_args.append("--high-mem")
            shape_lbl = f"{tier} --high-mem" if use_hm else f"{tier} standard"
            # Try scarce speculative tiers (H100/G4) & --high-mem once quickly; cap workhorse retries at 2
            # so a full ladder stays under ~15m and stays polite to Google's /tun/m/assign endpoint.
            if use_hm and len(shapes) > 1:
                attempts = 1
            elif tier in ("H100", "G4") and not is_last:
                attempts = 1
            else:
                attempts = min(max_attempts, 2)
            for attempt in range(1, attempts + 1):
                if log_fn:
                    log_fn(f"Requesting Colab {shape_lbl} (attempt {attempt}/{attempts}, timeout=180s)...")
                t0 = time.time()
                # Never cut off `colab new` early (<150s) or Colab may finish assigning an orphaned [?] VM
                rc, out, err = _colab(gpu_args, auth=auth, timeout=180)
                elapsed = round(time.time() - t0, 1)
                if rc == 0:
                    history.append({"gpu": tier, "high_mem": use_hm, "attempt": attempt, "status": "provisioned", "elapsed_sec": elapsed})
                    if log_fn:
                        log_fn(f"[✓] Provisioned Colab {shape_lbl} in {elapsed}s")
                    if on_step:
                        on_step(history, tier)
                    return tier, history
                reason = (err or out or "provision failed").strip()[-220:]
                history.append({"gpu": tier, "high_mem": use_hm, "attempt": attempt, "status": "failed", "reason": reason, "elapsed_sec": elapsed})
                if log_fn:
                    log_fn(f"[!] {shape_lbl} attempt {attempt}/{attempts} failed ({elapsed}s): {reason}")
                if on_step:
                    on_step(history, None)
                _colab(["stop", "-s", session_name], auth=auth, timeout=30)
                low = reason.lower()
                if "rejected accelerator" in low or "precondition failed" in low or "too many active sessions" in low:
                    break
                if attempt < attempts:
                    wait_s = base_backoff * attempt
                    if log_fn:
                        log_fn(f"Backing off {wait_s}s before next {shape_lbl} retry...")
                    time.sleep(wait_s)
    if log_fn:
        log_fn("[✗] Exhausted Colab GPU fallback ladder (Colab allocator congested or unavailable). Use RESUME to retry.")
    return None, history


def _mint_headless_drive_auth() -> dict | None:
    """Mint a headless Google Drive REST v3 auth bundle with OAuth2 refresh credentials + quota_project_id (zero popups)."""
    try:
        import google.auth
        from google.auth.transport.requests import Request
        creds, proj = google.auth.default()
        creds.refresh(Request())
        adc_p = os.path.expanduser("~/.config/gcloud/application_default_credentials.json")
        adc_raw = _read_json(adc_p, {}) if os.path.isfile(adc_p) else {}
        qp = getattr(creds, "quota_project_id", None) or proj or adc_raw.get("quota_project_id", "") or ""
        with urllib.request.urlopen(f"https://oauth2.googleapis.com/tokeninfo?access_token={creds.token}", timeout=8) as r:
            info = json.loads(r.read())
        if "drive" not in (info.get("scope") or ""):
            return None
        ttl = int(info.get("expires_in") or 3500)
        return {
            "access_token": creds.token,
            "expires_at": int(time.time()) + max(60, ttl),
            "refresh_token": adc_raw.get("refresh_token") or getattr(creds, "refresh_token", "") or "",
            "client_id": adc_raw.get("client_id") or getattr(creds, "client_id", "") or "",
            "client_secret": adc_raw.get("client_secret") or getattr(creds, "client_secret", "") or "",
            "quota_project_id": qp,
        }
    except Exception:
        return None


def _refresh_bundle_kit(bundle_path: str) -> None:
    """Ensure bundle.tar.gz contains the latest scripts/training/kit/train_lora.py before upload/resume."""
    if not bundle_path or not os.path.isfile(bundle_path) or not os.path.isfile(KIT):
        return
    tmp_dir = tempfile.mkdtemp(prefix="bl_bundle_refresh_")
    tmp_tar = bundle_path + ".refresh.tmp"
    try:
        with tarfile.open(bundle_path, "r:gz") as tf:
            safe = [
                m for m in tf.getmembers()
                if not (m.name.startswith("/") or ".." in m.name.split("/"))
                and (m.isfile() or m.isdir())
            ]
            tf.extractall(tmp_dir, members=safe)  # noqa: S202
        shutil.copyfile(KIT, os.path.join(tmp_dir, "train_lora.py"))
        with tarfile.open(tmp_tar, "w:gz") as tf:
            tf.add(tmp_dir, arcname=".")
        os.replace(tmp_tar, bundle_path)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)
        if os.path.exists(tmp_tar):
            try:
                os.remove(tmp_tar)
            except OSError:
                pass


def _build_colab_launch_py(v: dict, s: str, remote: str, track_name: str, hf_token: str | None, drive_ok: bool = True, drive_auth_remote: str | None = None) -> str:
    drive_ckpt = f"/content/drive/MyDrive/BlueLodge/checkpoints/{v['name']}/{track_name}" if (v["colab"]["drive_checkpoints"] and drive_ok) else f"{remote}/checkpoints"
    export_gguf = f"{remote}/output/adapter.gguf" if v["colab"]["export_gguf_on_colab"] else ""
    unsloth_pip = "unsloth " if v["hyper"].get("use_unsloth") else ""
    hf_env = f"export HF_TOKEN={shlex.quote(hf_token)}; " if hf_token else ""
    drv_env = f"export GOOGLE_DRIVE_AUTH_FILE={shlex.quote(drive_auth_remote)}; " if drive_auth_remote else ""
    mirror_folder = f"BlueLodge/training/{v['name']}/{track_name}"
    mirror_flag = f"--drive-mirror-folder {shlex.quote(mirror_folder)}" if drive_auth_remote else ""
    ckpt_sync = bool(v["colab"].get("drive_checkpoint_sync", v["colab"].get("drive_checkpoints", True)))
    ckpt_keep = int(v["colab"].get("drive_checkpoint_keep", 2))
    ckpt_flag = f"--drive-checkpoint-sync --drive-checkpoint-keep {ckpt_keep}" if (drive_auth_remote and ckpt_sync) else ""
    export_flag = f"--export-gguf {shlex.quote(export_gguf)}" if export_gguf else ""
    cleanup_auth = f"rm -f {shlex.quote(drive_auth_remote)}; " if drive_auth_remote else ""
    return (
        "import subprocess, os\n"
        f"os.makedirs({remote!r}, exist_ok=True)\n"
        f"subprocess.run(['tar','-xzf','/content/{s}.tar.gz','-C',{remote!r}], check=True)\n"
        f"os.makedirs({drive_ckpt!r}, exist_ok=True)\n"
        + (f"if os.path.exists({drive_auth_remote!r}): os.chmod({drive_auth_remote!r}, 0o600)\n" if drive_auth_remote else "")
        + f"cmd = ({(hf_env + drv_env)!r}\n"
        f"       'pip install -q {unsloth_pip}\"torch>=2.3\" \"transformers>=4.45\" \"peft>=0.12\" \"trl>=0.11\" '\n"
        "       '\"datasets>=2.20\" accelerate bitsandbytes gguf > /content/pip.log 2>&1; '\n"
        f"       'cd {remote} && nohup python train_lora.py --config config.json '\n"
        f"       '--checkpoint-dir {shlex.quote(drive_ckpt)} --resume-from-checkpoint latest {export_flag} {mirror_flag} {ckpt_flag} > train.log 2>&1; '\n"
        f"       'rc=$?; echo $rc > exit_code; {cleanup_auth}'\n"
        f"       'tar -czf /content/{s}_adapter.tar.gz -C output .')\n"
        "subprocess.Popen(['bash', '-c', cmd])\nprint('DISPATCHED')\n"
    )


def start_colab(v, rd, execute):
    hf_token, _ = cc._read_key_from_files(("HF_TOKEN", "HUGGINGFACE_TOKEN", "HUGGING_FACE_HUB_TOKEN"))
    plan = []
    for t in v["tracks"]:
        td = os.path.join(rd, "tracks", t["name"])
        os.makedirs(td, exist_ok=True)
        stage = os.path.join(td, "bundle")
        os.makedirs(stage, exist_ok=True)
        shutil.copyfile(KIT, os.path.join(stage, "train_lora.py"))
        if v.get("chat_template_file") and os.path.isfile(v["chat_template_file"]):
            shutil.copyfile(v["chat_template_file"], os.path.join(stage, "chat_template.jinja"))
        shutil.copyfile(t["train_file"], os.path.join(stage, "train.jsonl"))
        if t["val_file"]:
            shutil.copyfile(t["val_file"], os.path.join(stage, "val.jsonl"))
        s = _session(v, t)
        remote = f"/content/{s}"
        conf = _track_conf(v, t, "train.jsonl", "val.jsonl" if t["val_file"] else None, f"{remote}/output")
        _write_json(os.path.join(stage, "config.json"), conf)
        tar = os.path.join(td, "bundle.tar.gz")
        with tarfile.open(tar, "w:gz") as tf:
            tf.add(stage, arcname=".")
        plan.append({
            "track": t["name"], "session": s, "remote_dir": remote, "bundle": tar,
            "gpu_fallback": v["colab"]["gpu_fallback"], "selected_gpu": None,
            "fallback_history": [], "resumes": 0,
        })
        with open(os.path.join(td, "state"), "w") as fh:
            fh.write("planned\n")
        shutil.rmtree(stage, ignore_errors=True)

    meta = {
        "name": v["name"], "role": v["role"], "model_slug": v["model_slug"], "backend": "colab",
        "created": dt.datetime.now().isoformat(timespec="seconds"), "spec": v,
        "state": "planned", "plan": plan, "gate_status": "pending",
    }
    if execute:
        auth = v["colab"]["auth"]
        active_limit = v["colab"]["max_concurrent_sessions"]
        meta["state"] = "running"
        _write_json(os.path.join(rd, "run.json"), meta)
        for idx, tp in enumerate(plan):
            if idx >= active_limit:
                # Queue remaining tracks for watchdog to launch once a slot frees
                with open(os.path.join(rd, "tracks", tp["track"], "state"), "w") as fh:
                    fh.write("queued\n")
                continue
            _launch_single_colab_track(v, rd, tp, hf_token, auth)
            _write_json(os.path.join(rd, "run.json"), meta)
    _write_json(os.path.join(rd, "run.json"), meta)
    return meta


def _launch_single_colab_track(v: dict, rd: str, tp: dict, hf_token: str | None, auth: str) -> bool:
    td = os.path.join(rd, "tracks", tp["track"])
    s = tp["session"]
    _write_text(os.path.join(td, "state"), "provisioning\n")
    _append_provision_log(td, f"Track '{tp['track']}' entering provisioning phase (model={v['base_model']})")

    def _on_prov_step(hist, sel_gpu):
        tp["fallback_history"] = list(hist)
        if sel_gpu:
            tp["selected_gpu"] = sel_gpu
        rj = os.path.join(rd, "run.json")
        cur = _read_json(rj, {})
        if cur and isinstance(cur.get("plan"), list):
            for p_item in cur["plan"]:
                if p_item.get("track") == tp["track"]:
                    p_item["fallback_history"] = list(hist)
                    if sel_gpu:
                        p_item["selected_gpu"] = sel_gpu
            _write_json(rj, cur)

    selected, hist = _provision_with_fallback(
        s, v, log_fn=lambda msg: _append_provision_log(td, msg), on_step=_on_prov_step
    )
    tp["selected_gpu"] = selected
    tp["fallback_history"] = hist
    tp["last_provision_attempt_at"] = int(dt.datetime.now().timestamp())
    if not selected:
        with open(os.path.join(td, "state"), "w") as fh:
            fh.write("failed\n")
        tp["error"] = "All Colab GPU fallback tiers failed: " + "; ".join(f"{h['gpu']}({h.get('reason','')[:60]})" for h in hist)
        return False

    _append_provision_log(td, f"Refreshing train_lora.py kit and preparing Drive auth for {selected}...")

    # Re-pack config if stepped down to lower VRAM tier (auto batch_size scaling)
    if selected in ("L4", "T4"):
        t_spec = next((x for x in v["tracks"] if x["name"] == tp["track"]), None)
        if t_spec:
            stage = os.path.join(td, "bundle_scaled")
            os.makedirs(stage, exist_ok=True)
            with tarfile.open(tp["bundle"], "r:gz") as tf:
                tf.extractall(stage)
            _write_json(os.path.join(stage, "config.json"),
                        _track_conf(v, t_spec, "train.jsonl", "val.jsonl" if t_spec["val_file"] else None, f"{tp['remote_dir']}/output", gpu_tier=selected))
            with tarfile.open(tp["bundle"], "w:gz") as tf:
                tf.add(stage, arcname=".")
            shutil.rmtree(stage, ignore_errors=True)

    # Always refresh train_lora.py inside bundle.tar.gz so resumes/re-runs never ship an older kit
    _refresh_bundle_kit(tp["bundle"])

    # Avoid interactive Colab drivemount popups by default; prefer headless ADC Drive REST v3 mirroring + token refresh
    drive_ok = False
    drive_auth = _mint_headless_drive_auth() if v["colab"].get("drive_checkpoints", True) else None
    drive_auth_remote = None
    if v["colab"].get("drive_checkpoints", True) and v["colab"].get("interactive_drivemount", False):
        rc_d, out_d, err_d = _colab(["drivemount", "-s", s, "/content/drive"], auth=auth, timeout=60)
        drive_ok = (rc_d == 0)
        if not drive_ok:
            tp["drive_mount_warning"] = (err_d or out_d or "drivemount failed").strip()[-200:]
            _colab(["restart-kernel", "-s", s], auth=auth, timeout=45)
    tp["drive_mounted"] = drive_ok
    tp["drive_rest_mirror"] = bool(drive_auth)
    tp["drive_checkpoint_sync"] = bool(drive_auth and v["colab"].get("drive_checkpoint_sync", True))
    tp["drive_token_refresh"] = bool(drive_auth and drive_auth.get("refresh_token"))

    if drive_auth:
        fd, local_auth = tempfile.mkstemp(prefix="bl_drive_auth_", suffix=".json")
        try:
            os.chmod(local_auth, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(drive_auth, fh)
            remote_auth = f"/content/{s}_drive_auth.json"
            rc_a, _, _ = _colab(["upload", "-s", s, local_auth, remote_auth], auth=auth, timeout=60)
            if rc_a == 0:
                drive_auth_remote = remote_auth
        finally:
            try:
                os.remove(local_auth)
            except OSError:
                pass

    # Upload dataset/code bundle (+ optional local base weights)
    _append_provision_log(td, f"Uploading bundle.tar.gz ({os.path.getsize(tp['bundle']) // 1024} KiB) to {s}...")
    rc, out, err = _colab(["upload", "-s", s, tp["bundle"], f"/content/{s}.tar.gz"], auth=auth, timeout=600)
    if rc != 0:
        tp["error"] = f"upload: {(err or out).strip()[-250:]}"
        _append_provision_log(td, f"[✗] Bundle upload failed: {tp['error']}")
        _colab(["stop", "-s", s], auth=auth, timeout=60)
        with open(os.path.join(td, "state"), "w") as fh:
            fh.write("failed\n")
        return False
    _append_provision_log(td, "[✓] Bundle uploaded; dispatching pip install + train_lora.py on Colab...")

    if v["base_source"] == "local_upload" and v.get("base_hf_path") and os.path.isdir(v["base_hf_path"]):
        base_tar = os.path.join(rd, "base_upload.tar.gz")
        if not os.path.isfile(base_tar):
            with tarfile.open(base_tar, "w:gz") as tf:
                tf.add(v["base_hf_path"], arcname="base_model")
        rc_b, out_b, err_b = _colab(["upload", "-s", s, base_tar, "/content/base_model.tar.gz"], auth=auth, timeout=1800)
        if rc_b == 0:
            _colab(["exec", "-s", s], auth=auth, stdin="import subprocess; subprocess.run(['tar','-xzf','/content/base_model.tar.gz','-C','/content'], check=True)\n", timeout=300)

    launch_py = _build_colab_launch_py(v, s, tp["remote_dir"], tp["track"], hf_token, drive_ok=drive_ok, drive_auth_remote=drive_auth_remote)
    rc, out, err = _colab(["exec", "-s", s], auth=auth, stdin=launch_py, timeout=180)
    if rc != 0 or "DISPATCHED" not in out:
        tp["error"] = f"launch: {(err or out).strip()[-250:]}"
        _colab(["stop", "-s", s], auth=auth, timeout=60)
        with open(os.path.join(td, "state"), "w") as fh:
            fh.write("failed\n")
        return False

    tp["started_at"] = dt.datetime.now().isoformat(timespec="seconds")
    with open(os.path.join(td, "state"), "w") as fh:
        fh.write("running\n")
    return True


def _recover_track_from_drive(run_name: str, track_name: str, td: str) -> bool:
    """If a Colab VM finished while the host was offline, recover final adapter.gguf + PEFT files from Google Drive."""
    auth = _mint_headless_drive_auth()
    if not auth or not auth.get("access_token"):
        return False
    hdr = {"Authorization": f"Bearer {auth['access_token']}"}
    if auth.get("quota_project_id"):
        hdr["X-Goog-User-Project"] = auth["quota_project_id"]

    parent = "root"
    for part in ("BlueLodge", "training", run_name, track_name):
        q = f"name='{part.replace(chr(39), '')}' and mimeType='application/vnd.google-apps.folder' and '{parent}' in parents and trashed=false"
        url = "https://www.googleapis.com/drive/v3/files?fields=files(id,name)&q=" + urllib.parse.quote(q)
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=hdr), timeout=15) as r:
                files = json.loads(r.read()).get("files", [])
            if not files:
                return False
            parent = files[0]["id"]
        except Exception:
            return False

    q = f"'{parent}' in parents and mimeType!='application/vnd.google-apps.folder' and trashed=false"
    url = "https://www.googleapis.com/drive/v3/files?fields=files(id,name,size)&pageSize=50&q=" + urllib.parse.quote(q)
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=hdr), timeout=15) as r:
            files = json.loads(r.read()).get("files", [])
    except Exception:
        return False

    names = {f.get("name") for f in files}
    if "adapter.gguf" not in names and "adapter_model.safetensors" not in names:
        return False

    adapter_dir = os.path.join(td, "output", "adapter")
    os.makedirs(adapter_dir, exist_ok=True)
    downloaded = 0
    for f in files:
        fn = f.get("name") or ""
        fid = f.get("id") or ""
        if not fn or not fid or "/" in fn or ".." in fn:
            continue
        if fn == "adapter.gguf":
            dest = os.path.join(td, "adapter.gguf")
        elif fn == "train.log":
            dest = os.path.join(td, "train.log")
        else:
            dest = os.path.join(adapter_dir, fn)
        try:
            dl_url = f"https://www.googleapis.com/drive/v3/files/{fid}?alt=media"
            with urllib.request.urlopen(urllib.request.Request(dl_url, headers=hdr), timeout=300) as r:
                with open(dest, "wb") as out:
                    shutil.copyfileobj(r, out)
            downloaded += 1
        except Exception:
            continue

    if downloaded > 0 and (os.path.isfile(os.path.join(td, "adapter.gguf")) or os.path.isfile(os.path.join(adapter_dir, "adapter_model.safetensors"))):
        for root_p, dirs_p, files_p in os.walk(os.path.join(td, "output")):
            try:
                os.chmod(root_p, 0o775)
            except OSError:
                pass
            for fn_p in files_p:
                try:
                    os.chmod(os.path.join(root_p, fn_p), 0o664)
                except OSError:
                    pass
        _write_text(os.path.join(td, "state"), "done\n")
        return True
    return False


def _is_actively_provisioning(td: str, stale_after_sec: int = 1500) -> bool:
    """Return True if track state is 'provisioning' and provision.log was updated recently (< 25m)."""
    if track_status(td)["state"] != "provisioning":
        return False
    pl = os.path.join(td, "provision.log")
    st_p = os.path.join(td, "state")
    ref = pl if os.path.isfile(pl) else st_p
    try:
        age = dt.datetime.now().timestamp() - os.path.getmtime(ref)
        return age < stale_after_sec
    except OSError:
        return True


def resume_colab(name: str) -> dict:
    """Re-provision disconnected/timed-out Colab tracks and resume cleanly from Drive checkpoints."""
    rd = run_dir(name)
    meta = _read_json(os.path.join(rd, "run.json"), {})
    if meta.get("backend") != "colab":
        raise SpecError("resume is only for colab runs")
    v = meta["spec"]
    auth = v["colab"]["auth"]
    hf_token, _ = cc._read_key_from_files(("HF_TOKEN", "HUGGINGFACE_TOKEN", "HUGGING_FACE_HUB_TOKEN"))
    resumed = {}
    any_running = False
    now_ts = int(dt.datetime.now().timestamp())
    cooldown_sec = int(v["colab"].get("provision_cooldown_sec", 600))
    for tp in meta.get("plan", []):
        td = os.path.join(rd, "tracks", tp["track"])
        st = track_status(td)["state"]
        if st in ("done", "planned", "queued"):
            resumed[tp["track"]] = f"skip_{st}"
            continue
        if _is_actively_provisioning(td):
            resumed[tp["track"]] = "still_provisioning"
            any_running = True
            continue
        last_try = int(tp.get("last_provision_attempt_at") or 0)
        if st == "failed" and not tp.get("selected_gpu") and last_try > 0 and (now_ts - last_try) < cooldown_sec:
            rem = cooldown_sec - (now_ts - last_try)
            resumed[tp["track"]] = f"cooldown_{rem}s"
            any_running = True
            continue
        if int(tp.get("resumes", 0)) >= 6:
            resumed[tp["track"]] = "max_resumes_reached"
            continue
        # Check if session is still alive before re-provisioning
        rc, out, _ = _colab(["exec", "-s", tp["session"]], auth=auth, stdin="print('ALIVE')\n", timeout=30)
        if rc == 0 and "ALIVE" in out:
            resumed[tp["track"]] = "still_alive"
            any_running = True
            continue
        # Before re-provisioning, check if the track already finished and mirrored to Drive while host was offline
        if _recover_track_from_drive(name, tp["track"], td):
            resumed[tp["track"]] = "recovered_from_drive"
            continue
        _colab(["stop", "-s", tp["session"]], auth=auth, timeout=60)
        tp["resumes"] = int(tp.get("resumes", 0)) + 1
        ok = _launch_single_colab_track(v, rd, tp, hf_token, auth)
        if ok:
            any_running = True
            meta["state"] = "running"
            _write_text(os.path.join(rd, "state"), "running\n")
            _write_json(os.path.join(rd, "run.json"), meta)
        resumed[tp["track"]] = f"resumed_on_{tp.get('selected_gpu')}" if ok else f"resume_failed: {tp.get('error')}"
    if any_running:
        meta["state"] = "running"
        _write_text(os.path.join(rd, "state"), "running\n")
    _write_json(os.path.join(rd, "run.json"), meta)
    return {"name": name, "resumed": resumed}


def collect_colab(name):
    rd = run_dir(name)
    meta = _read_json(os.path.join(rd, "run.json"), {})
    if meta.get("backend") != "colab":
        raise SpecError("collect is only for colab runs")
    v = meta["spec"]
    auth = v["colab"]["auth"]
    res = {}
    for tp in meta.get("plan", []):
        td = os.path.join(rd, "tracks", tp["track"])
        st_cur = track_status(td)["state"]
        if st_cur in ("done", "planned", "queued"):
            res[tp["track"]] = st_cur
            continue
        if _is_actively_provisioning(td):
            res[tp["track"]] = "still_provisioning"
            continue
        s = tp["session"]
        rc, out, _ = _colab(["exec", "-s", s], auth=auth, stdin=(
            "import os\n"
            f"ec = '{tp['remote_dir']}/exit_code'\n"
            f"lg = '{tp['remote_dir']}/train.log'\n"
            "print('EXIT', open(ec).read().strip() if os.path.exists(ec) else 'running')\n"
            "if os.path.exists(lg): print('TAIL::' + open(lg, errors='ignore').read()[-32000:])\n"
        ), timeout=120)
        if rc != 0:
            if _recover_track_from_drive(name, tp["track"], td):
                res[tp["track"]] = "recovered_from_drive"
            else:
                res[tp["track"]] = "session_disconnected (run 'runs.py resume' to continue from Drive checkpoint)"
            continue
        if "TAIL::" in out:
            tail_txt = out.split("TAIL::", 1)[1]
            with open(os.path.join(td, "train.log"), "w", encoding="utf-8") as fh:
                fh.write(tail_txt)
        status_tok = (out.split("EXIT", 1)[-1].split()[0].strip() if "EXIT" in out else "unknown")
        if status_tok == "running":
            res[tp["track"]] = "still running"
            continue
        if status_tok == "0":
            local = os.path.join(td, "adapter.tar.gz")
            rc_d, _, err_d = _colab(["download", "-s", s, f"/content/{s}_adapter.tar.gz", local], auth=auth, timeout=900)
            if rc_d == 0 and os.path.isfile(local):
                with tarfile.open(local) as tf:
                    safe = [m for m in tf.getmembers() if not (m.name.startswith("/") or ".." in m.name.split("/"))
                            and (m.isfile() or m.isdir())]
                    out_dir = os.path.join(td, "output")
                    os.makedirs(out_dir, exist_ok=True)
                    tf.extractall(out_dir, members=safe)  # noqa: S202
                # Normalize modes (safetensors saves 0600 on Colab; root container extraction otherwise blocks host user)
                for root_p, _, files_p in os.walk(out_dir):
                    try:
                        os.chmod(root_p, 0o775)
                    except OSError:
                        pass
                    for fn_p in files_p:
                        try:
                            os.chmod(os.path.join(root_p, fn_p), 0o664)
                        except OSError:
                            pass
                # Promote in-Colab exported adapter.gguf and structured metrics.jsonl if present
                colab_gguf = os.path.join(td, "output", "adapter.gguf")
                if os.path.isfile(colab_gguf):
                    shutil.copyfile(colab_gguf, os.path.join(td, "adapter.gguf"))
                colab_metrics = os.path.join(td, "output", "metrics.jsonl")
                if os.path.isfile(colab_metrics):
                    shutil.copyfile(colab_metrics, os.path.join(td, "metrics.jsonl"))
                _write_text(os.path.join(td, "state"), "done\n")
                res[tp["track"]] = "downloaded"
            else:
                res[tp["track"]] = f"download failed: {err_d.strip()[-200:]}"
                continue
        else:
            with open(os.path.join(td, "state"), "w") as fh:
                fh.write("failed\n")
            res[tp["track"]] = f"training exited {status_tok}"
        _colab(["stop", "-s", s], auth=auth, timeout=60)

    track_states = [track_status(os.path.join(rd, "tracks", t["name"]))["state"] for t in v["tracks"]]
    if track_states and all(x == "done" for x in track_states):
        with open(os.path.join(rd, "state"), "w") as fh:
            fh.write("done\n")
    elif any(x == "failed" for x in track_states) and all(x in ("done", "failed") for x in track_states):
        with open(os.path.join(rd, "state"), "w") as fh:
            fh.write("failed\n")
    return res


STEP_RX = re.compile(r"(\d+)%\|[^|]*\|\s*(\d+)/(\d+)\s*\[([^<\]]+)<([^,\]]+),\s*([^\]]+)\]")


def _parse_log_progress(txt: str) -> dict:
    prog = {"step": None, "total_steps": None, "pct": None, "elapsed": None, "eta": None, "speed": None, "loss": None, "eval_loss": None}
    if not txt:
        return prog
    ms = STEP_RX.findall(txt)
    if ms:
        pct, cur, tot, elap, eta, spd = ms[-1]
        prog.update({
            "pct": int(pct), "step": int(cur), "total_steps": int(tot),
            "elapsed": elap.strip(), "eta": eta.strip(), "speed": spd.strip(),
        })
    lm = LOSS_RX.findall(txt)
    if lm:
        try:
            prog["loss"] = round(float(lm[-1][0]), 4)
        except ValueError:
            pass
    em = EVAL_RX.findall(txt)
    if em:
        try:
            prog["eval_loss"] = round(float(em[-1]), 4)
        except ValueError:
            pass
    return prog


_LOG_DICT_RX = re.compile(r"\{[^{}]*(?:'loss'|'eval_loss'|'rewards/margins')[^{}]*\}")


def _parse_metrics_series(metrics_jsonl_path: str | None, log_text: str) -> list[dict]:
    """Load structured per-step metrics from metrics.jsonl, or parse HF Trainer dict lines from train.log."""
    pts: list[dict] = []
    if metrics_jsonl_path and os.path.isfile(metrics_jsonl_path):
        try:
            with open(metrics_jsonl_path, encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                        if isinstance(rec, dict):
                            pts.append(rec)
                    except ValueError:
                        continue
        except OSError:
            pass
    if pts:
        return pts[-400:]

    # Fallback for older runs without metrics.jsonl: parse HF Trainer dict log lines
    if not log_text:
        return []
    import ast
    step_idx = 0
    for m in _LOG_DICT_RX.finditer(log_text):
        raw = m.group(0)
        try:
            d = ast.literal_eval(raw)
        except Exception:
            continue
        if not isinstance(d, dict):
            continue
        step_idx += 1
        rec = {"step": step_idx, "epoch": float(d.get("epoch", 0.0) or 0.0)}
        for k in ("loss", "eval_loss", "grad_norm", "learning_rate", "mean_token_accuracy",
                  "rewards/chosen", "rewards/rejected", "rewards/margins", "rewards/accuracies",
                  "eval_rewards/margins", "eval_rewards/accuracies"):
            if k in d and isinstance(d[k], (int, float)):
                rec[k] = round(float(d[k]), 6)
        if len(rec) > 2:
            pts.append(rec)
    return pts[-400:]


def _summarize_metrics(pts: list[dict]) -> dict:
    if not pts:
        return {"points": 0}
    losses = [p["loss"] for p in pts if isinstance(p.get("loss"), (int, float))]
    elosses = [p["eval_loss"] for p in pts if isinstance(p.get("eval_loss"), (int, float))]
    margins = [p["rewards/margins"] for p in pts if isinstance(p.get("rewards/margins"), (int, float))]
    accs = [p["rewards/accuracies"] for p in pts if isinstance(p.get("rewards/accuracies"), (int, float))]
    gnorms = [p["grad_norm"] for p in pts if isinstance(p.get("grad_norm"), (int, float))]
    tok_accs = [p["mean_token_accuracy"] for p in pts if isinstance(p.get("mean_token_accuracy"), (int, float))]
    out = {"points": len(pts)}
    if losses:
        out.update({"first_loss": losses[0], "min_loss": min(losses), "final_loss": losses[-1]})
    if elosses:
        out["final_eval_loss"] = elosses[-1]
    if margins:
        out.update({"first_margin": margins[0], "max_margin": max(margins), "final_margin": margins[-1]})
    if accs:
        out["final_reward_acc"] = accs[-1]
    if tok_accs:
        out["final_token_acc"] = tok_accs[-1]
    if gnorms:
        out["max_grad_norm"] = max(gnorms)
    return out


def _detect_training_phase(track_state: str, exit_code: str, log_text: str, source: str) -> str:
    if exit_code == "0" or track_state == "done":
        return "done"
    if track_state in ("failed", "cancelled") or (exit_code not in ("running", "unknown", "0") and str(exit_code).isdigit()):
        return "failed"
    if track_state == "provisioning" or source == "provision_log":
        return "provisioning"
    if track_state == "queued":
        return "queued"
    low = (log_text or "")[-4000:].lower()
    if "exporting gguf" in low or "convert_lora_to_gguf" in low:
        return "exporting_gguf"
    if "mirrored to google drive" in low or "saved peft adapter" in low or "saved dpo-tuned" in low:
        return "saving_adapter"
    if "%|" in low or "'loss':" in low or "rewards/margins" in low:
        return "training"
    if "loading" in low and ("fastlanguagemodel" in low or "checkpoint shards" in low or "downloading" in low):
        return "loading_model"
    if "[pip install]" in low:
        return "installing_deps"
    return track_state or "running"


def stream_logs(name: str, track: str | None = None, live: bool = True, lines: int = 80) -> dict:
    """Fetch live or cached training logs, provisioning history, structured metrics.jsonl & GPU telemetry
    (works for both Colab and local runs, from second 1 of provisioning through completion)."""
    rd = run_dir(name)
    meta = _read_json(os.path.join(rd, "run.json"), {})
    if not meta:
        raise SpecError(f"run '{name}' not found")
    backend = meta.get("backend", "local")
    tracks_meta = meta.get("plan") or [{"track": t["name"]} for t in (meta.get("spec") or {}).get("tracks", [])]
    track_names = [t.get("track") for t in tracks_meta if t.get("track")]
    if not track_names:
        raise SpecError(f"run '{name}' has no tracks")
    sel_name = track if (track and track in track_names) else track_names[0]
    tp = next((t for t in tracks_meta if t.get("track") == sel_name), {"track": sel_name})
    td = os.path.join(rd, "tracks", sel_name)
    os.makedirs(td, exist_ok=True)
    cached_log = os.path.join(td, "train.log")
    prov_log = os.path.join(td, "provision.log")
    cached_metrics = os.path.join(td, "metrics.jsonl")
    out_metrics = os.path.join(td, "output", "metrics.jsonl")
    t_state = track_status(td).get("state", "unknown")

    gpu_info = None
    exit_code = "unknown"
    log_text = ""
    source = "cached_file"
    live_err = None

    # Only probe Colab exec once a GPU has actually been provisioned (skip noisy errors while provisioning)
    if backend == "colab" and live and tp.get("session") and (tp.get("selected_gpu") or t_state == "running"):
        auth = (meta.get("spec") or {}).get("colab", {}).get("auth", "adc")
        s = tp["session"]
        remote = tp.get("remote_dir") or f"/content/{s}"
        probe = (
            "import os, json, subprocess\n"
            "gpu = None\n"
            "try:\n"
            "    raw = subprocess.getoutput('nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits').strip().splitlines()[0]\n"
            "    p = [x.strip() for x in raw.split(',')]\n"
            "    if len(p) >= 4: gpu = {'name': p[0], 'used_mb': int(p[1]), 'total_mb': int(p[2]), 'util_pct': int(p[3])}\n"
            "except Exception: pass\n"
            f"ec_p = {remote + '/exit_code'!r}\n"
            "ec = open(ec_p).read().strip() if os.path.exists(ec_p) else 'running'\n"
            f"lg_p = {remote + '/train.log'!r}\n"
            f"mt_p = {remote + '/output/metrics.jsonl'!r}\n"
            "tail = ''\n"
            "if os.path.exists(lg_p): tail = open(lg_p, errors='ignore').read()[-24000:]\n"
            "elif os.path.exists('/content/pip.log'): tail = '[pip install]\\n' + open('/content/pip.log', errors='ignore').read()[-6000:]\n"
            "metrics_raw = open(mt_p, errors='ignore').read()[-32000:] if os.path.exists(mt_p) else ''\n"
            "print('BL_LOG_JSON::' + json.dumps({'gpu': gpu, 'exit_code': ec, 'tail': tail, 'metrics_raw': metrics_raw}))\n"
        )
        rc, out, err = _colab(["exec", "-s", s, "--timeout", "25"], auth=auth, stdin=probe, timeout=40)
        if rc == 0 and "BL_LOG_JSON::" in out:
            try:
                payload = json.loads(out.split("BL_LOG_JSON::", 1)[1].strip().splitlines()[0])
                gpu_info = payload.get("gpu")
                exit_code = payload.get("exit_code", "running")
                log_text = payload.get("tail", "")
                source = "colab_live"
                if log_text:
                    with open(cached_log, "w", encoding="utf-8") as fh:
                        fh.write(log_text)
                mraw = payload.get("metrics_raw") or ""
                if mraw:
                    with open(cached_metrics, "w", encoding="utf-8") as fh:
                        fh.write(mraw)
            except (ValueError, IndexError) as e:
                live_err = f"parse error: {e}"
        else:
            live_err = (err or out or "colab session unreachable").strip()[-200:]

    if not log_text and os.path.isfile(cached_log):
        try:
            log_text = open(cached_log, encoding="utf-8", errors="ignore").read()[-24000:]
            source = "local_file" if backend == "local" else "cached_file"
        except OSError:
            pass

    # Provisioning / fallback-history live stream before train.log exists!
    prov_text = ""
    if os.path.isfile(prov_log):
        try:
            prov_text = open(prov_log, encoding="utf-8", errors="ignore").read()[-12000:]
        except OSError:
            pass
    if not log_text:
        if prov_text:
            log_text = prov_text
            source = "provision_log"
        elif tp.get("fallback_history") or tp.get("error"):
            lines_fb = []
            for h in (tp.get("fallback_history") or []):
                hm = " --high-mem" if h.get("high_mem") else ""
                lines_fb.append(f"[fallback] {h.get('gpu')}{hm} attempt {h.get('attempt')}: {h.get('status')} — {h.get('reason', 'ok')}")
            if tp.get("error"):
                lines_fb.append(f"[error] {tp['error']}")
            log_text = "\n".join(lines_fb)
            source = "provision_log"
        elif t_state in ("provisioning", "planned", "queued"):
            log_text = f"[{dt.datetime.now().strftime('%H:%M:%S')}] Track '{sel_name}' is {t_state} (waiting for Colab GPU assignment on ladder: {' -> '.join((meta.get('spec') or {}).get('colab', {}).get('gpu_fallback', ['H100','G4','A100']))})..."
            source = "provision_log"

    if backend == "local":
        ec_p = os.path.join(td, "exit_code")
        exit_code = open(ec_p).read().strip() if os.path.isfile(ec_p) else t_state
        if live and shutil.which("nvidia-smi"):
            try:
                raw = subprocess.check_output(
                    ["nvidia-smi", "--query-gpu=name,memory.used,memory.total,utilization.gpu", "--format=csv,noheader,nounits"],
                    text=True, timeout=5,
                ).strip().splitlines()[0]
                p = [x.strip() for x in raw.split(",")]
                if len(p) >= 4:
                    gpu_info = {"name": p[0], "used_mb": int(p[1]), "total_mb": int(p[2]), "util_pct": int(p[3])}
            except Exception:
                pass
    elif exit_code == "unknown":
        exit_code = t_state

    metrics_file = cached_metrics if os.path.isfile(cached_metrics) else (out_metrics if os.path.isfile(out_metrics) else None)
    metrics_pts = _parse_metrics_series(metrics_file, log_text)
    summary_stats = _summarize_metrics(metrics_pts)
    phase = _detect_training_phase(t_state, str(exit_code), log_text, source)

    cleaned_lines = []
    for raw_line in log_text.splitlines():
        seg = raw_line.split("\r")[-1]
        if seg.strip():
            cleaned_lines.append(seg)
    tail_lines = cleaned_lines[-max(10, min(300, int(lines))):]
    return {
        "status": "ok",
        "run": name,
        "backend": backend,
        "track": sel_name,
        "tracks": track_names,
        "track_state": t_state,
        "phase": phase,
        "session": tp.get("session"),
        "selected_gpu": tp.get("selected_gpu"),
        "fallback_history": tp.get("fallback_history") or [],
        "exit_code": exit_code,
        "gpu": gpu_info,
        "progress": _parse_log_progress(log_text),
        "metrics": metrics_pts,
        "summary_stats": summary_stats,
        "log_tail": "\n".join(tail_lines),
        "source": source,
        "live_error": live_err,
        "ts": dt.datetime.now().isoformat(timespec="seconds"),
    }


def inspect_colab_sessions(probe: bool = False) -> dict:
    """List every live Colab GPU assignment on Google's backend and classify active vs stale/orphaned VMs."""
    import contextlib
    try:
        with contextlib.redirect_stdout(sys.stderr):
            from colab_cli.common import state as cstate
            from colab_cli.auth import AuthProvider
            cstate.auth_provider = AuthProvider.ADC
            client = cstate.client
            assignments = client.list_assignments()
    except Exception as e:
        return {"status": "error", "message": f"Colab API unavailable: {e}", "sessions": [], "stale_count": 0}

    # Map endpoint -> local session name
    ep_to_sess = {}
    try:
        for item in cstate.store.list():
            s = cstate.store.get(item) if isinstance(item, str) else item
            if s and getattr(s, "endpoint", None):
                ep_to_sess[s.endpoint] = getattr(s, "name", item if isinstance(item, str) else s.endpoint)
    except Exception:
        pass

    # Map session name -> (run_name, track_name, run_state, track_state, remote_dir)
    # Read run.json directly because list_runs() returns summary status without the raw plan list.
    sess_to_run = {}
    for rj in glob.glob(os.path.join(runs_dir(), "*", "run.json")):
        meta = _read_json(rj)
        if not meta:
            continue
        rname = meta.get("name") or os.path.basename(os.path.dirname(rj))
        rd = os.path.dirname(rj)
        st_file = os.path.join(rd, "state")
        rstate = open(st_file).read().strip() if os.path.isfile(st_file) else meta.get("state")
        for tp in meta.get("plan") or []:
            sn = tp.get("session")
            if sn:
                td = os.path.join(rd, "tracks", tp.get("track", ""))
                sess_to_run[sn] = {
                    "run": rname, "track": tp.get("track"), "run_state": rstate,
                    "track_state": track_status(td).get("state") if os.path.isdir(td) else "unknown",
                    "remote_dir": tp.get("remote_dir") or f"/content/{sn}",
                }

    def _probe_one(sess_name: str, remote_dir: str) -> dict:
        pcode = (
            "import os, json, subprocess\n"
            "gpu = None\n"
            "try:\n"
            "    raw = subprocess.getoutput('nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits').strip().splitlines()[0]\n"
            "    p = [x.strip() for x in raw.split(',')]\n"
            "    if len(p) >= 4: gpu = {'name': p[0], 'used_mb': int(p[1]), 'total_mb': int(p[2]), 'util_pct': int(p[3])}\n"
            "except Exception: pass\n"
            f"ec_p = {remote_dir + '/exit_code'!r}\n"
            "ec = open(ec_p).read().strip() if os.path.exists(ec_p) else 'running'\n"
            "alive = bool(subprocess.getoutput('pgrep -f \"train_lora.py|pip install|convert_lora\"').strip())\n"
            "print('BL_PROBE::' + json.dumps({'gpu': gpu, 'exit_code': ec, 'alive': alive}))\n"
        )
        rc, out, _ = _colab(["exec", "-s", sess_name, "--timeout", "25"], auth="adc", stdin=pcode, timeout=35)
        if rc == 0 and "BL_PROBE::" in out:
            try:
                return json.loads(out.split("BL_PROBE::", 1)[1].strip().splitlines()[0])
            except ValueError:
                pass
        return {}

    probe_results = {}
    if probe:
        from concurrent.futures import ThreadPoolExecutor
        to_probe = []
        for a in assignments:
            ep = getattr(a, "endpoint", "")
            sess = ep_to_sess.get(ep)
            if sess:
                rm = sess_to_run.get(sess)
                to_probe.append((sess, rm["remote_dir"] if rm else f"/content/{sess}"))
        if to_probe:
            with ThreadPoolExecutor(max_workers=min(4, len(to_probe))) as ex:
                futs = {ex.submit(_probe_one, s, rdir): s for s, rdir in to_probe}
                for fut, s in futs.items():
                    try:
                        probe_results[s] = fut.result(timeout=40)
                    except Exception:
                        probe_results[s] = {}

    rows = []
    for a in assignments:
        ep = getattr(a, "endpoint", "")
        acc_raw = getattr(a, "accelerator", "")
        acc = acc_raw.value if hasattr(acc_raw, "value") else str(acc_raw)
        sess = ep_to_sess.get(ep)
        rm = sess_to_run.get(sess) if sess else None

        health = "active"
        reason = "Mapped to active training track"
        gpu_info = None
        proc_alive = None
        exit_code = None

        if not sess:
            health = "orphaned"
            reason = "Orphaned Colab VM (untracked in local session store; burning CU)"
        elif not rm:
            health = "orphaned"
            reason = f"Session '{sess}' has no matching run in .george/training/runs/"
        elif rm["track_state"] in ("done", "failed", "cancelled") or (
            rm["run_state"] in ("done", "failed", "cancelled") and rm["track_state"] != "running"
        ):
            health = "stale_finished"
            reason = f"Run '{rm['run']}' track '{rm['track']}' is already {rm['track_state']}/{rm['run_state']}"

        if probe and sess and probe_results.get(sess):
            pd = probe_results[sess]
            gpu_info = pd.get("gpu")
            exit_code = pd.get("exit_code")
            proc_alive = pd.get("alive")
            if exit_code not in (None, "running"):
                health = "stale_finished"
                reason = f"Training exited with code {exit_code} (VM still running idle)"
            elif proc_alive is True:
                health = "active"
                reason = "Live probe confirmed active training process on GPU"
            elif proc_alive is False and gpu_info and gpu_info.get("used_mb", 0) < 1000 and gpu_info.get("util_pct", 0) == 0:
                health = "stale_idle"
                reason = "No training process running and GPU is idle (0% util, <1 GiB VRAM)"

        rows.append({
            "endpoint": ep,
            "accelerator": acc,
            "session": sess,
            "run": rm["run"] if rm else None,
            "track": rm["track"] if rm else None,
            "run_state": rm["run_state"] if rm else None,
            "health": health,
            "stale": health != "active",
            "reason": reason,
            "gpu": gpu_info,
            "exit_code": exit_code,
            "proc_alive": proc_alive,
        })

    stale = [r for r in rows if r["stale"]]
    res = {
        "status": "ok",
        "total": len(rows),
        "active_count": len(rows) - len(stale),
        "stale_count": len(stale),
        "sessions": rows,
        "ts": dt.datetime.now().isoformat(timespec="seconds"),
        "updated_at": int(dt.datetime.now().timestamp()),
    }
    try:
        _write_json(os.path.join(GEORGE, "training", "colab_sessions_cache.json"), res)
    except OSError:
        pass
    return res


def cull_colab_vm(target: str | None = None, all_stale: bool = False) -> dict:
    """Terminate a specific Colab VM (by session name or raw endpoint) or cull all stale/orphaned VMs."""
    import contextlib
    try:
        with contextlib.redirect_stdout(sys.stderr):
            from colab_cli.common import state as cstate
            from colab_cli.auth import AuthProvider
            cstate.auth_provider = AuthProvider.ADC
            client = cstate.client
    except Exception as e:
        return {"status": "error", "message": f"Colab API unavailable: {e}"}

    culled = []
    errors = []
    if all_stale:
        snap = inspect_colab_sessions(probe=True)
        for row in snap.get("sessions", []):
            if not row.get("stale"):
                continue
            ep = row["endpoint"]
            try:
                client.unassign(ep)
                if row.get("session"):
                    try:
                        cstate.prune_session(row["session"])
                    except Exception:
                        pass
                culled.append({"endpoint": ep, "session": row.get("session"), "accelerator": row.get("accelerator"), "reason": row.get("reason")})
            except Exception as e:
                errors.append({"endpoint": ep, "error": str(e)})
        return {"status": "ok", "mode": "all_stale", "culled": culled, "errors": errors}

    if not target:
        raise SpecError("Provide --target <endpoint_or_session> or --all-stale")

    # Resolve target as either a local session name or raw Colab endpoint
    ep = target
    sess_name = None
    try:
        s = cstate.store.get(target)
        if s and getattr(s, "endpoint", None):
            ep = s.endpoint
            sess_name = target
        else:
            for item in cstate.store.list():
                s2 = cstate.store.get(item) if isinstance(item, str) else item
                if s2 and getattr(s2, "endpoint", None) == target:
                    sess_name = getattr(s2, "name", item if isinstance(item, str) else None)
                    break
    except Exception:
        pass

    try:
        client.unassign(ep)
        if sess_name:
            try:
                cstate.prune_session(sess_name)
            except Exception:
                pass
        culled.append({"endpoint": ep, "session": sess_name})
    except Exception as e:
        return {"status": "error", "message": f"Failed to unassign {ep}: {e}"}

    return {"status": "ok", "mode": "single", "culled": culled, "errors": errors}


# ── Status, Merge (SVD-32 Retention Lineage), Tier B Gate & Live Hot-Swap ──────

def _alive(pid):
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def track_status(td):
    st = {"state": (open(os.path.join(td, "state")).read().strip() if os.path.isfile(os.path.join(td, "state")) else "?")}
    log = os.path.join(td, "train.log")
    if os.path.isfile(log):
        with open(log, encoding="utf-8", errors="ignore") as fh:
            fh.seek(max(0, os.path.getsize(log) - 200000))
            tail = fh.read()
        losses = LOSS_RX.findall(tail)
        if losses:
            st["loss"], st["epoch"] = float(losses[-1][0]), float(losses[-1][1])
            st["loss_points"] = [float(x[0]) for x in losses[-50:]]
        ev = EVAL_RX.findall(tail)
        if ev:
            st["eval_loss"] = float(ev[-1])
        mg = MARGIN_RX.findall(tail)
        if mg:
            st["dpo_margin"] = float(mg[-1])
        st["log_tail"] = "\n".join(tail.strip().splitlines()[-4:])[-600:]
    if os.path.isdir(os.path.join(td, "output", "adapter")):
        st["adapter"] = os.path.join(td, "output", "adapter")
    if os.path.isfile(os.path.join(td, "adapter.gguf")):
        st["gguf"] = os.path.join(td, "adapter.gguf")
    return st


def status(name):
    rd = run_dir(name)
    meta = _read_json(os.path.join(rd, "run.json"))
    if not meta:
        raise SpecError(f"no run named {name}")
    run_state = open(os.path.join(rd, "state")).read().strip() if os.path.isfile(os.path.join(rd, "state")) else meta.get("state")
    if meta.get("backend") == "local" and run_state == "running" and not _alive(meta.get("pid")):
        run_state = "stopped"
    spec = meta.get("spec") or {}
    tracks = {t["name"]: track_status(os.path.join(rd, "tracks", t["name"])) for t in spec.get("tracks", [])}
    # Enrich tracks with Colab GPU fallback details if present
    for tp in meta.get("plan", []):
        if tp["track"] in tracks:
            tracks[tp["track"]]["selected_gpu"] = tp.get("selected_gpu")
            tracks[tp["track"]]["fallback_history"] = tp.get("fallback_history", [])
            tracks[tp["track"]]["resumes"] = tp.get("resumes", 0)
            if tp.get("error"):
                tracks[tp["track"]]["error"] = tp["error"]
    merged = _read_json(os.path.join(rd, "merged.json"))
    bench = _read_json(os.path.join(rd, "benchmark.json"))
    bench_st = _read_json(os.path.join(rd, "benchmark_status.json"))
    return {
        "name": name, "role": meta.get("role", spec.get("role", "core-agent")),
        "model_slug": meta.get("model_slug", spec.get("model_slug", "")),
        "base_model": spec.get("base_model", ""),
        "backend": meta.get("backend"), "state": run_state, "created": meta.get("created"),
        "gate_status": meta.get("gate_status", "pending"),
        "prior_adapter_weight": (spec.get("merge") or {}).get("prior_adapter_weight", 0.70),
        "tracks": tracks, "merged": merged, "benchmark": bench, "benchmark_status": bench_st, "dir": rd,
    }


def list_runs():
    out = []
    for rj in sorted(glob.glob(os.path.join(runs_dir(), "*", "run.json")), key=os.path.getmtime, reverse=True):
        try:
            s = status(os.path.basename(os.path.dirname(rj)))
            s["selected_gpus"] = [t.get("selected_gpu") for t in s["tracks"].values() if t.get("selected_gpu")]
            out.append(s)
        except SpecError:
            continue
    return out


def cancel(name):
    rd = run_dir(name)
    meta = _read_json(os.path.join(rd, "run.json"), {})
    if meta.get("backend") == "colab":
        auth = (meta.get("spec") or {}).get("colab", {}).get("auth", "adc")
        for tp in meta.get("plan", []):
            _colab(["stop", "-s", tp["session"]], auth=auth, timeout=60)
    elif _alive(meta.get("pid")):
        try:
            os.killpg(os.getpgid(meta["pid"]), signal.SIGTERM)
        except (OSError, ProcessLookupError):
            pass
    with open(os.path.join(rd, "state"), "w") as fh:
        fh.write("cancelled\n")
    return {"name": name, "state": "cancelled"}


def merge(name):
    """Convert any unconverted track adapters to GGUF, blend with prior active.gguf (if present & weighted),
    fuse via SVD-32 into MODELS_DIR/adapters/<model_slug>/<role>/candidates/, and stage for Tier B gate."""
    rd = run_dir(name)
    meta = _read_json(os.path.join(rd, "run.json"))
    if not meta:
        raise SpecError(f"no run named {name}")
    v = meta["spec"]
    conv = find_converter(v)
    conv_venv_py = os.path.join(GEORGE, "tools", "convert_venv", "bin", "python")
    if _exe(v["train_python"]):
        py = v["train_python"]
    elif _exe(conv_venv_py):
        py = conv_venv_py
    else:
        py = sys.executable
    hf_token, _ = cc._read_key_from_files(("HF_TOKEN", "HUGGINGFACE_TOKEN", "HUGGING_FACE_HUB_TOKEN"))
    conv_env = dict(os.environ)
    if hf_token and not conv_env.get("HF_TOKEN"):
        conv_env["HF_TOKEN"] = hf_token
    if conv:
        gguf_py = os.path.join(os.path.dirname(conv), "gguf-py")
        if os.path.isdir(gguf_py):
            conv_env["PYTHONPATH"] = gguf_py + os.pathsep + conv_env.get("PYTHONPATH", "")
    ggufs, notes = [], []
    role_dir = role_adapter_dir(v["model_slug"], v["role"])

    for t in v["tracks"]:
        td = os.path.join(rd, "tracks", t["name"])
        ad = os.path.join(td, "output", "adapter")
        out = os.path.join(td, "adapter.gguf")
        if not os.path.isfile(out):
            if not os.path.isdir(ad):
                notes.append(f"{t['name']}: no adapter (track state {track_status(td)['state']})")
                continue
            if not conv:
                notes.append(f"{t['name']}: cannot convert locally (no convert_lora_to_gguf.py; enable export_gguf_on_colab)")
                continue
            argv = [py, conv, ad, "--outtype", "f16", "--outfile", out]
            if v["base_hf_path"] and os.path.isfile(os.path.join(v["base_hf_path"], "config.json")):
                argv += ["--base", v["base_hf_path"]]
            else:
                argv += ["--base-model-id", v["base_model"]]
            r = subprocess.run(argv, capture_output=True, text=True, timeout=3600, stdin=subprocess.DEVNULL, check=False, env=conv_env)
            if r.returncode != 0:
                notes.append(f"{t['name']}: convert failed: {(r.stderr or r.stdout).strip()[-300:]}")
                continue
        # Preserve individual track GGUF in role lineage
        track_dst = os.path.join(role_dir, "tracks", f"{v['name']}-{t['name']}.gguf")
        shutil.copyfile(out, track_dst)
        ggufs.append(out)

    stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    outputs = []
    method = v["merge"]["method"]
    prior_w = float(v["merge"].get("prior_adapter_weight", 0.70))
    active_prior = os.path.join(role_dir, "active.gguf")
    merge_inputs = list(ggufs)
    raw_weights = v["merge"]["weights"] or ([1.0 / max(1, len(ggufs))] * len(ggufs))
    w_sum = sum(raw_weights) or 1.0
    norm_new_w = [w / w_sum for w in raw_weights]

    prior_blended = False
    if os.path.isfile(active_prior) and prior_w > 0.0 and method != "none" and ggufs:
        merge_inputs = [os.path.realpath(active_prior)] + ggufs
        merge_weights = [prior_w] + [w * (1.0 - prior_w) for w in norm_new_w]
        prior_blended = True
    else:
        merge_weights = norm_new_w

    cand_dir = os.path.join(role_dir, "candidates")
    if len(merge_inputs) == 1 or method == "none":
        for g in merge_inputs:
            dst = os.path.join(cand_dir, f"{v['name']}-{stamp}.gguf")
            shutil.copyfile(g, dst)
            outputs.append(dst)
    elif merge_inputs:
        dst = os.path.join(cand_dir, f"{v['name']}-{method}{v['merge']['target_rank']}-{stamp}.gguf")
        env = dict(os.environ)
        if conv:
            env["PYTHONPATH"] = os.path.join(os.path.dirname(conv), "gguf-py") + os.pathsep + env.get("PYTHONPATH", "")
        argv = [py, MERGE, "--adapters", *merge_inputs, "--output", dst, "--method", method,
                "--target_rank", str(v["merge"]["target_rank"]),
                "--weights", *[f"{w:.4f}" for w in merge_weights]]
        r = subprocess.run(argv, capture_output=True, text=True, timeout=3600, stdin=subprocess.DEVNULL, check=False, env=env)
        if r.returncode != 0:
            notes.append(f"merge failed: {(r.stderr or r.stdout).strip()[-400:]}")
        else:
            outputs.append(dst)

    res = {
        "name": name, "role": v["role"], "model_slug": v["model_slug"], "method": method,
        "prior_blended": prior_blended, "prior_weight": prior_w if prior_blended else 0.0,
        "weights": merge_weights, "inputs": merge_inputs, "outputs": outputs, "notes": notes,
        "at": dt.datetime.now().isoformat(timespec="seconds"),
    }
    _write_json(os.path.join(rd, "merged.json"), res)
    if not outputs:
        raise SpecError("nothing merged: " + "; ".join(notes or ["no adapters"]))

    meta["gate_status"] = "pending_approval"
    _write_json(os.path.join(rd, "run.json"), meta)
    with open(os.path.join(rd, "state"), "w") as fh:
        fh.write("staged_tier_b\n")
    return res


def _norm_model_tokens(text: str) -> set[str]:
    low = re.sub(r"[^a-z0-9]+", " ", (text or "").lower()).strip()
    stop = {"gguf", "it", "ud", "q4", "q5", "q6", "q8", "k", "xl", "s", "m", "l", "f16", "bf16", "unsloth", "google", "qwen", "models", "hub", "huggingface", "base", "baseline"}
    return {t for t in low.split() if t and t not in stop}


def model_matches_live(model_slug: str, live_model_path: str) -> bool:
    """Verify that the live llama-server base model matches the candidate adapter's target model_slug."""
    slug_l = (model_slug or "").lower()
    live_l = os.path.basename(live_model_path or "").lower()
    if not slug_l or not live_l:
        return False
    # Exact key anchors for known families so 31b never matches 26b or qwen3.8-27b
    anchors = ("31b", "27b", "26b", "e4b", "e2b", "14b", "9b", "8b", "7b", "4b")
    for a in anchors:
        if a in slug_l and a not in live_l:
            return False
    for fam in ("gemma", "qwen", "llama", "mistral", "deepseek"):
        if fam in slug_l and fam not in live_l:
            return False
    s_toks = _norm_model_tokens(slug_l)
    l_toks = _norm_model_tokens(live_l)
    return bool(s_toks and len(s_toks & l_toks) >= min(2, len(s_toks)))


def _default_inference_endpoint() -> str:
    if os.environ.get("KUBERNETES_SERVICE_HOST"):
        return "http://george-inference:8080"
    return "http://127.0.0.1:8080"


def _to_container_model_path(host_path: str) -> str:
    """Map host MODELS_DIR paths into /models/... inside george-inference container."""
    p = os.path.realpath(host_path) if os.path.exists(host_path) else host_path
    md = os.path.realpath(models_dir())
    if p.startswith("/models/"):
        return p
    if p.startswith(md + "/"):
        return "/models/" + p[len(md) + 1:]
    if "/models/" in p:
        return "/models/" + p.split("/models/", 1)[1]
    return p


def _probe_live_inference(endpoint: str) -> dict:
    base = endpoint.rstrip("/")
    out = {"reachable": False, "endpoint": base, "model_path": "", "adapters": []}
    try:
        with urllib.request.urlopen(f"{base}/props", timeout=8) as resp:
            props = json.loads(resp.read().decode("utf-8"))
            out["model_path"] = props.get("model_path") or ""
            out["reachable"] = True
    except Exception as e:
        out["error"] = str(e)
        return out
    try:
        with urllib.request.urlopen(f"{base}/lora-adapters", timeout=8) as resp:
            out["adapters"] = json.loads(resp.read().decode("utf-8"))
    except Exception:
        pass
    return out


def resolve_baseline(model_slug: str, role: str = "core-agent") -> dict | None:
    """Resolve the progressively-updated champion baseline scorecard for (model_slug, role).
    1. Use lineage.json['baseline'] if present and scorecard file exists.
    2. Otherwise scan benchmarks/results/multiturn_*.json matching model_slug and seed lineage.json['baseline'].
    """
    role_dir = role_adapter_dir(model_slug, role)
    lineage_p = os.path.join(role_dir, "lineage.json")
    lineage = _read_json(lineage_p, {"model_slug": model_slug, "role": role, "releases": [], "backups": []})
    saved = lineage.get("baseline")
    if isinstance(saved, dict):
        sp = saved.get("scorecard_path") or ""
        if sp and not os.path.isabs(sp):
            sp_abs = os.path.join(LODGE, sp)
        else:
            sp_abs = sp
        if sp_abs and os.path.isfile(sp_abs):
            sc = _read_json(sp_abs, {})
            if sc.get("overall_score") is not None:
                return {**saved, "scorecard_path": sp_abs, "scorecard": sc}

    # Auto-discover best matching saved baseline scorecard in benchmarks/results/
    bench_dir = os.path.join(LODGE, "benchmarks", "results")
    candidates = []
    for p in sorted(glob.glob(os.path.join(bench_dir, "multiturn_*.json"))):
        sc = _read_json(p, {})
        if not isinstance(sc, dict) or sc.get("overall_score") is None:
            continue
        lbl = f"{sc.get('model_label', '')} {os.path.basename(p)}"
        if model_matches_live(model_slug, lbl):
            is_base = "baseline" in lbl.lower()
            candidates.append((1 if is_base else 0, float(sc.get("overall_score", 0.0)), os.path.getmtime(p), p, sc))
    if not candidates:
        return None
    candidates.sort(key=lambda x: (x[0], x[1], x[2]), reverse=True)
    _, _, _, best_p, best_sc = candidates[0]
    rel_p = os.path.relpath(best_p, LODGE) if best_p.startswith(LODGE + os.sep) else best_p
    entry = {
        "label": best_sc.get("model_label", os.path.basename(best_p)),
        "scorecard_path": rel_p,
        "overall_score": float(best_sc.get("overall_score", 0.0)),
        "early_quit_rate_pct": float(best_sc.get("early_quit_rate_pct", 0.0)),
        "adapter_version": lineage.get("active"),
        "updated_at": dt.datetime.now().isoformat(timespec="seconds"),
    }
    lineage["baseline"] = entry
    _write_json(lineage_p, lineage)
    return {**entry, "scorecard_path": best_p, "scorecard": best_sc}


def _restart_inference_deployment(endpoint: str, expect_lora: bool = False, timeout_s: int = 240) -> dict:
    """Restart k3s deploy/george-inference and wait until /health is 200 (and optional LoRA loaded)."""
    kubectl = shutil.which("kubectl")
    if not kubectl:
        raise SpecError("kubectl not found — cannot cycle deploy/george-inference for candidate benchmark")
    r1 = subprocess.run(
        [kubectl, "-n", "blue-lodge", "rollout", "restart", "deploy/george-inference"],
        capture_output=True, text=True, timeout=30, check=False,
    )
    if r1.returncode != 0:
        raise SpecError(f"kubectl rollout restart failed: {(r1.stderr or r1.stdout).strip()[-240:]}")
    r2 = subprocess.run(
        [kubectl, "-n", "blue-lodge", "rollout", "status", "deploy/george-inference", f"--timeout={timeout_s}s"],
        capture_output=True, text=True, timeout=timeout_s + 15, check=False,
    )
    if r2.returncode != 0:
        raise SpecError(f"george-inference rollout failed: {(r2.stderr or r2.stdout).strip()[-240:]}")
    deadline = time.time() + 90
    base = endpoint.rstrip("/")
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"{base}/health", timeout=5) as resp:
                if resp.status == 200:
                    st = _probe_live_inference(base)
                    if not expect_lora or st.get("adapters"):
                        return st
        except Exception:
            pass
        time.sleep(2)
    raise SpecError(f"george-inference did not report healthy{' with LoRA loaded' if expect_lora else ''} within 90s")


def format_benchmark_discord_card(run_name: str, verdict: dict) -> str:
    """Build a concise Discord Markdown head-to-head scorecard with Accept/Deny decision options."""
    passed = bool(verdict.get("passed"))
    badge = "✅ GATE PASS" if passed else "⚠️ GATE BELOW THRESHOLD"
    b_sc = verdict.get("baseline_score", 0.0)
    c_sc = verdict.get("candidate_score", 0.0)
    delta = float(verdict.get("composite_delta", 0.0))
    b_eq = verdict.get("baseline_early_quit_pct", 0.0)
    c_eq = verdict.get("candidate_early_quit_pct", 0.0)
    eq_d = float(verdict.get("early_quit_delta", 0.0))
    base_lbl = verdict.get("baseline_label", "baseline")
    cand_lbl = verdict.get("candidate_label", run_name)
    lines = [
        f"**[Training Forge — 7-Pillar Head-to-Head Scorecard]** `{run_name}` ({badge})",
        f"**Baseline:** `{base_lbl}` → **Candidate:** `{cand_lbl}`",
        f"• **Composite:** `{b_sc}%` → **`{c_sc}%`** (**{delta:+.1f}%**)",
        f"• **Early-Quit Rate:** `{b_eq}%` → `{c_eq}%` ({eq_d:+.1f}%)",
        "",
        "**Per-Pillar Breakdown:**",
    ]
    for p, vals in (verdict.get("pillars") or {}).items():
        short = p.split(":", 1)[1].strip() if ":" in p else p
        d = float(vals.get("delta", 0.0))
        lines.append(f"• {short[:48]}: `{vals.get('baseline', 0)}%` → `{vals.get('candidate', 0)}%` ({d:+.1f}%)")
    lines.extend([
        "",
        "**Decision Options (Inference restored to production baseline):**",
        f"• Accept & promote SVD-32 layer: `/train approve {run_name}` (or click **ACCEPT** in Forge UI)",
        f"• Reject & keep current baseline: `/train deny {run_name}` (or click **DENY** in Forge UI)",
    ])
    return "\n".join(lines)


def send_discord_report(message: str, recipient: str = "@owner") -> bool:
    script = os.path.join(LODGE, "scripts", "monitor", "discord_send_report.sh")
    if not os.path.isfile(script):
        return False
    r = subprocess.run(
        ["bash", script, recipient, message],
        capture_output=True, text=True, timeout=30, check=False,
        env={**os.environ, "LODGE_DIR": LODGE, "GEORGE_DIR": GEORGE},
    )
    return r.returncode == 0


def benchmark_candidate(
    name: str,
    endpoint: str | None = None,
    min_delta: float | None = None,
    notify_discord: bool = False,
    dry_run: bool = False,
    force_rebaseline: bool = False,
) -> dict:
    """Automated 7-pillar head-to-head benchmark for a staged SVD-32 candidate against the progressive
    champion baseline (base model + current active.gguf). Always restores production inference afterward."""
    rd = run_dir(name)
    meta = _read_json(os.path.join(rd, "run.json"), {})
    merged = _read_json(os.path.join(rd, "merged.json"), {})
    outs = merged.get("outputs") or []
    if not outs or not os.path.isfile(outs[0]):
        raise SpecError(f"No merged candidate GGUF found for run '{name}' (run 'runs.py merge {name}' first).")
    cand_host = outs[0]
    v = meta.get("spec") or {}
    model_slug = meta.get("model_slug") or v.get("model_slug") or "default"
    role = meta.get("role") or v.get("role") or "core-agent"
    ep = (endpoint or _default_inference_endpoint()).rstrip("/")
    pol = load_policy()
    req_delta = float(min_delta) if min_delta is not None else 0.0

    # 1. Verify live inference server & base model match
    live = _probe_live_inference(ep)
    if not live.get("reachable"):
        raise SpecError(f"Inference endpoint {ep} is unreachable: {live.get('error', 'connection failed')}")
    live_model = live.get("model_path") or ""
    if not model_matches_live(model_slug, live_model):
        raise SpecError(
            f"Base model mismatch: live inference is serving '{os.path.basename(live_model)}', "
            f"but candidate '{name}' targets '{model_slug}'. Activate '{model_slug}' in Model Hub first "
            f"(or pass --endpoint pointing to a node serving '{model_slug}')."
        )

    role_dir = role_adapter_dir(model_slug, role)
    active_link = os.path.join(role_dir, "active.gguf")
    active_host = os.path.realpath(active_link) if os.path.isfile(active_link) else None
    baseline = None if force_rebaseline else resolve_baseline(model_slug, role)

    plan = {
        "status": "planned",
        "run": name,
        "model_slug": model_slug,
        "role": role,
        "endpoint": ep,
        "live_model": os.path.basename(live_model),
        "candidate_path": cand_host,
        "active_path": active_host,
        "baseline": {k: baseline[k] for k in ("label", "scorecard_path", "overall_score", "early_quit_rate_pct", "adapter_version") if k in baseline} if baseline else None,
        "will_capture_baseline": baseline is None,
        "min_delta": req_delta,
    }
    if dry_run:
        return plan

    bench_py = os.path.join(LODGE, "scripts", "eval", "multiturn_bench.py")
    py_bin = os.path.join(LODGE, ".venv", "bin", "python3")
    if not _exe(py_bin):
        py_bin = sys.executable
    status_p = os.path.join(rd, "benchmark_status.json")
    override_p = os.path.join(GEORGE, "training", "bench_override.json")

    def _set_stage(stage: str, st: str = "running", err: str | None = None):
        _write_json(status_p, {
            "status": st, "stage": stage, "run": name, "endpoint": ep,
            "updated_at": dt.datetime.now().isoformat(timespec="seconds"),
            "error": err,
        })

    _set_stage("staging_candidate_lora")
    cand_ctr = _to_container_model_path(cand_host)
    active_ctr = _to_container_model_path(active_host) if active_host else None
    if active_ctr:
        lora_scaled = f"{active_ctr}:0.0,{cand_ctr}:1.0"
        cand_id, active_id = 1, 0
    else:
        lora_scaled = f"{cand_ctr}:1.0"
        cand_id, active_id = 0, None

    _write_json(override_p, {
        "run": name,
        "model_slug": model_slug,
        "role": role,
        "candidate_path": cand_ctr,
        "active_path": active_ctr,
        "lora_scaled": lora_scaled,
        "created_at": dt.datetime.now().isoformat(timespec="seconds"),
    })

    def _run_bench_pass(label: str) -> tuple[str, dict]:
        fam = "gemma4" if "gemma" in model_slug else ("qwen" if "qwen" in model_slug else "auto")
        ts_now = int(time.time())
        safe_lbl = re.sub(r"[^A-Za-z0-9._-]", "_", label)[:40]
        out_json = os.path.join(LODGE, "benchmarks", "results", f"multiturn_7pillar_{safe_lbl}_{ts_now}.json")
        r = subprocess.run(
            [py_bin, bench_py, "--endpoint", ep, "--label", label, "--model-family", fam, "--output", out_json, "--json"],
            capture_output=True, text=True, timeout=3600, stdin=subprocess.DEVNULL, check=False,
            env={**os.environ, "LODGE_DIR": LODGE, "GEORGE_DIR": GEORGE},
        )
        if r.returncode != 0 or not os.path.isfile(out_json):
            raise SpecError(f"multiturn_bench failed for {label}: {(r.stderr or r.stdout).strip()[-400:]}")
        return out_json, _read_json(out_json, {})

    try:
        _set_stage("restarting_inference_with_candidate")
        _restart_inference_deployment(ep, expect_lora=True)

        # Capture fresh progressive baseline if none exists or forced
        if baseline is None:
            _set_stage("running_baseline_7pillar")
            scales_base = [{"id": cand_id, "scale": 0.0}]
            if active_id is not None:
                scales_base.insert(0, {"id": active_id, "scale": 1.0})
            hotswap_lora(ep, scales_base)
            lineage_p = os.path.join(role_dir, "lineage.json")
            lineage = _read_json(lineage_p, {"model_slug": model_slug, "role": role, "releases": [], "backups": []})
            act_ver = lineage.get("active")
            base_lbl = f"{model_slug}-{act_ver}-baseline" if act_ver else f"{model_slug}-base-baseline"
            base_path, base_sc = _run_bench_pass(base_lbl)
            rel_bp = os.path.relpath(base_path, LODGE) if base_path.startswith(LODGE + os.sep) else base_path
            lineage["baseline"] = {
                "label": base_sc.get("model_label", base_lbl),
                "scorecard_path": rel_bp,
                "overall_score": float(base_sc.get("overall_score", 0.0)),
                "early_quit_rate_pct": float(base_sc.get("early_quit_rate_pct", 0.0)),
                "adapter_version": act_ver,
                "updated_at": dt.datetime.now().isoformat(timespec="seconds"),
            }
            _write_json(lineage_p, lineage)
            baseline = {**lineage["baseline"], "scorecard_path": base_path, "scorecard": base_sc}

        # Run candidate 7-pillar evaluation with candidate scale=1.0
        _set_stage("running_candidate_7pillar")
        scales_cand = [{"id": cand_id, "scale": 1.0}]
        if active_id is not None:
            scales_cand.insert(0, {"id": active_id, "scale": 0.0})
        hotswap_lora(ep, scales_cand)
        cand_sc_path, cand_sc = _run_bench_pass(f"{name}-svd32")

        # Compare candidate vs progressive baseline
        _set_stage("computing_head_to_head_verdict")
        r_cmp = subprocess.run(
            [py_bin, bench_py, "--compare", baseline["scorecard_path"], cand_sc_path, "--min-delta", str(req_delta)],
            capture_output=True, text=True, timeout=60, check=False,
            env={**os.environ, "LODGE_DIR": LODGE, "GEORGE_DIR": GEORGE},
        )
        try:
            verdict = json.loads(r_cmp.stdout)
        except ValueError as e:
            raise SpecError(f"Failed to parse benchmark comparison JSON: {e}") from None

        verdict.update({
            "run": name,
            "model_slug": model_slug,
            "role": role,
            "candidate_path": cand_host,
            "baseline_scorecard_path": os.path.relpath(baseline["scorecard_path"], LODGE) if baseline["scorecard_path"].startswith(LODGE + os.sep) else baseline["scorecard_path"],
            "candidate_scorecard_path": os.path.relpath(cand_sc_path, LODGE) if cand_sc_path.startswith(LODGE + os.sep) else cand_sc_path,
            "baseline_adapter_version": baseline.get("adapter_version"),
            "benchmarked_at": dt.datetime.now().isoformat(timespec="seconds"),
        })
        _write_json(os.path.join(rd, "benchmark.json"), verdict)
    except Exception as e:
        _set_stage("failed", st="error", err=str(e))
        raise
    finally:
        # Always remove ephemeral benchmark staging override and restore production inference!
        try:
            if os.path.exists(override_p):
                os.remove(override_p)
        except OSError:
            pass
        try:
            _restart_inference_deployment(ep, expect_lora=False)
        except Exception:
            pass

    _set_stage("complete", st="done")
    discord_sent = False
    if notify_discord:
        card = format_benchmark_discord_card(name, verdict)
        discord_sent = send_discord_report(card, "@owner")
    return {"status": "ok", "discord_notified": discord_sent, **verdict}


def approve_candidate(name: str, approver: str = "operator", apply_live: bool = True) -> dict:
    """Tier B (or Tier A) promotion: moves candidate -> releases/, updates active.gguf & lineage.json,
    progressively advances the champion baseline scorecard, and reloads live inference if model matches."""
    rd = run_dir(name)
    meta = _read_json(os.path.join(rd, "run.json"), {})
    merged = _read_json(os.path.join(rd, "merged.json"), {})
    outs = merged.get("outputs") or []
    if not outs or not os.path.isfile(outs[0]):
        raise SpecError(f"No merged candidate GGUF found for run '{name}' (run merge first).")
    cand_path = outs[0]
    v = meta["spec"]
    role_dir = role_adapter_dir(v["model_slug"], v["role"])
    lineage_p = os.path.join(role_dir, "lineage.json")
    lineage = _read_json(lineage_p, {"model_slug": v["model_slug"], "role": v["role"], "releases": [], "backups": []})
    next_ver = len(lineage.get("releases", [])) + 1
    rel_name = f"v{next_ver}-{os.path.basename(cand_path)}"
    rel_path = os.path.join(role_dir, "releases", rel_name)
    shutil.copyfile(cand_path, rel_path)

    active_link = os.path.join(role_dir, "active.gguf")
    if os.path.lexists(active_link):
        os.unlink(active_link)
    os.symlink(os.path.join("releases", rel_name), active_link)

    bench = _read_json(os.path.join(rd, "benchmark.json"))
    entry = {
        "version": f"v{next_ver}", "run": name, "file": rel_name, "path": rel_path,
        "parent": lineage["releases"][-1]["version"] if lineage.get("releases") else None,
        "prior_weight": merged.get("prior_weight", 0.0), "weights": merged.get("weights", []),
        "benchmark": bench, "approved_by": approver,
        "approved_at": dt.datetime.now().isoformat(timespec="seconds"),
    }
    lineage.setdefault("releases", []).append(entry)
    lineage["active"] = entry["version"]

    # Progressively advance the champion baseline scorecard so the NEXT run competes against base + active vN!
    baseline_advanced = False
    if isinstance(bench, dict) and bench.get("candidate_scorecard_path"):
        lineage["baseline"] = {
            "label": bench.get("candidate_label") or f"{name}-svd32",
            "scorecard_path": bench["candidate_scorecard_path"],
            "overall_score": float(bench.get("candidate_score", 0.0)),
            "early_quit_rate_pct": float(bench.get("candidate_early_quit_pct", 0.0)),
            "adapter_version": entry["version"],
            "run": name,
            "updated_at": dt.datetime.now().isoformat(timespec="seconds"),
        }
        baseline_advanced = True
    _write_json(lineage_p, lineage)

    meta["gate_status"] = "approved"
    meta["promoted_release"] = rel_path
    _write_json(os.path.join(rd, "run.json"), meta)
    _write_text(os.path.join(rd, "state"), "promoted\n")

    # Best-effort reload of live george-inference when the active base model matches this adapter
    reloaded = False
    if apply_live and shutil.which("kubectl"):
        try:
            ep = _default_inference_endpoint()
            live = _probe_live_inference(ep)
            if live.get("reachable") and model_matches_live(v["model_slug"], live.get("model_path", "")):
                _restart_inference_deployment(ep, expect_lora=True)
                reloaded = True
        except Exception:
            reloaded = False

    return {
        "status": "ok", "name": name, "version": entry["version"],
        "active_path": active_link, "release_path": rel_path,
        "baseline_advanced": baseline_advanced, "inference_reloaded": reloaded,
    }


def deny_candidate(name: str, reason: str = "Denied by operator") -> dict:
    rd = run_dir(name)
    meta = _read_json(os.path.join(rd, "run.json"), {})
    meta["gate_status"] = "denied"
    meta["denial_reason"] = reason
    meta["denied_at"] = dt.datetime.now().isoformat(timespec="seconds")
    _write_json(os.path.join(rd, "run.json"), meta)
    _write_text(os.path.join(rd, "state"), "denied\n")
    return {"status": "ok", "name": name, "gate_status": "denied", "reason": reason}


def rollback_candidate(name: str, apply_live: bool = True) -> dict:
    """Undo a prior approval of `name`: remove its release entry, restore active.gguf to the previous
    release (or clean base model if none), revert gate_status to pending_approval, and reload inference."""
    rd = run_dir(name)
    meta = _read_json(os.path.join(rd, "run.json"), {})
    v = meta.get("spec") or {}
    model_slug = meta.get("model_slug") or v.get("model_slug") or "default"
    role = meta.get("role") or v.get("role") or "core-agent"
    role_dir = role_adapter_dir(model_slug, role)
    lineage_p = os.path.join(role_dir, "lineage.json")
    lineage = _read_json(lineage_p, {"model_slug": model_slug, "role": role, "releases": [], "backups": []})

    releases = list(lineage.get("releases") or [])
    removed = [r for r in releases if r.get("run") == name]
    kept = [r for r in releases if r.get("run") != name]
    for r in removed:
        rp = r.get("path")
        if rp and os.path.isfile(rp):
            try:
                os.remove(rp)
            except OSError:
                pass
    lineage["releases"] = kept

    active_link = os.path.join(role_dir, "active.gguf")
    if os.path.lexists(active_link):
        os.unlink(active_link)
    if kept:
        prev = kept[-1]
        lineage["active"] = prev.get("version")
        os.symlink(os.path.join("releases", prev["file"]), active_link)
        # Restore baseline to previous release's scorecard if available
        pb = prev.get("benchmark")
        if isinstance(pb, dict) and pb.get("candidate_scorecard_path"):
            lineage["baseline"] = {
                "label": pb.get("candidate_label") or prev.get("run"),
                "scorecard_path": pb["candidate_scorecard_path"],
                "overall_score": float(pb.get("candidate_score", 0.0)),
                "early_quit_rate_pct": float(pb.get("candidate_early_quit_pct", 0.0)),
                "adapter_version": prev.get("version"),
                "run": prev.get("run"),
                "updated_at": dt.datetime.now().isoformat(timespec="seconds"),
            }
    else:
        lineage["active"] = None
        if isinstance(lineage.get("baseline"), dict) and lineage["baseline"].get("run") == name:
            lineage.pop("baseline", None)

    _write_json(lineage_p, lineage)

    meta["gate_status"] = "pending_approval"
    meta.pop("promoted_release", None)
    _write_json(os.path.join(rd, "run.json"), meta)
    _write_text(os.path.join(rd, "state"), "staged_tier_b\n")

    reloaded = False
    if apply_live and shutil.which("kubectl"):
        try:
            ep = _default_inference_endpoint()
            live = _probe_live_inference(ep)
            if live.get("reachable") and model_matches_live(model_slug, live.get("model_path", "")):
                _restart_inference_deployment(ep, expect_lora=bool(kept))
                reloaded = True
        except Exception:
            reloaded = False

    return {
        "status": "ok",
        "name": name,
        "gate_status": "pending_approval",
        "removed_releases": [r.get("version") for r in removed],
        "active_version": lineage.get("active"),
        "inference_reloaded": reloaded,
    }


def list_adapters() -> list[dict]:
    root = os.path.join(models_dir(), "adapters")
    out = []
    for lp in sorted(glob.glob(os.path.join(root, "*", "*", "lineage.json"))):
        lin = _read_json(lp, {})
        role_dir = os.path.dirname(lp)
        active = os.path.join(role_dir, "active.gguf")
        out.append({
            "model_slug": lin.get("model_slug", os.path.basename(os.path.dirname(role_dir))),
            "role": lin.get("role", os.path.basename(role_dir)),
            "active_version": lin.get("active"),
            "active_path": os.path.realpath(active) if os.path.exists(active) else None,
            "baseline": lin.get("baseline"),
            "releases": lin.get("releases", []),
            "backups": lin.get("backups", []),
        })
    # Also surface loose legacy .gguf adapters directly in MODELS_DIR/adapters/
    loose = [p for p in sorted(glob.glob(os.path.join(root, "*.gguf")))]
    if loose:
        out.append({"model_slug": "legacy", "role": "unassigned", "active_version": None,
                    "active_path": None, "releases": [{"version": "legacy", "file": os.path.basename(p), "path": p} for p in loose],
                    "backups": []})
    return out


def hotswap_lora(endpoint: str, scales: list[dict]) -> dict:
    """Dynamically switch loaded LoRA/SVD scales on a running stock llama-server via POST /lora-adapters (0ms restart)."""
    base = (endpoint or "http://127.0.0.1:8080").rstrip("/")
    req = urllib.request.Request(
        f"{base}/lora-adapters",
        data=json.dumps(scales).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = resp.read().decode("utf-8", errors="ignore")
        # Fetch current state back
        with urllib.request.urlopen(f"{base}/lora-adapters", timeout=10) as resp2:
            cur = json.loads(resp2.read().decode("utf-8"))
        return {"status": "ok", "endpoint": base, "adapters": cur, "response": body}
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise SpecError(f"POST {base}/lora-adapters failed: {e}") from None


def bake(adapter_or_run: str, base_gguf: str, out_gguf: str | None = None, dry_run: bool = False) -> dict:
    base_p = os.path.expanduser(base_gguf or "")
    if not os.path.isfile(base_p):
        raise SpecError(f"base GGUF not found: {base_gguf}")
    adapter_p = os.path.expanduser(adapter_or_run or "")
    spec = None
    if not os.path.isfile(adapter_p):
        rd = run_dir(adapter_or_run)
        meta = _read_json(os.path.join(rd, "run.json"), {})
        spec = meta.get("spec")
        merged = _read_json(os.path.join(rd, "merged.json"), {})
        outs = merged.get("outputs") or []
        if outs and os.path.isfile(outs[0]):
            adapter_p = outs[0]
        else:
            raise SpecError(f"no merged adapter GGUF found for run {adapter_or_run} (run 'merge' first)")
    bin_p = find_export_lora_bin(spec)
    if not bin_p:
        if dry_run:
            bin_p = "llama-export-lora"
        else:
            raise SpecError("llama-export-lora binary not found in /usr/local/bin or $LLAMA_CPP_DIR")
    if not out_gguf:
        stem = re.sub(r"\.gguf$", "", base_p, flags=re.IGNORECASE)
        out_gguf = f"{stem}-Merged.gguf"
    out_p = os.path.expanduser(out_gguf)
    argv = [bin_p, "-m", base_p, "--lora", adapter_p, "-o", out_p]
    if dry_run:
        return {"status": "planned", "binary": bin_p, "base_gguf": base_p, "lora_gguf": adapter_p, "output_gguf": out_p, "argv": argv}
    env = dict(os.environ)
    bin_dir = os.path.dirname(bin_p)
    env["LD_LIBRARY_PATH"] = f"{bin_dir}:/usr/local/cuda/lib64:{env.get('LD_LIBRARY_PATH', '')}"
    r = subprocess.run(argv, capture_output=True, text=True, timeout=3600, stdin=subprocess.DEVNULL, check=False, env=env)
    if r.returncode != 0 or not os.path.isfile(out_p):
        raise SpecError(f"llama-export-lora failed: {(r.stderr or r.stdout).strip()[-400:]}")
    return {"status": "ok", "binary": bin_p, "base_gguf": base_p, "lora_gguf": adapter_p, "output_gguf": out_p}


TEMPLATE = {
    "name": "sleep-svd32-v1", "role": "core-agent", "model_slug": "gemma-4-31b-it",
    "backend": "colab", "base_model": "google/gemma-4-31b-it", "base_source": "hf_direct",
    "base_hf_path": "", "train_python": "", "llama_cpp_dir": "/opt/llama.cpp",
    "tracks": [
        {"name": "sft-core", "method": "sft", "train": "exports:forge_X/sft_train.jsonl", "val": "exports:forge_X/sft_val.jsonl", "gpu": 0},
        {"name": "dpo-persistence", "method": "dpo", "train": "exports:forge_X/dpo_train.jsonl", "val": "exports:forge_X/dpo_val.jsonl", "gpu": 0},
    ],
    "hyper": {k: v[3] for k, v in HYPER.items()} | {"load_in_4bit": True, "use_unsloth": True},
    "merge": {"method": "svd", "target_rank": 32, "prior_adapter_weight": 0.70, "weights": [0.55, 0.45]},
    "colab": {
        "auth": "adc", "gpu": "A100", "gpu_fallback": DEFAULT_GPU_FALLBACK,
        "min_gpu_vram_gb": 24, "high_mem": True, "max_concurrent_sessions": 3,
        "min_cu_balance": 150, "max_runtime_min": 180,
        "drive_checkpoints": True, "export_gguf_on_colab": True,
    },
    "local": {"pause_inference": True},
}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("template")
    sub.add_parser("list")
    sub.add_parser("adapters")
    sub.add_parser("gate-queue")
    for n in ("plan", "start"):
        p = sub.add_parser(n)
        p.add_argument("spec")
        if n == "start":
            p.add_argument("--dry-run", action="store_true")
            p.add_argument("--execute", action="store_true")
            p.add_argument("--force", action="store_true")
    for n in ("status", "cancel", "merge", "collect", "resume"):
        sub.add_parser(n).add_argument("name")
    pl = sub.add_parser("logs")
    pl.add_argument("name")
    pl.add_argument("--track", default=None)
    pl.add_argument("--live", action="store_true")
    pl.add_argument("--lines", type=int, default=80)
    pcs = sub.add_parser("colab-sessions")
    pcs.add_argument("--probe", action="store_true")
    pcv = sub.add_parser("cull-vm")
    pcv.add_argument("--target", default=None)
    pcv.add_argument("--all-stale", action="store_true")
    pa = sub.add_parser("approve")
    pa.add_argument("name")
    pa.add_argument("--approver", default="operator")
    pa.add_argument("--no-restart", action="store_true")
    pbm = sub.add_parser("benchmark")
    pbm.add_argument("name")
    pbm.add_argument("--endpoint", default=None)
    pbm.add_argument("--min-delta", type=float, default=None)
    pbm.add_argument("--notify-discord", action="store_true")
    pbm.add_argument("--force-rebaseline", action="store_true")
    pbm.add_argument("--dry-run", action="store_true")
    pd = sub.add_parser("deny")
    pd.add_argument("name")
    pd.add_argument("--reason", default="Denied by operator")
    prb = sub.add_parser("rollback")
    prb.add_argument("name")
    prb.add_argument("--no-restart", action="store_true")
    pp = sub.add_parser("policy")
    pp.add_argument("--set", dest="set_json", default=None, help="JSON object of policy fields to update")
    ph = sub.add_parser("hotswap")
    ph.add_argument("--endpoint", default="http://127.0.0.1:8080")
    ph.add_argument("--scales", required=True, help='JSON array e.g. \'[{"id":0,"scale":1.0}]\'')
    pb = sub.add_parser("bake")
    pb.add_argument("adapter")
    pb.add_argument("--base", required=True)
    pb.add_argument("--out", default=None)
    pb.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "template":
            res = TEMPLATE
        elif a.cmd == "list":
            res = list_runs()
        elif a.cmd == "adapters":
            res = list_adapters()
        elif a.cmd == "gate-queue":
            runs = list_runs()
            res = {
                "policy": load_policy(),
                "pending": [r for r in runs if r.get("gate_status") == "pending_approval"],
                "history": runs,
            }
        elif a.cmd == "policy":
            res = save_policy(json.loads(a.set_json)) if a.set_json else load_policy()
        elif a.cmd == "approve":
            res = approve_candidate(a.name, a.approver, apply_live=not a.no_restart)
        elif a.cmd == "benchmark":
            res = benchmark_candidate(
                a.name,
                endpoint=a.endpoint,
                min_delta=a.min_delta,
                notify_discord=a.notify_discord,
                dry_run=a.dry_run,
                force_rebaseline=a.force_rebaseline,
            )
        elif a.cmd == "deny":
            res = deny_candidate(a.name, a.reason)
        elif a.cmd == "rollback":
            res = rollback_candidate(a.name, apply_live=not a.no_restart)
        elif a.cmd == "hotswap":
            res = hotswap_lora(a.endpoint, json.loads(a.scales))
        elif a.cmd == "bake":
            res = bake(a.adapter, a.base, a.out, dry_run=a.dry_run)
        elif a.cmd in ("plan", "start"):
            spec = _read_json(a.spec)
            if spec is None:
                raise SpecError(f"cannot read spec {a.spec}")
            v = validate(spec)
            pf = preflight(v)
            if a.cmd == "plan":
                res = {"valid": len(pf["errors"]) == 0, "spec": v, **pf}
            else:
                dry = a.dry_run or (v["backend"] == "colab" and not a.execute)
                if pf["errors"] and not (dry or a.force):
                    raise SpecError("preflight failed: " + "; ".join(pf["errors"]))
                rd = os.path.join(runs_dir(), v["name"])
                if os.path.isdir(rd):
                    raise SpecError(f"run {v['name']} already exists")
                os.makedirs(rd)
                _write_json(os.path.join(rd, "spec.json"), spec)
                meta = start_local(v, rd, dry) if v["backend"] == "local" else start_colab(v, rd, a.execute)
                res = {
                    "name": v["name"], "dir": rd, "state": meta["state"],
                    "warnings": pf["warnings"], "errors": pf["errors"],
                    "plan": meta.get("plan"),
                }
        elif a.cmd == "status":
            res = status(a.name)
        elif a.cmd == "cancel":
            res = cancel(a.name)
        elif a.cmd == "merge":
            res = merge(a.name)
        elif a.cmd == "resume":
            res = resume_colab(a.name)
        elif a.cmd == "logs":
            res = stream_logs(a.name, track=a.track, live=a.live, lines=a.lines)
        elif a.cmd == "colab-sessions":
            res = inspect_colab_sessions(probe=a.probe)
        elif a.cmd == "cull-vm":
            res = cull_colab_vm(target=a.target, all_stale=a.all_stale)
        else:
            res = collect_colab(a.name)
    except (SpecError, ValueError) as e:
        print(json.dumps({"error": str(e)}))
        return 1
    print(json.dumps(res, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
