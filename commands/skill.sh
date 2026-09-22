#!/bin/bash
# ── George Slash Command: /skill ─────────────────────────────────────
# DESC: Inspect, load, or run skills (.agents/skills)
# USAGE: /skill [list | load <name> | run <name> [args] | show <name>]

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/skills.sh" 2>/dev/null || true

cmd_skill() {
    local args="$1"
    local workdir="${2:-$PWD}"

    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        list|"")
            skills_print_list "$workdir"
            ;;
        load)
            local sname="$rest"
            [ -z "$sname" ] && { ui_err "Usage: /skill load <name>"; return 1; }
            skills_load "$sname" "$workdir"
            ;;
        show)
            local sname="$rest"
            [ -z "$sname" ] && { ui_err "Usage: /skill show <name>"; return 1; }
            local f
            f=$(skills_get_file "$sname" "$workdir")
            if [ -n "$f" ] && [ -f "$f" ]; then
                ui_section "Skill: $sname ($f)"
                cat "$f"
                echo ""
            else
                ui_err "Skill '$sname' not found."
                return 1
            fi
            ;;
        run)
            local sname="${rest%% *}"
            local sargs="${rest#"$sname"}"
            sargs="${sargs#"${sargs%%[![:space:]]*}"}"
            [ -z "$sname" ] && { ui_err "Usage: /skill run <name> [args]"; return 1; }
            local norm
            norm=$(skills_normalize_name "$sname")
            if [ "$norm" = "grill-me" ] || [ "$norm" = "grill-with-docs" ]; then
                skills_run_grill_me "$sargs" "$workdir"
            else
                skills_load "$sname" "$workdir"
            fi
            ;;
        *)
            if skills_get_file "$subcmd" "$workdir" &>/dev/null; then
                local norm
                norm=$(skills_normalize_name "$subcmd")
                if [ "$norm" = "grill-me" ] || [ "$norm" = "grill-with-docs" ]; then
                    skills_run_grill_me "$rest" "$workdir"
                else
                    skills_load "$subcmd" "$workdir"
                fi
            else
                ui_err "Unknown /skill action: $subcmd"
                ui_dim "Usage: /skill [list | load <name> | run <name> [args] | show <name>]"
                return 1
            fi
            ;;
    esac
}
