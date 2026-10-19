#!/usr/bin/env python3
"""
P4 signal / shadow-simulator / impact / backtest checks (offline). Prints "<name> PASS|FAIL <detail>".

Databases and the policy live in a temp dir; GeckoTerminal is injected (gt_loader), nothing
touches the network or the chain.
"""
from __future__ import annotations

import copy
import json
import math
import os
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

TMP = Path(tempfile.mkdtemp(prefix="george-signals-"))
os.environ["GEORGE_DIR"] = str(TMP / ".george")
os.environ["FINANCE_DIR"] = str(TMP / ".george" / "finance")
os.environ["TRADING_DB_PATH"] = str(TMP / "trading.db")
os.environ["MARKET_DB_PATH"] = str(TMP / "market.db")
os.environ["ESCALATIONS_DB_PATH"] = str(TMP / "escalations.db")
os.environ["TRADING_POLICY_PATH"] = str(TMP / "trading_policy.json")
os.environ["GEORGE_CONFIG_DIR"] = str(TMP / "nokeys")
os.environ["ESCALATION_NO_BUS"] = "1"
for k in ("CARDANO_TEST_MODE", "DISCORD_BOT_TOKEN", "DISCORD_OPERATOR_ID"):
    os.environ.pop(k, None)
Path(os.environ["FINANCE_DIR"]).mkdir(parents=True, exist_ok=True)

import numpy as np  # noqa: E402

from lib.tools.quant import backtest, impact, market_db as mdb, signals  # noqa: E402
from lib.tools.trading import gates, policy, store  # noqa: E402

POLICY = copy.deepcopy(policy.DEFAULT_POLICY)
Path(os.environ["TRADING_POLICY_PATH"]).write_text(json.dumps(POLICY))
POL = policy.load_policy()
FEE = 0.003
FIXED = signals.fixed_fees(POL)
NW = float(POL["fees"]["network_fee_ada"])
RESULTS = []


def check(name):
    def deco(fn):
        try:
            ok, detail = fn()
        except Exception as e:
            import traceback
            ok, detail = False, f"{type(e).__name__}: {e} @ {traceback.format_exc().splitlines()[-3].strip()}"
        RESULTS.append(ok)
        print(f"{name} {'PASS' if ok else 'FAIL'} {detail}")
        return fn
    return deco


def sim(ts, lo, hi, cl, **kw):
    args = dict(t0=0.0, entry_price=1.0, size_ada=100.0, exit_target=1.05, fill_deadline=50.0, hold_s=1000.0,
                fee=FEE, fixed_ada=FIXED, network_fee=NW)
    args.update(kw)
    return signals.simulate_path(ts, lo, hi, cl, **args)


@check("sim_limit_fill_then_close")
def _():
    trig = 1.0 * (1 - FEE) * (1 - signals.HAIRCUT_BPS / 1e4)
    r = sim([10, 20, 30], [trig - 1e-6, 1.0, 1.0], [1.0, 1.0, 1.2], [1.0, 1.0, 1.1])
    want = 100.0 * 1.05 - 100.0 - FIXED
    return (r["status"] == "closed" and r["filled_at"] == 10 and abs(r["net_pnl_ada"] - want) < 1e-9,
            json.dumps(r))


@check("sim_touch_without_haircut_is_not_a_fill")
def _():
    touch = 1.0 * (1 - FEE)  # exactly the trigger without the haircut
    r = sim([10, 20, 60], [touch, touch, touch], [1.0] * 3, [1.0] * 3)
    return r["status"] == "unfilled" and abs(r["net_pnl_ada"] + 2 * NW) < 1e-9, json.dumps(r)


@check("sim_resting_until_deadline_known")
def _():
    r = sim([10, 20], [1.0, 1.0], [1.0, 1.0], [1.0, 1.0], known_until=30)
    return r["status"] == "resting", json.dumps(r)


@check("sim_no_exit_on_fill_bar")
def _():
    trig = (1 - FEE) * (1 - signals.HAIRCUT_BPS / 1e4)
    r = sim([10, 20], [trig - 0.01, 1.0], [2.0, 1.0], [1.0, 1.0], known_until=20)
    return r["status"] == "filled", json.dumps(r)


