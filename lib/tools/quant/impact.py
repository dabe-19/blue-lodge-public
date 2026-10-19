#!/usr/bin/env python3
"""
Impulse-response study of pool price to signed swap flow (plan P4, "impact.py").

Model (ARX, 5-minute grid from the pool recorder):
    r_t = c + sum_{l=0..L} b_l f_{t-l} + sum_{p=1..P} a_p r_{t-p} + e_t
  r_t  log return of the exact AMM spot over (t-5m, t]
  f_t  signed batch flow in the same interval as a fraction of the pre-trade ADA reserve
       (+ = ADA into the pool = price up; - = ADA out of the pool = price down)

The cumulative impulse response to a unit flow shock gives:
  peak       immediate log-price move per unit flow (b_0; ~2 for a constant-product pool)
  permanent  cumulative move after H steps (information content of the flow)
  reversion  1 - permanent / peak (share of the move that is transient)
  half_life  hours until the transient part has halved

These set the S2 shock-fade timeouts (2 x half-life) and say whether fading shocks is plausible at
all (reversion ~ 0 means the flow is information, not noise -> S2 has no edge on that pool).

Only exact recorder data is used: there is no fallback to coarse bars (flow cannot be signed there),
so a pool with too little history reports status 'insufficient_data'.

CLI: impact.py run [--assets A,B] [--days 30] | show [--assets A,B]
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

import numpy as np  # noqa: E402

STEP_S = 300
LAGS = 36         # flow lags (3 h): long enough to see a typical transient decay
AR = 2            # return lags
HORIZON = 288     # impulse response horizon (24 h)
MIN_BARS = 3 * 288
MIN_FLOW_BARS = 40
CACHE_MAX_AGE_S = 3 * 86400


def _finance_dir() -> Path:
    lodge = Path(os.environ.get("LODGE_DIR", _REPO_ROOT))
    george = Path(os.environ.get("GEORGE_DIR", lodge / ".george"))
    return Path(os.environ.get("FINANCE_DIR", george / "finance"))


def cache_path(asset: str) -> Path:
    return _finance_dir() / f"impact_{asset.upper()}.json"


def signed_flow(mcon, asset: str, since: int, until: int) -> Dict[int, float]:
    """{grid_end_ts: signed flow / pre-trade reserve} from batch rows (idx 0 = net pool move)."""
    out: Dict[int, float] = {}
    q = ("SELECT s.ts, s.side, s.ada_amt, p.reserve_ada FROM swaps s LEFT JOIN pool_snapshots p "
         "ON p.asset=s.asset AND p.tx=s.tx WHERE s.asset=? AND s.kind='batch' AND s.idx=0 AND s.ts>? AND s.ts<=?")
    for ts, side, ada, post in mcon.execute(q, (asset.upper(), since, until)):
        if not ada or not post or side not in ("buy", "sell"):
            continue
        ada, post = float(ada), float(post)
        pre = post + ada if side == "sell" else post - ada
        if pre <= 0:
            continue
        key = int(math.ceil(int(ts) / STEP_S) * STEP_S)
        out[key] = out.get(key, 0.0) + (ada / pre if side == "buy" else -ada / pre)
    return out


def fit_arx(r: np.ndarray, f: np.ndarray, lags: int = LAGS, ar: int = AR) -> Dict[str, Any]:
    """OLS fit of the ARX model; returns coefficients and their standard errors."""
    n = len(r)
    m = max(lags, ar)
    if n - m < 10 + lags + ar:
        return {"status": "insufficient_data", "n": int(n)}
    cols = [np.ones(n - m)]
    for l in range(lags + 1):
        cols.append(f[m - l:n - l])
    for p in range(1, ar + 1):
        cols.append(r[m - p:n - p])
    X = np.column_stack(cols)
    y = r[m:]
    beta, *_ = np.linalg.lstsq(X, y, rcond=None)
    resid = y - X @ beta
    dof = max(1, len(y) - X.shape[1])
    s2 = float(resid @ resid) / dof
    try:
        cov = s2 * np.linalg.pinv(X.T @ X)
        se = np.sqrt(np.clip(np.diag(cov), 0, None))
    except np.linalg.LinAlgError:
        se = np.full(len(beta), np.nan)
    ss_tot = float(((y - y.mean()) ** 2).sum())
    return {"status": "ok", "n": int(len(y)), "c": float(beta[0]),
            "b": [float(x) for x in beta[1:lags + 2]], "b_se": [float(x) for x in se[1:lags + 2]],
            "a": [float(x) for x in beta[lags + 2:]], "a_se": [float(x) for x in se[lags + 2:]],
            "r2": (1 - float(resid @ resid) / ss_tot) if ss_tot > 0 else 0.0, "resid_sd": math.sqrt(s2)}


def impulse_response(b: List[float], a: List[float], horizon: int = HORIZON) -> np.ndarray:
    """Cumulative log-price response to a unit flow at t=0."""
    r = np.zeros(horizon)
    for t in range(horizon):
        v = b[t] if t < len(b) else 0.0
        for p, ap in enumerate(a, start=1):
            if t - p >= 0:
                v += ap * r[t - p]
        r[t] = v
    return np.cumsum(r)


def summarize_irf(cum: np.ndarray, step_s: int = STEP_S) -> Dict[str, Any]:
    peak_i = int(np.argmax(np.abs(cum[:12])))  # the peak is within the first hour
    peak = float(cum[peak_i])
    perm = float(cum[-1])
    out: Dict[str, Any] = {"peak": peak, "permanent": perm, "peak_step": peak_i}
    if abs(peak) < 1e-12:
        out.update({"reversion_fraction": None, "half_life_h": None})
        return out
    out["reversion_fraction"] = float(1 - perm / peak)
    transient0 = peak - perm
    hl = None
    if abs(transient0) > 1e-12 and np.sign(transient0) == np.sign(peak):
        for i in range(peak_i, len(cum)):
            if abs(cum[i] - perm) <= 0.5 * abs(transient0):
                hl = (i - peak_i) * step_s / 3600.0
                break
    out["half_life_h"] = hl
    return out


def analyze(asset: str, mcon=None, days: int = 30, now: Optional[int] = None) -> Dict[str, Any]:
    from lib.tools.quant import market_db as mdb
    now = int(now or time.time())
    own = mcon is None
    mcon = mcon or mdb.connect()
    try:
        since = now - days * 86400
        pts = mdb.spot_series(mcon, asset, since, now, STEP_S)
        if len(pts) < MIN_BARS:
            return {"asset": asset.upper(), "status": "insufficient_data", "bars": len(pts), "need_bars": MIN_BARS,
                    "ts": now}
        arr = np.array(pts, float)
        t = arr[:, 0].astype(np.int64)
        logp = np.log(arr[:, 1])
        r = np.diff(logp)
        tt = t[1:]
        flow_map = signed_flow(mcon, asset, int(t[0]), int(t[-1]))
        f = np.array([flow_map.get(int(x), 0.0) for x in tt])
        n_flow = int((f != 0).sum())
        if n_flow < MIN_FLOW_BARS:
            return {"asset": asset.upper(), "status": "insufficient_data", "bars": len(pts), "flow_bars": n_flow,
                    "need_flow_bars": MIN_FLOW_BARS, "ts": now}
        fit = fit_arx(r, f)
        if fit["status"] != "ok":
            return {"asset": asset.upper(), **fit, "ts": now}
        cum = impulse_response(fit["b"], fit["a"])
        s = summarize_irf(cum)
        out = {"asset": asset.upper(), "status": "ok", "ts": now, "days": round((t[-1] - t[0]) / 86400.0, 2),
               "bars": len(pts), "flow_bars": n_flow, "fit": fit, **s,
               "irf_cum": [round(float(x), 6) for x in cum[[0, 1, 3, 6, 12, 36, 72, 144, 287]]],
               "irf_steps": [0, 1, 3, 6, 12, 36, 72, 144, 287],
               "note": ("transient share of a flow shock; S2 needs reversion_fraction well above 0 "
                        "and a half-life shorter than the hold")}
        return out
    finally:
        if own:
            mcon.close()


def run(assets: Optional[List[str]] = None, days: int = 30) -> Dict[str, Any]:
    from lib.tools.quant import market_db as mdb
    from lib.tools.trading import policy
    from lib.tools.quant.signals import recorder_pools
    pol = policy.load_policy()
    assets = [a.upper() for a in (assets or recorder_pools(pol))]
    mcon = mdb.connect()
    out: Dict[str, Any] = {}
    try:
        for a in assets:
            try:
                res = analyze(a, mcon, days)
            except Exception as e:
                res = {"asset": a, "status": "error", "reason": f"{type(e).__name__}: {e}"}
            out[a] = res
            try:
                p = cache_path(a)
                p.parent.mkdir(parents=True, exist_ok=True)
                tmp = p.with_suffix(".tmp")
                tmp.write_text(json.dumps(res, default=str))
                tmp.replace(p)
            except OSError:
                pass
    finally:
        mcon.close()
    return out


def cached(asset: str, max_age_s: int = CACHE_MAX_AGE_S) -> Optional[Dict[str, Any]]:
    """Latest analysis from disk (None when missing or older than max_age_s)."""
    p = cache_path(asset)
    try:
        d = json.loads(p.read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(d, dict) or time.time() - float(d.get("ts") or 0) > max_age_s:
        return None
    return d


def main() -> None:
    ap = argparse.ArgumentParser(description="Pool impulse response to signed swap flow")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("run")
    s.add_argument("--assets", default="")
    s.add_argument("--days", type=int, default=30)
    s = sub.add_parser("show")
    s.add_argument("--assets", default="")
    a = ap.parse_args()
    assets = [x.strip().upper() for x in a.assets.split(",") if x.strip()] or None
    try:
        if a.cmd == "run":
            out: Any = run(assets, a.days)
        else:
            from lib.tools.trading import policy
            from lib.tools.quant.signals import recorder_pools
            out = {x: cached(x) for x in (assets or recorder_pools(policy.load_policy()))}
    except Exception as e:
        out = {"status": "error", "reason": f"{type(e).__name__}: {str(e)[:300]}"}
    print(json.dumps(out, default=str))


if __name__ == "__main__":
    main()
