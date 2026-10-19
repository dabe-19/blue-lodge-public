#!/usr/bin/env python3
"""
S2 / S3 signal detection and the shadow simulator (grill-me Q3/Q8, plan P4).

S2 shock fade (all recorded pools):
  trigger  Kalman deviation (spot - FV) / sigma_dev <= -k (k = 2.0 to start) AND a batch in the
           last 15 min pushed the price down while moving >= min_swap_reserve_pct of the ADA reserve
  entry    resting limit BUY at post-shock spot x exp(-entry_offset_sigma x sigma_1h)
  exit     max(FV, break-even x 1.003) limit SELL
  timeout  the buy is reclaimed after 2 x impact half-life (clipped 1-24 h); a filled position is
           marked to market after 72 h
S3 stablecoin deviation (USDM / USDCX / DJED):
  trigger  pool price below 1/ADAUSD by more than round-trip fees + k x sigma_dev
  entry    market buy (pays the pool fee); exit at parity (limit SELL at FV)

Shadow simulator: every signal (and every plan action of a 'simulated' strategy) is a row in
trading.db sim_trades. update_sims() scores them against the exact pool spot path recorded in
market.db: a limit order counts as filled only if spot traded THROUGH its trigger by a haircut
(HAIRCUT_BPS, for batcher competition / queue position), and every leg pays the real fixed fees
(2 ADA batcher + 0.2 ADA network) plus the pool fee where it applies. Rows are finalised only
once the recorder has checked the pool past the decision time (no stale guesses).

Live strategies: when a strategy's effective state is 'live' (Gate 1 + operator unlock), a signal
also builds a buy plan; it executes only if an operator standing order covers it, otherwise the
plan is escalated (Tier B). Simulated strategies only journal.

CLI: signals.py scan [--emit] [--assets A,B] | update | latest [--assets A,B]
"""
from __future__ import annotations

import argparse
import json
import math
import os
import secrets
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

HAIRCUT_BPS = 10.0
SHOCK_LOOKBACK_S = 900
S2_COOLDOWN_S = 2 * 3600
S3_COOLDOWN_S = 6 * 3600
HOLD_S = 72 * 3600
MIN_HISTORY_DAYS = 3


def recorder_pools(pol: Dict[str, Any]) -> List[str]:
    return [str(a).upper() for a in ((pol.get("recorder") or {}).get("pools") or [])]


# ---------------------------------------------------------------------------
# Trade path simulator (shared with the backtester)
# ---------------------------------------------------------------------------

def fixed_fees(pol: Dict[str, Any]) -> float:
    f = pol["fees"]
    return 2 * (float(f["max_batcher_fee_ada"]) + float(f["network_fee_ada"]))


