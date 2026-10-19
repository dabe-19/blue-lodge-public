#!/usr/bin/env python3
"""
Sovereign Cardano Stop-Order & Reactive Bracket Engine
Calculates quantitative stop-buy/loss boundaries, validates fee drag floors,
simulates dry-run Minswap Aggregator execution, and manages armed triggers.
"""

from __future__ import annotations

import os
import sys
import json
import time
import math
import argparse
import logging
from pathlib import Path
from typing import Any, Dict, List, Optional
import numpy as np

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", stream=sys.stderr)
logger = logging.getLogger("cardano_stop_engine")

from lib.tools.cardano_trader import query_wallet_balance
from lib.tools.cardano_dex_swapper import estimate_swap_route, TOKEN_METADATA
from lib.tools.cardano_maker_db import (
    get_db_connection,
    init_db,
    record_stop_trigger,
    get_armed_stop_triggers,
    get_all_stop_triggers,
    update_stop_trigger_status,
    delete_stop_trigger,
    prune_stale_stop_triggers,
    cancel_linked_stop_triggers,
)
from lib.tools.quant import market_data as md

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path.home() / "blue-lodge"))
GEORGE_DIR = Path(os.environ.get("GEORGE_DIR", LODGE_DIR / ".george"))
FINANCE_DIR = Path(os.environ.get("FINANCE_DIR", GEORGE_DIR / "finance"))
JOURNAL_JSONL = FINANCE_DIR / "stop_trade_journal.jsonl"

HARD_RESERVE_FLOOR_ADA = 40.0  # Sovereign untouchable ADA reserve floor
FEE_DRAG_FLOOR_PCT = 1.24  # 2x 0.3% pool fee + batcher deposit & network fee floor
MIN_TARGET_EDGE_PCT = 2.0  # Minimum move required to clear friction with profit


def get_active_book_capital(asset: str) -> float:
    """Returns total active capital (in ADA) committed to resting orders for the given asset."""
    init_db()
    with get_db_connection() as conn:
        row = conn.execute(
            """
            SELECT COALESCE(SUM(capital_ada), 0.0) as total_capital
            FROM maker_orders
            WHERE asset = ? AND status IN ('PENDING_BUY', 'INVENTORY_HOLD', 'PENDING_SELL')
            """,
            (asset.upper(),),
        ).fetchone()
        return float(row["total_capital"]) if row else 0.0


def get_armed_stop_capital(asset: Optional[str] = None) -> float:
    """Returns total capital (in ADA) committed to armed stop triggers that haven't executed yet."""
    init_db()
    with get_db_connection() as conn:
        q = "SELECT COALESCE(SUM(capital_ada), 0.0) as total_capital FROM stop_triggers WHERE status = 'ARMED'"
        args = ()
        if asset:
            q += " AND asset = ?"
            args = (asset.upper(),)
        row = conn.execute(q, args).fetchone()
        return float(row["total_capital"]) if row else 0.0


def get_ada_macro_stats() -> Dict[str, Any]:
    """Fetches CoinGecko ADA price in USD and 24h price change percentage."""
    import urllib.request
    url = "https://api.coingecko.com/api/v3/simple/price?ids=cardano&vs_currencies=usd&include_24hr_change=true"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "BlueLodge-StopEngine/2.0", "Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode())
            ada_info = data.get("cardano", {})
            return {
                "status": "ok",
                "price_usd": float(ada_info.get("usd", 0.0)),
                "change_24h_pct": float(ada_info.get("usd_24h_change", 0.0)),
            }
    except Exception as e:
        logger.warning(f"CoinGecko ADA macro fetch error: {e}")
        # Return fallback neutral state with warning
        return {"status": "unavailable", "price_usd": 0.0, "change_24h_pct": 0.0, "error": str(e)}


