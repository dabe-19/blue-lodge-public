#!/bin/bash
# ── George: FIFO-Backed MQTT Mesh Bridge (`lib/ipc/mqtt_fifo_bridge.sh`) ────
# Bridges local POSIX FIFO IPC channels (`lib/ipc/fifo_ipc.sh`) across a
# distributed MQTT mesh (`mosquitto_pub` / `mosquitto_sub`) with:
#   - Credit-window flow control (`window_size=1` for single-slot remote GPUs)
#   - MQTT Last Will & Testament (LWT) automatic crash/disconnect recovery
#   - Transparent spillover payload serialization over MQTT
#   - Resilient auto-reconnecting subscriber loop
#
# Topic Hierarchy:
#   george/swarm/nodes/<node_id>/status  (Retained LWT & ONLINE/BUSY/OFFLINE state)
#   george/swarm/tasks/<node_id>         (Master -> Worker FIFO frame ingress)
#   george/swarm/results/<node_id>       (Worker -> Master FIFO frame egress + credit grant)
#   george/swarm/ctrl/<node_id>          (PAUSE / RESUME / ABORT / CREDIT flow signals)

[ -n "${_LIB_MQTT_FIFO_BRIDGE_LOADED:-}" ] && return 0; _LIB_MQTT_FIFO_BRIDGE_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/fifo_ipc.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/mqtt.sh" 2>/dev/null || true

# Ensure ~/.local/bin and ~/.local/lib/mosquitto are in PATH / LD_LIBRARY_PATH on remote worker nodes
if [ -d "$HOME/.local/bin" ] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$HOME/.local/bin:$PATH"
fi
if [ -d "$HOME/.local/lib/mosquitto" ] && [[ ":${LD_LIBRARY_PATH:-}:" != *":$HOME/.local/lib/mosquitto:"* ]]; then
    export LD_LIBRARY_PATH="$HOME/.local/lib/mosquitto${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

MQTT_BRIDGE_DIR="${MQTT_BRIDGE_DIR:-$GEORGE_DIR/swarm/bridges}"

# Helper: parse host and port from broker string (e.g. "127.0.0.1:1883")
_mqtt_bridge_parse_broker() {
    local broker="${1:-${MQTT_BROKER:-127.0.0.1:1883}}"
    if [[ "$broker" == *:* ]]; then
        _MB_HOST="${broker%%:*}"
        _MB_PORT="${broker##*:}"
    else
        _MB_HOST="$broker"
        _MB_PORT="${MQTT_PORT:-1883}"
    fi
    [ -z "$_MB_HOST" ] && _MB_HOST="127.0.0.1"
    [ -z "$_MB_PORT" ] && _MB_PORT="1883"
}

# Helper: sanitize node_id into a valid FIFO channel suffix
_mqtt_bridge_chan_id() {
    local node_id="$1"
    local prefix="${2:-node}"
    local clean
    clean=$(printf '%s' "$node_id" | tr -c 'A-Za-z0-9_-' '_')
    clean="${clean%_}"
    printf '%s_%s' "$prefix" "$clean"
}

