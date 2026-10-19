#!/usr/bin/env python3
"""
Strategy gates, drawdown freeze and automatic re-lock (grill-me Q8).

Gate 1 (per simulated strategy -> live, Tier B unlock proposed to the operator):
  latest walk-forward backtest has >= min_backtest_trips round trips, mean net > 0 and
  lower80 > min_lower80_ada; the shadow simulator has run >= min_live_sim_days; and the live
  shadow mean is not worse than the backtest mean by more than max_sim_vs_backtest_se combined
  standard errors (the backtest must survive contact with live data).
Gate 2 (scale-up, recommendation only): >= min_trips live round trips placed under the new rules,
  positive mean net P&L and positive mean 6 h markout. George then RECOMMENDS a manual transfer
  from the cold reserve; he never moves it (Q1).
Freeze: drawdown >= freeze_drawdown_pct (set by journal.snapshot_equity) demotes every live
  strategy to simulated; exits need confirmation. Only the operator lifts it (CLI below).
Re-lock: a strategy unlocked by override whose last relock_window_trips shadow (or live) trips
  have a negative mean goes back to simulated automatically, with an urgent escalation.

Operator CLI (bash_exec blocks these for George):
  gates.py status
  gates.py unfreeze --reason '...'
  gates.py set-state --strategy S2_shock_fade --state simulated|live --reason '...'
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import time
from pathlib import Path
from typing import Any, Callable, Dict, Optional

_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from lib.tools.trading import journal, policy, store  # noqa: E402

GATED = ("S2_shock_fade", "S3_stable_deviation")
NOTIFY_EVERY_S = 3 * 86400


def latest_backtest(con, strategy: str) -> Optional[Dict[str, Any]]:
    r = con.execute("SELECT * FROM backtests WHERE strategy=? ORDER BY ts DESC LIMIT 1", (strategy,)).fetchone()
    return dict(r) if r else None


def record_backtest(con, run_id: str, strategy: str, stats: Dict[str, Any], params: Dict[str, Any],
                    data_from: Optional[int], data_to: Optional[int], detail: Optional[Dict[str, Any]] = None) -> None:
    con.execute("INSERT OR REPLACE INTO backtests VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (run_id, int(time.time()), strategy, json.dumps(params, default=str), int(stats.get("n") or 0),
                 stats.get("mean"), stats.get("sd"), stats.get("se"), stats.get("lower80"), stats.get("win_rate"),
                 data_from, data_to, json.dumps(detail or {}, default=str)[:20000]))
    con.commit()


def gate1(con, pol, strategy: str) -> Dict[str, Any]:
    g = pol["gates"]["gate1"]
    bt = latest_backtest(con, strategy)
    sim = journal.sim_stats(con, strategy)
    checks: Dict[str, Any] = {}
    checks["backtest_trips"] = {"have": bt["n_trips"] if bt else 0, "need": g["min_backtest_trips"],
                                "ok": bool(bt and bt["n_trips"] >= g["min_backtest_trips"])}
    checks["backtest_mean_positive"] = {"have": bt["mean_ada"] if bt else None,
                                        "ok": bool(bt and (bt["mean_ada"] or 0) > 0)}
    checks["backtest_lower80"] = {"have": bt["lower80_ada"] if bt else None, "need": f"> {g['min_lower80_ada']}",
                                  "ok": bool(bt and bt["lower80_ada"] is not None and bt["lower80_ada"] > g["min_lower80_ada"])}
    checks["live_sim_days"] = {"have": round(sim.get("days_running") or 0, 1), "need": g["min_live_sim_days"],
                               "ok": (sim.get("days_running") or 0) >= g["min_live_sim_days"]}
    ok_sim = False
    gap = None
    if bt and sim.get("n", 0) >= 2 and sim.get("se") is not None and bt.get("se_ada") is not None:
        se = math.sqrt(sim["se"] ** 2 + bt["se_ada"] ** 2)
        gap = (sim["mean"] - (bt["mean_ada"] or 0)) / se if se > 0 else 0.0
        ok_sim = gap >= -float(g["max_sim_vs_backtest_se"])
    checks["sim_matches_backtest"] = {"have_se_gap": round(gap, 2) if gap is not None else None,
                                      "sim_n": sim.get("n", 0), "need": f">= -{g['max_sim_vs_backtest_se']} SE",
                                      "ok": ok_sim}
    return {"strategy": strategy, "state": policy.strategy_state(con, pol, strategy),
            "ready": all(c["ok"] for c in checks.values()), "checks": checks,
            "backtest_run": bt["run_id"] if bt else None,
            "sim": {k: sim.get(k) for k in ("n", "mean", "lower80", "win_rate", "days_running")}}


def gate2(con, pol) -> Dict[str, Any]:
    g = pol["gates"]["gate2"]
    trips = journal.trips(con, mode="live", closed=True, new_rules_only=True)
    s = journal.describe(t["net_pnl_ada"] for t in trips)
    mk = journal.markout_stats(con, g.get("markout_horizon", "6h"), mode="live", new_rules_only=True)
    checks = {"trips": {"have": s.get("n", 0), "need": g["min_trips"], "ok": s.get("n", 0) >= g["min_trips"]},
              "mean_net_positive": {"have": s.get("mean"), "ok": (s.get("mean") or 0) > 0},
              "markout_positive": {"have_bps": mk.get("mean"), "horizon": mk.get("horizon"),
                                   "ok": mk.get("n", 0) > 0 and (mk.get("mean") or 0) > 0}}
    return {"passed": all(c["ok"] for c in checks.values()), "checks": checks, "progress": f"{s.get('n', 0)}/{g['min_trips']}"}


def relock_check(con, pol, strategy: str) -> Optional[str]:
    """Reason to re-lock, if a live-by-override strategy's recent results are negative."""
    base = pol["strategies"].get(strategy, {}).get("state")
    ov = store.get_override(con, f"strategy:{strategy}")
    if base == "live" or ov != "live":
        return None
    w = int(pol["gates"]["relock_window_trips"])
    sim = journal.sim_stats(con, strategy, last_n=w)
    if sim.get("n", 0) >= w and (sim.get("mean") or 0) < 0:
        return f"last {w} shadow trips mean {sim['mean']:+.2f} ADA < 0"
    live = journal.trips(con, mode="live", strategy=strategy, closed=True, limit=w)
    ls = journal.describe(t["net_pnl_ada"] for t in live)
    if ls.get("n", 0) >= w and (ls.get("mean") or 0) < 0:
        return f"last {w} live trips mean {ls['mean']:+.2f} ADA < 0"
    return None


