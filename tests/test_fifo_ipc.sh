#!/bin/bash
# ── Tests: POSIX FIFO Async/Await & Flow Control Engine ──────────────

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/fifo_ipc.sh"

TEST_TMP=$(mktemp -d /tmp/george-fifo-test-XXXXXX)
export GEORGE_DIR="$TEST_TMP/.george"
export FIFO_IPC_DIR="$GEORGE_DIR/ipc"

cleanup() {
    rm -rf "$TEST_TMP" 2>/dev/null || true
}
trap cleanup EXIT

test_start "POSIX FIFO Async/Await & Flow Control Engine"

describe "fifo_channel_open & close"

it "creates named FIFOs and state file" && {
    fifo_channel_open "test_chan_1" 3
    assert_ok $?

    [ -p "$FIFO_IPC_DIR/channels/test_chan_1/data.fifo" ]
    assert_ok $?
    [ -p "$FIFO_IPC_DIR/channels/test_chan_1/ctrl.fifo" ]
    assert_ok $?
    assert_file_exists "$FIFO_IPC_DIR/channels/test_chan_1/state.json"

    fifo_channel_is_open "test_chan_1"
    assert_ok $?

    st=$(jq -r '.status' "$FIFO_IPC_DIR/channels/test_chan_1/state.json")
    assert_eq "$st" "OPEN"

    win=$(jq -r '.window_size' "$FIFO_IPC_DIR/channels/test_chan_1/state.json")
    assert_eq "$win" "3"
}

it "closes and cleans up channel" && {
    fifo_channel_close "test_chan_1"
    assert_ok $?

    fifo_channel_is_open "test_chan_1"
    assert_fail $?
}

describe "fifo_flow_control & credit windowing"

it "decrements credit upon acquire and replenishes on grant" && {
    fifo_channel_open "test_chan_flow" 2
    
    # Initial credits = 2
    c0=$(jq -r '.credits' "$FIFO_IPC_DIR/channels/test_chan_flow/state.json")
    assert_eq "$c0" "2"

    # Acquire 1 credit
    fifo_flow_acquire "test_chan_flow" 2
    assert_ok $?
    c1=$(jq -r '.credits' "$FIFO_IPC_DIR/channels/test_chan_flow/state.json")
    assert_eq "$c1" "1"

    # Acquire 2nd credit
    fifo_flow_acquire "test_chan_flow" 2
    assert_ok $?
    c2=$(jq -r '.credits' "$FIFO_IPC_DIR/channels/test_chan_flow/state.json")
    assert_eq "$c2" "0"

    # Grant 2 credits back
    fifo_flow_grant "test_chan_flow" 2
    assert_ok $?
    c3=$(jq -r '.credits' "$FIFO_IPC_DIR/channels/test_chan_flow/state.json")
    assert_eq "$c3" "2"

    fifo_channel_close "test_chan_flow"
}

it "pauses and resumes flow control on PAUSE/RESUME signals" && {
    fifo_channel_open "test_chan_pause" 5

    fifo_flow_send_ctrl "test_chan_pause" "PAUSE"
    bp=$(jq -r '.backpressure' "$FIFO_IPC_DIR/channels/test_chan_pause/state.json")
    assert_eq "$bp" "true"

    fifo_flow_send_ctrl "test_chan_pause" "RESUME"
    bp2=$(jq -r '.backpressure' "$FIFO_IPC_DIR/channels/test_chan_pause/state.json")
    assert_eq "$bp2" "false"

    fifo_channel_close "test_chan_pause"
}

describe "fifo_write_frame & fifo_read_frame"

it "streams JSON frames through FIFO with automatic sequence numbers" && {
    fifo_channel_open "test_stream" 5

    fifo_write_frame "test_stream" '{"action":"SYNC_TEST","val":42}' 2
    assert_ok $?

    frame=$(fifo_read_frame "test_stream" 2 1)
    assert_ok $?
    assert_contains "$frame" "SYNC_TEST"
    assert_contains "$frame" "42"

    fifo_channel_close "test_stream"
}

describe "fifo_async & fifo_await"

