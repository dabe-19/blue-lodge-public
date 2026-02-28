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
AGENT_MAX_STEPS="${AGENT_MAX_STEPS:-20}"       # Macro loop milestone ceiling
AGENT_PLAN_STEPS="${AGENT_PLAN_STEPS:-5}"      # Max steps per plan/subtask
AGENT_INNER_LOOPS="${AGENT_INNER_LOOPS:-6}"    # Inner loop escalation ceiling
AGENT_STEP_DELAY="${AGENT_STEP_DELAY:-1}"
AGENT_MAX_CLARIFY="${AGENT_MAX_CLARIFY:-2}"
AGENT_INTERACTIVE_PLANNING="${AGENT_INTERACTIVE_PLANNING:-0}"
AGENT_MAX_DEPTH="${AGENT_MAX_DEPTH:-2}"        # Subtask recursion depth
AGENT_WEB_SUFFICIENCY="${AGENT_WEB_SUFFICIENCY:-3}"  # Web actions before sufficiency signal
AGENT_MAX_MILESTONE_RETRIES="${AGENT_MAX_MILESTONE_RETRIES:-2}"  # Max times to retry same milestone
AGENT_EVAL_MODE="${AGENT_EVAL_MODE:-auto}"              # Evaluator mode: auto | interactive | disabled

LLM_EVALUATOR_TOKENS="${LLM_EVALUATOR_TOKENS:-512}"     # Max output tokens for evaluator

# ── Task Completion Evaluator ──────────────────────────────────
# Impartial judge with no personality injection. Reads micro_memory.md
# (concise Action/Status/Output log) rather than the full macro_memory
# (which carries persona bloat and stale placeholders). The primary
# objective is extracted from macro_memory for reference.
# Returns 0 if the task is complete, 1 if work remains.
#
# Modes (AGENT_EVAL_MODE):
#   auto        — (default) Silently finish the task chain with a summary.
#   interactive — Prompt the operator to confirm satisfaction or continue.
_agent_evaluate_completion() {
    local macro_file="$1"
    local micro_file="$2"

    # Extract ONLY the primary objective from macro_memory (skip persona bloat)
    local primary_obj
    primary_obj=$(awk '/^## Primary Objective/{getline; if(NF) print; exit}' "$macro_file" 2>/dev/null)
    [ -z "$primary_obj" ] && { ui_info "Evaluator: no primary objective found"; return 1; }

    # Use micro_memory as evaluation context — it's concise with clear
    # Action/Status/Output entries. Falls back to macro if micro unavailable.
    local eval_context
    if [ -n "$micro_file" ] && [ -f "$micro_file" ]; then
        eval_context=$(cat "$micro_file")
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: evaluator <- micro_memory ($(wc -l < "$micro_file") lines)"
    else
        eval_context=$(cat "$macro_file")
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: evaluator <- macro_memory fallback ($(wc -l < "$macro_file") lines)"
    fi

    # Truncate eval_context to the last N lines to prevent attention
    # dilution. When micro_memory grows huge (50+ actions), the primary
    # objective at the top of the prompt gets washed out by recency bias
    # in small models. Keeping only the tail + reordering (below) ensures
    # the objective gets maximum attention.
    local _max_ctx_lines="${AGENT_EVAL_CONTEXT_LINES:-50}"
    local _ctx_total
    _ctx_total=$(echo "$eval_context" | wc -l)
    if [ "$_ctx_total" -gt "$_max_ctx_lines" ]; then
        eval_context=$(echo "$eval_context" | tail -n "$_max_ctx_lines")
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] eval context truncated: $_ctx_total -> $_max_ctx_lines lines"
    fi

    # Build a strict, personality-free evaluation prompt.
    # ATTENTION REORDER: Action log comes FIRST so that the primary
    # objective and evaluation criteria sit at the END of the prompt
    # where small models pay the most attention (recency bias). This
    # prevents the objective from being buried under pages of action log.
    local eval_prompt="ACTION LOG (from the most recent milestone — review for successful actions):\n${eval_context}\n\n---\n\nPRIMARY OBJECTIVE (the original user request):\n${primary_obj}\n\nEvaluate whether ALL parts of the primary objective above have been satisfied by the Action Log.\n\nSTEP 1: Decompose the objective into distinct required parts.\n  Example: 'research X, write a report, and email it to Y' has THREE parts:\n    a) research X  b) write a report  c) email it to Y\n\nSTEP 2: For each part, check the Action Log for an action that addresses it.\n  - A relevant action with Status EXECUTED SUCCESSFULLY (exit 0) satisfies that part.\n  - Output may be empty — many tools (email, social) produce no output on success. That is normal.\n  - Do NOT count research/search as satisfying a 'write report' or 'email' part.\n\nSTEP 3: If ANY required part has no corresponding successful action, respond INCOMPLETE.\n\nCRITICAL RULES:\n- Do NOT treat the word SUCCESS in the log as automatic proof — verify the Action actually addresses each part.\n- A web search only satisfies a 'research' or 'find information' part — NOT a 'write', 'email', 'post', or 'send' part.\n- ALL parts must be satisfied for COMPLETE. Even one missing part means INCOMPLETE.\n\nRespond with EXACTLY one of:\n  COMPLETE\n  INCOMPLETE: <one-sentence reason what is still missing>\n\nExamples:\n  COMPLETE\n  INCOMPLETE: the report has not been written yet\n  INCOMPLETE: email was never sent to the recipient"

    local eval_sys="You are a strict task-completion evaluator. Decompose multi-part objectives into distinct required parts and verify each has a corresponding successful action. A web search satisfies research, but NOT writing, emailing, or posting. Output may be empty for successful commands — that is normal. Respond COMPLETE or INCOMPLETE: <reason>."

    ui_think "Evaluator: assessing task completion..."
    local verdict
    local LLM_SCENARIO=evaluator
    verdict=$(llm_generate "$eval_prompt" "$eval_sys" "${LLM_EVALUATOR_TOKENS:-512}" "$LLM_BUDGET_AGENT")

    # Clean up LLM output — strip think blocks, whitespace
    verdict=$(echo "$verdict" | sed ':a;N;$!ba;s/<think>[^<]*<\/think>//g')
    verdict=$(echo "$verdict" | sed 's/\[THINK\][^[]*\[\/THINK\]//gI')
    verdict=$(echo "$verdict" | sed '/^[[:space:]]*$/d' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # Extract the first meaningful line
    local first_line
    first_line=$(echo "$verdict" | head -1)

    # Parse verdict word and optional reason
    local verdict_word
    verdict_word=$(echo "$first_line" | awk '{print $1}')

    # Extract INCOMPLETE reason: smart parse per user spec
    # - If "INCOMPLETE: reason", take after colon
    # - If "INCOMPLETE" with no colon but text follows, take full remaining text
    # - If no text at all, reason stays empty (that's OK)
    _EVAL_INCOMPLETE_REASON=""
    if [[ "$verdict_word" != "COMPLETE" ]]; then
        if [[ "$first_line" == *":"* ]]; then
            _EVAL_INCOMPLETE_REASON=$(echo "$first_line" | sed 's/^[^:]*:[[:space:]]*//')
        elif [ "$(echo "$first_line" | wc -w)" -gt 1 ]; then
            _EVAL_INCOMPLETE_REASON=$(echo "$first_line" | sed 's/^[^ ]* *//')
        fi
        # If reason is still empty but there are more lines, use entire output
        if [ -z "$_EVAL_INCOMPLETE_REASON" ] && [ "$(echo "$verdict" | wc -l)" -gt 1 ]; then
            _EVAL_INCOMPLETE_REASON=$(echo "$verdict" | head -3)
        fi
        local _reason_display="${_EVAL_INCOMPLETE_REASON:+(${_EVAL_INCOMPLETE_REASON:0:80})}"
        ui_info "Evaluator: objective not yet fulfilled ${_reason_display}— continuing"
        return 1
    fi

    # ── Task is complete — handle by mode ──────────────────────
    ui_ok "Evaluator: primary objective fulfilled"

    if [[ "${AGENT_EVAL_MODE:-auto}" == "interactive" ]]; then
        # Interactive mode: ask the operator
        echo ""
        ui_info "The evaluator believes the original request has been completed."
        printf " %b%s%b %b%s%b " "\033[1;37m" "Are you satisfied with the result?" "\033[0m" "\033[2m" "[Y/n]" "\033[0m"
        local answer
        read -r answer < /dev/tty 2>/dev/null || answer="y"
        answer="${answer:-y}"
        if [[ "${answer,,}" == "y"* ]]; then
            local summary_prompt="Summarize briefly: the user asked to '${primary_obj}'. Based on this action log, what was accomplished?\n\n${eval_context}"
            local summary_sys="You are a concise summarizer. No personality. Output only the summary in 2-3 sentences."
            local task_summary
            local LLM_SCENARIO=evaluator
            task_summary=$(llm_generate "$summary_prompt" "$summary_sys" "${LLM_EVALUATOR_TOKENS:-512}" "$LLM_BUDGET_AGENT")
            task_summary=$(echo "$task_summary" | sed ':a;N;$!ba;s/<think>[^<]*<\/think>//g')
            task_summary=$(echo "$task_summary" | sed '/^[[:space:]]*$/d' | head -5)
            echo ""
            ui_ok "Summary: $task_summary"
            return 0
        else
            ui_info "Continuing work — operator requested more progress"
            return 1
        fi
    fi

    # Auto mode (default): generate brief summary and signal completion
    local summary_prompt="Summarize briefly: the user asked to '${primary_obj}'. Based on this action log, what was accomplished?\n\n${eval_context}"
    local summary_sys="You are a concise summarizer. No personality. Output only the summary in 2-3 sentences."
    local task_summary
    local LLM_SCENARIO=evaluator
    task_summary=$(llm_generate "$summary_prompt" "$summary_sys" "${LLM_EVALUATOR_TOKENS:-512}" "$LLM_BUDGET_AGENT")
    task_summary=$(echo "$task_summary" | sed ':a;N;$!ba;s/<think>[^<]*<\/think>//g')
    task_summary=$(echo "$task_summary" | sed '/^[[:space:]]*$/d' | head -5)
    echo ""
    ui_ok "Task complete — $task_summary"
    return 0
}

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

    return 1
}

# Track the last error from agent loops for critical error detection
_AGENT_LAST_ERROR=""

