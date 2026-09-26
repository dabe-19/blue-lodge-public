#!/bin/bash
# DESC: Manage autonomous George clones & sandboxes or clone a repository
# Usage: /clone [list|spawn|pause|resume|cull|await|<repo_url>] [args...]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/sandbox.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agent_sm.sh" 2>/dev/null || true

cmd_clone() {
    local args="$1"
    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        list)
            agent_sm_init
            local cur
            cur=$(agent_sm_list "$rest")
            if [ -z "$cur" ] || [ "$cur" = "[]" ]; then
                ui_info "No active George clones registered."
                return 0
            fi
            ui_step "Autonomous George Clones & Agent State Machine:"
            printf "%-26s %-12s %-12s %-10s %s\n" "AGENT ID" "TYPE" "STATE" "PORT" "OBJECTIVE"
            printf "%-26s %-12s %-12s %-10s %s\n" "--------------------------" "------------" "------------" "----------" "-------------------------"
            echo "$cur" | jq -r '.[] | "\(.agent_id)|\(.clone_type)|\(.state)|\(.gpu_port)|\(.task_description)"' | \
            while IFS='|' read -r aid ctype st port desc; do
                local status_color="$st"
                case "$st" in
                    RUNNING)   status_color="${COLOR_GREEN:-}${st}${COLOR_RESET:-}" ;;
                    FLOW_PAUSED) status_color="${COLOR_YELLOW:-}${st}${COLOR_RESET:-}" ;;
                    COMPLETED) status_color="${COLOR_CYAN:-}${st}${COLOR_RESET:-}" ;;
                    FAILED|ORPHANED|CULLED) status_color="${COLOR_RED:-}${st}${COLOR_RESET:-}" ;;
                esac
                printf "%-26s %-12s %-21b %-10s %s\n" "$aid" "$ctype" "$status_color" "$port" "${desc:0:40}"
            done
            return 0
            ;;
        spawn)
            local aid objective port
            aid=$(echo "$rest" | awk '{print $1}')
            rest="${rest#"$aid"}"
            rest="${rest#"${rest%%[![:space:]]*}"}"
            objective="$rest"
            [ -z "$aid" ] && { ui_err "Usage: /clone spawn <clone_id> <objective_command>"; return 1; }
            agent_sm_spawn_clone "$aid" "$objective"
            ui_ok "George clone $aid spawned asynchronously in worktree .sandboxes/$aid"
            return 0
            ;;
        pause)
            [ -z "$rest" ] && { ui_err "Usage: /clone pause <clone_id>"; return 1; }
            agent_sm_flow_control "$rest" "PAUSE"
            ui_ok "Flow control paused for clone $rest"
            return 0
            ;;
        resume)
            [ -z "$rest" ] && { ui_err "Usage: /clone resume <clone_id>"; return 1; }
            agent_sm_flow_control "$rest" "RESUME"
            ui_ok "Flow control resumed for clone $rest"
            return 0
            ;;
        cull)
            [ -z "$rest" ] && { ui_err "Usage: /clone cull <clone_id>"; return 1; }
            agent_sm_cull "$rest" "Operator manual cull"
            ui_ok "Clone $rest and sandbox culled"
            return 0
            ;;
        await)
            local aid timeout
            aid=$(echo "$rest" | awk '{print $1}')
            timeout=$(echo "$rest" | awk '{print $2}')
            [ -z "$timeout" ] && timeout=30
            [ -z "$aid" ] && { ui_err "Usage: /clone await <clone_id> [timeout_s]"; return 1; }
            ui_step "Awaiting resolution of clone $aid (timeout: ${timeout}s)..."
            if agent_sm_await "$aid" "$timeout"; then
                ui_ok "Clone $aid completed successfully."
                return 0
            else
                ui_err "Clone $aid failed or timed out."
                return 1
            fi
            ;;
    esac

    # Fallback: Git repository cloning
    local url name
    url=$(echo "$args" | awk '{print $1}')
    name=$(echo "$args" | awk '{print $2}')
    
    if [ -z "$url" ]; then
        printf " Repo URL or owner/name: "
        read -r url
    fi
    
    # Expand shorthand: owner/repo → full URL
    if [[ "$url" =~ ^[a-zA-Z0-9_-]+/[a-zA-Z0-9_.-]+$ ]]; then
        url="https://github.com/$url.git"
    fi
    
    if [ -z "$name" ]; then
        name=$(basename "$url" .git)
    fi
    
    sandbox_clone "$url" "$name"
    
    # Auto-detect project type and init GEORGE.md
    local dir="$LODGE_SANDBOXES/$name"
    if [ -d "$dir" ]; then
        cd "$dir"
        local type="General" build="make" test="make test"
        
        if [ -f "Cargo.toml" ]; then
            type="Rust"; build="cargo build"; test="cargo test"
        elif [ -f "pyproject.toml" ]; then
            type="Python"; build="uv run python main.py"; test="uv run pytest"
        elif [ -f "package.json" ]; then
            type="Node.js"; build="npm run build"; test="npm test"
        fi
        
        if [ ! -f "GEORGE.md" ]; then
            source "$LODGE_DIR/lib/memory.sh"
            memory_init "." "$name" "$type" "$build" "$test"
        fi
        
        export LODGE_PROJECT="$name"
        ui_ok "Now in: $dir"
        ui_dim "Use /sandbox cd $name to switch here later"
    fi
}
