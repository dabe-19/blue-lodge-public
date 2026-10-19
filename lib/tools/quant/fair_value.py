#!/usr/bin/env python3
"""
Fair value for Cardano pool prices.

S2 (all pools): a Kalman local-level filter on log price.
    y_t  = mu_t + eps_t      eps ~ N(0, R)   transient dislocation (batch impact, overshoot)
    mu_t = mu_{t-1} + eta_t  eta ~ N(0, Q)   the random-walk "efficient" level
  For this model Var(y_t - y_{t-k}) = k*Q + 2R, so Q and R are identified from the 1-step and
  k-step (24h) variances, i.e. from the variance-ratio curve. VR(24) ~ 0.35 on our pools means
  R is a large share of short-horizon variance: price overshoots and comes back. If the data say
  VR >= 1 (no transient component) R collapses to ~0 and fair value equals spot: no signal.
  The deviation (y - mu) / sigma_dev is the S2 trigger input; its decay rate (1-K) per step gives a
  model half-life.

S3 (USD stablecoins USDM/USDCX/DJED): fair value in ADA = 1 / ADAUSD (Coinbase) x peg. The
  deviation series log(pool) - log(1/ADAUSD) is mean-reverting by construction (arbitrage to the
  peg); its std and AR(1) half-life are estimated from history.

Data: market.db 5-minute grid from the pool recorder when >= 3 days exist, else GeckoTerminal
hourly bars. Every output carries `source` so callers can see what it rests on.
"""
from __future__ import annotations

import json
import math
import sys
import time
from pathlib import Path
from typing import Any, Dict, Optional

import numpy as np

_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

STABLES = {"USDM": 1.0, "USDCX": 1.0, "DJED": 1.0}
MIN_RECORDER_DAYS = 3


def local_level(y: np.ndarray, k: int, include_series: bool = False) -> Dict[str, Any]:
    """Moment-identified local-level model + steady-state Kalman filter over y (log prices)."""
    y = np.asarray(y, dtype=float)
    y = y[np.isfinite(y)]
    k = max(2, int(k))
    if len(y) < max(3 * k, 50):
        return {"status": "insufficient_data", "n": int(len(y))}
    d1 = np.diff(y)
    dk = y[k:] - y[:-k]
    v1, vk = float(np.var(d1)), float(np.var(dk))
    if v1 <= 0:
        return {"status": "flat", "n": int(len(y))}
    Q = (vk - v1) / (k - 1)
    R = (v1 - Q) / 2.0
    vr = vk / (k * v1)
    if Q <= 0:  # k-step variance below 1-step variance: noise dominated; keep a tiny level drift
        Q = v1 * 1e-3
        R = (v1 - Q) / 2.0
    if R <= 0:  # no transient component: random walk, fair value == spot
        R = 0.0
    # steady-state Kalman gain
    P = Q
    for _ in range(500):
        Pp = P + Q
        K = Pp / (Pp + R) if (Pp + R) > 0 else 1.0
        P_new = (1 - K) * Pp
        if abs(P_new - P) < 1e-18:
            P = P_new
            break
        P = P_new
    Pp = P + Q
    K = Pp / (Pp + R) if (Pp + R) > 0 else 1.0
    mu_arr = np.empty(len(y), dtype=float)
    mu = float(y[0])
    mu_arr[0] = mu
    for idx in range(1, len(y)):
        mu = mu + K * (float(y[idx]) - mu)
        mu_arr[idx] = mu
    resid = float(y[-1] - mu)
    sigma_dev = math.sqrt(R + P) if (R + P) > 0 else 0.0
    half_life = (math.log(0.5) / math.log(1 - K)) if 0 < K < 1 else 0.0
    out: Dict[str, Any] = {
        "status": "ok", "n": int(len(y)), "Q": Q, "R": R, "K": K, "vr_k": vr, "k": k,
        "mu": float(mu), "last": float(y[-1]), "deviation": float(resid),
        "sigma_dev": sigma_dev, "deviation_sigma": (resid / sigma_dev) if sigma_dev > 0 else 0.0,
        "half_life_steps": half_life, "noise_share": (2 * R / v1) if v1 > 0 else 0.0,
    }
    if include_series:
        out["mu_series"] = mu_arr
        out["z_series"] = ((y - mu_arr) / sigma_dev) if sigma_dev > 0 else np.zeros_like(y)
    return out


