#!/usr/bin/env python3
"""
Sovereign Cardano DEX Desk Summary & Position Synthesizer
Generates institutional-grade positioning summaries across Engine B (Resting Plutus Ladders)
and Engine C (Breakout Stop-Buy & OCO Brackets), combined with real-time Batcher Queue
telemetry and on-chain treasury headroom.
"""

from __future__ import annotations

import os
import sys
import json
import sqlite3
from pathlib import Path
from typing import Any, Dict, List, Optional

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from lib.tools.cardano_maker_db import get_db_connection, init_db
from lib.tools.cardano_market_dimensions import pre_trade_clearance
from lib.tools.cardano_stop_engine import query_wallet_balance, HARD_RESERVE_FLOOR_ADA


def get_dex_desk_summary(asset: str = "SNEK") -> Dict[str, Any]:
    """Extracts live chain truth and database state for the asset."""
    init_db()
    asset = asset.upper()

    # 1. Query Resting Limit Orders (Engine B) & Armed Stops (Engine C)
    with get_db_connection() as conn:
        conn.row_factory = sqlite3.Row
        all_order_rows = conn.execute(
            """
            SELECT id, order_id, asset, direction, status, capital_ada, target_price_ada,
                   tokens_target, tokens_filled, sell_target_ada, onchain_locked_ada,
                   breakeven_price_ada, tx_id, sell_tx_id, metadata_json, created_at
            FROM maker_orders
            WHERE status IN ('PENDING_BUY', 'INVENTORY_HOLD', 'PENDING_SELL')
            ORDER BY target_price_ada DESC
            """
        ).fetchall()
        from lib.tools.cardano_maker_db import enrich_cycles
        all_resting_orders = enrich_cycles([dict(r) for r in all_order_rows])
        resting_orders = [o for o in all_resting_orders if o["asset"] == asset]

        all_stop_rows = conn.execute(
            """
            SELECT id, trigger_id, asset, trigger_type, trigger_price_ada, invalidation_price_ada,
                   capital_ada, tp_target_pct, sl_target_pct, slippage_cap_pct, status, created_at
            FROM stop_triggers
            WHERE status = 'ARMED'
            ORDER BY trigger_price_ada DESC
            """
        ).fetchall()
        all_armed_stops = [dict(r) for r in all_stop_rows]
        armed_stops = [s for s in all_armed_stops if s["asset"] == asset]

    # Active assets with open positions
    active_assets = sorted(list({o["asset"] for o in all_resting_orders} | {s["asset"] for s in all_armed_stops}))

    # 3. Market Dimensions & Batcher Queue
    try:
        from lib.tools.cardano_market_dimensions import inspect_batcher_queue, compute_spread_corridor
        batcher_queue = inspect_batcher_queue(asset)
        corridor = compute_spread_corridor(asset)
        spot_ada = float(corridor.get("primary_spot_ada") or 0.0)
    except Exception as e:
        spot_ada = 0.0
        batcher_queue = {"status": "UNKNOWN", "pending_swaps": 0, "estimated_latency_s": 0, "error": str(e)}

    # 4. Wallet & Headroom (Calculated across entire desk portfolio)
    try:
        w_bal = query_wallet_balance()
        wallet_total_ada = float(w_bal.get("total_ada", 0.0))
    except Exception:
        wallet_total_ada = 0.0

    spendable_ada = max(0.0, wallet_total_ada - HARD_RESERVE_FLOOR_ADA)

    # Distinguish BUY orders (locking ADA) vs SELL orders (locking TOKENS, expecting ADA return)
    all_buys = [o for o in all_resting_orders if o.get("status") == "PENDING_BUY"]
    all_sells = [o for o in all_resting_orders if o.get("status") in ("PENDING_SELL", "INVENTORY_HOLD")]

    total_buy_principal_ada = sum(float(o["capital_ada"]) for o in all_buys)
    total_buy_locked_ada = sum(float(o.get("onchain_locked_ada") or (o["capital_ada"] + 4.0)) for o in all_buys)

    total_sell_locked_ada = sum(float(o.get("onchain_locked_ada") or 4.0) for o in all_sells)
    total_sell_tokens_held = sum(float(o.get("tokens_filled") or o.get("tokens_target") or 0.0) for o in all_sells)
    total_sell_expected_ada = sum(float(o.get("sell_target_ada") or (o.get("capital_ada") if o.get("direction") == "SELL" else 0.0) or 0.0) for o in all_sells)

    total_stop_ada = sum(float(s["capital_ada"]) for s in all_armed_stops)
    actual_onchain_locked_ada = total_buy_locked_ada + total_sell_locked_ada
    remaining_spendable_ada = max(0.0, spendable_ada - total_stop_ada)

    return {
        "status": "ok",
        "asset": asset,
        "active_assets": active_assets,
        "spot_price_ada": spot_ada,
        "batcher_queue": batcher_queue,
        "treasury": {
            "wallet_total_ada": round(wallet_total_ada, 4),
            "reserve_floor_ada": HARD_RESERVE_FLOOR_ADA,
            "liquid_spendable_ada": round(spendable_ada, 4),
            "remaining_headroom_ada": round(remaining_spendable_ada, 4),
            "spendable_headroom_ada": round(remaining_spendable_ada, 4),
            "onchain_locked_ada": round(actual_onchain_locked_ada, 2),
            "buy_orders_count": len(all_buys),
            "buy_principal_ada": round(total_buy_principal_ada, 2),
            "buy_locked_ada": round(total_buy_locked_ada, 2),
            "sell_orders_count": len(all_sells),
            "sell_locked_ada": round(total_sell_locked_ada, 2),
            "sell_tokens_held": round(total_sell_tokens_held, 4),
            "sell_expected_ada": round(total_sell_expected_ada, 2),
            "armed_stops_capital_ada": round(total_stop_ada, 2),
            "total_committed_capital_ada": round(total_buy_principal_ada + total_stop_ada, 2),
            "asset_resting_orders": len(resting_orders),
            "asset_armed_stops": len(armed_stops),
        },
        "resting_orders": resting_orders,
        "armed_stops": armed_stops,
        "all_resting_orders": all_resting_orders,
        "all_armed_stops": all_armed_stops,
    }


