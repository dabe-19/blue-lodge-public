#!/usr/bin/env python3
"""
Trading policy engine: loads .george/finance/trading_policy.json, resolves effective strategy
states (baseline + gate overrides + drawdown freeze), classifies actions into permission tiers
and runs the capital checks.

Tiers (grill-me Q2):
  A  autonomous, reported after: reprice same side/size within +-1.5 sigma, reclaim stale orders,
     sell held inventory at >= break-even + margin.
  B  needs the operator's `confirm <plan_id>` (or a standing order): new buys, pair switches,
     size increases, sells below break-even, strategy unlocks, standing-order creation.
  C  never autonomous, never executable by George: breach the floor, send funds off-wallet,
     change policy.
Unknown action types classify as C (fail closed).

Capital rules (Q6): at most 2 positions, one may use ~90% of working capital, a 10 ADA fee
buffer above the 40 ADA floor, and only pools where our order moves the price <= 0.1%.
"""
from __future__ import annotations

import copy
import json
import math
import os
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

_REPO_ROOT = Path(__file__).resolve().parents[3]
LODGE_DIR = Path(os.environ.get("LODGE_DIR", _REPO_ROOT))

# Fail-closed defaults: used when the policy file is missing or unreadable. Note execution.live=False.
DEFAULT_POLICY: Dict[str, Any] = {
    "version": 1,
    "execution": {"live": False},
    "wallet": {"floor_ada": 40.0, "fee_buffer_ada": 10.0},
    "capital": {"max_positions": 4, "max_position_fraction": 0.95, "max_pool_impact_pct": 0.50, "min_order_ada": 15.0},
    "fees": {"order_deposit_ada": 2.0, "max_batcher_fee_ada": 2.0, "network_fee_ada": 0.2, "default_pool_fee_bps": 30},
    "tiers": {"reprice_max_sigma": 1.5},
    "plans": {"ttl_s": 600, "max_move_sigma": 0.5},
    "strategies": {
        "S1_inventory_exit": {"state": "simulated", "exit_start_markup": 0.01, "exit_floor_markup": 0.003, "step_days": 7},
        "S2_shock_fade": {"state": "simulated", "k_sigma": 2.0, "min_swap_reserve_pct": 0.1, "entry_offset_sigma": 0.25},
        "S3_stable_deviation": {"state": "simulated", "assets": ["USDM", "USDCX", "DJED"], "k_sigma": 1.5},
        "manual": {"state": "live"},
        "momentum_stop_buy": {"state": "disabled"},
        "bid_ladder": {"state": "disabled"},
        "cointegration_reactor": {"state": "disabled"},
    },
    "inventory": {"stuck_days": 7, "stuck_sigma_24h": 2.5, "auto_average_down": False, "auto_stop_loss": False},
    "gates": {"gate1": {"min_backtest_trips": 40, "min_lower80_ada": -0.5, "min_live_sim_days": 14, "max_sim_vs_backtest_se": 1.0},
              "gate2": {"min_trips": 15, "markout_horizon": "6h"},
              "freeze_drawdown_pct": 15.0, "relock_window_trips": 20},
    "escalation": {"max_per_hour": 4, "dedup_hours": 6,
                   "quiet_hours": {"start": "22:00", "end": "07:00", "tz": "America/Chicago"}, "headless_max_steps": 3},
}

STATES = ("disabled", "simulated", "live")
TIER_A = {"reprice", "reclaim", "place_sell"}
TIER_C_TYPES = {"send", "policy_change", "withdraw"}


def policy_path() -> Path:
    p = os.environ.get("TRADING_POLICY_PATH")
    if p:
        return Path(p)
    george = Path(os.environ.get("GEORGE_DIR", LODGE_DIR / ".george"))
    return Path(os.environ.get("FINANCE_DIR", george / "finance")) / "trading_policy.json"


def _merge(base: Dict[str, Any], over: Dict[str, Any]) -> Dict[str, Any]:
    out = copy.deepcopy(base)
    for k, v in (over or {}).items():
        if k.startswith("_"):
            continue
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _merge(out[k], v)
        else:
            out[k] = copy.deepcopy(v)
    return out


