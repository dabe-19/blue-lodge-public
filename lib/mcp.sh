#!/bin/bash
# ── George: MCP (Model Context Protocol) Client ───────────────
# Pure-bash MCP client using jq for JSON-RPC 2.0 over stdio.
# No Python bridge, no Node.js runtime — just bash + jq.
#
# Architecture:
#   - FIFO for server stdin + regular file for stdout
#     (avoids subshell deadlocks that killed the FIFO-only approach)
#   - Flat file registry (bash 3.2 compatible, no assoc arrays)
#   - LRU cache for MCP tool catalogs (via lib/cache.sh)
#   - MCP-first dispatch with fallback to native slash commands
#
# Hard-won lessons incorporated from test build:
#   1. No FIFOs for READING responses (deadlock in $() subshells)
#   2. No ${3:-{}} patterns (bash misparses closing brace)
#   3. Background processes fully detached (</dev/null >/dev/null)
#   4. pkill -P for proper child process cleanup
#   5. Time-based response polling (not fixed iteration count)
#   6. Post-handshake notification drain (cold-start reliability)
#   7. Flat files not assoc arrays (bash 3.2 on macOS)
#
# Attribution:
#   MCP protocol: Anthropic (modelcontextprotocol.io)
#   Pure-bash MCP feasibility validated by:
#     yaniv-golan/mcp-bash-framework (MIT, server-side framework)
#   George's MCP client is an original implementation.

[ -n "${_LIB_MCP_LOADED:-}" ] && return 0; _LIB_MCP_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR:-.}/.george}"

# ── Config ─────────────────────────────────────────────────────
MCP_ENABLED="${MCP_ENABLED:-0}"
MCP_CONFIG_DIR="${MCP_CONFIG_DIR:-$GEORGE_DIR/mcp}"
MCP_RUN_DIR="${MCP_RUN_DIR:-${TMPDIR:-/tmp}/.lodge-mcp-$$}"
MCP_TIMEOUT="${MCP_TIMEOUT:-30}"
MCP_CACHE_NS="mcp"               # LRU cache namespace
MCP_SERVERS_FILE="${MCP_CONFIG_DIR}/servers.conf"
MCP_CATALOG_FILE="${MCP_CONFIG_DIR}/catalog.conf"

# ── jq is a hard dependency (enforced by install.sh + lodge main) ──
_MCP_JQ_CMD=jq

# ── Initialize ─────────────────────────────────────────────────
mcp_init() {
    mkdir -p "$MCP_CONFIG_DIR" "$MCP_RUN_DIR"

    # Seed default catalog if missing
    if [ ! -f "$MCP_CATALOG_FILE" ]; then
        _mcp_write_default_catalog
    fi

    # Create empty registry if missing
    [ -f "$MCP_SERVERS_FILE" ] || touch "$MCP_SERVERS_FILE"
}

mcp_enabled() {
    [ "${MCP_ENABLED:-0}" -eq 1 ]
}

# ── Utility: safe jq wrapper ──────────────────────────────────
_mcp_jq() {
    "$_MCP_JQ_CMD" "$@"
}

# ── Server Registry (flat file: name|command|description) ──────
# Bash 3.2 compatible — no associative arrays.

_mcp_server_exists() {
    local name="$1"
    [ -f "$MCP_SERVERS_FILE" ] && grep -q "^${name}|" "$MCP_SERVERS_FILE" 2>/dev/null
}

_mcp_server_cmd() {
    local name="$1"
    [ -f "$MCP_SERVERS_FILE" ] || return 1
    grep "^${name}|" "$MCP_SERVERS_FILE" 2>/dev/null | head -1 | cut -d'|' -f2
}

_mcp_server_desc() {
    local name="$1"
    [ -f "$MCP_SERVERS_FILE" ] || return 1
    grep "^${name}|" "$MCP_SERVERS_FILE" 2>/dev/null | head -1 | cut -d'|' -f3
}

mcp_server_add() {
    local name="$1"
    local cmd="$2"
    local desc="${3:-MCP server}"

    # Validate name: alphanumeric + hyphens only
    if ! printf '%s' "$name" | grep -qE '^[a-zA-Z0-9_-]+$'; then
        echo "ERROR: Server name must be alphanumeric (hyphens/underscores allowed)" >&2
        return 1
    fi

    mcp_init

    # Remove existing entry if any
    if _mcp_server_exists "$name"; then
        local tmp_file="${MCP_SERVERS_FILE}.tmp"
        grep -v "^${name}|" "$MCP_SERVERS_FILE" > "$tmp_file" 2>/dev/null
        mv "$tmp_file" "$MCP_SERVERS_FILE"
    fi

    echo "${name}|${cmd}|${desc}" >> "$MCP_SERVERS_FILE"
}

mcp_server_remove() {
    local name="$1"
    [ -f "$MCP_SERVERS_FILE" ] || return 1

    # Stop if running
    mcp_status "$name" >/dev/null 2>&1 && mcp_stop "$name"

    local tmp_file="${MCP_SERVERS_FILE}.tmp"
    grep -v "^${name}|" "$MCP_SERVERS_FILE" > "$tmp_file" 2>/dev/null
    mv "$tmp_file" "$MCP_SERVERS_FILE"

    # Invalidate tool cache for this server
    if declare -f cache_invalidate &>/dev/null; then
        cache_invalidate "mcp:tools:${name}"
    fi
}

mcp_server_list() {
    [ -f "$MCP_SERVERS_FILE" ] || { echo ""; return; }
    grep -v '^#' "$MCP_SERVERS_FILE" 2>/dev/null | grep -v '^$'
}

mcp_server_names() {
    mcp_server_list | cut -d'|' -f1
}

# ── JSON-RPC 2.0 Helpers ──────────────────────────────────────

_mcp_next_id() {
    local name="$1"
    local id_file="$MCP_RUN_DIR/$name/req_id"
    local current
    current=$(cat "$id_file" 2>/dev/null || echo 0)
    local next=$((current + 1))
    echo "$next" > "$id_file"
    echo "$next"
}

_mcp_build_request() {
    local id="$1"
    local method="$2"
    # Avoid ${3:-{}} — bash misparses the braces
    local params="$3"
    [ -z "$params" ] && params='{}'

    _mcp_jq -n -c \
        --argjson id "$id" \
        --arg method "$method" \
        --argjson params "$params" \
        '{"jsonrpc":"2.0","id":$id,"method":$method,"params":$params}'
}

_mcp_build_notification() {
    local method="$1"
    local params="${2:-}"
    [ -z "$params" ] && params='{}'

    _mcp_jq -n -c \
        --arg method "$method" \
        --argjson params "$params" \
        '{"jsonrpc":"2.0","method":$method,"params":$params}'
}

# ── Transport: FIFO (stdin) + regular file (stdout) ───────────
# Server stdin: FIFO with a sleep process holding the write end open.
# Server stdout: Regular file (append). No FIFO — avoids subshell deadlocks.
# Requests: printf to FIFO (atomic for < PIPE_BUF = 4KB).
# Responses: Poll the regular file for matching JSON-RPC id.

