#!/bin/bash
# ── George: Sovereign POSIX FIFO Async/Await & Flow Control Engine ────
# Implements pure POSIX shell asynchronous IPC:
#   1. Named FIFO channel creation and lifecycle management
#   2. Credit-based flow control and backpressure signaling (CREDIT, PAUSE, RESUME, ACK, ABORT)
#   3. Asynchronous execution (fifo_async) returning Promise / Task handles
#   4. Blocking resolution (fifo_await) with sub-second polling and timeout guards
#   5. Bidirectional frame reading/writing with JSON schema enforcement

[ -n "${_LIB_FIFO_IPC_LOADED:-}" ] && return 0; _LIB_FIFO_IPC_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
FIFO_IPC_DIR="${FIFO_IPC_DIR:-${GEORGE_DIR}/ipc}"
FIFO_DEFAULT_WINDOW="${FIFO_DEFAULT_WINDOW:-5}"

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true

fifo_ipc_init() {
    local base="${1:-$FIFO_IPC_DIR}"
    FIFO_IPC_DIR="$base"
    mkdir -p "$FIFO_IPC_DIR/channels" "$FIFO_IPC_DIR/promises" "$FIFO_IPC_DIR/locks" 2>/dev/null || true
}

# ── 1. Channel Lifecycle ─────────────────────────────────────────────

# Opens a structured FIFO channel: data.fifo + ctrl.fifo + state.json
# Usage: fifo_channel_open <channel_id> [credit_window]
fifo_channel_open() {
    local cid="$1"
    local window="${2:-$FIFO_DEFAULT_WINDOW}"
    fifo_ipc_init

    local cdir="$FIFO_IPC_DIR/channels/$cid"
    mkdir -p "$cdir" 2>/dev/null

    local data_fifo="$cdir/data.fifo"
    local ctrl_fifo="$cdir/ctrl.fifo"
    local state_file="$cdir/state.json"

    # Re-create FIFOs cleanly
    rm -f "$data_fifo" "$ctrl_fifo" 2>/dev/null || true
    mkfifo "$data_fifo" 2>/dev/null || true
    mkfifo "$ctrl_fifo" 2>/dev/null || true

    local now_ts
    now_ts=$(date +%s)
    jq -n \
        --arg cid "$cid" \
        --arg ts "$now_ts" \
        --argjson win "$window" \
        --argjson cred "$window" \
        '{
            channel_id: $cid,
            created_at: ($ts | tonumber),
            status: "OPEN",
            window_size: $win,
            credits: $cred,
            backpressure: false,
            seq_out: 0,
            seq_in: 0,
            last_activity: ($ts | tonumber)
        }' > "$state_file" 2>/dev/null || true

    # Spawn background pipe keeper to ensure Linux kernel never discards FIFO buffer between async readers/writers
    (
        exec 9<> "$data_fifo" 10<> "$ctrl_fifo"
        while [ -f "$state_file" ] && [ "$(jq -r '.status // empty' "$state_file" 2>/dev/null)" = "OPEN" ]; do
            sleep 0.5
        done
        exec 9>&- 10>&-
    ) </dev/null >/dev/null 2>&1 &
    local keeper_pid=$!
    disown "$keeper_pid" 2>/dev/null || true
    jq --argjson kp "$keeper_pid" '.keeper_pid = $kp' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true

    return 0
}

# Closes and cleans up a FIFO channel
# Usage: fifo_channel_close <channel_id>
fifo_channel_close() {
    local cid="$1"
    local cdir="$FIFO_IPC_DIR/channels/$cid"
    [ ! -d "$cdir" ] && return 0

    local state_file="$cdir/state.json"
    if [ -f "$state_file" ]; then
        local keeper_pid
        keeper_pid=$(jq -r '.keeper_pid // empty' "$state_file" 2>/dev/null || true)
        if [ -n "$keeper_pid" ] && [ "$keeper_pid" -gt 0 ] 2>/dev/null; then
            pkill -9 -P "$keeper_pid" 2>/dev/null || true
            kill -9 "$keeper_pid" 2>/dev/null || true
            wait "$keeper_pid" 2>/dev/null || true
        fi
        jq '.status = "CLOSED"' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true
    fi

    # Unblock any lingering writers/readers by sending ABORT in non-blocking O_RDWR mode
    if [ -p "$cdir/ctrl.fifo" ]; then
        (
            exec 3<> "$cdir/ctrl.fifo"
            printf 'ABORT\n' >&3 2>/dev/null || true
            exec 3>&-
        ) </dev/null >/dev/null 2>&1 || true
    fi

    rm -f "$cdir/data.fifo" "$cdir/ctrl.fifo" 2>/dev/null || true
    rm -rf "$cdir" 2>/dev/null || true
    return 0
}

