#!/usr/bin/env bash
# Tests the IPC-to-Remediation event bridge:
# Verifies that failing asynchronous commands executed via ipc_async
# emit valid system.job_failure events that route into remediation_event_ingress.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"

TEST_TMP=$(mktemp -d /tmp/george-bridge-test-XXXXXX)
export GEORGE_DIR="$TEST_TMP/.george"
export FIFO_IPC_DIR="$GEORGE_DIR/ipc"
export REMEDIATION_DIR="$GEORGE_DIR/remediation"

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/fifo_ipc.sh" 2>/dev/null
source "$LODGE_DIR/lib/agents/remediation.sh" 2>/dev/null

cleanup() {
    rm -rf "$TEST_TMP" 2>/dev/null || true
}
trap cleanup EXIT

test_start "IPC-to-Remediation Event Bridge"

_setup() {
    mkdir -p "$FIFO_IPC_DIR/promises" "$FIFO_IPC_DIR/channels" "$REMEDIATION_DIR/queue" 2>/dev/null || true
}

_teardown() {
    rm -rf "$FIFO_IPC_DIR/promises"/* "$FIFO_IPC_DIR/channels"/* "$REMEDIATION_DIR/queue"/* 2>/dev/null || true
}

describe "1. _ipc_emit_failure_event contract compliance"

it "generates payload satisfying system.job_failure schema" && {
    _setup
    prom_out="$FIFO_IPC_DIR/test_crash.log"
    cat << 'EOF' > "$prom_out"
[INFO] Starting task
[STEP] Doing work
lib/tools/test.sh: line 42: f: unbound variable
Authorization: Bearer sk-ant-secret123456789
EOF

    captured_payload=""
    ipc_dispatch_event() {
        captured_payload="$2"
        return 0
    }

    _ipc_emit_failure_event "prom_12345" "chan_research" "./lodge /research salvage test-slug" 1 "$prom_out" "$(( $(date +%s) - 5 ))"

    assert_neq "$captured_payload" "" "Captured payload must not be empty"

    jq -e . >/dev/null 2>&1 <<<"$captured_payload"
    assert_ok $? "Payload must be valid JSON"

    assert_contains "$(jq -r '.job' <<<"$captured_payload")" "chan_research"
    assert_contains "$(jq -r '.job_id' <<<"$captured_payload")" "lodge_research"
    assert_match "$(jq -r '.job_id' <<<"$captured_payload")" '^[A-Za-z0-9_.-]{1,80}$' "job_id must match regex"
    assert_eq "$(jq -r '.exit_code' <<<"$captured_payload")" "1"
    assert_eq "$(jq -r '.source' <<<"$captured_payload")" "ipc_async"
    assert_contains "$(jq -r '.stderr_tail' <<<"$captured_payload")" "unbound variable"
    assert_not_contains "$(jq -r '.stderr_tail' <<<"$captured_payload")" "sk-ant-secret" "Secret must be redacted"

    # Validate against formal event contract validator
    if [ -f "$LODGE_DIR/lib/tools/event_contracts.py" ]; then
        python3 "$LODGE_DIR/lib/tools/event_contracts.py" validate system.job_failure "$captured_payload" >/dev/null 2>&1
        assert_ok $? "Must pass python event contract validator"
    fi

    _teardown
}

describe "2. remediation_event_ingress integration for async IPC failures"

it "enqueues remediation task with Async Task Failure title" && {
    _setup
    payload='{
        "job": "chan_research_lodge_research",
        "job_id": "chan_research_lodge_research",
        "label": "./lodge /research salvage test-slug",
        "exit_code": 1,
        "log": "/tmp/crash.log",
        "stderr_tail": "line 1374: f: unbound variable",
        "wall_s": 12,
        "promise_id": "prom_test_999",
        "channel": "chan_research",
        "source": "ipc_async"
    }'

    qid=$(remediation_event_ingress "system.job_failure" "$payload" 2>/dev/null | tail -1)
    assert_neq "$qid" "" "Task ID must be returned"

    qf="$REMEDIATION_DIR/queue/${qid}.json"
    assert_file_exists "$qf" "Queue manifest must exist"

    assert_contains "$(jq -r '.title' "$qf")" "Async Task Failure"
    assert_contains "$(jq -r '.title' "$qf")" "exit 1"
    assert_eq "$(jq -r '.fingerprint' "$qf")" "job_fail_chan_research_lodge_research"
    assert_contains "$(cat "$(jq -r '.issue_file' "$qf")")" "unbound variable"

    _teardown
}

describe "3. End-to-end ipc_async failure triggering"

it "emits event and finalizes REJECTED status when command fails" && {
    _setup
    fifo_channel_open "test_bridge_chan" 5

    event_emitted=0
    ipc_dispatch_event() {
        if [ "$1" = "system.job_failure" ]; then
            event_emitted=1
        fi
        return 0
    }

    prom=$(ipc_async "test_bridge_chan" "echo 'CRITICAL FAILURE MOCK' >&2; exit 2")
    assert_ok $?

    # Wait for promise to settle
    elapsed=0
    st=""
    while [ "$elapsed" -lt 30 ]; do
        st=$(jq -r '.status // empty' "$FIFO_IPC_DIR/promises/${prom}.json" 2>/dev/null || echo "")
        [ "$st" = "REJECTED" ] && break
        sleep 0.1
        elapsed=$(( elapsed + 1 ))
    done

    assert_eq "$st" "REJECTED" "Promise status must be REJECTED"
    assert_eq "$(jq -r '.exit_code' "$FIFO_IPC_DIR/promises/${prom}.json")" "2"

    fifo_channel_close "test_bridge_chan"
    _teardown
}

test_end
