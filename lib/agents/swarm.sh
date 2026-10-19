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

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/mqtt.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/fifo_ipc.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/mqtt_fifo_bridge.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/sys/remote.sh" 2>/dev/null || true

# ── Swarm Defaults ───────────────────────────────────────────────────
SWARM_ROLE="${SWARM_ROLE:-none}"          # master | worker | none
SWARM_NODE_ID="${SWARM_NODE_ID:-}"
SWARM_NODE_MODE="${SWARM_NODE_MODE:-hybrid}" # inference | worker | hybrid
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
SWARM_NODE_MODE="${SWARM_NODE_MODE:-hybrid}"
SWARM_CLUSTER_ID="$SWARM_CLUSTER_ID"
SWARM_REQUIRE_APPROVAL="$SWARM_REQUIRE_APPROVAL"
MQTT_BROKER="${MQTT_BROKER:-127.0.0.1:1883}"
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
    local broker="${1:-${MQTT_BROKER:-127.0.0.1:1883}}"
    swarm_init

    mqtt_setup "$broker" 2>/dev/null || true
    if ! mqtt_available; then
        ui_err "mosquitto-clients required for swarm. Install with: sudo apt install mosquitto-clients"
        return 1
    fi

    SWARM_ROLE="master"
    SWARM_NODE_ID="master"
    swarm_save_config

    # Record master in registry (preserve existing workers)
    local now_ts
    now_ts=$(date '+%Y-%m-%d %H:%M:%S')
    local tmp_reg="${SWARM_REGISTRY}.tmp.$$"
    jq --arg id "master" \
       --arg role "master" \
       --arg host "$(hostname)" \
       --arg tier "${ACTIVE_TIER:-1}" \
       --arg ts "$now_ts" \
       '(map(select(.id != $id))) + [{id:$id, role:$role, mode:"master", host:$host, tier:$tier, status:"ONLINE", updated_at:$ts}]' \
       "$SWARM_REGISTRY" > "$tmp_reg" 2>/dev/null && mv "$tmp_reg" "$SWARM_REGISTRY"

    # Start Master background listener
    swarm_start_master_listener 1

    # Also ensure FIFO-MQTT bridges are running for any already-registered worker nodes
    local wids
    wids=$(jq -r '.[] | select(.role == "worker") | .id' "$SWARM_REGISTRY" 2>/dev/null)
    local wid
    for wid in $wids; do
        [ -n "$wid" ] && mqtt_fifo_master_bridge_start "$wid" "$broker" 1
    done

    ui_ok "Master node active on broker $broker"
    ui_dim "  Cluster ID:   $SWARM_CLUSTER_ID"
    ui_dim "  To join a worker node:"
    ui_dim "    /swarm join $broker <node_name>"
    return 0
}

_swarm_master_listener_loop() {
    swarm_init
    while true; do
        _mqtt_build_args
        mosquitto_sub "${_MQTT_ARGS[@]}" -t "george/master/inbox" 2>/dev/null | while read -r line; do
            [ -z "$line" ] && continue
            _swarm_master_handle_message "$line"
        done
        sleep 2
    done
}

swarm_start_master_listener() {
    local force_restart="${1:-0}"
    local pid_file="$SWARM_DIR/master_listener.pid"
    if [ -f "$pid_file" ]; then
        local old_pid
        old_pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            if [ "$force_restart" != "1" ]; then
                return 0
            fi
            pkill -TERM -P "$old_pid" 2>/dev/null || true
            kill -TERM "$old_pid" 2>/dev/null || true
            rm -f "$pid_file" 2>/dev/null
        fi
    fi

    if command -v systemd-run >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
        systemctl --user stop george-master-listener.service 2>/dev/null || true
        systemctl --user reset-failed george-master-listener.service 2>/dev/null || true
        systemd-run --user --unit=george-master-listener \
            --property=Restart=always --property=RestartSec=3 \
            --setenv=LODGE_DIR="$LODGE_DIR" --setenv=GEORGE_DIR="$GEORGE_DIR" \
            bash -c "source ${LODGE_DIR}/lib/agents/swarm.sh && _swarm_master_listener_loop" >/dev/null 2>&1 || true
        local spid
        spid=$(systemctl --user show -p MainPID --value george-master-listener.service 2>/dev/null || echo "")
        [ -n "$spid" ] && [ "$spid" != "0" ] && echo "$spid" > "$pid_file"
        return 0
    fi

    # Launch resilient background subscriber for george/master/inbox
    (
        for _fd in /proc/$BASHPID/fd/*; do
            _fd="${_fd##*/}"
            [[ "$_fd" =~ ^[0-9]+$ ]] && [ "$_fd" -gt 2 ] && eval "exec ${_fd}>&-" 2>/dev/null || true
        done
        while true; do
            _mqtt_build_args
            mosquitto_sub "${_MQTT_ARGS[@]}" -t "george/master/inbox" 2>/dev/null | while read -r line; do
                [ -z "$line" ] && continue
                _swarm_master_handle_message "$line"
            done
            sleep 2
        done
    ) </dev/null >/dev/null 2>&1 &
    local listener_pid=$!
    disown "$listener_pid" 2>/dev/null || true
    echo "$listener_pid" > "$pid_file"
}

