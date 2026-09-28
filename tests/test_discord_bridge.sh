#!/bin/bash
# ── Tests: Discord Bot Bridge & Interactive Chat Service ─────────────

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/api.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/social.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/native_tools.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/discord_bridge.sh" 2>/dev/null || true
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
    src=$(grep -n "elapsed.*-ge 120" "$LODGE_DIR/lib/discord_bridge.sh")
    assert_not_empty "$src"
}

describe "discord_bridge_sweep"

it "ignores channels when no new messages arrived beyond last_seen" && {
    sqlite3 "$DISCORD_CHANNELS_DB" "CREATE TABLE channels (name TEXT, channel_id TEXT);"
    sqlite3 "$DISCORD_CHANNELS_DB" "INSERT INTO channels VALUES ('general', '200100');"
    sqlite3 "$DISCORD_USERS_DB" "CREATE TABLE users (username TEXT, user_id TEXT, is_bot INTEGER);"
    sqlite3 "$DISCORD_USERS_DB" "INSERT INTO users VALUES ('dabe', '190628469', 0);"

    echo '{"channels":{"200100":"500","1477077957691576393":"500"}}' > "$DISCORD_LAST_SEEN_FILE"

    api_get_key() { echo "mock_token"; }

    curl() {
        if [[ "$*" == *"/users/@me"* && "$*" != *"/channels"* ]]; then
            echo '{"id":"777","username":"George"}'
        elif [[ "$*" == *"/messages"* ]]; then
            echo '[{"id":"450","author":{"id":"190628469","username":"dabe"},"content":"old message"}]'
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
    discord_history_append "chan_test_99" "user" "dabe" "What is the weather in Appleton?"
    discord_history_append "chan_test_99" "assistant" "George" "It is 61F and cloudy."

    ctx=$(discord_history_get "chan_test_99" 4)
    assert_contains "$ctx" "Recent Conversation Context"
    assert_contains "$ctx" "@dabe: What is the weather in Appleton?"
    assert_contains "$ctx" "George: It is 61F and cloudy."

    discord_history_clear "chan_test_99"
    cleared=$(discord_history_get "chan_test_99" 4)
    assert_empty "$cleared"
}

describe "User Profile Management: discord_profile_get / discord_profile_set"

it "stores and retrieves user location and notes in discord_profiles.db" && {
    discord_bridge_init
    discord_profile_set "user_123" "location" "Appleton, WI"
    discord_profile_set "user_123" "notes" "Operator of Blue Lodge"

    prof=$(discord_profile_get "user_123")
    assert_contains "$prof" "Appleton, WI"
    assert_contains "$prof" "Operator of Blue Lodge"
}

describe "Context Injection Fresh Task Isolation"

it "isolates fresh task turn 1 from past history and includes clean user profile" && {
    export _DISCORD_IN_ACTIVE_PIPE=1
    export _DISCORD_PIPE_TURN=1
    export DISCORD_PROFILES_DB="$GEORGE_DIR/discord_profiles.db"

    # Populate profile
    sqlite3 "$DISCORD_PROFILES_DB" "INSERT OR REPLACE INTO discord_user_profiles (user_id, username, location, notes, interaction_count, updated_at) VALUES ('user_456', 'dabe', 'Appleton, WI', 'Lead Architect', 1, $(date +%s));"

    # Mock react_run to inspect target_goal
    CAPTURED_GOAL=""
    react_run() {
        CAPTURED_GOAL="$1"
        local s_id="${REACT_SESSION_ID:-session_mock}"
        mkdir -p "$LODGE_DIR/.george/workspaces/$s_id"
        echo "Tonight in Appleton, WI it is clear and 55F." > "$LODGE_DIR/.george/workspaces/$s_id/final_reply.txt"
    }

    out_file="$TEST_TMP/reply_iso.txt"
    discord_generate_response "What is the weather like tonight?" "chan_iso_1" "dabe" "" "" "user_456" "$out_file"

    assert_contains "$CAPTURED_GOAL" "Location: Appleton, WI"
    assert_contains "$CAPTURED_GOAL" "What is the weather like tonight?"
    # Must NOT contain old conversation context header
    assert_not_contains "$CAPTURED_GOAL" "Recent Conversation Context"

    reply=$(cat "$out_file")
    assert_contains "$reply" "Appleton, WI"
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
        echo '[{"author":{"username":"dabe_"},"content":"Hello from discord"}]'
    }

    args_json='{"channel": "1477077957691576393", "count": 5}'
    resp=$(native_tools_dispatch "call_read_1" "discord_read" "$args_json" "$TEST_TMP")
    assert_ok $?
    assert_contains "$resp" "[dabe_] Hello from discord"
}

test_end
