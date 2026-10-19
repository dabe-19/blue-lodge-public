#!/usr/bin/env python3
"""Offline validation of the Sovereign Loan Fund building blocks (no network).
Run: .venv/bin/python tests/sovereign_fund_test.py"""
import json
import math
import os
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

# Isolate every file the modules write to before importing them.
_TMP = tempfile.mkdtemp(prefix="fund_test_")
os.environ["LODGE_FUND_LEDGER"] = os.path.join(_TMP, "ledger.jsonl")
os.environ["LODGE_FUND_POLICY"] = os.path.join(_TMP, "policy.json")
os.environ["LODGE_LOAN_BOOK"] = os.path.join(_TMP, "loan_book.json")
os.environ["GEORGE_DIR"] = os.path.join(_TMP, "george")

from lib.tools import sovereign_fund as fund  # noqa: E402
from lib.tools import sovereign_lending as lending  # noqa: E402
from lib.tools import limit_order_forecaster as lof  # noqa: E402
from lib.tools import polymarket_probability_arbitrageur as poly  # noqa: E402
from lib.tools.wallet import policy as wpolicy  # noqa: E402


def gbm_daily(n=200, sigma=0.04, seed=7, s0=1.0):
    rng = np.random.default_rng(seed)
    c = s0 * np.exp(np.cumsum(sigma * rng.standard_normal(n)))
    low = c * np.exp(-np.abs(sigma * 0.5 * rng.standard_normal(n)))
    high = c * np.exp(np.abs(sigma * 0.5 * rng.standard_normal(n)))
    return high, low, c


class TestTermRisk(unittest.TestCase):
    def test_risk_increases_with_ltv(self):
        h, l_, c = gbm_daily()
        lo = lending.term_risk(h, l_, c, 30, 0.2, 0.7, 0.01, 0.02)
        hi = lending.term_risk(h, l_, c, 30, 0.6, 0.7, 0.01, 0.02)
        self.assertLessEqual(lo["p_liquidation"]["used"], hi["p_liquidation"]["used"])
        self.assertLessEqual(lo["p_underwater"]["used"], hi["p_underwater"]["used"])
        self.assertGreater(hi["windows"], 100)

    def test_risk_increases_with_volatility(self):
        calm = lending.term_risk(*gbm_daily(sigma=0.01), 30, 0.5, 0.7, 0.01, 0.02)
        wild = lending.term_risk(*gbm_daily(sigma=0.08), 30, 0.5, 0.7, 0.01, 0.02)
        self.assertLess(calm["p_liquidation"]["used"], wild["p_liquidation"]["used"])

    def test_probabilities_are_probabilities(self):
        r = lending.term_risk(*gbm_daily(), 14, 0.4, 0.7, 0.003, 0.01)
        for k in ("p_liquidation", "p_underwater"):
            self.assertGreaterEqual(r[k]["used"], 0.0)
            self.assertLessEqual(r[k]["used"], 1.0)
        self.assertGreaterEqual(r["expected_loss_frac"], 0.0)

    def test_trigger_at_or_above_spot_is_certain(self):
        r = lending.term_risk(*gbm_daily(), 14, 0.7, 0.7, 0.0, 0.0)
        self.assertEqual(r["p_liquidation"]["closed_form"], 1.0)


class TestMaxSafeLtv(unittest.TestCase):
    def test_monotone_in_volatility_and_respects_limits(self):
        calm = lending.max_safe_ltv(*gbm_daily(sigma=0.01), 30, 0.7, 0.01, 0.02, 0.05, 0.25)
        wild = lending.max_safe_ltv(*gbm_daily(sigma=0.08), 30, 0.7, 0.01, 0.02, 0.05, 0.25)
        self.assertGreater(calm, wild)
        self.assertLess(calm, 0.7)
        r = lending.term_risk(*gbm_daily(sigma=0.08), 30, wild, 0.7, 0.01, 0.02)
        self.assertLessEqual(r["p_underwater"]["used"], 0.05 + 1e-9)
        self.assertLessEqual(r["p_liquidation"]["used"], 0.25 + 1e-9)


class TestAssetClass(unittest.TestCase):
    def test_relative_to_principal(self):
        self.assertEqual(lending.asset_class("DJED", "USDC"), "stable")
        self.assertNotEqual(lending.asset_class("DJED", "ADA"), "stable")
        self.assertEqual(lending.asset_class("SNEK", "ADA"), "token")


