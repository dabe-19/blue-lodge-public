#!/usr/bin/env python3
"""Sovereign Event Store, Timeseries Engine & Compute Deal Evaluator for Blue Lodge.

Manages a rolling 90-day SQLite WAL database (.george/events.db) logging:
  1. All reactive events passing through the POSIX FIFO Event Bus.
  2. Reactor execution telemetry, latencies, and outcome status.
  3. Queriable full-text search (FTS5) across historical event payloads.
  4. Compute hardware timeseries price ticks (GPUs & RAM) with unit economics ($/GB).
  5. Dynamic deal valuation (trailing 14-day median, benchmark FMV, discount grading).
  6. Rolling retention pruning (90-day TTL) and page compaction.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import re
import sqlite3
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

logger = logging.getLogger("event_store")
logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")

_REPO_ROOT = Path(__file__).resolve().parents[2]
_GEORGE_DIR = Path(os.environ.get("GEORGE_DIR") or _REPO_ROOT / ".george")
_DEFAULT_DB_PATH = _GEORGE_DIR / "events.db"

# ── Database Schema Definition ─────────────────────────────────────────

SCHEMA_SQL = """
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA busy_timeout = 5000;
PRAGMA foreign_keys = ON;

-- 1. Typed Event Contracts Registry
CREATE TABLE IF NOT EXISTS event_contracts (
    event_type TEXT PRIMARY KEY,
    domain TEXT NOT NULL,
    description TEXT NOT NULL,
    retention_days INTEGER NOT NULL DEFAULT 90,
    schema_json TEXT DEFAULT '{}',
    created_at INTEGER NOT NULL
);

-- 2. Global Event Store (Append-Only Event Ledger)
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id TEXT UNIQUE NOT NULL,
    event_type TEXT NOT NULL,
    source TEXT NOT NULL,
    depth INTEGER NOT NULL DEFAULT 0,
    payload TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type);
CREATE INDEX IF NOT EXISTS idx_events_source ON events(source);
CREATE INDEX IF NOT EXISTS idx_events_ts ON events(timestamp);
CREATE INDEX IF NOT EXISTS idx_events_created ON events(created_at);

-- 3. FTS5 Full-Text Search Virtual Table
CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
    event_id,
    event_type,
    source,
    payload,
    content='events',
    content_rowid='id'
);

-- FTS Synchronization Triggers
CREATE TRIGGER IF NOT EXISTS trg_events_ai AFTER INSERT ON events BEGIN
    INSERT INTO events_fts(rowid, event_id, event_type, source, payload)
    VALUES (new.id, new.event_id, new.event_type, new.source, new.payload);
END;

CREATE TRIGGER IF NOT EXISTS trg_events_ad AFTER DELETE ON events BEGIN
    INSERT INTO events_fts(events_fts, rowid, event_id, event_type, source, payload)
    VALUES ('delete', old.id, old.event_id, old.event_type, old.source, old.payload);
END;

-- 4. Reactor Execution & Dispatch Telemetry
CREATE TABLE IF NOT EXISTS reactions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    reactor_id TEXT NOT NULL,
    action_cmd TEXT NOT NULL,
    status TEXT NOT NULL,             -- 'FIRED', 'DEBOUNCED', 'CIRCUIT_BREAKER', 'SUCCESS', 'ERROR'
    exit_code INTEGER DEFAULT 0,
    duration_ms INTEGER DEFAULT 0,
    output_snippet TEXT DEFAULT '',
    fired_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_reactions_evt ON reactions(event_id);
CREATE INDEX IF NOT EXISTS idx_reactions_reactor ON reactions(reactor_id);
CREATE INDEX IF NOT EXISTS idx_reactions_type ON reactions(event_type);
CREATE INDEX IF NOT EXISTS idx_reactions_fired_at ON reactions(fired_at);

-- 5. Compute Hardware Taxonomy & Benchmark Specifications (GPU & RAM)
CREATE TABLE IF NOT EXISTS compute_hardware_specs (
    id TEXT PRIMARY KEY,
    category TEXT NOT NULL,           -- 'GPU' or 'RAM'
    family TEXT NOT NULL,             -- 'NVIDIA_AMPERE', 'NVIDIA_ADA', 'DDR5_SERVER_ECC', etc.
    model TEXT NOT NULL,              -- 'RTX 3090', 'RTX 4090', 'A100 80GB', 'DDR5-5600 ECC Reg'
    capacity_gb REAL NOT NULL,        -- 24.0 (VRAM), 64.0 (RAM)
    target_fmv_usd REAL NOT NULL,     -- Benchmark Fair Market Value
    deal_ceiling_usd REAL NOT NULL,   -- Alert ceiling threshold
    min_viable_price_usd REAL NOT NULL-- Price floor to eliminate accessories/boxes
);

-- 6. Timeseries Market Observations (Every Captured Listing Tick)
CREATE TABLE IF NOT EXISTS compute_market_observations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id TEXT,
    observed_at INTEGER NOT NULL,
    source TEXT NOT NULL,             -- 'ebay', 'reddit_hardwareswap', 'liquidations'
    hardware_id TEXT NOT NULL,
    raw_title TEXT NOT NULL,
    url TEXT NOT NULL,
    clean_url_hash TEXT NOT NULL,
    price_usd REAL NOT NULL,
    shipping_usd REAL DEFAULT 0.0,
    total_price_usd REAL NOT NULL,
    unit_cost REAL NOT NULL,          -- $/GB VRAM or $/GB RAM
    condition TEXT DEFAULT 'USED',
    seller TEXT DEFAULT '',
    notes TEXT DEFAULT '',
    FOREIGN KEY(hardware_id) REFERENCES compute_hardware_specs(id)
);

CREATE INDEX IF NOT EXISTS idx_cmo_hw_time ON compute_market_observations(hardware_id, observed_at);
CREATE INDEX IF NOT EXISTS idx_cmo_hash ON compute_market_observations(clean_url_hash);
CREATE INDEX IF NOT EXISTS idx_cmo_price ON compute_market_observations(total_price_usd);

