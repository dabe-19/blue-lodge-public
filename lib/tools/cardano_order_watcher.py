#!/usr/bin/env python3
"""
Sovereign Cardano Order Watcher Daemon (Path D)
Polls Blockfrost and DEX Order Validators every 60s.
Detects order fills, updates local SQLite cost-basis records,
and emits 'cardano/maker_filled' events to the POSIX FIFO Event Bus.
"""

import os
import sys
import json
import time
import signal
import logging
import argparse
import subprocess
import urllib.request
from pathlib import Path
from typing import Optional, Any, Dict, List

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path.home() / "blue-lodge"))
GEORGE_DIR = Path(os.environ.get("GEORGE_DIR", LODGE_DIR / ".george"))
FINANCE_DIR = Path(os.environ.get("FINANCE_DIR", GEORGE_DIR / "finance"))
EVENT_BUS_FIFO = Path(os.environ.get("EVENT_BUS_FIFO", GEORGE_DIR / "ipc" / "event_bus.fifo"))
WATCHER_PID_FILE = FINANCE_DIR / "order_watcher.pid"
WATCHER_LOG_FILE = FINANCE_DIR / "order_watcher.log"

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", stream=sys.stderr)
logger = logging.getLogger("cardano_order_watcher")

from lib.tools.cardano_trader import query_wallet_balance, normalize_blockfrost_base_url
from lib.tools.cardano_dex_swapper import load_env_vars, MINSWAP_AGGREGATOR_BASE, TOKEN_METADATA
from lib.tools.cardano_maker_db import (
    get_db_connection,
    mark_buy_order_filled,
    mark_cycle_completed,
    get_active_cycles,
    record_new_order,
)

def emit_event_to_bus(event_type: str, payload: Dict[str, Any], source: str = "cardano_order_watcher") -> bool:
    """Emits an event to the POSIX FIFO event bus or falls back to event_bus.sh."""
    try:
        depth = int(os.environ.get("EVENT_DEPTH", "0"))
    except ValueError:
        depth = 0
    env_obj: Dict[str, Any] = {
        "event_id": f"evt_{int(time.time())}_{os.urandom(3).hex()}",
        "type": event_type,
        "event_type": event_type,
        "source": source,
        "depth": depth,
        "timestamp": int(time.time()),
        "payload": payload,
    }
    if os.environ.get("EVENT_ID"):
        env_obj["parent_event_id"] = os.environ["EVENT_ID"]
    data = (json.dumps(env_obj, separators=(",", ":")) + "\n").encode("utf-8")

    # Fast path: a single atomic write(2) of a complete line (< PIPE_BUF)
    if len(data) <= 3900 and EVENT_BUS_FIFO.exists():
        try:
            fifo_fd = os.open(str(EVENT_BUS_FIFO), os.O_WRONLY | os.O_NONBLOCK)
            try:
                written = os.write(fifo_fd, data)
            finally:
                os.close(fifo_fd)
            if written == len(data):
                logger.info(f"Emitted {event_type} directly to FIFO: {payload.get('asset', '')}")
                return True
        except Exception as e:
            logger.debug(f"Direct FIFO write failed ({e}); invoking bash helper...")

    # Fallback to event_bus_emit in bash (spills large payloads, spools if bus is down).
    # Values are passed as positional args, never interpolated into the script.
    try:
        cmd = [
            "bash",
            "-c",
            'source "$1/lib/ipc/event_bus.sh" && event_bus_emit "$2" "$3" "$4"',
            "_", str(LODGE_DIR), event_type, json.dumps(payload), source,
        ]
        subprocess.run(cmd, capture_output=True, timeout=5, check=True)
        logger.info(f"Emitted {event_type} via event_bus.sh: {payload.get('asset', '')}")
        return True
    except Exception as e:
        logger.warning(f"Could not emit event to bus: {e}")
        return False

