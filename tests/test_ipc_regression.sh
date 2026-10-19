#!/bin/bash
# ── Tests: IPC Flow-Control & Event Bus Regression Suite ───────────────
# Locks in the fixes from the FIFO Async-Await IPC review (Phases A–C):
# atomic framing (spill, never truncate), credit window enforcement, PAUSE honoured,
# exact credit accounting, order-preserving filtered recv, exit-code capture,
# injection safety, process-group cancel, first-writer-wins promises, event-bus
# depth propagation / spool replay / overflow policies, config precedence, sync dedupe.

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true

TEST_TMP=$(mktemp -d /tmp/george-ipc-regr-XXXXXX)
export GEORGE_DIR="$TEST_TMP/.george"
export FIFO_IPC_DIR="$GEORGE_DIR/ipc"
export EVENT_BUS_DIR="$FIFO_IPC_DIR"
export EVENT_BUS_FIFO="$FIFO_IPC_DIR/event_bus.fifo"
export EVENT_BUS_REACTORS="$GEORGE_DIR/reactors.json"
export EVENT_BUS_LOG="$FIFO_IPC_DIR/event_bus.log"
export EVENT_BUS_PID_FILE="$FIFO_IPC_DIR/event_bus.pid"
export EVENT_BUS_LOCK="$FIFO_IPC_DIR/locks/event_bus.lock"
export EVENT_BUS_COOLDOWNS_DIR="$FIFO_IPC_DIR/cooldowns"
export EVENT_STORE_DB="$GEORGE_DIR/events.db"
mkdir -p "$GEORGE_DIR"

source "$LODGE_DIR/lib/ipc/fifo_ipc.sh"
source "$LODGE_DIR/lib/ipc/event_bus.sh"
source "$LODGE_DIR/lib/ipc/task_sync.sh"
ui_warn() { :; }; ui_err() { :; }

