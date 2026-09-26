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

    # Normalize hallucinated directory paths dynamically (portable across systems)
    local target_ws="${LODGE_DIR:-$HOME/blue-lodge}"
    cmd_str=$(echo "$cmd_str" | sed -E "s#(cd[[:space:]]+)?(/home/[^/]+|/Users/[^/]+|~|\$HOME)/blue[ _-][a-zA-Z0-9_-]*#\1${target_ws}#g")

    (
        cd "$workdir" || exit 1
        export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$LODGE_DIR:$PATH"
        if command -v timeout &>/dev/null; then
            timeout 30s bash -c "source '$LODGE_DIR/lib/mcp_server_gitea.sh' 2>/dev/null || true; $cmd_str"
        else
            bash -c "source '$LODGE_DIR/lib/mcp_server_gitea.sh' 2>/dev/null || true; $cmd_str"
        fi
    )
    return $?
}

# Alias /sh to /bash
cmd_sh() {
    cmd_bash "$@"
}
