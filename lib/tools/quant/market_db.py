#!/usr/bin/env python3
"""
Bounded SQLite store for on-chain pool state, swaps and CEX ticks (market.db).

Retention (enforced by `janitor()`, run daily from cron):
  pool_snapshots  raw 30 days  -> pool_bars_5m   (OHLC per 5 min) kept 1 year
  cex_ticks       raw 30 days  -> cex_bars_5m    kept 1 year
  swaps           forever (small: one row per batch / order)
  api_calls       7 days (call-budget accounting)
A hard size cap (default 2 GB, MARKET_DB_MAX_BYTES) prunes the oldest downsampled
data first, then the oldest raw rows, then VACUUMs.

Path: $MARKET_DB_PATH or $GEORGE_DIR/finance/market.db. Pure stdlib.
"""
from __future__ import annotations

import json
import os
import sqlite3
import sys
import time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

LODGE_DIR = Path(os.environ.get("LODGE_DIR", _REPO_ROOT))
GEORGE_DIR = Path(os.environ.get("GEORGE_DIR", LODGE_DIR / ".george"))

SCHEMA_VERSION = 1
RAW_RETENTION_S = 30 * 86400
BAR_RETENTION_S = 365 * 86400
API_RETENTION_S = 7 * 86400
BAR_S = 300
DEFAULT_MAX_BYTES = 2 * 1024 ** 3

_SCHEMA = """
CREATE TABLE IF NOT EXISTS pool_snapshots (
    ts INTEGER NOT NULL, pool TEXT NOT NULL, asset TEXT NOT NULL, dex TEXT NOT NULL DEFAULT 'MinswapV2',
    reserve_ada REAL NOT NULL, reserve_tok REAL NOT NULL, spot REAL NOT NULL, fee_bps REAL,
    tx TEXT NOT NULL DEFAULT '', src TEXT NOT NULL DEFAULT 'recorder',
    PRIMARY KEY (pool, ts, tx));
CREATE INDEX IF NOT EXISTS ix_snap_asset_ts ON pool_snapshots(asset, ts);
CREATE INDEX IF NOT EXISTS ix_snap_asset_tx ON pool_snapshots(asset, tx);
CREATE TABLE IF NOT EXISTS pool_bars_5m (
    bucket INTEGER NOT NULL, pool TEXT NOT NULL, asset TEXT NOT NULL,
    o REAL, h REAL, l REAL, c REAL, reserve_ada REAL, reserve_tok REAL, n INTEGER,
    PRIMARY KEY (pool, bucket));
CREATE INDEX IF NOT EXISTS ix_bars_asset ON pool_bars_5m(asset, bucket);
CREATE TABLE IF NOT EXISTS swaps (
    tx TEXT NOT NULL, idx INTEGER NOT NULL, ts INTEGER NOT NULL, pool TEXT NOT NULL, asset TEXT NOT NULL,
    kind TEXT NOT NULL, side TEXT, ada_amt REAL, tok_amt REAL, eff_price REAL,
    pre_spot REAL, post_spot REAL, impact_pct REAL, owner TEXT, batcher_fee_ada REAL, n_orders INTEGER,
    PRIMARY KEY (tx, idx));
CREATE INDEX IF NOT EXISTS ix_swaps_asset_ts ON swaps(asset, ts);
CREATE INDEX IF NOT EXISTS ix_swaps_owner ON swaps(owner);
CREATE TABLE IF NOT EXISTS cex_ticks (
    ts INTEGER NOT NULL, symbol TEXT NOT NULL, price REAL NOT NULL, src TEXT NOT NULL DEFAULT 'coinbase',
    PRIMARY KEY (symbol, ts));
CREATE TABLE IF NOT EXISTS cex_bars_5m (
    bucket INTEGER NOT NULL, symbol TEXT NOT NULL, o REAL, h REAL, l REAL, c REAL, n INTEGER,
    PRIMARY KEY (symbol, bucket));
CREATE TABLE IF NOT EXISTS api_calls (
    id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, provider TEXT NOT NULL,
    endpoint TEXT, ok INTEGER NOT NULL DEFAULT 1, purpose TEXT DEFAULT 'live');
CREATE INDEX IF NOT EXISTS ix_api_provider_ts ON api_calls(provider, ts);
CREATE TABLE IF NOT EXISTS recorder_state (
    pool TEXT PRIMARY KEY, asset TEXT NOT NULL, dex TEXT NOT NULL DEFAULT 'MinswapV2',
    lp_unit TEXT, unit TEXT, decimals INTEGER, pool_address TEXT,
    last_tx TEXT, last_height INTEGER, last_tx_index INTEGER, last_ts INTEGER,
    last_checked INTEGER, backfill_page INTEGER DEFAULT 0, backfill_oldest_ts INTEGER,
    backfill_done INTEGER DEFAULT 0, info TEXT);
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
"""


