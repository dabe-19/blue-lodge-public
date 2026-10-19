#!/usr/bin/env python3
"""
Universal operator escalation (grill-me Q7).

A fixed-rule detector (position watcher, gate evaluator, cron jobs with '# NOTIFY: escalate',
or George himself via operator_notify / operator_ask) raises an escalation. Guards run first so
compute is not spent on noise:
  * dedup: the same (kind, subject) is not re-sent within dedup_hours (default 6 h)
  * rate limit: at most max_per_hour deliveries per rolling hour (default 4)
  * quiet hours: non-urgent escalations raised in quiet hours are deferred and flushed after
Then the escalation is published on the event bus as 'operator/escalation'. The reactor runs a
headless George (read-only tools + crypto_plan + operator_notify/operator_ask, 3 steps) to write
the message. If the bus or the headless run is unavailable, the raw text is delivered directly.

Delivery is a Discord DM to the operator when Discord is configured, and always an entry in the
inbox (escalations.db), which the web desk shows. Answers: 'confirm P-XXXXXX' from the operator
is routed by the Discord bridge to the trading confirm path; any other reply to an open ask is
recorded here and opens an interactive George session with this context.

DB: $ESCALATIONS_DB_PATH or $GEORGE_DIR/ipc/escalations.db. Pure stdlib.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
LODGE_DIR = Path(os.environ.get("LODGE_DIR", _REPO_ROOT))

SEVERITIES = ("info", "normal", "urgent")
KIND_RE = re.compile(r"^[a-z0-9_./:-]{2,64}$")
PLAN_RE = re.compile(r"^P-[0-9A-F]{6}$")
PLAN_FIND_RE = re.compile(r"\bP-[0-9A-F]{6}\b")
ASK_DEFAULT_TTL_S = 600
DEFAULT_CFG = {"max_per_hour": 4, "dedup_hours": 6,
               "quiet_hours": {"start": "22:00", "end": "07:00", "tz": "America/Chicago"}}

_SCHEMA = """
CREATE TABLE IF NOT EXISTS escalations (
    id TEXT PRIMARY KEY, ts INTEGER NOT NULL, kind TEXT NOT NULL, subject TEXT NOT NULL,
    severity TEXT NOT NULL, text TEXT NOT NULL, plan_id TEXT, context TEXT, source TEXT,
    status TEXT NOT NULL, reason TEXT, channel TEXT, delivered_at INTEGER, message TEXT);
CREATE INDEX IF NOT EXISTS ix_esc_kind ON escalations(kind, subject, ts);
CREATE INDEX IF NOT EXISTS ix_esc_status ON escalations(status, ts);
CREATE TABLE IF NOT EXISTS asks (
    corr_id TEXT PRIMARY KEY, ts INTEGER NOT NULL, escalation_id TEXT, plan_id TEXT, text TEXT NOT NULL,
    status TEXT NOT NULL, answer TEXT, answered_at INTEGER, expires_at INTEGER NOT NULL);
