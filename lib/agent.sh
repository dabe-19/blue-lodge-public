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

# ── Plan a task ────────────────────────────────────────────────
agent_plan() {
    local task="$1"
    local workdir="${2:-.}"
    
    # Use lean "plan" mode — ~1,500 tokens instead of ~3,100
    local system_prompt
    system_prompt=$(memory_build_system_prompt "$workdir" "" "plan")
    
    local prompt="TASK: $task

Create a step-by-step plan. Rules:
- Use the FEWEST steps necessary. Most tasks need 1-4 steps.
- Never add filler steps. If the task needs 1 step, output 1 step.
- Absolute maximum: 8 steps. Only complex multi-file tasks should approach this.
- Each step must be completable in ONE LLM call.
- Each step must be a single action (write one file, run one command, etc.)
- Output ONLY a numbered list. No explanations."
    
    # Stream the plan so user sees progress in real-time
    echo ""
    ui_dim "  Plan:"
    local plan
    plan=$(llm_stream "$prompt" "$system_prompt" 512)
    echo ""
    
    if [ -z "$plan" ] || [[ "$plan" == ERROR* ]]; then
        ui_err "Planning failed: ${plan:-empty response}"
        return 1
    fi
    
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
    
    local system_prompt
    system_prompt=$(memory_build_system_prompt "$workdir")
    
    local prompt="CURRENT STEP ($step_num): $step_desc

Execute this step. Output rules:
- Shell commands: wrap in \`\`\`bash block
- File contents: wrap in a code block with '# filepath: ./path' on line 1
- Keep output minimal
- One action per response"
    
    ui_section "Step $step_num"
    ui_step "$step_desc"
    
    # Stream the step response so user sees it being generated
    echo ""
    local response
    response=$(llm_stream "$prompt" "$system_prompt" "$LLM_MAX_TOKENS")
    echo ""
    
    if [ -z "$response" ] || [[ "$response" == ERROR* ]]; then
        ui_err "Step failed: ${response:-empty response}"
        memory_append_section "Errors" "Step $step_num failed: ${response:-empty}" "$workdir"
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
    
    ui_section "Task"
    ui_info "$task"
    
    # Phase 1: Plan (user sees it streamed in real-time via /dev/tty)
    local plan
    plan=$(agent_plan "$task" "$workdir")
    if [ $? -ne 0 ] || [ "${_LODGE_CANCELLED:-0}" -eq 1 ]; then
        _LODGE_IN_TASK=0
        return 1
    fi
    echo ""
    
    # Parse steps
    local -a steps=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^[0-9]+[\.\)\ ] ]]; then
            local step_text
            step_text=$(echo "$line" | sed 's/^[0-9]*[.)[:space:]]*//')
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
    for i in "${!steps[@]}"; do
        # Check for cancellation between steps
        if [ "${_LODGE_CANCELLED:-0}" -eq 1 ]; then
            ui_warn "Task cancelled at step $((i + 1))/$total"
            break
        fi
        
        local step_num=$((i + 1))
        
        ui_progress "$step_num" "$total" "${steps[$i]:0:30}"
        
        if agent_execute_step "$step_num" "${steps[$i]}" "$workdir"; then
            completed=$((completed + 1))
        else
            # Check if failure was due to cancellation
            if [ "${_LODGE_CANCELLED:-0}" -eq 1 ]; then
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
    journal_reflect "$task ($completed/$total steps in $(basename "$workdir"))" "$workdir" &
    
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
