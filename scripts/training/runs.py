#!/usr/bin/env python3
"""Lodge training-run manager — local GPUs or Colab, real TRL training, merged GGUF at the end.

A *run* is one JSON spec with one or more *tracks* (one dataset + method each). Every track is trained
with the real PEFT/TRL kit (scripts/training/kit/train_lora.py: SFT or DPO). When all tracks finish,
their adapters are converted to GGUF with llama.cpp and fused with
scripts/colab_training/merge_frontier_loras.py (concat = exact, svd = fixed rank), then written into
MODELS_DIR/adapters where the Model Workbench picks them up.

Commands
  runs.py template                      print an example spec
  runs.py plan  SPEC.json               validate + preflight (python/torch/trl, GPUs, converter) — no side effects
  runs.py start SPEC.json [--dry-run] [--execute]
                                        local: write run dir + driver and launch it detached
                                        colab: build per-track bundles + command plan; --execute runs it
  runs.py status NAME | list
  runs.py cancel NAME
  runs.py merge  NAME                   convert finished adapters to GGUF and fuse them (also run by the driver)
  runs.py collect NAME                  colab: download adapters and terminate the sessions

Spec (JSON):
{
  "name": "recovery-v1",                     # [a-z0-9._-], becomes $GEORGE_DIR/training/runs/<name>
  "backend": "local",                        # or "colab"
  "base_model": "org/model",                 # HF repo id of the unquantised base (training)
  "base_hf_path": "/path/to/local/hf/copy",  # same weights on disk (needed for GGUF conversion)
  "train_python": "/path/to/venv/bin/python",# env with torch/transformers/peft/trl/datasets (or $BLUE_LODGE_TRAIN_PYTHON)
  "llama_cpp_dir": "/path/to/llama.cpp",     # has convert_lora_to_gguf.py (or $LLAMA_CPP_DIR)
  "tracks": [ {"name": "recovery", "method": "sft", "train": "exports:forge_x/sft_train.jsonl",
               "val": "exports:forge_x/sft_val.jsonl", "gpu": 0},
              {"name": "loops", "method": "dpo", "train": "exports:forge_y/dpo_train.jsonl", "gpu": 1} ],
  "hyper": {"epochs": 2, "learning_rate": 1e-4, "lora_r": 16, "lora_alpha": 32, "max_seq_len": 4096,
            "batch_size": 1, "grad_accum": 8, "load_in_4bit": true, "dpo_beta": 0.1},
  "merge": {"method": "svd", "target_rank": 32, "weights": null},   # concat | svd | none
  "colab": {"gpu": "A100", "high_mem": true}
}
Tracks on the same GPU run one after another; tracks on different GPUs run in parallel.
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

LODGE = os.environ.get("LODGE_DIR", os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
GEORGE = os.environ.get("GEORGE_DIR", os.path.join(LODGE, ".george"))
NAME_RX = re.compile(r"^[a-z0-9][a-z0-9._-]{1,47}$")
REPO_RX = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,95}$")
DS_RX = re.compile(r"^(training|exports):([A-Za-z0-9._+@/-]{1,300})$")
KIT = os.path.join(LODGE, "scripts", "training", "kit", "train_lora.py")
MERGE = os.path.join(LODGE, "scripts", "colab_training", "merge_frontier_loras.py")
LOSS_RX = re.compile(r"\{[^{}]*'loss': '?([0-9.eE+-]+)'?[^{}]*?'epoch': '?([0-9.]+)'?[^{}]*\}")
EVAL_RX = re.compile(r"'eval_loss': '?([0-9.eE+-]+)")
MARGIN_RX = re.compile(r"'rewards/margins': '?([0-9.eE+-]+)")
HYPER = {  # name: (type, lo, hi, default)
    "epochs": (float, 0.1, 50, 2), "learning_rate": (float, 1e-7, 1e-2, 1e-4), "lora_r": (int, 1, 512, 16),
    "lora_alpha": (int, 1, 1024, 32), "lora_dropout": (float, 0.0, 0.5, 0.05),
    "max_seq_len": (int, 256, 262144, 4096), "batch_size": (int, 1, 256, 1), "grad_accum": (int, 1, 1024, 8),
    "dpo_beta": (float, 0.01, 2.0, 0.1),
}
COLAB_BIN = os.environ.get("COLAB_BIN") or os.path.join(LODGE, ".venv", "bin", "colab")


class SpecError(ValueError):
    pass


def runs_dir():
    d = os.path.join(GEORGE, "training", "runs")
    os.makedirs(d, exist_ok=True)
    return d


def run_dir(name):
    """Existing run directory for a user-supplied name (validated — never a path)."""
    if not NAME_RX.match(str(name or "")):
        raise SpecError("run name: lowercase a-z0-9._- (2-48 chars)")
    rd = os.path.join(runs_dir(), name)
    if not os.path.isfile(os.path.join(rd, "run.json")):
        raise SpecError(f"no run named {name}")
    return rd


def models_dir():
    return os.environ.get("MODELS_DIR") or os.path.expanduser("~/models")


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
    for d in (spec.get("llama_cpp_dir"), os.environ.get("LLAMA_CPP_DIR")):
        if d:
            cands.append(os.path.join(d, "convert_lora_to_gguf.py"))
    cands += sorted(glob.glob(os.path.join(LODGE, "build*", "*", "convert_lora_to_gguf.py")))
    cands += [os.path.expanduser("~/llama.cpp/convert_lora_to_gguf.py")]
    return next((c for c in cands if os.path.isfile(c)), None)


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
        out_tracks.append({"name": tn, "method": method, "gpu": gpu, "train_file": train, "val_file": val,
                           "init_adapter": os.path.expanduser(str(init)) if init else None})
    merge = spec.get("merge") or {"method": "none"}
    if merge.get("method", "none") not in ("concat", "svd", "none"):
        raise SpecError("merge.method must be concat, svd or none")
    w = merge.get("weights")
    if w is not None and (not isinstance(w, list) or len(w) != len(out_tracks)
                          or not all(isinstance(x, (int, float)) and x >= 0 for x in w)):
        raise SpecError("merge.weights: one non-negative number per track (or null for equal weights)")
    tr = int(merge.get("target_rank", 32))
    if not 1 <= tr <= 1024:
        raise SpecError("merge.target_rank must be 1-1024")
    py = spec.get("train_python") or os.environ.get("BLUE_LODGE_TRAIN_PYTHON") or ""
    return {"name": name, "backend": backend, "base_model": spec["base_model"],
            "base_hf_path": os.path.expanduser(str(spec.get("base_hf_path") or "")),
            "train_python": os.path.expanduser(py), "llama_cpp_dir": spec.get("llama_cpp_dir"),
            "tracks": out_tracks, "hyper": hyper,
            "merge": {"method": merge.get("method", "none"), "target_rank": tr, "weights": w},
            "colab": {"gpu": str((spec.get("colab") or {}).get("gpu", "A100")),
                      "high_mem": bool((spec.get("colab") or {}).get("high_mem", True))}}


def preflight(v):
    """Hard errors block a local start; warnings are informational."""
    errors, warns, info = [], [], {}
    if v["backend"] == "local":
        if not _exe(v["train_python"]):
            errors.append("train_python not set or not executable — point it (or $BLUE_LODGE_TRAIN_PYTHON) at a venv "
                          "with torch, transformers, peft, trl, datasets (see scripts/training/kit/README.md)")
        else:
            try:
                r = subprocess.run([v["train_python"], "-c",
                                    "import torch, transformers, peft, trl, datasets; "
                                    "print(torch.cuda.device_count(), trl.__version__)"],
                                   capture_output=True, text=True, timeout=180, stdin=subprocess.DEVNULL, check=False)
                if r.returncode != 0:
                    errors.append("training env is missing packages: " + (r.stderr.strip().splitlines() or ["?"])[-1])
                else:
                    n, trl_v = r.stdout.split()[:2]
                    info["cuda_devices"], info["trl"] = int(n), trl_v
                    bad = sorted({t["gpu"] for t in v["tracks"] if t["gpu"] >= int(n)})
                    if bad:
                        errors.append(f"tracks use GPU(s) {bad} but the training env sees {n}")
            except (OSError, subprocess.TimeoutExpired, ValueError) as e:
                errors.append(f"could not probe training env: {e}")
        if shutil.which("nvidia-smi"):
            try:
                r = subprocess.run(["nvidia-smi", "--query-gpu=index,name,memory.used,memory.total",
                                    "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=20,
                                   check=False)
                gpus = []
                for line in r.stdout.strip().splitlines():
                    i, name, used, total = [x.strip() for x in line.split(",")]
                    gpus.append({"index": int(i), "name": name, "used_mb": int(used), "total_mb": int(total)})
                    if int(i) in {t["gpu"] for t in v["tracks"]} and int(total) - int(used) < 4096:
                        warns.append(f"GPU {i} has only {int(total) - int(used)} MiB free — stop the model "
                                     "server on it (/models status) before training")
                info["gpus"] = gpus
            except (OSError, subprocess.TimeoutExpired, ValueError):
                pass
    else:
        if not _exe(COLAB_BIN):
            warns.append(f"colab CLI not found at {COLAB_BIN} (set $COLAB_BIN); --execute will fail")
    # GGUF conversion happens for every run (even merge=none / single track)
    conv = find_converter(v)
    info["converter"] = conv
    if not conv:
        warns.append("llama.cpp convert_lora_to_gguf.py not found (set llama_cpp_dir) — adapters stay PEFT-only")
    if not (v["base_hf_path"] and os.path.isfile(os.path.join(v["base_hf_path"], "config.json"))):
        warns.append("base_hf_path missing or has no config.json — needed to convert adapters to GGUF")
    for t in v["tracks"]:
        try:
            with open(t["train_file"], encoding="utf-8") as fh:
                first = json.loads(fh.readline() or "{}")
        except (OSError, ValueError):
            errors.append(f"track {t['name']}: training file unreadable")
            continue
        if t["method"] == "dpo" and not {"prompt", "chosen", "rejected"} <= set(first):
            errors.append(f"track {t['name']}: DPO needs prompt/chosen/rejected rows (use a forge dpo_*.jsonl)")
        if t["method"] == "sft" and {"chosen", "rejected"} <= set(first) and "messages" not in first:
            warns.append(f"track {t['name']}: looks like a preference file; did you mean method=dpo?")
    if os.path.isdir(os.path.join(runs_dir(), v["name"])):
        errors.append(f"run {v['name']} already exists — pick a new name")
    return {"errors": errors, "warnings": warns, "info": info}


def _track_conf(v, t, train_file, val_file, out_dir):
    return {"name": f"{v['name']}-{t['name']}", "base_model": v["base_model"], "train_file": train_file,
            "val_file": val_file, "mode": t["method"], **v["hyper"], "adapter_gguf_dir": out_dir,
            "created_at": int(dt.datetime.now().timestamp())}


def _write_json(path, obj):
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


def start_local(v, rd, dry):
    q = shlex.quote
    lines = ["#!/usr/bin/env bash", "# Generated by scripts/training/runs.py — one run, tracks grouped by GPU.",
             "set -uo pipefail", f"cd {q(rd)}", "echo running > state",
             "run_track() {", '  local n="$1" g="$2"; shift 2',
             '  ( cd "tracks/$n" || exit 1',
             "    echo running > state",
             f'    CUDA_VISIBLE_DEVICES="$g" PYTHONUNBUFFERED=1 {q(v["train_python"] or "python3")} train_lora.py --config config.json "$@" > train.log 2>&1',
             '    rc=$?; echo "$rc" > exit_code',
             '    if [ "$rc" = 0 ]; then echo done > state; else echo failed > state; fi )', "}"]
    by_gpu = {}
    for t in v["tracks"]:
        td = os.path.join(rd, "tracks", t["name"])
        os.makedirs(td, exist_ok=True)
        shutil.copyfile(KIT, os.path.join(td, "train_lora.py"))
        _write_json(os.path.join(td, "config.json"),
                    _track_conf(v, t, t["train_file"], t["val_file"], os.path.join(models_dir(), "adapters")))
        with open(os.path.join(td, "state"), "w") as fh:
            fh.write("queued\n")
        extra = ["--init-adapter", t["init_adapter"]] if t["init_adapter"] else []
        by_gpu.setdefault(t["gpu"], []).append(" ".join(["run_track", q(t["name"]), str(t["gpu"])] +
                                                        [q(x) for x in extra]))
    for g, cmds in sorted(by_gpu.items()):
        lines.append("( " + " ; ".join(cmds) + " ) &")
    lines += ["wait"]
    if v["merge"]["method"] != "none":
        lines += [f"{q(sys.executable)} {q(os.path.abspath(__file__))} merge {q(v['name'])} > merge.log 2>&1 "
                  "&& echo done > state || echo merge_failed > state"]
    else:
        lines += ["grep -qx failed tracks/*/state && echo failed > state || echo done > state"]
    drv = os.path.join(rd, "driver.sh")
    with open(drv, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    os.chmod(drv, 0o755)
    meta = {"name": v["name"], "backend": "local", "created": dt.datetime.now().isoformat(timespec="seconds"),
            "spec": v, "state": "planned" if dry else "running", "pid": None}
    if not dry:
        log = open(os.path.join(rd, "driver.log"), "ab")
        p = subprocess.Popen(["bash", drv], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                             start_new_session=True, cwd=rd, env={**os.environ, "GEORGE_DIR": GEORGE,
                                                                  "LODGE_DIR": LODGE})
        meta["pid"] = p.pid
    _write_json(os.path.join(rd, "run.json"), meta)
    return meta


# ── colab ──────────────────────────────────────────────────────────────────────

def _colab(args, stdin=None, timeout=300):
    r = subprocess.run([COLAB_BIN, "--auth=adc"] + args, input=stdin, capture_output=True, text=True,
                       timeout=timeout, check=False)
    return r.returncode, r.stdout, r.stderr


def _session(v, t):
    return re.sub(r"[^a-z0-9-]", "-", f"bl-{v['name']}-{t['name']}")[:60]


def start_colab(v, rd, execute):
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
        conf = _track_conf(v, t, "train.jsonl", "val.jsonl" if t["val_file"] else None, "/content/out")
        _write_json(os.path.join(stage, "config.json"), conf)
        tar = os.path.join(td, "bundle.tar.gz")
        with tarfile.open(tar, "w:gz") as tf:
            tf.add(stage, arcname=".")
        s = _session(v, t)
        remote = f"/content/{s}"
        gpu = ["--gpu", v["colab"]["gpu"]] + (["--high-mem"] if v["colab"]["high_mem"] else [])
        launch = ("import subprocess, os\n"
                  f"os.makedirs({remote!r}, exist_ok=True)\n"
                  f"subprocess.run(['tar','-xzf','/content/{s}.tar.gz','-C',{remote!r}], check=True)\n"
                  "cmd = ('pip install -q \"torch>=2.3\" \"transformers>=4.45\" \"peft>=0.12\" \"trl>=0.11\" '\n"
                  "       '\"datasets>=2.20\" accelerate bitsandbytes > /content/pip.log 2>&1; '\n"
                  f"       'cd {remote} && nohup python train_lora.py --config config.json > train.log 2>&1; "
                  f"echo $? > exit_code; tar -czf /content/{s}_adapter.tar.gz -C output adapter')\n"
                  "subprocess.Popen(['bash', '-c', cmd])\nprint('DISPATCHED')\n")
        steps = [{"do": "new", "argv": ["new", "-s", s] + gpu},
                 {"do": "upload", "argv": ["upload", "-s", s, tar, f"/content/{s}.tar.gz"]},
                 {"do": "launch", "argv": ["exec", "-s", s], "stdin": launch}]
        plan.append({"track": t["name"], "session": s, "remote_dir": remote, "steps": steps})
        with open(os.path.join(td, "state"), "w") as fh:
            fh.write("planned\n")
        shutil.rmtree(stage, ignore_errors=True)
    meta = {"name": v["name"], "backend": "colab", "created": dt.datetime.now().isoformat(timespec="seconds"),
            "spec": v, "state": "planned", "plan": plan}
    if execute:
        if not _exe(COLAB_BIN):
            raise SpecError(f"colab CLI not found at {COLAB_BIN}")
        for tp in plan:
            td = os.path.join(rd, "tracks", tp["track"])
            for st in tp["steps"]:
                rc, out, err = _colab(st["argv"], st.get("stdin"))
                if rc != 0 or (st["do"] == "launch" and "DISPATCHED" not in out):
                    with open(os.path.join(td, "state"), "w") as fh:
                        fh.write("failed\n")
                    tp["error"] = f"{st['do']}: {(err or out).strip()[-300:]}"
                    _colab(["delete", "-s", tp["session"]])  # never leave a paid VM idling after a failure
                    break
            else:
                with open(os.path.join(td, "state"), "w") as fh:
                    fh.write("running\n")
        meta["state"] = "running"
    _write_json(os.path.join(rd, "run.json"), meta)
    return meta


def collect_colab(name):
    rd = run_dir(name)
    meta = _read_json(os.path.join(rd, "run.json"), {})
    if meta.get("backend") != "colab":
        raise SpecError("collect is only for colab runs")
    res = {}
    for tp in meta.get("plan", []):
        td = os.path.join(rd, "tracks", tp["track"])
        s = tp["session"]
        rc, out, _ = _colab(["exec", "-s", s], stdin=(
            "import os\n"
            f"print('EXIT', open('{tp['remote_dir']}/exit_code').read().strip() "
            f"if os.path.exists('{tp['remote_dir']}/exit_code') else 'running')\n"), timeout=120)
        status = (out.split("EXIT", 1)[-1].strip() if "EXIT" in out else "unknown")
        if status == "running":
            res[tp["track"]] = "still running"
            continue
        if status == "0":
            local = os.path.join(td, "adapter.tar.gz")
            rc, _, err = _colab(["download", "-s", s, f"/content/{s}_adapter.tar.gz", local], timeout=900)
            if rc == 0 and os.path.isfile(local):
                with tarfile.open(local) as tf:
                    safe = [m for m in tf.getmembers() if not (m.name.startswith("/") or ".." in m.name.split("/"))
                            and (m.isfile() or m.isdir())]
                    os.makedirs(os.path.join(td, "output"), exist_ok=True)
                    tf.extractall(os.path.join(td, "output"), members=safe)  # noqa: S202 — members filtered
                with open(os.path.join(td, "state"), "w") as fh:
                    fh.write("done\n")
                res[tp["track"]] = "downloaded"
            else:
                res[tp["track"]] = f"download failed: {err.strip()[-200:]}"
                continue
        else:
            with open(os.path.join(td, "state"), "w") as fh:
                fh.write("failed\n")
            res[tp["track"]] = f"training exited {status}"
        _colab(["delete", "-s", s])
    return res


# ── status / merge ─────────────────────────────────────────────────────────────

def _alive(pid):
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def track_status(td):
    st = {"state": (open(os.path.join(td, "state")).read().strip() if os.path.isfile(os.path.join(td, "state"))
                    else "?")}
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
    run_state = open(os.path.join(rd, "state")).read().strip() if os.path.isfile(os.path.join(rd, "state")) \
        else meta.get("state")
    if meta.get("backend") == "local" and run_state == "running" and not _alive(meta.get("pid")):
        run_state = "stopped"
    tracks = {t["name"]: track_status(os.path.join(rd, "tracks", t["name"])) for t in meta["spec"]["tracks"]}
    merged = _read_json(os.path.join(rd, "merged.json"))
    return {"name": name, "backend": meta.get("backend"), "state": run_state, "created": meta.get("created"),
            "tracks": tracks, "merged": merged, "dir": rd}


def list_runs():
    out = []
    for rj in sorted(glob.glob(os.path.join(runs_dir(), "*", "run.json")), key=os.path.getmtime, reverse=True):
        try:
            out.append({k: v for k, v in status(os.path.basename(os.path.dirname(rj))).items() if k != "tracks"})
        except SpecError:
            continue
    return out


def cancel(name):
    rd = run_dir(name)
    meta = _read_json(os.path.join(rd, "run.json"), {})
    if meta.get("backend") == "colab":
        for tp in meta.get("plan", []):
            _colab(["delete", "-s", tp["session"]])
    elif _alive(meta.get("pid")):
        try:
            os.killpg(os.getpgid(meta["pid"]), signal.SIGTERM)
        except (OSError, ProcessLookupError):
            pass
    with open(os.path.join(rd, "state"), "w") as fh:
        fh.write("cancelled\n")
    return {"name": name, "state": "cancelled"}


def merge(name):
    rd = run_dir(name)
    meta = _read_json(os.path.join(rd, "run.json"))
    if not meta:
        raise SpecError(f"no run named {name}")
    v = meta["spec"]
    conv = find_converter(v)
    py = v["train_python"] if _exe(v["train_python"]) else sys.executable
    ggufs, notes = [], []
    for t in v["tracks"]:
        td = os.path.join(rd, "tracks", t["name"])
        ad = os.path.join(td, "output", "adapter")
        out = os.path.join(td, "adapter.gguf")
        if not os.path.isdir(ad):
            notes.append(f"{t['name']}: no adapter (track state {track_status(td)['state']})")
            continue
        if not os.path.isfile(out):
            if not conv or not os.path.isfile(os.path.join(v["base_hf_path"], "config.json")):
                notes.append(f"{t['name']}: cannot convert (need llama_cpp_dir and base_hf_path)")
                continue
            r = subprocess.run([py, conv, ad, "--base", v["base_hf_path"], "--outtype", "f16", "--outfile", out],
                               capture_output=True, text=True, timeout=3600, stdin=subprocess.DEVNULL, check=False)
            if r.returncode != 0:
                notes.append(f"{t['name']}: convert failed: {(r.stderr or r.stdout).strip()[-300:]}")
                continue
        ggufs.append(out)
    dest_dir = os.path.join(models_dir(), "adapters")
    os.makedirs(dest_dir, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    outputs = []
    method = v["merge"]["method"]
    if len(ggufs) == 1 or method == "none":
        for g in ggufs:
            dst = os.path.join(dest_dir, f"{v['name']}-{os.path.basename(os.path.dirname(g))}-{stamp}.gguf")
            shutil.copyfile(g, dst)
            outputs.append(dst)
    elif ggufs:
        dst = os.path.join(dest_dir, f"{v['name']}-{method}-{stamp}.gguf")
        env = dict(os.environ)
        if conv:
            env["PYTHONPATH"] = os.path.join(os.path.dirname(conv), "gguf-py") + os.pathsep + env.get("PYTHONPATH", "")
        argv = [py, MERGE, "--adapters", *ggufs, "--output", dst, "--method", method,
                "--target_rank", str(v["merge"]["target_rank"])]
        if v["merge"]["weights"]:
            argv += ["--weights", *[str(w) for w in v["merge"]["weights"]]]
        r = subprocess.run(argv, capture_output=True, text=True, timeout=3600, stdin=subprocess.DEVNULL,
                           check=False, env=env)
        if r.returncode != 0:
            notes.append(f"merge failed: {(r.stderr or r.stdout).strip()[-400:]}")
        else:
            outputs.append(dst)
    res = {"name": name, "method": method, "inputs": ggufs, "outputs": outputs, "notes": notes,
           "at": dt.datetime.now().isoformat(timespec="seconds")}
    _write_json(os.path.join(rd, "merged.json"), res)
    if not outputs:
        raise SpecError("nothing merged: " + "; ".join(notes or ["no adapters"]))
    return res


TEMPLATE = {
    "name": "recovery-v1", "backend": "local", "base_model": "org/base-model",
    "base_hf_path": "~/hf/base-model", "train_python": "~/venvs/train/bin/python", "llama_cpp_dir": "~/llama.cpp",
    "tracks": [{"name": "recovery", "method": "sft", "train": "exports:forge_error-recovery_X/sft_train.jsonl",
                "val": "exports:forge_error-recovery_X/sft_val.jsonl", "gpu": 0},
               {"name": "loops", "method": "dpo", "train": "exports:forge_failure-modes_X/dpo_train.jsonl", "gpu": 1}],
    "hyper": {k: v[3] for k, v in HYPER.items()} | {"load_in_4bit": True},
    "merge": {"method": "svd", "target_rank": 32, "weights": None},
    "colab": {"gpu": "A100", "high_mem": True},
}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("template")
    for n in ("plan", "start"):
        p = sub.add_parser(n)
        p.add_argument("spec")
        if n == "start":
            p.add_argument("--dry-run", action="store_true", help="write the run dir/driver/bundles, launch nothing")
            p.add_argument("--execute", action="store_true", help="colab: actually provision and launch")
            p.add_argument("--force", action="store_true", help="local: start despite preflight errors")
    for n in ("status", "cancel", "merge", "collect"):
        sub.add_parser(n).add_argument("name")
    sub.add_parser("list")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "template":
            res = TEMPLATE
        elif a.cmd in ("plan", "start"):
            spec = _read_json(a.spec)
            if spec is None:
                raise SpecError(f"cannot read spec {a.spec}")
            v = validate(spec)
            pf = preflight(v)
            if a.cmd == "plan":
                res = {"valid": True, "spec": v, **pf}
            else:
                dry = a.dry_run or (v["backend"] == "colab" and not a.execute)
                if pf["errors"] and v["backend"] == "local" and not (dry or a.force):
                    raise SpecError("preflight failed: " + "; ".join(pf["errors"]))
                rd = os.path.join(runs_dir(), v["name"])
                if os.path.isdir(rd):
                    raise SpecError(f"run {v['name']} already exists")
                os.makedirs(rd)
                _write_json(os.path.join(rd, "spec.json"), spec)
                meta = start_local(v, rd, dry) if v["backend"] == "local" else start_colab(v, rd, a.execute)
                res = {"name": v["name"], "dir": rd, "state": meta["state"], "warnings": pf["warnings"],
                       "errors": pf["errors"],
                       "next": ("cd %s && bash driver.sh   (or re-run without --dry-run)" % rd) if dry and
                       v["backend"] == "local" else ("runs.py start <spec> --execute to provision Colab" if dry
                                                     else f"runs.py status {v['name']}")}
        elif a.cmd == "status":
            res = status(a.name)
        elif a.cmd == "list":
            res = list_runs()
        elif a.cmd == "cancel":
            res = cancel(a.name)
        elif a.cmd == "merge":
            res = merge(a.name)
        else:
            res = collect_colab(a.name)
    except SpecError as e:
        print(json.dumps({"error": str(e)}))
        return 1
    print(json.dumps(res, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
