#!/usr/bin/env python3
"""Sovereign API Trigger & Reactor Building Engine for Blue Lodge.

Connects the curated SQLite public-apis catalog (930+ keyless endpoints)
into the Sovereign Reactive Event Bus. Allows operators to discover endpoints,
generate autonomic polling triggers, and wire reactive chains.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sqlite3
import sys
import time
from pathlib import Path
from typing import Any

logger = logging.getLogger("api_trigger_builder")
logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")

_REPO_ROOT = Path(__file__).resolve().parents[2]
_DEFAULT_DB = _REPO_ROOT / "data" / "catalog" / "public_apis.sqlite"
_GEORGE_DIR = Path(os.environ.get("GEORGE_DIR") or _REPO_ROOT / ".george")
_TRIGGERS_DIR = _GEORGE_DIR / "triggers"
_CRON_JOBS_DIR = _GEORGE_DIR / "cron_jobs"
_REACTORS_FILE = _GEORGE_DIR / "reactors.json"

# Curated high-utility recipes connecting keyless endpoints to Event Bus
PRESET_RECIPES = {
    "coinbase_btc": {
        "name": "Coinbase BTC Spot Price Streamer",
        "category": "Cryptocurrency",
        "url": "https://api.coinbase.com/v2/prices/BTC-USD/spot",
        "event_type": "crypto_price_tick",
        "interval_seconds": 60,
        "json_filter": ".data | {symbol: .base, price: (.amount | tonumber), currency: .currency}",
        "description": "Polls real-time Bitcoin spot USD price and emits crypto_price_tick into event bus.",
    },
    "coinbase_ada": {
        "name": "Coinbase Cardano Spot Price Streamer",
        "category": "Cryptocurrency",
        "url": "https://api.coinbase.com/v2/prices/ADA-USD/spot",
        "event_type": "crypto_price_tick",
        "interval_seconds": 60,
        "json_filter": ".data | {symbol: .base, price: (.amount | tonumber), currency: .currency}",
        "description": "Polls real-time Cardano spot USD price and emits crypto_price_tick into event bus.",
    },
    "polymarket_active": {
        "name": "Polymarket Top Prediction Markets Watcher",
        "category": "Finance",
        "url": "https://gamma-api.polymarket.com/markets?limit=10&active=true&closed=false&order=volume24hr&ascending=false",
        "event_type": "polymarket_market_shift",
        "interval_seconds": 180,
        "json_filter": ".[0:5] | map({id: .id, question: .question, volume: (.volume | tonumber), outcomePrices: .outcomePrices})",
        "description": "Tracks high-volume active prediction markets and odds movements on Polymarket.",
    },
    "mempool_fee_rate": {
        "name": "Bitcoin Mempool Recommended Fees",
        "category": "Cryptocurrency",
        "url": "https://mempool.space/api/v1/fees/recommended",
        "event_type": "btc_mempool_fees",
        "interval_seconds": 120,
        "json_filter": "{fastestFee: .fastestFee, halfHourFee: .halfHourFee, hourFee: .hourFee, minimumFee: .minimumFee}",
        "description": "Monitors Bitcoin on-chain fee pressure and emits btc_mempool_fees.",
    },
    "hackernews_top": {
        "name": "HackerNews Top Story Intelligence",
        "category": "News",
        "url": "https://hacker-news.firebaseio.com/v0/topstories.json?limitToFirst=5&orderBy=\"$key\"",
        "event_type": "osint_tech_story",
        "interval_seconds": 300,
        "json_filter": "{top_ids: .}",
        "description": "Monitors top emerging developer news items from HackerNews without API keys.",
    },
}


def get_db_conn(db_path: Path | None = None) -> sqlite3.Connection:
    target = db_path or _DEFAULT_DB
    if not target.exists():
        raise FileNotFoundError(f"Database not found: {target}")
    conn = sqlite3.connect(str(target))
    conn.row_factory = sqlite3.Row
    return conn


def search_keyless_apis(
    query: str = "",
    category: str | None = None,
    limit: int = 15,
    db_path: Path | None = None,
) -> list[dict[str, Any]]:
    """Search the catalog for keyless (zero-auth) REST endpoints."""
    conn = get_db_conn(db_path)
    cursor = conn.cursor()

    sql_parts = ["SELECT id, name, url, description, category, cors, https FROM apis WHERE is_keyless = 1"]
    params: list[Any] = []

    if category:
        sql_parts.append("AND LOWER(category) = LOWER(?)")
        params.append(category)

    if query.strip():
        sql_parts.append("AND (name LIKE ? OR description LIKE ? OR category LIKE ?)")
        wild = f"%{query.strip()}%"
        params.extend([wild, wild, wild])

    sql_parts.append("ORDER BY name ASC LIMIT ?")
    params.append(limit)

    cursor.execute(" ".join(sql_parts), params)
    rows = cursor.fetchall()
    conn.close()

    return [dict(r) for r in rows]


def list_categories(db_path: Path | None = None) -> list[dict[str, Any]]:
    """List all categories with keyless API counts."""
    conn = get_db_conn(db_path)
    cursor = conn.cursor()
    cursor.execute("""
        SELECT category, COUNT(*) as count, SUM(is_keyless) as keyless_count
        FROM apis
        GROUP BY category
        ORDER BY keyless_count DESC
    """)
    rows = cursor.fetchall()
    conn.close()
    return [dict(r) for r in rows]


def create_trigger_script(
    trigger_id: str,
    name: str,
    endpoint_url: str,
    event_type: str,
    interval_seconds: int = 120,
    jq_filter: str = ".",
    headers: dict[str, str] | None = None,
) -> Path:
    """Generate an autonomic executable cron job script that polls the API and emits to Event Bus."""
    _CRON_JOBS_DIR.mkdir(parents=True, exist_ok=True)
    _TRIGGERS_DIR.mkdir(parents=True, exist_ok=True)

    clean_id = re.sub(r"[^a-zA-Z0-9_-]", "_", trigger_id.lower())
    script_path = _CRON_JOBS_DIR / f"api_{clean_id}.sh"
    meta_path = _TRIGGERS_DIR / f"{clean_id}.json"

    # Save metadata JSON
    meta = {
        "id": clean_id,
        "name": name,
        "url": endpoint_url,
        "event_type": event_type,
        "interval_seconds": interval_seconds,
        "jq_filter": jq_filter,
        "created_at": int(time.time()),
    }
    meta_path.write_text(json.dumps(meta, indent=2), encoding="utf-8")

    # Header args for curl
    hdr_args = ""
    if headers:
        for k, v in headers.items():
            hdr_args += f' -H "{k}: {v}"'

    # Build the cron script
    script_content = f"""#!/bin/bash
