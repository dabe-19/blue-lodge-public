#!/bin/bash
# ── George: Multi-Node Swarm & MQTT Coordination Engine (2026) ────────
# Provides distributed REPL coordination across heterogeneous nodes:
#   - MCP JSON-RPC 2.0 wire protocol over MQTT pub/sub
#   - Master-Worker hierarchy with remote-master proxy execution
#   - POSIX SIGUSR1 non-blocking TUI push notification
#   - Slot 1 background execution with configurable operator gate
#   - Git remote branch synchronization for code delegation
#
# Pure POSIX shell — requires mosquitto-clients and jq.

[ -n "${_LIB_SWARM_LOADED:-}" ] && return 0; _LIB_SWARM_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
SWARM_DIR="${SWARM_DIR:-$GEORGE_DIR/swarm}"
SWARM_REGISTRY="${SWARM_REGISTRY:-$SWARM_DIR/nodes.json}"
SWARM_CONFIG="${SWARM_CONFIG:-$SWARM_DIR/swarm.conf}"
SWARM_QUEUE_FILE="${SWARM_QUEUE_FILE:-$SWARM_DIR/queue.json}"

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mqtt.sh" 2>/dev/null || true

# ── Swarm Defaults ───────────────────────────────────────────────────
SWARM_ROLE="${SWARM_ROLE:-none}"          # master | worker | none
SWARM_NODE_ID="${SWARM_NODE_ID:-}"
SWARM_CLUSTER_ID="${SWARM_CLUSTER_ID:-blue-lodge}"
SWARM_REQUIRE_APPROVAL="${SWARM_REQUIRE_APPROVAL:-0}" # 0 = auto in Slot 1, 1 = manual operator gate
SWARM_LISTENER_PID=""

