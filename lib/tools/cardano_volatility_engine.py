#!/usr/bin/env python3
"""
Sovereign Cardano Volatility & Quantitative Horizon Engine (v2, audited).

v1 problems (fixed here):
  * Used CoinGecko USD candles although every order is priced in ADA, so ADA's own moves
    leaked into "asset volatility".
  * Estimated each horizon from 3-12 bars (huge sampling error) and called a single 24h
    high/low log-range a "24h sigma".
  * On any fetch failure it silently substituted hard-coded BASELINE numbers and a fake
    "mean-reverting" OU verdict, so downstream tools could not tell real from invented data.

v2 design:
  * ADA-quoted OHLCV from the most active pool (lib.tools.quant.market_data).
  * Horizon sigma = standard deviation of overlapping H-hour log returns over ~40 days of
    hourly bars (captures the short-horizon mean reversion that sqrt(t) scaling misses).
  * Mean reversion is judged by formal tests (ADF for a stationary level, Lo-MacKinlay
    variance ratio for short-horizon bounce). OU numbers are descriptive unless ADF rejects.
  * When data is unavailable the status is "unavailable" and numeric fields are omitted;
    nothing is fabricated. The output schema is kept compatible with existing consumers.
"""

import json
import logging
import math
import os
import sys
import time
from pathlib import Path
from typing import Any, Dict

import numpy as np

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from lib.tools.quant import market_data as md  # noqa: E402
from lib.tools.quant import models as qm  # noqa: E402

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", stream=sys.stderr)
logger = logging.getLogger("cardano_volatility_engine")

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path.home() / "blue-lodge"))
CACHE_FILE = LODGE_DIR / ".george" / "finance" / "volatility_cache.json"
CACHE_TTL_SEC = 3600

# Kept for backward-compatible imports. Used only as labelled priors by other tools;
# this engine NEVER substitutes them for live data.
ASSET_COINGECKO_MAP = {
    "SNEK": "snek", "MIN": "minswap", "IAG": "iagon", "WMTX": "world-mobile-token",
    "DJED": "djed", "ADA": "cardano", "NIGHT": "midnight", "USDM": "mehen-usdm",
    "USDCX": "usd-coin", "HOSKY": "hosky-token"
}
BASELINE_VOLATILITY = {
    "SNEK": {"30m": 0.009, "1h": 0.015, "2h": 0.024, "4h": 0.038, "8h": 0.055, "24h": 0.100},
    "MIN":  {"30m": 0.006, "1h": 0.010, "2h": 0.016, "4h": 0.025, "8h": 0.035, "24h": 0.050},
    "IAG":  {"30m": 0.008, "1h": 0.014, "2h": 0.022, "4h": 0.035, "8h": 0.050, "24h": 0.095},
    "WMTX": {"30m": 0.007, "1h": 0.012, "2h": 0.019, "4h": 0.030, "8h": 0.042, "24h": 0.075},
    "DJED": {"30m": 0.003, "1h": 0.005, "2h": 0.008, "4h": 0.012, "8h": 0.018, "24h": 0.030},
    "NIGHT": {"30m": 0.010, "1h": 0.016, "2h": 0.025, "4h": 0.040, "8h": 0.060, "24h": 0.105},
    "USDM": {"30m": 0.003, "1h": 0.005, "2h": 0.008, "4h": 0.012, "8h": 0.018, "24h": 0.030},
    "USDCX": {"30m": 0.003, "1h": 0.005, "2h": 0.008, "4h": 0.012, "8h": 0.018, "24h": 0.030},
    "HOSKY": {"30m": 0.015, "1h": 0.025, "2h": 0.040, "4h": 0.065, "8h": 0.095, "24h": 0.160},
}
TRACKED = ["SNEK", "MIN", "IAG", "WMTX", "DJED", "NIGHT", "USDM", "USDCX", "HOSKY"]
HORIZONS_H = {"1h": 1, "2h": 2, "4h": 4, "8h": 8, "24h": 24}


def parkinson_volatility(high_low_pairs) -> float:
    """Kept for callers that import it. Per-bar Parkinson sigma."""
    pairs = [(h, l) for (h, l) in high_low_pairs if h > 0 and l > 0 and h >= l]
    if not pairs:
        return 0.0
    return math.sqrt(sum(math.log(h / l) ** 2 for h, l in pairs) / (4.0 * math.log(2.0) * len(pairs)))