_mcp_send() {
    local name="$1"
    local json="$2"
    local fifo="$MCP_RUN_DIR/$name/in.fifo"

    [ -p "$fifo" ] || return 1

    # Atomic write to FIFO — server reads immediately
    # Safe from subshells: we only WRITE to the FIFO, never READ
    printf '%s\n' "$json" > "$fifo"
}

_mcp_recv() {
    local name="$1"
    local req_id="$2"
    local timeout="$3"
    [ -z "$timeout" ] && timeout="$MCP_TIMEOUT"

    local resp_file="$MCP_RUN_DIR/$name/responses.jsonl"
    local deadline=$(($(date +%s) + timeout))
    local last_size=0

    while [ "$(date +%s)" -lt "$deadline" ]; do
        if [ -f "$resp_file" ]; then
            local current_size
            current_size=$(wc -c < "$resp_file" 2>/dev/null)
            # wc -c may have leading whitespace on some systems
            current_size="${current_size## }"
            current_size="${current_size:-0}"

            if [ "$current_size" -gt "$last_size" ]; then
                # New data — check only new portion
                local new_data
                new_data=$(tail -c +"$((last_size + 1))" "$resp_file" 2>/dev/null)

                # Process only complete lines (newline-terminated) to
                # avoid matching a partially-written JSON response.
                # Any incomplete trailing data is re-read on the next
                # poll since last_size only advances to the end of the
                # last complete newline.
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
                # Only advance past fully-read complete lines
                last_size=$((last_size + _complete_bytes))
            fi
        fi
        sleep 0.1
    done

    return 1
}

# ── MCP Handshake (initialize + initialized) ──────────────────
_mcp_handshake() {
    local name="$1"
    local rundir="$MCP_RUN_DIR/$name"

    # Build initialize request
    local req_id
    req_id=$(_mcp_next_id "$name")
    local init_params
    init_params=$(_mcp_jq -n '{
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "george", version: "1.0" }
    }')
    local init_req
    init_req=$(_mcp_build_request "$req_id" "initialize" "$init_params")

    # Send initialize
    _mcp_send "$name" "$init_req" || return 1

    # Wait for response (15s — servers may need time to start)
    local init_resp
    init_resp=$(_mcp_recv "$name" "$req_id" 15)
    if [ -z "$init_resp" ]; then
        return 1
    fi

    # Verify valid initialize response
    local proto_ver
    proto_ver=$(printf '%s' "$init_resp" | _mcp_jq -r '.result.protocolVersion // empty' 2>/dev/null)
    if [ -z "$proto_ver" ]; then
        return 1
    fi

    # Cache server info
    printf '%s' "$init_resp" | _mcp_jq -r '.result' > "$rundir/capabilities.json" 2>/dev/null

    # Send initialized notification (no response expected)
    local notif
    notif=$(_mcp_build_notification "notifications/initialized")
    _mcp_send "$name" "$notif"

    # Post-handshake drain — wait for async notifications to clear
    # This fixes cold-start empty responses with real MCP servers
    sleep 0.3

    return 0
}

# ── Server Lifecycle ───────────────────────────────────────────

mcp_start() {
    local name="$1"

    local cmd
    cmd=$(_mcp_server_cmd "$name")
    if [ -z "$cmd" ]; then
        echo "ERROR: Unknown MCP server: $name" >&2
        return 1
    fi

    # Check if already running
    if mcp_status "$name" >/dev/null 2>&1; then
        return 0
    fi

    local rundir="$MCP_RUN_DIR/$name"
    mkdir -p "$rundir"

    # Clean previous run artifacts
    rm -f "$rundir"/{in.fifo,responses.jsonl,stderr.log,pid,keeper_pid,ready,req_id,capabilities.json}
    touch "$rundir/responses.jsonl"
    echo "0" > "$rundir/req_id"

    # Create stdin FIFO
    mkfifo "$rundir/in.fifo" 2>/dev/null || {
        rm -f "$rundir/in.fifo"
        mkfifo "$rundir/in.fifo" || return 1
    }

    # Start server: exec replaces the backgrounded subshell so $! tracks the
    # real server PID (without exec, $! captures the intermediate subshell).
    eval "exec $cmd" < "$rundir/in.fifo" >> "$rundir/responses.jsonl" 2>"$rundir/stderr.log" &
    local server_pid=$!
    echo "$server_pid" > "$rundir/pid"

    # Keep FIFO write end open so server doesn't get EOF on stdin.
    # All FDs detached to prevent subshell inheritance issues.
    # 86400s = 24 hours — plenty for any session.
    sleep 86400 > "$rundir/in.fifo" </dev/null 2>/dev/null &
    local keeper_pid=$!
    echo "$keeper_pid" > "$rundir/keeper_pid"

    # Wait for server process to start
    sleep 0.5

    # Verify server is still alive
    if ! kill -0 "$server_pid" 2>/dev/null; then
        echo "ERROR: MCP server '$name' died on startup" >&2
        declare -f ui_err &>/dev/null && ui_err "MCP server '$name' died on startup (pid=$server_pid)" >&2
        declare -f transcript_log &>/dev/null && transcript_log "mcp" "server '$name' FAILED to start (died on launch)"
        mcp_stop "$name"
        return 1
    fi

    # MCP handshake
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

    # Kill keeper process (FIFO writer)
    if [ -f "$rundir/keeper_pid" ]; then
        local keeper_pid
        keeper_pid=$(cat "$rundir/keeper_pid")
        kill "$keeper_pid" 2>/dev/null
        wait "$keeper_pid" 2>/dev/null
    fi

    # Kill server — children first (e.g., node spawned by npx)
    if [ -f "$rundir/pid" ]; then
        local pid
        pid=$(cat "$rundir/pid")
        if kill -0 "$pid" 2>/dev/null; then
            pkill -P "$pid" 2>/dev/null
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
        fi
    fi

    # Cleanup runtime files
    rm -f "$rundir"/{in.fifo,pid,keeper_pid,ready,req_id}
}

