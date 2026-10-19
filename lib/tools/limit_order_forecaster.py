#!/usr/bin/env python3
"""
Cardano limit-order fill forecaster (v2, audited).

What changed versus v1 (and why v1 numbers must not be trusted):
  * v1 used USD-quoted CoinGecko candles divided by a hard-coded ADA price, fell back to a
    fabricated IAG range when rate-limited, extrapolated a 4h "velocity" as drift, and
    computed (but never used) OU parameters. It also ignored the order's on-chain deadline,
    so an expired WingRiders request was reported as "~20h median fill".
  * v2 works in ADA on the actual pool (GeckoTerminal OHLCV), resolves the live order from
    chain (status, deadline, min_receive), converts the limit to the pool spot at which a
    batcher can actually execute the whole order (fee + own price impact), and reports fill
    probability from three independent methods so disagreement is visible:
        - closed-form first passage of driftless Brownian motion in log price,
        - stationary block bootstrap of observed (return, intrabar excursion) pairs,
        - empirical historical hit-rate with Wilson CI on effective sample size,
      plus an OU simulation only when the ADF test supports mean reversion.
  * Drift is assumed zero unless its t-statistic is significant. Nothing is silently faked:
    unavailable inputs are reported as unavailable.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

import numpy as np

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from lib.tools.quant import market_data as md  # noqa: E402
from lib.tools.quant import models as qm  # noqa: E402

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path.home() / "blue-lodge"))
DOSSIER_DIR = Path(os.environ.get("DOSSIER_DIR", LODGE_DIR / "dossiers" / "finance"))

HORIZONS_H = [6, 24, 72, 168]
MAX_BOOT_H = 24 * 30
ORDER_OVERHEAD_ADA = 4.0  # deposit + max batcher fee locked alongside a buy order (WR V1 / Minswap V2)
# Bar highs/lows are fee-inclusive trade prices, so they overstate pool-spot excursions by up to the
# swap fee. Walk-forward calibration (lib/tools/quant/calibration.py) showed 6h odds ~10-20 pts too
# optimistic without this haircut and well calibrated with it.
TOUCH_HAIRCUT = 0.003
CALIBRATION_TTL_S = 6 * 3600


# ---------------------------------------------------------------------------
# Order resolution (chain is the source of truth)
# ---------------------------------------------------------------------------

def _db_order_utxo(asset: str) -> Optional[Dict[str, Any]]:
    try:
        from lib.tools.cardano_maker_db import get_active_cycles
        for c in get_active_cycles():
            if c.get("asset") == asset and c.get("status") in ("PENDING_BUY", "PENDING_SELL"):
                meta = json.loads(c.get("metadata_json") or "{}")
                if meta.get("order_utxo"):
                    return {"utxo": meta["order_utxo"], "db_row": c}
    except Exception:
        return None
    return None


def resolve_order(asset: str, utxo: Optional[str]) -> Dict[str, Any]:
    """Returns the on-chain order (if any) with implied direction/amount/limit price."""
    db = None
    if not utxo:
        db = _db_order_utxo(asset)
        utxo = db["utxo"] if db else None
    if not utxo:
        return {"found": False}
    try:
        from lib.tools import cardano_orders as co
        tx, idx = utxo.split("#")
        d = co.describe_order_output(tx, int(idx))
    except Exception as e:
        return {"found": False, "utxo": utxo, "error": f"chain lookup failed: {e}"}
    unit = co.asset_unit(asset)
    dec = co.asset_decimals(asset)
    locked = d.get("locked_value", {})
    min_recv = (d.get("datum") or {}).get("min_receive")
    out: Dict[str, Any] = {"found": True, "utxo": utxo, "status": d["status"], "protocol": d["protocol"],
                           "limit_semantics": d.get("limit_semantics"), "deadline_iso": d.get("deadline_iso"),
                           "seconds_to_deadline": d.get("seconds_to_deadline"),
                           "cardanoscan_url": d.get("cardanoscan_url"), "protocol_note": d.get("protocol_note"),
                           "db_order_id": (db or {}).get("db_row", {}).get("order_id")}
    if db:
        out["cost_basis_per_token"] = db["db_row"].get("cost_basis_per_token")
    if unit in locked and min_recv:
        amt = locked[unit] / 10 ** dec
        out.update({"direction": "sell", "amount_tokens": amt, "min_receive_ada": min_recv / 1e6,
                    "limit_price": (min_recv / 1e6) / amt if amt else None})
    elif min_recv:
        tokens = min_recv / 10 ** dec
        ada_in = max(locked.get("lovelace", 0) / 1e6 - ORDER_OVERHEAD_ADA, 0.0)
        out.update({"direction": "buy", "amount_tokens": tokens, "ada_offered_est": ada_in,
                    "limit_price": ada_in / tokens if tokens else None})
    return out


# ---------------------------------------------------------------------------
# Market-dump comparison
# ---------------------------------------------------------------------------

def market_alternative(asset: str, direction: str, amount: float, limit_price: float) -> Dict[str, Any]:
    try:
        from lib.tools.cardano_dex_swapper import estimate_swap_route, TOKEN_METADATA
        dec = TOKEN_METADATA.get(asset, {}).get("decimals", 6)
        if direction == "sell":
            est, _ = estimate_swap_route(int(amount * 10 ** dec), asset, "ADA")
            got = float(est.get("amount_out", 0)) / 1e6
            return {"status": "ok", "kind": "market sell now", "receive_ada": got,
                    "limit_receive_ada": amount * limit_price,
                    "limit_premium_ada": amount * limit_price - got,
                    "price_impact_pct": float(est.get("avg_price_impact", 0) or 0),
                    "route": [p.get("protocol") for p in est.get("paths", [[]])[0]] if est.get("paths") else None}
        ada = amount * limit_price
        est, _ = estimate_swap_route(int(ada * 1e6), "ADA", asset)
        got = float(est.get("amount_out", 0)) / 10 ** dec
        return {"status": "ok", "kind": "market buy now", "receive_tokens": got,
                "limit_receive_tokens": amount, "limit_premium_tokens": amount - got,
                "price_impact_pct": float(est.get("avg_price_impact", 0) or 0)}
    except Exception as e:
        return {"status": "unavailable", "reason": f"aggregator estimate failed: {e}"}


# ---------------------------------------------------------------------------
# Core pipeline
# ---------------------------------------------------------------------------

def calibration_summary(asset: str, direction: str, grid: Dict[str, Any]) -> Dict[str, Any]:
    """Walk-forward track record of this model on this pool (no look-ahead), cached for 6h."""
    cache = md.CACHE_DIR / f"calibration_{asset}_{direction}.json"
    try:
        if cache.exists() and time.time() - cache.stat().st_mtime < CALIBRATION_TTL_S:
            return json.loads(cache.read_text())
        from lib.tools.quant.calibration import calibrate
        cal = calibrate(grid["o"], grid["h"], grid["l"], grid["c"], direction, (0.5, 1.0, 2.0, 3.0), (6, 24, 72),
                        step=6, touch_haircut=TOUCH_HAIRCUT, pred_haircut=TOUCH_HAIRCUT)
        if cal.get("status") != "ok":
            return cal
        blend = cal["overall"]["hit_conservative"]["blend"]
        out = {"status": "ok", "method": "walk-forward, 336h window, fee-haircut touches",
               "n_predictions": cal["n_predictions"], "brier": blend["brier"],
               "brier_skill_vs_base_rate": blend["brier_skill_vs_base_rate"],
               "reliability": blend["reliability"],
               "by_cell": [{k: r[k] for k in ("level_pct", "H", "pred_blend", "realized_conservative")}
                           for r in cal["by_cell"]],
               "computed_at": int(time.time())}
        md.CACHE_DIR.mkdir(parents=True, exist_ok=True)
        cache.write_text(json.dumps(qm.json_safe(out)))
        return out
    except Exception as e:  # calibration is advisory; never break the forecast
        return {"status": "unavailable", "reason": str(e)[:200]}


def horizon_sigma(log_close: np.ndarray, H: int, fallback: float) -> float:
    """Per-hour sigma implied by overlapping H-hour log returns. Under a random walk this equals the
    hourly sigma; with short-horizon mean reversion (variance ratio < 1) it is smaller, so sqrt(t)
    scaling of the hourly sigma would overstate long-horizon fill odds."""
    H = int(min(H, max(len(log_close) // 10, 1)))
    if H <= 1 or len(log_close) <= H + 10:
        return fallback
    d = log_close[H:] - log_close[:-H]
    return float(np.std(d, ddof=1) / math.sqrt(H))


def price_ladder(asset: str, direction: str, amount: float, prices: Optional[List[float]] = None,
                 horizons: Optional[List[int]] = None, n_rungs: int = 15, span_pct: float = 4.0,
                 series: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Calibrated fill odds for a ladder of candidate limit prices from one data load.

    Uses the same touch definition as the full forecast (CPMM trigger incl. own impact + fee
    haircut) and the median of closed-form (horizon sigma) and empirical hit rates. Cheap enough to
    run inside reactors. Sell ladders go from spot upward, buy ladders from spot downward."""
    asset, direction = asset.upper(), direction.lower()
    horizons = sorted(set(horizons or [6, 24, 72, 168]))
    series = series or md.load_series(asset, "hour", 1)
    if series.get("status") != "ok":
        return {"status": "error", "reason": f"market data unavailable: {series.get('reason')}"}
    pool, g = series["pool"], series["grid"]
    spot = float(pool["price_ada"])
    o, h, l, c = g["o"], g["h"], g["l"], g["c"]
    lc = np.log(c)
    vol = qm.volatility_estimators(o, h, l, c)
    sigma = float(vol.get("close_to_close", 0.0)) if vol.get("status") == "ok" else 0.0
    sH = {H: horizon_sigma(lc, H, sigma) for H in horizons}
    sgn = 1.0 if direction == "sell" else -1.0
    if not prices:
        prices = [spot * (1 + sgn * span_pct / 100.0 * i / max(n_rungs - 1, 1)) for i in range(n_rungs)]
    rungs = []
    for p in prices:
        trig = qm.cpmm_trigger_price(direction, amount, p, pool.get("reserve_token_est") or 0,
                                     pool.get("reserve_ada_est") or 0)
        trigger = trig["trigger_spot"] if trig.get("status") == "ok" else p
        log_d = math.log(trigger / spot)
        already = (direction == "sell" and log_d <= 0) or (direction == "buy" and log_d >= 0)
        log_t = log_d + sgn * math.log(1 + TOUCH_HAIRCUT)
        odds = {}
        for H in horizons:
            if already:
                odds[f"{H}h"] = 1.0
                continue
            cf = qm.gbm_hit_probability(log_t, sH[H], H, 0.0)
            emp = qm.empirical_hit_rate(o, h, l, c, log_t, H)
            vals = [cf] + ([emp["p"]] if emp.get("status") == "ok" and emp.get("p") is not None else [])
            odds[f"{H}h"] = round(float(np.median(vals)), 4)
        rungs.append({"price": round(p, 8), "trigger_spot": round(trigger, 8),
                      "premium_pct": round((p / spot - 1) * 100, 3),
                      "gross_ada" if direction == "sell" else "cost_ada": round(p * amount, 6),
                      "fill_probability": odds})
    return {"status": "ok", "asset": asset, "direction": direction.upper(), "amount_tokens": amount,
            "spot_price_ada": spot, "sigma_hourly": sigma, "touch_haircut": TOUCH_HAIRCUT,
            "coverage": series.get("coverage"), "rungs": rungs,
            "method": "median(closed-form w/ horizon sigma, empirical hit rate); CPMM trigger + fee haircut"}


