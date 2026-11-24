#!/usr/bin/env python3
"""
Sovereign Loan Fund - treasury, fund ledger, yield board and opportunity engine.

Everything here is read from live sources or the local append-only ledger; nothing is
invented. When a source is unavailable the value is reported as null with a reason.

  * Prices: CoinGecko simple price (USD) for ADA/BTC/ETH/POL/USDC; Cardano native tokens are
    valued in ADA from their deepest on-chain pool (GeckoTerminal via quant.market_data).
  * Holdings: Blockfrost (Cardano hot wallet + tokens locked in our open DEX orders),
    Polygon/Ethereum JSON-RPC (POL, USDC, ETH), mempool.space for watch-only BTC addresses.
  * Fund ledger (.george/finance/loan_fund_ledger.jsonl): capital earmarked for microloans,
    disbursements, repayments, interest and write-offs. The fund is a sub-account of the
    treasury: `available` is what the underwriter may lend.
  * Yields: DeFiLlama pools API (real APY/TVL) for the target assets, used as the fund's
    opportunity cost of capital and as an informational yield board.
  * Opportunities: concrete, ranked actions (stale orders to reprice, stranded funds,
    allocation drift, loan servicing, idle stablecoins).

CLI:  sovereign_fund.py treasury|state|yields|opportunities|policy [--json]
      sovereign_fund.py ledger-add --type allocate --asset ADA --amount 20 --note "..."
"""
from __future__ import annotations

import argparse
import fcntl
import json
import math
import os
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if __name__ == "__main__" and _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)

LODGE_DIR = Path(os.environ.get("LODGE_DIR", _REPO_ROOT))
GEORGE_DIR = Path(os.environ.get("GEORGE_DIR", LODGE_DIR / ".george"))
FIN_DIR = GEORGE_DIR / "finance"
LEDGER_FILE = Path(os.environ.get("LODGE_FUND_LEDGER", FIN_DIR / "loan_fund_ledger.jsonl"))
POLICY_FILE = Path(os.environ.get("LODGE_FUND_POLICY", FIN_DIR / "fund_policy.json"))
CACHE_DIR = LODGE_DIR / "market_cache"
UA = "BlueLodge-SovereignFund/2.0"

COINGECKO_IDS = {"ADA": "cardano", "BTC": "bitcoin", "ETH": "ethereum", "POL": "polygon-ecosystem-token",
                 "USDC": "usd-coin"}
TARGET_ASSETS = ("ADA", "USDC", "POL", "ETH", "BTC")
LEDGER_TYPES = {
    "allocate": +1,        # treasury capital earmarked for the fund
    "deallocate": -1,      # earmark released back to the trading treasury
    "profit_sweep": +1,    # share of realised trading profit swept into the fund
    "loan_out": -1,        # principal disbursed to a borrower
    "repay_principal": +1,
    "interest": +1,
    "fee_income": +1,
    "liquidation_proceeds": +1,
    "writeoff": 0,         # informational: principal lost (loan_out already debited)
    "expense": -1,         # tx fees paid by the fund
}

DEFAULT_POLICY: Dict[str, Any] = {
    "targets_pct": {"ADA": 45, "USDC": 25, "BTC": 10, "ETH": 10, "POL": 10},
    "profit_sweep_pct": 50,           # of realised maker profit, swept into the fund
    "max_loan_pct_of_fund": 40,       # single-loan concentration cap
    "min_loan_ada": 5.0,
    "max_term_days": 60,
    "risk_margin_apr_pct": 4.0,       # over expected loss + opportunity cost
    "max_p_underwater": 0.05,         # P(collateral < debt) before liquidation can act
    "max_p_liquidation": 0.25,
    "liquidation_grace_days": 3,
    "btc_watch_addresses": [],        # watch-only (no BTC signing in the harness)
    "stale_order_p72_threshold": 0.35,
}


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _http_json(url: str, timeout: int = 15) -> Any:
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def _cache_get(name: str, ttl: int, fetch, stale_ok: int = 0) -> Dict[str, Any]:
    """File cache. Returns {"data", "age_s", "stale"} or {"error"}; stale data (<= stale_ok s) is
    returned with stale=True when the live fetch fails."""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    p = CACHE_DIR / f"fund_{name}.json"
    cached = None
    if p.exists():
        try:
            cached = json.loads(p.read_text())
        except (OSError, json.JSONDecodeError):
            cached = None
    now = time.time()
    if cached and now - cached.get("ts", 0) < ttl:
        return {"data": cached["data"], "age_s": int(now - cached["ts"]), "stale": False}
    try:
        data = fetch()
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps({"ts": now, "data": data}))
        tmp.replace(p)
        return {"data": data, "age_s": 0, "stale": False}
    except Exception as e:  # network / rate limit
        if cached and now - cached.get("ts", 0) < max(ttl, stale_ok):
            return {"data": cached["data"], "age_s": int(now - cached["ts"]), "stale": True,
                    "error": f"{type(e).__name__}: {e}"}
        return {"error": f"{type(e).__name__}: {e}"}


