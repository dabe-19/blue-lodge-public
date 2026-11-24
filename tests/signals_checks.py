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


@check("sim_s1_maker_exit_stepdown")
def _():
    # 1) At 340 ADA, during first 6h ask_px honors exit_target (1.05); by day 5 it steps down to
    #    be * (1 + m_5d) (~1.0209) and closes at +2.71 ADA net instead of stalling at 1.05.
    r1 = sim(
        [0, 3600, 5 * 86400],
        [1.0, 1.0, 1.0],
        [1.0, 1.025, 1.028],
        [1.0, 1.015, 1.025],
        size_ada=340.0,
        entry_mode="market",
        exit_mode="s1_maker",
        hold_s=168 * 3600.0,
        exit_start_markup=0.015,
        exit_floor_markup=0.005,
        min_net_profit_ada=1.0,
        step_days=7.0,
    )
    # 2) At 150 ADA, day-7 floor markup (0.5% on be) would only net ~0.77 ADA, so min_net_profit_ada=1.0
    #    lifts the exit floor to strictly >= +1.00 ADA net.
    r2 = sim(
        [0, int(6.95 * 86400)],
        [1.0, 1.0],
        [1.0, 1.06],
        [1.0, 1.05],
        size_ada=150.0,
        entry_mode="market",
        exit_mode="s1_maker",
        hold_s=168 * 3600.0,
        exit_start_markup=0.015,
        exit_floor_markup=0.005,
        min_net_profit_ada=1.0,
        step_days=7.0,
    )
    ok = (
        r1["status"] == "closed"
        and r1["exit_at"] == 5 * 86400
        and r1["net_pnl_ada"] > 2.5
        and r2["status"] == "closed"
        and abs(r2["net_pnl_ada"] - 1.0) < 0.05
    )
    return ok, json.dumps({"r1_net": round(r1["net_pnl_ada"], 4), "r2_net": round(r2["net_pnl_ada"], 4)})


