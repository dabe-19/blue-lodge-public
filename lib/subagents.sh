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
source "$LODGE_DIR/lib/limits.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/alerts.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mcp_server_gitea.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/treesitter.sh" 2>/dev/null || true

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
    local log_file="${GEORGE_DIR}/subagents/${sub_id}.log"

    subagents_init
    mkdir -p "${GEORGE_DIR}/subagents" 2>/dev/null || true
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
       --arg log "$log_file" \
       '. += [{
           id: $id,
           pid: ($pid | tonumber? // 0),
           parent_pid: ($ppid | tonumber? // 0),
           tier: $tier,
           model: $model,
           objective: $obj,
           branch: $br,
           worktree_dir: $wt,
           log_file: $log,
           max_turns: ($turns | tonumber? // 200),
           current_turn: 1,
           status: "RUNNING",
           started_at: $start,
           updated_at: $start
       }]' "$SUBAGENTS_REGISTRY" > "$tmp_reg" 2>/dev/null && mv "$tmp_reg" "$SUBAGENTS_REGISTRY"
}

subagents_set_pid() {
    local sub_id="$1"
    local pid="$2"
    subagents_init
    local tmp_reg="${SUBAGENTS_REGISTRY}.tmp.$$"
    jq --arg id "$sub_id" \
       --arg pid "$pid" \
       'map(if .id == $id then .pid = ($pid | tonumber? // .pid) else . end)' \
       "$SUBAGENTS_REGISTRY" > "$tmp_reg" 2>/dev/null && mv "$tmp_reg" "$SUBAGENTS_REGISTRY"
}

_subagent_log_event() {
    local sub_id="$1"
    local tag="$2"
    local msg="$3"
    local log_dir="${GEORGE_DIR}/subagents"
    mkdir -p "$log_dir" 2>/dev/null || true
    local log_file="${log_dir}/${sub_id}.log"
    local stream_file="${log_dir}/${sub_id}.stream"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    local formatted
    formatted=$(printf '[%s] [%-11s] %s\n' "$ts" "$tag" "$msg")
    printf '%s\n' "$formatted" >> "$log_file"
    printf '%s\n' "$formatted" >> "$stream_file"
}

subagents_logs() {
    local sub_id="$1"
    local lines="${2:-50}"
    local log_file="${GEORGE_DIR}/subagents/${sub_id}.log"
    if [ -f "$log_file" ]; then
        tail -n "$lines" "$log_file"
    else
        echo "No logs found for subagent $sub_id (expected: $log_file)"
        return 1
    fi
}

