#!/usr/bin/env python3
"""
Sovereign Cardano Market Maker & Resting Limit Order Engine (Path D)
Calculates optimal maker spreads, bid-ask corridors, and resting limit orders
to accumulate ADA by providing passive liquidity rather than paying taker race fees.
"""

import sys
import os
import json
import time
import urllib.request
import logging
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Optional, Any

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)

from pycardano import (
    Transaction,
    TransactionWitnessSet,
    PaymentSigningKey,
    VerificationKeyWitness,
    BlockFrostChainContext,
    Network,
    TransactionBuilder,
    Address,
    RawPlutusData,
    datum_hash,
    ScriptDataHash,
)
import cbor2
from cbor2 import CBORTag
from pycardano.serialization import IndefiniteFrozenList, default_encoder
from nacl.hash import blake2b
from nacl.encoding import RawEncoder

def compute_conway_script_data_hash(pdata: Any) -> ScriptDataHash:
    """Computes canonical Cardano Conway era script_data_hash for datum-witnessed transactions."""
    datum_cbor = cbor2.dumps(pdata, default=default_encoder)
    raw = b"\xa0\x81" + datum_cbor + b"\xa0"
    return ScriptDataHash(blake2b(raw, 32, encoder=RawEncoder))

def mutate_datum_min_out(obj: Any, old_val: int, new_val: int) -> Any:
    """Type-preserving recursive Plutus datum mutator for resting limit orders."""
    if isinstance(obj, CBORTag):
        return CBORTag(obj.tag, mutate_datum_min_out(obj.value, old_val, new_val))
    elif isinstance(obj, IndefiniteFrozenList):
        return IndefiniteFrozenList([mutate_datum_min_out(x, old_val, new_val) for x in obj])
    elif isinstance(obj, list):
        return [mutate_datum_min_out(x, old_val, new_val) for x in obj]
    elif isinstance(obj, tuple):
        return tuple(mutate_datum_min_out(x, old_val, new_val) for x in obj)
    elif isinstance(obj, int) and obj == old_val:
        return new_val
    return obj

def to_plain(obj):
    if isinstance(obj, CBORTag):
        return CBORTag(obj.tag, to_plain(obj.value))
    elif isinstance(obj, (list, tuple)) or (hasattr(obj, '__iter__') and not isinstance(obj, (bytes, str, dict))):
        return [to_plain(x) for x in obj]
    elif isinstance(obj, dict):
        return {to_plain(k): to_plain(v) for k, v in obj.items()}
    return obj

from lib.tools.cardano_trader import query_wallet_balance, normalize_blockfrost_base_url
from lib.tools.cardano_dex_swapper import (
    estimate_swap_route,
    build_unsigned_swap_tx,
    build_direct_swap_tx,
    sign_and_submit_swap_tx,
    load_env_vars,
    TOKEN_METADATA,
    MINSWAP_AGGREGATOR_BASE,
)

for h in logging.root.handlers[:]:
    logging.root.removeHandler(h)
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", stream=sys.stderr)
logger = logging.getLogger("cardano_market_maker")

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path.home() / "blue-lodge"))
WALLET_KEY_FILE = LODGE_DIR / ".george" / "wallets" / "cardano_payment.skey"
STATUS_CACHE = LODGE_DIR / ".george" / "wallets" / "status_cache.json"

from lib.tools.cardano_volatility_engine import get_all_asset_volatilities

HARD_RESERVE_FLOOR_ADA = float(os.getenv("CARDANO_RESERVE_FLOOR_ADA", "40.00"))
MAKER_ROUNDTRIP_FRICTION_ADA = 3.96  # 2x 1.80 Batcher fee + 2x 0.18 L1 fee

