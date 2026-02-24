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
AGENT_MAX_STEPS="${AGENT_MAX_STEPS:-20}"
AGENT_STEP_DELAY="${AGENT_STEP_DELAY:-1}"
AGENT_MAX_CLARIFY="${AGENT_MAX_CLARIFY:-2}"
AGENT_INTERACTIVE_PLANNING="${AGENT_INTERACTIVE_PLANNING:-0}"
AGENT_MAX_DEPTH="${AGENT_MAX_DEPTH:-2}"
AGENT_MAX_RETRIES="${AGENT_MAX_RETRIES:-1}"  # Auto-retry failed steps before asking human

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
# Parent context is injected into CLAUDE.md so the subtask knows
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
- THINK FIRST: Is this a question or conversation? If so, output ONLY: 1. /ask <the user's question>. Done. No sandbox, no coding.
- Use the MINIMUM steps needed. Most tasks need 1-3 steps. Maximum: 4 steps.
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

# ── Dynamic Inner Loop Prompts ─────────────────────────────────
# Replaces the monolithic memory_build_system_prompt for inner loops.
# These prompts contain ZERO personality, vitals, or history.
# This drastically reduces prefill time — Ollama flushes the KV cache
# but does NOT reload the 4GB model from disk.

_build_router_prompt() {
    # Phase 1 Prompt: The Command Catalog Router
    # Provides the full lean command index so George routes to his
    # purpose-built slash commands instead of defaulting to raw bash.
    # Uses commands_catalog_plan() when available (dynamic, includes
    # custom /slash commands), otherwise falls back to a static index.
    echo "You are George's tactical routing engine. Pick the best tool."
    echo ""
    if declare -f commands_catalog_plan &>/dev/null; then
        commands_catalog_plan
    else
        cat << 'ROUTER_CATALOG'
--- COMMANDS (use ONLY these) ---
/ask <question>          — Quick answer (no planning)
/init <name> <lang>      — Scaffold project
/recall <query>          — Search knowledge base
/save <file> <text>      — Save content to file
/write <file> <text>     — Write/overwrite a file
/download <url> [dest]   — Download a URL
/sandbox new <name> [type] — Create sandbox (rust/python/shell)
/sandbox build|test|run|cd|rm <name> — Sandbox operations
/sandbox clone <url> [name] — Clone repo into sandbox
/clone <url>             — Clone and setup a repo
/build [release]         — Build project
/test [args]             — Run tests
/fix [error]             — Diagnose and fix
/commit [msg]            — AI commit message + commit
/push                    — Push to GitHub
/web search <query>      — Web search
/web fetch <url>         — Fetch a URL
/github search <q>       — Find GitHub repos
/journal write <text>    — Write to journal
/social post <text>      — Post to social platforms
/social <platform> <act> — Platform-specific action
/pgp sign|signpost|export — PGP operations
/email send|inbox|status — Email operations
/phone                   — Phone dashboard
/secret set|get <k>      — Encrypted secrets
/slash create <name> <desc> — Create custom command
/vitals                  — System dashboard
/git setup|status|ssh-keygen — Git configuration
/backup local|restore|github — Backup operations
bash                     — Standard Linux shell (fallback)
ROUTER_CATALOG
    fi
    echo ""
    echo "Output ONLY the tool name. For slash commands output the base command"
    echo "(e.g., '/web', '/sandbox', '/write', '/social', '/git', 'bash')."
    echo "If unsure which tool, output 'bash'."
}

