#!/bin/bash
# ── George: Memory Flow IPC — Layer 2 present as a non-blocking FIFO service ──
#
# Integrates the Layer 2 generated present (lib/memory/flow.sh) into the
# zero-daemon POSIX FIFO async/await credit protocol (lib/ipc/fifo_ipc.sh).
#
#   1. flow_ipc_ensure_channels — opens two FIFO channels:
#        flow.assemble  stream mode, credit window FLOW_IPC_WINDOW (4),
#                       priority IPC_PRIO_SYSTEM (80) — the request/response
#                       plane serving interactive present derivation.
#        flow.gc        credit mode, window 1, priority IPC_PRIO_CRON (50)
#                       — a single-flight semaphore guarding the auto-running
#                       cache-GC task (background maintenance never preempts).
#   2. flow_ipc_request <focus> [timeout] — producer side: sends a FLOW_REQ
#      frame (UUID-correlated) and awaits the matching FLOW_RESP. When the
#      credit window is exhausted the frame is durably spilled to the channel
#      queue and IPC_QUEUED (75) is returned — the producer NEVER blocks
#      beyond [timeout].
#   3. flow_ipc_service [max_requests] — consumer side: receives FLOW_REQ
#      frames, derives the TTL-cached present, returns a correlated FLOW_RESP.
#   4. flow_autotask_start_gc / flow_autotask_stop_gc — auto-running TTL
#      cache-GC background task. CRON priority (50); non-blocking: each cycle
#      tries for the GC credit once (1s poll), skips the cycle if another GC
#      holds it, never stalls the service.
#   5. flow_ipc_status / flow_ipc_close — observability and lifecycle.
#
# Zero-persistence invariant (Layer 2): this module adds NO tables to
# recall.db. All state lives in $FIFO_IPC_DIR (channel dirs) and the
# $FLOW_CACHE_DIR TTL files.
#
# Requires: bash 5+, jq, sqlite3+FTS5 (via flow.sh). Sources ipc, scenes and
# flow layers; load-guarded.

[ -n "${_LIB_FLOW_IPC_LOADED:-}" ] && return 0; _LIB_FLOW_IPC_LOADED=1

_flow_ipc_repo_root() {
    printf '%s' "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
}
# shellcheck source=/dev/null
source "$(_flow_ipc_repo_root)/lib/ipc/ipc.sh" 2>/dev/null
# shellcheck source=/dev/null
source "$(_flow_ipc_repo_root)/lib/memory/scenes.sh" 2>/dev/null
# shellcheck source=/dev/null
source "$(_flow_ipc_repo_root)/lib/memory/flow.sh" 2>/dev/null

# ── Tunables (env wins; numeric-validated, defaults on junk) ────────────
FLOW_IPC_WINDOW="${FLOW_IPC_WINDOW:-4}"        # in-flight assembles (credit window, flow.assemble)
FLOW_IPC_MAX_IDLE="${FLOW_IPC_MAX_IDLE:-300}"  # channel idle reaping
FLOW_IPC_TIMEOUT="${FLOW_IPC_TIMEOUT:-15}"     # producer send/recv timeout (s)
FLOW_GC_INTERVAL="${FLOW_GC_INTERVAL:-60}"     # auto-GC cadence (s); 0 = back-to-back cycles
FLOW_GC_MAX_CYCLES="${FLOW_GC_MAX_CYCLES:-0}"  # 0 = run until stopped (daemon)
case "$FLOW_IPC_WINDOW" in ''|*[!0-9]*) FLOW_IPC_WINDOW=4 ;; esac
[ "$FLOW_IPC_WINDOW" -ge 1 ] || FLOW_IPC_WINDOW=4
case "$FLOW_IPC_MAX_IDLE" in ''|*[!0-9]*) FLOW_IPC_MAX_IDLE=300 ;; esac
[ "$FLOW_IPC_MAX_IDLE" -ge 1 ] || FLOW_IPC_MAX_IDLE=300
case "$FLOW_IPC_TIMEOUT" in ''|*[!0-9]*) FLOW_IPC_TIMEOUT=15 ;; esac
[ "$FLOW_IPC_TIMEOUT" -ge 1 ] || FLOW_IPC_TIMEOUT=15
case "$FLOW_GC_INTERVAL" in ''|*[!0-9]*) FLOW_GC_INTERVAL=60 ;; esac
case "$FLOW_GC_MAX_CYCLES" in ''|*[!0-9]*) FLOW_GC_MAX_CYCLES=0 ;; esac

readonly FLOW_IPC_CHAN_ASSEMBLE="flow.assemble"
readonly FLOW_IPC_CHAN_GC="flow.gc"