@check("sim_timeout_marks_to_market")
def _():
    trig = (1 - FEE) * (1 - signals.HAIRCUT_BPS / 1e4)
    r = sim([10, 500, 1100], [trig - 0.01, 0.9, 0.9], [1.0, 1.0, 1.0], [0.97, 0.95, 0.95], hold_s=600.0)
    tokens = 100.0
    want = tokens * 0.95 * (1 - FEE) - 100.0 - FIXED
    return r["status"] == "timeout" and abs(r["net_pnl_ada"] - want) < 1e-9, json.dumps(r)


@check("sim_break_even_floor_on_exit")
def _():
    # target below break-even: the exit is lifted to break-even x 1.003
    r = sim([0, 10, 20], [1.0, 1.0, 1.0], [1.0, 1.0, 1.5], [1.0] * 3, entry_mode="market", exit_target=0.5)
    be = (100.0 + FIXED) / 100.0
    return (r["status"] == "closed" and abs(r["exit_price"] - be * 1.003) < 1e-12 and r["net_pnl_ada"] > 0,
            json.dumps(r))


@check("impact_recovers_impulse_response")
def _():
    rng = np.random.default_rng(1)
    n = 5000
    f = np.where(rng.random(n) < 0.1, rng.normal(0, 0.002, n), 0.0)
    r = np.zeros(n)
    tr = 0.0
    for t in range(n):
        prev = tr
        tr = 0.9 * tr + f[t]
        r[t] = f[t] + (tr - prev) + rng.normal(0, 1e-4)
    fit = impact.fit_arx(r, f)
    s = impact.summarize_irf(impact.impulse_response(fit["b"], fit["a"]))
    ok = abs(s["peak"] - 2) < 0.1 and abs(s["reversion_fraction"] - 0.5) < 0.1 and 0.3 < (s["half_life_h"] or 0) < 0.9
    return ok, json.dumps(s)


@check("impact_insufficient_data_and_cache")
def _():
    res = impact.run(["SNEK"])
    c = impact.cached("SNEK")
    return (res["SNEK"]["status"] == "insufficient_data" and c and c["status"] == "insufficient_data"
            and signals.impact_half_life_h("SNEK") is None), json.dumps(res["SNEK"])


@check("backtest_kalman_is_causal")
def _():
    rng = np.random.default_rng(3)
    y = np.cumsum(rng.normal(0, 0.01, 500))
    y2 = y.copy()
    y2[300:] += 0.5
    a, b = backtest.kalman_path(y, 0.2), backtest.kalman_path(y2, 0.2)
    return bool(np.allclose(a[:300], b[:300]) and not np.allclose(a[300:], b[300:])), "prefix unchanged"


def _seed_market(asset="TEST", reserve=2_000_000.0, now=None, fee_bps=30.0):
    now = now or int(time.time())
    con = mdb.connect()
    mdb.record_snapshot(con, now - 60, f"pool_{asset}", asset, reserve, reserve, fee_bps=fee_bps, tx="seed")
    con.execute("INSERT OR REPLACE INTO recorder_state(pool, asset, last_checked) VALUES (?,?,?)",
                (f"pool_{asset}", asset, now))
    con.commit()
    con.close()


def _equity(v=400.0):
    con = store.connect()
    con.execute("INSERT OR REPLACE INTO equity VALUES (?,?,?,?,?)", (int(time.time()), v, v, 0.0, "{}"))
    con.commit()
    con.close()


def _gt_series(closes, lows, highs, t0):
    t = t0 + 3600 * np.arange(len(closes))
    return {"status": "ok", "grid": {"t": t, "o": closes, "h": highs, "l": lows, "c": closes,
                                     "traded": np.ones(len(closes), bool)}}


