#!/usr/bin/env bash
# ── Tests: Sovereign Hot Wallet Compliance, OWASP scrypt, Reserve Floor & Liquid ADA Staking ──
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"
PY="${LODGE_DIR}/.venv/bin/python"
[ -x "$PY" ] || PY="python3"

PASS=0; FAIL=0
assert_ok() {
    local desc="$1"; shift
    if "$@"; then
        echo "  [PASS] $desc"; PASS=$((PASS+1))
    else
        echo "  [FAIL] $desc"; FAIL=$((FAIL+1))
    fi
}

echo "=== Blue Lodge Hot Wallet Compliance & Liquid Native ADA Staking Tests ==="

TMP_G="$(mktemp -d /tmp/lodge-wallet-test-XXXXXX)"
trap 'rm -rf "$TMP_G"' EXIT

assert_ok "CIP-1852 wallet creation derives stakeable base + stake1... address with OWASP scrypt N=2^17" \
    env GEORGE_DIR="$TMP_G" LODGE_DIR="$LODGE_DIR" "$PY" - <<'PY'
import json, os, stat
from pathlib import Path
from lib.tools.wallet import keystore as ks

res = ks.create_wallet("cardano", "staking-test", "strong-test-passphrase-123!", words=24)
assert res["status"] == "ok", res
w = res["wallet"]
addrs = w["addresses"]
assert addrs["primary"].startswith("addr1"), addrs
assert addrs["base"] == addrs["primary"], addrs
assert addrs["stake"] and addrs["stake"].startswith("stake1"), addrs
assert len(res["mnemonic"].split()) == 24

kp = Path(os.environ["GEORGE_DIR"]) / "wallets" / "keystore" / f"{w['id']}.json"
assert (kp.stat().st_mode & 0o777) == 0o600
raw = json.loads(kp.read_text())
assert raw["secret"]["n"] == 2 ** 17, raw["secret"]
assert raw["secret"]["cipher"] == "aes-256-gcm"

# Verify decrypt works & backward-compat N=2^15 decrypt still works
rec, sec = ks.unlock_secret(w["id"], "strong-test-passphrase-123!")
assert sec == res["mnemonic"]
PY

assert_ok "Keystore refuses to unlock files with insecure group/world permissions (!= 0600)" \
    env GEORGE_DIR="$TMP_G" LODGE_DIR="$LODGE_DIR" "$PY" - <<'PY'
import os
from pathlib import Path
from lib.tools.wallet import keystore as ks

res = ks.create_wallet("cardano", "perm-test", "strong-test-passphrase-123!", words=24)
wid = res["wallet"]["id"]
kp = Path(os.environ["GEORGE_DIR"]) / "wallets" / "keystore" / f"{wid}.json"
os.chmod(kp, 0o644)
try:
    ks.unlock_secret(wid, "strong-test-passphrase-123!")
    raise AssertionError("expected KeystoreError on 0644 permissions")
except ks.KeystoreError as e:
    assert "insecure permissions" in str(e)
os.chmod(kp, 0o600)
aud = ks.wallet_hygiene_audit()
assert aud["status"] == "ok" and aud["compliant"] is True, aud
PY

assert_ok "Wallet spending policy enforces reserve_floor_ada and blocks autonomous staking actions" \
    env GEORGE_DIR="$TMP_G" LODGE_DIR="$LODGE_DIR" "$PY" - <<'PY'
from lib.tools.wallet import policy

r1 = policy.check("george", "stake_delegate", wallet_id="agent-hot")
assert r1["allowed"] is False and "operator-only" in r1["reason"], r1

r2 = policy.check("george", "stake_withdraw", wallet_id="agent-hot")
assert r2["allowed"] is False and "operator-only" in r2["reason"], r2

r3 = policy.check("george", "limit_buy", ada_out=95.0, asset="NIGHT", wallet_id="agent-hot", current_ada_balance=100.0)
assert r3["allowed"] is False and "reserve floor" in r3["reason"], r3

r4 = policy.check("george", "limit_buy", ada_out=50.0, asset="NIGHT", wallet_id="agent-hot", current_ada_balance=100.0)
assert r4["allowed"] is True, r4
PY

assert_ok "cardano_stake_status reports stakeable=True for CIP-1852 wallet and stakeable=False for enterprise key" \
    env GEORGE_DIR="$TMP_G" LODGE_DIR="$LODGE_DIR" "$PY" - <<'PY'
from pycardano import PaymentSigningKey
from lib.tools.wallet import keystore as ks

w_hd = ks.create_wallet("cardano", "hd-stake", "strong-test-passphrase-123!", words=24)["wallet"]
st_hd = ks.cardano_stake_status(w_hd["id"])
assert st_hd["status"] == "ok" and st_hd["stakeable"] is True and st_hd["stake_address"].startswith("stake1"), st_hd

sk = PaymentSigningKey.generate()
w_ent = ks.import_wallet("cardano", "ent-legacy", "cardano_skey_cbor", sk.to_cbor_hex(), "strong-test-passphrase-123!")["wallet"]
st_ent = ks.cardano_stake_status(w_ent["id"])
assert st_ent["status"] == "ok" and st_ent["stakeable"] is False, st_ent

# Verify autonomous actor denied before chain call
den = ks.cardano_delegate_stake(w_hd["id"], "pool1qqqqq2qr4203dcq9me2gnacdmknxljkxa4743lge7w489329446", "strong-test-passphrase-123!", actor="george")
assert den["status"] == "denied", den
PY

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
