#!/usr/bin/env python3
"""
Portfolio snapshot: wallet (chain), open orders (maker DB cross-checked on chain), positions with
cost basis, exposure per asset, equity and working capital.

Chain is the source of truth for balances and order state; the maker DB supplies cost basis and
order ids. Disagreements are reported, never papered over. If the wallet balance cannot be read,
wallet_ada is None and every capital check fails closed.
"""
from __future__ import annotations

import json
import time
from typing import Any, Callable, Dict, List, Optional

from lib.tools.quant import tokens as tok


def _wallet() -> Dict[str, Any]:
    from lib.tools import cardano_orders as co
    addr, pkh = co.default_wallet()
    return {"address": addr, "pkh": pkh, "balance": co.wallet_balance(addr)}


def _order_status(utxo: str, pkh: str) -> Dict[str, Any]:
    from lib.tools import cardano_orders as co
    h, i = utxo.split("#")
    d = co.describe_order_output(h, int(i), our_pkh=pkh)
    return {"status": d.get("status"), "locked_value": d.get("locked_value") or {}, "protocol": d.get("protocol"),
            "consumed_by_tx": d.get("consumed_by_tx")}


def _db_rows() -> List[Dict[str, Any]]:
    from lib.tools.cardano_maker_db import get_db_connection, init_db
    init_db(is_simulated=False)
    with get_db_connection(is_simulated=False) as conn:
        rows = conn.execute("SELECT * FROM maker_orders WHERE status IN ('PENDING_BUY','INVENTORY_HOLD','PENDING_SELL') "
                            "ORDER BY created_at").fetchall()
        return [dict(r) for r in rows]


# Injection points for tests
WALLET: Callable[[], Dict[str, Any]] = _wallet
ORDER_STATUS: Callable[[str, str], Dict[str, Any]] = _order_status
DB_ROWS: Callable[[], List[Dict[str, Any]]] = _db_rows


def _meta(r: Dict[str, Any]) -> Dict[str, Any]:
    try:
        return json.loads(r.get("metadata_json") or "{}")
    except ValueError:
        return {}