TARGET_ASSETS = {
    "DJED": {
        "unit": "8db269c3ec630e06ae29f74bc39edd1f87c819f1056206e879a1cd61446a65644d6963726f555344",
        "decimals": 6,
        "typical_daily_range_pct": 3.5,
        "min_maker_spread_pct": 3.0,
        "batcher_fee_ada": 1.80,
        "lp_fee_pct": 0.30,
        "description": "Over-collateralized Algorithmic Stablecoin (Djed)",
    },
    "SNEK": {
        "unit": "279c909f348e533da5808898f87f9a14bb2c3dfbbacccd631d927a3f534e454b",
        "decimals": 0,
        "typical_daily_range_pct": 8.0,
        "min_maker_spread_pct": 4.5,
        "batcher_fee_ada": 1.80,
        "lp_fee_pct": 0.30,
        "description": "High-velocity Community Asset (Snek)",
    },
    "MIN": {
        "unit": "29d222ce763455e3d7a09a665ce554f00ac89d2e99a1a83d267170c64d494e",
        "decimals": 6,
        "typical_daily_range_pct": 6.0,
        "min_maker_spread_pct": 4.0,
        "batcher_fee_ada": 1.80,
        "lp_fee_pct": 0.30,
        "description": "Minswap Governance Token",
    },
    "WMTX": {
        "unit": "e5a42a1a1d3d1da71b0449663c32798725888d2eb0843c4dabeca05a576f726c644d6f62696c65546f6b656e58",
        "decimals": 6,
        "typical_daily_range_pct": 5.0,
        "min_maker_spread_pct": 3.5,
        "batcher_fee_ada": 1.80,
        "lp_fee_pct": 0.30,
        "description": "World Mobile Token (Telecom dePIN)",
    },
    "IAG": {
        "unit": "5d16cc1a177b5d9ba9cfa9793b07e60f1fb70fea1f8aef064415d114494147",
        "decimals": 6,
        "typical_daily_range_pct": 7.5,
        "min_maker_spread_pct": 4.0,
        "batcher_fee_ada": 1.80,
        "lp_fee_pct": 0.30,
        "description": "Iagon Decentralized Cloud Storage",
    },
    "NIGHT": {
        "unit": "0691b2fecca1ac4f53cb6dfb00b7013e561d1f34403b957cbb5af1fa4e49474854",
        "decimals": 6,
        "typical_daily_range_pct": 8.5,
        "min_maker_spread_pct": 4.5,
        "batcher_fee_ada": 1.80,
        "lp_fee_pct": 0.30,
        "description": "Midnight Privacy Token (Partner Chain)",
    },
    "USDM": {
        "unit": "c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad0014df105553444d",
        "decimals": 6,
        "typical_daily_range_pct": 2.5,
        "min_maker_spread_pct": 2.5,
        "batcher_fee_ada": 1.80,
        "lp_fee_pct": 0.30,
        "description": "Fiat-Backed Sovereign Stablecoin (Moneta USDM)",
    },
    "USDCX": {
        "unit": "1f3aec8bfe7ea4fe14c5f121e2a92e301afe414147860d557cac7e345553444378",
        "decimals": 6,
        "typical_daily_range_pct": 2.5,
        "min_maker_spread_pct": 2.5,
        "batcher_fee_ada": 1.80,
        "lp_fee_pct": 0.30,
        "description": "Circle xReserve Compliant Stablecoin (USDCx)",
    },
    "HOSKY": {
        "unit": "a0028f350aaabe0545fdcb56b039bfb08e4bb4d8c4d7c3c7d481c235484f534b59",
        "decimals": 0,
        "typical_daily_range_pct": 12.0,
        "min_maker_spread_pct": 6.0,
        "batcher_fee_ada": 1.80,
        "lp_fee_pct": 0.30,
        "description": "Premiere Cardano Meme Asset (Hosky Token)",
    },
}

# Units/decimals come from the canonical registry (lib/tools/quant/tokens.py). The literal
# values above are kept only for readability; the registry overrides them so a typo here
# (as happened with MIN) can never reach an order or a price query.
from lib.tools.quant import tokens as _tokens  # noqa: E402
for _sym, _cfg in TARGET_ASSETS.items():
    _cfg["unit"] = _tokens.unit(_sym)
    _cfg["decimals"] = _tokens.decimals(_sym)


def get_dynamic_friction(asset: str, capital_ada: float) -> dict[str, float]:
    """
    Computes exact on-chain friction for a 2-leg resting limit order cycle:
    2x Batcher Protocol Fee + 2x L1 Tx Fee + 2x AMM LP Swap Fee.
    """
    sym = asset.upper()
    cfg = TARGET_ASSETS.get(sym, {})
    batcher_fee_single = cfg.get("batcher_fee_ada", 1.80)
    l1_tx_fee_single = 0.174
    lp_fee_pct = cfg.get("lp_fee_pct", 0.30)
    lp_fee_roundtrip_ada = (capital_ada * (lp_fee_pct / 100.0)) * 2.0
    total_fixed_ada = (batcher_fee_single * 2.0) + (l1_tx_fee_single * 2.0)
    total_friction_ada = total_fixed_ada + lp_fee_roundtrip_ada

    return {
        "batcher_fee_single_ada": batcher_fee_single,
        "l1_tx_fee_single_ada": l1_tx_fee_single,
        "fixed_friction_ada": round(total_fixed_ada, 3),
        "lp_fee_pct": lp_fee_pct,
        "lp_fee_roundtrip_ada": round(lp_fee_roundtrip_ada, 3),
        "total_roundtrip_friction_ada": round(total_friction_ada, 3),
    }


def _round_price(p: float) -> float:
    if p <= 0:
        return 0.0
    if p < 0.0001:
        return float(f"{p:.4g}")
    return round(p, 6)


def _format_price(p: float) -> str:
    if p < 0.0001:
        return f"{p:.4e}"
    return f"{p:.6f}"


