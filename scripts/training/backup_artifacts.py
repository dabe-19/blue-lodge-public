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
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_credits as cc  # noqa: E402

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
        __import__("googleapiclient")
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


def upload_to_hf(local_path: Path, repo_id: str, path_in_repo: str) -> dict:
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
    api.create_repo(repo_id=repo_id, repo_type="model", private=True, exist_ok=True)
    api.upload_file(
        path_or_fileobj=str(local_path),
        path_in_repo=path_in_repo,
        repo_id=repo_id,
        repo_type="model",
        commit_message=f"chore(backup): archive {local_path.name}",
    )
    return {
        "status": "ok",
        "target": "hf",
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

    # Fast path 2: Google Drive REST API via ADC credentials
    try:
        import google.auth
        from googleapiclient.discovery import build
        from googleapiclient.http import MediaFileUpload
    except ImportError:
        return {
            "status": "error",
            "target": "drive",
            "message": "Install google-api-python-client (uv pip install google-api-python-client) or configure rclone 'gdrive:' for Drive backup.",
        }

    try:
        creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/drive.file"])
        svc = build("drive", "v3", credentials=creds, cache_discovery=False)
        parent_id = "root"
        for part in [x for x in folder_path.strip("/").split("/") if x]:
            q = f"name='{part}' and mimeType='application/vnd.google-apps.folder' and '{parent_id}' in parents and trashed=false"
            res = svc.files().list(q=q, fields="files(id,name)").execute().get("files", [])
            if res:
                parent_id = res[0]["id"]
            else:
                created = svc.files().create(
                    body={"name": part, "mimeType": "application/vnd.google-apps.folder", "parents": [parent_id]},
                    fields="id",
                ).execute()
                parent_id = created["id"]

        media = MediaFileUpload(str(local_path), resumable=True)
        uploaded = svc.files().create(
            body={"name": remote_name, "parents": [parent_id]},
            media_body=media,
            fields="id,webViewLink",
        ).execute()
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
    a = ap.parse_args()

    if a.cmd == "status":
        print(json.dumps(backup_status(), indent=2))
        return 0
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
