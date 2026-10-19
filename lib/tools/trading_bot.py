#!/usr/bin/env python3
"""Sovereign Mock Trading Bot & Polymarket Simulator for Blue Lodge.

Simulates event-driven cryptocurrency trades (BTC, ADA) and Polymarket prediction bets
based on Financial OSINT signals and Reactive Event Bus triggers. Tracks real-time
mark-to-market P&L (+/-), position trajectories, and streams automated reports
every 10 minutes to the configured operator via Discord DM.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import re
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

logger = logging.getLogger("trading_bot")
logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")

_REPO_ROOT = Path(__file__).resolve().parents[2]
_GEORGE_DIR = Path(os.environ.get("GEORGE_DIR", str(_REPO_ROOT / ".george")))
_TRADING_DIR = _GEORGE_DIR / "trading"
_DB_PATH = _TRADING_DIR / "portfolio.db"
_REPORTS_DIR = _GEORGE_DIR / "reports"
_LATEST_REPORT = _TRADING_DIR / "latest_report.md"
_OSINT_FINANCE_REPORT = _REPORTS_DIR / "osint_financial_report.md"
_REPORT_LOG = _REPORTS_DIR / "trading_stream.log"

def _load_secrets_env() -> None:
    for env_path in [_GEORGE_DIR / "secrets.env", _REPO_ROOT / ".env"]:
        if env_path.exists():
            for line in env_path.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))

_load_secrets_env()


# ── Database Initialization ──────────────────────────────────────────

def init_db(db_path: Path = _DB_PATH) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode = WAL;")

    with conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS portfolio (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                cash_usd REAL NOT NULL DEFAULT 10000.0,
                btc_balance REAL NOT NULL DEFAULT 0.0,
                ada_balance REAL NOT NULL DEFAULT 0.0,
                realized_pnl REAL NOT NULL DEFAULT 0.0,
                updated_at INTEGER NOT NULL
            );
        """)

        conn.execute("""
            CREATE TABLE IF NOT EXISTS trades (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                trade_id TEXT UNIQUE NOT NULL,
                asset TEXT NOT NULL,
                symbol TEXT NOT NULL,
                action TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'OPEN',
                entry_price REAL NOT NULL,
                current_price REAL NOT NULL,
                amount REAL NOT NULL,
                cost_usd REAL NOT NULL,
                exit_price REAL,
                pnl_usd REAL NOT NULL DEFAULT 0.0,
                pnl_pct REAL NOT NULL DEFAULT 0.0,
                target_price REAL,
                stop_loss REAL,
                trigger_event TEXT NOT NULL,
                rationale TEXT NOT NULL,
                opened_at INTEGER NOT NULL,
                closed_at INTEGER
            );
        """)

        conn.execute("""
            CREATE TABLE IF NOT EXISTS price_snapshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL,
                btc_price REAL,
                ada_price REAL,
                poly_summary TEXT
            );
        """)

        # Ensure singleton portfolio row
        cursor = conn.cursor()
        cursor.execute("SELECT COUNT(*) FROM portfolio WHERE id = 1")
        if cursor.fetchone()[0] == 0:
            cursor.execute(
                "INSERT INTO portfolio (id, cash_usd, btc_balance, ada_balance, realized_pnl, updated_at) "
                "VALUES (1, 10000.0, 0.0, 0.0, 0.0, ?)",
                (int(time.time()),),
            )

    return conn


# ── Real-Time Market Data Ingestion ──────────────────────────────────

def fetch_crypto_prices() -> dict[str, float]:
    """Fetch live spot prices for BTC and ADA from keyless Coinbase/Kraken endpoints."""
    prices: dict[str, float] = {}

    # 1. Coinbase API
    for sym in ["BTC", "ADA"]:
        try:
            req = urllib.request.Request(
                f"https://api.coinbase.com/v2/prices/{sym}-USD/spot",
                headers={"User-Agent": "BlueLodge-George/1.0"}
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                val = float(data["data"]["amount"])
                prices[sym] = val
        except Exception:
            pass

    # 2. Kraken fallback if any price missing
    if "BTC" not in prices or "ADA" not in prices:
        try:
            req = urllib.request.Request(
                "https://api.kraken.com/0/public/Ticker?pair=XBTUSD,ADAUSD",
                headers={"User-Agent": "BlueLodge-George/1.0"}
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                res = data.get("result", {})
                if "XXBTZUSD" in res and "BTC" not in prices:
                    prices["BTC"] = float(res["XXBTZUSD"]["c"][0])
                if "ADAUSD" in res and "ADA" not in prices:
                    prices["ADA"] = float(res["ADAUSD"]["c"][0])
        except Exception:
            pass

    # Safe defaults if network temporarily offline
    if "BTC" not in prices:
        prices["BTC"] = 83400.0
    if "ADA" not in prices:
        prices["ADA"] = 0.65

    return prices


def fetch_polymarket_markets(limit: int = 6) -> list[dict[str, Any]]:
    """Fetch top active prediction markets from Polymarket keyless Gamma API."""
    url = f"https://gamma-api.polymarket.com/markets?limit={limit}&active=true&closed=false&order=volume24hr&ascending=false"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "BlueLodge-George/1.0"})
        with urllib.request.urlopen(req, timeout=6) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            clean_markets = []
            for m in data:
                prices_raw = m.get("outcomePrices")
                try:
                    if isinstance(prices_raw, str):
                        prices_list = json.loads(prices_raw)
                    else:
                        prices_list = prices_raw or ["0.5", "0.5"]
                    yes_price = float(prices_list[0]) if len(prices_list) > 0 else 0.5
                    no_price = float(prices_list[1]) if len(prices_list) > 1 else 0.5
                except Exception:
                    yes_price, no_price = 0.5, 0.5

                clean_markets.append({
                    "id": m.get("id"),
                    "question": m.get("question"),
                    "volume": float(m.get("volume", 0)),
                    "yes_price": yes_price,
                    "no_price": no_price,
                    "end_date": m.get("endDate"),
                })
            return clean_markets
    except Exception as e:
        logger.warning(f"Polymarket fetch error: {e}")
        return [
            {
                "id": "mock_poly_1",
                "question": "Fed cuts interest rates before July 2026?",
                "volume": 2500000.0,
                "yes_price": 0.42,
                "no_price": 0.58,
                "end_date": "2026-07-01",
            },
            {
                "id": "mock_poly_2",
                "question": "Bitcoin reaches $100k in 2026?",
                "volume": 8400000.0,
                "yes_price": 0.68,
                "no_price": 0.32,
                "end_date": "2026-12-31",
            }
        ]


# ── Position Valuation & Mark-to-Market ──────────────────────────────

