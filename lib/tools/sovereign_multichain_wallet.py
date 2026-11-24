#!/usr/bin/env python3
"""
Sovereign Multi-Chain Wallet & Key Manager (Blue Lodge)
Unified interface for Cardano (ADA), Polygon PoS (POL, USDC), and Ethereum (ETH, ERC-20 USDC).

Features:
1. Multi-chain portfolio aggregation across Cardano, Polygon, and Ethereum.
2. Identical secp256k1 key management across Polygon and Ethereum.
3. ERC-20 USDC rescue and transfer engine on Ethereum Mainnet.
4. Gas estimation and funding requirements for cross-chain capital deployment.
5. Sovereign key generation and validation for Ed25519 (Cardano) and secp256k1 (EVM).
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)

from eth_account import Account
from eth_account.signers.local import LocalAccount
from eth_utils import to_checksum_address

from lib.tools.cardano_trader import query_wallet_balance, normalize_blockfrost_base_url

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", stream=sys.stderr)
logger = logging.getLogger("sovereign_multichain_wallet")

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path.home() / "blue-lodge"))
WALLETS_DIR = LODGE_DIR / ".george" / "wallets"

# Cardano Files
CARDANO_SKEY_FILE = WALLETS_DIR / "cardano_payment.skey"
CARDANO_ADDR_FILE = WALLETS_DIR / "cardano_payment.addr"

# EVM Files (Shared secp256k1 key for Polygon and Ethereum)
EVM_KEY_FILE = WALLETS_DIR / "polygon_payment.key"
EVM_ADDR_FILE = WALLETS_DIR / "polygon_payment.addr"

# Ethereum Contracts & Constants
ETH_USDC_CONTRACT = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
ETH_USDC_DECIMALS = 6
ETH_CHAIN_ID = 1

# Polygon Contracts & Constants
POLYGON_NATIVE_USDC = "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359"
POLYGON_BRIDGED_USDC = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"
POLYGON_CHAIN_ID = 137

# Resilient Public RPC Endpoints
ETH_RPCS = [
    "https://ethereum.publicnode.com",
    "https://cloudflare-eth.com",
    "https://1rpc.io/eth",
    "https://eth.llamarpc.com",
]

POLYGON_RPCS = [
    "https://polygon-bor-rpc.publicnode.com",
    "https://polygon.llamarpc.com",
    "https://1rpc.io/matic",
]


def rpc_call(rpcs: List[str], method: str, params: list, timeout: int = 5) -> Any:
    """Dispatches a JSON-RPC 2.0 call across fallback RPC endpoints."""
    payload = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode("utf-8")
    last_err = None
    for rpc in rpcs:
        try:
            req = urllib.request.Request(
                rpc,
                data=payload,
                headers={"Content-Type": "application/json", "User-Agent": "BlueLodge-SovereignWallet/1.0"},
            )
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                res = json.loads(resp.read().decode("utf-8"))
                if "error" in res:
                    raise RuntimeError(res["error"].get("message", "RPC Error"))
                return res.get("result")
        except Exception as e:
            last_err = e
            continue
    raise RuntimeError(f"All RPCs failed for method {method}: {last_err}")


def get_evm_account() -> Optional[LocalAccount]:
    """Loads the sovereign EVM account from encrypted keystore or local key storage."""
    try:
        from lib.tools.wallet import keystore
        return keystore.evm_signer()
    except Exception:
        pass
    if not EVM_KEY_FILE.exists():
        return None
    try:
        key_hex = EVM_KEY_FILE.read_text().strip()
        if not key_hex.startswith("0x"):
            key_hex = f"0x{key_hex}"
        return Account.from_key(key_hex)
    except Exception as e:
        logger.error(f"Failed to load EVM account: {e}")
        return None


def get_ethereum_status() -> Dict[str, Any]:
    """Queries live Ethereum Mainnet status: ETH balance, ERC-20 USDC balance, and gas price."""
    acct = get_evm_account()
    if acct is None:
        addr = os.getenv("POLYMARKET_FUNDER_ADDRESS", "").strip()
    else:
        addr = acct.address

    eth_bal = 0.0
    usdc_bal = 0.0
    gas_gwei = 0.0

    try:
        # 1. Native ETH balance
        raw_bal = rpc_call(ETH_RPCS, "eth_getBalance", [addr, "latest"])
        eth_bal = int(raw_bal, 16) / 1e18 if raw_bal else 0.0

        # 2. ERC-20 USDC balance
        call_data = "0x70a08231" + addr[2:].lower().rjust(64, "0")
        raw_usdc = rpc_call(ETH_RPCS, "eth_call", [{"to": ETH_USDC_CONTRACT, "data": call_data}, "latest"])
        usdc_bal = int(raw_usdc, 16) / (10 ** ETH_USDC_DECIMALS) if raw_usdc else 0.0

        # 3. Real-time Gas Price
        raw_gas = rpc_call(ETH_RPCS, "eth_gasPrice", [])
        gas_gwei = (int(raw_gas, 16) / 1e9) if raw_gas else 0.0
    except Exception as e:
        logger.warning(f"Error querying Ethereum status: {e}")

    # Estimate gas needed for ERC-20 transfer (approx 65,000 gas limit)
    est_tx_cost_eth = (65000 * gas_gwei * 1e9) / 1e18
    has_sufficient_gas = eth_bal >= est_tx_cost_eth and eth_bal > 0.0005

    return {
        "status": "ok",
        "network": "Ethereum Mainnet",
        "chain_id": ETH_CHAIN_ID,
        "address": addr,
        "eth_balance": round(eth_bal, 6),
        "usdc_balance": round(usdc_bal, 2),
        "usdc_contract": ETH_USDC_CONTRACT,
        "gas_price_gwei": round(gas_gwei, 2),
        "est_transfer_cost_eth": round(est_tx_cost_eth, 6),
        "has_sufficient_gas": has_sufficient_gas,
        "rescue_ready": usdc_bal > 0.0,
        "etherscan_url": f"https://etherscan.io/address/{addr}",
    }


def get_polygon_status() -> Dict[str, Any]:
    """Queries live Polygon PoS status: POL balance, Native USDC, and Bridged USDC.e."""
    acct = get_evm_account()
    if acct is None:
        addr = os.getenv("POLYMARKET_FUNDER_ADDRESS", "").strip()
    else:
        addr = acct.address

    pol_bal = 0.0
    usdc_native = 0.0
    usdc_bridged = 0.0

    try:
        # 1. Native POL
        raw_pol = rpc_call(POLYGON_RPCS, "eth_getBalance", [addr, "latest"])
        pol_bal = int(raw_pol, 16) / 1e18 if raw_pol else 0.0

        # 2. Native USDC
        call_data = "0x70a08231" + addr[2:].lower().rjust(64, "0")
        raw_usdc = rpc_call(POLYGON_RPCS, "eth_call", [{"to": POLYGON_NATIVE_USDC, "data": call_data}, "latest"])
        usdc_native = int(raw_usdc, 16) / 1e6 if raw_usdc else 0.0

        # 3. Bridged USDC.e
        raw_usdce = rpc_call(POLYGON_RPCS, "eth_call", [{"to": POLYGON_BRIDGED_USDC, "data": call_data}, "latest"])
        usdc_bridged = int(raw_usdce, 16) / 1e6 if raw_usdce else 0.0
    except Exception as e:
        logger.warning(f"Error querying Polygon status: {e}")

    total_usdc = usdc_native + usdc_bridged

    return {
        "status": "ok",
        "network": "Polygon PoS Mainnet",
        "chain_id": POLYGON_CHAIN_ID,
        "address": addr,
        "pol_balance": round(pol_bal, 4),
        "usdc_native": round(usdc_native, 2),
        "usdc_bridged": round(usdc_bridged, 2),
        "total_usdc": round(total_usdc, 2),
        "polygonscan_url": f"https://polygonscan.com/address/{addr}",
    }


def get_cardano_status() -> Dict[str, Any]:
    """Queries live Cardano Mainnet status."""
    cardano = query_wallet_balance()
    cardano["cardanoscan_url"] = f"https://cardanoscan.io/address/{cardano.get('address')}"
    return cardano


def get_unified_multichain_portfolio() -> Dict[str, Any]:
    """Aggregates portfolio balances and readiness across Cardano, Polygon, and Ethereum."""
    cardano = get_cardano_status()
    polygon = get_polygon_status()
    ethereum = get_ethereum_status()

    # Calculate Total Liquid Capital (USD estimate)
    # Estimate ADA @ $0.35, POL @ $0.30, ETH @ $2,400
    ada_val = cardano.get("total_ada", 0.0) * 0.35
    pol_val = polygon.get("pol_balance", 0.0) * 0.30
    eth_val = ethereum.get("eth_balance", 0.0) * 2400.0
    usdc_val = polygon.get("total_usdc", 0.0) + ethereum.get("usdc_balance", 0.0)
    total_est_usd = ada_val + pol_val + eth_val + usdc_val

    return {
        "status": "ok",
        "timestamp": int(time.time()),
        "total_estimated_usd": round(total_est_usd, 2),
        "cardano": cardano,
        "polygon": polygon,
        "ethereum": ethereum,
    }


def create_or_import_evm_key(private_key_hex: Optional[str] = None) -> Dict[str, str]:
    """Generates a new secp256k1 EVM key or imports an existing private key."""
    WALLETS_DIR.mkdir(parents=True, exist_ok=True)
    if private_key_hex:
        clean_key = private_key_hex.strip()
        if not clean_key.startswith("0x"):
            clean_key = f"0x{clean_key}"
        acct = Account.from_key(clean_key)
    else:
        acct = Account.create()

    raw_key = acct.key.hex()
    EVM_KEY_FILE.write_text(raw_key)
    EVM_KEY_FILE.chmod(0o600)
    EVM_ADDR_FILE.write_text(acct.address)

    return {
        "address": acct.address,
        "key_file": str(EVM_KEY_FILE),
        "network_compatibility": "Ethereum (Chain ID 1) and Polygon (Chain ID 137)",
    }


def build_and_sign_eth_usdc_transfer(
    to_address: str,
    amount_usdc: float,
    dry_run: bool = True,
    execute: bool = False,
) -> Dict[str, Any]:
    """
    Constructs, signs, and optionally broadcasts an ERC-20 USDC transfer on Ethereum Mainnet.
    Rescues accidentally sent funds or deploys capital to target address.
    """
    acct = get_evm_account()
    if not acct:
        raise RuntimeError(f"No EVM key found at {EVM_KEY_FILE}")

    to_checksum = to_checksum_address(to_address)
    raw_amount = int(amount_usdc * (10 ** ETH_USDC_DECIMALS))

    addr_clean = to_checksum[2:].lower().rjust(64, "0")
    amt_clean = hex(raw_amount)[2:].rjust(64, "0")
    tx_data = f"0xa9059cbb{addr_clean}{amt_clean}"

    raw_nonce = rpc_call(ETH_RPCS, "eth_getTransactionCount", [acct.address, "latest"])
    nonce = int(raw_nonce, 16) if raw_nonce else 0

    raw_gas_price = rpc_call(ETH_RPCS, "eth_gasPrice", [])
    gas_price = int(raw_gas_price, 16) if raw_gas_price else int(20e9)

    gas_limit = 65000

    tx = {
        "nonce": nonce,
        "gasPrice": gas_price,
        "gas": gas_limit,
        "to": ETH_USDC_CONTRACT,
        "value": 0,
        "data": tx_data,
        "chainId": ETH_CHAIN_ID,
    }

    signed = acct.sign_transaction(tx)
    tx_hash = signed.hash.hex()
    if not tx_hash.startswith("0x"):
        tx_hash = f"0x{tx_hash}"

    result = {
        "action": "eth_usdc_transfer",
        "sender": acct.address,
        "recipient": to_checksum,
        "amount_usdc": amount_usdc,
        "raw_amount": raw_amount,
        "contract": ETH_USDC_CONTRACT,
        "nonce": nonce,
        "gas_price_gwei": round(gas_price / 1e9, 2),
        "gas_limit": gas_limit,
        "est_fee_eth": round((gas_limit * gas_price) / 1e18, 6),
        "signed_tx_hash": tx_hash,
        "executed": False,
    }

    if execute and not dry_run:
        raw_tx_hex = signed.raw_transaction.hex()
        if not raw_tx_hex.startswith("0x"):
            raw_tx_hex = f"0x{raw_tx_hex}"
        try:
            broadcast_res = rpc_call(ETH_RPCS, "eth_sendRawTransaction", [raw_tx_hex])
            result["executed"] = True
            result["broadcast_result"] = broadcast_res
            result["etherscan_tx_url"] = f"https://etherscan.io/tx/{broadcast_res}"
            logger.info(f"Ethereum transaction broadcast successfully! Tx: {broadcast_res}")
        except Exception as e:
            result["error"] = str(e)
            logger.error(f"Failed to broadcast Ethereum transaction: {e}")
    else:
        result["dry_run"] = True
        result["note"] = "Transaction signed successfully in simulation mode. Use --execute to broadcast."

    return result


def print_ascii_dashboard(portfolio: Dict[str, Any]) -> None:
    """Renders a beautiful sovereign multi-chain desk dashboard."""
    c = portfolio.get("cardano", {})
    p = portfolio.get("polygon", {})
    e = portfolio.get("ethereum", {})

    print("=" * 78)
    print("           SOVEREIGN MULTI-CHAIN DESK: CARDANO | POLYGON | ETHEREUM")
    print("=" * 78)
    print(f" Total Estimated Treasury Value: ${portfolio.get('total_estimated_usd', 0.0):.2f} USD")
    print("-" * 78)

    # 1. Cardano
    print(" [1] CARDANO MAINNET (Layer 1 eUTxO)")
    print(f"     Address:        {c.get('address', 'N/A')}")
    print(f"     Total ADA:      {c.get('total_ada', 0.0):.4f} ADA (Spendable: {c.get('spendable_ada', 0.0):.4f} ADA)")
    print(f"     UTxO Count:     {c.get('utxo_count', 0)} | Reserve Floor: {c.get('reserve_floor_ada', 10.0):.1f} ADA")
    tokens = c.get("multi_assets", {})
    if tokens:
        print(f"     Native Tokens:  {', '.join(f'{k}: {v}' for k, v in tokens.items())}")
    else:
        print("     Native Tokens:  None")
    print(f"     Explorer:       {c.get('cardanoscan_url', '')}")
    print("-" * 78)

    # 2. Polygon
    print(" [2] POLYGON PoS MAINNET (EVM Chain ID 137)")
    print(f"     Address:        {p.get('address', 'N/A')}")
    print(f"     Native Gas:     {p.get('pol_balance', 0.0):.4f} POL")
    print(f"     USDC Native:    {p.get('usdc_native', 0.0):.2f} USDC")
    print(f"     USDC.e Bridged: {p.get('usdc_bridged', 0.0):.2f} USDC.e")
    print(f"     Total USDC:     {p.get('total_usdc', 0.0):.2f} USDC")
    print(f"     Explorer:       {p.get('polygonscan_url', '')}")
    print("-" * 78)

    # 3. Ethereum
    print(" [3] ETHEREUM MAINNET (EVM Chain ID 1)")
    print(f"     Address:        {e.get('address', 'N/A')} (Same key as Polygon!)")
    print(f"     Native Gas:     {e.get('eth_balance', 0.0):.6f} ETH")
    print(f"     ERC-20 USDC:    {e.get('usdc_balance', 0.0):.2f} USDC [Contract: 0xA0b8...eB48]")
    print(f"     Current Gas:    {e.get('gas_price_gwei', 0.0):.1f} Gwei (Est. transfer cost: {e.get('est_transfer_cost_eth', 0.0):.5f} ETH)")
    if e.get("usdc_balance", 0.0) > 0:
        if e.get("has_sufficient_gas"):
            print("     Rescue Status:  ★ READY FOR DEPLOYMENT / TRANSFER")
        else:
            print(f"     Rescue Status:  ⚠ 13.98 USDC FOUND. Needs ~0.001 ETH gas sent to this address to execute transfers.")
    print(f"     Explorer:       {e.get('etherscan_url', '')}")
    print("=" * 78)


def main() -> None:
    parser = argparse.ArgumentParser(description="Sovereign Multi-Chain Wallet & Key Manager")
    parser.add_argument("--status", action="store_true", help="Display full multi-chain status dashboard (default)")
    parser.add_argument("--json", action="store_true", help="Output pure JSON format")
    parser.add_argument("--chain", type=str, choices=["all", "cardano", "polygon", "ethereum"], default="all")
    parser.add_argument("--create-evm-key", action="store_true", help="Generate a new secp256k1 EVM keypair")
    parser.add_argument("--import-evm-key", type=str, help="Import an existing EVM private key in hex")
    parser.add_argument("--eth-transfer-usdc", type=float, help="Amount of USDC to transfer from Ethereum wallet")
    parser.add_argument("--to", type=str, help="Recipient address for transfer")
    parser.add_argument("--dry-run", action="store_true", default=True, help="Simulate and sign transaction without broadcasting")
    parser.add_argument("--execute", action="store_true", help="Broadcast transaction on-chain")

    args = parser.parse_args()

    if args.create_evm_key or args.import_evm_key:
        res = create_or_import_evm_key(args.import_evm_key)
        print(json.dumps(res, indent=2))
        return

    if args.eth_transfer_usdc:
        if not args.to:
            print("Error: --to <recipient_address> is required for transfer.", file=sys.stderr)
            sys.exit(1)
        res = build_and_sign_eth_usdc_transfer(
            to_address=args.to,
            amount_usdc=args.eth_transfer_usdc,
            dry_run=not args.execute,
            execute=args.execute,
        )
        print(json.dumps(res, indent=2))
        return

    portfolio = get_unified_multichain_portfolio()

    if args.json:
        if args.chain == "cardano":
            print(json.dumps(portfolio.get("cardano", {}), indent=2))
        elif args.chain == "polygon":
            print(json.dumps(portfolio.get("polygon", {}), indent=2))
        elif args.chain == "ethereum":
            print(json.dumps(portfolio.get("ethereum", {}), indent=2))
        else:
            print(json.dumps(portfolio, indent=2))
    else:
        print_ascii_dashboard(portfolio)


if __name__ == "__main__":
    main()