@check("backtest_s2_walk_forward_mean_reverting")
def _():
    _equity()
    _seed_market("TEST")
    rng = np.random.default_rng(7)
    n = 24 * 25
    lvl = np.cumsum(rng.normal(0, 0.003, n))
    trans = np.zeros(n)
    for i in range(1, n):
        trans[i] = 0.6 * trans[i - 1] + (-0.06 if rng.random() < 0.04 else 0.0)
    logp = lvl + trans
    c = np.exp(logp)
    lo, hi = c * 0.999, c * 1.001
    for i in range(1, n):
        lo[i] = min(lo[i], c[i - 1])
        hi[i] = max(hi[i], c[i - 1])
    t0 = (int(time.time()) // 3600) * 3600 - n * 3600
    out = backtest.run([backtest.S2], ["TEST"], record=True, gt_loader=lambda a, tf: _gt_series(c, lo, hi, t0))
    st = out["strategies"][backtest.S2]
    con = store.connect()
    bt = gates.latest_backtest(con, backtest.S2)
    con.close()
    s = st["stats"]
    v = st["variants"].get("market") or {}
    # a fast-reverting shock is mostly missed by a resting limit below the post-shock spot, but a
    # market entry captures it: the backtester must show both, and record the policy's (limit) run
    ok = v.get("n", 0) >= 10 and (v.get("mean") or 0) > 0 and (s.get("n", 0) == 0 or (bt and bt["run_id"] == st["run_id"])) \
        and st["params"]["sources"] == ["geckoterminal_1h"] and st["params"]["entry_mode"] == "limit"
    return ok, json.dumps({"limit": {k: s.get(k) for k in ("n", "mean", "fill_rate", "signals")},
                           "market": {k: v.get(k) for k in ("n", "mean", "lower80", "signals")}})


@check("backtest_s2_random_walk_has_no_edge")
def _():
    rng = np.random.default_rng(11)
    n = 24 * 25
    c = np.exp(np.cumsum(rng.normal(0, 0.01, n)))
    lo, hi = c * 0.999, c * 1.001
    for i in range(1, n):
        lo[i] = min(lo[i], c[i - 1])
        hi[i] = max(hi[i], c[i - 1])
    t0 = (int(time.time()) // 3600) * 3600 - n * 3600
    out = backtest.run([backtest.S2], ["TEST"], record=False, gt_loader=lambda a, tf: _gt_series(c, lo, hi, t0))
    s = out["strategies"][backtest.S2]["stats"]
    v = out["strategies"][backtest.S2]["variants"].get("market") or {}

    def no_edge(x):
        return x.get("n", 0) == 0 or x.get("lower80") is None or x["lower80"] <= 0.0
    # costs make a pure random walk lose on average; Gate 1 (lower80 > -0.5 AND mean > 0) must not
    # pass with confidence on it
    ok = no_edge(s) and no_edge(v) and v.get("n", 0) >= 5
    return ok, json.dumps({"limit": {k: s.get(k) for k in ("n", "mean", "lower80")},
                           "market": {k: v.get(k) for k in ("n", "mean", "lower80")}})


@check("backtest_s3_needs_cex_history")
def _():
    _seed_market("USDM", reserve=3_000_000.0, fee_bps=30.0)
    n = 24 * 10
    c = np.full(n, 4.0)
    t0 = (int(time.time()) // 3600) * 3600 - n * 3600
    out = backtest.run([backtest.S3], ["USDM"], record=False, gt_loader=lambda a, tf: _gt_series(c, c, c, t0))
    r = out["strategies"][backtest.S3]["assets"]["USDM"]
    return r.get("status") == "insufficient_data" and "cex" in (r.get("reason") or "").lower(), json.dumps(r)


@check("backtest_s3_reverting_discount_trades")
def _():
    rng = np.random.default_rng(5)
    n = 24 * 12
    t0 = (int(time.time()) // 3600) * 3600 - n * 3600
    con = mdb.connect()
    ada_usd = 0.25 * np.exp(np.cumsum(rng.normal(0, 0.004, n)))
    for i in range(n):
        ts = int(t0 + 3600 * (i + 1))
        for j in range(12):
            b = ts - 3600 + 300 * j
            con.execute("INSERT OR REPLACE INTO cex_bars_5m VALUES (?,?,?,?,?,?,?)",
                        (b, "ADA-USD", ada_usd[i], ada_usd[i], ada_usd[i], ada_usd[i], 1))
    con.commit()
    con.close()
    dev = np.zeros(n)
    for i in range(1, n):
        dev[i] = 0.5 * dev[i - 1] + (-0.05 if rng.random() < 0.05 else 0.0) + rng.normal(0, 0.001)
    c = (1.0 / ada_usd) * np.exp(dev)
    lo, hi = c.copy(), c.copy()
    for i in range(1, n):
        lo[i] = min(c[i], c[i - 1])
        hi[i] = max(c[i], c[i - 1])
    out = backtest.run([backtest.S3], ["USDM"], record=False, gt_loader=lambda a, tf: _gt_series(c, lo, hi, t0))
    s = out["strategies"][backtest.S3]["stats"]
    a = out["strategies"][backtest.S3]["assets"]["USDM"]
    return s.get("n", 0) >= 3 and (s.get("mean") or 0) > 0, json.dumps({"stats": {k: s.get(k) for k in ("n", "mean", "signals")},
                                                                       "asset": {k: a.get(k) for k in ("status", "reason", "size_ada", "fee", "cex_points")}})


@check("scan_warming_up_then_s2_signal_with_cooldown")
def _():
    now = int(time.time())
    con = mdb.connect()
    con.execute("DELETE FROM pool_snapshots WHERE asset='SHK'")
    rng = np.random.default_rng(2)
    ra, rt = 1_000_000.0, 1_000_000.0
    asset = "SHK"
    # 1 day only -> warming up
    for i in range(288):
        ts = now - 86400 + i * 300
        k = ra * rt
        ra *= math.exp(rng.normal(0, 0.001) / 2)
        rt = k / ra
        mdb.record_snapshot(con, ts, "pool_SHK", asset, ra, rt, fee_bps=30.0, tx=f"w{i}")
    con.execute("INSERT OR REPLACE INTO recorder_state(pool, asset, last_checked) VALUES (?,?,?)", ("pool_SHK", asset, now))
    con.commit()
    POL2 = copy.deepcopy(POL)
    POL2["recorder"] = {"pools": [asset]}
    Path(os.environ["TRADING_POLICY_PATH"]).write_text(json.dumps(POL2))
    r1 = signals.scan([asset], now=now)
    warm = r1["assets"][asset]["S2"]["status"] == "warming_up"
    # 4 days of history, then a big ADA-out batch (price down 10%)
    con.execute("DELETE FROM pool_snapshots WHERE asset=?", (asset,))
    ra, rt = 1_000_000.0, 1_000_000.0
    for i in range(4 * 288):
        ts = now - 4 * 86400 + i * 300
        k = ra * rt
        ra *= math.exp(rng.normal(0, 0.001) / 2)
        rt = k / ra
        mdb.record_snapshot(con, ts, "pool_SHK", asset, ra, rt, fee_bps=30.0, tx=f"h{i}")
    pre = ra
    out_ada = ra * 0.05
    k = ra * rt
    ra -= out_ada
    rt = k / ra
    mdb.record_snapshot(con, now - 30, "pool_SHK", asset, ra, rt, fee_bps=30.0, tx="shock")
    mdb.record_swaps(con, [{"tx": "shock", "idx": 0, "ts": now - 30, "pool": "pool_SHK", "asset": asset,
                            "kind": "batch", "side": "sell", "ada_amt": out_ada, "tok_amt": 0.0,
                            "impact_pct": -10.0}])
    con.commit()
    con.close()
    r2 = signals.scan([asset], now=now)
    r3 = signals.scan([asset], now=now + 60)
    s2 = r2["assets"][asset]["S2"]
    n2 = [x for x in r2["new_signals"] if x["strategy"] == "S2_shock_fade"]
    n3 = [x for x in r3["new_signals"] if x["strategy"] == "S2_shock_fade"]
    tcon = store.connect()
    rows = tcon.execute("SELECT status, note FROM sim_trades WHERE asset=?", (asset,)).fetchall()
    tcon.close()
    Path(os.environ["TRADING_POLICY_PATH"]).write_text(json.dumps(POL))
    ok = warm and s2.get("triggered") and len(n2) == 1 and not n3 and len(rows) == 1 \
        and "live" not in n2[0] and rows[0]["note"].startswith("signal")
    return ok, json.dumps({"warm": warm, "s2": {k: s2.get(k) for k in ("status", "deviation_sigma", "n_shocks")},
                           "n2": len(n2), "n3": len(n3), "rows": len(rows), "pre": round(pre)})


print(f"SUMMARY {sum(RESULTS)}/{len(RESULTS)}")
sys.exit(0 if all(RESULTS) else 1)
