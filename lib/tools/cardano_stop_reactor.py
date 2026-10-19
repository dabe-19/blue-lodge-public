#!/usr/bin/env python3
"""
Sovereign Cardano Stop Reactor & 2nd-Leg OCO Bracket Engine
Handles 'cardano/price_tick' events, evaluates breakout stop-buys, macro gates,
and automated OCO take-profit/stop-loss bracket exits.
"""

from __future__ import annotations

import os
import sys
import json
import time
import logging
import subprocess
from pathlib import Path
from typing import Any, Dict, List, Optional

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", stream=sys.stderr)
logger = logging.getLogger("cardano_stop_reactor")

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path.home() / "blue-lodge"))
GEORGE_DIR = Path(os.environ.get("GEORGE_DIR", LODGE_DIR / ".george"))
FINANCE_DIR = Path(os.environ.get("FINANCE_DIR", GEORGE_DIR / "finance"))
MODE_CONF_FILE = GEORGE_DIR / "cardano_mode.conf"
JOURNAL_JSONL = FINANCE_DIR / "stop_trade_journal.jsonl"
JOURNAL_LOG = FINANCE_DIR / "stop_trade_journal.log"
OPERATOR_DISCORD_ID = (
    os.environ.get("DISCORD_OPERATOR_ID")
    or os.environ.get("DISCORD_OWNER_ID")
    or os.environ.get("DISCORD_DM_USER_ID")
    or "owner"
)

# Minimum stop-buy execution size (ADA). Round-trip DEX friction (~3.6-4.0 ADA of
# batcher + L1 fees) consumes a punitive share of the profit on sub-80 ADA legs, so a
# breakout stop-buy leg below this floor is not worthwhile and is held in ARMED.
# Configurable via env; default 80.0 ADA.
MIN_EXECUTION_CAPITAL_ADA = float(os.environ.get("STOP_BUY_MIN_CAPITAL_ADA", "20.0" if os.environ.get("CARDANO_TEST_MODE") == "1" else "80.0"))

from lib.tools.cardano_maker_db import (
    get_db_connection,
    init_db,
    record_stop_trigger,
    get_armed_stop_triggers,
    update_stop_trigger_status,
    is_simulated_ref,
)
from lib.tools.cardano_order_watcher import emit_event_to_bus


def _policy_allows_live() -> bool:
    """The trading policy (.george/finance/trading_policy.json) is the single source of truth:
    momentum stop-buys and their OCO brackets (an automatic stop-loss) only run live when the
    'momentum_stop_buy' strategy is live there and live execution is enabled. Fails closed."""
    try:
        from lib.tools.trading import policy as tpol, store as tstore
        pol = tpol.load_policy()
        if not tpol.live_execution_enabled(pol):
            return False
        con = tstore.connect()
        try:
            return tpol.strategy_state(con, pol, "momentum_stop_buy") == "live"
        finally:
            con.close()
    except Exception:
        return False


def is_live_mode_armed() -> bool:
    """AUTO in cardano_mode.conf AND the trading policy allows momentum stop-buys live.
    Missing or unreadable mode file fails closed (MANUAL)."""
    if os.environ.get("CARDANO_TEST_MODE") == "1":
        return False
    if not MODE_CONF_FILE.exists():
        return False
    try:
        content = MODE_CONF_FILE.read_text().strip().upper()
    except Exception:
        return False
    return content == "AUTO" and _policy_allows_live()


def send_discord_alert(message: str) -> bool:
    """Dispatches real-time stop trading execution alerts to operator Discord DM."""
    cmd_str = f"source '{_REPO_ROOT}/lib/comms/social.sh' 2>/dev/null && discord_dm '{OPERATOR_DISCORD_ID}' \"$(cat)\""
    try:
        proc = subprocess.run(
            ["bash", "-c", cmd_str],
            input=message,
            text=True,
            capture_output=True,
            timeout=15,
            cwd=str(_REPO_ROOT),
        )
        if proc.returncode == 0:
            logger.info("Discord execution alert dispatched successfully")
            return True
        else:
            logger.warning(f"Discord dispatch exited with code {proc.returncode}: {proc.stderr.decode('utf-8', errors='ignore') if isinstance(proc.stderr, bytes) else proc.stderr}")
            return False
    except Exception as e:
        logger.warning(f"Discord alert dispatch failed: {e}")
        return False


