#!/usr/bin/env python3
"""
George's six trading tools (JSON in, JSON out) plus the operator-only confirm path.

  review                         crypto_review: wallet, orders, inventory, P&L, gates, freeze, limits
  scan [--assets A,B]            crypto_scan: per pool spot / fair value / deviation / regime / signals
  plan --intent '<json|phrase>'  crypto_plan: propose actions (writes the plan only)
  execute --plan-id P-XXXXXX     crypto_execute: run a plan (Tier B needs the operator's confirmation)
  standing-order create|list|revoke
  journal [--window-days N] [--strategy S]
  plans [--status S]             recent plans

Operator only (never exposed to George; bash_exec blocks it):
  confirm --plan P-XXXXXX --via discord --channel <id> --message-id <id>
      Verifies with the Discord API that the message exists, was written by DISCORD_OPERATOR_ID
      (or DISCORD_OWNER_ID) after the plan was built, and says 'confirm P-XXXXXX'; then mints a
      single-use token bound to the plan hash and executes the plan in the same process.
  confirm --plan P-XXXXXX --via web
      The web desk passes the server-side secret in TRADING_WEB_CONFIRM_SECRET; it must match
      .george/secrets/trading_confirm.key.
"""
from __future__ import annotations

import argparse
import hmac
import json
import os
import re
import sys
import time
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from lib.tools.trading import journal, plans, policy, store  # noqa: E402
from lib.tools.trading import market as mkt  # noqa: E402
from lib.tools.trading import portfolio as pf  # noqa: E402

CONFIRM_RE = re.compile(r"\bconfirm\s+(P-[0-9A-F]{6})\b", re.IGNORECASE)
SNOWFLAKE_RE = re.compile(r"^[0-9]{5,25}$")
DISCORD_EPOCH_MS = 1420070400000


def _r(x: Any) -> Any:
    """Round floats to 6 significant figures for compact, LLM-friendly output."""
    if isinstance(x, float):
        return float(f"{x:.6g}")
    if isinstance(x, dict):
        return {k: _r(v) for k, v in x.items() if not str(k).startswith("_")}
    if isinstance(x, list):
        return [_r(v) for v in x]
    return x


def _secrets_dir() -> Path:
    george = Path(os.environ.get("GEORGE_DIR", _REPO_ROOT / ".george"))
    return george / "secrets"


def _gates(con, pol) -> Dict[str, Any]:
    try:
        from lib.tools.trading import gates
        return gates.status(con, pol)
    except ImportError:
        return {"status": "unavailable", "reason": "gate evaluator not installed"}
    except Exception as e:
        return {"status": "error", "reason": f"{type(e).__name__}: {e}"}


def _recorder_brief() -> Dict[str, Any]:
    try:
        from lib.tools.quant import market_db as mdb
        h = mdb.health()
        now = time.time()
        return {"db_mb": round((h.get("size_bytes") or 0) / 1e6, 1), "swaps": h.get("rows_swaps"),
                "pool_check_age_s": {p["asset"]: (int(now - p["last_checked"]) if p.get("last_checked") else None)
                                     for p in h.get("pools", [])}}
    except Exception as e:
        return {"status": "error", "reason": f"{type(e).__name__}"}


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_review(a) -> Dict[str, Any]:
    pol = policy.load_policy()
    con = store.connect()
    try:
        port = pf.snapshot(pol)
        market = port.get("_market") or {}
        try:
            journal.capture_markouts(con)
        except Exception:
            pass
        eq = journal.snapshot_equity(con, port.get("equity_ada"), pol,
                                     {"wallet_ada": port.get("wallet_ada"), "source": "crypto_review"})
        positions = {}
        for asset, p in (port.get("positions") or {}).items():
            m = market.get(asset) or {}
            positions[asset] = {"tokens": p.get("tokens"), "cost_ada": p.get("cost_ada"), "breakeven": p.get("breakeven"),
                                "spot": p.get("spot"), "value_ada": p.get("value_ada"),
                                "unrealized_ada": p.get("unrealized_ada"),
                                "age_days": (p["age_s"] / 86400) if p.get("age_s") else None,
                                "uncosted_tokens": p.get("uncosted_tokens"), "fair_value": m.get("fair_value"),
                                "sigma_24h": m.get("sigma_24h")}
        out = {
            "status": "ok",
            "policy": {"execution": "live" if policy.live_execution_enabled(pol) else "dry_run",
                       "frozen": policy.is_frozen(con), "strategies": policy.strategy_states(con, pol),
                       "floor_ada": pol["wallet"]["floor_ada"], "fee_buffer_ada": pol["wallet"]["fee_buffer_ada"],
                       "max_positions": pol["capital"]["max_positions"],
                       "max_position_fraction": pol["capital"]["max_position_fraction"],
                       "max_pool_impact_pct": pol["capital"]["max_pool_impact_pct"]},
            "wallet": {"ada": port.get("wallet_ada"), "tokens": port.get("wallet_tokens"),
                       "locked_ada_in_orders": port.get("locked_ada_in_orders"), "equity_ada": port.get("equity_ada"),
                       "working_capital_ada": port.get("working_capital_ada"), "free_ada": port.get("free_ada")},
            "open_orders": [{k: o.get(k) for k in ("order_id", "asset", "side", "price", "ada", "tokens", "chain_status",
                                                   "plan_id")} | {"age_days": (time.time() - o["created_at"]) / 86400
                                                                  if o.get("created_at") else None}
                            for o in port.get("open_orders", [])],
            "positions": positions,
            "equity": eq,
            "gates": _gates(con, pol),
            "journal": {k: v for k, v in journal.summary(con, pol, 30).items() if k in ("live_trips", "markouts", "simulated", "open_trips")},
            "pending_plans": plans.list_plans(con, "proposed", 5),
            "standing_orders": plans.standing_orders(con),
            "recorder": _recorder_brief(),
            "warnings": port.get("warnings", []),
            "next_step": "Call crypto_plan with intent 'review' for concrete proposals (reprices, exits, reclaims), "
                         "or crypto_scan to look for entries.",
        }
        if out["journal"].get("live_trips"):
            out["journal"]["live_trips"].pop("recent", None)
        return out
    finally:
        con.close()