"""


def db_path() -> Path:
    p = os.environ.get("ESCALATIONS_DB_PATH")
    if p:
        return Path(p)
    return Path(os.environ.get("GEORGE_DIR", LODGE_DIR / ".george")) / "ipc" / "escalations.db"


def connect(path: Optional[Path] = None) -> sqlite3.Connection:
    path = Path(path) if path else db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(path), timeout=30)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    con.executescript(_SCHEMA)
    return con


def config() -> Dict[str, Any]:
    try:
        from lib.tools.trading.policy import load_policy
        cfg = dict(DEFAULT_CFG)
        cfg.update(load_policy().get("escalation") or {})
        return cfg
    except Exception:
        return dict(DEFAULT_CFG)


# ---------------------------------------------------------------------------
# Keys / operator identity
# ---------------------------------------------------------------------------

def get_key(name: str) -> Optional[str]:
    v = os.environ.get(name)
    if v:
        return v
    f = Path(os.environ.get("GEORGE_CONFIG_DIR", LODGE_DIR / ".george")) / "keys.conf"
    try:
        for line in f.read_text().splitlines():
            if line.startswith(name + "="):
                return line.split("=", 1)[1].strip() or None
    except OSError:
        pass
    return None


def operator_ids() -> List[str]:
    ids: List[str] = []
    for k in ("DISCORD_OPERATOR_ID", "DISCORD_OWNER_ID", "DISCORD_OWNER_IDS"):
        v = get_key(k)
        if v:
            ids += [x.strip() for x in v.split(",") if x.strip().isdigit()]
    return list(dict.fromkeys(ids))


def discord_configured() -> bool:
    return bool(get_key("DISCORD_BOT_TOKEN") and operator_ids())


# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------

def _hm(s: str) -> Tuple[int, int]:
    h, m = s.split(":")
    return int(h), int(m)


def in_quiet_hours(now: Optional[float] = None, cfg: Optional[Dict[str, Any]] = None) -> bool:
    cfg = cfg or config()
    q = cfg.get("quiet_hours") or {}
    if not q.get("start") or not q.get("end"):
        return False
    try:
        from zoneinfo import ZoneInfo
        t = datetime.fromtimestamp(now or time.time(), ZoneInfo(q.get("tz") or "UTC"))
    except Exception:
        t = datetime.utcfromtimestamp(now or time.time())
    sh, sm = _hm(q["start"])
    eh, em = _hm(q["end"])
    cur, start, end = t.hour * 60 + t.minute, sh * 60 + sm, eh * 60 + em
    return (start <= cur < end) if start < end else (cur >= start or cur < end)


def quiet_hours_end(now: Optional[float] = None, cfg: Optional[Dict[str, Any]] = None) -> int:
    cfg = cfg or config()
    now = now or time.time()
    t = now
    for _ in range(24 * 12):
        t += 300
        if not in_quiet_hours(t, cfg):
            return int(t)
    return int(now + 9 * 3600)


def guard(con, kind: str, subject: str, severity: str, now: Optional[float] = None,
          cfg: Optional[Dict[str, Any]] = None) -> Tuple[str, str]:
    """Returns (decision, reason): decision in {'send', 'suppress', 'defer'}."""
    cfg = cfg or config()
    now = int(now or time.time())
    dd = int(float(cfg.get("dedup_hours", 6)) * 3600)
    r = con.execute("SELECT id, ts FROM escalations WHERE kind=? AND subject=? AND status IN ('delivered','raised','deferred','expired','answered') "
                    "AND ts>=? ORDER BY ts DESC LIMIT 1", (kind, subject, now - dd)).fetchone()
    if r:
        return "suppress", f"duplicate of {r['id']} ({(now - r['ts']) // 60} min ago; dedup {dd // 3600} h)"
    n = con.execute("SELECT COUNT(*) FROM escalations WHERE status IN ('delivered','expired','answered') AND delivered_at>=?", (now - 3600,)).fetchone()[0]
    if n >= int(cfg.get("max_per_hour", 4)):
        return ("defer" if severity != "info" else "suppress"), f"rate limit: {n} delivered in the last hour"
    if severity != "urgent" and kind != "george/ask" and in_quiet_hours(now, cfg):
        return "defer", "quiet hours"
    return "send", ""


# ---------------------------------------------------------------------------
# Delivery
# ---------------------------------------------------------------------------

def _discord_dm(text: str) -> Tuple[bool, str]:
    ops = operator_ids()
    if not ops or not get_key("DISCORD_BOT_TOKEN"):
        return False, "discord not configured"
    script = 'source "$1/lib/comms/social.sh" >/dev/null 2>&1 && discord_dm "$2" "$(cat)" >/dev/null 2>&1'
    try:
        p = subprocess.run(["bash", "-c", script, "_", str(LODGE_DIR), ops[0]], input=text[:1900], text=True,
                           capture_output=True, timeout=30, cwd=str(LODGE_DIR))
        return p.returncode == 0, ("ok" if p.returncode == 0 else f"discord_dm exit {p.returncode}")
    except Exception as e:
        return False, f"{type(e).__name__}"


SEND_DM: Callable[[str], Tuple[bool, str]] = _discord_dm


def _emit_bus(event_type: str, payload: Dict[str, Any]) -> bool:
    if os.environ.get("ESCALATION_NO_BUS") == "1":
        return False
    try:
        from lib.tools.cardano_order_watcher import emit_event_to_bus
        return bool(emit_event_to_bus(event_type, payload, source="escalation"))
    except Exception:
        return False


EMIT: Callable[[str, Dict[str, Any]], bool] = _emit_bus


def _new_id(con, prefix: str, table: str, col: str) -> str:
    for _ in range(20):
        i = f"{prefix}-{secrets.token_hex(3).upper()}"
        if not con.execute(f"SELECT 1 FROM {table} WHERE {col}=?", (i,)).fetchone():
            return i
    raise RuntimeError("id allocation failed")


def _extract_plan_ids(text: Optional[str], explicit_plan_id: Optional[str] = None) -> List[str]:
    ids: List[str] = []
    if explicit_plan_id and PLAN_RE.match(explicit_plan_id):
        ids.append(explicit_plan_id)
    for m in PLAN_FIND_RE.findall(text or ""):
        if m not in ids:
            ids.append(m)
    return ids


def _sync_and_check_plans(plan_ids: List[str], now: Optional[float] = None) -> Tuple[Optional[str], Optional[int], bool, bool, bool]:
    """Expires due plans in trading.db and returns (live_plan_id, live_expires_at, any_confirmable, any_known_in_db, any_executed)."""
    if not plan_ids:
        return None, None, False, False, False
    now_ts = int(now or time.time())
    try:
        from lib.tools.trading import store
        tcon = store.connect()
        try:
            tcon.execute("UPDATE plans SET status='expired' WHERE status='proposed' AND expires_at < ?", (now_ts,))
            tcon.commit()
            any_known = False
            any_executed = False
            for pid in plan_ids:
                r = tcon.execute("SELECT status, expires_at FROM plans WHERE plan_id=?", (pid,)).fetchone()
                if r is not None:
                    any_known = True
                    if r["status"] in ("executed", "partially_executed"):
                        any_executed = True
                    if r["status"] == "proposed" and int(r["expires_at"]) > now_ts:
                        return pid, int(r["expires_at"]), True, True, any_executed
            return None, None, False, any_known, any_executed
        finally:
            tcon.close()
    except Exception:
        return None, None, False, False, False


def _plan_confirmable(plan_id: str) -> bool:
    if not plan_id:
        return False
    _, _, ok, _, _ = _sync_and_check_plans([plan_id])
    return ok


def mark_plan_confirmed(plan_id: str, via: str = "operator", con=None) -> int:
    """Marks any open/expired asks and delivered/raised/expired escalations linked to plan_id as answered."""
    pid = (plan_id or "").strip().upper()
    if not PLAN_RE.match(pid):
        return 0
    own = con is None
    con = con or connect()
    now_ts = int(time.time())
    ans = f"confirm {pid} ({via})" if via else f"confirm {pid}"
    updated = 0
    try:
        for row in con.execute(
            "SELECT corr_id, escalation_id, plan_id, text FROM asks WHERE status IN ('open','expired')"
        ).fetchall():
            if pid in _extract_plan_ids(row["text"], row["plan_id"]):
                con.execute(
                    "UPDATE asks SET status='answered', answer=COALESCE(answer, ?), answered_at=COALESCE(answered_at, ?) WHERE corr_id=?",
                    (ans, now_ts, row["corr_id"]),
                )
                updated += 1
                if row["escalation_id"]:
                    con.execute("UPDATE escalations SET status='answered' WHERE id=?", (row["escalation_id"],))
        for erow in con.execute(
            "SELECT id, plan_id, COALESCE(message, text) AS body FROM escalations WHERE status IN ('delivered','raised','expired')"
        ).fetchall():
            if pid in _extract_plan_ids(erow["body"], erow["plan_id"]):
                con.execute("UPDATE escalations SET status='answered' WHERE id=?", (erow["id"],))
                updated += 1
        con.commit()
        return updated
    finally:
        if own:
            con.close()


def _expire_stale(con, now: Optional[float] = None) -> None:
    """Expires open asks and delivered/raised escalations when their TTL or linked trading plan expires."""
    now_ts = int(now or time.time())
    for row in con.execute("SELECT corr_id, escalation_id, plan_id, text FROM asks WHERE status='open'").fetchall():
        pids = _extract_plan_ids(row["text"], row["plan_id"])
        if pids:
            _, _, any_ok, any_known, any_executed = _sync_and_check_plans(pids, now_ts)
            if any_executed:
                con.execute(
                    "UPDATE asks SET status='answered', answer=COALESCE(answer, ?), answered_at=COALESCE(answered_at, ?) WHERE corr_id=?",
                    (f"confirm {pids[0]}", now_ts, row["corr_id"]),
                )
                if row["escalation_id"]:
                    con.execute("UPDATE escalations SET status='answered' WHERE id=?", (row["escalation_id"],))
            elif any_known and not any_ok:
                con.execute("UPDATE asks SET status='expired' WHERE corr_id=?", (row["corr_id"],))
    con.execute("UPDATE asks SET status='expired' WHERE status='open' AND expires_at<?", (now_ts,))
    # Any escalation whose ask expired (and wasn't answered) also transitions to expired
    con.execute(
        "UPDATE escalations SET status='expired' WHERE status IN ('delivered','raised') "
        "AND id IN (SELECT escalation_id FROM asks WHERE escalation_id IS NOT NULL AND status='expired') "
        "AND id NOT IN (SELECT escalation_id FROM asks WHERE escalation_id IS NOT NULL AND status IN ('open','answered'))"
    )
    for erow in con.execute(
        "SELECT id, ts, delivered_at, plan_id, COALESCE(message, text) AS body FROM escalations WHERE status IN ('delivered','raised')"
    ).fetchall():
        pids = _extract_plan_ids(erow["body"], erow["plan_id"])
        if pids:
            _, _, any_ok, any_known, any_executed = _sync_and_check_plans(pids, now_ts)
            if any_executed:
                con.execute("UPDATE escalations SET status='answered' WHERE id=?", (erow["id"],))
            elif any_known and not any_ok:
                con.execute("UPDATE escalations SET status='expired' WHERE id=?", (erow["id"],))
        else:
            ref_ts = int(erow["delivered_at"] or erow["ts"] or 0)
            if ref_ts > 0 and now_ts - ref_ts > ASK_DEFAULT_TTL_S:
                con.execute("UPDATE escalations SET status='expired' WHERE id=? AND status='raised'", (erow["id"],))
    con.commit()


def deliver(con, esc_id: str, text: Optional[str] = None) -> Dict[str, Any]:
    """Sends (or re-sends with George's wording) an escalation. Inbox always; Discord when configured."""
    r = con.execute("SELECT * FROM escalations WHERE id=?", (esc_id,)).fetchone()
    if not r:
        return {"status": "not_found"}
    body = (text or r["text"]).strip()
    pids = _extract_plan_ids(body, r["plan_id"])
    canonical_plan_id = r["plan_id"] or (pids[0] if pids else None)
    ask_expires = int(time.time() + ASK_DEFAULT_TTL_S)
    if pids:
        try:
            from lib.tools.trading import plans as _tr_plans
            _tr_plans.refresh_plans_in_text(" ".join([body] + pids))
        except Exception:
            pass
        live_pid, live_exp, any_ok, _, _ = _sync_and_check_plans(pids)
        if any_ok and live_pid:
            canonical_plan_id = live_pid
            if live_exp:
                ask_expires = live_exp
            if canonical_plan_id not in body:
                body += f"\n\nPlan {canonical_plan_id}: reply 'confirm {canonical_plan_id}' to execute it (expires 10 min after delivery)."
        elif r["plan_id"]:
            body += (f"\n\n(Plan {r['plan_id']} has expired or already run. Reply in this DM and George will "
                     "rebuild it against current prices.)")
    ok, why = SEND_DM(f"[{r['severity'].upper()}] {body}")
    channel = "discord+inbox" if ok else "inbox"
    now_ts = int(time.time())
    con.execute("UPDATE escalations SET status='delivered', channel=?, delivered_at=?, message=?, reason=?, plan_id=? WHERE id=?",
                (channel, now_ts, body, None if ok else why, canonical_plan_id, esc_id))
    existing_ask = con.execute("SELECT corr_id FROM asks WHERE escalation_id=? AND status='open'", (esc_id,)).fetchone()
    if existing_ask:
        con.execute("UPDATE asks SET plan_id=COALESCE(?, plan_id), expires_at=? WHERE corr_id=?",
                    (canonical_plan_id, ask_expires, existing_ask["corr_id"]))
    elif r["severity"] != "info" and r["kind"] != "george/ask":
        con.execute("INSERT INTO asks VALUES (?,?,?,?,?, 'open', NULL, NULL, ?)",
                    (_new_id(con, "Q", "asks", "corr_id"), now_ts, esc_id, canonical_plan_id, body[:4000],
                     ask_expires))
    con.commit()
    return {"status": "delivered", "id": esc_id, "channel": channel, "discord": why, "plan_id": canonical_plan_id}


def raise_escalation(kind: str, subject: str, text: str, severity: str = "normal", plan_id: Optional[str] = None,
                     context: Optional[Dict[str, Any]] = None, source: str = "detector", headless: bool = True,
                     con=None, now: Optional[float] = None) -> Dict[str, Any]:
    if not KIND_RE.match(kind or ""):
        raise ValueError("invalid escalation kind")
    if severity not in SEVERITIES:
        raise ValueError("severity must be info|normal|urgent")
    if plan_id and not PLAN_RE.match(plan_id):
        raise ValueError("invalid plan id")
    own = con is None
    con = con or connect()
    try:
        cfg = config()
        decision, reason = guard(con, kind, subject[:200], severity, now, cfg)
        eid = _new_id(con, "E", "escalations", "id")
        status = {"send": "raised", "suppress": "suppressed", "defer": "deferred"}[decision]
        con.execute("INSERT INTO escalations(id, ts, kind, subject, severity, text, plan_id, context, source, status, reason)"
                    " VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                    (eid, int(now or time.time()), kind, subject[:200], severity, text[:4000], plan_id,
                     json.dumps(context or {}, default=str)[:20000], source, status, reason or None))
        con.commit()
        out = {"id": eid, "status": status, "reason": reason}
        if decision != "send":
            return out
        if headless and EMIT("operator/escalation", {"id": eid, "kind": kind, "severity": severity}):
            out["routed"] = "headless_george"
            return out
        out.update(deliver(con, eid))
        out["routed"] = "direct"
        return out
    finally:
        if own:
            con.close()