_swarm_master_handle_message() {
    local raw_json="$1"
    local method req_id
    method=$(echo "$raw_json" | jq -r '.method // empty' 2>/dev/null)
    req_id=$(echo "$raw_json" | jq -r '.id // empty' 2>/dev/null)

    case "$method" in
        node/join)
            local nid nhost ntier ngpu nmode nmodel
            nid=$(echo "$raw_json" | jq -r '.params.node_id // empty')
            nhost=$(echo "$raw_json" | jq -r '.params.host // "unknown"')
            ntier=$(echo "$raw_json" | jq -r '.params.tier // "2"')
            ngpu=$(echo "$raw_json" | jq -r '.params.gpu // "none"')
            nmode=$(echo "$raw_json" | jq -r '.params.mode // "hybrid"')
            nmodel=$(echo "$raw_json" | jq -r '.params.model // ""')
            [ -z "$nid" ] && return

            local fchan
            fchan=$(_mqtt_bridge_chan_id "$nid" "node")
            local ts
            ts=$(date '+%Y-%m-%d %H:%M:%S')
            local tmp_reg="${SWARM_REGISTRY}.tmp.$$"
            jq --arg id "$nid" --arg h "$nhost" --arg t "$ntier" --arg g "$ngpu" \
               --arg m "$nmode" --arg mod "$nmodel" --arg fc "$fchan" --arg ts "$ts" '
                (map(select(.id != $id))) + [{
                    id:$id, role:"worker", mode:$m, host:$h, tier:$t,
                    gpu:$g, model:$mod, fifo_channel:$fc, status:"ONLINE", updated_at:$ts
                }]
            ' "$SWARM_REGISTRY" > "$tmp_reg" 2>/dev/null && mv "$tmp_reg" "$SWARM_REGISTRY"

            # Open Master-side FIFO-MQTT bridge with 1-slot credit flow control
            if [ "$nmode" != "inference" ]; then
                mqtt_fifo_master_bridge_start "$nid" "${MQTT_BROKER:-127.0.0.1:1883}" 1
                ipc_flow_resume "$fchan" >/dev/null 2>&1 || true
                ipc_flow_unstick "$fchan" >/dev/null 2>&1 || true
            fi

            # Send ack back to worker inbox
            local ack_msg
            ack_msg=$(swarm_rpc_resp "$req_id" "{\"status\":\"JOINED\", \"cluster\":\"$SWARM_CLUSTER_ID\", \"master\":\"master\", \"fifo_channel\":\"$fchan\"}")
            mqtt_publish "george/node/$nid/inbox" "$ack_msg"

            swarm_notify_operator "Worker '$nid' ($nmode) joined from $nhost (Tier $ntier, GPU: $ngpu, FIFO: $fchan)"
            ;;

        node/leave)
            local nid
            nid=$(echo "$raw_json" | jq -r '.params.node_id // empty')
            if [ -n "$nid" ]; then
                local tmp_reg="${SWARM_REGISTRY}.tmp.$$"
                jq --arg id "$nid" 'map(if .id == $id then .status = "OFFLINE" else . end)' \
                    "$SWARM_REGISTRY" > "$tmp_reg" 2>/dev/null && mv "$tmp_reg" "$SWARM_REGISTRY"
                local fchan
                fchan=$(_mqtt_bridge_chan_id "$nid" "node")
                ipc_flow_pause "$fchan" >/dev/null 2>&1 || true
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

        sentinel/report)
            local snode sev_id sev_type sdiag
            snode=$(echo "$raw_json" | jq -r '.params.node_id // "worker"')
            sev_id=$(echo "$raw_json" | jq -r '.params.event_id // empty')
            sev_type=$(echo "$raw_json" | jq -r '.params.event_type // "anomaly"')
            sdiag=$(echo "$raw_json" | jq -r '.params.diagnosis // ""')
            mkdir -p "$SWARM_DIR" 2>/dev/null
            echo "$raw_json" >> "$SWARM_DIR/sentinel_reports.jsonl" 2>/dev/null
            swarm_notify_operator "[SENTINEL:${snode}] Triaged '${sev_type}' (${sev_id}): ${sdiag:0:180}"
            ;;

        sentinel/issue_triage)
            local snode sinum stitle
            snode=$(echo "$raw_json" | jq -r '.params.node_id // "worker"')
            sinum=$(echo "$raw_json" | jq -r '.params.issue_number // 0')
            stitle=$(echo "$raw_json" | jq -r '.params.title // ""')
            mkdir -p "$SWARM_DIR" 2>/dev/null
            echo "$raw_json" >> "$SWARM_DIR/sentinel_reports.jsonl" 2>/dev/null
            swarm_notify_operator "[STAGE-0 TRIAGE:${snode}] Completed pre-remediation brief for Gitea Issue #${sinum} (${stitle})"
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
    local broker="${1:-${MQTT_BROKER:-127.0.0.1:1883}}"
    local node_name="${2:-$(hostname -s 2>/dev/null || echo "worker-$RANDOM")}"
    local node_mode="${3:-${SWARM_NODE_MODE:-hybrid}}"
    swarm_init

    mqtt_setup "$broker" 2>/dev/null || true
    if ! mqtt_available; then
        ui_err "mosquitto-clients required for swarm. Install with: sudo apt install mosquitto-clients"
        return 1
    fi

    SWARM_ROLE="worker"
    SWARM_NODE_ID="$node_name"
    SWARM_NODE_MODE="$node_mode"
    swarm_save_config

    # Start Worker background listener and FIFO-MQTT worker bridge
    swarm_start_worker_listener "$node_name" "$broker" "$node_mode"

    # Dynamically detect GPU & loaded model
    local req_id="join-$RANDOM"
    local gpu_info="none"
    local active_model=""
    if [ -f "$LODGE_DIR/lib/sys/remote_node_probe.py" ]; then
        local probe_out
        probe_out=$(python3 "$LODGE_DIR/lib/sys/remote_node_probe.py" 2>/dev/null)
        if [ -n "$probe_out" ]; then
            gpu_info=$(echo "$probe_out" | jq -r '.hardware_summary // "none"' 2>/dev/null)
            active_model=$(echo "$probe_out" | jq -r '.llama_server.active_model_name // ""' 2>/dev/null)
        fi
    fi
    if [ "$gpu_info" = "none" ] || [ -z "$gpu_info" ]; then
        command -v nvidia-smi &>/dev/null && gpu_info=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
        [ -z "$gpu_info" ] && command -v rocm-smi &>/dev/null && gpu_info="AMD ROCm GPU"
    fi

    local join_params
    join_params=$(jq -n -c \
        --arg nid "$node_name" \
        --arg host "$(hostname)" \
        --arg tier "${ACTIVE_TIER:-2}" \
        --arg gpu "${gpu_info:-none}" \
        --arg mode "$node_mode" \
        --arg model "$active_model" \
        '{"node_id":$nid, "host":$host, "tier":$tier, "gpu":$gpu, "mode":$mode, "model":$model}')

    local join_msg
    join_msg=$(swarm_rpc_req "$req_id" "node/join" "$join_params")
    mqtt_publish "george/master/inbox" "$join_msg"

    ui_ok "Joined swarm on $broker as '$node_name' (mode=$node_mode)"
    ui_dim "  Master target: george/master/inbox"
    ui_dim "  Run command remotely on master:"
    ui_dim "    /remote-master <cmd>"
    return 0
}

