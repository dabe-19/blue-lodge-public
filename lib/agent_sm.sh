#!/bin/bash
# ── George: Sovereign POSIX State Machine & Clone Management Engine ───
# Manages concurrent agent sessions and multiple George clones working in
# sandboxes across nodes with async/await, credit flow control, and sentinel culling.
#
# States:
#   SPAWNED -> READY -> RUNNING
#   RUNNING -> FLOW_PAUSED -> RUNNING
#   RUNNING -> AWAITING_PEER -> RUNNING
#   RUNNING -> RESOLVING -> COMPLETED
#   ANY -> FAILED
#   ANY -> ORPHANED -> CULLED

[ -n "${_LIB_AGENT_SM_LOADED:-}" ] && return 0; _LIB_AGENT_SM_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
AGENT_SM_REGISTRY="${AGENT_SM_REGISTRY:-${GEORGE_DIR}/agents_sm.json}"
CLONE_HEARTBEAT_TIMEOUT_SEC="${CLONE_HEARTBEAT_TIMEOUT_SEC:-60}"

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mqtt.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/fifo_ipc.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/task_sync.sh" 2>/dev/null || true

agent_sm_init() {
    local gdir="${1:-$GEORGE_DIR}"
    GEORGE_DIR="$gdir"
    AGENT_SM_REGISTRY="${GEORGE_DIR}/agents_sm.json"
    mkdir -p "$GEORGE_DIR" "$GEORGE_DIR/agents" "$GEORGE_DIR/ipc" 2>/dev/null || true

    if [ ! -f "$AGENT_SM_REGISTRY" ]; then
        echo "[]" > "$AGENT_SM_REGISTRY" 2>/dev/null || true
    fi

    declare -f fifo_ipc_init &>/dev/null && fifo_ipc_init "$GEORGE_DIR/ipc" || true
    declare -f mqtt_init &>/dev/null && mqtt_init || true
}

# ── 1. Registration & State Transitions ──────────────────────────────

# Registers a new agent or clone in the state machine
# Usage: agent_sm_register <agent_id> <clone_type> <task_desc> [gpu_port] [parent_id]
agent_sm_register() {
    local aid="$1"
    local ctype="${2:-worker}"
    local desc="$3"
    local gpu_port="${4:-18080}"
    local parent_id="${5:-george_primary}"

    agent_sm_init

    local now_ts
    now_ts=$(date +%s)
    local sdir="${LODGE_DIR}/.sandboxes/${aid}"
    local br="clone/${aid}"

    # Open local FIFO channel
    fifo_channel_open "$aid" 5 2>/dev/null || true

    local new_entry
    new_entry=$(jq -n \
        --arg aid "$aid" \
        --arg ctype "$ctype" \
        --arg desc "$desc" \
        --arg parent "$parent_id" \
        --argjson gpu "$gpu_port" \
        --arg sdir "$sdir" \
        --arg br "$br" \
        --arg ts "$now_ts" \
        '{
            agent_id: $aid,
            clone_type: $ctype,
            parent_id: $parent,
            node_id: "local_node",
            gpu_port: $gpu,
            sandbox_dir: $sdir,
            branch: $br,
            pid: 0,
            channel_id: $aid,
            state: "SPAWNED",
            credits: 5,
            last_heartbeat: ($ts | tonumber),
            created_at: ($ts | tonumber),
            task_description: $desc,
            resolution: null
        }')

    # Upsert into registry atomically
    local cur
    cur=$(cat "$AGENT_SM_REGISTRY" 2>/dev/null || echo "[]")
    echo "$cur" | jq --arg aid "$aid" --argjson e "$new_entry" 'map(select(.agent_id != $aid)) + [$e]' > "${AGENT_SM_REGISTRY}.tmp" 2>/dev/null && mv "${AGENT_SM_REGISTRY}.tmp" "$AGENT_SM_REGISTRY" 2>/dev/null || true

    # Emit state event over FIFO and MQTT
    task_sync_send "$aid" "state" "$new_entry" 2>/dev/null || true
    return 0
}

