#!/bin/bash
# DESC: Push to GitHub (current branch)
# Usage: /push [branch]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

cmd_push() {
    local branch="${1:-}"
    local workdir="${2:-.}"
    
    cd "$workdir"
    
    if [ -z "$branch" ]; then
        branch=$(git branch --show-current 2>/dev/null)
    fi
    
    if [ -z "$branch" ]; then
        ui_err "Not a git repo or no branch detected"
        return 1
    fi
    
    ui_step "Pushing to origin/$branch..."
    git push origin "$branch" 2>&1
    
    if [ $? -eq 0 ]; then
        ui_ok "Pushed to origin/$branch"
    else
        ui_err "Push failed"
        return 1
    fi
}