# Hydrate a frame's spillover payload before sending across the network so the
# remote node receives the full inline JSON payload even if local disk spilled it.
_mqtt_bridge_hydrate_frame() {
    local frame="$1"
    if [[ "$frame" =~ \"__spillover_ref__\":[[:space:]]*\"([^\"]+)\" ]]; then
        local sp_file="${BASH_REMATCH[1]}"
        if [ -f "$sp_file" ]; then
            local hydrated
            hydrated=$(printf '%s' "$frame" | jq -c --slurpfile p "$sp_file" '.payload = $p[0]' 2>/dev/null)
            if [ -n "$hydrated" ]; then
                frame="$hydrated"
            fi
        fi
    fi
    printf '%s' "$frame"
}

# ── Master-Side Node Bridge ──────────────────────────────────────────
# Opens FIFO channels:
#   - `node_<id>`     (outbound tasks to worker, credit window = $window_size, default 1)
#   - `node_<id>_res` (inbound results from worker, credit window = 16)
# Launches background pump & subscriber that bridge the local FIFOs to MQTT topics.
# Usage: mqtt_fifo_master_bridge_start <node_id> [broker] [window_size]
mqtt_fifo_master_bridge_start() {
    local node_id="$1"
    local broker="${2:-${MQTT_BROKER:-127.0.0.1:1883}}"
    local window_size="${3:-1}"
    [ -z "$node_id" ] && return 1

    mkdir -p "$MQTT_BRIDGE_DIR" 2>/dev/null || true
    _mqtt_bridge_parse_broker "$broker"

    local out_chan res_chan
    out_chan=$(_mqtt_bridge_chan_id "$node_id" "node")
    res_chan=$(_mqtt_bridge_chan_id "$node_id" "node_res")

    # Open outbound task channel (window_size=1 for 1-slot remote GPU flow control)
    if ! ipc_channel_is_open "$out_chan"; then
        ipc_channel_open "$out_chan" "$window_size" 3600 "$IPC_PRIO_SYSTEM" "stream"
    fi
    # Open inbound results channel
    if ! ipc_channel_is_open "$res_chan"; then
        ipc_channel_open "$res_chan" 16 3600 "$IPC_PRIO_SYSTEM" "stream"
    fi

    # Check if master bridge daemon for this node is already alive
    local pid_file="$MQTT_BRIDGE_DIR/master_${node_id}.pid"
    local pump_pid_file="$MQTT_BRIDGE_DIR/master_${node_id}_pump.pid"
    local sub_pid_file="$MQTT_BRIDGE_DIR/master_${node_id}_sub.pid"
    if [ -f "$pid_file" ] && [ -f "$pump_pid_file" ] && [ -f "$sub_pid_file" ]; then
        local old_pid old_pump old_sub
        old_pid=$(cat "$pid_file" 2>/dev/null)
        old_pump=$(cat "$pump_pid_file" 2>/dev/null)
        old_sub=$(cat "$sub_pid_file" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null \
           && [ -n "$old_pump" ] && kill -0 "$old_pump" 2>/dev/null \
           && [ -n "$old_sub" ] && kill -0 "$old_sub" 2>/dev/null; then
            return 0
        fi
    fi

    # Clean up any partial bridge processes for this node
    mqtt_fifo_master_bridge_stop "$node_id" --keep-channels

    (
        for _fd in /proc/$BASHPID/fd/*; do
            _fd="${_fd##*/}"
            [[ "$_fd" =~ ^[0-9]+$ ]] && [ "$_fd" -gt 2 ] && eval "exec ${_fd}>&-" 2>/dev/null || true
        done
        trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM INT EXIT

        # 1. Outbound Pump: drains frames from `node_<id>` FIFO (without auto-granting credit!)
        #    and publishes them to `george/swarm/tasks/<node_id>`.
        #    Credit is ONLY granted back when the worker completes the task or sends CREDIT.
        (
            while ipc_channel_is_open "$out_chan"; do
                local frame=""
                if frame=$(ipc_recv "$out_chan" 2 "" "" 0 2>/dev/null); then
                    [ -z "$frame" ] && continue
                    frame=$(_mqtt_bridge_hydrate_frame "$frame")
                    mosquitto_pub -h "$_MB_HOST" -p "$_MB_PORT" \
                        -t "george/swarm/tasks/${node_id}" \
                        -q 1 -m "$frame" 2>/dev/null || true
                fi
            done
        ) &
        echo $! > "$pump_pid_file"

        # 2. Inbound Subscriber: listens to `george/swarm/results/<node_id>`,
        #    `george/swarm/ctrl/<node_id>`, and `george/swarm/nodes/<node_id>/status`.
        (
            while ipc_channel_is_open "$out_chan"; do
                mosquitto_sub -h "$_MB_HOST" -p "$_MB_PORT" \
                    -i "george-master-bridge-${node_id}" \
                    --keepalive 30 -v \
                    -t "george/swarm/results/${node_id}" \
                    -t "george/swarm/ctrl/${node_id}" \
                    -t "george/swarm/nodes/${node_id}/status" 2>/dev/null | \
                while IFS=' ' read -r topic payload; do
                    [ -z "$topic" ] || [ -z "$payload" ] && continue
                    case "$topic" in
                        "george/swarm/results/${node_id}")
                            # Write result frame to local `node_res_<id>` FIFO channel
                            local ftype fuuid fbody
                            ftype=$(printf '%s' "$payload" | jq -r '.type // "RESULT"' 2>/dev/null)
                            fuuid=$(printf '%s' "$payload" | jq -r '.uuid // .payload.uuid // empty' 2>/dev/null)
                            fbody=$(printf '%s' "$payload" | jq -c '.payload // .' 2>/dev/null)
                            if [ -n "$fuuid" ] && [ -n "$fbody" ]; then
                                ipc_send "$res_chan" "${ftype:-RESULT}" "$fbody" "$fuuid" 5 >/dev/null 2>&1 || true
                            fi
                            # Replenish 1 credit on the outbound task channel now that the worker finished!
                            ipc_flow_grant "$out_chan" 1 >/dev/null 2>&1 || true
                            ;;
                        "george/swarm/ctrl/${node_id}")
                            local ctrl_cmd
                            ctrl_cmd=$(printf '%s' "$payload" | jq -r '.cmd // .command // empty' 2>/dev/null)
                            [ -z "$ctrl_cmd" ] && ctrl_cmd="$payload"
                            case "$ctrl_cmd" in
                                PAUSE)   ipc_flow_pause "$out_chan" >/dev/null 2>&1 || true ;;
                                RESUME)  ipc_flow_resume "$out_chan" >/dev/null 2>&1 || true ;;
                                CREDIT)  ipc_flow_grant "$out_chan" 1 >/dev/null 2>&1 || true ;;
                                UNSTICK) ipc_flow_unstick "$out_chan" >/dev/null 2>&1 || true ;;
                                ABORT)   ipc_flow_send_ctrl "$out_chan" "ABORT" >/dev/null 2>&1 || true ;;
                            esac
                            ;;
                        "george/swarm/nodes/${node_id}/status")
                            local st
                            st=$(printf '%s' "$payload" | jq -r '.status // empty' 2>/dev/null)
                            case "$st" in
                                OFFLINE)
                                    # LWT or graceful disconnect: pause outbound FIFO channel & mark registry OFFLINE
                                    ipc_flow_pause "$out_chan" >/dev/null 2>&1 || true
                                    if [ -f "${SWARM_REGISTRY:-}" ]; then
                                        local tmp_r="${SWARM_REGISTRY}.tmp.$$"
                                        jq --arg id "$node_id" 'map(if .id == $id then .status = "OFFLINE" else . end)' \
                                            "$SWARM_REGISTRY" > "$tmp_r" 2>/dev/null && mv -f "$tmp_r" "$SWARM_REGISTRY"
                                    fi
                                    ;;
                                ONLINE)
                                    # Node online: resume outbound FIFO channel & ensure credit is available if idle
                                    ipc_flow_resume "$out_chan" >/dev/null 2>&1 || true
                                    ipc_flow_unstick "$out_chan" >/dev/null 2>&1 || true
                                    if [ -f "${SWARM_REGISTRY:-}" ]; then
                                        local tmp_r="${SWARM_REGISTRY}.tmp.$$"
                                        jq --arg id "$node_id" 'map(if .id == $id then .status = "ONLINE" else . end)' \
                                            "$SWARM_REGISTRY" > "$tmp_r" 2>/dev/null && mv -f "$tmp_r" "$SWARM_REGISTRY"
                                    fi
                                    ;;
                                BUSY)
                                    if [ -f "${SWARM_REGISTRY:-}" ]; then
                                        local tmp_r="${SWARM_REGISTRY}.tmp.$$"
                                        jq --arg id "$node_id" 'map(if .id == $id then .status = "BUSY" else . end)' \
                                            "$SWARM_REGISTRY" > "$tmp_r" 2>/dev/null && mv -f "$tmp_r" "$SWARM_REGISTRY"
                                    fi
                                    ;;
                            esac
                            ;;
                    esac
                done
                sleep 2
            done
        ) &
        echo $! > "$sub_pid_file"

        wait
    ) </dev/null >/dev/null 2>&1 &
    local bpid=$!
    disown "$bpid" 2>/dev/null || true
    echo "$bpid" > "$pid_file"
    ipc_log "INFO" "$out_chan" "Started Master MQTT-FIFO bridge for node '$node_id' (pid=$bpid, broker=$_MB_HOST:$_MB_PORT, window=$window_size)"
    return 0
}