def choose_rung(ladder: Dict[str, Any], horizon: str = "24h", min_prob: float = 0.7) -> Optional[Dict[str, Any]]:
    """Best price (highest for sells, lowest for buys) whose fill odds at `horizon` meet `min_prob`."""
    ok = [r for r in ladder.get("rungs", []) if (r["fill_probability"].get(horizon) or 0) >= min_prob]
    if not ok:
        return None
    return max(ok, key=lambda r: r["price"]) if ladder.get("direction") == "SELL" else min(ok, key=lambda r: r["price"])


def _r(x, n=4):
    return None if x is None or (isinstance(x, float) and not math.isfinite(x)) else round(float(x), n)


def generate_limit_order_forecast(asset: str, target_price: Optional[float] = None, amount: Optional[float] = None,
                                  direction: str = "sell", capital_ada: float = 120.0, write_dossier: bool = True,
                                  deadline_hours: Optional[float] = None, utxo: Optional[str] = None,
                                  pool_address: Optional[str] = None, hypothetical: bool = False) -> Dict[str, Any]:
    asset = asset.upper()
    direction = direction.lower()
    ts = int(time.time())
    warnings: List[str] = []

    # 1. On-chain order. If the caller's price matches the live order (or none was given),
    #    analyse that order; otherwise the request is a hypothetical relist.
    order = resolve_order(asset, utxo)
    lp = order.get("limit_price")
    matches = bool(order.get("found") and lp and not hypothetical
                   and (utxo or target_price is None or abs(target_price / lp - 1) <= 0.01))
    if matches:
        direction = order["direction"]
        target_price = target_price or lp
        amount = amount or order["amount_tokens"]
        if deadline_hours is None and order.get("seconds_to_deadline") is not None:
            deadline_hours = order["seconds_to_deadline"] / 3600.0
    elif order.get("found"):
        order = {**order, "hypothetical": True,
                 "note": "Requested price differs from the live order; analysing a hypothetical new order."}
    if order.get("error"):
        warnings.append(order["error"])

    # 2. Market data in ADA
    series = md.load_series(asset, "hour", 1, pool_address=pool_address)
    if series.get("status") != "ok":
        return {"status": "error", "asset": asset, "message": f"market data unavailable: {series.get('reason')}",
                "order": order}
    pool, g = series["pool"], series["grid"]
    spot = float(pool["price_ada"])
    if not target_price or target_price <= 0:
        return {"status": "error", "asset": asset, "message": "no target price given and no live order found",
                "spot_price_ada": spot, "order": order}
    if not amount or amount <= 0:
        amount = capital_ada / target_price
        warnings.append(f"amount not given; sized from capital {capital_ada} ADA")

    o, h, l, c = g["o"], g["h"], g["l"], g["c"]
    lc = np.log(c)
    rets = np.diff(lc)

    # 3. Diagnostics
    vol = qm.volatility_estimators(o, h, l, c)
    adf = qm.adf_test(lc)
    vr = qm.variance_ratio_test(lc)
    hurst = qm.hurst_dfa(rets)
    drift = qm.drift_estimate(rets)
    ou = qm.fit_ou(lc, 1.0, adf)
    sigma = float(vol.get("close_to_close", 0.0)) if vol.get("status") == "ok" else 0.0
    sig_ci = vol.get("close_to_close_ci95", [sigma, sigma])
    nu = drift["mean_per_bar"] if drift.get("significant_5pct") else 0.0
    if series["coverage"] < 0.5:
        warnings.append(f"only {series['coverage']:.0%} of hourly bars had trades; estimates are noisy")

    # 4. Executable trigger (pool spot at which a batcher can fill the whole order)
    trig = qm.cpmm_trigger_price(direction, amount, target_price, pool.get("reserve_token_est") or 0,
                                 pool.get("reserve_ada_est") or 0)
    trigger = trig["trigger_spot"] if trig.get("status") == "ok" else target_price
    if trig.get("status") != "ok":
        warnings.append("pool reserves unavailable; using raw limit price as trigger (ignores own impact)")
    log_d = math.log(trigger / spot)
    already = (direction == "sell" and log_d <= 0) or (direction == "buy" and log_d >= 0)
    # Distance used for touch probabilities (fee-inclusive trade prints must clear the haircut).
    log_d_touch = log_d + (math.log(1 + TOUCH_HAIRCUT) if direction == "sell" else -math.log(1 + TOUCH_HAIRCUT))

    horizons = list(HORIZONS_H)
    if deadline_hours is not None and deadline_hours > 0 and int(round(deadline_hours)) not in horizons:
        horizons.append(max(1, int(round(min(deadline_hours, MAX_BOOT_H)))))
    horizons = sorted(set(horizons))

    expired = matches and order.get("status") == "EXPIRED"
    closed = matches and order.get("status") in ("FILLED", "CANCELLED", "CONSUMED")

    # 5. Fill probabilities
    rows = []
    boot = qm.block_bootstrap_hit(o, h, l, c, log_d_touch, horizons, demean=(nu == 0.0)) if not already else {}
    for H in horizons:
        if already:
            rows.append({"hours": H, "closed_form": 1.0, "closed_form_band": [1.0, 1.0], "bootstrap": 1.0,
                         "empirical": 1.0, "empirical_ci95": [1.0, 1.0]})
            continue
        sH = horizon_sigma(lc, H, sigma)
        scale = sH / sigma if sigma else 1.0
        cf = qm.gbm_hit_probability(log_d_touch, sH, H, nu)
        band = sorted([qm.gbm_hit_probability(log_d_touch, s * scale, H, nu) for s in sig_ci])
        emp = qm.empirical_hit_rate(o, h, l, c, log_d_touch, H)
        rows.append({
            "hours": H,
            "closed_form": cf,
            "closed_form_band": band,
            "sigma_per_hour_at_horizon": sH,
            "bootstrap": (boot.get("p_by_horizon_bars") or {}).get(str(H)),
            "empirical": emp.get("p") if emp.get("status") == "ok" else None,
            "empirical_ci95": emp.get("ci95"),
            "empirical_n_eff": _r(emp.get("n_effective"), 1),
            "past_deadline": bool(deadline_hours is not None and H > deadline_hours),
        })
    ou_sim = qm.ou_hit_probability(spot, trigger, ou, horizons, 1.0) if not already else {"status": "skipped"}
    for row in rows:
        if ou_sim.get("status") == "ok":
            row["ou"] = ou_sim["p_by_horizon_h"].get(str(row["hours"]))
        # A request with a hard deadline cannot fill after it.
        if expired or closed or row.get("past_deadline"):
            row["effective"] = 0.0
        else:
            vals = [v for v in (row.get("bootstrap"), row.get("closed_form"), row.get("empirical")) if v is not None]
            row["effective"] = float(np.median(vals)) if vals else None

    median_cf = qm.gbm_median_hit_hours(log_d_touch, horizon_sigma(lc, 24, sigma)) if not already else 0.0
    median_boot = boot.get("median_hit_bars") if boot else (0.0 if already else None)

    # 6. Verdict
    dist_pct = (trigger / spot - 1) * 100
    p_dead = None
    if deadline_hours is not None and deadline_hours > 0 and not already:
        r_dead = next((r for r in rows if r["hours"] == max(1, int(round(min(deadline_hours, MAX_BOOT_H))))), None)
        if r_dead:
            p_dead = r_dead.get("bootstrap") if r_dead.get("bootstrap") is not None else r_dead.get("closed_form")
    if expired:
        verdict = ("EXPIRED: this order's deadline has passed; batchers will never execute it. "
                   "P(fill)=0. Reclaim the locked funds and, if desired, relist as a Minswap V2 limit "
                   "order (no deadline).")
        action = "reclaim"
    elif closed:
        verdict = f"Order already {order['status']} on-chain."
        action = "none"
    elif already:
        verdict = "Pool spot is already through the executable trigger; a batcher should fill on the next batch."
        action = "wait_for_batch"
    else:
        p24 = next(r for r in rows if r["hours"] == 24)
        p168 = next(r for r in rows if r["hours"] == 168)
        verdict = (f"Trigger is {dist_pct:+.2f}% from spot ({abs(log_d) / sigma if sigma else float('inf'):.1f} "
                   f"hourly sigmas). Fill ~{(p24['effective'] or 0) * 100:.0f}% within 24h, "
                   f"~{(p168['effective'] or 0) * 100:.0f}% within 7d (median of methods).")
        action = "hold" if (p168["effective"] or 0) >= 0.5 else "consider_repricing"
        if p_dead is not None:
            verdict += f" P(fill before deadline) ≈ {p_dead * 100:.0f}%."

    alt = market_alternative(asset, direction, amount, target_price)

    result: Dict[str, Any] = {
        "status": "success",
        "schema": "limit_order_forecast/v2",
        "timestamp": ts,
        "iso_time": time.strftime("%Y-%m-%d %H:%M:%SZ", time.gmtime(ts)),
        "asset": asset,
        "direction": direction.upper(),
        "amount_tokens": _r(amount, 6),
        "spot_price_ada": _r(spot, 6),
        "target_price_ada": _r(target_price, 6),
        "trigger_spot_ada": _r(trigger, 6),
        "trigger": {k: _r(v, 6) if isinstance(v, float) else v for k, v in trig.items()},
        "distance_pct": _r(dist_pct, 3),
        "distance_sigmas": _r(abs(log_d) / sigma, 2) if sigma else None,
        "deadline_hours": _r(deadline_hours, 2),
        "order": order,
        "verdict": verdict,
        "recommended_action": action,
        "fill_probability": [{k: (_r(v) if isinstance(v, float) else ([_r(x) for x in v] if isinstance(v, list) else v))
                              for k, v in row.items()} for row in rows],
        "median_hit_hours": {"closed_form": _r(median_cf, 1),
                             "bootstrap": _r(median_boot, 1) if median_boot is not None else None,
                             "note": "bootstrap median is null when fewer than half of paths hit within 30 days"},
        "volatility": {"sigma_hourly": _r(sigma, 5), "sigma_hourly_ci95": [_r(x, 5) for x in sig_ci],
                       "sigma_daily_equiv": _r(sigma * math.sqrt(24), 4),
                       "estimators": {k: _r(vol.get(k), 5) for k in
                                      ("close_to_close", "parkinson", "garman_klass", "rogers_satchell",
                                       "yang_zhang", "ewma")},
                       "zero_return_fraction": _r(vol.get("zero_return_fraction"), 3)},
        "diagnostics": {
            "adf": {k: adf.get(k) for k in ("statistic", "pvalue", "lags", "nobs", "interpretation")},
            "variance_ratio": vr,
            "hurst": {k: hurst.get(k) for k in ("hurst", "label")},
            "drift": {k: drift.get(k) for k in ("mean_per_bar", "t_stat", "significant_5pct")},
            "drift_used_per_hour": nu,
            "ou": {k: ou.get(k) for k in ("actionable", "reason", "half_life_hours", "half_life_ci95_hours",
                                          "mu_price", "band_1sd", "band_2sd")},
        },
        "market_alternative": alt,
        "calibration": calibration_summary(asset, direction, g),
        "data": {"pool": {k: pool.get(k) for k in ("pool_address", "dex", "name", "reserve_ada_est",
                                                   "reserve_token_est", "volume_usd_24h", "off_market")},
                 "bars": int(len(c)), "coverage": _r(series["coverage"], 3),
                 "span_hours": int(len(c)), "provenance": series["provenance"]},
        "warnings": warnings,
    }
    result["dossier_markdown"] = render_dossier(result)
    if write_dossier:
        DOSSIER_DIR.mkdir(parents=True, exist_ok=True)
        p = DOSSIER_DIR / f"limit_order_forecast_{asset}_{ts}.md"
        p.write_text(result["dossier_markdown"])
        result["dossier_path"] = str(p)
    return result