# ── Auto-fix: infer sandbox type from step context ─────────────
# Given a sandbox name and surrounding plan context, infers whether
# it should be rust, python, or shell.
_agent_infer_sandbox_type() {
    local name="$1"
    local context="$2"  # full plan text or step list
    local lower
    lower=$(echo "$context $name" | tr '[:upper:]' '[:lower:]')

    # Strong signals from the commands being run
    if [[ "$lower" == *"cargo "* ]] || [[ "$lower" == *"rustc"* ]] || [[ "$lower" == *".rs"* ]] || [[ "$lower" == *"Cargo.toml"* ]]; then
        echo "rust"; return
    fi
    if [[ "$lower" == *"pip "* ]] || [[ "$lower" == *"uv "* ]] || [[ "$lower" == *"python"* ]] || [[ "$lower" == *".py"* ]] || [[ "$lower" == *"pytest"* ]]; then
        echo "python"; return
    fi
    # Name-based heuristics
    if [[ "$name" == *rust* ]] || [[ "$name" == *cargo* ]] || [[ "$name" == *crate* ]]; then
        echo "rust"; return
    fi
    if [[ "$name" == *python* ]] || [[ "$name" == *py* ]] || [[ "$name" == *flask* ]] || [[ "$name" == *django* ]]; then
        echo "python"; return
    fi
    echo "shell"
}

# ── Auto-fix: create a missing sandbox ─────────────────────────
# If a /sandbox command fails because the sandbox doesn't exist,
# infer the type and create it automatically.
_agent_auto_create_sandbox() {
    local step="$1"
    local plan_context="$2"

    # Extract sandbox name from the step
    local sandbox_name=""
    if [[ "$step" =~ ^/sandbox\ +[a-z]+\ +([^ ]+) ]]; then
        sandbox_name="${BASH_REMATCH[1]}"
    fi
    [ -z "$sandbox_name" ] && return 1

    # Only act if the sandbox doesn't exist
    local sandbox_dir="${LODGE_SANDBOXES:-${LODGE_DIR:-.}/.sandboxes}/$sandbox_name"
    [ -d "$sandbox_dir" ] && return 1

    # Infer the type
    local inferred_type
    inferred_type=$(_agent_infer_sandbox_type "$sandbox_name" "$plan_context")

    ui_warn "Sandbox '$sandbox_name' not found — auto-creating as $inferred_type"
    if declare -f sandbox_create &>/dev/null; then
        sandbox_create "$sandbox_name" "$inferred_type"
        return $?
    fi
    return 1
}