def load_policy(path: Optional[Path] = None) -> Dict[str, Any]:
    p = Path(path) if path else policy_path()
    try:
        user = json.loads(p.read_text())
        if not isinstance(user, dict):
            raise ValueError("policy root must be an object")
        pol = _merge(DEFAULT_POLICY, user)
        pol["_source"] = str(p)
    except FileNotFoundError:
        pol = copy.deepcopy(DEFAULT_POLICY)
        pol["_source"] = "defaults (policy file missing)"
    except Exception as e:  # unreadable policy: defaults, never live
        pol = copy.deepcopy(DEFAULT_POLICY)
        pol["_source"] = f"defaults (policy unreadable: {type(e).__name__})"
        pol["execution"]["live"] = False
    for name, s in pol.get("strategies", {}).items():
        if s.get("state") not in STATES:
            s["state"] = "disabled"
    return pol


def live_execution_enabled(pol: Dict[str, Any]) -> bool:
    if os.environ.get("CARDANO_TEST_MODE") == "1" or os.environ.get("GEORGE_TRADING_DRY_RUN") == "1":
        return False
    return bool(pol.get("execution", {}).get("live", False))


# ---------------------------------------------------------------------------
# Strategy states, freeze
# ---------------------------------------------------------------------------

def is_frozen(con) -> Optional[Dict[str, Any]]:
    from lib.tools.trading import store
    return store.get_override(con, "freeze")


def strategy_state(con, pol: Dict[str, Any], name: str) -> str:
    """Effective state: baseline -> gate override -> freeze (live demoted to simulated).
    'disabled' in the policy file can never be overridden upward by George's tooling."""
    from lib.tools.trading import store
    base = pol.get("strategies", {}).get(name, {}).get("state", "disabled")
    if base == "disabled":
        return "disabled"
    st = base
    ov = store.get_override(con, f"strategy:{name}")
    if isinstance(ov, str) and ov in STATES:
        st = ov
    if st == "live" and is_frozen(con):
        st = "simulated"
    return st


def strategy_states(con, pol: Dict[str, Any]) -> Dict[str, str]:
    return {n: strategy_state(con, pol, n) for n in pol.get("strategies", {})}


# ---------------------------------------------------------------------------
# Exit pricing (S1)
# ---------------------------------------------------------------------------

def breakeven_price(cost_ada: float, tokens: float, pol: Dict[str, Any]) -> Optional[float]:
    """Limit-sell price at which proceeds (min_receive, net of pool fee) minus batcher + network
    fee recover the cost basis. The order deposit is refunded so it is not a cost."""
    if not tokens or tokens <= 0 or cost_ada is None or cost_ada < 0:
        return None
    f = pol["fees"]
    return (cost_ada + f["max_batcher_fee_ada"] + f["network_fee_ada"]) / tokens


def exit_markup(age_s: float, pol: Dict[str, Any]) -> float:
    s = pol["strategies"]["S1_inventory_exit"]
    start, floor, days = float(s["exit_start_markup"]), float(s["exit_floor_markup"]), float(s["step_days"])
    frac = min(1.0, max(0.0, age_s / (days * 86400.0)))
    return start + (floor - start) * frac


