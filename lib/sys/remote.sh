#!/bin/bash
# ── George: Remote Inference & Worker Node Manager (SSH Tunnel + Dynamic Discovery) ──
[ -n "${_LIB_REMOTE_LOADED:-}" ] && return 0; _LIB_REMOTE_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
[ -f "$LODGE_DIR/lib/core/endpoints.sh" ] && source "$LODGE_DIR/lib/core/endpoints.sh"

REMOTE_SSH_TARGET="${REMOTE_SSH_TARGET:-}"
REMOTE_SSH_PORT="${REMOTE_SSH_PORT:-22}"
REMOTE_SSH_KEY="${REMOTE_SSH_KEY:-$GEORGE_DIR/ssh/id_ed25519}"
REMOTE_OLLAMA_PORT="${REMOTE_OLLAMA_PORT:-11434}"
REMOTE_LLAMACPP_PORT="${REMOTE_LLAMACPP_PORT:-8080}"
REMOTE_LOCAL_OLLAMA_PORT="${REMOTE_LOCAL_OLLAMA_PORT:-11435}"
REMOTE_LOCAL_LLAMACPP_PORT="${REMOTE_LOCAL_LLAMACPP_PORT:-18080}"
REMOTE_FORWARD_HOST="${REMOTE_FORWARD_HOST:-127.0.0.1}"
REMOTE_JUMP_HOST="${REMOTE_JUMP_HOST:-}"
REMOTE_LLAMACPP_BIN="${REMOTE_LLAMACPP_BIN:-}"
REMOTE_LLAMACPP_GPU_LAYERS="${REMOTE_LLAMACPP_GPU_LAYERS:-99}"
REMOTE_LLAMACPP_CTX_SIZE="${REMOTE_LLAMACPP_CTX_SIZE:-12288}"
REMOTE_OLLAMA_DATA="${REMOTE_OLLAMA_DATA:-/usr/share/ollama/.ollama}"
REMOTE_GPU_BACKEND="${REMOTE_GPU_BACKEND:-auto}"
REMOTE_KV_CACHE_TYPE="${REMOTE_KV_CACHE_TYPE:-q4_0}"
REMOTE_FLASH_ATTN="${REMOTE_FLASH_ATTN:-on}"
REMOTE_PERSISTENT="${REMOTE_PERSISTENT:-1}"
REMOTE_NODE_MODE="${REMOTE_NODE_MODE:-hybrid}"
REMOTE_NODE_TIER="${REMOTE_NODE_TIER:-2}"
REMOTE_NODE_NAME="${REMOTE_NODE_NAME:-}"
REMOTE_REVERSE_TUNNEL="${REMOTE_REVERSE_TUNNEL:-1}"
REMOTE_MQTT_PORT="${REMOTE_MQTT_PORT:-1883}"
REMOTE_GITEA_PORT="${REMOTE_GITEA_PORT:-3088}"

_REMOTE_PID_FILE="${GEORGE_DIR}/remote-tunnel.pid"
_REMOTE_WATCHDOG_PID_FILE="${GEORGE_DIR}/remote-watchdog.pid"
_REMOTE_STATE_FILE="${GEORGE_DIR}/remote-node-state.json"
_REMOTE_CONNECTED=0

