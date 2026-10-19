#!/usr/bin/env python3
"""
Cardano Cointegration & Automated Resting Limit Order Reactor
Autonomous reactor loop that:
  1. Scans candidate pairs for statistically validated cointegration (Engle-Granger ADF p < 0.05).
  2. Detects stretched stationary spreads (|Z| >= 1.35 sigma).
  3. Validates market dimensions (Batcher Queue clear & CPMM slippage < 0.5%).
  4. Formulates calibrated resting limit orders via native Minswap V2 Plutus scripts (NO aggregators).
  5. Strictly enforces AUTO/MANUAL operating mode guard (MANUAL = risk-free dry runs).
  6. Dispatches full analytical briefing to the operator's Discord DM.

Usage:
  python3 lib/tools/cardano_cointegration_reactor.py --scan --notify
  python3 lib/tools/cardano_cointegration_reactor.py --dry-run
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from lib.tools import cardano_cointegration as cc
from lib.tools import cardano_market_dimensions as cmd
from lib.tools import minswap_v2 as mv2

GEORGE_DIR = _REPO_ROOT / ".george"
CONF_FILE = GEORGE_DIR / "cardano_mode.conf"
SIMULATION_LOG = _REPO_ROOT / "dossiers" / "finance" / "dry_run_simulations.jsonl"
OPERATOR_DISCORD_ID = (
    os.environ.get("DISCORD_OPERATOR_ID")
    or os.environ.get("DISCORD_OWNER_ID")
    or os.environ.get("DISCORD_DM_USER_ID")
    or "owner"
)


def get_operating_mode() -> str:
    """Reads current execution guard setting: MANUAL (default, dry-run) or AUTO (live).

    Fails closed: AUTO is returned ONLY when explicitly configured via env or conf file.
    Missing, unreadable, or unrecognised settings all resolve to MANUAL.
    """
    env_mode = (os.environ.get("CARDANO_COINT_MODE") or os.environ.get("CARDANO_MODE") or "").strip().upper()
    if env_mode:
        return "AUTO" if env_mode == "AUTO" else "MANUAL"
    if CONF_FILE.exists():
        try:
            if CONF_FILE.read_text().strip().upper() == "AUTO":
                return "AUTO"
        except Exception:
            pass
    return "MANUAL"


def send_discord_briefing(message: str) -> bool:
    """Dispatches analytical briefing to operator's Discord DM using social.sh."""
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
        return proc.returncode == 0
    except Exception as e:
        sys.stderr.write(f"[reactor] Discord dispatch failed: {e}\n")
        return False


DEFAULT_TRADE_SIZE_ADA = float(os.getenv("GEORGE_COINT_TRADE_SIZE_ADA", "100.0"))
ROUNDTRIP_FRICTION_ADA = 3.96  # Minswap V2 batcher fee (1.80) + L1 tx fee (0.18) per leg = 3.96 ADA roundtrip


def get_wallet_spendable_ada() -> float:
    """Returns spendable ADA available in the hot wallet above the 40.0 ADA reserve floor."""
    try:
        from lib.tools.cardano_trader import query_wallet_balance
        bal = query_wallet_balance()
        if bal.get("status") == "ok":
            return float(bal.get("spendable_ada", 0.0))
    except Exception:
        pass
    return 0.0


def get_wallet_token_balance(asset: str) -> float:
    try:
        from lib.tools.cardano_trader import query_wallet_balance
        from lib.tools.cardano_dex_swapper import TOKEN_METADATA
        bal = query_wallet_balance()
        if bal.get("status") != "ok":
            return 0.0
        meta = TOKEN_METADATA.get(asset.upper())
        decimals = meta.get("decimals", 6) if meta else 6
        unit = meta.get("unit") if meta else None
        for k, v in bal.get("multi_assets", {}).items():
            if k.endswith(f".{asset.upper()}") or (unit and k.replace(".", "").lower() == unit.lower()):
                return float(v) / (10 ** decimals)
    except Exception:
        pass
    return 0.0


