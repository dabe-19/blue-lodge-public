#!/bin/bash
# DESC: Run project tests
# Usage: /test [specific_test]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/memory.sh"

cmd_test() {
    local args="$1"
    local workdir="${2:-.}"
    
    # 1. Path Resolution for $args using ui_resolve_path if available
    local target_file=""
    if [ -n "$args" ]; then
        if declare -f ui_resolve_path &>/dev/null; then
            target_file=$(ui_resolve_path "$args" "$workdir")
        elif [ -f "$workdir/$args" ]; then
            target_file="$workdir/$args"
        elif [ -n "${AGENT_OUTPUT_DIR:-}" ] && [ -f "$workdir/$AGENT_OUTPUT_DIR/$args" ]; then
            target_file="$workdir/$AGENT_OUTPUT_DIR/$args"
        fi
    fi

    # 2. Default to task workspace if active, or if target_file is inside task workspace
    if [ -n "${AGENT_OUTPUT_DIR:-}" ] && [ -d "$workdir/$AGENT_OUTPUT_DIR" ]; then
        local has_project_file=0
        local f
        for f in Cargo.toml pyproject.toml Makefile package.json go.mod src/main.rs src/lib.rs src; do
            ( [ -f "$workdir/$AGENT_OUTPUT_DIR/$f" ] || [ -d "$workdir/$AGENT_OUTPUT_DIR/$f" ] ) && has_project_file=1
        done
        if [ $has_project_file -eq 0 ]; then
            # Check for standalone source/test files in task workspace (.py, .rs, .sh, .js)
            local script_count
            script_count=$(find "$workdir/$AGENT_OUTPUT_DIR" -maxdepth 2 \( -name "*.py" -o -name "*.rs" -o -name "*.sh" -o -name "*.js" \) 2>/dev/null | wc -l)
            [ "${script_count:-0}" -gt 0 ] && has_project_file=1
        fi
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
    
    # Re-verify target_file relative to workdir after cd
    if [ -n "$target_file" ] && [ -f "$(basename "$target_file")" ]; then
        target_file="$(basename "$target_file")"
    elif [ -n "$args" ] && [ -f "$args" ]; then
        target_file="$args"
    elif [ -n "$args" ] && [ -f "$(basename "$args")" ]; then
        target_file="$(basename "$args")"
    fi

    # 3. Read test command from GEORGE.md or detect
    local test_cmd
    test_cmd=$(memory_get_section "Build" "$workdir" | grep '^test:' | sed 's/^test:[[:space:]]*//' | head -1)
    [[ "$test_cmd" == "N/A" ]] && test_cmd=""
    
    if [ -z "$test_cmd" ]; then
        # Auto-detect from project manifests first
        if [ -f "Cargo.toml" ]; then
            test_cmd="cargo test"
        elif [ -f "pyproject.toml" ]; then
            test_cmd="uv run pytest"
        elif [ -f "package.json" ]; then
            test_cmd="npm test"
        elif [ -f "Makefile" ]; then
            test_cmd="make test"
        else
            # Standalone file / script runner auto-detection
            local eval_file="${target_file:-$args}"
            local test_sibling=""
            if [ -n "$eval_file" ]; then
                local base_name
                base_name=$(basename "$eval_file" | sed 's/\.py$//')
                test_sibling=$(find . -maxdepth 2 \( -name "test_${base_name}.py" -o -name "${base_name}_test.py" \) 2>/dev/null | head -1)
            fi
            if [ -z "$test_sibling" ]; then
                test_sibling=$(find . -maxdepth 2 \( -name "test_*.py" -o -name "*_test.py" \) 2>/dev/null | head -1)
            fi
            if [ -n "$test_sibling" ]; then
                eval_file="$test_sibling"
                target_file="$test_sibling"
            elif [ -z "$eval_file" ]; then
                eval_file=$(find . -maxdepth 2 \( -name "*.py" -o -name "*.rs" -o -name "*.sh" \) 2>/dev/null | head -1)
                target_file="$eval_file"
            fi

            if [[ "$eval_file" == *.py ]]; then
                if command -v pytest &>/dev/null; then
                    test_cmd="pytest"
                elif command -v python3 &>/dev/null; then
                    if grep -q 'unittest' "$eval_file" 2>/dev/null; then
                        test_cmd="python3 -m unittest"
                    else
                        test_cmd="python3"
                    fi
                fi
            elif [[ "$eval_file" == *.sh ]]; then
                if command -v bash &>/dev/null; then
                    test_cmd="bash"
                fi
            elif [[ "$eval_file" == *.rs ]]; then
                if command -v cargo &>/dev/null; then
                    test_cmd="cargo test"
                elif command -v rustc &>/dev/null; then
                    test_cmd="rustc --test"
                fi
            elif [[ "$eval_file" == *.js ]] || [[ "$eval_file" == *.ts ]]; then
                if command -v node &>/dev/null; then
                    test_cmd="node"
                fi
            fi
        fi
    fi

    if [ -z "$test_cmd" ]; then
        ui_err "Can't detect test command for workspace or target file '$args'. Add it to GEORGE.md under ## Build"
        return 1
    fi

    # Auto-save detected test command to GEORGE.md if not already set
    if declare -f memory_update_section &>/dev/null && [ -f "$workdir/GEORGE.md" ]; then
        local current_build_sec
        current_build_sec=$(memory_get_section "Build" "$workdir" 2>/dev/null)
        if [[ "$current_build_sec" == *"test: N/A"* ]] || ! echo "$current_build_sec" | grep -q '^test:'; then
            local base_cmd
            base_cmd=$(echo "$test_cmd" | awk '{print $1}')
            local updated_build_sec
            updated_build_sec=$(echo "$current_build_sec" | sed "s/^test:[[:space:]]*N\/A/test: $base_cmd/")
            memory_update_section "Build" "$updated_build_sec" "$workdir" 2>/dev/null
        fi
    fi

    # Append specific test file / target argument if present and not already in test_cmd
    local target_arg="${target_file:-$args}"
    if [ -n "$target_arg" ]; then
        if [[ "$test_cmd" != *"$target_arg"* ]]; then
            test_cmd="$test_cmd $target_arg"
        fi
    fi
    
    # 4. Tool Availability Gating
    local primary_tool
    primary_tool=$(echo "$test_cmd" | awk '{print $1}')
    if ! command -v "$primary_tool" &>/dev/null; then
        ui_err "Cannot run test: '$primary_tool' is not installed or unavailable on PATH"
        return 1
    fi

    ui_step "Running: $test_cmd"
    echo ""
    local cmd_out exit_code
    if declare -f ui_exec_stream &>/dev/null; then
        ui_exec_stream "$test_cmd" "  │ "
        exit_code=$?
        cmd_out="${_LAST_EXEC_OUT:-}"
    else
        cmd_out=$(bash -c "$test_cmd" 2>&1)
        exit_code=$?
        echo "$cmd_out"
    fi
    
    # 5. Missing Python Module Auto-Provisioning
    if [ $exit_code -ne 0 ] && [[ "$test_cmd" == *"python"* || "$test_cmd" == *"pytest"* ]]; then
        if [[ "$cmd_out" =~ (ModuleNotFoundError:[[:space:]]*No[[:space:]]+module[[:space:]]+named|No[[:space:]]+module[[:space:]]+named)[[:space:]]*\'([a-zA-Z0-9_]+)\' ]]; then
            local missing_mod="${BASH_REMATCH[2]}"
            ui_warn "Test execution detected missing Python package '$missing_mod'. Attempting user-space installation..."
            local inst_exit=1
            if command -v uv &>/dev/null; then
                uv pip install "$missing_mod" 2>&1
                inst_exit=$?
            elif python3 -m pip --version &>/dev/null; then
                python3 -m pip install --user "$missing_mod" 2>&1
                inst_exit=$?
            fi
            if [ $inst_exit -eq 0 ]; then
                ui_ok "Installed '$missing_mod' to user site-packages. Re-running tests..."
                echo ""
                cmd_out=$(bash -c "$test_cmd" 2>&1)
                exit_code=$?
                echo "$cmd_out"
            fi
        fi
    fi

    echo ""
    if [ $exit_code -eq 0 ]; then
        ui_ok "Tests passed"
    else
        ui_err "Tests failed (exit $exit_code)"
        memory_append_section "Context Files" "tests failed: exit $exit_code" "$workdir"
    fi
    
    return $exit_code
}
