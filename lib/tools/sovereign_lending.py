#!/usr/bin/env python3
"""
Sovereign Lending - microloan underwriting, loan book and on-chain servicing for the
Sovereign Loan Fund.

Replaces the earlier underwriters, which scored hard-coded loans with hard-coded oracle prices,
wrong policy ids and fixed LTV tables. This module:

Underwriting (quantitative, from live data)
  * Collateral is priced in the principal asset: Cardano native tokens from their deepest ADA
    pool (daily OHLC, GeckoTerminal); ADA/BTC/ETH/POL/USDC from CoinGecko daily closes.
  * Risk over the loan term T uses two independent estimates:
      - closed-form first passage of driftless Brownian motion in log price with a T-day
        horizon sigma (captures short-horizon mean reversion / momentum), and
      - an empirical walk over every historical T-day window using intrabar lows.
    It reports P(liquidation trigger) and P(underwater: collateral after liquidation slippage <
    debt) and the empirical expected loss given the liquidation policy.
  * Liquidation slippage for Cardano tokens is the CPMM price impact of selling the full
    collateral into the pool (+fee); majors use a fixed 1% haircut.
  * Required APR = expected loss + opportunity cost (best real base APY for the principal asset,
    DeFiLlama) + servicing costs + policy risk margin, annualised.
  * The max safe LTV (bisection) and a counter-offer are always returned.

Loan book (.george/finance/loan_book.json, atomic writes + lock)
  REQUESTED -> APPROVED | REJECTED -> AWAITING_COLLATERAL -> FUNDED -> REPAID -> CLOSED
                                                    FUNDED -> MARGIN_CALL -> LIQUIDATED | DEFAULTED

Servicing (Cardano, ADA principal) - plain payments with CIP-20 messages, no custom script:
  * collateral: detected when the borrower's address sends >= the agreed units to the fund wallet;
  * disbursement: ADA payment to the borrower (policy action `loan_disburse`);
  * repayment: lovelace received from the borrower after funding, excluding the collateral tx;
  * close: collateral returned once principal + interest is received;
  * LTV monitor: margin call at the trigger, liquidation (Minswap V2 limit at a calibrated rung)
    when breached or after the grace period past due.
  Custody is trust-based (the fund wallet holds the collateral). TODO(security): replace with an
  audited escrow validator before lending to untrusted parties at scale.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import math
import os
import re
import secrets
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

import numpy as np

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if __name__ == "__main__" and _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)

from lib.tools import sovereign_fund as fund  # noqa: E402
from lib.tools.quant import models as qm  # noqa: E402

BOOK_FILE = Path(os.environ.get("LODGE_LOAN_BOOK", fund.FIN_DIR / "loan_book.json"))
MAJORS = ("ADA", "BTC", "ETH", "POL", "USDC")
PRINCIPAL_ASSETS = ("ADA", "USDC")
OPEN_LOAN_STATUSES = ("FUNDED", "MARGIN_CALL")
DEFAULT_LIQ_LTV = {"stable": 0.90, "major": 0.80, "token": 0.70}
SERVICING_COST_ADA = 0.2 + 0.2 + 0.2      # disburse + collateral return + misc L1 fees
LIQUIDATION_COST_ADA = 2.5                 # batcher fee + deposit churn + L1
MAJOR_SLIPPAGE = 0.01
LOAN_ID_RE = re.compile(r"^LN-[0-9A-F]{8}$")
ADDR_RE = re.compile(r"^addr1[0-9a-z]{50,110}$")
CIP20_LABEL = 674


# ---------------------------------------------------------------------------
# market data
# ---------------------------------------------------------------------------

def asset_class(sym: str, principal: str = "ADA") -> str:
    """Risk class of the collateral *relative to the principal asset*."""
    sym, principal = sym.upper(), principal.upper()
    usd_like = ("USDC", "DJED", "USDM", "USDCX")
    if sym in usd_like and principal in usd_like:
        return "stable"
    if sym in MAJORS or sym in usd_like:
        return "major"
    return "token"


def collateral_series(collateral: str, principal: str) -> Dict[str, Any]:
    """Daily (h, l, c) of the collateral priced in the principal asset, plus spot and pool info."""
    from lib.tools.quant.market_data import KNOWN_ASSETS, load_series
    collateral, principal = collateral.upper(), principal.upper()
    if collateral == principal:
        return {"status": "error", "reason": "collateral and principal must differ"}

    def usd_leg(sym: str) -> Dict[str, Any]:
        if sym in MAJORS:
            h = fund.usd_daily_history(sym)
            if h.get("status") != "ok":
                return h
            c = np.asarray(h["closes"], float)
            return {"status": "ok", "h": c, "l": c, "c": c, "source": "coingecko daily close"}
        if sym in KNOWN_ASSETS:
            s = load_series(sym, "day")
            if s.get("status") != "ok":
                return {"status": "error", "reason": s.get("reason")}
            ada = fund.usd_daily_history("ADA")
            if ada.get("status") != "ok":
                return ada
            g = s["grid"]
            n = min(len(g["c"]), len(ada["closes"]))
            a = np.asarray(ada["closes"][-n:], float)
            return {"status": "ok", "h": np.asarray(g["h"][-n:]) * a, "l": np.asarray(g["l"][-n:]) * a,
                    "c": np.asarray(g["c"][-n:]) * a, "source": "pool daily OHLC x ADA/USD", "pool": s["pool"]}
        return {"status": "error", "reason": f"unsupported asset {sym}"}

    # Fast, exact path: Cardano token collateral against ADA principal (pool is quoted in ADA).
    if principal == "ADA" and collateral in KNOWN_ASSETS:
        s = load_series(collateral, "day")
        if s.get("status") != "ok":
            return {"status": "error", "reason": s.get("reason")}
        g = s["grid"]
        return {"status": "ok", "h": np.asarray(g["h"], float), "l": np.asarray(g["l"], float),
                "c": np.asarray(g["c"], float), "spot": float(s["pool"]["price_ada"]), "pool": s["pool"],
                "source": f"{s['pool'].get('dex')} pool daily OHLC (ADA)", "bars": len(g["c"])}
    cl, pl = usd_leg(collateral), usd_leg(principal)
    for leg in (cl, pl):
        if leg.get("status") != "ok":
            return {"status": "error", "reason": leg.get("reason")}
    n = min(len(cl["c"]), len(pl["c"]))
    pc = pl["c"][-n:]
    c = cl["c"][-n:] / pc
    h = cl["h"][-n:] / pc
    l_ = cl["l"][-n:] / pc
    spot_usd = fund.usd_prices().get("usd", {})
    if collateral in MAJORS and principal in MAJORS and spot_usd.get(collateral) and spot_usd.get(principal):
        spot = spot_usd[collateral] / spot_usd[principal]
    else:
        spot = float(c[-1])
    return {"status": "ok", "h": h, "l": l_, "c": c, "spot": spot, "pool": cl.get("pool"),
            "source": f"{cl['source']} / {pl['source']}", "bars": n}


def liquidation_slippage(collateral: str, units: float, series: Dict[str, Any]) -> float:
    pool = series.get("pool") or {}
    rt, ra = pool.get("reserve_token_est"), pool.get("reserve_ada_est")
    if asset_class(collateral, "ADA") == "token" and rt and ra:
        # CPMM: selling dx into (x, y) at fee f realises y*dx(1-f)/(x+dx(1-f)) vs spot y/x*dx.
        f = 0.003
        dx = units * (1 - f)
        realised = ra * dx / (rt + dx)
        return float(max(0.0, 1 - realised / (units * ra / rt)))
    return MAJOR_SLIPPAGE


# ---------------------------------------------------------------------------
# risk model
# ---------------------------------------------------------------------------

def _horizon_sigma(lc: np.ndarray, T: int) -> float:
    r = np.diff(lc)
    s1 = float(np.std(r, ddof=1)) if len(r) > 2 else 0.0
    Tm = int(min(T, max(len(lc) // 6, 1)))
    if Tm <= 1 or len(lc) <= Tm + 10:
        return s1
    d = lc[Tm:] - lc[:-Tm]
    return float(np.std(d, ddof=1) / math.sqrt(Tm))


def term_risk(h: np.ndarray, l_: np.ndarray, c: np.ndarray, T: int, ltv0: float, liq_ltv: float,
              slip: float, interest_frac: float) -> Dict[str, Any]:
    """Risk of a loan with initial LTV ltv0 over T days.

    Price ratios relative to today: liquidation trigger at ltv0/liq_ltv, underwater when
    collateral*(1-slip) < debt*(1+interest) i.e. ratio ltv0*(1+i)/(1-slip)."""
    lc = np.log(c)
    sH = _horizon_sigma(lc, T)
    liq_ratio = ltv0 / liq_ltv
    uw_ratio = ltv0 * (1 + interest_frac) / (1 - slip)
    p_liq_cf = qm.gbm_hit_probability(math.log(liq_ratio), sH, T) if liq_ratio < 1 else 1.0
    p_uw_cf = qm.gbm_hit_probability(math.log(uw_ratio), sH, T) if uw_ratio < 1 else 1.0
    n = len(c)
    liq_hits = uw_hits = 0
    losses: List[float] = []
    windows = 0
    for t in range(0, n - 1):
        end = min(n, t + 1 + T)
        if end - (t + 1) < max(1, int(T * 0.8)):
            break
        windows += 1
        base = c[t]
        path_l = l_[t + 1:end] / base
        path_c = c[t + 1:end] / base
        if np.min(path_l) <= uw_ratio:
            uw_hits += 1
        touch = np.nonzero(path_l <= liq_ratio)[0]
        if touch.size:
            liq_hits += 1
            k = touch[0]
            # Daily monitoring: we sell at the touching day's close, never better than the trigger.
            exec_ratio = min(float(path_c[k]), liq_ratio)
            recovered = exec_ratio / ltv0 * (1 - slip)          # per unit of principal
            losses.append(max(0.0, (1 + interest_frac) - recovered))
        else:
            losses.append(0.0)
    p_liq_emp = liq_hits / windows if windows else None
    p_uw_emp = uw_hits / windows if windows else None
    el_emp = float(np.mean(losses)) if losses else None
    worst = float(np.max(losses)) if losses else None
    p_liq = float(np.median([v for v in (p_liq_cf, p_liq_emp) if v is not None]))
    p_uw = float(max(v for v in (p_uw_cf, p_uw_emp) if v is not None))
    # Closed-form EL proxy: P(underwater) x mean shortfall (half the gap to zero recovery bound).
    el_cf = p_uw_cf * max(0.0, (1 + interest_frac) - uw_ratio / ltv0 * (1 - slip) * 0.5) if p_uw_cf else 0.0
    el = max(el_emp or 0.0, min(el_cf, 1.0) * 0.5)
    return {"sigma_daily": float(np.std(np.diff(lc), ddof=1)) if n > 2 else None, "sigma_horizon_daily": sH,
            "liq_trigger_ratio": liq_ratio, "underwater_ratio": uw_ratio,
            "p_liquidation": {"closed_form": p_liq_cf, "empirical": p_liq_emp, "used": p_liq},
            "p_underwater": {"closed_form": p_uw_cf, "empirical": p_uw_emp, "used": p_uw},
            "expected_loss_frac": el, "worst_window_loss_frac": worst, "windows": windows}


def max_safe_ltv(h, l_, c, T, liq_ltv, slip, interest_frac, max_p_uw, max_p_liq) -> float:
    lo, hi = 0.01, min(liq_ltv * 0.98, 0.95)
    if lo >= hi:
        return 0.0
    for _ in range(30):
        mid = (lo + hi) / 2
        r = term_risk(h, l_, c, T, mid, liq_ltv, slip, interest_frac)
        if r["p_underwater"]["used"] <= max_p_uw and r["p_liquidation"]["used"] <= max_p_liq:
            lo = mid
        else:
            hi = mid
    return lo


# ---------------------------------------------------------------------------
# underwriting
# ---------------------------------------------------------------------------

def underwrite(collateral: str, units: float, principal: float, term_days: int, apr_pct: float,
               principal_asset: str = "ADA", borrower: str = "", liq_ltv: Optional[float] = None,
               check_capacity: bool = True) -> Dict[str, Any]:
    pol = fund.load_policy()
    collateral, principal_asset = collateral.upper(), principal_asset.upper()
    problems: List[str] = []
    for name, v in (("units", units), ("principal", principal), ("apr_pct", apr_pct)):
        if not (isinstance(v, (int, float)) and math.isfinite(v) and v >= 0):
            return {"status": "error", "message": f"{name} must be a finite non-negative number"}
    if principal_asset not in PRINCIPAL_ASSETS:
        return {"status": "error", "message": f"principal asset must be one of {PRINCIPAL_ASSETS}"}
    if units <= 0 or principal <= 0:
        return {"status": "error", "message": "units and principal must be > 0"}
    term_days = int(term_days)
    if not (1 <= term_days <= 365):
        return {"status": "error", "message": "term_days must be 1..365"}
    if borrower and not ADDR_RE.match(borrower):
        problems.append("borrower address is not a mainnet Cardano address")

    s = collateral_series(collateral, principal_asset)
    if s.get("status") != "ok":
        return {"status": "error", "message": f"market data unavailable: {s.get('reason')}"}
    spot = float(s["spot"])
    value = units * spot
    ltv0 = principal / value if value > 0 else float("inf")
    cls = asset_class(collateral, principal_asset)
    liq_ltv = float(liq_ltv or DEFAULT_LIQ_LTV[cls])
    slip = liquidation_slippage(collateral, units, s)
    interest_frac = apr_pct / 100.0 * term_days / 365.0
    if len(s["c"]) < max(30, term_days + 10):
        problems.append(f"only {len(s['c'])} daily bars of history; need >= {max(30, term_days + 10)}")
    risk = term_risk(s["h"], s["l"], s["c"], term_days, min(ltv0, 5.0), liq_ltv, slip, interest_frac)
    safe = max_safe_ltv(s["h"], s["l"], s["c"], term_days, liq_ltv, slip, interest_frac,
                        pol["max_p_underwater"], pol["max_p_liquidation"])

    coc = fund.cost_of_capital_apr(principal_asset)
    usd = fund.usd_prices().get("usd", {})
    ada_per_principal = 1.0 if principal_asset == "ADA" else (
        (usd.get(principal_asset) or 1.0) / usd["ADA"] if usd.get("ADA") else None)
    # Fixed L1 costs are charged as a flat origination fee (standard for microloans) so that they
    # do not masquerade as an enormous APR on small principals. Expected liquidation costs are
    # probabilistic and stay in the rate.
    fee_principal = (SERVICING_COST_ADA / ada_per_principal) if ada_per_principal else 0.0
    liq_cost_frac = ((LIQUIDATION_COST_ADA * risk["p_liquidation"]["used"]) / (principal * ada_per_principal)
                     if ada_per_principal else 0.0)
    ann = 365.0 / term_days
    required_apr = (risk["expected_loss_frac"] + liq_cost_frac) * ann * 100 + coc["apr_pct"] + pol["risk_margin_apr_pct"]
    all_in_apr = required_apr + fee_principal / principal * ann * 100
    expected_net = principal * (interest_frac - risk["expected_loss_frac"] - liq_cost_frac
                                - coc["apr_pct"] / 100 * term_days / 365)
    servicing_frac = liq_cost_frac

    if ltv0 >= liq_ltv:
        problems.append(f"initial LTV {ltv0:.1%} is at/above the liquidation trigger {liq_ltv:.0%}")
    if ltv0 > safe + 1e-9:
        problems.append(f"LTV {ltv0:.1%} exceeds max safe LTV {safe:.1%} for {term_days}d "
                        f"(P underwater ≤ {pol['max_p_underwater']:.0%}, P liq ≤ {pol['max_p_liquidation']:.0%})")
    if apr_pct + 1e-9 < required_apr:
        problems.append(f"offered APR {apr_pct:.2f}% below required {required_apr:.2f}%")
    if term_days > pol["max_term_days"]:
        problems.append(f"term {term_days}d exceeds policy max {pol['max_term_days']}d")
    if principal_asset == "ADA" and principal < pol["min_loan_ada"]:
        problems.append(f"principal below policy minimum {pol['min_loan_ada']} ADA")
    capacity = None
    if check_capacity:
        st = fund.fund_state(include_maker=False)
        avail = st["available"].get(principal_asset, 0.0)
        nav = sum(v for k, v in st["nav"].items() if k == principal_asset)
        cap = min(avail, nav * pol["max_loan_pct_of_fund"] / 100.0) if nav > 0 else 0.0
        capacity = {"available": round(avail, 6), "nav": round(nav, 6), "max_single_loan": round(cap, 6)}
        if principal > cap + 1e-9:
            problems.append(f"principal exceeds fund capacity {cap:.2f} {principal_asset} "
                            f"(available {avail:.2f}, concentration cap {pol['max_loan_pct_of_fund']}% of NAV)")
    counter = None
    if problems:
        cp = min(safe * value, capacity["max_single_loan"] if capacity else safe * value)
        counter = {"principal": round(max(0.0, cp * 0.98), 4), "apr_pct": round(max(required_apr, apr_pct), 2),
                   "term_days": min(term_days, pol["max_term_days"]),
                   "collateral_units_for_requested_principal": round(principal / (safe * spot), 6) if safe > 0 else None}
    hard = [p for p in problems if "capacity" not in p and "history" not in p]
    verdict = "APPROVE" if not problems else ("COUNTER" if counter and counter["principal"] >= pol["min_loan_ada"] * (
        1 if principal_asset == "ADA" else 0) and not any("address" in p for p in problems) else "REJECT")
    return {
        "status": "ok", "schema": "sovereign_underwriting/v1", "timestamp": int(time.time()),
        "verdict": verdict, "problems": problems, "hard_problems": hard,
        "collateral": {"asset": collateral, "class": cls, "units": units, "spot_in_principal": spot,
                       "value": round(value, 6), "source": s["source"], "bars": len(s["c"]),
                       "liquidation_slippage": round(slip, 5)},
        "loan": {"principal": principal, "principal_asset": principal_asset, "term_days": term_days,
                 "apr_pct": apr_pct, "interest": round(principal * interest_frac, 6),
                 "ltv": round(ltv0, 5), "liq_ltv": liq_ltv, "max_safe_ltv": round(safe, 5),
                 "liquidation_price": round(principal / (units * liq_ltv), 10),
                 "borrower": borrower or None},
        "risk": {k: (round(v, 6) if isinstance(v, float) else
                     ({kk: (round(vv, 6) if isinstance(vv, float) else vv) for kk, vv in v.items()} if isinstance(v, dict) else v))
                 for k, v in risk.items()},
        "pricing": {"required_apr_pct": round(required_apr, 3), "cost_of_capital": coc,
                    "risk_margin_apr_pct": pol["risk_margin_apr_pct"],
                    "origination_fee": round(fee_principal, 6),
                    "all_in_apr_pct_if_fee_waived": round(all_in_apr, 3),
                    "expected_liquidation_cost_frac": round(servicing_frac, 6),
                    "expected_net_return": round(expected_net, 6),
                    "note": "origination fee covers fixed L1 costs and is owed with principal + interest"},
        "capacity": capacity, "counter_offer": counter,
        "method": "first-passage (horizon sigma) + empirical T-day windows on daily lows; daily-monitored liquidation",
    }


# ---------------------------------------------------------------------------
# loan book
# ---------------------------------------------------------------------------

def load_book() -> Dict[str, Dict[str, Any]]:
    if not BOOK_FILE.exists():
        return {}
    try:
        return json.loads(BOOK_FILE.read_text()).get("loans", {})
    except (OSError, json.JSONDecodeError):
        return {}


def _save_book(loans: Dict[str, Dict[str, Any]]) -> None:
    BOOK_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = BOOK_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps({"schema": "loan_book/v1", "loans": loans}, indent=2, default=str))
    tmp.replace(BOOK_FILE)


class _BookLock:
    def __enter__(self):
        BOOK_FILE.parent.mkdir(parents=True, exist_ok=True)
        self.f = open(BOOK_FILE.with_suffix(".lock"), "w")
        fcntl.flock(self.f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *a):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


def _hist(ln: Dict[str, Any], event: str, **kw) -> None:
    ln.setdefault("history", []).append({"ts": int(time.time()), "event": event, **kw})


def create_request(borrower: str, collateral: str, units: float, principal: float, term_days: int,
                   apr_pct: float, principal_asset: str = "ADA", note: str = "", actor: str = "operator") -> Dict[str, Any]:
    if not ADDR_RE.match(borrower or ""):
        return {"status": "error", "message": "borrower must be a mainnet Cardano address (addr1…)"}
    uw = underwrite(collateral, units, principal, term_days, apr_pct, principal_asset, borrower)
    if uw.get("status") != "ok":
        return uw
    lid = "LN-" + secrets.token_hex(4).upper()
    from lib.tools.quant.market_data import KNOWN_ASSETS
    ln = {"id": lid, "created_at": int(time.time()), "borrower": borrower, "collateral_asset": collateral.upper(),
          "collateral_units": units, "collateral_unit": KNOWN_ASSETS.get(collateral.upper(), {}).get("unit"),
          "principal": principal, "principal_asset": principal_asset.upper(), "term_days": int(term_days),
          "apr_pct": apr_pct, "interest": uw["loan"]["interest"], "liq_ltv": uw["loan"]["liq_ltv"],
          "origination_fee": uw["pricing"]["origination_fee"],
          "status": "APPROVED" if uw["verdict"] == "APPROVE" else "REJECTED", "note": str(note)[:300],
          "underwriting": {k: uw[k] for k in ("verdict", "problems", "loan", "pricing", "risk", "counter_offer")},
          "created_by": actor, "used_txs": []}
    _hist(ln, "requested", verdict=uw["verdict"], actor=actor)
    if ln["status"] == "APPROVED":
        ln["status"] = "AWAITING_COLLATERAL"
        _hist(ln, "awaiting_collateral")
    with _BookLock():
        book = load_book()
        book[lid] = ln
        _save_book(book)
    return {"status": "ok", "loan": ln, "underwriting": uw,
            "instructions": (f"Borrower must send {units} {collateral.upper()} (+ ~1.5 ADA min-UTxO) from {borrower[:16]}… "
                             f"to the fund wallet {_fund_addr()}" if ln["status"] == "AWAITING_COLLATERAL" else None)}


def _fund_addr() -> str:
    from lib.tools import cardano_orders as co
    return co.default_wallet()[0]


def _incoming_from(borrower: str, since_ts: int, exclude: List[str]) -> List[Dict[str, Any]]:
    """Transactions after since_ts that spend an input from the borrower's address (or stake key)
    and pay the fund wallet. Returns [{tx, ts, value{unit:qty}}]."""
    from lib.tools import cardano_orders as co
    fund_a = _fund_addr()
    try:
        binfo = co.bf_get(f"/addresses/{borrower}", allow_404=True) or {}
    except Exception:
        binfo = {}
    bstake = binfo.get("stake_address")
    txs = co.bf_get(f"/addresses/{fund_a}/transactions?order=desc&count=50", allow_404=True) or []
    out = []
    for t in txs:
        if t.get("block_time", 0) < since_ts:
            break
        h = t["tx_hash"]
        if h in exclude:
            continue
        utx = co.bf_get(f"/txs/{h}/utxos")
        from_b = False
        for i in utx.get("inputs", []):
            if i["address"] == borrower:
                from_b = True
                break
            if bstake:
                try:
                    ai = co.bf_get(f"/addresses/{i['address']}", allow_404=True) or {}
                    if ai.get("stake_address") == bstake:
                        from_b = True
                        break
                except Exception:
                    pass
        if not from_b:
            continue
        val: Dict[str, int] = {}
        for o in utx.get("outputs", []):
            if o["address"] == fund_a:
                for a in o["amount"]:
                    val[a["unit"]] = val.get(a["unit"], 0) + int(a["quantity"])
        if val:
            out.append({"tx": h, "ts": t.get("block_time"), "value": val})
    return list(reversed(out))


def _owed(ln: Dict[str, Any]) -> float:
    return float(ln["principal"]) + float(ln["interest"]) + float(ln.get("origination_fee") or 0)


def service(loan_id: Optional[str] = None, execute: bool = False, actor: str = "operator") -> Dict[str, Any]:
    """Advance loans through their lifecycle from chain state. Without execute, only detects and
    reports (no transactions). With execute, disburses / returns collateral / liquidates."""
    from lib.tools.quant.market_data import KNOWN_ASSETS
    results = []
    with _BookLock():
        book = load_book()
        ids = [loan_id] if loan_id else list(book)
        for lid in ids:
            ln = book.get(lid)
            if not ln:
                results.append({"loan_id": lid, "status": "error", "message": "unknown loan"})
                continue
            r: Dict[str, Any] = {"loan_id": lid, "before": ln["status"], "actions": []}
            try:
                if ln["principal_asset"] != "ADA" and ln["status"] in ("AWAITING_COLLATERAL", "FUNDED", "MARGIN_CALL"):
                    r["actions"].append("USDC-principal loans are tracked but servicing is manual (Polygon)")
                elif ln["status"] == "AWAITING_COLLATERAL":
                    _service_collateral(ln, r, execute, actor)
                elif ln["status"] in OPEN_LOAN_STATUSES:
                    _service_open(ln, r, execute, actor)
                elif ln["status"] == "REPAID":
                    _return_collateral(ln, r, execute, actor)
                elif ln["status"] == "DEFAULTED":
                    _liquidate(ln, r, execute, actor, reason="default")
            except Exception as e:
                r["error"] = f"{type(e).__name__}: {e}"[:400]
            r["after"] = ln["status"]
            results.append(r)
        _save_book(book)
    return {"status": "ok", "execute": execute, "results": results}


def _service_collateral(ln, r, execute, actor):
    unit = ln.get("collateral_unit")
    seen = _incoming_from(ln["borrower"], ln["created_at"] - 600, ln.get("used_txs", []))
    got = 0
    for t in seen:
        q = t["value"].get(unit, 0) if unit else 0
        if q > 0:
            got += q
            ln.setdefault("collateral_txs", []).append(t["tx"])
            ln["used_txs"].append(t["tx"])
            ln["collateral_lovelace"] = ln.get("collateral_lovelace", 0) + t["value"].get("lovelace", 0)
    from lib.tools.quant.market_data import KNOWN_ASSETS
    dec = KNOWN_ASSETS.get(ln["collateral_asset"], {}).get("decimals", 0)
    ln["collateral_received_units"] = ln.get("collateral_received_units", 0) + got / 10 ** dec
    r["collateral_received_units"] = ln["collateral_received_units"]
    if ln["collateral_received_units"] + 1e-9 < float(ln["collateral_units"]):
        r["actions"].append(f"waiting for collateral ({ln['collateral_received_units']} / {ln['collateral_units']})")
        return
    _hist(ln, "collateral_received", units=ln["collateral_received_units"])
    # Re-underwrite at current prices before disbursing.
    uw = underwrite(ln["collateral_asset"], float(ln["collateral_units"]), float(ln["principal"]), int(ln["term_days"]),
                    float(ln["apr_pct"]), ln["principal_asset"], ln["borrower"], ln["liq_ltv"])
    r["reunderwrite_verdict"] = uw.get("verdict")
    if uw.get("verdict") != "APPROVE":
        r["actions"].append(f"re-underwriting failed at disbursement: {uw.get('problems')}")
        return
    from lib.tools.wallet import keystore
    res = keystore.send_cardano(None, ln["borrower"], float(ln["principal"]), execute=execute, actor=actor,
                                policy_action="loan_disburse", message=f"BlueLodge Sovereign Loan {ln['id']} disbursement")
    r["disbursement"] = {k: res.get(k) for k in ("status", "message", "tx_id", "fee_ada", "dry_run", "confirmed")}
    if execute and res.get("status") == "ok":
        ln["status"] = "FUNDED"
        ln["funded_tx"] = res["tx_id"]
        ln["funded_at"] = int(time.time())
        ln["due_at"] = ln["funded_at"] + int(ln["term_days"]) * 86400
        ln["used_txs"].append(res["tx_id"])
        fund.ledger_add("loan_out", "ADA", float(ln["principal"]), res["tx_id"], f"disburse {ln['id']}", actor, ln["id"])
        _hist(ln, "funded", tx=res["tx_id"])
        r["actions"].append("disbursed")
    else:
        r["actions"].append("dry run: would disburse" if res.get("status") == "ok" else "disbursement denied/failed")


def _current_ltv(ln) -> Optional[float]:
    s = collateral_series(ln["collateral_asset"], ln["principal_asset"])
    if s.get("status") != "ok":
        return None
    return _owed(ln) / (float(ln["collateral_units"]) * float(s["spot"]))


def _service_open(ln, r, execute, actor):
    seen = _incoming_from(ln["borrower"], ln.get("funded_at", ln["created_at"]), ln.get("used_txs", []))
    for t in seen:
        lov = t["value"].get("lovelace", 0)
        if lov > 0:
            ln.setdefault("repayments", []).append({"tx": t["tx"], "ada": lov / 1e6, "ts": t["ts"]})
            ln["used_txs"].append(t["tx"])
            _hist(ln, "repayment", tx=t["tx"], ada=lov / 1e6)
    paid = sum(p["ada"] for p in ln.get("repayments", []))
    ln["repaid_ada"] = round(paid, 6)
    r["repaid_ada"], r["owed_ada"] = paid, _owed(ln)
    if paid + 1e-6 >= _owed(ln):
        ln["status"] = "REPAID"
        _hist(ln, "repaid", ada=paid)
        if not ln.get("ledger_repaid"):
            fund.ledger_add("repay_principal", "ADA", float(ln["principal"]), ln["repayments"][-1]["tx"],
                            f"repay {ln['id']}", actor, ln["id"])
            extra = paid - float(ln["principal"])
            if extra > 0:
                fund.ledger_add("interest", "ADA", extra, ln["repayments"][-1]["tx"], f"interest {ln['id']}", actor, ln["id"])
            ln["ledger_repaid"] = True
        # Persist REPAID before any transfer: the wallet policy re-reads the book from disk and only
        # allows a collateral return to a borrower whose loan is REPAID. (Caller holds _BookLock.)
        disk = load_book()
        disk[ln["id"]] = ln
        _save_book(disk)
        _return_collateral(ln, r, execute, actor)
        return
    ltv = _current_ltv(ln)
    r["ltv"] = ltv
    if ltv is not None:
        ln["last_ltv"] = round(ltv, 5)
        if ltv >= float(ln["liq_ltv"]):
            if ln["status"] != "MARGIN_CALL":
                ln["status"] = "MARGIN_CALL"
                ln["margin_call_at"] = int(time.time())
                _hist(ln, "margin_call", ltv=ltv)
            _liquidate(ln, r, execute, actor, reason=f"LTV {ltv:.1%} >= trigger {float(ln['liq_ltv']):.0%}")
            return
        if ln["status"] == "MARGIN_CALL" and ltv < float(ln["liq_ltv"]) * 0.95:
            ln["status"] = "FUNDED"
            _hist(ln, "margin_cured", ltv=ltv)
    grace = fund.load_policy()["liquidation_grace_days"] * 86400
    if ln.get("due_at") and time.time() > ln["due_at"] + grace:
        ln["status"] = "DEFAULTED"
        _hist(ln, "defaulted", repaid=paid)
        _liquidate(ln, r, execute, actor, reason="past due + grace")
    else:
        r["actions"].append(f"open; repaid {paid:.2f}/{_owed(ln):.2f} ADA; LTV {ltv if ltv is None else round(ltv, 4)}")


def _return_collateral(ln, r, execute, actor):
    if ln.get("collateral_return_tx"):
        ln["status"] = "CLOSED"
        return
    from lib.tools.quant.market_data import KNOWN_ASSETS
    unit = ln.get("collateral_unit")
    dec = KNOWN_ASSETS.get(ln["collateral_asset"], {}).get("decimals", 0)
    qty = int(round(float(ln["collateral_units"]) * 10 ** dec))
    min_ada = max(1.5, ln.get("collateral_lovelace", 1_500_000) / 1e6)
    from lib.tools.wallet import keystore
    res = keystore.send_cardano(None, ln["borrower"], min_ada, asset_unit=unit, asset_qty=qty, execute=execute,
                                actor=actor, policy_action="loan_return_collateral",
                                message=f"BlueLodge Sovereign Loan {ln['id']} collateral return")
    r["collateral_return"] = {k: res.get(k) for k in ("status", "message", "tx_id", "dry_run", "confirmed")}
    if execute and res.get("status") == "ok":
        ln["collateral_return_tx"] = res["tx_id"]
        ln["status"] = "CLOSED"
        ln["used_txs"].append(res["tx_id"])
        _hist(ln, "closed", tx=res["tx_id"])
        r["actions"].append("collateral returned; loan closed")
    else:
        r["actions"].append("dry run: would return collateral" if res.get("status") == "ok" else "collateral return failed")


def _liquidate(ln, r, execute, actor, reason: str):
    if ln.get("liquidation_tx"):
        r["actions"].append(f"liquidation order already placed {ln['liquidation_tx'][:12]}…")
        return
    from lib.tools.limit_order_forecaster import choose_rung, price_ladder
    units = float(ln["collateral_units"])
    lad = price_ladder(ln["collateral_asset"], "sell", units, n_rungs=11, span_pct=2.0)
    best = choose_rung(lad, "6h", 0.8) if lad.get("status") == "ok" else None
    price = best["price"] if best else (lad.get("spot_price_ada") or 0) * 0.99
    r["liquidation_plan"] = {"reason": reason, "price": price, "spot": lad.get("spot_price_ada"),
                             "p6h": best and best["fill_probability"].get("6h")}
    if not execute:
        r["actions"].append(f"dry run: would liquidate {units} {ln['collateral_asset']} @ {price:.8f} ({reason})")
        return
    from lib.tools.minswap_v2 import place_limit_order
    res = place_limit_order(ln["collateral_asset"], "sell", units, price, execute=True,
                            actor="operator" if actor == "operator" else "george")
    if res.get("status") == "ok":
        ln["liquidation_tx"] = res["tx_id"]
        ln["status"] = "LIQUIDATED"
        _hist(ln, "liquidation_listed", tx=res["tx_id"], price=price, reason=reason)
        r["actions"].append(f"liquidation listed {res['tx_id'][:12]}…; proceeds booked when filled (manual ledger entry)")
    else:
        r["actions"].append(f"liquidation failed: {res.get('message')}")


def cancel_request(loan_id: str, actor: str = "operator") -> Dict[str, Any]:
    with _BookLock():
        book = load_book()
        ln = book.get(loan_id)
        if not ln:
            return {"status": "error", "message": "unknown loan"}
        if ln["status"] not in ("AWAITING_COLLATERAL", "REJECTED", "APPROVED", "REQUESTED"):
            return {"status": "error", "message": f"cannot cancel a loan in {ln['status']}"}
        if ln.get("collateral_received_units"):
            return {"status": "error", "message": "collateral already received; return it before cancelling"}
        ln["status"] = "CANCELLED"
        _hist(ln, "cancelled", actor=actor)
        _save_book(book)
    return {"status": "ok", "loan": ln}


def book_summary() -> Dict[str, Any]:
    book = load_book()
    by: Dict[str, int] = {}
    for ln in book.values():
        by[ln["status"]] = by.get(ln["status"], 0) + 1
    loans = sorted(book.values(), key=lambda x: -x["created_at"])
    slim = [{k: ln.get(k) for k in ("id", "status", "borrower", "collateral_asset", "collateral_units", "principal",
                                     "principal_asset", "apr_pct", "term_days", "interest", "liq_ltv", "last_ltv",
                                     "repaid_ada", "funded_tx", "due_at", "created_at", "collateral_received_units")}
            for ln in loans]
    for s in slim:
        s["verdict"] = book[s["id"]].get("underwriting", {}).get("verdict")
    return {"status": "ok", "count": len(book), "by_status": by, "loans": slim[:100]}


def main() -> None:
    p = argparse.ArgumentParser(description="Sovereign Lending: underwriting, loan book, servicing")
    sub = p.add_subparsers(dest="cmd", required=True)
    u = sub.add_parser("underwrite")
    for s_ in (u, sub.add_parser("request")):
        s_.add_argument("--collateral", required=True)
        s_.add_argument("--units", type=float, required=True)
        s_.add_argument("--principal", type=float, required=True)
        s_.add_argument("--term-days", type=int, default=14)
        s_.add_argument("--apr", type=float, required=True)
        s_.add_argument("--principal-asset", default="ADA", choices=list(PRINCIPAL_ASSETS))
        s_.add_argument("--borrower", default="")
        s_.add_argument("--note", default="")
        s_.add_argument("--actor", default="operator", choices=["operator", "george"])
    sv = sub.add_parser("service")
    sv.add_argument("--loan-id", default=None)
    sv.add_argument("--execute", action="store_true")
    sv.add_argument("--actor", default="operator", choices=["operator", "george"])
    c = sub.add_parser("cancel")
    c.add_argument("--loan-id", required=True)
    c.add_argument("--actor", default="operator", choices=["operator", "george"])
    sub.add_parser("book")
    a = p.parse_args()
    try:
        if a.cmd == "underwrite":
            res = underwrite(a.collateral, a.units, a.principal, a.term_days, a.apr, a.principal_asset, a.borrower)
        elif a.cmd == "request":
            res = create_request(a.borrower, a.collateral, a.units, a.principal, a.term_days, a.apr,
                                 a.principal_asset, a.note, a.actor)
        elif a.cmd == "service":
            if a.loan_id and not LOAN_ID_RE.match(a.loan_id):
                raise ValueError("bad loan id")
            res = service(a.loan_id, a.execute, a.actor)
        elif a.cmd == "cancel":
            if not LOAN_ID_RE.match(a.loan_id):
                raise ValueError("bad loan id")
            res = cancel_request(a.loan_id, a.actor)
        else:
            res = book_summary()
    except Exception as e:
        res = {"status": "error", "message": f"{type(e).__name__}: {e}"}
    print(json.dumps(qm.json_safe(res), default=str))


if __name__ == "__main__":
    main()