# Transition an agent to a new state with validation and notification
# Usage: agent_sm_transition <agent_id> <new_state> [reason_or_metadata]
agent_sm_transition() {
    local aid="$1"
    local new_state="$2"
    local reason="${3:-}"

    agent_sm_init

    local cur
    cur=$(cat "$AGENT_SM_REGISTRY" 2>/dev/null || echo "[]")
    local entry
    entry=$(echo "$cur" | jq --arg aid "$aid" '.[] | select(.agent_id == $aid)' 2>/dev/null)

    if [ -z "$entry" ] || [ "$entry" = "null" ]; then
        return 1
    fi

    local old_state
    old_state=$(echo "$entry" | jq -r '.state')

    # Guard terminal states: COMPLETED or CULLED cannot regress to RUNNING or READY
    if [ "$old_state" = "COMPLETED" ] || [ "$old_state" = "CULLED" ]; then
        if [ "$new_state" = "RUNNING" ] || [ "$new_state" = "READY" ] || [ "$new_state" = "FLOW_PAUSED" ]; then
            return 0
        fi
    fi

    # Atomic update
    local now_ts
    now_ts=$(date +%s)
    local updated
    updated=$(echo "$cur" | jq \
        --arg aid "$aid" \
        --arg st "$new_state" \
        --arg rsn "$reason" \
        --arg ts "$now_ts" \
        'map(if .agent_id == $aid then .state = $st | .last_heartbeat = ($ts | tonumber) | .transition_reason = $rsn else . end)')

    echo "$updated" > "${AGENT_SM_REGISTRY}.tmp" 2>/dev/null && mv "${AGENT_SM_REGISTRY}.tmp" "$AGENT_SM_REGISTRY" 2>/dev/null || true

    # Broadcast state transition over FIFO and MQTT
    local evt
    evt=$(jq -nc \
        --arg aid "$aid" \
        --arg from "$old_state" \
        --arg to "$new_state" \
        --arg rsn "$reason" \
        --arg ts "$now_ts" \
        '{agent_id: $aid, from: $from, to: $to, reason: $rsn, timestamp: ($ts | tonumber)}')

    task_sync_send "$aid" "transition" "$evt" 2>/dev/null || true

    # Also signal MQTT event
    if declare -f mqtt_publish &>/dev/null; then
        mqtt_publish "george/agents/${aid}/state" "$evt" --retain >/dev/null 2>&1 || true
    fi

    return 0
}

# Updates agent heartbeat liveness timestamp
# Usage: agent_sm_heartbeat <agent_id>
agent_sm_heartbeat() {
    local aid="$1"
    agent_sm_init

    local now_ts
    now_ts=$(date +%s)
    local cur
    cur=$(cat "$AGENT_SM_REGISTRY" 2>/dev/null || echo "[]")

    echo "$cur" | jq --arg aid "$aid" --arg ts "$now_ts" \
        'map(if .agent_id == $aid then .last_heartbeat = ($ts | tonumber) else . end)' > "${AGENT_SM_REGISTRY}.tmp" 2>/dev/null && mv "${AGENT_SM_REGISTRY}.tmp" "$AGENT_SM_REGISTRY" 2>/dev/null || true

    # Lightweight MQTT heartbeat
    if declare -f mqtt_publish &>/dev/null; then
        mqtt_publish "george/agents/${aid}/heartbeat" "{\"agent_id\":\"$aid\",\"timestamp\":$now_ts}" >/dev/null 2>&1 || true
    fi
    return 0
}

# Sets the OS process PID for a registered agent
agent_sm_set_pid() {
    local aid="$1"
    local pid="$2"
    agent_sm_init

    local cur
    cur=$(cat "$AGENT_SM_REGISTRY" 2>/dev/null || echo "[]")
    echo "$cur" | jq --arg aid "$aid" --argjson p "$pid" \
        'map(if .agent_id == $aid then .pid = $p else . end)' > "${AGENT_SM_REGISTRY}.tmp" 2>/dev/null && mv "${AGENT_SM_REGISTRY}.tmp" "$AGENT_SM_REGISTRY" 2>/dev/null || true
}