def load_policy() -> Dict[str, Any]:
    pol = json.loads(json.dumps(DEFAULT_POLICY))
    if POLICY_FILE.exists():
        try:
            user = json.loads(POLICY_FILE.read_text())
            for k, v in user.items():
                pol[k] = v
        except (OSError, json.JSONDecodeError):
            pass
    return pol


def save_policy(updates: Dict[str, Any]) -> Dict[str, Any]:
    pol = load_policy()
    for k, v in updates.items():
        if k not in DEFAULT_POLICY:
            raise ValueError(f"unknown policy key {k}")
        pol[k] = v
    POLICY_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = POLICY_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(pol, indent=2))
    tmp.replace(POLICY_FILE)
    return pol


# ---------------------------------------------------------------------------
# prices
# ---------------------------------------------------------------------------

def usd_prices() -> Dict[str, Any]:
    ids = ",".join(COINGECKO_IDS.values())
    r = _cache_get("cg_simple", 120, lambda: _http_json(
        f"https://api.coingecko.com/api/v3/simple/price?ids={ids}&vs_currencies=usd"), stale_ok=3600)
    if "data" not in r:
        return {"status": "unavailable", "reason": r.get("error"), "usd": {}}
    usd = {sym: (r["data"].get(cg) or {}).get("usd") for sym, cg in COINGECKO_IDS.items()}
    return {"status": "ok", "usd": usd, "age_s": r["age_s"], "stale": r["stale"], "source": "coingecko"}


def cardano_token_price_ada(symbol: str) -> Optional[float]:
    try:
        from lib.tools.quant.market_data import load_series
        s = load_series(symbol, "hour")
        return float(s["pool"]["price_ada"]) if s.get("status") == "ok" else None
    except Exception:
        return None


def usd_daily_history(symbol: str, days: int = 180) -> Dict[str, Any]:
    """Daily USD closes from CoinGecko (cached 6h)."""
    cg = COINGECKO_IDS.get(symbol.upper())
    if not cg:
        return {"status": "error", "reason": f"no CoinGecko id for {symbol}"}
    r = _cache_get(f"cg_hist_{cg}_{days}", 6 * 3600, lambda: _http_json(
        f"https://api.coingecko.com/api/v3/coins/{cg}/market_chart?vs_currency=usd&days={days}&interval=daily"),
        stale_ok=3 * 86400)
    if "data" not in r:
        return {"status": "error", "reason": r.get("error")}
    px = [p[1] for p in r["data"].get("prices", []) if p and p[1]]
    return {"status": "ok", "closes": px, "age_s": r["age_s"], "stale": r["stale"]}


# ---------------------------------------------------------------------------
# holdings / treasury
# ---------------------------------------------------------------------------

