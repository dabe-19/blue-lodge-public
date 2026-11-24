#!/bin/bash
# ── Tests: lib/memory/flow_ipc.sh — Layer 2 over the FIFO IPC protocol ──
# Framework API: assert_eq actual expected [msg]; assert_ok/fail exit_code [msg];
# assert_contains haystack needle [msg]; assert_not_empty value [msg].
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

_FLOW_TMP=$(mktemp -d /tmp/george-flowipc-test-XXXXXX)
cleanup() { rm -rf "$_FLOW_TMP" 2>/dev/null || true; }
trap cleanup EXIT

# GEORGE_DIR must be set BEFORE sourcing so FIFO_IPC_DIR resolves into the sandbox
export GEORGE_DIR="$_FLOW_TMP/.george"
export RECALL_DB="$GEORGE_DIR/recall.db"
export LODGE_DIR
export FLOW_CACHE_DIR="$GEORGE_DIR/cache/flow"
export FLOW_EDGE_TTL=300
export FLOW_FRINGE_N=5
export FLOW_LINK_MAX=12
export FLOW_IPC_WINDOW=4
export FLOW_IPC_TIMEOUT=5
export FLOW_GC_INTERVAL=1
mkdir -p "$GEORGE_DIR"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/memory/scenes.sh"
source "$LODGE_DIR/lib/memory/flow.sh"
source "$LODGE_DIR/lib/memory/flow_ipc.sh"

test_start "lib/memory/flow_ipc.sh — Layer 2 over FIFO IPC"

# Pre-check: sqlite3 + FTS5 + jq
_HAS_SQLITE=0
if command -v sqlite3 &>/dev/null; then
    _tdb="$_FLOW_TMP/.fts5_check.db"
    if sqlite3 "$_tdb" "CREATE VIRTUAL TABLE _t USING fts5(c); DROP TABLE _t;" 2>/dev/null; then
        _HAS_SQLITE=1
    fi
    rm -f "$_tdb"
fi
if [ "$_HAS_SQLITE" != "1" ] || ! command -v jq &>/dev/null; then
    skip "sqlite3/FTS5/jq not available"
    test_end
    exit 0
fi

# ── Arrange ────────────────────────────────────────────────────────────
scene_store_init
assert_ok $? "scene_store_init applies schema to fresh DB"

sqlite3 "$RECALL_DB" <<SQL
INSERT INTO chunks (source, section, content, filepath, indexed_at) VALUES
 ('journal', 'FIFO design',  'We adopted the FIFO async IPC protocol with credit flow control', 'j.md', '2026-11-14T12:00:00Z'),
 ('journal', 'FIFO review',  'Review of the FIFO sliding-window credits and backpressure',      'j.md', '2026-11-14T13:00:00Z'),
 ('george',  'Weather',      'Local weather summary for Springfield',                              'G.md', '2026-11-10T08:00:00Z'),
 ('journal', 'Crypto desk',  'Shock fade sizing on NIGHT',                                      'j.md', '2026-11-13T22:00:00Z');
SQL
_s1=$(scene_ensure_for_chunk 1); _s2=$(scene_ensure_for_chunk 2)
_s3=$(scene_ensure_for_chunk 3); _s4=$(scene_ensure_for_chunk 4)
assert_not_empty "$_s1" "scene materialized"
scene_tag_add "$_s1" "ipc" "topic"
scene_tag_add "$_s2" "credits" "topic"
scene_tag_add "$_s4" "crypto" "topic"

_FOCUS_A="FIFO async IPC protocol credits"
_FOCUS_B="NIGHT shock fade crypto sizing"
_ASSEMBLE_STATE="$FIFO_IPC_DIR/channels/flow.assemble/state.json"
_GC_STATE="$FIFO_IPC_DIR/channels/flow.gc/state.json"

