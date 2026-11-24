#!/bin/bash
# DESC: Ask the operator a clarifying question
# Usage: /ask <question>

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true

cmd_ask() {
    local question="$1"
    local arg2="${2:-}"

    if [ -z "$question" ]; then
        ui_err "Usage: /ask <question> | /ask timeout [seconds]"
        ui_info "Asks the human operator a question in Discord or the REPL."
        return 1
    fi

    if [ "$question" = "timeout" ]; then
        if [ -n "$arg2" ] && [[ "$arg2" =~ ^[0-9]+$ ]]; then
            local cfg_dir="${GEORGE_DIR:-${LODGE_DIR:-$HOME/blue-lodge}/.george}"
            mkdir -p "$cfg_dir" 2>/dev/null || true
            echo "$arg2" > "$cfg_dir/ask_timeout"
            export ASK_OPERATOR_TIMEOUT="$arg2"
            ui_ok "Operator question timeout updated to ${arg2}s"
            return 0
        else
            local cur; cur=$(get_ask_operator_timeout)
            ui_info "Current operator question timeout: ${cur}s"
            ui_dim "To change: /ask timeout <seconds>"
            return 0
        fi
    fi

    ui_ask_operator "$question"
}

_cmd_ask() {
    cmd_ask "$@"
}