@dataclass
class MakerOpportunity:
    asset: str
    spot_price_ada: float
    bid_target_ada: float        # Price we place resting buy order
    ask_target_ada: float        # Price we place resting sell order
    maker_spread_pct: float      # Total corridor captured between bid and ask
    capital_allocation_ada: float
    gross_yield_ada: float
    friction_ada: float
    net_maker_profit_ada: float
    net_roi_pct: float
    is_profitable: bool
    status: str
    tactical_rationale: str
    trend_regime: str = "NORMAL_CORRIDOR"
    velocity_4h_pct: float = 0.5
    slide_action: str = "ALLOW"
    has_active_cycle: bool = False
    horizon: str = "4h"
    horizon_sigma_pct: float = 2.11
    est_fill_duration_hours: float = 4.0
    min_capital_needed_ada: float = 120.0
    recommended_horizon: str = "4h"
    batcher_fee_ada: float = 1.80
    l1_tx_fee_ada: float = 0.174
    lp_fee_pct: float = 0.30


def fetch_asset_trend_velocity(asset: str, spot_price: float, vol_data_all: Optional[dict] = None) -> dict[str, Any]:
    """
    Evaluates 4-hour price velocity and volatility to defend against structural slides.
    Returns trend status, 4h price change estimate, and slide action policy.
    """
    sym = asset.upper()
    cfg = TARGET_ASSETS.get(sym, {})
    if vol_data_all is None:
        try:
            vol_data_all = get_all_asset_volatilities()
        except Exception:
            vol_data_all = {}

    asset_profile = vol_data_all.get("assets", {}).get(sym, {})
    velocity_4h = asset_profile.get("velocity_4h_pct")

    if velocity_4h is None or asset_profile.get("status") not in ("live", None):
        # Fail closed: without live momentum data we cannot rule out a slide.
        velocity_4h = 0.0
        action = "HARD_PAUSE"
        regime = "DATA_UNAVAILABLE"
        desc = "Live ADA-quoted momentum data unavailable for this asset; buy bids paused until data returns."
    elif velocity_4h < -4.5:
        action = "HARD_PAUSE"
        regime = "SLIDE_ALERT"
        desc = f"4-hour price velocity ({velocity_4h:+.1f}%) exceeds -4.5% slide threshold. Hard pause on buy bids to avoid falling knives."
    elif velocity_4h < -1.5:
        action = "DEEP_DISCOUNT"
        regime = "DOWNSIDE_MOMENTUM_SKEW"
        desc = f"4-hour momentum is down ({velocity_4h:+.1f}%). Applying asymmetric skew: deeper buy discount and lower exit hurdle."
    else:
        action = "ALLOW"
        regime = "NORMAL_CORRIDOR"
        desc = "Normal mean-reverting corridor volatility."

    return {
        "asset": sym,
        "velocity_4h_pct": velocity_4h,
        "regime": regime,
        "slide_action": action,
        "rationale": desc,
        "volatility_profile": asset_profile.get("dispersion_pct", {}),
    }


def check_single_leg_inventory(asset: str) -> bool:
    """Returns True if asset is already held or in active buy/sell state (enforcing Single-Leg Rule)."""
    try:
        from lib.tools.cardano_maker_db import get_db_connection
        with get_db_connection() as conn:
            cur = conn.execute(
                "SELECT id FROM maker_orders WHERE asset = ? AND status IN ('PENDING_BUY', 'INVENTORY_HOLD', 'PENDING_SELL')",
                (asset.upper(),),
            )
            return cur.fetchone() is not None
    except Exception as e:
        # Fail closed: if the ledger cannot be read we must assume a cycle may be active.
        logger.warning(f"Single-leg inventory check failed for {asset} ({e}); treating as active.")
        return True


def fetch_live_spot_prices(capital_sample_ada: float = 20.0, target_asset: Optional[str] = None) -> dict[str, float]:
    """Fetches real-time reference prices in ADA across Cardano target assets (or single target_asset)."""
    prices = {}
    items = [(target_asset.upper(), TARGET_ASSETS[target_asset.upper()])] if (target_asset and target_asset.upper() in TARGET_ASSETS) else TARGET_ASSETS.items()
    for sym, cfg in items:
        try:
            est, _ = estimate_swap_route(int(capital_sample_ada * 1_000_000), "ADA", sym)
            raw_out = int(est.get("amount_out", 0))
            dec = cfg["decimals"]
            tok_out = raw_out / (10 ** dec)
            if tok_out > 0:
                prices[sym] = capital_sample_ada / tok_out
            if len(items) > 1:
                time.sleep(0.15)
        except Exception as e:
            logger.warning(f"Failed to fetch reference spot price for {sym}: {e}")
    return prices


