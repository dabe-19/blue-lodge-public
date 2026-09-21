#!/bin/bash
# ── Tests: Sentinel Watchdog & Visual Autonomic Sweeper ─────────────

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/endpoints.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/sentinel.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/cron.sh" 2>/dev/null || true
source "$LODGE_DIR/commands/cron.sh" 2>/dev/null || true

TEST_TMP=$(mktemp -d /tmp/george-sentinel-test-XXXXXX)
export GEORGE_CONFIG_DIR="$TEST_TMP/.george"
export GEORGE_DIR="$GEORGE_CONFIG_DIR"
export SENTINEL_DIR="$GEORGE_DIR/sentinel"
export SENTINEL_STATE="$SENTINEL_DIR/state.json"
export SENTINEL_HISTORY="$SENTINEL_DIR/history.jsonl"
export SENTINEL_LOG="$SENTINEL_DIR/sentinel.log"

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

test_start "Sentinel Telemetry Watchdog & Visual Autonomic Sweeper"

describe "sentinel_init"

it "initializes sentinel state file and directories" && {
    sentinel_init
    assert_file_exists "$SENTINEL_STATE"
    st=$(jq -r '.status' "$SENTINEL_STATE" 2>/dev/null)
    assert_eq "$st" "HEALTHY"
}

describe "sentinel_probe"

it "probes system vitals and generates structured JSON" && {
    res=$(sentinel_probe)
    echo "$res" | jq -e '.timestamp' >/dev/null
    assert_ok $?
    echo "$res" | jq -e '.status' >/dev/null
    assert_ok $?
    echo "$res" | jq -e '.gpu' >/dev/null
    assert_ok $?
    echo "$res" | jq -e '.slots' >/dev/null
    assert_ok $?
    echo "$res" | jq -e '.anomalies' >/dev/null
    assert_ok $?
}

it "flags stalled slot anomaly when token progress is frozen" && {
    export SENTINEL_SLOT_STALL_CYCLES=2
    # Seed state with cycle 1
    mkdir -p "$SENTINEL_DIR"
    echo '{"last_probe":0,"status":"HEALTHY","anomalies":[],"stalled_slots":{"0":{"cycles":1,"proc":100,"dec":10}}}' > "$SENTINEL_STATE"

    # Mock curl to return slot 0 busy with identical tokens (100 proc, 10 dec)
    curl() {
        if [[ "$*" == *"http://127.0.0.1:8080/slots"* ]]; then
            echo '[{"id":0,"is_processing":true,"id_task":999,"n_prompt_tokens":2000,"n_prompt_tokens_processed":100,"next_token":[{"n_decoded":10}]}]'
            return 0
        fi
        command curl "$@"
    }

    res=$(sentinel_probe)
    assert_contains "$res" "SLOT_0_STAGNATION"
    assert_contains "$res" "DEGRADED"
    unset -f curl
}

describe "sentinel_self_heal"

it "reaps rogue curl processes flagged in actions_needed" && {
    # Start a dummy sleep process to pretend it is a rogue curl
    sleep 300 &
    dummy_pid=$!

    mock_probe=$(jq -n --arg pid "$dummy_pid" '{
        status: "DEGRADED",
        actions_needed: ["KILL_CURL_" + $pid],
        anomalies: ["ORPHAN_CURL_PID_" + $pid]
    }')

    healed=$(sentinel_self_heal "$mock_probe")
    assert_contains "$healed" "Terminated rogue curl process PID $dummy_pid"

    # Verify dummy process is dead
    kill -0 "$dummy_pid" 2>/dev/null
    assert_fail $?
}

describe "sentinel_triage_tier2"

it "records structured markdown issue with telemetry diagnostics" && {
    mock_probe=$(jq -n '{
        status: "DEGRADED",
        gpu: { temp_c: 45, power_w: 30, vram_used_mb: 9300, vram_total_mb: 12288, util_pct: 10 },
        slots: {
            slot0: { busy: true, task_id: 101, processed_tokens: 50, prompt_tokens: 2000 },
            slot1: { busy: false, task_id: "", processed_tokens: 0, prompt_tokens: 0 }
        },
        anomalies: ["SLOT_0_STAGNATION: Task 101 stagnant for 3 cycles"],
        actions_needed: ["REAP_SLOT_0_CLIENT"]
    }')
    # Mock Gitea as offline so test runs do not pollute real issue tracker
    gitea_is_online() { return 1; }

    issue_ref=$(sentinel_triage_tier2 "$mock_probe" "Terminated client PID 99999")
    assert_contains "$issue_ref" "issue_sentinel_"
    assert_file_exists "$issue_ref"

    issue_text=$(cat "$issue_ref")
    assert_contains "$issue_text" "George Autonomic Sentinel Diagnostic Report"
    assert_contains "$issue_text" "SLOT_0_STAGNATION"
    assert_contains "$issue_text" "Autonomous Remediation Executed"
}

describe "cron visual popup integration"

it "detects GUI availability when wt.exe exists and in local session" && {
    if [ -n "${WSL_DISTRO_NAME:-}" ] && command -v wt.exe &>/dev/null; then
        cron_is_gui_available
        assert_ok $?
    fi
}

it "dispatches /cron sentinel and renders vitals" && {
    out=$(cmd_cron "sentinel" 2>&1)
    assert_contains "$out" "George Autonomic Sentinel"
    assert_contains "$out" "Status:"
    assert_contains "$out" "GPU Vitals:"
}

test_end
