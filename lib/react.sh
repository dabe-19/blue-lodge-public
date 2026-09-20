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
# - Full Task & Prompt Transcripts (.george/transcripts/)
# - Structured Routing Telemetry (.george/routing_trace.jsonl)
# - Macro Memory & Milestones (.george/macro_memory.json)

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
source "$LODGE_DIR/lib/transcript.sh" 2>/dev/null || true

# ── Structured Telemetry & Routing Trace ──────────────────────────────
_react_trace() {
    local workdir="$1" event="$2" payload="$3"
    local gdir="${workdir}/.george"
    local trace_file="$gdir/routing_trace.jsonl"
    mkdir -p "$gdir" 2>/dev/null || true
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)
    printf '{"timestamp":"%s","event":"%s","data":%s}\n' "$ts" "$event" "${payload:-{}}" >> "$trace_file" 2>/dev/null || true
}

# ── Auto-Compaction Engine ───────────────────────────────────────────
_react_compact_messages() {
    local session_dir="$1"
    local endpoint_url="$2"
    local workdir="${3:-.}"
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
        declare -f transcript_log_block &>/dev/null && transcript_log_block "auto-compaction" "$summary_text"
        _react_trace "$workdir" "auto_compaction" "$(jq -cn --arg sum "$summary_text" '{summary:$sum}')"
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
    local max_turns="${3:-${AGENT_MAX_MILESTONES:-${AGENT_PLAN_STEPS:-15}}}"
    local agent_temp="${AGENT_LLM_TEMPERATURE:-0.2}"
    local agent_max_tok="${AGENT_MAX_TOKENS:-2048}"

    # 1. Cascade to highest active endpoint tier
    if ! endpoints_cascade; then
        ui_err "No active inference endpoints available. Check endpoints.conf or start a backend."
        return 1
    fi

    ui_ok "Active Engine: Tier $ACTIVE_TIER [$ACTIVE_ENDPOINT_NAME] ($ACTIVE_ENDPOINT_MODEL @ $ACTIVE_ENDPOINT_URL)"
    ui_dim "Context Window: $ACTIVE_ENDPOINT_CONTEXT tokens | Compaction Threshold: $ACTIVE_ENDPOINT_COMPACT_TOKENS tokens"

    # 2. Setup session sandbox and .george persistence
    local gdir="${workdir}/.george"
    mkdir -p "$gdir" "$gdir/transcripts" "$gdir/workspaces"

    # Start persistent task transcript logging (.george/transcripts/*.md and *_prompts.md)
    declare -f transcript_start &>/dev/null && transcript_start "$goal" "$workdir"

    # Seed macro_memory.json
    local macro_file="$gdir/macro_memory.json"
    jq -n \
        --arg ts "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
        --arg obj "$goal" \
        --arg model "${ACTIVE_ENDPOINT_MODEL:-default}" \
        --arg tier "${ACTIVE_TIER:-1}" \
        '{
            task_started: $ts,
            primary_objective: $obj,
            model: $model,
            tier: $tier,
            completed_milestones: [],
            status: "IN_PROGRESS"
        }' > "$macro_file" 2>/dev/null || true

    _react_trace "$workdir" "task_start" "$(jq -cn --arg goal "$goal" --arg tier "${ACTIVE_TIER:-1}" '{goal:$goal, tier:$tier}')"

    local session_id="session_$(date +%Y%m%d_%H%M%S)_$$"
    local session_dir="$gdir/workspaces/$session_id"
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
            _react_compact_messages "$session_dir" "$ACTIVE_ENDPOINT_URL" "$workdir"
            running_tokens=0
        fi

        # Prepare chat completions payload with runtime /limits settings
        local payload
        payload=$(jq -n \
            --slurpfile msgs "$messages_file" \
            --argjson tools "$tools_schema" \
            --arg temp "$agent_temp" \
            --arg max_tok "$agent_max_tok" \
            '{
                messages: $msgs[0],
                tools: $tools,
                tool_choice: "auto",
                temperature: ($temp | tonumber),
                max_tokens: ($max_tok | tonumber),
                stream: true,
                stream_options: {include_usage: true}
            }')

        # Log turn boundary and prompt to transcript & prompt log
        declare -f transcript_section &>/dev/null && transcript_section "Turn $turn / $max_turns"
        declare -f transcript_log_prompt &>/dev/null && transcript_log_prompt "react-turn-$turn" "$payload" "$sys_prompt"

        local raw_content="" reasoning="" tool_calls="[]" p_tok=0 comp_tok=0
        local stream_cache="$session_dir/stream_turn_${turn}.json"

        local think_mode="${LODGE_THINK_STREAM:-1}"
        [ "${LODGE_THINK:-1}" -eq 0 ] && think_mode=0

        # Execute real-time streaming SSE pipeline
        curl -s -N --max-time 120 "$ACTIVE_ENDPOINT_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null | \
        sed -u -e 's/^data: //' -e '/^\[DONE\]/d' -e '/^[[:space:]]*$/d' | \
        jq --unbuffered -c '
            if .choices[0].delta.reasoning_content then
                {type: "thought", text: .choices[0].delta.reasoning_content}
            elif .choices[0].delta.content then
                {type: "content", text: .choices[0].delta.content}
            elif .choices[0].delta.tool_calls then
                {type: "tool_calls", delta: .choices[0].delta.tool_calls}
            elif .timings then
                {type: "usage", prompt_tokens: .timings.prompt_n, completion_tokens: .timings.predicted_n}
            elif .usage then
                {type: "usage", prompt_tokens: .usage.prompt_tokens, completion_tokens: .usage.completion_tokens}
            else
                empty
            end' 2>/dev/null | \
        tee "$stream_cache" | \
        awk -v think_mode="$think_mode" '
        BEGIN {
            color = (think_mode == 2 ? "\033[36m" : "\033[90m");
            in_thought = 0;
        }
        /"type":"thought"/ {
            if (think_mode > 0) {
                if (!in_thought) {
                    printf "%s[thought] ", color;
                    in_thought = 1;
                }
                sub(/.*"text":"/, "");
                sub(/"\}$/, "");
                gsub(/\\n/, "\n");
                gsub(/\\"/, "\"");
                gsub(/\\\\/, "\\");
                printf "%s", $0;
                fflush();
            }
        }
        /"type":"content"/ {
            if (in_thought) {
                if (think_mode > 0) printf "\033[0m\n";
                in_thought = 0;
            }
            sub(/.*"text":"/, "");
            sub(/"\}$/, "");
            gsub(/\\n/, "\n");
            gsub(/\\"/, "\"");
            gsub(/\\\\/, "\\");
            printf "%s", $0;
            fflush();
        }
        END {
            if (in_thought && think_mode > 0) {
                printf "\033[0m\n";
            }
        }'

        if [ ! -s "$stream_cache" ]; then
            # Graceful fallback: synchronous non-stream request
            ui_dim "Thinking..."
            local fallback_payload
            fallback_payload=$(echo "$payload" | jq '.stream = false | del(.stream_options)')
            local resp_json
            resp_json=$(curl -s --max-time 120 "$ACTIVE_ENDPOINT_URL/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "$fallback_payload" 2>/dev/null)

            if [ -z "$resp_json" ]; then
                ui_err "Empty response from endpoint $ACTIVE_ENDPOINT_URL."
                _react_trace "$workdir" "error" '{"error":"empty_response"}'
                if declare -f transcript_stop &>/dev/null && transcript_active 2>/dev/null; then
                    transcript_stop >/dev/null 2>&1
                fi
                return 1
            fi

            raw_content=$(echo "$resp_json" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
            reasoning=$(echo "$resp_json" | jq -r '.choices[0].message.reasoning_content // empty' 2>/dev/null)
            tool_calls=$(echo "$resp_json" | jq -c '.choices[0].message.tool_calls // empty' 2>/dev/null)
            p_tok=$(echo "$resp_json" | jq -r '.usage.prompt_tokens // 0' 2>/dev/null)
            comp_tok=$(echo "$resp_json" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)
            if [ -n "$reasoning" ]; then
                printf "${C_DIM}[thought] %s${C_RESET}\n" "$reasoning"
            fi
        else
            # Reconstruct complete response from stream cache
            local reconstructed
            reconstructed=$(jq -s '
              {
                reasoning: ([.[] | select(.type=="thought") | .text] | join("")),
                content: ([.[] | select(.type=="content") | .text] | join("")),
                tool_calls: (
                  ([.[] | select(.type=="tool_calls") | .delta[]] // []) |
                  reduce .[] as $call (
                    [];
                    .[$call.index] = {
                      id: (.[$call.index].id // $call.id),
                      type: (.[$call.index].type // $call.type // "function"),
                      function: {
                        name: (.[$call.index].function.name // $call.function.name),
                        arguments: ((.[$call.index].function.arguments // "") + ($call.function.arguments // ""))
                      }
                    }
                  )
                ),
                usage: (reduce (.[] | select(.type=="usage")) as $u ({}; . + $u))
              }
            ' "$stream_cache" 2>/dev/null)

            raw_content=$(echo "$reconstructed" | jq -r '.content // empty' 2>/dev/null)
            reasoning=$(echo "$reconstructed" | jq -r '.reasoning // empty' 2>/dev/null)
            tool_calls=$(echo "$reconstructed" | jq -c '.tool_calls // empty' 2>/dev/null)
            p_tok=$(echo "$reconstructed" | jq -r '.usage.prompt_tokens // 0' 2>/dev/null)
            comp_tok=$(echo "$reconstructed" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)
        fi

        # Accounting for token consumption
        local turn_total=$((p_tok + comp_tok))
        [ "$turn_total" -gt 0 ] && running_tokens=$turn_total
        local pct=0
        [ "${ACTIVE_ENDPOINT_CONTEXT:-0}" -gt 0 ] && pct=$((turn_total * 100 / ACTIVE_ENDPOINT_CONTEXT))
        ui_dim "Context: ${turn_total}/${ACTIVE_ENDPOINT_CONTEXT} tokens (${pct}%) | Compaction at ${ACTIVE_ENDPOINT_COMPACT_TOKENS}"

        if [ -n "$reasoning" ]; then
            declare -f transcript_log_block &>/dev/null && transcript_log_block "thought" "$reasoning"
        fi

        # ── Branch 1: Native OpenAI Tool Calls Detected ──────────────
        if [ -n "$tool_calls" ] && [ "$tool_calls" != "null" ] && [ "$tool_calls" != "[]" ]; then
            # Append assistant message (with tool_calls) to conversation history
            local asst_msg
            asst_msg=$(jq -nc \
                --arg content "$raw_content" \
                --arg rc "$reasoning" \
                --argjson tc "$tool_calls" \
                '{role: "assistant", content: (if $content == "" then null else $content end), reasoning_content: (if $rc == "" then null else $rc end), tool_calls: $tc}')
            jq --argjson m "$asst_msg" '. += [$m]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"

            # Execute each emitted tool call
            echo "$tool_calls" | jq -c '.[]' | while read -r call; do
                local c_id c_name c_args
                c_id=$(echo "$call" | jq -r '.id')
                c_name=$(echo "$call" | jq -r '.function.name')
                c_args=$(echo "$call" | jq -r '.function.arguments')

                ui_step "Native Tool Call: $c_name"
                echo "Tool Call: $c_name ($c_args)" >> "$history_file"
                declare -f transcript_log &>/dev/null && transcript_log "tool_call" "$c_name: $c_args"

                local tool_resp
                tool_resp=$(native_tools_dispatch "$c_id" "$c_name" "$c_args" "$workdir")

                # Append tool response to messages array
                jq --argjson tr "$tool_resp" '. += [$tr]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"

                local resp_content
                resp_content=$(echo "$tool_resp" | jq -r '.content')
                echo "Observation: $resp_content" >> "$history_file"
                declare -f transcript_log_block &>/dev/null && transcript_log_block "observation ($c_name)" "$resp_content"
                _react_trace "$workdir" "tool_call" "$(jq -cn --arg tool "$c_name" --arg args "$c_args" '{tool:$tool, args:$args}')"

                # Record in macro_memory.json
                local ts_now
                ts_now=$(date '+%Y-%m-%d %H:%M:%S')
                jq --arg ts "$ts_now" --arg tool "$c_name" --arg sum "${resp_content:0:200}" \
                    '.completed_milestones += [{"timestamp": $ts, "tool": $tool, "summary": $sum}]' \
                    "$macro_file" > "${macro_file}.tmp" 2>/dev/null && mv "${macro_file}.tmp" "$macro_file" 2>/dev/null || true

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
            declare -f transcript_log_block &>/dev/null && transcript_log_block "final_response" "$answer"
            _react_trace "$workdir" "task_complete" "$(jq -cn --arg goal "$goal" --arg outcome "$answer" '{goal:$goal, outcome:$outcome, status:"success"}')"
            jq '.status = "COMPLETED"' "$macro_file" > "${macro_file}.tmp" 2>/dev/null && mv "${macro_file}.tmp" "$macro_file" 2>/dev/null || true
            if declare -f transcript_stop &>/dev/null && transcript_active 2>/dev/null; then
                local _tpath
                _tpath=$(transcript_stop)
                [ -n "$_tpath" ] && ui_dim "  Transcript: $_tpath"
            fi
            return 0
        fi

        # Handle text /delegate
        if [[ "$action" == /delegate* ]]; then
            local del_args="${action#/delegate}"
            del_args="${del_args#"${del_args%%[![:space:]]*}"}"
            local del_tier="${del_args%% *}"
            local del_task="${del_args#* }"

            ui_info "Delegating to Tier $del_tier: $del_task"
            declare -f transcript_log &>/dev/null && transcript_log "delegate" "Tier $del_tier: $del_task"
            local subagent_obs
            subagent_obs=$(subagents_spawn "$del_tier" "$del_task" "Parent Goal: $goal" "$workdir" 2>&1)
            declare -f transcript_log_block &>/dev/null && transcript_log_block "subagent_output" "$subagent_obs"
            
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
            declare -f transcript_log &>/dev/null && transcript_log "command" "$action"

            local obs
            obs=$(commands_dispatch "$action" "$workdir" 2>&1)
            local exit_code=$?

            obs=$(printf '%s\n' "$obs" | sed -r 's/\x1B\[[0-9;]*[a-zA-Z]//g')
            if [ ${#obs} -gt 3000 ]; then
                obs="${obs:0:3000}\n... [truncated]"
            fi
            declare -f transcript_log_block &>/dev/null && transcript_log_block "output ($action)" "$obs"
            _react_trace "$workdir" "fallback_command" "$(jq -cn --arg cmd "$action" '{cmd:$cmd}')"

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
            declare -f transcript_log_block &>/dev/null && transcript_log_block "final_response" "$raw_content"
            _react_trace "$workdir" "task_complete" "$(jq -cn --arg goal "$goal" --arg summary "${raw_content:0:200}" '{goal:$goal, summary:$summary, status:"success"}')"
            jq '.status = "COMPLETED"' "$macro_file" > "${macro_file}.tmp" 2>/dev/null && mv "${macro_file}.tmp" "$macro_file" 2>/dev/null || true
            if declare -f transcript_stop &>/dev/null && transcript_active 2>/dev/null; then
                local _tpath
                _tpath=$(transcript_stop)
                [ -n "$_tpath" ] && ui_dim "  Transcript: $_tpath"
            fi
            return 0
        fi

        turn=$((turn + 1))
    done

    ui_warn "Task reached maximum turns ($max_turns)."
    _react_trace "$workdir" "task_halted" "$(jq -cn --arg goal "$goal" --arg reason "max_turns" '{goal:$goal, reason:$reason}')"
    jq '.status = "MAX_TURNS_EXCEEDED"' "$macro_file" > "${macro_file}.tmp" 2>/dev/null && mv "${macro_file}.tmp" "$macro_file" 2>/dev/null || true
    if declare -f transcript_stop &>/dev/null && transcript_active 2>/dev/null; then
        local _tpath
        _tpath=$(transcript_stop)
        [ -n "$_tpath" ] && ui_dim "  Transcript: $_tpath"
    fi
    return 1
}

# Alias agent_run to react_run
agent_run() {
    react_run "$@"
}