# ── Init & State Management ──────────────────────────────────────────
swarm_init() {
    mkdir -p "$SWARM_DIR" 2>/dev/null || true

    if [ ! -f "$SWARM_REGISTRY" ] || [ ! -s "$SWARM_REGISTRY" ]; then
        echo "[]" > "$SWARM_REGISTRY"
    fi

    if [ ! -f "$SWARM_QUEUE_FILE" ] || [ ! -s "$SWARM_QUEUE_FILE" ]; then
        echo "[]" > "$SWARM_QUEUE_FILE"
    fi

    # Load persistent config if present
    if [ -f "$SWARM_CONFIG" ]; then
        while IFS='=' read -r key val; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            key=$(echo "$key" | tr -d '[:space:]')
            val=$(echo "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '"' | tr -d "'")
            [ -z "${!key+x}" ] || [ -z "${!key}" ] && printf -v "$key" '%s' "$val"
        done < "$SWARM_CONFIG"
    fi

    if [ -z "$SWARM_NODE_ID" ]; then
        SWARM_NODE_ID="node-$RANDOM"
    fi
}

swarm_save_config() {
    mkdir -p "$SWARM_DIR" 2>/dev/null || true
    cat << EOF > "$SWARM_CONFIG"
# Blue Lodge Swarm Configuration
SWARM_ROLE="$SWARM_ROLE"
SWARM_NODE_ID="$SWARM_NODE_ID"
SWARM_CLUSTER_ID="$SWARM_CLUSTER_ID"
SWARM_REQUIRE_APPROVAL="$SWARM_REQUIRE_APPROVAL"
MQTT_BROKER="${MQTT_BROKER:-localhost:1883}"
EOF
}

# ── JSON-RPC 2.0 Framing Helpers ──────────────────────────────────────
swarm_rpc_req() {
    local req_id="$1"
    local method="$2"
    local params_json="${3:-}"
    [ -z "$params_json" ] && params_json="{}"
    jq -n -c \
        --arg id "$req_id" \
        --arg m "$method" \
        --arg p "$params_json" \
        '{"jsonrpc":"2.0", "id":$id, "method":$m, "params":($p | try fromjson catch {})}'
}

swarm_rpc_resp() {
    local req_id="$1"
    local result_json="${2:-}"
    [ -z "$result_json" ] && result_json="{}"
    jq -n -c \
        --arg id "$req_id" \
        --arg res "$result_json" \
        '{"jsonrpc":"2.0", "id":$id, "result":($res | try fromjson catch {})}'
}

swarm_rpc_err() {
    local req_id="$1"
    local code="${2:-500}"
    local message="$3"
    jq -n -c \
        --arg id "$req_id" \
        --arg c "$code" \
        --arg msg "$message" \
        '{"jsonrpc":"2.0", "id":$id, "error":{"code":($c | tonumber? // 500), "message":$msg}}'
}

swarm_rpc_chunk() {
    local req_id="$1"
    local text="$2"
    jq -n -c \
        --arg id "$req_id" \
        --arg t "$text" \
        '{"jsonrpc":"2.0", "method":"repl/chunk", "params":{"id":$id, "text":$t}}'
}

# ── TUI Push Notification Signaling (POSIX SIGUSR1) ───────────────────
swarm_notify_operator() {
    local message="$1"
    local repl_pid_file="$SWARM_DIR/.repl.pid"

    if [ -f "$repl_pid_file" ]; then
        local rpid
        rpid=$(cat "$repl_pid_file" 2>/dev/null)
        if [ -n "$rpid" ] && kill -0 "$rpid" 2>/dev/null; then
            # Write alert badge to swarm notification file for the trap handler
            echo "$message" > "$SWARM_DIR/.pending_notice"
            kill -SIGUSR1 "$rpid" 2>/dev/null || true
            return 0
        fi
    fi

    # Fallback to direct TTY or stderr
    if [ -w "/dev/tty" ]; then
        printf "\n\033[1;36m🔔 [SWARM]\033[0m %s\n" "$message" > /dev/tty 2>/dev/null || true
    fi
}

# ── Master Host Mode ─────────────────────────────────────────────────
swarm_host() {
    local broker="${1:-${MQTT_BROKER:-localhost:1883}}"
    swarm_init

    mqtt_setup "$broker" 2>/dev/null || true
    if ! mqtt_available; then
        ui_err "mosquitto-clients required for swarm. Install with: sudo apt install mosquitto-clients"
        return 1
    fi

    SWARM_ROLE="master"
    SWARM_NODE_ID="master"
    swarm_save_config

    # Record master in registry
    local now_ts
    now_ts=$(date '+%Y-%m-%d %H:%M:%S')
    local tmp_reg="${SWARM_REGISTRY}.tmp.$$"
    jq --arg id "master" \
       --arg role "master" \
       --arg host "$(hostname)" \
       --arg tier "${ACTIVE_TIER:-1}" \
       --arg ts "$now_ts" \
       '[{id:$id, role:$role, host:$host, tier:$tier, status:"ONLINE", updated_at:$ts}]' \
       "$SWARM_REGISTRY" > "$tmp_reg" 2>/dev/null && mv "$tmp_reg" "$SWARM_REGISTRY"

    # Start Master background listener
    swarm_start_master_listener

    ui_ok "Master node active on broker $broker"
    ui_dim "  Cluster ID:   $SWARM_CLUSTER_ID"
    ui_dim "  To join a worker node:"
    ui_dim "    /swarm join $broker <node_name>"
    return 0
}

swarm_start_master_listener() {
    local pid_file="$SWARM_DIR/master_listener.pid"
    if [ -f "$pid_file" ]; then
        local old_pid
        old_pid=$(cat "$pid_file" 2>/dev/null)
        [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null && return 0
    fi

    # Launch background subscriber for george/master/inbox
    (
        _mqtt_build_args
        mosquitto_sub "${_MQTT_ARGS[@]}" -t "george/master/inbox" 2>/dev/null | while read -r line; do
            [ -z "$line" ] && continue
            _swarm_master_handle_message "$line"
        done
    ) &
    local listener_pid=$!
    echo "$listener_pid" > "$pid_file"
}

_swarm_master_handle_message() {
    local raw_json="$1"
    local method req_id
    method=$(echo "$raw_json" | jq -r '.method // empty' 2>/dev/null)
    req_id=$(echo "$raw_json" | jq -r '.id // empty' 2>/dev/null)

    case "$method" in
        node/join)
            local nid nhost ntier ngpu
            nid=$(echo "$raw_json" | jq -r '.params.node_id // empty')
            nhost=$(echo "$raw_json" | jq -r '.params.host // "unknown"')
            ntier=$(echo "$raw_json" | jq -r '.params.tier // "2"')
            ngpu=$(echo "$raw_json" | jq -r '.params.gpu // "none"')
            [ -z "$nid" ] && return

            local ts
            ts=$(date '+%Y-%m-%d %H:%M:%S')
            local tmp_reg="${SWARM_REGISTRY}.tmp.$$"
            jq --arg id "$nid" --arg h "$nhost" --arg t "$ntier" --arg g "$ngpu" --arg ts "$ts" '
                (map(select(.id != $id))) + [{id:$id, role:"worker", host:$h, tier:$t, gpu:$g, status:"ONLINE", updated_at:$ts}]
            ' "$SWARM_REGISTRY" > "$tmp_reg" 2>/dev/null && mv "$tmp_reg" "$SWARM_REGISTRY"

            # Send ack back to worker inbox
            local ack_msg
            ack_msg=$(swarm_rpc_resp "$req_id" "{\"status\":\"JOINED\", \"cluster\":\"$SWARM_CLUSTER_ID\", \"master\":\"master\"}")
            mqtt_publish "george/node/$nid/inbox" "$ack_msg"

            swarm_notify_operator "Worker '$nid' joined from $nhost (Tier $ntier, GPU: $ngpu)"
            ;;

        node/leave)
            local nid
            nid=$(echo "$raw_json" | jq -r '.params.node_id // empty')
            if [ -n "$nid" ]; then
                local tmp_reg="${SWARM_REGISTRY}.tmp.$$"
                jq --arg id "$nid" 'map(if .id == $id then .status = "OFFLINE" else . end)' \
                    "$SWARM_REGISTRY" > "$tmp_reg" 2>/dev/null && mv "$tmp_reg" "$SWARM_REGISTRY"
                swarm_notify_operator "Worker '$nid' disconnected from swarm"
            fi
            ;;

        repl/exec)
            local from_node cmd
            from_node=$(echo "$raw_json" | jq -r '.params.from // empty')
            cmd=$(echo "$raw_json" | jq -r '.params.command // empty')
            [ -z "$from_node" ] || [ -z "$cmd" ] && return

            if [ "${SWARM_REQUIRE_APPROVAL:-0}" -eq 1 ]; then
                # Queue request for operator approval
                local ts
                ts=$(date '+%Y-%m-%d %H:%M:%S')
                local tmp_q="${SWARM_QUEUE_FILE}.tmp.$$"
                jq --arg id "$req_id" --arg from "$from_node" --arg c "$cmd" --arg ts "$ts" '
                    . += [{id:$id, from:$from, command:$c, status:"PENDING_APPROVAL", timestamp:$ts}]
                ' "$SWARM_QUEUE_FILE" > "$tmp_q" 2>/dev/null && mv "$tmp_q" "$SWARM_QUEUE_FILE"

                swarm_notify_operator "Worker '$from_node' requested: '$cmd' [/swarm approve $req_id]"
            else
                # Autonomous execution in Slot 1
                swarm_notify_operator "Worker '$from_node' executing: '$cmd' in Slot 1"
                _swarm_execute_remote_command "$req_id" "$from_node" "$cmd" &
            fi
            ;;
    esac
}