def simulate_path(ts: Sequence[float], lows: Sequence[float], highs: Sequence[float], closes: Sequence[float],
                  t0: float, entry_price: float, size_ada: float, exit_target: Optional[float],
                  fill_deadline: float, hold_s: float, fee: float, fixed_ada: float, network_fee: float,
                  entry_mode: str = "limit", known_until: Optional[float] = None,
                  haircut_bps: float = HAIRCUT_BPS) -> Dict[str, Any]:
    """Scores one hypothetical round trip on a price path (bars or step-function points).

    Limit buy: fills when low <= entry x (1 - fee) x (1 - haircut); tokens = size / entry.
    Market buy: fills at t0 at entry (callers pass spot / (1 - fee)).
    Exit: limit sell at max(exit_target, break-even x 1.003); fills when high >= exit / (1 - fee) x
    (1 + haircut) strictly after the fill. Otherwise marked to market at close x (1 - fee) when the
    hold expires. Unfilled limit buys cost the place + reclaim network fees.
    """
    h = haircut_bps / 1e4
    end = float(known_until if known_until is not None else (ts[-1] if len(ts) else t0))
    out: Dict[str, Any] = {"status": "resting"}
    fill_i = None
    if entry_mode == "market":
        fill_t = t0
        fill_i = max([i for i, t in enumerate(ts) if t <= t0] or [0]) if len(ts) else None
    else:
        trig = entry_price * (1 - fee) * (1 - h)
        for i, t in enumerate(ts):
            if t < t0:
                continue
            if t > fill_deadline:
                break
            if lows[i] <= trig:
                fill_i = i
                break
        if fill_i is None:
            if end >= fill_deadline:
                return {"status": "unfilled", "net_pnl_ada": -2 * network_fee, "fees_ada": 2 * network_fee,
                        "exit_at": int(fill_deadline)}
            return out
        fill_t = ts[fill_i]
    tokens = size_ada / entry_price
    be = (size_ada + fixed_ada) / tokens
    exit_px = max(exit_target or 0.0, be * 1.003)
    out.update({"status": "filled", "filled_at": int(fill_t), "tokens": tokens, "exit_price_target": exit_px})
    sell_trig = exit_px / (1 - fee) * (1 + h)
    hold_end = fill_t + hold_s
    start = (fill_i + 1) if (fill_i is not None and entry_mode != "market") else 0
    last_close = None
    for j in range(start, len(ts)):
        t = ts[j]
        if t <= fill_t:
            last_close = closes[j]
            continue
        if t > hold_end:
            break
        last_close = closes[j]
        if highs[j] >= sell_trig:
            out.update({"status": "closed", "exit_at": int(t), "exit_price": exit_px,
                        "net_pnl_ada": tokens * exit_px - size_ada - fixed_ada, "fees_ada": fixed_ada})
            return out
    if end >= hold_end and last_close:
        px = last_close * (1 - fee)
        out.update({"status": "timeout", "exit_at": int(hold_end), "exit_price": px,
                    "net_pnl_ada": tokens * px - size_ada - fixed_ada, "fees_ada": fixed_ada})
    return out


# ---------------------------------------------------------------------------
# Data helpers
# ---------------------------------------------------------------------------

def _pool_path(mcon, asset: str, since: int, until: int) -> Dict[str, List[float]]:
    """Exact AMM spot step path: the last snapshot before `since` plus every snapshot after."""
    asset = asset.upper()
    rows = []
    r0 = mcon.execute("SELECT ts, spot FROM pool_snapshots WHERE asset=? AND ts<? ORDER BY ts DESC LIMIT 1",
                      (asset, since)).fetchone()
    if r0:
        rows.append((since, float(r0[1])))
    else:
        b0 = mcon.execute("SELECT bucket, c FROM pool_bars_5m WHERE asset=? AND bucket<? ORDER BY bucket DESC LIMIT 1",
                          (asset, since)).fetchone()
        if b0:
            rows.append((since, float(b0[1])))
    for t, l, hi, c in mcon.execute("SELECT bucket + 299, l, h, c FROM pool_bars_5m WHERE asset=? AND bucket>=? AND bucket<=? "
                                    "AND bucket < COALESCE((SELECT MIN(ts) FROM pool_snapshots WHERE asset=?), 1e12) ORDER BY bucket",
                                    (asset, since, until, asset)):
        rows.append((int(t), (float(l), float(hi), float(c))))
    for t, s in mcon.execute("SELECT ts, spot FROM pool_snapshots WHERE asset=? AND ts>=? AND ts<=? ORDER BY ts",
                             (asset, since, until)):
        rows.append((int(t), float(s)))
    rows.sort(key=lambda x: x[0])
    ts, lo, hi, cl = [], [], [], []
    for t, v in rows:
        if isinstance(v, tuple):
            lo.append(v[0]); hi.append(v[1]); cl.append(v[2])
        else:
            lo.append(v); hi.append(v); cl.append(v)
        ts.append(float(t))
    return {"ts": ts, "lows": lo, "highs": hi, "closes": cl}