def evaluate_maker_corridors(
    spendable_ada: float,
    capital_override: Optional[float] = None,
    horizon: str = "auto",
) -> list[MakerOpportunity]:
    """
    Evaluates maker profitability across target assets using Parkinson Multi-Horizon Volatility,
    dynamic DEX batcher friction, and the Capital Feasibility Solver.
    """
    alloc_ada = capital_override or min(120.0, max(30.0, spendable_ada * 0.35))
    spot_prices = fetch_live_spot_prices()
    try:
        vol_data_all = get_all_asset_volatilities()
    except Exception as e:
        logger.warning(f"Could not fetch live volatility matrix ({e}); using baseline.")
        vol_data_all = {}

    opportunities: list[MakerOpportunity] = []
    horizon_hierarchy = ["30m", "1h", "2h", "4h", "8h", "24h"]
    est_durations = {
        "30m": 0.75,
        "1h": 1.5,
        "2h": 3.0,
        "4h": 6.0,
        "8h": 12.0,
        "24h": 24.0,
    }

    for sym, cfg in TARGET_ASSETS.items():
        spot = spot_prices.get(sym, 0.0)
        if spot <= 0:
            continue

        trend_data = fetch_asset_trend_velocity(sym, spot, vol_data_all)
        has_active = check_single_leg_inventory(sym)
        vol_profile = trend_data.get("volatility_profile", {})

        # Select target horizon: if "auto", find the fastest horizon that is profitable
        chosen_horizon = horizon.lower()
        if chosen_horizon not in horizon_hierarchy:
            chosen_horizon = "auto"

        if chosen_horizon == "auto":
            best_h = "24h"
            for h_candidate in horizon_hierarchy:
                sigma_c = vol_profile.get(h_candidate)
                if sigma_c is None:
                    continue  # no live estimate for this horizon; never substitute a guess
                spread_c = sigma_c * 2.0 * 1.05
                f_data_c = get_dynamic_friction(sym, alloc_ada)
                g_yield_c = alloc_ada * (spread_c / 100.0)
                n_profit_c = g_yield_c - f_data_c["total_roundtrip_friction_ada"]
                if n_profit_c >= 0.50:
                    best_h = h_candidate
                    break
            chosen_horizon = best_h

        # Microstructure Defensible Spread & Friction Floor
        friction_data = get_dynamic_friction(sym, alloc_ada)
        total_friction_ada = friction_data["total_roundtrip_friction_ada"]
        fixed_friction_ada = friction_data["fixed_friction_ada"]

        # Minimum defensible spread hurdle to guarantee net positive return
        min_defensible_spread_pct = ((fixed_friction_ada + 0.50) / alloc_ada) * 100.0 + (2.0 * friction_data["lp_fee_pct"])

        # Compute Parkinson corridor spread for the chosen horizon, bounded by defensible floor
        sigma_live = vol_profile.get(chosen_horizon)
        vol_unavailable = sigma_live is None
        # Display-only placeholder when data is missing; is_profitable is forced False below.
        sigma_pct = float(sigma_live) if not vol_unavailable else 0.0
        raw_parkinson_spread = sigma_pct * 2.0 * 1.05
        corridor_spread_pct = max(min_defensible_spread_pct, raw_parkinson_spread)
        half_pct = (corridor_spread_pct / 2.0) / 100.0

        # Asymmetric Trend Skewing (Model 3)
        vel = trend_data["velocity_4h_pct"]
        if trend_data["slide_action"] == "DEEP_DISCOUNT":
            vel_mag = abs(vel)
            bid_skew = 1.0 + min(0.35, vel_mag / 10.0)
            ask_skew = max(0.65, 1.0 - (vel_mag / 15.0))
        else:
            bid_skew = 1.0
            ask_skew = 1.0

        bid_price = spot * (1.0 - (half_pct * bid_skew))
        ask_price = spot * (1.0 + (half_pct * ask_skew))
        total_spread_pct = ((ask_price - bid_price) / bid_price) * 100.0

        # P&L Calculation with Defensible Parameters
        gross_yield = alloc_ada * (total_spread_pct / 100.0)
        net_profit = gross_yield - total_friction_ada
        net_roi = (net_profit / alloc_ada) * 100.0

        # Solves minimum capital required for this horizon to beat friction
        denom = max(0.001, (total_spread_pct / 100.0) - (2.0 * (friction_data["lp_fee_pct"] / 100.0)))
        min_needed_cap = (friction_data["fixed_friction_ada"] + 0.50) / denom

        # Find fastest recommended horizon if current is unviable
        recommended_h = chosen_horizon
        for h_rec in horizon_hierarchy:
            sig_rec = vol_profile.get(h_rec)
            if sig_rec is None:
                continue
            spr_rec = max(min_defensible_spread_pct, sig_rec * 2.0 * 1.05)
            if alloc_ada * (spr_rec / 100.0) - total_friction_ada >= 0.50:
                recommended_h = h_rec
                break

        # Ornstein-Uhlenbeck Mean-Reversion Guard
        asset_profile = vol_data_all.get("assets", {}).get(sym, {})
        ou_stats = asset_profile.get("ornstein_uhlenbeck", {})
        # Fail closed: a missing mean-reversion verdict means bids are NOT permitted.
        is_mean_reverting = bool(ou_stats.get("is_mean_reverting", False))
        ou_verdict = ou_stats.get("verdict", "")
        ou_half_life = ou_stats.get("half_life_hours", 6.0)

        is_profitable = (net_profit >= 0.50) and (not has_active) and (trend_data["slide_action"] != "HARD_PAUSE") and is_mean_reverting

        if vol_unavailable:
            is_profitable = False
        if vol_unavailable and not has_active:
            status = "VOL_UNAVAILABLE (PAUSED)"
            desc = f"No live {chosen_horizon} volatility estimate for {sym}; corridor not computed and bids paused (no fabricated fallback)."
        elif has_active:
            status = "INVENTORY_HOLD (SELL ONLY)"
            desc = f"Single-Leg Rule active: {sym} inventory already held in cycle. Buy bids locked to prevent adverse inventory accumulation."
            is_profitable = False
        elif not is_mean_reverting or ou_verdict == "ADVERSE_SELECTION_ALERT_DO_NOT_PLACE_BIDS":
            status = "OU_NON_STATIONARY (PAUSED)"
            desc = f"Ornstein-Uhlenbeck rejects mean reversion (half-life {ou_half_life}h, explosive/trending drift). Buy bids locked against adverse selection."
            is_profitable = False
        elif trend_data["slide_action"] == "HARD_PAUSE":
            status = "SLIDE_ALERT (PAUSED)"
            desc = trend_data["rationale"]
            is_profitable = False
        elif is_profitable:
            status = f"★ VIABLE ({chosen_horizon.upper()})"
            desc = (
                f"Horizon [{chosen_horizon.upper()}]: ±{sigma_pct:.2f}% Parkinson volatility. "
                f"Resting BUY @ {_format_price(bid_price)} ADA, SELL @ {_format_price(ask_price)} ADA (+{total_spread_pct:.1f}% corridor). "
                f"Gross: +{gross_yield:.2f} ADA clears {total_friction_ada:.2f} ADA dynamic friction (Net: +{net_profit:.2f} ADA)."
            )
        else:
            status = f"EXPAND SIZING OR HORIZON ({chosen_horizon.upper()})"
            desc = (
                f"Horizon [{chosen_horizon.upper()}] volatility is ±{sigma_pct:.2f}% (+{total_spread_pct:.2f}% corridor). "
                f"Allocation of {alloc_ada:.1f} ADA yields +{gross_yield:.2f} ADA, below dynamic friction of {total_friction_ada:.2f} ADA. "
                f"Needs {min_needed_cap:.0f} ADA capital for {chosen_horizon.upper()} or switch to {recommended_h.upper()} horizon."
            )

        opp = MakerOpportunity(
            asset=sym,
            spot_price_ada=_round_price(spot),
            bid_target_ada=_round_price(bid_price),
            ask_target_ada=_round_price(ask_price),
            maker_spread_pct=round(total_spread_pct, 2),
            capital_allocation_ada=round(alloc_ada, 2),
            gross_yield_ada=round(gross_yield, 3),
            friction_ada=total_friction_ada,
            net_maker_profit_ada=round(net_profit, 3),
            net_roi_pct=round(net_roi, 2),
            is_profitable=is_profitable,
            status=status,
            tactical_rationale=desc,
            trend_regime=trend_data["regime"],
            velocity_4h_pct=trend_data["velocity_4h_pct"],
            slide_action=trend_data["slide_action"],
            has_active_cycle=has_active,
            horizon=chosen_horizon,
            horizon_sigma_pct=round(sigma_pct, 2),
            est_fill_duration_hours=est_durations.get(chosen_horizon, 4.0),
            min_capital_needed_ada=round(min_needed_cap, 1),
            recommended_horizon=recommended_h,
            batcher_fee_ada=friction_data["batcher_fee_single_ada"],
            l1_tx_fee_ada=friction_data["l1_tx_fee_single_ada"],
            lp_fee_pct=friction_data["lp_fee_pct"],
        )
        opportunities.append(opp)

    return sorted(opportunities, key=lambda x: x.net_maker_profit_ada, reverse=True)


