#!/bin/bash
# ── Tests: Discord Bot Bridge & Interactive Chat Service ─────────────

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/api.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/social.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/native_tools.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/discord_bridge.sh" 2>/dev/null || true
source "$LODGE_DIR/commands/social.sh" 2>/dev/null || true

TEST_TMP=$(mktemp -d /tmp/george-discord-test-XXXXXX)
export GEORGE_CONFIG_DIR="$TEST_TMP/.george"
export GEORGE_DIR="$GEORGE_CONFIG_DIR"
export DISCORD_SESSIONS_DIR="$GEORGE_DIR/discord_sessions"
export DISCORD_MEDIA_DIR="$GEORGE_DIR/discord_media"
export DISCORD_LAST_SEEN_FILE="$DISCORD_SESSIONS_DIR/last_seen.json"
export DISCORD_KNOWN_DMS_FILE="$DISCORD_SESSIONS_DIR/known_dms.json"
export DISCORD_CHANNELS_DB="$GEORGE_DIR/discord_channels.db"
export DISCORD_USERS_DB="$GEORGE_DIR/discord_users.db"
export DISCORD_PROFILES_DB="$GEORGE_DIR/discord_profiles.db"
export DISCORD_BRIDGE_LOG="$DISCORD_SESSIONS_DIR/bridge.log"

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

test_start "Discord Bot Bridge & Interactive Chat Service"

describe "discord_bridge_init"

it "creates discord session and media directories" && {
    discord_bridge_init
    assert_dir_exists "$DISCORD_SESSIONS_DIR"
    assert_dir_exists "$DISCORD_MEDIA_DIR"
    assert_file_exists "$DISCORD_LAST_SEEN_FILE"
    ch_count=$(jq -r '.channels | length' "$DISCORD_LAST_SEEN_FILE" 2>/dev/null)
    assert_eq "$ch_count" "0"
}

describe "discord_send_file"

it "rejects missing channel target or file path" && {
    out=$(discord_send_file "" "" 2>&1 || true)
    assert_contains "$out" "Usage: discord_send_file"
}

it "rejects non-existent file path" && {
    api_get_key() { echo "mock-bot-token"; }
    api_require_key() { echo "mock-bot-token"; }
    out=$(discord_send_file "123456789" "$TEST_TMP/nonexistent.png" 2>&1 || true)
    assert_contains "$out" "does not exist"
}

it "formats and dispatches multipart curl request with image attachment" && {
    dummy_img="$TEST_TMP/test_chart.png"
    echo "PNG_DUMMY_BINARY_DATA" > "$dummy_img"

    curl() {
        echo "$*" >> "$TEST_TMP/curl_args.log"
        echo '{"id":"9988776655","content":"Here is the chart"}'
        echo "200"
    }

    out=$(discord_send_file "123456789" "$dummy_img" "Here is the chart" 2>&1)
    assert_ok $?
    assert_contains "$out" "Uploaded 'test_chart.png' to Discord"

    args=$(cat "$TEST_TMP/curl_args.log")
    assert_contains "$args" "files[0]=@$dummy_img;filename=test_chart.png"
    assert_contains "$args" "payload_json="
    rm -f "$TEST_TMP/curl_args.log"
}

describe "discord_download_attachments"

