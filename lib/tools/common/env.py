"""
Canonical environment and secrets resolution for Blue Lodge tools.
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Dict, Optional

_REPO_ROOT = Path(__file__).resolve().parents[3]
LODGE_DIR: Path = Path(os.environ.get("LODGE_DIR", _REPO_ROOT))
GEORGE_DIR: Path = Path(os.environ.get("GEORGE_DIR", LODGE_DIR / ".george"))
SECRETS_ENV_PATH: Path = GEORGE_DIR / "secrets.env"
EVENT_BUS_FIFO: Path = GEORGE_DIR / "ipc" / "event_bus.fifo"


def load_secrets(include_environ: bool = True, secrets_path: Optional[Path] = None) -> Dict[str, str]:
    """
    Parse .george/secrets.env (and optionally .env) and merge with os.environ.
    """
    env: Dict[str, str] = dict(os.environ) if include_environ else {}
    paths = [secrets_path] if secrets_path is not None else [SECRETS_ENV_PATH, LODGE_DIR / ".george" / "secrets.env", LODGE_DIR / ".env"]
    for p in paths:
        if p and p.exists():
            try:
                for raw_line in p.read_text(encoding="utf-8", errors="replace").splitlines():
                    line = raw_line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    if line.startswith("export "):
                        line = line[len("export "):].strip()
                    k, v = line.split("=", 1)
                    key = k.strip()
                    val = v.strip().strip('"').strip("'")
                    if key and (not include_environ or key not in env or not env[key]):
                        env[key] = val
            except Exception:
                pass
    return env


def get_secret(key: str, default: str = "") -> str:
    """Retrieve a single secret from os.environ or .george/secrets.env."""
    val = os.environ.get(key)
    if val:
        return val
    return load_secrets(include_environ=False).get(key, default)


def populate_environ() -> None:
    """Populate os.environ in-place with values from .george/secrets.env (without overwriting existing env vars)."""
    for k, v in load_secrets(include_environ=False).items():
        if v:
            os.environ.setdefault(k, v)