-- 7. Evaluated Compute Deals & Alpha Alerts
CREATE TABLE IF NOT EXISTS compute_deal_alerts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    observation_id INTEGER NOT NULL,
    hardware_id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    total_price_usd REAL NOT NULL,
    benchmark_fmv_usd REAL NOT NULL,
    rolling_median_14d REAL NOT NULL,
    discount_pct REAL NOT NULL,       -- (1 - price / median) * 100
    deal_grade TEXT NOT NULL,         -- 'STEAL' (>=30%), 'DEAL' (>=20%), 'FAIR'
    alerted_discord INTEGER DEFAULT 0,
    status TEXT DEFAULT 'ACTIVE',     -- 'ACTIVE', 'DISMISSED', 'EXPIRED'
    verification_status TEXT DEFAULT 'PENDING',  -- 'PENDING', 'VERIFIED', 'REJECTED'
    verification_verdict TEXT DEFAULT NULL,      -- 'AUTHENTIC', 'PARTS_OR_DEFECTIVE', 'ACCESSORY_TRAP', 'SCAM_SUSPECTED', etc.
    verification_reasoning TEXT DEFAULT NULL,
    verified_at INTEGER DEFAULT NULL,
    FOREIGN KEY(observation_id) REFERENCES compute_market_observations(id),
    FOREIGN KEY(hardware_id) REFERENCES compute_hardware_specs(id)
);

CREATE INDEX IF NOT EXISTS idx_cda_created ON compute_deal_alerts(created_at);
CREATE INDEX IF NOT EXISTS idx_cda_grade ON compute_deal_alerts(deal_grade);
CREATE INDEX IF NOT EXISTS idx_cda_status ON compute_deal_alerts(status);

-- 8. Forensic Deal Verifications & Fake Deal Detection Ledger
CREATE TABLE IF NOT EXISTS deal_verifications (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    deal_alert_id INTEGER,
    observation_id INTEGER,
    hardware_id TEXT NOT NULL,
    url TEXT NOT NULL,
    http_status INTEGER,
    fetched_title TEXT,
    condition TEXT,
    seller_feedback_count INTEGER,
    seller_positive_pct REAL,
    is_auction INTEGER DEFAULT 0,
    extracted_price_usd REAL,
    is_authentic INTEGER NOT NULL,      -- 1 = authentic, 0 = fake/scam/parts/trap
    verdict TEXT NOT NULL,              -- 'AUTHENTIC', 'PARTS_OR_DEFECTIVE', 'ACCESSORY_TRAP', 'SCAM_SUSPECTED', 'AUCTION_NOT_BIN', 'MISLEADING_SPEC', 'UNREACHABLE'
    confidence REAL NOT NULL,           -- 0.0 to 1.0
    red_flags TEXT DEFAULT '[]',        -- JSON array of triggered red flags
    reasoning TEXT NOT NULL,            -- Detailed explanation from verifier
    evaluator_model TEXT NOT NULL,      -- e.g. 'llama.cpp:8080' or 'forensic_rules_engine'
    verified_at INTEGER NOT NULL,
    FOREIGN KEY(deal_alert_id) REFERENCES compute_deal_alerts(id),
    FOREIGN KEY(observation_id) REFERENCES compute_market_observations(id)
);