mqtt_fifo_master_bridge_stop() {
    local node_id="$1"
    local keep_chans="${2:-}"
    [ -z "$node_id" ] && return 1
    local pf
    for pf in "$MQTT_BRIDGE_DIR/master_${node_id}.pid" \
              "$MQTT_BRIDGE_DIR/master_${node_id}_pump.pid" \
              "$MQTT_BRIDGE_DIR/master_${node_id}_sub.pid"; do
        if [ -f "$pf" ]; then
            local bpid
            bpid=$(cat "$pf" 2>/dev/null)
            if [ -n "$bpid" ]; then
                pkill -TERM -P "$bpid" 2>/dev/null || true
                kill -TERM "$bpid" 2>/dev/null || true
            fi
            rm -f "$pf" 2>/dev/null
        fi
    done
    if [ "$keep_chans" != "--keep-channels" ]; then
        local out_chan res_chan
        out_chan=$(_mqtt_bridge_chan_id "$node_id" "node")
        res_chan=$(_mqtt_bridge_chan_id "$node_id" "node_res")
        ipc_channel_close "$out_chan" 2>/dev/null || true
        ipc_channel_close "$res_chan" 2>/dev/null || true
    fi
}

# ── Worker-Side Node Bridge ──────────────────────────────────────────
# Opens local FIFO channels on the Worker:
#   - `worker_in`  (inbound tasks from Master via MQTT)
#   - `worker_out` (outbound results to Master via MQTT)
# Connects to the MQTT broker with Last Will & Testament (LWT) on
# `george/swarm/nodes/<node_id>/status` so any SSH tunnel drop or crash
# immediately signals OFFLINE to the Master.
# Usage: mqtt_fifo_worker_bridge_start <node_id> [broker] [mode]
mqtt_fifo_worker_bridge_start() {
    local node_id="$1"
    local broker="${2:-${MQTT_BROKER:-127.0.0.1:1883}}"
    local node_mode="${3:-hybrid}"
    [ -z "$node_id" ] && return 1

    mkdir -p "$MQTT_BRIDGE_DIR" 2>/dev/null || true
    _mqtt_bridge_parse_broker "$broker"

    if ! ipc_channel_is_open "worker_in"; then
        ipc_channel_open "worker_in" 1 3600 "$IPC_PRIO_SYSTEM" "stream"
    fi
    if ! ipc_channel_is_open "worker_out"; then
        ipc_channel_open "worker_out" 8 3600 "$IPC_PRIO_SYSTEM" "stream"
    fi

    local pid_file="$MQTT_BRIDGE_DIR/worker_${node_id}.pid"
    local pump_pid_file="$MQTT_BRIDGE_DIR/worker_${node_id}_pump.pid"
    local sub_pid_file="$MQTT_BRIDGE_DIR/worker_${node_id}_sub.pid"
    if [ -f "$pid_file" ] && [ -f "$pump_pid_file" ] && [ -f "$sub_pid_file" ]; then
        local old_pid old_pump old_sub
        old_pid=$(cat "$pid_file" 2>/dev/null)
        old_pump=$(cat "$pump_pid_file" 2>/dev/null)
        old_sub=$(cat "$sub_pid_file" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null \
           && [ -n "$old_pump" ] && kill -0 "$old_pump" 2>/dev/null \
           && [ -n "$old_sub" ] && kill -0 "$old_sub" 2>/dev/null; then
            return 0
        fi
    fi

    (
        trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM INT EXIT

        # 1. Outbound Result Pump: reads from `worker_out` FIFO and publishes to `george/swarm/results/<node_id>`
        (
            while ipc_channel_is_open "worker_out"; do
                local frame=""
                if frame=$(ipc_recv "worker_out" 2 "" "" 1 2>/dev/null); then
                    [ -z "$frame" ] && continue
                    frame=$(_mqtt_bridge_hydrate_frame "$frame")
                    mosquitto_pub -h "$_MB_HOST" -p "$_MB_PORT" \
                        -t "george/swarm/results/${node_id}" \
                        -q 1 -m "$frame" 2>/dev/null || true
                fi
            done
        ) &
        echo $! > "$pump_pid_file"

        # 2. Inbound Task Subscriber with LWT (Last Will & Testament)
        (
            while ipc_channel_is_open "worker_in"; do
                local now_ts
                now_ts=$(date +%s)
                local online_payload lwt_payload
                online_payload=$(jq -nc --arg id "$node_id" --arg m "$node_mode" --arg h "$(hostname)" --argjson ts "$now_ts" \
                    '{node_id:$id, status:"ONLINE", mode:$m, host:$h, timestamp:$ts}')
                lwt_payload=$(jq -nc --arg id "$node_id" --arg m "$node_mode" --arg h "$(hostname)" \
                    '{node_id:$id, status:"OFFLINE", reason:"lwt_disconnect", mode:$m, host:$h}')

                # Announce ONLINE (retained) right after mosquitto_sub connects so any previous LWT is overwritten
                (
                    sleep 0.5
                    mosquitto_pub -h "$_MB_HOST" -p "$_MB_PORT" \
                        -t "george/swarm/nodes/${node_id}/status" -r -q 1 \
                        -m "$online_payload" 2>/dev/null || true
                ) &

                # Subscribe with LWT so if SSH reverse tunnel drops, broker immediately publishes OFFLINE
                mosquitto_sub -h "$_MB_HOST" -p "$_MB_PORT" \
                    -i "george-worker-bridge-${node_id}" \
                    --keepalive 15 \
                    --will-topic "george/swarm/nodes/${node_id}/status" \
                    --will-payload "$lwt_payload" \
                    --will-qos 1 \
                    --will-retain \
                    -t "george/swarm/tasks/${node_id}" 2>/dev/null | \
                while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    local ftype fuuid fbody
                    ftype=$(printf '%s' "$line" | jq -r '.type // "TASK"' 2>/dev/null)
                    fuuid=$(printf '%s' "$line" | jq -r '.uuid // ""' 2>/dev/null)
                    fbody=$(printf '%s' "$line" | jq -c '.payload // .' 2>/dev/null)
                    ipc_send "worker_in" "${ftype:-TASK}" "${fbody:-$line}" "$fuuid" 10 >/dev/null 2>&1 || true
                done
                sleep 3
            done
        ) &
        echo $! > "$sub_pid_file"

        wait
    ) </dev/null >/dev/null 2>&1 &
    local bpid=$!
    disown "$bpid" 2>/dev/null || true
    echo "$bpid" > "$pid_file"
    ipc_log "INFO" "worker_in" "Started Worker MQTT-FIFO bridge for '$node_id' (pid=$bpid, broker=$_MB_HOST:$_MB_PORT)"
    return 0
}

mqtt_fifo_worker_bridge_stop() {
    local node_id="$1"
    local broker="${2:-${MQTT_BROKER:-127.0.0.1:1883}}"
    [ -z "$node_id" ] && return 1
    _mqtt_bridge_parse_broker "$broker"

    local offline_payload
    offline_payload=$(jq -nc --arg id "$node_id" --arg h "$(hostname)" \
        '{node_id:$id, status:"OFFLINE", reason:"graceful_stop", host:$h}')
    mosquitto_pub -h "$_MB_HOST" -p "$_MB_PORT" \
        -t "george/swarm/nodes/${node_id}/status" -r -q 1 \
        -m "$offline_payload" 2>/dev/null || true

    ipc_channel_close "worker_in" 2>/dev/null || true
    ipc_channel_close "worker_out" 2>/dev/null || true

    local pf
    for pf in "$MQTT_BRIDGE_DIR/worker_${node_id}.pid" \
              "$MQTT_BRIDGE_DIR/worker_${node_id}_pump.pid" \
              "$MQTT_BRIDGE_DIR/worker_${node_id}_sub.pid"; do
        if [ -f "$pf" ]; then
            local bpid
            bpid=$(cat "$pf" 2>/dev/null)
            if [ -n "$bpid" ]; then
                pkill -TERM -P "$bpid" 2>/dev/null || true
                kill -TERM "$bpid" 2>/dev/null || true
            fi
            rm -f "$pf" 2>/dev/null
        fi
    done
    killall -TERM mosquitto_sub 2>/dev/null || true
}

# ── High-Level Request/Response Task Dispatch via FIFO-MQTT Bridge ───
# Sends a task frame into `node_<id>` FIFO channel (blocking on the 1-slot credit window
# if the remote GPU/worker is busy) and awaits the correlated result frame on `node_res_<id>`.
# Usage: mqtt_fifo_dispatch_task <node_id> <task_json> [timeout_s]
mqtt_fifo_dispatch_task() {
    local node_id="$1"
    local task_json="$2"
    local timeout="${3:-180}"
    [ -z "$node_id" ] || [ -z "$task_json" ] && return 1

    local out_chan res_chan
    out_chan=$(_mqtt_bridge_chan_id "$node_id" "node")
    res_chan=$(_mqtt_bridge_chan_id "$node_id" "node_res")

    # Ensure bridge & its pump/subscriber processes are running
    mqtt_fifo_master_bridge_start "$node_id" "${MQTT_BROKER:-127.0.0.1:1883}" 1

    local req_uuid
    req_uuid=$(_ipc_uuid)

    # Enqueue / send into outbound FIFO channel (respects credit window = 1)
    ipc_send "$out_chan" "TASK" "$task_json" "$req_uuid" "$timeout"
    local send_rc=$?
    if [ "$send_rc" -ne 0 ] && [ "$send_rc" -ne "$IPC_QUEUED" ]; then
        return "$send_rc"
    fi

    # Wait for correlated result frame on inbound result FIFO channel
    local res_frame=""
    if res_frame=$(ipc_recv "$res_chan" "$timeout" "" "$req_uuid" 1 2>/dev/null); then
        printf '%s\n' "$res_frame"
        return 0
    fi
    return "$IPC_ERR_AWAIT_TIMEOUT"
}