it "extracts and downloads image attachments from inbound message JSON" && {
    dummy_remote="$TEST_TMP/remote_photo.jpg"
    echo "INBOUND_IMAGE_BYTES" > "$dummy_remote"

    curl() {
        local args=("$@")
        for ((i=0; i<${#args[@]}; i++)); do
            if [ "${args[$i]}" = "-o" ]; then
                cp "$dummy_remote" "${args[$((i+1))]}"
                return 0
            fi
        done
        return 1
    }

    mock_json='{
        "id": "11223344",
        "attachments": [
            {
                "id": "att_999",
                "url": "https://cdn.discordapp.com/attachments/1122/999/architecture_diagram.png",
                "filename": "architecture_diagram.png"
            }
        ]
    }'

    downloaded=$(discord_download_attachments "$mock_json" "chan_100")
    assert_file_exists "$downloaded"
    content=$(cat "$downloaded")
    assert_eq "$content" "INBOUND_IMAGE_BYTES"
    assert_contains "$downloaded" "chan_100_att_999_architecture_diagram.png"
}

describe "Inactivity Watchdog (120 seconds)"

it "verifies watchdog inactivity duration constant is 120s" && {
    src=$(grep -n "elapsed.*-ge 120" "$LODGE_DIR/lib/comms/discord_bridge.sh")
    assert_not_empty "$src"
}

describe "discord_bridge_sweep"

it "ignores channels when no new messages arrived beyond last_seen" && {
    sqlite3 "$DISCORD_CHANNELS_DB" "CREATE TABLE channels (name TEXT, channel_id TEXT);"
    sqlite3 "$DISCORD_CHANNELS_DB" "INSERT INTO channels VALUES ('general', '200100');"
    sqlite3 "$DISCORD_USERS_DB" "CREATE TABLE users (username TEXT, user_id TEXT, is_bot INTEGER);"
    sqlite3 "$DISCORD_USERS_DB" "INSERT INTO users VALUES ('operator', '190628469', 0);"

    echo '{"channels":{"200100":"500","300000000000000001":"500"}}' > "$DISCORD_LAST_SEEN_FILE"

    api_get_key() { echo "mock_token"; }

    curl() {
        if [[ "$*" == *"/users/@me"* && "$*" != *"/channels"* ]]; then
            echo '{"id":"777","username":"George"}'
        elif [[ "$*" == *"/messages"* ]]; then
            echo '[{"id":"450","author":{"id":"190628469","username":"operator"},"content":"old message"}]'
        else
            echo '{}'
        fi
    }

    out=$(discord_bridge_sweep)
    assert_ok $?
    assert_contains "$out" "No new DMs or @mentions found"
}

describe "Native Tool Wiring: discord_send_file"

it "exposes discord_send_file in social bundle" && {
    tools=$(native_tools_bundle_tools "+social")
    assert_contains "$tools" "discord_send_file"
}

it "includes discord_send_file and vision_analyze in social profile" && {
    prof=$(native_tools_resolve_profile "social")
    echo "$prof" | jq -e '.[] | select(.function.name == "discord_send_file")' >/dev/null
    assert_ok $?
    echo "$prof" | jq -e '.[] | select(.function.name == "vision_analyze")' >/dev/null
    assert_ok $?
}

it "dispatches discord_send_file through native_tools_dispatch" && {
    dummy_file="$TEST_TMP/report.pdf"
    echo "PDF_DUMMY" > "$dummy_file"

    api_get_key() { echo "mock_token"; }
    api_require_key() { echo "mock_token"; }

    curl() {
        echo '{"id":"101","content":"Uploaded report"}'
        echo "200"
    }

    args_json=$(jq -nc --arg t "200100" --arg f "$dummy_file" --arg m "Monthly report" \
        '{"target": $t, "file_path": $f, "message": $m}')

    resp=$(native_tools_dispatch "call_test_1" "discord_send_file" "$args_json" "$TEST_TMP")
    assert_ok $?
    assert_contains "$resp" "Uploaded 'report.pdf' to Discord"
}

describe "CLI Command Integration: /social discord"

it "routes /social discord upload to discord_send_file" && {
    dummy_file="$TEST_TMP/banner.webp"
    echo "WEBP_DATA" > "$dummy_file"

    curl() {
        echo '{"id":"102","content":"banner"}'
        echo "200"
    }

    out=$(cmd_social "discord upload 200100 $dummy_file Banner uploaded" "$TEST_TMP")
    assert_ok $?
    assert_contains "$out" "Uploaded 'banner.webp' to Discord"
}

describe "Continuous Typing Pulse Heartbeat"

it "starts and stops background typing heartbeat loop cleanly" && {
    api_get_key() { echo "mock_token"; }
    curl() { return 0; }

    pulse_pid=$(discord_typing_pulse_start "chan_test_99")
    assert_not_empty "$pulse_pid"
    kill -0 "$pulse_pid" 2>/dev/null
    assert_ok $?

    discord_typing_pulse_stop "$pulse_pid"
    kill -0 "$pulse_pid" 2>/dev/null
    assert_fail $?
}

describe "Multi-Turn Conversational History Buffer"

it "records and formats multi-turn dialogue context" && {
    discord_history_clear "chan_test_99"
    discord_history_append "chan_test_99" "user" "operator" "What is the weather in Springfield?"
    discord_history_append "chan_test_99" "assistant" "George" "It is 61F and cloudy."

    ctx=$(discord_history_get "chan_test_99" 4)
    assert_contains "$ctx" "Recent Conversation Context"
    assert_contains "$ctx" "@operator: What is the weather in Springfield?"
    assert_contains "$ctx" "George: It is 61F and cloudy."

    discord_history_clear "chan_test_99"
    cleared=$(discord_history_get "chan_test_99" 4)
    assert_empty "$cleared"
}

describe "User Profile Management: discord_profile_get / discord_profile_set"

it "stores and retrieves user location and notes in discord_profiles.db" && {
    discord_bridge_init
    discord_profile_set "user_123" "location" "Springfield, IL"
    discord_profile_set "user_123" "notes" "Operator of Blue Lodge"

    prof=$(discord_profile_get "user_123")
    assert_contains "$prof" "Springfield, IL"
    assert_contains "$prof" "Operator of Blue Lodge"
}

describe "Context Injection Fresh Task Isolation"

it "isolates fresh task turn 1 from past history and includes clean user profile" && {
    export _DISCORD_IN_ACTIVE_PIPE=1
    export _DISCORD_PIPE_TURN=1
    export DISCORD_PROFILES_DB="$GEORGE_DIR/discord_profiles.db"

    # Populate profile
    sqlite3 "$DISCORD_PROFILES_DB" "INSERT OR REPLACE INTO discord_user_profiles (user_id, username, location, notes, interaction_count, updated_at) VALUES ('user_456', 'operator', 'Springfield, IL', 'Lead Architect', 1, $(date +%s));"

    # Mock react_run to inspect target_goal
    CAPTURED_GOAL=""
    CAPTURED_CONV=""
    react_run() {
        CAPTURED_GOAL="$1"
        CAPTURED_CONV="${REACT_CONVERSATION_HISTORY:-}"
        local s_id="${REACT_SESSION_ID:-session_mock}"
        mkdir -p "$GEORGE_DIR/workspaces/$s_id"
        echo "Tonight in Springfield, IL it is clear and 55F." > "$GEORGE_DIR/workspaces/$s_id/final_reply.txt"
    }

    out_file="$TEST_TMP/reply_iso.txt"
    discord_generate_response "What is the weather like tonight?" "chan_iso_1" "operator" "" "" "user_456" "$out_file"

    assert_contains "$CAPTURED_CONV" "Location: Springfield, IL"
    assert_contains "$CAPTURED_GOAL" "What is the weather like tonight?"
    # Must NOT contain old conversation context header
    assert_not_contains "$CAPTURED_GOAL" "Recent Conversation Context"

    reply=$(cat "$out_file")
    assert_contains "$reply" "Springfield, IL"
}

describe "Privacy: /forget me"

it "erases profile, directory row, scoped + shared history; keeps penalty scores" && {
    export DISCORD_PROFILES_DB="$GEORGE_DIR/discord_profiles.db"
    export DISCORD_USERS_DB="$GEORGE_DIR/discord_users.db"
    export REPUTATION_DB="$GEORGE_DIR/reputation.db"
    mkdir -p "$DISCORD_HISTORY_DIR"
    sqlite3 "$DISCORD_PROFILES_DB" "INSERT OR REPLACE INTO discord_user_profiles (user_id, username, location, notes, interaction_count, updated_at) VALUES ('fgt_1', 'forgetme', 'Somewhere', 'note', 1, 0), ('keep_2', 'keeper', 'Elsewhere', '', 1, 0);"
    sqlite3 "$DISCORD_USERS_DB" "CREATE TABLE IF NOT EXISTS users (username TEXT, display_name TEXT, user_id TEXT UNIQUE, guild_name TEXT, guild_id TEXT, is_bot INTEGER, created_at TEXT); INSERT OR REPLACE INTO users (username, user_id) VALUES ('forgetme','fgt_1'),('keeper','keep_2');"
    sqlite3 "$REPUTATION_DB" "CREATE TABLE IF NOT EXISTS reputation (user_id TEXT PRIMARY KEY, username TEXT, platform TEXT, score INTEGER DEFAULT 10, tier TEXT, notes TEXT, created_at INTEGER, last_seen INTEGER); INSERT OR REPLACE INTO reputation (user_id, username, score, notes) VALUES ('fgt_1','forgetme',-5,'spam'),('fgt_3','nice',40,'helpful');"
    echo '[{"role":"user","author":"forgetme","content":"hi"}]' > "$DISCORD_HISTORY_DIR/history_chanA_fgt_1.json"
    echo '[{"role":"user","author":"forgetme","content":"x"},{"role":"user","author":"keeper","content":"y"}]' > "$DISCORD_HISTORY_DIR/history_chanB.json"
    echo '[{"role":"user","author":"keeper","content":"z"}]' > "$DISCORD_HISTORY_DIR/history_chanA_keep_2.json"

    out_file="$TEST_TMP/reply_forget.txt"
    reply=$(discord_generate_response "/forget me" "chanA" "forgetme" "" "" "fgt_1" "$out_file")
    assert_contains "$reply" "deleted your profile"
    assert_eq "0" "$(sqlite3 "$DISCORD_PROFILES_DB" "SELECT COUNT(*) FROM discord_user_profiles WHERE user_id='fgt_1';")"
    assert_eq "1" "$(sqlite3 "$DISCORD_PROFILES_DB" "SELECT COUNT(*) FROM discord_user_profiles WHERE user_id='keep_2';")"
    assert_eq "0" "$(sqlite3 "$DISCORD_USERS_DB" "SELECT COUNT(*) FROM users WHERE user_id='fgt_1';")"
    assert_eq "1" "$(sqlite3 "$DISCORD_USERS_DB" "SELECT COUNT(*) FROM users WHERE user_id='keep_2';")"
    assert_eq "-5|" "$(sqlite3 "$REPUTATION_DB" "SELECT score, username FROM reputation WHERE user_id='fgt_1';")"
    [ ! -f "$DISCORD_HISTORY_DIR/history_chanA_fgt_1.json" ]; assert_ok $?
    [ -f "$DISCORD_HISTORY_DIR/history_chanA_keep_2.json" ]; assert_ok $?
    assert_eq "keeper" "$(jq -r '[.[].author] | join(",")' "$DISCORD_HISTORY_DIR/history_chanB.json")"

    discord_forget_user "fgt_3" "nice" >/dev/null
    assert_eq "0" "$(sqlite3 "$REPUTATION_DB" "SELECT COUNT(*) FROM reputation WHERE user_id='fgt_3';")"
    discord_forget_user "bad'id" "x" >/dev/null; assert_fail $?
    # Not a forget request: phrase inside a sentence must not trigger
    [[ "please forget me not" =~ ^[[:space:]]*/?[Ff][Oo][Rr][Gg][Ee][Tt][[:space:]]+[Mm][Ee][[:space:]]*$ ]]; assert_fail $?
}

describe "Native Tool Wiring: discord_read"

it "exposes discord_read in social bundle" && {
    tools=$(native_tools_bundle_tools "+social")
    assert_contains "$tools" "discord_read"
}

it "dispatches discord_read through native_tools_dispatch" && {
    api_get_key() { echo "mock_token"; }
    api_require_key() { echo "mock_token"; }

    api_get() {
        echo '[{"author":{"username":"operator_"},"content":"Hello from discord"}]'
    }

    args_json='{"channel": "300000000000000001", "count": 5}'
    resp=$(native_tools_dispatch "call_read_1" "discord_read" "$args_json" "$TEST_TMP")
    assert_ok $?
    assert_contains "$resp" "[operator_] Hello from discord"
}

describe "Conversation memory: channel log"

it "persists across sessions, is injected on turn 1 with channel identity, and other speakers" && {
    export _DISCORD_IN_ACTIVE_PIPE=1 _DISCORD_PIPE_TURN=1
    CH=480000000000000001
    discord_channel_log_append "$CH" "user" "operator" "u_1" "Research the Deflategate mystery"
    discord_channel_log_append "$CH" "assistant" "George" "to:u_1" "Deflategate dossier: the Ideal Gas Law explains most of the PSI drop." "discord_run_x"
    discord_channel_log_append "$CH" "other" "member_user" "u_2" "lol is he still going"
    CAPTURED_GOAL=""
    CAPTURED_CONV=""
    react_run() { CAPTURED_GOAL="$1"; CAPTURED_CONV="${REACT_CONVERSATION_HISTORY:-}"; mkdir -p "$GEORGE_DIR/workspaces/$REACT_SESSION_ID"; echo "Here you go." > "$GEORGE_DIR/workspaces/$REACT_SESSION_ID/final_reply.txt"; }
    discord_generate_response "you never sent the report" "$CH" "operator" "" "" "u_1" "$TEST_TMP/r_mem.txt" >/dev/null
    assert_contains "$CAPTURED_CONV" "Conversation so far in this channel"
    assert_contains "$CAPTURED_CONV" "Deflategate dossier"
    assert_contains "$CAPTURED_CONV" "@member_user"
    assert_contains "$CAPTURED_CONV" "channel id $CH"
    assert_contains "$CAPTURED_CONV" "discord_send (with no target)"
    assert_eq "$CAPTURED_GOAL" "you never sent the report"
    # the request and the reply were both logged
    assert_contains "$(cat "$DISCORD_HISTORY_DIR/channel_$CH.jsonl")" "you never sent the report"
    assert_contains "$(cat "$DISCORD_HISTORY_DIR/channel_$CH.jsonl")" "Here you go."
}

it "prunes entries past the TTL and /forget me removes the user's lines and replies to them" && {
    CH=480000000000000002
    f="$DISCORD_HISTORY_DIR/channel_$CH.jsonl"
    printf '%s\n' '{"ts":1000,"role":"user","author":"old","author_id":"u_9","text":"ancient","run_id":""}' > "$f"
    discord_channel_log_append "$CH" "user" "forgetme2" "fg_2" "my secret plan"
    discord_channel_log_append "$CH" "assistant" "George" "to:fg_2" "about your secret plan" "r1"
    discord_channel_log_append "$CH" "user" "keeper" "kp_2" "hello"
    assert_not_contains "$(cat "$f")" "ancient"
    discord_forget_user "fg_2" "forgetme2" >/dev/null
    assert_not_contains "$(cat "$f")" "secret plan"
    assert_contains "$(cat "$f")" "hello"
}

describe "In-channel delivery (discord_send inside a Discord run)"

it "routes empty/'here'/the author's name to the current channel, never a DM" && {
    api_get_key() { echo "mock_token"; }
    api_require_key() { echo "mock_token"; }
    sleep() { :; }
    POSTED_URLS="$TEST_TMP/posted_urls.log"; : > "$POSTED_URLS"
    api_post() { echo "$1" >> "$POSTED_URLS"; export _API_LAST_BODY='{"id":"123450000000000001"}' _API_LAST_STATUS=200; echo "$_API_LAST_BODY"; return 0; }
    export _DISCORD_IN_SESSION=1 _DISCORD_CURRENT_CHANNEL=480000000000000003 _DISCORD_CURRENT_AUTHOR=member_user _DISCORD_CURRENT_AUTHOR_ID=222000000000000002
    export DISCORD_RUN_OUTBOX="$TEST_TMP/outbox_a.jsonl"; rm -f "$DISCORD_RUN_OUTBOX"
    for tgt in "" "here" "member_user" "@member_user"; do
        resp=$(native_tools_dispatch "c_$RANDOM" "discord_send" "$(jq -nc --arg t "$tgt" '{target:$t, message:"almost done, two more sources to check"}')" "$TEST_TMP")
        assert_contains "$resp" "Posted in this conversation"
    done
    assert_eq "4" "$(grep -c 'channels/480000000000000003/messages' "$POSTED_URLS")"
    assert_not_contains "$(cat "$POSTED_URLS")" "users/@me/channels"
    assert_eq "4" "$(discord_outbox_count)"
    # another user's name in a public channel stays in the channel, with an @mention
    out=$(discord_session_target "someoneelse"); assert_contains "$out" "@someoneelse"
    # explicit dm: is still a DM (normal resolution)
    discord_session_target "dm:operator" >/dev/null; assert_fail $?
    unset _DISCORD_IN_SESSION _DISCORD_CURRENT_CHANNEL _DISCORD_CURRENT_AUTHOR _DISCORD_CURRENT_AUTHOR_ID
}

it "discord_edit edits only George's own message from this run" && {
    export _DISCORD_IN_SESSION=1 _DISCORD_CURRENT_CHANNEL=480000000000000003
    export DISCORD_RUN_OUTBOX="$TEST_TMP/outbox_b.jsonl"; rm -f "$DISCORD_RUN_OUTBOX"
    EDITS="$TEST_TMP/edits.log"; : > "$EDITS"
    _ds_api() { echo "$1 $2" >> "$EDITS"; echo '{}'; return 0; }
    resp=$(native_tools_dispatch "e1" "discord_edit" '{"message":"final answer"}' "$TEST_TMP")
    assert_contains "$resp" "No message from this run"
    discord_outbox_record 480000000000000003 555000000000000001 "working on it…" send
    resp=$(native_tools_dispatch "e2" "discord_edit" '{"message":"final answer"}' "$TEST_TMP")
    assert_contains "$resp" "Edited message 555000000000000001"
    assert_contains "$(cat "$EDITS")" "PATCH /channels/480000000000000003/messages/555000000000000001"
    resp=$(native_tools_dispatch "e3" "discord_edit" '{"message":"x","message_id":"999000000000000009"}' "$TEST_TMP")
    assert_contains "$resp" "was not posted by this run"
    unset _DISCORD_IN_SESSION _DISCORD_CURRENT_CHANNEL DISCORD_RUN_OUTBOX
    unset -f _ds_api; unset _LIB_DISCORD_STATUS_LOADED; source "$LODGE_DIR/lib/comms/discord_status.sh" 2>/dev/null
}

describe "Final reply hygiene"

it "skips a final reply that repeats what the run already posted, and strips delivery narration" && {
    CH=480000000000000003
    react_run() {
        local ws="$GEORGE_DIR/workspaces/$REACT_SESSION_ID"; mkdir -p "$ws"
        discord_outbox_record "$CH" 600000000000000001 "Deflategate dossier: Wells Report, Ideal Gas Law, PSI readings at halftime, Exponent analysis" send
        printf '%s\n' "Deflategate dossier: Wells Report, Ideal Gas Law, PSI readings at halftime." "*Message delivered to @operator via Discord DM.*" > "$ws/final_reply.txt"
    }
    reply=$(discord_generate_response "dossier please" "$CH" "operator" "" "" "u_1" "$TEST_TMP/r_dup.txt")
    assert_empty "$(tr -d '[:space:]' < "$TEST_TMP/r_dup.txt")"
    react_run() {
        local ws="$GEORGE_DIR/workspaces/$REACT_SESSION_ID"; mkdir -p "$ws"
        discord_outbox_record "$CH" 600000000000000002 "Quick status: still reading sources" send
        printf '%s\n' "Final verdict: the footballs lost pressure mostly from temperature." "Action taken: Sent a direct reply to @operator." > "$ws/final_reply.txt"
    }
    discord_generate_response "verdict?" "$CH" "operator" "" "" "u_1" "$TEST_TMP/r_strip.txt" >/dev/null
    assert_contains "$(cat "$TEST_TMP/r_strip.txt")" "Final verdict"
    assert_not_contains "$(cat "$TEST_TMP/r_strip.txt")" "Action taken"
}

it "pipe posts nothing for an empty (already delivered) reply" && {
    SENT="$TEST_TMP/sent.log"; : > "$SENT"
    discord_send() { echo "$1|$2" >> "$SENT"; }
    _discord_pipe_deliver 4800001 0 operator 111 "" ""
    assert_empty "$(cat "$SENT")"
    _discord_pipe_deliver 4800001 0 operator 111 "hello" ""
    assert_contains "$(cat "$SENT")" "<@111> hello"
    unset -f discord_send; unset _LIB_SOCIAL_LOADED; source "$LODGE_DIR/lib/comms/social.sh" 2>/dev/null
}

describe "Pipe: queued messages and steering"

it "groups consecutive messages from one author, skips steered ids, keeps chatter as context" && {
    BOT=999000000000000999; CH=480000000000000004
    raw='[{"id":"100000000000000005","author":{"id":"222","username":"member_user"},"content":"george why so long"},
          {"id":"100000000000000004","author":{"id":"333","username":"rando"},"content":"lol"},
          {"id":"100000000000000003","author":{"id":"111","username":"operator_"},"content":"second"},
          {"id":"100000000000000002","author":{"id":"111","username":"operator_"},"content":"first"},
          {"id":"100000000000000006","author":{"id":"'$BOT'","username":"George"},"content":"bot"}]'
    g=$(_discord_pipe_next_group "$raw" "$BOT" "100000000000000001" "$CH" 0 "111")
    assert_eq "first
second" "$(jq -r '.content' <<<"$g")"
    assert_eq "100000000000000003" "$(jq -r '.last_id' <<<"$g")"
    g=$(_discord_pipe_next_group "$raw" "$BOT" "100000000000000003" "$CH" 0 "111")
    assert_eq "member_user" "$(jq -r '.author' <<<"$g")"
    assert_eq "rando" "$(jq -r '.chatter[0].author' <<<"$g")"
    echo "100000000000000005" > "$DISCORD_SESSIONS_DIR/steered_${CH}.ids"
    g=$(_discord_pipe_next_group "$raw" "$BOT" "100000000000000003" "$CH" 0 "111")
    assert_eq "100000000000000005" "$(jq -r '.skip_to' <<<"$g")"
    assert_empty "$(_discord_pipe_next_group "$raw" "$BOT" "100000000000000006" "$CH" 0 "111")"
}

it "steer watcher injects the author's mid-run message into the running loop" && {
    CH=480000000000000005; WS="$TEST_TMP/ws_steer"; mkdir -p "$WS"; STOP="$TEST_TMP/steer.stop"; rm -f "$STOP"
    _ds_api() {
        echo '[{"id":"700000000000000002","author":{"id":"111","username":"operator_"},"content":"also check the 2015 Exponent report"},
               {"id":"700000000000000003","author":{"id":"333","username":"rando"},"content":"unrelated chatter"}]'
    }
    DISCORD_STEER_INTERVAL=1 discord_steer_watch "$CH" "$WS" "$STOP" "700000000000000001" "111" 0 "999" &
    wpid=$!
    for _i in 1 2 3 4 5 6 7 8; do [ -s "$WS/.guidance_injection" ] && break; command sleep 0.5; done
    touch "$STOP"; wait "$wpid" 2>/dev/null
    assert_contains "$(cat "$WS/.guidance_injection")" "[DISCORD UPDATE"
    assert_contains "$(cat "$WS/.guidance_injection")" "2015 Exponent report"
    assert_not_contains "$(cat "$WS/.guidance_injection")" "unrelated chatter"
    discord_steered_has "$CH" "700000000000000002"; assert_ok $?
    unset -f _ds_api; unset _LIB_DISCORD_STATUS_LOADED; source "$LODGE_DIR/lib/comms/discord_status.sh" 2>/dev/null
}

