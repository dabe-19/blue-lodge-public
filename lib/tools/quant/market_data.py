#!/usr/bin/env python3
"""
On-chain DEX market data for Cardano native assets, quoted in ADA.

Source: GeckoTerminal public API (indexes Minswap / WingRiders / SundaeSwap pools
directly from chain). Every result carries a provenance block. There are NO
fabricated fallbacks: if data cannot be fetched and no cache exists, callers get
``{"status": "unavailable", ...}`` and must surface that, not invent numbers.

AMM microstructure note
-----------------------
A constant-product pool's price only changes when a swap executes. Hours with no
trades therefore have a *known* price equal to the previous close, so forward-
filling missing bars is exact (not an approximation). Range estimators also need
the previous close folded into each bar's high/low, because the first trade in a
bar moves the price away from the previous close and the indexer reports that
first trade as the bar's open.
"""
from __future__ import annotations

import calendar
import hashlib
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional

import numpy as np

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path.home() / "blue-lodge"))
GEORGE_DIR = Path(os.environ.get("GEORGE_DIR", LODGE_DIR / ".george"))
FINANCE_DIR = Path(os.environ.get("FINANCE_DIR", GEORGE_DIR / "finance"))
CACHE_DIR = FINANCE_DIR / "market_cache"

GT_BASE = "https://api.geckoterminal.com/api/v2"
GT_NETWORK = "cardano"
ADA_GT_ID = "cardano_0x"
UA = "BlueLodge-MarketData/2.0"

# symbol -> {unit, decimals}, sourced from the canonical registry (lib/tools/quant/tokens.py).
# tokens.py is pure data, so the quant layer still does not import the signing stack.
from lib.tools.quant import tokens as _tokens  # noqa: E402
KNOWN_ASSETS: Dict[str, Dict[str, Any]] = _tokens.unit_table()

TIMEFRAME_SECONDS = {"minute": 60, "hour": 3600, "day": 86400}
_TTL = {"pools": 60, "ohlcv_minute": 60, "ohlcv_hour": 180, "ohlcv_day": 3600, "trades": 30}


def resolve_unit(symbol_or_unit: str) -> str:
    s = symbol_or_unit.strip()
    meta = KNOWN_ASSETS.get(s.upper())
    if meta:
        return meta["unit"]
    if all(c in "0123456789abcdefABCDEF" for c in s) and len(s) >= 56:
        return s.lower()
    raise ValueError(f"Unknown asset '{symbol_or_unit}'. Pass a symbol in {sorted(KNOWN_ASSETS)} or a policy+name hex unit.")


def _cache_path(key: str) -> Path:
    # Minswap pool addresses share a 56-char script-hash prefix, so never truncate;
    # hash the full key instead.
    digest = hashlib.sha256(key.encode()).hexdigest()[:32]
    prefix = "".join(c if c.isalnum() else "_" for c in key.split("_", 1)[0])[:16]
    return CACHE_DIR / f"{prefix}_{digest}.json"


_MIN_INTERVAL_S = 2.1  # GeckoTerminal public API: ~30 requests/minute
_PACE_FILE = CACHE_DIR / ".last_request"


def _pace() -> None:
    """Cross-process pacing so concurrent tools do not trip the public rate limit."""
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        last = float(_PACE_FILE.read_text()) if _PACE_FILE.exists() else 0.0
    except (OSError, ValueError):
        last = 0.0
    wait = last + _MIN_INTERVAL_S - time.time()
    if 0 < wait <= _MIN_INTERVAL_S:
        time.sleep(wait)
    try:
        _PACE_FILE.write_text(str(time.time()))
    except OSError:
        pass


def _http_json(url: str, timeout: int = 15) -> Any:
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    delays = (3.0, 8.0, 20.0)
    for attempt in range(len(delays) + 1):
        _pace()
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            if (e.code == 429 or e.code >= 500) and attempt < len(delays):
                retry_after = e.headers.get("Retry-After") if e.headers else None
                try:
                    d = min(float(retry_after), 30.0) if retry_after else delays[attempt]
                except ValueError:
                    d = delays[attempt]
                time.sleep(d)
                continue
            raise


def _cached_get(key: str, url: str, ttl: int) -> Dict[str, Any]:
    """Returns {"data", "fetched_at", "from_cache", "stale"} or raises if nothing usable."""
    path = _cache_path(key)
    cached = None
    if path.exists():
        try:
            cached = json.loads(path.read_text())
        except Exception:
            cached = None
    now = time.time()
    if cached and now - cached.get("fetched_at", 0) < ttl:
        return {"data": cached["data"], "fetched_at": cached["fetched_at"], "from_cache": True, "stale": False}
    try:
        data = _http_json(url)
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"fetched_at": now, "url": url, "data": data}))
        tmp.replace(path)
        return {"data": data, "fetched_at": now, "from_cache": False, "stale": False}
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as e:
        if cached:
            return {"data": cached["data"], "fetched_at": cached["fetched_at"], "from_cache": True,
                    "stale": True, "error": str(e)}
        raise