# Protocol priority assignment (constants from lib/ipc/fifo_ipc.sh):
#   SYSTEM (80) — the assemble service: serves the interactive prompt's present
#   CRON   (50) — the auto-running GC: background maintenance
FLOW_IPC_PRIO_SERVICE="${FLOW_IPC_PRIO_SERVICE:-$IPC_PRIO_SYSTEM}"
FLOW_IPC_PRIO_GC="${FLOW_IPC_PRIO_GC:-$IPC_PRIO_CRON}"

_flow_ipc_pidfile() {
    if declare -F _flow_cache_root >/dev/null 2>&1; then
        printf '%s/autotask_gc.pid' "$(_flow_cache_root)"
    else
        printf '%s/autotask_gc.pid' "${FLOW_CACHE_DIR:-${GEORGE_DIR:-$(_flow_ipc_repo_root)/.george}/cache/flow}"
    fi
}

_flow_ipc_new_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        read -r < /proc/sys/kernel/random/uuid
    else
        printf '%08x-%04x-%04x-%04x-%012x' "$$" $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM
    fi
}

# ── Channel lifecycle ───────────────────────────────────────────────────
# Opens (or reuses) the two protocol channels with their assigned
# credit windows and priority levels. Idempotent.
flow_ipc_ensure_channels() {
    local rc=0
    ipc_init || return $IPC_ERR_GENERIC
    if ! ipc_channel_is_open "$FLOW_IPC_CHAN_ASSEMBLE"; then
        ipc_channel_open "$FLOW_IPC_CHAN_ASSEMBLE" "$FLOW_IPC_WINDOW" "$FLOW_IPC_MAX_IDLE" "$FLOW_IPC_PRIO_SERVICE" stream || rc=$?
    fi
    if ! ipc_channel_is_open "$FLOW_IPC_CHAN_GC"; then
        ipc_channel_open "$FLOW_IPC_CHAN_GC" 1 "$FLOW_IPC_MAX_IDLE" "$FLOW_IPC_PRIO_GC" credit || rc=$?
    fi
    return $rc
}

# Closes both channels (ABORT ctrl wake, keeper reaping) and stops the
# auto-GC task. Idempotent.
flow_ipc_close() {
    flow_autotask_stop_gc 2>/dev/null || true
    ipc_flow_send_ctrl "$FLOW_IPC_CHAN_ASSEMBLE" "ABORT" 2>/dev/null || true
    ipc_channel_close "$FLOW_IPC_CHAN_ASSEMBLE" 2>/dev/null || true
    ipc_channel_close "$FLOW_IPC_CHAN_GC" 2>/dev/null || true
    return 0
}

# ── Producer side ───────────────────────────────────────────────────────
# flow_ipc_request <focus> [timeout_s]
# Prints the FLOW_RESP payload on success:
#   {"ok":bool,"focus":str|null,"present":AssembledPresent|null}.
# Return codes (protocol): 0 OK | 2 NOTFOUND | 22 INVALID | 32 PIPE |
# 75 QUEUED (credit exhausted; frame durably spilled — retry later) |
# 110 TIMEOUT (no credit granted) | 124 RESPONSE TIMED OUT (sent, no consumer).
flow_ipc_request() {
    local focus="${1:-}"
    local timeout="${2:-$FLOW_IPC_TIMEOUT}"
    [ -z "$focus" ] && return $IPC_ERR_INVALID
    local rc=0
    flow_ipc_ensure_channels || return $?
    local req_uuid req
    req_uuid=$(_flow_ipc_new_uuid)
    req=$(jq -nc --arg f "$focus" '{focus: $f}' 2>/dev/null) || return $IPC_ERR_INVALID
    rc=0
    ipc_send "$FLOW_IPC_CHAN_ASSEMBLE" "FLOW_REQ" "$req" "$req_uuid" "$timeout" || rc=$?
    [ $rc -eq 0 ] || return $rc
    local resp_frame resp_body
    resp_frame=$(ipc_recv "$FLOW_IPC_CHAN_ASSEMBLE" "$timeout" "FLOW_RESP" "$req_uuid" 1) || return $?
    resp_body=$(printf '%s' "$resp_frame" | jq -c ' .payload // empty' 2>/dev/null)
    [ -n "$resp_body" ] || resp_body="$resp_frame"
    printf '%s\n' "$resp_body"
    return 0
}

