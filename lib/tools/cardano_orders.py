#!/usr/bin/env python3
"""
Cardano DEX order lifecycle: discover -> decode -> status -> reclaim -> verify.

Why this exists
---------------
The previous tooling labelled every resting order "MinswapV2", never read the
on-chain datum, and could not tell an open order from one whose deadline had
passed. Our IAG order turned out to be a WingRiders V1 *swap request* with a
deadline, i.e. it could never fill after that moment. This module reads truth
from the chain:

* Protocol registry keyed by order-validator script hash.
* Datum decoders that extract owner, deadline, direction and minimum receive.
* Status: OPEN / EXPIRED / FILLED / CANCELLED, derived from chain state.
* Reclaim that refuses to build unless the datum owner is our key, tries the
  protocol's candidate redeemers, and only accepts one that passes Plutus
  evaluation (Ogmios via Blockfrost) before anything can be broadcast.
* Post-submit verification: polls until the order UTxO is consumed by our tx and
  reports the wallet balance delta, so "funds came back" is proven, not assumed.

Live broadcast only happens with execute=True; the default is a dry run.
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if __name__ == "__main__" and _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path.home() / "blue-lodge"))
GEORGE_DIR = Path(os.environ.get("GEORGE_DIR", LODGE_DIR / ".george"))
EVENT_BUS_FIFO = GEORGE_DIR / "ipc" / "event_bus.fifo"
ADA = "lovelace"


# ---------------------------------------------------------------------------
# Blockfrost access
# ---------------------------------------------------------------------------

def _env() -> Dict[str, str]:
    from lib.tools.cardano_dex_swapper import load_env_vars
    return load_env_vars()


def _bf() -> Tuple[str, Dict[str, str]]:
    dolos_url = os.getenv("DOLOS_MINIBF_URL", "http://127.0.0.1:8000/api/v0").rstrip("/")
    try:
        req = urllib.request.Request(f"{dolos_url}/epochs/latest", headers={"User-Agent": "BlueLodge-Dolos/1.0"})
        with urllib.request.urlopen(req, timeout=0.3) as resp:
            if resp.status == 200:
                return dolos_url, {"project_id": "dolos_local", "User-Agent": "BlueLodge-Dolos/1.0"}
    except Exception:
        pass

    env = _env()
    pid = env.get("BLOCKFROST_PROJECT_ID", "")
    if not pid:
        raise RuntimeError("BLOCKFROST_PROJECT_ID missing from .george/secrets.env")
    base = env.get("BLOCKFROST_BASE_URL", "https://cardano-mainnet.blockfrost.io/api").rstrip("/")
    if not base.endswith("/v0"):
        base += "/v0"
    return base, {"project_id": pid, "User-Agent": "BlueLodge-Orders/2.0"}


def bf_get(path: str, allow_404: bool = False) -> Any:
    base, headers = _bf()
    req = urllib.request.Request(base + path, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        if allow_404 and e.code == 404:
            return None
        raise


def bf_evaluate(tx_cbor: bytes) -> Dict[str, Any]:
    base, headers = _bf()
    req = urllib.request.Request(base + "/utils/txs/evaluate", data=tx_cbor,
                                 headers={**headers, "Content-Type": "application/cbor"}, method="POST")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


# ---------------------------------------------------------------------------
# Plutus data helpers (Blockfrost json_value form)
# ---------------------------------------------------------------------------

def _c(node: Any) -> Optional[int]:
    return node.get("constructor") if isinstance(node, dict) else None


def _f(node: Any, i: int) -> Any:
    return node["fields"][i]


def _int(node: Any) -> Optional[int]:
    return node.get("int") if isinstance(node, dict) else None


def _bytes(node: Any) -> Optional[str]:
    return node.get("bytes") if isinstance(node, dict) else None


def _asset(node: Any) -> str:
    pol, name = _bytes(_f(node, 0)), _bytes(_f(node, 1))
    return ADA if not pol else pol + (name or "")


def _addr_pkh(node: Any) -> Optional[str]:
    """Plutus Address = Constr0[payment_credential, staking_opt]; payment cred Constr0[pkh] | Constr1[script]."""
    try:
        cred = _f(node, 0)
        return _bytes(_f(cred, 0)) if _c(cred) == 0 else None
    except Exception:
        return None


def _all_bytes(node: Any) -> List[str]:
    out: List[str] = []
    if isinstance(node, dict):
        if "bytes" in node:
            out.append(node["bytes"])
        for v in node.values():
            if isinstance(v, (dict, list)):
                out.extend(_all_bytes(v))
    elif isinstance(node, list):
        for v in node:
            out.extend(_all_bytes(v))
    return out


# ---------------------------------------------------------------------------
# Protocol registry
# ---------------------------------------------------------------------------

def _decode_wingriders_v1(d: Dict[str, Any]) -> Dict[str, Any]:
    # RequestDatum = Constr0[ Constr0[beneficiary Address, owner PKH, deadline POSIX ms,
    #                                 Constr0[assetA, assetB]],
    #                         Constr0[direction (Constr0 A->B | Constr1 B->A), min_receive] ]
    meta, action = _f(d, 0), _f(d, 1)
    pair = _f(meta, 3)
    a, b = _asset(_f(pair, 0)), _asset(_f(pair, 1))
    a_to_b = _c(_f(action, 0)) == 0
    return {
        "owner_pkh": _bytes(_f(meta, 1)),
        "beneficiary_pkh": _addr_pkh(_f(meta, 0)),
        "deadline_ms": _int(_f(meta, 2)),
        "offer_asset": a if a_to_b else b,
        "ask_asset": b if a_to_b else a,
        "min_receive": _int(_f(action, 1)),
        "order_kind": "swap_request_with_deadline",
    }


def _decode_minswap_v2(d: Dict[str, Any]) -> Dict[str, Any]:
    # OrderDatum = Constr0[canceller, refund_receiver, refund_datum, success_receiver, success_datum,
    #                      lp_asset, step, max_batcher_fee, expiry_setting_opt]
    canceller = _f(d, 0)
    owner = _bytes(_f(canceller, 0)) if _c(canceller) == 0 else None
    step = _f(d, 6)
    out: Dict[str, Any] = {"owner_pkh": owner, "beneficiary_pkh": _addr_pkh(_f(d, 3)), "deadline_ms": None,
                           "order_kind": f"minswap_v2_step_{_c(step)}"}
    if _c(step) in (0, 1):  # SwapExactIn / StopLoss share [direction, amount_opt, min_receive|..., ...]
        out["a_to_b"] = _c(_f(step, 0)) == 1
        out["min_receive"] = _int(_f(step, 2))
        out["order_kind"] = "minswap_v2_swap_exact_in (true limit, no deadline unless expiry set)"
    try:
        exp = _f(d, 8)
        if _c(exp) == 0:
            out["deadline_ms"] = _int(_f(_f(exp, 0), 0))
    except Exception:
        pass
    return out


def _decode_minswap_v1(d: Dict[str, Any]) -> Dict[str, Any]:
    # OrderDatum = Constr0[sender Address, receiver Address, receiver_datum_hash_opt, step, batcher_fee, output_ada]
    step = _f(d, 3)
    out = {"owner_pkh": _addr_pkh(_f(d, 0)), "beneficiary_pkh": _addr_pkh(_f(d, 1)), "deadline_ms": None,
           "order_kind": f"minswap_v1_step_{_c(step)}"}
    if _c(step) == 0:
        out["ask_asset"] = _asset(_f(step, 0))
        out["min_receive"] = _int(_f(step, 1))
    return out


def _decode_lodge_escrow(d: Dict[str, Any]) -> Dict[str, Any]:
    # SovereignEscrowDatum = Constr0[fiduciary_pkh, beneficiary_pkh, principal_lovelace, yield_bps, nonce]
    return {"owner_pkh": _bytes(_f(d, 0)), "beneficiary_pkh": _bytes(_f(d, 1)), "deadline_ms": None,
            "principal_lovelace": _int(_f(d, 2)), "order_kind": "lodge_poc_escrow"}


# Scripts that were never witnessed on-chain (Blockfrost cannot serve their CBOR).
# Each entry is verified at load time: plutus_script_hash(cbor) must equal the key.
LOCAL_SCRIPTS: Dict[str, Tuple[str, str]] = {
    "f14241393964259a53ca546af364e7f5688ca5aaa35f1e0da0f951b2": ("plutusv2", "49480100002221200101"),
}


PROTOCOLS: Dict[str, Dict[str, Any]] = {
    "464eeee89f05aff787d40045af2a40a83fd96c513197d32fbc54ff02": {
        "name": "SplashLimit", "dex": "splash", "decoder": lambda d: {
            "owner_pkh": _bytes(_f(d, 10)), "beneficiary_pkh": _addr_pkh(_f(d, 9)), "deadline_ms": None,
            "offer_asset": _asset(_f(d, 2)), "min_receive": None, "order_kind": "splash_limit"},
        "cancel_redeemers": [0, 1], "limit_semantics": True,
        "note": "Splash (ex-Spectrum) limit order; cancellable by the key in the datum.",
    },
    "f14241393964259a53ca546af364e7f5688ca5aaa35f1e0da0f951b2": {
        "name": "LodgeEscrowPoC", "dex": None, "decoder": _decode_lodge_escrow,
        "cancel_redeemers": [0, 1], "limit_semantics": False,
        "note": ("George's 2026-10-02 proof-of-concept escrow. Its script bytes were triple CBOR-wrapped "
                  "(encoding bug), so the ledger cannot deserialise the validator: every redeemer fails "
                  "evaluation and the locked ADA is very likely permanently unrecoverable."),
    },
    "86ae9eebd8b97944a45201e4aec1330a72291af2d071644bba015959": {
        "name": "WingRidersV1", "dex": "wingriders", "decoder": _decode_wingriders_v1,
        "cancel_redeemers": [1, 0], "limit_semantics": False,
        "note": "Swap request with a hard deadline; batchers ignore it after the deadline.",
    },
    "c3e28c36c3447315ba5a56f33da6a6ddc1770a876a8d9f0cb3a97c4c": {
        "name": "MinswapV2", "dex": "minswap-cardano", "decoder": _decode_minswap_v2,
        "cancel_redeemers": [1, 0], "limit_semantics": True,
        "note": "Order rests until min_receive is achievable or cancelled (CancelOrderByOwner = Constr1).",
    },
    "a65ca58a4e9c755fa830173d2a5caed458ac0c73f97db7faae2e7e3b": {
        "name": "MinswapV1", "dex": "minswap-cardano", "decoder": _decode_minswap_v1,
        "cancel_redeemers": [1, 0], "limit_semantics": True, "note": "Legacy Minswap order.",
    },
}


def protocol_for_address(addr: str) -> Tuple[Optional[str], Optional[Dict[str, Any]]]:
    from pycardano import Address
    try:
        a = Address.from_primitive(addr)
    except Exception:
        return None, None
    h = str(a.payment_part)
    return h, PROTOCOLS.get(h)


def cbor_to_plutus_json(obj: Any) -> Any:
    """Converts decoded CBOR Plutus data (cbor2 CBORTag tree / pycardano objects) into the
    detailed-schema JSON used by Blockfrost, so the same decoders work pre-broadcast."""
    from cbor2 import CBORTag
    try:
        from pycardano import RawPlutusData, PlutusData
        if isinstance(obj, RawPlutusData):
            return cbor_to_plutus_json(obj.data)
        if isinstance(obj, PlutusData):
            return obj.to_dict()
    except ImportError:
        pass
    if isinstance(obj, CBORTag):
        if 121 <= obj.tag <= 127:
            return {"constructor": obj.tag - 121, "fields": [cbor_to_plutus_json(x) for x in obj.value]}
        if 1280 <= obj.tag <= 1400:
            return {"constructor": obj.tag - 1280 + 7, "fields": [cbor_to_plutus_json(x) for x in obj.value]}
        if obj.tag == 102:
            return {"constructor": obj.value[0], "fields": [cbor_to_plutus_json(x) for x in obj.value[1]]}
        if obj.tag in (2, 3):  # bignum
            n = int.from_bytes(obj.value, "big")
            return {"int": n if obj.tag == 2 else -1 - n}
    if isinstance(obj, bool):
        return {"int": int(obj)}
    if isinstance(obj, int):
        return {"int": obj}
    if isinstance(obj, (bytes, bytearray)):
        return {"bytes": bytes(obj).hex()}
    if isinstance(obj, dict):
        return {"map": [{"k": cbor_to_plutus_json(k), "v": cbor_to_plutus_json(v)} for k, v in obj.items()]}
    if isinstance(obj, (list, tuple)) or hasattr(obj, "__iter__"):
        return {"list": [cbor_to_plutus_json(x) for x in obj]}
    return obj


MIN_SAFE_DEADLINE_S = 7 * 86400


def validate_new_order(script_address: str, datum_json: Dict[str, Any], our_pkh: str,
                       expected_min_receive: Optional[int] = None,
                       require_limit_semantics: bool = True) -> Dict[str, Any]:
    """Pre-broadcast guard. Returns {"ok": bool, "problems": [...], "decoded": {...}}."""
    problems: List[str] = []
    script_hash, proto = protocol_for_address(script_address)
    decoded: Dict[str, Any] = {}
    if not proto:
        problems.append(f"order validator {script_hash} is not in the protocol registry")
    else:
        try:
            decoded = proto["decoder"](datum_json)
        except Exception as e:
            problems.append(f"datum does not decode as {proto['name']}: {e}")
        if require_limit_semantics and not proto["limit_semantics"]:
            problems.append(f"{proto['name']} orders expire at a deadline; not a resting limit order")
    if decoded:
        if decoded.get("owner_pkh") != our_pkh:
            problems.append(f"datum owner/canceller {decoded.get('owner_pkh')} != our key {our_pkh}")
        if expected_min_receive is not None and decoded.get("min_receive") != expected_min_receive:
            problems.append(f"min_receive {decoded.get('min_receive')} != intended {expected_min_receive}")
        dl = decoded.get("deadline_ms")
        if dl and dl / 1000 - time.time() < MIN_SAFE_DEADLINE_S:
            problems.append(f"order deadline {time.strftime('%Y-%m-%d %H:%M', time.gmtime(dl / 1000))}Z is under 7 days away")
    return {"ok": not problems, "problems": problems, "protocol": proto["name"] if proto else None,
            "decoded": decoded}


# ---------------------------------------------------------------------------
# Wallet / signer
# ---------------------------------------------------------------------------

def default_wallet() -> Tuple[str, str]:
    """(address, payment key hash) of the agent hot wallet."""
    from pycardano import Address
    env = _env()
    addr = env.get("CARDANO_WALLET_ADDR") or (GEORGE_DIR / "wallets" / "cardano_payment.addr").read_text().strip()
    return addr, str(Address.from_primitive(addr).payment_part)


def _load_signer(wallet_id: Optional[str], passphrase: Optional[str]):
    """Returns (address_str, PaymentSigningKey). Uses the keystore when available."""
    try:
        from lib.tools.wallet import keystore
        return keystore.cardano_signer(wallet_id, passphrase)
    except ImportError:
        from pycardano import PaymentSigningKey
        from lib.tools.cardano_dex_swapper import WALLET_KEY_FILE
        addr, _ = default_wallet()
        return addr, PaymentSigningKey.load(str(WALLET_KEY_FILE))


def wallet_balance(addr: str) -> Dict[str, int]:
    info = bf_get(f"/addresses/{addr}", allow_404=True)
    if not info:
        return {ADA: 0}
    return {a["unit"]: int(a["quantity"]) for a in info.get("amount", [])}


# ---------------------------------------------------------------------------
# Discovery and status
# ---------------------------------------------------------------------------

def _display_value(value: Dict[str, int]) -> List[str]:
    try:
        from lib.tools.quant.market_data import KNOWN_ASSETS
        known = {m["unit"]: (s, m["decimals"]) for s, m in KNOWN_ASSETS.items()}
    except Exception:
        known = {}
    out = []
    if value.get(ADA):
        out.append(f"{value[ADA] / 1e6:,.6f} ADA")
    for unit, q in value.items():
        if unit == ADA:
            continue
        if unit in known:
            sym, dec = known[unit]
            out.append(f"{q / 10 ** dec:,.{min(dec, 6)}f} {sym}")
        else:
            try:
                name = bytes.fromhex(unit[56:]).decode("ascii")
                name = name if name.isprintable() and name else unit[56:66]
            except Exception:
                name = unit[56:66]
            out.append(f"{q:,} {name} (base units)")
    return out


def _datum_json(out: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    dh = out.get("data_hash")
    if not dh:
        return None
    r = bf_get(f"/scripts/datum/{dh}", allow_404=True)
    return r.get("json_value") if r else None


def describe_order_output(tx_hash: str, index: int, out: Optional[Dict[str, Any]] = None,
                          our_pkh: Optional[str] = None) -> Dict[str, Any]:
    if out is None:
        utx = bf_get(f"/txs/{tx_hash}/utxos")
        out = next(o for o in utx["outputs"] if o["output_index"] == index)
    addr = out["address"]
    script_hash, proto = protocol_for_address(addr)
    datum = _datum_json(out)
    decoded: Dict[str, Any] = {}
    decode_error = None
    if proto and datum:
        try:
            decoded = proto["decoder"](datum)
        except Exception as e:  # malformed / different version
            decode_error = f"{type(e).__name__}: {e}"
    if our_pkh is None:
        _, our_pkh = default_wallet()
    owned = bool(decoded.get("owner_pkh") == our_pkh or (datum and our_pkh in _all_bytes(datum)))
    consumed_by = out.get("consumed_by_tx")
    now_ms = int(time.time() * 1000)
    deadline = decoded.get("deadline_ms")
    if consumed_by:
        status = "CONSUMED"
    elif deadline and deadline < now_ms:
        status = "EXPIRED"
    else:
        status = "OPEN"
    value = {a["unit"]: int(a["quantity"]) for a in out.get("amount", [])}
    res = {
        "utxo": f"{tx_hash}#{index}",
        "tx_hash": tx_hash,
        "output_index": index,
        "script_address": addr,
        "script_hash": script_hash,
        "protocol": proto["name"] if proto else "UNKNOWN",
        "venue_dex": proto["dex"] if proto else None,
        "limit_semantics": proto["limit_semantics"] if proto else None,
        "protocol_note": proto["note"] if proto else "Unrecognised order validator; reclaim will try generic redeemers.",
        "status": status,
        "owned_by_us": owned,
        "locked_value": value,
        "locked_display": _display_value(value),
        "datum": decoded,
        "decode_error": decode_error,
        "deadline_iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(deadline / 1000)) if deadline else None,
        "seconds_to_deadline": int(deadline / 1000 - time.time()) if deadline else None,
        "consumed_by_tx": consumed_by,
        "cardanoscan_url": f"https://cardanoscan.io/transaction/{tx_hash}",
    }
    if consumed_by:
        res["status"] = _classify_consumption(consumed_by, our_pkh)
    return res


def _classify_consumption(spend_tx: str, our_pkh: str) -> str:
    """CANCELLED if our key signed the spending tx (required signer / our input), else FILLED."""
    try:
        from pycardano import Address
        utx = bf_get(f"/txs/{spend_tx}/utxos")
        for i in utx.get("inputs", []):
            try:
                if str(Address.from_primitive(i["address"]).payment_part) == our_pkh:
                    return "CANCELLED"
            except Exception:
                continue
        return "FILLED"
    except Exception:
        return "CONSUMED"


def _lookup_db_price(tx_hash: str) -> Optional[float]:
    try:
        import sqlite3
        db_path = GEORGE_DIR / "finance" / "maker_orders.db"
        if not db_path.exists():
            return None
        with sqlite3.connect(str(db_path)) as conn:
            cur = conn.execute("SELECT target_price_ada FROM maker_orders WHERE tx_id = ? LIMIT 1", (tx_hash,))
            row = cur.fetchone()
            if row and row[0] is not None:
                return float(row[0])
    except Exception:
        pass
    return None


def compact_order(d: Dict[str, Any]) -> Dict[str, Any]:
    """Strips verbose Plutus datum internals into a compact representation for LLM context & fast discovery."""
    datum = d.get("datum") or {}
    a_to_b = datum.get("a_to_b")
    if a_to_b is True:
        dir_str = "BUY"
    elif a_to_b is False:
        dir_str = "SELL"
    else:
        dir_str = datum.get("direction") or "UNKNOWN"

    locked_val = d.get("locked_value") or {}
    lovelace = locked_val.get("lovelace", 0)
    locked_ada = round(lovelace / 1_000_000.0, 4) if lovelace else 0.0

    tx_hash = d.get("tx_hash", "")
    target_price = datum.get("target_price_ada") or datum.get("price_ada") or _lookup_db_price(tx_hash)

    return {
        "utxo": d.get("utxo"),
        "tx_hash": tx_hash,
        "output_index": d.get("output_index"),
        "protocol": d.get("protocol"),
        "venue_dex": d.get("venue_dex"),
        "status": d.get("status"),
        "locked_display": d.get("locked_display"),
        "locked_ada": locked_ada,
        "direction": dir_str,
        "target_price_ada": target_price,
        "min_receive": datum.get("min_receive"),
        "deadline_iso": d.get("deadline_iso"),
        "consumed_by_tx": d.get("consumed_by_tx"),
        "cardanoscan_url": d.get("cardanoscan_url"),
    }


def discover_orders(addr: Optional[str] = None, lookback_txs: int = 40,
                    include_closed: Optional[bool] = None,
                    status: str = "open",
                    compact: bool = True) -> Dict[str, Any]:
    """Scans our recent transactions for outputs sent to known (or any) script addresses whose datum
    references our key. Chain is the source of truth; the local DB is only annotated."""
    if include_closed is not None:
        status = "all" if include_closed else "open"
    status_lower = status.lower()
    if addr is None:
        addr, pkh = default_wallet()
    else:
        from pycardano import Address
        pkh = str(Address.from_primitive(addr).payment_part)
    txs = bf_get(f"/addresses/{addr}/transactions?order=desc&count={min(lookback_txs, 100)}", allow_404=True) or []
    orders = []
    total_open = 0
    total_expired = 0
    for t in txs:
        h = t["tx_hash"]
        utx = bf_get(f"/txs/{h}/utxos")
        for o in utx.get("outputs", []):
            a = o["address"]
            if not (a.startswith("addr1w") or a.startswith("addr1z") or a.startswith("addr1x") or a.startswith("addr17")):
                continue
            if not o.get("data_hash"):
                continue
            try:
                d = describe_order_output(h, o["output_index"], o, pkh)
            except Exception as e:
                orders.append({"utxo": f"{h}#{o['output_index']}", "status": "ERROR", "error": str(e)})
                continue
            if not d["owned_by_us"]:
                continue
            st = d.get("status", "")
            if st == "OPEN":
                total_open += 1
            elif st == "EXPIRED":
                total_expired += 1

            if status_lower == "open" and st not in ("OPEN", "EXPIRED"):
                continue
            if status_lower == "closed" and st not in ("FILLED", "CANCELLED", "CONSUMED"):
                continue
            orders.append(compact_order(d) if compact else d)
    return {"status": "ok", "wallet": addr, "scanned_txs": len(txs), "orders": orders,
            "open": total_open,
            "expired": total_expired}


# ---------------------------------------------------------------------------
# Reclaim
# ---------------------------------------------------------------------------

class _GenericRedeemer:
    """Factory for zero-field constructor redeemers."""

    @staticmethod
    def make(constr: int):
        from pycardano import PlutusData
        cls = type(f"Constr{constr}", (PlutusData,), {"CONSTR_ID": constr})
        return cls()


def _fetch_script(script_hash: str):
    from pycardano import PlutusV1Script, PlutusV2Script, PlutusV3Script, plutus_script_hash
    if script_hash in LOCAL_SCRIPTS:
        t, hx = LOCAL_SCRIPTS[script_hash]
        cls = {"plutusv1": PlutusV1Script, "plutusv3": PlutusV3Script}.get(t, PlutusV2Script)
        s = cls(bytes.fromhex(hx))
        if str(plutus_script_hash(s)) != script_hash:
            raise ValueError("local script CBOR does not match its hash")
        return s, t
    info = bf_get(f"/scripts/{script_hash}")
    cbor = bytes.fromhex(bf_get(f"/scripts/{script_hash}/cbor")["cbor"])
    t = (info.get("type") or "").lower()
    if t == "plutusv1":
        return PlutusV1Script(cbor), t
    if t == "plutusv3":
        return PlutusV3Script(cbor), t
    return PlutusV2Script(cbor), t


def canonical_cost_models(ctx) -> Any:
    """Make PyCardano's script-integrity hash match the ledger.

    PyCardano encodes the PlutusV1 language view with keys sorted alphabetically and V2/V3
    in dict order. Since protocol v11 the mainnet V1 model (332 params) is no longer in
    alphabetical order, so the node rejects the tx with ScriptIntegrityHashMismatch even
    though Plutus evaluation passes. Blockfrost's `cost_models_raw` is in canonical ledger
    order; re-key every model by zero-padded index so both sort and insertion order are correct.
    """
    import dataclasses
    pp = ctx.protocol_param  # populates the BlockFrost context cache
    raw = (bf_get("/epochs/latest/parameters") or {}).get("cost_models_raw") or {}
    if raw:
        models = {lang: {f"{i:04d}": int(v) for i, v in enumerate(vals)} for lang, vals in raw.items()}
        ctx._protocol_param = dataclasses.replace(pp, cost_models=models)
    return ctx


def build_reclaim(utxo_ref: str, wallet_id: Optional[str] = None, passphrase: Optional[str] = None,
                  require_owner: bool = True) -> Dict[str, Any]:
    """Builds and signs (but does not submit) a reclaim tx. Each candidate redeemer must pass Plutus
    evaluation; the first that does is used. Returns the signed tx object under '_tx'."""
    from pycardano import (Address, BlockFrostChainContext, Network, Redeemer, TransactionBuilder)
    tx_hash, idx = utxo_ref.split("#")
    idx = int(idx)
    addr_str, skey = _load_signer(wallet_id, passphrase)
    wallet_addr = Address.from_primitive(addr_str)
    our_pkh = str(wallet_addr.payment_part)
    desc = describe_order_output(tx_hash, idx, our_pkh=our_pkh)
    if desc["status"] not in ("OPEN", "EXPIRED"):
        return {"status": "error", "message": f"order is {desc['status']}; nothing to reclaim", "order": desc}
    if require_owner and desc["datum"].get("owner_pkh") not in (None, our_pkh):
        return {"status": "error", "message": "datum owner is not this wallet; refusing to build", "order": desc}
    if require_owner and not desc["owned_by_us"]:
        return {"status": "error", "message": "our key does not appear in the order datum; refusing", "order": desc}

    base, _ = _bf()
    ctx = BlockFrostChainContext(project_id=_bf()[1]["project_id"], base_url=base.rsplit("/v0", 1)[0],
                                 network=Network.MAINNET)
    canonical_cost_models(ctx)
    script_addr = Address.from_primitive(desc["script_address"])
    target = next((u for u in ctx.utxos(script_addr)
                   if str(u.input.transaction_id) == tx_hash and u.input.index == idx), None)
    if target is None:
        return {"status": "error", "message": "order UTxO not found at script address (already spent?)", "order": desc}
    script, stype = _fetch_script(desc["script_hash"])
    proto = PROTOCOLS.get(desc["script_hash"])
    candidates = proto["cancel_redeemers"] if proto else [0, 1, 2]

    # Hash-referenced datums must be supplied in the witness set (inline datums need not be).
    from pycardano import RawPlutusData, datum_hash as _datum_hash
    witness_datum = None
    dh = target.output.datum_hash
    if dh is not None and target.output.datum is None:
        dcbor = bytes.fromhex(bf_get(f"/scripts/datum/{dh}/cbor")["cbor"])
        witness_datum = RawPlutusData.from_cbor(dcbor)
        if str(_datum_hash(witness_datum)) != str(dh):
            return {"status": "error", "message": f"datum from chain does not hash to {dh}; refusing", "order": desc}
    attempts = []
    for constr in candidates:
        try:
            b = TransactionBuilder(ctx)
            b.add_input_address(wallet_addr)
            b.add_script_input(target, script=script, datum=witness_datum,
                               redeemer=Redeemer(_GenericRedeemer.make(constr)))
            b.required_signers = [wallet_addr.payment_part]
            tx = b.build_and_sign(signing_keys=[skey], change_address=wallet_addr)
            if dh is not None and target.output.datum is None:
                wd = tx.transaction_witness_set.plutus_data or []
                if not any(str(_datum_hash(d)) == str(dh) for d in wd):
                    raise ValueError(f"witness set lacks datum {dh}")
            ev = bf_evaluate(tx.to_cbor() if isinstance(tx.to_cbor(), bytes) else bytes.fromhex(tx.to_cbor()))
            ok = "EvaluationResult" in json.dumps(ev) and "EvaluationFailure" not in json.dumps(ev)
            attempts.append({"redeemer_constr": constr, "evaluation_ok": ok, "evaluation": ev.get("result", ev)})
            if ok:
                return {
                    "status": "ok", "order": desc, "redeemer_constr": constr, "script_type": stype,
                    "attempts": attempts, "tx_id": str(tx.id),
                    "fee_ada": tx.transaction_body.fee / 1e6,
                    "expected_return": desc["locked_value"],
                    "_tx": tx, "_ctx": ctx, "_wallet": addr_str,
                }
        except Exception as e:
            attempts.append({"redeemer_constr": constr, "evaluation_ok": False, "error": str(e)[:400]})
    return {"status": "error", "message": "no candidate redeemer passed Plutus evaluation", "attempts": attempts,
            "order": desc}


def emit_event(event_type: str, payload: Dict[str, Any]) -> None:
    try:
        from lib.tools.cardano_order_watcher import emit_event_to_bus
        emit_event_to_bus(event_type, payload, source="cardano_orders")
        return
    except Exception:
        pass
    env = {"event_id": f"evt_{int(time.time())}_{os.urandom(3).hex()}", "type": event_type,
           "event_type": event_type, "source": "cardano_orders", "timestamp": int(time.time()), "payload": payload}
    if EVENT_BUS_FIFO.exists():
        try:
            fd = os.open(str(EVENT_BUS_FIFO), os.O_WRONLY | os.O_NONBLOCK)
            with os.fdopen(fd, "w") as f:
                f.write(json.dumps(env) + "\n")
        except OSError:
            pass


def settlement_to(spend_tx: str, addr: str) -> Dict[str, int]:
    """Sum of value paid to `addr` by `spend_tx` (what a batcher actually delivered)."""
    utx = bf_get(f"/txs/{spend_tx}/utxos")
    tot: Dict[str, int] = {}
    for o in utx.get("outputs", []):
        if o["address"] == addr:
            for a in o.get("amount", []):
                tot[a["unit"]] = tot.get(a["unit"], 0) + int(a["quantity"])
    return tot


def tx_fee_ada(tx_hash: str) -> float:
    t = bf_get(f"/txs/{tx_hash}", allow_404=True)
    return int(t.get("fees", 0)) / 1e6 if t else 0.0


def asset_unit(symbol: str) -> str:
    from lib.tools.quant.market_data import resolve_unit
    return resolve_unit(symbol)


def asset_decimals(symbol: str) -> int:
    from lib.tools.quant.market_data import KNOWN_ASSETS
    return int(KNOWN_ASSETS.get(symbol.upper(), {}).get("decimals", 6))


def verify_reclaim(utxo_ref: str, reclaim_tx: str, wallet_addr: str, balance_before: Dict[str, int],
                   timeout_s: int = 240, poll_s: int = 10) -> Dict[str, Any]:
    """Polls until the reclaim tx is on-chain, the order UTxO is consumed by it, and reports the
    wallet balance delta per asset."""
    tx_hash, idx = utxo_ref.split("#")
    deadline = time.time() + timeout_s
    confirmed = None
    while time.time() < deadline:
        confirmed = bf_get(f"/txs/{reclaim_tx}", allow_404=True)
        if confirmed:
            break
        time.sleep(poll_s)
    if not confirmed:
        return {"verified": False, "state": "PENDING", "message": f"not on-chain after {timeout_s}s"}
    # Indexers lag the tx by a few seconds: re-poll until the spend and the balance change are visible.
    consumed_ok, delta = False, {}
    for _ in range(12):
        utx = bf_get(f"/txs/{tx_hash}/utxos")
        out = next(o for o in utx["outputs"] if o["output_index"] == int(idx))
        consumed_ok = out.get("consumed_by_tx") == reclaim_tx
        after = wallet_balance(wallet_addr)
        delta = {u: after.get(u, 0) - balance_before.get(u, 0) for u in set(after) | set(balance_before)}
        delta = {u: q for u, q in delta.items() if q}
        if consumed_ok and delta:
            break
        time.sleep(poll_s)
    return {"verified": bool(consumed_ok), "state": "CONFIRMED", "block_height": confirmed.get("block_height"),
            "order_utxo_consumed_by_reclaim": consumed_ok, "wallet_delta": delta}


def reclaim_order(utxo_ref: str, execute: bool = False, wallet_id: Optional[str] = None,
                  passphrase: Optional[str] = None, wait: bool = True, actor: str = "operator") -> Dict[str, Any]:
    built = build_reclaim(utxo_ref, wallet_id, passphrase)
    if built.get("status") != "ok":
        return built
    tx, ctx, wallet = built.pop("_tx"), built.pop("_ctx"), built.pop("_wallet")
    built["dry_run"] = not execute
    built["cardanoscan_url"] = f"https://cardanoscan.io/transaction/{built['tx_id']}"
    if not execute:
        return built
    from lib.tools.wallet import policy
    pol = policy.check(actor, "reclaim", 0.0, wallet_id=wallet_id or "agent-hot")
    if not pol["allowed"]:
        _audit("reclaim_denied", {"utxo": utxo_ref, "actor": actor, "reason": pol["reason"]})
        return {"status": "denied", "message": pol["reason"], "preview": _strip(built)}
    before = wallet_balance(wallet)
    ctx.submit_tx(tx)
    built["submitted_at"] = int(time.time())
    _audit("reclaim_submitted", {"utxo": utxo_ref, "tx_id": built["tx_id"], "actor": actor})
    _update_db_after_reclaim(utxo_ref, built["tx_id"])
    emit_event("cardano/order_reclaim_submitted", {"utxo": utxo_ref, "tx_id": built["tx_id"]})
    if wait:
        v = verify_reclaim(utxo_ref, built["tx_id"], wallet, before)
        built["verification"] = v
        if v.get("verified"):
            emit_event("cardano/order_cancelled", {"utxo": utxo_ref, "cancel_tx_id": built["tx_id"],
                                                   "wallet_delta": v.get("wallet_delta"), "verified": True})
            _audit("reclaim_verified", {"utxo": utxo_ref, "tx_id": built["tx_id"], "delta": v.get("wallet_delta")})
    return built


def _update_db_after_reclaim(utxo_ref: str, reclaim_tx: str) -> None:
    try:
        from lib.tools.cardano_maker_db import get_db_connection, cancel_linked_stop_triggers
        tx_hash = utxo_ref.split("#")[0]
        now = int(time.time())
        with get_db_connection() as conn:
            row = conn.execute("SELECT id, order_id, status, direction FROM maker_orders WHERE tx_id = ? OR sell_tx_id = ?",
                               (tx_hash, tx_hash)).fetchone()
            if row:
                new_status = "INVENTORY_HOLD" if (row["status"] == "PENDING_SELL" or row["direction"] == "SELL") else "CANCELLED"
                conn.execute(
                    "UPDATE maker_orders SET status = ?, updated_at = ?, metadata_json = json_set(COALESCE(metadata_json,'{}'),"
                    " '$.cancel_tx_id', ?, '$.cancelled_at', ?) WHERE id = ?",
                    (new_status, now, reclaim_tx, now, row["id"]))
                conn.commit()
                if row["order_id"]:
                    cancel_linked_stop_triggers(row["order_id"], reason="order_reclaimed_onchain")
        cancel_linked_stop_triggers(tx_hash, reason="order_reclaimed_onchain")
    except Exception:
        pass


def _audit(kind: str, payload: Dict[str, Any]) -> None:
    p = GEORGE_DIR / "finance" / "wallet_audit.jsonl"
    p.parent.mkdir(parents=True, exist_ok=True)
    with open(p, "a") as f:
        f.write(json.dumps({"ts": int(time.time()), "kind": kind, **payload}) + "\n")


def sync_db_protocols() -> Dict[str, Any]:
    """Corrects protocol labels and expiry state in maker_orders.db from chain truth."""
    from lib.tools.cardano_maker_db import get_db_connection
    fixed = []
    with get_db_connection() as conn:
        rows = conn.execute("SELECT id, order_id, tx_id, sell_tx_id, status, metadata_json FROM maker_orders "
                            "WHERE status IN ('PENDING_BUY','PENDING_SELL')").fetchall()
        for r in rows:
            ref = (r["sell_tx_id"] if r["status"] == "PENDING_SELL" else r["tx_id"]) or r["tx_id"]
            if not ref:
                continue
            try:
                utx = bf_get(f"/txs/{ref}/utxos")
                out = next((o for o in utx["outputs"] if o.get("data_hash")), None)
                if not out:
                    continue
                d = describe_order_output(ref, out["output_index"], out)
            except Exception as e:
                fixed.append({"order_id": r["order_id"], "error": str(e)})
                continue
            meta = json.loads(r["metadata_json"] or "{}")
            meta.update({"protocol": d["protocol"], "onchain_status": d["status"], "deadline_iso": d["deadline_iso"],
                         "order_utxo": d["utxo"], "min_receive": d["datum"].get("min_receive")})
            conn.execute("UPDATE maker_orders SET metadata_json = ?, updated_at = ? WHERE id = ?",
                         (json.dumps(meta), int(time.time()), r["id"]))
            fixed.append({"order_id": r["order_id"], "protocol": d["protocol"], "onchain_status": d["status"]})
        conn.commit()
    return {"status": "ok", "updated": fixed}


def _strip(o: Any) -> Any:
    if isinstance(o, dict):
        return {k: _strip(v) for k, v in o.items() if not k.startswith("_")}
    if isinstance(o, list):
        return [_strip(v) for v in o]
    return o


def main() -> None:
    import argparse
    ap = argparse.ArgumentParser(description="Cardano DEX order lifecycle (discover / inspect / reclaim)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("discover"); d.add_argument("--lookback", type=int, default=40)
    d.add_argument("--status", choices=["open", "all", "closed"], default="open")
    d.add_argument("--open-only", action="store_true")
    d.add_argument("--full", action="store_true", help="output full uncompacted datum internals")
    i = sub.add_parser("inspect"); i.add_argument("utxo")
    r = sub.add_parser("reclaim"); r.add_argument("utxo")
    r.add_argument("--execute", action="store_true", help="broadcast to mainnet (default: dry run)")
    r.add_argument("--no-wait", action="store_true")
    r.add_argument("--wallet-id", default=None)
    r.add_argument("--actor", default="operator")
    sub.add_parser("sync-db")
    a = ap.parse_args()
    try:
        if a.cmd == "discover":
            st = "open" if a.open_only else a.status
            res = discover_orders(lookback_txs=a.lookback, status=st, compact=not a.full)
        elif a.cmd == "inspect":
            h, ix = a.utxo.split("#")
            res = describe_order_output(h, int(ix))
        elif a.cmd == "reclaim":
            pw = os.environ.pop("LODGE_WALLET_PASSPHRASE", None)
            res = reclaim_order(a.utxo, execute=a.execute, wallet_id=a.wallet_id, passphrase=pw,
                                wait=not a.no_wait, actor=a.actor)
        else:
            res = sync_db_protocols()
    except Exception as e:
        res = {"status": "error", "message": f"{type(e).__name__}: {e}"}
    print(json.dumps(_strip(res), indent=2, default=str))


if __name__ == "__main__":
    main()