# ── Autonomic API Trigger: {name} ──
# INTERVAL: {interval_seconds}
# ENABLED: 1

LODGE_DIR="${{LODGE_DIR:-$HOME/blue-lodge}}"
source "$LODGE_DIR/lib/ipc/event_bus.sh" 2>/dev/null || true

_API_URL="{endpoint_url}"
_EVENT_TYPE="{event_type}"
_TRIGGER_ID="{clean_id}"

# Fetch endpoint data with 6-second timeout
_RESP=$(curl -s --connect-timeout 4 -m 6{hdr_args} "$_API_URL" 2>/dev/null)
[ -z "$_RESP" ] && exit 0

# Apply jq transformation filter
_FILTERED=$(printf '%s' "$_RESP" | jq -c '{jq_filter}' 2>/dev/null)
[ -z "$_FILTERED" ] || [ "$_FILTERED" = "null" ] && exit 0

# Check cache state for deduplication
_CACHE_FILE="$LODGE_DIR/.george/ipc/cache_api_${clean_id}.hash"
_NEW_HASH=$(printf '%s' "$_FILTERED" | md5sum | cut -d' ' -f1)
_OLD_HASH=""
[ -f "$_CACHE_FILE" ] && _OLD_HASH=$(cat "$_CACHE_FILE" 2>/dev/null)

if [ "$_NEW_HASH" != "$_OLD_HASH" ]; then
    printf '%s' "$_NEW_HASH" > "$_CACHE_FILE" 2>/dev/null || true
    
    # Emit into Sovereign Event Bus
    event_bus_emit "$_EVENT_TYPE" "$_FILTERED" "api_trigger_${clean_id}"