subagents_stream() {
    local sub_id="$1"
    local log_file="${GEORGE_DIR}/subagents/${sub_id}.log"
    if [ ! -f "$log_file" ]; then
        echo "Awaiting stream log for subagent $sub_id..."
        local w=0
        while [ ! -f "$log_file" ] && [ "$w" -lt 30 ]; do
            sleep 0.2
            w=$((w + 1))
        done
    fi
    if [ -f "$log_file" ]; then
        tail -f -n 25 "$log_file"
    else
        echo "ERROR: Stream log not found for subagent $sub_id."
        return 1
    fi
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

_subagent_safe_remove_worktree() {
    local wt="$1"
    [ -z "$wt" ] && return 0
    [ ! -d "$wt" ] && return 0

    # Always try git worktree remove first
    git -C "$LODGE_DIR" worktree remove --force "$wt" 2>/dev/null || true

    # Only fall back to rm -rf if the directory is strictly inside a sandboxes directory
    case "$wt" in
        */.sandboxes/*|*lodge-sandboxes/*)
            rm -rf "$wt" 2>/dev/null || true
            ;;
        *)
            # Refuse to rm -rf system directories like /tmp, /, /home, etc.
            ;;
    esac
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
            _subagent_safe_remove_worktree "$swt"
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
        _subagent_safe_remove_worktree "$swt"
        if [ -n "$sbranch" ]; then
            git -C "$LODGE_DIR" branch -D "$sbranch" 2>/dev/null || true
        fi
        subagents_update_status "$sid" "KILLED_EXIT" "" "Lodge exit cleanup"
    done <<< "$running"

    git -C "$LODGE_DIR" worktree prune 2>/dev/null || true
}

# ── Subagent Worker Execution Loop ──────────────────────────────────
_subagent_worker_run() {
    local sub_id="$1"
    local target_tier="$2"
    local tier_model="$3"
    local tier_url="$4"
    local tier_roles="$5"
    local objective="$6"
    local parent_context="$7"
    local sub_dir="$8"
    local sub_branch="$9"
    local is_worktree="${10}"
    local sub_fifo="${11}"
    local ctrl_fifo="${12}"
    local max_turns="${13}"

    # Cleanup FIFOs when worker concludes
    local _worker_sub_fifo="${sub_fifo:-}"
    local _worker_ctrl_fifo="${ctrl_fifo:-}"
    _subagent_fifo_cleanup() {
        rm -f "${_worker_sub_fifo:-}" "${_worker_ctrl_fifo:-}" 2>/dev/null || true
    }
    trap _subagent_fifo_cleanup EXIT INT TERM

    _subagent_log_event "$sub_id" "SPAWN" "Tier $target_tier ($tier_model) | Objective: $objective | Worktree: $sub_dir" "$sub_fifo"

    local sub_history="$sub_dir/history.log"
    : > "$sub_history"

    local sub_system="You are an autonomous subagent worker (Tier $target_tier: $tier_model).
Role: $tier_roles
Your specific objective: $objective
Parent Context: $parent_context

You operate in an isolated git worktree sandbox. You can execute tools via slash commands:
- /read <file> [start] [count] : Read file contents
- /append <file> <content> : Append text to a file
- /bash <cmd> : Execute shell command in workspace (e.g. echo, sed, grep, git)
- /upstream propose <title> --reason <text> --metric <proof> : Propose your deliverable upstream as a PR to develop
- /web search <query> : Search the web
- /web fetch <url> : Fetch markdown page
- /respond <text> : Conclude your task and return the final synthesized answer.

WORKER PROTOCOL:
1. Never repeatedly /read the same file. After reading, proceed immediately to modifying the target file.
2. To modify files, use a python or bash code block, or a single-line command:
```python
# python code here to modify file
```
or Action: /bash sed -i ...
3. When changes are verified, propose upstream immediately:
Action: /upstream propose \"<title>\" --reason \"<reason>\" --metric \"<metric>\"
4. Conclude immediately after:
Action: /respond <summary of deliverable>

Output format for each turn:
Thought: <brief reasoning>
Action: <slash-command> (or code block)"

# ── Subagent Auto-Compaction Engine ──────────────────────────────────
_subagent_compact() {
    local sub_id="$1"
    local sub_history="$2"
    local tier_url="$3"
    local tier_model="$4"
    local sub_fifo="$5"

    _subagent_log_event "$sub_id" "COMPACT" "Slot tokens approaching threshold (18k+). Executing semantic auto-compaction..." "$sub_fifo"

    local history_summary
    history_summary=$(tail -c 12000 "$sub_history" 2>/dev/null)

    local prompt="The following is an ongoing subagent trajectory. Summarize the key accomplishments, discovered facts/line numbers, files modified, and pending tasks concisely:\n\n$history_summary"

    local payload
    payload=$(jq -n \
        --arg sys "You are a state summarizer. Produce a concise structured summary: Accomplished, Key Facts, Pending Goals." \
        --arg prompt "$prompt" \
        --arg model "$tier_model" \
        '{
            model: $model,
            messages: [
                {"role": "system", "content": $sys},
                {"role": "user", "content": $prompt}
            ],
            temperature: 0.2,
            reasoning_effort: "low",
            max_tokens: 1536
        }')

    local summary_resp
    summary_resp=$(curl -s --max-time 45 "$tier_url/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    local summary_text
    summary_text=$(echo "$summary_resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

    if [ -n "$summary_text" ]; then
        local last_turn
        last_turn=$(tail -c 2500 "$sub_history" 2>/dev/null)
        printf "[PREVIOUS CONTEXT COMPACTED]:\n%s\n\n%s\n" "$summary_text" "$last_turn" > "$sub_history"
        _subagent_log_event "$sub_id" "COMPACT" "Context compacted successfully. Memory runway refreshed." "$sub_fifo"
        return 0
    else
        _subagent_log_event "$sub_id" "WARN" "Auto-compaction summarization failed; continuing with trimmed history." "$sub_fifo"
        tail -c 6000 "$sub_history" > "${sub_history}.tmp" && mv "${sub_history}.tmp" "$sub_history"
        return 1
    fi
}

    local turn=1
    local final_result=""
    local running_tokens=0
    local kv_prefix_tokens=2815 # Invariant system prompt & tool manifest baseline
    local consecutive_failures=0
    local last_failed_action=""
    local circuit_tripped=0
    local circuit_reason=""

    while [ "$turn" -le "$max_turns" ]; do
        declare -f ui_dashboard_worker_update &>/dev/null && ui_dashboard_worker_update "$sub_id" "turn $turn/$max_turns (tok: $running_tokens)" >&2
        subagents_update_status "$sub_id" "RUNNING" "$turn"

        # Check in-flight control FIFO (non-blocking)
        if [ -p "$ctrl_fifo" ]; then
            local ctrl_cmd=""
            read -t 0.05 -r ctrl_cmd <> "$ctrl_fifo" 2>/dev/null || true
            if [ -n "$ctrl_cmd" ]; then
                case "$ctrl_cmd" in
                    PAUSE*)
                        subagents_update_status "$sub_id" "PAUSED" "$turn"
                        _subagent_log_event "$sub_id" "CONTROL" "Paused by parent. Awaiting RESUME..." "$sub_fifo"
                        declare -f ui_info &>/dev/null && ui_info "Subagent $sub_id paused by parent. Awaiting RESUME..."
                        while true; do
                            local resume_cmd=""
                            read -r resume_cmd <> "$ctrl_fifo" 2>/dev/null || true
                            if [[ "$resume_cmd" == RESUME* ]]; then
                                _subagent_log_event "$sub_id" "CONTROL" "Resumed by parent." "$sub_fifo"
                                break
                            fi
                            if [[ "$resume_cmd" == ABORT* ]]; then
                                _subagent_log_event "$sub_id" "CONTROL" "Aborted by parent while paused." "$sub_fifo"
                                final_result="ABORTED_BY_PARENT"
                                break 2
                            fi
                            sleep 0.2
                        done
                        subagents_update_status "$sub_id" "RUNNING" "$turn"
                        ;;
                    ABORT*)
                        _subagent_log_event "$sub_id" "CONTROL" "Aborted by parent." "$sub_fifo"
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
            _subagent_log_event "$sub_id" "COUNTDOWN" "Approaching turn ceiling: Turn $turn/$max_turns ($rem turn(s) remaining)" "$sub_fifo"
            declare -f ui_warn &>/dev/null && ui_warn "Child subagent $sub_id approaching turn ceiling: Turn $turn/$max_turns ($rem turn(s) remaining)."
            countdown_notice="[SYSTEM NOTICE: APPROACHING TURN CEILING ($rem turn(s) remaining of $max_turns). Cease exploratory actions. Consolidate your deliverables and conclude with /respond.]\n\n"
        fi

        # Build messages payload with full-fidelity context
        local messages_json
        local recent_obs=""
        if [ -s "$sub_history" ]; then
            recent_obs=$(cat "$sub_history")
        fi

        messages_json=$(jq -n \
            --arg sys "$sub_system" \
            --arg goal "$objective" \
            --arg cd "$countdown_notice" \
            --arg obs "$recent_obs" \
            '[
                {"role": "system", "content": $sys},
                {"role": "user", "content": ($cd + "Objective: " + $goal + "\n\nTrajectory:\n" + $obs + "\n\nCRITICAL FORMAT REQUIREMENT:\nThought: <brief 1-sentence reasoning under 25 words>\nAction: <slash-command, e.g. /bash <cmd> or /upstream propose ...>\n\nNext Action:")}
            ]')

        local tier_ctx
        tier_ctx=$(endpoints_get_tier_info "$target_tier" "CONTEXT" 2>/dev/null || echo 8192)
        [ -z "$tier_ctx" ] || [ "$tier_ctx" -le 0 ] 2>/dev/null && tier_ctx=8192
        local compact_threshold=$((tier_ctx * 3 / 4))
        [ "$compact_threshold" -lt 3000 ] && compact_threshold=3000

        local tier_timeout
        tier_timeout=$(endpoints_get_tier_info "$target_tier" "TIMEOUT" 2>/dev/null || echo 600)
        [ -z "$tier_timeout" ] || [ "$tier_timeout" -lt 300 ] 2>/dev/null && tier_timeout=600

        local payload
        payload=$(jq -n \
            --arg model "$tier_model" \
            --argjson msgs "$messages_json" \
            '{
                model: $model,
                messages: $msgs,
                temperature: 0.2,
                reasoning_effort: "low",
                max_tokens: 4096
            }')

        # Query endpoint
        local resp_json
        resp_json=$(curl -s --max-time "$tier_timeout" "$tier_url/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null)

        if [ -z "$resp_json" ]; then
            echo "Action: /respond ERROR: Target model endpoint timed out or failed." >> "$sub_history"
            _subagent_log_event "$sub_id" "ERROR" "Target model endpoint timed out or failed." "$sub_fifo"
            final_result="ERROR: Subagent endpoint timed out."
            break
        fi

        # Live token accounting from API usage metrics
        local p_tok comp_tok
        p_tok=$(echo "$resp_json" | jq -r '.usage.prompt_tokens // 0' 2>/dev/null)
        comp_tok=$(echo "$resp_json" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)
        if [ "$p_tok" -gt 0 ]; then
            running_tokens=$((p_tok + comp_tok + kv_prefix_tokens))
            _subagent_log_event "$sub_id" "TELEMETRY" "Slot tokens: $running_tokens (prompt: $p_tok, comp: $comp_tok, kv_prefix: $kv_prefix_tokens)" "$sub_fifo"
        fi

        # Autonomous per-slot auto-compaction trigger (proportional to tier context ceiling)
        if [ "$running_tokens" -ge "$compact_threshold" ]; then
            _subagent_compact "$sub_id" "$sub_history" "$tier_url" "$tier_model" "$sub_fifo"
            running_tokens=2000
        fi

        local raw_content reasoning_content
        raw_content=$(echo "$resp_json" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        reasoning_content=$(echo "$resp_json" | jq -r '.choices[0].message.reasoning_content // empty' 2>/dev/null)

        # Extract and log internal reasoning thoughts if present
        local thoughts="$reasoning_content"
        local cleaned="$raw_content"
        if echo "$raw_content" | grep -qE '<think>'; then
            if [ -z "$thoughts" ] && command -v perl &>/dev/null; then
                thoughts=$(echo "$raw_content" | perl -0777 -ne 'if (/<think>(.*?)<\/think>/s) { my $t = $1; $t =~ s/^\s+|\s+$//g; print $t; }')
            fi
            if command -v perl &>/dev/null; then
                cleaned=$(echo "$raw_content" | perl -0777 -pe 's/<think>.*?<\/think>//sg')
            fi
        fi
        if [ -n "$thoughts" ]; then
            _subagent_log_event "$sub_id" "THOUGHT" "$thoughts" "$sub_fifo"
        fi

        # Parse action from XML <tool_call>, Gemma <|tool_call>, or standard Action: /...
        local action=""

        if echo "$cleaned" | grep -qE '<tool_call>|<\|tool_call>'; then
            if command -v perl &>/dev/null; then
                action=$(printf '%s' "$cleaned" | perl -0777 -ne '
                    if (/<function=([a-zA-Z0-9_-]+)>(.*?)<\/function>/s) {
                        my $fn = lc($1);
                        my $inner = $2;
                        my $param = "";
                        if ($inner =~ /<parameter=[^>]*>(.*?)<\/parameter>/s) {
                            $param = $1;
                        } else {
                            $param = $inner;
                        }
                        $param =~ s/^\s+|\s+$//g;
                        if ($fn eq "bash" || $fn eq "sh") {
                            print "/bash $param\n";
                        } elsif ($fn eq "read" || $fn eq "file_read") {
                            print "/read $param\n";
                        } elsif ($fn eq "append" || $fn eq "file_append") {
                            print "/append $param\n";
                        } elsif ($fn eq "upstream") {
                            print "/upstream $param\n";
                        } else {
                            print "/$fn $param\n";
                        }
                    } elsif (/<\|tool_call>call:([a-zA-Z0-9_-]+)\{(?:command|query|content|args)?:?<\|"\|>(.*?)<\|"\|>/s ||
                             /<\|tool_call>call:([a-zA-Z0-9_-]+)\{(.*?)\}/s) {
                        my $fn = lc($1);
                        my $param = $2;
                        $param =~ s/^["\s:]+|["\s}]+$//g;
                        if ($fn eq "bash" || $fn eq "sh") {
                            print "/bash $param\n";
                        } elsif ($fn eq "read" || $fn eq "file_read") {
                            print "/read $param\n";
                        } elsif ($fn eq "append" || $fn eq "file_append") {
                            print "/append $param\n";
                        } elsif ($fn eq "upstream") {
                            print "/upstream $param\n";
                        } else {
                            print "/$fn $param\n";
                        }
                    }
                ' 2>/dev/null)
            fi
        fi

        if [ -z "$action" ]; then
            if echo "$cleaned" | grep -qE '^[[:space:]]*Action:[[:space:]]*`?\/upstream'; then
                action=$(echo "$cleaned" | sed -n 's/^[[:space:]]*Action:[[:space:]]*`\?\(\/.*\)`\?/\1/p' | head -1)
            elif echo "$cleaned" | grep -qE '^[[:space:]]*Action:[[:space:]]*`?\/respond'; then
                action=$(echo "$cleaned" | sed -n 's/^[[:space:]]*Action:[[:space:]]*`\?\(\/.*\)`\?/\1/p' | head -1)
            elif echo "$cleaned" | grep -qE '^[[:space:]]*Action:[[:space:]]*`?\/read'; then
                action=$(echo "$cleaned" | sed -n 's/^[[:space:]]*Action:[[:space:]]*`\?\(\/.*\)`\?/\1/p' | head -1)
            elif echo "$cleaned" | grep -qE '^[[:space:]]*Action:[[:space:]]*`?\/bash'; then
                action=$(printf '%s\n' "$cleaned" | sed -n '/^[[:space:]]*Action:[[:space:]]*`*\/bash/,$p' | sed '1s/^[[:space:]]*Action:[[:space:]]*`*//')
                action=$(printf '%s\n' "$action" | sed '/^[[:space:]]*\(Observation\|Thought\|Action\):/,$d')
                action=$(printf '%s\n' "$action" | sed 's/`[[:space:]]*$//')
            elif echo "$cleaned" | grep -qE '^[[:space:]]*Action:[[:space:]]*`?\/'; then
                action=$(echo "$cleaned" | sed -n 's/^[[:space:]]*Action:[[:space:]]*`\?\(\/.*\)`\?/\1/p' | head -1)
            elif echo "$cleaned" | grep -qE '```(python|python3)'; then
                local _extracted_py
                _extracted_py=$(echo "$cleaned" | sed -n '/```\(python\|python3\)/,/```/p' | sed '1d;$d')
                if [ -n "$_extracted_py" ]; then
                    action="/bash python3 - <<'EOF'
$_extracted_py
EOF"
                fi
            elif echo "$cleaned" | grep -qE '```(bash|sh)'; then
                local _extracted_cmd
                _extracted_cmd=$(echo "$cleaned" | sed -n '/```\(bash\|sh\)/,/```/p' | sed '1d;$d')
                if [ -n "$_extracted_cmd" ]; then
                    action="/bash $_extracted_cmd"
                fi
            elif echo "$cleaned" | grep -qE '^[[:space:]]*`?\/'; then
                action=$(echo "$cleaned" | grep -E '^[[:space:]]*`?\/' | head -1 | tr -d '`')
                action="${action#"${action%%[![:space:]]*}"}"
            elif echo "$cleaned" | grep -qE '^[[:space:]]*Action:[[:space:]]*(bash|read|append|upstream|respond)'; then
                action=$(echo "$cleaned" | sed -n 's/^[[:space:]]*Action:[[:space:]]*/\//p' | head -1)
            fi
        fi

        # Check if objective requires an upstream PR
        local needs_upstream=0
        if [[ "$objective" =~ (upstream|propose|PR|pull[[:space:]]request|SANDBOXES) ]]; then
            needs_upstream=1
        fi

        local pr_issued=0
        if [ -f "$sub_dir/.pr_issued" ]; then
            pr_issued=1
        fi

        if [ -z "$action" ]; then
            if [ "$needs_upstream" -eq 1 ] && [ "$pr_issued" -eq 0 ]; then
                _subagent_log_event "$sub_id" "GUARD" "No action found. Prompting model for explicit Action line." "$sub_fifo"
                local no_act_obs="[GUARD NOTICE: No valid tool action detected in your response. You must execute an action line, for example: Action: /bash python3 -c \"...\" or Action: /append <file> <content>, followed by Action: /upstream propose \"<title>\" --reason \"<reason>\" --metric \"<proof>\". Output: Thought: ... Action: /...]"
                printf "\n--- Turn %d ---\nObservation:\n%s\n" "$turn" "$no_act_obs" >> "$sub_history"
                turn=$((turn + 1))
                continue
            fi
            if [ -n "$cleaned" ] && [ "$turn" -gt 1 ]; then
                if [ "$needs_upstream" -eq 1 ] && [ "$pr_issued" -eq 0 ]; then
                    _subagent_log_event "$sub_id" "GUARD" "Model returned narrative text without issuing PR. Prompting for deliverable action." "$sub_fifo"
                    local no_act_obs="[GUARD NOTICE: You must execute Action: /upstream propose \"<title>\" --reason \"<reason>\" --metric \"<proof>\" before completing.]"
                    printf "\n--- Turn %d ---\nObservation:\n%s\n" "$turn" "$no_act_obs" >> "$sub_history"
                    turn=$((turn + 1))
                    continue
                fi
                final_result="$cleaned"
                _subagent_log_event "$sub_id" "RESULT" "$final_result" "$sub_fifo"
                break
            fi
            action="/respond $cleaned"
        fi

        _subagent_log_event "$sub_id" "ACTION" "$action" "$sub_fifo"

        # Check for /respond with Deliverable Guard
        if [[ "$action" == /respond* ]]; then
            local resp_text="${action#/respond}"
            resp_text="${resp_text#"${resp_text%%[![:space:]]*}"}"

            if [ "$needs_upstream" -eq 1 ] && [ "$pr_issued" -eq 0 ]; then
                _subagent_log_event "$sub_id" "GUARD" "Blocked premature /respond: objective requires submitting an upstream PR first." "$sub_fifo"
                obs="[GUARD NOTICE: Premature completion blocked. Your objective requires updating the file and running Action: /upstream propose \"<title>\" --reason \"<reason>\" --metric \"<metric>\" before concluding. Proceed to execute the modifications and propose upstream.]"
                printf "\n--- Turn %d ---\nAction: %s\nObservation:\n%s\n" "$turn" "$action" "$obs" >> "$sub_history"
                turn=$((turn + 1))
                continue
            fi

            final_result="$resp_text"
            [ -z "$final_result" ] && final_result="$cleaned"
            _subagent_log_event "$sub_id" "RESULT" "$final_result" "$sub_fifo"
            break
        fi

        # Execute tool inside isolated worktree directory
        local obs
        obs=$(commands_dispatch "$action" "$sub_dir" 2>&1)
        local cmd_rc=$?

        # Failure and Thrashing Detection
        local is_error=0
        if [ "$cmd_rc" -ne 0 ]; then
            is_error=1
        elif echo "$obs" | grep -qE "(SyntaxError|command not found|Unknown command|No such file or directory|fatal:|Traceback \(most recent call last\)|failed \(exit [1-9])"; then
            is_error=1
        fi

        if [ "$is_error" -eq 1 ]; then
            if [ -n "$last_failed_action" ] && [ "$action" = "$last_failed_action" ]; then
                # Thrashing detected: repeating identical failing action consecutively
                consecutive_failures=$((consecutive_failures + 2))
            else
                consecutive_failures=$((consecutive_failures + 1))
            fi
            last_failed_action="$action"
            _subagent_log_event "$sub_id" "WARN" "Action failed (exit $cmd_rc, streak: $consecutive_failures/3): ${action:0:80}" "$sub_fifo"
        else
            consecutive_failures=0
            last_failed_action=""
        fi

        # Log observation to persistent stream
        _subagent_log_event "$sub_id" "OBSERVATION" "$obs" "$sub_fifo"

        # Record full-fidelity observation in sub_history (soft-limit only astronomical dumps >15k chars)
        local record_obs="$obs"
        if [ ${#record_obs} -gt 15000 ]; then
            record_obs="${record_obs:0:15000}... [output bounded at 15k chars for slot headroom]"
        fi
        printf "\n--- Turn %d ---\nAction: %s\nObservation:\n%s\n" "$turn" "$action" "$record_obs" >> "$sub_history"

        # Check Circuit Breaker Threshold (default 3 consecutive failures or thrashing)
        local max_consecutive
        max_consecutive=$(limits_get CIRCUIT_BREAKER_MAX_FAILURES 3 2>/dev/null || echo 3)
        if [ "$consecutive_failures" -ge "$max_consecutive" ]; then
            circuit_tripped=1
            circuit_reason="Subagent tripped circuit breaker after $consecutive_failures consecutive failures (Action: ${action:0:80}). Escalating to Parent George."
            _subagent_log_event "$sub_id" "CIRCUIT_BREAKER" "$circuit_reason" "$sub_fifo"
            _subagent_log_event "$sub_id" "ALERT_PARENT" "Escalation triggered for subagent $sub_id (worktree: $sub_dir)" "$sub_fifo"

            # 1. Quarantined checkpoint branch commit & push
            local checkpoint_br="checkpoint/${sub_id}"
            if [ -d "$sub_dir" ]; then
                (
                    cd "$sub_dir" || exit 0
                    git branch -D "$checkpoint_br" >/dev/null 2>&1 || true
                    git checkout -B "$checkpoint_br" >/dev/null 2>&1 || true
                    git add -A >/dev/null 2>&1 || true
                    git commit -m "checkpoint(${sub_id}): state at circuit-breaker trip (turn $turn)" >/dev/null 2>&1 || true
                )
                git -C "$LODGE_DIR" push gitea "$checkpoint_br" >/dev/null 2>&1 || true
            fi

            # 2. Create structured Issue on Sovereign Gitea
            local issue_num="" issue_url=""
            if declare -f gitea_is_online &>/dev/null && gitea_is_online; then
                local issue_title="[Escalation] Subagent ${sub_id} blocked: ${action:0:60}"
                local issue_body
                issue_body=$(printf "### Subagent Circuit Breaker Escalation\n\n- **Subagent ID:** \`%s\`\n- **Tier:** %s (\`%s\`)\n- **Objective:** %s\n- **Turn:** %d\n- **Failed Action:** \`%s\`\n- **Checkpoint Branch:** \`%s\`\n- **Sandbox Worktree:** \`%s\`\n\n#### Last Error Diagnostic:\n\`\`\`\n%s\n\`\`\`\n" \
                    "$sub_id" "$target_tier" "$tier_model" "$objective" "$turn" "$action" "$checkpoint_br" "$sub_dir" "${obs:0:1500}")
                local issue_res
                issue_res=$(gitea_issue_create "$issue_title" "$issue_body" "escalation,blocked" 2>/dev/null || true)
                issue_num=$(echo "$issue_res" | jq -r .number 2>/dev/null || true)
                issue_url=$(echo "$issue_res" | jq -r .html_url 2>/dev/null || true)
                if [ -n "$issue_num" ] && [ "$issue_num" != "null" ]; then
                    gitea_issue_comment "$issue_num" "[Subagent ${sub_id}]: Tripped circuit breaker after ${consecutive_failures} consecutive failures. Quarantined in PAUSED_BLOCKED state at \`${checkpoint_br}\`." >/dev/null 2>&1 || true
                fi
            fi

            # 3. Dispatch Multi-Tier Alert across MQTT and External Channels
            local ctx_json
            ctx_json=$(jq -n \
                --arg sub "$sub_id" \
                --arg tier "$target_tier" \
                --arg model "$tier_model" \
                --arg act "$action" \
                --arg br "$checkpoint_br" \
                --arg wt "$sub_dir" \
                --arg is_num "${issue_num:-}" \
                '{ subagent_id: $sub, tier: $tier, model: $model, failed_action: $act, checkpoint: $br, worktree: $wt, issue_number: $is_num }')
            alerts_dispatch tier1 "Subagent $sub_id Blocked" "$circuit_reason" "${issue_url:-}" "$ctx_json" >/dev/null 2>&1 || true

            declare -f ui_err &>/dev/null && ui_err "⚡ [CIRCUIT BREAKER] Subagent $sub_id escalated to Parent George ($consecutive_failures consecutive failures)" >&2

            # Clean up temporary scratch scripts created during attempts
            rm -f /tmp/fix_*.py /tmp/patch_*.sh /tmp/subagent_*.tmp 2>/dev/null || true

            final_result="$circuit_reason"
            break
        fi

        turn=$((turn + 1))
    done

    # Preserve and auto-commit deliverables in git worktree
    if [ "$is_worktree" -eq 1 ] && [ -d "$sub_dir" ]; then
        (
            cd "$sub_dir" || exit 0
            if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
                GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-George}" \
                GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-george@bluelodge.local}" \
                GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-George}" \
                GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-george@bluelodge.local}" \
                git add -A 2>/dev/null || true
                git commit -q -m "subagent(${sub_id}): deliverable for ${objective:0:50}" 2>/dev/null || true
            fi
        )
        _subagent_log_event "$sub_id" "DELIVERABLE" "Deliverables auto-committed to branch $sub_branch in $sub_dir" "$sub_fifo"
    fi

    # Finalize visual dashboard and registry
    local exit_code=0
    local final_status="COMPLETED"
    if [ "$circuit_tripped" -eq 1 ]; then
        exit_code=75  # EX_TEMPFAIL / Escalated to Parent
        final_status="PAUSED_BLOCKED"
    elif [ -z "$final_result" ]; then
        exit_code=1
        final_status="FAILED"
    fi
    subagents_update_status "$sub_id" "$final_status" "$turn" "$final_result"
    declare -f ui_dashboard_worker_finish &>/dev/null && ui_dashboard_worker_finish "$sub_id" "$exit_code" >&2
    _subagent_log_event "$sub_id" "FINISH" "Status: $final_status | Turns: $turn" "$sub_fifo"

    if [ "$circuit_tripped" -eq 1 ]; then
        echo "⚡ [CIRCUIT BREAKER] $circuit_reason"
    elif [ -z "$final_result" ]; then
        echo "Subagent reached max turns without explicit response."
    else
        echo "$final_result"
    fi

    _subagent_fifo_cleanup 2>/dev/null || true
    trap - EXIT INT TERM
    return "$exit_code"
}

# ── Subagent Dispatcher ──────────────────────────────────────────────
# Spawns a dedicated subagent on the specified tier to accomplish a delegated goal.
# Usage: subagents_spawn <tier> <objective> [context] [workdir] [max_turns] [is_async]
subagents_spawn() {
    local target_tier="$1"
    local objective="$2"
    local parent_context="${3:-}"
    local workdir="${4:-$PWD}"
    local max_turns="${5:-${AGENT_CHILD_MAX_TURNS:-200}}"
    local is_async="${6:-0}"

    if [ -z "$target_tier" ] || [ -z "$objective" ]; then
        echo "ERROR: subagents_spawn requires tier and objective arguments."
        return 1
    fi

    endpoints_init 2>/dev/null || true

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

    # Provision git worktree if inside a git repository (branch from develop)
    if git -C "$LODGE_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
        local base_ref="develop"
        git -C "$LODGE_DIR" rev-parse --verify develop &>/dev/null || base_ref="HEAD"
        if git -C "$LODGE_DIR" worktree add -q -b "$sub_branch" "$sub_dir" "$base_ref" &>/dev/null; then
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
    declare -f ui_dashboard_worker_start &>/dev/null && ui_dashboard_worker_start "$sub_id" "$target_tier" "$tier_model" "$objective" >&2

    if [ "$is_async" = "1" ] || [ "$is_async" = "true" ]; then
        export _LODGE_SKIP_SUBAGENT_CLEANUP=1
        (
            _subagent_worker_run "$sub_id" "$target_tier" "$tier_model" "$tier_url" "$tier_roles" \
                "$objective" "$parent_context" "$sub_dir" "$sub_branch" "$is_worktree" \
                "$sub_fifo" "$ctrl_fifo" "$max_turns"
        ) >/dev/null 2>&1 &
        local bg_pid=$!
        subagents_set_pid "$sub_id" "$bg_pid"
        jq -n \
            --arg id "$sub_id" \
            --arg pid "$bg_pid" \
            --arg tier "$target_tier" \
            --arg model "$tier_model" \
            --arg branch "$sub_branch" \
            --arg wt "$sub_dir" \
            --arg log "${GEORGE_DIR}/subagents/${sub_id}.log" \
            '{
                sub_id: $id,
                pid: ($pid | tonumber),
                tier: ($tier | tonumber),
                model: $model,
                branch: $branch,
                worktree: $wt,
                log_file: $log,
                status: "RUNNING"
            }'
        return 0
    else
        _subagent_worker_run "$sub_id" "$target_tier" "$tier_model" "$tier_url" "$tier_roles" \
            "$objective" "$parent_context" "$sub_dir" "$sub_branch" "$is_worktree" \
            "$sub_fifo" "$ctrl_fifo" "$max_turns"
        return $?
    fi
}

