#!/usr/bin/env python3
"""
Open Cardano Rails shared helpers (pure chain/AMM utilities, zero proprietary alpha).
Provides:
  - HARD_RESERVE_FLOOR_ADA (40.0 ADA reserve constant)
  - query_wallet_balance() (live UTxO balance & multi-asset summary)
  - get_ada_macro_stats() (CoinGecko ADA/USD macro spot + 24h change)
  - verify_pool_batcher_liveness() (AMM pool NFT activity check)
  - compute_cpmm_arb_metrics() (constant-product AMM slippage & hurdle geometry)
"""
from __future__ import annotations

import json
import logging
import math
import os
import threading
import time
from pathlib import Path
from typing import Any, Dict, Optional

logger = logging.getLogger("cardano_rails_helpers")

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path.home() / "blue-lodge"))
GEORGE_DIR = Path(os.environ.get("GEORGE_DIR", LODGE_DIR / ".george"))

HARD_RESERVE_FLOOR_ADA: float = 40.0
RESERVE_FLOOR_LOVELACE: int = int(HARD_RESERVE_FLOOR_ADA * 1_000_000)
MAX_POOL_BATCH_AGE_H: float = 24.0
POOL_LIVENESS_CACHE = GEORGE_DIR / "finance" / "pool_liveness_cache.json"
_LIVENESS_LOCK = threading.Lock()
_LIVENESS_MEM: Dict[str, Any] = {}

TARGET_ASSETS: Dict[str, Dict[str, Any]] = {
    "DJED":  {"decimals": 6, "batcher_fee_ada": 1.80, "lp_fee_pct": 0.30, "description": "Djed Algorithmic Stablecoin"},
    "SNEK":  {"decimals": 0, "batcher_fee_ada": 1.80, "lp_fee_pct": 0.30, "description": "Snek Community Token"},
    "MIN":   {"decimals": 6, "batcher_fee_ada": 1.80, "lp_fee_pct": 0.30, "description": "Minswap Governance Token"},
    "WMTX":  {"decimals": 6, "batcher_fee_ada": 1.80, "lp_fee_pct": 0.30, "description": "World Mobile Token"},
    "IAG":   {"decimals": 6, "batcher_fee_ada": 1.80, "lp_fee_pct": 0.30, "description": "Iagon Decentralized Cloud Storage"},
    "NIGHT": {"decimals": 6, "batcher_fee_ada": 1.80, "lp_fee_pct": 0.30, "description": "Midnight Privacy Token"},
    "USDM":  {"decimals": 6, "batcher_fee_ada": 1.80, "lp_fee_pct": 0.30, "description": "Moneta USDM Stablecoin"},
    "USDCX": {"decimals": 6, "batcher_fee_ada": 1.80, "lp_fee_pct": 0.30, "description": "Circle xReserve USDCx"},
    "HOSKY": {"decimals": 0, "batcher_fee_ada": 1.80, "lp_fee_pct": 0.30, "description": "Hosky Token"},
}
try:
    from lib.tools.quant import tokens as _qtokens
    for _sym, _cfg in TARGET_ASSETS.items():
        _cfg["unit"] = _qtokens.unit(_sym)
        _cfg["decimals"] = _qtokens.decimals(_sym)
except Exception:
    pass


_TEST_MODE_SPOTS: Dict[str, float] = {
    "SNEK": 0.00335,
    "MIN": 0.042,
    "NIGHT": 0.195,
    "IAG": 0.18,
    "WMTX": 0.42,
    "DJED": 2.85,
    "USDM": 2.85,
    "USDCX": 2.85,
    "HOSKY": 0.000000045,
}


def fetch_live_spot_prices(
    capital_sample_ada: float = 20.0,
    target_asset: Optional[str] = None,
) -> Dict[str, float]:
    """Fetch reference spot prices in ADA via Minswap Aggregator (with offline test-mode defaults)."""
    if os.environ.get("CARDANO_TEST_MODE") == "1":
        if target_asset:
            sym = target_asset.upper()
            return {sym: _TEST_MODE_SPOTS[sym]} if sym in _TEST_MODE_SPOTS else {}
        return dict(_TEST_MODE_SPOTS)

    from lib.tools.cardano_dex_swapper import estimate_swap_route

    prices: Dict[str, float] = {}
    items = (
        [(target_asset.upper(), TARGET_ASSETS[target_asset.upper()])]
        if (target_asset and target_asset.upper() in TARGET_ASSETS)
        else list(TARGET_ASSETS.items())
    )
    for sym, cfg in items:
        try:
            est, _ = estimate_swap_route(int(capital_sample_ada * 1_000_000), "ADA", sym)
            raw_out = int(est.get("amount_out", 0))
            dec = int(cfg.get("decimals", 6))
            tok_out = raw_out / (10 ** dec)
            if tok_out > 0:
                prices[sym] = capital_sample_ada / tok_out
            if len(items) > 1:
                time.sleep(0.15)
        except Exception as e:
            logger.warning(f"Failed to fetch reference spot price for {sym}: {e}")
    return prices


