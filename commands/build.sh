#!/bin/bash
# DESC: Build the project
# Usage: /build [release]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/memory.sh"

cmd_build() {
    # Auto-detect project subdirectory from arguments (directory or file path)
    if [ -n "$args" ]; then
        local target_dir=""
        if [ -d "$workdir/$args" ]; then
            target_dir="$workdir/$args"
            args=""
        else
            local parent_dir
            parent_dir=$(dirname "$args")
            if [ "$parent_dir" != "." ] && [ -d "$workdir/$parent_dir" ]; then
                target_dir="$workdir/$parent_dir"
            fi
        fi
        if [ -n "$target_dir" ]; then
            workdir="$target_dir"
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Auto-detected project subdirectory from args: $workdir"
        fi
    fi

    cd "$workdir"
    
    local build_cmd
    # Read build command from ## Build section (key:value format)
    build_cmd=$(memory_get_section "Build" "$workdir" | grep '^build:' | sed 's/^build:[[:space:]]*//' | head -1)
    # Filter out placeholder values
    [[ "$build_cmd" == "N/A" ]] && build_cmd=""
    
    if [ -z "$build_cmd" ]; then
        # Search subdirectories for GEORGE.md containing a Build section
        local sub_george
        sub_george=$(find "$workdir" -mindepth 2 -maxdepth 3 -name "GEORGE.md" 2>/dev/null | grep -v "/\.george/" | head -1)
        if [ -n "$sub_george" ]; then
            local sub_dir
            sub_dir=$(dirname "$sub_george")
            if [ "$sub_dir" != "$workdir" ]; then
                workdir="$sub_dir"
                cd "$workdir"
                build_cmd=$(memory_get_section "Build" "$workdir" | grep '^build:' | sed 's/^build:[[:space:]]*//' | head -1)
                [[ "$build_cmd" == "N/A" ]] && build_cmd=""
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Auto-detected project subdirectory via GEORGE.md: $workdir"
            fi
        fi
    fi
    
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
    if [[ "$build_cmd" == *"main.sh"* ]] && [ -f "${LODGE_DIR}/responses/system_shield/main.sh" ]; then
        build_cmd="bash ${LODGE_DIR}/responses/system_shield/main.sh"
    elif [[ "$build_cmd" == *"main.sh"* ]] && [ -f "${LODGE_DIR}/responses/main.sh" ]; then
        build_cmd="bash ${LODGE_DIR}/responses/main.sh"
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
