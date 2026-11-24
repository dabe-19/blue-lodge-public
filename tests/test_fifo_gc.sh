#!/bin/bash
# ── Tests for FIFO-IPC Protocol Garbage Collector & Flowcontrol Reconciliation ──

source "$(dirname "$0")/framework.sh"
source "$(dirname "$0")/../lib/ipc/fifo_ipc.sh"

test_start "FIFO-IPC Protocol Garbage Collector & Queue Reconciliation"

describe "Stale Channel Sweep"
  it "detects and closes idle or crashed channels" && {
    tmp_gc=$(mktemp -d /tmp/george_gc_test_XXXXXX)
    FIFO_IPC_DIR="$tmp_gc"
    ipc_init "$tmp_gc"

    ipc_channel_open "active_chan" 5
    ipc_channel_open "stale_chan" 5

    # Artificially age stale_chan
    state_stale="$tmp_gc/channels/stale_chan/state.json"
    old_ts=$(( $(date +%s) - 500 ))
    jq --argjson ots "$old_ts" '.last_activity = $ots' "$state_stale" > "${state_stale}.tmp" && mv "${state_stale}.tmp" "$state_stale"

    # Run GC with 300s TTL (dry run first)
    dry_res=$(ipc_gc --dry-run --ttl 300)
    assert_contains "$dry_res" '"channels_swept":1'
    assert_dir_exists "$tmp_gc/channels/stale_chan"

    # Actual sweep
    real_res=$(ipc_gc --ttl 300)
    assert_contains "$real_res" '"channels_swept":1'
    [ ! -d "$tmp_gc/channels/stale_chan" ]
    assert_ok $? "stale channel must be removed"
    assert_dir_exists "$tmp_gc/channels/active_chan"

    # Force sweep
    ipc_gc --force >/dev/null
    [ ! -d "$tmp_gc/channels/active_chan" ]
    assert_ok $? "force sweep must remove all channels"

    rm -rf "$tmp_gc"
  }

describe "Flowcontrol Queue Unsticking"
  it "unwedges stalled flowcontrol queues when credits are exhausted and channel is idle" && {
    tmp_gc=$(mktemp -d /tmp/george_gc_test_XXXXXX)
    FIFO_IPC_DIR="$tmp_gc"
    ipc_init "$tmp_gc"

    ipc_channel_open "wedged_chan" 5
    st_file="$tmp_gc/channels/wedged_chan/state.json"
    old_ts=$(( $(date +%s) - 30 ))
    jq --argjson ots "$old_ts" '.credits = 0 | .backpressure = true | .last_activity = $ots' "$st_file" > "${st_file}.tmp" && mv "${st_file}.tmp" "$st_file"

    gc_res=$(ipc_gc --ttl 300)
    assert_contains "$gc_res" '"queues_unwedged":1'

    # Verify channel restored to window size and cleared backpressure
    cred_after=$(jq -r '.credits' "$st_file")
    bp_after=$(jq -r '.backpressure' "$st_file")
    assert_eq "$cred_after" "5"
    assert_eq "$bp_after" "false"

    ipc_channel_close "wedged_chan"
    rm -rf "$tmp_gc"
  }

describe "Promise Lifecycle & Dead Process Reclamation"
  it "reaps dead worker promises and prunes expired outputs" && {
    tmp_gc=$(mktemp -d /tmp/george_gc_test_XXXXXX)
    FIFO_IPC_DIR="$tmp_gc"
    ipc_init "$tmp_gc"

    # Create mock dead running promise
    dead_prom="$tmp_gc/promises/prom_dead_123.json"
    dead_out="$tmp_gc/promises/prom_dead_123.out"
    echo "partial output" > "$dead_out"
    echo '{"promise_id":"prom_dead_123","status":"RUNNING","pid":999999,"started_at":100}' > "$dead_prom"

    # Create mock expired resolved promise
    exp_prom="$tmp_gc/promises/prom_exp_456.json"
    exp_out="$tmp_gc/promises/prom_exp_456.out"
    echo "done output" > "$exp_out"
    old_fin=$(( $(date +%s) - 7200 ))
    echo "{\"promise_id\":\"prom_exp_456\",\"status\":\"RESOLVED\",\"exit_code\":0,\"finished_at\":$old_fin}" > "$exp_prom"

    gc_res=$(ipc_gc --ttl 1800)
    assert_contains "$gc_res" '"promises_pruned":1'

    # Dead running promise should have been marked REJECTED with exit code 137
    dead_st=$(jq -r '.status' "$dead_prom")
    dead_ec=$(jq -r '.exit_code' "$dead_prom")
    assert_eq "$dead_st" "REJECTED"
    assert_eq "$dead_ec" "137"

    # Expired promise should be deleted
    [ ! -f "$exp_prom" ]
    assert_ok $? "expired promise JSON must be deleted"
    [ ! -f "$exp_out" ]
    assert_ok $? "expired promise out file must be deleted"

    rm -rf "$tmp_gc"
  }

describe "Reactive Event Bus Reclamation"
  it "reaps dead event bus PID files and prunes stale cooldowns" && {
    tmp_gc=$(mktemp -d /tmp/george_gc_eb_XXXXXX)
    FIFO_IPC_DIR="$tmp_gc"
    ipc_init "$tmp_gc"
    mkdir -p "$tmp_gc/cooldowns"

    # Create mock dead event_bus.pid
    dead_pid_file="$tmp_gc/event_bus.pid"
    echo "999998" > "$dead_pid_file"

    # Create stale cooldown timestamp (2 hours old)
    old_cd=$(( $(date +%s) - 7200 ))
    echo "$old_cd" > "$tmp_gc/cooldowns/stale_reactor.ts"

    # Create fresh cooldown timestamp (10 seconds old)
    fresh_cd=$(( $(date +%s) - 10 ))
    echo "$fresh_cd" > "$tmp_gc/cooldowns/fresh_reactor.ts"

    gc_res=$(ipc_gc --ttl 1800)
    assert_contains "$gc_res" '"event_bus_reaped":1'

    # Verify dead PID file removed
    [ ! -f "$dead_pid_file" ]
    assert_ok $? "dead event_bus.pid must be reaped"

    # Verify stale cooldown pruned and fresh cooldown kept
    [ ! -f "$tmp_gc/cooldowns/stale_reactor.ts" ]
    assert_ok $? "stale cooldown timestamp must be pruned"

    [ -f "$tmp_gc/cooldowns/fresh_reactor.ts" ]
    assert_ok $? "fresh cooldown timestamp must be preserved"

    rm -rf "$tmp_gc"
  }

test_end
