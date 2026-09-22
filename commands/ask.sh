#!/bin/bash
# DESC: Ask the operator a clarifying question
# Usage: /ask <question>

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true

cmd_ask() {
    local question="$1"
    local workdir="${2:-.}"

    if [ -z "$question" ]; then
        ui_err "Usage: /ask <question>"
        ui_info "Asks the human operator a question in the REPL via /dev/tty."
        return 1
    fi

    ui_ask_operator "$question"
}

_cmd_ask() {
    cmd_ask "$@"
}