def update_mark_to_market(conn: sqlite3.Connection | None = None) -> dict[str, Any]:
    """Recalculate current price, P&L, and portfolio valuation for all open positions."""
    local_conn = conn is None
    if local_conn:
        conn = init_db()

    prices = fetch_crypto_prices()
    poly_markets = {m["id"]: m for m in fetch_polymarket_markets(limit=12)}

    now = int(time.time())
    cursor = conn.cursor()

    # Log price snapshot
    poly_summary = json.dumps([{m["id"]: (m["yes_price"], m["no_price"])} for m in poly_markets.values()][:4])
    cursor.execute(
        "INSERT INTO price_snapshots (timestamp, btc_price, ada_price, poly_summary) VALUES (?, ?, ?, ?)",
        (now, prices.get("BTC"), prices.get("ADA"), poly_summary),
    )

    # Update Open Trades
    cursor.execute("SELECT * FROM trades WHERE status = 'OPEN'")
    open_trades = cursor.fetchall()

    for t in open_trades:
        asset = t["asset"]
        action = t["action"]
        entry = t["entry_price"]
        amount = t["amount"]
        cost = t["cost_usd"]

        cur_price = entry
        if asset == "BTC":
            cur_price = prices.get("BTC", entry)
        elif asset == "ADA":
            cur_price = prices.get("ADA", entry)
        elif asset == "POLYMARKET":
            poly_id = t["symbol"]
            m = poly_markets.get(poly_id)
            if m:
                cur_price = m["yes_price"] if action == "BET_YES" else m["no_price"]

        # Calculate PnL
        if action in ("BUY", "BET_YES", "BET_NO"):
            pnl_usd = (cur_price - entry) * amount
        else: # SHORT / SELL
            pnl_usd = (entry - cur_price) * amount

        pnl_pct = (pnl_usd / cost * 100.0) if cost > 0 else 0.0

        cursor.execute(
            "UPDATE trades SET current_price = ?, pnl_usd = ?, pnl_pct = ? WHERE id = ?",
            (cur_price, pnl_usd, pnl_pct, t["id"]),
        )

    conn.commit()

    # Load Portfolio State
    cursor.execute("SELECT * FROM portfolio WHERE id = 1")
    port = dict(cursor.fetchone())

    cursor.execute("SELECT SUM(cost_usd) as total_invested, SUM(pnl_usd) as total_unrealized FROM trades WHERE status = 'OPEN'")
    sums = cursor.fetchone()
    total_invested = sums["total_invested"] or 0.0
    total_unrealized = sums["total_unrealized"] or 0.0

    net_equity = port["cash_usd"] + total_invested + total_unrealized
    total_pnl = port["realized_pnl"] + total_unrealized

    result = {
        "cash_usd": port["cash_usd"],
        "total_invested": total_invested,
        "total_unrealized_pnl": total_unrealized,
        "realized_pnl": port["realized_pnl"],
        "net_equity": net_equity,
        "total_pnl": total_pnl,
        "pnl_pct": (total_pnl / 10000.0) * 100.0, # based on $10k starting base
        "crypto_prices": prices,
        "active_trades_count": len(open_trades),
        "timestamp": now,
    }

    if local_conn:
        conn.close()

    return result


# ── Trade Execution Engine ────────────────────────────────────────────

def execute_crypto_trade(
    asset: str,
    action: str,
    amount_usd: float,
    rationale: str,
    trigger_event: str = "manual",
    conn: sqlite3.Connection | None = None,
) -> dict[str, Any]:
    """Execute a simulated spot crypto trade and log position in SQLite ledger."""
    local_conn = conn is None
    if local_conn:
        conn = init_db()

    prices = fetch_crypto_prices()
    cur_price = prices.get(asset, 83400.0 if asset == "BTC" else 0.65)
    amount_units = amount_usd / cur_price

    now = int(time.time())
    trade_id = f"tr_{asset.lower()}_{now}_{int(amount_usd)}"

    target_price = cur_price * 1.15 if action == "BUY" else cur_price * 0.85
    stop_loss = cur_price * 0.95 if action == "BUY" else cur_price * 1.05

    cursor = conn.cursor()
    cursor.execute("SELECT cash_usd FROM portfolio WHERE id = 1")
    cash = cursor.fetchone()[0]

    if cash < amount_usd and action == "BUY":
        return {"status": "error", "message": f"Insufficient cash (${cash:.2f} < ${amount_usd:.2f})"}

    cursor.execute("""
        INSERT INTO trades (
            trade_id, asset, symbol, action, status,
            entry_price, current_price, amount, cost_usd,
            pnl_usd, pnl_pct, target_price, stop_loss,
            trigger_event, rationale, opened_at
        ) VALUES (?, ?, ?, ?, 'OPEN', ?, ?, ?, ?, 0.0, 0.0, ?, ?, ?, ?, ?)
    """, (
        trade_id, asset, f"{asset}/USD", action,
        cur_price, cur_price, amount_units, amount_usd,
        target_price, stop_loss, trigger_event, rationale, now
    ))

    # Update cash balance
    if action == "BUY":
        cursor.execute("UPDATE portfolio SET cash_usd = cash_usd - ?, updated_at = ? WHERE id = 1", (amount_usd, now))

    conn.commit()

    trade_info = {
        "status": "ok",
        "trade_id": trade_id,
        "asset": asset,
        "action": action,
        "entry_price": cur_price,
        "amount_units": amount_units,
        "cost_usd": amount_usd,
        "rationale": rationale,
        "trigger": trigger_event,
    }

    if local_conn:
        conn.close()

    return trade_info


def execute_polymarket_bet(
    market_id: str,
    outcome: str,
    amount_usd: float,
    rationale: str,
    trigger_event: str = "polymarket_trigger",
    conn: sqlite3.Connection | None = None,
) -> dict[str, Any]:
    """Execute a simulated prediction market bet on Polymarket."""
    local_conn = conn is None
    if local_conn:
        conn = init_db()

    markets = fetch_polymarket_markets(limit=15)
    matched = next((m for m in markets if m["id"] == market_id), None)
    if not matched and markets:
        matched = markets[0]
        market_id = matched["id"]

    yes_price = matched["yes_price"] if matched else 0.50
    no_price = matched["no_price"] if matched else 0.50
    entry_price = yes_price if outcome.upper() == "YES" else no_price
    contracts = amount_usd / entry_price if entry_price > 0 else 0

    now = int(time.time())
    trade_id = f"poly_{market_id[:8]}_{now}"
    question = matched["question"] if matched else f"Market {market_id}"

    cursor = conn.cursor()
    cursor.execute("SELECT cash_usd FROM portfolio WHERE id = 1")
    cash = cursor.fetchone()[0]

    if cash < amount_usd:
        return {"status": "error", "message": f"Insufficient cash (${cash:.2f} < ${amount_usd:.2f})"}

    action_label = "BET_YES" if outcome.upper() == "YES" else "BET_NO"
    target_price = min(entry_price + 0.30, 0.99)
    stop_loss = max(entry_price - 0.15, 0.05)

    cursor.execute("""
        INSERT INTO trades (
            trade_id, asset, symbol, action, status,
            entry_price, current_price, amount, cost_usd,
            pnl_usd, pnl_pct, target_price, stop_loss,
            trigger_event, rationale, opened_at
        ) VALUES (?, 'POLYMARKET', ?, ?, 'OPEN', ?, ?, ?, ?, 0.0, 0.0, ?, ?, ?, ?, ?)
    """, (
        trade_id, f"POLY:{question[:60]}", action_label,
        entry_price, entry_price, contracts, amount_usd,
        target_price, stop_loss, trigger_event, rationale, now
    ))

    cursor.execute("UPDATE portfolio SET cash_usd = cash_usd - ?, updated_at = ? WHERE id = 1", (amount_usd, now))
    conn.commit()

    res = {
        "status": "ok",
        "trade_id": trade_id,
        "market": question,
        "outcome": outcome.upper(),
        "entry_price": entry_price,
        "contracts": contracts,
        "cost_usd": amount_usd,
        "rationale": rationale,
    }

    if local_conn:
        conn.close()

    return res


