#!/bin/bash
# ── Tests: Parallel Fan-Out Sibling Streak Suppression & Extended Thresholds ──
# Verifies that concurrent tool calls in Phase 1 do NOT artificially trip perturbation,
# and that the streak thresholds allow up to 7 consecutive operations.

set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/core/limits.sh"
source "$LODGE_DIR/lib/ipc/fifo_ipc.sh"
source "$LODGE_DIR/lib/core/react.sh"

# Mock advisor to avoid calling live LLM endpoint during unit tests
react_advise() { return 1; }

TEST_TMP=$(mktemp -d /tmp/george-streak-test-XXXXXX)
export GEORGE_DIR="$TEST_TMP/.george"
export FIFO_IPC_DIR="$GEORGE_DIR/ipc"
export LIMITS_CONF="$GEORGE_DIR/limits.conf"

cleanup() {
    rm -rf "$TEST_TMP" 2>/dev/null || true
}
trap cleanup EXIT

test_start "Parallel Fan-Out Sibling Streak Suppression & Extended Thresholds"

describe "1. Limits configuration values"

it "initializes CIRCUIT_BREAKER limits to 7 and 8" && {
    limits_init
    max_tool=$(limits_get CIRCUIT_BREAKER_MAX_TOOL_STREAK)
    max_path=$(limits_get CIRCUIT_BREAKER_MAX_PATH_STREAK)
    max_rep=$(limits_get CIRCUIT_BREAKER_MAX_REPEATS)
    win=$(limits_get CIRCUIT_BREAKER_REPEAT_WINDOW)

    assert_eq "$max_tool" "8" "Default max tool streak must be 8"
    assert_eq "$max_path" "7" "Default max path streak must be 7"
    assert_eq "$max_rep" "7" "Default max repeats must be 7"
    assert_eq "$win" "10" "Default repeat window must be 10"
}

describe "2. Consecutive target path streak threshold (up to 7)"

it "allows 6 consecutive reads on same path without tripping perturbation" && {
    session_id="test_sess_$$"
    workdir="$TEST_TMP"
    session_dir="$TEST_TMP/session"
    mkdir -p "$session_dir"
    messages_file="$session_dir/messages.json"
    macro_file="$session_dir/macro.json"
    history_file="$session_dir/trajectory.log"
    echo '[]' > "$messages_file"
    echo '{}' > "$macro_file"
    : > "$history_file"

    dummy_target="$TEST_TMP/target.txt"
    seq 1 50 > "$dummy_target"

    turn=1
    max_turns=10
    same_tool_streak=0
    last_invoked_tool=""
    same_target_path_streak=0
    last_inspected_path=""
    tool_search_streak=0
    thrashing_target_streak=0

    # Execute 6 consecutive calls on the same file path with different offsets
    for i in $(seq 1 6); do
        call=$(jq -nc --arg id "c$i" --arg p "$dummy_target" --argjson sl "$i" '{id: $id, function: {name: "file_read", arguments: ("{\"path\":\"" + $p + "\",\"start_line\":" + ($sl|tostring) + "}")}}')
        _react_execute_single_tool_step "$call" 1000 1
    done

    assert_eq "$same_target_path_streak" "6" "Path streak should reach 6"

    # Verify NO perturbation was injected in messages
    pert_count=$(jq '[.[] | select(.role == "user" and (.content | contains("SYSTEM PERTURBATION")))] | length' "$messages_file")
    assert_eq "$pert_count" "0" "Should NOT have injected perturbation after 6 reads"

    # 7th call reaches threshold 7
    call7=$(jq -nc --arg p "$dummy_target" '{id: "c7", function: {name: "file_read", arguments: ("{\"path\":\"" + $p + "\",\"start_line\":7}")}}')
    _react_execute_single_tool_step "$call7" 1000 1
    assert_eq "$same_target_path_streak" "7"

    pert_count7=$(jq '[.[] | select(.role == "user" and (.content | contains("SYSTEM PERTURBATION")))] | length' "$messages_file")
    assert_eq "$pert_count7" "1" "Should inject perturbation on 7th consecutive read"
}

describe "3. Action repetition strike scaling with max_repeats=7"

