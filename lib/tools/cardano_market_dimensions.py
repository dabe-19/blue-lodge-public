#!/usr/bin/env python3
"""
Cardano Higher-Dimensional Market Dimensions Engine
Provides George and the DEX Desk with:
  1. Batcher Queue Pressure & Mempool Latency Estimation
  2. Multi-DEX Arbitrage Spread Corridor & Friction Gates
  3. Constant-Product Liquidity Curve (CPMM) & Exact Slippage Matrix
  4. Pre-Trade Execution Clearance Evaluator

Usage:
  python3 lib/tools/cardano_market_dimensions.py --asset IAG --json
  python3 lib/tools/cardano_market_dimensions.py --pre-trade --asset IAG --size 100 --dir buy
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from lib.tools.quant import market_data as md
from lib.tools.quant import models as qm

# Protocol Script Addresses for Minswap V2, SundaeSwap, etc.
MINSWAP_V2_ORDER_SCRIPT = "addr1z8p79rpkcdz8x9d6tft0x0dx5mwuzac2sa4gm8cvkw5hcnzj2c79gy9l76sdg0xwhd7r0c0kna0tycz4y5s6mlenh8pqsfywsm"


def _recorder(asset: str):
    """(fresh pool state or None, batch activity or None) from market.db; never raises."""
    try:
        from lib.tools.quant import market_db as mdb
        con = mdb.connect()
        try:
            return mdb.fresh_pool_state(con, asset), mdb.batch_activity(con, asset)
        finally:
            con.close()
    except Exception:
        return None, None


def inspect_batcher_queue(asset: str) -> Dict[str, Any]:
    """
    Batcher telemetry from the pool-state recorder (market.db).

    Counting order-script UTxOs is not a queue measure (resting limit orders, ours included, sit
    there indefinitely), so this reports what the recorder actually observed for the pool: batches
    and orders filled in the last hour, the age of the last batch and the batcher fee actually
    charged. With no fresh recorder data it reports UNKNOWN; callers must treat UNKNOWN as
    "no information", never as CLEAR.
    """
    state, act = _recorder(asset)
    if not state or not act:
        return {
            "pending_swaps": None, "estimated_blocks_lag": None, "estimated_latency_s": None,
            "status": "UNKNOWN", "recommendation": "PROCEED_WITH_LIMIT_ORDERS",
            "note": "No fresh pool-recorder data for this pool; batch cadence unknown. Resting limit orders are unaffected by short queue delays.",
        }
    status = "FLOWING" if act["batches"] > 0 else "IDLE"
    return {
        "pending_swaps": None,
        "estimated_blocks_lag": None,
        "estimated_latency_s": None,
        "status": status,
        "batches_last_hour": act["batches"],
        "orders_filled_last_hour": act["orders"],
        "last_batch_age_s": act["last_batch_age_s"],
        "measured_batcher_fee_ada": act["measured_batcher_fee_ada"],
        "recommendation": "PROCEED_WITH_LIMIT_ORDERS",
        "note": ("Batches observed on-chain by the pool recorder. IDLE means no trades in the last hour "
                 "(thin pool), not a batcher outage."),
    }


def compute_spread_corridor(asset: str) -> Dict[str, Any]:
    """
    Discovers cross-DEX pricing across Minswap, Sundae, WingRiders, Saturn, Splash
    and computes the friction-adjusted spread corridor.
    """
    series = md.load_series(asset)
    if series.get("status") != "ok":
        return {"status": "error", "message": series.get("reason", "Failed to fetch multi-DEX data")}

    primary_pool = series.get("pool", {})
    spot_price = float(primary_pool.get("price_ada") or 0.0)
    primary_dex = primary_pool.get("dex", "Minswap")
    primary_res_ada = float(primary_pool.get("reserve_ada_est") or 50_000.0)

    from lib.tools.cardano_flash_sniper import compute_cpmm_arb_metrics

    corridor: List[Dict[str, Any]] = []
    max_premium_pct = 0.0
    max_discount_pct = 0.0
    best_arb_pair = None

    for sec in series.get("all_pools", []):
        sec_dex = sec.get("dex")
        vol_24h = float(sec.get("volume_usd_24h") or 0.0)
        reserve_usd = float(sec.get("reserve_usd") or 0.0)
        is_off_market = sec.get("off_market", False)

        # Strictly filter out zombie/abandoned pools (zero volume or off-market price)
        if is_off_market or vol_24h < 50.0 or reserve_usd < 500.0:
            continue

        if sec_dex != primary_dex and sec.get("price_ada"):
            sec_price = float(sec["price_ada"])
            spread_pct = round(((sec_price - spot_price) / spot_price) * 100.0, 2) if spot_price > 0 else 0.0
            
            direction = "PREMIUM" if spread_pct > 0 else "DISCOUNT"
            if spread_pct > max_premium_pct:
                max_premium_pct = spread_pct
            if spread_pct < max_discount_pct:
                max_discount_pct = spread_pct

            buy_p = min(spot_price, sec_price)
            sell_p = max(spot_price, sec_price)
            sec_res_ada = float(sec.get("reserve_ada_est") or (reserve_usd * 2.0))
            m = compute_cpmm_arb_metrics(
                spot_buy_ada=buy_p,
                spot_sell_ada=sell_p,
                buy_lp_fee=0.003,
                sell_lp_fee=0.003,
                buy_reserve_ada=primary_res_ada if spot_price <= sec_price else sec_res_ada,
                sell_reserve_ada=sec_res_ada if spot_price <= sec_price else primary_res_ada,
                fixed_fee_ada=4.36,
            )

            # Calculate gross arb return on a standard 50 ADA trade + optimal CPMM size
            gross_ada = abs(sec_price - spot_price) * (50.0 / buy_p) if buy_p > 0 else 0.0
            net_ada = gross_ada - 4.36

            entry = {
                "dex": sec_dex,
                "price_ada": sec_price,
                "spread_pct": spread_pct,
                "spread_direction": direction,
                "gross_spread_ada_50": round(gross_ada, 4),
                "net_after_friction_ada_50": round(net_ada, 4),
                "min_viable_ada": m["min_viable_ada"],
                "target_viable_ada": m["target_viable_ada"],
                "optimal_ada": m["optimal_ada"],
                "max_net_profit_ada": m["max_net_profit_ada"],
                "req_spread_pct": m["req_spread_pct"],
                "is_executable_arb": (m["max_net_profit_ada"] >= 0.5) or (net_ada > 0.5),
            }
            corridor.append(entry)
            if entry["is_executable_arb"] and (
                best_arb_pair is None or entry["max_net_profit_ada"] > best_arb_pair["max_net_profit_ada"]
            ):
                best_arb_pair = entry

    return {
        "status": "ok",
        "asset": asset,
        "primary_dex": primary_dex,
        "primary_spot_ada": spot_price,
        "corridor": corridor,
        "max_spread_span_pct": round(max_premium_pct - max_discount_pct, 2),
        "arbitrage_executable": best_arb_pair is not None,
        "best_arb": best_arb_pair,
    }


def compute_cpmm_curve(asset: str, trade_sizes: Optional[List[float]] = None) -> Dict[str, Any]:
    """
    Computes Constant-Product Liquidity Curve (CPMM: x * y = k)
    and precise slippage impact across trade sizes.
    """
    if trade_sizes is None:
        trade_sizes = [10.0, 25.0, 50.0, 100.0, 250.0, 500.0, 1000.0]

    series = md.load_series(asset)
    primary_pool = series.get("pool", {}) if series.get("status") == "ok" else {}
    spot = float(primary_pool.get("price_ada") or 0.0)
    reserve_ada = float(primary_pool.get("reserve_ada_est") or 0.0)
    fee = 0.003  # Minswap V2 default pool fee; replaced by the pool's real fee tier when recorded
    source = "geckoterminal_estimate"
    state, _ = _recorder(asset)
    if state and state.get("reserve_ada") and state.get("spot"):
        spot, reserve_ada = float(state["spot"]), float(state["reserve_ada"])
        if state.get("fee_bps") is not None:
            fee = float(state["fee_bps"]) / 10_000.0
        source = "pool_recorder_exact"

    if spot <= 0 or reserve_ada <= 0:
        # No fabricated reserve: without real depth we cannot price impact.
        return {
            "status": "unavailable",
            "asset": asset,
            "reason": series.get("reason") or "pool spot/reserve unavailable",
            "spot_ada": spot or None,
            "pool_reserve_ada": None,
            "pool_reserve_tokens": None,
            "curve": [{"size_ada": s, "tokens_out": None, "effective_price_ada": None,
                       "slippage_pct": None, "acceptable_for_execution": False} for s in trade_sizes],
        }

    reserve_token = reserve_ada / spot
    curve: List[Dict[str, Any]] = []
    for size in trade_sizes:
        # Constant product with input fee: dy = y * dx(1-f) / (x + dx(1-f))
        dx_eff = size * (1.0 - fee)
        tokens_out = (reserve_token * dx_eff) / (reserve_ada + dx_eff)
        effective_price = size / tokens_out if tokens_out > 0 else spot
        slippage_pct = round(((effective_price - spot) / spot) * 100.0, 4)

        curve.append({
            "size_ada": size,
            "tokens_out": round(tokens_out, 4),
            "effective_price_ada": round(effective_price, 6),
            "slippage_pct": slippage_pct,  # includes the pool fee
            "acceptable_for_execution": slippage_pct <= 0.5 + fee * 100.0,
        })

    return {
        "status": "ok",
        "asset": asset,
        "spot_ada": spot,
        "pool_fee_pct": fee * 100.0,
        "reserve_source": source,
        "pool_reserve_ada": round(reserve_ada, 2),
        "pool_reserve_tokens": round(reserve_token, 2),
        "curve": curve,
    }


def pre_trade_clearance(asset: str, trade_size_ada: float, direction: str = "buy") -> Dict[str, Any]:
    """
    Unified Pre-Flight Multi-Dimensional Check for George:
    Evaluates:
      1. Batcher queue pressure
      2. Spread corridor & pricing across all DEXes
      3. Precise slippage on trade size
      4. Clear GO / NO-GO decision with risk factors
    """
    bq = inspect_batcher_queue(asset)
    sc = compute_spread_corridor(asset)
    cpmm = compute_cpmm_curve(asset, [trade_size_ada])

    curve_point = cpmm["curve"][0] if cpmm.get("curve") else {}
    slippage = curve_point.get("slippage_pct")

    reasons: List[str] = []
    hard_fail = False
    caution = False

    if bq.get("status") == "CONGESTED":
        hard_fail = True
        reasons.append(f"Batcher queue congested: {bq.get('pending_swaps')} swaps pending (~{bq.get('estimated_latency_s')}s lag)")

    # Thresholds are price impact on top of the pool's own fee tier (0.3% pools: 1.0% / 0.75% total).
    fee_pct = float(cpmm.get("pool_fee_pct") or 0.3)
    if slippage is None:
        hard_fail = True
        reasons.append(f"Pool depth unavailable ({cpmm.get('reason', 'no reserves')}); price impact cannot be bounded")
    elif slippage > fee_pct + 0.7:
        hard_fail = True
        reasons.append(f"Excessive price impact: {slippage:.2f}% (incl. {fee_pct:.2f}% pool fee) on {trade_size_ada} ADA trade")
    elif slippage > fee_pct + 0.45:
        caution = True
        reasons.append(f"Elevated price impact: {slippage:.2f}% (incl. {fee_pct:.2f}% pool fee) on {trade_size_ada} ADA trade")

    # If buying, check if another DEX has it significantly cheaper
    if direction == "buy" and sc.get("corridor"):
        for alt in sc["corridor"]:
            if alt["spread_pct"] < -2.0 and alt["net_after_friction_ada_50"] > 0:
                caution = True
                reasons.append(f"Suboptimal venue: {alt['dex']} offers {abs(alt['spread_pct'])}% discount")

    verdict = "NO_GO" if hard_fail else ("CAUTION" if caution else "GO")
    return {
        "status": "ok",
        "asset": asset,
        "trade_size_ada": trade_size_ada,
        "direction": direction,
        "clearance": verdict,
        "batcher_queue": bq,
        "slippage_pct": slippage,
        "effective_price_ada": curve_point.get("effective_price_ada"),
        "reasons": reasons if reasons else ["Liquidity adequate; pricing competitive."],
    }


def main():
    parser = argparse.ArgumentParser(description="Cardano Market Dimensions & Pre-Flight Evaluator")
    parser.add_argument("--asset", default="IAG", help="Target Cardano token (IAG, SNEK, MIN, WMTX, DJED)")
    parser.add_argument("--size", type=float, default=50.0, help="Trade size in ADA")
    parser.add_argument("--dir", default="buy", choices=["buy", "sell"], help="Trade direction")
    parser.add_argument("--pre-trade", action="store_true", help="Run unified pre-trade clearance")
    parser.add_argument("--json", action="store_true", help="Output pure JSON")
    args = parser.parse_args()

    if args.pre_trade:
        res = pre_trade_clearance(args.asset, args.size, args.dir)
    else:
        bq = inspect_batcher_queue(args.asset)
        sc = compute_spread_corridor(args.asset)
        cpmm = compute_cpmm_curve(args.asset)
        clearance = pre_trade_clearance(args.asset, args.size, args.dir)
        res = {
            "status": "ok",
            "asset": args.asset,
            "batcher_queue": bq,
            "spread_corridor": sc,
            "cpmm_curve": cpmm,
            "clearance": clearance,
        }

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        print(f"\n━━ Higher-Dimensional Market Dimensions: {args.asset}/ADA ━━")
        bq_ = res.get('batcher_queue') or res.get('clearance', {}).get('batcher_queue', {})
        print(f"Batcher Queue:    {bq_.get('status')} ({bq_.get('note', '')})")
        if "spread_corridor" in res:
            sc = res["spread_corridor"]
            print(f"Primary DEX:      {sc.get('primary_dex')} spot {sc.get('primary_spot_ada')} ADA")
            for c in sc.get("corridor", []):
                print(f"  • {c['dex']:12} {c['price_ada']:.6f} ADA ({c['spread_pct']:+6.2f}% {c['spread_direction']})")
        if "cpmm_curve" in res:
            print("CPMM Slippage Depth:")
            if res["cpmm_curve"].get("status") != "ok":
                print(f"  unavailable: {res['cpmm_curve'].get('reason')}")
            for p in res["cpmm_curve"]["curve"]:
                if p.get("tokens_out") is None:
                    continue
                print(f"  {p['size_ada']:5.0f} ADA -> {p['tokens_out']:8.2f} {args.asset} (Eff: {p['effective_price_ada']:.6f} ₳, Slip: {p['slippage_pct']:+5.3f}% incl. fee)")
        if "clearance" in res:
            c = res["clearance"] if isinstance(res["clearance"], dict) else res
            print(f"Pre-Trade Verdict: {c.get('clearance')} ({c.get('trade_size_ada', 50)} ADA {c.get('direction', 'buy')})")
            for r in c.get("reasons", []):
                print(f"  - {r}")


if __name__ == "__main__":
    main()
