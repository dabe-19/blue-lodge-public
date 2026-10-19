#!/usr/bin/env python3
"""
Compatibility shim. The previous cross-chain underwriter scored loans against hard-coded oracle
prices and a hard-coded "yield market" table; it has been replaced by:

  * lib/tools/sovereign_lending.py  - live-data underwriting, loan book, servicing
  * lib/tools/sovereign_fund.py     - treasury, fund ledger, real DeFiLlama yields

This file keeps the old CLI flags working (used by older routes/scripts):
  --json                      -> yield board + loan book summary (real data)
  --simulate --asset --units --req-usd --apr --days [--borrower] [--json]
                              -> sovereign_lending.underwrite(principal in ADA)
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
    p = argparse.ArgumentParser(description="(shim) Sovereign microloan underwriter")
    p.add_argument("--simulate", action="store_true")
    p.add_argument("--scan", action="store_true", help="(default) yields + loan book")
    p.add_argument("--asset", default="SNEK")
    p.add_argument("--units", type=float, default=20000.0)
    p.add_argument("--req-usd", type=float, default=20.0, help="Principal (ADA; legacy flag name)")
    p.add_argument("--apr", type=float, default=15.0)
    p.add_argument("--days", type=int, default=14)
    p.add_argument("--borrower", default="")
    p.add_argument("--json", action="store_true")
    a = p.parse_args()
    from lib.tools import sovereign_fund as fund
    from lib.tools import sovereign_lending as sl
    from lib.tools.quant.models import json_safe
    if a.simulate:
        borrower = a.borrower if sl.ADDR_RE.match(a.borrower or "") else ""
        res = sl.underwrite(a.asset, a.units, a.req_usd, a.days, a.apr, "ADA", borrower)
    else:
        res = {"status": "ok", "yields": fund.yields(), "book": sl.book_summary(),
               "note": "legacy scan replaced by real yields + loan book; see sovereign_lending.py"}
    print(json.dumps(json_safe(res), indent=None if a.json else 2, default=str))


if __name__ == "__main__":
    main()
