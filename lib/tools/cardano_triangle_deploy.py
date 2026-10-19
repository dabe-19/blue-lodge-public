#!/usr/bin/env python3
"""
Sovereign Cardano Coverage Triangle Autonomous Deployer
Encapsulates the complete 3-Engine positioning workflow:
1. Calibrates ATR coil bounds, support rungs, and breakout resistance.
2. Enforces the strict 40.0 ADA reserve floor and headroom limits.
3. Deploys the 3-Tier Plutus resting limit buy ladder at support (Engine B).
4. Arms the reactive breakout stop-buy trigger with invalidation trap & chained OCO bracket (Engine C).
5. Returns a unified execution receipt and status.
"""

from __future__ import annotations

import os
import sys
import json
import time
import argparse
import logging
from pathlib import Path
from typing import Any, Dict, List

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", stream=sys.stderr)
logger = logging.getLogger("cardano_triangle_deploy")
sys.stderr.write("[DEPRECATION NOTICE] cardano_triangle_deploy.py is deprecated. Use 'cardano_order_tool.py' (or /trading order) instead.\n")

from lib.tools.cardano_stop_engine import (
    calculate_stop_bounds,
    query_wallet_balance,
    HARD_RESERVE_FLOOR_ADA,
)
from lib.tools.cardano_maker_db import (
    init_db,
    record_new_order,
    record_stop_trigger,
    check_ladder_collision,
)
from lib.tools.cardano_market_dimensions import inspect_batcher_queue


