#!/bin/bash
# DESC: Proxy slash commands and prompts from a worker REPL to the Master node over MQTT JSON-RPC
# Usage: /remote-master <command_or_prompt>

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agents/swarm.sh" 2>/dev/null || true

cmd_remote_master() {
    local cmd="$1"
    if [ -z "$cmd" ]; then
        ui_err "Usage: /remote-master <command_or_prompt>"
        ui_dim "Example: /remote-master /endpoints"
        ui_dim "Example: /remote-master /status"
        return 1
    fi

    swarm_remote_exec "$cmd"
}

_cmd_remote_master() {
    cmd_remote_master "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_remote_master "$*"
fi