def _cardano_holdings() -> Dict[str, Any]:
    from lib.tools import cardano_orders as co
    from lib.tools.quant.market_data import KNOWN_ASSETS
    addr, _ = co.default_wallet()
    bal = co.wallet_balance(addr)
    unit_to_sym = {m["unit"]: (s, m["decimals"]) for s, m in KNOWN_ASSETS.items()}
    rows: List[Dict[str, Any]] = [{"chain": "cardano", "asset": "ADA", "amount": bal.get("lovelace", 0) / 1e6,
                                   "location": "hot wallet", "locked": False}]
    for unit, q in bal.items():
        if unit == "lovelace":
            continue
        sym, dec = unit_to_sym.get(unit, (unit[56:72] or unit[:12], 0))
        rows.append({"chain": "cardano", "asset": sym, "amount": q / 10 ** dec, "location": "hot wallet",
                     "locked": False, "unit": unit})
    # Inventory locked in our open DEX orders (DB is the index, chain is the truth).
    try:
        from lib.tools.cardano_maker_db import get_db_connection, init_db
        init_db()
        with get_db_connection() as conn:
            dbrows = conn.execute("SELECT order_id, asset, status, metadata_json FROM maker_orders "
                                  "WHERE status IN ('PENDING_BUY','PENDING_SELL')").fetchall()
        for oid, asset, status, meta_s in dbrows:
            meta = json.loads(meta_s or "{}")
            ref = meta.get("order_utxo")
            if not ref or "#" not in ref:
                continue
            h, ix = ref.split("#")
            utx = co.bf_get(f"/txs/{h}/utxos", allow_404=True)
            out = next((o for o in (utx or {}).get("outputs", []) if o["output_index"] == int(ix)), None)
            if not out or out.get("consumed_by_tx"):
                continue
            for a in out.get("amount", []):
                if a["unit"] == "lovelace":
                    rows.append({"chain": "cardano", "asset": "ADA", "amount": int(a["quantity"]) / 1e6,
                                 "location": f"order {ref[:10]}… ({status})", "locked": True, "order_id": oid})
                else:
                    sym, dec = unit_to_sym.get(a["unit"], (a["unit"][56:72], 0))
                    rows.append({"chain": "cardano", "asset": sym, "amount": int(a["quantity"]) / 10 ** dec,
                                 "location": f"order {ref[:10]}… ({status})", "locked": True, "order_id": oid})
    except Exception as e:
        rows.append({"chain": "cardano", "asset": "?", "amount": None, "location": "open orders",
                     "error": f"{type(e).__name__}: {e}"})
    return {"address": addr, "rows": rows}


def _evm_holdings() -> Dict[str, Any]:
    from lib.tools import sovereign_multichain_wallet as smw
    out: Dict[str, Any] = {"rows": [], "notes": []}
    try:
        pg = smw.get_polygon_status()
        if pg.get("status") == "ok":
            out["polygon_address"] = pg.get("address")
            out["rows"] += [
                {"chain": "polygon", "asset": "POL", "amount": pg.get("pol_balance"), "location": "hot wallet", "locked": False},
                {"chain": "polygon", "asset": "USDC", "amount": pg.get("usdc_native"), "location": "native USDC", "locked": False},
                {"chain": "polygon", "asset": "USDC", "amount": pg.get("usdc_bridged"), "location": "USDC.e (bridged)", "locked": False},
            ]
        else:
            out["notes"].append(f"polygon: {pg.get('message') or pg.get('status')}")
    except Exception as e:
        out["notes"].append(f"polygon: {type(e).__name__}: {e}")
    try:
        eth = smw.get_ethereum_status()
        if eth.get("status") == "ok":
            out["ethereum"] = eth
            out["rows"] += [
                {"chain": "ethereum", "asset": "ETH", "amount": eth.get("eth_balance"), "location": "hot wallet", "locked": False},
                {"chain": "ethereum", "asset": "USDC", "amount": eth.get("usdc_balance"), "location": "hot wallet",
                 "locked": not eth.get("has_sufficient_gas", False),
                 "note": None if eth.get("has_sufficient_gas") else "stranded: no ETH for gas"},
            ]
        else:
            out["notes"].append(f"ethereum: {eth.get('message') or eth.get('status')}")
    except Exception as e:
        out["notes"].append(f"ethereum: {type(e).__name__}: {e}")
    return out


