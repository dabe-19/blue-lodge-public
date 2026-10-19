#!/usr/bin/env python3
"""
Walk-forward backtester for S2 (shock fade) and S3 (stablecoin deviation) — plan P4, Gate 1 input.

Protocol (no look-ahead):
  * data is split into rolling windows: train TRAIN_DAYS -> test TEST_DAYS, stepping TEST_DAYS
  * on each train window the model is fitted (S2: local-level Kalman gain + sigma; S3: mean/sd/half-life
    of the pool-vs-1/ADAUSD deviation) and the trigger k is chosen from K_GRID by train P&L
    (falls back to the policy k when no candidate produced >= 2 positive-sum trips)
  * on the following test window the frozen model generates signals causally; every signal is scored
    with signals.simulate_path (the exact same fill/fee/haircut model the shadow simulator uses)
  * only test-window trips are counted; stats are per round trip (closed + timeout, as in the
    shadow sim) with the unfilled count / cost reported separately

Data: exact recorder path (pool_snapshots + 5-min bars) when it covers >= MIN_RECORDER_DAYS;
otherwise GeckoTerminal hourly OHLC (S2 then uses a price-drop proxy for the swap-size condition
because the flow cannot be signed from bars; the source is recorded with the run so the operator
sees it). S3 needs the Coinbase ADA-USD history in market.db (cex_feed.py backfill).

Results are written to trading.db `backtests` via gates.record_backtest (one row per strategy).
CLI: backtest.py run [--strategy S2|S3|all] [--assets A,B] [--no-record]
"""
from __future__ import annotations

import argparse
import json
import math
import secrets
import sys
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

import numpy as np  # noqa: E402

from lib.tools.quant import signals  # noqa: E402

TRAIN_DAYS = 3
TEST_DAYS = 1
MIN_RECORDER_DAYS = 7
K_GRID_S2 = (1.5, 2.0, 2.5, 3.0)
K_GRID_S3 = (1.0, 1.5, 2.0, 2.5)
S2 = "S2_shock_fade"
S3 = "S3_stable_deviation"


# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------

def load_path(asset: str, mcon, days: int = 30, now: Optional[int] = None,
              gt_loader: Optional[Callable[..., Dict[str, Any]]] = None) -> Dict[str, Any]:
    """{source, step_s, path{ts,lows,highs,closes}, grid_t, grid_logp} or {status: unavailable}."""
    from lib.tools.quant import market_db as mdb
    now = int(now or time.time())
    since = now - days * 86400
    pts = mdb.spot_series(mcon, asset, since, now, 300)
    if pts and pts[-1][0] - pts[0][0] >= MIN_RECORDER_DAYS * 86400:
        path = signals._pool_path(mcon, asset, int(pts[0][0]), now)
        arr = np.array(pts, float)
        return {"status": "ok", "source": "pool_recorder", "step_s": 300, "path": path,
                "grid_t": arr[:, 0], "grid_logp": np.log(arr[:, 1])}
    if gt_loader is None:
        from lib.tools.quant.market_data import load_series as gt_loader
    s = gt_loader(asset, "hour")
    if s.get("status") != "ok":
        return {"status": "unavailable", "reason": s.get("reason") or "no GeckoTerminal series"}
    g = s["grid"]
    t = np.asarray(g["t"], float)
    c = np.asarray(g["c"], float)
    ok = np.isfinite(c) & (c > 0)
    if ok.sum() < (TRAIN_DAYS + TEST_DAYS) * 24:
        return {"status": "unavailable", "reason": f"only {int(ok.sum())} hourly bars"}
    t, c = t[ok], c[ok]
    lo = np.asarray(g["l"], float)[ok]
    hi = np.asarray(g["h"], float)[ok]
    end = t + 3600  # a bar is known at its close
    return {"status": "ok", "source": "geckoterminal_1h", "step_s": 3600,
            "path": {"ts": end.tolist(), "lows": lo.tolist(), "highs": hi.tolist(), "closes": c.tolist()},
            "grid_t": end, "grid_logp": np.log(c)}