@check("backtest_s2_wallet_capped_s1_maker")
def _():
    # Verify wallet_cap_sizing=True + exit_mode="s1_maker" caps size at wallet max_position_fraction
    # (~340 ADA) rather than inflating to multi-thousand ADA, and scores reverting 3% dips profitably.
    _seed_market("NGT", reserve=1_200_000.0, fee_bps=30.0)
    tcon = store.connect()
    tcon.execute(
        "INSERT OR REPLACE INTO equity(ts, equity_ada, peak_ada, drawdown_pct, detail) VALUES (?,?,?,?,?)",
        (int(time.time()), 2360.0, 2360.0, 0.0, "{}"),
    )
    tcon.commit()
    tcon.close()
    POL_S1 = copy.deepcopy(POL)
    POL_S1["wallet"]["floor_ada"] = 200.0
    POL_S1["wallet"]["fee_buffer_ada"] = 32.0
    POL_S1["capital"]["max_position_fraction"] = 0.16
    POL_S1["strategies"]["S1_inventory_exit"] = {
        **POL_S1["strategies"].get("S1_inventory_exit", {}),
        "exit_start_markup": 0.015,
        "exit_floor_markup": 0.005,
        "min_net_profit_ada": 1.0,
        "step_days": 7,
    }
    POL_S1["strategies"]["S2_shock_fade"].update({
        "assets": ["NGT"],
        "entry_mode": "market",
        "exit_mode": "s1_maker",
        "hold_hours": 168,
        "wallet_cap_sizing": True,
        "k_sigma": 2.0,
    })
    Path(os.environ["TRADING_POLICY_PATH"]).write_text(json.dumps(POL_S1))
    n = 24 * 25
    t0 = (int(time.time()) // 3600) * 3600 - n * 3600
    rng = np.random.default_rng(19)
    c = np.ones(n)
    for i in range(1, n):
        # Mean-reverting path with periodic -3.5% liquidity shocks that revert within 24h
        shock = -0.035 if (i > 180 and i % 36 == 0) else 0.0
        c[i] = 1.0 + 0.65 * (c[i - 1] - 1.0) + shock + rng.normal(0, 0.002)
    lo = np.minimum(c, np.roll(c, 1)) * 0.999
    hi = np.maximum(c, np.roll(c, 1)) * 1.004
    lo[0], hi[0] = c[0], c[0]
    out = backtest.run([backtest.S2], ["NGT"], record=False, gt_loader=lambda a, tf: _gt_series(c, lo, hi, t0))
    Path(os.environ["TRADING_POLICY_PATH"]).write_text(json.dumps(POL))
    r = out["strategies"][backtest.S2]["assets"]["NGT"]
    s = out["strategies"][backtest.S2]["stats"]
    cap_expected = round((2360.0 - 200.0 - 32.0) * 0.16, 2)  # 340.48 ADA
    ok = (
        abs((r.get("size_ada") or 0) - cap_expected) < 1.0
        and out["strategies"][backtest.S2]["params"].get("exit_mode") == "s1_maker"
        and s.get("n", 0) >= 3
        and (s.get("mean") or 0) > 0
        and "single_slot_stats" in r
    )
    return ok, json.dumps({"size_ada": r.get("size_ada"), "stats": s, "single_slot": r.get("single_slot_stats")})


@check("first_trigger_wins_s2_and_standing_corridor")
def _():
    from lib.tools.trading import plans, policy as pol_mod
    now = int(time.time())
    asset = "DUAL"
    rng = np.random.default_rng(77)
    mcon = mdb.connect()
    mcon.execute("DELETE FROM pool_snapshots WHERE asset=?", (asset,))
    mcon.execute("DELETE FROM swaps WHERE asset=?", (asset,))
    ra, rt = 2_000_000.0, 10_000_000.0  # spot ~ 0.20 ADA
    for i in range(4 * 288):
        ts = now - 4 * 86400 + i * 300
        k = ra * rt
        ra *= math.exp(rng.normal(0, 0.0008) / 2)
        rt = k / ra
        mdb.record_snapshot(mcon, ts, "pool_DUAL", asset, ra, rt, fee_bps=30.0, tx=f"d{i}")
    # -6% whale shock -> spot drops from ~0.20 to ~0.188 (outside [0.175, 0.182] corridor!)
    out_ada = ra * 0.03
    k = ra * rt
    ra -= out_ada
    rt = k / ra
    shock_spot = ra / rt
    mdb.record_snapshot(mcon, now - 120, "pool_DUAL", asset, ra, rt, fee_bps=30.0, tx="d_shock1")
    mdb.record_snapshot(mcon, now - 20, "pool_DUAL", asset, ra, rt, fee_bps=30.0, tx="d_shock1b")
    mdb.record_swaps(mcon, [{"tx": "d_shock1", "idx": 0, "ts": now - 120, "pool": "pool_DUAL", "asset": asset,
                             "kind": "batch", "side": "sell", "ada_amt": out_ada, "tok_amt": 0.0, "impact_pct": -6.0}])
    mcon.execute("INSERT OR REPLACE INTO recorder_state(pool, asset, last_checked) VALUES (?,?,?)",
                 ("pool_DUAL", asset, now))
    mcon.commit()

    POL_D = copy.deepcopy(POL)
    POL_D["execution"]["live"] = True
    POL_D["recorder"] = {"pools": [asset]}
    POL_D["strategies"]["S1_inventory_exit"]["state"] = "live"
    POL_D["strategies"]["S2_shock_fade"].update({
        "state": "simulated",
        "assets": [asset],
        "entry_mode": "market",
        "exit_mode": "s1_maker",
        "wallet_cap_sizing": True,
        "k_sigma": 2.0,
        "min_swap_reserve_pct": 0.1,
        "max_order_reserve_pct": 0.1,
        "stabilize_s": 90,
    })
    Path(os.environ["TRADING_POLICY_PATH"]).write_text(json.dumps(POL_D))

    tcon = store.connect()
    tcon.execute("DELETE FROM standing_orders WHERE asset=?", (asset,))
    tcon.execute("DELETE FROM sim_trades WHERE asset=?", (asset,))
    tcon.execute(
        "INSERT OR REPLACE INTO equity(ts, equity_ada, peak_ada, drawdown_pct, detail) VALUES (?,?,?,?,?)",
        (now - 60, 408.0, 408.0, 0.0, "{}"),
    )
    store.set_override(tcon, "strategy:S2_shock_fade", "live", by="plan:P-EAAE79", reason="Gate 1")
    corridor_min, corridor_max = round(shock_spot * 0.91, 6), round(shock_spot * 0.94, 6)
    tcon.execute(
        "INSERT INTO standing_orders (so_id, created_at, expires_at, strategy, asset, side, max_ada, "
        "used_ada, price_min, price_max, status) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        ("SO-DUAL01", now - 3600, now + 86400, "manual", asset, "buy", 340.0, 0.0, corridor_min, corridor_max, "active"),
    )
    tcon.commit()
    tcon.close()

    placed = []
    wallet_state = {"wallet_ada": 408.0, "exposure_ada": {}}
    orig_snap, orig_mkt, orig_place, orig_tag = plans.SNAPSHOT, plans.MARKET, plans.PLACE, plans.TAG_ORDER
    try:
        def fake_snap(pol_arg, market=None, check_chain=True):
            eq = 408.0
            wc = eq - pol_arg["wallet"]["floor_ada"] - pol_arg["wallet"]["fee_buffer_ada"]
            return {
                "wallet_ada": wallet_state["wallet_ada"],
                "wallet_tokens": {},
                "open_orders": [],
                "positions": {},
                "exposure_ada": dict(wallet_state["exposure_ada"]),
                "equity_ada": eq,
                "working_capital_ada": wc,
                "free_ada": wallet_state["wallet_ada"] - 50.0,
                "locked_ada_in_orders": 0.0,
                "warnings": [],
                "_market": {},
            }

        def fake_mkt(a, use_cache=True):
            mc = mdb.connect()
            st = mdb.fresh_pool_state(mc, a)
            mc.close()
            sp = float(st["spot"]) if st else shock_spot
            return {"asset": a.upper(), "status": "ok", "spot": sp, "sigma_1h": 0.012, "sigma_24h": 0.05,
                    "reserve_ada": 2_000_000.0, "fee_bps": 30, "fair_value": 0.20, "spot_source": "pool_recorder_exact"}

        def fake_place(a, side, tokens, price, execute, actor, parent_order_id):
            placed.append((a, side, round(tokens * price, 2), round(price, 6), execute))
            return {"status": "ok", "tx_id": f"tx_dual_{len(placed)}"}

        plans.SNAPSHOT = fake_snap
        plans.MARKET = fake_mkt
        plans.PLACE = fake_place
        plans.TAG_ORDER = lambda tx, f: None

        # Step 1: S2 shock triggers outside SO-DUAL01 corridor and executes autonomously!
        r1 = signals.scan([asset], now=now)
        s2_sig1 = [x for x in r1["new_signals"] if x["strategy"] == "S2_shock_fade"]
        s2_auto_ok = (
            len(s2_sig1) == 1
            and s2_sig1[0].get("live", {}).get("status") == "executed"
            and s2_sig1[0].get("live", {}).get("via") == "autonomous_strategy"
            and len(placed) == 1
        )

        # Simulate S2 capital now occupying the NIGHT/DUAL slot
        wallet_state["wallet_ada"] = 64.0
        wallet_state["exposure_ada"] = {asset: 340.0}

        # Step 2: Spot slides into SO-DUAL01 corridor while S2 occupies the slot -> SO stands down quietly!
        target_so_spot = 0.5 * (corridor_min + corridor_max * 0.995)
        ra_so = math.sqrt(k * target_so_spot)
        rt_so = k / ra_so
        mcon = mdb.connect()
        mdb.record_snapshot(mcon, now + 400, "pool_DUAL", asset, ra_so, rt_so, fee_bps=30.0, tx="d_so1")
        mdb.record_snapshot(mcon, now + 520, "pool_DUAL", asset, ra_so, rt_so, fee_bps=30.0, tx="d_so1b")
        mcon.execute("INSERT OR REPLACE INTO recorder_state(pool, asset, last_checked) VALUES (?,?,?)",
                     ("pool_DUAL", asset, now + 600))
        mcon.commit()
        mcon.close()

        r2 = signals.scan([asset], now=now + 600)
        tcon = store.connect()
        so_trig_events_busy = tcon.execute(
            "SELECT COUNT(*) FROM events WHERE kind='standing_order_corridor_trigger' AND detail LIKE '%SO-DUAL01%'"
        ).fetchone()[0]
        so_used_busy = float(tcon.execute("SELECT used_ada FROM standing_orders WHERE so_id='SO-DUAL01'").fetchone()[0])
        tcon.close()
        so_quiet_while_busy = (r2["standing_triggers"] == [] and so_trig_events_busy == 0 and so_used_busy == 0.0 and len(placed) == 1)

        # Step 3: S1 exits S2's inventory back to ADA -> SO-DUAL01 automatically re-arms and executes!
        wallet_state["wallet_ada"] = 414.0
        wallet_state["exposure_ada"] = {}
        mcon = mdb.connect()
        mcon.execute("INSERT OR REPLACE INTO recorder_state(pool, asset, last_checked) VALUES (?,?,?)",
                     ("pool_DUAL", asset, now + 900))
        mcon.commit()
        mcon.close()
        r3 = signals.scan([asset], now=now + 900)
        so_rearmed_ok = (
            len(r3["standing_triggers"]) == 1
            and r3["standing_triggers"][0]["live"].get("status") == "executed"
            and r3["standing_triggers"][0]["live"].get("via") == "standing_order"
            and len(placed) == 2
        )

        # Step 4: Now SO-DUAL01's position holds the slot when another S2 shock arrives past cooldown ->
        #         shadow sim records, live skips cleanly with skipped_capital_occupied!
        wallet_state["wallet_ada"] = 70.0
        wallet_state["exposure_ada"] = {asset: 340.0}
        later = now + signals.S2_COOLDOWN_S + 1800
        mcon = mdb.connect()
        out_ada2 = ra_so * 0.04
        ra2 = ra_so - out_ada2
        rt2 = k / ra2
        mdb.record_snapshot(mcon, later - 120, "pool_DUAL", asset, ra2, rt2, fee_bps=30.0, tx="d_shock2")
        mdb.record_snapshot(mcon, later - 20, "pool_DUAL", asset, ra2, rt2, fee_bps=30.0, tx="d_shock2b")
        mdb.record_swaps(mcon, [{"tx": "d_shock2", "idx": 0, "ts": later - 120, "pool": "pool_DUAL", "asset": asset,
                                 "kind": "batch", "side": "sell", "ada_amt": out_ada2, "tok_amt": 0.0, "impact_pct": -8.0}])
        mcon.execute("INSERT OR REPLACE INTO recorder_state(pool, asset, last_checked) VALUES (?,?,?)",
                     ("pool_DUAL", asset, later))
        mcon.commit()
        mcon.close()
        r4 = signals.scan([asset], now=later)
        s2_sig2 = [x for x in r4["new_signals"] if x["strategy"] == "S2_shock_fade"]
        s2_quiet_while_busy = (
            len(s2_sig2) == 1
            and s2_sig2[0].get("live", {}).get("status") == "skipped_capital_occupied"
            and len(placed) == 2
        )
    finally:
        plans.SNAPSHOT, plans.MARKET, plans.PLACE, plans.TAG_ORDER = orig_snap, orig_mkt, orig_place, orig_tag
        Path(os.environ["TRADING_POLICY_PATH"]).write_text(json.dumps(POL))

    ok = s2_auto_ok and so_quiet_while_busy and so_rearmed_ok and s2_quiet_while_busy
    return ok, json.dumps({
        "s2_auto_ok": s2_auto_ok,
        "so_quiet_while_busy": so_quiet_while_busy,
        "so_rearmed_ok": so_rearmed_ok,
        "s2_quiet_while_busy": s2_quiet_while_busy,
        "placed_count": len(placed),
    })


@check("s2_sizing_preview_and_counterfactual_what_if")
def _():
    _seed_market("SIZ", reserve=4_000_000.0, fee_bps=30.0)
    POL_SZ = copy.deepcopy(POL)
    POL_SZ["wallet"]["floor_ada"] = 40.0
    POL_SZ["wallet"]["fee_buffer_ada"] = 10.0
    POL_SZ["capital"]["max_position_fraction"] = 0.95
    POL_SZ["capital"]["max_pool_impact_pct"] = 0.5
    POL_SZ["strategies"]["S1_inventory_exit"] = {
        **POL_SZ["strategies"].get("S1_inventory_exit", {}),
        "exit_start_markup": 0.018,
        "exit_floor_markup": 0.005,
        "min_net_profit_ada": 1.0,
        "step_days": 7,
    }
    POL_SZ["strategies"]["S2_shock_fade"].update({
        "state": "live",
        "assets": ["SIZ"],
        "entry_mode": "market",
        "exit_mode": "s1_maker",
        "hold_hours": 168,
        "wallet_cap_sizing": True,
        "max_order_reserve_pct": 0.1,
        "min_net_profit_ada": 1.0,
        "max_s1_hurdle_pct": 0.045,
        "k_sigma": 2.0,
    })
    Path(os.environ["TRADING_POLICY_PATH"]).write_text(json.dumps(POL_SZ))
    try:
        tcon, mcon = store.connect(), mdb.connect()
        tcon.execute(
            "INSERT OR REPLACE INTO equity(ts, equity_ada, peak_ada, drawdown_pct, detail) VALUES (?,?,?,?,?)",
            (int(time.time()), 408.4, 408.4, 0.0, "{}"),
        )
        tcon.commit()
        prev_ok = signals.s2_sizing_preview(
            tcon, mcon, "SIZ", POL_SZ,
            port={"wallet_ada": 408.4, "working_capital_ada": 358.4, "positions": {}, "open_orders": []},
            mkt_row={"reserve_ada": 4_000_000.0, "spot": 0.25},
        )
        prev_sub = signals.s2_sizing_preview(
            tcon, mcon, "SIZ", POL_SZ,
            port={"wallet_ada": 130.0, "working_capital_ada": 80.0, "positions": {}, "open_orders": []},
            mkt_row={"reserve_ada": 4_000_000.0, "spot": 0.25},
        )
        skip_cnt = tcon.execute("SELECT COUNT(*) FROM events WHERE kind='signal_skipped'").fetchone()[0]
        bt_before = tcon.execute("SELECT COUNT(*) FROM backtests").fetchone()[0]
        tcon.close()
        mcon.close()

        # Run read-only what_if with a tight stop_pct=0.003 on a noisy mean-reverting series
        n = 24 * 25
        t0 = (int(time.time()) // 3600) * 3600 - n * 3600
        rng = np.random.default_rng(29)
        c = np.ones(n)
        for i in range(1, n):
            shock = -0.04 if (i > 180 and i % 30 == 0) else 0.0
            c[i] = 1.0 + 0.60 * (c[i - 1] - 1.0) + shock + rng.normal(0, 0.002)
        # Intra-bar dips of -1.2% before reverting +0.6% -> tight 0.3% stop gets whipsawed
        lo = c * 0.988
        hi = np.maximum(c, np.roll(c, 1)) * 1.008
        lo[0], hi[0] = c[0], c[0]
        wi = backtest.what_if(
            "S2", ["SIZ"], days=25,
            overrides={"stop_pct": 0.003, "hold_hours": 48},
            gt_loader=lambda a, tf: _gt_series(c, lo, hi, t0),
        )
        tcon = store.connect()
        bt_after = tcon.execute("SELECT COUNT(*) FROM backtests").fetchone()[0]
        tcon.close()
    finally:
        Path(os.environ["TRADING_POLICY_PATH"]).write_text(json.dumps(POL))

    sizing_ok = (
        prev_ok["autonomous_when_live"] is True
        and prev_ok["s2_pool_reserve_cap_ada"] == 4000.0
        and prev_ok["min_viable_s1_hurdle_ada"] == 120.0
        and abs(prev_ok["live_executable_ada_if_triggered_now"] - 340.48) < 0.05
        and prev_ok["binding_constraint"] == "wallet_position_cap"
        and prev_sub["live_executable_ada_if_triggered_now"] == 0.0
        and prev_sub["binding_constraint"] == "below_s1_hurdle"
        and skip_cnt >= 1
    )
    whatif_ok = (
        wi["status"] == "ok"
        and bt_after == bt_before
        and wi["delta_single_slot"]["verdict"] == "DEGRADES_NET_ADA"
        and wi["delta_single_slot"]["net_total_ada"] < 0
        and wi["delta_single_slot"]["stop_outs"] >= 1
        and any("auto_stop_loss is FALSE" in x for x in wi["governance_notes"])
    )
    return sizing_ok and whatif_ok, json.dumps({
        "exec_ada": prev_ok["live_executable_ada_if_triggered_now"],
        "hurdle_ada": prev_ok["min_viable_s1_hurdle_ada"],
        "delta": wi.get("delta_single_slot"),
    })


print(f"SUMMARY {sum(RESULTS)}/{len(RESULTS)}")
sys.exit(0 if all(RESULTS) else 1)