def format_markdown_report(data: Dict[str, Any]) -> str:
    """Renders a clean Discord/REPL-ready Markdown report."""
    asset = data["asset"]
    spot = data["spot_price_ada"]
    bq = data["batcher_queue"]
    tr = data["treasury"]
    orders = data["resting_orders"]
    stops = data["armed_stops"]

    lines = []
    lines.append(f"**[GEORGE // SOVEREIGN DEX DESK] {asset}/ADA Positioning Report**")
    lines.append(
        f"• **Pool Spot**: `{spot:.7f} ADA` | **Batcher Queue**: `[{bq.get('status', 'NORMAL')}]` "
        f"({bq.get('pending_swaps', 0)} swaps pending, ~{bq.get('estimated_latency_s', 20)}s lag)"
    )
    lines.append(
        f"• **Treasury State**: Wallet `{tr['wallet_total_ada']:.2f} ADA` | "
        f"Floor `{tr['reserve_floor_ada']:.1f} ADA` | "
        f"Spendable Headroom `{tr['remaining_headroom_ada']:.2f} ADA`"
    )
    lines.append(
        f"• **On-Chain Resting**: BUYS: {tr['buy_orders_count']} orders (`{tr['buy_locked_ada']:.1f}A` locked) | "
        f"SELLS: {tr['sell_orders_count']} orders (`{tr['sell_tokens_held']:,.0f}` tokens locked, expecting `+{tr['sell_expected_ada']:.2f}A` on fill)"
    )
    lines.append(
        f"• **Off-Chain Budget Earmarks**: `{tr['armed_stops_capital_ada']:.1f} ADA` reserved for armed breakout stops (0 ADA locked on-chain)"
    )
    lines.append("")

    # Section: Engine C (Breakout Stops)
    lines.append("**[ENGINE C // BREAKOUT STOP-BUY & INVALIDATION TRAPS]**")
    if stops:
        for s in stops:
            tp_ada = s['trigger_price_ada'] * (1.0 + (s.get('tp_target_pct', 4.0) / 100.0))
            sl_ada = s['trigger_price_ada'] * (1.0 - (s.get('sl_target_pct', 2.5) / 100.0))
            lines.append(
                f"  - **[STOP BUY] (`{s['trigger_id'][-6:]}`)**: `{s['trigger_price_ada']:.7f} ADA` (+{s['capital_ada']:.1f} ADA capital)\n"
                f"    • Invalidation Trap: `{s['invalidation_price_ada']:.7f} ADA` (protects against fakeouts)\n"
                f"    • Chained OCO: TP `+{s.get('tp_target_pct', 4.0):.1f}%` ({tp_ada:.7f} ADA) | SL `-{s.get('sl_target_pct', 2.5):.1f}%` ({sl_ada:.7f} ADA)"
            )
    else:
        lines.append("  *(No armed breakout stops active)*")
    lines.append("")

    # Section: Engine B (Resting Limit Ladder)
    lines.append("**[ENGINE B // PLUTUS RESTING LIMIT ORDERS]**")
    if orders:
        for i, o in enumerate(orders, 1):
            is_sell = o.get("status") in ("PENDING_SELL", "INVENTORY_HOLD") or o.get("direction") == "SELL"
            tx_short = (o.get('sell_tx_id') or o.get('tx_id') or "")[:8] + "…" if (o.get('sell_tx_id') or o.get('tx_id')) else "pending"
            be_price = float(o.get('breakeven_price_ada') or o['target_price_ada'])
            if is_sell:
                tokens_held = float(o.get("tokens_filled") or o.get("tokens_target") or 0.0)
                sell_tgt = float(o.get("sell_target_ada") or (o.get("capital_ada") if o.get("direction") == "SELL" else 0.0) or 0.0)
                locked_ada = float(o.get('onchain_locked_ada') or 4.0)
                linked_active = o.get("linked_active_order_id")
                link_str = f" ↳ Pre-loaded into [{linked_active[-6:]}]" if linked_active else ""
                lines.append(
                    f"  - **[TIER {i} SELL] (`{o['order_id'][-6:]}`)**: Target `{o['target_price_ada']:.7f} ADA` | "
                    f"Inventory: `{tokens_held:,.0f} {o['asset']}` (Deposit: `{locked_ada:.1f}A`) · Expecting `+{sell_tgt:.2f}A` · Tx `{tx_short}` [{o['status']}]{link_str}"
                )
            else:
                locked_ada = float(o.get('onchain_locked_ada') or (o['capital_ada'] + 4.0))
                pre_tok = float(o.get("preloaded_tokens") or 0.0)
                comb_tok = float(o.get("combined_projected_tokens") or 0.0)
                comb_ask = float(o.get("combined_projected_ask_ada") or 0.0)
                pre_str = f" (+{pre_tok:,.0f} {o['asset']} pre-loaded ➔ Comb: {comb_tok:,.0f} | Proj Ask: {comb_ask:.6f}A)" if pre_tok > 0 else ""
                lines.append(
                    f"  - **[TIER {i} BUY] (`{o['order_id'][-6:]}`)**: Limit `{o['target_price_ada']:.7f} ADA` "
                    f"(BE: `{be_price:.7f} ADA`) | Principal: `{o['capital_ada']:.1f}A` · Locked: `{locked_ada:.1f}A` · Tx `{tx_short}` [{o['status']}]{pre_str}"
                )
    else:
        lines.append("  *(No resting limit orders active)*")
    lines.append("")

    # Section: Asymmetric Risk Profile
    lines.append("**[COVERAGE TRIANGLE INTEGRITY]**: 100% Non-custodial Plutus smart contracts on MinswapV2/SundaeSwapV3. Realized profits self-revert to liquid ADA for sovereign reserve.")

    return "\n".join(lines)


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Sovereign DEX Desk Summary")
    parser.add_argument("asset", nargs="?", default="SNEK", help="Asset symbol (default: SNEK)")
    parser.add_argument("--json", action="store_true", help="Output pure JSON")
    args = parser.parse_args()

    data = get_dex_desk_summary(args.asset)
    if args.json:
        print(json.dumps(data, indent=2))
    else:
        print(format_markdown_report(data))


if __name__ == "__main__":
    main()