def flush_deferred(con=None, now: Optional[float] = None) -> List[Dict[str, Any]]:
    """Delivers deferred escalations once quiet hours are over and the rate limit allows."""
    own = con is None
    con = con or connect()
    out = []
    try:
        cfg = config()
        if in_quiet_hours(now, cfg):
            return []
        for r in con.execute("SELECT id, severity FROM escalations WHERE status='deferred' ORDER BY ts").fetchall():
            n = con.execute("SELECT COUNT(*) FROM escalations WHERE status='delivered' AND delivered_at>=?",
                            (int(now or time.time()) - 3600,)).fetchone()[0]
            if n >= int(cfg.get("max_per_hour", 4)):
                break
            out.append(deliver(con, r["id"]))
        return out
    finally:
        if own:
            con.close()


def operator_notify(text: str, severity: str = "normal", escalation_id: Optional[str] = None,
                    con=None) -> Dict[str, Any]:
    """George's one-way message to the operator (works in autonomous runs)."""
    own = con is None
    con = con or connect()
    try:
        if escalation_id:
            r = con.execute("SELECT status FROM escalations WHERE id=?", (escalation_id,)).fetchone()
            if r and r["status"] == "raised":
                return deliver(con, escalation_id, text)
        return raise_escalation("george/notify", f"notify:{text[:80]}", text, severity, source="george",
                                headless=False, con=con)
    finally:
        if own:
            con.close()