def db_path() -> Path:
    p = os.environ.get("MARKET_DB_PATH")
    return Path(p) if p else GEORGE_DIR / "finance" / "market.db"


def connect(path: Optional[Path] = None) -> sqlite3.Connection:
    path = Path(path) if path else db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(path), timeout=30)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA synchronous=NORMAL")
    con.executescript(_SCHEMA)
    con.execute("INSERT OR IGNORE INTO meta(k, v) VALUES ('schema_version', ?)", (str(SCHEMA_VERSION),))
    con.commit()
    return con


# ---------------------------------------------------------------------------
# Writes
# ---------------------------------------------------------------------------

def record_snapshot(con: sqlite3.Connection, ts: int, pool: str, asset: str, reserve_ada: float,
                    reserve_tok: float, fee_bps: Optional[float] = None, tx: str = "",
                    src: str = "recorder", dex: str = "MinswapV2") -> Optional[float]:
    if reserve_ada <= 0 or reserve_tok <= 0:
        return None
    spot = reserve_ada / reserve_tok
    con.execute("INSERT OR REPLACE INTO pool_snapshots VALUES (?,?,?,?,?,?,?,?,?,?)",
                (int(ts), pool, asset, dex, float(reserve_ada), float(reserve_tok), spot, fee_bps, tx, src))
    return spot


def record_swaps(con: sqlite3.Connection, rows: Iterable[Dict[str, Any]]) -> int:
    cols = ("tx", "idx", "ts", "pool", "asset", "kind", "side", "ada_amt", "tok_amt", "eff_price",
            "pre_spot", "post_spot", "impact_pct", "owner", "batcher_fee_ada", "n_orders")
    n = 0
    for r in rows:
        con.execute(f"INSERT OR REPLACE INTO swaps ({','.join(cols)}) VALUES ({','.join('?' * len(cols))})",
                    tuple(r.get(c) for c in cols))
        n += 1
    return n


def record_cex_tick(con: sqlite3.Connection, ts: int, symbol: str, price: float, src: str = "coinbase") -> None:
    if not price or price <= 0:
        raise ValueError("price must be positive")
    con.execute("INSERT OR REPLACE INTO cex_ticks VALUES (?,?,?,?)", (int(ts), symbol.upper(), float(price), src))


def log_api_call(con: sqlite3.Connection, provider: str, endpoint: str, ok: bool = True,
                 purpose: str = "live") -> None:
    con.execute("INSERT INTO api_calls(ts, provider, endpoint, ok, purpose) VALUES (?,?,?,?,?)",
                (int(time.time()), provider, endpoint[:120], 1 if ok else 0, purpose))
    con.commit()


# ---------------------------------------------------------------------------
# Budget accounting
# ---------------------------------------------------------------------------

def _utc_day_start(now: Optional[float] = None) -> int:
    now = int(now or time.time())
    return now - now % 86400


def calls_today(con: sqlite3.Connection, provider: str, purpose: Optional[str] = None,
                now: Optional[float] = None) -> int:
    q = "SELECT COUNT(*) FROM api_calls WHERE provider=? AND ts>=?"
    args: List[Any] = [provider, _utc_day_start(now)]
    if purpose:
        q += " AND purpose=?"
        args.append(purpose)
    return int(con.execute(q, args).fetchone()[0])


def calls_last(con: sqlite3.Connection, provider: str, seconds: int, now: Optional[float] = None) -> int:
    now = int(now or time.time())
    return int(con.execute("SELECT COUNT(*) FROM api_calls WHERE provider=? AND ts>=?",
                           (provider, now - seconds)).fetchone()[0])


