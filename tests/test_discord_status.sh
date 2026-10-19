#!/usr/bin/env bash
# Discord reply contract, status message, visibility, feedback, pidfiles (refinement P3)
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"
LODGE_DIR="$GEORGE_TEST_REPO"; export LODGE_DIR
export DISCORD_SESSIONS_DIR="$GEORGE_DIR/discord_sessions"
mkdir -p "$DISCORD_SESSIONS_DIR"
unset _LIB_RUN_LEDGER_LOADED _LIB_DISCORD_STATUS_LOADED
source "$LODGE_DIR/lib/core/run_ledger.sh"
source "$LODGE_DIR/lib/comms/discord_status.sh"

test_start "discord_status (P3 reply contract)"

d="$GEORGE_TEST_SANDBOX/dstat"; mkdir -p "$d"
cat > "$d/cfg.json" <<'EOF'
{"reactions": {"900000000000000002": {"👍": ["111111111111111111", "222222222222222222"], "🐢": ["111111111111111111"]}}}
EOF
python3 "$LODGE_DIR/tests/helpers/mock_discord.py" "$d/port" "$d/cfg.json" "$d/log.jsonl" &
mpid=$!
for _i in $(seq 50); do [ -s "$d/port" ] && break; sleep 0.1; done
export DISCORD_API_BASE="http://127.0.0.1:$(cat "$d/port")"
export DISCORD_BOT_TOKEN="test-token"
CH="123456789012345678"

describe "3.1 reply comes only from the run ledger / own session"
run_ledger_start "sess_ok" "q" "discord" >/dev/null
ws_ok="$GEORGE_TEST_SANDBOX/ws_ok"; mkdir -p "$ws_ok"; echo "The answer is 42." > "$ws_ok/final_reply.txt"
run_ledger_finish "sess_ok" "SUCCESS" "" "$ws_ok/final_reply.txt" 3 2 0 0
out=$(discord_reply_for_run "sess_ok" "$ws_ok"); rc=$?
assert_eq "0" "$rc" "ledger reply rc"
assert_eq "The answer is 42." "$out" "ledger reply verbatim, no footer on SUCCESS"

# A DIFFERENT session's fresh final reply must never leak into this one
other="$GEORGE_DIR/workspaces/discord_other"; mkdir -p "$other"; echo "LEAKED other-session reply" > "$other/final_reply.txt"
run_ledger_start "sess_fail" "q2" "discord" >/dev/null
ws_fail="$GEORGE_TEST_SANDBOX/ws_fail"; mkdir -p "$ws_fail"
printf '## Findings\n- UNH closed at 371.90 on Oct 2\n- **Milestone**: Step 1\n' > "$ws_fail/scratchpad.md"
run_ledger_finish "sess_fail" "LOOP" "Action repetition ceiling (web_fetch)" "" 9 9 4 1
out=$(discord_reply_for_run "sess_fail" "$ws_fail"); rc=$?
assert_eq "1" "$rc" "failure rc"
assert_not_contains "$out" "LEAKED" "no cross-session fallback"
assert_not_contains "$out" "George is here" "no canned reply"
assert_contains "$out" "Outcome: LOOP" "honest outcome"
assert_contains "$out" "sess_fail" "run id"
assert_contains "$out" "UNH closed at 371.90" "partial findings"
assert_not_contains "$out" "Milestone" "scratchpad bookkeeping filtered"

describe "3.2 partial outcome keeps reply but flags it"
run_ledger_start "sess_mt" "q3" "discord" >/dev/null
ws_mt="$GEORGE_TEST_SANDBOX/ws_mt"; mkdir -p "$ws_mt"; echo "Draft answer" > "$ws_mt/final_reply.txt"
run_ledger_finish "sess_mt" "MAX_TURNS" "" "$ws_mt/final_reply.txt" 200 150 3 0
out=$(discord_reply_for_run "sess_mt" "$ws_mt")
assert_contains "$out" "Draft answer" "partial reply kept"
assert_contains "$out" "MAX_TURNS" "outcome footer"
out=$(discord_reply_for_run "sess_unknown" "")
assert_contains "$out" "NO_RESULT" "no ledger, no reply → honest notice"

describe "3.3 status message post/edit + render"
mid=$(discord_status_post "$CH" "⏳ Working on it")
assert_eq "900000000000000001" "$mid" "status message id"
assert_eq "" "$(DISCORD_STATUS_ENABLED=0 discord_status_post "$CH" "x" 2>/dev/null)" "DISCORD_STATUS_ENABLED=0 blocks API"
assert_eq "" "$(LODGE_EVAL=1 discord_status_post "$CH" "x" 2>/dev/null)" "LODGE_EVAL=1 blocks API"
sd="$GEORGE_TEST_SANDBOX/sd"; mkdir -p "$sd"
cat > "$sd/messages.json" <<'EOF'
[{"role":"system","content":"s"},{"role":"user","content":"u"},
 {"role":"assistant","content":null,"tool_calls":[{"id":"1","type":"function","function":{"name":"web_search","arguments":"{}"}}]},
 {"role":"tool","tool_call_id":"1","content":"r"},
 {"role":"assistant","content":null,"tool_calls":[{"id":"2","type":"function","function":{"name":"web_fetch","arguments":"{}"}}]},
 {"role":"tool","tool_call_id":"2","content":"r"}]
