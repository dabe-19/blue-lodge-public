#!/bin/bash
# DESC: Fast conversational chat loop with safe read-only tools
# Usage: /chat <message>

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true

cmd_chat() {
    local message="$1"
    local workdir="${2:-.}"

    if [ -z "$message" ]; then
        ui_err "Usage: /chat <message>"
        ui_info "Runs a lightweight, multi-turn conversational chat with George."
        return 1
    fi

    bash "$LODGE_DIR/lib/core/chat_loop.sh" "$message"
}

_cmd_chat() {
    cmd_chat "$@"
}