def rolling_variance_ratio(y: np.ndarray, k: int = 4, window: int = 48) -> np.ndarray:
    """Rolling Lo-MacKinlay variance ratio VR(k) = Var(y_t - y_{t-k}) / (k * Var(y_t - y_{t-1})).
    VR < 0.85 indicates mean-reversion (batch overshoot / noise); VR > 1.15 indicates momentum/trend."""
    y = np.asarray(y, dtype=float)
    n = len(y)
    k = max(2, int(k))
    w = max(3 * k, int(window))
    vr_out = np.full(n, np.nan, dtype=float)
    if n < w + 1:
        return vr_out
    d1 = np.diff(y)
    dk = y[k:] - y[:-k]
    for i in range(w, n):
        s1 = d1[i - w:i]
        sk = dk[max(0, i - k - w + k):i - k + 1]
        v1 = float(np.var(s1)) if len(s1) > 2 else 0.0
        vk = float(np.var(sk)) if len(sk) > 2 else 0.0
        if v1 > 1e-18 and vk > 0:
            vr_out[i] = vk / (k * v1)
    return vr_out


def ar1_half_life(x: np.ndarray) -> Optional[float]:
    x = np.asarray(x, float)
    x = x[np.isfinite(x)]
    if len(x) < 30:
        return None
    a, b = x[:-1] - x[:-1].mean(), x[1:] - x[1:].mean()
    den = float(np.dot(a, a))
    if den <= 0:
        return None
    phi = float(np.dot(a, b) / den)
    return (math.log(0.5) / math.log(phi)) if 0 < phi < 1 else None


def asset_series(asset: str, days: int = 7, con=None) -> Dict[str, Any]:
    """Regular log-price grid: recorder 5-min if it covers >= MIN_RECORDER_DAYS, else GT hourly."""
    from lib.tools.quant import market_db as mdb
    now = int(time.time())
    own = con is None
    try:
        con = con or mdb.connect()
        pts = mdb.spot_series(con, asset, now - days * 86400, now, 300)
        if pts and (pts[-1][0] - pts[0][0]) >= MIN_RECORDER_DAYS * 86400:
            arr = np.array(pts, dtype=float)
            return {"status": "ok", "t": arr[:, 0], "logp": np.log(arr[:, 1]), "step_s": 300, "source": "pool_recorder_5m",
                    "spot": float(arr[-1, 1])}
    except Exception:
        pass
    finally:
        if own and con is not None:
            try:
                con.close()
            except Exception:
                pass
    from lib.tools.quant.market_data import load_series
    s = load_series(asset, "hour")
    if s.get("status") != "ok":
        return {"status": "unavailable", "reason": s.get("reason")}
    g = s["grid"]
    c = np.asarray(g["c"], float)
    ok = np.isfinite(c) & (c > 0)
    return {"status": "ok", "t": np.asarray(g["t"], float)[ok], "logp": np.log(c[ok]), "step_s": 3600,
            "source": "geckoterminal_1h", "spot": float(s["pool"]["price_ada"])}


def horizon_sigmas(logp: np.ndarray, step_s: int) -> Dict[str, Optional[float]]:
    out: Dict[str, Optional[float]] = {}
    for name, h_s in (("sigma_1h", 3600), ("sigma_24h", 86400)):
        h = max(1, int(round(h_s / step_s)))
        if len(logp) > 3 * h:
            out[name] = float(np.std(logp[h:] - logp[:-h]))
        else:
            out[name] = None
    return out


