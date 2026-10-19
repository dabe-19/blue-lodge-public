#!/bin/bash
# ── George: MCP (Model Context Protocol) Client ───────────────
[ -n "${_LIB_MCP_LOADED:-}" ] && return 0; _LIB_MCP_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR:-.}/.george}"

MCP_ENABLED="${MCP_ENABLED:-0}"
MCP_CONFIG_DIR="${MCP_CONFIG_DIR:-$GEORGE_DIR/mcp}"
MCP_RUN_DIR="${MCP_RUN_DIR:-$GEORGE_DIR/mcp/run}"
MCP_TIMEOUT="${MCP_TIMEOUT:-30}"
MCP_CACHE_NS="mcp"
MCP_SERVERS_FILE="${MCP_CONFIG_DIR}/servers.conf"
MCP_SERVERS_JSON="${MCP_CONFIG_DIR}/servers.json"
MCP_CATALOG_FILE="${MCP_CONFIG_DIR}/catalog.conf"

MCP_STARTUP_WAIT_SECONDS="${MCP_STARTUP_WAIT_SECONDS:-0.5}"
MCP_HANDSHAKE_DRAIN_SECONDS="${MCP_HANDSHAKE_DRAIN_SECONDS:-0.3}"
MCP_RECV_POLL_SECONDS="${MCP_RECV_POLL_SECONDS:-0.1}"
_MCP_JQ_CMD=jq

mcp_init() {
    mkdir -p "$MCP_CONFIG_DIR" "$MCP_RUN_DIR"
    [ ! -f "$MCP_CATALOG_FILE" ] && _mcp_write_default_catalog
    [ -f "$MCP_SERVERS_FILE" ] || touch "$MCP_SERVERS_FILE"
}

mcp_enabled() { [ "${MCP_ENABLED:-0}" -eq 1 ]; }
_mcp_jq() { "$_MCP_JQ_CMD" "$@"; }

# ── Server Registry ───────────────────────────────────────────

_mcp_server_exists() {
    local name="$1"
    [ -f "$MCP_SERVERS_FILE" ] && grep -q "^${name}|" "$MCP_SERVERS_FILE" 2>/dev/null && return 0
    if [ -f "$MCP_SERVERS_JSON" ] && command -v jq &>/dev/null; then
        jq -e "((.mcpServers[\"$name\"] // .[\"$name\"]) != null)" "$MCP_SERVERS_JSON" >/dev/null 2>&1 && return 0
    fi
    return 1
}

_mcp_server_cmd() {
    local name="$1" raw_cmd=""
    if [ -f "$MCP_SERVERS_FILE" ] && grep -q "^${name}|" "$MCP_SERVERS_FILE" 2>/dev/null; then
        raw_cmd=$(grep "^${name}|" "$MCP_SERVERS_FILE" 2>/dev/null | head -1 | cut -d'|' -f2)
    elif [ -f "$MCP_SERVERS_JSON" ] && command -v jq &>/dev/null; then
        local entry
        entry=$(jq -r "(.mcpServers[\"$name\"] // .[\"$name\"]) // empty" "$MCP_SERVERS_JSON" 2>/dev/null)
        if [ -n "$entry" ] && [ "$entry" != "null" ]; then
            local cmd args env_vars
            cmd=$(jq -r "(.mcpServers[\"$name\"] // .[\"$name\"]).command // empty" "$MCP_SERVERS_JSON" 2>/dev/null)
            args=$(jq -r "[(.mcpServers[\"$name\"] // .[\"$name\"]).args[]?] | join(\" \")" "$MCP_SERVERS_JSON" 2>/dev/null)
            env_vars=$(jq -r "[(.mcpServers[\"$name\"] // .[\"$name\"]).env // {} | to_entries[] | \"\\(.key)=\\\"\\(.value)\\\"\"] | join(\" \")" "$MCP_SERVERS_JSON" 2>/dev/null)
            [ -n "$cmd" ] && raw_cmd="${env_vars:+$env_vars }$cmd${args:+ $args}"
        fi
    fi
    [ -z "$raw_cmd" ] && return 1

    # Normalization: map legacy unpartitioned lib/mcp_server_* to lib/tools/mcp_server_*
    raw_cmd="${raw_cmd//lib\/mcp_server_/lib\/tools\/mcp_server_}"

    # Container vs host path translation
    if [ ! -d "/workspace" ] && [[ "$raw_cmd" == *"/workspace"* ]]; then
        raw_cmd="${raw_cmd//\/workspace/${LODGE_DIR:-$HOME/blue-lodge}}"
    fi

    # Expand relative script paths with LODGE_DIR
    local lodge_root="${LODGE_DIR:-$HOME/blue-lodge}"
    if [[ "$raw_cmd" =~ ^(bash|python3|python)[[:space:]]+(lib/tools/[^[:space:]]+)(.*)$ ]]; then
        local interp="${BASH_REMATCH[1]}"
        local rel_script="${BASH_REMATCH[2]}"
        local rest_args="${BASH_REMATCH[3]}"
        raw_cmd="$interp $lodge_root/$rel_script$rest_args"
    elif [[ "$raw_cmd" =~ ^(bash|python3|python)[[:space:]]+(\$LODGE_DIR/)([^[:space:]]+)(.*)$ ]]; then
        local interp="${BASH_REMATCH[1]}"
        local rel_script="${BASH_REMATCH[3]}"
        local rest_args="${BASH_REMATCH[4]}"
        raw_cmd="$interp $lodge_root/$rel_script$rest_args"
    fi

    echo "$raw_cmd"
}

_mcp_server_desc() {
    local name="$1"
    if [ -f "$MCP_SERVERS_FILE" ] && grep -q "^${name}|" "$MCP_SERVERS_FILE" 2>/dev/null; then
        grep "^${name}|" "$MCP_SERVERS_FILE" 2>/dev/null | head -1 | cut -d'|' -f3; return 0
    fi
    if [ -f "$MCP_SERVERS_JSON" ] && command -v jq &>/dev/null; then
        local desc
        desc=$(jq -r "(.mcpServers[\"$name\"] // .[\"$name\"]).description // \"Standard MCP Server ($name)\"" "$MCP_SERVERS_JSON" 2>/dev/null)
        [ -n "$desc" ] && [ "$desc" != "null" ] && echo "$desc" && return 0
    fi
    return 1
}

mcp_server_add() {
    local name="$1" cmd="$2" desc="${3:-MCP server}"
    if ! printf '%s' "$name" | grep -qE '^[a-zA-Z0-9_-]+$'; then
        echo "ERROR: Server name must be alphanumeric (hyphens/underscores allowed)" >&2
        return 1
    fi
    mcp_init
    if _mcp_server_exists "$name"; then
        local tmp_file="${MCP_SERVERS_FILE}.tmp"
        grep -v "^${name}|" "$MCP_SERVERS_FILE" > "$tmp_file" 2>/dev/null
        mv "$tmp_file" "$MCP_SERVERS_FILE"
    fi
    echo "${name}|${cmd}|${desc}" >> "$MCP_SERVERS_FILE"
}

