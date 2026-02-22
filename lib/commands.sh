#!/bin/bash
# ── Blue Lodge: Slash Command Dispatcher ───────────────────────
# Registers and dispatches /commands similar to Claude Code.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
LODGE_COMMANDS_DIR="$LODGE_DIR/commands"

# ── Registry ───────────────────────────────────────────────────
declare -A CMD_REGISTRY
declare -A CMD_DESC

commands_register() {
    local name="$1"
    local desc="$2"
    local handler="$3"
    CMD_REGISTRY["$name"]="$handler"
    CMD_DESC["$name"]="$desc"
}

# ── Dispatch ───────────────────────────────────────────────────
commands_dispatch() {
    local input="$1"
    local workdir="${2:-.}"
    
    # Parse: /command [args...]
    local cmd
    cmd=$(echo "$input" | awk '{print $1}' | sed 's|^/||')
    local args
    args=$(echo "$input" | sed 's|^/[^ ]* *||')
    
    # Check built-in commands first
    case "$cmd" in
        help)     commands_help; return 0 ;;
        quit|exit|q) return 99 ;;
    esac
    
    # Check registry
    if [ -n "${CMD_REGISTRY[$cmd]}" ]; then
        "${CMD_REGISTRY[$cmd]}" "$args" "$workdir"
        return $?
    fi
    
    # Check commands directory for scripts
    local script="$LODGE_COMMANDS_DIR/${cmd}.sh"
    if [ -f "$script" ]; then
        source "$script"
        "cmd_${cmd}" "$args" "$workdir"
        return $?
    fi
    
    return 1  # Not a command
}

# ── Is this a slash command? ───────────────────────────────────
commands_is_command() {
    local input="$1"
    [[ "$input" == /* ]]
}

# ── Show help ──────────────────────────────────────────────────
commands_help() {
    source "$LODGE_DIR/lib/ui.sh"
    
    ui_section "Slash Commands"
    
    # Built-in
    printf "  %b/help%b       Show this help\n" "$C_CYAN" "$C_RESET"
    printf "  %b/quit%b       Exit Blue Lodge\n" "$C_CYAN" "$C_RESET"
    echo ""
    
    # Registered
    for name in $(echo "${!CMD_REGISTRY[@]}" | tr ' ' '\n' | sort); do
        printf "  %b/%-10s%b %s\n" "$C_CYAN" "$name" "$C_RESET" "${CMD_DESC[$name]}"
    done
    
    # Script-based
    if [ -d "$LODGE_COMMANDS_DIR" ]; then
        for script in "$LODGE_COMMANDS_DIR"/*.sh; do
            [ -f "$script" ] || continue
            local name
            name=$(basename "$script" .sh)
            if [ -z "${CMD_REGISTRY[$name]}" ]; then
                local desc
                desc=$(head -3 "$script" | grep '# DESC:' | sed 's/.*DESC: *//')
                printf "  %b/%-10s%b %s\n" "$C_CYAN" "$name" "$C_RESET" "${desc:-Custom command}"
            fi
        done
    fi
    echo ""
}

# ── Load all command scripts ───────────────────────────────────
commands_load_all() {
    if [ ! -d "$LODGE_COMMANDS_DIR" ]; then return; fi
    
    for script in "$LODGE_COMMANDS_DIR"/*.sh; do
        [ -f "$script" ] || continue
        source "$script"
    done
}