def _known_until(mcon, asset: str) -> Optional[int]:
    r = mcon.execute("SELECT MAX(last_checked) FROM recorder_state WHERE asset=?", (asset.upper(),)).fetchone()
    return int(r[0]) if r and r[0] else None


def _fee_frac(mcon, asset: str, pol: Dict[str, Any]) -> float:
    r = mcon.execute("SELECT fee_bps FROM pool_snapshots WHERE asset=? AND fee_bps IS NOT NULL ORDER BY ts DESC LIMIT 1",
                     (asset.upper(),)).fetchone()
    return float(r[0] if r and r[0] is not None else pol["fees"]["default_pool_fee_bps"]) / 1e4


def min_viable_s2_ada(entry: float, target: float, pol: Dict[str, Any]) -> Optional[float]:
    """Smallest bet (ADA) for which target >= break-even * (1 + exit_floor_markup).
    Below this size, fixed batcher/tx fees push the break-even exit floor above Fair Value,
    forcing a limit sell to require an overshoot beyond Fair Value."""
    if not entry or not target or entry <= 0 or target <= 0:
        return None
    markup = float((pol.get("strategies") or {}).get("S1_inventory_exit", {}).get("exit_floor_markup", 0.003))
    denom = float(target) / (float(entry) * (1.0 + markup)) - 1.0
    if denom <= 1e-6:
        return None
    return round(fixed_fees(pol) / denom, 2)


def _sim_size(con, mcon, asset: str, pol: Dict[str, Any], entry: Optional[float] = None,
              target: Optional[float] = None) -> float:
    snap = mcon.execute("SELECT reserve_ada FROM pool_snapshots WHERE asset=? ORDER BY ts DESC LIMIT 1",
                        (asset.upper(),)).fetchone()
    reserve_ada = float(snap[0]) if snap else 0.0
    impact_cap = (float(pol["capital"]["max_pool_impact_pct"]) / 100.0) * reserve_ada
    eq = con.execute("SELECT equity_ada FROM equity ORDER BY ts DESC LIMIT 1").fetchone()
    working = (float(eq[0]) - pol["wallet"]["floor_ada"] - pol["wallet"]["fee_buffer_ada"]) if eq else 100.0
    cap = max(0.0, float(pol["capital"]["max_position_fraction"]) * working)
    if entry is not None and target is not None:
        mv = min_viable_s2_ada(entry, target, pol)
        s2_pct = float((pol.get("strategies") or {}).get("S2_shock_fade", {}).get("min_swap_reserve_pct", 0.10))
        s2_cap = min(impact_cap, (s2_pct / 100.0) * reserve_ada) if reserve_ada > 0 else 0.0
        if mv is None or (s2_cap > 0 and mv > s2_cap):
            return 0.0
        desired = max(cap, round(mv * 1.05, 2))
        size = min(s2_cap, desired) if s2_cap > 0 else 0.0
    else:
        size = min(impact_cap, cap) if impact_cap > 0 else 0.0
    return round(size, 2) if size >= float(pol["capital"]["min_order_ada"]) else 0.0


def impact_half_life_h(asset: str) -> Optional[float]:
    try:
        from lib.tools.quant import impact
        r = impact.cached(asset)
        return r.get("half_life_h") if r and r.get("status") == "ok" else None
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------

def _recent_signal(con, strategy: str, asset: str, within_s: int, now: int) -> bool:
    r = con.execute("SELECT 1 FROM sim_trades WHERE strategy=? AND asset=? AND created_at>=? AND note LIKE 'signal%' LIMIT 1",
                    (strategy, asset.upper(), now - within_s)).fetchone()
    return bool(r)