mcp_server_remove() {
    local name="$1"
    _mcp_server_exists "$name" || return 0
    mcp_status "$name" >/dev/null 2>&1 && mcp_stop "$name"
    if [ -f "$MCP_SERVERS_FILE" ]; then
        local tmp_file="${MCP_SERVERS_FILE}.tmp"
        grep -v "^${name}|" "$MCP_SERVERS_FILE" > "$tmp_file" 2>/dev/null
        mv "$tmp_file" "$MCP_SERVERS_FILE"
    fi
    if [ -f "$MCP_SERVERS_JSON" ] && command -v jq &>/dev/null; then
        local tmp_json="${MCP_SERVERS_JSON}.tmp"
        jq "del(.mcpServers[\"$name\"]) | del(.[\"$name\"])" "$MCP_SERVERS_JSON" > "$tmp_json" 2>/dev/null && mv "$tmp_json" "$MCP_SERVERS_JSON"
    fi
    declare -f cache_invalidate &>/dev/null && cache_invalidate "mcp:tools:${name}"
}

mcp_server_list() {
    [ -f "$MCP_SERVERS_FILE" ] && grep -v '^#' "$MCP_SERVERS_FILE" 2>/dev/null | grep -v '^$'
    if [ -f "$MCP_SERVERS_JSON" ] && command -v jq &>/dev/null; then
        local json_keys
        json_keys=$(jq -r '(.mcpServers // .) | keys[]?' "$MCP_SERVERS_JSON" 2>/dev/null || true)
        for k in $json_keys; do
            [ -f "$MCP_SERVERS_FILE" ] && grep -q "^${k}|" "$MCP_SERVERS_FILE" 2>/dev/null && continue
            local cmd desc
            cmd=$(_mcp_server_cmd "$k" 2>/dev/null || true)
            desc=$(_mcp_server_desc "$k" 2>/dev/null || true)
            [ -n "$cmd" ] && echo "${k}|${cmd}|${desc:-MCP Server}"
        done
    fi
}

mcp_server_names() {
    mcp_server_list | cut -d'|' -f1
}

# ── JSON-RPC 2.0 Helpers ──────────────────────────────────────

_mcp_next_id() {
    local name="$1"
    local id_file="$MCP_RUN_DIR/$name/req_id"
    local current next
    current=$(cat "$id_file" 2>/dev/null || echo 0)
    next=$((current + 1))
    echo "$next" > "$id_file"
    echo "$next"
}

_mcp_build_request() {
    local id="$1" method="$2" params="${3:-}"
    [ -z "$params" ] && params='{}'
    _mcp_jq -n -c --argjson id "$id" --arg method "$method" --argjson params "$params" \
        '{"jsonrpc":"2.0","id":$id,"method":$method,"params":$params}'
}

_mcp_build_notification() {
    local method="$1" params="${2:-}"
    [ -z "$params" ] && params='{}'
    _mcp_jq -n -c --arg method "$method" --argjson params "$params" \
        '{"jsonrpc":"2.0","method":$method,"params":$params}'
}

_mcp_send() {
    local name="$1" json="${2:-}"
    local fifo="$MCP_RUN_DIR/$name/in.fifo"
    [ -p "$fifo" ] || return 1
    if command -v timeout >/dev/null 2>&1; then
        timeout 5 sh -c 'printf "%s\n" "$1" > "$2"' -- "$json" "$fifo" 2>/dev/null
    else
        printf '%s\n' "$json" > "$fifo"
    fi
}