# ── 1. Channel topology: windows, modes, assigned priorities ───────────
flow_ipc_ensure_channels
assert_ok $? "flow_ipc_ensure_channels opens both channels"
assert_eq "$(jq -r '.status' "$_ASSEMBLE_STATE" 2>/dev/null)" "OPEN" "flow.assemble is OPEN"
assert_eq "$(jq -r '.mode' "$_ASSEMBLE_STATE" 2>/dev/null)" "stream" "flow.assemble is stream mode"
assert_eq "$(jq -r '.window_size' "$_ASSEMBLE_STATE" 2>/dev/null)" "4" "flow.assemble credit window = 4 (default)"
assert_eq "$(jq -r '.credits' "$_ASSEMBLE_STATE" 2>/dev/null)" "4" "flow.assemble starts with full credits"
assert_eq "$(jq -r '.priority' "$_ASSEMBLE_STATE" 2>/dev/null)" "80" "flow.assemble assigned SYSTEM priority (80)"
assert_eq "$(jq -r '.mode' "$_GC_STATE" 2>/dev/null)" "credit" "flow.gc is credit-mode semaphore"
assert_eq "$(jq -r '.window_size' "$_GC_STATE" 2>/dev/null)" "1" "flow.gc single-flight window = 1"
assert_eq "$(jq -r '.priority' "$_GC_STATE" 2>/dev/null)" "50" "flow.gc assigned CRON priority (50)"
assert_ok $(flow_ipc_ensure_channels; echo $?) "ensure_channels is idempotent"

# ── 2. Request/response round-trip through the service ─────────────────
( flow_ipc_service 2 >/dev/null 2>&1 ) &
_svc=$!
sleep 0.6
_out=$(flow_ipc_request "$_FOCUS_A" 8); _rc=$?
assert_ok $_rc "flow_ipc_request round-trip succeeds (service live)"
assert_eq "$(printf '%s' "$_out" | jq -r '.ok')" "true" "response ok:true"
assert_eq "$(printf '%s' "$_out" | jq -r '.present.focus')" "$_FOCUS_A" "present echoes requested focus"
assert_eq "$(printf '%s' "$_out" | jq -e '.present.fringe | length > 0' >/dev/null 2>&1; echo $?)" "0" "present fringe non-empty"
assert_eq "$(printf '%s' "$_out" | jq -e '.present.character_of_passage | length > 0' >/dev/null 2>&1; echo $?)" "0" "present character_of_passage present"

# ── 3. UUID correlation: second, distinct focus gets its own present ───
_out2=$(flow_ipc_request "$_FOCUS_B" 8); _rc2=$?
assert_ok $_rc2 "second request succeeds"
assert_eq "$(printf '%s' "$_out2" | jq -r '.present.focus')" "$_FOCUS_B" "correlation: distinct focus returns its own present"
[ "$(printf '%s' "$_out" | jq -r '.present.focus')" != "$(printf '%s' "$_out2" | jq -r '.present.focus')" ]
assert_ok $? "distinct foci yield distinct presents"