mcp_stop_all() {
    [ -d "$MCP_RUN_DIR" ] || return 0
    local name
    for dir in "$MCP_RUN_DIR"/*/; do
        [ -d "$dir" ] || continue
        name=$(basename "$dir")
        mcp_stop "$name"
    done
}

# Start all registered servers (skips already-running ones).
# Returns 0 if at least one server started successfully.
mcp_start_all() {
    mcp_init
    local names started=0 failed=0
    names=$(mcp_server_names)
    [ -z "$names" ] && return 1
    local name
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        if mcp_status "$name" >/dev/null 2>&1; then
            continue  # already running
        fi
        if mcp_start "$name" 2>/dev/null; then
            started=$((started + 1))
        else
            failed=$((failed + 1))
            declare -f ui_warn &>/dev/null && ui_warn "MCP server '$name' failed to start" >&2
        fi
    done <<< "$names"
    [ "$started" -gt 0 ]
}

# Check if any MCP servers are registered (servers.conf has entries).
mcp_has_servers() {
    [ -f "$MCP_SERVERS_FILE" ] || return 1
    grep -q -v '^#' "$MCP_SERVERS_FILE" 2>/dev/null && \
        grep -v '^#' "$MCP_SERVERS_FILE" 2>/dev/null | grep -q -v '^$'
}

mcp_status() {
    local name="$1"
    local rundir="$MCP_RUN_DIR/$name"

    [ -f "$rundir/pid" ] || return 1
    local pid
    pid=$(cat "$rundir/pid")
    kill -0 "$pid" 2>/dev/null || return 1
    [ -f "$rundir/ready" ] || return 2  # running but not ready
    return 0
}

mcp_running_servers() {
    [ -d "$MCP_RUN_DIR" ] || return
    local name
    for dir in "$MCP_RUN_DIR"/*/; do
        [ -d "$dir" ] || continue
        name=$(basename "$dir")
        if mcp_status "$name" >/dev/null 2>&1; then
            echo "$name"
        fi
    done
}

# ── MCP Protocol: Tools ───────────────────────────────────────

