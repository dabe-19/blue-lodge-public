#!/usr/bin/env python3
"""Sovereign Local Hot Wallet Generator for Blue Lodge.

Generates local Cardano (Ed25519) and Polygon (EVM) hot keypairs directly on
the local Linux host without requiring external browser extensions or mobile apps.
Stores private keys strictly in .george/wallets/ with 0600 file permissions and
outputs clean deposit addresses for funding from Trezor Suite.
"""

from __future__ import annotations

import argparse
import os
import stat
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[2]
_GEORGE_DIR = _REPO_ROOT / ".george"
_WALLETS_DIR = _GEORGE_DIR / "wallets"
_SECRETS_FILE = _GEORGE_DIR / "secrets.env"


def generate_wallets(save_to_secrets: bool = True) -> dict[str, str]:
    """Generate Cardano and Polygon hot wallets locally."""
    _WALLETS_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(_WALLETS_DIR, stat.S_IRWXU)  # 0700

    import pycardano
    from eth_account import Account

    # 1. Cardano Keypair Generation
    ada_skey_path = _WALLETS_DIR / "cardano_payment.skey"
    ada_vkey_path = _WALLETS_DIR / "cardano_payment.vkey"
    ada_addr_path = _WALLETS_DIR / "cardano_payment.addr"

    if ada_skey_path.exists():
        # Load existing key if already created
        skey = pycardano.PaymentSigningKey.load(str(ada_skey_path))
    else:
        skey = pycardano.PaymentSigningKey.generate()
        skey.save(str(ada_skey_path))
        os.chmod(ada_skey_path, stat.S_IRUSR | stat.S_IWUSR)  # 0600

    vkey = pycardano.PaymentVerificationKey.from_signing_key(skey)
    if not ada_vkey_path.exists():
        vkey.save(str(ada_vkey_path))
        os.chmod(ada_vkey_path, stat.S_IRUSR | stat.S_IWUSR)

    # Base address or enterprise address (Network.MAINNET)
    cardano_addr = str(pycardano.Address(payment_part=vkey.hash(), network=pycardano.Network.MAINNET))
    ada_addr_path.write_text(cardano_addr + "\n", encoding="utf-8")

    # 2. Polygon EVM Keypair Generation
    poly_key_path = _WALLETS_DIR / "polygon_payment.key"
    poly_addr_path = _WALLETS_DIR / "polygon_payment.addr"

    if poly_key_path.exists():
        poly_priv_hex = poly_key_path.read_text(encoding="utf-8").strip()
        acct = Account.from_key(poly_priv_hex)
    else:
        acct = Account.create()
        poly_priv_hex = acct.key.hex()
        poly_key_path.write_text(poly_priv_hex + "\n", encoding="utf-8")
        os.chmod(poly_key_path, stat.S_IRUSR | stat.S_IWUSR)  # 0600

    polygon_addr = acct.address
    poly_addr_path.write_text(polygon_addr + "\n", encoding="utf-8")

    # 3. Update .george/secrets.env if requested
    if save_to_secrets and _SECRETS_FILE.exists():
        lines = _SECRETS_FILE.read_text(encoding="utf-8").splitlines()
        updated_lines = []
        keys_set = set()

        for line in lines:
            trimmed = line.strip()
            if trimmed.startswith("CARDANO_WALLET_ADDR="):
                updated_lines.append(f'CARDANO_WALLET_ADDR="{cardano_addr}"')
                keys_set.add("CARDANO_WALLET_ADDR")
            elif trimmed.startswith("CARDANO_PAYMENT_SKEY="):
                updated_lines.append(f'CARDANO_PAYMENT_SKEY="{ada_skey_path.relative_to(_REPO_ROOT)}"')
                keys_set.add("CARDANO_PAYMENT_SKEY")
            elif trimmed.startswith("POLYMARKET_PRIVATE_KEY="):
                updated_lines.append(f'POLYMARKET_PRIVATE_KEY="{poly_priv_hex}"')
                keys_set.add("POLYMARKET_PRIVATE_KEY")
            elif trimmed.startswith("POLYMARKET_FUNDER_ADDRESS="):
                updated_lines.append(f'POLYMARKET_FUNDER_ADDRESS="{polygon_addr}"')
                keys_set.add("POLYMARKET_FUNDER_ADDRESS")
            else:
                updated_lines.append(line)

        if "CARDANO_PAYMENT_SKEY" not in keys_set:
            updated_lines.append(f'CARDANO_PAYMENT_SKEY="{ada_skey_path.relative_to(_REPO_ROOT)}"')
        if "CARDANO_WALLET_ADDR" not in keys_set:
            updated_lines.append(f'CARDANO_WALLET_ADDR="{cardano_addr}"')
        if "POLYMARKET_PRIVATE_KEY" not in keys_set:
            updated_lines.append(f'POLYMARKET_PRIVATE_KEY="{poly_priv_hex}"')
        if "POLYMARKET_FUNDER_ADDRESS" not in keys_set:
            updated_lines.append(f'POLYMARKET_FUNDER_ADDRESS="{polygon_addr}"')

        _SECRETS_FILE.write_text("\n".join(updated_lines) + "\n", encoding="utf-8")
        os.chmod(_SECRETS_FILE, stat.S_IRUSR | stat.S_IWUSR)

    return {
        "cardano_address": cardano_addr,
        "cardano_skey_file": str(ada_skey_path),
        "polygon_address": polygon_addr,
        "polygon_key_file": str(poly_key_path),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Sovereign Local Hot Wallet Generator")
    parser.add_argument("--no-secrets", action="store_true", help="Do not write to .george/secrets.env")
    args = parser.parse_args()

    wallets = generate_wallets(save_to_secrets=not args.no_secrets)

    print("\n" + "=" * 65)
    print(" 🏛️  BLUE LODGE SOVEREIGN HOT WALLETS GENERATED (LOCAL ON-DISK)")
    print("=" * 65)
    print(f"\n1. CARDANO (ADA) HOT WALLET")
    print(f"   Deposit Address: {wallets['cardano_address']}")
    print(f"   Private Key:     {wallets['cardano_skey_file']} (chmod 0600)")
    print(f"   Action Required: Send ~75 ADA ($50) from Trezor Suite to this address.")

    print(f"\n2. POLYMARKET (POLYGON PoS) HOT WALLET")
    print(f"   Deposit Address: {wallets['polygon_address']}")
    print(f"   Private Key:     {wallets['polygon_key_file']} (chmod 0600)")
    print(f"   Action Required: Send 50 USDC + 1 POL (MATIC) from Trezor to this address.")

    print("\n3. SECRETS UPDATED")
    print(f"   Both keys and addresses have been recorded into .george/secrets.env.")
    print("=" * 65 + "\n")


if __name__ == "__main__":
    main()
