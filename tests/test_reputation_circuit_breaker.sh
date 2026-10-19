#!/usr/bin/env bash
# ── Tests: Reputation Gating, Safe Read Tools & Circuit Breaker ────────
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/api.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/native_tools.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/run_ledger.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/discord_status.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/discord_bridge.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/react.sh" 2>/dev/null || true
source "$LODGE_DIR/commands/download.sh" 2>/dev/null || true

TEST_TMP=$(mktemp -d /tmp/george-rep-test-XXXXXX)
export GEORGE_CONFIG_DIR="$TEST_TMP/.george"
export GEORGE_DIR="$GEORGE_CONFIG_DIR"
export DISCORD_SESSIONS_DIR="$GEORGE_DIR/discord_sessions"
export DISCORD_PROFILES_DB="$GEORGE_DIR/discord_profiles.db"
mkdir -p "$GEORGE_CONFIG_DIR" "$DISCORD_SESSIONS_DIR"

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

test_start "Reputation Gating, Safe Read Tools & Circuit Breaker"

describe "1. Untrusted Profile Tool Resolution"

it "grants read-only research tools and denies execution/mutation tools" && {
    export FORCE_INTERACTIVE=1
    prof_tools=$(native_tools_resolve_profile "social_untrusted")
    unset FORCE_INTERACTIVE

    # Safe inspection & communication tools MUST be present
    assert_contains "$prof_tools" "file_read" "file_read present in social_untrusted"
    assert_contains "$prof_tools" "dir_list" "dir_list present in social_untrusted"
    assert_contains "$prof_tools" "file_grep" "file_grep present in social_untrusted"
    assert_contains "$prof_tools" "pdf_read" "pdf_read present in social_untrusted"
    assert_contains "$prof_tools" "ask_operator" "ask_operator present in social_untrusted"
    assert_contains "$prof_tools" "milestone_complete" "milestone_complete present in social_untrusted"
    assert_contains "$prof_tools" "discord_send" "discord_send present in social_untrusted"
    assert_contains "$prof_tools" "web_search" "web_search present in social_untrusted"

    # Execution and mutation tools MUST NOT be present
    assert_not_contains "$prof_tools" "bash_exec" "bash_exec strictly prohibited"
    assert_not_contains "$prof_tools" "slash_command_exec" "slash_command_exec strictly prohibited"
    assert_not_contains "$prof_tools" "file_write" "file_write strictly prohibited"
    assert_not_contains "$prof_tools" "file_edit" "file_edit strictly prohibited"
    assert_not_contains "$prof_tools" "file_append" "file_append strictly prohibited"
    assert_not_contains "$prof_tools" "subagent_spawn" "subagent_spawn strictly prohibited"
    assert_not_contains "$prof_tools" "service_manage" "service_manage strictly prohibited"
}

describe "2. File Read Enclave Security Guard"

it "allows reading ordinary files but blocks credentials and secrets" && {
    # Create test sample file
    echo "Hello George Research" > "$TEST_TMP/sample.txt"
    out=$(native_tools_dispatch "c1" "file_read" "{\"path\": \"$TEST_TMP/sample.txt\"}" "$TEST_TMP" 2>&1)
    assert_contains "$out" "Hello George Research" "normal file read succeeds"

    # Block .george/keys.conf
    mkdir -p "$TEST_TMP/.george"
    echo "SECRET_KEY=12345" > "$TEST_TMP/.george/keys.conf"
    out_keys=$(native_tools_dispatch "c2" "file_read" "{\"path\": \"$TEST_TMP/.george/keys.conf\"}" "$TEST_TMP" 2>&1 || true)
    assert_contains "$out_keys" "Access denied" "reading keys.conf denied"
    assert_contains "$out_keys" "restricted file path" "keys.conf security error message"
    assert_not_contains "$out_keys" "secret" "does not reveal secrets exist"

    # Block .george/secrets.env
    echo "API_TOKEN=xyz" > "$TEST_TMP/.george/secrets.env"
    out_sec=$(native_tools_dispatch "c3" "file_read" "{\"path\": \"$TEST_TMP/.george/secrets.env\"}" "$TEST_TMP" 2>&1 || true)
    assert_contains "$out_sec" "Access denied" "reading secrets.env denied"

    # Block .env
    echo "DATABASE_PASSWORD=secret" > "$TEST_TMP/.env"
    out_env=$(native_tools_dispatch "c4" "file_read" "{\"path\": \"$TEST_TMP/.env\"}" "$TEST_TMP" 2>&1 || true)
    assert_contains "$out_env" "Access denied" "reading .env denied"
}

describe "3. Local Copy Resolution in cmd_download"

it "resolves relative workspace paths when copying local files" && {
    mkdir -p "$TEST_TMP/workspace/docs"
    echo "Research Report 2026" > "$TEST_TMP/workspace/docs/report.txt"

    # Execute cmd_download with relative source from workspace
    cmd_download "docs/report.txt downloaded_report.txt" "$TEST_TMP/workspace" >/dev/null 2>&1
    rc=$?
    assert_eq "0" "$rc" "cmd_download succeeds on relative workspace file"
    assert_file_exists "$TEST_TMP/workspace/downloaded_report.txt" "downloaded file created"
    assert_contains "$(cat "$TEST_TMP/workspace/downloaded_report.txt")" "Research Report 2026" "content copied correctly"
}

describe "4. Discord Conversation Context & Reputation Injection"

