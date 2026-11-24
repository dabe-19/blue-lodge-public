#!/bin/bash
# ── George Slash Command: /workflow ───────────────────────────────────
# DESC: Inspect and run Lodge agent workflows (.agents/workflows & ALP v1 *.loop.json)
# USAGE: /workflow [list | run <name> [args] | show <name> | loops [owner] | show-loop <owner>/<id> | run-loop <owner>/<id> [params_json] | validate-loop <file>]

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agents/workflows.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/loop_engine.sh" 2>/dev/null || true

cmd_workflow() {
    local args="$1"
    local workdir="${2:-$PWD}"

    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}" # trim leading whitespace

    case "$subcmd" in
        list|"")
            workflows_print_list "$workdir"
            if declare -f loop_list &>/dev/null; then
                echo ""
                ui_section "Declarative Agentic Loops (ALP v1 — Heartwood & Modules)"
                loop_list | jq -r '.loops[] | "  [\(.owner)] \(.id) — \(.name) (\(.enabled_phase_count)/\(.phase_count) phases, FIFO:\(.fifo_phases), max_turns:\(.max_turns)\(if .has_override then ", OVERRIDE" else "" end))"' 2>/dev/null || true
                ui_dim "Run /workflow run-loop <owner>/<id> [params_json] or edit in the Web UI Loop Studio."
            fi
            ;;
        loops)
            ui_section "Declarative Agentic Loops (ALP v1)"
            loop_list "$rest" | jq -r '.loops[] | "  [\(.owner)] \(.id) — \(.name) (\(.enabled_phase_count)/\(.phase_count) phases, FIFO:\(.fifo_phases), max_turns:\(.max_turns)\(if .has_override then ", OVERRIDE" else "" end))"'
            ;;
        show-loop)
            local spec="$rest"
            if [[ "$spec" != */* ]]; then
                ui_err "Usage: /workflow show-loop <owner>/<loop_id> (e.g. heartwood/deep-research or poshtracker/visual_comps_finder)"
                return 1
            fi
            loop_resolve_json "${spec%%/*}" "${spec#*/}" | jq '.loop'
            ;;
        validate-loop)
            [ -z "$rest" ] && { ui_err "Usage: /workflow validate-loop <path/to/file.loop.json>"; return 1; }
            loop_validate "$rest"
            ;;
        run-loop)
            local spec="${rest%% *}"
            local pjson="${rest#"$spec"}"
            pjson="${pjson#"${pjson%%[![:space:]]*}"}"
            if [[ "$spec" != */* ]]; then
                ui_err "Usage: /workflow run-loop <owner>/<loop_id> [params_json]"
                return 1
            fi
            local l_owner="${spec%%/*}" l_id="${spec#*/}"
            local ts sbox pfile
            ts=$(date +%s)
            sbox="$LODGE_DIR/.sandboxes/loop_${l_owner//-/_}_${l_id//-/_}_${ts}"
            mkdir -p "$sbox/inputs"
            pfile="$sbox/inputs/params.json"
            if [ -n "$pjson" ]; then
                printf '%s\n' "$pjson" > "$pfile"
            else
                printf '{}\n' > "$pfile"
            fi
            loop_run "$l_owner" "$l_id" "$sbox" "$pfile"
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
                ui_dim "Usage: /workflow [list | run <name> [args] | show <name> | loops [owner] | show-loop <owner>/<id> | run-loop <owner>/<id>]"
                return 1
            fi
            ;;
    esac
}
