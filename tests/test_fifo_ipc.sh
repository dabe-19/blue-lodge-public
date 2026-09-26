#!/bin/bash
# ── Tests: POSIX FIFO Async/Await & Flow Control Engine ──────────────

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/fifo_ipc.sh"

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

test_end