# ── Subagent Deliverable & Worktree Management ────────────────────────
subagents_diff() {
    local sub_id="$1"
    local stat_only="${2:-false}"
    if [ -z "$sub_id" ]; then
        echo "ERROR: sub_id is required."
        return 1
    fi
    local branch="subagent/$sub_id"
    if ! git -C "$LODGE_DIR" rev-parse --verify "$branch" &>/dev/null; then
        echo "ERROR: Branch $branch does not exist."
        return 1
    fi
    local diff_cmd=(git -C "$LODGE_DIR" diff HEAD.."$branch")
    [ "$stat_only" = "true" ] && diff_cmd+=(--stat)
    local out
    out=$("${diff_cmd[@]}" 2>&1)
    [ -z "$out" ] && out="No differences between HEAD and $branch."
    echo "$out"
}

subagents_merge() {
    local sub_id="$1"
    local strategy="${2:-merge}"
    if [ -z "$sub_id" ]; then
        echo "ERROR: sub_id is required."
        return 1
    fi
    local branch="subagent/$sub_id"
    if ! git -C "$LODGE_DIR" rev-parse --verify "$branch" &>/dev/null; then
        echo "ERROR: Branch $branch does not exist."
        return 1
    fi
    local out
    if [ "$strategy" = "squash" ]; then
        out=$(git -C "$LODGE_DIR" merge --squash "$branch" 2>&1)
    else
        out=$(git -C "$LODGE_DIR" merge --no-ff -m "Merge subagent deliverable ($sub_id)" "$branch" 2>&1)
    fi
    local code=$?
    echo "$out"
    return "$code"
}

