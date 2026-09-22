#!/bin/bash
# DESC: Manage Model Context Protocol (MCP) servers and tools
# Usage: /mcp [list|catalog|install <id>|start <name>|stop <name>|call <server> <tool> <json_args>|on|off]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mcp.sh" 2>/dev/null || true

cmd_mcp() {
    local args="$1"
    local workdir="${2:-.}"

    if ! declare -f mcp_command &>/dev/null; then
        echo "ERROR: lib/mcp.sh could not be loaded." >&2
        return 1
    fi

    mcp_command "$args"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_mcp "$*"
fi
