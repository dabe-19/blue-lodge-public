#!/usr/bin/env python3
"""
Sovereign Cardano DEX Flash Spread & Volatility Sniping Engine
Surveys real cross-DEX liquidity dislocations across Minswap, SundaeSwap,
WingRiders, Splash, CSWAP, and VyFinance on Cardano Mainnet via live isolated
protocol estimates. Computes exact CPMM pool depth, minimum viable order size,
profit-maximizing optimal order size, and required spread hurdles.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

# Auto-bootstrap project virtualenv (Python 3.12 with compiled C-extensions like pycardano)
_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

import concurrent.futures
import json
import logging
import math
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from typing import Any, Dict, List, Optional

from lib.tools.quant import tokens as _tokens

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("cardano_flash_sniper")

LODGE_DIR = Path(os.environ.get("LODGE_DIR", _REPO_ROOT))
SECRETS_FILE = LODGE_DIR / ".george" / "secrets.env"
STATUS_CACHE = LODGE_DIR / ".george" / "wallets" / "status_cache.json"
SNIPER_CACHE = LODGE_DIR / ".george" / "wallets" / "dex_sniper_cache.json"

MINSWAP_AGGREGATOR_BASE = "https://agg-api.minswap.org/aggregator"

_COINGECKO_MAP: Dict[str, str] = {
    "SNEK": "snek",
    "MIN": "minswap",
    "WMTX": "world-mobile-token",
    "DJED": "djed",
    "IAG": "iagon",
    "NIGHT": "midnight",
    "HOSKY": "hosky-token",
    "USDM": "usdm",
    "USDCX": "usd-coin",
    "SHEN": "shen",
    "INDY": "indigo-dao-governance-token",
    "LQ": "liqwid-finance",
    "STRIKE": "strike-finance",
    "SUNDAE": "sundaeswap",
    "FLDT": "fluidtokens",
}

# Monitored Liquid Pairs on Cardano Mainnet built from canonical token registry
POOLS_CATALOG: Dict[str, Dict[str, Any]] = {
    sym: {
        "unit": _tokens.unit(sym),
        "decimals": _tokens.decimals(sym),
        "coingecko_id": _COINGECKO_MAP.get(sym, sym.lower()),
        "base_spread_threshold": 1.5 if sym in ("DJED", "USDM", "USDCX") else 2.5,
    }
    for sym in _tokens.symbols()
}

ALL_PROTOCOLS: List[str] = [
    "MinswapV2", "Minswap", "MinswapStable",
    "Splash", "Spectrum", "SplashStable",
    "SundaeSwapV3", "SundaeSwap", "SundaeSwapStable",
    "WingRidersV2", "WingRiders", "WingRidersStableV2",
    "OpenDjedV1", "ChakraBondingCurve", "CswapV1", "VyFinance", "DanogoCLMMV1",
]

DEX_VENUES: Dict[str, List[str]] = {
    "Minswap": ["MinswapV2", "Minswap", "MinswapStable"],
    "SundaeSwap": ["SundaeSwapV3", "SundaeSwap", "SundaeSwapStable"],
    "WingRiders": ["WingRidersV2", "WingRiders", "WingRidersStableV2"],
    "Splash": ["Splash", "SplashStable"],
    "CSWAP": ["CswapV1"],
    "Danogo": ["DanogoCLMMV1"],
}
# Note: VyFinance is excluded from DEX_VENUES (and kept in ALL_PROTOCOLS) because its Plutus order
# datum requires a StakeAddress credential, whereas George's hot wallet is an Enterprise address (addr1v...).

POOL_LIVENESS_CACHE = LODGE_DIR / ".george" / "wallets" / "pool_liveness_cache.json"
# Maximum hours since the pool NFT's last on-chain batch settlement before a pool is quarantined as a zombie/stalled batcher
MAX_POOL_BATCH_AGE_H = float(os.getenv("CARDANO_MAX_POOL_BATCH_AGE_H", "6.0"))

# Minimum pool ADA reserve to qualify as an active non-zombie venue
MIN_VENUE_RESERVE_ADA = 1000.0
MAX_VENUE_PROBE_IMPACT = 0.25

# Fiduciary Boundaries
HARD_RESERVE_FLOOR_ADA = float(os.getenv("CARDANO_RESERVE_FLOOR_ADA", "40.00"))
MIN_NET_PROFIT_ADA = 0.50
DEX_BATCHER_FEE_PER_LEG_ADA = 2.00
L1_FEE_PER_LEG_ADA = 0.18
SWAP_FEE_BPS = 30  # 0.30% default pool swap fee


@dataclass
class SnipingOpportunity:
    asset: str
    buy_dex: str
    sell_dex: str
    spot_buy_price_ada: float
    spot_sell_price_ada: float
    gross_spread_pct: float
    capital_allocation_ada: float
    gross_profit_ada: float
    total_friction_ada: float
    net_profit_ada: float
    net_roi_pct: float
    viable: bool
    execution_strategy: str
    recommended_limit_buy: float
    recommended_limit_sell: float
    risk_assessment: str
    net_lp_spread_pct: float = 0.0
    exec_spread_pct: float = 0.0
    eff_reserve_ada: float = 0.0
    min_viable_ada: Optional[float] = None
    no_slip_min_ada: Optional[float] = None
    target_viable_ada: float = 0.0
    optimal_ada: float = 0.0
    max_net_profit_ada: float = 0.0
    req_spread_pct: float = 0.0
    venues_count: int = 0


def compute_cpmm_arb_metrics(
    spot_buy_ada: float,
    spot_sell_ada: float,
    buy_lp_fee: float,
    sell_lp_fee: float,
    buy_reserve_ada: float,
    sell_reserve_ada: float,
    fixed_fee_ada: float,
    min_profit_ada: float = MIN_NET_PROFIT_ADA,
) -> Dict[str, Any]:
    """
    Exact constant-product AMM (CPMM) 2-leg cross-DEX arbitrage sizing & hurdle math.

    Given two pools with zero-impact spot prices P_buy,0 and P_sell,0, LP fee fractions
    f_buy and f_sell, and ADA reserves R_buy and R_sell:
      - Zero-impact net-of-LP multiplier:
          Gamma = (P_sell,0 / P_buy,0) * (1 - f_buy) * (1 - f_sell)
      - Effective harmonic pool depth:
          R_eff = (R_buy * R_sell) / (R_buy + R_sell)
      - Gross profit after LP fees and CPMM price impact for order size dx (ADA):
          G(dx) = dx * (Gamma / (1 + dx / R_eff) - 1)
      - Profit-maximizing order size dx* where dG/ddx = 0:
          dx* = R_eff * (sqrt(Gamma) - 1)   for Gamma > 1, yielding G_max = R_eff * (sqrt(Gamma) - 1)^2
      - Required gross profit hurdle H = fixed_fee_ada + min_profit_ada.
      - Minimum cross-DEX spot spread required on R_eff so G_max >= H:
          Gamma_req = (1 + sqrt(H / R_eff))^2
          req_spread_pct = (Gamma_req / ((1 - f_buy) * (1 - f_sell)) - 1) * 100
          target_viable_ada = sqrt(R_eff * H)
    """
    if spot_buy_ada <= 0 or spot_sell_ada <= 0:
        return {
            "spot_spread_pct": 0.0,
            "net_lp_spread_pct": 0.0,
            "eff_reserve_ada": 0.0,
            "min_viable_ada": None,
            "max_viable_ada": None,
            "no_slip_min_ada": None,
            "target_viable_ada": 0.0,
            "optimal_ada": 0.0,
            "max_gross_profit_ada": 0.0,
            "max_net_profit_ada": -fixed_fee_ada,
            "req_spread_pct": 0.0,
        }

    lp_keep = max(1e-6, (1.0 - buy_lp_fee) * (1.0 - sell_lp_fee))
    spot_ratio = spot_sell_ada / spot_buy_ada
    spot_spread_pct = (spot_ratio - 1.0) * 100.0
    gamma = spot_ratio * lp_keep
    net_lp_spread_pct = (gamma - 1.0) * 100.0

    if buy_reserve_ada > 0 and sell_reserve_ada > 0:
        eff_reserve_ada = (buy_reserve_ada * sell_reserve_ada) / (buy_reserve_ada + sell_reserve_ada)
    else:
        eff_reserve_ada = max(buy_reserve_ada, sell_reserve_ada, 0.0)

    hurdle_ada = max(0.01, fixed_fee_ada + min_profit_ada)

    # Pure friction break-even order size (ignoring pool price impact) when net-LP spread > 0
    no_slip_min_ada: Optional[float] = None
    if gamma > 1.0001:
        no_slip_min_ada = round(hurdle_ada / (gamma - 1.0), 2)

    if eff_reserve_ada <= 0:
        return {
            "spot_spread_pct": round(spot_spread_pct, 3),
            "net_lp_spread_pct": round(net_lp_spread_pct, 3),
            "eff_reserve_ada": 0.0,
            "min_viable_ada": no_slip_min_ada,
            "max_viable_ada": None,
            "no_slip_min_ada": no_slip_min_ada,
            "target_viable_ada": round(no_slip_min_ada or 0.0, 2),
            "optimal_ada": round(no_slip_min_ada or 0.0, 2),
            "max_gross_profit_ada": 0.0,
            "max_net_profit_ada": round(-fixed_fee_ada, 3),
            "req_spread_pct": round(((1.0 / lp_keep) - 1.0) * 100.0 + 2.0, 2),
        }

    # Required spread & threshold order size given real pool depth R_eff
    gamma_req = (1.0 + math.sqrt(hurdle_ada / eff_reserve_ada)) ** 2
    req_spread_pct = ((gamma_req / lp_keep) - 1.0) * 100.0
    target_viable_ada = math.sqrt(eff_reserve_ada * hurdle_ada)

    # Optimal order size at current spread
    if gamma > 1.0:
        sqrt_g = math.sqrt(gamma)
        optimal_ada = eff_reserve_ada * (sqrt_g - 1.0)
        max_gross_profit_ada = eff_reserve_ada * ((sqrt_g - 1.0) ** 2)
    else:
        optimal_ada = 0.0
        max_gross_profit_ada = 0.0

    max_net_profit_ada = max_gross_profit_ada - fixed_fee_ada

    # Solve G(dx) = hurdle_ada => dx^2 / R_eff + (1 - gamma + hurdle / R_eff)*dx + hurdle = 0
    min_viable_ada: Optional[float] = None
    max_viable_ada: Optional[float] = None
    if max_gross_profit_ada >= hurdle_ada and gamma > 1.0:
        a = 1.0 / eff_reserve_ada
        b = 1.0 - gamma + (hurdle_ada / eff_reserve_ada)
        c = hurdle_ada
        disc = max(0.0, b * b - 4.0 * a * c)
        root_low = (-b - math.sqrt(disc)) / (2.0 * a)
        root_high = (-b + math.sqrt(disc)) / (2.0 * a)
        if root_low > 0:
            min_viable_ada = round(root_low, 2)
        if root_high > 0:
            max_viable_ada = round(root_high, 2)

    return {
        "spot_spread_pct": round(spot_spread_pct, 3),
        "net_lp_spread_pct": round(net_lp_spread_pct, 3),
        "eff_reserve_ada": round(eff_reserve_ada, 1),
        "min_viable_ada": min_viable_ada,
        "max_viable_ada": max_viable_ada,
        "no_slip_min_ada": no_slip_min_ada,
        "target_viable_ada": round(target_viable_ada, 2),
        "optimal_ada": round(optimal_ada, 2),
        "max_gross_profit_ada": round(max_gross_profit_ada, 3),
        "max_net_profit_ada": round(max_net_profit_ada, 3),
        "req_spread_pct": round(req_spread_pct, 2),
    }


import threading

_LIVENESS_LOCK = threading.Lock()
_LIVENESS_MEM: Dict[str, Dict[str, Any]] = {}
_BF_API_SINGLETON = None


def _get_bf_api():
    global _BF_API_SINGLETON
    if _BF_API_SINGLETON is None:
        try:
            from lib.tools.cardano_trader import get_blockfrost_client
            _BF_API_SINGLETON = get_blockfrost_client().api
        except Exception:
            _BF_API_SINGLETON = False
    return _BF_API_SINGLETON if _BF_API_SINGLETON is not False else None


def resolve_pool_nft_unit(protocol: str, pool_id: str) -> str:
    """Resolve Minswap Aggregator hop.pool_id into the canonical on-chain Pool NFT / LP asset unit."""
    pid = (pool_id or "").strip().replace(".", "").replace("0014efbfbd10", "0014df10")
    if not pid:
        return ""
    if protocol == "SundaeSwapV3" and len(pid) == 56:
        return "e0302560ced2fdcbfcb2602697df970cd0d6a38f94b32703f51c312b000de140" + pid
    if protocol == "SundaeSwap" and len(pid) < 56:
        return "0029cb7c88c7567b63d1a512c0ed626aa169688ec980730c0473b9137020" + pid
    return pid


def verify_pool_batcher_liveness(
    protocol: str,
    pool_id: str,
    max_age_h: float = MAX_POOL_BATCH_AGE_H,
) -> Dict[str, Any]:
    """
    Verify on-chain that a specific AMM pool's batcher is actively clearing orders.

    On Cardano, a pool's NFT/LP token only moves in a transaction when a batcher settles a batch
    (or an LP adds/removes liquidity) against that exact pool UTxO. Pools whose NFT has not moved
    in > max_age_h hours (e.g., abandoned Spectrum/CswapV1/legacy pools where batchers stopped
    running days or months ago) have frozen prices that create fake arbitrage spreads.
    """
    nft_unit = resolve_pool_nft_unit(protocol, pool_id)
    if not nft_unit or len(nft_unit) < 56 or not all(c in "0123456789abcdefABCDEF" for c in nft_unit):
        return {"live": True, "last_batch_age_h": None, "avg_batch_interval_h": None, "reason": "unverified_pool_id"}

    now = time.time()
    with _LIVENESS_LOCK:
        if not _LIVENESS_MEM and POOL_LIVENESS_CACHE.exists():
            try:
                _LIVENESS_MEM.update(json.loads(POOL_LIVENESS_CACHE.read_text()))
            except Exception:
                pass
        cached = _LIVENESS_MEM.get(nft_unit)
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

    bf = _get_bf_api()
    if bf is None:
        return {"live": True, "last_batch_age_h": None, "avg_batch_interval_h": None, "reason": "blockfrost_unavailable"}

    try:
        txs = bf.asset_transactions(nft_unit, count=5, order="desc")
        if not txs:
            rec = {"checked_at": now, "last_batch_ts": 0, "avg_batch_interval_h": None}
        else:
            last_ts = int(txs[0].block_time)
            avg_int_h = (
                round(((txs[0].block_time - txs[-1].block_time) / (len(txs) - 1)) / 3600.0, 2)
                if len(txs) > 1
                else 0.0
            )
            rec = {"checked_at": now, "last_batch_ts": last_ts, "avg_batch_interval_h": avg_int_h}
    except Exception:
        return {"live": True, "last_batch_age_h": None, "avg_batch_interval_h": None, "reason": "lookup_skipped"}

    with _LIVENESS_LOCK:
        _LIVENESS_MEM[nft_unit] = rec
        try:
            POOL_LIVENESS_CACHE.parent.mkdir(parents=True, exist_ok=True)
            POOL_LIVENESS_CACHE.write_text(json.dumps(_LIVENESS_MEM))
        except Exception:
            pass

    last_ts = int(rec.get("last_batch_ts") or 0)
    age_h = round((now - last_ts) / 3600.0, 2) if last_ts > 0 else 9999.0
    live = age_h <= max_age_h
    return {
        "live": live,
        "last_batch_age_h": age_h,
        "avg_batch_interval_h": rec.get("avg_batch_interval_h"),
        "reason": "ok" if live else f"Stale pool batcher ({age_h:.1f}h > {max_age_h:.1f}h limit)",
    }


def _estimate_single_venue(
    amount_raw: int,
    token_in: str,
    token_out: str,
    allowed_protocols: List[str],
    timeout: float = 4.5,
) -> Optional[Dict[str, Any]]:
    excluded = [p for p in ALL_PROTOCOLS if p not in allowed_protocols]
    payload = {
        "amount": str(amount_raw),
        "token_in": token_in,
        "token_out": token_out,
        "slippage": 0.02,
        "exclude_protocols": excluded,
        "allow_multi_hops": False,
    }
    req = urllib.request.Request(
        f"{MINSWAP_AGGREGATOR_BASE}/estimate",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "BlueLodge-FlashSniper/2.0"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode())
        out_raw = int(data.get("amount_out") or 0)
        paths = data.get("paths") or []
        if out_raw <= 0 or not paths or not paths[0]:
            return None
        hop = paths[0][0]
        proto = str(hop.get("protocol") or "AMM")
        if proto not in allowed_protocols:
            return None
        pool_id = str(hop.get("pool_id") or "")
        in_raw = int(hop.get("amount_in") or amount_raw)
        lp_fee_raw = int(hop.get("lp_fee") or 0)
        lp_fee_frac = (lp_fee_raw / in_raw) if in_raw > 0 else 0.003
        # Minswap aggregator returns price_impact as a percentage (e.g. 0.338 = 0.338% = 0.00338)
        impact = float(hop.get("price_impact") or 0.0) / 100.0
        batcher_ada = int(data.get("total_dex_fee") or hop.get("dex_fee") or 2_000_000) / 1_000_000
        agg_ada = int(data.get("aggregator_fee") or 0) / 1_000_000
        return {
            "amount_in_raw": in_raw,
            "amount_out_raw": out_raw,
            "protocol": proto,
            "pool_id": pool_id,
            "lp_fee_frac": lp_fee_frac,
            "price_impact": impact,
            "batcher_ada": batcher_ada,
            "agg_ada": agg_ada,
        }
    except Exception:
        return None


def _scan_single_token(sym: str, cfg: Dict[str, Any], trade_capital_ada: float) -> Optional[Dict[str, Any]]:
    unit = cfg["unit"]
    dec = int(cfg["decimals"])
    exec_cap_ada = max(10.0, float(trade_capital_ada))
    # Use a 50 ADA reference probe to discover all active DEX venues without tripping slippage filters on mid-depth pools
    ref_probe_ada = 50.0
    ref_lovelace = int(ref_probe_ada * 1_000_000)

    venue_quotes: Dict[str, Dict[str, Any]] = {}
    quarantined_venues: List[Dict[str, Any]] = []
    for venue_name, protos in DEX_VENUES.items():
        seen_pools = set()
        active_protos = list(protos)
        for probe_ada in (50.0, 2500.0):
            if not active_protos:
                break
            probe_lovelace = int(probe_ada * 1_000_000)
            est = _estimate_single_venue(probe_lovelace, "lovelace", unit, active_protos)
            if not est:
                break
            pool_id = est.get("pool_id", "")
            if pool_id in seen_pools:
                continue
            seen_pools.add(pool_id)
            used_proto = est["protocol"]
            tok_out_ref = est["amount_out_raw"] / (10 ** dec)
            if tok_out_ref <= 0:
                continue
            imp = est["price_impact"]
            f_lp = est["lp_fee_frac"]
            if imp >= MAX_VENUE_PROBE_IMPACT:
                continue
            eff_buy_ref = probe_ada / tok_out_ref
            spot_price = eff_buy_ref * max(0.01, (1.0 - imp))
            denom = ((1.0 - f_lp) / max(1e-6, 1.0 - imp)) - 1.0
            reserve_ada = (probe_ada * (1.0 - f_lp) / denom) if denom > 1e-6 else 50_000.0
            if reserve_ada < MIN_VENUE_RESERVE_ADA:
                if used_proto in active_protos and len(active_protos) > 1:
                    active_protos.remove(used_proto)
                continue

            # Dynamic On-Chain Pool-NFT Batcher Liveness Gate: quarantine pools with stalled/abandoned batchers
            liveness = verify_pool_batcher_liveness(used_proto, pool_id)
            if not liveness["live"]:
                quarantined_venues.append({
                    "dex": venue_name,
                    "protocol": used_proto,
                    "spot_ada": round(spot_price, 8),
                    "reserve_ada": round(reserve_ada, 1),
                    "last_batch_age_h": liveness["last_batch_age_h"],
                    "reason": liveness["reason"],
                })
                if used_proto in active_protos and len(active_protos) > 1:
                    active_protos.remove(used_proto)
                continue

            # Exact CPMM output for exec_cap_ada on this pool
            eff_in_ada = exec_cap_ada * (1.0 - f_lp)
            ada_after_impact = (reserve_ada * eff_in_ada) / (reserve_ada + eff_in_ada)
            tok_out_exec = ada_after_impact / spot_price if spot_price > 0 else 0.0
            raw_tok_exec = int(tok_out_exec * (10 ** dec))

            venue_quotes[venue_name] = {
                "dex": venue_name,
                "protocol": used_proto,
                "pool_id": pool_id,
                "raw_tok_out": raw_tok_exec,
                "tok_out": tok_out_exec,
                "eff_buy_price_ada": (exec_cap_ada / tok_out_exec) if tok_out_exec > 0 else spot_price,
                "spot_price_ada": spot_price,
                "lp_fee_frac": f_lp,
                "price_impact": imp,
                "reserve_ada": round(reserve_ada, 1),
                "batcher_ada": est["batcher_ada"],
                "agg_ada": est["agg_ada"],
                "last_batch_age_h": liveness["last_batch_age_h"],
                "avg_batch_interval_h": liveness["avg_batch_interval_h"],
            }
            break

    if not venue_quotes:
        return None

    venues_list = sorted(venue_quotes.values(), key=lambda v: v["spot_price_ada"])
    venues_count = len(venues_list)

    if venues_count >= 2:
        # Evaluate all distinct (buy_venue != sell_venue) pairs and select the best cross-DEX corridor
        best_pair = None
        best_score = -1e12
        for b_name, b_q in venue_quotes.items():
            for s_name, s_q in venue_quotes.items():
                if b_name == s_name:
                    continue
                fixed_fee = b_q["batcher_ada"] + s_q["batcher_ada"] + (2.0 * L1_FEE_PER_LEG_ADA)
                m = compute_cpmm_arb_metrics(
                    spot_buy_ada=b_q["spot_price_ada"],
                    spot_sell_ada=s_q["spot_price_ada"],
                    buy_lp_fee=b_q["lp_fee_frac"],
                    sell_lp_fee=s_q["lp_fee_frac"],
                    buy_reserve_ada=b_q["reserve_ada"],
                    sell_reserve_ada=s_q["reserve_ada"],
                    fixed_fee_ada=fixed_fee,
                )
                # Rank by: (1) viable net profit, (2) positive gross arb yield, (3) proximity to required spread hurdle
                is_viable_pair = 1.0 if m["max_net_profit_ada"] >= MIN_NET_PROFIT_ADA else 0.0
                has_pos_gross = 1.0 if m["max_gross_profit_ada"] > 0 else 0.0
                hurdle_gap = m["spot_spread_pct"] - m["req_spread_pct"]
                score = (
                    (is_viable_pair * 10000.0)
                    + (m["max_net_profit_ada"] * 100.0 if is_viable_pair else 0.0)
                    + (has_pos_gross * 100.0)
                    + (m["max_gross_profit_ada"] * 10.0)
                    + hurdle_gap
                )
                if score > best_score:
                    best_score = score
                    best_pair = (b_q, s_q, m, fixed_fee)

        assert best_pair is not None
        buy_q, sell_q, metrics, direct_fixed_fee = best_pair
        # Compute exact CPMM sell leg on the winning sell venue at exec_cap_ada
        spot_val_ada = buy_q["tok_out"] * sell_q["spot_price_ada"] * (1.0 - sell_q["lp_fee_frac"])
        ada_returned = (sell_q["reserve_ada"] * spot_val_ada) / (sell_q["reserve_ada"] + spot_val_ada)
        sell_batcher_ada = sell_q["batcher_ada"]
        sell_agg_ada = sell_q["agg_ada"]
        sell_proto = sell_q["protocol"]
    else:
        # Single-DEX token: no secondary pool available
        buy_q = venues_list[0]
        sell_q = venues_list[0]
        sell_proto = f"{buy_q['protocol']} (Single-DEX)"
        sell_batcher_ada = buy_q["batcher_ada"]
        sell_agg_ada = buy_q["agg_ada"]
        direct_fixed_fee = buy_q["batcher_ada"] * 2.0 + (2.0 * L1_FEE_PER_LEG_ADA)
        spot_val_ada = buy_q["tok_out"] * buy_q["spot_price_ada"] * (1.0 - buy_q["lp_fee_frac"])
        ada_returned = (buy_q["reserve_ada"] * spot_val_ada) / (buy_q["reserve_ada"] + spot_val_ada)
        metrics = compute_cpmm_arb_metrics(
            spot_buy_ada=buy_q["spot_price_ada"],
            spot_sell_ada=buy_q["spot_price_ada"],
            buy_lp_fee=buy_q["lp_fee_frac"],
            sell_lp_fee=buy_q["lp_fee_frac"],
            buy_reserve_ada=buy_q["reserve_ada"],
            sell_reserve_ada=buy_q["reserve_ada"],
            fixed_fee_ada=direct_fixed_fee,
        )

    tok_out = buy_q["tok_out"]
    exec_buy_price = exec_cap_ada / tok_out if tok_out > 0 else buy_q["spot_price_ada"]
    exec_sell_price = ada_returned / tok_out if tok_out > 0 else sell_q["spot_price_ada"]
    exec_spread_pct = ((exec_sell_price - exec_buy_price) / exec_buy_price) * 100.0 if exec_buy_price > 0 else 0.0

    l1_tx_fee_ada = 2.0 * L1_FEE_PER_LEG_ADA
    direct_friction_ada = round(buy_q["batcher_ada"] + sell_batcher_ada + l1_tx_fee_ada, 3)
    agg_surcharge_ada = round(buy_q["agg_ada"] + sell_agg_ada, 3)

    return {
        "asset": sym,
        "buy_dex": buy_q["protocol"],
        "sell_dex": sell_proto,
        "buy_family": buy_q["dex"],
        "sell_family": sell_q["dex"],
        "buy_batch_age_h": buy_q.get("last_batch_age_h"),
        "sell_batch_age_h": sell_q.get("last_batch_age_h"),
        "is_cross_dex": venues_count >= 2 and (buy_q["dex"] != sell_q["dex"]),
        "venues_count": venues_count,
        "all_venues": [
            {
                "dex": v["dex"],
                "protocol": v["protocol"],
                "spot_ada": round(v["spot_price_ada"], 8),
                "reserve_ada": v["reserve_ada"],
                "lp_fee_pct": round(v["lp_fee_frac"] * 100.0, 2),
                "batcher_ada": v["batcher_ada"],
                "last_batch_age_h": v.get("last_batch_age_h"),
            }
            for v in venues_list
        ],
        "quarantined_venues": quarantined_venues,
        "spot_buy_price_ada": round(buy_q["spot_price_ada"], 8),
        "spot_sell_price_ada": round(sell_q["spot_price_ada"], 8),
        "buy_price_ada": round(exec_buy_price, 8),
        "sell_price_ada": round(exec_sell_price, 8),
        "spot_spread_pct": metrics["spot_spread_pct"],
        "net_lp_spread_pct": metrics["net_lp_spread_pct"],
        "exec_spread_pct": round(exec_spread_pct, 3),
        "buy_lp_fee_pct": round(buy_q["lp_fee_frac"] * 100.0, 2),
        "sell_lp_fee_pct": round(sell_q["lp_fee_frac"] * 100.0, 2),
        "buy_reserve_ada": buy_q["reserve_ada"],
        "sell_reserve_ada": sell_q["reserve_ada"],
        "eff_reserve_ada": metrics["eff_reserve_ada"],
        "min_viable_ada": metrics["min_viable_ada"],
        "max_viable_ada": metrics["max_viable_ada"],
        "no_slip_min_ada": metrics["no_slip_min_ada"],
        "target_viable_ada": metrics["target_viable_ada"],
        "optimal_ada": metrics["optimal_ada"],
        "max_gross_profit_ada": metrics["max_gross_profit_ada"],
        "max_net_profit_ada": metrics["max_net_profit_ada"],
        "req_spread_pct": metrics["req_spread_pct"],
        "tok_out": tok_out,
        "ada_returned": round(ada_returned, 6),
        "capital_ada": round(exec_cap_ada, 2),
        "buy_batcher_fee_ada": buy_q["batcher_ada"],
        "sell_batcher_fee_ada": sell_batcher_ada,
        "aggregator_fee_ada": agg_surcharge_ada,
        "l1_network_fee_ada": l1_tx_fee_ada,
        "total_friction_ada": direct_friction_ada,
    }


def fetch_live_amm_quotes(trade_capital_ada: float) -> list[dict[str, Any]]:
    """Fetches real live isolated per-DEX AMM quotes across all monitored Cardano pairs."""
    now = time.time()
    if SNIPER_CACHE.exists():
        try:
            cached = json.loads(SNIPER_CACHE.read_text())
            cached_cap = float(cached.get("trade_capital_ada", 0.0))
            cached_quotes = cached.get("quotes", [])
            if (
                (now - cached.get("timestamp", 0) < 45)
                and abs(cached_cap - trade_capital_ada) < 1.0
                and len(cached_quotes) >= 10
                and "spot_spread_pct" in (cached_quotes[0] if cached_quotes else {})
            ):
                logger.info(f"Using cached live cross-DEX quotes (<45s old, {cached_cap:.1f} ADA capital)")
                return cached_quotes
        except Exception:
            pass

    quotes: list[dict[str, Any]] = []
    items = list(POOLS_CATALOG.items())
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        future_map = {
            pool.submit(_scan_single_token, sym, cfg, trade_capital_ada): sym
            for sym, cfg in items
        }
        for fut in concurrent.futures.as_completed(future_map):
            sym = future_map[fut]
            try:
                res = fut.result()
                if res:
                    quotes.append(res)
            except Exception as e:
                logger.warning(f"Error fetching live cross-DEX quotes for {sym}: {e}")

    # Sort deterministically by max_net_profit_ada descending, then spot_spread_pct descending
    quotes.sort(key=lambda q: (q.get("max_net_profit_ada", -999.0), q.get("spot_spread_pct", -999.0)), reverse=True)

    try:
        SNIPER_CACHE.parent.mkdir(parents=True, exist_ok=True)
        SNIPER_CACHE.write_text(
            json.dumps(
                {
                    "timestamp": now,
                    "trade_capital_ada": trade_capital_ada,
                    "quotes": quotes,
                },
                indent=2,
            )
        )
    except Exception as e:
        logger.warning(f"Failed to cache sniper quotes: {e}")

    return quotes


def scan_flash_dislocations(
    spendable_ada: float,
    min_spread_override: Optional[float] = None,
    capital_override: Optional[float] = None,
) -> list[SnipingOpportunity]:
    opportunities: list[SnipingOpportunity] = []

    max_single_swap = float(os.getenv("CARDANO_MAX_SINGLE_SWAP_ADA", "200.00"))
    default_trade_size = float(os.getenv("CARDANO_SWAP_TRADE_SIZE_ADA", "150.00"))

    if capital_override is not None and capital_override > 0:
        trade_capital_ada = min(max_single_swap, max(10.0, float(capital_override)))
    else:
        # Use up to 95% of spendable working capital (capped by max_single_swap) to dilute fixed fees
        trade_capital_ada = min(
            max_single_swap,
            max(10.0, spendable_ada * 0.95 if spendable_ada > 0 else default_trade_size),
        )

    live_quotes = fetch_live_amm_quotes(trade_capital_ada)

    for q in live_quotes:
        sym = q["asset"]
        cfg = POOLS_CATALOG.get(sym, {})
        spot_buy_p = float(q.get("spot_buy_price_ada") or q.get("buy_price_ada") or 0.0)
        spot_sell_p = float(q.get("spot_sell_price_ada") or q.get("sell_price_ada") or 0.0)
        buy_venue = q["buy_dex"]
        sell_venue = q["sell_dex"]
        ada_returned = float(q["ada_returned"])
        actual_cap = float(q.get("capital_ada", trade_capital_ada))

        if spot_buy_p <= 0 or spot_sell_p <= 0:
            continue

        spot_spread = float(q.get("spot_spread_pct", 0.0))
        net_lp_spread = float(q.get("net_lp_spread_pct", 0.0))
        exec_spread = float(q.get("exec_spread_pct", 0.0))
        total_friction_ada = float(q.get("total_friction_ada", 4.36))

        gross_profit_ada = ada_returned - actual_cap
        net_profit_ada = gross_profit_ada - total_friction_ada
        net_roi = (net_profit_ada / actual_cap) * 100.0 if actual_cap > 0 else 0.0

        min_viable_ada = q.get("min_viable_ada")
        no_slip_min_ada = q.get("no_slip_min_ada")
        target_viable_ada = float(q.get("target_viable_ada") or 0.0)
        optimal_ada = float(q.get("optimal_ada") or 0.0)
        max_net_profit_ada = float(q.get("max_net_profit_ada") or net_profit_ada)
        req_spread_pct = float(q.get("req_spread_pct") or 2.5)
        eff_reserve_ada = float(q.get("eff_reserve_ada") or 0.0)
        venues_count = int(q.get("venues_count") or 1)

        threshold = min_spread_override or cfg.get("base_spread_threshold", 2.0)
        viable = (net_profit_ada >= MIN_NET_PROFIT_ADA) or (max_net_profit_ada >= MIN_NET_PROFIT_ADA and spot_spread >= threshold)

        if viable:
            strategy = "Flash Market Snipe (Active)"
            risk_desc = (
                f"Viable cross-DEX arb: Buy on {buy_venue}, Sell on {sell_venue}. "
                f"Min order: {min_viable_ada:.0f} ADA | Optimal: {optimal_ada:.0f} ADA (nets {max_net_profit_ada:+.2f} ADA)."
            )
        else:
            strategy = "Resting Limit Order (Passive Sniping)"
            risk_desc = (
                f"Spot spread {spot_spread:+.2f}% (net-LP {net_lp_spread:+.2f}%) below {req_spread_pct:.2f}% hurdle "
                f"for {eff_reserve_ada:,.0f} ADA eff. depth (target size >= {target_viable_ada:.0f} ADA)."
            )

        limit_buy_target = spot_buy_p * 0.98
        limit_sell_target = spot_sell_p * 1.02

        opp = SnipingOpportunity(
            asset=sym,
            buy_dex=buy_venue,
            sell_dex=sell_venue,
            spot_buy_price_ada=round(spot_buy_p, 8),
            spot_sell_price_ada=round(spot_sell_p, 8),
            gross_spread_pct=round(spot_spread, 2),
            capital_allocation_ada=round(actual_cap, 2),
            gross_profit_ada=round(gross_profit_ada, 3),
            total_friction_ada=round(total_friction_ada, 3),
            net_profit_ada=round(net_profit_ada, 3),
            net_roi_pct=round(net_roi, 2),
            viable=viable,
            execution_strategy=strategy,
            recommended_limit_buy=round(limit_buy_target, 8),
            recommended_limit_sell=round(limit_sell_target, 8),
            risk_assessment=risk_desc,
            net_lp_spread_pct=round(net_lp_spread, 2),
            exec_spread_pct=round(exec_spread, 2),
            eff_reserve_ada=round(eff_reserve_ada, 1),
            min_viable_ada=min_viable_ada,
            no_slip_min_ada=no_slip_min_ada,
            target_viable_ada=round(target_viable_ada, 1),
            optimal_ada=round(optimal_ada, 1),
            max_net_profit_ada=round(max_net_profit_ada, 3),
            req_spread_pct=round(req_spread_pct, 2),
            venues_count=venues_count,
        )
        opportunities.append(opp)

    return sorted(opportunities, key=lambda x: (x.max_net_profit_ada, x.gross_spread_pct), reverse=True)


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Sovereign Cardano DEX Flash Spread & Volatility Sniper")
    parser.add_argument("--scan", action="store_true", help="Scan live DEX pools for flash mispricings")
    parser.add_argument("--capital", "--trade-size", "-c", dest="capital", type=float, default=None,
                        help="Target trade capital in ADA (default: 95% of spendable up to 200 ADA)")
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--min-spread", type=float, default=None, help="Minimum spread percentage hurdle")
    args = parser.parse_args()

    spendable_ada = 194.26
    if STATUS_CACHE.exists():
        try:
            cdata = json.loads(STATUS_CACHE.read_text())
            spendable_ada = float(cdata.get("cardano", {}).get("spendable_ada", 194.26))
        except Exception:
            pass

    opps = scan_flash_dislocations(spendable_ada, min_spread_override=args.min_spread, capital_override=args.capital)

    if args.json:
        print(json.dumps([asdict(o) for o in opps], indent=2))
        return

    print("\n" + "=" * 116)
    print("  SOVEREIGN CARDANO DEX FLASH SPREAD & VOLATILITY SNIPER (MAINNET ISOLATED MULTI-DEX)")
    print("=" * 116)
    print(f"  Treasury Allocation: {spendable_ada:.2f} ADA Spendable | {HARD_RESERVE_FLOOR_ADA:.2f} ADA Floor")
    print("-" * 116)
    print(
        f"  {'ASSET':<7} {'BUY VENUE':<15} {'SELL VENUE':<15} {'SPOT SPRD':<10} "
        f"{'REQ SPRD':<9} {'MIN/TGT ADA':<12} {'OPT ADA':<9} {'NET@CAP':<10} {'MAX NET'}"
    )
    print("-" * 116)
    viable_count = 0
    for o in opps:
        min_str = f"{o.min_viable_ada:.0f} ADA" if o.min_viable_ada else f"~{o.target_viable_ada:.0f} ADA*"
        print(
            f"  {o.asset:<7} {o.buy_dex:<15} {o.sell_dex:<15} {o.gross_spread_pct:>+7.2f}%  "
            f"{o.req_spread_pct:>6.2f}%   {min_str:<12} {o.optimal_ada:>6.0f} A  "
            f"{o.net_profit_ada:>+7.2f} A  {o.max_net_profit_ada:>+7.2f} A"
        )
        if o.viable:
            viable_count += 1
    print("=" * 116)
    print(f"  Surveillance complete: {len(opps)} Pairs Analyzed across 6 DEX families. {viable_count} Viable Snipes.")
    print("  (* ~ADA indicates target order size required when pair reaches its REQ SPRD hurdle for its pool depth.)")
    print("=" * 116 + "\n")


if __name__ == "__main__":
    main()