def calculate_stop_bounds(asset: str) -> Dict[str, Any]:
    """Calculates coil characteristics, fee drag, book headroom, and stop recommendations."""
    asset = asset.upper()
    series = md.load_series(asset, "hour", 1)
    if series.get("status") != "ok":
        return {"status": "error", "message": f"Market data unavailable: {series.get('reason')}"}

    g = series["grid"]
    pool = series["pool"]
    spot = float(pool["price_ada"])
    closes = g["c"]
    highs = g["h"]
    lows = g["l"]

    if len(closes) < 10:
        return {"status": "error", "message": "Insufficient candle history for coil analysis"}

    # Look back over recent 48 hours (or total bars if less)
    lookback = min(48, len(closes))
    recent_closes = closes[-lookback:]
    recent_highs = highs[-lookback:]
    recent_lows = lows[-lookback:]

    coil_high = float(np.max(recent_highs))
    coil_low = float(np.min(recent_lows))
    coil_mid = float((coil_high + coil_low) / 2.0)
    range_span_pct = float(((coil_high - coil_low) / spot) * 100.0)

    # 20-period EMA
    weights = np.exp(np.linspace(-1.0, 0.0, min(20, len(closes))))
    weights /= weights.sum()
    ema_20 = float(np.dot(closes[-len(weights):], weights))

    # Parkinson Volatility / Sigma
    log_hl = [math.log(h / l) ** 2 for h, l in zip(recent_highs, recent_lows) if h > 0 and l > 0 and h >= l]
    sigma_hourly = math.sqrt(sum(log_hl) / (4.0 * math.log(2.0) * len(log_hl))) if log_hl else 0.015

    # Capital Headroom & 40.0 ADA Reserve Floor
    try:
        if os.environ.get("CARDANO_TEST_MODE") == "1":
            total_wallet_ada = 227.3547
        else:
            w_bal = query_wallet_balance()
            total_wallet_ada = float(w_bal.get("total_ada", 0.0))
    except Exception:
        total_wallet_ada = 227.3547  # Fallback to test balance if offline
    reserve_floor_ada = HARD_RESERVE_FLOOR_ADA
    spendable_ada = max(0.0, total_wallet_ada - reserve_floor_ada)
    active_book = get_active_book_capital(asset)
    remaining_headroom = max(0.0, spendable_ada - active_book)
    rec_size = min(50.0, remaining_headroom) if remaining_headroom >= 15.0 else remaining_headroom

    # Macro Gate Check (Default: Bypassed for pure ADA Accumulation)
    ada_macro = get_ada_macro_stats()
    ada_24h_pct = ada_macro.get("change_24h_pct", 0.0)
    # USD gate is bypassed by default in ADA numeraire mode; evaluated if operator specifies explicit threshold
    gate_open = True

    # Stop Levels Formulation
    # Breakout Stop-Buy: 1.5% above the coil high
    breakout_trigger = round(coil_high * 1.015, 7)
    # Invalidation retreat: if break spikes and retreats below 97% of break high or midpoint
    invalidation_retreat = round(min(coil_high * 0.97, coil_mid), 7)
    # Hard Invalidation for accumulation book: below coil low
    hard_stop_loss = round(coil_low * 0.985, 7)

    # OCO Targets for Breakout trade (ADA-Harvesting Exits)
    # Default baseline (+4.0% TP, -2.5% SL)
    tp_target = round(breakout_trigger * 1.040, 7)
    sl_target = round(breakout_trigger * 0.975, 7)

    # Dynamic Volatility & Cardano DEX Batcher Friction Calibration:
    # 1. Volatility-scaled Stop-Loss: 2.0 * sigma_hourly (bounded between 3.0% and 8.0%)
    vol_sl_pct = max(3.0, min(8.0, round(2.0 * sigma_hourly * 100.0, 1)))
    # 2. Risk/Reward ratio >= 2:1 -> Take-Profit scaled proportionally
    vol_tp_pct = max(5.0, round(2.0 * vol_sl_pct, 1))

    # Batcher & Gas Friction Drag analysis for Cardano DEX taker swaps:
    # 2 legs * ~1.8 ADA batcher fee = 3.6 ADA fixed friction
    round_trip_batcher_ada = 3.6
    sizing_for_friction = rec_size if rec_size >= 15.0 else 25.0
    batcher_friction_pct = round((round_trip_batcher_ada / sizing_for_friction) * 100.0, 2)
    min_capital_for_4pct_friction = round(round_trip_batcher_ada / 0.04, 1)  # 90.0 ADA

    return {
        "status": "ok",
        "numeraire": "ADA",
        "objective": "SOVEREIGN_ADA_ACCUMULATION_MICROFINANCING",
        "asset": asset,
        "spot_price_ada": spot,
        "ema_20_ada": round(ema_20, 7),
        "coil_high_ada": coil_high,
        "coil_low_ada": coil_low,
        "coil_mid_ada": round(coil_mid, 7),
        "range_span_pct": round(range_span_pct, 2),
        "sigma_hourly_pct": round(sigma_hourly * 100.0, 2),
        "wallet_total_ada": round(total_wallet_ada, 4),
        "reserve_floor_ada": reserve_floor_ada,
        "spendable_ada": round(spendable_ada, 4),
        "active_book_ada": active_book,
        "remaining_headroom_ada": round(remaining_headroom, 2),
        "recommended_stop_buy_size_ada": round(rec_size, 2),
        "is_book_saturated": remaining_headroom < 10.0,
        "fee_drag_floor_pct": FEE_DRAG_FLOOR_PCT,
        "min_edge_pct": MIN_TARGET_EDGE_PCT,
        "ada_24h_change_pct": round(ada_24h_pct, 2),
        "macro_gate_status": "BYPASSED (ADA Numeraire Mode: Raw ADA Accumulation)",
        "macro_gate_open": gate_open,
        "recommendations": {
            "stop_buy_trigger_ada": breakout_trigger,
            "invalidation_disarm_ada": invalidation_retreat,
            "hard_invalidation_ada": hard_stop_loss,
            "oco_take_profit_ada": tp_target,
            "oco_take_profit_pct": 4.0,
            "oco_stop_loss_ada": sl_target,
            "oco_stop_loss_pct": 2.5,
            # Dynamic volatility & sizing calibration
            "dynamic_volatility_sl_pct": vol_sl_pct,
            "dynamic_volatility_tp_pct": vol_tp_pct,
            "dynamic_oco_take_profit_ada": round(breakout_trigger * (1.0 + vol_tp_pct / 100.0), 7),
            "dynamic_oco_stop_loss_ada": round(breakout_trigger * (1.0 - vol_sl_pct / 100.0), 7),
            "round_trip_batcher_fee_ada": round_trip_batcher_ada,
            "batcher_friction_pct_at_rec_size": batcher_friction_pct,
            "min_recommended_capital_ada": min_capital_for_4pct_friction,
            "breakeven_ratchet_enabled": True,
        },
    }