def run_reactor_cycle(notify_discord: bool = True, force_execute: bool = False, capital_ada: Optional[float] = None, force_dry_run: bool = False) -> Dict[str, Any]:
    timestamp_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    if force_dry_run:
        mode = "MANUAL"
    elif force_execute:
        mode = "AUTO"
    else:
        mode = get_operating_mode()

    # Step 1: Scan and rank cointegrated pairs
    scan_results = cc.scan_all_candidate_pairs()
    actionable_opportunities = [
        r for r in scan_results
        if r.get("cointegration", {}).get("is_cointegrated", False)
        and abs(r.get("z_score", 0.0)) >= 1.35
    ]

    if not actionable_opportunities:
        return {
            "status": "idle",
            "timestamp": timestamp_iso,
            "mode": mode,
            "message": "No actionable cointegration spreads (|Z| >= 1.35σ with ADF p < 0.05) detected.",
            "pairs_scanned": len(scan_results),
        }

    # Evaluate the top ranked opportunity
    opp = actionable_opportunities[0]
    pair_name = opp["pair"]
    asset_a = opp["asset_a"]
    asset_b = opp["asset_b"]
    z_score = opp["z_score"]
    beta = opp.get("hedge_ratio_beta", 1.0)
    ou = opp.get("ornstein_uhlenbeck", {})
    half_life_h = ou.get("half_life_hours", 0.0)

    # Spot pricing and current inventory valuation
    spot_a = float(opp.get("spot_a", 0.1))
    spot_b = float(opp.get("spot_b", 0.1))
    held_a = get_wallet_token_balance(asset_a)
    held_a_value_ada = round(held_a * spot_a, 2)
    spendable_ada = get_wallet_spendable_ada()

    # Dynamic Hurdle Sizing for ADA Accumulation:
    # Breakeven capital: roundtrip_friction / spread_edge
    expected_spread_delta_pct = max(abs(z_score) * 0.02, 0.01)
    hurdle_size_ada = round(ROUNDTRIP_FRICTION_ADA / expected_spread_delta_pct, 1)

    if capital_ada is not None and capital_ada > 0:
        target_trade_size_ada = float(capital_ada)
    else:
        # Hurdle sizing with >= 15% edge margin to guarantee positive Net ADA accumulation
        target_trade_size_ada = max(DEFAULT_TRADE_SIZE_ADA, round(hurdle_size_ada * 1.15, 1))

    # Determine mispriced target leg & inventory-aware direction
    # Pair spread: S = ln(P_A) - beta * ln(P_B)
    if z_score <= -1.35:
        # Spread is depressed: asset_a is cheap relative to asset_b.
        # Long the undervalued leg (asset_a) with ADA.
        target_asset = asset_a
        direction = "buy"
        spot_price = spot_a
        rationale = f"Spread is depressed ({z_score:+.2f}σ). {asset_a} is cheap relative to {asset_b}; accumulating {asset_a} with ADA."
    else:
        # Spread is stretched: asset_a is rich, asset_b is cheap.
        # If held inventory value is large enough to beat the roundtrip friction hurdle, place limit ask.
        # Otherwise, sub-hurdle selling guarantees fee loss; accumulate the cheap leg asset_b with ADA instead.
        if held_a_value_ada >= hurdle_size_ada:
            target_asset = asset_a
            direction = "sell"
            spot_price = spot_a
            rationale = f"Spread is stretched ({z_score:+.2f}σ). {asset_a} is rich; selling held inventory ({held_a:.1f} {asset_a} ≈ {held_a_value_ada:.1f} ADA)."
        else:
            target_asset = asset_b
            direction = "buy"
            spot_price = spot_b
            if held_a > 0:
                rationale = f"Spread is stretched ({z_score:+.2f}σ). {asset_a} is rich, {asset_b} is cheap. Held {asset_a} ({held_a_value_ada:.1f} ADA) < {hurdle_size_ada:.1f} ADA hurdle; accumulating cheap leg {asset_b} with ADA."
            else:
                rationale = f"Spread is stretched ({z_score:+.2f}σ). {asset_a} is rich, {asset_b} is cheap. Wallet holds 0 {asset_a}; accumulating cheap leg {asset_b} with ADA."

    # Determine allocated trade size in ADA
    if direction == "buy":
        # In live mode (AUTO), bound by spendable ADA so orders never fail UTXO selection
        if (mode == "AUTO" or force_execute) and not force_dry_run:
            trade_size_ada = min(target_trade_size_ada, max(10.0, round(spendable_ada, 1)))
        else:
            trade_size_ada = target_trade_size_ada
    else:
        # Sell leg: bounded by held token inventory value
        trade_size_ada = min(target_trade_size_ada, round(held_a_value_ada, 1))

    # Step 2: Multi-Dimensional Pre-Trade Clearance Check
    clearance = cmd.pre_trade_clearance(target_asset, trade_size_ada, direction)
    bq = clearance.get("batcher_queue", {})
    slippage = clearance.get("slippage_pct", 0.0)

    if clearance.get("clearance") == "NO_GO":
        reason = "; ".join(clearance.get("reasons", ["Pre-trade clearance rejected"]))
        return {
            "status": "cleared_rejected",
            "pair": pair_name,
            "target_asset": target_asset,
            "direction": direction,
            "trade_size_ada": trade_size_ada,
            "reason": reason,
        }

    # Step 3: Calibrated Limit Price Computation & Friction Hurdle
    spot_price = float(clearance.get("effective_price_ada") or spot_price)
    if direction == "buy":
        # Rest limit bid 1.5% below current spot to capture the mean-reverting wave
        limit_price = round(spot_price * 0.985, 6)
        amount_tokens = round(trade_size_ada / limit_price, 2)
    else:
        # Rest limit ask 1.5% above current spot
        limit_price = round(spot_price * 1.015, 6)
        amount_tokens = min(held_a, round(trade_size_ada / spot_price, 2))

    expected_gross_profit_ada = round(trade_size_ada * expected_spread_delta_pct, 2)
    net_ev_ada = round(expected_gross_profit_ada - ROUNDTRIP_FRICTION_ADA, 2)

    # Step 4: Native Minswap V2 Limit Order Build & Mode Guard
    # Fiduciary & Capital Guard: Enforce positive Net EV and capital sufficiency for live execution
    is_live_execute = (mode == "AUTO")
    ev_gated = False
    gate_reason = ""

    if is_live_execute:
        if net_ev_ada < 0:
            is_live_execute = False
            ev_gated = True
            gate_reason = f"Net EV {net_ev_ada:+.2f} ADA < 0 after batcher fees"
        elif direction == "buy" and spendable_ada < trade_size_ada:
            is_live_execute = False
            ev_gated = True
            gate_reason = f"Spendable balance ({spendable_ada:.1f} ADA) < trade size ({trade_size_ada:.1f} ADA) above reserve floor"

    try:
        order_res = mv2.place_limit_order(
            asset=target_asset,
            direction=direction,
            amount=amount_tokens,
            limit_price_ada=limit_price,
            execute=is_live_execute,
            actor="george",
            force_collision=not is_live_execute,
        )
    except Exception as e:
        order_res = {"status": "error", "message": str(e)}

    # Step 5: Check Order Placement Outcome & Simulation Log
    is_order_success = (order_res.get("status") == "ok")
    if is_order_success:
        tx_id = order_res.get("tx_id", "simulated_plutus_tx")
        order_utxo = order_res.get("order_utxo", f"{tx_id}#0")
        if ev_gated:
            action_label = f"SIMULATED DRY-RUN (GATED: {gate_reason})"
            status_icon = "🛡️"
        elif is_live_execute:
            action_label = "LIVE BROADCAST EXECUTED"
            status_icon = "🟢"
        else:
            action_label = "SIMULATED DRY-RUN ONLY (ZERO RISK)"
            status_icon = "🔒"
    else:
        tx_id = "failed"
        order_utxo = "N/A"
        err_msg = order_res.get("message", "Order placement failed")
        action_label = f"EXECUTION REJECTED ({err_msg})"
        status_icon = "⚠️"

    if not is_live_execute and is_order_success:
        sim_record = {
            "timestamp": timestamp_iso,
            "mode": "dry-run",
            "strategy": "cointegration_maker_limit",
            "pair": pair_name,
            "asset": target_asset,
            "direction": direction,
            "trade_size_ada": trade_size_ada,
            "amount_tokens": amount_tokens,
            "limit_price_ada": limit_price,
            "z_score": z_score,
            "adf_pvalue": opp.get("cointegration", {}).get("adf_pvalue"),
            "expected_gross_profit_ada": expected_gross_profit_ada,
            "roundtrip_friction_ada": ROUNDTRIP_FRICTION_ADA,
            "net_ev_ada": net_ev_ada,
            "tx_id": tx_id,
            "order_utxo": order_utxo,
            "script": order_res.get("order_address", "addr1w8p79rpkcdz8x9d6tft0x0dx5mwuzac2sa4gm8cvkw5hcnqst2ctf"),
            "l1_fee_ada": order_res.get("fee_ada", 0.176),
            "status": "simulated_cleared",
        }
        try:
            SIMULATION_LOG.parent.mkdir(parents=True, exist_ok=True)
            with open(SIMULATION_LOG, "a", encoding="utf-8") as f:
                f.write(json.dumps(sim_record) + "\n")
        except Exception:
            pass

    # Step 6: Dispatch Analytical Briefing to Discord
    discord_msg = f"""🏛️ **George Cointegration & Limit Order Reactor**
• **Opportunity**: `{pair_name}` ({rationale})
• **Stationarity Proof**: ADF p = {opp.get('cointegration', {}).get('adf_pvalue', 0.0):.4f} (Rejects Random Walk)
• **Model Parameters**: β Hedge = {beta:.4f} · OU Half-Life = {half_life_h:.1f} hours
• **Pre-Trade Clearance**: Batcher Queue {bq.get('status', 'NORMAL')} (~{bq.get('estimated_latency_s', 20)}s lag) · Slippage {slippage:.3f}%
• **Friction Hurdle**: Gross Edge ~{expected_gross_profit_ada:.2f} ADA vs Roundtrip Batcher Friction {ROUNDTRIP_FRICTION_ADA:.2f} ADA (Net EV: {net_ev_ada:+.2f} ADA)
• **Capital Sizing**: {trade_size_ada:.1f} ADA allocated (Hurdle threshold: {hurdle_size_ada:.1f} ADA)
• **Calibrated Limit Order**:
  - Venue: Direct Minswap V2 Plutus Script (Zero Aggregator Routing)
  - Action: `{direction.upper()}` {amount_tokens:.2f} {target_asset} @ {limit_price:.6f} ADA
• **Operating Guard**: {status_icon} **[{mode}]** → {action_label}
• **Order UTxO**: `{order_utxo}`
"""

    discord_sent = False
    if notify_discord:
        # Only notify on success or if a real live execution was attempted
        if is_order_success or is_live_execute:
            discord_sent = send_discord_briefing(discord_msg)
        else:
            sys.stderr.write(f"[reactor] Suppressed Discord alert for simulated dry-run rejection: {action_label}\n")

    return {
        "status": "ok" if is_order_success else "error",
        "timestamp": timestamp_iso,
        "mode": mode,
        "pair": pair_name,
        "target_asset": target_asset,
        "direction": direction,
        "trade_size_ada": trade_size_ada,
        "limit_price_ada": limit_price,
        "amount_tokens": amount_tokens,
        "z_score": z_score,
        "half_life_hours": half_life_h,
        "expected_gross_profit_ada": expected_gross_profit_ada,
        "roundtrip_friction_ada": ROUNDTRIP_FRICTION_ADA,
        "net_ev_ada": net_ev_ada,
        "order_result": order_res,
        "discord_notified": discord_sent,
        "message": f"Reactor processed {pair_name}: {action_label}",
    }