def query_onchain_pending_orders(addr: str) -> List[Dict[str, Any]]:
    """Queries live active resting orders on DEX validator scripts."""
    url = f"{MINSWAP_AGGREGATOR_BASE}/pending-orders?owner_address={addr}"
    req = urllib.request.Request(url, headers={"User-Agent": "BlueLodge-OrderWatcher/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=12) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return data.get("orders", [])
    except Exception as e:
        logger.warning(f"Failed to query DEX pending orders: {e}")
        return []

def query_wallet_token_balances(addr: str, bf_id: str, bf_url: str) -> Dict[str, float]:
    """Queries current non-ADA token quantities held in wallet."""
    endpoint = f"{bf_url}/v0/addresses/{addr}" if "/v0" not in bf_url else f"{bf_url}/addresses/{addr}"
    req = urllib.request.Request(endpoint, headers={"project_id": bf_id, "User-Agent": "BlueLodge/1.0"})
    balances = {}
    try:
        with urllib.request.urlopen(req, timeout=12) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            amounts = data.get("amount", [])
            for item in amounts:
                unit = item.get("unit")
                qty = int(item.get("quantity", 0))
                if unit == "lovelace" or qty <= 0:
                    continue
                for sym, meta in TOKEN_METADATA.items():
                    if meta.get("unit") == unit:
                        dec = meta.get("decimals", 6)
                        balances[sym] = qty / (10 ** dec)
                        break
    except Exception as e:
        logger.warning(f"Failed to query wallet token balances: {e}")
    return balances

def check_tx_output_consumed(tx_hash: Optional[str], output_index: int, bf_id: str, bf_url: str) -> Optional[str]:
    """Queries Blockfrost to check if a specific transaction output has been consumed (spent)."""
    if not tx_hash or not bf_id or tx_hash.startswith("sim_"):
        return None
    endpoint = f"{bf_url}/v0/txs/{tx_hash}/utxos" if "/v0" not in bf_url else f"{bf_url}/txs/{tx_hash}/utxos"
    req = urllib.request.Request(endpoint, headers={"project_id": bf_id, "User-Agent": "BlueLodge-OrderWatcher/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            outputs = data.get("outputs", [])
            for out in outputs:
                if out.get("output_index") == output_index:
                    return out.get("consumed_by_tx")
    except Exception as e:
        logger.debug(f"Failed to check UTxO status for {tx_hash}#{output_index}: {e}")
    return None

RELIST_COOLDOWN_S = 1800


def _meta(row: Dict[str, Any]) -> Dict[str, Any]:
    try:
        return json.loads(row.get("metadata_json") or "{}")
    except json.JSONDecodeError:
        return {}


def _save_meta(row_id: int, meta: Dict[str, Any], status: Optional[str] = None) -> None:
    with get_db_connection() as conn:
        if status:
            conn.execute("UPDATE maker_orders SET metadata_json = ?, status = ?, updated_at = ? WHERE id = ?",
                         (json.dumps(meta), status, int(time.time()), row_id))
        else:
            conn.execute("UPDATE maker_orders SET metadata_json = ?, updated_at = ? WHERE id = ?",
                         (json.dumps(meta), int(time.time()), row_id))
        conn.commit()


def _journal_fill(row: Dict[str, Any], meta: Dict[str, Any], side: str, tokens: float, price: Optional[float],
                  entry_ada: Optional[float] = None, exit_ada: Optional[float] = None,
                  realized: Optional[float] = None, fee_ada: Optional[float] = None) -> None:
    """Books a chain-settled fill in the trading journal (markouts + trips). Never raises."""
    try:
        from lib.tools.trading import journal, store
        con = store.connect()
        try:
            oid = row["order_id"]
            strategy = meta.get("strategy") or "legacy"
            new_rules = bool(meta.get("new_rules"))
            if price and price > 0:
                journal.record_fill(con, f"{oid}:{side}", "live", strategy, row["asset"], side, price,
                                    tokens or None, new_rules=new_rules)
            if side == "buy":
                journal.open_trip(con, oid, "live", strategy, row["asset"], price, tokens, entry_ada,
                                  fees_ada=fee_ada, buy_order_id=oid, new_rules=new_rules,
                                  meta={"plan_id": meta.get("plan_id")})
            else:
                if not con.execute("SELECT 1 FROM trips WHERE trip_id=?", (oid,)).fetchone():
                    cost = float(row.get("cost_basis_ada") or 0) or None
                    journal.open_trip(con, oid, "live", strategy, row["asset"],
                                      (cost / tokens) if (cost and tokens) else None, tokens, cost,
                                      buy_order_id=oid, new_rules=new_rules, ts=int(row.get("created_at") or 0) or None)
                journal.close_trip(con, oid, price, exit_ada if exit_ada is not None else 0.0, fees_ada=fee_ada,
                                   sell_order_id=row.get("sell_tx_id") or row.get("tx_id"), net_pnl_ada=realized)
        finally:
            con.close()
    except Exception as e:
        logger.warning(f"[{row.get('order_id')}] journal hook failed: {type(e).__name__}: {e}")


def poll_order_lifecycle_once() -> Dict[str, Any]:
    """Single polling cycle driven by chain truth (lib/tools/cardano_orders.py).

    For every resting order the order UTxO is decoded and classified OPEN / EXPIRED /
    FILLED / CANCELLED. Fills are booked from what the batcher actually paid to our
    address (not targets or whole-wallet balances). Expired orders emit
    'cardano/order_expired' once and are reclaimed automatically only when
    GEORGE_AUTO_RECLAIM_EXPIRED=1 and the george spending policy allows it.
    INVENTORY_HOLD cycles re-emit 'cardano/maker_filled' at most every 30 minutes and
    never for inventory that came back from a cancelled sell unless GEORGE_AUTO_RELIST=1.
    """
    from lib.tools import cardano_orders as co

    with get_db_connection() as conn:
        cur = conn.execute("SELECT * FROM maker_orders WHERE status IN ('PENDING_BUY', 'PENDING_SELL', 'INVENTORY_HOLD')")
        rows = [dict(r) for r in cur.fetchall()]
    if not rows:
        return {"status": "idle", "pending_count": 0, "fills_detected": 0}

    our_addr, our_pkh = co.default_wallet()
    report: List[Dict[str, Any]] = []
    fills = 0
    now = int(time.time())

    for row in rows:
        meta = _meta(row)
        status = row["status"]
        ord_id = row["order_id"]

        if status == "INVENTORY_HOLD":
            # Explicit reactor isolation: Skip inventory managed by stop_reactor (which has its own OCO bracket exit)
            if meta.get("managed_by") == "stop_reactor" or meta.get("source") == "stop_reactor":
                report.append({"order_id": ord_id, "status": status, "note": "managed by stop_reactor OCO bracket"})
                continue
            relist_ok = not meta.get("relist_blocked") or os.environ.get("GEORGE_AUTO_RELIST") == "1"
            recent = now - int(meta.get("fill_emitted_at", 0)) < RELIST_COOLDOWN_S
            claim_expired = (now - int(meta.get("sell_claim_at", 0)) >= RELIST_COOLDOWN_S)
            if float(row["tokens_filled"] or 0) > 0 and relist_ok and not recent and (not meta.get("sell_claim_at") or claim_expired):
                emit_event_to_bus("cardano/maker_filled", {
                    "order_id": ord_id, "asset": row["asset"], "tokens_filled": float(row["tokens_filled"]),
                    "net_cost_basis_ada": float(row["cost_basis_ada"]), "timestamp": now,
                    "is_simulated": str(row.get("tx_id") or "").startswith("sim_")})
                meta["fill_emitted_at"] = now
                _save_meta(row["id"], meta)
            report.append({"order_id": ord_id, "status": status, "relist_blocked": bool(meta.get("relist_blocked"))})
            continue

        ref = (row.get("sell_tx_id") or row.get("tx_id")) if status == "PENDING_SELL" else row.get("tx_id")
        if not ref or str(ref).startswith("sim_"):
            report.append({"order_id": ord_id, "status": status, "note": "simulated row; not on chain"})
            continue
        try:
            utxo_ref = meta.get("order_utxo") if meta.get("order_utxo", "").startswith(ref) else None
            if not utxo_ref:
                utx = co.bf_get(f"/txs/{ref}/utxos")
                out = next((o for o in utx["outputs"] if o.get("data_hash")), None)
                if not out:
                    report.append({"order_id": ord_id, "status": status, "note": "no datum output in order tx"})
                    continue
                utxo_ref = f"{ref}#{out['output_index']}"
            h, ix = utxo_ref.split("#")
            d = co.describe_order_output(h, int(ix), our_pkh=our_pkh)
        except Exception as e:
            logger.warning(f"[{ord_id}] chain lookup failed: {e}")
            report.append({"order_id": ord_id, "status": status, "error": str(e)})
            continue

        meta.update({"protocol": d["protocol"], "order_utxo": d["utxo"], "onchain_status": d["status"],
                     "deadline_iso": d["deadline_iso"], "checked_at": now})

        if d["status"] == "OPEN":
            _save_meta(row["id"], meta)

        elif d["status"] == "EXPIRED":
            if not meta.get("expired_emitted"):
                meta["expired_emitted"] = now
                emit_event_to_bus("cardano/order_expired", {
                    "order_id": ord_id, "asset": row["asset"], "utxo": d["utxo"], "protocol": d["protocol"],
                    "deadline_iso": d["deadline_iso"], "locked_value": d["locked_value"],
                    "action_recommended": "reclaim"})
            if os.environ.get("GEORGE_AUTO_RECLAIM_EXPIRED") == "1" and not meta.get("auto_reclaim_tx"):
                from lib.tools.wallet import policy
                if policy.check("george", "reclaim")["allowed"]:
                    r = co.reclaim_order(d["utxo"], execute=True, actor="george", wait=False)
                    meta["auto_reclaim_tx"] = r.get("tx_id")
                    meta["auto_reclaim_status"] = r.get("status")
            _save_meta(row["id"], meta)

        elif d["status"] == "FILLED":
            st = co.settlement_to(d["consumed_by_tx"], our_addr)
            unit = co.asset_unit(row["asset"])
            dec = co.asset_decimals(row["asset"])
            if status == "PENDING_BUY":
                tokens = st.get(unit, 0) / 10 ** dec
                ada_back = st.get("lovelace", 0) / 1e6
                locked_ada = d["locked_value"].get("lovelace", 0) / 1e6
                cost_basis = locked_ada - ada_back + float(row["l1_tx_fee_ada"] or 0)
                fill_info = mark_buy_order_filled(ord_id, tokens, cost_basis)
                actual_tokens = fill_info.get("tokens_filled", tokens) if isinstance(fill_info, dict) else tokens
                actual_cost = fill_info.get("cost_basis_ada", cost_basis) if isinstance(fill_info, dict) else cost_basis
                emit_event_to_bus("cardano/maker_filled", {
                    "order_id": ord_id, "buy_tx_id": ref, "consumed_by_tx": d["consumed_by_tx"],
                    "asset": row["asset"], "tokens_filled": actual_tokens, "net_cost_basis_ada": round(actual_cost, 6),
                    "ada_refunded": ada_back, "timestamp": now,
                    "is_consolidated": fill_info.get("is_consolidated", False) if isinstance(fill_info, dict) else False,
                    "consolidated_from": fill_info.get("consolidated_from", []) if isinstance(fill_info, dict) else []})
                meta.update({"fill_tx": d["consumed_by_tx"], "fill_emitted_at": now})
                _save_meta(row["id"], meta)
                _journal_fill(row, meta, "buy", float(actual_tokens or 0),
                              (float(actual_cost) / float(actual_tokens)) if actual_tokens else None,
                              entry_ada=float(actual_cost), fee_ada=float(row["l1_tx_fee_ada"] or 0))
            else:
                ada_received = st.get("lovelace", 0) / 1e6
                locked_ada = d["locked_value"].get("lovelace", 0) / 1e6
                sell_fee = co.tx_fee_ada(ref)
                net_exit = ada_received - locked_ada - sell_fee
                cost_basis = float(row["cost_basis_ada"] or 0)
                realized = (net_exit - cost_basis) if cost_basis > 0 else 0.0
                mark_cycle_completed(ord_id, realized)
                meta.update({"sell_fill_tx": d["consumed_by_tx"], "ada_received": ada_received,
                             "net_exit_ada": round(net_exit, 6)})
                _save_meta(row["id"], meta)
                sold = float(row["tokens_filled"] or row["tokens_target"] or 0)
                tgt = float(row["sell_target_ada"] or row["capital_ada"] or 0)
                _journal_fill(row, meta, "sell", sold,
                              ((tgt / sold) if (tgt and sold) else ((net_exit / sold) if sold else None)),
                              exit_ada=net_exit, realized=(realized if cost_basis > 0 else None), fee_ada=sell_fee)
                emit_event_to_bus("cardano/maker_cycle_completed", {
                    "order_id": ord_id, "sell_tx_id": ref, "consumed_by_tx": d["consumed_by_tx"],
                    "asset": row["asset"], "ada_received": ada_received, "net_exit_ada": round(net_exit, 6),
                    "realized_profit_ada": round(realized, 6), "timestamp": now})
            fills += 1

        elif d["status"] == "CANCELLED":
            if status == "PENDING_SELL":
                meta.update({"relist_blocked": True, "cancel_tx": d["consumed_by_tx"]})
                meta.pop("sell_claim_at", None)
                _save_meta(row["id"], meta, status="INVENTORY_HOLD")
            else:
                meta["cancel_tx"] = d["consumed_by_tx"]
                _save_meta(row["id"], meta, status="CANCELLED")

        report.append({"order_id": ord_id, "db_status": status, "onchain": d["status"], "protocol": d["protocol"],
                       "utxo": d["utxo"], "deadline": d["deadline_iso"]})

    return {"status": "ok", "pending_count": len(rows), "fills_detected": fills, "orders": report}


def simulate_fill(order_id_or_asset: str) -> Dict[str, Any]:
    """Test helper: deterministically marks an active order filled and emits the bus event."""
    row = None
    sim = False
    for is_sim in (False, True):
        with get_db_connection(is_simulated=is_sim) as conn:
            cur = conn.execute(
                "SELECT * FROM maker_orders WHERE order_id = ? OR asset = ? ORDER BY id DESC LIMIT 1",
                (order_id_or_asset, order_id_or_asset.upper()),
            )
            r = cur.fetchone()
            if r:
                row = r
                sim = is_sim
                break

    if not row:
        capital = 120.0
        tokens_target = 51369.0 if order_id_or_asset.upper() == "SNEK" else 7720.0
        ord_id = record_new_order(
            asset=order_id_or_asset.upper(),
            direction="BUY",
            capital_ada=capital,
            target_price_ada=capital / tokens_target,
            tokens_target=tokens_target,
            tx_id=f"sim_tx_{os.urandom(8).hex()}",
            l1_fee_ada=0.18,
            batcher_fee_ada=1.80,
            is_simulated=True,
        )
        sim = True
        with get_db_connection(is_simulated=True) as conn:
            cur = conn.execute("SELECT * FROM maker_orders WHERE order_id = ?", (ord_id,))
            row = cur.fetchone()

    ord_id = row["order_id"]
    asset = row["asset"]
    capital = float(row["capital_ada"])
    tokens_target = float(row["tokens_target"])
    cost_basis = capital + 1.98  # 1.80 batcher + 0.18 L1 fee

    fill_info = mark_buy_order_filled(ord_id, tokens_target, cost_basis, is_simulated=sim)
    actual_tokens = fill_info.get("tokens_filled", tokens_target) if isinstance(fill_info, dict) else tokens_target
    actual_cost = fill_info.get("cost_basis_ada", cost_basis) if isinstance(fill_info, dict) else cost_basis

    payload = {
        "order_id": ord_id,
        "buy_tx_id": row["tx_id"],
        "asset": asset,
        "capital_in_ada": capital,
        "tokens_filled": actual_tokens,
        "net_cost_basis_ada": actual_cost,
        "batcher_fee_ada": 1.80,
        "tx_fee_ada": 0.18,
        "timestamp": int(time.time()),
        "is_simulated": True,
        "is_consolidated": fill_info.get("is_consolidated", False) if isinstance(fill_info, dict) else False,
        "consolidated_from": fill_info.get("consolidated_from", []) if isinstance(fill_info, dict) else [],
    }
    emit_event_to_bus("cardano/maker_filled", payload)
    return {
        "status": "success",
        "action": "simulated_fill",
        "order_id": ord_id,
        "asset": asset,
        "cost_basis_ada": actual_cost,
        "tokens_filled": actual_tokens,
        "is_consolidated": fill_info.get("is_consolidated", False) if isinstance(fill_info, dict) else False,
        "consolidated_from": fill_info.get("consolidated_from", []) if isinstance(fill_info, dict) else [],
    }

def run_daemon(interval_sec: int = 60) -> None:
    """Runs continuous polling loop."""
    logger.info(f"Starting Cardano Order Watcher Daemon (Poll interval: {interval_sec}s)...")
    WATCHER_PID_FILE.parent.mkdir(parents=True, exist_ok=True)
    WATCHER_PID_FILE.write_text(str(os.getpid()))

    def handle_exit(signum, frame):
        logger.info("Order Watcher Daemon shutting down gracefully...")
        if WATCHER_PID_FILE.exists():
            WATCHER_PID_FILE.unlink(missing_ok=True)
        sys.exit(0)

    signal.signal(signal.SIGINT, handle_exit)
    signal.signal(signal.SIGTERM, handle_exit)

    while True:
        try:
            res = poll_order_lifecycle_once()
            logger.debug(f"Poll completed: {res}")
        except Exception as e:
            logger.error(f"Error in watcher poll cycle: {e}")
        time.sleep(interval_sec)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Cardano Order Watcher Daemon (Path D)")
    parser.add_argument("--daemon", action="store_true", help="Run as long-running background daemon")
    parser.add_argument("--once", action="store_true", help="Execute single polling pass and exit")
    parser.add_argument("--simulate-fill", type=str, metavar="ASSET_OR_ORDER_ID", help="Simulate a buy fill event for testing")
    parser.add_argument("--interval", type=int, default=60, help="Polling interval in seconds (default: 60)")
    parser.add_argument("--json", action="store_true", help="Output pure JSON")
    args = parser.parse_args()

    if args.simulate_fill:
        res = simulate_fill(args.simulate_fill)
        print(json.dumps(res, indent=2))
    elif args.once:
        res = poll_order_lifecycle_once()
        print(json.dumps(res, indent=2))
    elif args.daemon:
        run_daemon(interval_sec=args.interval)
    else:
        res = poll_order_lifecycle_once()
        print(json.dumps(res, indent=2))