# ── Auto-fix: install missing package ──────────────────────────
# Detects common "not found" / "not installed" errors and attempts
# to install the missing tool via apt.
_agent_auto_install_package() {
    local error_msg="$1"
    local lower
    lower=$(echo "$error_msg" | tr '[:upper:]' '[:lower:]')

    local pkg=""
    # "command not found: <cmd>"
    if [[ "$lower" =~ command\ not\ found.*:?\ *([a-z0-9_-]+) ]]; then
        pkg="${BASH_REMATCH[1]}"
    # "<cmd>: not found" or "<cmd> not found"
    elif [[ "$lower" =~ ([a-z0-9_-]+):\ not\ found ]]; then
        pkg="${BASH_REMATCH[1]}"
    # "No such file or directory" for common tools
    elif [[ "$lower" =~ /usr/bin/([a-z0-9_-]+).*no\ such ]]; then
        pkg="${BASH_REMATCH[1]}"
    fi

    [ -z "$pkg" ] && return 1
    # Skip if it's a sandbox name or something obviously not a package
    [[ "$pkg" =~ ^(sandbox|lodge|george)$ ]] && return 1

    if command -v "$pkg" &>/dev/null; then
        return 1  # already installed, error was something else
    fi

    ui_warn "'$pkg' not found — attempting: apt install -y $pkg"
    if command -v apt &>/dev/null; then
        apt install -y "$pkg" 2>&1 | tail -3
        if command -v "$pkg" &>/dev/null; then
            ui_ok "Installed $pkg"
            return 0
        fi
    fi
    ui_dim "  Could not auto-install '$pkg'"
    return 1
}

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

    # Track which sandbox names get created in the plan
    local -A _sandbox_created=()

    for i in "${!steps[@]}"; do
        local step="${steps[$i]}"
        local num=$((i + 1))

        # ── Track sandbox creations ────────────────────────────
        if [[ "$step" =~ ^/sandbox\ +(new|create|init|make)\ +([^ ]+) ]]; then
            _sandbox_created["${BASH_REMATCH[2]}"]=1
        fi

        # ── Sandbox use before creation ────────────────────────
        if [[ "$step" =~ ^/sandbox\ +(run|build|test|exec|cd|status)\ +([^ ]+) ]]; then
            local _sb_name="${BASH_REMATCH[2]}"
            local _sb_dir="${LODGE_SANDBOXES:-${LODGE_DIR:-.}/.sandboxes}/$_sb_name"
            if [ -z "${_sandbox_created[$_sb_name]+x}" ] && [ ! -d "$_sb_dir" ]; then
                _AGENT_PLAN_WARNINGS="${_AGENT_PLAN_WARNINGS}\n  Step $num: /sandbox ${BASH_REMATCH[1]} '$_sb_name' — sandbox not created in plan (will auto-create)"
                warn_count=$(( warn_count + 1 ))
            fi
        fi

        # ── Hallucinated commands: /foo where foo isn't registered ──
        if [[ "$step" =~ ^/([a-zA-Z_][a-zA-Z0-9_-]*) ]]; then
            local _step_cmd="${BASH_REMATCH[1]}"
            local _cmd_found=0
            # Check registry (if populated)
            if declare -p CMD_REGISTRY &>/dev/null && [[ -n "${CMD_REGISTRY[$_step_cmd]+x}" ]]; then
                _cmd_found=1
            fi
            # Check commands dir scripts
            if [ -f "${LODGE_COMMANDS_DIR:-$LODGE_DIR/commands}/${_step_cmd}.sh" ]; then
                _cmd_found=1
            fi
            # Built-in commands
            if [[ "$_step_cmd" == "help" || "$_step_cmd" == "quit" || "$_step_cmd" == "exit" ]]; then
                _cmd_found=1
            fi
            if [ "$_cmd_found" -eq 0 ]; then
                _AGENT_PLAN_WARNINGS="${_AGENT_PLAN_WARNINGS}\n  Step $num: /$_step_cmd is not a registered command — will fail"
                warn_count=$(( warn_count + 1 ))
            fi
        fi

        # Hallucinated URLs: placeholder domains like your-repo, your-link, example.com
        if [[ "$step" =~ (your-repo|your-link|your-url|example\.com|placeholder|your-name|your-user) ]]; then
            _AGENT_PLAN_WARNINGS="${_AGENT_PLAN_WARNINGS}\n  Step $num: Contains placeholder URL/name — will fail"
            warn_count=$(( warn_count + 1 ))
        fi

        # /download from a URL that was clearly invented (not from a prior step)
        if [[ "$step" =~ ^/download ]] && [[ "$step" =~ github\.com/[^/]+/[^/]+ ]] && [[ "$step" =~ (your-|example|placeholder) ]]; then
            _AGENT_PLAN_WARNINGS="${_AGENT_PLAN_WARNINGS}\n  Step $num: Downloading from hallucinated URL"
            warn_count=$(( warn_count + 1 ))
        fi

        # /save with a shell command as content (literal $(find ...) etc)
        if [[ "$step" =~ ^/save ]] && [[ "$step" =~ \$\( ]]; then
            _AGENT_PLAN_WARNINGS="${_AGENT_PLAN_WARNINGS}\n  Step $num: /save with \$(command) — will save literal text, not output"
            warn_count=$(( warn_count + 1 ))
        fi

        # /social post with unquoted multi-word text (first word gets parsed as platform)
        if [[ "$step" =~ ^/social\ +post\ +\" ]]; then
            : # properly quoted — OK
        elif [[ "$step" =~ ^/social\ +post\ +[^\"] ]]; then
            _AGENT_PLAN_WARNINGS="${_AGENT_PLAN_WARNINGS}\n  Step $num: /social post needs quoted text (first word may be parsed as platform)"
            warn_count=$(( warn_count + 1 ))
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
# Parent context is injected into GEORGE.md so the subtask knows
# what the overall task is and what has been completed so far.
_agent_run_subtask() {
    local task="$1"
    local workdir="${2:-.}"
    local depth="${3:-1}"
    local parent_task="${4:-}"

    if [ "$depth" -gt "$AGENT_MAX_DEPTH" ]; then
        ui_warn "Max planning depth ($AGENT_MAX_DEPTH) reached. Executing as single step."
        agent_inner_loop "$task" "$workdir"
        return $?
    fi

    # Inject parent context so subtask plan is aware of the bigger picture
    if [ -n "$parent_task" ]; then
        memory_update_section "Current Task" "SUBTASK of: $parent_task\nSubtask: $task" "$workdir"
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
            if _agent_run_subtask "$sub_desc" "$workdir" "$((depth + 1))" "$task"; then
                completed=$((completed + 1))
            fi
        else
            ui_progress "$step_num" "$total" "${step_text:0:30}"
            if agent_inner_loop "$step_text" "$workdir"; then
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

    local base_rules="Plan this task. Rules:
- THINK FIRST: Is this a simple question George can answer from his own knowledge (no web search, no tools, no external actions)? If so, output ONLY: 1. /ask <the user's question>. Done. No sandbox, no coding.
- If the user explicitly names a tool or action (e.g., 'search the web', 'post to discord'), route to that tool — do NOT use /ask.
- Use the MINIMUM steps needed. Most tasks need 1-3 steps. Maximum: $AGENT_PLAN_STEPS steps.
- NEVER pad plans. No filler steps (no READMEs, no backup, no status checks, no recall searches, no reviews).
- Every step must directly advance the user's stated goal.
- Each step = ONE action (one file, one command, one operation).
- Use your slash commands (e.g. /sandbox, /write, /build) in steps.
- If using /sandbox: create it FIRST with /sandbox new <name> <type>.
- For complex multi-file or design-heavy work, prefix a step with [SUBTASK] — describe WHAT the code must do (architecture, modules, behavior). The subtask gets its own recursive sub-plan. Use [SUBTASK] for the heavy lifting; keep your top-level plan lean.
- Code steps must produce REAL implementation — no Hello World, no stubs.
- NEVER invent URLs or repo names. Use /web search or /github search first.
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

        local LLM_SCENARIO=agent
        plan=$(llm_stream "$prompt" "$system_prompt" 512 "$LLM_BUDGET_AGENT")
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

# ── Dynamic Inner Loop Prompts ─────────────────────────────────
# Replaces the monolithic memory_build_system_prompt for inner loops.
# These prompts contain ZERO personality, vitals, or history.
# This drastically reduces prefill time — Ollama flushes the KV cache
# but does NOT reload the 4GB model from disk.

_build_router_prompt() {
    # Phase 1 Prompt: The Command Catalog Router
    # Category-grouped command list with few-shot routing examples.
    # The router's only job is classification: task → base command.
    # Specialist handles exact syntax. ~250 tokens.
    echo "You are George. Pick the best tool for this task from your command catalog."
    echo ""
    cat << 'ROUTER_CATALOG'
--- COMMAND CATALOG (use ONLY these) ---

KNOWLEDGE & REASONING:
  /ask         — Answer a question from your own knowledge (no tools)
  /recall      — Search your knowledge base (FTS5)
  /journal     — Write to your living memory

FILE & PROJECT:
  /write       — Write or overwrite a file
  /save        — Save content to a file
  /download    — Download a URL or copy a file
  /init        — Scaffold a new project
  /clone       — Clone a git repo
  /build       — Build project
  /test        — Run tests
  /fix         — Diagnose and fix errors
  /commit      — AI commit message + commit
  /push        — Push to GitHub

WEB & SEARCH:
  /web         — Search the web, fetch page content, or find image URLs
  /github      — Search GitHub repos
  /vision      — Analyze/describe an image (pass URL or file path directly)

COMMUNICATION:
  /social      — Post to Discord, Telegram, X, Mastodon, Bluesky (NOT email)
  /email       — Send or check actual email (gmail, protonmail, zoho)
  /phone       — Phone dashboard, SMS, calls

SANDBOX & CONTAINERS:
  /sandbox     — Create/build/test/run code sandboxes (NOT for running slash commands)
  /container   — Linux containers via proot-distro

SECURITY & CONFIG:
  /pgp         — Sign, verify, export PGP keys
  /secret      — Encrypted secrets vault
  /git         — Git setup, SSH keys
  /backup      — Backup and restore
  /vitals      — System dashboard

EXTENSION:
  /slash       — Create or run custom commands
  bash         — Standard Linux shell (fallback)

--- FEW-SHOT ROUTING EXAMPLES ---
Task: "what is a monad?"               → /ask
Task: "post hello to the lunkers channel" → /social
Task: "search the web for rust tutorials" → /web
Task: "send an email to john@test.com"  → /email
Task: "build a url shortener in rust"   → /sandbox
Task: "download https://example.com/f"  → /download
Task: "describe this image"              → /vision
Task: "find and describe images of X"    → /web (search first, then /vision later)
ROUTER_CATALOG
    echo ""
    echo "Output ONLY the tool name. For slash commands output the base command"
    echo "(e.g., '/web', '/sandbox', '/write', '/social', '/git', 'bash')."
    echo "ROUTING RULES:"
    echo "- CRITICAL: If the Action Log shows the current objective is already fulfilled (data gathered, question answered, command executed), you MUST output EXACTLY: SUCCESS: <brief summary>"
    echo "- CRITICAL: If the Action Log contains **Status:** EXECUTED SUCCESSFULLY for the current objective, the objective IS DONE — output SUCCESS: <brief summary>"
    echo "- To post to Discord/Telegram/X, route to /social (NOT /email)"
    echo "- Do NOT route to /sandbox to run other slash commands"
    echo "- /email is ONLY for actual email addresses"
    echo "If the user's request matches a specific tool above, USE THAT TOOL. Only fall back to '/ask' if no tool is relevant."
}

# ── Specialist: per-command API key status ─────────────────────
# Returns a compact line listing which API keys/secrets are
# configured for a given command.  Injected into the specialist
# prompt so the model knows what services are available and can
# avoid generating commands that will fail due to missing keys.
#
# Only emits output for commands that actually need keys.
# Format:  KEYS: SERPER_API_KEY ✓, PERPLEXITY_API_KEY ✗
_specialist_key_status() {
    local cmd="$1"  # base command without /
    declare -f api_get_key &>/dev/null || return 0

    local -a keys=()
    case "$cmd" in
        web)      keys=(SERPER_API_KEY PERPLEXITY_API_KEY) ;;
        social)   keys=(DISCORD_BOT_TOKEN DISCORD_WEBHOOK_URL TELEGRAM_BOT_TOKEN X_BEARER_TOKEN MASTODON_ACCESS_TOKEN BLUESKY_APP_PASSWORD) ;;
        email)    keys=(EMAIL_PROVIDER) ;;
        github)   keys=(GITHUB_TOKEN) ;;
        wallet)   keys=(btc_address ada_address sol_address) ;;
        pgp)      ;; # uses gpg keyring, not API keys
        *)        return 0 ;;  # no keys needed
    esac

    [ ${#keys[@]} -eq 0 ] && return 0

    local parts=""
    local k
    for k in "${keys[@]}"; do
        if api_get_key "$k" &>/dev/null; then
            parts="${parts:+$parts, }$k ✓"
        else
            # wallet keys live in the secrets vault, not api keys
            if [[ "$cmd" == "wallet" ]] && declare -f secrets_get &>/dev/null; then
                if secrets_get "$k" &>/dev/null 2>&1; then
                    parts="${parts:+$parts, }$k ✓"
                    continue
                fi
            fi
            parts="${parts:+$parts, }$k ✗"
        fi
    done

    [ -n "$parts" ] && echo "KEYS: $parts"
}

_build_specialist_prompt() {
    local cmd_name="$1"
    local workdir="$2"
    local micro_objective="$3"  # Optional: used to rerank docs by objective keywords
    # Phase 2 Prompt: The Action Specialist
    # Injects deep-dive docs for ONE specific command.
    #
    # Slash commands: output on their own line starting with /
    #   (commands_dispatch handles execution)
    # Bash commands: output inside a ```bash block
    #   (eval handles execution)

    if [ "$cmd_name" != "bash" ]; then
        echo "You are George. Execute this task by outputting exactly ONE slash command."
        echo "Output the FULL command on its own line starting with / — do NOT wrap in a code block."
        echo "Do NOT use /sandbox to run slash commands. Slash commands execute directly."
        echo "Do NOT quote arguments with \" or '. Slash commands parse by whitespace, not shell quoting."
        echo "Output only ONE command per line — never chain multiple /commands together."
        echo ""

        # Docs injection is SKIPPED for the specialist. The syntax card
        # below provides all needed syntax in ~10 lines per command.
        # Previously, GEORGE_REFERENCE.md (40 lines) + SLASH_COMMANDS.md
        # table rows + recall FTS5 results were all injected, ballooning
        # input to 1500-1800 tokens for only 3-17 output tokens. The 4B
        # model doesn't need encyclopedic docs — it needs a crisp syntax
        # card and the objective.
        local base_cmd="${cmd_name#/}"

        # ── Command-specific syntax cards ─────────────────────
        # Guaranteed inline reference per command. Prevents the
        # specialist from hallucinating syntax when doc lookups
        # return wrong or empty sections.
        echo ""
        echo "SYNTAX CARD:"
        case "$base_cmd" in
            social)
                echo "- /social post discord <channel_name> <text>"
                echo "  ALWAYS include channel name (e.g. lunkers, general). Never omit it."
                echo "- /social post telegram <text>"
                echo "- /social post x <text>"
                echo "- /social post mastodon <text>"
                echo "- /social discord dm <user> <text>"
                echo "- /social discord read <channel>"
                echo "- @mentions: Write @DisplayName naturally. Auto-resolved to <@user_id>."
                echo "- Do NOT use #channel in text. Channel goes BEFORE the text."
                echo "- Do NOT wrap any arguments in quotes."
                echo "Example: /social post discord lunkers @Pompler Just landed a 5lb bass at Cedar Lake"
                ;;
            init)
                echo "- /init <name> <type>"
                echo "  name MUST have no spaces (use underscores)."
                echo "  Types: rust, python, rl, data, automation, notebook, shell"
                echo "- Creates project dir, GEORGE.md, starter code, git init."
                echo "- After /init, use /write to add files, /build to build."
                echo "Example: /init task-manager rust"
                ;;
            write)
                echo "- /write <filepath> <content>"
                echo "  filepath relative to current project dir."
                echo "  Content is everything after filepath (no quoting)."
                echo "  Creates parent directories automatically."
                echo "  For multi-line, use \\n for newlines."
                echo "Example: /write src/main.rs fn main() { println!(\"Hello\"); }"
                ;;
            save)
                echo "- /save <filepath> <content>"
                echo "  First token = filepath, rest = content."
                echo "  Reads stdin if no content provided."
                echo "Example: /save notes.md Meeting moved to Thursday at 3pm"
                ;;
            web)
                echo "- /web search <query>         — Search the web (returns URLs + snippets)"
                echo "- /web fetch <url>            — Read a webpage's content"
                echo "- /web images <query>         — Find image URLs via Serper API"
                echo "- /web scrape-images <url>    — Extract image URLs from a webpage (no API key)"
                echo "  RULES:"
                echo "  - /web search takes a QUERY. /web fetch takes a URL. Never swap them."
                echo "  - To DESCRIBE an image: use /vision <image_url> (NOT /web fetch on an image URL)."
                echo "  - /vision accepts image URLs directly — no need to /download first."
                echo "  IMAGE WORKFLOW: /web search <topic> → pick image URL → /vision <image_url> [prompt]"
                echo "  ALT IMAGE WORKFLOW: /web scrape-images <page_url> → /vision <image_url> [prompt]"
                echo "Example: /web search rust async tutorial 2025"
                ;;
            download)
                echo "- /download <url_or_path> [destination]"
                echo "  Downloads a file. Destination is optional."
                echo "Example: /download https://example.com/data.csv ./data/"
                ;;
            sandbox)
                echo "- /sandbox new <name> [type]  — Create (types: rust/python/shell)"
                echo "- /sandbox build <name>       — Build project in sandbox"
                echo "- /sandbox test <name>        — Run tests"
                echo "- /sandbox run <name>         — Run project"
                echo "- /sandbox cd <name>          — Change into sandbox dir"
                echo "- /sandbox rm <name>          — Remove sandbox"
                echo "- /sandbox clone <url> [name] — Clone repo into sandbox"
                echo "- Do NOT use /sandbox to run other slash commands."
                echo "Example: /sandbox new url-shortener rust"
                ;;
            build)
                echo "- /build [release]"
                echo "  Auto-detects Cargo/pyproject/Makefile."
                echo "  Reads GEORGE.md ## Build section for instructions."
                echo "Example: /build release"
                ;;
            test)
                echo "- /test [specific_test]"
                echo "  Auto-detects Cargo/pytest/npm/make."
                echo "  Reads GEORGE.md ## Test section for instructions."
                echo "Example: /test"
                ;;
            fix)
                echo "- /fix [file_or_description]"
                echo "  Auto-diagnoses and fixes errors."
                echo "  Optional: specify file or error description."
                echo "Example: /fix src/main.rs"
                ;;
            commit)
                echo "- /commit [files...]"
                echo "  AI-generates commit message from staged changes."
                echo "  Optional: specific files to stage."
                echo "Example: /commit"
                ;;
            push)
                echo "- /push [branch]"
                echo "  Pushes to remote. Defaults to current branch."
                echo "Example: /push"
                ;;
            clone)
                echo "- /clone <repo_url_or_owner/repo> [local_name]"
                echo "  Supports full URL or owner/repo shorthand."
                echo "  Optional local directory name."
                echo "Example: /clone tokio-rs/tokio"
                ;;
            git)
                echo "- /git setup      — Configure git user/email"
                echo "- /git status     — Show repo status"
                echo "- /git ssh-keygen — Generate SSH key for GitHub"
                echo "Example: /git setup"
                ;;
            github)
                echo "- /github search <query>"
                echo "  Searches GitHub repositories."
                echo "Example: /github search rust web framework"
                ;;
            email)
                echo "- /email send <provider> <recipient> subject=<subject> body=<body>"
                echo "  provider: gmail, protonmail, zoho"
                echo "  Recipient email goes right after provider (no to= needed)."
                echo "  Use subject= and body= for subject and body (captures multi-word text)."
                echo "  Also accepts: to= s= b= as aliases for to= subject= body="
                echo "  Example: /email send gmail user@example.com subject=Hello there body=How are you?"
                echo "- /email inbox <provider> [count]"
                echo "- /email status"
                echo "  For actual email only — NOT for social platforms."
                echo "Example: /email send gmail user@example.com subject=Hello there body=How are you?"
                ;;
            journal)
                echo "- /journal write <entry_text>"
                echo "  Types: reflection, learning, struggle, beauty, feeling, encounter."
                echo "  Appends timestamped entry to journal.md."
                echo "Example: /journal Because in every Animal that walks upright, the Deficiency of the Fluids that fill the Muscles appears first in the highest Part: The Face first grows lank and wrinkled; then the Neck; then the Breast and Arms; the lower Parts continuing to the last as plump as ever: So that covering all above with a Basket, and regarding2 only what is below the Girdle, it is impossible of two Women to know an old from a young one. And as in the dark all Cats are grey, the Pleasure of corporal Enjoyment with an old Woman is at least equal, and frequently superior, every Knack being by Practice capable of Improvement."
                ;;
            recall)
                echo "- /recall <query>"
                echo "  BM25-ranked FTS5 search of knowledge base."
                echo "  Returns source, section, and snippet."
                echo "Example: /recall trout stocking schedule"
                ;;
            pgp)
                echo "- /pgp sign <message>   — Cleartext-sign a message"
                echo "- /pgp signpost         — Sign + post to Discord"
                echo "- /pgp export           — Export public key"
                echo "Example: /pgp sign I attest this message is authentic"
                ;;
            phone)
                echo "- /phone"
                echo "  Shows phone dashboard (battery, signal, location, SMS)."
                echo "  No arguments needed."
                echo "Example: /phone"
                ;;
            secret)
                echo "- /secret set <name> <value>"
                echo "- /secret get <name>"
                echo "  AES-256-CBC encrypted vault."
                echo "Example: /secret set SERPER_API_KEY abc123xyz"
                ;;
            vitals)
                echo "- /vitals"
                echo "  System dashboard: disk, RAM, battery, network."
                echo "  No arguments needed."
                echo "Example: /vitals"
                ;;
            backup)
                echo "- /backup local   — Timestamped local backup"
                echo "- /backup restore — Restore from backup"
                echo "- /backup github  — Push backup to GitHub"
                echo "Example: /backup local"
                ;;
            vision)
                echo "- /vision <image_path_or_url> [prompt]"
                echo "  Analyzes an image using AI vision. Supports jpg/png/gif/webp/bmp."
                echo "  Accepts direct image URLs — auto-downloads and analyzes (no /download needed)."
                echo "  Optional prompt to guide the analysis."
                echo "  REQUIRES a vision-capable model. If current model lacks vision:"
                echo "    Switch first: /models single minist-inst"
                echo "    Then: /vision <url_or_path> [prompt]"
                echo "  Vision-capable models: minist-inst"
                echo "Example: /vision https://example.com/photo.jpg describe this scene"
                echo "Example: /vision ./downloaded_image.jpg What text is visible?"
                ;;
            container)
                echo "- /container create <distro>  — Install (ubuntu/alpine/debian/fedora/kali)"
                echo "- /container enter <distro>   — Interactive shell"
                echo "- /container exec <distro> <cmd> — Run command inside"
                echo "- /container rm <distro>      — Remove container"
                echo "Example: /container create ubuntu"
                ;;
            wallet)
                echo "- /wallet status   — Show configured wallets"
                echo "- /wallet balances — Show live balances"
                echo "- /wallet check    — Health check"
                echo "Example: /wallet balances"
                ;;
            slash)
                echo "- /slash create <name> <description>"
                echo "- /slash run <name> [args]"
                echo "- /slash list"
                echo "Example: /slash create morning-brief Show me weather, calendar, and unread messages"
                ;;
            ask)
                echo "- /ask <question>"
                echo "  Quick answer from LLM — no tools, no planning."
                echo "Example: /ask What is a monad in functional programming?"
                ;;
            *)
                echo "- /$base_cmd (no specific syntax card — check docs above)"
                ;;
        esac

        # Inject per-command API key availability so the specialist
        # knows which services are configured and can avoid commands
        # that will fail due to missing keys.
        local _key_status
        _key_status=$(_specialist_key_status "$base_cmd" 2>/dev/null)
        if [ -n "$_key_status" ]; then
            echo ""
            echo "$_key_status"
        fi

        # Previous search results are already visible in the micro_memory
        # action log via MICRO OBJECTIVE + ACTION LOG injection in the
        # specialist_prompt (user message). No need to inject them again
        # into the system prompt — that was doubling the token count.
    else
        echo "You are George. Output exactly ONE command inside a \`\`\`bash block."
        echo "Use standard bash. Do not use interactive commands (like nano or vim)."
        echo "Do not output slash commands — use only shell builtins and system utilities."
    fi
}

