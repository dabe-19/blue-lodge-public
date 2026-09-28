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
source "$LODGE_DIR/lib/limits.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/cache.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/fifo_ipc.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/task_sync.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agent_sm.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mqtt.sh" 2>/dev/null || true

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

# ── Action Normalization & Canonical Hash ────────────────────────────
_react_action_hash() {
    local c_name="$1"
    local c_args="${2:-}"
    local norm_args=""

    if [ -z "$c_args" ] || [ "$c_args" = "{}" ]; then
        norm_args="{}"
    elif echo "$c_args" | jq -e 'type == "object" or type == "array"' >/dev/null 2>&1; then
        norm_args=$(echo "$c_args" | jq -S -c . 2>/dev/null || echo "$c_args" | tr -d '[:space:]')
    else
        norm_args=$(echo "$c_args" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr -s ' ')
    fi

    printf '%s:%s' "$c_name" "$norm_args" | md5sum 2>/dev/null | cut -d' ' -f1 \
        || printf '%s:%s' "$c_name" "$norm_args" | cksum | cut -d' ' -f1
}

# ── Repetition & Loop Thrashing Detection ────────────────────────────
# Evaluates action repetition against a circular history buffer.
# Returns:
#   0: Forward progress / first occurrence
#   1: Strike 1 (Advisory recommended)
#   2: Strike 2 (Deterministic Interlock)
#   3: Strike 3 (Trip Circuit Breaker)
_react_check_repetition() {
    local session_dir="$1"
    local a_hash="$2"
    local c_name="${3:-}"
    local c_args="${4:-}"

    local hash_file="$session_dir/action_hashes.log"
    local repeat_window
    repeat_window=$(declare -f limits_get &>/dev/null && limits_get CIRCUIT_BREAKER_REPEAT_WINDOW 5 || echo "${CIRCUIT_BREAKER_REPEAT_WINDOW:-5}")
    local max_repeats
    max_repeats=$(declare -f limits_get &>/dev/null && limits_get CIRCUIT_BREAKER_MAX_REPEATS 3 || echo "${CIRCUIT_BREAKER_MAX_REPEATS:-3}")

    local prev_hashes=()
    if [ -f "$hash_file" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && prev_hashes+=("$line")
        done < "$hash_file"
    fi

    local prev_count=${#prev_hashes[@]}
    local strike=0

    # 1. Immediate exact repetition (Turn T == Turn T-1)
    if [ "$prev_count" -ge 1 ]; then
        local last_h="${prev_hashes[$((prev_count - 1))]}"
        if [ "$a_hash" = "$last_h" ]; then
            strike=1
        fi
    fi

    # 2. Check for 2-step oscillation: A -> B -> A -> B
    if [ "$prev_count" -ge 3 ]; then
        local h_minus_1="${prev_hashes[$((prev_count - 1))]}"
        local h_minus_2="${prev_hashes[$((prev_count - 2))]}"
        local h_minus_3="${prev_hashes[$((prev_count - 3))]}"
        if [ "$a_hash" = "$h_minus_2" ] && [ "$h_minus_1" = "$h_minus_3" ]; then
            strike=2
        fi
    fi

    # 3. Sliding window frequency
    local window_start=$(( prev_count - repeat_window ))
    [ "$window_start" -lt 0 ] && window_start=0
    local occurrences=0
    local i
    for (( i=window_start; i<prev_count; i++ )); do
        if [ "${prev_hashes[$i]}" = "$a_hash" ]; then
            occurrences=$((occurrences + 1))
        fi
    done

    if [ "$occurrences" -ge $((max_repeats - 1)) ]; then
        strike=3
    elif [ "$occurrences" -ge 2 ] && [ "$strike" -lt 2 ]; then
        strike=2
    elif [ "$occurrences" -ge 1 ] && [ "$strike" -lt 1 ]; then
        strike=1
    fi

    # Record new hash into history file
    echo "$a_hash" >> "$hash_file"

    echo "$strike"
}

# ── Pseudo-LRU Cache Interception Helpers ───────────────────────────
_react_tool_is_cacheable() {
    local name="$1"
    local args="${2:-}"
    case "$name" in
        web_search|web_fetch|pdf_read|file_read|code_symbol_get|code_outline|recall)
            return 0
            ;;
        phytology_manage)
            local act=""
            act=$(echo "$args" | jq -r '.action // empty' 2>/dev/null)
            if [ "$act" = "status" ] || [ "$act" = "audit" ] || [ "$act" = "cache-status" ]; then
                return 0
            fi
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

_react_tool_cache_ns() {
    local name="$1"
    case "$name" in
        web_search|web_fetch|pdf_read)
            echo "web"
            ;;
        file_read|code_symbol_get|code_outline)
            echo "files"
            ;;
        recall)
            echo "recall"
            ;;
        phytology_manage)
            echo "phytology"
            ;;
        *)
            echo "default"
            ;;
    esac
}

_react_tool_is_mutating() {
    local name="$1"
    local args="${2:-}"
    case "$name" in
        file_write|file_edit|symbol_patch|git_commit|git_push|git_checkout|gitea_pr|gitea_issue_close)
            return 0
            ;;
        phytology_manage)
            local act=""
            act=$(echo "$args" | jq -r '.action // empty' 2>/dev/null)
            if [ "$act" = "heal" ] || [ "$act" = "rollback" ] || [ "$act" = "prune" ] || [ "$act" = "lignify" ] || [ "$act" = "cache-invalidate" ]; then
                return 0
            fi
            return 1
            ;;
        bash_exec)
            local cmd=""
            cmd=$(echo "$args" | jq -r '.command // empty' 2>/dev/null || echo "$args")
            if echo "$cmd" | grep -qE '\b(git\s+(commit|checkout|merge|rebase|push|branch)|sed\s+-i|rm\s+|mv\s+|touch\s+|cat\s+>|tee\s+)'; then
                return 0
            fi
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# ── Circuit Breaker Classification Engine ────────────────────────────
_react_classify_circuit_state() {
    local c_name="$1"
    local c_args="${2:-}"
    local err_text="${3:-}"
    local search_streak="${4:-0}"
    local fail_streak="${5:-0}"
    local rep_strike="${6:-0}"

    if [ "$c_name" = "TOOL_SEARCH_THRASHING" ] || [ "$c_name" = "tool_search" -a "$search_streak" -ge 2 ]; then
        echo "TOOL_SEARCH_THRASHING"
    elif [ "$c_name" = "TARGET_FILE_THRASHING" ] || [[ "$err_text" =~ Repeated\ file\ inspection|Target\ file ]]; then
        echo "TARGET_FILE_THRASHING"
    elif [ "$c_name" = "phytology_manage" ] || [[ "$c_args" =~ phyto ]] || [[ "$err_text" =~ /phytology\ failed|subcommand ]]; then
        echo "PHYTOLOGY_ERROR"
    elif [[ "$err_text" =~ syntax\ error|unexpected\ token|command\ not\ found ]] || [ "$c_name" = "bash_exec" -a "$fail_streak" -ge 1 ]; then
        echo "SHELL_SYNTAX_ERROR"
    elif [ "$fail_streak" -ge 2 ]; then
        echo "CONSECUTIVE_TOOL_FAILURES"
    elif [ "$rep_strike" -ge 2 ]; then
        echo "ACTION_REPETITION"
    else
        echo "GENERAL_LOOP_THRASHING"
    fi
}

