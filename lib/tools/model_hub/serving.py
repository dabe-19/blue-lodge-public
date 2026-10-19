"""What is actually being served, and the operator's optional launch presets.

server_status() asks each configured llama-server endpoint (TIER*_URL in .george/endpoints.conf) for
/health and /props, so the UI shows the real loaded model and real context size instead of labels.

Presets are purely operator-defined (.george/models/presets.json, never committed). They let an
operator keep a custom launch script (forked llama.cpp builds, split-GPU stacks, ...) one click away
without Blue Lodge shipping any model-specific assumptions. See config/models/presets.example.json.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from .common import HubError, george_dir, lodge_dir
from .hw import models_dir

PRESET_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
PRESET_ARG_RE = re.compile(r"^[A-Za-z0-9._:/=+,@-]{1,160}$")
MAX_PRESETS = 16


def _endpoints() -> list[dict[str, Any]]:
    f = george_dir() / "endpoints.conf"
    vals: dict[str, str] = {}
    try:
        for line in f.read_text().splitlines():
            m = re.match(r"^(TIER\d)_(URL|MODEL|CONTEXT|ENABLED)=(.*)$", line.strip())
            if m:
                vals[f"{m.group(1)}_{m.group(2)}"] = m.group(3).strip().strip("\"'")
    except OSError:
        return []
    out = []
    for tier in sorted({k.split("_")[0] for k in vals}):
        url = vals.get(f"{tier}_URL", "")
        p = urllib.parse.urlparse(url)
        if p.scheme not in ("http", "https") or not p.hostname:
            continue
        out.append({"tier": tier, "url": f"{p.scheme}://{p.netloc}", "configured_model": vals.get(f"{tier}_MODEL"),
                    "configured_ctx": int(vals[f"{tier}_CONTEXT"]) if vals.get(f"{tier}_CONTEXT", "").isdigit() else None,
                    "enabled": vals.get(f"{tier}_ENABLED", "1") != "0"})
    return out


def _get(url: str, timeout: float = 2.5) -> Any:
    req = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "George-ModelHub/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 - operator-configured local endpoint
        return json.loads(r.read(2 << 20) or b"null")


def _map_model_path(path: str | None) -> str | None:
    """Map a server-side model path (/models/... inside docker, or a host path) to MODELS_DIR-relative."""
    if not path or not isinstance(path, str):
        return None
    base = models_dir()
    cand = base / path[len("/models/"):] if path.startswith("/models/") else Path(path)
    try:
        rp = cand.resolve(strict=True)
        rb = base.resolve()
    except (OSError, RuntimeError):
        return None
    return rp.relative_to(rb).as_posix() if str(rp).startswith(str(rb) + os.sep) else None


def server_status() -> dict[str, Any]:
    eps = []
    for ep in _endpoints():
        st: dict[str, Any] = dict(ep)
        try:
            h = _get(ep["url"] + "/health")
            st["ok"] = isinstance(h, dict) and h.get("status") in ("ok", "no slot available")
            st["health"] = h.get("status") if isinstance(h, dict) else None
        except (urllib.error.URLError, OSError, ValueError) as e:
            st.update(ok=False, health=None, error=str(getattr(e, "reason", e))[:120])
            eps.append(st)
            continue
        try:
            props = _get(ep["url"] + "/props")
            dgs = props.get("default_generation_settings") or {}
            st.update(model_path=props.get("model_path"), n_ctx=dgs.get("n_ctx") or props.get("n_ctx"),
                      slots=props.get("total_slots"), modalities=props.get("modalities"),
                      build=props.get("build_info"), chat_template=bool(props.get("chat_template")))
        except (urllib.error.URLError, OSError, ValueError, AttributeError):
            pass
        try:
            models = _get(ep["url"] + "/v1/models")
            m = ((models or {}).get("data") or [{}])[0]
            meta = m.get("meta") or {}
            st.setdefault("model_path", m.get("id"))
            st.update(n_ctx_train=meta.get("n_ctx_train"), n_params=meta.get("n_params"), size=meta.get("size"),
                      ftype=meta.get("ftype"))
            st["n_ctx"] = st.get("n_ctx") or meta.get("n_ctx")
        except (urllib.error.URLError, OSError, ValueError, AttributeError, IndexError):
            pass
        st["model_rel"] = _map_model_path(st.get("model_path"))
        eps.append(st)
    active = None
    try:
        active = json.loads((george_dir() / "models" / "active_profile.json").read_text())
    except (OSError, ValueError):
        pass
    return {"endpoints": eps, "active_profile": active, "can_rollback": bool(active)}


# ── presets ────────────────────────────────────────────────────────────────────

def presets_file() -> Path:
    return george_dir() / "models" / "presets.json"


def _validate_preset(p: Any, i: int) -> dict[str, Any]:
    if not isinstance(p, dict):
        raise HubError(f"presets[{i}]: must be an object")
    pid = str(p.get("id", ""))
    if not PRESET_ID_RE.match(pid):
        raise HubError(f"presets[{i}].id: lowercase a-z0-9_- (max 32)")
    script = str(p.get("script", ""))
    lodge = lodge_dir().resolve()
    sp = (lodge / script).resolve()
    if (not script or script.startswith("/") or ".." in Path(script).parts
            or not str(sp).startswith(str(lodge / "scripts") + os.sep) or not sp.is_file()):
        raise HubError(f"presets[{i}].script: must be an existing file under scripts/ in the lodge")
    args = p.get("args") or []
    if not isinstance(args, list) or len(args) > 12 or not all(isinstance(a, str) and PRESET_ARG_RE.match(a) for a in args):
        raise HubError(f"presets[{i}].args: up to 12 plain arguments ([A-Za-z0-9._:/=+,@-])")
    return {"id": pid, "label": str(p.get("label") or pid)[:60], "description": str(p.get("description") or "")[:400],
            "script": script, "args": args, "status_args": [a for a in (p.get("status_args") or [])
                                                            if isinstance(a, str) and PRESET_ARG_RE.match(a)][:6]}


def presets() -> dict[str, Any]:
    f = presets_file()
    if not f.exists():
        return {"file": str(f), "presets": [], "configured": False}
    try:
        raw = json.loads(f.read_text())
    except ValueError as e:
        raise HubError(f"{f}: invalid JSON ({e})") from None
    items = raw.get("presets") if isinstance(raw, dict) else None
    if not isinstance(items, list):
        raise HubError(f"{f}: expected {{\"presets\": [...]}}")
    out, errors = [], []
    for i, p in enumerate(items[:MAX_PRESETS]):
        try:
            out.append(_validate_preset(p, i))
        except HubError as e:
            errors.append(str(e))
    return {"file": str(f), "presets": out, "errors": errors, "configured": True}


def run_preset(pid: str, status: bool = False, timeout: int = 900) -> dict[str, Any]:
    p = next((x for x in presets()["presets"] if x["id"] == pid), None)
    if not p:
        raise HubError(f"no preset '{pid}' in {presets_file()}")
    args = p["status_args"] if status else p["args"]
    if status and not args:
        raise HubError(f"preset '{pid}' has no status_args")
    argv = ["bash", str(lodge_dir() / p["script"]), *args]
    try:
        r = subprocess.run(argv, cwd=str(lodge_dir()), capture_output=True, text=True, timeout=timeout,
                           env={**os.environ, "LODGE_DIR": str(lodge_dir())}, stdin=subprocess.DEVNULL, check=False)
    except subprocess.TimeoutExpired:
        raise HubError(f"preset '{pid}' timed out after {timeout}s (it may still be starting)") from None
    tail = lambda s: "\n".join(s.splitlines()[-60:])  # noqa: E731
    return {"id": pid, "exit_code": r.returncode, "ok": r.returncode == 0, "output": tail(r.stdout),
            "stderr": tail(r.stderr)}
