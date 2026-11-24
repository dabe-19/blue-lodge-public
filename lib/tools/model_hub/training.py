"""Fine-tuning helpers: local datasets, Hugging Face dataset pulls, George-run export, LoRA training kits.

Blue Lodge does not train models itself (that needs a GPU training stack the lodge does not ship).
Instead it prepares everything around training so the loop closes cleanly:

  1. datasets      list what is in data/training/ and George's exported runs (.george/datasets/)
  2. dataset-pull  fetch a dataset file from Hugging Face (sha256-verified when the hub provides one)
  3. export-runs   turn George's own successful runs into train/val JSONL (scripts/training/export_lora_dataset.py)
  3b. forge        build focused SFT/DPO datasets from transcripts (scripts/training/forge.py)
  4. train-kit     write a self-contained LoRA SFT/DPO kit (config + script + README) for any base model; run it in
                   your own training environment (local GPU, Colab, cloud), convert the adapter to GGUF, drop
                   it into MODELS_DIR/adapters, and it shows up in the Library ready to attach.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path
from typing import Any

from .common import REPO_RE, SHA256_RE, HubError, george_dir, get_json, lodge_dir, open_url, safe_relpath
from .hw import models_dir
from .providers import HuggingFace

DATA_EXT = (".jsonl", ".json", ".parquet", ".csv", ".txt", ".arrow")
MAX_DATASET = 50 * (1 << 30)
KIT_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{1,47}$")


def _roots() -> dict[str, Path]:
    return {"training": lodge_dir() / "data" / "training", "exports": george_dir() / "datasets"}


def resolve_dataset(ds_id: str) -> Path:
    """'training:<rel>' or 'exports:<rel>' -> absolute path, boundary-checked."""
    root_name, _, rel = (ds_id or "").partition(":")
    roots = _roots()
    if root_name not in roots or not safe_relpath(rel) or not rel.lower().endswith(DATA_EXT):
        raise HubError("dataset id must look like training:<file> or exports:<dir>/<file>")
    base = roots[root_name].resolve()
    p = (roots[root_name] / rel).resolve()
    if not str(p).startswith(str(base) + os.sep) or not p.is_file():
        raise HubError(f"dataset {ds_id} not found")
    return p


def _rows(p: Path) -> int | None:
    if p.suffix.lower() not in (".jsonl", ".txt", ".csv") or p.stat().st_size > 512 * (1 << 20):
        return None
    n = 0
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            n += chunk.count(b"\n")
    return n


def _format(p: Path) -> str | None:
    if p.suffix.lower() != ".jsonl":
        return None
    try:
        with open(p, encoding="utf-8") as f:
            first = json.loads(f.readline() or "{}")
    except (ValueError, UnicodeDecodeError, OSError):
        return "unreadable"
    if not isinstance(first, dict):
        return "other"
    if "messages" in first or "conversations" in first:
        return "chat"
    if "prompt" in first and ("completion" in first or "response" in first):
        return "prompt/completion"
    if "instruction" in first and "output" in first:
        return "instruction"
    if "text" in first:
        return "text"
    return "other"


def list_datasets() -> dict[str, Any]:
    out = []
    for root_name, root in _roots().items():
        if not root.is_dir():
            continue
        for p in sorted(root.rglob("*")):
            if len(p.relative_to(root).parts) > 3 or not p.is_file() or not p.name.lower().endswith(DATA_EXT):
                continue
            if p.name in ("manifest.json",) or any(x.startswith(".") for x in p.relative_to(root).parts):
                continue
            st = p.stat()
            out.append({"id": f"{root_name}:{p.relative_to(root).as_posix()}", "root": root_name,
                        "rel": p.relative_to(root).as_posix(), "size": st.st_size, "mtime": int(st.st_mtime),
                        "rows": _rows(p), "format": _format(p)})
            if len(out) >= 500:
                break
    return {"roots": {k: str(v) for k, v in _roots().items()}, "datasets": out}


def dataset_files(repo: str) -> dict[str, Any]:
    if not REPO_RE.match(repo or ""):
        raise HubError("invalid dataset repo id")
    hf = HuggingFace()
    tree = get_json(f"{hf.base}/api/datasets/{repo}/tree/main?recursive=1", token=hf.token())
    files = []
    for t in tree if isinstance(tree, list) else []:
        path = t.get("path", "")
        if t.get("type") == "directory" or not safe_relpath(path) or not path.lower().endswith(DATA_EXT):
            continue
        lfs = t.get("lfs") or {}
        sha = (lfs.get("oid") or "").lower()
        files.append({"path": path, "size": int(t.get("size") or 0), "sha256": sha if SHA256_RE.match(sha) else None})
        if len(files) >= 500:
            break
    return {"repo": repo, "files": files}


def _progress(job: str, **kw: Any) -> None:
    from .installer import _progress as prog
    prog(job, **kw)


def pull_dataset(repo: str, path: str) -> dict[str, Any]:
    info = next((f for f in dataset_files(repo)["files"] if f["path"] == path), None)
    if not info:
        raise HubError(f"{path} is not a dataset file in {repo} (supported: {', '.join(DATA_EXT)})")
    if not 0 < info["size"] <= MAX_DATASET:
        raise HubError("dataset file is empty or larger than 50 GiB")
    slug = re.sub(r"[^A-Za-z0-9._-]+", "_", f"{repo.replace('/', '__')}__{path.replace('/', '_')}")[:150]
    dest_dir = lodge_dir() / "data" / "training" / "active"
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / slug
    job = "ds-" + re.sub(r"[^a-z0-9._-]+", "-", slug.lower())[:60].strip("-.")
    hf = HuggingFace()
    url = f"{hf.base}/datasets/{repo}/resolve/main/{urllib.parse.quote(path)}"
    _progress(job, state="running", kind="dataset", total=info["size"], done=0, file=path, error=None)
    done = 0

    def bump(n: int) -> None:
        nonlocal done
        done += n
        if done % (32 << 20) < n or done >= info["size"]:
            _progress(job, done=done)

    try:
        if info["sha256"]:
            from .installer import download_file
            download_file(job, url, hf.token(), dest, info["size"], info["sha256"], bump)
        else:
            part = dest.with_name(dest.name + ".part")
            with open_url(url, token=hf.token(), timeout=60) as r, open(part, "wb") as out:
                for chunk in iter(lambda: r.read(1 << 20), b""):
                    bump(len(chunk))
                    if done > info["size"]:
                        raise HubError("server sent more bytes than expected")
                    out.write(chunk)
            if part.stat().st_size != info["size"]:
                part.unlink(missing_ok=True)
                raise HubError("incomplete download")
            os.replace(part, dest)
    except HubError as e:
        _progress(job, state="failed", error=str(e))
        raise
    _progress(job, state="done", done=info["size"])
    return {"job": job, "id": f"training:active/{slug}", "size": info["size"], "verified": bool(info["sha256"]),
            "rows": _rows(dest), "format": _format(dest)}


def export_runs(since: str | None = None) -> dict[str, Any]:
    script = lodge_dir() / "scripts" / "training" / "export_lora_dataset.py"
    argv = [sys.executable, str(script), "--george-dir", str(george_dir())]
    if since:
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", since):
            raise HubError("since must be YYYY-MM-DD")
        argv += ["--since", since]
    r = subprocess.run(argv, capture_output=True, text=True, timeout=600, stdin=subprocess.DEVNULL, check=False,
                       cwd=str(lodge_dir()))
    if r.returncode != 0:
        raise HubError("export failed: " + (r.stderr or r.stdout).strip()[-400:])
    try:
        res = json.loads(r.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        raise HubError("export produced no summary") from None
    out = Path(res.get("out", ""))
    try:
        rel = out.resolve().relative_to((george_dir() / "datasets").resolve()).as_posix()
        res["train_id"] = f"exports:{rel}/train.jsonl"
        res["val_id"] = f"exports:{rel}/val.jsonl"
    except ValueError:
        pass
    return res


# ── dataset forge (scripts/training/forge.py) ──────────────────────────────────

FORGE_FOCUS_RE = re.compile(r"^(mix|[a-z][a-z-]{2,30})(,[a-z][a-z-]{2,30}){0,7}$")


def _forge(argv_tail: list[str], timeout: int) -> dict[str, Any]:
    script = lodge_dir() / "scripts" / "training" / "forge.py"
    argv = [sys.executable, str(script), "--george-dir", str(george_dir())] + argv_tail
    r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL, check=False,
                       cwd=str(lodge_dir()))
    if r.returncode != 0:
        raise HubError("forge failed: " + (r.stderr or r.stdout).strip()[-400:])
    try:
        return json.loads(r.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        raise HubError("forge produced no summary") from None


def forge_recipes() -> dict[str, Any]:
    return _forge(["recipes", "--json"], 30)


def forge_pantry() -> dict[str, Any]:
    return _forge(["pantry", "--json"], 600)


def forge_build(cfg: dict[str, Any]) -> dict[str, Any]:
    focus = str(cfg.get("focus", "mix")).strip().lower()
    if not FORGE_FOCUS_RE.match(focus):
        raise HubError("focus: 'mix' or comma-separated recipe names")
    count = _num(cfg.get("count", 200), int, 1, 200000, "count")
    fmt = str(cfg.get("format", "both"))
    if fmt not in ("sft", "dpo", "both"):
        raise HubError("format must be sft, dpo or both")
    argv = ["build", "--json", "--focus", focus, "--count", str(count), "--format", fmt,
            "--val-frac", str(_num(cfg.get("val_frac", 0.1), float, 0.0, 0.49, "val_frac")),
            "--seed", str(_num(cfg.get("seed", 7), int, 0, 2**31 - 1, "seed"))]
    if cfg.get("since"):
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(cfg["since"])):
            raise HubError("since must be YYYY-MM-DD")
        argv += ["--since", str(cfg["since"])]
    if cfg.get("drop_reasoning"):
        argv.append("--drop-reasoning")
    if cfg.get("include_curricula"):
        argv.append("--include-curricula")
    if cfg.get("augment_llm"):
        argv += ["--augment-llm", "--max-llm-calls", str(_num(cfg.get("max_llm_calls", 100), int, 1, 2000,
                                                                  "max_llm_calls"))]
    if cfg.get("max_context"):
        argv += ["--max-context", str(_num(cfg["max_context"], int, 2000, 400000, "max_context"))]
    from .installer import downloads_dir
    job = "forge"
    argv += ["--progress-file", str(downloads_dir() / f"{job}.json")]
    _progress(job, kind="forge", state="running", done=0, total=count, error=None, focus=focus)
    try:
        res = _forge(argv, 60 * 60 * 3 if cfg.get("augment_llm") else 900)
    except (HubError, subprocess.TimeoutExpired) as e:
        _progress(job, state="error", error=str(e)[-300:])
        raise HubError(str(e)) from None
    rel = None
    try:
        rel = Path(res.get("out", "")).resolve().relative_to((george_dir() / "datasets").resolve()).as_posix()
    except ValueError:
        pass
    _progress(job, state="done", done=res.get("produced", 0), total=count, out=res.get("out"),
              shortfall=res.get("shortfall", 0))
    if rel:
        res["ids"] = {k: f"exports:{rel}/{k}.jsonl" for k in ("sft_train", "sft_val", "dpo_train", "dpo_val")
                      if res.get(k)}
    return res


# ── training kits ──────────────────────────────────────────────────────────────

def kits_dir() -> Path:
    d = george_dir() / "training" / "kits"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _num(v: Any, typ: type, lo: float, hi: float, name: str) -> Any:
    try:
        x = typ(v)
    except (TypeError, ValueError):
        raise HubError(f"{name} must be a number") from None
    if not lo <= x <= hi:
        raise HubError(f"{name} must be in [{lo}, {hi}]")
    return x


def make_kit(cfg: dict[str, Any]) -> dict[str, Any]:
    name = str(cfg.get("name", ""))
    if not KIT_NAME_RE.match(name):
        raise HubError("kit name: lowercase a-z0-9._- (2-48 chars)")
    base = str(cfg.get("base_model", ""))
    if not REPO_RE.match(base):
        raise HubError("base_model must be a Hugging Face repo id (org/name) of the unquantized base model")
    train = resolve_dataset(str(cfg.get("train", "")))
    val = resolve_dataset(str(cfg["val"])) if cfg.get("val") else None
    mode = str(cfg.get("mode", "sft"))
    if mode not in ("sft", "dpo"):
        raise HubError("mode must be sft or dpo")
    conf = {
        "name": name, "base_model": base, "train_file": str(train), "val_file": str(val) if val else None,
        "epochs": _num(cfg.get("epochs", 2), float, 0.1, 50, "epochs"),
        "learning_rate": _num(cfg.get("learning_rate", 1e-4), float, 1e-7, 1e-2, "learning_rate"),
        "lora_r": _num(cfg.get("lora_r", 16), int, 1, 512, "lora_r"),
        "lora_alpha": _num(cfg.get("lora_alpha", 32), int, 1, 1024, "lora_alpha"),
        "lora_dropout": _num(cfg.get("lora_dropout", 0.05), float, 0.0, 0.5, "lora_dropout"),
        "max_seq_len": _num(cfg.get("max_seq_len", 4096), int, 256, 262144, "max_seq_len"),
        "batch_size": _num(cfg.get("batch_size", 1), int, 1, 256, "batch_size"),
        "grad_accum": _num(cfg.get("grad_accum", 8), int, 1, 1024, "grad_accum"),
        "load_in_4bit": bool(cfg.get("load_in_4bit", True)),
        "mode": mode,
        "dpo_beta": _num(cfg.get("dpo_beta", 0.1), float, 0.01, 2.0, "dpo_beta"),
        "adapter_gguf_dir": str(models_dir() / "adapters"),
        "created_at": int(time.time()),
    }
    d = kits_dir() / name
    d.mkdir(parents=True, exist_ok=True)
    tpl = lodge_dir() / "scripts" / "training" / "kit"
    for f in ("train_lora.py", "README.md"):
        shutil.copyfile(tpl / f, d / f)
    (d / "config.json").write_text(json.dumps(conf, indent=2))
    run = d / "run.sh"
    run.write_text("#!/usr/bin/env bash\n# Generated by Blue Lodge. Run inside your training environment (see README.md).\n"
                   "set -euo pipefail\ncd \"$(dirname \"$0\")\"\npython train_lora.py --config config.json \"$@\"\n")
    run.chmod(0o755)
    return {"kit": name, "dir": str(d), "config": conf,
            "next": f"cd {d} && read README.md, then ./run.sh in an environment with torch+transformers+peft+trl"}


def list_kits() -> list[dict[str, Any]]:
    out = []
    for c in sorted(kits_dir().glob("*/config.json")):
        try:
            conf = json.loads(c.read_text())
        except (OSError, ValueError):
            continue
        out.append({"name": conf.get("name"), "dir": str(c.parent), "base_model": conf.get("base_model"),
                    "train_file": conf.get("train_file"), "created_at": conf.get("created_at"),
                    "has_output": (c.parent / "output").is_dir()})
    return out
