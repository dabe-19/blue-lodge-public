#!/usr/bin/env python3
"""
Reactive sell-leg for filled maker BUY orders ('cardano/maker_filled').

Fixes over the previous shell reactor:
* Idempotent: an atomic DB claim guarantees one sell listing per filled buy even when
  the watcher or bus delivers the event repeatedly.
* Never records placeholder tx ids for live cycles; failures leave the cycle in
  INVENTORY_HOLD with the error recorded (retry allowed after a cool-down).
* Payload is parsed as JSON and validated; nothing from the bus is interpolated into code.
* Pricing uses on-chain ADA-quoted spot and reports the model fill probability of the
  chosen ask, so the operator can see whether the listing is realistic.
* George's autonomous placement is checked against the spending policy.
* (2026-10) Pricing and permission now come from the trading policy engine
  (lib/tools/trading): S1 exit price = max(fair value, break-even x 1.01) stepping down to
  break-even x 1.003 over 7 days; the listing is built as a plan and executed only if it is
  Tier A, S1 is live, execution.live is on and GEORGE_EXECUTE_LIVE_SELL=1. Anything else is
  escalated to the operator with a plan_id. price_sell_leg() below is kept for the CLI only.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Any, Dict

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if __name__ == "__main__" and _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)

ORDER_ID_RE = re.compile(r"^[A-Za-z0-9_\-]{3,80}$")
CLAIM_COOLDOWN_S = 1800
SELL_FRICTION_ADA = 2.0 + 0.2   # max batcher fee + L1 fee (2 ADA deposit is refunded)
MIN_PROFIT_ADA = 0.75
# Minimum worthwhile sell notional (ADA). A position whose value is below this floor is not
# worth the round-trip DEX friction (SELL_FRICTION_ADA + MIN_PROFIT_ADA), so the sell leg is
# deferred and the inventory rests in INVENTORY_HOLD. Configurable via env; default 80.0 ADA.
MIN_SELL_NOTIONAL_ADA = float(os.environ.get("MAKER_SELL_MIN_NOTIONAL_ADA", "80.0"))
# Sell modes (per-cycle metadata `sell_mode` overrides env MAKER_SELL_MODE):
#   auto      - cost-plus floor if it is realistic (P72h >= AUTO_MIN_P72), else the best calibrated
#               rung that still breaks even; if none breaks even, the break-even price (flagged).
#   liquidity - best calibrated rung with P(target horizon) >= target prob; losses allowed down to
#               MAX_LOSS_PCT below cost basis. Used to recycle stuck inventory back into ADA.
#   profit    - legacy cost-plus floor / spread ask regardless of fill odds.
SELL_MODES = ("auto", "liquidity", "profit")
AUTO_MIN_P72 = 0.5
LIQ_HORIZON = os.environ.get("MAKER_LIQ_HORIZON", "24h")
LIQ_MIN_PROB = float(os.environ.get("MAKER_LIQ_MIN_PROB", "0.7"))
MAX_LOSS_PCT = float(os.environ.get("MAKER_MAX_LOSS_PCT", "10"))


def _cycle_meta(order_id: str, is_simulated: bool = False) -> Dict[str, Any]:
    try:
        from lib.tools.cardano_maker_db import get_db_connection, init_db
        init_db(is_simulated=is_simulated)
        with get_db_connection(is_simulated=is_simulated) as conn:
            row = conn.execute("SELECT metadata_json FROM maker_orders WHERE order_id = ?", (order_id,)).fetchone()
        if not row and not is_simulated:
            with get_db_connection(is_simulated=True) as conn:
                row = conn.execute("SELECT metadata_json FROM maker_orders WHERE order_id = ?", (order_id,)).fetchone()
        return json.loads(row[0] or "{}") if row else {}
    except Exception:
        return {}


def _claim(order_id: str, is_simulated: bool = False) -> bool:
    from lib.tools.cardano_maker_db import get_db_connection, init_db
    init_db(is_simulated=is_simulated)
    now = int(time.time())
    with get_db_connection(is_simulated=is_simulated) as conn:
        cur = conn.execute(
            "UPDATE maker_orders SET metadata_json = json_set(COALESCE(metadata_json,'{}'), '$.sell_claim_at', ?), "
            "updated_at = ? WHERE order_id = ? AND status = 'INVENTORY_HOLD' AND "
            "(json_extract(metadata_json,'$.sell_claim_at') IS NULL OR json_extract(metadata_json,'$.sell_claim_at') < ?)",
            (now, now, order_id, now - CLAIM_COOLDOWN_S))
        conn.commit()
        return cur.rowcount == 1


def _note(order_id: str, key: str, value: Any, is_simulated: bool = False) -> None:
    from lib.tools.cardano_maker_db import get_db_connection
    with get_db_connection(is_simulated=is_simulated) as conn:
        conn.execute("UPDATE maker_orders SET metadata_json = json_set(COALESCE(metadata_json,'{}'), ?, ?) "
                     "WHERE order_id = ?", (f"$.{key}", json.dumps(value) if isinstance(value, (dict, list)) else value,
                                             order_id))
        conn.commit()


def price_sell_leg(asset: str, tokens: float, cost_basis: float, spread_pct: float,
                   mode: str = "auto") -> Dict[str, Any]:
    from lib.tools.limit_order_forecaster import choose_rung, price_ladder
    from lib.tools.quant.market_data import load_series
    mode = mode if mode in SELL_MODES else "auto"
    floor = (cost_basis + SELL_FRICTION_ADA + MIN_PROFIT_ADA) / tokens
    breakeven = (cost_basis + SELL_FRICTION_ADA) / tokens
    s = load_series(asset, "hour")
    if s.get("status") != "ok":
        return {"status": "unavailable", "reason": s.get("reason"), "floor_price": floor}
    spot = float(s["pool"]["price_ada"])
    legacy = max(floor, spot * (1 + spread_pct / 200.0))
    lad = price_ladder(asset, "sell", tokens, n_rungs=21, span_pct=8.0, series=s)
    if lad.get("status") != "ok":
        return {"status": "unavailable", "reason": lad.get("reason"), "floor_price": floor}
    best = choose_rung(lad, LIQ_HORIZON, LIQ_MIN_PROB)
    reason = ""
    if mode == "profit":
        ask, reason = legacy, "legacy cost-plus/spread ask"
    elif mode == "liquidity":
        min_px = cost_basis * (1 - MAX_LOSS_PCT / 100.0) / tokens
        if best and best["price"] >= min_px:
            ask, reason = best["price"], f"best rung with P{LIQ_HORIZON}>={LIQ_MIN_PROB:.0%}"
        else:
            ask, reason = max(min_px, spot), f"loss cap {MAX_LOSS_PCT}% binds"
    else:
        legacy_odds = price_ladder(asset, "sell", tokens, prices=[legacy], series=s)["rungs"][0]["fill_probability"]
        if (legacy_odds.get("72h") or 0) >= AUTO_MIN_P72:
            ask, reason = legacy, "cost-plus ask is realistic"
        elif best and best["price"] >= breakeven:
            ask, reason = best["price"], "best calibrated rung above break-even"
        else:
            ask, reason = breakeven, ("break-even (no calibrated rung clears cost); low fill odds - "
                                      "set sell_mode=liquidity to recycle into ADA")
    odds = price_ladder(asset, "sell", tokens, prices=[ask], series=s)["rungs"][0]["fill_probability"]
    return {"status": "ok", "mode": mode, "reason": reason, "spot": spot, "floor_price": floor,
            "breakeven_price": breakeven, "legacy_ask": legacy, "ask": ask,
            "premium_pct": (ask / spot - 1) * 100, "sigma_hourly": lad["sigma_hourly"],
            "fill_probability_calibrated": odds,
            "ladder": [{"price": r["price"], "p24h": r["fill_probability"].get("24h")} for r in lad["rungs"][::4]],
            "expected_gross_ada": ask * tokens, "expected_net_profit_ada": ask * tokens - cost_basis - SELL_FRICTION_ADA}


def handle(payload: Dict[str, Any]) -> Dict[str, Any]:
    if payload.get("relisted_inline"):
        return {"status": "skipped", "reason": "already relisted inline during mark_buy_filled"}
    order_id = str(payload.get("order_id", ""))
    asset = str(payload.get("asset", "")).upper()
    try:
        tokens = float(payload.get("tokens_filled", 0))
        cost_basis = float(payload.get("net_cost_basis_ada", 0))
    except (TypeError, ValueError):
        return {"status": "rejected", "reason": "non-numeric tokens/cost"}
    is_sim = bool(payload.get("is_simulated", False))
    from lib.tools.quant.market_data import KNOWN_ASSETS
    if not ORDER_ID_RE.match(order_id) or asset not in KNOWN_ASSETS or tokens <= 0 or cost_basis < 0:
        return {"status": "rejected", "reason": "invalid maker_filled payload"}

    meta = _cycle_meta(order_id, is_simulated=is_sim)
    if meta.get("managed_by") in ("stop_reactor", "arbitrage_graph") or meta.get("source") in ("stop_reactor", "arbitrage_graph"):
        return {"status": "skipped", "reason": f"managed_by_{meta.get('managed_by') or meta.get('source')}; engine manages the sell leg"}
    if meta.get("operator_hold") or meta.get("relist_blocked"):
        return {"status": "skipped", "reason": "operator_hold/relist_blocked set on this cycle; operator manages the sell leg"}

    # S1 inventory exit through the trading policy engine (grill-me Q2/Q6): exit price =
    # max(fair value, break-even x 1.01) stepping down to break-even x 1.003 over 7 days.
    from lib.tools.trading import plans as tplans, policy as tpol, store as tstore
    from lib.tools.trading.market import market_ctx
    pol = tpol.load_policy()
    m = market_ctx(asset)
    age = max(0.0, time.time() - float(meta.get("filled_at") or payload.get("timestamp") or time.time()))
    pricing = tpol.exit_price(cost_basis, tokens, age, m.get("fair_value"), pol)
    if not pricing:
        return {"status": "deferred", "reason": "no cost basis: exit needs the operator"}
    pricing["spot"] = m.get("spot")
    if is_sim:
        return {"status": "simulated", "order_id": order_id, "asset": asset, "tokens": tokens,
                "ask_price_ada": pricing["price"], "pricing": pricing,
                "note": "simulated cycle: priced by the policy engine, no transaction built"}

    notional = tokens * float(m.get("spot") or pricing["price"])
    if notional < float(pol["capital"]["min_order_ada"]):
        return {"status": "deferred", "asset": asset, "tokens": tokens, "notional_ada": round(notional, 2),
                "reason": f"position notional {notional:.2f} ADA < policy min order {pol['capital']['min_order_ada']:.0f} ADA"}

    con = tstore.connect()
    try:
        if tpol.strategy_state(con, pol, "S1_inventory_exit") == "disabled":
            return {"status": "skipped", "reason": "S1_inventory_exit is disabled in the trading policy"}
        plan = tplans.build_plan({"kind": "exit", "asset": asset, "parent_order_id": order_id}, origin="reactor:s1",
                                 con=con, pol=pol)
        sells = [a for a in plan["actions"] if a["type"] in ("place_sell", "reprice") and not a.get("blocked")]
        if not sells:
            return {"status": "deferred", "plan_id": plan["plan_id"], "reason": "; ".join(plan.get("notes") or [])[:400]
                    or "no executable exit action", "pricing": pricing}
        if plan["tier"] != "A":
            try:
                from lib.comms import escalation
                escalation.raise_escalation(
                    "cardano/s1_needs_confirmation", order_id,
                    f"{asset} inventory ({tokens:,.2f} tokens, cost {cost_basis:.2f} ADA) needs your decision before it is "
                    f"listed: {plan['summary']}", plan_id=plan["plan_id"], context={"pricing": pricing},
                    source="maker_sell_reactor")
            except Exception:
                pass
            return {"status": "needs_confirmation", "plan_id": plan["plan_id"], "summary": plan["summary"],
                    "pricing": pricing}
        from lib.tools.feature_flags import flag
        # Second, independent opt-in (env or .george/features.conf) on top of policy execution.live.
        if not flag("GEORGE_EXECUTE_LIVE_SELL", False):
            return {"status": "simulated", "plan_id": plan["plan_id"], "order_id": order_id, "asset": asset,
                    "ask_price_ada": sells[0].get("price"), "pricing": pricing,
                    "note": "GEORGE_EXECUTE_LIVE_SELL is off: plan built, not executed"}
        if not _claim(order_id, is_simulated=False):
            return {"status": "skipped", "reason": "sell leg already claimed/placed for this order (idempotent)"}
        res = tplans.execute_plan(plan["plan_id"], actor="george", con=con, pol=pol)
    finally:
        con.close()
    first = (res.get("results") or [{}])[0]
    if res.get("status") != "executed" or first.get("status") not in ("ok", "unvalidated", "simulated"):
        _note(order_id, "sell_error", str(first.get("message") or res.get("reason"))[:300])
        _note(order_id, "sell_claim_at", None)
        return {"status": "failed", "plan_id": plan["plan_id"], "reason": first.get("message") or res.get("reason"),
                "pricing": pricing}
    out = {"status": "placed" if first.get("submitted") else first.get("status"), "plan_id": plan["plan_id"],
           "order_id": order_id, "asset": asset, "sell_tx_id": first.get("tx_id") if first.get("submitted") else None,
           "ask_price_ada": sells[0].get("price"), "tokens": sells[0].get("tokens"), "pricing": pricing,
           "live": res.get("live")}
    if first.get("submitted"):
        from lib.tools.cardano_orders import emit_event
        emit_event("cardano/maker_sell_placed", {k: out[k] for k in ("order_id", "asset", "sell_tx_id",
                                                                      "ask_price_ada", "tokens")})
    return out


def main() -> None:
    raw = sys.argv[1] if len(sys.argv) > 1 else sys.stdin.read()
    try:
        payload = json.loads(raw or "{}")
        if not isinstance(payload, dict):
            raise ValueError("payload must be an object")
        res = handle(payload)
    except Exception as e:
        res = {"status": "error", "reason": f"{type(e).__name__}: {e}"}
    print(json.dumps(res, default=str))


if __name__ == "__main__":
    main()