_build_specialist_prompt() {
    local cmd_name="$1"
    local workdir="$2"
    # Phase 2 Prompt: The Action Specialist
    # Injects deep-dive docs for ONE specific command.
    #
    # Slash commands: output on their own line starting with /
    #   (commands_dispatch handles execution)
    # Bash commands: output inside a ```bash block
    #   (eval handles execution)

    if [ "$cmd_name" != "bash" ]; then
        echo "You are George's execution engine. Output exactly ONE slash command."
        echo "Output the FULL command on its own line starting with / — do NOT wrap in a code block."
        echo ""

        # Extract docs for the specific command.
        # Strategy: grep the command reference table from SLASH_COMMANDS.md,
        # then fall back to recall, then to commands_catalog_plan.
        local docs=""

        # 1. Try table rows matching the command from the Command Reference
        if [ -f "$LODGE_DIR/docs/SLASH_COMMANDS.md" ]; then
            docs=$(grep -E "^\| \`$cmd_name" "$LODGE_DIR/docs/SLASH_COMMANDS.md" 2>/dev/null | head -8)
        fi

        # 2. Fall back to recall FTS5 search for richer docs
        if [ -z "$docs" ] && declare -f recall_search_context &>/dev/null; then
            docs=$(recall_search_context "$cmd_name" 2 2>/dev/null)
        fi

        # 3. Last resort: extract from the plan catalog
        if [ -z "$docs" ] && declare -f commands_catalog_plan &>/dev/null; then
            docs=$(commands_catalog_plan 2>/dev/null | grep -i "${cmd_name#/}" | head -5)
        fi

        if [ -n "$docs" ]; then
            echo "COMMAND DOCUMENTATION:"
            echo "$docs"
        fi
    else
        echo "You are George's execution engine. Output exactly ONE command inside a \`\`\`bash block."
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
    echo "## Action Log" >> "$micro_file"

    local inner_attempts=0
    local max_inner_loops=6
    local last_failed_cmd=""

    while [ "$inner_attempts" -lt "$max_inner_loops" ]; do
        local inner_context=$(cat "$micro_file")

        # ── PHASE 1: Fast Tool Routing ────────────────────────
        local router_sys=$(_build_router_prompt)
        local route_prompt="Review the Action Log. If objective complete, output SUCCESS: <summary>. Otherwise, output the tool name needed.\n\n$inner_context"

        # llm_generate is used here for maximum speed — no streaming,
        # no personality, just returns the raw string.
        local selected_tool
        selected_tool=$(llm_generate "$route_prompt" "$router_sys" "${LLM_ASK_TOKENS:-300}")

        if [[ "$selected_tool" == *"SUCCESS:"* ]]; then
            local summary
            summary=$(echo "$selected_tool" | sed 's/.*SUCCESS: //')
            echo "- Step: $micro_objective -> $summary" >> "$george_dir/macro_memory.md"
            return 0
        fi

        # ── PHASE 2: Specialist Execution ─────────────────────
        # sed -e 's/^[[:space:]]*//' : Strips leading whitespace.
        # sed -e 's/[[:space:]]*$//' : Strips trailing whitespace.
        selected_tool=$(echo "$selected_tool" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        local specialist_sys=$(_build_specialist_prompt "$selected_tool" "$workdir")

        # Inject micro_memory (action log) so the specialist sees
        # prior outputs, created files, and error history. Without this,
        # multi-step objectives fail because the specialist can't adapt.
        local specialist_prompt="MICRO OBJECTIVE: $micro_objective\n\nACTION LOG:\n$inner_context\n\nWrite the exact command to execute next."

        local action_plan
        action_plan=$(llm_stream "$specialist_prompt" "$specialist_sys" "${LLM_ASK_TOKENS:-300}")

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
                echo -e "\n**Action:** \`$cmd\`\n**Result:**\n\`\`\`\n$output\n\`\`\`" >> "$micro_file"
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
                    echo -e "\n**Action:** \`$cmd\` (Retry OK)\n**Result:**\n\`\`\`\n$output\n\`\`\`" >> "$micro_file"
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
                fi
            fi

            # ── Levels 3-4: Syntax Permutation ────────────────
            # (Handled by the identicality lockout at the top of the loop.
            #  The LLM will see the failure context in micro_memory and
            #  generate a new command. If it's identical, the interlock
            #  rejects it and forces another generation.)

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
                fi
            fi

            # Append failure to micro memory so the LLM sees it on the next loop
            echo -e "\n**Failed Action:** \`$cmd\`\n**Error:**\n\`\`\`\n$output\n\`\`\`" >> "$micro_file"
        fi

        inner_attempts=$((inner_attempts + 1))
    done

    # ── Terminal Escalation: Human Operator Intervention ───────
    # All 5 levels exhausted. Drop to a safe holding state.
    # Present failures_log.md to the operator for guidance.
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
    if [ -n "$guidance" ] && [ "$guidance" != "abort" ]; then
        echo -e "\n**Operator Guidance:** $guidance" >> "$micro_file"
        # One final attempt with human guidance injected into context
        local inner_context=$(cat "$micro_file")
        local specialist_sys=$(_build_specialist_prompt "bash" "$workdir")
        local final_plan
        final_plan=$(llm_stream "The operator said: $guidance. Write the exact command." "$specialist_sys" "${LLM_ASK_TOKENS:-300}")
        local final_cmd
        final_cmd=$(echo "$final_plan" | awk '/```bash/{flag=1; next} /```/{flag=0} flag')
        if [ -n "$final_cmd" ]; then
            ui_step "Running (guided): $final_cmd"
            local final_output
            final_output=$(eval "$final_cmd" 2>&1 | head -c 2000)
            if [ ${PIPESTATUS[0]} -eq 0 ]; then
                local summary="Completed with operator guidance"
                echo "- Step: $micro_objective -> $summary" >> "$george_dir/macro_memory.md"
                return 0
            fi
        fi
    fi

    echo "- Step: $micro_objective -> FAILED" >> "$george_dir/macro_memory.md"
    return 1
}

# ── Run full task: Macro Loop (The Strategist) ────────────────
# Governs the overall trajectory of the task using a dynamic
# dual-loop ReAct architecture:
#   Macro Loop: Determines the next high-level milestone.
#   Micro Loop: Executes via agent_inner_loop.
#
# Memory Architecture (all legacy CLAUDE.md references eradicated):
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

    # Seed macro_memory.md with a ~500-token persona summary from soul.md
    # and the primary objective. This persists for the duration of the task.
    {
        echo "# George — Task Memory"
        echo ""
        echo "## Persona"
        # Extract a lean persona summary: first 20 lines of soul.md (~500 tokens)
        if [ -f "$LODGE_DIR/soul.md" ]; then
            head -20 "$LODGE_DIR/soul.md"
        else
            echo "You are George, a concise coding agent for mobile devices."
        fi
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

        local macro_prompt="Read the following task memory. What is the SINGLE next logical milestone to advance the Primary Objective? If the objective is fully complete, reply DONE.\n\n$macro_context"

        # Use a lean system prompt — no personality, just strategic reasoning.
        # By stripping the ~500-token soul and ~200-token vitals during
        # execution, we drastically reduce prefill time. Ollama flushes the
        # context window (not the 4GB model) so a 150-token prompt reasons
        # almost instantly.
        local macro_sys="You are a strategic planning engine. Given a task memory with completed milestones, determine the single next milestone needed. Output either DONE or a concise milestone description (one sentence, imperative mood). Output NOTHING else."

        ui_think "Strategist: determining next milestone..."
        local milestone
        milestone=$(llm_generate "$macro_prompt" "$macro_sys" "${LLM_ASK_TOKENS:-300}")

        # Strip whitespace for clean comparison
        milestone=$(echo "$milestone" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        # ── Check for completion ──────────────────────────────
        if [ -z "$milestone" ] || [[ "$milestone" == ERROR* ]]; then
            ui_err "Macro loop failed: ${milestone:-empty response}"
            break
        fi

        if [[ "$milestone" == "DONE" ]] || [[ "$milestone" == "DONE." ]] || [[ "$milestone" == *"DONE"* && ${#milestone} -lt 10 ]]; then
            ui_ok "Strategist: Objective complete."
            break
        fi

        # ── Execute milestone via Micro Loop ──────────────────
        macro_iterations=$((macro_iterations + 1))
        echo ""
        ui_section "Milestone $macro_iterations"
        ui_info "$milestone"

        if agent_inner_loop "$milestone" "$workdir"; then
            completed_milestones=$((completed_milestones + 1))
            _exec_log="${_exec_log}Milestone $macro_iterations: ${milestone:0:60} — OK\n"
        else
            failed_milestones="${failed_milestones:+${failed_milestones}, }milestone $macro_iterations: $milestone"
            _exec_log="${_exec_log}Milestone $macro_iterations: ${milestone:0:60} — FAILED\n"

            # Check if failure was due to cancellation
            if [ "${_LODGE_CANCELLED:-0}" -eq 1 ] || [ -f "$_cancel_file" ]; then
                ui_warn "Milestone $macro_iterations cancelled"
                break
            fi
        fi

        sleep "${AGENT_STEP_DELAY:-1}"
    done

    # ── Task complete ─────────────────────────────────────────
    _LODGE_IN_TASK=0
    _LODGE_CANCELLED=0

    echo ""
    ui_divider
    if [ "$macro_iterations" -eq 0 ]; then
        ui_ok "Task complete: objective resolved without milestones"
    else
        ui_ok "Task complete: $completed_milestones/$macro_iterations milestones succeeded"
    fi

    # Reflect in journal (background — don't block user)
    local reflect_summary="$task ($completed_milestones/$macro_iterations milestones in $(basename "$workdir"))"
    if [ -n "$failed_milestones" ]; then
        reflect_summary="${reflect_summary}. Failed: ${failed_milestones}"
    fi
    journal_reflect "$reflect_summary" "$workdir" "$_exec_log" &

    # Notify on phone if available
    tools_phone_toast "Lodge: Task complete ($completed_milestones/$macro_iterations milestones)"

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
    response=$(llm_stream "$full_question" "$system_prompt" "$LLM_ASK_TOKENS")
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