def operator_ask(text: str, plan_id: Optional[str] = None, escalation_id: Optional[str] = None,
                 ttl_s: int = ASK_DEFAULT_TTL_S, con=None) -> Dict[str, Any]:
    """Question to the operator; returns a corr_id. A 'confirm P-XXXXXX' reply executes the plan;
    any other reply is recorded as the answer and opens an interactive session."""
    if plan_id and not PLAN_RE.match(plan_id):
        raise ValueError("invalid plan id")
    own = con is None
    con = con or connect()
    try:
        if not plan_id:
            pids = _extract_plan_ids(text)
            if pids:
                plan_id = pids[0]
            elif escalation_id:
                er = con.execute("SELECT plan_id FROM escalations WHERE id=?", (escalation_id,)).fetchone()
                if er and er["plan_id"]:
                    plan_id = er["plan_id"]
        eff_ttl = min(int(ttl_s or ASK_DEFAULT_TTL_S), ASK_DEFAULT_TTL_S) if plan_id else int(ttl_s or ASK_DEFAULT_TTL_S)
        cid = _new_id(con, "Q", "asks", "corr_id")
        now_ts = int(time.time())
        con.execute("INSERT INTO asks VALUES (?,?,?,?,?, 'open', NULL, NULL, ?)",
                    (cid, now_ts, escalation_id, plan_id, text[:4000], now_ts + eff_ttl))
        con.commit()
        msg = f"{text.strip()}\n\n(ref {cid}"
        msg += f"; reply 'confirm {plan_id}' to execute" if plan_id else ""
        msg += "; any other reply goes to George)"
        if escalation_id:
            r = con.execute("SELECT status FROM escalations WHERE id=?", (escalation_id,)).fetchone()
            if r and r["status"] == "raised":
                d = deliver(con, escalation_id, msg)
                return {"corr_id": cid, **d}
        res = raise_escalation("george/ask", f"ask:{cid}", msg, "normal", plan_id=plan_id, source="george",
                               headless=False, con=con)
        con.execute("UPDATE asks SET escalation_id=? WHERE corr_id=? AND escalation_id IS NULL", (res.get("id"), cid))
        con.commit()
        return {"corr_id": cid, **res}
    finally:
        if own:
            con.close()


