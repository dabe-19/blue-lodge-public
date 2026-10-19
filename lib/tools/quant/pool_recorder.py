#!/usr/bin/env python3
"""
Pool-state recorder: exact on-chain reserves and per-order swap flow for Minswap V2 ADA pools.

Why: GeckoTerminal bars are coarse (and estimate reserves from USD), so everything downstream
(fair value, shock detection, markouts, fill odds) was built on approximations. The pool UTxO's
inline datum holds the exact reserves and the pool's real fee tier, and every batch transaction
that spends it lists the individual orders it filled.

How (Blockfrost-shaped API, 1 call per pool per tick when nothing happened):
  1. GET /assets/{lp_unit}/transactions?order=desc   - the pool UTxO always holds the LP-token
     remainder, so every spend of the pool moves the LP asset.
  2. For each new tx: GET /txs/{hash}/utxos            - pool input/output datums give pre/post
     reserves; order inputs (Minswap V2 order script) give per-order side, size, owner and, for
     buys, the batcher fee actually charged (open item O2).

Minswap V2 pool datum (verified on mainnet, fixture lib/tools/fixtures/minswap_v2_pool_batches_snek.json):
  Constr0[stake_cred, assetA, assetB, total_liquidity, reserve_a, reserve_b,
          base_fee_a_num, base_fee_b_num (denominator 10_000), fee_sharing_opt, allow_dynamic_fee]

Providers (config `recorder.providers`, default ["dolos", "blockfrost", "koios"]):
  dolos      local Blockfrost-compatible mini-API ($DOLOS_MINIBF_URL), unbudgeted, used when healthy
  blockfrost free tier, budget `recorder.budgets.blockfrost` (25k/day)
  koios      overflow, budget `recorder.budgets.koios` (10k/day)
Over-budget providers degrade cadence 60s -> 5m and then hand over to the next provider.

Everything here is read-only. CLI:
  pool_recorder.py tick [--assets SNEK,NIGHT]     one recorder pass (cron, every 60s)
  pool_recorder.py backfill [--max-calls N]       ~30-day history, chunked within budget
  pool_recorder.py status                         budget + freshness per pool
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if __name__ == "__main__" and _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)

from lib.tools.quant import market_db as mdb  # noqa: E402
from lib.tools.quant import tokens  # noqa: E402

LP_POLICY = "f5808c2c990d86da54bfc97d89cee6efa20cd8461616359478d96b4c"
POOL_NFT = LP_POLICY + "4d5350"  # "MSP": one per Minswap V2 pool UTxO
ORDER_SCRIPT_HASH = "c3e28c36c3447315ba5a56f33da6a6ddc1770a876a8d9f0cb3a97c4c"
FEE_DENOM = 10_000
ORDER_DEPOSIT_LOVELACE = 2_000_000

DEFAULT_CONFIG: Dict[str, Any] = {
    "pools": ["NIGHT", "SNEK", "MIN", "USDM", "DJED", "USDCX", "IAG", "HOSKY", "WMTX"],
    "slow_pools": ["IAG", "HOSKY", "WMTX"],
    "interval_s": 60,
    "slow_interval_s": 300,
    "providers": ["dolos", "blockfrost", "koios"],
    "budgets": {"blockfrost": 25000, "koios": 10000, "dolos": 10 ** 9},
    "max_txs_per_pool_tick": 15,
    "backfill_days": 30,
    "backfill_daily_budget": 6000,
    "backfill_calls_per_run": 120,
}


def load_config() -> Dict[str, Any]:
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    try:
        from lib.tools.trading import policy as pol
        user = pol.load_policy().get("recorder") or {}
    except Exception:
        user = {}
    for k, v in user.items():
        if isinstance(v, dict) and isinstance(cfg.get(k), dict):
            cfg[k].update(v)
        else:
            cfg[k] = v
    return cfg


# ---------------------------------------------------------------------------
# Bech32 address -> payment credential (no pycardano import on the hot path)
# ---------------------------------------------------------------------------

_B32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def address_payment_cred(addr: str) -> Optional[str]:
    """Hex payment credential (key or script hash) of a Shelley bech32 address."""
    try:
        hrp, data = addr.rsplit("1", 1)
        vals = [_B32.index(c) for c in data.lower()][:-6]
        acc, bits, out = 0, 0, bytearray()
        for v in vals:
            acc = (acc << 5) | v
            bits += 5
            while bits >= 8:
                bits -= 8
                out.append((acc >> bits) & 0xFF)
        header = out[0] >> 4
        if header > 7:  # byron / reward addresses carry no payment credential
            return None
        return out[1:29].hex()
    except (ValueError, IndexError):
        return None


def address_stake_cred(addr: str) -> Optional[str]:
    try:
        hrp, data = addr.rsplit("1", 1)
        vals = [_B32.index(c) for c in data.lower()][:-6]
        acc, bits, out = 0, 0, bytearray()
        for v in vals:
            acc = (acc << 5) | v
            bits += 5
            while bits >= 8:
                bits -= 8
                out.append((acc >> bits) & 0xFF)
        header = out[0] >> 4
        return out[29:57].hex() if header <= 3 and len(out) >= 57 else None
    except (ValueError, IndexError):
        return None


# ---------------------------------------------------------------------------
# Plutus data (CBOR) decoding
# ---------------------------------------------------------------------------

def plutus_from_cbor(cbor_hex: str) -> Any:
    import cbor2
    return _norm(cbor2.loads(bytes.fromhex(cbor_hex)))


def _norm(o: Any) -> Any:
    import cbor2
    if isinstance(o, cbor2.CBORTag):
        t = o.tag
        if 121 <= t <= 127:
            return {"c": t - 121, "f": [_norm(x) for x in o.value]}
        if 1280 <= t <= 1400:
            return {"c": t - 1280 + 7, "f": [_norm(x) for x in o.value]}
        if t == 102:
            return {"c": int(o.value[0]), "f": [_norm(x) for x in o.value[1]]}
        if t in (2, 3):  # bignum
            n = int.from_bytes(o.value, "big")
            return n if t == 2 else -1 - n
        return o.value
    if isinstance(o, (list, tuple)):
        return [_norm(x) for x in o]
    if isinstance(o, dict):
        return {(k.hex() if isinstance(k, bytes) else str(_norm(k))): _norm(v) for k, v in o.items()}
    return o


def _asset_of(node: Dict[str, Any]) -> Tuple[str, str]:
    return node["f"][0].hex(), node["f"][1].hex()


def decode_pool_datum(cbor_hex: str) -> Optional[Dict[str, Any]]:
    try:
        d = plutus_from_cbor(cbor_hex)
        f = d["f"]
        if d["c"] != 0 or len(f) < 8:
            return None
        a, b = _asset_of(f[1]), _asset_of(f[2])
        return {"asset_a": a[0] + a[1], "asset_b": b[0] + b[1], "total_liquidity": int(f[3]),
                "reserve_a": int(f[4]), "reserve_b": int(f[5]),
                "fee_a_bps": int(f[6]) * 10_000 / FEE_DENOM, "fee_b_bps": int(f[7]) * 10_000 / FEE_DENOM}
    except Exception:
        return None


def _addr_pkh(node: Dict[str, Any]) -> Tuple[Optional[str], Optional[str]]:
    """Plutus Address -> (payment key hash or None for scripts, stake key hash or None)."""
    try:
        pay = node["f"][0]
        pkh = pay["f"][0].hex() if pay["c"] == 0 else None
        stake = None
        st = node["f"][1]
        if st["c"] == 0:  # Some(StakingHash(PubKeyCredential(h)))
            inner = st["f"][0]
            if inner["c"] == 0 and inner["f"][0]["c"] == 0:
                stake = inner["f"][0]["f"][0].hex()
        return pkh, stake
    except Exception:
        return None, None


def decode_order_datum(cbor_hex: str) -> Optional[Dict[str, Any]]:
    try:
        d = plutus_from_cbor(cbor_hex)
        f = d["f"]
        if d["c"] != 0 or len(f) < 8:
            return None
        canceller = f[0]["f"][0].hex() if f[0]["c"] == 0 and f[0]["f"] else None
        rpkh, rstake = _addr_pkh(f[3])
        lp = _asset_of(f[5])
        step = f[6]
        out = {"canceller": canceller, "receiver_pkh": rpkh, "receiver_stake": rstake,
               "lp_policy": lp[0], "lp_name": lp[1], "step": step["c"], "max_batcher_fee": int(f[7]),
               "a_to_b": None, "amount_in": None, "min_receive": None}
        if step["c"] == 0:  # SwapExactIn
            sf = step["f"]
            out["a_to_b"] = sf[0]["c"] == 1
            amt = sf[1]
            out["amount_in"] = int(amt["f"][0]) if amt["c"] == 0 else None  # SpecificAmount vs All
            out["min_receive"] = int(sf[2])
        return out
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Batch transaction decomposition
# ---------------------------------------------------------------------------

def _qty(utxo: Dict[str, Any], unit: str) -> int:
    for a in utxo.get("amount", []):
        if a.get("unit") == unit:
            return int(a["quantity"])
    return 0


def _is_pool_utxo(u: Dict[str, Any], unit: str) -> Optional[Dict[str, Any]]:
    if not u.get("inline_datum") or _qty(u, POOL_NFT) != 1:
        return None
    d = decode_pool_datum(u["inline_datum"])
    if d and d["asset_a"] == "" and d["asset_b"] == unit:
        return d
    return None


def parse_batch(tx_utxos: Dict[str, Any], asset: str, lp_name: str, unit: str, decimals: int,
                ts: int) -> Optional[Dict[str, Any]]:
    """Returns {pre, post, rows} for one tx that spent the pool, or None if the pool is not an output."""
    tx = tx_utxos.get("hash") or ""
    real_inputs = [u for u in tx_utxos.get("inputs", []) if not u.get("reference") and not u.get("collateral")]
    outputs = [u for u in tx_utxos.get("outputs", []) if not u.get("collateral")]
    pre = next((d for d in (_is_pool_utxo(u, unit) for u in real_inputs) if d), None)
    post = next((d for d in (_is_pool_utxo(u, unit) for u in outputs) if d), None)
    if post is None:
        return None
    tok_scale = 10 ** decimals

    def spot(d: Dict[str, Any]) -> float:
        return (d["reserve_a"] / 1e6) / (d["reserve_b"] / tok_scale)

    rows: List[Dict[str, Any]] = []
    post_spot = spot(post)
    pre_spot = spot(pre) if pre else None
    base = {"tx": tx, "ts": int(ts), "pool": LP_POLICY + lp_name, "asset": asset}
    if pre:
        d_ada = (post["reserve_a"] - pre["reserve_a"]) / 1e6
        d_tok = (post["reserve_b"] - pre["reserve_b"]) / tok_scale
        if d_ada > 0 > d_tok:
            kind, side = "batch", "buy"
        elif d_ada < 0 < d_tok:
            kind, side = "batch", "sell"
        else:
            kind, side = "liquidity", None
        eff = abs(d_ada / d_tok) if kind == "batch" and d_tok else None
    else:
        d_ada = d_tok = 0.0
        kind, side, eff = "pool_created", None, None

    orders: List[Dict[str, Any]] = []
    used_out: set = set()
    for u in real_inputs:
        if address_payment_cred(u.get("address", "")) != ORDER_SCRIPT_HASH or not u.get("inline_datum"):
            continue
        od = decode_order_datum(u["inline_datum"])
        if not od or od["lp_name"] != lp_name:
            continue
        lov_in = _qty(u, "lovelace")
        tok_in = _qty(u, unit)
        side_o = ("buy" if od["a_to_b"] else "sell") if od["a_to_b"] is not None else ("sell" if tok_in else "buy")
        recv = None
        if od["receiver_pkh"]:
            for i, o in enumerate(outputs):
                if i in used_out:
                    continue
                if address_payment_cred(o.get("address", "")) == od["receiver_pkh"]:
                    recv = o
                    used_out.add(i)
                    break
        r_lov = _qty(recv, "lovelace") if recv else None
        r_tok = _qty(recv, unit) if recv else None
        fee = None
        ada_amt = tok_amt = None
        if side_o == "buy":
            amt_in = od["amount_in"] if od["amount_in"] is not None else max(0, lov_in - ORDER_DEPOSIT_LOVELACE - od["max_batcher_fee"])
            ada_amt = amt_in / 1e6
            if recv is not None and od["step"] == 0:
                fee = (lov_in - amt_in - r_lov) / 1e6
                tok_amt = r_tok / tok_scale if r_tok else None
        else:
            tok_amt = (od["amount_in"] if od["amount_in"] is not None else tok_in) / tok_scale
        orders.append({"od": od, "side": side_o, "ada_amt": ada_amt, "tok_amt": tok_amt, "fee": fee,
                       "lov_in": lov_in, "r_lov": r_lov, "owner": ("stake:" + od["receiver_stake"]) if od["receiver_stake"]
                       else ("pkh:" + od["canceller"]) if od["canceller"] else None})
    # Sells: ADA received = receiver lovelace - (input lovelace - fee). The fee is taken from buys in the
    # same batch when available (measured), else max_batcher_fee (upper bound, flagged by fee=None).
    measured = [o["fee"] for o in orders if o["fee"] is not None and 0 <= o["fee"] <= 10]
    fee_ref = sorted(measured)[len(measured) // 2] if measured else None
    for o in orders:
        if o["side"] == "sell" and o["r_lov"] is not None:
            f_used = fee_ref if fee_ref is not None else o["od"]["max_batcher_fee"] / 1e6
            o["ada_amt"] = max(0.0, (o["r_lov"] - o["lov_in"]) / 1e6 + f_used)

    rows.append({**base, "idx": 0, "kind": kind, "side": side, "ada_amt": abs(d_ada) if pre else None,
                 "tok_amt": abs(d_tok) if pre else None, "eff_price": eff, "pre_spot": pre_spot,
                 "post_spot": post_spot,
                 "impact_pct": ((post_spot / pre_spot - 1) * 100) if pre_spot else None,
                 "owner": None, "batcher_fee_ada": fee_ref, "n_orders": len(orders)})
    for i, o in enumerate(orders, start=1):
        eff_o = (o["ada_amt"] / o["tok_amt"]) if o["ada_amt"] and o["tok_amt"] else None
        rows.append({**base, "idx": i, "kind": "order" if o["od"]["step"] == 0 else "order_other", "side": o["side"],
                     "ada_amt": o["ada_amt"], "tok_amt": o["tok_amt"], "eff_price": eff_o,
                     "pre_spot": pre_spot, "post_spot": post_spot, "impact_pct": None, "owner": o["owner"],
                     "batcher_fee_ada": o["fee"], "n_orders": None})
    return {"tx": tx, "pre": pre, "post": post, "post_spot": post_spot, "pre_spot": pre_spot,
            "fee_bps": post["fee_a_bps"], "rows": rows,
            "reserve_ada": post["reserve_a"] / 1e6, "reserve_tok": post["reserve_b"] / tok_scale}


# ---------------------------------------------------------------------------
# Chain sources (budgeted)
# ---------------------------------------------------------------------------

class SourceUnavailable(RuntimeError):
    pass


class BudgetExceeded(RuntimeError):
    pass


class _Source:
    name = "base"

    def __init__(self, con, purpose: str = "live"):
        self.con = con
        self.purpose = purpose

    def _log(self, endpoint: str, ok: bool) -> None:
        mdb.log_api_call(self.con, self.name, endpoint, ok, self.purpose)


class BlockfrostSource(_Source):
    name = "blockfrost"

    def __init__(self, con, purpose: str = "live", base: Optional[str] = None,
                 headers: Optional[Dict[str, str]] = None):
        super().__init__(con, purpose)
        if base is None:
            from lib.tools.cardano_dex_swapper import load_env_vars
            env = load_env_vars()
            pid = env.get("BLOCKFROST_PROJECT_ID", "")
            if not pid:
                raise SourceUnavailable("BLOCKFROST_PROJECT_ID missing")
            base = env.get("BLOCKFROST_BASE_URL", "https://cardano-mainnet.blockfrost.io/api").rstrip("/")
            if not base.endswith("/v0"):
                base += "/v0"
            headers = {"project_id": pid}
        self.base = base.rstrip("/")
        self.headers = {"User-Agent": "BlueLodge-PoolRecorder/1.0", **(headers or {})}

    def _get(self, path: str) -> Any:
        req = urllib.request.Request(self.base + path, headers=self.headers)
        ep = path.split("?")[0]
        ep = "/".join("{h}" if len(p) >= 56 else p for p in ep.split("/"))
        try:
            with urllib.request.urlopen(req, timeout=25) as r:
                data = json.loads(r.read().decode())
            self._log(ep, True)
            return data
        except urllib.error.HTTPError as e:
            self._log(ep, False)
            if e.code == 404:
                return None
            if e.code in (402, 429):
                raise BudgetExceeded(f"{self.name} HTTP {e.code}")
            raise
        except Exception:
            self._log(ep, False)
            raise

    def asset_txs(self, lp_unit: str, count: int = 20, page: int = 1, order: str = "desc",
                  after_height: Optional[int] = None) -> List[Dict[str, Any]]:
        q = urllib.parse.urlencode({"count": min(100, count), "page": page, "order": order})
        return self._get(f"/assets/{lp_unit}/transactions?{q}") or []

    def tx_utxos(self, tx_hash: str) -> Optional[Dict[str, Any]]:
        return self._get(f"/txs/{tx_hash}/utxos")


class DolosSource(BlockfrostSource):
    name = "dolos"

    def __init__(self, con, purpose: str = "live"):
        url = os.getenv("DOLOS_MINIBF_URL", "http://127.0.0.1:8000/api/v0").rstrip("/")
        try:
            req = urllib.request.Request(f"{url}/epochs/latest", headers={"User-Agent": "BlueLodge-Dolos/1.0"})
            with urllib.request.urlopen(req, timeout=0.5) as resp:
                if resp.status != 200:
                    raise SourceUnavailable("dolos unhealthy")
        except SourceUnavailable:
            raise
        except Exception as e:
            raise SourceUnavailable(f"dolos not reachable at {url}: {type(e).__name__}")
        super().__init__(con, purpose, base=url, headers={})


class KoiosSource(_Source):
    """Koios v1, normalised to the Blockfrost shapes parse_batch() expects."""
    name = "koios"

    def __init__(self, con, purpose: str = "live", base: Optional[str] = None):
        super().__init__(con, purpose)
        self.base = (base or os.getenv("KOIOS_URL", "https://api.koios.rest/api/v1")).rstrip("/")
        self.headers = {"Accept": "application/json", "User-Agent": "BlueLodge-PoolRecorder/1.0"}
        tok = os.getenv("KOIOS_API_TOKEN")
        if not tok:
            try:
                from lib.tools.cardano_dex_swapper import load_env_vars
                tok = load_env_vars().get("KOIOS_API_TOKEN")
            except Exception:
                tok = None
        if tok:
            self.headers["Authorization"] = f"Bearer {tok}"

    def _req(self, path: str, payload: Optional[Dict[str, Any]] = None) -> Any:
        data = json.dumps(payload).encode() if payload is not None else None
        hdr = {**self.headers, **({"Content-Type": "application/json"} if data else {})}
        req = urllib.request.Request(self.base + path, data=data, headers=hdr)
        ep = path.split("?")[0]
        try:
            with urllib.request.urlopen(req, timeout=60) as r:  # asset_txs on LP tokens takes ~30s
                out = json.loads(r.read().decode())
            self._log(ep, True)
            return out
        except urllib.error.HTTPError as e:
            self._log(ep, False)
            if e.code in (402, 429):
                raise BudgetExceeded(f"koios HTTP {e.code}")
            raise
        except Exception:
            self._log(ep, False)
            raise

    def asset_txs(self, lp_unit: str, count: int = 20, page: int = 1, order: str = "desc",
                  after_height: Optional[int] = None) -> List[Dict[str, Any]]:
        # Unbounded LP-token history times out on Koios: always bound by block height (~2h on first contact).
        if not after_height:
            tip = self._req("/tip") or [{}]
            after_height = int(tip[0].get("block_no") or 0) - 360
        q = urllib.parse.urlencode({"_asset_policy": lp_unit[:56], "_asset_name": lp_unit[56:],
                                    "_after_block_height": int(after_height) - 1, "_history": "true",
                                    "order": f"block_height.{order}", "limit": count, "offset": (page - 1) * count})
        rows = self._req(f"/asset_txs?{q}") or []
        return [{"tx_hash": r["tx_hash"], "block_height": r.get("block_height"), "tx_index": 0,
                 "block_time": r.get("block_time")} for r in rows]

    @staticmethod
    def _utxo(u: Dict[str, Any]) -> Dict[str, Any]:
        amount = [{"unit": "lovelace", "quantity": str(u.get("value", "0"))}]
        for a in u.get("asset_list") or []:
            amount.append({"unit": a["policy_id"] + a.get("asset_name", ""), "quantity": str(a["quantity"])})
        idt = u.get("inline_datum")
        return {"address": (u.get("payment_addr") or {}).get("bech32", ""), "amount": amount,
                "inline_datum": idt.get("bytes") if isinstance(idt, dict) else None,
                "tx_hash": u.get("tx_hash"), "output_index": u.get("tx_index"),
                "reference": False, "collateral": False}

    def tx_utxos(self, tx_hash: str) -> Optional[Dict[str, Any]]:
        rows = self._req("/tx_info", {"_tx_hashes": [tx_hash], "_inputs": True, "_assets": True,
                                      "_scripts": True, "_metadata": False, "_withdrawals": False,
                                      "_certs": False, "_bytecode": True})  # inline datum bytes need _bytecode
        if not rows:
            return None
        t = rows[0]
        return {"hash": t["tx_hash"], "inputs": [self._utxo(u) for u in t.get("inputs") or []],
                "outputs": [self._utxo(u) for u in t.get("outputs") or []]}


_SOURCES = {"blockfrost": BlockfrostSource, "koios": KoiosSource, "dolos": DolosSource}


def pick_source(con, cfg: Dict[str, Any], purpose: str = "live",
                skip: Tuple[str, ...] = ()) -> Tuple[Optional[_Source], int, List[Dict[str, Any]]]:
    """First healthy provider with budget left. Returns (source, cadence multiplier, budget report)."""
    report = []
    for name in cfg.get("providers", []):
        if name in skip or name not in _SOURCES:
            continue
        limit = int(cfg.get("budgets", {}).get(name, 0) or 0)
        st = mdb.budget_status(con, name, limit) if name != "dolos" else {"provider": name, "cadence_multiplier": 1}
        report.append(st)
        if st["cadence_multiplier"] == 0:
            continue
        try:
            return _SOURCES[name](con, purpose), int(st["cadence_multiplier"]), report
        except SourceUnavailable as e:
            report[-1]["unavailable"] = str(e)
            continue
    return None, 0, report


# ---------------------------------------------------------------------------
# Pool registry
# ---------------------------------------------------------------------------

def _state(con, asset: str) -> Optional[Dict[str, Any]]:
    r = con.execute("SELECT * FROM recorder_state WHERE asset=? AND dex='MinswapV2'", (asset,)).fetchone()
    return dict(r) if r else None


def ensure_pool(con, asset: str) -> Dict[str, Any]:
    asset = tokens.canonical(asset) or asset.upper()
    st = _state(con, asset)
    if st and st.get("lp_unit"):
        return st
    from lib.tools.minswap_v2 import find_pool
    p = find_pool(asset)
    lp_unit = p["pool_address"]
    rec = tokens.get(asset)
    con.execute("INSERT OR REPLACE INTO recorder_state(pool, asset, dex, lp_unit, unit, decimals, info) "
                "VALUES (?,?,?,?,?,?,?)",
                (lp_unit, asset, "MinswapV2", lp_unit, rec["unit"], int(rec["decimals"]), json.dumps({"seen": []})))
    con.commit()
    return _state(con, asset)


def _info(st: Dict[str, Any]) -> Dict[str, Any]:
    try:
        return json.loads(st.get("info") or "{}")
    except ValueError:
        return {}


def _apply(con, st: Dict[str, Any], tx_meta: Dict[str, Any], utx: Dict[str, Any], src: str) -> Optional[Dict[str, Any]]:
    lp_name = st["lp_unit"][56:]
    ts = int(tx_meta.get("block_time") or time.time())
    if "hash" not in utx:
        utx = {**utx, "hash": tx_meta["tx_hash"]}
    res = parse_batch(utx, st["asset"], lp_name, st["unit"], int(st["decimals"]), ts)
    if res is None:
        mdb.record_swaps(con, [{"tx": tx_meta["tx_hash"], "idx": 0, "ts": ts, "pool": st["pool"], "asset": st["asset"],
                                "kind": "no_pool_output"}])
        return None
    mdb.record_snapshot(con, ts, st["pool"], st["asset"], res["reserve_ada"], res["reserve_tok"],
                        res["fee_bps"], tx_meta["tx_hash"], src)
    mdb.record_swaps(con, res["rows"])
    return res


def poll_pool(con, src: _Source, asset: str, cfg: Dict[str, Any], now: Optional[float] = None) -> Dict[str, Any]:
    st = ensure_pool(con, asset)
    now = int(now or time.time())
    max_tx = int(cfg.get("max_txs_per_pool_tick", 15))
    listing = src.asset_txs(st["lp_unit"], count=max_tx + 5, order="desc", after_height=st.get("last_height"))
    info = _info(st)
    seen = set(info.get("seen") or [])
    last_h = st.get("last_height") or 0
    if not st.get("last_tx"):
        new = listing[:1]  # first contact: current state only; history is the backfill job's work
    else:
        new = [t for t in listing if t["tx_hash"] not in seen and (t.get("block_height") or 0) >= last_h]
    gap = bool(st.get("last_tx")) and len(new) >= len(listing) and len(listing) > 0
    new.sort(key=lambda t: (t.get("block_height") or 0, t.get("tx_index") or 0))
    if len(new) > max_tx:
        new = new[-max_tx:]
    applied = 0
    last = None
    for t in new:
        utx = src.tx_utxos(t["tx_hash"])
        if utx is None:
            continue
        res = _apply(con, st, t, utx, src.name)
        seen.add(t["tx_hash"])
        last = t
        if res:
            applied += 1
    info["seen"] = list(seen)[-80:]
    if gap:
        info["gaps"] = int(info.get("gaps", 0)) + 1
    params: List[Any] = [now, json.dumps(info)]
    sql = "UPDATE recorder_state SET last_checked=?, info=?"
    if last:
        sql += ", last_tx=?, last_height=?, last_tx_index=?, last_ts=?"
        params += [last["tx_hash"], last.get("block_height"), last.get("tx_index"), last.get("block_time")]
    con.execute(sql + " WHERE pool=?", params + [st["pool"]])
    con.commit()
    return {"asset": st["asset"], "new_txs": len(new), "applied": applied, "gap": gap, "provider": src.name}


def tick(assets: Optional[List[str]] = None, now: Optional[float] = None, con=None) -> Dict[str, Any]:
    cfg = load_config()
    own = con is None
    con = con or mdb.connect()
    now = float(now or time.time())
    out: Dict[str, Any] = {"status": "ok", "ts": int(now), "pools": [], "errors": []}
    try:
        src, mult, report = pick_source(con, cfg)
        out["budget"] = report
        if src is None:
            out["status"] = "budget_exhausted"
            return out
        out["provider"], out["cadence_multiplier"] = src.name, mult
        slow = set(cfg.get("slow_pools") or [])
        for asset in assets or cfg["pools"]:
            try:
                st = ensure_pool(con, asset)
            except Exception as e:
                out["errors"].append({"asset": asset, "error": f"resolve: {type(e).__name__}: {e}"})
                continue
            base_iv = cfg["slow_interval_s"] if st["asset"] in slow else cfg["interval_s"]
            if not assets and st.get("last_checked") and now - st["last_checked"] < base_iv * mult - 5:
                continue
            try:
                out["pools"].append(poll_pool(con, src, st["asset"], cfg, now))
            except BudgetExceeded as e:
                out["errors"].append({"asset": st["asset"], "error": str(e)})
                nxt, mult2, _ = pick_source(con, cfg, skip=(src.name,))
                if nxt is None:
                    out["status"] = "budget_exhausted"
                    break
                src, mult = nxt, mult2
            except Exception as e:
                out["errors"].append({"asset": st["asset"], "error": f"{type(e).__name__}: {str(e)[:200]}"})
        return out
    finally:
        if own:
            con.close()


# ---------------------------------------------------------------------------
# Backfill (~30 days, chunked within budget)
# ---------------------------------------------------------------------------

def backfill(assets: Optional[List[str]] = None, max_calls: Optional[int] = None, now: Optional[float] = None,
             con=None) -> Dict[str, Any]:
    cfg = load_config()
    own = con is None
    con = con or mdb.connect()
    now = int(now or time.time())
    horizon = now - int(cfg["backfill_days"]) * 86400
    out: Dict[str, Any] = {"status": "ok", "pools": []}
    try:
        used_bf = sum(mdb.calls_today(con, p, purpose="backfill") for p in ("blockfrost", "koios"))
        allowance = max(0, int(cfg["backfill_daily_budget"]) - used_bf)
        calls_left = min(allowance, int(max_calls or cfg["backfill_calls_per_run"]))
        if calls_left <= 0:
            out["status"] = "backfill_budget_exhausted"
            return out
        src, mult, report = pick_source(con, cfg, purpose="backfill", skip=("koios",))
        if src is None or mult != 1:
            out["status"] = "deferred_live_budget_priority"
            out["budget"] = report
            return out
        candidates = []
        for asset in assets or cfg["pools"]:
            st = ensure_pool(con, asset)
            if not st.get("backfill_done"):
                candidates.append(st)
        # Prioritize pools with no backfill yet, then those with the shallowest history (largest oldest_ts)
        candidates.sort(key=lambda s: (0 if s.get("backfill_oldest_ts") is None else 1, -(s.get("backfill_oldest_ts") or now)))
        for idx, st in enumerate(candidates):
            if calls_left <= 0:
                break
            rem = max(1, len(candidates) - idx)
            pool_calls = calls_left if len(candidates) == 1 else max(15, calls_left // rem)
            pool_calls = min(calls_left, pool_calls)
            page = int(st.get("backfill_page") or 0) + 1
            done = applied = 0
            oldest = st.get("backfill_oldest_ts")
            while pool_calls > 0 and calls_left > 0 and not done:
                listing = src.asset_txs(st["lp_unit"], count=100, page=page, order="desc")
                calls_left -= 1
                pool_calls -= 1
                if not listing:
                    done = 1
                    break
                for t in listing:
                    if (t.get("block_time") or now) < horizon:
                        done = 1
                        break
                    if con.execute("SELECT 1 FROM swaps WHERE tx=? LIMIT 1", (t["tx_hash"],)).fetchone():
                        oldest = min(oldest or now, int(t.get("block_time") or now))
                        continue
                    if pool_calls <= 0 or calls_left <= 0:
                        break
                    utx = src.tx_utxos(t["tx_hash"])
                    calls_left -= 1
                    pool_calls -= 1
                    if utx is not None:
                        _apply(con, st, t, utx, f"backfill:{src.name}")
                        applied += 1
                    oldest = min(oldest or now, int(t.get("block_time") or now))
                else:
                    page += 1
                    con.execute("UPDATE recorder_state SET backfill_page=?, backfill_oldest_ts=? WHERE pool=?",
                                (page - 1, oldest, st["pool"]))
                    con.commit()
                    continue
                break
            con.execute("UPDATE recorder_state SET backfill_done=?, backfill_oldest_ts=? WHERE pool=?",
                        (done, oldest, st["pool"]))
            con.commit()
            out["pools"].append({"asset": st["asset"], "applied": applied, "done": bool(done), "page": page,
                                 "oldest_ts": oldest})
        out["calls_left"] = calls_left
        return out
    finally:
        if own:
            con.close()


def status(con=None) -> Dict[str, Any]:
    cfg = load_config()
    own = con is None
    con = con or mdb.connect()
    try:
        now = time.time()
        budgets = [mdb.budget_status(con, p, int(cfg["budgets"].get(p, 0))) for p in ("blockfrost", "koios")]
        pools = []
        for r in con.execute("SELECT * FROM recorder_state ORDER BY asset"):
            r = dict(r)
            snap = mdb.latest_snapshot(con, r["asset"])
            pools.append({"asset": r["asset"], "dex": r["dex"], "last_trade_ts": r.get("last_ts"),
                          "checked_age_s": int(now - r["last_checked"]) if r.get("last_checked") else None,
                          "spot": snap["spot"] if snap else None, "fee_bps": snap["fee_bps"] if snap else None,
                          "reserve_ada": snap["reserve_ada"] if snap else None,
                          "backfill_done": bool(r.get("backfill_done")), "backfill_oldest_ts": r.get("backfill_oldest_ts"),
                          "gaps": _info(r).get("gaps", 0)})
        return {"status": "ok", "budgets": budgets, "pools": pools, "db": {"size_bytes": mdb.size_bytes()}}
    finally:
        if own:
            con.close()


def main() -> None:
    import argparse
    ap = argparse.ArgumentParser(description="Minswap V2 pool-state recorder")
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("tick")
    t.add_argument("--assets", default=None)
    b = sub.add_parser("backfill")
    b.add_argument("--assets", default=None)
    b.add_argument("--max-calls", type=int, default=None)
    sub.add_parser("status")
    a = ap.parse_args()
    assets = [s.strip().upper() for s in a.assets.split(",")] if getattr(a, "assets", None) else None
    try:
        if a.cmd == "tick":
            res = tick(assets)
        elif a.cmd == "backfill":
            res = backfill(assets, a.max_calls)
        else:
            res = status()
    except Exception as e:
        res = {"status": "error", "message": f"{type(e).__name__}: {e}"}
    print(json.dumps(res, indent=2, default=str))


if __name__ == "__main__":
    main()