# ── Execute a single micro-objective (The Tactician) ──────────
# Replaces the legacy agent_execute_step with a two-phase
# route→execute inner loop governed by the Constrained Escalation Matrix.
#
# Phase 1 (Router):  Fast tool selection — zero personality, just a catalog.
# Phase 2 (Specialist): Deep-dive execution — one command's docs injected.
#
# Failure Escalation Matrix (5 levels + terminal):
#   L1: Naive retry (LLM bypassed — programmatic re-exec after sleep)
#   L2: Forced knowledge retrieval (/recall on base command)
#   L3-L4: Syntax permutation with identicality lockout
#   L5: Forced web fallback (search stderr + command name)
#   Terminal: Human operator intervention (read -r from /dev/tty)
agent_inner_loop() {
    local micro_objective="$1"
    local workdir="${2:-.}"
    local george_dir="$workdir/.george"
    local micro_file="$george_dir/micro_memory.md"
    local fail_file="$george_dir/failures_log.md"

    mkdir -p "$george_dir"

    # STRICT OVERWRITE: Wipe micro memory clean for the new objective.
    # This is not appended — it is destroyed and recreated on every
    # handoff from the Macro loop.
    echo "# Micro Objective: $micro_objective" > "$micro_file"

    # ── PRIMARY OBJECTIVE INJECTION ────────────────────────────
    # Inject the overarching task goal so the inner loop's router and
    # specialist never lose sight of the bigger picture. Without this,
    # the LLM optimizes locally (e.g. fetching every URL) instead of
    # progressing toward the user's actual request.
    if [ -f "$george_dir/macro_memory.md" ]; then
        local _primary_obj
        _primary_obj=$(awk '/^## Primary Objective/{getline; if(NF) print; exit}' "$george_dir/macro_memory.md" 2>/dev/null)
        if [ -n "$_primary_obj" ] && [ "$_primary_obj" != "$micro_objective" ]; then
            echo "## Primary Objective (overall task — stay focused)" >> "$micro_file"
            echo "$_primary_obj" >> "$micro_file"
            echo "" >> "$micro_file"
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: primary objective -> micro_memory"
        fi
    fi

    echo "## Action Log" >> "$micro_file"

    local inner_attempts=0
    local max_inner_loops="$AGENT_INNER_LOOPS"
    local last_failed_cmd=""
    local _last_success_cmd=""      # Track last successful command for macro_memory
    local _last_success_snippet=""  # First 200 chars of last successful output
    local _cancel_file="${TMPDIR:-/tmp}/.lodge-cancel-$$"

    while [ "$inner_attempts" -lt "$max_inner_loops" ]; do
        # ── CANCELLATION CHECK: Break immediately on Ctrl+C ─────
        # Without this, the loop continues making LLM calls after
        # the user presses Ctrl+C, creating a cancel→think→cancel loop.
        if [ "${_LODGE_CANCELLED:-0}" -eq 1 ] || [ -f "$_cancel_file" ]; then
            return 1
        fi

        local inner_context=$(cat "$micro_file")

        # ── PHASE 1: Fast Tool Routing ────────────────────────
        local router_sys=$(_build_router_prompt)
        local route_prompt="Review the Action Log. If the objective is ALREADY FULFILLED by the actions taken (data gathered, command executed, content created), output SUCCESS: <brief summary>. Otherwise, output the SINGLE tool name needed for the next action."

        # ── RESEARCH SUFFICIENCY GUIDANCE ──────────────────────
        # For objectives involving web research, tell the router to
        # output SUCCESS once there's enough gathered data instead
        # of exhaustively scraping every URL from search results.
        local _obj_lower_rt
        _obj_lower_rt=$(echo "$micro_objective" | tr '[:upper:]' '[:lower:]')
        if [[ "$_obj_lower_rt" == *search* ]] || [[ "$_obj_lower_rt" == *web* ]] || [[ "$_obj_lower_rt" == *fetch* ]] || [[ "$_obj_lower_rt" == *find* ]] || [[ "$_obj_lower_rt" == *look*up* ]]; then
            route_prompt="${route_prompt}\nWEB RESEARCH RULE: You have ENOUGH data after 1 search + 1-2 page fetches. Do NOT fetch every URL. Once you have substantive content, output SUCCESS with a summary of findings."
        fi

        route_prompt="${route_prompt}\n\n$inner_context"

        # llm_generate is used here for maximum speed — no streaming,
        # no personality, just returns the raw string.
        local selected_tool
        local LLM_SCENARIO=router
        selected_tool=$(llm_generate "$route_prompt" "$router_sys" "${LLM_ROUTER_TOKENS:-50}" "$LLM_BUDGET_ROUTER")

        # Cancel check after router LLM call — curl may have been killed
        if [ "${_LODGE_CANCELLED:-0}" -eq 1 ] || [ -f "$_cancel_file" ]; then
            return 1
        fi

        if [[ "$selected_tool" == *"SUCCESS:"* ]]; then
            local summary
            summary=$(echo "$selected_tool" | sed -n 's/.*SUCCESS:[[:space:]]*//p' | head -1)
            [ -z "$summary" ] && summary="Objective fulfilled"
            local _step_ts
            _step_ts=$(date '+%Y-%m-%d %H:%M:%S')

            # Write completion verdict to micro_memory BEFORE returning.
            # The evaluator reads micro_memory after the inner loop returns.
            # Without this, micro_memory has the raw Action/Status/Output but
            # no explicit completion marker — which can cause a conservative
            # evaluator (especially on a 4B model) to return INCOMPLETE when
            # the output is empty or ANSI-garbled.
            echo -e "\n**Milestone Result:** COMPLETE — $summary" >> "$micro_file"

            if [ -n "$_last_success_cmd" ]; then
                echo "- Step [$_step_ts]: $micro_objective -> $summary | ran: $_last_success_cmd (exit 0)" >> "$george_dir/macro_memory.md"
            else
                echo "- Step [$_step_ts]: $micro_objective -> $summary" >> "$george_dir/macro_memory.md"
            fi
            return 0
        fi

        # ── WEB SUFFICIENCY ENFORCEMENT ───────────────────────
        # The sufficiency gate (below) writes SUFFICIENCY REACHED to
        # micro_memory after N successful web actions. If the router
        # STILL doesn't output SUCCESS on the next iteration, we
        # programmatically force completion instead of wasting more
        # escalation rounds. This catches models (e.g., Ministral)
        # that ignore prompt-based stop signals.
        if grep -q "SUFFICIENCY REACHED" "$micro_file" 2>/dev/null; then
            local _suff_summary="Web research data gathered"
            # Extract the last web search result for a meaningful summary
            local _last_web
            _last_web=$(grep -oP '(?<=Web search.*: ).*' "$micro_file" 2>/dev/null | tail -1)
            [ -n "$_last_web" ] && _suff_summary="${_last_web:0:120}"
            local _step_ts
            _step_ts=$(date '+%Y-%m-%d %H:%M:%S')
            echo -e "\n**Milestone Result:** COMPLETE — $_suff_summary" >> "$micro_file"
            echo "- Step [$_step_ts]: $micro_objective -> $_suff_summary" >> "$george_dir/macro_memory.md"
            return 0
        fi

        # ── PHASE 2: Specialist Execution ─────────────────────
        # sed -e 's/^[[:space:]]*//' : Strips leading whitespace.
        # sed -e 's/[[:space:]]*$//' : Strips trailing whitespace.
        selected_tool=$(echo "$selected_tool" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        # Extract just the base command name (first word of FIRST line, strip leading /)
        # Router sometimes outputs "/ask" or "/web search" or noise.
        # CRITICAL: head -1 ensures multi-line router output (the router
        # sometimes regurgitates the entire command) only yields the first
        # line. Without this, awk emits one word per line and the tool
        # name becomes a multi-line string that fails file existence checks.
        selected_tool=$(echo "$selected_tool" | head -1 | awk '{print $1}' | sed 's|^/||; s|^/||')

        # ── TOOL VALIDATION: Reject hallucinated commands ─────
        # If the router outputs a tool name that doesn't exist in the
        # command registry or commands directory, fall back to /ask.
        # This prevents the inner loop from wasting escalation rounds
        # on imaginary commands like "/execute" or "/research".
        local _tool_valid=0
        if [ "$selected_tool" = "bash" ]; then
            _tool_valid=1
        elif declare -p CMD_REGISTRY &>/dev/null && [[ -n "${CMD_REGISTRY[$selected_tool]+x}" ]]; then
            _tool_valid=1
        elif [ -f "${LODGE_COMMANDS_DIR:-$LODGE_DIR/commands}/${selected_tool}.sh" ]; then
            _tool_valid=1
        fi
        if [ "$_tool_valid" -eq 0 ]; then
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Router hallucinated '/$selected_tool' — falling back to /ask"
            selected_tool="ask"
        fi

        # ── SANDBOX INTERLOCK: Programmatic gate ──────────────
        # The 4B model obsessively routes through /sandbox even for
        # non-code tasks (social posts, web searches, etc.).
        # Programmatically reject /sandbox unless the micro objective
        # explicitly involves code, building, or project creation.
        if [ "$selected_tool" = "sandbox" ]; then
            local _obj_lower
            _obj_lower=$(echo "$micro_objective" | tr '[:upper:]' '[:lower:]')
            if ! [[ "$_obj_lower" =~ (build|compile|code|project|scaffold|init|clone|test|debug|deploy|create.*app|create.*project|write.*program|develop) ]]; then
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Sandbox rejected for non-code objective — extracting real command"
                # Try to extract the real slash command from the micro objective
                local _real_cmd
                _real_cmd=$(echo "$micro_objective" | grep -oP '/[a-z]+' | head -1 | sed 's|^/||')
                if [ -n "$_real_cmd" ] && { declare -p CMD_REGISTRY &>/dev/null && [[ -n "${CMD_REGISTRY[$_real_cmd]+x}" ]]; }; then
                    selected_tool="$_real_cmd"
                else
                    # Fallback: scan objective for common command keywords
                    case "$_obj_lower" in
                        *social*|*discord*|*telegram*|*post*|*tweet*) selected_tool="social" ;;
                        *search*|*web*|*fetch*|*url*)                selected_tool="web" ;;
                        *write*|*save*|*file*)                      selected_tool="write" ;;
                        *email*|*send*mail*)                        selected_tool="email" ;;
                        *journal*|*log*|*note*)                     selected_tool="journal" ;;
                        *recall*|*remember*|*knowledge*)            selected_tool="recall" ;;
                        *)                                          selected_tool="ask" ;;
                    esac
                fi
            fi
        fi

        # Re-prefix for specialist lookup
        [ "$selected_tool" != "bash" ] && selected_tool="/$selected_tool"

        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Phase 2 specialist: loading docs for $selected_tool"

        local specialist_sys=$(_build_specialist_prompt "$selected_tool" "$workdir" "$micro_objective")
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: specialist prompt <- syntax card for $selected_tool"

        # Inject micro_memory (action log) so the specialist sees
        # prior outputs, created files, and error history. Without this,
        # multi-step objectives fail because the specialist can't adapt.
        local specialist_prompt="MICRO OBJECTIVE: $micro_objective\n\nACTION LOG:\n$inner_context\n\nWrite the exact command to execute next."
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: specialist <- micro_memory action log ($(echo "$inner_context" | wc -l) lines)"

        # Use llm_generate (non-streaming) for the specialist. The output
        # is a single command line that will be displayed by "Running: ..."
        # below. Streaming it first wastes time showing the same text twice
        # and confuses the user with redundant output.
        local action_plan
        local LLM_SCENARIO=agent
        action_plan=$(llm_generate "$specialist_prompt" "$specialist_sys" "${LLM_AGENT_TOKENS:-512}" "$LLM_BUDGET_AGENT")

        # Cancel check after specialist LLM call
        if [ "${_LODGE_CANCELLED:-0}" -eq 1 ] || [ -f "$_cancel_file" ]; then
            return 1
        fi

        # Extract command based on routing: slash commands vs bash.
        # Slash commands: extracted as lines starting with /
        # Bash commands: extracted from ```bash blocks
        local cmd=""
        local cmd_is_slash=0
        if [ "$selected_tool" != "bash" ]; then
            # Extract slash command line (first /command line outside code blocks)
            cmd=$(echo "$action_plan" | awk '
                /^```/ { in_block = !in_block; next }
                in_block { next }
                /^\/[a-z]/ { print; exit }
            ')
            if [ -n "$cmd" ]; then
                cmd_is_slash=1
            else
                # Fallback: LLM may have wrapped it in a bash block anyway
                cmd=$(echo "$action_plan" | awk '/```bash/{flag=1; next} /```/{flag=0} flag')
            fi
        else
            # awk: /```bash/ sets flag, /```/ clears flag, flag prints lines between.
            cmd=$(echo "$action_plan" | awk '/```bash/{flag=1; next} /```/{flag=0} flag')
        fi

        # ── MULTI-COMMAND SPLITTER ────────────────────────────
        # The LLM sometimes concatenates multiple slash commands on one line:
        #   /sandbox new x  /write file.md "text"  /social post discord "msg"
        # Extract only the FIRST slash command and discard the rest.
        if [ "$cmd_is_slash" -eq 1 ] && [[ "$cmd" =~ ^(/[a-z]+[[:space:]]) ]]; then
            # Check for a second embedded slash command (space-/cmd pattern)
            local _first_cmd
            _first_cmd=$(echo "$cmd" | sed 's|  */|\n/|g' | head -1)
            if [ "$_first_cmd" != "$cmd" ]; then
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Split multi-command: extracted '${_first_cmd:0:60}...'"
                cmd="$_first_cmd"
            fi
        fi

        # ── QUOTE NORMALIZATION ────────────────────────────────
        # The LLM wraps slash command arguments in shell-style quotes:
        #   /init python "pid loop tuning assistant"
        #   /social post discord "#lunkers" "hello world"
        # Slash commands don't use shell parsing — quotes are literal.
        # Strip matching outer quotes from the args portion.
        if [ "$cmd_is_slash" -eq 1 ] && [[ "$cmd" == *'"'* ]]; then
            cmd=$(echo "$cmd" | sed 's/"//g')
        fi
        if [ "$cmd_is_slash" -eq 1 ] && [[ "$cmd" == *"'"* ]]; then
            cmd=$(echo "$cmd" | sed "s/'//g")
        fi

        # ── PROGRAMMATIC INTERLOCK: Identicality Lockout ──────
        # Levels 3-4: Prevents the LLM from re-running the exact same
        # broken command. If identical, reject and force regeneration.
        if [ "$inner_attempts" -ge 2 ] && [ -n "$cmd" ] && [ "$cmd" == "$last_failed_cmd" ]; then
            ui_warn "Interlock Triggered: Identical failed command. Forcing regeneration."
            echo "**System Interlock:** Command \`$cmd\` rejected (identical to previous failure)." >> "$micro_file"
            inner_attempts=$((inner_attempts + 1))
            continue
        fi

        if [ -n "$cmd" ]; then
            ui_step "Running: $cmd"

            # Execute based on command type:
            #   Slash commands → commands_dispatch (proper command registry)
            #   Bash commands  → eval (direct shell execution)
            # head -c 2000 : Reads only the first 2000 bytes to prevent
            # context window overflow from massive stack traces.
            local output
            local exit_code
            if [ "$cmd_is_slash" -eq 1 ] && declare -f commands_dispatch &>/dev/null; then
                output=$(commands_dispatch "$cmd" "$workdir" 2>&1 | head -c 2000)
                exit_code=${PIPESTATUS[0]}
            else
                output=$(eval "$cmd" 2>&1 | head -c 2000)
                exit_code=${PIPESTATUS[0]}
            fi

            if [ $exit_code -eq 0 ]; then
                _last_success_cmd="$cmd"
                _last_success_snippet="${output:0:200}"
                echo -e "\n**Action:** \`$cmd\`\n**Status:** EXECUTED SUCCESSFULLY (exit 0)\n**Output:**\n\`\`\`\n$output\n\`\`\`" >> "$micro_file"

                # ── WEB SUFFICIENCY GATE ───────────────────────
                # Prevent George from exhaustively scraping every
                # URL returned by a search. After N successful web
                # actions, inject a strong "stop fetching" signal
                # into micro_memory so the router outputs SUCCESS
                # on the next iteration instead of routing to /web.
                if [[ "$cmd" == /web* ]]; then
                    local _web_ok_count
                    _web_ok_count=$(grep -c '^\*\*Action:\*\* `/web' "$micro_file" 2>/dev/null || echo 0)
                    if [ "$_web_ok_count" -ge "${AGENT_WEB_SUFFICIENCY:-3}" ]; then
                        echo -e "\n**SUFFICIENCY REACHED:** $_web_ok_count web actions completed. You have gathered enough data to fulfill the objective. Do NOT fetch more URLs. Summarize your findings and output SUCCESS: <summary>." >> "$micro_file"
                        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Web sufficiency gate: $_web_ok_count actions reached threshold"
                    fi
                fi

                inner_attempts=$((inner_attempts + 1))
                continue
            fi

            # ═══════════════════════════════════════════════════
            # FAILURE ESCALATION MATRIX
            # ═══════════════════════════════════════════════════
            last_failed_cmd="$cmd"
            echo -e "\nFAILED COMMAND: \`$cmd\`\nEXIT CODE: $exit_code\nOUTPUT:\n$output\n---" >> "$fail_file"

            # ── Level 1: Naive Retry (Programmatic Bypass) ────
            # LLM is completely bypassed. Re-run the exact command
            # after a brief sleep. Catches transient network errors,
            # file locks, or race conditions without wasting tokens.
            if [ "$inner_attempts" -eq 0 ]; then
                ui_warn "Escalation L1: Naive retry..."
                sleep 1
                if [ "$cmd_is_slash" -eq 1 ] && declare -f commands_dispatch &>/dev/null; then
                    output=$(commands_dispatch "$cmd" "$workdir" 2>&1 | head -c 2000)
                else
                    output=$(eval "$cmd" 2>&1 | head -c 2000)
                fi
                if [ ${PIPESTATUS[0]} -eq 0 ]; then
                    echo -e "\n**Action:** \`$cmd\` (Retry)\n**Status:** EXECUTED SUCCESSFULLY (exit 0)\n**Output:**\n\`\`\`\n$output\n\`\`\`" >> "$micro_file"
                    inner_attempts=$((inner_attempts + 1))
                    continue
                fi
                ui_warn "L1 failed. Escalating..."
            fi

            # ── Level 2: Forced Knowledge Retrieval ───────────
            # Parse the base command from the failed string and
            # programmatically execute /recall <base_command>.
            # Inject the recall stdout into micro_memory so the
            # LLM reads its own documentation BEFORE retrying.
            if [ "$inner_attempts" -le 1 ] && declare -f recall_search_context &>/dev/null; then
                local base_cmd
                base_cmd=$(echo "$cmd" | awk '{print $1}')
                ui_warn "Escalation L2: Forced recall for '$base_cmd'..."
                local recall_result
                recall_result=$(recall_search_context "$base_cmd" 3 2>/dev/null)
                if [ -n "$recall_result" ]; then
                    echo -e "\n**Recall ($base_cmd):**\n\`\`\`\n$recall_result\n\`\`\`" >> "$micro_file"
                    [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: L2 recall for '$base_cmd' -> micro_memory"
                fi
            fi

            # ── Levels 3-4: Syntax Permutation + History Recall ─
            # Identicality lockout (top of loop) prevents identical reruns.
            # Additionally, read the failure log for past RECOVERY entries.
            # If the operator has previously solved a similar failure,
            # inject those instructions so the LLM can self-correct.
            if [ "$inner_attempts" -ge 2 ] && [ -f "$fail_file" ]; then
                local past_recoveries
                past_recoveries=$(grep -B1 -A2 "^RECOVERY:\|^OPERATOR GUIDANCE:" "$fail_file" 2>/dev/null | tail -20)
                if [ -n "$past_recoveries" ]; then
                    ui_warn "Escalation L3: Injecting past recovery instructions..."
                    echo -e "\n**Past Recovery Instructions (from failure log):**\n\`\`\`\n$past_recoveries\n\`\`\`" >> "$micro_file"
                    [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: L3 past recoveries -> micro_memory"
                fi
            fi

            # ── Level 5: Forced Web Fallback ──────────────────
            # LLM is bypassed again. Extract the last 5 lines of stderr
            # and automatically search the web for the error.
            if [ "$inner_attempts" -ge 4 ] && declare -f web_search &>/dev/null; then
                local stderr_tail
                stderr_tail=$(echo "$output" | tail -n 5)
                local base_cmd
                base_cmd=$(echo "$cmd" | awk '{print $1}')
                ui_warn "Escalation L5: Web search for error..."
                local web_result
                web_result=$(web_search "error: $stderr_tail $base_cmd" 3 2>/dev/null)
                if [ -n "$web_result" ]; then
                    echo -e "\n**Web Search Results:**\n\`\`\`\n${web_result:0:1500}\n\`\`\`" >> "$micro_file"
                    [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: L5 web error search -> micro_memory"
                fi
            fi

            # Append failure to micro memory so the LLM sees it on the next loop
            echo -e "\n**Action:** \`$cmd\`\n**Status:** FAILED (exit $exit_code)\n**Error:**\n\`\`\`\n$output\n\`\`\`" >> "$micro_file"
        fi

        inner_attempts=$((inner_attempts + 1))
    done

    # ── Terminal Escalation: Human Operator Intervention ───────
    # All 5 levels exhausted. Drop to a safe holding state.
    # Present failures_log.md to the operator for guidance.
    # Skip entirely if cancelled — user wants to return to REPL, not be
    # prompted for guidance on an operation they already abandoned.
    if [ "${_LODGE_CANCELLED:-0}" -eq 1 ] || [ -f "$_cancel_file" ]; then
        local _step_ts
        _step_ts=$(date '+%Y-%m-%d %H:%M:%S')
        echo "- Step [$_step_ts]: $micro_objective -> CANCELLED" >> "$george_dir/macro_memory.md"
        return 1
    fi
    ui_err "Inner loop exhausted all escalation levels."
    if [ -f "$fail_file" ]; then
        echo ""
        ui_warn "Failures log:"
        tail -30 "$fail_file"
        echo ""
    fi
    printf "  %bGeorge needs help. Provide a command, explanation, or 'abort': %b" "$C_BOLD" "$C_RESET"
    local guidance
    read -r guidance < /dev/tty

    # ── ABORT PROPAGATION ─────────────────────────────────────
    # When the operator types 'abort', propagate cancellation to the
    # macro loop so the entire task stops — not just this milestone.
    # Previously, abort only terminated the inner loop and the macro
    # loop would immediately generate the same failed milestone again.
    if [ "$guidance" = "abort" ]; then
        _LODGE_CANCELLED=1
        touch "$_cancel_file" 2>/dev/null
        local _step_ts
        _step_ts=$(date '+%Y-%m-%d %H:%M:%S')
        echo "- Step [$_step_ts]: $micro_objective -> ABORTED by operator" >> "$george_dir/macro_memory.md"
        return 1
    fi

    if [ -n "$guidance" ] && [ "$guidance" != "abort" ]; then
        echo -e "\n**Operator Guidance:** $guidance" >> "$micro_file"

        # ── Catalog-Aware Guided Retry ────────────────────────
        # Combine operator input with the full command catalog so
        # the LLM maps natural language ("use /web search") to a
        # real command instead of hallucinating.
        # Inject micro_memory (action log) so the specialist sees
        # prior inputs, created files, and error history. Without this,
        # guided retries fail because the LLM can't see past attempts.
        local catalog=""
        if declare -f commands_catalog &>/dev/null; then
            catalog=$(commands_catalog)
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: guided retry <- command catalog"
        fi

        local guided_prompt="MICRO OBJECTIVE: $micro_objective

OPERATOR GUIDANCE: $guidance

AVAILABLE COMMANDS:
$catalog

The operator provided guidance after previous failures. Using the operator's instructions and the command catalog above, write the exact command to execute.
The command MUST be one listed in AVAILABLE COMMANDS or a valid bash command.
Output a slash command line starting with / OR a bash code block."

        local guided_sys=$(_build_specialist_prompt "" "$workdir" "$micro_objective")
        local final_plan
        local LLM_SCENARIO=agent
        final_plan=$(llm_stream "$guided_prompt" "$guided_sys" "${LLM_AGENT_TOKENS:-512}" "$LLM_BUDGET_AGENT")

        # Extract slash command or bash command (same logic as main loop)
        local final_cmd=""
        local final_is_slash=0
        final_cmd=$(echo "$final_plan" | awk '
            /^```/ { in_block = !in_block; next }
            in_block { next }
            /^\/[a-z]/ { print; exit }
        ')
        if [ -n "$final_cmd" ]; then
            final_is_slash=1
        else
            final_cmd=$(echo "$final_plan" | awk '/```bash/{flag=1; next} /```/{flag=0} flag')
        fi

        if [ -n "$final_cmd" ]; then
            ui_step "Running (guided): $final_cmd"
            local final_output
            local final_exit
            if [ "$final_is_slash" -eq 1 ] && declare -f commands_dispatch &>/dev/null; then
                final_output=$(commands_dispatch "$final_cmd" "$workdir" 2>&1 | head -c 2000)
                final_exit=${PIPESTATUS[0]}
            else
                final_output=$(eval "$final_cmd" 2>&1 | head -c 2000)
                final_exit=${PIPESTATUS[0]}
            fi

            if [ "$final_exit" -eq 0 ]; then
                # ── Recovery Logging ───────────────────────────
                # Write a RECOVERY entry to the failure log so that
                # future L3 escalations can find what the operator
                # told us to do for similar failures.
                {
                    echo ""
                    echo "RECOVERY: \`$final_cmd\`"
                    echo "OPERATOR GUIDANCE: $guidance"
                    echo "ORIGINAL FAILURE: \`$last_failed_cmd\`"
                    echo "---"
                } >> "$fail_file"
                local summary="Completed with operator guidance"
                local _step_ts
                _step_ts=$(date '+%Y-%m-%d %H:%M:%S')
                echo -e "\n**Action:** \`$final_cmd\`\n**Status:** EXECUTED SUCCESSFULLY (exit 0)\n**Output:**\n\`\`\`\n$final_output\n\`\`\`" >> "$micro_file"
                echo -e "\n**Milestone Result:** COMPLETE — $summary" >> "$micro_file"
                echo "- Step [$_step_ts]: $micro_objective -> $summary | ran: $final_cmd (exit 0)" >> "$george_dir/macro_memory.md"
                return 0
            else
                # Log guided failure for the record
                echo -e "\nFAILED COMMAND (guided): \`$final_cmd\`\nEXIT CODE: $final_exit\nOPERATOR GUIDANCE: $guidance\nOUTPUT:\n$final_output\n---" >> "$fail_file"
            fi
        fi
    fi

    local _step_ts
    _step_ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "- Step [$_step_ts]: $micro_objective -> FAILED" >> "$george_dir/macro_memory.md"
    return 1
}

# ── Run full task: Macro Loop (The Strategist) ────────────────
# Governs the overall trajectory of the task using a dynamic
# dual-loop ReAct architecture:
#   Macro Loop: Determines the next high-level milestone.
#   Micro Loop: Executes via agent_inner_loop.
#
# Memory Architecture (all legacy CLAUDE.md references migrated to GEORGE.md):
#   macro_memory.md — Persona seed + objective + completed milestones.
#   micro_memory.md — Overwritten per micro-objective (managed by inner loop).
#   failures_log.md — Isolated stderr graveyard (managed by inner loop).
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

    # Reset debug counters at task start
    declare -f llm_debug_reset &>/dev/null && llm_debug_reset

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

    # ── Initialize Memory Architecture ────────────────────────
    local george_dir="$workdir/.george"
    local macro_file="$george_dir/macro_memory.md"
    local fail_file="$george_dir/failures_log.md"
    mkdir -p "$george_dir"

    # Seed macro_memory.md with the identity section from soul.md
    # and the primary objective. This persists for the duration of the task.
    # Uses _memory_soul_identity() for a clean cut at the TMS boundary
    # instead of an arbitrary head -20 that could split mid-paragraph.
    {
        echo "# George — Task Memory"
        echo ""
        echo "## Persona"
        _memory_soul_identity
        echo ""
        echo "## Primary Objective"
        echo "$task"
        echo ""
        echo "## Completed Milestones"
        echo "(none yet)"
    } > "$macro_file"

    # Create failures log alongside macro memory
    echo "# Failures Log" > "$fail_file"
    echo "---" >> "$fail_file"

    # ── Macro Loop: Milestone-by-milestone execution ──────────
    local macro_iterations=0
    local max_macro_loops="${AGENT_MAX_STEPS:-20}"
    local completed_milestones=0
    local failed_milestones=""
    local _exec_log=""
    # Milestone deduplication: track attempted milestones so the
    # strategist doesn't regenerate the same failed milestone in a
    # loop. Each entry is "status|milestone_text".
    local -a _attempted_milestones=()

    while [ "$macro_iterations" -lt "$max_macro_loops" ]; do
        # Check for cancellation between milestones
        if [ "${_LODGE_CANCELLED:-0}" -eq 1 ] || [ -f "$_cancel_file" ]; then
            ui_warn "Task cancelled at milestone $((macro_iterations + 1))"
            break
        fi

        # Inter-milestone vitals check
        if declare -f vitals_guard_disk &>/dev/null; then
            if ! vitals_guard_disk 2>/dev/null; then
                ui_warn "Stopping task — disk critically low"
                break
            fi
            vitals_guard_ram 2>/dev/null || true
        fi

        # Read macro_memory.md and ask for the SINGLE next milestone
        local macro_context
        macro_context=$(cat "$macro_file")
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: strategist <- macro_memory ($(echo "$macro_context" | wc -l) lines)"

        local macro_prompt="Read the following task memory. What is the SINGLE next logical milestone to advance the Primary Objective? If the objective is fully complete, reply with EXACTLY the word DONE and nothing else.\n\n$macro_context"

        # Use a lean system prompt — no personality, just strategic reasoning.
        # By stripping the ~500-token soul and ~200-token vitals during
        # execution, we drastically reduce prefill time. Ollama flushes the
        # context window (not the 4GB model) so a 150-token prompt reasons
        # almost instantly.
        #
        # CRITICAL: The strategist MUST know what tools exist so milestones
        # align with real slash commands. Without this, the 4B model invents
        # actions like "Research evidence-based..." that the inner loop can't
        # execute. Use a lean command list (~200 tokens) instead of the full
        # catalog (~800 tokens) — the strategist only needs to ROUTE, not
        # generate exact syntax (the specialist handles that).
        local _tool_summary=""
        _tool_summary="YOUR WORKING COMMANDS (by category):
KNOWLEDGE: /ask /recall /journal write
FILES: /write /save /download /init /clone /build /test /fix /commit /push
WEB: /web search|fetch|images|scrape-images /github search /vision
COMMUNICATION: /social post discord|telegram|x|mastodon <target> <text>
  /social discord dm|read <user|channel> /email send|inbox /phone
  /email send provider address subject= body=
SANDBOX: /sandbox new|build|test|run|cd|rm /container create|enter
CONFIG: /pgp sign|export /secret set|get /git setup|status /vitals /backup local|restore
EXTENSION: /slash create|run"

        # Service status: let strategist know what's configured vs not
        local _svc_status=""
        if declare -f commands_services_status &>/dev/null; then
            _svc_status=$(commands_services_status 2>/dev/null)
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && [ -n "$_svc_status" ] && ui_dim "  [debug] inject: strategist <- services status"
        fi

        # ── Inject milestone history into strategist prompt ─────
        # Prevents the strategist from regenerating failed milestones.
        local _milestone_history=""
        if [ ${#_attempted_milestones[@]} -gt 0 ]; then
            _milestone_history="\n\nPREVIOUSLY ATTEMPTED MILESTONES (do NOT repeat failed ones):"
            for _am in "${_attempted_milestones[@]}"; do
                _milestone_history="${_milestone_history}\n- ${_am}"
            done
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] inject: strategist <- milestone history (${#_attempted_milestones[@]} entries)"
        fi

        local macro_sys="You are a strategic planning engine. Given a task memory with completed milestones, determine the single next milestone needed.

${_tool_summary}

SERVICES STATUS: ${_svc_status:-unknown}

STRATEGIC RULES:
- If the user explicitly names a tool or action (e.g., 'search the web', 'post to discord', 'send email', 'download'), route to that tool — NEVER override with /ask
- ONLY use /ask for simple questions George can answer from his own knowledge with NO tools (e.g., 'what is a monad?', 'explain recursion')
- Every milestone MUST use a command from YOUR WORKING COMMANDS above. Do NOT invent commands.
- To post to Discord/Telegram/X, use /social (NOT /email). /email is for actual email addresses only.
- Do NOT use /sandbox to run slash commands. Slash commands run directly.
- ONLY use services that are CONFIGURED (see SERVICES STATUS above)
- Frame milestones as tool-executable actions, not abstract goals
- RESEARCH MILESTONES: If you lack information needed to proceed (API keys, URLs, package names, technical details), create a milestone to gather that information using /web search, /recall, /web fetch, or /social discord read. It is ALWAYS acceptable to create a milestone whose purpose is research or information gathering.
- If a task requires credentials or keys you don't have, search for them (/secret get, /web search, /recall) before giving up.
- Use /recall to check your knowledge base before assuming you don't know something.
- Do NOT regenerate a milestone that previously FAILED — try a different approach or skip it
- For multi-part tasks, advance to the NEXT part even if a previous part partially failed
- For multi-part tasks, advance to the NEXT part even if a previous part partially failed
- COMPLETION: When the Primary Objective is fulfilled, output EXACTLY the word DONE (nothing else)
- CONVERSATION RULE: If the user's objective is simply to chat or ask a question, and you have executed the /ask command to answer them, the objective is complete. Output DONE.
- NEVER prefix a milestone with DONE, DONE:, COMPLETE, or any completion keyword — those are reserved signals
- MILESTONE FORMAT: Output ONLY a concise imperative sentence (e.g., 'Search the web for X', 'Use /recall to look up syntax').
- NO INTRODUCTIONS. NO EXPLANATIONS. NEVER say 'The next milestone is...'. Output the action and NOTHING else.${_milestone_history}"

        ui_think "Strategist: determining next milestone..."
        local milestone
        # Use llm_generate (non-streaming) for the strategist. The output
        # is a brief milestone description displayed once by ui_info below.
        # Previously llm_stream showed it live, then ui_info showed it again,
        # then the specialist streamed it a third time — tripling the output.
        local LLM_SCENARIO=strategist
        milestone=$(llm_generate "$macro_prompt" "$macro_sys" "${LLM_STRATEGIST_TOKENS:-512}" "$LLM_BUDGET_AGENT")

        # ── MILESTONE CLEANUP ─────────────────────────────────
        # The strategist should output one imperative sentence, but
        # small models sometimes emit <think> blocks, code fences,
        # explanatory preamble, or repetitive content. Strip all of
        # that so the milestone is a clean, single-line action.
        # 1. Remove <think>...</think> and [THINK]...[/THINK] blocks (including multi-line)
        milestone=$(echo "$milestone" | sed ':a;N;$!ba;s/<think>[^<]*<\/think>//g')
        milestone=$(echo "$milestone" | sed 's/\[THINK\][^[]*\[\/THINK\]//gI')
        milestone=$(echo "$milestone" | sed 's/\[THOUGHT\][^[]*\[\/THOUGHT\]//gI')
        # 2. Remove stray opening/closing think tags (both formats, all case variants)
        milestone=$(echo "$milestone" | sed 's/<\/?think>//gI')
        milestone=$(echo "$milestone" | sed 's/\[\/?THINK\]//gI')
        milestone=$(echo "$milestone" | sed 's/\[\/?THOUGHT\]//gI')
        # 3. Remove code fences and their content
        milestone=$(echo "$milestone" | sed '/^```/,/^```/d')
        # 4. Strip leading/trailing whitespace and blank lines
        milestone=$(echo "$milestone" | sed '/^[[:space:]]*$/d' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        # 5. Take ONLY the first non-empty line (milestone = one sentence)
        milestone=$(echo "$milestone" | head -1)
        # 6. Truncate to 200 chars max (prevents context bloat)
        milestone="${milestone:0:200}"

        # ── Check for completion ──────────────────────────────
        if [ -z "$milestone" ] || [[ "$milestone" == ERROR* ]]; then
            ui_err "Macro loop failed: ${milestone:-empty response}"
            break
        fi

        if [[ "$milestone" == DONE* ]]; then
            ui_ok "Strategist: Objective complete."
            break
        fi

        # ── MILESTONE DEDUPLICATION CHECK ─────────────────────
        # If the strategist generated a milestone substantially similar
        # to one that already failed, detect it and either force the
        # strategist to try a different approach or skip ahead.
        local _milestone_lower
        _milestone_lower=$(echo "$milestone" | tr '[:upper:]' '[:lower:]')
        local _dup_count=0
        for _prev in "${_attempted_milestones[@]}"; do
            local _prev_text _prev_lower
            _prev_text="${_prev#*|}"  # strip "FAILED|" or "OK|" prefix
            _prev_lower=$(echo "$_prev_text" | tr '[:upper:]' '[:lower:]')
            # Check for substantial similarity (first 40 chars match or
            # both contain the same primary slash command + keyword)
            if [ "${_milestone_lower:0:40}" = "${_prev_lower:0:40}" ]; then
                _dup_count=$((_dup_count + 1))
            fi
        done
        if [ "$_dup_count" -ge "${AGENT_MAX_MILESTONE_RETRIES:-2}" ]; then
            ui_warn "Milestone '$milestone' already attempted $_dup_count times — forcing progression"
            echo "- Milestone: $milestone -> SKIPPED (duplicate of failed milestone)" >> "$macro_file"
            _attempted_milestones+=("SKIPPED|$milestone")
            macro_iterations=$((macro_iterations + 1))
            _exec_log="${_exec_log}Milestone $macro_iterations: ${milestone:0:60} — SKIPPED (dup)\n"
            sleep "${AGENT_STEP_DELAY:-1}"
            continue
        fi

        # ── Execute milestone via Micro Loop ──────────────────
        macro_iterations=$((macro_iterations + 1))
        echo ""
        ui_section "Milestone $macro_iterations"
        ui_info "$milestone"

        if agent_inner_loop "$milestone" "$workdir"; then
            completed_milestones=$((completed_milestones + 1))
            _exec_log="${_exec_log}Milestone $macro_iterations: ${milestone:0:60} — OK\n"
            _attempted_milestones+=("OK|$milestone")

            # Remove the seed placeholder after first successful milestone.
            # Without this, "(none yet)" sits above real step entries in
            # macro_memory and misleads the evaluator/strategist into
            # thinking no milestones have been completed.
            if [ "$completed_milestones" -eq 1 ]; then
                sed -i '/^(none yet)$/d' "$macro_file"
            fi
        else
            failed_milestones="${failed_milestones:+${failed_milestones}, }milestone $macro_iterations: $milestone"
            _exec_log="${_exec_log}Milestone $macro_iterations: ${milestone:0:60} — FAILED\n"
            _attempted_milestones+=("FAILED|$milestone")

            # Check if failure was due to cancellation or operator abort
            if [ "${_LODGE_CANCELLED:-0}" -eq 1 ] || [ -f "$_cancel_file" ]; then
                ui_warn "Milestone $macro_iterations cancelled"
                break
            fi
        fi

        # ── Evaluator: check if objective is already fulfilled ─
        # After each completed milestone, an impartial evaluator
        # judges whether the primary objective has been satisfied.
        # This prevents unnecessary extra milestones when the task
        # is already done. Skipped when AGENT_EVAL_MODE=disabled.
        if [ "${AGENT_EVAL_MODE:-auto}" != "disabled" ] && [ "$completed_milestones" -gt 0 ]; then
            if _agent_evaluate_completion "$macro_file" "$george_dir/micro_memory.md"; then
                break
            else
                # Inject evaluator's INCOMPLETE reason into milestone history
                # so the strategist can use it when planning the next milestone.
                if [ -n "${_EVAL_INCOMPLETE_REASON:-}" ]; then
                    _attempted_milestones+=("EVAL|still missing: $_EVAL_INCOMPLETE_REASON")
                fi
            fi
        fi

        sleep "${AGENT_STEP_DELAY:-1}"
    done

    # ── Task complete ─────────────────────────────────────────
    # Capture cancellation state BEFORE resetting — needed to skip
    # post-task journal reflection (which triggers a model switch to
    # the secondary model and can crash Termux if Ollama is still
    # recovering from the killed curl requests).
    local _was_cancelled=0
    if [ "${_LODGE_CANCELLED:-0}" -eq 1 ] || [ -f "$_cancel_file" ]; then
        _was_cancelled=1
    fi
    _LODGE_IN_TASK=0
    _LODGE_CANCELLED=0

    echo ""
    ui_divider
    if [ "$_was_cancelled" -eq 1 ]; then
        ui_warn "Task cancelled ($completed_milestones/$macro_iterations milestones completed before cancellation)"
    elif [ "$macro_iterations" -eq 0 ]; then
        ui_ok "Task complete: objective resolved without milestones"
    else
        ui_ok "Task complete: $completed_milestones/$macro_iterations milestones succeeded"
    fi

    # Print debug summary (timers + token totals) if enabled
    declare -f llm_debug_summary &>/dev/null && llm_debug_summary

    # Reflect in journal (background — don't block user)
    # SKIP if task was cancelled — journal_reflect triggers a model switch
    # to the secondary model (LLM_SCENARIO=journal → LODGE_MODEL_SECONDARY).
    # After Ctrl+C, Ollama may still be cleaning up killed requests; issuing
    # a model unload+load at that moment races with the cleanup and can crash
    # Termux. The cancelled task will be visible in macro_memory.md anyway.
    if [ "$_was_cancelled" -eq 0 ]; then
        local reflect_summary="$task ($completed_milestones/$macro_iterations milestones in $(basename "$workdir"))"
        if [ -n "$failed_milestones" ]; then
            reflect_summary="${reflect_summary}. Failed: ${failed_milestones}"
        fi
        journal_reflect "$reflect_summary" "$workdir" "$_exec_log" &

        # Notify on phone if available
        tools_phone_toast "Lodge: Task complete ($completed_milestones/$macro_iterations milestones)"
    fi

    # Model stays loaded during active session for fast response times.
    # It will be unloaded on session exit (lodge main) or by keep_alive timeout.

    return 0
}

# ── Conversation history (ring buffer for /ask continuity) ─────
# Stores last N exchanges so George remembers recent conversation.
# Each entry: "USER: ...\nGEORGE: ..."
_AGENT_CONV_HISTORY=()
AGENT_CONV_MAX="${AGENT_CONV_MAX:-3}"  # Keep last 3 exchanges (~300-600 tokens)

_agent_conv_push() {
    local user_msg="$1"
    local george_msg="$2"
    # Truncate long responses to ~150 chars to stay token-lean
    local trunc_response="${george_msg:0:150}"
    [ ${#george_msg} -gt 150 ] && trunc_response="${trunc_response}..."
    _AGENT_CONV_HISTORY+=("USER: $user_msg
GEORGE: $trunc_response")
    # Trim to max size
    while [ ${#_AGENT_CONV_HISTORY[@]} -gt "$AGENT_CONV_MAX" ]; do
        _AGENT_CONV_HISTORY=("${_AGENT_CONV_HISTORY[@]:1}")
    done
}

_agent_conv_context() {
    if [ ${#_AGENT_CONV_HISTORY[@]} -eq 0 ]; then
        echo ""
        return
    fi
    local ctx="--- RECENT CONVERSATION ---"
    for entry in "${_AGENT_CONV_HISTORY[@]}"; do
        ctx="$ctx
$entry"
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
    
    # Stream the response so user sees tokens arrive in real-time
    echo ""
    local response
    local LLM_SCENARIO=ask
    response=$(llm_stream "$full_question" "$system_prompt" "$LLM_ASK_TOKENS" "$LLM_BUDGET_ASK")
    echo ""
    
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
    
    # Journal the exchange — George writes a witty one-liner for posterity
    # Runs in background so user isn't blocked
    if declare -f journal_write_quip &>/dev/null; then
        journal_write_quip "$question" "$response" &
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
            agent_inner_loop "${steps[$i]}" "$workdir"
        else
            ui_warn "Skipped step $step_num"
            memory_append_section "Completed Steps" "Step $step_num: SKIPPED — ${steps[$i]}" "$workdir"
        fi
    done
}
