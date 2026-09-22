#!/bin/bash
# ── George Slash Command: /workflow ───────────────────────────────────
# DESC: Inspect and run Lodge agent workflows (.agents/workflows)
# USAGE: /workflow [list | run <name> [args] | show <name>]

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/workflows.sh" 2>/dev/null || true

cmd_workflow() {
    local args="$1"
    local workdir="${2:-$PWD}"

    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}" # trim leading whitespace

    case "$subcmd" in
        list|"")
            workflows_print_list "$workdir"
            ;;
        show)
            local wf_name="$rest"
            [ -z "$wf_name" ] && { ui_err "Usage: /workflow show <name>"; return 1; }
            local f
            f=$(workflows_get_file "$wf_name" "$workdir")
            if [ -n "$f" ] && [ -f "$f" ]; then
                ui_section "Workflow: $wf_name ($f)"
                cat "$f"
                echo ""
            else
                ui_err "Workflow '$wf_name' not found."
                return 1
            fi
            ;;
        run)
            local wf_name="${rest%% *}"
            local wf_args="${rest#"$wf_name"}"
            wf_args="${wf_args#"${wf_args%%[![:space:]]*}"}"
            [ -z "$wf_name" ] && { ui_err "Usage: /workflow run <name> [args]"; return 1; }
            workflows_run "$wf_name" "$wf_args" "$workdir"
            ;;
        *)
            # If subcmd itself is a valid workflow name, run it directly!
            if workflows_get_file "$subcmd" "$workdir" &>/dev/null; then
                workflows_run "$subcmd" "$rest" "$workdir"
            else
                ui_err "Unknown /workflow action: $subcmd"
                ui_dim "Usage: /workflow [list | run <name> [args] | show <name>]"
                return 1
            fi
            ;;
    esac
}