def open_asks(con=None) -> List[Dict[str, Any]]:
    own = con is None
    con = con or connect()
    try:
        _expire_stale(con)
        return [dict(r) for r in con.execute("SELECT * FROM asks WHERE status='open' ORDER BY ts DESC")]
    finally:
        if own:
            con.close()


def answer_latest(answer: str, con=None) -> Optional[Dict[str, Any]]:
    """Records the operator's free-text reply against the newest open ask (if any)."""
    own = con is None
    con = con or connect()
    try:
        asks = open_asks(con)
        if not asks:
            return None
        a = asks[0]
        con.execute("UPDATE asks SET status='answered', answer=?, answered_at=? WHERE corr_id=?",
                    (answer[:4000], int(time.time()), a["corr_id"]))
        if a.get("escalation_id"):
            con.execute("UPDATE escalations SET status='answered' WHERE id=?", (a["escalation_id"],))
        con.commit()
        esc = con.execute("SELECT * FROM escalations WHERE id=?", (a.get("escalation_id"),)).fetchone() if a.get("escalation_id") else None
        return {"corr_id": a["corr_id"], "question": a["text"], "plan_id": a["plan_id"],
                "escalation": dict(esc) if esc else None}
    finally:
        if own:
            con.close()


def inbox(limit: int = 30, con=None) -> List[Dict[str, Any]]:
    own = con is None
    con = con or connect()
    try:
        _expire_stale(con)
        return [dict(r) for r in con.execute(
            "SELECT id, ts, kind, subject, severity, status, reason, channel, plan_id, COALESCE(message, text) AS text "
            "FROM escalations WHERE status != 'suppressed' ORDER BY ts DESC LIMIT ?", (limit,))]
    finally:
        if own:
            con.close()


