#!/usr/bin/env python3
"""
Sovereign Cardano Unified Order Tool (UCOM Tier 2 Command Facade)
CLI interface and unified native facade for:
  - Resting Limit Ladders (with 80.0 ADA floor and Option C inventory preloading)
  - Breakout Stop-Buys & Trailing Invalidation Traps
  - Universal Order Cancellation & On-chain UTxO Reclaims
  - Polymorphic Status Monitoring (v_unified_orders)
  - Dynamic Ladder Pruning & Friction Guards
"""

from __future__ import annotations

import os
import sys
import json
import time
import argparse
import logging
from pathlib import Path
from typing import Any, Dict, List, Optional

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)

logging.basicConfig(level=logging.WARNING, format="%(asctime)s [%(levelname)s] %(message)s", stream=sys.stderr)
logger = logging.getLogger("cardano_order_tool")

from lib.tools.cardano_order_manager import (
    CardanoOrderManager,
    MIN_LADDER_RUNG_FLOOR_ADA,
)
from lib.tools.cardano_stop_engine import HARD_RESERVE_FLOOR_ADA


def format_table(rows: List[List[str]], headers: List[str]) -> str:
    """Formats rows into an aligned ASCII table."""
    col_widths = [len(h) for h in headers]
    for row in rows:
        for i, val in enumerate(row):
            if i < len(col_widths):
                col_widths[i] = max(col_widths[i], len(str(val)))
            else:
                col_widths.append(len(str(val)))

    header_line = "  ".join(f"{h:<{col_widths[i]}}" for i, h in enumerate(headers))
    sep_line = "  ".join("-" * col_widths[i] for i in range(len(headers)))
    data_lines = [
        "  ".join(f"{str(val):<{col_widths[i]}}" for i, val in enumerate(row))
        for row in rows
    ]
    return "\n".join([header_line, sep_line] + data_lines)


def handle_ladder(args: argparse.Namespace) -> int:
    is_dry = not args.execute
    mgr = CardanoOrderManager(is_simulated=is_dry)
    
    if args.plan_only:
        res = mgr.plan_ladder(
            asset=args.asset,
            total_capital_ada=args.capital,
            rungs=args.rungs,
            profile=args.profile,
            min_floor_ada=args.min_floor,
        )
    else:
        res = mgr.deploy_ladder(
            asset=args.asset,
            total_capital_ada=args.capital,
            rungs=args.rungs,
            profile=args.profile,
            dry_run=is_dry,
            execute=args.execute,
        )

    if args.json:
        print(json.dumps(res, indent=2))
        return 0

    mode_str = "SIMULATION (DRY RUN)" if is_dry else "LIVE MAINNET EXECUTION"
    print(f"\n=======================================================")
    print(f" SOVEREIGN CARDANO LADDER: {args.asset.upper()} [{mode_str}]")
    print(f"=======================================================")
    print(f"Total Capital:      {args.capital:.2f} ADA")
    print(f"Minimum Rung Floor: {args.min_floor:.2f} ADA (Autonomous Exit Viability)")
    print(f"Reserve Floor:      {HARD_RESERVE_FLOOR_ADA:.2f} ADA (Safeguarded)")
    if "spot_price_ada" in res:
        print(f"Spot Reference:     {res['spot_price_ada']:.7f} ADA")
    if "trend_regime" in res:
        print(f"Regime / Vol:       {res['trend_regime']} (σ_24h: {res.get('parkinson_sigma_pct', 0.0):.2f}%)")

    rungs = res.get("rungs", [])
    if rungs:
        headers = ["Rung", "Capital (A)", "Limit Price (A)", "Tokens", "Discount%", "Fee Drag%"]
        table_rows = []
        for r in rungs:
            table_rows.append([
                f"#{r['rung_index']}",
                f"{r['capital_ada']:.2f}",
                f"{r['target_price_ada']:.7f}",
                f"{r['expected_tokens']:.1f}",
                f"-{r['discount_pct']:.2f}%",
                f"{r['fee_drag_pct']:.2f}%",
            ])
        print("\n" + format_table(table_rows, headers) + "\n")

    inv = res.get("inventory_preloaded")
    if inv and inv.get("linked_holdings"):
        print("Option C Inventory Preloaded:")
        for h in inv["linked_holdings"]:
            print(f"  • Linked Order {h['inventory_order_id']}: {h['tokens']:.4f} {args.asset.upper()} (Basis: {h['cost_basis_ada']:.2f} ADA)")

    return 0


