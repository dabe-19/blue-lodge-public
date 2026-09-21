#!/bin/bash
# ── George: Agent Workflow Engine (2026) ─────────────────────────────
# Discovers, parses, and executes Lodge multi-agent workflows (.agent.md)
# inside the George REPL and subagent sandboxes.
# Replaces the deprecated Strategist/Honeydew dual loop.

[ -n "${_LIB_WORKFLOWS_LOADED:-}" ] && return 0; _LIB_WORKFLOWS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_CONFIG_DIR="${GEORGE_CONFIG_DIR:-${LODGE_DIR}/.george}"

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/subagents.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/react.sh" 2>/dev/null || true

# ── Workflow Directory Resolution ─────────────────────────────────────
workflows_dir() {
    local workdir="${1:-$PWD}"
    if [ -d "$workdir/.agents/workflows" ]; then
        echo "$workdir/.agents/workflows"
    elif [ -d "$LODGE_DIR/.agents/workflows" ]; then
        echo "$LODGE_DIR/.agents/workflows"
    else
        echo "$LODGE_DIR/.agents/workflows"
    fi
}

# ── Alias Normalizer ──────────────────────────────────────────────────
workflows_normalize_name() {
    local raw="$1"
    raw="${raw#/}" # strip leading slash
    raw="${raw,,}" # lowercase
    raw="${raw%.agent.md}"
    raw="${raw%.agent}"
    raw="${raw%.md}"

    case "$raw" in
        architect|the-architect|plan)
            echo "the-architect" ;;
        dispatcher|dispatch)
            echo "dispatcher" ;;
        george)
            echo "george" ;;
        tyler|the-tyler|security)
            echo "the-tyler" ;;
        warden|the-warden|style)
            echo "the-warden" ;;
        chronicler|the-chronicler|docs)
            echo "the-chronicler" ;;
        quartermaster|tooling|env)
            echo "quartermaster" ;;
        tester|test|verify)
            echo "tester" ;;
        git-manager|git)
            echo "git-manager" ;;
        trowel|finish|complete)
            echo "trowel" ;;
        deacon|the-deacon)
            echo "the-deacon" ;;
        secretary|the-secretary)
            echo "the-secretary" ;;
        trestleboard|the-trestleboard)
            echo "the-trestleboard" ;;
        repl-specialist|repl)
            echo "repl-specialist" ;;
        core-specialist|core)
            echo "core-specialist" ;;
        commands-specialist|commands)
            echo "commands-specialist" ;;
        ui-specialist|ui)
            echo "ui-specialist" ;;
        tests-specialist|tests)
            echo "tests-specialist" ;;
        *)
            echo "$raw" ;;
    esac
}

# ── Locate Workflow File ──────────────────────────────────────────────
workflows_get_file() {
    local name="$1"
    local workdir="${2:-$PWD}"
    local wf_dir
    wf_dir=$(workflows_dir "$workdir")

    local norm
    norm=$(workflows_normalize_name "$name")

    # Direct checks
    if [ -f "$wf_dir/${norm}.agent.md" ]; then
        echo "$wf_dir/${norm}.agent.md"
        return 0
    elif [ -f "$wf_dir/${norm}.md" ]; then
        echo "$wf_dir/${norm}.md"
        return 0
    elif [ -f "$wf_dir/the-${norm}.agent.md" ]; then
        echo "$wf_dir/the-${norm}.agent.md"
        return 0
    elif [ -f "$wf_dir/${norm}-specialist.agent.md" ]; then
        echo "$wf_dir/${norm}-specialist.agent.md"
        return 0
    fi

    # Fallback search across directory
    local candidate
    candidate=$(find "$wf_dir" -maxdepth 1 -iname "*${norm}*.md" 2>/dev/null | head -1)
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
        echo "$candidate"
        return 0
    fi

    return 1
}

