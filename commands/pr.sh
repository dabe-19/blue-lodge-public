#!/bin/bash
# DESC: Manage and audit pull requests and code promotions (GitFlow: target 'develop')
# Usage: /pr [list|show|diff|audit|accept|reject|create] [args...]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/pr.sh" 2>/dev/null || true

cmd_pr() {
    local args="$1"
    local workdir="${2:-.}"

    pr_init

    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        ""|list)
            pr_list
            ;;
        show)
            local target_id="${rest%% *}"
            if [ -z "$target_id" ]; then
                ui_err "Usage: /pr show <PR_ID>"
                return 1
            fi
            pr_show "$target_id"
            ;;
        diff)
            local target_id="${rest%% *}"
            local opt="${rest#"$target_id"}"
            opt="${opt#"${opt%%[![:space:]]*}"}"
            if [ -z "$target_id" ]; then
                ui_err "Usage: /pr diff <PR_ID> [--stat]"
                return 1
            fi
            local stat_only=false
            [[ "$opt" == *"--stat"* ]] && stat_only=true
            pr_diff "$target_id" "$stat_only"
            ;;
        audit)
            local target_id="${rest%% *}"
            if [ -z "$target_id" ]; then
                ui_err "Usage: /pr audit <PR_ID>"
                return 1
            fi
            pr_audit "$target_id"
            ;;
        accept|merge)
            local target_id="${rest%% *}"
            local strat="${rest#"$target_id"}"
            strat="${strat#"${strat%%[![:space:]]*}"}"
            strat="${strat:-merge}"
            if [ -z "$target_id" ]; then
                ui_err "Usage: /pr accept <PR_ID> [merge|squash]"
                return 1
            fi
            pr_accept "$target_id" "$strat"
            ;;
        reject)
            local target_id="${rest%% *}"
            local reason="${rest#"$target_id"}"
            reason="${reason#"${reason%%[![:space:]]*}"}"
            reason="${reason:-Rejected by operator}"
            if [ -z "$target_id" ]; then
                ui_err "Usage: /pr reject <PR_ID> [reason]"
                return 1
            fi
            pr_reject "$target_id" "$reason"
            ;;
        create)
            local src="${rest%% *}"
            local remaining="${rest#"$src"}"
            remaining="${remaining#"${remaining%%[![:space:]]*}"}"
            local title="$remaining"
            if [ -z "$src" ] || [ -z "$title" ]; then
                ui_err "Usage: /pr create <source_branch> <title...>"
                return 1
            fi
            pr_create "$src" "$title" "Manual PR creation via /pr create" "develop"
            ;;
        *)
            ui_err "Unknown /pr command: '$subcmd'"
            ui_info "Available subcommands: list, show <id>, diff <id>, audit <id>, accept <id>, reject <id>, create <branch> <title>"
            return 1
            ;;
    esac
}