def _btc_holdings(addresses: List[str]) -> Dict[str, Any]:
    rows, notes = [], []
    for a in addresses[:5]:
        if not isinstance(a, str) or not a.isalnum() or not (25 <= len(a) <= 90):
            notes.append("ignored malformed BTC address")
            continue
        try:
            d = _http_json(f"https://mempool.space/api/address/{a}")
            cs, ms = d.get("chain_stats", {}), d.get("mempool_stats", {})
            sats = cs.get("funded_txo_sum", 0) - cs.get("spent_txo_sum", 0) + ms.get("funded_txo_sum", 0) - ms.get("spent_txo_sum", 0)
            rows.append({"chain": "bitcoin", "asset": "BTC", "amount": sats / 1e8, "location": f"watch-only {a[:8]}…",
                         "locked": False})
        except Exception as e:
            notes.append(f"btc {a[:8]}…: {type(e).__name__}")
    if not addresses:
        notes.append("no BTC address configured (fund_policy.json btc_watch_addresses); BTC is tracked watch-only")
    return {"rows": rows, "notes": notes}


def treasury() -> Dict[str, Any]:
    pol = load_policy()
    prices = usd_prices()
    usd = prices.get("usd", {})
    ada_usd = usd.get("ADA")
    card = _cardano_holdings()
    evm = _evm_holdings()
    btc = _btc_holdings(pol.get("btc_watch_addresses") or [])
    rows = card["rows"] + evm["rows"] + btc["rows"]
    token_px: Dict[str, Optional[float]] = {}
    for r in rows:
        a, amt = r.get("asset"), r.get("amount")
        if amt is None:
            r["value_usd"] = r["value_ada"] = None
            continue
        if a in usd and usd.get(a) is not None:
            r["price_usd"] = usd[a]
            r["value_usd"] = amt * usd[a]
            r["value_ada"] = r["value_usd"] / ada_usd if ada_usd else None
        else:
            if a not in token_px:
                token_px[a] = cardano_token_price_ada(a)
            px = token_px[a]
            r["price_ada"] = px
            r["value_ada"] = amt * px if px is not None else None
            r["value_usd"] = r["value_ada"] * ada_usd if (r["value_ada"] is not None and ada_usd) else None
    tot_usd = sum(r["value_usd"] for r in rows if r.get("value_usd") is not None)
    by_asset: Dict[str, float] = {}
    for r in rows:
        if r.get("value_usd") is None:
            continue
        bucket = r["asset"] if r["asset"] in TARGET_ASSETS else "ADA"  # native tokens are ADA-ecosystem risk
        by_asset[bucket] = by_asset.get(bucket, 0.0) + r["value_usd"]
    targets = pol["targets_pct"]
    allocation = []
    for a in TARGET_ASSETS:
        cur = by_asset.get(a, 0.0)
        cur_pct = 100 * cur / tot_usd if tot_usd else 0.0
        tgt = float(targets.get(a, 0))
        allocation.append({"asset": a, "value_usd": round(cur, 2), "pct": round(cur_pct, 2), "target_pct": tgt,
                           "drift_pct": round(cur_pct - tgt, 2),
                           "gap_usd": round(tgt / 100 * tot_usd - cur, 2) if tot_usd else None})
    for r in rows:
        for k in ("value_usd", "value_ada", "amount"):
            if isinstance(r.get(k), float):
                r[k] = round(r[k], 6)
    return {"status": "ok", "timestamp": int(time.time()), "prices": prices, "rows": rows,
            "total_usd": round(tot_usd, 2), "total_ada": round(tot_usd / ada_usd, 3) if ada_usd else None,
            "locked_usd": round(sum(r["value_usd"] for r in rows if r.get("locked") and r.get("value_usd")), 2),
            "allocation": allocation, "cardano_address": card["address"],
            "evm_address": evm.get("polygon_address"),
            "ethereum": {k: evm.get("ethereum", {}).get(k) for k in ("gas_price_gwei", "has_sufficient_gas",
                                                                       "est_transfer_cost_eth")},
            "notes": evm["notes"] + btc["notes"]}


# ---------------------------------------------------------------------------
# fund ledger
# ---------------------------------------------------------------------------

