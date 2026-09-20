#!/bin/bash
# ── George: Subagent Delegation Engine (2026) ────────────────────────
# Manages child worker agents delegated across the 4-tier model hierarchy.
# Provides isolated execution directories, FIFO streaming, and dashboard hooks.

[ -n "${_LIB_SUBAGENTS_LOADED:-}" ] && return 0; _LIB_SUBAGENTS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/endpoints.sh"
source "$LODGE_DIR/lib/ui_dashboard.sh"
source "$LODGE_DIR/lib/commands.sh"

# ── Subagent Dispatcher ──────────────────────────────────────────────
# Spawns a dedicated subagent on the specified tier to accomplish a delegated goal.
# Usage: subagents_spawn <tier> <objective> [context] [workdir] [max_turns]
subagents_spawn() {
    local target_tier="$1"
    local objective="$2"
    local parent_context="${3:-}"
    local workdir="${4:-$PWD}"
    local max_turns="${5:-6}"

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

    local tier_url tier_model tier_ctx tier_roles
    tier_url=$(endpoints_get_tier_info "$target_tier" "URL")
    tier_model=$(endpoints_get_tier_info "$target_tier" "MODEL")
    tier_ctx=$(endpoints_get_tier_info "$target_tier" "CONTEXT")
    tier_roles=$(endpoints_get_tier_info "$target_tier" "ROLES")

    # Generate unique subagent ID and isolated runtime directory
    local sub_id="sub_t${target_tier}_${RANDOM}_$(date +%s)"
    local sub_dir="/tmp/.lodge-subagent-${sub_id}"
    mkdir -p "$sub_dir"

    # Setup FIFO for streaming
    local sub_fifo="$sub_dir/stream.fifo"
    rm -f "$sub_fifo"
    mkfifo "$sub_fifo"

    # Register with visual dashboard
    ui_dashboard_worker_start "$sub_id" "$target_tier" "$tier_model" "$objective"

    # Ensure cleanup on exit
    _subagent_cleanup() {
        rm -f "$sub_fifo" 2>/dev/null
        rm -rf "$sub_dir" 2>/dev/null
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
        ui_dashboard_worker_update "$sub_id" "turn $turn/$max_turns"

        # Build messages payload
        local messages_json
        local recent_obs=""
        if [ -s "$sub_history" ]; then
            recent_obs=$(tail -n 30 "$sub_history")
        fi

        messages_json=$(jq -n \
            --arg sys "$sub_system" \
            --arg goal "$objective" \
            --arg obs "$recent_obs" \
            '[
                {"role": "system", "content": $sys},
                {"role": "user", "content": ("Objective: " + $goal + "\n\nTrajectory:\n" + $obs + "\n\nNext Action:")}
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

        # Execute tool
        echo "Action: $action" >> "$sub_history"
        local obs
        obs=$(commands_dispatch "$action" "$workdir" 2>&1)

        # Truncate observation to prevent context explosion
        if [ ${#obs} -gt 1500 ]; then
            obs="${obs:0:1500}... [truncated]"
        fi
        echo "Observation: $obs" >> "$sub_history"

        turn=$((turn + 1))
    done

    # Finalize visual dashboard
    local exit_code=0
    [ -z "$final_result" ] && exit_code=1
    ui_dashboard_worker_finish "$sub_id" "$exit_code"

    if [ -z "$final_result" ]; then
        echo "Subagent reached max turns without explicit response."
    else
        echo "$final_result"
    fi

    return "$exit_code"
}
