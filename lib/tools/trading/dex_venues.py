#!/usr/bin/env python3
"""
Multi-DEX Cardano Venue Fee, Batcher Friction & Liquidity Comparator.

Compares round-trip fee hurdles, batcher/scooper fixed ADA overhead, S1 positive-EV
exit bounce hurdles, and S2 minimum viable order sizes across Cardano DEX venues
(Minswap V2, SundaeSwap V3, Splash, WingRiders V2, CSWAP) using local telemetry
from market.db, trading.db (cross_dex_spreads), and dex_sniper_cache.json with zero
blocking network calls.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

LODGE_DIR = Path(__file__).resolve().parents[3]
if str(LODGE_DIR) not in sys.path:
    sys.path.insert(0, str(LODGE_DIR))

from lib.tools.quant import market_db as mdb
from lib.tools.trading import policy, store

ASSET_RE = re.compile(r"^[A-Z0-9]{1,16}$")
SNIPER_CACHE_PATH = LODGE_DIR / ".george" / "wallets" / "dex_sniper_cache.json"

# Canonical Cardano Mainnet DEX protocol schedules.
# batcher_fee_ada = per-leg batcher/scooper/agent execution fee on Cardano Mainnet.
# network_fee_ada = per-leg Cardano L1 tx fee (~0.20 ADA).
VENUE_CATALOG: List[Dict[str, Any]] = [
    {
        "venue": "Minswap V2",
        "protocol_id": "MinswapV2",
        "amm_model": "Dynamic-Fee CPMM + Limit Book",
        "default_lp_fee_bps": 30.0,
        "min_lp_fee_bps": 5.0,
        "max_lp_fee_bps": 30.0,
        "batcher_fee_ada": 2.00,
        "network_fee_ada": 0.20,
        "native_builder_status": "live_plutus_v2",
        "enterprise_wallet_ok": True,
        "notes": "Primary Sovereign execution venue (native SwapExactIn limit builder + auto S1 exit)",
    },
    {
        "venue": "SundaeSwap V3",
        "protocol_id": "SundaeSwapV3",
        "amm_model": "Tiered Concentrated / V3 AMM",
        "default_lp_fee_bps": 10.0,
        "min_lp_fee_bps": 5.0,
        "max_lp_fee_bps": 30.0,
        "batcher_fee_ada": 1.28,
        "network_fee_ada": 0.20,
        "native_builder_status": "aggregator_quote_ready",
        "enterprise_wallet_ok": True,
        "notes": "Low scooper fee (1.28 ADA/leg) + 5-30 bps fee tiers; strongest low-size S2 friction profile",
    },
    {
        "venue": "Splash",
        "protocol_id": "Splash",
        "amm_model": "Hybrid Orderbook + CPMM",
        "default_lp_fee_bps": 15.0,
        "min_lp_fee_bps": 10.0,
        "max_lp_fee_bps": 30.0,
        "batcher_fee_ada": 1.50,
        "network_fee_ada": 0.20,
        "native_builder_status": "aggregator_quote_ready",
        "enterprise_wallet_ok": True,
        "notes": "Off-chain batcher orderbook with 1.50 ADA execution fee on liquid pairs",
    },
    {
        "venue": "WingRiders V2",
        "protocol_id": "WingRidersV2",
        "amm_model": "Constant-Product / Stable V2",
        "default_lp_fee_bps": 20.0,
        "min_lp_fee_bps": 20.0,
        "max_lp_fee_bps": 35.0,
        "batcher_fee_ada": 2.00,
        "network_fee_ada": 0.20,
        "native_builder_status": "aggregator_quote_ready",
        "enterprise_wallet_ok": True,
        "notes": "2.0 ADA agent fee per leg; deep secondary liquidity on Cardano DeFi majors",
    },
    {
        "venue": "CSWAP",
        "protocol_id": "CswapV1",
        "amm_model": "CPMM V1",
        "default_lp_fee_bps": 30.0,
        "min_lp_fee_bps": 30.0,
        "max_lp_fee_bps": 30.0,
        "batcher_fee_ada": 2.00,
        "network_fee_ada": 0.20,
        "native_builder_status": "spread_surveillance_only",
        "enterprise_wallet_ok": True,
        "notes": "Monitored for cross-DEX dislocations (thin reserve depth on mid-caps)",
    },
]


def _default_size_ada(con, pol: Dict[str, Any]) -> float:
    row = con.execute("SELECT equity_ada FROM equity ORDER BY ts DESC LIMIT 1").fetchone()
    if row and row[0]:
        working = max(0.0, float(row[0]) - float(pol["wallet"]["floor_ada"]) - float(pol["wallet"]["fee_buffer_ada"]))
        cap = round(working * float(pol["capital"]["max_position_fraction"]), 2)
        if cap >= float(pol["capital"].get("min_order_ada", 25.0)):
            return cap
    return 340.0


def _load_sniper_quotes(asset: str) -> Dict[str, Dict[str, Any]]:
    if not SNIPER_CACHE_PATH.exists():
        return {}
    try:
        raw = json.loads(SNIPER_CACHE_PATH.read_text())
    except Exception:
        return {}
    out: Dict[str, Dict[str, Any]] = {}
    for q in raw.get("quotes") or []:
        if str(q.get("asset") or "").upper() != asset:
            continue
        proto = str(q.get("protocol") or q.get("venue") or "")
        if proto:
            out[proto] = q
    return out


def compare_venues(asset: str = "NIGHT", size_ada: Optional[float] = None) -> Dict[str, Any]:
    sym = (asset or "NIGHT").strip().upper()
    if not ASSET_RE.match(sym):
        return {"status": "error", "message": f"invalid asset symbol: {asset!r}"}

    pol = policy.load_policy()
    con = store.connect()
    mcon = mdb.connect()
    try:
        trade_ada = float(size_ada) if (size_ada is not None and size_ada > 0) else _default_size_ada(con, pol)
        s1_cfg = (pol.get("strategies") or {}).get("S1_inventory_exit") or {}
        min_net_ada = float(s1_cfg.get("min_net_profit_ada", 1.0))
        floor_markup = float(s1_cfg.get("exit_floor_markup", 0.005))

        # Primary Minswap V2 telemetry from pool_snapshots
        snap = mcon.execute(
            "SELECT ts, reserve_ada, spot, fee_bps FROM pool_snapshots WHERE asset=? ORDER BY ts DESC LIMIT 1",
            (sym,),
        ).fetchone()
        minswap_reserve_ada = float(snap["reserve_ada"]) if snap and snap["reserve_ada"] else None
        minswap_spot = float(snap["spot"]) if (snap and snap["spot"] and float(snap["spot"]) > 0) else None
        minswap_fee_bps = float(snap["fee_bps"]) if (snap and snap["fee_bps"] is not None) else None

        # Recent cross_dex_spreads telemetry (last 24h) per venue
        cutoff = int(time.time()) - 86400
        spread_rows = con.execute(
            "SELECT buy_dex, sell_dex, spot_buy_ada, spot_sell_ada, eff_reserve_ada, ts "
            "FROM cross_dex_spreads WHERE asset=? AND ts>=? ORDER BY ts DESC LIMIT 60",
            (sym, cutoff),
        ).fetchall()
        observed_venues: Dict[str, Dict[str, Any]] = {}
        for sr in spread_rows:
            for side_col, px_col in (("buy_dex", "spot_buy_ada"), ("sell_dex", "spot_sell_ada")):
                vname = str(sr[side_col] or "")
                if vname and vname not in observed_venues:
                    observed_venues[vname] = {
                        "spot_ada": float(sr[px_col]) if sr[px_col] else None,
                        "eff_reserve_ada": float(sr["eff_reserve_ada"]) if sr["eff_reserve_ada"] else None,
                        "ts": int(sr["ts"]),
                    }

        sniper_quotes = _load_sniper_quotes(sym)
        venues_out: List[Dict[str, Any]] = []
        for v in VENUE_CATALOG:
            pid = v["protocol_id"]
            v_short = v["venue"].split()[0]
            lp_bps = (
                minswap_fee_bps
                if (pid == "MinswapV2" and minswap_fee_bps is not None)
                else float(v["default_lp_fee_bps"])
            )
            fee_frac = lp_bps / 1e4
            rt_fixed_ada = round(2.0 * (float(v["batcher_fee_ada"]) + float(v["network_fee_ada"])), 2)
            # Reserve & spot lookup: Minswap snapshot -> sniper cache -> cross_dex_spreads
            reserve_ada = minswap_reserve_ada if pid == "MinswapV2" else None
            spot_ada = minswap_spot if pid == "MinswapV2" else None
            sq = sniper_quotes.get(pid) or sniper_quotes.get(v_short)
            if sq:
                reserve_ada = reserve_ada or (float(sq["reserve_ada"]) if sq.get("reserve_ada") else None)
                spot_ada = spot_ada or (float(sq["spot_ada"]) if sq.get("spot_ada") else None)
            obs = observed_venues.get(pid) or observed_venues.get(v_short)
            if obs:
                reserve_ada = reserve_ada or obs.get("eff_reserve_ada")
                spot_ada = spot_ada or obs.get("spot_ada")

            impact_pct = (trade_ada / reserve_ada * 100.0) if (reserve_ada and reserve_ada > 0) else 0.0
            rt_hurdle_pct = round((rt_fixed_ada / max(trade_ada, 1.0) + 2.0 * fee_frac) * 100.0 + impact_pct, 2)
            s1_pos_ev_bounce_pct = round(
                ((rt_fixed_ada + min_net_ada) / max(trade_ada, 1.0) + 2.0 * fee_frac) * 100.0, 2
            )
            # Minimum order size (ADA) to clear fixed round-trip fees + floor_markup on a 2.5% shock fade
            target_gross_edge = 0.025 - 2.0 * fee_frac - floor_markup
            min_viable_250bps_ada = round(rt_fixed_ada / target_gross_edge, 1) if target_gross_edge > 1e-4 else None

            venues_out.append({
                "venue": v["venue"],
                "protocol_id": pid,
                "amm_model": v["amm_model"],
                "lp_fee_bps": round(lp_bps, 1),
                "fee_range_bps": f"{int(v['min_lp_fee_bps'])}-{int(v['max_lp_fee_bps'])}",
                "batcher_fee_ada": float(v["batcher_fee_ada"]),
                "round_trip_fixed_ada": rt_fixed_ada,
                "reserve_ada": round(reserve_ada, 1) if reserve_ada else None,
                "spot_ada": round(spot_ada, 6) if spot_ada else None,
                "round_trip_hurdle_pct": rt_hurdle_pct,
                "s1_positive_ev_bounce_pct": s1_pos_ev_bounce_pct,
                "min_viable_250bps_shock_ada": min_viable_250bps_ada,
                "native_builder_status": v["native_builder_status"],
                "notes": v["notes"],
            })

        best_friction = min(venues_out, key=lambda r: r["s1_positive_ev_bounce_pct"])
        live_exec = next((r for r in venues_out if r["native_builder_status"] == "live_plutus_v2"), venues_out[0])
        fee_savings_ada = round(live_exec["round_trip_fixed_ada"] - best_friction["round_trip_fixed_ada"], 2)

        return {
            "status": "ok",
            "ts": int(time.time()),
            "asset": sym,
            "size_ada": round(trade_ada, 2),
            "min_net_profit_ada": min_net_ada,
            "active_execution_venue": live_exec["venue"],
            "lowest_friction_venue": best_friction["venue"],
            "potential_rt_fee_savings_ada": fee_savings_ada,
            "venues": venues_out,
        }
    finally:
        con.close()
        mcon.close()


def main() -> None:
    ap = argparse.ArgumentParser(description="Multi-DEX Venue Fee & Liquidity Comparator")
    ap.add_argument("--asset", default="NIGHT")
    ap.add_argument("--size", type=float, default=0.0)
    args = ap.parse_args()
    res = compare_venues(args.asset, args.size if args.size > 0 else None)
    print(json.dumps(res))


if __name__ == "__main__":
    main()
