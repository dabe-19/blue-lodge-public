#!/usr/bin/env bash
# Run ledger + outcome taxonomy (refinement P1/1.7)
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"
LODGE_DIR="$GEORGE_TEST_REPO"; export LODGE_DIR
unset _LIB_RUN_LEDGER_LOADED
source "$LODGE_DIR/lib/core/run_ledger.sh"

test_start "run_ledger"

assert_fn_defined run_ledger_start
assert_fn_defined run_ledger_finish
assert_fn_defined run_ledger_label
assert_fn_defined run_ledger_infer_outcome

RUNS="$GEORGE_DIR/runs"

describe "start"
run_ledger_start "session_t1" "What is 2+2?" "discord" "1" "qwen-27b" "/tmp/ws"
f="$RUNS/session_t1/run.json"
assert_file_exists "$f"
assert_eq "$(jq -r '.session_id' "$f")" "session_t1"
assert_eq "$(jq -r '.goal' "$f")" "What is 2+2?"
assert_eq "$(jq -r '.type' "$f")" "discord"
assert_eq "$(jq -r '.status' "$f")" "RUNNING"
assert_eq "$(jq -r '.model' "$f")" "qwen-27b"
assert_match "$(jq -r '.started_epoch' "$f")" '^[0-9]+$'

describe "session id validation"
run_ledger_start "../evil" "x" "react" >/dev/null 2>&1
assert_eq "$?" "1" "path traversal ids rejected"
assert_file_not_exists "$GEORGE_DIR/evil/run.json"

describe "finish SUCCESS copies final reply + trajectory"
WS="$GEORGE_TEST_SANDBOX/ws_t1"; mkdir -p "$WS"
echo '[{"role":"user","content":"What is 2+2?"},{"role":"assistant","content":"4"}]' > "$WS/messages.json"
jq --arg w "$WS" '.workspace=$w' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
reply="$GEORGE_TEST_SANDBOX/final_reply.txt"; printf 'The answer is 4.\n' > "$reply"
run_ledger_finish "session_t1" SUCCESS "" "$reply" 3 5 1 0
assert_eq "$(jq -r '.outcome' "$f")" "SUCCESS"
assert_eq "$(jq -r '.status' "$f")" "FINISHED"
assert_eq "$(jq -r '.turns' "$f")" "3"
assert_eq "$(jq -r '.tool_calls' "$f")" "5"
assert_eq "$(jq -r '.tool_fails' "$f")" "1"
assert_eq "$(jq -r '.breaker_trips' "$f")" "0"
assert_match "$(jq -r '.wall_s' "$f")" '^[0-9]+$'
assert_file_exists "$RUNS/session_t1/final_reply.md"
assert_eq "$(cat "$RUNS/session_t1/final_reply.md")" "The answer is 4."
assert_eq "$(jq -r '.final_reply' "$f")" "$RUNS/session_t1/final_reply.md"
assert_eq "$(jq -r '.[1].content' "$RUNS/session_t1/messages.json")" "4" "trajectory preserved"

describe "finish is idempotent (first outcome wins)"
run_ledger_finish "session_t1" ABORTED "late cleanup"
assert_eq "$(jq -r '.outcome' "$f")" "SUCCESS"

describe "invalid outcome rejected"
run_ledger_start "session_t2" "goal" "react"
run_ledger_finish "session_t2" BOGUS >/dev/null 2>&1
assert_eq "$?" "2" "unknown outcome returns 2"
assert_eq "$(jq -r '.status' "$RUNS/session_t2/run.json")" "RUNNING"

describe "finish without start still records"
run_ledger_finish "session_t3" TIMEOUT "harness timeout"
assert_eq "$(jq -r '.outcome' "$RUNS/session_t3/run.json")" "TIMEOUT"
assert_eq "$(jq -r '.reason' "$RUNS/session_t3/run.json")" "harness timeout"
assert_file_not_exists "$RUNS/session_t3/final_reply.md"

describe "agent.run_complete emitted"
_emitted=""
event_bus_emit() { _emitted="$1|$2"; }
run_ledger_start "session_t4" "g" "cron"
RUN_LEDGER_EMIT_SYNC=1 run_ledger_finish "session_t4" STALL "empty turns" "" 7
assert_contains "$_emitted" "agent.run_complete|"
assert_eq "$(printf '%s' "${_emitted#*|}" | jq -r '.outcome')" "STALL"
assert_eq "$(printf '%s' "${_emitted#*|}" | jq -r '.turns')" "7"
assert_eq "$(printf '%s' "${_emitted#*|}" | jq -r '.session_id')" "session_t4"
assert_match "$(printf '%s' "${_emitted#*|}" | jq -r '.wall_s')" '^[0-9]+$'
unset -f event_bus_emit

describe "outcome inference"
assert_eq "$(run_ledger_infer_outcome 0 COMPLETED yes)" "SUCCESS"
assert_eq "$(run_ledger_infer_outcome 1 CIRCUIT_BREAKER_TRIPPED no)" "LOOP"
assert_eq "$(run_ledger_infer_outcome 1 CAPABILITY_EXHAUSTED no)" "TOOL_FAIL"
assert_eq "$(run_ledger_infer_outcome 0 TURN_CEILING_PRESERVED no)" "MAX_TURNS"
assert_eq "$(run_ledger_infer_outcome 130 IN_PROGRESS no)" "ABORTED"
assert_eq "$(run_ledger_infer_outcome 0 IN_PROGRESS yes)" "SUCCESS"
assert_eq "$(run_ledger_infer_outcome 1 IN_PROGRESS no)" "ABORTED"
assert_eq "$(run_ledger_classify_breaker 'Persistent tool failure on web_fetch reached strike ceiling')" "TOOL_FAIL"
assert_eq "$(run_ledger_classify_breaker 'Action repetition ceiling reached (web_search)')" "LOOP"

describe "labels (reactions / rate)"
run_ledger_label "session_t1" "good" "discord_reaction" "user_42"
run_ledger_label "session_t1" "bad" "rate" "user_7" "wrong year"
assert_eq "$(jq -r '.labels | length' "$f")" "2"
assert_eq "$(jq -r '.labels[0].label' "$f")" "good"
assert_eq "$(jq -r '.labels[1].note' "$f")" "wrong year"
run_ledger_label "session_t1" "excellent!!" "rate" "u" >/dev/null 2>&1
assert_eq "$?" "2" "labels are allow-listed"

describe "react_run integration"
source "$LODGE_DIR/lib/core/react.sh" 2>/dev/null
assert_fn_contains react_run run_ledger_start
assert_fn_contains react_run _react_ledger_close
assert_fn_defined _react_ledger_close

test_end
