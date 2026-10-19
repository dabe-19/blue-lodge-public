#!/usr/bin/env python3
"""
Spending policy for autonomous (George) wallet actions.

The operator is never capped here (the UI confirms every operator action), but any
action whose actor is not "operator" must pass this policy. Spend is accounted from
the append-only audit log (.george/finance/wallet_audit.jsonl), so caps survive
restarts. Policy file: .george/wallets/policy.json (created with conservative
defaults on first use).
"""
from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any, Dict, Optional

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path.home() / "blue-lodge"))
GEORGE_DIR = Path(os.environ.get("GEORGE_DIR", LODGE_DIR / ".george"))
POLICY_FILE = GEORGE_DIR / "wallets" / "policy.json"
AUDIT_FILE = GEORGE_DIR / "finance" / "wallet_audit.jsonl"

DEFAULT_POLICY: Dict[str, Any] = {
    "george": {
        "enabled": True,
        "wallets": ["agent-hot"],
        "max_ada_per_tx": 500.0,
        "max_ada_per_day": 2000.0,
        "allowed_actions": ["limit_buy", "limit_sell", "reclaim", "sign_message", "loan_disburse",
                            "loan_return_collateral"],
        "allowed_assets": ["IAG", "SNEK", "MIN", "WMTX", "DJED", "NIGHT", "USDM", "USDCX", "HOSKY"],
        "send_allowlist": [],
        "reserve_floor_ada": 10.0,
    }
}

ACTION_SPENDS = {"limit_buy", "swap", "send", "loan_disburse", "loan_return_collateral"}


def load_policy() -> Dict[str, Any]:
    if not POLICY_FILE.exists():
        POLICY_FILE.parent.mkdir(parents=True, exist_ok=True)
        POLICY_FILE.write_text(json.dumps(DEFAULT_POLICY, indent=2))
        os.chmod(POLICY_FILE, 0o600)
    try:
        return json.loads(POLICY_FILE.read_text())
    except json.JSONDecodeError:
        return DEFAULT_POLICY


def save_policy(policy: Dict[str, Any]) -> None:
    POLICY_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = POLICY_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(policy, indent=2))
    os.chmod(tmp, 0o600)
    tmp.replace(POLICY_FILE)


def spent_today(actor: str) -> float:
    if not AUDIT_FILE.exists():
        return 0.0
    cutoff = time.time() - 86400
    total = 0.0
    with open(AUDIT_FILE) as f:
        for line in f:
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if r.get("actor") == actor and r.get("ts", 0) >= cutoff and r.get("kind") == "policy_spend":
                total += float(r.get("ada", 0))
    return total


def check(actor: str, action: str, ada_out: float = 0.0, asset: Optional[str] = None,
          destination: Optional[str] = None, wallet_id: Optional[str] = None) -> Dict[str, Any]:
    if actor == "operator":
        return {"allowed": True, "reason": "operator action (confirmed in UI)"}
    pol = load_policy().get(actor)
    if not pol or not pol.get("enabled"):
        return {"allowed": False, "reason": f"no enabled policy for actor '{actor}'"}
    if action not in pol.get("allowed_actions", []):
        return {"allowed": False, "reason": f"action '{action}' not permitted for {actor}"}
    if wallet_id and wallet_id not in pol.get("wallets", []):
        return {"allowed": False, "reason": f"wallet '{wallet_id}' not delegated to {actor}"}
    if asset and asset.upper() not in [a.upper() for a in pol.get("allowed_assets", [])] and asset.upper() != "ADA":
        return {"allowed": False, "reason": f"asset {asset} not on {actor}'s allow-list"}
    if action == "send" and destination not in pol.get("send_allowlist", []):
        return {"allowed": False, "reason": "destination not on send allow-list"}
    if action in ("loan_disburse", "loan_return_collateral"):
        want = {"loan_disburse": ("AWAITING_COLLATERAL",), "loan_return_collateral": ("REPAID",)}[action]
        try:
            from lib.tools.sovereign_lending import load_book
            ok = any(ln.get("borrower") == destination and ln.get("status") in want for ln in load_book().values())
        except Exception:
            ok = False
        if not ok:
            return {"allowed": False, "reason": f"no loan in {want} for this destination"}
    if action in ACTION_SPENDS:
        if ada_out > float(pol.get("max_ada_per_tx", 0)):
            return {"allowed": False, "reason": f"{ada_out:.2f} ADA exceeds per-tx cap {pol.get('max_ada_per_tx')}"}
        day = spent_today(actor)
        if day + ada_out > float(pol.get("max_ada_per_day", 0)):
            return {"allowed": False,
                    "reason": f"daily cap {pol.get('max_ada_per_day')} ADA would be exceeded (spent {day:.2f})"}
    return {"allowed": True, "reason": "within policy"}


def record_spend(actor: str, ada: float, ref: str) -> None:
    if actor == "operator" or ada <= 0:
        return
    AUDIT_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(AUDIT_FILE, "a") as f:
        f.write(json.dumps({"ts": int(time.time()), "kind": "policy_spend", "actor": actor, "ada": ada, "ref": ref}) + "\n")
