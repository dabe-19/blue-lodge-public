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
import urllib.error
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
    for d in (spec.get("llama_cpp_dir"), os.environ.get("LLAMA_CPP_DIR"), "/opt/llama.cpp"):
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
    return {
        "name": name, "role": role, "model_slug": model_slug, "backend": backend,
        "base_model": spec["base_model"], "base_source": base_source,
        "base_hf_path": os.path.expanduser(str(spec.get("base_hf_path") or "")),
        "drive_base_path": str(spec.get("drive_base_path") or ""),
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


def _provision_with_fallback(session_name: str, v: dict) -> tuple[str | None, list[dict]]:
    """Try provisioning Colab GPU tiers from strongest to weakest with fail-fast assign timeouts
    and transient-503 retries + backoff.
    Google's /tun/m/assign can hold a connection for 90-120s before returning 503 on scarce SKUs
    (H100/G4), so we use a 45s assign timeout, try scarce top tiers once, and concentrate
    multi-attempt retries on the primary workhorse tier (A100 standard / last eligible tier).
    """
    import time
    history = []
    auth = v["colab"]["auth"]
    max_attempts = int(v["colab"].get("retry_attempts", 3))
    base_backoff = int(v["colab"].get("retry_backoff_sec", 6))
    ladder = list(v["colab"]["gpu_fallback"])
    for idx, tier in enumerate(ladder):
        shapes = [True, False] if (v["colab"]["high_mem"] and GPU_TIERS[tier]["high_mem"]) else [False]
        is_last = (idx == len(ladder) - 1)
        for use_hm in shapes:
            gpu_args = ["new", "-s", session_name, "--gpu", tier]
            if use_hm:
                gpu_args.append("--high-mem")
            # Try scarce speculative tiers (H100/G4) & --high-mem once quickly; retry workhorse (A100 std / last tier)
            if use_hm and len(shapes) > 1:
                attempts = 1
            elif tier in ("H100", "G4") and not is_last:
                attempts = 1
            else:
                attempts = max_attempts
            for attempt in range(1, attempts + 1):
                # Never cut off `colab new` early (<150s) or Colab may finish assigning an orphaned [?] VM
                rc, out, err = _colab(gpu_args, auth=auth, timeout=180)
                if rc == 0:
                    history.append({"gpu": tier, "high_mem": use_hm, "attempt": attempt, "status": "provisioned"})
                    return tier, history
                reason = (err or out or "provision failed").strip()[-220:]
                history.append({"gpu": tier, "high_mem": use_hm, "attempt": attempt, "status": "failed", "reason": reason})
                _colab(["stop", "-s", session_name], auth=auth, timeout=30)
                low = reason.lower()
                if "rejected accelerator" in low or "precondition failed" in low or "too many active sessions" in low:
                    break
                if attempt < attempts:
                    time.sleep(base_backoff * attempt)
    return None, history


def _build_colab_launch_py(v: dict, s: str, remote: str, track_name: str, hf_token: str | None, drive_ok: bool = True) -> str:
    drive_ckpt = f"/content/drive/MyDrive/BlueLodge/checkpoints/{v['name']}/{track_name}" if (v["colab"]["drive_checkpoints"] and drive_ok) else f"{remote}/checkpoints"
    export_gguf = f"{remote}/output/adapter.gguf" if v["colab"]["export_gguf_on_colab"] else ""
    unsloth_pip = "unsloth " if v["hyper"].get("use_unsloth") else ""
    hf_env = f"export HF_TOKEN={shlex.quote(hf_token)}; " if hf_token else ""
    export_flag = f"--export-gguf {shlex.quote(export_gguf)}" if export_gguf else ""
    return (
        "import subprocess, os\n"
        f"os.makedirs({remote!r}, exist_ok=True)\n"
        f"subprocess.run(['tar','-xzf','/content/{s}.tar.gz','-C',{remote!r}], check=True)\n"
        f"os.makedirs({drive_ckpt!r}, exist_ok=True)\n"
        f"cmd = ({hf_env!r}\n"
        f"       'pip install -q {unsloth_pip}\"torch>=2.3\" \"transformers>=4.45\" \"peft>=0.12\" \"trl>=0.11\" '\n"
        "       '\"datasets>=2.20\" accelerate bitsandbytes gguf > /content/pip.log 2>&1; '\n"
        f"       'cd {remote} && nohup python train_lora.py --config config.json '\n"
        f"       '--checkpoint-dir {shlex.quote(drive_ckpt)} --resume-from-checkpoint latest {export_flag} > train.log 2>&1; '\n"
        f"       'rc=$?; echo $rc > exit_code; '\n"
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
    selected, hist = _provision_with_fallback(s, v)
    tp["selected_gpu"] = selected
    tp["fallback_history"] = hist
    if not selected:
        with open(os.path.join(td, "state"), "w") as fh:
            fh.write("failed\n")
        tp["error"] = "All Colab GPU fallback tiers failed: " + "; ".join(f"{h['gpu']}({h.get('reason','')[:60]})" for h in hist)
        return False

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

    # Mount Google Drive for 1h-timeout checkpoint resilience (non-fatal fallback to local checkpoints)
    drive_ok = False
    if v["colab"]["drive_checkpoints"]:
        rc_d, out_d, err_d = _colab(["drivemount", "-s", s, "/content/drive"], auth=auth, timeout=60)
        drive_ok = (rc_d == 0)
        if not drive_ok:
            tp["drive_mount_warning"] = (err_d or out_d or "drivemount failed").strip()[-200:]
            # Unstick remote Jupyter kernel if drive.mount stalled awaiting interactive FUSE consent
            _colab(["restart-kernel", "-s", s], auth=auth, timeout=45)
    tp["drive_mounted"] = drive_ok

    # Upload dataset/code bundle (+ optional local base weights)
    rc, out, err = _colab(["upload", "-s", s, tp["bundle"], f"/content/{s}.tar.gz"], auth=auth, timeout=600)
    if rc != 0:
        tp["error"] = f"upload: {(err or out).strip()[-250:]}"
        _colab(["stop", "-s", s], auth=auth, timeout=60)
        with open(os.path.join(td, "state"), "w") as fh:
            fh.write("failed\n")
        return False

    if v["base_source"] == "local_upload" and v.get("base_hf_path") and os.path.isdir(v["base_hf_path"]):
        base_tar = os.path.join(rd, "base_upload.tar.gz")
        if not os.path.isfile(base_tar):
            with tarfile.open(base_tar, "w:gz") as tf:
                tf.add(v["base_hf_path"], arcname="base_model")
        rc_b, out_b, err_b = _colab(["upload", "-s", s, base_tar, "/content/base_model.tar.gz"], auth=auth, timeout=1800)
        if rc_b == 0:
            _colab(["exec", "-s", s], auth=auth, stdin="import subprocess; subprocess.run(['tar','-xzf','/content/base_model.tar.gz','-C','/content'], check=True)\n", timeout=300)

    launch_py = _build_colab_launch_py(v, s, tp["remote_dir"], tp["track"], hf_token, drive_ok=drive_ok)
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
    for tp in meta.get("plan", []):
        td = os.path.join(rd, "tracks", tp["track"])
        st = track_status(td)["state"]
        if st in ("done",):
            resumed[tp["track"]] = "already_done"
            continue
        if int(tp.get("resumes", 0)) >= 4:
            resumed[tp["track"]] = "max_resumes_reached"
            continue
        # Check if session is still alive before re-provisioning
        rc, out, _ = _colab(["exec", "-s", tp["session"]], auth=auth, stdin="print('ALIVE')\n", timeout=30)
        if rc == 0 and "ALIVE" in out:
            resumed[tp["track"]] = "still_alive"
            continue
        _colab(["stop", "-s", tp["session"]], auth=auth, timeout=60)
        tp["resumes"] = int(tp.get("resumes", 0)) + 1
        ok = _launch_single_colab_track(v, rd, tp, hf_token, auth)
        resumed[tp["track"]] = f"resumed_on_{tp.get('selected_gpu')}" if ok else f"resume_failed: {tp.get('error')}"
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
        if st_cur == "done":
            res[tp["track"]] = "done"
            continue
        s = tp["session"]
        rc, out, _ = _colab(["exec", "-s", s], auth=auth, stdin=(
            "import os\n"
            f"ec = '{tp['remote_dir']}/exit_code'\n"
            f"lg = '{tp['remote_dir']}/train.log'\n"
            "print('EXIT', open(ec).read().strip() if os.path.exists(ec) else 'running')\n"
            "if os.path.exists(lg): print('TAIL::' + open(lg, errors='ignore').read()[-1200:])\n"
        ), timeout=120)
        if rc != 0:
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
                    os.makedirs(os.path.join(td, "output"), exist_ok=True)
                    tf.extractall(os.path.join(td, "output"), members=safe)  # noqa: S202
                # Promote in-Colab exported adapter.gguf if present
                colab_gguf = os.path.join(td, "output", "adapter.gguf")
                if os.path.isfile(colab_gguf):
                    shutil.copyfile(colab_gguf, os.path.join(td, "adapter.gguf"))
                with open(os.path.join(td, "state"), "w") as fh:
                    fh.write("done\n")
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
    return {
        "name": name, "role": meta.get("role", spec.get("role", "core-agent")),
        "model_slug": meta.get("model_slug", spec.get("model_slug", "")),
        "base_model": spec.get("base_model", ""),
        "backend": meta.get("backend"), "state": run_state, "created": meta.get("created"),
        "gate_status": meta.get("gate_status", "pending"),
        "prior_adapter_weight": (spec.get("merge") or {}).get("prior_adapter_weight", 0.70),
        "tracks": tracks, "merged": merged, "benchmark": bench, "dir": rd,
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
    py = v["train_python"] if _exe(v["train_python"]) else sys.executable
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
            r = subprocess.run(argv, capture_output=True, text=True, timeout=3600, stdin=subprocess.DEVNULL, check=False)
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


def approve_candidate(name: str, approver: str = "operator") -> dict:
    """Tier B (or Tier A) promotion: moves candidate -> releases/, updates active.gguf & lineage.json."""
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
    _write_json(lineage_p, lineage)

    meta["gate_status"] = "approved"
    meta["promoted_release"] = rel_path
    _write_json(os.path.join(rd, "run.json"), meta)
    with open(os.path.join(rd, "state"), "w") as fh:
        fh.write("promoted\n")
    return {"status": "ok", "name": name, "version": entry["version"], "active_path": active_link, "release_path": rel_path}


def deny_candidate(name: str, reason: str = "Denied by operator") -> dict:
    rd = run_dir(name)
    meta = _read_json(os.path.join(rd, "run.json"), {})
    meta["gate_status"] = "denied"
    meta["denial_reason"] = reason
    meta["denied_at"] = dt.datetime.now().isoformat(timespec="seconds")
    _write_json(os.path.join(rd, "run.json"), meta)
    with open(os.path.join(rd, "state"), "w") as fh:
        fh.write("denied\n")
    return {"status": "ok", "name": name, "gate_status": "denied", "reason": reason}


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
    pa = sub.add_parser("approve")
    pa.add_argument("name")
    pa.add_argument("--approver", default="operator")
    pd = sub.add_parser("deny")
    pd.add_argument("name")
    pd.add_argument("--reason", default="Denied by operator")
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
            res = approve_candidate(a.name, a.approver)
        elif a.cmd == "deny":
            res = deny_candidate(a.name, a.reason)
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
        else:
            res = collect_colab(a.name)
    except (SpecError, ValueError) as e:
        print(json.dumps({"error": str(e)}))
        return 1
    print(json.dumps(res, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
