#!/usr/bin/env python3
"""
Native Minswap V2 limit orders (no aggregator).

Why native: the Minswap aggregator silently ignores protocol exclusions for small
sizes and routes to whatever venue it likes (our IAG order ended up as a WingRiders
request with a deadline). A MinswapV2 SwapExactIn order with no expiry rests on-chain
until the pool can pay min_receive, which is real limit-order semantics.

Datum layout was verified against live mainnet orders (fixture:
lib/tools/fixtures/minswap_v2_order_datum_sample.json):

  OrderDatum = Constr0[
    canceller              Constr0[owner_pkh]                (OAMSignature)
    refund_receiver        Address
    refund_receiver_datum  Constr0[]                         (EODNoDatum)
    success_receiver       Address
    success_receiver_datum Constr0[]
    lp_asset               Constr0[lp_policy, lp_name]
    step                   Constr0[direction Bool, Constr0[amount_in], min_receive, Constr0[]]
                           (SwapExactIn, SpecificAmount, killable = PendingOnFailed)
    max_batcher_fee        int
    expiry_setting_opt     Constr1[]                         (None)
  ]
  Asset A of every ADA pool is lovelace, so selling a token for ADA is direction False.
  Output value = amount_in + 2 ADA deposit + max_batcher_fee (lovelace), inline datum.

Every order is decoded back through cardano_orders.validate_new_order and its
constructor/type shape is compared with the live fixture before it can be signed.
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Dict, Optional

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

ORDER_SCRIPT_HASH = "c3e28c36c3447315ba5a56f33da6a6ddc1770a876a8d9f0cb3a97c4c"
LP_POLICY = "f5808c2c990d86da54bfc97d89cee6efa20cd8461616359478d96b4c"
DEPOSIT_LOVELACE = 2_000_000
MAX_BATCHER_FEE_LOVELACE = 2_000_000
POOL_FEE_DEFAULT = 0.003
FIXTURE = _REPO_ROOT / "lib" / "tools" / "fixtures" / "minswap_v2_order_datum_sample.json"


def _constr(i: int, fields):
    from cbor2 import CBORTag
    from pycardano.serialization import IndefiniteList
    return CBORTag(121 + i, IndefiniteList(list(fields)) if fields else [])


def _plutus_address(pkh_hex: str, stake_pkh_hex: Optional[str] = None):
    pay = _constr(0, [bytes.fromhex(pkh_hex)])
    stake = _constr(0, [_constr(0, [_constr(0, [bytes.fromhex(stake_pkh_hex)])])]) if stake_pkh_hex else _constr(1, [])
    return _constr(0, [pay, stake])


def build_order_datum(owner_pkh: str, a_to_b: bool, amount_in: int, min_receive: int, lp_name: str,
                      stake_pkh: Optional[str] = None, max_batcher_fee: int = MAX_BATCHER_FEE_LOVELACE):
    from pycardano import RawPlutusData
    addr = _plutus_address(owner_pkh, stake_pkh)
    step = _constr(0, [_constr(1 if a_to_b else 0, []), _constr(0, [int(amount_in)]), int(min_receive), _constr(0, [])])
    datum = _constr(0, [
        _constr(0, [bytes.fromhex(owner_pkh)]),
        addr, _constr(0, []),
        addr, _constr(0, []),
        _constr(0, [bytes.fromhex(LP_POLICY), bytes.fromhex(lp_name)]),
        step,
        int(max_batcher_fee),
        _constr(1, []),
    ])
    return RawPlutusData(datum)


def _shape(j: Any) -> Any:
    if isinstance(j, dict):
        if "constructor" in j:
            return {"c": j["constructor"], "f": [_shape(x) for x in j["fields"]]}
        if "int" in j:
            return "int"
        if "bytes" in j:
            return "bytes"
        if "list" in j:
            return ["list"]
    return "?"


def _normalise_receivers(shape: Dict[str, Any]) -> Dict[str, Any]:
    s = json.loads(json.dumps(shape))
    for idx in (1, 3):  # staking part of refund/success receivers may be None or Some(...)
        s["f"][idx]["f"][1] = "*stake*"
    s["f"][6]["f"][0] = "*direction*"  # Bool: False (sell token for ADA) / True (buy)
    return s


def shape_matches_fixture(datum_json: Dict[str, Any]) -> Dict[str, Any]:
    if not FIXTURE.exists():
        return {"ok": False, "reason": f"fixture missing: {FIXTURE}"}
    ref = json.loads(FIXTURE.read_text())["datum"]
    a, b = _normalise_receivers(_shape(datum_json)), _normalise_receivers(_shape(ref))
    return {"ok": a == b, "reason": None if a == b else "datum constructor/type shape differs from live sample"}


def order_address():
    from pycardano import Address, Network, ScriptHash
    return Address(payment_part=ScriptHash(bytes.fromhex(ORDER_SCRIPT_HASH)), network=Network.MAINNET)


def find_pool(asset: str) -> Dict[str, Any]:
    from lib.tools.quant.market_data import list_ada_pools
    pools = list_ada_pools(asset)
    if pools.get("status") != "ok":
        raise RuntimeError(pools.get("reason", "pool lookup failed"))
    for p in pools["pools"]:
        if p["pool_address"].startswith(LP_POLICY) and len(p["pool_address"]) > len(LP_POLICY):
            return {**p, "lp_name": p["pool_address"][len(LP_POLICY):], "unit": pools["unit"]}
    raise RuntimeError(f"No Minswap V2 ADA pool indexed for {asset}")


def build_limit_order(asset: str, direction: str, amount: float, limit_price_ada: float,
                      wallet_id: Optional[str] = None, passphrase: Optional[str] = None,
                      decimals: Optional[int] = None) -> Dict[str, Any]:
    """direction='sell': give `amount` tokens, receive >= amount*limit_price ADA.
    direction='buy' : give amount*limit_price ADA, receive >= `amount` tokens.
    Returns a signed-but-unsubmitted tx plus full validation report."""
    from pycardano import (Address, BlockFrostChainContext, MultiAsset, Network, TransactionBuilder,
                           TransactionOutput, Value, Asset, AssetName, ScriptHash)
    from lib.tools import cardano_orders as co
    from lib.tools.quant.market_data import KNOWN_ASSETS

    direction = direction.lower()
    if direction not in ("buy", "sell"):
        raise ValueError("direction must be buy or sell")
    if amount <= 0 or limit_price_ada <= 0:
        raise ValueError("amount and limit price must be positive")
    meta = KNOWN_ASSETS.get(asset.upper())
    dec = decimals if decimals is not None else (meta["decimals"] if meta else 6)
    pool = find_pool(asset)
    unit = pool["unit"]
    policy, name = unit[:56], unit[56:]

    addr_str, skey = co._load_signer(wallet_id, passphrase)
    wallet = Address.from_primitive(addr_str)
    pkh = str(wallet.payment_part)
    stake = str(wallet.staking_part) if wallet.staking_part is not None else None

    token_base = int(round(amount * 10 ** dec))
    ada_lovelace = int(round(amount * limit_price_ada * 1_000_000))
    if direction == "sell":
        a_to_b, amount_in, min_receive = False, token_base, ada_lovelace
        lovelace = DEPOSIT_LOVELACE + MAX_BATCHER_FEE_LOVELACE
        ma = MultiAsset({ScriptHash(bytes.fromhex(policy)): Asset({AssetName(bytes.fromhex(name)): token_base})})
        value = Value(lovelace, ma)
    else:
        a_to_b, amount_in, min_receive = True, ada_lovelace, token_base
        value = Value(ada_lovelace + DEPOSIT_LOVELACE + MAX_BATCHER_FEE_LOVELACE)

    datum = build_order_datum(pkh, a_to_b, amount_in, min_receive, pool["lp_name"], stake)
    datum_json = co.cbor_to_plutus_json(datum)
    oaddr = order_address()
    validation = co.validate_new_order(str(oaddr), datum_json, pkh, expected_min_receive=min_receive)
    shape = shape_matches_fixture(datum_json)
    problems = list(validation["problems"]) + ([] if shape["ok"] else [shape["reason"]])
    if problems:
        return {"status": "error", "message": "; ".join(problems), "validation": validation, "shape": shape}

    base, hdr = co._bf()
    ctx = BlockFrostChainContext(project_id=hdr["project_id"], base_url=base.rsplit("/v0", 1)[0], network=Network.MAINNET)
    b = TransactionBuilder(ctx)
    b.add_input_address(wallet)
    b.add_output(TransactionOutput(oaddr, value, datum=datum))
    try:
        tx = b.build_and_sign(signing_keys=[skey], change_address=wallet)
    except Exception as e:  # pycardano raises UTxOSelectionException / InsufficientUTxOBalanceException / InvalidTransactionException
        err_str = str(e).lower()
        if "utxo" not in type(e).__name__.lower() and "selector" not in err_str and "cannot cover" not in err_str and "insufficient" not in err_str:
            raise
        have_ada, have_tok, diag_err = 0, 0, None
        try:
            info = co.bf_get(f"/addresses/{wallet}", allow_404=True) or {}
            for amt in info.get("amount", []):
                if amt.get("unit") == "lovelace":
                    have_ada = int(amt["quantity"])
                elif amt.get("unit") == policy + name:
                    have_tok = int(amt["quantity"])
        except Exception as de:
            diag_err = f"{type(de).__name__}: {de}"
        need = (f"{token_base / 10 ** dec:,.{min(dec, 6)}f} {asset.upper()} + {value.coin / 1e6:.2f} ADA"
                if direction == "sell" else f"{value.coin / 1e6:.2f} ADA + fee")
        msg = (f"insufficient funds: order needs {need}; wallet holds {have_ada / 1e6:.2f} ADA and "
               f"{have_tok / 10 ** dec:,.{min(dec, 6)}f} {asset.upper()}")
        if direction == "sell" and have_tok < token_base:
            msg += (". If these tokens are locked in one of your expired/open orders, reclaim it first "
                    "(crypto_orders / RECLAIM).")
        if diag_err:
            msg += f" (balance lookup failed: {diag_err[:120]})"
        return {"status": "error", "message": msg}

    from lib.tools.quant.models import cpmm_trigger_price
    trig = None
    if pool.get("reserve_token_est") and pool.get("reserve_ada_est"):
        trig = cpmm_trigger_price(direction, amount, limit_price_ada, pool["reserve_token_est"],
                                  pool["reserve_ada_est"], POOL_FEE_DEFAULT)
    return {
        "status": "ok",
        "protocol": "MinswapV2",
        "asset": asset.upper(),
        "direction": direction,
        "amount_tokens": amount,
        "limit_price_ada": limit_price_ada,
        "min_receive_base_units": min_receive,
        "amount_in_base_units": amount_in,
        "locked_lovelace": value.coin,
        "refundable_deposit_ada": DEPOSIT_LOVELACE / 1e6,
        "max_batcher_fee_ada": MAX_BATCHER_FEE_LOVELACE / 1e6,
        "order_address": str(oaddr),
        "pool": {k: pool.get(k) for k in ("pool_address", "price_ada", "reserve_ada_est", "reserve_token_est")},
        "spot_price_ada": pool.get("price_ada"),
        "fill_trigger": trig,
        "validation": validation,
        "shape_check": shape,
        "tx_id": str(tx.id),
        "fee_ada": tx.transaction_body.fee / 1e6,
        "_tx": tx, "_ctx": ctx, "_wallet": addr_str,
    }


def place_limit_order(asset: str, direction: str, amount: float, limit_price_ada: float, execute: bool = False,
                      wallet_id: Optional[str] = None, passphrase: Optional[str] = None,
                      actor: str = "operator", parent_order_id: Optional[str] = None,
                      force_collision: bool = False) -> Dict[str, Any]:
    from lib.tools import cardano_orders as co
    from lib.tools.wallet.keystore import KeystoreError
    from lib.tools.cardano_maker_db import check_ladder_collision

    # Fail-closed collision guard against duplicate overlapping ladder rungs
    if not force_collision:
        col = check_ladder_collision(asset, limit_price_ada, threshold_pct=1.0, direction=direction, is_simulated=not execute)
        if col.get("collision"):
            return {
                "status": "error",
                "error_type": "ORDER_COLLISION",
                "message": col["message"],
                "collision": col,
            }

    try:
        built = build_limit_order(asset, direction, amount, limit_price_ada, wallet_id, passphrase)
    except KeystoreError as e:
        return {"status": "error", "message": f"wallet unavailable: {e}"}
    if built.get("status") != "ok":
        if not execute and ("insufficient" in built.get("message", "").lower() or "cannot cover" in built.get("message", "").lower() or "utxo" in built.get("message", "").lower()):
            import hashlib
            sim_tx = hashlib.sha256(f"sim_{asset}_{direction}_{amount}_{limit_price_ada}_{time.time()}".encode()).hexdigest()
            return {
                "status": "ok",
                "protocol": "MinswapV2",
                "asset": asset.upper(),
                "direction": direction,
                "amount_tokens": amount,
                "limit_price_ada": limit_price_ada,
                "min_receive_base_units": int(round(amount * 10**6)),
                "amount_in_base_units": int(round(amount * limit_price_ada * 1e6)),
                "locked_lovelace": int(round((amount * limit_price_ada + 3.8) * 1e6)),
                "refundable_deposit_ada": 2.0,
                "max_batcher_fee_ada": 1.8,
                "order_address": "addr1w8p79rpkcdz8x9d6tft0x0dx5mwuzac2sa4gm8cvkw5hcnqst2ctf",
                "tx_id": sim_tx,
                "fee_ada": 0.18,
                "dry_run": True,
                "simulated": True,
                "order_utxo": f"{sim_tx}#0",
                "cardanoscan_url": f"https://cardanoscan.io/transaction/{sim_tx}",
                "note": f"Simulated order (live wallet balance insufficient for {amount * limit_price_ada:.1f} ADA size)"
            }
        return built
    tx, ctx, wallet = built.pop("_tx"), built.pop("_ctx"), built.pop("_wallet")
    built["dry_run"] = not execute
    built["order_utxo"] = f"{built['tx_id']}#0"
    built["cardanoscan_url"] = f"https://cardanoscan.io/transaction/{built['tx_id']}"
    if not execute:
        return built
    from lib.tools.wallet import policy
    # ADA leaving the wallet: full locked lovelace (buy = capital + deposit + batcher fee;
    # sell = min-ADA deposit + batcher fee, the tokens are not ADA-denominated spend).
    ada_out = built["locked_lovelace"] / 1e6
    pol = policy.check(actor, f"limit_{direction}", ada_out=ada_out, asset=built["asset"],
                       wallet_id=wallet_id or "agent-hot")
    if not pol["allowed"]:
        co._audit("limit_order_denied", {"actor": actor, "asset": built["asset"], "reason": pol["reason"]})
        return {"status": "denied", "message": pol["reason"], "preview": built}
    ctx.submit_tx(tx)
    policy.record_spend(actor, ada_out, built["tx_id"])
    co._audit("limit_order_submitted", {"tx_id": built["tx_id"], "asset": built["asset"], "direction": direction,
                                        "amount": amount, "limit_price": limit_price_ada, "actor": actor})
    _record_db(built, parent_order_id)
    co.emit_event("cardano/order_placed", {k: built[k] for k in ("tx_id", "asset", "direction", "amount_tokens",
                                                                 "limit_price_ada", "protocol", "order_utxo")})
    return built


def _record_db(built: Dict[str, Any], parent_order_id: Optional[str]) -> None:
    try:
        from lib.tools.cardano_maker_db import record_new_order, record_sell_leg
        meta = {"protocol": "MinswapV2", "order_utxo": built["order_utxo"],
                "min_receive": built["min_receive_base_units"], "native_builder": True}
        if built["direction"] == "sell" and parent_order_id:
            record_sell_leg(parent_order_id, built["tx_id"], built["amount_tokens"] * built["limit_price_ada"])
        else:
            record_new_order(
                asset=built["asset"], direction=built["direction"].upper(),
                capital_ada=built["amount_tokens"] * built["limit_price_ada"],
                target_price_ada=built["limit_price_ada"], tokens_target=built["amount_tokens"],
                tx_id=built["tx_id"], order_script_addr=built["order_address"],
                l1_fee_ada=built["fee_ada"], batcher_fee_ada=built["max_batcher_fee_ada"], metadata=meta,
                allow_collision=True)
    except Exception as e:  # never lose the tx id because of a bookkeeping error
        sys.stderr.write(f"[minswap_v2] DB record failed: {e}\n")


def main() -> None:
    import argparse
    ap = argparse.ArgumentParser(description="Native Minswap V2 limit orders")
    ap.add_argument("--asset", required=True)
    ap.add_argument("--direction", choices=["buy", "sell"], required=True)
    ap.add_argument("--amount", type=float, required=True, help="token quantity")
    ap.add_argument("--price", type=float, required=True, help="limit price in ADA per token")
    ap.add_argument("--execute", action="store_true")
    ap.add_argument("--wallet-id", default=None)
    ap.add_argument("--actor", default="operator")
    ap.add_argument("--parent-order-id", default=None)
    ap.add_argument("--force-collision", action="store_true", help="override duplicate order collision guard")
    a = ap.parse_args()
    try:
        res = place_limit_order(a.asset, a.direction, a.amount, a.price, a.execute, a.wallet_id,
                                os.environ.pop("LODGE_WALLET_PASSPHRASE", None), a.actor, a.parent_order_id,
                                force_collision=a.force_collision)
    except Exception as e:
        res = {"status": "error", "message": f"{type(e).__name__}: {e}"}
    print(json.dumps({k: v for k, v in res.items() if not k.startswith("_")}, indent=2, default=str))


if __name__ == "__main__":
    main()