swarm_start_worker_listener() {
    local node_name="$1"
    local broker="${2:-${MQTT_BROKER:-127.0.0.1:1883}}"
    local node_mode="${3:-${SWARM_NODE_MODE:-hybrid}}"

    # Start FIFO-MQTT worker bridge (opens worker_in & worker_out FIFOs + LWT status)
    if declare -f mqtt_fifo_worker_bridge_start &>/dev/null; then
        mqtt_fifo_worker_bridge_start "$node_name" "$broker" "$node_mode"
    fi

    local pid_file="$SWARM_DIR/worker_listener.pid"
    if [ -f "$pid_file" ]; then
        local old_pid
        old_pid=$(cat "$pid_file" 2>/dev/null)
        [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null && return 0
    fi

    (
        trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM INT EXIT

        # 1. Legacy RPC inbox subscriber (`george/node/$node_name/inbox`)
        (
            while true; do
                _mqtt_build_args
                mosquitto_sub "${_MQTT_ARGS[@]}" -t "george/node/$node_name/inbox" 2>/dev/null | while read -r line; do
                    [ -z "$line" ] && continue
                    _swarm_worker_handle_message "$line"
                done
                sleep 2
            done
        ) &

        # 2. FIFO-backed task consumer: reads from `worker_in` FIFO channel, executes task,
        #    and writes result to `worker_out` FIFO channel (which grants 1 credit back to Master).
        (
            while ipc_channel_is_open "worker_in"; do
                local frame=""
                if frame=$(ipc_recv "worker_in" 3 "" "" 1 2>/dev/null); then
                    [ -z "$frame" ] && continue
                    _swarm_worker_handle_fifo_frame "$frame"
                fi
            done
        ) &

        wait
    ) </dev/null >/dev/null 2>&1 &
    local listener_pid=$!
    disown "$listener_pid" 2>/dev/null || true
    echo "$listener_pid" > "$pid_file"
}

_swarm_worker_handle_fifo_frame() {
    local frame="$1"
    local fuuid cmd branch sync_repo
    fuuid=$(printf '%s' "$frame" | jq -r '.uuid // empty' 2>/dev/null)
    cmd=$(printf '%s' "$frame" | jq -r '.payload.command // .payload.text // empty' 2>/dev/null)
    branch=$(printf '%s' "$frame" | jq -r '.payload.branch // empty' 2>/dev/null)
    sync_repo=$(printf '%s' "$frame" | jq -r '.payload.sync_repo // "0"' 2>/dev/null)
    [ -z "$cmd" ] && return 0

    _mqtt_bridge_parse_broker "${MQTT_BROKER:-127.0.0.1:1883}"

    # Mark worker BUSY on MQTT status topic while executing in Slot 1
    local busy_msg
    busy_msg=$(jq -nc --arg id "$SWARM_NODE_ID" --arg u "$fuuid" --arg h "$(hostname)" \
        '{node_id:$id, status:"BUSY", active_task:$u, host:$h}')
    mosquitto_pub -h "$_MB_HOST" -p "$_MB_PORT" \
        -t "george/swarm/nodes/${SWARM_NODE_ID}/status" -r -q 1 \
        -m "$busy_msg" 2>/dev/null || true

    # Optional git sync before running task
    if [ "$sync_repo" = "1" ] && git -C "$LODGE_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
        git -C "$LODGE_DIR" fetch --all -q 2>/dev/null || true
    fi

    local work_dir="$LODGE_DIR"
    local wt_dir=""
    if [ -n "$branch" ] && git -C "$LODGE_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
        wt_dir="$LODGE_DIR/.george/workspaces/swarm_${fuuid}"
        mkdir -p "$(dirname "$wt_dir")" 2>/dev/null
        if git -C "$LODGE_DIR" worktree add -q -B "$branch" "$wt_dir" 2>/dev/null; then
            work_dir="$wt_dir"
        fi
    fi

    # Stream start chunk to Master
    local chunk_start
    chunk_start=$(swarm_rpc_chunk "$fuuid" "[Worker $SWARM_NODE_ID: Executing '$cmd'...]\n")
    mqtt_publish "george/master/stream" "$chunk_start" 2>/dev/null || true

    local start_ms end_ms elapsed_ms
    start_ms=$(date +%s%3N 2>/dev/null || date +%s)
    local out_tmp
    out_tmp=$(mktemp)
    local exit_code=0
    (
        export LODGE_NONINTERACTIVE=1
        export LLAMA_CPP_URL="${LLAMA_CPP_URL:-http://127.0.0.1:8080}"
        cd "$work_dir" && bash -c "$cmd"
    ) > "$out_tmp" 2>&1
    exit_code=$?
    end_ms=$(date +%s%3N 2>/dev/null || date +%s)
    elapsed_ms=$((end_ms - start_ms))

    # Stream output lines to Master stream topic
    while IFS= read -r line || [ -n "$line" ]; do
        local chunk
        chunk=$(swarm_rpc_chunk "$fuuid" "$line\n")
        mqtt_publish "george/master/stream" "$chunk" 2>/dev/null || true
    done < "$out_tmp"

    local out_text
    out_text=$(head -c 32768 "$out_tmp" 2>/dev/null)
    rm -f "$out_tmp" 2>/dev/null

    if [ -n "$wt_dir" ] && [ -d "$wt_dir" ]; then
        git -C "$LODGE_DIR" worktree remove --force "$wt_dir" 2>/dev/null || rm -rf "$wt_dir"
        git -C "$LODGE_DIR" worktree prune 2>/dev/null || true
    fi

    # Build result JSON and write to `worker_out` FIFO channel (pumped to george/swarm/results/<id>)
    local res_json
    res_json=$(jq -nc \
        --arg node "$SWARM_NODE_ID" \
        --arg uuid "$fuuid" \
        --arg cmd "$cmd" \
        --arg out "$out_text" \
        --argjson ec "$exit_code" \
        --argjson ms "$elapsed_ms" \
        '{node:$node, uuid:$uuid, command:$cmd, exit_code:$ec, elapsed_ms:$ms, status:"DONE", output:$out}')
    ipc_send "worker_out" "RESULT" "$res_json" "$fuuid" 10 >/dev/null 2>&1 || true

    # Restore worker status to ONLINE
    local online_msg
    online_msg=$(jq -nc --arg id "$SWARM_NODE_ID" --arg m "${SWARM_NODE_MODE:-hybrid}" --arg h "$(hostname)" \
        '{node_id:$id, status:"ONLINE", mode:$m, host:$h}')
    mosquitto_pub -h "$_MB_HOST" -p "$_MB_PORT" \
        -t "george/swarm/nodes/${SWARM_NODE_ID}/status" -r -q 1 \
        -m "$online_msg" 2>/dev/null || true
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

            # Route through local worker_in FIFO if open so credit flow control is respected
            if ipc_channel_is_open "worker_in"; then
                local task_body
                task_body=$(jq -nc --arg c "$cmd" --arg b "$task_branch" '{command:$c, branch:$b}')
                ipc_send "worker_in" "TASK" "$task_body" "$req_id" 10 >/dev/null 2>&1 && return
            fi
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

# ── Master Task Delegation via FIFO-Backed MQTT Bridge ───────────────
swarm_delegate() {
    local target_node="$1"
    local cmd="$2"
    local timeout="${3:-180}"
    swarm_init

    if [ "$SWARM_ROLE" != "master" ]; then
        # Auto-initialize master role if local broker is reachable
        swarm_host "${MQTT_BROKER:-127.0.0.1:1883}" >/dev/null 2>&1 || {
            ui_err "Task delegation is only supported from the Master node."
            return 1
        }
    fi

    # Check node in registry
    local node_entry
    node_entry=$(jq -c --arg n "$target_node" '.[] | select(.id == $n)' "$SWARM_REGISTRY" 2>/dev/null | head -1)
    if [ -z "$node_entry" ]; then
        ui_err "Worker node '$target_node' not found in swarm registry. Run /swarm status"
        return 1
    fi

    local node_mode
    node_mode=$(echo "$node_entry" | jq -r '.mode // "hybrid"')
    if [ "$node_mode" = "inference" ]; then
        ui_err "Node '$target_node' is configured in pure 'inference' mode (no repo/task worker)."
        return 1
    fi

    local task_json
    task_json=$(jq -nc --arg c "$cmd" '{command:$c}')

    ui_dim "Delegating '$cmd' to $target_node via FIFO-MQTT bridge (1-slot credit flow control)..."
    local res_frame
    if res_frame=$(mqtt_fifo_dispatch_task "$target_node" "$task_json" "$timeout"); then
        local out_txt exit_code elapsed_ms
        out_txt=$(printf '%s' "$res_frame" | jq -r '.payload.output // empty' 2>/dev/null)
        exit_code=$(printf '%s' "$res_frame" | jq -r '.payload.exit_code // 0' 2>/dev/null)
        elapsed_ms=$(printf '%s' "$res_frame" | jq -r '.payload.elapsed_ms // 0' 2>/dev/null)
        [ -n "$out_txt" ] && printf "%s\n" "$out_txt"
        if [ "${exit_code:-0}" -eq 0 ]; then
            ui_ok "Delegated task complete on $target_node (exit 0, ${elapsed_ms}ms)."
            return 0
        else
            ui_warn "Delegated task completed on $target_node with exit $exit_code (${elapsed_ms}ms)."
            return "$exit_code"
        fi
    else
        ui_err "Delegated task to $target_node timed out or failed."
        return 1
    fi
}

# ── Remote Node Enrollment (Master -> Remote SSH Node) ───────────────
# Enrolls a remote SSH node into the Blue Lodge architecture in one of three modes:
#   - inference : Pure OpenAI/Ollama inference endpoint (no repo clone or MQTT worker)
#   - worker    : Clones/syncs ~/blue-lodge and starts the FIFO-MQTT worker daemon
#   - hybrid    : Both Tier inference endpoint AND FIFO-MQTT worker daemon (Default)
# Usage: swarm_enroll_remote [ssh_target] [jump_host] [node_name] [mode] [tier]
swarm_enroll_remote() {
    local target="${1:-$REMOTE_SSH_TARGET}"
    local jump="${2:-$REMOTE_JUMP_HOST}"
    local node_name="${3:-}"
    local mode="${4:-${REMOTE_NODE_MODE:-hybrid}}"
    local tier="${5:-${REMOTE_NODE_TIER:-2}}"

    [ -z "$target" ] && { ui_err "Usage: /swarm enroll <user@host> [jump_host] [node_name] [inference|worker|hybrid]"; return 1; }
    case "$mode" in
        inference|worker|hybrid) ;;
        *) ui_err "Invalid mode '$mode'. Must be: inference, worker, or hybrid."; return 1 ;;
    esac

    REMOTE_SSH_TARGET="$target"
    [ -n "$jump" ] && [ "$jump" != "-" ] && REMOTE_JUMP_HOST="$jump"
    REMOTE_NODE_MODE="$mode"
    REMOTE_NODE_TIER="$tier"
    [ -n "$node_name" ] && REMOTE_NODE_NAME="$node_name"
    _remote_save_config

    # 1. Ensure Master swarm host is active on local Mosquitto broker
    swarm_init
    if [ "$SWARM_ROLE" != "master" ]; then
        swarm_host "${MQTT_BROKER:-127.0.0.1:1883}" >/dev/null 2>&1 || true
    else
        swarm_start_master_listener 1
    fi

    # 2. Establish bidirectional SSH tunnel (-L inference, -R 1883 MQTT, -R 3088 Gitea)
    ui_info "Establishing bidirectional SSH tunnel to $target${REMOTE_JUMP_HOST:+ (via $REMOTE_JUMP_HOST)}..."
    if ! remote_connect "$target"; then
        ui_err "Failed to establish SSH tunnel to $target"
        return 1
    fi

    # 3. Discover remote hardware & models
    local disc
    disc=$(remote_discover_node "$target" "$REMOTE_JUMP_HOST" 2>/dev/null)
    local rhost rgpu rmodel
    rhost=$(echo "$disc" | jq -r '.hostname // "remote-node"' 2>/dev/null)
    rgpu=$(echo "$disc" | jq -r '.hardware_summary // "none"' 2>/dev/null)
    rmodel=$(echo "$disc" | jq -r '.llama_server.active_model_name // ""' 2>/dev/null)
    [ -z "$node_name" ] && node_name="${REMOTE_NODE_NAME:-$rhost}"
    REMOTE_NODE_NAME="$node_name"
    _remote_save_config

    if [ "$mode" = "inference" ]; then
        # Record in swarm registry as inference-only node
        local ts
        ts=$(date '+%Y-%m-%d %H:%M:%S')
        local tmp_reg="${SWARM_REGISTRY}.tmp.$$"
        jq --arg id "$node_name" --arg h "$rhost" --arg t "$tier" --arg g "$rgpu" \
           --arg mod "$rmodel" --arg ts "$ts" '
            (map(select(.id != $id))) + [{
                id:$id, role:"worker", mode:"inference", host:$h, tier:$t,
                gpu:$g, model:$mod, fifo_channel:null, status:"ONLINE", updated_at:$ts
            }]
        ' "$SWARM_REGISTRY" > "$tmp_reg" 2>/dev/null && mv "$tmp_reg" "$SWARM_REGISTRY"
        ui_ok "Enrolled '$node_name' ($rhost) in pure INFERENCE mode (Tier $tier: $rmodel on $rgpu)"
        return 0
    fi

    # 4. Sync ~/blue-lodge repository to remote worker over SSH / reverse Gitea tunnel
    ui_info "Synchronizing ~/blue-lodge repository to $node_name ($target)..."
    local bundle_file
    bundle_file=$(mktemp "${TMPDIR:-/tmp}/blue-lodge-sync.XXXXXX.bundle")
    git -C "$LODGE_DIR" bundle create "$bundle_file" HEAD main 2>/dev/null || \
        git -C "$LODGE_DIR" bundle create "$bundle_file" HEAD 2>/dev/null

    local scp_args=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -P "${REMOTE_SSH_PORT:-22}")
    [ -f "$REMOTE_SSH_KEY" ] && scp_args+=(-i "$REMOTE_SSH_KEY")
    [ -n "${REMOTE_JUMP_HOST:-}" ] && [ "$REMOTE_JUMP_HOST" != "$target" ] && scp_args+=(-J "$REMOTE_JUMP_HOST")

    scp "${scp_args[@]}" "$bundle_file" "${target}:/tmp/blue-lodge-sync.bundle" >/dev/null 2>&1
    rm -f "$bundle_file" 2>/dev/null

    # Also sync the latest uncommitted worker runtime scripts (fifo_ipc.sh, mqtt_fifo_bridge.sh, swarm.sh, remote_node_probe.py)
    _remote_exec "
