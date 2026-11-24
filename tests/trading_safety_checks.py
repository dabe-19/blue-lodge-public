#!/usr/bin/env python3
"""
P0 trading safety checks (offline). Each check prints one line: "<name> PASS|FAIL <detail>".

Every guard on the money path must FAIL CLOSED: a missing config, an unreadable ledger,
or unavailable market data must block new risk, never permit it. No network is used;
all data sources are monkeypatched.
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))
os.environ.setdefault("CARDANO_TEST_MODE", "1")

RESULTS = []


def check(name):
    def deco(fn):
        try:
            ok, detail = fn()
        except Exception as e:  # a crash is a failure, never a pass
            ok, detail = False, f"{type(e).__name__}: {e}"
        RESULTS.append(ok)
        print(f"{name} {'PASS' if ok else 'FAIL'} {detail}")
        return fn
    return deco


# ── 1. Cointegration reactor mode guard ───────────────────────────────────────
@check("reactor_mode_fails_closed")
def _():
    from lib.tools import cardano_cointegration_reactor as r
    saved_env = {k: os.environ.pop(k, None) for k in ("CARDANO_COINT_MODE", "CARDANO_MODE")}
    saved_conf = r.CONF_FILE
    out = {}
    try:
        with tempfile.TemporaryDirectory() as d:
            r.CONF_FILE = Path(d) / "missing.conf"
            out["no_conf"] = r.get_operating_mode()
            r.CONF_FILE.write_text("garbage\n")
            out["bad_conf"] = r.get_operating_mode()
            r.CONF_FILE.write_text("auto\n")
            out["conf_auto"] = r.get_operating_mode()
            os.environ["CARDANO_COINT_MODE"] = "live-please"
            out["bad_env"] = r.get_operating_mode()
            os.environ["CARDANO_COINT_MODE"] = "DRY_RUN"
            out["env_dry"] = r.get_operating_mode()
            os.environ["CARDANO_COINT_MODE"] = "AUTO"
            out["env_auto"] = r.get_operating_mode()
    finally:
        r.CONF_FILE = saved_conf
        os.environ.pop("CARDANO_COINT_MODE", None)
        for k, v in saved_env.items():
            if v is not None:
                os.environ[k] = v
    expected = {"no_conf": "MANUAL", "bad_conf": "MANUAL", "conf_auto": "AUTO",
                "bad_env": "MANUAL", "env_dry": "MANUAL", "env_auto": "AUTO"}
    return out == expected, str(out)


# ── 2. Market maker guards ────────────────────────────────────────────────────
@check("single_leg_check_fails_closed_on_db_error")
def _():
    import lib.tools.cardano_maker_db as db
    from lib.tools import cardano_market_maker as mm
    orig = db.get_db_connection

    def boom(*a, **k):
        raise RuntimeError("ledger unreadable")
    db.get_db_connection = boom
    try:
        res = mm.check_single_leg_inventory("SNEK")
    finally:
        db.get_db_connection = orig
    return res is True, f"returned {res}"


@check("trend_velocity_pauses_without_data")
def _():
    from lib.tools import cardano_market_maker as mm
    res = mm.fetch_asset_trend_velocity("SNEK", 0.0035, vol_data_all={})
    return res["slide_action"] == "HARD_PAUSE", f"{res['slide_action']} / {res['regime']}"


@check("corridors_never_viable_when_vol_unavailable")
def _():
    from lib.tools import cardano_market_maker as mm
    saved = (mm.fetch_live_spot_prices, mm.get_all_asset_volatilities, mm.check_single_leg_inventory)
    mm.fetch_live_spot_prices = lambda *a, **k: {"SNEK": 0.0035, "NIGHT": 0.19, "MIN": 0.05}

    def vol_down(*a, **k):
        raise RuntimeError("volatility engine offline")
    mm.get_all_asset_volatilities = vol_down
    mm.check_single_leg_inventory = lambda asset: False
    try:
        opps = mm.evaluate_maker_corridors(300.0, capital_override=300.0)
    finally:
        mm.fetch_live_spot_prices, mm.get_all_asset_volatilities, mm.check_single_leg_inventory = saved
    viable = [o.asset for o in opps if o.is_profitable]
    statuses = sorted({o.status for o in opps})
    return (len(opps) == 3 and not viable), f"viable={viable} statuses={statuses}"


@check("corridors_block_when_ou_verdict_missing")
def _():
    from lib.tools import cardano_market_maker as mm
    saved = (mm.fetch_live_spot_prices, mm.get_all_asset_volatilities, mm.check_single_leg_inventory)
    mm.fetch_live_spot_prices = lambda *a, **k: {"SNEK": 0.0035}
    # Live vol + momentum present, but NO ornstein_uhlenbeck block -> must not be viable.
    prof = {"status": "live", "velocity_4h_pct": 0.1,
            "dispersion_pct": {"30m": 2.0, "1h": 3.0, "2h": 4.0, "4h": 6.0, "8h": 8.0, "24h": 12.0}}
    mm.get_all_asset_volatilities = lambda *a, **k: {"assets": {"SNEK": prof}}
    mm.check_single_leg_inventory = lambda asset: False
    try:
        opps = mm.evaluate_maker_corridors(300.0, capital_override=300.0)
    finally:
        mm.fetch_live_spot_prices, mm.get_all_asset_volatilities, mm.check_single_leg_inventory = saved
    o = opps[0]
    return (not o.is_profitable), f"is_profitable={o.is_profitable} status={o.status}"


# ── 3. Market dimensions ──────────────────────────────────────────────────────
def _patched_series(cmd, value):
    orig = cmd.md.load_series
    cmd.md.load_series = lambda *a, **k: value
    return orig


@check("cpmm_no_fabricated_reserve")
def _():
    from lib.tools import cardano_market_dimensions as cmd
    orig = _patched_series(cmd, {"status": "unavailable", "reason": "offline"})
    try:
        c = cmd.compute_cpmm_curve("SNEK", [100.0])
        clr = cmd.pre_trade_clearance("SNEK", 100.0, "buy")
    finally:
        cmd.md.load_series = orig
    ok = c["status"] == "unavailable" and c["curve"][0]["slippage_pct"] is None and clr["clearance"] == "NO_GO"
    return ok, f"cpmm={c['status']} clearance={clr['clearance']}"


@check("cpmm_includes_pool_fee_and_unknown_queue_not_blocking")
def _():
    from lib.tools import cardano_market_dimensions as cmd
    pool = {"price_ada": 0.0035, "reserve_ada_est": 2_000_000.0, "dex": "minswap-cardano"}
    orig = _patched_series(cmd, {"status": "ok", "pool": pool, "all_pools": [pool]})
    try:
        c = cmd.compute_cpmm_curve("SNEK", [300.0])
        clr = cmd.pre_trade_clearance("SNEK", 300.0, "buy")
        bq = cmd.inspect_batcher_queue("SNEK")
    finally:
        cmd.md.load_series = orig
    slip = c["curve"][0]["slippage_pct"]
    ok = 0.30 <= slip < 0.35 and bq["status"] == "UNKNOWN" and bq["pending_swaps"] is None and clr["clearance"] == "GO"
    return ok, f"slippage={slip}% queue={bq['status']} clearance={clr['clearance']}"


@check("congested_queue_is_no_go")
def _():
    from lib.tools import cardano_market_dimensions as cmd
    pool = {"price_ada": 0.0035, "reserve_ada_est": 2_000_000.0, "dex": "minswap-cardano"}
    orig_s = _patched_series(cmd, {"status": "ok", "pool": pool, "all_pools": [pool]})
    orig_q = cmd.inspect_batcher_queue
    cmd.inspect_batcher_queue = lambda a: {"status": "CONGESTED", "pending_swaps": 40, "estimated_latency_s": 140}
    try:
        clr = cmd.pre_trade_clearance("SNEK", 50.0, "buy")
    finally:
        cmd.md.load_series, cmd.inspect_batcher_queue = orig_s, orig_q
    return clr["clearance"] == "NO_GO", clr["clearance"]


# ── 4. Token registry is the single source of truth ───────────────────────────
@check("token_registry_consistent")
def _():
    from lib.tools.quant import tokens as t, market_data as md
    from lib.tools.cardano_dex_swapper import TOKEN_METADATA
    from lib.tools.cardano_market_maker import TARGET_ASSETS
    from lib.tools.cardano_arbitrage_searcher import TARGET_ASSETS as ARB
    real_min = "29d222ce763455e3d7a09a665ce554f00ac89d2e99a1a83d267170c64d494e"
    bad = []
    if t.unit("MIN") != real_min:
        bad.append("registry MIN")
    for s in t.symbols():
        if md.KNOWN_ASSETS[s]["unit"] != t.unit(s):
            bad.append(f"market_data {s}")
        if TOKEN_METADATA[s]["unit"] != t.unit(s):
            bad.append(f"swapper {s}")
    for s, cfg in TARGET_ASSETS.items():
        if cfg["unit"] != t.unit(s):
            bad.append(f"maker {s}")
    for s, cfg in ARB.items():
        if cfg["policy_id"] + cfg["asset_name_hex"] != t.unit(s):
            bad.append(f"arb {s}")
    graph = (REPO / "lib/tools/cardano_arbitrage_graph.sh").read_text()
    if "29d222ce763455e3d7a09a665ce554f00ac89d2c99a52f4dda8b3350" in graph:
        bad.append("arbitrage_graph.sh stale MIN")
    return not bad, ",".join(bad) or "all modules agree"


if __name__ == "__main__":
    sys.exit(0 if all(RESULTS) else 1)
