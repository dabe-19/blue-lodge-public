#!/usr/bin/env python3
"""
Trading journal: fills -> markouts, round trips with chain-measured net P&L, equity / drawdown
history (sets the freeze override), and the statistics the gates use.

Markouts: every fill schedules marks at +5m / +1h / +6h / +24h. A mark is taken from the pool
recorder (exact AMM spot at that time) only once the recorder has *checked the pool after* the
due time; if the recorder had a gap the markout is 'missing', never a stale guess.
  buy  markout = (mark - fill) * tokens      (positive = we bought below where price went)
  sell markout = (fill - mark) * tokens

Trips: entry_ada / exit_ada are net cash flows measured on chain by the order watcher (locked
lovelace minus refunds, plus L1 fees), so net_pnl_ada already includes the fees actually paid.
"""
from __future__ import annotations

import json
import math
import time
from typing import Any, Dict, Iterable, List, Optional

from lib.tools.trading import store

HORIZONS_S = (300, 3600, 21600, 86400)
HORIZON_NAMES = {300: "5m", 3600: "1h", 21600: "6h", 86400: "24h"}
NAME_TO_S = {v: k for k, v in HORIZON_NAMES.items()}
Z80 = 1.2816  # one-sided 80% lower bound


# ---------------------------------------------------------------------------
# Fills + markouts
# ---------------------------------------------------------------------------

def record_fill(con, fill_id: str, mode: str, strategy: Optional[str], asset: str, side: str,
                price: float, tokens: Optional[float], ts: Optional[int] = None,
                new_rules: bool = True, horizons: Iterable[int] = HORIZONS_S) -> int:
    """Schedules markouts for a fill. Idempotent per (fill_id, horizon)."""
    if side not in ("buy", "sell") or not price or price <= 0:
        raise ValueError("record_fill needs side buy|sell and a positive price")
    ts = int(ts or time.time())
    n = 0
    for h in horizons:
        cur = con.execute(
            "INSERT OR IGNORE INTO markouts(fill_id, horizon_s, mode, strategy, asset, side, fill_ts, fill_price, tokens,"
            " due_ts, status, new_rules) VALUES (?,?,?,?,?,?,?,?,?,?, 'pending', ?)",
            (fill_id, int(h), mode, strategy, asset.upper(), side, ts, float(price), tokens, ts + int(h), int(bool(new_rules))))
        n += cur.rowcount
    con.commit()
    return n


def _recorder_checked_after(mcon, asset: str, ts: int) -> bool:
    r = mcon.execute("SELECT MAX(last_checked) FROM recorder_state WHERE asset=?", (asset.upper(),)).fetchone()
    return bool(r and r[0] and int(r[0]) >= ts)


def capture_markouts(con, mcon=None, now: Optional[float] = None, missing_after_s: int = 2 * 86400) -> Dict[str, int]:
    """Fills in due markouts from market.db. Returns counts {done, missing, waiting}."""
    from lib.tools.quant import market_db as mdb
    now = int(now or time.time())
    own = mcon is None
    mcon = mcon or mdb.connect()
    out = {"done": 0, "missing": 0, "waiting": 0}
    try:
        rows = con.execute("SELECT * FROM markouts WHERE status='pending' AND due_ts<=?", (now,)).fetchall()
        for r in rows:
            if not _recorder_checked_after(mcon, r["asset"], r["due_ts"]):
                if now - r["due_ts"] > missing_after_s:
                    con.execute("UPDATE markouts SET status='missing' WHERE fill_id=? AND horizon_s=?",
                                (r["fill_id"], r["horizon_s"]))
                    out["missing"] += 1
                else:
                    out["waiting"] += 1
                continue
            mark = mdb.spot_at(mcon, r["asset"], r["due_ts"])
            if not mark:
                con.execute("UPDATE markouts SET status='missing' WHERE fill_id=? AND horizon_s=?",
                            (r["fill_id"], r["horizon_s"]))
                out["missing"] += 1
                continue
            sign = 1.0 if r["side"] == "buy" else -1.0
            bps = sign * (mark / r["fill_price"] - 1.0) * 1e4
            ada = sign * (mark - r["fill_price"]) * r["tokens"] if r["tokens"] else None
            con.execute("UPDATE markouts SET mark_price=?, markout_ada=?, markout_bps=?, status='done' "
                        "WHERE fill_id=? AND horizon_s=?", (mark, ada, bps, r["fill_id"], r["horizon_s"]))
            out["done"] += 1
        con.commit()
    finally:
        if own:
            mcon.close()
    return out


