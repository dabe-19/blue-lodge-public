#!/bin/bash
# ── George: Sovereign Task-to-Task MQTT Coordination & Sync ──────────
# Enables parallel executing agent nodes and remediation sandboxes to:
#   1. Publish heartbeat, status, and remediation events over MQTT
#   2. Asynchronously wait/listen for peer task events with timeouts
#   3. Safely pull and rebase develop changes across concurrent worktrees
#   4. Manage git index lock contention and file conflicts cleanly

[ -n "${_LIB_TASK_SYNC_LOADED:-}" ] && return 0; _LIB_TASK_SYNC_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mqtt.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/fifo_ipc.sh" 2>/dev/null || true

task_sync_init() {
    declare -f mqtt_init &>/dev/null && mqtt_init || true
    declare -f fifo_ipc_init &>/dev/null && fifo_ipc_init || true
}

# Publishes an event to MQTT topic george/tasks/<task_id>/<event_name>
task_sync_signal() {
    local task_id="$1"
    local event_name="$2"
    local payload="${3:-{}}"
    local retain="${4:---retain}"
    local topic="george/tasks/${task_id}/${event_name}"

    task_sync_init
    if declare -f mqtt_publish &>/dev/null; then
        mqtt_publish "$topic" "$payload" "$retain" >/dev/null 2>&1
        return $?
    fi
    return 1
}

# Waits for a specific event on an MQTT topic or specific remediation resolution
# Usage: task_sync_wait <topic> [timeout_seconds] [match_key] [match_val]
task_sync_wait() {
    local topic="$1"
    local timeout="${2:-15}"
    local match_key="${3:-}"
    local match_val="${4:-}"

    task_sync_init
    if ! declare -f mqtt_subscribe &>/dev/null; then
        return 1
    fi

    local start_ts now_ts elapsed
    start_ts=$(date +%s)

    while true; do
        now_ts=$(date +%s)
        elapsed=$((now_ts - start_ts))
        [ "$elapsed" -ge "$timeout" ] && break

        local rem_time=$((timeout - elapsed))
        [ "$rem_time" -gt 3 ] && rem_time=3
        [ "$rem_time" -lt 1 ] && rem_time=1

        local msg
        msg=$(mqtt_subscribe "$topic" --count 1 --timeout "$rem_time" 2>/dev/null || true)
        if [ -n "$msg" ]; then
            if [ -n "$match_key" ]; then
                local actual_val
                actual_val=$(echo "$msg" | jq -r --arg k "$match_key" '.[$k] // empty' 2>/dev/null || true)
                if [ "$actual_val" = "$match_val" ]; then
                    echo "$msg"
                    return 0
                fi
            else
                echo "$msg"
                return 0
            fi
        fi
        sleep 0.5
    done
    return 1
}

# Safely rebases current branch on develop, handling lock contention and conflicts
# Usage: task_sync_rebase_develop [worktree_dir]
task_sync_rebase_develop() {
    local wt_dir="${1:-$PWD}"
    local max_retries=5
    local attempt=1

    while [ $attempt -le $max_retries ]; do
        # Check for stale index lock
        if [ -f "$wt_dir/.git/index.lock" ]; then
            if ! pgrep -f "git.*$wt_dir" >/dev/null 2>&1; then
                rm -f "$wt_dir/.git/index.lock" 2>/dev/null || true
            fi
        fi

        # Fetch latest develop from remotes
        if git -C "$wt_dir" fetch origin develop >/dev/null 2>&1 || git -C "$wt_dir" fetch gitea develop >/dev/null 2>&1; then
            # Attempt rebase
            if git -C "$wt_dir" rebase origin/develop >/dev/null 2>&1; then
                declare -f ui_ok &>/dev/null && ui_ok "Successfully rebased on origin/develop in $wt_dir" >&2
                return 0
            else
                # Rebase failed: abort and try clean recursive merge strategy
                git -C "$wt_dir" rebase --abort >/dev/null 2>&1 || true
                declare -f ui_warn &>/dev/null && ui_warn "Rebase conflict detected in $wt_dir. Reconciling with develop..." >&2
                if git -C "$wt_dir" merge -X ours origin/develop -m "chore(sync): reconcile parallel updates with develop" >/dev/null 2>&1; then
                    declare -f ui_ok &>/dev/null && ui_ok "Cleanly merged origin/develop into $wt_dir" >&2
                    return 0
                fi
            fi
        fi

        attempt=$((attempt + 1))
        sleep 1
    done

    declare -f ui_err &>/dev/null && ui_err "Failed to synchronize $wt_dir with develop after $max_retries attempts" >&2
    return 1
}