# Checks if a channel exists and is active
fifo_channel_is_open() {
    local cid="$1"
    local state_file="$FIFO_IPC_DIR/channels/$cid/state.json"
    [ -f "$state_file" ] && [ "$(jq -r '.status // empty' "$state_file" 2>/dev/null)" = "OPEN" ]
}

# ── 2. Flow Control Primitives ──────────────────────────────────────

# Acquires transmission credit before writing to data.fifo.
# If credits are 0, waits for consumer CREDIT grant on ctrl.fifo.
# Usage: fifo_flow_acquire <channel_id> [timeout_s]
fifo_flow_acquire() {
    local cid="$1"
    local timeout="${2:-10}"
    local cdir="$FIFO_IPC_DIR/channels/$cid"
    local state_file="$cdir/state.json"
    local ctrl_fifo="$cdir/ctrl.fifo"

    [ ! -f "$state_file" ] && return 1

    local start_ts now_ts elapsed
    start_ts=$(date +%s)

    while true; do
        # Check current credit count
        local cred st bp
        cred=$(jq -r '.credits // 0' "$state_file" 2>/dev/null || echo 0)
        st=$(jq -r '.status // "CLOSED"' "$state_file" 2>/dev/null || echo "CLOSED")
        bp=$(jq -r '.backpressure // false' "$state_file" 2>/dev/null || echo false)

        [ "$st" != "OPEN" ] && return 1

        if [ "$cred" -gt 0 ] && [ "$bp" = "false" ]; then
            # Deduct 1 credit atomically
            jq '.credits -= 1 | .last_activity = (now | floor)' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true
            return 0
        fi

        # Credits depleted or paused: read ctrl.fifo non-blockingly for updates
        now_ts=$(date +%s)
        elapsed=$((now_ts - start_ts))
        if [ "$elapsed" -ge "$timeout" ]; then
            # Multi-turn flow control auto-recovery safeguard:
            # If producer is wedged due to depleted credits or stale pause beyond threshold,
            # auto-recover credits to window size to prevent aborting multi-turn agent execution
            if [ "${FIFO_AUTO_RECOVER:-1}" = "1" ] && [ "$timeout" -ge 5 ]; then
                local win
                win=$(jq -r '.window_size // 5' "$state_file" 2>/dev/null || echo 5)
                ui_warn "fifo_flow_acquire: channel $cid auto-recovering credits after ${elapsed}s wait" >&2
                jq --argjson w "$win" '.credits = $w | .backpressure = false | .last_activity = (now | floor)' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true
                return 0
            fi
            return 110 # Connection timed out (ETIMEDOUT)
        fi

        if [ -p "$ctrl_fifo" ]; then
            local cmd=""
            if read -t 0.1 -r cmd <> "$ctrl_fifo" 2>/dev/null; then
                if [ -n "$cmd" ]; then
                    case "$cmd" in
                        CREDIT\ *)
                            local add_cred="${cmd#CREDIT }"
                            if [[ "$add_cred" =~ ^[0-9]+$ ]]; then
                                jq --argjson a "$add_cred" '.credits += $a | .backpressure = false | .last_activity = (now | floor)' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true
                            fi
                            ;;
                        PAUSE)
                            jq '.backpressure = true | .last_activity = (now | floor)' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true
                            ;;
                        RESUME)
                            jq '.backpressure = false | .last_activity = (now | floor)' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true
                            ;;
                        PING)
                            jq '.last_activity = (now | floor)' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true
                            (
                                exec 3<> "$ctrl_fifo"
                                printf 'PONG\n' >&3 2>/dev/null || true
                                exec 3>&-
                            ) </dev/null >/dev/null 2>&1 &
                            ;;
                        PONG|HEARTBEAT)
                            jq '.last_activity = (now | floor)' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true
                            ;;
                        FLUSH|UNSTICK)
                            local win
                            win=$(jq -r '.window_size // 5' "$state_file" 2>/dev/null || echo 5)
                            jq --argjson w "$win" '.credits = $w | .backpressure = false | .last_activity = (now | floor)' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true
                            ;;
                        ABORT)
                            jq '.status = "ABORTED"' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true
                            return 1
                            ;;
                    esac
                fi
            fi
        fi

        sleep 0.05
    done
}