def markout_stats(con, horizon: str = "6h", mode: Optional[str] = None, strategy: Optional[str] = None,
                  since: int = 0, new_rules_only: bool = False) -> Dict[str, Any]:
    q = "SELECT markout_bps, markout_ada FROM markouts WHERE status='done' AND horizon_s=? AND fill_ts>=?"
    args: List[Any] = [NAME_TO_S.get(horizon, 21600), since]
    if mode:
        q += " AND mode=?"
        args.append(mode)
    if strategy:
        q += " AND strategy=?"
        args.append(strategy)
    if new_rules_only:
        q += " AND new_rules=1"
    rows = con.execute(q, args).fetchall()
    s = describe([r[0] for r in rows])
    s["mean_ada"] = (sum(r[1] for r in rows if r[1] is not None) / len(rows)) if rows else None
    s["horizon"] = horizon
    return s


# ---------------------------------------------------------------------------
# Trips
# ---------------------------------------------------------------------------

def open_trip(con, trip_id: str, mode: str, strategy: str, asset: str, entry_price: Optional[float],
              tokens: Optional[float], entry_ada: Optional[float], fees_ada: Optional[float] = None,
              buy_order_id: Optional[str] = None, new_rules: bool = True, ts: Optional[int] = None,
              meta: Optional[Dict[str, Any]] = None) -> bool:
    cur = con.execute(
        "INSERT OR IGNORE INTO trips(trip_id, mode, strategy, asset, opened_at, entry_price, tokens, entry_ada, fees_ada,"
        " new_rules, buy_order_id, meta) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        (trip_id, mode, strategy, asset.upper(), int(ts or time.time()), entry_price, tokens, entry_ada, fees_ada,
         int(bool(new_rules)), buy_order_id, json.dumps(meta or {})))
    con.commit()
    return cur.rowcount == 1


def close_trip(con, trip_id: str, exit_price: Optional[float], exit_ada: float, fees_ada: Optional[float] = None,
               sell_order_id: Optional[str] = None, ts: Optional[int] = None,
               net_pnl_ada: Optional[float] = None) -> Optional[Dict[str, Any]]:
    """Closes an open trip. net = exit_ada - entry_ada unless the caller passes a measured figure."""
    r = con.execute("SELECT * FROM trips WHERE trip_id=?", (trip_id,)).fetchone()
    if not r or r["closed_at"]:
        return None
    net = net_pnl_ada if net_pnl_ada is not None else (
        exit_ada - r["entry_ada"] if r["entry_ada"] is not None else None)
    fees = (r["fees_ada"] or 0.0) + (fees_ada or 0.0) if (r["fees_ada"] is not None or fees_ada is not None) else None
    con.execute("UPDATE trips SET closed_at=?, exit_price=?, exit_ada=?, fees_ada=?, net_pnl_ada=?, sell_order_id=? "
                "WHERE trip_id=?", (int(ts or time.time()), exit_price, exit_ada, fees, net, sell_order_id, trip_id))
    con.commit()
    return dict(con.execute("SELECT * FROM trips WHERE trip_id=?", (trip_id,)).fetchone())


def trips(con, mode: Optional[str] = None, strategy: Optional[str] = None, closed: Optional[bool] = True,
          since: int = 0, new_rules_only: bool = False, limit: int = 500) -> List[Dict[str, Any]]:
    q = "SELECT * FROM trips WHERE opened_at>=?"
    args: List[Any] = [since]
    if mode:
        q += " AND mode=?"
        args.append(mode)
    if strategy:
        q += " AND strategy=?"
        args.append(strategy)
    if closed is True:
        q += " AND closed_at IS NOT NULL"
    elif closed is False:
        q += " AND closed_at IS NULL"
    if new_rules_only:
        q += " AND new_rules=1"
    q += " ORDER BY opened_at DESC LIMIT ?"
    args.append(limit)
    return [dict(r) for r in con.execute(q, args)]


# ---------------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------------

def describe(xs: Iterable[Optional[float]]) -> Dict[str, Any]:
    v = [float(x) for x in xs if x is not None and math.isfinite(float(x))]
    n = len(v)
    if n == 0:
        return {"n": 0}
    mean = sum(v) / n
    sd = math.sqrt(sum((x - mean) ** 2 for x in v) / (n - 1)) if n > 1 else None
    se = sd / math.sqrt(n) if sd is not None else None
    return {"n": n, "mean": mean, "sd": sd, "se": se, "lower80": (mean - Z80 * se) if se is not None else None,
            "win_rate": sum(1 for x in v if x > 0) / n, "total": sum(v)}


def sim_stats(con, strategy: str, since: int = 0, last_n: Optional[int] = None) -> Dict[str, Any]:
    q = ("SELECT net_pnl_ada, created_at FROM sim_trades WHERE strategy=? AND status IN ('closed','timeout') "
         "AND created_at>=? ORDER BY created_at DESC")
    rows = con.execute(q, (strategy, since)).fetchall()
    if last_n:
        rows = rows[:last_n]
    s = describe([r[0] for r in rows])
    first = con.execute("SELECT MIN(created_at) FROM sim_trades WHERE strategy=?", (strategy,)).fetchone()[0]
    s["days_running"] = ((time.time() - first) / 86400.0) if first else 0.0
    return s