def detect_s2(asset: str, mcon, pol: Dict[str, Any], now: Optional[int] = None) -> Dict[str, Any]:
    import numpy as np
    from lib.tools.quant import fair_value as fvm
    from lib.tools.quant import market_db as mdb
    now = int(now or time.time())
    p = pol["strategies"]["S2_shock_fade"]
    pts = mdb.spot_series(mcon, asset, now - 7 * 86400, now, 300)
    if not pts or pts[-1][0] - pts[0][0] < MIN_HISTORY_DAYS * 86400:
        return {"status": "warming_up", "reason": f"< {MIN_HISTORY_DAYS} days of recorder history"}
    arr = np.array(pts, float)
    logp = np.log(arr[:, 1])
    fresh = mdb.fresh_pool_state(mcon, asset)
    if not fresh:
        return {"status": "stale", "reason": "recorder has not checked this pool in 15 min"}
    logp = np.append(logp, math.log(float(fresh["spot"])))
    ll = fvm.local_level(logp, 288)
    if ll.get("status") != "ok":
        return {"status": ll.get("status")}
    sig = fvm.horizon_sigmas(logp, 300)
    dev = ll["deviation_sigma"]
    fv = math.exp(ll["mu"])
    spot = float(fresh["spot"])
    entry_est = spot * math.exp(-float(p.get("entry_offset_sigma", 0.25)) * float(sig.get("sigma_1h") or 0.0))
    mv_ada = min_viable_s2_ada(entry_est, fv, pol)
    out: Dict[str, Any] = {"status": "ok", "deviation_sigma": dev, "fair_value": fv,
                           "spot": spot, "sigma_1h": sig.get("sigma_1h"), "sigma_24h": sig.get("sigma_24h"),
                           "model_half_life_h": ll["half_life_steps"] * 300 / 3600.0,
                           "min_viable_ada": mv_ada, "triggered": False}
    shocks = []
    for r in mcon.execute("SELECT s.tx, s.ts, s.ada_amt, s.impact_pct, p.reserve_ada FROM swaps s LEFT JOIN pool_snapshots p "
                          "ON p.asset=s.asset AND p.tx=s.tx WHERE s.asset=? AND s.kind='batch' AND s.idx=0 AND s.ts>=? "
                          "AND s.impact_pct < 0", (asset.upper(), now - SHOCK_LOOKBACK_S)):
        post_res = r[4]
        if not post_res or not r[2]:
            continue
        pre_res = float(post_res) + float(r[2])
        pct = float(r[2]) / pre_res * 100.0
        if pct >= float(p["min_swap_reserve_pct"]):
            shocks.append({"tx": r[0], "ts": r[1], "ada": r[2], "reserve_pct": pct, "impact_pct": r[3]})
    out["shocks"] = shocks
    out["triggered"] = bool(shocks) and dev <= -float(p["k_sigma"])
    return out


def detect_s3(asset: str, mcon, pol: Dict[str, Any], con=None) -> Dict[str, Any]:
    from lib.tools.quant import fair_value as fvm
    from lib.tools.quant import market_db as mdb
    p = pol["strategies"]["S3_stable_deviation"]
    if asset.upper() not in [a.upper() for a in p.get("assets", [])]:
        return {"status": "not_applicable"}
    fresh = mdb.fresh_pool_state(mcon, asset)
    if not fresh:
        return {"status": "stale", "reason": "recorder has not checked this pool in 15 min"}
    s3 = fvm.stable_fair_value(asset, float(fresh["spot"]), 7, con=mcon)
    if s3.get("status") != "ok" or s3.get("sigma_dev") is None:
        return {"status": "warming_up", "reason": s3.get("reason") or s3.get("note")}
    fee = _fee_frac(mcon, asset, pol)
    size = _sim_size(con, mcon, asset, pol) if con is not None else 100.0
    fee_log = 2 * fee + (fixed_fees(pol) / size if size else 1.0)
    dev = s3["deviation"] - s3.get("mean_dev", 0.0)
    thr = fee_log + float(p["k_sigma"]) * float(s3["sigma_dev"])
    # exit at parity adjusted by the pool's persistent premium/discount (the level it reverts to)
    target = float(s3["fair_value"]) * math.exp(float(s3.get("mean_dev", 0.0)))
    return {"status": "ok", "spot": float(fresh["spot"]), "fair_value": s3["fair_value"], "target": target,
            "deviation": dev,
            "threshold": thr, "sigma_dev": s3["sigma_dev"], "half_life_h": s3.get("half_life_h"),
            "triggered": dev <= -thr, "side": "buy" if dev < 0 else "sell", "fee": fee, "size_ada": size}


