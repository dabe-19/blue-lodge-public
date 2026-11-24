#!/usr/bin/env bash
# End-to-end: discord_generate_response → react_run (mock LLM) → run ledger → reply,
# with status message post/final edit against a mock Discord API (refinement P3).
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"
LODGE_DIR="$GEORGE_TEST_REPO"; export LODGE_DIR

test_start "discord_e2e_mock"
command -v setsid >/dev/null 2>&1 || { skip "setsid unavailable"; test_end; exit 0; }

d="$GEORGE_TEST_SANDBOX/de2e"; mkdir -p "$d"
echo '{"reactions":{}}' > "$d/dcfg.json"
python3 "$LODGE_DIR/tests/helpers/mock_discord.py" "$d/dport" "$d/dcfg.json" "$d/discord.jsonl" &
dpid=$!
for _i in $(seq 50); do [ -s "$d/dport" ] && break; sleep 0.1; done

# _bridge_run <name> <llm_script_json> <prompt>
_bridge_run() {
    local name="$1" script="$2" prompt="$3" w="$d/$1"; mkdir -p "$w"
    printf '%s' "$script" > "$w/script.json"
    python3 "$LODGE_DIR/tests/helpers/mock_llm.py" "$w/port" "$w/script.json" "$w/llm.log" &
    local mpid=$!
    local _i; for _i in $(seq 50); do [ -s "$w/port" ] && break; sleep 0.1; done
    ( cd "$w" && ENDPOINTS_CONF="$w/none.conf" TIER1_URL="http://127.0.0.1:$(cat "$w/port")" TIER1_ENABLED=1 \
        TIER0_ENABLED=0 TIER2_ENABLED=0 TIER3_ENABLED=0 TIER1_MODEL=mock ACTIVE_TIER=1 \
        LODGE_TIMEOUT=20 TELEMETRY_BUS_BRIDGE=0 DISCORD_AGENT_MAX_TURNS=6 \
        DISCORD_API_BASE="http://127.0.0.1:$(cat "$d/dport")" DISCORD_BOT_TOKEN="test-token" \
        DISCORD_SESSIONS_DIR="$GEORGE_DIR/discord_sessions" DISCORD_PROFILES_DB="$GEORGE_DIR/discord_profiles.db" \
        REPUTATION_DB="$GEORGE_DIR/reputation.db" \
        timeout 150 setsid -w bash -c '
            source "$LODGE_DIR/lib/comms/discord_bridge.sh" 2>/dev/null
            discord_generate_response "$1" "123456789012345678" "tester" "" "" "111111111111111111" "$2"' _ \
        "$prompt" "$w/reply.txt" </dev/null > "$w/out.log" 2>&1 )
    kill "$mpid" 2>/dev/null; wait "$mpid" 2>/dev/null
}

describe "SUCCESS: status message posted, reply from ledger, final edit with rating legend"
: > "$d/discord.jsonl"
_bridge_run ok '{"turns":[{"content":"The capital of France is Paris."}],"aux":"{\"items\":[]}"}' "What is the capital of France?"
reply=$(cat "$d/ok/reply.txt" 2>/dev/null)
assert_contains "$reply" "Paris" "reply from the run"
assert_not_contains "$reply" "George is here" "no canned text"
posts=$(jq -r 'select(.method=="POST") | .body.content' "$d/discord.jsonl" 2>/dev/null)
assert_contains "$posts" "Working on it" "status message posted"
final=$(jq -rs 'map(select(.method=="PATCH")) | last | .body.content // ""' "$d/discord.jsonl" 2>/dev/null)
assert_contains "$final" "Finished — SUCCESS" "status finalized with outcome"
assert_contains "$final" "👍 good" "rating legend"
assert_eq "1" "$(ls "$GEORGE_DIR/discord_sessions/feedback/"*.json 2>/dev/null | wc -l | tr -d ' ')" "feedback tracker created"
sid=$(jq -r '.session_id' "$GEORGE_DIR"/discord_sessions/feedback/*.json 2>/dev/null)
assert_eq "SUCCESS" "$(jq -r '.outcome' "$GEORGE_DIR/runs/$sid/run.json" 2>/dev/null)" "ledger outcome"

describe "No result: honest failure, never another session's reply"
mkdir -p "$GEORGE_DIR/workspaces/discord_stale_other"
echo "STALE reply from another session" > "$GEORGE_DIR/workspaces/discord_stale_other/final_reply.txt"
: > "$d/discord.jsonl"
_bridge_run stall '{"turns":[{"content":""}],"aux":"{\"items\":[]}"}' "Say hello."
reply=$(cat "$d/stall/reply.txt" 2>/dev/null)
assert_not_contains "$reply" "STALE reply" "no cross-session fallback"
assert_contains "$reply" "wasn't able to finish" "honest failure"
assert_contains "$reply" "STALL" "outcome named"
final=$(jq -rs 'map(select(.method=="PATCH")) | last | .body.content // ""' "$d/discord.jsonl" 2>/dev/null)
assert_contains "$final" "STALL" "status shows failure outcome"

kill "$dpid" 2>/dev/null
test_end
