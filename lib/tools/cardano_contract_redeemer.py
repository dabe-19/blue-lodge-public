#!/usr/bin/env python3
"""Sovereign Cardano Plutus V2 Contract Redeemer / Yield Harvester.

Redeems or reclaims locked UTxOs from the Plutus V2 Escrow contract back into
George's hot wallet or Trezor vault, executing the on-chain Plutus V2 validator.
"""

from __future__ import annotations

import sys
import os
from pathlib import Path

# Auto-bootstrap project virtualenv (Python 3.12 with compiled C-extensions like pycardano)
_VENV_PY = Path(__file__).resolve().parent.parent.parent / ".venv" / "bin" / "python"
if _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)

import argparse
import json
import logging
import warnings
from typing import Any

warnings.filterwarnings("ignore")

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

import pycardano
from lib.tools.cardano_trader import (
    get_blockfrost_client,
    get_wallet_address,
    _WALLETS_DIR,
)
from lib.tools.cardano_contract_deployer import get_plutus_script

logger = logging.getLogger("cardano_redeemer")
logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")


def redeem_contract_funds(
    target_tx_id: str | None = None,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Redeem a locked UTxO from the Plutus V2 contract back to George's wallet."""
    from lib.tools.cardano_trader import load_signing_key
    sk = load_signing_key()
    my_addr = pycardano.Address.from_primitive(get_wallet_address())

    context = get_blockfrost_client()
    script, script_addr = get_plutus_script()

    script_utxos = context.utxos(script_addr)
    if not script_utxos:
        raise ValueError(f"No UTxOs found at script address {script_addr}")

    if target_tx_id:
        selected_utxo = next((u for u in script_utxos if str(u.input.transaction_id) == target_tx_id), None)
        if not selected_utxo:
            raise ValueError(f"UTxO with tx_id {target_tx_id} not found at contract address.")
    else:
        # Pick the latest or highest value UTxO
        selected_utxo = script_utxos[-1]

    # Need a collateral UTxO from George's wallet
    wallet_utxos = context.utxos(my_addr)
    if not wallet_utxos:
        raise ValueError("No UTxOs available in wallet for collateral/fees.")

    redeemer = pycardano.Redeemer(pycardano.Unit())

    tx_builder = pycardano.TransactionBuilder(context)
    tx_builder.add_script_input(
        selected_utxo,
        script=script,
        redeemer=redeemer,
    )
    # Add wallet input for fees and collateral
    tx_builder.add_input_address(my_addr)
    tx_builder.collaterals.append(wallet_utxos[0])

    tx = tx_builder.build_and_sign([sk], change_address=my_addr)
    tx_id = str(tx.transaction_body.id)

    if dry_run:
        return {
            "status": "dry_run",
            "redeemed_tx_id": tx_id,
            "redeemed_utxo": f"{selected_utxo.input.transaction_id}#{selected_utxo.input.index}",
            "amount_ada": selected_utxo.output.amount.coin / 1_000_000,
            "fee_ada": tx.transaction_body.fee / 1_000_000,
        }

    logger.info("Submitting Plutus redemption transaction %s...", tx_id)
    context.submit_tx(tx)
    logger.info("Redemption transaction submitted!")

    return {
        "status": "submitted",
        "action": "PLUTUS_V2_REDEEM",
        "tx_id": tx_id,
        "amount_reclaimed_ada": selected_utxo.output.amount.coin / 1_000_000,
        "fee_ada": tx.transaction_body.fee / 1_000_000,
        "cardanoscan_tx_url": f"https://cardanoscan.io/transaction/{tx_id}",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Redeem funds from Plutus V2 Contract")
    parser.add_argument("--tx-id", type=str, help="Specific UTxO transaction hash to redeem")
    parser.add_argument("--dry-run", action="store_true", help="Build transaction without submitting")
    args = parser.parse_args()

    res = redeem_contract_funds(target_tx_id=args.tx_id, dry_run=args.dry_run)
    print(json.dumps(res, indent=2))


if __name__ == "__main__":
    main()