describe "Interrupted runs"

it "notifies the channel once when a run's process died, including its partial draft" && {
    CH=480000000000000006
    mkdir -p "$GEORGE_DIR/workspaces/discord_run_dead"
    echo "Partial Deflategate findings: PSI drop consistent with temperature." > "$GEORGE_DIR/workspaces/discord_run_dead/best_draft.txt"
    jq -cn --argjson ts "$(date +%s)" '{run_id:"discord_run_dead", author:"operator", author_id:"111", started:$ts, pid:"999999"}' > "$DISCORD_SESSIONS_DIR/active_run_${CH}.json"
    SENT="$TEST_TMP/sent_int.log"; : > "$SENT"
    discord_send() { printf '%s|%s\n' "$1" "$2" >> "$SENT"; return 0; }
    discord_notify_interrupted_runs
    assert_contains "$(cat "$SENT")" "$CH|<@111> sorry"
    assert_contains "$(cat "$SENT")" "Partial Deflategate findings"
    [ ! -f "$DISCORD_SESSIONS_DIR/active_run_${CH}.json" ]; assert_ok $?
    : > "$SENT"; discord_notify_interrupted_runs; assert_empty "$(cat "$SENT")"
    unset -f discord_send; unset _LIB_SOCIAL_LOADED; source "$LODGE_DIR/lib/comms/social.sh" 2>/dev/null
}

