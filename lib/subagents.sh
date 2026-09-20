#!/bin/bash
# ── George: Subagent Delegation Engine (2026) ────────────────────────
# Manages child worker agents delegated across the 4-tier model hierarchy.
# Provides git worktree sandboxing, central process registry, in-flight control FIFO,
# 50-turn child limit, 5-turn countdown alert, and zero-orphan lifecycle reaping.

[ -n "${_LIB_SUBAGENTS_LOADED:-}" ] && return 0; _LIB_SUBAGENTS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
SUBAGENTS_REGISTRY="${SUBAGENTS_REGISTRY:-$GEORGE_DIR/subagents.json}"

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/endpoints.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ui_dashboard.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/commands.sh" 2>/dev/null || true

# ── Central Subagents Registry ───────────────────────────────────────
subagents_registry_file() {
    echo "$SUBAGENTS_REGISTRY"
}

subagents_init() {
    mkdir -p "$GEORGE_DIR" 2>/dev/null || true
    if [ ! -f "$SUBAGENTS_REGISTRY" ] || [ ! -s "$SUBAGENTS_REGISTRY" ]; then
        echo "[]" > "$SUBAGENTS_REGISTRY"
    fi
}

subagents_register() {
    local sub_id="$1"
    local pid="$2"
    local parent_pid="$3"
    local tier="$4"
    local model="$5"
    local objective="$6"
    local branch="$7"
    local worktree_dir="$8"
    local max_turns="$9"
    local started_at
    started_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")

    subagents_init
    local tmp_reg="${SUBAGENTS_REGISTRY}.tmp.$$"
    jq --arg id "$sub_id" \
       --arg pid "$pid" \
       --arg ppid "$parent_pid" \
       --arg tier "$tier" \
       --arg model "$model" \
       --arg obj "$objective" \
       --arg br "$branch" \
       --arg wt "$worktree_dir" \
       --arg turns "$max_turns" \
       --arg start "$started_at" \
       '. += [{
           id: $id,
           pid: ($pid | tonumber? // 0),
           parent_pid: ($ppid | tonumber? // 0),
           tier: $tier,
           model: $model,
           objective: $obj,
           branch: $br,
           worktree_dir: $wt,
           max_turns: ($turns | tonumber? // 50),
           current_turn: 1,
           status: "RUNNING",
           started_at: $start,
           updated_at: $start
       }]' "$SUBAGENTS_REGISTRY" > "$tmp_reg" 2>/dev/null && mv "$tmp_reg" "$SUBAGENTS_REGISTRY"
}

subagents_update_status() {
    local sub_id="$1"
    local status="$2"
    local turn="${3:-}"
    local result="${4:-}"
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")

    subagents_init
    local tmp_reg="${SUBAGENTS_REGISTRY}.tmp.$$"
    jq --arg id "$sub_id" \
       --arg st "$status" \
       --arg turn "$turn" \
       --arg res "$result" \
       --arg now "$now" \
       'map(if .id == $id then
           .status = $st |
           .updated_at = $now |
           (if $turn != "" then .current_turn = ($turn | tonumber? // .current_turn) else . end) |
           (if $res != "" then .result = $res else . end)
       else . end)' "$SUBAGENTS_REGISTRY" > "$tmp_reg" 2>/dev/null && mv "$tmp_reg" "$SUBAGENTS_REGISTRY"
}

subagents_get_active() {
    subagents_init
    jq -c '[.[] | select(.status == "RUNNING" or .status == "PAUSED")]' "$SUBAGENTS_REGISTRY" 2>/dev/null || echo "[]"
}

subagents_reap_orphans() {
    subagents_init
    local running
    running=$(jq -r '.[] | select(.status == "RUNNING" or .status == "PAUSED") | "\(.id)|\(.pid)|\(.branch)|\(.worktree_dir)"' "$SUBAGENTS_REGISTRY" 2>/dev/null || true)
    [ -z "$running" ] && return 0

    while IFS='|' read -r sid spid sbranch swt; do
        [ -z "$sid" ] && continue
        local is_alive=0
        if [ -n "$spid" ] && [ "$spid" -gt 0 ] 2>/dev/null; then
            if kill -0 "$spid" 2>/dev/null; then
                is_alive=1
            fi
        fi

        if [ "$is_alive" -eq 0 ]; then
            declare -f ui_warn &>/dev/null && ui_warn "Reaping orphaned subagent $sid (PID $spid dead)..."
            if [ -n "$swt" ] && [ -d "$swt" ]; then
                git -C "$LODGE_DIR" worktree remove --force "$swt" 2>/dev/null || rm -rf "$swt" 2>/dev/null || true
            fi
            if [ -n "$sbranch" ]; then
                git -C "$LODGE_DIR" branch -D "$sbranch" 2>/dev/null || true
            fi
            subagents_update_status "$sid" "ORPHAN_REAPED" "" "Process disappeared"
        fi
    done <<< "$running"

    git -C "$LODGE_DIR" worktree prune 2>/dev/null || true
}

subagents_cleanup_all() {
    subagents_init
    local running
    running=$(jq -r '.[] | select(.status == "RUNNING" or .status == "PAUSED") | "\(.id)|\(.pid)|\(.branch)|\(.worktree_dir)"' "$SUBAGENTS_REGISTRY" 2>/dev/null || true)
    [ -z "$running" ] && return 0

    while IFS='|' read -r sid spid sbranch swt; do
        [ -z "$sid" ] && continue
        if [ -n "$spid" ] && [ "$spid" -gt 0 ] 2>/dev/null; then
            if kill -0 "$spid" 2>/dev/null; then
                kill -TERM "$spid" 2>/dev/null || true
            fi
        fi
        if [ -n "$swt" ] && [ -d "$swt" ]; then
            git -C "$LODGE_DIR" worktree remove --force "$swt" 2>/dev/null || rm -rf "$swt" 2>/dev/null || true
        fi
        if [ -n "$sbranch" ]; then
            git -C "$LODGE_DIR" branch -D "$sbranch" 2>/dev/null || true
        fi
        subagents_update_status "$sid" "KILLED_EXIT" "" "Lodge exit cleanup"
    done <<< "$running"

    git -C "$LODGE_DIR" worktree prune 2>/dev/null || true
}

# ── Subagent Dispatcher ──────────────────────────────────────────────
# Spawns a dedicated subagent on the specified tier to accomplish a delegated goal.
# Usage: subagents_spawn <tier> <objective> [context] [workdir] [max_turns]
subagents_spawn() {
    local target_tier="$1"
    local objective="$2"
    local parent_context="${3:-}"
    local workdir="${4:-$PWD}"
    local max_turns="${5:-${AGENT_CHILD_MAX_TURNS:-50}}"

    if [ -z "$target_tier" ] || [ -z "$objective" ]; then
        echo "ERROR: subagents_spawn requires tier and objective arguments."
        return 1
    fi

    # Check if target tier is available
    if ! endpoints_probe "$target_tier"; then
        local t_name
        t_name=$(endpoints_get_tier_info "$target_tier" "NAME")
        echo "ERROR: Tier $target_tier ($t_name) is currently offline or unreachable."
        return 1
    fi

    local tier_name tier_url tier_model tier_ctx tier_roles
    tier_name=$(endpoints_get_tier_info "$target_tier" "NAME")
    tier_url=$(endpoints_get_tier_info "$target_tier" "URL")
    tier_model=$(endpoints_get_tier_info "$target_tier" "MODEL")
    tier_ctx=$(endpoints_get_tier_info "$target_tier" "CONTEXT")
    tier_roles=$(endpoints_get_tier_info "$target_tier" "ROLES")

    # Generate unique subagent ID and isolated runtime directory in git worktree
    local sub_id="sub_t${target_tier}_${RANDOM}_$(date +%s)"
    local sub_branch="subagent/${sub_id}"
    local sandbox_base="${LODGE_DIR}/.sandboxes"
    local sub_dir="${sandbox_base}/${sub_id}"
    local is_worktree=0

    mkdir -p "$sandbox_base" 2>/dev/null || true

    # Provision git worktree if inside a git repository
    if git -C "$LODGE_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
        if git -C "$LODGE_DIR" worktree add -b "$sub_branch" "$sub_dir" 2>/dev/null; then
            is_worktree=1
        fi
    fi

    # Fallback to plain directory if worktree add fails
    if [ ! -d "$sub_dir" ]; then
        mkdir -p "$sub_dir"
    fi

    # Setup FIFOs: stream.fifo and control.fifo
    local sub_fifo="$sub_dir/stream.fifo"
    local ctrl_fifo="$sub_dir/control.fifo"
    rm -f "$sub_fifo" "$ctrl_fifo"
    mkfifo "$sub_fifo" 2>/dev/null || true
    mkfifo "$ctrl_fifo" 2>/dev/null || true

    # Scoped endpoints configuration for child
    mkdir -p "$sub_dir/.george" 2>/dev/null || true
    cat > "$sub_dir/.george/endpoints.conf" <<EOF
# Subagent Scoped Endpoints Configuration
TIER${target_tier}_NAME="${tier_name}"
TIER${target_tier}_URL="${tier_url}"
TIER${target_tier}_MODEL="${tier_model}"
TIER${target_tier}_CONTEXT=${tier_ctx}
TIER${target_tier}_ENABLED=1
EOF

    # Register in central subagents registry
    subagents_register "$sub_id" "$$" "$$" "$target_tier" "$tier_model" "$objective" "$sub_branch" "$sub_dir" "$max_turns"

    # Register with visual dashboard
    declare -f ui_dashboard_worker_start &>/dev/null && ui_dashboard_worker_start "$sub_id" "$target_tier" "$tier_model" "$objective"

    # Ensure cleanup on return
    _subagent_cleanup() {
        rm -f "$sub_fifo" "$ctrl_fifo" 2>/dev/null
        if [ "$is_worktree" -eq 1 ]; then
            git -C "$LODGE_DIR" worktree remove --force "$sub_dir" 2>/dev/null || rm -rf "$sub_dir" 2>/dev/null || true
            git -C "$LODGE_DIR" branch -D "$sub_branch" 2>/dev/null || true
        else
            rm -rf "$sub_dir" 2>/dev/null
        fi
    }
    trap _subagent_cleanup RETURN

    local sub_history="$sub_dir/history.log"
    : > "$sub_history"

    # Subagent System Prompt
    local sub_system="You are an autonomous subagent worker (Tier $target_tier: $tier_model).
Role: $tier_roles
Your specific objective: $objective
Parent Context: $parent_context

You operate in an isolated sandbox. You can execute tools via slash commands:
- /web search <query> : Search the web
- /web fetch <url> : Fetch markdown page
- /read <file> : Read file contents
- /bash <cmd> : Execute shell command in workspace
- /respond <text> : Conclude your task and return the final synthesized answer.

Output format for each turn:
Thought: <reasoning>
Action: <slash-command>

When your task is complete, finish with:
Action: /respond <distilled result>"

    local turn=1
    local final_result=""

    while [ "$turn" -le "$max_turns" ]; do
        declare -f ui_dashboard_worker_update &>/dev/null && ui_dashboard_worker_update "$sub_id" "turn $turn/$max_turns"
        subagents_update_status "$sub_id" "RUNNING" "$turn"

        # Check in-flight control FIFO (non-blocking)
        if [ -p "$ctrl_fifo" ]; then
            local ctrl_cmd=""
            read -t 0.05 -r ctrl_cmd <> "$ctrl_fifo" 2>/dev/null || true
            if [ -n "$ctrl_cmd" ]; then
                case "$ctrl_cmd" in
                    PAUSE*)
                        subagents_update_status "$sub_id" "PAUSED" "$turn"
                        declare -f ui_info &>/dev/null && ui_info "Subagent $sub_id paused by parent. Awaiting RESUME..."
                        while true; do
                            local resume_cmd=""
                            read -r resume_cmd <> "$ctrl_fifo" 2>/dev/null || true
                            [[ "$resume_cmd" == RESUME* ]] && break
                            [[ "$resume_cmd" == ABORT* ]] && { final_result="ABORTED_BY_PARENT"; break 2; }
                            sleep 0.2
                        done
                        subagents_update_status "$sub_id" "RUNNING" "$turn"
                        ;;
                    ABORT*)
                        final_result="ABORTED_BY_PARENT"
                        break
                        ;;
                esac
            fi
        fi

        # 5-turn countdown alert for child subagent
        local countdown_notice=""
        if [ "$turn" -ge "$((max_turns - 5))" ]; then
            local rem=$((max_turns - turn))
            declare -f ui_warn &>/dev/null && ui_warn "Child subagent $sub_id approaching turn ceiling: Turn $turn/$max_turns ($rem turn(s) remaining)."
            countdown_notice="[SYSTEM NOTICE: APPROACHING TURN CEILING ($rem turn(s) remaining of $max_turns). Cease exploratory actions. Consolidate your deliverables and conclude with /respond.]\n\n"
        fi

        # Build messages payload
        local messages_json
        local recent_obs=""
        if [ -s "$sub_history" ]; then
            recent_obs=$(tail -n 30 "$sub_history")
        fi

        messages_json=$(jq -n \
            --arg sys "$sub_system" \
            --arg goal "$objective" \
            --arg cd "$countdown_notice" \
            --arg obs "$recent_obs" \
            '[
                {"role": "system", "content": $sys},
                {"role": "user", "content": ($cd + "Objective: " + $goal + "\n\nTrajectory:\n" + $obs + "\n\nNext Action:")}
            ]')

        local payload
        payload=$(jq -n \
            --arg model "$tier_model" \
            --argjson msgs "$messages_json" \
            '{
                model: $model,
                messages: $msgs,
                temperature: 0.2,
                max_tokens: 1024
            }')

        # Query endpoint
        local resp_json
        resp_json=$(curl -s --max-time 60 "$tier_url/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null)

        if [ -z "$resp_json" ]; then
            echo "Action: /respond ERROR: Target model endpoint timed out or failed." >> "$sub_history"
            final_result="ERROR: Subagent endpoint timed out."
            break
        fi

        local raw_content
        raw_content=$(echo "$resp_json" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

        # Parse action
        local action=""
        local cleaned
        cleaned=$(echo "$raw_content" | sed -e '/<think>/,/<\/think>/d')

        if echo "$cleaned" | grep -qE '^Action:[[:space:]]*/'; then
            action=$(echo "$cleaned" | sed -n 's/^Action:[[:space:]]*\(\/.*\)/\1/p' | head -1)
        elif echo "$cleaned" | grep -qE '^[[:space:]]*/'; then
            action=$(echo "$cleaned" | grep -E '^[[:space:]]*/' | head -1)
            action="${action#"${action%%[![:space:]]*}"}"
        fi

        if [ -z "$action" ]; then
            # If model returned text without action on later turns, treat as completion
            if [ -n "$cleaned" ] && [ "$turn" -gt 1 ]; then
                final_result="$cleaned"
                break
            fi
            action="/respond $cleaned"
        fi

        # Check for /respond
        if [[ "$action" == /respond* ]]; then
            final_result="${action#/respond}"
            final_result="${final_result#"${final_result%%[![:space:]]*}"}"
            [ -z "$final_result" ] && final_result="$cleaned"
            break
        fi

        # Execute tool inside isolated worktree directory
        echo "Action: $action" >> "$sub_history"
        local obs
        obs=$(commands_dispatch "$action" "$sub_dir" 2>&1)

        # Truncate observation to prevent context explosion
        if [ ${#obs} -gt 1500 ]; then
            obs="${obs:0:1500}... [truncated]"
        fi
        echo "Observation: $obs" >> "$sub_history"

        turn=$((turn + 1))
    done

    # Finalize visual dashboard and registry
    local exit_code=0
    [ -z "$final_result" ] && exit_code=1
    local final_status="COMPLETED"
    [ "$exit_code" -ne 0 ] && final_status="FAILED"
    subagents_update_status "$sub_id" "$final_status" "$turn" "$final_result"
    declare -f ui_dashboard_worker_finish &>/dev/null && ui_dashboard_worker_finish "$sub_id" "$exit_code"

    if [ -z "$final_result" ]; then
        echo "Subagent reached max turns without explicit response."
    else
        echo "$final_result"
    fi

    return "$exit_code"
}
