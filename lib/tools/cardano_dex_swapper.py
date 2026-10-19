#!/usr/bin/env python3
"""
Sovereign Cardano DEX Swapper & Execution Engine
Integrates with Minswap Aggregator API and PyCardano to autonomously:
1. Calculate optimal multi-DEX routing across Minswap v2, Spectrum, and SundaeSwap.
2. Build unsigned Cardano Mainnet swap transactions utilizing hot wallet UTxOs.
3. Cryptographically sign the transaction with George's sovereign private key.
4. Broadcast to Cardano Mainnet with strict fiduciary boundaries (10.00 ADA reserve floor, slippage caps).
5. Supports bidirectional execution: ADA -> Native Asset (Buy) and Native Asset -> ADA (Sell).
"""

import sys
import os
from pathlib import Path

# Auto-bootstrap project virtualenv (Python 3.12 with compiled C-extensions like pycardano)
_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)

import json
import time
import urllib.request
import urllib.error
import logging
from dataclasses import dataclass
from typing import Optional, Any

from pycardano import (
    Transaction,
    TransactionWitnessSet,
    PaymentSigningKey,
    VerificationKeyWitness,
    BlockFrostChainContext,
    Network,
    TransactionBuilder,
    Address,
)

from lib.tools.cardano_trader import normalize_blockfrost_base_url

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", stream=sys.stderr)
logger = logging.getLogger("cardano_dex_swapper")

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path.home() / "blue-lodge"))
SECRETS_FILE = LODGE_DIR / ".george" / "secrets.env"
WALLET_KEY_FILE = LODGE_DIR / ".george" / "wallets" / "cardano_payment.skey"
STATUS_CACHE = LODGE_DIR / ".george" / "wallets" / "status_cache.json"

MINSWAP_AGGREGATOR_BASE = "https://agg-api.minswap.org/aggregator"

# Registered Token Units on Cardano Mainnet (canonical source: lib/tools/quant/tokens.py)
from lib.tools.quant import tokens as _tokens  # noqa: E402
TOKEN_METADATA = {
    "ADA": {"decimals": 6, "unit": "lovelace"},
    "LOVELACE": {"decimals": 6, "unit": "lovelace"},
    **{sym: {"decimals": rec["decimals"], "unit": rec["unit"]} for sym, rec in _tokens.unit_table().items()},
}
for _alias, _canon in _tokens.ALIASES.items():
    TOKEN_METADATA[_alias] = TOKEN_METADATA[_canon]

TOKEN_REGISTRY = {sym: info["unit"] for sym, info in TOKEN_METADATA.items()}

HARD_RESERVE_FLOOR_ADA = float(os.getenv("CARDANO_RESERVE_FLOOR_ADA", "40.00"))
MAX_SINGLE_SWAP_ADA = float(os.getenv("CARDANO_MAX_SINGLE_SWAP_ADA", "200.00"))
DEFAULT_SLIPPAGE = 0.02  # 2.0% max slippage


def load_env_vars() -> dict[str, str]:
    env = {}
    if SECRETS_FILE.exists():
        for line in SECRETS_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip("'\"")
    return env


def get_token_unit(symbol_or_unit: str) -> str:
    sym = symbol_or_unit.upper()
    return TOKEN_REGISTRY.get(sym, symbol_or_unit)