# ── Event-Driven Autonomic Reactor Handler ───────────────────────────

def handle_incoming_event(event_type: str, payload_json_str: str) -> None:
    """Reactor entrypoint: parse incoming event from Event Bus and evaluate trade placement."""
    try:
        payload = json.loads(payload_json_str) if isinstance(payload_json_str, str) else payload_json_str
    except Exception:
        payload = {}

    conn = init_db()

    # 1. Crypto Dev Grant / Ecosystem Catalyst Signal
    if event_type in ("finance_crypto_signal", "finance_opportunity_alert"):
        title = payload.get("title", "")
        summary = payload.get("executive_summary", "")
        score = payload.get("score", 0)

        rationale = f"Autonomic trigger on {event_type} (score: {score}): {title}"
        if "bitcoin" in title.lower() or "btc" in title.lower() or "opensats" in title.lower():
            res = execute_crypto_trade("BTC", "BUY", 250.0, rationale, trigger_event=event_type, conn=conn)
            logger.info(f"Executed event-based trade: {res}")
        elif "cardano" in title.lower() or "ada" in title.lower() or "catalyst" in title.lower():
            res = execute_crypto_trade("ADA", "BUY", 200.0, rationale, trigger_event=event_type, conn=conn)
            logger.info(f"Executed event-based trade: {res}")

    # 2. Polymarket Market Movement Signal
    elif event_type in ("polymarket_market_shift", "polymarket_sentiment_signal"):
        markets = fetch_polymarket_markets(limit=3)
        if markets:
            target = markets[0]
            # Place mock bet if odds are favorable
            if target["yes_price"] <= 0.45:
                rat = f"Event trigger {event_type}: Polymarket market '{target['question'][:50]}' odds undervalued at {target['yes_price']:.2f}"
                res = execute_polymarket_bet(target["id"], "YES", 150.0, rat, trigger_event=event_type, conn=conn)
                logger.info(f"Executed event-based Polymarket bet: {res}")

    update_mark_to_market(conn)
    conn.close()


# ── Event Bus & OSINT Reactor Intelligence Extractors ──────────────────

def _get_event_bus_stats() -> dict[str, int] | None:
    """Fetch total event bus dispatches and reaction firings."""
    reactors_path = _GEORGE_DIR / "reactors.json"
    if not reactors_path.exists():
        return None
    try:
        data = json.loads(reactors_path.read_text(encoding="utf-8"))
        stats = data.get("stats", {})
        return {
            "events_total": stats.get("events_total", 0),
            "reactions_fired": stats.get("reactions_fired", 0),
        }
    except Exception:
        return None


def _get_latest_polymarket_trigger() -> str | None:
    """Extract latest prediction market shift from api_triggers.log."""
    triggers_log = _GEORGE_DIR / "ipc" / "api_triggers.log"
    if not triggers_log.exists():
        return None
    try:
        lines = triggers_log.read_text(encoding="utf-8").strip().splitlines()
        for line in reversed(lines[-80:]):
            if "[EVENT_LOG] polymarket_market_shift:" in line:
                json_part = line.split("[EVENT_LOG] polymarket_market_shift:", 1)[1].strip()
                markets = json.loads(json_part)
                if isinstance(markets, list) and markets:
                    top_m = markets[0]
                    for m in markets:
                        q_lower = m.get("question", "").lower()
                        if any(w in q_lower for w in ["fed", "rate", "interest", "bitcoin", "crypto", "election", "president"]):
                            top_m = m
                            break
                    q = top_m.get("question", "")
                    if len(q) > 65:
                        q = q[:62] + "..."
                    vol = top_m.get("volume", 0)
                    vol_str = f"${vol/1e6:.1f}M" if vol >= 1e6 else f"${vol/1e3:.0f}K"
                    prices = top_m.get("outcomePrices", [])
                    if isinstance(prices, str):
                        try:
                            prices = json.loads(prices)
                        except Exception:
                            prices = []
                    odds_str = ""
                    if len(prices) >= 2:
                        try:
                            y = float(prices[0]) * 100
                            n = float(prices[1]) * 100
                            odds_str = f"Yes: {y:.1f}% | No: {n:.1f}%"
                        except Exception:
                            pass
                    return f'"{q}" — {odds_str} ({vol_str} vol)'
    except Exception:
        pass
    return None


def _get_latest_rss_headline() -> str | None:
    """Extract latest intelligence RSS headline captured by rss_news_reactor."""
    rss_log = _GEORGE_DIR / "ipc" / "rss_reactions.log"
    if not rss_log.exists():
        return None
    try:
        lines = rss_log.read_text(encoding="utf-8").strip().splitlines()
        for line in reversed(lines[-20:]):
            if "[REACTION_TRIGGERED] Title:" in line:
                part = line.split("[REACTION_TRIGGERED] Title:", 1)[1].strip()
                if " | URL:" in part:
                    title, _ = part.split(" | URL:", 1)
                    title = title.strip()
                    title = re.sub(r"\s*\[rss:[^\]]+\]", "", title)
                    if len(title) > 80:
                        title = title[:77] + "..."
                    return title
    except Exception:
        pass
    return None


def _get_latest_finance_signals(limit: int = 2) -> list[str]:
    """Extract top-ranked recent financial OSINT signals from seen database."""
    seen_path = _GEORGE_DIR / "ipc" / "finance_osint_seen.json"
    if not seen_path.exists():
        return []
    try:
        data = json.loads(seen_path.read_text(encoding="utf-8"))
        items = list(data.get("items", {}).values())
        if not items:
            return []
        items.sort(key=lambda x: (x.get("first_seen", 0), x.get("score", 0)), reverse=True)
        results = []
        for it in items[:limit]:
            cat = it.get("category", "INTEL")
            title = it.get("title", "")
            if len(title) > 65:
                title = title[:62] + "..."
            score = it.get("score", 0)
            results.append(f"[{cat}] {title} (Score: {score})")
        return results
    except Exception:
        return []