def _horizon_sd(lc: np.ndarray, h: int) -> float:
    if len(lc) <= h + 20:
        return float("nan")
    d = lc[h:] - lc[:-h]
    return float(np.std(d, ddof=1))


def _corridors(sigma_4h: float) -> Dict[str, Any]:
    out = {}
    for cap in (30.0, 50.0, 100.0, 150.0):
        friction = (3.96 / cap) * 100.0 + 0.60 + 1.00  # 2x(batcher+L1) + 2x0.3% LP fee + 1% hurdle
        corridor = max(1.5, sigma_4h * 100.0 * 2.0 * 1.15)
        out[f"{int(cap)}ada"] = {
            "friction_floor_pct": round(friction, 2),
            "parkinson_corridor_4h_pct": round(corridor, 2),  # name kept for consumers; now horizon-sd based
            "defensible_spread_pct": round(max(friction, corridor), 2),
            "is_viable_at_4h": corridor >= friction,
        }
    return out


def analyze_asset_volatility(symbol: str, cg_id: str = None) -> Dict[str, Any]:
    """Multi-horizon volatility, momentum and mean-reversion diagnostics in ADA terms.
    `cg_id` is accepted for backward compatibility and ignored."""
    sym = symbol.upper()
    try:
        s = md.load_series(sym, "hour", 1)
    except Exception as e:
        s = {"status": "unavailable", "reason": f"{type(e).__name__}: {e}"}
    if s.get("status") != "ok":
        logger.warning(f"Volatility for {sym} unavailable: {s.get('reason')}")
        return {"asset": sym, "status": "unavailable", "reason": s.get("reason"), "timestamp": int(time.time()),
                "volatility": {}, "dispersion_pct": {}, "defensible_corridors": {},
                "ornstein_uhlenbeck": {"status": "UNAVAILABLE", "is_mean_reverting": False,
                                       "verdict": "NO_DATA_DO_NOT_TRADE", "half_life_hours": None}}
    g = s["grid"]
    c = g["c"]
    lc = np.log(c)
    r = np.diff(lc)
    sig = {k: _horizon_sd(lc, h) for k, h in HORIZONS_H.items()}
    sig["30m"] = sig["1h"] * math.sqrt(0.5) if math.isfinite(sig["1h"]) else float("nan")  # scaled, labelled
    vol = {k: round(v, 5) for k, v in sig.items() if math.isfinite(v)}
    vel4 = (math.exp(lc[-1] - lc[-5]) - 1) * 100 if len(lc) > 5 else 0.0
    vel24 = (math.exp(lc[-1] - lc[-25]) - 1) * 100 if len(lc) > 25 else 0.0

    adf = qm.adf_test(lc)
    vr = qm.variance_ratio_test(lc)
    ou = qm.fit_ou(lc, 1.0, adf)
    drift = qm.drift_estimate(r)
    short_mr = vr.get("verdict", "").startswith("short-horizon mean reversion")
    momentum = vr.get("verdict") == "short-horizon momentum"
    level_mr = bool(adf.get("rejects_unit_root_5pct"))
    adverse = momentum or (drift.get("significant_5pct") and drift.get("mean_per_bar", 0) < 0)
    if adverse:
        verdict = "ADVERSE_SELECTION_ALERT_DO_NOT_PLACE_BIDS"
    elif level_mr:
        verdict = "LEVEL_MEAN_REVERTING"
    elif short_mr:
        verdict = "SHORT_HORIZON_BOUNCE_ONLY"
    else:
        verdict = "RANDOM_WALK"
    ou_out = {
        "status": "OK",
        "is_mean_reverting": bool(level_mr or short_mr) and not adverse,
        "basis": ("ADF rejects unit root" if level_mr else
                  "variance ratio < 1 (short-horizon bounce); level is a random walk" if short_mr else
                  "no mean reversion detected"),
        "verdict": verdict,
        "actionable": bool(ou.get("actionable")),
        "theta": ou.get("theta_per_hour"),
        "half_life_hours": round(ou["half_life_hours"], 2) if ou.get("half_life_hours") else None,
        "half_life_ci95_hours": ou.get("half_life_ci95_hours"),
        "equilibrium_price": ou.get("mu_price") if ou.get("actionable") else None,
        "adf_pvalue": adf.get("pvalue"),
        "variance_ratio": [{"q": x["q"], "vr": round(x["vr"], 3), "p": x["pvalue"]} for x in vr.get("ratios", [])],
        "regime": verdict,
        "note": ou.get("reason"),
    }
    return {
        "asset": sym,
        "status": "live",
        "numeraire": "ADA",
        "timestamp": int(time.time()),
        "price_ada": float(s["pool"]["price_ada"]),
        "velocity_4h_pct": round(vel4, 2),
        "velocity_24h_pct": round(vel24, 2),
        "volatility": vol,
        "dispersion_pct": {k: round(v * 100.0, 2) for k, v in vol.items()},
        "method": "sd of overlapping H-hour ADA log returns (30m scaled from 1h)",
        "sample": {"bars": int(len(c)), "coverage": round(s["coverage"], 3),
                   "pool": s["pool"]["pool_address"], "dex": s["pool"]["dex"]},
        "ornstein_uhlenbeck": ou_out,
        "defensible_corridors": _corridors(sig["4h"]) if math.isfinite(sig["4h"]) else {},
        "provenance": s["provenance"],
    }


