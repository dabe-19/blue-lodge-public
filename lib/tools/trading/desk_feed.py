#!/usr/bin/env python3
"""
Read-only aggregate for the web Trading Desk (plan P5). One JSON document, local data only
(trading.db, market.db, escalations.db, cached impact studies) — no chain or HTTP calls, so the
panel is cheap to poll.

  desk_feed.py            everything below
  sections: policy, gates, plans, standing_orders, markouts, trips, sims, backtests,
            fair_value (per recorded pool), recorder, escalations
"""
from __future__ import annotations

import json
import math
import sys
import time
from pathlib import Path
from typing import Any, Dict, List

_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))


def _safe(fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except Exception as e:  # each panel degrades independently
        return {"status": "error", "reason": f"{type(e).__name__}: {str(e)[:200]}"}


def _policy(pol: Dict[str, Any], con=None) -> Dict[str, Any]:
    from lib.tools.trading import policy
    frozen = bool(policy.is_frozen(con)) if con is not None else False
    eff_strats = policy.strategy_states(con, pol) if con is not None else {k: v.get("state") for k, v in pol["strategies"].items()}
    cap = dict(pol["capital"])
    cap["freeze"] = frozen
    cap["reserve_floor_ada"] = pol["wallet"].get("floor_ada", 40.0)
    cap["fee_reserve_ada"] = pol["wallet"].get("fee_buffer_ada", 10.0)
    return {"live_execution": policy.live_execution_enabled(pol), "policy_live_flag": bool(pol["execution"].get("live")),
            "source": pol.get("_source"), "wallet": pol["wallet"], "capital": cap,
            "frozen": frozen, "strategies": eff_strats}


def _plans(con) -> List[Dict[str, Any]]:
    from lib.tools.trading import plans
    out = []
    for p in plans.list_plans(con, None, 25):
        full = plans.get_plan(con, p["plan_id"]) or {}
        acts = full.get("actions") or []
        norm_acts = []
        for a in acts[:6]:
            ev = a.get("ev") if isinstance(a.get("ev"), dict) else {}
            norm_acts.append({
                "type": a.get("type"),
                "kind": a.get("type") or a.get("kind"),
                "asset": a.get("asset"),
                "side": a.get("side") or ("buy" if a.get("type") == "place_buy" else ("sell" if a.get("type") == "place_sell" else None)),
                "price": a.get("price") if a.get("price") is not None else a.get("new_price"),
                "ada": a.get("ada"),
                "budget_ada": a.get("ada") if a.get("ada") is not None else a.get("budget_ada"),
                "tokens": a.get("tokens"),
                "tier": a.get("tier"),
                "blocked": a.get("blocked"),
                "reasons": a.get("block_reasons") or a.get("reasons"),
                "ev_ada": ev.get("ev_net_ada") if ev.get("ev_net_ada") is not None else a.get("ev_ada"),
                "p_fill": ev.get("p_fill") if ev.get("p_fill") is not None else a.get("p_fill"),
            })
        p["actions"] = norm_acts
        p["confirmable"] = p["status"] == "proposed" and p["tier"] == "B" and p["expires_at"] > time.time()
        out.append(p)
    return out


def _markouts(con) -> Dict[str, Any]:
    rows = [dict(r) for r in con.execute(
        "SELECT fill_id, horizon_s, mode, strategy, asset, side, fill_ts, fill_price, mark_price, markout_ada, "
        "markout_bps, status FROM markouts ORDER BY fill_ts DESC, horizon_s LIMIT 160")]
    fills: Dict[str, Dict[str, Any]] = {}
    for r in rows:
        f = fills.setdefault(r["fill_id"], {k: r[k] for k in ("fill_id", "mode", "strategy", "asset", "side",
                                                               "fill_ts", "fill_price")} | {"h": {}})
        f["h"][str(r["horizon_s"])] = {"bps": r["markout_bps"], "ada": r["markout_ada"], "status": r["status"]}
    return {"fills": list(fills.values())[:40]}


def _sims(con) -> List[Dict[str, Any]]:
    return [dict(r) for r in con.execute(
        "SELECT sim_id, strategy, asset, created_at, entry_price, size_ada, exit_target, status, filled_at, exit_at, "
        "exit_price, net_pnl_ada FROM sim_trades ORDER BY created_at DESC LIMIT 40")]


def _backtests(con) -> Dict[str, Any]:
    from lib.tools.trading import gates
    out = {}
    for s in gates.GATED:
        bt = gates.latest_backtest(con, s)
        if not bt:
            continue
        try:
            detail = json.loads(bt.get("detail") or "{}")
        except ValueError:
            detail = {}
        out[s] = {"run_id": bt["run_id"], "ts": bt["ts"], "n": bt["n_trips"], "mean": bt["mean_ada"],
                  "lower80": bt["lower80_ada"], "win_rate": bt["win_rate"],
                  "params": json.loads(bt.get("params_json") or "{}"), "variants": detail.get("variants")}
    return out


def _fair_value(mcon, pol) -> List[Dict[str, Any]]:
    import numpy as np
    from lib.tools.quant import fair_value as fvm
    from lib.tools.quant import impact
    from lib.tools.quant import market_db as mdb
    from lib.tools.quant.signals import recorder_pools
    now = int(time.time())
    out = []
    for a in recorder_pools(pol):
        row: Dict[str, Any] = {"asset": a}
        fresh = mdb.fresh_pool_state(mcon, a)
        snap = fresh or mdb.latest_snapshot(mcon, a)
        row["spot"] = snap["spot"] if snap else None
        row["fresh"] = bool(fresh)
        row["reserve_ada"] = snap["reserve_ada"] if snap else None
        pts = mdb.spot_series(mcon, a, now - 7 * 86400, now, 300)
        row["history_days"] = round((pts[-1][0] - pts[0][0]) / 86400.0, 2) if pts else 0.0
        if len(pts) >= 50:
            y = np.log(np.array([p[1] for p in pts], float))
            ll = fvm.local_level(y, min(288, max(2, len(y) // 3)))
            if ll.get("status") == "ok":
                row.update({"fair_value": math.exp(ll["mu"]), "deviation_sigma": ll["deviation_sigma"],
                            "vr": ll["vr_k"]})
        if a in fvm.STABLES:
            s3 = fvm.stable_fair_value(a, row["spot"], 7, con=mcon)
            if s3.get("status") == "ok":
                row["peg_fair_value"] = s3["fair_value"]
                row["peg_deviation_pct"] = (s3.get("deviation") or 0.0) * 100
        im = impact.cached(a)
        if im:
            row["impact"] = {k: im.get(k) for k in ("status", "reversion_fraction", "half_life_h")}
        out.append(row)
    return out


def _recorder(mcon) -> Dict[str, Any]:
    from lib.tools.quant import market_db as mdb
    h = mdb.health(mcon)
    budgets = {}
    for prov, lim in (("blockfrost", 25000), ("koios", 10000)):
        budgets[prov] = {"today": mdb.calls_today(mcon, prov), "limit": lim}
    now = time.time()
    pools = [{"asset": p["asset"], "dex": p["dex"], "checked_age_s": int(now - p["last_checked"]) if p["last_checked"] else None,
              "last_trade_age_s": int(now - p["last_ts"]) if p["last_ts"] else None, "backfill_done": p["backfill_done"]}
             for p in h.get("pools", [])]
    return {"size_bytes": h["size_bytes"], "max_bytes": h["max_bytes"],
            "rows": {k[5:]: v for k, v in h.items() if k.startswith("rows_")}, "pools": pools,
            "cex_age_s": int(now - h["cex_latest"]["ts"]) if h.get("cex_latest") else None,
            "budgets": budgets, "last_janitor": h.get("last_janitor")}


def build() -> Dict[str, Any]:
    from lib.comms import escalation
    from lib.tools.quant import market_db as mdb
    from lib.tools.trading import agent_tools, gates, plans, policy, store
    _safe(agent_tools.ensure_web_secret)
    pol = policy.load_policy()
    con, mcon = store.connect(), mdb.connect()
    try:
        return {"status": "ok", "ts": int(time.time()),
                "policy": _safe(_policy, pol, con),
                "gates": _safe(gates.status, con, pol),
                "plans": _safe(_plans, con),
                "standing_orders": _safe(plans.standing_orders, con, True),
                "markouts": _safe(_markouts, con),
                "trips": _safe(lambda: [dict(r) for r in con.execute(
                    "SELECT trip_id, mode, strategy, asset, opened_at, closed_at, entry_price, exit_price, entry_ada, "
                    "exit_ada, fees_ada, net_pnl_ada, new_rules FROM trips ORDER BY opened_at DESC LIMIT 30")]),
                "sims": _safe(_sims, con),
                "backtests": _safe(_backtests, con),
                "fair_value": _safe(_fair_value, mcon, pol),
                "recorder": _safe(_recorder, mcon),
                "escalations": _safe(lambda: {
                    "inbox": escalation.inbox(30),
                    "open_asks": [{**a, "confirmable": bool(a.get("plan_id") and escalation._plan_confirmable(a["plan_id"]))}
                                  for a in escalation.open_asks()],
                    "discord_configured": escalation.discord_configured()
                })}
    finally:
        con.close()
        mcon.close()


def main() -> None:
    try:
        out = build()
    except Exception as e:
        out = {"status": "error", "reason": f"{type(e).__name__}: {str(e)[:300]}"}
    print(json.dumps(out, default=str))


if __name__ == "__main__":
    main()
