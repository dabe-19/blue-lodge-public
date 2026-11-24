#!/usr/bin/env python3
"""Conservative Fractional Kelly Staking Engine for Blue Lodge.

Calculates mathematically disciplined position sizing based on estimated Fair Value,
market implied odds, and strict bankroll safety constraints.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from typing import Any


def calculate_kelly_stake(
    p_fair: float,
    p_market: float,
    outcome: str = "YES",
    bankroll: float = 50.0,
    fraction: float = 0.25,
    hard_max: float = 5.0,
    min_stake: float = 1.0,
) -> dict[str, Any]:
    """Calculate conservative fractional Kelly stake."""
    p_fair = max(0.01, min(0.99, float(p_fair)))
    p_market = max(0.01, min(0.99, float(p_market)))
    outcome = outcome.strip().upper()

    if outcome == "NO":
        p_fair_eff = 1.0 - p_fair
        p_market_eff = 1.0 - p_market
    else:
        outcome = "YES"
        p_fair_eff = p_fair
        p_market_eff = p_market

    # Net decimal odds: b = (1 - price) / price
    # e.g., if market price is 0.40, a $1 payout returns $0.60 profit per $0.40 spent: b = 0.60 / 0.40 = 1.5
    b = (1.0 - p_market_eff) / p_market_eff if p_market_eff > 0 else 0.0

    # Full Kelly: f* = (b * p - q) / b = (p - p_market) / (1 - p_market)
    edge = p_fair_eff - p_market_eff
    if edge <= 0 or b <= 0:
        full_kelly = 0.0
    else:
        full_kelly = edge / (1.0 - p_market_eff)

    # Fractional Kelly (e.g. Quarter Kelly)
    fractional_kelly = max(0.0, full_kelly * fraction)

    # Raw dollar allocation
    raw_dollars = fractional_kelly * bankroll

    # Apply bounds
    if raw_dollars < min_stake:
        final_stake = 0.0
        status = "PASS_BELOW_MINIMUM_STAKE"
    else:
        final_stake = min(raw_dollars, hard_max)
        status = "ALLOCATE"

    # Number of contracts at market price
    contracts = math.floor(final_stake / p_market_eff) if p_market_eff > 0 and final_stake > 0 else 0
    actual_spent = round(contracts * p_market_eff, 2)
    max_payout = round(contracts * 1.00, 2)
    potential_profit = round(max_payout - actual_spent, 2)

    return {
        "outcome": outcome,
        "p_fair": round(p_fair_eff, 4),
        "p_market": round(p_market_eff, 4),
        "edge": round(edge, 4),
        "edge_pct": round(edge * 100.0, 2),
        "full_kelly_pct": round(full_kelly * 100.0, 2),
        "applied_fraction": fraction,
        "fractional_kelly_pct": round(fractional_kelly * 100.0, 2),
        "bankroll_usd": round(bankroll, 2),
        "recommended_stake_usd": round(final_stake, 2),
        "actual_cost_usd": actual_spent,
        "contracts_count": contracts,
        "potential_profit_usd": potential_profit,
        "max_payout_usd": max_payout,
        "status": status,
        "hard_max_limit": round(hard_max, 2),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Fractional Kelly Staking Engine")
    parser.add_argument("--p-fair", "-f", type=float, required=True, help="Estimated fair probability (0.01 - 0.99)")
    parser.add_argument("--p-market", "-m", type=float, required=True, help="Current market price (0.01 - 0.99)")
    parser.add_argument("--outcome", "-o", choices=["YES", "NO"], default="YES", help="Bet outcome (YES or NO)")
    parser.add_argument("--bankroll", "-b", type=float, default=50.0, help="Total available bankroll in USD (default: $50.00)")
    parser.add_argument("--fraction", "-k", type=float, default=0.25, help="Kelly fraction multiplier (default: 0.25)")
    parser.add_argument("--hard-max", type=float, default=5.0, help="Hard maximum stake per bet (default: $5.00)")
    parser.add_argument("--min-stake", type=float, default=1.0, help="Minimum stake threshold (default: $1.00)")

    args = parser.parse_args()
    res = calculate_kelly_stake(
        p_fair=args.p_fair,
        p_market=args.p_market,
        outcome=args.outcome,
        bankroll=args.bankroll,
        fraction=args.fraction,
        hard_max=args.hard_max,
        min_stake=args.min_stake,
    )
    print(json.dumps(res, indent=2))


if __name__ == "__main__":
    main()
