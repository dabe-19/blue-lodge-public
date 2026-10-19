#!/usr/bin/env python3
"""
Sovereign Cardano Unified Order Manager (UCOM Tier 2 / 3 Adapter)
Unified abstraction layer consolidating:
1. Resting Limit Order Ladders (Passive Maker on Plutus Script UTxOs)
2. Option C Inventory Pre-loading & Blended Cost Basis
3. Breakout Stop-Buys & Trailing Invalidation Traps (Active Taker triggers)
4. Order Lifecycle, Intelligent Pruning, and Cancellation

Fiduciary Floor: Strict 80.00 ADA minimum rung floor for autonomous exit viability.
Reserve Guard: 40.00 ADA Hard Reserve Floor protected at all times.
"""

from __future__ import annotations

import os
import sys
import json
import time
import logging
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", stream=sys.stderr)
logger = logging.getLogger("cardano_order_manager")

from lib.tools.cardano_maker_db import (
    get_db_connection,
    init_db,
    get_unified_orders,
    record_new_order,
    record_stop_trigger,
    update_stop_trigger_status,
    link_accumulated_inventory,
    unlink_inventory,
    auto_link_held_inventory,
    get_active_cycles,
    is_simulated_ref,
)
from lib.tools.cardano_market_maker import (
    TARGET_ASSETS,
    fetch_live_spot_prices,
    fetch_asset_trend_velocity,
    build_resting_limit_order_tx,
    query_wallet_balance,
)
from lib.tools.cardano_stop_engine import HARD_RESERVE_FLOOR_ADA

MIN_LADDER_RUNG_FLOOR_ADA = 80.0