_mcp_recv() {
    local name="$1" req_id="${2:-}" timeout="${3:-$MCP_TIMEOUT}" start_offset="${4:-0}"
    local resp_file="$MCP_RUN_DIR/$name/responses.jsonl"
    local deadline=$(($(date +%s) + timeout)) last_size="$start_offset"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if [ -f "$resp_file" ]; then
            local current_size
            current_size=$(wc -c < "$resp_file" 2>/dev/null)
            current_size="${current_size## }"; current_size="${current_size:-0}"
            if [ "$current_size" -gt "$last_size" ]; then
                local new_data
                new_data=$(tail -c +"$((last_size + 1))" "$resp_file" 2>/dev/null)
                # Fast-path regex search to avoid line-by-line jq process forks
                if [ -n "$req_id" ]; then
                    local matched_line
                    matched_line=$(echo "$new_data" | grep -m 1 -E "\"id\":[[:space:]]*$req_id(\b|,|\})" 2>/dev/null || true)
                    if [ -n "$matched_line" ]; then
                        printf '%s' "$matched_line"
                        return 0
                    fi
                fi
                local _complete_bytes=0
                while IFS= read -r line; do
                    _complete_bytes=$((_complete_bytes + ${#line} + 1))
                    [ -z "$line" ] && continue
                    local rid
                    rid=$(printf '%s' "$line" | _mcp_jq -r '.id // empty' 2>/dev/null)
                    if [ "$rid" = "$req_id" ]; then
                        printf '%s' "$line"
                        return 0
                    fi
                done <<< "$new_data"
                last_size=$((last_size + _complete_bytes))
            fi
        fi
        sleep "$MCP_RECV_POLL_SECONDS"
    done
    return 1
}

# ── Handshake & Server Lifecycle ──────────────────────────────

_mcp_handshake() {
    local name="$1"
    local rundir="$MCP_RUN_DIR/$name"
    local req_id init_params init_req init_resp proto_ver notif
    local resp_file="$rundir/responses.jsonl"
    local start_offset=$(wc -c < "$resp_file" 2>/dev/null || echo 0)
    start_offset="${start_offset## }"; start_offset="${start_offset:-0}"
    req_id=$(_mcp_next_id "$name")
    init_params=$(_mcp_jq -n '{protocolVersion:"2024-11-05",capabilities:{},clientInfo:{name:"george",version:"1.0"}}')
    init_req=$(_mcp_build_request "$req_id" "initialize" "$init_params")
    _mcp_send "$name" "$init_req" || return 1
    init_resp=$(_mcp_recv "$name" "$req_id" 15 "$start_offset")
    [ -z "$init_resp" ] && return 1
    proto_ver=$(printf '%s' "$init_resp" | _mcp_jq -r '.result.protocolVersion // empty' 2>/dev/null)
    [ -z "$proto_ver" ] && return 1
    printf '%s' "$init_resp" | _mcp_jq -r '.result' > "$rundir/capabilities.json" 2>/dev/null
    notif=$(_mcp_build_notification "notifications/initialized")
    _mcp_send "$name" "$notif"
    sleep "$MCP_HANDSHAKE_DRAIN_SECONDS"
    return 0
}

mcp_start() {
    local name="$1" cmd
    cmd=$(_mcp_server_cmd "$name")
    [ -z "$cmd" ] && { echo "ERROR: Unknown MCP server: $name" >&2; return 1; }
    if mcp_status "$name" >/dev/null 2>&1; then
        if [ ! -p "$MCP_RUN_DIR/$name/in.fifo" ]; then
            mcp_stop "$name"
        else
            return 0
        fi
    fi
    local rundir="$MCP_RUN_DIR/$name"
    mkdir -p "$rundir"
    if [ -f "$rundir/pid" ]; then
        local _stale_pid=$(cat "$rundir/pid")
        if ! kill -0 "$_stale_pid" 2>/dev/null; then
            rm -f "$rundir"/{in.fifo,pid,keeper_pid,ready,req_id,responses.jsonl,stderr.log}
        else
            mcp_stop "$name"
        fi
    fi
    pkill -f "mcp-server-$name" 2>/dev/null
    rm -f "$rundir"/{in.fifo,responses.jsonl,stderr.log,pid,keeper_pid,ready,req_id,capabilities.json}
    touch "$rundir/responses.jsonl"
    echo "0" > "$rundir/req_id"
    mkfifo "$rundir/in.fifo" 2>/dev/null || { rm -f "$rundir/in.fifo"; mkfifo "$rundir/in.fifo" || return 1; }
    bash -lc "$cmd" < "$rundir/in.fifo" >> "$rundir/responses.jsonl" 2>"$rundir/stderr.log" &
    local server_pid=$!
    echo "$server_pid" > "$rundir/pid"
    sleep 86400 > "$rundir/in.fifo" </dev/null 2>/dev/null &
    echo "$!" > "$rundir/keeper_pid"
    sleep "$MCP_STARTUP_WAIT_SECONDS"
    if ! kill -0 "$server_pid" 2>/dev/null; then
        echo "ERROR: MCP server '$name' died on startup" >&2
        declare -f ui_err &>/dev/null && ui_err "MCP server '$name' died on startup (pid=$server_pid)" >&2
        declare -f transcript_log &>/dev/null && transcript_log "mcp" "server '$name' FAILED to start (died on launch)"
        mcp_stop "$name"
        return 1
    fi
    if ! _mcp_handshake "$name"; then
        echo "ERROR: MCP handshake failed for '$name'" >&2
        declare -f ui_err &>/dev/null && ui_err "MCP handshake FAILED for '$name'" >&2
        declare -f transcript_log &>/dev/null && transcript_log "mcp" "server '$name' handshake FAILED"
        mcp_stop "$name"
        return 1
    fi
    touch "$rundir/ready"
    [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && ui_dim "  [debug] MCP server '$name' started (pid=$server_pid)" >&2
    declare -f transcript_log &>/dev/null && transcript_log "mcp" "server '$name' started OK (pid=$server_pid, cmd=${cmd:0:80})"
    return 0
}

mcp_stop() {
    local name="$1"
    local rundir="$MCP_RUN_DIR/$name"
    [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && ui_dim "  [debug] MCP server '$name' stopping" >&2
    declare -f transcript_log &>/dev/null && transcript_log "mcp" "server '$name' stopping"
    if [ -f "$rundir/keeper_pid" ]; then
        local keeper_pid=$(cat "$rundir/keeper_pid")
        kill "$keeper_pid" 2>/dev/null; wait "$keeper_pid" 2>/dev/null
    fi
    if [ -f "$rundir/pid" ]; then
        local pid=$(cat "$rundir/pid")
        if kill -0 "$pid" 2>/dev/null; then
            pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; pkill -f "mcp-server-$name" 2>/dev/null
            sleep 0.2
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
        fi
    fi
    rm -f "$rundir"/{in.fifo,pid,keeper_pid,ready,req_id}
}

mcp_stop_all() {
    [ -d "$MCP_RUN_DIR" ] || return 0
    local dir name
    for dir in "$MCP_RUN_DIR"/*/; do
        [ -d "$dir" ] || continue
        mcp_stop "$(basename "$dir")"
    done
}

mcp_start_all() {
    mcp_init
    local names started=0 failed=0 name
    names=$(mcp_server_names)
    [ -z "$names" ] && return 1
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        mcp_status "$name" >/dev/null 2>&1 && continue
        if mcp_start "$name" 2>/dev/null; then
            started=$((started + 1))
        else
            failed=$((failed + 1))
            declare -f ui_warn &>/dev/null && ui_warn "MCP server '$name' failed to start" >&2
        fi
    done <<< "$names"
    [ "$started" -gt 0 ]
}

mcp_ensure_running() {
    [ "${MCP_ENABLED:-0}" -eq 1 ] || return 0
    mcp_has_servers || return 0
    mcp_start_all >/dev/null 2>&1 || true
}

mcp_has_servers() {
    [ -f "$MCP_SERVERS_FILE" ] || return 1
    grep -q -v '^#' "$MCP_SERVERS_FILE" 2>/dev/null && \
        grep -v '^#' "$MCP_SERVERS_FILE" 2>/dev/null | grep -q -v '^$'
}

mcp_status() {
    local rundir="$MCP_RUN_DIR/$1"
    [ -f "$rundir/pid" ] || return 1
    local pid=$(cat "$rundir/pid")
    kill -0 "$pid" 2>/dev/null || return 1
    [ -f "$rundir/ready" ] || return 2
    return 0
}

mcp_running_servers() {
    [ -d "$MCP_RUN_DIR" ] || return
    local dir name
    for dir in "$MCP_RUN_DIR"/*/; do
        [ -d "$dir" ] || continue
        name=$(basename "$dir")
        mcp_status "$name" >/dev/null 2>&1 && echo "$name"
    done
}

# ── Protocol: Tools ───────────────────────────────────────────

mcp_tools_list() {
    local name="$1"
    if declare -f cache_get &>/dev/null; then
        local cached=$(cache_get "mcp:tools:${name}" "$MCP_CACHE_NS")
        [ $? -eq 0 ] && [ -n "$cached" ] && { printf '%s' "$cached"; return 0; }
    fi
    mcp_status "$name" >/dev/null 2>&1 || mcp_start "$name" || return 1
    local req_id=$(_mcp_next_id "$name")
    local req=$(_mcp_build_request "$req_id" "tools/list" '{}')
    local resp_file="$MCP_RUN_DIR/$name/responses.jsonl"
    local start_offset=$(wc -c < "$resp_file" 2>/dev/null || echo 0)
    start_offset="${start_offset## }"; start_offset="${start_offset:-0}"
    _mcp_send "$name" "$req" || return 1
    local resp=$(_mcp_recv "$name" "$req_id" "$MCP_TIMEOUT" "$start_offset")
    [ -z "$resp" ] && return 1
    local _tl_err=$(printf '%s' "$resp" | _mcp_jq -r '.error.message // empty' 2>/dev/null)
    if [ -n "$_tl_err" ]; then
        echo "MCP ERROR (tools/list): $_tl_err" >&2
        declare -f ui_err &>/dev/null && ui_err "MCP tools/list ERROR: server=$name msg=$_tl_err" >&2
        declare -f transcript_log &>/dev/null && transcript_log "mcp" "tools/list ERROR: server=$name msg=$_tl_err"
        return 1
    fi
    local tools=$(printf '%s' "$resp" | _mcp_jq -r '.result.tools // []' 2>/dev/null)
    { [ -z "$tools" ] || [ "$tools" = "null" ]; } && tools="[]"
    declare -f cache_put &>/dev/null && cache_put "mcp:tools:${name}" "$MCP_CACHE_NS" "$tools"
    printf '%s' "$tools"
}

mcp_tool_call() {
    local server="$1" tool="$2" params="${3:-}"
    [ -z "$params" ] && params='{}'
    if [ "$server" = "george-mqtt" ]; then
        if [ "${LODGE_DEBUG:-0}" -eq 1 ]; then
            local _mqtt_log="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-$HOME/blue-lodge}/.george}/mqtt.log"
            mkdir -p "$(dirname "$_mqtt_log")" 2>/dev/null || true
            printf '[%s] [debug] MCP tool_call: server=%s tool=%s params=%s\n' "$(date +%T)" "$server" "$tool" "${params:0:120}" >> "$_mqtt_log" 2>/dev/null || true
        fi
    else
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && ui_dim "  [debug] MCP tool_call: server=$server tool=$tool params=${params:0:120}" >&2
    fi
    mcp_status "$server" >/dev/null 2>&1 || mcp_start "$server" || {
        declare -f ui_err &>/dev/null && ui_err "MCP tool_call FAILED: cannot start server '$server'" >&2
        declare -f transcript_log &>/dev/null && transcript_log "mcp" "tool_call FAILED: server '$server' won't start (tool=$tool)"
        return 1
    }
    local req_id=$(_mcp_next_id "$server")
    local call_params=$(_mcp_jq -n -c --arg name "$tool" --argjson arguments "$params" '{"name":$name,"arguments":$arguments}')
    local req=$(_mcp_build_request "$req_id" "tools/call" "$call_params")
    local resp_file="$MCP_RUN_DIR/$server/responses.jsonl"
    local start_offset=$(wc -c < "$resp_file" 2>/dev/null || echo 0)
    start_offset="${start_offset## }"; start_offset="${start_offset:-0}"
    _mcp_send "$server" "$req" || return 1
    local resp=$(_mcp_recv "$server" "$req_id" "$MCP_TIMEOUT" "$start_offset")
    if [ -z "$resp" ]; then
        declare -f ui_err &>/dev/null && ui_err "MCP tool_call TIMEOUT: server=$server tool=$tool (${MCP_TIMEOUT}s)" >&2
        declare -f transcript_log &>/dev/null && transcript_log "mcp" "tool_call TIMEOUT: server=$server tool=$tool (${MCP_TIMEOUT}s)"
        return 1
    fi
    local err=$(printf '%s' "$resp" | _mcp_jq -r '.error.message // empty' 2>/dev/null)
    if [ -n "$err" ]; then
        local err_code=$(printf '%s' "$resp" | _mcp_jq -r '.error.code // "unknown"' 2>/dev/null)
        echo "MCP ERROR: $err" >&2
        declare -f ui_err &>/dev/null && ui_err "MCP tool_call ERROR: server=$server tool=$tool code=$err_code msg=$err" >&2
        declare -f transcript_log &>/dev/null && transcript_log "mcp" "tool_call ERROR: server=$server tool=$tool code=$err_code msg=$err"
        return 1
    fi
    local content=$(printf '%s' "$resp" | _mcp_jq -r '.result.content[]? | select(.type == "text") | .text' 2>/dev/null)
    if [ "$server" = "george-mqtt" ]; then
        if [ "${LODGE_DEBUG:-0}" -eq 1 ]; then
            local _mqtt_log="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-$HOME/blue-lodge}/.george}/mqtt.log"
            mkdir -p "$(dirname "$_mqtt_log")" 2>/dev/null || true
            printf '[%s] [debug] MCP tool_call OK: server=%s tool=%s response_len=%s\n' "$(date +%T)" "$server" "$tool" "${#content}" >> "$_mqtt_log" 2>/dev/null || true
        fi
    else
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && ui_dim "  [debug] MCP tool_call OK: server=$server tool=$tool response_len=${#content}" >&2
        declare -f transcript_log &>/dev/null && transcript_log "mcp" "tool_call OK: server=$server tool=$tool response_len=${#content}"
    fi
    printf '%s' "$content"
}

# ── Web & Tool Wrappers ───────────────────────────────────────

_mcp_try_fetch_tool() {
    local tool="$1" args_json="$2" fallback_tool="${3:-}" fallback_args="${4:-}"
    local servers=("george-fetch" "fetch") server result
    for server in "${servers[@]}"; do
        _mcp_server_exists "$server" || continue
        result=$(mcp_tool_call "$server" "$tool" "$args_json" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$result" ]; then
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && ui_dim "  [debug] MCP $tool OK via $server (${#result} bytes)" >&2
            declare -f transcript_log &>/dev/null && transcript_log "mcp" "$tool OK: $server (${#result} bytes)"
            printf '%s' "$result"
            return 0
        fi
    done
    if [ -n "$fallback_tool" ]; then
        [ -z "$fallback_args" ] && fallback_args="$args_json"
        for server in "${servers[@]}"; do
            _mcp_server_exists "$server" || continue
            result=$(mcp_tool_call "$server" "$fallback_tool" "$fallback_args" 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$result" ]; then
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && ui_dim "  [debug] MCP $fallback_tool (fallback) OK via $server (${#result} bytes)" >&2
                declare -f transcript_log &>/dev/null && transcript_log "mcp" "$fallback_tool (fallback from $tool) OK: $server (${#result} bytes)"
                printf '%s' "$result"
                return 0
            fi
        done
    fi
    if [ "$tool" = "fetch" ] || [ "$tool" = "fetch_json" ]; then
        if _mcp_server_exists "puppeteer"; then
            result=$(mcp_tool_call "puppeteer" "puppeteer_navigate" "$args_json" 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$result" ]; then
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && ui_dim "  [debug] MCP puppeteer fallback OK (${#result} bytes)" >&2
                declare -f transcript_log &>/dev/null && transcript_log "mcp" "puppeteer fallback OK (${#result} bytes)"
                printf '%s' "$result"
                return 0
            fi
        fi
    fi
    return 1
}

mcp_web_fetch() {
    local url="$1" _url_json json_result _sf_content _sf_title _sf_text _sf_blocked result
    _url_json=$(_mcp_jq -n -c --arg url "$url" '{"url":$url}')
    json_result=$(_mcp_try_fetch_tool "fetch_json" "$_url_json" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$json_result" ]; then
        _sf_title=$(echo "$json_result" | _mcp_jq -r '.title // ""' 2>/dev/null)
        _sf_content=$(echo "$json_result" | _mcp_jq -r '.content // ""' 2>/dev/null)
        _sf_blocked=$(echo "$json_result" | _mcp_jq -r '.blocked // false' 2>/dev/null)
        if [ "$_sf_blocked" != "true" ] && [ -n "$_sf_content" ] && [ ${#_sf_content} -gt 80 ]; then
            [ -n "$_sf_title" ] && _sf_text="${_sf_title}"$'\n\n'"${_sf_content}" || _sf_text="$_sf_content"
            printf '%s' "$_sf_text"
            return 0
        fi
    fi
    result=$(_mcp_try_fetch_tool "fetch" "$_url_json" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$result" ]; then
        printf '%s' "$result"
        return 0
    fi
    declare -f transcript_log &>/dev/null && transcript_log "mcp" "web_fetch FALLBACK: no MCP server succeeded for url=${url:0:80}"
    return 1
}

mcp_web_fetch_json() { _mcp_try_fetch_tool "fetch_json" "$(_mcp_jq -n -c --arg url "$1" '{"url":$url}')"; }
mcp_web_search() { _mcp_try_fetch_tool "web_search" "$(_mcp_jq -n -c --arg q "$1" --argjson c "${2:-5}" '{"query":$q,"count":$c}')"; }
mcp_web_images() { _mcp_try_fetch_tool "web_images" "$(_mcp_jq -n -c --arg q "$1" --argjson c "${2:-5}" '{"query":$q,"count":$c}')"; }
mcp_web_fetch_pdf() { _mcp_try_fetch_tool "fetch_pdf" "$(_mcp_jq -n -c --arg url "$1" '{"url":$url}')"; }
mcp_github_search() { _mcp_try_fetch_tool "github_search" "$(_mcp_jq -n -c --arg q "$1" --argjson c "${2:-5}" '{"query":$q,"count":$c}')"; }

_mcp_try_server_tool() {
    local server="$1" tool="$2" args_json="${3:-}" result
    _mcp_server_exists "$server" || return 1
    result=$(mcp_tool_call "$server" "$tool" "$args_json" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$result" ]; then
        if [ "$server" = "george-mqtt" ]; then
            if [ "${LODGE_DEBUG:-0}" -eq 1 ]; then
                local _mqtt_log="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-$HOME/blue-lodge}/.george}/mqtt.log"
                mkdir -p "$(dirname "$_mqtt_log")" 2>/dev/null || true
                printf '[%s] [debug] MCP %s OK via %s (%s bytes)\n' "$(date +%T)" "$tool" "$server" "${#result}" >> "$_mqtt_log" 2>/dev/null || true
            fi
        else
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && ui_dim "  [debug] MCP $tool OK via $server (${#result} bytes)" >&2
            declare -f transcript_log &>/dev/null && transcript_log "mcp" "$tool OK: $server (${#result} bytes)"
        fi
        printf '%s' "$result"
        return 0
    fi
    return 1
}

mcp_git_status() { _mcp_try_server_tool "george-git" "git_status" "$(_mcp_jq -n -c --arg p "${1:-.}" '{"path":$p}')"; }
mcp_git_log() { _mcp_try_server_tool "george-git" "git_log" "$(_mcp_jq -n -c --argjson c "${1:-10}" --arg p "${2:-.}" '{"count":$c,"path":$p}')"; }
mcp_git_diff() {
    local _args=$(_mcp_jq -n -c --arg p "${1:-.}" --arg s "${2:-false}" --arg r "${3:-}" \
        '{path:$p} + (if $s == "true" then {staged:true} else {} end) + (if $r != "" then {ref:$r} else {} end)')
    _mcp_try_server_tool "george-git" "git_diff" "$_args"
}
mcp_git_commit() {
    local _args=$(_mcp_jq -n -c --arg m "$1" --arg p "${2:-.}" --arg f "${3:-}" \
        '{"message":$m,"path":$p} + (if $f != "" then {"files":$f} else {} end)')
    _mcp_try_server_tool "george-git" "git_commit" "$_args"
}
mcp_git_push() {
    local _args=$(_mcp_jq -n -c --arg p "${1:-.}" --arg r "${2:-origin}" --arg b "${3:-}" \
        '{"path":$p,"remote":$r} + (if $b != "" then {"branch":$b} else {} end)')
    _mcp_try_server_tool "george-git" "git_push" "$_args"
}
mcp_git_pull() { _mcp_try_server_tool "george-git" "git_pull" "$(_mcp_jq -n -c --arg p "${1:-.}" --arg r "${2:-origin}" '{"path":$p,"remote":$r}')"; }
mcp_git_branch() {
    local _args=$(_mcp_jq -n -c --arg p "${1:-.}" --arg n "${2:-}" \
        '{"path":$p} + (if $n != "" then {"name":$n} else {} end)')
    _mcp_try_server_tool "george-git" "git_branch" "$_args"
}
mcp_git_clone() { _mcp_try_server_tool "george-git" "git_clone" "$(_mcp_jq -n -c --arg u "$1" --arg p "${2:-.}" '{"url":$u,"path":$p}')"; }

mcp_mqtt_publish() {
    local _args=$(_mcp_jq -n -c --arg t "$1" --arg m "$2" --argjson q "${3:-0}" --arg r "${4:-false}" \
        '{"topic":$t,"message":$m,"qos":$q} + (if $r == "true" then {"retain":true} else {} end)')
    _mcp_try_server_tool "george-mqtt" "mqtt_publish" "$_args"
}
mcp_mqtt_subscribe() {
    local _args=$(_mcp_jq -n -c --arg t "$1" --argjson c "${2:-1}" --argjson to "${3:-10}" '{"topic":$t,"count":$c,"timeout":$to}')
    _mcp_try_server_tool "george-mqtt" "mqtt_subscribe" "$_args"
}
mcp_mqtt_status() { _mcp_try_server_tool "george-mqtt" "mqtt_status" '{}'; }

mcp_x_post() { _mcp_try_server_tool "george-x" "x_post" "$(_mcp_jq -n -c --arg t "$1" '{"text":$t}')"; }
mcp_x_timeline() { _mcp_try_server_tool "george-x" "x_timeline" "$(_mcp_jq -n -c --argjson c "${1:-10}" '{"count":$c}')"; }
mcp_x_reply() { _mcp_try_server_tool "george-x" "x_reply" "$(_mcp_jq -n -c --arg id "$1" --arg t "$2" '{"tweet_id":$id,"text":$t}')"; }
mcp_x_search() { _mcp_try_server_tool "george-x" "x_search" "$(_mcp_jq -n -c --arg q "$1" --argjson c "${2:-10}" '{"query":$q,"count":$c}')"; }
mcp_x_delete() { _mcp_try_server_tool "george-x" "x_delete" "$(_mcp_jq -n -c --arg id "$1" '{"tweet_id":$id}')"; }

mcp_inference_status() { _mcp_try_server_tool "george-inference" "inference_status" '{}'; }
mcp_inference_models() { _mcp_try_server_tool "george-inference" "inference_models" '{}'; }
mcp_inference_ps() { _mcp_try_server_tool "george-inference" "inference_ps" '{}'; }
mcp_inference_pull() { _mcp_try_server_tool "george-inference" "inference_pull" "$(_mcp_jq -n -c --arg m "$1" '{"model":$m}')"; }
mcp_inference_load() { _mcp_try_server_tool "george-inference" "inference_load" "$(_mcp_jq -n -c --arg m "$1" --arg k "${2:-5m}" '{"model":$m,"keep_alive":$k}')"; }

# ── Intercept, Catalog & CLI ──────────────────────────────────

_mcp_dispatch_intercept() {
    local cmd="$1" args="$2"
    mcp_enabled || return 1
    local server_name tools_json match params
    for server_name in $(mcp_running_servers); do
        tools_json=$(mcp_tools_list "$server_name" 2>/dev/null)
        [ -z "$tools_json" ] && continue
        match=$(printf '%s' "$tools_json" | _mcp_jq -r --arg cmd "$cmd" \
            '.[] | select(.name == $cmd or .name == ("mcp_" + $cmd) or .name == ($cmd + "_" + "fetch") or (.name | ascii_downcase) == ($cmd | ascii_downcase)) | .name' 2>/dev/null | head -1)
        params=""
        if [ -z "$match" ] && [ -n "$args" ]; then
            local _subcmd _subrest _compound
            _subcmd=$(echo "$args" | awk '{print $1}')
            _subrest=$(echo "$args" | sed 's/^[^ ]* *//')
            [ "$_subrest" = "$args" ] && _subrest=""
            if [ -n "$_subcmd" ]; then
                _compound="${cmd}_${_subcmd}"
                match=$(printf '%s' "$tools_json" | _mcp_jq -r --arg compound "$_compound" \
                    '.[] | select((.name | ascii_downcase) == ($compound | ascii_downcase)) | .name' 2>/dev/null | head -1)
                if [ -z "$match" ] && [ "$cmd" = "github" ]; then
                    local _alias_compound="git_${_subcmd}"
                    match=$(printf '%s' "$tools_json" | _mcp_jq -r --arg compound "$_alias_compound" \
                        '.[] | select((.name | ascii_downcase) == ($compound | ascii_downcase)) | .name' 2>/dev/null | head -1)
                fi
                if [ -n "$match" ]; then
                    local _req_param
                    _req_param=$(printf '%s' "$tools_json" | _mcp_jq -r --arg name "$match" \
                        '.[] | select(.name == $name) | .inputSchema.required // [] | .[0] // empty' 2>/dev/null)
                    if [ -n "$_subrest" ] && [ -n "$_req_param" ]; then
                        params=$(_mcp_jq -n -c --arg key "$_req_param" --arg val "$_subrest" '{($key): $val}')
                    elif [ -n "$_subrest" ]; then
                        params=$(_mcp_jq -n -c --arg input "$_subrest" '{"input":$input}')
                    else
                        params='{}'
                    fi
                fi
            fi
        fi
        if [ -n "$match" ]; then
            [ -z "$params" ] && params=$(_mcp_jq -n -c --arg input "$args" '{"input":$input}')
            local result=$(mcp_tool_call "$server_name" "$match" "$params" 2>/dev/null)
            if [ -n "$result" ]; then
                printf '%s' "$result"
                return 0
            fi
        fi
    done
    return 1
}

mcp_catalog() {
    mcp_enabled || return 1
    local catalog="" server_name
    for server_name in $(mcp_server_names); do
        local desc=$(_mcp_server_desc "$server_name")
        local tools_json=$(mcp_tools_list "$server_name" 2>/dev/null)
        if [ -n "$tools_json" ] && [ "$tools_json" != "[]" ]; then
            local tool_summary=$(printf '%s' "$tools_json" | _mcp_jq -r '.[] | "    - " + .name + ": " + (.description // "no description")' 2>/dev/null)
            catalog="${catalog}MCP Server: ${server_name} — ${desc}\n  Tools:\n${tool_summary}\n\n"
        else
            catalog="${catalog}MCP Server: ${server_name} — ${desc} (no tools cached)\n\n"
        fi
    done
    if [ -n "$catalog" ]; then
        printf 'MCP INTEGRATION (ENABLED)\nUse /mcp call <server> <tool> <json_params> to invoke MCP tools.\nAvailable servers and tools:\n\n%b' "$catalog"
    fi
}

mcp_find_tool() {
    local tool_name="$1" server_name tools_json found
    for server_name in $(mcp_server_names); do
        tools_json=$(mcp_tools_list "$server_name" 2>/dev/null)
        [ -z "$tools_json" ] && continue
        found=$(printf '%s' "$tools_json" | _mcp_jq -r --arg t "$tool_name" '.[] | select(.name == $t) | .name' 2>/dev/null)
        if [ -n "$found" ]; then
            echo "$server_name"
            return 0
        fi
    done
    return 1
}

_mcp_write_default_catalog() {
    mkdir -p "$MCP_CONFIG_DIR"
    cat > "$MCP_CATALOG_FILE" << CATALOG
# George MCP Server Catalog — recommended servers
# Format: name|command|description
# Install with: /mcp install <name>
george-fetch|bash $LODGE_DIR/lib/tools/mcp_server_fetch.sh|Built-in web fetch (pure bash, no Node.js)
george-git|bash $LODGE_DIR/lib/tools/mcp_server_git.sh|Built-in git & GitHub operations (pure bash, no Node.js)
george-gitea|bash $LODGE_DIR/lib/tools/mcp_server_gitea.sh|Built-in Sovereign Gitea Git Forge & PR review orchestration
george-fusion|python3 $LODGE_DIR/lib/tools/mcp_server_fusion.py|Autodesk Fusion 360 Parametric CAD & 3D Fabrication
george-gcloud|bash $LODGE_DIR/lib/tools/mcp_server_gcloud.sh|Pure-bash Google Cloud Platform (gcloud) orchestration
george-inference|bash $LODGE_DIR/lib/tools/mcp_server_inference.sh|Built-in remote GPU inference catalog & management
george-mqtt|bash $LODGE_DIR/lib/tools/mcp_server_mqtt.sh|Built-in MQTT pub/sub messaging (pure bash, no Node.js)
george-x|bash $LODGE_DIR/lib/tools/mcp_server_x.sh|Built-in X/Twitter integration (pure bash, no Node.js)
memory|npx -y @modelcontextprotocol/server-memory|Persistent Knowledge Graph Memory
fetch|npx -y @anthropic/mcp-server-fetch|Web content fetching (enhanced scraping)
puppeteer|npx -y @anthropic/mcp-server-puppeteer|Browser automation for JS-rendered pages
brave-search|npx -y @anthropic/mcp-server-brave-search|Web search via Brave API (needs BRAVE_API_KEY)
github|npx -y @anthropic/mcp-server-github|GitHub operations (needs GITHUB_TOKEN)
filesystem|npx -y @anthropic/mcp-server-filesystem .|Local filesystem access (scoped to current dir)
sqlite|npx -y @anthropic/mcp-server-sqlite|SQLite database queries
everything|npx -y @anthropic/mcp-server-everything|Testing/demo server (all tool types)
CATALOG
}

mcp_catalog_list() {
    [ -f "$MCP_CATALOG_FILE" ] || _mcp_write_default_catalog
    grep -v '^#' "$MCP_CATALOG_FILE" 2>/dev/null | grep -v '^$'
}

mcp_catalog_install() {
    local catalog_name="$1" entry
    entry=$(mcp_catalog_list | grep "^${catalog_name}|" | head -1)
    if [ -z "$entry" ]; then
        echo "ERROR: '$catalog_name' not found in MCP catalog" >&2
        echo "Available: $(mcp_catalog_list | cut -d'|' -f1 | tr '\n' ' ')" >&2
        return 1
    fi
    mcp_server_add "$catalog_name" "$(echo "$entry" | cut -d'|' -f2)" "$(echo "$entry" | cut -d'|' -f3)"
}

mcp_command() {
    local args="$1"
    local action=$(echo "$args" | awk '{print $1}')
    local rest=$(echo "$args" | sed 's/^[^ ]* *//')
    [ "$rest" = "$args" ] && rest=""

    case "$action" in
        ""|status) _mcp_show_status ;;
        on|enable)
            MCP_ENABLED=1
            mcp_init
            if mcp_has_servers; then
                local _sname
                while IFS= read -r _sname; do
                    [ -z "$_sname" ] && continue
                    mcp_status "$_sname" >/dev/null 2>&1 && continue
                    declare -f ui_dim &>/dev/null && ui_dim "  Starting MCP server '$_sname'..." >&2
                    if mcp_start "$_sname" 2>/dev/null; then
                        declare -f ui_ok &>/dev/null && ui_ok "MCP server '$_sname' started"
                    else
                        declare -f ui_warn &>/dev/null && ui_warn "MCP server '$_sname' failed to start" >&2
                    fi
                done <<< "$(mcp_server_names)"
            fi
            declare -f _llm_save_config &>/dev/null && _llm_save_config 2>/dev/null
            declare -f ui_ok &>/dev/null && ui_ok "MCP integration enabled" || echo "MCP integration enabled"
            ;;
        off|disable)
            MCP_ENABLED=0
            mcp_stop_all
            declare -f _llm_save_config &>/dev/null && _llm_save_config 2>/dev/null
            declare -f ui_ok &>/dev/null && ui_ok "MCP integration disabled" || echo "MCP integration disabled"
            ;;
        add|register)
            local name=$(echo "$rest" | awk '{print $1}')
            local cmd_str=$(echo "$rest" | awk '{$1=""; print}' | sed 's/^ *//') desc_str
            if [ -z "$name" ] || [ -z "$cmd_str" ]; then
                declare -f ui_section &>/dev/null && ui_section "Register MCP Server"
                printf "  Server name (alphanumeric, hyphens, underscores): "; read -r name
                [ -z "$name" ] && { echo "Cancelled — no name given" >&2; return 1; }
                printf "  Command to start the server: "; read -r cmd_str
                [ -z "$cmd_str" ] && { echo "Cancelled — no command given" >&2; return 1; }
                printf "  Description [MCP server: %s]: " "$name"; read -r desc_str
                [ -z "$desc_str" ] && desc_str="MCP server: $name"
            else
                desc_str="MCP server: $name"
            fi
            mcp_init 2>/dev/null
            if mcp_server_add "$name" "$cmd_str" "$desc_str"; then
                if declare -f ui_ok &>/dev/null; then
                    ui_ok "MCP server '$name' registered"
                    ui_dim "  cmd: $cmd_str" >&2
                    ui_dim "  Start with: /mcp start $name" >&2
                else
                    echo "MCP server '$name' registered"
                fi
            fi
            ;;
        remove|rm)
            local name=$(echo "$rest" | awk '{print $1}')
            [ -z "$name" ] && { echo "Usage: /mcp remove <name>" >&2; return 1; }
            mcp_server_remove "$name"
            declare -f ui_ok &>/dev/null && ui_ok "MCP server '$name' removed" || echo "MCP server '$name' removed"
            ;;
        list) _mcp_show_servers ;;
        catalog) _mcp_show_catalog ;;
        install)
            local catalog_name=$(echo "$rest" | awk '{print $1}')
            [ -z "$catalog_name" ] && { _mcp_show_catalog; return 0; }
            if mcp_catalog_install "$catalog_name"; then
                declare -f ui_ok &>/dev/null && ui_ok "Installed '$catalog_name' from catalog"
            fi
            ;;
        start)
            local name=$(echo "$rest" | awk '{print $1}')
            [ -z "$name" ] && { echo "Usage: /mcp start <name>" >&2; return 1; }
            MCP_ENABLED=1
            declare -f ui_dim &>/dev/null && ui_dim "Starting MCP server '$name'..." >&2
            if mcp_start "$name"; then
                declare -f ui_ok &>/dev/null && ui_ok "MCP server '$name' started and ready" || echo "MCP server '$name' started"
            else
                if declare -f ui_err &>/dev/null; then
                    ui_err "Failed to start MCP server '$name'" >&2
                    local stderr_file="$MCP_RUN_DIR/$name/stderr.log"
                    if [ -f "$stderr_file" ] && [ -s "$stderr_file" ]; then
                        ui_dim "Server stderr:" >&2
                        tail -5 "$stderr_file" | while IFS= read -r line; do ui_dim "  $line" >&2; done
                    fi
                fi
                return 1
            fi
            ;;
        stop)
            local name=$(echo "$rest" | awk '{print $1}')
            if [ -z "$name" ] || [ "$name" = "all" ]; then
                mcp_stop_all
                declare -f ui_ok &>/dev/null && ui_ok "All MCP servers stopped" || echo "All MCP servers stopped"
            else
                mcp_stop "$name"
                declare -f ui_ok &>/dev/null && ui_ok "MCP server '$name' stopped" || echo "MCP server '$name' stopped"
            fi
            ;;
        tools)
            local name=$(echo "$rest" | awk '{print $1}')
            if [ -z "$name" ]; then
                local server_name tools
                for server_name in $(mcp_server_names); do
                    echo "=== $server_name ==="
                    tools=$(mcp_tools_list "$server_name" 2>/dev/null)
                    if [ -n "$tools" ] && [ "$tools" != "[]" ]; then
                        printf '%s' "$tools" | _mcp_jq -r '.[] | "  " + .name + " — " + (.description // "")' 2>/dev/null
                    else
                        echo "  (no tools or server not started)"
                    fi
                    echo ""
                done
            else
                local tools=$(mcp_tools_list "$name" 2>/dev/null)
                if [ -n "$tools" ] && [ "$tools" != "[]" ]; then
                    printf '%s' "$tools" | _mcp_jq -r '.[] | .name + " — " + (.description // "")' 2>/dev/null
                else
                    echo "No tools found (is '$name' registered and running?)" >&2
                fi
            fi
            ;;
        call)
            local server=$(echo "$rest" | awk '{print $1}')
            local tool=$(echo "$rest" | awk '{print $2}')
            local params_json=$(echo "$rest" | awk '{$1=""; $2=""; print}' | sed 's/^ *//')
            [ -z "$params_json" ] && params_json='{}'
            if [ -z "$server" ] || [ -z "$tool" ]; then
                echo "Usage: /mcp call <server> <tool> [params_json]" >&2
                return 1
            fi
            MCP_ENABLED=1
            local result=$(mcp_tool_call "$server" "$tool" "$params_json" 2>/dev/null)
            if [ -n "$result" ]; then
                echo "$result"
            else
                echo "MCP call failed: $server / $tool" >&2
                return 1
            fi
            ;;
        cache)
            local subaction=$(echo "$rest" | awk '{print $1}')
            if [ "$subaction" = "clear" ]; then
                if declare -f cache_invalidate_ns &>/dev/null; then
                    cache_invalidate_ns "$MCP_CACHE_NS"
                    declare -f ui_ok &>/dev/null && ui_ok "MCP tool cache cleared" || echo "MCP tool cache cleared"
                fi
            else
                declare -f cache_stats &>/dev/null && echo "MCP Cache: $(cache_stats)"
            fi
            ;;
        help|*) _mcp_show_help ;;
    esac
}

