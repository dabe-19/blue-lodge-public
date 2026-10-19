#!/usr/bin/env python3
"""
Position watcher: the fixed-rule detector behind the escalation framework (grill-me Q6/Q7).
Run by .george/cron_jobs/position_watcher.sh every 5 minutes. No LLM is involved here.

Each tick:
  1. capture due markouts from the pool recorder
  2. snapshot equity (sets the drawdown freeze at >= freeze_drawdown_pct; escalated as urgent)
  3. stuck positions (age >= stuck_days or spot <= -stuck_sigma_24h vs cost) -> escalation with an
     exit plan; NEVER an automatic stop-loss or averaging down
  4. expired / unlikely / legacy orders that need a decision -> escalation with a review plan
  5. gate evaluation (lib/tools/trading/gates.py: unlock readiness, re-lock, Gate 2)
  6. flush escalations deferred by quiet hours / rate limit
  7. hourly: build a sells-scope review plan and execute it ONLY if every action is Tier A, S1 is
     live, policy execution.live is on and GEORGE_EXECUTE_LIVE_SELL=1 (the same double opt-in as
     the S1 sell reactor). Tier B content is escalated, never executed.

Output: one JSON line (the cron log keeps it). Dry-run safe: --dry-run builds and reports only.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from lib.tools.trading import journal, plans, policy, store  # noqa: E402

AUTO_INTERVAL_S = 3600


def _flag_live_sell() -> bool:
    try:
        from lib.tools.feature_flags import flag
        return bool(flag("GEORGE_EXECUTE_LIVE_SELL", False))
    except Exception:
        return os.environ.get("GEORGE_EXECUTE_LIVE_SELL") == "1"


def _escalation():
    from lib.comms import escalation
    return escalation


FLAG_LIVE_SELL: Callable[[], bool] = _flag_live_sell
ESCALATION: Callable[[], Any] = _escalation


def _raise(kind: str, subject: str, text: str, severity: str = "normal", intent: Optional[Dict[str, Any]] = None,
           context: Optional[Dict[str, Any]] = None, dry_run: bool = False, con=None, pol=None,
           plan_id: Optional[str] = None) -> Dict[str, Any]:
    """Guards first (so no plan is built for a duplicate), then an optional plan, then the escalation."""
    esc = ESCALATION()
    econ = esc.connect()
    try:
        decision, reason = esc.guard(econ, kind, subject[:200], severity)
        if decision == "suppress":
            return {"kind": kind, "subject": subject, "status": "suppressed", "reason": reason}
        if intent and decision == "send" and not plan_id:
            try:
                p = plans.build_plan(intent, origin="watcher", con=con, pol=pol)
                if p["status"] == "proposed":
                    plan_id = p["plan_id"]
                    text = f"{text}\n\n{p['summary']}"
            except Exception as e:
                text += f"\n\n(could not build a plan: {type(e).__name__}: {str(e)[:120]})"
        if dry_run:
            return {"kind": kind, "subject": subject, "status": "dry_run", "would": decision, "plan_id": plan_id,
                    "text": text[:400]}
        r = esc.raise_escalation(kind, subject, text, severity, plan_id=plan_id, context=context,
                                 source="position_watcher", con=econ)
        return {"kind": kind, "subject": subject, **r, "plan_id": plan_id}
    finally:
        econ.close()


def _stuck(port: Dict[str, Any], market: Dict[str, Dict[str, Any]], pol) -> List[Dict[str, Any]]:
    inv = pol["inventory"]
    out = []
    for asset, pos in (port.get("positions") or {}).items():
        m = market.get(asset) or {}
        if not (pos.get("cost_ada") and pos.get("tokens_db") and m.get("spot") and m.get("sigma_24h")):
            continue
        per = pos["cost_ada"] / pos["tokens_db"]
        z = math.log(m["spot"] / per) / m["sigma_24h"]
        age_d = (pos.get("age_s") or 0) / 86400
        if age_d >= inv["stuck_days"] or z <= -inv["stuck_sigma_24h"]:
            out.append({"asset": asset, "age_days": round(age_d, 2), "z_vs_cost": round(z, 2),
                        "cost_ada": pos["cost_ada"], "tokens": pos["tokens_db"], "spot": m["spot"],
                        "unrealized_ada": pos.get("unrealized_ada")})
    return out


def _last_auto(con) -> int:
    r = con.execute("SELECT MAX(ts) FROM events WHERE kind='watcher_auto'").fetchone()
    return int(r[0] or 0)


def tick(dry_run: bool = False, force_auto: bool = False) -> Dict[str, Any]:
    pol = policy.load_policy()
    con = store.connect()
    out: Dict[str, Any] = {"ts": int(time.time()), "dry_run": dry_run, "escalations": []}
    try:
        try:
            out["markouts"] = journal.capture_markouts(con)
        except Exception as e:
            out["markouts"] = {"error": f"{type(e).__name__}: {e}"}

        port, market = plans._context(pol, [])
        if port.get("wallet_ada") is None:
            out["portfolio"] = "unavailable"
        was_frozen = bool(policy.is_frozen(con))
        eq = journal.snapshot_equity(con, port.get("equity_ada"), pol, {"wallet_ada": port.get("wallet_ada"),
                                                                        "source": "position_watcher"})
        out["equity"] = {k: eq.get(k) for k in ("equity_ada", "peak_ada", "drawdown_pct", "froze", "status")}
        if eq.get("froze") and not was_frozen:
            out["escalations"].append(_raise(
                "trading/freeze", "drawdown",
                f"Drawdown {eq['drawdown_pct']:.1f}% from peak {eq['peak_ada']:.1f} ADA (equity {eq['equity_ada']:.1f}). "
                "All strategies are now simulated; exits still need your confirmation. To lift the freeze after "
                "review run: lib/tools/trading/gates.py unfreeze --reason '<why>' (operator shell only).",
                "urgent", dry_run=dry_run, con=con, pol=pol))

        for s in _stuck(port, market, pol):
            out["escalations"].append(_raise(
                "trading/stuck", s["asset"],
                f"{s['asset']} position looks stuck: {s['age_days']:.1f} days old, spot {s['z_vs_cost']:+.1f} sigma_24h vs "
                f"cost ({s['tokens']:,.2f} tokens, cost {s['cost_ada']:.2f} ADA, unrealized "
                f"{(s.get('unrealized_ada') or 0):+.2f} ADA). No automatic stop-loss or averaging down: hold, re-list "
                "lower, or exit at a loss?", intent={"kind": "exit", "asset": s["asset"]}, context=s,
                dry_run=dry_run, con=con, pol=pol))

        acts, _notes = plans._review_actions(pol, port, market, "buys")
        decide = [a for a in acts if a["type"] == "reclaim" and (a.get("tier_floor") == "B")]
        expired = [a for a in acts if a["type"] == "reclaim" and "expired" in (a.get("reason") or "")]
        if decide:
            out["escalations"].append(_raise(
                "trading/orders", ",".join(sorted(a["order_id"] for a in decide)),
                "Open orders need a decision:\n" + "\n".join(f"- {a['asset']} {a['side']} {a['order_id']}: {a['reason']}"
                                                            for a in decide),
                intent={"kind": "review_pending", "scope": "buys"}, dry_run=dry_run, con=con, pol=pol))
        out["orders"] = {"needs_decision": len(decide), "expired": len(expired)}

        try:
            from lib.tools.trading import gates
            out["gates"] = gates.evaluate(con, pol, raise_fn=None if dry_run else
                                          (lambda **kw: out["escalations"].append(_raise(con=con, pol=pol, **kw))))
        except ImportError:
            out["gates"] = "unavailable"
        except Exception as e:
            out["gates"] = {"error": f"{type(e).__name__}: {e}"}

        if not dry_run:
            try:
                out["flushed"] = len(ESCALATION().flush_deferred())
            except Exception as e:
                out["flushed"] = f"error: {type(e).__name__}"

        if force_auto or time.time() - _last_auto(con) >= AUTO_INTERVAL_S:
            out["auto"] = auto_pass(con, pol, dry_run, port, expired)
        return out
    finally:
        con.close()


def auto_pass(con, pol, dry_run: bool, port: Dict[str, Any], expired: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Hourly Tier A pass. One plan per held asset (exit/reprice) and per expired order (reclaim), so a
    Tier B item never blocks an unrelated Tier A one. Only all-Tier-A plans execute."""
    if not dry_run:
        store.log_event(con, "watcher_auto", {})
        con.commit()
    intents: List[Dict[str, Any]] = [{"kind": "exit", "asset": a} for a in sorted(port.get("positions") or {})]
    intents += [{"kind": "reclaim", "order_id": a["order_id"], "reason": "order expired on chain"} for a in expired]
    out: Dict[str, Any] = {"plans": [], "status": "nothing_to_do"}
    tier_b: List[str] = []
    tier_b_pids: List[str] = []
    executed: List[str] = []
    for it in intents:
        try:
            p = plans.build_plan(it, origin="cron", con=con, pol=pol)
        except Exception as e:
            out["plans"].append({"intent": it, "status": "error", "reason": f"{type(e).__name__}: {str(e)[:160]}"})
            continue
        rec: Dict[str, Any] = {"intent": it.get("asset") or it.get("order_id"), "plan_id": p["plan_id"],
                               "tier": p["tier"], "plan_status": p["status"]}
        out["plans"].append(rec)
        if p["status"] != "proposed":
            rec["status"] = "nothing_to_do"
            continue
        if p["tier"] != "A":
            rec["status"] = "needs_operator"
            tier_b.append(p["summary"])
            if p.get("plan_id"):
                tier_b_pids.append(p["plan_id"])
            continue
        if dry_run:
            rec["status"] = "dry_run"
            continue
        if not FLAG_LIVE_SELL():
            rec["status"] = "not_executed"
            rec["reason"] = "GEORGE_EXECUTE_LIVE_SELL is off (env or .george/features.conf)"
            continue
        r = plans.execute_plan(p["plan_id"], actor="george", con=con, pol=pol)
        rec.update({"status": r.get("status"), "live": r.get("live"),
                    "results": [{k: x.get(k) for k in ("action", "status", "tx_id", "message")}
                                for x in r.get("results", [])]})
        if r.get("status") in ("executed", "partially_executed") and r.get("live"):
            executed += [f"- {x['action']}: {x['status']}" for x in rec["results"]]
    sts = {p.get("status") for p in out["plans"]}
    out["status"] = ("executed" if executed else "needs_operator" if tier_b else
                     "not_executed" if "not_executed" in sts else "dry_run" if "dry_run" in sts else "nothing_to_do")
    if tier_b and not dry_run:
        out["escalation"] = _raise("trading/auto_tier_b", "hourly",
                                   "The hourly review found exits/reclaims that need your confirmation:\n" +
                                   "\n".join(tier_b), plan_id=tier_b_pids[0] if tier_b_pids else None,
                                   con=con, pol=pol)
        if out["escalation"].get("status") == "suppressed" and tier_b_pids:
            con.executemany("UPDATE plans SET status='superseded' WHERE plan_id=? AND status='proposed'",
                            [(pid,) for pid in tier_b_pids])
            con.commit()
    elif tier_b and dry_run and tier_b_pids:
        con.executemany("UPDATE plans SET status='superseded' WHERE plan_id=? AND status='proposed'",
                        [(pid,) for pid in tier_b_pids])
        con.commit()
    if executed:
        try:
            ESCALATION().operator_notify("Autonomous Tier A actions (hourly review):\n" + "\n".join(executed),
                                         severity="normal")
        except Exception:
            pass
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="Position watcher (cron)")
    ap.add_argument("--dry-run", action="store_true", help="build and report only: no escalations, no execution")
    ap.add_argument("--force-auto", action="store_true", help="run the hourly Tier A pass now")
    a = ap.parse_args()
    try:
        out = tick(dry_run=a.dry_run, force_auto=a.force_auto)
    except Exception as e:
        out = {"status": "error", "reason": f"{type(e).__name__}: {str(e)[:300]}"}
    print(json.dumps(out, default=str))


if __name__ == "__main__":
    main()