mcp_tools_list() {
    local name="$1"

    # Check LRU cache first
    if declare -f cache_get &>/dev/null; then
        local cached
        cached=$(cache_get "mcp:tools:${name}" "$MCP_CACHE_NS")
        if [ $? -eq 0 ] && [ -n "$cached" ]; then
            printf '%s' "$cached"
            return 0
        fi
    fi

    # Ensure server is running
    mcp_status "$name" >/dev/null 2>&1 || {
        mcp_start "$name" || return 1
    }

    local req_id
    req_id=$(_mcp_next_id "$name")
    local req
    req=$(_mcp_build_request "$req_id" "tools/list" '{}')

    _mcp_send "$name" "$req" || return 1

    local resp
    resp=$(_mcp_recv "$name" "$req_id" "$MCP_TIMEOUT")
    if [ -z "$resp" ]; then
        return 1
    fi

    # Check for JSON-RPC error response
    local _tl_err
    _tl_err=$(printf '%s' "$resp" | _mcp_jq -r '.error.message // empty' 2>/dev/null)
    if [ -n "$_tl_err" ]; then
        echo "MCP ERROR (tools/list): $_tl_err" >&2
        declare -f ui_err &>/dev/null && ui_err "MCP tools/list ERROR: server=$name msg=$_tl_err" >&2
        declare -f transcript_log &>/dev/null && transcript_log "mcp" "tools/list ERROR: server=$name msg=$_tl_err"
        return 1
    fi

    local tools
    tools=$(printf '%s' "$resp" | _mcp_jq -r '.result.tools // []' 2>/dev/null)
    if [ -z "$tools" ] || [ "$tools" = "null" ]; then
        tools="[]"
    fi

    # Log discovered tools count
    local _tool_count
    _tool_count=$(printf '%s' "$tools" | _mcp_jq 'length' 2>/dev/null || echo 0)
    [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && ui_dim "  [debug] MCP tools/list: server=$name tools=$_tool_count" >&2

    # Cache the tools list
    if declare -f cache_put &>/dev/null; then
        cache_put "mcp:tools:${name}" "$MCP_CACHE_NS" "$tools"
    fi

    printf '%s' "$tools"
}

mcp_tool_call() {
    local server="$1"
    local tool="$2"
    # Avoid ${3:-{}} bash brace misparse
    local params="$3"
    [ -z "$params" ] && params='{}'

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && ui_dim "  [debug] MCP tool_call: server=$server tool=$tool params=${params:0:120}" >&2

    # Ensure server is running
    mcp_status "$server" >/dev/null 2>&1 || {
        mcp_start "$server" || {
            declare -f ui_err &>/dev/null && ui_err "MCP tool_call FAILED: cannot start server '$server'" >&2
            declare -f transcript_log &>/dev/null && transcript_log "mcp" "tool_call FAILED: server '$server' won't start (tool=$tool)"
            return 1
        }
    }

    local req_id
    req_id=$(_mcp_next_id "$server")
    local call_params
    call_params=$(_mcp_jq -n -c \
        --arg name "$tool" \
        --argjson arguments "$params" \
        '{"name":$name,"arguments":$arguments}')
    local req
    req=$(_mcp_build_request "$req_id" "tools/call" "$call_params")

    _mcp_send "$server" "$req" || return 1

    local resp
    resp=$(_mcp_recv "$server" "$req_id" "$MCP_TIMEOUT")
    if [ -z "$resp" ]; then
        declare -f ui_err &>/dev/null && ui_err "MCP tool_call TIMEOUT: server=$server tool=$tool (${MCP_TIMEOUT}s)" >&2
        declare -f transcript_log &>/dev/null && transcript_log "mcp" "tool_call TIMEOUT: server=$server tool=$tool (${MCP_TIMEOUT}s)"
        return 1
    fi

    # Check for error
    local err
    err=$(printf '%s' "$resp" | _mcp_jq -r '.error.message // empty' 2>/dev/null)
    if [ -n "$err" ]; then
        local err_code
        err_code=$(printf '%s' "$resp" | _mcp_jq -r '.error.code // "unknown"' 2>/dev/null)
        echo "MCP ERROR: $err" >&2
        declare -f ui_err &>/dev/null && ui_err "MCP tool_call ERROR: server=$server tool=$tool code=$err_code msg=$err" >&2
        declare -f transcript_log &>/dev/null && transcript_log "mcp" "tool_call ERROR: server=$server tool=$tool code=$err_code msg=$err"
        return 1
    fi

    # Extract text content from result
    local content
    content=$(printf '%s' "$resp" | _mcp_jq -r '
        .result.content[]? |
        select(.type == "text") |
        .text
    ' 2>/dev/null)

    local _content_len=${#content}
    [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && ui_dim "  [debug] MCP tool_call OK: server=$server tool=$tool response_len=$_content_len" >&2
    declare -f transcript_log &>/dev/null && transcript_log "mcp" "tool_call OK: server=$server tool=$tool response_len=$_content_len"

    printf '%s' "$content"
}

# ── MCP Web Service Boundary ───────────────────────────────────
# All web operations route through MCP when available. Each wrapper
# tries the george-fetch MCP server first, falls back to external
# MCP servers, and returns 1 on failure so the caller can use its
# own direct implementation (curl, jq, etc.) as a last resort.
#
# Architecture: slash-command → web function → MCP wrapper → MCP server
#   /web fetch       → web_fetch()       → mcp_web_fetch()       → fetch_json / fetch
#   /web search      → web_search()      → mcp_web_search()      → web_search
#   /web images      → web_images()      → mcp_web_images()      → web_images
#   /web scrape-imgs → web_scrape_imgs() → mcp_web_fetch_json()  → fetch_json
#   /web fetch .pdf  → web_fetch()       → mcp_web_fetch_pdf()   → fetch_pdf
#   /github search   → web_search_github → mcp_github_search()   → github_search
#
# This boundary means:
#   - Swap george-fetch for a cloud service → zero changes to web.sh
#   - Add a new provider → add one MCP tool + update the wrapper
#   - External MCP clients get the same tools the agent uses

# ── Helper: try a tool across fetch-capable MCP servers ────────
# Usage: _mcp_try_fetch_tool "tool_name" '{"url":"..."}' ["fallback_tool" '{"url":"..."}']
# Returns 0+content on first success, 1 if all exhausted.
_mcp_try_fetch_tool() {
    local tool="$1"
    local args_json="$2"
    local fallback_tool="${3:-}"
    local fallback_args="${4:-}"

    local servers=("george-fetch" "fetch")
    local server result

    for server in "${servers[@]}"; do
        _mcp_server_exists "$server" || continue
        result=$(mcp_tool_call "$server" "$tool" "$args_json" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$result" ]; then
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
                ui_dim "  [debug] MCP $tool OK via $server (${#result} bytes)" >&2
            declare -f transcript_log &>/dev/null && \
                transcript_log "mcp" "$tool OK: $server (${#result} bytes)"
            printf '%s' "$result"
            return 0
        fi
    done

    # Try fallback tool if specified (e.g. fetch_json failed → try fetch)
    if [ -n "$fallback_tool" ]; then
        [ -z "$fallback_args" ] && fallback_args="$args_json"
        for server in "${servers[@]}"; do
            _mcp_server_exists "$server" || continue
            result=$(mcp_tool_call "$server" "$fallback_tool" "$fallback_args" 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$result" ]; then
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
                    ui_dim "  [debug] MCP $fallback_tool (fallback) OK via $server (${#result} bytes)" >&2
                declare -f transcript_log &>/dev/null && \
                    transcript_log "mcp" "$fallback_tool (fallback from $tool) OK: $server (${#result} bytes)"
                printf '%s' "$result"
                return 0
            fi
        done
    fi

    # Try puppeteer as last resort for plain fetch
    if [ "$tool" = "fetch" ] || [ "$tool" = "fetch_json" ]; then
        if _mcp_server_exists "puppeteer"; then
            result=$(mcp_tool_call "puppeteer" "puppeteer_navigate" "$args_json" 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$result" ]; then
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
                    ui_dim "  [debug] MCP puppeteer fallback OK (${#result} bytes)" >&2
                declare -f transcript_log &>/dev/null && \
                    transcript_log "mcp" "puppeteer fallback OK (${#result} bytes)"
                printf '%s' "$result"
                return 0
            fi
        fi
    fi

    return 1
}

# ── mcp_web_fetch: Structured-first URL fetching ──────────────
# Tries fetch_json first (semantic HTML extraction → title+content),
# extracts plain text from the JSON response. Falls back to plain
# fetch if structured extraction returns insufficient content (<80 chars).
mcp_web_fetch() {
    local url="$1"
    local _url_json
    _url_json=$(_mcp_jq -n -c --arg url "$url" '{"url":$url}')

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
        ui_dim "  [debug] MCP web_fetch: url=${url:0:120}" >&2

    # Try structured extraction first via fetch_json
    local json_result _sf_content _sf_title _sf_text _sf_blocked
    json_result=$(_mcp_try_fetch_tool "fetch_json" "$_url_json" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$json_result" ]; then
        # Parse structured fields from JSON response
        _sf_title=$(echo "$json_result" | _mcp_jq -r '.title // ""' 2>/dev/null)
        _sf_content=$(echo "$json_result" | _mcp_jq -r '.content // ""' 2>/dev/null)
        _sf_blocked=$(echo "$json_result" | _mcp_jq -r '.blocked // false' 2>/dev/null)

        if [ "$_sf_blocked" != "true" ] && [ -n "$_sf_content" ] && [ ${#_sf_content} -gt 80 ]; then
            [ -n "$_sf_title" ] && _sf_text="${_sf_title}"$'\n\n'"${_sf_content}" || _sf_text="$_sf_content"
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
                ui_dim "  [debug] MCP web_fetch: structured extraction succeeded (${#_sf_text} chars)" >&2
            declare -f transcript_log &>/dev/null && \
                transcript_log "mcp" "web_fetch structured OK: url=${url:0:80} (${#_sf_text} chars)"
            printf '%s' "$_sf_text"
            return 0
        fi
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
            ui_dim "  [debug] MCP web_fetch: structured extraction insufficient — trying plain fetch" >&2
    fi

    # Fall back to plain text fetch
    local result
    result=$(_mcp_try_fetch_tool "fetch" "$_url_json" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$result" ]; then
        printf '%s' "$result"
        return 0
    fi

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
        ui_dim "  [debug] MCP web_fetch: all servers exhausted — falling back to caller" >&2
    declare -f transcript_log &>/dev/null && \
        transcript_log "mcp" "web_fetch FALLBACK: no MCP server succeeded for url=${url:0:80}"
    return 1
}

# ── mcp_web_fetch_json: Structured JSON URL fetching ──────────
# Returns raw JSON from fetch_json tool (title, content, images, links).
# Used by web_fetch_json() and web_scrape_images().
mcp_web_fetch_json() {
    local url="$1"
    local _url_json
    _url_json=$(_mcp_jq -n -c --arg url "$url" '{"url":$url}')

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
        ui_dim "  [debug] MCP web_fetch_json: url=${url:0:120}" >&2

    _mcp_try_fetch_tool "fetch_json" "$_url_json"
}

# ── mcp_web_search: Web search via MCP ────────────────────────
# Routes through george-fetch web_search tool.
mcp_web_search() {
    local query="$1"
    local count="${2:-5}"
    local _args_json
    _args_json=$(_mcp_jq -n -c --arg q "$query" --argjson c "$count" '{"query":$q,"count":$c}')

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
        ui_dim "  [debug] MCP web_search: query=${query:0:80}" >&2

    _mcp_try_fetch_tool "web_search" "$_args_json"
}

# ── mcp_web_images: Image search via MCP ──────────────────────
# Routes through george-fetch web_images tool.
mcp_web_images() {
    local query="$1"
    local count="${2:-5}"
    local _args_json
    _args_json=$(_mcp_jq -n -c --arg q "$query" --argjson c "$count" '{"query":$q,"count":$c}')

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
        ui_dim "  [debug] MCP web_images: query=${query:0:80}" >&2

    _mcp_try_fetch_tool "web_images" "$_args_json"
}

# ── mcp_web_fetch_pdf: PDF extraction via MCP ─────────────────
# Routes through george-fetch fetch_pdf tool.
mcp_web_fetch_pdf() {
    local url="$1"
    local _url_json
    _url_json=$(_mcp_jq -n -c --arg url "$url" '{"url":$url}')

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
        ui_dim "  [debug] MCP web_fetch_pdf: url=${url:0:120}" >&2

    _mcp_try_fetch_tool "fetch_pdf" "$_url_json"
}

# ── mcp_github_search: GitHub repo search via MCP ─────────────
# Routes through george-fetch github_search tool.
mcp_github_search() {
    local query="$1"
    local count="${2:-5}"
    local _args_json
    _args_json=$(_mcp_jq -n -c --arg q "$query" --argjson c "$count" '{"query":$q,"count":$c}')

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
        ui_dim "  [debug] MCP github_search: query=${query:0:80}" >&2

    _mcp_try_fetch_tool "github_search" "$_args_json"
}

# ── Helper: try a tool on a specific MCP server ───────────────
# Usage: _mcp_try_server_tool "george-git" "git_status" '{"path":"."}'
# Returns 0+content on success, 1 if server missing or tool fails.
_mcp_try_server_tool() {
    local server="$1"
    local tool="$2"
    local args_json="$3"

    _mcp_server_exists "$server" || return 1

    local result
    result=$(mcp_tool_call "$server" "$tool" "$args_json" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$result" ]; then
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
            ui_dim "  [debug] MCP $tool OK via $server (${#result} bytes)" >&2
        declare -f transcript_log &>/dev/null && \
            transcript_log "mcp" "$tool OK: $server (${#result} bytes)"
        printf '%s' "$result"
        return 0
    fi
    return 1
}

# ═══════════════════════════════════════════════════════════════
# Git MCP Wrappers (george-git server)
# ═══════════════════════════════════════════════════════════════

mcp_git_status() {
    local path="${1:-.}"
    local _args
    _args=$(_mcp_jq -n -c --arg p "$path" '{"path":$p}')
    _mcp_try_server_tool "george-git" "git_status" "$_args"
}

mcp_git_log() {
    local count="${1:-10}"
    local path="${2:-.}"
    local _args
    _args=$(_mcp_jq -n -c --argjson c "$count" --arg p "$path" '{"count":$c,"path":$p}')
    _mcp_try_server_tool "george-git" "git_log" "$_args"
}

mcp_git_diff() {
    local path="${1:-.}"
    local staged="${2:-false}"
    local ref="${3:-}"
    local _args
    _args=$(_mcp_jq -n -c --arg p "$path" --arg s "$staged" --arg r "$ref" \
        '{path:$p} + (if $s == "true" then {staged:true} else {} end) + (if $r != "" then {ref:$r} else {} end)')
    _mcp_try_server_tool "george-git" "git_diff" "$_args"
}

mcp_git_commit() {
    local message="$1"
    local path="${2:-.}"
    local files="${3:-}"
    local _args
    _args=$(_mcp_jq -n -c --arg m "$message" --arg p "$path" --arg f "$files" \
        '{"message":$m,"path":$p} + (if $f != "" then {"files":$f} else {} end)')
    _mcp_try_server_tool "george-git" "git_commit" "$_args"
}

mcp_git_push() {
    local path="${1:-.}"
    local remote="${2:-origin}"
    local branch="${3:-}"
    local _args
    _args=$(_mcp_jq -n -c --arg p "$path" --arg r "$remote" --arg b "$branch" \
        '{"path":$p,"remote":$r} + (if $b != "" then {"branch":$b} else {} end)')
    _mcp_try_server_tool "george-git" "git_push" "$_args"
}

mcp_git_pull() {
    local path="${1:-.}"
    local remote="${2:-origin}"
    local _args
    _args=$(_mcp_jq -n -c --arg p "$path" --arg r "$remote" '{"path":$p,"remote":$r}')
    _mcp_try_server_tool "george-git" "git_pull" "$_args"
}

mcp_git_branch() {
    local path="${1:-.}"
    local name="${2:-}"
    local _args
    _args=$(_mcp_jq -n -c --arg p "$path" --arg n "$name" \
        '{"path":$p} + (if $n != "" then {"name":$n} else {} end)')
    _mcp_try_server_tool "george-git" "git_branch" "$_args"
}

mcp_git_clone() {
    local url="$1"
    local path="${2:-.}"
    local _args
    _args=$(_mcp_jq -n -c --arg u "$url" --arg p "$path" '{"url":$u,"path":$p}')
    _mcp_try_server_tool "george-git" "git_clone" "$_args"
}

# ═══════════════════════════════════════════════════════════════
# MQTT MCP Wrappers (george-mqtt server)
# ═══════════════════════════════════════════════════════════════

mcp_mqtt_publish() {
    local topic="$1"
    local message="$2"
    local qos="${3:-0}"
    local retain="${4:-false}"
    local _args
    _args=$(_mcp_jq -n -c --arg t "$topic" --arg m "$message" --argjson q "$qos" --arg r "$retain" \
        '{"topic":$t,"message":$m,"qos":$q} + (if $r == "true" then {"retain":true} else {} end)')
    _mcp_try_server_tool "george-mqtt" "mqtt_publish" "$_args"
}

mcp_mqtt_subscribe() {
    local topic="$1"
    local count="${2:-1}"
    local timeout="${3:-10}"
    local _args
    _args=$(_mcp_jq -n -c --arg t "$topic" --argjson c "$count" --argjson to "$timeout" \
        '{"topic":$t,"count":$c,"timeout":$to}')
    _mcp_try_server_tool "george-mqtt" "mqtt_subscribe" "$_args"
}

mcp_mqtt_status() {
    _mcp_try_server_tool "george-mqtt" "mqtt_status" '{}'
}

# ═══════════════════════════════════════════════════════════════
# X (Twitter) MCP Wrappers (george-x server)
# ═══════════════════════════════════════════════════════════════

mcp_x_post() {
    local text="$1"
    local _args
    _args=$(_mcp_jq -n -c --arg t "$text" '{"text":$t}')
    _mcp_try_server_tool "george-x" "x_post" "$_args"
}

mcp_x_timeline() {
    local count="${1:-10}"
    local _args
    _args=$(_mcp_jq -n -c --argjson c "$count" '{"count":$c}')
    _mcp_try_server_tool "george-x" "x_timeline" "$_args"
}

mcp_x_reply() {
    local tweet_id="$1"
    local text="$2"
    local _args
    _args=$(_mcp_jq -n -c --arg id "$tweet_id" --arg t "$text" '{"tweet_id":$id,"text":$t}')
    _mcp_try_server_tool "george-x" "x_reply" "$_args"
}

mcp_x_search() {
    local query="$1"
    local count="${2:-10}"
    local _args
    _args=$(_mcp_jq -n -c --arg q "$query" --argjson c "$count" '{"query":$q,"count":$c}')
    _mcp_try_server_tool "george-x" "x_search" "$_args"
}

mcp_x_delete() {
    local tweet_id="$1"
    local _args
    _args=$(_mcp_jq -n -c --arg id "$tweet_id" '{"tweet_id":$id}')
    _mcp_try_server_tool "george-x" "x_delete" "$_args"
}

# ── MCP Dispatch Intercept ─────────────────────────────────────
# When MCP is enabled, this function checks if an MCP server has
# a tool that matches the slash command. If so, calls it FIRST.
# Returns 0 on success (MCP handled it), 1 on failure/no match.

_mcp_dispatch_intercept() {
    local cmd="$1"
    local args="$2"

    mcp_enabled || return 1

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && ui_dim "  [debug] MCP dispatch intercept: cmd=$cmd args=${args:0:80}" >&2

    # Check cached tool mappings for all running servers
    local server_name
    for server_name in $(mcp_running_servers); do
        local tools_json
        tools_json=$(mcp_tools_list "$server_name" 2>/dev/null)
        [ -z "$tools_json" ] && continue

        # Search for a tool matching the command name
        local match
        match=$(printf '%s' "$tools_json" | _mcp_jq -r \
            --arg cmd "$cmd" \
            '.[] | select(.name == $cmd or .name == ("mcp_" + $cmd) or
                          .name == ($cmd + "_" + "fetch") or
                          (.name | ascii_downcase) == ($cmd | ascii_downcase)) |
             .name' 2>/dev/null | head -1)

        # Compound command matching: /git status → git_status, /github search → github_search
        local params=""
        if [ -z "$match" ] && [ -n "$args" ]; then
            local _subcmd _subrest
            _subcmd=$(echo "$args" | awk '{print $1}')
            _subrest=$(echo "$args" | sed 's/^[^ ]* *//')
            [ "$_subrest" = "$args" ] && _subrest=""

            if [ -n "$_subcmd" ]; then
                local _compound="${cmd}_${_subcmd}"
                match=$(printf '%s' "$tools_json" | _mcp_jq -r \
                    --arg compound "$_compound" \
                    '.[] | select((.name | ascii_downcase) == ($compound | ascii_downcase)) | .name' 2>/dev/null | head -1)

                # Alias: github_* → git_* (e.g. /github clone → git_clone)
                if [ -z "$match" ] && [ "$cmd" = "github" ]; then
                    local _alias_compound="git_${_subcmd}"
                    match=$(printf '%s' "$tools_json" | _mcp_jq -r \
                        --arg compound "$_alias_compound" \
                        '.[] | select((.name | ascii_downcase) == ($compound | ascii_downcase)) | .name' 2>/dev/null | head -1)
                fi

                if [ -n "$match" ]; then
                    # Map remaining args to the tool's first required parameter
                    local _req_param
                    _req_param=$(printf '%s' "$tools_json" | _mcp_jq -r \
                        --arg name "$match" \
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
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && ui_dim "  [debug] MCP dispatch: matched tool '$match' on server '$server_name'" >&2
            # Build params from args (pass as a generic "input" or "query" field)
            [ -z "$params" ] && params=$(_mcp_jq -n -c --arg input "$args" '{"input":$input}')
            local result
            result=$(mcp_tool_call "$server_name" "$match" "$params" 2>/dev/null)
            if [ -n "$result" ]; then
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && ui_dim "  [debug] MCP dispatch OK: server=$server_name tool=$match (${#result} bytes)" >&2
                declare -f transcript_log &>/dev/null && transcript_log "mcp" "dispatch intercept OK: server=$server_name tool=$match cmd=$cmd (${#result} bytes)"
                printf '%s' "$result"
                return 0
            fi
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && ui_dim "  [debug] MCP dispatch: tool '$match' returned empty on server '$server_name'" >&2
            declare -f transcript_log &>/dev/null && transcript_log "mcp" "dispatch intercept EMPTY: server=$server_name tool=$match cmd=$cmd"
        fi
    done

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && ui_dim "  [debug] MCP dispatch: no matching tool for cmd=$cmd — falling back to native" >&2
    return 1
}

# ── Agent Catalog: MCP Tools for LLM injection ────────────────
# Returns MCP tool info formatted for the agent strategist/specialist.
# When MCP is enabled, this supplements (or replaces) the regular
# command catalog depending on injection mode.

mcp_catalog() {
    mcp_enabled || return 1

    local catalog=""
    local server_name

    for server_name in $(mcp_server_names); do
        local desc
        desc=$(_mcp_server_desc "$server_name")
        local tools_json
        tools_json=$(mcp_tools_list "$server_name" 2>/dev/null)

        if [ -n "$tools_json" ] && [ "$tools_json" != "[]" ]; then
            local tool_summary
            tool_summary=$(printf '%s' "$tools_json" | _mcp_jq -r \
                '.[] | "    - " + .name + ": " + (.description // "no description")' 2>/dev/null)
            catalog="${catalog}MCP Server: ${server_name} — ${desc}\n  Tools:\n${tool_summary}\n\n"
        else
            catalog="${catalog}MCP Server: ${server_name} — ${desc} (no tools cached)\n\n"
        fi
    done

    if [ -n "$catalog" ]; then
        printf 'MCP INTEGRATION (ENABLED)\nUse /mcp call <server> <tool> <json_params> to invoke MCP tools.\nAvailable servers and tools:\n\n%b' "$catalog"
    fi
}

# ── Find which server has a specific tool ──────────────────────
mcp_find_tool() {
    local tool_name="$1"
    local server_name

    for server_name in $(mcp_server_names); do
        local tools_json
        tools_json=$(mcp_tools_list "$server_name" 2>/dev/null)
        [ -z "$tools_json" ] && continue

        local found
        found=$(printf '%s' "$tools_json" | _mcp_jq -r \
            --arg t "$tool_name" \
            '.[] | select(.name == $t) | .name' 2>/dev/null)
        if [ -n "$found" ]; then
            echo "$server_name"
            return 0
        fi
    done

    return 1
}

# ── Default Server Catalog ─────────────────────────────────────
# Recommended MCP servers that users can install with /mcp install <name>.
# Format: name|command|description

_mcp_write_default_catalog() {
    mkdir -p "$MCP_CONFIG_DIR"
    cat > "$MCP_CATALOG_FILE" << CATALOG
# George MCP Server Catalog — recommended servers
# Format: name|command|description
# Install with: /mcp install <name>
george-fetch|bash $LODGE_DIR/lib/mcp_server_fetch.sh|Built-in web fetch (pure bash, no Node.js)
george-git|bash $LODGE_DIR/lib/mcp_server_git.sh|Built-in git & GitHub operations (pure bash, no Node.js)
george-x|bash $LODGE_DIR/lib/mcp_server_x.sh|Built-in X/Twitter integration (pure bash, no Node.js)
fetch|npx -y @anthropic/mcp-server-fetch|Web content fetching (enhanced scraping)
puppeteer|npx -y @anthropic/mcp-server-puppeteer|Browser automation for JS-rendered pages
brave-search|npx -y @anthropic/mcp-server-brave-search|Web search via Brave API (needs BRAVE_API_KEY)
github|npx -y @anthropic/mcp-server-github|GitHub operations (needs GITHUB_TOKEN)
filesystem|npx -y @anthropic/mcp-server-filesystem .|Local filesystem access (scoped to current dir)
sqlite|npx -y @anthropic/mcp-server-sqlite|SQLite database queries
memory|npx -y @anthropic/mcp-server-memory|Knowledge graph memory
everything|npx -y @anthropic/mcp-server-everything|Testing/demo server (all tool types)
CATALOG
}

mcp_catalog_list() {
    [ -f "$MCP_CATALOG_FILE" ] || _mcp_write_default_catalog
    grep -v '^#' "$MCP_CATALOG_FILE" 2>/dev/null | grep -v '^$'
}

mcp_catalog_install() {
    local catalog_name="$1"
    local entry
    entry=$(mcp_catalog_list | grep "^${catalog_name}|" | head -1)

    if [ -z "$entry" ]; then
        echo "ERROR: '$catalog_name' not found in MCP catalog" >&2
        echo "Available: $(mcp_catalog_list | cut -d'|' -f1 | tr '\n' ' ')" >&2
        return 1
    fi

    local cmd desc
    cmd=$(echo "$entry" | cut -d'|' -f2)
    desc=$(echo "$entry" | cut -d'|' -f3)

    mcp_server_add "$catalog_name" "$cmd" "$desc"
}

# ── /mcp Command Menu ─────────────────────────────────────────
mcp_command() {
    local args="$1"
    local action
    action=$(echo "$args" | awk '{print $1}')
    local rest
    rest=$(echo "$args" | sed 's/^[^ ]* *//')

    case "$action" in
        ""|status)
            _mcp_show_status
            ;;
        on|enable)
            MCP_ENABLED=1
            mcp_init
            # Auto-start all registered servers
            if mcp_has_servers; then
                local _started_any=0
                local _sname
                while IFS= read -r _sname; do
                    [ -z "$_sname" ] && continue
                    if mcp_status "$_sname" >/dev/null 2>&1; then
                        continue
                    fi
                    declare -f ui_dim &>/dev/null && ui_dim "  Starting MCP server '$_sname'..." >&2
                    if mcp_start "$_sname" 2>/dev/null; then
                        declare -f ui_ok &>/dev/null && ui_ok "MCP server '$_sname' started"
                        _started_any=1
                    else
                        declare -f ui_warn &>/dev/null && ui_warn "MCP server '$_sname' failed to start" >&2
                    fi
                done <<< "$(mcp_server_names)"
            fi
            # Persist setting
            declare -f _llm_save_config &>/dev/null && _llm_save_config 2>/dev/null
            if declare -f ui_ok &>/dev/null; then
                ui_ok "MCP integration enabled"
            else
                echo "MCP integration enabled"
            fi
            ;;
        off|disable)
            MCP_ENABLED=0
            mcp_stop_all
            # Persist setting
            declare -f _llm_save_config &>/dev/null && _llm_save_config 2>/dev/null
            if declare -f ui_ok &>/dev/null; then
                ui_ok "MCP integration disabled"
            else
                echo "MCP integration disabled"
            fi
            ;;
        add|register)
            local name cmd_str desc_str
            name=$(echo "$rest" | awk '{print $1}')
            cmd_str=$(echo "$rest" | awk '{$1=""; print}' | sed 's/^ *//')
            # Interactive mode when args are missing
            if [ -z "$name" ] || [ -z "$cmd_str" ]; then
                declare -f ui_section &>/dev/null && ui_section "Register MCP Server"
                printf "  Server name (alphanumeric, hyphens, underscores): "
                read -r name
                [ -z "$name" ] && { echo "Cancelled — no name given" >&2; return 1; }
                printf "  Command to start the server: "
                read -r cmd_str
                [ -z "$cmd_str" ] && { echo "Cancelled — no command given" >&2; return 1; }
                printf "  Description [MCP server: %s]: " "$name"
                read -r desc_str
                [ -z "$desc_str" ] && desc_str="MCP server: $name"
            else
                desc_str="MCP server: $name"
            fi
            mcp_init 2>/dev/null
            mcp_server_add "$name" "$cmd_str" "$desc_str"
            if [ $? -eq 0 ]; then
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
            local name
            name=$(echo "$rest" | awk '{print $1}')
            [ -z "$name" ] && { echo "Usage: /mcp remove <name>" >&2; return 1; }
            mcp_server_remove "$name"
            if declare -f ui_ok &>/dev/null; then
                ui_ok "MCP server '$name' removed"
            else
                echo "MCP server '$name' removed"
            fi
            ;;
        list)
            _mcp_show_servers
            ;;
        catalog)
            _mcp_show_catalog
            ;;
        install)
            local catalog_name
            catalog_name=$(echo "$rest" | awk '{print $1}')
            [ -z "$catalog_name" ] && { _mcp_show_catalog; return 0; }
            mcp_catalog_install "$catalog_name"
            if [ $? -eq 0 ] && declare -f ui_ok &>/dev/null; then
                ui_ok "Installed '$catalog_name' from catalog"
            fi
            ;;
        start)
            local name
            name=$(echo "$rest" | awk '{print $1}')
            [ -z "$name" ] && { echo "Usage: /mcp start <name>" >&2; return 1; }
            MCP_ENABLED=1
            if declare -f ui_dim &>/dev/null; then
                ui_dim "Starting MCP server '$name'..." >&2
            fi
            if mcp_start "$name"; then
                if declare -f ui_ok &>/dev/null; then
                    ui_ok "MCP server '$name' started and ready"
                else
                    echo "MCP server '$name' started"
                fi
            else
                if declare -f ui_err &>/dev/null; then
                    ui_err "Failed to start MCP server '$name'" >&2
                    local stderr_file="$MCP_RUN_DIR/$name/stderr.log"
                    if [ -f "$stderr_file" ] && [ -s "$stderr_file" ]; then
                        ui_dim "Server stderr:" >&2
                        tail -5 "$stderr_file" | while IFS= read -r line; do
                            ui_dim "  $line" >&2
                        done
                    fi
                fi
                return 1
            fi
            ;;
        stop)
            local name
            name=$(echo "$rest" | awk '{print $1}')
            if [ -z "$name" ] || [ "$name" = "all" ]; then
                mcp_stop_all
                if declare -f ui_ok &>/dev/null; then
                    ui_ok "All MCP servers stopped"
                else
                    echo "All MCP servers stopped"
                fi
            else
                mcp_stop "$name"
                if declare -f ui_ok &>/dev/null; then
                    ui_ok "MCP server '$name' stopped"
                else
                    echo "MCP server '$name' stopped"
                fi
            fi
            ;;
        tools)
            local name
            name=$(echo "$rest" | awk '{print $1}')
            if [ -z "$name" ]; then
                # Show tools for all servers
                local server_name
                for server_name in $(mcp_server_names); do
                    echo "=== $server_name ==="
                    local tools
                    tools=$(mcp_tools_list "$server_name" 2>/dev/null)
                    if [ -n "$tools" ] && [ "$tools" != "[]" ]; then
                        printf '%s' "$tools" | _mcp_jq -r '.[] | "  " + .name + " — " + (.description // "")' 2>/dev/null
                    else
                        echo "  (no tools or server not started)"
                    fi
                    echo ""
                done
            else
                local tools
                tools=$(mcp_tools_list "$name" 2>/dev/null)
                if [ -n "$tools" ] && [ "$tools" != "[]" ]; then
                    printf '%s' "$tools" | _mcp_jq -r '.[] | .name + " — " + (.description // "")' 2>/dev/null
                else
                    echo "No tools found (is '$name' registered and running?)" >&2
                fi
            fi
            ;;
        call)
            local server tool params_json
            server=$(echo "$rest" | awk '{print $1}')
            tool=$(echo "$rest" | awk '{print $2}')
            params_json=$(echo "$rest" | awk '{$1=""; $2=""; print}' | sed 's/^ *//')
            [ -z "$params_json" ] && params_json='{}'

            if [ -z "$server" ] || [ -z "$tool" ]; then
                echo "Usage: /mcp call <server> <tool> [params_json]" >&2
                return 1
            fi

            MCP_ENABLED=1
            local result
            result=$(mcp_tool_call "$server" "$tool" "$params_json" 2>/dev/null)
            if [ -n "$result" ]; then
                echo "$result"
            else
                echo "MCP call failed: $server / $tool" >&2
                return 1
            fi
            ;;
        cache)
            local subaction
            subaction=$(echo "$rest" | awk '{print $1}')
            case "$subaction" in
                clear)
                    if declare -f cache_invalidate_ns &>/dev/null; then
                        cache_invalidate_ns "$MCP_CACHE_NS"
                        if declare -f ui_ok &>/dev/null; then
                            ui_ok "MCP tool cache cleared"
                        else
                            echo "MCP tool cache cleared"
                        fi
                    fi
                    ;;
                *)
                    if declare -f cache_stats &>/dev/null; then
                        echo "MCP Cache: $(cache_stats)"
                    fi
                    ;;
            esac
            ;;
        help|*)
            _mcp_show_help
            ;;
    esac
}

