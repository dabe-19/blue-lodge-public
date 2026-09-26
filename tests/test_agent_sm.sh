#!/bin/bash
# ── Tests: Sovereign POSIX State Machine & Clone Management Engine ────

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mqtt.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/fifo_ipc.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/task_sync.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agent_sm.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/sentinel.sh" 2>/dev/null || true

TEST_TMP=$(mktemp -d /tmp/george-agent-sm-test-XXXXXX)
export GEORGE_DIR="$TEST_TMP/.george"
export SENTINEL_DIR="$GEORGE_DIR/sentinel"
export SENTINEL_STATE="$SENTINEL_DIR/state.json"
export SENTINEL_HISTORY="$SENTINEL_DIR/history.jsonl"
export SENTINEL_LOG="$SENTINEL_DIR/sentinel.log"
export FIFO_IPC_DIR="$GEORGE_DIR/ipc"
export AGENT_SM_REGISTRY="$GEORGE_DIR/agents_sm.json"

cleanup() {
    # Cull any spawned test worktrees
    git -C "$LODGE_DIR" worktree list 2>/dev/null | grep "$TEST_TMP" | awk '{print $1}' | while read -r wt; do
        git -C "$LODGE_DIR" worktree remove --force "$wt" 2>/dev/null || true
    done
    rm -rf "$TEST_TMP" 2>/dev/null || true
}
trap cleanup EXIT

test_start "POSIX State Machine & Autonomous Clone Management Engine"

describe "agent_sm_register & agent_sm_transition"

it "registers a new agent with SPAWNED state and opens FIFO channel" && {
    agent_sm_init "$GEORGE_DIR"
    agent_sm_register "clone_test_01" "george_clone" "Fix merge conflict" 18080 "george_primary"
    assert_ok $?

    assert_file_exists "$AGENT_SM_REGISTRY"
    reg=$(cat "$AGENT_SM_REGISTRY")
    st=$(echo "$reg" | jq -r '.[] | select(.agent_id == "clone_test_01") | .state')
    assert_eq "$st" "SPAWNED"

    fifo_channel_is_open "clone_test_01"
    assert_ok $?
}

it "transitions state cleanly across lifecycle states" && {
    agent_sm_transition "clone_test_01" "READY" "Worktree ready"
    assert_ok $?
    st1=$(jq -r '.[] | select(.agent_id == "clone_test_01") | .state' "$AGENT_SM_REGISTRY")
    assert_eq "$st1" "READY"

    agent_sm_transition "clone_test_01" "RUNNING" "Executing task"
    assert_ok $?
    st2=$(jq -r '.[] | select(.agent_id == "clone_test_01") | .state' "$AGENT_SM_REGISTRY")
    assert_eq "$st2" "RUNNING"
}

it "updates heartbeat timestamp on agent_sm_heartbeat" && {
    hb_before=$(jq -r '.[] | select(.agent_id == "clone_test_01") | .last_heartbeat' "$AGENT_SM_REGISTRY")
    sleep 1
    agent_sm_heartbeat "clone_test_01"
    assert_ok $?
    hb_after=$(jq -r '.[] | select(.agent_id == "clone_test_01") | .last_heartbeat' "$AGENT_SM_REGISTRY")
    [ "$hb_after" -ge "$hb_before" ]
    assert_ok $?
}

describe "Flow Control: PAUSE & RESUME"

it "pauses clone execution and sets state to FLOW_PAUSED" && {
    agent_sm_flow_control "clone_test_01" "PAUSE"
    assert_ok $?

    st=$(jq -r '.[] | select(.agent_id == "clone_test_01") | .state' "$AGENT_SM_REGISTRY")
    assert_eq "$st" "FLOW_PAUSED"

    bp=$(jq -r '.backpressure' "$FIFO_IPC_DIR/channels/clone_test_01/state.json")
    assert_eq "$bp" "true"
}

it "resumes clone execution and transitions state back to RUNNING" && {
    agent_sm_flow_control "clone_test_01" "RESUME"
    assert_ok $?

    st=$(jq -r '.[] | select(.agent_id == "clone_test_01") | .state' "$AGENT_SM_REGISTRY")
    assert_eq "$st" "RUNNING"

    bp=$(jq -r '.backpressure' "$FIFO_IPC_DIR/channels/clone_test_01/state.json")
    assert_eq "$bp" "false"
}

describe "Clone Worktree Provisioning & Async Execution"

it "spawns clone in sandbox and awaits successful completion" && {
    clone_id="clone_exec_$(date +%s)"
    agent_sm_spawn_clone "$clone_id" "echo 'clone executed successfully' > result.txt; exit 0" 18080 "george_primary"
    assert_ok $?

    agent_sm_await "$clone_id" 10
    assert_ok $?

    st=$(jq -r --arg cid "$clone_id" '.[] | select(.agent_id == $cid) | .state' "$AGENT_SM_REGISTRY")
    assert_eq "$st" "COMPLETED"

    # Clean up worktree
    agent_sm_cull "$clone_id" "Test completion cleanup"
    assert_ok $?
}

describe "Sentinel Orphan Detection & Culling"

it "detects dead processes as orphans in agent_sm_probe_orphans" && {
    dead_clone="clone_dead_$(date +%s)"
    agent_sm_register "$dead_clone" "george_clone" "Dead worker test" 18080 "george_primary"
    agent_sm_transition "$dead_clone" "RUNNING" "Started"
    
    # Assign non-existent PID (e.g., 999999)
    agent_sm_set_pid "$dead_clone" 999999

    orphans=$(agent_sm_probe_orphans 60)
    has_dead=$(echo "$orphans" | jq --arg cid "$dead_clone" '[.[] | select(.agent_id == $cid and .reason == "PROCESS_DEAD")] | length')
    assert_eq "$has_dead" "1"
}

it "sentinel_probe flags dead clone and sentinel_self_heal autonomously culls it" && {
    probe=$(sentinel_probe)
    
    # Verify anomaly and action needed
    has_anom=$(echo "$probe" | jq --arg cid "$dead_clone" '[.anomalies[] | select(contains($cid))] | length')
    [ "$has_anom" -ge 1 ]
    assert_ok $?

    has_act=$(echo "$probe" | jq --arg cid "$dead_clone" '[.actions_needed[] | select(contains($cid))] | length')
    [ "$has_act" -ge 1 ]
    assert_ok $?

    # Self-heal
    heal_out=$(sentinel_self_heal "$probe")
    assert_ok $?

    # Verify state transitioned to CULLED
    st=$(jq -r --arg cid "$dead_clone" '.[] | select(.agent_id == $cid) | .state' "$AGENT_SM_REGISTRY")
    assert_eq "$st" "CULLED"

    # Verify FIFO channel was closed
    fifo_channel_is_open "$dead_clone"
    assert_fail $?
}

test_end
