#!/usr/bin/env python3
"""Walk-forward calibration of limit-order fill probabilities.

For every origin bar t (after a warm-up window) and each relative level d above (sell) or below
(buy) the close, the model predicts P(price touches the level within H bars) using ONLY bars <= t.
The prediction is compared with what actually happened in bars t+1..t+H. This answers the question
"when the forecaster says 60%, does it fill ~60% of the time?" without look-ahead.

Methods scored:
  closed_form  first-passage probability with horizon-consistent sigma (as the forecaster uses)
  empirical    historical touch frequency in the trailing window (as the forecaster uses)
  blend        median of the two

Realized touches use bar highs/lows, which are trade execution prices. A trade price on a CPMM pool
includes the swap fee, so a high can overstate the pool spot by up to ~fee. `--touch-haircut` (default
= pool fee 0.3%) requires the high to exceed the level by that much, the conservative definition of
"the batcher could have filled us".
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any, Dict, List, Sequence

import numpy as np

_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from lib.tools.quant import market_data as md  # noqa: E402
from lib.tools.quant import models as qm  # noqa: E402


def _horizon_sigma(lc: np.ndarray, H: int, fallback: float) -> float:
    if H <= 1 or len(lc) <= H + 10:
        return fallback
    d = lc[H:] - lc[:-H]
    return float(np.std(d, ddof=1) / math.sqrt(H))


def _empirical(h: np.ndarray, l: np.ndarray, c: np.ndarray, log_d: float, H: int, direction: str) -> float | None:
    n = len(c)
    if n <= H + 5:
        return None
    hits = 0
    tot = 0
    for i in range(0, n - H):
        lvl = c[i] * math.exp(log_d)
        if direction == "sell":
            hits += bool(np.max(h[i + 1:i + 1 + H]) >= lvl)
        else:
            hits += bool(np.min(l[i + 1:i + 1 + H]) <= lvl)
        tot += 1
    return hits / tot if tot else None


def calibrate(o, h, l, c, direction: str = "sell", levels_pct: Sequence[float] = (0.5, 1.0, 2.0, 3.0, 5.0),
              horizons: Sequence[int] = (6, 24, 72), warmup: int = 336, step: int = 6,
              touch_haircut: float = 0.003, window: int = 336, pred_haircut: float = 0.0) -> Dict[str, Any]:
    o, h, l, c = (np.asarray(x, dtype=float) for x in (o, h, l, c))
    n = len(c)
    sign = 1.0 if direction == "sell" else -1.0
    recs: List[Dict[str, Any]] = []
    for t in range(warmup, n - max(horizons) - 1, step):
        lo = max(0, t - window)
        wo, wh, wl, wc = o[lo:t + 1], h[lo:t + 1], l[lo:t + 1], c[lo:t + 1]
        lc = np.log(wc)
        rets = np.diff(lc)
        sigma = float(np.std(rets, ddof=1)) if len(rets) > 10 else 0.0
        if sigma <= 0:
            continue
        for pct in levels_pct:
            log_d = sign * math.log(1 + pct / 100.0)
            lvl = c[t] * math.exp(log_d)
            log_dp = log_d + sign * math.log(1 + pred_haircut)
            for H in horizons:
                sH = _horizon_sigma(lc, H, sigma)
                cf = qm.gbm_hit_probability(log_dp, sH, H, 0.0)
                emp = _empirical(wh, wl, wc, log_dp, H, direction)
                fut_h, fut_l = h[t + 1:t + 1 + H], l[t + 1:t + 1 + H]
                if direction == "sell":
                    hit_raw = bool(np.max(fut_h) >= lvl)
                    hit_cons = bool(np.max(fut_h) >= lvl * (1 + touch_haircut))
                else:
                    hit_raw = bool(np.min(fut_l) <= lvl)
                    hit_cons = bool(np.min(fut_l) <= lvl * (1 - touch_haircut))
                vals = [v for v in (cf, emp) if v is not None]
                recs.append({"t": t, "pct": pct, "H": H, "closed_form": cf, "empirical": emp,
                             "blend": float(np.median(vals)) if vals else None,
                             "hit_raw": hit_raw, "hit_conservative": hit_cons})
    return summarize(recs)


def _reliability(p: np.ndarray, y: np.ndarray, bins: int = 5) -> List[Dict[str, Any]]:
    out = []
    edges = np.linspace(0, 1, bins + 1)
    for i in range(bins):
        m = (p >= edges[i]) & (p < edges[i + 1] if i < bins - 1 else p <= edges[i + 1])
        if m.sum() >= 5:
            out.append({"bin": f"{edges[i]:.1f}-{edges[i + 1]:.1f}", "n": int(m.sum()),
                        "mean_pred": round(float(p[m].mean()), 3), "realized": round(float(y[m].mean()), 3)})
    return out


def summarize(recs: List[Dict[str, Any]]) -> Dict[str, Any]:
    if not recs:
        return {"status": "insufficient_data"}
    res: Dict[str, Any] = {"status": "ok", "n_predictions": len(recs), "by_cell": [], "overall": {}}
    for target in ("hit_conservative", "hit_raw"):
        res["overall"][target] = {}
        for m in ("closed_form", "empirical", "blend"):
            rr = [r for r in recs if r[m] is not None]
            p = np.array([r[m] for r in rr])
            y = np.array([1.0 if r[target] else 0.0 for r in rr])
            base = float(y.mean())
            brier = float(np.mean((p - y) ** 2))
            brier_clim = float(np.mean((base - y) ** 2))
            res["overall"][target][m] = {
                "brier": round(brier, 4),
                "brier_skill_vs_base_rate": round(1 - brier / brier_clim, 3) if brier_clim > 0 else None,
                "mean_pred": round(float(p.mean()), 3), "realized": round(base, 3),
                "reliability": _reliability(p, y),
            }
    cells = sorted({(r["pct"], r["H"]) for r in recs})
    for pct, H in cells:
        rr = [r for r in recs if r["pct"] == pct and r["H"] == H]
        y = np.array([1.0 if r["hit_conservative"] else 0.0 for r in rr])
        yr = np.array([1.0 if r["hit_raw"] else 0.0 for r in rr])
        row = {"level_pct": pct, "H": H, "n": len(rr), "realized_conservative": round(float(y.mean()), 3),
               "realized_raw": round(float(yr.mean()), 3)}
        for m in ("closed_form", "empirical", "blend"):
            vals = [r[m] for r in rr if r[m] is not None]
            row[f"pred_{m}"] = round(float(np.mean(vals)), 3) if vals else None
        res["by_cell"].append(row)
    return res


def main() -> None:
    ap = argparse.ArgumentParser(description="Walk-forward calibration of fill probabilities")
    ap.add_argument("--asset", required=True)
    ap.add_argument("--direction", default="sell", choices=["sell", "buy"])
    ap.add_argument("--levels", default="0.5,1,2,3,5", help="comma-separated % distances")
    ap.add_argument("--horizons", default="6,24,72")
    ap.add_argument("--touch-haircut", type=float, default=0.003)
    ap.add_argument("--pred-haircut", type=float, default=0.0, help="also widen the predicted distance by this")
    ap.add_argument("--step", type=int, default=6)
    a = ap.parse_args()
    s = md.load_series(a.asset.upper(), "hour", 1)
    if s.get("status") != "ok":
        print(json.dumps({"status": "error", "message": s.get("reason")}))
        return
    g = s["grid"]
    out = calibrate(g["o"], g["h"], g["l"], g["c"], a.direction,
                    [float(x) for x in a.levels.split(",")], [int(x) for x in a.horizons.split(",")],
                    step=a.step, touch_haircut=a.touch_haircut, pred_haircut=a.pred_haircut)
    out.update({"asset": a.asset.upper(), "direction": a.direction, "bars": len(g["c"]),
                "coverage": s.get("coverage"), "pool": s["pool"].get("pool_address"),
                "touch_haircut": a.touch_haircut})
    print(json.dumps(qm.json_safe(out), indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