def fetch_asset_trend_velocity(asset: str, spot_price_ada: float, vol_data_all: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Return basic volatility profile for an asset from cardano_volatility_engine."""
    sym = asset.upper()
    if os.environ.get("CARDANO_TEST_MODE") == "1":
        return {
            "asset": sym,
            "velocity_4h_pct": 0.5,
            "regime": "NORMAL_CORRIDOR",
            "slide_action": "ALLOW",
            "volatility_profile": {"30m": 1.2, "1h": 1.8, "2h": 2.4, "4h": 3.2, "8h": 4.0, "24h": 5.0},
        }
    if vol_data_all is None:
        try:
            from lib.tools.cardano_volatility_engine import get_all_asset_volatilities
            vol_data_all = get_all_asset_volatilities()
        except Exception:
            vol_data_all = {}
    profile = (vol_data_all or {}).get("assets", {}).get(sym, {})
    return {
        "asset": sym,
        "velocity_4h_pct": profile.get("velocity_4h_pct", 0.0) or 0.0,
        "regime": "NORMAL_CORRIDOR",
        "slide_action": "ALLOW",
        "volatility_profile": profile.get("dispersion_pct", {}),
    }


def query_wallet_balance() -> Dict[str, Any]:
    """Query live UTxOs and ADA balance via cardano_trader (with offline test-mode fast path)."""
    if os.environ.get("CARDANO_TEST_MODE") == "1":
        return {
            "status": "ok",
            "address": "addr1_test_mode",
            "utxo_count": 2,
            "total_lovelace": 540_000_000,
            "total_ada": 540.0,
            "spendable_ada": 500.0,
            "reserve_floor_ada": HARD_RESERVE_FLOOR_ADA,
            "multi_assets": {},
        }
    from lib.tools.cardano_trader import query_wallet_balance as _trader_qwb
    return _trader_qwb()


def get_ada_macro_stats() -> Dict[str, Any]:
    """Fetch CoinGecko ADA/USD spot and 24h change percentage."""
    import urllib.request
    url = "https://api.coingecko.com/api/v3/simple/price?ids=cardano&vs_currencies=usd&include_24hr_change=true"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "BlueLodge-CardanoRails/1.0", "Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode())
            ada_info = data.get("cardano", {})
            return {
                "status": "ok",
                "price_usd": float(ada_info.get("usd", 0.0)),
                "change_24h_pct": float(ada_info.get("usd_24h_change", 0.0)),
            }
    except Exception as e:
        logger.warning(f"CoinGecko ADA macro fetch error: {e}")
        return {"status": "unavailable", "price_usd": 0.0, "change_24h_pct": 0.0, "error": str(e)}


def verify_pool_batcher_liveness(
    protocol: str,
    pool_id: str,
    max_age_h: float = MAX_POOL_BATCH_AGE_H,
) -> Dict[str, Any]:
    """Verify on-chain that a pool's NFT/LP token has settled a batch within max_age_h hours."""
    clean_id = (pool_id or "").replace(".", "").strip()
    if len(clean_id) < 56 or not all(c in "0123456789abcdefABCDEF" for c in clean_id):
        return {"live": True, "last_batch_age_h": None, "avg_batch_interval_h": None, "reason": "unverified_pool_id"}

    now = time.time()
    with _LIVENESS_LOCK:
        if not _LIVENESS_MEM and POOL_LIVENESS_CACHE.exists():
            try:
                _LIVENESS_MEM.update(json.loads(POOL_LIVENESS_CACHE.read_text()))
            except Exception:
                pass
        cached = _LIVENESS_MEM.get(clean_id)
        if cached and (now - float(cached.get("checked_at", 0)) < 900):
            last_ts = int(cached.get("last_batch_ts") or 0)
            age_h = round((now - last_ts) / 3600.0, 2) if last_ts > 0 else 9999.0
            live = age_h <= max_age_h
            return {
                "live": live,
                "last_batch_age_h": age_h,
                "avg_batch_interval_h": cached.get("avg_batch_interval_h"),
                "reason": "ok" if live else f"Stale pool batcher ({age_h:.1f}h > {max_age_h:.1f}h limit)",
            }

    try:
        from lib.tools import cardano_orders as co
        txs = co.bf_get(f"/assets/{clean_id}/transactions?count=3&order=desc", allow_404=True) or []
        if not txs:
            return {"live": True, "last_batch_age_h": None, "avg_batch_interval_h": None, "reason": "no_tx_history"}
        last_ts = int(txs[0].get("block_time") or 0)
        age_h = round((now - last_ts) / 3600.0, 2) if last_ts > 0 else 9999.0
        live = age_h <= max_age_h
        rec = {"checked_at": now, "last_batch_ts": last_ts, "avg_batch_interval_h": None}
        with _LIVENESS_LOCK:
            _LIVENESS_MEM[clean_id] = rec
            try:
                POOL_LIVENESS_CACHE.parent.mkdir(parents=True, exist_ok=True)
                POOL_LIVENESS_CACHE.write_text(json.dumps(_LIVENESS_MEM))
            except Exception:
                pass
        return {
            "live": live,
            "last_batch_age_h": age_h,
            "avg_batch_interval_h": None,
            "reason": "ok" if live else f"Stale pool batcher ({age_h:.1f}h > {max_age_h:.1f}h limit)",
        }
    except Exception:
        return {"live": True, "last_batch_age_h": None, "avg_batch_interval_h": None, "reason": "check_skipped"}


def compute_cpmm_arb_metrics(
    spot_buy_ada: float,
    spot_sell_ada: float,
    buy_reserve_ada: float,
    sell_reserve_ada: float,
    buy_lp_fee: float = 0.003,
    sell_lp_fee: float = 0.003,
    fixed_fee_ada: float = 4.4,
    min_profit_ada: float = 1.0,
) -> Dict[str, Any]:
    """Constant-product AMM (CPMM) 2-leg spread & slippage geometry."""
    if spot_buy_ada <= 0 or spot_sell_ada <= 0:
        return {
            "spot_spread_pct": 0.0, "net_lp_spread_pct": 0.0, "eff_reserve_ada": 0.0,
            "min_viable_ada": None, "max_viable_ada": None, "no_slip_min_ada": None,
            "target_viable_ada": 0.0, "optimal_ada": 0.0, "max_gross_profit_ada": 0.0,
            "max_net_profit_ada": -fixed_fee_ada, "req_spread_pct": 0.0,
        }
    lp_keep = max(1e-6, (1.0 - buy_lp_fee) * (1.0 - sell_lp_fee))
    spot_ratio = spot_sell_ada / spot_buy_ada
    spot_spread_pct = (spot_ratio - 1.0) * 100.0
    gamma = spot_ratio * lp_keep
    net_lp_spread_pct = (gamma - 1.0) * 100.0
    eff_reserve_ada = (
        (buy_reserve_ada * sell_reserve_ada) / (buy_reserve_ada + sell_reserve_ada)
        if (buy_reserve_ada > 0 and sell_reserve_ada > 0)
        else max(buy_reserve_ada, sell_reserve_ada, 0.0)
    )
    hurdle_ada = max(0.01, fixed_fee_ada + min_profit_ada)
    no_slip_min_ada = round(hurdle_ada / (gamma - 1.0), 2) if gamma > 1.0001 else None
    if eff_reserve_ada <= 0:
        return {
            "spot_spread_pct": round(spot_spread_pct, 3), "net_lp_spread_pct": round(net_lp_spread_pct, 3),
            "eff_reserve_ada": 0.0, "min_viable_ada": no_slip_min_ada, "max_viable_ada": None,
            "no_slip_min_ada": no_slip_min_ada, "target_viable_ada": round(no_slip_min_ada or 0.0, 2),
            "optimal_ada": round(no_slip_min_ada or 0.0, 2), "max_gross_profit_ada": 0.0,
            "max_net_profit_ada": round(-fixed_fee_ada, 3),
            "req_spread_pct": round(((1.0 / lp_keep) - 1.0) * 100.0 + 2.0, 2),
        }
    gamma_req = (1.0 + math.sqrt(hurdle_ada / eff_reserve_ada)) ** 2
    req_spread_pct = ((gamma_req / lp_keep) - 1.0) * 100.0
    target_viable_ada = math.sqrt(eff_reserve_ada * hurdle_ada)
    if gamma > 1.0:
        sqrt_g = math.sqrt(gamma)
        optimal_ada = eff_reserve_ada * (sqrt_g - 1.0)
        max_gross_profit_ada = eff_reserve_ada * ((sqrt_g - 1.0) ** 2)
    else:
        optimal_ada, max_gross_profit_ada = 0.0, 0.0
    max_net_profit_ada = max_gross_profit_ada - fixed_fee_ada
    min_viable_ada = max_viable_ada = None
    if max_gross_profit_ada >= hurdle_ada and gamma > 1.0:
        a = 1.0 / eff_reserve_ada
        b = 1.0 - gamma + (hurdle_ada / eff_reserve_ada)
        disc = max(0.0, b * b - 4.0 * a * hurdle_ada)
        rl, rh = (-b - math.sqrt(disc)) / (2.0 * a), (-b + math.sqrt(disc)) / (2.0 * a)
        if rl > 0:
            min_viable_ada = round(rl, 2)
        if rh > 0:
            max_viable_ada = round(rh, 2)
    return {
        "spot_spread_pct": round(spot_spread_pct, 3), "net_lp_spread_pct": round(net_lp_spread_pct, 3),
        "eff_reserve_ada": round(eff_reserve_ada, 1), "min_viable_ada": min_viable_ada,
        "max_viable_ada": max_viable_ada, "no_slip_min_ada": no_slip_min_ada,
        "target_viable_ada": round(target_viable_ada, 2), "optimal_ada": round(optimal_ada, 2),
        "max_gross_profit_ada": round(max_gross_profit_ada, 3), "max_net_profit_ada": round(max_net_profit_ada, 3),
        "req_spread_pct": round(req_spread_pct, 2),
    }