set -e
if [ ! -d ~/blue-lodge/.git ]; then
    rm -rf ~/blue-lodge
    git clone -q /tmp/blue-lodge-sync.bundle ~/blue-lodge 2>/dev/null || true
    cd ~/blue-lodge
    git checkout -B main 2>/dev/null || true
else
    cd ~/blue-lodge
    git fetch -q /tmp/blue-lodge-sync.bundle HEAD:refs/remotes/origin/master_sync 2>/dev/null || true
    git reset --hard refs/remotes/origin/master_sync 2>/dev/null || true
fi
git -C ~/blue-lodge remote set-url origin http://127.0.0.1:3088/george/blue-lodge.git 2>/dev/null || \
    git -C ~/blue-lodge remote add origin http://127.0.0.1:3088/george/blue-lodge.git 2>/dev/null || true
rm -f /tmp/blue-lodge-sync.bundle
    mkdir -p ~/blue-lodge/lib/ipc ~/blue-lodge/lib/agents ~/blue-lodge/lib/sys ~/blue-lodge/lib/comms ~/blue-lodge/commands
" >/dev/null 2>&1

    scp "${scp_args[@]}" \
        "$LODGE_DIR/lib/ipc/fifo_ipc.sh" \
        "$LODGE_DIR/lib/ipc/mqtt_fifo_bridge.sh" \
        "${target}:~/blue-lodge/lib/ipc/" >/dev/null 2>&1
    scp "${scp_args[@]}" \
        "$LODGE_DIR/lib/comms/mqtt.sh" \
        "${target}:~/blue-lodge/lib/comms/" >/dev/null 2>&1
    scp "${scp_args[@]}" \
        "$LODGE_DIR/lib/agents/swarm.sh" \
        "$LODGE_DIR/lib/agents/remote_sentinel.sh" \
        "${target}:~/blue-lodge/lib/agents/" >/dev/null 2>&1
    scp "${scp_args[@]}" \
        "$LODGE_DIR/lib/sys/remote_node_probe.py" \
        "$LODGE_DIR/lib/sys/remote.sh" \
        "${target}:~/blue-lodge/lib/sys/" >/dev/null 2>&1
    scp "${scp_args[@]}" \
        "$LODGE_DIR/commands/swarm.sh" \
        "${target}:~/blue-lodge/commands/" >/dev/null 2>&1

    # 5. Record worker in Master SWARM_REGISTRY and start Master-side FIFO-MQTT bridge
    local fchan
    fchan=$(_mqtt_bridge_chan_id "$node_name" "node")
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local tmp_reg="${SWARM_REGISTRY}.tmp.$$"
    jq --arg id "$node_name" --arg h "$rhost" --arg t "$tier" --arg g "$rgpu" \
       --arg m "$mode" --arg mod "$rmodel" --arg fc "$fchan" --arg ts "$ts" '
        (map(select(.id != $id))) + [{
            id:$id, role:"worker", mode:$m, host:$h, tier:$t,
            gpu:$g, model:$mod, fifo_channel:$fc, status:"ONLINE", updated_at:$ts
        }]
    ' "$SWARM_REGISTRY" > "$tmp_reg" 2>/dev/null && mv "$tmp_reg" "$SWARM_REGISTRY"

    mqtt_fifo_master_bridge_stop "$node_name" --keep-channels >/dev/null 2>&1 || true
    mqtt_fifo_master_bridge_start "$node_name" "${MQTT_BROKER:-127.0.0.1:1883}" 1

    # 6. Configure and start Worker daemon + Autonomous Sentinel on remote node (connecting to 127.0.0.1:1883 reverse tunnel)
    ui_info "Starting FIFO-MQTT worker daemon & Autonomous Sentinel on $node_name (mode=$mode)..."
    _remote_exec "
