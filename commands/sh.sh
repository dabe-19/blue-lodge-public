#!/bin/bash
# DESC: Execute shell command in workspace (alias for /bash)
# Usage: /sh <command...>

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/commands/bash.sh"

cmd_sh() {
    cmd_bash "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_sh "$@"
fi