CREATE INDEX IF NOT EXISTS idx_dv_deal ON deal_verifications(deal_alert_id);
CREATE INDEX IF NOT EXISTS idx_dv_verdict ON deal_verifications(verdict);
CREATE INDEX IF NOT EXISTS idx_dv_authentic ON deal_verifications(is_authentic);
CREATE INDEX IF NOT EXISTS idx_dv_verified ON deal_verifications(verified_at);
"""

# Default Contracts Seed Data
DEFAULT_CONTRACTS = [
    ("compute_listing_seen", "compute_market", "Raw compute hardware listing discovered on secondary marketplace", 90),
    ("compute_deal_alert", "compute_market", "Evaluated GPU or RAM deal exceeding alpha discount threshold", 90),
    ("compute_deal_verified", "compute_market", "Authentic GPU or RAM deal verified by agentic website fetch", 90),
    ("compute_deal_rejected", "compute_market", "Fake, parts-only, or scam deal rejected by forensic verifier", 90),
    ("polymarket_market_shift", "prediction_markets", "Active prediction market odds tick and implied volume", 90),
    ("crypto_price_tick", "crypto", "Live cryptocurrency spot price snapshot from exchange ticker", 60),
    ("finance_crypto_signal", "finance_osint", "Grant, bounty, or ecosystem catalyst targeting developer infrastructure", 90),
    ("finance_opportunity_alert", "finance_osint", "Synthesized high-priority revenue or funding opportunity", 90),
    ("searxng_rss", "rss_intel", "Breaking intelligence headline and URL from SearXNG RSS feed", 60),
    ("radio_call_ingest", "sdr_osint", "TrunkRecorder radio call transcript and frequency telemetry", 90),
    ("system_telemetry", "system", "Core daemon heartbeat, memory, and task bay operational telemetry", 30),
]

# Compute Hardware Seed Taxonomy (High-Alpha Compute Focus)
DEFAULT_HARDWARE = [
    # GPUs (VRAM Density Workhorses)
    ("RTX_3090_24GB", "GPU", "NVIDIA_AMPERE", "GeForce RTX 3090", 24.0, 680.0, 550.0, 220.0),
    ("RTX_4090_24GB", "GPU", "NVIDIA_ADA", "GeForce RTX 4090", 24.0, 1550.0, 1300.0, 500.0),
    ("RTX_A6000_48GB", "GPU", "NVIDIA_AMPERE_WORKSTATION", "RTX A6000", 48.0, 2800.0, 2200.0, 800.0),
    ("A100_80GB_PCIE", "GPU", "NVIDIA_AMPERE_DATACENTER", "NVIDIA A100 PCIe 80GB", 80.0, 11000.0, 8500.0, 2500.0),
    ("A100_40GB_PCIE", "GPU", "NVIDIA_AMPERE_DATACENTER", "NVIDIA A100 PCIe 40GB", 40.0, 4200.0, 3200.0, 1200.0),
    ("RX_7900_XTX_24GB", "GPU", "AMD_RDNA3", "Radeon RX 7900 XTX", 24.0, 780.0, 620.0, 250.0),
    ("RX_5700_XT_8GB", "GPU", "AMD_RDNA1", "Radeon RX 5700 XT", 8.0, 130.0, 100.0, 45.0),
    # Server / Workstation RAM (DDR5 & DDR4 ECC RDIMMs)
    ("DDR5_ECC_RDIMM_64GB", "RAM", "DDR5_SERVER_ECC", "64GB DDR5 ECC Registered RDIMM", 64.0, 185.0, 140.0, 45.0),
    ("DDR5_ECC_RDIMM_128GB", "RAM", "DDR5_SERVER_ECC", "128GB (2x64GB / 1x128GB) DDR5 ECC RDIMM", 128.0, 360.0, 280.0, 90.0),
    ("DDR5_ECC_RDIMM_256GB", "RAM", "DDR5_SERVER_ECC", "256GB (4x64GB / 2x128GB) DDR5 ECC RDIMM", 256.0, 700.0, 540.0, 180.0),
    ("DDR4_ECC_RDIMM_64GB", "RAM", "DDR4_SERVER_ECC", "64GB DDR4-3200 ECC Registered RDIMM", 64.0, 75.0, 55.0, 20.0),
    ("DDR4_ECC_RDIMM_128GB", "RAM", "DDR4_SERVER_ECC", "128GB (2x64GB) DDR4 ECC Registered Kit", 128.0, 140.0, 105.0, 40.0),
]


# ── Initialization & Connection ────────────────────────────────────────

def get_db_path() -> Path:
    env_path = os.getenv("GEORGE_EVENTS_DB")
    if env_path:
        return Path(env_path)
    return _DEFAULT_DB_PATH


def init_db(db_path: Path | None = None) -> sqlite3.Connection:
    target_path = db_path or get_db_path()
    target_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(target_path), timeout=5.0)
    conn.row_factory = sqlite3.Row

    with conn:
        conn.executescript(SCHEMA_SQL)
        now_ts = int(time.time())

        # Seed event contracts
        for c in DEFAULT_CONTRACTS:
            conn.execute(
                """
                INSERT INTO event_contracts (event_type, domain, description, retention_days, schema_json, created_at)
                VALUES (?, ?, ?, ?, '{}', ?)
                ON CONFLICT(event_type) DO UPDATE SET
                    domain=excluded.domain,
                    description=excluded.description,
                    retention_days=excluded.retention_days
                """,
                (c[0], c[1], c[2], c[3], now_ts),
            )

        # Registry contracts (configs/event_contracts.json) are authoritative.
        reg_path = Path(os.getenv("EVENT_CONTRACTS_FILE") or _REPO_ROOT / "configs" / "event_contracts.json")
        try:
            reg = json.loads(reg_path.read_text()).get("contracts", [])
        except (OSError, json.JSONDecodeError):
            reg = []
        for c in reg:
            if not c.get("type") or not c.get("domain"):
                continue
            schema = {k: c[k] for k in ("handling", "required", "reactors", "alias_of") if k in c}
            conn.execute(
                """
                INSERT INTO event_contracts (event_type, domain, description, retention_days, schema_json, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(event_type) DO UPDATE SET
                    domain=excluded.domain,
                    description=excluded.description,
                    retention_days=excluded.retention_days,
                    schema_json=excluded.schema_json
                """,
                (c["type"], c["domain"], c.get("description", ""), int(c.get("retention_days", 90)),
                 json.dumps(schema), now_ts),
            )

        # Seed hardware taxonomy
        for hw in DEFAULT_HARDWARE:
            conn.execute(
                """
                INSERT INTO compute_hardware_specs (id, category, family, model, capacity_gb, target_fmv_usd, deal_ceiling_usd, min_viable_price_usd)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    target_fmv_usd=excluded.target_fmv_usd,
                    deal_ceiling_usd=excluded.deal_ceiling_usd,
                    min_viable_price_usd=excluded.min_viable_price_usd
                """,
                hw,
            )

        # Migrate compute_deal_alerts columns if existing table is missing them
        cursor = conn.cursor()
        cursor.execute("PRAGMA table_info(compute_deal_alerts)")
        existing_cols = {r[1] for r in cursor.fetchall()}
        migration_cols = [
            ("verification_status", "TEXT DEFAULT 'PENDING'"),
            ("verification_verdict", "TEXT DEFAULT NULL"),
            ("verification_reasoning", "TEXT DEFAULT NULL"),
            ("verified_at", "INTEGER DEFAULT NULL"),
        ]
        for col_name, col_type in migration_cols:
            if col_name not in existing_cols:
                try:
                    cursor.execute(f"ALTER TABLE compute_deal_alerts ADD COLUMN {col_name} {col_type}")
                except Exception:
                    pass

        try:
            cursor.execute("CREATE INDEX IF NOT EXISTS idx_cda_verif ON compute_deal_alerts(verification_status)")
        except Exception:
            pass

    return conn


# ── Core Event & Reaction Logging ─────────────────────────────────────

def log_event(
    event_id: str,
    event_type: str,
    source: str,
    payload: dict[str, Any] | str,
    depth: int = 0,
    timestamp: int | None = None,
    conn: sqlite3.Connection | None = None,
) -> bool:
    """Log an incoming event envelope into the global event ledger."""
    should_close = False
    if conn is None:
        conn = init_db()
        should_close = True

    ts = timestamp or int(time.time())
    now_ts = int(time.time())
    payload_str = json.dumps(payload) if isinstance(payload, dict) or isinstance(payload, list) else str(payload)

    try:
        with conn:
            conn.execute(
                """
                INSERT INTO events (event_id, event_type, source, depth, payload, timestamp, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(event_id) DO NOTHING
                """,
                (event_id, event_type, source, depth, payload_str, ts, now_ts),
            )
        return True
    except Exception as e:
        logger.warning(f"Failed to log event '{event_id}': {e}")
        return False
    finally:
        if should_close:
            conn.close()


def log_reaction(
    event_id: str,
    event_type: str,
    reactor_id: str,
    action_cmd: str,
    status: str = "SUCCESS",
    exit_code: int = 0,
    duration_ms: int = 0,
    output_snippet: str = "",
    conn: sqlite3.Connection | None = None,
) -> bool:
    """Log a reactor firing or suppression outcome into reactions table."""
    should_close = False
    if conn is None:
        conn = init_db()
        should_close = True

    now_ts = int(time.time())
    snippet = (output_snippet or "")[:500]

    try:
        with conn:
            conn.execute(
                """
                INSERT INTO reactions (event_id, event_type, reactor_id, action_cmd, status, exit_code, duration_ms, output_snippet, fired_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (event_id, event_type, reactor_id, action_cmd, status, exit_code, duration_ms, snippet, now_ts),
            )
        return True
    except Exception as e:
        logger.warning(f"Failed to log reaction for '{reactor_id}': {e}")
        return False
    finally:
        if should_close:
            conn.close()


# ── Compute Hardware Valuation & Deal Engine ──────────────────────────

def identify_hardware_spec(title: str, snippet: str = "") -> str | None:
    """Match listing text against known GPU & RAM hardware models."""
    text = f"{title} {snippet}".lower()

    # Discard non-compute hardware accessories and boxes
    negative_patterns = [
        r"\b(box only|shroud|cooler only|waterblock|heatsink|bracket|backplate|cable|fan replacement|parts only|for parts|broken|keycap|t-shirt)\b"
    ]
    for np in negative_patterns:
        if re.search(np, text):
            return None

    # 1. RTX 4090
    if "4090" in text and ("rtx" in text or "geforce" in text or "nvidia" in text or "24gb" in text):
        return "RTX_4090_24GB"

    # 2. RTX 3090
    if "3090" in text and ("rtx" in text or "geforce" in text or "nvidia" in text or "24gb" in text):
        return "RTX_3090_24GB"

    # 3. RTX A6000
    if ("a6000" in text or "rtx a6000" in text) and "48gb" in text:
        return "RTX_A6000_48GB"

    # 4. A100 Datacenter
    if "a100" in text:
        if "80gb" in text:
            return "A100_80GB_PCIE"
        elif "40gb" in text:
            return "A100_40GB_PCIE"

    # 5. AMD RX 7900 XTX
    if ("7900 xtx" in text or "7900xtx" in text) and "24gb" in text:
        return "RX_7900_XTX_24GB"

    # 6. AMD RX 5700 XT
    if "5700 xt" in text or "5700xt" in text:
        return "RX_5700_XT_8GB"

    # 7. DDR5 ECC RDIMMs (Server & Workstation)
    if "ddr5" in text and ("ecc" in text or "rdimm" in text or "registered" in text):
        if "256gb" in text or "4x64gb" in text:
            return "DDR5_ECC_RDIMM_256GB"
        elif "128gb" in text or "2x64gb" in text:
            return "DDR5_ECC_RDIMM_128GB"
        elif "64gb" in text:
            return "DDR5_ECC_RDIMM_64GB"

    # 8. DDR4 ECC RDIMMs
    if "ddr4" in text and ("ecc" in text or "rdimm" in text or "registered" in text):
        if "128gb" in text or "2x64gb" in text:
            return "DDR4_ECC_RDIMM_128GB"
        elif "64gb" in text:
            return "DDR4_ECC_RDIMM_64GB"

    return None


def evaluate_compute_listing(
    title: str,
    price_usd: float,
    url: str,
    source: str = "ebay",
    shipping_usd: float = 0.0,
    snippet: str = "",
    event_id: str | None = None,
    conn: sqlite3.Connection | None = None,
) -> dict[str, Any] | None:
    """Evaluate a raw hardware listing against FMV baselines and historical moving medians."""
    hw_id = identify_hardware_spec(title, snippet)
    if not hw_id:
        return None

    source = source or "ebay"

    should_close = False
    if conn is None:
        conn = init_db()
        should_close = True

    now_ts = int(time.time())
    total_price = round(price_usd + shipping_usd, 2)
    clean_url = url.split("#")[0].split("?")[0].rstrip("/")
    url_hash = hashlib.sha256(clean_url.encode("utf-8")).hexdigest()

    try:
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM compute_hardware_specs WHERE id = ?", (hw_id,))
        spec = cursor.fetchone()
        if not spec:
            return None

        # Price floor filter (discards accessory listings)
        if total_price < spec["min_viable_price_usd"]:
            return None

        # URL dedup: skip if same listing already observed within 24h with same price
        cursor.execute(
            """SELECT total_price_usd FROM compute_market_observations
               WHERE clean_url_hash = ? AND observed_at >= ?
               ORDER BY observed_at DESC LIMIT 1""",
            (url_hash, now_ts - 86400),
        )
        recent = cursor.fetchone()
        if recent and abs(recent["total_price_usd"] - total_price) < 0.01:
            return None  # identical duplicate within 24h - skip

        # Unit economics ($/GB VRAM or $/GB RAM)
        unit_cost = round(total_price / spec["capacity_gb"], 2)

        # Record timeseries observation
        with conn:
            cursor.execute(
                """
                INSERT INTO compute_market_observations (
                    event_id, observed_at, source, hardware_id, raw_title, url, clean_url_hash,
                    price_usd, shipping_usd, total_price_usd, unit_cost, condition
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'USED')
                """,
                (event_id, now_ts, source, hw_id, title, clean_url, url_hash, price_usd, shipping_usd, total_price, unit_cost),
            )
            obs_id = cursor.lastrowid

        # Calculate trailing 14-day median from historical observations (excluding current listing)
        fourteen_days_ago = now_ts - (14 * 86400)
        cursor.execute(
            """
            SELECT total_price_usd FROM compute_market_observations
            WHERE hardware_id = ? AND observed_at >= ? AND id != ?
            ORDER BY total_price_usd ASC
            """,
            (hw_id, fourteen_days_ago, obs_id),
        )
        historical_prices = [r["total_price_usd"] for r in cursor.fetchall()]

        if len(historical_prices) >= 3:
            mid = len(historical_prices) // 2
            rolling_median = (historical_prices[mid] if len(historical_prices) % 2 != 0
                              else (historical_prices[mid - 1] + historical_prices[mid]) / 2.0)
            benchmark_fmv = round(min(rolling_median, spec["target_fmv_usd"]), 2)
        else:
            rolling_median = spec["target_fmv_usd"]
            benchmark_fmv = round(spec["target_fmv_usd"], 2)

        # Calculate discount percentage against benchmark FMV
        discount_pct = round(((benchmark_fmv - total_price) / benchmark_fmv) * 100.0, 1)

        # Classify deal grade
        if discount_pct >= 30.0 or total_price <= spec["deal_ceiling_usd"] * 0.85:
            deal_grade = "STEAL"
        elif discount_pct >= 20.0 or total_price <= spec["deal_ceiling_usd"]:
            deal_grade = "DEAL"
        elif discount_pct >= -10.0:
            deal_grade = "FAIR"
        else:
            deal_grade = "OVERPRICED"

        # Record alert if genuine deal
        alert_id = None
        if deal_grade in ("STEAL", "DEAL"):
            with conn:
                cursor.execute(
                    """
                    INSERT INTO compute_deal_alerts (
                        observation_id, hardware_id, created_at, total_price_usd, benchmark_fmv_usd,
                        rolling_median_14d, discount_pct, deal_grade, alerted_discord, status
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 'ACTIVE')
                    """,
                    (obs_id, hw_id, now_ts, total_price, benchmark_fmv, rolling_median, discount_pct, deal_grade),
                )
                alert_id = cursor.lastrowid

        return {
            "observation_id": obs_id,
            "alert_id": alert_id,
            "hardware_id": hw_id,
            "model": spec["model"],
            "category": spec["category"],
            "capacity_gb": spec["capacity_gb"],
            "total_price_usd": total_price,
            "unit_cost": unit_cost,
            "benchmark_fmv": benchmark_fmv,
            "rolling_median_14d": rolling_median,
            "discount_pct": discount_pct,
            "deal_grade": deal_grade,
            "is_deal": deal_grade in ("STEAL", "DEAL"),
            "url": clean_url,
            "title": title,
        }
    except Exception as e:
        logger.warning(f"Error evaluating listing '{title}': {e}")
        return None
    finally:
        if should_close:
            conn.close()


# ── Queries & Observability API ────────────────────────────────────────

def query_events(
    event_type: str | None = None,
    source: str | None = None,
    limit: int = 25,
    conn: sqlite3.Connection | None = None,
) -> list[dict[str, Any]]:
    """Query recent events from the global event ledger."""
    should_close = False
    if conn is None:
        conn = init_db()
        should_close = True

    try:
        cursor = conn.cursor()
        query = "SELECT * FROM events WHERE 1=1"
        params: list[Any] = []
        if event_type:
            query += " AND event_type = ?"
            params.append(event_type)
        if source:
            query += " AND source = ?"
            params.append(source)
        query += " ORDER BY id DESC LIMIT ?"
        params.append(limit)

        cursor.execute(query, params)
        rows = [dict(r) for r in cursor.fetchall()]
        for r in rows:
            try:
                r["payload"] = json.loads(r["payload"])
            except Exception:
                pass
        return rows
    finally:
        if should_close:
            conn.close()


def search_events_fts(query_str: str, limit: int = 20, conn: sqlite3.Connection | None = None) -> list[dict[str, Any]]:
    """Full-text search across historical event payloads via SQLite FTS5."""
    should_close = False
    if conn is None:
        conn = init_db()
        should_close = True

    try:
        cursor = conn.cursor()
        # Clean query string for FTS5 syntax
        clean_q = re.sub(r"[^\w\s\*\-]", " ", query_str).strip()
        if not clean_q:
            return []

        cursor.execute(
            """
            SELECT e.* FROM events_fts f
            JOIN events e ON f.rowid = e.id
            WHERE events_fts MATCH ?
            ORDER BY bm25(events_fts)
            LIMIT ?
            """,
            (clean_q, limit),
        )
        rows = [dict(r) for r in cursor.fetchall()]
        for r in rows:
            try:
                r["payload"] = json.loads(r["payload"])
            except Exception:
                pass
        return rows
    finally:
        if should_close:
            conn.close()


def query_active_deals(
    category: str | None = None,
    grade: str | None = None,
    limit: int = 15,
    conn: sqlite3.Connection | None = None,
) -> list[dict[str, Any]]:
    """Query top-ranked active compute hardware deals from SQLite."""
    should_close = False
    if conn is None:
        conn = init_db()
        should_close = True

    try:
        cursor = conn.cursor()
        query = """
            SELECT d.*, h.category, h.model, h.capacity_gb, o.raw_title, o.url, o.source, o.unit_cost
            FROM compute_deal_alerts d
            JOIN compute_hardware_specs h ON d.hardware_id = h.id
            JOIN compute_market_observations o ON d.observation_id = o.id
            WHERE d.status = 'ACTIVE' AND (d.verification_status IS NULL OR d.verification_status != 'REJECTED')
        """
        params: list[Any] = []
        if category:
            query += " AND h.category = ?"
            params.append(category.upper())
        if grade:
            query += " AND d.deal_grade = ?"
            params.append(grade.upper())
        query += " ORDER BY d.discount_pct DESC LIMIT ?"
        params.append(limit)

        cursor.execute(query, params)
        return [dict(r) for r in cursor.fetchall()]
    finally:
        if should_close:
            conn.close()


def record_deal_verification(
    deal_alert_id: int | None,
    observation_id: int | None,
    hardware_id: str,
    url: str,
    is_authentic: bool,
    verdict: str,
    confidence: float,
    reasoning: str,
    http_status: int = 200,
    fetched_title: str = "",
    condition: str = "",
    seller_feedback_count: int = 0,
    seller_positive_pct: float = 0.0,
    is_auction: bool = False,
    extracted_price_usd: float | None = None,
    red_flags: list[str] | None = None,
    evaluator_model: str = "deal_verifier",
    conn: sqlite3.Connection | None = None,
) -> int:
    """Record verification result and update compute_deal_alerts status."""
    should_close = False
    if conn is None:
        conn = init_db()
        should_close = True

    now_ts = int(time.time())
    flags_json = json.dumps(red_flags or [])

    try:
        with conn:
            cursor = conn.cursor()
            cursor.execute(
                """
                INSERT INTO deal_verifications (
                    deal_alert_id, observation_id, hardware_id, url, http_status, fetched_title,
                    condition, seller_feedback_count, seller_positive_pct, is_auction,
                    extracted_price_usd, is_authentic, verdict, confidence, red_flags,
                    reasoning, evaluator_model, verified_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    deal_alert_id, observation_id, hardware_id, url, http_status, fetched_title,
                    condition, seller_feedback_count, seller_positive_pct, 1 if is_auction else 0,
                    extracted_price_usd, 1 if is_authentic else 0, verdict, confidence, flags_json,
                    reasoning, evaluator_model, now_ts
                ),
            )
            verif_id = cursor.lastrowid

            if deal_alert_id:
                new_status = "ACTIVE" if is_authentic else "DISMISSED"
                v_status = "VERIFIED" if is_authentic else "REJECTED"
                cursor.execute(
                    """
                    UPDATE compute_deal_alerts
                    SET status = ?, verification_status = ?, verification_verdict = ?, verification_reasoning = ?, verified_at = ?
                    WHERE id = ?
                    """,
                    (new_status, v_status, verdict, reasoning, now_ts, deal_alert_id),
                )
        return verif_id or 0
    finally:
        if should_close:
            conn.close()


def query_verifications(limit: int = 20, conn: sqlite3.Connection | None = None) -> list[dict[str, Any]]:
    """Query recent forensic deal verification audit entries."""
    should_close = False
    if conn is None:
        conn = init_db()
        should_close = True
    try:
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT v.*, h.model, h.category
            FROM deal_verifications v
            LEFT JOIN compute_hardware_specs h ON v.hardware_id = h.id
            ORDER BY v.verified_at DESC
            LIMIT ?
            """,
            (limit,)
        )
        rows = [dict(r) for r in cursor.fetchall()]
        for r in rows:
            try:
                r["red_flags"] = json.loads(r.get("red_flags") or "[]")
            except Exception:
                r["red_flags"] = []
        return rows
    finally:
        if should_close:
            conn.close()


def query_hardware_stats(hardware_id: str | None = None, conn: sqlite3.Connection | None = None) -> list[dict[str, Any]]:
    """Compute moving stats and price distribution per hardware model."""
    should_close = False
    if conn is None:
        conn = init_db()
        should_close = True

    try:
        cursor = conn.cursor()
        query = """
            SELECT
                h.id, h.category, h.model, h.capacity_gb, h.target_fmv_usd, h.deal_ceiling_usd,
                COUNT(o.id) as observation_count,
                MIN(o.total_price_usd) as min_price_usd,
                AVG(o.total_price_usd) as avg_price_usd,
                MAX(o.total_price_usd) as max_price_usd
            FROM compute_hardware_specs h
            LEFT JOIN compute_market_observations o ON h.id = o.hardware_id
            WHERE 1=1
        """
        params: list[Any] = []
        if hardware_id:
            query += " AND h.id = ?"
            params.append(hardware_id)
        query += " GROUP BY h.id ORDER BY h.category, h.id"

        cursor.execute(query, params)
        return [dict(r) for r in cursor.fetchall()]
    finally:
        if should_close:
            conn.close()


# ── Rolling Expiration & Database Compaction ──────────────────────────

def prune_expired_records(retention_days: int = 90, conn: sqlite3.Connection | None = None) -> dict[str, int]:
    """Prune event and telemetry records older than retention threshold and compact."""
    should_close = False
    if conn is None:
        conn = init_db()
        should_close = True

    cutoff_ts = int(time.time()) - (retention_days * 86400)
    stats = {}

    try:
        cursor = conn.cursor()
        with conn:
            # 1. Prune events older than retention cutoff
            cursor.execute("DELETE FROM events WHERE created_at < ?", (cutoff_ts,))
            stats["events_pruned"] = cursor.rowcount

            # 2. Prune reactions telemetry
            cursor.execute("DELETE FROM reactions WHERE fired_at < ?", (cutoff_ts,))
            stats["reactions_pruned"] = cursor.rowcount

            # 3. Prune historical observations (keep deal alerts flagged active)
            cursor.execute(
                """
                DELETE FROM compute_market_observations
                WHERE observed_at < ?
                  AND id NOT IN (SELECT observation_id FROM compute_deal_alerts WHERE status = 'ACTIVE')
                """,
                (cutoff_ts,),
            )
            stats["observations_pruned"] = cursor.rowcount

            # 4. Mark stale deal alerts as EXPIRED (older than 30 days)
            deals_cutoff = int(time.time()) - (30 * 86400)
            cursor.execute("UPDATE compute_deal_alerts SET status = 'EXPIRED' WHERE created_at < ? AND status = 'ACTIVE'", (deals_cutoff,))
            stats["deals_expired"] = cursor.rowcount

        # Compact database free pages
        cursor.execute("PRAGMA incremental_vacuum;")
        return stats
    finally:
        if should_close:
            conn.close()


def compact_database(conn: sqlite3.Connection | None = None) -> dict[str, Any]:
    """Execute VACUUM and WAL checkpoint to compact SQLite pages."""
    target_path = get_db_path()
    size_before = target_path.stat().st_size if target_path.exists() else 0

    should_close = False
    if conn is None:
        conn = init_db()
        should_close = True

    try:
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        conn.execute("VACUUM;")
        size_after = target_path.stat().st_size if target_path.exists() else 0
        return {
            "status": "ok",
            "bytes_before": size_before,
            "bytes_after": size_after,
            "bytes_freed": max(0, size_before - size_after),
        }
    finally:
        if should_close:
            conn.close()


def get_store_summary(conn: sqlite3.Connection | None = None) -> dict[str, Any]:
    """Retrieve aggregate counts, DB file size, and telemetry stats."""
    target_path = get_db_path()
    size_bytes = target_path.stat().st_size if target_path.exists() else 0

    should_close = False
    if conn is None:
        conn = init_db()
        should_close = True

    try:
        cursor = conn.cursor()
        cursor.execute("SELECT COUNT(*) FROM events")
        total_events = cursor.fetchone()[0]

        cursor.execute("SELECT COUNT(*) FROM reactions")
        total_reactions = cursor.fetchone()[0]

        cursor.execute("SELECT COUNT(*) FROM compute_market_observations")
        total_observations = cursor.fetchone()[0]

        cursor.execute("SELECT COUNT(*) FROM compute_deal_alerts WHERE status = 'ACTIVE'")
        active_deals = cursor.fetchone()[0]

        cursor.execute("SELECT COUNT(*) FROM compute_deal_alerts WHERE deal_grade = 'STEAL' AND status = 'ACTIVE'")
        steals = cursor.fetchone()[0]

        return {
            "db_path": str(target_path),
            "size_bytes": size_bytes,
            "size_mb": round(size_bytes / (1024 * 1024), 2),
            "total_events": total_events,
            "total_reactions": total_reactions,
            "total_compute_observations": total_observations,
            "active_compute_deals": active_deals,
            "active_steals": steals,
        }
    finally:
        if should_close:
            conn.close()


# ── CLI Interface ──────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="Sovereign Event Store & Compute Deal Engine")
    parser.add_argument("--db-path", "--db", type=str, default=None, help="Custom database path")
    parser.add_argument("--init", action="store_true", help="Initialize SQLite tables, contracts, and taxonomy")
    parser.add_argument("--stats", action="store_true", help="Display summary stats, DB size, and event counts")
    parser.add_argument("--log-event", action="store_true", help="Log an event envelope into events table")
    parser.add_argument("--event-id", type=str, help="Unique event identifier")
    parser.add_argument("--event-type", type=str, help="Event contract type")
    parser.add_argument("--source", type=str, default=None, help="Originating subsystem or watcher")
    parser.add_argument("--payload", type=str, default="{}", help="JSON payload")
    parser.add_argument("--depth", type=int, default=0, help="Recursion depth")
    parser.add_argument("--log-reaction", action="store_true", help="Log a reaction firing outcome")
    parser.add_argument("--reactor-id", type=str, help="Reactor identifier")
    parser.add_argument("--action-cmd", type=str, default="", help="Command executed")
    parser.add_argument("--status", type=str, default="SUCCESS", help="Outcome status")
    parser.add_argument("--duration", "--duration-ms", dest="duration", type=float, default=0.0, help="Duration in milliseconds")
    parser.add_argument("--exit-code", type=int, default=0, help="Process exit code")
    parser.add_argument("--eval-compute", action="store_true", help="Evaluate a raw compute listing for alpha deal")
    parser.add_argument("--title", type=str, help="Listing title")
    parser.add_argument("--price", type=float, help="Listing price in USD")
    parser.add_argument("--url", type=str, default="https://example.com", help="Listing URL")
    parser.add_argument("--query-events", action="store_true", help="List recent events")
    parser.add_argument("--search", type=str, help="FTS5 search across historical event payloads")
    parser.add_argument("--limit", type=int, default=25, help="Maximum number of records to return (default 25)")
    parser.add_argument("--deals", action="store_true", help="Display active compute hardware deals")
    parser.add_argument("--category", choices=["GPU", "RAM"], help="Filter by GPU or RAM")
    parser.add_argument("--steals", action="store_true", help="Filter deals for STEAL grade (>=30%% off)")
    parser.add_argument("--hardware-stats", action="store_true", help="Show pricing distribution per hardware model")
    parser.add_argument("--prune", action="store_true", help="Prune records older than retention threshold")
    parser.add_argument("--retention-days", type=int, default=90, help="Retention period in days (default 90)")
    parser.add_argument("--verifications", action="store_true", help="Display recent deal verification audit entries")
    parser.add_argument("--compact", action="store_true", help="Execute VACUUM & WAL checkpoint")
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")

    args = parser.parse_args()

    if args.db_path:
        os.environ["GEORGE_EVENTS_DB"] = str(Path(args.db_path).resolve())

    if args.init:
        init_db()
        print("[OK] Sovereign Event Store & Hardware Taxonomy initialized.")
        sys.exit(0)

    if args.stats:
        summary = get_store_summary()
        if args.json:
            print(json.dumps(summary, indent=2))
        else:
            print("=" * 72)
            print("  SOVEREIGN EVENT STORE & COMPUTE TELEMETRY DATABASE")
            print("=" * 72)
            print(f"  Database Path:      {summary['db_path']}")
            print(f"  Size on Disk:       {summary['size_mb']} MB ({summary['size_bytes']:,} bytes)")
            print(f"  Total Events:       {summary['total_events']:,}")
            print(f"  Total Reactions:    {summary['total_reactions']:,}")
            print(f"  Market Ticks (HW):  {summary['total_compute_observations']:,}")
            print(f"  Active Deals:       {summary['active_compute_deals']:,} (Steals: {summary['active_steals']})")
            print("=" * 72)
        sys.exit(0)

    if args.log_event:
        if not args.event_id or not args.event_type:
            print("[ERROR] --event-id and --event-type are required for --log-event", file=sys.stderr)
            sys.exit(1)
        ok = log_event(args.event_id, args.event_type, args.source, args.payload, args.depth)
        print(f"[OK] Event logged: {ok}")
        sys.exit(0 if ok else 1)

    if args.log_reaction:
        if not args.event_id or not args.reactor_id:
            print("[ERROR] --event-id and --reactor-id are required for --log-reaction", file=sys.stderr)
            sys.exit(1)
        ok = log_reaction(args.event_id, args.event_type or "unknown", args.reactor_id, args.action_cmd, args.status, exit_code=args.exit_code, duration_ms=args.duration)
        print(f"[OK] Reaction logged: {ok}")
        sys.exit(0 if ok else 1)

    if args.eval_compute:
        if not args.title or args.price is None:
            print("[ERROR] --title and --price are required for --eval-compute", file=sys.stderr)
            sys.exit(1)
        res = evaluate_compute_listing(args.title, args.price, args.url, source=args.source)
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            if not res:
                print("[SKIP] Listing does not match known compute hardware specifications.")
            else:
                grade_flag = f"[{res['deal_grade']}]" if res["is_deal"] else f"({res['deal_grade']})"
                print(f"{grade_flag} {res['model']} ({res['capacity_gb']}GB)")
                print(f"  Price: ${res['total_price_usd']:.2f}  |  Unit Cost: ${res['unit_cost']:.2f}/GB")
                print(f"  Benchmark FMV: ${res['benchmark_fmv']:.2f}  |  Discount: {res['discount_pct']:+.1f}%")
                print(f"  URL: {res['url']}")
        sys.exit(0)

    if args.deals:
        grade = "STEAL" if args.steals else None
        deals = query_active_deals(category=args.category, grade=grade)
        if args.json:
            print(json.dumps(deals, indent=2))
        else:
            print("=" * 76)
            print(f"  ACTIVE COMPUTE ALPHA & HARDWARE DEALS ({len(deals)} opportunities)")
            print("=" * 76)
            if not deals:
                print("  No active deals currently match the criteria.")
            for d in deals:
                v_badge = f"[{d.get('verification_status') or 'UNVERIFIED'}]"
                print(f"  [{d['deal_grade']}: {d['discount_pct']:+.1f}%] {v_badge} {d['model']} ({d['capacity_gb']:.0f}GB)")
                print(f"      Price: ${d['total_price_usd']:.2f} (${d['unit_cost']:.2f}/GB)  |  FMV: ${d['benchmark_fmv_usd']:.2f}  |  Source: {d['source']}")
                print(f"      Title: {d['raw_title'][:70]}")
                print(f"      Link:  {d['url']}")
                if d.get("verification_reasoning"):
                    print(f"      Audit: {d['verification_reasoning'][:80]}")
                print()
            print("=" * 76)
        sys.exit(0)

    if args.verifications:
        verifs = query_verifications(limit=args.limit)
        if args.json:
            print(json.dumps(verifs, indent=2))
        else:
            print("=" * 80)
            print(f"  FORENSIC DEAL VERIFICATIONS AUDIT LOG ({len(verifs)} entries)")
            print("=" * 80)
            if not verifs:
                print("  No verification records found.")
            for v in verifs:
                status_icon = "[VERIFIED AUTHENTIC]" if v["is_authentic"] else f"[REJECTED: {v['verdict']}]"
                print(f"  {status_icon} {v.get('model', 'Hardware')}")
                print(f"      URL:       {v['url']}")
                print(f"      Reasoning: {v['reasoning']}")
                print(f"      Evaluator: {v['evaluator_model']} (Confidence: {v['confidence']*100:.0f}%)")
                print()
            print("=" * 80)
        sys.exit(0)

    if args.hardware_stats:
        stats = query_hardware_stats()
        if args.json:
            print(json.dumps(stats, indent=2))
        else:
            print("=" * 76)
            print("  COMPUTE HARDWARE BENCHMARK & TIMESERIES PRICE METRICS")
            print("=" * 76)
            print(f"  {'Model':<30} {'Cat':<5} {'FMV ($)':<9} {'Ceiling':<9} {'Obs':<6} {'Min ($)':<8} {'Avg ($)':<8}")
            print("  " + "-" * 74)
            for s in stats:
                obs = s['observation_count'] or 0
                min_p = f"${s['min_price_usd']:.0f}" if s['min_price_usd'] else "--"
                avg_p = f"${s['avg_price_usd']:.0f}" if s['avg_price_usd'] else "--"
                print(f"  {s['model']:<30} {s['category']:<5} ${s['target_fmv_usd']:<8.0f} ${s['deal_ceiling_usd']:<8.0f} {obs:<6} {min_p:<8} {avg_p:<8}")
            print("=" * 76)
        sys.exit(0)

    if args.search:
        results = search_events_fts(args.search, limit=args.limit)
        if args.json:
            print(json.dumps(results, indent=2))
        else:
            print(f"Found {len(results)} events matching '{args.search}':")
            for r in results:
                print(f"  [{r['event_type']}] ID: {r['event_id']} (Source: {r['source']})")
                print(f"      Payload: {r['payload']}")
        sys.exit(0)

    if args.query_events:
        results = query_events(args.event_type, args.source, limit=args.limit)
        if args.json:
            print(json.dumps(results, indent=2))
        else:
            print(f"Showing last {len(results)} events:")
            for r in results:
                print(f"  [{r['event_type']}] ID: {r['event_id']} (Source: {r['source']})")
        sys.exit(0)

    if args.prune:
        pstats = prune_expired_records(args.retention_days)
        print(f"[OK] Pruned records older than {args.retention_days} days: {pstats}")
        sys.exit(0)

    if args.compact:
        cstats = compact_database()
        print(f"[OK] Database compacted: {cstats['bytes_freed']} bytes freed.")
        sys.exit(0)

    parser.print_help()


if __name__ == "__main__":
    main()
