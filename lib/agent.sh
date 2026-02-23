#!/bin/bash
# ── George: Agent Loop ─────────────────────────────────────
# The core plan→execute→memory cycle.
# Each step is a small LLM call with full memory context.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/llm.sh"
source "$LODGE_DIR/lib/memory.sh"
source "$LODGE_DIR/lib/tools.sh"
source "$LODGE_DIR/lib/journal.sh"

# ── Config ─────────────────────────────────────────────────────
AGENT_MAX_STEPS="${AGENT_MAX_STEPS:-12}"
AGENT_STEP_DELAY="${AGENT_STEP_DELAY:-1}"
AGENT_MAX_CLARIFY="${AGENT_MAX_CLARIFY:-2}"
AGENT_INTERACTIVE_PLANNING="${AGENT_INTERACTIVE_PLANNING:-0}"
AGENT_MAX_DEPTH="${AGENT_MAX_DEPTH:-3}"

# ── Normalize inline plans ─────────────────────────────────────
# LLMs sometimes output all steps on one line:
#   "1. step one  2. step two  3. step three"
# This splits them into separate lines for the parser.
_agent_split_inline_steps() {
    local plan="$1"
    # Insert newline before step numbers preceded by 2+ spaces
    # Handles both "N." and "N)" formats
    echo "$plan" | sed 's/  \+\([0-9]\+[.)]\) /\n\1 /g'
}

# ── Check for critical errors needing user assistance ──────────
# Returns 0 (true) if the error message indicates a problem that
# requires user intervention: missing API keys, missing packages,
# missing authentication credentials, or slash command failures.
_agent_is_critical_error() {
    local error_msg="$1"
    [ -z "$error_msg" ] && return 1
    local lower
    lower=$(echo "$error_msg" | tr '[:upper:]' '[:lower:]')

    # Missing API key
    [[ "$lower" == *"api key"* ]] && return 0
    [[ "$lower" == *"api_key"* ]] && return 0
    [[ "$lower" == *"apikey"* ]] && return 0

    # Missing package / dependency
    [[ "$lower" == *"not installed"* ]] && return 0
    [[ "$lower" == *"command not found"* ]] && return 0
    [[ "$lower" == *"module not found"* ]] && return 0
    [[ "$lower" == *"package"*"missing"* ]] && return 0

    # Authentication / credentials
    [[ "$lower" == *"authentication"* ]] && return 0
    [[ "$lower" == *"credentials"* ]] && return 0
    [[ "$lower" == *"unauthorized"* ]] && return 0
    [[ "$lower" == *"permission denied"* ]] && return 0
    [[ "$lower" == *"access denied"* ]] && return 0

    # Slash command errors
    [[ "$lower" == *"slash command failed"* ]] && return 0

    return 1
}

# Track the last error from agent_execute_step for critical error detection
_AGENT_LAST_ERROR=""

