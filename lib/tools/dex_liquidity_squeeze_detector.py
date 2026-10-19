#!/usr/bin/env python3
"""
Sovereign DEX pool health & squeeze detector (v2, live data).

v1 audited a hard-coded table of reserves, "minutes since last swap" and "batcher queue depth"
(plus a STALE_MOCK_TRAP pair) - none of it came from chain. v2 measures, per asset, from
GeckoTerminal (cached, rate-paced):

  * every indexed ADA pool (all venues): price, reserves, 24h volume / trade count;
  * cross-venue price dispersion among live pools (a real dislocation signal);
  * time since the last trade on the primary pool (from the trades feed);
  * CPMM price impact for 50 / 100 ADA orders from actual reserves (incl. 0.3% fee);
  * volatility compression: realised sigma of the last 24 hourly bars vs. the trailing 7 days;
  * hourly bar coverage (share of hours with any trade) as the stale-pool measure.

Health: STALE_TRAP_HAZARD (no trade for > MAX_STALE_H hours or reserve < floor) ->
HARD_ABORT_TRAP; SHALLOW_CAUTION (50 ADA impact > 1.8%) -> REDUCE_ORDER_SIZE;
VOLATILITY_SQUEEZE_COILING (ratio <= 0.5) -> EXPAND_SPREADS; else DEEP_ACTIVE -> PERMIT_TRADES.
"""
from __future__ import annotations

import argparse
import json
import logging
import math
import os
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

import numpy as np

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if __name__ == "__main__" and _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)

from lib.tools.quant import market_data as md  # noqa: E402

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", stream=sys.stderr)
logger = logging.getLogger("dex_liquidity_squeeze_detector")

LODGE_DIR = Path(os.environ.get("LODGE_DIR", _REPO_ROOT))
CACHE_FILE = LODGE_DIR / ".george" / "finance" / "liquidity_squeeze_cache.json"

MAX_STALE_H = 6.0
MIN_SAFE_POOL_RESERVE_ADA = 15_000.0
MAX_ACCEPTABLE_SLIPPAGE_PCT = 1.80
SQUEEZE_RATIO = 0.50
POOL_FEE = 0.003


@dataclass
class PoolLiquidityAudit:
    pair: str
    dex: str
    asset: str
    pool_address: Optional[str]
    price_ada: Optional[float]
    reserve_ada: Optional[float]
    volume_usd_24h: Optional[float]
    trades_24h: Optional[int]
    staleness_minutes: Optional[float]
    hourly_coverage: Optional[float]
    slippage_50_ada_pct: Optional[float]
    slippage_100_ada_pct: Optional[float]
    volatility_squeeze_ratio: Optional[float]
    venue_count: int
    venue_spread_pct: Optional[float]
    venues: List[Dict[str, Any]] = field(default_factory=list)
    is_stale_trap: bool = False
    is_volatility_squeeze: bool = False
    liquidity_health: str = "UNKNOWN"
    trading_action: str = "NO_DATA"
    rationale: str = ""


def cpmm_impact_pct(order_ada: float, reserve_ada: Optional[float]) -> Optional[float]:
    """Effective price impact (incl. pool fee) of swapping order_ada into a CPMM pool."""
    if not reserve_ada or reserve_ada <= 0:
        return None
    dx = order_ada * (1 - POOL_FEE)
    return round((1 - (reserve_ada / (reserve_ada + dx)) * (1 - POOL_FEE)) * 100.0, 3)


def compute_kyles_lambda_slippage(order_ada: float, reserve_ada: float) -> float:
    """Backward-compatible name for the CPMM impact."""
    v = cpmm_impact_pct(order_ada, reserve_ada)
    return 100.0 if v is None else v