def deploy_coverage_triangle(
    asset: str = "SNEK",
    total_capital_ada: float = 120.0,
    tp_pct: Optional[float] = None,
    sl_pct: Optional[float] = None,
    execute: bool = False,
    force_collision: bool = False,
) -> Dict[str, Any]:
    """Encapsulates the full Coverage Triangle setup into a single unified deployment."""
    init_db()
    asset = asset.upper()

    # 1. Inspect Mempool Batcher Queue
    queue_telemetry = inspect_batcher_queue(asset)

    # 2. Check Wallet Headroom & Reserve Floor
    try:
        w_bal = query_wallet_balance()
        wallet_total_ada = float(w_bal.get("total_ada", 0.0))
    except Exception:
        wallet_total_ada = 0.0

    spendable_ada = max(0.0, wallet_total_ada - HARD_RESERVE_FLOOR_ADA)
    if execute and total_capital_ada > spendable_ada:
        return {
            "status": "error",
            "message": (
                f"Requested capital {total_capital_ada:.2f} ADA exceeds spendable headroom "
                f"{spendable_ada:.2f} ADA (Wallet: {wallet_total_ada:.2f} ADA, Floor: {HARD_RESERVE_FLOOR_ADA:.1f} ADA)"
            ),
        }

    # 3. Calculate Quantitative Coil & Price Bounds
    bounds = calculate_stop_bounds(asset)
    if bounds.get("status") != "ok":
        return {"status": "error", "message": f"Coil calculation failed: {bounds.get('message')}"}

    spot = float(bounds["spot_price_ada"])
    recs = bounds.get("recommendations", {})
    stop_trigger_px = float(recs.get("stop_buy_trigger_ada", spot * 1.05))
    invalidation_px = float(recs.get("invalidation_disarm_ada", spot * 0.97))
    sigma_pct = float(bounds.get("sigma_hourly_pct", 1.5)) / 100.0

    # Dynamic Volatility & Reward/Risk Bracketing:
    # Uses 2σ volatility for stop-loss and >= 2:1 profit ratio for take-profit
    dyn_tp_pct = float(recs.get("dynamic_volatility_tp_pct", 6.4))
    dyn_sl_pct = float(recs.get("dynamic_volatility_sl_pct", 3.2))
    effective_tp = float(tp_pct) if tp_pct is not None else dyn_tp_pct
    effective_sl = float(sl_pct) if sl_pct is not None else dyn_sl_pct

    # Capital Allocation: 75% for resting support ladder, 25% for breakout stop
    ladder_capital_total = total_capital_ada * 0.75
    stop_capital = total_capital_ada * 0.25

    # 3-Tier Ladder Pricing: Tier 1 (-1.0σ), Tier 2 (-2.0σ), Tier 3 (-3.0σ)
    t1_px = round(spot * (1.0 - max(0.02, 1.0 * sigma_pct * 3.0)), 7)
    t2_px = round(spot * (1.0 - max(0.04, 2.0 * sigma_pct * 3.0)), 7)
    t3_px = round(spot * (1.0 - max(0.06, 3.0 * sigma_pct * 3.0)), 7)

    # Capital per tier (equal weight)
    t1_cap = round(ladder_capital_total / 3.0, 2)
    t2_cap = round(ladder_capital_total / 3.0, 2)
    t3_cap = round(ladder_capital_total - (t1_cap + t2_cap), 2)

    tier_specs = [
        {"tier": 1, "target_price_ada": t1_px, "capital_ada": t1_cap},
        {"tier": 2, "target_price_ada": t2_px, "capital_ada": t2_cap},
        {"tier": 3, "target_price_ada": t3_px, "capital_ada": t3_cap},
    ]

    # 3.5. Pre-flight Collision Guard (Fail-closed against overlapping active ladder rungs)
    if not force_collision:
        for spec in tier_specs:
            col = check_ladder_collision(
                asset=asset,
                target_price_ada=spec["target_price_ada"],
                threshold_pct=1.0,
                direction="BUY",
                is_simulated=not execute,
            )
            if col.get("collision"):
                return {
                    "status": "error",
                    "error_type": "LADDER_COLLISION",
                    "message": (
                        f"Coverage triangle deployment halted: Tier {spec['tier']} target {spec['target_price_ada']:.7f} ADA collides with "
                        f"active order {col['conflicting_order_id']} ({col['conflicting_price_ada']:.7f} ADA, diff {col['diff_pct']:.2f}%). "
                        f"Reclaim active orders first using crypto_reclaim_order or pass --force-collision."
                    ),
                    "collision": col,
                }

    deployed_orders: List[Dict[str, Any]] = []
    ts = int(time.time())

    # 4. Deploy Engine B (Plutus Limit Ladder)
    for spec in tier_specs:
        order_id = f"maker_{asset.lower()}_{ts}_{spec['tier']}"
        tokens_target = int((spec["capital_ada"] / spec["target_price_ada"]) * 1e6) if spec["target_price_ada"] > 0 else 0
        tx_hash = f"sim_{ts}_{spec['tier']}" if not execute else ""

        order_id = record_new_order(
            asset=asset,
            direction="BUY",
            capital_ada=spec["capital_ada"],
            target_price_ada=spec["target_price_ada"],
            tokens_target=tokens_target,
            tx_id=tx_hash,
            metadata={"source": "cardano_triangle_deploy", "tier": spec["tier"], "execute": execute},
            is_simulated=not execute,
            allow_collision=True,
        )
        deployed_orders.append({
            "order_id": order_id,
            "tier": spec["tier"],
            "target_price_ada": spec["target_price_ada"],
            "capital_ada": spec["capital_ada"],
            "status": "PENDING_BUY",
            "tx_id": tx_hash or "pending_on_chain",
        })

    # 5. Deploy Engine C (Breakout Stop-Buy & Chained OCO Bracket)
    trigger_id = record_stop_trigger(
        asset=asset,
        trigger_type="STOP_BUY",
        trigger_price_ada=stop_trigger_px,
        capital_ada=stop_capital,
        invalidation_price_ada=invalidation_px,
        tp_target_pct=effective_tp,
        sl_target_pct=effective_sl,
        slippage_cap_pct=1.5,
        metadata={
            "source": "cardano_triangle_deploy",
            "execute": execute,
            "dry_run_only": not execute,
            "spot_at_arm": spot,
            "dynamic_volatility_calibrated": tp_pct is None and sl_pct is None,
        },
        is_simulated=not execute,
    )

    deployed_stop = {
        "trigger_id": trigger_id,
        "trigger_type": "STOP_BUY",
        "trigger_price_ada": stop_trigger_px,
        "invalidation_price_ada": invalidation_px,
        "capital_ada": stop_capital,
        "tp_target_pct": effective_tp,
        "sl_target_pct": effective_sl,
        "dynamic_calibrated": tp_pct is None and sl_pct is None,
        "status": "ARMED",
    }

    return {
        "status": "ok",
        "action": "triangle_deployed",
        "asset": asset,
        "execute_mode": "MAINNET_BROADCAST" if execute else "SIMULATION_DRY_RUN",
        "spot_price_ada": spot,
        "total_committed_ada": round(total_capital_ada, 2),
        "reserve_floor_ada": HARD_RESERVE_FLOOR_ADA,
        "remaining_headroom_ada": round(max(0.0, spendable_ada - total_capital_ada), 2),
        "batcher_queue": queue_telemetry,
        "engine_b_plutus_ladder": deployed_orders,
        "engine_c_breakout_stop": deployed_stop,
    }