def cmd_scan(a) -> Dict[str, Any]:
    pol = policy.load_policy()
    assets = [x.strip().upper() for x in (a.assets or "").split(",") if x.strip()] or \
        [str(x).upper() for x in ((pol.get("recorder") or {}).get("pools") or [])]
    con = store.connect()
    try:
        states = policy.strategy_states(con, pol)
        try:
            port = pf.snapshot(pol, check_chain=False)
        except Exception:
            port = {"wallet_ada": None}
        sigs: Dict[str, Any] = {}
        try:
            from lib.tools.quant import signals
            sigs = signals.latest(assets)
        except ImportError:
            pass
        except Exception as e:
            sigs = {"_error": f"{type(e).__name__}: {e}"}
        rows = []
        for asset in assets:
            if not plans.ASSET_RE.match(asset):
                continue
            m = mkt.market_ctx(asset)
            row = mkt.public(m)
            if port.get("wallet_ada") is not None:
                caps = policy.max_buy_breakdown(asset, pol, port, {asset: m})
                row["max_buy_ada_now"] = round(caps["max_buy_ada"], 2)
                row["buy_caps"] = {k: v for k, v in caps.items() if k != "max_buy_ada"}
            else:
                row["max_buy_ada_now"] = None
                row["buy_caps"] = None
            fee = (m.get("fee_bps") if m.get("fee_bps") is not None else pol["fees"]["default_pool_fee_bps"]) / 1e4
            if row["max_buy_ada_now"]:
                row["round_trip_cost_pct_at_max"] = round((plans._round_trip_fixed(pol) / row["max_buy_ada_now"] + 2 * fee) * 100, 2)
            row["signals"] = sigs.get(asset, [])
            try:
                from lib.tools.quant import impact
                im = impact.cached(asset)
                row["flow_impact"] = {k: im.get(k) for k in ("status", "reversion_fraction", "half_life_h", "days")} \
                    if im else {"status": "not_run"}
            except Exception:
                row["flow_impact"] = {"status": "unavailable"}
            rows.append(row)
        bts: Dict[str, Any] = {}
        try:
            from lib.tools.trading import gates
            for s in gates.GATED:
                bt = gates.latest_backtest(con, s)
                if bt:
                    try:
                        variants = json.loads(bt.get("detail") or "{}").get("variants")
                    except ValueError:
                        variants = None
                    bts[s] = {"run_id": bt["run_id"], "age_h": round((time.time() - bt["ts"]) / 3600, 1),
                              "round_trips": bt["n_trips"], "mean_net_ada": bt["mean_ada"],
                              "lower80_ada": bt["lower80_ada"], "win_rate": bt["win_rate"],
                              "params": json.loads(bt.get("params_json") or "{}"), "variants": variants}
        except Exception as e:
            bts = {"_error": f"{type(e).__name__}: {e}"}
        return {"status": "ok", "strategy_states": states, "pools": rows, "backtests": bts,
                "how_to_read": "deviation_sigma < 0 means the pool trades below fair value. regime.vr_24h < 1 means "
                               "1-24 h moves partly revert (mean reversion); ~1 means random walk (no edge). "
                               "max_buy_ada_now is min(wallet_cap_ada, position_cap_ada, pool_impact_cap_ada) — check "
                               "buy_caps.binding_cap to see which cap is actually binding (never assume max_buy_ada_now "
                               "is the pool-impact cap). round_trip_cost_pct_at_max is the move a round trip must capture "
                               "to break even. flow_impact.reversion_fraction is the share of a swap's price move that reverts "
                               "(~0 = flow is information, fading it loses). backtests are walk-forward, net of all "
                               "fees; a strategy with mean_net_ada <= 0 has no demonstrated edge. "
                               "S2/S3 signals in 'simulated' state are journalled, not traded."}
    finally:
        con.close()


