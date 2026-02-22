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
    build_cmd=$(memory_get_section "Build" "$workdir" | head -1 | sed 's/^`//;s/`$//')
    
    if [ -z "$build_cmd" ]; then
        if [ -f "Cargo.toml" ]; then
            build_cmd="cargo build"
        elif [ -f "pyproject.toml" ]; then
            build_cmd="uv run python main.py"
        elif [ -f "Makefile" ]; then
            build_cmd="make"
        else
            ui_err "Can't detect build command. Add it to CLAUDE.md under ## Build"
            return 1
        fi
    fi
    
    # Release flag
    if [[ "$args" == *"release"* ]] && [[ "$build_cmd" == *"cargo"* ]]; then
        build_cmd="$build_cmd --release"
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