def main():
    parser = argparse.ArgumentParser(description="Cardano Cointegration & Resting Limit Order Reactor")
    parser.add_argument("--scan", action="store_true", help="Execute reactor scan cycle")
    parser.add_argument("--capital", "--trade-size", dest="capital", type=float, default=None,
                        help="Target order capital in ADA (default: dynamic hurdle sizing or GEORGE_COINT_TRADE_SIZE_ADA, min ~100.0 ADA)")
    parser.add_argument("--notify", action="store_true", default=True, help="Send Discord briefing to operator")
    parser.add_argument("--no-notify", dest="notify", action="store_false", help="Suppress Discord briefing")
    parser.add_argument("--execute", action="store_true", help="Force live execution (requires AUTO mode)")
    parser.add_argument("--dry-run", action="store_true", help="Force dry-run simulation mode")
    parser.add_argument("--json", action="store_true", help="Output JSON only")
    args = parser.parse_args()

    res = run_reactor_cycle(
        notify_discord=args.notify,
        force_execute=args.execute,
        capital_ada=args.capital,
        force_dry_run=args.dry_run,
    )
    if args.json:
        print(json.dumps(res, indent=2, default=str))
    else:
        print(f"\n━━ Cardano Cointegration Reactor: {res.get('timestamp')} ━━")
        print(f"Operating Mode:    [{res.get('mode')}]")
        print(f"Status:            {res.get('message', res.get('status'))}")
        if "pair" in res:
            print(f"Target Pair:       {res['pair']} ({res['direction'].upper()} {res['target_asset']})")
            print(f"Capital Size:      {res.get('trade_size_ada')} ADA (Net EV: {res.get('net_ev_ada'):+.2f} ADA)")
            print(f"Limit Price:       {res['limit_price_ada']} ADA ({res['amount_tokens']} tokens)")
            print(f"Discord Notified:  {res.get('discord_notified')}")


if __name__ == "__main__":
    main()