_swarm_execute_remote_command() {
    local req_id="$1"
    local from_node="$2"
    local cmd="$3"
    local stream_topic="george/node/$from_node/stream"
    local inbox_topic="george/node/$from_node/inbox"

    # Stream starting header
    local chunk_start
    chunk_start=$(swarm_rpc_chunk "$req_id" "[Master: Executing '$cmd' in Slot 1...]\n")
    mqtt_publish "$stream_topic" "$chunk_start"

    # Execute command (slash command or react task)
    local out_tmp
    out_tmp=$(mktemp)
    local exit_code=0

    if [[ "$cmd" == /* ]]; then
        # Slash command dispatch
        (
            export LODGE_NONINTERACTIVE=1
            export ACTIVE_TIER=1
            commands_dispatch "$cmd" "$LODGE_DIR"
        ) > "$out_tmp" 2>&1
        exit_code=$?
    else
        # Natural language prompt via react_run (non-interactive)
        (
            export LODGE_NONINTERACTIVE=1
            export ACTIVE_TIER=1
            react_run "$cmd" "$LODGE_DIR" 15 1 "swarm_${req_id}" "default"
        ) > "$out_tmp" 2>&1
        exit_code=$?
    fi

    # Stream output lines
    while IFS= read -r line || [ -n "$line" ]; do
        local chunk
        chunk=$(swarm_rpc_chunk "$req_id" "$line\n")
        mqtt_publish "$stream_topic" "$chunk"
    done < "$out_tmp"
    rm -f "$out_tmp" 2>/dev/null

    # Send completion result
    local res_payload
    res_payload=$(swarm_rpc_resp "$req_id" "{\"exit_code\":$exit_code, \"status\":\"DONE\"}")
    mqtt_publish "$inbox_topic" "$res_payload"
}

# ── Worker Join Mode ─────────────────────────────────────────────────
swarm_join() {
    local broker="${1:-${MQTT_BROKER:-localhost:1883}}"
    local node_name="${2:-worker-$RANDOM}"
    swarm_init

    mqtt_setup "$broker" 2>/dev/null || true
    if ! mqtt_available; then
        ui_err "mosquitto-clients required for swarm. Install with: sudo apt install mosquitto-clients"
        return 1
    fi

    SWARM_ROLE="worker"
    SWARM_NODE_ID="$node_name"
    swarm_save_config

    # Start Worker background listener
    swarm_start_worker_listener "$node_name"

    # Send join handshake
    local req_id="join-$RANDOM"
    local gpu_info="none"
    command -v nvidia-smi &>/dev/null && gpu_info=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    [ -z "$gpu_info" ] && command -v rocm-smi &>/dev/null && gpu_info="AMD ROCm GPU"

    local join_params
    join_params=$(jq -n -c \
        --arg nid "$node_name" \
        --arg host "$(hostname)" \
        --arg tier "${ACTIVE_TIER:-2}" \
        --arg gpu "$gpu_info" \
        '{"node_id":$nid, "host":$host, "tier":$tier, "gpu":$gpu}')

    local join_msg
    join_msg=$(swarm_rpc_req "$req_id" "node/join" "$join_params")
    mqtt_publish "george/master/inbox" "$join_msg"

    ui_ok "Joined swarm on $broker as '$node_name'"
    ui_dim "  Master target: george/master/inbox"
    ui_dim "  Run command remotely on master:"
    ui_dim "    /remote-master <cmd>"
    return 0
}

swarm_start_worker_listener() {
    local node_name="$1"
    local pid_file="$SWARM_DIR/worker_listener.pid"
    if [ -f "$pid_file" ]; then
        local old_pid
        old_pid=$(cat "$pid_file" 2>/dev/null)
        [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null && return 0
    fi

    (
        _mqtt_build_args
        mosquitto_sub "${_MQTT_ARGS[@]}" -t "george/node/$node_name/inbox" 2>/dev/null | while read -r line; do
            [ -z "$line" ] && continue
            _swarm_worker_handle_message "$line"
        done
    ) &
    local listener_pid=$!
    echo "$listener_pid" > "$pid_file"
}

_swarm_worker_handle_message() {
    local raw_json="$1"
    local method req_id
    method=$(echo "$raw_json" | jq -r '.method // empty' 2>/dev/null)
    req_id=$(echo "$raw_json" | jq -r '.id // empty' 2>/dev/null)

    case "$method" in
        task/spawn)
            local cmd task_branch
            cmd=$(echo "$raw_json" | jq -r '.params.command // empty')
            task_branch=$(echo "$raw_json" | jq -r '.params.branch // empty')
            [ -z "$cmd" ] && return

            # Execute delegated task in worktree or local dir
            _swarm_worker_execute_delegated "$req_id" "$cmd" "$task_branch" &
            ;;
    esac
}

_swarm_worker_execute_delegated() {
    local req_id="$1"
    local cmd="$2"
    local branch="${3:-}"
    local stream_topic="george/master/stream"
    local inbox_topic="george/master/inbox"

    local work_dir="$LODGE_DIR"
    local wt_dir=""
    if [ -n "$branch" ] && git -C "$LODGE_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
        wt_dir="$LODGE_DIR/.george/workspaces/swarm_${req_id}"
        mkdir -p "$(dirname "$wt_dir")" 2>/dev/null
        if git -C "$LODGE_DIR" worktree add -q -b "$branch" "$wt_dir" 2>/dev/null; then
            work_dir="$wt_dir"
        fi
    fi

    # Stream initial ack
    local chunk_start
    chunk_start=$(swarm_rpc_chunk "$req_id" "[Worker $SWARM_NODE_ID: Running '$cmd'...]\n")
    mqtt_publish "$stream_topic" "$chunk_start"

    # Execute
    local out_tmp
    out_tmp=$(mktemp)
    local exit_code=0
    (
        export LODGE_NONINTERACTIVE=1
        cd "$work_dir" && bash -c "$cmd"
    ) > "$out_tmp" 2>&1
    exit_code=$?

    # Stream output
    while IFS= read -r line || [ -n "$line" ]; do
        local chunk
        chunk=$(swarm_rpc_chunk "$req_id" "$line\n")
        mqtt_publish "$stream_topic" "$chunk"
    done < "$out_tmp"
    rm -f "$out_tmp" 2>/dev/null

    # Clean worktree if used
    if [ -n "$wt_dir" ] && [ -d "$wt_dir" ]; then
        git -C "$LODGE_DIR" worktree remove --force "$wt_dir" 2>/dev/null || rm -rf "$wt_dir"
        git -C "$LODGE_DIR" worktree prune 2>/dev/null || true
    fi

    # Return result
    local res_payload
    res_payload=$(swarm_rpc_resp "$req_id" "{\"node\":\"$SWARM_NODE_ID\", \"exit_code\":$exit_code, \"status\":\"DONE\"}")
    mqtt_publish "$inbox_topic" "$res_payload"
}

# ── Remote-Master Proxy (Worker -> Master) ───────────────────────────
swarm_remote_exec() {
    local cmd="$1"
    swarm_init

    if [ "$SWARM_ROLE" != "worker" ]; then
        ui_warn "Not currently configured as a worker node. Run: /swarm join <broker>"
        return 1
    fi

    local req_id="rexec-$RANDOM-$(date +%s)"
    local stream_topic="george/node/$SWARM_NODE_ID/stream"
    local inbox_topic="george/node/$SWARM_NODE_ID/inbox"

    local exec_params
    exec_params=$(jq -n -c \
        --arg from "$SWARM_NODE_ID" \
        --arg c "$cmd" \
        '{"from":$from, "command":$c}')

    local exec_msg
    exec_msg=$(swarm_rpc_req "$req_id" "repl/exec" "$exec_params")

    ui_dim "Routing '$cmd' to Master node via MQTT..."

    # Launch subscriber on stream and inbox topics synchronously until completion
    local completed=0
    _mqtt_build_args

    # Publish request to Master inbox
    mqtt_publish "george/master/inbox" "$exec_msg"

    # Listen to stream chunks and final completion frame
    local timeout=90
    local start_ts
    start_ts=$(date +%s)

    mosquitto_sub "${_MQTT_ARGS[@]}" -t "$stream_topic" -t "$inbox_topic" 2>/dev/null | while read -r line; do
        [ -z "$line" ] && continue
        local method msg_id
        method=$(echo "$line" | jq -r '.method // empty' 2>/dev/null)
        msg_id=$(echo "$line" | jq -r '.id // empty' 2>/dev/null)

        if [ "$msg_id" = "$req_id" ]; then
            if [ "$method" = "repl/chunk" ]; then
                local txt
                txt=$(echo "$line" | jq -r '.params.text // empty')
                printf "%b" "$txt"
            elif echo "$line" | jq -e '.result' >/dev/null 2>&1; then
                local code
                code=$(echo "$line" | jq -r '.result.exit_code // 0')
                if [ "$code" -eq 0 ]; then
                    ui_ok "Remote execution complete (exit 0)."
                else
                    ui_warn "Remote execution completed with exit $code."
                fi
                break
            fi
        fi

        local now
        now=$(date +%s)
        if [ $((now - start_ts)) -gt "$timeout" ]; then
            ui_err "Remote-master execution timed out (${timeout}s)."
            break
        fi
    done
}

# ── Master Task Delegation (Master -> Worker) ────────────────────────
swarm_delegate() {
    local target_node="$1"
    local cmd="$2"
    swarm_init

    if [ "$SWARM_ROLE" != "master" ]; then
        ui_err "Task delegation is only supported from the Master node."
        return 1
    fi

    # Check node in registry
    local node_exists
    node_exists=$(jq -r --arg n "$target_node" '.[] | select(.id == $n) | .id' "$SWARM_REGISTRY" 2>/dev/null)
    if [ -z "$node_exists" ]; then
        ui_err "Worker node '$target_node' not found in swarm registry. Run /swarm status"
        return 1
    fi

    local req_id="del-$RANDOM-$(date +%s)"
    local spawn_params
    spawn_params=$(jq -n -c \
        --arg c "$cmd" \
        '{"command":$c}')

    local spawn_msg
    spawn_msg=$(swarm_rpc_req "$req_id" "task/spawn" "$spawn_params")

    ui_dim "Delegating '$cmd' to $target_node..."
    mqtt_publish "george/node/$target_node/inbox" "$spawn_msg"

    # Listen on master stream topic for output
    _mqtt_build_args
    local timeout=120
    local start_ts
    start_ts=$(date +%s)

    mosquitto_sub "${_MQTT_ARGS[@]}" -t "george/master/stream" -t "george/master/inbox" 2>/dev/null | while read -r line; do
        [ -z "$line" ] && continue
        local method msg_id
        method=$(echo "$line" | jq -r '.method // empty' 2>/dev/null)
        msg_id=$(echo "$line" | jq -r '.id // empty' 2>/dev/null)

        if [ "$msg_id" = "$req_id" ]; then
            if [ "$method" = "repl/chunk" ]; then
                local txt
                txt=$(echo "$line" | jq -r '.params.text // empty')
                printf "%b" "$txt"
            elif echo "$line" | jq -e '.result' >/dev/null 2>&1; then
                local code
                code=$(echo "$line" | jq -r '.result.exit_code // 0')
                if [ "$code" -eq 0 ]; then
                    ui_ok "Delegated task complete on $target_node (exit 0)."
                else
                    ui_warn "Delegated task completed on $target_node with exit $code."
                fi
                break
            fi
        fi

        local now
        now=$(date +%s)
        if [ $((now - start_ts)) -gt "$timeout" ]; then
            ui_err "Delegated task timed out (${timeout}s)."
            break
        fi
    done
}

# ── Status & Cluster Management ──────────────────────────────────────
swarm_status() {
    swarm_init
    ui_header "Blue Lodge Multi-Node Swarm"
    printf "  Cluster:   %s\n" "$SWARM_CLUSTER_ID"
    printf "  Role:      %s\n" "$SWARM_ROLE"
    printf "  Node ID:   %s\n" "$SWARM_NODE_ID"
    printf "  Broker:    %s\n" "${MQTT_BROKER:-localhost:1883}"
    local pol="Auto (Slot 1)"
    [ "${SWARM_REQUIRE_APPROVAL:-0}" -eq 1 ] && pol="Manual Approval Gate"
    printf "  Policy:    %s\n\n" "$pol"

    ui_step "Registered Nodes:"
    if [ -f "$SWARM_REGISTRY" ] && [ -s "$SWARM_REGISTRY" ]; then
        jq -r '.[] | "  - [\(.role | ascii_upcase)] \(.id) @ \(.host) (Tier \(.tier // "1"), GPU: \(.gpu // "none")) — \(.status)"' "$SWARM_REGISTRY" 2>/dev/null || echo "  (none)"
    else
        echo "  (none)"
    fi

    if [ "${SWARM_REQUIRE_APPROVAL:-0}" -eq 1 ] && [ -f "$SWARM_QUEUE_FILE" ]; then
        local pending
        pending=$(jq -r '.[] | select(.status == "PENDING_APPROVAL") | "  - [REQ \(.id)] from \(.from): \(.command) (\(.timestamp))"' "$SWARM_QUEUE_FILE" 2>/dev/null)
        if [ -n "$pending" ]; then
            printf "\n"
            ui_step "Pending Approval Queue:"
            echo "$pending"
            ui_dim "  Approve with: /swarm approve <id>"
        fi
    fi
}

swarm_policy() {
    local mode="$1"
    swarm_init
    case "$mode" in
        auto|autonomous)
            SWARM_REQUIRE_APPROVAL=0
            swarm_save_config
            ui_ok "Swarm execution policy: Autonomous (Slot 1)"
            ;;
        manual|gate|approve)
            SWARM_REQUIRE_APPROVAL=1
            swarm_save_config
            ui_ok "Swarm execution policy: Manual Operator Approval Gate"
            ;;
        *)
            ui_info "Usage: /swarm policy [auto|manual]"
            ;;
    esac
}

swarm_approve() {
    local req_id="$1"
    swarm_init
    [ -z "$req_id" ] && { ui_err "Usage: /swarm approve <id>"; return 1; }

    local req_entry
    req_entry=$(jq -r --arg id "$req_id" '.[] | select(.id == $id and .status == "PENDING_APPROVAL")' "$SWARM_QUEUE_FILE" 2>/dev/null)
    if [ -z "$req_entry" ]; then
        ui_err "Pending request '$req_id' not found in queue."
        return 1
    fi

    local from_node cmd
    from_node=$(echo "$req_entry" | jq -r '.from')
    cmd=$(echo "$req_entry" | jq -r '.command')

    # Update queue status
    local tmp_q="${SWARM_QUEUE_FILE}.tmp.$$"
    jq --arg id "$req_id" 'map(if .id == $id then .status = "APPROVED" else . end)' \
        "$SWARM_QUEUE_FILE" > "$tmp_q" 2>/dev/null && mv "$tmp_q" "$SWARM_QUEUE_FILE"

    ui_ok "Approved request '$req_id' from $from_node: '$cmd'"
    _swarm_execute_remote_command "$req_id" "$from_node" "$cmd" &
}

swarm_reject() {
    local req_id="$1"
    swarm_init
    [ -z "$req_id" ] && { ui_err "Usage: /swarm reject <id>"; return 1; }

    local req_entry
    req_entry=$(jq -r --arg id "$req_id" '.[] | select(.id == $id and .status == "PENDING_APPROVAL")' "$SWARM_QUEUE_FILE" 2>/dev/null)
    [ -z "$req_entry" ] && { ui_err "Pending request '$req_id' not found."; return 1; }

    local from_node
    from_node=$(echo "$req_entry" | jq -r '.from')

    local tmp_q="${SWARM_QUEUE_FILE}.tmp.$$"
    jq --arg id "$req_id" 'map(if .id == $id then .status = "REJECTED" else . end)' \
        "$SWARM_QUEUE_FILE" > "$tmp_q" 2>/dev/null && mv "$tmp_q" "$SWARM_QUEUE_FILE"

    # Send rejection error to worker
    local err_payload
    err_payload=$(swarm_rpc_err "$req_id" 403 "Request rejected by Master operator.")
    mqtt_publish "george/node/$from_node/inbox" "$err_payload"

    ui_ok "Rejected request '$req_id'."
}

swarm_leave() {
    swarm_init
    if [ "$SWARM_ROLE" = "worker" ]; then
        local leave_msg
        leave_msg=$(swarm_rpc_req "leave-$RANDOM" "node/leave" "{\"node_id\":\"$SWARM_NODE_ID\"}")
        mqtt_publish "george/master/inbox" "$leave_msg" 2>/dev/null || true
    fi

    # Kill background listeners
    for pid_file in "$SWARM_DIR"/master_listener.pid "$SWARM_DIR"/worker_listener.pid; do
        if [ -f "$pid_file" ]; then
            local lpid
            lpid=$(cat "$pid_file" 2>/dev/null)
            [ -n "$lpid" ] && kill "$lpid" 2>/dev/null || true
            rm -f "$pid_file" 2>/dev/null
        fi
    done

    SWARM_ROLE="none"
    swarm_save_config
    ui_ok "Swarm node '$SWARM_NODE_ID' disconnected and listeners stopped."
}
