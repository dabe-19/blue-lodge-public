#!/bin/bash
# ── George: Agent Helpers ─────────────────────────────────────────
# Survivors of the retired legacy agent loop (lib/core/agent.sh, removed in
# refinement P2.8; see git tag pre-agent-sh-retirement). react_run in
# lib/core/react.sh is the single execution engine.
#
# Kept here because live code still depends on them:
#   - AGENT_* config defaults read by tools.sh, social.sh, write/append/edit,
#     limits.sh and the /limits UI in lodge
#   - _agent_routing_apply  (/limits routing; legacy knob, no effect on react)
#   - _strip_think_blocks, _agent_extract_json  (reflexive.sh)
#   - agent_ask + conversation ring buffer  (/q single-shot answers)
#   - agent_plan  (/plan → honeydew strategist, plan-only)

[ -n "${_LIB_AGENT_HELPERS_LOADED:-}" ] && return 0; _LIB_AGENT_HELPERS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh"
source "$LODGE_DIR/lib/core/llm.sh"
source "$LODGE_DIR/lib/memory/memory.sh"
source "$LODGE_DIR/lib/tools/tools.sh"
source "$LODGE_DIR/lib/memory/journal.sh"

# ── Config ─────────────────────────────────────────────────────
AGENT_MAX_STEPS="${AGENT_MAX_STEPS:-40}"       # Macro loop milestone ceiling
AGENT_PLAN_STEPS="${AGENT_PLAN_STEPS:-8}"      # Max steps per plan/subtask
AGENT_INNER_LOOPS="${AGENT_INNER_LOOPS:-8}"    # Inner loop escalation ceiling
AGENT_STEP_DELAY="${AGENT_STEP_DELAY:-1}"
AGENT_MAX_CLARIFY="${AGENT_MAX_CLARIFY:-2}"
AGENT_INTERACTIVE_PLANNING="${AGENT_INTERACTIVE_PLANNING:-0}"
AGENT_MAX_DEPTH="${AGENT_MAX_DEPTH:-3}"        # Subtask recursion depth (3 = three levels of expansion)
AGENT_HONEYDEW_EXPAND="${AGENT_HONEYDEW_EXPAND:-1}"  # Subtask expansion: 0=disabled, 1=enabled
AGENT_HONEYDEW_MAX_ITEMS="${AGENT_HONEYDEW_MAX_ITEMS:-12}"  # Max honeydew items before expansion is suppressed
AGENT_HONEYDEW_REWRITE="${AGENT_HONEYDEW_REWRITE:-1}"    # Dynamic honeydew rewrite: 0=disabled, 1=enabled
AGENT_HONEYDEW_REWRITE_ROUNDS="${AGENT_HONEYDEW_REWRITE_ROUNDS:-8}"  # Global honeydew rewrite limit (all paths: normal, pressure relief, auto-recovery)
AGENT_HONEYDEW_REWRITE_CADENCE="${AGENT_HONEYDEW_REWRITE_CADENCE:-0}"  # Min new milestones between rewrites (0=every iteration)
AGENT_FORCE_REWRITE="${AGENT_FORCE_REWRITE:-1}"          # Force honeydew rewrite in interlock/failure recovery (bypass Phase 1 router): 0=disabled, 1=enabled
AGENT_WEB_SUFFICIENCY="${AGENT_WEB_SUFFICIENCY:-20}"  # Web actions before sufficiency signal
AGENT_MAX_MILESTONE_RETRIES="${AGENT_MAX_MILESTONE_RETRIES:-3}"  # Max times to retry same milestone
AGENT_MAX_CMD_FAMILY="${AGENT_MAX_CMD_FAMILY:-5}"               # Max milestones with same base command
AGENT_HONEYDEW_MATCH="${AGENT_HONEYDEW_MATCH:-3}"              # Min keyword score to auto-check honeydew item
AGENT_HONEYDEW_INITIAL_COUNT="${AGENT_HONEYDEW_INITIAL_COUNT:-5}"  # Upper bound on initial honeydew items (prompt hint)
AGENT_EVAL_MODE="${AGENT_EVAL_MODE:-auto}"              # Evaluator mode: auto | interactive | disabled
AGENT_WEB_SEARCH_CONSEC_MAX="${AGENT_WEB_SEARCH_CONSEC_MAX:-1}"  # Max consecutive /web search before fallback to fetch/scrape
AGENT_WEB_FETCH_CASCADE="${AGENT_WEB_FETCH_CASCADE:-1}"          # Auto-fetch top search results: 0=disabled, 1=enabled
AGENT_WEB_SEARCH_TIGHT_PARSING="${AGENT_WEB_SEARCH_TIGHT_PARSING:-0}"  # Tight web query parsing: 0=loose (keep quotes/negations/operators), 1=strict (strip all)
AGENT_WEB_SEARCH_MAX_LENGTH="${AGENT_WEB_SEARCH_MAX_LENGTH:-160}"  # Max character length for /web search queries
AGENT_WEB_SEARCH_MAX_OPERATORS="${AGENT_WEB_SEARCH_MAX_OPERATORS:-3}"  # Max AND/OR operators allowed in loose mode
AGENT_RESPOND_CONSEC_MAX="${AGENT_RESPOND_CONSEC_MAX:-2}"        # Max consecutive /respond before removal from catalog
AGENT_EVAL_VALIDATE="${AGENT_EVAL_VALIDATE:-1}"                  # Evaluator command validation: 0=disabled, 1=enabled
AGENT_EVAL_REC_CHARS="${AGENT_EVAL_REC_CHARS:-500}"              # Max chars after a slash command in evaluator recommendations
AGENT_EVAL_REC_INJECT="${AGENT_EVAL_REC_INJECT:-1}"            # Recommendation injection to honeydew rewriter: 0=off (current), 1=recommendation-only (high weight), 2=both (recommendation + full context)
AGENT_CROSS_TASK_SIEVE="${AGENT_CROSS_TASK_SIEVE:-1}"          # Cross-task memory sieve: 0=disabled, 1=keyword recall injection at task start
AGENT_CONTEXT_FILES_MAX="${AGENT_CONTEXT_FILES_MAX:-10}"      # Max context file entries persisted across tasks (0=disabled)
AGENT_PRESSURE_RELIEF="${AGENT_PRESSURE_RELIEF:-2}"          # Consecutive milestone skips before pressure relief fires (0=disabled)
AGENT_SMART_ROUTE="${AGENT_SMART_ROUTE:-3}"              # Smart command routing: 0=disabled, 1=post-dispatch reroute only, 2=fuzzy keyword catalog injection only, 3=combined
AGENT_ASK_USER="${AGENT_ASK_USER:-1}"                    # Allow George to /ask the user questions during tasks: 0=disabled, 1=enabled
AGENT_BRAINSTORM="${AGENT_BRAINSTORM:-1}"                  # Allow George to /brainstorm (self-reason) during tasks: 0=disabled, 1=enabled
AGENT_FILE_EXPAND="${AGENT_FILE_EXPAND:-1}"              # Auto-expand file references in /social, /email, /write text: 0=disabled, 1=enabled
AGENT_FILE_EXPAND_CHARS="${AGENT_FILE_EXPAND_CHARS:-40000}"  # Max chars per expanded file in specialist output (0=unlimited)
AGENT_DM_SCAN_CHARS="${AGENT_DM_SCAN_CHARS:-80}"          # Characters to scan for recipient names from start of DM text
AGENT_PRE_ROUTE="${AGENT_PRE_ROUTE:-1}"                  # Pre-route: extract /cmd from milestone, skip router: 0=disabled, 1=enabled
AGENT_FAST_ROUTE="${AGENT_FAST_ROUTE:-1}"                # Fast-route: 0=disabled, 1=keywords+lean, 2=fuzzy only (lean prompt, no keyword matching)
AGENT_ROUTING="${AGENT_ROUTING:-}"                       # Consolidated routing preset: 0=minimal, 1=standard, 2=full-llm, 3=enhanced (empty=use individual vars)
AGENT_TASK_MODE="${AGENT_TASK_MODE:-0}"                  # Task classifier override: 0=auto (LLM), 1=abstract, 2=concrete, 3=combined
AGENT_WEB_UNLOCK_ABSTRACT="${AGENT_WEB_UNLOCK_ABSTRACT:-1}"  # Milestones before /web unlocks for abstract tasks (99=effectively never)
AGENT_WEB_UNLOCK_COMBINED="${AGENT_WEB_UNLOCK_COMBINED:-0}"   # Milestones before /web unlocks for combined tasks
AGENT_WEB_SEARCH_ONLY_ABSTRACT="${AGENT_WEB_SEARCH_ONLY_ABSTRACT:-1}"  # Milestones after web unlock where ONLY /web search is allowed (no fetch/scrape) for abstract tasks
AGENT_WEB_SEARCH_ONLY_COMBINED="${AGENT_WEB_SEARCH_ONLY_COMBINED:-1}"  # Milestones after web unlock where ONLY /web search is allowed (no fetch/scrape) for combined tasks
AGENT_GIT_UNLOCK_ABSTRACT="${AGENT_GIT_UNLOCK_ABSTRACT:-1}"  # Milestones before /git unlocks for abstract tasks (99=effectively never)
AGENT_GIT_UNLOCK_COMBINED="${AGENT_GIT_UNLOCK_COMBINED:-1}"   # Milestones before /git unlocks for combined tasks
AGENT_OUTPUT_DIR="${AGENT_OUTPUT_DIR:-.george/workspaces}" # Parent directory for agent file writes (.george/workspaces)
AGENT_GREP_ALLOW_ABSOLUTE="${AGENT_GREP_ALLOW_ABSOLUTE:-0}"  # /grep path policy: 0=relative-only (force to workdir), 1=allow absolute paths
AGENT_GREP_MAX_LINES="${AGENT_GREP_MAX_LINES:-300}"          # /grep output cap (lines shown before truncation)
AGENT_LS_ALLOW_ABSOLUTE="${AGENT_LS_ALLOW_ABSOLUTE:-0}"      # /ls path policy: 0=relative-only (force to workdir), 1=allow absolute paths
AGENT_MILESTONE_CHARS="${AGENT_MILESTONE_CHARS:-200}"        # Max chars for milestone text before truncation (full text still passed to specialist)
AGENT_ROUTER_SHORTLIST_MIN="${AGENT_ROUTER_SHORTLIST_MIN:-3}"  # Router shortlist floor (commands)
AGENT_ROUTER_SHORTLIST_MAX="${AGENT_ROUTER_SHORTLIST_MAX:-5}"  # Router shortlist ceiling (commands)
AGENT_SPECIALIST_STRICT="${AGENT_SPECIALIST_STRICT:-1}"      # Specialist boundary: 1=primary command only, 0=broad catalog
AGENT_FORCE_OFFLINE="${AGENT_FORCE_OFFLINE:-0}"              # Force deterministic offline routing fallback
AGENT_INFEASIBILITY_PROMPT_ONCE="${AGENT_INFEASIBILITY_PROMPT_ONCE:-1}"  # Limitation-resolution prompt cadence: 1=once per episode
AGENT_ROUTER_PHASE_B_MIN="${AGENT_ROUTER_PHASE_B_MIN:-5}"    # Adaptive exposure phase B shortlist floor
AGENT_ROUTER_PHASE_B_MAX="${AGENT_ROUTER_PHASE_B_MAX:-8}"    # Adaptive exposure phase B shortlist ceiling
AGENT_ROUTER_PHASE_C_MAX="${AGENT_ROUTER_PHASE_C_MAX:-12}"   # Adaptive exposure phase C shortlist ceiling
AGENT_GRAMMAR_HANDSHAKE="${AGENT_GRAMMAR_HANDSHAKE:-1}"      # Startup grammar compatibility canary: 0=off, 1=on
AGENT_CONVERSATIONAL_INFO_MODE="${AGENT_CONVERSATIONAL_INFO_MODE:-1}"  # Conversational-info fast path: 0=off, 1=on
AGENT_ANTI_FLAIL_RESPOND="${AGENT_ANTI_FLAIL_RESPOND:-1}"    # Reject low-information /respond loops on info-seeking tasks