# ── Display Helpers ────────────────────────────────────────────

_mcp_show_status() {
    local _ui_section="echo"
    local _ui_dim="echo"
    local _ui_info="echo"
    declare -f ui_section &>/dev/null && _ui_section="ui_section"
    declare -f ui_dim &>/dev/null && _ui_dim="ui_dim"
    declare -f ui_info &>/dev/null && _ui_info="ui_info"

    $_ui_section "MCP Integration"
    echo ""

    local status_label="DISABLED"
    if mcp_enabled; then
        status_label="ENABLED"
    fi
    $_ui_info "Status: $status_label"

    # Running servers
    local running
    running=$(mcp_running_servers)
    if [ -n "$running" ]; then
        $_ui_info "Running servers:"
        for name in $running; do
            local desc
            desc=$(_mcp_server_desc "$name")
            $_ui_dim "  ● $name — ${desc:-MCP server}" >&2
        done
    else
        $_ui_dim "No servers running" >&2
    fi

    # Registered servers
    local total
    total=$(mcp_server_names | wc -l)
    total="${total## }"
    $_ui_dim "Registered: ${total:-0} servers" >&2

    # Cache stats
    if declare -f cache_stats &>/dev/null; then
        $_ui_dim "Tool cache: $(cache_stats)" >&2
    fi

    echo ""
    $_ui_dim "  /mcp on|off     — Enable/disable MCP" >&2
    $_ui_dim "  /mcp list       — Show registered servers" >&2
    $_ui_dim "  /mcp catalog    — Browse recommended servers" >&2
    $_ui_dim "  /mcp help       — Full command reference" >&2
}

