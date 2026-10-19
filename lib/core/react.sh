#!/bin/bash
# ── George: Modern POSIX ReAct Engine (2026) ─────────────────────────
[ -n "${_LIB_REACT_LOADED:-}" ] && return 0; _LIB_REACT_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"

source "$LODGE_DIR/lib/ui/ui.sh"
source "$LODGE_DIR/lib/core/endpoints.sh"
source "$LODGE_DIR/lib/ui/commands.sh"
source "$LODGE_DIR/lib/memory/memory.sh"
source "$LODGE_DIR/lib/memory/journal.sh"
source "$LODGE_DIR/lib/agents/subagents.sh"
source "$LODGE_DIR/lib/tools/native_tools.sh"
source "$LODGE_DIR/lib/core/context_engine.sh"

source "$LODGE_DIR/lib/memory/transcript.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agents/telemetry.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/limits.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/sys/cache.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/fifo_ipc.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/task_sync.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/agent_sm.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/mqtt.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/run_ledger.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/react_envelope.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/react_evaluator.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/react_advisor.sh" 2>/dev/null || true

# ── Steering messages ────────────────────────────────────────────────
# Inside the tool-execution loop an assistant tool_calls message must be
# followed directly by its tool results; steering text injected there broke
# message ordering. While _REACT_IN_TOOL_LOOP=1 messages are queued and
# flushed as one user message after the tool results (_react_steer_flush).
_react_steer() {
    local text="$1" mf="${2:-${messages_file:-}}"
    [ -z "$text" ] || [ -z "$mf" ] && return 0
    if [ "${_REACT_IN_TOOL_LOOP:-0}" -eq 1 ] && [ -n "${session_dir:-}" ]; then
        printf '%s\n\n' "$text" >> "$session_dir/.pending_steer" 2>/dev/null && return 0
    fi
    jq --arg a "$text" '. += [{"role": "user", "content": $a}]' "$mf" > "${mf}.tmp" 2>/dev/null && mv "${mf}.tmp" "$mf"
}
_react_steer_flush() {
    local mf="${1:-${messages_file:-}}" f="${session_dir:-}/.pending_steer"
    [ -s "$f" ] || return 0
    local txt; txt=$(cat "$f"); rm -f "$f"
    jq --arg a "${txt%$'\n\n'}" '. += [{"role": "user", "content": $a}]' "$mf" > "${mf}.tmp" 2>/dev/null && mv "${mf}.tmp" "$mf"
}

# ── Deliverable carry-forward ────────────────────────────────────────
# A substantive answer written mid-run (e.g. a report the guard intercepted
# because plan steps were still pending) used to be lost: the final turn said
# "the dossier is already above" and only that line reached the user.
#   _react_note_draft     keep the longest such draft in $session_dir/best_draft.txt
#   _react_post_draft     in a Discord run, post a long draft to the channel right away
#   _react_carry_forward  if the final answer only points back at the draft, prepend it
REACT_DRAFT_MIN_CHARS="${REACT_DRAFT_MIN_CHARS:-400}"
REACT_DRAFT_POST_MIN_CHARS="${REACT_DRAFT_POST_MIN_CHARS:-1200}"
_react_note_draft() {
    local sd="$1" text="$2"
    [ -n "$sd" ] && [ -d "$sd" ] || return 0
    local len=${#text} cur=0
    [ "$len" -ge "$REACT_DRAFT_MIN_CHARS" ] || return 0
    # Sanity guard: do not record scratchpad thinking or raw code diffs as user deliverable
    if [[ "$text" == *"</think>"* ]] || [[ "$text" == *"<think>"* ]] || [[ "$text" == *"<<<<<<< SEARCH"* ]]; then
        return 0
    fi
    [ -f "$sd/best_draft.txt" ] && cur=$(wc -c < "$sd/best_draft.txt" 2>/dev/null || echo 0)
    [ "$len" -ge "$cur" ] || return 0
    printf '%s\n' "$text" > "$sd/best_draft.txt" 2>/dev/null
    rm -f "$sd/best_draft.posted" 2>/dev/null
    return 0
}
# _react_post_draft <session_dir> <text> → 0 if posted to the current Discord conversation
_react_post_draft() {
    local sd="$1" text="$2"
    [ "${_DISCORD_IN_SESSION:-0}" = "1" ] && [[ "${_DISCORD_CURRENT_CHANNEL:-}" =~ ^[0-9]{5,25}$ ]] || return 1
    [ "${REACT_DISCORD_AUTOPOST:-1}" = "1" ] || return 1
    if [ ${#text} -lt "$REACT_DRAFT_POST_MIN_CHARS" ] && ! [[ "$text" =~ [Pp]-[0-9A-Fa-f]{6} ]]; then
        return 1
    fi
    declare -f discord_send &>/dev/null || return 1
    local msg="$text"
    declare -f discord_sanitize_egress &>/dev/null && \
        msg=$(discord_sanitize_egress "$text" "${_DISCORD_CURRENT_AUTHOR_ID:-}" "${_DISCORD_CURRENT_AUTHOR:-}")
    if discord_send "$_DISCORD_CURRENT_CHANNEL" "$msg" >/dev/null 2>&1; then
        if [ -n "$sd" ]; then
            touch "$sd/best_draft.posted" 2>/dev/null
            touch "$sd/.draft_posted_to_channel" 2>/dev/null
        fi
        return 0
    fi
    return 1
}
# _react_carry_forward <session_dir> <final_text> → prints the reply to deliver
_react_carry_forward() {
    local sd="$1" final="$2" draft="$1/best_draft.txt"
    if [ -n "$sd" ] && [ -s "$draft" ] && [ ! -f "$sd/best_draft.posted" ] && [ ! -f "$sd/.draft_posted_to_channel" ]; then
        local dl fl
        dl=$(wc -c < "$draft" 2>/dev/null || echo 0); fl=${#final}
        if [ "$fl" -lt $(( dl * 40 / 100 )) ]; then
            if printf '%s' "$final" | grep -qiE '(above|already (been )?(posted|shared|provided|delivered|presented|written|laid out|on the table)|as (shown|outlined|detailed|noted|presented|described) (above|earlier|previously)|(see|in) (the|my) (report|dossier|summary|answer|analysis|response) (above|earlier)|previous (message|turn|response)|on the table|report.s (is|are|s|up )?(already )?(in|on) the channel|(is|are) (up )?in the channel|on the shelf)' \
               || { [ "$fl" -lt 350 ] && [ "$dl" -ge "$REACT_DRAFT_POST_MIN_CHARS" ]; }; then  # incident 2026-10-05: fragment was 251 chars
                printf '%s\n\n%s\n' "$(cat "$draft")" "$final"
                return 0
            fi
        fi
    fi
    printf '%s\n' "$final"
}

# ── Structured Telemetry & Routing Trace ──────────────────────────────
_react_trace() {
    local w="${1:-.}"; local ev="${2:-}"; local p="${3:-}"; local gd="${w}/.george"
    mkdir -p "$gd" 2>/dev/null || true
    printf '{"timestamp":"%s","event":"%s","data":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)" "$ev" "${p:-"{}"}" >> "$gd/routing_trace.jsonl" 2>/dev/null || true
}

# ── Action Normalization & Canonical Hash ────────────────────────────
_react_action_hash() {
    local n="$1" a="${2:-}" na="{}"
    if [ -n "$a" ] && [ "$a" != "{}" ]; then
        if echo "$a" | jq -e 'type == "object" or type == "array"' >/dev/null 2>&1; then
            na=$(echo "$a" | jq -S -c . 2>/dev/null || echo "$a" | tr -d '[:space:]')
        else
            na=$(echo "$a" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr -s ' ')
        fi
    fi
    printf '%s:%s' "$n" "$na" | md5sum 2>/dev/null | cut -d' ' -f1 || printf '%s:%s' "$n" "$na" | cksum | cut -d' ' -f1
}

# ── Repetition & Loop Thrashing Detection ────────────────────────────
_react_check_repetition() {
    local session_dir="$1" a_hash="$2" c_name="${3:-}" c_args="${4:-}"
    local hash_file="$session_dir/action_hashes.log"
    local repeat_window=$(declare -f limits_get &>/dev/null && limits_get CIRCUIT_BREAKER_REPEAT_WINDOW 10 || echo "${CIRCUIT_BREAKER_REPEAT_WINDOW:-10}")
    local max_repeats=$(declare -f limits_get &>/dev/null && limits_get CIRCUIT_BREAKER_MAX_REPEATS 7 || echo "${CIRCUIT_BREAKER_MAX_REPEATS:-7}")
    local prev_hashes=()
    [ -f "$hash_file" ] && mapfile -t prev_hashes < "$hash_file"

    local prev_count=${#prev_hashes[@]} strike=0
    [ "$prev_count" -ge 1 ] && [ "$a_hash" = "${prev_hashes[$((prev_count - 1))]}" ] && strike=1
    if [ "$prev_count" -ge 3 ]; then
        [ "$a_hash" != "${prev_hashes[$((prev_count - 1))]}" ] && [ "$a_hash" = "${prev_hashes[$((prev_count - 2))]}" ] && [ "${prev_hashes[$((prev_count - 1))]}" = "${prev_hashes[$((prev_count - 3))]}" ] && strike=2
    fi

    local window_start=$(( prev_count - repeat_window )) occurrences=0 i
    [ "$window_start" -lt 0 ] && window_start=0
    for (( i=window_start; i<prev_count; i++ )); do
        [ "${prev_hashes[$i]}" = "$a_hash" ] && occurrences=$((occurrences + 1))
    done

    local strike_ceiling=$(( max_repeats - 1 ))
    [ "$strike_ceiling" -lt 3 ] && strike_ceiling=3
    local strike_pert=$(( max_repeats - 2 ))
    [ "$strike_pert" -lt 2 ] && strike_pert=2
    local strike_adv=$(( (max_repeats + 1) / 2 ))
    [ "$strike_adv" -lt 1 ] && strike_adv=1

    if [ "$occurrences" -ge "$strike_ceiling" ]; then strike=3
    elif [ "$occurrences" -ge "$strike_pert" ] && [ "$strike" -lt 2 ]; then strike=2
    elif [ "$occurrences" -ge "$strike_adv" ] && [ "$strike" -lt 1 ]; then strike=1
    fi

    echo "$a_hash" >> "$hash_file"
    echo "$strike"
}

# ── Pseudo-LRU Cache Interception Helpers ───────────────────────────
_react_tool_is_cacheable() {
    local name="$1" args="${2:-}"
    case "$name" in
        web_search|web_fetch|pdf_read|file_read|code_symbol_get|code_outline|recall) return 0 ;;
        phytology_manage)
            local act=$(echo "$args" | jq -r '.action // empty' 2>/dev/null)
            [[ "$act" =~ ^(status|audit|cache-status)$ ]] && return 0
            return 1 ;;
        *) return 1 ;;
    esac
}

_react_tool_cache_ns() {
    case "$1" in
        web_search|web_fetch|pdf_read) echo "web" ;;
        file_read|code_symbol_get|code_outline) echo "files" ;;
        recall) echo "recall" ;;
        phytology_manage) echo "phytology" ;;
        *) echo "default" ;;
    esac
}

_react_tool_cache_key() {
    local name="$1" args="${2:-}"
    local h
    h=$(echo -n "$args" | sha256sum 2>/dev/null | cut -d' ' -f1 || echo "$args")
    echo "tool:${name}:${h:0:16}"
}

_react_tool_is_mutating() {
    local name="$1" args="${2:-}"
    case "$name" in
        file_write|file_edit|symbol_patch|git_commit|git_push|git_checkout|gitea_pr|gitea_issue_close) return 0 ;;
        crypto_plan|crypto_execute|crypto_standing_order|operator_ask|operator_notify|discord_send|discord_send_file|discord_dm|crypto_place_limit|crypto_reclaim_order|crypto_send_ada|crypto_swap) return 0 ;;
        milestone_complete|task_complete|end_turn|vision_analyze) return 0 ;;
        phytology_manage)
            local act=$(echo "$args" | jq -r '.action // empty' 2>/dev/null)
            [[ "$act" =~ ^(heal|rollback|prune|lignify|cache-invalidate)$ ]] && return 0
            return 1 ;;
        bash_exec)
            local cmd=$(echo "$args" | jq -r '.command // empty' 2>/dev/null || echo "$args")
            echo "$cmd" | grep -qE '(\bgit\s+(commit|checkout|merge|rebase|push|branch)\b|\bsed\s+-i\b|\b(rm|mv|cp|touch|tee|chmod|chown|mkdir)\s+|\bcat\s+>|\b(discord_send|discord_dm|discord_send_file|operator_ask|operator_notify)\b|social\.sh\s+(post|reply|dm|send)|\bcurl\b.*(-X\s*(POST|PUT|PATCH|DELETE)|--request|--data|-d\s|-F\s))' && return 0
            return 1 ;;
        *) return 1 ;;
    esac
}

# ── Circuit Breaker Classification Engine ────────────────────────────
_react_classify_circuit_state() {
    local c_name="$1" c_args="${2:-}" err_text="${3:-}" search_streak="${4:-0}" fail_streak="${5:-0}" rep_strike="${6:-0}"
    if [[ "$err_text" =~ (restricted\ by\ system\ policy|Reputation\ Score|reputation\ level\ restricts|REPUTATION_CAPABILITY_DEFICIT) ]] || [ "$c_name" = "REPUTATION_CAPABILITY_DEFICIT" ]; then echo "REPUTATION_CAPABILITY_DEFICIT"
    elif [ "$c_name" = "TOOL_SEARCH_THRASHING" ] || [ "$c_name" = "tool_search" -a "$search_streak" -ge 2 ]; then echo "TOOL_SEARCH_THRASHING"
    elif [ "$c_name" = "TARGET_FILE_THRASHING" ] || [[ "$err_text" =~ Repeated\ file\ inspection|Target\ file ]]; then echo "TARGET_FILE_THRASHING"
    elif [ "$c_name" = "phytology_manage" ] || [[ "$c_args" =~ phyto ]] || [[ "$err_text" =~ /phytology\ failed|subcommand ]]; then echo "PHYTOLOGY_ERROR"
    elif [[ "$err_text" =~ syntax\ error|unexpected\ token|command\ not\ found ]] || [ "$c_name" = "bash_exec" -a "$fail_streak" -ge 1 ]; then echo "SHELL_SYNTAX_ERROR"
    elif [ "$fail_streak" -ge 2 ]; then echo "CONSECUTIVE_TOOL_FAILURES"
    elif [ "$rep_strike" -ge 2 ]; then echo "ACTION_REPETITION"
    else echo "GENERAL_LOOP_THRASHING"
    fi
}

# ── Circuit Breaker Intelligent Prompt Perturbation Hook ─────────────
_react_circuit_breaker_perturbation() {
    local session_id="$1" workdir="$2" breaker_class="$3" action_summary="$4" last_error="$5" messages_file="$6" macro_file="${7:-}"
    local primary_obj="Resolve the active engineering task in $workdir"
    [ -n "$macro_file" ] && [ -f "$macro_file" ] && primary_obj=$(jq -r '.primary_objective // empty' "$macro_file" 2>/dev/null || echo "$primary_obj")
    local perturbation="" source_tier=""

    local _adv_tools=""
    _adv_tools=$(jq -r '[.[].function.name] | join(",")' <<<"${turn_tools_schema:-${tools_schema:-[]}}" 2>/dev/null)
    local has_bash=0
    [[ ",${_adv_tools:-}," =~ ,bash_exec, ]] && has_bash=1

    # P2.6: grammar-constrained advisor (budgeted: 1/step, 3/run, 45 s)
    if declare -f react_advise &>/dev/null && [ -n "${session_dir:-}" ]; then
        local _adv_json=""
        ui_step "Consulting advisor for $breaker_class..."
        if _adv_json=$(react_advise "$session_dir" "${current_hd_id:-1}" "${current_hd_step:-$primary_obj}" "${goal:-$primary_obj}" "$breaker_class: $action_summary — ${last_error:0:200}" "$_adv_tools"); then
            perturbation=$(react_advise_render "$_adv_json"); source_tier="Advisor"
            _rl_advisor_json="$_adv_json"
        fi
    fi

    if [ -z "$perturbation" ]; then
        source_tier="Static Classification Catalog"
        case "$breaker_class" in
            REPUTATION_CAPABILITY_DEFICIT)
                local _auth_name="${DISCORD_CURRENT_AUTHOR_NAME:-user}"
                local _auth_rep="${DISCORD_CURRENT_AUTHOR_REP:-unknown}"
                local _min_rep="${DISCORD_OPS_MIN_REPUTATION:-50}"
                perturbation="[SYSTEM PERTURBATION: REPUTATION CAPABILITY RESTRICTION. The current user (@${_auth_name}) has Reputation Score ${_auth_rep} (level ${_auth_rep}), which is below the threshold (${_min_rep}) required to execute operational tools ($action_summary).
DO NOT attempt shell execution, script creation, file modifications, or operational commands.
Instead, communicate directly to @${_auth_name} explaining that their reputation level restricts access to these operational features. You may use ask_operator to send a message back to Discord or synthesize a clear conversational response summarizing what information you can provide and how they can build reputation.]"
                ;;
            TOOL_SEARCH_THRASHING)
                if echo "${goal:-}" | grep -qiE 'crypto|wallet|cardano|ada|polymarket|arbitrage|swap|dex|trade|loan|plan|order|snek|night|iag|wmtx|djed|usdm'; then
                    perturbation="[SYSTEM PERTURBATION: Loop thrashing detected on tool_search. Cease searching. Use the policy-gated sovereign trading tools directly: crypto_review (state), crypto_scan (pools & signals), crypto_plan (propose plan), crypto_execute (execute approved plan), crypto_standing_order, crypto_journal, wallet_status, wallet_balances, operator_ask, operator_notify. Do NOT call tool_search again.]"
                elif [ "$has_bash" -eq 1 ] || [ -z "$_adv_tools" ]; then
                    perturbation="[SYSTEM PERTURBATION: Loop thrashing detected on tool_search. Cease searching. All core tools are already loaded and mounted in your bedrock catalog: phytology_manage, bash_exec, slash_command_exec, file_read, dir_list, file_grep. Call your mounted tools directly. Do NOT call tool_search again.]"
                else
                    perturbation="[SYSTEM PERTURBATION: Loop thrashing detected on tool_search. Cease searching. Use your available tools directly (file_read, dir_list, file_grep, web_search, ask_operator, milestone_complete). Do NOT call tool_search again.]"
                fi
                ;;
            PHYTOLOGY_ERROR) perturbation="[SYSTEM PERTURBATION: Phytology invocation error. Valid subcommands for phytology_manage are: 'status', 'audit', 'heal', 'rollback', 'prune', 'fitness', 'lignify', 'test'. Pass the action as a simple string parameter (e.g. action="status" or action="audit", flags="--cached"). Do NOT wrap arguments in raw JSON strings.]" ;;
            SHELL_SYNTAX_ERROR) perturbation="[SYSTEM PERTURBATION: Shell syntax error or script failure in bash_exec ($last_error). When running Python via bash_exec: NEVER use double-quoted python3 -c \"...\"; ALWAYS use single-quoted heredocs (python3 - <<'EOF' ... EOF) or write scripts with file_write. NEVER call json.load/json.loads without try...except Exception as e. Or use native arxiv_search, hn_search, searxng_science_search, or web_search directly.]" ;;
            ACTION_REPETITION) perturbation="[SYSTEM PERTURBATION: Action repetition ceiling breached ($action_summary). Repeating this action is strictly prohibited. You MUST switch tools or significantly modify parameters immediately to proceed.]" ;;
            CONSECUTIVE_TOOL_FAILURES)
                if [ "$has_bash" -eq 1 ]; then
                    perturbation="[SYSTEM PERTURBATION: Multiple consecutive tool actions failed ($last_error). Step back from this failing approach. Inspect the workspace directly using file_read on lib/agents/phytology.sh or dir_list to verify active files.]"
                else
                    perturbation="[SYSTEM PERTURBATION: Multiple consecutive tool actions failed ($last_error). Step back from this failing approach. Use your available read tools (file_read, dir_list) or synthesize your response directly with ask_operator or your final answer. Do NOT attempt shell execution.]"
                fi
                ;;
            TOOL_THRASHING)
                if [ "$has_bash" -eq 1 ]; then
                    perturbation="[SYSTEM PERTURBATION: Loop thrashing detected on $action_summary. Cease invoking this tool repeatedly. Synthesize existing evidence, use bash_exec to inspect local files or run commands directly, or call milestone_complete to advance the plan.]"
                else
                    perturbation="[SYSTEM PERTURBATION: Loop thrashing detected on $action_summary. Cease invoking this tool repeatedly. Synthesize existing evidence using your available read tools (file_read, dir_list, file_grep), communicate findings via ask_operator or your final response, and call milestone_complete to advance the plan. Do NOT attempt shell execution.]"
                fi
                ;;
            *)
                if [ "$has_bash" -eq 1 ]; then
                    perturbation="[SYSTEM PERTURBATION: Execution loop interlock tripped ($breaker_class: $action_summary). Halt current cycle and switch to a direct inspection tool (file_read, dir_list, or phytology_manage). Do not repeat the failed action.]"
                else
                    perturbation="[SYSTEM PERTURBATION: Execution loop interlock tripped ($breaker_class: $action_summary). Halt current cycle and switch to an available tool (file_read, dir_list, ask_operator). Do not repeat the failed action.]"
                fi
                ;;
        esac
    fi

    # Update active task milestone in honeydew.json for REPUTATION_CAPABILITY_DEFICIT
    if [ "$breaker_class" = "REPUTATION_CAPABILITY_DEFICIT" ]; then
        local hd_file="${session_dir:-${AGENT_TASK_WORKSPACE:-}}/honeydew.json"
        [ ! -f "$hd_file" ] && hd_file="$workdir/.george/honeydew.json"
        if [ -f "$hd_file" ]; then
            local _auth_name="${DISCORD_CURRENT_AUTHOR_NAME:-user}"
            local _auth_rep="${DISCORD_CURRENT_AUTHOR_REP:-unknown}"
            local _pending_id
            _pending_id=$(jq -r '[.items[]? | select(.status != "done")][0].id // empty' "$hd_file" 2>/dev/null)
            if [ -n "$_pending_id" ]; then
                jq --argjson pid "$_pending_id" \
                   --arg auth "$_auth_name" \
                   --arg rep "$_auth_rep" '
                    .task_type = "chat" |
                    .items = [.items[] | 
                        if .id == $pid then
                            .task = "Communicate to @" + $auth + " that reputation score (" + $rep + ") restricts operational tool access, and summarize available information" |
                            .task_type = "chat" |
                            .endpoint_tier = 1
                        elif .id > $pid and (.task | test("create|build|write|implement|run|test|execute|deploy|patch|daemon"; "i")) then
                            .status = "done" |
                            .skipped = true |
                            .reason = "reputation_restriction"
                        else
                            .
                        end
                    ]
                ' "$hd_file" > "${hd_file}.tmp" 2>/dev/null && mv "${hd_file}.tmp" "$hd_file" 2>/dev/null || true
                ui_ok "[CIRCUIT BREAKER] Rewrote Honeydew milestone $_pending_id to communicate reputation restriction to user."
            fi
        fi
    fi

    ui_warn "[PERTURBATION] Prompt Perturbation Injected via $source_tier: ${perturbation:0:120}..."
    if [ -n "$messages_file" ] && [ -f "$messages_file" ]; then
        _react_steer "$perturbation" "$messages_file"
    fi

    _react_trace "$workdir" "circuit_breaker_perturbation" "$(jq -cn --arg cls "$breaker_class" --arg tier "$source_tier" --arg p "$perturbation" '{classification:$cls, source:$tier, perturbation:$p}')"
    declare -f telemetry_record_anomaly &>/dev/null && telemetry_record_anomaly "$session_id" "CIRCUIT_BREAKER_PERTURBATION" "$breaker_class" "$perturbation" >/dev/null 2>&1 || true
    echo "$perturbation"
}

# ── Circuit Breaker Hard Trip & Quarantine ──────────────────────────
_react_trip_circuit_breaker() {
    local session_id="$1" workdir="$2" reason="$3" action_summary="$4" messages_file="$5" macro_file="$6" last_error="${7:-}"
    ui_err "[CIRCUIT BREAKER TRIPPED] $reason (Action: $action_summary)"
    # Run-ledger counters live in react_run's dynamic scope
    _rl_breaker_trips=$(( ${_rl_breaker_trips:-0} + 1 )); _rl_last_breaker="$reason"
    _react_trace "$workdir" "circuit_breaker_tripped" "$(jq -cn --arg reason "$reason" --arg act "$action_summary" '{reason:$reason, action:$act}')"
    [ -f "$macro_file" ] && jq '.status = "CIRCUIT_BREAKER_TRIPPED"' "$macro_file" > "${macro_file}.tmp" 2>/dev/null && mv "${macro_file}.tmp" "$macro_file" 2>/dev/null || true

    mkdir -p "$LODGE_DIR/.george/alerts" 2>/dev/null || true
    local alert_file="$LODGE_DIR/.george/alerts/alert_${session_id}.json"
    local alert_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")
    local branch_now="none"

    if git -C "$workdir" rev-parse --is-inside-work-tree &>/dev/null; then
        branch_now=$(git -C "$workdir" branch --show-current 2>/dev/null || echo "detached")
        if [ -n "$(git -C "$workdir" status --porcelain 2>/dev/null)" ]; then
            local stash_sha=$(git -C "$workdir" stash create "quarantine: preserve dirty state ($session_id)" 2>/dev/null || true)
            [ -n "$stash_sha" ] && git -C "$workdir" branch -f "quarantine/${session_id}" "$stash_sha" >/dev/null 2>&1 || true
            ui_warn "Dirty state preserved on quarantine branch 'quarantine/${session_id}'"
        fi
    fi

    jq -n --arg id "$session_id" --arg ts "$alert_ts" --arg reason "$reason" --arg act "$action_summary" --arg err "${last_error:0:1000}" --arg branch "$branch_now" --arg workdir "$workdir" \
        '{id: $id, timestamp: $ts, status: "CIRCUIT_BREAKER_TRIPPED", reason: $reason, action: $act, error: $err, branch: $branch, workdir: $workdir}' > "$alert_file" 2>/dev/null || true

    local trip_cls=$(_react_classify_circuit_state "$action_summary" "" "$reason: $last_error" 0 3 3)
    _react_circuit_breaker_perturbation "$session_id" "$workdir" "$trip_cls" "$action_summary" "$reason: $last_error" "$messages_file" "$macro_file"

    declare -f task_sync_signal &>/dev/null && task_sync_signal "$session_id" "circuit_breaker" "$(cat "$alert_file" 2>/dev/null || echo "{}")" >/dev/null 2>&1 || true
    declare -f telemetry_record_anomaly &>/dev/null && telemetry_record_anomaly "$session_id" "CIRCUIT_BREAKER" "react.sh" "$reason: $action_summary" >/dev/null 2>&1 || true
    declare -f telemetry_task_end &>/dev/null && telemetry_task_end "$session_id" 75 "CIRCUIT_BREAKER_TRIPPED" >/dev/null 2>&1 || true
    declare -f agent_sm_transition &>/dev/null && agent_sm_transition "$session_id" "CIRCUIT_BREAKER_TRIPPED" "$reason" 2>/dev/null || true
    declare -f fifo_channel_close &>/dev/null && fifo_channel_close "$session_id" 2>/dev/null || true
}

# ── Self-Healing Circuit Breaker ─────────────────────────────────────
_react_self_heal_circuit_breaker() {
    local session_id="${1:-}" workdir="${2:-$PWD}" session_dir="${3:-}" c_name="${4:-tool}" c_args="${5:-}" messages_file="${6:-}" macro_file="${7:-}" rep_strike="${8:-3}"
    local scratchpad="$session_dir/scratchpad.md" has_evidence=0
    if [ -f "$scratchpad" ]; then
        # Require genuine verified facts (excluding empty search result summaries)
        local real_b_cnt=$(grep -E '^[[:space:]]*(\*|-)' "$scratchpad" 2>/dev/null | grep -vicE '(0 found|0 candidates|0 distinct|results: empty|empty|status: 0|no results|unresponsive)' || echo 0)
        [ "$real_b_cnt" -ge 2 ] && has_evidence=1
    fi

    if [ "$has_evidence" -eq 1 ]; then
        ui_warn "[CIRCUIT BREAKER] Action repetition detected on '$c_name' (Strike $rep_strike), but scratchpad.md contains verified findings."
        ui_info "[CIRCUIT BREAKER] Transitioning loop from research to synthesis to prevent session stall."
        local heal_adv="[CIRCUIT HEALER: Repetition ceiling reached on '$c_name'. Cease repeating this action. You have already gathered verified facts in scratchpad.md. Proceed immediately to synthesize your final report and deliver your findings in clean markdown. Do NOT execute redundant tool calls.]"
        _react_steer "$heal_adv" "$messages_file"
        _react_trace "$workdir" "circuit_healed" "$(jq -cn --arg tool "$c_name" --arg action "transition_to_synthesis" '{tool:$tool, action:$action}')"
        return 0
    elif [ "$rep_strike" -ge 4 ]; then
        ui_err "[CIRCUIT BREAKER] Action repetition ceiling breached with zero scratchpad progress. Tripping hard circuit breaker."
        _react_trip_circuit_breaker "$session_id" "$workdir" "Action repetition ceiling reached ($c_name)" "$c_name ($c_args)" "$messages_file" "$macro_file" "Repeated action with empty scratchpad"
        return 75
    else
        ui_warn "[CIRCUIT BREAKER] Action repetition strike $rep_strike on '$c_name'. Perturbing prompt with alternative vector."
        _react_circuit_breaker_perturbation "$session_id" "$workdir" "ACTION_REPETITION" "$c_name ($c_args)" "Action repetition strike $rep_strike" "$messages_file" "$macro_file"
        return 0
    fi
}