def get_all_asset_volatilities(force_refresh: bool = False) -> Dict[str, Any]:
    now = time.time()
    CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
    if not force_refresh and CACHE_FILE.exists():
        try:
            cached = json.loads(CACHE_FILE.read_text())
            if now - cached.get("timestamp", 0) < CACHE_TTL_SEC and cached.get("schema") == "vol/v2":
                return cached
        except Exception:
            pass
    results = {sym: analyze_asset_volatility(sym) for sym in TRACKED}
    payload = {"status": "ok", "schema": "vol/v2", "timestamp": int(now),
               "source": "GeckoTerminal ADA-quoted OHLCV · horizon-sd · ADF/VR diagnostics", "assets": results}
    try:
        CACHE_FILE.write_text(json.dumps(qm.json_safe(payload), indent=2))
    except Exception as e:
        logger.warning(f"Could not persist volatility cache: {e}")
    return payload


if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser(description="Cardano Volatility & Multi-Horizon Quant Engine (ADA-quoted)")
    p.add_argument("--asset", default="")
    p.add_argument("--json", action="store_true")
    p.add_argument("--refresh", action="store_true")
    a = p.parse_args()
    data = get_all_asset_volatilities(force_refresh=a.refresh)
    if a.asset:
        res = data.get("assets", {}).get(a.asset.upper()) or analyze_asset_volatility(a.asset)
        if a.json:
            print(json.dumps(qm.json_safe(res), indent=2))
        else:
            print(f"=== VOLATILITY PROFILE: {a.asset.upper()}/ADA === status={res.get('status')}")
            print(f"Velocity 4h: {res.get('velocity_4h_pct')}% | 24h: {res.get('velocity_24h_pct')}%")
            for h, v in res.get("dispersion_pct", {}).items():
                print(f"  {h:>4}: ±{v:.2f}% (1σ of {h} return)")
            ou = res.get("ornstein_uhlenbeck", {})
            print(f"Mean reversion: {ou.get('verdict')} — {ou.get('basis')}")
    else:
        if a.json:
            print(json.dumps(qm.json_safe(data), indent=2))
        else:
            print("=== CARDANO MULTI-HORIZON VOLATILITY (ADA-quoted, 1σ of H-hour return) ===")
            print(f"{'ASSET':<6} {'30M':<8} {'1H':<8} {'2H':<8} {'4H':<8} {'8H':<8} {'24H':<8} {'4H VEL':<8} VERDICT")
            for sym, d in data.get("assets", {}).items():
                v = d.get("dispersion_pct", {})
                print(f"{sym:<6} " + " ".join(f"±{v.get(k, float('nan')):<6.2f}%" for k in ("30m", "1h", "2h", "4h", "8h", "24h"))
                      + f" {d.get('velocity_4h_pct', 0):>+6.1f}% {d.get('ornstein_uhlenbeck', {}).get('verdict', d.get('status'))}")