def shock_times(mcon, asset: str, min_reserve_pct: float) -> List[int]:
    """Timestamps of price-down batches that moved >= min_reserve_pct of the pre-trade ADA reserve."""
    out = []
    q = ("SELECT s.ts, s.ada_amt, p.reserve_ada FROM swaps s LEFT JOIN pool_snapshots p ON p.asset=s.asset "
         "AND p.tx=s.tx WHERE s.asset=? AND s.kind='batch' AND s.idx=0 AND s.impact_pct < 0 ORDER BY s.ts")
    for ts, ada, post in mcon.execute(q, (asset.upper(),)):
        if ada and post and float(ada) / (float(post) + float(ada)) * 100.0 >= min_reserve_pct:
            out.append(int(ts))
    return out


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

def kalman_path(y: np.ndarray, K: float) -> np.ndarray:
    """Posterior level mu_t after observing y_t (steady-state gain K), causal."""
    mu = np.empty_like(y)
    m = y[0]
    for i, obs in enumerate(y):
        m = m + K * (obs - m)
        mu[i] = m
    return mu


def _window_masks(t: np.ndarray, start: float, end: float):
    return (t >= start) & (t < end)


def _stats(trips: List[Dict[str, Any]]) -> Dict[str, Any]:
    from lib.tools.trading import journal
    done = [x for x in trips if x["status"] in ("closed", "timeout")]
    s = journal.describe(x["net_pnl_ada"] for x in done)
    unf = [x for x in trips if x["status"] == "unfilled"]
    s.update({"signals": len(trips), "unfilled": len(unf), "unfilled_cost_ada": sum(x["net_pnl_ada"] for x in unf),
              "fill_rate": (len(done) / (len(done) + len(unf))) if (done or unf) else None,
              "timeouts": sum(1 for x in done if x["status"] == "timeout")})
    return s