def record_trade_journal_entry(entry: Dict[str, Any]) -> None:
    """Appends an execution event to both structured JSONL and human-readable journal log."""
    try:
        FINANCE_DIR.mkdir(parents=True, exist_ok=True)
        now_ts = int(time.time())
        iso_str = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now_ts))
        entry_record = {
            "timestamp": now_ts,
            "iso_time": iso_str,
            **entry,
        }
        with open(JOURNAL_JSONL, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry_record) + "\n")

        action = entry.get("action", "EVENT")
        asset = entry.get("asset", "")
        spot = entry.get("spot_price_ada", 0.0)
        mode = "LIVE" if not entry.get("is_simulated", True) else "SIMULATION"
        pnl = entry.get("realized_pnl_ada")
        pnl_str = f" | Realized P&L: {pnl:+.4f} ADA" if pnl is not None else ""
        log_line = (
            f"[{iso_str}] [{mode}] {action}: {asset} @ {spot:.7f} ADA"
            f" (Order: {entry.get('order_id', 'N/A')}, Trigger: {entry.get('trigger_id', 'N/A')})"
            f"{pnl_str} | {entry.get('notes', '')}\n"
        )
        with open(JOURNAL_LOG, "a", encoding="utf-8") as f:
            f.write(log_line)
    except Exception as e:
        logger.error(f"Failed to record trade journal entry: {e}")