_mcp_show_servers() {
    local _ui_section="echo"
    local _ui_dim="echo"
    declare -f ui_section &>/dev/null && _ui_section="ui_section"
    declare -f ui_dim &>/dev/null && _ui_dim="ui_dim"

    $_ui_section "Registered MCP Servers"
    echo ""

    local entries
    entries=$(mcp_server_list)
    if [ -z "$entries" ]; then
        $_ui_dim "No servers registered. Try: /mcp install fetch" >&2
        return
    fi

    while IFS='|' read -r name cmd desc; do
        [ -z "$name" ] && continue
        local state="○"
        if mcp_status "$name" >/dev/null 2>&1; then
            state="●"
        fi
        printf "  %s %-15s %s\n" "$state" "$name" "${desc:-}"
        $_ui_dim "    cmd: $cmd" >&2
    done <<< "$entries"

    echo ""
    $_ui_dim "  ● = running, ○ = stopped" >&2
}

_mcp_show_catalog() {
    local _ui_section="echo"
    local _ui_dim="echo"
    declare -f ui_section &>/dev/null && _ui_section="ui_section"
    declare -f ui_dim &>/dev/null && _ui_dim="ui_dim"

    $_ui_section "MCP Server Catalog"
    echo ""

    local entries
    entries=$(mcp_catalog_list)
    if [ -z "$entries" ]; then
        $_ui_dim "No catalog available" >&2
        return
    fi

    while IFS='|' read -r name cmd desc; do
        [ -z "$name" ] && continue
        local installed=""
        if _mcp_server_exists "$name"; then
            installed=" [installed]"
        fi
        printf "  %-15s %s%s\n" "$name" "${desc:-}" "$installed"
    done <<< "$entries"

    echo ""
    $_ui_dim "  Install: /mcp install <name>" >&2
    $_ui_dim "  Then:    /mcp start <name>" >&2
}