subagents_reap() {
    local sub_id="$1"
    if [ -z "$sub_id" ]; then
        echo "ERROR: sub_id is required."
        return 1
    fi
    local wt_path="${LODGE_DIR}/.sandboxes/$sub_id"
    local branch="subagent/$sub_id"

    # Kill process if still alive in background
    local spid sstat
    spid=$(jq -r --arg id "$sub_id" '.[] | select(.id == $id) | .pid' "$SUBAGENTS_REGISTRY" 2>/dev/null || true)
    sstat=$(jq -r --arg id "$sub_id" '.[] | select(.id == $id) | .status' "$SUBAGENTS_REGISTRY" 2>/dev/null || true)
    if [ "$sstat" = "RUNNING" ] || [ "$sstat" = "PAUSED" ]; then
        if [ -n "$spid" ] && [ "$spid" -gt 0 ] 2>/dev/null && [ "$spid" -ne "$$" ] && kill -0 "$spid" 2>/dev/null; then
            kill -TERM "$spid" 2>/dev/null || true
        fi
    fi

    if [ -d "$wt_path" ]; then
        git -C "$LODGE_DIR" worktree remove --force "$wt_path" 2>/dev/null || rm -rf "$wt_path" 2>/dev/null || true
    fi
    git -C "$LODGE_DIR" branch -D "$branch" 2>/dev/null || true
    git -C "$LODGE_DIR" worktree prune 2>/dev/null || true

    subagents_update_status "$sub_id" "REAPED" "" "Worktree and branch reaped"
    echo "Worktree $wt_path and branch $branch cleanly reaped."
}