def _pct(v):
    return "—" if v is None else f"{v * 100:.1f}%"


def render_dossier(r: Dict[str, Any]) -> str:
    o = r["order"]
    d = r["diagnostics"]
    lines = [
        f"# Limit Order Fill Forecast: {r['asset']}/ADA ({r['direction']})",
        "",
        f"**Generated:** `{r['iso_time']}` · schema `{r['schema']}`  ",
        f"**Size:** `{r['amount_tokens']:,} {r['asset']}` · **Limit:** `{r['target_price_ada']} ADA` · "
        f"**Executable trigger (fee + own impact):** `{r['trigger_spot_ada']} ADA`  ",
        f"**Pool spot:** `{r['spot_price_ada']} ADA` ({r['data']['pool'].get('dex')}) · "
        f"**Distance:** `{r['distance_pct']:+}%` = `{r['distance_sigmas']}σ` hourly",
        "",
        f"> **Verdict:** {r['verdict']}",
        "",
    ]
    if o.get("found"):
        lines += ["## On-chain order", "",
                  f"- UTxO: [`{o['utxo']}`]({o.get('cardanoscan_url')}) · protocol **{o.get('protocol')}** · "
                  f"status **{o.get('status')}**",
                  f"- Deadline: `{o.get('deadline_iso') or 'none (true limit order)'}`",
                  f"- {o.get('protocol_note')}", ""]
    lines += ["## Fill probability by horizon", "",
              "| Horizon | Closed-form (σ CI band) | Bootstrap | Empirical (95% CI) | OU | **Effective** |",
              "| :-- | :-- | :-- | :-- | :-- | :-- |"]
    for row in r["fill_probability"]:
        band = row.get("closed_form_band") or [None, None]
        ci = row.get("empirical_ci95") or [None, None]
        tag = " (past deadline)" if row.get("past_deadline") else ""
        lines.append(f"| {row['hours']}h{tag} | {_pct(row.get('closed_form'))} ({_pct(band[0])}–{_pct(band[1])}) | "
                     f"{_pct(row.get('bootstrap'))} | {_pct(row.get('empirical'))} ({_pct(ci[0])}–{_pct(ci[1])}) | "
                     f"{_pct(row.get('ou'))} | **{_pct(row.get('effective'))}** |")
    m = r["median_hit_hours"]
    lines += ["", f"Median time to trigger: closed-form `{m['closed_form']}h`, bootstrap `{m['bootstrap']}h`.",
              "The mean first-passage time of a driftless walk is infinite, so no mean is reported.", "",
              "## Model diagnostics", "",
              f"- σ hourly (close-to-close on forward-filled grid): `{r['volatility']['sigma_hourly']}` "
              f"(95% CI {r['volatility']['sigma_hourly_ci95']}), daily-equivalent `{r['volatility']['sigma_daily_equiv']}`",
              f"- ADF: τ=`{_r(d['adf'].get('statistic'), 3)}`, p=`{_r(d['adf'].get('pvalue'), 3)}` → {d['adf'].get('interpretation')}",
              f"- Variance ratio: {d['variance_ratio'].get('verdict')}",
              f"- Hurst (DFA): `{_r(d['hurst'].get('hurst'), 3)}` ({d['hurst'].get('label')})",
              f"- Drift t-stat `{_r(d['drift'].get('t_stat'), 2)}` → drift used: `{d['drift_used_per_hour']}`",
              f"- OU actionable: **{d['ou'].get('actionable')}** — {d['ou'].get('reason')}", ""]
    a = r["market_alternative"]
    lines += ["## Limit vs market now", ""]
    if a.get("status") == "ok" and "receive_ada" in a:
        lines.append(f"- Market sell now: `{a['receive_ada']:.4f} ADA` vs limit `{a['limit_receive_ada']:.4f} ADA` "
                     f"→ waiting is worth `{a['limit_premium_ada']:+.4f} ADA` if it fills.")
    elif a.get("status") == "ok":
        lines.append(f"- Market buy now: `{a['receive_tokens']:.4f}` vs limit `{a['limit_receive_tokens']:.4f}` tokens.")
    else:
        lines.append(f"- {a.get('reason')}")
    lines += ["", "## Data provenance", "",
              f"- Pool `{r['data']['pool'].get('pool_address')}` · {r['data']['bars']} hourly bars · "
              f"{(r['data']['coverage'] or 0) * 100:.0f}% traded",
              f"- OHLCV: {r['data']['provenance']['ohlcv'].get('url')} (age {r['data']['provenance']['ohlcv'].get('age_s')}s)"]
    if r["warnings"]:
        lines += ["", "## Warnings", ""] + [f"- {w}" for w in r["warnings"]]
    return "\n".join(lines) + "\n"