_mcp_show_status() {
    declare -f ui_section &>/dev/null && ui_section "MCP Integration" || echo "MCP Integration"
    echo ""
    local status_label="DISABLED"
    mcp_enabled && status_label="ENABLED"
    declare -f ui_info &>/dev/null && ui_info "Status: $status_label" || echo "Status: $status_label"

    local running=$(mcp_running_servers)
    if [ -n "$running" ]; then
        declare -f ui_info &>/dev/null && ui_info "Running servers:" || echo "Running servers:"
        for name in $running; do
            local desc=$(_mcp_server_desc "$name")
            declare -f ui_dim &>/dev/null && ui_dim "  ● $name — ${desc:-MCP server}" >&2 || echo "  ● $name — ${desc:-MCP server}" >&2
        done
    else
        declare -f ui_dim &>/dev/null && ui_dim "No servers running" >&2 || echo "No servers running" >&2
    fi

    local total=$(mcp_server_names | wc -l)
    total="${total## }"
    declare -f ui_dim &>/dev/null && ui_dim "Registered: ${total:-0} servers" >&2 || echo "Registered: ${total:-0} servers" >&2
    declare -f cache_stats &>/dev/null && { declare -f ui_dim &>/dev/null && ui_dim "Tool cache: $(cache_stats)" >&2 || echo "Tool cache: $(cache_stats)" >&2; }
    echo ""
    declare -f ui_dim &>/dev/null && ui_dim "  /mcp on|off     — Enable/disable MCP" >&2 || echo "  /mcp on|off     — Enable/disable MCP" >&2
    declare -f ui_dim &>/dev/null && ui_dim "  /mcp list       — Show registered servers" >&2 || echo "  /mcp list       — Show registered servers" >&2
    declare -f ui_dim &>/dev/null && ui_dim "  /mcp catalog    — Browse recommended servers" >&2 || echo "  /mcp catalog    — Browse recommended servers" >&2
    declare -f ui_dim &>/dev/null && ui_dim "  /mcp help       — Full command reference" >&2 || echo "  /mcp help       — Full command reference" >&2
}