# ── Unified POSIX FIFO + MQTT Protocol Dispatch ──────────────────────

# Transmits message/event to a target agent or node.
# Transparently routes via local FIFO IPC if target channel is local,
# while always publishing to MQTT retained topic for cluster discovery.
# Usage: task_sync_send <target_id> <event_name> [payload_json]
task_sync_send() {
    local target="$1"
    local event="$2"
    local payload="${3:-{}}"

    task_sync_init

    # 1. Local FIFO transmission if channel is open
    if declare -f fifo_channel_is_open &>/dev/null && fifo_channel_is_open "$target"; then
        fifo_write_frame "$target" "$payload" 2 >/dev/null 2>&1 || true
    fi

    # 2. Sovereign MQTT retained event broadcast
    task_sync_signal "$target" "$event" "$payload" >/dev/null 2>&1 || true
    return 0
}

# Receives next event from target agent or node.
# Checks local FIFO stream first (<5ms), falling back to MQTT subscription.
# Usage: task_sync_recv <target_id> [timeout_s]
task_sync_recv() {
    local target="$1"
    local timeout="${2:-5}"

    task_sync_init

    # 1. Try local FIFO channel first
    if declare -f fifo_channel_is_open &>/dev/null && fifo_channel_is_open "$target"; then
        local frame
        frame=$(fifo_read_frame "$target" "$timeout" 1 2>/dev/null || true)
        if [ -n "$frame" ]; then
            echo "$frame"
            return 0
        fi
    fi

    # 2. Fall back to MQTT subscription
    local topic="george/tasks/${target}/+"
    task_sync_wait "$topic" "$timeout"
}

# Executes an async task connected to target channel/agent
# Usage: task_sync_async <channel_id> <command_line>
task_sync_async() {
    local cid="$1"
    local cmd="$2"
    task_sync_init

    if declare -f fifo_async &>/dev/null; then
        fifo_async "$cid" "$cmd"
    else
        echo "ERROR: fifo_async not available" >&2
        return 1
    fi
}

# Awaits completion of an async task handle
# Usage: task_sync_await <promise_id> [timeout_s]
task_sync_await() {
    local prom_id="$1"
    local timeout="${2:-30}"
    task_sync_init

    if declare -f fifo_await &>/dev/null; then
        fifo_await "$prom_id" "$timeout"
    else
        echo "ERROR: fifo_await not available" >&2
        return 1
    fi
}

# Transmits flow control commands locally and cluster-wide
# Usage: task_sync_flow_control <target_agent> <action>
task_sync_flow_control() {
    local target="$1"
    local action="$2" # CREDIT <N> | PAUSE | RESUME | ABORT | PING

    task_sync_init

    # Local FIFO control pipe
    if declare -f fifo_channel_is_open &>/dev/null && fifo_channel_is_open "$target"; then
        case "$action" in
            CREDIT\ *)
                local amt="${action#CREDIT }"
                fifo_flow_grant "$target" "$amt" >/dev/null 2>&1 || true
                ;;
            *)
                fifo_flow_send_ctrl "$target" "$action" >/dev/null 2>&1 || true
                ;;
        esac
    fi

    # Mirror flow command to MQTT topic
    local flow_payload
    flow_payload=$(jq -nc --arg tgt "$target" --arg act "$action" --arg ts "$(date +%s)" '{target:$tgt, action:$act, timestamp:($ts|tonumber)}')
    if declare -f mqtt_publish &>/dev/null; then
        mqtt_publish "george/agents/${target}/flow" "$flow_payload" >/dev/null 2>&1 || true
    fi
    return 0
}