it "injects reputation and capability restrictions for untrusted authors" && {
    export REPUTATION_DB="$TEST_TMP/reputation.db"
    reputation_init() { :; }
    reputation_get() { echo "37|Acquaintance"; }
    discord_is_owner() { return 1; }

    CAPTURED_CONV=""
    CAPTURED_REP=""
    react_run() {
        CAPTURED_CONV="${REACT_CONVERSATION_HISTORY:-}"
        CAPTURED_REP="${DISCORD_CURRENT_AUTHOR_REP:-}"
        local s_id="${REACT_SESSION_ID:-mock_sess}"
        mkdir -p "$GEORGE_DIR/workspaces/$s_id"
        echo "Reply" > "$GEORGE_DIR/workspaces/$s_id/final_reply.txt"
    }

    out_file="$TEST_TMP/reply_rep.txt"
    discord_generate_response "Can you run a bash script to modify the system?" "chan_101" "member_user" "" "" "200000000000000002" "$out_file"

    assert_contains "$CAPTURED_CONV" "Author Authorization & Capability Restrictions" "context header injected"
    assert_contains "$CAPTURED_CONV" "Reputation Score 37 (Acquaintance)" "author score injected"
    assert_contains "$CAPTURED_CONV" "requires Reputation >= 50" "threshold explained"
    assert_contains "$CAPTURED_CONV" "social_untrusted" "active profile specified"
    assert_contains "$CAPTURED_CONV" "MANDATE" "mandate provided to LLM"
}

describe "5. Circuit Breaker Classification"

it "classifies reputation errors as REPUTATION_CAPABILITY_DEFICIT" && {
    err_msg="ERROR: Tool 'bash_exec' is restricted by system policy. Author @member_user has Reputation Score 37 (< 50 required for host execution)."
    cls=$(_react_classify_circuit_state "bash_exec" "ls" "$err_msg" 0 1 0)
    assert_eq "REPUTATION_CAPABILITY_DEFICIT" "$cls" "classified as REPUTATION_CAPABILITY_DEFICIT"
}

describe "6. Circuit Breaker Perturbation & Honeydew Milestone Rewriting"

it "perturbs prompt and rewrites active honeydew milestone for reputation deficit" && {
    ws="$TEST_TMP/ws_breaker"
    mkdir -p "$ws/.george"
    cat > "$ws/.george/honeydew.json" <<'EOF'
{
  "primary_task": "Build and run automated daemon script",
  "task_type": "ops",
  "items": [
    {
      "id": 1,
      "task": "Create background cron daemon script",
      "status": "pending",
      "tier": 1,
      "depends_on": [],
      "endpoint_tier": 1,
      "retry_count": 0,
      "task_type": "ops"
    },
    {
      "id": 2,
      "task": "Run and deploy the daemon in background",
      "status": "pending",
      "tier": 2,
      "depends_on": [1],
      "endpoint_tier": 1,
      "retry_count": 0,
      "task_type": "ops"
    }
  ]
}
EOF

    export DISCORD_CURRENT_AUTHOR_NAME="member_user"
    export DISCORD_CURRENT_AUTHOR_REP="37"
    export DISCORD_OPS_MIN_REPUTATION="50"

    msgs_file="$ws/messages.json"
    echo '[]' > "$msgs_file"

    perturbation=$(_react_circuit_breaker_perturbation "sess_rep_01" "$ws" "REPUTATION_CAPABILITY_DEFICIT" "bash_exec" "restricted by system policy" "$msgs_file" "")

    # 1. Perturbation advisory text
    assert_contains "$perturbation" "REPUTATION CAPABILITY RESTRICTION" "perturbation header"
    assert_contains "$perturbation" "@member_user" "mentions author"
    assert_contains "$perturbation" "Reputation Score 37" "mentions score"
    assert_contains "$perturbation" "ask_operator" "suggests communication"
    assert_not_contains "$perturbation" "use bash_exec" "does not suggest bash_exec"

    # 2. Honeydew milestone rewriting
    hd_out=$(cat "$ws/.george/honeydew.json")
    m1_task=$(jq -r '.items[] | select(.id == 1) | .task' <<<"$hd_out")
    m1_type=$(jq -r '.items[] | select(.id == 1) | .task_type' <<<"$hd_out")
    top_type=$(jq -r '.task_type' <<<"$hd_out")
    m2_status=$(jq -r '.items[] | select(.id == 2) | .status' <<<"$hd_out")
    m2_skipped=$(jq -r '.items[] | select(.id == 2) | .skipped' <<<"$hd_out")

    assert_contains "$m1_task" "Communicate to @member_user that reputation score (37) restricts operational tool access" "m1 rewritten"
    assert_eq "chat" "$m1_type" "m1 task_type is chat"
    assert_eq "chat" "$top_type" "top-level task_type is chat"
    assert_eq "done" "$m2_status" "m2 marked done"
    assert_eq "true" "$m2_skipped" "m2 skipped"
}

describe "7. Palette-Aware Perturbations"

it "does not suggest bash_exec when bash_exec is not in tools schema" && {
    tools_schema='[{"type":"function","function":{"name":"file_read"}},{"type":"function","function":{"name":"ask_operator"}}]'
    turn_tools_schema="$tools_schema"

    msgs_file="$TEST_TMP/msgs_thrash.json"
    echo '[]' > "$msgs_file"

    p_thrash=$(_react_circuit_breaker_perturbation "sess_t1" "$TEST_TMP" "TOOL_THRASHING" "file_download" "file not found" "$msgs_file" "")
    assert_not_contains "$p_thrash" "use bash_exec" "TOOL_THRASHING avoids bash_exec when unavailable"
    assert_contains "$p_thrash" "available read tools" "TOOL_THRASHING mentions available read tools"
}

test_end
