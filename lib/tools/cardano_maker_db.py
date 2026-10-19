#!/usr/bin/env python3
"""
Sovereign Cardano Maker Database & Disaster Recovery Engine (Path D)
Manages the persistent lifecycle of resting limit orders, realized cost basis,
and on-chain reconciliation via Blockfrost and DEX Order Scripts.
"""

import os
import sys
import json
import time
import sqlite3
import logging
import urllib.request
from pathlib import Path
from typing import Optional, Any, Dict, List

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path.home() / "blue-lodge"))
GEORGE_DIR = Path(os.environ.get("GEORGE_DIR", LODGE_DIR / ".george"))
FINANCE_DIR = Path(os.environ.get("FINANCE_DIR", GEORGE_DIR / "finance"))
MAKER_DB_PATH = Path(os.environ.get("MAKER_DB_PATH", FINANCE_DIR / "maker_orders.db"))
SIM_MAKER_DB_PATH = Path(os.environ.get("SIM_MAKER_DB_PATH", FINANCE_DIR / "sim_maker_orders.db"))

def is_simulated_ref(ref: Optional[str]) -> bool:
    """Helper to detect simulated order IDs or transaction IDs."""
    if not ref:
        return False
    s = str(ref).strip().lower()
    return s.startswith("sim_") or s.startswith("mock_")

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", stream=sys.stderr)
logger = logging.getLogger("cardano_maker_db")

from lib.tools.cardano_trader import query_wallet_balance, normalize_blockfrost_base_url
from lib.tools.cardano_dex_swapper import load_env_vars, MINSWAP_AGGREGATOR_BASE, TOKEN_METADATA

SCHEMA_SQL = """
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA busy_timeout = 5000;

CREATE TABLE IF NOT EXISTS maker_orders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id TEXT UNIQUE NOT NULL,
    tx_id TEXT,
    asset TEXT NOT NULL,
    direction TEXT NOT NULL,                 -- 'BUY' or 'SELL'
    status TEXT NOT NULL,                    -- 'PENDING_BUY', 'INVENTORY_HOLD', 'PENDING_SELL', 'COMPLETED', 'CANCELLED'
    capital_ada REAL NOT NULL,
    target_price_ada REAL NOT NULL,
    tokens_target REAL NOT NULL,
    tokens_filled REAL DEFAULT 0.0,
    cost_basis_ada REAL DEFAULT 0.0,
    cost_basis_per_token REAL DEFAULT 0.0,
    batcher_fee_ada REAL DEFAULT 1.80,
    l1_tx_fee_ada REAL DEFAULT 0.18,
    onchain_locked_ada REAL DEFAULT 0.0,
    breakeven_price_ada REAL DEFAULT 0.0,
    order_script_addr TEXT,
    sell_tx_id TEXT,
    sell_target_ada REAL DEFAULT 0.0,
    realized_profit_ada REAL DEFAULT 0.0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    metadata_json TEXT DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_maker_orders_status ON maker_orders(status);
CREATE INDEX IF NOT EXISTS idx_maker_orders_asset ON maker_orders(asset);
CREATE INDEX IF NOT EXISTS idx_maker_orders_tx ON maker_orders(tx_id);

CREATE TABLE IF NOT EXISTS stop_triggers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    trigger_id TEXT UNIQUE NOT NULL,
    asset TEXT NOT NULL,
    trigger_type TEXT NOT NULL,          -- 'STOP_BUY', 'STOP_LOSS', 'OCO_BRACKET'
    trigger_price_ada REAL NOT NULL,
    invalidation_price_ada REAL,         -- threshold to disarm if breached
    gate_ada_24h_min REAL DEFAULT 0.0,   -- minimum ADA 24h change required to fire
    capital_ada REAL NOT NULL,           -- size in ADA
    slippage_cap_pct REAL DEFAULT 1.5,   -- max allowable taker slippage
    tp_target_pct REAL DEFAULT 4.0,      -- OCO take-profit target %
    sl_target_pct REAL DEFAULT 2.5,      -- OCO stop-loss target %
    status TEXT NOT NULL,                -- 'ARMED', 'TRIGGERED', 'DISARMED', 'CANCELLED', 'EXECUTED'
    linked_order_id TEXT,                -- links to maker_orders
    dry_run_sim_json TEXT DEFAULT '{}',  -- simulation receipt
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    metadata_json TEXT DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_stop_triggers_status ON stop_triggers(status);
CREATE INDEX IF NOT EXISTS idx_stop_triggers_asset ON stop_triggers(asset);
"""

class OrderCollisionError(Exception):
    """Raised when an order placement collides with an existing active order at the same level."""
    pass


def check_ladder_collision(
    asset: str,
    target_price_ada: float,
    threshold_pct: float = 1.0,
    direction: str = "BUY",
    is_simulated: bool = False,
) -> Dict[str, Any]:
    """Checks if an active order already exists within threshold_pct of target_price_ada."""
    init_db(is_simulated=is_simulated)
    asset = asset.upper()
    direction = direction.upper()
    with get_db_connection(is_simulated=is_simulated) as conn:
        rows = conn.execute(
            """
            SELECT order_id, tx_id, asset, direction, status, capital_ada,
                   target_price_ada, tokens_target, onchain_locked_ada, breakeven_price_ada
            FROM maker_orders
            WHERE asset = ? AND direction = ? AND status IN ('PENDING_BUY', 'PENDING_SELL')
            """,
            (asset, direction),
        ).fetchall()
        for r in rows:
            active_px = float(r["target_price_ada"])
            if active_px <= 0:
                continue
            diff_pct = abs(target_price_ada - active_px) / active_px * 100.0
            if diff_pct < threshold_pct:
                locked_ada = float(r["onchain_locked_ada"] or (r["capital_ada"] + 4.0))
                return {
                    "collision": True,
                    "conflicting_order_id": r["order_id"],
                    "conflicting_tx": r["tx_id"] or "",
                    "conflicting_price_ada": active_px,
                    "target_price_ada": target_price_ada,
                    "diff_pct": round(diff_pct, 3),
                    "onchain_locked_ada": locked_ada,
                    "message": (
                        f"Collision detected: active order {r['order_id']} ({r['direction']} {asset}) "
                        f"at {active_px:.7f} ADA is within {diff_pct:.2f}% of target {target_price_ada:.7f} ADA "
                        f"(threshold: {threshold_pct:.1f}%). Reclaim conflicting order first or pass allow_collision=True."
                    ),
                }
    return {"collision": False}


