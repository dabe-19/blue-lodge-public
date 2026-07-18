#!/bin/bash
# DESC: Run project tests
# Usage: /test [specific_test]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/memory.sh"

cmd_test() {
    local args="$1"
    local workdir="${2:-.}"
    
    # Default to task workspace if active, unless it has no project file but parent does
    if [ -n "${AGENT_OUTPUT_DIR:-}" ] && [ -d "$workdir/$AGENT_OUTPUT_DIR" ]; then
        local has_project_file=0
        local f
        for f in Cargo.toml pyproject.toml Makefile package.json go.mod src/main.rs src/lib.rs src; do
            ( [ -f "$workdir/$AGENT_OUTPUT_DIR/$f" ] || [ -d "$workdir/$AGENT_OUTPUT_DIR/$f" ] ) && has_project_file=1
        done
        if [ $has_project_file -eq 0 ]; then
            local test_cmd_check
            test_cmd_check=$(memory_get_section "Build" "$workdir/$AGENT_OUTPUT_DIR" | grep '^test:' | sed 's/^test:[[:space:]]*//' | head -1)
            [ -n "$test_cmd_check" ] && [[ "$test_cmd_check" != "N/A" ]] && has_project_file=1
        fi
        if [ $has_project_file -eq 1 ]; then
            workdir="$workdir/$AGENT_OUTPUT_DIR"
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Routing test to active task workspace: $workdir"
        fi
    fi
    
    cd "$workdir"
    
    # Get test command from GEORGE.md or detect
    local test_cmd
    # Read test command from ## Build section (key:value format)
    test_cmd=$(memory_get_section "Build" "$workdir" | grep '^test:' | sed 's/^test:[[:space:]]*//' | head -1)
    # Filter out placeholder values
    [[ "$test_cmd" == "N/A" ]] && test_cmd=""
    
    if [ -z "$test_cmd" ]; then
        # Auto-detect
        if [ -f "Cargo.toml" ]; then
            test_cmd="cargo test"
        elif [ -f "pyproject.toml" ]; then
            test_cmd="uv run pytest"
        elif [ -f "package.json" ]; then
            test_cmd="npm test"
        elif [ -f "Makefile" ]; then
            test_cmd="make test"
        else
            ui_err "Can't detect test command. Add it to GEORGE.md under ## Build"
            return 1
        fi
    fi
    
    # Append specific test if given
    if [ -n "$args" ]; then
        test_cmd="$test_cmd $args"
    fi
    
    ui_step "Running: $test_cmd"
    echo ""
    bash -c "$test_cmd" 2>&1
    local exit_code=$?
    
    echo ""
    if [ $exit_code -eq 0 ]; then
        ui_ok "Tests passed"
    else
        ui_err "Tests failed (exit $exit_code)"
        memory_append_section "Context Files" "tests failed: exit $exit_code" "$workdir"
    fi
    
    return $exit_code
}