# ── Load persisted remote config ───────────────────────────────
_remote_load_config() {
    local _cfg="${GEORGE_DIR}/remote.conf"
    [ -f "$_cfg" ] || return 0
    local _key _val
    while IFS='=' read -r _key _val; do
        [[ "$_key" =~ ^[[:space:]]*# ]] && continue
        [[ "$_key" =~ ^[[:space:]]*$ ]] && continue
        _key="${_key//[[:space:]]/}"
        _val="${_val#"${_val%%[![:space:]]*}"}"
        _val="${_val%"${_val##*[![:space:]]}"}"
        _val="${_val#\"}"
        _val="${_val%\"}"
        case "$_key" in
            REMOTE_SSH_TARGET|REMOTE_SSH_PORT|REMOTE_SSH_KEY|\
            REMOTE_OLLAMA_PORT|REMOTE_LLAMACPP_PORT|\
            REMOTE_LOCAL_OLLAMA_PORT|REMOTE_LOCAL_LLAMACPP_PORT|\
            REMOTE_FORWARD_HOST|REMOTE_JUMP_HOST|\
            REMOTE_LLAMACPP_BIN|REMOTE_LLAMACPP_GPU_LAYERS|\
            REMOTE_LLAMACPP_CTX_SIZE|REMOTE_OLLAMA_DATA|\
            REMOTE_GPU_BACKEND|REMOTE_KV_CACHE_TYPE|REMOTE_FLASH_ATTN|\
            REMOTE_PERSISTENT|REMOTE_NODE_MODE|REMOTE_NODE_TIER|\
            REMOTE_NODE_NAME|REMOTE_REVERSE_TUNNEL|\
            REMOTE_MQTT_PORT|REMOTE_GITEA_PORT)
                printf -v "$_key" '%s' "$_val" ;;
        esac
    done < "$_cfg"
    if [ -z "$REMOTE_SSH_KEY" ] || [ ! -d "$(dirname "$REMOTE_SSH_KEY")" ]; then
        REMOTE_SSH_KEY="$GEORGE_DIR/ssh/id_ed25519"
    fi
}

# ── Save remote config ────────────────────────────────────────
_remote_save_config() {
    mkdir -p "$GEORGE_DIR"
    cat > "${GEORGE_DIR}/remote.conf" << EOF
# George remote inference & worker node config
REMOTE_SSH_TARGET=${REMOTE_SSH_TARGET}
REMOTE_SSH_PORT=${REMOTE_SSH_PORT}
REMOTE_SSH_KEY=${REMOTE_SSH_KEY}
REMOTE_OLLAMA_PORT=${REMOTE_OLLAMA_PORT}
REMOTE_LLAMACPP_PORT=${REMOTE_LLAMACPP_PORT}
REMOTE_LOCAL_OLLAMA_PORT=${REMOTE_LOCAL_OLLAMA_PORT}
REMOTE_LOCAL_LLAMACPP_PORT=${REMOTE_LOCAL_LLAMACPP_PORT}
REMOTE_FORWARD_HOST=${REMOTE_FORWARD_HOST}
REMOTE_JUMP_HOST=${REMOTE_JUMP_HOST}
REMOTE_LLAMACPP_BIN=${REMOTE_LLAMACPP_BIN}
REMOTE_LLAMACPP_GPU_LAYERS=${REMOTE_LLAMACPP_GPU_LAYERS}
REMOTE_LLAMACPP_CTX_SIZE=${REMOTE_LLAMACPP_CTX_SIZE}
REMOTE_OLLAMA_DATA=${REMOTE_OLLAMA_DATA}
REMOTE_GPU_BACKEND=${REMOTE_GPU_BACKEND}
REMOTE_KV_CACHE_TYPE=${REMOTE_KV_CACHE_TYPE}
REMOTE_FLASH_ATTN=${REMOTE_FLASH_ATTN}
REMOTE_PERSISTENT=${REMOTE_PERSISTENT:-1}
REMOTE_NODE_MODE=${REMOTE_NODE_MODE:-hybrid}
REMOTE_NODE_TIER=${REMOTE_NODE_TIER:-2}
REMOTE_NODE_NAME=${REMOTE_NODE_NAME:-}
REMOTE_REVERSE_TUNNEL=${REMOTE_REVERSE_TUNNEL:-1}
REMOTE_MQTT_PORT=${REMOTE_MQTT_PORT:-1883}
REMOTE_GITEA_PORT=${REMOTE_GITEA_PORT:-3088}
EOF
    chmod 600 "${GEORGE_DIR}/remote.conf"
}

_remote_load_config

# ── Find tunnel PID ───────────────────────────────────────────
_remote_find_tunnel_pid() {
    local _target="$1" _pid
    for pat in "ssh.*-N.*${_target}" "autossh.*${_target}"; do
        _pid=$(pgrep -n -f "$pat" 2>/dev/null || ps aux 2>/dev/null | grep "$pat" | grep -v grep | awk '{print $2}' | tail -1)
        [ -n "$_pid" ] && { echo "$_pid"; return 0; }
    done
    return 1
}

# ── Check if SSH tunnel PID is alive ───────────────────────────
_remote_tunnel_alive() {
    [ -f "$_REMOTE_PID_FILE" ] || return 1
    local _pid
    _pid=$(cat "$_REMOTE_PID_FILE" 2>/dev/null)
    [ -n "$_pid" ] || return 1
    kill -0 "$_pid" 2>/dev/null && return 0
    [ -d "/proc/$_pid" ] 2>/dev/null && return 0
    ps -p "$_pid" >/dev/null 2>&1 && return 0
    return 1
}

# ── Ensure ssh-agent is running and key is loaded ─────────────
_remote_ensure_agent() {
    [ ! -f "$REMOTE_SSH_KEY" ] && return 0
    ssh-keygen -y -P "" -f "$REMOTE_SSH_KEY" &>/dev/null && return 0
    [ -z "${SSH_AUTH_SOCK:-}" ] && eval "$(ssh-agent -s)" >/dev/null 2>&1
    local fp
    fp=$(ssh-keygen -lf "$REMOTE_SSH_KEY" 2>/dev/null | awk '{print $2}')
    ssh-add -l 2>/dev/null | grep -q "$fp" 2>/dev/null && return 0
    echo "SSH key is passphrase-protected. Unlocking..." >&2
    ssh-add "$REMOTE_SSH_KEY"
}

# ── Detect and resolve local port conflicts ───────────────────
_remote_check_port_conflicts() {
    local _rem=0
    # Default local tunnel ports to non-colliding ports (18080 / 11435) if set to 8080 / 11434 and in use
    if [ "${REMOTE_LOCAL_LLAMACPP_PORT:-18080}" = "8080" ] && _remote_port_in_use 8080; then
        REMOTE_LOCAL_LLAMACPP_PORT=18080
        _rem=1
    fi
    if [ "${REMOTE_LOCAL_OLLAMA_PORT:-11435}" = "11434" ] && _remote_port_in_use 11434; then
        REMOTE_LOCAL_OLLAMA_PORT=11435
        _rem=1
    fi
    for var in REMOTE_LOCAL_OLLAMA_PORT REMOTE_LOCAL_LLAMACPP_PORT; do
        local _p="${!var}"
        if _remote_port_in_use "$_p"; then
            local _np=$(( _p + 10000 ))
            if ! _remote_port_in_use "$_np"; then
                printf -v "$var" '%s' "$_np"
                _rem=1
            fi
        fi
    done
    [ "$_rem" -eq 1 ] && _remote_save_config
}

_remote_port_in_use() {
    local _port="$1"
    (echo >/dev/tcp/127.0.0.1/"$_port") 2>/dev/null && return 0
    command -v ss >/dev/null 2>&1 && ss -tlnH "sport = :$_port" 2>/dev/null | grep -q "$_port" && return 0
    command -v netstat >/dev/null 2>&1 && netstat -tln 2>/dev/null | grep -q ":$_port " && return 0
    return 1
}

# ── Sweep orphaned tunnel processes ────────────────────────────
_remote_sweep_orphans() {
    local pids
    pids=$( { pgrep -f 'autossh|ssh.*-N' 2>/dev/null || true; ps aux 2>/dev/null | grep -E '[a]utossh|[s]sh.*-N' | awk '{print $2}'; } | sort -u | grep -v '^$' )
    if [ -n "$pids" ]; then
        for p in $pids; do kill "$p" 2>/dev/null || true; done
        sleep 0.3
        for p in $pids; do kill -9 "$p" 2>/dev/null || true; done
    fi
    return 0
}

# End-to-end tunnel target is always REMOTE_SSH_TARGET (using ProxyJump -J if REMOTE_JUMP_HOST is set).
_remote_tunnel_target() {
    echo "${REMOTE_SSH_TARGET:-$REMOTE_JUMP_HOST}"
}

_remote_host_of() {
    echo "${1##*@}"
}

_remote_ssh_base_args() {
    # When connecting end-to-end to REMOTE_SSH_TARGET (directly or via -J REMOTE_JUMP_HOST),
    # local forwards on the target machine hit 127.0.0.1 directly.
    local _fwd="127.0.0.1"
    if [ -z "${REMOTE_SSH_TARGET:-}" ] && [ -n "${REMOTE_FORWARD_HOST:-}" ]; then
        _fwd="$REMOTE_FORWARD_HOST"
    fi
    _REMOTE_SSH_ARGS=(
        -N
        -o BatchMode=yes
        -o ConnectTimeout=10
        -o ServerAliveInterval=30
        -o ServerAliveCountMax=3
        -o StrictHostKeyChecking=accept-new
        -p "${REMOTE_SSH_PORT:-22}"
    )
    [ -f "$REMOTE_SSH_KEY" ] && _REMOTE_SSH_ARGS+=(-i "$REMOTE_SSH_KEY")
    if [ -n "${REMOTE_JUMP_HOST:-}" ] && [ -n "${REMOTE_SSH_TARGET:-}" ] && [ "$REMOTE_JUMP_HOST" != "$REMOTE_SSH_TARGET" ]; then
        _REMOTE_SSH_ARGS+=(-J "$REMOTE_JUMP_HOST")
    fi
    _REMOTE_SSH_ARGS+=(-L "${REMOTE_LOCAL_OLLAMA_PORT}:${_fwd}:${REMOTE_OLLAMA_PORT}")
    _REMOTE_SSH_ARGS+=(-L "${REMOTE_LOCAL_LLAMACPP_PORT}:${_fwd}:${REMOTE_LLAMACPP_PORT}")
    _REMOTE_SSH_ARGS+=(-L "0.0.0.0:${REMOTE_LOCAL_WHISPER_PORT:-18090}:${_fwd}:${REMOTE_WHISPER_PORT:-8090}")

    # Reverse tunnels (-R) allow isolated worker nodes behind NAT/JumpBox to reach Master's
    # Mosquitto MQTT broker (:1883) and Gitea server (:3088) at 127.0.0.1 on the remote node.
    if [ "${REMOTE_REVERSE_TUNNEL:-1}" = "1" ]; then
        _REMOTE_SSH_ARGS+=(-R "${REMOTE_MQTT_PORT:-1883}:127.0.0.1:${MQTT_PORT:-1883}")
        _REMOTE_SSH_ARGS+=(-R "${REMOTE_GITEA_PORT:-3088}:127.0.0.1:${GITEA_PORT:-3088}")
    fi
}

_remote_watchdog() {
    for _fd in /proc/$BASHPID/fd/*; do
        _fd="${_fd##*/}"
        [[ "$_fd" =~ ^[0-9]+$ ]] && [ "$_fd" -gt 2 ] && eval "exec ${_fd}>&-" 2>/dev/null || true
    done
    local _tunnel_target
    _tunnel_target=$(_remote_tunnel_target)
    while true; do
        if ! _remote_tunnel_alive; then
            _remote_ssh_base_args
            ssh -f "${_REMOTE_SSH_ARGS[@]}" "$_tunnel_target" </dev/null >/dev/null 2>&1
            sleep 1
            local _pid
            _pid=$(_remote_find_tunnel_pid "$_tunnel_target")
            [ -n "$_pid" ] && echo "$_pid" > "$_REMOTE_PID_FILE"
        fi
        if [ -n "${REMOTE_JUMP_HOST:-}" ] && ! _remote_port_in_use 13000; then
            local _sdr_ip="${SDR_REMOTE_IP:-${SDR_REMOTE_HOST:-sdr-server}}"
            ssh -f -N -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new -i "$REMOTE_SSH_KEY" -L "0.0.0.0:13000:${_sdr_ip}:3000" "$REMOTE_JUMP_HOST" </dev/null >/dev/null 2>&1 || true
        fi
        sleep 15
    done
}

_remote_exec() {
    local target="${REMOTE_SSH_TARGET:-}"
    [ -z "$target" ] && return 1
    local args=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -p "${REMOTE_SSH_PORT:-22}")
    [ -f "$REMOTE_SSH_KEY" ] && args+=(-i "$REMOTE_SSH_KEY")
    if [ -n "${REMOTE_JUMP_HOST:-}" ] && [ "$REMOTE_JUMP_HOST" != "$target" ]; then
        args+=(-J "$REMOTE_JUMP_HOST")
    fi
    ssh "${args[@]}" "$target" "$1"
}

