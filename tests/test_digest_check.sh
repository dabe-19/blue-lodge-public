#!/bin/bash
# ── Tests for lib/tools/digest_check.sh (remediation 80cfc3d933bb) ──
# Deterministic character-cap validator & trimmer for outbound digests.

source "$(dirname "$0")/framework.sh"

DIGEST_CHECK="$GEORGE_TEST_REPO/lib/tools/digest_check.sh"

TMP_DIR=$(mktemp -d /tmp/digest-check-test-XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

test_start "digest_check.sh (char-cap validator & trimmer)"

describe "validate mode"
  it "reports OK with exit 0 when under cap" && {
    printf 'line1
line2
line3
' > "$TMP_DIR/d1.txt"
    out=$(bash "$DIGEST_CHECK" validate "$TMP_DIR/d1.txt" 100)
    assert_ok $?
    assert_contains "$out" "OK 17/100"
  }

  it "reports OVER with exit 1 when over cap" && {
    printf 'line1
line2
line3
' > "$TMP_DIR/d2.txt"
    out=$(bash "$DIGEST_CHECK" validate "$TMP_DIR/d2.txt" 10 2>&1)
    assert_fail $?
    assert_contains "$out" "OVER"
  }

  it "accepts stdin via dash file argument" && {
    out=$(printf 'x
' | bash "$DIGEST_CHECK" validate - 5)
    assert_ok $?
    assert_contains "$out" "OK 1/5"
  }

describe "count mode"
  it "prints '<chars> <cap>' machine-readable" && {
    printf 'line1
line2
line3
' > "$TMP_DIR/d3.txt"
    out=$(bash "$DIGEST_CHECK" count "$TMP_DIR/d3.txt" 100)
    assert_ok $?
    assert_eq "$out" "17 100"
  }

  it "counts UTF-8 characters, not bytes" && {
    printf '⚔️ Hourly Digest
[AI] summary here
' > "$TMP_DIR/d4.txt"
    out=$(bash "$DIGEST_CHECK" count "$TMP_DIR/d4.txt" 100)
    assert_eq "$out" "34 100"
  }

describe "trim mode"
  it "drops whole trailing lines until under cap, rewriting in place" && {
    printf 'alpha
be very very long line here
gamma
' > "$TMP_DIR/d5.txt"
    bash "$DIGEST_CHECK" trim "$TMP_DIR/d5.txt" 25 2>/dev/null
    assert_ok $?
    content=$(cat "$TMP_DIR/d5.txt")
    assert_contains "$content" "alpha"
    assert_not_contains "$content" "be very very"
  }

  it "refuses to empty the digest when the first line alone exceeds cap (exit 2)" && {
    printf 'one very long first line that exceeds cap
second
' > "$TMP_DIR/d6.txt"
    out=$(bash "$DIGEST_CHECK" trim "$TMP_DIR/d6.txt" 20 2>&1)
    assert_fail $?
    assert_contains "$out" "UNTRIMMABLE"
  }

  it "prints trimmed content to stdout with dash file" && {
    printf 'alpha
gamma
delta
' | bash "$DIGEST_CHECK" trim - 12 2>/dev/null > "$TMP_DIR/d7.txt"
    assert_ok $?
    content=$(cat "$TMP_DIR/d7.txt")
    assert_contains "$content" "alpha"
    assert_not_contains "$content" "delta"
  }

describe "usage errors"
  it "exits 3 on unknown mode" && {
    rc=0
    bash "$DIGEST_CHECK" explode 2>/dev/null || rc=$?
    assert_eq "$rc" "3"
  }

  it "exits 3 on non-numeric cap" && {
    rc=0
    bash "$DIGEST_CHECK" validate - abc 2>/dev/null || rc=$?
    assert_eq "$rc" "3"
  }

  it "exits 3 when the input file is missing" && {
    rc=0
    bash "$DIGEST_CHECK" validate "$TMP_DIR/missing.txt" 100 2>/dev/null || rc=$?
    assert_eq "$rc" "3"
  }

describe "architectural purity"
  it "uses no Python or Node in the helper itself" && {
    assert_not_contains "$(cat "$DIGEST_CHECK")" "python3"
    assert_not_contains "$(cat "$DIGEST_CHECK")" "node "
  }

test_end