# ── 2. Flow Control Integration ──────────────────────────────────────

# Dispatches flow control signals to an active clone
# Usage: agent_sm_flow_control <agent_id> <action>
# Actions: PAUSE | RESUME | CREDIT <N>
agent_sm_flow_control() {
    local aid="$1"
    local action="$2"
    agent_sm_init

    case "$action" in
        PAUSE)
            task_sync_flow_control "$aid" "PAUSE"
            agent_sm_transition "$aid" "FLOW_PAUSED" "Operator or backpressure paused"
            ;;
        RESUME)
            task_sync_flow_control "$aid" "RESUME"
            agent_sm_transition "$aid" "RUNNING" "Flow control resumed"
            ;;
        CREDIT\ *)
            task_sync_flow_control "$aid" "$action"
            ;;
    esac
    return 0
}

# ── 3. Autonomous George Clone Lifecycle ─────────────────────────────

# Spawns a new George clone in an isolated git worktree with FIFO and MQTT attached
# Usage: agent_sm_spawn_clone <agent_id> <task_cmd_or_objective> [gpu_port] [parent_id]
agent_sm_spawn_clone() {
    local aid="$1"
    local objective="$2"
    local gpu_port="${3:-18080}"
    local parent_id="${4:-george_primary}"

    agent_sm_init

    local sdir="${LODGE_DIR}/.sandboxes/${aid}"
    local br="clone/${aid}"

    # Provision isolated git worktree sandbox
    mkdir -p "$(dirname "$sdir")" 2>/dev/null || true
    git -C "$LODGE_DIR" branch -D "$br" >/dev/null 2>&1 || true
    git -C "$LODGE_DIR" worktree remove --force "$sdir" >/dev/null 2>&1 || true
    git -C "$LODGE_DIR" worktree add -b "$br" "$sdir" HEAD >/dev/null 2>&1 || {
        ui_err "Failed to provision clone worktree $sdir" >&2
        return 1
    }

    # Register in state machine
    agent_sm_register "$aid" "george_clone" "$objective" "$gpu_port" "$parent_id"
    agent_sm_transition "$aid" "READY" "Worktree provisioned"

    local main_george_dir="$GEORGE_DIR"
    local main_lodge_dir="$LODGE_DIR"

    # Worker script executing within sandbox
    local worker_script="$sdir/run_worker.sh"
    cat > "$worker_script" <<EOF
#!/bin/bash
cd "$sdir" || exit 1
export SANDBOX_DIR="$sdir"
export LODGE_DIR="$main_lodge_dir"
export GEORGE_DIR="$main_george_dir"
export ACTIVE_TIER=2
export ACTIVE_ENDPOINT_URL="http://127.0.0.1:${gpu_port}"

cleanup_worker() {
    local ec=\$?
    [ -n "\$HB_PID" ] && kill \$HB_PID 2>/dev/null || true
    if [ -f "$main_lodge_dir/lib/agent_sm.sh" ]; then
        source "$main_lodge_dir/lib/agent_sm.sh" 2>/dev/null || true
        if [ \$ec -eq 0 ]; then
            agent_sm_transition "$aid" "COMPLETED" "Task succeeded" 2>/dev/null || true
        else
            agent_sm_transition "$aid" "FAILED" "Exit code \$ec" 2>/dev/null || true
        fi
    fi
}
trap cleanup_worker EXIT

# Periodic heartbeat loop
(
    while true; do
        sleep 5
        bash -c 'source "$main_lodge_dir/lib/agent_sm.sh" 2>/dev/null; agent_sm_heartbeat "$aid"' 2>/dev/null || true
    done
) </dev/null >/dev/null 2>&1 &
HB_PID=\$!

# Execute command in inner subshell so exit N is cleanly intercepted
( eval "$objective" ) > "$sdir/task.out" 2>&1
exit \$?
EOF
    chmod +x "$worker_script"

    agent_sm_transition "$aid" "RUNNING" "Executing async contract"

    # Spawn async worker attached to FIFO channel
    local prom_id
    prom_id=$(fifo_async "$aid" "bash '$worker_script'")
    
    # Extract PID and save promise_id in registry
    local wpid
    wpid=$(jq -r '.pid // 0' "$FIFO_IPC_DIR/promises/${prom_id}.json" 2>/dev/null || echo 0)
    
    local cur
    cur=$(cat "$AGENT_SM_REGISTRY" 2>/dev/null || echo "[]")
    echo "$cur" | jq --arg aid "$aid" --argjson p "$wpid" --arg prom "$prom_id" \
        'map(if .agent_id == $aid then .pid = $p | .promise_id = $prom else . end)' > "${AGENT_SM_REGISTRY}.tmp" 2>/dev/null && mv "${AGENT_SM_REGISTRY}.tmp" "$AGENT_SM_REGISTRY" 2>/dev/null || true

    echo "$aid"
    return 0
}