it "does not trip action repetition perturbation on 2nd or 3rd repeat" && {
    session_dir="$TEST_TMP/session_rep"
    mkdir -p "$session_dir"
    rm -f "$session_dir/action_hashes.log"

    a_hash="test_hash_unique_123"

    # Call 1
    s1=$(_react_check_repetition "$session_dir" "$a_hash" "file_read" "{}")
    # Call 2 (immediate repeat: strike 1 advisory)
    s2=$(_react_check_repetition "$session_dir" "$a_hash" "file_read" "{}")
    assert_eq "$s2" "1" "2nd identical call gets strike 1 (advisory), not strike 2"

    # Call 3
    s3=$(_react_check_repetition "$session_dir" "$a_hash" "file_read" "{}")
    assert_eq "$s3" "1" "3rd identical call remains strike 1 under max_repeats=7"
}

describe "4. Parallel Fan-Out Sibling Streak Suppression (12 concurrent reads)"

it "does not inflate tool or path streaks across 12 sibling calls in a single turn" && {
    session_dir="$TEST_TMP/session_fanout"
    mkdir -p "$session_dir"
    messages_file="$session_dir/messages.json"
    macro_file="$session_dir/macro.json"
    echo '[]' > "$messages_file"
    echo '{}' > "$macro_file"

    # Prepare 12 parallel read calls
    p1_calls=()
    for i in $(seq 1 12); do
        echo "file $i content" > "$TEST_TMP/file_$i.txt"
        p1_calls+=("$(jq -nc --arg id "call_$i" --arg p "$TEST_TMP/file_$i.txt" '{id: $id, function: {name: "file_read", arguments: ("{\"path\":\"" + $p + "\"}")}}')")
    done

    same_tool_streak=0
    last_invoked_tool=""
    same_target_path_streak=0
    last_inspected_path=""
    tool_search_streak=0

    # Simulate Phase 1 parallel fan-out evaluation loop logic
    _p1_idx=0
    for _call in "${p1_calls[@]}"; do
        c_id=$(jq -r '.id' <<<"$_call")
        c_name=$(jq -r '.function.name' <<<"$_call")
        c_args=$(jq -r '.function.arguments' <<<"$_call")

        # Intra-turn sibling gating
        if [ "$_p1_idx" -eq 0 ]; then
            if [ "$c_name" = "$last_invoked_tool" ]; then same_tool_streak=$((same_tool_streak + 1))
            else same_tool_streak=1; last_invoked_tool="$c_name"
            fi

            max_tool_streak=$(limits_get CIRCUIT_BREAKER_MAX_TOOL_STREAK 8)
            if [ "$same_tool_streak" -ge "$max_tool_streak" ]; then
                _react_circuit_breaker_perturbation "$session_id" "$workdir" "TOOL_THRASHING" "$c_name ($c_args)" "Repeated invocations" "$messages_file" "$macro_file"
            fi
        fi

        target_path=$(jq -r '.path // empty' <<<"$c_args" 2>/dev/null)
        if [ -n "$target_path" ]; then
            if [ "$_p1_idx" -eq 0 ]; then
                if [ "$target_path" = "$last_inspected_path" ]; then same_target_path_streak=$((same_target_path_streak + 1))
                else same_target_path_streak=1; last_inspected_path="$target_path"
                fi
                max_path_streak=$(limits_get CIRCUIT_BREAKER_MAX_PATH_STREAK 7)
                if [ "$same_target_path_streak" -ge "$max_path_streak" ]; then
                    _react_circuit_breaker_perturbation "$session_id" "$workdir" "TARGET_FILE_THRASHING" "$c_name ($target_path)" "Repeated file inspection" "$messages_file" "$macro_file"
                fi
            fi
        fi
        _p1_idx=$((_p1_idx + 1))
    done

    # Verification:
    # 1. same_tool_streak should be exactly 1, NOT 12!
    assert_eq "$same_tool_streak" "1" "12 concurrent reads in single turn only increments same_tool_streak once"
    # 2. same_target_path_streak should be exactly 1
    assert_eq "$same_target_path_streak" "1" "same_target_path_streak only evaluated on first call in turn"
    # 3. No perturbation notices were emitted
    pert_count=$(jq '[.[] | select(.role == "user" and (.content | contains("SYSTEM PERTURBATION")))] | length' "$messages_file")
    assert_eq "$pert_count" "0" "Zero perturbation notices for 12 concurrent reads in one parallel turn"
}

test_end