def arm_stop_trigger(
    asset: str,
    trigger_type: str,
    trigger_price: float,
    capital_ada: float,
    invalidation_price: Optional[float] = None,
    gate_ada_24h_min: float = -999.0,
    slippage_cap_pct: float = 1.5,
    tp_target_pct: Optional[float] = None,
    sl_target_pct: Optional[float] = None,
    force_overallocate: bool = False,
    dry_run: bool = True,
) -> Dict[str, Any]:
    """Validates headroom against 40.0 ADA reserve floor, simulates swap route, and arms trigger in DB."""
    asset = asset.upper()
    trigger_type = trigger_type.upper()
    if trigger_type not in ("STOP_BUY", "STOP_LOSS"):
        return {"status": "error", "message": f"Invalid trigger type: {trigger_type}. Must be STOP_BUY or STOP_LOSS."}

    # Dynamic Volatility Calibration if not explicitly overridden
    if tp_target_pct is None or sl_target_pct is None:
        try:
            b_info = calculate_stop_bounds(asset)
            recs = b_info.get("recommendations", {})
            if tp_target_pct is None:
                tp_target_pct = float(recs.get("dynamic_volatility_tp_pct", 4.0))
            if sl_target_pct is None:
                sl_target_pct = float(recs.get("dynamic_volatility_sl_pct", 2.5))
        except Exception:
            tp_target_pct = tp_target_pct or 4.0
            sl_target_pct = sl_target_pct or 2.5

    # Headroom check for STOP_BUY (strictly protecting 40.0 ADA reserve floor)
    if trigger_type == "STOP_BUY" and not force_overallocate:
        try:
            if os.environ.get("CARDANO_TEST_MODE") == "1":
                total_wallet_ada = 227.3547
            else:
                w_bal = query_wallet_balance()
                total_wallet_ada = float(w_bal.get("total_ada", 0.0))
        except Exception:
            total_wallet_ada = 227.3547
        reserve_floor_ada = HARD_RESERVE_FLOOR_ADA
        spendable_ada = max(0.0, total_wallet_ada - reserve_floor_ada)
        active_book = get_active_book_capital(asset)
        headroom = max(0.0, spendable_ada - active_book)
        if capital_ada > headroom:
            return {
                "status": "error",
                "message": (
                    f"Requested capital ({capital_ada:.2f} ADA) exceeds available headroom "
                    f"({headroom:.2f} ADA) above the {reserve_floor_ada:.1f} ADA reserve floor "
                    f"(Wallet: {total_wallet_ada:.2f} ADA, Spendable: {spendable_ada:.2f} ADA, Active {asset} Book: {active_book:.2f} ADA). "
                    "Use --force-overallocate to override."
                ),
            }

    # Dry-run Minswap Aggregator Route Simulation
    logger.info(f"Simulating swap quote via Minswap Aggregator for {capital_ada} ADA -> {asset}...")
    try:
        amount_in_lovelace = int(capital_ada * 1_000_000)
        slippage_frac = slippage_cap_pct / 100.0
        est, params = estimate_swap_route(amount_in_lovelace, "ADA", asset, slippage_frac)
        raw_out = float(est.get("amount_out", 0))
        dec = TOKEN_METADATA.get(asset, {}).get("decimals", 0)
        est_tokens = raw_out / (10 ** dec)
        est_price = capital_ada / est_tokens if est_tokens > 0 else 0.0
        price_impact = float(est.get("avg_price_impact", 0.0) or 0.0)

        dex_routes = []
        for path in est.get("paths", []):
            for step in path:
                if isinstance(step, dict) and step.get("protocol"):
                    dex_routes.append(step["protocol"])
        if not dex_routes:
            dex_routes = ["MinswapAggregator"]

        dry_run_receipt = {
            "timestamp": int(time.time()),
            "mode": "DRY_RUN" if dry_run else "LIVE_ARMED",
            "asset": asset,
            "input_ada": capital_ada,
            "estimated_tokens_out": round(est_tokens, 2),
            "simulated_execution_price_ada": round(est_price, 7),
            "price_impact_pct": round(price_impact, 2),
            "batcher_fee_ada": 1.80,
            "dex_route": list(set(dex_routes)),
            "slippage_cap_pct": slippage_cap_pct,
        }
    except Exception as e:
        logger.warning(f"Live aggregator simulation error ({e}); using analytical fallback quote")
        # Use on-chain pool spot as analytical fallback if aggregator is unreachable
        series = md.load_series(asset, "hour", 1)
        spot = float(series.get("pool", {}).get("price_ada", 0.0033))
        est_tokens = capital_ada / spot if spot > 0 else 0.0
        dry_run_receipt = {
            "timestamp": int(time.time()),
            "mode": "DRY_RUN" if dry_run else "LIVE_ARMED",
            "asset": asset,
            "input_ada": capital_ada,
            "estimated_tokens_out": round(est_tokens, 2),
            "simulated_execution_price_ada": round(spot, 7),
            "price_impact_pct": 0.05,
            "batcher_fee_ada": 1.80,
            "dex_route": ["MinswapV2"],
            "slippage_cap_pct": slippage_cap_pct,
        }

    # Save to SQLite database as ARMED
    trigger_id = record_stop_trigger(
        asset=asset,
        trigger_type=trigger_type,
        trigger_price_ada=trigger_price,
        capital_ada=capital_ada,
        invalidation_price_ada=invalidation_price,
        gate_ada_24h_min=gate_ada_24h_min,
        slippage_cap_pct=slippage_cap_pct,
        tp_target_pct=tp_target_pct,
        sl_target_pct=sl_target_pct,
        dry_run_sim=dry_run_receipt,
        metadata={"dry_run_only": dry_run, "initial_spot": est_price},
    )

    return {
        "status": "ok",
        "trigger_id": trigger_id,
        "asset": asset,
        "trigger_type": trigger_type,
        "trigger_price_ada": trigger_price,
        "invalidation_price_ada": invalidation_price,
        "capital_ada": capital_ada,
        "simulation_receipt": dry_run_receipt,
    }