EOF
echo '{"items":[{"id":1,"task":"Search","status":"done"},{"id":2,"task":"Fetch UNH quote page","status":"pending"}]}' > "$sd/honeydew.json"
terse=$(discord_status_render "$sd" 0 "$(( $(date +%s) - 75 ))")
assert_contains "$terse" "turn 2 · 2 tool calls · 1m1" "terse progress"
assert_not_contains "$terse" "Fetch UNH" "terse hides step text"
verbose=$(discord_status_render "$sd" 1 "$(date +%s)")
assert_contains "$verbose" "Step 2: Fetch UNH quote page" "verbose step"
assert_contains "$verbose" "Last tool: web_fetch" "verbose last tool"
discord_status_edit "$CH" "$mid" "edited"; assert_ok $? "edit ok"
assert_eq "PATCH" "$(tail -1 "$d/log.jsonl" | jq -r .method)" "PATCH sent"
assert_eq "[]" "$(tail -1 "$d/log.jsonl" | jq -c .body.allowed_mentions.parse)" "status never pings"

stop="$GEORGE_TEST_SANDBOX/stop"; rm -f "$stop"
before=$(grep -c PATCH "$d/log.jsonl")
DISCORD_STATUS_TEST_INTERVAL=1 discord_status_loop "$CH" "$mid" "$sd" 0 "$(date +%s)" "$stop" &
lpid=$!
sleep 2.6; touch "$stop"; wait "$lpid"
after=$(grep -c PATCH "$d/log.jsonl")
assert_gt "$after" "$before" "loop edited the status message"
DISCORD_STATUS_ENABLED=0 discord_status_post "$CH" "x" >/dev/null; assert_fail $? "disabled → no post"
discord_status_post "not-a-channel" "x" >/dev/null; assert_fail $? "non-snowflake channel rejected"
ft=$(discord_status_final_text "sess_ok" "SUCCESS" 192)
assert_contains "$ft" "SUCCESS · 3m12s" "final text"
assert_contains "$ft" "👍 good" "rating legend"

describe "3.4 visibility tiers"
discord_status_verbose_ok 0 "111111111111111111"; assert_fail $? "public channel never verbose"
reputation_get() { echo "55|Master Mason"; }
discord_status_verbose_ok 1 "111111111111111111"; assert_ok $? "Master Mason DM verbose"
reputation_get() { echo "30|Brother"; }
discord_status_verbose_ok 1 "111111111111111111"; assert_fail $? "Brother DM terse"
discord_status_verbose_ok 1 "1; DROP TABLE"; assert_fail $? "invalid id rejected"
unset -f reputation_get

describe "3.7 ops and crypto tool profile gating"
reputation_get() { echo "10|Entered Apprentice"; }
discord_user_trusted "222222222222222222"; assert_fail $? "low reputation untrusted"
assert_eq "$(discord_select_run_profile "222222222222222222" "please fix my cron job")" "social_untrusted" "stranger ops intent stays social_untrusted"
assert_eq "$(discord_select_run_profile "222222222222222222" "$(printf 'x%.0s' {1..200})")" "social_untrusted" "stranger long prompt stays social_untrusted"
assert_eq "$(discord_select_run_profile "222222222222222222" "reposition our crypto limit orders")" "social_untrusted" "stranger crypto intent stays social_untrusted"

reputation_get() { echo "60|Master Mason"; }
discord_user_trusted "222222222222222222"; assert_ok $? "reputation >= 50 trusted"
assert_eq "$(discord_select_run_profile "222222222222222222" "please fix my cron job")" "social+ops" "trusted ops intent elevates"
assert_eq "$(discord_select_run_profile "222222222222222222" "hi george")" "social" "trusted chit-chat stays social"
assert_eq "$(discord_select_run_profile "222222222222222222" "what is crypto market price")" "social" "trusted non-owner never gets crypto tools"

# Owner tests (mocking owner ID and username)
DISCORD_OWNER_IDS="999999999999999999" DISCORD_OWNER_USERNAMES="testowner"
assert_eq "$(DISCORD_OWNER_IDS="999999999999999999" discord_select_run_profile "999999999999999999" "reposition our crypto limits and stop orders")" "social+crypto" "owner crypto intent elevates to social+crypto"
assert_eq "$(DISCORD_OWNER_USERNAMES="testowner" discord_select_run_profile "some_random_id" "reposition our crypto limits" "testowner")" "social+crypto" "owner username elevates to social+crypto"
assert_eq "$(DISCORD_OWNER_USERNAMES="testowner" discord_select_run_profile "some_random_id" "reposition our crypto limits and fix docker cron daemon" "testowner")" "social+ops+crypto" "owner crypto+ops elevates to social+ops+crypto"