def query_pending_orders(owner_addr: Optional[str] = None) -> list[dict[str, Any]]:
    """Queries live active resting orders on Cardano DEX order scripts for the specified wallet address."""
    env = load_env_vars()
    addr = owner_addr or env.get("CARDANO_WALLET_ADDR", "")
    if not addr:
        logger.warning("CARDANO_WALLET_ADDR is not set; no pending orders to query")
        return []
    orders = []

    # 1. Try external Minswap aggregator API (skip in isolated test mode)
    if os.environ.get("CARDANO_TEST_MODE") != "1":
        url = f"{MINSWAP_AGGREGATOR_BASE}/pending-orders?owner_address={addr}"
        req = urllib.request.Request(url, headers={"User-Agent": "BlueLodge-SovereignSwapper/1.0"})
        try:
            with urllib.request.urlopen(req, timeout=6) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                orders = data.get("orders", [])
        except Exception as e:
            logger.warning(f"Failed to query pending orders from Minswap API ({e})")

    # 2. Sovereign Local Ledger & Blockfrost Fallback
    if not orders:
        try:
            from lib.tools.cardano_maker_db import get_active_cycles
            cycles = get_active_cycles()
            for c in cycles:
                if c.get("status") in ("PENDING_BUY", "PENDING_SELL"):
                    active_tx = (c.get("sell_tx_id") or c.get("tx_id")) if c.get("status") == "PENDING_SELL" else c.get("tx_id")
                    is_sell = c.get("status") == "PENDING_SELL" or c.get("direction") == "SELL"
                    tokens_held = float(c.get("tokens_filled", 0) or c.get("tokens_target", 0))
                    sell_target = float(c.get("sell_target_ada", 0) or (c.get("capital_ada", 0) if is_sell else 0))
                    calc_price = round(sell_target / tokens_held, 6) if (is_sell and tokens_held > 0 and sell_target > 0) else c.get("target_price_ada")

                    target_recv_str = f"{sell_target:.2f} ADA ({calc_price:.6f} ADA/{c.get('asset')})" if is_sell else f"{float(c.get('tokens_target', 0)):,.4f} {c.get('asset')}"
                    locked_cap_str = f"4.0 ADA + {tokens_held:,.4f} {c.get('asset')}" if is_sell else f"{c.get('capital_ada')} ADA"

                    orders.append({
                        "order_id": c.get("order_id"),
                        "tx_in": f"{active_tx}#0" if active_tx else c.get("order_id"),
                        "asset": c.get("asset"),
                        "direction": "SELL" if is_sell else "BUY",
                        "locked_ada": 4.0 if is_sell else c.get("capital_ada"),
                        "locked_capital_display": locked_cap_str,
                        "target_receive_display": target_recv_str,
                        "sell_target_ada": sell_target if is_sell else None,
                        "expected_tokens": tokens_held if is_sell else c.get("tokens_target"),
                        "target_price_ada": calc_price,
                        "order_script": c.get("order_script_addr"),
                        "status": c.get("status"),
                        "created_at": c.get("created_at"),
                    })
        except Exception as e:
            logger.warning(f"Failed to query local maker_orders.db: {e}")

    return orders