def handle_stop(args: argparse.Namespace) -> int:
    is_dry = not args.execute
    mgr = CardanoOrderManager(is_simulated=is_dry)

    res = mgr.arm_breakout_stop(
        asset=args.asset,
        breakout_price_ada=args.trigger_price,
        invalidation_price_ada=args.invalidation_price,
        capital_ada=args.capital,
        tp_pct=args.tp,
        sl_pct=args.sl,
        dry_run=is_dry,
        execute=args.execute,
    )

    if args.json:
        print(json.dumps(res, indent=2))
        return 0

    mode_str = "SIMULATION (DRY RUN)" if is_dry else "LIVE MAINNET EXECUTION"
    print(f"\n=======================================================")
    print(f" ARMED BREAKOUT STOP-BUY: {args.asset.upper()} [{mode_str}]")
    print(f"=======================================================")
    print(f"Trigger ID:         {res.get('trigger_id')}")
    print(f"Breakout Trigger:   {res.get('trigger_price_ada', 0.0):.7f} ADA")
    print(f"Invalidation Trap:  {res.get('invalidation_price_ada', 0.0):.7f} ADA (Auto-Disarms Below)")
    print(f"Capital Allocation: {res.get('capital_ada', 0.0):.2f} ADA")
    print(f"Chained Bracket:    TP +{res.get('tp_pct', 0.0):.1f}%  |  SL -{res.get('sl_pct', 0.0):.1f}%")
    print(f"Status:             ARMED\n")
    return 0


def handle_cancel(args: argparse.Namespace) -> int:
    mgr = CardanoOrderManager(is_simulated=args.simulated)
    res = mgr.cancel_order(ref_id=args.ref_id, actor=args.actor)

    if args.json:
        print(json.dumps(res, indent=2))
        return 0

    st = res.get("status", "unknown").upper()
    print(f"\nOrder Cancellation: {args.ref_id} -> {st}")
    if res.get("kind"):
        print(f"Order Kind: {res['kind']}")
    if res.get("reclaim_receipt"):
        print(f"Reclaim Receipt: {res['reclaim_receipt']}")
    if res.get("message"):
        print(f"Notice: {res['message']}")
    print("")
    return 0


def handle_status(args: argparse.Namespace) -> int:
    mgr = CardanoOrderManager(is_simulated=args.simulated)
    orders = mgr.list_orders(
        status=args.status,
        asset=args.asset,
        limit=args.limit,
    )

    if args.json:
        print(json.dumps(orders, indent=2))
        return 0

    env_str = "SIMULATED ORDERS" if args.simulated else "LIVE MAINNET ORDERS"
    print(f"\n=======================================================")
    print(f" SOVEREIGN CARDANO UNIFIED ORDER BOOK [{env_str}]")
    print(f"=======================================================")

    if not orders:
        print("No orders found matching filter criteria.\n")
        return 0

    headers = ["Order / Trigger ID", "Kind", "Asset", "Status", "Capital (A)", "Price (ADA)", "Preloaded Inv"]
    rows = []
    for o in orders:
        meta = json.loads(o.get("metadata_json") or "{}") if isinstance(o.get("metadata_json"), str) else (o.get("metadata_json") or {})
        px = o.get("trigger_price") or o.get("limit_price") or 0.0
        inv_str = "-"
        if meta.get("preloaded_inventory"):
            inv = meta["preloaded_inventory"]
            inv_tokens = inv.get("tokens") or inv.get("preloaded_tokens") or 0.0
            inv_str = f"{inv_tokens:.1f} {o['asset']}"
        rows.append([
            o.get("ref_id", ""),
            o.get("order_kind", ""),
            o.get("asset", ""),
            o.get("status", ""),
            f"{float(o.get('capital_ada') or 0.0):.2f}",
            f"{float(px):.7f}",
            inv_str,
        ])

    print("\n" + format_table(rows, headers) + "\n")
    return 0


def handle_prune(args: argparse.Namespace) -> int:
    mgr = CardanoOrderManager(is_simulated=args.simulated)
    res = mgr.prune_ladder_lower_rungs(
        ladder_id=args.ladder_id,
        filled_rung_id=args.filled_rung_id,
    )

    if args.json:
        print(json.dumps(res, indent=2))
        return 0

    st = res.get("status", "unknown").upper()
    print(f"\nLadder Pruning: {args.ladder_id} -> {st}")
    if res.get("reason"):
        print(f"Protection Reason: {res['reason']}")
    if res.get("reclaimed_rungs_count") is not None:
        print(f"Reclaimed Rungs:   {res['reclaimed_rungs_count']}")
    print("")
    return 0