# ---------------------------------------------------------------------------
# Scan: record signals as shadow trades (and act on live strategies)
# ---------------------------------------------------------------------------

def _insert_sim(con, strategy: str, asset: str, now: int, signal: Dict[str, Any], entry: float, size: float,
                exit_target: Optional[float], fill_deadline: int, note: str) -> str:
    sid = f"SIM-{secrets.token_hex(4).upper()}"
    con.execute("INSERT INTO sim_trades(sim_id, strategy, asset, created_at, signal_json, side, entry_price, size_ada,"
                " exit_target, timeout_at, status, note) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                (sid, strategy, asset.upper(), now, json.dumps(signal, default=str), "buy", float(entry), float(size),
                 exit_target, int(fill_deadline), "resting", note))
    con.commit()
    return sid


def _act_live(con, pol, strategy: str, asset: str, entry: float, size: float, reason: str) -> Dict[str, Any]:
    """Live strategy: build a buy plan; execute only under an operator standing order."""
    from lib.tools.trading import plans
    p = plans.build_plan({"kind": "buy", "asset": asset, "budget_ada": size, "price": entry, "strategy": strategy,
                          "reason": reason}, origin=f"signal:{strategy}", con=con, pol=pol)
    if p["status"] != "proposed":
        return {"plan_id": p["plan_id"], "status": p["status"]}
    covered = all(a.get("blocked") or plans.standing_cover(con, a) for a in p["actions"])
    if covered:
        r = plans.execute_plan(p["plan_id"], actor="george", con=con, pol=pol)
        return {"plan_id": p["plan_id"], "status": r.get("status"), "via": "standing_order"}
    try:
        from lib.comms import escalation
        escalation.raise_escalation(f"trading/{strategy.lower()}", asset,
                                    f"{strategy} signal on {asset}: {reason}. Buy {size:.0f} ADA at {entry:.6g}?",
                                    plan_id=p["plan_id"], source="signals")
    except Exception:
        pass
    return {"plan_id": p["plan_id"], "status": "escalated"}