def snapshot(pol: Dict[str, Any], market: Optional[Dict[str, Dict[str, Any]]] = None,
             check_chain: bool = True) -> Dict[str, Any]:
    from lib.tools.trading.market import market_ctx
    out: Dict[str, Any] = {"ts": int(time.time()), "warnings": []}
    try:
        w = WALLET()
        bal = w["balance"]
        out["wallet_address"] = w["address"]
        out["wallet_ada"] = bal.get("lovelace", 0) / 1e6
        pkh = w["pkh"]
    except Exception as e:
        out["wallet_ada"] = None
        out["warnings"].append(f"wallet balance unavailable: {type(e).__name__}: {str(e)[:120]}")
        bal, pkh = {}, ""
    wallet_tokens: Dict[str, float] = {}
    for unit, q in bal.items():
        if unit == "lovelace":
            continue
        sym = tok.symbol_for_unit(unit)
        if sym:
            wallet_tokens[sym] = q / 10 ** tok.decimals(sym)
    out["wallet_tokens"] = wallet_tokens

    try:
        rows = DB_ROWS()
    except Exception as e:
        rows = []
        out["warnings"].append(f"maker DB unreadable: {type(e).__name__}")
    open_orders: List[Dict[str, Any]] = []
    positions: Dict[str, Dict[str, Any]] = {}
    locked_lovelace = 0
    locked_tokens: Dict[str, float] = {}
    buy_locked_ada: Dict[str, float] = {}
    for r in rows:
        meta = _meta(r)
        asset = r["asset"].upper()
        if r["status"] == "PENDING_BUY":
            utxo = meta.get("order_utxo") or (f"{r['tx_id']}#0" if r.get("tx_id") else None)
            o = {"order_id": r["order_id"], "asset": asset, "side": "buy", "utxo": utxo, "price": r["target_price_ada"],
                 "ada": r["capital_ada"], "tokens": r["tokens_target"], "created_at": r["created_at"]}
        elif r["status"] == "PENDING_SELL":
            sell_tx = r.get("sell_tx_id") or r.get("tx_id")
            utxo = meta.get("order_utxo") or (f"{sell_tx}#0" if sell_tx else None)
            tokens = float(r.get("tokens_filled") or r.get("tokens_target") or 0.0)
            ada = float(r.get("sell_target_ada") or r.get("capital_ada") or 0.0)
            price = (ada / tokens) if (ada and tokens) else (float(r["target_price_ada"]) if r.get("target_price_ada") else None)
            o = {"order_id": r["order_id"], "asset": asset, "side": "sell", "utxo": utxo,
                 "price": price, "tokens": tokens, "ada": ada,
                 "created_at": int(meta.get("sell_placed_at") or meta.get("sell_claim_at") or r["updated_at"])}
        else:
            o = None
        if r["status"] in ("INVENTORY_HOLD", "PENDING_SELL"):
            p = positions.setdefault(asset, {"asset": asset, "tokens_db": 0.0, "cost_ada": None, "opened_at": r["created_at"],
                                             "order_ids": []})
            row_cost = float(r.get("cost_basis_ada") or 0)
            if row_cost > 0:
                p["tokens_db"] += float(r.get("tokens_filled") or r.get("tokens_target") or 0)
                p["cost_ada"] = (p["cost_ada"] or 0.0) + row_cost
            p["opened_at"] = min(p["opened_at"], meta.get("filled_at") or r["created_at"])
            p["order_ids"].append(r["order_id"])
        if o is None:
            continue
        o["plan_id"] = meta.get("plan_id")
        o["strategy"] = meta.get("strategy")
        if check_chain and o["utxo"] and pkh:
            try:
                st = ORDER_STATUS(o["utxo"], pkh)
                o["chain_status"] = st["status"]
                if st["status"] in ("OPEN", "EXPIRED"):
                    lv = st["locked_value"]
                    locked_lovelace += int(lv.get("lovelace", 0))
                    for unit, q in lv.items():
                        sym = tok.symbol_for_unit(unit) if unit != "lovelace" else None
                        if sym:
                            locked_tokens[sym] = locked_tokens.get(sym, 0.0) + q / 10 ** tok.decimals(sym)
                    if o["side"] == "buy":
                        buy_locked_ada[asset] = buy_locked_ada.get(asset, 0.0) + float(o.get("ada") or (int(lv.get("lovelace", 0)) / 1e6))
                else:
                    out["warnings"].append(f"{o['order_id']} is {st['status']} on chain but {r['status']} in the DB (watcher will reconcile)")
            except Exception as e:
                o["chain_status"] = "UNKNOWN"
                out["warnings"].append(f"order {o['order_id']} status check failed: {type(e).__name__}")
        elif not check_chain:
            o["chain_status"] = "DB_ONLY"
            db_locked_ada = float(r.get("onchain_locked_ada") or ((float(o.get("ada") or 0.0) + 4.0) if o["side"] == "buy" else 4.0))
            locked_lovelace += int(round(db_locked_ada * 1e6))
            if o["side"] == "buy":
                buy_locked_ada[asset] = buy_locked_ada.get(asset, 0.0) + float(o.get("ada") or db_locked_ada)
            elif o["side"] == "sell" and o.get("tokens"):
                locked_tokens[asset] = locked_tokens.get(asset, 0.0) + float(o["tokens"])
        open_orders.append(o)
    out["open_orders"] = open_orders

    assets = set(wallet_tokens) | set(locked_tokens) | set(positions) | set(buy_locked_ada)
    market = dict(market or {})
    for a in assets:
        if a not in market:
            market[a] = market_ctx(a)
    exposure: Dict[str, float] = {}
    token_value = 0.0
    for a in sorted(assets):
        held = wallet_tokens.get(a, 0.0) + locked_tokens.get(a, 0.0)
        spot = (market.get(a) or {}).get("spot")
        val = held * spot if spot else None
        if val is None and held > 0:
            out["warnings"].append(f"{a}: no price; {held:,.4f} tokens excluded from equity")
        exposure[a] = (val or 0.0) + buy_locked_ada.get(a, 0.0)
        token_value += val or 0.0
        p = positions.get(a)
        if held > 0 or p:
            p = positions.setdefault(a, {"asset": a, "tokens_db": 0.0, "cost_ada": None, "opened_at": None, "order_ids": []})
            p["tokens"] = held
            p["spot"] = spot
            p["value_ada"] = val
            if p.get("cost_ada") is not None and p.get("tokens_db"):
                if abs(held - p["tokens_db"]) > max(1e-6, 0.01 * p["tokens_db"]):
                    # Chain holds a different quantity than the DB recorded: scale cost per token, flag it.
                    out["warnings"].append(f"{a}: chain holds {held:,.4f} tokens vs {p['tokens_db']:,.4f} in the DB; "
                                           "cost basis covers the DB quantity only")
                    if held > 0:
                        per = p["cost_ada"] / p["tokens_db"]
                        p["cost_ada_db"] = p["cost_ada"]
                        p["cost_ada"] = per * min(held, p["tokens_db"]) if held < p["tokens_db"] else p["cost_ada"]
                        p["uncosted_tokens"] = max(0.0, held - p["tokens_db"])
            from lib.tools.trading.policy import breakeven_price
            be_tokens = min(held, p["tokens_db"]) if p.get("tokens_db") else held
            p["breakeven"] = breakeven_price(p.get("cost_ada"), be_tokens, pol) if p.get("cost_ada") is not None else None
            p["unrealized_ada"] = (spot * be_tokens - p["cost_ada"]) if (spot and p.get("cost_ada") is not None) else None
            p["age_s"] = (time.time() - p["opened_at"]) if p.get("opened_at") else None
    out["positions"] = {a: p for a, p in positions.items() if (p.get("tokens") or 0) > 0}
    out["exposure_ada"] = exposure
    out["locked_ada_in_orders"] = locked_lovelace / 1e6
    if check_chain and out["wallet_ada"] is not None and any(
        o.get("chain_status") in ("OPEN", "EXPIRED") and (out["ts"] - int(o.get("created_at") or 0)) < 300
        for o in open_orders
    ):
        try:
            w2 = WALLET()
            bal2 = w2.get("balance") or {}
            if "lovelace" in bal2:
                out["wallet_ada"] = min(float(out["wallet_ada"]), bal2.get("lovelace", 0) / 1e6)
        except Exception:
            pass
    if out["wallet_ada"] is not None:
        eq = out["wallet_ada"] + locked_lovelace / 1e6 + token_value
        out["equity_ada"] = eq
        out["working_capital_ada"] = eq - pol["wallet"]["floor_ada"] - pol["wallet"]["fee_buffer_ada"]
        out["free_ada"] = out["wallet_ada"] - pol["wallet"]["floor_ada"] - pol["wallet"]["fee_buffer_ada"]
    else:
        out["equity_ada"] = out["working_capital_ada"] = out["free_ada"] = None
    out["_market"] = market
    return out
