"""Optional Google Drive mirror for the Blue Lodge Model Hub.

Lets multiple sovereign nodes sharing a Google Drive account (e.g. Hiram, George, and swarm
edge nodes) mirror installed GGUF profiles, SHA-256 manifests, and active SVD-32/LoRA adapters
into a shared personal Drive folder (`BlueLodge/models/hub` by default), using 8 MiB resumable
streaming (zero RAM blowup on 20+ GiB GGUFs) via ADC credentials or `rclone`.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from . import profiles
from .common import HubError, george_dir
from .hw import models_dir

CHUNK_SIZE = 8 * 1024 * 1024  # 8 MiB (multiple of 256 KiB required by Drive resumable upload)


def default_drive_folder() -> str:
    env_f = os.environ.get("DRIVE_MODEL_HUB_FOLDER", "").strip()
    if env_f:
        return env_f.strip("/")
    pol_p = george_dir() / "training" / "policy.json"
    if pol_p.is_file():
        try:
            pol = json.loads(pol_p.read_text(encoding="utf-8"))
            if pol.get("drive_model_hub_folder"):
                return str(pol["drive_model_hub_folder"]).strip("/")
        except (OSError, ValueError):
            pass
    return "BlueLodge/models/hub"


class _DriveV3:
    """Pure-stdlib Google Drive REST v3 client backed by ADC credentials (zero interactive popups)."""

    def __init__(self) -> None:
        self._creds = None
        self._quota_project = ""
        self._folder_cache: dict[str, str] = {}

    def _init_creds(self) -> None:
        if self._creds is not None:
            return
        try:
            import google.auth
            from google.auth.transport.requests import Request
        except ImportError as e:
            raise HubError("google-auth is not installed (run inside .venv or install google-auth)") from e
        try:
            creds, proj = google.auth.default()
            creds.refresh(Request())
        except Exception as e:
            raise HubError(f"Google ADC credentials unavailable or expired: {e}") from e
        self._creds = creds
        qp = getattr(creds, "quota_project_id", None) or proj or ""
        if not qp:
            for cand in (
                Path.home() / ".config/gcloud/application_default_credentials.json",
                Path("/root/.config/gcloud/application_default_credentials.json"),
            ):
                if cand.is_file():
                    try:
                        qp = json.loads(cand.read_text(encoding="utf-8")).get("quota_project_id", "")
                        if qp:
                            break
                    except (OSError, ValueError):
                        continue
        self._quota_project = qp

    def _headers(self, force_refresh: bool = False) -> dict[str, str]:
        self._init_creds()
        if force_refresh or not self._creds.valid:
            from google.auth.transport.requests import Request
            self._creds.refresh(Request())
        hdr = {"Authorization": f"Bearer {self._creds.token}"}
        if self._quota_project:
            hdr["X-Goog-User-Project"] = self._quota_project
        return hdr

    def _open(self, build_req, timeout: int = 30):
        try:
            return urllib.request.urlopen(build_req(False), timeout=timeout)
        except urllib.error.HTTPError as e:
            if e.code == 401:
                return urllib.request.urlopen(build_req(True), timeout=timeout)
            raise

    def ensure_folder(self, path: str, create: bool = True) -> str | None:
        norm = "/".join(p for p in path.strip("/").split("/") if p)
        if not norm:
            return "root"
        if norm in self._folder_cache:
            return self._folder_cache[norm]
        parent = "root"
        built = []
        for part in norm.split("/"):
            built.append(part)
            key = "/".join(built)
            if key in self._folder_cache:
                parent = self._folder_cache[key]
                continue
            safe = part.replace("'", "")
            q = f"name='{safe}' and mimeType='application/vnd.google-apps.folder' and '{parent}' in parents and trashed=false"
            url = "https://www.googleapis.com/drive/v3/files?fields=files(id,name)&q=" + urllib.parse.quote(q)
            with self._open(lambda fr: urllib.request.Request(url, headers=self._headers(fr)), timeout=20) as r:
                found = json.loads(r.read()).get("files", [])
            if found:
                parent = found[0]["id"]
                self._folder_cache[key] = parent
                continue
            if not create:
                return None
            meta = json.dumps({
                "name": part, "mimeType": "application/vnd.google-apps.folder", "parents": [parent],
            }).encode("utf-8")
            with self._open(
                lambda fr: urllib.request.Request(
                    "https://www.googleapis.com/drive/v3/files?fields=id",
                    data=meta, headers={**self._headers(fr), "Content-Type": "application/json"}, method="POST",
                ),
                timeout=20,
            ) as r:
                parent = json.loads(r.read())["id"]
                self._folder_cache[key] = parent
        return parent

    def list_files(self, folder_id: str) -> list[dict[str, Any]]:
        q = f"'{folder_id}' in parents and trashed=false"
        url = (
            "https://www.googleapis.com/drive/v3/files?"
            "fields=files(id,name,size,mimeType,modifiedTime)&pageSize=200&q=" + urllib.parse.quote(q)
        )
        with self._open(lambda fr: urllib.request.Request(url, headers=self._headers(fr)), timeout=20) as r:
            return json.loads(r.read()).get("files", [])

    def find_file(self, folder_id: str, name: str) -> dict[str, Any] | None:
        safe = name.replace("'", "")
        q = f"name='{safe}' and '{folder_id}' in parents and trashed=false"
        url = "https://www.googleapis.com/drive/v3/files?fields=files(id,name,size,modifiedTime)&pageSize=5&q=" + urllib.parse.quote(q)
        with self._open(lambda fr: urllib.request.Request(url, headers=self._headers(fr)), timeout=20) as r:
            files = json.loads(r.read()).get("files", [])
        return files[0] if files else None

    def upload_file(self, local_path: Path, folder_id: str, remote_name: str, skip_same_size: bool = True) -> dict[str, Any]:
        total = local_path.stat().st_size
        existing = self.find_file(folder_id, remote_name)
        if existing and skip_same_size and int(existing.get("size") or -1) == total:
            return {"status": "skipped_exists", "file_id": existing["id"], "bytes": total}

        if existing:
            init_url = f"https://www.googleapis.com/upload/drive/v3/files/{existing['id']}?uploadType=resumable&fields=id,webViewLink"
            method = "PATCH"
            meta = json.dumps({"name": remote_name}).encode("utf-8")
        else:
            init_url = "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,webViewLink"
            method = "POST"
            meta = json.dumps({"name": remote_name, "parents": [folder_id]}).encode("utf-8")

        with self._open(
            lambda fr: urllib.request.Request(
                init_url,
                data=meta,
                headers={
                    **self._headers(fr),
                    "Content-Type": "application/json; charset=UTF-8",
                    "X-Upload-Content-Length": str(total),
                    "X-Upload-Content-Type": "application/octet-stream",
                },
                method=method,
            ),
            timeout=30,
        ) as r:
            upload_url = r.headers.get("Location")
        if not upload_url:
            raise HubError(f"Drive resumable init failed for {remote_name}")

        if total == 0:
            req = urllib.request.Request(upload_url, data=b"", headers={"Content-Length": "0"}, method="PUT")
            with urllib.request.urlopen(req, timeout=60) as r:
                res = json.loads(r.read() or b"{}")
            return {"status": "uploaded", "file_id": res.get("id"), "bytes": 0}

        with open(local_path, "rb") as fh:
            offset = 0
            while offset < total:
                chunk = fh.read(CHUNK_SIZE)
                if not chunk:
                    break
                end = offset + len(chunk) - 1
                hdr = {
                    "Content-Length": str(len(chunk)),
                    "Content-Type": "application/octet-stream",
                    "Content-Range": f"bytes {offset}-{end}/{total}",
                }
                req = urllib.request.Request(upload_url, data=chunk, headers=hdr, method="PUT")
                try:
                    with urllib.request.urlopen(req, timeout=600) as r:
                        if r.status in (200, 201):
                            res = json.loads(r.read() or b"{}")
                            return {"status": "uploaded", "file_id": res.get("id"), "bytes": total}
                except urllib.error.HTTPError as e:
                    if e.code == 308:
                        offset += len(chunk)
                        continue
                    raise
                offset += len(chunk)
        return {"status": "uploaded", "bytes": total}

    def download_file(self, file_id: str, dest: Path, expected_sha256: str | None = None) -> dict[str, Any]:
        dest.parent.mkdir(parents=True, exist_ok=True)
        part = dest.with_suffix(dest.suffix + ".part")
        url = f"https://www.googleapis.com/drive/v3/files/{file_id}?alt=media"
        h = hashlib.sha256()
        written = 0
        try:
            with self._open(lambda fr: urllib.request.Request(url, headers=self._headers(fr)), timeout=600) as r:
                with open(part, "wb") as out:
                    while True:
                        buf = r.read(4 * 1024 * 1024)
                        if not buf:
                            break
                        out.write(buf)
                        h.update(buf)
                        written += len(buf)
            actual = h.hexdigest()
            if expected_sha256 and actual != expected_sha256.lower():
                part.unlink(missing_ok=True)
                raise HubError(f"SHA-256 mismatch downloading {dest.name}: expected {expected_sha256[:16]}, got {actual[:16]}")
            os.chmod(part, 0o600)
            os.replace(part, dest)
            return {"status": "downloaded", "bytes": written, "sha256": actual}
        except Exception:
            part.unlink(missing_ok=True)
            raise

    def read_json(self, file_id: str) -> Any:
        url = f"https://www.googleapis.com/drive/v3/files/{file_id}?alt=media"
        with self._open(lambda fr: urllib.request.Request(url, headers=self._headers(fr)), timeout=30) as r:
            return json.loads(r.read().decode("utf-8"))


def _adc_configured() -> bool:
    for cand in (
        os.environ.get("GOOGLE_APPLICATION_CREDENTIALS", ""),
        str(Path.home() / ".config/gcloud/application_default_credentials.json"),
        "/root/.config/gcloud/application_default_credentials.json",
    ):
        if cand and os.path.isfile(cand):
            return True
    return False


def _detect_adapter_slug(profile: dict[str, Any]) -> str | None:
    repo = ((profile.get("source") or {}).get("repo") or profile.get("name") or "").lower()
    for needle, slug in (
        ("gemma-4-31b", "gemma-4-31b-it"),
        ("gemma-4-26b", "gemma-4-26b-a4b-it"),
        ("gemma-4-e4b", "gemma-4-e4b-it"),
        ("gemma-4-e2b", "gemma-4-e2b-it"),
        ("qwen3.8-27b", "qwen3.8-27b"),
    ):
        if needle in repo:
            return slug
    return None


def drive_status() -> dict[str, Any]:
    adc = _adc_configured()
    gauth = False
    try:
        __import__("google.auth")
        gauth = True
    except ImportError:
        pass
    rclone_bin = shutil.which("rclone")
    installed = [p["name"] for p in profiles.list_profiles() if p.get("status") == "installed"]
    return {
        "ready": bool((adc and gauth) or rclone_bin),
        "adc_configured": adc,
        "google_auth_installed": gauth,
        "rclone_available": bool(rclone_bin),
        "drive_folder": default_drive_folder(),
        "local_installed_profiles": installed,
    }


def drive_list(folder: str | None = None) -> dict[str, Any]:
    root_folder = (folder or default_drive_folder()).strip("/")
    drv = _DriveV3()
    prof_root = drv.ensure_folder(f"{root_folder}/profiles", create=False)
    prof_items = []
    if prof_root:
        for entry in drv.list_files(prof_root):
            if entry.get("mimeType") != "application/vnd.google-apps.folder":
                continue
            pfiles = drv.list_files(entry["id"])
            pj = next((f for f in pfiles if f.get("name") == "profile.json"), None)
            meta = {}
            if pj:
                try:
                    meta = drv.read_json(pj["id"])
                except Exception:
                    meta = {}
            total_b = sum(int(f.get("size") or 0) for f in pfiles if str(f.get("name", "")).endswith(".gguf"))
            prof_items.append({
                "name": entry["name"],
                "repo": (meta.get("source") or {}).get("repo"),
                "provider": (meta.get("source") or {}).get("provider"),
                "ctx": (meta.get("server") or {}).get("ctx"),
                "size_gib": round(total_b / (1 << 30), 2),
                "files": [f["name"] for f in pfiles],
                "modified": entry.get("modifiedTime"),
            })
    ad_root = drv.ensure_folder(f"{root_folder}/adapters", create=False)
    ad_items = []
    if ad_root:
        for m_dir in drv.list_files(ad_root):
            if m_dir.get("mimeType") != "application/vnd.google-apps.folder":
                continue
            for r_dir in drv.list_files(m_dir["id"]):
                if r_dir.get("mimeType") != "application/vnd.google-apps.folder":
                    continue
                afiles = drv.list_files(r_dir["id"])
                ad_items.append({
                    "model_slug": m_dir["name"],
                    "role": r_dir["name"],
                    "files": [f["name"] for f in afiles],
                })
    return {
        "drive_folder": root_folder,
        "profiles": sorted(prof_items, key=lambda x: x["name"]),
        "adapters": ad_items,
    }


def drive_push(profile_name: str | None = None, push_all: bool = False,
               include_adapters: bool = True, folder: str | None = None,
               dry_run: bool = False) -> dict[str, Any]:
    root_folder = (folder or default_drive_folder()).strip("/")
    targets = []
    if push_all:
        targets = [p["name"] for p in profiles.list_profiles() if p.get("status") == "installed"]
    elif profile_name:
        targets = [profile_name]
    else:
        raise HubError("specify a profile name or --all")
    if not targets:
        raise HubError("no installed profiles to mirror")

    plan = []
    for name in targets:
        p = profiles.load(name)
        lroot = profiles.local_root(p)
        files_to_push = []
        for f in p.get("files") or []:
            lp = lroot / f["path"]
            if not lp.is_file():
                raise HubError(f"profile '{name}' missing local file: {lp} (install first)")
            files_to_push.append({"local": str(lp), "remote": os.path.basename(f["path"]), "size": lp.stat().st_size, "sha256": f.get("sha256")})
            sha_p = lp.with_suffix(lp.suffix + ".sha256")
            if sha_p.is_file():
                files_to_push.append({"local": str(sha_p), "remote": os.path.basename(str(sha_p)), "size": sha_p.stat().st_size})
        adapter_bundle = None
        if include_adapters:
            slug = _detect_adapter_slug(p)
            if slug:
                adir = models_dir() / "adapters" / slug / "core-agent"
                act = adir / "active.gguf"
                if act.exists():
                    real_act = act.resolve()
                    adapter_bundle = {
                        "model_slug": slug, "role": "core-agent",
                        "active_gguf": str(real_act), "size": real_act.stat().st_size,
                        "lineage": str(adir / "lineage.json") if (adir / "lineage.json").is_file() else None,
                    }
        plan.append({"profile": name, "files": files_to_push, "adapter": adapter_bundle})

    if dry_run:
        return {"status": "ok", "dry_run": True, "drive_folder": root_folder, "plan": plan}

    drv = _DriveV3()
    results = []
    for item in plan:
        name = item["profile"]
        p = profiles.load(name)
        pf_id = drv.ensure_folder(f"{root_folder}/profiles/{name}", create=True)
        uploaded = []
        # Upload profile.json
        fd, tmp_pj = tempfile.mkstemp(prefix=f"bl_prof_{name}_", suffix=".json")
        os.close(fd)
        try:
            Path(tmp_pj).write_text(json.dumps(p, indent=2) + "\n", encoding="utf-8")
            u_pj = drv.upload_file(Path(tmp_pj), pf_id, "profile.json", skip_same_size=False)
            uploaded.append({"file": "profile.json", **u_pj})
        finally:
            try:
                os.remove(tmp_pj)
            except OSError:
                pass
        for fi in item["files"]:
            u = drv.upload_file(Path(fi["local"]), pf_id, fi["remote"], skip_same_size=True)
            uploaded.append({"file": fi["remote"], **u})
        ad_res = []
        if item["adapter"]:
            ab = item["adapter"]
            af_id = drv.ensure_folder(f"{root_folder}/adapters/{ab['model_slug']}/{ab['role']}", create=True)
            u_a = drv.upload_file(Path(ab["active_gguf"]), af_id, "active.gguf", skip_same_size=True)
            ad_res.append({"file": "active.gguf", **u_a})
            if ab["lineage"]:
                u_l = drv.upload_file(Path(ab["lineage"]), af_id, "lineage.json", skip_same_size=False)
                ad_res.append({"file": "lineage.json", **u_l})
        results.append({"profile": name, "uploaded": uploaded, "adapters": ad_res})

    return {
        "status": "ok",
        "drive_folder": root_folder,
        "mirrored_at": dt.datetime.now().isoformat(timespec="seconds"),
        "results": results,
    }


def drive_pull(profile_name: str, with_adapters: bool = True,
               folder: str | None = None, dry_run: bool = False) -> dict[str, Any]:
    root_folder = (folder or default_drive_folder()).strip("/")
    drv = _DriveV3()
    pf_id = drv.ensure_folder(f"{root_folder}/profiles/{profile_name}", create=False)
    if not pf_id:
        raise HubError(f"profile '{profile_name}' not found on Google Drive under {root_folder}/profiles/")
    remote_files = drv.list_files(pf_id)
    pj = next((f for f in remote_files if f.get("name") == "profile.json"), None)
    if not pj:
        raise HubError(f"profile.json missing in Drive folder {root_folder}/profiles/{profile_name}")
    p = drv.read_json(pj["id"])
    lroot = profiles.local_root(p)

    # Check if adapter mirror exists on Drive
    slug = _detect_adapter_slug(p)
    ad_files = []
    if with_adapters and slug:
        af_id = drv.ensure_folder(f"{root_folder}/adapters/{slug}/core-agent", create=False)
        if af_id:
            ad_files = drv.list_files(af_id)

    if dry_run:
        return {
            "status": "ok",
            "dry_run": True,
            "profile": profile_name,
            "local_root": str(lroot),
            "files": [{"name": f["name"], "size": int(f.get("size") or 0)} for f in remote_files],
            "adapter_slug": slug,
            "adapter_files": [f["name"] for f in ad_files],
        }

    downloaded = []
    lroot.mkdir(parents=True, exist_ok=True)
    for pf in p.get("files") or []:
        fname = os.path.basename(pf["path"])
        rf = next((x for x in remote_files if x.get("name") == fname), None)
        if not rf:
            raise HubError(f"missing expected file '{fname}' in Drive mirror for '{profile_name}'")
        dest = lroot / pf["path"]
        exp_sha = pf.get("sha256")
        if dest.is_file() and exp_sha:
            # Skip if already present locally with matching SHA-256
            h = hashlib.sha256()
            with open(dest, "rb") as fh:
                for chunk in iter(lambda: fh.read(4 * 1024 * 1024), b""):
                    h.update(chunk)
            if h.hexdigest() == exp_sha.lower():
                downloaded.append({"file": pf["path"], "status": "verified_local", "sha256": exp_sha[:16]})
                continue
        res = drv.download_file(rf["id"], dest, expected_sha256=exp_sha)
        if exp_sha:
            dest.with_suffix(dest.suffix + ".sha256").write_text(exp_sha + "\n", encoding="utf-8")
        downloaded.append({"file": pf["path"], **res})

    # Register the profile locally as approved + installed so `/models activate <name>` works immediately
    p["status"] = "installed"
    p["approved_sha"] = profiles.canonical_hash(p)
    p["approved_at"] = int(dt.datetime.now().timestamp())
    p["approved_by"] = "drive_mirror"
    p["installed_at"] = int(dt.datetime.now().timestamp())
    profiles.profile_path(profile_name).write_text(json.dumps(p, indent=2) + "\n", encoding="utf-8")

    pulled_adapters = []
    if with_adapters and slug and ad_files:
        adir = models_dir() / "adapters" / slug / "core-agent"
        adir.mkdir(parents=True, exist_ok=True)
        for af in ad_files:
            if af["name"] in ("active.gguf", "lineage.json"):
                dest = adir / af["name"]
                res = drv.download_file(af["id"], dest)
                os.chmod(dest, 0o664)
                pulled_adapters.append({"file": af["name"], **res})

    return {
        "status": "ok",
        "profile": profile_name,
        "local_root": str(lroot),
        "downloaded": downloaded,
        "adapters": pulled_adapters,
        "next": f"/models activate {profile_name}",
    }
