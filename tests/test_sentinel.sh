#!/bin/bash
# ── Tests: Sentinel Watchdog & Visual Autonomic Sweeper ─────────────

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/endpoints.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agents/sentinel.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/sys/cron.sh" 2>/dev/null || true
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

describe "sentinel_probe task heartbeat severity"

export TELEMETRY_ACTIVE_DIR="$TEST_TMP/telemetry_active"
_seed_task() { # <id> <pid> <age_s>
    mkdir -p "$TELEMETRY_ACTIVE_DIR"
    jq -n --arg id "$1" --argjson pid "$2" --argjson hb "$(( $(date +%s) - $3 ))" \
        '{task_id:$id, pid:$pid, pty_pid:0, heartbeat_ts:$hb, last_tool:"bash_exec", turn:3, max_turns:30}' \
        > "$TELEMETRY_ACTIVE_DIR/$1.json"
}

it "live task stalled below hard-kill is advisory only (no anomaly, no reap)" && {
    rm -rf "$TELEMETRY_ACTIVE_DIR"; sleep 300 & live_pid=$!
    _seed_task stall_adv "$live_pid" 500
    res=$(sentinel_probe)
    assert_contains "$(echo "$res" | jq -c '.advisories')" "TASK_STALL: Task stall_adv"
    assert_not_contains "$(echo "$res" | jq -c '.anomalies')" "stall_adv"
    assert_not_contains "$(echo "$res" | jq -c '.actions_needed')" "REAP_DEAD_TASK_stall_adv"
    kill "$live_pid" 2>/dev/null
}

it "live task past SENTINEL_STALL_HARD_KILL_SEC is reaped" && {
    rm -rf "$TELEMETRY_ACTIVE_DIR"; sleep 300 & live_pid=$!
    _seed_task stall_hard "$live_pid" 1000
    res=$(sentinel_probe)
    assert_contains "$(echo "$res" | jq -c '.anomalies')" "TASK_DEAD_PID: Task stall_hard"
    assert_contains "$(echo "$res" | jq -c '.actions_needed')" "REAP_DEAD_TASK_stall_hard"
    assert_eq "$(echo "$res" | jq -r '.status')" "DEGRADED"
    kill "$live_pid" 2>/dev/null
}

it "honors a lowered SENTINEL_STALL_HARD_KILL_SEC" && {
    rm -rf "$TELEMETRY_ACTIVE_DIR"; sleep 300 & live_pid=$!
    _seed_task stall_cfg "$live_pid" 500
    res=$(SENTINEL_STALL_HARD_KILL_SEC=450 sentinel_probe)
    assert_contains "$(echo "$res" | jq -c '.actions_needed')" "REAP_DEAD_TASK_stall_cfg"
    kill "$live_pid" 2>/dev/null
}

it "dead task PID is still flagged and reaped" && {
    rm -rf "$TELEMETRY_ACTIVE_DIR"
    sleep 0 & dead_pid=$!; wait "$dead_pid" 2>/dev/null
    _seed_task stall_dead "$dead_pid" 200
    res=$(sentinel_probe)
    assert_contains "$(echo "$res" | jq -c '.anomalies')" "TASK_DEAD_PID: Task stall_dead"
    assert_contains "$(echo "$res" | jq -c '.actions_needed')" "REAP_DEAD_TASK_stall_dead"
    rm -rf "$TELEMETRY_ACTIVE_DIR"
}

describe "sentinel_sweep exit codes"

it "returns 0 when only advisories are present" && {
    (
        sentinel_sweep_remediated_issues() { :; }
        sentinel_probe() { echo '{"status":"HEALTHY","gpu":{},"slots":{"slot0":{},"slot1":{}},"anomalies":[],"advisories":["TASK_STALL: Task x stalled"],"actions_needed":[]}'; }
        sentinel_sweep >/dev/null 2>&1
    )
    assert_eq "$?" "0"
}

it "returns 1 when actionable anomalies remain unresolved" && {
    (
        sentinel_sweep_remediated_issues() { :; }
        sentinel_self_heal() { :; }
        sentinel_triage_tier2() { echo "issue_test"; }
        sentinel_probe() { echo '{"status":"DEGRADED","gpu":{},"slots":{"slot0":{},"slot1":{}},"anomalies":["TASK_DEAD_PID: Task y"],"advisories":[],"actions_needed":[]}'; }
        sentinel_sweep >/dev/null 2>&1
    )
    assert_eq "$?" "1"
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

it "autonomously reaps completed sandboxes older than TTL" && {
    dummy_sb="$TEST_TMP/sub_test_ttl_$$"
    mkdir -p "$dummy_sb"
    touch "$dummy_sb/.done"
    echo "Complete" > "$dummy_sb/.phase"
    touch -d "2 hours ago" "$dummy_sb"

    mock_probe=$(jq -n --arg sb "$dummy_sb" '{
        status: "DEGRADED",
        actions_needed: ["PRUNE_SANDBOX_" + $sb],
        anomalies: ["STALE_SANDBOX: Completed sandbox sub_test_ttl aged 7200s"]
    }')

    healed=$(sentinel_self_heal "$mock_probe")
    assert_contains "$healed" "Autonomously reaped stale completed sandbox"
    [ ! -d "$dummy_sb" ]
    assert_ok $?
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