it "executes command asynchronously and awaits resolution" && {
    fifo_channel_open "test_async_chan" 5

    # Run background job via fifo_async
    prom=$(fifo_async "test_async_chan" "echo 'ASYNC_OUTPUT_READY'; exit 0")
    assert_ok $?
    [ -n "$prom" ]
    assert_ok $?

    # Verify promise manifest exists
    assert_file_exists "$FIFO_IPC_DIR/promises/${prom}.json"

    # Await completion
    out=$(fifo_await "$prom" 5)
    ec=$?
    assert_eq "$ec" "0"
    assert_contains "$out" "ASYNC_OUTPUT_READY"

    fifo_channel_close "test_async_chan"
}

it "handles non-zero exit code resolution cleanly" && {
    fifo_channel_open "test_fail_chan" 5

    prom=$(fifo_async "test_fail_chan" "echo 'FAIL_TRIGGERED' >&2; exit 42")
    assert_ok $?

    out=$(fifo_await "$prom" 5 2>&1)
    ec=$?
    assert_eq "$ec" "42"
    assert_contains "$out" "FAIL_TRIGGERED"

    fifo_channel_close "test_fail_chan"
}

it "detects prematurely killed background process without hanging" && {
    fifo_channel_open "test_kill_chan" 5

    prom=$(fifo_async "test_kill_chan" "sleep 10; exit 0")
    assert_ok $?

    bg_pid=$(jq -r '.pid' "$FIFO_IPC_DIR/promises/${prom}.json")
    [ -n "$bg_pid" ] && kill -9 "$bg_pid" 2>/dev/null || true

    start_t=$(date +%s)
    out=$(fifo_await "$prom" 5 2>&1)
    ec=$?
    end_t=$(date +%s)
    dur=$((end_t - start_t))

    assert_eq "$ec" "137"
    [ "$dur" -lt 3 ]
    assert_ok $?

    fifo_channel_close "test_kill_chan"
}

describe "hardened multi-turn flow control & barrier primitives"

it "validates JSON frames with fifo_validate_frame" && {
    fifo_validate_frame '{"key": "value", "seq": 1}'
    assert_ok $?

    fifo_validate_frame 'not valid json'
    assert_fail $?
}

it "flushes channel and restores credits with fifo_channel_flush" && {
    fifo_channel_open "test_flush_chan" 3
    # deplete credits
    fifo_flow_acquire "test_flush_chan" 2
    fifo_flow_acquire "test_flush_chan" 2
    fifo_flow_acquire "test_flush_chan" 2
    c=$(jq -r '.credits' "$FIFO_IPC_DIR/channels/test_flush_chan/state.json")
    assert_eq "$c" "0"

    fifo_channel_flush "test_flush_chan"
    assert_ok $?

    c2=$(jq -r '.credits' "$FIFO_IPC_DIR/channels/test_flush_chan/state.json")
    assert_eq "$c2" "3"
    fifo_channel_close "test_flush_chan"
}

it "auto-unsticks wedged channel via fifo_flow_unstick" && {
    fifo_channel_open "test_unstick_chan" 4
    fifo_flow_send_ctrl "test_unstick_chan" "PAUSE"
    bp=$(jq -r '.backpressure' "$FIFO_IPC_DIR/channels/test_unstick_chan/state.json")
    assert_eq "$bp" "true"

    fifo_flow_unstick "test_unstick_chan"
    assert_ok $?

    bp2=$(jq -r '.backpressure' "$FIFO_IPC_DIR/channels/test_unstick_chan/state.json")
    assert_eq "$bp2" "false"
    c=$(jq -r '.credits' "$FIFO_IPC_DIR/channels/test_unstick_chan/state.json")
    assert_eq "$c" "4"
    fifo_channel_close "test_unstick_chan"
}

it "safely bounds oversized payloads via FIFO_MAX_PAYLOAD_BYTES" && {
    fifo_channel_open "test_bound_chan" 5
    export FIFO_MAX_PAYLOAD_BYTES=100

    huge_payload=$(python3 -c "import json; print(json.dumps({'data': 'X' * 500}))")
    fifo_write_frame "test_bound_chan" "$huge_payload" 2
    assert_ok $?

    read_back=$(fifo_read_frame "test_bound_chan" 2 1)
    assert_ok $?
    assert_contains "$read_back" "truncated"
    assert_contains "$read_back" "true"

    export FIFO_MAX_PAYLOAD_BYTES=67108864
    fifo_channel_close "test_bound_chan"
}

