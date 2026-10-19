#!/usr/bin/env python3
"""
Two-step trading: build_plan() proposes, execute_plan() acts.

A plan is a list of typed actions (reclaim / place_buy / place_sell / reprice /
standing_order_create / strategy_unlock), each with prices, fill odds, fees, its permission tier
and the policy checks it passed or failed. Plans are stored in trading.db with a sha256 hash
over their content, a 10-minute TTL and the spot / sigma_1h references they were priced on.

execute_plan() re-checks everything against fresh chain and market state:
  * expired, tampered (hash mismatch), already executed, or stale (spot moved > 0.5 sigma_1h)
    plans are refused;
  * Tier A actions run unless the drawdown freeze is on (reclaims always run);
  * Tier B actions need a single-use confirm token minted from the operator's reply
    (bound to this plan's hash) or an active standing order that covers them;
  * Tier C is refused;
  * strategies in state 'simulated' are journalled as shadow trades, 'disabled' are refused;
  * transactions are submitted only when policy execution.live is true (and not in test /
    dry-run mode); otherwise the transaction is built and validated but not sent.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import re
import secrets
import time
from typing import Any, Callable, Dict, List, Optional, Tuple

from lib.tools.trading import journal, policy, store
from lib.tools.trading import market as mkt
from lib.tools.trading import portfolio as pf

PLAN_RE = re.compile(r"^P-[0-9A-F]{6}$")
SO_RE = re.compile(r"^SO-[0-9A-F]{6}$")
ASSET_RE = re.compile(r"^[A-Z0-9]{2,12}$")
TIER_ORDER = {"A": 0, "B": 1, "C": 2}
PRICE_ACTIONS = {"place_buy", "place_sell", "reprice"}
REPRICE_MIN_LOG = 0.005          # do not churn orders for < 0.5% moves
REPRICE_MIN_AGE_S = 6 * 3600     # nor reprice an order placed < 6 h ago (each reprice costs ~0.4 ADA)


# ---------------------------------------------------------------------------
# Injection points (tests replace these)
# ---------------------------------------------------------------------------

def _place(asset: str, side: str, tokens: float, price: float, execute: bool, actor: str,
           parent_order_id: Optional[str]) -> Dict[str, Any]:
    from lib.tools.minswap_v2 import place_limit_order
    return place_limit_order(asset, side, tokens, price, execute=execute, actor=actor,
                             parent_order_id=parent_order_id, force_collision=True)


def _reclaim(utxo: str, execute: bool, actor: str, wait: bool) -> Dict[str, Any]:
    from lib.tools.cardano_orders import reclaim_order
    return reclaim_order(utxo, execute=execute, actor=actor, wait=wait)


def _tag_order(tx_id: str, fields: Dict[str, Any]) -> None:
    from lib.tools.cardano_maker_db import get_db_connection
    with get_db_connection() as conn:
        for k, v in fields.items():
            conn.execute("UPDATE maker_orders SET metadata_json = json_set(COALESCE(metadata_json,'{}'), ?, ?) "
                         "WHERE tx_id = ? OR sell_tx_id = ?", (f"$.{k}", v, tx_id, tx_id))
        conn.commit()


def _claim_sell(order_id: str) -> None:
    """Blocks the S1 reactor from relisting this inventory while we reprice it ourselves."""
    from lib.tools.cardano_maker_db import get_db_connection
    with get_db_connection() as conn:
        conn.execute("UPDATE maker_orders SET metadata_json = json_set(COALESCE(metadata_json,'{}'), '$.sell_claim_at', ?) "
                     "WHERE order_id = ?", (int(time.time()), order_id))
        conn.commit()


PLACE: Callable[..., Dict[str, Any]] = _place
RECLAIM: Callable[..., Dict[str, Any]] = _reclaim
TAG_ORDER: Callable[[str, Dict[str, Any]], None] = _tag_order
CLAIM_SELL: Callable[[str], None] = _claim_sell
SNAPSHOT: Callable[..., Dict[str, Any]] = pf.snapshot
MARKET: Callable[..., Dict[str, Any]] = mkt.market_ctx


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _phi(x: float) -> float:
    return 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)))


def touch_probability(d_log: float, sigma: Optional[float]) -> Optional[float]:
    """Reflection-principle probability that a driftless random walk with horizon sigma moves
    at least d_log (in log terms) at some point in the horizon. With the mean reversion we
    measure at 1-24 h this is a conservative-to-fair estimate; it is a model, not a promise."""
    if sigma is None or sigma <= 0:
        return None
    if d_log <= 0:
        return 1.0
    return min(1.0, 2.0 * (1.0 - _phi(d_log / sigma)))


def _fee(m: Dict[str, Any], pol: Dict[str, Any]) -> float:
    bps = m.get("fee_bps")
    return float(bps if bps is not None else pol["fees"]["default_pool_fee_bps"]) / 1e4


def _round_trip_fixed(pol: Dict[str, Any]) -> float:
    f = pol["fees"]
    return 2 * (f["max_batcher_fee_ada"] + f["network_fee_ada"])


def plan_hash(p: Dict[str, Any]) -> str:
    body = {k: p[k] for k in ("plan_id", "intent", "actions", "refs", "expires_at")}
    return hashlib.sha256(json.dumps(body, sort_keys=True, default=str).encode()).hexdigest()


def _new_id(con, prefix: str, table: str, col: str) -> str:
    for _ in range(20):
        i = f"{prefix}-{secrets.token_hex(3).upper()}"
        if not con.execute(f"SELECT 1 FROM {table} WHERE {col}=?", (i,)).fetchone():
            return i
    raise RuntimeError("could not allocate an id")


def _max_tier(tiers: List[str]) -> str:
    return max(tiers, key=lambda t: TIER_ORDER[t]) if tiers else "A"


def parse_intent(intent: Any) -> Dict[str, Any]:
    """Accepts a dict, a list of intents, or a short phrase (single or ';'-separated batch):
      'review' | 'rebalance' | 'review_pending' | 'auto' -> re-evaluate open orders and inventory
      'exit SNEK' / 'sell SNEK'                          -> list/reprice the SNEK position at the policy exit price
      'buy SNEK 50' [@ 0.0034] [strategy S2_shock_fade]
      'buy 50 [ADA] [of] SNEK [@|at 0.0034]'
      'buy NIGHT 12 @ 0.095; buy IAG 10 @ 0.21'          -> multi-leg batch plan under one P-XXXXXX ID
      'reclaim <order_id>'                               -> pull a resting order
      'reprice <order_id> [to|@] <price>'                -> reprice a resting order
      'move <order_id> to NIGHT [60]'                    -> reclaim, then buy NIGHT
      'unlock S2_shock_fade'                             -> strategy simulated -> live (Tier B)
    """
    if isinstance(intent, list):
        sub = [parse_intent(x) for x in intent if x]
        if len(sub) == 1:
            return sub[0]
        return {"kind": "batch", "orders": sub}
    if isinstance(intent, dict):
        d = dict(intent)
        if isinstance(d.get("orders") or d.get("actions"), list):
            raw_list = d.get("orders") or d.get("actions") or []
            sub = [parse_intent(x) for x in raw_list if x]
            if len(sub) == 1:
                return sub[0]
            return {"kind": "batch", "orders": sub}
        if "kind" not in d:
            if d.get("ada") and not d.get("budget_ada"):
                d["budget_ada"] = d["ada"]
            d["kind"] = "buy" if d.get("budget_ada") else ("exit" if d.get("asset") else "review_pending")
        elif d["kind"] in ("place_buy",):
            d["kind"] = "buy"
            if d.get("ada") and not d.get("budget_ada"):
                d["budget_ada"] = d["ada"]
        elif d["kind"] in ("auto", "review", "rebalance"):
            d["kind"] = "review_pending"
        if d.get("asset"):
            d["asset"] = str(d["asset"]).upper()
        return d
    s = str(intent or "").strip()
    if ";" in s:
        parts = [p.strip() for p in s.split(";") if p.strip()]
        if len(parts) > 1:
            return {"kind": "batch", "orders": [parse_intent(p) for p in parts]}
    toks = s.split()
    if not toks or toks[0].lower() in ("review", "rebalance", "review_pending", "auto"):
        return {"kind": "review_pending"}
    k = toks[0].lower()
    if k in ("exit", "sell") and len(toks) >= 2:
        asset_tok = toks[-1].upper() if toks[1].lower() in ("all", "position") and len(toks) >= 3 else toks[1].upper()
        return {"kind": "exit", "asset": asset_tok}
    if k == "buy" and len(toks) >= 3:
        # Support both 'buy SNEK 50 [@ 0.0034]' and 'buy 50 [ADA] [of] SNEK [@|at 0.0034]'
        m_nat = re.match(
            r"^buy\s+([0-9]+(?:\.[0-9]+)?)\s*(?:ada\s+)?(?:of\s+)?([A-Za-z0-9]{2,12})(?:\s+(?:@|at)\s*([0-9]+(?:\.[0-9]+)?))?(?:\s+strategy\s+(\S+))?",
            s, re.IGNORECASE
        )
        if m_nat:
            d: Dict[str, Any] = {
                "kind": "buy",
                "asset": m_nat.group(2).upper(),
                "budget_ada": float(m_nat.group(1)),
                "strategy": m_nat.group(4) or "manual",
            }
            if m_nat.group(3):
                d["price"] = float(m_nat.group(3))
            return d
        budget_tok = re.sub(r"(?i)ada$", "", toks[2])
        d = {"kind": "buy", "asset": toks[1].upper(), "budget_ada": float(budget_tok), "strategy": "manual"}
        for marker in ("@", "at"):
            if marker in [t.lower() for t in toks]:
                idx = [t.lower() for t in toks].index(marker)
                if idx + 1 < len(toks):
                    d["price"] = float(toks[idx + 1])
                break
        if "strategy" in [t.lower() for t in toks]:
            idx = [t.lower() for t in toks].index("strategy")
            if idx + 1 < len(toks):
                d["strategy"] = toks[idx + 1]
        return d
    if k == "reclaim":
        if len(toks) == 1 or toks[1].lower() in ("stale", "all", "expired"):
            return {"kind": "review_pending", "scope": "buys"}
        return {"kind": "reclaim", "order_id": toks[1]}
    if k == "reprice" and len(toks) >= 3:
        price_tok = toks[-1]
        return {"kind": "reprice", "order_id": toks[1], "price": float(price_tok)}
    if k == "move" and len(toks) >= 4 and toks[2].lower() == "to":
        d = {"kind": "move", "order_id": toks[1], "asset": toks[3].upper()}
        if len(toks) >= 5:
            d["budget_ada"] = float(re.sub(r"(?i)ada$", "", toks[4]))
        return d
    if k in ("unlock",) and len(toks) >= 2:
        return {"kind": "unlock", "strategy": toks[1]}
    if k in ("send", "transfer", "wallet_send") and len(toks) >= 3:
        # Format: "send 25 [ADA|SNEK|POL|USDC] to <addr> [memo <msg>]" or "send <addr> 25 [ADA]"
        m_send = re.match(
            r"^(?:send|transfer|wallet_send)\s+([0-9]+(?:\.[0-9]+)?)\s*([A-Za-z0-9._-]{2,12})?\s+(?:to\s+)?(\S+)(?:\s+(?:memo|message)\s+(.+))?$",
            s, re.IGNORECASE
        )
        if m_send:
            amt = float(m_send.group(1))
            tok = (m_send.group(2) or "ADA").upper()
            to_addr = m_send.group(3)
            msg = (m_send.group(4) or "").strip() or None
            chain = "polygon" if (to_addr.startswith("0x") or tok in ("POL", "MATIC", "USDC", "USDC.E")) else (
                "ethereum" if tok == "ETH" else "cardano"
            )
            return {"kind": "wallet_send", "to": to_addr, "amount": amt, "token": tok, "chain": chain, "message": msg}
    raise ValueError(f"unrecognised intent {s!r}")


# ---------------------------------------------------------------------------
# Action builders
# ---------------------------------------------------------------------------

def _buy_action(asset: str, budget: float, strategy: str, pol, port, market, price: Optional[float] = None,
                reason: str = "") -> Dict[str, Any]:
    m = market.get(asset) or {}
    a: Dict[str, Any] = {"type": "place_buy", "asset": asset, "strategy": strategy, "side": "buy", "reason": reason}
    spot, s24 = m.get("spot"), m.get("sigma_24h")
    if not spot or not s24:
        a.update({"blocked": True, "checks": [f"{asset}: spot or sigma_24h unavailable (fail closed)"]})
        return a
    fv = m.get("fair_value")
    off = float(pol["strategies"].get("S2_shock_fade", {}).get("entry_offset_sigma", 0.25))
    if price is None:
        base = min(spot, fv) if fv else spot
        price = base * math.exp(-off * s24)
    cap = policy.max_buy_ada(asset, pol, port, market)
    ada = min(float(budget), cap) if cap > 0 else float(budget)
    fee = _fee(m, pol)
    trigger = price * (1 - fee)
    d = math.log(spot / trigger)
    fixed = _round_trip_fixed(pol)
    a.update({"price": price, "ada": round(ada, 6), "tokens": ada / price, "spot": spot, "fair_value": fv,
              "pool_fee_pct": fee * 100, "fills_when_spot_below": trigger,
              "distance_sigma_24h": d / s24, "p_fill_24h_model": touch_probability(d, s24),
              "round_trip_fixed_fees_ada": fixed,
              "breakeven_gain_pct": (fixed / ada * 100 + 2 * fee * 100) if ada > 0 else None,
              "budget_ada": budget, "max_allowed_ada": round(cap, 2)})
    if fv:
        a["ev_if_filled_ada"] = (ada / price) * fv * (1 - fee) - ada - fixed
        a["ev_model"] = m.get("fair_value_model")
    return a


def _sell_target(asset: str, pos: Dict[str, Any], pol, m) -> Optional[Dict[str, Any]]:
    tokens = pos.get("tokens_db") or pos.get("tokens")
    if pos.get("cost_ada") is None or not tokens:
        return None
    return policy.exit_price(pos["cost_ada"], min(pos.get("tokens") or tokens, tokens), pos.get("age_s") or 0.0,
                             m.get("fair_value"), pol)


def _sell_odds(a: Dict[str, Any], m: Dict[str, Any], pol) -> None:
    spot, s24 = m.get("spot"), m.get("sigma_24h")
    if spot and a.get("price"):
        trig = a["price"] / (1 - _fee(m, pol))
        a["fills_when_spot_above"] = trig
        a["p_fill_24h_model"] = touch_probability(math.log(trig / spot), s24)
        a["premium_to_spot_pct"] = (a["price"] / spot - 1) * 100


def _exit_actions(asset: str, pol, port, market, force: bool = False,
                  parent_order_id: Optional[str] = None) -> Tuple[List[Dict[str, Any]], List[str]]:
    notes: List[str] = []
    m = market.get(asset) or {}
    pos = (port.get("positions") or {}).get(asset)
    open_sells = [o for o in port.get("open_orders", []) if o["asset"] == asset and o["side"] == "sell"
                  and o.get("chain_status") in ("OPEN", "EXPIRED", None)]
    if not pos and not open_sells:
        return [], [f"{asset}: no position"]
    tgt = _sell_target(asset, pos or {}, pol, m)
    acts: List[Dict[str, Any]] = []
    for o in open_sells:
        if not tgt:
            notes.append(f"{asset}: open sell {o['order_id']} but no cost basis on record; leaving it")
            continue
        if not o.get("price") or not o.get("utxo"):
            notes.append(f"{asset}: open sell {o['order_id']} missing price/utxo; leaving it")
            continue
        move = abs(math.log(tgt["price"] / o["price"]))
        age = time.time() - (o.get("created_at") or 0)
        s24 = m.get("sigma_24h") or 0
        if not force and (move < max(REPRICE_MIN_LOG, 0.25 * s24) or age < REPRICE_MIN_AGE_S):
            notes.append(f"{asset}: sell at {o['price']:.6g} vs policy exit {tgt['price']:.6g} "
                         f"({move * 100:.2f}% apart, order age {age / 3600:.1f} h): no reprice needed")
            continue
        a = {"type": "reprice", "asset": asset, "side": "sell", "old_side": "sell", "order_id": o["order_id"],
             "utxo": o["utxo"], "old_price": o["price"], "price": tgt["price"], "tokens": o["tokens"],
             "old_tokens": o["tokens"], "strategy": "S1_inventory_exit", "exit_pricing": tgt,
             "reason": f"policy exit price {tgt['binding']}"}
        _sell_odds(a, m, pol)
        acts.append(a)
    free = (port.get("wallet_tokens") or {}).get(asset, 0.0)
    if free > 0 and not open_sells:
        price = tgt["price"] if tgt else max(m.get("spot") or 0, m.get("fair_value") or 0)
        if not price:
            return acts, notes + [f"{asset}: no price for an exit"]
        tokens = min(free, pos.get("tokens_db") or free) if (tgt and pos.get("tokens_db")) else free
        parent = parent_order_id or ((pos or {}).get("order_ids", [None])[0] if (pos or {}).get("order_ids") else None)
        a = {"type": "place_sell", "asset": asset, "side": "sell", "tokens": tokens, "price": price,
             "strategy": "S1_inventory_exit", "parent_order_id": parent, "exit_pricing": tgt,
             "reason": "list held inventory at the policy exit price" if tgt else
                       "no cost basis on record: priced at max(spot, fair value); needs your confirmation"}
        _sell_odds(a, m, pol)
        acts.append(a)
    return acts, notes


def _reclaim_action(o: Dict[str, Any], reason: str, tier_floor: Optional[str] = None) -> Dict[str, Any]:
    a = {"type": "reclaim", "order_id": o["order_id"], "utxo": o["utxo"], "asset": o["asset"], "side": o["side"],
         "price": o.get("price"), "reason": reason}
    if tier_floor:
        a["tier_floor"] = tier_floor
    return a


def _review_actions(pol, port, market, scope: str = "all") -> Tuple[List[Dict[str, Any]], List[str]]:
    acts: List[Dict[str, Any]] = []
    notes: List[str] = []
    inv = pol["inventory"]
    for o in port.get("open_orders", []):
        m = market.get(o["asset"]) or {}
        cs = o.get("chain_status")
        if cs not in ("OPEN", "EXPIRED"):
            notes.append(f"{o['order_id']}: chain status {cs}; the order watcher will reconcile")
            continue
        if cs == "EXPIRED" and o.get("utxo"):
            acts.append(_reclaim_action(o, "order expired on chain"))
            continue
        if o["side"] == "buy" and scope in ("all", "buys"):
            spot, s24 = m.get("spot"), m.get("sigma_24h")
            age_d = (time.time() - (o.get("created_at") or time.time())) / 86400
            dist = (math.log(spot / o["price"]) / s24) if (spot and s24 and o.get("price")) else None
            reasons = []
            if age_d >= inv["stuck_days"]:
                reasons.append(f"resting {age_d:.1f} days (>= {inv['stuck_days']})")
            if dist is not None and dist > 3.0:
                reasons.append(f"{dist:.1f} sigma_24h below spot: unlikely to fill")
            legacy = not o.get("plan_id")
            if reasons:
                acts.append(_reclaim_action(o, "; ".join(reasons)))
            elif legacy:
                p = touch_probability(math.log(spot / (o["price"] * (1 - _fee(m, pol)))), s24) if (spot and s24) else None
                acts.append(_reclaim_action(
                    o, f"legacy order placed before the policy engine (bid-ladder strategy is now disabled); "
                       f"{(dist or 0):.1f} sigma_24h below spot, model P(fill 24h) "
                       f"{('%.0f%%' % (p * 100)) if p is not None else 'n/a'}. Keep it, or reclaim and redeploy?",
                    tier_floor="B"))
            else:
                notes.append(f"{o['order_id']}: buy at {o['price']:.6g} fits the rules; keep")
    if scope in ("all", "sells"):
        for asset in sorted((port.get("positions") or {}).keys()):
            a2, n2 = _exit_actions(asset, pol, port, market)
            acts.extend(a2)
            notes.extend(n2)
            pos = port["positions"][asset]
            m = market.get(asset) or {}
            if pos.get("cost_ada") and pos.get("tokens_db") and m.get("spot") and m.get("sigma_24h"):
                per = pos["cost_ada"] / pos["tokens_db"]
                z = math.log(m["spot"] / per) / m["sigma_24h"]
                age_d = (pos.get("age_s") or 0) / 86400
                if age_d >= inv["stuck_days"] or z <= -inv["stuck_sigma_24h"]:
                    notes.append(f"STUCK {asset}: {age_d:.1f} days, spot {z:+.1f} sigma_24h vs cost. No automatic "
                                 "stop-loss or averaging down: your call (hold, re-list lower, or exit at a loss).")
    return acts, notes


# ---------------------------------------------------------------------------
# Plan building
# ---------------------------------------------------------------------------

def _context(pol, assets: List[str], check_chain: bool = True) -> Tuple[Dict[str, Any], Dict[str, Dict[str, Any]]]:
    market = {a: MARKET(a) for a in assets}
    port = SNAPSHOT(pol, market=market, check_chain=check_chain)
    market.update(port.get("_market") or {})
    return port, market


def _finalise(con, actions: List[Dict[str, Any]], pol, port, market) -> None:
    for a in actions:
        if a.get("blocked"):
            a.setdefault("tier", "-")
            continue
        tier, why = policy.classify(a, pol, port, market)
        if a.get("tier_floor") and TIER_ORDER[a["tier_floor"]] > TIER_ORDER[tier]:
            tier, why = a["tier_floor"], why + ["operator decision requested"]
        cc = policy.capital_check(a, pol, port, market)
        if cc["breach_floor"]:
            tier = "C"
        a["tier"] = tier
        a["tier_reasons"] = why
        a["checks"] = cc["failures"]
        a["blocked"] = (not cc["ok"]) or tier == "C"
        if a.get("strategy"):
            a["strategy_state"] = policy.strategy_state(con, pol, a["strategy"])
            if a["strategy_state"] == "disabled":
                a["blocked"] = True
                a["checks"].append(f"strategy {a['strategy']} is disabled")


def build_plan(intent: Any, origin: str = "george", con=None, pol=None) -> Dict[str, Any]:
    pol = pol or policy.load_policy()
    own = con is None
    con = con or store.connect()
    try:
        it = parse_intent(intent)
        kind = it["kind"]
        assets: List[str] = []
        if it.get("asset"):
            assets.append(it["asset"])
        if kind == "batch":
            for sub in it.get("orders") or []:
                if sub.get("asset") and sub["asset"] not in assets:
                    assets.append(sub["asset"])
        for a_sym in assets:
            if not ASSET_RE.match(a_sym):
                raise ValueError(f"invalid asset {a_sym!r}")
        port, market = _context(pol, assets)
        actions: List[Dict[str, Any]] = []
        notes: List[str] = []
        if kind == "review_pending":
            actions, notes = _review_actions(pol, port, market, it.get("scope", "all"))
        elif kind == "exit":
            actions, notes = _exit_actions(it["asset"], pol, port, market, force=bool(it.get("force")),
                                           parent_order_id=it.get("parent_order_id"))
        elif kind == "buy":
            strat = it.get("strategy") or "manual"
            if strat not in pol["strategies"]:
                raise ValueError(f"unknown strategy {strat!r}")
            actions = [_buy_action(it["asset"], float(it["budget_ada"]), strat, pol, port, market, it.get("price"),
                                   it.get("reason", ""))]
        elif kind == "batch":
            port_running = dict(port)
            port_running["exposure_ada"] = dict(port.get("exposure_ada") or {})
            for sub in it.get("orders") or []:
                sk = sub.get("kind")
                if sk == "buy":
                    strat = sub.get("strategy") or "manual"
                    if strat not in pol["strategies"]:
                        raise ValueError(f"unknown strategy {strat!r}")
                    b = _buy_action(sub["asset"], float(sub["budget_ada"]), strat, pol, port_running, market,
                                    sub.get("price"), sub.get("reason", ""))
                    _finalise(con, [b], pol, port_running, market)
                    b["_prechecked"] = True
                    if not b.get("blocked") and port_running.get("wallet_ada") is not None:
                        used_ada = float(b.get("ada") or 0.0)
                        f = pol["fees"]
                        outflow = used_ada + f["order_deposit_ada"] + f["max_batcher_fee_ada"] + f["network_fee_ada"]
                        port_running["wallet_ada"] = max(0.0, float(port_running["wallet_ada"]) - outflow)
                        if port_running.get("free_ada") is not None:
                            port_running["free_ada"] = max(0.0, float(port_running["free_ada"]) - outflow)
                        exp = dict(port_running.get("exposure_ada") or {})
                        exp[sub["asset"]] = exp.get(sub["asset"], 0.0) + used_ada
                        port_running["exposure_ada"] = exp
                    actions.append(b)
                elif sk == "exit":
                    a2, n2 = _exit_actions(sub["asset"], pol, port_running, market, force=bool(sub.get("force")))
                    actions.extend(a2)
                    notes.extend(n2)
                elif sk == "reclaim":
                    o = next((o for o in port_running.get("open_orders", []) if o["order_id"] == sub.get("order_id")), None)
                    if not o or not o.get("utxo"):
                        raise ValueError(f"no open order {sub.get('order_id')!r}")
                    actions.append(_reclaim_action(o, sub.get("reason") or "operator batch request"))
                else:
                    raise ValueError(f"unsupported batch sub-intent {sk!r}")
        elif kind == "reprice":
            o = next((o for o in port.get("open_orders", []) if o["order_id"] == it.get("order_id")), None)
            if not o or not o.get("utxo"):
                raise ValueError(f"no open order {it.get('order_id')!r}")
            new_p = float(it["price"])
            m = market.get(o["asset"]) or _context(pol, [o["asset"]])[1].get(o["asset"]) or {}
            market[o["asset"]] = m
            a = {"type": "reprice", "asset": o["asset"], "side": o["side"], "old_side": o["side"],
                 "order_id": o["order_id"], "utxo": o["utxo"], "old_price": o["price"], "price": new_p,
                 "tokens": o["tokens"], "old_tokens": o["tokens"], "ada": o.get("ada"),
                 "strategy": "S1_inventory_exit" if o["side"] == "sell" else "manual",
                 "reason": it.get("reason") or "reprice resting order"}
            if o["side"] == "sell":
                _sell_odds(a, m, pol)
            actions = [a]
        elif kind in ("reclaim", "move"):
            o = next((o for o in port.get("open_orders", []) if o["order_id"] == it.get("order_id")), None)
            if not o or not o.get("utxo"):
                raise ValueError(f"no open order {it.get('order_id')!r}")
            actions = [_reclaim_action(o, it.get("reason") or ("operator request" if kind == "reclaim" else f"move capital to {it['asset']}"))]
            if kind == "move":
                budget = float(it.get("budget_ada") or o.get("ada") or 0)
                b = _buy_action(it["asset"], budget, it.get("strategy") or "manual", pol, port, market,
                                reason=f"redeploy capital from {o['order_id']}")
                # The reclaim returns the order's ADA first: credit it for the capital check.
                port2 = dict(port)
                if o["side"] == "buy" and port.get("wallet_ada") is not None:
                    port2["wallet_ada"] = port["wallet_ada"] + float(o.get("ada") or 0)
                    exp = dict(port.get("exposure_ada") or {})
                    exp[o["asset"]] = max(0.0, exp.get(o["asset"], 0.0) - float(o.get("ada") or 0))
                    port2["exposure_ada"] = exp
                _finalise(con, [b], pol, port2, market)
                b["_prechecked"] = True
                actions.append(b)
        elif kind == "unlock":
            s = it.get("strategy")
            if s not in pol["strategies"]:
                raise ValueError(f"unknown strategy {s!r}")
            actions = [{"type": "strategy_unlock", "strategy": s, "to_state": "live",
                        "current_state": policy.strategy_state(con, pol, s), "reason": it.get("reason", "")}]
            try:
                from lib.tools.trading import gates
                if s in gates.GATED:
                    g1 = gates.gate1(con, pol, s)
                    actions[0]["gate1_ready"] = g1["ready"]
                    actions[0]["gate1_failing"] = [k for k, c in g1["checks"].items() if not c["ok"]]
                    if not g1["ready"]:
                        notes.append(f"Gate 1 has NOT passed for {s} (failing: {', '.join(actions[0]['gate1_failing'])}); "
                                     "unlocking anyway is your call.")
            except Exception:
                pass
        elif kind == "standing_order":
            s = it.get("strategy") or "manual"
            if s not in pol["strategies"] or not it.get("asset") or not it.get("max_ada"):
                raise ValueError("standing_order needs strategy, asset and max_ada")
            hours = float(it.get("expires_hours") or 72)
            actions = [{"type": "standing_order_create", "strategy": s, "asset": it["asset"], "side": "buy",
                        "max_ada": float(it["max_ada"]), "price_min": it.get("price_min"),
                        "price_max": it.get("price_max"), "expires_at": int(time.time() + hours * 3600),
                        "reason": it.get("reason", "")}]
        elif kind == "wallet_send":
            to_addr = str(it.get("to") or "").strip()
            amount = float(it.get("amount") or 0.0)
            token = str(it.get("token") or "ADA").upper()
            chain = str(it.get("chain") or ("polygon" if to_addr.startswith("0x") else "cardano")).lower()
            if not to_addr or amount <= 0:
                raise ValueError("wallet_send needs destination address ('to') and positive 'amount'")
            ada_outflow = amount if (chain in ("cardano", "ada") and token == "ADA") else (
                1.5 if chain in ("cardano", "ada") else 0.0
            )
            actions = [{
                "type": "wallet_send",
                "chain": chain,
                "wallet_id": it.get("wallet_id"),
                "to": to_addr,
                "amount": amount,
                "token": token,
                "ada": ada_outflow,
                "message": it.get("message"),
                "reason": it.get("reason") or "operator-confirmed wallet transfer",
            }]
        else:
            raise ValueError(f"unknown intent kind {kind!r}")

        pre = [a for a in actions if a.pop("_prechecked", False)]
        _finalise(con, [a for a in actions if a not in pre], pol, port, market)
        live_tiers = [a["tier"] for a in actions if not a.get("blocked")]
        now = int(time.time())
        refs = {}
        for a in actions:
            m = market.get(a.get("asset") or "") or {}
            if a.get("asset") and a["type"] in PRICE_ACTIONS:
                refs[a["asset"]] = {"spot": m.get("spot"), "sigma_1h": m.get("sigma_1h"), "spot_source": m.get("spot_source")}
        plan = {"plan_id": _new_id(con, "P", "plans", "plan_id"), "created_at": now,
                "expires_at": now + int(pol["plans"]["ttl_s"]), "origin": origin, "intent": it,
                "actions": actions, "refs": refs}
        plan["plan_hash"] = plan_hash(plan)
        plan["tier"] = _max_tier(live_tiers) if live_tiers else "-"
        plan["status"] = "proposed" if live_tiers else ("blocked" if actions else "noop")
        plan["notes"] = notes + port.get("warnings", [])
        plan["execution_mode"] = "live" if policy.live_execution_enabled(pol) else "dry_run (execution.live=false or test mode)"
        plan["frozen"] = bool(policy.is_frozen(con))
        plan["summary"] = summarize(plan)
        con.execute("INSERT INTO plans(plan_id, created_at, expires_at, origin, intent_json, actions_json, refs_json,"
                    " plan_hash, tier, status, summary) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                    (plan["plan_id"], now, plan["expires_at"], origin, json.dumps(it, sort_keys=True, default=str),
                     json.dumps(actions, sort_keys=True, default=str), json.dumps(refs, sort_keys=True, default=str),
                     plan["plan_hash"], plan["tier"], plan["status"], plan["summary"]))
        store.log_event(con, "plan_built", {"plan_id": plan["plan_id"], "origin": origin, "tier": plan["tier"],
                                            "status": plan["status"]})
        con.commit()
        plan["how_to_execute"] = _how_to(plan)
        return plan
    finally:
        if own:
            con.close()


def _fmt_action(a: Dict[str, Any]) -> str:
    t = a["type"]
    st = "BLOCKED " if a.get("blocked") else f"[{a.get('tier')}] "
    if t == "place_buy":
        s = f"{st}BUY {a['asset']} {a.get('ada', 0):.1f} ADA @ {a.get('price', 0):.6g}"
    elif t == "place_sell":
        s = f"{st}SELL {a.get('tokens', 0):,.2f} {a['asset']} @ {a.get('price', 0):.6g}"
    elif t == "reprice":
        s = f"{st}REPRICE {a['side']} {a['asset']} {a['old_price']:.6g} -> {a['price']:.6g}"
    elif t == "reclaim":
        s = f"{st}RECLAIM {a['side']} {a['asset']} order {a['order_id']}"
    elif t == "strategy_unlock":
        s = f"{st}UNLOCK {a['strategy']} -> live"
    elif t == "standing_order_create":
        s = f"{st}STANDING ORDER {a['strategy']} {a['asset']} up to {a['max_ada']:.0f} ADA"
    elif t == "wallet_send":
        s = f"{st}SEND {a.get('amount', 0):g} {a.get('token', 'ADA')} -> {a.get('to', '')[:24]}... ({a.get('chain', 'cardano')})"
    else:
        s = f"{st}{t}"
    if a.get("checks"):
        s += " (" + "; ".join(a["checks"]) + ")"
    return s


def summarize(plan: Dict[str, Any]) -> str:
    lines = [f"{plan['plan_id']} tier {plan['tier']} ({plan['status']}), expires in "
             f"{max(0, plan['expires_at'] - int(time.time())) // 60} min"]
    lines += ["  " + _fmt_action(a) for a in plan["actions"]]
    return "\n".join(lines)


def _how_to(plan: Dict[str, Any]) -> str:
    if plan["status"] != "proposed":
        return "Nothing executable in this plan."
    if plan["tier"] == "A":
        return f"Tier A: George may run crypto_execute(plan_id='{plan['plan_id']}') now (report it after)."
    return (f"Tier B: needs the operator. Ask them to reply 'confirm {plan['plan_id']}' within "
            f"{(plan['expires_at'] - int(time.time())) // 60} minutes (Discord) or press Confirm in the web desk. "
            "Do NOT call crypto_execute yourself for Tier B: it will be refused without the operator's token.")


# ---------------------------------------------------------------------------
# Confirm tokens + standing orders
# ---------------------------------------------------------------------------

def _th(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def mint_token(con, plan_id: str, via: str, evidence: str) -> str:
    """Only the operator paths call this (Discord reply verified against the Discord API, or the web
    desk with the server-side secret). The raw token is never stored, shown to George or logged."""
    r = con.execute("SELECT plan_hash, expires_at, status FROM plans WHERE plan_id=?", (plan_id,)).fetchone()
    if not r:
        raise ValueError("unknown plan")
    if r["status"] != "proposed":
        raise ValueError(f"plan is {r['status']}")
    if int(time.time()) > r["expires_at"]:
        raise ValueError("plan expired")
    if con.execute("SELECT 1 FROM confirm_tokens WHERE evidence=?", (evidence,)).fetchone():
        raise ValueError("this confirmation was already used")
    tok = secrets.token_urlsafe(24)
    con.execute("INSERT INTO confirm_tokens VALUES (?,?,?,?,?,NULL,?,?)",
                (_th(tok), plan_id, r["plan_hash"], int(time.time()), r["expires_at"], via, evidence))
    store.log_event(con, "token_minted", {"plan_id": plan_id, "via": via})
    con.commit()
    return tok


def consume_token(con, plan_id: str, plan_hash_: str, token: Optional[str]) -> bool:
    if not token:
        return False
    cur = con.execute("UPDATE confirm_tokens SET used_at=? WHERE token_hash=? AND plan_id=? AND plan_hash=? "
                      "AND used_at IS NULL AND expires_at>=?",
                      (int(time.time()), _th(token), plan_id, plan_hash_, int(time.time())))
    con.commit()
    return cur.rowcount == 1


def standing_cover(con, a: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    if a.get("type") != "place_buy":
        return None
    now = int(time.time())
    for r in con.execute("SELECT * FROM standing_orders WHERE status='active' AND expires_at>? AND asset=? AND strategy=? "
                         "AND side='buy'", (now, a["asset"], a.get("strategy"))):
        if r["used_ada"] + float(a.get("ada", 0)) > r["max_ada"] + 1e-9:
            continue
        if r["price_min"] is not None and a["price"] < r["price_min"]:
            continue
        if r["price_max"] is not None and a["price"] > r["price_max"]:
            continue
        return dict(r)
    return None


def standing_orders(con, include_inactive: bool = False) -> List[Dict[str, Any]]:
    q = "SELECT * FROM standing_orders" + ("" if include_inactive else " WHERE status='active' AND expires_at>?")
    args = () if include_inactive else (int(time.time()),)
    return [dict(r) for r in con.execute(q + " ORDER BY created_at DESC", args)]


def revoke_standing_order(con, so_id: str, by: str) -> bool:
    if not SO_RE.match(so_id or ""):
        raise ValueError("invalid standing order id")
    cur = con.execute("UPDATE standing_orders SET status='revoked' WHERE so_id=? AND status='active'", (so_id,))
    store.log_event(con, "standing_order_revoked", {"so_id": so_id, "by": by})
    con.commit()
    return cur.rowcount == 1


# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------

def get_plan(con, plan_id: str) -> Optional[Dict[str, Any]]:
    r = con.execute("SELECT * FROM plans WHERE plan_id=?", (plan_id,)).fetchone()
    if not r:
        return None
    p = dict(r)
    p["intent"] = json.loads(p.pop("intent_json"))
    p["actions"] = json.loads(p.pop("actions_json"))
    p["refs"] = json.loads(p.pop("refs_json"))
    p["result"] = json.loads(p.pop("result_json")) if p.get("result_json") else None
    return p


def refresh_plan_ttl(con, plan_id: str, pol=None) -> Optional[Dict[str, Any]]:
    """Refreshes a proposed plan's 10-minute TTL at presentation/delivery time so the operator
    always gets a full TTL window from when the message is actually delivered to Discord."""
    pol = pol or policy.load_policy()
    p = get_plan(con, (plan_id or "").upper())
    if not p or p.get("status") != "proposed":
        return None
    now = int(time.time())
    # Only refresh plans built within the last 30 minutes
    if now - int(p.get("created_at") or 0) > 1800:
        return None
    new_exp = max(int(p["expires_at"]), now + int(pol["plans"]["ttl_s"]))
    p["expires_at"] = new_exp
    p["plan_hash"] = plan_hash(p)
    p["summary"] = summarize(p)
    con.execute("UPDATE plans SET expires_at=?, plan_hash=?, summary=? WHERE plan_id=? AND status='proposed'",
                (p["expires_at"], p["plan_hash"], p["summary"], p["plan_id"]))
    con.commit()
    return p


def refresh_plans_in_text(text: str, con=None, pol=None) -> List[str]:
    ids = sorted({m.upper() for m in re.findall(r"\bP-[0-9A-Fa-f]{6}\b", text or "")})
    if not ids:
        return []
    pol = pol or policy.load_policy()
    own = con is None
    con = con or store.connect()
    refreshed: List[str] = []
    try:
        for pid in ids:
            if refresh_plan_ttl(con, pid, pol=pol):
                refreshed.append(pid)
        return refreshed
    finally:
        if own:
            con.close()


def list_plans(con, status: Optional[str] = None, limit: int = 20) -> List[Dict[str, Any]]:
    now = int(time.time())
    con.execute("UPDATE plans SET status='expired' WHERE status='proposed' AND expires_at<?", (now,))
    con.commit()
    q = "SELECT plan_id, created_at, expires_at, origin, tier, status, summary, executed_at FROM plans"
    args: List[Any] = []
    if status:
        q += " WHERE status=?"
        args.append(status)
    return [dict(r) for r in con.execute(q + " ORDER BY created_at DESC LIMIT ?", args + [limit])]


def _freshness(p: Dict[str, Any], pol) -> Tuple[bool, List[str]]:
    lim = float(pol["plans"]["max_move_sigma"])
    why: List[str] = []
    for asset, ref in (p.get("refs") or {}).items():
        m = MARKET(asset, use_cache=False)
        spot, s1 = m.get("spot"), ref.get("sigma_1h") or m.get("sigma_1h")
        if not spot or not ref.get("spot") or not s1:
            why.append(f"{asset}: spot/sigma unavailable now: cannot verify the plan is still fresh")
            continue
        mv = abs(math.log(spot / ref["spot"]))
        if mv > lim * s1:
            why.append(f"{asset}: spot moved {mv * 100:.2f}% (> {lim} sigma_1h = {lim * s1 * 100:.2f}%) since the plan")
    return (not why), why


def _strategy_for(a: Dict[str, Any]) -> str:
    return a.get("strategy") or ("S1_inventory_exit" if a.get("side") == "sell" else "manual")


def _record_sim(con, a: Dict[str, Any], plan_id: str, m: Dict[str, Any]) -> str:
    sid = f"SIM-{secrets.token_hex(4).upper()}"
    ada = float(a.get("ada") or (a.get("tokens", 0) * a.get("price", 0)))
    con.execute("INSERT INTO sim_trades(sim_id, strategy, asset, created_at, signal_json, side, entry_price, size_ada,"
                " exit_target, timeout_at, status, note) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                (sid, _strategy_for(a), a["asset"], int(time.time()), json.dumps({"plan_id": plan_id, "action": a},
                                                                                 default=str),
                 a.get("side", "buy"), float(a["price"]), ada, m.get("fair_value"), int(time.time() + 3 * 86400),
                 "resting", f"from plan {plan_id}"))
    con.commit()
    return sid


def _tag(tx_id: str, a: Dict[str, Any], plan_id: str) -> None:
    fields: Dict[str, Any] = {"plan_id": plan_id, "strategy": _strategy_for(a), "new_rules": 1}
    if a.get("side") == "sell":
        fields["sell_placed_at"] = int(time.time())
    try:
        TAG_ORDER(tx_id, fields)
    except Exception:
        pass


def _run_action(con, a: Dict[str, Any], pol, live: bool, actor: str, plan_id: str) -> Dict[str, Any]:
    t = a["type"]
    if t == "reclaim":
        r = RECLAIM(a["utxo"], execute=live, actor=actor, wait=False)
        return {"status": "ok" if r.get("status") == "ok" else "failed", "tx_id": r.get("tx_id"),
                "message": r.get("message"), "submitted": live and r.get("status") == "ok"}
    if t in ("place_buy", "place_sell"):
        side = "buy" if t == "place_buy" else "sell"
        r = PLACE(a["asset"], side, float(a["tokens"]), float(a["price"]), execute=live, actor=actor,
                  parent_order_id=a.get("parent_order_id"))
        res = {"status": "ok" if r.get("status") == "ok" else "failed", "tx_id": r.get("tx_id"),
               "message": r.get("message"), "submitted": live and r.get("status") == "ok"}
        if r.get("simulated"):
            res.update({"status": "failed" if live else "unvalidated",
                        "message": "builder could not build this order with the current wallet (insufficient funds)"})
            res["tx_id"] = None
        if res["submitted"] and r.get("tx_id"):
            _tag(r["tx_id"], a, plan_id)
        return res
    if t == "reprice":
        if a["side"] == "sell" and a.get("order_id"):
            CLAIM_SELL(a["order_id"])
        r1 = RECLAIM(a["utxo"], execute=live, actor=actor, wait=live)
        if r1.get("status") != "ok":
            return {"status": "failed", "stage": "reclaim", "message": r1.get("message")}
        if live and not (r1.get("verification") or {}).get("verified"):
            return {"status": "partial", "stage": "reclaim", "reclaim_tx": r1.get("tx_id"),
                    "message": "reclaim submitted but not yet verified; the order watcher returns the inventory to "
                               "INVENTORY_HOLD and S1 relists it at the policy price"}
        r2 = PLACE(a["asset"], a["side"], float(a["tokens"]), float(a["price"]), execute=live, actor=actor,
                   parent_order_id=a.get("order_id") if a["side"] == "sell" else None)
        ok = r2.get("status") == "ok" and not r2.get("simulated")
        if ok and live and r2.get("tx_id"):
            _tag(r2["tx_id"], a, plan_id)
        return {"status": "ok" if ok else ("unvalidated" if not live else "partial"), "reclaim_tx": r1.get("tx_id"),
                "tx_id": r2.get("tx_id") if ok else None, "message": r2.get("message"), "submitted": live and ok}
    if t == "standing_order_create":
        so = _new_id(con, "SO", "standing_orders", "so_id")
        con.execute("INSERT INTO standing_orders VALUES (?,?,?,?,?,?,?,0,?,?, 'active', ?, ?)",
                    (so, int(time.time()), a["expires_at"], a["strategy"], a["asset"], a.get("side", "buy"),
                     a["max_ada"], a.get("price_min"), a.get("price_max"), plan_id, a.get("reason")))
        con.commit()
        return {"status": "ok", "so_id": so}
    if t == "strategy_unlock":
        store.set_override(con, f"strategy:{a['strategy']}", a.get("to_state", "live"), by=f"plan:{plan_id}",
                           reason=a.get("reason") or "operator-confirmed unlock")
        return {"status": "ok", "state": policy.strategy_state(con, pol, a["strategy"])}
    if t == "wallet_send":
        from lib.tools.wallet import keystore as ks
        chain = str(a.get("chain") or "cardano").lower()
        tok = str(a.get("token") or "ADA").upper()
        amt = float(a.get("amount") or 0.0)
        wid = a.get("wallet_id")
        if chain in ("polygon", "pol", "ethereum", "eth", "evm"):
            res = ks.send_evm(
                wid, a["to"], amt,
                token=tok if tok not in ("ADA", "") else "POL",
                network="ethereum" if chain in ("ethereum", "eth") else "polygon",
                passphrase=None, execute=live, actor="operator",
            )
        else:
            res = ks.send_cardano(
                wid, a["to"],
                ada=amt if tok == "ADA" else 1.5,
                passphrase=None, execute=live, actor="operator",
                token=None if tok == "ADA" else tok,
                token_amount=0.0 if tok == "ADA" else amt,
                message=a.get("message"),
            )
        return {
            "status": "ok" if res.get("status") == "ok" else "failed",
            "tx_id": res.get("tx_id"),
            "submitted": bool(res.get("confirmed") or (live and res.get("status") == "ok")),
            "fee_ada": res.get("fee_ada"),
            "fee_native": res.get("fee_native"),
            "explorer": res.get("cardanoscan_url") or res.get("explorer_url"),
        }
    return {"status": "rejected", "message": f"unknown action {t}"}


def execute_plan(plan_id: str, confirm_token: Optional[str] = None, actor: str = "george", con=None,
                 pol=None) -> Dict[str, Any]:
    if not PLAN_RE.match(plan_id or ""):
        return {"status": "rejected", "reason": "invalid plan_id (expected P-XXXXXX from crypto_plan)"}
    pol = pol or policy.load_policy()
    own = con is None
    con = con or store.connect()
    try:
        p = get_plan(con, plan_id)
        if not p:
            return {"status": "rejected", "reason": "unknown plan_id: build one with crypto_plan first"}
        if p["status"] != "proposed":
            return {"status": "rejected", "reason": f"plan is {p['status']}", "result": p.get("result")}
        now = int(time.time())
        if now > p["expires_at"]:
            con.execute("UPDATE plans SET status='expired' WHERE plan_id=?", (plan_id,))
            con.commit()
            return {"status": "rejected", "reason": "plan expired (10 min TTL): build a fresh plan"}
        if plan_hash(p) != p["plan_hash"]:
            store.log_event(con, "plan_tampered", {"plan_id": plan_id})
            con.execute("UPDATE plans SET status='rejected' WHERE plan_id=?", (plan_id,))
            con.commit()
            return {"status": "rejected", "reason": "plan content does not match its hash"}
        needs_b = any(a.get("tier") == "B" and not a.get("blocked") for a in p["actions"])
        token_ok = consume_token(con, plan_id, p["plan_hash"], confirm_token) if confirm_token else False
        if confirm_token and not token_ok:
            return {"status": "rejected", "reason": "confirm token invalid, used, expired or for another plan"}
        if needs_b and not token_ok:
            uncovered = [_fmt_action(a) for a in p["actions"]
                         if a.get("tier") == "B" and not a.get("blocked") and not standing_cover(con, a)]
            if uncovered:
                return {"status": "needs_confirmation", "plan_id": plan_id,
                        "reason": f"Tier B: the operator must reply 'confirm {plan_id}' (Discord) or press Confirm in "
                                  "the web desk. Nothing was executed.", "uncovered_actions": uncovered,
                        "expires_in_s": p["expires_at"] - now}
        if any(a["type"] in PRICE_ACTIONS and not a.get("blocked") for a in p["actions"]):
            fresh, why = _freshness(p, pol)
            if not fresh:
                con.execute("UPDATE plans SET status='stale' WHERE plan_id=?", (plan_id,))
                con.commit()
                return {"status": "rejected", "reason": "plan is stale: " + "; ".join(why) + ". Build a fresh plan."}
        cur = con.execute("UPDATE plans SET status='executing' WHERE plan_id=? AND status='proposed'", (plan_id,))
        con.commit()
        if cur.rowcount != 1:
            return {"status": "rejected", "reason": "plan is already being executed"}

        live = policy.live_execution_enabled(pol)
        frozen = bool(policy.is_frozen(con))
        assets = sorted({a["asset"] for a in p["actions"] if a.get("asset")})
        mkt.clear_cache()
        port, market = _context(pol, assets)
        results: List[Dict[str, Any]] = []
        stop = False
        for a in p["actions"]:
            r: Dict[str, Any] = {"action": _fmt_action(a)}
            if stop:
                r.update({"status": "skipped", "message": "an earlier action failed"})
                results.append(r)
                continue
            if a.get("blocked"):
                r.update({"status": "skipped", "message": "blocked at plan time: " + "; ".join(a.get("checks") or [])})
                results.append(r)
                continue
            # Re-classify against fresh state.
            if a["type"] in ("reclaim", "place_buy", "place_sell", "reprice", "wallet_send"):
                tier, why = policy.classify(a, pol, port, market)
                if a.get("tier_floor") and TIER_ORDER[a["tier_floor"]] > TIER_ORDER[tier]:
                    tier = a["tier_floor"]
                cc = policy.capital_check(a, pol, port, market)
                if cc["breach_floor"] or tier == "C":
                    r.update({"status": "rejected", "message": "Tier C now: " + "; ".join(cc["failures"] or why)})
                    results.append(r)
                    stop = True
                    continue
                if not cc["ok"] and a["type"] != "reclaim":
                    r.update({"status": "rejected", "message": "capital check failed now: " + "; ".join(cc["failures"])})
                    results.append(r)
                    stop = True
                    continue
            else:
                tier = a.get("tier", "B")
            strat = _strategy_for(a) if a["type"] in PRICE_ACTIONS else None
            state = policy.strategy_state(con, pol, strat) if strat else "live"
            risk_reducing_sell = a.get("side") == "sell" and a["type"] in ("place_sell", "reprice")
            if frozen and risk_reducing_sell and state == "simulated" and \
                    pol["strategies"].get(strat, {}).get("state") == "live":
                tier, state = "B", "live"   # exits during a freeze: allowed, but only with your confirmation
            so = None
            if tier == "B":
                if not token_ok:
                    so = standing_cover(con, a)
                    if not so:
                        r.update({"status": "needs_confirmation",
                                  "message": f"Tier B: ask the operator to reply 'confirm {plan_id}'"})
                        results.append(r)
                        continue
            if state == "disabled":
                r.update({"status": "rejected", "message": f"strategy {strat} is disabled"})
                results.append(r)
                continue
            if state == "simulated":
                sid = _record_sim(con, a, plan_id, market.get(a["asset"]) or {})
                r.update({"status": "simulated", "sim_id": sid,
                          "message": f"strategy {strat} is simulated{' (drawdown freeze)' if frozen else ''}: "
                                     "journalled as a shadow trade, no transaction"})
                results.append(r)
                continue
            prev_tx = next((x.get("tx_id") for x in reversed(results) if x.get("submitted") and x.get("tx_id")), None)
            if prev_tx and live and PLACE is _place and a["type"] in ("reclaim", "place_buy", "place_sell", "reprice"):
                try:
                    from lib.tools.cardano_orders import bf_get
                    deadline = time.time() + 60
                    while time.time() < deadline:
                        if bf_get(f"/txs/{prev_tx}", allow_404=True):
                            break
                        time.sleep(3)
                except Exception:
                    pass
            try:
                out = _run_action(con, a, pol, live, actor, plan_id)
            except Exception as e:
                out = {"status": "failed", "message": f"{type(e).__name__}: {str(e)[:200]}"}
            r.update(out)
            if out.get("status") == "ok" and a["type"] == "place_buy" and port.get("wallet_ada") is not None:
                used_ada = float(a.get("ada") or 0.0)
                f = pol["fees"]
                outflow = used_ada + f["order_deposit_ada"] + f["max_batcher_fee_ada"] + f["network_fee_ada"]
                port["wallet_ada"] = max(0.0, float(port["wallet_ada"]) - outflow)
                exp = dict(port.get("exposure_ada") or {})
                exp[a["asset"]] = exp.get(a["asset"], 0.0) + used_ada
                port["exposure_ada"] = exp
            if so and out.get("status") == "ok":
                con.execute("UPDATE standing_orders SET used_ada = used_ada + ? WHERE so_id=?",
                            (float(a.get("ada", 0)), so["so_id"]))
                con.commit()
                r["standing_order"] = so["so_id"]
            if not live and out.get("status") in ("ok", "unvalidated") and a["type"] in ("reclaim", "place_buy", "place_sell", "reprice", "wallet_send"):
                r["dry_run"] = True
            results.append(r)
            if out.get("status") not in ("ok", "unvalidated"):
                stop = True
        sts = {r["status"] for r in results}
        if sts <= {"ok", "simulated", "skipped", "unvalidated"} and sts & {"ok", "simulated", "unvalidated"}:
            final = "executed"
        elif sts & {"ok", "simulated", "partial"}:
            final = "partially_executed"
        elif sts == {"needs_confirmation"} or sts == {"needs_confirmation", "skipped"}:
            final = "proposed"   # nothing ran: the plan stays confirmable until it expires
        else:
            final = "failed"
        con.execute("UPDATE plans SET status=?, result_json=?, executed_at=? WHERE plan_id=?",
                    (final, json.dumps(results, default=str), int(time.time()) if final != "proposed" else None, plan_id))
        store.log_event(con, "plan_executed", {"plan_id": plan_id, "status": final, "actor": actor, "live": live,
                                               "confirmed": token_ok})
        con.commit()
        return {"status": final, "plan_id": plan_id, "live": live, "confirmed_by_operator": token_ok,
                "frozen": frozen, "results": results}
    finally:
        if own:
            con.close()
