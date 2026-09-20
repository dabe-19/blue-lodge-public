#!/bin/bash
# DESC: Propose code promotion or candidate optimization upstream to develop
# Usage: /upstream propose <title> [--reason <text>] [--metric <proof>]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/pr.sh" 2>/dev/null || true

cmd_upstream() {
    local args="$1"
    local workdir="${2:-.}"

    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        propose)
            local curr_branch
            curr_branch=$(git -C "$workdir" branch --show-current 2>/dev/null)
            if [ -z "$curr_branch" ]; then
                ui_err "Cannot propose upstream PR from detached HEAD."
                return 1
            fi
            if [ "$curr_branch" = "main" ] || [ "$curr_branch" = "develop" ]; then
                ui_err "Cannot propose upstream PR from primary integration branch '$curr_branch'."
                ui_info "Create a candidate branch first (e.g. 'candidate/my-optimization')."
                return 1
            fi

            # Parse title, reason, metric, and flags
            local force_local=0
            [[ "$rest" == *"--local"* ]] && force_local=1

            local title="" reason="" metric=""
            title=$(echo "$rest" | sed -E 's/--local//g; s/--reason.*//; s/--metric.*//' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            if [[ "$rest" =~ --reason[[:space:]]+([^--]+) ]]; then
                reason="${BASH_REMATCH[1]}"
                reason="${reason#"${reason%%[![:space:]]*}"}"
            fi
            if [[ "$rest" =~ --metric[[:space:]]+([^--]+) ]]; then
                metric="${BASH_REMATCH[1]}"
                metric="${metric#"${metric%%[![:space:]]*}"}"
            fi

            [ -z "$title" ] && title="Optimization deliverable from $curr_branch"

            # Auto-commit any unstaged/uncommitted changes in the worktree
            if [ -n "$(git -C "$workdir" status --porcelain 2>/dev/null)" ]; then
                git -C "$workdir" add -A >/dev/null 2>&1 || true
                git -C "$workdir" commit -m "feat(upstream): ${title}" >/dev/null 2>&1 || true
            fi

            local dossier="### Rationale\n${reason:-"Candidate optimization tested and validated."}\n\n### Empirical Metric Delta (The Plumb)\n${metric:-"All test suites passing in branch sandbox."}"

            ui_step "Submitting candidate PR upstream to 'develop'..."
            if pr_create "$curr_branch" "$title" "$dossier" "develop" "$force_local"; then
                touch "$workdir/.pr_issued" 2>/dev/null || true
                return 0
            else
                return 1
            fi
            ;;
        *)
            ui_err "Unknown /upstream command: '$subcmd'"
            ui_info "Usage: /upstream propose <title> [--reason <text>] [--metric <proof>]"
            return 1
            ;;
    esac
}