def audit_pool_liquidity(pair_symbol: str) -> PoolLiquidityAudit:
    pair = pair_symbol.upper()
    asset = pair.split("/")[0]
    if asset not in md.KNOWN_ASSETS:
        return PoolLiquidityAudit(pair=pair, dex="-", asset=asset, pool_address=None, price_ada=None,
                                  reserve_ada=None, volume_usd_24h=None, trades_24h=None, staleness_minutes=None,
                                  hourly_coverage=None, slippage_50_ada_pct=None, slippage_100_ada_pct=None,
                                  volatility_squeeze_ratio=None, venue_count=0, venue_spread_pct=None,
                                  liquidity_health="UNKNOWN", trading_action="NO_DATA",
                                  rationale=f"{asset} is not a known asset ({sorted(md.KNOWN_ASSETS)})")
    s = md.load_series(asset, "hour")
    if s.get("status") != "ok":
        return PoolLiquidityAudit(pair=pair, dex="-", asset=asset, pool_address=None, price_ada=None,
                                  reserve_ada=None, volume_usd_24h=None, trades_24h=None, staleness_minutes=None,
                                  hourly_coverage=None, slippage_50_ada_pct=None, slippage_100_ada_pct=None,
                                  volatility_squeeze_ratio=None, venue_count=0, venue_spread_pct=None,
                                  liquidity_health="UNKNOWN", trading_action="NO_DATA",
                                  rationale=f"market data unavailable: {s.get('reason')}")
    pool = s["pool"]
    live = [p for p in s.get("all_pools", []) if not p.get("off_market")]
    venues = [{"dex": p["dex"], "price_ada": p["price_ada"], "reserve_ada": round(p["reserve_ada_est"] or 0),
               "volume_usd_24h": round(p["volume_usd_24h"], 2), "pool_address": p["pool_address"]} for p in live]
    spread = None
    if len(live) >= 2:
        px = [p["price_ada"] for p in live]
        spread = round((max(px) / min(px) - 1) * 100, 3)
    # last trade on the primary pool
    stale_min = None
    tr = md.fetch_pool_trades(pool["pool_address"])
    if tr.get("status") == "ok" and tr["trades"]:
        stale_min = round((time.time() - tr["trades"][-1]["time"]) / 60.0, 1)
    g = s["grid"]
    c = np.asarray(g["c"], float)
    r = np.diff(np.log(c))
    squeeze = None
    if len(r) >= 24 * 8:
        s24 = float(np.std(r[-24:], ddof=1))
        s7d = float(np.std(r[-24 * 7:], ddof=1))
        squeeze = round(s24 / s7d, 3) if s7d > 0 else None
    cov = float(np.mean(g["traded"][-24 * 7:])) if len(g["traded"]) else None
    res_ada = pool.get("reserve_ada_est")
    slip50, slip100 = cpmm_impact_pct(50, res_ada), cpmm_impact_pct(100, res_ada)
    reasons = []
    is_stale = False
    if stale_min is not None and stale_min > MAX_STALE_H * 60:
        is_stale = True
        reasons.append(f"no trade for {stale_min / 60:.1f}h (> {MAX_STALE_H}h)")
    if res_ada is not None and res_ada < MIN_SAFE_POOL_RESERVE_ADA:
        is_stale = True
        reasons.append(f"reserve {res_ada:,.0f} ADA < {MIN_SAFE_POOL_RESERVE_ADA:,.0f}")
    is_squeeze = squeeze is not None and squeeze <= SQUEEZE_RATIO
    if is_stale:
        health, action = "STALE_TRAP_HAZARD", "HARD_ABORT_TRAP"
        rationale = "Do not rest limit orders here: " + " & ".join(reasons)
    elif slip50 is not None and slip50 > MAX_ACCEPTABLE_SLIPPAGE_PCT:
        health, action = "SHALLOW_CAUTION", "REDUCE_ORDER_SIZE"
        rationale = f"50 ADA impact {slip50:.2f}% > {MAX_ACCEPTABLE_SLIPPAGE_PCT}%"
    elif is_squeeze:
        health, action = "VOLATILITY_SQUEEZE_COILING", "EXPAND_SPREADS"
        rationale = f"24h realised vol is {squeeze:.2f}x the 7d level; widen maker corridors"
    else:
        health, action = "DEEP_ACTIVE", "PERMIT_TRADES"
        rationale = (f"reserve {res_ada:,.0f} ADA, last trade {stale_min if stale_min is not None else '?'} min ago, "
                     f"{(cov or 0):.0%} of hours traded (7d)")
    if spread is not None and spread > 1.0:
        rationale += f"; cross-venue dispersion {spread:.2f}% across {len(live)} live pools"
    return PoolLiquidityAudit(
        pair=f"{asset}/ADA", dex=str(pool.get("dex")), asset=asset, pool_address=pool.get("pool_address"),
        price_ada=pool.get("price_ada"), reserve_ada=round(res_ada, 2) if res_ada else None,
        volume_usd_24h=round(pool.get("volume_usd_24h") or 0, 2), trades_24h=(pool.get("tx_24h") or {}).get("buys", 0)
        + (pool.get("tx_24h") or {}).get("sells", 0) if isinstance(pool.get("tx_24h"), dict) else pool.get("tx_24h"),
        staleness_minutes=stale_min, hourly_coverage=round(cov, 3) if cov is not None else None,
        slippage_50_ada_pct=slip50, slippage_100_ada_pct=slip100, volatility_squeeze_ratio=squeeze,
        venue_count=len(live), venue_spread_pct=spread, venues=venues, is_stale_trap=is_stale,
        is_volatility_squeeze=is_squeeze, liquidity_health=health, trading_action=action, rationale=rationale)