_mcp_show_help() {
    local _ui_section="echo"
    local _ui_dim="echo"
    declare -f ui_section &>/dev/null && _ui_section="ui_section"
    declare -f ui_dim &>/dev/null && _ui_dim="ui_dim"

    $_ui_section "MCP Commands"
    echo ""
    $_ui_dim "  /mcp                         Show status overview" >&2
    $_ui_dim "  /mcp on | off                Enable/disable MCP integration" >&2
    $_ui_dim "  /mcp add [name] [command]    Register a server (interactive if no args)" >&2
    $_ui_dim "  /mcp register               Interactive server registration" >&2
    $_ui_dim "  /mcp remove <name>           Unregister a server" >&2
    $_ui_dim "  /mcp list                    List registered servers" >&2
    $_ui_dim "  /mcp catalog                 Browse recommended servers" >&2
    $_ui_dim "  /mcp install <name>          Install from catalog" >&2
    $_ui_dim "  /mcp start <name>            Start a server" >&2
    $_ui_dim "  /mcp stop [name|all]         Stop server(s)" >&2
    $_ui_dim "  /mcp tools [name]            List available tools" >&2
    $_ui_dim "  /mcp call <srv> <tool> [{}]  Call an MCP tool" >&2
    $_ui_dim "  /mcp cache [clear]           View/clear tool cache" >&2
    $_ui_dim "  /mcp help                    This help" >&2
    echo ""
    $_ui_dim "  When MCP is enabled, George uses MCP tools as the primary" >&2
    $_ui_dim "  path and falls back to native slash commands on failure." >&2
}

# ── Cleanup hook ───────────────────────────────────────────────
_mcp_cleanup() {
    mcp_stop_all 2>/dev/null
    rm -rf "$MCP_RUN_DIR" 2>/dev/null
}