def main() -> None:
    p = argparse.ArgumentParser(description="Cardano limit order fill forecaster (v2)")
    p.add_argument("--asset", default="IAG")
    p.add_argument("--target-price", type=float, default=None, help="Limit price in ADA (auto from live order)")
    p.add_argument("--amount", type=float, default=None, help="Token amount (auto from live order)")
    p.add_argument("--direction", default="sell", choices=["sell", "buy"])
    p.add_argument("--capital", type=float, default=120.0)
    p.add_argument("--deadline", type=float, default=None, help="Hours until the order deadline, if any")
    p.add_argument("--utxo", default=None, help="Order UTxO ref tx#ix to analyse")
    p.add_argument("--pool", default=None, help="Pin a specific pool address")
    p.add_argument("--hypothetical", action="store_true", help="Price a new order; never snap to a live order")
    p.add_argument("--ladder", action="store_true", help="Print a calibrated price ladder (needs --amount)")
    p.add_argument("--span-pct", type=float, default=4.0)
    p.add_argument("--rungs", type=int, default=15)
    p.add_argument("--no-dossier", action="store_true")
    p.add_argument("--json", action="store_true")
    a = p.parse_args()
    if a.ladder:
        if not a.amount:
            p.error("--ladder requires --amount")
        lad = price_ladder(a.asset, a.direction, a.amount, None, None, a.rungs, a.span_pct)
        print(json.dumps(qm.json_safe(lad), indent=2, default=str, allow_nan=False))
        return
    if a.hypothetical and a.target_price is None:
        p.error("--hypothetical requires --target-price")
    res = generate_limit_order_forecast(a.asset, a.target_price, a.amount, a.direction, a.capital,
                                        not a.no_dossier, a.deadline, a.utxo, a.pool, a.hypothetical)
    if a.json:
        print(json.dumps(qm.json_safe(res), indent=2, default=str, allow_nan=False))
    else:
        print(res.get("dossier_markdown") or json.dumps(res, indent=2, default=str))
        if res.get("dossier_path"):
            print(f"\n[Dossier saved to: {res['dossier_path']}]")


if __name__ == "__main__":
    main()