# Awaits resolution of an agent or clone
# Usage: agent_sm_await <agent_id> [timeout_s]
agent_sm_await() {
    local aid="$1"
    local timeout="${2:-30}"
    agent_sm_init

    local start_ts now_ts elapsed
    start_ts=$(date +%s)

    while true; do
        now_ts=$(date +%s)
        elapsed=$((now_ts - start_ts))
        if [ "$elapsed" -ge "$timeout" ]; then
            return 124
        fi

        local cur
        cur=$(cat "$AGENT_SM_REGISTRY" 2>/dev/null || echo "[]")
        local entry
        entry=$(echo "$cur" | jq --arg aid "$aid" '.[] | select(.agent_id == $aid)' 2>/dev/null)
        local st
        st=$(echo "$entry" | jq -r '.state // empty')

        if [ "$st" = "COMPLETED" ]; then
            return 0
        elif [ "$st" = "FAILED" ] || [ "$st" = "CULLED" ] || [ "$st" = "ORPHANED" ]; then
            return 1
        fi

        # Check promise status as fallback
        local prom_id
        prom_id=$(echo "$entry" | jq -r '.promise_id // empty')
        if [ -n "$prom_id" ] && [ -f "$FIFO_IPC_DIR/promises/${prom_id}.json" ]; then
            local p_st
            p_st=$(jq -r '.status // empty' "$FIFO_IPC_DIR/promises/${prom_id}.json" 2>/dev/null)
            if [ "$p_st" = "RESOLVED" ]; then
                local p_ec
                p_ec=$(jq -r '.exit_code // 0' "$FIFO_IPC_DIR/promises/${prom_id}.json" 2>/dev/null)
                if [ "$p_ec" -eq 0 ]; then
                    agent_sm_transition "$aid" "COMPLETED" "Resolved via promise"
                    return 0
                else
                    agent_sm_transition "$aid" "FAILED" "Failed with exit code $p_ec"
                    return 1
                fi
            fi
        fi

        sleep 0.1
    done
}

# ── 4. Sentinel Orphan Detection & Culling ────────────────────────────

