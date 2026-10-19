"""Operator feature flags for capabilities that ship disabled in the public tree.

Resolution order for ``flag(name)``:
  1. the process environment (``NAME=1`` / ``NAME=0``) — always wins;
  2. ``$GEORGE_DIR/features.conf`` (default ``<repo>/.george/features.conf``), KEY=VALUE lines;
  3. the caller-supplied default (public builds pass ``False``).

``.george/`` is gitignored, so an operator can enable a capability on their own box
without it ever being enabled for anyone who clones the repo.

Known flags:
  GEORGE_EXECUTE_LIVE_SELL        maker-sell reactor builds/submits real sell transactions
  GEORGE_REDDIT_CHALLENGE_SOLVER  solve Reddit's JS proof-of-work interstitial on fetch

CLI:  feature_flags.py get <NAME> [default]   → prints 1/0, rc 0 when enabled
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

_NAME_RX = re.compile(r"^[A-Z][A-Z0-9_]{1,63}$")
_TRUE = {"1", "true", "yes", "on"}
_FALSE = {"0", "false", "no", "off", ""}


def _conf_path() -> Path:
    base = os.environ.get("GEORGE_DIR") or str(Path(__file__).resolve().parents[2] / ".george")
    return Path(base) / "features.conf"


def _read_conf(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return out
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        if k.startswith("export "):
            k = k[7:].strip()
        if _NAME_RX.match(k):
            out[k] = v.strip().strip('"').strip("'")
    return out


def _parse(val: str | None) -> bool | None:
    if val is None:
        return None
    v = val.strip().lower()
    if v in _TRUE:
        return True
    if v in _FALSE:
        return False
    return None


def flag(name: str, default: bool = False) -> bool:
    if not _NAME_RX.match(name):
        return default
    env = _parse(os.environ.get(name))
    if env is not None:
        return env
    conf = _parse(_read_conf(_conf_path()).get(name))
    return default if conf is None else conf


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "get":
        default = len(argv) > 2 and argv[2].strip().lower() in _TRUE
        on = flag(argv[1], default)
        print("1" if on else "0")
        return 0 if on else 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
