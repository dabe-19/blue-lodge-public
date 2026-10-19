#!/usr/bin/env python3
"""Sovereign Polygon DeFi Swapper: Converts POL -> WPOL -> USDC.e via Uniswap V3.

Enables autonomous self-funding for Polymarket CLOB collateral directly on-chain.
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

from eth_abi import encode, decode
from eth_account import Account

_REPO_ROOT = Path(__file__).resolve().parents[2]
_SECRETS_FILE = _REPO_ROOT / ".george" / "secrets.env"

logger = logging.getLogger("polygon_swapper")
logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")

WPOL_ADDR = "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270"
USDC_E_ADDR = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"
UNISWAP_V3_ROUTER = "0xE592427A0AEce92De3Edee1F18E0157C05861564"

RPC_URLS = [
    "https://polygon.llamarpc.com",
    "https://1rpc.io/matic",
    "https://polygon.drpc.org",
    "https://polygon-bor-rpc.publicnode.com",
]


def _rpc_call(method: str, params: list[Any]) -> Any:
    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": int(time.time() * 1000),
        "method": method,
        "params": params,
    }).encode("utf-8")

    last_err = None
    for rpc in RPC_URLS:
        try:
            req = urllib.request.Request(
                rpc,
                data=payload,
                headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)", "Content-Type": "application/json"},
            )
            resp = json.loads(urllib.request.urlopen(req, timeout=10).read().decode("utf-8"))
            if "error" in resp:
                last_err = resp["error"]
                continue
            return resp.get("result")
        except Exception as e:
            last_err = e
            continue
    raise ConnectionError(f"All Polygon RPCs failed. Last error: {last_err}")


def swap_pol_to_usdc(amount_pol: float = 15.0, dry_run: bool = False) -> dict[str, Any]:
    # 1. Load key
    if _SECRETS_FILE.exists():
        for line in _SECRETS_FILE.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))

    key = os.getenv("POLYMARKET_PRIVATE_KEY")
    account = Account.from_key(key)
    my_addr = account.address

    # 2. Check balance
    bal_hex = _rpc_call("eth_getBalance", [my_addr, "latest"])
    pol_bal = int(bal_hex, 16) / 1e18
    logger.info("Signer: %s | Current POL Balance: %.4f", my_addr, pol_bal)

    if pol_bal < amount_pol + 1.0:
        raise ValueError(f"Insufficient POL: has {pol_bal:.4f}, requested swap {amount_pol} + 1.0 reserve for gas")

    amount_wei = int(amount_pol * 1e18)

    nonce_hex = _rpc_call("eth_getTransactionCount", [my_addr, "latest"])
    nonce = int(nonce_hex, 16)

    gas_price_hex = _rpc_call("eth_gasPrice", [])
    gas_price = int(int(gas_price_hex, 16) * 1.35)

    if dry_run:
        return {
            "status": "dry_run",
            "amount_pol": amount_pol,
            "nonce": nonce,
            "gas_price": gas_price,
        }

    # Step A: Deposit POL -> WPOL
    logger.info("Step 1: Wrapping %.2f POL to WPOL...", amount_pol)
    wrap_tx = {
        "to": WPOL_ADDR,
        "value": amount_wei,
        "gas": 60_000,
        "gasPrice": gas_price,
        "nonce": nonce,
        "chainId": 137,
        "data": "0xd0e30db0",  # deposit()
    }
    signed_wrap = account.sign_transaction(wrap_tx)
    wrap_hash = _rpc_call("eth_sendRawTransaction", ["0x" + signed_wrap.raw_transaction.hex()])
    logger.info("Wrap Tx Hash: %s", wrap_hash)
    nonce += 1
    time.sleep(3)

    # Step B: Check WPOL allowance for Uniswap Router
    call_data = "0xdd62ed3e" + encode(["address", "address"], [my_addr, UNISWAP_V3_ROUTER]).hex()
    allowance_hex = _rpc_call("eth_call", [{"to": WPOL_ADDR, "data": call_data}, "latest"])
    allowance = int(allowance_hex, 16) if allowance_hex and allowance_hex != "0x" else 0

    if allowance < amount_wei:
        logger.info("Step 2: Approving WPOL for Uniswap V3 SwapRouter...")
        max_uint = (1 << 256) - 1
        approve_data = "0x095ea7b3" + encode(["address", "uint256"], [UNISWAP_V3_ROUTER, max_uint]).hex()
        app_tx = {
            "to": WPOL_ADDR,
            "value": 0,
            "gas": 65_000,
            "gasPrice": gas_price,
            "nonce": nonce,
            "chainId": 137,
            "data": approve_data,
        }
        signed_app = account.sign_transaction(app_tx)
        app_hash = _rpc_call("eth_sendRawTransaction", ["0x" + signed_app.raw_transaction.hex()])
        logger.info("Approve Tx Hash: %s", app_hash)
        nonce += 1
        time.sleep(3)

    # Step C: Execute exactInputSingle swap on Uniswap V3 Router
    logger.info("Step 3: Swapping WPOL for USDC.e on Uniswap V3...")
    deadline = int(time.time()) + 600
    # struct ExactInputSingleParams:
    # (address tokenIn, address tokenOut, uint24 fee, address recipient, uint256 deadline, uint256 amountIn, uint256 amountOutMinimum, uint160 sqrtPriceLimitX96)
    swap_params_encoded = encode(
        ["(address,address,uint24,address,uint256,uint256,uint256,uint160)"],
        [(WPOL_ADDR, USDC_E_ADDR, 500, my_addr, deadline, amount_wei, 0, 0)],
    )
    # selector for exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160)) -> 0x414bf382
    swap_data = "0x414bf382" + swap_params_encoded.hex()

    swap_tx = {
        "to": UNISWAP_V3_ROUTER,
        "value": 0,
        "gas": 220_000,
        "gasPrice": gas_price,
        "nonce": nonce,
        "chainId": 137,
        "data": swap_data,
    }
    signed_swap = account.sign_transaction(swap_tx)
    swap_hash = _rpc_call("eth_sendRawTransaction", ["0x" + signed_swap.raw_transaction.hex()])
    logger.info("Uniswap V3 Swap Tx Hash: %s", swap_hash)

    return {
        "status": "submitted",
        "action": "UNISWAP_V3_SWAP",
        "amount_pol_swapped": amount_pol,
        "wrap_tx": wrap_hash,
        "swap_tx": swap_hash,
        "polygonscan_swap_url": f"https://polygonscan.com/tx/{swap_hash}",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Swap POL to USDC.e via Uniswap V3")
    parser.add_argument("--amount", type=float, default=15.0, help="Amount of POL to swap (default: 15.0)")
    parser.add_argument("--dry-run", action="store_true", help="Simulate without broadcasting")
    args = parser.parse_args()

    res = swap_pol_to_usdc(amount_pol=args.amount, dry_run=args.dry_run)
    print(json.dumps(res, indent=2))


if __name__ == "__main__":
    main()