def ledger_entries() -> List[Dict[str, Any]]:
    if not LEDGER_FILE.exists():
        return []
    out = []
    with open(LEDGER_FILE) as f:
        for line in f:
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return out


def ledger_add(etype: str, asset: str, amount: float, ref: str = "", note: str = "",
               actor: str = "operator", loan_id: Optional[str] = None) -> Dict[str, Any]:
    if etype not in LEDGER_TYPES:
        raise ValueError(f"type must be one of {sorted(LEDGER_TYPES)}")
    asset = asset.upper()
    if asset not in TARGET_ASSETS:
        raise ValueError(f"fund assets are {TARGET_ASSETS}")
    if not (isinstance(amount, (int, float)) and math.isfinite(amount) and amount > 0):
        raise ValueError("amount must be a positive number")
    if etype in ("allocate", "deallocate", "loan_out", "expense"):
        st = fund_state(include_maker=False)
        avail = st["available"].get(asset, 0.0)
        if etype in ("deallocate", "loan_out", "expense") and amount > avail + 1e-9:
            raise ValueError(f"{etype} {amount} {asset} exceeds fund available {avail:.6f}")
        if etype == "allocate" and asset == "ADA" and actor != "operator":
            raise ValueError("only the operator may earmark new capital")
    e = {"ts": int(time.time()), "type": etype, "asset": asset, "amount": float(amount), "ref": str(ref)[:120],
         "note": str(note)[:300], "actor": actor, "loan_id": loan_id}
    LEDGER_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(LEDGER_FILE, "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(json.dumps(e) + "\n")
        fcntl.flock(f, fcntl.LOCK_UN)
    return {"status": "ok", "entry": e}


def _maker_pnl() -> Dict[str, Any]:
    try:
        from lib.tools.cardano_maker_db import get_db_connection, init_db
        init_db()
        with get_db_connection() as conn:
            cols = [r[1] for r in conn.execute("PRAGMA table_info(maker_orders)").fetchall()]
            pcol = "realized_profit_ada" if "realized_profit_ada" in cols else None
            if not pcol:
                return {"status": "unavailable", "reason": "no realized_profit_ada column"}
            row = conn.execute(f"SELECT COUNT(*), COALESCE(SUM({pcol}),0) FROM maker_orders "
                               "WHERE status='COMPLETED' AND tx_id NOT LIKE 'sim_%'").fetchone()
        return {"status": "ok", "completed_cycles": row[0], "realized_profit_ada": round(float(row[1]), 6)}
    except Exception as e:
        return {"status": "unavailable", "reason": f"{type(e).__name__}: {e}"}


def fund_state(include_maker: bool = True) -> Dict[str, Any]:
    entries = ledger_entries()
    avail: Dict[str, float] = {}
    totals: Dict[str, Dict[str, float]] = {}
    for e in entries:
        sign = LEDGER_TYPES.get(e.get("type"), 0)
        a = e.get("asset", "ADA")
        avail[a] = avail.get(a, 0.0) + sign * float(e.get("amount", 0))
        totals.setdefault(e["type"], {}).setdefault(a, 0.0)
        totals[e["type"]][a] += float(e.get("amount", 0))
    outstanding: Dict[str, float] = {}
    try:
        from lib.tools import sovereign_lending as sl
        for ln in sl.load_book().values():
            if ln.get("status") in sl.OPEN_LOAN_STATUSES:
                outstanding[ln["principal_asset"]] = outstanding.get(ln["principal_asset"], 0.0) + float(ln["principal"])
    except Exception:
        pass
    pol = load_policy()
    st: Dict[str, Any] = {"status": "ok", "available": {k: round(v, 6) for k, v in avail.items()},
                          "outstanding_principal": {k: round(v, 6) for k, v in outstanding.items()},
                          "totals_by_type": totals, "entries": len(entries),
                          "nav": {a: round(avail.get(a, 0.0) + outstanding.get(a, 0.0), 6)
                                  for a in set(avail) | set(outstanding)}}
    if include_maker:
        pnl = _maker_pnl()
        swept = totals.get("profit_sweep", {}).get("ADA", 0.0)
        st["maker_pnl"] = pnl
        if pnl.get("status") == "ok":
            due = max(0.0, pnl["realized_profit_ada"] * pol["profit_sweep_pct"] / 100.0 - swept)
            st["sweep_due_ada"] = round(due, 6)
    return st


# ---------------------------------------------------------------------------
# yields (DeFiLlama)
# ---------------------------------------------------------------------------

_YIELD_FILTER = {
    "ADA": {"chains": {"Cardano"}, "symbols": {"ADA"}},
    "USDC": {"chains": {"Polygon", "Ethereum", "Cardano"}, "symbols": {"USDC", "USDC.E", "USDCX"}},
    "ETH": {"chains": {"Ethereum", "Polygon"}, "symbols": {"WETH", "ETH"}},
    "BTC": {"chains": {"Ethereum", "Polygon"}, "symbols": {"WBTC", "CBBTC"}},
    "POL": {"chains": {"Polygon"}, "symbols": {"WPOL", "POL", "WMATIC"}},
}
_REPUTABLE = {"aave-v3", "compound-v3", "liqwid", "spark", "morpho-blue", "lido", "indigo", "rocket-pool"}


def yields(min_tvl_usd: float = 1_000_000) -> Dict[str, Any]:
    def fetch():
        d = _http_json("https://yields.llama.fi/pools", timeout=40)["data"]
        keep = []
        for p in d:
            sym = str(p.get("symbol", "")).upper()
            for asset, f in _YIELD_FILTER.items():
                if p.get("chain") in f["chains"] and sym in f["symbols"]:
                    keep.append({"asset": asset, "project": p.get("project"), "chain": p.get("chain"),
                                 "symbol": p.get("symbol"), "apy": p.get("apy"), "apy_base": p.get("apyBase"),
                                 "apy_reward": p.get("apyReward"), "tvl_usd": p.get("tvlUsd"),
                                 "stablecoin": p.get("stablecoin"), "il_risk": p.get("ilRisk"),
                                 "pool": p.get("pool")})
        return keep
    r = _cache_get("llama_yields", 3600, fetch, stale_ok=86400)
    if "data" not in r:
        return {"status": "unavailable", "reason": r.get("error"), "best": {}, "pools": []}
    pools = [p for p in r["data"] if (p.get("tvl_usd") or 0) >= min_tvl_usd and p.get("apy") is not None
             and p.get("project") in _REPUTABLE]
    pools.sort(key=lambda p: (p["asset"], -(p.get("apy_base") or p.get("apy") or 0)))
    best: Dict[str, Any] = {}
    reference: Dict[str, Any] = {}
    for p in pools:
        base = p.get("apy_base") if p.get("apy_base") is not None else p.get("apy")
        if p["asset"] not in best or base > (best[p["asset"]].get("apy_base") or best[p["asset"]]["apy"]):
            best[p["asset"]] = p
        if p["asset"] not in reference or (p.get("tvl_usd") or 0) > (reference[p["asset"]].get("tvl_usd") or 0):
            reference[p["asset"]] = p
    return {"status": "ok", "source": "defillama", "age_s": r["age_s"], "stale": r["stale"],
            "min_tvl_usd": min_tvl_usd, "best": best, "reference": reference, "pools": pools[:60],
            "note": "Informational; the harness has no deposit integration for these protocols yet. "
                    "The deepest reputable pool's base APY per asset is the fund's opportunity cost."}


def cost_of_capital_apr(asset: str) -> Dict[str, Any]:
    y = yields()
    b = y.get("reference", {}).get(asset.upper())
    if b:
        base = b.get("apy_base") if b.get("apy_base") is not None else b.get("apy")
        return {"apr_pct": float(base), "source": f"{b['project']} {b['chain']} {b['symbol']} (DeFiLlama)"}
    return {"apr_pct": 3.0, "source": "default 3% (yield data unavailable)"}


# ---------------------------------------------------------------------------
# opportunities
# ---------------------------------------------------------------------------

def opportunities(tr: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    pol = load_policy()
    tr = tr or treasury()
    ops: List[Dict[str, Any]] = []

    # 1. Stale resting orders (calibrated fill odds too low) -> reprice.
    try:
        from lib.tools.cardano_maker_db import get_db_connection, init_db
        from lib.tools.limit_order_forecaster import choose_rung, price_ladder
        init_db()
        with get_db_connection() as conn:
            conn.row_factory = None
            rows = conn.execute("SELECT order_id, asset, status, tokens_filled, tokens_target, sell_target_ada, capital_ada, target_price_ada, metadata_json "
                                "FROM maker_orders WHERE status='PENDING_SELL'").fetchall()
        for oid, asset, status, tokens_f, tokens_t, target_total, cap_ada, tgt_px, meta_s in rows:
            tokens = float(tokens_f or tokens_t or 0)
            eff_total = float(target_total or cap_ada or 0)
            price = (eff_total / tokens) if (tokens > 0 and eff_total > 0) else float(tgt_px or 0)
            if tokens <= 0 or price <= 0:
                continue
            lad = price_ladder(asset, "sell", tokens, prices=[price])
            if lad.get("status") != "ok":
                continue
            p72 = lad["rungs"][0]["fill_probability"].get("72h", 0)
            entry = {"kind": "order_health", "order_id": oid, "asset": asset, "limit_price": round(price, 8),
                     "spot": lad["spot_price_ada"], "p24h": lad["rungs"][0]["fill_probability"].get("24h"),
                     "p72h": p72}
            if p72 < pol["stale_order_p72_threshold"]:
                best = choose_rung(price_ladder(asset, "sell", tokens, n_rungs=21, span_pct=8.0), "24h", 0.7)
                entry.update({"priority": 1, "title": f"Reprice stale {asset} sell (P72h {p72:.0%})",
                              "action": "reclaim + relist", "suggested_price": best and best["price"],
                              "tools": ["crypto_reclaim_order", "crypto_place_limit"]})
            else:
                entry.update({"priority": 5, "title": f"{asset} sell healthy (P72h {p72:.0%})", "action": "hold"})
            ops.append(entry)
    except Exception as e:
        ops.append({"kind": "order_health", "priority": 9, "title": "order health unavailable", "error": str(e)[:200]})

    # 2. Stranded Ethereum USDC.
    eth = tr.get("ethereum") or {}
    eth_usdc = next((r for r in tr["rows"] if r["chain"] == "ethereum" and r["asset"] == "USDC"), None)
    if eth_usdc and (eth_usdc.get("amount") or 0) > 0 and not eth.get("has_sufficient_gas"):
        gwei = eth.get("gas_price_gwei") or 1.0
        need_eth = gwei * 1e-9 * 70_000 * 3  # ~3 ERC-20 transfers of headroom
        eth_usd = tr["prices"]["usd"].get("ETH")
        ops.append({"kind": "stranded", "priority": 2, "title": f"Unlock {eth_usdc['amount']:.2f} USDC on Ethereum",
                    "detail": f"Needs ~{need_eth:.6f} ETH gas (≈${need_eth * eth_usd:.2f}) at {gwei} gwei"
                              if eth_usd else f"Needs ~{need_eth:.6f} ETH gas",
                    "action": "send a small amount of ETH to the EVM address, then move USDC to Polygon/fund",
                    "address": tr.get("evm_address")})

    # 3. Allocation drift toward accumulation targets.
    for a in tr.get("allocation", []):
        if a["gap_usd"] is not None and a["gap_usd"] > max(5.0, 0.05 * tr["total_usd"]):
            route = {
                "USDC": "Polygon: swap POL->USDC (polygon_swapper) or route Cardano profits via stablecoin pools",
                "POL": "Polygon: buy POL with USDC on a Polygon DEX",
                "ETH": "Bridge USDC to Ethereum/Polygon WETH (not automated)",
                "BTC": "Acquire via CEX or wrapped BTC (watch-only in harness)",
                "ADA": "Recycle stuck native-token inventory to ADA; sweep maker profits",
            }.get(a["asset"], "")
            ops.append({"kind": "allocation", "priority": 4, "title": f"Accumulate {a['asset']}: ${a['gap_usd']:.2f} under target",
                        "detail": f"{a['pct']:.1f}% vs target {a['target_pct']:.0f}%", "action": route})

    # 4. Profit sweep into the loan fund.
    st = fund_state()
    if (st.get("sweep_due_ada") or 0) > 0.5:
        ops.append({"kind": "sweep", "priority": 3, "title": f"Sweep {st['sweep_due_ada']:.2f} ADA of maker profit into the loan fund",
                    "action": "ledger-add --type profit_sweep", "tools": ["fund_ledger_add"]})
    if not st["available"] and not st["outstanding_principal"]:
        ops.append({"kind": "fund", "priority": 3, "title": "Loan fund has no earmarked capital",
                    "action": "earmark ADA with ledger-add --type allocate (operator)"})

    # 5. Loan servicing.
    try:
        from lib.tools import sovereign_lending as sl
        for ln in sl.load_book().values():
            if ln.get("status") in ("AWAITING_COLLATERAL", "FUNDED", "MARGIN_CALL", "DEFAULTED"):
                ops.append({"kind": "loan", "priority": 2 if ln["status"] in ("MARGIN_CALL", "DEFAULTED") else 4,
                            "title": f"Loan {ln['id']}: {ln['status']}", "loan_id": ln["id"],
                            "action": "service (check collateral / repayments / LTV)", "tools": ["lending_service"]})
    except Exception:
        pass

    # 6. Idle stablecoins vs best real yield (informational).
    y = yields()
    usdc_best = y.get("best", {}).get("USDC")
    idle_usdc = sum((r.get("amount") or 0) for r in tr["rows"] if r["asset"] == "USDC" and not r.get("locked"))
    if usdc_best and idle_usdc > 1:
        apy = usdc_best.get("apy_base") or usdc_best.get("apy")
        ops.append({"kind": "yield", "priority": 6,
                    "title": f"{idle_usdc:.2f} idle USDC could earn {apy:.2f}% on {usdc_best['project']} ({usdc_best['chain']})",
                    "detail": f"≈ ${idle_usdc * apy / 100:.2f}/yr; deposit integration not built (TODO)",
                    "action": "informational"})
    ops.sort(key=lambda o: o.get("priority", 9))
    return {"status": "ok", "timestamp": int(time.time()), "count": len(ops), "opportunities": ops}


def main() -> None:
    p = argparse.ArgumentParser(description="Sovereign Loan Fund")
    p.add_argument("cmd", choices=["treasury", "state", "yields", "opportunities", "policy", "ledger", "ledger-add",
                                   "set-policy"])
    p.add_argument("--type"); p.add_argument("--asset", default="ADA"); p.add_argument("--amount", type=float)
    p.add_argument("--ref", default=""); p.add_argument("--note", default="")
    p.add_argument("--actor", default="operator", choices=["operator", "george"])
    p.add_argument("--policy-json", default=None, help="JSON object of policy updates (set-policy)")
    p.add_argument("--json", action="store_true")
    a = p.parse_args()
    try:
        if a.cmd == "treasury":
            res = treasury()
        elif a.cmd == "state":
            res = fund_state()
        elif a.cmd == "yields":
            res = yields()
        elif a.cmd == "opportunities":
            res = opportunities()
        elif a.cmd == "policy":
            res = {"status": "ok", "policy": load_policy()}
        elif a.cmd == "set-policy":
            if a.actor != "operator":
                raise ValueError("only the operator may change fund policy")
            res = {"status": "ok", "policy": save_policy(json.loads(a.policy_json or "{}"))}
        elif a.cmd == "ledger":
            res = {"status": "ok", "entries": ledger_entries()[-200:]}
        else:
            if not a.type or a.amount is None:
                raise ValueError("ledger-add requires --type and --amount")
            res = ledger_add(a.type, a.asset, a.amount, a.ref, a.note, a.actor)
    except Exception as e:
        res = {"status": "error", "message": f"{type(e).__name__}: {e}"}
    print(json.dumps(res, indent=2 if not a.json else None, default=str))


if __name__ == "__main__":
    main()