def simulate_limit_order(
    asset: str,
    capital_ada: float = 35.0,
    limit_discount_pct: float = 2.5,
    direction: str = "buy",
) -> dict[str, Any]:
    """Simulates placement of a resting limit order without submitting to chain."""
    sym = asset.upper()
    cfg = TARGET_ASSETS.get(sym, {"decimals": 6, "min_maker_spread_pct": 4.0})
    dec = cfg.get("decimals", 6)

    # 1. Fetch live reference quote
    amt_in_base = int(capital_ada * 1_000_000)
    est, _ = estimate_swap_route(amt_in_base, "ADA", sym)
    raw_est_out = int(est.get("amount_out", 0))
    spot_tokens = raw_est_out / (10 ** dec)
    spot_price_ada = capital_ada / spot_tokens if spot_tokens > 0 else 0.0

    batcher_fee_lovelace = int(est.get("total_dex_fee", 2000000))
    batcher_fee_ada = batcher_fee_lovelace / 1_000_000
    refundable_deposit_ada = 2.00
    estimated_tx_fee_ada = 0.18

    if direction.lower() == "buy":
        limit_tokens = int(raw_est_out * (1.0 + (limit_discount_pct / 100.0)))
        human_limit_tokens = limit_tokens / (10 ** dec)
        limit_price_ada = capital_ada / human_limit_tokens if human_limit_tokens > 0 else 0.0
        gross_yield_ada = capital_ada * (limit_discount_pct / 100.0)
    else:
        limit_tokens = int(raw_est_out * (1.0 - (limit_discount_pct / 100.0)))
        human_limit_tokens = limit_tokens / (10 ** dec)
        limit_price_ada = capital_ada / human_limit_tokens if human_limit_tokens > 0 else 0.0
        gross_yield_ada = capital_ada * (limit_discount_pct / 100.0)

    total_locked_ada = capital_ada + batcher_fee_ada + refundable_deposit_ada
    cycle_gross_profit = gross_yield_ada * 2.0
    net_cycle_profit = cycle_gross_profit - MAKER_ROUNDTRIP_FRICTION_ADA

    return {
        "status": "simulated",
        "asset": sym,
        "direction": direction.lower(),
        "capital_in_ada": capital_ada,
        "spot_price_ada": _round_price(spot_price_ada),
        "spot_tokens_out": round(spot_tokens, 4),
        "limit_price_ada": _round_price(limit_price_ada),
        "limit_tokens_out": round(human_limit_tokens, 4),
        "limit_spread_pct": limit_discount_pct,
        "refundable_deposit_ada": refundable_deposit_ada,
        "batcher_fee_ada": batcher_fee_ada,
        "estimated_tx_fee_ada": estimated_tx_fee_ada,
        "total_locked_ada": round(total_locked_ada, 2),
        "gross_yield_ada": round(gross_yield_ada, 3),
        "net_profit_cycle_ada": round(net_cycle_profit, 3),
        "is_profitable_cycle": net_cycle_profit >= 0.50,
        "direct_savings_ada": 0.85,
    }


