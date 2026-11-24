#!/usr/bin/env python3
"""
Coinbase ADA-USD reference price: live spot tick + 5-minute candle backfill into market.db.

S3 (stablecoin deviation) fair value for USDM/USDCX/DJED in ADA is 1 / ADAUSD, so the CEX
series is a first-class input. Live ticks come from the cron job api_coinbase_ada.sh (60s);
`backfill` pulls public Coinbase Exchange candles (300 per request, no key) so the backtester
has the same history as the pool recorder.

CLI:
  cex_feed.py tick                 fetch spot once and record it
  cex_feed.py backfill --days 30   5-minute candles into cex_bars_5m (idempotent)
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any, Dict

_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from lib.tools.quant import market_db as mdb  # noqa: E402

SPOT_URL = "https://api.coinbase.com/v2/prices/ADA-USD/spot"
CANDLES_URL = "https://api.exchange.coinbase.com/products/ADA-USD/candles"
UA = {"User-Agent": "BlueLodge-CexFeed/1.0", "Accept": "application/json"}


def _get(url: str, timeout: int = 15) -> Any:
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
        return json.loads(r.read().decode())


def tick(con=None) -> Dict[str, Any]:
    own = con is None
    con = con or mdb.connect()
    try:
        price = float(_get(SPOT_URL)["data"]["amount"])
        ts = int(time.time())
        mdb.record_cex_tick(con, ts, "ADA-USD", price)
        con.commit()
        return {"status": "ok", "ts": ts, "price": price}
    finally:
        if own:
            con.close()


def backfill(days: int = 30, con=None) -> Dict[str, Any]:
    own = con is None
    con = con or mdb.connect()
    try:
        end = int(time.time())
        start = end - days * 86400
        step = 300 * 300  # 300 candles of 5 minutes per request
        n = 0
        t = start
        while t < end:
            t2 = min(end, t + step)
            q = (f"?granularity=300&start={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(t))}"
                 f"&end={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(t2))}")
            rows = _get(CANDLES_URL + q)
            for r in rows:  # [time, low, high, open, close, volume]
                bucket = int(r[0]) - int(r[0]) % mdb.BAR_S
                con.execute("INSERT OR REPLACE INTO cex_bars_5m VALUES (?,?,?,?,?,?,?)",
                            (bucket, "ADA-USD", float(r[3]), float(r[2]), float(r[1]), float(r[4]), 1))
                n += 1
            con.commit()
            t = t2
            time.sleep(0.4)  # public endpoint: stay well under 10 req/s
        return {"status": "ok", "bars": n, "days": days}
    finally:
        if own:
            con.close()


def main() -> None:
    import argparse
    ap = argparse.ArgumentParser(description="Coinbase ADA-USD reference feed")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("tick")
    b = sub.add_parser("backfill")
    b.add_argument("--days", type=int, default=30)
    a = ap.parse_args()
    try:
        res = tick() if a.cmd == "tick" else backfill(max(1, min(a.days, 365)))
    except Exception as e:
        res = {"status": "error", "message": f"{type(e).__name__}: {e}"}
    print(json.dumps(res, indent=2))


if __name__ == "__main__":
    main()