def _score(sim_fn, sigs: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    out = []
    for s in sigs:
        r = sim_fn(s)
        if r["status"] in ("closed", "timeout", "unfilled"):
            out.append({**s, **r})
    return out


def s2_signals(d: Dict[str, Any], shocks: List[int], K: float, sigma_dev: float, sigma_1h: float, k: float,
               start: float, end: float, p: Dict[str, Any], hl_h: float, mode: str = "limit",
               fee: float = 0.0) -> List[Dict[str, Any]]:
    t, y = d["grid_t"], d["grid_logp"]
    mu = kalman_path(y, K)
    dev = (y - mu) / sigma_dev if sigma_dev > 0 else np.zeros_like(y)
    step = d["step_s"]
    drop_thr = 2 * float(p["min_swap_reserve_pct"]) / 100.0  # CPMM: a swap of x% of reserve moves price ~2x%
    sigs, last = [], -1e18
    sh = np.array(shocks, float)
    for i in range(1, len(t)):
        ti = float(t[i])
        if ti < start or ti >= end or dev[i] > -k or ti - last < signals.S2_COOLDOWN_S:
            continue
        if d["source"] == "pool_recorder":
            ok = bool(len(sh)) and bool(((sh > ti - signals.SHOCK_LOOKBACK_S) & (sh <= ti)).any())
        else:
            ok = (y[i] - y[i - 1]) <= -drop_thr
        if not ok:
            continue
        spot = math.exp(y[i])
        if mode == "market":
            entry, deadline = spot / (1 - fee), ti + 3600
        else:
            entry = spot * math.exp(-float(p["entry_offset_sigma"]) * sigma_1h)
            deadline = ti + min(24.0, max(1.0, 2 * hl_h)) * 3600
        sigs.append({"t0": ti + 1, "entry": entry, "target": math.exp(mu[i]), "deadline": deadline,
                     "hold_s": signals.HOLD_S, "mode": mode, "dev_sigma": float(dev[i]), "step": step})
        last = ti
    return sigs


def s3_signals(d: Dict[str, Any], cex: Dict[int, float], peg: float, mean_dev: float, sd: float, hl_h: float,
               k: float, fee: float, fixed: float, size: float, start: float, end: float) -> List[Dict[str, Any]]:
    t, y = d["grid_t"], d["grid_logp"]
    step = d["step_s"]
    thr = 2 * fee + fixed / size + k * sd
    sigs, last = [], -1e18
    for i in range(len(t)):
        ti = float(t[i])
        if ti < start or ti >= end or ti - last < signals.S3_COOLDOWN_S:
            continue
        cx = cex.get(int(ti - ti % step))
        if not cx:
            continue
        fv = peg / cx
        dev = y[i] - math.log(fv) - mean_dev
        if dev > -thr:
            continue
        spot = math.exp(y[i])
        sigs.append({"t0": ti, "entry": spot / (1 - fee), "target": fv * math.exp(mean_dev), "deadline": ti + 3600,
                     "hold_s": int(min(72.0, max(2.0, 2 * hl_h)) * 3600), "mode": "market", "dev": float(dev)})
        last = ti
    return sigs


# ---------------------------------------------------------------------------
# Walk-forward drivers
# ---------------------------------------------------------------------------

def _sim_fn(d: Dict[str, Any], size: float, fee: float, fixed: float, nw: float):
    P = d["path"]
    end = P["ts"][-1] if P["ts"] else 0

    def f(s: Dict[str, Any]) -> Dict[str, Any]:
        sz = float(s.get("size_ada") or size)
        return signals.simulate_path(P["ts"], P["lows"], P["highs"], P["closes"], s["t0"], s["entry"], sz,
                                     s["target"], s["deadline"], s["hold_s"], fee, fixed, nw,
                                     entry_mode=s["mode"], known_until=end)
    return f


def _pick_k(grid, run_k: Callable[[float], List[Dict[str, Any]]], default_k: float) -> float:
    best, best_sum = default_k, None
    for k in grid:
        tr = [x for x in run_k(k) if x["status"] in ("closed", "timeout")]
        if len(tr) < 2:
            continue
        s = sum(x["net_pnl_ada"] for x in tr)
        if s > 0 and (best_sum is None or s > best_sum):
            best, best_sum = k, s
    return best


def _filter_s2_friction(sigs: List[Dict[str, Any]], pol: Dict[str, Any], base_size: float,
                        impact_cap: float, enforce: bool) -> List[Dict[str, Any]]:
    out = []
    for sg in sigs:
        mv = signals.min_viable_s2_ada(sg["entry"], sg["target"], pol)
        sg2 = dict(sg)
        sg2["min_viable_ada"] = mv
        if enforce:
            if mv is None or (impact_cap > 0 and mv > impact_cap):
                continue
            sg2["size_ada"] = round(min(impact_cap, max(base_size, mv * 1.05)), 2)
        else:
            sg2["size_ada"] = base_size
        out.append(sg2)
    return out


def backtest_s2(asset: str, d: Dict[str, Any], mcon, pol: Dict[str, Any], size: float, fee: float,
                mode: str = "limit") -> Dict[str, Any]:
    from lib.tools.quant import fair_value as fvm
    p = pol["strategies"][S2]
    fixed = signals.fixed_fees(pol)
    nw = float(pol["fees"]["network_fee_ada"])
    t, y, step = d["grid_t"], d["grid_logp"], d["step_s"]
    snap = mcon.execute("SELECT reserve_ada FROM pool_snapshots WHERE asset=? ORDER BY ts DESC LIMIT 1",
                        (asset.upper(),)).fetchone()
    s2_pct = min(float(pol["capital"]["max_pool_impact_pct"]), float(p.get("min_swap_reserve_pct", 0.10)))
    impact_cap = (s2_pct / 100.0) * float(snap[0]) if snap else size
    enforce_friction = (d["source"] == "pool_recorder")
    shocks = shock_times(mcon, asset, float(p["min_swap_reserve_pct"])) if d["source"] == "pool_recorder" else []
    sim = _sim_fn(d, size, fee, fixed, nw)
    kk = max(2, int(86400 / step))
    hl_imp = signals.impact_half_life_h(asset)
    trips: List[Dict[str, Any]] = []
    windows = []
    s = float(t[0]) + TRAIN_DAYS * 86400
    while s + TEST_DAYS * 86400 <= float(t[-1]) + step:
        tr_mask = _window_masks(t, s - TRAIN_DAYS * 86400, s)
        ll = fvm.local_level(y[tr_mask], kk)
        if ll.get("status") != "ok" or not ll.get("sigma_dev"):
            windows.append({"test_start": int(s), "status": ll.get("status")})
            s += TEST_DAYS * 86400
            continue
        sig1h = fvm.horizon_sigmas(y[tr_mask], step).get("sigma_1h") or 0.0
        hl = hl_imp or (ll["half_life_steps"] * step / 3600.0) or 6.0
        args = (shocks, ll["K"], ll["sigma_dev"], sig1h)
        k = _pick_k(K_GRID_S2, lambda kx: _score(sim, _filter_s2_friction(
            s2_signals(d, *args, kx, s - TRAIN_DAYS * 86400, s, p, hl, mode, fee),
            pol, size, impact_cap, enforce_friction)), float(p["k_sigma"]))
        tt = _score(sim, _filter_s2_friction(
            s2_signals(d, *args, k, s, s + TEST_DAYS * 86400, p, hl, mode, fee),
            pol, size, impact_cap, enforce_friction))
        trips.extend(tt)
        windows.append({"test_start": int(s), "k": k, "K": round(ll["K"], 4), "half_life_h": round(hl, 2),
                        "trips": len(tt)})
        s += TEST_DAYS * 86400
    mvs = [float(x["min_viable_ada"]) for x in trips if x.get("min_viable_ada") is not None]
    mv_med = round(float(np.median(mvs)), 2) if mvs else None
    return {"asset": asset, "source": d["source"], "size_ada": size, "impact_cap_ada": round(impact_cap, 2),
            "min_viable_ada_median": mv_med, "fee": fee, "entry_mode": mode,
            "windows": windows, "trips": trips, "stats": _stats(trips)}


def backtest_s3(asset: str, d: Dict[str, Any], mcon, pol: Dict[str, Any], size: float, fee: float) -> Dict[str, Any]:
    from lib.tools.quant import fair_value as fvm
    from lib.tools.quant import market_db as mdb
    p = pol["strategies"][S3]
    peg = fvm.STABLES.get(asset.upper())
    if peg is None:
        return {"asset": asset, "status": "not_stable"}
    fixed = signals.fixed_fees(pol)
    nw = float(pol["fees"]["network_fee_ada"])
    t, y, step = d["grid_t"], d["grid_logp"], d["step_s"]
    cex = {int(a): float(b) for a, b in mdb.cex_series(mcon, "ADA-USD", int(t[0]) - step, int(t[-1]), step)}
    if len(cex) < (TRAIN_DAYS + TEST_DAYS) * 86400 / step * 0.5:
        return {"asset": asset, "status": "insufficient_data", "reason": "Coinbase ADA-USD history too short "
                "(run cex_feed.py backfill)", "cex_points": len(cex)}
    dev_all = np.array([y[i] - math.log(peg / cex[int(t[i] - t[i] % step)]) if cex.get(int(t[i] - t[i] % step))
                        else np.nan for i in range(len(t))])
    sim = _sim_fn(d, size, fee, fixed, nw)
    trips: List[Dict[str, Any]] = []
    windows = []
    s = float(t[0]) + TRAIN_DAYS * 86400
    while s + TEST_DAYS * 86400 <= float(t[-1]) + step:
        dv = dev_all[_window_masks(t, s - TRAIN_DAYS * 86400, s)]
        dv = dv[np.isfinite(dv)]
        if len(dv) < 48:
            windows.append({"test_start": int(s), "status": "insufficient_data"})
            s += TEST_DAYS * 86400
            continue
        mean, sd = float(np.mean(dv)), float(np.std(dv))
        hl_steps = fvm.ar1_half_life(dv)
        hl = (hl_steps * step / 3600.0) if hl_steps else 12.0
        k = _pick_k(K_GRID_S3, lambda kx: _score(sim, s3_signals(d, cex, peg, mean, sd, hl, kx, fee, fixed, size,
                                                                 s - TRAIN_DAYS * 86400, s)), float(p["k_sigma"]))
        tt = _score(sim, s3_signals(d, cex, peg, mean, sd, hl, k, fee, fixed, size, s, s + TEST_DAYS * 86400))
        trips.extend(tt)
        windows.append({"test_start": int(s), "k": k, "mean_dev": round(mean, 5), "sd": round(sd, 5),
                        "half_life_h": round(hl, 2), "trips": len(tt)})
        s += TEST_DAYS * 86400
    return {"asset": asset, "source": d["source"], "size_ada": size, "fee": fee, "windows": windows,
            "trips": trips, "stats": _stats(trips)}


def run(strategies: List[str], assets: Optional[List[str]] = None, record: bool = True, days: int = 30,
        gt_loader=None, now: Optional[int] = None) -> Dict[str, Any]:
    from lib.tools.quant import market_db as mdb
    from lib.tools.trading import gates, policy, store
    pol = policy.load_policy()
    con, mcon = store.connect(), mdb.connect()
    out: Dict[str, Any] = {"ts": int(time.time()), "strategies": {}}
    try:
        for strat in strategies:
            if strat not in pol["strategies"]:
                continue
            p = pol["strategies"][strat]
            if strat == S3:
                universe = [a.upper() for a in (assets or p.get("assets", []))
                            if a.upper() in [x.upper() for x in p.get("assets", [])]]
            else:
                universe = [a.upper() for a in (assets or signals.recorder_pools(pol))]
            mode = "market" if p.get("entry_mode") == "market" else "limit"
            alt = "limit" if mode == "market" else "market"
            per_asset, all_trips, alt_trips = {}, [], []
            t_from, t_to = None, None
            for a in universe:
                try:
                    d = load_path(a, mcon, days, now=now, gt_loader=gt_loader)
                    if d.get("status") != "ok":
                        per_asset[a] = {"status": d.get("status"), "reason": d.get("reason")}
                        continue
                    size = signals._sim_size(con, mcon, a, pol)
                    if size <= 0:
                        per_asset[a] = {"status": "skipped", "reason": "pool too thin for min order at 0.1% impact"}
                        continue
                    fee = signals._fee_frac(mcon, a, pol)
                    if strat == S2:
                        res = backtest_s2(a, d, mcon, pol, size, fee, mode)
                        res_alt = backtest_s2(a, d, mcon, pol, size, fee, alt)
                        alt_trips.extend(res_alt["trips"])
                        res["alt_stats"] = {"entry_mode": alt, **res_alt["stats"]}
                    else:
                        res = backtest_s3(a, d, mcon, pol, size, fee)
                except Exception as e:
                    per_asset[a] = {"status": "error", "reason": f"{type(e).__name__}: {e}"}
                    continue
                if "trips" in res:
                    all_trips.extend(res["trips"])
                    t0, t1 = int(d["grid_t"][0]), int(d["grid_t"][-1])
                    t_from = t0 if t_from is None else min(t_from, t0)
                    t_to = t1 if t_to is None else max(t_to, t1)
                per_asset[a] = {k: v for k, v in res.items() if k != "trips"}
            stats = _stats(all_trips)
            run_id = f"BT-{secrets.token_hex(4).upper()}"
            params = {"train_days": TRAIN_DAYS, "test_days": TEST_DAYS, "haircut_bps": signals.HAIRCUT_BPS,
                      "fixed_fees_ada": signals.fixed_fees(pol),
                      "sources": sorted({v.get("source") for v in per_asset.values() if v.get("source")})}
            if strat == S2:
                params["entry_mode"] = mode
            detail = {"assets": {a: {k: v for k, v in r.items() if k != "windows"} for a, r in per_asset.items()}}
            variants = {alt: _stats(alt_trips)} if strat == S2 else {}
            if variants:
                detail["variants"] = variants
            if record and stats.get("n", 0) > 0:
                gates.record_backtest(con, run_id, strat, stats, params, t_from, t_to, detail)
            out["strategies"][strat] = {"run_id": run_id if record and stats.get("n", 0) > 0 else None,
                                        "stats": stats, "params": params, "variants": variants,
                                        "assets": per_asset}
        return out
    finally:
        con.close()
        mcon.close()


def main() -> None:
    ap = argparse.ArgumentParser(description="Walk-forward backtest for S2/S3")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("run")
    s.add_argument("--strategy", default="all", choices=["S2", "S3", "all"])
    s.add_argument("--assets", default="")
    s.add_argument("--days", type=int, default=30)
    s.add_argument("--no-record", action="store_true")
    s.add_argument("--verbose", action="store_true", help="include per-window detail")
    a = ap.parse_args()
    strats = {"S2": [S2], "S3": [S3], "all": [S2, S3]}[a.strategy]
    assets = [x.strip().upper() for x in a.assets.split(",") if x.strip()] or None
    try:
        out: Any = run(strats, assets, record=not a.no_record, days=a.days)
        if not a.verbose:
            for st in out["strategies"].values():
                for r in st["assets"].values():
                    r.pop("windows", None)
    except Exception as e:
        out = {"status": "error", "reason": f"{type(e).__name__}: {str(e)[:300]}"}
    print(json.dumps(out, default=str))


if __name__ == "__main__":
    main()