class TestChooseRung(unittest.TestCase):
    LADDER = {"direction": "SELL", "rungs": [
        {"price": 1.00, "fill_probability": {"24h": 0.9}},
        {"price": 1.01, "fill_probability": {"24h": 0.72}},
        {"price": 1.02, "fill_probability": {"24h": 0.5}},
    ]}

    def test_sell_picks_highest_price_meeting_threshold(self):
        self.assertEqual(lof.choose_rung(self.LADDER, "24h", 0.7)["price"], 1.01)

    def test_buy_picks_lowest_price_meeting_threshold(self):
        buy = {"direction": "BUY", "rungs": [
            {"price": 0.98, "fill_probability": {"24h": 0.4}},
            {"price": 0.99, "fill_probability": {"24h": 0.75}},
            {"price": 1.00, "fill_probability": {"24h": 0.95}},
        ]}
        self.assertEqual(lof.choose_rung(buy, "24h", 0.7)["price"], 0.99)

    def test_none_when_unreachable(self):
        self.assertIsNone(lof.choose_rung(self.LADDER, "24h", 0.99))


class TestLedger(unittest.TestCase):
    def setUp(self):
        for p in (fund.LEDGER_FILE, fund.POLICY_FILE):
            if Path(p).exists():
                Path(p).unlink()

    def test_allocate_then_state(self):
        fund.ledger_add("allocate", "ADA", 30, note="seed", actor="operator")
        st = fund.fund_state(include_maker=False)
        self.assertAlmostEqual(st["nav"]["ADA"], 30.0)
        self.assertAlmostEqual(st["available"]["ADA"], 30.0)

    def test_george_cannot_allocate_ada(self):
        with self.assertRaises(ValueError):
            fund.ledger_add("allocate", "ADA", 5, actor="george")

    def test_overdraw_rejected(self):
        fund.ledger_add("allocate", "ADA", 10, actor="operator")
        with self.assertRaises(ValueError):
            fund.ledger_add("deallocate", "ADA", 11, actor="operator")

    def test_invalid_inputs(self):
        for args in (("bogus", "ADA", 1), ("allocate", "DOGE", 1), ("allocate", "ADA", -1), ("allocate", "ADA", float("nan"))):
            with self.assertRaises(ValueError):
                fund.ledger_add(*args, actor="operator")

    def test_ledger_is_append_only_jsonl(self):
        fund.ledger_add("allocate", "USDC", 3, actor="operator")
        fund.ledger_add("expense", "USDC", 1, actor="george")
        lines = Path(fund.LEDGER_FILE).read_text().strip().splitlines()
        self.assertEqual([json.loads(x)["type"] for x in lines], ["allocate", "expense"])


class TestPolicyLoanGuard(unittest.TestCase):
    BORROWER = "addr1" + "q" * 98

    def _book(self, status):
        lending._save_book({"LN-0000000A": {"id": "LN-0000000A", "borrower": self.BORROWER, "status": status}})

    def _george_policy(self):
        p = json.loads(json.dumps(wpolicy.DEFAULT_POLICY))
        wpolicy.save_policy(p)

    def test_disburse_requires_awaiting_collateral(self):
        self._george_policy()
        self._book("AWAITING_COLLATERAL")
        self.assertTrue(wpolicy.check("george", "loan_disburse", 5, destination=self.BORROWER)["allowed"])
        self._book("FUNDED")
        self.assertFalse(wpolicy.check("george", "loan_disburse", 5, destination=self.BORROWER)["allowed"])

    def test_collateral_return_requires_repaid(self):
        self._george_policy()
        self._book("FUNDED")
        self.assertFalse(wpolicy.check("george", "loan_return_collateral", 1.5, destination=self.BORROWER)["allowed"])
        self._book("REPAID")
        self.assertTrue(wpolicy.check("george", "loan_return_collateral", 1.5, destination=self.BORROWER)["allowed"])

    def test_unknown_destination_denied(self):
        self._george_policy()
        self._book("AWAITING_COLLATERAL")
        other = "addr1" + "z" * 98
        self.assertFalse(wpolicy.check("george", "loan_disburse", 5, destination=other)["allowed"])

    def test_per_tx_cap_applies(self):
        self._george_policy()
        self._book("AWAITING_COLLATERAL")
        self.assertFalse(wpolicy.check("george", "loan_disburse", 1000, destination=self.BORROWER)["allowed"])


class TestPolymarketBestLevels(unittest.TestCase):
    def test_best_bid_is_max_and_best_ask_is_min(self):
        # CLOB returns bids ascending and asks descending (worst first).
        book = {"bids": [{"price": "0.01", "size": "100"}, {"price": "0.40", "size": "5"}],
                "asks": [{"price": "0.99", "size": "100"}, {"price": "0.45", "size": "7"}]}
        b = poly.best_levels(book)
        self.assertEqual((b["bid"], b["bid_size"]), (0.40, 5.0))
        self.assertEqual((b["ask"], b["ask_size"]), (0.45, 7.0))

    def test_empty_book(self):
        b = poly.best_levels({"bids": [], "asks": []})
        self.assertIsNone(b["bid"])
        self.assertIsNone(b["ask"])


if __name__ == "__main__":
    unittest.main()