# ── Dynamic Hardware, Model & LoRA Discovery on Remote Node ─────────
# Connects via SSH and returns a complete JSON snapshot with zero static assumptions.
remote_discover_node() {
    local target="${1:-$REMOTE_SSH_TARGET}"
    local jump="${2:-$REMOTE_JUMP_HOST}"
    [ -z "$target" ] && { echo '{"status":"error","message":"No SSH target configured"}'; return 1; }

    local probe_script="$LODGE_DIR/lib/sys/remote_node_probe.py"
    [ -f "$probe_script" ] || { echo '{"status":"error","message":"remote_node_probe.py missing"}'; return 1; }

    local args=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -p "${REMOTE_SSH_PORT:-22}")
    [ -f "$REMOTE_SSH_KEY" ] && args+=(-i "$REMOTE_SSH_KEY")
    if [ -n "$jump" ] && [ "$jump" != "$target" ]; then
        args+=(-J "$jump")
    fi

    local raw_json
    raw_json=$(ssh "${args[@]}" "$target" "python3 -" < "$probe_script" 2>/dev/null)

    if [ -z "$raw_json" ] || ! echo "$raw_json" | jq -e '.status == "ok"' >/dev/null 2>&1; then
        echo '{"status":"error","message":"Failed to discover remote node via SSH"}'
        return 1
    fi

    mkdir -p "$GEORGE_DIR"
    echo "$raw_json" > "$_REMOTE_STATE_FILE"
    echo "$raw_json"
    return 0
}

