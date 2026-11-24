#!/usr/bin/env python3
"""Bayesian Fair Value & Expected Value Engine for Blue Lodge.

Calculates calibrated Fair Value probability (P_fair), Expected Value (EV),
and Margin of Safety from base rates, empirical evidence weights, and sentiment.
Outputs structured JSON suitable for ReAct loops and atomic pipelines.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from typing import Any


def calculate_fair_value(
    p_market: float,
    p_base: float = 0.50,
    evidence_for: float = 1.0,
    evidence_against: float = 1.0,
    sentiment: float = 0.0,
    min_sources: int = 2,
    total_sources: int = 3,
    min_ev_threshold: float = 0.15,
    damping_factor: float = 0.40,
) -> dict[str, Any]:
    """Calculate calibrated Fair Value, Edge, and Expected Value (EV)."""
    # Clamp probabilities to prevent division by zero in logit space
    p_market = max(0.01, min(0.99, float(p_market)))
    p_base = max(0.05, min(0.95, float(p_base)))
    sentiment = max(-1.0, min(1.0, float(sentiment)))
    
    # 1. Base rate prior in log-odds
    prior_logit = math.log(p_base / (1.0 - p_base))
    
    # 2. Evidence log-likelihood ratio with smoothing
    eps = 0.5
    evidence_ratio = (evidence_for + eps) / (evidence_against + eps)
    delta_evidence = math.log(evidence_ratio) * damping_factor
    
    # 3. Sentiment polarity contribution
    delta_sentiment = sentiment * 0.25 * damping_factor
    
    # 4. Posterior logit and fair probability
    posterior_logit = prior_logit + delta_evidence + delta_sentiment
    p_fair = 1.0 / (1.0 + math.exp(-posterior_logit))
    p_fair = max(0.02, min(0.98, p_fair))
    
    # 5. Calculate Edge & EV for YES
    edge_yes = p_fair - p_market
    ev_yes = edge_yes / p_market if p_market > 0 else 0.0
    
    # 6. Calculate Edge & EV for NO
    p_market_no = 1.0 - p_market
    p_fair_no = 1.0 - p_fair
    edge_no = p_fair_no - p_market_no
    ev_no = edge_no / p_market_no if p_market_no > 0 else 0.0
    
    # 7. Impartial Spectator Decision Rule
    # Requires sufficient independent sources and a clear margin of safety
    recommendation = "PASS"
    selected_outcome = "NONE"
    selected_ev = 0.0
    selected_edge = 0.0
    margin_of_safety_met = False
    
    if total_sources >= min_sources:
        if ev_yes >= min_ev_threshold and edge_yes > 0.05:
            recommendation = "BUY YES"
            selected_outcome = "YES"
            selected_ev = ev_yes
            selected_edge = edge_yes
            margin_of_safety_met = True
        elif ev_no >= min_ev_threshold and edge_no > 0.05:
            recommendation = "BUY NO"
            selected_outcome = "NO"
            selected_ev = ev_no
            selected_edge = edge_no
            margin_of_safety_met = True
        else:
            recommendation = "PASS (Inadequate Margin of Safety)"
    else:
        recommendation = "PASS (Insufficient Corroborating Sources)"
        
    return {
        "market_implied_prob": round(p_market, 4),
        "base_rate_prior": round(p_base, 4),
        "estimated_fair_value": round(p_fair, 4),
        "yes": {
            "edge": round(edge_yes, 4),
            "edge_pct": round(edge_yes * 100.0, 2),
            "ev": round(ev_yes, 4),
            "ev_pct": round(ev_yes * 100.0, 2),
        },
        "no": {
            "edge": round(edge_no, 4),
            "edge_pct": round(edge_no * 100.0, 2),
            "ev": round(ev_no, 4),
            "ev_pct": round(ev_no * 100.0, 2),
        },
        "selected_outcome": selected_outcome,
        "recommendation": recommendation,
        "selected_edge_pct": round(selected_edge * 100.0, 2),
        "selected_ev_pct": round(selected_ev * 100.0, 2),
        "margin_of_safety_met": margin_of_safety_met,
        "evidence_summary": {
            "evidence_for": round(evidence_for, 2),
            "evidence_against": round(evidence_against, 2),
            "total_sources": total_sources,
            "sentiment_score": round(sentiment, 2),
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Bayesian Fair Value & Expected Value Engine")
    parser.add_argument("--market-price", "-m", type=float, required=True, help="Current market Yes price (0.01 - 0.99)")
    parser.add_argument("--base-rate", "-b", type=float, default=0.50, help="Historical category prior base rate (default: 0.50)")
    parser.add_argument("--evidence-for", type=float, default=1.0, help="Weighted evidence score supporting YES")
    parser.add_argument("--evidence-against", type=float, default=1.0, help="Weighted evidence score supporting NO")
    parser.add_argument("--sentiment", "-s", type=float, default=0.0, help="Normalized sentiment score (-1.0 to 1.0)")
    parser.add_argument("--sources", type=int, default=3, help="Total independent corroborating sources verified")
    parser.add_argument("--min-ev", type=float, default=0.15, help="Minimum EV threshold (default: 0.15 / 15%%)")
    parser.add_argument("--json", action="store_true", help="Output raw JSON (default)")

    args = parser.parse_args()
    res = calculate_fair_value(
        p_market=args.market_price,
        p_base=args.base_rate,
        evidence_for=args.evidence_for,
        evidence_against=args.evidence_against,
        sentiment=args.sentiment,
        total_sources=args.sources,
        min_ev_threshold=args.min_ev,
    )

    print(json.dumps(res, indent=2))


if __name__ == "__main__":
    main()