# Consumer grants transmission credit to producer
# Usage: fifo_flow_grant <channel_id> [amount]
fifo_flow_grant() {
    local cid="$1"
    local amount="${2:-1}"
    local cdir="$FIFO_IPC_DIR/channels/$cid"
    local state_file="$cdir/state.json"
    local ctrl_fifo="$cdir/ctrl.fifo"

    [ ! -f "$state_file" ] && return 1

    # Update state file
    jq --argjson a "$amount" '.credits += $a | .last_activity = (now | floor)' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true

    # Transmit CREDIT signal to unblock waiting producer
    if [ -p "$ctrl_fifo" ]; then
        (
            exec 3<> "$ctrl_fifo"
            printf 'CREDIT %d\n' "$amount" >&3 2>/dev/null || true
            exec 3>&-
        ) </dev/null >/dev/null 2>&1 &
    fi
    return 0
}

# Transmits flow control command: PAUSE | RESUME | ABORT | PING | HEARTBEAT | UNSTICK
# Usage: fifo_flow_send_ctrl <channel_id> <command>
fifo_flow_send_ctrl() {
    local cid="$1"
    local cmd="$2"
    local cdir="$FIFO_IPC_DIR/channels/$cid"
    local state_file="$cdir/state.json"
    local ctrl_fifo="$cdir/ctrl.fifo"

    [ ! -f "$state_file" ] && return 1

    case "$cmd" in
        PAUSE)
            jq '.backpressure = true | .last_activity = (now | floor)' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true
            ;;
        RESUME)
            jq '.backpressure = false | .last_activity = (now | floor)' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true
            ;;
        UNSTICK|FLUSH)
            local win
            win=$(jq -r '.window_size // 5' "$state_file" 2>/dev/null || echo 5)
            jq --argjson w "$win" '.credits = $w | .backpressure = false | .last_activity = (now | floor)' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true
            ;;
        PING|PONG|HEARTBEAT)
            jq '.last_activity = (now | floor)' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true
            ;;
        ABORT)
            jq '.status = "ABORTED"' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true
            ;;
    esac

    if [ -p "$ctrl_fifo" ]; then
        (
            exec 3<> "$ctrl_fifo"
            printf '%s\n' "$cmd" >&3 2>/dev/null || true
            exec 3>&-
        ) </dev/null >/dev/null 2>&1 &
    fi
    return 0
}

# Unsticks a wedged channel immediately by restoring credits and clearing backpressure
# Usage: fifo_flow_unstick <channel_id>
fifo_flow_unstick() {
    local cid="$1"
    fifo_flow_send_ctrl "$cid" "UNSTICK"
}

# Sends heartbeat ping across ctrl FIFO
# Usage: fifo_flow_ping <channel_id>
fifo_flow_ping() {
    local cid="$1"
    fifo_flow_send_ctrl "$cid" "PING"
}

# ── 3. Data Streaming & Frame I/O ────────────────────────────────────

# Validates whether a string is a well-formed JSON frame
# Usage: fifo_validate_frame <frame_str>
fifo_validate_frame() {
    local frame="$1"
    [ -z "$frame" ] && return 1
    echo "$frame" | jq -e . >/dev/null 2>&1
}

