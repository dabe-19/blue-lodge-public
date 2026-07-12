#!/bin/bash
# DESC: Build the project
# Usage: /build [release]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/memory.sh"

cmd_build() {
    local args="$1"
    local workdir="${2:-.}"
    
    cd "$workdir"
    
    local build_cmd
    # Read build command from ## Build section (key:value format)
    build_cmd=$(memory_get_section "Build" "$workdir" | grep '^build:' | sed 's/^build:[[:space:]]*//' | head -1)
    # Filter out placeholder values
    [[ "$build_cmd" == "N/A" ]] && build_cmd=""
    
    if [ -z "$build_cmd" ]; then
        if [ -f "Cargo.toml" ]; then
            build_cmd="cargo build"
        elif [ -f "pyproject.toml" ]; then
            build_cmd="uv run python main.py"
        elif [ -f "Makefile" ]; then
            build_cmd="make"
        else
            ui_err "Can't detect build command. Add it to GEORGE.md under ## Build"
            return 1
        fi
    fi
    
    # Release flag
    if [[ "$args" == *"release"* ]] && [[ "$build_cmd" == *"cargo"* ]]; then
        build_cmd="$build_cmd --release"
    fi

    # Concrete task redirection: run the agent-generated version if it exists
    if [[ "$build_cmd" == *"main.sh"* ]] && [ -f "responses/system_shield/main.sh" ]; then
        build_cmd="bash responses/system_shield/main.sh"
    elif [[ "$build_cmd" == *"main.sh"* ]] && [ -f "responses/main.sh" ]; then
        build_cmd="bash responses/main.sh"
    fi
    
    ui_step "Running: $build_cmd"
    echo ""
    bash -c "$build_cmd" 2>&1
    local exit_code=$?
    
    echo ""
    if [ $exit_code -eq 0 ]; then
        ui_ok "Build succeeded"
    else
        ui_err "Build failed (exit $exit_code)"
    fi
    
    return $exit_code
}