# ── Parse Workflow Metadata ───────────────────────────────────────────
workflows_parse_meta() {
    local file="$1"
    [ -f "$file" ] || return 1

    local name="" desc="" arg_hint="" target=""
    name=$(basename "$file" | sed -E 's/\.(agent\.)?md$//')

    # Parse YAML frontmatter between first two '---' lines
    local fm
    fm=$(awk '/^---/{flag++; next} flag==1{print} flag>=2{exit}' "$file")

    local fm_name fm_desc fm_hint fm_target
    fm_name=$(echo "$fm" | grep -i '^name:' | head -1 | sed 's/^name:[[:space:]]*//' | tr -d '"'\''')
    fm_desc=$(echo "$fm" | grep -i '^description:' | head -1 | sed 's/^description:[[:space:]]*//' | tr -d '"'\''')
    fm_hint=$(echo "$fm" | grep -i '^argument-hint:' | head -1 | sed 's/^argument-hint:[[:space:]]*//' | tr -d '"'\''')
    fm_target=$(echo "$fm" | grep -i '^target:' | head -1 | sed 's/^target:[[:space:]]*//' | tr -d '"'\''')

    [ -n "$fm_name" ] && name="$fm_name"
    [ -z "$fm_desc" ] && fm_desc="Workflow: $name"

    jq -n \
       --arg name "$name" \
       --arg desc "$fm_desc" \
       --arg hint "$fm_hint" \
       --arg target "$fm_target" \
       --arg file "$file" \
       '{name: $name, description: $desc, argument_hint: $hint, target: $target, file: $file}'
}

# ── List All Workflows ────────────────────────────────────────────────
workflows_list() {
    local workdir="${1:-$PWD}"
    local wf_dir
    wf_dir=$(workflows_dir "$workdir")

    local items=()
    if [ -d "$wf_dir" ]; then
        for f in "$wf_dir"/*.md; do
            [ -f "$f" ] || continue
            # Skip templates or raw guides
            [[ "$(basename "$f")" == "README.md" ]] && continue
            local meta
            meta=$(workflows_parse_meta "$f")
            [ -n "$meta" ] && items+=("$meta")
        done
    fi

    if [ ${#items[@]} -eq 0 ]; then
        echo "[]"
        return 0
    fi

    printf '%s\n' "${items[@]}" | jq -s 'sort_by(.name)'
}

# ── Format List for Terminal UI ───────────────────────────────────────
workflows_print_list() {
    local workdir="${1:-$PWD}"
    local json
    json=$(workflows_list "$workdir")

    ui_section "Available Agent Workflows (.agents/workflows)"

    local count
    count=$(echo "$json" | jq '. | length' 2>/dev/null || echo 0)

    if [ "$count" -eq 0 ]; then
        ui_dim "  No workflows discovered in $(workflows_dir "$workdir")."
        return 0
    fi

    echo "$json" | jq -r '.[] | "  \u001b[1;36m/" + .name + "\u001b[0m — " + .description' | while IFS= read -r line; do
        echo -e "$line"
    done
    echo ""
    ui_dim "Run /workflow run <name> [args] or invoke directly (e.g. /the-architect, /dispatcher, /george)"
}

# ── Extract Persona, Rules & Workflow Body ────────────────────────────
workflows_extract_sections() {
    local file="$1"
    [ -f "$file" ] || return 1

    local rules workflow_steps body
    # Extract rules block: between <rules> and </rules>
    rules=$(awk '/<rules>/{flag=1; next} /<\/rules>/{flag=0} flag' "$file")
    # Extract workflow block: between <workflow> and </workflow>
    workflow_steps=$(awk '/<workflow>/{flag=1; next} /<\/workflow>/{flag=0} flag' "$file")
    # Body outside frontmatter
    body=$(awk '/^---/{c++; next} c>=2{print}' "$file")

    jq -n \
       --arg file "$file" \
       --arg rules "$rules" \
       --arg steps "$workflow_steps" \
       --arg body "$body" \
       '{file: $file, rules: $rules, steps: $steps, body: $body}'
}

# ── Build Specialized Prompt for Workflow ─────────────────────────────
workflows_build_prompt() {
    local name="$1"
    local args="$2"
    local workdir="${3:-$PWD}"
    local file
    file=$(workflows_get_file "$name" "$workdir") || return 1

    local sections
    sections=$(workflows_extract_sections "$file")
    local rules steps body
    rules=$(echo "$sections" | jq -r '.rules // empty')
    steps=$(echo "$sections" | jq -r '.steps // empty')
    body=$(echo "$sections" | jq -r '.body // empty')

    local prompt=""
    prompt+="<agent_workflow_instruction>\n"
    prompt+="You are executing the sovereign agent workflow: $name.\n"
    [ -n "$args" ] && prompt+="Objective/Context: $args\n"
    prompt+="\n"

    if [ -n "$rules" ]; then
        prompt+="<rules>\n$rules\n</rules>\n\n"
    fi

    if [ -n "$steps" ]; then
        prompt+="<workflow_steps>\n$steps\n</workflow_steps>\n\n"
    else
        prompt+="$body\n\n"
    fi

    prompt+="Execute the workflow steps with craftsmanship and precision.\n"
    prompt+="</agent_workflow_instruction>"

    echo -e "$prompt"
}

# ── Execute Workflow ──────────────────────────────────────────────────
workflows_run() {
    local name="$1"
    local args="${2:-}"
    local workdir="${3:-$PWD}"

    local norm
    norm=$(workflows_normalize_name "$name")
    local file
    file=$(workflows_get_file "$norm" "$workdir")

    if [ -z "$file" ] || [ ! -f "$file" ]; then
        ui_err "Workflow '$name' not found in $(workflows_dir "$workdir")"
        return 1
    fi

    local meta
    meta=$(workflows_parse_meta "$file")
    local wf_title wf_desc
    wf_title=$(echo "$meta" | jq -r '.name')
    wf_desc=$(echo "$meta" | jq -r '.description')

    ui_header "Executing Workflow: /$wf_title" "$wf_desc"

    # Specific Workflow Intercepts for Deep Interactive Flow
    case "$norm" in
        the-architect|architect|plan)
            _workflow_run_architect "$args" "$workdir" "$file"
            return $?
            ;;
        dispatcher|dispatch)
            _workflow_run_dispatcher "$args" "$workdir" "$file"
            return $?
            ;;
        george)
            _workflow_run_george "$args" "$workdir" "$file"
            return $?
            ;;
        the-tyler|tyler)
            _workflow_run_tyler "$args" "$workdir" "$file"
            return $?
            ;;
        the-warden|warden)
            _workflow_run_warden "$args" "$workdir" "$file"
            return $?
            ;;
        *)
            # Generic workflow execution via ReAct engine with injected workflow rules
            local wf_prompt
            wf_prompt=$(workflows_build_prompt "$norm" "$args" "$workdir")
            local exec_goal="Workflow /$wf_title: ${args:-Execute defined workflow steps}"
            react_run "$exec_goal\n\n$wf_prompt" "$workdir"
            return $?
            ;;
    esac
}

# ── Specialized Workflow: The Architect (Interactive Planning) ─────────
_workflow_run_architect() {
    local objective="$1"
    local workdir="$2"
    local wf_file="$3"

    ui_step "The Architect: Initiating interactive planning workflow..."

    # 1. Discover Project Reality
    local proj_doc="$workdir/GEORGE.md"
    if [ ! -f "$proj_doc" ]; then
        ui_warn "No GEORGE.md found in workspace. Searching for context..."
    else
        ui_ok "Discovered workspace status: $proj_doc"
    fi

    if [ -z "$objective" ]; then
        if [ -t 0 ]; then
            echo -en "${C_CYAN}Enter feature objective or issue description for the plan:${C_RESET} "
            read -r objective
        fi
    fi

    if [ -z "$objective" ]; then
        ui_err "The Architect requires an objective to plan."
        return 1
    fi

    local plan_path="$workdir/implementation_plan.md"
    ui_info "Drafting implementation plan for: $objective"
    ui_dim "Target plan artifact: $plan_path"

    # Run ReAct in Architect Persona to draft implementation_plan.md
    local wf_prompt
    wf_prompt=$(workflows_build_prompt "the-architect" "$objective" "$workdir")
    
    local architect_instruction
    architect_instruction="You are THE ARCHITECT. Research the codebase using file_read, dir_list, file_grep, and web_search. Then create a complete, actionable technical plan and save it directly to 'implementation_plan.md' in the current workspace.
The plan MUST follow the structure:
### Feature Overview
### Layer Changes
### Scope Boundaries
### Touched Layers (Handoff Routing)
- **core-specialist**: yes | no
- **commands-specialist**: yes | no
- **ui-specialist**: yes | no
- **tests-specialist**: yes | no
- **repl-specialist**: yes | no
### Tooling Layer (Provisioning): yes | no
### Functional Verification: yes | no
### Security: yes | no
### Style: yes | no
### Verification Plan

Do NOT modify any source code files—your ONLY deliverable is 'implementation_plan.md'. Once written, summarize the plan."

    react_run "$architect_instruction\n\n$wf_prompt\n\nOBJECTIVE: $objective" "$workdir"
    local rc=$?

    if [ -f "$plan_path" ]; then
        ui_ok "Plan created: $plan_path"
        echo ""
        ui_section "Next Step"
        echo -e "Review ${C_BOLD}$plan_path${C_RESET}, then run ${C_CYAN}/dispatcher${C_RESET} to execute the pipeline."
    fi
    return $rc
}

# ── Specialized Workflow: The Dispatcher (Pipeline Orchestrator) ───────
_workflow_run_dispatcher() {
    local args="$1"
    local workdir="$2"
    local wf_file="$3"

    local plan_path="$workdir/implementation_plan.md"
    if [ ! -f "$plan_path" ]; then
        ui_err "No implementation_plan.md found in $workdir."
        ui_dim "Run /the-architect or /plan first to draft an implementation plan."
        return 1
    fi

    ui_step "Dispatcher: Reading $plan_path..."

    # Parse Touched Layers from plan
    local run_core=0 run_cmds=0 run_ui=0 run_repl=0 run_tests=0 run_tooling=0 run_verify=1 run_sec=0 run_style=0

    grep -iq -- "- \*\*core-specialist\*\*: *yes" "$plan_path" && run_core=1
    grep -iq -- "- \*\*commands-specialist\*\*: *yes" "$plan_path" && run_cmds=1
    grep -iq -- "- \*\*ui-specialist\*\*: *yes" "$plan_path" && run_ui=1
    grep -iq -- "- \*\*repl-specialist\*\*: *yes" "$plan_path" && run_repl=1
    grep -iq -- "- \*\*tests-specialist\*\*: *yes" "$plan_path" && run_tests=1
    grep -iq -- "- \*\*Tooling\*\*: *yes" "$plan_path" && run_tooling=1
    grep -iq -- "- \*\*Verification\*\*: *no" "$plan_path" && run_verify=0
    grep -iq -- "- \*\*Security\*\*: *yes" "$plan_path" && run_sec=1
    grep -iq -- "- \*\*Style\*\*: *yes" "$plan_path" && run_style=1

    ui_section "Pipeline Schedule"
    [ "$run_tooling" -eq 1 ] && ui_info "1. /quartermaster (Tooling & Dependencies)"
    [ "$run_core" -eq 1 ] && ui_info "2. /core-specialist (Core Engine & Libs)"
    [ "$run_cmds" -eq 1 ] && ui_info "3. /commands-specialist (Commands & Dispatcher)"
    [ "$run_ui" -eq 1 ] && ui_info "4. /ui-specialist (Terminal UI)"
    [ "$run_repl" -eq 1 ] && ui_info "5. /repl-specialist (REPL Sandbox)"
    [ "$run_tests" -eq 1 ] && ui_info "6. /tests-specialist (Test Harness & Framework)"
    [ "$run_verify" -eq 1 ] && ui_info "7. /tester (End-to-End Functional Verification)"
    ui_info "8. /george (Senior Technical Audit — Sec: $run_sec, Style: $run_style)"
    ui_info "9. /the-chronicler (Documentation & Changelogs)"
    ui_info "10. /git-manager (Conventional Commit & Push)"
    echo ""

    # Execute Dispatcher loop
    local wf_prompt
    wf_prompt=$(workflows_build_prompt "dispatcher" "$args" "$workdir")

    local dispatcher_instruction
    dispatcher_instruction="You are DISPATCHER, pipeline orchestrator for Blue Lodge. Read implementation_plan.md. Execute the required specialists in fixed sequence. For each layer marked 'yes', implement the necessary edits, verify the layer with localized tests, and document the results. Then route to verification and audit."

    react_run "$dispatcher_instruction\n\n$wf_prompt" "$workdir"
    return $?
}

# ── Specialized Workflow: George (Senior Auditor) ──────────────────────
_workflow_run_george() {
    local args="$1"
    local workdir="$2"
    local wf_file="$3"

    ui_step "George: Conducting Senior Technical Audit..."

    local wf_prompt
    wf_prompt=$(workflows_build_prompt "george" "$args" "$workdir")
    local audit_instruction="You are GEORGE, Senior Technical Auditor. Audit the changes in git status and diff against the rules of Blue Lodge craftsmanship, zero-leak sandboxing, test coverage, and POSIX compliance. Perform security and style passes. Provide an explicit audit verdict: PASS or FAIL."

    react_run "$audit_instruction\n\n$wf_prompt\n\nCONTEXT: $args" "$workdir"
    return $?
}

# ── Specialized Workflow: The Tyler (Security Auditor) ─────────────────
_workflow_run_tyler() {
    local args="$1"
    local workdir="$2"
    local wf_file="$3"

    ui_step "The Tyler: Initiating Security & Prompt Injection Audit..."

    local wf_prompt
    wf_prompt=$(workflows_build_prompt "the-tyler" "$args" "$workdir")
    local tyler_instruction="You are THE TYLER, the Inner Guard and Security Auditor. Audit the recent changes for command injection, unsanitized parameters, shell escaping vulnerabilities, credential leaks, and prompt injection risks. Output a structured Security Audit finding list."

    react_run "$tyler_instruction\n\n$wf_prompt\n\nTARGET: $args" "$workdir"
    return $?
}

# ── Specialized Workflow: The Warden (Style Auditor) ───────────────────
_workflow_run_warden() {
    local args="$1"
    local workdir="$2"
    local wf_file="$3"

    ui_step "The Warden: Initiating Architecture & Style Audit..."

    local wf_prompt
    wf_prompt=$(workflows_build_prompt "the-warden" "$args" "$workdir")
    local warden_instruction="You are THE WARDEN, Architecture and Style Auditor. Review the code for adherence to pure POSIX shell standards, modularity, readability, zero-dependency requirements, and craftsmanship conventions. Output a structured Style & Architecture report."

    react_run "$warden_instruction\n\n$wf_prompt\n\nTARGET: $args" "$workdir"
    return $?
}