def format_stops_table(asset: Optional[str] = None) -> str:
    """Formats active and historical stop triggers as a rich terminal table."""
    triggers = get_all_stop_triggers(asset=asset, limit=30)
    if not triggers:
        return "No stop triggers registered in database."

    # Cache spots for active assets
    unique_assets = list({t["asset"] for t in triggers})
    spots = {}
    for a in unique_assets:
        try:
            s = md.load_series(a, "hour", 1)
            if s.get("status") == "ok":
                spots[a] = float(s["pool"]["price_ada"])
        except Exception:
            pass

    ada_macro = get_ada_macro_stats()
    ada_24h = ada_macro.get("change_24h_pct", 0.0)

    lines = [
        f"=== SOVEREIGN STOP TRIGGERS & REACTIVE BRACKETS (Reserve Floor: {HARD_RESERVE_FLOOR_ADA:.1f} ADA | ADA 24h: {ada_24h:+.2f}%) ===",
        f"{'ID':<26} {'ASSET':<6} {'TYPE':<12} {'TRIGGER (ADA)':<14} {'SPOT (ADA)':<12} {'DIST %':<10} {'SIZE':<8} {'STATUS':<11} {'GATE':<8}",
        "-" * 115,
    ]

    for t in triggers:
        tid = t["trigger_id"]
        a = t["asset"]
        ttype = t["trigger_type"]
        tp = t["trigger_price_ada"]
        cur_spot = spots.get(a, 0.0)
        dist_str = "n/a"
        if cur_spot > 0:
            dist = ((tp - cur_spot) / cur_spot) * 100.0
            dist_str = f"{dist:+.2f}%"

        size_str = f"{t['capital_ada']:.1f}A"
        st = t["status"]

        gate_val = t.get("gate_ada_24h_min")
        if gate_val is None or float(gate_val) <= -900.0:
            gate_str = "BYPASS"
        else:
            gate_str = "OK" if ada_24h >= float(gate_val) else "BLOCKED"

        lines.append(
            f"{tid:<26} {a:<6} {ttype:<12} {tp:<14.7f} {cur_spot:<12.7f} {dist_str:<10} {size_str:<8} {st:<11} {gate_str:<8}"
        )

    return "\n".join(lines)