def init_db(is_simulated: bool = False) -> None:
    FINANCE_DIR.mkdir(parents=True, exist_ok=True)
    db_path = SIM_MAKER_DB_PATH if is_simulated else MAKER_DB_PATH
    db_path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(str(db_path), timeout=10.0) as conn:
        conn.executescript(SCHEMA_SQL)
        # Dynamic schema migration for dual-metric accounting
        cols = [r[1] for r in conn.execute("PRAGMA table_info(maker_orders)").fetchall()]
        if "onchain_locked_ada" not in cols:
            conn.execute("ALTER TABLE maker_orders ADD COLUMN onchain_locked_ada REAL DEFAULT 0.0")
        if "breakeven_price_ada" not in cols:
            conn.execute("ALTER TABLE maker_orders ADD COLUMN breakeven_price_ada REAL DEFAULT 0.0")
        # Backfill any existing rows
        conn.execute("""
            UPDATE maker_orders
            SET onchain_locked_ada = CASE
                WHEN UPPER(direction) = 'SELL' THEN round(2.0 + COALESCE(batcher_fee_ada, 2.0), 4)
                ELSE round(capital_ada + 2.0 + COALESCE(batcher_fee_ada, 2.0), 4)
            END
            WHERE onchain_locked_ada IS NULL OR onchain_locked_ada = 0.0
               OR (UPPER(direction) = 'SELL' AND onchain_locked_ada > 10.0)
        """)
        conn.execute("""
            UPDATE maker_orders
            SET sell_tx_id = COALESCE(sell_tx_id, tx_id),
                sell_target_ada = CASE WHEN sell_target_ada IS NULL OR sell_target_ada = 0.0 THEN capital_ada ELSE sell_target_ada END,
                tokens_filled = CASE WHEN tokens_filled IS NULL OR tokens_filled = 0.0 THEN tokens_target ELSE tokens_filled END
            WHERE UPPER(direction) = 'SELL'
              AND (sell_tx_id IS NULL OR sell_target_ada = 0.0 OR tokens_filled = 0.0)
        """)
        conn.execute("""
            UPDATE maker_orders
            SET breakeven_price_ada = CASE
                WHEN tokens_target > 0 THEN round((capital_ada + COALESCE(batcher_fee_ada, 2.0) + COALESCE(l1_tx_fee_ada, 0.18)) / tokens_target, 7)
                ELSE target_price_ada
            END
            WHERE breakeven_price_ada IS NULL OR breakeven_price_ada = 0.0
        """)

        # Deploy Unified Orders View (UCOM Tier 2 / 3 View Layer)
        conn.execute("DROP VIEW IF EXISTS v_unified_orders")
        conn.execute("""
            CREATE VIEW v_unified_orders AS
            SELECT 
                'maker_' || id AS uid,
                id AS internal_id,
                order_id AS ref_id,
                asset,
                direction AS order_kind,
                target_price_ada AS trigger_price,
                target_price_ada AS limit_price,
                capital_ada,
                COALESCE(tokens_filled, tokens_target, 0.0) AS tokens,
                status,
                json_extract(metadata_json, '$.linked_to_active_order') AS parent_ladder_id,
                cost_basis_ada,
                cost_basis_per_token,
                'maker_orders' AS source_table,
                created_at,
                updated_at,
                metadata_json
            FROM maker_orders
            UNION ALL
            SELECT
                'stop_' || id AS uid,
                id AS internal_id,
                trigger_id AS ref_id,
                asset,
                trigger_type AS order_kind,
                trigger_price_ada AS trigger_price,
                invalidation_price_ada AS limit_price,
                capital_ada,
                0.0 AS tokens,
                status,
                linked_order_id AS parent_ladder_id,
                0.0 AS cost_basis_ada,
                0.0 AS cost_basis_per_token,
                'stop_triggers' AS source_table,
                created_at,
                updated_at,
                metadata_json
            FROM stop_triggers
        """)
        conn.commit()

def init_sim_db() -> None:
    init_db(is_simulated=True)

def get_unified_orders(
    status: Optional[str] = None,
    asset: Optional[str] = None,
    limit: int = 100,
    is_simulated: bool = False,
) -> List[Dict[str, Any]]:
    """Queries the polymorphic v_unified_orders view across maker_orders and stop_triggers."""
    init_db(is_simulated=is_simulated)
    query = "SELECT * FROM v_unified_orders WHERE 1=1"
    params: List[Any] = []
    if status:
        query += " AND status = ?"
        params.append(status.upper())
    if asset:
        query += " AND asset = ?"
        params.append(asset.upper())
    query += " ORDER BY created_at DESC LIMIT ?"
    params.append(limit)

    with get_db_connection(is_simulated=is_simulated) as conn:
        rows = conn.execute(query, tuple(params)).fetchall()
        return [dict(r) for r in rows]

def get_db_connection(is_simulated: bool = False) -> sqlite3.Connection:
    FINANCE_DIR.mkdir(parents=True, exist_ok=True)
    db_path = SIM_MAKER_DB_PATH if is_simulated else MAKER_DB_PATH
    db_path.parent.mkdir(parents=True, exist_ok=True)
    if not db_path.exists() or db_path.stat().st_size == 0:
        init_db(is_simulated=is_simulated)
    conn = sqlite3.connect(str(db_path), timeout=10.0)
    conn.row_factory = sqlite3.Row
    return conn

def get_sim_db_connection() -> sqlite3.Connection:
    return get_db_connection(is_simulated=True)