def _provenance(src: Dict[str, Any], url: str) -> Dict[str, Any]:
    return {
        "source": "geckoterminal",
        "url": url,
        "fetched_at": int(src["fetched_at"]),
        "age_s": int(time.time() - src["fetched_at"]),
        "from_cache": src["from_cache"],
        "stale": src.get("stale", False),
        **({"fetch_error": src["error"]} if src.get("error") else {}),
    }


def list_ada_pools(symbol_or_unit: str, ttl: Optional[int] = None) -> Dict[str, Any]:
    """All indexed pools pairing the asset with ADA, sorted by reserve (deepest first)."""
    unit = resolve_unit(symbol_or_unit)
    url = f"{GT_BASE}/networks/{GT_NETWORK}/tokens/{unit}/pools?page=1"
    try:
        src = _cached_get(f"pools_{unit}", url, int(ttl if ttl is not None else _TTL["pools"]))
    except Exception as e:
        return {"status": "unavailable", "reason": f"pool list fetch failed: {e}", "unit": unit}
    pools = []
    for p in src["data"].get("data", []):
        rel = p.get("relationships", {})
        base = rel.get("base_token", {}).get("data", {}).get("id", "")
        quote = rel.get("quote_token", {}).get("data", {}).get("id", "")
        if {base, quote} != {f"{GT_NETWORK}_{unit}", ADA_GT_ID}:
            continue
        a = p.get("attributes", {})
        asset_is_base = base == f"{GT_NETWORK}_{unit}"
        try:
            price_ada = float(a["base_token_price_quote_token"]) if asset_is_base else float(a["quote_token_price_base_token"])
        except (KeyError, TypeError, ValueError):
            continue
        reserve_usd = float(a.get("reserve_in_usd") or 0)
        ada_usd = float((a.get("quote_token_price_usd") if asset_is_base else a.get("base_token_price_usd")) or 0)
        # CPMM pools hold equal value on each side.
        ada_reserve = (reserve_usd / 2 / ada_usd) if ada_usd > 0 else None
        token_reserve = (ada_reserve / price_ada) if ada_reserve and price_ada > 0 else None
        pools.append({
            "pool_address": a.get("address") or p["id"].split("_", 1)[-1],
            "dex": rel.get("dex", {}).get("data", {}).get("id", "unknown"),
            "name": a.get("name"),
            "asset_is_base": asset_is_base,
            "price_ada": price_ada,
            "ada_usd": ada_usd or None,
            "reserve_usd": reserve_usd,
            "reserve_ada_est": ada_reserve,
            "reserve_token_est": token_reserve,
            "volume_usd_24h": float((a.get("volume_usd") or {}).get("h24") or 0),
            "tx_24h": (a.get("transactions") or {}).get("h24"),
        })
    # Dead pools keep stale prices (and therefore bogus USD reserves); rank by actual
    # activity and flag anything priced >15% away from the most active pool.
    pools.sort(key=lambda x: (x["volume_usd_24h"], x["reserve_usd"]), reverse=True)
    ref = pools[0]["price_ada"] if pools else None
    for p in pools:
        p["off_market"] = bool(ref and abs(p["price_ada"] / ref - 1) > 0.15) or p["volume_usd_24h"] <= 0
    pools.sort(key=lambda x: (not x["off_market"], x["volume_usd_24h"]), reverse=True)
    return {"status": "ok", "unit": unit, "pools": pools, "provenance": _provenance(src, url)}


def fetch_ohlcv(pool_address: str, timeframe: str = "hour", aggregate: int = 1,
                limit: int = 1000, asset_is_base: bool = True, ttl: Optional[int] = None) -> Dict[str, Any]:
    """Raw OHLCV bars in ADA (ascending time). Bars only exist where trades happened."""
    if timeframe not in TIMEFRAME_SECONDS:
        raise ValueError("timeframe must be minute|hour|day")
    q = urllib.parse.urlencode({"aggregate": aggregate, "limit": min(int(limit), 1000),
                                "currency": "token", "token": "base" if asset_is_base else "quote"})
    url = f"{GT_BASE}/networks/{GT_NETWORK}/pools/{pool_address}/ohlcv/{timeframe}?{q}"
    eff_ttl = int(ttl if ttl is not None else _TTL.get(f"ohlcv_{timeframe}", 300))
    try:
        src = _cached_get(f"ohlcv_{pool_address}_{timeframe}_{aggregate}_{asset_is_base}", url, eff_ttl)
    except Exception as e:
        return {"status": "unavailable", "reason": f"ohlcv fetch failed: {e}"}
    rows = (src["data"].get("data") or {}).get("attributes", {}).get("ohlcv_list") or []
    bars = sorted(([int(r[0]), float(r[1]), float(r[2]), float(r[3]), float(r[4]), float(r[5])] for r in rows),
                  key=lambda r: r[0])
    if not bars:
        return {"status": "unavailable", "reason": "no bars returned", "provenance": _provenance(src, url)}
    return {"status": "ok", "timeframe": timeframe, "aggregate": aggregate, "bars": bars,
            "provenance": _provenance(src, url)}


