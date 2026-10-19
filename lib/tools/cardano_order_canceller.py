#!/usr/bin/env python3
"""
Sovereign Cardano Order Canceller & Emergency Reclaim Engine (Path D)
Autonomously reclaims resting limit orders and stuck AMM swap orders back to George's sovereign hot wallet.

Capabilities:
1. Reclaims orders from MinswapV2, Spectrum, SundaeSwap, and other Cardano AMM order validators.
2. Dynamically fetches on-chain script CBOR and script type (PlutusV1/PlutusV2) via Blockfrost.
3. Constructs Plutus Refund/Cancel transactions (Redeemer Constr 0 []) signed by George's private key.
4. Preserves 100% of the locked token and refundable ADA deposits (paying transaction fees from external wallet UTxOs).
5. Updates local maker_orders.db state and emits 'cardano/order_cancelled' event onto the POSIX FIFO bus.
"""

import sys
import os
import json
import time
import urllib.request
import urllib.error
import logging
from pathlib import Path
from typing import Optional, Any, Dict, List

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)

from pycardano import (
    BlockFrostChainContext,
    Network,
    Address,
    TransactionBuilder,
    Transaction,
    TransactionWitnessSet,
    PaymentSigningKey,
    PlutusV1Script,
    PlutusV2Script,
    Redeemer,
    PlutusData,
    UTxO,
)

from lib.tools.cardano_dex_swapper import load_env_vars, WALLET_KEY_FILE
from lib.tools.cardano_trader import normalize_blockfrost_base_url
from lib.tools.cardano_maker_db import get_db_connection

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", stream=sys.stderr)
logger = logging.getLogger("cardano_order_canceller")

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path.home() / "blue-lodge"))
EVENT_BUS_FIFO = LODGE_DIR / ".george" / "ipc" / "event_bus.fifo"


class RefundRedeemer(PlutusData):
    """Standard Refund/Cancel Redeemer (Constructor 0) used across Cardano DEX Order Scripts."""
    CONSTR_ID = 0


def emit_cancel_event(payload: Dict[str, Any]) -> None:
    """Emits 'cardano/order_cancelled' to POSIX FIFO event bus."""
    envelope = json.dumps({
        "event_id": f"evt_cancel_{int(time.time())}_{os.urandom(3).hex()}",
        "type": "cardano/order_cancelled",
        "event_type": "cardano/order_cancelled",
        "source": "cardano_order_canceller",
        "timestamp": int(time.time()),
        "payload": payload,
    })
    if EVENT_BUS_FIFO.exists():
        try:
            fifo_fd = os.open(str(EVENT_BUS_FIFO), os.O_WRONLY | os.O_NONBLOCK)
            with os.fdopen(fifo_fd, "w") as f:
                f.write(envelope + "\n")
            logger.info("Emitted cardano/order_cancelled to FIFO")
        except Exception as e:
            logger.debug(f"FIFO emit skipped: {e}")


def fetch_script_cbor_and_type(script_hash: str, bf_id: str, bf_base: str) -> tuple[bytes, str]:
    """Fetches script CBOR and type (plutusV1 or plutusV2) from Blockfrost."""
    info_url = f"{bf_base}/scripts/{script_hash}"
    cbor_url = f"{bf_base}/scripts/{script_hash}/cbor"

    headers = {"project_id": bf_id, "User-Agent": "BlueLodge-OrderCanceller/1.0"}

    # 1. Fetch Script Metadata
    req_info = urllib.request.Request(info_url, headers=headers)
    with urllib.request.urlopen(req_info, timeout=12) as resp:
        info_data = json.loads(resp.read().decode())
        script_type = info_data.get("type", "plutusV2")

    # 2. Fetch Script CBOR
    req_cbor = urllib.request.Request(cbor_url, headers=headers)
    with urllib.request.urlopen(req_cbor, timeout=12) as resp:
        cbor_data = json.loads(resp.read().decode())
        cbor_hex = cbor_data.get("cbor", "")

    return bytes.fromhex(cbor_hex), script_type