fi
"""

    script_path.write_text(script_content, encoding="utf-8")
    script_path.chmod(0o755)
    return script_path


def register_reactor_for_trigger(
    reactor_id: str,
    event_type: str,
    action: str,
    pattern: str = ".*",
    debounce: int = 10,
) -> bool:
    """Register a matching reactor in .george/reactors.json."""
    if not _REACTORS_FILE.exists():
        _REACTORS_FILE.parent.mkdir(parents=True, exist_ok=True)
        init_data = {"reactors": [], "stats": {"events_total": 0, "reactions_fired": 0}}
        _REACTORS_FILE.write_text(json.dumps(init_data, indent=2), encoding="utf-8")

    try:
        data = json.loads(_REACTORS_FILE.read_text(encoding="utf-8"))
        reactors = [r for r in data.get("reactors", []) if r.get("id") != reactor_id]
        reactors.append({
            "id": reactor_id,
            "event_type": event_type,
            "pattern": pattern,
            "action": action,
            "debounce_secs": debounce,
            "enabled": True,
            "created_at": int(time.time()),
        })
        data["reactors"] = reactors
        _REACTORS_FILE.write_text(json.dumps(data, indent=2), encoding="utf-8")
        return True
    except Exception as e:
        logger.error(f"Failed to register reactor: {e}")
        return False


def main() -> None:
    parser = argparse.ArgumentParser(description="Sovereign API Trigger & Reactor Building Engine")
    parser.add_argument("--search", type=str, help="Search keyless APIs in the catalog")
    parser.add_argument("--category", type=str, help="Filter search by category")
    parser.add_argument("--categories", action="store_true", help="List all categories with keyless API counts")
    parser.add_argument("--presets", action="store_true", help="List pre-configured trigger recipes")
    parser.add_argument("--build-preset", type=str, help="Deploy a preset trigger recipe by key")
    parser.add_argument("--build-custom", action="store_true", help="Build a custom trigger from parameters")
    parser.add_argument("--id", type=str, help="Trigger ID")
    parser.add_argument("--name", type=str, help="Trigger Name")
    parser.add_argument("--url", type=str, help="API URL")
    parser.add_argument("--event-type", type=str, help="Event Bus event type to emit")
    parser.add_argument("--interval", type=int, default=120, help="Poll interval in seconds")
    parser.add_argument("--filter", type=str, default=".", help="jq filter expression")
    parser.add_argument("--action", type=str, help="Optional reactor shell action to bind")
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")

    args = parser.parse_args()

    if args.categories:
        cats = list_categories()
        if args.json:
            print(json.dumps(cats, indent=2))
            sys.exit(0)
        print("=" * 60)
        print("  KEYLESS API CATALOG CATEGORIES")
        print("=" * 60)
        for c in cats:
            print(f"  {c['category']:<25} | {c['keyless_count']:>3} keyless (of {c['count']:>3} total)")
        sys.exit(0)

    if args.presets:
        if args.json:
            print(json.dumps(PRESET_RECIPES, indent=2))
            sys.exit(0)
        print("=" * 72)
        print("  PRE-CONFIGURED SOVEREIGN API TRIGGER RECIPES")
        print("=" * 72)
        for key, p in PRESET_RECIPES.items():
            print(f"  [{key}] {p['name']}")
            print(f"    Category: {p['category']} | Interval: {p['interval_seconds']}s")
            print(f"    Event:    {p['event_type']}")
            print(f"    URL:      {p['url']}")
            print(f"    Desc:     {p['description']}")
            print()
        sys.exit(0)

    if args.build_preset:
        preset_key = args.build_preset.strip()
        if preset_key not in PRESET_RECIPES:
            print(f"[ERROR] Unknown preset: {preset_key}. Run with --presets to see options.", file=sys.stderr)
            sys.exit(1)

        p = PRESET_RECIPES[preset_key]
        script_path = create_trigger_script(
            trigger_id=preset_key,
            name=p["name"],
            endpoint_url=p["url"],
            event_type=p["event_type"],
            interval_seconds=p["interval_seconds"],
            jq_filter=p["json_filter"],
        )
        # If action provided or default reaction, register reactor
        action = args.action or f"printf '[EVENT_LOG] %s: %s\\n' \"$EVENT_TYPE\" \"$EVENT_PAYLOAD\" >> $LODGE_DIR/.george/ipc/api_triggers.log"
        rx_id = f"rx_{preset_key}"
        register_reactor_for_trigger(rx_id, p["event_type"], action)

        if args.json:
            print(json.dumps({"status": "ok", "preset": preset_key, "script_path": str(script_path), "reactor_id": rx_id}, indent=2))
        else:
            print(f"[OK] Deployed autonomic trigger script: {script_path}")
            print(f"[OK] Registered Event Bus reactor: '{rx_id}' on '{p['event_type']}'")
        sys.exit(0)

    if args.build_custom:
        if not args.id or not args.url or not args.event_type:
            print("[ERROR] --id, --url, and --event-type are required for --build-custom", file=sys.stderr)
            sys.exit(1)

        name = args.name or args.id
        script_path = create_trigger_script(
            trigger_id=args.id,
            name=name,
            endpoint_url=args.url,
            event_type=args.event_type,
            interval_seconds=args.interval,
            jq_filter=args.filter,
        )

        rx_id = None
        if args.action:
            rx_id = f"rx_{args.id}"
            register_reactor_for_trigger(rx_id, args.event_type, args.action)

        if args.json:
            print(json.dumps({"status": "ok", "id": args.id, "script_path": str(script_path), "reactor_id": rx_id}, indent=2))
        else:
            print(f"[OK] Deployed custom trigger script: {script_path}")
            if rx_id:
                print(f"[OK] Registered Event Bus reactor: '{rx_id}' on '{args.event_type}'")
        sys.exit(0)

    if args.search or args.category:
        results = search_keyless_apis(args.search or "", category=args.category)
        if args.json:
            print(json.dumps(results, indent=2))
            sys.exit(0)
        print("=" * 72)
        print(f"  KEYLESS APIS MATCHING (Query: '{args.search or ''}', Category: '{args.category or 'ALL'}')")
        print("=" * 72)
        if not results:
            print("  No keyless APIs matched criteria.")
        for r in results:
            print(f"  [{r['id']}] {r['name']} ({r['category']})")
            print(f"      URL:  {r['url']}")
            print(f"      Desc: {r['description'][:90]}...")
            print()
        sys.exit(0)

    parser.print_help()


if __name__ == "__main__":
    main()
