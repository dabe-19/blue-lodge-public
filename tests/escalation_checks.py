#!/usr/bin/env python3
"""
P3 escalation checks (offline). Each check prints "<name> PASS|FAIL <detail>".
Discord delivery is injected (escalation.SEND_DM) and the event bus is disabled, so nothing
leaves the machine and no headless George run is started.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))
TMP = Path(tempfile.mkdtemp(prefix="george-escalation-"))
os.environ["ESCALATIONS_DB_PATH"] = str(TMP / "escalations.db")
os.environ["TRADING_DB_PATH"] = str(TMP / "trading.db")
os.environ["TRADING_POLICY_PATH"] = str(TMP / "missing_policy.json")
os.environ["GEORGE_CONFIG_DIR"] = str(TMP / "nokeys")
os.environ["ESCALATION_NO_BUS"] = "1"
for k in ("DISCORD_BOT_TOKEN", "DISCORD_OPERATOR_ID", "DISCORD_OWNER_ID", "DISCORD_OWNER_IDS"):
    os.environ.pop(k, None)

from lib.comms import escalation as esc  # noqa: E402

RESULTS = []
SENT = []
esc.SEND_DM = lambda text: (SENT.append(text) or True, "ok")
esc.EMIT = lambda t, p: False


def check(name):
    def deco(fn):
        try:
            ok, detail = fn()
        except Exception as e:
            ok, detail = False, f"{type(e).__name__}: {e}"
        RESULTS.append(ok)
        print(f"{name} {'PASS' if ok else 'FAIL'} {detail}")
        return fn
    return deco


def fresh():
    p = Path(os.environ["ESCALATIONS_DB_PATH"])
    for s in ("", "-wal", "-shm"):
        Path(str(p) + s).unlink(missing_ok=True)
    SENT.clear()
    return esc.connect()


def chicago(h, m=0):
    from zoneinfo import ZoneInfo
    d = datetime.now(ZoneInfo("America/Chicago")).replace(hour=h, minute=m, second=0, microsecond=0)
    return d.timestamp()


NOON = chicago(12)
NIGHT = chicago(23, 30)


@check("quiet_hours_window")
def _():
    r = (esc.in_quiet_hours(NIGHT), esc.in_quiet_hours(chicago(3)), esc.in_quiet_hours(NOON), esc.in_quiet_hours(chicago(7, 1)))
    return r == (True, True, False, False), str(r)


@check("dedup_6h")
def _():
    con = fresh()
    a = esc.raise_escalation("trading/stuck", "SNEK", "first", con=con, now=NOON)
    b = esc.raise_escalation("trading/stuck", "SNEK", "again", con=con, now=NOON + 600)
    c = esc.raise_escalation("trading/stuck", "NIGHT", "other subject", con=con, now=NOON + 600)
    d = esc.raise_escalation("trading/stuck", "SNEK", "after 7h", con=con, now=NOON + 7 * 3600)
    ok = (a["status"] == "delivered" and b["status"] == "suppressed" and c["status"] == "delivered"
          and d["status"] == "delivered")
    return ok, f"{a['status']},{b['status']},{c['status']},{d['status']}"


@check("rate_limit_4_per_hour")
def _():
    con = fresh()
    now = time.time()
    if esc.in_quiet_hours(now):
        now = NOON   # guard() uses 'now' for quiet hours; deliveries stamp real time
    out = [esc.raise_escalation("cron/x", f"s{i}", "t", con=con, now=now)["status"] for i in range(5)]
    info = esc.raise_escalation("cron/x", "s9", "t", severity="info", con=con, now=now)["status"]
    ok = out[:4] == ["delivered"] * 4 and out[4] == "deferred" and info == "suppressed"
    return ok, f"{out} info={info}"


@check("quiet_hours_defer_and_urgent_bypass")
def _():
    con = fresh()
    n = esc.raise_escalation("trading/orders", "o1", "night normal", con=con, now=NIGHT)
    u = esc.raise_escalation("trading/freeze", "dd", "night urgent", severity="urgent", con=con, now=NIGHT)
    sent_at_night = len(SENT)
    f_night = esc.flush_deferred(con=con, now=NIGHT)
    f_day = esc.flush_deferred(con=con, now=NOON)
    st = esc.get(n["id"], con=con)["status"]
    ok = (n["status"] == "deferred" and u["status"] == "delivered" and sent_at_night == 1 and f_night == []
          and len(f_day) == 1 and st == "delivered")
    return ok, f"normal={n['status']} urgent={u['status']} flushed_day={len(f_day)} final={st}"


@check("inbox_fallback_without_discord")
def _():
    con = fresh()
    saved = esc.SEND_DM
    esc.SEND_DM = esc._discord_dm   # real path: no keys configured -> inbox only
    try:
        r = esc.raise_escalation("trading/stuck", "MIN", "no discord", con=con, now=NOON)
    finally:
        esc.SEND_DM = saved
    box = esc.inbox(con=con)
    ok = r["channel"] == "inbox" and box and box[0]["id"] == r["id"] and not esc.discord_configured()
    return ok, f"channel={r.get('channel')} discord={r.get('discord')} inbox={len(box)}"


@check("ask_answer_roundtrip")
def _():
    con = fresh()
    q = esc.operator_ask("Reclaim the SNEK bid?", plan_id="P-ABC123", con=con)
    asks = esc.open_asks(con=con)
    ans = esc.answer_latest("yes, reclaim it", con=con)
    after = esc.open_asks(con=con)
    ok = (q["corr_id"].startswith("Q-") and len(asks) == 1 and ans and ans["corr_id"] == q["corr_id"]
          and ans["plan_id"] == "P-ABC123" and not after and "confirm P-ABC123" in SENT[-1]
          and asks[0]["escalation_id"] == q["id"])
    return ok, f"corr={q['corr_id']} esc={q.get('id')} answered={bool(ans)} open_after={len(after)}"


@check("delivered_escalation_opens_reply_window")
def _():
    con = fresh()
    r = esc.raise_escalation("trading/stuck", "IAG", "stuck", con=con, now=NOON)
    asks = esc.open_asks(con=con)
    i = esc.raise_escalation("cron/y", "z", "fyi", severity="info", con=con, now=NOON)
    asks2 = esc.open_asks(con=con)
    ok = len(asks) == 1 and asks[0]["escalation_id"] == r["id"] and len(asks2) == 1 and i["status"] == "delivered"
    return ok, f"asks={len(asks)} after_info={len(asks2)}"


@check("expired_plan_not_offered_for_confirm")
def _():
    con = fresh()
    r = esc.raise_escalation("trading/orders", "o9", "decide", plan_id="P-DEAD01", con=con, now=NOON)
    msg = SENT[-1]
    return "has expired" in msg and "reply 'confirm" not in msg, msg[-120:].replace("\n", " ")


@check("expired_plan_expires_open_ask_and_escalation")
def _():
    from lib.tools.trading import store
    con = fresh()
    tcon = store.connect()
    now_ts = int(time.time())
    tcon.execute(
        "INSERT OR REPLACE INTO plans(plan_id, created_at, expires_at, origin, intent_json, actions_json, refs_json, plan_hash, tier, status, summary) "
        "VALUES ('P-CAFE01', ?, ?, 'test', '{}', '[]', '{}', 'h1', 'B', 'proposed', 'test plan')",
        (now_ts, now_ts + 600),
    )
    tcon.commit()
    q = esc.operator_ask("Exit SNEK via P-CAFE01?", plan_id="P-CAFE01", con=con)
    live_asks = esc.open_asks(con=con)
    # Now expire the plan in trading.db
    tcon.execute("UPDATE plans SET expires_at=? WHERE plan_id='P-CAFE01'", (now_ts - 5,))
    tcon.commit()
    tcon.close()
    after_asks = esc.open_asks(con=con)
    ans = esc.answer_latest("George, how are you doing?", con=con)
    box = esc.inbox(con=con)
    ok = len(live_asks) == 1 and len(after_asks) == 0 and ans is None and box and box[0]["status"] == "expired"
    return ok, f"live={len(live_asks)} after={len(after_asks)} ans={ans} esc_status={box[0]['status'] if box else None}"


@check("validation")
def _():
    bad = []
    for kw in ({"kind": "Bad Kind!"}, {"severity": "panic"}, {"plan_id": "P-xyz"}):
        args = {"kind": "ok/kind", "subject": "s", "text": "t", "severity": "normal"}
        args.update(kw)
        try:
            esc.raise_escalation(args["kind"], args["subject"], args["text"], args["severity"],
                                 plan_id=args.get("plan_id"), con=fresh())
            bad.append(kw)
        except ValueError:
            pass
    return not bad, f"accepted_invalid={bad}"


if __name__ == "__main__":
    n = sum(RESULTS)
    print(f"SUMMARY {n}/{len(RESULTS)}")
    sys.exit(0 if n == len(RESULTS) else 1)