# Probes for dead PIDs or expired heartbeats across active agents/clones
# Returns JSON array of flagged anomalies
# Usage: agent_sm_probe_orphans [timeout_sec]
agent_sm_probe_orphans() {
    local max_age="${1:-$CLONE_HEARTBEAT_TIMEOUT_SEC}"
    agent_sm_init

    local now_ts
    now_ts=$(date +%s)
    local cur
    cur=$(cat "$AGENT_SM_REGISTRY" 2>/dev/null || echo "[]")

    local flagged=()
    while read -r row; do
        [ -z "$row" ] && continue
        local aid st pid hb
        aid=$(echo "$row" | jq -r '.agent_id')
        st=$(echo "$row" | jq -r '.state')
        pid=$(echo "$row" | jq -r '.pid // 0')
        hb=$(echo "$row" | jq -r '.last_heartbeat // 0')

        # Check active states
        if [ "$st" = "RUNNING" ] || [ "$st" = "SPAWNED" ] || [ "$st" = "READY" ] || [ "$st" = "FLOW_PAUSED" ] || [ "$st" = "AWAITING_PEER" ]; then
            local is_alive=0
            if [ "$pid" -gt 0 ]; then
                kill -0 "$pid" 2>/dev/null && is_alive=1
            fi

            local age=$((now_ts - hb))
            if [ "$pid" -gt 0 ] && [ "$is_alive" -eq 0 ]; then
                flagged+=("{\"agent_id\":\"$aid\",\"reason\":\"PROCESS_DEAD\",\"age\":$age,\"pid\":$pid}")
            elif [ "$age" -ge "$max_age" ]; then
                flagged+=("{\"agent_id\":\"$aid\",\"reason\":\"HEARTBEAT_EXPIRED\",\"age\":$age,\"pid\":$pid}")
            fi
        fi
    done < <(echo "$cur" | jq -c '.[]' 2>/dev/null || true)

    if [ ${#flagged[@]} -gt 0 ]; then
        printf '%s\n' "${flagged[@]}" | jq -s .
    else
        echo "[]"
    fi
}

# Culls an orphaned or finished clone, cleaning worktree, processes, and FIFOs
# Usage: agent_sm_cull <agent_id> [reason]
agent_sm_cull() {
    local aid="$1"
    local reason="${2:-Manual or sentinel cull}"
    agent_sm_init

    local cur
    cur=$(cat "$AGENT_SM_REGISTRY" 2>/dev/null || echo "[]")
    local entry
    entry=$(echo "$cur" | jq --arg aid "$aid" '.[] | select(.agent_id == $aid)' 2>/dev/null)

    local pid sdir br
    pid=$(echo "$entry" | jq -r '.pid // 0' 2>/dev/null || echo 0)
    sdir=$(echo "$entry" | jq -r '.sandbox_dir // empty' 2>/dev/null || true)
    br=$(echo "$entry" | jq -r '.branch // empty' 2>/dev/null || true)

    # 1. Terminate process tree (guard against killing self or PID 1)
    if [ "$pid" -gt 1 ] && [ "$pid" -ne "$$" ] && [ "$pid" -ne "${BASHPID:-0}" ] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        sleep 0.1
        kill -KILL "$pid" 2>/dev/null || true
    fi

    # 2. Close FIFO channel
    fifo_channel_close "$aid" 2>/dev/null || true

    # 3. Cull git worktree cleanly
    if [ -n "$sdir" ] && [ -d "$sdir" ]; then
        git -C "$LODGE_DIR" worktree remove --force "$sdir" >/dev/null 2>&1 || true
        rm -rf "$sdir" 2>/dev/null || true
    fi

    # 4. Delete branch if present
    if [ -n "$br" ] && [ "$br" != "develop" ] && [ "$br" != "main" ]; then
        git -C "$LODGE_DIR" branch -D "$br" >/dev/null 2>&1 || true
    fi

    git -C "$LODGE_DIR" worktree prune >/dev/null 2>&1 || true

    # 5. Mark as CULLED
    agent_sm_transition "$aid" "CULLED" "$reason"

    # 6. Publish cull event to MQTT
    if declare -f mqtt_publish &>/dev/null; then
        local cull_evt
        cull_evt=$(jq -nc --arg aid "$aid" --arg rsn "$reason" --arg ts "$(date +%s)" '{agent_id:$aid, status:"CULLED", reason:$rsn, timestamp:($ts|tonumber)}')
        mqtt_publish "george/agents/${aid}/cull" "$cull_evt" >/dev/null 2>&1 || true
    fi

    return 0
}

# Lists registered agents/clones matching optional state filter
# Usage: agent_sm_list [state_filter]
agent_sm_list() {
    local filter="${1:-}"
    agent_sm_init

    local cur
    cur=$(cat "$AGENT_SM_REGISTRY" 2>/dev/null || echo "[]")
    if [ -n "$filter" ]; then
        echo "$cur" | jq --arg st "$filter" '[.[] | select(.state == $st)]'
    else
        echo "$cur"
    fi
}