def scan(assets: Optional[List[str]] = None, emit: bool = False, now: Optional[int] = None) -> Dict[str, Any]:
    from lib.tools.quant import market_db as mdb
    from lib.tools.trading import policy, store
    pol = policy.load_policy()
    now = int(now or time.time())
    assets = [a.upper() for a in (assets or recorder_pools(pol))]
    con, mcon = store.connect(), mdb.connect()
    out: Dict[str, Any] = {"ts": now, "assets": {}, "new_signals": []}
    try:
        states = policy.strategy_states(con, pol)
        for asset in assets:
            res: Dict[str, Any] = {}
            try:
                s2 = detect_s2(asset, mcon, pol, now)
            except Exception as e:
                s2 = {"status": "error", "reason": f"{type(e).__name__}: {e}"}
            res["S2"] = {k: v for k, v in s2.items() if k != "shocks"} | {"n_shocks": len(s2.get("shocks") or [])}
            if s2.get("triggered") and states.get("S2_shock_fade") != "disabled" \
                    and not _recent_signal(con, "S2_shock_fade", asset, S2_COOLDOWN_S, now):
                p2 = pol["strategies"]["S2_shock_fade"]
                mode = "market" if p2.get("entry_mode") == "market" else "limit"
                spot_s2 = float(s2["spot"])
                fv_s2 = float(s2["fair_value"])
                if mode == "market":
                    entry = spot_s2 / (1 - _fee_frac(mcon, asset, pol))
                else:
                    entry = spot_s2 * math.exp(-float(p2["entry_offset_sigma"]) * float(s2.get("sigma_1h") or 0.0))
                size = _sim_size(con, mcon, asset, pol, entry=entry, target=fv_s2)
                mv = min_viable_s2_ada(entry, fv_s2, pol)
                hl = float(impact_half_life_h(asset) or s2.get("model_half_life_h") or 6.0)
                deadline = now + (3600 if mode == "market" else int(min(24.0, max(1.0, 2 * hl)) * 3600))
                sig = {"source": "signal", "kind": "s2_shock", "deviation_sigma": s2["deviation_sigma"],
                       "fair_value": fv_s2, "min_viable_ada": mv, "shocks": s2["shocks"][:3],
                       "hold_s": HOLD_S, "half_life_h": hl, "entry_mode": mode}
                if size > 0:
                    sid = _insert_sim(con, "S2_shock_fade", asset, now, sig, entry, size, fv_s2, deadline,
                                      "signal S2 shock fade")
                    rec = {"strategy": "S2_shock_fade", "asset": asset, "sim_id": sid, "entry": entry,
                           "size_ada": size, "min_viable_ada": mv}
                    if states.get("S2_shock_fade") == "live":
                        live_cap = _sim_size(con, mcon, asset, pol)
                        if mv is None or live_cap >= mv:
                            rec["live"] = _act_live(con, pol, "S2_shock_fade", asset, entry, min(size, live_cap),
                                                    f"shock: deviation {s2['deviation_sigma']:+.1f} sigma")
                    out["new_signals"].append(rec)
                    if emit:
                        _emit("cardano/s2_shock", rec)
            try:
                s3 = detect_s3(asset, mcon, pol, con)
            except Exception as e:
                s3 = {"status": "error", "reason": f"{type(e).__name__}: {e}"}
            if s3.get("status") != "not_applicable":
                res["S3"] = s3
                if s3.get("triggered") and s3.get("size_ada") and states.get("S3_stable_deviation") != "disabled" \
                        and not _recent_signal(con, "S3_stable_deviation", asset, S3_COOLDOWN_S, now):
                    spot_s3 = float(s3["spot"])
                    fee_s3 = float(s3["fee"])
                    entry = spot_s3 / (1 - fee_s3)
                    hl = float(s3.get("half_life_h") or 12.0)
                    sig = {"source": "signal", "kind": "s3_deviation", "deviation": s3["deviation"],
                           "threshold": s3["threshold"], "fair_value": s3["fair_value"], "entry_mode": "market",
                           "hold_s": int(min(72.0, max(2.0, 2 * hl)) * 3600)}
                    s3_size = float(s3["size_ada"])
                    s3_target = float(s3["target"]) if s3.get("target") is not None else None
                    sid = _insert_sim(con, "S3_stable_deviation", asset, now, sig, entry, s3_size,
                                      s3_target, now + 3600, "signal S3 stable deviation")
                    rec = {"strategy": "S3_stable_deviation", "asset": asset, "sim_id": sid, "entry": entry,
                           "size_ada": s3_size}
                    if states.get("S3_stable_deviation") == "live":
                        rec["live"] = _act_live(con, pol, "S3_stable_deviation", asset, entry,
                                                s3_size, f"stable {float(s3['deviation']) * 100:+.2f}% vs 1/ADAUSD")
                    out["new_signals"].append(rec)
                    if emit:
                        _emit("cardano/s3_deviation", rec)
            out["assets"][asset] = res
        out["shadow"] = update_sims(con, mcon, pol, now)
        return out
    finally:
        con.close()
        mcon.close()


def _emit(event: str, payload: Dict[str, Any]) -> None:
    try:
        from lib.tools.cardano_order_watcher import emit_event_to_bus
        emit_event_to_bus(event, payload, source="signals")
    except Exception:
        pass