def list_aggregator_protocols() -> list[str]:
    """Protocol identifiers the Minswap aggregator can route through."""
    req = urllib.request.Request(f"{MINSWAP_AGGREGATOR_BASE}/protocols",
                                 headers={"User-Agent": "BlueLodge-SovereignSwapper/1.0"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return [p["protocol"] for p in data.get("protocols", []) if p.get("protocol")]


def estimate_swap_route(
    amount_in_base_units: int,
    token_in: str,
    token_out: str,
    slippage: float = DEFAULT_SLIPPAGE,
    only_protocols: Optional[list[str]] = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Queries Minswap Aggregator for real-time optimal routing across Cardano AMMs.

    Two-tier batcher & contract safety guard:
      1. Structural Protocol Filter: Excludes dead/incompatible protocols:
         - Spectrum & OpenDjedV1 & ChakraBondingCurve: Decommissioned AMMs (0 active batchers).
         - VyFinance: Requires StakeAddress owner (incompatible with Enterprise addr1v... wallet).
      2. Dynamic Per-Pool On-Chain Batcher Liveness Gate:
         Verifies via Blockfrost that every hop's Pool NFT has settled a batch on-chain within
         MAX_POOL_BATCH_AGE_H (6 hours). If a hop routes through a stalled pool (e.g. a CswapV1
         or legacy WingRiders v1 pool whose batcher hasn't cleared in days/weeks), that protocol
         is dynamically added to exclude_protocols and the route is re-estimated.
    """
    from lib.tools.cardano_flash_sniper import verify_pool_batcher_liveness

    url = f"{MINSWAP_AGGREGATOR_BASE}/estimate"
    exclude = ["Spectrum", "VyFinance", "OpenDjedV1", "ChakraBondingCurve"]
    if only_protocols:
        exclude = [p for p in list_aggregator_protocols() if p not in only_protocols]

    for _attempt in range(3):
        estimate_params = {
            "amount": str(amount_in_base_units),
            "token_in": get_token_unit(token_in),
            "token_out": get_token_unit(token_out),
            "slippage": slippage,
            "exclude_protocols": list(exclude),
            "allow_multi_hops": not only_protocols,
        }
        req = urllib.request.Request(
            url,
            data=json.dumps(estimate_params).encode("utf-8"),
            headers={"Content-Type": "application/json", "User-Agent": "BlueLodge-SovereignSwapper/2.0"},
        )
        with urllib.request.urlopen(req, timeout=12) as resp:
            est = json.loads(resp.read().decode("utf-8"))

        stale_protos = []
        for path in est.get("paths") or []:
            for hop in path or []:
                proto = str(hop.get("protocol") or "")
                pid = str(hop.get("pool_id") or "")
                if proto and pid:
                    liv = verify_pool_batcher_liveness(proto, pid)
                    if not liv.get("live", True):
                        logger.warning(
                            f"Quarantining stale pool on {proto} (last batch {liv.get('last_batch_age_h')}h ago): {liv.get('reason')}"
                        )
                        if proto not in exclude and proto not in stale_protos:
                            stale_protos.append(proto)
        if not stale_protos or only_protocols:
            return est, estimate_params
        exclude.extend(stale_protos)

    return est, estimate_params


def build_unsigned_swap_tx(sender_addr: str, estimate_params: dict[str, Any], min_amount_out: str) -> str:
    """Builds an unsigned transaction CBOR using Minswap Aggregator."""
    url = f"{MINSWAP_AGGREGATOR_BASE}/build-tx"
    payload = {
        "sender": sender_addr,
        "min_amount_out": str(min_amount_out),
        "estimate": estimate_params,
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", "User-Agent": "BlueLodge-SovereignSwapper/1.0"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            res = json.loads(resp.read().decode("utf-8"))
            return res["cbor"]
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8")
        friendly_err = None
        try:
            err_json = json.loads(err_body)
            msg = err_json.get("message", "")
            err_detail = err_json.get("details", {}).get("error", {})
            if "Insufficient balance" in msg or err_detail.get("missingQty"):
                missing = err_detail.get("missingQty", "unknown")
                asset = err_detail.get("asset", "unknown")
                friendly_err = (
                    f"Minswap build-tx rejected: Wallet does not hold required input UTxO for asset '{asset}' (missing: {missing}). "
                    f"On Cardano, acquired token UTxOs must be confirmed on-chain before a sell transaction can be constructed."
                )
        except Exception:
            pass
        if friendly_err:
            raise ValueError(friendly_err)
        raise ValueError(f"Minswap build-tx failed (HTTP {e.code}): {err_body}")


def build_direct_swap_tx(
    sender_addr: str,
    estimate_params: dict[str, Any],
    min_amount_out: str,
    blockfrost_id: str,
    network_str: str = "mainnet",
) -> str:
    """Builds a direct swap transaction CBOR that sends directly to the DEX order script,
    completely stripping out the 0.85 ADA aggregator fee output and returning the savings to the user's change address."""
    # 1. Get standard unsigned tx containing the compiled DEX order script output and datum
    agg_cbor = build_unsigned_swap_tx(sender_addr, estimate_params, min_amount_out)

    try:
        tx_agg = Transaction.from_cbor(agg_cbor)
        outputs = tx_agg.transaction_body.outputs

        # Check if aggregator fee output exists (typically output #1 with ~850,000 lovelace)
        if len(outputs) < 2:
            return agg_cbor

        dex_order_output = outputs[0]

        # 2. Build direct transaction with PyCardano TransactionBuilder
        base_url = normalize_blockfrost_base_url(os.getenv("BLOCKFROST_BASE_URL"))
        context = BlockFrostChainContext(
            project_id=blockfrost_id,
            base_url=base_url,
            network=Network.MAINNET if network_str == "mainnet" else Network.TESTNET,
        )

        builder = TransactionBuilder(context)
        builder.add_input_address(Address.from_primitive(sender_addr))
        builder.add_output(dex_order_output)

        # Build transaction returning change directly to sender
        direct_body = builder.build(change_address=Address.from_primitive(sender_addr))
        direct_tx = Transaction(
            transaction_body=direct_body,
            transaction_witness_set=TransactionWitnessSet(),
        )
        direct_cbor = direct_tx.to_cbor().hex()

        logger.info("[DIRECT_AMM] Direct swap transaction successfully built: Aggregator fee eliminated, saved 0.85 ADA!")
        return direct_cbor
    except Exception as e:
        logger.warning(f"[DIRECT_AMM] Direct swap build failed ({e}); falling back to standard aggregator transaction.")
        return agg_cbor


def sign_and_submit_swap_tx(
    cbor_hex: str,
    skey: PaymentSigningKey,
    blockfrost_id: str,
    dry_run: bool = False,
) -> tuple[str, str]:
    """Signs the swap transaction and broadcasts to Cardano Mainnet."""
    tx = Transaction.from_cbor(cbor_hex)
    tx_hash_bytes = tx.transaction_body.hash()
    signature = skey.sign(tx_hash_bytes)
    vkey_witness = VerificationKeyWitness(skey.to_verification_key(), signature)

    if tx.transaction_witness_set is None:
        tx.transaction_witness_set = TransactionWitnessSet(vkey_witnesses=[vkey_witness])
    elif tx.transaction_witness_set.vkey_witnesses is None:
        tx.transaction_witness_set.vkey_witnesses = [vkey_witness]
    else:
        tx.transaction_witness_set.vkey_witnesses.append(vkey_witness)

    tx_id = str(tx.id)
    signed_cbor = tx.to_cbor().hex()

    if dry_run:
        logger.info(f"[DRY-RUN] Transaction constructed & signed successfully. Tx ID: {tx_id}")
        return tx_id, signed_cbor

    # Broadcast via Blockfrost
    try:
        base_url = normalize_blockfrost_base_url(os.getenv("BLOCKFROST_BASE_URL"))
        context = BlockFrostChainContext(
            project_id=blockfrost_id,
            base_url=base_url,
        )
        context.submit_tx_cbor(signed_cbor)
        logger.info(f"[SUBMITTED] Cardano DEX Swap successfully mined via Blockfrost! Tx ID: {tx_id}")
    except Exception as e:
        logger.warning(f"Blockfrost submission failed: {e}. Trying Minswap finalize endpoint...")
        submit_url = f"{MINSWAP_AGGREGATOR_BASE}/finalize-and-submit-tx"
        submit_req = urllib.request.Request(
            submit_url,
            data=json.dumps({"cbor": signed_cbor}).encode("utf-8"),
            headers={"Content-Type": "application/json", "User-Agent": "BlueLodge-SovereignSwapper/1.0"},
        )
        with urllib.request.urlopen(submit_req, timeout=15) as submit_resp:
            submit_data = json.loads(submit_resp.read().decode("utf-8"))
            logger.info(f"[SUBMITTED] Cardano DEX Swap submitted via Minswap! Response: {submit_data}")

    return tx_id, signed_cbor


def execute_dex_swap(
    amount: float,
    from_token: str = "ADA",
    to_token: str = "SNEK",
    slippage: float = DEFAULT_SLIPPAGE,
    dry_run: bool = True,
    direct: bool = True,
    auto_relist: bool = True,
) -> dict[str, Any]:
    """High-level fiduciary execution wrapper for Cardano DEX swaps (Bidirectional: Buy or Sell)."""
    env = load_env_vars()
    blockfrost_id = env.get("BLOCKFROST_PROJECT_ID", "")
    sender_addr = env.get("CARDANO_HOT_WALLET_ADDR") or env.get("CARDANO_WALLET_ADDR", "")
    skey = None
    try:
        from lib.tools.wallet import keystore
        k_addr, skey = keystore.cardano_signer(None, None)
        if not sender_addr:
            sender_addr = k_addr
    except Exception:
        if WALLET_KEY_FILE.exists():
            skey = PaymentSigningKey.load(str(WALLET_KEY_FILE))
    if not sender_addr:
        raise ValueError("CARDANO_HOT_WALLET_ADDR / CARDANO_WALLET_ADDR is not set (.george/secrets.env)")
    if skey is None:
        raise FileNotFoundError(f"Signing key not found in keystore or at {WALLET_KEY_FILE}")

    from_sym = from_token.upper()
    to_sym = to_token.upper()

    # Read current spendable balance
    spendable_ada = 0.0
    if STATUS_CACHE.exists():
        try:
            cdata = json.loads(STATUS_CACHE.read_text())
            cardano_info = cdata.get("cardano", {})
            spendable_ada = float(cardano_info.get("spendable_ada", 0.0))
            if spendable_ada <= 0.0 and "total_ada" in cardano_info:
                spendable_ada = max(0.0, float(cardano_info["total_ada"]) - HARD_RESERVE_FLOOR_ADA)
        except Exception:
            pass

    # Fiduciary Checks when spending ADA
    if from_sym in ["ADA", "LOVELACE"]:
        if amount > MAX_SINGLE_SWAP_ADA:
            raise ValueError(f"Swap amount {amount:.2f} ADA exceeds risk ceiling of {MAX_SINGLE_SWAP_ADA:.2f} ADA")

        remaining = spendable_ada - amount
        if not dry_run and remaining < 0:
            raise ValueError(
                f"Swap leaves {remaining:.2f} ADA, violating the {HARD_RESERVE_FLOOR_ADA:.2f} ADA untouchable reserve floor"
            )
        amount_in_base = int(amount * 1_000_000)
    else:
        # Native asset input
        tok_meta_in = TOKEN_METADATA.get(from_sym, {"decimals": 6})
        dec_in = tok_meta_in.get("decimals", 6)
        amount_in_base = int(amount * (10 ** dec_in))

    tok_meta_out = TOKEN_METADATA.get(to_sym, {"decimals": 6})
    decimals_out = tok_meta_out.get("decimals", 6)

    # 1. Estimate
    logger.info(f"Estimating optimal route to swap {amount} {from_sym} into {to_sym}...")
    est, est_params = estimate_swap_route(amount_in_base, from_sym, to_sym, slippage)
    raw_amount_out = int(est.get("amount_out", "0"))
    raw_min_out = int(est.get("min_amount_out", "0"))
    price_impact = est.get("avg_price_impact", 0.0)
    protocol = est.get("paths", [[{}]])[0][0].get("protocol", "Aggregated AMM")

    human_amount_out = raw_amount_out / (10 ** decimals_out)
    human_min_out = raw_min_out / (10 ** decimals_out)

    # 2. Build Unsigned Tx (Direct AMM eliminates 0.85 ADA aggregator toll)
    if direct:
        logger.info(f"Building direct AMM transaction (Route: {protocol}, eliminating aggregator fee)...")
        cbor = build_direct_swap_tx(sender_addr, est_params, est["min_amount_out"], blockfrost_id)
    else:
        logger.info(f"Building unsigned transaction via Minswap Aggregator (Route: {protocol})...")
        cbor = build_unsigned_swap_tx(sender_addr, est_params, est["min_amount_out"])

    # 3. Sign & Submit
    tx_id, signed_cbor = sign_and_submit_swap_tx(cbor, skey, blockfrost_id, dry_run=dry_run)

    # Automatic sale relisting using the same process as limit orders
    relist_info = None
    if auto_relist and from_sym in ["ADA", "LOVELACE"] and to_sym not in ["ADA", "LOVELACE"]:
        tokens_received = human_amount_out if human_amount_out > 0 else human_min_out
        if tokens_received > 0:
            try:
                from lib.tools.cardano_maker_db import record_dex_swap_fill
                relist_info = record_dex_swap_fill(
                    asset=to_sym,
                    tokens_filled=tokens_received,
                    cost_basis_ada=amount,
                    tx_id=tx_id,
                    protocol=protocol,
                    is_simulated=dry_run,
                    auto_relist=True,
                    metadata={"source": "dex_swap", "protocol": protocol, "slippage_pct": slippage * 100},
                )
                logger.info(f"Automatic maker sell relisting triggered for {to_sym} ({tokens_received} tokens): {relist_info.get('order_id')}")
            except Exception as e:
                logger.warning(f"Automatic sale relisting failed: {e}")
                relist_info = {"status": "error", "error": str(e)}

    return {
        "status": "success",
        "dry_run": dry_run,
        "direct_amm": direct,
        "tx_id": tx_id,
        "protocol": protocol,
        "input_amount": amount,
        "input_token": from_sym,
        "output_token": to_sym,
        "estimated_amount_out": f"{human_amount_out:.4f}" if decimals_out > 0 else f"{int(human_amount_out)}",
        "minimum_amount_out": f"{human_min_out:.4f}" if decimals_out > 0 else f"{int(human_min_out)}",
        "price_impact_pct": round(price_impact, 2),
        "cardanoscan_url": f"https://cardanoscan.io/transaction/{tx_id}",
        "auto_relist": relist_info,
    }


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Sovereign Cardano DEX Swapper (Bidirectional)")
    parser.add_argument("--amount", type=float, default=10.0, help="Amount of input asset to swap")
    parser.add_argument("--token", default=None, help="Target token symbol (SNEK, MIN, WMTX, DJED, IAG)")
    parser.add_argument("--from-token", default=None, help="Source token (default: ADA)")
    parser.add_argument("--to-token", default=None, help="Target token (default: SNEK)")
    parser.add_argument("--direction", choices=["buy", "sell"], default="buy", help="Swap direction relative to token (buy=ADA->token, sell=token->ADA)")
    parser.add_argument("--slippage", type=float, default=DEFAULT_SLIPPAGE, help="Max slippage tolerance (e.g. 0.02)")
    parser.add_argument("--execute", action="store_true", help="Execute real live transaction on Mainnet")
    parser.add_argument("--dry-run", action="store_true", help="Construct and sign transaction without network broadcast")
    parser.add_argument("--no-direct", action="store_true", help="Include third-party aggregator fee rather than direct AMM order")
    parser.add_argument("--no-auto-relist", action="store_true", help="Disable automatic maker sell relisting after buy swap")
    parser.add_argument("--json", action="store_true", help="Output pure JSON payload")
    args = parser.parse_args()

    is_dry_run = not args.execute

    # Resolve from_token and to_token
    if args.direction == "sell":
        from_tok = args.from_token or args.token or "IAG"
        to_tok = args.to_token or "ADA"
    else:
        from_tok = args.from_token or "ADA"
        to_tok = args.to_token or args.token or "SNEK"

    if args.json:
        try:
            res = execute_dex_swap(
                amount=args.amount,
                from_token=from_tok,
                to_token=to_tok,
                slippage=args.slippage,
                dry_run=is_dry_run,
                direct=not args.no_direct,
                auto_relist=not args.no_auto_relist,
            )
            print(json.dumps(res))
            return
        except Exception as e:
            print(json.dumps({"status": "error", "error": str(e)}))
            sys.exit(1)

    print("\n" + "=" * 80)
    print("  SOVEREIGN CARDANO DEX SWAPPER & EXECUTION ENGINE")
    print("=" * 80)
    mode_str = "\033[1;33m[DRY-RUN SIMULATION (SAFE)]\033[0m" if is_dry_run else "\033[1;31m[LIVE MAINNET EXECUTION]\033[0m"
    print(f"  Execution Mode: {mode_str}")
    print(f"  Swap Intent:    {args.amount} {from_tok.upper()} -> {to_tok.upper()} (Max Slippage: {args.slippage:.1%})")
    print(f"  Routing Model:  {'Direct AMM (0.85 ADA Aggregator Fee Eliminated)' if not args.no_direct else 'Minswap Aggregator (With Aggregator Fee)'}")
    print("-" * 80)

    try:
        res = execute_dex_swap(
            amount=args.amount,
            from_token=from_tok,
            to_token=to_tok,
            slippage=args.slippage,
            dry_run=is_dry_run,
            direct=not args.no_direct,
            auto_relist=not args.no_auto_relist,
        )
        print(f"  Transaction ID:         {res['tx_id']}")
        print(f"  Route Protocol:         {res['protocol']}")
        print(f"  Estimated Output:       {res['estimated_amount_out']} {res['output_token']}")
        print(f"  Guaranteed Minimum:     {res['minimum_amount_out']} {res['output_token']}")
        print(f"  Expected Price Impact:  {res['price_impact_pct']:.2f}%")
        print(f"  Cardanoscan URL:        {res['cardanoscan_url']}")
        print("-" * 80)
        status_msg = "Transaction verified & ready." if is_dry_run else "TRANSACTION BROADCASTED TO CARDANO MAINNET!"
        print(f"  Result: \033[1;32m{status_msg}\033[0m")
    except Exception as e:
        print(f"  \033[1;31mExecution Failed:\033[0m {e}")
    print("=" * 80 + "\n")


if __name__ == "__main__":
    main()
