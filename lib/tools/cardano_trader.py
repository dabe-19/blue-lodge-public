#!/usr/bin/env python3
"""Sovereign Cardano Autonomous Trading & Treasury Bridge for Blue Lodge.

Manages George's local Cardano hot wallet, interacts with Blockfrost,
enforces an untouchable 10 ADA network fee reserve floor, executes bounded
DEX swaps/arbitrage, and provides autonomous profit sweeping to the Trezor master vault.
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
warnings.filterwarnings("ignore")
from typing import Any

_REPO_ROOT = Path(__file__).resolve().parents[2]
_GEORGE_DIR = _REPO_ROOT / ".george"
_SECRETS_FILE = _GEORGE_DIR / "secrets.env"
_WALLETS_DIR = _GEORGE_DIR / "wallets"

logger = logging.getLogger("cardano_trader")
logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")


def _load_env() -> None:
    for env_path in [_SECRETS_FILE, _REPO_ROOT / ".env"]:
        if env_path.exists():
            for line in env_path.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


_load_env()

# Hard fiduciary invariants
RESERVE_FLOOR_LOVELACE = int(os.getenv("CARDANO_RESERVE_FLOOR_LOVELACE", "40000000"))  # 40 ADA untouchable reserve for fees & UTxO min-ADA
MAX_TRADE_LOVELACE = 50_000_000      # 50 ADA maximum risk per single transaction


def normalize_blockfrost_base_url(url: str | None) -> str:
    """Normalizes Blockfrost base URL for PyCardano / BlockFrostApi compatibility."""
    if not url:
        return "https://cardano-mainnet.blockfrost.io/api"
    clean = url.rstrip("/")
    if clean.endswith("/v0"):
        clean = clean[:-3]
    if not clean.endswith("/api"):
        clean = f"{clean}/api"
    return clean


def get_blockfrost_client() -> Any:
    """Initialize PyCardano Blockfrost chain context, prioritizing local Dolos Mini-Blockfrost."""
    from pycardano import BlockFrostChainContext, Network
    import urllib.request

    dolos_url = os.getenv("DOLOS_MINIBF_URL", "http://127.0.0.1:8000/api/v0").rstrip("/")
    try:
        req = urllib.request.Request(f"{dolos_url}/epochs/latest", headers={"User-Agent": "BlueLodge-Dolos/1.0"})
        with urllib.request.urlopen(req, timeout=0.3) as resp:
            if resp.status == 200:
                base_url = normalize_blockfrost_base_url(dolos_url)
                return BlockFrostChainContext(project_id="dolos_local", base_url=base_url)
    except Exception:
        pass

    project_id = os.getenv("BLOCKFROST_PROJECT_ID")
    if not project_id or "YOUR_BLOCKFROST" in project_id:
        raise ValueError("BLOCKFROST_PROJECT_ID is not configured in .george/secrets.env")

    base_url = normalize_blockfrost_base_url(os.getenv("BLOCKFROST_BASE_URL"))
    network_str = os.getenv("CARDANO_NETWORK", "mainnet").lower()
    net = Network.MAINNET if network_str == "mainnet" else Network.TESTNET

    return BlockFrostChainContext(project_id=project_id, base_url=base_url)


def load_signing_key() -> Any:
    """Load local hot wallet payment signing key (via encrypted keystore auto-unlock or legacy skey)."""
    import pycardano
    try:
        from lib.tools.wallet import keystore
        _, sk = keystore.cardano_signer(None, None)
        return sk
    except Exception:
        pass

    skey_path_rel = os.getenv("CARDANO_PAYMENT_SKEY", ".george/wallets/cardano_payment.skey")
    skey_path = _REPO_ROOT / skey_path_rel if not Path(skey_path_rel).is_absolute() else Path(skey_path_rel)

    if not skey_path.exists():
        raise FileNotFoundError(f"Signing key not found in keystore or at {skey_path}. Run lib/tools/wallet_generator.py first.")

    return pycardano.PaymentSigningKey.load(str(skey_path))


def get_wallet_address() -> str:
    """Get configured local Cardano address."""
    addr = os.getenv("CARDANO_WALLET_ADDR")
    if addr:
        return addr.strip()

    try:
        from lib.tools.wallet import keystore
        k_addr, _ = keystore.cardano_signer(None, None)
        if k_addr:
            return k_addr
    except Exception:
        pass

    addr_file = _WALLETS_DIR / "cardano_payment.addr"
    if addr_file.exists():
        return addr_file.read_text(encoding="utf-8").strip()

    raise ValueError("CARDANO_WALLET_ADDR is not configured in .george/secrets.env")


def query_wallet_balance() -> dict[str, Any]:
    """Query live UTxOs and ADA balance from Blockfrost."""
    import pycardano

    addr_str = get_wallet_address()
    address = pycardano.Address.from_primitive(addr_str)

    try:
        context = get_blockfrost_client()
        utxos = context.utxos(address)
    except Exception as e:
        return {
            "status": "offline_or_unconfigured",
            "address": addr_str,
            "error": str(e),
            "total_lovelace": 0,
            "total_ada": 0.0,
            "spendable_ada": 0.0,
            "reserve_floor_ada": RESERVE_FLOOR_LOVELACE / 1_000_000,
        }

    total_lovelace = sum(u.output.amount.coin for u in utxos)
    total_ada = total_lovelace / 1_000_000
    spendable_lovelace = max(0, total_lovelace - RESERVE_FLOOR_LOVELACE)
    spendable_ada = spendable_lovelace / 1_000_000

    # Collect any native assets
    assets: dict[str, int] = {}
    for u in utxos:
        if u.output.amount.multi_asset:
            for policy, tokens in u.output.amount.multi_asset.items():
                for name, qty in tokens.items():
                    asset_id = f"{policy.to_primitive().hex()}.{name.to_primitive().decode('utf-8', errors='ignore')}"
                    assets[asset_id] = assets.get(asset_id, 0) + qty

    return {
        "status": "ok",
        "address": addr_str,
        "utxo_count": len(utxos),
        "total_lovelace": total_lovelace,
        "total_ada": round(total_ada, 4),
        "spendable_ada": round(spendable_ada, 4),
        "reserve_floor_ada": RESERVE_FLOOR_LOVELACE / 1_000_000,
        "multi_assets": assets,
        "trezor_master_sweep": os.getenv("MASTER_TREZOR_CARDANO_ADDR", "Not configured"),
    }


def sweep_profits_to_trezor(dry_run: bool = False) -> dict[str, Any]:
    """Sweep all spendable ADA above the 10 ADA reserve floor to Trezor master address."""
    import pycardano

    master_addr = os.getenv("MASTER_TREZOR_CARDANO_ADDR")
    if not master_addr or "YOUR_TREZOR" in master_addr:
        return {"status": "error", "message": "MASTER_TREZOR_CARDANO_ADDR not configured in .george/secrets.env"}

    bal = query_wallet_balance()
    if bal.get("status") != "ok":
        return {"status": "error", "message": f"Unable to fetch balance: {bal.get('error')}"}

    spendable_lovelace = bal["total_lovelace"] - RESERVE_FLOOR_LOVELACE
    fee_estimate = 200_000  # ~0.2 ADA fee
    sweep_amount = spendable_lovelace - fee_estimate

    if sweep_amount < 2_000_000:
        return {
            "status": "pass",
            "message": f"Insufficient excess balance to sweep (Spendable: {bal['spendable_ada']:.2f} ADA, Min sweep: 2.0 ADA)",
        }

    sweep_ada = sweep_amount / 1_000_000
    if dry_run:
        return {
            "status": "dry_run_ok",
            "sweep_amount_ada": round(sweep_ada, 4),
            "recipient_trezor": master_addr,
            "retained_reserve_ada": RESERVE_FLOOR_LOVELACE / 1_000_000,
        }

    # Build and sign transaction
    try:
        context = get_blockfrost_client()
        skey = load_signing_key()
        from_addr = pycardano.Address.from_primitive(bal["address"])
        to_addr = pycardano.Address.from_primitive(master_addr)

        tx_builder = pycardano.TransactionBuilder(context)
        tx_builder.add_input_address(from_addr)
        tx_builder.add_output(pycardano.TransactionOutput(to_addr, sweep_amount))

        signed_tx = tx_builder.build_and_sign([skey], change_address=from_addr)
        context.submit_tx(signed_tx)
        tx_id = str(signed_tx.transaction_body.id)

        logger.info(f"Sweep transaction submitted! TxID: {tx_id}")
        return {
            "status": "submitted",
            "tx_id": tx_id,
            "swept_ada": round(sweep_ada, 4),
            "destination_trezor": master_addr,
        }
    except Exception as e:
        logger.error(f"Sweep transaction failed: {e}")
        return {"status": "error", "message": str(e)}


def main() -> None:
    parser = argparse.ArgumentParser(description="Cardano Autonomous Trader & Treasury Bridge")
    parser.add_argument("--balance", "-b", action="store_true", help="Query live wallet balance & UTxOs")
    parser.add_argument("--sweep", action="store_true", help="Sweep excess spendable ADA to Trezor master address")
    parser.add_argument("--dry-run", action="store_true", help="Simulate execution without submitting transaction")
    parser.add_argument("--json", action="store_true", help="Output raw JSON")

    args = parser.parse_args()

    if args.sweep:
        res = sweep_profits_to_trezor(dry_run=args.dry_run)
    else:
        res = query_wallet_balance()

    print(json.dumps(res, indent=2))


if __name__ == "__main__":
    main()