def budget_status(con: sqlite3.Connection, provider: str, daily_limit: int,
                  now: Optional[float] = None) -> Dict[str, Any]:
    """used today, projected end-of-day use from the last hour's rate, and the cadence multiplier
    the recorder should apply (1 = normal, 5 = degraded 60s->5m, 0 = stop)."""
    now = float(now or time.time())
    used = calls_today(con, provider, now=now)
    last_h = calls_last(con, provider, 3600, now=now)
    remaining_s = 86400 - (int(now) % 86400)
    projected = used + last_h * remaining_s / 3600.0
    if used >= daily_limit:
        mult = 0
    elif projected > daily_limit * 0.9:
        mult = 5
    else:
        mult = 1
    return {"provider": provider, "used_today": used, "daily_limit": daily_limit, "last_hour": last_h,
            "projected": int(projected), "cadence_multiplier": mult,
            "remaining": max(0, daily_limit - used)}


# ---------------------------------------------------------------------------
# Reads
# ---------------------------------------------------------------------------

def latest_snapshot(con: sqlite3.Connection, asset: str) -> Optional[Dict[str, Any]]:
    r = con.execute("SELECT * FROM pool_snapshots WHERE asset=? ORDER BY ts DESC LIMIT 1", (asset.upper(),)).fetchone()
    return dict(r) if r else None


def spot_series(con: sqlite3.Connection, asset: str, since: int, until: Optional[int] = None,
                step_s: int = BAR_S) -> List[List[float]]:
    """[[ts, spot]] on a regular grid (forward-filled: exact for an AMM between trades).
    Merges 5-min bars (older history) with raw snapshots (recent)."""
    until = int(until or time.time())
    asset = asset.upper()
    pts: Dict[int, float] = {}
    for r in con.execute("SELECT bucket, c FROM pool_bars_5m WHERE asset=? AND bucket>=? AND bucket<=? ORDER BY bucket",
                         (asset, since - 86400, until)):
        pts[int(r[0]) + BAR_S - 1] = float(r[1])
    for r in con.execute("SELECT ts, spot FROM pool_snapshots WHERE asset=? AND ts>=? AND ts<=? ORDER BY ts",
                         (asset, since - 86400, until)):
        pts[int(r[0])] = float(r[1])
    if not pts:
        return []
    events = sorted(pts.items())
    out: List[List[float]] = []
    j, last = 0, None
    t = since - since % step_s
    while t <= until:
        while j < len(events) and events[j][0] <= t:
            last = events[j][1]
            j += 1
        if last is not None:
            out.append([t, last])
        t += step_s
    return out


def cex_series(con: sqlite3.Connection, symbol: str, since: int, until: Optional[int] = None,
               step_s: int = BAR_S) -> List[List[float]]:
    until = int(until or time.time())
    symbol = symbol.upper()
    pts: Dict[int, float] = {}
    for r in con.execute("SELECT bucket, c FROM cex_bars_5m WHERE symbol=? AND bucket>=? AND bucket<=?",
                         (symbol, since - 3600, until)):
        pts[int(r[0]) + BAR_S - 1] = float(r[1])
    for r in con.execute("SELECT ts, price FROM cex_ticks WHERE symbol=? AND ts>=? AND ts<=?",
                         (symbol, since - 3600, until)):
        pts[int(r[0])] = float(r[1])
    if not pts:
        return []
    events = sorted(pts.items())
    out, j, last = [], 0, None
    t = since - since % step_s
    while t <= until:
        while j < len(events) and events[j][0] <= t:
            last = events[j][1]
            j += 1
        # A CEX price older than 15 min is not a valid reference: leave a gap.
        if last is not None and t - events[j - 1][0] <= 900:
            out.append([t, last])
        t += step_s
    return out


def latest_cex(con: sqlite3.Connection, symbol: str = "ADA-USD") -> Optional[Dict[str, Any]]:
    r = con.execute("SELECT * FROM cex_ticks WHERE symbol=? ORDER BY ts DESC LIMIT 1", (symbol.upper(),)).fetchone()
    return dict(r) if r else None


def swaps_for(con: sqlite3.Connection, asset: str, since: int, kind: Optional[str] = None) -> List[Dict[str, Any]]:
    q = "SELECT * FROM swaps WHERE asset=? AND ts>=?"
    args: List[Any] = [asset.upper(), since]
    if kind:
        q += " AND kind=?"
        args.append(kind)
    return [dict(r) for r in con.execute(q + " ORDER BY ts, tx, idx", args)]