def _get_latest_dossier_catalyst() -> str | None:
    """Extract top actionable revenue or grant opportunity from finance_intel.md."""
    dossier_path = _REPO_ROOT / "dossiers" / "finance_intel.md"
    if not dossier_path.exists():
        return None
    try:
        content = dossier_path.read_text(encoding="utf-8").strip()
        sections = content.split("## Strategic Synthesis Brief:")
        for sec in reversed(sections[1:]):
            lines = [l.strip() for l in sec.strip().splitlines() if l.strip()]
            in_opps = False
            for line in lines:
                if "### 2. High-Priority" in line:
                    in_opps = True
                    continue
                if in_opps:
                    if line.startswith("###"):
                        break
                    if line.startswith("•") and "Test Grant" not in line and "General financial sweep" not in line:
                        bullet = line.lstrip("•").strip()
                        if len(bullet) > 90:
                            bullet = bullet[:87] + "..."
                        return bullet
        # Fallback to any bullet if none found
        for sec in reversed(sections[1:]):
            lines = [l.strip() for l in sec.strip().splitlines() if l.strip()]
            in_opps = False
            for line in lines:
                if "### 2. High-Priority" in line:
                    in_opps = True
                    continue
                if in_opps:
                    if line.startswith("###"):
                        break
                    if line.startswith("•"):
                        bullet = line.lstrip("•").strip()
                        if len(bullet) > 90:
                            bullet = bullet[:87] + "..."
                        return bullet
    except Exception:
        pass
    return None


def _get_latest_marketplace_osint() -> str | None:
    """Extract latest marketplace watcher discovery from osint_seen.json."""
    seen_path = _GEORGE_DIR / "ipc" / "osint_seen.json"
    if not seen_path.exists():
        return None
    try:
        data = json.loads(seen_path.read_text(encoding="utf-8"))
        items = list(data.get("items", {}).values())
        if not items:
            return None
        items.sort(key=lambda x: x.get("first_seen", 0), reverse=True)
        it = items[0]
        title = it.get("title", "")
        title = re.sub(r"\s*\|\s*eBay.*$", "", title, flags=re.IGNORECASE)
        if len(title) > 65:
            title = title[:62] + "..."
        wid = it.get("watcher_id", "osint")
        return f"[{wid}] {title}"
    except Exception:
        pass
    return None


def _get_latest_compute_deals(limit: int = 2) -> list[str]:
    """Extract top active GPU and RAM compute deals from SQLite event store with hyperlinks."""
    db_path = _GEORGE_DIR / "events.db"
    if not db_path.exists():
        return []
    try:
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()
        cur.execute(
            """
            SELECT d.deal_grade, d.discount_pct, d.total_price_usd, d.verification_status,
                   h.model, h.category, o.unit_cost, o.raw_title, o.url
            FROM compute_deal_alerts d
            JOIN compute_hardware_specs h ON d.hardware_id = h.id
            JOIN compute_market_observations o ON d.observation_id = o.id
            WHERE d.status = 'ACTIVE' AND d.deal_grade IN ('STEAL', 'DEAL')
              AND (d.verification_status IS NULL OR d.verification_status != 'REJECTED')
              AND d.id = (
                  SELECT d2.id FROM compute_deal_alerts d2
                  JOIN compute_market_observations o2 ON d2.observation_id = o2.id
                  WHERE d2.status = 'ACTIVE' AND d2.deal_grade IN ('STEAL', 'DEAL')
                    AND (d2.verification_status IS NULL OR d2.verification_status != 'REJECTED')
                    AND o2.clean_url_hash = o.clean_url_hash
                  ORDER BY d2.discount_pct DESC LIMIT 1
              )
            ORDER BY (d.verification_status = 'VERIFIED') DESC, d.discount_pct DESC
            LIMIT ?
            """,
            (limit,)
        )
        rows = cur.fetchall()
        conn.close()
        results = []
        for r in rows:
            hw = r["model"]
            grade = r["deal_grade"]
            disc = r["discount_pct"]
            price = r["total_price_usd"]
            unit = r["unit_cost"]
            url = r["url"] or ""
            v_status = r["verification_status"] or "UNVERIFIED"
            v_badge = " (Verified)" if v_status == "VERIFIED" else ""
            unit_str = f" (${unit:.2f}/GB)" if unit else ""
            if url:
                results.append(f"[{grade} -{disc:.0f}%] [{hw}]({url}) at ${price:,.0f}{unit_str}{v_badge}")
            else:
                results.append(f"[{grade} -{disc:.0f}%] {hw} at ${price:,.0f}{unit_str}{v_badge}")
        return results
    except Exception:
        return []


def _get_detailed_compute_deals(limit: int = 5) -> list[dict[str, Any]]:
    """Extract structured compute deals for detailed markdown synthesis."""
    db_path = _GEORGE_DIR / "events.db"
    if not db_path.exists():
        return []
    try:
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()
        cur.execute(
            """
            SELECT d.deal_grade, d.discount_pct, d.total_price_usd, d.verification_status, d.verification_verdict,
                   h.model, h.category, o.unit_cost, o.raw_title, o.url
            FROM compute_deal_alerts d
            JOIN compute_hardware_specs h ON d.hardware_id = h.id
            JOIN compute_market_observations o ON d.observation_id = o.id
            WHERE d.status = 'ACTIVE' AND d.deal_grade IN ('STEAL', 'DEAL')
              AND (d.verification_status IS NULL OR d.verification_status != 'REJECTED')
              AND d.id = (
                  SELECT d2.id FROM compute_deal_alerts d2
                  JOIN compute_market_observations o2 ON d2.observation_id = o2.id
                  WHERE d2.status = 'ACTIVE' AND d2.deal_grade IN ('STEAL', 'DEAL')
                    AND (d2.verification_status IS NULL OR d2.verification_status != 'REJECTED')
                    AND o2.clean_url_hash = o.clean_url_hash
                  ORDER BY d2.discount_pct DESC LIMIT 1
              )
            ORDER BY (d.verification_status = 'VERIFIED') DESC, d.discount_pct DESC
            LIMIT ?
            """,
            (limit,)
        )
        rows = [dict(r) for r in cur.fetchall()]
        conn.close()
        return rows
    except Exception:
        return []


def _get_latest_reactor_trade() -> str | None:
    """Extract latest autonomic trade executed by an event reactor."""
    log_path = _GEORGE_DIR / "trading" / "trading.log"
    if not log_path.exists():
        return None
    try:
        lines = log_path.read_text(encoding="utf-8").strip().splitlines()
        for line in reversed(lines[-30:]):
            if "Executed event-based trade:" in line:
                m = re.search(r"action':\s*'([^']+)',\s*'entry_price':\s*([0-9.]+).*?'trigger':\s*'([^']+)'", line)
                if m:
                    action, price, trigger = m.groups()
                    return f"{action} @ ${float(price):.4f} (Trigger: {trigger})"
                m_asset = re.search(r"'asset':\s*'([^']+)'", line)
                asset = m_asset.group(1) if m_asset else "CRYPTO"
                m_cost = re.search(r"'cost_usd':\s*([0-9.]+)", line)
                cost = f"${float(m_cost.group(1)):.0f}" if m_cost else ""
                return f"Auto-trade {cost} on event trigger ({asset})"
    except Exception:
        pass
    return None