it "awaits multiple promises concurrently with fifo_await_all" && {
    fifo_channel_open "test_barrier_chan" 5

    p1=$(fifo_async "test_barrier_chan" "sleep 0.2; echo PROMISE_ONE")
    p2=$(fifo_async "test_barrier_chan" "sleep 0.3; echo PROMISE_TWO")
    p3=$(fifo_async "test_barrier_chan" "sleep 0.1; echo PROMISE_THREE")

    fifo_await_all "$p1" "$p2" "$p3" 10
    assert_ok $?

    # Verify all resolved
    s1=$(jq -r '.status' "$FIFO_IPC_DIR/promises/${p1}.json")
    s2=$(jq -r '.status' "$FIFO_IPC_DIR/promises/${p2}.json")
    s3=$(jq -r '.status' "$FIFO_IPC_DIR/promises/${p3}.json")
    assert_eq "$s1" "RESOLVED"
    assert_eq "$s2" "RESOLVED"
    assert_eq "$s3" "RESOLVED"

    fifo_channel_close "test_barrier_chan"
}

it "fails fast in fifo_await_all when any promise fails" && {
    fifo_channel_open "test_barrier_fail" 5

    p_ok=$(fifo_async "test_barrier_fail" "sleep 1; exit 0")
    p_bad=$(fifo_async "test_barrier_fail" "sleep 0.1; exit 19")

    fifo_await_all "$p_ok" "$p_bad" 5
    ec=$?
    assert_eq "$ec" "19"

    fifo_channel_close "test_barrier_fail"
}

describe "Sovereign POSIX Agentic Protocol v3 Extensions"

it "transmits and receives OKF NDJSON standard frames with ipc_send & ipc_recv" && {
    ipc_channel_open "test_v3_proto" 5

    test_uuid="a1b2c3d4-0000-4000-8000-000000000001"
    ipc_send "test_v3_proto" "AGENT_DISPATCH" '{"task":"codegen","difficulty":5}' "$test_uuid" 5
    assert_ok $?

    frame=$(ipc_recv "test_v3_proto" 5)
    assert_ok $?

    # Verify OKF frame envelope attributes
    assert_contains "$frame" '"type":"AGENT_DISPATCH"'
    assert_contains "$frame" '"channel":"test_v3_proto"'
    assert_contains "$frame" "$test_uuid"
    assert_contains "$frame" '"task":"codegen"'
    assert_contains "$frame" '"difficulty":5'

    ipc_channel_close "test_v3_proto"
}

it "filters incoming frames by type and UUID correlation" && {
    ipc_channel_open "test_v3_filter" 5

    u1="11111111-1111-4111-8111-111111111111"
    u2="22222222-2222-4222-8222-222222222222"

    ipc_send "test_v3_filter" "MSG_IGNORED" '{"val":1}' "$u1" 2
    ipc_send "test_v3_filter" "MSG_TARGET"  '{"val":2}' "$u2" 2

    # Receive with filter for MSG_TARGET and u2
    matched=$(ipc_recv "test_v3_filter" 5 "MSG_TARGET" "$u2")
    assert_ok $?
    assert_contains "$matched" "MSG_TARGET"
    assert_contains "$matched" "$u2"
    assert_contains "$matched" '"val":2'

    ipc_channel_close "test_v3_filter"
}

it "transparently spills over and hydrates large payloads exceeding PIPE_BUF" && {
    ipc_channel_open "test_v3_spill" 5

    # Generate payload > 4000 bytes
    large_payload=$(python3 -c "import json; print(json.dumps({'large_vector': 'A' * 4500}))")
    spill_uuid="99999999-9999-4999-8999-999999999999"

    ipc_send "test_v3_spill" "LARGE_DATA" "$large_payload" "$spill_uuid" 5
    assert_ok $?

    # Verify transparent rehydration
    rehydrated=$(ipc_recv "test_v3_spill" 5)
    assert_ok $?
    assert_contains "$rehydrated" "large_vector"
    assert_contains "$rehydrated" "AAAAAA"
    assert_contains "$rehydrated" "$spill_uuid"

    ipc_channel_close "test_v3_spill"
}