_mcp_show_servers() {
    declare -f ui_section &>/dev/null && ui_section "Registered MCP Servers" || echo "Registered MCP Servers"
    echo ""
    local entries=$(mcp_server_list)
    if [ -z "$entries" ]; then
        declare -f ui_dim &>/dev/null && ui_dim "No servers registered. Try: /mcp install fetch" >&2 || echo "No servers registered. Try: /mcp install fetch" >&2
        return
    fi
    local name cmd desc state
    while IFS='|' read -r name cmd desc; do
        [ -z "$name" ] && continue
        state="○"
        mcp_status "$name" >/dev/null 2>&1 && state="●"
        printf "  %s %-15s %s\n" "$state" "$name" "${desc:-}"
        declare -f ui_dim &>/dev/null && ui_dim "    cmd: $cmd" >&2 || echo "    cmd: $cmd" >&2
    done <<< "$entries"
    echo ""
    declare -f ui_dim &>/dev/null && ui_dim "  ● = running, ○ = stopped" >&2 || echo "  ● = running, ○ = stopped" >&2
}

_mcp_show_catalog() {
    declare -f ui_section &>/dev/null && ui_section "MCP Server Catalog" || echo "MCP Server Catalog"
    echo ""
    local entries=$(mcp_catalog_list)
    if [ -z "$entries" ]; then
        declare -f ui_dim &>/dev/null && ui_dim "No catalog available" >&2 || echo "No catalog available" >&2
        return
    fi
    local name cmd desc installed
    while IFS='|' read -r name cmd desc; do
        [ -z "$name" ] && continue
        installed=""
        _mcp_server_exists "$name" && installed=" [installed]"
        printf "  %-15s %s%s\n" "$name" "${desc:-}" "$installed"
    done <<< "$entries"
    echo ""
    declare -f ui_dim &>/dev/null && ui_dim "  Install: /mcp install <name>" >&2 || echo "  Install: /mcp install <name>" >&2
    declare -f ui_dim &>/dev/null && ui_dim "  Then:    /mcp start <name>" >&2 || echo "  Then:    /mcp start <name>" >&2
}

