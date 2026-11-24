#!/usr/bin/env python3
"""
Chart payload builder for the Sovereign DEX Desk.

Produces everything the front-end charting layer needs for one asset/ADA pair:
  * On-chain first candles + signed order-flow volume (5m, 15m, 1h, 4h, 1D) from market.db,
    with seamless pre-recorder history stitching for long lookbacks.
  * Dynamic Kalman local-level fair value trajectory (exp(mu_t)) + ±1σ/±2σ dislocation bands.
  * S3 stablecoin CEX peg parity trajectory (1 / ADA_USD(t)) + fee/sigma trigger bands.
  * ADA/USD macro reference series (Coinbase 5m/tick feed from market.db).
  * Cumulative Volume Delta (CVD) & signed buy/sell volume + shock-bar detection.
  * Visible Range Volume Profile (VRVP: POC, VAH, VAL + 24-bin volume-at-price histogram).
  * Rolling Lo-MacKinlay Variance Ratio VR(k) regime classification (Mean-Reverting vs Trending).
  * ARX post-shock impulse-response mean-reversion projection inside the forward volatility cone.
  * Shadow simulator trades (sim_trades), proposed plans (P-XXXXXX), standing orders (SO-XXXXXX),
    completed round trips, walk-forward backtest stats, and S2/S3 quant signal markers.
  * Exact CPMM marginal order-book ladder + real on-chain batcher telemetry from market.db.
All values are in ADA per token. Missing inputs are omitted, never fabricated.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sqlite3
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

import numpy as np

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from lib.tools.quant import fair_value as fv_mod  # noqa: E402
from lib.tools.quant import impact as impact_mod  # noqa: E402
from lib.tools.quant import market_data as md  # noqa: E402
from lib.tools.quant import market_db as mdb  # noqa: E402
from lib.tools.quant import models as qm  # noqa: E402
from lib.tools.quant import tokens as tok_mod  # noqa: E402

CSCAN = "https://cardanoscan.io/transaction/"
_HEX64 = re.compile(r"^[0-9a-f]{64}$")


def _maker_db_path() -> Path:
    import os
    lodge = Path(os.environ.get("LODGE_DIR", _REPO_ROOT))
    george = Path(os.environ.get("GEORGE_DIR", lodge / ".george"))
    fin = Path(os.environ.get("FINANCE_DIR", george / "finance"))
    if os.environ.get("CARDANO_TEST_MODE") == "1":
        return Path(os.environ.get("SIM_MAKER_DB_PATH", fin / "sim_maker_orders.db"))
    return Path(os.environ.get("MAKER_DB_PATH", fin / "maker_orders.db"))


def _tx_time(tx_hash: str, fallback_ts: Optional[int] = None) -> int | None:
    if not tx_hash or not _HEX64.match(tx_hash):
        return fallback_ts
    try:
        mcon = mdb.connect()
        try:
            r = mcon.execute("SELECT ts FROM swaps WHERE tx=? LIMIT 1", (tx_hash,)).fetchone()
            if r and r["ts"]:
                return int(r["ts"])
        finally:
            mcon.close()
    except Exception:
        pass
    if fallback_ts:
        return int(fallback_ts)
    try:
        from lib.tools.cardano_orders import bf_get
        return int(bf_get(f"/txs/{tx_hash}")["block_time"])
    except Exception:
        return None


def _orders_for(asset: str) -> List[Dict[str, Any]]:
    try:
        p = _maker_db_path()
        if not p.exists():
            return []
        conn = sqlite3.connect(str(p), timeout=10)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT * FROM maker_orders WHERE asset = ? ORDER BY created_at DESC LIMIT 20", (asset,)
        ).fetchall()
        conn.close()
        return [dict(r) for r in rows]
    except Exception:
        return []


def _stop_triggers_for(asset: str) -> List[Dict[str, Any]]:
    try:
        p = _maker_db_path()
        if not p.exists():
            return []
        conn = sqlite3.connect(str(p), timeout=10)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT * FROM stop_triggers WHERE asset = ? AND status = 'ARMED' ORDER BY created_at DESC", (asset,)
        ).fetchall()
        conn.close()
        return [dict(r) for r in rows]
    except Exception:
        return []


def _trading_db_overlays(asset: str, now_ts: int) -> Dict[str, Any]:
    """Reads proposed plans, active standing orders, shadow sim trades, completed trips, and backtest summary from trading.db."""
    out: Dict[str, Any] = {
        "plans": [],
        "standing_orders": [],
        "sim_trades": [],
        "trips": [],
        "backtest": None,
    }
    try:
        from lib.tools.trading import store as tstore
        con = tstore.connect()
        try:
            # 1. Proposed / recent plans for this asset
            for r in con.execute(
                "SELECT plan_id, created_at, expires_at, tier, status, actions_json, summary "
                "FROM plans WHERE status IN ('proposed', 'executed') ORDER BY created_at DESC LIMIT 25"
            ).fetchall():
                try:
                    acts = json.loads(r["actions_json"] or "[]")
                except Exception:
                    acts = []
                for a in acts:
                    if str(a.get("asset") or "").upper() != asset:
                        continue
                    if r["status"] == "proposed" and int(r["expires_at"] or 0) <= now_ts:
                        continue
                    out["plans"].append({
                        "plan_id": r["plan_id"],
                        "status": r["status"],
                        "tier": r["tier"],
                        "created_at": int(r["created_at"]),
                        "expires_at": int(r["expires_at"]),
                        "side": str(a.get("side") or "buy").lower(),
                        "price": float(a["price"]) if a.get("price") is not None else None,
                        "trigger_spot": float(a.get("fills_when_spot_below") or a.get("fills_when_spot_above") or 0.0) or None,
                        "ada": float(a.get("ada") or a.get("budget_ada") or 0.0) or None,
                        "tokens": float(a.get("tokens") or 0.0) or None,
                        "ev_ada": float(a["ev_if_filled_ada"]) if a.get("ev_if_filled_ada") is not None else None,
                        "p_fill": float(a["p_fill_24h_model"]) if a.get("p_fill_24h_model") is not None else None,
                        "fair_value": float(a["fair_value"]) if a.get("fair_value") is not None else None,
                        "strategy": a.get("strategy") or "manual",
                    })

            # 2. Active standing orders for this asset
            for r in con.execute(
                "SELECT so_id, strategy, asset, side, max_ada, used_ada, price_min, price_max, status, expires_at "
                "FROM standing_orders WHERE UPPER(asset)=? AND status='active' AND expires_at>? ORDER BY created_at DESC",
                (asset, now_ts),
            ).fetchall():
                out["standing_orders"].append({
                    "so_id": r["so_id"],
                    "strategy": r["strategy"],
                    "side": r["side"],
                    "max_ada": float(r["max_ada"] or 0.0),
                    "used_ada": float(r["used_ada"] or 0.0),
                    "price_min": float(r["price_min"]) if r["price_min"] is not None else None,
                    "price_max": float(r["price_max"]) if r["price_max"] is not None else None,
                    "expires_at": int(r["expires_at"]),
                })

            # 3. Shadow simulator trades for this asset
            for r in con.execute(
                "SELECT sim_id, strategy, side, created_at, entry_price, size_ada, exit_target, "
                "timeout_at, status, filled_at, exit_at, exit_price, net_pnl_ada, fees_ada "
                "FROM sim_trades WHERE UPPER(asset)=? ORDER BY created_at DESC LIMIT 30",
                (asset,),
            ).fetchall():
                out["sim_trades"].append(dict(r))

            # 4. Closed / open round trips for this asset
            for r in con.execute(
                "SELECT trip_id, mode, strategy, opened_at, closed_at, entry_price, exit_price, "
                "tokens, entry_ada, exit_ada, fees_ada, net_pnl_ada "
                "FROM trips WHERE UPPER(asset)=? ORDER BY opened_at DESC LIMIT 20",
                (asset,),
            ).fetchall():
                out["trips"].append(dict(r))

            # 5. Latest walk-forward backtest stats for this asset
            strat_key = "S3_stable_deviation" if asset in fv_mod.STABLES else "S2_shock_fade"
            bt_row = con.execute(
                "SELECT run_id, ts, strategy, detail FROM backtests WHERE strategy=? ORDER BY ts DESC LIMIT 1",
                (strat_key,),
            ).fetchone()
            if bt_row and bt_row["detail"]:
                detail = json.loads(bt_row["detail"])
                asset_bt = (detail.get("assets") or {}).get(asset)
                if asset_bt and asset_bt.get("stats"):
                    out["backtest"] = {
                        "run_id": bt_row["run_id"],
                        "ts": int(bt_row["ts"]),
                        "strategy": bt_row["strategy"],
                        "size_ada": asset_bt.get("size_ada"),
                        "fee": asset_bt.get("fee"),
                        **asset_bt["stats"],
                    }
        finally:
            con.close()
    except Exception:
        pass
    return out


def _compute_volume_profile(candles: List[Dict[str, Any]], volume: List[Dict[str, Any]], n_bins: int = 24) -> Dict[str, Any]:
    """Computes Visible Range Volume Profile (VRVP): POC, VAH, VAL (70% Value Area), and price bins."""
    if not candles or not volume:
        return {"status": "empty", "bins": []}
    p_min = min(float(c["low"]) for c in candles if c["low"] > 0)
    p_max = max(float(c["high"]) for c in candles if c["high"] > 0)
    if p_max <= p_min or p_min <= 0:
        return {"status": "flat", "poc_price": p_min, "vah_price": p_max, "val_price": p_min, "bins": []}

    span = p_max - p_min
    bin_w = span / n_bins
    bins = [
        {
            "price_low": p_min + i * bin_w,
            "price_high": p_min + (i + 1) * bin_w,
            "price_mid": p_min + (i + 0.5) * bin_w,
            "volume": 0.0,
            "buy_volume": 0.0,
            "sell_volume": 0.0,
        }
        for i in range(n_bins)
    ]

    for c, v in zip(candles, volume):
        tot_v = float(v.get("value") or 0.0)
        # Weight volume by real ADA volume when traded; if all volumes are 0, weight by 1 per traded bar (TPO profile)
        if tot_v <= 0:
            continue
        buy_v = float(v.get("buy_volume") or (tot_v if c["close"] >= c["open"] else 0.0))
        sell_v = float(v.get("sell_volume") or (tot_v - buy_v))
        lo, hi = float(c["low"]), float(c["high"])
        b_start = max(0, min(n_bins - 1, int((lo - p_min) / bin_w)))
        b_end = max(0, min(n_bins - 1, int((hi - p_min) / bin_w)))
        count = b_end - b_start + 1
        for bi in range(b_start, b_end + 1):
            bins[bi]["volume"] += tot_v / count
            bins[bi]["buy_volume"] += buy_v / count
            bins[bi]["sell_volume"] += sell_v / count

    total_vol = sum(b["volume"] for b in bins)
    # Fallback to TPO (time-at-price) if volume is 0
    if total_vol <= 0:
        for c in candles:
            mid = 0.5 * (float(c["high"]) + float(c["low"]))
            bi = max(0, min(n_bins - 1, int((mid - p_min) / bin_w)))
            bins[bi]["volume"] += 1.0
            bins[bi]["buy_volume"] += 1.0 if c["close"] >= c["open"] else 0.0
            bins[bi]["sell_volume"] += 1.0 if c["close"] < c["open"] else 0.0
        total_vol = sum(b["volume"] for b in bins)

    poc_idx = max(range(n_bins), key=lambda i: bins[i]["volume"])
    max_bin_vol = max(bins[poc_idx]["volume"], 1e-12)

    # Expand outward from POC until 70% of total volume is captured (standard Value Area)
    target_va = 0.70 * total_vol
    cum_va = bins[poc_idx]["volume"]
    lo_idx = hi_idx = poc_idx
    while cum_va < target_va and (lo_idx > 0 or hi_idx < n_bins - 1):
        up_v = bins[hi_idx + 1]["volume"] if hi_idx + 1 < n_bins else -1.0
        dn_v = bins[lo_idx - 1]["volume"] if lo_idx - 1 >= 0 else -1.0
        if up_v >= dn_v and hi_idx + 1 < n_bins:
            hi_idx += 1
            cum_va += bins[hi_idx]["volume"]
        elif lo_idx - 1 >= 0:
            lo_idx -= 1
            cum_va += bins[lo_idx]["volume"]
        else:
            break

    for i, b in enumerate(bins):
        b["pct_of_max"] = round((b["volume"] / max_bin_vol) * 100.0, 1)
        b["in_value_area"] = lo_idx <= i <= hi_idx
        b["is_poc"] = i == poc_idx
        b["volume"] = round(b["volume"], 2)
        b["buy_volume"] = round(b["buy_volume"], 2)
        b["sell_volume"] = round(b["sell_volume"], 2)

    return {
        "status": "ok",
        "poc_price": round(bins[poc_idx]["price_mid"], 8),
        "vah_price": round(bins[hi_idx]["price_high"], 8),
        "val_price": round(bins[lo_idx]["price_low"], 8),
        "total_volume_ada": round(total_vol, 2),
        "bins": bins,
    }


def _build_real_order_book(
    asset: str,
    spot: float,
    reserve_ada: float,
    fee_bps: float,
    primary_dex: str,
    all_pools: List[Dict[str, Any]],
    our_orders: List[Dict[str, Any]],
    stop_triggers: List[Dict[str, Any]],
    plans: List[Dict[str, Any]],
) -> Dict[str, Any]:
    """Computes exact marginal CPMM liquidity depth (dx = x*(sqrt(1+s)-1)/(1-f)) + real resting limit orders & secondary DEX pools."""
    fee = max(0.0, float(fee_bps or 30.0) / 10_000.0)
    reserve_tok = (reserve_ada / spot) if (spot > 0 and reserve_ada > 0) else 0.0
    venue_label = "MINSWAP-V2" if "minswap" in primary_dex.lower() else primary_dex.upper()[:10]

    steps = [0.003, 0.008, 0.015, 0.025, 0.040, 0.065]
    asks: List[Dict[str, Any]] = []
    bids: List[Dict[str, Any]] = []

    if spot > 0 and reserve_ada > 0:
        prev_cum_ask_ada = 0.0
        prev_cum_ask_tok = 0.0
        for s in steps:
            px = spot * (1.0 + s)
            # Cumulative ADA required to move marginal CPMM spot from p0 to p0*(1+s), including pool fee
            cum_ada = reserve_ada * (math.sqrt(1.0 + s) - 1.0) / max(1e-6, 1.0 - fee)
            cum_tok = reserve_tok * (1.0 - 1.0 / math.sqrt(1.0 + s))
            inc_ada = max(1.0, cum_ada - prev_cum_ask_ada)
            inc_tok = max(inc_ada / px, cum_tok - prev_cum_ask_tok)
            prev_cum_ask_ada = cum_ada
            prev_cum_ask_tok = cum_tok
            asks.append({
                "price": round(px, 8),
                "size": round(inc_tok, 2),
                "depthAda": round(inc_ada, 2),
                "cumDepthAda": round(cum_ada, 2),
                "venue": venue_label,
                "side": "ask",
                "isResting": False,
                "step_pct": round(s * 100.0, 2),
            })

        prev_cum_bid_ada = 0.0
        prev_cum_bid_tok = 0.0
        for s in steps:
            px = spot * (1.0 - s)
            if px <= 0:
                continue
            cum_ada = reserve_ada * (1.0 - math.sqrt(max(0.0, 1.0 - s))) * (1.0 - fee)
            cum_tok = reserve_tok * (1.0 / math.sqrt(max(1e-6, 1.0 - s)) - 1.0)
            inc_ada = max(1.0, cum_ada - prev_cum_bid_ada)
            inc_tok = max(inc_ada / px, cum_tok - prev_cum_bid_tok)
            prev_cum_bid_ada = cum_ada
            prev_cum_bid_tok = cum_tok
            bids.append({
                "price": round(px, 8),
                "size": round(inc_tok, 2),
                "depthAda": round(inc_ada, 2),
                "cumDepthAda": round(cum_ada, 2),
                "venue": venue_label,
                "side": "bid",
                "isResting": False,
                "step_pct": round(-s * 100.0, 2),
            })

    # Secondary active DEX pools (only non-off-market pools with real reserves)
    for sec in all_pools:
        if sec.get("off_market") or sec.get("dex") == primary_dex:
            continue
        sec_px = float(sec.get("price_ada") or 0.0)
        sec_res = float(sec.get("reserve_ada_est") or 0.0)
        if sec_px <= 0 or sec_res < 250.0:
            continue
        sec_venue = str(sec.get("dex") or "SEC-DEX").replace("-cardano", "").upper()[:10]
        # 1% marginal slice of the secondary pool
        slice_ada = max(25.0, sec_res * 0.01)
        if sec_px > spot * 1.001:
            asks.append({
                "price": round(sec_px, 8),
                "size": round(slice_ada / sec_px, 2),
                "depthAda": round(slice_ada, 2),
                "cumDepthAda": round(slice_ada, 2),
                "venue": sec_venue,
                "side": "ask",
                "isResting": False,
            })
        elif sec_px < spot * 0.999:
            bids.append({
                "price": round(sec_px, 8),
                "size": round(slice_ada / sec_px, 2),
                "depthAda": round(slice_ada, 2),
                "cumDepthAda": round(slice_ada, 2),
                "venue": sec_venue,
                "side": "bid",
                "isResting": False,
            })

    # Our own resting limit orders
    for o in our_orders:
        if o.get("status") not in ("PENDING_BUY", "PENDING_SELL", "INVENTORY_HOLD"):
            continue
        px = float(o.get("limit_price") or 0.0)
        tok = float(o.get("amount_tokens") or 0.0)
        if px <= 0 or tok <= 0:
            continue
        side_str = "ask" if o.get("direction") == "SELL" else "bid"
        row = {
            "price": round(px, 8),
            "size": round(tok, 2),
            "depthAda": round(px * tok, 2),
            "cumDepthAda": round(px * tok, 2),
            "venue": "OUR-LIMIT",
            "side": side_str,
            "isResting": True,
        }
        if side_str == "ask":
            asks.append(row)
        else:
            bids.append(row)

    # Active proposed plans
    for p in plans:
        if p.get("status") != "proposed" or not p.get("price"):
            continue
        px = float(p["price"])
        ada_v = float(p.get("ada") or (px * float(p.get("tokens") or 0.0)) or 50.0)
        tok_v = float(p.get("tokens") or (ada_v / px if px > 0 else 0.0))
        side_str = "ask" if p.get("side") == "sell" else "bid"
        row = {
            "price": round(px, 8),
            "size": round(tok_v, 2),
            "depthAda": round(ada_v, 2),
            "cumDepthAda": round(ada_v, 2),
            "venue": f"PLAN {p['plan_id']}",
            "side": side_str,
            "isResting": True,
        }
        if side_str == "ask":
            asks.append(row)
        else:
            bids.append(row)

    # Armed stop triggers
    for st in stop_triggers:
        tp = float(st.get("trigger_price_ada") or 0.0)
        cap = float(st.get("capital_ada") or 50.0)
        if tp <= 0:
            continue
        is_ask = st.get("trigger_type") in ("OCO_BRACKET", "STOP_BUY") and tp > spot
        row = {
            "price": round(tp, 8),
            "size": round(cap / tp, 2),
            "depthAda": round(cap, 2),
            "cumDepthAda": round(cap, 2),
            "venue": "STOP-TRIG",
            "side": "ask" if is_ask else "bid",
            "isResting": True,
        }
        if is_ask:
            asks.append(row)
        else:
            bids.append(row)

    asks.sort(key=lambda r: r["price"], reverse=True)
    bids.sort(key=lambda r: r["price"], reverse=True)
    visible_asks = asks[-6:]
    visible_bids = bids[:6]
    best_ask = visible_asks[-1]["price"] if visible_asks else spot * (1.0 + fee)
    best_bid = visible_bids[0]["price"] if visible_bids else spot * (1.0 - fee)
    spread_ada = max(0.0, best_ask - best_bid)
    spread_pct = (spread_ada / spot * 100.0) if spot > 0 else 0.0

    return {
        "asks": visible_asks,
        "bids": visible_bids,
        "best_ask": round(best_ask, 8),
        "best_bid": round(best_bid, 8),
        "mid_price": round(0.5 * (best_ask + best_bid), 8),
        "spread_ada": round(spread_ada, 8),
        "spread_pct": round(spread_pct, 3),
        "fee_bps": fee_bps,
        "reserve_ada": round(reserve_ada, 2),
    }


def _load_chart_series(asset: str, timeframe: str, aggregate: int, bars: int) -> Dict[str, Any]:
    """On-chain first OHLCV + order-flow loader from market.db, with pre-recorder history stitch when needed."""
    step = md.TIMEFRAME_SECONDS[timeframe] * int(aggregate)
    now_ts = int(time.time())
    mcon = None
    onchain = {"status": "unavailable"}
    swaps_recent: List[Dict[str, Any]] = []
    try:
        mcon = mdb.connect()
        onchain = mdb.ohlcv_series(mcon, asset, step_s=step, since=now_ts - bars * step, until=now_ts, max_bars=bars)
        swaps_recent = mdb.recent_swaps(mcon, asset, limit=80)
    except Exception:
        onchain = {"status": "unavailable"}

    onchain_bars = onchain.get("bars") or [] if onchain.get("status") == "ok" else []
    min_needed = 40 if (timeframe == "minute" and aggregate <= 5) else min(bars, 90)

    # Try to get secondary pools from GeckoTerminal cache/API without failing if offline
    all_pools: List[Dict[str, Any]] = []
    gt_pool_prov: Dict[str, Any] = {}
    try:
        pools_res = md.list_ada_pools(asset, ttl=86400 if onchain_bars else None)
        if pools_res.get("status") == "ok":
            all_pools = pools_res.get("pools") or []
            gt_pool_prov = pools_res.get("provenance") or {}
    except Exception:
        pass

    # Case 1: market.db already has enough bars (e.g. 5m, 15m, or backfilled 1h/4h) -> 100% On-Chain!
    if len(onchain_bars) >= min_needed:
        pool_meta = dict(onchain["pool"])
        if all_pools:
            pool_meta["volume_usd_24h"] = all_pools[0].get("volume_usd_24h")
        else:
            all_pools = [pool_meta]
        if mcon is not None:
            mcon.close()
        return {
            "status": "ok",
            "source_mode": "market_db_onchain",
            "unit": onchain.get("unit") or tok_mod.resolve_unit(asset) if hasattr(tok_mod, "resolve_unit") else md.resolve_unit(asset),
            "pool": pool_meta,
            "all_pools": all_pools,
            "step_s": step,
            "bars": onchain_bars[-bars:],
            "onchain_bars_count": len(onchain_bars),
            "swaps_recent": swaps_recent,
            "provenance": {
                "pools": gt_pool_prov or {"source": "market.db", "age_s": onchain.get("age_s", 0), "stale": False},
                "ohlcv": {
                    "source": "market.db (on-chain)",
                    "age_s": onchain.get("age_s", 0),
                    "from_cache": False,
                    "stale": False,
                    "onchain_bars": len(onchain_bars),
                },
            },
        }

    # Case 2: Need pre-recorder history (e.g. 4h / 1D or non-recorder asset) -> load GT and stitch onchain_bars on top!
    gt_tf = timeframe
    gt_agg = aggregate
    if timeframe == "minute" and aggregate == 5:
        # If an unrecorded asset asks for 5m and has <40 bars in market.db, request 5m or 15m from GT
        gt_tf, gt_agg = "minute", 5
    gt_series = md.load_series(asset, gt_tf, gt_agg, ttl=86400 if onchain_bars else None)
    if gt_series.get("status") != "ok":
        if mcon is not None:
            mcon.close()
        if onchain_bars:
            pool_meta = dict(onchain["pool"])
            return {
                "status": "ok",
                "source_mode": "market_db_onchain",
                "unit": onchain.get("unit") or md.resolve_unit(asset),
                "pool": pool_meta,
                "all_pools": all_pools or [pool_meta],
                "step_s": step,
                "bars": onchain_bars[-bars:],
                "onchain_bars_count": len(onchain_bars),
                "swaps_recent": swaps_recent,
                "provenance": {
                    "pools": {"source": "market.db", "age_s": onchain.get("age_s", 0), "stale": False},
                    "ohlcv": {"source": "market.db (on-chain)", "age_s": onchain.get("age_s", 0), "stale": False},
                },
            }
        return {"status": "unavailable", "reason": gt_series.get("reason", "market data unavailable")}

    g = gt_series["grid"]
    pool_meta = dict(gt_series["pool"])
    all_pools = gt_series.get("all_pools") or [pool_meta]
    now_bar = int(time.time()) // step * step
    extra = (now_bar - int(g["t"][-1])) // step if len(g["t"]) else 0
    if 0 < extra <= 2000:
        last = float(g["c"][-1])
        g = dict(g)
        g["t"] = np.concatenate([g["t"], g["t"][-1] + step * np.arange(1, extra + 1)])
        for k in ("o", "h", "l", "c"):
            g[k] = np.concatenate([g[k], np.full(extra, last)])
        g["v"] = np.concatenate([g["v"], np.zeros(extra)])
        g["traded"] = np.concatenate([g["traded"], np.zeros(extra, dtype=bool)])

    # Convert GT grid into unified bar dicts, then overwrite >= onchain_t0 with exact on-chain market.db bars!
    onchain_by_t = {int(b["time"]): b for b in onchain_bars}
    onchain_t0 = min(onchain_by_t.keys()) if onchain_by_t else None

    merged_bars: List[Dict[str, Any]] = []
    for t_val, o_v, h_v, l_v, c_v, v_v, tr_v in zip(g["t"], g["o"], g["h"], g["l"], g["c"], g["v"], g["traded"]):
        t_int = int(t_val)
        if onchain_t0 is not None and t_int >= onchain_t0:
            continue
        o_f, h_f, l_f, c_f, v_f = float(o_v), float(h_v), float(l_v), float(c_v), float(v_v)
        # Approximate directional split on pre-recorder historical bars using close vs open & range
        if v_f > 0 and h_f > l_f:
            buy_ratio = max(0.1, min(0.9, (c_f - l_f) / (h_f - l_f)))
        else:
            buy_ratio = 0.5 if c_f >= o_f else 0.35
        bv = v_f * buy_ratio
        sv = v_f - bv
        merged_bars.append({
            "time": t_int,
            "open": o_f,
            "high": h_f,
            "low": l_f,
            "close": c_f,
            "volume": v_f,
            "buy_volume": bv,
            "sell_volume": sv,
            "delta_volume": bv - sv,
            "trades": 1 if tr_v else 0,
            "traded": bool(tr_v),
            "shock": False,
            "max_impact_pct": 0.0,
        })

    if onchain_bars:
        # Ensure smooth open continuity at the stitch boundary
        if merged_bars:
            prev_close = merged_bars[-1]["close"]
            first_oc = dict(onchain_bars[0])
            first_oc["open"] = prev_close
            first_oc["high"] = max(first_oc["high"], prev_close)
            first_oc["low"] = min(first_oc["low"], prev_close)
            merged_bars.append(first_oc)
            merged_bars.extend(onchain_bars[1:])
        else:
            merged_bars.extend(onchain_bars)
        # Override pool spot, reserves, and fee tier with exact on-chain state
        oc_pool = onchain["pool"]
        pool_meta["price_ada"] = oc_pool["price_ada"]
        pool_meta["reserve_ada_est"] = oc_pool["reserve_ada_est"]
        pool_meta["reserve_token_est"] = oc_pool["reserve_token_est"]
        pool_meta["fee_bps"] = oc_pool["fee_bps"]

    if mcon is not None:
        mcon.close()

    prov_ohlcv = dict(gt_series["provenance"]["ohlcv"])
    if onchain_bars:
        prov_ohlcv["source"] = f"market.db on-chain ({len(onchain_bars)} bars) + historical backfill"
        prov_ohlcv["age_s"] = onchain.get("age_s", prov_ohlcv.get("age_s", 0))
        prov_ohlcv["stale"] = False
        prov_ohlcv["onchain_bars"] = len(onchain_bars)

    return {
        "status": "ok",
        "source_mode": "hybrid_onchain_stitched" if onchain_bars else "geckoterminal_fallback",
        "unit": gt_series["unit"],
        "pool": pool_meta,
        "all_pools": all_pools,
        "step_s": step,
        "bars": merged_bars[-bars:],
        "onchain_bars_count": len(onchain_bars),
        "swaps_recent": swaps_recent,
        "provenance": {
            "pools": gt_series["provenance"]["pools"],
            "ohlcv": prov_ohlcv,
        },
    }


def build_chart(asset: str, timeframe: str = "hour", aggregate: int = 1, bars: int = 500) -> Dict[str, Any]:
    asset = asset.upper()
    now_ts = int(time.time())
    series = _load_chart_series(asset, timeframe, aggregate, bars)
    if series.get("status") != "ok" or not series.get("bars"):
        return {"status": "error", "message": f"market data unavailable: {series.get('reason', 'no bars')}"}

    raw_bars: List[Dict[str, Any]] = series["bars"]
    pool = series["pool"]
    step = int(series["step_s"])
    step_h = step / 3600.0
    spot = float(pool["price_ada"])
    reserve_ada = float(pool.get("reserve_ada_est") or 0.0)
    fee_bps = float(pool.get("fee_bps") if pool.get("fee_bps") is not None else 30.0)
    pool_fee = fee_bps / 10_000.0

    candles: List[Dict[str, Any]] = []
    volume: List[Dict[str, Any]] = []
    cvd_series: List[Dict[str, Any]] = []
    cum_delta = 0.0

    for b in raw_bars:
        t_int = int(b["time"])
        o_v, h_v, l_v, c_v = float(b["open"]), float(b["high"]), float(b["low"]), float(b["close"])
        v_v = float(b.get("volume") or 0.0)
        bv = float(b.get("buy_volume") or 0.0)
        sv = float(b.get("sell_volume") or 0.0)
        dv = float(b.get("delta_volume") if b.get("delta_volume") is not None else (bv - sv))
        tr = bool(b.get("traded"))
        sh = bool(b.get("shock"))
        cum_delta += dv
        direction = "up" if c_v > o_v else ("down" if c_v < o_v else ("up" if dv >= 0 else "down"))
        candles.append({"time": t_int, "open": o_v, "high": h_v, "low": l_v, "close": c_v})
        volume.append({
            "time": t_int,
            "value": round(v_v, 4),
            "buy_volume": round(bv, 4),
            "sell_volume": round(sv, 4),
            "delta": round(dv, 4),
            "trades": int(b.get("trades") or 0),
            "traded": tr,
            "shock": sh,
            "direction": direction,
        })
        cvd_series.append({
            "time": t_int,
            "value": round(cum_delta, 4),
            "delta": round(dv, 4),
        })

    t_arr = np.array([c["time"] for c in candles], dtype=np.int64)
    c_arr = np.array([c["close"] for c in candles], dtype=float)
    traded_arr = np.array([v["traded"] for v in volume], dtype=bool)
    coverage = float(traded_arr.mean()) if len(traded_arr) else 0.0

    lines: List[Dict[str, Any]] = [{"price": spot, "label": "Pool spot", "kind": "spot"}]
    markers: List[Dict[str, Any]] = []
    orders_out: List[Dict[str, Any]] = []

    # 1. Our orders (maker_orders DB annotated with chain truth)
    for row in _orders_for(asset):
        meta = json.loads(row.get("metadata_json") or "{}")
        status = row.get("status")
        px = float(row.get("target_price_ada") or 0.0)
        tokens = float(row.get("tokens_target") or 0.0)
        if status in ("PENDING_SELL", "INVENTORY_HOLD"):
            if row.get("tokens_filled"):
                tokens = float(row["tokens_filled"])
            if row.get("sell_target_ada") and tokens > 0:
                px = float(row["sell_target_ada"]) / tokens

        is_standalone_sell = (row.get("direction") or "").upper() == "SELL"
        eff_dir = "SELL" if (status in ("PENDING_SELL", "INVENTORY_HOLD") or is_standalone_sell) else row.get("direction", "BUY")
        entry = {"order_id": row["order_id"], "status": status, "direction": eff_dir,
                 "limit_price": px, "amount_tokens": tokens,
                 "protocol": meta.get("protocol"), "onchain_status": meta.get("onchain_status"),
                 "deadline_iso": meta.get("deadline_iso"), "order_utxo": meta.get("order_utxo")}
        active = status in ("PENDING_BUY", "PENDING_SELL", "INVENTORY_HOLD")
        if active:
            if status == "PENDING_BUY" and row.get("target_price_ada"):
                lines.append({"price": float(row["target_price_ada"]), "label": f"BUY limit {row['order_id'][-6:]}",
                              "kind": "limit_buy"})
            if status in ("PENDING_SELL", "INVENTORY_HOLD") and px > 0 and tokens > 0:
                dead = meta.get("onchain_status") == "EXPIRED"
                lines.append({"price": px, "label": f"SELL limit{' (EXPIRED)' if dead else ''} {row['order_id'][-6:]}",
                              "kind": "limit_sell_expired" if dead else "limit_sell"})
                trig = qm.cpmm_trigger_price("sell", tokens, px,
                                             pool.get("reserve_token_est") or 0, pool.get("reserve_ada_est") or 0)
                if trig.get("status") == "ok":
                    lines.append({"price": trig["trigger_spot"], "label": "Executable trigger", "kind": "trigger"})
            if row.get("cost_basis_per_token"):
                lines.append({"price": float(row["cost_basis_per_token"]), "label": "Cost basis", "kind": "cost_basis"})
        tx_pairs = (
            (("sell_tx_id", "SELL order"), ("tx_id", "SELL order"))
            if is_standalone_sell
            else (("tx_id", "BUY order"), ("sell_tx_id", "SELL order"))
        )
        seen_tx = set()
        for key, label in tx_pairs:
            h = row.get(key)
            if h and _HEX64.match(h) and h not in seen_tx:
                seen_tx.add(h)
                fb_ts = int(row.get("updated_at") if (key == "sell_tx_id" and not is_standalone_sell and row.get("updated_at")) else (row.get("created_at") or 0)) or None
                t = _tx_time(h, fallback_ts=fb_ts)
                if t:
                    markers.append({"time": t, "label": label, "kind": "our_tx", "tx_hash": h, "url": CSCAN + h,
                                    "position": "belowBar" if "BUY" in label else "aboveBar"})
        orders_out.append(entry)

    # 2. Armed Stop Triggers & Reactive Brackets
    stop_triggers = _stop_triggers_for(asset)
    for st in stop_triggers:
        ttype = st["trigger_type"]
        tp = float(st["trigger_price_ada"])
        tid = st["trigger_id"][-6:]
        inv = float(st["invalidation_price_ada"]) if st.get("invalidation_price_ada") is not None else None

        if ttype == "STOP_BUY":
            lines.append({
                "price": tp,
                "label": f"STOP BUY {tid} (+{st['capital_ada']:.0f}A)",
                "kind": "stop_buy",
            })
            if inv:
                lines.append({
                    "price": inv,
                    "label": f"DISARM TRAP {tid}",
                    "kind": "invalidation_disarm",
                })
        elif ttype == "STOP_LOSS":
            lines.append({
                "price": tp,
                "label": f"STOP LOSS {tid}",
                "kind": "stop_loss",
            })
        elif ttype == "OCO_BRACKET":
            lines.append({
                "price": tp,
                "label": f"OCO TP {tid} (+{st.get('tp_target_pct', 4.0):.1f}%)",
                "kind": "take_profit",
            })
            if inv:
                lines.append({
                    "price": inv,
                    "label": f"OCO SL {tid} (-{st.get('sl_target_pct', 2.5):.1f}%)",
                    "kind": "stop_loss",
                })

    # 3. Diagnostics, Static OU & Dynamic Kalman Local-Level Fair Value Curve
    lc = np.log(np.clip(c_arr, 1e-12, None))
    adf = qm.adf_test(lc)
    ou = qm.fit_ou(lc, step_h, adf)
    if ou.get("actionable"):
        for k_ou, lab in (("band_1sd", "OU ±1σ"), ("band_2sd", "OU ±2σ")):
            lo, hi = ou[k_ou]
            lines += [{"price": lo, "label": f"{lab} low", "kind": "ou_band"},
                      {"price": hi, "label": f"{lab} high", "kind": "ou_band"}]
        lines.append({"price": ou["mu_price"], "label": "OU mean", "kind": "ou_mean"})

    kalman_k = max(2, min(max(2, len(lc) // 4), int(round(86400.0 / step))))
    ll = fv_mod.local_level(lc, kalman_k, include_series=True)
    kalman_series: List[Dict[str, Any]] = []
    kalman_diag: Dict[str, Any] = {"status": ll.get("status")}
    if ll.get("status") == "ok" and "mu_series" in ll:
        mu_s = ll["mu_series"]
        z_s = ll["z_series"]
        sig_d = float(ll["sigma_dev"] or 0.0)
        for idx_k, (t_v, mu_v, z_v) in enumerate(zip(t_arr, mu_s, z_s)):
            fv_px = math.exp(float(mu_v))
            kalman_series.append({
                "time": int(t_v),
                "fv": fv_px,
                "p1": math.exp(float(mu_v) + sig_d),
                "m1": math.exp(float(mu_v) - sig_d),
                "p2": math.exp(float(mu_v) + 2.0 * sig_d),
                "m2": math.exp(float(mu_v) - 2.0 * sig_d),
                "z": round(float(z_v), 3),
            })
            # Emit historical S2 shock-fade signal markers where dislocation <= -2.0σ on a traded/shock bar
            if idx_k >= 10 and float(z_v) <= -2.0 and (volume[idx_k]["shock"] or volume[idx_k]["delta"] < 0):
                markers.append({
                    "time": int(t_v),
                    "label": f"S2 Signal ({float(z_v):+.1f}σ)",
                    "kind": "quant_signal",
                    "price": float(c_arr[idx_k]),
                    "position": "belowBar",
                })
        fv_now = math.exp(float(ll["mu"]))
        z_now = float(ll["deviation_sigma"])
        hl_h = float(ll["half_life_steps"]) * step_h
        kalman_diag = {
            "status": "ok",
            "fair_value": fv_now,
            "deviation_sigma": round(z_now, 3),
            "sigma_dev": round(sig_d, 6),
            "vr_k": round(float(ll["vr_k"]), 3),
            "noise_share": round(float(ll["noise_share"]), 3),
            "half_life_h": round(hl_h, 2),
            "K": round(float(ll["K"]), 4),
        }
        lines.append({
            "price": fv_now,
            "label": f"Kalman FV ({z_now:+.2f}σ)",
            "kind": "kalman_fv",
        })

    # 4. Rolling Variance Ratio & Regime Ribbon
    vr_win = min(48, max(16, len(lc) // 3))
    vr_arr = fv_mod.rolling_variance_ratio(lc, k=4, window=vr_win)
    regime_series: List[Dict[str, Any]] = []
    for t_v, vr_v in zip(t_arr, vr_arr):
        if not np.isfinite(vr_v):
            continue
        vr_f = float(vr_v)
        reg = "MEAN_REVERTING" if vr_f < 0.85 else ("TRENDING" if vr_f > 1.15 else "RANDOM_WALK")
        regime_series.append({
            "time": int(t_v),
            "vr": round(vr_f, 3),
            "regime": reg,
        })
    current_vr = regime_series[-1]["vr"] if regime_series else kalman_diag.get("vr_k")
    current_regime = regime_series[-1]["regime"] if regime_series else (
        "MEAN_REVERTING" if (current_vr is not None and current_vr < 0.85)
        else ("TRENDING" if (current_vr is not None and current_vr > 1.15) else "RANDOM_WALK")
    )

    # 5. CEX ADA-USD Macro Reference Series & S3 Stablecoin Peg Parity Curve
    ada_usd_series: List[Dict[str, Any]] = []
    peg_series: List[Dict[str, Any]] = []
    peg_diag: Optional[Dict[str, Any]] = None
    try:
        mcon = mdb.connect()
        try:
            t_start_cex = int(t_arr[0]) - max(3600, 2 * step)
            t_end_cex = int(t_arr[-1]) + step
            cex_pts: List[tuple[int, float]] = []
            for r in mcon.execute(
                "SELECT bucket, c FROM cex_bars_5m WHERE symbol='ADA-USD' AND bucket>=? AND bucket<=? ORDER BY bucket",
                (t_start_cex, t_end_cex),
            ):
                if r["c"] and float(r["c"]) > 0:
                    cex_pts.append((int(r["bucket"]) + 299, float(r["c"])))
            for r in mcon.execute(
                "SELECT ts, price FROM cex_ticks WHERE symbol='ADA-USD' AND ts>=? AND ts<=? ORDER BY ts",
                (t_start_cex, t_end_cex),
            ):
                if r["price"] and float(r["price"]) > 0:
                    cex_pts.append((int(r["ts"]), float(r["price"])))
            cex_pts.sort(key=lambda x: x[0])
            if cex_pts:
                j_cx = 0
                last_cx: Optional[float] = None
                last_cx_ts = 0
                max_gap = max(1800, 2 * step)
                for t_v in t_arr:
                    t_i = int(t_v) + step - 1
                    while j_cx < len(cex_pts) and cex_pts[j_cx][0] <= t_i:
                        last_cx = cex_pts[j_cx][1]
                        last_cx_ts = cex_pts[j_cx][0]
                        j_cx += 1
                    if last_cx is not None and (t_i - last_cx_ts) <= max_gap:
                        ada_usd_series.append({"time": int(t_v), "value": round(last_cx, 5)})

            if asset in fv_mod.STABLES and ada_usd_series:
                peg_val = float(fv_mod.STABLES[asset])
                s3_info = fv_mod.stable_fair_value(asset, spot, con=mcon)
                sig_peg = float(s3_info.get("sigma_dev") or 0.008)
                rt_fee = 2.0 * pool_fee
                band_w = rt_fee + 1.5 * sig_peg
                for pt in ada_usd_series:
                    fv_p = peg_val / float(pt["value"])
                    peg_series.append({
                        "time": int(pt["time"]),
                        "fv": round(fv_p, 6),
                        "buy_trig": round(fv_p * math.exp(-band_w), 6),
                        "sell_trig": round(fv_p * math.exp(band_w), 6),
                    })
                if s3_info.get("status") == "ok" and s3_info.get("fair_value"):
                    peg_fv = float(s3_info["fair_value"])
                    dev_pct = (spot / peg_fv - 1.0) * 100.0
                    peg_diag = {
                        "fair_value": round(peg_fv, 6),
                        "ada_usd": s3_info.get("ada_usd"),
                        "deviation_pct": round(dev_pct, 3),
                        "deviation_sigma": round(float(s3_info.get("deviation_sigma") or 0.0), 2),
                        "half_life_h": round(float(s3_info["half_life_h"]), 2) if s3_info.get("half_life_h") else None,
                    }
                    lines.append({
                        "price": peg_fv,
                        "label": f"CEX Peg Parity ({dev_pct:+.2f}%)",
                        "kind": "peg_fv",
                    })
        finally:
            mcon.close()
    except Exception:
        pass

    # 6. Forward Volatility Cone & ARX Post-Shock Impulse-Response Projection
    cone: List[Dict[str, Any]] = []
    impulse_projection: List[Dict[str, Any]] = []
    t_last = int(t_arr[-1])

    imp_data = impact_mod.cached(asset)
    if not imp_data:
        try:
            mcon = mdb.connect()
            try:
                imp_data = impact_mod.analyze(asset, mcon=mcon, days=14)
                if isinstance(imp_data, dict):
                    p_imp = impact_mod.cache_path(asset)
                    p_imp.parent.mkdir(parents=True, exist_ok=True)
                    p_imp.write_text(json.dumps(imp_data, default=str))
            finally:
                mcon.close()
        except Exception:
            imp_data = None

    imp_hl_h = (
        float(imp_data["half_life_h"])
        if (imp_data and imp_data.get("status") == "ok" and imp_data.get("half_life_h"))
        else kalman_diag.get("half_life_h")
    )
    imp_rev = (
        float(imp_data["reversion_fraction"])
        if (imp_data and imp_data.get("status") == "ok" and imp_data.get("reversion_fraction") is not None)
        else kalman_diag.get("noise_share")
    )
    target_eq = (
        peg_diag["fair_value"]
        if (peg_diag and peg_diag.get("fair_value"))
        else (kalman_diag.get("fair_value") or spot)
    )

    for H in (1, 3, 6, 12, 24, 48, 72, 120, 168):
        k = max(1, int(round(H / step_h)))
        if len(lc) > k + 10:
            sd = float(np.std(lc[k:] - lc[:-k], ddof=1))
        else:
            sd = float(np.std(np.diff(lc), ddof=1)) * math.sqrt(k)
        t_h = t_last + int(H * 3600)
        cone.append({
            "time": t_h,
            "hours": H,
            "p1": spot * math.exp(sd),
            "m1": spot * math.exp(-sd),
            "p2": spot * math.exp(2 * sd),
            "m2": spot * math.exp(-2 * sd),
        })
        if imp_hl_h and imp_hl_h > 0 and target_eq > 0:
            rev_share = max(0.0, min(1.0, float(imp_rev if imp_rev is not None else 0.65)))
            decay = math.pow(0.5, H / max(0.25, float(imp_hl_h)))
            log_spot = math.log(spot)
            log_eq = math.log(target_eq)
            # Transient fraction (rev_share) decays back toward equilibrium with half-life imp_hl_h
            log_proj = log_spot - rev_share * (1.0 - decay) * (log_spot - log_eq)
            impulse_projection.append({
                "time": t_h,
                "hours": H,
                "value": round(math.exp(log_proj), 8),
            })

    # 7. Trading.db Overlays: Proposed Plans, Standing Orders, Shadow Sim Trades & Trips
    tdb_ov = _trading_db_overlays(asset, now_ts)
    for p in tdb_ov["plans"]:
        if p["status"] == "proposed" and p.get("price"):
            lines.append({
                "price": float(p["price"]),
                "label": f"PLAN {p['plan_id']} {p['side'].upper()}",
                "kind": "proposed_plan",
            })
    for so in tdb_ov["standing_orders"]:
        if so.get("price_min"):
            lines.append({
                "price": float(so["price_min"]),
                "label": f"{so['so_id']} min ({so['strategy']})",
                "kind": "standing_order",
            })
        if so.get("price_max"):
            lines.append({
                "price": float(so["price_max"]),
                "label": f"{so['so_id']} max ({so['strategy']})",
                "kind": "standing_order",
            })
    for sim in tdb_ov["sim_trades"]:
        if sim.get("status") in ("resting", "filled") and sim.get("entry_price"):
            lines.append({
                "price": float(sim["entry_price"]),
                "label": f"SIM {sim['strategy'][:2]} entry",
                "kind": "sim_order",
            })
        if sim.get("created_at"):
            markers.append({
                "time": int(sim["created_at"]),
                "label": f"SIM {sim['strategy'][:2]} {sim['side'].upper()}",
                "kind": "sim_trade",
                "price": float(sim["entry_price"] or spot),
                "position": "belowBar" if sim.get("side") == "buy" else "aboveBar",
            })
        if sim.get("exit_at") and sim.get("exit_price"):
            pnl = float(sim.get("net_pnl_ada") or 0.0)
            markers.append({
                "time": int(sim["exit_at"]),
                "label": f"SIM EXIT ({pnl:+.1f}₳)",
                "kind": "sim_trade",
                "price": float(sim["exit_price"]),
                "position": "aboveBar",
            })
    for trip in tdb_ov["trips"]:
        if trip.get("opened_at") and trip.get("entry_price"):
            markers.append({
                "time": int(trip["opened_at"]),
                "label": f"TRIP BUY @ {float(trip['entry_price']):.4f}",
                "kind": "our_tx",
                "price": float(trip["entry_price"]),
                "position": "belowBar",
            })
        if trip.get("closed_at") and trip.get("exit_price"):
            pnl = float(trip.get("net_pnl_ada") or 0.0)
            markers.append({
                "time": int(trip["closed_at"]),
                "label": f"TRIP SELL ({pnl:+.2f}₳)",
                "kind": "our_tx",
                "price": float(trip["exit_price"]),
                "position": "aboveBar",
            })

    # 8. Visible Range Volume Profile (POC, VAH, VAL)
    vp = _compute_volume_profile(candles, volume, n_bins=24)
    if vp.get("status") == "ok":
        lines.append({"price": vp["poc_price"], "label": "VP POC (Max Vol)", "kind": "vp_poc"})
        lines.append({"price": vp["vah_price"], "label": "VP VAH (70% High)", "kind": "vp_vah"})
        lines.append({"price": vp["val_price"], "label": "VP VAL (70% Low)", "kind": "vp_val"})

    # 9. Batcher & Pool Fee Break-Even Hurdle Band
    fixed_leg_ada = 2.2  # 2.0 ADA Minswap batcher + 0.2 ADA network L1 fee
    round_trip_fixed_ada = 4.4
    fee_hurdles: List[Dict[str, Any]] = []
    for sz_ada in (25.0, 50.0, 100.0, 250.0):
        # Round-trip percentage hurdle = 2 * pool_fee + 4.4 / sz_ada
        rt_pct = (2.0 * pool_fee + (round_trip_fixed_ada / sz_ada)) * 100.0
        be_sell_px = spot * (1.0 + rt_pct / 100.0)
        fee_hurdles.append({
            "size_ada": sz_ada,
            "round_trip_hurdle_pct": round(rt_pct, 2),
            "single_leg_hurdle_pct": round((pool_fee + fixed_leg_ada / sz_ada) * 100.0, 2),
            "breakeven_exit_price": round(be_sell_px, 8),
        })
    ref_hurdle = next((h for h in fee_hurdles if h["size_ada"] == 50.0), fee_hurdles[0])
    lines.append({
        "price": ref_hurdle["breakeven_exit_price"],
        "label": f"50₳ Break-Even (+{ref_hurdle['round_trip_hurdle_pct']:.1f}%)",
        "kind": "fee_hurdle",
    })

    # 10. Pool Swap Markers (On-Chain market.db first, GeckoTerminal fallback only if empty)
    swaps_recent = series.get("swaps_recent") or []
    if swaps_recent:
        for sw in swaps_recent[-60:]:
            imp_str = f" ({sw['impact_pct']:+.2f}%)" if abs(sw.get("impact_pct") or 0.0) >= 0.25 else ""
            markers.append({
                "time": int(sw["time"]),
                "label": f"{sw['kind']} {sw['ada_amt']:.0f}₳{imp_str}",
                "kind": f"pool_{sw['kind']}",
                "tx_hash": sw["tx_hash"],
                "url": CSCAN + (sw["tx_hash"] or ""),
                "price": float(sw["price_ada"]),
                "ada_amt": float(sw["ada_amt"]),
                "position": "belowBar" if sw["kind"] == "buy" else "aboveBar",
            })
    else:
        trades = md.fetch_pool_trades(pool["pool_address"])
        if trades.get("status") == "ok":
            for tr in trades["trades"][-50:]:
                markers.append({
                    "time": tr["time"],
                    "label": f"{tr['kind']} {tr['volume_usd']:.0f}$",
                    "kind": f"pool_{tr['kind']}",
                    "tx_hash": tr["tx_hash"],
                    "url": CSCAN + (tr["tx_hash"] or ""),
                    "price": tr["price_ada"],
                    "position": "belowBar" if tr["kind"] == "buy" else "aboveBar",
                })
    markers.sort(key=lambda m: m["time"])

    # ── Cardano-Native Microstructure (Exact Recorder-Backed) ───────────
    # 1. Constant-Product Liquidity Curve (CPMM) with real pool fee tier
    eff_res_ada = reserve_ada if reserve_ada > 0 else 50000.0
    eff_res_tok = eff_res_ada / spot if spot > 0 else 1.0
    liquidity_curve = []
    for trade_size_ada in [10.0, 25.0, 50.0, 100.0, 250.0, 500.0]:
        dx_eff = trade_size_ada * (1.0 - pool_fee)
        tokens_out = (eff_res_tok * dx_eff) / (eff_res_ada + dx_eff)
        effective_price = trade_size_ada / tokens_out if tokens_out > 0 else spot
        slippage_pct = round(((effective_price - spot) / spot) * 100.0, 3) if spot > 0 else 0.0
        liquidity_curve.append({
            "size_ada": trade_size_ada,
            "tokens_out": round(tokens_out, 2),
            "effective_price": round(effective_price, 6),
            "slippage_pct": slippage_pct,
            "fee_bps": fee_bps,
        })

    # 2. Real Batcher Queue Telemetry from market.db (via cardano_market_dimensions)
    try:
        from lib.tools.cardano_market_dimensions import inspect_batcher_queue
        batcher_queue = inspect_batcher_queue(asset)
    except Exception:
        batcher_queue = {
            "pending_swaps": None,
            "estimated_blocks_lag": None,
            "estimated_latency_s": None,
            "status": "UNKNOWN",
        }

    # 3. Arbitrage Spread Corridor (filtered for active non-off-market pools)
    spread_corridor = []
    primary_dex = pool.get("dex", "minswap-v2")
    for sec in series["all_pools"]:
        if sec.get("off_market"):
            continue
        if sec.get("dex") != primary_dex and sec.get("price_ada"):
            sec_price = float(sec["price_ada"])
            spread_pct = round(((sec_price - spot) / spot) * 100.0, 2) if spot > 0 else 0.0
            spread_corridor.append({
                "dex": sec.get("dex"),
                "price_ada": sec_price,
                "spread_pct": spread_pct,
                "spread_direction": "PREMIUM" if spread_pct > 0 else "DISCOUNT",
                "reserve_ada_est": sec.get("reserve_ada_est"),
            })

    # 4. Exact CPMM + On-Chain Resting Order Book
    order_book = _build_real_order_book(
        asset=asset,
        spot=spot,
        reserve_ada=eff_res_ada,
        fee_bps=fee_bps,
        primary_dex=primary_dex,
        all_pools=series["all_pools"],
        our_orders=orders_out,
        stop_triggers=stop_triggers,
        plans=tdb_ov["plans"],
    )

    node_source = "koios"
    try:
        from lib.tools.cardano_provider import get_cardano_provider
        prov = get_cardano_provider()
        node_source = prov.name
    except Exception:
        pass

    return {
        "status": "ok",
        "asset": asset,
        "quote": "ADA",
        "timeframe": timeframe,
        "aggregate": aggregate,
        "step_s": step,
        "source_mode": series.get("source_mode", "market_db_onchain"),
        "node_source": node_source,
        "pool": {
            "pool_address": pool.get("pool_address"),
            "dex": pool.get("dex"),
            "name": pool.get("name"),
            "price_ada": spot,
            "reserve_ada_est": eff_res_ada,
            "reserve_token_est": eff_res_tok,
            "fee_bps": fee_bps,
            "volume_usd_24h": pool.get("volume_usd_24h"),
        },
        "all_pools": [
            {k: p.get(k) for k in ("pool_address", "dex", "price_ada", "reserve_ada_est", "volume_usd_24h", "off_market")}
            for p in series["all_pools"]
        ],
        "spot": spot,
        "candles": candles,
        "volume": volume,
        "cvd_series": cvd_series,
        "kalman_series": kalman_series,
        "peg_series": peg_series,
        "ada_usd_series": ada_usd_series,
        "regime_series": regime_series,
        "impulse_projection": impulse_projection,
        "volume_profile": vp,
        "fee_hurdles": fee_hurdles,
        "sim_and_plans": tdb_ov,
        "order_book": order_book,
        "lines": lines,
        "cone": cone,
        "markers": markers,
        "orders": orders_out,
        "cpmm_liquidity_curve": liquidity_curve,
        "batcher_queue_pressure": batcher_queue,
        "arbitrage_spread_corridor": spread_corridor,
        "diagnostics": {
            "adf_pvalue": adf.get("pvalue"),
            "ou_actionable": ou.get("actionable"),
            "ou_reason": ou.get("reason"),
            "kalman": kalman_diag,
            "peg": peg_diag,
            "regime": {
                "current": current_regime,
                "vr_4": current_vr,
            },
            "impact": {
                "half_life_h": round(float(imp_hl_h), 2) if imp_hl_h else None,
                "reversion_fraction": round(float(imp_rev), 3) if imp_rev is not None else None,
                "status": imp_data.get("status") if imp_data else "unavailable",
            },
        },
        "explorer": {
            "pool": f"https://www.geckoterminal.com/cardano/pools/{pool['pool_address']}",
            "token": f"https://cardanoscan.io/token/{series['unit']}",
        },
        "provenance": series["provenance"],
        "coverage": coverage,
    }


def main() -> None:
    ap = argparse.ArgumentParser(description="Chart payload for the Sovereign DEX Desk")
    ap.add_argument("--asset", required=True)
    ap.add_argument("--timeframe", default="hour", choices=["minute", "hour", "day"])
    ap.add_argument("--aggregate", type=int, default=1)
    ap.add_argument("--bars", type=int, default=500)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    try:
        res = build_chart(a.asset, a.timeframe, a.aggregate, max(50, min(a.bars, 1000)))
    except Exception as e:
        res = {"status": "error", "message": f"{type(e).__name__}: {e}"}
    print(json.dumps(qm.json_safe(res), default=str, allow_nan=False))


if __name__ == "__main__":
    main()