def update_sims(con, mcon, pol, now: Optional[int] = None) -> Dict[str, int]:
    """Scores resting/filled shadow trades against the recorded pool path."""
    now = int(now or time.time())
    counts = {"checked": 0, "filled": 0, "closed": 0, "timeout": 0, "unfilled": 0, "no_data": 0}
    fixed = fixed_fees(pol)
    nw = float(pol["fees"]["network_fee_ada"])
    for r in con.execute("SELECT * FROM sim_trades WHERE status IN ('resting','filled')").fetchall():
        counts["checked"] += 1
        try:
            sig = json.loads(r["signal_json"] or "{}")
        except ValueError:
            sig = {}
        known = _known_until(mcon, r["asset"])
        if not known:
            counts["no_data"] += 1
            continue
        path = _pool_path(mcon, r["asset"], int(r["created_at"]), min(now, known))
        if not path["ts"]:
            counts["no_data"] += 1
            continue
        fee = _fee_frac(mcon, r["asset"], pol)
        res = simulate_path(path["ts"], path["lows"], path["highs"], path["closes"], float(r["created_at"]),
                            float(r["entry_price"]), float(r["size_ada"]), r["exit_target"], float(r["timeout_at"]),
                            float(sig.get("hold_s") or HOLD_S), fee, fixed, nw,
                            entry_mode=sig.get("entry_mode", "limit"), known_until=min(now, known))
        st = res["status"]
        if st == "resting":
            continue
        con.execute("UPDATE sim_trades SET status=?, filled_at=?, exit_at=?, exit_price=?, net_pnl_ada=?, fees_ada=? "
                    "WHERE sim_id=?", (st, res.get("filled_at"), res.get("exit_at"), res.get("exit_price"),
                                       res.get("net_pnl_ada"), res.get("fees_ada"), r["sim_id"]))
        if st in counts and st != r["status"]:
            counts[st] += 1
    con.commit()
    return counts


def latest(assets: Optional[List[str]] = None, hours: float = 24.0) -> Dict[str, List[Dict[str, Any]]]:
    """Recent signals per asset (for crypto_scan)."""
    from lib.tools.trading import store
    con = store.connect()
    try:
        since = int(time.time() - hours * 3600)
        out: Dict[str, List[Dict[str, Any]]] = {}
        q = "SELECT sim_id, strategy, asset, created_at, entry_price, size_ada, exit_target, status, net_pnl_ada, note " \
            "FROM sim_trades WHERE created_at>=? ORDER BY created_at DESC LIMIT 200"
        for r in con.execute(q, (since,)):
            if assets and r["asset"] not in [a.upper() for a in assets]:
                continue
            out.setdefault(r["asset"], []).append({k: r[k] for k in r.keys()})
        return out
    finally:
        con.close()


def main() -> None:
    ap = argparse.ArgumentParser(description="S2/S3 signals + shadow simulator")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scan")
    s.add_argument("--emit", action="store_true")
    s.add_argument("--assets", default="")
    sub.add_parser("update")
    s = sub.add_parser("latest")
    s.add_argument("--assets", default="")
    a = ap.parse_args()
    assets = [x.strip().upper() for x in getattr(a, "assets", "").split(",") if x.strip()] or None
    try:
        if a.cmd == "scan":
            out: Any = scan(assets, emit=a.emit)
        elif a.cmd == "update":
            from lib.tools.quant import market_db as mdb
            from lib.tools.trading import policy, store
            con, mcon = store.connect(), mdb.connect()
            try:
                out = update_sims(con, mcon, policy.load_policy())
            finally:
                con.close()
                mcon.close()
        else:
            out = latest(assets)
    except Exception as e:
        out = {"status": "error", "reason": f"{type(e).__name__}: {str(e)[:300]}"}
    print(json.dumps(out, default=str))


if __name__ == "__main__":
    main()
