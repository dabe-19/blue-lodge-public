#!/usr/bin/env python3
"""
P2/P4 trading policy-engine checks (offline). Each check prints "<name> PASS|FAIL <detail>".

Everything that could touch the chain or the network is injected: plans.SNAPSHOT / MARKET /
PLACE / RECLAIM / TAG_ORDER / CLAIM_SELL, agent_tools.DISCORD_GET, watcher.ESCALATION /
FLAG_LIVE_SELL. Databases and the policy file live in a temp dir.
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

TMP = Path(tempfile.mkdtemp(prefix="george-trading-policy-"))
os.environ["GEORGE_DIR"] = str(TMP / ".george")
os.environ["FINANCE_DIR"] = str(TMP / ".george" / "finance")
os.environ["TRADING_DB_PATH"] = str(TMP / "trading.db")
os.environ["MARKET_DB_PATH"] = str(TMP / "market.db")
os.environ["ESCALATIONS_DB_PATH"] = str(TMP / "escalations.db")
os.environ["TRADING_POLICY_PATH"] = str(TMP / "trading_policy.json")
os.environ["MAKER_DB_PATH"] = str(TMP / "maker_orders.db")
os.environ["SIM_MAKER_DB_PATH"] = str(TMP / "sim_maker_orders.db")
for k in ("CARDANO_TEST_MODE", "GEORGE_TRADING_DRY_RUN", "DISCORD_OPERATOR_ID", "DISCORD_OWNER_ID",
          "DISCORD_OWNER_IDS", "DISCORD_BOT_TOKEN", "GEORGE_EXECUTE_LIVE_SELL"):
    os.environ.pop(k, None)
os.environ["GEORGE_CONFIG_DIR"] = str(TMP / "nokeys")   # escalation.get_key must not read the real keys.conf
Path(os.environ["FINANCE_DIR"]).mkdir(parents=True, exist_ok=True)

from lib.tools.trading import journal, plans, policy, store  # noqa: E402

POLICY = copy.deepcopy(policy.DEFAULT_POLICY)
POLICY["execution"]["live"] = True   # every submit path below is injected
POLICY["strategies"]["S1_inventory_exit"]["state"] = "live"
Path(os.environ["TRADING_POLICY_PATH"]).write_text(json.dumps(POLICY))

RESULTS = []
CALLS = {"place": [], "reclaim": [], "tag": [], "claim": []}


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


# ── Fixtures ─────────────────────────────────────────────────────────────────
MKT = {
    "SNEK": {"asset": "SNEK", "status": "ok", "spot": 0.0035, "sigma_1h": 0.01, "sigma_24h": 0.04,
             "reserve_ada": 1_000_000.0, "fee_bps": 100, "fair_value": 0.0036, "spot_source": "test"},
    "NIGHT": {"asset": "NIGHT", "status": "ok", "spot": 0.20, "sigma_1h": 0.012, "sigma_24h": 0.06,
              "reserve_ada": 2_000_000.0, "fee_bps": 30, "fair_value": 0.20, "spot_source": "test"},
}


def port(wallet=200.0, positions=None, open_orders=None, wallet_tokens=None, exposure=None):
    positions = positions or {}
    tv = sum((p.get("tokens") or 0) * MKT[a]["spot"] for a, p in positions.items())
    eq = wallet + tv
    pol = policy.load_policy()
    return {"wallet_ada": wallet, "wallet_tokens": wallet_tokens or {}, "open_orders": open_orders or [],
            "positions": positions, "exposure_ada": exposure if exposure is not None else
            {a: (p.get("tokens") or 0) * MKT[a]["spot"] for a, p in positions.items()},
            "equity_ada": eq, "working_capital_ada": eq - pol["wallet"]["floor_ada"] - pol["wallet"]["fee_buffer_ada"],
            "free_ada": wallet - 50, "locked_ada_in_orders": 0.0, "warnings": [], "_market": {}}


STATE = {"port": port()}


def install(p=None, mkt=None):
    STATE["port"] = p or port()
    m = mkt or MKT
    plans.SNAPSHOT = lambda pol, market=None, check_chain=True: copy.deepcopy(STATE["port"])
    plans.MARKET = lambda a, use_cache=True: copy.deepcopy(m.get(a.upper(), {"asset": a, "status": "unavailable"}))
    plans.PLACE = lambda asset, side, tokens, price, execute, actor, parent_order_id: (
        CALLS["place"].append((asset, side, tokens, price, execute)) or {"status": "ok", "tx_id": f"tx{len(CALLS['place'])}"})
    plans.RECLAIM = lambda utxo, execute, actor, wait: (
        CALLS["reclaim"].append((utxo, execute)) or {"status": "ok", "tx_id": "rtx", "verification": {"verified": True}})
    plans.TAG_ORDER = lambda tx, f: CALLS["tag"].append((tx, f))
    plans.CLAIM_SELL = lambda oid: CALLS["claim"].append(oid)


def reset_calls():
    for v in CALLS.values():
        v.clear()


def fresh_db():
    p = Path(os.environ["TRADING_DB_PATH"])
    for suffix in ("", "-wal", "-shm"):
        Path(str(p) + suffix).unlink(missing_ok=True)
    return store.connect()


def costed_position(asset="NIGHT", tokens=300.0, cost=55.0, age_s=2 * 86400):
    return {asset: {"asset": asset, "tokens": tokens, "tokens_db": tokens, "cost_ada": cost, "age_s": age_s,
                    "order_ids": [f"maker_{asset.lower()}_1"], "spot": MKT[asset]["spot"]}}


install()
POL = policy.load_policy()


# ── 1. Tier classification ───────────────────────────────────────────────────
@check("tiers_classify")
def _():
    p = port(positions=costed_position())
    be = policy.breakeven_price(55.0, 300.0, POL)
    cases = {
        "reclaim": ({"type": "reclaim"}, "A"),
        "buy": ({"type": "place_buy", "asset": "SNEK"}, "B"),
        "send": ({"type": "send"}, "C"),
        "unknown": ({"type": "teleport"}, "C"),
        "sell_above_be": ({"type": "place_sell", "asset": "NIGHT", "price": be * 1.01}, "A"),
        "sell_below_be": ({"type": "place_sell", "asset": "NIGHT", "price": be * 0.99}, "B"),
        "sell_uncosted": ({"type": "place_sell", "asset": "SNEK", "price": 1.0}, "B"),
        "reprice_small": ({"type": "reprice", "asset": "NIGHT", "side": "sell", "old_side": "sell", "tokens": 300,
                           "old_tokens": 300, "old_price": be * 1.02, "price": be * 1.01}, "A"),
        "reprice_big": ({"type": "reprice", "asset": "NIGHT", "side": "sell", "old_side": "sell", "tokens": 300,
                         "old_tokens": 300, "old_price": be * 1.5, "price": be * 1.01}, "B"),
        "reprice_resize": ({"type": "reprice", "asset": "NIGHT", "side": "sell", "old_side": "sell", "tokens": 200,
                            "old_tokens": 300, "old_price": be * 1.02, "price": be * 1.01}, "B"),
        "unlock": ({"type": "strategy_unlock"}, "B"),
    }
    got = {k: policy.classify(a, POL, p, MKT)[0] for k, (a, _) in cases.items()}
    bad = {k: (got[k], want) for k, (_, want) in cases.items() if got[k] != want}
    return not bad, f"mismatches={bad}" if bad else f"{len(cases)} cases"


# ── 2. Policy loading fails closed ───────────────────────────────────────────
@check("policy_fails_closed")
def _():
    d = Path(tempfile.mkdtemp(dir=TMP))
    missing = policy.load_policy(d / "nope.json")
    (d / "bad.json").write_text("{not json")
    bad = policy.load_policy(d / "bad.json")
    (d / "weird.json").write_text(json.dumps({"execution": {"live": True}, "strategies": {"S2_shock_fade": {"state": "yolo"}}}))
    weird = policy.load_policy(d / "weird.json")
    os.environ["CARDANO_TEST_MODE"] = "1"
    forced = policy.live_execution_enabled(weird)
    os.environ.pop("CARDANO_TEST_MODE")
    ok = (not policy.live_execution_enabled(missing) and not policy.live_execution_enabled(bad)
          and weird["strategies"]["S2_shock_fade"]["state"] == "disabled" and forced is False
          and missing["strategies"]["S1_inventory_exit"]["state"] == "simulated")
    return ok, f"missing_live={missing['execution']['live']} bad_live={bad['execution']['live']} weird_S2={weird['strategies']['S2_shock_fade']['state']}"


# ── 3. Capital rules ─────────────────────────────────────────────────────────
@check("capital_rules")
def _():
    buy = lambda ada, asset="SNEK": {"type": "place_buy", "asset": asset, "ada": ada}
    r = {}
    r["floor"] = policy.capital_check(buy(170), POL, port(wallet=200), MKT)["breach_floor"]
    r["buffer"] = any("fee buffer" in f for f in policy.capital_check(buy(150), POL, port(wallet=200), MKT)["failures"])
    r["min_order"] = any("min" in f for f in policy.capital_check(buy(10), POL, port(wallet=200), MKT)["failures"])
    max_pos = int(POL["capital"]["max_positions"])
    full_pos = port(wallet=400, exposure={f"TOK{i}": 20.0 for i in range(max_pos)})
    r["max_positions"] = any(f"position #{max_pos + 1}" in f for f in policy.capital_check(buy(30), POL, full_pos, MKT)["failures"])
    over_pos = float(POL["capital"]["max_position_fraction"]) * 350.0 + 10.0
    r["position_cap"] = any("of working capital" in f for f in policy.capital_check(buy(over_pos), POL, port(wallet=400), MKT)["failures"])
    small = copy.deepcopy(MKT)
    small["SNEK"]["reserve_ada"] = 4_000.0
    r["impact"] = any("impact" in f for f in policy.capital_check(buy(30), POL, port(wallet=400), small)["failures"])
    nores = copy.deepcopy(MKT)
    nores["SNEK"].pop("reserve_ada")
    r["reserve_unknown"] = any("reserve unknown" in f for f in policy.capital_check(buy(30), POL, port(wallet=400), nores)["failures"])
    nowallet = port()
    nowallet["wallet_ada"] = None
    r["wallet_unknown"] = not policy.capital_check(buy(30), POL, nowallet, MKT)["ok"]
    r["ok_case"] = policy.capital_check(buy(40), POL, port(wallet=400), MKT)["ok"]
    return all(r.values()), str(r)


# ── 4. Tier B is refused without the operator's token; nothing runs ──────────
@check("tier_b_needs_token")
def _():
    con = fresh_db()
    install(port(wallet=400))
    reset_calls()
    p = plans.build_plan("buy SNEK 40", con=con)
    res = plans.execute_plan(p["plan_id"], con=con)
    st = plans.get_plan(con, p["plan_id"])["status"]
    return (p["tier"] == "B" and res["status"] == "needs_confirmation" and not CALLS["place"] and st == "proposed"), \
        f"tier={p['tier']} res={res['status']} plan_status={st} places={len(CALLS['place'])}"


# ── 5. Confirm token: executes once, single use, bound to the plan ───────────
@check("confirm_token_single_use_and_bound")
def _():
    con = fresh_db()
    install(port(wallet=400))
    reset_calls()
    p1 = plans.build_plan("buy SNEK 40", con=con)
    p2 = plans.build_plan("buy SNEK 30", con=con)
    tok = plans.mint_token(con, p1["plan_id"], "discord", "discord:1:2")
    wrong = plans.execute_plan(p2["plan_id"], confirm_token=tok, con=con)
    ok1 = plans.execute_plan(p1["plan_id"], confirm_token=tok, con=con)
    again = plans.execute_plan(p1["plan_id"], confirm_token=tok, con=con)
    try:
        plans.mint_token(con, p2["plan_id"], "discord", "discord:1:2")
        reuse_evidence = "minted"
    except ValueError as e:
        reuse_evidence = str(e)
    ok = (wrong["status"] == "rejected" and ok1["status"] == "executed" and len(CALLS["place"]) == 1
          and again["status"] == "rejected" and "already used" in reuse_evidence and ok1["confirmed_by_operator"])
    return ok, f"wrong={wrong['status']} first={ok1['status']} again={again['status']} places={len(CALLS['place'])} evidence={reuse_evidence}"


# ── 6. TTL expiry and hash tamper ────────────────────────────────────────────
@check("plan_ttl_and_tamper")
def _():
    con = fresh_db()
    install(port(wallet=400, positions=costed_position()))
    reset_calls()
    p = plans.build_plan("buy SNEK 40", con=con)
    con.execute("UPDATE plans SET expires_at=? WHERE plan_id=?", (int(time.time()) - 1, p["plan_id"]))
    con.commit()
    exp = plans.execute_plan(p["plan_id"], con=con)
    q = plans.build_plan("buy SNEK 40", con=con)
    acts = json.loads(con.execute("SELECT actions_json FROM plans WHERE plan_id=?", (q["plan_id"],)).fetchone()[0])
    acts[0]["ada"] = 140.0
    acts[0]["tier"] = "A"
    con.execute("UPDATE plans SET actions_json=? WHERE plan_id=?", (json.dumps(acts, sort_keys=True), q["plan_id"]))
    con.commit()
    tam = plans.execute_plan(q["plan_id"], con=con)
    ok = "expired" in exp.get("reason", "") and "hash" in tam.get("reason", "") and not CALLS["place"]
    return ok, f"expired={exp.get('reason')} tamper={tam.get('reason')}"


# ── 7. Freshness: price moved > 0.5 sigma_1h since the plan ──────────────────
@check("stale_plan_rejected")
def _():
    con = fresh_db()
    install(port(wallet=400))
    reset_calls()
    p = plans.build_plan("buy SNEK 40", con=con)
    tok = plans.mint_token(con, p["plan_id"], "web", "web:x")
    moved = copy.deepcopy(MKT)
    moved["SNEK"]["spot"] = 0.0035 * 1.03
    install(STATE["port"], moved)
    res = plans.execute_plan(p["plan_id"], confirm_token=tok, con=con)
    install(STATE["port"], MKT)
    return res["status"] == "rejected" and "stale" in res.get("reason", "") and not CALLS["place"], res.get("reason", "")


# ── 8. Standing order covers a Tier B buy within its limits only ─────────────
@check("standing_order_cover")
def _():
    con = fresh_db()
    install(port(wallet=400))
    reset_calls()
    so = plans.build_plan({"kind": "standing_order", "strategy": "manual", "asset": "SNEK", "max_ada": 50,
                           "expires_hours": 24}, con=con)
    tok = plans.mint_token(con, so["plan_id"], "web", "web:so")
    r = plans.execute_plan(so["plan_id"], confirm_token=tok, con=con)
    b1 = plans.build_plan("buy SNEK 40", con=con)
    e1 = plans.execute_plan(b1["plan_id"], con=con)
    b2 = plans.build_plan("buy SNEK 30", con=con)
    e2 = plans.execute_plan(b2["plan_id"], con=con)
    used = con.execute("SELECT used_ada FROM standing_orders").fetchone()[0]
    ok = (r["status"] == "executed" and e1["status"] == "executed" and e2["status"] == "needs_confirmation"
          and len(CALLS["place"]) == 1 and abs(used - 40) < 1e-6)
    return ok, f"so={r['status']} first={e1['status']} second={e2['status']} used={used}"


# ── 9. Simulated strategy goes to sim_trades, disabled is blocked ────────────
@check("simulated_and_disabled_strategies")
def _():
    con = fresh_db()
    install(port(wallet=400))
    reset_calls()
    p = plans.build_plan({"kind": "buy", "asset": "SNEK", "budget_ada": 40, "strategy": "S2_shock_fade"}, con=con)
    tok = plans.mint_token(con, p["plan_id"], "web", "web:sim")
    r = plans.execute_plan(p["plan_id"], confirm_token=tok, con=con)
    n = con.execute("SELECT COUNT(*) FROM sim_trades WHERE strategy='S2_shock_fade'").fetchone()[0]
    d = plans.build_plan({"kind": "buy", "asset": "SNEK", "budget_ada": 40, "strategy": "bid_ladder"}, con=con)
    ok = (r["results"][0]["status"] == "simulated" and n == 1 and not CALLS["place"]
          and d["status"] == "blocked" and d["actions"][0]["blocked"])
    return ok, f"sim={r['results'][0]['status']} rows={n} disabled_plan={d['status']}"


# ── 10. Drawdown freeze: live -> simulated; exits need confirmation ──────────
@check("drawdown_freeze")
def _():
    con = fresh_db()
    now = int(time.time())
    journal.snapshot_equity(con, 400.0, POL, ts=now - 200)
    blip = journal.snapshot_equity(con, 90.0, POL, ts=now - 150)      # single bad tick: must NOT freeze
    journal.snapshot_equity(con, 400.0, POL, ts=now - 120)            # recovers
    journal.snapshot_equity(con, 330.0, POL, ts=now - 60)             # 1st real tick >= 15%
    eq = journal.snapshot_equity(con, 330.0, POL)                     # 2nd consecutive tick -> freeze
    states = policy.strategy_states(con, POL)
    pos = costed_position()
    install(port(wallet=200, positions=pos, wallet_tokens={"NIGHT": 300.0}))
    reset_calls()
    p = plans.build_plan({"kind": "exit", "asset": "NIGHT"}, con=con)
    r = plans.execute_plan(p["plan_id"], con=con)
    ok = (not blip["froze"] and eq["froze"] and states["S1_inventory_exit"] == "simulated" and states["manual"] == "simulated"
          and p["tier"] == "A" and r["results"][0]["status"] == "needs_confirmation" and not CALLS["place"])
    return ok, f"blip_froze={blip['froze']} froze={eq['froze']} dd={eq['drawdown_pct']:.1f} S1={states['S1_inventory_exit']} exit={r['results'][0]['status']}"


# ── 11. Tier A exit executes live (injected) and tags the order ──────────────
@check("tier_a_exit_executes")
def _():
    con = fresh_db()
    install(port(wallet=200, positions=costed_position(), wallet_tokens={"NIGHT": 300.0}))
    reset_calls()
    p = plans.build_plan({"kind": "exit", "asset": "NIGHT"}, con=con)
    r = plans.execute_plan(p["plan_id"], con=con)
    tagged = CALLS["tag"] and CALLS["tag"][0][1].get("plan_id") == p["plan_id"] and CALLS["tag"][0][1].get("new_rules") == 1
    ok = p["tier"] == "A" and r["status"] == "executed" and len(CALLS["place"]) == 1 and CALLS["place"][0][1] == "sell" \
        and bool(tagged) and r["live"]
    return ok, f"tier={p['tier']} status={r['status']} places={CALLS['place'][:1]} tagged={bool(tagged)}"


# ── 12. Discord confirmation verification ────────────────────────────────────
@check("discord_confirm_verification")
def _():
    from lib.tools.trading import agent_tools as at
    os.environ["DISCORD_OPERATOR_ID"] = "100000000000000001"
    epoch = at.DISCORD_EPOCH_MS
    created = int(time.time()) - 60

    def snow(t):
        return str((int(t * 1000) - epoch) << 22)
    msgs = {}

    def fake_get(path):
        return msgs[path.rsplit("/", 1)[-1]]
    at.DISCORD_GET = fake_get
    good = snow(time.time())
    msgs[good] = {"author": {"id": "100000000000000001"}, "content": "confirm P-ABC123", "edited_timestamp": None}
    other = snow(time.time() + 1)
    msgs[other] = {"author": {"id": "999999999999"}, "content": "confirm P-ABC123"}
    bot = snow(time.time() + 2)
    msgs[bot] = {"author": {"id": "100000000000000001", "bot": True}, "content": "confirm P-ABC123"}
    wrongp = snow(time.time() + 3)
    msgs[wrongp] = {"author": {"id": "100000000000000001"}, "content": "confirm P-FFFFFF"}
    edited = snow(time.time() + 4)
    msgs[edited] = {"author": {"id": "100000000000000001"}, "content": "confirm P-ABC123", "edited_timestamp": "x"}
    old = snow(created - 600)
    msgs[old] = {"author": {"id": "100000000000000001"}, "content": "confirm P-ABC123"}
    v = lambda mid: at.verify_discord_confirm("P-ABC123", "123456789012", mid, created)
    r = {"good": v(good), "other": v(other), "bot": v(bot), "wrong_plan": v(wrongp), "edited": v(edited),
         "predates": v(old), "bad_id": at.verify_discord_confirm("P-ABC123", "chan; rm", good, created)}
    os.environ.pop("DISCORD_OPERATOR_ID")
    ok = r["good"] is None and all(r[k] for k in r if k != "good")
    return ok, json.dumps({k: (v or "OK")[:40] for k, v in r.items()})


# ── 13. Journal markouts from the pool recorder ──────────────────────────────
@check("journal_markouts")
def _():
    from lib.tools.quant import market_db as mdb
    con = fresh_db()
    m = mdb.connect()
    t0 = int(time.time()) - 3 * 86400
    journal.record_fill(con, "o1:buy", "live", "manual", "SNEK", "buy", 0.0035, 10000.0, ts=t0)
    journal.record_fill(con, "o2:buy", "live", "manual", "NIGHT", "buy", 0.20, 100.0, ts=int(time.time()) - 400)
    mdb.record_snapshot(m, t0 + 200, "p1", "SNEK", 1_000_000, 1_000_000 / 0.00357)
    m.execute("INSERT OR REPLACE INTO recorder_state(pool, asset, last_checked) VALUES ('p1','SNEK',?)", (t0 + 400,))
    m.commit()
    c = journal.capture_markouts(con, m)
    rows = {(r["fill_id"], r["horizon_s"]): dict(r) for r in con.execute("SELECT * FROM markouts")}
    five = rows[("o1:buy", 300)]
    ok = (five["status"] == "done" and abs(five["markout_bps"] - (0.00357 / 0.0035 - 1) * 1e4) < 1e-6
          and rows[("o1:buy", 3600)]["status"] == "missing" and rows[("o2:buy", 300)]["status"] == "pending")
    m.close()
    return ok, f"counts={c} 5m={five['status']}/{five['markout_bps']:.1f}bps 1h={rows[('o1:buy', 3600)]['status']}"


# ── 14. Order-watcher journal hook: buy opens, sell closes the trip ──────────
@check("watcher_journal_hook_trips")
def _():
    from lib.tools import cardano_order_watcher as w
    con = fresh_db()
    con.close()
    row = {"order_id": "maker_snek_9", "asset": "SNEK", "cost_basis_ada": 40.0, "created_at": int(time.time()),
           "sell_tx_id": "stx"}
    meta = {"strategy": "manual", "new_rules": 1, "plan_id": "P-000001"}
    w._journal_fill(row, meta, "buy", 11000.0, 40.0 / 11000.0, entry_ada=40.0, fee_ada=0.2)
    w._journal_fill(row, meta, "sell", 11000.0, 0.0038, exit_ada=41.5, realized=1.5, fee_ada=0.2)
    con = store.connect()
    t = dict(con.execute("SELECT * FROM trips WHERE trip_id='maker_snek_9'").fetchone())
    n = con.execute("SELECT COUNT(*) FROM markouts").fetchone()[0]
    ok = t["closed_at"] and abs(t["net_pnl_ada"] - 1.5) < 1e-9 and t["new_rules"] == 1 and n == 8
    return bool(ok), f"net={t['net_pnl_ada']} new_rules={t['new_rules']} markouts={n}"


# ── 15. Watcher hourly pass: Tier A only, double opt-in, Tier B escalated ────
@check("watcher_auto_pass")
def _():
    from lib.tools.trading import watcher
    raised = []

    class FakeEsc:
        def connect(self):
            import sqlite3
            return sqlite3.connect(":memory:")

        def guard(self, con, kind, subject, severity):
            return "send", ""

        def raise_escalation(self, kind, subject, text, severity="normal", plan_id=None, context=None, source="", con=None):
            raised.append((kind, plan_id))
            return {"id": "E-TEST01", "status": "raised"}

        def operator_notify(self, *a, **k):
            raised.append(("notify", None))

        def flush_deferred(self):
            return []
    watcher.ESCALATION = lambda: FakeEsc()
    con = fresh_db()
    pos = costed_position()
    pos["SNEK"] = {"asset": "SNEK", "tokens": 7000.0, "tokens_db": 0.0, "cost_ada": None, "age_s": None, "order_ids": []}
    p = port(wallet=200, positions=pos, wallet_tokens={"NIGHT": 300.0, "SNEK": 7000.0})
    install(p)
    reset_calls()
    watcher.FLAG_LIVE_SELL = lambda: False
    off = watcher.auto_pass(con, POL, False, STATE["port"], [])
    places_off = len(CALLS["place"])
    watcher.FLAG_LIVE_SELL = lambda: True
    on = watcher.auto_pass(con, POL, False, STATE["port"], [])
    by = {x["intent"]: x.get("status") for x in on["plans"]}
    ok = (places_off == 0 and {x["intent"]: x.get("status") for x in off["plans"]}.get("NIGHT") == "not_executed"
          and by.get("NIGHT") == "executed" and by.get("SNEK") == "needs_operator" and len(CALLS["place"]) == 1
          and any(k == "trading/auto_tier_b" for k, _ in raised))
    return ok, f"off={[(x['intent'], x.get('status')) for x in off['plans']]} on={by} raised={raised}"


# ── 16. Gates: Gate 1 readiness, Gate 2, automatic re-lock ───────────────────
@check("gates_gate1_gate2_relock")
def _():
    from lib.tools.trading import gates
    con = fresh_db()
    g0 = gates.gate1(con, POL, "S2_shock_fade")
    gates.record_backtest(con, "bt1", "S2_shock_fade", journal.describe([0.8, 1.2, 0.5, 1.0] * 12), {}, 0, 1)
    old = int(time.time()) - 20 * 86400
    for i in range(10):
        con.execute("INSERT INTO sim_trades(sim_id, strategy, asset, created_at, side, entry_price, size_ada, timeout_at, "
                    "status, net_pnl_ada) VALUES (?,?,?,?,?,?,?,?,?,?)",
                    (f"S{i}", "S2_shock_fade", "SNEK", old + i * 3600, "buy", 0.0035, 40, old, "closed", 0.9 + 0.05 * (i % 3)))
    con.commit()
    g1 = gates.gate1(con, POL, "S2_shock_fade")
    for i in range(15):
        journal.open_trip(con, f"T{i}", "live", "S1_inventory_exit", "NIGHT", 0.2, 100, 20)
        journal.close_trip(con, f"T{i}", 0.21, 21.0, net_pnl_ada=0.6)
        journal.record_fill(con, f"T{i}:sell", "live", "S1_inventory_exit", "NIGHT", "sell", 0.21, 100, ts=old)
    con.execute("UPDATE markouts SET status='done', markout_bps=12.0, markout_ada=0.02 WHERE horizon_s=21600")
    con.commit()
    g2 = gates.gate2(con, POL)
    store.set_override(con, "strategy:S2_shock_fade", "live", by="test")
    for i in range(20):
        con.execute("INSERT INTO sim_trades(sim_id, strategy, asset, created_at, side, entry_price, size_ada, timeout_at, "
                    "status, net_pnl_ada) VALUES (?,?,?,?,?,?,?,?,?,?)",
                    (f"N{i}", "S2_shock_fade", "SNEK", int(time.time()) - 100 + i, "buy", 0.0035, 40, 0, "closed", -0.4))
    con.commit()
    raised = []
    ev = gates.evaluate(con, POL, raise_fn=lambda **kw: raised.append(kw["kind"]))
    st = policy.strategy_state(con, POL, "S2_shock_fade")
    ok = (not g0["ready"] and g1["ready"] and g2["passed"] and ev["relocked"] and st == "simulated"
          and "trading/relock" in raised and "trading/gate2" in raised)
    return ok, f"g0={g0['ready']} g1={g1['ready']} {[k for k, c in g1['checks'].items() if not c['ok']]} g2={g2['passed']} state={st} raised={raised}"


# ── 17. Review flags legacy buys as Tier B decisions, never auto ─────────────
@check("review_legacy_buy_is_tier_b")
def _():
    con = fresh_db()
    oo = [{"order_id": "maker_snek_legacy", "asset": "SNEK", "side": "buy", "utxo": "aa#0", "price": 0.0033,
           "ada": 94.0, "tokens": 28000, "created_at": int(time.time()) - 86400, "chain_status": "OPEN", "plan_id": None}]
    install(port(wallet=150, open_orders=oo))
    p = plans.build_plan("review", con=con)
    a = [x for x in p["actions"] if x["type"] == "reclaim"]
    return bool(a) and a[0]["tier"] == "B" and p["tier"] == "B", f"actions={[(x['type'], x['tier']) for x in p['actions']]}"


# ── 18. Multi-leg batch plans, natural buy phrasing, TTL refresh, multi-confirm ─
@check("batch_plans_ttl_refresh_and_multi_confirm")
def _():
    from lib.tools.trading import agent_tools as at
    con = fresh_db()
    install(port(wallet=400))
    reset_calls()
    nat = plans.build_plan("buy 30 ADA of SNEK at 0.0034", con=con)
    batch = plans.build_plan("buy SNEK 30 @ 0.0034; buy NIGHT 25 @ 0.19", con=con)
    con.execute("UPDATE plans SET status='expired', expires_at=? WHERE plan_id=?", (int(time.time()) - 120, batch["plan_id"]))
    con.commit()
    refreshed = plans.refresh_plans_in_text(f"Proposed {batch['plan_id']} for your review", con=con)
    p_after = plans.get_plan(con, batch["plan_id"])
    os.environ["DISCORD_OPERATOR_ID"] = "100000000000000001"
    mid = str((int(time.time() * 1000) - at.DISCORD_EPOCH_MS) << 22)
    at.DISCORD_GET = lambda _p: {"author": {"id": "100000000000000001"},
                                 "content": f"confirm {nat['plan_id']} · confirm {batch['plan_id']}",
                                 "edited_timestamp": None}
    v1 = at.verify_discord_confirm(nat["plan_id"], "123456789012", mid, int(nat["created_at"]))
    v2 = at.verify_discord_confirm(batch["plan_id"], "123456789012", mid, int(batch["created_at"]))
    os.environ.pop("DISCORD_OPERATOR_ID", None)
    ok = (len(nat["actions"]) == 1 and nat["actions"][0]["asset"] == "SNEK" and abs(nat["actions"][0]["ada"] - 30.0) < 1e-6
          and len(batch["actions"]) == 2 and not any(a.get("blocked") for a in batch["actions"])
          and batch["plan_id"] in refreshed and p_after["status"] == "proposed" and p_after["expires_at"] > int(time.time()) + 1500
          and v1 is None and v2 is None)
    return ok, f"nat={nat['plan_id']} batch_legs={len(batch['actions'])} refreshed={refreshed} v1={v1} v2={v2}"


# ── 19. Standalone SELL lifecycle (record_new_order -> watcher fill -> escalation confirm) ─
@check("standalone_sell_lifecycle_and_escalation_confirm")
def _():
    import tempfile
    from lib.tools import cardano_maker_db as mdb
    from lib.tools import cardano_order_watcher as watcher
    from lib.tools import cardano_orders as co
    from lib.comms import escalation as esc

    with tempfile.TemporaryDirectory() as td:
        orig_mdb_path = mdb.MAKER_DB_PATH
        orig_dw = co.default_wallet
        orig_desc = co.describe_order_output
        orig_settle = co.settlement_to
        orig_fee = co.tx_fee_ada
        orig_journal = watcher._journal_fill
        orig_emit = watcher.emit_event_to_bus
        try:
            mdb.MAKER_DB_PATH = Path(td) / "maker_orders.db"
            mdb.init_db()
            tx_hash = "e" * 64
            fill_hash = "8" * 64
            oid = mdb.record_new_order(
                asset="SNEK",
                direction="SELL",
                capital_ada=24.621197,
                target_price_ada=0.00338575,
                tokens_target=7272.0,
                batcher_fee_ada=2.0,
                tx_id=tx_hash,
                metadata={"dex": "minswap_v2", "plan_id": "P-DD1C97", "order_utxo": f"{tx_hash}#0"},
            )
            rows_before = [r for r in mdb.get_active_cycles() if r["order_id"] == oid]
            r0 = rows_before[0]
            rec_ok = (
                r0["sell_tx_id"] == tx_hash
                and abs(float(r0["onchain_locked_ada"]) - 4.0) < 1e-6
                and abs(float(r0["tokens_filled"]) - 7272.0) < 1e-6
                and abs(float(r0["sell_target_ada"]) - 24.621197) < 1e-5
                and float(r0["cost_basis_ada"]) == 0.0
            )
            journaled = []
            co.default_wallet = lambda: ("addr1_test", "a" * 56)
            co.describe_order_output = lambda h, ix, our_pkh=None: {
                "status": "FILLED",
                "protocol": "minswap_v2",
                "utxo": f"{h}#{ix}",
                "deadline_iso": None,
                "consumed_by_tx": fill_hash,
                "locked_value": {"lovelace": 4000000},
                "settlement_to_us": {"lovelace": 26690140},
            }
            co.settlement_to = lambda _tx, _addr: {"lovelace": 26690140}
            co.tx_fee_ada = lambda _ref: 0.177733
            watcher._journal_fill = lambda row, meta, side, tokens, price, **kw: journaled.append(
                (row["order_id"], side, round(tokens, 2), kw.get("realized"))
            )
            watcher.emit_event_to_bus = lambda *_a, **_k: True
            res = watcher.poll_order_lifecycle_once()
            all_rows = [r for r in mdb.get_active_cycles() if r["order_id"] == oid]
            r1 = all_rows[0]
            watcher_ok = (
                res.get("fills_detected") == 1
                and r1["status"] == "COMPLETED"
                and float(r1["realized_profit_ada"]) == 0.0
                and abs(float(r1.get("net_exit_ada") or 0.0) - 22.512407) < 1e-5
                and journaled == [(oid, "sell", 7272.0, None)]
            )
            e_con = esc.connect(Path(td) / "escalations.db")
            now_ts = int(time.time())
            e_con.execute(
                "INSERT INTO escalations(id, ts, kind, subject, severity, text, plan_id, status) VALUES (?,?,?,?,?,?,?,?)",
                ("E-9AD657", now_ts, "trading/auto_tier_b", "SNEK exit", "normal", "Confirm P-DD1C97", "P-DD1C97", "delivered"),
            )
            e_con.execute(
                "INSERT INTO asks(corr_id, ts, escalation_id, plan_id, text, status, expires_at) VALUES (?,?,?,?,?,?,?)",
                ("Q-428DCA", now_ts, "E-9AD657", "P-DD1C97", "Confirm P-DD1C97?", "open", now_ts + 600),
            )
            e_con.commit()
            updated = esc.mark_plan_confirmed("P-DD1C97", via="discord", con=e_con)
            a_st = e_con.execute("SELECT status, answer FROM asks WHERE corr_id='Q-428DCA'").fetchone()
            e_st = e_con.execute("SELECT status FROM escalations WHERE id='E-9AD657'").fetchone()
            e_con.close()
            esc_ok = updated >= 1 and a_st["status"] == "answered" and "P-DD1C97" in (a_st["answer"] or "") and e_st["status"] == "answered"
            ok = rec_ok and watcher_ok and esc_ok
            return ok, f"rec_ok={rec_ok} watcher_ok={watcher_ok} esc_ok={esc_ok}"
        finally:
            mdb.MAKER_DB_PATH = orig_mdb_path
            co.default_wallet = orig_dw
            co.describe_order_output = orig_desc
            co.settlement_to = orig_settle
            co.tx_fee_ada = orig_fee
            watcher._journal_fill = orig_journal
            watcher.emit_event_to_bus = orig_emit


# ── 18. Multi-corridor standing-order ladder coexistence & position cap ───────
@check("standing_order_ladder_coexistence_and_cap")
def _():
    con = fresh_db()
    # working_capital = 428.31 - 50 = 378.31 ADA -> 90% position cap (if 0.90) or 95% (359.39 ADA)
    pol_ladder = copy.deepcopy(POL)
    pol_ladder["capital"]["max_position_fraction"] = 0.90
    install(port(wallet=428.31))
    reset_calls()
    # 1. Shallow corridor: 170 ADA in [0.2055, 0.2085]
    p1 = plans.build_plan(
        {"kind": "standing_order", "strategy": "manual", "asset": "NIGHT", "max_ada": 170,
         "price_min": 0.2055, "price_max": 0.2085, "expires_hours": 72},
        con=con, pol=pol_ladder,
    )
    t1 = plans.mint_token(con, p1["plan_id"], "discord", "disc:1")
    r1 = plans.execute_plan(p1["plan_id"], confirm_token=t1, con=con, pol=pol_ladder)
    so1_id = r1["results"][0]["so_id"]
    # 2. Deep corridor: 170 ADA in [0.1945, 0.1985] with descriptive reference to so1_id in reason
    #    (regression test for P-575F61: mentioning so1_id as "complements SO-XXXXXX" must NOT supersede it!)
    p2 = plans.build_plan(
        {"kind": "standing_order", "strategy": "manual", "asset": "NIGHT", "max_ada": 170,
         "price_min": 0.1945, "price_max": 0.1985, "expires_hours": 72, "replace": False,
         "reason": f"Deep ladder rung; complements {so1_id} shallow rung at 0.2055-0.2085"},
        con=con, pol=pol_ladder,
    )
    t2 = plans.mint_token(con, p2["plan_id"], "discord", "disc:2")
    r2 = plans.execute_plan(p2["plan_id"], confirm_token=t2, con=con, pol=pol_ladder)
    so2_id = r2["results"][0]["so_id"]
    active_ids = [s["so_id"] for s in plans.standing_orders(con)]
    # 3. Third disjoint corridor that would push ladder to 360 ADA > 340.48 ADA cap -> blocked at plan time!
    p3 = plans.build_plan(
        {"kind": "standing_order", "strategy": "manual", "asset": "NIGHT", "max_ada": 20,
         "price_min": 0.1800, "price_max": 0.1850, "expires_hours": 72},
        con=con, pol=pol_ladder,
    )
    # 4. Verify standing_cover matches shallow vs deep corridor accurately
    cov_shallow = plans.standing_cover(con, {"type": "place_buy", "asset": "NIGHT", "strategy": "manual", "ada": 100, "price": 0.2070})
    cov_deep = plans.standing_cover(con, {"type": "place_buy", "asset": "NIGHT", "strategy": "manual", "ada": 100, "price": 0.1960})
    # 5. Verify evaluate_standing_orders steps recommended_corridor below existing sibling rung
    evals = plans.evaluate_standing_orders(con, pol=pol_ladder)
    rec_by_id = {e["so_id"]: e.get("recommended_corridor") for e in evals}
    rec2 = rec_by_id.get(so2_id) or {}
    rec_non_overlap = not plans._corridors_overlap(rec2.get("price_min"), rec2.get("price_max"), 0.2055, 0.2085)
    ok = (
        r1["status"] == "executed"
        and r2["status"] == "executed"
        and r2["results"][0].get("superseded_so_ids") == []
        and so1_id in r2["results"][0].get("coexisting_so_ids", [])
        and set(active_ids) == {so1_id, so2_id}
        and p3["status"] == "blocked"
        and cov_shallow is not None and cov_shallow["so_id"] == so1_id
        and cov_deep is not None and cov_deep["so_id"] == so2_id
        and rec_non_overlap
    )
    return ok, f"active={active_ids} p3={p3['status']} rec_non_overlap={rec_non_overlap}"


# ── Drift-aware touch probability + fill-cost haircut (crypto_forecast blend parity) ──

@check("touch_probability_drift_blend")
def _touch_probability_drift_blend():
    d, sigma = 0.15, 0.05  # barrier 15% below spot
    legacy = plans.touch_probability(d, sigma)
    flat, cflat = plans.blended_touch_probability(d, sigma, 0.0, 100.0, 85.0, None, "SNEK", "buy")
    up, _ = plans.blended_touch_probability(d, sigma, 0.05, 100.0, 85.0, None, "SNEK", "buy")
    dn, _ = plans.blended_touch_probability(d, sigma, -0.05, 100.0, 85.0, None, "SNEK", "buy")
    none_p, none_c = plans.blended_touch_probability(d, None, 0.0, 100.0, 85.0, None, "SNEK", "buy")
    touched, _ = plans.blended_touch_probability(0.0, sigma, 0.0, 100.0, 100.0, None, "SNEK", "buy")
    ou = {"actionable": True, "status": "ok", "theta_per_hour": 0.1, "mu_price": 88.0,
          "sigma_step_log": 0.03, "half_life_hours": 7}
    p_ou1, c_ou1 = plans.blended_touch_probability(d, sigma, 0.0, 100.0, 85.0, ou, "SNEK", "buy", horizon_h=1.0)
    p_ou24, c_ou24 = plans.blended_touch_probability(d, sigma, 0.0, 100.0, 85.0, ou, "SNEK", "buy", horizon_h=24.0)
    p_ou72, c_ou72 = plans.blended_touch_probability(d, sigma, 0.0, 100.0, 85.0, ou, "SNEK", "buy", horizon_h=72.0)
    # Producer contract check on market.py: uses 24*3600 (not 68400) and extracts "close" from ohlcv_series bars
    import inspect
    from lib.tools.trading import market as mkt_mod
    mkt_src = inspect.getsource(mkt_mod.market_ctx)
    producer_ok = ("68400" not in mkt_src) and ('b.get("close")' in mkt_src)
    ok = (
        abs(flat - legacy) < 1e-9                      # zero drift must reduce to legacy closed form
        and cflat.get("closed_form") is not None
        and up < flat < dn                             # rising pool pushes fill odds down; falling raises them
        and none_p is None and none_c == {}            # fail closed without sigma
        and touched == 1.0                             # barrier already at/above spot
        and "ou" in c_ou24                             # OU simulation joined the blend when actionable
        and c_ou1["ou"] < c_ou24["ou"] <= c_ou72["ou"] # multi-hour OU simulation scales across horizon_h
        and producer_ok
    )
    return ok, (f"legacy={legacy:.4f} flat={flat:.4f} up={up:.4f} dn={dn:.4f} "
                f"ou1h={c_ou1.get('ou'):.4f} ou24h={c_ou24.get('ou'):.4f} ou72h={c_ou72.get('ou'):.4f}")


@check("buy_action_fill_haircut")
def _buy_action_fill_haircut():
    m = MKT["NIGHT"]  # spot 0.20, sigma_24h 0.06, fee 30bps
    a = plans._buy_action("NIGHT", 100.0, "manual", POLICY, port(), MKT, price=0.19, reason="t")
    hc = plans._fill_haircut(m, POLICY, 0.19, 0.20)
    fixed = plans._round_trip_fixed(POLICY)
    ev_exp = (100.0 / 0.19) * 0.20 * (1 - 0.003) - 100.0 - fixed
    pol_leg = copy.deepcopy(POLICY)
    pol_leg["fees"]["enforce_legacy_fill_haircut"] = True
    hc_leg = plans._fill_haircut(m, pol_leg, 0.19, 0.20)
    ok = (
        not a.get("blocked")
        and hc == 0.0                                                   # Minswap V2 exact min_receive -> 0 phantom haircut
        and abs(a["tokens"] - 100.0 / 0.19) < 1e-9                      # full 100 ADA deployed
        and abs(a["effective_fill_price"] - 0.19) < 1e-6
        and a["fill_haircut_pct"] == 0.0
        and abs(a["ev_if_filled_ada"] - ev_exp) < 1e-9
        and a.get("p_sell_72h_after_fill") is not None and a["p_sell_72h_after_fill"] > 0.5
        and a.get("expected_net_profit_ada", 0) >= 1.0
        and 0.01 < hc_leg < pol_leg["fees"]["fill_haircut_max"]         # opt-in legacy mode preserved
    )
    return ok, f"hc={hc} tokens={a['tokens']:.4f} p_sell72={a.get('p_sell_72h_after_fill')} ev={a['ev_if_filled_ada']:.4f}"


@check("standing_order_drift_and_haircut")
def _standing_order_drift_and_haircut():
    con = fresh_db()
    now = int(time.time())
    con.execute(
        "INSERT INTO standing_orders (so_id, created_at, expires_at, strategy, asset, side, max_ada, "
        "used_ada, price_min, price_max, status) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        ("SO-DRIFT", now - 2 * 86400, now + 72 * 3600, "manual", "NIGHT", "buy", 100.0, 0.0, 0.165, 0.177, "active"))
    # Second corridor right below spot (pullback test: must NOT retreat when be_exit >= spot!)
    con.execute(
        "INSERT INTO standing_orders (so_id, created_at, expires_at, strategy, asset, side, max_ada, "
        "used_ada, price_min, price_max, status) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        ("SO-PULL", now - 4 * 3600, now + 48 * 3600, "manual", "NIGHT", "buy", 150.0, 0.0, 0.191, 0.196, "active"))
    con.commit()
    base = dict(MKT["NIGHT"])  # spot 0.20, sigma_24h 0.06, fee 30bps
    m0, mup, mdn = dict(base), dict(base), dict(base)
    mup["velocity_24h"] = 0.20   # +20%/24h, pushing price away from the corridor
    mdn["velocity_24h"] = -0.20  # -20%/24h, pulling price toward it
    ev0_map = {x["so_id"]: x for x in plans.evaluate_standing_orders(con, pol=POLICY, market={"NIGHT": m0}, now=now)}
    evup_map = {x["so_id"]: x for x in plans.evaluate_standing_orders(con, pol=POLICY, market={"NIGHT": mup}, now=now)}
    evdn_map = {x["so_id"]: x for x in plans.evaluate_standing_orders(con, pol=POLICY, market={"NIGHT": mdn}, now=now)}
    ev0, evup, evdn = ev0_map["SO-DRIFT"], evup_map["SO-DRIFT"], evdn_map["SO-DRIFT"]
    ev_pull = ev0_map["SO-PULL"]
    p0, pup, pdn = ev0["p_fill_expiry"], evup["p_fill_expiry"], evdn["p_fill_expiry"]
    p_max = 0.177
    be_expected = p_max * (1.0 + plans._round_trip_fixed(POLICY) / 100.0 + 2 * 0.003)
    rec = evup.get("recommended_corridor") or {}
    ok = (
        ev0["health"] == "healthy" and p0 >= 0.15 and ev0["velocity_24h"] is None
        and ev_pull["health"] == "healthy"                                          # pullback does NOT retreat!
        and ev_pull["breakeven_exit"] > 0.20                                        # even though be_exit > spot
        and evup["health"] == "needs_recalibration" and pup < 0.15 and pup < p0     # strong drift away triggers recalib
        and "24h velocity +20.00% is pushing price away from the corridor" in " ".join(evup["reasons"])
        and pdn > p0 and evdn["velocity_24h"] == -0.2 and evdn["drift_per_h_24h"] is not None
        and evup["p_fill_expiry_components"].get("drift_window") is not None
        and abs(ev0["breakeven_exit"] - be_expected) < 1e-4
        and ev0["fill_haircut_pct"] == 0.0
        and rec.get("price_max") and rec["price_max"] * (1.0 + plans._round_trip_fixed(POLICY) / 100.0 + 2 * 0.003) < 0.20
        and (rec.get("p_sell_fill_72h") or 0) >= 0.50 and (rec.get("expected_net_profit_ada") or 0) >= 1.0
    )
    return ok, (f"p0={p0} pup={pup} pdn={pdn} pull_health={ev_pull['health']} be={ev0['breakeven_exit']} "
                f"rec={rec.get('price_min')}-{rec.get('price_max')} p_sell72={rec.get('p_sell_fill_72h')}")


@check("two_sided_positive_ev_and_s1_sell")
def _two_sided_positive_ev_and_s1_sell():
    import numpy as np
    from lib.tools.quant import models as qm
    # 1. S1 exit_price enforces positive net ADA EV (>= 1.0 ADA) even at day 7 when fair_value dipped
    ex_day7 = policy.exit_price(cost_ada=50.0, tokens=250.0, age_s=7 * 86400, fair_value=0.205, pol=POLICY)
    # breakeven = (50 + 2.2) / 250 = 0.2088; legacy 0.3% markup was 0.2094 (+0.15 ADA); positive_ev_floor = (52.2 + 1.0)/250 = 0.2128 (+1.0 ADA)
    s1_ok = (
        ex_day7 is not None
        and ex_day7["binding"] == "positive_ev_floor"
        and abs(ex_day7["expected_net_profit_ada"] - 1.0) < 1e-5
        and ex_day7["price"] >= ex_day7["breakeven"] * 1.003
    )
    # 2. Detrended OU recovers actionable mean-reverting pullback structure around a rising trend
    rng = np.random.default_rng(42)
    n = 160
    resid = np.zeros(n)
    for i in range(1, n):
        resid[i] = 0.72 * resid[i - 1] + 0.008 * rng.standard_normal()
    trending_logp = math.log(0.18) + 0.0012 * np.arange(n) + resid
    ou_dt = qm.fit_ou_detrended(trending_logp, 1.0, anchor_price=0.22)
    ou_ok = bool(ou_dt.get("actionable")) and ou_dt.get("detrended") is True and abs(ou_dt["mu_price"] - 0.22) < 1e-9
    # 3. Standing order with tiny size / ultra-low vol where 72h sell bounce < 25% is blocked at plan time
    con = fresh_db()
    low_vol_mkt = copy.deepcopy(MKT)
    low_vol_mkt["NIGHT"]["sigma_24h"] = 0.015  # 1.5% daily vol -> 72h vol 2.6%, cannot bounce +32% on a 17 ADA order!
    install(port(wallet=400), low_vol_mkt)
    doomed = plans.build_plan(
        {"kind": "standing_order", "strategy": "manual", "asset": "NIGHT", "max_ada": 17.0,
         "price_min": 0.194, "price_max": 0.197, "expires_hours": 72},
        con=con,
    )
    install(port(wallet=400), MKT)
    doomed_ok = doomed["status"] == "blocked" and any("low 72h sell probability" in c for c in doomed["actions"][0].get("checks", []))
    ok = s1_ok and ou_ok and doomed_ok
    return ok, f"s1_ok={s1_ok} (net={ex_day7.get('expected_net_profit_ada')}) ou_ok={ou_ok} doomed_ok={doomed_ok}"


@check("operator_corridor_pinning_and_dex_venues")
def _operator_corridor_pinning_and_dex_venues():
    from lib.tools.trading import dex_venues
    con = fresh_db()
    install(port(wallet=500), MKT)
    p1 = plans.build_plan(
        {"kind": "standing_order", "strategy": "manual", "asset": "NIGHT", "max_ada": 100.0,
         "price_min": 0.173, "price_max": 0.177, "expires_hours": 72},
        con=con,
    )
    tok = plans.mint_token(con, p1["plan_id"], "discord", "discord:pin:1")
    r1 = plans.execute_plan(p1["plan_id"], confirm_token=tok, actor="operator", con=con, pol=POLICY)
    so_id = r1["results"][0]["so_id"]
    con.execute("UPDATE standing_orders SET created_at=? WHERE so_id=?", (int(time.time()) - 4 * 3600, so_id))
    con.commit()
    # Pinning suppresses normal 2.4-sigma drift recalibration while still blocking unforced overlap
    locked_ok = plans.set_standing_order_lock(con, so_id, locked=True, by="operator")
    m_drift = copy.deepcopy(MKT)
    m_drift["NIGHT"]["velocity_24h"] = 0.22
    ev_pinned = plans.evaluate_standing_orders(con, pol=POLICY, market=m_drift)[0]
    p_overlap = plans.build_plan(
        {"kind": "standing_order", "strategy": "manual", "asset": "NIGHT", "max_ada": 100.0,
         "price_min": 0.175, "price_max": 0.179, "expires_hours": 72},
        con=con,
    )
    overlap_blocked = (
        p_overlap["status"] == "blocked"
        and any("overlaps operator-pinned standing order" in c for c in p_overlap["actions"][0].get("checks", []))
    )
    # Explicit replace=True is allowed to supersede the pinned corridor when the operator commands it
    p_explicit = plans.build_plan(
        {"kind": "standing_order", "strategy": "manual", "asset": "NIGHT", "max_ada": 100.0,
         "price_min": 0.180, "price_max": 0.185, "expires_hours": 72, "replace": True},
        con=con,
    )
    explicit_ok = p_explicit["status"] == "proposed" and so_id in p_explicit["actions"][0].get("superseded_so_ids", [])
    # Unpinning restores normal drift recalibration
    plans.set_standing_order_lock(con, so_id, locked=False, by="operator")
    ev_unpinned = plans.evaluate_standing_orders(con, pol=POLICY, market=m_drift)[0]
    # Multi-DEX venue comparator
    v_cmp = dex_venues.compare_venues("NIGHT", 340.0)
    venues_ok = (
        v_cmp.get("status") == "ok"
        and len(v_cmp.get("venues") or []) >= 4
        and v_cmp.get("lowest_friction_venue") == "SundaeSwap V3"
        and v_cmp.get("active_execution_venue") == "Minswap V2"
    )
    ok = (
        locked_ok
        and ev_pinned["health"] == "pinned"
        and ev_pinned["locked_by_operator"] is True
        and overlap_blocked
        and explicit_ok
        and ev_unpinned["health"] == "needs_recalibration"
        and venues_ok
    )
    return ok, f"pinned={ev_pinned['health']} overlap_blocked={overlap_blocked} unpinned={ev_unpinned['health']} low_fee={v_cmp.get('lowest_friction_venue')}"


@check("autonomous_s2_and_s1_stepdown_reprice")
def _autonomous_s2_and_s1_stepdown_reprice():
    con = fresh_db()
    pol_s2 = copy.deepcopy(POLICY)
    pol_s2["strategies"]["S1_inventory_exit"]["exit_start_markup"] = 0.018
    pol_s2["strategies"]["S1_inventory_exit"]["exit_floor_markup"] = 0.005
    pol_s2["strategies"]["S2_shock_fade"]["assets"] = ["NIGHT"]
    store.set_override(con, "strategy:S2_shock_fade", "live", by="plan:P-EAAE79", reason="Gate 1 passed")
    # Overlapping standing order: autonomous S2 must NOT consume its used_ada
    now = int(time.time())
    con.execute(
        "INSERT INTO standing_orders (so_id, created_at, expires_at, strategy, asset, side, max_ada, "
        "used_ada, price_min, price_max, status) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        ("SO-COEX01", now - 3600, now + 86400, "manual", "NIGHT", "buy", 340.0, 0.0, 0.185, 0.195, "active"),
    )
    con.commit()
    install(port(wallet=410.0), MKT)
    reset_calls()

    # 1) Verified signal-scanner plan on unlocked NIGHT auto-executes without confirm_token or draining SO-COEX01
    p_sig = plans.build_plan(
        {"kind": "buy", "asset": "NIGHT", "budget_ada": 100.0, "price": 0.190, "strategy": "S2_shock_fade"},
        origin="signal:S2_shock_fade", con=con, pol=pol_s2,
    )
    r_sig = plans.execute_plan(p_sig["plan_id"], actor="george", con=con, pol=pol_s2)
    so_used_after_s2 = float(con.execute("SELECT used_ada FROM standing_orders WHERE so_id='SO-COEX01'").fetchone()[0])
    tagged_auto = any(f.get("autonomous_strategy") == "S2_shock_fade" for _, f in CALLS["tag"])

    # 2) Ad-hoc agent plan (origin='agent') outside SO corridor is still Tier B -> needs_confirmation
    p_adhoc = plans.build_plan(
        {"kind": "buy", "asset": "NIGHT", "budget_ada": 100.0, "price": 0.198, "strategy": "S2_shock_fade"},
        origin="agent", con=con, pol=pol_s2,
    )
    r_adhoc = plans.execute_plan(p_adhoc["plan_id"], actor="george", con=con, pol=pol_s2)

    # 3) Signal on non-allowlisted asset (SNEK when assets=['NIGHT']) is refused without confirmation
    p_wrong_asset = plans.build_plan(
        {"kind": "buy", "asset": "SNEK", "budget_ada": 40.0, "price": 0.0034, "strategy": "S2_shock_fade"},
        origin="signal:S2_shock_fade", con=con, pol=pol_s2,
    )
    r_wrong_asset = plans.execute_plan(p_wrong_asset["plan_id"], actor="george", con=con, pol=pol_s2)

    # 4) Drawdown freeze demotes S2_shock_fade back to simulated -> autonomous Tier B refused
    store.set_override(con, "freeze", {"reason": "test dd"}, by="journal")
    p_frozen = plans.build_plan(
        {"kind": "buy", "asset": "NIGHT", "budget_ada": 100.0, "price": 0.198, "strategy": "S2_shock_fade"},
        origin="signal:S2_shock_fade", con=con, pol=pol_s2,
    )
    r_frozen = plans.execute_plan(p_frozen["plan_id"], actor="george", con=con, pol=pol_s2)
    store.clear_override(con, "freeze", by="operator")

    # 5) S1 exit_price caps fair_value stretch (<6h) and drops fair_value after 6h; _exit_actions reprices
    #    downward at day 6 even when sigma_24h=6% (previously blocked by 0.25*s24=1.5%), never upward
    ex_0h = policy.exit_price(cost_ada=302.2, tokens=1650.0, age_s=1800, fair_value=0.250, pol=pol_s2)
    ex_8h = policy.exit_price(cost_ada=302.2, tokens=1650.0, age_s=8 * 3600, fair_value=0.250, pol=pol_s2)
    be_n = ex_0h["breakeven"]
    fv_capped_ok = abs(ex_0h["price"] - be_n * 1.035) < 1e-9 and ex_8h["binding"] != "fair_value"

    pos_6d = {"NIGHT": {"asset": "NIGHT", "tokens": 1650.0, "tokens_db": 1650.0, "cost_ada": 302.2,
                        "age_s": 6 * 86400, "order_ids": ["m1"], "spot": 0.20}}
    oo_high = [{"order_id": "m1", "asset": "NIGHT", "side": "sell", "utxo": "u#0", "price": be_n * 1.018,
                "tokens": 1650.0, "created_at": now - 12 * 3600, "chain_status": "OPEN"}]
    oo_low = [{"order_id": "m1", "asset": "NIGHT", "side": "sell", "utxo": "u#0", "price": be_n * 1.005,
               "tokens": 1650.0, "created_at": now - 12 * 3600, "chain_status": "OPEN"}]
    acts_down, _ = plans._exit_actions("NIGHT", pol_s2, port(wallet=100, positions=pos_6d, open_orders=oo_high), MKT)
    pos_0d = copy.deepcopy(pos_6d)
    pos_0d["NIGHT"]["age_s"] = 600
    acts_up, _ = plans._exit_actions("NIGHT", pol_s2, port(wallet=100, positions=pos_0d, open_orders=oo_low), MKT)
    reprice_ok = len(acts_down) == 1 and acts_down[0]["type"] == "reprice" and len(acts_up) == 0

    install(port(wallet=200), MKT)
    ok = (
        r_sig["status"] == "executed"
        and r_sig["results"][0].get("autonomous_strategy") == "S2_shock_fade"
        and tagged_auto
        and so_used_after_s2 == 0.0
        and len(CALLS["place"]) == 1
        and r_adhoc["status"] == "needs_confirmation"
        and r_wrong_asset["status"] == "needs_confirmation"
        and r_frozen["status"] == "needs_confirmation"
        and fv_capped_ok
        and reprice_ok
    )
    return ok, (
        f"sig={r_sig['status']} so_used={so_used_after_s2} adhoc={r_adhoc['status']} "
        f"wrong_asset={r_wrong_asset['status']} frozen={r_frozen['status']} fv_cap={fv_capped_ok} rep={reprice_ok}"
    )


if __name__ == "__main__":
    n_ok = sum(RESULTS)
    print(f"SUMMARY {n_ok}/{len(RESULTS)}")
    sys.exit(0 if n_ok == len(RESULTS) else 1)

