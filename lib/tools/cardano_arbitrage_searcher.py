#!/usr/bin/env python3
"""Sovereign Cardano DEX Arbitrage Searcher & Microloan Allocator for Blue Lodge.

Continuously monitors price spreads across Cardano DEX protocols (Minswap,
SundaeSwap, WingRiders, Splash, CSWAP, VyFinance), computes exact CPMM pool
depth, minimum viable order sizes, profit-maximizing optimal order sizes,
persists spread observations to trading.db over time, and allocates trading
profits into Pillar 1 microloan underwriting.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from lib.tools.cardano_trader import (
    RESERVE_FLOOR_LOVELACE,
    query_wallet_balance,
)
from lib.tools.quant import tokens as _tokens
from lib.tools.trading import store as _tstore

logger = logging.getLogger("cardano_arbitrage")
logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")

# Target Cardano Native Assets for Arbitrage (all 15 tokens from canonical registry)
TARGET_ASSETS: Dict[str, Dict[str, Any]] = {
    sym: {
        "policy_id": _tokens.get(sym)["policy_id"],
        "asset_name_hex": _tokens.get(sym)["asset_name_hex"],
        "decimals": _tokens.decimals(sym),
    }
    for sym in _tokens.symbols()
}

# Protocol fee models on Cardano (in basis points: 30 bps = 0.30%)
DEX_SWAP_FEE_BPS = 30
BATCHER_FEE_LOVELACE = 2_000_000  # 2.00 ADA DEX batcher fee per swap leg
L1_TX_FEE_LOVELACE = 180_000      # ~0.18 ADA Cardano network fee per leg


@dataclass
class ArbitrageOpportunity:
    asset: str
    buy_dex: str
    sell_dex: str
    buy_price_ada: float
    sell_price_ada: float
    gross_spread_pct: float
    total_fee_ada: float
    capital_req_ada: float
    est_net_profit_ada: float
    net_roi_pct: float
    viable: bool
    rationale: str
    spot_buy_ada: float = 0.0
    spot_sell_ada: float = 0.0
    net_lp_spread_pct: float = 0.0
    exec_spread_pct: float = 0.0
    eff_reserve_ada: float = 0.0
    venues_count: int = 1
    is_cross_dex: bool = False
    min_viable_ada: Optional[float] = None
    no_slip_min_ada: Optional[float] = None
    target_viable_ada: float = 0.0
    optimal_ada: float = 0.0
    max_net_profit_ada: float = 0.0
    req_spread_pct: float = 0.0
    buy_batch_age_h: Optional[float] = None
    sell_batch_age_h: Optional[float] = None
    all_venues: List[Dict[str, Any]] = field(default_factory=list)
    quarantined_venues: List[Dict[str, Any]] = field(default_factory=list)
    history: Dict[str, Any] = field(default_factory=dict)


def fetch_live_market_prices() -> dict[str, float]:
    """Live USD prices (ADA and majors) from the Sovereign Fund price cache."""
    from lib.tools.sovereign_fund import usd_prices
    p = usd_prices()
    return {k: v for k, v in (p.get("usd") or {}).items() if v is not None}


def _record_and_summarize_history(quotes: list[dict[str, Any]], now_ts: int) -> dict[str, dict[str, Any]]:
    """Persist cross-DEX spread observations into trading.db and return 24h rolling stats per asset."""
    summaries: dict[str, dict[str, Any]] = {}
    try:
        con = _tstore.connect()
        try:
            last_row = con.execute("SELECT MAX(ts) FROM cross_dex_spreads").fetchone()
            last_ts = int(last_row[0]) if (last_row and last_row[0]) else 0
            should_insert = (now_ts - last_ts) >= 25

            if should_insert:
                for q in quotes:
                    sym = str(q.get("asset") or "")
                    if not sym:
                        continue
                    cap_ada = float(q.get("capital_ada") or 0.0)
                    ada_ret = float(q.get("ada_returned") or 0.0)
                    fee_ada = float(q.get("total_friction_ada") or 4.36)
                    net_at_cap = (ada_ret - cap_ada) - fee_ada
                    max_net = float(q.get("max_net_profit_ada") or net_at_cap)
                    viable_int = 1 if (net_at_cap >= 0.50 or max_net >= 0.50) else 0
                    con.execute(
                        """
                        INSERT INTO cross_dex_spreads (
                            ts, asset, buy_dex, sell_dex, venues_count,
                            spot_buy_ada, spot_sell_ada, spot_spread_pct, net_lp_spread_pct, exec_spread_pct,
                            fixed_fee_ada, eff_reserve_ada, capital_ada, net_profit_at_cap_ada,
                            min_viable_ada, target_viable_ada, optimal_ada, max_net_profit_ada,
                            req_spread_pct, viable
                        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        """,
                        (
                            now_ts,
                            sym,
                            str(q.get("buy_dex") or ""),
                            str(q.get("sell_dex") or ""),
                            int(q.get("venues_count") or 1),
                            float(q.get("spot_buy_price_ada") or q.get("buy_price_ada") or 0.0),
                            float(q.get("spot_sell_price_ada") or q.get("sell_price_ada") or 0.0),
                            float(q.get("spot_spread_pct") or 0.0),
                            float(q.get("net_lp_spread_pct") or 0.0),
                            float(q.get("exec_spread_pct") or 0.0),
                            fee_ada,
                            float(q.get("eff_reserve_ada") or 0.0),
                            cap_ada,
                            round(net_at_cap, 3),
                            q.get("min_viable_ada"),
                            float(q.get("target_viable_ada") or 0.0),
                            float(q.get("optimal_ada") or 0.0),
                            round(max_net, 3),
                            float(q.get("req_spread_pct") or 0.0),
                            viable_int,
                        ),
                    )
                con.commit()

            cutoff = now_ts - 86400
            rows = con.execute(
                """
                SELECT
                    asset,
                    COUNT(*) AS obs_24h,
                    MAX(spot_spread_pct) AS peak_spread_pct,
                    MAX(max_net_profit_ada) AS best_max_net_ada,
                    MIN(CASE WHEN min_viable_ada IS NOT NULL AND min_viable_ada > 0 THEN min_viable_ada END) AS min_viable_seen_ada,
                    AVG(target_viable_ada) AS avg_target_ada,
                    AVG(req_spread_pct) AS avg_req_spread_pct,
                    SUM(viable) AS viable_ticks
                FROM cross_dex_spreads
                WHERE ts >= ?
                GROUP BY asset
                """,
                (cutoff,),
            ).fetchall()
            for r in rows:
                summaries[str(r["asset"])] = {
                    "obs_24h": int(r["obs_24h"] or 0),
                    "peak_spread_pct": round(float(r["peak_spread_pct"] or 0.0), 2),
                    "best_max_net_ada": round(float(r["best_max_net_ada"] or 0.0), 3),
                    "min_viable_seen_ada": round(float(r["min_viable_seen_ada"]), 1) if r["min_viable_seen_ada"] is not None else None,
                    "avg_target_ada": round(float(r["avg_target_ada"] or 0.0), 1),
                    "avg_req_spread_pct": round(float(r["avg_req_spread_pct"] or 0.0), 2),
                    "viable_ticks": int(r["viable_ticks"] or 0),
                }
        finally:
            con.close()
    except Exception as e:
        logger.warning(f"Failed to record/query cross_dex_spreads history: {e}")
    return summaries


def scan_cross_dex_spreads(prices: dict[str, float], spendable_ada: float) -> list[ArbitrageOpportunity]:
    """Analyze real on-chain isolated cross-DEX quotes across 15 tokens and 6 DEX families."""
    from lib.tools.cardano_flash_sniper import fetch_live_amm_quotes

    max_single_swap = float(os.getenv("CARDANO_MAX_SINGLE_SWAP_ADA", "200.00"))
    # Align with trading_policy.json max_position_fraction (0.95 of working capital, up to max_single_swap)
    trade_capital_ada = min(max_single_swap, max(10.0, spendable_ada * 0.95 if spendable_ada > 0 else 150.0))
    quotes = fetch_live_amm_quotes(trade_capital_ada)
    now_ts = int(time.time())
    history_map = _record_and_summarize_history(quotes, now_ts)

    opportunities: list[ArbitrageOpportunity] = []

    for q in quotes:
        sym = str(q.get("asset") or "")
        buy_dex = str(q.get("buy_dex") or "Unknown")
        sell_dex = str(q.get("sell_dex") or "Unknown")
        buy_p = float(q.get("buy_price_ada") or 0.0)
        sell_p = float(q.get("sell_price_ada") or 0.0)
        spot_buy_p = float(q.get("spot_buy_price_ada") or buy_p)
        spot_sell_p = float(q.get("spot_sell_price_ada") or sell_p)
        ada_returned = float(q.get("ada_returned") or 0.0)
        actual_capital = float(q.get("capital_ada") or trade_capital_ada)

        if buy_p <= 0 or sell_p <= 0:
            continue

        spot_spread = float(q.get("spot_spread_pct", ((spot_sell_p - spot_buy_p) / spot_buy_p) * 100.0))
        net_lp_spread = float(q.get("net_lp_spread_pct") or 0.0)
        exec_spread = float(q.get("exec_spread_pct", ((sell_p - buy_p) / buy_p) * 100.0))
        total_friction_ada = float(q.get("total_friction_ada") or 4.36)

        gross_profit_ada = ada_returned - actual_capital
        net_profit_ada = gross_profit_ada - total_friction_ada
        net_roi = (net_profit_ada / actual_capital) * 100.0 if actual_capital > 0 else 0.0

        min_viable_ada = q.get("min_viable_ada")
        no_slip_min_ada = q.get("no_slip_min_ada")
        target_viable_ada = float(q.get("target_viable_ada") or 0.0)
        optimal_ada = float(q.get("optimal_ada") or 0.0)
        max_net_profit_ada = float(q.get("max_net_profit_ada") or net_profit_ada)
        req_spread_pct = float(q.get("req_spread_pct") or 2.5)
        eff_reserve_ada = float(q.get("eff_reserve_ada") or 0.0)
        venues_count = int(q.get("venues_count") or 1)
        is_cross_dex = bool(q.get("is_cross_dex", buy_dex != sell_dex))
        hist = history_map.get(sym, {})

        viable = (net_profit_ada >= 0.50) or (max_net_profit_ada >= 0.50 and spot_spread >= 1.5)

        if min_viable_ada is not None:
            sizing_note = (
                f"Viable now for orders >= {min_viable_ada:.0f} ADA "
                f"(optimal {optimal_ada:.0f} ADA nets {max_net_profit_ada:+.2f} ADA)."
            )
        else:
            sizing_note = (
                f"Needs >={req_spread_pct:.2f}% spread on {eff_reserve_ada:,.0f} ADA eff. depth "
                f"(target order ~{target_viable_ada:.0f} ADA; current optimal {optimal_ada:.0f} ADA nets {max_net_profit_ada:+.2f} ADA)."
            )

        opp = ArbitrageOpportunity(
            asset=sym,
            buy_dex=buy_dex,
            sell_dex=sell_dex,
            buy_price_ada=round(buy_p, 8),
            sell_price_ada=round(sell_p, 8),
            gross_spread_pct=round(spot_spread, 2),
            total_fee_ada=round(total_friction_ada, 3),
            capital_req_ada=round(actual_capital, 2),
            est_net_profit_ada=round(net_profit_ada, 3),
            net_roi_pct=round(net_roi, 2),
            viable=viable,
            rationale=(
                f"Buy {sym} on {buy_dex} (spot {spot_buy_p:.6f} ADA) -> Sell on {sell_dex} (spot {spot_sell_p:.6f} ADA). "
                f"Spot spread: {spot_spread:+.2f}% (net-LP: {net_lp_spread:+.2f}%, exec@{actual_capital:.0f}A: {exec_spread:+.2f}%). "
                f"Direct DEX friction: {total_friction_ada:.2f} ADA. {sizing_note}"
            ),
            spot_buy_ada=round(spot_buy_p, 8),
            spot_sell_ada=round(spot_sell_p, 8),
            net_lp_spread_pct=round(net_lp_spread, 2),
            exec_spread_pct=round(exec_spread, 2),
            eff_reserve_ada=round(eff_reserve_ada, 1),
            venues_count=venues_count,
            is_cross_dex=is_cross_dex,
            min_viable_ada=min_viable_ada,
            no_slip_min_ada=no_slip_min_ada,
            target_viable_ada=round(target_viable_ada, 1),
            optimal_ada=round(optimal_ada, 1),
            max_net_profit_ada=round(max_net_profit_ada, 3),
            req_spread_pct=round(req_spread_pct, 2),
            buy_batch_age_h=q.get("buy_batch_age_h"),
            sell_batch_age_h=q.get("sell_batch_age_h"),
            all_venues=q.get("all_venues") or [],
            quarantined_venues=q.get("quarantined_venues") or [],
            history=hist,
        )
        opportunities.append(opp)

    # Sort by max_net_profit_ada (at optimal size) then spot gross_spread_pct
    return sorted(opportunities, key=lambda x: (x.viable, x.max_net_profit_ada, x.gross_spread_pct), reverse=True)


def calculate_microloan_reallocation(spendable_ada: float, potential_profit_ada: float) -> dict[str, Any]:
    """Real Sovereign Loan Fund position (ledger-backed) plus the profit that would be swept."""
    from lib.tools.sovereign_fund import fund_state, load_policy
    st = fund_state()
    pol = load_policy()
    return {
        "fund_available": st.get("available", {}),
        "fund_outstanding_principal": st.get("outstanding_principal", {}),
        "sweep_due_ada": st.get("sweep_due_ada"),
        "would_sweep_from_this_trade_ada": round(max(0.0, potential_profit_ada) * pol["profit_sweep_pct"] / 100, 3),
        "profit_sweep_pct": pol["profit_sweep_pct"],
        "note": "Loans are underwritten and serviced by lib/tools/sovereign_lending.py (no escrow script).",
    }


def run_arbitrage_scan() -> dict[str, Any]:
    """Execute complete arbitrage scan and microloan reallocation analysis."""
    bal = query_wallet_balance()
    spendable_ada = bal.get("spendable_ada", 0.0)
    total_ada = bal.get("total_ada", 0.0)

    prices = fetch_live_market_prices()
    opps = scan_cross_dex_spreads(prices, spendable_ada)

    best_opp = opps[0] if opps else None
    potential_profit = max(best_opp.est_net_profit_ada, best_opp.max_net_profit_ada) if (best_opp and best_opp.viable) else 0.0

    microloan_plan = calculate_microloan_reallocation(spendable_ada, potential_profit)

    result = {
        "status": "ok",
        "timestamp": int(time.time()),
        "treasury": {
            "total_ada": total_ada,
            "spendable_ada": spendable_ada,
            "reserve_floor_ada": RESERVE_FLOOR_LOVELACE / 1_000_000,
        },
        "spot_prices_usd": {k: round(v, 6) for k, v in prices.items()},
        "arbitrage_opportunities": [asdict(o) for o in opps],
        "top_arbitrage_action": asdict(best_opp) if best_opp else None,
        "microloan_capital_flywheel": microloan_plan,
    }

    report_file = _REPO_ROOT / "dossiers" / "finance" / "cardano_arbitrage_scan.json"
    report_file.parent.mkdir(parents=True, exist_ok=True)
    report_file.write_text(json.dumps(result, indent=2), encoding="utf-8")

    return result


def main() -> None:
    parser = argparse.ArgumentParser(description="Cardano DEX Arbitrage Searcher & Microloan Allocator")
    parser.add_argument("--json", action="store_true", help="Output pure JSON")
    args = parser.parse_args()

    res = run_arbitrage_scan()

    if args.json:
        print(json.dumps(res, indent=2))
        return

    print("=" * 116)
    print("  SOVEREIGN CARDANO DEX ARBITRAGE SEARCHER & CPMM ORDER-SIZE HURDLE MATRIX")
    print("=" * 116)
    t = res["treasury"]
    print(f"  Treasury Balance: {t['total_ada']:.2f} ADA (Spendable: {t['spendable_ada']:.2f} ADA | Reserve Floor: {t['reserve_floor_ada']:.2f} ADA)")
    print("-" * 116)
    print(
        f"  {'ASSET':<7} {'BUY VENUE':<15} {'SELL VENUE':<15} {'SPOT SPRD':<10} "
        f"{'NET-LP':<8} {'REQ SPRD':<9} {'MIN/TGT ADA':<12} {'OPT ADA':<9} {'NET@CAP':<10} {'MAX NET'}"
    )
    print("-" * 116)
    for o in res["arbitrage_opportunities"]:
        min_str = f"{o['min_viable_ada']:.0f} ADA" if o.get("min_viable_ada") else f"~{o.get('target_viable_ada', 0):.0f} ADA*"
        print(
            f"  {o['asset']:<7} {o['buy_dex']:<15} {o['sell_dex']:<15} {o['gross_spread_pct']:>+7.2f}%  "
            f"{o.get('net_lp_spread_pct', 0):>+6.2f}%  {o.get('req_spread_pct', 0):>6.2f}%   "
            f"{min_str:<12} {o.get('optimal_ada', 0):>6.0f} A  "
            f"{o['est_net_profit_ada']:>+7.2f} A  {o.get('max_net_profit_ada', 0):>+7.2f} A"
        )
    print("=" * 116)
    print("  (* ~ADA = Target minimum order size required when the pair reaches its REQ SPRD hurdle for its pool depth.)")
    print("=" * 116)


if __name__ == "__main__":
    main()
