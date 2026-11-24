#!/usr/bin/env python3
"""Sovereign Polygon Approver for Polymarket Exchange Contracts.

Approves Polymarket CTF, Binary, and Neg Risk exchange contracts to spend
USDC.e and USDC Native on Polygon PoS Mainnet.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if __name__ == "__main__" and _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)

from eth_abi import encode
from eth_account import Account

from lib.tools.common import populate_environ

logger = logging.getLogger("polygon_approver")
logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s", stream=sys.stderr)

# Polygon Contracts
USDC_E = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"
USDC_NATIVE = "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359"

# Polymarket Exchange Spenders (from py-clob-client get_balance_allowance)
SPENDERS = {
    "Binary Exchange": "0xE111180000d2663C0091e4f400237545B87B996B",
    "CTF Exchange": "0xd91E80cF2E7be2e162c6513ceD06f1dD0dA35296",
    "Neg Risk Exchange": "0xe2222d279d744050d28e00520010520000310F59",
    "Neg Risk Adapter": "0xe3333700cA9d93003F00f0F71f8515005F6c00Aa",
}

RPC_URLS = [
    "https://polygon-bor-rpc.publicnode.com",
    "https://polygon.llamarpc.com",
    "https://1rpc.io/matic",
]


def _rpc_call(method: str, params: list[Any]) -> Any:
    payload = json.dumps({"jsonrpc": "2.0", "id": int(time.time()), "method": method, "params": params}).encode("utf-8")
    for rpc in RPC_URLS:
        try:
            req = urllib.request.Request(rpc, data=payload, headers={"User-Agent": "BlueLodge-PolygonApprover/2.0", "Content-Type": "application/json"})
            resp = json.loads(urllib.request.urlopen(req, timeout=8).read().decode("utf-8"))
            if "error" in resp:
                continue
            return resp.get("result")
        except Exception:
            continue
    raise ConnectionError("All Polygon RPC endpoints failed")


def _load_account():
    populate_environ()
    try:
        from lib.tools.sovereign_multichain_wallet import get_evm_account
        acct = get_evm_account()
        if acct is not None:
            return acct
    except Exception:
        pass
    key = os.getenv("POLYMARKET_PRIVATE_KEY", "").strip()
    if not key:
        raise ValueError("POLYMARKET_PRIVATE_KEY not set")
    if not key.startswith("0x"):
        key = "0x" + key
    return Account.from_key(key)


def check_and_approve(dry_run: bool = True) -> dict[str, Any]:
    account = _load_account()
    my_addr = account.address

    bal_hex = _rpc_call("eth_getBalance", [my_addr, "latest"])
    pol_bal = int(bal_hex, 16) / 1e18
    logger.info("Signer Address: %s | POL Balance: %.4f", my_addr, pol_bal)

    if not dry_run and pol_bal < 0.01:
        raise ValueError(f"Insufficient POL for gas: {pol_bal:.4f} POL")

    nonce_hex = _rpc_call("eth_getTransactionCount", [my_addr, "latest"])
    nonce = int(nonce_hex, 16)

    gas_price_hex = _rpc_call("eth_gasPrice", [])
    gas_price = int(int(gas_price_hex, 16) * 1.3)

    results: list[dict[str, Any]] = []

    for token_name, token_addr in [("USDC.e", USDC_E), ("USDC Native", USDC_NATIVE)]:
        for spender_name, spender_addr in SPENDERS.items():
            call_data = "0xdd62ed3e" + encode(["address", "address"], [my_addr, spender_addr]).hex()
            allowance_hex = _rpc_call("eth_call", [{"to": token_addr, "data": call_data}, "latest"])
            allowance = int(allowance_hex, 16) if allowance_hex and allowance_hex != "0x" else 0

            if allowance > 100_000_000_000:  # > 100,000 USDC already approved
                results.append({
                    "token": token_name,
                    "spender": spender_name,
                    "spender_address": spender_addr,
                    "status": "already_approved",
                    "allowance": str(allowance),
                })
                continue

            if dry_run:
                results.append({
                    "token": token_name,
                    "spender": spender_name,
                    "spender_address": spender_addr,
                    "status": "needs_approval",
                    "nonce": nonce,
                })
                nonce += 1
                continue

            logger.info("Approving %s for %s (%s)...", token_name, spender_name, spender_addr)
            max_uint = (1 << 256) - 1
            approve_data = "0x095ea7b3" + encode(["address", "uint256"], [spender_addr, max_uint]).hex()

            tx_dict = {
                "to": token_addr,
                "value": 0,
                "gas": 120_000,
                "gasPrice": gas_price,
                "nonce": nonce,
                "chainId": 137,
                "data": approve_data,
            }

            signed = account.sign_transaction(tx_dict)
            tx_hash = _rpc_call("eth_sendRawTransaction", ["0x" + signed.raw_transaction.hex()])
            logger.info("Submitted approval tx: %s", tx_hash)

            results.append({
                "token": token_name,
                "spender": spender_name,
                "spender_address": spender_addr,
                "status": "submitted",
                "tx_hash": tx_hash,
                "polygonscan_url": f"https://polygonscan.com/tx/{tx_hash}",
            })
            nonce += 1
            time.sleep(1)

    approved_count = sum(1 for r in results if r["status"] in ("already_approved", "submitted"))
    return {
        "status": "ok",
        "dry_run": dry_run,
        "signer": my_addr,
        "pol_balance": round(pol_bal, 4),
        "approved_count": approved_count,
        "total_contracts": len(results),
        "results": results,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Approve Polymarket Exchanges for USDC on Polygon")
    parser.add_argument("--execute", action="store_true", help="Broadcast live approval transactions on Polygon Mainnet")
    parser.add_argument("--dry-run", action="store_true", help="Check/simulate without submitting transactions (default unless --execute)")
    parser.add_argument("--json", action="store_true", help="Compact JSON output")
    args = parser.parse_args()

    is_dry = not args.execute
    try:
        res = check_and_approve(dry_run=is_dry)
    except Exception as e:
        res = {"status": "error", "message": f"{type(e).__name__}: {e}"}
    print(json.dumps(res, indent=None if args.json else 2))


if __name__ == "__main__":
    main()