# Flushes and discards unread frames from data.fifo, resetting credits and activity
# Usage: fifo_channel_flush <channel_id>
fifo_channel_flush() {
    local cid="$1"
    local cdir="$FIFO_IPC_DIR/channels/$cid"
    local data_fifo="$cdir/data.fifo"
    local state_file="$cdir/state.json"
    [ ! -f "$state_file" ] && return 1

    # Drain data_fifo non-blockingly until empty
    if [ -p "$data_fifo" ]; then
        local junk=""
        while read -t 0.05 -r junk <> "$data_fifo" 2>/dev/null; do
            :
        done
    fi

    local win
    win=$(jq -r '.window_size // 5' "$state_file" 2>/dev/null || echo 5)
    jq --argjson w "$win" '.credits = $w | .backpressure = false | .last_activity = (now | floor)' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true
    return 0
}

# Writes a structured JSON frame to the channel data.fifo with credit enforcement
# Usage: fifo_write_frame <channel_id> <payload_json> [timeout_s]
fifo_write_frame() {
    local cid="$1"
    local payload="$2"
    local timeout="${3:-10}"
    local cdir="$FIFO_IPC_DIR/channels/$cid"
    local data_fifo="$cdir/data.fifo"
    local state_file="$cdir/state.json"

    [ ! -p "$data_fifo" ] && return 1

    # Multi-turn payload boundary protection: guard against Linux pipe buffer overflow
    local max_bytes="${FIFO_MAX_FRAME_BYTES:-32768}"
    local payload_len=${#payload}
    if [ "$payload_len" -gt "$max_bytes" ]; then
        payload=$(jq -nc \
            --arg orig_len "$payload_len" \
            --arg snippet "$(echo "$payload" | head -c "$max_bytes")" \
            '{truncated: true, original_bytes: ($orig_len | tonumber), snippet: $snippet}')
    fi

    # Acquire credit (enforcing flow control window)
    if ! fifo_flow_acquire "$cid" "$timeout"; then
        return 1
    fi

    # Read current seq_out and increment
    local seq=0
    seq=$(jq -r '.seq_out // 0' "$state_file" 2>/dev/null || echo 0)
    seq=$((seq + 1))
    jq --argjson s "$seq" '.seq_out = $s | .last_activity = (now | floor)' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true

    local now_ts
    now_ts=$(date +%s)
    local frame
    frame=$(jq -nc \
        --arg cid "$cid" \
        --argjson seq "$seq" \
        --arg ts "$now_ts" \
        --argjson body "$payload" \
        '{channel: $cid, seq: $seq, ts: ($ts | tonumber), body: $body}' 2>/dev/null || echo "$payload")

    # Write line-delimited frame to data FIFO
    if [ -p "$data_fifo" ]; then
        (
            exec 4<> "$data_fifo"
            printf '%s\n' "$frame" >&4 2>/dev/null || true
            exec 4>&-
        ) 2>/dev/null &
    fi

    return 0
}

# Reads next available frame from data.fifo, auto-granting replenishment credit
# Usage: fifo_read_frame <channel_id> [timeout_s] [auto_grant=1]
fifo_read_frame() {
    local cid="$1"
    local timeout="${2:-5}"
    local auto_grant="${3:-1}"
    local cdir="$FIFO_IPC_DIR/channels/$cid"
    local data_fifo="$cdir/data.fifo"
    local state_file="$cdir/state.json"

    [ ! -p "$data_fifo" ] && return 1

    local frame=""
    # Non-blocking timed read from data_fifo using file descriptor open
    if read -t "$timeout" -r frame <> "$data_fifo" 2>/dev/null; then
        if [ -n "$frame" ]; then
            # Increment seq_in
            local seq_in=0
            seq_in=$(jq -r '.seq_in // 0' "$state_file" 2>/dev/null || echo 0)
            seq_in=$((seq_in + 1))
            jq --argjson s "$seq_in" '.seq_in = $s | .last_activity = (now | floor)' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true

            # Replenish producer credit
            if [ "$auto_grant" -eq 1 ]; then
                fifo_flow_grant "$cid" 1
            fi

            printf '%s\n' "$frame"
            return 0
        fi
    fi

    return 1
}

# ── 4. Async / Await Execution Runtime ───────────────────────────────

# Spawns a command or function in the background attached to channel IPC.
# Returns a Promise / Task Handle with promise_id.
# Usage: fifo_async <channel_id> <command_line>
fifo_async() {
    local cid="$1"
    local cmd="$2"
    fifo_ipc_init

    local prom_id="prom_$(date +%s)_$RANDOM"
    local prom_file="$FIFO_IPC_DIR/promises/${prom_id}.json"
    local prom_out="$FIFO_IPC_DIR/promises/${prom_id}.out"
    local now_ts
    now_ts=$(date +%s)

    # Launch background worker
    (
        # Execute command in an inner subshell to safely capture any explicit exit N
        local exit_code=0
        if ( eval "$cmd" ) > "$prom_out" 2>&1; then
            exit_code=0
        else
            exit_code=$?
        fi

        local fin_ts
        fin_ts=$(date +%s)
        local out_body
        out_body=$(cat "$prom_out" 2>/dev/null | tr '\n' ' ' | head -c 2000)

        # Update promise file immediately via unique temp file
        local p_status="RESOLVED"
        [ "$exit_code" -ne 0 ] && p_status="REJECTED"
        local child_tmp="${prom_file}.fin.${BASHPID:-$$}"
        jq --argjson ec "$exit_code" \
           --argjson fin "$fin_ts" \
           --arg st "$p_status" \
           '.status = $st | .exit_code = $ec | .finished_at = $fin' "$prom_file" > "$child_tmp" 2>/dev/null && mv "$child_tmp" "$prom_file" 2>/dev/null || true

        # Notify channel of completion if channel is active
        if [ -n "$cid" ] && fifo_channel_is_open "$cid"; then
            local res_payload
            res_payload=$(jq -nc \
                --arg prom "$prom_id" \
                --argjson ec "$exit_code" \
                --arg out "$out_body" \
                --arg st "$p_status" \
                '{promise_id: $prom, exit_code: $ec, output: $out, status: $st}')
            fifo_write_frame "$cid" "$res_payload" 2 2>/dev/null || true
        fi
    ) </dev/null >/dev/null 2>&1 &

    local bg_pid=$!
    # Write initial promise file directly with RUNNING status and real bg_pid
    local parent_tmp="${prom_file}.init.$$"
    jq -n \
        --arg pid "$prom_id" \
        --arg cid "$cid" \
        --arg cmd "$cmd" \
        --arg ts "$now_ts" \
        --argjson bg "$bg_pid" \
        '{
            promise_id: $pid,
            channel_id: $cid,
            command: $cmd,
            status: "RUNNING",
            pid: $bg,
            started_at: ($ts | tonumber),
            finished_at: null,
            exit_code: null
        }' > "$parent_tmp" 2>/dev/null && mv "$parent_tmp" "$prom_file" 2>/dev/null || true

    echo "$prom_id"
    return 0
}