def spot_at(con: sqlite3.Connection, asset: str, ts: int) -> Optional[float]:
    """Last known pool spot at or before ts (raw first, then 5-min bars)."""
    r = con.execute("SELECT spot FROM pool_snapshots WHERE asset=? AND ts<=? ORDER BY ts DESC LIMIT 1",
                    (asset.upper(), int(ts))).fetchone()
    if r:
        return float(r[0])
    r = con.execute("SELECT c FROM pool_bars_5m WHERE asset=? AND bucket<=? ORDER BY bucket DESC LIMIT 1",
                    (asset.upper(), int(ts))).fetchone()
    return float(r[0]) if r else None


def fresh_pool_state(con: sqlite3.Connection, asset: str, max_age_s: int = 900) -> Optional[Dict[str, Any]]:
    """Latest exact pool state, only if the recorder checked this pool within max_age_s.
    (The snapshot timestamp is the last *trade*; an idle pool is still current if it was checked.)"""
    st = con.execute("SELECT last_checked FROM recorder_state WHERE asset=? ORDER BY last_checked DESC LIMIT 1",
                     (asset.upper(),)).fetchone()
    if not st or not st[0] or time.time() - int(st[0]) > max_age_s:
        return None
    snap = latest_snapshot(con, asset)
    if snap:
        snap["checked_age_s"] = int(time.time() - int(st[0]))
    return snap