subagents_resume() {
    local sub_id="$1"
    local resolved_pr="${2:-}"
    subagents_init

    local reg_entry
    reg_entry=$(jq -r --arg id "$sub_id" '.[] | select(.id == $id)' "$SUBAGENTS_REGISTRY" 2>/dev/null)
    if [ -z "$reg_entry" ]; then
        ui_err "Subagent '$sub_id' not found in registry."
        return 1
    fi

    local swt sbranch sstatus obj tier model turns
    swt=$(echo "$reg_entry" | jq -r .worktree_dir)
    sbranch=$(echo "$reg_entry" | jq -r .branch)
    sstatus=$(echo "$reg_entry" | jq -r .status)
    obj=$(echo "$reg_entry" | jq -r .objective)
    tier=$(echo "$reg_entry" | jq -r .tier)
    model=$(echo "$reg_entry" | jq -r .model)
    turns=$(echo "$reg_entry" | jq -r .max_turns)

    ui_section "Resuming Subagent $sub_id ($sstatus)"

    if [ -d "$swt" ]; then
        ui_step "Updating worktree at $swt with latest changes from develop..."
        git -C "$swt" fetch origin develop >/dev/null 2>&1 || git -C "$swt" fetch gitea develop >/dev/null 2>&1 || true
        git -C "$swt" merge --no-edit origin/develop >/dev/null 2>&1 || git -C "$swt" merge --no-edit develop >/dev/null 2>&1 || true
        ui_ok "Worktree synchronized with develop."
    else
        ui_err "Worktree directory '$swt' missing. Cannot resume."
        return 1
    fi

    # Update status to RESUMED / RUNNING
    subagents_update_status "$sub_id" "RUNNING" "" "Resumed execution after resolution"

    # Emit resumption event to MQTT
    if declare -f mqtt_publish &>/dev/null; then
        local resume_payload
        resume_payload=$(jq -n \
            --arg id "$sub_id" \
            --arg pr "${resolved_pr:-none}" \
            --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")" \
            '{ event: "WORKER_RESUME", subagent_id: $id, resolved_pr: $pr, timestamp: $ts }')
        mqtt_publish "george/workers/${sub_id}/resume" "$resume_payload" >/dev/null 2>&1 || true
    fi

    ui_ok "Subagent $sub_id resumed."
}