def record_new_order(
    asset: str,
    direction: str,
    capital_ada: float,
    target_price_ada: float,
    tokens_target: float,
    tx_id: Optional[str] = None,
    order_script_addr: Optional[str] = None,
    l1_fee_ada: float = 0.18,
    batcher_fee_ada: float = 1.80,
    metadata: Optional[Dict[str, Any]] = None,
    is_simulated: Optional[bool] = None,
    allow_collision: bool = False,
) -> str:
    sim = False
    if is_simulated is True:
        sim = True
    elif is_simulated_ref(tx_id):
        sim = True
    elif metadata and (metadata.get("is_simulated") or metadata.get("simulated")):
        sim = True

    init_db(is_simulated=sim)

    # Fail-closed collision guard
    if not allow_collision:
        col = check_ladder_collision(
            asset=asset,
            target_price_ada=target_price_ada,
            threshold_pct=1.0,
            direction=direction,
            is_simulated=sim,
        )
        if col.get("collision"):
            raise OrderCollisionError(col["message"])

    now = int(time.time())
    order_id = f"maker_{asset.lower()}_{now}_{os.urandom(3).hex()}"
    is_sell = direction.upper() == "SELL"
    status = "PENDING_SELL" if is_sell else "PENDING_BUY"
    
    meta_dict = dict(metadata or {})
    if sim:
        meta_dict["is_simulated"] = True

    # Dual-metric accounting calculation
    # Buy orders lock principal + 2.0 ADA deposit + batcher fee; Sell orders lock tokens + 2.0 ADA deposit + batcher fee
    onchain_locked = (
        round(2.0 + float(batcher_fee_ada), 4)
        if is_sell
        else round(float(capital_ada) + 2.0 + float(batcher_fee_ada), 4)
    )
    breakeven_px = (
        round((float(capital_ada) + float(batcher_fee_ada) + float(l1_fee_ada)) / float(tokens_target), 7)
        if float(tokens_target) > 0
        else float(target_price_ada)
    )
    init_tokens_filled = float(tokens_target) if is_sell else 0.0
    init_sell_tx_id = tx_id if is_sell else None
    init_sell_target_ada = float(capital_ada) if is_sell else 0.0

    with get_db_connection(is_simulated=sim) as conn:
        conn.execute(
            """
            INSERT INTO maker_orders (
                order_id, tx_id, asset, direction, status, capital_ada,
                target_price_ada, tokens_target, tokens_filled, cost_basis_ada,
                cost_basis_per_token, batcher_fee_ada, l1_tx_fee_ada,
                onchain_locked_ada, breakeven_price_ada,
                order_script_addr, sell_tx_id, sell_target_ada,
                created_at, updated_at, metadata_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                order_id,
                tx_id,
                asset.upper(),
                direction.upper(),
                status,
                float(capital_ada),
                float(target_price_ada),
                float(tokens_target),
                init_tokens_filled,
                0.0,
                0.0,
                float(batcher_fee_ada),
                float(l1_fee_ada),
                onchain_locked,
                breakeven_px,
                order_script_addr,
                init_sell_tx_id,
                init_sell_target_ada,
                now,
                now,
                json.dumps(meta_dict),
            ),
        )
        conn.commit()
    target_db = "sim_maker_orders.db" if sim else "maker_orders.db"
    logger.info(
        f"Recorded new order {order_id} ({direction.upper()} {asset}) status={status} "
        f"principal={capital_ada}A locked={onchain_locked}A BE={breakeven_px} tx={tx_id} in [{target_db}]"
    )
    return order_id

def mark_buy_order_filled(
    order_id_or_tx: str,
    tokens_filled: float,
    actual_cost_basis_ada: Optional[float] = None,
    is_simulated: Optional[bool] = None,
) -> Dict[str, Any]:
    sim = is_simulated if is_simulated is not None else is_simulated_ref(order_id_or_tx)
    init_db(is_simulated=sim)
    now = int(time.time())
    with get_db_connection(is_simulated=sim) as conn:
        cur = conn.execute(
            "SELECT * FROM maker_orders WHERE order_id = ? OR tx_id = ?",
            (order_id_or_tx, order_id_or_tx),
        )
        row = cur.fetchone()
        if not row and not sim:
            with get_db_connection(is_simulated=True) as s_conn:
                row = s_conn.execute(
                    "SELECT * FROM maker_orders WHERE order_id = ? OR tx_id = ?",
                    (order_id_or_tx, order_id_or_tx),
                ).fetchone()
                if row:
                    sim = True
                    conn = s_conn
        if not row:
            logger.warning(f"Order not found for fill: {order_id_or_tx}")
            return {"status": "error", "message": f"Order not found: {order_id_or_tx}"}

        capital = float(row["capital_ada"])
        tx_fee = float(row["l1_tx_fee_ada"])
        batcher_fee = float(row["batcher_fee_ada"])
        cost_basis = actual_cost_basis_ada or (capital + tx_fee + batcher_fee)

        meta = json.loads(row["metadata_json"] or "{}")
        preloaded = meta.get("preloaded_inventory")

        # If not explicitly preloaded, check for any unlinked INVENTORY_HOLD for same asset
        if not preloaded:
            held_cur = conn.execute(
                """
                SELECT id, order_id, tokens_filled, cost_basis_ada, metadata_json
                FROM maker_orders
                WHERE asset = ? AND status = 'INVENTORY_HOLD' AND id != ?
                ORDER BY created_at ASC
                """,
                (row["asset"], row["id"])
            )
            held_rows = held_cur.fetchall()
            matched_sources = []
            for h in held_rows:
                h_meta = json.loads(h["metadata_json"] or "{}")
                linked_to = h_meta.get("linked_to_active_order")
                if linked_to is None or linked_to == row["order_id"]:
                    matched_sources.append(h)
            if matched_sources:
                preloaded = {
                    "source_order_ids": [h["order_id"] for h in matched_sources],
                    "tokens": sum(float(h["tokens_filled"]) for h in matched_sources),
                    "cost_basis_ada": sum(float(h["cost_basis_ada"]) for h in matched_sources),
                }

        merged_source_ids = []
        if preloaded and float(preloaded.get("tokens", 0)) > 0:
            held_tokens = float(preloaded.get("tokens", 0.0))
            held_cost = float(preloaded.get("cost_basis_ada", 0.0))
            source_ids = preloaded.get("source_order_ids", [])

            combined_tokens = float(tokens_filled) + held_tokens
            combined_cost = float(cost_basis) + held_cost
            combined_cost_per_tok = combined_cost / combined_tokens if combined_tokens > 0 else 0.0

            meta["preloaded_inventory_merged"] = True
            meta["consolidated_from"] = source_ids
            meta["merged_held_tokens"] = held_tokens
            meta["merged_held_cost_ada"] = held_cost
            merged_source_ids = source_ids

            conn.execute(
                """
                UPDATE maker_orders
                SET status = 'INVENTORY_HOLD',
                    tokens_filled = ?,
                    cost_basis_ada = ?,
                    cost_basis_per_token = ?,
                    metadata_json = ?,
                    updated_at = ?
                WHERE id = ?
                """,
                (combined_tokens, combined_cost, combined_cost_per_tok, json.dumps(meta), now, row["id"]),
            )

            for s_id in source_ids:
                s_row = conn.execute("SELECT id, metadata_json FROM maker_orders WHERE order_id = ?", (s_id,)).fetchone()
                if s_row:
                    s_meta = json.loads(s_row["metadata_json"] or "{}")
                    s_meta["merged_into"] = row["order_id"]
                    s_meta["merged_at"] = now
                    conn.execute(
                        """
                        UPDATE maker_orders
                        SET status = 'CONSOLIDATED',
                            metadata_json = ?,
                            updated_at = ?
                        WHERE id = ?
                        """,
                        (json.dumps(s_meta), now, s_row["id"]),
                    )
            tokens_to_report = combined_tokens
            cost_to_report = combined_cost
            logger.info(
                f"Order {order_id_or_tx} FILLED & CONSOLIDATED with {len(source_ids)} prior rungs "
                f"({held_tokens:.4f} {row['asset']} + {tokens_filled:.4f} {row['asset']} = {combined_tokens:.4f} {row['asset']}). "
                f"Combined Cost Basis: {combined_cost:.3f} ADA (Blended: {combined_cost_per_tok:.6f} ADA/tok)"
            )
        else:
            cost_per_tok = cost_basis / float(tokens_filled) if tokens_filled > 0 else 0.0
            conn.execute(
                """
                UPDATE maker_orders
                SET status = 'INVENTORY_HOLD',
                    tokens_filled = ?,
                    cost_basis_ada = ?,
                    cost_basis_per_token = ?,
                    updated_at = ?
                WHERE id = ?
                """,
                (float(tokens_filled), float(cost_basis), float(cost_per_tok), now, row["id"]),
            )
            tokens_to_report = float(tokens_filled)
            cost_to_report = float(cost_basis)
            logger.info(f"Order {order_id_or_tx} FILLED in [{'sim_db' if sim else 'prod_db'}]: {tokens_filled} {row['asset']} received. Net cost basis: {cost_basis:.3f} ADA")

        conn.commit()

    return {
        "status": "success",
        "order_id": row["order_id"],
        "asset": row["asset"],
        "tokens_filled": tokens_to_report,
        "cost_basis_ada": cost_to_report,
        "is_consolidated": bool(merged_source_ids),
        "consolidated_from": merged_source_ids,
    }

def record_dex_swap_fill(
    asset: str,
    tokens_filled: float,
    cost_basis_ada: float,
    tx_id: Optional[str] = None,
    protocol: str = "DEX_SWAP",
    is_simulated: Optional[bool] = None,
    auto_relist: bool = True,
    metadata: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Records an instant DEX swap fill (ADA -> Native Asset) in maker_orders.db,
    emits 'cardano/maker_filled' to the event bus, and automatically triggers
    a sale relisting using the same process as resting limit orders."""
    sim = False
    if is_simulated is True:
        sim = True
    elif is_simulated_ref(tx_id):
        sim = True
    elif metadata and (metadata.get("is_simulated") or metadata.get("simulated")):
        sim = True

    init_db(is_simulated=sim)
    now = int(time.time())
    order_id = f"swap_{asset.lower()}_{now}_{os.urandom(3).hex()}"
    cost_per_tok = (float(cost_basis_ada) / float(tokens_filled)) if float(tokens_filled) > 0 else 0.0

    meta_dict = dict(metadata or {})
    meta_dict.setdefault("source", "dex_swap")
    meta_dict.setdefault("protocol", protocol)
    if sim:
        meta_dict["is_simulated"] = True

    with get_db_connection(is_simulated=sim) as conn:
        conn.execute(
            """
            INSERT INTO maker_orders (
                order_id, tx_id, asset, direction, status, capital_ada,
                target_price_ada, tokens_target, tokens_filled, cost_basis_ada,
                cost_basis_per_token, batcher_fee_ada, l1_tx_fee_ada,
                onchain_locked_ada, breakeven_price_ada,
                order_script_addr, created_at, updated_at, metadata_json
            ) VALUES (?, ?, ?, 'BUY', 'INVENTORY_HOLD', ?, ?, ?, ?, ?, ?, 0.0, 0.18, 0.0, ?, NULL, ?, ?, ?)
            """,
            (
                order_id,
                tx_id,
                asset.upper(),
                float(cost_basis_ada),
                cost_per_tok,
                float(tokens_filled),
                float(tokens_filled),
                float(cost_basis_ada),
                cost_per_tok,
                cost_per_tok,
                now,
                now,
                json.dumps(meta_dict),
            ),
        )
        conn.commit()

    logger.info(
        f"DEX swap fill recorded as {order_id} ({asset.upper()}) in [{'sim_maker_orders.db' if sim else 'maker_orders.db'}]: "
        f"{tokens_filled} tokens, cost_basis={cost_basis_ada:.3f} ADA"
    )

    evt_payload = {
        "order_id": order_id,
        "buy_tx_id": tx_id,
        "asset": asset.upper(),
        "tokens_filled": float(tokens_filled),
        "net_cost_basis_ada": round(float(cost_basis_ada), 6),
        "timestamp": now,
        "is_simulated": sim,
    }

    relist_res = None
    if auto_relist:
        try:
            from lib.tools.maker_sell_reactor import handle as handle_maker_sell
            relist_res = handle_maker_sell(evt_payload)
            evt_payload["relisted_inline"] = True
            logger.info(f"Automatic maker sell relisting result for {order_id}: status={relist_res.get('status')}")
        except Exception as e:
            logger.warning(f"Direct maker_sell_reactor trigger failed: {e}")
            relist_res = {"status": "error", "reason": str(e)}

    try:
        from lib.tools.cardano_order_watcher import emit_event_to_bus
        emit_event_to_bus("cardano/maker_filled", evt_payload)
    except Exception as e:
        logger.warning(f"Could not emit cardano/maker_filled to bus: {e}")

    return {
        "status": "ok",
        "order_id": order_id,
        "asset": asset.upper(),
        "tokens_filled": float(tokens_filled),
        "cost_basis_ada": float(cost_basis_ada),
        "is_simulated": sim,
        "relist": relist_res,
    }


def record_sell_leg(
    buy_order_id_or_tx: str,
    sell_tx_id: str,
    sell_target_ada: float,
    is_simulated: Optional[bool] = None,
) -> bool:
    sim = is_simulated if is_simulated is not None else (is_simulated_ref(buy_order_id_or_tx) or is_simulated_ref(sell_tx_id))
    init_db(is_simulated=sim)
    now = int(time.time())
    with get_db_connection(is_simulated=sim) as conn:
        cur = conn.execute(
            "SELECT * FROM maker_orders WHERE order_id = ? OR tx_id = ?",
            (buy_order_id_or_tx, buy_order_id_or_tx),
        )
        row = cur.fetchone()
        if not row and not sim:
            with get_db_connection(is_simulated=True) as s_conn:
                row = s_conn.execute(
                    "SELECT * FROM maker_orders WHERE order_id = ? OR tx_id = ?",
                    (buy_order_id_or_tx, buy_order_id_or_tx),
                ).fetchone()
                if row:
                    sim = True
                    conn = s_conn
        if not row:
            logger.warning(f"Order not found for sell leg: {buy_order_id_or_tx}")
            return False

        conn.execute(
            """
            UPDATE maker_orders
            SET status = 'PENDING_SELL',
                sell_tx_id = ?,
                sell_target_ada = ?,
                updated_at = ?
            WHERE id = ?
            """,
            (sell_tx_id, float(sell_target_ada), now, row["id"]),
        )
        conn.commit()
    logger.info(f"Recorded SELL leg for {buy_order_id_or_tx} in [{'sim_db' if sim else 'prod_db'}]: sell_tx={sell_tx_id} target={sell_target_ada:.3f} ADA")
    return True

def mark_cycle_completed(
    order_id_or_tx: str,
    realized_profit_ada: float,
    is_simulated: Optional[bool] = None,
) -> bool:
    sim = is_simulated if is_simulated is not None else is_simulated_ref(order_id_or_tx)
    init_db(is_simulated=sim)
    now = int(time.time())
    with get_db_connection(is_simulated=sim) as conn:
        cur = conn.execute(
            "SELECT id FROM maker_orders WHERE order_id = ? OR tx_id = ? OR sell_tx_id = ?",
            (order_id_or_tx, order_id_or_tx, order_id_or_tx),
        )
        row = cur.fetchone()
        if not row and not sim:
            with get_db_connection(is_simulated=True) as s_conn:
                row = s_conn.execute(
                    "SELECT id FROM maker_orders WHERE order_id = ? OR tx_id = ? OR sell_tx_id = ?",
                    (order_id_or_tx, order_id_or_tx, order_id_or_tx),
                ).fetchone()
                if row:
                    sim = True
                    conn = s_conn
        if not row:
            logger.warning(f"Order not found to complete cycle: {order_id_or_tx}")
            return False

        conn.execute(
            """
            UPDATE maker_orders
            SET status = 'COMPLETED',
                realized_profit_ada = ?,
                updated_at = ?
            WHERE id = ?
            """,
            (float(realized_profit_ada), now, row["id"]),
        )
        conn.commit()
    logger.info(f"Cycle COMPLETED for {order_id_or_tx} in [{'sim_db' if sim else 'prod_db'}]: Realized profit = +{realized_profit_ada:.3f} ADA")
    return True

def link_accumulated_inventory(
    active_order_id: str,
    held_order_id: Optional[str] = None,
    is_simulated: Optional[bool] = None,
) -> Dict[str, Any]:
    """Pre-loads accumulated held inventory into an active PENDING_BUY limit order."""
    sim = is_simulated if is_simulated is not None else is_simulated_ref(active_order_id)
    init_db(is_simulated=sim)
    now = int(time.time())

    with get_db_connection(is_simulated=sim) as conn:
        active_row = conn.execute(
            "SELECT * FROM maker_orders WHERE order_id = ? OR tx_id = ?",
            (active_order_id, active_order_id),
        ).fetchone()
        if not active_row:
            raise ValueError(f"Active order {active_order_id} not found")
        if active_row["status"] != "PENDING_BUY":
            raise ValueError(f"Active order {active_order_id} status is {active_row['status']}, expected PENDING_BUY")

        asset = active_row["asset"]
        active_id = active_row["order_id"]

        if held_order_id:
            held_cur = conn.execute(
                "SELECT * FROM maker_orders WHERE (order_id = ? OR tx_id = ?) AND asset = ? AND status = 'INVENTORY_HOLD'",
                (held_order_id, held_order_id, asset),
            )
            held_rows = held_cur.fetchall()
            if not held_rows:
                raise ValueError(f"Held order {held_order_id} not found in INVENTORY_HOLD for asset {asset}")
        else:
            held_cur = conn.execute(
                "SELECT * FROM maker_orders WHERE asset = ? AND status = 'INVENTORY_HOLD' ORDER BY created_at ASC",
                (asset,),
            )
            held_rows = held_cur.fetchall()

        if not held_rows:
            return {"status": "ok", "message": f"No INVENTORY_HOLD positions found for {asset}", "linked_count": 0}

        held_tokens = sum(float(h["tokens_filled"]) for h in held_rows)
        held_cost = sum(float(h["cost_basis_ada"]) for h in held_rows)
        source_ids = [h["order_id"] for h in held_rows]

        # Update active order metadata
        active_meta = json.loads(active_row["metadata_json"] or "{}")
        active_meta["preloaded_inventory"] = {
            "source_order_ids": source_ids,
            "tokens": held_tokens,
            "cost_basis_ada": held_cost,
            "linked_at": now,
        }
        conn.execute(
            "UPDATE maker_orders SET metadata_json = ?, updated_at = ? WHERE id = ?",
            (json.dumps(active_meta), now, active_row["id"]),
        )

        # Update each held order metadata
        for h in held_rows:
            h_meta = json.loads(h["metadata_json"] or "{}")
            h_meta["linked_to_active_order"] = active_id
            h_meta["linked_at"] = now
            conn.execute(
                "UPDATE maker_orders SET metadata_json = ?, updated_at = ? WHERE id = ?",
                (json.dumps(h_meta), now, h["id"]),
            )

        conn.commit()

    logger.info(f"Linked {len(source_ids)} held rungs ({held_tokens} {asset}, {held_cost:.2f}A) into active order {active_id}")
    return {
        "status": "success",
        "active_order_id": active_id,
        "asset": asset,
        "preloaded_tokens": held_tokens,
        "preloaded_cost_basis_ada": held_cost,
        "source_order_ids": source_ids,
        "combined_tokens": float(active_row["tokens_target"]) + held_tokens,
        "combined_cost_basis_ada": round(float(active_row["capital_ada"]) + 2.18 + held_cost, 3),
    }


def unlink_inventory(
    active_order_id: str,
    is_simulated: Optional[bool] = None,
) -> Dict[str, Any]:
    """Removes pre-loaded inventory association from an active order and unlinks held orders."""
    sim = is_simulated if is_simulated is not None else is_simulated_ref(active_order_id)
    init_db(is_simulated=sim)
    now = int(time.time())

    with get_db_connection(is_simulated=sim) as conn:
        active_row = conn.execute(
            "SELECT * FROM maker_orders WHERE order_id = ? OR tx_id = ?",
            (active_order_id, active_order_id),
        ).fetchone()
        if not active_row:
            raise ValueError(f"Active order {active_order_id} not found")

        active_meta = json.loads(active_row["metadata_json"] or "{}")
        preloaded = active_meta.pop("preloaded_inventory", None)
        source_ids = preloaded.get("source_order_ids", []) if preloaded else []

        conn.execute(
            "UPDATE maker_orders SET metadata_json = ?, updated_at = ? WHERE id = ?",
            (json.dumps(active_meta), now, active_row["id"]),
        )

        for s_id in source_ids:
            s_row = conn.execute("SELECT id, metadata_json FROM maker_orders WHERE order_id = ?", (s_id,)).fetchone()
            if s_row:
                s_meta = json.loads(s_row["metadata_json"] or "{}")
                s_meta.pop("linked_to_active_order", None)
                conn.execute(
                    "UPDATE maker_orders SET metadata_json = ?, updated_at = ? WHERE id = ?",
                    (json.dumps(s_meta), now, s_row["id"]),
                )

        conn.commit()

    logger.info(f"Unlinked preloaded inventory from active order {active_row['order_id']}")
    return {"status": "success", "active_order_id": active_row["order_id"], "unlinked_count": len(source_ids)}


def auto_link_held_inventory(asset: Optional[str] = None, is_simulated: Optional[bool] = None) -> List[Dict[str, Any]]:
    """Scans for any unlinked INVENTORY_HOLD positions and auto-links them to matching PENDING_BUY orders."""
    sim = is_simulated if is_simulated is not None else False
    init_db(is_simulated=sim)
    results = []

    with get_db_connection(is_simulated=sim) as conn:
        if asset:
            active_buys = conn.execute(
                "SELECT * FROM maker_orders WHERE status = 'PENDING_BUY' AND asset = ? ORDER BY created_at ASC",
                (asset.upper(),)
            ).fetchall()
        else:
            active_buys = conn.execute(
                "SELECT * FROM maker_orders WHERE status = 'PENDING_BUY' ORDER BY created_at ASC"
            ).fetchall()

    for buy in active_buys:
        meta = json.loads(buy["metadata_json"] or "{}")
        if not meta.get("preloaded_inventory"):
            try:
                res = link_accumulated_inventory(buy["order_id"], is_simulated=sim)
                if res.get("status") == "success" and res.get("preloaded_tokens", 0) > 0:
                    results.append(res)
            except Exception as e:
                logger.warning(f"Auto-link failed for {buy['order_id']}: {e}")

    return results


def enrich_cycles(cycles: List[Dict[str, Any]], is_simulated: bool = False) -> List[Dict[str, Any]]:
    """Enriches cycles with preloaded inventory metrics, blended cost basis, and projected profitable ask."""
    active_buys_by_asset = {}
    for c in cycles:
        if c.get("status") == "PENDING_BUY":
            active_buys_by_asset[c.get("asset")] = c.get("order_id")

    markouts_by_oid: Dict[str, float] = {}
    if not is_simulated:
        try:
            trading_db = FINANCE_DIR / "trading.db"
            if trading_db.exists():
                with sqlite3.connect(str(trading_db), timeout=5.0) as tconn:
                    for mrow in tconn.execute(
                        "SELECT fill_id, markout_bps FROM markouts WHERE horizon_s = 21600 AND status = 'done' AND markout_bps IS NOT NULL"
                    ).fetchall():
                        fid = str(mrow[0] or "")
                        oid_base = fid.split(":", 1)[0]
                        if oid_base:
                            markouts_by_oid[oid_base] = float(mrow[1])
        except Exception:
            pass

    enriched = []
    for c in cycles:
        c_dict = dict(c)
        meta = json.loads(c_dict.get("metadata_json") or "{}")
        status = c_dict.get("status")
        asset = c_dict.get("asset")
        oid = c_dict.get("order_id")

        if oid in markouts_by_oid:
            c_dict["markout_6h_bps"] = markouts_by_oid[oid]
        if meta.get("ada_received") is not None:
            c_dict["ada_received"] = float(meta["ada_received"])
        if meta.get("net_exit_ada") is not None:
            c_dict["net_exit_ada"] = float(meta["net_exit_ada"])

        if status == "PENDING_BUY":
            preloaded = meta.get("preloaded_inventory", {})
            pre_tok = float(preloaded.get("tokens", 0.0))
            pre_cost = float(preloaded.get("cost_basis_ada", 0.0))
            source_ids = preloaded.get("source_order_ids", [])

            c_dict["preloaded_tokens"] = pre_tok
            c_dict["preloaded_cost_basis_ada"] = pre_cost
            c_dict["preloaded_source_orders"] = source_ids

            target_tok = float(c_dict.get("tokens_target", 0.0))
            capital = float(c_dict.get("capital_ada", 0.0))
            batcher = float(c_dict.get("batcher_fee_ada", 2.0))
            l1_fee = float(c_dict.get("l1_tx_fee_ada", 0.18))
            rung_cost = capital + batcher + l1_fee

            comb_tok = round(target_tok + pre_tok, 4)
            comb_cost = round(rung_cost + pre_cost, 3)
            comb_be = round((comb_cost + 2.20) / comb_tok, 6) if comb_tok > 0 else 0.0
            comb_ask = round((comb_cost + 2.20 + 0.75) / comb_tok, 6) if comb_tok > 0 else 0.0

            c_dict["combined_projected_tokens"] = comb_tok
            c_dict["combined_projected_cost_basis_ada"] = comb_cost
            c_dict["combined_projected_breakeven_ada"] = comb_be
            c_dict["combined_projected_ask_ada"] = comb_ask

        elif status == "INVENTORY_HOLD":
            linked_order = meta.get("linked_to_active_order")
            c_dict["linked_active_order_id"] = linked_order
            if not linked_order:
                c_dict["available_active_order_id"] = active_buys_by_asset.get(asset)

        elif status == "CONSOLIDATED":
            c_dict["merged_into"] = meta.get("merged_into")

        enriched.append(c_dict)

    return enriched


def get_active_cycles(is_simulated: bool = False) -> List[Dict[str, Any]]:
    init_db(is_simulated=is_simulated)
    # Auto-link unlinked inventory holds to active buy rungs
    auto_link_held_inventory(is_simulated=is_simulated)
    with get_db_connection(is_simulated=is_simulated) as conn:
        if is_simulated:
            cur = conn.execute("SELECT * FROM maker_orders ORDER BY updated_at DESC")
        else:
            # STRICT TAX & ACCOUNTING INVARIANT: Only return real on-chain orders from maker_orders.db
            cur = conn.execute(
                "SELECT * FROM maker_orders WHERE (tx_id NOT LIKE 'sim_%' OR tx_id IS NULL) AND order_id NOT LIKE 'sim_%' ORDER BY updated_at DESC"
            )
        rows = cur.fetchall()
        cycles = [dict(r) for r in rows]

    return enrich_cycles(cycles, is_simulated=is_simulated)


def get_sim_cycles() -> List[Dict[str, Any]]:
    return get_active_cycles(is_simulated=True)

def purge_and_migrate_simulated() -> Dict[str, Any]:
    """
    STRICT TAX & FIDUCIARY SEGREGATION:
    Removes any simulated test cycles or triggers from production maker_orders.db
    and safely migrates them into sim_maker_orders.db so real accounting and IRS Form 8949
    ledgers remain 100% pure on-chain truth.
    """
    init_db(is_simulated=False)
    init_db(is_simulated=True)
    migrated_orders = 0
    migrated_triggers = 0

    with get_db_connection(is_simulated=False) as p_conn:
        p_orders = p_conn.execute(
            "SELECT * FROM maker_orders WHERE tx_id LIKE 'sim_%' OR order_id LIKE 'sim_%' OR metadata_json LIKE '%\"is_simulated\": true%'"
        ).fetchall()
        p_triggers = p_conn.execute(
            """
            SELECT * FROM stop_triggers 
            WHERE trigger_id LIKE 'sim_%' 
               OR linked_order_id LIKE 'sim_%' 
               OR metadata_json LIKE '%"is_simulated": true%'
               OR metadata_json LIKE '%"dry_run_only": true%'
               OR dry_run_sim_json LIKE '%"mode": "DRY_RUN"%'
            """
        ).fetchall()

    if p_orders or p_triggers:
        with get_db_connection(is_simulated=True) as s_conn:
            for o in p_orders:
                cols = [k for k in o.keys() if k != 'id']
                placeholders = ', '.join(['?'] * len(cols))
                col_names = ', '.join(cols)
                s_conn.execute(
                    f"INSERT OR REPLACE INTO maker_orders ({col_names}) VALUES ({placeholders})",
                    [o[k] for k in cols]
                )
                migrated_orders += 1
            for t in p_triggers:
                cols = [k for k in t.keys() if k != 'id']
                placeholders = ', '.join(['?'] * len(cols))
                col_names = ', '.join(cols)
                s_conn.execute(
                    f"INSERT OR REPLACE INTO stop_triggers ({col_names}) VALUES ({placeholders})",
                    [t[k] for k in cols]
                )
                migrated_triggers += 1
            s_conn.commit()

        with get_db_connection(is_simulated=False) as p_conn:
            p_conn.execute(
                "DELETE FROM maker_orders WHERE tx_id LIKE 'sim_%' OR order_id LIKE 'sim_%' OR metadata_json LIKE '%\"is_simulated\": true%'"
            )
            p_conn.execute(
                """
                DELETE FROM stop_triggers 
                WHERE trigger_id LIKE 'sim_%' 
                   OR linked_order_id LIKE 'sim_%' 
                   OR metadata_json LIKE '%\"is_simulated\": true%'
                   OR metadata_json LIKE '%\"dry_run_only\": true%'
                   OR dry_run_sim_json LIKE '%\"mode\": \"DRY_RUN\"%'
                """
            )
            p_conn.commit()

    logger.info(f"Purge & Migrate: Segregated {migrated_orders} simulated orders and {migrated_triggers} simulated triggers into sim_maker_orders.db")
    return {
        "status": "ok",
        "migrated_orders": migrated_orders,
        "migrated_triggers": migrated_triggers,
    }

def clear_simulated_cycles() -> int:
    """Removes all simulated/dry-run test cycles from maker_orders.db and quarantines in sim DB."""
    res = purge_and_migrate_simulated()
    return res["migrated_orders"]

def delete_order_cycle(order_id: str) -> bool:
    """Deletes a specific maker cycle from database."""
    sim = is_simulated_ref(order_id)
    init_db(is_simulated=sim)
    with get_db_connection(is_simulated=sim) as conn:
        cur = conn.execute(
            "DELETE FROM maker_orders WHERE order_id = ? OR tx_id = ?",
            (order_id, order_id),
        )
        conn.commit()
        if cur.rowcount > 0:
            return True
    if not sim:
        with get_db_connection(is_simulated=True) as s_conn:
            cur = s_conn.execute(
                "DELETE FROM maker_orders WHERE order_id = ? OR tx_id = ?",
                (order_id, order_id),
            )
            s_conn.commit()
            return cur.rowcount > 0
    return False

def reconcile_from_ledger() -> Dict[str, Any]:
    """
    DISASTER RECOVERY: Rebuilds local maker order state from Cardano L1 ground truth.
    0. Reconciles existing PENDING_BUY / PENDING_SELL orders against on-chain settlement.
    1. Queries Blockfrost & DEX script pending orders owned by our wallet.
    2. Inspects hot wallet UTxO token balances.
    3. Reconstructs missing SQLite records to ensure zero loss of capital visibility.
    """
    init_db()
    lifecycle_res = None
    try:
        from lib.tools.cardano_order_watcher import poll_order_lifecycle_once
        lifecycle_res = poll_order_lifecycle_once()
    except Exception as e:
        logger.warning(f"Order lifecycle poll during reconciliation failed: {e}")

    env = load_env_vars()
    addr = env.get("CARDANO_WALLET_ADDR", "")
    if not addr:
        raise ValueError("CARDANO_WALLET_ADDR is not set (.george/secrets.env)")
    bf_id = env.get("BLOCKFROST_PROJECT_ID", "")
    bf_url = normalize_blockfrost_base_url(env.get("BLOCKFROST_BASE_URL"))

    logger.info(f"Starting Disaster Recovery / Ledger Reconciliation for {addr}...")
    recovered_pending = 0
    recovered_inventory = 0

    # 1. Query live resting orders from Minswap API
    try:
        url = f"{MINSWAP_AGGREGATOR_BASE}/pending-orders?owner_address={addr}"
        req = urllib.request.Request(url, headers={"User-Agent": "BlueLodge-DisasterRecovery/1.0"})
        with urllib.request.urlopen(req, timeout=12) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            orders = data.get("orders", [])
            for o in orders:
                tx_id = o.get("tx_hash") or o.get("tx_id")
                asset = o.get("target_asset", "UNKNOWN")
                amt_in = float(o.get("amount_in", 0)) / 1_000_000
                tokens_target = float(o.get("expected_amount_out", 0))
                
                with get_db_connection() as conn:
                    cur = conn.execute("SELECT id FROM maker_orders WHERE tx_id = ?", (tx_id,))
                    if not cur.fetchone():
                        record_new_order(
                            asset=asset,
                            direction="BUY",
                            capital_ada=amt_in,
                            target_price_ada=(amt_in / tokens_target) if tokens_target > 0 else 0.0,
                            tokens_target=tokens_target,
                            tx_id=tx_id,
                            metadata={"reconciled_from_dex": True},
                        )
                        recovered_pending += 1
    except Exception as e:
        logger.warning(f"DEX pending order query error during reconciliation: {e}")

    # 1b. Check local trade audit trail (trades.jsonl) for unindexed live limit orders
    trades_file = Path(os.environ.get("GRAPH_TRADES_LOG", LODGE_DIR / "dossiers" / "finance" / "trades.jsonl"))
    if trades_file.exists():
        try:
            with open(trades_file, "r") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                        if rec.get("mode") == "live" and rec.get("strategy") == "maker_limit_order" and rec.get("status") == "resting_placed":
                            tx_id = rec.get("tx_id")
                            asset = rec.get("asset", "UNKNOWN")
                            amt_in = float(rec.get("input_ada", 0.0))
                            script_addr = rec.get("script")
                            l1_fee = float(rec.get("l1_fee_ada", 0.18))

                            with get_db_connection() as conn:
                                cur = conn.execute("SELECT id FROM maker_orders WHERE tx_id = ?", (tx_id,))
                                if not cur.fetchone():
                                    t_price = 0.090649 if asset == "IAG" else (amt_in / 1000.0)
                                    tokens_tgt = (amt_in / t_price) if t_price > 0 else 0.0
                                    record_new_order(
                                        asset=asset,
                                        direction="BUY",
                                        capital_ada=amt_in,
                                        target_price_ada=t_price,
                                        tokens_target=tokens_tgt,
                                        tx_id=tx_id,
                                        order_script_addr=script_addr,
                                        l1_fee_ada=l1_fee,
                                        batcher_fee_ada=2.00,
                                        metadata={"reconciled_from_trades_log": True},
                                    )
                                    recovered_pending += 1
                                    logger.info(f"Reconciled resting live maker order from trades.jsonl: {asset} tx={tx_id}")
                    except Exception:
                        pass
        except Exception as e:
            logger.warning(f"Error reading trades.jsonl during reconciliation: {e}")

    # 2. Query Wallet UTxOs from Blockfrost to recover held inventory
    try:
        endpoint = f"{bf_url}/v0/addresses/{addr}" if "/v0" not in bf_url else f"{bf_url}/addresses/{addr}"
        req = urllib.request.Request(endpoint, headers={"project_id": bf_id, "User-Agent": "BlueLodge/1.0"})
        with urllib.request.urlopen(req, timeout=12) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            amounts = data.get("amount", [])
            
            for item in amounts:
                unit = item.get("unit")
                qty = int(item.get("quantity", 0))
                if unit == "lovelace" or qty <= 0:
                    continue
                
                matched_sym = None
                for sym, m in TOKEN_METADATA.items():
                    if m.get("unit") == unit:
                        matched_sym = sym
                        break
                
                if matched_sym:
                    dec = TOKEN_METADATA[matched_sym].get("decimals", 6)
                    human_qty = qty / (10 ** dec)
                    
                    with get_db_connection() as conn:
                        cur = conn.execute(
                            "SELECT id FROM maker_orders WHERE asset = ? AND status IN ('PENDING_BUY', 'INVENTORY_HOLD', 'PENDING_SELL')",
                            (matched_sym,),
                        )
                        if not cur.fetchone():
                            # Reconstruct held inventory record
                            now = int(time.time())
                            order_id = f"reconciled_{matched_sym.lower()}_{now}"
                            conn.execute(
                                """
                                INSERT INTO maker_orders (
                                    order_id, asset, direction, status, capital_ada, target_price_ada,
                                    tokens_target, tokens_filled, cost_basis_ada, cost_basis_per_token,
                                    created_at, updated_at, metadata_json
                                ) VALUES (?, ?, 'BUY', 'INVENTORY_HOLD', 0.0, 0.0, ?, ?, 0.0, 0.0, ?, ?, ?)
                                """,
                                (order_id, matched_sym, human_qty, human_qty, now, now, json.dumps({"reconciled_from_wallet": True, "operator_hold": True, "relist_blocked": True})),
                            )
                            conn.commit()
                            recovered_inventory += 1
                            logger.info(f"Reconciled unindexed held inventory: {human_qty} {matched_sym}")
    except Exception as e:
        logger.warning(f"Blockfrost UTxO query error during reconciliation: {e}")

    return {
        "status": "ok",
        "lifecycle_poll": lifecycle_res,
        "recovered_pending_orders": recovered_pending,
        "recovered_inventory_records": recovered_inventory,
        "active_cycles": get_active_cycles(),
    }

# ── Stop Trigger Operations ──────────────────────────────────────────

def record_stop_trigger(
    asset: str,
    trigger_type: str,
    trigger_price_ada: float,
    capital_ada: float,
    invalidation_price_ada: Optional[float] = None,
    gate_ada_24h_min: float = 0.0,
    slippage_cap_pct: float = 1.5,
    tp_target_pct: float = 4.0,
    sl_target_pct: float = 2.5,
    linked_order_id: Optional[str] = None,
    dry_run_sim: Optional[Dict[str, Any]] = None,
    metadata: Optional[Dict[str, Any]] = None,
    is_simulated: Optional[bool] = None,
) -> str:
    sim = False
    if is_simulated is True:
        sim = True
    elif is_simulated_ref(linked_order_id):
        sim = True
    elif metadata and (metadata.get("is_simulated") or metadata.get("simulated") or metadata.get("dry_run_only")):
        sim = True
    elif dry_run_sim and (dry_run_sim.get("mode") == "DRY_RUN" or dry_run_sim.get("simulated")):
        sim = True

    init_db(is_simulated=sim)
    now = int(time.time())
    trigger_id = f"stop_{asset.lower()}_{now}_{os.urandom(3).hex()}"
    sim_json = json.dumps(dry_run_sim or {})
    meta_dict = dict(metadata or {})
    if sim:
        meta_dict["is_simulated"] = True
    meta_json = json.dumps(meta_dict)

    with get_db_connection(is_simulated=sim) as conn:
        conn.execute(
            """
            INSERT INTO stop_triggers (
                trigger_id, asset, trigger_type, trigger_price_ada, invalidation_price_ada,
                gate_ada_24h_min, capital_ada, slippage_cap_pct, tp_target_pct, sl_target_pct,
                status, linked_order_id, dry_run_sim_json, created_at, updated_at, metadata_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'ARMED', ?, ?, ?, ?, ?)
            """,
            (
                trigger_id, asset.upper(), trigger_type.upper(), float(trigger_price_ada),
                float(invalidation_price_ada) if invalidation_price_ada is not None else None,
                float(gate_ada_24h_min), float(capital_ada), float(slippage_cap_pct),
                float(tp_target_pct), float(sl_target_pct),
                linked_order_id, sim_json, now, now, meta_json
            ),
        )
        conn.commit()
    target_db = "sim_maker_orders.db" if sim else "maker_orders.db"
    logger.info(f"Armed new stop trigger: {trigger_id} for {asset} at {trigger_price_ada} ADA in [{target_db}]")
    return trigger_id

def get_armed_stop_triggers(asset: Optional[str] = None, is_simulated: bool = False) -> List[Dict[str, Any]]:
    init_db(is_simulated=is_simulated)
    with get_db_connection(is_simulated=is_simulated) as conn:
        if asset:
            rows = conn.execute(
                "SELECT * FROM stop_triggers WHERE status = 'ARMED' AND asset = ? ORDER BY created_at ASC",
                (asset.upper(),)
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM stop_triggers WHERE status = 'ARMED' ORDER BY created_at ASC"
            ).fetchall()
    return [dict(r) for r in rows]

def get_sim_stop_triggers(asset: Optional[str] = None) -> List[Dict[str, Any]]:
    return get_armed_stop_triggers(asset=asset, is_simulated=True)

def get_all_stop_triggers(asset: Optional[str] = None, limit: int = 50, is_simulated: bool = False) -> List[Dict[str, Any]]:
    init_db(is_simulated=is_simulated)
    with get_db_connection(is_simulated=is_simulated) as conn:
        if asset:
            rows = conn.execute(
                "SELECT * FROM stop_triggers WHERE asset = ? ORDER BY created_at DESC LIMIT ?",
                (asset.upper(), limit)
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM stop_triggers ORDER BY created_at DESC LIMIT ?",
                (limit,)
            ).fetchall()
    return [dict(r) for r in rows]

def update_stop_trigger_status(
    trigger_id: str,
    new_status: str,
    metadata_updates: Optional[Dict[str, Any]] = None,
    linked_order_id: Optional[str] = None,
    is_simulated: Optional[bool] = None,
) -> bool:
    sim = is_simulated if is_simulated is not None else (is_simulated_ref(trigger_id) or is_simulated_ref(linked_order_id))
    init_db(is_simulated=sim)
    now = int(time.time())
    with get_db_connection(is_simulated=sim) as conn:
        cur = conn.execute("SELECT metadata_json FROM stop_triggers WHERE trigger_id = ?", (trigger_id,))
        row = cur.fetchone()
        if not row and not sim:
            with get_db_connection(is_simulated=True) as s_conn:
                row = s_conn.execute("SELECT metadata_json FROM stop_triggers WHERE trigger_id = ?", (trigger_id,)).fetchone()
                if row:
                    sim = True
                    conn = s_conn
        if not row:
            return False
        meta = json.loads(row[0] or "{}")
        if metadata_updates:
            meta.update(metadata_updates)

        if linked_order_id:
            conn.execute(
                """
                UPDATE stop_triggers
                SET status = ?, linked_order_id = ?, updated_at = ?, metadata_json = ?
                WHERE trigger_id = ?
                """,
                (new_status.upper(), linked_order_id, now, json.dumps(meta), trigger_id)
            )
        else:
            conn.execute(
                """
                UPDATE stop_triggers
                SET status = ?, updated_at = ?, metadata_json = ?
                WHERE trigger_id = ?
                """,
                (new_status.upper(), now, json.dumps(meta), trigger_id)
            )
        conn.commit()
    logger.info(f"Updated stop trigger {trigger_id} status to {new_status} in [{'sim_db' if sim else 'prod_db'}]")
    return True

def delete_stop_trigger(trigger_id: str) -> bool:
    sim = is_simulated_ref(trigger_id)
    init_db(is_simulated=sim)
    with get_db_connection(is_simulated=sim) as conn:
        cur = conn.execute("DELETE FROM stop_triggers WHERE trigger_id = ?", (trigger_id,))
        conn.commit()
        if cur.rowcount > 0:
            return True
    if not sim:
        with get_db_connection(is_simulated=True) as s_conn:
            cur = s_conn.execute("DELETE FROM stop_triggers WHERE trigger_id = ?", (trigger_id,))
            s_conn.commit()
            return cur.rowcount > 0
    return False

def cancel_linked_stop_triggers(order_id_or_tx: str, reason: str = "order_reclaimed") -> int:
    """Cancels any ARMED stop triggers linked to the given order ID or transaction hash in both DBs."""
    if not order_id_or_tx:
        return 0
    init_db(is_simulated=False)
    init_db(is_simulated=True)
    now = int(time.time())
    cancelled_count = 0
    clean_ref = order_id_or_tx.split("#")[0].strip()

    for is_sim in (False, True):
        with get_db_connection(is_simulated=is_sim) as conn:
            rows = conn.execute(
                """
                SELECT trigger_id, metadata_json FROM stop_triggers
                WHERE status = 'ARMED' AND (
                    linked_order_id = ? OR
                    linked_order_id = ? OR
                    trigger_id = ? OR
                    metadata_json LIKE ? OR
                    metadata_json LIKE ?
                )
                """,
                (order_id_or_tx, clean_ref, order_id_or_tx, f"%{clean_ref}%", f"%{order_id_or_tx}%"),
            ).fetchall()
            for r in rows:
                tid = r["trigger_id"]
                meta = json.loads(r["metadata_json"] or "{}")
                meta.update({"cancelled_reason": reason, "cancelled_at": now})
                conn.execute(
                    "UPDATE stop_triggers SET status = 'CANCELLED', updated_at = ?, metadata_json = ? WHERE trigger_id = ?",
                    (now, json.dumps(meta), tid),
                )
                cancelled_count += 1
                logger.info(f"Auto-cancelled stop trigger {tid} linked to order/tx {order_id_or_tx} (Reason: {reason})")
            conn.commit()
    return cancelled_count

def prune_stale_stop_triggers(max_age_secs: int = 86400, cancel_all_armed: bool = False, is_simulated: bool = False) -> Dict[str, Any]:
    """Prunes stale or orphaned ARMED stop triggers older than max_age_secs, or all if requested."""
    init_db(is_simulated=is_simulated)
    now = int(time.time())
    cutoff = now - max_age_secs
    pruned = []
    with get_db_connection(is_simulated=is_simulated) as conn:
        if cancel_all_armed:
            rows = conn.execute(
                "SELECT trigger_id, asset, trigger_type, created_at, metadata_json FROM stop_triggers WHERE status = 'ARMED'"
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT trigger_id, asset, trigger_type, created_at, metadata_json FROM stop_triggers WHERE status = 'ARMED' AND created_at < ?",
                (cutoff,),
            ).fetchall()
        for r in rows:
            tid = r["trigger_id"]
            meta = json.loads(r["metadata_json"] or "{}")
            meta.update({"cancelled_reason": "stale_prune", "cancelled_at": now})
            conn.execute(
                "UPDATE stop_triggers SET status = 'CANCELLED', updated_at = ?, metadata_json = ? WHERE trigger_id = ?",
                (now, json.dumps(meta), tid),
            )
            pruned.append(tid)
            logger.info(f"Pruned stale stop trigger {tid} ({r['asset']} {r['trigger_type']})")
        conn.commit()
    return {"status": "ok", "pruned_count": len(pruned), "pruned_trigger_ids": pruned}

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Cardano Maker DB & Disaster Recovery CLI")
    parser.add_argument("--init", action="store_true", help="Initialize maker orders SQLite databases")
    parser.add_argument("--list", action="store_true", help="List all real on-chain maker order cycles")
    parser.add_argument("--sim-list", action="store_true", help="List all simulated maker order cycles")
    parser.add_argument("--reconcile", action="store_true", help="Run disaster recovery reconciliation against Cardano L1")
    parser.add_argument("--clear-simulated", action="store_true", help="Clear simulated cycles (alias for purge-simulated)")
    parser.add_argument("--purge-simulated", action="store_true", help="Purge and quarantine simulated records into sim_maker_orders.db")
    parser.add_argument("--delete", type=str, help="Delete a specific order cycle by ID")
    parser.add_argument("--link-inventory", action="store_true", help="Link held inventory to active buy order")
    parser.add_argument("--unlink-inventory", action="store_true", help="Unlink held inventory from active buy order")
    parser.add_argument("--auto-link", action="store_true", help="Auto-link held inventory to matching active buy orders")
    parser.add_argument("--active-id", type=str, help="Active order ID for inventory linking")
    parser.add_argument("--held-id", type=str, help="Held order ID to link (optional; defaults to all held for asset)")
    parser.add_argument("--sim", action="store_true", help="Operate on simulated database")
    parser.add_argument("--json", action="store_true", help="Output pure JSON")
    args = parser.parse_args()

    if args.init:
        init_db(is_simulated=False)
        init_db(is_simulated=True)
        print("Real database initialized at:", MAKER_DB_PATH)
        print("Sim database initialized at:", SIM_MAKER_DB_PATH)
    elif args.link_inventory:
        if not args.active_id:
            print(json.dumps({"status": "error", "message": "--active-id required for --link-inventory"}) if args.json else "Error: --active-id required")
            sys.exit(1)
        res = link_accumulated_inventory(args.active_id, held_order_id=args.held_id, is_simulated=args.sim)
        print(json.dumps(res, indent=2) if args.json else res)
    elif args.unlink_inventory:
        if not args.active_id:
            print(json.dumps({"status": "error", "message": "--active-id required for --unlink-inventory"}) if args.json else "Error: --active-id required")
            sys.exit(1)
        res = unlink_inventory(args.active_id, is_simulated=args.sim)
        print(json.dumps(res, indent=2) if args.json else res)
    elif args.auto_link:
        res = auto_link_held_inventory(is_simulated=args.sim)
        print(json.dumps({"status": "ok", "auto_linked": res}, indent=2) if args.json else f"Auto-linked {len(res)} positions")
    elif args.clear_simulated or args.purge_simulated:
        res = purge_and_migrate_simulated()
        if args.json:
            print(json.dumps(res))
        else:
            print(f"Purged and segregated {res['migrated_orders']} simulated orders and {res['migrated_triggers']} simulated triggers into sim_maker_orders.db")
    elif args.delete:
        ok = delete_order_cycle(args.delete)
        if args.json:
            print(json.dumps({"status": "ok" if ok else "not_found", "deleted": ok}))
        else:
            print(f"Delete cycle '{args.delete}': {'Success' if ok else 'Not Found'}")
    elif args.reconcile:
        res = reconcile_from_ledger()
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            print(f"Reconciliation Complete: Recovered {res['recovered_pending_orders']} pending orders, {res['recovered_inventory_records']} inventory records.")
    elif args.sim_list:
        cycles = get_sim_cycles()
        if args.json:
            print(json.dumps({"status": "ok", "cycles": cycles}, indent=2))
        else:
            print(f"=== SIMULATED MAKER CYCLES ({len(cycles)}) ===")
            for c in cycles:
                print(f"  [{c['status']}] {c['asset']} ({c['direction']}) | Capital: {c['capital_ada']} ADA | Tokens: {c['tokens_filled']}/{c['tokens_target']} | Cost Basis: {c['cost_basis_ada']} ADA | Tx: {c['tx_id']}")
    elif args.list:
        cycles = get_active_cycles(is_simulated=False)
        if args.json:
            print(json.dumps({"status": "ok", "cycles": cycles}, indent=2))
        else:
            print(f"=== ACTIVE REAL ON-CHAIN MAKER CYCLES ({len(cycles)}) ===")
            for c in cycles:
                print(f"  [{c['status']}] {c['asset']} ({c['direction']}) | Capital: {c['capital_ada']} ADA | Tokens: {c['tokens_filled']}/{c['tokens_target']} | Cost Basis: {c['cost_basis_ada']} ADA | Tx: {c['tx_id']}")
    else:
        init_db(is_simulated=False)
        init_db(is_simulated=True)
        print("Real database verified at:", MAKER_DB_PATH)
        print("Sim database verified at:", SIM_MAKER_DB_PATH)