# ── Consumer side (the service) ─────────────────────────────────────────
# flow_ipc_service [max_requests]   (0 = serve until channel closes)
# Runs in the calling process; background it for daemon use:
#   flow_ipc_service &   or   ( flow_ipc_service >/dev/null 2>&1 ) &
flow_ipc_service() {
    local max="${1:-0}"
    local served=0
    local rc=0
    flow_ipc_ensure_channels || return $?
    local recv_timeout=5
    [ "$FLOW_IPC_TIMEOUT" -lt 5 ] 2>/dev/null && recv_timeout=$FLOW_IPC_TIMEOUT
    local frame="" uuid="" focus="" present="" body=""
    while :; do
        frame=$(ipc_recv "$FLOW_IPC_CHAN_ASSEMBLE" "$recv_timeout" "FLOW_REQ" "" 1) || {
            rc=$?
            [ "$rc" -eq "$IPC_ERR_AWAIT_TIMEOUT" ] && continue
            break
        }
        uuid=$(printf '%s' "$frame" | jq -r '.uuid // empty' 2>/dev/null)
        focus=$(printf '%s' "$frame" | jq -r '.payload.focus // empty' 2>/dev/null)
        if [ -n "$focus" ]; then
            present=$(flow_assemble_present "$focus" 2>/dev/null)
        else
            present="null"
        fi
        if [ "$present" != "null" ] && ! printf '%s' "$present" | jq -ce 'type == "object"' >/dev/null 2>&1; then
            present="null"
        fi
        body=$(jq -nc --argjson p "$present" \
            '{ok: ($p != null), focus: (if $p == null then null else $p.focus end), present: $p}' 2>/dev/null)
        [ -n "$body" ] || body='{"ok":false,"focus":null,"present":null}'
        ipc_send "$FLOW_IPC_CHAN_ASSEMBLE" "FLOW_RESP" "$body" "$uuid" "$recv_timeout" || break
        served=$((served + 1))
        [ "$max" -gt 0 ] && [ "$served" -ge "$max" ] && break
    done
    return 0
}

# ── Auto-running cache-GC task (CRON priority, single-flight semaphore) ─
# flow_autotask_gc_loop [max_cycles] — one iteration per FLOW_GC_INTERVAL:
# tries ONCE for the single GC credit (1s poll). If another GC holds it,
# the cycle is skipped. Never blocks, never starves the service.
flow_autotask_gc_loop() {
    local max_cycles="${1:-$FLOW_GC_MAX_CYCLES}"
    local n=0
    flow_ipc_ensure_channels || return $?
    while :; do
        if ipc_flow_acquire "$FLOW_IPC_CHAN_GC" 1; then
            flow_cache_gc >/dev/null 2>&1 || true
            ipc_flow_grant "$FLOW_IPC_CHAN_GC" 1
            ipc_flow_ping "$FLOW_IPC_CHAN_GC" 2>/dev/null || true
        fi
        n=$((n + 1))
        [ "$max_cycles" -gt 0 ] && [ "$n" -ge "$max_cycles" ] && break
        [ "${FLOW_GC_INTERVAL:-60}" -gt 0 ] && sleep "${FLOW_GC_INTERVAL}"
    done
    return 0
}

# flow_autotask_start_gc [max_cycles] — detaches the GC loop; prints its PID.
flow_autotask_start_gc() {
    local max_cycles="${1:-$FLOW_GC_MAX_CYCLES}"
    local pidfile
    pidfile=$(_flow_ipc_pidfile)
    mkdir -p "$(dirname "$pidfile")" 2>/dev/null || true
    if [ -f "$pidfile" ]; then
        local old=""
        old=$(< "$pidfile")
        if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
            printf '%s\n' "$old"    # already running: idempotent
            return 0
        fi
    fi
    (
        exec 0</dev/null 1>/dev/null 2>/dev/null
        flow_autotask_gc_loop "$max_cycles"
    ) &
    local pid=$!
    echo "$pid" > "$pidfile"
    disown "$pid" 2>/dev/null || true
    printf '%s\n' "$pid"
    return 0
}

flow_autotask_stop_gc() {
    local pidfile pid=""
    pidfile=$(_flow_ipc_pidfile)
    [ -f "$pidfile" ] && pid=$(< "$pidfile")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile" 2>/dev/null || true
    return 0
}

# ── Observability ───────────────────────────────────────────────────────
# NDJSON: one line per channel {channel,status,credits,window_size,priority,mode,backpressure}
# plus one line {autotask_gc: RUNNING|STOPPED, pid}.
flow_ipc_status() {
    local c cdir
    for c in "$FLOW_IPC_CHAN_ASSEMBLE" "$FLOW_IPC_CHAN_GC"; do
        cdir="${FIFO_IPC_DIR:-${GEORGE_DIR:-$(_flow_ipc_repo_root)/.george}/ipc}/channels/$c"
        if [ -f "$cdir/state.json" ]; then
            jq -c --arg c "$c" '{channel: $c} + {status, credits, window_size, priority, mode, backpressure}' "$cdir/state.json" 2>/dev/null
        else
            jq -nc --arg c "$c" '{channel: $c, status: "CLOSED", credits: 0, window_size: 0, priority: 0, mode: "none", backpressure: false}'
        fi
    done
    local pidfile pid=""
    pidfile=$(_flow_ipc_pidfile)
    [ -f "$pidfile" ] && pid=$(< "$pidfile")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        jq -nc --argjson pid "$pid" '{autotask_gc: "RUNNING", pid: $pid}'
    else
        jq -nc '{autotask_gc: "STOPPED", pid: 0}'
    fi
    return 0
}