def _generate_extended_osint_report(state: dict[str, Any], ts_str: str) -> str:
    """Generate exhaustive local markdown report with full details, raw signals, and links."""
    lines = [
        "# Sovereign OSINT & Financial Intelligence Report",
        f"Generated: {ts_str}",
        "",
        "## 1. Portfolio & Trading Telemetry",
        f"- **Net Equity**: ${state['net_equity']:.2f}",
        f"- **Total P&L**: ${state['total_pnl']:.2f} ({state['pnl_pct']:.2f}%)",
        f"- **Available Cash**: ${state['cash_usd']:.2f} | **Invested Capital**: ${state['total_invested']:.2f}",
        f"- **Bitcoin (BTC/USD)**: ${state['crypto_prices'].get('BTC', 0):,.2f}",
        f"- **Cardano (ADA/USD)**: ${state['crypto_prices'].get('ADA', 0):.4f}",
        "",
        "## 2. Event Bus & Reactor Telemetry",
    ]
    stats = _get_event_bus_stats()
    if stats:
        lines.append(f"- **Total Events Dispatched**: {stats['events_total']:,}")
        lines.append(f"- **Total Reactions Fired**: {stats['reactions_fired']:,}")

    reactors_path = _GEORGE_DIR / "reactors.json"
    if reactors_path.exists():
        try:
            rdata = json.loads(reactors_path.read_text(encoding="utf-8"))
            lines.append("\n### Active Registered Event Bus Reactors")
            lines.append("| Reactor ID | Event Type | Enabled | Debounce |")
            lines.append("| :--- | :--- | :---: | :---: |")
            for r in rdata.get("reactors", []):
                en = "Yes" if r.get("enabled") else "No"
                lines.append(f"| `{r.get('id')}` | `{r.get('event_type')}` | {en} | {r.get('debounce_secs')}s |")
        except Exception:
            pass

    seen_path = _GEORGE_DIR / "ipc" / "finance_osint_seen.json"
    if seen_path.exists():
        try:
            sdata = json.loads(seen_path.read_text(encoding="utf-8"))
            items = list(sdata.get("items", {}).values())
            if items:
                items.sort(key=lambda x: (x.get("first_seen", 0), x.get("score", 0)), reverse=True)
                lines.append("\n## 3. Captured Financial OSINT Opportunities & Signals")
                lines.append("| Category | Score | Title | URL |")
                lines.append("| :---: | :---: | :--- | :--- |")
                for it in items[:15]:
                    lines.append(f"| {it.get('category', 'INTEL')} | {it.get('score', 0)} | {it.get('title', '')} | {it.get('url', '')} |")
        except Exception:
            pass

    poly = _get_latest_polymarket_trigger()
    if poly:
        lines.append(f"\n## 4. Latest Prediction Market Shift")
        lines.append(f"- {poly}")

    rss = _get_latest_rss_headline()
    if rss:
        lines.append(f"\n## 5. Live News & RSS Reactions")
        lines.append(f"- {rss}")

    deals = _get_detailed_compute_deals(limit=10)
    if deals:
        lines.append("\n## 6. Top Active Compute Alpha Deals (GPU & RAM Arbitrage)")
        lines.append("| Grade | Hardware | Price | Discount | Unit Cost | Verification | Listing Link |")
        lines.append("| :---: | :--- | :---: | :---: | :---: | :---: | :--- |")
        for d in deals:
            grade = d.get("deal_grade", "DEAL")
            hw = d.get("model") or (d.get("hardware_id") or "HARDWARE").upper().replace("_", " ")
            price = f"${d.get('total_price_usd', 0):,.2f}"
            disc = f"{d.get('discount_pct', 0):.1f}%"
            unit = f"${d.get('unit_cost', 0):.2f}/GB" if d.get('unit_cost') else "--"
            title = d.get("raw_title") or "Direct Listing Link"
            v_status = d.get("verification_status") or "PENDING"
            v_badge = "✅ VERIFIED" if v_status == "VERIFIED" else "⏳ PENDING"
            if len(title) > 45:
                title = title[:42] + "..."
            url = d.get("url", "")
            link = f"[{title}]({url})" if url else title
            lines.append(f"| **{grade}** | {hw} | {price} | {disc} | {unit} | {v_badge} | {link} |")

    sdr_summary = _get_sdr_osint_summary(hours=3.0)
    if sdr_summary:
        lines.append("\n## 7. Local P25 SDR SIGINT & Public Safety Radio Telemetry (3h Window)")
        lines.append(sdr_summary)

    lines.append("\n---\n*Report compiled autonomously by Sovereign Blue Lodge Trading & OSINT Reporter.*")
    return "\n".join(lines)


def _get_sdr_osint_summary(hours: float = 3.0) -> str:
    """Fetch compiled 3-hour statistical & tactical P25 SDR summary from sdr_ingest.py."""
    try:
        sys.path.insert(0, str(_REPO_ROOT / "lib" / "tools"))
        import sdr_ingest
        return sdr_ingest.generate_osint_sdr_summary_markdown(hours=hours)
    except Exception as e:
        logger.debug(f"SDR OSINT summary warning: {e}")
        return ""


# ── Live per-cycle Intel Fetch (multi-domain SearXNG news + 10-min price deltas) ──

_INTEL_SEEN_PATH = _GEORGE_DIR / "ipc" / "intel_seen.json"
_SEARXNG_URL = os.environ.get("SEARXNG_URL", "http://127.0.0.1:8081")