# ── Dynamically Switch Model & Optional LoRA Adapter on Remote Node ─
# Usage: remote_switch_model <model_name_or_path> [lora_path_or_none] [ctx_size] [parallel_slots]
remote_switch_model() {
    local model_ref="${1:-}"
    local lora_ref="${2:-}"
    local req_ctx="${3:-${REMOTE_LLAMACPP_CTX_SIZE:-12288}}"
    local req_parallel="${4:-1}"

    [ -z "$model_ref" ] && { echo "ERROR: Usage: remote_switch_model <model> [lora_path|none] [ctx] [parallel]" >&2; return 1; }
    [ -z "$REMOTE_SSH_TARGET" ] && { echo "ERROR: REMOTE_SSH_TARGET not configured" >&2; return 1; }

    local disc
    disc=$(remote_discover_node) || return 1

    # Resolve model entry from discovered models
    local match
    match=$(echo "$disc" | jq -c --arg ref "$model_ref" '
        (.models[] | select(.path == $ref or .name == $ref or (.name | ascii_downcase | contains($ref | ascii_downcase))))
    ' 2>/dev/null | head -1)

    local model_path="" req_prism="false" model_name=""
    if [ -n "$match" ]; then
        model_path=$(echo "$match" | jq -r '.path')
        model_name=$(echo "$match" | jq -r '.name')
        req_prism=$(echo "$match" | jq -r '.requires_prism')
    else
        model_path="$model_ref"
        model_name=$(basename "$model_ref" .gguf)
        [[ "$model_path" == *prism* || "$model_path" == *Bonsai* || "$model_path" == *bonsai* ]] && req_prism="true"
    fi

    local lora_path=""
    if [ -n "$lora_ref" ] && [ "$lora_ref" != "none" ] && [ "$lora_ref" != "null" ]; then
        local lmatch
        lmatch=$(echo "$disc" | jq -c --arg ref "$lora_ref" '
            (.loras[] | select(.path == $ref or .name == $ref or (.name | ascii_downcase | contains($ref | ascii_downcase))))
        ' 2>/dev/null | head -1)
        if [ -n "$lmatch" ]; then
            lora_path=$(echo "$lmatch" | jq -r '.path')
        else
            lora_path="$lora_ref"
        fi
    fi

    local bin="\${HOME}/llama.cpp/build/bin/llama-server.real"
    local extra_flags="--temp 0.35 --top-p 0.90 --top-k 40 --min-p 0.05 --chat-template-file \${HOME}/.george/gemma4_agentic.jinja"
    if [[ "$model_path" == *E4B* || "$model_path" == *e4b* || "$model_name" == *E4B* || "$model_name" == *e4b* ]]; then
        extra_flags="$extra_flags --mmproj \${HOME}/llama.cpp/models/mmproj-gemma-4-E4B-it-F16.gguf"
        [ "$req_ctx" -eq 12288 ] 2>/dev/null && req_ctx=32768
    fi
    if [ "$req_prism" = "true" ]; then
        bin="\${HOME}/llama.cpp-prism/build/bin/llama-server"
        extra_flags="--reasoning-preserve"
        [ "$req_ctx" -gt 8192 ] 2>/dev/null && req_ctx=8192
    fi

    local _kv_type="${REMOTE_KV_CACHE_TYPE:-q4_0}"
    [ "$_kv_type" = "auto" ] || [ -z "$_kv_type" ] && _kv_type="q4_0"
    local _fa="${REMOTE_FLASH_ATTN:-on}"
    [ "$_fa" = "auto" ] || [ -z "$_fa" ] && _fa="on"

    _remote_exec "
mkdir -p ~/.george
cat > ~/.george/active_model.conf << 'EOF'
ACTIVE_MODEL_ID=\"${model_name}\"
ACTIVE_MODEL_BIN=\"${bin}\"
ACTIVE_MODEL_PATH=\"${model_path}\"
ACTIVE_LORA_PATH=\"${lora_path}\"
ACTIVE_CTX_SIZE=\"${req_ctx}\"
ACTIVE_PARALLEL=\"${req_parallel}\"
ACTIVE_BATCH=\"1024\"
ACTIVE_UBATCH=\"512\"
ACTIVE_KV_TYPE=\"${_kv_type}\"
ACTIVE_FLASH_ATTN=\"${_fa}\"
ACTIVE_EXTRA_FLAGS=\"${extra_flags}\"
EOF
mpid=\$(systemctl show -p MainPID --value llama-secondary 2>/dev/null || echo 0)
if [ -n \"\$mpid\" ] && [ \"\$mpid\" -gt 0 ] 2>/dev/null; then
    kill -9 \"\$mpid\" 2>/dev/null || true
else
    pkill -9 -f 'llama-server.*8080' 2>/dev/null || true
    nohup ~/llama.cpp/run_agent_server.sh >/tmp/llama-server.log 2>&1 &
fi
" || return 1

    # Wait 3s for old process to exit and systemd to start the new model before polling health
    sleep 3
    # Wait up to 45s for remote port 8080 health to return ok
    local ready=0
    local i
    for i in $(seq 1 45); do
        sleep 1
        if _remote_exec "curl -sf --max-time 2 http://127.0.0.1:${REMOTE_LLAMACPP_PORT:-8080}/health" 2>/dev/null | grep -q '"ok"'; then
            ready=1
            break
        fi
    done

    if [ "$ready" -ne 1 ]; then
        echo "ERROR: Remote llama-server did not become healthy after switching to $model_name" >&2
        return 1
    fi

    # Refresh discovery and sync tier in endpoints.conf
    local new_disc
    new_disc=$(remote_discover_node 2>/dev/null || true)
    if declare -f endpoints_update_tier &>/dev/null; then
        local label="$model_name"
        [ -n "$lora_path" ] && label="${model_name}+$(basename "$lora_path" .gguf)"
        local hw
        hw=$(echo "$new_disc" | jq -r '.hardware_summary // empty' 2>/dev/null)
        local hname
        hname=$(echo "$new_disc" | jq -r '.hostname // empty' 2>/dev/null)
        local node_slug="${REMOTE_NODE_NAME:-${hname:-remote-node}}"
        endpoints_update_tier "${REMOTE_NODE_TIER:-2}" \
            "NAME=${node_slug}" \
            "MODEL=${label}" \
            "CONTEXT=${req_ctx}" \
            ${hw:+"HARDWARE=${hw}"}
    fi

    declare -f ui_ok &>/dev/null && ui_ok "Switched remote model to ${model_name}${lora_path:+ (LoRA: $(basename "$lora_path"))} [ctx=${req_ctx}, slots=${req_parallel}]"
    return 0
}

# ── Connect: open bidirectional SSH tunnel & sync Tier ─────────
remote_connect() {
    _remote_load_config
    local target="${1:-$REMOTE_SSH_TARGET}"
    [ -z "$target" ] && { echo "ERROR: No SSH target. Use: remote_connect user@host" >&2; return 1; }
    REMOTE_SSH_TARGET="$target"

    remote_disconnect --keep-tier 2>/dev/null || true
    _remote_sweep_orphans
    # Reset local tunnel ports to standard defaults (18080 / 11435) if they are free after sweeping old tunnels
    if ! _remote_port_in_use 18080; then
        REMOTE_LOCAL_LLAMACPP_PORT=18080
    fi
    if ! _remote_port_in_use 11435; then
        REMOTE_LOCAL_OLLAMA_PORT=11435
    fi
    _remote_ensure_agent || { echo "ERROR: Cannot unlock SSH key." >&2; return 1; }
    _remote_check_port_conflicts

    # Clean up any stale reverse-forwarded sshd sockets on the remote node if reverse tunnel is enabled
    if [ "${REMOTE_REVERSE_TUNNEL:-1}" = "1" ]; then
        _remote_exec "pkill -f 'sshd:.*notty' 2>/dev/null || true" 2>/dev/null || true
        sleep 0.5
    fi

    _remote_ssh_base_args
    local _tunnel_target
    _tunnel_target=$(_remote_tunnel_target)
    local _method="ssh"
    local _err
    _err=$(mktemp "${TMPDIR:-/tmp}/remote-ssh-err.XXXXXX")
    if command -v systemd-run >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
        systemctl --user stop george-remote-tunnel.service 2>/dev/null || true
        systemctl --user reset-failed george-remote-tunnel.service 2>/dev/null || true
        systemd-run --user --unit=george-remote-tunnel \
            --property=Restart=always --property=RestartSec=5 \
            ssh "${_REMOTE_SSH_ARGS[@]}" "$_tunnel_target" 2>"$_err"
        _method="systemd-ssh"
    elif command -v autossh >/dev/null 2>&1; then
        AUTOSSH_GATETIME=0 autossh -M 0 -f "${_REMOTE_SSH_ARGS[@]}" "$_tunnel_target" 2>"$_err"
        _method="autossh"
    else
        ssh -f "${_REMOTE_SSH_ARGS[@]}" "$_tunnel_target" 2>"$_err"
    fi
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "ERROR: SSH tunnel failed (exit $rc): $(cat "$_err" 2>/dev/null)" >&2
        rm -f "$_err" 2>/dev/null
        return 1
    fi
    rm -f "$_err" 2>/dev/null

    sleep 1
    local pid
    pid=$(_remote_find_tunnel_pid "$_tunnel_target")
    [ -n "$pid" ] && { mkdir -p "$GEORGE_DIR"; echo "$pid" > "$_REMOTE_PID_FILE"; }
    if [ "$_method" = "ssh" ]; then
        _remote_watchdog "$_tunnel_target" </dev/null >/dev/null 2>&1 &
        local wpid=$!
        disown "$wpid" 2>/dev/null || true
        echo "$wpid" > "$_REMOTE_WATCHDOG_PID_FILE"
    fi

    _REMOTE_CONNECTED=1
    export REMOTE_OLLAMA_URL="http://127.0.0.1:${REMOTE_LOCAL_OLLAMA_PORT}"
    export REMOTE_LLAMA_CPP_URL="http://127.0.0.1:${REMOTE_LOCAL_LLAMACPP_PORT}"

    # Only override primary LLAMA_CPP_URL if local port 8080 is not running its own server
    if ! _remote_port_in_use 8080 || [ "${REMOTE_LOCAL_LLAMACPP_PORT}" = "8080" ]; then
        OLLAMA_URL="$REMOTE_OLLAMA_URL"
        LLAMA_CPP_URL="$REMOTE_LLAMA_CPP_URL"
        ACTIVE_ENDPOINT_URL="$REMOTE_LLAMA_CPP_URL"
    fi

    _remote_save_config

    # Dynamically discover the connected remote node and register it into endpoints.conf
    local disc
    disc=$(remote_discover_node 2>/dev/null || true)
    if [ -n "$disc" ] && echo "$disc" | jq -e '.status == "ok"' >/dev/null 2>&1; then
        local hname hw lmodel lctx
        hname=$(echo "$disc" | jq -r '.hostname // "remote-node"')
        hw=$(echo "$disc" | jq -r '.hardware_summary // ""')
        lmodel=$(echo "$disc" | jq -r '.active.model // ""')
        lctx=$(echo "$disc" | jq -r '.active.n_ctx // empty')
        local slug="${REMOTE_NODE_NAME:-$hname}"
        local tier="${REMOTE_NODE_TIER:-2}"
        local en=1
        [ "${REMOTE_NODE_MODE:-hybrid}" = "worker" ] && en=0
        if declare -f endpoints_update_tier &>/dev/null; then
            endpoints_update_tier "$tier" \
                "NAME=${slug}" \
                "URL=http://127.0.0.1:${REMOTE_LOCAL_LLAMACPP_PORT}" \
                ${lmodel:+"MODEL=${lmodel}"} \
                ${hw:+"HARDWARE=${hw}"} \
                ${lctx:+"CONTEXT=${lctx}"} \
                "ENABLED=${en}"
        fi
        # If enrolled in hybrid or worker mode, ensure FIFO channel is resumed and worker ONLINE status is restored
        if [ "${REMOTE_NODE_MODE:-hybrid}" != "inference" ] && declare -f ipc_flow_resume &>/dev/null; then
            local fchan="node_${slug}"
            ipc_flow_resume "$fchan" >/dev/null 2>&1 || true
            ipc_flow_unstick "$fchan" >/dev/null 2>&1 || true
            if [ -f "$GEORGE_DIR/swarm/nodes.json" ]; then
                local tmp_r="$GEORGE_DIR/swarm/nodes.json.tmp.$$"
                jq --arg id "$slug" 'map(if .id == $id then .status = "ONLINE" else . end)' \
                    "$GEORGE_DIR/swarm/nodes.json" > "$tmp_r" 2>/dev/null && mv -f "$tmp_r" "$GEORGE_DIR/swarm/nodes.json"
            fi
        fi
    fi

    declare -f ui_ok &>/dev/null && ui_ok "Connected to $target via $_method (llama:127.0.0.1:$REMOTE_LOCAL_LLAMACPP_PORT, Ollama:127.0.0.1:$REMOTE_LOCAL_OLLAMA_PORT, mode:${REMOTE_NODE_MODE:-hybrid})"
    return 0
}

# ── Disconnect: tear down SSH tunnel ───────────────────────────
remote_disconnect() {
    local keep_tier="${1:-}"
    systemctl --user stop george-remote-tunnel.service 2>/dev/null || true
    systemctl --user reset-failed george-remote-tunnel.service 2>/dev/null || true
    if [ -f "$_REMOTE_WATCHDOG_PID_FILE" ]; then
        local wpid
        wpid=$(cat "$_REMOTE_WATCHDOG_PID_FILE" 2>/dev/null)
        [ -n "$wpid" ] && kill "$wpid" 2>/dev/null && wait "$wpid" 2>/dev/null
        rm -f "$_REMOTE_WATCHDOG_PID_FILE"
    fi
    if [ -f "$_REMOTE_PID_FILE" ]; then
        local pid
        pid=$(cat "$_REMOTE_PID_FILE" 2>/dev/null)
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
        rm -f "$_REMOTE_PID_FILE"
    fi
    _remote_sweep_orphans
    _REMOTE_CONNECTED=0

    if [ "$keep_tier" != "--keep-tier" ] && declare -f endpoints_update_tier &>/dev/null; then
        endpoints_update_tier "${REMOTE_NODE_TIER:-2}" "ENABLED=0" 2>/dev/null || true
    fi
    echo "Disconnected remote tunnel."
    return 0
}

# ── Status: check tunnel health + probe endpoints ─────────────
remote_tunnel_status() {
    local status="disconnected" pid="none" target="${REMOTE_SSH_TARGET:-<not set>}"
    local o_st="unreachable" l_st="unreachable"
    if _remote_tunnel_alive; then
        pid=$(cat "$_REMOTE_PID_FILE" 2>/dev/null); status="connected"
        curl -sf --max-time 2 "http://127.0.0.1:${REMOTE_LOCAL_OLLAMA_PORT}/api/tags" &>/dev/null && o_st="running"
        local h
        h=$(curl -sf --max-time 2 "http://127.0.0.1:${REMOTE_LOCAL_LLAMACPP_PORT}/health" 2>/dev/null)
        [ $? -eq 0 ] && l_st=$(echo "$h" | jq -r '.status // "running"' 2>/dev/null)
    elif [ -f "$_REMOTE_PID_FILE" ]; then
        status="stale (tunnel died)"; rm -f "$_REMOTE_PID_FILE"
    fi
    local method="ssh"
    command -v autossh >/dev/null 2>&1 && method="autossh"
    [ -f "$_REMOTE_WATCHDOG_PID_FILE" ] && kill -0 "$(cat "$_REMOTE_WATCHDOG_PID_FILE" 2>/dev/null)" 2>/dev/null && method="ssh+watchdog"

    printf "  %-22s %s\n" "Status:" "$status"
    printf "  %-22s %s\n" "Target:" "$target"
    printf "  %-22s %s\n" "Jump host:" "${REMOTE_JUMP_HOST:-<direct>}"
    printf "  %-22s %s\n" "Node mode:" "${REMOTE_NODE_MODE:-hybrid} (Tier ${REMOTE_NODE_TIER:-2})"
    printf "  %-22s %s\n" "Tunnel PID:" "$pid"
    printf "  %-22s %s\n" "Method:" "$method"
    printf "  %-22s %s\n" "Ollama:" "$o_st (127.0.0.1:${REMOTE_LOCAL_OLLAMA_PORT} -> :${REMOTE_OLLAMA_PORT})"
    printf "  %-22s %s\n" "llama-server:" "$l_st (127.0.0.1:${REMOTE_LOCAL_LLAMACPP_PORT} -> :${REMOTE_LLAMACPP_PORT})"
    if [ "${REMOTE_REVERSE_TUNNEL:-1}" = "1" ]; then
        printf "  %-22s %s\n" "Reverse tunnels:" "MQTT :${REMOTE_MQTT_PORT:-1883}, Gitea :${REMOTE_GITEA_PORT:-3088}"
    fi
    [ "$status" = "connected" ] && return 0
    return 1
}

# ── Setup: interactive SSH key configuration ───────────────────
remote_setup_ssh() {
    local target="${1:-$REMOTE_SSH_TARGET}"
    [ -z "$target" ] && { echo "Usage: /remote setup user@host"; return 1; }
    command -v ssh-keygen >/dev/null 2>&1 || { echo "ERROR: ssh-keygen not found." >&2; return 1; }

    mkdir -p "$(dirname "$REMOTE_SSH_KEY")"
    if [ ! -f "$REMOTE_SSH_KEY" ]; then
        ssh-keygen -t ed25519 -f "$REMOTE_SSH_KEY" -N "" -C "george@$(hostname)" || return 1
    fi
    local s_args=(-o ConnectTimeout=10 -p "$REMOTE_SSH_PORT" -i "$REMOTE_SSH_KEY")
    [ -n "${REMOTE_JUMP_HOST:-}" ] && s_args+=(-J "$REMOTE_JUMP_HOST")

    if ssh -o BatchMode=yes "${s_args[@]}" "$target" "echo ok" &>/dev/null; then
        REMOTE_SSH_TARGET="$target"; _remote_save_config; return 0
    fi

    if command -v ssh-copy-id >/dev/null 2>&1; then
        local c_args=(-i "$REMOTE_SSH_KEY" -p "$REMOTE_SSH_PORT")
        [ -n "${REMOTE_JUMP_HOST:-}" ] && c_args+=(-o "ProxyJump=$REMOTE_JUMP_HOST")
        ssh-copy-id "${c_args[@]}" "$target" || return 1
    fi
    ssh -o BatchMode=yes "${s_args[@]}" "$target" "echo ok" &>/dev/null && { REMOTE_SSH_TARGET="$target"; _remote_save_config; return 0; }
    return 1
}

remote_secure_key() {
    [ ! -f "$REMOTE_SSH_KEY" ] && { echo "No SSH key found at $REMOTE_SSH_KEY" >&2; return 1; }
    ssh-keygen -p -f "$REMOTE_SSH_KEY"
    [ -z "${SSH_AUTH_SOCK:-}" ] && eval "$(ssh-agent -s)" >/dev/null 2>&1
    ssh-add "$REMOTE_SSH_KEY"
}

remote_probe_endpoints() {
    local ourl="http://127.0.0.1:${REMOTE_LOCAL_OLLAMA_PORT:-11435}"
    local lurl="http://127.0.0.1:${REMOTE_LOCAL_LLAMACPP_PORT:-18080}"
    curl -sf --max-time 3 "${ourl}/api/tags" &>/dev/null && ui_ok "Remote Ollama reachable at $ourl" || ui_warn "Remote Ollama unreachable at $ourl"
    curl -sf --max-time 3 "${lurl}/health" &>/dev/null && ui_ok "Remote llama-server reachable at $lurl" || ui_warn "Remote llama-server unreachable at $lurl"
}

remote_diagnose() {
    local target="${REMOTE_SSH_TARGET:-}" _tunnel_target
    _tunnel_target=$(_remote_tunnel_target)
    echo "=== Remote Node & Tunnel Diagnostics ==="
    echo "── Configuration ──"
    printf "  %-22s %s\n" "SSH target:" "${target:-<not set>}"
    printf "  %-22s %s\n" "Jump host:" "${REMOTE_JUMP_HOST:-<direct>}"
    printf "  %-22s %s\n" "Node mode:" "${REMOTE_NODE_MODE:-hybrid} (Tier ${REMOTE_NODE_TIER:-2})"
    printf "  %-22s %s\n" "SSH port:" "${REMOTE_SSH_PORT:-22}"
    printf "  %-22s %s\n" "SSH key:" "$REMOTE_SSH_KEY"
    printf "  %-22s %s\n" "Local Ollama port:" "${REMOTE_LOCAL_OLLAMA_PORT:-11435}"
    printf "  %-22s %s\n" "Local llama port:" "${REMOTE_LOCAL_LLAMACPP_PORT:-18080}"
    printf "  %-22s %s\n" "Remote Ollama port:" "${REMOTE_OLLAMA_PORT:-11434}"
    printf "  %-22s %s\n" "Remote llama port:" "${REMOTE_LLAMACPP_PORT:-8080}"
    echo ""
    echo "── SSH Key ──"
    if [ -f "$REMOTE_SSH_KEY" ]; then
        echo "  Key exists: $REMOTE_SSH_KEY"
        local fp
        fp=$(ssh-keygen -lf "$REMOTE_SSH_KEY" 2>/dev/null)
        [ -n "$fp" ] && echo "  Fingerprint: $fp"
    else
        echo "  ERROR: Key not found: $REMOTE_SSH_KEY"
        echo "  Run: /remote setup $target"; return 1
    fi
    echo ""
    echo "── SSH Authentication ──"
    if _remote_exec "echo __DIAGNOSE_OK__" 2>/dev/null | grep -q "__DIAGNOSE_OK__"; then
        echo "  End-to-end SSH auth: OK"
    else
        echo "  End-to-end SSH auth: FAILED"
        return 1
    fi
    echo ""
    echo "── Tunnel Process ──"
    _remote_tunnel_alive && echo "  Tunnel PID: $(cat "$_REMOTE_PID_FILE" 2>/dev/null) (alive)" || echo "  Tunnel: not running"
    echo "── Local Tunnel Ports ──"
    for p in "${REMOTE_LOCAL_OLLAMA_PORT:-11435}" "${REMOTE_LOCAL_LLAMACPP_PORT:-18080}"; do
        _remote_port_in_use "$p" && printf "  Port %-6s %s\n" "$p:" "listening" || printf "  Port %-6s %s\n" "$p:" "not listening"
    done
    echo ""
    echo "── Endpoint Probes ──"
    local o_resp
    o_resp=$(curl -sf --max-time 3 "http://127.0.0.1:${REMOTE_LOCAL_OLLAMA_PORT:-11435}/api/tags" 2>/dev/null)
    [ -n "$o_resp" ] && echo "  Ollama: OK ($(echo "$o_resp" | jq '.models | length' 2>/dev/null) models)" || echo "  Ollama: UNREACHABLE"
    local l_resp
    l_resp=$(curl -sf --max-time 3 "http://127.0.0.1:${REMOTE_LOCAL_LLAMACPP_PORT:-18080}/health" 2>/dev/null)
    [ -n "$l_resp" ] && echo "  llama-server: OK ($(echo "$l_resp" | jq -r '.status // "ok"' 2>/dev/null))" || echo "  llama-server: UNREACHABLE"
    echo "=== End Diagnostics ==="
    return 0
}

_remote_auto_reattach() {
    if _remote_tunnel_alive; then
        export REMOTE_OLLAMA_URL="http://127.0.0.1:${REMOTE_LOCAL_OLLAMA_PORT}"
        export REMOTE_LLAMA_CPP_URL="http://127.0.0.1:${REMOTE_LOCAL_LLAMACPP_PORT}"
        _REMOTE_CONNECTED=1
    fi
}