subagents_prune() {
    local opt="${1:-stale}"
    subagents_init

    local entries
    if [ "$opt" = "--all" ] || [ "$opt" = "all" ]; then
        entries=$(jq -r '.[] | "\(.id)|\(.status)|\(.worktree_dir)|\(.branch)"' "$SUBAGENTS_REGISTRY" 2>/dev/null || true)
    else
        entries=$(jq -r '.[] | select(.status == "COMPLETED" or .status == "DONE" or .status == "CRASHED_ORPHAN" or .status == "KILLED_EXIT" or .status == "FAILED" or .status == "REAPED") | "\(.id)|\(.status)|\(.worktree_dir)|\(.branch)"' "$SUBAGENTS_REGISTRY" 2>/dev/null || true)
    fi

    local pruned_count=0
    while IFS='|' read -r sid st swt sbranch; do
        [ -z "$sid" ] && continue
        if [ -n "$swt" ] && [ -d "$swt" ]; then
            _subagent_safe_remove_worktree "$swt"
        fi
        if [ -n "$sbranch" ] && [ "$sbranch" != "develop" ] && [ "$sbranch" != "main" ]; then
            git -C "$LODGE_DIR" branch -D "$sbranch" 2>/dev/null || true
        fi
        pruned_count=$((pruned_count + 1))
    done <<< "$entries"

    git -C "$LODGE_DIR" worktree prune 2>/dev/null || true
    ui_ok "Pruned $pruned_count subagent worktrees and branches."
}

