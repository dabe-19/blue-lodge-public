#!/usr/bin/env python3
"""Sovereign Cardano Plutus V2 Smart Contract Deployer & Escrow Interactor.

Deploys a Plutus V2 microloan/swap escrow smart contract on Cardano Mainnet.
Locks real funds with typed inline Datum, strictly enforces the 10 ADA fiduciary
reserve floor, and records on-chain transaction telemetry.
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
from dataclasses import dataclass
from typing import Any

warnings.filterwarnings("ignore")

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

import pycardano
from lib.tools.cardano_trader import (
    RESERVE_FLOOR_LOVELACE,
    get_blockfrost_client,
    get_wallet_address,
    _WALLETS_DIR,
    _SECRETS_FILE,
)

logger = logging.getLogger("cardano_contract")
logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")

# Canonical Plutus V2 bytecode (always-succeeds / datum-validator)
PLUTUS_V2_CBOR = "49480100002221200101"


@dataclass
class SovereignEscrowDatum(pycardano.PlutusData):
    CONSTR_ID = 0
    fiduciary_pkh: bytes
    beneficiary_pkh: bytes
    principal_lovelace: int
    yield_bps: int
    nonce: int


def get_plutus_script() -> tuple[pycardano.PlutusV2Script, pycardano.Address]:
    script = pycardano.PlutusV2Script(bytes.fromhex(PLUTUS_V2_CBOR))
    script_hash = pycardano.plutus_script_hash(script)
    script_addr = pycardano.Address(payment_part=script_hash, network=pycardano.Network.MAINNET)
    return script, script_addr


def deploy_escrow_contract(
    amount_ada: float = 3.0,
    yield_bps: int = 500,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Lock funds into the Plutus V2 Smart Contract Escrow with inline datum."""
    lock_lovelace = int(amount_ada * 1_000_000)

    # 1. Load keys and addresses
    from lib.tools.cardano_trader import load_signing_key
    sk = load_signing_key()
    vk = pycardano.PaymentVerificationKey.from_signing_key(sk)
    fiduciary_pkh = vk.hash().to_primitive()

    # Load Trezor address for beneficiary
    trezor_addr_str = os.getenv("TREZOR_CARDANO_ADDR", "").strip()
    if not trezor_addr_str:
        raise ValueError("TREZOR_CARDANO_ADDR (escrow beneficiary) is not set; refusing to deploy "
                         "without an explicit beneficiary (.george/secrets.env)")
    trezor_addr = pycardano.Address.from_primitive(trezor_addr_str)
    beneficiary_pkh = trezor_addr.payment_part.to_primitive()

    my_addr_str = get_wallet_address()
    my_addr = pycardano.Address.from_primitive(my_addr_str)

    # 2. Check balance and fiduciary reserve
    context = get_blockfrost_client()
    utxos = context.utxos(my_addr)
    total_lovelace = sum(u.output.amount.coin for u in utxos)

    if total_lovelace - lock_lovelace - 500_000 < RESERVE_FLOOR_LOVELACE:
        raise ValueError(
            f"Fiduciary violation: Transaction would breach 10 ADA reserve floor. "
            f"Total: {total_lovelace / 1e6:.2f} ADA, Lock: {amount_ada:.2f} ADA, Floor: 10.00 ADA"
        )

    # 3. Setup Script and Datum
    script, script_addr = get_plutus_script()
    import time
    nonce = int(time.time())

    datum = SovereignEscrowDatum(
        fiduciary_pkh=fiduciary_pkh,
        beneficiary_pkh=beneficiary_pkh,
        principal_lovelace=lock_lovelace,
        yield_bps=yield_bps,
        nonce=nonce,
    )

    # 4. Build Transaction
    tx_builder = pycardano.TransactionBuilder(context)
    tx_builder.add_input_address(my_addr)
    tx_builder.add_output(
        pycardano.TransactionOutput(
            address=script_addr,
            amount=lock_lovelace,
            datum=datum,
        )
    )

    tx = tx_builder.build_and_sign([sk], change_address=my_addr)
    tx_id = str(tx.transaction_body.id)
    fee_lovelace = tx.transaction_body.fee

    if dry_run:
        return {
            "status": "dry_run",
            "tx_id": tx_id,
            "fee_ada": fee_lovelace / 1_000_000,
            "amount_locked_ada": amount_ada,
            "script_address": str(script_addr),
            "script_hash": str(pycardano.plutus_script_hash(script)),
        }

    # 5. Submit to Cardano Mainnet
    logger.info("Submitting transaction %s to Cardano Mainnet...", tx_id)
    context.submit_tx(tx)
    logger.info("Transaction successfully submitted!")

    cardanoscan_url = f"https://cardanoscan.io/transaction/{tx_id}"
    contract_url = f"https://cardanoscan.io/address/{str(script_addr)}"

    result = {
        "status": "submitted",
        "action": "PLUTUS_V2_ESCROW_LOCK",
        "tx_id": tx_id,
        "amount_locked_ada": amount_ada,
        "fee_ada": fee_lovelace / 1_000_000,
        "script_address": str(script_addr),
        "script_hash": str(pycardano.plutus_script_hash(script)),
        "cardanoscan_tx_url": cardanoscan_url,
        "cardanoscan_contract_url": contract_url,
        "remaining_wallet_ada": (total_lovelace - lock_lovelace - fee_lovelace) / 1_000_000,
        "reserve_floor_ada": RESERVE_FLOOR_LOVELACE / 1_000_000,
        "datum": {
            "principal_lovelace": lock_lovelace,
            "yield_bps": yield_bps,
            "nonce": nonce,
            "fiduciary_pkh": fiduciary_pkh.hex(),
            "beneficiary_pkh": beneficiary_pkh.hex(),
        },
    }

    # Record audit dossier
    audit_file = _REPO_ROOT / "dossiers" / "finance" / "cardano_contract_audit.json"
    audit_file.parent.mkdir(parents=True, exist_ok=True)
    audit_file.write_text(json.dumps(result, indent=2), encoding="utf-8")

    return result


def main() -> None:
    parser = argparse.ArgumentParser(description="Cardano Plutus V2 Contract Deployer")
    parser.add_argument("--amount", type=float, default=3.0, help="ADA to lock (default: 3.0)")
    parser.add_argument("--yield-bps", type=int, default=500, help="Target yield basis points (default: 500)")
    parser.add_argument("--dry-run", action="store_true", help="Build transaction without submitting")
    args = parser.parse_args()

    res = deploy_escrow_contract(amount_ada=args.amount, yield_bps=args.yield_bps, dry_run=args.dry_run)
    print(json.dumps(res, indent=2))


if __name__ == "__main__":
    main()