# ---------------------------------------------------------------------------
# Equity / drawdown / freeze
# ---------------------------------------------------------------------------

def snapshot_equity(con, equity_ada: Optional[float], pol: Dict[str, Any], detail: Optional[Dict[str, Any]] = None,
                    ts: Optional[int] = None) -> Dict[str, Any]:
    """Records equity, updates the peak and sets the freeze override at >= freeze_drawdown_pct.
    External deposits/withdrawals should be recorded as 'flow' events so they do not count as P&L:
    the peak is reset (rebased) when detail['flow_ada'] is given.
    Single-tick unconfirmed spikes (>5% above prior peak without flow_ada) do not ratify a new peak
    unless the preceding snapshot also confirmed that level."""
    if equity_ada is None:
        return {"status": "unavailable", "reason": "equity unknown (wallet unreadable)"}
    ts = int(ts or time.time())
    prev = con.execute("SELECT equity_ada, peak_ada FROM equity ORDER BY ts DESC LIMIT 1").fetchone()
    flow = float((detail or {}).get("flow_ada") or 0.0)
    eq_f = float(equity_ada)
    if prev:
        prev_eq, prev_peak = float(prev[0]), float(prev[1])
        base_peak = prev_peak + flow
        if flow == 0.0 and eq_f > base_peak * 1.05 and prev_eq <= base_peak * 1.05:
            # Unconfirmed single-tick spike (e.g. indexer lag double-counting an order UTxO):
            # wait for the next snapshot to confirm before raising peak_ada.
            peak = base_peak
        else:
            peak = max(eq_f, base_peak)
    else:
        peak = eq_f
    dd = 0.0 if peak <= 0 else max(0.0, (peak - eq_f) / peak * 100.0)
    con.execute("INSERT OR REPLACE INTO equity VALUES (?,?,?,?,?)", (ts, eq_f, peak, dd,
                                                                  json.dumps(detail or {}, default=str)))
    con.commit()
    out = {"status": "ok", "equity_ada": equity_ada, "peak_ada": peak, "drawdown_pct": dd, "froze": False}
    lim = float(pol["gates"]["freeze_drawdown_pct"])
    if dd >= lim and not store.get_override(con, "freeze"):
        store.set_override(con, "freeze", {"at": ts, "drawdown_pct": round(dd, 2), "peak_ada": peak,
                                           "equity_ada": equity_ada}, by="journal",
                           reason=f"drawdown {dd:.1f}% >= {lim:.0f}%: all strategies to simulation")
        out["froze"] = True
    return out


def drawdown(con) -> Dict[str, Any]:
    r = con.execute("SELECT * FROM equity ORDER BY ts DESC LIMIT 1").fetchone()
    return dict(r) if r else {"equity_ada": None, "peak_ada": None, "drawdown_pct": None}


# ---------------------------------------------------------------------------
# Summary for crypto_journal / crypto_review
# ---------------------------------------------------------------------------

def summary(con, pol: Dict[str, Any], window_days: float = 30.0, strategy: Optional[str] = None) -> Dict[str, Any]:
    since = int(time.time() - window_days * 86400)
    live = trips(con, mode="live", strategy=strategy, since=since)
    live_new = [t for t in live if t["new_rules"]]
    out: Dict[str, Any] = {
        "window_days": window_days,
        "live_trips": {"all": describe(t["net_pnl_ada"] for t in live),
                       "new_rules": describe(t["net_pnl_ada"] for t in live_new),
                       "recent": [{k: t[k] for k in ("trip_id", "strategy", "asset", "opened_at", "closed_at",
                                                     "entry_ada", "exit_ada", "net_pnl_ada", "new_rules")}
                                  for t in live[:10]]},
        "open_trips": [{k: t[k] for k in ("trip_id", "strategy", "asset", "opened_at", "entry_ada", "tokens")}
                       for t in trips(con, mode="live", closed=False)],
        "markouts": {h: markout_stats(con, h, mode="live", strategy=strategy, since=since) for h in ("5m", "1h", "6h", "24h")},
        "markouts_pending": con.execute("SELECT COUNT(*) FROM markouts WHERE status='pending'").fetchone()[0],
        "simulated": {},
        "drawdown": drawdown(con),
    }
    names = [strategy] if strategy else [n for n in pol.get("strategies", {}) if n.startswith("S")]
    for n in names:
        out["simulated"][n] = sim_stats(con, n, since=since)
    return out