def scan_all_pools() -> Dict[str, Any]:
    audits = [asdict(audit_pool_liquidity(f"{a}/ADA")) for a in md.KNOWN_ASSETS]
    payload = {"status": "ok", "schema": "pool_health/v2", "timestamp": int(time.time()),
               "total_pools_audited": len(audits),
               "stale_traps_blocked": sum(1 for a in audits if a["is_stale_trap"]),
               "volatility_squeezes_flagged": sum(1 for a in audits if a["is_volatility_squeeze"]),
               "dislocations": [{"asset": a["asset"], "venue_spread_pct": a["venue_spread_pct"], "venues": a["venues"]}
                                for a in audits if (a["venue_spread_pct"] or 0) > 1.0],
               "pools": audits, "source": "GeckoTerminal (live, cached)"}
    try:
        CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
        CACHE_FILE.write_text(json.dumps(payload, indent=2, default=str))
    except OSError as e:
        logger.warning(f"Could not persist cache: {e}")
    return payload


def _fmt(v, f):
    return "?" if v is None else format(v, f)


def print_audit_dashboard(scan_res: Dict[str, Any]) -> None:
    print("=" * 100)
    print("  DEX POOL HEALTH & SQUEEZE DETECTOR (live)")
    print("=" * 100)
    print(f"  {'PAIR':<10} {'DEX':<18} {'RESERVE ADA':>12} {'LAST TRADE':>11} {'COV7D':>6} {'SLIP50':>7} "
          f"{'SQZ':>5} {'VENUES':>6} {'DISP%':>6}  STATUS")
    for p in scan_res.get("pools", []):
        print(f"  {p['pair']:<10} {p['dex'][:18]:<18} {_fmt(p['reserve_ada'], ',.0f'):>12} "
              f"{_fmt(p['staleness_minutes'], '.0f') + 'm':>11} {_fmt(p['hourly_coverage'], '.0%'):>6} "
              f"{_fmt(p['slippage_50_ada_pct'], '.2f'):>7} {_fmt(p['volatility_squeeze_ratio'], '.2f'):>5} "
              f"{p['venue_count']:>6} {_fmt(p['venue_spread_pct'], '.2f'):>6}  {p['liquidity_health']}")
    print("=" * 100)


def main() -> None:
    parser = argparse.ArgumentParser(description="DEX pool health & squeeze detector (live data)")
    parser.add_argument("--scan", action="store_true", help="Scan all known assets (default)")
    parser.add_argument("--pair", type=str, help="e.g. SNEK/ADA")
    parser.add_argument("--check-trap", action="store_true", help="Exit 1 if the pair is a stale trap")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if args.pair:
        res = audit_pool_liquidity(args.pair)
        if args.check_trap:
            sys.exit(1 if res.is_stale_trap or res.trading_action == "NO_DATA" else 0)
        if args.json:
            print(json.dumps(asdict(res), default=str))
        else:
            print(json.dumps(asdict(res), indent=2, default=str))
        return
    scan_res = scan_all_pools()
    if args.json:
        print(json.dumps(scan_res, default=str))
    else:
        print_audit_dashboard(scan_res)


if __name__ == "__main__":
    main()
