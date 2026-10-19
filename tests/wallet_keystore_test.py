#!/usr/bin/env python3
"""Keystore + policy tests (sandboxed GEORGE_DIR; no network).
Run: .venv/bin/python tests/wallet_keystore_test.py"""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

TMP = tempfile.mkdtemp(prefix="george-keystore-test-")
os.environ["GEORGE_DIR"] = os.path.join(TMP, ".george")
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.tools.wallet import keystore as K  # noqa: E402
from lib.tools.wallet import policy as P  # noqa: E402

PW = "correct horse battery staple"


class TestKeystore(unittest.TestCase):
    def test_create_list_sign_verify_cardano(self):
        r = K.create_wallet("cardano", "Operator Main", PW)
        wid = r["wallet"]["id"]
        self.assertEqual(len(r["mnemonic"].split()), 24)
        self.assertTrue(r["wallet"]["addresses"]["base"].startswith("addr1q"))
        self.assertNotIn("secret", r["wallet"])
        listed = [w["id"] for w in K.list_wallets()["wallets"]]
        self.assertIn(wid, listed)
        raw = json.loads((K.KEYSTORE_DIR / f"{wid}.json").read_text())
        self.assertNotIn(r["mnemonic"].split()[0] + " " + r["mnemonic"].split()[1], json.dumps(raw))
        self.assertEqual(oct(os.stat(K.KEYSTORE_DIR / f"{wid}.json").st_mode & 0o777), "0o600")
        s = K.sign_message(wid, "blue lodge proves control", PW)
        v = K.verify_message("cardano", s["signature"], "blue lodge proves control", r["wallet"]["addresses"]["base"])
        self.assertTrue(v["verified"])
        bad = K.verify_message("cardano", s["signature"], "tampered message")
        self.assertFalse(bad["verified"])

    def test_wrong_passphrase(self):
        wid = K.create_wallet("cardano", "pw test", PW)["wallet"]["id"]
        with self.assertRaises(K.KeystoreError):
            K.sign_message(wid, "x", "wrong passphrase!!")

    def test_ciphertext_bound_to_wallet_id(self):
        a = K.create_wallet("cardano", "a", PW)["wallet"]["id"]
        b = K.create_wallet("cardano", "b", PW)["wallet"]["id"]
        ra = json.loads((K.KEYSTORE_DIR / f"{a}.json").read_text())
        rb = json.loads((K.KEYSTORE_DIR / f"{b}.json").read_text())
        rb["secret"] = ra["secret"]
        (K.KEYSTORE_DIR / f"{b}.json").write_text(json.dumps(rb))
        with self.assertRaises(K.KeystoreError):
            K.unlock_secret(b, PW)

    def test_import_mnemonic_deterministic(self):
        m = K.create_wallet("cardano", "orig", PW)
        imp = K.import_wallet("cardano", "copy", "mnemonic", m["mnemonic"], PW)
        self.assertEqual(imp["wallet"]["addresses"]["base"], m["wallet"]["addresses"]["base"])

    def test_bad_mnemonic_rejected(self):
        with self.assertRaises(K.KeystoreError):
            K.import_wallet("cardano", "bad", "mnemonic", "abandon " * 23 + "zoo", PW)

    def test_evm_sign_verify(self):
        r = K.create_wallet("evm", "poly", PW, words=12)
        wid, addr = r["wallet"]["id"], r["wallet"]["addresses"]["primary"]
        s = K.sign_message(wid, "hello evm", PW)
        self.assertTrue(K.verify_message("evm", s["signature"], "hello evm", addr)["verified"])

    def test_short_passphrase(self):
        with self.assertRaises(K.KeystoreError):
            K.create_wallet("cardano", "weak", "short")

    def test_delete_moves_to_trash(self):
        wid = K.create_wallet("cardano", "trash me", PW)["wallet"]["id"]
        K.delete_wallet(wid, PW)
        self.assertFalse((K.KEYSTORE_DIR / f"{wid}.json").exists())
        self.assertTrue(any(K.TRASH_DIR.glob(f"{wid}.*.json")))


class TestPolicy(unittest.TestCase):
    def setUp(self):
        if P.AUDIT_FILE.exists():
            P.AUDIT_FILE.unlink()
    def test_operator_unrestricted(self):
        self.assertTrue(P.check("operator", "send", 10_000)["allowed"])

    def test_george_caps(self):
        self.assertTrue(P.check("george", "limit_buy", 10, "IAG")["allowed"])
        self.assertFalse(P.check("george", "limit_buy", 1000, "IAG")["allowed"])
        self.assertFalse(P.check("george", "send", 1, destination="addr1xyz")["allowed"])
        self.assertFalse(P.check("george", "limit_buy", 5, "SCAMCOIN")["allowed"])
        self.assertFalse(P.check("george", "limit_buy", 5, "IAG", wallet_id="cad-operator-abc123")["allowed"])

    def test_daily_cap_accumulates(self):
        for _ in range(3):
            P.record_spend("george", 700, "t")
        self.assertFalse(P.check("george", "limit_buy", 5, "IAG")["allowed"])

    def test_unknown_actor_denied(self):
        self.assertFalse(P.check("mallory", "limit_buy", 1, "IAG")["allowed"])

    def test_receive_info_qr_and_uri(self):
        r = K.create_wallet("cardano", "Recv Test", PW)
        wid = r["wallet"]["id"]
        info = K.receive_info(wid, chain="cardano", amount=25.5, token="ADA")
        self.assertEqual(info["status"], "ok")
        self.assertTrue(info["address"].startswith("addr1q"))
        self.assertIn("web+cardano:", info["uri"])
        self.assertIn("amount=25.5", info["uri"])
        self.assertIn("<svg", info["qr_svg"])
        self.assertTrue(len(info["qr_ansi"]) > 10)

    def test_evm_receive_info(self):
        r = K.create_wallet("evm", "EVM Recv", PW, words=12)
        wid = r["wallet"]["id"]
        info = K.receive_info(wid, chain="polygon", amount=10.0, token="USDC")
        self.assertEqual(info["status"], "ok")
        self.assertTrue(info["address"].startswith("0x"))
        self.assertIn("ethereum:", info["uri"])
        self.assertIn("@137", info["uri"])
        self.assertIn("<svg", info["qr_svg"])

    def test_agent_auto_unlock_keyfile(self):
        r = K.create_wallet("cardano", "Agent Sim", PW)
        wid = r["wallet"]["id"]
        rec = json.loads((K.KEYSTORE_DIR / f"{wid}.json").read_text())
        _, raw_secret = K.unlock_secret(wid, PW)
        rec["id"] = "agent-hot"
        rec["auto_unlock"] = True
        rec["secret"] = K._encrypt(raw_secret, PW, K._aad("agent-hot", "cardano"))
        (K.KEYSTORE_DIR / "agent-hot.json").write_text(json.dumps(rec))
        os.chmod(K.KEYSTORE_DIR / "agent-hot.json", 0o600)
        K.AGENT_KEYFILE.parent.mkdir(parents=True, exist_ok=True)
        K.AGENT_KEYFILE.write_text(PW + "\n")
        os.chmod(K.AGENT_KEYFILE, 0o600)
        _, unlocked_secret = K.unlock_secret("agent-hot", None)
        self.assertEqual(unlocked_secret, r["mnemonic"])


if __name__ == "__main__":
    unittest.main()