# Awaits resolution of an async promise handle
# Usage: fifo_await <promise_id> [timeout_s]
fifo_await() {
    local prom_id="$1"
    local timeout="${2:-30}"
    local prom_file="$FIFO_IPC_DIR/promises/${prom_id}.json"
    local prom_out="$FIFO_IPC_DIR/promises/${prom_id}.out"

    if [ ! -f "$prom_file" ]; then
        ui_err "Promise $prom_id not found" >&2
        return 1
    fi

    local start_ts now_ts elapsed
    start_ts=$(date +%s)

    while true; do
        now_ts=$(date +%s)
        elapsed=$((now_ts - start_ts))
        if [ "$elapsed" -ge "$timeout" ]; then
            ui_warn "Promise $prom_id timed out after ${timeout}s" >&2
            return 124
        fi

        local st ec bg_pid
        st=$(jq -r '.status // "PENDING"' "$prom_file" 2>/dev/null || echo "PENDING")
        ec=$(jq -r '.exit_code // empty' "$prom_file" 2>/dev/null || true)
        bg_pid=$(jq -r '.pid // empty' "$prom_file" 2>/dev/null || true)

        if [ "$st" = "RESOLVED" ]; then
            [ -f "$prom_out" ] && cat "$prom_out"
            return "${ec:-0}"
        elif [ "$st" = "REJECTED" ]; then
            [ -f "$prom_out" ] && cat "$prom_out" >&2
            return "${ec:-1}"
        fi

        # Safeguard: Detect crashed / prematurely killed background process
        if [ -n "$bg_pid" ] && [ "$bg_pid" -gt 0 ] 2>/dev/null; then
            if ! kill -0 "$bg_pid" 2>/dev/null; then
                sleep 0.1
                st=$(jq -r '.status // "PENDING"' "$prom_file" 2>/dev/null || echo "PENDING")
                ec=$(jq -r '.exit_code // empty' "$prom_file" 2>/dev/null || true)
                if [ "$st" = "RESOLVED" ] || [ "$st" = "REJECTED" ]; then
                    [ -f "$prom_out" ] && cat "$prom_out"
                    return "${ec:-0}"
                fi
                ui_err "Process PID $bg_pid for promise $prom_id died unexpectedly." >&2
                jq '.status = "REJECTED" | .exit_code = 137' "$prom_file" > "${prom_file}.dead.$$" 2>/dev/null && mv "${prom_file}.dead.$$" "$prom_file" 2>/dev/null || true
                printf "ERROR: Process PID %s terminated prematurely (crashed or killed)\n" "$bg_pid" >&2
                return 137
            fi
        fi

        sleep 0.05
    done
}