# ── Circuit Breaker Intelligent Prompt Perturbation Hook ─────────────
# 3-Tier Escalation Ladder:
#   Tier A: Second Configured Node (Federated Compute Ladder via endpoints.conf)
#   Tier B: Async/Direct Diagnostic LLM Request to Active Endpoint
#   Tier C: Case-Selection Static Prompt Injection Fallback
_react_circuit_breaker_perturbation() {
    local session_id="$1"
    local workdir="$2"
    local breaker_class="$3"
    local action_summary="$4"
    local last_error="$5"
    local messages_file="$6"
    local macro_file="${7:-}"

    local primary_obj=""
    [ -n "$macro_file" ] && [ -f "$macro_file" ] && primary_obj=$(jq -r '.primary_objective // empty' "$macro_file" 2>/dev/null)
    [ -z "$primary_obj" ] && primary_obj="Resolve the active engineering task in $workdir"

    local perturbation=""
    local source_tier=""

    # 1. Tier A: Second Configured Node (e.g. Tier 2 on 18080 or Tier 3 on mac-m5)
    declare -f endpoints_init &>/dev/null && endpoints_init
    local sec_url=""
    local sec_model=""

    if [ -n "${TIER2_URL:-}" ] && [ "${TIER2_URL}" != "${ACTIVE_ENDPOINT_URL:-}" ]; then
        if declare -f endpoints_probe &>/dev/null && endpoints_probe 2; then
            sec_url="$TIER2_URL"
            sec_model="${TIER2_MODEL:-champion-v5}"
            source_tier="Tier 2 (Secondary Node: $sec_url)"
        elif curl -sf --max-time 1.5 "${TIER2_URL}/health" &>/dev/null; then
            sec_url="$TIER2_URL"
            sec_model="${TIER2_MODEL:-champion-v5}"
            source_tier="Tier 2 (Secondary Node: $sec_url)"
        fi
    fi

    if [ -z "$sec_url" ] && [ -n "${TIER3_URL:-}" ] && [ "${TIER3_URL}" != "${ACTIVE_ENDPOINT_URL:-}" ]; then
        if declare -f endpoints_probe &>/dev/null && endpoints_probe 3; then
            sec_url="$TIER3_URL"
            sec_model="${TIER3_MODEL:-glm-5.3-flash}"
            source_tier="Tier 3 (Frontier Node: $sec_url)"
        fi
    fi

    if [ -n "$sec_url" ]; then
        ui_step "Consulting Secondary Node ($source_tier) for Circuit Breaker Perturbation..."
        local sec_prompt="You are an authoritative supervisor node. George's ReAct execution loop in repo 'blue-lodge' is thrashing.
Failure Classification: $breaker_class
Failing Action: $action_summary
Error/Output: ${last_error:0:300}
Primary Objective: $primary_obj

Respond with EXACTLY ONE concise, imperative steering directive (1-2 sentences) wrapped in [SYSTEM PERTURBATION: ...].
Specify the exact native tool name and parameters George should immediately invoke to unblock execution. Do NOT apologize or output markdown formatting."

        local sec_payload
        sec_payload=$(jq -nc \
            --arg model "$sec_model" \
            --arg prompt "$sec_prompt" \
            '{
                model: $model,
                messages: [
                    {"role": "system", "content": "You are the secondary supervisor AI providing real-time circuit-breaker steering directives."},
                    {"role": "user", "content": $prompt}
                ],
                max_tokens: 150,
                temperature: 0.2
            }')

        local sec_resp
        sec_resp=$(curl -s --max-time 4 "$sec_url/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$sec_payload" 2>/dev/null)

        local sec_content
        sec_content=$(echo "$sec_resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        if [ -n "$sec_content" ]; then
            perturbation="$sec_content"
            [[ "$perturbation" != \[* ]] && perturbation="[SYSTEM PERTURBATION ($source_tier): $perturbation]"
        fi
    fi

    # 2. Tier B: Async/Direct Diagnostic LLM Request to Active Endpoint
    if [ -z "$perturbation" ] && [ -n "${ACTIVE_ENDPOINT_URL:-}" ]; then
        ui_step "Querying Active Endpoint for Circuit Breaker Perturbation..."
        local ep_prompt="George's ReAct loop has encountered an interlock / circuit breaker trip.
Classification: $breaker_class
Action: $action_summary
Error: ${last_error:0:300}
Objective: $primary_obj

Generate a direct, imperative prompt perturbation (1-2 sentences) telling George how to unblock: which exact tool (e.g. phytology_manage, bash_exec, file_read) to call and with what exact parameters. Return only the directive."

        local ep_payload
        ep_payload=$(jq -nc \
            --arg model "${ACTIVE_ENDPOINT_MODEL:-champion-v5}" \
            --arg prompt "$ep_prompt" \
            '{
                model: $model,
                messages: [
                    {"role": "system", "content": "You are the system supervisor providing diagnostic perturbation directives."},
                    {"role": "user", "content": $prompt}
                ],
                max_tokens: 150,
                temperature: 0.3
            }')

        local ep_resp
        ep_resp=$(curl -s --max-time 3 "$ACTIVE_ENDPOINT_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$ep_payload" 2>/dev/null)

        local ep_content
        ep_content=$(echo "$ep_resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        if [ -n "$ep_content" ]; then
            perturbation="[SYSTEM PERTURBATION (Async Endpoint): $ep_content]"
            source_tier="Active Endpoint ($ACTIVE_ENDPOINT_URL)"
        fi
    fi

    # 3. Tier C: Case-Selection Static Prompt Injection Fallback
    if [ -z "$perturbation" ]; then
        source_tier="Static Classification Catalog"
        case "$breaker_class" in
            TARGET_FILE_THRASHING)
                perturbation="[SYSTEM PERTURBATION: Target file paging thrashing detected ($action_summary). You have inspected slices of this same file repeatedly without fulfilling your objective. Cease reading this file. Fulfill your active Honeydew milestone directly using the appropriate domain tool or synthesize your final findings.]"
                ;;
            TOOL_SEARCH_THRASHING)
                perturbation="[SYSTEM PERTURBATION: Loop thrashing detected on tool_search. Cease searching. All core tools are already loaded and mounted in your bedrock catalog: phytology_manage, bash_exec, file_read, dir_list, file_grep. To inspect living tissue health and status, call phytology_manage directly with action=\"status\" or action=\"audit\", flags=\"--cached\". Do NOT call tool_search again.]"
                ;;
            PHYTOLOGY_ERROR)
                perturbation="[SYSTEM PERTURBATION: Phytology invocation error. Valid subcommands for phytology_manage are: 'status', 'audit', 'heal', 'rollback', 'prune', 'fitness', 'lignify', 'test'. Pass the action as a simple string parameter (e.g. action=\"status\" or action=\"audit\", flags=\"--cached\"). Do NOT wrap arguments in raw JSON strings.]"
                ;;
            SHELL_SYNTAX_ERROR)
                perturbation="[SYSTEM PERTURBATION: Shell syntax error in bash_exec. Your command failed due to unmatched parentheses, unescaped wildcards, or invalid syntax. Use simple, direct commands; quote file search patterns (e.g. find . -name \"*phyto*\"); or use native file_read/file_grep/dir_list directly.]"
                ;;
            ACTION_REPETITION)
                perturbation="[SYSTEM PERTURBATION: Action repetition ceiling breached ($action_summary). Repeating this action is strictly prohibited. You MUST switch tools or significantly modify parameters immediately to proceed.]"
                ;;
            CONSECUTIVE_TOOL_FAILURES)
                perturbation="[SYSTEM PERTURBATION: Multiple consecutive tool actions failed ($last_error). Step back from this failing approach. Inspect the workspace directly using file_read on lib/phytology.sh or dir_list to verify active files.]"
                ;;
            *)
                perturbation="[SYSTEM PERTURBATION: Execution loop interlock tripped ($breaker_class: $action_summary). Halt current cycle and switch to a direct inspection tool (file_read, dir_list, or phytology_manage). Do not repeat the failed action.]"
                ;;
        esac
    fi

    ui_warn "⚡ Prompt Perturbation Injected via $source_tier: ${perturbation:0:120}..."
    if [ -n "$messages_file" ] && [ -f "$messages_file" ]; then
        jq --arg p "$perturbation" '. += [{"role": "user", "content": $p}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
    fi

    _react_trace "$workdir" "circuit_breaker_perturbation" "$(jq -cn --arg cls "$breaker_class" --arg tier "$source_tier" --arg p "$perturbation" '{classification:$cls, source:$tier, perturbation:$p}')"
    if declare -f telemetry_record_anomaly &>/dev/null; then
        telemetry_record_anomaly "$session_id" "CIRCUIT_BREAKER_PERTURBATION" "$breaker_class" "$perturbation" >/dev/null 2>&1 || true
    fi

    echo "$perturbation"
}

# ── Circuit Breaker Hard Trip & Quarantine ──────────────────────────
_react_trip_circuit_breaker() {
    local session_id="$1"
    local workdir="$2"
    local reason="$3"
    local action_summary="$4"
    local messages_file="$5"
    local macro_file="$6"
    local last_error="${7:-}"

    ui_err "⚡ [CIRCUIT BREAKER TRIPPED] $reason (Action: $action_summary)"
    _react_trace "$workdir" "circuit_breaker_tripped" "$(jq -cn --arg reason "$reason" --arg act "$action_summary" '{reason:$reason, action:$act}')"

    jq '.status = "CIRCUIT_BREAKER_TRIPPED"' "$macro_file" > "${macro_file}.tmp" 2>/dev/null && mv "${macro_file}.tmp" "$macro_file" 2>/dev/null || true

    # Structured alert artifact
    mkdir -p "$LODGE_DIR/.george/alerts" 2>/dev/null || true
    local alert_file="$LODGE_DIR/.george/alerts/alert_${session_id}.json"
    local alert_ts
    alert_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")

    local branch_now=""
    if git -C "$workdir" rev-parse --is-inside-work-tree &>/dev/null; then
        branch_now=$(git -C "$workdir" branch --show-current 2>/dev/null || echo "detached")
        # Quarantine checkpoint commit if dirty
        if [ -n "$(git -C "$workdir" status --porcelain 2>/dev/null)" ]; then
            local quarantine_branch="quarantine/${session_id}"
            (
                cd "$workdir" || exit 0
                local stash_sha
                stash_sha=$(git stash create "quarantine(checkpoint): preserve dirty state from tripped breaker ($session_id)" 2>/dev/null || true)
                if [ -n "$stash_sha" ]; then
                    git branch -f "$quarantine_branch" "$stash_sha" >/dev/null 2>&1 || true
                fi
            ) 2>/dev/null || true
            ui_warn "Dirty state preserved on quarantine branch 'quarantine/${session_id}'"
        fi
    fi

    jq -n \
        --arg id "$session_id" \
        --arg ts "$alert_ts" \
        --arg reason "$reason" \
        --arg act "$action_summary" \
        --arg err "${last_error:0:1000}" \
        --arg branch "${branch_now:-none}" \
        --arg workdir "$workdir" \
        '{
            id: $id,
            timestamp: $ts,
            status: "CIRCUIT_BREAKER_TRIPPED",
            reason: $reason,
            action: $act,
            error: $err,
            branch: $branch,
            workdir: $workdir
        }' > "$alert_file" 2>/dev/null || true

    # Prompt Perturbation Hook (Escalation to Secondary Node / Async LLM / Static Catalog)
    local trip_cls
    trip_cls=$(_react_classify_circuit_state "$action_summary" "" "$reason: $last_error" 0 3 3)
    _react_circuit_breaker_perturbation "$session_id" "$workdir" "$trip_cls" "$action_summary" "$reason: $last_error" "$messages_file" "$macro_file"

    # MQTT Broadcast
    if declare -f task_sync_signal &>/dev/null; then
        task_sync_signal "$session_id" "circuit_breaker" "$(cat "$alert_file" 2>/dev/null || echo "{}")" >/dev/null 2>&1 || true
    fi

    # Telemetry
    if declare -f telemetry_record_anomaly &>/dev/null; then
        telemetry_record_anomaly "$session_id" "CIRCUIT_BREAKER" "react.sh" "$reason: $action_summary" >/dev/null 2>&1 || true
    fi
    if declare -f telemetry_task_end &>/dev/null; then
        telemetry_task_end "$session_id" 75 "CIRCUIT_BREAKER_TRIPPED" >/dev/null 2>&1 || true
    fi
    declare -f agent_sm_transition &>/dev/null && agent_sm_transition "$session_id" "CIRCUIT_BREAKER_TRIPPED" "$reason" 2>/dev/null || true
    declare -f fifo_channel_close &>/dev/null && fifo_channel_close "$session_id" 2>/dev/null || true
}

# ── Self-Healing Circuit Breaker ─────────────────────────────────────
# Instead of hard-exiting when repetition is detected, evaluates accumulated
# evidence in scratchpad.md and either forces transition to synthesis or perturbs.
_react_self_heal_circuit_breaker() {
    local session_id="${1:-}"
    local workdir="${2:-$PWD}"
    local session_dir="${3:-}"
    local c_name="${4:-tool}"
    local c_args="${5:-}"
    local messages_file="${6:-}"
    local macro_file="${7:-}"
    local rep_strike="${8:-3}"

    local scratchpad="$session_dir/scratchpad.md"
    local has_evidence=0
    if [ -f "$scratchpad" ]; then
        local scratch_bytes
        scratch_bytes=$(wc -c < "$scratchpad" 2>/dev/null || echo 0)
        local bullet_count
        bullet_count=$(grep -cE '^[[:space:]]*(\*|-)' "$scratchpad" 2>/dev/null || echo 0)
        if [ "$scratch_bytes" -gt 100 ] || [ "$bullet_count" -ge 2 ]; then
            has_evidence=1
        fi
    fi

    if [ "$has_evidence" -eq 1 ]; then
        ui_warn "⚡ Self-healing circuit breaker: Action repetition detected on '$c_name' (Strike $rep_strike), but scratchpad.md contains verified findings."
        ui_info "⚡ Transitioning loop from research to synthesis to prevent session stall."
        local heal_adv="[CIRCUIT HEALER: Repetition ceiling reached on '$c_name'. Cease repeating this action. You have already gathered verified facts in scratchpad.md. Proceed immediately to synthesize your final report and deliver your findings in clean markdown. Do NOT execute redundant tool calls.]"
        jq --arg a "$heal_adv" '. += [{"role": "user", "content": $a}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
        _react_trace "$workdir" "circuit_healed" "$(jq -cn --arg tool "$c_name" --arg action "transition_to_synthesis" '{tool:$tool, action:$action}')"
        return 0
    else
        if [ "$rep_strike" -ge 4 ]; then
            ui_err "⚡ Action repetition ceiling breached with zero scratchpad progress. Tripping hard circuit breaker."
            _react_trip_circuit_breaker "$session_id" "$workdir" "Action repetition ceiling reached ($c_name)" "$c_name ($c_args)" "$messages_file" "$macro_file" "Repeated action with empty scratchpad"
            return 75
        else
            ui_warn "⚡ Action repetition strike $rep_strike on '$c_name'. Perturbing prompt with alternative vector."
            _react_circuit_breaker_perturbation "$session_id" "$workdir" "ACTION_REPETITION" "$c_name ($c_args)" "Action repetition strike $rep_strike" "$messages_file" "$macro_file"
            return 0
        fi
    fi
}

