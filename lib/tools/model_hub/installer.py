"""Deterministic installer: approved profile -> verified files on disk.

Refuses unapproved/edited profiles, re-validates, checks disk, downloads with HTTP Range resume,
verifies size + sha256 for every file, then atomically renames into place. Progress is written to
.george/models/downloads/<name>.json for the CLI/web UI; touching <name>.cancel aborts cleanly.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import time
from pathlib import Path
from typing import Any, Callable

from . import profiles
from .common import HubError, george_dir, open_url
from .hw import probe
from .providers import IPFS, get_provider

CHUNK = 1 << 20


def downloads_dir() -> Path:
    d = george_dir() / "models" / "downloads"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _progress(name: str, **kw: Any) -> None:
    f = downloads_dir() / f"{name}.json"
    cur = {}
    if f.exists():
        try:
            cur = json.loads(f.read_text())
        except ValueError:
            cur = {}
    cur.update(kw, ts=int(time.time()))
    tmp = f.with_suffix(".tmp")
    tmp.write_text(json.dumps(cur))
    os.replace(tmp, f)


def _cancelled(name: str) -> bool:
    return (downloads_dir() / f"{name}.cancel").exists()


def _sha_file(path: Path, h: Any | None = None) -> Any:
    h = h or hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(CHUNK * 8), b""):
            h.update(chunk)
    return h


def _verified_marker(dest: Path) -> Path:
    return dest.with_name(dest.name + ".sha256")


def already_verified(dest: Path, size: int, sha: str) -> bool:
    m = _verified_marker(dest)
    if dest.exists() and dest.stat().st_size == size and m.exists():
        return m.read_text().strip() == sha and m.stat().st_mtime >= dest.stat().st_mtime
    return False


def _urls(p: dict[str, Any], f: dict[str, Any]) -> list[tuple[str, str | None]]:
    src = p["source"]
    if src["provider"] == "ipfs":
        return [(u, None) for u in IPFS().file_urls(f["cid"], f["path"])]
    prov = get_provider(src["provider"])
    return [(prov.file_url(src["repo"], src["revision"], f["path"]), prov.token())]


def download_file(name: str, url: str, token: str | None, dest: Path, size: int, sha: str,
                  on_bytes: Callable[[int], None]) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    have = part.stat().st_size if part.exists() else 0
    if have > size:
        part.unlink()
        have = 0
    h = _sha_file(part) if have else hashlib.sha256()
    on_bytes(have)
    if have < size:
        headers = {"Range": f"bytes={have}-"} if have else {}
        with open_url(url, token=token, headers=headers, timeout=60) as r:
            if have and r.status != 206:
                # Server ignored Range: restart from zero.
                have, h = 0, hashlib.sha256()
                part.unlink(missing_ok=True)
            with open(part, "ab") as out:
                while True:
                    if _cancelled(name):
                        raise HubError("cancelled by operator (partial file kept for resume)")
                    chunk = r.read(CHUNK)
                    if not chunk:
                        break
                    have += len(chunk)
                    if have > size:
                        raise HubError(f"{dest.name}: server sent more bytes than expected")
                    out.write(chunk)
                    h.update(chunk)
                    on_bytes(len(chunk))
    if have != size:
        raise HubError(f"{dest.name}: incomplete ({have}/{size} bytes); re-run install to resume")
    got = h.hexdigest()
    if got != sha:
        part.unlink(missing_ok=True)
        raise HubError(f"{dest.name}: sha256 mismatch (expected {sha[:12]}…, got {got[:12]}…); file discarded")
    os.replace(part, dest)
    _verified_marker(dest).write_text(sha)


def install(name: str, log: Callable[[str], None] = print) -> dict[str, Any]:
    p = profiles.load(name)
    if not profiles.is_approved(p):
        raise HubError("profile is not approved (or was edited after approval). "
                       "Review it, then approve: /models approve " + name)
    hw = probe()
    errs = profiles.validate(p, hw)
    if errs:
        raise HubError("profile failed validation:\n  - " + "\n  - ".join(errs[:20]))
    (downloads_dir() / f"{name}.cancel").unlink(missing_ok=True)
    root = profiles.local_root(p)
    total = sum(f["size"] for f in p["files"])
    done = 0
    is_local = p["source"]["provider"] == "local"
    _progress(name, state="running", kind="verify" if is_local else "download", total=total, done=0, file=None,
              error=None)

    def bump(n: int) -> None:
        nonlocal done
        done += n
        if done % (64 * CHUNK) < n or done >= total:
            _progress(name, done=done)

    try:
        for f in p["files"]:
            dest = root / f["path"]
            if is_local:
                _progress(name, file=f["path"])
                from . import library
                if not dest.is_file() or dest.stat().st_size != f["size"]:
                    raise HubError(f"{f['path']}: missing or size changed since import; re-import it from the Library")
                got = library.sha256_cached(dest, on_bytes=bump, cancelled=lambda: _cancelled(name))
                if got != f["sha256"]:
                    raise HubError(f"{f['path']}: sha256 mismatch (file changed since import); re-import it from the Library")
                log(f"✓ {f['path']} verified in place (sha256)")
                continue
            if already_verified(dest, f["size"], f["sha256"]):
                log(f"✓ {f['path']} already present and verified")
                bump(f["size"])
                continue
            _progress(name, file=f["path"])
            log(f"↓ {f['path']} ({round(f['size'] / (1 << 30), 2)} GiB)")
            last_err: Exception | None = None
            start_done = done
            for url, tok in _urls(p, f):
                try:
                    download_file(name, url, tok, dest, f["size"], f["sha256"], bump)
                    last_err = None
                    break
                except HubError as e:
                    last_err = e
                    if "cancelled" in str(e) or "sha256 mismatch" in str(e):
                        raise
                    done = start_done
                    log(f"  ! {e} — trying next source" if p["source"]["provider"] == "ipfs" else f"  ! {e}")
            if last_err:
                raise last_err
            log(f"✓ {f['path']} verified (sha256)")
        for a in p.get("adapters") or []:
            log(f"✓ adapter {a['path']} ({a['role']}, scale {a.get('scale', 1.0)})")
        profiles.verify_adapters(p)
    except HubError as e:
        _progress(name, state="failed", error=str(e))
        raise
    p["status"] = "installed"
    p["installed_at"] = int(time.time())
    p["local_files"] = {f["role"] + ":" + f["path"]: str(root / f["path"]) for f in p["files"]}
    for a in p.get("adapters") or []:
        p["local_files"][a["role"] + ":" + a["path"]] = str(profiles.adapters_dir() / a["path"])
    profiles.save(p)
    _progress(name, state="done", done=total)
    return {"name": name, "root": str(root), "bytes": total}


def remove(name: str, delete_files: bool = False) -> dict[str, Any]:
    p = profiles.load(name)
    removed = []
    if delete_files:
        root = profiles.local_root(p)
        for f in p["files"]:
            for path in (root / f["path"], (root / f["path"]).with_name(Path(f["path"]).name + ".sha256"),
                         (root / f["path"]).with_name(Path(f["path"]).name + ".part")):
                if path.exists() and root in path.resolve().parents:
                    path.unlink()
                    removed.append(str(path))
    profiles.profile_path(name).unlink(missing_ok=True)
    (downloads_dir() / f"{name}.json").unlink(missing_ok=True)
    return {"name": name, "deleted_files": removed}


def jobs() -> list[dict[str, Any]]:
    """Every download / import / verify / dataset job with its last recorded progress."""
    out = []
    for f in sorted(downloads_dir().glob("*.json"), key=lambda x: x.stat().st_mtime, reverse=True)[:50]:
        try:
            d = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(d, dict):
            continue
        d["name"] = f.stem
        d.setdefault("kind", "download")
        if d.get("state") == "running" and time.time() - int(d.get("ts") or 0) > 600:
            d["state"] = "stalled"
        out.append(d)
    return out


def disk_report() -> dict[str, Any]:
    from .hw import models_dir
    hub = models_dir() / "hub"
    used = 0
    if hub.exists():
        for f in hub.rglob("*"):
            if f.is_file():
                used += f.stat().st_size
    du = shutil.disk_usage(models_dir() if models_dir().exists() else Path.home())
    return {"models_dir": str(models_dir()), "hub_dir": str(hub), "hub_used_mb": used // (1 << 20),
            "disk_free_mb": du.free // (1 << 20), "disk_total_mb": du.total // (1 << 20)}
