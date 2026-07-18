#!/bin/bash
# DESC: Build the project
# Usage: /build [release]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/memory.sh"

cmd_build() {
    local target_dir=""
    # Default to task workspace if active, unless it has no project file but parent does
    if [ -n "${AGENT_OUTPUT_DIR:-}" ] && [ -d "$workdir/$AGENT_OUTPUT_DIR" ]; then
        local has_project_file=0
        local f
        for f in Cargo.toml pyproject.toml Makefile package.json go.mod src/main.rs src/lib.rs src; do
            ( [ -f "$workdir/$AGENT_OUTPUT_DIR/$f" ] || [ -d "$workdir/$AGENT_OUTPUT_DIR/$f" ] ) && has_project_file=1
        done
        if [ $has_project_file -eq 0 ]; then
            local build_cmd_check
            build_cmd_check=$(memory_get_section "Build" "$workdir/$AGENT_OUTPUT_DIR" | grep '^build:' | sed 's/^build:[[:space:]]*//' | head -1)
            [ -n "$build_cmd_check" ] && [[ "$build_cmd_check" != "N/A" ]] && has_project_file=1
        fi
        if [ $has_project_file -eq 1 ]; then
            target_dir="$workdir/$AGENT_OUTPUT_DIR"
        fi
    fi

    # Auto-detect project subdirectory from arguments (directory or file path)
    if [ -n "$args" ]; then
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
    fi

    if [ -n "$target_dir" ]; then
        workdir="$target_dir"
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Auto-detected project subdirectory: $workdir"
    fi

    cd "$workdir"
    
    local build_cmd
    # Read build command from ## Build section (key:value format)
    build_cmd=$(memory_get_section "Build" "$workdir" | grep '^build:' | sed 's/^build:[[:space:]]*//' | head -1)
    # Filter out placeholder values
    [[ "$build_cmd" == "N/A" ]] && build_cmd=""
    
    if [ -z "$build_cmd" ]; then
        local has_local_project=0
        local f
        for f in Cargo.toml pyproject.toml Makefile package.json go.mod; do
            [ -f "$f" ] && has_local_project=1
        done
        if [ -d "src" ] || [ -f "GEORGE.md" ]; then
            has_local_project=1
        fi
        if [ $has_local_project -eq 0 ]; then
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
    fi
    
    if [ -z "$build_cmd" ]; then
        if [ ! -f "Cargo.toml" ] && [ -f "src/main.rs" ]; then
            ui_warn "Cargo.toml not found, but src/main.rs exists. Auto-generating a fallback Cargo.toml..."
            cat << 'EOF' > Cargo.toml
[package]
name = "rust-microservice"
version = "0.1.0"
edition = "2021"

[dependencies]
tokio = { version = "1", features = ["full"] }
reqwest = { version = "0.11", features = ["json"] }
serde = { version = "1.0", features = ["derive"] }
EOF
        fi

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
