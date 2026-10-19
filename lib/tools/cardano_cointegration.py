#!/usr/bin/env python3
"""
Cardano Cointegration & Multi-Dimensional Pairs/Basket Scanner
Solves the random-walk limitation of single-asset OU models:
  - Single tokens are I(1) non-stationary random walks (ADF p > 0.05).
  - Cointegrated pairs (A - beta * B) form strictly stationary I(0) synthetic spreads.
  - Implements Engle-Granger Two-Step Cointegration & OU Half-Life fitting.

Candidate Pairs Tested:
  - DJED / USDC (Pegged Stablecoin parity)
  - IAG / WMTX (Decentralized Physical Infrastructure)
  - MIN / SNEK (DeFi liquidity & high-volume ecosystem tokens)
  - MIN / ADA  (DEX token vs L1 base asset)

Usage:
  python3 lib/tools/cardano_cointegration.py --scan --json
  python3 lib/tools/cardano_cointegration.py --pair IAG WMTX --json
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import numpy as np

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from lib.tools.quant import market_data as md
from lib.tools.quant import models as qm

CANDIDATE_PAIRS = [
    ("MIN", "IAG", "Protocol Utility Spread"),
    ("DJED", "MIN", "Stable vs DeFi Spread"),
    ("DJED", "IAG", "Stable vs DePIN Spread"),
    ("IAG", "WMTX", "DePIN Infrastructure Spread"),
    ("MIN", "SNEK", "Cardano DeFi Ecosystem Spread"),
    ("SNEK", "WMTX", "Community vs Telecom Spread"),
    ("NIGHT", "MIN", "Midnight Partner Chain vs DEX"),
    ("NIGHT", "SNEK", "Midnight Privacy vs Meme"),
    ("USDM", "DJED", "Fiat-Backed USDM vs Algorithmic DJED Parity"),
    ("USDCX", "USDM", "Circle xReserve USDCx vs Moneta USDM Parity"),
    ("HOSKY", "SNEK", "Cardano Premier Meme Asset Spread"),
    ("NIGHT", "USDM", "Midnight Privacy vs Fiat-Backed USDM"),
]


def _ols(y: np.ndarray, x: np.ndarray) -> Tuple[float, float, np.ndarray]:
    """
    Fits OLS: y = alpha + beta * x + eps.
    Returns (alpha, beta, residuals).
    """
    X = np.column_stack([np.ones_like(x), x])
    beta_hat = np.linalg.lstsq(X, y, rcond=None)[0]
    alpha, beta = float(beta_hat[0]), float(beta_hat[1])
    residuals = y - (alpha + beta * x)
    return alpha, beta, residuals


def _tls(y: np.ndarray, x: np.ndarray) -> Tuple[float, float, np.ndarray]:
    """
    Fits Total Least Squares (Orthogonal Distance Regression via 2D SVD/PCA):
      y = alpha + beta * x + eps
    Minimizes orthogonal squared Euclidean errors, eliminating errors-in-variables
    directionality bias (beta_yx == 1.0 / beta_xy).
    Returns (alpha, beta, residuals).
    """
    fit = qm.total_least_squares(y, x)
    return float(fit["alpha"]), float(fit["beta"]), fit["residuals"]


def test_pair_cointegration(asset_a: str, asset_b: str, timeframe: str = "hour", aggregate: int = 1) -> Dict[str, Any]:
    """
    Runs Engle-Granger Two-Step Cointegration Test:
      1. Loads aligned historical price series for Token A and Token B.
      2. Computes Total Least Squares (TLS) orthogonal regression to find symmetric beta.
      3. Tests stationarity of residuals with MacKinnon N=2 Augmented Dickey-Fuller.
      4. Fits OU mean-reverting dynamics to compute half-life and trade signals.
    """
    series_a = md.load_series(asset_a, timeframe=timeframe, aggregate=aggregate)
    series_b = md.load_series(asset_b, timeframe=timeframe, aggregate=aggregate)

    if series_a.get("status") != "ok" or series_b.get("status") != "ok":
        return {
            "status": "unavailable",
            "pair": f"{asset_a}/{asset_b}",
            "reason": f"Insufficient data: A={series_a.get('status')}, B={series_b.get('status')}",
        }

    grid_a = series_a.get("grid", {})
    grid_b = series_b.get("grid", {})

    t_a, c_a = grid_a.get("t", []), grid_a.get("c", [])
    t_b, c_b = grid_b.get("t", []), grid_b.get("c", [])

    if len(t_a) < 30 or len(t_b) < 30:
        return {
            "status": "insufficient_data",
            "pair": f"{asset_a}/{asset_b}",
            "bars_a": len(t_a),
            "bars_b": len(t_b),
        }

    # Timestamp alignment
    map_a = {int(t): float(c) for t, c in zip(t_a, c_a) if c > 0}
    map_b = {int(t): float(c) for t, c in zip(t_b, c_b) if c > 0}

    common_times = sorted(set(map_a.keys()).intersection(map_b.keys()))
    if len(common_times) < 25:
        return {
            "status": "insufficient_overlap",
            "pair": f"{asset_a}/{asset_b}",
            "common_bars": len(common_times),
        }

    prices_a = np.array([map_a[t] for t in common_times])
    prices_b = np.array([map_b[t] for t in common_times])

    ln_a = np.log(prices_a)
    ln_b = np.log(prices_b)

    # Step 1: Total Least Squares (TLS) regression on log prices (with OLS for reference)
    ols_alpha, ols_beta, _ = _ols(ln_a, ln_b)
    alpha, beta, residuals = _tls(ln_a, ln_b)

    # Step 2: ADF unit root test on residuals (Engle-Granger N=2 cointegration response surface)
    adf = qm.adf_test(residuals, n_variables=2)

    # Step 3: OU Model parameters on residuals
    step_h = (series_a["step_s"]) / 3600.0
    ou = qm.fit_ou(residuals, dt_hours=step_h, adf=adf)

    # Step 4: Spread Z-Score, Variance & Volatility Corridor
    mu = float(np.mean(residuals))
    sigma = float(np.std(residuals, ddof=1)) if len(residuals) > 1 else 1.0
    variance = float(sigma ** 2)
    current_spread = float(residuals[-1])
    z_score = (current_spread - mu) / sigma if sigma > 0 else 0.0

    # Build aligned historical spread corridor series (~100 points)
    corridor_series = []
    step = max(1, len(common_times) // 100)
    for idx in range(0, len(common_times), step):
        t_sec = int(common_times[idx])
        s_val = float(residuals[idx])
        corridor_series.append({
            "time": t_sec,
            "spread": round(s_val, 5),
            "z_score": round((s_val - mu) / sigma, 2) if sigma > 0 else 0.0,
            "price_a": round(float(prices_a[idx]), 6),
            "price_b": round(float(prices_b[idx]), 6),
        })
    if corridor_series and corridor_series[-1]["time"] != int(common_times[-1]):
        s_last = float(residuals[-1])
        corridor_series.append({
            "time": int(common_times[-1]),
            "spread": round(s_last, 5),
            "z_score": round((s_last - mu) / sigma, 2) if sigma > 0 else 0.0,
            "price_a": round(float(prices_a[-1]), 6),
            "price_b": round(float(prices_b[-1]), 6),
        })

    is_cointegrated = adf.get("rejects_unit_root_5pct", False)
    pvalue = adf.get("pvalue", 1.0)

    # Trading Signal determination
    signal = "NEUTRAL"
    action = "HOLD"
    if is_cointegrated:
        if z_score >= 1.35:
            signal = "SHORT_SPREAD"
            action = f"SELL {asset_a} / BUY {asset_b} (Spread rich: {z_score:+.2f}σ)"
        elif z_score <= -1.35:
            signal = "LONG_SPREAD"
            action = f"BUY {asset_a} / SELL {asset_b} (Spread cheap: {z_score:+.2f}σ)"

    return {
        "status": "ok",
        "pair": f"{asset_a}/{asset_b}",
        "asset_a": asset_a,
        "asset_b": asset_b,
        "bars_evaluated": len(common_times),
        "spot_a": float(prices_a[-1]),
        "spot_b": float(prices_b[-1]),
        "regression_method": "total_least_squares",
        "hedge_ratio_beta": round(beta, 4),
        "intercept_alpha": round(alpha, 4),
        "ols_hedge_ratio_beta": round(ols_beta, 4),
        "ols_intercept_alpha": round(ols_alpha, 4),
        "cointegration": {
            "is_cointegrated": is_cointegrated,
            "adf_statistic": round(float(adf.get("statistic", 0.0)), 3),
            "adf_critical_5pct": round(float(adf.get("critical_values", {}).get("5%", -3.336)), 3),
            "adf_pvalue": round(float(pvalue), 4),
            "n_variables": 2,
            "critical_values": {k: round(v, 3) for k, v in adf.get("critical_values", {}).items()},
            "interpretation": "STATIONARY (True Mean-Reverting Spread)" if is_cointegrated else "NON-STATIONARY (Random Walk)",
        },
        "ornstein_uhlenbeck": {
            "half_life_hours": ou.get("half_life_hours"),
            "mean_reversion_time_hours": ou.get("half_life_hours"),
            "kappa_mean_reversion_speed": ou.get("kappa"),
            "mu_mean": round(mu, 5),
            "sigma": round(sigma, 5),
            "variance": round(variance, 6),
            "corridor_bands": {
                "upper_2sigma": round(mu + 2.0 * sigma, 5),
                "upper_1_5sigma": round(mu + 1.5 * sigma, 5),
                "mean": round(mu, 5),
                "lower_1_5sigma": round(mu - 1.5 * sigma, 5),
                "lower_2sigma": round(mu - 2.0 * sigma, 5),
            },
        },
        "spread_now": round(current_spread, 5),
        "z_score": round(z_score, 2),
        "signal": signal,
        "action": action,
        "corridor_series": corridor_series,
    }


def scan_all_candidate_pairs() -> List[Dict[str, Any]]:
    """Scans all predefined candidate pairs and returns ranked cointegration opportunities."""
    results = []
    for asset_a, asset_b, description in CANDIDATE_PAIRS:
        res = test_pair_cointegration(asset_a, asset_b)
        res["description"] = description
        results.append(res)

    # Rank by lowest p-value (strongest cointegration first)
    results.sort(key=lambda x: (x.get("cointegration", {}).get("adf_pvalue", 1.0), -abs(x.get("z_score", 0.0))))
    return results


def main():
    parser = argparse.ArgumentParser(description="Cardano Cointegration & Pairs Statistical Arbitrage Scanner")
    parser.add_argument("--scan", action="store_true", help="Scan all predefined candidate pairs")
    parser.add_argument("--pair", nargs=2, metavar=("A", "B"), help="Test specific pair (e.g. --pair IAG WMTX)")
    parser.add_argument("--json", action="store_true", help="Output pure JSON")
    args = parser.parse_args()

    if args.pair:
        res = test_pair_cointegration(args.pair[0], args.pair[1])
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            c = res.get("cointegration", {})
            ou = res.get("ornstein_uhlenbeck", {})
            ou_hl = ou.get('half_life_hours')
            hl = f"{round(float(ou_hl), 1)} hours" if ou_hl is not None else "None"
            print("=" * 80)
            print(f"Cointegration Analysis: {res.get('pair')}")
            print("=" * 80)
            print(f"Stationarity:       {c.get('interpretation')}")
            print(f"ADF Statistic:      tau={c.get('adf_statistic')} (5% crit: {c.get('adf_critical_5pct')}, p={c.get('adf_pvalue')}, N=2)")
            print(f"TLS Hedge Ratio:    beta={res.get('hedge_ratio_beta')} [ln({args.pair[0]}) = alpha + beta * ln({args.pair[1]})]")
            print(f"OLS Hedge Ratio:    beta={res.get('ols_hedge_ratio_beta')}")
            print(f"Current Z-Score:    {res.get('z_score'):+.2f} sigma")
            print(f"OU Half-Life:       {hl}")
            print(f"Signal / Action:    {res.get('action')}")
            print("=" * 80)
    else:
        results = scan_all_candidate_pairs()
        if args.json:
            print(json.dumps({"status": "ok", "pairs": results}, indent=2))
        else:
            print("=" * 104)
            print("Cardano Cointegration & Pairs Statistical Arbitrage Scanner")
            print("=" * 104)
            print(f"{'PAIR':12} {'CATEGORY':26} {'COINT':7} {'ADF-TAU':9} {'CRIT-5%':9} {'ADF-P':8} {'TLS-BETA':10} {'Z-SCORE':9} {'ACTION'}")
            print("-" * 104)
            for r in results:
                pair = r.get("pair", "-")
                desc = r.get("description", "-")[:24]
                c_data = r.get("cointegration", {})
                coint = "YES" if c_data.get("is_cointegrated") else "NO"
                tau = f"{c_data.get('adf_statistic', 0.0):.3f}" if "adf_statistic" in c_data else "-"
                crit5 = f"{c_data.get('adf_critical_5pct', -3.336):.3f}" if "adf_critical_5pct" in c_data else "-"
                p = f"{c_data.get('adf_pvalue', 1.0):.4f}" if "adf_pvalue" in c_data else "-"
                beta = f"{r.get('hedge_ratio_beta', 0.0):.4f}" if "hedge_ratio_beta" in r else "-"
                z = f"{r.get('z_score', 0.0):+6.2f}s" if "z_score" in r else "-"
                act = r.get("action", "-")
                print(f"{pair:12} {desc:26} {coint:7} {tau:9} {crit5:9} {p:8} {beta:10} {z:9} {act}")
            print("=" * 104)


if __name__ == "__main__":
    main()

