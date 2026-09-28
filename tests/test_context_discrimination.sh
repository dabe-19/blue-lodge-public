#!/usr/bin/env bash
# tests/test_context_discrimination.sh:
# Verifies context discrimination, request hashing, pseudo-LRU tracking,
# and Honeydew DAG milestone isolation.

set -euo pipefail

LODGE_DIR="/home/wsl-ops/blue-lodge"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/cache.sh"
source "$LODGE_DIR/lib/discord_bridge.sh"
source "$LODGE_DIR/lib/react.sh"

TEST_PASSED=0
TEST_FAILED=0

assert_contains() {
    local text="$1"
    local pattern="$2"
    local msg="${3:-Assertion failed}"
    if echo "$text" | grep -qE "$pattern"; then
        TEST_PASSED=$((TEST_PASSED + 1))
        ui_ok "PASS: $pattern found"
    else
        TEST_FAILED=$((TEST_FAILED + 1))
        ui_err "FAIL: $msg (pattern '$pattern' not found in output)"
    fi
}

assert_not_contains() {
    local text="$1"
    local pattern="$2"
    local msg="${3:-Assertion failed}"
    if echo "$text" | grep -qE "$pattern"; then
        TEST_FAILED=$((TEST_FAILED + 1))
        ui_err "FAIL: $msg (pattern '$pattern' unexpectedly found)"
    else
        TEST_PASSED=$((TEST_PASSED + 1))
        ui_ok "PASS: pattern '$pattern' correctly absent"
    fi
}

echo "=== Test 1: Inbound Request Hashing & Cache Hit Identification ==="
cache_init
req_text="Can you summarize the past week in the NFL and find me some good memes about it?"
cache_record_inbound_request "$req_text" "dabe" "chan_123" "completed" "NFL and memes summarized"

if cache_is_prior_request "$req_text"; then
    ui_ok "PASS: cache_is_prior_request hit on recorded request"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    ui_err "FAIL: cache_is_prior_request missed recorded request"
    TEST_FAILED=$((TEST_FAILED + 1))
fi

if ! cache_is_prior_request "Completely unseen brand new prompt for testing"; then
    ui_ok "PASS: cache_is_prior_request correctly returned false on unseen request"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    ui_err "FAIL: cache_is_prior_request falsely hit on unseen request"
    TEST_FAILED=$((TEST_FAILED + 1))
fi

echo ""
echo "=== Test 2: Discord History Formatting with Completed Request Labels ==="
tmp_hdir=$(mktemp -d)
DISCORD_HISTORY_DIR="$tmp_hdir"
discord_history_append "chan_test" "user" "dabe" "$req_text" "user_1"
discord_history_append "chan_test" "assistant" "George" "Here are the top NFL highlights and memes." "user_1"

hist_output=$(discord_history_get "chan_test" 4 "user_1")
assert_contains "$hist_output" "HISTORICAL COMPLETED PRIOR REQUEST" "Expected historical label on past turn"
assert_contains "$hist_output" "DO NOT RE-EXECUTE" "Expected do-not-reexecute label"
assert_contains "$hist_output" "HISTORICAL RESPONSE FROM GEORGE" "Expected historical response label"

echo ""
echo "=== Test 3: Honeydew Task Extraction Isolates Clean Active Objective ==="
compound_goal="[Recent Conversation & Task History (Reference Only)]:
[HISTORICAL COMPLETED PRIOR REQUEST #a8f3b129 (DO NOT RE-EXECUTE)]:
@dabe_: Can you make a weekly cron for meme report?
[HISTORICAL RESPONSE FROM GEORGE]:
George: Created .george/cron_jobs/meme_report.sh

============================================================
[ACTIVE PRIMARY OBJECTIVE - EXECUTE THIS NOW]:
[Current Inbound Message from @dabe_]:
please execute the live test run.
============================================================"

# Test Honeydew DAG clean task extraction
tmp_work=$(mktemp -d)
mkdir -p "$tmp_work/.george"
_react_ensure_honeydew_plan "$compound_goal" "$tmp_work" 1
saved_task=$(jq -r '.primary_task' "$tmp_work/.george/honeydew.json")
first_step=$(jq -r '.items[0].task' "$tmp_work/.george/honeydew.json")

assert_contains "$saved_task" "please execute the live test run" "Expected clean active objective extracted"
assert_not_contains "$saved_task" "weather" "Extracted task should not contain weather"
assert_not_contains "$first_step" "weather" "Milestone step 1 should not contain weather"
assert_contains "$first_step" "(Locate target script|test|execute|run)" "Step 1 should be test execution related"

echo ""
echo "=== Test Summary ==="
echo "Passed: $TEST_PASSED | Failed: $TEST_FAILED"
rm -rf "$tmp_hdir" "$tmp_work"
[ "$TEST_FAILED" -eq 0 ]
