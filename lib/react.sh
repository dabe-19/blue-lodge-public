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
source "$LODGE_DIR/lib/telemetry.sh" 2>/dev/null || true

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

# ── Auto-Compaction Engine (Hierarchical Rich Compaction) ────────────
_react_compact_messages() {
    local session_dir="$1"
    local endpoint_url="$2"
    local workdir="${3:-.}"
    local messages_file="$session_dir/messages.json"
    local memory_file="$session_dir/memory.md"

    ui_dim "Compacting conversation history (2,500 token rich technical budget)..."

    # 1. Extract structural repository & execution manifest from messages_file
    local user_goal
    user_goal=$(jq -r '[.[] | select(.role == "user")][0].content // empty' "$messages_file" 2>/dev/null)
    [ -z "$user_goal" ] && user_goal="Continue task execution."

    local files_touched
    files_touched=$(jq -r '[.[] | select(.role=="assistant") | .tool_calls[]?.function.arguments | fromjson? | .path // empty] | unique | .[]' "$messages_file" 2>/dev/null | head -n 20 | tr '\n' ', ' | sed 's/,[[:space:]]*$//')

    local recent_commands
    recent_commands=$(jq -r '[.[] | select(.role=="assistant") | .tool_calls[]?.function.arguments | fromjson? | .command // empty] | .[-6:] | .[]' "$messages_file" 2>/dev/null | tr '\n' '; ' | sed 's/;[[:space:]]*$//')

    local recent_obs
    recent_obs=$(jq -r '[.[] | select(.role=="tool")][-3:] | .[].content // empty' "$messages_file" 2>/dev/null | head -n 20 | tr '\n' ' ')

    local git_context=""
    if git -C "$workdir" rev-parse --is-inside-work-tree &>/dev/null; then
        local branch_now status_now
        branch_now=$(git -C "$workdir" branch --show-current 2>/dev/null || echo "detached")
        status_now=$(git -C "$workdir" status --short 2>/dev/null | tr '\n' ' ' | head -c 160)
        git_context="Git Branch: $branch_now | Status: ${status_now:-clean}"
    fi

    # 2. Extract trajectory for LLM summarization (tail of history)
    local msgs_summary
    msgs_summary=$(jq -r '.[] | "\(.role): \(.content // .tool_calls // "")"' "$messages_file" 2>/dev/null | tail -n 80)

    local prompt="The following is an ongoing technical agent trajectory for a software engineering task.
${git_context:+Current Environment: $git_context
}Produce an exhaustive, high-fidelity technical summary (up to 2,500 tokens) preserving all critical implementation context:
1. PRIMARY OBJECTIVE: High-level architectural goal.
2. FILES INSPECTED & MODIFIED: Exact file paths, functions, and key lines analyzed or changed.
3. ERRORS & DIAGNOSTICS: Exact error messages, compiler/test output, exit codes, and diagnosed root causes.
4. KEY FACTS DISCOVERED: Environment facts, existing tools, directory structures, and constraints.
5. CONCRETE PENDING ACTIONS: Immediate next steps required to complete the objective.

Trajectory history:
$msgs_summary"

    local r_effort="${LLM_REASONING_EFFORT:-medium}"
    local payload
    payload=$(jq -n \
        --arg sys "You are a senior software architect and technical state summarizer. Produce a dense, comprehensive, high-fidelity technical state summary up to 2500 tokens. Preserve exact file names, functions, error traces, and next concrete actions." \
        --arg prompt "$prompt" \
        --arg r_effort "$r_effort" \
        '{
            messages: [
                {"role": "system", "content": $sys},
                {"role": "user", "content": $prompt}
            ],
            temperature: 0.2,
            max_tokens: 2500,
            reasoning_effort: $r_effort
        }')

    local summary_payload_file="$session_dir/compact_payload.json"
    echo "$payload" > "$summary_payload_file"
    local summary_resp
    summary_resp=$(curl -s --max-time 60 "$endpoint_url/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d @"$summary_payload_file" 2>/dev/null)
    rm -f "$summary_payload_file"

    local summary_text
    summary_text=$(echo "$summary_resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

    # 3. Deterministic Rich Fallback if endpoint fails, times out, or returns empty
    if [ -z "$summary_text" ]; then
        summary_text="## Technical Context Summary (Deterministic Manifest Fallback)
### 1. Primary Objective
${user_goal}

### 2. Environment & Repository State
${git_context:-Standalone workspace: $workdir}

### 3. Files Inspected & Touched
${files_touched:-None recorded}

### 4. Recent Commands Executed
\`\`\`
${recent_commands:-None recorded}
\`\`\`

### 5. Recent Observations & Diagnostics
\`\`\`
${recent_obs:-In progress}
\`\`\`

### 6. Working Notice
Trajectory auto-compacted deterministically to recover context headroom while preserving structural file and tool history."
    fi

    echo "## Context Summary (Auto-Compacted):" > "$memory_file"
    echo "$summary_text" >> "$memory_file"

    # 4. Extract safe working-memory pair (last completed single assistant-tool round)
    local recent_pair
    recent_pair=$(jq -c '
        if length >= 2 and .[-1].role == "tool" then
            ([.[] | select(.role == "assistant")] | .[-1]) as $last_asst |
            if ($last_asst.tool_calls | length) == 1 and .[-2].role == "assistant" then
                [.[-2], .[-1]]
            else
                []
            end
        else
            []
        end
    ' "$messages_file" 2>/dev/null || echo "[]")

    # 5. Reconstruct clean, schema-compliant messages array
    local sys_msg
    sys_msg=$(jq '.[0] // empty' "$messages_file" 2>/dev/null)
    if ! echo "$sys_msg" | jq -e '.role == "system"' >/dev/null 2>&1; then
        sys_msg='{"role": "system", "content": "You are George, senior technical companion and builder."}'
    fi

    jq -n \
        --argjson sys "$sys_msg" \
        --arg goal "$user_goal" \
        --arg mem "$summary_text" \
        --argjson recent "$recent_pair" \
        '
            [
                $sys,
                {"role": "user", "content": ("PRIMARY OBJECTIVE:\n" + $goal)},
                {"role": "assistant", "content": ("[PREVIOUS CONTEXT COMPACTED - TECHNICAL STATE SUMMARY]:\n" + $mem)}
            ] + (if ($recent | length) == 2 then [
                {"role": "user", "content": "Continue executing the task based on the technical progress summary above. Here was your most recent working tool execution before compaction:"},
                $recent[0],
                $recent[1],
                {"role": "user", "content": "Proceed with your next action based on the summary and above observation."}
            ] else [
                {"role": "user", "content": "Continue executing the task based on the technical progress summary above. Advance the primary objective using native tools."}
            ] end)
        ' > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"

    ui_ok "Context successfully compacted with 2,500 token technical budget."
    declare -f transcript_log_block &>/dev/null && transcript_log_block "auto-compaction" "$summary_text"
    _react_trace "$workdir" "auto_compaction" "$(jq -cn --arg sum "$summary_text" '{summary:$sum}')"
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
    local max_turns="${3:-${AGENT_MAX_TURNS:-${AGENT_MAX_MILESTONES:-9999}}}"
    local agent_temp="${AGENT_LLM_TEMPERATURE:-0.2}"
    local agent_max_tok="${AGENT_MAX_TOKENS:-16384}"
    local tool_filter="${6:-${REACT_TOOL_FILTER:-}}"

    # Robust argument polymorphism: if arg 3 is non-numeric, it was passed as profile/tool_filter
    if [ -n "${3:-}" ] && ! [[ "$3" =~ ^[0-9]+$ ]]; then
        tool_filter="$3"
        max_turns="${AGENT_MAX_TURNS:-${AGENT_MAX_MILESTONES:-9999}}"
    fi

    # Zero-latency task classifier: if tool_filter is empty, "all", or "auto", classify by objective
    if [ -z "$tool_filter" ] || [ "$tool_filter" = "all" ] || [ "$tool_filter" = "auto" ]; then
        if declare -f native_tools_classify_profile &>/dev/null; then
            tool_filter=$(native_tools_classify_profile "$goal")
        else
            tool_filter="default"
        fi
    fi

    if [ -z "$goal" ]; then
        ui_err "Task description required."
        return 1
    fi

    # 1. Cascade to highest active endpoint tier
    if ! endpoints_cascade; then
        ui_err "No active inference endpoints available. Check endpoints.conf or start a backend."
        return 1
    fi

    local agent_temp="${AGENT_LLM_TEMPERATURE:-${ACTIVE_ENDPOINT_TEMPERATURE:-0.2}}"
    local agent_topp="${AGENT_LLM_TOP_P:-${ACTIVE_ENDPOINT_TOP_P:-0.95}}"
    local req_timeout="${LODGE_TIMEOUT:-${REACT_TIMEOUT:-${ACTIVE_ENDPOINT_TIMEOUT:-600}}}"

    ui_ok "Active Engine: Tier $ACTIVE_TIER [$ACTIVE_ENDPOINT_NAME] ($ACTIVE_ENDPOINT_MODEL @ $ACTIVE_ENDPOINT_URL)"
    ui_dim "Context Window: $ACTIVE_ENDPOINT_CONTEXT tokens | Compaction Threshold: $ACTIVE_ENDPOINT_COMPACT_TOKENS tokens"
    ui_dim "Task Profile: '$tool_filter'"

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

    local session_id="${session_id_arg:-session_$(date +%Y%m%d_%H%M%S)_$$}"
    local session_dir="$gdir/workspaces/$session_id"
    mkdir -p "$session_dir"

    local history_file="$session_dir/trajectory.log"
    local messages_file="$session_dir/messages.json"
    local memory_file="$session_dir/memory.md"
    : > "$history_file"

    # Export active task memory slug and session workspace paths
    if declare -f memory_get_task_slug &>/dev/null; then
        export AGENT_ACTIVE_TASK_SLUG="$(memory_get_task_slug "$goal")"
    else
        export AGENT_ACTIVE_TASK_SLUG="active_report_$(date '+%H%M%S')"
    fi
    export AGENT_TASK_WORKSPACE="$session_dir"
    export AGENT_TASK_WORKSPACE_REL=".george/workspaces/$session_id"
    export AGENT_ACTIVE_SESSION_DIR="$session_dir"
    export AGENT_ACTIVE_SESSION_ID="$session_id"
    declare -f memory_register_files &>/dev/null && memory_register_files "$workdir"

    # Register task with Sovereign Telemetry Ring
    if declare -f telemetry_task_start &>/dev/null; then
        local _t_log=""
        [ -n "${session_log:-}" ] && _t_log="$session_log"
        local _t_pty="${CRON_POPUP_PID:-${PTY_PID:-0}}"
        local _t_trans="${_TRANSCRIPT_FILE:-}"
        telemetry_task_start "$session_id" "react" "$workdir" "$_t_log" "$_t_pty" "$_t_trans" >/dev/null 2>&1 || true
    fi

    # Auto-start configured MCP servers if enabled
    declare -f mcp_ensure_running &>/dev/null && mcp_ensure_running

    # 3. Assemble Dynamic Copilot-Style Context & Tool Schemas
    ui_dim "Assembling context pipeline and native tool registry..."
    local sys_prompt
    sys_prompt=$(context_engine_build "$goal" "$workdir" "$ACTIVE_TIER" "${tool_filter:-default}")

    local active_tools_file="$session_dir/active_tools.json"
    local tools_schema
    if declare -f native_tools_resolve_profile &>/dev/null; then
        tools_schema=$(native_tools_resolve_profile "${tool_filter:-default}")
    elif declare -f native_tools_get_schemas &>/dev/null; then
        tools_schema=$(native_tools_get_schemas "$tool_filter")
    else
        tools_schema=$(native_tools_get_all_schemas)
    fi
    echo "$tools_schema" > "$active_tools_file"

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
    local consecutive_empty_turns=0
    local thrashing_target_streak=0
    local last_invoked_tool=""

    echo "PRIMARY OBJECTIVE: $goal" >> "$history_file"
    local display_goal="$goal"
    if [[ "$goal" == *"OBJECTIVE:"* ]]; then
        display_goal="${goal##*OBJECTIVE:}"
        display_goal="${display_goal#"${display_goal%%[![:space:]]*}"}"
        display_goal="${display_goal%%$'\n'*}"
        display_goal="${display_goal%%\\n*}"
    else
        display_goal=$(echo "$goal" | head -n 1)
    fi
    ui_info "Starting Task: ${display_goal:0:140}"

    while [ "$turn" -le "$max_turns" ]; do
        printf "\n${C_BOLD}${C_CYAN}── Turn %d/%d ──────────────────────────────${C_RESET}\n" "$turn" "$max_turns"

        # Telemetry heartbeat and PTY / pipe liveness check
        if declare -f telemetry_task_heartbeat &>/dev/null; then
            telemetry_task_heartbeat "$session_id" "$turn" "${last_invoked_tool:-}" "$max_turns"
        fi

        # Cooperative scheduling pause for background remediation tasks
        if [ "${AGENT_SOVEREIGN_REMEDIATION:-0}" -eq 1 ]; then
            if declare -f remediation_cooperative_pause &>/dev/null; then
                remediation_cooperative_pause
            fi
        fi

        # Pipe & PTY Integrity Watchdog
        if [ -n "${PTY_PID:-}" ] && [ "${PTY_PID:-0}" -ne 0 ]; then
            if ! kill -0 "$PTY_PID" 2>/dev/null; then
                ui_warn "Session monitor (PID $PTY_PID) ended unexpectedly. Closing turn loop."
                if declare -f telemetry_record_anomaly &>/dev/null; then
                    telemetry_record_anomaly "$session_id" "PROCESS_STALL" "react.sh" "PTY monitor PID $PTY_PID severed; unblocking task" >/dev/null 2>&1 || true
                fi
                break
            fi
        fi

        # Refresh active tools schema if tool_search mounted new capabilities in previous turn
        if [ -s "$active_tools_file" ]; then
            tools_schema=$(cat "$active_tools_file")
        fi

        # Calibrated countdown advisory starting 10 turns before ceiling
        local countdown_trigger=$((max_turns - 10))
        [ "$max_turns" -lt 15 ] && countdown_trigger=$((max_turns - 4))
        [ "$max_turns" -le 5 ] && countdown_trigger=$((max_turns - 1))
        if [ "$turn" -ge "$countdown_trigger" ] && [ "$turn" -lt "$max_turns" ]; then
            local rem=$((max_turns - turn))
            ui_warn "Turn budget: Turn $turn/$max_turns ($rem turn(s) remaining)."
            local alert_msg
            if [ "$tool_filter" = "social" ] || [ "$tool_filter" = "chat" ]; then
                if [ "$rem" -le 2 ]; then
                    alert_msg="[SYSTEM ADVISORY: Turn $turn/$max_turns — $rem turn(s) remaining. Conclude your response to the user.]"
                else
                    alert_msg="[SYSTEM ADVISORY: Turn $turn/$max_turns — $rem turns remaining. Begin wrapping up your thoughts.]"
                fi
            else
                if [ "$rem" -ge 7 ]; then
                    alert_msg="[SYSTEM ADVISORY: Turn $turn/$max_turns — $rem turns remaining. You have ample budget, but begin converging your investigation toward a concrete fix.]"
                elif [ "$rem" -ge 4 ]; then
                    alert_msg="[SYSTEM ADVISORY: Turn $turn/$max_turns — $rem turns remaining. Transition from research to execution: apply your code edits and execute automated tests.]"
                elif [ "$rem" -ge 2 ]; then
                    alert_msg="[SYSTEM ADVISORY: Turn $turn/$max_turns — $rem turns remaining. Final verification: ensure tests pass cleanly, stage changes, and prepare your final summary.]"
                else
                    alert_msg="[SYSTEM ADVISORY: FINAL TURN ($turn/$max_turns — 1 turn remaining). Conclude your task now and present your final deliverable and summary.]"
                fi
            fi
            jq --arg msg "$alert_msg" \
                'if (.[-1].content | test("SYSTEM ADVISORY|APPROACHING TURN CEILING|SYSTEM NOTICE"; "i")) then .[-1].content = $msg else . += [{"role": "user", "content": $msg}] end' \
                "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
        fi

        # Pre-flight token re-estimation from messages_file byte size + native tools overhead (~4000 tokens)
        if [ -f "$messages_file" ]; then
            local _current_bytes
            _current_bytes=$(wc -c < "$messages_file" 2>/dev/null || echo 0)
            local _est_tokens=$(( (_current_bytes * 10 / 35) + 4000 ))
            if [ "$_est_tokens" -gt "$running_tokens" ]; then
                running_tokens="$_est_tokens"
            fi
        fi

        # Check compaction threshold
        if [ "$running_tokens" -ge "$ACTIVE_ENDPOINT_COMPACT_TOKENS" ]; then
            _react_compact_messages "$session_dir" "$ACTIVE_ENDPOINT_URL" "$workdir"
            running_tokens=0
        fi

        # Prepare chat completions payload with runtime /limits settings
        local r_effort="${LLM_REASONING_EFFORT:-medium}"
        local payload_file="$session_dir/payload_turn_${turn}.json"
        local payload
        payload=$(jq -n \
            --slurpfile msgs "$messages_file" \
            --argjson tools "$tools_schema" \
            --arg temp "$agent_temp" \
            --arg topp "$agent_topp" \
            --arg max_tok "$agent_max_tok" \
            --arg r_effort "$r_effort" \
            '{
                messages: $msgs[0],
                tools: $tools,
                tool_choice: "auto",
                temperature: ($temp | tonumber),
                top_p: ($topp | tonumber),
                repeat_penalty: 1.15,
                frequency_penalty: 0.20,
                presence_penalty: 0.10,
                max_tokens: ($max_tok | tonumber),
                reasoning_effort: $r_effort,
                stream: true,
                stream_options: {include_usage: true},
                stop: ["<|im_end|>", "</tool_call>", "<|endoftext|>"]
            }')
        echo "$payload" > "$payload_file"

        # Log turn boundary and prompt to transcript & prompt log
        declare -f transcript_section &>/dev/null && transcript_section "Turn $turn / $max_turns"
        declare -f transcript_log_prompt &>/dev/null && transcript_log_prompt "react-turn-$turn" "$payload" "$sys_prompt"

        local raw_content="" reasoning="" tool_calls="[]" p_tok=0 comp_tok=0
        local stream_cache="$session_dir/stream_turn_${turn}.json"

        # Stream response chunks via curl SSE (stream reasoning tokens by default in ReAct unless suppressed)
        local think_mode="${LODGE_THINK_STREAM:-1}"
        if [ "${LODGE_NOTHINK:-0}" -eq 1 ] || [ "${LODGE_THINK_STREAM:-1}" -eq 0 ]; then
            think_mode=0
        fi

        # Detect interactive/unbuffered awk support (-W interactive for mawk on Termux/Debian)
        local _awk_opt=""
        if awk --version 2>&1 | grep -iq mawk; then
            _awk_opt="-W interactive"
        fi

        # Launch ambient craftsman prefill ticker during prompt evaluation
        declare -f ui_prefill_ticker_start &>/dev/null && ui_prefill_ticker_start "$session_dir"

        # Execute real-time streaming SSE pipeline (filter SSE comment/keepalive lines to protect jq parser)
        local stream_err_file="$session_dir/stream_err_turn_${turn}.log"
        curl -s -N --keepalive-time 10 --max-time "$req_timeout" "$ACTIVE_ENDPOINT_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d @"$payload_file" 2>"$stream_err_file" | \
        sed -u -e '/^:/d' -e '/^data: /!d' -e 's/^data: //' -e '/^\[DONE\]/d' -e '/^[[:space:]]*$/d' | \
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
        awk -v think_mode="$think_mode" -v sc="$stream_cache" -v tpid_file="$session_dir/.prefill_ticker.pid" $_awk_opt '
        BEGIN {
            color = (think_mode == 2 ? "\033[36m" : "\033[90m");
            in_thought = 0;
            got_chunk = 0;
        }
        {
            if (!got_chunk) {
                got_chunk = 1;
                if (tpid_file != "") {
                    system("tpid=$(cat " tpid_file " 2>/dev/null); rm -f " tpid_file " 2>/dev/null; if [ -n \"$tpid\" ]; then kill -9 $tpid 2>/dev/null; fi; printf \"\\r\\033[2K\" >&2");
                }
            }
            print $0 > sc;
            fflush(sc);
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
        declare -f ui_prefill_ticker_stop &>/dev/null && ui_prefill_ticker_stop "$session_dir"

        if [ ! -s "$stream_cache" ]; then
            # Graceful fallback: synchronous non-stream request
            local err_preview=""
            [ -s "$stream_err_file" ] && err_preview=$(tr '\n' ' ' < "$stream_err_file" | tr -s ' ' | head -c 120)
            if [ -n "$err_preview" ]; then
                ui_dim "Stream interrupted ($err_preview); querying synchronous fallback..."
            else
                ui_dim "Stream interrupted; querying synchronous fallback..."
            fi
            local fallback_payload_file="$session_dir/fallback_payload_turn_${turn}.json"
            jq '.stream = false | del(.stream_options)' "$payload_file" > "$fallback_payload_file"
            local fb_timeout="${LODGE_TIMEOUT:-${REACT_TIMEOUT:-${ACTIVE_ENDPOINT_TIMEOUT:-600}}}"
            local resp_json
            resp_json=$(curl -s --keepalive-time 10 --max-time "$fb_timeout" "$ACTIVE_ENDPOINT_URL/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d @"$fallback_payload_file" 2>/dev/null)

            if [ -z "$resp_json" ]; then
                ui_warn "Empty response from endpoint $ACTIVE_ENDPOINT_URL. Retrying once after 3s..."
                sleep 3
                resp_json=$(curl -s --max-time "$fb_timeout" "$ACTIVE_ENDPOINT_URL/v1/chat/completions" \
                    -H "Content-Type: application/json" \
                    -d @"$fallback_payload_file" 2>/dev/null)
            fi

            if [ -z "$resp_json" ]; then
                ui_err "Empty response from endpoint $ACTIVE_ENDPOINT_URL."
                _react_trace "$workdir" "error" '{"error":"empty_response"}'
                if declare -f transcript_stop &>/dev/null && transcript_active 2>/dev/null; then
                    transcript_stop >/dev/null 2>&1
                fi
                return 1
            fi

            local endpoint_err
            endpoint_err=$(echo "$resp_json" | jq -r '.error.message // .error // empty' 2>/dev/null)
            if [ -n "$endpoint_err" ]; then
                ui_err "Inference endpoint error: $endpoint_err"
                if [[ "$endpoint_err" =~ context|token|length|maximum ]]; then
                    ui_warn "Context length exceeded! Triggering emergency auto-compaction..."
                    _react_compact_messages "$session_dir" "$ACTIVE_ENDPOINT_URL" "$workdir"
                    running_tokens=0
                    consecutive_empty_turns=0
                    turn=$((turn + 1))
                    continue
                fi
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

        # Accounting for token consumption:
        # Calculate actual message text character volume (~3.5 chars / token)
        local _chars=0
        [ -f "$messages_file" ] && _chars=$(wc -c < "$messages_file" 2>/dev/null || echo 0)
        local _est_p_tok=$(( _chars * 10 / 35 ))

        # If server didn't emit usage metrics or emitted prefix-cache delta (< actual message text),
        # enforce actual character-based token floor to prevent masking context bloat
        if [ "${p_tok:-0}" -lt "$_est_p_tok" ]; then
            p_tok="$_est_p_tok"
        fi
        if [ "${comp_tok:-0}" -le 0 ]; then
            local _resp_chars=$(( ${#raw_content} + ${#reasoning} ))
            comp_tok=$(( _resp_chars * 10 / 35 ))
        fi

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
            # Sanitize and repair tool_calls arguments to ensure valid JSON and extract embedded XML parameters
            if command -v python3 &>/dev/null; then
                tool_calls=$(echo "$tool_calls" | python3 -c '
import sys, json, re

def sanitize_one(raw):
    if not raw or raw == "null":
        return "{}"
    extracted = {}
    try:
        j = json.loads(raw)
        if isinstance(j, dict):
            for k, v in j.items():
                if isinstance(v, str):
                    clean_v = re.split(r"</?(?:parameter|function|tool_call|invoke|output)[^>]*>", v)[0].strip()
                    extracted[k] = clean_v
                else:
                    extracted[k] = v
    except Exception:
        for m in re.finditer(r"\"([a-zA-Z0-9_]+)\"\s*:\s*\"([^\"<]+)", raw):
            extracted[m.group(1)] = m.group(2).strip()

    if "<parameter" in raw or "</parameter>" in raw:
        xml_matches = re.findall(r"<parameter\s*(?:=\s*)?([a-zA-Z0-9_]+)\s*>\s*(.*?)(?:</parameter>|(?=<parameter)|(?=</function>)|$)", raw, re.DOTALL)
        for k, v in xml_matches:
            v_clean = v.strip()
            v_clean = re.sub(r"</?(?:parameter|function|tool_call|invoke|output)[^>]*>", "", v_clean).strip()
            if re.match(r"^\d+$", v_clean):
                extracted[k] = int(v_clean)
            else:
                extracted[k] = v_clean

    if "command" in extracted and isinstance(extracted["command"], str):
        c = extracted["command"]
        c = re.split(r"</?(?:parameter|function|tool_call|invoke|output)[^>]*>", c)[0].strip()
        c = re.sub(r"head -n(\s*(\||&|;|$))", r"head -n 10\1", c)
        c = re.sub(r"git rev-parse\s+([^\s]+)\s+--short", r"git rev-parse --short \1", c)
        extracted["command"] = c

    if "path" in extracted and isinstance(extracted["path"], str):
        p = extracted["path"].split("\n")[0].strip()
        if p.startswith("home/wsl-ops/"):
            p = "/" + p
        extracted["path"] = p

    return json.dumps(extracted) if extracted else raw

try:
    calls = json.load(sys.stdin)
    if isinstance(calls, list):
        for c in calls:
            fn = c.get("function", {})
            args = fn.get("arguments", "")
            fn["arguments"] = sanitize_one(args)
        print(json.dumps(calls))
    else:
        print("[]")
except Exception:
    print("[]")
' 2>/dev/null || echo "$tool_calls")
            else
                tool_calls=$(echo "$tool_calls" | jq 'map(
                    .function.arguments as $a |
                    if (try ($a | fromjson) catch null) != null then
                        .function.arguments = (($a | fromjson | walk(if type == "string" then split("</parameter>")[0] | split("<function")[0] | split("</invoke>")[0] | split("</output>")[0] | split("<tool_call")[0] | gsub("</?(parameter|function|tool_call|invoke|output)[^>]*>"; "") | sub("^[[:space:]]+|[[:space:]]+$"; "") else . end)) | tojson)
                    elif (try (($a + "\"}") | fromjson) catch null) != null then
                        .function.arguments += "\"}"
                    elif (try (($a + "}") | fromjson) catch null) != null then
                        .function.arguments += "}"
                    else
                        .function.arguments = ("{\"error\":\"malformed_arguments\",\"raw\":" + ($a | @json) + "}")
                    end
                )' 2>/dev/null || echo "[]")
            fi

            # Validate tool_calls is well-formed JSON array before passing to --argjson
            if ! echo "$tool_calls" | jq -e 'type == "array"' >/dev/null 2>&1; then
                tool_calls="[]"
            fi

            # Append assistant message (with tool_calls) to conversation history
            local asst_msg
            asst_msg=$(jq -nc \
                --arg content "$raw_content" \
                --arg rc "$reasoning" \
                --argjson tc "$tool_calls" \
                '{role: "assistant", content: (if $content == "" then null else $content end), reasoning_content: (if $rc == "" then null else $rc end), tool_calls: $tc}' 2>/dev/null)
            if [ -n "$asst_msg" ]; then
                jq --argjson m "$asst_msg" '. += [$m]' "$messages_file" > "${messages_file}.tmp" 2>/dev/null && mv "${messages_file}.tmp" "$messages_file"
            fi

            # Execute each emitted tool call
            local tool_exhausted=0
            while read -r call; do
                local c_id c_name c_args
                c_id=$(echo "$call" | jq -r '.id')
                c_name=$(echo "$call" | jq -r '.function.name')
                c_args=$(echo "$call" | jq -r '.function.arguments')

                last_invoked_tool="$c_name"

                ui_step "Native Tool Call: $c_name"
                echo "Tool Call: $c_name ($c_args)" >> "$history_file"
                declare -f transcript_log &>/dev/null && transcript_log "tool_call" "$c_name: $c_args"

                if [ "${LODGE_DEBUG:-0}" -eq 1 ]; then
                    printf "   ${C_BOLD}${C_BLUE}[DEBUG: Tool Args]${C_RESET} %s\n" "$c_args"
                fi

                local tool_resp
                tool_resp=$(native_tools_dispatch "$c_id" "$c_name" "$c_args" "$workdir")

                # Guarantee tool_resp is a well-formed JSON object before passing to jq
                if ! echo "$tool_resp" | jq -e 'type == "object"' >/dev/null 2>&1; then
                    local _extracted
                    _extracted=$(echo "$tool_resp" | sed -n '/^{/,$p' | jq -c 'select(type == "object")' 2>/dev/null | tail -n 1 || true)
                    if [ -n "$_extracted" ]; then
                        tool_resp="$_extracted"
                    else
                        tool_resp=$(jq -nc \
                            --arg id "$c_id" \
                            --arg name "$c_name" \
                            --arg content "$tool_resp" \
                            '{role: "tool", tool_call_id: $id, name: $name, content: $content}')
                    fi
                fi

                local resp_content
                resp_content=$(echo "$tool_resp" | jq -r '.content // empty')
                local max_tool_chars="${REACT_MAX_OBSERVATION_CHARS:-16000}"
                if [ "${#resp_content}" -gt "$max_tool_chars" ]; then
                    local truncated_note=$'\n\n'"[Observation truncated at ${max_tool_chars} characters to protect context budget. Narrow your query, paginate with start_line, or use targeted grep/symbol tools.]"
                    resp_content="${resp_content:0:$max_tool_chars}${truncated_note}"
                    tool_resp=$(echo "$tool_resp" | jq --arg c "$resp_content" '.content = $c')
                fi

                # Append tool response to messages array
                jq --argjson tr "$tool_resp" '. += [$tr]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"

                echo "Observation: $resp_content" >> "$history_file"
                declare -f transcript_log_block &>/dev/null && transcript_log_block "observation ($c_name)" "$resp_content"
                _react_trace "$workdir" "tool_call" "$(jq -cn --arg tool "$c_name" --arg args "$c_args" '{tool:$tool, args:$args}')"

                # Check for tool errors and track cognitive thrashing
                local is_tool_failure=0
                if echo "$resp_content" | grep -qE '(\bERROR\b|ERROR:|Command failed|pdftotext: not found|ModuleNotFoundError|ImportError|Traceback \(most recent call last\)|No such file or directory|failed \(exit [1-9]|SCRIPT_EXIT=[1-9]|SyntaxError:)'; then
                    is_tool_failure=1
                fi

                if [ "$is_tool_failure" -eq 1 ]; then
                    thrashing_target_streak=$((thrashing_target_streak + 1))
                    if declare -f telemetry_record_anomaly &>/dev/null; then
                        telemetry_record_anomaly "$session_id" "CAPABILITY_DEFICIT" "$c_name" "Failure on $c_name (Strike $thrashing_target_streak): ${resp_content:0:200}" >/dev/null 2>&1 || true
                    fi

                    if [ "$thrashing_target_streak" -eq 3 ]; then
                        ui_warn "3 consecutive tool failures detected targeting $c_name. Injecting Metacognitive Resilience Frame."
                        local warn_pivot="[SYSTEM ADVISORY — AUTONOMOUS ADAPTIVE PIVOT REQUIRED]
Action targeting '$c_name' has failed 3 consecutive times. Repeating identical commands or syntax tweaks is strictly prohibited.
Execute the Metacognitive Pathfinding Protocol:
1. ABSTRACT INTENT: Identify the fundamental objective of this action (decouple the intended result from the specific tool or command).
2. SURVEY CAPABILITIES: Use discovery commands (e.g. bash inspection, file_search, or grep_search) to locate alternative libraries, tools, fallback providers, or configurations present in the repository.
3. SUBSTITUTE OR ADAPT: Formulate a distinct alternative pathway (e.g. secondary provider, fallback package, local mock, or environment reconfiguration).
4. VERIFY: Execute and validate the alternative pathway."
                        jq --arg w "$warn_pivot" '. += [{"role": "user", "content": $w}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                    elif [ "$thrashing_target_streak" -ge 6 ]; then
                        ui_err "Hard capability ceiling reached: 6 consecutive unyielding tool failures ($c_name). Preserving incident and halting."
                        if declare -f telemetry_preserve_incident &>/dev/null; then
                            telemetry_preserve_incident "$session_id" "CAPABILITY_EXHAUSTED" "Repeated tool failure on $c_name" "$workdir" >/dev/null 2>&1 || true
                        fi
                        if declare -f telemetry_triage_operational_failure &>/dev/null; then
                            telemetry_triage_operational_failure "$c_name" "CAPABILITY_EXHAUSTED" "Persistent tool failure on $c_name reached strike ceiling" "${resp_content:0:500}" "$workdir" >/dev/null 2>&1 || true
                        fi
                        if declare -f telemetry_task_end &>/dev/null; then
                            telemetry_task_end "$session_id" 1 "CAPABILITY_EXHAUSTED" >/dev/null 2>&1 || true
                        fi
                        export AGENT_ACTIVE_SESSION_ID=""
                        jq '.status = "CAPABILITY_EXHAUSTED"' "$macro_file" > "${macro_file}.tmp" 2>/dev/null && mv "${macro_file}.tmp" "$macro_file" 2>/dev/null || true
                        tool_exhausted=1
                        break
                    fi
                else
                    thrashing_target_streak=0
                    if declare -f telemetry_reset_consecutive_failures &>/dev/null; then
                        telemetry_reset_consecutive_failures "$session_id" >/dev/null 2>&1 || true
                    fi
                fi

                # Record in macro_memory.json
                local ts_now
                ts_now=$(date '+%Y-%m-%d %H:%M:%S')
                jq --arg ts "$ts_now" --arg tool "$c_name" --arg sum "${resp_content:0:200}" \
                    '.completed_milestones += [{"timestamp": $ts, "tool": $tool, "summary": $sum}]' \
                    "$macro_file" > "${macro_file}.tmp" 2>/dev/null && mv "${macro_file}.tmp" "$macro_file" 2>/dev/null || true

                # Brief UI preview or full debug observation
                if [ "${LODGE_DEBUG:-0}" -eq 1 ]; then
                    printf "   ${C_BOLD}${C_GRAY}[DEBUG: Observation (${#resp_content} chars)]${C_RESET}\n%s\n" "$resp_content"
                else
                    local preview
                    preview=$(echo "$resp_content" | head -n 3 | tr '\n' ' ')
                    printf "${C_DIM}  ↳ Result: %s${C_RESET}\n" "$preview"
                fi

                declare -f transcript_log_jsonl &>/dev/null && transcript_log_jsonl "$goal" "${reasoning:-${think_content:-}}" "${c_name:-tool}(${c_args:-})" "$resp_content"
            done < <(echo "$tool_calls" | jq -c '.[]')

            if [ "$tool_exhausted" -eq 1 ]; then
                return 1
            fi

            consecutive_empty_turns=0
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
            jq --arg ans "$answer" '. += [{"role": "assistant", "content": $ans}]' "$messages_file" > "${messages_file}.tmp" 2>/dev/null && mv "${messages_file}.tmp" "$messages_file" 2>/dev/null || true
            journal_write "reflection" "Goal achieved: $goal. Result: $answer" 2>/dev/null || true
            declare -f transcript_log_block &>/dev/null && transcript_log_block "final_response" "$answer"
            _react_trace "$workdir" "task_complete" "$(jq -cn --arg goal "$goal" --arg outcome "$answer" '{goal:$goal, outcome:$outcome, status:"success"}')"
            jq '.status = "COMPLETED"' "$macro_file" > "${macro_file}.tmp" 2>/dev/null && mv "${macro_file}.tmp" "$macro_file" 2>/dev/null || true
            if declare -f telemetry_task_end &>/dev/null; then
                telemetry_task_end "$session_id" 0 "COMPLETED" >/dev/null 2>&1 || true
            fi
            export AGENT_ACTIVE_SESSION_ID=""
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

            if [ "$exit_code" -ne 0 ]; then
                if declare -f telemetry_record_anomaly &>/dev/null; then
                    telemetry_record_anomaly "$session_id" "SHELL_RUNTIME" "$action" "Fallback command failed with exit $exit_code: ${obs:0:200}" >/dev/null 2>&1 || true
                fi
                if declare -f telemetry_triage_operational_failure &>/dev/null; then
                    telemetry_triage_operational_failure "$action" "SHELL_RUNTIME" "Fallback command execution failure ($action)" "${obs:0:500}" "$workdir" >/dev/null 2>&1 || true
                fi
            fi

            obs=$(printf '%s\n' "$obs" | sed -r 's/\x1B\[[0-9;]*[a-zA-Z]//g')
            local max_fb_chars="${REACT_MAX_OBSERVATION_CHARS:-16000}"
            if [ ${#obs} -gt "$max_fb_chars" ]; then
                obs="${obs:0:$max_fb_chars}\n... [truncated]"
            fi
            declare -f transcript_log_block &>/dev/null && transcript_log_block "output ($action)" "$obs"
            _react_trace "$workdir" "fallback_command" "$(jq -cn --arg cmd "$action" '{cmd:$cmd}')"

            jq --arg obs "Command $action (exit $exit_code):\n$obs" \
                '. += [{"role": "user", "content": $obs}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"

            turn=$((turn + 1))
            continue
        fi

        # If model provided answer directly without tool calls
        if [ -n "$raw_content" ]; then
            # Premature Exit Guard: In multi-turn tasks where output
            # contains forward-looking planning text or preambles rather than a final deliverable, advance to tool execution.
            local is_premature_plan=0
            if [ "$max_turns" -gt 1 ]; then
                if [ "${AGENT_SOVEREIGN_REMEDIATION:-0}" -eq 1 ] && [ "$turn" -lt 5 ]; then
                    is_premature_plan=1
                elif echo "$raw_content" | grep -qiE "(I will|I'll|I plan to|Let's outline|Step 1|First step|I need to check|I need to inspect|Let's begin by|Before making changes|I will pull|I'll pull|Let me fetch|I am going to|I'm going to|I will search|I'll search|Let me pull|I'll gather|I will gather|I'll start by|I will start by|Let me survey|Let me inspect|Let me explore|Let me examine|I will examine|I'll look at|ground this in|survey what is|Let me now|Let me proceed|I will now|Next step|Proceeding to|I will execute|Let me execute)"; then
                    is_premature_plan=1
                elif echo "$raw_content" | grep -qE ":[[:space:]]*$"; then
                    is_premature_plan=1
                elif [ ${#raw_content} -lt 450 ] && echo "$raw_content" | grep -qiE "\b(will pull|will fetch|will search|will look up|will inspect|will check|will investigate|going to search|going to pull|going to fetch|going to ground|execute real tool|call tools|invoke tools|execute tool)\b"; then
                    is_premature_plan=1
                fi
            fi

            # Zero-Tool Research Verification Guard:
            # If the task requires research/investigation and the model attempts to exit on early turns
            # without executing any retrieval tools (web_search, web_fetch, pdf_read, file_read, etc.),
            # intercept the unverified response and demand real source retrieval.
            local is_unverified_research=0
            if [ "$turn" -le 2 ] && [ "$max_turns" -gt 1 ]; then
                local is_research_task=0
                if echo "${goal,,}" | grep -qiE '\b(research|report|dossier|background on|investigate|due diligence|osint|deep dive|fact check)\b'; then
                    is_research_task=1
                elif [[ "${tool_filter:-}" =~ research ]] && echo "${goal,,}" | grep -qiE '\b(research|report|dossier|background|investigate|due diligence|osint|latest|recent|news|current)\b'; then
                    is_research_task=1
                fi
                if [ "$is_research_task" -eq 1 ]; then
                    if [ ! -f "$history_file" ] || ! grep -qE "(Tool Call: web_|Tool Call: fetch|Tool Call: pdf_read|Tool Call: file_read|Tool Call: github_search|Action: .*web|Action: .*curl|Action: .*search)" "$history_file"; then
                        is_unverified_research=1
                    fi
                fi
            fi

            # Zero-Tool Implementation Verification Guard for Code / Engineering Tasks:
            # If the task requires building, coding, testing, refactoring, extending, or modifying,
            # and no implementation/execution tools (file_write, file_edit, symbol_patch, git_commit, etc.)
            # have completed, prevent premature declaration of task completion and force tool execution.
            local is_unverified_code=0
            if [ "$max_turns" -gt 1 ]; then
                local is_code_task=0
                if echo "${goal,,}" | grep -qiE '\b(extend|implement|develop|fix|refactor|test|patch|code|write|create|build|modify|phytology|protocol|feature|graft|audit|remediat|branch|pr|pull request|commit)\b'; then
                    is_code_task=1
                fi
                if [ "$is_code_task" -eq 1 ]; then
                    if [ ! -f "$history_file" ] || ! grep -qE "(Tool Call: file_write|Tool Call: file_edit|Tool Call: symbol_patch|Tool Call: git_commit|Tool Call: git_push|Tool Call: gitea_pr|Tool Call: gitea_issue_close|Action: .*commit|Action: .*push|git checkout -b|git commit|git branch feature)" "$history_file"; then
                        is_unverified_code=1
                    fi
                fi
            fi

            if [ "$is_premature_plan" -eq 1 ]; then
                jq --arg ans "$raw_content" '. += [{"role": "assistant", "content": $ans}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                local adv="[SYSTEM ADVISORY: Plan acknowledged. Proceed immediately to execute your plan by calling the required native tools (e.g. web_search, web_fetch, file_read, code_outline, code_symbol_get, file_grep, dir_list, bash_exec). Emit conversational markdown ONLY when all tool actions are complete and the deliverable is 100% finished.]"
                jq --arg p "$adv" '. += [{"role": "user", "content": $p}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                consecutive_empty_turns=0
                turn=$((turn + 1))
                continue
            elif [ "$is_unverified_research" -eq 1 ]; then
                ui_dim "  [guard] Intercepted Turn $turn draft: zero research tools executed for research task"
                jq --arg ans "$raw_content" '. += [{"role": "assistant", "content": $ans}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                local adv="[SYSTEM ADVISORY: Research verification required. You produced a draft summary on Turn $turn without executing any retrieval tools (web_search, web_fetch, pdf_read, file_read). You MUST call web_search to find primary or credible secondary sources and call web_fetch to extract facts before declaring this task complete. Do not simulate or fabricate citations.]"
                jq --arg p "$adv" '. += [{"role": "user", "content": $p}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                consecutive_empty_turns=0
                turn=$((turn + 1))
                continue
            elif [ "$is_unverified_code" -eq 1 ]; then
                ui_dim "  [guard] Intercepted Turn $turn draft: zero implementation/execution tools executed for code task"
                jq --arg ans "$raw_content" '. += [{"role": "assistant", "content": $ans}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                local adv="[SYSTEM ADVISORY: Implementation verification required. You produced a conversational response on Turn $turn without executing any code implementation or execution tools (file_read, file_write, bash_exec, symbol_patch, git_*). You MUST execute the required code changes, run tests, and perform git operations in the workspace using your native tools before declaring this task complete. Proceed immediately to tool execution.]"
                jq --arg p "$adv" '. += [{"role": "user", "content": $p}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                consecutive_empty_turns=0
                turn=$((turn + 1))
                continue
            fi

            echo ""
            ui_ok "Task Complete!"
            printf '%s\n' "$raw_content" > "$session_dir/final_reply.txt" 2>/dev/null || true
            jq --arg ans "$raw_content" '. += [{"role": "assistant", "content": $ans}]' "$messages_file" > "${messages_file}.tmp" 2>/dev/null && mv "${messages_file}.tmp" "$messages_file" 2>/dev/null || true
            journal_write "reflection" "Completed task: $goal. Summary: ${raw_content:0:200}" 2>/dev/null || true
            declare -f transcript_log_block &>/dev/null && transcript_log_block "final_response" "$raw_content"
            _react_trace "$workdir" "task_complete" "$(jq -cn --arg goal "$goal" --arg summary "${raw_content:0:200}" '{goal:$goal, summary:$summary, status:"success"}')"
            jq '.status = "COMPLETED"' "$macro_file" > "${macro_file}.tmp" 2>/dev/null && mv "${macro_file}.tmp" "$macro_file" 2>/dev/null || true
            declare -f memory_register_files &>/dev/null && memory_register_files "$workdir"
            if declare -f telemetry_task_end &>/dev/null; then
                telemetry_task_end "$session_id" 0 "COMPLETED" >/dev/null 2>&1 || true
            fi
            export AGENT_ACTIVE_SESSION_ID=""
            if declare -f transcript_stop &>/dev/null && transcript_active 2>/dev/null; then
                local _tpath
                _tpath=$(transcript_stop)
                [ -n "$_tpath" ] && ui_dim "  Transcript: $_tpath"
            fi
            return 0
        fi

        # If model generated reasoning / thoughts without tool calls:
        if [ -z "$raw_content" ] && [ -n "$reasoning" ]; then
            # Thought continuation: model is actively reasoning through the problem.
            # Preserve thought in conversation history and prompt for conclusion or next action.
            local asst_thought_msg
            asst_thought_msg=$(jq -nc \
                --arg rc "$reasoning" \
                '{role: "assistant", content: null, reasoning_content: $rc}')
            jq --argjson m "$asst_thought_msg" '. += [$m]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"

            local prompt_advise
            if [ "${tool_filter:-default}" = "social" ] || [ "${tool_filter:-default}" = "chat" ]; then
                prompt_advise="[SYSTEM ADVISORY: Chain-of-thought completed. Now provide your final, direct response to the user. Do not repeat internal reasoning.]"
            else
                prompt_advise="[SYSTEM ADVISORY: Chain-of-thought received. Proceed to execute your next step. Use available tools (e.g. file_read, code_outline, code_symbol_get, file_grep, dir_list, bash_exec) to inspect files, execute commands, or apply fixes.]"
            fi
            jq --arg p "$prompt_advise" '. += [{"role": "user", "content": $p}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"

            echo "Thought: $reasoning" >> "$history_file"
            declare -f transcript_log_block &>/dev/null && transcript_log_block "thought" "$reasoning"

            # Reset empty turns counter because model generated active thoughts
            consecutive_empty_turns=0
            turn=$((turn + 1))
            continue
        fi


        # Track consecutive truly empty turns (where neither content nor reasoning was generated)
        consecutive_empty_turns=$((consecutive_empty_turns + 1))
        if [ "$consecutive_empty_turns" -ge 5 ]; then
            ui_err "Circuit breaker tripped: Model returned $consecutive_empty_turns consecutive empty turns without advancing."
            ui_warn "Halting task to protect context tokens and prevent infinite loop."
            _react_trace "$workdir" "circuit_breaker" "$(jq -cn --arg reason "consecutive_empty_turns" --argjson turns "$consecutive_empty_turns" '{reason:$reason, turns:$turns}')"
            jq '.status = "CIRCUIT_BREAKER_TRIPPED"' "$macro_file" > "${macro_file}.tmp" 2>/dev/null && mv "${macro_file}.tmp" "$macro_file" 2>/dev/null || true
            if declare -f telemetry_record_anomaly &>/dev/null; then
                telemetry_record_anomaly "$session_id" "PROCESS_STALL" "react.sh" "Circuit breaker tripped: $consecutive_empty_turns consecutive empty turns" >/dev/null 2>&1 || true
            fi
            if declare -f telemetry_preserve_incident &>/dev/null; then
                telemetry_preserve_incident "$session_id" "PROCESS_STALL" "Circuit breaker tripped: consecutive empty turns" "$workdir" >/dev/null 2>&1 || true
            fi
            if declare -f telemetry_triage_operational_failure &>/dev/null; then
                telemetry_triage_operational_failure "react_agent" "PROCESS_STALL" "Circuit breaker tripped: consecutive empty turns" "Model returned $consecutive_empty_turns consecutive empty turns without advancing" "$workdir" >/dev/null 2>&1 || true
            fi
            if declare -f telemetry_task_end &>/dev/null; then
                telemetry_task_end "$session_id" 1 "CIRCUIT_BREAKER_TRIPPED" >/dev/null 2>&1 || true
            fi
            export AGENT_ACTIVE_SESSION_ID=""
            if declare -f transcript_stop &>/dev/null && transcript_active 2>/dev/null; then
                transcript_stop >/dev/null 2>&1 || true
            fi
            return 1
        else
            # Nudge model on empty turn before burnout
            local empty_nudge="[SYSTEM NOTICE: No response or tool call generated on turn $turn. Please continue your task or invoke an available tool.]"
            jq --arg n "$empty_nudge" '. += [{"role": "user", "content": $n}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
        fi

        turn=$((turn + 1))
    done

    ui_warn "Task reached turn ceiling ($max_turns). Preserving active state and memory..."
    journal_write "reflection" "Task paused at turn ceiling ($max_turns): $goal." 2>/dev/null || true
    _react_trace "$workdir" "task_halted" "$(jq -cn --arg goal "$goal" --arg reason "turn_ceiling_preserved" '{goal:$goal, reason:$reason}')"
    jq '.status = "TURN_CEILING_PRESERVED"' "$macro_file" > "${macro_file}.tmp" 2>/dev/null && mv "${macro_file}.tmp" "$macro_file" 2>/dev/null || true
    declare -f memory_register_files &>/dev/null && memory_register_files "$workdir"
    if declare -f telemetry_triage_operational_failure &>/dev/null; then
        telemetry_triage_operational_failure "react_agent" "PROCESS_STALL" "Task reached turn ceiling ($max_turns turns)" "Task failed to conclude within turn budget: $goal" "$workdir" >/dev/null 2>&1 || true
    fi
    if declare -f telemetry_task_end &>/dev/null; then
        telemetry_task_end "$session_id" 0 "TURN_CEILING_PRESERVED" >/dev/null 2>&1 || true
    fi
    export AGENT_ACTIVE_SESSION_ID=""
    if declare -f transcript_stop &>/dev/null && transcript_active 2>/dev/null; then
        local _tpath
        _tpath=$(transcript_stop)
        [ -n "$_tpath" ] && ui_dim "  Transcript: $_tpath"
    fi
    return 0
}

# Alias agent_run to react_run
agent_run() {
    react_run "$@"
}
