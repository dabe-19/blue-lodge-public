#!/bin/bash
# ── George Slash Command: /dispatch ───────────────────────────────────
# DESC: Dispatch the-dispatcher multi-agent pipeline with a feature contract
# USAGE: /dispatch [contract_file | task_description]

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/workflows.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/react.sh" 2>/dev/null || true

cmd_dispatch() {
    local args="$1"
    local workdir="${2:-$PWD}"

    local contract_file=""
    if [ -n "$args" ] && [ -f "$args" ]; then
        contract_file="$args"
    elif [ -n "$args" ] && [ -f "$workdir/$args" ]; then
        contract_file="$workdir/$args"
    elif [ -f "$workdir/.george/contracts/latest.contract.md" ]; then
        contract_file="$workdir/.george/contracts/latest.contract.md"
    fi

    ui_section "Blue Lodge Multi-Agent Pipeline Dispatch"
    if [ -n "$contract_file" ]; then
        ui_step "Dispatching with contract: $contract_file"
        local contract_content
        contract_content=$(cat "$contract_file" 2>/dev/null)
        workflows_run "dispatcher.agent" "Execute contract: $contract_file\n\n$contract_content" "$workdir"
    else
        local goal="${args:-Execute pending implementation contract}"
        ui_step "Dispatching pipeline for goal: $goal"
        workflows_run "dispatcher.agent" "$goal" "$workdir"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_dispatch "$@"
fi
