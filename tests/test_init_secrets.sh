#!/usr/bin/env bash
# Tests: scripts/infra/init_secrets.sh — first-run secret generation (never overwrites, 0600, idempotent)
source "$(dirname "$0")/framework.sh"
test_start "init_secrets"

S="$GEORGE_TEST_SANDBOX/initsec"; mkdir -p "$S/repo/configs" "$S/repo/.george"
cp "$LODGE_DIR/configs/secrets.env.example" "$S/repo/configs/secrets.env.example"
INIT() { LODGE_DIR="$S/repo" bash "$LODGE_DIR/scripts/infra/init_secrets.sh" "$@"; }

describe "fresh install writes .env, .george/secrets.env, and .george/secrets/agent_keystore.key with private permissions"
out=$(INIT 2>&1)
assert_file_exists "$S/repo/.env"
assert_eq "$(stat -c %a "$S/repo/.env")" "600" ".env is 0600"
assert_eq "$(stat -c %a "$S/repo/.george/secrets.env")" "600" "secrets.env is 0600"
assert_eq "$(stat -c %a "$S/repo/.george/secrets/agent_keystore.key")" "600" "agent_keystore.key is 0600"
sec=$(grep -E '^SEARXNG_SECRET=' "$S/repo/.env" | cut -d= -f2)
assert_eq "$(printf '%s' "$sec" | grep -cE '^[0-9a-f]{64}$')" "1" "SEARXNG_SECRET is 64 random hex chars"
assert_contains "$(cat "$S/repo/.env")" "BIND_ADDR=127.0.0.1" "services bind to localhost by default"
assert_not_contains "$out" "$sec" "secret is never printed"

describe "idempotent: re-running keeps existing secrets"
INIT >/dev/null 2>&1
assert_eq "$(grep -E '^SEARXNG_SECRET=' "$S/repo/.env" | cut -d= -f2)" "$sec" "secret unchanged on re-run"
assert_eq "$(grep -c '^SEARXNG_SECRET=' "$S/repo/.env")" "1" "no duplicate keys"

describe "existing operator .env is preserved; only missing keys are appended"
printf 'BIND_ADDR=0.0.0.0\nMY_SETTING=keep\n' > "$S/repo/.env"; chmod 644 "$S/repo/.env"
echo 'CUSTOM=1' > "$S/repo/.george/secrets.env"
INIT >/dev/null 2>&1
assert_contains "$(cat "$S/repo/.env")" "BIND_ADDR=0.0.0.0" "operator BIND_ADDR kept"
assert_contains "$(cat "$S/repo/.env")" "MY_SETTING=keep" "operator setting kept"
assert_eq "$(grep -c '^SEARXNG_SECRET=' "$S/repo/.env")" "1" "missing secret appended"
assert_eq "$(stat -c %a "$S/repo/.env")" "600" "permissions tightened"
assert_eq "$(cat "$S/repo/.george/secrets.env")" "CUSTOM=1" "existing secrets.env untouched"

test_end
