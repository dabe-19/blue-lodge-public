#!/bin/bash
# ── George Slash Command: /rules ─────────────────────────────────────
# DESC: Inspect workspace rules and instructions (.agents/rules)
# USAGE: /rules [list | show <name>]

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/rules.sh" 2>/dev/null || true

cmd_rules() {
    local args="$1"
    local workdir="${2:-$PWD}"

    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        list|"")
            rules_print_list "$workdir"
            ;;
        show)
            local rname="$rest"
            [ -z "$rname" ] && { ui_err "Usage: /rules show <name>"; return 1; }
            local f
            f=$(rules_get_file "$rname" "$workdir")
            if [ -n "$f" ] && [ -f "$f" ]; then
                ui_section "Rule: $rname ($f)"
                cat "$f"
                echo ""
            else
                ui_err "Rule '$rname' not found."
                return 1
            fi
            ;;
        *)
            if rules_get_file "$subcmd" "$workdir" &>/dev/null; then
                local f
                f=$(rules_get_file "$subcmd" "$workdir")
                ui_section "Rule: $subcmd ($f)"
                cat "$f"
                echo ""
            else
                ui_err "Unknown /rules action: $subcmd"
                ui_dim "Usage: /rules [list | show <name>]"
                return 1
            fi
            ;;
    esac
}