describe "Loop: deliverable carry-forward"

it "delivers the earlier draft when the final answer only points 'above'" && {
    SD="$TEST_TMP/sd_cf"; mkdir -p "$SD"
    draft=$(printf 'Deflategate dossier line %s. ' $(seq 1 60))
    _react_note_draft "$SD" "$draft"
    out=$(_react_carry_forward "$SD" "The dossier is already on the table above.")
    assert_contains "$out" "Deflategate dossier line 60"
    assert_contains "$out" "already on the table"
    out=$(_react_carry_forward "$SD" "$(printf 'A completely new and complete answer %s. ' $(seq 1 80))")
    assert_not_contains "$out" "Deflategate dossier line"
    touch "$SD/best_draft.posted"
    out=$(_react_carry_forward "$SD" "See above.")
    assert_eq "See above." "$out"
}

describe "Egress Sanitization & Thought Leak Suppression"

it "strips inline and multiline think blocks cleanly from discord egress" && {
    raw="<think>Evaluating user question about Cardano DEX.</think>The current ADA/DJED pool ratio is 1.05."
    sanitized=$(discord_sanitize_egress "$raw")
    assert_not_contains "$sanitized" "Evaluating user question"
    assert_contains "$sanitized" "The current ADA/DJED pool ratio is 1.05."

    raw_multi=$(printf '<think>\nInternal chain of thought step 1\nStep 2\n</think>\nHere is the answer.')
    sanitized_multi=$(discord_sanitize_egress "$raw_multi")
    assert_not_contains "$sanitized_multi" "Internal chain of thought"
    assert_contains "$sanitized_multi" "Here is the answer."
}

it "strips orphan thought streams ending with closing tag" && {
    raw_orphan="Unfiltered internal deliberation preceding think tag</think>Hello operator!"
    sanitized_orphan=$(discord_sanitize_egress "$raw_orphan")
    assert_not_contains "$sanitized_orphan" "Unfiltered internal deliberation"
    assert_contains "$sanitized_orphan" "Hello operator!"
}

test_end
