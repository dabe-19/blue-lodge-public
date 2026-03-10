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

# ── Dependency check ───────────────────────────────────────────
_MCP_JQ_CMD=""
if command -v jq >/dev/null 2>&1; then
    _MCP_JQ_CMD="jq"
elif command -v gojq >/dev/null 2>&1; then
    _MCP_JQ_CMD="gojq"
fi

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
    [ "${MCP_ENABLED:-0}" -eq 1 ] && [ -n "$_MCP_JQ_CMD" ]
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

    if [ -z "$_MCP_JQ_CMD" ]; then
        echo "ERROR: MCP requires jq or gojq" >&2
        return 1
    fi

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

    # Start server: reads from FIFO stdin, appends stdout to regular file
    # eval handles commands with arguments like "npx -y @anthropic/server-fetch"
    eval "$cmd" < "$rundir/in.fifo" >> "$rundir/responses.jsonl" 2>"$rundir/stderr.log" &
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
        mcp_stop "$name"
        return 1
    fi

    # MCP handshake
    if ! _mcp_handshake "$name"; then
        echo "ERROR: MCP handshake failed for '$name'" >&2
        mcp_stop "$name"
        return 1
    fi

    touch "$rundir/ready"
    return 0
}

mcp_stop() {
    local name="$1"
    local rundir="$MCP_RUN_DIR/$name"

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
        return 1
    fi

    local tools
    tools=$(printf '%s' "$resp" | _mcp_jq -r '.result.tools // []' 2>/dev/null)
    if [ -z "$tools" ] || [ "$tools" = "null" ]; then
        tools="[]"
    fi

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

    # Ensure server is running
    mcp_status "$server" >/dev/null 2>&1 || {
        mcp_start "$server" || return 1
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
        return 1
    fi

    # Check for error
    local err
    err=$(printf '%s' "$resp" | _mcp_jq -r '.error.message // empty' 2>/dev/null)
    if [ -n "$err" ]; then
        echo "MCP ERROR: $err" >&2
        return 1
    fi

    # Extract text content from result
    local content
    content=$(printf '%s' "$resp" | _mcp_jq -r '
        .result.content[]? |
        select(.type == "text") |
        .text
    ' 2>/dev/null)

    printf '%s' "$content"
}

# ── MCP Web Fetch (fallback/priority for web.sh) ──────────────
# Tries MCP fetch servers for a URL. Called by web.sh when:
#   - MCP enabled → try MCP first (primary path)
#   - curl fails → try MCP as fallback

mcp_web_fetch() {
    local url="$1"

    # Try built-in george-fetch server first (pure bash, no Node.js)
    if _mcp_server_exists "george-fetch"; then
        local result
        result=$(mcp_tool_call "george-fetch" "fetch" "$(_mcp_jq -n -c --arg url "$url" '{"url":$url}')" 2>/dev/null)
        if [ -n "$result" ]; then
            printf '%s' "$result"
            return 0
        fi
    fi

    # Try external "fetch" server (e.g. @anthropic/mcp-server-fetch)
    if _mcp_server_exists "fetch"; then
        local result
        result=$(mcp_tool_call "fetch" "fetch" "$(_mcp_jq -n -c --arg url "$url" '{"url":$url}')" 2>/dev/null)
        if [ -n "$result" ]; then
            printf '%s' "$result"
            return 0
        fi
    fi

    # Try "puppeteer" server for JS-rendered content
    if _mcp_server_exists "puppeteer"; then
        local result
        result=$(mcp_tool_call "puppeteer" "puppeteer_navigate" "$(_mcp_jq -n -c --arg url "$url" '{"url":$url}')" 2>/dev/null)
        if [ -n "$result" ]; then
            printf '%s' "$result"
            return 0
        fi
    fi

    return 1
}

# ── MCP Dispatch Intercept ─────────────────────────────────────
# When MCP is enabled, this function checks if an MCP server has
# a tool that matches the slash command. If so, calls it FIRST.
# Returns 0 on success (MCP handled it), 1 on failure/no match.

_mcp_dispatch_intercept() {
    local cmd="$1"
    local args="$2"

    mcp_enabled || return 1

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

        if [ -n "$match" ]; then
            # Build params from args (pass as a generic "input" or "query" field)
            local params
            params=$(_mcp_jq -n -c --arg input "$args" '{"input":$input}')
            local result
            result=$(mcp_tool_call "$server_name" "$match" "$params" 2>/dev/null)
            if [ -n "$result" ]; then
                printf '%s' "$result"
                return 0
            fi
        fi
    done

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
            if declare -f ui_ok &>/dev/null; then
                ui_ok "MCP integration enabled"
            else
                echo "MCP integration enabled"
            fi
            ;;
        off|disable)
            MCP_ENABLED=0
            mcp_stop_all
            if declare -f ui_ok &>/dev/null; then
                ui_ok "MCP integration disabled"
            else
                echo "MCP integration disabled"
            fi
            ;;
        add)
            local name cmd_str desc_str
            name=$(echo "$rest" | awk '{print $1}')
            cmd_str=$(echo "$rest" | awk '{$1=""; print}' | sed 's/^ *//')
            if [ -z "$name" ] || [ -z "$cmd_str" ]; then
                echo "Usage: /mcp add <name> <command>" >&2
                return 1
            fi
            desc_str="MCP server: $name"
            mcp_server_add "$name" "$cmd_str" "$desc_str"
            if declare -f ui_ok &>/dev/null; then
                ui_ok "MCP server '$name' registered"
            else
                echo "MCP server '$name' registered"
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
                ui_dim "Starting MCP server '$name'..."
            fi
            if mcp_start "$name"; then
                if declare -f ui_ok &>/dev/null; then
                    ui_ok "MCP server '$name' started and ready"
                else
                    echo "MCP server '$name' started"
                fi
            else
                if declare -f ui_err &>/dev/null; then
                    ui_err "Failed to start MCP server '$name'"
                    local stderr_file="$MCP_RUN_DIR/$name/stderr.log"
                    if [ -f "$stderr_file" ] && [ -s "$stderr_file" ]; then
                        ui_dim "Server stderr:"
                        tail -5 "$stderr_file" | while IFS= read -r line; do
                            ui_dim "  $line"
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
    elif [ "${MCP_ENABLED:-0}" -eq 1 ] && [ -z "$_MCP_JQ_CMD" ]; then
        status_label="ENABLED (but jq missing — install jq to activate)"
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
            $_ui_dim "  ● $name — ${desc:-MCP server}"
        done
    else
        $_ui_dim "No servers running"
    fi

    # Registered servers
    local total
    total=$(mcp_server_names | wc -l)
    total="${total## }"
    $_ui_dim "Registered: ${total:-0} servers"

    # Cache stats
    if declare -f cache_stats &>/dev/null; then
        $_ui_dim "Tool cache: $(cache_stats)"
    fi

    echo ""
    $_ui_dim "  /mcp on|off     — Enable/disable MCP"
    $_ui_dim "  /mcp list       — Show registered servers"
    $_ui_dim "  /mcp catalog    — Browse recommended servers"
    $_ui_dim "  /mcp help       — Full command reference"
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
        $_ui_dim "No servers registered. Try: /mcp install fetch"
        return
    fi

    while IFS='|' read -r name cmd desc; do
        [ -z "$name" ] && continue
        local state="○"
        if mcp_status "$name" >/dev/null 2>&1; then
            state="●"
        fi
        printf "  %s %-15s %s\n" "$state" "$name" "${desc:-}"
        $_ui_dim "    cmd: $cmd"
    done <<< "$entries"

    echo ""
    $_ui_dim "  ● = running, ○ = stopped"
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
        $_ui_dim "No catalog available"
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
    $_ui_dim "  Install: /mcp install <name>"
    $_ui_dim "  Then:    /mcp start <name>"
}

