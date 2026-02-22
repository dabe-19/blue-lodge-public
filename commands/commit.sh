#!/bin/bash
# DESC: Smart git commit with AI-generated message
# Usage: /commit [files...]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/llm.sh"

cmd_commit() {
    local args="$1"
    local workdir="${2:-.}"
    
    cd "$workdir"
    
    # Check for changes
    local diff
    diff=$(git diff --stat HEAD 2>/dev/null)
    local staged
    staged=$(git diff --cached --stat 2>/dev/null)
    
    if [ -z "$diff" ] && [ -z "$staged" ]; then
        ui_warn "No changes to commit"
        return 0
    fi
    
    # Stage files
    if [ -n "$args" ]; then
        git add -- $args 2>&1
    else
        ui_info "Staging all changes..."
        git add -A 2>&1
    fi
    
    # Get diff for commit message generation
    local changes
    changes=$(git diff --cached --stat 2>/dev/null)
    local detailed_diff
    detailed_diff=$(git diff --cached --no-color 2>/dev/null | head -200)
    
    ui_section "Changes"
    echo "$changes"
    echo ""
    
    # Generate commit message
    ui_spinner_start "Generating commit message"
    local msg
    msg=$(llm_generate "Generate a concise git commit message (conventional commits format) for these changes. Output ONLY the message, nothing else. Max 72 chars for first line.

Changes:
$changes

Diff (truncated):
$detailed_diff")
    ui_spinner_stop
    
    # Clean up the message
    msg=$(echo "$msg" | head -5 | sed 's/^["`'"'"']//;s/["`'"'"']$//')
    
    ui_info "Suggested: $msg"
    if ui_confirm "Use this message?"; then
        git commit -m "$msg" 2>&1
        ui_ok "Committed!"
    else
        printf " Enter message: "
        read -r custom_msg
        git commit -m "$custom_msg" 2>&1
        ui_ok "Committed with custom message"
    fi
}