def regularize_bars(bars: List[List[float]], step_s: int) -> Dict[str, np.ndarray]:
    """Builds a regular grid. Empty intervals take the previous close (exact for an AMM).
    Each bar's high/low is widened to include the previous close."""
    if not bars:
        return {k: np.array([]) for k in ("t", "o", "h", "l", "c", "v", "traded")}
    t0, t1 = bars[0][0], bars[-1][0]
    n = int((t1 - t0) // step_s) + 1
    t = t0 + step_s * np.arange(n, dtype=np.int64)
    o = np.full(n, np.nan); h = np.full(n, np.nan); l = np.full(n, np.nan)
    c = np.full(n, np.nan); v = np.zeros(n); traded = np.zeros(n, dtype=bool)
    for ts, bo, bh, bl, bc, bv in bars:
        i = int((ts - t0) // step_s)
        if 0 <= i < n:
            o[i], h[i], l[i], c[i], v[i], traded[i] = bo, bh, bl, bc, bv, True
    for i in range(n):
        if not traded[i]:
            prev = c[i - 1]
            o[i] = h[i] = l[i] = c[i] = prev
        elif i > 0:
            prev = c[i - 1]
            o[i] = prev  # AMM: the interval opens at the last traded price
            h[i] = max(h[i], prev)
            l[i] = min(l[i], prev)
    return {"t": t, "o": o, "h": h, "l": l, "c": c, "v": v, "traded": traded}


def fetch_pool_trades(pool_address: str) -> Dict[str, Any]:
    url = f"{GT_BASE}/networks/{GT_NETWORK}/pools/{pool_address}/trades"
    try:
        src = _cached_get(f"trades_{pool_address}", url, _TTL["trades"])
    except Exception as e:
        return {"status": "unavailable", "reason": f"trades fetch failed: {e}"}
    out = []
    for d in src["data"].get("data", []):
        a = d.get("attributes", {})
        try:
            ts = calendar.timegm(time.strptime(a["block_timestamp"], "%Y-%m-%dT%H:%M:%SZ"))
        except Exception:
            continue
        kind = a.get("kind")
        price = float(a.get("price_to_in_currency_token") if kind == "buy" else a.get("price_from_in_currency_token") or 0)
        out.append({
            "time": ts, "tx_hash": a.get("tx_hash"), "kind": kind,
            "price_ada": price, "volume_usd": float(a.get("volume_in_usd") or 0),
            "from_amount": float(a.get("from_token_amount") or 0),
            "to_amount": float(a.get("to_token_amount") or 0),
            "trader": a.get("tx_from_address"),
        })
    out.sort(key=lambda r: r["time"])
    return {"status": "ok", "trades": out, "provenance": _provenance(src, url)}


def load_series(symbol_or_unit: str, timeframe: str = "hour", aggregate: int = 1,
                pool_address: Optional[str] = None, ttl: Optional[int] = None) -> Dict[str, Any]:
    """Convenience: deepest ADA pool -> regularized OHLCV grid + pool meta + provenance."""
    pools = list_ada_pools(symbol_or_unit, ttl=ttl)
    if pools.get("status") != "ok" or not pools["pools"]:
        return {"status": "unavailable", "reason": pools.get("reason", "no ADA pool indexed for asset")}
    pool = next((p for p in pools["pools"] if p["pool_address"] == pool_address), pools["pools"][0]) \
        if pool_address else pools["pools"][0]
    raw = fetch_ohlcv(pool["pool_address"], timeframe, aggregate, asset_is_base=pool["asset_is_base"], ttl=ttl)
    if raw.get("status") != "ok":
        return {"status": "unavailable", "reason": raw.get("reason"), "pool": pool}
    step = TIMEFRAME_SECONDS[timeframe] * aggregate
    grid = regularize_bars(raw["bars"], step)
    return {
        "status": "ok",
        "unit": pools["unit"],
        "pool": pool,
        "all_pools": pools["pools"],
        "timeframe": timeframe,
        "aggregate": aggregate,
        "step_s": step,
        "raw_bars": raw["bars"],
        "grid": grid,
        "coverage": float(grid["traded"].mean()) if len(grid["traded"]) else 0.0,
        "provenance": {"pools": pools["provenance"], "ohlcv": raw["provenance"]},
    }
