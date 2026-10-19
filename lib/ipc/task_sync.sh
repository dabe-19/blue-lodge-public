#!/bin/bash
# ── George: Sovereign Task-to-Task MQTT Coordination & Sync ──────────
# Enables parallel executing agent nodes and remediation sandboxes to:
#   1. Publish heartbeat, status, and remediation events over MQTT
#   2. Asynchronously wait/listen for peer task events with timeouts
#   3. Safely pull and rebase develop changes across concurrent worktrees
#   4. Manage git index lock contention and file conflicts cleanly

[ -n "${_LIB_TASK_SYNC_LOADED:-}" ] && return 0; _LIB_TASK_SYNC_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/mqtt.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/fifo_ipc.sh" 2>/dev/null || true

task_sync_init() {
    declare -f mqtt_init &>/dev/null && mqtt_init || true
    declare -f fifo_ipc_init &>/dev/null && fifo_ipc_init || true
}

# Publishes an event to MQTT topic george/tasks/<task_id>/<event_name>
task_sync_signal() {
    local task_id="$1"
    local event_name="$2"
    local payload="${3:-"{}"}"
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
# Delivery contract (one transport per hop):
#   * If the target has an OPEN local IPC channel, the message goes over the FIFO only.
#   * Otherwise it is published to MQTT (george/tasks/<target>/<event>).
#   * TASK_SYNC_MIRROR=1 additionally mirrors local deliveries to MQTT for dashboards;
#     both copies carry the same msg_id, and task_sync_recv de-duplicates on it.
# Every message is wrapped as {msg_id, origin, event, ts, payload}.

TASK_SYNC_NODE_ID="${TASK_SYNC_NODE_ID:-${GEORGE_NODE_ID:-${HOSTNAME:-node}}}"
TASK_SYNC_MIRROR="${TASK_SYNC_MIRROR:-0}"
TASK_SYNC_DEDUPE_MAX="${TASK_SYNC_DEDUPE_MAX:-512}"

# Builds the message envelope. Sets REPLY.
_task_sync_wrap() {
    local event="$1" payload="$2" mid
    mid="${TASK_SYNC_NODE_ID}-${BASHPID}-${EPOCHREALTIME//[.,]/}-${RANDOM}"
    printf '%s' "$payload" | jq -e . >/dev/null 2>&1 || payload=$(jq -nc --arg s "$payload" '$s')
    REPLY=$(jq -nc --arg mid "$mid" --arg org "$TASK_SYNC_NODE_ID" --arg ev "$event" \
        --argjson ts "${EPOCHSECONDS:-$(date +%s)}" --argjson pl "$payload" \
        '{msg_id: $mid, origin: $org, event: $ev, ts: $ts, payload: $pl}')
}

# Returns 0 if msg_id was already seen for target (and records it otherwise).
_task_sync_seen() {
    local target="$1" mid="$2"
    [ -z "$mid" ] && return 1
    local dir="${FIFO_IPC_DIR:-${GEORGE_DIR:-$LODGE_DIR/.george}/ipc}/sync_seen"
    local f="$dir/${target//[^A-Za-z0-9_.-]/_}.ids"
    local lk="${f}.lock"
    mkdir -p "$dir" 2>/dev/null
    (
        flock -w 2 200 2>/dev/null || true
        if [ -f "$f" ] && grep -qxF -- "$mid" "$f" 2>/dev/null; then
            exit 0
        fi
        printf '%s\n' "$mid" >> "$f"
        # Bound the dedupe window
        local n
        n=$(wc -l < "$f" 2>/dev/null || echo 0)
        if [ "$n" -gt $(( TASK_SYNC_DEDUPE_MAX * 2 )) ]; then
            tail -n "$TASK_SYNC_DEDUPE_MAX" "$f" > "${f}.tmp.${BASHPID:-$$}" 2>/dev/null && mv -f "${f}.tmp.${BASHPID:-$$}" "$f"
        fi
        exit 1
    ) 200>"$lk"
}

# Extracts msg_id from a raw message or IPC frame (zero-fork).
_task_sync_mid() {
    local raw="$1"
    REPLY=""
    [[ "$raw" =~ \"msg_id\":[[:space:]]*\"([^\"]+)\" ]] && REPLY="${BASH_REMATCH[1]}"
}

# Transmits message/event to a target agent or node.
# Usage: task_sync_send <target_id> <event_name> [payload_json]
task_sync_send() {
    local target="$1"
    local event="$2"
    local payload="${3:-"{}"}"
    [ -z "$target" ] || [ -z "$event" ] && return 1

    task_sync_init
    _task_sync_wrap "$event" "$payload"
    local msg="$REPLY"
    [ -z "$msg" ] && return 1

    local local_ok=0
    if declare -f ipc_channel_is_open &>/dev/null && ipc_channel_is_open "$target"; then
        local rc=0
        ipc_send "$target" "DATA" "$msg" "" 2 >/dev/null 2>&1 || rc=$?
        # Delivered (0) or durably queued behind backpressure (IPC_QUEUED) both count
        { [ "$rc" -eq 0 ] || [ "$rc" -eq "${IPC_QUEUED:-75}" ]; } && local_ok=1
    fi

    if [ "$local_ok" -eq 0 ] || [ "$TASK_SYNC_MIRROR" = "1" ]; then
        task_sync_signal "$target" "$event" "$msg" >/dev/null 2>&1 || [ "$local_ok" -eq 1 ] || return 1
    fi
    return 0
}

# Receives the next (de-duplicated) message for a target.
# Local FIFO first, then MQTT. Duplicates (same msg_id) are dropped.
# Usage: task_sync_recv <target_id> [timeout_s]
task_sync_recv() {
    local target="$1"
    local timeout="${2:-5}"
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=5

    task_sync_init
    local deadline=$(( ${EPOCHSECONDS:-$(date +%s)} + timeout )) remain msg

    while :; do
        remain=$(( deadline - ${EPOCHSECONDS:-$(date +%s)} ))
        [ "$remain" -le 0 ] && return 1
        msg=""
        if declare -f ipc_channel_is_open &>/dev/null && ipc_channel_is_open "$target"; then
            msg=$(ipc_recv "$target" "$remain" "" "" 1 2>/dev/null) || msg=""
        else
            msg=$(task_sync_wait "george/tasks/${target}/+" "$remain" 2>/dev/null) || msg=""
        fi
        [ -z "$msg" ] && return 1
        _task_sync_mid "$msg"
        if [ -n "$REPLY" ] && _task_sync_seen "$target" "$REPLY"; then
            continue
        fi
        printf '%s\n' "$msg"
        return 0
    done
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

# Applies a flow-control action to a local channel.
_task_sync_apply_flow() {
    local target="$1" action="$2"
    declare -f ipc_channel_is_open &>/dev/null && ipc_channel_is_open "$target" || return 1
    case "$action" in
        CREDIT\ *)
            local amt="${action#CREDIT }"
            [[ "$amt" =~ ^[0-9]+$ ]] || return 1
            ipc_flow_grant "$target" "$amt" >/dev/null 2>&1
            ;;
        PAUSE|RESUME|ABORT|PING|UNSTICK)
            ipc_flow_send_ctrl "$target" "$action" >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

# Transmits flow control commands locally and cluster-wide.
# Applied locally when this node hosts the channel; always published (with origin and
# msg_id) so a remote node hosting the channel can apply it via task_sync_flow_listen.
# Usage: task_sync_flow_control <target_agent> <action>
task_sync_flow_control() {
    local target="$1"
    local action="$2" # CREDIT <N> | PAUSE | RESUME | ABORT | PING
    [ -z "$target" ] || [ -z "$action" ] && return 1

    task_sync_init
    _task_sync_apply_flow "$target" "$action" || true

    local flow_payload
    flow_payload=$(jq -nc --arg tgt "$target" --arg act "$action" --arg org "$TASK_SYNC_NODE_ID" \
        --arg mid "${TASK_SYNC_NODE_ID}-${BASHPID}-${EPOCHREALTIME//[.,]/}" \
        --argjson ts "${EPOCHSECONDS:-$(date +%s)}" \
        '{msg_id: $mid, origin: $org, target: $tgt, action: $act, timestamp: $ts}')
    if declare -f mqtt_publish &>/dev/null; then
        mqtt_publish "george/agents/${target}/flow" "$flow_payload" >/dev/null 2>&1 || true
    fi
    return 0
}

# Subscriber for cluster-wide flow control. Applies remote-originated actions to the
# local channel exactly once (msg_id de-dupe, own-origin skip).
# Usage: task_sync_flow_listen <agent_id> [--once] [timeout_per_poll]
task_sync_flow_listen() {
    local target="$1" once=0 poll="${3:-5}"
    [ "${2:-}" = "--once" ] && once=1
    [ -z "$target" ] && return 1
    task_sync_init
    declare -f mqtt_subscribe &>/dev/null || return 1

    local msg org act tgt
    while :; do
        msg=$(mqtt_subscribe "george/agents/${target}/flow" --count 1 --timeout "$poll" 2>/dev/null || true)
        if [ -n "$msg" ]; then
            _task_sync_mid "$msg"
            if ! _task_sync_seen "flow_${target}" "$REPLY"; then
                org=""; act=""; tgt=""
                [[ "$msg" =~ \"origin\":[[:space:]]*\"([^\"]*)\" ]] && org="${BASH_REMATCH[1]}"
                [[ "$msg" =~ \"action\":[[:space:]]*\"([^\"]*)\" ]] && act="${BASH_REMATCH[1]}"
                [[ "$msg" =~ \"target\":[[:space:]]*\"([^\"]*)\" ]] && tgt="${BASH_REMATCH[1]}"
                if [ "$org" != "$TASK_SYNC_NODE_ID" ] && [ "$tgt" = "$target" ]; then
                    _task_sync_apply_flow "$target" "$act" || true
                fi
            fi
        fi
        [ "$once" -eq 1 ] && break
        # Stop when the local channel is gone
        declare -f ipc_channel_is_open &>/dev/null && ! ipc_channel_is_open "$target" && break
    done
    return 0
}
