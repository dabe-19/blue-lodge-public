#!/usr/bin/env python3
"""
Sovereign Polymarket complete-set arbitrage scanner (v2, audited).

What v1 got wrong (and why it never found anything real):
  * The CLOB /book endpoint returns bids ascending and asks descending; v1 read element [0],
    i.e. the WORST bid (~0.001) and WORST ask (~0.999), so every sum was ~1.0 or nonsense.
  * It summed only the first 3 outcome tokens of single markets (YES/NO of one binary market),
    ignored depth, fees, the 5-share minimum order, and the "augmented" neg-risk flag.
  * "Mint-and-dump" needs CTF split + sells; not implemented, so it is no longer reported as viable.

What v2 does:
  1. Binary markets: buy YES + NO when best_ask(YES) + best_ask(NO) + fees < 1.
  2. Negative-risk events (mutually exclusive outcomes): buy YES on every outcome when the sum of
     best asks + fees < 1. Events flagged negRiskAugmented (unnamed "other" outcomes possible) are
     reported but NOT viable: if an unlisted outcome wins every leg pays 0.
  * Best prices are max(bids) / min(asks); executable sets = min size at the best ask across legs.
  * Polymarket fee model: fee = baseRate(bps) x min(p, 1-p) x shares, per taker leg.
  * Read-only. Execution (signed CLOB orders) is out of scope; viable rows are reported with the
    exact legs, size and capital needed.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
import urllib.request
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", stream=sys.stderr)
logger = logging.getLogger("polymarket_arbitrageur")

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path.home() / "blue-lodge"))
CLOB = "https://clob.polymarket.com"
GAMMA = "https://gamma-api.polymarket.com"
UA = {"User-Agent": "Mozilla/5.0 (BlueLodge research scanner)", "Accept": "application/json"}

MIN_NET_EDGE_PCT = 0.5        # after fees
MIN_ORDER_SHARES = 5.0        # CLOB minimum
MAX_LEGS = 40


def _get(url: str, timeout: int = 15) -> Any:
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
        return json.loads(r.read().decode())


def _post(url: str, body: Any, timeout: int = 20) -> Any:
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={**UA, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def best_levels(book: Dict[str, Any]) -> Dict[str, Optional[float]]:
    """Best bid = highest bid, best ask = lowest ask (CLOB lists are not best-first)."""
    bids = [(float(b["price"]), float(b["size"])) for b in book.get("bids", [])]
    asks = [(float(a["price"]), float(a["size"])) for a in book.get("asks", [])]
    bb = max(bids, key=lambda x: x[0]) if bids else (None, 0.0)
    ba = min(asks, key=lambda x: x[0]) if asks else (None, 0.0)
    return {"bid": bb[0], "bid_size": bb[1], "ask": ba[0], "ask_size": ba[1]}


def fetch_books(token_ids: List[str]) -> Dict[str, Dict[str, Optional[float]]]:
    out: Dict[str, Dict[str, Optional[float]]] = {}
    for i in range(0, len(token_ids), 20):
        chunk = token_ids[i:i + 20]
        try:
            for b in _post(f"{CLOB}/books", [{"token_id": t} for t in chunk]):
                out[str(b.get("asset_id"))] = best_levels(b)
        except Exception as e:
            logger.warning(f"books batch failed: {e}")
        time.sleep(0.2)
    return out


def taker_fee(price: float, shares: float, base_bps: float) -> float:
    return (base_bps / 10_000.0) * min(price, 1 - price) * shares


@dataclass
class ProbabilityArbOpportunity:
    kind: str                       # "binary_complete_set" | "negrisk_complete_set"
    market_id: str
    question: str
    legs: List[Dict[str, Any]]
    sum_best_ask: float
    fees_per_set: float
    net_cost_per_set: float
    net_edge_pct: float
    executable_sets: float
    capital_req_usd: float
    net_profit_usd: float
    viable: bool
    blockers: List[str] = field(default_factory=list)
    url: str = ""


def _fee_bps(m: Dict[str, Any]) -> float:
    if not m.get("feesEnabled"):
        return 0.0
    return float(m.get("takerBaseFee") or 0)


def scan_negrisk_events(limit: int = 40) -> List[ProbabilityArbOpportunity]:
    events = _get(f"{GAMMA}/events?limit={limit}&active=true&closed=false&order=volume24hr&ascending=false")
    opps: List[ProbabilityArbOpportunity] = []
    for e in events:
        if not e.get("negRisk"):
            continue
        mkts = [m for m in e.get("markets", []) if m.get("active") and not m.get("closed")
                and m.get("acceptingOrders", True) and m.get("clobTokenIds")]
        if len(mkts) < 2 or len(mkts) > MAX_LEGS:
            continue
        yes = [json.loads(m["clobTokenIds"])[0] for m in mkts]
        books = fetch_books(yes)
        legs, blockers = [], []
        for m, t in zip(mkts, yes):
            bl = books.get(t) or {}
            if bl.get("ask") is None:
                blockers.append(f"no ask on '{m.get('groupItemTitle') or m.get('question', '')[:30]}'")
                continue
            legs.append({"outcome": m.get("groupItemTitle") or m.get("question", "")[:60], "token_id": t,
                         "ask": bl["ask"], "ask_size": bl["ask_size"], "fee_bps": _fee_bps(m)})
        if blockers or not legs:
            continue
        s = sum(l["ask"] for l in legs)
        fees = sum(taker_fee(l["ask"], 1.0, l["fee_bps"]) for l in legs)
        cost = s + fees
        edge = (1.0 - cost) / cost * 100 if cost > 0 else 0.0
        sets = min(l["ask_size"] for l in legs)
        if e.get("negRiskAugmented"):
            blockers.append("augmented neg-risk: an unlisted outcome can win, so the set is not complete")
        if sets < MIN_ORDER_SHARES:
            blockers.append(f"depth {sets:.1f} shares < {MIN_ORDER_SHARES} minimum")
        viable = edge >= MIN_NET_EDGE_PCT and not blockers
        opps.append(ProbabilityArbOpportunity(
            kind="negrisk_complete_set", market_id=str(e.get("id")), question=str(e.get("title"))[:90], legs=legs,
            sum_best_ask=round(s, 4), fees_per_set=round(fees, 5), net_cost_per_set=round(cost, 5),
            net_edge_pct=round(edge, 3), executable_sets=round(sets, 2), capital_req_usd=round(cost * sets, 2),
            net_profit_usd=round((1 - cost) * sets, 4), viable=viable, blockers=blockers,
            url=f"https://polymarket.com/event/{e.get('slug')}"))
    return opps


def scan_binary_markets(limit: int = 40) -> List[ProbabilityArbOpportunity]:
    mkts = _get(f"{GAMMA}/markets?limit={limit}&active=true&closed=false&order=volume24hr&ascending=false")
    mkts = [m for m in mkts if m.get("clobTokenIds") and not m.get("negRisk")]
    toks: List[Tuple[Dict[str, Any], List[str]]] = []
    for m in mkts:
        try:
            ids = json.loads(m["clobTokenIds"])
        except Exception:
            continue
        if len(ids) == 2:
            toks.append((m, ids))
    books = fetch_books([t for _, ids in toks for t in ids])
    opps = []
    for m, ids in toks:
        a, b = books.get(ids[0]) or {}, books.get(ids[1]) or {}
        if a.get("ask") is None or b.get("ask") is None:
            continue
        bps = _fee_bps(m)
        s = a["ask"] + b["ask"]
        fees = taker_fee(a["ask"], 1, bps) + taker_fee(b["ask"], 1, bps)
        cost = s + fees
        edge = (1 - cost) / cost * 100
        sets = min(a["ask_size"], b["ask_size"])
        blockers = [] if sets >= MIN_ORDER_SHARES else [f"depth {sets:.1f} < {MIN_ORDER_SHARES}"]
        outs = json.loads(m.get("outcomes") or '["YES","NO"]')
        opps.append(ProbabilityArbOpportunity(
            kind="binary_complete_set", market_id=str(m.get("id")), question=str(m.get("question"))[:90],
            legs=[{"outcome": outs[0], "token_id": ids[0], "ask": a["ask"], "ask_size": a["ask_size"], "fee_bps": bps},
                  {"outcome": outs[1], "token_id": ids[1], "ask": b["ask"], "ask_size": b["ask_size"], "fee_bps": bps}],
            sum_best_ask=round(s, 4), fees_per_set=round(fees, 5), net_cost_per_set=round(cost, 5),
            net_edge_pct=round(edge, 3), executable_sets=round(sets, 2), capital_req_usd=round(cost * sets, 2),
            net_profit_usd=round((1 - cost) * sets, 4), viable=edge >= MIN_NET_EDGE_PCT and not blockers,
            blockers=blockers, url=f"https://polymarket.com/market/{m.get('slug')}"))
    return opps


def scan_polymarket_arbitrage(available_usdc: float = 0.0, override_size: Optional[float] = None) -> List[ProbabilityArbOpportunity]:
    """Backwards-compatible entry point: all complete-set opportunities, best edge first."""
    opps: List[ProbabilityArbOpportunity] = []
    for fn in (scan_negrisk_events, scan_binary_markets):
        try:
            opps += fn()
        except Exception as e:
            logger.warning(f"{fn.__name__} failed: {e}")
    budget = override_size or available_usdc
    for o in opps:
        if o.viable and budget and o.capital_req_usd > budget:
            o.blockers.append(f"needs ${o.capital_req_usd:.2f} for full depth; budget ${budget:.2f} "
                              f"(partial: {budget / o.net_cost_per_set:.1f} sets)")
    return sorted(opps, key=lambda o: o.net_edge_pct, reverse=True)


def polygon_usdc() -> float:
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
        from lib.tools.sovereign_multichain_wallet import get_polygon_status
        pg = get_polygon_status()
        return float(pg.get("total_usdc") or 0.0)
    except Exception:
        return 0.0


def main() -> None:
    p = argparse.ArgumentParser(description="Polymarket complete-set arbitrage scanner (read-only)")
    p.add_argument("--scan", action="store_true", help="Scan (default)")
    p.add_argument("--json", action="store_true")
    p.add_argument("--size", type=float, default=None, help="Budget in USDC (default: live Polygon USDC)")
    a = p.parse_args()
    budget = a.size if a.size else polygon_usdc()
    opps = scan_polymarket_arbitrage(budget, a.size)
    if a.json:
        print(json.dumps({"status": "ok", "schema": "polymarket_complete_set/v2", "timestamp": int(time.time()),
                          "budget_usdc": budget, "scanned": len(opps), "viable": sum(o.viable for o in opps),
                          "opportunities": [asdict(o) for o in opps[:40]]}, default=str))
        return
    print("\n" + "=" * 96)
    print("  POLYMARKET COMPLETE-SET ARBITRAGE SCAN (read-only; fees, depth and min size applied)")
    print("=" * 96)
    print(f"  Budget: ${budget:.2f} USDC (Polygon)")
    print(f"  {'KIND':<10} {'QUESTION':<46} {'ΣASK':>7} {'FEES':>7} {'EDGE%':>7} {'SETS':>8}  VIABLE")
    for o in opps[:25]:
        print(f"  {o.kind.split('_')[0]:<10} {o.question[:46]:<46} {o.sum_best_ask:>7.3f} {o.fees_per_set:>7.4f} "
              f"{o.net_edge_pct:>7.2f} {o.executable_sets:>8.1f}  {'YES' if o.viable else 'no'}"
              + (f"  [{o.blockers[0][:40]}]" if o.blockers else ""))
    print("=" * 96)
    print(f"  {len(opps)} books scanned, {sum(o.viable for o in opps)} viable after fees/depth.")
    print("  Complete sets on liquid markets are usually priced at >= $1; a zero count is the normal, honest result.\n")


if __name__ == "__main__":
    main()
