#!/bin/bash
# DESC: Diagnose and fix errors in the project
# Usage: /fix [file_or_description]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/llm.sh"
source "$LODGE_DIR/lib/memory.sh"
source "$LODGE_DIR/lib/agent.sh"

cmd_fix() {
    local args="$1"
    local workdir="${2:-.}"
    
    cd "$workdir"
    
    local error_context=""
    
    # Try to detect project type and get errors
    if [ -f "Cargo.toml" ]; then
        ui_step "Running cargo check..."
        error_context=$(cargo check 2>&1 || true)
    elif [ -f "pyproject.toml" ]; then
        if command -v uv &>/dev/null; then
            ui_step "Running Python check..."
            error_context=$(uv run python -m py_compile main.py 2>&1 || true)
        fi
    fi
    
    # If user specified something, include it
    if [ -n "$args" ]; then
        if [ -f "$args" ]; then
            error_context="$error_context

File contents ($args):
$(head -100 "$args")"
        else
            error_context="$error_context

User described error: $args"
        fi
    fi
    
    if [ -z "$error_context" ]; then
        ui_warn "No errors detected. Describe the problem after /fix"
        return 0
    fi
    
    # Show errors
    ui_section "Errors Found"
    echo "$error_context" | head -30
    echo ""
    
    # Run agent to fix
    agent_run "Fix these errors. Apply minimal changes only.

ERRORS:
$error_context" "$workdir"
}
