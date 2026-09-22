#!/bin/bash
# DESC: View and configure George swarm limits, timeouts, and remediation levers
# Usage: /limits [set <KEY> <VALUE>|reset|get <KEY>]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/limits.sh" 2>/dev/null || true

cmd_limits() {
    local args="$1"
    local workdir="${2:-.}"

    limits_init

    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        ""|list|show)
            limits_list
            ;;
        set)
            local key="${rest%% *}"
            local val="${rest#"$key"}"
            val="${val#"${val%%[![:space:]]*}"}"
            if [ -z "$key" ] || [ -z "$val" ]; then
                ui_err "Usage: /limits set <KEY> <VALUE>"
                return 1
            fi
            limits_set "$key" "$val"
            ;;
        get)
            local key="${rest%% *}"
            if [ -z "$key" ]; then
                ui_err "Usage: /limits get <KEY>"
                return 1
            fi
            limits_get "$key"
            ;;
        reset)
            limits_reset
            ;;
        *)
            ui_err "Unknown /limits subcommand: '$subcmd'"
            ui_info "Usage: /limits [set <KEY> <VALUE>|reset|get <KEY>]"
            return 1
            ;;
    esac
}