def get_trade_journal(limit: int = 50) -> List[Dict[str, Any]]:
    """Reads execution records from stop_trade_journal.jsonl."""
    if not JOURNAL_JSONL.exists():
        return []
    records = []
    try:
        with open(JOURNAL_JSONL, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        records.append(json.loads(line))
                    except Exception:
                        pass
        records.sort(key=lambda x: x.get("timestamp", 0), reverse=True)
        return records[:limit]
    except Exception as e:
        logger.warning(f"Error reading trade journal: {e}")
        return []


def format_journal_table(limit: int = 20) -> str:
    """Formats trade journal records into a terminal table."""
    records = get_trade_journal(limit=limit)
    if not records:
        return "No execution records found in stop trade journal (.george/finance/stop_trade_journal.jsonl)."

    header = f"{'TIME (UTC)':<20} {'ACTION':<24} {'ASSET':<6} {'SPOT (ADA)':<12} {'CAPITAL':<10} {'TOKENS':<12} {'REALIZED P&L':<14} {'STATUS':<12}"
    divider = "─" * len(header)
    lines = [
        "━━ Sovereign Cardano Stop-Order Execution Journal ━━",
        header,
        divider,
    ]
    for r in records:
        iso_t = r.get("iso_time", "")[:19].replace("T", " ")
        act = r.get("action", "")
        asset = r.get("asset", "")
        spot = float(r.get("spot_price_ada", 0.0))
        cap = r.get("capital_ada")
        cap_str = f"{float(cap):.1f}A" if cap is not None else "—"
        tok = r.get("tokens")
        tok_str = f"{float(tok):,.1f}" if tok is not None else "—"
        pnl = r.get("realized_pnl_ada")
        if pnl is not None:
            pnl_str = f"{float(pnl):+.4f} ADA"
        else:
            pnl_str = "HOLDING" if act == "BREAKOUT_BUY_EXECUTED" else "—"
        mode_str = "SIMULATION" if r.get("is_simulated", True) else "LIVE"

        lines.append(
            f"{iso_t:<20} {act:<24} {asset:<6} {spot:<12.7f} {cap_str:<10} {tok_str:<12} {pnl_str:<14} {mode_str:<12}"
        )
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Sovereign Cardano Stop-Order & Reactive Bracket Engine")
    subparsers = parser.add_subparsers(dest="cmd")

    # calc
    calc_p = subparsers.add_parser("calc", help="Calculate quantitative stop boundaries and sizing")
    calc_p.add_argument("asset", type=str, help="Token symbol (e.g. SNEK, MIN, IAG)")
    calc_p.add_argument("--json", action="store_true", help="Output pure JSON")

    # arm
    arm_p = subparsers.add_parser("arm", help="Simulate dry-run and arm a stop trigger")
    arm_p.add_argument("asset", type=str, help="Token symbol (e.g. SNEK)")
    arm_p.add_argument("--type", type=str, default="STOP_BUY", choices=["STOP_BUY", "STOP_LOSS"], help="Trigger type")
    arm_p.add_argument("--trigger", type=float, required=True, help="Trigger price in ADA")
    arm_p.add_argument("--amount", type=float, required=True, help="Order capital in ADA")
    arm_p.add_argument("--invalidation", type=float, default=None, help="Invalidation price to disarm trigger")
    arm_p.add_argument("--gate-ada-24h", type=float, default=-999.0, help="Minimum ADA 24h change required to fire (default: -999.0 / bypassed for ADA accumulation)")
    arm_p.add_argument("--slippage", type=float, default=1.5, help="Slippage cap percentage")
    arm_p.add_argument("--tp-pct", type=float, default=None, help="2nd-leg Take-Profit percentage (default: dynamic volatility scaled)")
    arm_p.add_argument("--sl-pct", type=float, default=None, help="2nd-leg Stop-Loss percentage (default: dynamic 2σ volatility scaled)")
    arm_p.add_argument("--force-overallocate", action="store_true", help="Override available headroom above reserve floor")
    arm_p.add_argument("--dry-run", action="store_true", default=False, help="Explicit dry-run mode (default is dry-run unless --execute)")
    arm_p.add_argument("--execute", action="store_true", help="Arm for live execution (default is dry-run mode)")
    arm_p.add_argument("--json", action="store_true", help="Output pure JSON")

    # list
    list_p = subparsers.add_parser("list", help="List registered stop triggers")
    list_p.add_argument("--asset", type=str, default=None, help="Filter by token symbol")
    list_p.add_argument("--json", action="store_true", help="Output pure JSON")

    # cancel
    cancel_p = subparsers.add_parser("cancel", help="Cancel / disarm an active stop trigger (or 'all' for all armed)")
    cancel_p.add_argument("trigger_id", type=str, help="Trigger ID to cancel, or 'all'")
    cancel_p.add_argument("--json", action="store_true", help="Output pure JSON")

    # prune
    prune_p = subparsers.add_parser("prune", help="Prune stale or aborted stop triggers")
    prune_p.add_argument("--max-age", type=int, default=86400, help="Max age in seconds (default: 86400)")
    prune_p.add_argument("--all", action="store_true", help="Cancel all ARMED triggers unconditionally")
    prune_p.add_argument("--json", action="store_true", help="Output pure JSON")

    # journal
    journal_p = subparsers.add_parser("journal", help="Display sovereign stop trade execution journal")
    journal_p.add_argument("--limit", type=int, default=25, help="Number of recent records to display (default: 25)")
    journal_p.add_argument("--json", action="store_true", help="Output pure JSON")

    args = parser.parse_args()

    if args.cmd == "calc":
        res = calculate_stop_bounds(args.asset)
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            if res.get("status") != "ok":
                print(f"Error: {res.get('message')}")
                sys.exit(1)
            recs = res["recommendations"]
            print(f"=== QUANTITATIVE STOP BOUNDARY ANALYSIS: {res['asset']}/ADA ===")
            print(f"  Current Spot:          {res['spot_price_ada']:.7f} ADA")
            print(f"  20-Hour EMA:           {res['ema_20_ada']:.7f} ADA")
            print(f"  Coil Range (48h):      {res['coil_low_ada']:.7f} → {res['coil_high_ada']:.7f} ADA (Span: {res['range_span_pct']}%)")
            print(f"  Coil Midpoint:         {res['coil_mid_ada']:.7f} ADA")
            print(f"  Hourly Volatility:     {res['sigma_hourly_pct']}%")
            print(f"  ADA 24h USD Change:    {res['ada_24h_change_pct']:+.2f}% [BYPASSED: ADA Accumulation Mode]")
            print(f"  Round-Trip Fee Drag:   {res['fee_drag_floor_pct']}% floor (Min edge: {res['min_edge_pct']}%)")
            print(f"  Treasury Reserve:      {res['wallet_total_ada']:.2f} ADA (Floor: {res['reserve_floor_ada']:.1f} ADA, Spendable: {res['spendable_ada']:.2f} ADA)")
            print(f"  Dynamic Book Headroom: {res['remaining_headroom_ada']:.2f} ADA (Active {res['asset']}: {res['active_book_ada']:.2f} ADA)")
            print(f"  Recommended Sizing:    {res['recommended_stop_buy_size_ada']} ADA {'[SATURATED]' if res['is_book_saturated'] else '[VIABLE]'}")
            print("\n=== FORMULATED RECOMMENDATIONS ===")
            print(f"  Breakout Stop-Buy:     {recs['stop_buy_trigger_ada']:.7f} ADA (Above coil high)")
            print(f"  Invalidation Disarm:   {recs['invalidation_disarm_ada']:.7f} ADA (Coil retreat trap threshold)")
            print(f"  Ladder Hard Stop:      {recs['hard_invalidation_ada']:.7f} ADA (Accumulation invalidation)")
            print(f"  OCO Take-Profit (+4%): {recs['oco_take_profit_ada']:.7f} ADA")
            print(f"  OCO Stop-Loss (-2.5%): {recs['oco_stop_loss_ada']:.7f} ADA")

    elif args.cmd == "arm":
        res = arm_stop_trigger(
            asset=args.asset,
            trigger_type=args.type,
            trigger_price=args.trigger,
            capital_ada=args.amount,
            invalidation_price=args.invalidation,
            gate_ada_24h_min=args.gate_ada_24h,
            slippage_cap_pct=args.slippage,
            tp_target_pct=args.tp_pct,
            sl_target_pct=args.sl_pct,
            force_overallocate=args.force_overallocate,
            dry_run=not args.execute,
        )
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            if res.get("status") != "ok":
                print(f"Error: {res.get('message')}")
                sys.exit(1)
            sim = res["simulation_receipt"]
            print(f"✓ Stop Trigger Armed: {res['trigger_id']}")
            print(f"  Asset:              {res['asset']} ({res['trigger_type']})")
            print(f"  Trigger Price:      {res['trigger_price_ada']:.7f} ADA")
            print(f"  Invalidation Level: {res['invalidation_price_ada'] or 'None'}")
            print(f"  Capital:            {res['capital_ada']} ADA")
            print(f"  Mode:               {sim['mode']}")
            print(f"  Simulated Tokens:   {sim['estimated_tokens_out']:,.2f} {res['asset']}")
            print(f"  Price Impact:       {sim['price_impact_pct']:.2f}%")
            print(f"  DEX Route:          {', '.join(sim['dex_route'])}")

    elif args.cmd == "list":
        if args.json:
            triggers = get_all_stop_triggers(asset=args.asset)
            print(json.dumps({"status": "ok", "triggers": triggers}, indent=2))
        else:
            print(format_stops_table(asset=args.asset))

    elif args.cmd == "cancel":
        if args.trigger_id.lower() == "all":
            res = prune_stale_stop_triggers(cancel_all_armed=True)
            if args.json:
                print(json.dumps(res, indent=2))
            else:
                print(f"Cancelled {res['pruned_count']} active stop triggers.")
        else:
            ok = update_stop_trigger_status(args.trigger_id, "CANCELLED")
            if args.json:
                print(json.dumps({"status": "ok" if ok else "error", "cancelled": ok}))
            else:
                print(f"Cancelled stop trigger {args.trigger_id}: {'Success' if ok else 'Not Found'}")

    elif args.cmd == "prune":
        res = prune_stale_stop_triggers(max_age_secs=args.max_age, cancel_all_armed=args.all)
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            print(f"Pruned {res['pruned_count']} stale stop triggers: {', '.join(res['pruned_trigger_ids']) if res['pruned_trigger_ids'] else 'None'}")

    elif args.cmd == "journal":
        if args.json:
            records = get_trade_journal(limit=args.limit)
            print(json.dumps({"status": "ok", "journal": records}, indent=2))
        else:
            print(format_journal_table(limit=args.limit))

    else:
        parser.print_help()


if __name__ == "__main__":
    main()