def get(esc_id: str, con=None) -> Optional[Dict[str, Any]]:
    own = con is None
    con = con or connect()
    try:
        r = con.execute("SELECT * FROM escalations WHERE id=?", (esc_id,)).fetchone()
        return dict(r) if r else None
    finally:
        if own:
            con.close()


def main() -> None:
    ap = argparse.ArgumentParser(description="Operator escalation")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("raise")
    s.add_argument("--kind", required=True)
    s.add_argument("--subject", required=True)
    s.add_argument("--text", default=None, help="message text (default: stdin)")
    s.add_argument("--severity", default="normal", choices=SEVERITIES)
    s.add_argument("--plan-id", default=None)
    s.add_argument("--source", default="cli")
    s.add_argument("--no-headless", action="store_true")
    s = sub.add_parser("notify")
    s.add_argument("--text", required=True)
    s.add_argument("--severity", default="normal", choices=SEVERITIES)
    s.add_argument("--escalation-id", default=None)
    s = sub.add_parser("ask")
    s.add_argument("--text", required=True)
    s.add_argument("--plan-id", default=None)
    s.add_argument("--escalation-id", default=None)
    s = sub.add_parser("deliver")
    s.add_argument("--id", required=True)
    s.add_argument("--text", default=None)
    sub.add_parser("flush")
    s = sub.add_parser("inbox")
    s.add_argument("--limit", type=int, default=30)
    s = sub.add_parser("get")
    s.add_argument("--id", required=True)
    s = sub.add_parser("answer")
    s.add_argument("--text", required=True)
    sub.add_parser("asks")
    sub.add_parser("quiet")
    a = ap.parse_args()
    try:
        if a.cmd == "raise":
            text = a.text if a.text is not None else sys.stdin.read()
            out: Any = raise_escalation(a.kind, a.subject, text, a.severity, a.plan_id, source=a.source,
                                        headless=not a.no_headless)
        elif a.cmd == "notify":
            out = operator_notify(a.text, a.severity, a.escalation_id)
        elif a.cmd == "ask":
            out = operator_ask(a.text, a.plan_id, a.escalation_id)
        elif a.cmd == "deliver":
            con = connect()
            try:
                out = deliver(con, a.id, a.text)
            finally:
                con.close()
        elif a.cmd == "flush":
            out = {"delivered": flush_deferred()}
        elif a.cmd == "inbox":
            out = {"inbox": inbox(a.limit), "open_asks": open_asks(), "discord_configured": discord_configured()}
        elif a.cmd == "get":
            out = get(a.id) or {"status": "not_found"}
        elif a.cmd == "answer":
            out = answer_latest(a.text) or {"status": "no_open_ask"}
        elif a.cmd == "asks":
            out = {"open_asks": open_asks()}
        else:
            out = {"quiet_hours": in_quiet_hours(), "config": config()}
    except ValueError as e:
        out = {"status": "error", "reason": str(e)}
    print(json.dumps(out, default=str))


if __name__ == "__main__":
    main()