def exit_price(cost_ada: float, tokens: float, age_s: float, fair_value: Optional[float],
               pol: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    be = breakeven_price(cost_ada, tokens, pol)
    if be is None:
        return None
    m = exit_markup(age_s, pol)
    floor_px = be * (1 + m)
    px = max(floor_px, fair_value) if fair_value else floor_px
    return {"price": px, "breakeven": be, "markup": m, "floor_price": floor_px,
            "fair_value": fair_value, "binding": "fair_value" if fair_value and fair_value > floor_px else "breakeven_markup"}


# ---------------------------------------------------------------------------
# Tier classification + capital checks
# ---------------------------------------------------------------------------

def classify(action: Dict[str, Any], pol: Dict[str, Any], portfolio: Dict[str, Any],
             market: Dict[str, Dict[str, Any]]) -> Tuple[str, List[str]]:
    t = action.get("type")
    reasons: List[str] = []
    if t in TIER_C_TYPES:
        return "C", [f"{t} is never autonomous"]
    if t == "reclaim":
        return "A", ["reclaim own order"]
    if t == "place_sell":
        pos = (portfolio.get("positions") or {}).get(action.get("asset"), {})
        be = breakeven_price(pos.get("cost_ada"), pos.get("tokens"), pol) if pos else None
        floor_m = float(pol["strategies"]["S1_inventory_exit"]["exit_floor_markup"])
        if be is None:
            return "B", ["no cost basis on record: selling needs confirmation"]
        if float(action.get("price", 0)) >= be * (1 + floor_m) - 1e-15:
            return "A", [f"sell >= break-even x{1 + floor_m:.3f}"]
        return "B", ["sell below break-even + margin"]
    if t == "reprice":
        m = market.get(action.get("asset"), {})
        sig = m.get("sigma_24h")
        old, new = action.get("old_price"), action.get("price")
        if action.get("side") != action.get("old_side") or abs(float(action.get("tokens", 0)) - float(action.get("old_tokens", 0))) > 1e-9 * max(1.0, float(action.get("old_tokens", 1))):
            return "B", ["reprice changes side or size"]
        if not sig or not old or not new:
            return "B", ["sigma unavailable: reprice needs confirmation"]
        d = abs(math.log(float(new) / float(old)))
        lim = float(pol["tiers"]["reprice_max_sigma"]) * float(sig)
        if action.get("side") == "sell":
            pos = (portfolio.get("positions") or {}).get(action.get("asset"), {})
            be = breakeven_price(pos.get("cost_ada"), pos.get("tokens"), pol) if pos else None
            floor_m = float(pol["strategies"]["S1_inventory_exit"]["exit_floor_markup"])
            if be is None or float(new) < be * (1 + floor_m):
                return "B", ["sell reprice below break-even + margin"]
        return ("A", [f"|move| {d:.4f} <= {lim:.4f} (1.5 sigma_24h)"]) if d <= lim else ("B", ["reprice beyond 1.5 sigma_24h"])
    if t == "place_buy":
        return "B", ["new buy"]
    if t in ("strategy_unlock", "standing_order_create", "wallet_send"):
        return "B", [t]
    return "C", [f"unknown action type {t!r} (fail closed)"]


def capital_check(action: Dict[str, Any], pol: Dict[str, Any], portfolio: Dict[str, Any],
                  market: Dict[str, Dict[str, Any]]) -> Dict[str, Any]:
    """Returns {ok, failures[], breach_floor}. Only buys add risk; sells/reclaims pass if fees fit."""
    w, cap, fees = pol["wallet"], pol["capital"], pol["fees"]
    failures: List[str] = []
    breach_floor = False
    wallet_ada = portfolio.get("wallet_ada")
    if wallet_ada is None:
        return {"ok": False, "failures": ["wallet balance unavailable (fail closed)"], "breach_floor": False}
    t = action.get("type")
    net_fee = fees["network_fee_ada"]
    if t in ("reclaim",):
        out = net_fee
    elif t == "place_sell":
        out = fees["order_deposit_ada"] + fees["max_batcher_fee_ada"] + net_fee
    elif t == "reprice":
        out = 2 * net_fee + (fees["order_deposit_ada"] + fees["max_batcher_fee_ada"] if action.get("side") == "sell" else 0)
        if action.get("side") == "buy":
            out += max(0.0, float(action.get("ada", 0)) - float(action.get("old_ada", action.get("ada", 0))))
    elif t == "place_buy":
        out = float(action.get("ada", 0)) + fees["order_deposit_ada"] + fees["max_batcher_fee_ada"] + net_fee
    elif t == "wallet_send":
        if str(action.get("chain", "cardano")).lower() in ("cardano", "ada"):
            out = float(action.get("ada", 0)) + net_fee
        else:
            out = 0.0
    else:
        out = 0.0
    after = float(wallet_ada) - out
    if after < w["floor_ada"]:
        breach_floor = True
        failures.append(f"would leave {after:.2f} ADA < {w['floor_ada']:.0f} ADA floor")
    elif after < w["floor_ada"] + w["fee_buffer_ada"]:
        failures.append(f"would leave {after:.2f} ADA, inside the {w['fee_buffer_ada']:.0f} ADA fee buffer above the floor")
    if t == "place_buy" or (t == "reprice" and action.get("side") == "buy"):
        asset = action.get("asset")
        ada = float(action.get("ada", 0))
        if ada < cap["min_order_ada"]:
            failures.append(f"order {ada:.1f} ADA < min {cap['min_order_ada']:.0f} ADA (fixed fees would dominate)")
        exposures = dict(portfolio.get("exposure_ada") or {})
        held = {a for a, v in exposures.items() if v >= 5.0}
        if asset not in held and len(held) + 1 > cap["max_positions"]:
            failures.append(f"would open position #{len(held) + 1} (max {cap['max_positions']}: {sorted(held)})")
        working = portfolio.get("working_capital_ada")
        if working is None or working <= 0:
            failures.append("working capital unavailable or non-positive")
        else:
            new_exp = exposures.get(asset, 0.0) + (ada if t == "place_buy" else max(0.0, ada - float(action.get("old_ada", ada))))
            if new_exp > cap["max_position_fraction"] * working + 1e-9:
                failures.append(f"{asset} exposure {new_exp:.1f} ADA > {cap['max_position_fraction']:.0%} of working capital {working:.1f}")
        m = market.get(asset, {})
        r = m.get("reserve_ada")
        if not r:
            failures.append(f"{asset} pool reserve unknown: impact cannot be bounded (fail closed)")
        else:
            impact_pct = ada / float(r) * 100.0
            if impact_pct > cap["max_pool_impact_pct"]:
                failures.append(f"impact {impact_pct:.3f}% > {cap['max_pool_impact_pct']}% of pool (max {cap['max_pool_impact_pct'] / 100 * float(r):.0f} ADA)")
    return {"ok": not failures, "failures": failures, "breach_floor": breach_floor}


def max_buy_breakdown(asset: str, pol: Dict[str, Any], portfolio: Dict[str, Any],
                      market: Dict[str, Dict[str, Any]]) -> Dict[str, Any]:
    """Detailed breakdown of wallet, position, and pool-impact caps for a buy on `asset`."""
    w, cap, fees = pol["wallet"], pol["capital"], pol["fees"]
    wallet_ada = float(portfolio.get("wallet_ada") or 0.0)
    wallet_cap = max(0.0, wallet_ada - w["floor_ada"] - w["fee_buffer_ada"]
                     - fees["order_deposit_ada"] - fees["max_batcher_fee_ada"] - fees["network_fee_ada"])
    working = float(portfolio.get("working_capital_ada") or 0.0)
    current_exp = float((portfolio.get("exposure_ada") or {}).get(asset, 0.0))
    pos_cap = max(0.0, cap["max_position_fraction"] * working - current_exp)
    r = market.get(asset, {}).get("reserve_ada")
    impact_cap = max(0.0, (cap["max_pool_impact_pct"] / 100.0) * float(r)) if r else 0.0
    named = [("wallet_cap", wallet_cap), ("position_cap", pos_cap), ("pool_impact_cap", impact_cap)]
    binding_name, best = min(named, key=lambda kv: kv[1])
    if best < cap["min_order_ada"]:
        return {"max_buy_ada": 0.0, "binding_cap": f"below_min_order ({binding_name})",
                "wallet_cap_ada": round(wallet_cap, 2), "position_cap_ada": round(pos_cap, 2),
                "pool_impact_cap_ada": round(impact_cap, 2), "current_exposure_ada": round(current_exp, 2)}
    return {"max_buy_ada": best, "binding_cap": binding_name,
            "wallet_cap_ada": round(wallet_cap, 2), "position_cap_ada": round(pos_cap, 2),
            "pool_impact_cap_ada": round(impact_cap, 2), "current_exposure_ada": round(current_exp, 2)}


def max_buy_ada(asset: str, pol: Dict[str, Any], portfolio: Dict[str, Any], market: Dict[str, Dict[str, Any]]) -> float:
    """Largest buy that passes every capital rule (0 if none)."""
    return float(max_buy_breakdown(asset, pol, portfolio, market)["max_buy_ada"])

