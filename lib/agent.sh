#!/bin/bash
# ── Blue Lodge: Agent Loop ─────────────────────────────────────
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
    
    local system_prompt
    system_prompt=$(memory_build_system_prompt "$workdir")
    
    local prompt="TASK: $task

Create a step-by-step plan. Rules:
- Max 8 steps
- Each step must be completable in ONE LLM call
- Each step should be a single action (write one file, run one command, etc.)
- Output ONLY a numbered list. No explanations.
- If the task is simple (1-2 steps), use fewer steps."
    
    ui_think "Planning..."
    local plan
    plan=$(llm_generate "$prompt" "$system_prompt")
    
    if [ $? -ne 0 ] || [[ "$plan" == ERROR* ]]; then
        ui_err "Planning failed: $plan"
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
    
    ui_spinner_start "Generating"
    local response
    response=$(llm_generate "$prompt" "$system_prompt")
    local llm_exit=$?
    ui_spinner_stop
    
    if [ $llm_exit -ne 0 ] || [[ "$response" == ERROR* ]]; then
        ui_err "Step failed: $response"
        memory_append_section "Errors" "Step $step_num failed: $response" "$workdir"
        return 1
    fi
    
    # Show the response
    ui_render_response "$response"
    
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
    
    ui_section "Task"
    ui_info "$task"
    
    # Phase 1: Plan
    local plan
    plan=$(agent_plan "$task" "$workdir")
    if [ $? -ne 0 ]; then return 1; fi
    
    ui_section "Plan"
    echo "$plan" | while IFS= read -r line; do
        [ -n "$line" ] && ui_dim "$line"
    done
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
        local step_num=$((i + 1))
        
        ui_progress "$step_num" "$total" "${steps[$i]:0:30}"
        
        if agent_execute_step "$step_num" "${steps[$i]}" "$workdir"; then
            completed=$((completed + 1))
        else
            ui_warn "Step $step_num failed. Continue? [Y/n]"
            read -r cont
            if [[ "${cont,,}" == "n" ]]; then
                ui_warn "Stopped at step $step_num"
                break
            fi
        fi
        
        # Delay between steps
        sleep "$AGENT_STEP_DELAY"
        
        # Compact memory if it's getting long
        if [ "$step_num" -gt 8 ]; then
            memory_compact "$workdir"
        fi
    done
    
    # Phase 3: Summary
    echo ""
    ui_divider
    ui_ok "Task complete: $completed/$total steps succeeded"
    
    # Phase 4: Reflect in journal
    journal_reflect "$task ($completed/$total steps in $(basename "$workdir"))" "$workdir"
    
    # Notify on phone if available
    tools_phone_toast "Lodge: Task complete ($completed/$total steps)"
    
    return 0
}

# ── Single-shot ask (no planning, just answer) ────────────────
agent_ask() {
    local question="$1"
    local workdir="${2:-.}"
    
    local system_prompt
    system_prompt=$(memory_build_system_prompt "$workdir")
    
    ui_spinner_start "Thinking"
    local response
    response=$(llm_generate "$question" "$system_prompt")
    ui_spinner_stop
    
    if [[ "$response" == ERROR* ]]; then
        ui_err "$response"
        return 1
    fi
    
    echo ""
    ui_render_response "$response"
    echo ""
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
