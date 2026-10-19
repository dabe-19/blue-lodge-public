#!/usr/bin/env python3
"""Tests for encrypted keystore auto-unlock, Receive QR/URI generation, token symbol resolution,
and Tier B wallet_send plan gating (sandboxed GEORGE_DIR; no network calls).
Run: .venv/bin/python tests/test_keystore_send_receive.py
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

TMP = tempfile.mkdtemp(prefix="george-send-recv-test-")
os.environ["GEORGE_DIR"] = os.path.join(TMP, ".george")
os.environ["CARDANO_TEST_MODE"] = "1"
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.tools.wallet import keystore as K  # noqa: E402
from lib.tools.wallet import qr as QR  # noqa: E402
from lib.tools.trading import plans as TP  # noqa: E402
from lib.tools.trading import policy as TPOL  # noqa: E402

PW = "sovereign-test-passphrase-1234"


class TestKeystoreSendReceive(unittest.TestCase):
    def setUp(self):
        # Mock portfolio & market for plans.py so no network calls occur
        TP.SNAPSHOT = lambda pol, market=None, check_chain=True: {
            "wallet_ada": 250.0,
            "free_ada": 200.0,
            "working_capital_ada": 200.0,
            "positions": {},
            "open_orders": [],
            "exposure_ada": {},
            "wallet_tokens": {},
            "warnings": [],
        }
        TP.MARKET = lambda asset, use_cache=True: {
            "spot": 0.003,
            "fair_value": 0.0031,
            "sigma_1h": 0.02,
            "sigma_24h": 0.08,
            "fee_bps": 30,
        }

    def test_qr_matrix_svg_ansi(self):
        m = QR.matrix("web+cardano:addr1q9test?amount=25")
        self.assertGreaterEqual(len(m), 21)
        self.assertEqual(len(m), len(m[0]))
        svg = QR.to_svg("web+cardano:addr1q9test?amount=25")
        self.assertIn("<svg", svg)
        self.assertIn("<rect", svg)
        ansi = QR.to_ansi("web+cardano:addr1q9test?amount=25")
        self.assertTrue(len(ansi.splitlines()) >= 10)

    def test_token_symbol_resolution(self):
        unit, qty, sym, dec = K._resolve_cardano_token("SNEK", 1000.0)
        self.assertEqual(sym, "SNEK")
        self.assertTrue(len(unit) > 56)
        self.assertEqual(qty, int(round(1000.0 * (10 ** dec))))

    def test_wallet_send_intent_parsing_and_tier_b_gate(self):
        dest = "addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3jcu5d8ps7zex2k2xt3uqxgjqnnj83ws8lhrn648jjxtwq2ytjqp"
        parsed = TP.parse_intent(f"send 25 ADA to {dest} memo test-payment")
        self.assertEqual(parsed["kind"], "wallet_send")
        self.assertEqual(parsed["amount"], 25.0)
        self.assertEqual(parsed["token"], "ADA")
        self.assertEqual(parsed["to"], dest)
        self.assertEqual(parsed["message"], "test-payment")

        plan = TP.build_plan(parsed, origin="george")
        self.assertEqual(plan["tier"], "B")
        self.assertEqual(plan["status"], "proposed")
        self.assertEqual(plan["actions"][0]["type"], "wallet_send")

        # Calling execute_plan without operator confirm token must be refused (needs_confirmation)
        unconfirmed = TP.execute_plan(plan["plan_id"], confirm_token=None, actor="george")
        self.assertEqual(unconfirmed["status"], "needs_confirmation")

    def test_wallet_send_breaching_floor_is_blocked_tier_c(self):
        dest = "addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3jcu5d8ps7zex2k2xt3uqxgjqnnj83ws8lhrn648jjxtwq2ytjqp"
        # Wallet has 250 ADA and floor is 40 ADA -> sending 220 ADA leaves 29.8 ADA < 40 ADA floor -> Tier C blocked
        plan = TP.build_plan({"kind": "wallet_send", "to": dest, "amount": 220.0, "token": "ADA", "chain": "cardano"})
        self.assertEqual(plan["actions"][0]["tier"], "C")
        self.assertTrue(plan["actions"][0]["blocked"])
        self.assertEqual(plan["status"], "blocked")


if __name__ == "__main__":
    unittest.main()
