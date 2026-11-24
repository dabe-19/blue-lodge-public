#!/usr/bin/env python3
"""Sovereign Polygon DeFi Swapper: Converts POL -> WPOL -> USDC.e via Uniswap V3.

Enables autonomous self-funding for Polymarket CLOB collateral directly on-chain,
with on-chain QuoterV2 / spot slippage protection (amountOutMinimum > 0).
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
from typing import Any, Optional

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if __name__ == "__main__" and _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)

from eth_abi import decode, encode
from eth_account import Account

from lib.tools.common import populate_environ

logger = logging.getLogger("polygon_swapper")
logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s", stream=sys.stderr)

WPOL_ADDR = "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270"
USDC_E_ADDR = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"
UNISWAP_V3_ROUTER = "0xE592427A0AEce92De3Edee1F18E0157C05861564"
UNISWAP_V3_QUOTER_V2 = "0x61fFE014bA17989E743c5F6cB21bF9697530B21e"
POOL_FEE_BPS = 500  # 0.05% tier

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
                headers={"User-Agent": "BlueLodge-PolygonSwapper/2.0", "Content-Type": "application/json"},
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
        raise ValueError("No EVM account or POLYMARKET_PRIVATE_KEY configured")
    if not key.startswith("0x"):
        key = "0x" + key
    return Account.from_key(key)


def quote_wpol_to_usdce(amount_wei: int) -> tuple[int, str]:
    """
    Returns (expected_out_units_6dec, quote_source) for swapping `amount_wei` WPOL -> USDC.e.
    First queries Uniswap V3 QuoterV2 on Polygon via eth_call; falls back to CoinGecko POL/USD.
    """
    # 1. Try Uniswap V3 QuoterV2: quoteExactInputSingle((address,address,uint256,uint24,uint160)) -> selector 0xc6a5026a
    try:
        params_enc = encode(
            ["(address,address,uint256,uint24,uint160)"],
            [(WPOL_ADDR, USDC_E_ADDR, amount_wei, POOL_FEE_BPS, 0)],
        )
        call_data = "0xc6a5026a" + params_enc.hex()
        res_hex = _rpc_call("eth_call", [{"to": UNISWAP_V3_QUOTER_V2, "data": call_data}, "latest"])
        if res_hex and res_hex != "0x" and len(res_hex) >= 66:
            raw_bytes = bytes.fromhex(res_hex[2:])
            amount_out = decode(["uint256"], raw_bytes[:32])[0]
            if amount_out > 0:
                return int(amount_out), "uniswap_v3_quoter_v2"
    except Exception as e:
        logger.debug("QuoterV2 eth_call fallback: %s", e)

    # 2. Fallback to CoinGecko POL/USD price via sovereign_fund
    try:
        from lib.tools import sovereign_fund as fund
        px = (fund.usd_prices().get("usd") or {}).get("POL")
        if px and float(px) > 0:
            est_usdc = (amount_wei / 1e18) * float(px) * 0.9995
            return int(round(est_usdc * 1e6)), "coingecko_spot"
    except Exception:
        pass

    raise RuntimeError("Unable to obtain live WPOL -> USDC.e quote for slippage protection")


def swap_pol_to_usdc(
    amount_pol: float = 15.0,
    dry_run: bool = True,
    max_slippage_bps: int = 100,
) -> dict[str, Any]:
    if amount_pol <= 0 or amount_pol > 10_000:
        raise ValueError("amount_pol must be in (0, 10000]")
    max_slippage_bps = max(10, min(1000, int(max_slippage_bps)))

    account = _load_account()
    my_addr = account.address

    bal_hex = _rpc_call("eth_getBalance", [my_addr, "latest"])
    pol_bal = int(bal_hex, 16) / 1e18
    logger.info("Signer: %s | Current POL Balance: %.4f", my_addr, pol_bal)

    amount_wei = int(round(amount_pol * 1e18))
    expected_out_raw, quote_source = quote_wpol_to_usdce(amount_wei)
    min_out_raw = max(1, int(expected_out_raw * (10_000 - max_slippage_bps) // 10_000))
    expected_usdc = round(expected_out_raw / 1e6, 4)
    min_out_usdc = round(min_out_raw / 1e6, 4)

    nonce_hex = _rpc_call("eth_getTransactionCount", [my_addr, "latest"])
    nonce = int(nonce_hex, 16)

    gas_price_hex = _rpc_call("eth_gasPrice", [])
    gas_price = int(int(gas_price_hex, 16) * 1.35)

    has_balance = pol_bal >= (amount_pol + 1.0)

    if dry_run:
        return {
            "status": "ok" if has_balance else "insufficient_balance",
            "dry_run": True,
            "signer": my_addr,
            "pol_balance": round(pol_bal, 4),
            "amount_pol": amount_pol,
            "expected_usdc_e": expected_usdc,
            "min_out_usdc_e": min_out_usdc,
            "min_out_raw": min_out_raw,
            "max_slippage_bps": max_slippage_bps,
            "quote_source": quote_source,
            "nonce": nonce,
            "gas_price_gwei": round(gas_price / 1e9, 2),
            "message": (
                f"Dry run: swap {amount_pol} POL -> ~{expected_usdc} USDC.e (min {min_out_usdc} USDC.e, {max_slippage_bps} bps max slippage)"
                if has_balance
                else f"Insufficient POL: balance {pol_bal:.4f} POL, need {amount_pol + 1.0:.2f} POL (incl. 1.0 POL gas reserve)"
            ),
        }

    if not has_balance:
        raise ValueError(f"Insufficient POL: has {pol_bal:.4f}, requested swap {amount_pol} + 1.0 reserve for gas")

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

    # Step C: Execute exactInputSingle swap on Uniswap V3 Router with amountOutMinimum = min_out_raw
    logger.info("Step 3: Swapping WPOL for USDC.e on Uniswap V3 (min_out=%s USDC.e)...", min_out_usdc)
    deadline = int(time.time()) + 600
    swap_params_encoded = encode(
        ["(address,address,uint24,address,uint256,uint256,uint256,uint160)"],
        [(WPOL_ADDR, USDC_E_ADDR, POOL_FEE_BPS, my_addr, deadline, amount_wei, min_out_raw, 0)],
    )
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
        "dry_run": False,
        "action": "UNISWAP_V3_SWAP",
        "signer": my_addr,
        "amount_pol_swapped": amount_pol,
        "expected_usdc_e": expected_usdc,
        "min_out_usdc_e": min_out_usdc,
        "max_slippage_bps": max_slippage_bps,
        "quote_source": quote_source,
        "wrap_tx": wrap_hash,
        "swap_tx": swap_hash,
        "polygonscan_swap_url": f"https://polygonscan.com/tx/{swap_hash}",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Swap POL to USDC.e via Uniswap V3")
    parser.add_argument("--amount", type=float, default=15.0, help="Amount of POL to swap (default: 15.0)")
    parser.add_argument("--max-slippage-bps", type=int, default=100, help="Max slippage in basis points (default: 100 = 1.0%)")
    parser.add_argument("--execute", action="store_true", help="Broadcast live transaction on Polygon Mainnet")
    parser.add_argument("--dry-run", action="store_true", help="Simulate without broadcasting (default unless --execute)")
    parser.add_argument("--json", action="store_true", help="Compact JSON output")
    args = parser.parse_args()

    is_dry = not args.execute
    try:
        res = swap_pol_to_usdc(
            amount_pol=args.amount,
            dry_run=is_dry,
            max_slippage_bps=args.max_slippage_bps,
        )
    except Exception as e:
        res = {"status": "error", "message": f"{type(e).__name__}: {e}"}
    print(json.dumps(res, indent=None if args.json else 2))


if __name__ == "__main__":
    main()