def build_resting_limit_order_tx(
    asset: str,
    capital_ada: float = 35.0,
    limit_discount_pct: float = 2.5,
    direction: str = "buy",
    tokens: Optional[float] = None,
    target_price: Optional[float] = None,
    dry_run: bool = True,
    parent_order_id: Optional[str] = None,
    actor: str = "george",
    allow_collision: bool = False,
) -> dict[str, Any]:
    """Places a true resting limit order as a native Minswap V2 SwapExactIn order (no expiry).

    Replaces the previous approach of mutating the aggregator's swap tx, which could land on
    any venue (our IAG order became a WingRiders request with a deadline and could never fill).
    The native builder validates owner, min-receive, deadline and datum shape before signing.
    """
    from lib.tools.minswap_v2 import place_limit_order, find_pool

    sym = asset.upper()
    is_sell = direction.lower() == "sell"
    bal = query_wallet_balance()
    spendable = bal.get("spendable_ada", 0.0)
    pool = find_pool(sym)
    spot = float(pool["price_ada"])

    if is_sell:
        if tokens is None or tokens <= 0:
            tokens = float(bal.get("assets", {}).get(sym, 0.0))
            if tokens <= 0:
                try:
                    cdata = json.loads(STATUS_CACHE.read_text())
                    tokens = float(cdata.get("cardano", {}).get("assets", {}).get(sym, 0.0))
                except Exception:
                    pass
        if tokens <= 0:
            raise ValueError(f"No {sym} tokens available in wallet to place sell limit order.")
        price = target_price if target_price and target_price > 0 else spot * (1 + limit_discount_pct / 100.0)
        amount = tokens
    else:
        total_ada = bal.get("total_ada", spendable + HARD_RESERVE_FLOOR_ADA)
        if not dry_run and total_ada - capital_ada - 4.0 < HARD_RESERVE_FLOOR_ADA:
            raise ValueError(
                f"Limit order capital ({capital_ada} ADA + 4 ADA deposit/fee) breaches reserve floor "
                f"({HARD_RESERVE_FLOOR_ADA} ADA). Total: {total_ada:.2f} ADA"
            )
        price = target_price if target_price and target_price > 0 else spot * (1 - limit_discount_pct / 100.0)
        amount = capital_ada / price

    res = place_limit_order(sym, "sell" if is_sell else "buy", amount, price, execute=not dry_run,
                            actor=actor, parent_order_id=parent_order_id, force_collision=allow_collision)
    if res.get("status") != "ok":
        raise ValueError(res.get("message", "limit order build failed"))
    res.update({
        "status": "success",
        "capital_ada": round(amount * price, 6),
        "tokens": amount,
        "target_val": res["min_receive_base_units"],
        "limit_discount_pct": limit_discount_pct,
        "tx_fee_ada": round(res["fee_ada"], 4),
        "aggregator_fee_saved_ada": 0.85,
        "order_script": res["order_address"],
        "locked_output_ada": round(res["locked_lovelace"] / 1_000_000, 2),
        "message": (f"Resting {'SELL' if is_sell else 'BUY'} limit order "
                    f"{'simulated' if dry_run else 'placed on-chain'} on MinswapV2 at {price:.6f} ADA "
                    f"(spot {spot:.6f})."),
    })
    return res


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Sovereign Cardano Market Maker Engine (Path D)")
    parser.add_argument("--scan", action="store_true", help="Scan live assets for profitable maker corridors")
    parser.add_argument("--simulate", action="store_true", help="Simulate placement of a resting limit order")
    parser.add_argument("--place", action="store_true", help="Build and submit direct resting limit order")
    parser.add_argument("--orders", action="store_true", help="Query live active resting orders on chain")
    parser.add_argument("--asset", type=str, default="SNEK", help="Target asset symbol (e.g. SNEK, MIN, WMTX, DJED, IAG)")
    parser.add_argument("--capital", type=float, default=None, help="Capital allocation in ADA to evaluate or trade")
    parser.add_argument("--horizon", type=str, default="auto", choices=["auto", "30m", "1h", "2h", "4h", "8h", "24h"], help="Execution horizon / target sell-through rate")
    parser.add_argument("--discount", type=float, default=2.5, help="Corridor discount percentage (default: 2.5%%)")
    parser.add_argument("--direction", type=str, default="buy", choices=["buy", "sell"], help="Order direction")
    parser.add_argument("--tokens", type=float, default=None, help="Token quantity for sell leg")
    parser.add_argument("--target-price", type=float, default=None, help="Target limit price in ADA per token")
    parser.add_argument("--actor", type=str, default="george", choices=["george", "operator"], help="Actor attribution for policy checks (default: 'george')")
    parser.add_argument("--dry-run", action="store_true", default=True, help="Dry run mode (default: True)")
    parser.add_argument("--execute", action="store_true", help="Execute live transaction on Cardano Mainnet")
    parser.add_argument("--json", action="store_true", help="Output pure JSON")
    args = parser.parse_args()

    bal = query_wallet_balance()
    spendable_ada = bal.get("spendable_ada", 189.4)
    total_ada = bal.get("total_ada", 199.4)

    if args.orders:
        orders = query_pending_orders()
        if args.json:
            print(json.dumps({"status": "ok", "orders": orders, "count": len(orders)}, indent=2))
        else:
            print(f"Active resting orders on-chain: {len(orders)}")
            for o in orders:
                print(f"  Order: {o}")
        return

    if args.simulate:
        cap = args.capital or min(120.0, max(30.0, spendable_ada * 0.35))
        sim = simulate_limit_order(args.asset, capital_ada=cap, limit_discount_pct=args.discount, direction=args.direction)
        if args.json:
            print(json.dumps(sim, indent=2))
        else:
            print(f"=== SIMULATED RESTING LIMIT ORDER ({sim['asset']}) ===")
            print(f"  Direction: {sim['direction'].upper()} | Capital: {sim['capital_in_ada']} ADA")
            print(f"  Spot Price: {sim['spot_price_ada']:.6f} ADA | Limit Target: {sim['limit_price_ada']:.6f} ADA ({sim['limit_spread_pct']:+.1f}%)")
            print(f"  Tokens Out: {sim['limit_tokens_out']} {sim['asset']} (vs {sim['spot_tokens_out']} at spot)")
            print(f"  Deposit: {sim['refundable_deposit_ada']} ADA (Refundable) | Batcher Fee: {sim['batcher_fee_ada']} ADA | Tx Fee: ~{sim['estimated_tx_fee_ada']} ADA")
            print(f"  Cycle Net Margin: {sim['net_profit_cycle_ada']:+.3f} ADA | Viable: {sim['is_profitable_cycle']}")
        return

    if args.place:
        cap = args.capital or min(120.0, max(30.0, spendable_ada * 0.35))
        is_dry = not args.execute
        res = build_resting_limit_order_tx(
            asset=args.asset,
            capital_ada=cap,
            limit_discount_pct=args.discount,
            direction=args.direction,
            tokens=args.tokens,
            target_price=args.target_price,
            dry_run=is_dry,
            actor=args.actor,
        )
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            mode_str = "DRY-RUN" if is_dry else "LIVE"
            print(f"=== RESTING LIMIT ORDER [{mode_str}] ===")
            print(f"  Tx ID: {res['tx_id']}")
            print(f"  Direction: {res['direction'].upper()} | Asset: {res['asset']} | Capital: {res['capital_ada']} ADA")
            print(f"  L1 Tx Fee: {res['tx_fee_ada']} ADA | Aggregator Fee Saved: {res['aggregator_fee_saved_ada']} ADA")
            print(f"  Status: {res['message']}")
        return

    # Default to scanning corridors with dynamic quant models
    opps = evaluate_maker_corridors(spendable_ada, capital_override=args.capital, horizon=args.horizon)

    if args.json:
        res = {
            "status": "ok",
            "timestamp": int(time.time()),
            "horizon_requested": args.horizon,
            "wallet": {
                "total_ada": total_ada,
                "spendable_ada": spendable_ada,
            },
            "corridors": [asdict(o) for o in opps],
        }
        print(json.dumps(res, indent=2))
        return

    print("=" * 105)
    print("  SOVEREIGN CARDANO RESTING LIMIT ORDER & QUANT MARKET MAKER ENGINE (PATH D)")
    print("=" * 105)
    print(f"  Treasury: {total_ada:.2f} ADA Total | {spendable_ada:.2f} ADA Spendable | Horizon Policy: [{args.horizon.upper()}]")
    print("-" * 105)
    print(f"  {'ASSET':<6} {'SPOT':<10} {'BID (BUY)':<12} {'ASK (SELL)':<12} {'SPREAD':<8} {'HORIZON':<8} {'EST DURATION':<14} {'NET PROFIT':<12} {'STATUS'}")
    print("-" * 105)
    for o in opps:
        color = "\033[1;32m" if o.is_profitable else "\033[0;33m"
        rst = "\033[0m"
        est_str = f"~{o.est_fill_duration_hours:.1f}h"
        print(f"  {o.asset:<6} {o.spot_price_ada:<10.6f} {o.bid_target_ada:<12.6f} {o.ask_target_ada:<12.6f} +{o.maker_spread_pct:>4.1f}%   {o.horizon.upper():<8} {est_str:<14} {color}{o.net_maker_profit_ada:>+6.3f} ADA{rst}   {o.status}")
    print("=" * 105)
    print("  Quant Guidance: Corridors dynamically calibrated via Parkinson volatility on rolling OHLCV.")
    print("  Execution horizons dynamically optimize between rapid fill velocity and friction clearance.")
    print("=" * 105 + "\n")


if __name__ == "__main__":
    main()
