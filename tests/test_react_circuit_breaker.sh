#!/bin/bash
# ── Tests for lib/react.sh Circuit Breaker & Repetition Detection ─────

source "$(dirname "$0")/framework.sh"
source "$(dirname "$0")/../lib/react.sh"
source "$(dirname "$0")/../lib/limits.sh"

test_start "lib/react.sh — ReAct Circuit Breaker & Repetition Detection"

describe "_react_action_hash"
  it "produces identical hash for json arguments with different key order" && {
    h1=$(_react_action_hash "file_read" '{"path":"foo.txt","offset":10}')
    h2=$(_react_action_hash "file_read" '{"offset":10,"path":"foo.txt"}')
    assert_eq "$h1" "$h2"
  }

  it "produces identical hash for text commands with different whitespace" && {
    h1=$(_react_action_hash "fallback_cmd" "  /view    foo.txt   ")
    h2=$(_react_action_hash "fallback_cmd" "/view foo.txt")
    assert_eq "$h1" "$h2"
  }

  it "produces different hashes for different actions or arguments" && {
    h1=$(_react_action_hash "file_read" '{"path":"foo.txt"}')
    h2=$(_react_action_hash "file_read" '{"path":"bar.txt"}')
    [ "$h1" != "$h2" ]
  }

describe "_react_check_repetition"
  it "returns 0 for initial novel action" && {
    tmp_sess=$(mktemp -d)
    h=$(_react_action_hash "file_read" '{"path":"a.txt"}')
    strike=$(_react_check_repetition "$tmp_sess" "$h" "file_read")
    rm -rf "$tmp_sess"
    assert_eq "$strike" "0"
  }

  it "returns 1 (Strike 1) for immediate identical repeat" && {
    tmp_sess=$(mktemp -d)
    h=$(_react_action_hash "file_read" '{"path":"a.txt"}')
    _react_check_repetition "$tmp_sess" "$h" "file_read" >/dev/null
    strike=$(_react_check_repetition "$tmp_sess" "$h" "file_read")
    rm -rf "$tmp_sess"
    assert_eq "$strike" "1"
  }

  it "returns 2 (Strike 2) for oscillating loop A -> B -> A -> B" && {
    tmp_sess=$(mktemp -d)
    ha=$(_react_action_hash "tool_a" '{}')
    hb=$(_react_action_hash "tool_b" '{}')
    _react_check_repetition "$tmp_sess" "$ha" "tool_a" >/dev/null # A (0)
    _react_check_repetition "$tmp_sess" "$hb" "tool_b" >/dev/null # B (0)
    _react_check_repetition "$tmp_sess" "$ha" "tool_a" >/dev/null # A (1)
    strike=$(_react_check_repetition "$tmp_sess" "$hb" "tool_b")   # B -> Strike 2 (oscillation)
    rm -rf "$tmp_sess"
    assert_eq "$strike" "2"
  }

  it "returns 3 (Strike 3) when repeats reach max threshold" && {
    tmp_sess=$(mktemp -d)
    h=$(_react_action_hash "web_search" '{"query":"linux kernel"}')
    _react_check_repetition "$tmp_sess" "$h" "web_search" >/dev/null # 1st occurrence (0)
    _react_check_repetition "$tmp_sess" "$h" "web_search" >/dev/null # 2nd occurrence (1)
    strike=$(_react_check_repetition "$tmp_sess" "$h" "web_search")   # 3rd occurrence (3)
    rm -rf "$tmp_sess"
    assert_eq "$strike" "3"
  }

describe "_react_trip_circuit_breaker"
  it "writes alert artifact and updates macro status" && {
    tmp_sess_dir=$(mktemp -d)
    tmp_workdir=$(mktemp -d)
    macro_file="$tmp_sess_dir/macro_memory.json"
    messages_file="$tmp_sess_dir/messages.json"
    echo '{"status": "RUNNING"}' > "$macro_file"
    echo '[]' > "$messages_file"

    sess_id="test_breaker_$$"
    export LODGE_DIR="$tmp_sess_dir"

    _react_trip_circuit_breaker "$sess_id" "$tmp_workdir" "Test Breaker Reason" "tool_x({})" "$messages_file" "$macro_file" "Simulated failure"

    # Verify macro memory status updated
    st=$(jq -r '.status' "$macro_file")
    assert_eq "$st" "CIRCUIT_BREAKER_TRIPPED"

    # Verify alert JSON written
    alert_path="$LODGE_DIR/.george/alerts/alert_${sess_id}.json"
    [ -f "$alert_path" ]
    assert_eq "$(jq -r '.status' "$alert_path")" "CIRCUIT_BREAKER_TRIPPED"
    assert_eq "$(jq -r '.reason' "$alert_path")" "Test Breaker Reason"

    rm -rf "$tmp_sess_dir" "$tmp_workdir"
  }

  it "preserves dirty workspace on quarantine git branch" && {
    tmp_git=$(mktemp -d)
    git -C "$tmp_git" init >/dev/null 2>&1
    git -C "$tmp_git" config user.email "test@example.com"
    git -C "$tmp_git" config user.name "Test Runner"
    echo "initial" > "$tmp_git/file.txt"
    git -C "$tmp_git" add file.txt
    git -C "$tmp_git" commit -m "init" >/dev/null 2>&1

    # Make workspace dirty
    echo "dirty edit" >> "$tmp_git/file.txt"

    tmp_sess_dir=$(mktemp -d)
    macro_file="$tmp_sess_dir/macro_memory.json"
    messages_file="$tmp_sess_dir/messages.json"
    echo '{"status": "RUNNING"}' > "$macro_file"
    echo '[]' > "$messages_file"

    sess_id="qtest_$$"
    export LODGE_DIR="$tmp_sess_dir"

    _react_trip_circuit_breaker "$sess_id" "$tmp_git" "Dirty Crash" "file_write(file.txt)" "$messages_file" "$macro_file" "Error"

    # Check quarantine branch exists in git repo
    q_exists=$(git -C "$tmp_git" branch --list "quarantine/${sess_id}")
    [ -n "$q_exists" ]

    rm -rf "$tmp_git" "$tmp_sess_dir"
  }

test_end