# Multi-domain OSINT registry. Every 10-min cycle probes all domains once with a
# rotating query angle (full rotation per domain over len(queries) cycles, ~30 min
# for 3 angles), so each domain keeps a fresh, broad result pool. One static query
# per cycle would exhaust the dedupe store and produce empty intel.
_INTEL_DOMAINS = [
    {"id": "ai_frontier", "tag": "AI",
     "queries": ["OpenAI OR Anthropic OR Google DeepMind model release announcement",
                 "frontier AI lab funding partnership acquisition",
                 "AI datacenter Nvidia GPU capacity expansion"],
     "junk_urls": [r"(?i)(cosmic\.nyc|collegeconsult|essay)"],
    },
    {"id": "ai_policy", "tag": "AI-POL",
     "queries": ["AI regulation executive order EU AI Act enforcement",
                 "AI export controls compute sanctions datacenter",
                 "AI safety incident model risk"],
     "junk_urls": [r"(?i)(now\.solar|archive\.li)"],
    },
    {"id": "military_us", "tag": "MIL",
     "queries": ["US military deployment carrier strike group",
                 "NATO exercise deployment defense pact",
                 "US military aid package base buildup"],
     "junk_urls": [r"(?i)(usembassy|prnewswire|businesswire)"],
    },
    {"id": "military_tech", "tag": "MIL-TECH",
     "queries": ["missile test hypersonic interceptor",
                 "drone system battlefield deployment",
                 "Golden Dome missile defense budget"],
     "junk_urls": [r"(?i)(news\.sbs\.co\.kr)"],
    },
    {"id": "geo_ukraine", "tag": "GEO-UA",
     "queries": ["Ukraine Russia ceasefire negotiations",
                 "Ukraine sanctions refinery attack",
                 "Zelensky Putin talks"],
     "junk_urls": [],
    },
    {"id": "geo_uschina", "tag": "GEO-USCN",
     "queries": ["US China tariffs trade negotiations",
                 "Taiwan Strait South China Sea",
                 "Japan South Korea India China defense border"],
     "junk_urls": [r"(?i)(scmp\.com/topics|thefinancialexpress\.com\.bd)"],
    },
    {"id": "chips_supply", "tag": "CHIPS",
     "queries": ["TSMC Nvidia ASML export controls fab",
                 "semiconductor smuggling export enforcement",
                 "chip factory capacity expansion investment"],
     "junk_urls": [r"(?i)(indexbox\.io)"],
    },
    {"id": "energy", "tag": "ENERGY",
     "queries": ["OPEC oil production target price",
                 "LNG pipeline natural gas sanctions",
                 "grid datacenter power demand critical minerals"],
     "junk_urls": [r"(?i)(indexbox\.io)"],
    },
    {"id": "macro_fin", "tag": "MACRO",
     "queries": ["Fed rate decision CPI inflation",
                 "Treasury yields bond market selloff",
                 "bank credit stress regional lender"],
     "junk_urls": [],
    },
    {"id": "crypto", "tag": "CRYPTO",
     "queries": ["bitcoin price news today",
                 "crypto market breaking news",
                 "cardano ADA news",
                 "ethereum ETF regulation news",
                 "stablecoin SEC Fed crypto regulation news"],
     "junk_urls": [],
    },
]

# Junk-title patterns: evergreen listicles, SEO market-outlook pages, presale shilling.
_JUNK_TITLE_RE = re.compile(
    r"(?i)(price prediction|price forecast|how to buy|how to mine|best (crypto )?wallet"
    r"|whitepaper|presale|airdrop|sign ?up|bonus|stake ?up|explorer|explorador"
    r"|detective|lost coins|alpha ?pepe|top [0-9]+ coins"
    r"|market outlook|news and statistics|how (high school|students|companies|to use)"
    r"|should (students|companies|businesses) use)"
)


def _is_junk_intel_result(domain: dict[str, Any], title: str, url: str, snippet: str) -> bool:
    """Filter non-news results: SEO junk, foreign-language pages, raw price trackers,
    and per-domain site exclusions (aggregator homepages, PR wires, essay mills)."""
    if _JUNK_TITLE_RE.search(title or ""):
        return True
    for pat in domain.get("junk_urls") or []:
        if re.search(pat, url):
            return True
    text = (title or "") + " " + (snippet or "")[:80]
    # Foreign-language results — high non-ASCII ratio
    if text:
        non_ascii = sum(1 for ch in text if ord(ch) > 127)
        if non_ascii / max(len(text), 1) > 0.04:
            return True
    # Non-ASCII-clean foreign headlines (Spanish/Portuguese/German/Vietnamese stop words)
    if re.search(r"(?i)\b(busca|buscan|para|antes|este d\u00eda|d\u00eda|y la|y el|abrir\u00e1|previs\u00e3o|sobre o|und (die|der|das|eine)|wird f\u00fcr|nachrichten|cạnh tranh|tải về|segun)\b", text):
        return True
    # Foreign comma-decimal numbers ("4,61%" / "12,34") — Spanish/LatAm price-writeup signal
    if re.search(r"(?i)\b\d{1,2},\d{2}\s*%?\b", (title or "")[:60]):
        return True
    # Pure price-tracker / coin-info pages (not news)
    if re.search(r"(?i)investing\.com/(crypto|fx|commodities)/[a-z0-9-]+", url):
        return True
    if re.search(r"(?i)coingecko\.com/en/(coins|price)", url):
        return True
    if re.search(r"(?i)coinmarketcap\.com/currencies/", url):
        return True
    if re.search(r"(?i)(/explorer|bitinfocharts|coinpaprika\.com/coin)", url):
        return True
    return False
def _load_intel_seen() -> dict:
    try:
        return json.loads(_INTEL_SEEN_PATH.read_text(encoding="utf-8"))
    except Exception:
        return {"items": {}}
def _save_intel_seen(state: dict) -> None:
    try:
        _INTEL_SEEN_PATH.parent.mkdir(parents=True, exist_ok=True)
        state["items"] = dict(list(state.get("items", {}).items())[-1500:])
        _INTEL_SEEN_PATH.write_text(json.dumps(state, indent=2), encoding="utf-8")
    except Exception:
        pass
def _fetch_live_intel(limit_per_domain: int = 2) -> dict[str, list[dict[str, Any]]]:
    """Probe every intel domain once per 10-min cycle with a rotating query angle.

    Each domain cycles through its query pool one angle at a time (a full rotation
    takes len(queries) cycles, ~30 min for 3 angles) so the result pool stays broad
    instead of one static query exhausting the dedupe store. Deduped across cycles
    via the seen store; one story per publisher per cycle keeps the feed readable.

    Returns {domain_id: [fresh item dicts]} for all registered domains.
    """
    try:
        from osint_watcher import query_searxng
    except Exception:
        return {}

    cycle = int(time.time()) // 600
    seen_state = _load_intel_seen()
    seen_items = seen_state.setdefault("items", {})
    out: dict[str, list[dict[str, Any]]] = {}
    for d in _INTEL_DOMAINS:
        q = d["queries"][cycle % len(d["queries"])]
        try:
            raw = query_searxng(_SEARXNG_URL, q, time_range="day", categories=["news", "general"]) or []
        except Exception:
            raw = []
        fresh: list[dict[str, Any]] = []
        pubs: set[str] = set()
        for r in raw:
            title = re.sub(r"\s+", " ", (r.get("title") or "")).strip()
            url = (r.get("url") or "").strip()
            snippet = re.sub(r"\s+", " ", (r.get("content") or "")).strip()
            if not title or not url or "127.0.0.1" in url:
                continue
            if _is_junk_intel_result(d, title, url, snippet):
                continue
            dom = re.sub(r"^www\.", "", (url.split("/")[2] if url.startswith("http") else ""))
            if not dom or dom in pubs:  # one story per publisher keeps the feed readable
                continue
            h = hashlib.sha256(f"{url}|{title}".encode("utf-8")).hexdigest()
            if h in seen_items:
                continue
            seen_items[h] = {"title": title, "url": url, "first_seen": int(time.time()), "domain": d["id"]}
            pubs.add(dom)
            fresh.append({"title": title, "url": url, "snippet": snippet[:160], "engine": r.get("engine", "searxng")})
            if len(fresh) >= limit_per_domain:
                break
        out[d["id"]] = fresh
    _save_intel_seen(seen_state)
    return out