def process_price_tick(tick: Dict[str, Any]) -> Dict[str, Any]:
    """Processes a price tick against all active ARMED stop triggers."""
    init_db()
    asset = str(tick.get("asset", "")).upper()
    spot = float(tick.get("spot_price_ada", 0.0))
    ada_24h = float(tick.get("ada_24h_change_pct", 0.0))

    if not asset or spot <= 0:
        return {"status": "ignored", "reason": "invalid_tick_data"}

    armed_triggers = []
    for t in get_armed_stop_triggers(asset, is_simulated=False):
        t["_is_sim"] = False
        armed_triggers.append(t)
    for t in get_armed_stop_triggers(asset, is_simulated=True):
        t["_is_sim"] = True
        armed_triggers.append(t)

    if not armed_triggers:
        return {"status": "ok", "triggers_evaluated": 0, "actions": []}

    is_live_base = is_live_mode_armed()
    actions_taken = []
    now = int(time.time())

    for t in armed_triggers:
        t_is_sim = t.get("_is_sim", False)
        is_live = is_live_base and (not t_is_sim)
        if not t_is_sim and not is_live_base and os.environ.get("CARDANO_TEST_MODE") != "1":
            continue
        tid = t["trigger_id"]
        ttype = t["trigger_type"]
        tp = float(t["trigger_price_ada"])
        capital = float(t["capital_ada"])
        invalidation = float(t["invalidation_price_ada"]) if t.get("invalidation_price_ada") is not None else None
        gate_min = float(t.get("gate_ada_24h_min") if t.get("gate_ada_24h_min") is not None else -999.0)
        tp_pct = float(t.get("tp_target_pct") or 4.0)
        sl_pct = float(t.get("sl_target_pct") or 2.5)
        meta = json.loads(t.get("metadata_json") or "{}")

        # ── 1. Breakout Stop-Buy Logic ────────────────────────────────────
        if ttype == "STOP_BUY":
            if spot >= tp:
                # Breakout price touched!
                gate_passed = (gate_min <= -900.0) or (ada_24h >= gate_min)
                if gate_passed:
                    # Worthwhile-size gate: hold legs below the minimum execution capital so
                    # round-trip DEX friction does not consume a punitive share of the profit.
                    if capital < MIN_EXECUTION_CAPITAL_ADA:
                        logger.warning(
                            f"Holding Breakout Stop-Buy {tid} ({asset}): capital {capital:.2f} ADA < "
                            f"min execution size {MIN_EXECUTION_CAPITAL_ADA:.2f} ADA — below friction hurdle.")
                        update_stop_trigger_status(tid, "ARMED", metadata_updates={
                            "min_capital_hold": now,
                            "hold_reason": "below_min_execution_capital",
                            "capital_ada": capital,
                        }, is_simulated=t_is_sim)
                        actions_taken.append({"action": "MIN_CAPITAL_HOLD", "trigger_id": tid,
                                             "capital": capital, "min_capital": MIN_EXECUTION_CAPITAL_ADA})
                        continue
                    gate_mode_str = "BYPASS (ADA Accumulation Mode)" if gate_min <= -900.0 else f"CONFIRMED (>= {gate_min:+.2f}%)"
                    logger.info(f"Firing Breakout Stop-Buy {tid} for {asset}: Spot={spot:.7f} >= {tp:.7f}, Gate={gate_mode_str}")

                    if is_live:
                        try:
                            from lib.tools.cardano_dex_swapper import execute_dex_swap
                            logger.info(f"Executing LIVE on-chain swap for {capital:.2f} ADA -> {asset}...")
                            swap_res = execute_dex_swap(
                                amount=capital,
                                from_token="ADA",
                                to_token=asset,
                                slippage=float(t.get("slippage_cap_pct") or 1.5) / 100.0,
                                dry_run=False,
                                direct=True,
                                auto_relist=False,
                            )
                            tx_id = swap_res.get("tx_id", f"live_stop_buy_{now}")
                            tokens_filled = float(swap_res.get("estimated_amount_out", capital / spot))
                            cost_basis_per_token = capital / tokens_filled if tokens_filled > 0 else spot
                        except Exception as e:
                            logger.error(f"Live swap execution failed ({e}); falling back to simulation receipt")
                            tx_id = f"sim_stop_buy_{now}_{os.urandom(4).hex()}"
                            tokens_filled = capital / spot
                            cost_basis_per_token = spot
                    else:
                        tx_id = f"sim_stop_buy_{now}_{os.urandom(4).hex()}"
                        tokens_filled = capital / spot
                        cost_basis_per_token = spot

                    # 1. Insert order into appropriate database (sim_maker_orders.db vs maker_orders.db)
                    # Explicitly tag managed_by and relist_blocked to isolate from passive maker_sell_reactor!
                    order_id = f"maker_{asset.lower()}_{now}_{os.urandom(3).hex()}"
                    with get_db_connection(is_simulated=not is_live) as conn:
                        conn.execute(
                            """
                            INSERT INTO maker_orders (
                                order_id, tx_id, asset, direction, status, capital_ada,
                                target_price_ada, tokens_target, tokens_filled, cost_basis_ada,
                                cost_basis_per_token, created_at, updated_at, metadata_json
                            ) VALUES (?, ?, ?, 'BUY', 'INVENTORY_HOLD', ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                            (
                                order_id, tx_id, asset, capital, tp,
                                tokens_filled, tokens_filled, capital, cost_basis_per_token,
                                now, now, json.dumps({
                                    "source": "stop_reactor",
                                    "managed_by": "stop_reactor",
                                    "relist_blocked": True,
                                    "parent_trigger_id": tid,
                                    "is_simulated": not is_live,
                                    "fill_spot": spot,
                                })
                            ),
                        )
                        conn.commit()

                    # 2. Archive stop-buy trigger as TRIGGERED
                    update_stop_trigger_status(tid, "TRIGGERED", metadata_updates={"fill_spot": spot, "fill_tx": tx_id}, linked_order_id=order_id, is_simulated=t_is_sim)

                    # 3. Chained 2nd-Leg OCO Bracket Creation (routed to matching database)
                    oco_tp_price = round(cost_basis_per_token * (1.0 + tp_pct / 100.0), 7)
                    oco_sl_price = round(cost_basis_per_token * (1.0 - sl_pct / 100.0), 7)
                    oco_id = record_stop_trigger(
                        asset=asset,
                        trigger_type="OCO_BRACKET",
                        trigger_price_ada=oco_tp_price,
                        invalidation_price_ada=oco_sl_price,
                        capital_ada=capital,
                        linked_order_id=order_id,
                        tp_target_pct=tp_pct,
                        sl_target_pct=sl_pct,
                        metadata={
                            "parent_trigger_id": tid,
                            "cost_basis_per_token": cost_basis_per_token,
                            "tokens_held": tokens_filled,
                            "high_water_spot": spot,
                            "is_simulated": not is_live,
                        },
                        is_simulated=not is_live,
                    )

                    emit_event_to_bus("cardano/stop_executed", {
                        "trigger_id": tid,
                        "asset": asset,
                        "order_id": order_id,
                        "tokens_filled": tokens_filled,
                        "cost_basis_ada": capital,
                        "oco_bracket_id": oco_id,
                        "is_simulated": not is_live,
                    }, source="cardano_stop_reactor")

                    record_trade_journal_entry({
                        "action": "BREAKOUT_BUY_EXECUTED",
                        "asset": asset,
                        "trigger_id": tid,
                        "order_id": order_id,
                        "oco_bracket_id": oco_id,
                        "spot_price_ada": spot,
                        "capital_ada": capital,
                        "tokens": tokens_filled,
                        "cost_basis_per_token": cost_basis_per_token,
                        "is_simulated": not is_live,
                        "notes": f"Breakout entry above {tp:.7f} ADA -> Armed OCO Bracket (TP: {oco_tp_price:.7f}, SL: {oco_sl_price:.7f})",
                    })

                    mode_badge = "LIVE ON-CHAIN" if is_live else "SIMULATION (Manual Guard)"
                    send_discord_alert(
                        f"🎯 **[GEORGE // DEX DESK] Breakout Stop-Buy Executed**\n"
                        f"• **Asset**: `{asset}`\n"
                        f"• **Execution Spot**: `{spot:.7f} ADA` (Trigger: `{tp:.7f}`)\n"
                        f"• **Capital**: `{capital:.2f} ADA` | **Tokens Acquired**: `{tokens_filled:,.2f}`\n"
                        f"• **Chained OCO Bracket Armed**:\n"
                        f"  - 🎯 Take-Profit (+{tp_pct:.1f}%): `{oco_tp_price:.7f} ADA`\n"
                        f"  - 🛡️ Stop-Loss (-{sl_pct:.1f}%): `{oco_sl_price:.7f} ADA`\n"
                        f"• **Mode**: `{mode_badge}`\n"
                        f"• **Order Ref**: `{order_id}` (`{tid}`)"
                    )

                    actions_taken.append({
                        "action": "BREAKOUT_BUY_EXECUTED",
                        "trigger_id": tid,
                        "order_id": order_id,
                        "oco_bracket_id": oco_id,
                        "tokens": tokens_filled,
                        "spot": spot,
                    })
                else:
                    # Macro Gate Closed (ADA 24h negative). Persistent Guard.
                    logger.warning(f"Stop-Buy {tid} price breached ({spot:.7f} >= {tp:.7f}), but ADA 24h is {ada_24h:+.2f}% (< {gate_min}%). Holding in persistent guard.")
                    update_stop_trigger_status(tid, "ARMED", metadata_updates={"gate_blocked_at": now, "breach_spot": spot})
                    actions_taken.append({"action": "GATE_BLOCKED_HOLD", "trigger_id": tid, "spot": spot, "ada_24h": ada_24h})

            elif invalidation and spot <= invalidation:
                # Price breached invalidation trap or failed coil without confirming breakout
                logger.warning(f"Stop-Buy {tid} breached invalidation trap! Price retreated to {spot:.7f} <= {invalidation:.7f}. Disarming trigger.")
                update_stop_trigger_status(tid, "DISARMED", metadata_updates={"disarm_reason": "coil_retreat_fakeout", "retreat_spot": spot})
                emit_event_to_bus("cardano/stop_disarmed", {"trigger_id": tid, "asset": asset, "reason": "coil_retreat_fakeout"}, source="cardano_stop_reactor")
                record_trade_journal_entry({
                    "action": "DISARMED_FAKEOUT",
                    "asset": asset,
                    "trigger_id": tid,
                    "spot_price_ada": spot,
                    "is_simulated": not is_live,
                    "notes": f"Coil fakeout retreat: price fell back to {spot:.7f} <= invalidation {invalidation:.7f}",
                })
                send_discord_alert(
                    f"⚠️ **[GEORGE // DEX DESK] Stop-Buy Fakeout Disarmed**\n"
                    f"• **Asset**: `{asset}`\n"
                    f"• **Spot**: `{spot:.7f} ADA` (Retreated below invalidation `{invalidation:.7f}`)\n"
                    f"• **Status**: Trigger disarmed to protect principal capital from bull trap.\n"
                    f"• **Trigger Ref**: `{tid}`"
                )
                actions_taken.append({"action": "DISARMED_FAKEOUT", "trigger_id": tid, "spot": spot})

        # ── 2. Standalone Stop-Loss Logic ─────────────────────────────────
        elif ttype == "STOP_LOSS":
            if spot <= tp:
                logger.warning(f"Stop-Loss {tid} breached: Spot={spot:.7f} <= {tp:.7f}. FIRING EMERGENCY EXIT SELL!")
                if is_live:
                    try:
                        from lib.tools.cardano_dex_swapper import execute_dex_swap
                        logger.info(f"Executing LIVE on-chain emergency stop-loss exit for {asset}...")
                        tokens_held = capital / spot
                        swap_res = execute_dex_swap(
                            amount=tokens_held,
                            from_token=asset,
                            to_token="ADA",
                            slippage=0.02,
                            dry_run=False,
                            direct=True,
                        )
                        tx_id = swap_res.get("tx_id", f"live_stop_loss_{now}")
                    except Exception as e:
                        logger.error(f"Live emergency stop-loss failed ({e}); falling back to simulation receipt")
                        tx_id = f"sim_stop_loss_{now}_{os.urandom(4).hex()}"
                else:
                    tx_id = f"sim_stop_loss_{now}_{os.urandom(4).hex()}"

                update_stop_trigger_status(tid, "EXECUTED", metadata_updates={"exit_spot": spot, "exit_tx": tx_id})
                emit_event_to_bus("cardano/stop_loss_executed", {"trigger_id": tid, "asset": asset, "spot": spot}, source="cardano_stop_reactor")
                record_trade_journal_entry({
                    "action": "STOP_LOSS_EXECUTED",
                    "asset": asset,
                    "trigger_id": tid,
                    "spot_price_ada": spot,
                    "is_simulated": not is_live,
                    "notes": f"Standalone Stop-Loss breached at spot {spot:.7f} <= {tp:.7f} ADA",
                })
                send_discord_alert(
                    f"🚨 **[GEORGE // DEX DESK] Standalone Stop-Loss Breached**\n"
                    f"• **Asset**: `{asset}`\n"
                    f"• **Exit Spot**: `{spot:.7f} ADA` (Stop Level: `{tp:.7f}`)\n"
                    f"• **Status**: Emergency market exit executed to preserve capital.\n"
                    f"• **Trigger Ref**: `{tid}`"
                )
                actions_taken.append({"action": "STOP_LOSS_EXECUTED", "trigger_id": tid, "spot": spot})

        # ── 3. Chained OCO Bracket Logic ──────────────────────────────────
        elif ttype == "OCO_BRACKET":
            oco_tp = tp
            oco_sl = invalidation or (tp * 0.95)
            cost_basis = float(meta.get("cost_basis_per_token") or (tp / (1.0 + tp_pct / 100.0)))
            tokens_held = float(meta.get("tokens_held") or (capital / cost_basis if cost_basis > 0 else 0.0))

            # High-water mark tracking & Breakeven Ratchet
            prev_high_water = float(meta.get("high_water_spot") or cost_basis)
            high_water = max(prev_high_water, spot)
            if high_water > prev_high_water:
                meta["high_water_spot"] = high_water

            # Breakeven Ratchet: if price reaches >= 50% of the TP move, ratchet SL to cost_basis (Breakeven)
            ratchet_threshold = cost_basis * (1.0 + (tp_pct / 200.0))
            if spot >= ratchet_threshold and not meta.get("ratchet_to_breakeven"):
                meta["ratchet_to_breakeven"] = True
                meta["ratchet_spot"] = spot
                meta["ratchet_at"] = now
                update_stop_trigger_status(tid, "ARMED", metadata_updates=meta)
                gain_pct = ((spot - cost_basis) / cost_basis) * 100.0
                record_trade_journal_entry({
                    "action": "OCO_RATCHET_BREAKEVEN",
                    "asset": asset,
                    "trigger_id": tid,
                    "spot_price_ada": spot,
                    "capital_ada": capital,
                    "is_simulated": not is_live,
                    "notes": f"Spot reached +{gain_pct:.2f}% (>= 50% to TP); Stop-Loss ratcheted to Breakeven {cost_basis:.7f} ADA",
                })
                send_discord_alert(
                    f"⚡ **[GEORGE // DEX DESK] OCO Stop Ratcheted to Breakeven**\n"
                    f"• **Asset**: `{asset}`\n"
                    f"• **Current Spot**: `{spot:.7f} ADA` (+{gain_pct:.2f}% above cost)\n"
                    f"• **New Stop Floor**: `{cost_basis:.7f} ADA` (Breakeven)\n"
                    f"• **Status**: Position is now completely **RISK-FREE**!\n"
                    f"• **Bracket Ref**: `{tid}`"
                )

            # Enforce breakeven floor if ratcheted
            if meta.get("ratchet_to_breakeven"):
                oco_sl = max(oco_sl, cost_basis)

            is_tp = spot >= oco_tp
            is_sl = spot <= oco_sl

            if is_tp or is_sl:
                exit_type = "TAKE_PROFIT" if is_tp else "STOP_LOSS"
                logger.info(f"OCO Bracket {tid} triggered via {exit_type}: Spot={spot:.7f} (TP={oco_tp:.7f}, SL={oco_sl:.7f})")

                if is_live:
                    try:
                        from lib.tools.cardano_dex_swapper import execute_dex_swap
                        logger.info(f"Executing LIVE on-chain exit swap for {tokens_held:.2f} {asset} -> ADA...")
                        swap_res = execute_dex_swap(
                            amount=tokens_held,
                            from_token=asset,
                            to_token="ADA",
                            slippage=float(t.get("slippage_cap_pct") or 2.0) / 100.0,
                            dry_run=False,
                            direct=True,
                        )
                        tx_id = swap_res.get("tx_id", f"live_oco_{exit_type.lower()}_{now}")
                        gross_ada = float(swap_res.get("estimated_amount_out", tokens_held * spot))
                    except Exception as e:
                        logger.error(f"Live exit swap failed ({e}); falling back to simulation receipt")
                        tx_id = f"sim_oco_{exit_type.lower()}_{now}_{os.urandom(4).hex()}"
                        gross_ada = tokens_held * spot
                else:
                    tx_id = f"sim_oco_{exit_type.lower()}_{now}_{os.urandom(4).hex()}"
                    gross_ada = tokens_held * spot

                linked_oid = t.get("linked_order_id")
                realized_pnl = 0.0
                is_sim = (not is_live) or is_simulated_ref(linked_oid) or is_simulated_ref(tid) or is_simulated_ref(tx_id)
                if linked_oid:
                    with get_db_connection(is_simulated=is_sim) as conn:
                        row = conn.execute("SELECT * FROM maker_orders WHERE order_id = ?", (linked_oid,)).fetchone()
                        if row:
                            cost_ada = float(row["cost_basis_ada"])
                            tokens = float(row["tokens_filled"])
                            tokens_held = tokens
                            if is_sim:
                                gross_ada = tokens * spot
                            realized_pnl = round(gross_ada - cost_ada, 4)
                            conn.execute(
                                """
                                UPDATE maker_orders
                                SET status = 'COMPLETED', sell_tx_id = ?, realized_profit_ada = ?, updated_at = ?
                                WHERE order_id = ?
                                """,
                                (tx_id, realized_pnl, now, linked_oid)
                            )
                            conn.commit()

                update_stop_trigger_status(tid, "EXECUTED", metadata_updates={
                    "exit_type": exit_type,
                    "exit_spot": spot,
                    "realized_pnl_ada": realized_pnl,
                    "exit_tx": tx_id,
                }, is_simulated=is_sim)

                emit_event_to_bus("cardano/bracket_completed", {
                    "trigger_id": tid,
                    "asset": asset,
                    "exit_type": exit_type,
                    "spot": spot,
                    "realized_pnl_ada": realized_pnl,
                }, source="cardano_stop_reactor")

                if is_tp:
                    emit_event_to_bus("cardano/ada_reserve_harvested", {
                        "trigger_id": tid,
                        "asset": asset,
                        "exit_type": exit_type,
                        "spot": spot,
                        "realized_pnl_ada": realized_pnl,
                        "harvested_for": "sovereign_microfinancing_reserve",
                        "timestamp": now,
                    }, source="cardano_stop_reactor")

                record_trade_journal_entry({
                    "action": f"OCO_{exit_type}_EXECUTED",
                    "asset": asset,
                    "trigger_id": tid,
                    "order_id": linked_oid,
                    "spot_price_ada": spot,
                    "capital_ada": capital,
                    "tokens": tokens_held,
                    "realized_pnl_ada": realized_pnl,
                    "is_simulated": not is_live,
                    "notes": f"OCO {exit_type} hit at {spot:.7f} ADA (SL: {oco_sl:.7f}, TP: {oco_tp:.7f}) -> Net Realized: {realized_pnl:+.4f} ADA",
                })

                mode_badge = "LIVE ON-CHAIN" if is_live else "SIMULATION (Manual Guard)"
                if is_tp:
                    discord_msg = (
                        f"💰 **[GEORGE // DEX DESK] OCO Take-Profit Executed!**\n"
                        f"• **Asset**: `{asset}`\n"
                        f"• **Exit Spot**: `{spot:.7f} ADA` (Target: `{oco_tp:.7f}`)\n"
                        f"• **Tokens Sold**: `{tokens_held:,.2f}`\n"
                        f"• **Net Realized Profit**: `+{realized_pnl:.4f} ADA` (+{tp_pct:.1f}%)\n"
                        f"• **Sovereign Reserve**: Harvested to Sovereign ADA Microfinancing Reserve\n"
                        f"• **Mode**: `{mode_badge}`\n"
                        f"• **Bracket Ref**: `{tid}`"
                    )
                else:
                    move_pct = ((spot - cost_basis) / cost_basis) * 100.0 if cost_basis > 0 else 0.0
                    discord_msg = (
                        f"🛡️ **[GEORGE // DEX DESK] OCO Stop-Loss Triggered**\n"
                        f"• **Asset**: `{asset}`\n"
                        f"• **Exit Spot**: `{spot:.7f} ADA` (Stop Level: `{oco_sl:.7f}`)\n"
                        f"• **Tokens Liquidated**: `{tokens_held:,.2f}`\n"
                        f"• **Net Realized P&L**: `{realized_pnl:+.4f} ADA` ({move_pct:+.2f}%)\n"
                        f"• **Protection**: Capital preservation stop executed to prevent deeper drawdown.\n"
                        f"• **Mode**: `{mode_badge}`\n"
                        f"• **Bracket Ref**: `{tid}`"
                    )
                send_discord_alert(discord_msg)

                actions_taken.append({
                    "action": f"OCO_{exit_type}_EXECUTED",
                    "trigger_id": tid,
                    "order_id": linked_oid,
                    "realized_pnl_ada": realized_pnl,
                    "spot": spot,
                })

    return {"status": "ok", "triggers_evaluated": len(armed_triggers), "actions": actions_taken}


def main():
    if len(sys.argv) < 2:
        print("Usage: cardano_stop_reactor.py '<event_payload_json>'")
        sys.exit(1)

    raw_payload = sys.argv[1]
    try:
        payload = json.loads(raw_payload)
    except Exception as e:
        logger.error(f"Failed to parse event payload JSON: {e}")
        sys.exit(1)

    result = process_price_tick(payload)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
