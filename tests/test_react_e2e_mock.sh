#!/usr/bin/env bash
# Hermetic end-to-end react_run against a scripted mock LLM (refinement P1/1.7).
# Verifies the run ledger records real outcomes from real loop exits.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"
LODGE_DIR="$GEORGE_TEST_REPO"; export LODGE_DIR

test_start "react_e2e_mock"

command -v setsid >/dev/null 2>&1 || { skip "setsid unavailable"; test_end; exit 0; }

# _mock_run <name> <script_json> <goal> <max_turns> <profile>
_mock_run() {
    local name="$1" script="$2" goal="$3" turns="$4" profile="$5"
    local d="$GEORGE_TEST_SANDBOX/$name"; mkdir -p "$d"
    printf '%s' "$script" > "$d/script.json"
    python3 "$LODGE_DIR/tests/helpers/mock_llm.py" "$d/port" "$d/script.json" "$d/llm.log" &
    local mpid=$!
    local _i; for _i in $(seq 50); do [ -s "$d/port" ] && break; sleep 0.1; done
    local port; port=$(cat "$d/port" 2>/dev/null)
    ( cd "$d" && ENDPOINTS_CONF="$d/none.conf" TIER1_URL="http://127.0.0.1:$port" TIER1_ENABLED=1 \
        TIER0_ENABLED=0 TIER2_ENABLED=0 TIER3_ENABLED=0 TIER1_MODEL=mock ACTIVE_TIER=1 \
        REACT_SESSION_ID="session_$name" LODGE_TIMEOUT=20 TELEMETRY_BUS_BRIDGE=0 \
        timeout 150 setsid -w bash -c 'source "$LODGE_DIR/lib/core/react.sh" 2>/dev/null; react_run "$1" "$PWD" "$2" "$3"' _ \
        "$goal" "$turns" "$profile" </dev/null > "$d/out.log" 2>&1 )
    echo $? > "$d/rc"
    kill "$mpid" 2>/dev/null; wait "$mpid" 2>/dev/null
    pkill -f "george-keeper-session_$name" 2>/dev/null || true
}

describe "SUCCESS path writes ledger + final_reply.md"
_mock_run ok '{"turns":[{"content":"The answer is 4."}],"aux":"{\"items\":[]}"}' "What is 2+2? Reply briefly." 4 chat
f="$GEORGE_DIR/runs/session_ok/run.json"
assert_file_exists "$f"
assert_eq "$(jq -r '.status' "$f" 2>/dev/null)" "FINISHED"
assert_eq "$(jq -r '.outcome' "$f" 2>/dev/null)" "SUCCESS"
assert_eq "$(jq -r '.model' "$f" 2>/dev/null)" "mock"
assert_contains "$(cat "$GEORGE_DIR/runs/session_ok/final_reply.md" 2>/dev/null)" "The answer is 4."

describe "empty turns produce STALL"
_mock_run stall '{"turns":[{"content":""}],"aux":"{\"items\":[]}"}' "Say hello." 8 chat
f="$GEORGE_DIR/runs/session_stall/run.json"
assert_file_exists "$f"
assert_eq "$(jq -r '.outcome' "$f" 2>/dev/null)" "STALL"
assert_contains "$(jq -r '.reason' "$f" 2>/dev/null)" "consecutive_empty_turns"
assert_file_not_exists "$GEORGE_DIR/runs/session_stall/final_reply.md"

describe "tool call → envelope (stderr warning is not a failure; ordering valid)"
_tc='{"turns":[{"content":"","tool_calls":[{"id":"call_env1","type":"function","function":{"name":"bash_exec","arguments":"{\"command\":\"echo \\\"<string>:20: DeprecationWarning: old api\\\" >&2; echo answer=42\"}"}}]},{"content":"The answer is 42."}],"aux":"{\"items\":[]}"}'
_mock_run env "$_tc" "Run the probe and tell me the number." 6 chat
f="$GEORGE_DIR/runs/session_env/run.json"
assert_eq "$(jq -r '.outcome' "$f" 2>/dev/null)" "SUCCESS" "run succeeds"
assert_eq "$(jq -r '.tool_fails' "$f" 2>/dev/null)" "0" "no tool failure recorded"
assert_eq "$(jq -r '.tool_calls' "$f" 2>/dev/null)" "1" "one tool call recorded"
envf=$(ls "$GEORGE_DIR"/workspaces/session_env/observations/*.envelope.json 2>/dev/null | head -1)
[ -z "$envf" ] && envf=$(find "$GEORGE_TEST_SANDBOX/env" "$GEORGE_DIR" -name 'call_call_env1.envelope.json' 2>/dev/null | head -1)
assert_eq "$(jq -r '.ok' "$envf" 2>/dev/null)" "true" "envelope ok=true"
msgs="$GEORGE_DIR/runs/session_env/messages.json"
tool_c=$(jq -r '[.[] | select(.role == "tool")][0].content' "$msgs" 2>/dev/null)
assert_contains "$tool_c" "answer=42" "observation delivered"
assert_not_contains "$tool_c" "DeprecationWarning" "warning stripped before the model"
assert_eq "$(jq -r '[.[] | .role] | (index("tool") as $t | .[$t-1])' "$msgs" 2>/dev/null)" "assistant" "tool result directly follows its assistant tool_calls"
assert_eq "$(jq -r '[.[] | select(.role == "tool") | has("exit_code")] | any' "$msgs" 2>/dev/null)" "false" "envelope metadata stripped from LLM messages"

describe "REACT_WALL_BUDGET_S forces the final turn (eval/discord time budget)"
_slow='{"type":"function","function":{"name":"bash_exec","arguments":"{\"command\":\"sleep 3; echo step\"}"}}'
_wb="{\"turns\":[{\"content\":\"\",\"tool_calls\":[{\"id\":\"w1\",${_slow#\{}]},{\"content\":\"\",\"tool_calls\":[{\"id\":\"w2\",${_slow#\{}]},{\"content\":\"\",\"tool_calls\":[{\"id\":\"w3\",${_slow#\{}]},{\"content\":\"\",\"tool_calls\":[{\"id\":\"w4\",${_slow#\{}]},{\"content\":\"Report done.\"}],\"aux\":\"{\\\"items\\\":[]}\"}"
REACT_WALL_BUDGET_S=4 _mock_run wall "$_wb" "Run the slow probe several times then report." 10 chat
msgs="$GEORGE_DIR/runs/session_wall/messages.json"
assert_contains "$(jq -r '[.[] | select(.role == "user") | .content] | join("\n")' "$msgs" 2>/dev/null)" "TIME BUDGET EXHAUSTED" "final-turn advisory injected"
assert_eq "$(jq -r '[.[] | select(.role == "tool")] | length' "$msgs" 2>/dev/null)" "2" "loop stopped after the budget turn (2 of 4 tool turns)"
assert_contains "$(cat "$GEORGE_TEST_SANDBOX/wall/out.log")" "Time budget:" "budget warning surfaced"

test_end