def stable_fair_value(asset: str, spot: Optional[float], days: int = 7, con=None,
                      series: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    from lib.tools.quant import market_db as mdb
    peg = STABLES.get(asset.upper())
    if peg is None:
        return {"status": "not_stable"}
    own = con is None
    con = con or mdb.connect()
    try:
        now = int(time.time())
        cex = mdb.latest_cex(con, "ADA-USD")
        if not cex or now - int(cex["ts"]) > 900:
            return {"status": "unavailable", "reason": "no Coinbase ADA-USD tick in the last 15 minutes"}
        fv = peg / float(cex["price"])
        cx = dict((int(t), p) for t, p in mdb.cex_series(con, "ADA-USD", now - days * 86400, now, 300))
        if series and series.get("status") == "ok":
            pool = list(zip(series["t"], np.exp(series["logp"])))
            step = int(series["step_s"])
        else:
            pool = mdb.spot_series(con, asset, now - days * 86400, now, 300)
            step = 300
        dev = np.array([math.log(p) - math.log(peg / cx[int(t)]) for t, p in pool if int(t) in cx and cx[int(t)] > 0])
        out: Dict[str, Any] = {"status": "ok", "fair_value": fv, "ada_usd": float(cex["price"]), "cex_age_s": now - int(cex["ts"]),
                               "n": int(len(dev))}
        if spot:
            out["deviation"] = math.log(spot / fv)
        if len(dev) >= 48:
            sd = float(np.std(dev))
            hl = ar1_half_life(dev)
            out.update({"sigma_dev": sd, "mean_dev": float(np.mean(dev)),
                        "half_life_h": (hl * step / 3600.0) if hl else None, "step_s": step})
            if spot and sd > 0:
                out["deviation_sigma"] = (out["deviation"] - out["mean_dev"]) / sd
        else:
            out["note"] = "fewer than 48 aligned pool/CEX points: deviation sigma not estimated yet"
        return out
    finally:
        if own:
            con.close()


def fair_value(asset: str, days: int = 7) -> Dict[str, Any]:
    asset = asset.upper()
    s = asset_series(asset, days)
    if s.get("status") != "ok":
        return {"status": "unavailable", "asset": asset, "reason": s.get("reason")}
    k = int(round(86400 / s["step_s"]))
    try:
        from lib.tools.quant import market_db as mdb
        _c = mdb.connect()
        fresh = mdb.fresh_pool_state(_c, asset)
        _c.close()
        if fresh and fresh.get("spot"):
            s["spot"] = float(fresh["spot"])
            s["logp"] = np.append(s["logp"], math.log(s["spot"])) if s["source"] != "pool_recorder_5m" else s["logp"]
    except Exception:
        pass
    ll = local_level(s["logp"], k)
    sig = horizon_sigmas(s["logp"], s["step_s"])
    out: Dict[str, Any] = {"status": "ok", "asset": asset, "source": s["source"], "spot": s["spot"], **sig}
    if ll.get("status") == "ok":
        out["s2"] = {"fair_value": math.exp(ll["mu"]), "deviation_sigma": ll["deviation_sigma"],
                     "sigma_dev": ll["sigma_dev"], "noise_share": ll["noise_share"], "vr_24h": ll["vr_k"],
                     "half_life_h": ll["half_life_steps"] * s["step_s"] / 3600.0, "K": ll["K"]}
    else:
        out["s2"] = {"status": ll.get("status"), "fair_value": None}
    if asset in STABLES:
        out["s3"] = stable_fair_value(asset, s["spot"], days, series=s)
    return out


def main() -> None:
    import argparse
    ap = argparse.ArgumentParser(description="Kalman / CEX-peg fair value")
    ap.add_argument("--asset", required=True)
    ap.add_argument("--days", type=int, default=7)
    a = ap.parse_args()
    try:
        res = fair_value(a.asset, max(2, min(a.days, 60)))
    except Exception as e:
        res = {"status": "error", "message": f"{type(e).__name__}: {e}"}
    print(json.dumps(res, indent=2, default=float))


if __name__ == "__main__":
    main()
