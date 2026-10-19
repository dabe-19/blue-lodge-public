#!/bin/bash
# ── Tests: Entity Judgment & Reputation Ledger ───────────────────────

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agents/reputation.sh" 2>/dev/null || true

TEST_TMP=$(mktemp -d /tmp/george-reputation-test-XXXXXX)
export GEORGE_CONFIG_DIR="$TEST_TMP/.george"
export GEORGE_DIR="$GEORGE_CONFIG_DIR"
export REPUTATION_DB="$GEORGE_DIR/reputation.db"

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

test_start "George Entity Judgment Ledger & Reputation Engine"

describe "reputation_init"

it "creates sqlite database and schema cleanly" && {
    reputation_init
    assert_file_exists "$REPUTATION_DB"
    tables=$(sqlite3 "$REPUTATION_DB" ".tables")
    assert_contains "$tables" "reputation"
}

describe "reputation_get and default tier"

it "initializes unknown user with 10 points and Stranger tier" && {
    data=$(reputation_get "user_101" "Alice")
    assert_eq "$data" "10|Stranger"
}

describe "reputation_add and tier progression"

it "increments score and promotes to Brother at 25 points" && {
    reputation_add "user_101" 15 "valid_bug_report" "Alice"
    data=$(reputation_get "user_101" "Alice")
    assert_eq "$data" "25|Brother"
}

it "promotes to Master Mason at 50 points" && {
    reputation_add "user_101" 25 "approved_pr" "Alice"
    data=$(reputation_get "user_101" "Alice")
    assert_eq "$data" "50|Master Mason"
}

it "demotes to Cowan when score drops below 0" && {
    reputation_add "user_bad" -15 "jailbreak_attempt" "Eve"
    data=$(reputation_get "user_bad" "Eve")
    score=$(echo "$data" | cut -d'|' -f1)
    tier=$(echo "$data" | cut -d'|' -f2)
    assert_eq "$tier" "Cowan"
}

describe "reputation_format_status"

it "formats Masonic judgment report with score and unlocked features" && {
    status_str=$(reputation_format_status "user_101" "Alice")
    assert_contains "$status_str" "George's Judgment Ledger"
    assert_contains "$status_str" "50 points"
    assert_contains "$status_str" "Master Mason"
    assert_contains "$status_str" "Elevated agency"
}

describe "reputation SQL safety (injection hardening)"

it "does not let a crafted username self-promote to Master Mason" && {
    evil="x', 'discord', 999, 'Master Mason', 0, 0); --"
    reputation_get "998877665544" "$evil" >/dev/null
    data=$(reputation_get "998877665544" "whatever")
    assert_eq "$data" "10|Stranger"
}

it "stores usernames containing apostrophes verbatim" && {
    reputation_get "123456789012" "O'Brien" >/dev/null
    stored=$(sqlite3 "$REPUTATION_DB" "SELECT username FROM reputation WHERE user_id = '123456789012';")
    assert_eq "$stored" "O'Brien"
}

it "rejects user_ids containing quotes or SQL metacharacters" && {
    reputation_get "1' OR '1'='1" "Mallory" >/dev/null 2>&1
    rc=$?
    assert_eq "$rc" "1"
    cnt=$(sqlite3 "$REPUTATION_DB" "SELECT count(*) FROM reputation WHERE username = 'Mallory';")
    assert_eq "$cnt" "0"
}

it "rejects non-integer score deltas" && {
    reputation_add "user_101" "5; DROP TABLE reputation" "x" "Alice" >/dev/null 2>&1
    rc=$?
    assert_eq "$rc" "1"
    data=$(reputation_get "user_101" "Alice")
    assert_eq "$data" "50|Master Mason"
}

test_end