# ── Cascading failure detection ────────────────────────────────
# Given a failed step and the remaining steps, determines if the
# remaining steps depend on the same resource and should be skipped.
# Returns 0 if remaining steps share the resource (cascade likely).
_agent_detect_cascade() {
    local failed_step="$1"
    shift
    local -a remaining=("$@")

    # Extract the sandbox/resource name from the failed step
    # Matches: /sandbox build NAME, /sandbox run NAME ..., etc.
    local resource=""
    if [[ "$failed_step" =~ ^/sandbox\ +[a-z]+\ +([^ ]+) ]]; then
        resource="${BASH_REMATCH[1]}"
    fi

    [ -z "$resource" ] && return 1

    # Count how many remaining steps reference the same resource
    local dependent=0
    for step in "${remaining[@]}"; do
        if [[ "$step" == *"$resource"* ]]; then
            (( dependent++ ))
        fi
    done

    # If majority of remaining steps reference the same resource, cascade
    if [ "$dependent" -gt 0 ] && [ "${#remaining[@]}" -gt 0 ]; then
        local pct=$(( dependent * 100 / ${#remaining[@]} ))
        [ "$pct" -ge 50 ] && return 0
    fi

    return 1
}

# ── Plan validation ────────────────────────────────────────────
# Scans a list of steps for common hallucination patterns and
# warns about them before execution begins. Returns 0 always
# (advisory only), but sets _AGENT_PLAN_WARNINGS with messages.
_agent_validate_plan() {
    local -a steps=("$@")
    _AGENT_PLAN_WARNINGS=""
    local warn_count=0

    for i in "${!steps[@]}"; do
        local step="${steps[$i]}"
        local num=$((i + 1))

        # Hallucinated URLs: placeholder domains like your-repo, your-link, example.com
        if [[ "$step" =~ (your-repo|your-link|your-url|example\.com|placeholder|your-name|your-user) ]]; then
            _AGENT_PLAN_WARNINGS="${_AGENT_PLAN_WARNINGS}\n  Step $num: Contains placeholder URL/name — will fail"
            (( warn_count++ ))
        fi

        # /download from a URL that was clearly invented (not from a prior step)
        if [[ "$step" =~ ^/download ]] && [[ "$step" =~ github\.com/[^/]+/[^/]+ ]] && [[ "$step" =~ (your-|example|placeholder) ]]; then
            _AGENT_PLAN_WARNINGS="${_AGENT_PLAN_WARNINGS}\n  Step $num: Downloading from hallucinated URL"
            (( warn_count++ ))
        fi

        # /save with a shell command as content (literal $(find ...) etc)
        if [[ "$step" =~ ^/save ]] && [[ "$step" =~ \$\( ]]; then
            _AGENT_PLAN_WARNINGS="${_AGENT_PLAN_WARNINGS}\n  Step $num: /save with \$(command) — will save literal text, not output"
            (( warn_count++ ))
        fi

        # /social post with unquoted multi-word text (first word gets parsed as platform)
        if [[ "$step" =~ ^/social\ +post\ +\" ]]; then
            : # properly quoted — OK
        elif [[ "$step" =~ ^/social\ +post\ +[^\"] ]]; then
            _AGENT_PLAN_WARNINGS="${_AGENT_PLAN_WARNINGS}\n  Step $num: /social post needs quoted text (first word may be parsed as platform)"
            (( warn_count++ ))
        fi
    done

    if [ "$warn_count" -gt 0 ]; then
        echo ""
        ui_warn "Plan validation found $warn_count issue(s):$(printf '%b' "$_AGENT_PLAN_WARNINGS")"
        echo ""
    fi

    return 0
}

# ── Parse plan text into steps array ───────────────────────────
# Shared parser used by agent_run and _agent_run_subtask.
# Writes step strings to stdout, one per line.
_agent_parse_steps() {
    local plan="$1"
    plan=$(_agent_split_inline_steps "$plan")
    while IFS= read -r line; do
        if [[ "$line" =~ ^[0-9]+[\.\)\ ] ]]; then
            local step_text
            step_text=$(echo "$line" | sed 's/^[0-9]*[.)[:space:]]*//')
            [ -n "$step_text" ] && echo "$step_text"
        elif [[ "$line" =~ ^/ ]] && [ -n "$line" ]; then
            echo "$line"
        elif [[ "$line" =~ ^[-\*]\ + ]]; then
            local step_text
            step_text=$(echo "$line" | sed 's/^[-*][[:space:]]*//')
            [ -n "$step_text" ] && echo "$step_text"
        fi
    done <<< "$plan"
}

# ── Recursively plan and execute a subtask ─────────────────────
# Called when a step is prefixed with [SUBTASK]. Plans the subtask
# as a new mini-task and executes each sub-step, respecting depth.
_agent_run_subtask() {
    local task="$1"
    local workdir="${2:-.}"
    local depth="${3:-1}"

    if [ "$depth" -gt "$AGENT_MAX_DEPTH" ]; then
        ui_warn "Max planning depth ($AGENT_MAX_DEPTH) reached. Executing as single step."
        agent_execute_step "sub" "$task" "$workdir" "$task"
        return $?
    fi

    ui_section "Subtask (depth $depth)"
    ui_info "$task"

    local plan
    plan=$(agent_plan "$task" "$workdir")
    if [ $? -ne 0 ]; then return 1; fi

    local -a steps=()
    while IFS= read -r s; do
        [ -n "$s" ] && steps+=("$s")
    done < <(_agent_parse_steps "$plan")

    local total=${#steps[@]}
    if [ "$total" -eq 0 ]; then
        steps=("$task")
        total=1
    fi

    ui_info "Sub-plan: $total steps (depth $depth)"
    echo ""

    local completed=0
    for i in "${!steps[@]}"; do
        local step_num=$((i + 1))
        local step_text="${steps[$i]}"

        # Nested subtask detection
        if [[ "$step_text" == \[SUBTASK\]* ]]; then
            local sub_desc="${step_text#\[SUBTASK\]}"
            sub_desc="${sub_desc# }"
            if _agent_run_subtask "$sub_desc" "$workdir" "$((depth + 1))"; then
                completed=$((completed + 1))
            fi
        else
            ui_progress "$step_num" "$total" "${step_text:0:30}"
            if agent_execute_step "$step_num" "$step_text" "$workdir" "$task"; then
                completed=$((completed + 1))
            fi
        fi

        sleep "$AGENT_STEP_DELAY"

        if [ "$step_num" -ge 4 ] && [ $(( step_num % 2 )) -eq 0 ]; then
            memory_compact "$workdir"
        fi
    done

    ui_ok "Subtask complete: $completed/$total sub-steps succeeded"
    return 0
}

# ── Plan a task ────────────────────────────────────────────────
agent_plan() {
    local task="$1"
    local workdir="${2:-.}"
    
    # Use lean "plan" mode — ~1,500 tokens instead of ~3,100
    local system_prompt
    system_prompt=$(memory_build_system_prompt "$workdir" "" "plan")
    
    # Determine effective clarification limit based on interactive planning mode
    local effective_max_clarify=0
    if [ "${AGENT_INTERACTIVE_PLANNING:-0}" -eq 1 ]; then
        effective_max_clarify="$AGENT_MAX_CLARIFY"
    fi

    local base_rules="Create a step-by-step plan. Rules:
- Use the FEWEST steps necessary. Most tasks need 1-4 steps.
- Never add filler steps. If the task needs 1 step, output 1 step.
- Absolute maximum: $AGENT_MAX_STEPS steps. Only complex multi-file tasks should approach this.
- Each step must be completable in ONE LLM call.
- Each step must be a single action (write one file, run one command, etc.)
- You can reference your slash commands (e.g. /recall, /sandbox) in steps.
- If a step is too complex for a single action, prefix it with [SUBTASK] — it will be recursively expanded into its own sub-plan.
- Output ONLY a NUMBERED LIST (1. 2. 3. etc.) — no explanations, no code."

    if [ "$effective_max_clarify" -gt 0 ]; then
        base_rules="${base_rules}
- If the task is too vague or you need key details to make a good plan,
  start your response with CLARIFY: followed by ONE short question.
  You may ask for clarification at most ${effective_max_clarify} times."
    else
        base_rules="${base_rules}
- Do NOT ask questions. Produce a plan with the information available."
    fi

    base_rules="${base_rules}

Example plan format:
1. Do the first thing
2. Do the second thing
3. Do the third thing"

    local context=""
    local clarify_round=0
    local plan=""

    while [ "$clarify_round" -le "$effective_max_clarify" ]; do
        local prompt="TASK: $task"
        if [ -n "$context" ]; then
            prompt="${prompt}

ADDITIONAL CONTEXT FROM USER:
${context}"
        fi

        if [ "$clarify_round" -eq "$effective_max_clarify" ] && [ "$effective_max_clarify" -gt 0 ]; then
            prompt="${prompt}

${base_rules}

You have already asked ${clarify_round} question(s). No more questions — produce a plan NOW."
        else
            prompt="${prompt}

${base_rules}"
        fi

        # Stream the plan so user sees progress in real-time
        echo ""
        if [ "$clarify_round" -eq 0 ]; then
            ui_dim "  Plan:"
        else
            ui_dim "  Plan (round $((clarify_round + 1))):"
        fi

        plan=$(llm_stream "$prompt" "$system_prompt" 512)
        echo ""

        if [ -z "$plan" ] || [[ "$plan" == ERROR* ]]; then
            ui_err "Planning failed: ${plan:-empty response}"
            return 1
        fi

        # Check if the model is asking for clarification (only in interactive mode)
        if [ "$effective_max_clarify" -gt 0 ]; then
            local trimmed
            trimmed=$(echo "$plan" | sed 's/^[[:space:]]*//')
            if [[ "$trimmed" == CLARIFY:* ]] && [ "$clarify_round" -lt "$effective_max_clarify" ]; then
                clarify_round=$((clarify_round + 1))
                local question
                question=$(echo "$trimmed" | sed 's/^CLARIFY:[[:space:]]*//')
                echo ""
                ui_info "George needs more info ($clarify_round/$effective_max_clarify):"
                printf "  %b%s%b\n" "$C_CYAN" "$question" "$C_RESET"
                echo ""
                printf "  %b> %b" "$C_BOLD" "$C_RESET"
                local answer
                read -r answer < /dev/tty
                if [ -z "$answer" ]; then
                    ui_dim "  No answer — proceeding with available info."
                    # Force plan on next round
                    clarify_round=$effective_max_clarify
                else
                    context="${context:+$context\n}$question → $answer"
                fi
            else
                # Got a plan (not a clarification request)
                break
            fi
        else
            # Non-interactive mode — accept whatever plan was generated
            break
        fi
    done
    
    # Update memory
    memory_update_section "Current Task" "$task" "$workdir"
    memory_update_section "Plan" "$plan" "$workdir"
    
    echo "$plan"
}

# ── Execute a single step ──────────────────────────────────────
agent_execute_step() {
    local step_num="$1"
    local step_desc="$2"
    local workdir="${3:-.}"
    local task_context="${4:-}"
    
    ui_section "Step $step_num"
    ui_step "$step_desc"
    _AGENT_LAST_ERROR=""
    
    # If the step is already a slash command, dispatch it directly
    # instead of asking the LLM (which wraps it in a broken ```bash block)
    if [[ "$step_desc" =~ ^/ ]] && declare -f commands_dispatch &>/dev/null; then
        local _cmd_stderr_file="${TMPDIR:-/tmp}/.lodge-cmd-stderr-$$"
        if commands_dispatch "$step_desc" "$workdir" 2> >(tee "$_cmd_stderr_file" >&2); then
            rm -f "$_cmd_stderr_file"
            memory_append_section "Completed Steps" "Step $step_num: $step_desc" "$workdir"
            return 0
        else
            # Capture the specific error output so George knows WHY it failed
            local _cmd_detail=""
            [ -f "$_cmd_stderr_file" ] && _cmd_detail=$(tail -5 "$_cmd_stderr_file" 2>/dev/null)
            rm -f "$_cmd_stderr_file"
            # Also include prereq messages from sandbox if available
            [ -n "${_SANDBOX_PREREQ_MSG:-}" ] && _cmd_detail="${_cmd_detail:+$_cmd_detail\n}Prereq: $_SANDBOX_PREREQ_MSG"
            local err_msg="Slash command failed: $step_desc"
            [ -n "$_cmd_detail" ] && err_msg="$err_msg — $_cmd_detail"
            _AGENT_LAST_ERROR="$err_msg"
            ui_err "$err_msg"
            memory_append_section "Errors" "Step $step_num failed: $err_msg" "$workdir"
            journal_write_failure "$step_desc" "$err_msg" "$task_context"
            return 1
        fi
    fi
    
    local system_prompt
    system_prompt=$(memory_build_system_prompt "$workdir")
    
    local prompt="CURRENT STEP ($step_num): $step_desc

Execute this step. Output rules:
- Shell commands: wrap in \`\`\`bash block
- Slash commands: output on their own line starting with / (do NOT wrap in a bash block)
- File contents: wrap in a code block with '# filepath: ./path' on line 1
- Keep output minimal
- One action per response"
    
    # Stream the step response so user sees it being generated
    echo ""
    local response
    response=$(llm_stream "$prompt" "$system_prompt" "$LLM_MAX_TOKENS")
    echo ""
    
    if [ -z "$response" ] || [[ "$response" == ERROR* ]]; then
        local err_msg="Step failed: ${response:-empty response}"
        _AGENT_LAST_ERROR="$err_msg"
        ui_err "$err_msg"
        memory_append_section "Errors" "Step $step_num failed: ${response:-empty}" "$workdir"
        journal_write_failure "Step $step_num: $step_desc" "$err_msg" "$task_context"
        return 1
    fi
    
    # Execute operations
    local results
    results=$(tools_process_response "$response" "$workdir")
    
    # Update memory
    memory_append_section "Completed Steps" "Step $step_num: $step_desc" "$workdir"
    
    if [ -n "$results" ]; then
        # Track modified files
        echo "$results" | grep -oP 'Wrote: \K[^ ;]+' | while read -r f; do
            memory_append_section "Key Files" "$f" "$workdir"
        done
    fi
    
    return 0
}

# ── Run full task (plan + execute all steps) ───────────────────
agent_run() {
    local task="$1"
    local workdir="${2:-.}"
    
    if [ -z "$task" ]; then
        ui_err "No task provided"
        return 1
    fi
    
    # Signal that we're in a task (for cancellation handling)
    _LODGE_IN_TASK=1
    _LODGE_CANCELLED=0
    local _cancel_file="${TMPDIR:-/tmp}/.lodge-cancel-$$"
    
    ui_section "Task"
    ui_info "$task"

    # Check for cancellation (file-based — visible in subshells unlike variables)
    if [ -f "$_cancel_file" ]; then _LODGE_IN_TASK=0; return 1; fi

    # Pre-flight vitals check — abort if critically low on resources
    if declare -f vitals_preflight &>/dev/null; then
        if ! vitals_preflight "strict" 2>/dev/null; then
            ui_err "Task aborted — resolve resource issues above first"
            _LODGE_IN_TASK=0
            return 1
        fi
    fi
    
    # Phase 1: Plan (user sees it streamed in real-time via /dev/tty)
    local plan
    plan=$(agent_plan "$task" "$workdir")
    if [ $? -ne 0 ] || [ "${_LODGE_CANCELLED:-0}" -eq 1 ] || [ -f "$_cancel_file" ]; then
        _LODGE_IN_TASK=0
        return 1
    fi
    echo ""
    
    # Parse steps using shared parser
    local -a steps=()
    while IFS= read -r s; do
        [ -n "$s" ] && steps+=("$s")
    done < <(_agent_parse_steps "$plan")
    
    local total=${#steps[@]}
    if [ "$total" -eq 0 ]; then
        # If plan parsing fails, treat the whole thing as one step
        ui_warn "Could not parse plan. Executing as single step."
        steps=("$task")
        total=1
    fi
    
    ui_info "Executing $total steps..."
    echo ""

    # Pre-execution plan validation — warn about hallucinated URLs, bad patterns
    _agent_validate_plan "${steps[@]}"
    
    # Phase 2: Execute
    local completed=0
    local failed_steps=""
    local _cascade_halt=0
    for i in "${!steps[@]}"; do
        # Check for cancellation between steps (file + variable)
        if [ "${_LODGE_CANCELLED:-0}" -eq 1 ] || [ -f "$_cancel_file" ]; then
            ui_warn "Task cancelled at step $((i + 1))/$total"
            break
        fi
        
        local step_num=$((i + 1))
        
        ui_progress "$step_num" "$total" "${steps[$i]:0:30}"
        
        # Detect [SUBTASK] markers — recursively plan and execute
        if [[ "${steps[$i]}" == \[SUBTASK\]* ]]; then
            local subtask_desc="${steps[$i]#\[SUBTASK\]}"
            subtask_desc="${subtask_desc# }"
            if _agent_run_subtask "$subtask_desc" "$workdir" 1; then
                completed=$((completed + 1))
            else
                failed_steps="${failed_steps:+${failed_steps}, }step $step_num: ${steps[$i]}"
            fi
        elif agent_execute_step "$step_num" "${steps[$i]}" "$workdir" "$task"; then
            completed=$((completed + 1))
        else
            failed_steps="${failed_steps:+${failed_steps}, }step $step_num: ${steps[$i]}"
            # Check if failure was due to cancellation
            if [ "${_LODGE_CANCELLED:-0}" -eq 1 ] || [ -f "$_cancel_file" ]; then
                ui_warn "Step $step_num cancelled"
                break
            fi

            # ── Cascading failure detection ────────────────────
            # If the failed step and most remaining steps share a resource,
            # halt the chain rather than accumulating N identical failures.
            local -a _remaining_steps=()
            for _ri in $(seq $((i + 1)) $((total - 1))); do
                _remaining_steps+=("${steps[$_ri]}")
            done
            if [ ${#_remaining_steps[@]} -gt 0 ] && _agent_detect_cascade "${steps[$i]}" "${_remaining_steps[@]}"; then
                echo ""
                ui_err "Cascading failure detected — ${#_remaining_steps[@]} remaining steps depend on the same resource"
                ui_info "Halting to avoid ${#_remaining_steps[@]} more identical failures."
                echo ""
                ui_info "George needs help with step $step_num:"
                printf "  %b%s%b\n" "$C_CYAN" "$_AGENT_LAST_ERROR" "$C_RESET"
                printf "  %bFix the issue and retry, or press Enter to abort: %b" "$C_BOLD" "$C_RESET"
                local guidance
                read -r guidance < /dev/tty
                if [ -n "$guidance" ]; then
                    memory_append_section "User Guidance" "Step $step_num: $guidance" "$workdir"
                    # User gave guidance — retry this step once
                    ui_info "Retrying step $step_num with guidance..."
                    if agent_execute_step "$step_num" "${steps[$i]}" "$workdir" "$task"; then
                        completed=$((completed + 1))
                        continue
                    fi
                fi
                ui_warn "Stopped at step $step_num (cascade halt)"
                break
            fi

            # Critical errors (missing API key, package, auth, slash failures)
            # prompt the user for guidance with no timeout
            if _agent_is_critical_error "$_AGENT_LAST_ERROR"; then
                echo ""
                ui_info "George needs help with step $step_num:"
                printf "  %b%s%b\n" "$C_CYAN" "$_AGENT_LAST_ERROR" "$C_RESET"
                printf "  %bHow should I proceed? (or press Enter to skip): %b" "$C_BOLD" "$C_RESET"
                local guidance
                read -r guidance < /dev/tty
                if [ -n "$guidance" ]; then
                    memory_append_section "User Guidance" "Step $step_num: $guidance" "$workdir"
                fi
            fi
            ui_warn "Step $step_num failed. Continue? [Y/n]"
            read -r cont
            if [[ "${cont,,}" == "n" ]]; then
                ui_warn "Stopped at step $step_num"
                break
            fi
        fi
        
        # Delay between steps
        sleep "$AGENT_STEP_DELAY"
        
        # Inter-step vitals check — warn on degrading conditions
        if declare -f vitals_guard_disk &>/dev/null; then
            if ! vitals_guard_disk 2>/dev/null; then
                ui_warn "Stopping task — disk critically low"
                break
            fi
            vitals_guard_ram 2>/dev/null || true  # warn but don't abort
        fi

        # Compact memory if steps are accumulating (earlier = safer for 8K context)
        if [ "$step_num" -ge 4 ] && [ $(( step_num % 2 )) -eq 0 ]; then
            memory_compact "$workdir"
        fi
    done
    
    # Task done — signal no longer in task
    _LODGE_IN_TASK=0
    _LODGE_CANCELLED=0
    
    # Phase 3: Summary
    echo ""
    ui_divider
    ui_ok "Task complete: $completed/$total steps succeeded"
    
    # Phase 4: Reflect in journal (background — don't block user)
    local reflect_summary="$task ($completed/$total steps in $(basename "$workdir"))"
    if [ -n "$failed_steps" ]; then
        reflect_summary="${reflect_summary}. Failed: ${failed_steps}"
    fi
    journal_reflect "$reflect_summary" "$workdir" &
    
    # Notify on phone if available
    tools_phone_toast "Lodge: Task complete ($completed/$total steps)"
    
    # Model stays loaded during active session for fast response times.
    # It will be unloaded on session exit (lodge main) or by keep_alive timeout.
    
    return 0
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
    
    # Stream the response so user sees tokens arrive in real-time
    echo ""
    local response
    response=$(llm_stream "$question" "$system_prompt" "$LLM_ASK_TOKENS")
    echo ""
    
    _LODGE_IN_TASK=0
    
    if [ "${_LODGE_CANCELLED:-0}" -eq 1 ]; then
        _LODGE_CANCELLED=0
        return 1
    fi
    
    if [[ "$response" == ERROR* ]]; then
        ui_err "$response"
        return 1
    fi
    
    # Model stays loaded during active session for fast response times.
}

# ── Interactive step-by-step mode ──────────────────────────────
agent_step_mode() {
    local task="$1"
    local workdir="${2:-.}"
    
    local plan
    plan=$(agent_plan "$task" "$workdir")
    if [ $? -ne 0 ]; then return 1; fi
    
    ui_section "Plan"
    echo "$plan"
    echo ""
    
    # Normalize inline plans before parsing
    plan=$(_agent_split_inline_steps "$plan")
    local -a steps=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^[0-9]+[\.\)] ]]; then
            steps+=("$(echo "$line" | sed 's/^[0-9]*[.)[:space:]]*//')")
        fi
    done <<< "$plan"
    
    for i in "${!steps[@]}"; do
        local step_num=$((i + 1))
        echo ""
        ui_info "Next: Step $step_num — ${steps[$i]}"
        if ui_confirm "Execute this step?"; then
            agent_execute_step "$step_num" "${steps[$i]}" "$workdir"
        else
            ui_warn "Skipped step $step_num"
            memory_append_section "Completed Steps" "Step $step_num: SKIPPED — ${steps[$i]}" "$workdir"
        fi
    done
}