DISCORD_OPS_MIN_REPUTATION=75 discord_user_trusted "222222222222222222"; assert_fail $? "threshold configurable"
discord_user_trusted "1' OR '1'='1"; assert_fail $? "invalid id never trusted"
unset -f reputation_get
discord_user_trusted "222222222222222222"; assert_fail $? "no reputation db -> untrusted"

describe "3.8 chat rewards cannot farm past the trust threshold"
_rep_added=""
reputation_add() { _rep_added="$2"; }
reputation_get() { echo "30|Brother"; }
discord_reward_turn "222222222222222222" "bob"; assert_eq "$_rep_added" "1" "below cap earns +1"
_rep_added=""; reputation_get() { echo "49|Brother"; }
discord_reward_turn "222222222222222222" "bob"; assert_eq "$_rep_added" "" "at cap (threshold-1) no auto reward"
_rep_added=""; reputation_get() { echo "70|Master Mason"; }
discord_reward_turn "222222222222222222" "bob"; assert_eq "$_rep_added" "1" "already-trusted users keep earning"
_rep_added=""; discord_reward_turn "x' OR 1=1" "bob"; assert_eq "$_rep_added" "" "invalid id ignored"
unset -f reputation_get reputation_add
echo '{"u1":"555555555555555555"}' > "$DISCORD_SESSIONS_DIR/known_dms.json"
discord_channel_is_dm "555555555555555555"; assert_ok $? "known DM channel"
discord_channel_is_dm "$CH"; assert_fail $? "public channel"

describe "3.5 feedback: reactions + /rate → ledger labels"
discord_feedback_track "$CH" "900000000000000002" "sess_ok"; assert_ok $? "tracked"
DISCORD_BOT_ID="222222222222222222" discord_feedback_sweep
labels=$(jq -c '[.labels[] | "\(.label):\(.user):\(.source)"]' "$GEORGE_DIR/runs/sess_ok/run.json")
assert_contains "$labels" "good:111111111111111111:discord_reaction" "thumbs up labelled"
assert_contains "$labels" "slow:111111111111111111:discord_reaction" "turtle labelled"
assert_not_contains "$labels" "222222222222222222" "bot's own reaction ignored"
DISCORD_BOT_ID="222222222222222222" discord_feedback_sweep
assert_eq "2" "$(jq '.labels | length' "$GEORGE_DIR/runs/sess_ok/run.json")" "sweep idempotent"
ack=$(discord_rate_command "/rate partial missing the dividend" "111111111111111111" "sess_mt"); rc=$?
assert_eq "0" "$rc" "/rate default run"
assert_contains "$ack" "partial" "ack"
assert_eq "missing the dividend" "$(jq -r '.labels[-1].note' "$GEORGE_DIR/runs/sess_mt/run.json")" "note stored"
discord_rate_command "/rate sess_fail wrong" "111111111111111111" "" >/dev/null; assert_ok $? "/rate explicit run"
discord_rate_command "/rate nosuch_run good" "1" "" >/dev/null; assert_fail $? "unknown run rejected"
assert_file_not_exists "$GEORGE_DIR/runs/nosuch_run/run.json" "no skeleton created"
discord_rate_command "/rate amazing" "1" "sess_ok" >/dev/null; assert_fail $? "invalid label"
touch -d "@$(( $(date +%s) - 90000 ))" "$DISCORD_SESSIONS_DIR/feedback/900000000000000002.json"
jq '.ts = 1' "$DISCORD_SESSIONS_DIR/feedback/900000000000000002.json" > "$d/x" && mv "$d/x" "$DISCORD_SESSIONS_DIR/feedback/900000000000000002.json"
discord_feedback_sweep
assert_file_not_exists "$DISCORD_SESSIONS_DIR/feedback/900000000000000002.json" "expired tracker removed"

describe "3.6 pidfiles survive PID reuse"
pf="$GEORGE_TEST_SANDBOX/x.pid"
sleep 30 & spid=$!
discord_pid_write "$pf" "$spid"
assert_file_exists "${pf}.start" "start sidecar"
assert_eq "$spid" "$(cat "$pf")" "pidfile stays a bare pid (Rust/monitor compatible)"
discord_pid_alive "$pf"; assert_ok $? "live process"
echo "1" > "${pf}.start"
discord_pid_alive "$pf"; assert_fail $? "start-time mismatch → recycled PID"
kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
discord_pid_write "$pf" "$$"; rm -f "${pf}.start"
touch -d "@$(( $(date +%s) - $(cut -d. -f1 /proc/uptime) - 60 ))" "$pf"
discord_pid_alive "$pf"; assert_fail $? "legacy pidfile from before boot → stale"
touch "$pf"
discord_pid_alive "$pf"; assert_ok $? "legacy pidfile written this boot"

kill "$mpid" 2>/dev/null
test_end