export PATH=\"\$HOME/.local/bin:\$PATH\"
export LD_LIBRARY_PATH=\"\$HOME/.local/lib/mosquitto\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\"
export LODGE_DIR=\"\$HOME/blue-lodge\"
export GEORGE_DIR=\"\$HOME/blue-lodge/.george\"
export MQTT_BROKER=\"127.0.0.1:1883\"
export REMOTE_SENTINEL_NODE_ID=\"${node_name}\"
cd ~/blue-lodge
source lib/agents/swarm.sh
source lib/agents/remote_sentinel.sh 2>/dev/null || true
remote_sentinel_stop >/dev/null 2>&1 || true
swarm_leave >/dev/null 2>&1 || true
killall -9 mosquitto_sub 2>/dev/null || true
sleep 0.5
swarm_join \"127.0.0.1:1883\" \"${node_name}\" \"${mode}\"
remote_sentinel_start >/dev/null 2>&1 || true
" || {
        ui_err "Failed to start worker listener on $node_name"
        return 1
    }

    sleep 1
    ipc_flow_resume "$fchan" >/dev/null 2>&1 || true
    ipc_flow_unstick "$fchan" >/dev/null 2>&1 || true
    ui_ok "Remote node '$node_name' enrolled in '${mode}' mode and linked via FIFO-MQTT mesh!"
    return 0
}