class CardanoOrderManager:
    """Unified Facade managing both resting Plutus limit ladders and active stop triggers."""

    def __init__(self, is_simulated: bool = False):
        self.is_simulated = is_simulated
        init_db(is_simulated=self.is_simulated)

    def list_orders(
        self,
        status: Optional[str] = None,
        asset: Optional[str] = None,
        limit: int = 100,
    ) -> List[Dict[str, Any]]:
        """Queries the unified polymorphic view across all order types."""
        return get_unified_orders(
            status=status,
            asset=asset,
            limit=limit,
            is_simulated=self.is_simulated,
        )

    def plan_ladder(
        self,
        asset: str,
        total_capital_ada: float,
        rungs: int = 2,
        profile: str = "geometric",
        horizon: str = "auto",
        min_floor_ada: float = MIN_LADDER_RUNG_FLOOR_ADA,
    ) -> Dict[str, Any]:
        """Calculates an intelligent multi-rung ladder respecting the 80 ADA minimum floor.
        
        If requested rungs would force individual rungs below min_floor_ada,
        automatically compresses the ladder count to prevent stranded sub-hurdle dust.
        """
        asset = asset.upper()
        if asset not in TARGET_ASSETS:
            raise ValueError(f"Unsupported asset '{asset}'. Valid target assets: {list(TARGET_ASSETS.keys())}")

        # 1. Sizing Compression Gate
        max_possible_rungs = max(1, int(total_capital_ada // min_floor_ada))
        effective_rungs = min(rungs, max_possible_rungs)
        if effective_rungs < rungs:
            logger.warning(
                f"Ladder compressed from {rungs} to {effective_rungs} rungs to enforce "
                f"the {min_floor_ada:.2f} ADA minimum exit viability floor on {total_capital_ada:.2f} ADA capital."
            )

        # 2. Fetch Spot Price & Volatility Profile
        spot_dict = fetch_live_spot_prices(capital_sample_ada=20.0, target_asset=asset)
        spot = spot_dict.get(asset, 0.0)
        if spot <= 0:
            raise RuntimeError(f"Unable to fetch valid live spot price for {asset}")

        trend = fetch_asset_trend_velocity(asset, spot)
        vol_profile = trend.get("volatility_profile", {})
        sigma_pct = vol_profile.get(horizon if horizon != "auto" else "24h", 4.5)

        # 3. Capital Weighting across Rungs
        # Geometric: weights [1.0, 1.4, 2.0] normalized to total_capital_ada
        if profile == "geometric" and effective_rungs > 1:
            raw_weights = [1.0 * (1.35 ** i) for i in range(effective_rungs)]
            sum_w = sum(raw_weights)
            rung_capitals = [round((w / sum_w) * total_capital_ada, 2) for w in raw_weights]
            # Ensure rounding doesn't violate floor on Rung 1
            rung_capitals[0] = max(min_floor_ada, rung_capitals[0])
            diff = sum(rung_capitals) - total_capital_ada
            rung_capitals[-1] = round(rung_capitals[-1] - diff, 2)
        else:
            # Uniform split
            eq_cap = round(total_capital_ada / effective_rungs, 2)
            rung_capitals = [eq_cap] * effective_rungs

        # 4. Price Spacing across Rungs
        # Space rungs downward based on Parkinson volatility
        base_step_pct = max(1.8, sigma_pct * 0.75)
        planned_rungs = []
        ladder_id = f"ladder_{asset.lower()}_{int(time.time())}"

        for i, cap in enumerate(rung_capitals):
            discount_pct = (i + 1) * base_step_pct
            bid_px = spot * (1.0 - (discount_pct / 100.0))
            expected_tokens = cap / bid_px
            # Fixed batcher fee 2.0 ADA + ~0.18 tx fee
            fee_overhead_ada = 2.18
            breakeven_px = (cap + fee_overhead_ada) / (expected_tokens * 0.997)
            profit_ask_px = (cap + fee_overhead_ada + 0.75) / (expected_tokens * 0.997)

            planned_rungs.append({
                "rung_index": i + 1,
                "asset": asset,
                "capital_ada": cap,
                "discount_pct": round(discount_pct, 2),
                "target_price_ada": round(bid_px, 7),
                "expected_tokens": round(expected_tokens, 4),
                "standalone_breakeven_ada": round(breakeven_px, 7),
                "standalone_profit_ask_ada": round(profit_ask_px, 7),
                "fee_drag_pct": round((fee_overhead_ada / cap) * 100.0, 2),
                "onchain_locked_ada": round(cap + 4.0, 4),
            })

        return {
            "status": "ok",
            "ladder_id": ladder_id,
            "asset": asset,
            "spot_price_ada": round(spot, 7),
            "total_capital_ada": total_capital_ada,
            "effective_rungs": effective_rungs,
            "profile": profile,
            "parkinson_sigma_pct": round(sigma_pct, 2),
            "trend_regime": trend.get("regime", "NORMAL"),
            "rungs": planned_rungs,
        }

    def deploy_ladder(
        self,
        asset: str,
        total_capital_ada: float,
        rungs: int = 2,
        profile: str = "geometric",
        dry_run: bool = True,
        execute: bool = False,
    ) -> Dict[str, Any]:
        """Calculates and places the multi-rung resting limit ladder on Cardano DEX.
        
        Enforces 40 ADA reserve floor and auto-links existing held inventory into Rung 1.
        """
        is_dry = dry_run and (not execute)
        bal = query_wallet_balance()
        spendable = float(bal.get("spendable_ada", 0.0))
        total_ada = float(bal.get("total_ada", 0.0))

        # Fiduciary Check for live execution
        if not is_dry:
            required_spendable = total_capital_ada + (rungs * 4.0)  # capital + locked UTxO deposits
            if spendable < required_spendable:
                raise ValueError(
                    f"Insufficient spendable ADA ({spendable:.2f} ADA). "
                    f"Ladder requires {required_spendable:.2f} ADA ({total_capital_ada:.2f}A principal + "
                    f"{rungs * 4.0:.2f}A Plutus UTxO deposits) while safeguarding {HARD_RESERVE_FLOOR_ADA:.2f} ADA reserve floor."
                )

        plan = self.plan_ladder(
            asset=asset,
            total_capital_ada=total_capital_ada,
            rungs=rungs,
            profile=profile,
        )

        placed_rungs = []
        ladder_id = plan["ladder_id"]

        for r in plan["rungs"]:
            # Build Plutus resting limit order
            tx_res = build_resting_limit_order_tx(
                asset=asset,
                capital_ada=r["capital_ada"],
                limit_discount_pct=r["discount_pct"],
                direction="buy",
                target_price=r["target_price_ada"],
                dry_run=is_dry,
                allow_collision=True,
            )

            if tx_res.get("status") != "success":
                if is_dry:
                    tx_res = {
                        "tx_id": f"sim_tx_{os.urandom(8).hex()}",
                        "order_script": "addr1w8p79rpkcdz8x9d6tft0x0dx5mwuzac2sa4gm8cvkw5hcnqst2ctf",
                        "fee_ada": 0.178,
                        "order_utxo": f"sim_tx_{os.urandom(8).hex()}#0",
                    }
                else:
                    raise RuntimeError(f"Failed to build resting limit order for rung {r['rung_index']}: {tx_res}")

            tx_id = tx_res.get("tx_id", f"tx_{os.urandom(8).hex()}")
            order_id = record_new_order(
                asset=asset,
                direction="BUY",
                capital_ada=r["capital_ada"],
                target_price_ada=r["target_price_ada"],
                tokens_target=r["expected_tokens"],
                tx_id=tx_id,
                batcher_fee_ada=2.0,
                l1_fee_ada=float(tx_res.get("fee_ada", 0.178)),
                order_script_addr=tx_res.get("order_script"),
                metadata={
                    "ladder_id": ladder_id,
                    "rung_index": r["rung_index"],
                    "total_rungs": plan["effective_rungs"],
                    "order_utxo": tx_res.get("order_utxo"),
                    "dry_run": is_dry,
                },
                is_simulated=is_dry,
                allow_collision=True,
            )
            placed_rungs.append({**r, "order_id": order_id, "tx_id": tx_id})

        # Option C Integration: Auto-link any existing held inventory into Rung 1!
        link_res = auto_link_held_inventory(asset=asset, is_simulated=is_dry)

        return {
            "status": "success",
            "mode": "DRY_RUN" if is_dry else "LIVE_L1_SETTLEMENT",
            "ladder_id": ladder_id,
            "asset": asset,
            "total_capital_ada": total_capital_ada,
            "rungs_placed": len(placed_rungs),
            "rungs": placed_rungs,
            "inventory_preloaded": link_res,
        }

    def arm_breakout_stop(
        self,
        asset: str,
        breakout_price_ada: float,
        invalidation_price_ada: float,
        capital_ada: float,
        tp_pct: float = 4.0,
        sl_pct: float = 2.5,
        dry_run: bool = True,
        execute: bool = False,
    ) -> Dict[str, Any]:
        """Arms a breakout stop-buy trigger equipped with an active invalidation disarm trap."""
        asset = asset.upper()
        is_dry = dry_run and (not execute)
        
        trigger_id = record_stop_trigger(
            asset=asset,
            trigger_type="STOP_BUY",
            trigger_price_ada=breakout_price_ada,
            invalidation_price_ada=invalidation_price_ada,
            capital_ada=capital_ada,
            tp_target_pct=tp_pct,
            sl_target_pct=sl_pct,
            metadata={
                "armed_by": "cardano_order_manager",
                "dry_run": is_dry,
                "armed_at": int(time.time()),
            },
            is_simulated=is_dry,
        )

        return {
            "status": "armed",
            "mode": "DRY_RUN" if is_dry else "LIVE",
            "trigger_id": trigger_id,
            "asset": asset,
            "trigger_price_ada": breakout_price_ada,
            "invalidation_price_ada": invalidation_price_ada,
            "capital_ada": capital_ada,
            "tp_pct": tp_pct,
            "sl_pct": sl_pct,
        }

    def cancel_order(self, ref_id: str, actor: str = "operator") -> Dict[str, Any]:
        """Universally cancels/reclaims either a resting limit order UTxO or a stop trigger."""
        ref_id = str(ref_id).strip()

        # Check if it's a stop trigger
        with get_db_connection(is_simulated=self.is_simulated) as conn:
            cur = conn.execute("SELECT id, status FROM stop_triggers WHERE trigger_id = ?", (ref_id,))
            stop_row = cur.fetchone()
            if stop_row:
                update_stop_trigger_status(
                    trigger_id=ref_id,
                    new_status="CANCELLED",
                    metadata_updates={"cancelled_by": actor, "cancelled_at": int(time.time())},
                    is_simulated=self.is_simulated,
                )
                return {"status": "cancelled", "kind": "stop_trigger", "ref_id": ref_id}

            # Check if it's a resting limit order in maker_orders
            cur = conn.execute("SELECT * FROM maker_orders WHERE order_id = ? OR tx_id = ? OR sell_tx_id = ?", (ref_id, ref_id, ref_id))
            maker_row = cur.fetchone()
            if maker_row:
                row_dict = dict(maker_row)
                order_id = row_dict["order_id"]
                current_st = row_dict["status"]

                if current_st in ("COMPLETED", "CANCELLED", "CONSOLIDATED"):
                    return {"status": "noop", "message": f"Order {order_id} is already {current_st}"}

                # If order has resting UTxO on chain, invoke reclaim
                order_utxo = (row_dict.get("sell_tx_id") or row_dict.get("tx_id")) if current_st == "PENDING_SELL" else row_dict.get("tx_id")
                meta = json.loads(row_dict.get("metadata_json") or "{}")
                utxo_ref = meta.get("order_utxo") or f"{order_utxo}#0"

                reclaim_res = None
                if not self.is_simulated and current_st in ("PENDING_BUY", "PENDING_SELL"):
                    try:
                        from lib.tools.cardano_orders import reclaim_order
                        logger.info(f"Submitting on-chain reclaim transaction for UTxO {utxo_ref}...")
                        reclaim_res = reclaim_order(utxo_ref, actor=actor, execute=True)
                    except Exception as e:
                        logger.warning(f"On-chain reclaim call failed or order already spent ({e})")

                conn.execute(
                    "UPDATE maker_orders SET status = 'CANCELLED', updated_at = ? WHERE order_id = ?",
                    (int(time.time()), order_id)
                )
                conn.commit()

                # Unlink from any active ladder associations
                unlink_inventory(active_order_id=order_id, is_simulated=self.is_simulated)

                return {
                    "status": "cancelled",
                    "kind": "maker_order",
                    "order_id": order_id,
                    "reclaim_receipt": reclaim_res,
                }

        return {"status": "not_found", "ref_id": ref_id}

    def prune_ladder_lower_rungs(self, ladder_id: str, filled_rung_id: str) -> Dict[str, Any]:
        """Conditionally prunes un-triggered lower rungs once an upper rung's exit path is secured.
        
        Safety Gate: Does NOT prune if the filled position notional is below the 80 ADA hurdle.
        """
        with get_db_connection(is_simulated=self.is_simulated) as conn:
            cur = conn.execute(
                "SELECT * FROM maker_orders WHERE order_id = ?", (filled_rung_id,)
            )
            filled_row = cur.fetchone()
            if not filled_row:
                return {"status": "error", "message": f"Filled rung {filled_rung_id} not found"}

            f_dict = dict(filled_row)
            cap = float(f_dict.get("capital_ada") or 0.0)
            meta = json.loads(f_dict.get("metadata_json") or "{}")
            preloaded = meta.get("preloaded_inventory", {})
            total_notional = cap + float(preloaded.get("cost_basis_ada") or 0.0)

            # Option 3 Safety Gate: Never prune if position is below friction hurdle
            if total_notional < MIN_LADDER_RUNG_FLOOR_ADA:
                return {
                    "status": "held",
                    "reason": f"Filled position notional ({total_notional:.2f} ADA) < {MIN_LADDER_RUNG_FLOOR_ADA:.2f} ADA hurdle. Lower rungs retained.",
                }

            # Query all lower rungs associated with this ladder_id that are still PENDING_BUY
            cur = conn.execute(
                """
                SELECT order_id, tx_id, capital_ada FROM maker_orders
                WHERE status = 'PENDING_BUY'
                  AND order_id != ?
                  AND json_extract(metadata_json, '$.ladder_id') = ?
                """,
                (filled_rung_id, ladder_id)
            )
            lower_rungs = [dict(r) for r in cur.fetchall()]

            pruned = []
            for lr in lower_rungs:
                c_res = self.cancel_order(lr["order_id"], actor="auto_prune")
                pruned.append({"order_id": lr["order_id"], "capital_ada": lr["capital_ada"], "result": c_res})

            return {
                "status": "pruned",
                "ladder_id": ladder_id,
                "reclaimed_rungs_count": len(pruned),
                "pruned": pruned,
            }
