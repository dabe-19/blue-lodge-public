#!/bin/bash
# ── George: Modern POSIX ReAct Engine (2026) ─────────────────────────
# Dual-protocol agent loop:
# 1. Native OpenAI JSON Function/Tool Calling (primary path)
# 2. Text-based ReAct slash commands (fallback path for edge models)
# Integrated with:
# - Copilot-Style Dynamic Context Injection (lib/context_engine.sh)
# - Pure POSIX Native Tool Bridge (lib/native_tools.sh)
# - 4-Tier Hardware Topology & Subagents (lib/endpoints.sh, lib/subagents.sh)
# - Running token tracking & micro-compaction

[ -n "${_LIB_REACT_LOADED:-}" ] && return 0; _LIB_REACT_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"

source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/endpoints.sh"
source "$LODGE_DIR/lib/commands.sh"
source "$LODGE_DIR/lib/memory.sh"
source "$LODGE_DIR/lib/journal.sh"
source "$LODGE_DIR/lib/subagents.sh"
source "$LODGE_DIR/lib/native_tools.sh"
source "$LODGE_DIR/lib/context_engine.sh"

# ── Auto-Compaction Engine ───────────────────────────────────────────
_react_compact_messages() {
    local session_dir="$1"
    local endpoint_url="$2"
    local messages_file="$session_dir/messages.json"
    local memory_file="$session_dir/memory.md"

    ui_dim "Compacting conversation history..."

    local msgs_summary
    msgs_summary=$(jq -r '.[] | "\(.role): \(.content // .tool_calls // "")"' "$messages_file" 2>/dev/null | tail -n 60)

    local prompt="The following is an ongoing agent trajectory. Summarize the key accomplishments, discovered facts, and remaining tasks concisely:\n\n$msgs_summary"

    local payload
    payload=$(jq -n \
        --arg sys "You are a state summarizer. Produce a concise structured summary: Accomplished, Key Facts, Pending Goals." \
        --arg prompt "$prompt" \
        '{
            messages: [
                {"role": "system", "content": $sys},
                {"role": "user", "content": $prompt}
            ],
            temperature: 0.2,
            max_tokens: 512
        }')

    local summary_resp
    summary_resp=$(curl -s --max-time 45 "$endpoint_url/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    local summary_text
    summary_text=$(echo "$summary_resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

    if [ -n "$summary_text" ]; then
        echo "## Context Summary (Auto-Compacted):" > "$memory_file"
        echo "$summary_text" >> "$memory_file"

        # Retain system prompt and latest 4 messages, injecting memory summary
        local sys_msg last_few
        sys_msg=$(jq '.[0]' "$messages_file")
        last_few=$(jq '.[-4:]' "$messages_file")

        jq -n \
            --argjson sys "$sys_msg" \
            --arg mem "$summary_text" \
            --argjson rest "$last_few" \
            '[$sys, {"role": "user", "content": ("[PREVIOUS CONTEXT COMPACTED]:\n" + $mem)}] + $rest' \
            > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"

        ui_ok "Context successfully compacted."
    fi
}

# ── Fallback Text Action Parser ──────────────────────────────────────
_react_parse_action() {
    local raw_output="$1"

    local cleaned
    cleaned=$(echo "$raw_output" | sed -e '/<think>/,/<\/think>/d')

    local action=""
    if echo "$cleaned" | grep -qE '^Action:[[:space:]]*`?\/'; then
        action=$(echo "$cleaned" | sed -n 's/^Action:[[:space:]]*`\?\(\/.*\)`\?/\1/p' | head -1)
    elif echo "$cleaned" | grep -qE '^[[:space:]]*`?\/'; then
        action=$(echo "$cleaned" | grep -E '^[[:space:]]*`?\/' | head -1)
        action="${action#"${action%%[![:space:]]*}"}"
    elif echo "$cleaned" | grep -q '```bash'; then
        action=$(echo "$cleaned" | sed -n '/```bash/,/```/p' | grep -E '^[[:space:]]*`?\/' | head -1)
        action="${action#"${action%%[![:space:]]*}"}"
    fi

    action="${action#\`}"
    action="${action%\`}"
    action="${action%$'\r'}"

    echo "$action"
}

# ── Main ReAct Runner ────────────────────────────────────────────────
react_run() {
    local goal="$1"
    local workdir="${2:-$PWD}"
    local max_turns="${3:-15}"

    # 1. Cascade to highest active endpoint tier
    if ! endpoints_cascade; then
        ui_err "No active inference endpoints available. Check endpoints.conf or start a backend."
        return 1
    fi

    ui_ok "Active Engine: Tier $ACTIVE_TIER [$ACTIVE_ENDPOINT_NAME] ($ACTIVE_ENDPOINT_MODEL @ $ACTIVE_ENDPOINT_URL)"
    ui_dim "Context Window: $ACTIVE_ENDPOINT_CONTEXT tokens | Compaction Threshold: $ACTIVE_ENDPOINT_COMPACT_TOKENS tokens"

    # 2. Setup session sandbox
    local session_id="session_$(date +%Y%m%d_%H%M%S)_$$"
    local session_dir="$GEORGE_DIR/workspaces/$session_id"
    mkdir -p "$session_dir"

    local history_file="$session_dir/trajectory.log"
    local messages_file="$session_dir/messages.json"
    local memory_file="$session_dir/memory.md"
    : > "$history_file"

    # 3. Assemble Dynamic Copilot-Style Context & Tool Schemas
    ui_dim "Assembling context pipeline and native tool registry..."
    local sys_prompt
    sys_prompt=$(context_engine_build "$goal" "$workdir" "$ACTIVE_TIER")

    local tools_schema
    tools_schema=$(native_tools_get_all_schemas)

    # Initialize messages.json
    jq -n \
        --arg sys "$sys_prompt" \
        --arg user "$goal" \
        '[
            {"role": "system", "content": $sys},
            {"role": "user", "content": $user}
        ]' > "$messages_file"

    local running_tokens=0
    local turn=1

    echo "PRIMARY OBJECTIVE: $goal" >> "$history_file"
    ui_info "Starting Task: $goal"

    while [ "$turn" -le "$max_turns" ]; do
        printf "\n${C_BOLD}${C_CYAN}── Turn %d/%d ──────────────────────────────${C_RESET}\n" "$turn" "$max_turns"

        # Check compaction threshold
        if [ "$running_tokens" -ge "$ACTIVE_ENDPOINT_COMPACT_TOKENS" ]; then
            _react_compact_messages "$session_dir" "$ACTIVE_ENDPOINT_URL"
            running_tokens=0
        fi

        # Prepare chat completions payload
        local payload
        payload=$(jq -n \
            --slurpfile msgs "$messages_file" \
            --argjson tools "$tools_schema" \
            '{
                messages: $msgs[0],
                tools: $tools,
                tool_choice: "auto",
                temperature: 0.2,
                max_tokens: 2048
            }')

        ui_dim "Thinking..."
        local resp_json
        resp_json=$(curl -s --max-time 120 "$ACTIVE_ENDPOINT_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null)

        if [ -z "$resp_json" ]; then
            ui_err "Empty response from endpoint $ACTIVE_ENDPOINT_URL."
            return 1
        fi

        local raw_content reasoning tool_calls
        raw_content=$(echo "$resp_json" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        reasoning=$(echo "$resp_json" | jq -r '.choices[0].message.reasoning_content // empty' 2>/dev/null)
        tool_calls=$(echo "$resp_json" | jq -c '.choices[0].message.tool_calls // empty' 2>/dev/null)

        # Accounting for token consumption
        local p_tok comp_tok
        p_tok=$(echo "$resp_json" | jq -r '.usage.prompt_tokens // 0' 2>/dev/null)
        comp_tok=$(echo "$resp_json" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)
        local turn_total=$((p_tok + comp_tok))
        # llama-server's prompt_tokens is ALREADY the cumulative context of all turns in this request.
        # Track actual current context size instead of accumulating prompt tokens quadratically.
        running_tokens=$turn_total
        local pct=$((turn_total * 100 / ACTIVE_ENDPOINT_CONTEXT))
        ui_dim "Context: ${turn_total}/${ACTIVE_ENDPOINT_CONTEXT} tokens (${pct}%) | Compaction at ${ACTIVE_ENDPOINT_COMPACT_TOKENS}"

        # Show reasoning if present
        if [ -n "$reasoning" ]; then
            printf "${C_DIM}[thought] %s${C_RESET}\n" "$reasoning"
        fi

        # ── Branch 1: Native OpenAI Tool Calls Detected ──────────────
        if [ -n "$tool_calls" ] && [ "$tool_calls" != "null" ] && [ "$tool_calls" != "[]" ]; then
            # Append assistant message (with tool_calls) to conversation history
            local asst_msg
            asst_msg=$(echo "$resp_json" | jq -c '.choices[0].message')
            jq --argjson m "$asst_msg" '. += [$m]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"

            # Execute each emitted tool call
            echo "$tool_calls" | jq -c '.[]' | while read -r call; do
                local c_id c_name c_args
                c_id=$(echo "$call" | jq -r '.id')
                c_name=$(echo "$call" | jq -r '.function.name')
                c_args=$(echo "$call" | jq -r '.function.arguments')

                ui_step "Native Tool Call: $c_name"
                echo "Tool Call: $c_name ($c_args)" >> "$history_file"

                local tool_resp
                tool_resp=$(native_tools_dispatch "$c_id" "$c_name" "$c_args" "$workdir")

                # Append tool response to messages array
                jq --argjson tr "$tool_resp" '. += [$tr]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"

                local resp_content
                resp_content=$(echo "$tool_resp" | jq -r '.content')
                echo "Observation: $resp_content" >> "$history_file"

                # Brief UI preview
                local preview
                preview=$(echo "$resp_content" | head -n 3 | tr '\n' ' ')
                printf "${C_DIM}  ↳ Result: %s${C_RESET}\n" "$preview"
            done

            turn=$((turn + 1))
            continue
        fi

        # ── Branch 2: Model Outputted Content / Fallback Slash Command
        if [ -n "$raw_content" ]; then
            echo "$raw_content"
        fi

        local action
        action=$(_react_parse_action "$raw_content")

        # Handle text /respond
        if [[ "$action" == /respond* ]]; then
            local answer="${action#/respond}"
            answer="${answer#"${answer%%[![:space:]]*}"}"
            echo ""
            ui_ok "Task Complete!"
            printf "${C_BOLD}${C_GREEN}%s${C_RESET}\n" "$answer"
            journal_write "reflection" "Goal achieved: $goal. Result: $answer" 2>/dev/null || true
            return 0
        fi

        # Handle text /delegate
        if [[ "$action" == /delegate* ]]; then
            local del_args="${action#/delegate}"
            del_args="${del_args#"${del_args%%[![:space:]]*}"}"
            local del_tier="${del_args%% *}"
            local del_task="${del_args#* }"

            ui_info "Delegating to Tier $del_tier: $del_task"
            local subagent_obs
            subagent_obs=$(subagents_spawn "$del_tier" "$del_task" "Parent Goal: $goal" "$workdir" 2>&1)
            
            # Append as user observation
            jq --arg obs "Subagent Tier $del_tier Output:\n$subagent_obs" \
                '. += [{"role": "user", "content": $obs}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"

            turn=$((turn + 1))
            continue
        fi

        # Handle other text slash commands (fallback path)
        if [ -n "$action" ]; then
            ui_step "Executing fallback command: $action"
            echo "Action: $action" >> "$history_file"

            local obs
            obs=$(commands_dispatch "$action" "$workdir" 2>&1)
            local exit_code=$?

            obs=$(printf '%s\n' "$obs" | sed -r 's/\x1B\[[0-9;]*[a-zA-Z]//g')
            if [ ${#obs} -gt 3000 ]; then
                obs="${obs:0:3000}\n... [truncated]"
            fi

            jq --arg obs "Command $action (exit $exit_code):\n$obs" \
                '. += [{"role": "user", "content": $obs}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"

            turn=$((turn + 1))
            continue
        fi

        # If model provided answer directly without tool calls on turn > 1, conclude task
        if [ -n "$raw_content" ]; then
            echo ""
            ui_ok "Task Complete!"
            journal_write "reflection" "Completed task: $goal. Summary: ${raw_content:0:200}" 2>/dev/null || true
            return 0
        fi

        turn=$((turn + 1))
    done

    ui_warn "Task reached maximum turns ($max_turns)."
    return 1
}

# Alias agent_run to react_run
agent_run() {
    react_run "$@"
}