it "cancels running async promise and reaps background process group" && {
    ipc_channel_open "test_v3_cancel" 5

    prom=$(ipc_async "test_v3_cancel" "sleep 10")
    assert_ok $?

    # Small pause to ensure process spawned
    sleep 0.1

    # Cancel task
    ipc_cancel "$prom" "SIGTERM"
    assert_ok $?

    # Verify promise manifest reflects CANCELED
    st=$(jq -r '.status' "$FIFO_IPC_DIR/promises/${prom}.json")
    ec=$(jq -r '.exit_code' "$FIFO_IPC_DIR/promises/${prom}.json")
    assert_eq "$st" "CANCELED"
    assert_eq "$ec" "125"

    ipc_channel_close "test_v3_cancel"
}

it "monadically chains promises with ipc_pipe" && {
    ipc_channel_open "test_v3_pipe" 5

    p1=$(ipc_async "test_v3_pipe" "printf 'CHAINED_INPUT'")
    assert_ok $?

    p2=$(ipc_pipe "$p1" "test_v3_pipe" 'echo "PREFIX_{}_SUFFIX"')
    assert_ok $?

    out2=$(ipc_await "$p2" 10)
    ec2=$?
    assert_eq "$ec2" "0"
    assert_contains "$out2" "PREFIX_CHAINED_INPUT_SUFFIX"

    ipc_channel_close "test_v3_pipe"
}

it "enforces standard errno exit codes on timeouts and aborts" && {
    ipc_channel_open "test_v3_codes" 5

    # Test await timeout -> exit code 124
    p_slow=$(ipc_async "test_v3_codes" "sleep 3")
    set +e
    out=$(ipc_await "$p_slow" 1 2>/dev/null)
    ec_timeout=$?
    set -e
    assert_eq "$ec_timeout" "124"

    ipc_channel_close "test_v3_codes"
}

describe "Sovereign Inference Slot FIFO Lease & Priority Preemption"

it "acquires and releases inference slot 0 lease" && {
    ipc_acquire_inference_lease 50 "test_cron_task" 2
    assert_ok $?

    s_dir=$(ipc_inference_slot_dir)
    assert_file_exists "$s_dir/lease.json"

    holder=$(jq -r '.holder_pid' "$s_dir/lease.json")
    task=$(jq -r '.task_name' "$s_dir/lease.json")
    prio=$(jq -r '.priority' "$s_dir/lease.json")

    assert_eq "$task" "test_cron_task"
    assert_eq "$prio" "50"

    ipc_release_inference_lease "test_cron_task"
    assert_ok $?

    [ ! -f "$s_dir/lease.json" ]
    assert_ok $?
}

it "preempts lower-priority background tasks when higher priority arrives" && {
    s_dir=$(ipc_inference_slot_dir)

    # Low priority remediation task acquires lease
    ipc_acquire_inference_lease 20 "test_remediation_task" 2
    assert_ok $?
    assert_eq "$(jq -r '.task_name' "$s_dir/lease.json")" "test_remediation_task"

    # Interactive prompt (prio 100) preempts remediation (prio 20)
    ipc_acquire_inference_lease 100 "test_interactive_task" 2
    assert_ok $?
    assert_eq "$(jq -r '.task_name' "$s_dir/lease.json")" "test_interactive_task"
    assert_eq "$(jq -r '.priority' "$s_dir/lease.json")" "100"

    # Cleanup
    ipc_release_inference_lease "test_interactive_task"
    assert_ok $?
}

it "correctly detects human operator presence" && {
    assert_fail $(ipc_is_human_present && echo 0 || echo 1)

    # Simulate interactive lock
    mkdir -p "$GEORGE_DIR"
    echo "$$" > "$GEORGE_DIR/interactive.lock"
    ipc_is_human_present
    assert_ok $?

    rm -f "$GEORGE_DIR/interactive.lock"
    assert_fail $(ipc_is_human_present && echo 0 || echo 1)
}

test_end