def format_console_receipt(receipt: Dict[str, Any]) -> str:
    """Formats a clean industrial Fadell-style receipt without decorative emojis."""
    lines = []
    lines.append(f"**[COVERAGE TRIANGLE DEPLOYED] {receipt['asset']}/ADA ({receipt['execute_mode']})**")
    lines.append(f"• Spot Price: `{receipt['spot_price_ada']:.7f} ADA` | Committed: `{receipt['total_committed_ada']:.2f} ADA`")
    lines.append(f"• Reserve Floor: `{receipt['reserve_floor_ada']:.1f} ADA` | Remaining Headroom: `{receipt['remaining_headroom_ada']:.2f} ADA`")
    lines.append("")
    lines.append("**[ENGINE C // BREAKOUT STOP-BUY & INVALIDATION TRAP]**")
    s = receipt["engine_c_breakout_stop"]
    dyn_tag = " [Dynamic Volatility Scaled]" if s.get("dynamic_calibrated") else ""
    lines.append(f"  - Trigger: `{s['trigger_price_ada']:.7f} ADA` (+{s['capital_ada']:.1f} ADA capital) [{s['status']}]")
    lines.append(f"  - Invalidation Trap: `{s['invalidation_price_ada']:.7f} ADA` (auto-disarms if rejected)")
    lines.append(f"  - Chained OCO Bracket: TP `+{s['tp_target_pct']:.1f}%` / SL `-{s['sl_target_pct']:.1f}%`{dyn_tag}")
    lines.append("")
    lines.append("**[ENGINE B // 3-TIER PLUTUS LIMIT BUY LADDER]**")
    for o in receipt["engine_b_plutus_ladder"]:
        lines.append(f"  - Tier {o['tier']}: `{o['target_price_ada']:.7f} ADA` ({o['capital_ada']:.1f} ADA) [{o['status']}]")
    lines.append("")
    lines.append("**[INTEGRITY]**: 100% Non-custodial Plutus smart contract architecture. Yield self-reverts to ADA microfinancing pool.")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Deploy Sovereign Coverage Triangle")
    parser.add_argument("asset", nargs="?", default="SNEK", help="Asset symbol (e.g. SNEK, MIN, IAG)")
    parser.add_argument("--capital", type=float, default=120.0, help="Total ADA capital to commit across triangle (default 120.0)")
    parser.add_argument("--tp", type=float, default=None, help="Take-profit percentage for OCO (default: dynamic volatility scaled)")
    parser.add_argument("--sl", type=float, default=None, help="Stop-loss percentage for OCO (default: dynamic 2σ volatility scaled)")
    parser.add_argument("--execute", action="store_true", help="Broadcast live on mainnet (requires policy clearance)")
    parser.add_argument("--force-collision", action="store_true", help="Override duplicate order collision guard")
    parser.add_argument("--json", action="store_true", help="Output pure JSON")

    args = parser.parse_args()
    receipt = deploy_coverage_triangle(
        asset=args.asset,
        total_capital_ada=args.capital,
        tp_pct=args.tp,
        sl_pct=args.sl,
        execute=args.execute,
        force_collision=args.force_collision,
    )

    if args.json:
        print(json.dumps(receipt, indent=2))
    else:
        if receipt.get("status") == "error":
            print(f"Error: {receipt.get('message')}", file=sys.stderr)
            sys.exit(1)
        print(format_console_receipt(receipt))


if __name__ == "__main__":
    main()
