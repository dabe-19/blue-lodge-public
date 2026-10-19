#!/usr/bin/env python3
"""Sovereign Real-Time On-Chain Wallet Status Provider for Blue Lodge.

Queries Blockfrost for Cardano Mainnet ADA & Native Token UTxOs,
and queries Polygon PoS RPC for POL & USDC balances.
Outputs unified JSON for the Craftsman Workbench UI and telemetry pipelines.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import urllib.parse
import urllib.request
import warnings
warnings.filterwarnings("ignore")
from pathlib import Path
from typing import Any

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from lib.tools.cardano_trader import query_wallet_balance

logger = logging.getLogger("wallet_status")
logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")


def get_polygon_status() -> dict[str, Any]:
    """Query live Polygon POL and USDC token balances."""
    addr = os.getenv("POLYMARKET_FUNDER_ADDRESS", "").strip()
    if not addr:
        addr_file = _REPO_ROOT / ".george" / "wallets" / "polygon_payment.addr"
        if addr_file.exists():
            addr = addr_file.read_text(encoding="utf-8").strip()
    if not addr:
        try:
            from lib.tools.wallet import keystore as ks
            addr = ks.receive_info("agent-evm", chain="polygon").get("address", "")
        except Exception:
            addr = ""
    pol_bal = 0.0
    usdc_bal = 0.0
    usdce_bal = 0.0

    rpc_endpoints = [
        "https://polygon-bor-rpc.publicnode.com",
        "https://polygon.llamarpc.com",
        "https://1rpc.io/matic",
    ]

    for rpc in rpc_endpoints:
        try:
            # 1. Native POL
            payload = json.dumps({"jsonrpc": "2.0", "method": "eth_getBalance", "params": [addr, "latest"], "id": 1}).encode("utf-8")
            req = urllib.request.Request(rpc, data=payload, headers={"Content-Type": "application/json", "User-Agent": "BlueLodge/1.0"})
            with urllib.request.urlopen(req, timeout=3) as resp:
                res = json.loads(resp.read().decode())
                pol_bal = int(res.get("result", "0x0"), 16) / 1e18

            # 2. Native USDC (0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359)
            data_call = "0x70a08231" + addr[2:].lower().rjust(64, "0")
            payload_usdc = json.dumps({"jsonrpc": "2.0", "method": "eth_call", "params": [{"to": "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359", "data": data_call}, "latest"], "id": 2}).encode("utf-8")
            req2 = urllib.request.Request(rpc, data=payload_usdc, headers={"Content-Type": "application/json", "User-Agent": "BlueLodge/1.0"})
            with urllib.request.urlopen(req2, timeout=3) as resp:
                res2 = json.loads(resp.read().decode())
                usdc_bal = int(res2.get("result", "0x0"), 16) / 1e6

            # 3. Bridged USDC.e (0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174)
            payload_usdce = json.dumps({"jsonrpc": "2.0", "method": "eth_call", "params": [{"to": "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174", "data": data_call}, "latest"], "id": 3}).encode("utf-8")
            req3 = urllib.request.Request(rpc, data=payload_usdce, headers={"Content-Type": "application/json", "User-Agent": "BlueLodge/1.0"})
            with urllib.request.urlopen(req3, timeout=3) as resp:
                res3 = json.loads(resp.read().decode())
                usdce_bal = int(res3.get("result", "0x0"), 16) / 1e6

            break
        except Exception:
            continue

    total_usdc = usdc_bal + usdce_bal

    return {
        "address": addr,
        "pol_balance": round(pol_bal, 4),
        "usdc_native": round(usdc_bal, 2),
        "usdc_bridged": round(usdce_bal, 2),
        "total_usdc": round(total_usdc, 2),
        "network": "Polygon PoS Mainnet",
        "chain_id": int(os.getenv("POLYMARKET_CHAIN_ID", 137)),
        "polygonscan_url": f"https://polygonscan.com/address/{addr}",
    }


def get_unified_wallet_status() -> dict[str, Any]:
    """Retrieve combined real-time wallet readouts across Cardano, Polygon, and Ethereum."""
    cardano = query_wallet_balance()
    polygon = get_polygon_status()
    try:
        from lib.tools.sovereign_multichain_wallet import get_ethereum_status
        ethereum = get_ethereum_status()
    except Exception:
        ethereum = {
            "status": "unavailable",
            "network": "Ethereum Mainnet",
            "chain_id": 1,
            "address": polygon.get("address", ""),
            "eth_balance": 0.0,
            "usdc_balance": 0.0,
        }

    # Add Cardanoscan URL
    cardano["cardanoscan_url"] = f"https://cardanoscan.io/address/{cardano.get('address')}"

    return {
        "status": "ok",
        "timestamp": int(os.time() if hasattr(os, "time") else __import__("time").time()),
        "cardano": cardano,
        "polygon": polygon,
        "ethereum": ethereum,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Sovereign On-Chain Wallet Status Provider")
    parser.add_argument("--json", action="store_true", help="Output raw JSON (default)")
    args = parser.parse_args()

    status = get_unified_wallet_status()
    print(json.dumps(status, indent=2))


if __name__ == "__main__":
    main()