def batch_activity(con: sqlite3.Connection, asset: str, window_s: int = 3600) -> Dict[str, Any]:
    now = int(time.time())
    rows = con.execute("SELECT ts, n_orders FROM swaps WHERE asset=? AND idx=0 AND kind IN ('batch','liquidity') "
                       "AND ts>=? ORDER BY ts", (asset.upper(), now - window_s)).fetchall()
    last = con.execute("SELECT MAX(ts) FROM swaps WHERE asset=? AND idx=0", (asset.upper(),)).fetchone()[0]
    fees = [float(r[0]) for r in con.execute(
        "SELECT batcher_fee_ada FROM swaps WHERE asset=? AND kind='order' AND batcher_fee_ada IS NOT NULL "
        "ORDER BY ts DESC LIMIT 200", (asset.upper(),))]
    return {"batches": len(rows), "orders": int(sum(int(r[1] or 0) for r in rows)), "window_s": window_s,
            "last_batch_age_s": (now - int(last)) if last else None,
            "measured_batcher_fee_ada": (sorted(fees)[len(fees) // 2] if fees else None),
            "batcher_fee_samples": len(fees)}


def recent_swaps(con: sqlite3.Connection, asset: str, limit: int = 80) -> List[Dict[str, Any]]:
    """Recent on-chain batch swaps for chart markers and order-flow display."""
    asset = asset.upper()
    rows = con.execute(
        "SELECT tx, ts, side, ada_amt, tok_amt, pre_spot, post_spot, eff_price, impact_pct, n_orders "
        "FROM swaps WHERE asset=? AND kind='batch' AND idx=0 AND side IN ('buy','sell') "
        "ORDER BY ts DESC LIMIT ?",
        (asset, int(limit)),
    ).fetchall()
    out: List[Dict[str, Any]] = []
    for r in reversed(rows):
        px = float(r["post_spot"] or r["eff_price"] or 0.0)
        if px <= 0:
            continue
        out.append({
            "time": int(r["ts"]),
            "tx_hash": r["tx"],
            "kind": r["side"],
            "price_ada": px,
            "ada_amt": float(r["ada_amt"] or 0.0),
            "tok_amt": float(r["tok_amt"] or 0.0),
            "impact_pct": float(r["impact_pct"] or 0.0),
            "n_orders": int(r["n_orders"] or 1),
        })
    return out


def ohlcv_series(con: sqlite3.Connection, asset: str, step_s: int = BAR_S,
                 since: Optional[int] = None, until: Optional[int] = None,
                 max_bars: int = 600) -> Dict[str, Any]:
    """Constructs exact on-chain OHLCV + signed order-flow bars at any step_s (300=5m, 900=15m, 3600=1h, 14400=4h, 86400=1D)
    from market.db (pool_bars_5m + pool_snapshots + swaps)."""
    asset = asset.upper()
    until = int(until or time.time())
    since = int(since if since is not None else (until - max_bars * step_s))

    snap_latest = latest_snapshot(con, asset)
    rec_state = con.execute("SELECT * FROM recorder_state WHERE asset=? ORDER BY last_checked DESC LIMIT 1", (asset,)).fetchone()
    if not snap_latest:
        bar_latest = con.execute("SELECT * FROM pool_bars_5m WHERE asset=? ORDER BY bucket DESC LIMIT 1", (asset,)).fetchone()
        if not bar_latest:
            return {"status": "unavailable", "reason": f"no on-chain snapshots in market.db for {asset}"}
        snap_latest = {
            "ts": int(bar_latest["bucket"]) + BAR_S - 1,
            "pool": bar_latest["pool"],
            "asset": asset,
            "dex": "MinswapV2",
            "reserve_ada": float(bar_latest["reserve_ada"] or 0.0),
            "reserve_tok": float(bar_latest["reserve_tok"] or 0.0),
            "spot": float(bar_latest["c"] or 0.0),
            "fee_bps": 30.0,
        }

    reserve_ada_now = float(snap_latest.get("reserve_ada") or 0.0)
    reserve_tok_now = float(snap_latest.get("reserve_tok") or 0.0)
    spot_now = float(snap_latest.get("spot") or 0.0)
    fee_bps_now = float(snap_latest.get("fee_bps") if snap_latest.get("fee_bps") is not None else 30.0)
    pool_id = str(snap_latest.get("pool") or (rec_state["pool"] if rec_state else ""))
    unit_id = str(rec_state["unit"]) if rec_state and rec_state["unit"] else ""

    # Collect price observations in [since - step_s, until]
    price_buckets: Dict[int, Dict[str, float]] = {}
    min_obs_ts: Optional[int] = None
    max_obs_ts: Optional[int] = None

    def _add_price(ts_val: int, hi_v: float, lo_v: float, cl_v: float) -> None:
        nonlocal min_obs_ts, max_obs_ts
        if cl_v <= 0 or hi_v <= 0 or lo_v <= 0:
            return
        if min_obs_ts is None or ts_val < min_obs_ts:
            min_obs_ts = ts_val
        if max_obs_ts is None or ts_val > max_obs_ts:
            max_obs_ts = ts_val
        b = (ts_val // step_s) * step_s
        cur = price_buckets.get(b)
        if cur is None:
            price_buckets[b] = {"h": hi_v, "l": lo_v, "c": cl_v, "last_ts": ts_val}
        else:
            cur["h"] = max(cur["h"], hi_v)
            cur["l"] = min(cur["l"], lo_v)
            if ts_val >= cur["last_ts"]:
                cur["c"] = cl_v
                cur["last_ts"] = ts_val

    for r in con.execute(
        "SELECT bucket, o, h, l, c FROM pool_bars_5m WHERE asset=? AND bucket>=? AND bucket<=? ORDER BY bucket",
        (asset, since - step_s, until),
    ):
        _add_price(int(r["bucket"]) + BAR_S - 1, float(r["h"]), float(r["l"]), float(r["c"]))

    for r in con.execute(
        "SELECT ts, pre_spot, post_spot FROM swaps WHERE asset=? AND kind='batch' AND idx=0 AND ts>=? AND ts<=? ORDER BY ts",
        (asset, since - step_s, until),
    ):
        pre_s = float(r["pre_spot"] or 0.0)
        post_s = float(r["post_spot"] or 0.0)
        if post_s > 0:
            hi_s = max(pre_s, post_s) if pre_s > 0 else post_s
            lo_s = min(pre_s, post_s) if pre_s > 0 else post_s
            _add_price(int(r["ts"]), hi_s, lo_s, post_s)

    for r in con.execute(
        "SELECT ts, spot FROM pool_snapshots WHERE asset=? AND ts>=? AND ts<=? ORDER BY ts",
        (asset, since - step_s, until),
    ):
        s_val = float(r["spot"] or 0.0)
        _add_price(int(r["ts"]), s_val, s_val, s_val)

    if not price_buckets or min_obs_ts is None:
        return {"status": "unavailable", "reason": f"no on-chain price observations in window for {asset}"}

    start_b = max((since // step_s) * step_s, (min_obs_ts // step_s) * step_s)
    end_b = (until // step_s) * step_s
    if end_b < start_b:
        end_b = start_b

    # Group swap flow per tx, then aggregate into step_s buckets
    tx_flow: Dict[str, Dict[str, Any]] = {}
    for r in con.execute(
        "SELECT tx, idx, ts, kind, side, ada_amt, impact_pct, n_orders FROM swaps "
        "WHERE asset=? AND ts>=? AND ts<=? ORDER BY ts, tx, idx",
        (asset, start_b, until),
    ):
        tx = r["tx"]
        tf = tx_flow.get(tx)
        if tf is None:
            tf = {
                "ts": int(r["ts"]),
                "batch_ada": 0.0,
                "batch_side": None,
                "order_buy_ada": 0.0,
                "order_sell_ada": 0.0,
                "impact_pct": 0.0,
                "n_orders": 0,
            }
            tx_flow[tx] = tf
        kind = r["kind"]
        side = r["side"]
        ada = float(r["ada_amt"] or 0.0)
        if kind == "batch" and int(r["idx"]) == 0:
            tf["batch_ada"] = ada
            tf["batch_side"] = side
            tf["impact_pct"] = abs(float(r["impact_pct"] or 0.0))
            tf["n_orders"] = int(r["n_orders"] or 0)
        elif kind in ("order", "order_other") and ada > 0:
            if side == "buy":
                tf["order_buy_ada"] += ada
            elif side == "sell":
                tf["order_sell_ada"] += ada

    vol_buckets: Dict[int, Dict[str, Any]] = {}
    for tf in tx_flow.values():
        b = (tf["ts"] // step_s) * step_s
        vb = vol_buckets.get(b)
        if vb is None:
            vb = {"buy_ada": 0.0, "sell_ada": 0.0, "trades": 0, "max_impact": 0.0, "max_batch_ada": 0.0}
            vol_buckets[b] = vb
        ob, os_ = tf["order_buy_ada"], tf["order_sell_ada"]
        if ob + os_ > 0:
            vb["buy_ada"] += ob
            vb["sell_ada"] += os_
        elif tf["batch_ada"] > 0:
            if tf["batch_side"] == "buy":
                vb["buy_ada"] += tf["batch_ada"]
            elif tf["batch_side"] == "sell":
                vb["sell_ada"] += tf["batch_ada"]
        vb["trades"] += max(1, tf["n_orders"]) if (ob + os_ + tf["batch_ada"]) > 0 else 0
        vb["max_impact"] = max(vb["max_impact"], tf["impact_pct"])
        vb["max_batch_ada"] = max(vb["max_batch_ada"], tf["batch_ada"])

    # Seed price before start_b
    prev_c = spot_at(con, asset, start_b)
    if prev_c is None:
        first_key = min(price_buckets.keys())
        prev_c = price_buckets[first_key]["c"]

    bars_out: List[Dict[str, Any]] = []
    b = start_b
    while b <= end_b:
        pb = price_buckets.get(b)
        vb = vol_buckets.get(b)
        buy_a = float(vb["buy_ada"]) if vb else 0.0
        sell_a = float(vb["sell_ada"]) if vb else 0.0
        tot_v = buy_a + sell_a
        trades_n = int(vb["trades"]) if vb else 0
        max_imp = float(vb["max_impact"]) if vb else 0.0
        max_b_ada = float(vb["max_batch_ada"]) if vb else 0.0
        shock = bool(
            (reserve_ada_now > 0 and max_b_ada >= 0.005 * reserve_ada_now)
            or max_imp >= 1.0
        )
        if pb is not None:
            o_px = float(prev_c)
            c_px = float(pb["c"])
            h_px = max(o_px, float(pb["h"]), c_px)
            l_px = min(o_px, float(pb["l"]), c_px)
            traded = True
            prev_c = c_px
        else:
            o_px = h_px = l_px = c_px = float(prev_c)
            traded = tot_v > 0
        bars_out.append({
            "time": int(b),
            "open": o_px,
            "high": h_px,
            "low": l_px,
            "close": c_px,
            "volume": tot_v,
            "buy_volume": buy_a,
            "sell_volume": sell_a,
            "delta_volume": buy_a - sell_a,
            "trades": trades_n,
            "traded": traded,
            "shock": shock,
            "max_impact_pct": round(max_imp, 4),
        })
        b += step_s

    if len(bars_out) > max_bars:
        bars_out = bars_out[-max_bars:]

    checked_ts = int(rec_state["last_checked"] or snap_latest["ts"]) if rec_state else int(snap_latest["ts"])
    return {
        "status": "ok",
        "asset": asset,
        "unit": unit_id,
        "step_s": step_s,
        "min_ts": min_obs_ts,
        "max_ts": max_obs_ts,
        "checked_at": checked_ts,
        "age_s": max(0, int(time.time()) - checked_ts),
        "pool": {
            "pool_address": pool_id,
            "dex": "minswap-v2",
            "name": f"{asset} / ADA",
            "asset_is_base": True,
            "price_ada": spot_now,
            "reserve_ada_est": reserve_ada_now,
            "reserve_token_est": reserve_tok_now,
            "fee_bps": fee_bps_now,
        },
        "bars": bars_out,
    }


# ---------------------------------------------------------------------------
# Janitor: downsample, retention, size cap
# ---------------------------------------------------------------------------

def downsample(con: sqlite3.Connection, now: Optional[float] = None) -> Dict[str, int]:
    """Roll raw rows older than 1 day into 5-min bars (idempotent), then drop raw rows past retention."""
    now = int(now or time.time())
    horizon = now - 86400
    n_bars = 0
    rows = con.execute("SELECT pool, asset, ts, spot, reserve_ada, reserve_tok FROM pool_snapshots "
                       "WHERE ts < ? ORDER BY pool, ts", (horizon,)).fetchall()
    bars: Dict[tuple, Dict[str, Any]] = {}
    for r in rows:
        k = (r["pool"], int(r["ts"]) - int(r["ts"]) % BAR_S)
        b = bars.get(k)
        if b is None:
            bars[k] = {"asset": r["asset"], "o": r["spot"], "h": r["spot"], "l": r["spot"], "c": r["spot"],
                       "ra": r["reserve_ada"], "rt": r["reserve_tok"], "n": 1}
        else:
            b["h"], b["l"], b["c"] = max(b["h"], r["spot"]), min(b["l"], r["spot"]), r["spot"]
            b["ra"], b["rt"], b["n"] = r["reserve_ada"], r["reserve_tok"], b["n"] + 1
    for (pool, bucket), b in bars.items():
        con.execute("INSERT OR REPLACE INTO pool_bars_5m VALUES (?,?,?,?,?,?,?,?,?,?)",
                    (bucket, pool, b["asset"], b["o"], b["h"], b["l"], b["c"], b["ra"], b["rt"], b["n"]))
        n_bars += 1
    crow = con.execute("SELECT symbol, ts, price FROM cex_ticks WHERE ts < ? ORDER BY symbol, ts", (horizon,)).fetchall()
    cb: Dict[tuple, Dict[str, Any]] = {}
    for r in crow:
        k = (r["symbol"], int(r["ts"]) - int(r["ts"]) % BAR_S)
        b = cb.get(k)
        p = r["price"]
        if b is None:
            cb[k] = {"o": p, "h": p, "l": p, "c": p, "n": 1}
        else:
            b["h"], b["l"], b["c"], b["n"] = max(b["h"], p), min(b["l"], p), p, b["n"] + 1
    for (sym, bucket), b in cb.items():
        con.execute("INSERT OR REPLACE INTO cex_bars_5m VALUES (?,?,?,?,?,?,?)",
                    (bucket, sym, b["o"], b["h"], b["l"], b["c"], b["n"]))
        n_bars += 1
    cut = now - RAW_RETENTION_S
    d_snap = con.execute("DELETE FROM pool_snapshots WHERE ts < ?", (cut,)).rowcount
    d_cex = con.execute("DELETE FROM cex_ticks WHERE ts < ?", (cut,)).rowcount
    d_bar = con.execute("DELETE FROM pool_bars_5m WHERE bucket < ?", (now - BAR_RETENTION_S,)).rowcount
    d_bar += con.execute("DELETE FROM cex_bars_5m WHERE bucket < ?", (now - BAR_RETENTION_S,)).rowcount
    d_api = con.execute("DELETE FROM api_calls WHERE ts < ?", (now - API_RETENTION_S,)).rowcount
    con.commit()
    return {"bars_written": n_bars, "raw_snapshots_deleted": d_snap, "raw_cex_deleted": d_cex,
            "bars_deleted": d_bar, "api_rows_deleted": d_api}


def size_bytes(path: Optional[Path] = None) -> int:
    path = Path(path) if path else db_path()
    total = 0
    for suffix in ("", "-wal", "-shm"):
        p = Path(str(path) + suffix)
        if p.exists():
            total += p.stat().st_size
    return total


def enforce_cap(con: sqlite3.Connection, max_bytes: Optional[int] = None, path: Optional[Path] = None) -> Dict[str, Any]:
    """Prune oldest downsampled data first, then oldest raw data, in 10% steps, until under the cap."""
    max_bytes = int(max_bytes or os.environ.get("MARKET_DB_MAX_BYTES", DEFAULT_MAX_BYTES))
    path = Path(path) if path else db_path()
    pruned: List[str] = []
    for _ in range(40):
        con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        if size_bytes(path) <= max_bytes:
            break
        did = False
        for table, col in (("pool_bars_5m", "bucket"), ("cex_bars_5m", "bucket"),
                           ("pool_snapshots", "ts"), ("cex_ticks", "ts"), ("api_calls", "ts")):
            lo, hi = con.execute(f"SELECT MIN({col}), MAX({col}) FROM {table}").fetchone()
            if lo is None or hi is None or hi <= lo:
                continue
            cut = lo + max(1, (hi - lo) // 10)
            n = con.execute(f"DELETE FROM {table} WHERE {col} < ?", (cut,)).rowcount
            if n:
                pruned.append(f"{table}<{cut}:{n}")
                did = True
                break
        con.commit()
        con.execute("VACUUM")
        if not did:
            break
    return {"size_bytes": size_bytes(path), "max_bytes": max_bytes, "pruned": pruned}


def janitor(con: Optional[sqlite3.Connection] = None, now: Optional[float] = None,
            max_bytes: Optional[int] = None) -> Dict[str, Any]:
    own = con is None
    con = con or connect()
    try:
        ds = downsample(con, now)
        cap = enforce_cap(con, max_bytes)
        con.execute("VACUUM")
        con.execute("INSERT OR REPLACE INTO meta(k, v) VALUES ('last_janitor', ?)", (str(int(time.time())),))
        con.commit()
        return {"status": "ok", **ds, **cap}
    finally:
        if own:
            con.close()


def health(con: Optional[sqlite3.Connection] = None) -> Dict[str, Any]:
    own = con is None
    con = con or connect()
    try:
        out: Dict[str, Any] = {"path": str(db_path()), "size_bytes": size_bytes(),
                               "max_bytes": int(os.environ.get("MARKET_DB_MAX_BYTES", DEFAULT_MAX_BYTES))}
        for t in ("pool_snapshots", "pool_bars_5m", "swaps", "cex_ticks", "cex_bars_5m", "api_calls"):
            out[f"rows_{t}"] = int(con.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0])
        out["pools"] = [dict(r) for r in con.execute(
            "SELECT pool, asset, dex, last_ts, last_checked, backfill_done, backfill_oldest_ts FROM recorder_state ORDER BY asset")]
        cex = latest_cex(con)
        out["cex_latest"] = cex
        m = con.execute("SELECT v FROM meta WHERE k='last_janitor'").fetchone()
        out["last_janitor"] = int(m[0]) if m else None
        return out
    finally:
        if own:
            con.close()


def main() -> None:
    import argparse
    ap = argparse.ArgumentParser(description="market.db maintenance")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("health")
    sub.add_parser("janitor")
    t = sub.add_parser("cex-tick", help="record a CEX price tick")
    t.add_argument("--symbol", default="ADA-USD")
    t.add_argument("--price", type=float, required=True)
    t.add_argument("--ts", type=int, default=None)
    t.add_argument("--src", default="coinbase")
    a = ap.parse_args()
    try:
        if a.cmd == "health":
            res = health()
        elif a.cmd == "janitor":
            res = janitor()
        else:
            con = connect()
            record_cex_tick(con, a.ts or int(time.time()), a.symbol, a.price, a.src)
            con.commit()
            con.close()
            res = {"status": "ok", "symbol": a.symbol.upper(), "price": a.price}
    except Exception as e:
        res = {"status": "error", "message": f"{type(e).__name__}: {e}"}
    print(json.dumps(res, indent=2, default=str))


if __name__ == "__main__":
    main()