def _recent_intel(domain_id: str | None = None, max_age_seconds: int = 1800, limit: int = 3) -> list[dict[str, Any]]:
    """Most recent captures within the window (transparent fallback when a cycle is quiet)."""
    try:
        items = _load_intel_seen().get("items", {}).values()
        recent = [it for it in items
                  if int(time.time()) - it.get("first_seen", 0) <= max_age_seconds
                  and (domain_id is None or it.get("domain") == domain_id)]
        recent.sort(key=lambda it: it.get("first_seen", 0), reverse=True)
        return recent[:limit]
    except Exception:
        return []
def _get_10min_price_deltas(conn: sqlite3.Connection) -> list[tuple[str, float, float, float]]:
    """Compute BTC/ADA price movement over the trailing ~10 minutes from snapshots."""
    try:
        cur = conn.cursor()
        row = cur.execute(
            "SELECT timestamp, btc_price, ada_price FROM price_snapshots ORDER BY timestamp DESC LIMIT 1"
        ).fetchone()
        if not row:
            return []
        latest_ts, btc, ada = row
        prev = cur.execute(
            "SELECT btc_price, ada_price FROM price_snapshots WHERE timestamp <= ? ORDER BY timestamp DESC LIMIT 1",
            (latest_ts - 600,),
        ).fetchone()
        if not prev:
            return []
        out = []
        for sym, cur_p, old_p in (("BTC", btc, prev[0]), ("ADA", ada, prev[1])):
            if old_p:
                delta = cur_p - old_p
                out.append((sym, cur_p, delta, (delta / old_p) * 100.0))
        return out
    except Exception:
        return []


# ── 10-Minute Streaming Performance Reporter ──────────────────────────

def generate_streaming_report() -> str:
    """Generate high-density performance and trajectory report."""
    conn = init_db()
    state = update_mark_to_market(conn)

    cursor = conn.cursor()

    cursor.execute("SELECT * FROM trades WHERE status = 'CLOSED' ORDER BY closed_at DESC LIMIT 5")
    closed_trades = cursor.fetchall()
    price_deltas = _get_10min_price_deltas(conn)
    conn.close()

    ts_str = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(state["timestamp"]))
    pnl_sign = "+" if state["total_pnl"] >= 0 else ""
    pnl_indicator = "[GAIN]" if state["total_pnl"] >= 0 else "[LOSS]"

    lines = [
        "========================================================================",
        f"  SOVEREIGN TRADING & INTEL REPORT  |  {ts_str}",
        "========================================================================",
        f"  Portfolio Status:    {pnl_indicator} {pnl_sign}${state['total_pnl']:.2f} ({pnl_sign}{state['pnl_pct']:.2f}%)",
        f"  Net Equity:          ${state['net_equity']:.2f}",
        f"  Available Cash:      ${state['cash_usd']:.2f}  |  Invested Capital: ${state['total_invested']:.2f}",
        f"  Unrealized P&L:      {pnl_sign}${state['total_unrealized_pnl']:.2f}",
        f"  Realized P&L:        ${state['realized_pnl']:.2f}",
        "",
        "── LIVE MARKET FEEDS & TRAJECTORY ──────────────────────────────────────",
        f"  Bitcoin (BTC/USD):   ${state['crypto_prices'].get('BTC', 0):,.2f}",
        f"  Cardano (ADA/USD):   ${state['crypto_prices'].get('ADA', 0):.4f}",
        "",
    ]

    if closed_trades:
        lines.append("── RECENT CLOSED TRADES ────────────────────────────────────────────────")
        for ct in closed_trades:
            pnl_s = "+" if ct["pnl_usd"] >= 0 else ""
            lines.append(f"  - [{ct['action']}] {ct['symbol']} closed at ${ct['exit_price']:.2f} ({pnl_s}${ct['pnl_usd']:.2f})")
        lines.append("")

    lines.append("── LIVE PRICE TRAJECTORY (trailing 10 min) ─────────────────────────────")
    for sym, cur_p, delta, pct in price_deltas:
        d_sign = "+" if delta >= 0 else ""
        arrow = "▲" if delta >= 0 else "▼"
        cur_fmt = f"${cur_p:,.2f}" if sym == "BTC" else f"${cur_p:.4f}"
        delta_fmt = f"${abs(delta):,.2f}" if sym == "BTC" else f"${abs(delta):.4f}"
        lines.append(f"  {sym}: {cur_fmt}  {arrow} {delta_fmt} ({d_sign}{pct:.2f}%) vs 10 min ago")
    if not price_deltas:
        lines.append("  (snapshot history still accumulating — deltas arrive in a couple of cycles)")
    lines.append("")

    lines.append("── INTEL FEED (multi-domain, captured this cycle) ──────────────────────")
    fresh_intel = _fetch_live_intel(limit_per_domain=2)
    total_fresh = sum(len(v) for v in fresh_intel.values())
    for d in _INTEL_DOMAINS:
        for it in fresh_intel.get(d["id"]) or []:
            dom = re.sub(r"^www\.", "", (it["url"].split("/")[2] if it["url"].startswith("http") else ""))
            lines.append(f"  [{d['tag']:9s}] {it['title'][:100]}")
            if it.get("snippet"):
                lines.append(f"               {it['snippet'][:140]}")
            lines.append(f"               {dom} → {it['url']}")
    if total_fresh == 0:
        lines.append("  (no new events captured this cycle — feed quiet, not stale)")
        for it in _recent_intel(max_age_seconds=1800, limit=3):
            tag = next((d["tag"] for d in _INTEL_DOMAINS if d["id"] == it.get("domain")), "FEED")
            age_min = max(0, (int(time.time()) - it.get("first_seen", 0)) // 60)
            lines.append(f"   most recent [{tag}] {age_min} min ago: {it.get('title', '')[:80]}")
            lines.append(f"     {it.get('url', '')}")

    deals = _get_latest_compute_deals(limit=2)
    for d in deals:
        lines.append(f"  [COMPUTE]     {d}")

    lines.append("")
    sdr_section = _get_sdr_osint_summary(hours=3.0)
    if sdr_section:
        lines.append(sdr_section)
        lines.append("")

    lines.append(f"  Full OSINT dossier with all captured URLs: {_OSINT_FINANCE_REPORT}")

    lines.append("")
    lines.append("========================================================================")
    report_text = "\n".join(lines)

    # Persist locally
    _LATEST_REPORT.parent.mkdir(parents=True, exist_ok=True)
    _LATEST_REPORT.write_text(report_text, encoding="utf-8")

    # Persist extended report
    _OSINT_FINANCE_REPORT.parent.mkdir(parents=True, exist_ok=True)
    extended_report = _generate_extended_osint_report(state, ts_str)
    _OSINT_FINANCE_REPORT.write_text(extended_report, encoding="utf-8")

    _REPORT_LOG.parent.mkdir(parents=True, exist_ok=True)
    with open(_REPORT_LOG, "a", encoding="utf-8") as lf:
        lf.write(f"\n--- {ts_str} ---\n" + report_text + "\n")

    return report_text


def _default_discord_user() -> str:
    for cfg in (_GEORGE_DIR / "keys.conf", _GEORGE_DIR / "secrets.env"):
        if cfg.exists():
            try:
                for line in cfg.read_text(encoding="utf-8").splitlines():
                    s = line.strip()
                    for k in ("DISCORD_DM_USER_ID", "OPERATOR_HANDLE", "DISCORD_OPERATOR_ID"):
                        if s.startswith(f"{k}="):
                            val = s.split("=", 1)[1].strip().strip('"').strip("'")
                            if val:
                                return val
            except Exception:
                pass
    return os.environ.get("DISCORD_DM_USER_ID") or os.environ.get("OPERATOR_HANDLE") or "operator"


def send_discord_stream_report(user_id: str = "") -> bool:
    """Send the 10-minute performance report to Discord DM via social.sh bridge."""
    if not user_id or user_id == "default":
        user_id = _default_discord_user()
    report = generate_streaming_report()

    # Call discord_dm in social.sh
    cmd = f"""
        LODGE_DIR="{_REPO_ROOT}"
        source "$LODGE_DIR/lib/comms/social.sh" 2>/dev/null || true
        discord_dm "{user_id}" "$(cat << 'EOF'
{report}
EOF
)" 2>&1
    """
    try:
        proc = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=30)
        out = proc.stdout.strip()
        logger.info(f"Discord DM status: {out}")
        delivered = ("Sent to Discord" in (proc.stdout or ""))
        if not delivered:
            logger.warning("Discord DM NOT delivered. tail: " + ((proc.stdout or "") + (proc.stderr or ""))[-600:])
        return delivered
    except Exception as e:
        logger.warning(f"Discord DM delivery exception: {e}")
        return False