def cmd_plan(a) -> Dict[str, Any]:
    raw = a.intent or "review"
    try:
        intent: Any = json.loads(raw)
    except ValueError:
        intent = raw
    p = plans.build_plan(intent, origin=a.origin)
    keep = ("plan_id", "status", "tier", "expires_at", "execution_mode", "frozen", "summary", "how_to_execute",
            "notes", "actions", "refs")
    return {k: p[k] for k in keep}


def cmd_execute(a) -> Dict[str, Any]:
    return plans.execute_plan(a.plan_id, confirm_token=a.confirm_token, actor="george")


def cmd_standing(a) -> Dict[str, Any]:
    con = store.connect()
    try:
        if a.so_action == "list":
            return {"status": "ok", "standing_orders": plans.standing_orders(con, include_inactive=bool(a.all))}
        if a.so_action == "revoke":
            ok = plans.revoke_standing_order(con, a.id, by=a.origin)
            return {"status": "ok" if ok else "not_found", "so_id": a.id}
        spec = json.loads(a.spec or "{}")
        spec["kind"] = "standing_order"
        p = plans.build_plan(spec, origin=a.origin, con=con)
        return {k: p[k] for k in ("plan_id", "status", "tier", "summary", "how_to_execute", "actions")}
    finally:
        con.close()


def cmd_journal(a) -> Dict[str, Any]:
    pol = policy.load_policy()
    con = store.connect()
    try:
        try:
            journal.capture_markouts(con)
        except Exception:
            pass
        s = journal.summary(con, pol, float(a.window_days), a.strategy)
        s["gates"] = _gates(con, pol)
        return {"status": "ok", **s}
    finally:
        con.close()


def cmd_plans(a) -> Dict[str, Any]:
    con = store.connect()
    try:
        if a.plan_id:
            p = plans.get_plan(con, a.plan_id)
            return {"status": "ok" if p else "not_found", "plan": p}
        return {"status": "ok", "plans": plans.list_plans(con, a.status, int(a.limit))}
    finally:
        con.close()


# ---------------------------------------------------------------------------
# Operator confirmation
# ---------------------------------------------------------------------------

def _operator_ids() -> List[str]:
    from lib.comms import escalation
    return escalation.operator_ids()


