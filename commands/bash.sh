#!/bin/bash
# DESC: Execute shell command in workspace
# Usage: /bash <command...>

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

cmd_bash() {
    local cmd_str="$1"
    local workdir="${2:-.}"

    if [ -z "$cmd_str" ]; then
        ui_err "Usage: /bash <command...>"
        return 1
    fi

    (
        cd "$workdir" || exit 1
        export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$LODGE_DIR:$PATH"
        # Run command with 30s timeout if timeout command exists
        if command -v timeout &>/dev/null; then
            timeout 30s bash -c "$cmd_str"
        else
            bash -c "$cmd_str"
        fi
    )
    return $?
}

# Alias /sh to /bash
cmd_sh() {
    cmd_bash "$@"
}
