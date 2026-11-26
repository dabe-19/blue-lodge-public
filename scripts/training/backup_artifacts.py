#!/usr/bin/env python3
"""
scripts/training/backup_artifacts.py
Backs up promoted SVD-32 GGUF adapters, lineage manifests, and benchmark scorecards to:
  1. Google Drive (via Google Drive API using ADC credentials, or rclone / local Drive mount)
  2. Private Hugging Face Hub repository (via huggingface_hub + HF_TOKEN from .george/keys.conf)

Usage:
  backup_artifacts.py status
  backup_artifacts.py backup --file PATH --model SLUG --role ROLE [--target drive|hf|both] [--hf-repo org/repo]
  backup_artifacts.py backup --all [--target drive|hf|both]
  backup_artifacts.py publish --model SLUG --role ROLE --hf-repo user/repo [--public] [--template PATH] [--dry-run]
  backup_artifacts.py pull-adapter --hf-repo org/repo --model SLUG [--role core-agent] [--file NAME.gguf] [--activate] [--dry-run]
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_credits as cc  # noqa: E402
import sync_tool_schemas as sts  # noqa: E402

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path(__file__).resolve().parent.parent.parent))
GEORGE_DIR = Path(os.environ.get("GEORGE_DIR", LODGE_DIR / ".george"))
MODELS_DIR = Path(os.environ.get("MODELS_DIR", Path.home() / "models"))


def _read_policy() -> dict:
    p = GEORGE_DIR / "training" / "policy.json"
    if p.is_file():
        try:
            return json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            pass
    return {}


def backup_status() -> dict:
    prereqs = cc.get_prerequisites()
    policy = _read_policy()
    hf_repo = policy.get("hf_backup_repo") or os.environ.get("HF_BACKUP_REPO") or ""
    drive_folder = policy.get("drive_backup_folder") or os.environ.get("DRIVE_BACKUP_FOLDER") or "BlueLodge/models/adapters"

    hf_lib = False
    try:
        __import__("huggingface_hub")
        hf_lib = True
    except ImportError:
        pass

    drive_api_lib = False
    try:
        __import__("google.auth")
        drive_api_lib = True
    except ImportError:
        pass

    rclone_bin = shutil.which("rclone")
    return {
        "hf": {
            "ready": bool(prereqs["hf_token"]["configured"] and hf_lib and hf_repo),
            "token_configured": prereqs["hf_token"]["configured"],
            "library_installed": hf_lib,
            "repo": hf_repo,
        },
        "drive": {
            "ready": bool((prereqs["adc_credentials"]["configured"] and drive_api_lib) or rclone_bin),
            "adc_configured": prereqs["adc_credentials"]["configured"],
            "google_api_installed": drive_api_lib,
            "rclone_available": bool(rclone_bin),
            "folder": drive_folder,
        },
    }


def upload_to_hf(local_path: Path, repo_id: str, path_in_repo: str,
                 private: bool = True, commit_message: str | None = None) -> dict:
    token, _ = cc._read_key_from_files(("HF_TOKEN", "HUGGINGFACE_TOKEN", "HUGGING_FACE_HUB_TOKEN"))
    if not token:
        return {"status": "error", "target": "hf", "message": "HF_TOKEN not configured in .george/keys.conf"}
    if not repo_id:
        return {"status": "error", "target": "hf", "message": "HF backup repo not configured (set hf_backup_repo in Forge policy)"}
    try:
        from huggingface_hub import HfApi
    except ImportError:
        return {"status": "error", "target": "hf", "message": "huggingface_hub not installed (uv pip install huggingface-hub)"}

    api = HfApi(token=token)
    api.create_repo(repo_id=repo_id, repo_type="model", private=private, exist_ok=True)
    api.upload_file(
        path_or_fileobj=str(local_path),
        path_in_repo=path_in_repo,
        repo_id=repo_id,
        repo_type="model",
        commit_message=commit_message or f"chore(backup): archive {local_path.name}",
    )
    return {
        "status": "ok",
        "target": "hf",
        "private": private,
        "uri": f"https://huggingface.co/{repo_id}/blob/main/{path_in_repo}",
        "at": dt.datetime.now().isoformat(timespec="seconds"),
    }


def upload_to_drive(local_path: Path, folder_path: str, remote_name: str) -> dict:
    # Fast path 1: rclone gdrive remote if operator configured rclone
    rclone_bin = shutil.which("rclone")
    if rclone_bin:
        remotes = subprocess.run([rclone_bin, "listremotes"], capture_output=True, text=True, check=False).stdout
        for rname in ("gdrive:", "google-drive:", "drive:"):
            if rname in remotes:
                dest = f"{rname}{folder_path.strip('/')}/{remote_name}"
                r = subprocess.run([rclone_bin, "copyto", str(local_path), dest], capture_output=True, text=True, check=False)
                if r.returncode == 0:
                    return {"status": "ok", "target": "drive", "uri": dest, "at": dt.datetime.now().isoformat(timespec="seconds")}

    # Fast path 2: Pure stdlib Google Drive REST API v3 via ADC credentials (zero popups, no googleapiclient needed)
    try:
        import urllib.parse
        import urllib.request
        import google.auth
        from google.auth.transport.requests import Request
    except ImportError:
        return {
            "status": "error",
            "target": "drive",
            "message": "Install google-auth or configure rclone 'gdrive:' for Drive backup.",
        }

    try:
        creds, proj = google.auth.default()
        creds.refresh(Request())
        qp = getattr(creds, "quota_project_id", None) or proj or ""
        if not qp:
            for cand in (Path.home() / ".config/gcloud/application_default_credentials.json", Path("/root/.config/gcloud/application_default_credentials.json")):
                try:
                    if cand.is_file():
                        qp = json.loads(cand.read_text(encoding="utf-8")).get("quota_project_id", "")
                        if qp:
                            break
                except OSError:
                    continue
        hdr = {"Authorization": f"Bearer {creds.token}"}
        if qp:
            hdr["X-Goog-User-Project"] = qp

        parent_id = "root"
        for part in [x for x in folder_path.strip("/").split("/") if x]:
            q = f"name='{part.replace(chr(39), '')}' and mimeType='application/vnd.google-apps.folder' and '{parent_id}' in parents and trashed=false"
            url = "https://www.googleapis.com/drive/v3/files?fields=files(id,name)&q=" + urllib.parse.quote(q)
            with urllib.request.urlopen(urllib.request.Request(url, headers=hdr), timeout=20) as r:
                found = json.loads(r.read()).get("files", [])
            if found:
                parent_id = found[0]["id"]
            else:
                meta = json.dumps({"name": part, "mimeType": "application/vnd.google-apps.folder", "parents": [parent_id]}).encode()
                creq = urllib.request.Request(
                    "https://www.googleapis.com/drive/v3/files?fields=id",
                    data=meta, headers={**hdr, "Content-Type": "application/json"}, method="POST",
                )
                with urllib.request.urlopen(creq, timeout=20) as r:
                    parent_id = json.loads(r.read())["id"]

        meta = json.dumps({"name": remote_name, "parents": [parent_id]}).encode("utf-8")
        init_req = urllib.request.Request(
            "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,webViewLink",
            data=meta,
            headers={**hdr, "Content-Type": "application/json; charset=UTF-8", "X-Upload-Content-Length": str(local_path.stat().st_size)},
            method="POST",
        )
        with urllib.request.urlopen(init_req, timeout=30) as r:
            upload_url = r.headers.get("Location")
        with open(local_path, "rb") as fh:
            data = fh.read()
        put_req = urllib.request.Request(
            upload_url, data=data,
            headers={"Content-Length": str(len(data)), "Content-Type": "application/octet-stream"},
            method="PUT",
        )
        with urllib.request.urlopen(put_req, timeout=600) as r:
            uploaded = json.loads(r.read())
        return {
            "status": "ok",
            "target": "drive",
            "file_id": uploaded.get("id"),
            "uri": uploaded.get("webViewLink") or f"gdrive://{folder_path}/{remote_name}",
            "at": dt.datetime.now().isoformat(timespec="seconds"),
        }
    except Exception as e:
        return {"status": "error", "target": "drive", "message": str(e)}


def backup_file(local_path: Path, model_slug: str, role: str, target: str, hf_repo: str | None = None) -> dict:
    if not local_path.is_file():
        return {"status": "error", "message": f"File not found: {local_path}"}
    policy = _read_policy()
    repo = hf_repo or policy.get("hf_backup_repo") or os.environ.get("HF_BACKUP_REPO") or ""
    drive_root = policy.get("drive_backup_folder") or "BlueLodge/models/adapters"

    results = []
    if target in ("hf", "both"):
        results.append(upload_to_hf(local_path, repo, f"{model_slug}/{role}/{local_path.name}"))
    if target in ("drive", "both"):
        results.append(upload_to_drive(local_path, f"{drive_root}/{model_slug}/{role}", local_path.name))

    # Persist backup record into lineage.json if present
    lineage_p = MODELS_DIR / "adapters" / model_slug / role / "lineage.json"
    if lineage_p.is_file():
        try:
            lin = json.loads(lineage_p.read_text(encoding="utf-8"))
            lin.setdefault("backups", []).append({
                "file": local_path.name,
                "results": results,
                "at": dt.datetime.now().isoformat(timespec="seconds"),
            })
            lineage_p.write_text(json.dumps(lin, indent=2) + "\n", encoding="utf-8")
        except (OSError, ValueError):
            pass

    ok_any = any(r.get("status") == "ok" for r in results)
    return {"status": "ok" if ok_any else "error", "file": str(local_path), "results": results}


def backup_all(target: str, hf_repo: str | None = None) -> dict:
    adapter_root = MODELS_DIR / "adapters"
    backed = []
    for lineage_fp in sorted(glob.glob(str(adapter_root / "*" / "*" / "lineage.json"))):
        role_dir = Path(lineage_fp).parent
        role = role_dir.name
        model_slug = role_dir.parent.name
        active = role_dir / "active.gguf"
        if active.exists():
            backed.append(backup_file(active.resolve(), model_slug, role, target, hf_repo))
        backed.append(backup_file(Path(lineage_fp), model_slug, role, target, hf_repo))
    return {"status": "ok", "count": len(backed), "items": backed}


_DEFAULT_BASE_MODELS = {
    "gemma-4-31b-it": "google/gemma-4-31b-it",
    "gemma-4-26b-a4b-it": "google/gemma-4-26b-a4b-it",
    "gemma-4-e4b-it": "google/gemma-4-e4b-it",
    "gemma-4-e2b-it": "google/gemma-4-e2b-it",
    "qwen3.8-27b": "Qwen/Qwen3.8-27B",
}


def _sanitize_value(v):
    if isinstance(v, dict):
        return {k: _sanitize_value(val) for k, val in v.items() if k not in ("backups",)}
    if isinstance(v, list):
        return [_sanitize_value(x) for x in v]
    if isinstance(v, str):
        # Strip local filesystem home/workspace prefixes before public release
        v = re.sub(r"/home/[^/\s\"']+", "<HOME>", v)
        v = re.sub(r"/root/[^/\s\"']+", "<HOME>", v)
        return v
    return v


def build_model_card(model_slug: str, role: str, hf_repo: str, gguf_name: str,
                     base_model: str, schema_info: dict,
                     template_name: str | None = None,
                     scorecard: dict | None = None,
                     lineage: dict | None = None) -> str:
    """Generate a Hugging Face Model Card README.md for a Blue Lodge SVD-32 GGUF adapter bundle."""
    ver = (lineage or {}).get("active_version") or "v1"
    published_at = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
    lines = [
        "---",
        f"base_model: {base_model}",
        "library_name: llama.cpp",
        "license: apache-2.0",
        "tags:",
        "  - blue-lodge",
        "  - lora",
        "  - svd-32",
        "  - gguf",
        "  - llama-cpp",
        "  - tool-use",
        "  - agent",
        f"  - role-{role}",
        "---",
        "",
        f"# Blue Lodge Sovereign Adapter — `{model_slug}` (`{role}` / {ver})",
        "",
        f"SVD-32 fused GGUF LoRA adapter trained with the [Blue Lodge](https://github.com/dabe-19/blue-lodge) "
        f"SFT + DPO harness pipeline for **{base_model}** (`role: {role}`, published `{published_at}`).",
        "",
        "## Bundle Contents",
        "",
        "| Artifact | Purpose |",
        "|---|---|",
        f"| `{gguf_name}` | SVD-32 fused GGUF LoRA adapter (`--lora-scaled` hot-swappable in stock `llama-server`) |",
        "| `tool_schema_manifest.json` | Canonical Blue Lodge tool schema subset (`core_sha256: "
        f"`{schema_info.get('core_sha256', '')[:16]}`) |",
        "| `lineage.json` | Sanitized SVD-32 version lineage and provenance |",
    ]
    if template_name:
        lines.append(f"| `{template_name}` | Calibrated Jinja chat template matching training & live inference |")
    if scorecard:
        lines.append("| `benchmark_scorecard.json` | 7-Pillar Multi-Turn Sovereign Benchmark scorecard |")

    if scorecard:
        lines += ["", "## 7-Pillar Multi-Turn Benchmark Scorecard", ""]
        if "pillars" in scorecard and isinstance(scorecard["pillars"], dict):
            lines += [
                f"- **Composite Score:** `{scorecard.get('candidate_score', scorecard.get('overall_score', '?'))}%`"
                + (f" (delta `{scorecard['composite_delta']:+.1f}%` vs `{scorecard.get('baseline_label', 'baseline')}`)"
                   if "composite_delta" in scorecard else ""),
                f"- **Early-Quit Rate:** `{scorecard.get('candidate_early_quit_pct', scorecard.get('early_quit_rate_pct', '?'))}%`",
                "",
                "| Pillar | Score |",
                "|---|---:|",
            ]
            for pname, pval in scorecard["pillars"].items():
                short = pname.split(":", 1)[1].strip() if ":" in pname else pname
                if isinstance(pval, dict) and "candidate" in pval:
                    lines.append(f"| {short} | {pval['baseline']:.1f}% → **{pval['candidate']:.1f}%** ({pval['delta']:+.1f}%) |")
                elif isinstance(pval, dict) and "score_pct" in pval:
                    lines.append(f"| {short} | **{pval['score_pct']:.1f}%** |")

    tpl_flag = f" \\\n  --chat-template-file {template_name}" if template_name else ""
    lines += [
        "",
        "## Usage with Stock `llama-server`",
        "",
        "```bash",
        "llama-server \\",
        f"  -m <path-to-{model_slug}.gguf> \\",
        f"  --lora-scaled {gguf_name}:1.0 \\",
        f"  --jinja{tpl_flag}",
        "```",
        "",
        "## Usage inside Blue Lodge",
        "",
        "```bash",
        f"# Place {gguf_name} at $MODELS_DIR/adapters/{model_slug}/{role}/active.gguf",
        "# Blue Lodge start_inference.sh automatically detects and mounts active.gguf on startup.",
        "```",
        "",
        f"Published via `scripts/training/backup_artifacts.py publish --hf-repo {hf_repo}`.",
        "",
    ]
    return "\n".join(lines)


def _find_latest_scorecard(model_slug: str, role: str) -> dict | None:
    role_dir = MODELS_DIR / "adapters" / model_slug / role
    for cand in (role_dir / "benchmark_scorecard.json", role_dir / "baseline_scorecard.json"):
        if cand.is_file():
            try:
                return json.loads(cand.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                pass
    # Also scan recent runs matching model_slug + role for benchmark_verdict.json
    runs_root = GEORGE_DIR / "training" / "runs"
    best = None
    best_mtime = 0.0
    if runs_root.is_dir():
        for vp in runs_root.glob("*/benchmark_verdict.json"):
            rj = vp.parent / "run.json"
            if not rj.is_file():
                continue
            try:
                meta = json.loads(rj.read_text(encoding="utf-8"))
                if meta.get("model_slug") == model_slug and meta.get("role", "core-agent") == role:
                    mt = vp.stat().st_mtime
                    if mt > best_mtime:
                        best_mtime = mt
                        best = json.loads(vp.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
    return best


def publish_bundle(model_slug: str, role: str, hf_repo: str, public: bool = False,
                   template_path: str | None = None, dry_run: bool = False,
                   out_dir: str | None = None, adapter_path: str | None = None,
                   base_model: str | None = None) -> dict:
    """Assemble and optionally publish a self-contained Hugging Face release bundle
    (GGUF adapter + Model Card README.md + tool_schema_manifest.json + Jinja template + scorecard)."""
    role_dir = MODELS_DIR / "adapters" / model_slug / role
    gguf_src = Path(adapter_path).expanduser() if adapter_path else (role_dir / "active.gguf")
    if gguf_src.is_symlink():
        gguf_src = gguf_src.resolve()

    lineage = {}
    lin_path = role_dir / "lineage.json"
    if lin_path.is_file():
        try:
            lineage = json.loads(lin_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            lineage = {}

    resolved_base = (
        base_model
        or lineage.get("base_model")
        or _DEFAULT_BASE_MODELS.get(model_slug, model_slug)
    )
    scorecard = _find_latest_scorecard(model_slug, role)

    # Resolve matching Jinja template (explicit or auto-attached for Qwen3.8)
    tpl_src: Path | None = None
    if template_path:
        p = Path(template_path).expanduser()
        if not p.is_absolute():
            p = LODGE_DIR / p
        if p.is_file():
            tpl_src = p
    elif "qwen" in model_slug.lower():
        cand = LODGE_DIR / "configs" / "blue_lodge_jinja_template.jinja"
        if cand.is_file():
            tpl_src = cand

    merged_tools, schema_info = sts.compute_sync_plan(LODGE_DIR)
    stage_dir = Path(out_dir).expanduser() if out_dir else Path(tempfile.mkdtemp(prefix=f"bl_publish_{model_slug}_"))
    stage_dir.mkdir(parents=True, exist_ok=True)
    cleanup_stage = not bool(out_dir) and not dry_run

    gguf_name = f"{model_slug}-{role}-svd32.gguf"
    staged_files: list[str] = []
    try:
        if gguf_src.is_file():
            shutil.copy2(gguf_src, stage_dir / gguf_name)
            staged_files.append(gguf_name)
        elif not dry_run:
            return {"status": "error", "message": f"Adapter GGUF not found: {gguf_src} (pass --adapter PATH or approve a run first)"}

        # Sanitized lineage.json
        san_lineage = _sanitize_value(lineage) if lineage else {
            "model_slug": model_slug, "role": role, "base_model": resolved_base, "active_version": "v1",
        }
        (stage_dir / "lineage.json").write_text(json.dumps(san_lineage, indent=2) + "\n", encoding="utf-8")
        staged_files.append("lineage.json")

        # Tool schema manifest (canonical tools + SHA-256)
        schema_manifest = {
            "schema_source": "data/schemas/native_tools.json",
            "live_tool_count": schema_info["live_count"],
            "core_tool_count": schema_info["train_after_count"],
            "live_sha256": schema_info["live_sha256"],
            "core_sha256": schema_info["core_sha256"],
            "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
            "tools": merged_tools,
        }
        (stage_dir / "tool_schema_manifest.json").write_text(
            json.dumps(schema_manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        staged_files.append("tool_schema_manifest.json")

        tpl_name = None
        if tpl_src and tpl_src.is_file():
            tpl_name = tpl_src.name
            shutil.copy2(tpl_src, stage_dir / tpl_name)
            staged_files.append(tpl_name)

        if scorecard:
            (stage_dir / "benchmark_scorecard.json").write_text(
                json.dumps(_sanitize_value(scorecard), indent=2) + "\n", encoding="utf-8"
            )
            staged_files.append("benchmark_scorecard.json")

        readme = build_model_card(
            model_slug=model_slug, role=role, hf_repo=hf_repo, gguf_name=gguf_name,
            base_model=resolved_base, schema_info=schema_info,
            template_name=tpl_name, scorecard=scorecard, lineage=san_lineage,
        )
        (stage_dir / "README.md").write_text(readme, encoding="utf-8")
        staged_files.append("README.md")

        if dry_run:
            return {
                "status": "ok",
                "dry_run": True,
                "hf_repo": hf_repo,
                "visibility": "public" if public else "private",
                "base_model": resolved_base,
                "adapter_present": gguf_src.is_file(),
                "stage_dir": str(stage_dir),
                "files": sorted(staged_files),
                "core_sha256": schema_info["core_sha256"],
                "readme_preview": readme[:1200],
            }

        token, _ = cc._read_key_from_files(("HF_TOKEN", "HUGGINGFACE_TOKEN", "HUGGING_FACE_HUB_TOKEN"))
        if not token:
            return {"status": "error", "message": "HF_TOKEN not configured in .george/keys.conf"}
        try:
            from huggingface_hub import HfApi
        except ImportError:
            return {"status": "error", "message": "huggingface_hub not installed (uv pip install huggingface-hub)"}

        api = HfApi(token=token)
        api.create_repo(repo_id=hf_repo, repo_type="model", private=not public, exist_ok=True)
        api.upload_folder(
            folder_path=str(stage_dir),
            repo_id=hf_repo,
            repo_type="model",
            commit_message=f"release({model_slug}/{role}): publish Blue Lodge SVD-32 adapter bundle",
        )
        return {
            "status": "ok",
            "dry_run": False,
            "hf_repo": hf_repo,
            "visibility": "public" if public else "private",
            "url": f"https://huggingface.co/{hf_repo}",
            "files": sorted(staged_files),
            "at": dt.datetime.now().isoformat(timespec="seconds"),
        }
    finally:
        if cleanup_stage:
            shutil.rmtree(stage_dir, ignore_errors=True)


def _infer_model_slug_from_repo(hf_repo: str) -> str:
    low = (hf_repo or "").lower()
    if "qwen3.8-27b" in low or "qwen38-27b" in low:
        return "qwen3.8-27b"
    if "gemma-4-31b" in low or "gemma4-31b" in low:
        return "gemma-4-31b-it"
    if "gemma-4-26b" in low or "gemma4-26b" in low:
        return "gemma-4-26b-a4b-it"
    if "gemma-4-e4b" in low or "gemma4-e4b" in low:
        return "gemma-4-e4b-it"
    if "gemma-4-e2b" in low or "gemma4-e2b" in low:
        return "gemma-4-e2b-it"
    stem = (hf_repo or "adapter").split("/")[-1]
    stem = re.sub(r"(?i)(?:-super)?(?:-hermes)?(?:-adapted)?(?:-adapter)?(?:-lora)?(?:-gguf)?$", "", stem)
    slug = re.sub(r"[^a-z0-9._-]+", "-", stem.lower()).strip("-._")
    return slug[:64] or "generic"


def pull_hf_adapter(hf_repo: str, model_slug: str | None = None, role: str = "core-agent",
                    filename: str | None = None, activate: bool = False,
                    dry_run: bool = False, compress_svd: int | None = None) -> dict:
    """Download a community/HF GGUF LoRA adapter (e.g. harness-hub/Qwen3.8-27B-super-adapter-GGUF)
    into $MODELS_DIR/adapters/<model_slug>/<role>/community/ with SHA-256 verification, optional
    SVD rank compression (8/16/32/64), and lineage tracking."""
    if not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", hf_repo or ""):
        return {"status": "error", "message": f"Invalid HF repo id: {hf_repo!r}"}
    if compress_svd is not None and int(compress_svd) not in (8, 16, 32, 64):
        return {"status": "error", "message": f"compress_svd rank must be one of 8, 16, 32, 64 (got {compress_svd})"}
    model_slug = (model_slug or "").strip() or _infer_model_slug_from_repo(hf_repo)
    token, _ = cc._read_key_from_files(("HF_TOKEN", "HUGGINGFACE_TOKEN", "HUGGING_FACE_HUB_TOKEN"))
    hdr = {"User-Agent": "blue-lodge-adapter-hub/1.0"}
    if token:
        hdr["Authorization"] = f"Bearer {token}"

    tree_url = f"https://huggingface.co/api/models/{hf_repo}/tree/main"
    try:
        with urllib.request.urlopen(urllib.request.Request(tree_url, headers=hdr), timeout=30) as r:
            entries = json.loads(r.read().decode("utf-8"))
    except Exception as e:
        return {"status": "error", "message": f"Could not inspect HF repo {hf_repo}: {e}"}

    ggufs = [x for x in entries if isinstance(x, dict) and str(x.get("path", "")).lower().endswith(".gguf")]
    if not ggufs:
        return {"status": "error", "message": f"No .gguf adapter files found in {hf_repo}"}

    chosen = None
    if filename:
        chosen = next((x for x in ggufs if x["path"] == filename or os.path.basename(x["path"]) == filename), None)
        if not chosen:
            return {"status": "error", "message": f"File {filename!r} not found in {hf_repo}; available: {[x['path'] for x in ggufs]}"}
    else:
        # Prefer F16 / BF16 LoRA GGUFs when multiple exist
        chosen = next((x for x in ggufs if "f16" in x["path"].lower() or "bf16" in x["path"].lower()), ggufs[0])

    rel_path = chosen["path"]
    expected_size = int(chosen.get("size") or 0)
    expected_sha = ((chosen.get("lfs") or {}).get("oid") or "").strip().lower()
    safe_repo = hf_repo.replace("/", "__")
    role_dir = MODELS_DIR / "adapters" / model_slug / role
    comm_dir = role_dir / "community"
    dest_path = comm_dir / f"{safe_repo}__{os.path.basename(rel_path)}"
    dl_url = f"https://huggingface.co/{hf_repo}/resolve/main/{urllib.parse.quote(rel_path)}"

    svd_dest = None
    if compress_svd is not None:
        svd_stem = re.sub(r"(?i)(?:-svd\d+)?\.gguf$", "", dest_path.name)
        svd_dest = comm_dir / f"{svd_stem}-svd{int(compress_svd)}.gguf"

    if dry_run:
        return {
            "status": "ok",
            "dry_run": True,
            "hf_repo": hf_repo,
            "model_slug": model_slug,
            "role": role,
            "file": rel_path,
            "size_mib": round(expected_size / (1024 * 1024), 1),
            "expected_sha256": expected_sha[:16] if expected_sha else None,
            "dest_path": str(dest_path),
            "compress_svd": int(compress_svd) if compress_svd is not None else None,
            "svd_dest_path": str(svd_dest) if svd_dest else None,
            "activate": activate,
            "available_ggufs": [x["path"] for x in ggufs],
        }

    comm_dir.mkdir(parents=True, exist_ok=True)
    # Reuse already-verified file on disk if size & sha256 match
    reused = False
    actual_sha = ""
    written = 0
    if dest_path.is_file() and (not expected_size or dest_path.stat().st_size == expected_size):
        h_ex = hashlib.sha256()
        with open(dest_path, "rb") as fh:
            while True:
                b = fh.read(4 * 1024 * 1024)
                if not b:
                    break
                h_ex.update(b)
        cand_sha = h_ex.hexdigest()
        if not expected_sha or cand_sha == expected_sha:
            actual_sha = cand_sha
            written = dest_path.stat().st_size
            reused = True

    if not reused:
        part_path = dest_path.with_suffix(dest_path.suffix + ".part")
        h = hashlib.sha256()
        written = 0
        try:
            with urllib.request.urlopen(urllib.request.Request(dl_url, headers=hdr), timeout=600) as r:
                with open(part_path, "wb") as out:
                    while True:
                        chunk = r.read(4 * 1024 * 1024)
                        if not chunk:
                            break
                        out.write(chunk)
                        h.update(chunk)
                        written += len(chunk)
            actual_sha = h.hexdigest()
            if expected_sha and actual_sha != expected_sha:
                part_path.unlink(missing_ok=True)
                return {"status": "error", "message": f"SHA-256 mismatch for {rel_path}: expected {expected_sha[:16]}, got {actual_sha[:16]}"}
            os.chmod(part_path, 0o664)
            os.replace(part_path, dest_path)
            try:
                (dest_path.with_name(dest_path.name + ".sha256")).write_text(f"{actual_sha}  {dest_path.name}\n", encoding="utf-8")
            except OSError:
                pass
        except Exception as e:
            part_path.unlink(missing_ok=True)
            return {"status": "error", "message": f"Download failed for {dl_url}: {e}"}

    svd_info = None
    final_target = dest_path
    final_sha = actual_sha
    if compress_svd is not None and svd_dest is not None:
        rank = int(compress_svd)
        lodge_root = Path(__file__).resolve().parents[2]
        merge_script = Path(__file__).resolve().parent / "merge_loras.py"
        if not merge_script.is_file():
            return {"status": "error", "message": f"SVD compressor not found: {merge_script}"}
        venv_py = lodge_root / ".venv" / "bin" / "python"
        py_bin = str(venv_py) if (venv_py.is_file() and os.access(venv_py, os.X_OK)) else sys.executable
        tmp_svd = svd_dest.with_name(f".{svd_dest.name}.tmp.{os.getpid()}")
        svd_env = dict(os.environ)
        svd_env.setdefault("OPENBLAS_NUM_THREADS", "4")
        svd_env.setdefault("OMP_NUM_THREADS", "4")
        svd_env.setdefault("MKL_NUM_THREADS", "4")
        try:
            proc = subprocess.run(
                [
                    py_bin, str(merge_script),
                    "--adapters", str(dest_path),
                    "--weights", "1.0",
                    "--output", str(tmp_svd),
                    "--method", "svd",
                    "--target_rank", str(rank),
                    "--alpha", str(float(rank * 2)),
                    "--outtype", "f16",
                ],
                capture_output=True, text=True, timeout=600, check=False, env=svd_env,
            )
            if proc.returncode != 0 or not tmp_svd.is_file():
                tail = (proc.stderr or proc.stdout or "SVD merge failed").strip()[-500:]
                return {"status": "error", "message": f"Downloaded {dest_path.name}, but SVD-{rank} compression failed: {tail}"}
            os.chmod(tmp_svd, 0o664)
            os.replace(tmp_svd, svd_dest)
        finally:
            if tmp_svd.exists():
                tmp_svd.unlink(missing_ok=True)
        h_svd = hashlib.sha256()
        with open(svd_dest, "rb") as fh:
            while True:
                b = fh.read(4 * 1024 * 1024)
                if not b:
                    break
                h_svd.update(b)
        svd_sha = h_svd.hexdigest()
        try:
            (svd_dest.with_name(svd_dest.name + ".sha256")).write_text(f"{svd_sha}  {svd_dest.name}\n", encoding="utf-8")
        except OSError:
            pass
        svd_bytes = svd_dest.stat().st_size
        svd_info = {
            "rank": rank,
            "path": str(svd_dest),
            "file": svd_dest.name,
            "size_bytes": svd_bytes,
            "size_mib": round(svd_bytes / (1024 * 1024), 1),
            "saved_pct": round((1.0 - (svd_bytes / written)) * 100.0, 1) if written > 0 else 0.0,
            "sha256": svd_sha,
        }
        final_target = svd_dest
        final_sha = svd_sha

    active_link = role_dir / "active.gguf"
    if activate:
        if active_link.is_symlink() or active_link.exists():
            active_link.unlink()
        active_link.symlink_to(final_target)

    lineage_p = role_dir / "lineage.json"
    lin = {}
    if lineage_p.is_file():
        try:
            lin = json.loads(lineage_p.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            lin = {}
    lin.setdefault("model_slug", model_slug)
    lin.setdefault("role", role)
    lin.setdefault("community_adapters", []).append({
        "hf_repo": hf_repo,
        "file": rel_path,
        "path": str(dest_path),
        "size_bytes": written,
        "sha256": actual_sha,
        "svd_compressed": svd_info,
        "pulled_at": dt.datetime.now().isoformat(timespec="seconds"),
    })
    if activate:
        lin["active_version"] = f"hf:{hf_repo}" + (f":svd{int(compress_svd)}" if svd_info else "")
        lin["active_path"] = str(final_target)
    lineage_p.write_text(json.dumps(lin, indent=2) + "\n", encoding="utf-8")

    return {
        "status": "ok",
        "hf_repo": hf_repo,
        "model_slug": model_slug,
        "role": role,
        "file": rel_path,
        "size_mib": round(written / (1024 * 1024), 1),
        "reused_local": reused,
        "sha256": final_sha[:16],
        "source_sha256": actual_sha[:16],
        "path": str(dest_path),
        "installed_path": str(final_target),
        "svd_compressed": svd_info,
        "activated": activate,
        "active_path": str(active_link) if activate else None,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    pb = sub.add_parser("backup")
    pb.add_argument("--file", default=None)
    pb.add_argument("--model", default="generic")
    pb.add_argument("--role", default="core-agent")
    pb.add_argument("--all", action="store_true")
    pb.add_argument("--target", choices=("drive", "hf", "both"), default="both")
    pb.add_argument("--hf-repo", default=None)

    pp = sub.add_parser("publish", help="Stage & publish a Hugging Face release bundle (GGUF + Model Card + schemas + Jinja)")
    pp.add_argument("--model", required=True, help="Model slug (e.g. gemma-4-31b-it or qwen3.8-27b)")
    pp.add_argument("--role", default="core-agent")
    pp.add_argument("--hf-repo", required=True, help="Destination Hugging Face repo (e.g. dabe-19/blue-lodge-gemma4-31b-svd32)")
    pp.add_argument("--public", action="store_true", help="Create/publish as a PUBLIC Hugging Face repo (default: private)")
    pp.add_argument("--template", default=None, help="Optional .jinja chat template file to include in the release bundle")
    pp.add_argument("--adapter", default=None, help="Explicit adapter .gguf path (defaults to active.gguf)")
    pp.add_argument("--base-model", default=None, help="Explicit HF base_model id for Model Card YAML frontmatter")
    pp.add_argument("--out-dir", default=None, help="Keep staged release bundle in this directory")
    pp.add_argument("--dry-run", action="store_true", help="Stage locally and emit bundle manifest without uploading")

    pl = sub.add_parser("pull-adapter", help="Download a GGUF LoRA/SVD adapter from Hugging Face into MODELS_DIR/adapters/")
    pl.add_argument("repo_pos", nargs="?", default=None, help="Optional positional HF repo (org/repo)")
    pl.add_argument("--hf-repo", default=None, help="Source HF repo (e.g. harness-hub/Qwen3.8-27B-super-adapter-GGUF)")
    pl.add_argument("--model", "--model-slug", dest="model", default=None, help="Target model slug (auto-inferred if omitted)")
    pl.add_argument("--role", default="core-agent")
    pl.add_argument("--file", default=None, help="Optional specific .gguf filename in the HF repo")
    pl.add_argument("--compress-svd", type=int, choices=(8, 16, 32, 64), default=None, help="Compress downloaded LoRA to SVD rank N (e.g. 32 -> ~86 MiB)")
    pl.add_argument("--activate", action="store_true", help="Point active.gguf symlink at the downloaded (or SVD-compressed) adapter")
    pl.add_argument("--dry-run", action="store_true", help="Inspect repo files & SHA-256 without downloading")
    a = ap.parse_args()

    if a.cmd == "status":
        print(json.dumps(backup_status(), indent=2))
        return 0
    if a.cmd == "pull-adapter":
        repo_arg = a.hf_repo or a.repo_pos or ""
        res = pull_hf_adapter(
            hf_repo=repo_arg, model_slug=a.model, role=a.role,
            filename=a.file, activate=a.activate, dry_run=a.dry_run,
            compress_svd=a.compress_svd,
        )
        print(json.dumps(res, indent=2))
        return 0 if res.get("status") == "ok" else 1
    if a.cmd == "publish":
        res = publish_bundle(
            model_slug=a.model, role=a.role, hf_repo=a.hf_repo, public=a.public,
            template_path=a.template, dry_run=a.dry_run, out_dir=a.out_dir,
            adapter_path=a.adapter, base_model=a.base_model,
        )
        print(json.dumps(res, indent=2))
        return 0 if res.get("status") == "ok" else 1
    if a.all:
        res = backup_all(a.target, a.hf_repo)
    elif a.file:
        res = backup_file(Path(a.file).expanduser(), a.model, a.role, a.target, a.hf_repo)
    else:
        res = {"status": "error", "message": "Specify --file <path> or --all"}
    print(json.dumps(res, indent=2))
    return 0 if res.get("status") == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