def handle_triangle(args: argparse.Namespace) -> int:
    from lib.tools.cardano_triangle_deploy import deploy_coverage_triangle, format_console_receipt
    res = deploy_coverage_triangle(
        asset=args.asset,
        total_capital_ada=args.capital,
        tp_pct=args.tp,
        sl_pct=args.sl,
        execute=args.execute,
        force_collision=args.force_collision,
    )
    if args.json:
        print(json.dumps(res, indent=2))
    else:
        if res.get("status") == "error":
            print(f"Error: {res.get('message')}", file=sys.stderr)
            return 1
        print(format_console_receipt(res))
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="Sovereign Cardano Unified Order Manager (UCOM)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    subparsers = parser.add_subparsers(dest="subcommand", help="Available subcommands")

    # 1. LADDER
    p_ladder = subparsers.add_parser("ladder", help="Plan or deploy multi-rung resting limit ladder")
    p_ladder.add_argument("asset", nargs="?", default="SNEK", help="Target asset symbol (e.g. SNEK, NIGHT, MIN, IAG)")
    p_ladder.add_argument("--capital", "-c", type=float, default=160.0, help="Total ADA capital across ladder")
    p_ladder.add_argument("--rungs", "-r", type=int, default=2, help="Number of rungs (auto-compressed if floor violated)")
    p_ladder.add_argument("--profile", "-p", choices=["geometric", "uniform"], default="geometric", help="Capital distribution profile")
    p_ladder.add_argument("--min-floor", type=float, default=MIN_LADDER_RUNG_FLOOR_ADA, help=f"Minimum rung floor in ADA (default {MIN_LADDER_RUNG_FLOOR_ADA})")
    p_ladder.add_argument("--plan-only", action="store_true", help="Calculate ladder geometry without placing orders")
    p_ladder.add_argument("--execute", action="store_true", help="Submit live transactions to Cardano mainnet")
    p_ladder.add_argument("--json", action="store_true", help="Output raw JSON")

    # 2. STOP
    p_stop = subparsers.add_parser("stop", help="Arm breakout stop-buy trigger with invalidation disarm trap")
    p_stop.add_argument("asset", help="Target asset symbol (e.g. SNEK, MIN, IAG)")
    p_stop.add_argument("--trigger-price", "-t", type=float, required=True, help="Breakout resistance trigger price in ADA")
    p_stop.add_argument("--invalidation-price", "-i", type=float, required=True, help="Support invalidation disarm trap price in ADA")
    p_stop.add_argument("--capital", "-c", type=float, default=40.0, help="Capital in ADA allocated to breakout trigger")
    p_stop.add_argument("--tp", type=float, default=4.0, help="Take-profit target percentage for chained OCO")
    p_stop.add_argument("--sl", type=float, default=2.5, help="Stop-loss target percentage for chained OCO")
    p_stop.add_argument("--execute", action="store_true", help="Arm trigger in live mode")
    p_stop.add_argument("--json", action="store_true", help="Output raw JSON")

    # 3. CANCEL
    p_cancel = subparsers.add_parser("cancel", help="Cancel/reclaim resting limit order or stop trigger")
    p_cancel.add_argument("ref_id", help="Order ID, UTxO reference (tx#idx), or Stop Trigger ID")
    p_cancel.add_argument("--actor", default="operator", help="Actor initiating cancellation (default 'operator')")
    p_cancel.add_argument("--simulated", action="store_true", help="Cancel from simulated orders store")
    p_cancel.add_argument("--json", action="store_true", help="Output raw JSON")

    # 4. STATUS
    p_status = subparsers.add_parser("status", help="List unified polymorphic orders across limit & stop engines")
    p_status.add_argument("--asset", "-a", default=None, help="Filter by asset symbol")
    p_status.add_argument("--status", "-s", default=None, help="Filter by status (PENDING_BUY, ARMED, etc.)")
    p_status.add_argument("--limit", "-n", type=int, default=50, help="Max records to retrieve")
    p_status.add_argument("--simulated", action="store_true", help="Query simulated orders store instead of live")
    p_status.add_argument("--json", action="store_true", help="Output raw JSON")

    # 5. PRUNE
    p_prune = subparsers.add_parser("prune", help="Safely prune lower rungs of a filled ladder")
    p_prune.add_argument("--ladder-id", required=True, help="Ladder identifier")
    p_prune.add_argument("--filled-rung-id", required=True, help="Order ID of filled upper rung")
    p_prune.add_argument("--simulated", action="store_true", help="Query simulated orders store")
    p_prune.add_argument("--json", action="store_true", help="Output raw JSON")

    # 6. TRIANGLE (Backward Compatibility)
    p_tri = subparsers.add_parser("triangle", help="Deploy 3-Engine Coverage Triangle (Legacy adapter)")
    p_tri.add_argument("asset", nargs="?", default="SNEK", help="Asset symbol")
    p_tri.add_argument("--capital", type=float, default=120.0, help="Total ADA capital")
    p_tri.add_argument("--tp", type=float, default=None, help="Take-profit %")
    p_tri.add_argument("--sl", type=float, default=None, help="Stop-loss %")
    p_tri.add_argument("--execute", action="store_true", help="Broadcast live on mainnet")
    p_tri.add_argument("--force-collision", action="store_true", help="Override collision guard")
    p_tri.add_argument("--json", action="store_true", help="Output pure JSON")

    args = parser.parse_args()
    if not args.subcommand:
        parser.print_help()
        sys.exit(0)

    handlers = {
        "ladder": handle_ladder,
        "stop": handle_stop,
        "cancel": handle_cancel,
        "status": handle_status,
        "prune": handle_prune,
        "triangle": handle_triangle,
    }

    try:
        sys.exit(handlers[args.subcommand](args))
    except Exception as e:
        logger.error(f"Execution failed: {e}", exc_info=True)
        if getattr(args, "json", False):
            print(json.dumps({"status": "error", "message": str(e)}, indent=2))
        else:
            print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