# ── Status & Cluster Management ──────────────────────────────────────
swarm_status() {
    swarm_init
    ui_header "Blue Lodge Multi-Node Swarm"
    printf "  Cluster:   %s\n" "$SWARM_CLUSTER_ID"
    printf "  Role:      %s\n" "$SWARM_ROLE"
    printf "  Node ID:   %s\n" "$SWARM_NODE_ID"
    printf "  Broker:    %s\n" "${MQTT_BROKER:-127.0.0.1:1883}"
    local pol="Auto (Slot 1)"
    [ "${SWARM_REQUIRE_APPROVAL:-0}" -eq 1 ] && pol="Manual Approval Gate"
    printf "  Policy:    %s\n\n" "$pol"

    ui_step "Registered Nodes:"
    if [ -f "$SWARM_REGISTRY" ] && [ -s "$SWARM_REGISTRY" ]; then
        jq -r '.[] | "  - [\(.role | ascii_upcase):\(.mode // "hybrid")] \(.id) @ \(.host) (Tier \(.tier // "1"), GPU: \(.gpu // "none")\(.model | if . and . != "" then ", Model: " + . else "" end)\(.fifo_channel | if . and . != "" then ", FIFO: " + . else "" end)) — \(.status)"' "$SWARM_REGISTRY" 2>/dev/null || echo "  (none)"
    else
        echo "  (none)"
    fi

    # Show FIFO channel flow control telemetry for worker channels
    local wchans
    wchans=$(jq -r '.[] | select(.fifo_channel != null and .fifo_channel != "") | .fifo_channel' "$SWARM_REGISTRY" 2>/dev/null)
    if [ -n "$wchans" ]; then
        printf "\n"
        ui_step "FIFO-MQTT Flow Control Channels:"
        local wc
        for wc in $wchans; do
            if ipc_channel_is_open "$wc"; then
                local st_json cred win bp qd
                st_json=$(ipc_status "$wc" 2>/dev/null)
                cred=$(echo "$st_json" | jq -r '.credits // 0')
                win=$(echo "$st_json" | jq -r '.window_size // 1')
                bp=$(echo "$st_json" | jq -r '.backpressure // false')
                qd=$(echo "$st_json" | jq -r '.queue_depth // 0')
                printf "  - %-20s credits=%s/%s  backpressure=%-5s  queued=%s\n" "$wc" "$cred" "$win" "$bp" "$qd"
            else
                printf "  - %-20s CLOSED\n" "$wc"
            fi
        done
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
        if declare -f mqtt_fifo_worker_bridge_stop &>/dev/null; then
            mqtt_fifo_worker_bridge_stop "$SWARM_NODE_ID" "${MQTT_BROKER:-127.0.0.1:1883}"
        fi
    fi

    # Kill background listeners
    for pid_file in "$SWARM_DIR"/master_listener.pid "$SWARM_DIR"/worker_listener.pid; do
        if [ -f "$pid_file" ]; then
            local lpid
            lpid=$(cat "$pid_file" 2>/dev/null)
            if [ -n "$lpid" ]; then
                pkill -TERM -P "$lpid" 2>/dev/null || true
                kill "$lpid" 2>/dev/null || true
            fi
            rm -f "$pid_file" 2>/dev/null
        fi
    done

    SWARM_ROLE="none"
    swarm_save_config
    ui_ok "Swarm node '$SWARM_NODE_ID' disconnected and listeners stopped."
}