cleanup() {
    event_bus_stop >/dev/null 2>&1 || true
    pkill -f "ipcregr_marker_$$" 2>/dev/null || true
    for c in "$FIFO_IPC_DIR"/channels/*/; do
        [ -d "$c" ] && ipc_channel_close "$(basename "$c")" >/dev/null 2>&1
    done
    rm -rf "$TEST_TMP" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

_wait_for() {  # _wait_for <tenths> <cmd...>
    local n="$1"; shift
    local i
    for (( i = 0; i < n; i++ )); do "$@" && return 0; sleep 0.1; done
    return 1
}

test_start "IPC Flow-Control & Event Bus Regression Suite"

# ─────────────────────────────────────────────────────────────────────
describe "Phase A: framing, credits and ordering"

it "round-trips a >PIPE_BUF payload intact via spill (never truncated)" && {
    ipc_channel_open rg_big 5 >/dev/null
    big=$(jq -nc --arg s "$(head -c 6000 /dev/zero | tr '\0' 'x')" '{data:$s}')
    ipc_send rg_big DATA "$big"
    assert_ok $?
    got=$(ipc_recv rg_big 3)
    len=$(jq -r '.payload.data | length' <<< "$got")
    assert_eq "$len" "6000" "hydrated payload length"
    trunc=$(jq -r '.payload.truncated // false' <<< "$got")
    assert_eq "$trunc" "false"
    ipc_channel_close rg_big >/dev/null
}

it "enforces the credit window and loses no frames under 20 concurrent senders" && {
    ipc_channel_open rg_win 5 >/dev/null
    for i in $(seq 1 20); do ipc_send rg_win DATA "{\"i\":$i}" "" 1 >/dev/null 2>&1 & done; wait
    q=$(find "$FIFO_IPC_DIR/channels/rg_win/queue" -type f 2>/dev/null | wc -l)
    assert_eq "$q" "15" "frames beyond the window must be queued"
    n=0; seqs=""
    while f=$(ipc_recv rg_win 2); do
        n=$((n + 1)); seqs+="$(jq -r .seq <<< "$f") "
    done
    assert_eq "$n" "20" "every frame eventually delivered"
    uniq=$(tr ' ' '\n' <<< "$seqs" | grep -c . ); dup=$(tr ' ' '\n' <<< "$seqs" | grep . | sort | uniq -d | wc -l)
    assert_eq "$uniq" "20"
    assert_eq "$dup" "0" "sequence numbers are unique"
    ipc_channel_close rg_win >/dev/null
}

it "keeps credit accounting exact under 40 concurrent acquires" && {
    ipc_channel_open rg_cred 50 >/dev/null
    for i in $(seq 1 40); do ipc_flow_acquire rg_cred 1 & done; wait
    cred=$(jq -r .credits "$FIFO_IPC_DIR/channels/rg_cred/state.json")
    assert_eq "$cred" "10"
    ipc_channel_close rg_cred >/dev/null
}

it "PAUSE blocks delivery (no bypass) and RESUME drains the queue" && {
    ipc_channel_open rg_pause 5 >/dev/null
    ipc_flow_pause rg_pause
    for i in 1 2 3; do ipc_send rg_pause DATA "{\"i\":$i}" "" 0 >/dev/null 2>&1; done
    f=$(ipc_recv rg_pause 1 "" "" 0); rc=$?
    assert_fail $rc "nothing may be delivered while paused"
    ipc_flow_resume rg_pause
    n=0; while ipc_recv rg_pause 1 >/dev/null; do n=$((n + 1)); done
    assert_eq "$n" "3"
    ipc_channel_close rg_pause >/dev/null
}

it "filtered recv parks non-matching frames without reordering" && {
    ipc_channel_open rg_ord 10 >/dev/null
    ipc_send rg_ord DATA '{"n":1}' aaaa; ipc_send rg_ord DATA '{"n":2}' bbbb; ipc_send rg_ord DATA '{"n":3}' cccc
    m=$(ipc_recv rg_ord 2 "" bbbb | jq -r .payload.n)
    assert_eq "$m" "2"
    order=""; while f=$(ipc_recv rg_ord 1); do order+="$(jq -r .payload.n <<< "$f") "; done
    assert_eq "$order" "1 3 "
    ipc_channel_close rg_ord >/dev/null
}

# ─────────────────────────────────────────────────────────────────────
describe "Phase A: promises, cancellation and injection"

it "captures the real exit code of async work" && {
    p=$(ipc_async "" "exit 7")
    ipc_await "$p" 5 >/dev/null 2>&1; rc=$?
    assert_eq "$rc" "7"
}

it "ipc_pipe never executes upstream output as shell" && {
    p=$(ipc_async "" "echo 'hi; touch $TEST_TMP/PWNED_PIPE'")
    p2=$(ipc_pipe "$p" "" 'echo "${IPC_PIPE_INPUT}"' 5)
    ipc_await "$p2" 5 >/dev/null 2>&1
    [ -f "$TEST_TMP/PWNED_PIPE" ]; assert_fail $? "upstream output must not be executed"
}

it "ipc_cancel kills the whole process group (grandchildren included)" && {
    marker="ipcregr_marker_$$"
    p=$(ipc_async "" "bash -c 'exec -a ${marker}_a sleep 300' & bash -c 'exec -a ${marker}_b sleep 300' & wait")
    _wait_for 30 pgrep -f "[${marker:0:1}]${marker:1}_b" >/dev/null
    assert_ok $? "grandchildren started"
    ipc_cancel "$p" TERM >/dev/null 2>&1
    _wait_for 30 bash -c "! pgrep -f '[${marker:0:1}]${marker:1}_' >/dev/null"
    assert_ok $? "no grandchild survives cancel"
    st=$(jq -r .status "$FIFO_IPC_DIR/promises/$p.json")
    assert_eq "$st" "CANCELED"
}

it "promise settlement is first-writer-wins" && {
    p=$(ipc_async "" "echo done")
    ipc_await "$p" 5 >/dev/null 2>&1
    ipc_cancel "$p" TERM >/dev/null 2>&1
    st=$(jq -r .status "$FIFO_IPC_DIR/promises/$p.json")
    assert_eq "$st" "RESOLVED" "a late cancel must not overwrite a settled promise"
}

# ─────────────────────────────────────────────────────────────────────
describe "Phase B: event bus on IPC"

it "propagates causal depth and parent id from reactor context" && {
    event_bus_init
    rm -f "$FIFO_IPC_DIR/event_spool.ndjson"
    EVENT_DEPTH=2 EVENT_ID=evt_parent_1 event_bus_emit "rg_depth" '{"x":1}' "rg"
    line=$(tail -n 1 "$FIFO_IPC_DIR/event_spool.ndjson")
    assert_eq "$(jq -r .depth <<< "$line")" "2"
    assert_eq "$(jq -r .parent_event_id <<< "$line")" "evt_parent_1"
}

it "spools when offline and treats payloads as data (no injection)" && {
    rm -f "$FIFO_IPC_DIR/event_spool.ndjson"
    event_bus_emit "rg_inj" "'; touch $TEST_TMP/PWNED_EMIT; echo '" "rg"
    assert_ok $?
    [ -f "$TEST_TMP/PWNED_EMIT" ]; assert_fail $? "payload must never be executed"
    c=$(grep -c rg_inj "$FIFO_IPC_DIR/event_spool.ndjson")
    assert_eq "$c" "1"
}

it "spills large event payloads instead of breaking PIPE_BUF atomicity" && {
    rm -f "$FIFO_IPC_DIR/event_spool.ndjson"
    big=$(jq -nc --arg s "$(head -c 8000 /dev/zero | tr '\0' 'y')" '{blob:$s}')
    event_bus_emit "rg_big_evt" "$big" "rg"
    line=$(tail -n 1 "$FIFO_IPC_DIR/event_spool.ndjson")
    [ "${#line}" -lt 4096 ]; assert_ok $? "envelope stays below PIPE_BUF"
    ref=$(jq -r '.payload.__spillover_ref__ // empty' <<< "$line")
    assert_not_empty "$ref"
    assert_file_exists "$ref"
}

it "replays the spool on daemon start and fires matching reactors" && {
    out="$TEST_TMP/replay.out"; rm -f "$out" "$FIFO_IPC_DIR/event_spool.ndjson"
    event_bus_emit "rg_replay" '{"k":"v1"}' "rg"
    reactor_add rx_rg_replay rg_replay ".*" "printf '%s\n' \"\$EVENT_PAYLOAD\" >> '$out'" 0
    event_bus_start >/dev/null
    _wait_for 50 test -s "$out"
    assert_ok $? "spooled event replayed"
    assert_contains "$(cat "$out" 2>/dev/null)" "v1"
}

it "queue overflow serialises bursts in order with max_concurrency=1" && {
    out="$TEST_TMP/queue.out"; : > "$out"
    reactor_add rx_rg_queue rg_queue ".*" "sleep 0.3; printf '%s\n' \"\$(jq -r .n <<< \"\$EVENT_PAYLOAD\")\" >> '$out'" 0 queue 1 30
    for i in 1 2 3 4; do event_bus_emit rg_queue "{\"n\":$i}" rg; done
    _wait_for 100 bash -c "[ -f '$out' ] && [ \"\$(wc -l < '$out' 2>/dev/null || echo 0)\" -ge 4 ]"
    assert_ok $? "all queued events processed"
    assert_eq "$(tr '\n' ' ' < "$out")" "1 2 3 4 "
}

it "coalesce overflow fires the leading and newest trailing event only" && {
    out="$TEST_TMP/coalesce.out"; rm -f "$out"
    reactor_add rx_rg_coal rg_coal ".*" "printf '%s\n' \"\$(jq -r .n <<< \"\$EVENT_PAYLOAD\")\" >> '$out'" 2 coalesce 1 30
    for i in 1 2 3 4 5; do event_bus_emit rg_coal "{\"n\":$i}" rg; done
    _wait_for 60 bash -c "[ \"\$(wc -l < '$out' 2>/dev/null)\" -ge 2 ]"
    assert_ok $?
    sleep 0.5
    assert_eq "$(tr '\n' ' ' < "$out")" "1 5 "
}

it "circuit breaker bounds reactor-emitted cascades" && {
    reactor_add rx_rg_loop rg_loop ".*" "event_bus_emit rg_loop '{}' loop" 0 drop 4 30
    event_bus_emit rg_loop '{}' rg
    sleep 2
    assert_contains "$(cat "$EVENT_BUS_LOG")" "CIRCUIT_BREAKER"
    loops=$(grep -c "Firing reactor 'rx_rg_loop'" "$EVENT_BUS_LOG")
    [ "$loops" -le "$EVENT_BUS_MAX_DEPTH" ]; assert_ok $? "fired $loops times (<= max depth)"
    event_bus_stop >/dev/null
}

# ─────────────────────────────────────────────────────────────────────
describe "Phase C: configuration and multi-node sync"

it "ipc.conf supplies defaults but never overrides the environment" && {
    printf 'FIFO_AUTO_RECOVER=1\nFIFO_SPILL_BYTES=1234\n' > "$GEORGE_DIR/ipc.conf"
    out=$(FIFO_AUTO_RECOVER=0 GEORGE_DIR="$GEORGE_DIR" bash -c 'source "$1/lib/ipc/fifo_ipc.sh"; echo "$FIFO_AUTO_RECOVER $FIFO_SPILL_BYTES"' _ "$LODGE_DIR")
    assert_eq "$out" "0 1234"
    rm -f "$GEORGE_DIR/ipc.conf"
}

it "task_sync de-duplicates by msg_id" && {
    _task_sync_seen rg_target "mid-123"; first=$?
    _task_sync_seen rg_target "mid-123"; second=$?
    assert_eq "$first" "1" "first sighting is new"
    assert_eq "$second" "0" "duplicate detected"
}

it "task_sync_send uses exactly one transport for local targets" && {
    ipc_channel_open rg_sync 5 >/dev/null
    mqtt_publish() { echo "MQTT" >> "$TEST_TMP/mqtt.calls"; }
    TASK_SYNC_MIRROR=0 task_sync_send rg_sync state '{"s":1}'
    [ -f "$TEST_TMP/mqtt.calls" ]; assert_fail $? "no MQTT copy for a local delivery"
    m=$(task_sync_recv rg_sync 2)
    assert_eq "$(jq -r .payload.payload.s <<< "$m")" "1"
    assert_not_empty "$(jq -r .payload.msg_id <<< "$m")"
    unset -f mqtt_publish
    ipc_channel_close rg_sync >/dev/null
}

test_end