def get_full_status_json() -> dict[str, Any]:
    """Retrieve full portfolio status, open and closed trades, and live markets as structured JSON."""
    conn = init_db()
    mtm = update_mark_to_market(conn)
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM trades WHERE status = 'OPEN' ORDER BY opened_at DESC")
    open_trades = [dict(r) for r in cursor.fetchall()]
    cursor.execute("SELECT * FROM trades WHERE status = 'CLOSED' ORDER BY closed_at DESC LIMIT 25")
    closed_trades = [dict(r) for r in cursor.fetchall()]
    cursor.execute("SELECT * FROM price_snapshots ORDER BY timestamp DESC LIMIT 20")
    history = [dict(r) for r in cursor.fetchall()]
    conn.close()

    markets = fetch_polymarket_markets(limit=8)

    return {
        "status": "ok",
        "portfolio": mtm,
        "open_trades": open_trades,
        "closed_trades": closed_trades,
        "price_history": history,
        "polymarkets": markets,
        "event_bus": {
            "stats": _get_event_bus_stats(),
            "latest_polymarket": _get_latest_polymarket_trigger(),
            "latest_rss": _get_latest_rss_headline(),
            "latest_finance_signals": _get_latest_finance_signals(),
            "latest_catalyst": _get_latest_dossier_catalyst(),
            "latest_marketplace": _get_latest_marketplace_osint(),
            "latest_compute_deals": _get_detailed_compute_deals(limit=5),
            "latest_reactor_trade": _get_latest_reactor_trade(),
        },
    }


# ── CLI & Subcommands ────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="Sovereign Mock Trading Bot & Polymarket Simulator")
    parser.add_argument("--status", action="store_true", help="Print current portfolio status and +/- P&L")
    parser.add_argument("--json", action="store_true", help="Output full portfolio, positions, and markets as JSON")
    parser.add_argument("--report", action="store_true", help="Generate 10-minute streaming intelligence report")
    parser.add_argument("--send-dm", action="store_true", help="Stream report directly to configured operator Discord DM")
    parser.add_argument("--user", type=str, default="", help="Discord username or user ID for DM delivery")
    parser.add_argument("--trade", choices=["BUY", "SELL"], help="Execute manual crypto trade")
    parser.add_argument("--asset", choices=["BTC", "ADA"], default="BTC", help="Crypto asset for trade")
    parser.add_argument("--amount", type=float, default=200.0, help="USD amount for trade/bet")
    parser.add_argument("--rationale", type=str, default="Manual operator execution", help="Trade reasoning")
    parser.add_argument("--bet-poly", choices=["YES", "NO"], help="Place manual Polymarket prediction bet")
    parser.add_argument("--market-id", type=str, help="Polymarket market ID")
    parser.add_argument("--event-trigger", type=str, help="Event Bus type for incoming reaction")
    parser.add_argument("--event-payload", type=str, help="JSON payload for incoming reaction")
    parser.add_argument("--markets", action="store_true", help="List active Polymarket prediction markets")
    parser.add_argument("--reset-portfolio", action="store_true", help="Reset simulation portfolio to initial $10k cash")

    args = parser.parse_args()

    if args.json:
        data = get_full_status_json()
        print(json.dumps(data, indent=2))
        sys.exit(0)

    if args.reset_portfolio:
        conn = init_db()
        with conn:
            conn.execute("UPDATE portfolio SET cash_usd = 10000.0, btc_balance = 0.0, ada_balance = 0.0, realized_pnl = 0.0, updated_at = ?", (int(time.time()),))
            conn.execute("DELETE FROM trades")
        conn.close()
        print("[OK] Paper trading portfolio reset to $10,000 USD cash.")
        sys.exit(0)

    if args.markets:
        markets = fetch_polymarket_markets(limit=8)
        print("=" * 72)
        print("  ACTIVE POLYMARKET PREDICTION MARKETS (ZERO-AUTH LIVE FEED)")
        print("=" * 72)
        for m in markets:
            print(f"  [{m['id']}] {m['question']}")
            print(f"      Yes: {m['yes_price']:.2f}  |  No: {m['no_price']:.2f}  |  Vol: ${m['volume']:,.0f}")
            print()
        sys.exit(0)

    if args.trade:
        res = execute_crypto_trade(args.asset, args.trade, args.amount, args.rationale)
        print(json.dumps(res, indent=2))
        sys.exit(0)

    if args.bet_poly:
        res = execute_polymarket_bet(args.market_id or "auto", args.bet_poly, args.amount, args.rationale)
        print(json.dumps(res, indent=2))
        sys.exit(0)

    if args.event_trigger and args.event_payload:
        handle_incoming_event(args.event_trigger, args.event_payload)
        print("[OK] Processed event trigger reaction.")
        sys.exit(0)

    if args.send_dm:
        success = send_discord_stream_report(args.user)
        print(f"[OK] Stream report dispatched (Delivery success: {success})")
        sys.exit(0)

    if args.report:
        print(generate_streaming_report())
        sys.exit(0)

    # Default: status
    print(generate_streaming_report())


if __name__ == "__main__":
    main()