_mcp_show_help() {
    local _ui_section="echo"
    local _ui_dim="echo"
    declare -f ui_section &>/dev/null && _ui_section="ui_section"
    declare -f ui_dim &>/dev/null && _ui_dim="ui_dim"

    $_ui_section "MCP Commands"
    echo ""
    $_ui_dim "  /mcp                         Show status overview"
    $_ui_dim "  /mcp on | off                Enable/disable MCP integration"
    $_ui_dim "  /mcp add <name> <command>    Register a custom server"
    $_ui_dim "  /mcp remove <name>           Unregister a server"
    $_ui_dim "  /mcp list                    List registered servers"
    $_ui_dim "  /mcp catalog                 Browse recommended servers"
    $_ui_dim "  /mcp install <name>          Install from catalog"
    $_ui_dim "  /mcp start <name>            Start a server"
    $_ui_dim "  /mcp stop [name|all]         Stop server(s)"
    $_ui_dim "  /mcp tools [name]            List available tools"
    $_ui_dim "  /mcp call <srv> <tool> [{}]  Call an MCP tool"
    $_ui_dim "  /mcp cache [clear]           View/clear tool cache"
    $_ui_dim "  /mcp help                    This help"
    echo ""
    $_ui_dim "  When MCP is enabled, George uses MCP tools as the primary"
    $_ui_dim "  path and falls back to native slash commands on failure."
}

# ── Cleanup hook ───────────────────────────────────────────────
_mcp_cleanup() {
    mcp_stop_all 2>/dev/null
    rm -rf "$MCP_RUN_DIR" 2>/dev/null
}
