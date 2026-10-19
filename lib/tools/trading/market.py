#!/usr/bin/env python3
"""
Market context per asset for the trading layer: exact spot / reserves / fee tier from the pool
recorder when fresh, GeckoTerminal estimates otherwise (labelled), horizon sigmas and fair value.
Cached per process for 60 s so one tool call never fetches the same asset twice.
"""
from __future__ import annotations

import time
from typing import Any, Dict, List, Optional

_CACHE: Dict[str, Any] = {}
_TTL_S = 60


def market_ctx(asset: str, use_cache: bool = True) -> Dict[str, Any]:
    asset = asset.upper()
    hit = _CACHE.get(asset)
    if use_cache and hit and time.time() - hit["_at"] < _TTL_S:
        return hit
    out: Dict[str, Any] = {"asset": asset, "status": "ok", "_at": time.time()}
    try:
        from lib.tools.quant import market_db as mdb
        con = mdb.connect()
        try:
            st = mdb.fresh_pool_state(con, asset)
            act = mdb.batch_activity(con, asset, 86400)
        finally:
            con.close()
    except Exception:
        st, act = None, None
    if st:
        out.update({"spot": st["spot"], "spot_source": "pool_recorder_exact", "reserve_ada": st["reserve_ada"],
                    "reserve_source": "pool_recorder_exact", "fee_bps": st.get("fee_bps"),
                    "recorder_checked_age_s": st.get("checked_age_s")})
    if act:
        out["batches_24h"] = act["batches"]
        out["measured_batcher_fee_ada"] = act["measured_batcher_fee_ada"]
    try:
        from lib.tools.quant.fair_value import fair_value
        fv = fair_value(asset)
    except Exception as e:
        fv = {"status": "error", "reason": f"{type(e).__name__}: {e}"}
    out["fair_value_detail"] = fv
    if fv.get("status") == "ok":
        out.setdefault("spot", fv.get("spot"))
        out.setdefault("spot_source", fv.get("source"))
        out["sigma_1h"] = fv.get("sigma_1h")
        out["sigma_24h"] = fv.get("sigma_24h")
        s3 = fv.get("s3") or {}
        s2 = fv.get("s2") or {}
        if s3.get("status") == "ok":
            out["fair_value"] = s3.get("fair_value")
            out["fair_value_model"] = "S3: 1/ADAUSD (Coinbase)"
            out["deviation_sigma"] = s3.get("deviation_sigma")
        elif s2.get("fair_value"):
            out["fair_value"] = s2["fair_value"]
            out["fair_value_model"] = "S2: Kalman local level"
            out["deviation_sigma"] = s2.get("deviation_sigma")
    if "reserve_ada" not in out:
        try:
            from lib.tools.quant.market_data import list_ada_pools
            pools = list_ada_pools(asset)
            p = next((p for p in pools.get("pools", []) if not p.get("off_market")), None)
            if p:
                out.setdefault("spot", p.get("price_ada"))
                out.setdefault("spot_source", "geckoterminal")
                out["reserve_ada"] = p.get("reserve_ada_est")
                out["reserve_source"] = "geckoterminal_estimate"
        except Exception:
            pass
    if out.get("fee_bps") is None:
        out["fee_bps"] = None
        out["fee_note"] = "pool fee tier not recorded yet (Minswap V2 tiers vary: SNEK is 1%)"
    if not out.get("spot"):
        out["status"] = "unavailable"
    _CACHE[asset] = out
    return out


def market_for(assets: List[str]) -> Dict[str, Dict[str, Any]]:
    return {a.upper(): market_ctx(a) for a in assets}


def clear_cache() -> None:
    _CACHE.clear()


def public(m: Dict[str, Any]) -> Dict[str, Any]:
    """Compact, LLM-friendly view."""
    keys = ("asset", "status", "spot", "spot_source", "fair_value", "fair_value_model", "deviation_sigma",
            "sigma_1h", "sigma_24h", "reserve_ada", "reserve_source", "fee_bps", "batches_24h",
            "measured_batcher_fee_ada", "fee_note")
    out = {k: m.get(k) for k in keys if m.get(k) is not None}
    fv = m.get("fair_value_detail") or {}
    s2 = fv.get("s2") or {}
    if s2.get("vr_24h") is not None:
        out["regime"] = {"vr_24h": round(s2["vr_24h"], 3), "noise_share": round(s2.get("noise_share", 0), 3),
                         "half_life_h": round(s2.get("half_life_h", 0), 2), "source": fv.get("source")}
    return out


def optional_float(x: Any) -> Optional[float]:
    try:
        return float(x) if x is not None else None
    except (TypeError, ValueError):
        return None
