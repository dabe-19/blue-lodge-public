#!/usr/bin/env python3
"""Local SQLite CLI backing __MOD_NAME__ tools and Web UI actions.

Uses Python standard library only (zero external dependencies) and strictly
parameterized SQL queries. Persistent state is stored under MODULE_DATA_DIR
so module upgrades never touch user data.
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys
import time
from pathlib import Path


def get_db_path() -> Path:
    data_dir = Path(
        os.environ.get("MODULE_DATA_DIR")
        or os.path.join(os.environ.get("GEORGE_DIR", ".george"), "module_data", "__MOD_ID__")
    )
    data_dir.mkdir(parents=True, exist_ok=True)
    return data_dir / "app.db"


def connect() -> sqlite3.Connection:
    conn = sqlite3.connect(str(get_db_path()))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            category TEXT NOT NULL DEFAULT 'note',
            body TEXT NOT NULL,
            created_at INTEGER NOT NULL
        )
        """
    )
    conn.commit()
    return conn


def read_payload() -> dict:
    raw = sys.stdin.read().strip()
    if not raw:
        return {}
    try:
        val = json.loads(raw)
        return val if isinstance(val, dict) else {"value": val}
    except Exception:
        return {}


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else "list"
    payload = read_payload()
    conn = connect()

    if action in ("list", "__MOD_PREFIX___list_entries"):
        try:
            limit = max(1, min(100, int(payload.get("limit", 20))))
        except Exception:
            limit = 20
        rows = conn.execute(
            "SELECT id, title, category, body, created_at FROM entries ORDER BY id DESC LIMIT ?",
            (limit,),
        ).fetchall()
        print(json.dumps({"status": "ok", "entries": [dict(r) for r in rows]}))
        return 0

    if action in ("save", "__MOD_PREFIX___save_entry"):
        title = str(payload.get("title") or "").strip()[:160]
        category = str(payload.get("category") or "note").strip()[:48] or "note"
        body = str(payload.get("body") or "").strip()[:32000]
        if not title or not body:
            print(json.dumps({"status": "error", "message": "title and body are required"}))
            return 1
        ts = int(time.time())
        cur = conn.execute(
            "INSERT INTO entries (title, category, body, created_at) VALUES (?, ?, ?, ?)",
            (title, category, body, ts),
        )
        conn.commit()
        print(json.dumps({"status": "ok", "id": cur.lastrowid, "title": title, "created_at": ts}))
        return 0

    if action == "delete":
        try:
            eid = int(payload.get("id", 0))
        except Exception:
            eid = 0
        if eid <= 0:
            print(json.dumps({"status": "error", "message": "valid entry id required"}))
            return 1
        conn.execute("DELETE FROM entries WHERE id = ?", (eid,))
        conn.commit()
        print(json.dumps({"status": "ok", "deleted_id": eid}))
        return 0

    print(json.dumps({"status": "error", "message": f"unknown action: {action}"}))
    return 1


if __name__ == "__main__":
    sys.exit(main())
