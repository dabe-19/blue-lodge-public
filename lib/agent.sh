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

# ── Plan a task ────────────────────────────────────────────────
agent_plan() {
    local task="$1"
    local workdir="${2:-.}"
    
    # Use lean "plan" mode — ~1,500 tokens instead of ~3,100
    local system_prompt
    system_prompt=$(memory_build_system_prompt "$workdir" "" "plan")
    
    local base_rules="Create a step-by-step plan. Rules:
- Use the FEWEST steps necessary. Most tasks need 1-4 steps.
- Never add filler steps. If the task needs 1 step, output 1 step.
- Absolute maximum: 8 steps. Only complex multi-file tasks should approach this.
- Each step must be completable in ONE LLM call.
- Each step must be a single action (write one file, run one command, etc.)
- You can reference your slash commands (e.g. /recall, /sandbox) in steps.
- Output ONLY a NUMBERED LIST (1. 2. 3. etc.) — no explanations, no code.
- If the task is too vague or you need key details to make a good plan,
  start your response with CLARIFY: followed by ONE short question.
  You may ask for clarification at most ${AGENT_MAX_CLARIFY} times.

Example plan format:
1. Do the first thing
2. Do the second thing
3. Do the third thing"

    local context=""
    local clarify_round=0
    local plan=""

    while [ "$clarify_round" -le "$AGENT_MAX_CLARIFY" ]; do
        local prompt="TASK: $task"
        if [ -n "$context" ]; then
            prompt="${prompt}

ADDITIONAL CONTEXT FROM USER:
${context}"
        fi

        if [ "$clarify_round" -eq "$AGENT_MAX_CLARIFY" ]; then
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

        # Check if the model is asking for clarification
        local trimmed
        trimmed=$(echo "$plan" | sed 's/^[[:space:]]*//')
        if [[ "$trimmed" == CLARIFY:* ]] && [ "$clarify_round" -lt "$AGENT_MAX_CLARIFY" ]; then
            clarify_round=$((clarify_round + 1))
            local question
            question=$(echo "$trimmed" | sed 's/^CLARIFY:[[:space:]]*//')
            echo ""
            ui_info "George needs more info ($clarify_round/$AGENT_MAX_CLARIFY):"
            printf "  %b%s%b\n" "$C_CYAN" "$question" "$C_RESET"
            echo ""
            printf "  %b> %b" "$C_BOLD" "$C_RESET"
            local answer
            read -r answer < /dev/tty
            if [ -z "$answer" ]; then
                ui_dim "  No answer — proceeding with available info."
                # Force plan on next round
                clarify_round=$AGENT_MAX_CLARIFY
            else
                context="${context:+$context\n}$question → $answer"
            fi
        else
            # Got a plan (not a clarification request)
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
    
    # If the step is already a slash command, dispatch it directly
    # instead of asking the LLM (which wraps it in a broken ```bash block)
    if [[ "$step_desc" =~ ^/ ]] && declare -f commands_dispatch &>/dev/null; then
        if commands_dispatch "$step_desc" "$workdir"; then
            memory_append_section "Completed Steps" "Step $step_num: $step_desc" "$workdir"
            return 0
        else
            local err_msg="Slash command failed: $step_desc"
            ui_err "$err_msg"
            memory_append_section "Errors" "Step $step_num failed: $step_desc" "$workdir"
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
    
    # Normalize inline plans: "1. foo  2. bar" → separate lines
    plan=$(_agent_split_inline_steps "$plan")

    # Parse steps — numbered lines like "1. Do something" or "1) Do something"
    # Also accept slash command lines as steps (model sometimes outputs those)
    local -a steps=()
    while IFS= read -r line; do
        # Numbered list item: "1. thing" or "1) thing" or "1 thing"
        if [[ "$line" =~ ^[0-9]+[\.\)\ ] ]]; then
            local step_text
            step_text=$(echo "$line" | sed 's/^[0-9]*[.)[:space:]]*//')
            [ -n "$step_text" ] && steps+=("$step_text")
        # Slash command line (e.g., "/recall query" or "/sandbox create 1")
        elif [[ "$line" =~ ^/ ]] && [ -n "$line" ]; then
            steps+=("$line")
        # Dash/bullet list item: "- Do something" or "* Do something"
        elif [[ "$line" =~ ^[-\*]\ + ]]; then
            local step_text
            step_text=$(echo "$line" | sed 's/^[-*][[:space:]]*//')
            [ -n "$step_text" ] && steps+=("$step_text")
        fi
    done <<< "$plan"
    
    local total=${#steps[@]}
    if [ "$total" -eq 0 ]; then
        # If plan parsing fails, treat the whole thing as one step
        ui_warn "Could not parse plan. Executing as single step."
        steps=("$task")
        total=1
    fi
    
    ui_info "Executing $total steps..."
    echo ""
    
    # Phase 2: Execute
    local completed=0
    local failed_steps=""
    for i in "${!steps[@]}"; do
        # Check for cancellation between steps (file + variable)
        if [ "${_LODGE_CANCELLED:-0}" -eq 1 ] || [ -f "$_cancel_file" ]; then
            ui_warn "Task cancelled at step $((i + 1))/$total"
            break
        fi
        
        local step_num=$((i + 1))
        
        ui_progress "$step_num" "$total" "${steps[$i]:0:30}"
        
        if agent_execute_step "$step_num" "${steps[$i]}" "$workdir" "$task"; then
            completed=$((completed + 1))
        else
            failed_steps="${failed_steps:+${failed_steps}, }step $step_num: ${steps[$i]}"
            # Check if failure was due to cancellation
            if [ "${_LODGE_CANCELLED:-0}" -eq 1 ] || [ -f "$_cancel_file" ]; then
                ui_warn "Step $step_num cancelled"
                break
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