# ── Mid-Turn Sub-Turn LLM Digest & Scratchpad Synchronization ────────
# Distills raw observation into dense facts, metrics, and citations,
# storing them in scratchpad.md, memory.md, and mem:active_task.
_react_digest_tool_output() {
    local c_id="${1:-}"
    local c_name="${2:-tool}"
    local c_args="${3:-}"
    local resp_content="${4:-}"
    local active_step="${5:-}"
    local session_dir="${6:-}"
    local workdir="${7:-$PWD}"
    local goal="${8:-}"

    local scratchpad="$session_dir/scratchpad.md"
    local g_scratchpad="$workdir/.george/scratchpad.md"
    local memory_file="$session_dir/memory.md"
    mkdir -p "$session_dir" "$workdir/.george" "$workdir/.george/memories" 2>/dev/null || true

    # Archive raw observation to workspace
    mkdir -p "$session_dir/observations" 2>/dev/null || true
    local obs_fname="$c_id"
    [[ "$obs_fname" != call_* ]] && obs_fname="call_${obs_fname}"
    [ -z "$obs_fname" ] || [ "$obs_fname" = "call_" ] && obs_fname="call_0"
    printf '%s\n' "$resp_content" > "$session_dir/observations/${obs_fname}.txt" 2>/dev/null || true

    # If response is very short (< 60 chars) and lacks numbers or links, record directly
    if [ ${#resp_content} -lt 60 ] && ! echo "$resp_content" | grep -qE '(\b[0-9]+\b|https?://|error|fail|status)'; then
        local raw_snippet="${resp_content:0:150}"
        local ts
        ts=$(date '+%H:%M:%S')
        echo -e "\n### [${ts}] ${c_name} (${c_args:0:100})\n- **Milestone**: ${active_step}\n- ${raw_snippet}" >> "$scratchpad"
        cp "$scratchpad" "$g_scratchpad" 2>/dev/null || true
        ui_dim "  [digest] Brief observation (${#resp_content} chars) recorded to scratchpad" >&2
        echo "$raw_snippet"
        return 0
    fi

    local ep_url="${ACTIVE_ENDPOINT_URL:-http://127.0.0.1:8080}"
    local digest_result=""
    local digest_timeout="${REACT_DIGEST_TIMEOUT:-25}"

    local excerpt="${resp_content:0:4500}"
    local args_snippet="${c_args:0:200}"

    ui_dim "  [digest] Sub-turn LLM distilling observation from ${c_name} (${#resp_content} chars)..." >&2

    local sys_prompt="You are the Blue Lodge Evidence Digest Engine. Your sole task is to distill raw tool observations into dense, structured, factual evidence for the agent's scratchpad.
Extract:
1. Exact numbers, financial figures, metrics, dates, entity names, status codes.
2. Direct URLs, citations, or file paths.
3. Key factual answers directly addressing the active milestone.
Do NOT output conversation, introductions, or pleasantries. Format as concise markdown bullet points."

    local user_prompt="CURRENT ACTIVE MILESTONE:
${active_step}

TOOL EXECUTED:
${c_name}(${args_snippet})

RAW OBSERVATION (excerpt):
${excerpt}

Distill key factual findings, metrics, and citations:"

    local payload
    payload=$(jq -n \
        --arg sys "$sys_prompt" \
        --arg user "$user_prompt" \
        '{
            messages: [
                {"role": "system", "content": $sys},
                {"role": "user", "content": $user}
            ],
            temperature: 0.1,
            max_tokens: 500,
            chat_template_kwargs: {enable_thinking: false},
            stream: false
        }' 2>/dev/null)

    local resp_json
    resp_json=$(curl -s --max-time "$digest_timeout" "$ep_url/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    digest_result=$(echo "$resp_json" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

    # Heuristic fallback if LLM is unavailable or times out
    if [ -z "$digest_result" ]; then
        ui_warn "  [digest] Sub-turn LLM unavailable or timed out; generating structured heuristic digest" >&2
        local extracted_urls
        extracted_urls=$(echo "$resp_content" | grep -oE 'https?://[^ ">\t]+' | head -n 5 | tr '\n' ' ')
        local head_lines
        head_lines=$(echo "$resp_content" | grep -vE '^\[debug\]' | sed '/^[[:space:]]*$/d' | head -n 6 | tr '\n' ' ')
        digest_result="- Key Output: ${head_lines:0:300}"
        if [ -n "$extracted_urls" ]; then
            digest_result="${digest_result}\n- Citations: ${extracted_urls}"
        fi
    else
        # Strip think tags if present
        digest_result=$(echo "$digest_result" | sed -E 's/<think>.*<\/think>//g')
        local fact_count
        fact_count=$(echo "$digest_result" | grep -c '^[*-]' || echo 1)
        [ "$fact_count" -eq 0 ] && fact_count=1
        ui_ok "  [digest] Sub-turn LLM extracted ${fact_count} structured evidence facts" >&2
    fi

    # Atomically append to scratchpad.md
    local ts
    ts=$(date '+%H:%M:%S')
    {
        echo ""
        echo "### [${ts}] ${c_name} (${args_snippet})"
        echo "- **Milestone**: ${active_step}"
        echo "${digest_result}"
    } >> "$scratchpad"
    cp "$scratchpad" "$g_scratchpad" 2>/dev/null || true

    # Atomically append to memory.md under discoveries
    if [ -f "$memory_file" ]; then
        if ! grep -q "## Active Discoveries & Working Memory" "$memory_file"; then
            echo -e "\n## Active Discoveries & Working Memory\n" >> "$memory_file"
        fi
        echo "- [${ts}] ${c_name}: $(echo "$digest_result" | head -n 3 | tr '\n' ' ')" >> "$memory_file"
    fi

    # Atomically append to mem:active_task
    local slug="${AGENT_ACTIVE_TASK_SLUG:-active_report}"
    local mem_task_file="$workdir/.george/memories/${slug}.md"
    mkdir -p "$(dirname "$mem_task_file")" 2>/dev/null || true
    {
        echo ""
        echo "#### [${ts}] Evidence: ${c_name} (${args_snippet})"
        echo "${digest_result}"
    } >> "$mem_task_file" 2>/dev/null || true

    ui_dim "  [digest] Updated scratchpad.md & mem:${slug}" >&2

    echo "$digest_result"
}

# ── Mid-Turn Milestone Evaluator ─────────────────────────────────────
# Evaluates accumulated scratchpad evidence against the active Honeydew step.
# If SATISFIED, marks item complete, resolves promise, triggers DAG expansion.
# If IN_PROGRESS, outputs concise directive for next tool call.
_react_eval_milestone_evidence() {
    local workdir="${1:-$PWD}"
    local session_dir="${2:-}"
    local active_step_id="${3:-1}"
    local active_step_task="${4:-}"
    local goal="${5:-}"
    local last_digest="${6:-}"

    local scratchpad="$session_dir/scratchpad.md"
    local hd_file="$workdir/.george/honeydew.json"
    local macro_file="$workdir/.george/macro_memory.json"
    [ ! -f "$hd_file" ] && return 0

    local scratch_excerpt=""
    [ -f "$scratchpad" ] && scratch_excerpt=$(tail -n 250 "$scratchpad" 2>/dev/null)

    local ep_url="${ACTIVE_ENDPOINT_URL:-http://127.0.0.1:8080}"
    local eval_timeout="${REACT_EVAL_TIMEOUT:-25}"

    ui_dim "  [evaluator] Sub-turn LLM evaluating Step ${active_step_id} against accumulated evidence..." >&2

    local sys_prompt="You are the Blue Lodge Milestone Evaluator.
Determine whether the accumulated scratchpad evidence satisfies the Current Active Milestone.
If the scratchpad contains the core metrics, answers, or facts addressing the active milestone, mark it SATISFIED.
Respond ONLY with valid JSON:
{\"verdict\": \"SATISFIED\" or \"IN_PROGRESS\", \"reason\": \"<1-sentence explanation>\", \"suggested_action\": \"<concise recommendation for next tool or parameter, or empty if satisfied>\"}"

    local user_prompt="PRIMARY OBJECTIVE:
${goal}

CURRENT ACTIVE MILESTONE (Step ${active_step_id}):
${active_step_task}

LATEST ACCUMULATED SCRATCHPAD EVIDENCE:
${scratch_excerpt:-No scratchpad evidence yet.}

Evaluate if Step ${active_step_id} is SATISFIED by the evidence, or what remains:"

    local payload
    payload=$(jq -n \
        --arg sys "$sys_prompt" \
        --arg user "$user_prompt" \
        '{
            messages: [
                {"role": "system", "content": $sys},
                {"role": "user", "content": $user}
            ],
            temperature: 0.1,
            max_tokens: 500,
            chat_template_kwargs: {enable_thinking: false},
            stream: false
        }' 2>/dev/null)

    local resp_json
    resp_json=$(curl -s --max-time "$eval_timeout" "$ep_url/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    local content
    content=$(echo "$resp_json" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

    local verdict="IN_PROGRESS"
    local reason=""
    local suggested_action=""

    if [ -n "$content" ]; then
        content=$(echo "$content" | sed -E 's/<think>.*<\/think>//g')
        local parsed_json
        parsed_json=$(echo "$content" | grep -oE '\{.*\}' | tail -n 1 2>/dev/null)
        if [ -n "$parsed_json" ] && echo "$parsed_json" | jq empty 2>/dev/null; then
            verdict=$(echo "$parsed_json" | jq -r '.verdict // "IN_PROGRESS"')
            reason=$(echo "$parsed_json" | jq -r '.reason // ""')
            suggested_action=$(echo "$parsed_json" | jq -r '.suggested_action // ""')
        elif [[ "$content" =~ SATISFIED ]]; then
            verdict="SATISFIED"
            reason="Evaluation satisfied milestone requirements."
        fi
    fi

    # Fallback heuristic evaluation
    if [ "$verdict" != "SATISFIED" ]; then
        local lower_task="${active_step_task,,}"
        if [[ "$lower_task" =~ (search|fetch|find|inspect|read|check|gather|identify|research|collect|analyze|review|compile|explore|obtain|extract) ]] && [ -f "$scratchpad" ]; then
            if grep -qiE '(\$[0-9]+|[0-9]+\s*(billion|million|usd)|revenue|eps|operating cash|status: OK|status = "OK"|passed)' "$scratchpad" 2>/dev/null && [ $(wc -l < "$scratchpad" 2>/dev/null || echo 0) -ge 10 ]; then
                verdict="SATISFIED"
                reason="Substantial empirical findings and metrics accumulated in scratchpad."
            fi
        fi
    fi

    if [ "$verdict" = "SATISFIED" ]; then
        ui_ok "  [evaluator] Step $active_step_id SATISFIED: ${reason:-Milestone requirements met}" >&2
        jq --argjson pid "$active_step_id" \
            '(.items[] | select(.id == $pid)).status = "done"' \
            "$hd_file" > "${hd_file}.tmp" 2>/dev/null && mv "${hd_file}.tmp" "$hd_file"

        local ts_now
        ts_now=$(date '+%Y-%m-%d %H:%M:%S')
        jq --arg ts "$ts_now" --arg obj "$active_step_task" --arg sum "${reason:-Step completed}" \
            '.completed_milestones += [{"timestamp": $ts, "objective": $obj, "summary": $sum, "status": "SATISFIED"}]' \
            "$macro_file" > "${macro_file}.tmp" 2>/dev/null && mv "${macro_file}.tmp" "$macro_file" 2>/dev/null || true

        local prom_dir="${FIFO_IPC_DIR:-/tmp/blue_lodge_ipc}/promises"
        mkdir -p "$prom_dir" 2>/dev/null || true
        local fin_ts
        fin_ts=$(date +%s)
        jq -n --arg mid "$active_step_id" --arg task "$active_step_task" --arg sum "$reason" --argjson ts "$fin_ts" \
            '{milestone_id: $mid, task: $task, summary: $sum, status: "RESOLVED", resolved_at: $ts}' \
            > "$prom_dir/milestone_${active_step_id}.json" 2>/dev/null || true

        _react_expand_honeydew_dag "$goal" "$workdir" "$session_dir"

        local new_active
        new_active=$(jq -r '[.items[]? | select(.status != "done")][0] | if . then "Step " + (.id|tostring) + ": " + .task else "Synthesize Final Deliverable" end' "$hd_file" 2>/dev/null)
        ui_info "  [honeydew] Advanced to: $new_active" >&2
        echo "SATISFIED|${reason}|${new_active}"
    else
        ui_info "  [evaluator] Step $active_step_id IN_PROGRESS: ${reason:-Evidence gathering in progress}" >&2
        if [ -n "$suggested_action" ]; then
            ui_dim "  [evaluator] Guidance: $suggested_action" >&2
        fi
        echo "IN_PROGRESS|${reason}|${suggested_action}"
    fi
}

# ── Outer Loop Dynamic DAG Expansion ─────────────────────────────────
# Adjusts remaining Honeydew milestones using discovered evidence.
_react_expand_honeydew_dag() {
    local goal="$1"
    local workdir="${2:-$PWD}"
    local session_dir="$3"
    [ "${AGENT_MODE:-}" = "worker" ] && return 0

    local hd_file="$workdir/.george/honeydew.json"
    local macro_file="$workdir/.george/macro_memory.json"
    local scratchpad="$session_dir/scratchpad.md"
    local strat_script="$workdir/lib/honeydew_strategist.py"
    [ ! -f "$strat_script" ] && strat_script="/home/wsl-ops/blue-lodge/lib/honeydew_strategist.py"

    if [ -f "$strat_script" ] && [ -f "$hd_file" ]; then
        python3 "$strat_script" --expand "$goal" "$hd_file" "$macro_file" "$scratchpad" "${ACTIVE_ENDPOINT_URL:-http://127.0.0.1:8080}" >/dev/null 2>&1 || true
    fi
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

# ── Honeydew Dynamic Multi-Step Planner ──────────────────────────────
_react_ensure_honeydew_plan() {
    local task="$1"
    local workdir="${2:-$PWD}"
    local gdir="$workdir/.george"
    local hd_file="$gdir/honeydew.json"
    local force="${3:-0}"
    mkdir -p "$gdir" 2>/dev/null || true

    # Check existing plan
    local should_rebuild=1
    if [ "$force" -eq 0 ] && [ -f "$hd_file" ]; then
        local cur_task pending_count
        cur_task=$(jq -r '.primary_task // empty' "$hd_file" 2>/dev/null)
        pending_count=$(jq -r '[.items[]? | select(.status != "done")] | length' "$hd_file" 2>/dev/null || echo 0)
        # Only reuse if same task AND there are still pending steps remaining
        if [ "$cur_task" = "$task" ] && [ "$pending_count" -gt 0 ]; then
            should_rebuild=0
        fi
    fi

    if [ "$should_rebuild" -eq 1 ]; then
        local lower_task="${task,,}"
        local items_json=""

        # ── Pre-Loop Strategist (Option 4A): Agentic DAG Decomposition ──
        local ep_url="${ACTIVE_ENDPOINT_URL:-http://127.0.0.1:8080}"
        local strat_script="$workdir/lib/honeydew_strategist.py"
        [ ! -f "$strat_script" ] && strat_script="/home/wsl-ops/blue-lodge/lib/honeydew_strategist.py"

        if [ -f "$strat_script" ]; then
            items_json=$(python3 "$strat_script" "$task" "$ep_url" 2>/dev/null || true)
        fi

        local item_count
        item_count=$(echo "$items_json" | jq 'length' 2>/dev/null || echo 0)
        if [ "$item_count" -ge 2 ]; then
            ui_dim "  ✓ Pre-Loop Strategist generated $item_count bespoke DAG milestones"
        else
            items_json='[
                {"id": 1, "task": "Execute targeted action to fulfill the objective", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0},
                {"id": 2, "task": "Synthesize results and deliver final response to operator", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0}
            ]'
        fi

        jq -n --arg task "$task" --argjson items "$items_json" \
            '{"primary_task": $task, "items": $items}' > "$hd_file" 2>/dev/null || true

        # Initialize FIFO IPC promise registry for each milestone
        if declare -f fifo_ipc_init &>/dev/null; then
            fifo_ipc_init 2>/dev/null || true
            local prom_dir="${FIFO_IPC_DIR:-/tmp/blue_lodge_ipc}/promises"
            mkdir -p "$prom_dir" 2>/dev/null || true
            local now_ts
            now_ts=$(date +%s)
            for m_id in $(jq -r '.items[]?.id // empty' "$hd_file" 2>/dev/null); do
                jq -n --arg mid "$m_id" --argjson ts "$now_ts" \
                    '{milestone_id: $mid, status: "PENDING", created_at: $ts}' \
                    > "$prom_dir/milestone_${m_id}.json" 2>/dev/null || true
            done
        fi
    fi

    # ALWAYS display the plan visibly on TTY and transcript
    ui_section "Honeydew Execution Plan"
    jq -r '.items[] | "  [" + (if .status == "done" then "✓" else " " end) + "] Step " + (.id|tostring) + ": " + .task' \
        "$hd_file" 2>/dev/null | while IFS= read -r line; do
        ui_info "$line"
    done
    if declare -f transcript_log_block &>/dev/null; then
        local plan_txt
        plan_txt=$(jq -r '.items[] | "  [" + (if .status == "done" then "✓" else " " end) + "] Step " + (.id|tostring) + ": " + .task' "$hd_file" 2>/dev/null)
        transcript_log_block "Honeydew Execution Plan" "$plan_txt"
    fi
}

_react_advance_honeydew_plan() {
    local workdir="${1:-$PWD}"
    local action_name="${2:-}"
    local action_args="${3:-}"
    local hd_file="$workdir/.george/honeydew.json"
    [ ! -f "$hd_file" ] && return 0
    [ "${AGENT_MODE:-}" = "worker" ] && return 0

    # Find first pending item
    local pending_id
    pending_id=$(jq -r '[.items[] | select(.status != "done")][0].id // empty' "$hd_file" 2>/dev/null)
    [ -z "$pending_id" ] && return 0

    local pending_task
    pending_task=$(jq -r --argjson pid "$pending_id" '.items[] | select(.id == $pid) | .task // empty' "$hd_file" 2>/dev/null)
    local lower_ptask="${pending_task,,}"
    local lower_args="${action_args,,}"
    local should_advance=0

    # Direct terminal tool call takes absolute precedence
    if [ "$action_name" = "milestone_complete" ]; then
        should_advance=1
    # 1. Cron / Script creation milestones (must be mutating to advance)
    elif [[ "$lower_ptask" =~ (create|register|write|implement).*(cron|job|script) ]]; then
        if [[ "$action_name" =~ file_write|file_edit ]] && [[ "$lower_args" =~ cron_jobs|\.sh ]]; then
            should_advance=1
        elif [[ "$action_name" == "bash_exec" ]] && _react_tool_is_mutating "$action_name" "$action_args" && [[ "$lower_args" =~ cron_jobs|\.sh ]]; then
            should_advance=1
        fi
    # 2. Verification / Execution milestones (must run verification, not just ls/cat)
    elif [[ "$lower_ptask" =~ (verify|execute|test|run).*(cron|sandbox|research) ]]; then
        if [[ "$action_name" =~ research_sandbox ]] || \
           ([[ "$action_name" == "bash_exec" ]] && [[ "$lower_args" =~ (research_sandbox|\.george/cron_jobs/.*\.sh|scripts/.*\.sh) ]] && ! [[ "$lower_args" =~ ^[[:space:]]*\"?(ls|cat|head|tail|grep|find)[[:space:]] ]]); then
            should_advance=1
        fi
    # 3. Delivery / Discord milestones
    elif [[ "$lower_ptask" =~ (deliver|send|report).*(discord|channel|user|dm|recipient) ]]; then
        if [[ "$action_name" =~ discord_send|discord_dm ]] || \
           ([[ "$action_name" == "bash_exec" ]] && [[ "$lower_args" =~ (discord_send|discord_dm|curl.*discord) ]] && ! [[ "$lower_args" =~ ^[[:space:]]*\"?(ls|cat|head|tail|grep|find)[[:space:]] ]]); then
            should_advance=1
        fi
    # 4. System status / Living Tissue diagnostics (Engine level only)
    elif [[ "$lower_ptask" =~ \b(system status|service status|diagnostics?|phytology|living tissue|system vitals|engine health)\b ]]; then
        if [[ "$action_name" =~ phytology|status|service|docker|git_status ]] || \
           [[ "$lower_args" =~ status|audit|cache-status|fitness ]] || \
           [[ "$action_name" == "bash_exec" && "$lower_args" =~ status|uptime|ps ]]; then
            should_advance=1
        elif [[ "$action_name" =~ file_read ]] && [[ "$lower_args" =~ phytology|status ]]; then
            should_advance=1
        fi
    elif [[ "$lower_ptask" =~ locate|inspect.*code|search.*sources ]]; then
        if [[ "$action_name" =~ file_read|file_grep|web_search|web_fetch|code_outline|code_symbol_get|dir_list ]]; then
            should_advance=1
        fi
    elif [[ "$lower_ptask" =~ cron|job|weather|discord|schedule ]]; then
        if [[ "$action_name" =~ file_write|file_edit ]] && [[ "$lower_args" =~ cron_jobs|weather|\.sh ]]; then
            should_advance=1
        elif [[ "$action_name" == "slash_command_exec" ]] && [[ "$lower_args" =~ cron ]]; then
            should_advance=1
        elif [[ "$action_name" == "bash_exec" ]] && _react_tool_is_mutating "$action_name" "$action_args"; then
            should_advance=1
        elif [[ "$action_name" =~ discord_send|discord_dm ]]; then
            should_advance=1
        fi
    elif [[ "$lower_ptask" =~ modify|write|patch|edit|record.*findings|distill ]]; then
        if [[ "$action_name" =~ file_edit|file_write|file_append|git_commit ]]; then
            should_advance=1
        fi
    elif [[ "$lower_ptask" =~ verify|test|harness|syntax|regression ]]; then
        if [[ "$action_name" =~ bash_exec|test|code_validate ]] && [[ "$lower_args" =~ test|check|cargo|pytest|make|npm|bash\ -n ]]; then
            should_advance=1
        fi
    else
        # Strict Option 5A contract: never advance on random irrelevant tools like backup_create or ask_operator
        if [ "$action_name" = "milestone_complete" ]; then
            should_advance=1
        elif _react_tool_is_mutating "$action_name" "$action_args"; then
            should_advance=1
        fi
    fi

    [ "$should_advance" -eq 0 ] && return 0

    # Mark current pending item as done
    jq --argjson pid "$pending_id" \
        '(.items[] | select(.id == $pid)).status = "done"' \
        "$hd_file" > "${hd_file}.tmp" 2>/dev/null && mv "${hd_file}.tmp" "$hd_file"

    # Register FIFO IPC promise resolution
    local prom_dir="${FIFO_IPC_DIR:-/tmp/blue_lodge_ipc}/promises"
    mkdir -p "$prom_dir" 2>/dev/null || true
    local fin_ts
    fin_ts=$(date +%s)
    jq -n --arg mid "$pending_id" --arg task "$pending_task" --arg act "$action_name" --argjson ts "$fin_ts" \
        '{milestone_id: $mid, task: $task, resolver_tool: $act, status: "RESOLVED", resolved_at: $ts}' \
        > "$prom_dir/milestone_${pending_id}.json" 2>/dev/null || true

    # Trigger Outer Loop Dynamic DAG Expansion
    _react_expand_honeydew_dag "" "$workdir" "${AGENT_ACTIVE_SESSION_DIR:-$workdir/.george/workspaces/${AGENT_ACTIVE_SESSION_ID:-default}}"

    local new_active
    new_active=$(jq -r '[.items[] | select(.status != "done")][0] | if . then "Step " + (.id|tostring) + ": " + .task else "All plan steps completed." end' "$hd_file" 2>/dev/null)
    ui_info "  [honeydew] Step $pending_id complete -> Next: $new_active"
}

# ── Milestone-Scoped Tool Masking ────────────────────────────────────
# Filters candidate tools schema dynamically based on the active Honeydew step.
# Prevents greedy token sampling of generic tools (e.g. dir_list, file_read)
# during status/diagnostic steps, and disables tools on final synthesis steps.
_react_scope_tools_for_step() {
    local all_tools_json="${1:-[]}"
    local active_step="${2:-}"
    local pending_tool_steps="${3:-1}"

    # Worker mode never masks tools away
    if [ "${AGENT_MODE:-}" = "worker" ]; then
        echo "$all_tools_json"
        return 0
    fi

    # Gated Synthesis Barrier (Option 5A):
    # tool_choice=none is ONLY mounted if ALL prerequisite implementation/tool steps are DONE,
    # AND the active step itself is explicitly a final synthesis step.
    if [ "$pending_tool_steps" -le 0 ] 2>/dev/null && echo "$active_step" | grep -qiE '\b(synthesize|conclude|respond to operator|final deliverable)\b'; then
        echo "[]"
        return 0
    fi

    local step_lower="${active_step,,}"
    local allowed_pattern=""

    # 1. Code Modification / Implementation / Patching / Cron & Messaging (Priority 1)
    if echo "$step_lower" | grep -qiE '\b(code|implement|edit|write|patch|refactor|fix|compile|cargo|npm|cron|schedule|register|create|build)\b'; then
        allowed_pattern='^(file_read|file_edit|file_write|symbol_patch|code_outline|code_symbol_get|file_grep|bash_exec|research_sandbox|web_search_cross_section|git_status|git_diff|git_commit|discord_send|discord_dm|ask_operator|milestone_complete)$'
    # 2. Research / Investigation / Information Retrieval
    elif echo "$step_lower" | grep -qiE '\b(research|investigate|search|web|find out|background|literature|arxiv|cve|scrape|intel|dossier)\b'; then
        allowed_pattern='^(web_search|web_search_cross_section|web_fetch|research_sandbox|scrape|file_read|file_write|recall_search|pdf_read|bash_exec|ask_operator|milestone_complete)$'
    # 3. Testing / Verification
    elif echo "$step_lower" | grep -qiE '\b(test|verify|validate|benchmark|suite|check)\b'; then
        allowed_pattern='^(bash_exec|file_read|file_write|research_sandbox|git_status|git_diff|discord_send|discord_dm|ask_operator|milestone_complete)$'
    # 4. Status / Diagnostics / Living Tissue Inspection (System level only)
    elif echo "$step_lower" | grep -qiE '\b(system status|service status|diagnostics?|phytology|living tissue|system vitals|engine health)\b'; then
        allowed_pattern='^(phytology_manage|service_manage|vitals_manage|git_status|bash_exec|ask_operator|milestone_complete)$'
    fi

    if [ -n "$allowed_pattern" ]; then
        local scoped
        scoped=$(echo "$all_tools_json" | jq -c --arg pat "$allowed_pattern" '[.[] | select(.function.name | test($pat))]' 2>/dev/null)
        if [ -n "$scoped" ] && [ "$scoped" != "[]" ]; then
            echo "$scoped"
            return 0
        fi
    fi

    # Fallback to full active profile tools
    echo "$all_tools_json"
}

# ── Option C: Two-Tier Recovery Cascade ──────────────────────────────
# Tier 1: Local micro-retry with injected failure advisory
# Tier 2: Escalate to Strategist rewrite inserting dedicated remediation milestone
_react_dag_handle_failure() {
    local workdir="${1:-$PWD}"
    local milestone_id="${2:-1}"
    local failure_reason="${3:-Unknown failure}"
    local hd_file="$workdir/.george/honeydew.json"
    [ ! -f "$hd_file" ] && return 1

    local current_retries
    current_retries=$(jq -r --argjson mid "$milestone_id" '(.items[] | select(.id == $mid)).retry_count // 0' "$hd_file" 2>/dev/null || echo 0)

    if [ "$current_retries" -lt 1 ]; then
        # Tier 1: Local Micro-Retry
        ui_warn "  [recovery:tier-1] Milestone $milestone_id failed contract ($failure_reason). Triggering local micro-retry (1/1)..."
        jq --argjson mid "$milestone_id" \
           '(.items[] | select(.id == $mid)).retry_count = 1' "$hd_file" > "${hd_file}.tmp" 2>/dev/null && mv "${hd_file}.tmp" "$hd_file"
        return 0
    else
        # Tier 2: Escalate to Strategist DAG Rewrite
        ui_err "  [recovery:tier-2] Milestone $milestone_id failed micro-retry. Escalating to Strategist DAG rewrite..."
        local rem_id=$((milestone_id * 10 + 1))
        local rem_task="Diagnose and remediate blocker: $failure_reason"
        
        local updated_items
        updated_items=$(jq --argjson mid "$milestone_id" --argjson rid "$rem_id" --arg rtask "$rem_task" '
            .items |= map(
                if .id == $mid then
                    .status = "remediating"
                else . end
            ) | .items = [{"id": $rid, "task": $rtask, "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0}] + .items
        ' "$hd_file" 2>/dev/null)
        
        if [ -n "$updated_items" ]; then
            echo "$updated_items" > "$hd_file"
            ui_info "  [recovery:tier-2] Inserted remediation Step $rem_id into DAG before resuming."
        fi
        return 2
    fi
}

# ── Main ReAct Runner ────────────────────────────────────────────────
react_run() {
    export _LODGE_IN_TASK=1
    trap 'export _LODGE_IN_TASK=0; stty sane 2>/dev/null || true' RETURN 2>/dev/null || true
    local goal="$1"
    local workdir="${2:-$PWD}"
    local max_turns="${3:-${AGENT_MAX_TURNS:-${AGENT_MAX_MILESTONES:-30}}}"
    local agent_temp="${AGENT_LLM_TEMPERATURE:-1.0}"
    local tool_filter="${6:-${REACT_TOOL_FILTER:-}}"
    local mode="${8:-${AGENT_MODE:-standard}}"

    # Robust argument polymorphism: if arg 3 is non-numeric, it was passed as profile/tool_filter
    if [ -n "${3:-}" ] && ! [[ "$3" =~ ^[0-9]+$ ]]; then
        tool_filter="$3"
        max_turns="${AGENT_MAX_TURNS:-${AGENT_MAX_MILESTONES:-30}}"
    fi

    # Zero-latency task classifier: if tool_filter is empty, "all", or "auto", classify by objective
    if [ -z "$tool_filter" ] || [ "$tool_filter" = "all" ] || [ "$tool_filter" = "auto" ]; then
        if declare -f native_tools_classify_profile &>/dev/null; then
            tool_filter=$(native_tools_classify_profile "$goal")
        else
            tool_filter="default"
        fi
    fi

    # Auto-detect worker mode from profile
    if [ "$tool_filter" = "worker" ] || [ "$tool_filter" = "sandbox_worker" ] || [ "$tool_filter" = "worker_research" ] || [ "$mode" = "worker" ]; then
        mode="worker"
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

    local agent_temp="${AGENT_LLM_TEMPERATURE:-${ACTIVE_ENDPOINT_TEMPERATURE:-1.0}}"
    local agent_topp="${AGENT_LLM_TOP_P:-${ACTIVE_ENDPOINT_TOP_P:-0.95}}"
    local agent_max_tok="${AGENT_MAX_TOKENS:-${ACTIVE_ENDPOINT_MAX_TOKENS:-16384}}"
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
    local hd_file="$gdir/honeydew.json"
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

    local session_id_arg="${REACT_SESSION_ID:-}"
    if [ -z "$session_id_arg" ]; then
        if [ -n "${7:-}" ]; then
            session_id_arg="$7"
        elif [ -n "${5:-}" ] && ! [[ "${5:-}" =~ ^[0-9]+$ ]]; then
            session_id_arg="$5"
        fi
    fi
    local session_id="${session_id_arg:-session_$(date +%Y%m%d_%H%M%S)_$$}"
    local session_dir="$gdir/workspaces/$session_id"
    mkdir -p "$session_dir"

    # Initialize FIFO IPC Channel & Credit Flow Control
    local init_credits
    init_credits=$(declare -f limits_get &>/dev/null && limits_get FLOW_CONTROL_DEFAULT_CREDITS 5 || echo 5)
    declare -f fifo_channel_open &>/dev/null && fifo_channel_open "$session_id" "$init_credits" 2>/dev/null || true

    # Initialize State Machine & Pseudo-LRU Cache
    declare -f agent_sm_register &>/dev/null && agent_sm_register "$session_id" "react_worker" "$goal" 2>/dev/null || true
    declare -f agent_sm_transition &>/dev/null && agent_sm_transition "$session_id" "RUNNING" "Beginning ReAct loop" 2>/dev/null || true
    declare -f cache_init &>/dev/null && cache_init

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

    # Initialize Honeydew execution plan
    if [ "$mode" = "worker" ]; then
        mkdir -p "$gdir" 2>/dev/null || true
        cat > "$hd_file" <<EOF
{
  "primary_task": $(jq -n --arg g "$goal" '$g'),
  "items": [
    {
      "id": 1,
      "task": "Execute delegated task and deliver results",
      "status": "pending",
      "tier": ${ACTIVE_TIER:-1},
      "depends_on": [],
      "endpoint_tier": ${ACTIVE_TIER:-1},
      "retry_count": 0
    }
  ]
}
EOF
        ui_section "Worker Execution Plan"
        ui_step "Step 1: Execute delegated task and deliver results"
    else
        # Force fresh agentic decomposition for parent orchestrator
        _react_ensure_honeydew_plan "$goal" "$workdir" 1
    fi

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

    # Prepare initial user message anchored to plan
    local initial_user_msg
    if [ "$mode" = "worker" ]; then
        initial_user_msg="PRIMARY OBJECTIVE (DELEGATED WORKER):\n$goal\n\nSANDBOX WORKSPACE:\n$workdir\n\nDIRECTIVES FOR WORKER:\n1. Execute all actions directly inside your isolated sandbox workspace.\n2. If your task requires creating or modifying code: test your changes thoroughly using bash_exec. When verified, submit your deliverable as a Pull Request to Sovereign Gitea using gitea_pr_create (or git commit/push to your subagent branch), and return the PR number and summary.\n3. If your task is research or query: retrieve the information and return your findings directly as text.\n4. Conclude with a clear summary of your work."
    else
        local active_step
        active_step=$(jq -r '[.items[]? | select(.status != "done")][0] | if . then "Step " + (.id|tostring) + ": " + .task else "Step 1" end' "$hd_file" 2>/dev/null)
        local plan_checklist
        plan_checklist=$(jq -r '.items[]? | "- [" + (if .status == "done" then "✓" else " " end) + "] Step " + (.id|tostring) + ": " + .task' "$hd_file" 2>/dev/null)

        initial_user_msg="PRIMARY OBJECTIVE:\n$goal\n\nHONEYDEW EXECUTION PLAN:\n$plan_checklist\n\nCURRENT ACTIVE MILESTONE:\n$active_step\n\nDIRECTIVE: Focus exclusively on executing $active_step directly using domain getter/action tools."
    fi

    # Initialize messages.json
    jq -n \
        --arg sys "$sys_prompt" \
        --arg user "$initial_user_msg" \
        '[
            {"role": "system", "content": $sys},
            {"role": "user", "content": $user}
        ]' > "$messages_file"

    local running_tokens=0
    local turn=1
    local consecutive_empty_turns=0
    local consecutive_premature_plans=0
    local thrashing_target_streak=0
    local tool_search_streak=0
    local same_tool_streak=0
    local last_invoked_tool=""
    local same_target_path_streak=0
    local last_inspected_path=""

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
        if [ -f "${TMPDIR:-/tmp}/.lodge-cancel-$$" ] || [ "${_LODGE_CANCELLED:-0}" -eq 1 ]; then
            ui_warn "Task cancelled via signal."
            export _LODGE_IN_TASK=0
            stty sane 2>/dev/null
            return 130
        fi
        local current_hd_step="Step 1"
        local current_hd_id=1
        if [ -f "$hd_file" ]; then
            current_hd_id=$(jq -r '[.items[]? | select(.status != "done")][0].id // 1' "$hd_file" 2>/dev/null || echo 1)
            current_hd_step=$(jq -r '[.items[]? | select(.status != "done")][0] | if . then "Step " + (.id|tostring) + ": " + .task else "Synthesize Final Deliverable" end' "$hd_file" 2>/dev/null)
        fi
        [ -z "$current_hd_step" ] && current_hd_step="Synthesize Final Deliverable"
        export CURRENT_ACTIVE_MILESTONE_ID="$current_hd_id"
        printf "\n${C_BOLD}${C_CYAN}── Turn %d/%d | Active Honeydew: %s ──────────────────────────────${C_RESET}\n" "$turn" "$max_turns" "$current_hd_step"

        # Loop Management: Honeydew synthesis transition gate
        local pending_tool_steps=0
        if [ -f "$hd_file" ]; then
            pending_tool_steps=$(jq -r '[.items[]? | select(.status != "done" and (
                (.task | test("^(Step [0-9]+: )?(create|build|write|implement|run|test|execute|verify|inspect|check|configure|schedule|register|deploy|research|search)\\b"; "i")) or
                ((.task | test("^(Step [0-9]+: )?(synthesize|deliver to operator|respond to operator|conclude)\\b"; "i")) | not)
            ))] | length' "$hd_file" 2>/dev/null || echo 0)
        fi
        [ -z "$pending_tool_steps" ] && pending_tool_steps=0
        local last_role
        last_role=$(jq -r '.[-1].role // empty' "$messages_file" 2>/dev/null)
        if [ "$pending_tool_steps" -eq 0 ] && [ "$last_role" = "tool" ]; then
            local final_adv="[HONEYDEW PROGRESS: All inspection/action steps are marked [✓]. The final milestone is active: Synthesize your diagnostic observations and deliver the structured status report directly to the operator in clean markdown. Do NOT execute redundant tool calls.]"
            jq --arg a "$final_adv" '. += [{"role": "user", "content": $a}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
        fi

        # Credit-based flow control check
        if declare -f fifo_channel_is_open &>/dev/null && fifo_channel_is_open "$session_id"; then
            if declare -f fifo_flow_acquire &>/dev/null; then
                if ! fifo_flow_acquire "$session_id" 1; then
                    declare -f agent_sm_transition &>/dev/null && agent_sm_transition "$session_id" "FLOW_PAUSED" "Credit window exhausted"
                    ui_warn "Flow paused: awaiting credit grant for session $session_id..."
                    if ! fifo_flow_acquire "$session_id" 2; then
                        ui_dim "  [flow-control] Auto-granting 5 credits to advance execution"
                        declare -f fifo_flow_grant &>/dev/null && fifo_flow_grant "$session_id" 5
                        fifo_flow_acquire "$session_id" 1 || true
                    fi
                    declare -f agent_sm_transition &>/dev/null && agent_sm_transition "$session_id" "RUNNING" "Resumed with granted credits"
                fi
            fi
        fi

        # MQTT turn progress broadcast
        if declare -f task_sync_signal &>/dev/null; then
            task_sync_signal "$session_id" "turn" "$(jq -cn --arg id "$session_id" --argjson turn "$turn" --arg tool "${last_invoked_tool:-none}" '{session_id:$id, turn:$turn, last_tool:$tool}')" >/dev/null 2>&1 || true
        fi

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

        # Apply Milestone-Scoped Tool Masking
        local turn_tools_schema
        local turn_tool_choice="auto"
        turn_tools_schema=$(_react_scope_tools_for_step "$tools_schema" "$current_hd_step" "$pending_tool_steps")
        if [ "$turn_tools_schema" = "[]" ] || [ -z "$turn_tools_schema" ]; then
            turn_tools_schema="[]"
            turn_tool_choice="none"
            ui_dim "  [tool-mask] Step '$current_hd_step' -> Synthesis Mode (tool_choice=none)"
        else
            local mounted_names
            mounted_names=$(echo "$turn_tools_schema" | jq -r '[.[].function.name] | join(", ")' 2>/dev/null || echo "")
            ui_dim "  [tool-mask] Step '$current_hd_step' -> Mounted tools: [$mounted_names]"
            if [ "${consecutive_premature_plans:-0}" -gt 0 ]; then
                turn_tool_choice="required"
                ui_dim "  [tool-mask] Enforcing tool_choice=required due to premature planning ($consecutive_premature_plans)"
            fi
        fi

        local payload
        payload=$(jq -n \
            --slurpfile msgs "$messages_file" \
            --argjson tools "$turn_tools_schema" \
            --arg tool_choice "$turn_tool_choice" \
            --arg temp "$agent_temp" \
            --arg topp "$agent_topp" \
            --arg max_tok "$agent_max_tok" \
            --arg r_effort "$r_effort" \
            '{
                messages: $msgs[0],
                tools: (if ($tools | length) > 0 then $tools else null end),
                tool_choice: (if ($tools | length) > 0 then $tool_choice else "none" end),
                temperature: ($temp | tonumber),
                top_p: ($topp | tonumber),
                top_k: 20,
                min_p: 0.0,
                repeat_penalty: 1.0,
                frequency_penalty: 0.0,
                presence_penalty: 0.0,
                max_tokens: ($max_tok | tonumber),
                reasoning_effort: $r_effort,
                chat_template_kwargs: {preserve_thinking: true},
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

        # Fallback: if native tool_calls array is empty, inspect raw_content for embedded XML/JSON function calls
        if [ -z "$tool_calls" ] || [ "$tool_calls" = "null" ] || [ "$tool_calls" = "[]" ]; then
            if [[ "$raw_content" == *"<function"* ]] || [[ "$raw_content" == *"<tool_call"* ]]; then
                if command -v python3 &>/dev/null; then
                    local _extracted_tc
                    _extracted_tc=$(python3 -c '
import sys, re, json, os

text = sys.argv[1] if len(sys.argv) > 1 else sys.stdin.read()
calls = []
json_tc = re.findall(r"<tool_call[^>]*>\s*(\{.*?\})(?:\s*</tool_call>|$)", text, re.DOTALL)
for j_str in json_tc:
    try:
        d = json.loads(j_str)
        if "name" in d:
            args = d.get("arguments", {})
            if not isinstance(args, str):
                args = json.dumps(args)
            calls.append({
                "id": f"call_txt_{len(calls)+1}",
                "type": "function",
                "function": {"name": d["name"], "arguments": args}
            })
    except Exception:
        pass

pattern = re.compile(r"<function\s*=\s*([a-zA-Z0-9_-]+)\s*>(.*?)(?:</function>|$)", re.DOTALL)
for m in pattern.finditer(text):
    fn_name = m.group(1).strip()
    body = m.group(2)
    params = {}
    param_pattern = re.compile(r"<(?:parameter\s*(?:=\s*|\s+name\s*=\s*[\"'"'"']?)([a-zA-Z0-9_]+)[\"'"'"']?|([a-zA-Z0-9_]+))\s*>(.*?)(?:</(?:parameter|\1|\2)>|(?=<parameter)|(?=<[a-zA-Z0-9_]+>)|$)", re.DOTALL)
    for pm in param_pattern.finditer(body):
        k = pm.group(1) or pm.group(2)
        v = pm.group(3).strip()
        v = re.sub(r"</?[^>]+>", "", v).strip()
        if k and k not in ("function",):
            params[k] = v

    if fn_name == "computer_use" and "name" in params:
        fn_name = params.pop("name")
    elif fn_name == "computer_use" and "action" in params:
        fn_name = params.pop("action")

    calls.append({
        "id": f"call_txt_{len(calls)+1}",
        "type": "function",
        "function": {
            "name": fn_name,
            "arguments": json.dumps(params)
        }
    })
print(json.dumps(calls))
' "$raw_content" 2>/dev/null || echo "[]")
                    if [ -n "$_extracted_tc" ] && [ "$_extracted_tc" != "[]" ]; then
                        tool_calls="$_extracted_tc"
                        raw_content=""
                    fi
                fi
            fi
        fi

        # ── Branch 1: Native OpenAI Tool Calls Detected ──────────────
        if [ -n "$tool_calls" ] && [ "$tool_calls" != "null" ] && [ "$tool_calls" != "[]" ]; then
            # Sanitize and repair tool_calls arguments to ensure valid JSON and extract embedded XML parameters
            if command -v python3 &>/dev/null; then
                tool_calls=$(echo "$tool_calls" | python3 -c '
import sys, json, re, os

def sanitize_one(raw):
    if not raw or raw == "null":
        return "{}"
    extracted = {}
    parsed = False
    for suffix in ["", "\"\n}", "\"}", "}", "\n}"]:
        try:
            j = json.loads(raw + suffix, strict=False)
            if isinstance(j, dict):
                for k, v in j.items():
                    if isinstance(v, str):
                        clean_v = re.split(r"</?(?:parameter|function|tool_call|invoke|output)[^>]*>", v)[0].strip()
                        extracted[k] = clean_v
                    else:
                        extracted[k] = v
                parsed = True
                break
        except Exception:
            continue
    if not parsed:
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

    target_ws = os.environ.get("LODGE_DIR") or os.path.expanduser("~/blue-lodge")

    if "command" in extracted and isinstance(extracted["command"], str):
        c = extracted["command"]
        c = re.split(r"</?(?:parameter|function|tool_call|invoke|output)[^>]*>", c)[0].strip()
        c = re.sub(r"head -n(\s*(\||&|;|$))", r"head -n 10\1", c)
        c = re.sub(r"git rev-parse\s+([^\s]+)\s+--short", r"git rev-parse --short \1", c)
        c = re.sub(r"\bgit checkout -b\b", "git checkout -B", c)
        c = re.sub(r"(?:/home/[^/]+|/Users/[^/]+|~|\$HOME)/blue[ _-][a-zA-Z0-9_-]+", target_ws, c)
        extracted["command"] = c

    if "path" in extracted and isinstance(extracted["path"], str):
        p = extracted["path"].split("\n")[0].strip()
        p = re.split(r"(\s+2?>|\s+\||\s+;)", p)[0].strip()
        p = re.sub(r"^(?:/home/[^/]+|/Users/[^/]+|~|\$HOME|\.?/?home/[^/]+)/blue[ _-][a-zA-Z0-9_-]+", target_ws, p)
        if re.match(r"^home/[^/]+/", p):
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
                '{role: "assistant", content: (if $content == "" then null else $content end), tool_calls: $tc} + (if ($rc // "") != "" then {reasoning_content: $rc} else {} end)' 2>/dev/null)
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

                if [ "$c_name" = "$last_invoked_tool" ]; then
                    same_tool_streak=$((same_tool_streak + 1))
                else
                    same_tool_streak=1
                    last_invoked_tool="$c_name"
                fi

                if [ "$c_name" = "tool_search" ]; then
                    tool_search_streak=$((tool_search_streak + 1))
                else
                    tool_search_streak=0
                fi

                # Intercept tool_search thrashing early (Streak >= 2)
                if [ "$tool_search_streak" -ge 2 ]; then
                    ui_warn "⚡ Tool search thrashing detected (Streak: $tool_search_streak). Triggering Prompt Perturbation Hook."
                    _react_circuit_breaker_perturbation "$session_id" "$workdir" "TOOL_SEARCH_THRASHING" "tool_search ($c_args)" "Repeated tool_search invocations without forward progress" "$messages_file" "$macro_file"
                fi

                # ── Action Hashing & Repetition Detection ────────────
                local a_hash
                a_hash=$(_react_action_hash "$c_name" "$c_args")
                local rep_strike
                rep_strike=$(_react_check_repetition "$session_dir" "$a_hash" "$c_name" "$c_args")

                if [ "$rep_strike" -ge 3 ]; then
                    local heal_ec=0
                    _react_self_heal_circuit_breaker "$session_id" "$workdir" "$session_dir" "$c_name" "$c_args" "$messages_file" "$macro_file" "$rep_strike"
                    heal_ec=$?
                    if [ "$heal_ec" -ne 0 ]; then
                        export AGENT_ACTIVE_SESSION_ID=""
                        return "$heal_ec"
                    fi
                elif [ "$rep_strike" -eq 1 ]; then
                    local rep_adv="[CIRCUIT ADVISORY: Action '$c_name' was already executed. Repeating identical actions or oscillating cycles without parameter changes is strictly prohibited. Modify your parameters or select an alternative tool.]"
                    jq --arg a "$rep_adv" '. += [{"role": "user", "content": $a}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                elif [ "$rep_strike" -eq 2 ]; then
                    _react_circuit_breaker_perturbation "$session_id" "$workdir" "ACTION_REPETITION" "$c_name ($c_args)" "Action repetition strike 2" "$messages_file" "$macro_file"
                fi

                # ── Target Path & File Repetition Tracking ───────────
                local target_path=""
                if [[ "$c_name" =~ file_read|file_grep|file_outline|code_symbol_get|file_edit|file_write ]]; then
                    target_path=$(echo "$c_args" | jq -r '.path // empty' 2>/dev/null)
                fi

                if [ -n "$target_path" ]; then
                    if [ "$target_path" = "$last_inspected_path" ]; then
                        same_target_path_streak=$((same_target_path_streak + 1))
                    else
                        same_target_path_streak=1
                        last_inspected_path="$target_path"
                    fi

                    if [ "$same_target_path_streak" -ge 3 ]; then
                        ui_warn "⚡ Target path repetition ceiling reached on $target_path (Streak: $same_target_path_streak). Tripping circuit breaker / perturbation."
                        _react_circuit_breaker_perturbation "$session_id" "$workdir" "TARGET_FILE_THRASHING" "$c_name ($target_path)" "Repeated file inspection on $target_path without task advancement" "$messages_file" "$macro_file"
                    elif [ "$same_target_path_streak" -eq 2 ]; then
                        local path_adv="[CIRCUIT ADVISORY: Target file '$target_path' has been inspected multiple times in a row. Cease linear paging or repeated inspection of this file. Synthesize your findings or call the domain-specific tool required by the active Honeydew milestone.]"
                        jq --arg a "$path_adv" '. += [{"role": "user", "content": $a}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                    fi
                else
                    same_target_path_streak=0
                    last_inspected_path=""
                fi

                ui_step "Native Tool Call: $c_name"
                echo "Tool Call: $c_name ($c_args)" >> "$history_file"
                declare -f transcript_log &>/dev/null && transcript_log "tool_call" "$c_name: $c_args"

                if [ "${LODGE_DEBUG:-0}" -eq 1 ]; then
                    printf "   ${C_BOLD}${C_BLUE}[DEBUG: Tool Args]${C_RESET} %s\n" "$c_args"
                fi

                local tool_resp=""
                local from_cache=0
                local cache_key=""
                local cache_ns=""

                # ── Pseudo-LRU Cache Interception ────────────────────
                if _react_tool_is_cacheable "$c_name"; then
                    cache_ns=$(_react_tool_cache_ns "$c_name")
                    cache_key="tool:${c_name}:${a_hash}"
                    local cached_val=""
                    if declare -f cache_get &>/dev/null && cached_val=$(cache_get "$cache_key" "$cache_ns" 2>/dev/null); then
                        from_cache=1
                        ui_step "Native Tool Call: $c_name [LRU CACHE HIT (~0ms)]"
                        tool_resp=$(jq -nc \
                            --arg id "$c_id" \
                            --arg name "$c_name" \
                            --arg content "$cached_val" \
                            '{role: "tool", tool_call_id: $id, name: $name, content: ("[CACHED OBSERVATION (0ms)]\n" + $content)}')
                    fi
                fi

                if [ "$from_cache" -eq 0 ]; then
                    local as_timeout
                    as_timeout=$(declare -f limits_get &>/dev/null && limits_get ASYNC_TOOL_WATCHDOG_TIMEOUT 120 || echo 120)
                    if declare -f fifo_async &>/dev/null && declare -f fifo_await &>/dev/null; then
                        local prom_id
                        local b64_args
                        b64_args=$(printf '%s' "$c_args" | base64 -w 0)
                        prom_id=$(fifo_async "$session_id" "native_tools_dispatch '$c_id' '$c_name' \"\$(printf '%s' '$b64_args' | base64 -d)\" '$workdir'")
                        tool_resp=$(fifo_await "$prom_id" "$as_timeout" 2>/dev/null)
                        local await_ec=$?
                        if [ "$await_ec" -eq 124 ]; then
                            tool_resp=$(jq -nc \
                                --arg id "$c_id" \
                                --arg name "$c_name" \
                                --arg timeout "$as_timeout" \
                                '{role: "tool", tool_call_id: $id, name: $name, content: ("ERROR: Tool execution timed out after " + $timeout + "s")}')
                        elif [ "$await_ec" -ne 0 ] && [ -z "$tool_resp" ]; then
                            tool_resp=$(jq -nc \
                                --arg id "$c_id" \
                                --arg name "$c_name" \
                                --arg ec "$await_ec" \
                                '{role: "tool", tool_call_id: $id, name: $name, content: ("ERROR: Tool execution crashed or terminated prematurely (exit code: " + $ec + ")")}')
                        fi
                    else
                        tool_resp=$(native_tools_dispatch "$c_id" "$c_name" "$c_args" "$workdir")
                    fi
                fi

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
                fi

                # Archive raw observation to workspace
                mkdir -p "$session_dir/observations" 2>/dev/null || true
                printf '%s\n' "$resp_content" > "$session_dir/observations/call_${c_id}.txt" 2>/dev/null || true
                echo "Observation: $resp_content" >> "$history_file"
                declare -f transcript_log_block &>/dev/null && transcript_log_block "observation ($c_name)" "$resp_content"
                local is_cached_bool="false"
                [ "$from_cache" -eq 1 ] && is_cached_bool="true"
                _react_trace "$workdir" "tool_call" "$(jq -cn --arg tool "$c_name" --arg args "$c_args" --argjson cached "$is_cached_bool" '{tool:$tool, args:$args, cached:$cached}')"

                # Check for tool errors and track cognitive thrashing
                local is_tool_failure=0
                if echo "$resp_content" | grep -qE '(\bERROR\b|ERROR:|Command failed|pdftotext: not found|ModuleNotFoundError|ImportError|Traceback \(most recent call last\)|No such file or directory|failed \(exit [1-9]|SCRIPT_EXIT=[1-9]|SyntaxError:|syntax error|unexpected token|Unknown.*subcommand)'; then
                    is_tool_failure=1
                fi

                # ── Cache Store & Invalidation ───────────────────────
                if [ "$from_cache" -eq 0 ] && [ "$is_tool_failure" -eq 0 ] && _react_tool_is_cacheable "$c_name"; then
                    declare -f cache_put &>/dev/null && cache_put "$cache_key" "$cache_ns" "$resp_content"
                fi
                if _react_tool_is_mutating "$c_name" "$c_args"; then
                    declare -f cache_invalidate_ns &>/dev/null && cache_invalidate_ns "files"
                    declare -f cache_invalidate_ns &>/dev/null && cache_invalidate_ns "git"
                fi

                # ── MID-TURN GUIDED LOOP: SUB-TURN LLM DIGEST & SCRATCHPAD ──
                local tool_digest=""
                local eval_verdict="IN_PROGRESS"
                local eval_reason=""
                local eval_guidance=""

                if [ "$is_tool_failure" -eq 0 ]; then
                    tool_digest=$(_react_digest_tool_output "$c_id" "$c_name" "$c_args" "$resp_content" "$current_hd_step" "$session_dir" "$workdir" "$goal")

                    # ── MID-TURN GUIDED LOOP: MILESTONE EVALUATOR ───────────
                    local eval_out=""
                    eval_out=$(_react_eval_milestone_evidence "$workdir" "$session_dir" "$current_hd_id" "$current_hd_step" "$goal" "$tool_digest")
                    if [ -n "$eval_out" ]; then
                        eval_verdict="${eval_out%%|*}"
                        local _rem="${eval_out#*|}"
                        eval_reason="${_rem%%|*}"
                        eval_guidance="${_rem#*|}"
                    fi

                    # If Evaluator marked milestone SATISFIED, refresh active step ID and step task
                    if [ "$eval_verdict" = "SATISFIED" ]; then
                        if [ -f "$hd_file" ]; then
                            current_hd_id=$(jq -r '[.items[]? | select(.status != "done")][0].id // 1' "$hd_file" 2>/dev/null || echo 1)
                            current_hd_step=$(jq -r '[.items[]? | select(.status != "done")][0] | if . then "Step " + (.id|tostring) + ": " + .task else "Synthesize Final Deliverable" end' "$hd_file" 2>/dev/null)
                            export CURRENT_ACTIVE_MILESTONE_ID="$current_hd_id"
                        fi
                    fi

                    # Advance Honeydew multi-step milestone rule matching as well
                    _react_advance_honeydew_plan "$workdir" "$c_name" "$c_args"

                    # ── CURATED CONTEXT INJECTION (Preserve Code Fidelity & Prevent Bloat) ────
                    local curated_obs=""
                    # If this is a code inspection/file tool or bounded output (<=3500 chars), preserve raw code fidelity
                    if [[ "$c_name" =~ ^(file_read|file_edit|file_write|file_grep|file_diff|git_diff|dir_list|file_list|phytology_inspect)$ ]] || [ "${#resp_content}" -le 3500 ]; then
                        curated_obs="${resp_content}

[MILESTONE EVALUATION: ${eval_verdict}]
${eval_reason:+${eval_reason} }${eval_guidance:+(Directive: ${eval_guidance})}"
                    else
                        curated_obs="[OBSERVATION DIGEST: ${c_name}]
${tool_digest}

[MILESTONE EVALUATION: ${eval_verdict}]
${eval_reason:+${eval_reason} }${eval_guidance:+(Directive: ${eval_guidance})}
[Verified facts recorded in scratchpad.md and mem:active_task. Full observation archived in workspace.]"
                    fi

                    tool_resp=$(echo "$tool_resp" | jq --arg c "$curated_obs" '.content = $c')
                else
                    # Curated failure observation (preserve up to 1500 chars for compiler/interpreter diagnostics)
                    local fail_obs="[OBSERVATION ERROR: ${c_name}]
Error: ${resp_content:0:1500}
[STATUS: Tool execution failed. Check syntax and arguments before retrying.]"
                    tool_resp=$(echo "$tool_resp" | jq --arg c "$fail_obs" '.content = $c')
                fi

                # Append curated tool response to messages array
                jq --argjson tr "$tool_resp" '. += [$tr]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"

                # Transmit FIFO frame for turning step
                if declare -f fifo_write_frame &>/dev/null && [ -n "$session_id" ]; then
                    fifo_write_frame "$session_id" "$(jq -nc --arg tool "$c_name" --arg v "${eval_verdict:-FAILURE}" '{event: "tool_digest", tool: $tool, verdict: $v}')" 2 2>/dev/null || true
                fi

                if [ "$is_tool_failure" -eq 1 ]; then
                    thrashing_target_streak=$((thrashing_target_streak + 1))
                    if declare -f telemetry_record_anomaly &>/dev/null; then
                        telemetry_record_anomaly "$session_id" "CAPABILITY_DEFICIT" "$c_name" "Failure on $c_name (Strike $thrashing_target_streak): ${resp_content:0:200}" >/dev/null 2>&1 || true
                    fi

                    # Trigger intelligent prompt perturbation hook on consecutive failures
                    if [ "$thrashing_target_streak" -ge 2 ]; then
                        local fail_cls
                        fail_cls=$(_react_classify_circuit_state "$c_name" "$c_args" "$resp_content" "$tool_search_streak" "$thrashing_target_streak" 0)
                        _react_circuit_breaker_perturbation "$session_id" "$workdir" "$fail_cls" "$c_name ($c_args)" "${resp_content:0:300}" "$messages_file" "$macro_file"
                    fi

                    if [ "$thrashing_target_streak" -ge 4 ]; then
                        ui_err "Hard capability ceiling reached: 4 consecutive unyielding tool failures ($c_name). Tripping breaker and preserving incident."
                        _react_trip_circuit_breaker "$session_id" "$workdir" "Persistent tool failure on $c_name reached strike ceiling" "$c_name ($c_args)" "$messages_file" "$macro_file" "${resp_content:0:500}"
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

                # Brief UI preview and optional debug observation
                local preview
                preview=$(echo "${tool_digest:-$resp_content}" | head -n 3 | tr '\n' ' ')
                printf "${C_DIM}  ↳ Digest: %s${C_RESET}\n" "$preview"
                if [ "${LODGE_DEBUG:-0}" -eq 1 ]; then
                    printf "   ${C_BOLD}${C_GRAY}[DEBUG: Observation (${#resp_content} chars)]${C_RESET}\n%s\n" "${resp_content:0:1500}"
                fi


                declare -f transcript_log_jsonl &>/dev/null && transcript_log_jsonl "$goal" "${reasoning:-${think_content:-}}" "${c_name:-tool}(${c_args:-})" "$resp_content"
            done < <(echo "$tool_calls" | jq -c '.[]')

            if [ "$tool_exhausted" -eq 1 ]; then
                return 1
            fi

            consecutive_empty_turns=0
            consecutive_premature_plans=0
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
            local fb_hash
            fb_hash=$(_react_action_hash "fallback_cmd" "$action")
            local fb_strike
            fb_strike=$(_react_check_repetition "$session_dir" "$fb_hash" "fallback_cmd" "$action")

            if [ "$fb_strike" -ge 3 ]; then
                local fb_heal_ec=0
                _react_self_heal_circuit_breaker "$session_id" "$workdir" "$session_dir" "fallback_cmd" "$action" "$messages_file" "$macro_file" "$fb_strike"
                fb_heal_ec=$?
                if [ "$fb_heal_ec" -ne 0 ]; then
                    export AGENT_ACTIVE_SESSION_ID=""
                    return "$fb_heal_ec"
                fi
            elif [ "$fb_strike" -eq 1 ]; then
                local fb_adv="[CIRCUIT ADVISORY: Fallback command '$action' was already executed. Repeating identical commands without parameter changes is strictly prohibited. Modify your parameters or proceed to other actions.]"
                jq --arg a "$fb_adv" '. += [{"role": "user", "content": $a}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
            elif [ "$fb_strike" -eq 2 ]; then
                _react_circuit_breaker_perturbation "$session_id" "$workdir" "ACTION_REPETITION" "$action" "Fallback repetition strike 2" "$messages_file" "$macro_file"
            fi

            ui_step "Executing fallback command: $action"
            echo "Action: $action" >> "$history_file"
            declare -f transcript_log &>/dev/null && transcript_log "command" "$action"

            local obs
            obs=$(commands_dispatch "$action" "$workdir" 2>&1)
            local exit_code=$?

            if echo "$action" | grep -qE '\b(edit|write|patch|commit|push|git|rm|mv|touch|sed)'; then
                declare -f cache_invalidate_ns &>/dev/null && cache_invalidate_ns "files"
                declare -f cache_invalidate_ns &>/dev/null && cache_invalidate_ns "git"
            fi

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
            # Guard against pseudo tool calls masquerading as final responses
            if [[ "$raw_content" =~ \<tool_call|\<function ]]; then
                ui_warn "  [guard] Intercepted raw tool call text in conversational output; enforcing tool execution."
                jq --arg ans "$raw_content" '. += [{"role": "assistant", "content": $ans}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                local adv="[SYSTEM ADVISORY: You outputted an unexecuted tool call text. Execute the tool properly or synthesize your final deliverable from the scratchpad without tool tags.]"
                jq --arg p "$adv" '. += [{"role": "user", "content": $p}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                turn=$((turn + 1))
                continue
            fi

            # Premature Exit Guard: In multi-turn tasks where output
            # contains forward-looking planning text or preambles rather than a final deliverable, advance to tool execution.
            # CRITICAL: If tools have ALREADY executed in this session, the assistant is reporting results, NOT planning.
            local is_premature_plan=0
            local has_prior_tool_execution=0
            if [ -f "$history_file" ] && grep -qE "(Tool Call:|Action:)" "$history_file"; then
                has_prior_tool_execution=1
            fi

            if [ "$max_turns" -gt 1 ] && [ "$has_prior_tool_execution" -eq 0 ]; then
                local trimmed_tail="${raw_content%"${raw_content##*[![:space:]]}"}"
                if [ "${AGENT_SOVEREIGN_REMEDIATION:-0}" -eq 1 ] && [ "$turn" -lt 5 ]; then
                    is_premature_plan=1
                elif echo "$raw_content" | grep -qiE "(I will|I'll|I plan to|Let's outline|Step 1|First step|I need to check|I need to inspect|Let's begin by|Before making changes|I will pull|I'll pull|Let me fetch|I am going to|I'm going to|I will search|I'll search|Let me pull|I'll gather|I will gather|I'll start by|I will start by|Let me survey|Let me inspect|Let me explore|Let me examine|I will examine|I'll look at|ground this in|survey what is|Let me now|Let me proceed|I will now|Next step|Proceeding to|I will execute|Let me execute)"; then
                    is_premature_plan=1
                elif [[ "$trimmed_tail" == *: ]]; then
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
                # Exclude operational status, inspection, check, and phytology tasks from external research requirements
                if ! echo "${goal,,}" | grep -qiE '\b(status|inspect|check|phytology|audit|health)\b'; then
                    if echo "${goal,,}" | grep -qiE '\b(research|dossier|background on|investigate|due diligence|osint|deep dive|fact check)\b'; then
                        is_research_task=1
                    elif [[ "${tool_filter:-}" =~ research ]] && echo "${goal,,}" | grep -qiE '\b(research|dossier|background|investigate|due diligence|osint|latest|recent|news|current)\b'; then
                        is_research_task=1
                    fi
                fi
                if [ "$is_research_task" -eq 1 ]; then
                    if [ ! -f "$history_file" ] || ! grep -qE "(Tool Call: web_|Tool Call: fetch|Tool Call: pdf_read|Tool Call: file_read|Tool Call: github_search|Tool Call: phytology_manage|Action: .*web|Action: .*curl|Action: .*search)" "$history_file"; then
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
                if echo "${goal,,}" | grep -qiE '\b(extend|implement|develop|fix|refactor|test|patch|code|write|create|build|modify|feature|graft|remediat|branch|pr|pull request|commit)\b'; then
                    is_code_task=1
                fi
                # Exclude pure inspection, health verification, audit, or status queries from forced mutation
                if echo "${goal,,}" | grep -qiE '\b(inspect|status|verify|check|audit|report on|overview of)\b' && ! echo "${goal,,}" | grep -qiE '\b(implement|create|extend|build|fix|write|modify|refactor|patch|branch)\b'; then
                    is_code_task=0
                fi
                if [ "$is_code_task" -eq 1 ]; then
                    if [ ! -f "$history_file" ] || ! grep -qE "(Tool Call: file_write|Tool Call: file_edit|Tool Call: symbol_patch|Tool Call: git_commit|Tool Call: git_push|Tool Call: gitea_pr|Tool Call: gitea_issue_close|Tool Call: phytology_manage|Tool Call: slash_command_exec|Tool Call: bash_exec|Action: .*phytology|Action: .*commit|Action: .*push|git checkout -b|git commit|git branch feature)" "$history_file"; then
                        is_unverified_code=1
                    fi
                fi
            fi

            if [ "$is_premature_plan" -eq 1 ]; then
                consecutive_premature_plans=$((consecutive_premature_plans + 1))
                if [ "$consecutive_premature_plans" -ge 5 ]; then
                    ui_err "  [guard] Circuit breaker: 5 consecutive turns produced planning monologues without tool execution. Halting runaway loop."
                    _react_trace "$workdir" "circuit_breaker_premature_loop" '{"turns": '"$turn"', "consecutive_premature": '"$consecutive_premature_plans"'}'
                    break
                fi
                if [ "$consecutive_premature_plans" -ge 3 ]; then
                    ui_warn "  [guard] Premature planning loop detected ($consecutive_premature_plans turns). Pruning advisory history and enforcing immediate tool execution."
                    python3 -c '
import sys, json
path = sys.argv[1]
try:
    with open(path, "r") as f:
        msgs = json.load(f)
    cleaned = [m for m in msgs if not (isinstance(m.get("content"), str) and "[SYSTEM ADVISORY:" in m["content"])]
    with open(path, "w") as f:
        json.dump(cleaned, f)
except Exception:
    pass
' "$messages_file" 2>/dev/null || true
                fi
                jq --arg ans "$raw_content" '. += [{"role": "assistant", "content": $ans}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                local adv
                if [ "$consecutive_premature_plans" -ge 2 ]; then
                    adv="[SYSTEM ADVISORY: Execute your tool call now. Invoke bash_exec, file_write, or research_sandbox directly. Do not output text preambles or planning sentences.]"
                else
                    adv="[SYSTEM ADVISORY: Plan acknowledged. Proceed immediately to execute your plan by calling the required native tools (e.g. bash_exec, file_write, file_read, research_sandbox). Emit conversational markdown ONLY when all tool actions are complete and the deliverable is 100% finished.]"
                fi
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
                # Honeydew synchronization: ensure action tools remain mounted so worker can execute
                local hd_f="$workdir/.george/honeydew.json"
                if [ -f "$hd_f" ]; then
                    local last_act_id
                    last_act_id=$(jq -r '[.items[]? | select(.task | test("synthesize|deliver|report|respond"; "i") | not)][-1].id // empty' "$hd_f" 2>/dev/null)
                    if [ -n "$last_act_id" ]; then
                        jq --argjson aid "$last_act_id" '(.items[] | select(.id == $aid)).status = "pending"' "$hd_f" > "${hd_f}.tmp" 2>/dev/null && mv "${hd_f}.tmp" "$hd_f"
                    fi
                fi
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
            declare -f agent_sm_transition &>/dev/null && agent_sm_transition "$session_id" "DONE" "Task completed successfully" 2>/dev/null || true
            declare -f fifo_channel_close &>/dev/null && fifo_channel_close "$session_id" 2>/dev/null || true
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
                '{role: "assistant", content: null} + (if ($rc // "") != "" then {reasoning_content: $rc} else {} end)')
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
    declare -f agent_sm_transition &>/dev/null && agent_sm_transition "$session_id" "HALTED" "Turn ceiling reached" 2>/dev/null || true
    declare -f fifo_channel_close &>/dev/null && fifo_channel_close "$session_id" 2>/dev/null || true
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