def _discord_get(path: str) -> Dict[str, Any]:
    from lib.comms import escalation
    tok = escalation.get_key("DISCORD_BOT_TOKEN")
    if not tok:
        raise RuntimeError("DISCORD_BOT_TOKEN not set")
    req = urllib.request.Request(f"https://discord.com/api/v10{path}",
                                 headers={"Authorization": f"Bot {tok}", "User-Agent": "BlueLodge-George (trading confirm, 1.0)"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read().decode())


DISCORD_GET = _discord_get


def verify_discord_confirm(plan_id: str, channel: str, message_id: str, plan_created_at: int) -> Optional[str]:
    """Returns None if the message is a valid operator confirmation for plan_id, else the reason."""
    if not SNOWFLAKE_RE.match(channel or "") or not SNOWFLAKE_RE.match(message_id or ""):
        return "invalid channel/message id"
    ops = _operator_ids()
    if not ops:
        return "DISCORD_OPERATOR_ID / DISCORD_OWNER_ID not configured"
    try:
        msg = DISCORD_GET(f"/channels/{channel}/messages/{message_id}")
    except Exception as e:
        return f"could not fetch the message from Discord: {type(e).__name__}"
    author = (msg.get("author") or {}).get("id")
    if author not in ops:
        return "message was not written by the operator"
    if (msg.get("author") or {}).get("bot"):
        return "message was written by a bot"
    content = msg.get("content") or ""
    confirmed_ids = (
        {pid.upper() for pid in re.findall(r"\bP-[0-9A-F]{6}\b", content, re.IGNORECASE)}
        if re.search(r"\bconfirm\b", content, re.IGNORECASE)
        else set()
    )
    if plan_id.upper() not in confirmed_ids:
        return f"message does not say 'confirm {plan_id}'"
    sent_ms = (int(message_id) >> 22) + DISCORD_EPOCH_MS
    if sent_ms / 1000.0 < plan_created_at - 5:
        return "message predates the plan"
    if msg.get("edited_timestamp"):
        return "edited messages are not accepted as confirmations"
    return None


def cmd_confirm(a) -> Dict[str, Any]:
    if not plans.PLAN_RE.match(a.plan or ""):
        return {"status": "rejected", "reason": "invalid plan id"}
    con = store.connect()
    try:
        p = plans.get_plan(con, a.plan)
        if not p:
            return {"status": "rejected", "reason": "unknown plan"}
        if a.via == "discord":
            why = verify_discord_confirm(a.plan, a.channel, a.message_id, int(p["created_at"]))
            evidence = f"discord:{a.channel}:{a.message_id}:{a.plan.upper()}"
        elif a.via == "web":
            key_file = ensure_web_secret()
            given = os.environ.get("TRADING_WEB_CONFIRM_SECRET", "")
            try:
                want = key_file.read_text().strip()
            except OSError:
                want = ""
            why = None if (want and given and hmac.compare_digest(want, given)) else "web confirmation secret invalid"
            evidence = f"web:{a.plan}:{int(time.time())}:{os.urandom(4).hex()}"
        else:
            why, evidence = "unknown confirmation channel", ""
        if why:
            store.log_event(con, "confirm_rejected", {"plan_id": a.plan, "via": a.via, "reason": why})
            con.commit()
            return {"status": "rejected", "reason": why}
        try:
            tok = plans.mint_token(con, a.plan, a.via, evidence)
        except ValueError as e:
            return {"status": "rejected", "reason": str(e)}
    finally:
        con.close()
    res = plans.execute_plan(a.plan, confirm_token=tok, actor="george")
    res["confirmed_via"] = a.via
    if res.get("status") in ("executed", "partially_executed"):
        try:
            from lib.comms import escalation
            escalation.mark_plan_confirmed(a.plan, via=a.via)
        except Exception:
            pass
    return res


def ensure_web_secret() -> Path:
    d = _secrets_dir()
    d.mkdir(parents=True, exist_ok=True)
    f = d / "trading_confirm.key"
    if not f.exists():
        f.write_text(os.urandom(32).hex() + "\n")
        os.chmod(f, 0o600)
    return f


def cmd_touch_plans(a) -> Dict[str, Any]:
    return {"status": "ok", "refreshed": plans.refresh_plans_in_text(a.text or "")}


def main() -> None:
    ap = argparse.ArgumentParser(description="George trading tools")
    ap.add_argument("--origin", default="george")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("review")
    s = sub.add_parser("scan")
    s.add_argument("--assets", default="")
    s = sub.add_parser("plan")
    s.add_argument("--intent", default="review")
    s = sub.add_parser("execute")
    s.add_argument("--plan-id", required=True)
    s.add_argument("--confirm-token", default=None)
    s = sub.add_parser("standing-order")
    s.add_argument("so_action", choices=["create", "list", "revoke"])
    s.add_argument("--spec", default=None, help='JSON: {"strategy","asset","max_ada","price_min","price_max","expires_hours"}')
    s.add_argument("--id", default=None)
    s.add_argument("--all", action="store_true")
    s = sub.add_parser("journal")
    s.add_argument("--window-days", default="30")
    s.add_argument("--strategy", default=None)
    s = sub.add_parser("plans")
    s.add_argument("--status", default=None)
    s.add_argument("--plan-id", default=None)
    s.add_argument("--limit", default="20")
    s = sub.add_parser("confirm")
    s.add_argument("--plan", required=True)
    s.add_argument("--via", choices=["discord", "web"], required=True)
    s.add_argument("--channel", default="")
    s.add_argument("--message-id", default="")
    s = sub.add_parser("touch-plans")
    s.add_argument("--text", default="")
    sub.add_parser("init-web-secret")
    a = ap.parse_args()
    fn = {"review": cmd_review, "scan": cmd_scan, "plan": cmd_plan, "execute": cmd_execute,
          "standing-order": cmd_standing, "journal": cmd_journal, "plans": cmd_plans, "confirm": cmd_confirm,
          "touch-plans": cmd_touch_plans,
          "init-web-secret": lambda _a: {"status": "ok", "path": str(ensure_web_secret())}}[a.cmd]
    try:
        out = fn(a)
    except ValueError as e:
        out = {"status": "error", "reason": str(e)}
    except Exception as e:
        out = {"status": "error", "reason": f"{type(e).__name__}: {str(e)[:300]}"}
    print(json.dumps(_r(out), default=str))


if __name__ == "__main__":
    main()
