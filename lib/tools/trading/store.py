#!/usr/bin/env python3
"""
trading.db: plans, confirm tokens, standing orders, journal (trips + markouts), shadow
simulation trades, equity history and policy overrides (gate unlocks / freeze).

Path: $TRADING_DB_PATH or $GEORGE_DIR/finance/trading.db. Pure stdlib.
"""
from __future__ import annotations

import json
import os
import sqlite3
import time
from pathlib import Path
from typing import Any, Dict, Optional

_REPO_ROOT = Path(__file__).resolve().parents[3]
LODGE_DIR = Path(os.environ.get("LODGE_DIR", _REPO_ROOT))

_SCHEMA = """
CREATE TABLE IF NOT EXISTS plans (
    plan_id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
    origin TEXT NOT NULL, intent_json TEXT NOT NULL, actions_json TEXT NOT NULL,
    refs_json TEXT NOT NULL, plan_hash TEXT NOT NULL, tier TEXT NOT NULL,
    status TEXT NOT NULL, result_json TEXT, executed_at INTEGER, summary TEXT);
CREATE INDEX IF NOT EXISTS ix_plans_status ON plans(status, created_at);
CREATE TABLE IF NOT EXISTS confirm_tokens (
    token_hash TEXT PRIMARY KEY, plan_id TEXT NOT NULL, plan_hash TEXT NOT NULL,
    minted_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, used_at INTEGER,
    via TEXT NOT NULL, evidence TEXT);
CREATE TABLE IF NOT EXISTS standing_orders (
    so_id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
    strategy TEXT NOT NULL, asset TEXT NOT NULL, side TEXT NOT NULL DEFAULT 'buy',
    max_ada REAL NOT NULL, used_ada REAL NOT NULL DEFAULT 0,
    price_min REAL, price_max REAL, status TEXT NOT NULL, approved_plan TEXT, note TEXT);
CREATE TABLE IF NOT EXISTS trips (
    trip_id TEXT PRIMARY KEY, mode TEXT NOT NULL, strategy TEXT NOT NULL, asset TEXT NOT NULL,
    opened_at INTEGER NOT NULL, closed_at INTEGER, entry_price REAL, exit_price REAL,
    tokens REAL, entry_ada REAL, exit_ada REAL, fees_ada REAL, net_pnl_ada REAL,
    new_rules INTEGER NOT NULL DEFAULT 1, buy_order_id TEXT, sell_order_id TEXT, meta TEXT);
CREATE TABLE IF NOT EXISTS markouts (
    fill_id TEXT NOT NULL, horizon_s INTEGER NOT NULL, mode TEXT NOT NULL, strategy TEXT,
    asset TEXT NOT NULL, side TEXT NOT NULL, fill_ts INTEGER NOT NULL, fill_price REAL NOT NULL,
    tokens REAL, due_ts INTEGER NOT NULL, mark_price REAL, markout_ada REAL, markout_bps REAL,
    status TEXT NOT NULL DEFAULT 'pending', new_rules INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (fill_id, horizon_s));
CREATE INDEX IF NOT EXISTS ix_markouts_due ON markouts(status, due_ts);
CREATE TABLE IF NOT EXISTS sim_trades (
    sim_id TEXT PRIMARY KEY, strategy TEXT NOT NULL, asset TEXT NOT NULL, created_at INTEGER NOT NULL,
    signal_json TEXT, side TEXT NOT NULL, entry_price REAL NOT NULL, size_ada REAL NOT NULL,
    exit_target REAL, timeout_at INTEGER NOT NULL, status TEXT NOT NULL,
    filled_at INTEGER, exit_at INTEGER, exit_price REAL, net_pnl_ada REAL, fees_ada REAL, note TEXT);
CREATE INDEX IF NOT EXISTS ix_sim_status ON sim_trades(strategy, status);
CREATE TABLE IF NOT EXISTS equity (
    ts INTEGER PRIMARY KEY, equity_ada REAL NOT NULL, peak_ada REAL NOT NULL, drawdown_pct REAL NOT NULL,
    detail TEXT);
CREATE TABLE IF NOT EXISTS overrides (
    k TEXT PRIMARY KEY, v TEXT NOT NULL, set_at INTEGER NOT NULL, set_by TEXT NOT NULL, reason TEXT);
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, kind TEXT NOT NULL, detail TEXT);
CREATE TABLE IF NOT EXISTS backtests (
    run_id TEXT PRIMARY KEY, ts INTEGER NOT NULL, strategy TEXT NOT NULL, params_json TEXT,
    n_trips INTEGER NOT NULL, mean_ada REAL, sd_ada REAL, se_ada REAL, lower80_ada REAL,
    win_rate REAL, data_from INTEGER, data_to INTEGER, detail TEXT);
CREATE INDEX IF NOT EXISTS ix_bt_strategy ON backtests(strategy, ts);
CREATE TABLE IF NOT EXISTS cross_dex_spreads (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,
    asset TEXT NOT NULL,
    buy_dex TEXT NOT NULL,
    sell_dex TEXT NOT NULL,
    venues_count INTEGER NOT NULL DEFAULT 0,
    spot_buy_ada REAL NOT NULL,
    spot_sell_ada REAL NOT NULL,
    spot_spread_pct REAL NOT NULL,
    net_lp_spread_pct REAL NOT NULL,
    exec_spread_pct REAL NOT NULL,
    fixed_fee_ada REAL NOT NULL,
    eff_reserve_ada REAL NOT NULL,
    capital_ada REAL NOT NULL,
    net_profit_at_cap_ada REAL NOT NULL,
    min_viable_ada REAL,
    target_viable_ada REAL NOT NULL,
    optimal_ada REAL NOT NULL,
    max_net_profit_ada REAL NOT NULL,
    req_spread_pct REAL NOT NULL,
    viable INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS ix_cds_asset_ts ON cross_dex_spreads(asset, ts);
"""


def db_path() -> Path:
    p = os.environ.get("TRADING_DB_PATH")
    if p:
        return Path(p)
    george = Path(os.environ.get("GEORGE_DIR", LODGE_DIR / ".george"))
    return Path(os.environ.get("FINANCE_DIR", george / "finance")) / "trading.db"


def connect(path: Optional[Path] = None) -> sqlite3.Connection:
    path = Path(path) if path else db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(path), timeout=30)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    con.executescript(_SCHEMA)
    return con


def get_override(con: sqlite3.Connection, k: str) -> Optional[Any]:
    r = con.execute("SELECT v FROM overrides WHERE k=?", (k,)).fetchone()
    return json.loads(r[0]) if r else None


def set_override(con: sqlite3.Connection, k: str, v: Any, by: str, reason: str = "") -> None:
    con.execute("INSERT OR REPLACE INTO overrides VALUES (?,?,?,?,?)", (k, json.dumps(v), int(time.time()), by, reason))
    log_event(con, "override", {"k": k, "v": v, "by": by, "reason": reason})
    con.commit()


def clear_override(con: sqlite3.Connection, k: str, by: str, reason: str = "") -> None:
    con.execute("DELETE FROM overrides WHERE k=?", (k,))
    log_event(con, "override_cleared", {"k": k, "by": by, "reason": reason})
    con.commit()


def log_event(con: sqlite3.Connection, kind: str, detail: Dict[str, Any]) -> None:
    con.execute("INSERT INTO events(ts, kind, detail) VALUES (?,?,?)", (int(time.time()), kind, json.dumps(detail, default=str)))