LLM_EVALUATOR_TOKENS="${LLM_EVALUATOR_TOKENS:-4096}"     # Max output tokens for evaluator



# ── Consolidated Routing Preset ────────────────────────────────
# Maps AGENT_ROUTING preset to individual routing variables.
# Called at startup if AGENT_ROUTING is set, and by /limits routing.
# Presets: 0=minimal, 1=standard, 2=full-llm, 3=enhanced
_agent_routing_apply() {
    local mode="${1:-${AGENT_ROUTING:-}}"
    [ -z "$mode" ] && return 0
    case "$mode" in
        0) AGENT_PRE_ROUTE=0; AGENT_FAST_ROUTE=0; AGENT_SMART_ROUTE=0 ;;
        1) AGENT_PRE_ROUTE=1; AGENT_FAST_ROUTE=1; AGENT_SMART_ROUTE=1 ;;
        2) AGENT_PRE_ROUTE=1; AGENT_FAST_ROUTE=0; AGENT_SMART_ROUTE=1 ;;
        3) AGENT_PRE_ROUTE=1; AGENT_FAST_ROUTE=1; AGENT_SMART_ROUTE=3 ;;
    esac
}
# Apply preset if AGENT_ROUTING was set via environment
_agent_routing_apply


# ── Think Block Stripper ───────────────────────────────────────
# Single awk pass replaces ~40 sed forks across 12 call sites.
# Handles <think>, [THINK], [THOUGHT] variants case-insensitively
# including unclosed blocks (token limit truncated before closing tag).
# Saves 360-1080ms per task cycle on constrained hardware
# (each sed fork = ~15ms RAM alloc on Jetson Nano / Termux).
#
# Usage: cleaned=$(echo "$raw" | _strip_think_blocks)
_strip_think_blocks() {
    local input
    input=$(cat)
    if [[ "$input" == *"</think>"* && "$input" != *"<think>"* ]]; then
        input="${input#*</think>}"
    elif [[ "$input" == *"[/think]"* && "$input" != *"[think]"* ]]; then
        input="${input#*[/think]}"
    elif [[ "$input" == *"[/thought]"* && "$input" != *"[thought]"* ]]; then
        input="${input#*[/thought]}"
    fi
    echo "$input" | awk 'BEGIN { skip=0 }
    {
        # Normalize Gemma 4 reasoning channel tags to standard think tags
        gsub(/<\|channel>thought/, "<think>")
        gsub(/<channel\|>/, "</think>")

        # Remove complete balanced blocks on a single line first
        gsub(/<[tT][hH][iI][nN][kK]>[^<]*<\/[tT][hH][iI][nN][kK]>/, "")
        gsub(/\[[tT][hH][iI][nN][kK]\][^\[]*\[\/[tT][hH][iI][nN][kK]\]/, "")
        gsub(/\[[tT][hH][oO][uU][gG][hH][tT]\][^\[]*\[\/[tT][hH][oO][uU][gG][hH][tT]\]/, "")

        # Multi-line block detection: opening tag starts skip mode
        if (match($0, /<[tT][hH][iI][nN][kK]>/)) {
            sub(/<[tT][hH][iI][nN][kK]>.*/, "", $0)
            if (length($0) > 0) print $0
            skip=1; next
        }
        if (match($0, /\[[tT][hH][iI][nN][kK]\]/)) {
            sub(/\[[tT][hH][iI][nN][kK]\].*/, "", $0)
            if (length($0) > 0) print $0
            skip=1; next
        }
        if (match($0, /\[[tT][hH][oO][uU][gG][hH][tT]\]/)) {
            sub(/\[[tT][hH][oO][uU][gG][hH][tT]\].*/, "", $0)
            if (length($0) > 0) print $0
            skip=1; next
        }

        # Closing tags end skip mode
        if (skip) {
            if (match($0, /<\/[tT][hH][iI][nN][kK]>/)) {
                sub(/.*<\/[tT][hH][iI][nN][kK]>/, "", $0)
                skip=0
                if (length($0) > 0) print $0
                next
            }
            if (match($0, /\[\/[tT][hH][iI][nN][kK]\]/)) {
                if (match($0, /:[[:space:]]*\[\/[tT][hH][iI][nN][kK]\]/)) {
                    sub(/\[\/[tT][hH][iI][nN][kK]\]/, "[", $0)
                    skip=0
                    if (length($0) > 0) print $0
                    next
                }
                sub(/.*\[\/[tT][hH][iI][nN][kK]\]/, "", $0)
                skip=0
                if (length($0) > 0) print $0
                next
            }
            if (match($0, /\[\/[tT][hH][oO][uU][gG][hH][tT]\]/)) {
                if (match($0, /:[[:space:]]*\[\/[tT][hH][oO][uU][gG][hH][tT]\]/)) {
                    sub(/\[\/[tT][hH][oO][uU][gG][hH][tT]\]/, "[", $0)
                    skip=0
                    if (length($0) > 0) print $0
                    next
                }
                sub(/.*\[\/[tT][hH][oO][uU][gG][hH][tT]\]/, "", $0)
                skip=0
                if (length($0) > 0) print $0
                next
            }
            next  # inside unclosed block — skip line
        }

        # Strip stray opening/closing tags (orphaned fragments)
        gsub(/<\/?[tT][hH][iI][nN][kK]>/, "")
        gsub(/\[\/?[tT][hH][iI][nN][kK]\]/, "")
        gsub(/\[\/?[tT][hH][oO][uU][gG][hH][tT]\]/, "")

        if (length($0) > 0) print $0
    }'
}

# ── JSON Extraction Helper (Layer 2) ───────────────────────────
# Extracts and validates structured JSON from raw LLM output.
# Handles think blocks, markdown code fences, and surrounding prose.
#
# Usage: _agent_extract_json "$raw_output" "field1" "field2" ...
#   - Positional args after $1 are required field names.
#   - Outputs clean JSON to stdout on success (exit 0).
#   - Returns exit 1 on parse failure (caller falls back to Layer 3).
#
# Pipeline: strip think blocks → strip markdown → extract first
# {...} → validate with jq (parse + required fields check).
_agent_extract_json() {
    local raw="$1"
    shift
    local -a required_fields=("$@")

    # Step 1: Strip think blocks (reuse existing helper)
    local cleaned
    cleaned=$(echo "$raw" | _strip_think_blocks)

    # Step 2: Strip markdown code fences (```json ... ```)
    # The model may put the JSON on the same line as the fence marker
    # (e.g. ```json{"type":"combined"}```) — strip markers, keep content.
    cleaned=$(echo "$cleaned" | sed 's/^```[a-zA-Z]*//;s/```$//')

    # Step 3: Strip leading/trailing whitespace and asterisks
    cleaned=$(echo "$cleaned" | sed 's/\*\+//g' | sed '/^[[:space:]]*$/d' | \
              sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # Step 4: Extract the first balanced JSON object {...} starting from any '{'
    local json_obj
    json_obj=$(echo "$cleaned" | awk '
        BEGIN { RS="^$" }
        {
            for (start_pos = 1; start_pos <= length($0); start_pos++) {
                if (substr($0, start_pos, 1) == "{") {
                    depth = 0
                    output = ""
                    for (i = start_pos; i <= length($0); i++) {
                        c = substr($0, i, 1)
                        output = output c
                        if (c == "{") {
                            depth++
                        } else if (c == "}") {
                            depth--
                            if (depth == 0) {
                                print output
                                exit 0
                            }
                        }
                    }
                }
            }
        }
    ')

    [ -z "$json_obj" ] && return 1

    # Step 5: Validate JSON with jq
    local validated
    validated=$(echo "$json_obj" | jq -e '.' 2>/dev/null) || return 1

    # Step 6: Check required fields exist (non-null)
    local field
    for field in "${required_fields[@]}"; do
        if ! echo "$validated" | jq -e --arg f "$field" '.[$f] // empty' &>/dev/null; then
            return 1
        fi
    done

    echo "$validated"
    return 0
}

# ── Conversation history (ring buffer for /ask continuity) ─────
# Stores last N exchanges so George remembers recent conversation.
# Each entry: "USER: ...\nGEORGE: ..."
# Parallel array stores full responses for accuracy when needed.
_AGENT_CONV_HISTORY=()
_AGENT_CONV_FULL=()
AGENT_CONV_MAX="${AGENT_CONV_MAX:-6}"  # Keep last 6 exchanges
# Graduated compression: last 2 = 400 chars, middle 2 = 200 chars, oldest 2 = 100 chars

_agent_conv_push() {
    local user_msg="$1"
    local george_msg="$2"
    # Store full response in parallel array for accuracy references
    _AGENT_CONV_FULL+=("$george_msg")
    _AGENT_CONV_HISTORY+=("USER: $user_msg
GEORGE: $george_msg")
    # Trim to max size
    while [ ${#_AGENT_CONV_HISTORY[@]} -gt "$AGENT_CONV_MAX" ]; do
        _AGENT_CONV_HISTORY=("${_AGENT_CONV_HISTORY[@]:1}")
        _AGENT_CONV_FULL=("${_AGENT_CONV_FULL[@]:1}")
    done
}

_agent_conv_context() {
    if [ ${#_AGENT_CONV_HISTORY[@]} -eq 0 ]; then
        echo ""
        return
    fi
    local ctx="--- RECENT CONVERSATION ---"
    local _total=${#_AGENT_CONV_HISTORY[@]}
    local i
    for (( i=0; i<_total; i++ )); do
        local _age=$((_total - i))  # 1=newest, _total=oldest
        local _limit
        if [ "$_age" -le 2 ]; then
            _limit=400  # last 2 exchanges: 400 chars
        elif [ "$_age" -le 4 ]; then
            _limit=200  # middle 2 exchanges: 200 chars
        else
            _limit=100  # oldest 2 exchanges: 100 chars
        fi
        local _entry="${_AGENT_CONV_HISTORY[$i]}"
        # Apply graduated compression to the GEORGE response portion
        local _user_part _george_part
        _user_part=$(echo "$_entry" | head -1)
        _george_part=$(echo "$_entry" | tail -n +2)
        local _george_text="${_george_part#GEORGE: }"
        if [ ${#_george_text} -gt "$_limit" ]; then
            _george_part="GEORGE: ${_george_text:0:$_limit}..."
        fi
        ctx="$ctx
$_user_part
$_george_part"
    done
    echo "$ctx"
}

# ── Single-shot ask (no planning, just answer) ────────────────
agent_ask() {
    local question="$1"
    local workdir="${2:-.}"
    
    _LODGE_IN_TASK=1
    _LODGE_CANCELLED=0
    
    # Use lean prompt — keeps system context under ~800 tokens
    local system_prompt
    system_prompt=$(memory_build_system_prompt "$workdir" "$question" "ask")
    
    # Inject conversation history for continuity
    local conv_ctx
    conv_ctx=$(_agent_conv_context)
    
    local full_question="$question"
    if [ -n "$conv_ctx" ]; then
        full_question="$conv_ctx

$question"
    fi
    
    echo ""
    local response
    local LLM_SCENARIO=ask
    local _ask_rc

    # ── Provider path: synchronous API call ───────────────────
    # Cloud APIs return fast enough that chunked response is fine.
    # Streaming via FIFO + background curl in nested $() subshells
    # traps the curl PID where Ctrl+C can't reach it, causing hangs.
    if [ -n "${GEORGE_PROVIDER:-}" ] && declare -f _provider_call_with_backoff &>/dev/null; then
        local _ask_msg="$full_question"
        if [ -n "$system_prompt" ]; then
            _ask_msg="Instructions: ${system_prompt}

${full_question}"
        fi

        ui_spinner_start "$GEORGE_PROVIDER" 2>/dev/null >/dev/tty
        response=$(_provider_call_with_backoff "$GEORGE_PROVIDER" "$_ask_msg")
        _ask_rc=$?
        ui_spinner_stop 2>/dev/null

        # Render response for interactive REPL mode
        if [ -t 1 ] && [ "$_ask_rc" -eq 0 ] && [ -n "$response" ]; then
            echo ""
            ui_render_response "$response"
        fi
    else
        # ── Local backend: stream tokens to TTY ──────────────────
        # llm_stream() writes every token to /dev/tty as it arrives,
        # while stdout is captured into $response via $().
        response=$(llm_stream "$full_question" "$system_prompt" "$LLM_ASK_TOKENS" "$LLM_BUDGET_ASK")
        _ask_rc=$?
    fi

    if [ $_ask_rc -ne 0 ] || [ -z "$response" ]; then
        echo ""
        ui_err "No response generated"
        _LODGE_IN_TASK=0
        return 1
    fi

    # Transcript: log the ask response
    declare -f transcript_log_block &>/dev/null && transcript_log_block "llm-response (ask)" "$response"

    # Track this exchange for future context
    [ -n "$response" ] && [[ "$response" != ERROR* ]] && _agent_conv_push "$question" "$response"
    
    _LODGE_IN_TASK=0
    
    if [ "${_LODGE_CANCELLED:-0}" -eq 1 ]; then
        _LODGE_CANCELLED=0
        return 1
    fi
    
    if [[ "$response" == ERROR* ]]; then
        ui_err "$response"
        return 1
    fi
    
    # Emit response to stdout so the agent inner loop's
    # output=$(commands_dispatch ...) captures it into the action log.
    # In interactive mode llm_stream already displayed tokens to /dev/tty,
    # so only echo when stdout is NOT a terminal (i.e., captured by $()).
    if ! [ -t 1 ]; then
        # Also render to /dev/tty so the operator can see /brainstorm
        # and /q results during task execution (otherwise only visible
        # in debug mode or transcripts).
        {
            echo ""
            printf "  %b/brainstorm:%b\n" "$C_DIM" "$C_RESET"
            ui_render_response "$response"
            echo ""
        } 2>/dev/null >/dev/tty
        echo "$response"
    fi

    # Journal the exchange — George writes a witty one-liner for posterity
    # Runs in background so user isn't blocked.
    # Redirect /dev/tty writes to /dev/null so debug output from the
    # background LLM call doesn't overwrite the REPL prompt.
    if declare -f journal_write_quip &>/dev/null; then
        journal_write_quip "$question" "$response" </dev/null >/dev/null 2>&1 &
    fi
    
    # Model stays loaded during active session for fast response times.
}


# ── Plan-only (/plan) ─────────────────────────────────────────
# Produces a numbered milestone plan via the honeydew strategist (the same
# planner react_run uses) without executing anything. Falls back to the
# strategist's deterministic heuristic plan when the LLM is unreachable.
# Usage: agent_plan "<task>" [workdir]   → numbered list on stdout
agent_plan() {
    local task="${1:-}" workdir="${2:-.}"
    [ -z "$task" ] && { ui_err "Usage: /plan <task>"; return 1; }
    local strat="$LODGE_DIR/lib/tools/honeydew_strategist.py"
    [ -f "$strat" ] || { ui_err "honeydew strategist missing: $strat"; return 1; }
    local items
    items=$(cd "$workdir" 2>/dev/null && python3 "$strat" "$task" "${ACTIVE_ENDPOINT_URL:-http://127.0.0.1:8080}" 2>/dev/null)
    local milestones
    milestones=$(jq -c 'if type == "object" and .items then .items elif type == "array" then . else [] end' 2>/dev/null <<<"$items")
    if ! jq -e "type == \"array\" and length > 0" >/dev/null 2>&1 <<<"$milestones"; then
        ui_err "Planner returned no milestones"
        return 1
    fi
    jq -r ".[] | \"\(.id). \(.task)\"" <<<"$milestones"
}