# ── Mid-Turn Sub-Turn LLM Digest & Scratchpad Synchronization ────────
_react_digest_tool_output() {
    local c_id="${1:-}" c_name="${2:-tool}" c_args="${3:-}" resp_content="${4:-}" active_step="${5:-}" session_dir="${6:-}" workdir="${7:-$PWD}" goal="${8:-}" force_llm="${9:-0}"
    local scratchpad="$session_dir/scratchpad.md" memory_file="$session_dir/memory.md"
    mkdir -p "$session_dir/observations" 2>/dev/null || true

    # Full cleaned observation is archived by react_run (observations/call_<id>.txt)

    local ts=$(date '+%H:%M:%S')
    if [ ${#resp_content} -lt 60 ] && ! echo "$resp_content" | grep -qE '(\b[0-9]+\b|https?://|error|fail|status)'; then
        local raw_snippet="${resp_content:0:150}"
        echo -e "\n### [${ts}] ${c_name} (${c_args:0:100})\n- **Milestone**: ${active_step}\n- ${raw_snippet}" >> "$scratchpad"
        ui_dim "  [digest] Brief observation (${#resp_content} chars) recorded to scratchpad" >&2
        echo "$raw_snippet"; return 0
    fi

    local ep_url="${ACTIVE_ENDPOINT_URL:-http://127.0.0.1:8080}" digest_result=""
    local digest_timeout="${REACT_DIGEST_TIMEOUT:-180}" args_snippet="${c_args:0:200}"

    # Only perform sub-turn LLM distillation when force_llm=1 (evidence boundary) AND payload > 3500 chars
    local needs_llm_distill=0
    case "$c_name" in
        web_fetch|fetch_web_pdf|research_*|pdf_read)
            [ "${#resp_content}" -gt 3500 ] && [ "$force_llm" -eq 1 ] && needs_llm_distill=1
            ;;
        *)
            needs_llm_distill=0
            ;;
    esac

    if [ "$needs_llm_distill" -eq 0 ]; then
        local urls=$(echo "$resp_content" | grep -oE 'https?://[^ ">\t]+' | head -n 5 | tr '\n' ' ')
        local clean_out=$(echo "$resp_content" | grep -vE '^\[debug\]' | sed '/^[[:space:]]*$/d' | tr '\n' ' ')
        local head_l="${clean_out:0:800}"
        # rem_1792091177_337 (b167cf0cd9bf): heuristic digests cut a front-only
        # window and silently truncated the tail, so pending_plans and other
        # trailing evidence from crypto_review never reached the evaluator and an
        # extra verification turn was forced. Preserve a balanced tail window and
        # middle landmark slice so mid-output and final evidence survive digesting.
        local mid_l="" tail_l=""
        if [ ${#clean_out} -gt 2400 ]; then
            local mid_pos=$(( ${#clean_out} / 2 - 300 ))
            [ "$mid_pos" -lt 800 ] && mid_pos=800
            mid_l="${clean_out:$mid_pos:600}"
        fi
        [ ${#clean_out} -gt 1500 ] && tail_l="${clean_out: -1200}"
        case "$c_name" in
            file_write|file_edit|file_patch)
                local p=$(echo "$c_args" | jq -r '.path // empty' 2>/dev/null || echo "")
                digest_result="- File modified: ${p:-$c_name}"
                ;;
            *)
                digest_result="- Key Output: ${head_l}"
                [ -n "$mid_l" ] && digest_result="${digest_result}\n- Midpoint excerpt: ${mid_l}"
                [ -n "$tail_l" ] && digest_result="${digest_result}\n- Tail (final evidence): ${tail_l}"
                [ -n "$urls" ] && digest_result="${digest_result}\n- Citations: ${urls}"
                ;;
        esac
        ui_dim "  [digest] Fast heuristic digest recorded for ${c_name} (${#resp_content} chars)" >&2
    else
        ui_dim "  [digest] Sub-turn LLM distilling observation from ${c_name} (${#resp_content} chars)..." >&2

        # Sanitize and window large article / research responses to avoid overwhelming LLM context
        local obs_excerpt="${resp_content:0:4500}"
        if [ ${#resp_content} -gt 4500 ]; then
            local cleaned_obs
            cleaned_obs=$(echo "$resp_content" | sed -E 's/<[^>]+>/ /g' | tr -s ' \t\r\n' ' ')
            obs_excerpt="${cleaned_obs:0:3500}"
        fi

        local sys_prompt="You are the Blue Lodge Evidence Digest Engine. Distill raw tool observations into dense, structured, factual evidence for scratchpad.\nExtract exact numbers, financial figures, dates, URLs, citations, answers. No pleasantries. Concise markdown bullet points."
        local user_prompt="CURRENT ACTIVE MILESTONE:\n${active_step}\n\nTOOL EXECUTED:\n${c_name}(${args_snippet})\n\nRAW OBSERVATION (excerpt):\n${obs_excerpt}\n\nDistill key factual findings, metrics, and citations:"
        local payload=$(jq -n --arg sys "$sys_prompt" --arg user "$user_prompt" '{messages: [{"role": "system", "content": $sys}, {"role": "user", "content": $user}], temperature: 0.7, max_tokens: 500, reasoning_effort: "low", chat_template_kwargs: {enable_thinking: false}, stream: false}')

        # Pulse keepalive before and after distillation call
        declare -f telemetry_task_heartbeat &>/dev/null && [ -n "${AGENT_ACTIVE_SESSION_ID:-}" ] && telemetry_task_heartbeat "$AGENT_ACTIVE_SESSION_ID" "${turn:-1}" "${c_name}:distill" "${max_turns:-200}"
        local resp_json=$(curl -s --max-time "$digest_timeout" "$ep_url/v1/chat/completions" -H "Content-Type: application/json" -d "$payload" 2>/dev/null)
        declare -f telemetry_task_heartbeat &>/dev/null && [ -n "${AGENT_ACTIVE_SESSION_ID:-}" ] && telemetry_task_heartbeat "$AGENT_ACTIVE_SESSION_ID" "${turn:-1}" "${c_name}:distill_done" "${max_turns:-200}"

        digest_result=$(echo "$resp_json" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

        if [ -z "$digest_result" ]; then
            ui_warn "  [digest] Sub-turn LLM unavailable or timed out; generating structured heuristic digest" >&2
            local urls=$(echo "$resp_content" | grep -oE 'https?://[^ ">\t]+' | head -n 5 | tr '\n' ' ')
            local head_l=$(echo "$resp_content" | grep -vE '^\[debug\]' | sed '/^[[:space:]]*$/d' | head -n 6 | tr '\n' ' ')
            digest_result="- Key Output: ${head_l:0:1500}"
            [ -n "$urls" ] && digest_result="${digest_result}\n- Citations: ${urls}"
        else
            digest_result=$(echo "$digest_result" | sed -E 's/<think>.*<\/think>//g')
            local fact_count=$(echo "$digest_result" | grep -c '^[*-]' || echo 1)
            [ "$fact_count" -eq 0 ] && fact_count=1
            ui_ok "  [digest] Sub-turn LLM extracted ${fact_count} structured evidence facts" >&2
        fi
    fi

    { echo ""; echo "### [${ts}] ${c_name} (${args_snippet})"; echo "- **Milestone**: ${active_step}"; echo "${digest_result}"; } >> "$scratchpad"

    if [ -f "$memory_file" ]; then
        grep -q "## Active Discoveries & Working Memory" "$memory_file" || echo -e "\n## Active Discoveries & Working Memory\n" >> "$memory_file"
        echo "- [${ts}] ${c_name}: $(echo "$digest_result" | head -n 3 | tr '\n' ' ')" >> "$memory_file"
    fi

    # D6: no global scratchpad / mem:active_task mirrors — evidence is session-scoped.
    ui_dim "  [digest] Updated session scratchpad.md" >&2
    echo "$digest_result"
}

# ── Background Task Heartbeat Ticker ─────────────────────────────────
# Maintains active heartbeat in both telemetry active ring and Agent SM
# every 20 seconds during inference streaming, tool execution, and distillation.
_react_heartbeat_ticker_start() {
    local s_id="$1"
    local s_dir="$2"
    local m_turns="${3:-200}"
    [ -z "$s_id" ] || [ -z "$s_dir" ] && return 0
    _react_heartbeat_ticker_stop "$s_dir"

    local pid_file="${s_dir}/.heartbeat_ticker.pid"
    (
        exec 2>/dev/null >/dev/null
        while [ -f "$pid_file" ]; do
            sleep 20
            [ ! -f "$pid_file" ] && break
            declare -f telemetry_task_heartbeat &>/dev/null && telemetry_task_heartbeat "$s_id" "${turn:-1}" "${last_invoked_tool:-}" "$m_turns"
            declare -f agent_sm_heartbeat &>/dev/null && agent_sm_heartbeat "$s_id"
        done
        rm -f "$pid_file" 2>/dev/null || true
    ) &
    local ticker_pid=$!
    echo "$ticker_pid" > "$pid_file" 2>/dev/null || true
    disown "$ticker_pid" 2>/dev/null || true
}

_react_heartbeat_ticker_stop() {
    local s_dir="$1"
    [ -z "$s_dir" ] && return 0
    local pid_file="${s_dir}/.heartbeat_ticker.pid"
    if [ -f "$pid_file" ]; then
        local tpid
        tpid=$(cat "$pid_file" 2>/dev/null || echo "")
        rm -f "$pid_file" 2>/dev/null || true
        local cron_pid=""
        [ -f "${GEORGE_DIR:-$HOME/blue-lodge/.george}/.cron.pid" ] && cron_pid=$(cat "${GEORGE_DIR:-$HOME/blue-lodge/.george}/.cron.pid" 2>/dev/null || true)
        if [ -n "$tpid" ] && [ "$tpid" -gt 0 ] 2>/dev/null; then
            # Absolute guard: NEVER kill self, current shell, or cron daemon
            if [ "$tpid" != "$$" ] && [ "$tpid" != "${BASHPID:-0}" ] && [ "$tpid" != "$cron_pid" ]; then
                pkill -P "$tpid" 2>/dev/null || true
                kill -9 "$tpid" 2>/dev/null || true
            fi
        fi
    fi
}

# ── Sub-Turn LLM Milestone Evaluator ─────────────────────────────────
_react_eval_milestone_evidence() {
    local workdir="${1:-$PWD}" session_dir="${2:-}" active_step_id="${3:-1}" active_step_task="${4:-}" goal="${5:-}" last_digest="${6:-}" force_llm="${7:-0}"
    # Session-scoped state only; global .george fallbacks leaked plans across sessions (D6)
    local hd_file="${session_dir:-${AGENT_TASK_WORKSPACE:-}}/honeydew.json"
    local macro_file="${session_dir:-${AGENT_TASK_WORKSPACE:-}}/macro_memory.json"
    if [ -z "$session_dir" ] && [ -z "${AGENT_TASK_WORKSPACE:-}" ]; then
        hd_file="$workdir/.george/honeydew.json"; macro_file="$workdir/.george/macro_memory.json"
    fi
    [ ! -f "$hd_file" ] && return 0

    local verdict="IN_PROGRESS" reason="" suggested_action=""

    # Only evaluate at state boundaries (mutation, milestone interval, near turn ceiling)
    if [ "$force_llm" -ne 1 ]; then
        echo "IN_PROGRESS|Evidence gathering in progress|Continue research"
        return 0
    fi

    # P2.5: one GBNF-constrained call (temperature 0.1): COMPLETE | INCOMPLETE | BLOCKED
    if declare -f react_eval_milestone &>/dev/null; then
        ui_dim "  [evaluator] Judging Step ${active_step_id} (grammar-constrained)..." >&2
        local ev_out ev_v
        ev_out=$(react_eval_milestone "$session_dir" "$active_step_id" "$active_step_task" "$goal" "$last_digest")
        ev_v="${ev_out%%|*}"; local ev_rem="${ev_out#*|}"
        reason="${ev_rem%%|*}"; suggested_action="${ev_rem#*|}"
        case "$ev_v" in
            COMPLETE) verdict="SATISFIED" ;;
            BLOCKED)  verdict="BLOCKED" ;;
            *)        verdict="IN_PROGRESS" ;;
        esac
    fi

    if [ "$verdict" = "SATISFIED" ]; then
        ui_ok "  [evaluator] Step $active_step_id SATISFIED: ${reason:-Milestone requirements met}" >&2
        jq --argjson pid "$active_step_id" '(.items[] | select(.id == $pid)).status = "done"' "$hd_file" > "${hd_file}.tmp" 2>/dev/null && mv "${hd_file}.tmp" "$hd_file"
        local ts_now=$(date '+%Y-%m-%d %H:%M:%S')
        jq --arg ts "$ts_now" --arg obj "$active_step_task" --arg sum "${reason:-Step completed}" '.completed_milestones += [{"timestamp": $ts, "objective": $obj, "summary": $sum, "status": "SATISFIED"}]' "$macro_file" > "${macro_file}.tmp" 2>/dev/null && mv "${macro_file}.tmp" "$macro_file" 2>/dev/null || true

        local prom_dir="${FIFO_IPC_DIR:-/tmp/blue_lodge_ipc}/promises"
        mkdir -p "$prom_dir" 2>/dev/null || true
        jq -n --arg mid "$active_step_id" --arg task "$active_step_task" --arg sum "$reason" --argjson ts "$(date +%s)" '{milestone_id: $mid, task: $task, summary: $sum, status: "RESOLVED", resolved_at: $ts}' > "$prom_dir/milestone_${active_step_id}.json" 2>/dev/null || true

        _react_expand_honeydew_dag "$goal" "$workdir" "$session_dir"
        local new_active=$(jq -r '[.items[]? | select(.status != "done")][0] | if . then "Step " + (.id|tostring) + ": " + .task else "Synthesize Final Deliverable" end' "$hd_file" 2>/dev/null)
        ui_info "  [honeydew] Advanced to: $new_active" >&2
        echo "SATISFIED|${reason}|${new_active}"
    elif [ "$verdict" = "BLOCKED" ]; then
        ui_warn "  [evaluator] Step $active_step_id BLOCKED: ${reason:-no viable source}" >&2
        echo "BLOCKED|${reason}|${suggested_action}"
    else
        ui_info "  [evaluator] Step $active_step_id IN_PROGRESS: ${reason:-Evidence gathering in progress}" >&2
        [ -n "$suggested_action" ] && ui_dim "  [evaluator] Guidance: $suggested_action" >&2
        echo "IN_PROGRESS|${reason}|${suggested_action}"
    fi
}

# ── Outer Loop Dynamic DAG Expansion ─────────────────────────────────
_react_expand_honeydew_dag() {
    local goal="$1" workdir="${2:-$PWD}" session_dir="$3"
    [ "${AGENT_MODE:-}" = "worker" ] && return 0
    local hd_file="${session_dir:-${AGENT_TASK_WORKSPACE:-}}/honeydew.json"
    [ ! -f "$hd_file" ] && hd_file="$workdir/.george/honeydew.json"
    local macro_file="${session_dir:-${AGENT_TASK_WORKSPACE:-}}/macro_memory.json"
    [ ! -f "$macro_file" ] && macro_file="$workdir/.george/macro_memory.json"
    local scratchpad="$session_dir/scratchpad.md"
    local strat_script="$workdir/lib/tools/honeydew_strategist.py"
    [ ! -f "$strat_script" ] && strat_script="$HOME/blue-lodge/lib/tools/honeydew_strategist.py"
    [ -f "$strat_script" ] && [ -f "$hd_file" ] && python3 "$strat_script" --expand "$goal" "$hd_file" "$macro_file" "$scratchpad" "${ACTIVE_ENDPOINT_URL:-http://127.0.0.1:8080}" >/dev/null 2>&1 || true
}

# ── Auto-Compaction Engine (Hierarchical Rich Compaction) ────────────
_react_compact_messages() {
    local session_dir="$1" endpoint_url="$2" workdir="${3:-.}" goal="${4:-}" mode="${5:-master}"
    local messages_file="$session_dir/messages.json" memory_file="$session_dir/memory.md"
    ui_dim "Compacting conversation history (2,500 token rich technical budget)..."

    local user_goal="$goal"
    if [ -z "$user_goal" ]; then
        user_goal=$(jq -r '[.[] | select(.role == "user")][0].content // empty' "$messages_file" 2>/dev/null || echo "Continue task execution.")
        if [[ "$user_goal" == *"HONEYDEW EXECUTION PLAN:"* ]]; then
            user_goal=$(echo "$user_goal" | sed -e 's/^PRIMARY OBJECTIVE:[[:space:]]*//' -e '/HONEYDEW EXECUTION PLAN:/,$d' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        elif [[ "$user_goal" == "PRIMARY OBJECTIVE:"* ]]; then
            user_goal="${user_goal#PRIMARY OBJECTIVE:}"
            user_goal="$(echo "$user_goal" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        fi
    fi
    [ -z "$user_goal" ] && user_goal="Continue task execution."
    local files_touched=$(jq -r '[.[] | select(.role=="assistant") | .tool_calls[]?.function.arguments | fromjson? | .path // empty] | unique | .[]' "$messages_file" 2>/dev/null | head -n 20 | tr '\n' ', ' | sed 's/,[[:space:]]*$//')
    local recent_commands=$(jq -r '[.[] | select(.role=="assistant") | .tool_calls[]?.function.arguments | fromjson? | .command // empty] | .[-6:] | .[]' "$messages_file" 2>/dev/null | tr '\n' '; ' | sed 's/;[[:space:]]*$//')
    local recent_obs=$(jq -r '[.[] | select(.role=="tool")][-3:] | .[].content // empty' "$messages_file" 2>/dev/null | head -n 20 | tr '\n' ' ')
    local git_context=""
    if git -C "$workdir" rev-parse --is-inside-work-tree &>/dev/null; then
        local b_now=$(git -C "$workdir" branch --show-current 2>/dev/null || echo "detached")
        local s_now=$(git -C "$workdir" status --short 2>/dev/null | tr '\n' ' ' | head -c 160)
        git_context="Git Branch: $b_now | Status: ${s_now:-clean}"
    fi

    local msgs_summary=$(jq -r '.[] | "\(.role): \(.content // (if .tool_calls then (.tool_calls | map(.function.name + "(" + (.function.arguments // "") + ")") | join("; ")) else "" end))"' "$messages_file" 2>/dev/null | tail -n 80)
    local prompt="The following is an ongoing technical agent trajectory for a software engineering or operational task.\n${git_context:+Current Environment: $git_context\n}Produce an exhaustive technical summary up to 2,500 tokens preserving the user's primary objective, active plan IDs (e.g. P-XXXXXX), tool outputs, files, errors, and next actions.\n\nTrajectory history:\n$msgs_summary"
    local payload=$(jq -n --arg sys "You are a senior software architect and technical state summarizer." --arg prompt "$prompt" --arg r_effort "${LLM_REASONING_EFFORT:-medium}" '{messages: [{"role": "system", "content": $sys}, {"role": "user", "content": $prompt}], temperature: 1.0, max_tokens: 2500, reasoning_effort: $r_effort}')
    local summary_resp=$(curl -s --max-time 120 "$endpoint_url/v1/chat/completions" -H "Content-Type: application/json" -d "$payload" 2>/dev/null)
    local summary_text=$(echo "$summary_resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

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

    local recent_pair=$(jq -c '
        if length >= 2 and .[-1].role == "tool" then
            ([.[] | select(.role == "assistant")] | .[-1]) as $last_asst |
            if ($last_asst.tool_calls | length) == 1 and .[-2].role == "assistant" then [.[-2], .[-1]] else [] end
        else [] end
    ' "$messages_file" 2>/dev/null || echo "[]")

    local sys_msg=$(jq '.[0] // empty' "$messages_file" 2>/dev/null)
    echo "$sys_msg" | jq -e '.role == "system"' >/dev/null 2>&1 || sys_msg='{"role": "system", "content": "You are George, senior technical companion and builder."}'

    local hd_file="$session_dir/honeydew.json"
    [ ! -f "$hd_file" ] && hd_file="${AGENT_TASK_WORKSPACE:-}/honeydew.json"
    [ ! -f "$hd_file" ] && hd_file="$workdir/.george/honeydew.json"

    local bedrock_appendix=""
    if declare -f native_tools_bedrock_appendix &>/dev/null; then
        bedrock_appendix=$(native_tools_bedrock_appendix)
    fi

    local compacted_user_msg=""
    if [ "$mode" = "worker" ]; then
        compacted_user_msg="PRIMARY OBJECTIVE (DELEGATED WORKER):\n$user_goal\n\nSANDBOX WORKSPACE:\n$workdir"
        [ -n "$bedrock_appendix" ] && compacted_user_msg+="\n\n$bedrock_appendix"
    elif [ -f "$hd_file" ]; then
        local current_hd_step plan_check
        current_hd_step=$(jq -r '[.items[]? | select(.status != "done")][0] | if . then "Step " + (.id|tostring) + ": " + .task else "Synthesize Final Deliverable" end' "$hd_file" 2>/dev/null)
        [ -z "$current_hd_step" ] && current_hd_step="Synthesize Final Deliverable"
        plan_check=$(jq -r '.items[]? | "- [" + (if .status == "done" then "✓" else " " end) + "] Step " + (.id|tostring) + ": " + .task' "$hd_file" 2>/dev/null)
        local directive="Focus exclusively on executing $current_hd_step directly using domain getter/action tools."
        if _react_is_final_synthesis_step "$current_hd_step" "$hd_file"; then
            directive=$(_react_synthesis_directive "$current_hd_step")
        fi
        compacted_user_msg="PRIMARY OBJECTIVE:\n$user_goal\n\nHONEYDEW EXECUTION PLAN:\n$plan_check\n\nCURRENT ACTIVE MILESTONE:\n$current_hd_step\n\nDIRECTIVE: $directive"
        [ -n "$bedrock_appendix" ] && compacted_user_msg+="\n\n$bedrock_appendix"
    else
        compacted_user_msg="PRIMARY OBJECTIVE:\n$user_goal"
        [ -n "$bedrock_appendix" ] && compacted_user_msg+="\n\n$bedrock_appendix"
    fi

    # Protect and pin the Grounding Evidence Ledger across compaction
    local evidence_ledger=""
    if [ -f "$session_dir/scratchpad.md" ] && [ -s "$session_dir/scratchpad.md" ]; then
        evidence_ledger=$(head -c 8000 "$session_dir/scratchpad.md")
    elif [ -f "$workdir/.george/scratchpad.md" ] && [ -s "$workdir/.george/scratchpad.md" ]; then
        evidence_ledger=$(head -c 8000 "$workdir/.george/scratchpad.md")
    fi
    if [ -n "$evidence_ledger" ]; then
        compacted_user_msg+="\n\nGROUNDING EVIDENCE LEDGER (PRESERVED ACROSS COMPACTION):\n$evidence_ledger"
    fi

    jq -n --argjson sys "$sys_msg" --arg user_msg "$compacted_user_msg" --arg mem "$summary_text" --argjson recent "$recent_pair" '
        [$sys, {"role": "user", "content": $user_msg}, {"role": "assistant", "content": ("[PREVIOUS CONTEXT COMPACTED - TECHNICAL STATE SUMMARY]:\n" + $mem)}] +
        (if ($recent | length) == 2 then [
            {"role": "user", "content": "Continue executing the task based on the technical progress summary above. Here was your most recent working tool execution before compaction:"},
            $recent[0], $recent[1],
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
    local cleaned=$(echo "$1" | sed -e '/<think>/,/<\/think>/d')
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
    action="${action#\`}"; action="${action%\`}"; echo "${action%$'\r'}"
}

# ── Honeydew Dynamic Multi-Step Planner ──────────────────────────────
_react_ensure_honeydew_plan() {
    local task="$1" workdir="${2:-$PWD}" gdir="${2:-$PWD}/.george" force="${3:-0}" target_dir="${4:-}"
    local hd_file=""
    if [ -n "$target_dir" ] && [ -d "$target_dir" ]; then
        hd_file="$target_dir/honeydew.json"
    elif [ -n "${session_dir:-}" ] && [ -d "$session_dir" ]; then
        hd_file="$session_dir/honeydew.json"
    elif [ -n "${AGENT_TASK_WORKSPACE:-}" ] && [ -d "$AGENT_TASK_WORKSPACE" ]; then
        hd_file="$AGENT_TASK_WORKSPACE/honeydew.json"
    else
        hd_file="$gdir/honeydew.json"
    fi
    local clean_task="$task"
    mkdir -p "$(dirname "$hd_file")" "$gdir" 2>/dev/null || true

    if [[ "$task" =~ \[Current\ Inbound\ Message[^\]]*\]:?[[:space:]]*(.*) ]]; then
        clean_task="${BASH_REMATCH[1]}"
        clean_task="${clean_task%%============================================================*}"
    elif [[ "$task" =~ \[ACTIVE\ PRIMARY\ OBJECTIVE[^\]]*\]:?[[:space:]]*(.*) ]]; then
        clean_task="${BASH_REMATCH[1]}"
        clean_task="${clean_task%%============================================================*}"
    fi
    clean_task=$(echo "$clean_task" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$clean_task" ] && clean_task="$task"

    local rebuild=1
    if [ "$force" -eq 0 ] && [ -f "$hd_file" ]; then
        local cur_task=$(jq -r '.primary_task // empty' "$hd_file" 2>/dev/null)
        local pending_cnt=$(jq -r '[.items[]? | select(.status != "done")] | length' "$hd_file" 2>/dev/null || echo 0)
        [ "$cur_task" = "$clean_task" ] && [ "$pending_cnt" -gt 0 ] && rebuild=0
    fi

    if [ "$rebuild" -eq 1 ]; then
        local items_json="" ep_url="${ACTIVE_ENDPOINT_URL:-http://127.0.0.1:8080}" strat_script="$workdir/lib/tools/honeydew_strategist.py"
        [ ! -f "$strat_script" ] && strat_script="$HOME/blue-lodge/lib/tools/honeydew_strategist.py"
        local strat_out=""
        local strat_err_log="${session_dir:-/tmp}/honeydew_strategist.err"
        if declare -f ipc_acquire_inference_lease &>/dev/null; then
            ipc_acquire_inference_lease "${_task_priority:-50}" "${session_id:-task_$$}_hd" 120 2>/dev/null || true
        fi
        [ -f "$strat_script" ] && strat_out=$(python3 "$strat_script" "$clean_task" "$ep_url" 2>>"$strat_err_log" || true)
        if [ "${_task_priority:-50}" -lt "${IPC_PRIO_INTERACTIVE:-100}" ] && declare -f ipc_release_inference_lease &>/dev/null; then
            ipc_release_inference_lease 2>/dev/null || true
        fi
        local strat_type="ops" strat_source="heuristic"
        if echo "$strat_out" | jq -e 'type == "object" and .items' >/dev/null 2>&1; then
            strat_type=$(echo "$strat_out" | jq -r '.task_type // "ops"')
            strat_source=$(echo "$strat_out" | jq -r '.source // "heuristic"')
            items_json=$(echo "$strat_out" | jq -c '.items')
        elif echo "$strat_out" | jq -e 'type == "array"' >/dev/null 2>&1; then
            items_json="$strat_out"
            strat_type=$(echo "$strat_out" | jq -r '.[0].task_type // "ops"')
        fi
        local items_len=$(echo "$items_json" | jq 'length' 2>/dev/null || echo 0)
        if [ "$items_len" -ge 1 ] && [ "$strat_type" = "chat" ]; then
            ui_dim "  ✓ Pre-Loop Strategist generated conversational milestone (type: chat, source: $strat_source)"
        elif [ "$items_len" -ge 2 ]; then
            ui_dim "  ✓ Pre-Loop Strategist generated $items_len bespoke DAG milestones (type: $strat_type, source: $strat_source)"
        else
            items_json='[{"id": 1, "task": "Execute targeted action to fulfill the objective", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0, "task_type": "'"$strat_type"'"}, {"id": 2, "task": "Synthesize results and deliver final response to operator", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0, "task_type": "'"$strat_type"'"}]'
        fi
        jq -n --arg task "$clean_task" --arg type "$strat_type" --argjson items "$items_json" '{"primary_task": $task, "task_type": $type, "items": $items}' > "$hd_file" 2>/dev/null || true
        if [ -z "${GEORGE_PARENT_TASK_ID:-}" ]; then
            cp -f "$hd_file" "$gdir/honeydew.json" 2>/dev/null || true
        fi

        if declare -f fifo_ipc_init &>/dev/null; then
            fifo_ipc_init 2>/dev/null || true
            local prom_dir="${FIFO_IPC_DIR:-/tmp/blue_lodge_ipc}/promises" now_ts=$(date +%s)
            mkdir -p "$prom_dir" 2>/dev/null || true
            for m_id in $(jq -r '.items[]?.id // empty' "$hd_file" 2>/dev/null); do
                jq -n --arg mid "$m_id" --argjson ts "$now_ts" '{milestone_id: $mid, status: "PENDING", created_at: $ts}' > "$prom_dir/milestone_${m_id}.json" 2>/dev/null || true
            done
        fi
    fi

    ui_section "Honeydew Execution Plan"
    local plan_txt=$(jq -r '.items[] | "  [" + (if .status == "done" then "✓" else " " end) + "] Step " + (.id|tostring) + ": " + .task' "$hd_file" 2>/dev/null)
    if declare -f transcript_log_block &>/dev/null; then
        transcript_log_block "Honeydew Execution Plan" "$plan_txt"
    fi
    return 0
}

# Count pending milestones in honeydew.json that require tool/action execution
# (excludes only the final in-session synthesis / conversational reply step).
_react_pending_action_steps() {
    local hd_file="${1:-}"
    [ -f "$hd_file" ] || { echo 0; return 0; }
    local in_discord="${_DISCORD_IN_SESSION:-0}"
    jq -r --argjson disc "$in_discord" '
        (.items[-1].id // 0) as $last_id |
        [.items[]? | select(.status != "done") | select(
            (.id == $last_id) and (
                ((.task | test("^(Step [0-9]+: )?synthesize\\b"; "i")) and ((.task | test("\\b(create|build|implement|modify|patch|refactor|deploy|commit|push)\\b"; "i")) | not) and ($disc == 1 or ((.task | test("\\b(discord|dm|webhook|email|telegram|tweet|x_post)\\b"; "i")) | not)))
                or
                ((.task | test("^(Step [0-9]+: )?(compose|draft|formulate|conclude|summarize|acknowledge|reply|respond|answer|present|share|deliver|report|provide)\\b"; "i"))
                 and ((.task | test("\\b(create|build|implement|run|test|execute|verify|inspect|check|configure|schedule|register|deploy|research|search|fetch|scrape|reconstruct|modify|patch|refactor|edit|commit|push|merge|spawn|locate|gather|extract|retrieve|diagnose|remediate|vision_analyze)\\b"; "i")) | not)
                 and ($disc == 1 or ((.task | test("\\b(discord|dm|webhook|email|telegram|tweet|x_post)\\b"; "i")) | not))
                 and ((.task | test("\\b(dm|direct message)\\b"; "i")) | not))
            )
            | not
        )] | length
    ' "$hd_file" 2>/dev/null || echo 0
}

_react_is_final_synthesis_step() {
    local step_text="${1:-}" hd_file="${2:-}"
    if [ -n "$hd_file" ] && [ -f "$hd_file" ]; then
        local rem_act
        rem_act=$(_react_pending_action_steps "$hd_file")
        [ "${rem_act:-1}" -eq 0 ] && return 0
        return 1
    fi
    if [[ "$step_text" =~ [Ss]ynthesize ]] || [[ "$step_text" =~ [Ff]inal\ [Dd]eliverable ]] || [[ "$step_text" == "All plan steps completed." ]]; then
        return 0
    fi
    return 1
}

_react_synthesis_directive() {
    local step_label="${1:-Synthesize Final Deliverable}"
    if [ "${_DISCORD_IN_SESSION:-0}" = "1" ]; then
        printf '%s' "All action/inspection milestones are satisfied [✓]. Write your reply to @${_DISCORD_CURRENT_AUTHOR:-the user} itself — the actual answer or report they asked for, directly in Discord markdown. Your plain-text response at the end of your turn is posted to this channel automatically and completes ${step_label} — do NOT call milestone_complete or task_complete, and do NOT use discord_send for your final reply (only use discord_send if you still have more tool calls to run and need to post a brief mid-task status update first). Do not include 'I sent…' or 'What I did:' meta-narration."
    else
        printf '%s' "All action/inspection milestones are satisfied [✓]. Synthesize your final deliverable and present your findings directly in clean markdown. Do NOT call milestone_complete or task_complete — emitting your markdown response completes the task."
    fi
}

_react_advance_honeydew_plan() {
    local workdir="${1:-$PWD}" action_name="${2:-}" action_args="${3:-}" action_obs="${4:-}"
    local hd_file="${session_dir:-${AGENT_TASK_WORKSPACE:-}}/honeydew.json"
    [ ! -f "$hd_file" ] && hd_file="$workdir/.george/honeydew.json"
    [ ! -f "$hd_file" ] || [ "${AGENT_MODE:-}" = "worker" ] && return 0
    # A mid-task status update sent in response to DISCORD_STATUS_NUDGE_TURN must not advance the active milestone
    if [ "$action_name" = "discord_send" ] && [ "${_discord_nudge_turn:-0}" -eq "${turn:-0}" ] && [ "${turn:-0}" -gt 0 ]; then
        return 0
    fi
    local pending_id=$(jq -r '[.items[] | select(.status != "done")][0].id // empty' "$hd_file" 2>/dev/null)
    [ -z "$pending_id" ] && return 0
    local pending_task=$(jq -r --argjson pid "$pending_id" '.items[] | select(.id == $pid) | .task // empty' "$hd_file" 2>/dev/null)
    local l_task="${pending_task,,}" l_args="${action_args,,}" should_advance=0

    # 1. Explicit milestone completion signals
    if [[ "$action_name" =~ ^(milestone_complete|task_complete|end_turn)$ ]]; then
        should_advance=1

    # 2. Discrete operational side effects (cron registration, delivery, execution, crypto workflow, vision/SDR inspection)
    elif [[ "$action_name" =~ ^(vision_analyze|reverse_image_search|sdr_query|sdr_listen)$ ]] && echo "$l_task" | grep -qiE '\b(inspect|analyze|examine|describe|identify|view|check|look|image|photo|picture|attachment|visual|sdr|radio|scanner|talkgroup|unit|dispatch|audio|m4a|query|stat)\b'; then
        should_advance=1
    elif [[ "$action_name" =~ ^(crypto_review|wallet_status|wallet_balances)$ ]] && echo "$l_task" | grep -qiE '\b(review|wallet|balance|portfolio|state|position|inventory|treasury|inspect|check)\b'; then
        should_advance=1
    elif [[ "$action_name" == "crypto_scan" ]] && echo "$l_task" | grep -qiE '\b(scan|pool|market|price|signal|spread|dislocation|opportunity|evaluate|analyze|inspect)\b'; then
        should_advance=1
    elif [[ "$action_name" =~ ^(crypto_plan|crypto_standing_order)$ ]] && echo "$l_task" | grep -qiE '\b(plan|propose|build|construct|formul|allocat|order|limit|trade|standing|reprice|reclaim)\b'; then
        should_advance=1
    elif [[ "$action_name" == "crypto_execute" ]] && echo "$l_task" | grep -qiE '\b(execute|confirm|submit|place|trade|order|reclaim|reprice)\b'; then
        should_advance=1
    elif [[ "$action_name" =~ ^(operator_ask|operator_notify)$ ]] && echo "$l_task" | grep -qiE '\b(ask|notify|escalat|operator|present|deliver|report|confirm)\b'; then
        should_advance=1
    elif [[ "$l_task" =~ (create|register|write|implement|reconstruct|modify|update|patch|configure|refactor).*(cron|job|script) ]]; then
        ([[ "$action_name" =~ file_write|file_edit ]] || [[ "$action_name" == "bash_exec" && $(_react_tool_is_mutating "$action_name" "$action_args") ]]) && [[ "$l_args" =~ cron_jobs|\.sh ]] && should_advance=1
    elif [[ "$l_task" =~ (verify|execute|test|run).*(cron|sandbox|research) ]]; then
        ([[ "$action_name" =~ research_sandbox ]] || ([[ "$action_name" == "bash_exec" ]] && [[ "$l_args" =~ (research_sandbox|\.george/cron_jobs/.*\.sh|scripts/.*\.sh) ]] && ! [[ "$l_args" =~ ^[[:space:]]*\"?(ls|cat|head|tail|grep|find)[[:space:]] ]])) && should_advance=1
    elif [[ "$l_task" =~ (deliver|send|report|post|compose|reply|respond).*(discord|channel|user|dm|recipient|response|reply|@) ]] && ! echo "$l_task" | grep -qiE '^(step [0-9]+: )?(investigate|research|inspect|analyze|check|verify|test|build|create|implement|fix|debug|search|fetch|scrape)\b'; then
        ([[ "$action_name" =~ discord_send|discord_dm|operator_notify|operator_ask ]] || ([[ "$action_name" == "bash_exec" ]] && [[ "$l_args" =~ (discord_send|discord_dm|curl.*discord) ]] && ! [[ "$l_args" =~ ^[[:space:]]*\"?(ls|cat|head|tail|grep|find)[[:space:]] ]])) && should_advance=1
    elif echo "$l_task" | grep -qiE '\b(system status|service status|diagnostics?|phytology|living tissue|system vitals|engine health)\b'; then
        ([[ "$action_name" =~ phytology|service_manage|vitals_manage ]] || [[ "$l_args" =~ status|audit|cache-status|fitness ]]) && should_advance=1
    elif echo "$l_task" | grep -qiE '\b(verify|test|harness|syntax|regression)\b' && ! echo "$l_task" | grep -qiE '\b(search|download|extract|literature|synthesize)\b'; then
        [[ "$action_name" =~ bash_exec|test|code_validate ]] && [[ "$l_args" =~ test|check|cargo|pytest|make|npm|bash\ -n ]] && should_advance=1
    fi

    # 3. Deterministic physical file evidence check for retrieval/download milestones
    # Multi-turn search/retrieval steps MUST NOT advance on mere getter tool invocation (file_read, hn_search, web_search, arxiv_search).
    # They require physical artifacts (at least 2 extracted papers/notes) or evaluation via _react_eval_milestone_evidence.
    if [ "$should_advance" -eq 0 ] && ! echo "$l_task" | grep -qiE '\b(create|write|implement|modify|update|patch|refactor|edit)\b' && echo "$l_task" | grep -qiE '\b(search|literature|download|paper|source|extract)\b'; then
        local file_count=0
        file_count=$(find "$workdir" -maxdepth 2 \( -path '*/papers/*.txt' -o -path '*/artifacts/*' -o -name 'notes*.txt' -o -name 'extract_*.txt' \) 2>/dev/null | wc -l)
        if [ "$file_count" -ge 2 ]; then
            should_advance=1
        fi
    fi

    [ "$should_advance" -eq 0 ] && return 0
    jq --argjson pid "$pending_id" '(.items[] | select(.id == $pid)).status = "done"' "$hd_file" > "${hd_file}.tmp" 2>/dev/null && mv "${hd_file}.tmp" "$hd_file"

    # Terminal delivery fast-path:
    # If this was a delivery milestone and all actionable steps are complete, mark any trailing
    # synthesis/conclusion milestones as done so autonomous runs and cron jobs exit cleanly without
    # taking extra turns to write redundant internal cycle reports.
    if [[ "$l_task" =~ (deliver|send|report|post|compose|reply|respond).*(discord|channel|user|dm|recipient|response|reply|@) ]] || [[ "$action_name" =~ ^(discord_send|discord_dm|operator_ask|operator_notify)$ ]]; then
        local rem_action_steps
        rem_action_steps=$(_react_pending_action_steps "$hd_file")
        if [ "${rem_action_steps:-0}" -eq 0 ]; then
            jq '(.items[]? | select(.status != "done")).status = "done"' "$hd_file" > "${hd_file}.tmp" 2>/dev/null && mv "${hd_file}.tmp" "$hd_file"
        fi
    fi

    local prom_dir="${FIFO_IPC_DIR:-/tmp/blue_lodge_ipc}/promises"
    mkdir -p "$prom_dir" 2>/dev/null || true
    jq -n --arg mid "$pending_id" --arg task "$pending_task" --arg act "$action_name" --argjson ts "$(date +%s)" '{milestone_id: $mid, task: $task, resolver_tool: $act, status: "RESOLVED", resolved_at: $ts}' > "$prom_dir/milestone_${pending_id}.json" 2>/dev/null || true

    _react_expand_honeydew_dag "" "$workdir" "${AGENT_ACTIVE_SESSION_DIR:-$workdir/.george/workspaces/${AGENT_ACTIVE_SESSION_ID:-default}}"
    local new_active=$(jq -r '[.items[] | select(.status != "done")][0] | if . then "Step " + (.id|tostring) + ": " + .task else "All plan steps completed." end' "$hd_file" 2>/dev/null)
    ui_info "  [honeydew] Step $pending_id complete -> Next: $new_active"
}

# ── Milestone-Scoped Tool Masking ────────────────────────────────────
_react_scope_tools_for_step() {
    local all_tools_json="${1:-[]}" active_step="${2:-}" pending_tool_steps="${3:-1}"
    [ "${AGENT_MODE:-}" = "worker" ] && { echo "$all_tools_json"; return 0; }
    local s_low="${active_step,,}" pat=""

    # 1. Inviolable Bedrock Meta-Tools
    # These must NEVER be stripped out by milestone scoping to prevent grammar logit collapse.
    # ask_operator is included ONLY when an interactive operator is present (Discord or REPL).
    local bedrock_meta="^(tool_search|slash_command_exec|milestone_complete|task_complete|end_turn|bash_exec|web_fetch)"
    if declare -f is_interactive_operator_session &>/dev/null && is_interactive_operator_session; then
        bedrock_meta="^(tool_search|slash_command_exec|ask_operator|milestone_complete|task_complete|end_turn|bash_exec|web_fetch)"
    else
        all_tools_json=$(echo "$all_tools_json" | jq '[.[] | select(.function.name != "ask_operator")]' 2>/dev/null || echo "$all_tools_json")
    fi

    if echo "$s_low" | grep -qiE '\b(synthesize|compose|conclude|respond to operator|final deliverable|deliver|conversational response|conversational reply|acknowledge message)\b'; then
        # Synthesis Mode: Preserve bedrock tools (including execution tools) and delivery tools
        pat="${bedrock_meta}|(file_read|file_edit|file_write|sdr_query|sdr_listen|discord_send|discord_dm|discord_edit|discord_send_file)$"
    elif echo "$s_low" | grep -qiE '\b(code|implement|edit|write|patch|refactor|fix|compile|cargo|npm|cron|schedule|register|create|build)\b'; then
        pat="${bedrock_meta}|(file_read|file_edit|file_write|symbol_patch|code_outline|code_symbol_get|file_grep|research_sandbox|web_search|web_fetch|searxng_.*|sdr_query|sdr_listen|git_status|git_diff|git_commit|discord_send|discord_dm)$"
    elif echo "$s_low" | grep -qiE '\b(research|investigate|search|web|find out|background|literature|arxiv|cve|scrape|intel|dossier|sdr|radio|scanner|talkgroup|unit|dispatch|audio|m4a|query|stat)\b'; then
        pat="${bedrock_meta}|(web_search|web_search_cross_section|web_fetch|searxng_.*|arxiv_search|hn_search|research_sandbox|scrape|sdr_query|sdr_listen|file_read|file_write|recall_search|pdf_read|discord_send_file)$"
    elif echo "$s_low" | grep -qiE '\b(crypto|cardano|wallet|dex|swap|order|limit|stop|bracket|reclaim|arbitrage|lending|loan|fund|snek|min|wmtx|djed)\b'; then
        pat="${bedrock_meta}|(wallet_.*|crypto_.*|cardano_.*|polymarket_.*|lending_.*|fund_.*|file_read|file_write|discord_send|discord_dm)$"
    elif echo "$s_low" | grep -qiE '\b(test|verify|validate|benchmark|suite|check)\b'; then
        pat="${bedrock_meta}|(file_read|file_write|web_search|web_fetch|research_sandbox|sdr_query|sdr_listen|git_status|git_diff|discord_send|discord_dm)$"
    elif echo "$s_low" | grep -qiE '\b(system status|service status|diagnostics?|phytology|living tissue|system vitals|engine health)\b'; then
        pat="${bedrock_meta}|(phytology_manage|service_manage|vitals_manage|sdr_query|git_status)$"
    fi

    # 2. Objective-Aware Pre-Provisioning:
    # If the active goal/objective mandates specific integration delivery, preserve those tools across all steps
    if [ -n "${goal:-}" ]; then
        if echo "$goal" | grep -qiE 'discord_send|#nfl-memes|#general|#|Logic server|discord'; then
            pat="${pat%\$}|discord_send|discord_dm|discord_edit|discord_send_file)$"
        fi
        if echo "$goal" | grep -qiE 'github|gitea|pull request|pr_create|git_push'; then
            pat="${pat%\$}|gitea_.*|git_.*)$"
        fi
        if echo "$goal" | grep -qiE 'crypto|wallet|cardano|ada|polymarket|arbitrage|swap|dex|trade|loan|snek|order|reclaim|stop'; then
            pat="${pat%\$}|wallet_.*|crypto_.*|cardano_.*|polymarket_.*|lending_.*|fund_.*)$"
        fi
        if echo "$goal" | grep -qiE 'sdr|radio|scanner|talkgroup|tgid|p25|dispatch|m4a|metro|county|county|springfield|county ems|sheriff|ems|unit'; then
            pat="${pat%\$}|sdr_query|sdr_listen|discord_send_file)$"
        fi
    fi

    # In a live Discord conversation George must always be able to talk to the channel
    # (progress notes, partial answers, edits) whatever milestone is active.
    if [ -n "$pat" ] && [ "${_DISCORD_IN_SESSION:-0}" = "1" ]; then
        pat="${pat%\$}|discord_send|discord_edit|discord_send_file|sdr_query|sdr_listen)$"
    fi

    # 3. Dynamic Tool Search Preservation:
    # If the agent has dynamically attached tools into active_tools.json via tool_search,
    # NEVER strip them out via milestone pattern scoping!
    if [ -n "${session_dir:-}" ] && [ -f "$session_dir/trajectory.log" ]; then
        if grep -q "Tool Call: tool_search" "$session_dir/trajectory.log" 2>/dev/null; then
            echo "$all_tools_json"
            return 0
        fi
    fi

    if [ -n "$pat" ]; then
        local scoped=$(echo "$all_tools_json" | jq -c --arg pat "$pat" '[.[] | select(.function.name | test($pat))]' 2>/dev/null)
        [ -n "$scoped" ] && [ "$scoped" != "[]" ] && { echo "$scoped"; return 0; }
    fi
    echo "$all_tools_json"
}

# ── Option C: Two-Tier Recovery Cascade ──────────────────────────────
_react_dag_handle_failure() {
    local workdir="${1:-$PWD}" milestone_id="${2:-1}" failure_reason="${3:-Unknown failure}"
    local hd_file="${session_dir:-${AGENT_TASK_WORKSPACE:-}}/honeydew.json"
    [ ! -f "$hd_file" ] && hd_file="$workdir/.george/honeydew.json"
    [ ! -f "$hd_file" ] && return 1
    local cur_retries=$(jq -r --argjson mid "$milestone_id" '(.items[] | select(.id == $mid)).retry_count // 0' "$hd_file" 2>/dev/null || echo 0)

    if [ "$cur_retries" -lt 1 ]; then
        ui_warn "  [recovery:tier-1] Milestone $milestone_id failed contract ($failure_reason). Triggering local micro-retry (1/1)..."
        jq --argjson mid "$milestone_id" '(.items[] | select(.id == $mid)).retry_count = 1' "$hd_file" > "${hd_file}.tmp" 2>/dev/null && mv "${hd_file}.tmp" "$hd_file"
        return 0
    else
        ui_err "  [recovery:tier-2] Milestone $milestone_id failed micro-retry. Escalating to Strategist DAG rewrite..."
        local rem_id=$((milestone_id * 10 + 1)) rem_task="Diagnose and remediate blocker: $failure_reason"
        local updated=$(jq --argjson mid "$milestone_id" --argjson rid "$rem_id" --arg rtask "$rem_task" '.items |= map(if .id == $mid then .status = "remediating" else . end) | .items = [{"id": $rid, "task": $rtask, "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0}] + .items' "$hd_file" 2>/dev/null)
        [ -n "$updated" ] && echo "$updated" > "$hd_file" && ui_info "  [recovery:tier-2] Inserted remediation Step $rem_id into DAG before resuming."
        return 2
    fi
}

# ── Helper for XML/Text Tool Call Extraction ─────────────────────────
_react_extract_text_tool_calls() {
    python3 -c '
import sys, re, json
text = sys.stdin.read()
calls = []
for j_str in re.findall(r"<tool_call[^>]*>\s*(\{.*?\})(?:\s*</tool_call>|$)", text, re.DOTALL):
    try:
        d = json.loads(j_str)
        if "name" in d:
            args = d.get("arguments", {})
            calls.append({"id": f"call_txt_{len(calls)+1}", "type": "function", "function": {"name": d["name"], "arguments": json.dumps(args) if not isinstance(args, str) else args}})
    except Exception: pass

for m in re.finditer(r"<function\s*=\s*([a-zA-Z0-9_-]+)\s*>(.*?)(?:</function>|$)", text, re.DOTALL):
    fn_name = m.group(1).strip()
    params = {}
    for pm in re.finditer(r"<(?:parameter\s*(?:=\s*|\s+name\s*=\s*["'"'"']?)([a-zA-Z0-9_]+)["'"'"']?|([a-zA-Z0-9_]+))\s*>(.*?)(?:</(?:parameter||)>|(?=<parameter)|(?=<[a-zA-Z0-9_]+>)|$)", m.group(2), re.DOTALL):
        k = pm.group(1) or pm.group(2)
        v = re.sub(r"</?[^>]+>", "", pm.group(3).strip()).strip()
        if k and k != "function": params[k] = v
    if fn_name == "computer_use": fn_name = params.pop("name", params.pop("action", fn_name))
    calls.append({"id": f"call_txt_{len(calls)+1}", "type": "function", "function": {"name": fn_name, "arguments": json.dumps(params)}})
print(json.dumps(calls))
' <<< "$1" 2>/dev/null || echo "[]"
}

# ── Helper for Tool Call Arguments Repair ────────────────────────────
_react_repair_tool_calls() {
    python3 -c '
import sys, json, re, os
ws = os.environ.get("LODGE_DIR") or os.path.expanduser("~/blue-lodge")
reasoning = sys.argv[1] if len(sys.argv) > 1 else ""

def clean_arg(raw):
    if not raw or raw == "null": return "{}"
    d = {}
    for sfx in ["", "}", "\"\n}", "\n}", "}"]:
        try:
            j = json.loads(raw + sfx, strict=False)
            if isinstance(j, dict):
                for k, v in j.items():
                    d[k] = re.split(r"</?(?:parameter|function|tool_call|invoke|output)[^>]*>", v)[0].strip() if isinstance(v, str) else v
                break
        except Exception: continue
    if not d:
        for m in re.finditer(r"\"([a-zA-Z0-9_]+)\"\s*:\s*\"([^\"<]+)\"", raw): d[m.group(1)] = m.group(2).strip()
    for k, v in re.findall(r"<parameter\s*(?:=\s*)?([a-zA-Z0-9_]+)\s*>\s*(.*?)(?:</parameter>|(?=<parameter)|(?=</function>)|$)", raw, re.DOTALL):
        vc = re.sub(r"</?[^>]+>", "", v.strip()).strip()
        d[k] = int(vc) if vc.isdigit() else vc
    if "command" in d and isinstance(d["command"], str):
        c = re.split(r"</?(?:parameter|function|tool_call|invoke|output)[^>]*>", d["command"])[0].strip()
        c = re.sub(r"head -n(\s*(\||&|;|$))", r"head -n 10 \1", c)
        c = re.sub(r"git rev-parse\s+([^\s]+)\s+--short", r"git rev-parse --short \1", c)
        c = re.sub(r"\bgit checkout -b\b", "git checkout -B", c)
        c = re.sub(r"(https?://)\s+", r"\1", c)
        c = re.sub(r"(https?://[a-zA-Z0-9_-]+)\s*\.\s*([a-zA-Z0-9_.-]+)", r"\1.\2", c)
        c = re.sub(r"(https?://[a-zA-Z0-9_.-]+)\s*\.\s*([a-zA-Z0-9_.-]+)", r"\1.\2", c)
        c = re.sub(r"\bcurl\s+(.*?)\s*-o\s+([a-zA-Z0-9_.-]+/)\s*", r"curl \1 -O --output-dir \2 ", c)
        _ws_re = re.compile(r"(?:/home/[^/\s]+|/Users/[^/\s]+|~|\$HOME|\.?/?home/[^/\s]+)/blue[ _-][a-zA-Z0-9_-]+(/\.sandboxes/[A-Za-z0-9_.-]+)?")
        def _rebase(m):
            return m.group(0) if m.group(1) else ws
        c = _ws_re.sub(_rebase, c)
        c = re.sub(r"(/\.sandboxes/[A-Za-z0-9_.-]+)(?:\1)+", r"\1", c)
        d["command"] = c
    if "path" in d and isinstance(d["path"], str):
        p = re.split(r"(\s+2?>|\s+\||\s+;)", d["path"].split("\n")[0].strip())[0].strip()
        _ws_re_path = re.compile(r"^(?:/home/[^/\s]+|/Users/[^/\s]+|~|\$HOME|\.?/?home/[^/\s]+)/blue[ _-][a-zA-Z0-9_-]+(/\.sandboxes/[A-Za-z0-9_.-]+)?")
        m0 = _ws_re_path.match(p)
        if m0 and not m0.group(1):
            p = ws + p[m0.end():]
        p = re.sub(r"(/\.sandboxes/[A-Za-z0-9_.-]+)(?:\1)+", r"\1", p)
        d["path"] = "/" + p if re.match(r"^home/[^/]+/", p) else p
    return json.dumps(d) if d else raw

try:
    calls = json.load(sys.stdin)
    if isinstance(calls, list):
        for c in calls:
            fn = c.get("function", {})
            fn["arguments"] = clean_arg(fn.get("arguments", ""))
            # Semantic Thought-vs-Call Collapse Guard:
            # If the model explicitly reasoned it was calling tool_search, but grammar collapsed to search
            if reasoning and re.search(r"\b(?:calling|call|use|using|mount)\s+tool_search\b", reasoning, re.I):
                if fn.get("name") in ["web_search", "web_search_cross_section", "research_sandbox"]:
                    fn["name"] = "tool_search"
        print(json.dumps(calls))
    else: print("[]")
except Exception: print("[]")
' "${2:-}" <<< "$1" 2>/dev/null || echo "$1"
}

# ── Main ReAct Runner ────────────────────────────────────────────────
# Close the run ledger entry for the current react_run (called from the RETURN
# trap, so it sees react_run's locals via dynamic scope). Idempotent.
_react_ledger_close() {
    [ "${_rl_started:-0}" = "1" ] || return 0
    [ -n "${session_id:-}" ] || return 0
    _rl_started=0
    local _reply_src="" _has_reply="no" _mstatus="" _oc="${_rl_outcome:-}" _why="${_rl_reason:-}"
    if [ -n "${session_dir:-}" ] && [ -s "$session_dir/final_reply.txt" ]; then
        _reply_src="$session_dir/final_reply.txt"; _has_reply="yes"
    fi
    [ -n "${macro_file:-}" ] && [ -f "$macro_file" ] && _mstatus=$(jq -r '.status // ""' "$macro_file" 2>/dev/null)
    if [ -z "$_oc" ]; then
        _oc=$(run_ledger_infer_outcome 0 "$_mstatus" "$_has_reply")
        if [ "$_mstatus" = "CIRCUIT_BREAKER_TRIPPED" ] && [ -n "${_rl_last_breaker:-}" ]; then
            _oc=$(run_ledger_classify_breaker "$_rl_last_breaker"); _why="${_why:-$_rl_last_breaker}"
        fi
    fi
    declare -f run_ledger_finish &>/dev/null || return 0
    run_ledger_finish "$session_id" "$_oc" "$_why" "$_reply_src" "${turn:-0}" \
        "${_rl_tool_calls:-0}" "${_rl_tool_fails:-0}" "${_rl_breaker_trips:-0}" >/dev/null 2>&1 || true
}

# ── Adaptive Two-Phase Tool Execution & Observation Ingress ──────────
_react_postprocess_observation() {
    local c_id="$1"
    local c_name="$2"
    local c_args="$3"
    local tool_resp="$4"
    local await_ec="${5:-0}"
    local _react_t_dur="${6:-0}"
    local from_cache="${7:-0}"
    local turn_max_chars="${8:-32000}"
    local num_turn_calls="${9:-1}"

    if ! echo "$tool_resp" | jq -e 'type == "object"' >/dev/null 2>&1; then
        local ext=$(echo "$tool_resp" | sed -n '/^{/,$p' | jq -c 'select(type == "object")' 2>/dev/null | tail -n 1 || true)
        [ -n "$ext" ] && tool_resp="$ext" || tool_resp=$(jq -nc --arg id "$c_id" --arg name "$c_name" --arg content "$tool_resp" '{role: "tool", tool_call_id: $id, name: $name, content: $content}')
    fi

    # P2.3: normalise into the tool-result envelope (exit code + strong signals only)
    local _env_exit _env_pref _env_json="" _env_cls=""
    _env_exit=$(jq -r '.exit_code // empty' <<<"$tool_resp" 2>/dev/null)
    _env_pref=$(jq -r '.payload_ref // empty' <<<"$tool_resp" 2>/dev/null)
    [ -z "$_env_exit" ] && _env_exit="${await_ec:-0}"
    [ "$from_cache" -eq 1 ] && _env_exit=0
    [ "${await_ec:-0}" -eq 124 ] 2>/dev/null && _env_exit=124
    tool_resp=$(jq -c 'del(.exit_code, .duration_ms, .payload_ref)' <<<"$tool_resp" 2>/dev/null || echo "$tool_resp")
    local resp_content=$(echo "$tool_resp" | jq -r '.content // empty')
    if declare -f react_envelope_build &>/dev/null; then
        _env_json=$(react_envelope_build "$c_name" "$_env_exit" "$_react_t_dur" "$resp_content" ${_env_pref:+"$_env_pref"})
        if [ -n "${_sc_cls:-}" ]; then
            _env_json=$(jq -c --arg c "$_sc_cls" '.ok = false | .error_class = $c' <<<"$_env_json")
        fi
        resp_content=$(jq -r '.data // ""' <<<"$_env_json")
        _env_cls=$(jq -r '.error_class // empty' <<<"$_env_json")
    fi

    # Archive raw, un-truncated observation to disk
    mkdir -p "$session_dir/observations" 2>/dev/null || true
    local _c_file_id="${c_id#call_}"
    local _obs_archive="$session_dir/observations/call_${_c_file_id}.txt"
    printf '%s\n' "$resp_content" > "$_obs_archive" 2>/dev/null || true

    # Dynamic turn-budget partitioning
    local max_chars="$turn_max_chars"
    local _obs_hard_max=$(( ${ACTIVE_ENDPOINT_CONTEXT:-131072} / 8 * 4 ))
    [ "$max_chars" -gt "$_obs_hard_max" ] 2>/dev/null && max_chars="$_obs_hard_max"
    if [ "${#resp_content}" -gt "$max_chars" ]; then
        if [ "$num_turn_calls" -gt 1 ]; then
            resp_content="${resp_content:0:$max_chars}"$'\n\n[Observation truncated at '"${max_chars}"' characters for turn-budget partitioning. Full output available at '"$_obs_archive"']'
        else
            resp_content="${resp_content:0:$max_chars}"$'\n\n[Observation truncated at '"${max_chars}"' characters to protect context budget. Narrow your query, paginate with start_line, or use targeted grep/symbol tools.]'
        fi
    fi
    [ -n "${_env_json:-}" ] && printf '%s\n' "$_env_json" > "$session_dir/observations/call_${_c_file_id}.envelope.json" 2>/dev/null || true
    [ -n "${history_file:-}" ] && echo "Observation: $resp_content" >> "$history_file"

    local is_tool_failure=0
    if [ -n "$_env_json" ]; then
        [ -n "$_env_cls" ] && is_tool_failure=1
    else
        [ "${_env_exit:-0}" -ne 0 ] 2>/dev/null && is_tool_failure=1
    fi
    if [ "$is_tool_failure" -eq 1 ] && declare -f react_envelope_failed_attempt_note &>/dev/null; then
        react_envelope_failed_attempt_note "$session_dir" "$c_name" "$c_args" "${_env_cls:-CRASH}"
        if [ -z "${_sc_cls:-}" ] && [[ "$c_name" =~ (fetch|scrape|browse|web_read) ]]; then
            local _fd_url; _fd_url=$(jq -r '.url // .link // .uri // empty' <<<"$c_args" 2>/dev/null)
            react_envelope_failed_domain_record "$session_dir" "$(react_envelope_url_domain "$_fd_url")" "${_env_cls:-CRASH}"
        fi
    fi
    _rl_tool_calls=$(( ${_rl_tool_calls:-0} + 1 )); [ "$is_tool_failure" -eq 1 ] && _rl_tool_fails=$(( ${_rl_tool_fails:-0} + 1 ))

    # Visual observation card in terminal
    local _dur_str=""
    [ "$_react_t_dur" -gt 0 ] && _dur_str=" in ${_react_t_dur}ms"
    if [ "$is_tool_failure" -eq 1 ]; then
        ui_warn "Observation from $c_name finished${_dur_str} (${#resp_content} chars, status: alert/error)"
    else
        ui_ok "Observation received from $c_name${_dur_str} (${#resp_content} chars)"
    fi

    # Log collapsible card to transcript
    if declare -f transcript_log_tool_call &>/dev/null; then
        transcript_log_tool_call "$c_name" "$c_id" "$c_args" "$resp_content" "${await_ec:-0}" "$_react_t_dur" "${#resp_content}"
    else
        declare -f transcript_log_block &>/dev/null && transcript_log_block "observation ($c_name)" "$resp_content"
    fi
    _react_trace "$workdir" "tool_call" "$(jq -cn --arg tool "$c_name" --arg args "$c_args" --argjson cached "$([ "$from_cache" -eq 1 ] && echo "true" || echo "false")" '{tool:$tool, args:$args, cached:$cached}')"

    if [ "$from_cache" -eq 0 ] && [ "$is_tool_failure" -eq 0 ] && _react_tool_is_cacheable "$c_name"; then
        local cache_key=$(_react_tool_cache_key "$c_name" "$c_args")
        local cache_ns=$(_react_tool_cache_ns "$c_name")
        declare -f cache_put &>/dev/null && cache_put "$cache_key" "$cache_ns" "$resp_content"
    fi
    if _react_tool_is_mutating "$c_name" "$c_args"; then
        declare -f cache_invalidate_ns &>/dev/null && cache_invalidate_ns "files"
        declare -f cache_invalidate_ns &>/dev/null && cache_invalidate_ns "git"
    fi

    local tool_digest="" eval_verdict="IN_PROGRESS" eval_reason="" eval_guidance=""
    if [ "$is_tool_failure" -eq 0 ]; then
        tool_digest=$(_react_digest_tool_output "$c_id" "$c_name" "$c_args" "$resp_content" "${current_hd_step:-}" "$session_dir" "${workdir:-.}" "${goal:-}")

        local should_evaluate=0
        if [ "${_REACT_SKIP_BATCH_EVAL:-0}" -eq 1 ]; then
            should_evaluate=0
        elif [ "$c_name" = "discord_send" ] && { { [ "${_discord_nudge_turn:-0}" -eq "${turn:-0}" ] && [ "${turn:-0}" -gt 0 ]; } || ! echo "${current_hd_step:-}" | grep -qiE '\b(discord|deliver|send|post|notify|channel|reply|respond)\b'; }; then
            should_evaluate=0
        elif _react_tool_is_mutating "$c_name" "$c_args"; then
            should_evaluate=1
        elif [ "${turn:-1}" -ge $(( ${max_turns:-10} - 3 )) ]; then
            should_evaluate=1
        elif [ "${thrashing_target_streak:-0}" -ge 1 ]; then
            should_evaluate=1
        elif [ $(( ${turn:-1} % 5 )) -eq 0 ]; then
            should_evaluate=1
        fi

        local eval_out=$(_react_eval_milestone_evidence "${workdir:-.}" "$session_dir" "${current_hd_id:-}" "${current_hd_step:-}" "${goal:-}" "$tool_digest" "$should_evaluate")
        if [ -n "$eval_out" ]; then
            eval_verdict="${eval_out%%|*}"; local rem="${eval_out#*|}"; eval_reason="${rem%%|*}"; eval_guidance="${rem#*|}"
        fi
        if declare -f react_advise &>/dev/null && [ "$should_evaluate" -eq 1 ] && [ -n "${current_hd_id:-}" ] && \
           { [ "$eval_verdict" = "BLOCKED" ] || { [ "$eval_verdict" = "IN_PROGRESS" ] && [ "$(react_eval_incomplete_count "$session_dir" "$current_hd_id")" -ge 2 ]; }; }; then
            local _ev_adv=""
            if _ev_adv=$(react_advise "$session_dir" "$current_hd_id" "${current_hd_step:-}" "${goal:-}" "EVALUATOR_${eval_verdict}: ${eval_reason}" "$(jq -r '[.[].function.name] | join(",")' <<<"${turn_tools_schema:-[]}" 2>/dev/null)"); then
                _react_steer "$(react_advise_render "$_ev_adv")" "$messages_file"
                if [ "$(jq -r '.abandon_step // false' <<<"$_ev_adv")" = "true" ] && [ -f "${hd_file:-}" ]; then
                    jq --argjson pid "$current_hd_id" '(.items[] | select(.id == $pid)) |= (.status = "done" | .abandoned = true)' "$hd_file" > "${hd_file}.tmp" 2>/dev/null && mv "${hd_file}.tmp" "$hd_file"
                    eval_verdict="SATISFIED"; eval_reason="Step abandoned on advisor recommendation: $(jq -r '.diagnosis' <<<"$_ev_adv")"
                fi
            fi
        fi
        declare -f telemetry_task_heartbeat &>/dev/null && telemetry_task_heartbeat "${session_id:-default}" "${turn:-1}" "$c_name" "${max_turns:-1}"
        declare -f agent_sm_heartbeat &>/dev/null && agent_sm_heartbeat "${session_id:-default}"

        local prev_hd_id="${current_hd_id:-}"
        if [ "$eval_verdict" != "SATISFIED" ]; then
            _react_advance_honeydew_plan "${workdir:-.}" "$c_name" "$c_args" "$resp_content"
        fi
        # Tier B proposed plan fast-path: if crypto_plan / crypto_standing_order produced a proposed plan
        # (or crypto_execute returned needs_confirmation), mark any pending execution/verification milestones
        # as done so George immediately presents the plan ID to the operator without wasting the 10-min TTL.
        local _tier_b_note=""
        if [[ "$c_name" =~ ^(crypto_plan|crypto_standing_order|crypto_execute)$ ]] && echo "$resp_content" | grep -qE '"status":[[:space:]]*"(proposed|needs_confirmation)"'; then
            if [ -f "${hd_file:-}" ]; then
                jq '(.items[]? | select(.status != "done" and ((.task | test("^(Step [0-9]+: )?(synthesize|deliver to operator|respond to operator|conclude|present)\\b"; "i")) | not))).status = "done"' "$hd_file" > "${hd_file}.tmp" 2>/dev/null && mv "${hd_file}.tmp" "$hd_file"
            fi
            _tier_b_note=$'\n\n[TIER B PLAN PROPOSED — AWAITING OPERATOR CONFIRMATION: Once all requested plans are built, stop calling tools and present the plan_id(s) and trade details directly to the operator so they can reply '\''confirm <plan_id>'\'' within the 10-minute window. Do NOT call crypto_execute on an unconfirmed Tier B plan.]'
        fi
        local eval_note=""
        if [ -f "${hd_file:-}" ]; then
            local updated_hd_id updated_hd_step
            updated_hd_id=$(jq -r '[.items[]? | select(.status != "done")][0].id // 1' "$hd_file" 2>/dev/null || echo 1)
            updated_hd_step=$(jq -r '[.items[]? | select(.status != "done")][0] | if . then "Step " + (.id|tostring) + ": " + .task else "Synthesize Final Deliverable" end' "$hd_file" 2>/dev/null)
            if [ "$eval_verdict" = "SATISFIED" ] || [ "$updated_hd_id" != "$prev_hd_id" ] || [ -n "$_tier_b_note" ]; then
                current_hd_id="$updated_hd_id"
                current_hd_step="$updated_hd_step"
                export CURRENT_ACTIVE_MILESTONE_ID="$current_hd_id"
                local reason_adv="${eval_reason:-Milestone requirements met.}"
                [ "$eval_verdict" != "SATISFIED" ] && reason_adv="Milestone action verified."
                eval_note=$'

[MILESTONE ADVANCEMENT: SATISFIED] '"${reason_adv} Current Active: ${current_hd_step}${_tier_b_note}"
            fi
        elif [ -n "$_tier_b_note" ]; then
            eval_note="$_tier_b_note"
        fi

        local curated_obs=""
        if [[ "$c_name" =~ ^(file_read|file_edit|file_write|file_grep|file_diff|git_diff|dir_list|file_list|phytology_inspect)$ ]] || ! declare -f react_envelope_condense &>/dev/null; then
            curated_obs="${resp_content}${eval_note}"
        else
            curated_obs="$(react_envelope_condense "$resp_content" "${REACT_OBS_INLINE_CHARS:-6000}" "$_obs_archive")${eval_note}"
        fi
        tool_resp=$(echo "$tool_resp" | jq --arg c "$curated_obs" '.content = $c')
    else
        local fail_card=""
        if [ -n "$_env_json" ] && declare -f react_envelope_render &>/dev/null; then
            fail_card=$(react_envelope_render "$_env_json")
        else
            fail_card="[TOOL FAILED: ${c_name}]
${resp_content:0:300}"
        fi
        tool_resp=$(echo "$tool_resp" | jq --arg c "$fail_card" '.content = $c')
    fi

    jq --argjson tr "$tool_resp" '. += [$tr]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
    declare -f fifo_write_frame &>/dev/null && [ -n "$session_id" ] && fifo_write_frame "$session_id" "$(jq -nc --arg tool "$c_name" --arg v "${eval_verdict:-FAILURE}" '{event: "tool_digest", tool: $tool, verdict: $v}')" 2 2>/dev/null || true

    if [ "$is_tool_failure" -eq 1 ]; then
        thrashing_target_streak=$(( ${thrashing_target_streak:-0} + 1 ))
        local fail_cls=$(_react_classify_circuit_state "$c_name" "$c_args" "$resp_content" "${tool_search_streak:-0}" "$thrashing_target_streak" 0)
        declare -f telemetry_record_anomaly &>/dev/null && telemetry_record_anomaly "${session_id:-default}" "CAPABILITY_DEFICIT" "$c_name" "Failure on $c_name (Strike $thrashing_target_streak, Class $fail_cls): ${resp_content:0:200}" >/dev/null 2>&1 || true

        # For REPUTATION_CAPABILITY_DEFICIT, perturb IMMEDIATELY on strike 1 to halt thrashing
        if [ "$fail_cls" = "REPUTATION_CAPABILITY_DEFICIT" ] || [ "$thrashing_target_streak" -ge 2 ]; then
            _react_circuit_breaker_perturbation "${session_id:-default}" "${workdir:-.}" "$fail_cls" "$c_name ($c_args)" "${resp_content:0:300}" "$messages_file" "$macro_file"
        fi
        if [ "$thrashing_target_streak" -ge 4 ]; then
            ui_err "Hard capability ceiling reached: 4 consecutive unyielding tool failures ($c_name). Tripping breaker and preserving incident."
            _react_trip_circuit_breaker "${session_id:-default}" "${workdir:-.}" "Persistent tool failure on $c_name reached strike ceiling" "$c_name ($c_args)" "$messages_file" "$macro_file" "${resp_content:0:500}"
            export AGENT_ACTIVE_SESSION_ID=""
            jq '.status = "CAPABILITY_EXHAUSTED"' "$macro_file" > "${macro_file}.tmp" 2>/dev/null && mv "${macro_file}.tmp" "$macro_file" 2>/dev/null || true
            tool_exhausted=1
        fi
    else
        thrashing_target_streak=0
        declare -f telemetry_reset_consecutive_failures &>/dev/null && telemetry_reset_consecutive_failures "$session_id" >/dev/null 2>&1 || true
    fi

    jq --arg ts "$(date '+%Y-%m-%d %H:%M:%S')" --arg tool "$c_name" --arg sum "${resp_content:0:200}" '.completed_milestones += [{"timestamp": $ts, "tool": $tool, "summary": $sum}]' "$macro_file" > "${macro_file}.tmp" 2>/dev/null && mv "${macro_file}.tmp" "$macro_file" 2>/dev/null || true
    printf "${C_DIM}  ↳ Digest: %s${C_RESET}\n" "$(echo "${tool_digest:-$resp_content}" | head -n 3 | tr '\n' ' ')"
    [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf "   ${C_BOLD}${C_GRAY}[DEBUG: Observation (${#resp_content} chars)]${C_RESET}\n%s\n" "${resp_content:0:1500}"
    declare -f transcript_log_jsonl &>/dev/null && transcript_log_jsonl "${goal:-}" "${reasoning:-${think_content:-}}" "${c_name:-tool}(${c_args:-})" "$resp_content"
}

_react_execute_single_tool_step() {
    local call="$1"
    local turn_max_chars="${2:-32000}"
    local num_turn_calls="${3:-1}"

    local c_id=$(echo "$call" | jq -r '.id')
    local c_name=$(echo "$call" | jq -r '.function.name')
    local c_args=$(echo "$call" | jq -r '.function.arguments')

    if [ "$c_name" = "$last_invoked_tool" ]; then same_tool_streak=$((same_tool_streak + 1))
    else same_tool_streak=1; last_invoked_tool="$c_name"
    fi

    if [ "$c_name" = "tool_search" ]; then
        tool_search_streak=$((tool_search_streak + 1))
        if [ "$tool_search_streak" -ge 2 ]; then
            ui_warn "[CIRCUIT BREAKER] Tool search thrashing detected (Streak: $tool_search_streak). Triggering Prompt Perturbation Hook."
            _react_circuit_breaker_perturbation "$session_id" "$workdir" "TOOL_SEARCH_THRASHING" "tool_search ($c_args)" "Repeated tool_search invocations without forward progress" "$messages_file" "$macro_file"
        fi
    elif [ "$c_name" = "bash_exec" ]; then
        tool_search_streak=0
    else
        tool_search_streak=0
        local max_tool_streak=$(declare -f limits_get &>/dev/null && limits_get CIRCUIT_BREAKER_MAX_TOOL_STREAK 8 || echo "${CIRCUIT_BREAKER_MAX_TOOL_STREAK:-8}")
        local tool_streak_adv_threshold=$(( max_tool_streak - 2 ))
        [ "$tool_streak_adv_threshold" -lt 4 ] && tool_streak_adv_threshold=4
        if [ "$same_tool_streak" -ge "$max_tool_streak" ]; then
            ui_warn "[CIRCUIT BREAKER] Tool invocation streak ceiling reached on $c_name (Streak: $same_tool_streak). Triggering Prompt Perturbation Hook."
            _react_circuit_breaker_perturbation "$session_id" "$workdir" "TOOL_THRASHING" "$c_name ($c_args)" "Repeated invocations of $c_name without advancing the task" "$messages_file" "$macro_file"
        elif [ "$same_tool_streak" -ge "$tool_streak_adv_threshold" ]; then
            local tool_streak_adv="[CIRCUIT ADVISORY: Tool '$c_name' has been invoked ${same_tool_streak} times consecutively. If previous results were insufficient or empty, cease repeating this tool. Select an alternative tool or synthesize your findings to advance.]"
            _react_steer "$tool_streak_adv" "$messages_file"
        fi
    fi

    local a_hash=$(_react_action_hash "$c_name" "$c_args")
    local rep_strike=$(_react_check_repetition "$session_dir" "$a_hash" "$c_name" "$c_args")
    if [ "$rep_strike" -ge 3 ]; then
        local heal_ec=0
        _react_self_heal_circuit_breaker "$session_id" "$workdir" "$session_dir" "$c_name" "$c_args" "$messages_file" "$macro_file" "$rep_strike"; heal_ec=$?
        [ "$heal_ec" -ne 0 ] && { export AGENT_ACTIVE_SESSION_ID=""; return "$heal_ec"; }
    elif [ "$rep_strike" -eq 1 ]; then
        local rep_adv="[CIRCUIT ADVISORY: Action '$c_name' was already executed. Repeating identical actions or oscillating cycles without parameter changes is strictly prohibited. Modify your parameters or select an alternative tool.]"
        jq --arg a "$rep_adv" '. += [{"role": "user", "content": $a}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
    elif [ "$rep_strike" -eq 2 ]; then
        _react_circuit_breaker_perturbation "$session_id" "$workdir" "ACTION_REPETITION" "$c_name ($c_args)" "Action repetition strike 2" "$messages_file" "$macro_file"
    fi

    local target_path=""
    [[ "$c_name" =~ file_read|file_grep|file_outline|code_symbol_get|file_edit|file_write ]] && target_path=$(echo "$c_args" | jq -r '.path // empty' 2>/dev/null)
    if [ -n "$target_path" ]; then
        if [ "$target_path" = "$last_inspected_path" ]; then same_target_path_streak=$((same_target_path_streak + 1))
        else same_target_path_streak=1; last_inspected_path="$target_path"
        fi
        local max_path_streak=$(declare -f limits_get &>/dev/null && limits_get CIRCUIT_BREAKER_MAX_PATH_STREAK 7 || echo "${CIRCUIT_BREAKER_MAX_PATH_STREAK:-7}")
        local path_streak_adv_threshold=$(( max_path_streak - 2 ))
        [ "$path_streak_adv_threshold" -lt 3 ] && path_streak_adv_threshold=3
        if [ "$same_target_path_streak" -ge "$max_path_streak" ]; then
            ui_warn "[CIRCUIT BREAKER] Target path repetition ceiling reached on $target_path (Streak: $same_target_path_streak). Tripping circuit breaker / perturbation."
            _react_circuit_breaker_perturbation "$session_id" "$workdir" "TARGET_FILE_THRASHING" "$c_name ($target_path)" "Repeated file inspection on $target_path without task advancement" "$messages_file" "$macro_file"
        elif [ "$same_target_path_streak" -ge "$path_streak_adv_threshold" ]; then
            local path_adv="[CIRCUIT ADVISORY: Target file '$target_path' has been inspected multiple times in a row. Cease linear paging or repeated inspection of this file. Synthesize your findings or call the domain-specific tool required by the active Honeydew milestone.]"
            _react_steer "$path_adv" "$messages_file"
        fi
    else same_target_path_streak=0; last_inspected_path=""
    fi

    local _sc_cls="" _sc_domain=""
    if [[ "$c_name" =~ (fetch|scrape|browse|web_read) ]] && declare -f react_envelope_failed_domain_check &>/dev/null; then
        local _sc_url; _sc_url=$(jq -r '.url // .link // .uri // empty' <<<"$c_args" 2>/dev/null)
        _sc_domain=$(react_envelope_url_domain "$_sc_url")
        [ -n "$_sc_domain" ] && _sc_cls=$(react_envelope_failed_domain_check "$session_dir" "$_sc_domain")
        [ -n "$_sc_cls" ] && ui_warn "Skipping $c_name: $_sc_domain already failed this session ($_sc_cls)"
    fi

    ui_step "Native Tool Call: $c_name"
    [ -n "${history_file:-}" ] && echo "Tool Call: $c_name ($c_args)" >> "$history_file"
    declare -f transcript_log &>/dev/null && transcript_log "tool_call" "$c_name: $c_args"
    [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf "   ${C_BOLD}${C_BLUE}[DEBUG: Tool Args]${C_RESET} %s\n" "$c_args"

    local tool_resp="" from_cache=0 cache_key="" cache_ns=""
    local _react_t_dur=0 await_ec=0
    if [ -n "$_sc_cls" ]; then
        from_cache=2
        tool_resp=$(jq -nc --arg id "$c_id" --arg name "$c_name" --arg d "$_sc_domain" --arg c "$_sc_cls" \
            '{role: "tool", tool_call_id: $id, name: $name, exit_code: 1,
              content: ("ERROR: request skipped — " + $d + " already failed this session (" + $c + "). Choose a different source.")}')
    fi

    if [ "$from_cache" -eq 0 ] && { [ "${REACT_STRICT_TOOLS:-0}" = "1" ] || [ "${tool_filter:-}" = "model_hub" ] || [ "${tool_filter:-}" = "social_untrusted" ] || [ "${tool_filter:-}" = "untrusted_social" ]; }; then
        if ! jq -e --arg n "$c_name" 'any(.[]?; .function.name == $n)' <<<"${tools_schema:-[]}" >/dev/null 2>&1; then
            from_cache=2
            local _rep_err=""
            if [ "${tool_filter:-}" = "social_untrusted" ] || [ "${tool_filter:-}" = "untrusted_social" ] || [ -n "${DISCORD_CURRENT_AUTHOR_REP:-}" ]; then
                local _auth_name="${DISCORD_CURRENT_AUTHOR_NAME:-user}"
                local _auth_rep="${DISCORD_CURRENT_AUTHOR_REP:-unknown}"
                local _min_rep="${DISCORD_OPS_MIN_REPUTATION:-50}"
                _rep_err="ERROR: Tool '${c_name}' is restricted by system policy. Author @${_auth_name} has Reputation Score ${_auth_rep} (< ${_min_rep} required for host execution). You must not retry this tool. Please inform @${_auth_name} that their reputation level restricts access to '${c_name}' and provide a conversational response or summarize what information you can retrieve."
            else
                _rep_err="ERROR: tool ${c_name} is not available in this profile. Use only the tools you were given."
            fi
            tool_resp=$(jq -nc --arg id "$c_id" --arg name "$c_name" --arg content "$_rep_err" \
                '{role: "tool", tool_call_id: $id, name: $name, exit_code: 1, content: $content}')
        fi
    fi

    if [ "$from_cache" -eq 0 ] && _react_tool_is_cacheable "$c_name"; then
        cache_ns=$(_react_tool_cache_ns "$c_name"); cache_key="tool:${c_name}:${a_hash}"
        local cached_val=""
        if declare -f cache_get &>/dev/null && cached_val=$(cache_get "$cache_key" "$cache_ns" 2>/dev/null); then
            from_cache=1; ui_step "Native Tool Call: $c_name [LRU CACHE HIT (~0ms)]"
            tool_resp=$(jq -nc --arg id "$c_id" --arg name "$c_name" --arg content "$cached_val" '{role: "tool", tool_call_id: $id, name: $name, content: ("[CACHED OBSERVATION (0ms)]\n" + $content)}')
        fi
    fi

    if [ "$from_cache" -eq 0 ]; then
        local _t_start_ms
        _t_start_ms=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
        local as_timeout=$(declare -f limits_get &>/dev/null && limits_get ASYNC_TOOL_WATCHDOG_TIMEOUT 120 || echo 120)
        if [[ "$c_name" =~ ^(vision_analyze|reverse_image_search|research_sandbox)$ ]]; then
            as_timeout="${ASYNC_VISION_WATCHDOG_TIMEOUT:-240}"
        fi
        local await_ec=0
        declare -f telemetry_task_heartbeat &>/dev/null && telemetry_task_heartbeat "${session_id:-default}" "${turn:-1}" "$c_name" "${max_turns:-1}"
        declare -f agent_sm_heartbeat &>/dev/null && agent_sm_heartbeat "${session_id:-default}"
        if declare -f fifo_async &>/dev/null && declare -f fifo_await &>/dev/null; then
            local call_cid="${session_id}_tc_${c_id//[^A-Za-z0-9_.-]/_}"
            local _q_cid _q_sid _q_id _q_name _q_args _q_wd
            printf -v _q_cid '%q' "$call_cid"; printf -v _q_sid '%q' "$session_id"
            printf -v _q_id '%q' "$c_id"; printf -v _q_name '%q' "$c_name"
            printf -v _q_args '%q' "$c_args"; printf -v _q_wd '%q' "$workdir"
            local prom_id=$(fifo_async "$call_cid" "export IPC_CHANNEL=$_q_cid; export AGENT_ACTIVE_TASK_ID=$_q_sid; native_tools_dispatch $_q_id $_q_name $_q_args $_q_wd" "$c_id" "$c_name" "$c_args")
            tool_resp=$(fifo_await "$prom_id" "$as_timeout" 2>/dev/null)
            await_ec=$?
            rm -f "${FIFO_IPC_DIR:-${gdir}/ipc}/promises/${prom_id}"* 2>/dev/null || true
            if [ "$await_ec" -eq 124 ]; then
                tool_resp=$(jq -nc --arg id "$c_id" --arg name "$c_name" --arg timeout "$as_timeout" '{role: "tool", tool_call_id: $id, name: $name, exit_code: 124, content: ("ERROR: Tool execution timed out after " + $timeout + "s")}')
            elif [ "$await_ec" -ne 0 ] && [ -z "$tool_resp" ]; then
                tool_resp=$(jq -nc --arg id "$c_id" --arg name "$c_name" --arg ec "$await_ec" '{role: "tool", tool_call_id: $id, name: $name, exit_code: ($ec|tonumber), content: ("ERROR: Tool execution crashed or terminated prematurely (exit code: " + $ec + ")")}')
            fi
        else
            tool_resp=$(native_tools_dispatch "$c_id" "$c_name" "$c_args" "$workdir")
            await_ec=$?
        fi
        declare -f telemetry_task_heartbeat &>/dev/null && telemetry_task_heartbeat "${session_id:-default}" "${turn:-1}" "$c_name" "${max_turns:-1}"
        declare -f agent_sm_heartbeat &>/dev/null && agent_sm_heartbeat "${session_id:-default}"
        local _t_end_ms
        _t_end_ms=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
        _react_t_dur=$(( _t_end_ms - _t_start_ms ))
        [ "$_react_t_dur" -lt 0 ] 2>/dev/null && _react_t_dur=0
    fi

    _react_postprocess_observation "$c_id" "$c_name" "$c_args" "$tool_resp" "$await_ec" "$_react_t_dur" "$from_cache" "$turn_max_chars" "$num_turn_calls"
}

react_run() {
    export _LODGE_IN_TASK=1
    _react_session_cleanup() {
        _react_ledger_close
        export _LODGE_IN_TASK=0
        stty sane 2>/dev/null || true
        [ -n "${_prev_transcript_file:-}" ] && export _TRANSCRIPT_FILE="$_prev_transcript_file"
        declare -f ipc_release_inference_lease &>/dev/null && ipc_release_inference_lease "${session_id:-task_$$}" 2>/dev/null || true
        declare -f ipc_channel_close &>/dev/null && ipc_channel_close "${session_id:-}" 2>/dev/null || true
        _react_heartbeat_ticker_stop "${session_dir:-}"
        if [ -n "${session_dir:-}" ] && [ -d "$session_dir" ]; then
            [ ! -f "$session_dir/.done" ] && touch "$session_dir/.done" 2>/dev/null || true
            if [ -f "$session_dir/.phase" ] && ! grep -qiE 'complete|done|halt|abort|fail' "$session_dir/.phase" 2>/dev/null; then
                echo "Completed" > "$session_dir/.phase" 2>/dev/null || true
            fi
        fi
        if [ -n "${session_id:-}" ] && [ -f "${GEORGE_DIR:-$LODGE_DIR/.george}/subagents.json" ]; then
            local _sub_reg="${GEORGE_DIR:-$LODGE_DIR/.george}/subagents.json"
            local _tmp_sub="${_sub_reg}.tmp.$$"
            jq --arg id "$session_id" \
               'map(if .id == $id and .status == "RUNNING" then .status = "COMPLETED" | .updated_at = (now | todate) else . end)' \
               "$_sub_reg" > "$_tmp_sub" 2>/dev/null && mv "$_tmp_sub" "$_sub_reg"
        fi
    }
    trap '_react_session_cleanup' RETURN 2>/dev/null || true
    trap '_react_session_cleanup' INT TERM HUP 2>/dev/null || true
    local goal="$1" workdir="${2:-$PWD}" max_turns="${3:-${AGENT_MAX_TURNS:-${AGENT_MAX_MILESTONES:-200}}}"
    local agent_temp="${AGENT_LLM_TEMPERATURE:-1.0}" tool_filter="${6:-${REACT_TOOL_FILTER:-}}" mode="${8:-${AGENT_MODE:-standard}}"

    # Determine FIFO inference priority
    local _task_priority="${IPC_PRIO_CRON:-50}"
    if [ "${_DISCORD_IN_SESSION:-0}" = "1" ] || [ -t 0 ] || [ -f "${GEORGE_DIR:-$LODGE_DIR/.george}/interactive.lock" ]; then
        _task_priority="${IPC_PRIO_INTERACTIVE:-100}"
    elif [ "${AGENT_SOVEREIGN_REMEDIATION:-0}" = "1" ]; then
        _task_priority="${IPC_PRIO_REMEDIATION:-20}"
    elif [[ "${tool_filter:-}" =~ trade|market ]] || [ "${AGENT_MODE:-}" = "trade" ]; then
        _task_priority="${IPC_PRIO_TRADE:-90}"
    fi

    if [ -n "${3:-}" ] && ! [[ "$3" =~ ^[0-9]+$ ]]; then
        tool_filter="$3"; max_turns="${AGENT_MAX_TURNS:-${AGENT_MAX_MILESTONES:-200}}"
    fi

    if [ -z "$tool_filter" ] || [ "$tool_filter" = "all" ] || [ "$tool_filter" = "auto" ]; then
        tool_filter=$(declare -f native_tools_classify_profile &>/dev/null && native_tools_classify_profile "$goal" || echo "default")
    fi
    [[ "$tool_filter" =~ ^(worker|sandbox_worker|worker_research)$ ]] && mode="worker"

    [ -z "$goal" ] && { ui_err "Task description required."; return 1; }
    if ! endpoints_cascade; then
        ui_err "No active inference endpoints available. Check endpoints.conf or start a backend."; return 1
    fi

    agent_temp="${AGENT_LLM_TEMPERATURE:-${ACTIVE_ENDPOINT_TEMPERATURE:-1.0}}"
    local agent_topp="${AGENT_LLM_TOP_P:-${ACTIVE_ENDPOINT_TOP_P:-0.95}}"
    local agent_max_tok="${AGENT_MAX_TOKENS:-${ACTIVE_ENDPOINT_MAX_TOKENS:-16384}}"
    local req_timeout="${LODGE_TIMEOUT:-${REACT_TIMEOUT:-${ACTIVE_ENDPOINT_TIMEOUT:-900}}}"

    ui_ok "Active Engine: Tier $ACTIVE_TIER [$ACTIVE_ENDPOINT_NAME] ($ACTIVE_ENDPOINT_MODEL @ $ACTIVE_ENDPOINT_URL)"
    ui_dim "Context Window: $ACTIVE_ENDPOINT_CONTEXT tokens | Compaction Threshold: $ACTIVE_ENDPOINT_COMPACT_TOKENS tokens"
    ui_dim "Task Profile: '$tool_filter'"

    local gdir="${workdir}/.george"
    mkdir -p "$gdir" "$gdir/transcripts" "$gdir/workspaces"
    if ! declare -f transcript_active &>/dev/null || ! transcript_active; then
        declare -f transcript_start &>/dev/null && transcript_start "$goal" "$workdir"
    else
        declare -f transcript_section &>/dev/null && transcript_section "Phase 1: Autonomous ReAct Investigation Loop"
    fi

    local session_id_arg="${REACT_SESSION_ID:-}"
    [ -z "$session_id_arg" ] && [ -n "${7:-}" ] && session_id_arg="$7"
    [ -z "$session_id_arg" ] && [ -n "${5:-}" ] && ! [[ "${5:-}" =~ ^[0-9]+$ ]] && session_id_arg="$5"

    local parent_task_id="${GEORGE_PARENT_TASK_ID:-}"
    local parent_pid="${GEORGE_PARENT_PID:-}"

    if [ -z "$parent_task_id" ]; then
        local candidate_parent="${AGENT_ACTIVE_SESSION_ID:-}"
        if [ -n "$candidate_parent" ] && [ "$candidate_parent" != "$session_id_arg" ]; then
            local p_pid_file="$gdir/workspaces/$candidate_parent/.pid"
            local p_pid=""
            [ -f "$p_pid_file" ] && p_pid=$(cat "$p_pid_file" 2>/dev/null || true)
            if [ -n "$p_pid" ] && [ "$p_pid" != "$$" ] && kill -0 "$p_pid" 2>/dev/null; then
                parent_task_id="$candidate_parent"
                parent_pid="$p_pid"
            elif [ -n "${_LODGE_PARENT_PID:-}" ] && [ "$_LODGE_PARENT_PID" != "$$" ]; then
                parent_task_id="$candidate_parent"
                parent_pid="$_LODGE_PARENT_PID"
            fi
        fi
    fi

    local session_id=""
    if [ -n "$parent_task_id" ]; then
        export GEORGE_PARENT_TASK_ID="$parent_task_id"
        export GEORGE_PARENT_PID="${parent_pid:-$PPID}"
        # If session_id_arg was inherited from parent or empty, generate a dedicated subtask session ID
        if [ -z "$session_id_arg" ] || [ "$session_id_arg" = "$parent_task_id" ]; then
            session_id="sub_${parent_task_id}_$$"
        else
            session_id="$session_id_arg"
        fi
    else
        session_id="${session_id_arg:-session_$(date +%Y%m%d_%H%M%S)_$$}"
    fi

    local session_dir="$gdir/workspaces/$session_id"
    local _discord_nudged=""
    mkdir -p "$session_dir"

    local macro_file="$session_dir/macro_memory.json"
    local hd_file="$session_dir/honeydew.json"
    [ -z "$parent_task_id" ] && [ ! -f "$gdir/macro_memory.json" ] && macro_file="$gdir/macro_memory.json"

    jq -n --arg ts "$(date '+%Y-%m-%d %H:%M:%S %Z')" --arg obj "$goal" --arg model "${ACTIVE_ENDPOINT_MODEL:-default}" --arg tier "${ACTIVE_TIER:-1}" \
        '{task_started: $ts, primary_objective: $obj, model: $model, tier: $tier, completed_milestones: [], status: "IN_PROGRESS"}' > "$macro_file" 2>/dev/null || true
    _react_trace "$workdir" "task_start" "$(jq -cn --arg goal "$goal" --arg tier "${ACTIVE_TIER:-1}" '{goal:$goal, tier:$tier}')"

    echo "${BASHPID:-$$}" > "$session_dir/.pid" 2>/dev/null || true
    echo "Running" > "$session_dir/.phase" 2>/dev/null || true
    local _meta_type="react"
    [[ "$session_id" == discord_* ]] && _meta_type="discord"
    [[ "$session_id" == cron_* ]] && _meta_type="cron"
    [[ "$session_id" == sub_* ]] && _meta_type="subtask"
    [[ "$session_id" == refine_* ]] && _meta_type="subtask"
    jq -n --arg cmd "$goal" --arg type "$_meta_type" --arg sid "$session_id" \
        --arg parent_id "${parent_task_id:-}" --argjson parent_pid "${parent_pid:-0}" \
        '{command: $cmd, type: $type, session_id: $sid, objective: $cmd, parent_task_id: (if $parent_id != "" then $parent_id else null end), parent_pid: (if $parent_pid > 0 then $parent_pid else null end)}' > "$session_dir/task_meta.json" 2>/dev/null || true

    # Run ledger (P1/1.7): $GEORGE_DIR/runs/<session_id>/run.json
    local _rl_started=0 _rl_outcome="" _rl_reason="" _rl_last_breaker="" _rl_tool_calls=0 _rl_tool_fails=0 _rl_breaker_trips=0
    if declare -f run_ledger_start &>/dev/null; then
        run_ledger_start "$session_id" "$goal" "$_meta_type" "${ACTIVE_TIER:-}" "${ACTIVE_ENDPOINT_MODEL:-}" "$session_dir" >/dev/null 2>&1 && _rl_started=1
    fi

    declare -f fifo_channel_open &>/dev/null && fifo_channel_open "$session_id" "${max_turns:-50}" 2>/dev/null || true
    declare -f agent_sm_register &>/dev/null && agent_sm_register "$session_id" "react_worker" "$goal" 2>/dev/null || true
    declare -f agent_sm_set_pid &>/dev/null && agent_sm_set_pid "$session_id" "${BASHPID:-$$}" 2>/dev/null || true
    declare -f agent_sm_transition &>/dev/null && agent_sm_transition "$session_id" "RUNNING" "Beginning ReAct loop" 2>/dev/null || true
    if [ -d "${LODGE_DIR}/.sandboxes/${session_id}" ]; then
        echo "${BASHPID:-$$}" > "${LODGE_DIR}/.sandboxes/${session_id}/.pid" 2>/dev/null || true
        echo "Running" > "${LODGE_DIR}/.sandboxes/${session_id}/.phase" 2>/dev/null || true
    fi
    declare -f cache_init &>/dev/null && cache_init

    local history_file="$session_dir/trajectory.log" messages_file="$session_dir/messages.json" memory_file="$session_dir/memory.md"
    : > "$history_file"
    : > "$session_dir/scratchpad.md"
    [ -z "$parent_task_id" ] && : > "$gdir/scratchpad.md"

    # Dedicated subtask transcript setup
    local _prev_transcript_file="${_TRANSCRIPT_FILE:-}"
    if [ -n "$parent_task_id" ] || [ "$_meta_type" = "subtask" ]; then
        local _sub_transcript_dir="${workdir}/.george/transcripts"
        mkdir -p "$_sub_transcript_dir"
        local _sub_transcript="${_sub_transcript_dir}/${session_id}.md"
        export _TRANSCRIPT_FILE="$_sub_transcript"
        {
            echo "# Subtask Transcript: $session_id"
            echo ""
            echo "**Task:** $goal"
            echo "**Started:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
            echo "**Parent Task:** ${parent_task_id:-none}"
            echo "**Directory:** $session_dir"
            echo "**Model:** ${ACTIVE_ENDPOINT_MODEL:-unknown}"
            echo "**Tier:** ${ACTIVE_TIER:-1}"
            echo ""
            echo "---"
            echo ""
        } > "$_TRANSCRIPT_FILE" 2>/dev/null || true
    fi

    export AGENT_ACTIVE_TASK_SLUG="$(declare -f memory_get_task_slug &>/dev/null && memory_get_task_slug "$goal" || echo "active_report_$(date '+%H%M%S')")"
    export AGENT_TASK_WORKSPACE="$session_dir" AGENT_TASK_WORKSPACE_REL=".george/workspaces/$session_id" AGENT_ACTIVE_SESSION_DIR="$session_dir" AGENT_ACTIVE_SESSION_ID="$session_id"
    declare -f memory_register_files &>/dev/null && memory_register_files "$workdir"

    if declare -f telemetry_task_start &>/dev/null; then
        telemetry_task_start "$session_id" "$_meta_type" "$workdir" "${session_log:-$history_file}" "${CRON_POPUP_PID:-${PTY_PID:-0}}" "${_TRANSCRIPT_FILE:-}" >/dev/null 2>&1 || true
    fi
    if [ -n "$parent_task_id" ] && declare -f subagents_register &>/dev/null; then
        subagents_register "$session_id" "$$" "${parent_pid:-$PPID}" "${ACTIVE_TIER:-1}" "${ACTIVE_ENDPOINT_MODEL:-default}" "$goal" "" "$session_dir" "$max_turns" 2>/dev/null || true
    fi
    declare -f mcp_ensure_running &>/dev/null && mcp_ensure_running

    if [ "$mode" = "worker" ]; then
        mkdir -p "$session_dir" 2>/dev/null || true
        jq -n --arg g "$goal" --argjson t "${ACTIVE_TIER:-1}" '{"primary_task": $g, "items": [{"id": 1, "task": "Execute delegated task and deliver results", "status": "pending", "tier": $t, "depends_on": [], "endpoint_tier": $t, "retry_count": 0}]}' > "$hd_file" 2>/dev/null || true
        ui_section "Worker Execution Plan"; ui_step "Step 1: Execute delegated task and deliver results"
    else
        _react_ensure_honeydew_plan "$goal" "$workdir" 1 "$session_dir"
    fi

    export AGENT_REACT_LOOP=1
    export SUPPRESS_TOOL_MANIFEST=1
    ui_dim "Assembling context pipeline and native tool registry..."
    local sys_prompt=$(context_engine_build "$goal" "$workdir" "$ACTIVE_TIER" "${tool_filter:-default}")
    local active_tools_file="$session_dir/active_tools.json" tools_schema=""
    if declare -f native_tools_resolve_profile &>/dev/null; then tools_schema=$(native_tools_resolve_profile "${tool_filter:-default}")
    elif declare -f native_tools_get_schemas &>/dev/null; then tools_schema=$(native_tools_get_schemas "$tool_filter")
    else tools_schema=$(native_tools_get_all_schemas)
    fi
    echo "$tools_schema" > "$active_tools_file"

    local bedrock_appendix=""
    if declare -f native_tools_bedrock_appendix &>/dev/null; then
        bedrock_appendix=$(native_tools_bedrock_appendix)
    fi

    local initial_user_msg=""
    local goal_clean="$goal"
    [[ "$goal_clean" == *"<conversation_history>"* ]] && goal_clean="${goal_clean%%<conversation_history>*}"
    if [ "$mode" = "worker" ]; then
        initial_user_msg="PRIMARY OBJECTIVE (DELEGATED WORKER):\n$goal_clean\n\nSANDBOX WORKSPACE:\n$workdir\n\nDIRECTIVES FOR WORKER:\n1. Execute all actions directly inside your isolated sandbox workspace.\n2. If your task requires creating or modifying code: test your changes thoroughly using bash_exec. When verified, submit your deliverable as a Pull Request to Sovereign Gitea using gitea_pr_create (or git commit/push to your subagent branch), and return the PR number and summary.\n3. If your task is research or query: retrieve the information and return your findings directly as text.\n4. Conclude with a clear summary of your work."
        if [ -n "${REACT_CONVERSATION_HISTORY:-}" ]; then
            if [[ "$REACT_CONVERSATION_HISTORY" == *"<conversation_history>"* ]]; then
                initial_user_msg+="\n\n${REACT_CONVERSATION_HISTORY}"
            else
                initial_user_msg+="\n\n<conversation_history>\n${REACT_CONVERSATION_HISTORY}\n</conversation_history>"
            fi
        fi
        [ -n "$bedrock_appendix" ] && initial_user_msg+="\n\n$bedrock_appendix"
    else
        local act_step=$(jq -r '[.items[]? | select(.status != "done")][0] | if . then "Step " + (.id|tostring) + ": " + .task else "Synthesize Final Deliverable" end' "$hd_file" 2>/dev/null)
        [ -z "$act_step" ] && act_step="Synthesize Final Deliverable"
        local plan_check=$(jq -r '.items[]? | "- [" + (if .status == "done" then "✓" else " " end) + "] Step " + (.id|tostring) + ": " + .task' "$hd_file" 2>/dev/null)
        local init_dir="Focus exclusively on executing $act_step directly using domain getter/action tools."
        if _react_is_final_synthesis_step "$act_step" "$hd_file"; then
            init_dir=$(_react_synthesis_directive "$act_step")
        fi
        local goal_lower="${goal_clean,,}"
        if [[ "$goal_lower" =~ (cron|schedule|recurring) ]] && [[ "$goal_lower" =~ (research|intel|report|news|releases?|announcement|findings|sweep) ]]; then
            init_dir+="\n\n[ARCHITECTURAL DIRECTIVE: For research or intelligence cron jobs, follow the Blue Lodge standard pattern established in .george/cron_jobs/health_insurance_intel.sh. Implement a lightweight .george/cron_jobs/<name>.sh launcher with '# INTERVAL: <seconds>' that delegates execution to: exec \"\$LODGE_DIR/lodge\" \"Run the research_sandbox tool with sample_size 5 and output_file '<file>' for the topic: '<topic>'. Then read the generated dossier and send a concise summary of it to <Discord target>.\". Do not attempt to write complex ad-hoc scrapers from scratch; leverage research_sandbox.]"
        fi
        initial_user_msg="PRIMARY OBJECTIVE:\n$goal_clean\n\nHONEYDEW EXECUTION PLAN:\n$plan_check\n\nCURRENT ACTIVE MILESTONE:\n$act_step\n\nDIRECTIVE: $init_dir"
        if [ -n "${REACT_CONVERSATION_HISTORY:-}" ]; then
            if [[ "$REACT_CONVERSATION_HISTORY" == *"<conversation_history>"* ]]; then
                initial_user_msg+="\n\n${REACT_CONVERSATION_HISTORY}"
            else
                initial_user_msg+="\n\n<conversation_history>\n${REACT_CONVERSATION_HISTORY}\n</conversation_history>"
            fi
        fi
        [ -n "$bedrock_appendix" ] && initial_user_msg+="\n\n$bedrock_appendix"
    fi

    jq -n --arg sys "$sys_prompt" --arg user "$initial_user_msg" '[{"role": "system", "content": $sys}, {"role": "user", "content": $user}]' > "$messages_file"

    local running_tokens=0 turn=1 consecutive_empty_turns=0 consecutive_premature_plans=0 _cot_retry_used=0 _final_adv_sent="" _discord_nudge_turn=0
    local thrashing_target_streak=0 tool_search_streak=0 tool_search_lock_until=0 hd_guard_hits=0 _rl_advisor_json="" same_tool_streak=0 last_invoked_tool="" same_target_path_streak=0 last_inspected_path=""
    echo "PRIMARY OBJECTIVE: $goal" >> "$history_file"
    local display_goal="$goal"
    if [[ "$goal" == *"OBJECTIVE:"* ]]; then
        display_goal="${goal##*OBJECTIVE:}"
        display_goal="${display_goal#"${display_goal%%[![:space:]]*}"}"
    fi
    # Squash multiple lines into single clean line for transcript header without cutting off characters
    display_goal=$(echo "$display_goal" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^ //;s/ $//')
    ui_info "Starting Task: $display_goal"

    local _LAST_SEEN_HD_ID=""
    if [ -f "$hd_file" ]; then
        _LAST_SEEN_HD_ID=$(jq -r '[.items[]? | select(.status != "done")][0].id // 1' "$hd_file" 2>/dev/null || echo 1)
    fi

    _react_heartbeat_ticker_start "$session_id" "$session_dir" "$max_turns"

    # Optional wall-clock budget (seconds). Unset/0 = unlimited (default, unchanged behaviour).
    local _wall_t0 _wall_budget="${REACT_WALL_BUDGET_S:-0}" _wall_stage=0
    _wall_t0=$(date +%s)
    [[ "$_wall_budget" =~ ^[0-9]+$ ]] || _wall_budget=0

    while [ "$turn" -le "$max_turns" ]; do
        if [ -f "${TMPDIR:-/tmp}/.lodge-cancel-$$" ] || [ "${_LODGE_CANCELLED:-0}" -eq 1 ]; then
            _rl_outcome="ABORTED"; _rl_reason="cancelled_by_signal"
            ui_warn "Task cancelled via signal."; export _LODGE_IN_TASK=0; stty sane 2>/dev/null; return 130
        fi

        # Dynamic turn-level cooperative pause for sovereign background remediation
        if [ "${AGENT_SOVEREIGN_REMEDIATION:-0}" -eq 1 ] && declare -f remediation_cooperative_pause &>/dev/null; then
            remediation_cooperative_pause 1
        fi

        local current_hd_step="Step 1" current_hd_id=1
        if [ -f "$hd_file" ]; then
            current_hd_id=$(jq -r '[.items[]? | select(.status != "done")][0].id // 1' "$hd_file" 2>/dev/null || echo 1)
            current_hd_step=$(jq -r '[.items[]? | select(.status != "done")][0] | if . then "Step " + (.id|tostring) + ": " + .task else "Synthesize Final Deliverable" end' "$hd_file" 2>/dev/null)
        fi
        [ -z "$current_hd_step" ] && current_hd_step="Synthesize Final Deliverable"
        export CURRENT_ACTIVE_MILESTONE_ID="$current_hd_id"
        printf "\n${C_BOLD}${C_CYAN}── Turn %d/%d | Active Honeydew: %s ──────────────────────────────${C_RESET}\n" "$turn" "$max_turns" "$current_hd_step"
        echo "Turn $turn/$max_turns: $current_hd_step" > "$session_dir/.phase" 2>/dev/null || true
        echo -e "\n── Turn $turn/$max_turns | Active Honeydew: $current_hd_step ──\n" >> "$history_file" 2>/dev/null || true
        declare -f transcript_section &>/dev/null && transcript_section "Turn $turn / $max_turns: $current_hd_step"

        # Milestone advancement detection: inject tail milestone notification rather than mutating prefix
        if [ "$mode" != "worker" ] && [ -n "$_LAST_SEEN_HD_ID" ] && [ "$current_hd_id" != "$_LAST_SEEN_HD_ID" ]; then
            local prev_hd_id="$_LAST_SEEN_HD_ID"
            _LAST_SEEN_HD_ID="$current_hd_id"
            local advance_directive="Focus exclusively on executing $current_hd_step directly using domain getter/action tools."
            if _react_is_final_synthesis_step "$current_hd_step" "$hd_file"; then
                advance_directive=$(_react_synthesis_directive "$current_hd_step")
                _final_adv_sent=1
            fi
            local adv_banner="[HONEYDEW ADVANCE: Step $prev_hd_id complete [✓]. Active Milestone -> $current_hd_step. Directive: $advance_directive]"
            ui_ok "  [honeydew] Step $prev_hd_id complete -> Next: $current_hd_step"
            jq --arg adv "$adv_banner" '. += [{"role": "user", "content": $adv}]' "$messages_file" > "${messages_file}.tmp" 2>/dev/null && mv "${messages_file}.tmp" "$messages_file"
        fi

        # Discord: a long silent run looks dead from the channel. Nudge once to post a short status.
        if [ "${_DISCORD_IN_SESSION:-0}" = "1" ] && [ "$mode" != "worker" ] && [ -z "${_discord_nudged:-}" ] \
           && [ "$turn" -ge "${DISCORD_STATUS_NUDGE_TURN:-12}" ] && [ ! -s "${DISCORD_RUN_OUTBOX:-/nonexistent}" ]; then
            _discord_nudged=1
            _discord_nudge_turn="$turn"
            jq --arg p "[DISCORD NOTICE: You have been working for $turn turns and the channel has heard nothing except the automatic progress line. If this will take a while longer, post one short status or partial finding now with discord_send (no target = this channel), then continue.]" '. += [{"role": "user", "content": $p}]' "$messages_file" > "${messages_file}.tmp" 2>/dev/null && mv "${messages_file}.tmp" "$messages_file"
        fi

        # Operator Steer & Lifecycle Handling from Autonomic Task Bay & Control FIFO
        local _ctrl_fifo=""
        [ -p "$workdir/control.fifo" ] && _ctrl_fifo="$workdir/control.fifo"
        [ -z "$_ctrl_fifo" ] && [ -p "$session_dir/control.fifo" ] && _ctrl_fifo="$session_dir/control.fifo"
        if [ -n "$_ctrl_fifo" ]; then
            local _fifo_cmd=""
            if read -t 0.05 -r _fifo_cmd <> "$_ctrl_fifo" 2>/dev/null; then
                case "$_fifo_cmd" in
                    PAUSE) touch "$session_dir/.pause_requested" "$workdir/.pause_requested" 2>/dev/null || true ;;
                    RESUME) rm -f "$session_dir/.pause_requested" "$workdir/.pause_requested" 2>/dev/null || true; touch "$session_dir/.resume_requested" 2>/dev/null || true ;;
                    ABORT) touch "$session_dir/.abort" "$workdir/.abort" 2>/dev/null || true ;;
                    *) [ -n "$_fifo_cmd" ] && printf '%s\n' "$_fifo_cmd" > "$session_dir/.guidance_injection" 2>/dev/null || true ;;
                esac
            fi
        fi

        if [ -f "$session_dir/.pause_requested" ] || [ -f "$workdir/.pause_requested" ]; then
            echo "Paused" > "$session_dir/.phase" 2>/dev/null || true
            ui_warn "Task paused by operator via Autonomic Task Bay. Waiting for resume signal..."
            while [ -f "$session_dir/.pause_requested" ] || [ -f "$workdir/.pause_requested" ]; do
                # Check for control.fifo resume signal while paused
                if [ -n "$_ctrl_fifo" ]; then
                    local _resume_chk=""
                    if read -t 0.1 -r _resume_chk <> "$_ctrl_fifo" 2>/dev/null; then
                        [ "$_resume_chk" = "RESUME" ] && rm -f "$session_dir/.pause_requested" "$workdir/.pause_requested" 2>/dev/null || true
                        [ "$_resume_chk" = "ABORT" ] && touch "$session_dir/.abort" 2>/dev/null || true
                    fi
                fi
                sleep 0.5
                if [ -f "$session_dir/.abort" ] || [ -f "$workdir/.abort" ] || [ -f "${TMPDIR:-/tmp}/.lodge-cancel-$$" ]; then
                    break
                fi
            done
            rm -f "$session_dir/.resume_requested" 2>/dev/null || true
            echo "Turn $turn/$max_turns: $current_hd_step" > "$session_dir/.phase" 2>/dev/null || true
        fi
        if [ -f "$session_dir/.abort" ] || [ -f "$workdir/.abort" ]; then
            _rl_outcome="ABORTED"; _rl_reason="operator_abort"
            ui_warn "Task aborted by operator via Autonomic Task Bay."; return 130
        fi
        local _guidance_src=""
        [ -f "$session_dir/.guidance_injection" ] && _guidance_src="$session_dir/.guidance_injection"
        [ -z "$_guidance_src" ] && [ -f "$workdir/.guidance_injection" ] && _guidance_src="$workdir/.guidance_injection"
        if [ -n "$_guidance_src" ]; then
            local _inj_msg
            _inj_msg=$(cat "$_guidance_src" 2>/dev/null || true)
            rm -f "$_guidance_src" "$session_dir/.guidance_injection" "$workdir/.guidance_injection" 2>/dev/null || true
            if [ -n "$_inj_msg" ]; then
                local _formatted_inj="$_inj_msg"
                if [[ "$_inj_msg" != *"[CRITICAL OPERATOR"* ]] && [[ "$_inj_msg" != *"[OPERATOR"* ]] && [[ "$_inj_msg" != "[DISCORD UPDATE"* ]]; then
                    _formatted_inj="[CRITICAL OPERATOR DIRECTIVE - PRIORITY 1]: $_inj_msg"
                fi
                ui_info "[DIRECTIVE: P1] Operator Directive Injected: $_inj_msg"
                echo -e "\n\033[1;33m$_formatted_inj\033[0m" >> "$session_dir/trajectory.log"
                jq --arg inj "$_formatted_inj" '. += [{"role": "user", "content": $inj}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file" 2>/dev/null || true
            fi
        fi

        local pending_tool_steps=0
        if [ -f "$hd_file" ]; then
            pending_tool_steps=$(_react_pending_action_steps "$hd_file")
        fi
        local last_role=$(jq -r '.[-1].role // empty' "$messages_file" 2>/dev/null)
        if [ "$pending_tool_steps" -eq 0 ] && [ "$last_role" = "tool" ] && [ -z "${_final_adv_sent:-}" ] \
           && ! { [ "${last_invoked_tool:-}" = "discord_send" ] && [ "${_discord_nudge_turn:-0}" -eq $((turn - 1)) ]; }; then
            _final_adv_sent=1
            local final_adv="[HONEYDEW PROGRESS: $(_react_synthesis_directive "$current_hd_step")]"
            jq --arg a "$final_adv" '. += [{"role": "user", "content": $a}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
        fi

        if declare -f ipc_channel_is_open &>/dev/null && ipc_channel_is_open "$session_id"; then
            # Session channel = turn budget + operator control surface (PAUSE/RESUME/ABORT).
            if ! ipc_flow_acquire "$session_id" 0 2>/dev/null; then
                local _fg_sf="$FIFO_IPC_DIR/channels/$session_id/state.json" _fg_raw="" _fg_bp="false" _fg_st="OPEN" _fg_win=50
                [ -f "$_fg_sf" ] && _fg_raw=$(< "$_fg_sf")
                _ipc_jget_raw _fg_bp "$_fg_raw" backpressure false
                _ipc_jget_raw _fg_st "$_fg_raw" status OPEN
                _ipc_jget_raw _fg_win "$_fg_raw" window_size 50
                if [ "$_fg_st" = "ABORTED" ] || [ "$_fg_st" = "CLOSED" ]; then
                    ui_warn "Session $session_id aborted via IPC control channel. Ending turn loop."
                    break
                elif [ "$_fg_bp" = "true" ]; then
                    # Operator/backpressure PAUSE: block until RESUME (never bypass)
                    declare -f agent_sm_transition &>/dev/null && agent_sm_transition "$session_id" "FLOW_PAUSED" "Paused via IPC control channel"
                    ui_warn "Flow paused for session $session_id; waiting for RESUME (max ${REACT_FLOW_PAUSE_MAX_WAIT:-3600}s)..."
                    if ! ipc_flow_acquire "$session_id" "${REACT_FLOW_PAUSE_MAX_WAIT:-3600}" 2>/dev/null; then
                        ui_warn "Session $session_id not resumed/aborted. Ending turn loop."
                        break
                    fi
                    declare -f agent_sm_transition &>/dev/null && agent_sm_transition "$session_id" "RUNNING" "Resumed via IPC control channel"
                elif [ -z "${GEORGE_PARENT_TASK_ID:-}" ]; then
                    # Autonomous session exhausted its turn budget window: open a new window
                    ipc_flow_grant "$session_id" "$_fg_win" >/dev/null 2>&1
                    ipc_flow_acquire "$session_id" 0 >/dev/null 2>&1 || true
                else
                    # Child session: wait for the parent to grant credits, then degrade gracefully
                    declare -f agent_sm_transition &>/dev/null && agent_sm_transition "$session_id" "FLOW_PAUSED" "Credit window exhausted"
                    ui_warn "Flow paused: awaiting credit grant for session $session_id..."
                    if ! ipc_flow_acquire "$session_id" "${REACT_FLOW_CREDIT_WAIT:-30}" 2>/dev/null; then
                        ipc_log "WARN" "$session_id" "No parent credit grant within ${REACT_FLOW_CREDIT_WAIT:-30}s; self-granting half window"
                        ipc_flow_grant "$session_id" $(( (_fg_win + 1) / 2 )) >/dev/null 2>&1
                        ipc_flow_acquire "$session_id" 0 >/dev/null 2>&1 || true
                    fi
                    declare -f agent_sm_transition &>/dev/null && agent_sm_transition "$session_id" "RUNNING" "Resumed with granted credits"
                fi
            fi
        fi

        local compact_thresh="${ACTIVE_ENDPOINT_COMPACT_TOKENS:-98304}"
        local ctx_lim="${ACTIVE_ENDPOINT_CONTEXT_LIMIT:-131072}"

        declare -f task_sync_signal &>/dev/null && task_sync_signal "$session_id" "turn" "$(jq -cn --arg id "$session_id" --argjson turn "$turn" --arg tool "${last_invoked_tool:-none}" '{session_id:$id, turn:$turn, last_tool:$tool}')" >/dev/null 2>&1 || true
        declare -f telemetry_task_heartbeat &>/dev/null && telemetry_task_heartbeat "$session_id" "$turn" "${last_invoked_tool:-}" "$max_turns" "$running_tokens" "$compact_thresh" "$ctx_lim"
        declare -f agent_sm_heartbeat &>/dev/null && agent_sm_heartbeat "$session_id"
        [ "${AGENT_SOVEREIGN_REMEDIATION:-0}" -eq 1 ] && declare -f remediation_cooperative_pause &>/dev/null && remediation_cooperative_pause

        if [ -n "${PTY_PID:-}" ] && [ "${PTY_PID:-0}" -ne 0 ] && ! kill -0 "$PTY_PID" 2>/dev/null; then
            ui_warn "Session monitor (PID $PTY_PID) ended unexpectedly. Closing turn loop."
            declare -f telemetry_record_anomaly &>/dev/null && telemetry_record_anomaly "$session_id" "PROCESS_STALL" "react.sh" "PTY monitor PID $PTY_PID severed" >/dev/null 2>&1 || true
            break
        fi

        [ -s "$active_tools_file" ] && tools_schema=$(cat "$active_tools_file")

        local countdown_trigger=$((max_turns - 10))
        [ "$max_turns" -lt 15 ] && countdown_trigger=$((max_turns - 4))
        [ "$max_turns" -le 5 ] && countdown_trigger=$((max_turns - 1))
        if [ "$turn" -ge "$countdown_trigger" ] && [ "$turn" -lt "$max_turns" ]; then
            local rem=$((max_turns - turn)) alert_msg=""
            ui_warn "Turn budget: Turn $turn/$max_turns ($rem turn(s) remaining)."
            if [ "$tool_filter" = "social" ] || [ "$tool_filter" = "chat" ]; then
                alert_msg="[SYSTEM ADVISORY: Turn $turn/$max_turns — $rem turn(s) remaining. Conclude your response to the user.]"
            else
                if [ "$rem" -ge 7 ]; then alert_msg="[SYSTEM ADVISORY: Turn $turn/$max_turns — $rem turns remaining. You have ample budget, but begin converging your investigation toward a concrete fix.]"
                elif [ "$rem" -ge 4 ]; then alert_msg="[SYSTEM ADVISORY: Turn $turn/$max_turns — $rem turns remaining. Transition from research to execution: apply your code edits and execute automated tests.]"
                elif [ "$rem" -ge 2 ]; then alert_msg="[SYSTEM ADVISORY: Turn $turn/$max_turns — $rem turns remaining. Final verification: ensure tests pass cleanly, stage changes, and prepare your final summary.]"
                else alert_msg="[SYSTEM ADVISORY: FINAL TURN ($turn/$max_turns — 1 turn remaining). Conclude your task now and present your final deliverable and summary.]"
                fi
            fi
            jq --arg msg "$alert_msg" 'if (.[-1].content | test("SYSTEM ADVISORY|APPROACHING TURN CEILING|SYSTEM NOTICE"; "i")) then .[-1].content = $msg else . += [{"role": "user", "content": $msg}] end' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
        fi

        # ── Wall-clock budget: converge at 70%, force the final turn at 85% ──
        if [ "$_wall_budget" -gt 0 ] && [ "$_wall_stage" -lt 2 ]; then
            local _wall_el=$(( $(date +%s) - _wall_t0 ))
            local _wall_msg=""
            if [ $((_wall_el * 100)) -ge $((_wall_budget * 85)) ]; then
                _wall_stage=2
                max_turns="$turn"
                _wall_msg="[SYSTEM ADVISORY: TIME BUDGET EXHAUSTED (${_wall_el}s of ${_wall_budget}s). FINAL TURN. Do not call tools. Write your final deliverable now from scratchpad.md, with the source links you have gathered.]"
            elif [ "$_wall_stage" -lt 1 ] && [ $((_wall_el * 100)) -ge $((_wall_budget * 70)) ]; then
                _wall_stage=1
                _wall_msg="[SYSTEM ADVISORY: Time budget ${_wall_el}s of ${_wall_budget}s used. Stop opening new lines of research; finish the current step and move to writing the final deliverable.]"
            fi
            if [ -n "$_wall_msg" ]; then
                ui_warn "Time budget: ${_wall_el}s/${_wall_budget}s (stage $_wall_stage)"
                _react_trace "$workdir" "wall_budget" "$(jq -cn --argjson el "$_wall_el" --argjson b "$_wall_budget" --argjson s "$_wall_stage" '{elapsed:$el, budget:$b, stage:$s}')" 2>/dev/null || true
                jq --arg msg "$_wall_msg" 'if (.[-1].content | test("SYSTEM ADVISORY"; "i")) then .[-1].content = $msg else . += [{"role": "user", "content": $msg}] end' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
            fi
        fi

        # ── Research Evidence Density & Early Convergence Check ─────────────
        # For research tasks, check evidence density in scratchpad.md to prevent open-ended looping
        if [ "$tool_filter" = "research" ] && [ "$turn" -ge 12 ] && [ "$turn" -lt "$countdown_trigger" ]; then
            local _sp="$session_dir/scratchpad.md"
            [ ! -f "$_sp" ] && _sp="$workdir/scratchpad.md"
            if [ -f "$_sp" ]; then
                local _sp_refs
                _sp_refs=$(grep -E -c '^(####|###|\*|-).*(\[http|https?://|arXiv|Reference|Source|Extracted Paper)' "$_sp" 2>/dev/null || echo 0)
                local _sp_chars
                _sp_chars=$(wc -c < "$_sp" 2>/dev/null || echo 0)
                if [ "${_sp_refs:-0}" -ge 4 ] && [ "${_sp_chars:-0}" -ge 3000 ]; then
                    local _conv_advisory="[SYSTEM CONVERGENCE DIRECTIVE: Research evidence threshold satisfied (${_sp_refs} verified sources cataloged, ${_sp_chars} bytes in scratchpad.md). Cease secondary searches, repeated file reads, or scraping. Conclude Phase 1 now with a concise summary of your findings so the pipeline can proceed to Phase 2 (Audit) and Phase 3 (Monograph Synthesis).]"
                    jq --arg msg "$_conv_advisory" 'if (.[-1].content | test("SYSTEM CONVERGENCE DIRECTIVE"; "i")) then .[-1].content = $msg else . += [{"role": "user", "content": $msg}] end' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                    ui_info "  [convergence] Injected research convergence directive (${_sp_refs} refs, ${_sp_chars} chars in scratchpad.md)"
                fi
            fi
        fi

        if [ -f "$messages_file" ]; then
            local cur_b=$(wc -c < "$messages_file" 2>/dev/null || echo 0)
            local est_tok=$(( (cur_b * 10 / 35) + 4000 ))
            [ "$est_tok" -gt "$running_tokens" ] && running_tokens="$est_tok"
        fi

        # Check for operator forced compaction interrupt OR automatic threshold
        if [ -f "$session_dir/.compact_requested" ] || [ "$running_tokens" -ge "$compact_thresh" ]; then
            local was_forced=0
            [ -f "$session_dir/.compact_requested" ] && was_forced=1
            rm -f "$session_dir/.compact_requested" 2>/dev/null || true
            if [ "$was_forced" -eq 1 ]; then
                ui_warn "[COMPACT] Operator Forced Context Compaction triggered at Turn $turn!"
                echo -e "\n\033[1;36m[COMPACT INTERRUPT]: Operator initiated forced context compaction at Turn $turn.\033[0m" >> "$session_dir/trajectory.log"
            fi
            _react_compact_messages "$session_dir" "$ACTIVE_ENDPOINT_URL" "$workdir" "$goal" "${mode:-master}"
            running_tokens=0
            if [ -f "$messages_file" ]; then
                local post_b=$(wc -c < "$messages_file" 2>/dev/null || echo 0)
                running_tokens=$(( (post_b * 10 / 35) + 2500 ))
            fi
        fi

        local payload_file="$session_dir/payload_turn_${turn}.json" turn_tool_choice="auto"
        # Maintain active toolset across turns for KV cache preservation
        local turn_tools_schema="$tools_schema"
        if [ "${tool_search_streak:-0}" -ge 2 ] && [ "${tool_search_lock_until:-0}" -le "$turn" ]; then
            # P2.7: lock tool_search for 4 turns (masking for one turn let it oscillate back)
            tool_search_lock_until=$(( turn + 4 )); tool_search_streak=0
            local _ts_avail; _ts_avail=$(echo "$turn_tools_schema" | jq -r '[.[].function.name | select(. != "tool_search")] | join(", ")' 2>/dev/null)
            _react_steer "[TOOLS LOCKED: tool_search is disabled for the next 4 turns. Use one of the tools you already have: ${_ts_avail}]" "$messages_file"
        fi
        if [ "${tool_search_lock_until:-0}" -gt "$turn" ]; then
            turn_tools_schema=$(echo "$turn_tools_schema" | jq -c '[.[] | select(.function.name != "tool_search")]' 2>/dev/null || echo "$turn_tools_schema")
            ui_warn "  [tool-mask] tool_search locked until turn $tool_search_lock_until"
        fi
        if _react_is_final_synthesis_step "$current_hd_step" "$hd_file"; then
            turn_tools_schema=$(_react_scope_tools_for_step "$tools_schema" "$current_hd_step" "$pending_tool_steps")
            if [ "${pending_tool_steps:-0}" -eq 0 ]; then
                turn_tools_schema=$(echo "$turn_tools_schema" | jq -c '[.[] | select(.function.name | test("^(milestone_complete|task_complete|end_turn)$") | not)]' 2>/dev/null || echo "$turn_tools_schema")
            fi
        fi
        if [ "$turn_tools_schema" = "[]" ] || [ -z "$turn_tools_schema" ]; then
            turn_tools_schema="[]"; turn_tool_choice="none"
            ui_dim "  [tool-mask] Step '$current_hd_step' -> Synthesis Mode (tool_choice=none)"
        else
            ui_dim "  [tool-mask] Step '$current_hd_step' -> Mounted tools: [$(echo "$turn_tools_schema" | jq -r '[.[].function.name] | join(", ")' 2>/dev/null)]"
            [ "${consecutive_premature_plans:-0}" -gt 0 ] && { turn_tool_choice="required"; ui_dim "  [tool-mask] Enforcing tool_choice=required due to premature planning ($consecutive_premature_plans)"; }
        fi

        # ── Wall-clock hard ceiling: advisories alone can't stop a long turn ──
        # Clamp this turn's request to the remaining budget (+45s grace) and cap
        # output on the forced final turn so it can't overrun the caller's timeout.
        local turn_max_tok="$agent_max_tok"
        if [ "$_wall_budget" -gt 0 ]; then
            local _wall_left=$(( _wall_budget + 45 - ($(date +%s) - _wall_t0) ))
            [ "$_wall_left" -lt 20 ] && _wall_left=20
            [[ "$req_timeout" =~ ^[0-9]+$ ]] && [ "$req_timeout" -gt "$_wall_left" ] && req_timeout="$_wall_left"
            if [ "$_wall_stage" -ge 2 ] && [[ "$turn_max_tok" =~ ^[0-9]+$ ]] && [ "$turn_max_tok" -gt "${REACT_FINAL_TURN_MAX_TOK:-1200}" ]; then
                turn_max_tok="${REACT_FINAL_TURN_MAX_TOK:-1200}"
            fi
        fi

        jq -n --slurpfile msgs "$messages_file" --argjson tools "$turn_tools_schema" --arg tool_choice "$turn_tool_choice" --arg temp "$agent_temp" --arg topp "$agent_topp" --arg max_tok "$turn_max_tok" --arg r_effort "${LLM_REASONING_EFFORT:-medium}" '{messages: $msgs[0], tools: (if ($tools | length) > 0 then $tools else null end), tool_choice: (if ($tools | length) > 0 then $tool_choice else "none" end), parallel_tool_calls: (if ($tools | length) > 0 then true else null end), temperature: ($temp | tonumber), top_p: ($topp | tonumber), top_k: 20, min_p: 0.0, repeat_penalty: 1.0, frequency_penalty: 0.0, presence_penalty: 0.0, max_tokens: ($max_tok | tonumber), reasoning_effort: $r_effort, chat_template_kwargs: {preserve_thinking: true}, stream: true, stream_options: {include_usage: true}, stop: ["<|im_end|>", "<|endoftext|>"]}' > "$payload_file"

        if declare -f transcript_log_prompt &>/dev/null; then
            if [ "$turn" -le 1 ] || [ "${TRANSCRIPT_LOG_FULL_PAYLOAD:-0}" = "1" ]; then
                transcript_log_prompt "react-turn-$turn" "$(jq -c '{msg_count: (.messages|length), tool_count: ((.tools // [])|length), last_messages: (.messages[-2:])}' "$payload_file" 2>/dev/null || head -c 4000 "$payload_file")" "$sys_prompt"
            else
                transcript_log_prompt "react-turn-$turn" "$(jq -c '{turn: '"$turn"', msg_count: (.messages|length), delta: (.messages[-2:])}' "$payload_file" 2>/dev/null || tail -c 2000 "$payload_file")" ""
            fi
        fi

        local raw_content="" reasoning="" tool_calls="[]" p_tok=0 comp_tok=0 stream_cache="$session_dir/stream_turn_${turn}.json"
        local think_mode="${LODGE_THINK_STREAM:-1}"
        [ "${LODGE_NOTHINK:-0}" -eq 1 ] && think_mode=0
        local awk_opt=""
        awk --version 2>&1 | grep -iq mawk && awk_opt="-W interactive"

        declare -f ui_prefill_ticker_start &>/dev/null && ui_prefill_ticker_start "$session_dir"
        local stream_err_file="$session_dir/stream_err_turn_${turn}.log"
        if declare -f ipc_acquire_inference_lease &>/dev/null; then
            ipc_acquire_inference_lease "$_task_priority" "${session_id:-task_$$}" 120 2>/dev/null || true
        fi
        curl -s -N --keepalive-time 10 --max-time "$req_timeout" "$ACTIVE_ENDPOINT_URL/v1/chat/completions" -H "Content-Type: application/json" -d @"$payload_file" 2>"$stream_err_file" | \
        sed -u -e '/^:/d' -e '/^data: /!d' -e 's/^data: //' -e '/^\[DONE\]/d' -e '/^[[:space:]]*$/d' | \
        jq --unbuffered -c 'if .choices[0].delta.reasoning_content then {type: "thought", text: .choices[0].delta.reasoning_content} elif .choices[0].delta.content then {type: "content", text: .choices[0].delta.content} elif .choices[0].delta.tool_calls then {type: "tool_calls", delta: .choices[0].delta.tool_calls} elif .timings then {type: "usage", prompt_tokens: .timings.prompt_n, completion_tokens: .timings.predicted_n} elif .usage then {type: "usage", prompt_tokens: .usage.prompt_tokens, completion_tokens: .usage.completion_tokens} else empty end' 2>/dev/null | \
        awk -v think_mode="$think_mode" -v sc="$stream_cache" -v tpid_file="$session_dir/.prefill_ticker.pid" $awk_opt '
        BEGIN { color = (think_mode == 2 ? "\033[36m" : "\033[90m"); in_thought = 0; got_chunk = 0; }
        { if (!got_chunk) { got_chunk = 1; if (tpid_file != "") { system("tpid=$(cat " tpid_file " 2>/dev/null); rm -f " tpid_file " 2>/dev/null; if [ -n \"$tpid\" ]; then kill -9 $tpid 2>/dev/null; fi; printf \"\\r\\033[2K\" >&2"); } } print $0 > sc; fflush(sc); }
        /"type":"thought"/ { if (think_mode > 0) { if (!in_thought) { printf "%s[thought] ", color; in_thought = 1; } sub(/.*"text":"/, ""); sub(/"\}$/, ""); gsub(/\\n/, "\n"); gsub(/\\"/, "\""); gsub(/\\\\/, "\\"); printf "%s", $0; fflush(); } }
        /"type":"content"/ { if (in_thought) { if (think_mode > 0) printf "\033[0m\n"; in_thought = 0; } sub(/.*"text":"/, ""); sub(/"\}$/, ""); gsub(/\\n/, "\n"); gsub(/\\"/, "\""); gsub(/\\\\/, "\\"); printf "%s", $0; fflush(); }
        END { if (in_thought && think_mode > 0) printf "\033[0m\n"; }'
        local curl_status="${PIPESTATUS[0]}"
        declare -f ui_prefill_ticker_stop &>/dev/null && ui_prefill_ticker_stop "$session_dir"

        if [ "$curl_status" -eq 28 ]; then
            ui_warn "Inference stream timed out after ${req_timeout}s (curl error 28). Output may be partially truncated."
            _react_trace "$workdir" "warning" "{\"warning\":\"stream_timeout\",\"timeout_sec\":$req_timeout,\"turn\":$turn}"
        fi

        if [ ! -s "$stream_cache" ]; then
            ui_dim "Stream interrupted; querying synchronous fallback..."
            local fallback_payload="$session_dir/fallback_payload_turn_${turn}.json"
            jq '.stream = false | del(.stream_options)' "$payload_file" > "$fallback_payload"
            local resp_json=$(curl -s --keepalive-time 10 --max-time "$req_timeout" "$ACTIVE_ENDPOINT_URL/v1/chat/completions" -H "Content-Type: application/json" -d @"$fallback_payload" 2>/dev/null)
            [ -z "$resp_json" ] && { sleep 3; resp_json=$(curl -s --max-time "$req_timeout" "$ACTIVE_ENDPOINT_URL/v1/chat/completions" -H "Content-Type: application/json" -d @"$fallback_payload" 2>/dev/null); }
            local ep_err=""
            [ -n "$resp_json" ] && ep_err=$(echo "$resp_json" | jq -r '.error.message // .error // empty' 2>/dev/null)
            # If the inference container just restarted (e.g. after a crash/reload) and is still
            # initializing or loading weights (HTTP 503 "Loading model"), wait for /health readiness
            # and retry the SAME turn without burning consecutive_empty_turns or polluting messages.json.
            if [ -z "$resp_json" ] || [[ "$ep_err" =~ [Ll]oading\ model|unavailable|initializing|warming\ up ]]; then
                _endpoint_load_retries=$(( ${_endpoint_load_retries:-0} + 1 ))
                if [ "$_endpoint_load_retries" -le 3 ]; then
                    ui_warn "Inference endpoint ($ACTIVE_ENDPOINT_URL) is loading/restarting (${ep_err:-connection reset}); waiting up to ${REACT_ENDPOINT_LOAD_WAIT_SEC:-90}s for readiness (attempt $_endpoint_load_retries/3)..."
                    local _wait_sec=0 _max_wait="${REACT_ENDPOINT_LOAD_WAIT_SEC:-90}" _ep_ready=0
                    while [ "$_wait_sec" -lt "$_max_wait" ]; do
                        sleep 3
                        _wait_sec=$((_wait_sec + 3))
                        local _h_status
                        _h_status=$(curl -s -m 3 "$ACTIVE_ENDPOINT_URL/health" 2>/dev/null | jq -r '.status // empty' 2>/dev/null || true)
                        if [ "$_h_status" = "ok" ]; then
                            _ep_ready=1
                            break
                        fi
                    done
                    if [ "$_ep_ready" -eq 1 ]; then
                        ui_ok "Inference endpoint ($ACTIVE_ENDPOINT_URL) is ready after ${_wait_sec}s; retrying turn $turn."
                        if [ "$_task_priority" -lt "${IPC_PRIO_INTERACTIVE:-100}" ] && declare -f ipc_release_inference_lease &>/dev/null; then
                            ipc_release_inference_lease "${session_id:-task_$$}" 2>/dev/null || true
                        fi
                        continue
                    fi
                fi
            else
                _endpoint_load_retries=0
            fi
            if [ -z "$resp_json" ]; then
                ui_err "Empty response from endpoint $ACTIVE_ENDPOINT_URL."
                _react_trace "$workdir" "error" '{"error":"empty_response"}'
                _rl_outcome="ABORTED"; _rl_reason="endpoint_empty_response"
                declare -f transcript_stop &>/dev/null && transcript_active 2>/dev/null && transcript_stop >/dev/null 2>&1
                return 1
            fi
            if [ -n "$ep_err" ]; then
                ui_err "Inference endpoint error: $ep_err"
                if [[ "$ep_err" =~ context|token|length|maximum ]]; then
                    ui_warn "Context length exceeded! Triggering emergency auto-compaction..."
                    _react_compact_messages "$session_dir" "$ACTIVE_ENDPOINT_URL" "$workdir" "$goal" "${mode:-master}"
                    running_tokens=0; consecutive_empty_turns=0; turn=$((turn + 1)); continue
                fi
            fi
            raw_content=$(echo "$resp_json" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
            reasoning=$(echo "$resp_json" | jq -r '.choices[0].message.reasoning_content // empty' 2>/dev/null)
            tool_calls=$(echo "$resp_json" | jq -c '.choices[0].message.tool_calls // empty' 2>/dev/null)
            p_tok=$(echo "$resp_json" | jq -r '.usage.prompt_tokens // 0' 2>/dev/null)
            comp_tok=$(echo "$resp_json" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)
            [ -n "$reasoning" ] && printf "${C_DIM}[thought] %s${C_RESET}\n" "$reasoning"
        else
            _endpoint_load_retries=0
            local reconstructed=$(jq -s '{reasoning: ([.[] | select(.type=="thought") | .text] | join("")), content: ([.[] | select(.type=="content") | .text] | join("")), tool_calls: (([.[] | select(.type=="tool_calls") | .delta[]] // []) | reduce .[] as $call ([]; .[$call.index] = {id: (.[$call.index].id // $call.id), type: (.[$call.index].type // $call.type // "function"), function: {name: (.[$call.index].function.name // $call.function.name), arguments: ((.[$call.index].function.arguments // "") + ($call.function.arguments // ""))}})), usage: (reduce (.[] | select(.type=="usage")) as $u ({}; . + $u))}' "$stream_cache" 2>/dev/null)
            raw_content=$(echo "$reconstructed" | jq -r '.content // empty' 2>/dev/null)
            reasoning=$(echo "$reconstructed" | jq -r '.reasoning // empty' 2>/dev/null)
            tool_calls=$(echo "$reconstructed" | jq -c '.tool_calls // empty' 2>/dev/null)
            p_tok=$(echo "$reconstructed" | jq -r '.usage.prompt_tokens // 0' 2>/dev/null)
            comp_tok=$(echo "$reconstructed" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)
            if [ "$curl_status" -eq 28 ] && [ -n "$raw_content" ]; then
                raw_content="${raw_content}"$'\n\n*(Note: LLM generation reached the '"${req_timeout}"'s stream timeout; response was truncated mid-sentence.)*'
            fi
        fi

        # Release background inference lease between turns so interactive requests preempt instantly
        if [ "$_task_priority" -lt "${IPC_PRIO_INTERACTIVE:-100}" ] && declare -f ipc_release_inference_lease &>/dev/null; then
            ipc_release_inference_lease "${session_id:-task_$$}" 2>/dev/null || true
        fi

        # Use true token metrics from llama-server; only fallback to heuristic if unpopulated
        if [ "${p_tok:-0}" -le 0 ]; then
            local chars=0; [ -f "$messages_file" ] && chars=$(wc -c < "$messages_file" 2>/dev/null || echo 0)
            p_tok=$(( chars * 10 / 35 ))
        fi
        if [ "${comp_tok:-0}" -le 0 ]; then
            comp_tok=$(( (${#raw_content} + ${#reasoning}) * 10 / 35 ))
        fi

        local turn_total=$((p_tok + comp_tok))
        [ "$turn_total" -gt 0 ] && running_tokens=$turn_total
        local pct=0; [ "${ACTIVE_ENDPOINT_CONTEXT:-0}" -gt 0 ] && pct=$((turn_total * 100 / ACTIVE_ENDPOINT_CONTEXT))
        # Sanitize leaked thought tags from raw_content (e.g. reasoning budget rollover or model think tags)
        if [[ "$raw_content" == *"</think>"* ]]; then
            local leaked_thought="${raw_content%%</think>*}"
            raw_content="${raw_content#*</think>}"
            leaked_thought="${leaked_thought#*<think>}"
            reasoning="${reasoning:-}${reasoning:+ }${leaked_thought}"
            raw_content="$(echo "$raw_content" | sed -e 's/^[[:space:]]*//')"
        fi
        local active_thought="${reasoning:-}"
        if [ -z "$active_thought" ] && [[ "$raw_content" =~ \<think\>(.*)\</think\> ]]; then
            active_thought="${BASH_REMATCH[1]}"
        fi
        [ -n "$active_thought" ] && declare -f _subagent_log_event &>/dev/null && [ -n "${_SUBAGENT_ACTIVE_ID:-}" ] && _subagent_log_event "$_SUBAGENT_ACTIVE_ID" "THOUGHT" "$active_thought"
        [ -n "$reasoning" ] && declare -f transcript_log_block &>/dev/null && transcript_log_block "thought" "$reasoning"

        if [ -z "$tool_calls" ] || [ "$tool_calls" = "null" ] || [ "$tool_calls" = "[]" ]; then
            if [[ "$raw_content" == *"<function"* ]] || [[ "$raw_content" == *"<tool_call"* ]]; then
                local extracted_tc=$(_react_extract_text_tool_calls "$raw_content")
                if [ -n "$extracted_tc" ] && [ "$extracted_tc" != "[]" ]; then
                    tool_calls="$extracted_tc"; raw_content=""
                fi
            fi
        fi

        # ── P2.10 Thought-Only Turn Recovery (rem_1792091177_337 / b167cf0cd9bf) ──
        # An escalation task on a 4-turn budget burned its entire first turn on
        # chain-of-thought (no content, no tool calls), leaving no slack for the
        # final verification step even though operator_ask had already delivered.
        # A reasoning-only response must not consume a full turn: re-issue ONCE
        # within the same turn with tool_choice=required so the model is forced
        # to act on its completed deliberation instead of silently stalling.
        if [ -z "$tool_calls" ] || [ "$tool_calls" = "null" ] || [ "$tool_calls" = "[]" ]; then
            if [ -z "$raw_content" ] && [ -n "$reasoning" ] && [ "${_cot_retry_used:-0}" -eq 0 ] \
               && [ "$(jq 'length' <<<"$turn_tools_schema" 2>/dev/null || echo 0)" -gt 0 ] \
               && ! [[ "${tool_filter:-default}" =~ ^(social|chat)$ ]]; then
                _cot_retry_used=1
                ui_warn "  [cot-retry] Turn $turn returned deliberation only; re-issuing in-turn with tool_choice=required"
                _react_trace "$workdir" "cot_retry" "$(jq -cn --argjson turn "$turn" '{turn: $turn, reason: "thought_only_in_turn_retry"}')"
                # Persist the deliberation so the forced re-issue has full context
                jq --argjson m "$(jq -nc --arg rc "$reasoning" '{role: "assistant", content: null, reasoning_content: $rc}')" '. += [$m]' "$messages_file" > "${messages_file}.tmp" 2>/dev/null && mv "${messages_file}.tmp" "$messages_file"
                jq --arg p "[SYSTEM ADVISORY: Your previous turn contained deliberation only and no tool call. Your analysis is complete — now execute the single most useful native tool call for the active milestone.]" '. += [{"role": "user", "content": $p}]' "$messages_file" > "${messages_file}.tmp" 2>/dev/null && mv "${messages_file}.tmp" "$messages_file"
                local _cot_payload="$session_dir/cot_retry_payload_turn_${turn}.json" _cot_resp=""
                jq '.stream = false | del(.stream_options) | .tool_choice = "required" | del(.reasoning_effort)' "$payload_file" > "$_cot_payload" 2>/dev/null
                _cot_resp=$(curl -s --keepalive-time 10 --max-time "$req_timeout" "$ACTIVE_ENDPOINT_URL/v1/chat/completions" -H "Content-Type: application/json" -d @"$_cot_payload" 2>/dev/null)
                if [ -n "$_cot_resp" ] && jq -e '.choices[0].message' <<<"$_cot_resp" >/dev/null 2>&1; then
                    local _cot_tc _cot_content _cot_rc
                    _cot_tc=$(jq -c '.choices[0].message.tool_calls // empty' <<<"$_cot_resp" 2>/dev/null)
                    _cot_content=$(jq -r '.choices[0].message.content // empty' <<<"$_cot_resp" 2>/dev/null)
                    _cot_rc=$(jq -r '.choices[0].message.reasoning_content // empty' <<<"$_cot_resp" 2>/dev/null)
                    if [ -n "$_cot_tc" ] && [ "$_cot_tc" != "null" ] && [ "$_cot_tc" != "[]" ] \
                       && jq -e 'type == "array" and length > 0' <<<"$_cot_tc" >/dev/null 2>&1; then
                        # Recovery succeeded: the forced re-issue produced real tool
                        # action, so this turn proceeds to Branch 1 execution and the
                        # turn is preserved (no ceiling advance, no counter bump).
                        tool_calls="$_cot_tc"
                        raw_content="$_cot_content"
                        [ -n "$_cot_rc" ] && reasoning="${reasoning}${reasoning:+ }${_cot_rc}"
                        ui_ok "  [cot-retry] In-turn recovery: model issued $(jq 'length' <<<"$_cot_tc" 2>/dev/null || echo '?') tool call(s); Turn $turn preserved"
                    else
                        raw_content="${raw_content}${_cot_content}"
                        [ -n "$_cot_rc" ] && reasoning="${reasoning}${reasoning:+ }${_cot_rc}"
                    fi
                fi
            fi
        fi

        # ── Branch 1: Native OpenAI Tool Calls Detected ──────────────
        if [ -n "$tool_calls" ] && [ "$tool_calls" != "null" ] && [ "$tool_calls" != "[]" ]; then
            tool_calls=$(_react_repair_tool_calls "$tool_calls" "$reasoning")
            echo "$tool_calls" | jq -e 'type == "array"' >/dev/null 2>&1 || tool_calls="[]"
            # ── P2.9 Truncated-Args Guard & Intra-Turn Deduplication ──────────
            # 1) A tool call whose arguments are not valid JSON (e.g. truncated to
            #    `{"` by a cut SSE stream) must NEVER be persisted to the message
            #    history: the inference endpoint rejects every subsequent request
            #    with a 500 parse error on the poisoned assistant message.
            # 2) With parallel_tool_calls enabled in llama-server's PEG grammar,
            #    the model can emit 2–20 duplicate <tool_call> blocks in a single
            #    turn. Deduplicate within the turn by canonical action signature
            #    BEFORE persisting to messages.json or dispatching Phase 1/2.
            local _valid_tcs="[]" _tc_dropped=0 _tc_deduped=0
            local _turn_seen_sigs="|"
            while IFS= read -r _tc; do
                [ -z "$_tc" ] && continue
                if jq -e 'type == "object" and ((.function.name? // "") != "") and ((.function.arguments? // "") | tostring | (test("^\\s*$") or (fromjson? != null)))' <<<"$_tc" >/dev/null 2>&1; then
                    _tc=$(jq -c 'if ((.function.arguments? // "") | tostring | test("^\\s*$")) then .function.arguments = "{}" else . end' <<<"$_tc" 2>/dev/null || echo "$_tc")
                    local _tc_name _tc_args _tc_sig
                    _tc_name=$(jq -r '.function.name // empty' <<<"$_tc" 2>/dev/null)
                    _tc_args=$(jq -r '.function.arguments // "{}"' <<<"$_tc" 2>/dev/null)
                    if [[ "$_tc_name" =~ ^(milestone_complete|task_complete|end_turn)$ ]]; then
                        _tc_sig="singleton:${_tc_name}"
                    elif [ "$_tc_name" = "bash_exec" ]; then
                        local _b_cmd
                        _b_cmd=$(jq -r '.command // empty' <<<"$_tc_args" 2>/dev/null || echo "$_tc_args")
                        if [[ "$_b_cmd" =~ \b(discord_send|discord_dm|discord_send_file)\b ]]; then
                            _tc_sig="singleton:bash_discord_egress"
                        else
                            _tc_sig=$(_react_action_hash "$_tc_name" "$_tc_args")
                        fi
                    else
                        _tc_sig=$(_react_action_hash "$_tc_name" "$_tc_args")
                    fi
                    if [[ "$_turn_seen_sigs" == *"|${_tc_sig}|"* ]]; then
                        _tc_deduped=$((_tc_deduped + 1))
                        continue
                    fi
                    _turn_seen_sigs="${_turn_seen_sigs}${_tc_sig}|"
                    _valid_tcs=$(jq -c --argjson c "$_tc" '. + [$c]' <<<"$_valid_tcs" 2>/dev/null)
                else
                    _tc_dropped=$((_tc_dropped + 1))
                    ui_warn "  [tool-guard] Discarded tool call with truncated/malformed JSON arguments (name: $(echo "$_tc" | jq -r '.function.name // "unknown"' 2>/dev/null))"
                fi
            done < <(echo "$tool_calls" | jq -c '.[]' 2>/dev/null)
            [ "$_tc_deduped" -gt 0 ] && ui_dim "  [tool-dedup] Collapsed $_tc_deduped duplicate tool call(s) emitted in turn $turn"
            tool_calls="$_valid_tcs"
            if [ "$_tc_dropped" -gt 0 ] && [ "$tool_calls" = "[]" ]; then
                # Nothing survived validation: persist reasoning/content only (no
                # poisoned tool_calls) and steer the model to re-issue the call.
                jq --arg c "$raw_content" --arg rc "$reasoning" '. += [({role: "assistant", content: (if $c == "" then null else $c end)} + (if ($rc // "") != "" then {reasoning_content: $rc} else {} end))]' "$messages_file" > "${messages_file}.tmp" 2>/dev/null && mv "${messages_file}.tmp" "$messages_file"
                jq --arg n "[SYSTEM NOTICE: Your previous tool call arrived with truncated JSON arguments and was discarded before execution. Re-issue that tool call now with complete, well-formed JSON arguments.]" '. += [{"role": "user", "content": $n}]' "$messages_file" > "${messages_file}.tmp" 2>/dev/null && mv "${messages_file}.tmp" "$messages_file"
                ui_warn "  [tool-guard] All tool calls discarded this turn; steering re-issue."
                turn=$((turn + 1))
                continue
            fi

            # If the model emitted its full answer in raw_content alongside a terminal milestone_complete /
            # task_complete / end_turn tool call on the final Honeydew step (or a chat turn), complete immediately
            # on this turn instead of discarding raw_content and spinning an extra synthesis turn.
            if [ ${#raw_content} -ge 40 ] && jq -e 'type == "array" and length == 1 and (.[0].function.name | test("^(milestone_complete|task_complete|end_turn)$"))' <<<"$tool_calls" >/dev/null 2>&1; then
                local _rem_hd=0 _hd_type=""
                if [ -f "$hd_file" ]; then
                    _rem_hd=$(jq -r '[.items[]? | select(.status != "done")] | length' "$hd_file" 2>/dev/null || echo 0)
                    _hd_type=$(jq -r '.task_type // empty' "$hd_file" 2>/dev/null || true)
                fi
                if [ "${_rem_hd:-0}" -le 1 ] || [ "$_hd_type" = "chat" ]; then
                    [ -f "$hd_file" ] && jq '(.items[]? | select(.status != "done")).status = "done"' "$hd_file" > "${hd_file}.tmp" 2>/dev/null && mv "${hd_file}.tmp" "$hd_file"
                    tool_calls="[]"
                fi
            fi
        fi

        if [ -n "$tool_calls" ] && [ "$tool_calls" != "null" ] && [ "$tool_calls" != "[]" ]; then
            local asst_msg=$(jq -nc --arg content "$raw_content" --arg rc "$reasoning" --argjson tc "$tool_calls" '{role: "assistant", content: (if $content == "" then null else $content end), tool_calls: $tc} + (if ($rc // "") != "" then {reasoning_content: $rc} else {} end)' 2>/dev/null)
            [ -n "$asst_msg" ] && jq --argjson m "$asst_msg" '. += [$m]' "$messages_file" > "${messages_file}.tmp" 2>/dev/null && mv "${messages_file}.tmp" "$messages_file"
            # Substantive text emitted alongside tool calls is a candidate deliverable
            [ ${#raw_content} -ge "$REACT_DRAFT_MIN_CHARS" ] && _react_note_draft "$session_dir" "$raw_content"

            local tool_exhausted=0
            _REACT_IN_TOOL_LOOP=1; rm -f "$session_dir/.pending_steer" 2>/dev/null

            local num_turn_calls
            num_turn_calls=$(jq 'length' <<<"$tool_calls" 2>/dev/null || echo 1)
            [ "$num_turn_calls" -lt 1 ] 2>/dev/null && num_turn_calls=1

            local turn_total_budget="${REACT_TURN_TOTAL_BUDGET:-24000}"
            local turn_max_chars="${REACT_MAX_OBSERVATION_CHARS:-32000}"
            if [ "$num_turn_calls" -gt 1 ]; then
                turn_max_chars=$(( turn_total_budget / num_turn_calls ))
                [ "$turn_max_chars" -lt 4000 ] && turn_max_chars=4000
            fi

            local as_timeout
            as_timeout=$(declare -f limits_get &>/dev/null && limits_get ASYNC_TOOL_WATCHDOG_TIMEOUT 120 || echo 120)

            # Partition calls into Phase 1 (Concurrent Read-Only) and Phase 2 (Serial Mutation)
            local -a p1_calls=() p2_calls=()
            while IFS= read -r _t_call; do
                [ -z "$_t_call" ] && continue
                local _cn _ca
                _cn=$(jq -r '.function.name // empty' <<<"$_t_call" 2>/dev/null)
                _ca=$(jq -r '.function.arguments // empty' <<<"$_t_call" 2>/dev/null)
                if _react_tool_is_mutating "$_cn" "$_ca"; then
                    p2_calls+=("$_t_call")
                else
                    p1_calls+=("$_t_call")
                fi
            done < <(echo "$tool_calls" | jq -c '.[]' 2>/dev/null)

            # ── Phase 1: Read-Only Tools (Parallel fan-out if >= 2 calls and FIFO IPC available) ──
            if [ "${#p1_calls[@]}" -gt 1 ] && declare -f fifo_async &>/dev/null && declare -f fifo_await_all_settled &>/dev/null; then
                ui_step "Adaptive Barrier Phase 1: Fan-out ${#p1_calls[@]} concurrent read tools in parallel"
                local -a p1_prom_ids=() p1_t0_ms=() p1_is_cached=() p1_cached_resp=()
                local _p1_idx=0

                for _call in "${p1_calls[@]}"; do
                    local c_id c_name c_args
                    c_id=$(jq -r '.id' <<<"$_call")
                    c_name=$(jq -r '.function.name' <<<"$_call")
                    c_args=$(jq -r '.function.arguments' <<<"$_call")

                    # Streak and repetition checks:
                    # In parallel fan-out, all calls run concurrently within the SAME turn.
                    # Only evaluate turn-level tool and path streaks on the first call (_p1_idx == 0)
                    # to prevent intra-turn sibling calls from artificially escalating thrashing counters.
                    if [ "$_p1_idx" -eq 0 ]; then
                        if [ "$c_name" = "$last_invoked_tool" ]; then same_tool_streak=$((same_tool_streak + 1))
                        else same_tool_streak=1; last_invoked_tool="$c_name"
                        fi

                        if [ "$c_name" = "tool_search" ]; then
                            tool_search_streak=$((tool_search_streak + 1))
                            if [ "$tool_search_streak" -ge 2 ]; then
                                ui_warn "[CIRCUIT BREAKER] Tool search thrashing detected (Streak: $tool_search_streak). Triggering Prompt Perturbation Hook."
                                _react_circuit_breaker_perturbation "$session_id" "$workdir" "TOOL_SEARCH_THRASHING" "tool_search ($c_args)" "Repeated tool_search invocations without forward progress" "$messages_file" "$macro_file"
                            fi
                        elif [ "$c_name" = "bash_exec" ]; then
                            tool_search_streak=0
                        else
                            tool_search_streak=0
                            local max_tool_streak=$(declare -f limits_get &>/dev/null && limits_get CIRCUIT_BREAKER_MAX_TOOL_STREAK 8 || echo "${CIRCUIT_BREAKER_MAX_TOOL_STREAK:-8}")
                            local tool_streak_adv_threshold=$(( max_tool_streak - 2 ))
                            [ "$tool_streak_adv_threshold" -lt 4 ] && tool_streak_adv_threshold=4
                            if [ "$same_tool_streak" -ge "$max_tool_streak" ]; then
                                ui_warn "[CIRCUIT BREAKER] Tool invocation streak ceiling reached on $c_name (Streak: $same_tool_streak). Triggering Prompt Perturbation Hook."
                                _react_circuit_breaker_perturbation "$session_id" "$workdir" "TOOL_THRASHING" "$c_name ($c_args)" "Repeated invocations of $c_name without advancing the task" "$messages_file" "$macro_file"
                            elif [ "$same_tool_streak" -ge "$tool_streak_adv_threshold" ]; then
                                local tool_streak_adv="[CIRCUIT ADVISORY: Tool '$c_name' has been invoked ${same_tool_streak} times consecutively. If previous results were insufficient or empty, cease repeating this tool. Select an alternative tool or synthesize your findings to advance.]"
                                _react_steer "$tool_streak_adv" "$messages_file"
                            fi
                        fi
                    fi

                    local a_hash=$(_react_action_hash "$c_name" "$c_args")
                    local rep_strike=$(_react_check_repetition "$session_dir" "$a_hash" "$c_name" "$c_args")
                    if [ "$rep_strike" -ge 3 ]; then
                        local heal_ec=0
                        _react_self_heal_circuit_breaker "$session_id" "$workdir" "$session_dir" "$c_name" "$c_args" "$messages_file" "$macro_file" "$rep_strike"; heal_ec=$?
                        [ "$heal_ec" -ne 0 ] && { export AGENT_ACTIVE_SESSION_ID=""; return "$heal_ec"; }
                    elif [ "$rep_strike" -eq 1 ]; then
                        local rep_adv="[CIRCUIT ADVISORY: Action '$c_name' was already executed. Repeating identical actions or oscillating cycles without parameter changes is strictly prohibited. Modify your parameters or select an alternative tool.]"
                        jq --arg a "$rep_adv" '. += [{"role": "user", "content": $a}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                    elif [ "$rep_strike" -eq 2 ]; then
                        _react_circuit_breaker_perturbation "$session_id" "$workdir" "ACTION_REPETITION" "$c_name ($c_args)" "Action repetition strike 2" "$messages_file" "$macro_file"
                    fi

                    local target_path=""
                    [[ "$c_name" =~ file_read|file_grep|file_outline|code_symbol_get|file_edit|file_write ]] && target_path=$(jq -r '.path // empty' <<<"$c_args" 2>/dev/null)
                    if [ -n "$target_path" ]; then
                        if [ "$_p1_idx" -eq 0 ]; then
                            if [ "$target_path" = "$last_inspected_path" ]; then same_target_path_streak=$((same_target_path_streak + 1))
                            else same_target_path_streak=1; last_inspected_path="$target_path"
                            fi
                            local max_path_streak=$(declare -f limits_get &>/dev/null && limits_get CIRCUIT_BREAKER_MAX_PATH_STREAK 7 || echo "${CIRCUIT_BREAKER_MAX_PATH_STREAK:-7}")
                            local path_streak_adv_threshold=$(( max_path_streak - 2 ))
                            [ "$path_streak_adv_threshold" -lt 3 ] && path_streak_adv_threshold=3
                            if [ "$same_target_path_streak" -ge "$max_path_streak" ]; then
                                ui_warn "[CIRCUIT BREAKER] Target path repetition ceiling reached on $target_path (Streak: $same_target_path_streak). Tripping circuit breaker / perturbation."
                                _react_circuit_breaker_perturbation "$session_id" "$workdir" "TARGET_FILE_THRASHING" "$c_name ($target_path)" "Repeated file inspection on $target_path without task advancement" "$messages_file" "$macro_file"
                            elif [ "$same_target_path_streak" -ge "$path_streak_adv_threshold" ]; then
                                local path_adv="[CIRCUIT ADVISORY: Target file '$target_path' has been inspected multiple times in a row. Cease linear paging or repeated inspection of this file. Synthesize your findings or call the domain-specific tool required by the active Honeydew milestone.]"
                                _react_steer "$path_adv" "$messages_file"
                            fi
                        fi
                    else
                        [ "$_p1_idx" -eq 0 ] && { same_target_path_streak=0; last_inspected_path=""; }
                    fi

                    ui_step "Native Tool Call: $c_name (parallel)"
                    [ -n "${history_file:-}" ] && echo "Tool Call: $c_name ($c_args)" >> "$history_file"
                    declare -f transcript_log &>/dev/null && transcript_log "tool_call" "$c_name: $c_args"

                    # Domain check
                    local _sc_cls=""
                    if [[ "$c_name" =~ (fetch|scrape|browse|web_read) ]] && declare -f react_envelope_failed_domain_check &>/dev/null; then
                        local _sc_url; _sc_url=$(jq -r '.url // .link // .uri // empty' <<<"$c_args" 2>/dev/null)
                        _sc_cls=$(react_envelope_failed_domain_check "$session_dir" "$(react_envelope_url_domain "$_sc_url")")
                    fi

                    # Strict tool / profile policy check
                    local _policy_blocked=0 _policy_resp=""
                    if [ -z "$_sc_cls" ] && { [ "${REACT_STRICT_TOOLS:-0}" = "1" ] || [ "${tool_filter:-}" = "model_hub" ] || [ "${tool_filter:-}" = "social_untrusted" ] || [ "${tool_filter:-}" = "untrusted_social" ]; }; then
                        if ! jq -e --arg n "$c_name" 'any(.[]?; .function.name == $n)' <<<"${tools_schema:-[]}" >/dev/null 2>&1; then
                            _policy_blocked=1
                            local _rep_err=""
                            if [ "${tool_filter:-}" = "social_untrusted" ] || [ "${tool_filter:-}" = "untrusted_social" ] || [ -n "${DISCORD_CURRENT_AUTHOR_REP:-}" ]; then
                                local _auth_name="${DISCORD_CURRENT_AUTHOR_NAME:-user}"
                                local _auth_rep="${DISCORD_CURRENT_AUTHOR_REP:-unknown}"
                                local _min_rep="${DISCORD_OPS_MIN_REPUTATION:-50}"
                                _rep_err="ERROR: Tool '${c_name}' is restricted by system policy. Author @${_auth_name} has Reputation Score ${_auth_rep} (< ${_min_rep} required for host execution). You must not retry this tool. Please inform @${_auth_name} that their reputation level restricts access to '${c_name}' and provide a conversational response or summarize what information you can retrieve."
                            else
                                _rep_err="ERROR: tool ${c_name} is not available in this profile. Use only the tools you were given."
                            fi
                            _policy_resp=$(jq -nc --arg id "$c_id" --arg name "$c_name" --arg content "$_rep_err" \
                                '{role: "tool", tool_call_id: $id, name: $name, exit_code: 1, content: $content}')
                        fi
                    fi

                    # Cache check
                    local from_cache=0 cache_key="" cache_ns=""
                    if [ -z "$_sc_cls" ] && [ "$_policy_blocked" -eq 0 ] && _react_tool_is_cacheable "$c_name"; then
                        cache_key=$(_react_tool_cache_key "$c_name" "$c_args")
                        cache_ns=$(_react_tool_cache_ns "$c_name")
                        if declare -f cache_get &>/dev/null && cache_get "$cache_key" "$cache_ns" >/dev/null 2>&1; then
                            from_cache=1
                        fi
                    fi

                    if [ "$_policy_blocked" -eq 1 ]; then
                        p1_is_cached[$_p1_idx]=3 # policy blocked
                        p1_cached_resp[$_p1_idx]="$_policy_resp"
                        p1_prom_ids[$_p1_idx]=""
                        p1_t0_ms[$_p1_idx]=0
                    elif [ "$from_cache" -eq 1 ]; then
                        p1_is_cached[$_p1_idx]=1
                        local _c_val
                        _c_val=$(cache_get "$cache_key" "$cache_ns" 2>/dev/null)
                        p1_cached_resp[$_p1_idx]=$(jq -nc --arg id "$c_id" --arg name "$c_name" --arg content "$_c_val" '{role: "tool", tool_call_id: $id, name: $name, content: ("[CACHED OBSERVATION (0ms)]\n" + $content)}')
                        p1_prom_ids[$_p1_idx]=""
                        p1_t0_ms[$_p1_idx]=0
                    elif [ -n "$_sc_cls" ]; then
                        p1_is_cached[$_p1_idx]=2 # domain blocked
                        p1_cached_resp[$_p1_idx]=""
                        p1_prom_ids[$_p1_idx]=""
                        p1_t0_ms[$_p1_idx]=0
                    else
                        p1_is_cached[$_p1_idx]=0
                        local _t_start_ms
                        _t_start_ms=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
                        p1_t0_ms[$_p1_idx]="$_t_start_ms"

                        local call_cid="${session_id}_tc_${c_id//[^A-Za-z0-9_.-]/_}"
                        local _q_cid _q_sid _q_id _q_name _q_args _q_wd
                        printf -v _q_cid '%q' "$call_cid"; printf -v _q_sid '%q' "$session_id"
                        printf -v _q_id '%q' "$c_id"; printf -v _q_name '%q' "$c_name"
                        printf -v _q_args '%q' "$c_args"; printf -v _q_wd '%q' "$workdir"
                        local prom_id
                        prom_id=$(fifo_async "$call_cid" "export IPC_CHANNEL=$_q_cid; export AGENT_ACTIVE_TASK_ID=$_q_sid; native_tools_dispatch $_q_id $_q_name $_q_args $_q_wd" "$c_id" "$c_name" "$c_args")
                        p1_prom_ids[$_p1_idx]="$prom_id"
                    fi
                    _p1_idx=$((_p1_idx + 1))
                done

                # Filter active async promise IDs for barrier join
                local -a _active_proms=()
                for _pid in "${p1_prom_ids[@]}"; do
                    [ -n "$_pid" ] && _active_proms+=("$_pid")
                done

                if [ "${#_active_proms[@]}" -gt 0 ]; then
                    ui_step "Barrier: Awaiting ${#_active_proms[@]} concurrent read tool promises (Settled-All)..."
                    fifo_await_all_settled "$as_timeout" "${_active_proms[@]}"
                fi

                # Ingest Phase 1 observations in emission order
                _p1_idx=0
                for _call in "${p1_calls[@]}"; do
                    local c_id c_name c_args tool_resp="" await_ec=0 _react_t_dur=0 from_cache=0
                    c_id=$(jq -r '.id' <<<"$_call")
                    c_name=$(jq -r '.function.name' <<<"$_call")
                    c_args=$(jq -r '.function.arguments' <<<"$_call")

                    if [ "${p1_is_cached[$_p1_idx]:-0}" -eq 1 ]; then
                        tool_resp="${p1_cached_resp[$_p1_idx]}"
                        from_cache=1
                        await_ec=0
                        _react_t_dur=0
                    elif [ "${p1_is_cached[$_p1_idx]:-0}" -eq 3 ]; then
                        tool_resp="${p1_cached_resp[$_p1_idx]}"
                        from_cache=2
                        await_ec=1
                        _react_t_dur=0
                    elif [ "${p1_is_cached[$_p1_idx]:-0}" -eq 2 ]; then
                        tool_resp=$(jq -nc --arg id "$c_id" --arg name "$c_name" '{role: "tool", tool_call_id: $id, name: $name, exit_code: 1, content: "ERROR: Domain previously failed circuit breaker check"}')
                        from_cache=2
                        await_ec=1
                        _react_t_dur=0
                    else
                        local prom_id="${p1_prom_ids[$_p1_idx]}"
                        local _t_end_ms
                        _t_end_ms=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
                        _react_t_dur=$(( _t_end_ms - ${p1_t0_ms[$_p1_idx]:-$_t_end_ms} ))
                        [ "$_react_t_dur" -lt 0 ] 2>/dev/null && _react_t_dur=0

                        tool_resp=$(fifo_await "$prom_id" 0 2>&1)
                        await_ec=$?
                        rm -f "${FIFO_IPC_DIR:-${gdir}/ipc}/promises/${prom_id}"* 2>/dev/null || true

                        if [ "$await_ec" -eq 124 ]; then
                            tool_resp=$(jq -nc --arg id "$c_id" --arg name "$c_name" --arg timeout "$as_timeout" '{role: "tool", tool_call_id: $id, name: $name, exit_code: 124, content: ("ERROR: Tool execution timed out after " + $timeout + "s")}')
                        elif [ "$await_ec" -ne 0 ] && [ -z "$tool_resp" ]; then
                            tool_resp=$(jq -nc --arg id "$c_id" --arg name "$c_name" --arg ec "$await_ec" '{role: "tool", tool_call_id: $id, name: $name, exit_code: ($ec|tonumber), content: ("ERROR: Tool execution crashed or terminated prematurely (exit code: " + $ec + ")")}')
                        fi
                    fi

                    local _REACT_SKIP_BATCH_EVAL=0
                    if [ "${#p2_calls[@]}" -gt 0 ] || [ $(( _p1_idx + 1 )) -lt "${#p1_calls[@]}" ]; then
                        _REACT_SKIP_BATCH_EVAL=1
                    fi
                    _react_postprocess_observation "$c_id" "$c_name" "$c_args" "$tool_resp" "$await_ec" "$_react_t_dur" "$from_cache" "$turn_max_chars" "$num_turn_calls"
                    _p1_idx=$((_p1_idx + 1))
                    [ "$tool_exhausted" -eq 1 ] && break
                done
            else
                # Fallback or single Phase 1 call: run serially
                for _call in "${p1_calls[@]}"; do
                    _react_execute_single_tool_step "$_call" "$turn_max_chars" "$num_turn_calls"
                    [ "$tool_exhausted" -eq 1 ] && break
                done
            fi

            # ── Phase 2: Serial Mutation Queue ──
            if [ "$tool_exhausted" -eq 0 ] && [ "${#p2_calls[@]}" -gt 0 ]; then
                [ "${#p1_calls[@]}" -gt 0 ] && ui_step "Adaptive Barrier Phase 2: Draining ${#p2_calls[@]} mutating tools serially"
                for _call in "${p2_calls[@]}"; do
                    _react_execute_single_tool_step "$_call" "$turn_max_chars" "$num_turn_calls"
                    [ "$tool_exhausted" -eq 1 ] && break
                done
            fi

            _REACT_IN_TOOL_LOOP=0; _react_steer_flush "$messages_file"

            [ "$tool_exhausted" -eq 1 ] && { _rl_outcome="TOOL_FAIL"; _rl_reason="${_rl_last_breaker:-tool strike ceiling}"; return 1; }
            consecutive_empty_turns=0; consecutive_premature_plans=0; turn=$((turn + 1)); continue
        fi

        # ── Branch 2: Model Outputted Content / Fallback Slash Command
        [ -n "$raw_content" ] && echo "$raw_content"
        local action=$(_react_parse_action "$raw_content")

        if [[ "$action" == /respond* ]]; then
            local answer="${action#/respond}"; answer="${answer#"${answer%%[![:space:]]*}"}"
            declare -f _subagent_log_event &>/dev/null && [ -n "${_SUBAGENT_ACTIVE_ID:-}" ] && _subagent_log_event "$_SUBAGENT_ACTIVE_ID" "RESULT" "$answer"
            echo ""; ui_ok "Task Complete!"
            printf "${C_BOLD}${C_GREEN}%s${C_RESET}\n" "$answer"
            _react_carry_forward "$session_dir" "$answer" > "$session_dir/final_reply.txt" 2>/dev/null || true
            _rl_outcome="SUCCESS"
            jq --arg ans "$answer" '. += [{"role": "assistant", "content": $ans}]' "$messages_file" > "${messages_file}.tmp" 2>/dev/null && mv "${messages_file}.tmp" "$messages_file" 2>/dev/null || true
            journal_write "reflection" "Goal achieved: $goal. Result: $answer" 2>/dev/null || true
            declare -f transcript_log_block &>/dev/null && transcript_log_block "final_response" "$answer"
            _react_trace "$workdir" "task_complete" "$(jq -cn --arg goal "$goal" --arg outcome "$answer" '{goal:$goal, outcome:$outcome, status:"success"}')"
            jq '.status = "COMPLETED"' "$macro_file" > "${macro_file}.tmp" 2>/dev/null && mv "${macro_file}.tmp" "$macro_file" 2>/dev/null || true
            declare -f telemetry_task_end &>/dev/null && telemetry_task_end "$session_id" 0 "COMPLETED" >/dev/null 2>&1 || true
            export AGENT_ACTIVE_SESSION_ID=""
            if declare -f transcript_stop &>/dev/null && transcript_active 2>/dev/null; then
                local tp=$(transcript_stop); [ -n "$tp" ] && ui_dim "  Transcript: $tp"
            fi
            declare -f fifo_channel_close &>/dev/null && fifo_channel_close "$session_id" 2>/dev/null || true
            return 0
        fi

        if [[ "$action" == /delegate* ]]; then
            local del_args="${action#/delegate}"; del_args="${del_args#"${del_args%%[![:space:]]*}"}"
            local del_tier="${del_args%% *}" del_task="${del_args#* }"
            ui_info "Delegating to Tier $del_tier: $del_task"
            declare -f transcript_log &>/dev/null && transcript_log "delegate" "Tier $del_tier: $del_task"
            local sub_obs=$(subagents_spawn "$del_tier" "$del_task" "Parent Goal: $goal" "$workdir" 2>&1)
            declare -f transcript_log_block &>/dev/null && transcript_log_block "subagent_output" "$sub_obs"
            jq --arg obs "Subagent Tier $del_tier Output:\n$sub_obs" '. += [{"role": "user", "content": $obs}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
            turn=$((turn + 1)); continue
        fi

        if [ -n "$action" ]; then
            local fb_hash=$(_react_action_hash "fallback_cmd" "$action")
            local fb_strike=$(_react_check_repetition "$session_dir" "$fb_hash" "fallback_cmd" "$action")
            if [ "$fb_strike" -ge 3 ]; then
                local fb_heal=0
                _react_self_heal_circuit_breaker "$session_id" "$workdir" "$session_dir" "fallback_cmd" "$action" "$messages_file" "$macro_file" "$fb_strike"; fb_heal=$?
                [ "$fb_heal" -ne 0 ] && { export AGENT_ACTIVE_SESSION_ID=""; return "$fb_heal"; }
            elif [ "$fb_strike" -eq 1 ]; then
                jq --arg a "[CIRCUIT ADVISORY: Fallback command '$action' was already executed. Repeating identical commands without parameter changes is strictly prohibited. Modify your parameters or proceed to other actions.]" '. += [{"role": "user", "content": $a}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
            elif [ "$fb_strike" -eq 2 ]; then
                _react_circuit_breaker_perturbation "$session_id" "$workdir" "ACTION_REPETITION" "$action" "Fallback repetition strike 2" "$messages_file" "$macro_file"
            fi

            ui_step "Executing fallback command: $action"
            echo "Action: $action" >> "$history_file"
            declare -f _subagent_log_event &>/dev/null && [ -n "${_SUBAGENT_ACTIVE_ID:-}" ] && _subagent_log_event "$_SUBAGENT_ACTIVE_ID" "ACTION" "$action"
            declare -f transcript_log &>/dev/null && transcript_log "command" "$action"

            local obs=$(commands_dispatch "$action" "$workdir" 2>&1)
            local exit_code=$?
            if echo "$action" | grep -qE '\b(edit|write|patch|commit|push|git|rm|mv|touch|sed)'; then
                declare -f cache_invalidate_ns &>/dev/null && cache_invalidate_ns "files"
                declare -f cache_invalidate_ns &>/dev/null && cache_invalidate_ns "git"
            fi
            if [ "$exit_code" -ne 0 ]; then
                declare -f telemetry_record_anomaly &>/dev/null && telemetry_record_anomaly "$session_id" "SHELL_RUNTIME" "$action" "Fallback command failed with exit $exit_code: ${obs:0:200}" >/dev/null 2>&1 || true
                declare -f telemetry_triage_operational_failure &>/dev/null && telemetry_triage_operational_failure "$action" "SHELL_RUNTIME" "Fallback command execution failure ($action)" "${obs:0:500}" "$workdir" >/dev/null 2>&1 || true
            fi
            obs=$(printf '%s\n' "$obs" | sed -r 's/\x1B\[[0-9;]*[a-zA-Z]//g')
            local max_fb="${REACT_MAX_OBSERVATION_CHARS:-32000}"
            # F3: Hard bound — per-obs cap must not exceed window/8 (tokens*4 = chars)
            local _fb_hard_max=$(( ${ACTIVE_ENDPOINT_CONTEXT:-131072} / 8 * 4 ))
            [ "$max_fb" -gt "$_fb_hard_max" ] 2>/dev/null && max_fb="$_fb_hard_max"
            [ ${#obs} -gt "$max_fb" ] && obs="${obs:0:$max_fb}\n... [truncated]"
            declare -f transcript_log_block &>/dev/null && transcript_log_block "output ($action)" "$obs"
            _react_trace "$workdir" "fallback_command" "$(jq -cn --arg cmd "$action" '{cmd:$cmd}')"
            jq --arg obs "Command $action (exit $exit_code):\n$obs" '. += [{"role": "user", "content": $obs}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
            turn=$((turn + 1)); continue
        fi

        if [ -n "$raw_content" ]; then
            if [[ "$raw_content" =~ \<tool_call|\<function ]]; then
                ui_warn "  [guard] Intercepted raw tool call text in conversational output; enforcing tool execution."
                jq --arg ans "$raw_content" '. += [{"role": "assistant", "content": $ans}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                jq --arg p "[SYSTEM ADVISORY: You outputted an unexecuted tool call text. Execute the tool properly or synthesize your final deliverable from the scratchpad without tool tags.]" '. += [{"role": "user", "content": $p}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                turn=$((turn + 1)); continue
            fi

            local active_intent="$goal"
            if [[ "$active_intent" == *"<conversation_history>"* ]]; then
                active_intent="${active_intent%%<conversation_history>*}"
            fi
            local active_intent_lower="${active_intent,,}"

            local is_premature_plan=0 has_prior_tool_execution=0
            [ -f "$history_file" ] && grep -qE "(Tool Call:|Action:)" "$history_file" && has_prior_tool_execution=1
            if [ "$max_turns" -gt 1 ] && [ "$has_prior_tool_execution" -eq 0 ]; then
                local trimmed_tail="${raw_content%"${raw_content##*[![:space:]]}"}"
                if [ "${AGENT_SOVEREIGN_REMEDIATION:-0}" -eq 1 ] && [ "$turn" -lt 5 ]; then is_premature_plan=1
                elif echo "$raw_content" | grep -qiE "(I will|I'll|I plan to|Let's outline|Step 1|First step|I need to check|I need to inspect|Let's begin by|Before making changes|I will pull|I'll pull|Let me fetch|I am going to|I'm going to|I will search|I'll search|Let me pull|I'll gather|I will gather|I'll start by|I will start by|Let me survey|Let me inspect|Let me explore|Let me examine|I will examine|I'll look at|ground this in|survey what is|Let me now|Let me proceed|I will now|Next step|Proceeding to|I will execute|Let me execute)"; then is_premature_plan=1
                elif [[ "$trimmed_tail" == *: ]]; then is_premature_plan=1
                elif [ ${#raw_content} -lt 450 ] && echo "$raw_content" | grep -qiE "\b(will pull|will fetch|will search|will look up|will inspect|will check|will investigate|going to search|going to pull|going to fetch|going to ground|execute real tool|call tools|invoke tools|execute tool)\b"; then is_premature_plan=1
                fi
                if [[ "${tool_filter:-}" =~ ^(social|chat)$ ]] || [[ "$active_intent_lower" =~ ^[[:space:]]*(thanks|thank\ you|thx|ty|cheers|hi|hello|hey|gm|gn|good\ morning|sup|yo|ok|okay|sounds\ good)\b ]]; then
                    is_premature_plan=0
                fi
            fi

            local is_unverified_research=0
            if [ "$turn" -le 2 ] && [ "$max_turns" -gt 1 ]; then
                local is_res=0
                if ! echo "$active_intent_lower" | grep -qiE '\b(status|inspect|check|phytology|audit|health)\b'; then
                    if echo "$active_intent_lower" | grep -qiE '\b(research|dossier|background on|investigate|due diligence|osint|deep dive|fact check)\b'; then is_res=1
                    elif [[ "${tool_filter:-}" =~ research ]] && echo "$active_intent_lower" | grep -qiE '\b(research|dossier|background|investigate|due diligence|osint|latest|recent|news|current)\b'; then is_res=1
                    fi
                fi
                if [ "$is_res" -eq 1 ]; then
                    if [ ! -f "$history_file" ] || ! grep -qE "(Tool Call: web_|Tool Call: fetch|Tool Call: pdf_read|Tool Call: file_read|Tool Call: github_search|Tool Call: phytology_manage|Action: .*web|Action: .*curl|Action: .*search)" "$history_file"; then
                        is_unverified_research=1
                    fi
                fi
            fi

            local is_unverified_code=0
            if [ "$max_turns" -gt 1 ]; then
                local is_code=0
                echo "$active_intent_lower" | grep -qiE '\b(extend|implement|develop|fix|refactor|test|patch|code|write|create|build|modify|feature|graft|remediat|branch|pr|pull request|commit)\b' && is_code=1
                echo "$active_intent_lower" | grep -qiE '\b(inspect|status|verify|check|audit|report on|overview of)\b' && ! echo "$active_intent_lower" | grep -qiE '\b(implement|create|extend|build|fix|write|modify|refactor|patch|branch)\b' && is_code=0
                # If the goal is a synthesis, summary, or report task (e.g. "write up a summary of today's news"),
                # it is a research/prose deliverable, not a software code implementation.
                if echo "$active_intent_lower" | grep -qiE '\b(write\s+(up\s+)?(a\s+)?(summary|report|analysis|dossier|overview|essay|brief|article|update|response|reply)|summary of|news from)\b'; then
                    if ! echo "$active_intent_lower" | grep -qiE '\b(code|script|test|function|class|method|module|unit|endpoint|api|pr|git)\b'; then
                        is_code=0
                    fi
                fi
                # Incident 2026-10-05 (WoW "Patch 12.2" run, post-mortem D1): a domain word
                # like "patch", "test" or "build" inside a conversational question must not
                # classify a chat/research goal as a code task. Only count code intent when
                # the goal names real code or ops artifacts — or when the profile is code.
                if [ "$is_code" -eq 1 ]; then
                    if [[ "${tool_filter:-}" =~ ^(chat|social)$ ]]; then
                        is_code=0
                    elif ! echo "$active_intent_lower" | grep -qiE '(repo(sitory)?|workspace|codebase|files?|scripts?|\bsrc\b|\.rs\b|\.py\b|\.sh\b|gitea|git checkout|git commit|pull request|symbol_|bash_exec|file_write|cargo|pytest|npm run|\bapi\b|endpoint|server|service|container|docker|kubernetes|database|cron|bug|failing|error|crash|broken|stack ?trace|regression)' \
                       && echo "$active_intent_lower" | grep -qiE '(^|\b)(how|what|why|when|where|who|are|is|was|were)\b|\?$|shaping up|status of|what.s (up|new|the deal)|latest (on|news)|current (status|state)|recap|explain|summar'; then
                        is_code=0
                    fi
                fi
                # Strictly force is_code to 0 on social/chat runs or conversational greetings/thanks
                local _task_t=""
                [ -f "$hd_file" ] && _task_t=$(jq -r '.task_type // empty' "$hd_file" 2>/dev/null || true)
                if [[ "${tool_filter:-}" =~ ^(chat|social)$ ]] || [ "$_task_t" = "chat" ] || [ "$_task_t" = "social" ] || [[ "$active_intent_lower" =~ ^[[:space:]]*(thanks|thank\ you|thx|ty|cheers|hi|hello|hey|gm|gn|good\ morning|sup|yo|ok|okay|sounds\ good)\b ]]; then
                    is_code=0
                fi
                if [ "$is_code" -eq 1 ]; then
                    if [ ! -f "$history_file" ] || ! grep -qE "(Tool Call: file_write|Tool Call: file_edit|Tool Call: symbol_patch|Tool Call: git_commit|Tool Call: git_push|Tool Call: gitea_pr|Tool Call: gitea_issue_close|Tool Call: phytology_manage|Tool Call: slash_command_exec|Action: .*phytology|Action: .*commit|Action: .*push|git checkout -b|git commit|git branch feature)" "$history_file"; then
                        local has_mutating_bash=0
                        if [ -f "$history_file" ]; then
                            while IFS= read -r bh_line; do
                                if echo "$bh_line" | grep -qiE '(chmod|touch|mkdir|cp|mv|rm|sed|python.*test|cargo|npm|pytest|bash\ -n|\.sh\b)'; then
                                    has_mutating_bash=1; break
                                fi
                            done < <(grep -E "Tool Call: bash_exec" "$history_file" 2>/dev/null || true)
                        fi
                        [ "$has_mutating_bash" -eq 0 ] && is_unverified_code=1
                    fi
                fi
            fi

            # Incident 2026-10-05 (post-mortem D2): a substantive pure-text answer intercepted by
            # an advisory below used to be lost — only the tool-call branch recorded drafts. Keep
            # the longest draft on file so _react_carry_forward can restore it if the final turn
            # ends up being a fragment. (No auto-post here: an un-intercepted turn IS the final
            # reply and would be double-delivered.)
            [ ${#raw_content} -ge "$REACT_DRAFT_MIN_CHARS" ] && _react_note_draft "$session_dir" "$raw_content"

            if [ "$is_premature_plan" -eq 1 ]; then
                consecutive_premature_plans=$((consecutive_premature_plans + 1))
                if [ "$consecutive_premature_plans" -ge 5 ]; then
                    ui_err "  [guard] Circuit breaker: 5 consecutive turns produced planning monologues without tool execution. Halting runaway loop."
                    _react_trace "$workdir" "circuit_breaker_premature_loop" '{"turns": '"$turn"', "consecutive_premature": '"$consecutive_premature_plans"'}'
                    break
                fi
                if [ "$consecutive_premature_plans" -ge 3 ]; then
                    ui_warn "  [guard] Premature planning loop detected ($consecutive_premature_plans turns). Pruning advisory history and enforcing immediate tool execution."
                    python3 -c 'import sys, json; p = sys.argv[1]; msgs = [m for m in json.load(open(p)) if not (isinstance(m.get("content"), str) and "[SYSTEM ADVISORY:" in m["content"])]; json.dump(msgs, open(p, "w"))' "$messages_file" 2>/dev/null || true
                fi
                jq --arg ans "$raw_content" '. += [{"role": "assistant", "content": $ans}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                local adv="[SYSTEM ADVISORY: Plan acknowledged. Proceed immediately to execute your plan by calling the required native tools (e.g. bash_exec, file_write, file_read, research_sandbox). Emit conversational markdown ONLY when all tool actions are complete and the deliverable is 100% finished.]"
                [ "$consecutive_premature_plans" -ge 2 ] && adv="[SYSTEM ADVISORY: Execute your tool call now. Invoke bash_exec, file_write, or research_sandbox directly. Do not output text preambles or planning sentences.]"
                jq --arg p "$adv" '. += [{"role": "user", "content": $p}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                consecutive_empty_turns=0; turn=$((turn + 1)); continue
            elif [ "$is_unverified_research" -eq 1 ]; then
                ui_dim "  [guard] Intercepted Turn $turn draft: zero research tools executed for research task"
                jq --arg ans "$raw_content" '. += [{"role": "assistant", "content": $ans}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                jq --arg p "[SYSTEM ADVISORY: Research verification required. You produced a draft summary on Turn $turn without executing any retrieval tools (web_search, web_fetch, pdf_read, file_read). You MUST call web_search to find primary or credible secondary sources and call web_fetch to extract facts before declaring this task complete. Do not simulate or fabricate citations.]" '. += [{"role": "user", "content": $p}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                consecutive_empty_turns=0; turn=$((turn + 1)); continue
            elif [ "$is_unverified_code" -eq 1 ] && [ "${unverified_code_hits:-0}" -lt 1 ]; then
                # Incident 2026-10-05 (post-mortem D1): the advisory fired twice on the same run
                # and consumed the turns that would have delivered the answer. One strike per run —
                # after it, let the conversational reply through (mirrors the hd_guard_hits cap).
                unverified_code_hits=$(( ${unverified_code_hits:-0} + 1 ))
                ui_dim "  [guard] Intercepted Turn $turn draft: zero implementation/execution tools executed for code task"
                jq --arg ans "$raw_content" '. += [{"role": "assistant", "content": $ans}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                jq --arg p "[SYSTEM ADVISORY: Implementation verification required. You produced a conversational response on Turn $turn without executing any code implementation or execution tools (file_read, file_write, bash_exec, symbol_patch, git_*). You MUST execute the required code changes, run tests, and perform git operations in the workspace using your native tools before declaring this task complete. Proceed immediately to tool execution.]" '. += [{"role": "user", "content": $p}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                if [ -f "$hd_file" ]; then
                    local last_aid=$(jq -r '[.items[]? | select(.task | test("synthesize|deliver|report|respond"; "i") | not)][-1].id // empty' "$hd_file" 2>/dev/null)
                    [ -n "$last_aid" ] && jq --argjson aid "$last_aid" '(.items[] | select(.id == $aid)).status = "pending"' "$hd_file" > "${hd_file}.tmp" 2>/dev/null && mv "${hd_file}.tmp" "$hd_file"
                fi
                consecutive_empty_turns=0; turn=$((turn + 1)); continue
            fi

            # Guard against premature termination when Honeydew action milestones remain uncompleted
            local pending_steps_cnt=0
            if [ -f "$hd_file" ]; then
                # If a Tier B trade plan (P-XXXXXX) was built in this session and is being presented in raw_content,
                # mark any remaining milestones as done so the operator gets the plan immediately!
                if [[ "$raw_content" =~ [Pp]-[0-9A-Fa-f]{6} ]] && [ -f "$history_file" ] && grep -qE "Tool Call: (crypto_plan|crypto_standing_order)" "$history_file" 2>/dev/null; then
                    jq '(.items[]? | select(.status != "done")).status = "done"' "$hd_file" > "${hd_file}.tmp" 2>/dev/null && mv "${hd_file}.tmp" "$hd_file"
                fi
                pending_steps_cnt=$(_react_pending_action_steps "$hd_file")
            fi
            local _hd_generic_only=0
            if [ "$pending_steps_cnt" -gt 0 ] && [ -f "$hd_file" ]; then
                jq -e '[.items[]? | select(.status != "done") | .task | select(test("^(Step [0-9]+: )?(Execute targeted action to fulfill the objective|Synthesize results and deliver final response)"; "i") | not)] | length == 0' "$hd_file" >/dev/null 2>&1 && _hd_generic_only=1
            fi
            # Exempt: chat profile, generic fallback plans, and after 2 interceptions (prevents answer-suppression loops)
            local _task_type_guard=""
            [ -f "$hd_file" ] && _task_type_guard=$(jq -r '.task_type // empty' "$hd_file" 2>/dev/null || true)
            if [ "$pending_steps_cnt" -gt 0 ] && [ "$turn" -lt "$max_turns" ] && [ "${hd_guard_hits:-0}" -lt 2 ] \
               && [ "$_hd_generic_only" -eq 0 ] && [[ ! "${tool_filter:-}" =~ ^(chat|social)$ ]] \
               && [ "$_task_type_guard" != "chat" ] && [ "$_task_type_guard" != "social" ] \
               && ! [[ "$active_intent_lower" =~ ^[[:space:]]*(thanks|thank\ you|thx|ty|cheers|hi|hello|hey|gm|gn|good\ morning|sup|yo|ok|okay|sounds\ good)\b ]]; then
                hd_guard_hits=$(( ${hd_guard_hits:-0} + 1 ))
                local next_pending_step
                next_pending_step=$(jq -r '[.items[]? | select(.status != "done")][0] | if . then "Step " + (.id|tostring) + ": " + .task else "Next Milestone" end' "$hd_file" 2>/dev/null)
                ui_dim "  [guard] Intercepted intermediate commentary: pending milestone '$next_pending_step' not completed ($pending_steps_cnt remaining)"
                jq --arg ans "$raw_content" '. += [{"role": "assistant", "content": $ans}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                _react_note_draft "$session_dir" "$raw_content"
                local _guard_dir="[SYSTEM DIRECTIVE: Intermediate report recorded, but task is not complete. The Honeydew execution plan has pending milestones remaining: '$next_pending_step'. Proceed immediately to execute this milestone using the appropriate native tool (e.g. file_write, file_edit, bash_exec). Do not conclude with conversational text until all milestones are finished.]"
                if _react_post_draft "$session_dir" "$raw_content"; then
                    ui_ok "  [guard] Discord run: posted the intercepted report to the channel (${#raw_content} chars)."
                    local non_research_pending=0
                    [ -f "$hd_file" ] && non_research_pending=$(jq -r '[.items[]? | select(.status != "done" and (((.task | test("^(Step [0-9]+: )?(create|build|write|implement|run|test|execute|modify|patch|refactor|deploy)\\b"; "i")) and ((.task | test("^(Step [0-9]+: )?(research|search|analyze|synthesize|conclude|deliver)\\b"; "i")) | not))))] | length' "$hd_file" 2>/dev/null || echo 0)
                    if [ "$non_research_pending" -eq 0 ] && [ "${#raw_content}" -ge 1200 ]; then
                        ui_ok "  [guard] Delivered comprehensive report (${#raw_content} chars) covering all research milestones. Task complete!"
                        jq '(.items[]? | select(.status != "done")).status = "done"' "$hd_file" > "${hd_file}.tmp" 2>/dev/null && mv "${hd_file}.tmp" "$hd_file"
                        pending_steps_cnt=0
                    else
                        _guard_dir="[SYSTEM NOTICE: Your report above has been POSTED to the Discord channel — the user can read it now. Pending plan step: '$next_pending_step'. Do it only if it adds something the user needs (use discord_send for follow-ups or discord_edit to correct). Do not repeat the report; when finished, end with a short closing line.]"
                    fi
                fi
                if [ "$pending_steps_cnt" -gt 0 ]; then
                    jq --arg p "$_guard_dir" '. += [{"role": "user", "content": $p}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
                    consecutive_empty_turns=0; turn=$((turn + 1)); continue
                fi
            fi

            [ -f "$hd_file" ] && jq '(.items[]? | select(.status != "done")).status = "done"' "$hd_file" > "${hd_file}.tmp" 2>/dev/null && mv "${hd_file}.tmp" "$hd_file"
            echo ""; ui_ok "Task Complete!"
            local _final_out
            _final_out=$(_react_carry_forward "$session_dir" "$raw_content")
            [ "$_final_out" != "$raw_content" ] && ui_dim "  [carry-forward] Final answer pointed back at an earlier draft; delivering the draft with it."
            printf '%s\n' "$_final_out" > "$session_dir/final_reply.txt" 2>/dev/null || true
            _rl_outcome="SUCCESS"
            jq --arg ans "$raw_content" '. += [{"role": "assistant", "content": $ans}]' "$messages_file" > "${messages_file}.tmp" 2>/dev/null && mv "${messages_file}.tmp" "$messages_file" 2>/dev/null || true
            journal_write "reflection" "Completed task: $goal. Summary: ${raw_content:0:200}" 2>/dev/null || true
            declare -f transcript_log_block &>/dev/null && transcript_log_block "final_response" "$raw_content"
            _react_trace "$workdir" "task_complete" "$(jq -cn --arg goal "$goal" --arg summary "${raw_content:0:200}" '{goal:$goal, summary:$summary, status:"success"}')"
            jq '.status = "COMPLETED"' "$macro_file" > "${macro_file}.tmp" 2>/dev/null && mv "${macro_file}.tmp" "$macro_file" 2>/dev/null || true
            echo "Completed" > "$session_dir/.phase" 2>/dev/null || true
            touch "$session_dir/.done" 2>/dev/null || true
            if [ -d "${LODGE_DIR}/.sandboxes/${session_id}" ]; then
                echo "Completed" > "${LODGE_DIR}/.sandboxes/${session_id}/.phase" 2>/dev/null || true
                touch "${LODGE_DIR}/.sandboxes/${session_id}/.done" 2>/dev/null || true
            fi
            declare -f memory_register_files &>/dev/null && memory_register_files "$workdir"
            declare -f telemetry_task_end &>/dev/null && telemetry_task_end "$session_id" 0 "COMPLETED" >/dev/null 2>&1 || true
            declare -f agent_sm_transition &>/dev/null && agent_sm_transition "$session_id" "DONE" "Task completed successfully" 2>/dev/null || true
            declare -f fifo_channel_close &>/dev/null && fifo_channel_close "$session_id" 2>/dev/null || true
            declare -f agent_sm_cull &>/dev/null && agent_sm_cull "$session_id" "Task completed successfully" >/dev/null 2>&1 || true
            export AGENT_ACTIVE_SESSION_ID=""
            if [ "${REACT_KEEP_TRANSCRIPT:-0}" -ne 1 ]; then
                if declare -f transcript_stop &>/dev/null && transcript_active 2>/dev/null; then
                    local tp=$(transcript_stop); [ -n "$tp" ] && ui_dim "  Transcript: $tp"
                fi
            fi
            return 0
        fi

        if [ -z "$raw_content" ] && [ -n "$reasoning" ]; then
            # P2.10: if the in-turn COT retry already persisted the deliberation
            # and issued the forced-action advisory, skip the duplicate append.
            if [ "${_cot_retry_used:-0}" -eq 0 ]; then
            jq --argjson m "$(jq -nc --arg rc "$reasoning" '{role: "assistant", content: null} + (if ($rc // "") != "" then {reasoning_content: $rc} else {} end)')" '. += [$m]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
            local prompt_advise="[SYSTEM ADVISORY: Chain-of-thought received. Proceed to execute your next step. Use available tools (e.g. file_read, code_outline, code_symbol_get, file_grep, dir_list, bash_exec) to inspect files, execute commands, or apply fixes.]"
            local _task_type_cot=""
            [ -f "$hd_file" ] && _task_type_cot=$(jq -r '.task_type // empty' "$hd_file" 2>/dev/null || true)
            local _ai_clean="${goal%%<conversation_history>*}"
            if [[ "${tool_filter:-default}" =~ ^(social|chat)$ ]] || [ "$_task_type_cot" = "chat" ] || [ "$_task_type_cot" = "social" ] || [[ "${_ai_clean,,}" =~ ^[[:space:]]*(thanks|thank\ you|thx|ty|cheers|hi|hello|hey|gm|gn|good\ morning|sup|yo|ok|okay|sounds\ good)\b ]]; then
                prompt_advise="[SYSTEM ADVISORY: Chain-of-thought completed. Now provide your final, direct response to the user. Do not repeat internal reasoning.]"
            fi
            jq --arg p "$prompt_advise" '. += [{"role": "user", "content": $p}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
            fi
            echo "Thought: $reasoning" >> "$history_file"
            declare -f transcript_log_block &>/dev/null && transcript_log_block "thought" "$reasoning"
            consecutive_empty_turns=0; turn=$((turn + 1)); continue
        fi

        consecutive_empty_turns=$((consecutive_empty_turns + 1))
        if [ "$consecutive_empty_turns" -ge 5 ]; then
            ui_err "Circuit breaker tripped: Model returned $consecutive_empty_turns consecutive empty turns without advancing."
            _rl_outcome="STALL"; _rl_reason="consecutive_empty_turns=$consecutive_empty_turns"
            ui_warn "Halting task to protect context tokens and prevent infinite loop."
            _react_trace "$workdir" "circuit_breaker" "$(jq -cn --arg reason "consecutive_empty_turns" --argjson turns "$consecutive_empty_turns" '{reason:$reason, turns:$turns}')"
            jq '.status = "CIRCUIT_BREAKER_TRIPPED"' "$macro_file" > "${macro_file}.tmp" 2>/dev/null && mv "${macro_file}.tmp" "$macro_file" 2>/dev/null || true
            declare -f telemetry_record_anomaly &>/dev/null && telemetry_record_anomaly "$session_id" "PROCESS_STALL" "react.sh" "Circuit breaker tripped: $consecutive_empty_turns consecutive empty turns" >/dev/null 2>&1 || true
            declare -f telemetry_preserve_incident &>/dev/null && telemetry_preserve_incident "$session_id" "PROCESS_STALL" "Circuit breaker tripped: consecutive empty turns" "$workdir" >/dev/null 2>&1 || true
            local issue_ref=""
            if declare -f telemetry_triage_operational_failure &>/dev/null; then
                issue_ref=$(telemetry_triage_operational_failure "react_agent" "PROCESS_STALL" "Circuit breaker tripped: consecutive empty turns" "Model returned $consecutive_empty_turns consecutive empty turns without advancing" "$workdir" 2>/dev/null || true)
            fi
            if declare -f agent_sm_quarantine &>/dev/null; then
                agent_sm_quarantine "$session_id" "$workdir" "$turn" "$max_turns" "Circuit breaker tripped: $consecutive_empty_turns consecutive empty turns" "PROCESS_STALL" "$issue_ref" >/dev/null 2>&1 || true
            fi
            declare -f telemetry_task_end &>/dev/null && telemetry_task_end "$session_id" 1 "CIRCUIT_BREAKER_TRIPPED" >/dev/null 2>&1 || true
            export AGENT_ACTIVE_SESSION_ID=""
            declare -f transcript_stop &>/dev/null && transcript_active 2>/dev/null && transcript_stop >/dev/null 2>&1 || true
            return 1
        else
            jq --arg n "[SYSTEM NOTICE: No response or tool call generated on turn $turn. Please continue your task or invoke an available tool.]" '. += [{"role": "user", "content": $n}]' "$messages_file" > "${messages_file}.tmp" && mv "${messages_file}.tmp" "$messages_file"
        fi

        turn=$((turn + 1))
    done

    _rl_outcome="MAX_TURNS"; _rl_reason="turn_ceiling=$max_turns"
    ui_warn "Task reached turn ceiling ($max_turns). Preserving active state and memory..."
    journal_write "reflection" "Task paused at turn ceiling ($max_turns): $goal." 2>/dev/null || true
    _react_trace "$workdir" "task_halted" "$(jq -cn --arg goal "$goal" --arg reason "turn_ceiling_preserved" '{goal:$goal, reason:$reason}')"
    jq '.status = "TURN_CEILING_PRESERVED"' "$macro_file" > "${macro_file}.tmp" 2>/dev/null && mv "${macro_file}.tmp" "$macro_file" 2>/dev/null || true
    echo "Halted" > "$session_dir/.phase" 2>/dev/null || true
    touch "$session_dir/.done" 2>/dev/null || true
    if [ -d "${LODGE_DIR}/.sandboxes/${session_id}" ]; then
        echo "Halted" > "${LODGE_DIR}/.sandboxes/${session_id}/.phase" 2>/dev/null || true
        touch "${LODGE_DIR}/.sandboxes/${session_id}/.done" 2>/dev/null || true
    fi
    declare -f memory_register_files &>/dev/null && memory_register_files "$workdir"
    declare -f telemetry_triage_operational_failure &>/dev/null && telemetry_triage_operational_failure "react_agent" "PROCESS_STALL" "Task reached turn ceiling ($max_turns turns)" "Task failed to conclude within turn budget: $goal" "$workdir" >/dev/null 2>&1 || true
    declare -f telemetry_task_end &>/dev/null && telemetry_task_end "$session_id" 0 "TURN_CEILING_PRESERVED" >/dev/null 2>&1 || true
    declare -f agent_sm_transition &>/dev/null && agent_sm_transition "$session_id" "HALTED" "Turn ceiling reached" 2>/dev/null || true
    declare -f fifo_channel_close &>/dev/null && fifo_channel_close "$session_id" 2>/dev/null || true
    declare -f agent_sm_cull &>/dev/null && agent_sm_cull "$session_id" "Turn ceiling reached" >/dev/null 2>&1 || true
    export AGENT_ACTIVE_SESSION_ID=""
    if [ "${REACT_KEEP_TRANSCRIPT:-0}" -ne 1 ]; then
        if declare -f transcript_stop &>/dev/null && transcript_active 2>/dev/null; then
            local tp=$(transcript_stop); [ -n "$tp" ] && ui_dim "  Transcript: $tp"
        fi
    fi
    return 0
}

# Alias agent_run to react_run
agent_run() {
    react_run "$@"
}