def cancel_resting_order(
    tx_hash: Optional[str] = None,
    order_id: Optional[str] = None,
    script_addr_str: Optional[str] = None,
    output_index: int = 0,
    execute: bool = False,
) -> Dict[str, Any]:
    """
    Reclaims a resting order back to the hot wallet.

    Delegates to lib.tools.cardano_orders, which reads the on-chain datum, refuses to
    build unless the datum owner is our key, selects the redeemer that passes Plutus
    evaluation, and (when execute=True) verifies on-chain that the order UTxO was
    consumed by our tx and reports the wallet balance delta.
    """
    from lib.tools import cardano_orders

    if order_id and not tx_hash:
        with get_db_connection() as conn:
            row = conn.execute(
                "SELECT * FROM maker_orders WHERE order_id = ? OR tx_id = ? OR sell_tx_id = ?",
                (order_id, order_id, order_id),
            ).fetchone()
        if not row:
            raise ValueError(f"order {order_id} not found in maker_orders.db")
        row = dict(row)
        tx_hash = (row.get("sell_tx_id") or row.get("tx_id")) if row.get("status") == "PENDING_SELL" else (row.get("tx_id") or row.get("sell_tx_id"))
    if not tx_hash:
        raise ValueError("Must provide either --order-id or --tx-in")

    clean_tx = tx_hash.split("#")[0].strip()
    if "#" in tx_hash:
        output_index = int(tx_hash.split("#")[1])
    else:
        # Locate the datum-bearing script output of the order tx.
        utx = cardano_orders.bf_get(f"/txs/{clean_tx}/utxos")
        for o in utx.get("outputs", []):
            if o.get("data_hash") and (script_addr_str is None or o["address"] == script_addr_str):
                output_index = o["output_index"]
                break

    res = cardano_orders.reclaim_order(f"{clean_tx}#{output_index}", execute=execute)
    if res.get("status") != "ok":
        raise ValueError(res.get("message", "reclaim failed"))
    locked = res.get("expected_return", {})

    from lib.tools.cardano_maker_db import cancel_linked_stop_triggers
    if order_id:
        cancel_linked_stop_triggers(order_id, reason="order_reclaimed_via_canceller")
    if tx_hash:
        cancel_linked_stop_triggers(clean_tx, reason="order_reclaimed_via_canceller")

    return {
        "status": "success",
        "action": "order_cancelled" if execute else "order_cancel_dry_run",
        "dry_run": not execute,
        "cancel_tx_id": res["tx_id"],
        "reclaimed_utxo": f"{clean_tx}#{output_index}",
        "reclaimed_ada": round(locked.get("lovelace", 0) / 1_000_000, 6),
        "reclaimed_tokens": {k: v for k, v in locked.items() if k != "lovelace"},
        "tx_fee_ada": round(res.get("fee_ada", 0), 6),
        "protocol": res["order"]["protocol"],
        "order_status": res["order"]["status"],
        "redeemer_constr": res.get("redeemer_constr"),
        "evaluation": res.get("attempts"),
        "verification": res.get("verification"),
        "order_script": res["order"]["script_address"],
        "cardanoscan_url": res.get("cardanoscan_url"),
    }


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Sovereign Cardano Order Canceller & Emergency Reclaim")
    parser.add_argument("--order-id", type=str, help="Order ID from maker_orders.db to cancel")
    parser.add_argument("--tx-in", type=str, help="Target UTxO (<tx_hash>#<index>) to cancel")
    parser.add_argument("--script-addr", type=str, help="Optional script address override")
    parser.add_argument("--execute", action="store_true", help="Execute and broadcast live transaction on Mainnet")
    parser.add_argument("--dry-run", action="store_true", default=True, help="Dry run simulation mode")
    parser.add_argument("--json", action="store_true", help="Output pure JSON")
    args = parser.parse_args()

    is_exec = args.execute

    try:
        res = cancel_resting_order(
            tx_hash=args.tx_in,
            order_id=args.order_id,
            script_addr_str=args.script_addr,
            execute=is_exec,
        )
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            mode = "LIVE" if is_exec else "DRY-RUN"
            print(f"=== ORDER CANCELLATION [{mode}] ===")
            print(f"  Tx ID: {res['cancel_tx_id']}")
            print(f"  Reclaimed UTxO: {res['reclaimed_utxo']}")
            print(f"  Reclaimed ADA: {res['reclaimed_ada']} ADA")
            print(f"  Reclaimed Assets: {res['reclaimed_tokens']}")
            print(f"  L1 Tx Fee: {res['tx_fee_ada']} ADA")
            print(f"  Cardanoscan: {res['cardanoscan_url']}")
    except Exception as e:
        if args.json:
            print(json.dumps({"status": "error", "message": str(e)}, indent=2))
        else:
            print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