_mcp_show_help() {
    declare -f ui_section &>/dev/null && ui_section "MCP Commands" || echo "MCP Commands"
    echo ""
    declare -f ui_dim &>/dev/null && {
        ui_dim "  /mcp                         Show status overview"
        ui_dim "  /mcp on | off                Enable/disable MCP integration"
        ui_dim "  /mcp add [name] [command]    Register a server (interactive if no args)"
        ui_dim "  /mcp register               Interactive server registration"
        ui_dim "  /mcp remove <name>           Unregister a server"
        ui_dim "  /mcp list                    List registered servers"
        ui_dim "  /mcp catalog                 Browse recommended servers"
        ui_dim "  /mcp install <name>          Install from catalog"
        ui_dim "  /mcp start <name>            Start a server"
        ui_dim "  /mcp stop [name|all]         Stop server(s)"
        ui_dim "  /mcp tools [name]            List available tools"
        ui_dim "  /mcp call <srv> <tool> [{}]  Call an MCP tool"
        ui_dim "  /mcp cache [clear]           View/clear tool cache"
        ui_dim "  /mcp help                    This help"
        echo ""
        ui_dim "  When MCP is enabled, George uses MCP tools as the primary"
        ui_dim "  path and falls back to native slash commands on failure."
    } || {
        echo "  /mcp                         Show status overview"
        echo "  /mcp on | off                Enable/disable MCP integration"
        echo "  /mcp add [name] [command]    Register a server (interactive if no args)"
        echo "  /mcp register               Interactive server registration"
        echo "  /mcp remove <name>           Unregister a server"
        echo "  /mcp list                    List registered servers"
        echo "  /mcp catalog                 Browse recommended servers"
        echo "  /mcp install <name>          Install from catalog"
        echo "  /mcp start <name>            Start a server"
        echo "  /mcp stop [name|all]         Stop server(s)"
        echo "  /mcp tools [name]            List available tools"
        echo "  /mcp call <srv> <tool> [{}]  Call an MCP tool"
        echo "  /mcp cache [clear]           View/clear tool cache"
        echo "  /mcp help                    This help"
        echo ""
        echo "  When MCP is enabled, George uses MCP tools as the primary"
        echo "  path and falls back to native slash commands on failure."
    }
}

_mcp_cleanup() {
    mcp_stop_all 2>/dev/null
    rm -rf "$MCP_RUN_DIR" 2>/dev/null
}
