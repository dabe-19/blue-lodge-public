#!/bin/bash
# ── George: /remote-master Command ───────────────────────────────────
# Proxies slash commands and prompts from a worker REPL directly to the
# Master node over MQTT JSON-RPC, rendering live output stream in real time.

source "${LODGE_DIR:-$HOME/blue-lodge}/lib/swarm.sh" 2>/dev/null || true

_cmd_remote_master() {
    local cmd="$1"
    if [ -z "$cmd" ]; then
        ui_err "Usage: /remote-master <command_or_prompt>"
        ui_dim "Example: /remote-master /endpoints"
        ui_dim "Example: /remote-master /status"
        return 1
    fi

    swarm_remote_exec "$cmd"
}
