#!/usr/bin/env python3
"""
Compatibility shim. The previous Cardano P2P underwriter "scanned" a hard-coded DJED loan for every
UTxO at a broken PoC escrow, added three fabricated benchmark loans, used invented fallback prices
and wrong policy ids. It is replaced by lib/tools/sovereign_lending.py (live-data underwriting,
loan book, on-chain servicing). Old flags still work:

  --scan [--json]                                  -> loan book summary
  --simulate --asset --units --req-ada --interest-ada --duration [--json]
                                                   -> underwrite (interest converted to APR)
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if __name__ == "__main__" and _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)


def main() -> None:
    p = argparse.ArgumentParser(description="(shim) Cardano P2P loan underwriter")
    p.add_argument("--scan", action="store_true")
    p.add_argument("--simulate", action="store_true")
    p.add_argument("--asset", default="SNEK")
    p.add_argument("--units", type=float, default=20000.0)
    p.add_argument("--req-ada", type=float, default=20.0)
    p.add_argument("--interest-ada", type=float, default=0.15)
    p.add_argument("--duration", type=float, default=14.0)
    p.add_argument("--json", action="store_true")
    a = p.parse_args()
    from lib.tools import sovereign_lending as sl
    from lib.tools.quant.models import json_safe
    if a.simulate:
        days = max(1, int(round(a.duration)))
        apr = (a.interest_ada / a.req_ada) * (365.0 / days) * 100.0 if a.req_ada > 0 else 0.0
        res = sl.underwrite(a.asset, a.units, a.req_ada, days, apr, "ADA")
    else:
        res = sl.book_summary()
    print(json.dumps(json_safe(res), indent=None if a.json else 2, default=str))


if __name__ == "__main__":
    main()
