#!/usr/bin/env python3
"""Time-Series Residual & Volatility Analyzer for Blue Lodge.

Analyzes historical price trajectories and odds movements to compute
Z-score residuals, rolling volatility regimes, and mean-reversion signals.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from typing import Any


def estimate_ornstein_uhlenbeck(prices: list[float], dt: float = 0.5) -> dict[str, Any]:
    """
    Estimates Ornstein-Uhlenbeck (OU) mean-reversion parameters:
    dX_t = theta * (mu - X_t) * dt + sigma * dW_t
    Via discrete AR(1) OLS: (X_t - X_{t-1}) = a + b * X_{t-1} + e_t
    where b = exp(-theta * dt) - 1, a = mu * (1 - exp(-theta * dt))
    """
    clean = [float(x) for x in prices if float(x) > 0]
    if len(clean) < 6:
        return {
            "status": "INSUFFICIENT_DATA",
            "is_mean_reverting": False,
            "theta": 0.0,
            "half_life_hours": 0.0,
            "equilibrium_price": clean[-1] if clean else 0.0,
            "ou_volatility": 0.0,
            "regime": "INSUFFICIENT_DATA",
            "verdict": "UNVERIFIED",
        }

    log_p = [math.log(p) for p in clean]
    x_prev = log_p[:-1]
    dx = [log_p[i] - log_p[i - 1] for i in range(1, len(log_p))]

    n = len(dx)
    sum_x = sum(x_prev)
    sum_dx = sum(dx)
    sum_x2 = sum(x * x for x in x_prev)
    sum_x_dx = sum(x * d for x, d in zip(x_prev, dx))

    denom = (n * sum_x2 - sum_x ** 2)
    if abs(denom) < 1e-12:
        return {
            "status": "SINGULAR_MATRIX",
            "is_mean_reverting": False,
            "theta": 0.0,
            "half_life_hours": 0.0,
            "equilibrium_price": clean[-1],
            "ou_volatility": 0.0,
            "regime": "UNDEFINED",
            "verdict": "REJECT",
        }

    b = (n * sum_x_dx - sum_x * sum_dx) / denom
    a = (sum_dx - b * sum_x) / n

    residuals = [dx[i] - (a + b * x_prev[i]) for i in range(n)]
    res_var = sum(r * r for r in residuals) / max(1, n - 2)
    res_std = math.sqrt(max(0.0, res_var))

    if b < 0:
        val = 1.0 + b
        theta = -math.log(val) / dt if val > 0 else -b / dt
        mu_log = -a / b if abs(b) > 1e-9 else log_p[-1]
        mu = math.exp(mu_log)

        half_life = (math.log(2.0) / theta) if theta > 1e-6 else 999.0
        sigma_ou = res_std / math.sqrt(dt) if dt > 0 else res_std

        if half_life <= 12.0:
            regime = "FAST_MEAN_REVERTING"
            verdict = "HIGH_CONFIDENCE_MAKER"
        elif half_life <= 36.0:
            regime = "MODERATE_MEAN_REVERTING"
            verdict = "EXPAND_HORIZON"
        else:
            regime = "SLUGGISH_DRIFT"
            verdict = "HIGH_RISK_STALE_EXPOSURE"

        return {
            "status": "OK",
            "is_mean_reverting": True,
            "theta": round(theta, 4),
            "half_life_hours": round(half_life, 2),
            "equilibrium_price": round(mu, 6),
            "ou_volatility": round(sigma_ou, 4),
            "residuals_std": round(res_std, 4),
            "regime": regime,
            "verdict": verdict,
        }
    else:
        return {
            "status": "OK",
            "is_mean_reverting": False,
            "theta": 0.0,
            "half_life_hours": 999.99,
            "equilibrium_price": clean[-1],
            "ou_volatility": round(res_std, 4),
            "residuals_std": round(res_std, 4),
            "regime": "MOMENTUM_TRENDING_OR_EXPLOSIVE",
            "verdict": "ADVERSE_SELECTION_ALERT_DO_NOT_PLACE_BIDS",
        }


def analyze_residuals(
    prices: list[float],
    current_price: float | None = None,
    lookback: int = 14,
) -> dict[str, Any]:
    """Calculate moving averages, rolling volatility, Z-score residuals, and OU parameters."""
    if not prices:
        return {
            "status": "INSUFFICIENT_DATA",
            "sample_size": 0,
            "mean": 0.0,
            "current_price": current_price or 0.0,
            "z_score": 0.0,
            "volatility": 0.0,
            "regime": "UNKNOWN",
            "mean_reversion_bias": "NEUTRAL",
            "ornstein_uhlenbeck": {},
        }

    clean_prices = [float(p) for p in prices]
    if current_price is not None:
        clean_prices.append(float(current_price))

    n = len(clean_prices)
    cur = clean_prices[-1]
    window = clean_prices[-lookback:] if n >= lookback else clean_prices

    # Mean & Standard Deviation
    mean = sum(window) / len(window)
    variance = sum((x - mean) ** 2 for x in window) / len(window)
    volatility = math.sqrt(variance)

    # Z-score residual
    z_score = (cur - mean) / volatility if volatility > 1e-6 else 0.0

    # Volatility regime
    if volatility < 0.02:
        regime = "COMPRESSED"
    elif volatility < 0.06:
        regime = "NORMAL"
    elif volatility < 0.12:
        regime = "ELEVATED"
    else:
        regime = "EXTREME"

    # Mean reversion signal
    if z_score > 1.8:
        bias = "OVERBOUGHT_MEAN_REVERSION_DOWN"
    elif z_score < -1.8:
        bias = "OVERSOLD_MEAN_REVERSION_UP"
    elif abs(z_score) <= 0.5:
        bias = "AT_EQUILIBRIUM"
    else:
        bias = "MOMENTUM_TRENDING"

    # Ornstein-Uhlenbeck estimation on available price series
    ou_stats = estimate_ornstein_uhlenbeck(clean_prices)

    return {
        "status": "OK",
        "sample_size": n,
        "window_size": len(window),
        "current_price": round(cur, 6),
        "mean_price": round(mean, 6),
        "residual": round(cur - mean, 6),
        "volatility_sigma": round(volatility, 6),
        "z_score": round(z_score, 2),
        "regime": regime,
        "mean_reversion_bias": bias,
        "min_in_window": round(min(window), 6),
        "max_in_window": round(max(window), 6),
        "ornstein_uhlenbeck": ou_stats,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Time-Series Residual & Ornstein-Uhlenbeck Analyzer")
    parser.add_argument("--prices", type=str, help="Comma-separated price list, e.g. '0.40,0.41,0.43,0.42'")
    parser.add_argument("--current", type=float, help="Current spot price")
    parser.add_argument("--lookback", type=int, default=14, help="Lookback window size (default: 14)")
    parser.add_argument("--ou", action="store_true", help="Output standalone Ornstein-Uhlenbeck parameters")
    parser.add_argument("--stdin", action="store_true", help="Read JSON array of prices from stdin")

    args = parser.parse_args()
    price_list: list[float] = []

    if args.stdin or not sys.stdin.isatty():
        try:
            data = json.load(sys.stdin)
            if isinstance(data, list):
                price_list = [float(x) for x in data]
            elif isinstance(data, dict) and "prices" in data:
                price_list = [float(x) for x in data["prices"]]
        except Exception:
            pass

    if not price_list and args.prices:
        try:
            price_list = [float(x.strip()) for x in args.prices.split(",") if x.strip()]
        except Exception:
            pass

    if args.ou:
        res = estimate_ornstein_uhlenbeck(price_list)
    else:
        res = analyze_residuals(price_list, current_price=args.current, lookback=args.lookback)
    print(json.dumps(res, indent=2))


if __name__ == "__main__":
    main()