def status(con, pol) -> Dict[str, Any]:
    dd = journal.drawdown(con)
    g2 = gate2(con, pol)
    return {"stage": "scale_up_recommended" if g2["passed"] else "accumulating",
            "gate1": {s: gate1(con, pol, s) for s in GATED if s in pol["strategies"]},
            "gate2": g2,
            "freeze": {"frozen": bool(policy.is_frozen(con)), "detail": policy.is_frozen(con),
                       "drawdown_pct": dd.get("drawdown_pct"), "limit_pct": pol["gates"]["freeze_drawdown_pct"],
                       "peak_ada": dd.get("peak_ada"), "equity_ada": dd.get("equity_ada")}}


def _recently(con, kind: str, subject: str, within_s: int) -> bool:
    r = con.execute("SELECT MAX(ts) FROM events WHERE kind=? AND json_extract(detail,'$.subject')=?",
                    (kind, subject)).fetchone()
    return bool(r and r[0] and time.time() - r[0] < within_s)


def evaluate(con, pol, raise_fn: Optional[Callable[..., Any]] = None) -> Dict[str, Any]:
    """status() plus, when raise_fn is given, the side effects: re-locks and escalations."""
    out: Dict[str, Any] = {"relocked": []}
    for s in GATED:
        if s not in pol["strategies"]:
            continue
        why = relock_check(con, pol, s)
        if why and raise_fn:
            store.set_override(con, f"strategy:{s}", "simulated", by="gates", reason=f"auto re-lock: {why}")
            out["relocked"].append({"strategy": s, "reason": why})
            raise_fn(kind="trading/relock", subject=s, severity="urgent",
                     text=f"{s} was re-locked to simulation automatically: {why}. No action needed; it can be "
                          "re-unlocked only through Gate 1 again.")
    st = status(con, pol)
    out.update(st)
    if not raise_fn:
        return out
    for s, g in st["gate1"].items():
        if g["ready"] and g["state"] == "simulated" and not _recently(con, "gate_notified", s, NOTIFY_EVERY_S):
            store.log_event(con, "gate_notified", {"subject": s})
            con.commit()
            raise_fn(kind="trading/gate1", subject=s,
                     text=f"Gate 1 passed for {s}: backtest {g['checks']['backtest_trips']['have']} trips, mean "
                          f"{g['checks']['backtest_mean_positive']['have']:+.2f} ADA, lower80 "
                          f"{g['checks']['backtest_lower80']['have']:+.2f}; shadow {g['sim']['n']} trips over "
                          f"{g['sim']['days_running']:.0f} days matches it. Unlock it for live trading?",
                     intent={"kind": "unlock", "strategy": s, "reason": "Gate 1 passed"})
    if st["gate2"]["passed"] and not _recently(con, "gate_notified", "gate2", 7 * 86400):
        store.log_event(con, "gate_notified", {"subject": "gate2"})
        con.commit()
        eq = st["freeze"].get("equity_ada") or 0
        rec = min(2000.0, max(100.0, round(eq / 50.0) * 50.0))
        c = st["gate2"]["checks"]
        raise_fn(kind="trading/gate2", subject="gate2",
                 text=f"Gate 2 passed: {c['trips']['have']} round trips under the new rules, mean net "
                      f"{c['mean_net_positive']['have']:+.2f} ADA/trip, mean {c['markout_positive']['horizon']} markout "
                      f"{c['markout_positive']['have_bps']:+.0f} bps. Recommendation: move about {rec:.0f} ADA from the "
                      "cold reserve to the hot wallet yourself (George never touches the Trezor). Order sizes scale "
                      "automatically with working capital, still capped at 0.1% pool impact.")
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="Trading gates (operator CLI)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    s = sub.add_parser("unfreeze")
    s.add_argument("--reason", required=True)
    s = sub.add_parser("set-state")
    s.add_argument("--strategy", required=True)
    s.add_argument("--state", choices=["simulated", "live"], required=True)
    s.add_argument("--reason", required=True)
    a = ap.parse_args()
    pol = policy.load_policy()
    con = store.connect()
    try:
        if a.cmd == "status":
            out: Any = status(con, pol)
        elif a.cmd == "unfreeze":
            if not policy.is_frozen(con):
                out = {"status": "not_frozen"}
            else:
                store.clear_override(con, "freeze", by="operator", reason=a.reason)
                # Rebase the peak so the same drawdown does not re-freeze immediately.
                dd = journal.drawdown(con)
                if dd.get("equity_ada") is not None:
                    con.execute("INSERT OR REPLACE INTO equity VALUES (?,?,?,?,?)",
                                (int(time.time()), dd["equity_ada"], dd["equity_ada"], 0.0,
                                 json.dumps({"source": "unfreeze_rebase", "reason": a.reason})))
                    con.commit()
                out = {"status": "unfrozen", "peak_rebased_to": dd.get("equity_ada")}
        else:
            if a.strategy not in pol["strategies"]:
                raise SystemExit(f"unknown strategy {a.strategy}")
            store.set_override(con, f"strategy:{a.strategy}", a.state, by="operator", reason=a.reason)
            out = {"status": "ok", "strategy": a.strategy, "effective": policy.strategy_state(con, pol, a.strategy)}
    finally:
        con.close()
    print(json.dumps(out, default=str))


if __name__ == "__main__":
    main()