# ── 4. Backpressure: exhausted credit window => IPC_QUEUED (75), no block ─
ipc_channel_open "flowtest.bp" 1 300 50 stream
assert_ok $? "scratch backpressure channel (window=1) opened"
assert_ok $(ipc_flow_acquire "flowtest.bp" 1; echo $?) "sole credit acquired"
_t0=$(date +%s)
ipc_send "flowtest.bp" "DATA" '{"probe":1}' "" 1; _bp=$?
_t1=$(date +%s)
assert_eq "$_bp" "75" "send with zero credits returns IPC_QUEUED (75)"
assert_eq "$(( (_t1 - _t0) <= 2 ))" "1" "queued send returned in <=2s (never blocked)"
_qdir="$FIFO_IPC_DIR/channels/flowtest.bp/queue"
_qn=$(ls "$_qdir"/*.frame 2>/dev/null | wc -l)
assert_eq "$_qn" "1" "frame durably spilled to the channel queue"
ipc_flow_grant "flowtest.bp" 1
sleep 0.3
_qn=$(ls "$_qdir"/*.frame 2>/dev/null | wc -l)
assert_eq "$_qn" "0" "grant flushes the spill queue"
ipc_channel_close "flowtest.bp"

# ── 5. Non-blocking failure: no service => timeout, not a hang ─────────
wait "$_svc" 2>/dev/null   # service served its 2 requests and exited
_t0=$(date +%s)
flow_ipc_request "late focus" 2; _late=$?
_t1=$(date +%s)
assert_ne "$_late" "0" "request without a service fails cleanly"
assert_eq "$_late" "124" "failure code is IPC_ERR_AWAIT_TIMEOUT (124)"
assert_eq "$(( (_t1 - _t0) < 6 ))" "1" "failure returned in <6s (non-blocking)"

# ── 6. Auto-running GC task: detached, single-flight, self-terminating ──
_gc_pid=$(flow_autotask_start_gc 3)
assert_not_empty "$_gc_pid" "autotask_start_gc prints a PID"
assert_ok $(kill -0 "$_gc_pid" 2>/dev/null; echo $?) "GC autotask is alive after start"
assert_eq "$(flow_ipc_status | jq -r 'select(.autotask_gc != null) | .autotask_gc')" "RUNNING" "status reports autotask RUNNING"
assert_ok $(flow_autotask_start_gc 3 >/dev/null; echo $?) "start is idempotent while running"
sleep 4.2
assert_eq "$(kill -0 "$_gc_pid" 2>/dev/null; echo $?)" "1" "GC autotask self-terminated after max_cycles=3"
assert_eq "$(jq -r '.credits' "$_GC_STATE" 2>/dev/null)" "1" "GC credit re-granted (semaphore restored)"
assert_eq "$(flow_ipc_status | jq -r 'select(.autotask_gc != null) | .autotask_gc')" "STOPPED" "status reports autotask STOPPED after exit"

# ── 7. Credit window is tunable ────────────────────────────────────────
export FLOW_IPC_WINDOW=2
flow_ipc_close
flow_ipc_ensure_channels
assert_eq "$(jq -r '.window_size' "$_ASSEMBLE_STATE" 2>/dev/null)" "2" "FLOW_IPC_WINDOW=2 honored on re-open"
export FLOW_IPC_WINDOW=4

# ── 8. Lifecycle + blast radius ────────────────────────────────────────
flow_ipc_close
assert_eq "$(jq -r '.status' "$_ASSEMBLE_STATE" 2>/dev/null)" "" "flow.assemble channel reaped (state dir gone)"
assert_eq "$(jq -r '.status' "$_GC_STATE" 2>/dev/null)" "" "flow.gc channel reaped (state dir gone)"
ipc_channel_is_open "flow.assemble" && _op=1 || _op=0
assert_eq "$_op" "0" "flow.assemble reports closed after close"
# close() sends SIGTERM; the keeper's trap fires when its in-flight `sleep 2`
# lapses, so poll inside a bounded 10s reap window (TERM ~2s; state-miss
# self-exit worst case ~8s). Scope the grep to THIS run's FIFO tree so
# unrelated long-lived keepers elsewhere cannot fail the suite.
_leaked=1
for _i in $(seq 1 20); do
    _keep=$(ps -eo args 2>/dev/null | grep -F "$FIFO_IPC_DIR" | grep -c 'george-keeper' || true)
    [ "$_keep" = "0" ] && { _leaked=0; break; }
    sleep 0.5
done
assert_eq "$_leaked" "0" "no leaked flow channel keepers for this run (10s reap window)"
assert_eq "$(ipc_send 'flow.assemble' 'FLOW_REQ' '{}' '' 2; echo $?)" "2" "raw send post-close returns IPC_ERR_NOTFOUND (2)"
# Zero-persistence invariant: no flow tables, scene counts untouched
_tables=$(sqlite3 "$RECALL_DB" ".tables")
assert_eq "$(printf '%s' "$_tables" | grep -cE 'flow|linkage')" "0" "no flow/linkage tables added to recall.db"
assert_eq "$(sqlite3 "$RECALL_DB" 'SELECT COUNT(*) FROM scenes;')" "4" "scene count unchanged (read-only Layer 2)"
assert_eq "$(sqlite3 "$RECALL_DB" 'SELECT COUNT(*) FROM chunks;')" "4" "chunk count unchanged"

test_end
exit 0