# Awaits resolution of multiple async promise handles concurrently (Multi-promise barrier)
# Usage: fifo_await_all <promise_id1> [promise_id2 ...] [timeout_s]
fifo_await_all() {
    local promises=()
    local timeout=60

    local args=("$@")
    if [ "${#args[@]}" -gt 1 ]; then
        local last_idx=$((${#args[@]} - 1))
        local last_arg="${args[$last_idx]}"
        if [[ "$last_arg" =~ ^[0-9]+$ ]]; then
            timeout="$last_arg"
            unset 'args[last_idx]'
        fi
    fi

    for a in "${args[@]}"; do
        IFS=',' read -ra split_arr <<< "$a"
        for p in "${split_arr[@]}"; do
            [ -n "$p" ] && promises+=("$p")
        done
    done

    [ "${#promises[@]}" -eq 0 ] && return 0

    local start_ts now_ts elapsed
    start_ts=$(date +%s)

    while true; do
        now_ts=$(date +%s)
        elapsed=$((now_ts - start_ts))
        if [ "$elapsed" -ge "$timeout" ]; then
            ui_warn "fifo_await_all timed out after ${timeout}s" >&2
            return 124
        fi

        local all_done=true
        local any_failed=false
        local fail_code=1

        for prom_id in "${promises[@]}"; do
            local prom_file="$FIFO_IPC_DIR/promises/${prom_id}.json"
            if [ ! -f "$prom_file" ]; then
                any_failed=true
                fail_code=1
                all_done=true
                break
            fi

            local st ec bg_pid
            st=$(jq -r '.status // "PENDING"' "$prom_file" 2>/dev/null || echo "PENDING")
            ec=$(jq -r '.exit_code // empty' "$prom_file" 2>/dev/null || true)
            bg_pid=$(jq -r '.pid // empty' "$prom_file" 2>/dev/null || true)

            if [ "$st" = "REJECTED" ]; then
                any_failed=true
                fail_code="${ec:-1}"
            elif [ "$st" = "RUNNING" ] || [ "$st" = "PENDING" ]; then
                # Check for dead worker PID
                if [ -n "$bg_pid" ] && [ "$bg_pid" -gt 0 ] 2>/dev/null; then
                    if ! kill -0 "$bg_pid" 2>/dev/null; then
                        sleep 0.05
                        st=$(jq -r '.status // "PENDING"' "$prom_file" 2>/dev/null || echo "PENDING")
                        if [ "$st" != "RESOLVED" ]; then
                            jq '.status = "REJECTED" | .exit_code = 137' "$prom_file" > "${prom_file}.dead.$$" 2>/dev/null && mv "${prom_file}.dead.$$" "$prom_file" 2>/dev/null || true
                            any_failed=true
                            fail_code=137
                        fi
                    else
                        all_done=false
                    fi
                else
                    all_done=false
                fi
            fi
        done

        if [ "$any_failed" = "true" ]; then
            return "$fail_code"
        fi

        if [ "$all_done" = "true" ]; then
            return 0
        fi

        sleep 0.05
    done
}

# ── 5. FIFO <-> MQTT Bridge Integration ──────────────────────────────

# Attaches an MQTT bridge to a FIFO channel for node-to-node routing.
# Direction: "out" (forward local FIFO frames -> MQTT topic)
#            "in"  (forward MQTT topic messages -> local FIFO channel)
# Usage: fifo_mqtt_bridge_start <channel_id> <mqtt_topic> [direction="out"]
fifo_mqtt_bridge_start() {
    local cid="$1"
    local topic="$2"
    local dir="${3:-out}"
    local cdir="$FIFO_IPC_DIR/channels/$cid"
    local state_file="$cdir/state.json"

    [ ! -f "$state_file" ] && return 1

    source "$LODGE_DIR/lib/mqtt.sh" 2>/dev/null || true
    declare -f mqtt_init &>/dev/null && mqtt_init || true

    local bridge_pid_file="$cdir/bridge_${dir}.pid"

    if [ "$dir" = "out" ]; then
        # Worker forwards frames from local FIFO data stream to remote MQTT topic
        (
            while [ -f "$state_file" ] && [ "$(jq -r '.status // empty' "$state_file" 2>/dev/null)" = "OPEN" ]; do
                local frame
                frame=$(fifo_read_frame "$cid" 2 1 2>/dev/null || true)
                if [ -n "$frame" ]; then
                    declare -f mqtt_publish &>/dev/null && mqtt_publish "$topic" "$frame" >/dev/null 2>&1 || true
                fi
                sleep 0.05
            done
        ) </dev/null >/dev/null 2>&1 &
        local b_pid=$!
        echo "$b_pid" > "$bridge_pid_file"
        jq --argjson bp "$b_pid" --arg top "$topic" '.mqtt_out_bridge = {pid: $bp, topic: $top}' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true
    elif [ "$dir" = "in" ]; then
        # Worker subscribes to MQTT and writes incoming messages into FIFO
        (
            while [ -f "$state_file" ] && [ "$(jq -r '.status // empty' "$state_file" 2>/dev/null)" = "OPEN" ]; do
                local msg
                msg=$(mqtt_subscribe "$topic" --count 1 --timeout 2 2>/dev/null || true)
                if [ -n "$msg" ]; then
                    fifo_write_frame "$cid" "$msg" 2 2>/dev/null || true
                fi
                sleep 0.05
            done
        ) </dev/null >/dev/null 2>&1 &
        local b_pid=$!
        echo "$b_pid" > "$bridge_pid_file"
        jq --argjson bp "$b_pid" --arg top "$topic" '.mqtt_in_bridge = {pid: $bp, topic: $top}' "$state_file" > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" 2>/dev/null || true
    fi

    return 0
}

# Stops attached FIFO-MQTT bridge workers
# Usage: fifo_mqtt_bridge_stop <channel_id>
fifo_mqtt_bridge_stop() {
    local cid="$1"
    local cdir="$FIFO_IPC_DIR/channels/$cid"
    [ ! -d "$cdir" ] && return 0

    for pf in "$cdir"/bridge_*.pid; do
        if [ -f "$pf" ]; then
            local bpid
            bpid=$(cat "$pf" 2>/dev/null)
            [ -n "$bpid" ] && kill "$bpid" 2>/dev/null || true
            rm -f "$pf" 2>/dev/null || true
        fi
    done
    return 0
}

