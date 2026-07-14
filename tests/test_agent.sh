#!/bin/bash
# ── Tests: lib/agent.sh ───────────────────────────────────────
# Agent tests verify function structure and config — actual LLM
# calls are mocked since we can't depend on Ollama in CI.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/llm.sh"
source "$LODGE_DIR/lib/memory.sh"
source "$LODGE_DIR/lib/tools.sh"
source "$LODGE_DIR/lib/journal.sh"
source "$LODGE_DIR/lib/providers.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agent.sh"

test_start "lib/agent.sh — Agent Loop"

# ── Configuration ──────────────────────────────────────────────
describe "Configuration defaults"

  it "AGENT_MAX_STEPS defaults to 40" && {
    assert_eq "$AGENT_MAX_STEPS" "40"
  }

  it "AGENT_STEP_DELAY defaults to 1" && {
    assert_eq "$AGENT_STEP_DELAY" "1"
  }

# ── Function existence ─────────────────────────────────────────
describe "Core agent functions"

  it "agent_plan is defined" && {
    declare -f agent_plan &>/dev/null
    assert_ok $?
  }

  it "agent_inner_loop is defined" && {
    declare -f agent_inner_loop &>/dev/null
    assert_ok $?
  }

  it "agent_run is defined" && {
    declare -f agent_run &>/dev/null
    assert_ok $?
  }

  it "agent_ask is defined" && {
    declare -f agent_ask &>/dev/null
    assert_ok $?
  }

  it "agent_ask echoes response to stdout for capture" && {
    body=$(declare -f agent_ask)
    echo "$body" | grep -q 'echo "$response"'
    assert_ok $? "agent_ask must echo response to stdout so agent inner loop captures it"
  }

  it "agent_step_mode is defined" && {
    declare -f agent_step_mode &>/dev/null
    assert_ok $?
  }

# ── Cancellation state ────────────────────────────────────────
describe "Cancellation tracking"

  it "_LODGE_IN_TASK is initialized" && {
    # Variable should exist (may be set by sourcing lodge or set to 0 by default)
    assert_match "${_LODGE_IN_TASK:-0}" "^[01]$"
  }

  it "_LODGE_CANCELLED is initialized" && {
    assert_match "${_LODGE_CANCELLED:-0}" "^[01]$"
  }

# ── Inner loop cancellation ───────────────────────────────────
describe "Inner loop cancellation"

  it "agent_inner_loop checks cancel file at top of while loop" && {
    body=$(declare -f agent_inner_loop)
    # Must check cancel file BEFORE making any LLM calls
    echo "$body" | grep -q '_LODGE_CANCELLED.*-eq 1.*_cancel_file'
    assert_ok $?
  }

  it "agent_inner_loop checks cancel after router LLM call" && {
    body=$(declare -f agent_inner_loop)
    # After llm_generate there should be a cancel check (3+ cancel checks total)
    count=$(echo "$body" | grep -c '_LODGE_CANCELLED.*_cancel_file')
    [ "$count" -ge 3 ]
    assert_ok $?
  }

  it "agent_inner_loop checks cancel after specialist LLM call" && {
    body=$(declare -f agent_inner_loop)
    # The cancel check pattern appears at loop top + after router + after specialist = 3+
    count=$(echo "$body" | grep -c '_cancel_file')
    [ "$count" -ge 4 ]
    assert_ok $?
  }

  it "agent_inner_loop skips terminal escalation when cancelled" && {
    body=$(declare -f agent_inner_loop)
    # After the while loop ends, should check cancel before operator prompt
    # JSON: _macro_add_milestone writes CANCELLED status via jq
    echo "$body" | grep -q '_macro_add_milestone.*CANCELLED'
    assert_ok $?
  }

  it "agent_inner_loop writes CANCELLED to macro_memory on cancel" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_macro_add_milestone.*CANCELLED'
    assert_ok $?
  }

# ── llm_stream cancellation propagation ───────────────────────
describe "llm_stream cancellation propagation"

  it "llm_stream checks cancel file after pipe completes" && {
    body=$(declare -f llm_stream)
    # After the done block, should check cancel file and return 1
    echo "$body" | grep -A1 '_cancel_file' | grep -q 'return 1'
    assert_ok $?
  }

# ── agent_run input validation ─────────────────────────────────
describe "agent_run input validation"

  it "fails with empty task" && {
    agent_run "" "." >/dev/null 2>&1
    assert_fail $?
  }

# ── Clarification config ──────────────────────────────────────
describe "Clarification rounds"

  it "AGENT_MAX_CLARIFY defaults to 2" && {
    assert_eq "$AGENT_MAX_CLARIFY" "2"
  }

  it "AGENT_MAX_CLARIFY is overridable" && {
    (
      AGENT_MAX_CLARIFY=0
      assert_eq "$AGENT_MAX_CLARIFY" "0"
    )
    assert_ok $?
  }

# ── Agent ask user toggle ─────────────────────────────────────
describe "Agent ask user toggle"

  it "AGENT_ASK_USER defaults to 1 (enabled)" && {
    assert_eq "$AGENT_ASK_USER" "1"
  }

  it "AGENT_ASK_USER is overridable" && {
    (
      AGENT_ASK_USER=0
      assert_eq "$AGENT_ASK_USER" "0"
    )
    assert_ok $?
  }

  it "router prompt conditionally includes /ask via _ask_line" && {
    body=$(declare -f _build_router_prompt)
    echo "$body" | grep -q '_ask_line'
    assert_ok $? "Router must use _ask_line conditional for /ask injection"
  }

  it "router /ask injection is gated on AGENT_ASK_USER" && {
    body=$(declare -f _build_router_prompt)
    echo "$body" | grep -q 'AGENT_ASK_USER'
    assert_ok $? "Router must check AGENT_ASK_USER toggle"
  }

# ── User preference recall integration ────────────────────────
describe "User preference recall integration"

  it "agent_run flushes USER_INPUT milestones to recall" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'recall_log_user_input'
    assert_ok $? "agent_run must call recall_log_user_input for user inputs"
  }

  it "strategist injects pref hint when user_pref entries exist" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'recall_user_pref_count\|_pref_hint\|USER PREFERENCES ON FILE'
    assert_ok $? "strategist must include user preference hint"
  }

  it "task-success flush parses Q and A from macro_memory summary" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'User answered'
    assert_ok $? "flush must parse USER_INPUT summaries from macro_memory"
  }

# ── Interactive planning flag ─────────────────────────────────
describe "Interactive planning flag"

  it "AGENT_INTERACTIVE_PLANNING defaults to 0" && {
    assert_eq "$AGENT_INTERACTIVE_PLANNING" "0"
  }

  it "AGENT_INTERACTIVE_PLANNING is overridable" && {
    (
      AGENT_INTERACTIVE_PLANNING=1
      assert_eq "$AGENT_INTERACTIVE_PLANNING" "1"
    )
    assert_ok $?
  }

  it "agent_plan uses AGENT_INTERACTIVE_PLANNING to gate clarification" && {
    body=$(declare -f agent_plan)
    echo "$body" | grep -q "AGENT_INTERACTIVE_PLANNING"
    assert_ok $?
  }

  it "agent_plan includes 'Do NOT ask questions' instruction when non-interactive" && {
    body=$(declare -f agent_plan)
    echo "$body" | grep -q "Do NOT ask questions"
    assert_ok $?
  }

# ── Critical error detection ──────────────────────────────────
describe "Critical error detection"

  it "_agent_is_critical_error is defined" && {
    declare -f _agent_is_critical_error &>/dev/null
    assert_ok $?
  }

  it "detects missing API key errors" && {
    _agent_is_critical_error "Error: missing API key for service"
    assert_ok $?
  }

  it "detects missing package errors" && {
    _agent_is_critical_error "bash: jq: command not found"
    assert_ok $?
  }

  it "detects authentication errors" && {
    _agent_is_critical_error "Error: authentication failed"
    assert_ok $?
  }

  it "detects credentials errors" && {
    _agent_is_critical_error "No credentials provided"
    assert_ok $?
  }

  it "detects permission denied errors" && {
    _agent_is_critical_error "Permission denied (publickey)"
    assert_ok $?
  }

  it "does not treat slash command failures as critical (handled by auto-retry)" && {
    _agent_is_critical_error "Slash command failed: /deploy"
    assert_fail $?
  }

  it "detects not installed errors" && {
    _agent_is_critical_error "Error: node is not installed"
    assert_ok $?
  }

  it "returns false for generic errors" && {
    _agent_is_critical_error "Something went wrong"
    assert_fail $?
  }

  it "returns false for empty input" && {
    _agent_is_critical_error ""
    assert_fail $?
  }

  it "_AGENT_LAST_ERROR is initialized" && {
    assert_eq "$_AGENT_LAST_ERROR" ""
  }

# ── Plan prompt structure ──────────────────────────────────────
describe "Plan prompt includes clarification instruction"

  it "agent_plan function body mentions CLARIFY:" && {
    body=$(declare -f agent_plan)
    echo "$body" | grep -q "CLARIFY:"
    assert_ok $?
  }

  it "agent_plan function body mentions AGENT_MAX_CLARIFY" && {
    body=$(declare -f agent_plan)
    echo "$body" | grep -q "AGENT_MAX_CLARIFY"
    assert_ok $?
  }

  it "agent_plan function body reads from /dev/tty for user input" && {
    body=$(declare -f agent_plan)
    echo "$body" | grep -q "/dev/tty"
    assert_ok $?
  }

# ── Inline plan normalization ─────────────────────────────────
describe "Inline plan normalization"

  it "_agent_split_inline_steps is defined" && {
    declare -f _agent_split_inline_steps &>/dev/null
    assert_ok $?
  }

  it "splits inline numbered plans into separate lines" && {
    _input='1. /recall /sandbox  2. /plan /api --testnet  3. /init project'
    _result=$(_agent_split_inline_steps "$_input")
    _count=$(echo "$_result" | wc -l)
    assert_eq "$_count" "3"
  }

  it "preserves already multi-line plans" && {
    _input='1. First step
2. Second step
3. Third step'
    _result=$(_agent_split_inline_steps "$_input")
    _count=$(echo "$_result" | wc -l)
    assert_eq "$_count" "3"
  }

  it "handles parenthesis format" && {
    _input='1) First  2) Second  3) Third'
    _result=$(_agent_split_inline_steps "$_input")
    _count=$(echo "$_result" | wc -l)
    assert_eq "$_count" "3"
  }

  it "does not split single-step plans" && {
    _input='1. Just one step here'
    _result=$(_agent_split_inline_steps "$_input")
    _count=$(echo "$_result" | wc -l)
    assert_eq "$_count" "1"
  }

  it "does not false-positive on double-space-digit in normal text" && {
    _input='Check  2 files and fix bugs'
    _result=$(_agent_split_inline_steps "$_input")
    _count=$(echo "$_result" | wc -l)
    assert_eq "$_count" "1"
  }

# ── Dynamic prompt builders & inner loop architecture ──────────
describe "Dynamic dual-loop architecture"

  it "_build_router_prompt is defined" && {
    declare -f _build_router_prompt &>/dev/null
    assert_ok $?
  }

  it "_build_specialist_prompt is defined" && {
    declare -f _build_specialist_prompt &>/dev/null
    assert_ok $?
  }

  it "specialist includes /web syntax card for web tool" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q '/web search'
    assert_ok $?
    echo "$body" | grep -q '/web fetch'
    assert_ok $?
  }

  it "specialist journal card includes read and write syntax" && {
    body=$(declare -f _build_specialist_prompt)
    # Must document /journal (no args = read all)
    echo "$body" | grep -q '/journal.*Read ALL journal entries'
    assert_ok $?
    # Must document /journal show
    echo "$body" | grep -q '/journal show'
    assert_ok $?
    # Must document /journal write
    echo "$body" | grep -q '/journal write'
    assert_ok $?
    # Must warn against writing when task asks to read
    echo "$body" | grep -q 'NEVER write new content when the task asks you to check'
    assert_ok $?
  }

  it "router catalog lists journal as read or write" && {
    body=$(declare -f _build_router_prompt_full)
    echo "$body" | grep -q '/journal.*Read or write'
    assert_ok $?
  }

  it "strategist tool summary lists journal read and write" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '/journal","/journal write'
    assert_ok $?
  }

  it "agent_inner_loop uses escalation matrix" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'Escalation L1\|Naive retry'
    assert_ok $?
  }

  it "agent_inner_loop overwrites micro_memory per milestone" && {
    body=$(declare -f agent_inner_loop)
    # Strict overwrite: micro_memory is destroyed and recreated via _micro_init
    echo "$body" | grep -q '_micro_init.*micro_file'
    assert_ok $?
  }

  it "agent_inner_loop implements identicality lockout" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'Identical failed command'
    assert_ok $?
  }

  it "agent_inner_loop validates router tool output" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_tool_valid'
    assert_ok $?
  }

  it "macro strategist injects lean command list" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'YOUR WORKING COMMANDS'
    assert_ok $?
  }

  it "macro strategist uses llm_generate for clean output" && {
    body=$(declare -f agent_run)
    # The strategist milestone call should use llm_generate (not llm_stream)
    # so that milestone text doesn't appear twice (once streamed, once via ui_info).
    echo "$body" | grep -q 'llm_generate.*macro_prompt.*macro_sys'
    assert_ok $?
  }

  it "macro strategist uses LLM_SCENARIO=strategist (not agent)" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'LLM_SCENARIO=strategist'
    assert_ok $?
  }

  it "macro strategist uses LLM_STRATEGIST_TOKENS (not LLM_AGENT_TOKENS)" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'LLM_STRATEGIST_TOKENS'
    assert_ok $?
  }

  it "macro strategist strips <think> blocks from milestone" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_strip_think_blocks'
    assert_ok $?
  }

  it "macro strategist strips [THINK] blocks from milestone" && {
    # Functional test: verify the sed patterns actually strip bracket think tags
    _ms='[THINK]internal reasoning[/THINK]Do the task'
    _ms=$(echo "$_ms" | sed 's/\[THINK\][^[]*\[\/THINK\]//gI')
    _ms=$(echo "$_ms" | sed 's/\[\/?THINK\]//gI')
    _ms=$(echo "$_ms" | sed '/^[[:space:]]*$/d' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    assert_eq "$_ms" "Do the task"
    # Verify the code path exists in agent_run
    grep -q 'THINK' "$LODGE_DIR/lib/agent.sh"
    assert_ok $?
  }

  it "macro strategist strips [THOUGHT] blocks from milestone" && {
    _ms='[THOUGHT]internal reasoning[/THOUGHT]Do the task'
    _ms=$(echo "$_ms" | sed 's/\[THOUGHT\][^[]*\[\/THOUGHT\]//gI')
    _ms=$(echo "$_ms" | sed 's/\[\/?THOUGHT\]//gI')
    _ms=$(echo "$_ms" | sed '/^[[:space:]]*$/d' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    assert_eq "$_ms" "Do the task"
    grep -q 'THOUGHT' "$LODGE_DIR/lib/agent.sh"
    assert_ok $?
  }

  it "strategist DONE guard rejects DONE with pending honeydew items" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_dg_pending'
    assert_ok $? "Must check pending count on DONE"
    echo "$body" | grep -q 'hallucinated DONE'
    assert_ok $? "Must warn about hallucinated DONE"
  }

  it "strategist DONE guard substitutes next pending item" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_dg_next_task'
    assert_ok $? "Must read next pending task from honeydew"
    echo "$body" | grep -q 'milestone=.*_dg_next_task'
    assert_ok $? "Must override milestone with honeydew task"
  }

  it "strategist DONE guard allows DONE when all items complete" && {
    body=$(declare -f agent_run)
    # When _dg_pending is 0, the guard must fall through to break
    echo "$body" | grep -q '_dg_pending.*-gt 0'
    assert_ok $? "Must check if pending > 0 before overriding"
  }


  it "macro strategist has anti-sandbox rule" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '/sandbox.*NEVER.*slash\|NEVER for running slash'
    assert_ok $?
  }

  it "macro strategist injects service status" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'commands_services_status'
    assert_ok $?
  }

  it "router prompt has social routing rules" && {
    body=$(declare -f _build_router_prompt_full)
    echo "$body" | grep -q 'NOT.*email'
    assert_ok $?
  }

  it "router prompt has anti-sandbox rule" && {
    body=$(declare -f _build_router_prompt_full)
    echo "$body" | grep -q 'sandbox.*NEVER\|NOT.*sandbox'
    assert_ok $?
  }

  it "specialist prompt has anti-sandbox instruction" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'NOT use /sandbox to run slash'
    assert_ok $?
  }

  it "specialist prompt tells LLM not to quote arguments" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'quotes on args\|quotes_on_args\|NOT quote arguments'
    assert_ok $?
  }

  it "specialist prompt tells LLM one command per line" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'multiple commands per line\|multiple_commands_per_line\|ONE command per line'
    assert_ok $?
  }

  it "inner loop has sandbox programmatic interlock" && {
    body=$(declare -f agent_inner_loop)
    # _obj_lower is used to check if objective is code-related before allowing sandbox
    echo "$body" | grep -q '_obj_lower'
    assert_ok $?
    echo "$body" | grep -q 'build\|compile\|code\|project'
    assert_ok $?
  }

  it "inner loop has multi-command splitter" && {
    body=$(declare -f agent_inner_loop)
    # _first_cmd is used to extract just the first command from multi-command lines
    echo "$body" | grep -q '_first_cmd'
    assert_ok $?
  }

  it "inner loop has quote normalization" && {
    body=$(declare -f agent_inner_loop)
    # Strips double quotes from slash commands
    echo "$body" | grep -q 'sed.*s/\"//g'
    assert_ok $?
  }

# ── Router smart command extraction ─────────────────────────
describe "Router smart command extraction"

  it "inner loop scans for valid slash command in prose output" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_extracted_cmd'
    assert_ok $? "Must have smart extraction variable"
    echo "$body" | grep -q 'CMD_REGISTRY.*_candidate'
    assert_ok $? "Must validate candidate against registry"
  }

  it "smart extraction falls back to first-word when no valid command found" && {
    body=$(declare -f agent_inner_loop)
    # When _extracted_cmd is empty, falls back to head -1 | awk
    echo "$body" | grep -q '_extracted_cmd.*\]'
    assert_ok $? "Must check if extracted_cmd is set"
    echo "$body" | grep -q "head -1.*awk.*print.*1"
    assert_ok $? "Fallback must use head -1 | awk"
  }

  it "smart extraction prefers registry match over first word" && {
    body=$(declare -f agent_inner_loop)
    # The _extracted_cmd path runs BEFORE the fallback
    echo "$body" | grep -q 'extracted_cmd.*from prose output'
    assert_ok $? "Must log extracted command from prose"
  }

  it "agent_run resets debug counters" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'llm_debug_reset'
    assert_ok $?
  }

  it "agent_run prints debug summary" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'llm_debug_summary'
    assert_ok $?
  }

# ── Router heuristics: remap and direct respond ───────────────
describe "Router heuristics"

  it "router eligibility pass respects slash command in milestone and bypasses loose matching" && (
    _agent_router_probe_network() { return 0; }
    local out
    _AGENT_WEB_LOCKED=1 _AGENT_GIT_LOCKED=1 out=$(_agent_router_eligibility_pass "Use /journal to search for self-description" "." "web-search" "combined" "A" "normal")
    echo "$out" | grep -q '"shortlist":\[.*"journal".*\]'
    assert_ok $? "Shortlist must contain journal"
    echo "$out" | grep -q '"infeasibility_class":"none"'
    assert_ok $? "Must not trigger policy/capability lock for web"
  )

  it "remaps /research to /web" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'selected_tool.*==.*"research"'
    assert_ok $? "Must detect /research hallucination"
    echo "$body" | grep -q 'remapped.*web'
    assert_ok $? "Must remap to /web"
  }

  it "remaps /search to /web" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'selected_tool.*==.*"search"'
    assert_ok $? "Must detect /search hallucination"
  }

  it "direct respond bypasses specialist when no slash command found" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_direct_respond=1'
    assert_ok $? "Must set direct respond flag"
    echo "$body" | grep -q '_direct_respond.*-eq 1'
    assert_ok $? "Must check direct respond flag"
    echo "$body" | grep -q '/respond.*_router_full_text'
    assert_ok $? "Must route full text to /respond"
  }

  it "direct respond only triggers when no slash pattern exists in text" && {
    body=$(declare -f agent_inner_loop)
    # Must check for absence of /[a-z] pattern before triggering
    echo "$body" | grep -q '_router_full_text.*\/\[a-z\]'
    assert_ok $? "Must verify no slash pattern in full text"
  }

  it "saves router full text before extraction modifies it" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_router_full_text=.*selected_tool'
    assert_ok $? "Must save full text before extraction"
  }

  it "direct respond skips specialist LLM call" && {
    body=$(declare -f agent_inner_loop)
    # The specialist LLM call must be gated by the direct_respond check
    echo "$body" | grep -q '_direct_respond.*-eq 1.*then'
    assert_ok $? "Must guard specialist with direct_respond check"
    # Specialist prompt building only happens in else branch
    echo "$body" | grep -q '_build_specialist_prompt'
    assert_ok $? "Specialist prompt must exist outside direct respond path"
  }

  it "direct respond skips quote normalization and post-processing" && {
    body=$(declare -f agent_inner_loop)
    # The cleanup pipeline (quote strip, splitter, trimmer) must be
    # gated so prose text is not mangled (e.g. apostrophes in "it's").
    echo "$body" | grep -q '_direct_respond.*-ne 1'
    assert_ok $? "Must skip specialist output cleanup for direct respond"
  }

# ── Recursive planning config ─────────────────────────────────
describe "Recursive planning config"

  it "AGENT_MAX_DEPTH defaults to 3" && {
    assert_eq "$AGENT_MAX_DEPTH" "3"
  }

  it "AGENT_MAX_DEPTH is overridable" && {
    (
      AGENT_MAX_DEPTH=5
      assert_eq "$AGENT_MAX_DEPTH" "5"
    )
    assert_ok $?
  }

# ── Shared step parser ────────────────────────────────────────
describe "Shared step parser (_agent_parse_steps)"

  it "_agent_parse_steps is defined" && {
    declare -f _agent_parse_steps &>/dev/null
    assert_ok $?
  }

  it "parses numbered steps" && {
    _input='1. First step
2. Second step
3. Third step'
    _count=$(_agent_parse_steps "$_input" | wc -l)
    assert_eq "$_count" "3"
  }

  it "parses slash command lines" && {
    _input='1. Do something
/recall query
2. Do another thing'
    _count=$(_agent_parse_steps "$_input" | wc -l)
    assert_eq "$_count" "3"
  }

  it "parses dash/bullet list items" && {
    _input='- First item
- Second item'
    _count=$(_agent_parse_steps "$_input" | wc -l)
    assert_eq "$_count" "2"
  }

  it "preserves [SUBTASK] prefix in parsed steps" && {
    _input='1. Simple step
2. [SUBTASK] Build the frontend module
3. Another step'
    _result=$(_agent_parse_steps "$_input" | sed -n '2p')
    assert_contains "$_result" "[SUBTASK]"
  }

# ── Recursive subtask function ─────────────────────────────────
describe "Recursive subtask execution"

  it "_agent_run_subtask is defined" && {
    declare -f _agent_run_subtask &>/dev/null
    assert_ok $?
  }

  it "_agent_run_subtask detects [SUBTASK] markers" && {
    body=$(declare -f _agent_run_subtask)
    echo "$body" | grep -q 'SUBTASK'
    assert_ok $?
  }

  it "_agent_run_subtask function body checks AGENT_MAX_DEPTH" && {
    body=$(declare -f _agent_run_subtask)
    echo "$body" | grep -q 'AGENT_MAX_DEPTH'
    assert_ok $?
  }

  it "_agent_run_subtask function body calls agent_plan" && {
    body=$(declare -f _agent_run_subtask)
    echo "$body" | grep -q 'agent_plan'
    assert_ok $?
  }

# ── Plan prompt references configurable step limit ─────────────
describe "Plan prompt uses configurable step limit"

  it "agent_plan prompt uses AGENT_PLAN_STEPS variable" && {
    body=$(declare -f agent_plan)
    echo "$body" | grep -q 'AGENT_PLAN_STEPS'
    assert_ok $?
  }

  it "AGENT_PLAN_STEPS defaults to 8" && {
    assert_eq "$AGENT_PLAN_STEPS" "8"
  }

  it "AGENT_PLAN_STEPS is overridable" && {
    (
      AGENT_PLAN_STEPS=8
      assert_eq "$AGENT_PLAN_STEPS" "8"
    )
    assert_ok $?
  }

  it "AGENT_INNER_LOOPS defaults to 8" && {
    assert_eq "$AGENT_INNER_LOOPS" "8"
  }

  it "AGENT_INNER_LOOPS is overridable" && {
    (
      AGENT_INNER_LOOPS=10
      assert_eq "$AGENT_INNER_LOOPS" "10"
    )
    assert_ok $?
  }

  it "agent_inner_loop body uses AGENT_INNER_LOOPS" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'AGENT_INNER_LOOPS'
    assert_ok $?
  }

  it "AGENT_MAX_RETRIES is removed (dead code)" && {
    body=$(cat "$LODGE_DIR/lib/agent.sh")
    ! echo "$body" | grep -q 'AGENT_MAX_RETRIES'
    assert_ok $?
  }

  it "agent_plan prompt mentions [SUBTASK] syntax" && {
    body=$(declare -f agent_plan)
    echo "$body" | grep -q '\[SUBTASK\]'
    assert_ok $?
  }

# ── Cascade detection ─────────────────────────────────────────
describe "Cascade detection (_agent_detect_cascade)"

  it "is defined" && {
    declare -f _agent_detect_cascade &>/dev/null
    assert_ok $?
  }

  it "detects cascade when 50%+ remaining steps share resource" && {
    _agent_detect_cascade \
      "/sandbox build mygame" \
      "/sandbox run mygame echo test" \
      "/sandbox test mygame" \
      "/save notes.md"
    assert_ok $?
  }

  it "does not cascade when steps are independent" && {
    _agent_detect_cascade \
      "/sandbox build mygame" \
      "/recall query hello" \
      "/save notes.md" \
      "/email send test@x.com Hi Hello"
    assert_fail $?
  }

  it "returns 1 if failed step has no resource name" && {
    _agent_detect_cascade \
      "Think about the problem" \
      "/sandbox build game"
    assert_fail $?
  }

  it "returns 1 with no remaining steps" && {
    _agent_detect_cascade "/sandbox build game"
    assert_fail $?
  }

  it "detects cascade at exactly 50% threshold" && {
    _agent_detect_cascade \
      "/sandbox build app" \
      "/sandbox run app make" \
      "/recall query something"
    assert_ok $?
  }

  it "does not cascade below 50%" && {
    _agent_detect_cascade \
      "/sandbox build app" \
      "/sandbox run app make" \
      "/recall query a" \
      "/save file.txt" \
      "/email send x@y.com a b"
    assert_fail $?
  }

# ── Plan validation ────────────────────────────────────────────
describe "Plan validation (_agent_validate_plan)"

  it "is defined" && {
    declare -f _agent_validate_plan &>/dev/null
    assert_ok $?
  }

  it "detects placeholder URLs (your-repo)" && {
    _agent_validate_plan \
      "/download https://github.com/your-repo/game" 2>&1 | grep -q "issue"
    assert_ok $?
  }

  it "detects placeholder (example.com)" && {
    _agent_validate_plan \
      "/download https://example.com/thing" 2>&1 | grep -q "issue"
    assert_ok $?
  }

  it "detects /save with \$(command)" && {
    _agent_validate_plan \
      '/save listing.txt $(find . -name "*.rs")' 2>&1 | grep -q "issue"
    assert_ok $?
  }

  it "detects /social post with unquoted text" && {
    _agent_validate_plan \
      "/social post Just shipped a new game" 2>&1 | grep -q "issue"
    assert_ok $?
  }

  it "accepts properly quoted /social post" && {
    out=$(_agent_validate_plan \
      '/social post "Just shipped a new game"' 2>&1)
    # Should produce no warnings
    echo "$out" | grep -qv "issue"
    assert_ok $?
  }

  it "returns 0 even with warnings (advisory only)" && {
    _agent_validate_plan \
      "/download https://github.com/your-repo/x" \
      '/save f.txt $(echo hi)' 2>/dev/null
    assert_ok $?
  }

  it "detects hallucinated commands not in registry or scripts" && {
    _agent_validate_plan \
      "/run cargo build" 2>&1 | grep -q "not a registered command"
    assert_ok $?
  }

  it "produces no warnings for clean plan" && {
    out=$(_agent_validate_plan \
      "/build release" \
      "/test all" \
      "/save output.txt hello" 2>&1)
    assert_eq "$out" ""
  }

  it "sets _AGENT_PLAN_WARNINGS" && {
    _agent_validate_plan \
      "/download https://github.com/your-repo/x" >/dev/null 2>&1
    assert_not_empty "$_AGENT_PLAN_WARNINGS"
  }

  it "clears _AGENT_PLAN_WARNINGS on clean plan" && {
    _AGENT_PLAN_WARNINGS="leftover"
    _agent_validate_plan \
      "/build release" >/dev/null 2>&1
    assert_eq "$_AGENT_PLAN_WARNINGS" ""
  }

# ── Escalation matrix in agent_inner_loop ─────────────────────
describe "Escalation matrix in agent_inner_loop"

  it "implements Level 2 forced knowledge retrieval" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'recall_search_context\|Escalation L2'
    assert_ok $?
  }

  it "implements Level 5 forced web fallback" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'web_search\|Escalation L5'
    assert_ok $?
  }

  it "implements terminal escalation with operator input" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'read -r guidance'
    assert_ok $?
  }

# ── L3 failure history recall ─────────────────────────────────
describe "L3 failure history recall"

  it "L3 reads failure log for past recovery instructions" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'L3_recovery'
    assert_ok $?
  }

  it "L3 triggers at _fail_count >= 3" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_fail_count.*-ge 3.*fail_file'
    assert_ok $?
  }

  it "L3 greps RECOVERY and OPERATOR GUIDANCE from failure log" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'RECOVERY.*OPERATOR GUIDANCE'
    assert_ok $?
  }

# ── Catalog-aware operator guided retry ───────────────────────
describe "Catalog-aware operator guided retry"

  it "guided retry injects command catalog" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'commands_catalog'
    assert_ok $?
  }

  it "guided retry extracts slash commands (not just bash)" && {
    body=$(declare -f agent_inner_loop)
    # Must handle both /command lines and ```bash blocks
    echo "$body" | grep -q 'final_is_slash'
    assert_ok $?
  }

  it "guided retry logs RECOVERY entry on success" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'RECOVERY:.*final_cmd'
    assert_ok $?
  }

  it "guided retry logs OPERATOR GUIDANCE in recovery entry" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'OPERATOR GUIDANCE:.*guidance'
    assert_ok $?
  }

  it "guided retry logs ORIGINAL FAILURE in recovery entry" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'ORIGINAL FAILURE:.*last_failed_cmd'
    assert_ok $?
  }

  it "guided retry logs failure when guided attempt also fails" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'FAILED COMMAND (guided)'
    assert_ok $?
  }

  it "guided retry uses commands_dispatch for slash commands" && {
    body=$(declare -f agent_inner_loop)
    # The guided retry section should dispatch slash commands properly
    echo "$body" | grep -q 'final_is_slash.*commands_dispatch'
    assert_ok $?
  }

# ── Soul injection in agent_run ───────────────────────────────
describe "Soul injection in dual-loop architecture"

  it "agent_run uses _memory_soul_identity for macro memory seed" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_memory_soul_identity'
    assert_ok $?
  }

  it "macro memory seed includes task start timestamp" && {
    body=$(declare -f agent_run)
    # _macro_init writes task_started field via jq with date timestamp
    echo "$body" | grep -q '_macro_init.*macro_file'
    assert_ok $?
  }

  it "micro memory includes milestone start timestamp" && {
    body=$(declare -f agent_inner_loop)
    # _micro_init writes 'started' field with timestamp
    echo "$body" | grep -q '_micro_init.*micro_file'
    assert_ok $?
  }

  it "strategist prompt includes current date/time" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_strat_now'
    assert_ok $?
    echo "$body" | grep -q 'date/time:.*_strat_now\|current date and time'
    assert_ok $?
  }

  it "milestone evaluator prompt includes current timestamp" && {
    body=$(declare -f _agent_evaluate_milestone)
    echo "$body" | grep -q 'CURRENT DATE/TIME'
    assert_ok $?
  }

  it "overall evaluator prompt includes current timestamp" && {
    body=$(declare -f _agent_evaluate_completion)
    echo "$body" | grep -q 'CURRENT DATE/TIME'
    assert_ok $?
  }

  it "router prompt includes current date/time" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_route_now'
    assert_ok $?
    echo "$body" | grep -q 'Current date/time'
    assert_ok $?
  }

  it "journal_reflect background is disowned in agent_run" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'journal_reflect.*&'
    assert_ok $?
    echo "$body" | grep -q 'disown'
    assert_ok $?
  }

  it "agent_run does NOT use head -20 for soul extraction" && {
    body=$(declare -f agent_run)
    # Old pattern was 'head -20' — should be replaced
    ! echo "$body" | grep -q 'head -20'
    assert_ok $?
  }

  it "agent_plan calls memory_build_system_prompt with plan mode" && {
    body=$(declare -f agent_plan)
    echo "$body" | grep -q '"plan"'
    assert_ok $?
  }

# ── Web Sufficiency Gate ───────────────────────────────────────
describe "Web sufficiency gate in agent_inner_loop"

  it "AGENT_WEB_SUFFICIENCY defaults to 20" && {
    assert_eq "$AGENT_WEB_SUFFICIENCY" "20"
  }

  it "inner loop body contains sufficiency gate" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_micro_sufficiency_reached'
    assert_ok $?
  }

  it "sufficiency gate checks _web_ok_count against threshold" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'AGENT_WEB_SUFFICIENCY'
    assert_ok $?
  }

  it "sufficiency gate only fires for /web commands" && {
    body=$(declare -f agent_inner_loop)
    # Must contain the conditional: cmd == /web*
    echo "$body" | grep -q '/web\*'
    assert_ok $?
  }

# ── Primary Objective Injection ────────────────────────────────
describe "Primary objective injection in inner loop"

  it "inner loop injects primary objective from macro_memory" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'primary_objective'
    assert_ok $?
  }

  it "injection reads from macro_memory via _macro_get" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_macro_get.*macro_file.*primary_objective'
    assert_ok $?
  }

  it "injection only adds objective when different from micro objective" && {
    body=$(declare -f agent_inner_loop)
    # Must compare _primary_obj != micro_objective
    echo "$body" | grep -q '_primary_obj.*!=.*micro_objective'
    assert_ok $?
  }

# ── Router Research Guidance ────────────────────────────────────
describe "Web sufficiency enforcement gate"

  it "inner loop has programmatic sufficiency enforcement" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'WEB SUFFICIENCY ENFORCEMENT\|_micro_sufficiency_reached'
    assert_ok $?
  }

  it "sufficiency gate calls _agent_complete_milestone" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_agent_complete_milestone.*micro_file.*macro_file'
    assert_ok $?
  }

  it "sufficiency INCOMPLETE injects eval reason into micro_memory" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_micro_add_note.*EVAL_FEEDBACK'
    assert_ok $? "INCOMPLETE eval reason must be injected into micro_memory for inner loop visibility"
  }

# ── Abort Propagation ─────────────────────────────────────────
describe "Abort propagation from inner loop to macro loop"

  it "abort sets _LODGE_CANCELLED flag" && {
    body=$(declare -f agent_inner_loop)
    # Must contain: guidance = abort -> _LODGE_CANCELLED=1
    echo "$body" | grep -q 'guidance.*abort'
    assert_ok $?
    echo "$body" | grep -q '_LODGE_CANCELLED=1'
    assert_ok $?
  }

  it "abort touches cancel file for subshell visibility" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'touch.*_cancel_file'
    assert_ok $?
  }

  it "abort writes ABORTED to macro_memory" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_macro_add_milestone.*ABORTED'
    assert_ok $?
  }

  it "abort returns 1 immediately without guided retry" && {
    # Verify abort block (with return 1) appears before guided retry block
    # in the source file. declare -f strips comments so we read the file.
    abort_line=$(grep -n 'Aborted by operator' "$LODGE_DIR/lib/agent.sh" | head -1 | cut -d: -f1)
    guided_line=$(grep -n 'Catalog-Aware Guided Retry' "$LODGE_DIR/lib/agent.sh" | head -1 | cut -d: -f1)
    [ -n "$abort_line" ] && [ -n "$guided_line" ] && [ "$abort_line" -lt "$guided_line" ]
    assert_ok $?
  }

# ── Milestone Deduplication ────────────────────────────────────
describe "Milestone deduplication in macro loop"

  it "AGENT_MAX_MILESTONE_RETRIES defaults to 3" && {
    assert_eq "$AGENT_MAX_MILESTONE_RETRIES" "3"
  }

  it "agent_run initializes _attempted_milestones array" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_attempted_milestones'
    assert_ok $?
  }

  it "agent_run tracks milestone outcomes (OK/FAILED) in array" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'OK|'
    assert_ok $?
    echo "$body" | grep -q 'FAILED|'
    assert_ok $?
  }

  it "strategist prompt includes 'do NOT repeat failed milestones' rule" && {
    # Check the source file directly since declare -f may mangle multi-byte
    # characters (em dashes) in string literals.
    grep -q 'no_repeat\|Do NOT regenerate' "$LODGE_DIR/lib/agent.sh"
    assert_ok $?
  }

  it "milestone history injected into strategist system prompt" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'PREVIOUSLY ATTEMPTED MILESTONES'
    assert_ok $?
  }

  it "duplicate milestones are skipped after max retries" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'Skipped (duplicate of failed milestone)'
    assert_ok $?
  }

  it "deduplication checks first 120 chars of normalized text for similarity" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_milestone_norm:0:120'
    assert_ok $?
  }

  it "deduplication extracts slash command signature" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_milestone_slash'
    assert_ok $?
    echo "$body" | grep -q '_prev_slash'
    assert_ok $?
  }

  it "exact-repeat of last milestone triggers immediate dup" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'exact repeat of last milestone'
    assert_ok $?
    echo "$body" | grep -q '_last_milestone_text'
    assert_ok $?
  }

  it "force-progression still runs overall evaluator before continue" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_agent_evaluate_completion.*macro_file.*micro_memory'
    assert_ok $?
    echo "$body" | grep -q 'Milestone skipped (repeated)'
    assert_ok $?
  }

# ── Specialist key injection ──────────────────────────────────
describe "Specialist per-command key status"

  it "_specialist_key_status is defined" && {
    declare -f _specialist_key_status &>/dev/null
    assert_ok $?
  }

  it "returns empty for commands with no keys (build)" && {
    out=$(_specialist_key_status "build" 2>/dev/null)
    assert_empty "$out"
  }

  it "returns empty for commands with no keys (test)" && {
    out=$(_specialist_key_status "test" 2>/dev/null)
    assert_empty "$out"
  }

  it "maps web command to SERPER and PERPLEXITY keys" && {
    body=$(declare -f _specialist_key_status)
    echo "$body" | grep -q 'SERPER_API_KEY'
    assert_ok $?
    echo "$body" | grep -q 'PERPLEXITY_API_KEY'
    assert_ok $?
  }

  it "maps social command to platform tokens" && {
    body=$(declare -f _specialist_key_status)
    echo "$body" | grep -q 'DISCORD_BOT_TOKEN'
    assert_ok $?
    echo "$body" | grep -q 'TELEGRAM_BOT_TOKEN'
    assert_ok $?
  }

  it "maps email command to EMAIL_PROVIDER" && {
    body=$(declare -f _specialist_key_status)
    echo "$body" | grep -q 'EMAIL_PROVIDER'
    assert_ok $?
  }

  it "specialist prompt calls _specialist_key_status" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q '_specialist_key_status'
    assert_ok $?
  }

# ── Task Completion Evaluator ──────────────────────────────────
describe "Task completion evaluator"

  it "AGENT_EVAL_MODE defaults to auto" && {
    assert_eq "$AGENT_EVAL_MODE" "auto"
  }

  it "AGENT_EVAL_MODE is overridable" && {
    (
      AGENT_EVAL_MODE=interactive
      assert_eq "$AGENT_EVAL_MODE" "interactive"
    )
    assert_ok $?
  }

  it "_agent_evaluate_completion is defined" && {
    declare -f _agent_evaluate_completion &>/dev/null
    assert_ok $?
  }

  it "_agent_evaluate_milestone is defined" && {
    declare -f _agent_evaluate_milestone &>/dev/null
    assert_ok $?
  }

  it "milestone evaluator uses pragmatic system prompt" && {
    body=$(declare -f _agent_evaluate_milestone)
    echo "$body" | grep -q 'pragmatic milestone evaluator'
    assert_ok $?
    echo "$body" | grep -q 'milestone_text'
    assert_ok $?
  }

  it "milestone evaluator accepts exit 0 as success" && {
    body=$(declare -f _agent_evaluate_milestone)
    echo "$body" | grep -q 'exit_0\|Exit code 0'
    assert_ok $?
    echo "$body" | grep -q 'COMPLETE'
    assert_ok $?
  }

  it "overall evaluator uses strategic system prompt" && {
    body=$(declare -f _agent_evaluate_completion)
    echo "$body" | grep -q 'task-completion evaluator'
    assert_ok $?
  }

  it "overall evaluator reads macro_memory file" && {
    body=$(declare -f _agent_evaluate_completion)
    echo "$body" | grep -q 'macro_file'
    assert_ok $?
    echo "$body" | grep -q 'macro_context'
    assert_ok $?
  }

  it "evaluator expects COMPLETE or INCOMPLETE verdict" && {
    body=$(declare -f _agent_evaluate_completion)
    echo "$body" | grep -q 'COMPLETE'
    assert_ok $?
    echo "$body" | grep -q 'INCOMPLETE'
    assert_ok $?
  }

  it "evaluator supports interactive mode via AGENT_EVAL_MODE" && {
    body=$(declare -f _agent_evaluate_completion)
    echo "$body" | grep -q 'AGENT_EVAL_MODE'
    assert_ok $?
    echo "$body" | grep -q 'interactive'
    assert_ok $?
  }

  it "evaluator reuses verdict reason as task summary" && {
    body=$(declare -f _agent_evaluate_completion)
    echo "$body" | grep -q '_EVAL_COMPLETE_REASON'
    assert_ok $?
  }

  it "evaluator uses LLM_SCENARIO=evaluator" && {
    body=$(declare -f _agent_evaluate_completion)
    echo "$body" | grep -q 'LLM_SCENARIO=evaluator'
    assert_ok $?
  }

  it "honeydew + overall evaluator chain in agent_run after successful milestones" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_agent_evaluate_honeydew_item'
    assert_ok $?
    echo "$body" | grep -q '_agent_evaluate_completion'
    assert_ok $?
  }

  it "evaluator feedback is threaded into strategist prompt" && {
    body=$(declare -f agent_run)
    # _last_eval_feedback variable is initialized
    echo "$body" | grep -q '_last_eval_feedback'
    assert_ok $?
    # Feedback injected at end of strategist system prompt with attention markers
    echo "$body" | grep -q 'EVALUATOR FEEDBACK'
    assert_ok $?
    # Feedback is set from honeydew evaluator and overall evaluator
    echo "$body" | grep -q 'Remaining work'
    assert_ok $?
    echo "$body" | grep -q 'NOT addressed'
    assert_ok $?
    # Feedback templates must not inject status words into strategist.
    # We check only the string-literal portion of each assignment,
    # excluding variable names like _EVAL_INCOMPLETE_REASON.
    # Extract just the quoted template text from each assignment.
    _t_feedback_templates=$(echo "$body" | grep '_last_eval_feedback="' | grep -v '_last_eval_feedback=""' | sed 's/.*_last_eval_feedback="//' | sed 's/".*//')
    ! echo "$_t_feedback_templates" | grep -qw 'DONE'
    assert_ok $? "Eval feedback templates must not contain DONE"
    ! echo "$_t_feedback_templates" | grep -qw 'SUCCESS'
    assert_ok $? "Eval feedback templates must not contain SUCCESS"
    ! echo "$_t_feedback_templates" | grep -qw 'FAILED'
    assert_ok $? "Eval feedback templates must not contain FAILED"
  }

  it "evaluator is skipped when AGENT_EVAL_MODE=disabled" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'AGENT_EVAL_MODE.*!=.*disabled'
    assert_ok $?
  }

  it "evaluator only triggers when completed_milestones > 0" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'completed_milestones.*-gt 0'
    assert_ok $?
  }

  it "LLM_EVALUATOR_TOKENS defaults to 4096" && {
    assert_eq "$LLM_EVALUATOR_TOKENS" "4096"
  }

# ── Macro memory enrichment: timestamps & command results ─────
describe "Macro memory: timestamped command results"

  it "inner loop tracks _last_success_cmd" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_last_success_cmd='
    assert_ok $?
  }

  it "inner loop tracks _last_success_snippet" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_last_success_snippet='
    assert_ok $?
  }

  it "inner loop updates _last_success_cmd on exit 0" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_last_success_cmd="\$cmd"'
    assert_ok $?
  }

  it "SUCCESS macro_memory entry uses _macro_add_milestone" && {
    body=$(declare -f _agent_complete_milestone)
    echo "$body" | grep -q '_macro_add_milestone.*macro_file.*micro_objective'
    assert_ok $?
  }

  it "SUCCESS macro_memory entry includes command" && {
    body=$(declare -f _agent_complete_milestone)
    # _macro_add_milestone receives the command as a parameter
    echo "$body" | grep -q '_macro_add_milestone.*last_success_cmd'
    assert_ok $?
  }

  it "FAILED macro_memory entry uses _macro_add_milestone" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_macro_add_milestone.*FAILED'
    assert_ok $?
  }

  it "CANCELLED macro_memory entry uses _macro_add_milestone" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_macro_add_milestone.*CANCELLED'
    assert_ok $?
  }

  it "ABORTED macro_memory entry uses _macro_add_milestone" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_macro_add_milestone.*ABORTED'
    assert_ok $?
  }

  it "guided recovery macro_memory entry includes command" && {
    body=$(declare -f agent_inner_loop)
    # _macro_add_milestone receives the command as a parameter
    echo "$body" | grep -q '_macro_add_milestone.*final_cmd'
    assert_ok $?
  }

# ── Research buffer: cross-milestone data flow ────────────────
describe "Research buffer (cross-milestone data flow)"

  it "RESEARCH_BUFFER_FILE constant is defined" && {
    [ -n "$RESEARCH_BUFFER_FILE" ]
    assert_ok $? "RESEARCH_BUFFER_FILE must be set"
  }

  it "inner loop references RESEARCH_BUFFER_FILE for write" && {
    body=$(declare -f _agent_complete_milestone)
    echo "$body" | grep -q 'RESEARCH_BUFFER_FILE'
    assert_ok $? "Must reference RESEARCH_BUFFER_FILE"
  }

  it "_micro_web_outputs returns JSON array" && {
    body=$(declare -f _micro_web_outputs)
    echo "$body" | grep -q 'jq'
    assert_ok $? "Must use jq for JSON output"
  }

  it "inner loop injects research buffer as native JSON via jq --argjson" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'jq --argjson rc'
    assert_ok $? "Must inject research buffer via jq --argjson"
  }

  it "research buffer is deleted after injection" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'rm -f.*_research_buf'
    assert_ok $? "Must delete research buffer after injection"
  }

  it "research buffer uses _micro_web_outputs to extract web data" && {
    body=$(declare -f _agent_complete_milestone)
    echo "$body" | grep -q '_micro_web_outputs'
    assert_ok $? "Must use _micro_web_outputs to extract successful /web output blocks"
  }

  it "research buffer tags with source milestone" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'source.*src'
    assert_ok $? "Must tag research context with source milestone"
  }

  it "research buffer default max_chars is 1500" && {
    body=$(declare -f _micro_web_outputs)
    echo "$body" | grep -q '1500'
    assert_ok $? "Must default max_chars to 1500"
  }

# ── Evaluator-based completion (router decoupling) ────────────
describe "Evaluator-based milestone completion"

  it "_agent_complete_milestone helper is defined" && {
    declare -f _agent_complete_milestone &>/dev/null
    assert_ok $?
  }

  it "_agent_complete_milestone writes COMPLETE to micro_memory" && {
    body=$(declare -f _agent_complete_milestone)
    echo "$body" | grep -q '_micro_set_result.*COMPLETE'
    assert_ok $? "Must write COMPLETE verdict"
  }

  it "_agent_complete_milestone summarizes micro_memory via LLM" && {
    body=$(declare -f _agent_complete_milestone)
    echo "$body" | grep -q 'llm_generate.*_ms_prompt'
    assert_ok $? "Must call llm_generate for milestone summary"
  }

  it "_agent_complete_milestone tags action class" && {
    body=$(declare -f _agent_complete_milestone)
    echo "$body" | grep -q '_action_class='
    assert_ok $? "Must tag milestone with action class"
  }

  it "_agent_complete_milestone saves research buffer for web actions" && {
    body=$(declare -f _agent_complete_milestone)
    echo "$body" | grep -q 'RESEARCH_BUFFER_FILE'
    assert_ok $? "Must save research buffer to .george dir"
  }

  it "inner loop calls _agent_evaluate_milestone after successful action" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_agent_evaluate_milestone'
    assert_ok $? "Must call evaluator after each successful action"
  }

  it "inner loop calls _agent_complete_milestone on evaluator pass" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_agent_complete_milestone'
    assert_ok $? "Must call completion helper when evaluator says COMPLETE"
  }

# ── Brainstorm buffer (cross-milestone data flow) ─────────────
describe "Brainstorm buffer (cross-milestone data flow)"

  it "BRAINSTORM_FILE constant is defined" && {
    [ -n "$BRAINSTORM_FILE" ]
    assert_ok $? "BRAINSTORM_FILE must be set"
  }

  it "brainstorm output writes JSON sidecar file on success" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'BRAINSTORM_FILE'
    assert_ok $? "Inner loop must reference BRAINSTORM_FILE"
    echo "$body" | grep -q 'jq -n.*query.*response.*timestamp'
    assert_ok $? "Must write structured JSON with query, response, timestamp"
  }

  it "brainstorm JSON is injected into micro_memory on inner loop start" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'brainstorm_context'
    assert_ok $? "Must inject brainstorm_context into micro_memory"
  }

  it "brainstorm JSON is deleted after injection into micro_memory" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'rm -f.*_bs_buf'
    assert_ok $? "Must delete brainstorm file after injection"
  }

  it "strategist prompt includes brainstorm context when file exists" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_strat_brainstorm'
    assert_ok $? "Strategist must have brainstorm injection variable"
    echo "$body" | grep -q 'BRAINSTORM OUTPUT'
    assert_ok $? "Strategist must display brainstorm output header"
  }

  it "honeydew rewriter includes brainstorm context when file exists" && {
    body=$(declare -f _agent_honeydew_rewrite)
    echo "$body" | grep -q '_rewrite_brainstorm'
    assert_ok $? "Honeydew rewriter must have brainstorm injection variable"
    echo "$body" | grep -q 'BRAINSTORM_FILE'
    assert_ok $? "Honeydew rewriter must reference BRAINSTORM_FILE"
  }

  it "brainstorm response is capped at 3000 chars in JSON file" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'output:0:3000'
    assert_ok $? "Must cap brainstorm response to 3000 chars"
  }

  it "micro_init includes brainstorm_context field" && {
    local _tmpf
    _tmpf=$(mktemp)
    _micro_init "$_tmpf" "test"
    jq -e 'has("brainstorm_context")' "$_tmpf" >/dev/null 2>&1
    assert_ok $? "micro_memory must include brainstorm_context field"
    rm -f "$_tmpf"
  }

  it "honeydew rewrite clears brainstorm_context from micro_memory" && {
    body=$(declare -f _agent_honeydew_rewrite)
    echo "$body" | grep -q 'brainstorm_context.*null'
    assert_ok $? "Honeydew rewrite must reset brainstorm_context"
  }

  it "router prompt constrains output to slash commands only" && {
    body=$(declare -f _build_router_prompt_full)
    echo "$body" | grep -q 'Output ONLY a slash command'
    assert_ok $? "Router must constrain output to slash commands only"
    # Must NOT mention DONE/SUCCESS/COMPLETE — those words contaminate attention
    ! echo "$body" | grep -q 'DONE\|SUCCESS\|COMPLETE'
    assert_ok $? "Router must not mention status words"
  }

  it "router prompt outputs only tool names" && {
    body=$(declare -f _build_router_prompt_full)
    echo "$body" | grep -q 'bare tool name'
    assert_ok $? "Router output instruction: only tool names"
  }

  it "router prompt forbids code fences in output" && {
    body=$(declare -f _build_router_prompt_full)
    echo "$body" | grep -q 'no_fences\|NEVER wrap output\|NO code fences\|code fences'
    assert_ok $? "Router must forbid backtick wrapping"
  }

  it "router prompt has plain-text preamble before JSON" && {
    body=$(declare -f _build_router_prompt_full)
    echo "$body" | grep -q 'Output ONLY the bare tool name'
    assert_ok $? "Router must have plain-text anti-backtick preamble"
  }

  it "router prompt defaults to /respond instead of /ask" && {
    body=$(declare -f _build_router_prompt)
    echo "$body" | grep -q '/respond.*DEFAULT\|DEFAULT.*respond'
    assert_ok $? "Router must default to /respond for general answers"
  }

  it "router prefers /web search for time-sensitive information" && {
    body=$(declare -f _build_router_prompt)
    echo "$body" | grep -q 'web.*time-sensitive\|weather.*dates.*scores.*events'
    assert_ok $? "Router rules must prefer /web for date-gated queries"
  }

  it "inner loop strips code fences from router output" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'sed.*```'
    assert_ok $? "Must strip code fences before tool extraction"
  }

  it "inner loop ignores hallucinated SUCCESS from router" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'Router output.*SUCCESS.*ignoring'
    assert_ok $? "Must gracefully handle hallucinated SUCCESS"
  }

# ── Web soft-failure tolerance ────────────────────────────────
describe "Web soft-failure tolerance"

  it "web soft-failure checks for prior successful /web actions" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_prior_web_ok'
    assert_ok $? "Must check for prior successful web actions"
  }

  it "web soft-failure skips escalation matrix when prior web successes exist" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'specialist_soft_fail'
    assert_ok $? "Must log as soft failure"
  }

  it "web soft-failure injects NOTE about available data" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'Use existing data\|try a different URL'
    assert_ok $? "Must nudge to use existing data"
  }

  it "web soft-failure only applies to /web commands" && {
    body=$(declare -f agent_inner_loop)
    # The soft-failure guard is inside: if [[ "$cmd" == /web* ]]
    echo "$body" | grep -q 'cmd.*== /web\*'
    assert_ok $? "Must only trigger for /web commands"
  }

  it "escalation uses _fail_count (not inner_attempts)" && {
    body=$(declare -f agent_inner_loop)
    # L1 should use _fail_count
    echo "$body" | grep -q '_fail_count.*-le 1'
    assert_ok $? "L1 must use _fail_count"
    # L2 should use _fail_count
    echo "$body" | grep -q '_fail_count.*-le 2'
    assert_ok $? "L2 must use _fail_count"
    # L5 should use _fail_count
    echo "$body" | grep -q '_fail_count.*-ge 5'
    assert_ok $? "L5 must use _fail_count"
  }

  it "_fail_count only increments on actual failures (not soft failures)" && {
    body=$(declare -f agent_inner_loop)
    # _fail_count increment must be AFTER the soft-failure check
    # (which does continue before reaching _fail_count++)
    echo "$body" | grep -q '_fail_count=$((_fail_count + 1))'
    assert_ok $? "Must increment _fail_count after soft-failure check"
  }

# ── Placeholder detection in /write ───────────────────────────
describe "Placeholder detection in /write"

  it "inner loop detects placeholder brackets in /write content" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'placeholder.*Template\|Template.*not finished'
    assert_ok $? "Must warn about template/placeholder content"
  }

  it "placeholder check only runs on /write commands" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'cmd.*== /write\*'
    assert_ok $? "Must only check /write commands"
  }

  it "placeholder check looks for common bracket patterns" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'your \|briefly \|TBD\|TODO\|placeholder'
    assert_ok $? "Must detect common placeholder patterns"
  }

# ── Richer milestone summaries ────────────────────────────────
describe "Richer milestone summaries"

  it "milestone summary prompt asks for key data from web results" && {
    body=$(declare -f _agent_complete_milestone)
    echo "$body" | grep -q 'MUST INCLUDE those specific facts'
    assert_ok $? "Must instruct summarizer to retain research data"
  }

# ── Web Output Condenser ──────────────────────────────────────
describe "Web output condenser in agent_inner_loop"

  it "has web condenser logic for /web commands" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'Web Summary'
    assert_ok $? "Must inject [Web Summary] prefix for condensed output"
  }

  it "condenser only triggers for /web commands" && {
    body=$(declare -f agent_inner_loop)
    # The condenser check should be gated on /web* and include condense_prompt
    echo "$body" | grep -q 'cmd.*==.*/web'
    assert_ok $? "Must gate condenser on /web commands"
    echo "$body" | grep -q '_condense_prompt'
    assert_ok $? "Must use _condense_prompt variable"
  }

  it "condenser only triggers for output > 300 chars" && {
    body=$(declare -f agent_inner_loop)
    # Small outputs should pass through uncondensed
    echo "$body" | grep -q '300'
    assert_ok $? "Must have minimum length threshold"
  }

  it "condenser injects task context (micro_objective)" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'micro_objective'
    assert_ok $? "Must include task objective for context-aware summarization"
  }

  it "condenser injects primary objective from macro_memory" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'primary_for_condense\|OVERALL GOAL'
    assert_ok $? "Must inject primary objective for broader context"
  }

  it "condenser instructs LLM to flag junk data" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'JUNK'
    assert_ok $? "Must instruct model to flag junk/paywall/empty content"
  }

  it "condenser uses llm_generate" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'llm_generate.*condense_prompt'
    assert_ok $? "Must use llm_generate for condense call"
  }

  it "condenser strips think blocks from output" && {
    body=$(declare -f agent_inner_loop)
    # Should clean <think> blocks from condensed output  
    echo "$body" | grep -q 'think.*_condensed\|_condensed.*think'
    assert_ok $? "Must strip thinking artifacts from summary"
  }

  it "LLM_WEB_CONDENSE_TOKENS has default of 200" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'LLM_WEB_CONDENSE_TOKENS:-200'
    assert_ok $? "Must default condense token budget to 200"
  }

# ── Honeydew list system ──────────────────────────────────────
describe "Honeydew list system"

  it "_agent_honeydew_build is defined" && {
    declare -f _agent_honeydew_build &>/dev/null
    assert_ok $?
  }

  it "_agent_honeydew_mark is defined" && {
    declare -f _agent_honeydew_mark &>/dev/null
    assert_ok $?
  }

  it "_agent_honeydew_status is defined" && {
    declare -f _agent_honeydew_status &>/dev/null
    assert_ok $?
  }

  it "_agent_honeydew_read is defined" && {
    declare -f _agent_honeydew_read &>/dev/null
    assert_ok $?
  }

  it "_agent_honeydew_auto_check is defined" && {
    declare -f _agent_honeydew_auto_check &>/dev/null
    assert_ok $?
  }

  it "honeydew_mark updates checklist items" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    jq -n '{"primary_task":"test","items":[
      {"id":1,"task":"First task","status":"pending"},
      {"id":2,"task":"Second task","status":"pending"},
      {"id":3,"task":"Third task","status":"pending"}]}' > "$_tmpdir/.george/honeydew.json"
    _agent_honeydew_mark 2 "$_tmpdir"
    _status=$(jq -r '.items[] | select(.id == 2) | .status' "$_tmpdir/.george/honeydew.json")
    assert_eq "$_status" "done" "Item 2 should be marked done"
    _status1=$(jq -r '.items[] | select(.id == 1) | .status' "$_tmpdir/.george/honeydew.json")
    assert_eq "$_status1" "pending" "Item 1 should remain pending"
    rm -rf "$_tmpdir"
  }

  it "honeydew_status reports correct counts" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    jq -n '{"primary_task":"test","items":[
      {"id":1,"task":"Done task","status":"done"},
      {"id":2,"task":"Pending task","status":"pending"},
      {"id":3,"task":"Another pending","status":"pending"}]}' > "$_tmpdir/.george/honeydew.json"
    status=$(_agent_honeydew_status "$_tmpdir")
    echo "$status" | grep -q '1/3 complete'
    assert_ok $? "Should show 1/3 complete, got: $status"
    rm -rf "$_tmpdir"
  }

  it "honeydew_status shows all-done when fully checked" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    jq -n '{"primary_task":"test","items":[
      {"id":1,"task":"Done","status":"done"},
      {"id":2,"task":"Also done","status":"done"}]}' > "$_tmpdir/.george/honeydew.json"
    status=$(_agent_honeydew_status "$_tmpdir")
    echo "$status" | grep -q 'All tasks done'
    assert_ok $? "Should report all done, got: $status"
    rm -rf "$_tmpdir"
  }

  it "honeydew_read returns file contents" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    jq -n '{"primary_task":"test","items":[{"id":1,"task":"Test item","status":"pending"}]}' > "$_tmpdir/.george/honeydew.json"
    content=$(_agent_honeydew_read "$_tmpdir")
    echo "$content" | grep -q 'primary_task'
    assert_ok $? "Should contain primary_task field"
    rm -rf "$_tmpdir"
  }

  it "honeydew_auto_check matches milestone to item by keywords" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    jq -n '{"primary_task":"test","items":[
      {"id":1,"task":"Search the web for HiBy M500 specs","status":"pending"},
      {"id":2,"task":"Write markdown report","status":"pending"},
      {"id":3,"task":"Email the report","status":"pending"}]}' > "$_tmpdir/.george/honeydew.json"
    _agent_honeydew_auto_check "Search the web for HiBy M500 specifications and pricing" "$_tmpdir"
    assert_ok $? "Should match item 1"
    _status=$(jq -r '.items[] | select(.id == 1) | .status' "$_tmpdir/.george/honeydew.json")
    assert_eq "$_status" "done" "Item 1 should be auto-checked"
    rm -rf "$_tmpdir"
  }

  it "honeydew_auto_check requires minimum 2 word overlap" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    jq -n '{"primary_task":"test","items":[
      {"id":1,"task":"Search web for HiBy specs","status":"pending"},
      {"id":2,"task":"Write report about findings","status":"pending"}]}' > "$_tmpdir/.george/honeydew.json"
    _agent_honeydew_auto_check "completely unrelated milestone about cats" "$_tmpdir" || true
    _status1=$(jq -r '.items[] | select(.id == 1) | .status' "$_tmpdir/.george/honeydew.json")
    assert_eq "$_status1" "pending" "Item 1 should remain pending with no keyword overlap"
    _status2=$(jq -r '.items[] | select(.id == 2) | .status' "$_tmpdir/.george/honeydew.json")
    assert_eq "$_status2" "pending" "Item 2 should remain pending with no keyword overlap"
    rm -rf "$_tmpdir"
  }

  it "agent_run calls _agent_honeydew_build" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_agent_honeydew_build'
    assert_ok $? "agent_run must call honeydew build"
  }

  it "agent_run evaluates honeydew items via LLM on milestone success" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_agent_evaluate_honeydew_item'
    assert_ok $? "agent_run must use honeydew evaluator"
  }

  it "overall evaluator hard-gates on honeydew completion (no LLM)" && {
    body=$(declare -f _agent_evaluate_completion)
    # When honeydew exists, P2 must check item counts deterministically
    echo "$body" | grep -q '_hd_gate_total'
    assert_ok $? "P2 must count honeydew items for hard gate"
    echo "$body" | grep -q '_hd_gate_pending'
    assert_ok $? "P2 must track pending count"
    # Hard gate returns INCOMPLETE when pending > 0, COMPLETE when pending = 0
    echo "$body" | grep -q 'still pending'
    assert_ok $? "P2 must report pending items on INCOMPLETE"
    echo "$body" | grep -q 'All.*honeydew items completed'
    assert_ok $? "P2 must confirm all-done on COMPLETE"
  }

  it "overall evaluator skips LLM call when honeydew exists" && {
    body=$(declare -f _agent_evaluate_completion)
    # The hard gate checks honeydew item counts and returns before LLM call
    echo "$body" | grep -q '_hd_gate_pending.*-gt 0'
    assert_ok $? "P2 must return 1 on pending > 0"
    echo "$body" | grep -q '_hd_gate_pending.*-eq 0'
    assert_ok $? "P2 must return 0 on pending = 0"
  }

  it "overall evaluator falls back to LLM P2 when no honeydew" && {
    body=$(declare -f _agent_evaluate_completion)
    # When no honeydew, uses primary_objective + LLM-based evaluation
    echo "$body" | grep -q 'primary_objective'
    assert_ok $? "P2 must fall back to primary_objective without honeydew"
    echo "$body" | grep -q 'task-completion evaluator'
    assert_ok $? "LLM fallback path must have task-completion system prompt"
  }

  it "overall evaluator supports interactive mode in honeydew gate" && {
    body=$(declare -f _agent_evaluate_completion)
    # Interactive mode check must exist in the hard gate path
    echo "$body" | grep -q 'AGENT_EVAL_MODE.*interactive'
    assert_ok $? "Hard gate must support interactive mode"
  }

  it "strategist rules reference honeydew list" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'honeydew\|HONEYDEW'
    assert_ok $? "Strategist must know about honeydew list"
  }

  it "strategist prompt never mentions DONE or COMPLETE" && {
    body=$(declare -f agent_run)
    # Strategist prompt construction must not contain the words DONE or COMPLETE
    # in any form that gets injected into LLM prompts (macro_prompt or macro_sys).
    # Only the evaluator should know these concepts exist.
    # Exclude code-side checks (DONE guard uses [[ == DONE* ]] which is bash, not prompt).
    _t_prompt_parts=$(echo "$body" | grep -E 'macro_prompt=|macro_sys=|STRAT_RULES_JSON' -A2)
    ! echo "$_t_prompt_parts" | grep -qi 'DONE'
    assert_ok $? "Strategist prompts must not contain the word DONE"
    ! echo "$_t_prompt_parts" | grep -qi 'COMPLETE'
    assert_ok $? "Strategist prompts must not contain the word COMPLETE"
    # Must NOT contain "done_when" rules
    ! echo "$body" | grep -q 'done_when'
    assert_ok $? "Must not have done_when rule in strategist"
  }

  it "strategist honeydew rule says FIRST not NEXT" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'FIRST \[ \] item by number'
    assert_ok $? "Honeydew injection must say FIRST not NEXT"
    echo "$body" | grep -q 'Do NOT skip items'
    assert_ok $? "Honeydew injection must forbid skipping"
  }

  it "strategist prompt places honeydew after macro_context" && {
    body=$(declare -f agent_run)
    # macro_prompt must have macro_context BEFORE _strat_honeydew
    echo "$body" | grep -q 'macro_context.*_strat_honeydew'
    assert_ok $? "macro_context must appear before honeydew list for recency bias"
  }

  it "honeydew inline splitter requires 1-2 whitespace after period" && {
    body=$(declare -f _agent_honeydew_build)
    # Splitter sed uses BRE escaping \{1,2\} — grep for the 1,2 quantifier
    # near [:space:] to verify the whitespace constraint.
    echo "$body" | tr -d '\n' | grep -q '\[:space:\].*1,2'
    assert_ok $? "Inline splitter must require 1-2 whitespace after period"
  }

  it "honeydew inline splitter limits to 1-2 digit item numbers" && {
    body=$(declare -f _agent_honeydew_build)
    echo "$body" | tr -d '\n' | grep -q '\[0-9\].*1,2.*\[:space:\]'
    assert_ok $? "Inline splitter must limit to 1-2 digit numbers"
  }

  it "honeydew parser limits to 1-2 digit item numbers" && {
    body=$(declare -f _agent_parse_numbered_items)
    echo "$body" | grep 'BASH_REMATCH' -B5 | grep -q '{1,2}'
    assert_ok $? "Line parser must limit to 1-2 digit numbers"
  }

  it "strategist rules enforce one milestone per honeydew item" && {
    grep -q 'one_action' "$LODGE_DIR/lib/agent.sh"
    assert_ok $? "Strategist must have one_action rule"
  }

  it "inner loop injects honeydew status into micro_memory" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'honeydew_progress'
    assert_ok $? "Inner loop must inject honeydew status"
  }

# ── Honeydew JSON resilience (Granite format) ─────────────────
describe "Honeydew JSON resilience"

  it "honeydew jq handles Granite string-array format" && {
    # Granite outputs: {"items":["task one","task two"]} instead of {"items":[{"task":"text"}]}
    _input='{"items":["Review 2025 Packers draft class.","Identify top QB prospects.","Analyze needs."]}'
    _result=$(echo "$_input" | jq '[.items | to_entries[] | {id: (.key + 1), task: (if (.value | type) == "string" then .value else .value.task end), status: "pending", depth: 0}]' 2>/dev/null)
    _count=$(echo "${_result:-[]}" | jq 'length' 2>/dev/null)
    _count="${_count:-0}"
    assert_eq "$_count" "3" "Should parse 3 items from string array"
  }

  it "honeydew jq still handles standard object format" && {
    # Standard grammar-enforced format: {"items":[{"task":"text"}]}
    _input='{"items":[{"task":"Review draft."},{"task":"Identify prospects."}]}'
    _result=$(echo "$_input" | jq '[.items | to_entries[] | {id: (.key + 1), task: (if (.value | type) == "string" then .value else .value.task end), status: "pending", depth: 0}]' 2>/dev/null)
    _count=$(echo "${_result:-[]}" | jq 'length' 2>/dev/null)
    _count="${_count:-0}"
    assert_eq "$_count" "2" "Should parse 2 items from object array"
  }

  it "honeydew jq extracts correct task text from string array" && {
    _input='{"items":["First task","Second task"]}'
    _result=$(echo "$_input" | jq '[.items | to_entries[] | {id: (.key + 1), task: (if (.value | type) == "string" then .value else .value.task end), status: "pending", depth: 0}]' 2>/dev/null)
    _task1=$(echo "$_result" | jq -r '.[0].task')
    assert_eq "$_task1" "First task"
    _task2=$(echo "$_result" | jq -r '.[1].task')
    assert_eq "$_task2" "Second task"
  }

  it "honeydew jq assigns sequential IDs from string array" && {
    _input='{"items":["A","B","C"]}'
    _result=$(echo "$_input" | jq '[.items | to_entries[] | {id: (.key + 1), task: (if (.value | type) == "string" then .value else .value.task end), status: "pending", depth: 0}]' 2>/dev/null)
    _id1=$(echo "$_result" | jq '.[0].id')
    _id3=$(echo "$_result" | jq '.[2].id')
    assert_eq "$_id1" "1"
    assert_eq "$_id3" "3"
  }

  it "honeydew count guard defaults to 0 on empty jq output" && {
    _items_json=""
    _count=$(echo "${_items_json:-[]}" | jq 'length' 2>/dev/null)
    _count="${_count:-0}"
    assert_eq "$_count" "0" "Empty jq output must default to 0"
  }

# ── Output-dir enforcement spacing ────────────────────────────
describe "Output-dir enforcement spacing"

  it "output-dir enforcement code calls tools_fix_ext_spacing" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'tools_fix_ext_spacing'
    assert_ok $? "Output-dir enforcement must call tools_fix_ext_spacing"
  }

  it "write syntax card includes spacing rule" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'SPACE between filepath and content'
    assert_ok $? "Write syntax card must emphasize space between filepath and content"
  }

# ── Honeydew subtask decomposition ────────────────────────────
describe "Honeydew subtask decomposition"

  it "_agent_honeydew_needs_expansion is defined" && {
    declare -f _agent_honeydew_needs_expansion &>/dev/null
    assert_ok $?
  }

  it "_agent_honeydew_expand is defined" && {
    declare -f _agent_honeydew_expand &>/dev/null
    assert_ok $?
  }

  it "_agent_honeydew_maybe_expand is defined" && {
    declare -f _agent_honeydew_maybe_expand &>/dev/null
    assert_ok $?
  }

  it "needs_expansion detects compare/contrast patterns" && {
    _agent_honeydew_needs_expansion "Compare HiBy M500 and FiiO M11 features and pricing"
    assert_ok $? "compare...and should trigger expansion"
  }

  it "needs_expansion detects 'for each' patterns" && {
    _agent_honeydew_needs_expansion "For each product, gather specs and pricing"
    assert_ok $? "'for each' should trigger expansion"
  }

  it "needs_expansion detects compound research+write patterns" && {
    _agent_honeydew_needs_expansion "Research weather data and write a summary report"
    assert_ok $? "research...and...write should trigger expansion"
  }

  it "needs_expansion detects multi-item enumerations" && {
    _agent_honeydew_needs_expansion "Gather pricing for widgets, gadgets, and sprockets from the web"
    assert_ok $? "comma-separated list with 'and' should trigger expansion"
  }

  it "needs_expansion detects long item text (>200 chars)" && {
    _long="Research the complete specifications including pricing weight dimensions battery life display technology sound quality codec support Bluetooth version storage capacity RAM operating system firmware and build quality for HiBy M500 digital audio player from multiple reputable online sources and expert review"
    _agent_honeydew_needs_expansion "$_long"
    assert_ok $? "Item >200 chars should trigger expansion"
  }

  it "needs_expansion rejects simple items" && {
    _agent_honeydew_needs_expansion "Find the weather forecast"
    _result=$?
    assert_eq "$_result" "1" "Simple item should NOT trigger expansion"
  }

  it "needs_expansion rejects short single-action items" && {
    _agent_honeydew_needs_expansion "Email the report to Bob"
    _result=$?
    assert_eq "$_result" "1" "Short single-action should NOT trigger expansion"
  }

  it "expand splices sub-items into honeydew list" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    jq -n '{"primary_task":"test","items":[
      {"id":1,"task":"Done task","status":"done","depth":0},
      {"id":2,"task":"Compare product A and product B specs and pricing","status":"pending","depth":0},
      {"id":3,"task":"Email the comparison","status":"pending","depth":0}]}' > "$_tmpdir/.george/honeydew.json"

    # Mock llm_generate to return predictable sub-items
    _orig_llm=$(declare -f llm_generate)
    llm_generate() { echo "1. Research product A specs and pricing"; echo "2. Research product B specs and pricing"; echo "3. Write comparison summary"; }
    _agent_honeydew_expand 2 "$_tmpdir" 2>/dev/null

    # Restore llm_generate
    eval "$_orig_llm"

    # Verify: original 3 items -> 1 done + 3 sub-items + 1 pending = 5 total
    _total=$(jq '.items | length' "$_tmpdir/.george/honeydew.json")
    assert_eq "$_total" "5" "Should have 5 items after expansion (1 done + 3 sub + 1 original)"

    # Sub-items should have depth=1
    _d1=$(jq '[.items[] | select(.depth == 1)] | length' "$_tmpdir/.george/honeydew.json")
    [ "$_d1" -ge 2 ]
    assert_ok $? "Sub-items should have depth=1, got $_d1 items"

    # IDs should be sequential
    _ids=$(jq '[.items[].id] | sort == [range(1; length+1)]' "$_tmpdir/.george/honeydew.json")
    assert_eq "$_ids" "true" "IDs must be sequential after splice"

    # Done item should still be first
    _first_status=$(jq -r '.items[0].status' "$_tmpdir/.george/honeydew.json")
    assert_eq "$_first_status" "done" "First item should still be done"

    # Email task should be last
    _last_task=$(jq -r '.items[-1].task' "$_tmpdir/.george/honeydew.json")
    assert_contains "$_last_task" "Email"

    rm -rf "$_tmpdir"
  }

  it "expand respects AGENT_MAX_DEPTH" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    jq -n '{"primary_task":"test","items":[
      {"id":1,"task":"Compare X and Y features and pricing","status":"pending","depth":2}]}' > "$_tmpdir/.george/honeydew.json"

    AGENT_MAX_DEPTH=2
    _agent_honeydew_expand 1 "$_tmpdir" 2>/dev/null
    _result=$?
    assert_eq "$_result" "1" "Should refuse to expand at max depth"

    # Item count should be unchanged
    _total=$(jq '.items | length' "$_tmpdir/.george/honeydew.json")
    assert_eq "$_total" "1" "Should not have expanded"

    rm -rf "$_tmpdir"
  }

  it "expand skips items that fail complexity heuristic" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    jq -n '{"primary_task":"test","items":[
      {"id":1,"task":"Find the weather","status":"pending","depth":0}]}' > "$_tmpdir/.george/honeydew.json"

    _agent_honeydew_expand 1 "$_tmpdir" 2>/dev/null
    _result=$?
    assert_eq "$_result" "1" "Simple item should not be expanded"

    _total=$(jq '.items | length' "$_tmpdir/.george/honeydew.json")
    assert_eq "$_total" "1" "Should not have expanded"

    rm -rf "$_tmpdir"
  }

  it "maybe_expand returns 1 when no honeydew file" && {
    _tmpdir=$(mktemp -d)
    _agent_honeydew_maybe_expand "$_tmpdir"
    _result=$?
    assert_eq "$_result" "1" "No honeydew file should return 1"
    rm -rf "$_tmpdir"
  }

  it "initial honeydew build sets depth=0 on items" && {
    body=$(declare -f _agent_honeydew_build)
    echo "$body" | grep -q '"depth": 0\|"depth":0'
    assert_ok $? "Initial items must have depth: 0"
  }

  it "agent_run calls _agent_honeydew_maybe_expand in macro loop" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_agent_honeydew_maybe_expand'
    assert_ok $? "Macro loop must call maybe_expand"
  }

  it "macro loop refreshes macro_memory after expansion" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'honeydew expansion\|_hd_expanded'
    assert_ok $? "Macro loop must refresh macro_memory after expansion"
  }

# ── Honeydew expansion interlocks ─────────────────────────────
describe "Honeydew expansion interlocks"

  it "AGENT_HONEYDEW_EXPAND defaults to 1 (enabled)" && {
    grep -q 'AGENT_HONEYDEW_EXPAND.*:-1' "$LODGE_DIR/lib/agent.sh"
    assert_ok $? "AGENT_HONEYDEW_EXPAND must default to 1"
  }

  it "maybe_expand returns 1 when expansion is disabled" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    jq -n '{"primary_task":"test","items":[
      {"id":1,"task":"Compare product A and product B specs and pricing","status":"pending","depth":0}]}' > "$_tmpdir/.george/honeydew.json"
    AGENT_HONEYDEW_EXPAND=0
    _agent_honeydew_maybe_expand "$_tmpdir"
    _result=$?
    assert_eq "$_result" "1" "Expansion disabled should return 1"
    _total=$(jq '.items | length' "$_tmpdir/.george/honeydew.json")
    assert_eq "$_total" "1" "List should be unchanged when expansion disabled"
    rm -rf "$_tmpdir"
  }

  it "maybe_expand has master toggle guard" && {
    body=$(declare -f _agent_honeydew_maybe_expand)
    echo "$body" | grep -q 'AGENT_HONEYDEW_EXPAND'
    assert_ok $? "maybe_expand must check AGENT_HONEYDEW_EXPAND"
  }

  it "maybe_expand has item count cap" && {
    body=$(declare -f _agent_honeydew_maybe_expand)
    echo "$body" | grep -q 'AGENT_HONEYDEW_MAX_ITEMS'
    assert_ok $? "maybe_expand must check AGENT_HONEYDEW_MAX_ITEMS"
  }

  it "maybe_expand suppresses expansion when list is at max items" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    # Create a list with 8 items (at default max)
    jq -n '{"primary_task":"test","items":[
      {"id":1,"task":"Compare stuff A and stuff B features and pricing","status":"pending","depth":0},
      {"id":2,"task":"Item two","status":"pending","depth":0},
      {"id":3,"task":"Item three","status":"pending","depth":0},
      {"id":4,"task":"Item four","status":"pending","depth":0},
      {"id":5,"task":"Item five","status":"pending","depth":0},
      {"id":6,"task":"Item six","status":"pending","depth":0},
      {"id":7,"task":"Item seven","status":"pending","depth":0},
      {"id":8,"task":"Item eight","status":"pending","depth":0}]}' > "$_tmpdir/.george/honeydew.json"
    AGENT_HONEYDEW_EXPAND=1
    AGENT_HONEYDEW_MAX_ITEMS=8
    _agent_honeydew_maybe_expand "$_tmpdir"
    _result=$?
    assert_eq "$_result" "1" "Should refuse to expand when at item cap"
    _total=$(jq '.items | length' "$_tmpdir/.george/honeydew.json")
    assert_eq "$_total" "8" "List should be unchanged"
    AGENT_HONEYDEW_EXPAND=0
    rm -rf "$_tmpdir"
  }

  it "maybe_expand has redundancy guard" && {
    body=$(declare -f _agent_honeydew_maybe_expand)
    echo "$body" | grep -q 'keyword overlap\|redundant'
    assert_ok $? "maybe_expand must have redundancy detection"
  }

  it "AGENT_MAX_DEPTH defaults to 3" && {
    grep -q 'AGENT_MAX_DEPTH.*:-3' "$LODGE_DIR/lib/agent.sh"
    assert_ok $? "AGENT_MAX_DEPTH must default to 3"
  }

  it "needs_expansion length threshold is 200 chars" && {
    # 150 chars should NOT trigger
    _medium=$(printf 'x%.0s' $(seq 1 150))
    _agent_honeydew_needs_expansion "$_medium"
    _result=$?
    assert_eq "$_result" "1" "150-char item should NOT trigger expansion"
  }

# ── L1 scrape-images fallback ────────────────────────────────
describe "L1 scrape-images to fetch fallback"

  it "L1 detects /web scrape-images and falls back to /web fetch" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'scrape-images.*fetch'
    assert_ok $? "L1 must detect scrape-images and convert to fetch"
  }

  it "L1 labels fallback as scrape-images→fetch" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'scrape-images.*fetch'
    assert_ok $? "L1 label must show fallback type"
  }

  it "L1 extracts URL from scrape-images command" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_scrape_url'
    assert_ok $? "Must extract URL into _scrape_url variable"
  }

  it "L1 constructs /web fetch command with extracted URL" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '/web fetch.*_scrape_url'
    assert_ok $? "Must build /web fetch with the URL"
  }

# ── Web flow chain examples in specialist ─────────────────────
describe "Web flow chain examples in specialist"

  it "specialist /web card includes flow chain examples" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'FLOW CHAINS'
    assert_ok $? "Must include FLOW CHAINS section"
  }

  it "specialist /web card includes scrape-images fallback guidance" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'scrape-images returns empty.*fetch'
    assert_ok $? "Must guide fallback from scrape-images to fetch"
  }

  it "specialist /web card includes research flow chain" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'research.*search.*fetch.*summarize\|Text research.*search.*fetch.*summarize'
    assert_ok $? "Must show research flow chain"
  }

  it "specialist /web card includes report flow chain" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'Report.*search.*fetch.*write'
    assert_ok $? "Must show report flow chain"
  }

  it "specialist /web card includes search_tips for concise queries" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'search_tips'
    assert_ok $? "Must include search_tips section"
    echo "$body" | grep -q '3-5 keywords MAX'
    assert_ok $? "Must limit search queries to 3-5 keywords"
    echo "$body" | grep -q 'NEVER paste entire milestone'
    assert_ok $? "Must warn against pasting milestone as query"
  }

# ── Code fence stripping & parse failure handling ─────────────
describe "Code fence stripping & parse failure handling"

  it "inner loop strips code fence lines before command extraction" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_clean_plan'
    assert_ok $? "Must use _clean_plan variable for fence-stripped output"
    echo "$body" | grep -q 'sed.*```'
    assert_ok $? "Must use sed to strip code fence lines"
  }

  it "slash extraction uses clean_plan not raw action_plan" && {
    body=$(declare -f agent_inner_loop)
    # All awk extraction paths must use _clean_plan not action_plan
    echo "$body" | grep -q 'echo.*_clean_plan.*awk'
    assert_ok $? "Slash awk must operate on _clean_plan"
  }

  it "empty cmd triggers parse_failure action in micro_memory" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'parse_failure'
    assert_ok $? "Must log parse_failure when cmd is empty"
    echo "$body" | grep -q 'could not be parsed\|Specialist output'
    assert_ok $? "Must include diagnostic message for parse failure"
  }

  it "specialist forbidden list includes code fence prohibition" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'code_block_wrapper\|code fences'
    assert_ok $? "Specialist prompt must forbid code block wrapping"
  }

  it "specialist prompt has explicit anti-backtick instruction" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'NO backticks.*NO code fences'
    assert_ok $? "Specialist prompt must have plain-text anti-backtick directive"
  }

  it "specialist cards use format_only_ex templates not concrete examples" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'format_only_ex'
    assert_ok $? "Specialist syntax cards must use format_only_ex to avoid small-model example copying"
  }

  it "specialist /ask card describes human-in-the-loop behavior" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'HUMAN.*USER\|human operator\|user.*answer'
    assert_ok $? "Specialist /ask card must describe asking the human user"
  }

  it "specialist /q card warns about staleness for time-sensitive info" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'may be stale'
    assert_ok $? "Specialist /q card must warn about potentially stale model knowledge"
  }

  it "honeydew_display function exists" && {
    declare -f _agent_honeydew_display > /dev/null 2>&1
    assert_ok $? "_agent_honeydew_display must be defined"
  }

  it "honeydew_display renders checklist from JSON" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    _hd_file="$_tmpdir/.george/honeydew.json"
    jq -n '{"primary_task":"test","items":[
      {"id":1,"task":"Alpha","status":"done"},
      {"id":2,"task":"Beta","status":"pending"}]}' > "$_hd_file"
    output=$(_agent_honeydew_display "$_hd_file" 2>&1)
    echo "$output" | grep -q '\[x\].*Alpha'
    assert_ok $? "Done item should show [x]"
    echo "$output" | grep -q '\[ \].*Beta'
    assert_ok $? "Pending item should show [ ]"
    rm -rf "$_tmpdir"
  }

# ── Honeydew auto-check with milestone summary ────────────────
describe "Honeydew auto-check uses milestone summary"

  it "AGENT_HONEYDEW_MATCH defaults to 3" && {
    assert_eq "$AGENT_HONEYDEW_MATCH" "3"
  }

  it "auto-check uses AGENT_HONEYDEW_MATCH threshold" && {
    body=$(declare -f _agent_honeydew_auto_check)
    echo "$body" | grep -q 'AGENT_HONEYDEW_MATCH'
    assert_ok $? "Must use configurable threshold variable"
  }

  it "auto-check accepts optional macro_file argument" && {
    body=$(declare -f _agent_honeydew_auto_check)
    echo "$body" | grep -q 'macro_file'
    assert_ok $? "Must accept macro_file parameter"
  }

  it "auto-check reads last milestone summary from macro_memory" && {
    body=$(declare -f _agent_honeydew_auto_check)
    echo "$body" | grep -q 'completed_milestones.*summary'
    assert_ok $? "Must read summary from macro_memory"
  }

  it "auto-check combines milestone text with summary for matching" && {
    body=$(declare -f _agent_honeydew_auto_check)
    echo "$body" | grep -q 'match_text.*_last_summary'
    assert_ok $? "Must combine milestone and summary into match_text"
  }

  it "auto-check matches slash command milestone via macro summary" && {
    # Functional test: a bare /web search milestone wouldn't match
    # "Research NFL free agency predictions" but the summary will.
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    _hd_file="$_tmpdir/.george/$HONEYDEW_FILE"
    _macro_file="$_tmpdir/.george/macro_memory.json"
    jq -n '{"primary_task":"test","items":[
      {"id":1,"task":"Research NFL free agency predictions","status":"pending"},
      {"id":2,"task":"Write summary report","status":"pending"}]}' > "$_hd_file"
    # Macro memory with a rich summary that shares keywords with honeydew item 1
    jq -n '{"primary_objective":"test","completed_milestones":[
      {"timestamp":"2026-03-05","objective":"/web search Hendrickson Ravens 2026",
       "summary":"Sporting News predicted Hendrickson joins Ravens in 2026 NFL free agency. Multiple sources confirmed predictions about contract value.",
       "command":"/web search Hendrickson Ravens 2026","action_class":"RESEARCH_ONLY","status":"OK"}]}' > "$_macro_file"
    # The milestone text alone has weak overlap with honeydew item 1
    # but the summary adds "predictions", "free", "agency" which match
    _agent_honeydew_auto_check '/web search Hendrickson Ravens 2026' "$_tmpdir" "$_macro_file"
    _rc=$?
    # Verify item 1 was marked done
    _status=$(jq -r '.items[] | select(.id == 1) .status' "$_hd_file")
    assert_eq "$_status" "done" "Honeydew item 1 should be marked done via summary matching"
    rm -rf "$_tmpdir"
  }

  it "auto-check still works without macro_file (backward compat)" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    _hd_file="$_tmpdir/.george/$HONEYDEW_FILE"
    jq -n '{"primary_task":"test","items":[
      {"id":1,"task":"Search for Hendrickson Ravens contract details","status":"pending"}]}' > "$_hd_file"
    # milestone text alone has enough keywords (hendrickson, ravens, contract, details)
    _agent_honeydew_auto_check 'Search for Hendrickson Ravens contract details' "$_tmpdir"
    _rc=$?
    _status=$(jq -r '.items[] | select(.id == 1) .status' "$_hd_file")
    assert_eq "$_status" "done" "Should match on milestone text alone when keywords overlap"
    rm -rf "$_tmpdir"
  }

  it "call site passes macro_file to honeydew evaluator" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_agent_evaluate_honeydew_item.*macro_file.*micro_memory.*milestone.*workdir'
    assert_ok $? "Must pass macro_file, micro_memory, milestone, workdir to honeydew evaluator"
  }

# ── Research→Delivery state machine ───────────────────────────
describe "Research→Delivery state machine"

  it "agent_run initializes _research_milestone_count" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_research_milestone_count=0'
    assert_ok $? "Must initialize research milestone counter"
  }

  it "agent_run tracks research milestones and resets on delivery" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_research_milestone_count=$((_research_milestone_count + 1))'
    assert_ok $? "Must increment research counter"
    # Reset to 0 happens on non-research milestones (delivery)
    # declare -f strips comments so check the source file directly
    grep -q '_research_milestone_count=0.*reset on delivery' "$LODGE_DIR/lib/agent.sh"
    assert_ok $? "Must reset counter on delivery milestone"
  }

  it "strategist prompt injects research gate after 2+ research milestones" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'RESEARCH PHASE FINISHED'
    assert_ok $? "Must inject research phase gate directive"
    echo "$body" | grep -q '_research_milestone_count.*-ge.*_research_gate_threshold'
    assert_ok $? "Must check for 2+ consecutive research milestones"
  }

  it "strategist rules do NOT have always_ok for research" && {
    body=$(declare -f agent_run)
    ! echo "$body" | grep -q '"always_ok":true'
    assert_ok $? "always_ok must be removed from strategist rules"
  }

  it "strategist rules have max_consecutive for research" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'max_consecutive.*2'
    assert_ok $? "Must set max_consecutive research limit"
  }

# ── Command-family dedup cap ──────────────────────────────────
describe "Command-family dedup cap"

  it "AGENT_MAX_CMD_FAMILY defaults to 5" && {
    assert_eq "$AGENT_MAX_CMD_FAMILY" "5"
  }

  it "deduplication implements command-family strategy" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_ms_base_cmd'
    assert_ok $? "Must extract base command for family tracking"
    echo "$body" | grep -q '_family_count'
    assert_ok $? "Must count family occurrences"
    echo "$body" | grep -q 'AGENT_MAX_CMD_FAMILY'
    assert_ok $? "Must check against family cap"
  }

  it "command-family cap triggers dup when threshold reached" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'command-family cap'
    assert_ok $? "Must log command-family cap in debug"
  }

# ── Usage/help output detection ───────────────────────────────
describe "Usage/help output detection"

  it "inner loop detects usage/help output on exit 0" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'USAGE/HELP text'
    assert_ok $? "Must warn about usage/help output"
  }

  it "usage detection checks for common patterns" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'usage:\|subcommands:\|synopsis:'
    assert_ok $? "Must check for standard usage patterns"
  }

  it "usage detection only runs on short output" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '2000'
    assert_ok $? "Must limit detection to short outputs"
  }

# ── Sandbox interlock delivery-first ordering ─────────────────
describe "Sandbox interlock delivery-first ordering"

  it "sandbox fallback checks delivery commands before research" && {
    # Read source file directly (declare -f strips comments and mangles case blocks)
    _write_line=$(grep -n '\*write\*|\*save\*|\*file\*' "$LODGE_DIR/lib/agent.sh" | head -1 | cut -d: -f1)
    _web_line=$(grep -n '\*search\*|\*web\*|\*fetch\*' "$LODGE_DIR/lib/agent.sh" | head -1 | cut -d: -f1)
    [ -n "$_write_line" ] && [ -n "$_web_line" ] && [ "$_write_line" -lt "$_web_line" ]
    assert_ok $? "Delivery commands (/write) must be checked before research (/web) in fallback"
  }

# ── Evaluator contradiction guard ────────────────────────────
describe "Evaluator contradiction guard"

  it "milestone evaluator has contradiction guard" && {
    grep -q 'Contradiction guard' "$LODGE_DIR/lib/agent.sh"
    assert_ok $?
  }

  it "contradiction guard catches 'not achieved'" && {
    body=$(declare -f _agent_evaluate_milestone)
    echo "$body" | grep -q 'not achieved'
    assert_ok $?
  }

  it "contradiction guard catches 'failed' (hard context)" && {
    body=$(declare -f _agent_evaluate_milestone)
    echo "$body" | grep -q 'fail'
    assert_ok $?
  }

  it "contradiction guard catches 'does not exist'" && {
    body=$(declare -f _agent_evaluate_milestone)
    echo "$body" | grep -q 'does not exist'
    assert_ok $?
  }

  it "contradiction guard catches 'incomplete'" && {
    body=$(declare -f _agent_evaluate_milestone)
    echo "$body" | grep -q 'incomplete'
    assert_ok $?
  }

  it "contradiction guard returns 1 on override" && {
    body=$(declare -f _agent_evaluate_milestone)
    echo "$body" | grep -q 'overrode contradictory COMPLETE'
    assert_ok $?
    echo "$body" | grep -A1 'overrode contradictory' | grep -q 'return 1'
    assert_ok $?
  }

  it "contradiction guard has dismissal filter for soft-fail words" && {
    body=$(declare -f _agent_evaluate_milestone)
    # Soft negation branch: fail* triggers only when not dismissed
    echo "$body" | grep -q '_contradiction=1'
    assert_ok $? "must set _contradiction flag"
    echo "$body" | grep -qiE 'irrelevant.*fail|fail.*irrelevant'
    assert_ok $? "must check for 'irrelevant' near fail"
    echo "$body" | grep -qiE 'but.*fail|fail.*but'
    assert_ok $? "must check for 'but' near fail"
  }

  it "contradiction guard separates hard and soft negation tiers" && {
    body=$(declare -f _agent_evaluate_milestone)
    # Hard negation sets _contradiction without dismissal check
    echo "$body" | grep -q '_contradiction=1'
    assert_ok $? "must set _contradiction flag"
    # Soft negation has a case branch for fail* with a dismissal filter
    echo "$body" | grep -q 'fail'
    assert_ok $? "must have soft fail pattern"
    echo "$body" | grep -q '_contradiction=0'
    assert_ok $? "must initialize _contradiction to 0"
  }

# ── Social context injection into strategist ──────────────────
describe "Social context injection into strategist"

  it "strategist prompt fetches social context" && {
    body=$(declare -f _agent_strategist_prompt 2>/dev/null || declare -f agent_run)
    echo "$body" | grep -q 'social_context_compact'
    assert_ok $?
  }

  it "strategist prompt injects registered social channel names" && {
    body=$(declare -f _agent_strategist_prompt 2>/dev/null || declare -f agent_run)
    echo "$body" | grep -q 'registered social channel names'
    assert_ok $?
  }

  it "specialist injects social context for /social commands" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'social_context_compact'
    assert_ok $?
    echo "$body" | grep -q 'social'
    assert_ok $?
  }

# ── Dynamic Honeydew Rewrite ──────────────────────────────────
describe "Dynamic honeydew rewrite configuration"

  it "AGENT_HONEYDEW_REWRITE defaults to 1 (enabled)" && {
    grep -q 'AGENT_HONEYDEW_REWRITE.*:-1' "$LODGE_DIR/lib/agent.sh"
    assert_ok $? "AGENT_HONEYDEW_REWRITE must default to 1"
  }

  it "AGENT_HONEYDEW_REWRITE_ROUNDS defaults to 8" && {
    grep -q 'AGENT_HONEYDEW_REWRITE_ROUNDS.*:-8' "$LODGE_DIR/lib/agent.sh"
    assert_ok $? "AGENT_HONEYDEW_REWRITE_ROUNDS must default to 8"
  }

  it "AGENT_HONEYDEW_REWRITE_CADENCE defaults to 0" && {
    grep -q 'AGENT_HONEYDEW_REWRITE_CADENCE.*:-0' "$LODGE_DIR/lib/agent.sh"
    assert_ok $? "AGENT_HONEYDEW_REWRITE_CADENCE must default to 0"
  }

describe "Dynamic honeydew rewrite function"

  it "_agent_honeydew_rewrite is defined" && {
    declare -f _agent_honeydew_rewrite &>/dev/null
    assert_ok $?
  }

  it "rewrite returns 1 when toggle is disabled" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    jq -n '{"primary_task":"test","items":[
      {"id":1,"task":"Do something","status":"pending","depth":0}]}' > "$_tmpdir/.george/honeydew.json"
    jq -n '{"primary_objective":"test","completed_milestones":[{"summary":"did a thing"}]}' > "$_tmpdir/.george/macro_memory.json"
    AGENT_HONEYDEW_REWRITE=0
    _agent_honeydew_rewrite "$_tmpdir/.george/macro_memory.json" "$_tmpdir/.george/micro_memory.json" "$_tmpdir"
    _result=$?
    assert_eq "$_result" "1" "Rewrite disabled should return 1"
    rm -rf "$_tmpdir"
  }

  it "rewrite returns 1 when rounds exhausted" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    jq -n '{"primary_task":"test","items":[
      {"id":1,"task":"Do something","status":"pending","depth":0}]}' > "$_tmpdir/.george/honeydew.json"
    jq -n '{"primary_objective":"test","completed_milestones":[{"summary":"did a thing"}]}' > "$_tmpdir/.george/macro_memory.json"
    AGENT_HONEYDEW_REWRITE=1
    AGENT_HONEYDEW_REWRITE_ROUNDS=2
    _honeydew_rewrite_rounds_used=2
    _agent_honeydew_rewrite "$_tmpdir/.george/macro_memory.json" "$_tmpdir/.george/micro_memory.json" "$_tmpdir"
    _result=$?
    assert_eq "$_result" "1" "Exhausted rounds should return 1"
    AGENT_HONEYDEW_REWRITE=0
    _honeydew_rewrite_rounds_used=0
    rm -rf "$_tmpdir"
  }

  it "rewrite returns 1 when no completed milestones exist" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    jq -n '{"primary_task":"test","items":[
      {"id":1,"task":"Do something","status":"pending","depth":0}]}' > "$_tmpdir/.george/honeydew.json"
    jq -n '{"primary_objective":"test","completed_milestones":[]}' > "$_tmpdir/.george/macro_memory.json"
    AGENT_HONEYDEW_REWRITE=1
    AGENT_HONEYDEW_REWRITE_ROUNDS=2
    _honeydew_rewrite_rounds_used=0
    _agent_honeydew_rewrite "$_tmpdir/.george/macro_memory.json" "$_tmpdir/.george/micro_memory.json" "$_tmpdir"
    _result=$?
    assert_eq "$_result" "1" "No milestones should return 1"
    AGENT_HONEYDEW_REWRITE=0
    rm -rf "$_tmpdir"
  }

  it "rewrite returns 1 when no pending items exist" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    jq -n '{"primary_task":"test","items":[
      {"id":1,"task":"Already done","status":"done","depth":0}]}' > "$_tmpdir/.george/honeydew.json"
    jq -n '{"primary_objective":"test","completed_milestones":[{"summary":"did a thing"}]}' > "$_tmpdir/.george/macro_memory.json"
    AGENT_HONEYDEW_REWRITE=1
    AGENT_HONEYDEW_REWRITE_ROUNDS=2
    _honeydew_rewrite_rounds_used=0
    _agent_honeydew_rewrite "$_tmpdir/.george/macro_memory.json" "$_tmpdir/.george/micro_memory.json" "$_tmpdir"
    _result=$?
    assert_eq "$_result" "1" "No pending items should return 1"
    AGENT_HONEYDEW_REWRITE=0
    rm -rf "$_tmpdir"
  }

  it "rewrite has toggle guard" && {
    body=$(declare -f _agent_honeydew_rewrite)
    echo "$body" | grep -q 'AGENT_HONEYDEW_REWRITE'
    assert_ok $? "rewrite must check AGENT_HONEYDEW_REWRITE toggle"
  }

  it "rewrite has rounds guard" && {
    body=$(declare -f _agent_honeydew_rewrite)
    echo "$body" | grep -q 'AGENT_HONEYDEW_REWRITE_ROUNDS'
    assert_ok $? "rewrite must check AGENT_HONEYDEW_REWRITE_ROUNDS"
  }

  it "rewrite has rounds-used counter check" && {
    body=$(declare -f _agent_honeydew_rewrite)
    echo "$body" | grep -q '_honeydew_rewrite_rounds_used'
    assert_ok $? "rewrite must track rounds used"
  }

  it "rewrite preserves completed items during splice" && {
    body=$(declare -f _agent_honeydew_rewrite)
    echo "$body" | grep -q 'select(.status == "done")'
    assert_ok $? "rewrite must preserve done items"
  }

  it "rewrite increments rounds counter" && {
    body=$(declare -f _agent_honeydew_rewrite)
    echo "$body" | grep -q '_honeydew_rewrite_rounds_used=$(('
    assert_ok $? "rewrite must increment rounds counter"
  }

describe "Dynamic honeydew rewrite integration"

  it "agent_run initializes _honeydew_rewrite_rounds_used counter" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_honeydew_rewrite_rounds_used=0'
    assert_ok $? "agent_run must initialize rewrite rounds counter"
  }

  it "agent_run calls _agent_honeydew_rewrite before expand" && {
    body=$(declare -f agent_run)
    # Verify rewrite is called and comes before expand
    _rewrite_line=$(echo "$body" | grep -n '_agent_honeydew_rewrite' | head -1 | cut -d: -f1)
    _expand_line=$(echo "$body" | grep -n '_agent_honeydew_maybe_expand' | head -1 | cut -d: -f1)
    [ -n "$_rewrite_line" ] && [ -n "$_expand_line" ]
    assert_ok $? "Both rewrite and expand must be called in agent_run"
    [ "$_rewrite_line" -lt "$_expand_line" ]
    assert_ok $? "Rewrite must be called BEFORE expand"
  }

  it "agent_run refreshes macro_memory after rewrite" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'macro_memory refreshed after honeydew rewrite'
    assert_ok $? "agent_run must refresh macro_memory after rewrite"
  }

  it "agent_run initializes _honeydew_rewrite_last_ms cadence watermark" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_honeydew_rewrite_last_ms=0'
    assert_ok $? "agent_run must initialize cadence watermark"
  }

  it "rewrite has cadence guard checking AGENT_HONEYDEW_REWRITE_CADENCE" && {
    body=$(declare -f _agent_honeydew_rewrite)
    echo "$body" | grep -q 'AGENT_HONEYDEW_REWRITE_CADENCE'
    assert_ok $? "rewrite must check AGENT_HONEYDEW_REWRITE_CADENCE"
  }

  it "rewrite cadence gate is bypassed when force_rewrite=1" && {
    body=$(declare -f _agent_honeydew_rewrite)
    echo "$body" | grep -q 'force_rewrite.*-ne 1'
    assert_ok $? "cadence gate must skip when force_rewrite is active"
  }

  it "rewrite updates _honeydew_rewrite_last_ms after successful rewrite" && {
    body=$(declare -f _agent_honeydew_rewrite)
    echo "$body" | grep -q '_honeydew_rewrite_last_ms='
    assert_ok $? "rewrite must update cadence watermark"
  }

# ── Web Search Tight Parsing ──────────────────────────────────
describe "Web search tight-parsing configuration"

  it "AGENT_WEB_SEARCH_TIGHT_PARSING defaults to 0 (loose)" && {
    assert_eq "${AGENT_WEB_SEARCH_TIGHT_PARSING:-0}" "0"
  }

  it "AGENT_WEB_SEARCH_MAX_LENGTH defaults to 160" && {
    assert_eq "${AGENT_WEB_SEARCH_MAX_LENGTH:-160}" "160"
  }

  it "AGENT_WEB_SEARCH_MAX_OPERATORS defaults to 3" && {
    assert_eq "${AGENT_WEB_SEARCH_MAX_OPERATORS:-3}" "3"
  }

  it "AGENT_WEB_SEARCH_CONSEC_MAX defaults to 2" && {
    assert_eq "${AGENT_WEB_SEARCH_CONSEC_MAX:-2}" "2"
  }

  it "agent.sh config section declares AGENT_WEB_SEARCH_TIGHT_PARSING" && {
    grep -q 'AGENT_WEB_SEARCH_TIGHT_PARSING' "$LODGE_DIR/lib/agent.sh"
    assert_ok $?
  }

  it "agent.sh config section declares AGENT_WEB_SEARCH_MAX_LENGTH" && {
    grep -q 'AGENT_WEB_SEARCH_MAX_LENGTH' "$LODGE_DIR/lib/agent.sh"
    assert_ok $?
  }

  it "agent.sh config section declares AGENT_WEB_SEARCH_MAX_OPERATORS" && {
    grep -q 'AGENT_WEB_SEARCH_MAX_OPERATORS' "$LODGE_DIR/lib/agent.sh"
    assert_ok $?
  }

describe "Web search query cleaner dual-mode"

  it "inner loop contains tight-parsing conditional" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'AGENT_WEB_SEARCH_TIGHT_PARSING'
    assert_ok $? "Inner loop must branch on AGENT_WEB_SEARCH_TIGHT_PARSING"
  }

  it "loose mode preserves quotes for /web search" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_skip_quote_strip'
    assert_ok $? "Quote normalization must skip stripping for /web search in loose mode"
  }

  it "loose mode caps operators at AGENT_WEB_SEARCH_MAX_OPERATORS" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'AGENT_WEB_SEARCH_MAX_OPERATORS'
    assert_ok $? "Loose mode must reference operator cap variable"
  }

  it "loose mode applies AGENT_WEB_SEARCH_MAX_LENGTH character cap" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'AGENT_WEB_SEARCH_MAX_LENGTH'
    assert_ok $? "Loose mode must reference max length variable"
  }

  it "tight mode strips stopwords and caps at 8 words" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'i<=8'
    assert_ok $? "Tight mode must cap at 8 words"
  }

# ── AGENT_OUTPUT_DIR enforcement ──────────────────────────────
describe "AGENT_OUTPUT_DIR enforcement"

  it "AGENT_OUTPUT_DIR defaults to responses" && {
    assert_eq "$AGENT_OUTPUT_DIR" "responses"
  }

  it "agent_inner_loop references AGENT_OUTPUT_DIR" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'AGENT_OUTPUT_DIR'
    assert_ok $? "Inner loop must reference AGENT_OUTPUT_DIR"
  }

  it "output dir enforcement matches /write, /save, /append" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '/write.*| /save.*| /append'
    assert_ok $? "Must match /write, /save, and /append commands"
  }

  it "output dir enforcement skips already-prefixed paths" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'AGENT_OUTPUT_DIR.*/'
    assert_ok $? "Must check if path already starts with output dir"
  }

# ── Fuzzy keyword catalog matching ────────────────────────────
describe "Fuzzy keyword catalog matching (_agent_fuzzy_catalog_match)"

  it "AGENT_SMART_ROUTE defaults to 3 (combined)" && {
    assert_eq "$AGENT_SMART_ROUTE" "3"
  }

  it "function is defined" && {
    declare -f _agent_fuzzy_catalog_match &>/dev/null
    assert_ok $?
  }

  # ── GitHub / Git keywords (unified → git) ─────────────────
  it "matches 'github' keyword → git" && {
    result=$(_agent_fuzzy_catalog_match "Search for a github repo" "web")
    assert_contains "$result" "git"
  }

  it "matches 'pull request' keyword → git" && {
    result=$(_agent_fuzzy_catalog_match "Check the pull request status" "web")
    assert_contains "$result" "git"
  }

  it "matches 'git repo' keyword → git" && {
    result=$(_agent_fuzzy_catalog_match "Find a git repo for ML models" "web")
    assert_contains "$result" "git"
  }

  it "skips github when already routed to github" && {
    result=$(_agent_fuzzy_catalog_match "Search github repos" "github")
    assert_eq "$result" ""
  }

  it "skips github when already routed to git" && {
    result=$(_agent_fuzzy_catalog_match "Find a github project" "git")
    assert_eq "$result" ""
  }

  # ── Social keywords ───────────────────────────────────────
  it "matches 'discord' keyword → social" && {
    result=$(_agent_fuzzy_catalog_match "Post this to discord general" "write")
    assert_contains "$result" "social"
  }

  it "matches 'telegram' keyword → social" && {
    result=$(_agent_fuzzy_catalog_match "Send update via telegram" "web")
    assert_contains "$result" "social"
  }

  it "matches 'tweet' keyword → social" && {
    result=$(_agent_fuzzy_catalog_match "Tweet about the new release" "write")
    assert_contains "$result" "social"
  }

  it "matches 'post to' keyword → social" && {
    result=$(_agent_fuzzy_catalog_match "Post to the announcements channel" "web")
    assert_contains "$result" "social"
  }

  it "skips social when already routed to social" && {
    result=$(_agent_fuzzy_catalog_match "Post to discord general" "social")
    assert_eq "$result" ""
  }

  # ── Email keywords ────────────────────────────────────────
  it "matches 'email' keyword → email" && {
    result=$(_agent_fuzzy_catalog_match "Send an email to the team" "web")
    assert_contains "$result" "email"
  }

  it "matches 'gmail' keyword → email" && {
    result=$(_agent_fuzzy_catalog_match "Check gmail inbox for replies" "web")
    assert_contains "$result" "email"
  }

  it "matches email address pattern → email" && {
    result=$(_agent_fuzzy_catalog_match "Send the report to bob@corp.com" "write")
    assert_contains "$result" "email"
  }

  it "does NOT false-positive email on Discord @mention" && {
    result=$(_agent_fuzzy_catalog_match "send the text file to @babadoo on discord" "write")
    assert_not_contains "$result" "email"
    assert_contains "$result" "social"
  }

  it "skips email when already routed to email" && {
    result=$(_agent_fuzzy_catalog_match "Email the report" "email")
    assert_eq "$result" ""
  }

  # ── No match cases ────────────────────────────────────────
  it "returns empty for generic write task" && {
    result=$(_agent_fuzzy_catalog_match "Write a summary of findings" "write")
    assert_eq "$result" ""
  }

  it "returns empty for plain web search" && {
    result=$(_agent_fuzzy_catalog_match "Search for Python tutorials" "web")
    assert_eq "$result" ""
  }

  # ── Other domain keywords ─────────────────────────────────
  it "matches 'journal' keyword → journal" && {
    result=$(_agent_fuzzy_catalog_match "Write a daily log entry" "write")
    assert_contains "$result" "journal"
  }

  it "matches 'pgp' keyword → pgp" && {
    result=$(_agent_fuzzy_catalog_match "Encrypt the file with pgp" "write")
    assert_contains "$result" "pgp"
  }

  it "matches 'docker' keyword → container sandbox" && {
    result=$(_agent_fuzzy_catalog_match "Run this in a docker container" "web")
    assert_contains "$result" "container"
  }

  it "matches 'wallet' keyword → wallet" && {
    result=$(_agent_fuzzy_catalog_match "Check bitcoin wallet balance" "web")
    assert_contains "$result" "wallet"
  }

  it "matches 'screenshot' keyword → vision" && {
    result=$(_agent_fuzzy_catalog_match "Analyze the screenshot of the error" "web")
    assert_contains "$result" "vision"
  }

  it "matches 'phone' keyword → phone" && {
    result=$(_agent_fuzzy_catalog_match "Check the phone battery level" "web")
    assert_contains "$result" "phone"
  }

  it "matches 'backup' keyword → backup" && {
    result=$(_agent_fuzzy_catalog_match "Backup the project files" "write")
    assert_contains "$result" "backup"
  }

  # ── Agent inner loop integration ──────────────────────────
  it "inner loop references _agent_fuzzy_catalog_match" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_agent_fuzzy_catalog_match'
    assert_ok $? "Inner loop must call fuzzy catalog matcher"
  }

  it "inner loop gates fuzzy injection on AGENT_SMART_ROUTE >= 2" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_sr_mode.*-ge 2'
    assert_ok $? "Must gate on mode >= 2"
  }

  it "mode 2 replaces primary catalog with fuzzy match" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_sr_mode.*-eq 2'
    assert_ok $? "Must have mode 2 logic for replacement"
  }

  it "mode 3 appends fuzzy catalogs alongside primary" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'ALSO CONSIDER'
    assert_ok $? "Mode 3 must inject 'ALSO CONSIDER' phrasing"
  }

# ── Verdict parsing (quote stripping) ─────────────────────────
# Small models (4B) echo back JSON schema with the verdict keyword
# wrapped in double quotes, e.g. '"SATISFIED"' instead of 'SATISFIED'.
# The verdict parser must strip these quotes to avoid false negatives.
describe "Verdict parsing strips quotes from small model output"

  it "strips double quotes from SATISFIED verdict" && {
    _verdict='"SATISFIED", "scope":"test"'
    _word=$(echo "$_verdict" | head -1 | awk -F'[: \t]' '{print $1}' | sed "s/^[*_\"\\x27]\\+//;s/[*_.,\"\\x27]\\+$//")
    assert_eq "$_word" "SATISFIED"
  }

  it "strips double quotes from UNSATISFIED verdict" && {
    _verdict='"UNSATISFIED": reason here'
    _word=$(echo "$_verdict" | head -1 | awk -F'[: \t]' '{print $1}' | sed "s/^[*_\"\\x27]\\+//;s/[*_.,\"\\x27]\\+$//")
    assert_eq "$_word" "UNSATISFIED"
  }

  it "strips double quotes from COMPLETE verdict (P1)" && {
    _verdict='"COMPLETE": milestone done'
    _word=$(echo "$_verdict" | head -1 | awk '{print $1}' | sed "s/^[*_\"\\x27]\\+//;s/[*_:.,\"\\x27]\\+$//")
    assert_eq "$_word" "COMPLETE"
  }

  it "strips double quotes from INCOMPLETE verdict (P1)" && {
    _verdict='"INCOMPLETE": not done'
    _word=$(echo "$_verdict" | head -1 | awk '{print $1}' | sed "s/^[*_\"\\x27]\\+//;s/[*_:.,\"\\x27]\\+$//")
    assert_eq "$_word" "INCOMPLETE"
  }

  it "still works with unquoted SATISFIED (normal case)" && {
    _verdict='SATISFIED: looks good'
    _word=$(echo "$_verdict" | head -1 | awk -F'[: \t]' '{print $1}' | sed "s/^[*_\"\\x27]\\+//;s/[*_.,\"\\x27]\\+$//")
    assert_eq "$_word" "SATISFIED"
  }

  it "handles markdown bold wrapped verdict" && {
    _verdict='**SATISFIED**: content matched'
    _word=$(echo "$_verdict" | head -1 | awk -F'[: \t]' '{print $1}' | sed "s/^[*_\"\\x27]\\+//;s/[*_.,\"\\x27]\\+$//")
    assert_eq "$_word" "SATISFIED"
  }

  it "handles single-quoted verdict from small models" && {
    _verdict="'SATISFIED': it worked"
    _word=$(echo "$_verdict" | head -1 | awk -F'[: \t]' '{print $1}' | sed "s/^[*_\"\\x27]\\+//;s/[*_.,\"\\x27]\\+$//")
    assert_eq "$_word" "SATISFIED"
  }

# ── Fast Route: keyword filter ─────────────────────────────────
describe "Fast route keyword filter"

  it "_fast_route is defined" && {
    declare -f _fast_route &>/dev/null
    assert_ok $?
  }

  it "AGENT_FAST_ROUTE defaults to 1 (enabled)" && {
    assert_eq "$AGENT_FAST_ROUTE" "1"
  }

  it "AGENT_FAST_ROUTE is overridable" && {
    (
      AGENT_FAST_ROUTE=0
      assert_eq "$AGENT_FAST_ROUTE" "0"
    )
    assert_ok $?
  }

  it "routes 'search github repo' to git" && {
    result=$(_fast_route "Use /github search to find the blue-lodge-public repo")
    assert_eq "$result" "git"
  }

  it "routes 'post to discord general channel' to social" && {
    result=$(_fast_route "Post a summary to the general channel in discord")
    assert_eq "$result" "social"
  }

  it "routes 'send email to bob' to email" && {
    result=$(_fast_route "Send email to bob@example.com with the report")
    assert_eq "$result" "email"
  }

  it "routes 'check inbox' to email" && {
    result=$(_fast_route "Check email inbox for new messages")
    assert_eq "$result" "email"
  }

  it "routes 'encrypt with pgp' to pgp" && {
    result=$(_fast_route "PGP sign the release file")
    assert_eq "$result" "pgp"
  }

  it "routes 'phone status' to phone" && {
    result=$(_fast_route "Check phone status and battery level")
    assert_eq "$result" "phone"
  }

  it "routes 'analyze image' to vision" && {
    result=$(_fast_route "Analyze image at /tmp/screenshot.png")
    assert_eq "$result" "vision"
  }

  it "routes 'journal write' to journal" && {
    result=$(_fast_route "Write a journal entry about today")
    assert_eq "$result" "journal"
  }

  it "routes 'docker container' to container" && {
    result=$(_fast_route "Start a Docker container with alpine")
    assert_eq "$result" "container"
  }

  it "routes 'sandbox test' to sandbox" && {
    result=$(_fast_route "Run the code in a sandbox environment")
    assert_eq "$result" "sandbox"
  }

  it "routes 'bitcoin wallet' to wallet" && {
    result=$(_fast_route "Check bitcoin wallet balance")
    assert_eq "$result" "wallet"
  }

  it "routes 'backup files' to backup" && {
    result=$(_fast_route "Backup the project files")
    assert_eq "$result" "backup"
  }

  it "routes 'system status' to vitals" && {
    result=$(_fast_route "Check system dashboard for disk space")
    assert_eq "$result" "vitals"
  }

  it "routes 'mqtt publish' to mqtt" && {
    result=$(_fast_route "MQTT publish to sensor topic")
    assert_eq "$result" "mqtt"
  }

  it "routes 'git clone' to git" && {
    result=$(_fast_route "Git clone the project from remote")
    assert_eq "$result" "git"
  }

  it "routes 'commit changes' to git" && {
    result=$(_fast_route "Commit changes to the repo")
    assert_eq "$result" "git"
  }

  it "routes 'push changes' to git" && {
    result=$(_fast_route "Push changes to the remote")
    assert_eq "$result" "git"
  }

  it "routes 'ssh key setup' to git" && {
    result=$(_fast_route "Set up SSH key for git remote")
    assert_eq "$result" "git"
  }

  it "routes 'recall knowledge' to recall" && {
    result=$(_fast_route "Recall from the knowledge base about preferences")
    assert_eq "$result" "recall"
  }

  it "routes 'secret vault' to secret" && {
    result=$(_fast_route "Retrieve api key from the secret vault")
    assert_eq "$result" "secret"
  }

  it "returns failure for ambiguous task (falls through to LLM)" && {
    _fast_route "write a summary of the project"
    assert_fail $? "ambiguous tasks must fall through to LLM router"
  }

  it "returns failure for 'what is the weather'" && {
    _fast_route "what is the weather in New York"
    assert_fail $? "weather queries should fall through to LLM (/web)"
  }

  it "returns failure for 'read the README'" && {
    _fast_route "read the README file"
    assert_fail $? "/read should fall through to LLM"
  }

  it "returns failure for 'fix the build errors'" && {
    _fast_route "fix the build errors"
    assert_fail $? "/fix should fall through to LLM"
  }

  it "returns failure for 'create a custom script'" && {
    _fast_route "create a custom script for deployment"
    assert_fail $? "/slash should fall through to LLM"
  }

  it "routes case-insensitively" && {
    result=$(_fast_route "Search GITHUB for the repo")
    assert_eq "$result" "git"
  }

  it "routes 'google drive' to gsuite" && {
    result=$(_fast_route "Upload to Google Drive")
    assert_eq "$result" "gsuite"
  }

  it "routes 'smart home sensor' to mqtt" && {
    result=$(_fast_route "Check smart home sensor data")
    assert_eq "$result" "mqtt"
  }

  it "routes 'pull request' to git" && {
    result=$(_fast_route "Create a pull request for this branch")
    assert_eq "$result" "git"
  }

  it "routes 'repository' to git" && {
    result=$(_fast_route "List all repositories in the org")
    assert_eq "$result" "git"
  }

  it "routes 'repo' to git" && {
    result=$(_fast_route "Clone the repo locally")
    assert_eq "$result" "git"
  }

  it "routes 'telegram message' to social" && {
    result=$(_fast_route "Send a message via telegram")
    assert_eq "$result" "social"
  }

  it "routes '/post something' to social" && {
    result=$(_fast_route "/post the update to the general channel")
    assert_eq "$result" "social"
  }

  it "routes 'post to channel' to social" && {
    result=$(_fast_route "post the summary to channel general")
    assert_eq "$result" "social"
  }

  it "routes 'post to general' to social" && {
    result=$(_fast_route "post to general the latest news")
    assert_eq "$result" "social"
  }

# ── Routing pipeline fixes ────────────────────────────────────
describe "Pre-route decoupling"

  it "pre-route works when smart-route is 0" && {
    AGENT_SMART_ROUTE=0
    AGENT_PRE_ROUTE=1
    assert_eq "${AGENT_PRE_ROUTE}" "1" "pre-route must be independent of smart-route"
  }

  it "pre-route can be disabled independently of smart-route" && {
    AGENT_SMART_ROUTE=2
    AGENT_PRE_ROUTE=0
    assert_eq "${AGENT_PRE_ROUTE}" "0" "pre-route disabled while smart-route=2"
    assert_eq "${AGENT_SMART_ROUTE}" "2" "smart-route remains active"
    AGENT_PRE_ROUTE=1
  }

describe "AGENT_ROUTING presets"

  it "routing preset 0 disables all routing shortcuts" && {
    AGENT_ROUTING=0
    _agent_routing_apply
    assert_eq "${AGENT_PRE_ROUTE}" "0"
    assert_eq "${AGENT_FAST_ROUTE}" "0"
    assert_eq "${AGENT_SMART_ROUTE}" "0"
    AGENT_ROUTING=""
  }

  it "routing preset 1 enables standard routing" && {
    AGENT_ROUTING=1
    _agent_routing_apply
    assert_eq "${AGENT_PRE_ROUTE}" "1"
    assert_eq "${AGENT_FAST_ROUTE}" "1"
    assert_eq "${AGENT_SMART_ROUTE}" "1"
    AGENT_ROUTING=""
  }

  it "routing preset 2 uses full-llm (no fast-route)" && {
    AGENT_ROUTING=2
    _agent_routing_apply
    assert_eq "${AGENT_PRE_ROUTE}" "1"
    assert_eq "${AGENT_FAST_ROUTE}" "0"
    assert_eq "${AGENT_SMART_ROUTE}" "1"
    AGENT_ROUTING=""
  }

  it "routing preset 3 enables enhanced routing" && {
    AGENT_ROUTING=3
    _agent_routing_apply
    assert_eq "${AGENT_PRE_ROUTE}" "1"
    assert_eq "${AGENT_FAST_ROUTE}" "1"
    assert_eq "${AGENT_SMART_ROUTE}" "3"
    AGENT_ROUTING=""
  }

  it "empty AGENT_ROUTING does not change settings" && {
    AGENT_PRE_ROUTE=1
    AGENT_FAST_ROUTE=1
    AGENT_SMART_ROUTE=2
    AGENT_ROUTING=""
    _agent_routing_apply
    assert_eq "${AGENT_PRE_ROUTE}" "1"
    assert_eq "${AGENT_FAST_ROUTE}" "1"
    assert_eq "${AGENT_SMART_ROUTE}" "2"
  }

describe "Fast-route pattern narrowing"

  it "routes 'synthesize findings into journal' to journal not recall" && {
    result=$(_fast_route "synthesize findings into journal entry")
    assert_eq "$result" "journal"
  }

  it "routes 'write journal entry about themes' to journal" && {
    result=$(_fast_route "write journal entry about key themes")
    assert_eq "$result" "journal"
  }

  it "routes 'capture insights in daily review' to journal" && {
    result=$(_fast_route "capture insights from the daily review")
    assert_eq "$result" "journal"
  }

  it "does not route 'based on your previous research' to recall" && {
    result=$(_fast_route "based on your previous research, write a summary")
    assert_neq "$result" "recall" "broad phrases must not steal routes to recall"
  }

  it "does not route 'from your earlier analysis' to recall" && {
    result=$(_fast_route "from your earlier analysis, compile notes")
    assert_neq "$result" "recall" "broad phrases must not steal routes to recall"
  }

  it "still routes 'search knowledge base' to recall" && {
    result=$(_fast_route "search knowledge base for prior findings")
    assert_eq "$result" "recall"
  }

  it "still routes 'recall search' to recall" && {
    result=$(_fast_route "recall search for deployment notes")
    assert_eq "$result" "recall"
  }

describe "Lean router /journal entry"

  it "lean router prompt includes /journal" && {
    AGENT_FAST_ROUTE=1
    prompt=$(_build_router_prompt)
    echo "$prompt" | grep -q '/journal'
    assert_ok $? "lean router prompt must include /journal"
    AGENT_FAST_ROUTE=1
  }

  it "lean router /journal mentions journal entries" && {
    AGENT_FAST_ROUTE=1
    prompt=$(_build_router_prompt)
    echo "$prompt" | grep '/journal' | grep -qi 'journal entries'
    assert_ok $? "lean router /journal line must mention journal entries"
    AGENT_FAST_ROUTE=1
  }

# ── Git/GitHub unification ────────────────────────────────────
describe "Git/GitHub unification"

  it "specialist /git card includes fetch subcommand" && {
    card=$(_build_specialist_prompt "git" "fetch readme" "")
    echo "$card" | grep -q '"fetch"'
    assert_ok $? "/git specialist card must include fetch subcommand"
  }

  it "specialist /git card includes workflow hint" && {
    card=$(_build_specialist_prompt "git" "search and scrape" "")
    echo "$card" | grep -q '"workflow"'
    assert_ok $? "/git specialist card must include workflow JSON"
  }

  it "full router prompt references /git not /github" && {
    AGENT_FAST_ROUTE=0
    prompt=$(_build_router_prompt)
    echo "$prompt" | grep -q '/git '
    assert_ok $? "full router prompt must reference /git"
    echo "$prompt" | grep -q '/github search'
    assert_fail $? "full router prompt must NOT reference /github search (use /git search)"
    AGENT_FAST_ROUTE=1
  }

  it "full router prompt GIT section includes fetch" && {
    AGENT_FAST_ROUTE=0
    prompt=$(_build_router_prompt)
    echo "$prompt" | grep -q '/git fetch'
    assert_ok $? "full router prompt GIT section must include /git fetch"
    AGENT_FAST_ROUTE=1
  }

  it "full router prompt mentions post routes to social" && {
    AGENT_FAST_ROUTE=0
    prompt=$(_build_router_prompt)
    echo "$prompt" | grep -qi 'post.*social\|/post.*social'
    assert_ok $? "full router prompt must mention /post routes to /social"
    AGENT_FAST_ROUTE=1
  }

  it "specialist TOOLS list omits /github and /clone as separate entries" && {
    body=$(declare -f _build_specialist_prompt)
    tools_line=$(echo "$body" | grep '_tools_list=')
    echo "$tools_line" | grep -q '/github '
    assert_fail $? "specialist TOOLS list must NOT list /github separately"
    echo "$tools_line" | grep -q '/clone'
    assert_fail $? "specialist TOOLS list must NOT list /clone separately"
  }

  it "specialist TOOLS list includes /git" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q '_tools_list="/git '
    assert_ok $? "specialist TOOLS list must include /git"
  }

  it "MCP dispatch aliases github_* to git_*" && {
    grep -q '_alias_compound="git_' "$LODGE_DIR/lib/mcp.sh"
    assert_ok $? "MCP dispatch must alias github compound commands to git"
  }

  it "_specialist_key_status handles both github and git" && {
    body=$(declare -f _specialist_key_status)
    echo "$body" | grep -q 'github.*git'
    assert_ok $? "_specialist_key_status must match both github and git"
  }

# ── Fast Route + Lean Router integration ──────────────────────
describe "Fast route + lean router integration"

  it "agent_run uses _cached_router_sys for prompt caching" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_cached_router_sys'
    assert_ok $? "agent_run must cache router prompt at task init"
  }

  it "agent_inner_loop uses _fast_route before LLM router" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_fast_route'
    assert_ok $? "agent_inner_loop must call _fast_route before LLM router"
  }

  it "agent_inner_loop uses cached router sys" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_cached_router_sys'
    assert_ok $? "agent_inner_loop must use cached router sys instead of rebuilding"
  }

  it "lean router prompt is smaller than full prompt" && {
    AGENT_FAST_ROUTE=1
    lean_size=$(_build_router_prompt | wc -c)
    AGENT_FAST_ROUTE=0
    full_size=$(_build_router_prompt | wc -c)
    AGENT_FAST_ROUTE=1
    [ "$lean_size" -lt "$full_size" ]
    assert_ok $? "lean prompt ($lean_size chars) must be smaller than full ($full_size chars)"
  }

  it "lean router prompt contains /web" && {
    AGENT_FAST_ROUTE=1
    prompt=$(_build_router_prompt)
    echo "$prompt" | grep -q '/web'
    assert_ok $? "lean prompt must include /web (ambiguous command)"
  }

  it "lean router prompt contains /respond" && {
    AGENT_FAST_ROUTE=1
    prompt=$(_build_router_prompt)
    echo "$prompt" | grep -q '/respond'
    assert_ok $? "lean prompt must include /respond (default delivery)"
  }

  it "lean router prompt does NOT contain /git (handled by fast-route)" && {
    AGENT_FAST_ROUTE=1
    prompt=$(_build_router_prompt)
    echo "$prompt" | grep -q '/git '
    assert_fail $? "lean prompt must NOT include /git (fast-route handles it)"
  }

  it "full router prompt contains /git when fast-route disabled" && {
    AGENT_FAST_ROUTE=0
    prompt=$(_build_router_prompt)
    echo "$prompt" | grep -q '/git '
    assert_ok $? "full prompt must include /git when fast-route disabled"
    AGENT_FAST_ROUTE=1
  }

  it "_build_router_prompt delegates to _build_router_prompt_full when AGENT_FAST_ROUTE=0" && {
    body=$(declare -f _build_router_prompt)
    echo "$body" | grep -q '_build_router_prompt_full'
    assert_ok $? "lean prompt must delegate to full when fast-route disabled"
  }

# ── Conditional strategist injection ──────────────────────────
describe "Conditional strategist injection"

  it "social context is gated on task keywords in agent_run" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_social_signal'
    assert_ok $? "social context injection must use keyword gating"
  }

  it "brainstorm context is gated on AGENT_BRAINSTORM" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'AGENT_BRAINSTORM.*BRAINSTORM_FILE\|AGENT_BRAINSTORM.*brainstorm'
    assert_ok $? "brainstorm context must be gated on AGENT_BRAINSTORM toggle"
  }

  it "coding card is conditionally injected based on task keywords" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_coding_signal'
    assert_ok $? "coding card must use keyword detection"
  }

  it "COMMS tools only injected when social/email services configured" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'CONFIGURED.*discord\|CONFIGURED.*email'
    assert_ok $? "COMMS section must be conditional on service configuration"
  }

# ── Task classifier function ─────────────────────────────────
describe "Task classifier function"

  it "_agent_classify_task function exists" && {
    declare -f _agent_classify_task &>/dev/null
    assert_ok $? "_agent_classify_task must be defined"
  }

  it "AGENT_TASK_MODE defaults to 0 (auto)" && {
    assert_eq "${AGENT_TASK_MODE:-0}" "0"
  }

  it "AGENT_TASK_MODE=1 forces abstract and returns early" && {
    body=$(declare -f _agent_classify_task)
    echo "$body" | grep -q 'AGENT_TASK_TYPE="abstract"'
    assert_ok $? "mode 1 must set AGENT_TASK_TYPE to abstract"
  }

  it "AGENT_TASK_MODE=2 forces concrete" && {
    body=$(declare -f _agent_classify_task)
    echo "$body" | grep -q 'AGENT_TASK_TYPE="concrete"'
    assert_ok $? "mode 2 must set AGENT_TASK_TYPE to concrete"
  }

  it "AGENT_TASK_MODE=3 forces combined" && {
    body=$(declare -f _agent_classify_task)
    echo "$body" | grep -q 'AGENT_TASK_TYPE="combined"'
    assert_ok $? "mode 3 must set AGENT_TASK_TYPE to combined"
  }

  it "AGENT_TASK_MODE=0 falls through to LLM classification" && {
    body=$(declare -f _agent_classify_task)
    echo "$body" | grep -q 'llm_generate'
    assert_ok $? "mode 0 must invoke LLM classifier"
  }

# ── Web masking system ───────────────────────────────────────
describe "Web masking system"

  it "AGENT_WEB_UNLOCK_ABSTRACT defaults to 1" && {
    assert_eq "${AGENT_WEB_UNLOCK_ABSTRACT:-1}" "1"
  }

  it "AGENT_WEB_UNLOCK_COMBINED defaults to 0" && {
    assert_eq "${AGENT_WEB_UNLOCK_COMBINED:-0}" "0"
  }

  it "agent_run computes _web_locked flag per macro iteration" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_web_locked'
    assert_ok $? "agent_run must compute _web_locked flag"
  }

  it "_web_locked is exported as _AGENT_WEB_LOCKED" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'export _AGENT_WEB_LOCKED'
    assert_ok $? "_AGENT_WEB_LOCKED must be exported for inner functions"
  }

  it "web lock checks AGENT_TASK_TYPE against thresholds" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'AGENT_WEB_UNLOCK_ABSTRACT\|WEB_UNLOCK_ABSTRACT'
    assert_ok $? "web lock must reference abstract threshold"
    echo "$body" | grep -q 'AGENT_WEB_UNLOCK_COMBINED\|WEB_UNLOCK_COMBINED'
    assert_ok $? "web lock must reference combined threshold"
  }

  it "cached router variant strips /web lines" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_cached_router_sys_nweb'
    assert_ok $? "web-stripped router cache must exist"
  }

  it "router selection switches on _AGENT_WEB_LOCKED" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_AGENT_WEB_LOCKED'
    assert_ok $? "inner loop must check _AGENT_WEB_LOCKED"
    echo "$body" | grep -q '_cached_router_sys_nweb'
    assert_ok $? "router must have web-stripped variant available"
  }

  it "strategist tool summary conditionally omits WEB group" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_web_locked'
    assert_ok $? "strategist section must reference web lock flag"
    echo "$body" | grep -q '/vision'
    assert_ok $? "vision must remain available when web is stripped"
  }

  it "exploration directive has web-locked variant without /web mention" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'EXPLORATION PRIORITY'
    assert_ok $? "exploration directive must exist"
    echo "$body" | grep -q '/grep'
    assert_ok $? "exploration directive must include /grep"
  }

  it "specialist preamble conditionally omits /web from TOOLS" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q '_AGENT_WEB_LOCKED'
    assert_ok $? "specialist TOOLS list must conditionally exclude /web"
  }

# ── Git masking system ────────────────────────────────────────
describe "Git masking system"

  it "AGENT_GIT_UNLOCK_ABSTRACT defaults to 1" && {
    assert_eq "${AGENT_GIT_UNLOCK_ABSTRACT:-1}" "1"
  }

  it "AGENT_GIT_UNLOCK_COMBINED defaults to 1" && {
    assert_eq "${AGENT_GIT_UNLOCK_COMBINED:-1}" "1"
  }

  it "agent_run computes _git_locked flag per macro iteration" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_git_locked'
    assert_ok $? "agent_run must compute _git_locked flag"
  }

  it "_git_locked is exported as _AGENT_GIT_LOCKED" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'export _AGENT_GIT_LOCKED'
    assert_ok $? "_AGENT_GIT_LOCKED must be exported for inner functions"
  }

  it "git lock checks AGENT_TASK_TYPE against thresholds" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'AGENT_GIT_UNLOCK_ABSTRACT\|GIT_UNLOCK_ABSTRACT'
    assert_ok $? "git lock must reference abstract threshold"
    echo "$body" | grep -q 'AGENT_GIT_UNLOCK_COMBINED\|GIT_UNLOCK_COMBINED'
    assert_ok $? "git lock must reference combined threshold"
  }

  it "cached router variant strips /git lines" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_cached_router_sys_ngit'
    assert_ok $? "git-stripped router cache must exist"
  }

  it "router selection switches on _AGENT_GIT_LOCKED" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_AGENT_GIT_LOCKED'
    assert_ok $? "inner loop must check _AGENT_GIT_LOCKED"
    echo "$body" | grep -q '_cached_router_sys_ngit'
    assert_ok $? "router must have git-stripped variant available"
  }

  it "strategist tool summary conditionally omits GIT group" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_git_locked'
    assert_ok $? "strategist section must reference git lock flag"
  }

  it "specialist preamble conditionally omits /git from TOOLS" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q '_AGENT_GIT_LOCKED'
    assert_ok $? "specialist TOOLS list must conditionally exclude /git"
  }

  it "recommendation validation discards /git when locked" && {
    body=$(declare -f _agent_evaluate_honeydew_item)
    echo "$body" | grep -q '_AGENT_GIT_LOCKED'
    assert_ok $? "evaluator must discard /git recommendations when locked"
  }

  it "compact catalog gates /git via GITPLACEHOLDER" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'GITPLACEHOLDER'
    assert_ok $? "compact catalog must use GITPLACEHOLDER pattern"
  }

# ── /grep agent integration ──────────────────────────────────
describe "/grep agent integration"

  it "/grep is in lean router prompt" && {
    body=$(declare -f _build_router_prompt)
    echo "$body" | grep -q '/grep'
    assert_ok $? "/grep must appear in lean router"
  }

  it "/grep is in full router prompt" && {
    body=$(declare -f _build_router_prompt_full)
    echo "$body" | grep -q '/grep'
    assert_ok $? "/grep must appear in full router"
  }

  it "/grep has a specialist syntax card" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'grep)'
    assert_ok $? "/grep must have a specialist syntax card case"
  }

  it "_fast_route matches grep keywords" && {
    body=$(declare -f _fast_route)
    echo "$body" | grep -q 'grep'
    assert_ok $? "fast route must match grep keywords"
  }

  it "/grep appears in strategist tool summary" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '/grep'
    assert_ok $? "/grep must be listed in strategist tool summary"
  }

  it "/grep appears in exploration directive" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '/grep.*pattern'
    assert_ok $? "/grep must appear in exploration directive"
  }

# ── /grep command hardening ──────────────────────────────────
describe "/grep command hardening"

  it "/grep is exempt from quote stripping" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '/grep.*skip_quote_strip\|/grep.*_skip_quote'
    rc1=$?
    # Also accept adjacent-line pattern (declare -f may split across lines)
    if [ "$rc1" -ne 0 ]; then
        echo "$body" | grep -A1 '/grep' | grep -q '_skip_quote_strip'
        rc1=$?
    fi
    assert_ok $rc1 "/grep must bypass quote stripping"
  }

  it "AGENT_GREP_ALLOW_ABSOLUTE defaults to 0" && {
    assert_eq "${AGENT_GREP_ALLOW_ABSOLUTE:-0}" "0"
  }

  it "AGENT_GREP_MAX_LINES defaults to 100" && {
    assert_eq "${AGENT_GREP_MAX_LINES:-100}" "100"
  }

  it "/grep syntax card teaches quoted patterns" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'Pattern MUST be in double quotes'
    assert_ok $? "syntax card must teach quoting requirement"
  }

  it "/grep syntax card teaches relative paths only" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'RELATIVE PATHS ONLY'
    assert_ok $? "syntax card must enforce relative paths"
  }

  it "/grep syntax card teaches ERE not PCRE" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'NOT.*\\\\d.*\\\\w'
    assert_ok $? "syntax card must warn about PCRE shorthand"
  }

  it "exploration directive uses quoted /grep syntax" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '/grep.*"<pattern>"'
    assert_ok $? "exploration directive must show quoted /grep pattern"
  }

# ── Phase 2: /cd evaluation flow ──────────────────────────────
describe "/cd specialist loop fix"

  it "/cd interception uses flag instead of continue" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_cd_intercepted=1'
    assert_ok $? "/cd must set intercepted flag"
  }

  it "/cd guard closes before dispatch" && {
    grep -q 'end _cd_intercepted guard' "$LODGE_DIR/lib/agent.sh"
    assert_ok $? "dispatch must be wrapped in _cd_intercepted=0 guard"
  }

# ── Phase 3: Content stripping exemption ───────────────────────
describe "Multi-command content preservation"

  it "splitter skips content-bearing verbs" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'respond|write|save|append|edit|email|brainstorm|q'
    assert_ok $? "splitter must exempt content-bearing verbs"
  }

# ── Phase 4: /ls path enforcement ─────────────────────────────
describe "/ls root path enforcement"

  it "AGENT_LS_ALLOW_ABSOLUTE defaults to 0" && {
    assert_eq "${AGENT_LS_ALLOW_ABSOLUTE:-0}" "0"
  }

  it "/ls syntax card teaches relative paths" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'RELATIVE PATHS ONLY'
    assert_ok $? "/ls syntax card must enforce relative paths"
  }

# ── Phase 5: Ctrl+C cancel-file in SSE loops ──────────────────
describe "SSE loop cancel awareness"

  it "generic SSE loop checks cancel file" && {
    body=$(declare -f _provider_sse_loop)
    echo "$body" | grep -q '_cancel_file'
    assert_ok $? "generic SSE loop must reference cancel file"
  }

  it "Anthropic SSE loop checks cancel file" && {
    body=$(declare -f _provider_anthropic_sse_loop)
    echo "$body" | grep -q '_cancel_file'
    assert_ok $? "Anthropic SSE loop must reference cancel file"
  }

  it "Google SSE loop checks cancel file" && {
    body=$(declare -f _provider_google_sse_loop)
    echo "$body" | grep -q '_cancel_file'
    assert_ok $? "Google SSE loop must reference cancel file"
  }

  it "Cohere SSE loop checks cancel file" && {
    body=$(declare -f _provider_cohere_sse_loop)
    echo "$body" | grep -q '_cancel_file'
    assert_ok $? "Cohere SSE loop must reference cancel file"
  }

# ── Phase 7: Web gate evaluator leak ──────────────────────────
describe "Web gate evaluator filtering"

  it "evaluator catalog filters /web when locked" && {
    body=$(declare -f _agent_evaluate_honeydew_item)
    echo "$body" | grep -q '_AGENT_WEB_LOCKED'
    assert_ok $? "evaluator must check _AGENT_WEB_LOCKED for catalog"
  }

  it "recommendation validator blocks /web when locked" && {
    body=$(declare -f _agent_evaluate_honeydew_item)
    echo "$body" | grep -q 'web.*discarded.*web locked'
    assert_ok $? "recommendation validator must block /web when locked"
  }

# ── Phase 8: Grep \\| ERE transform ──────────────────────────
describe "Grep BRE-to-ERE transform"

  it "/grep transforms backslash-pipe to pipe for ERE" && {
    # The sed chain in _cmd_grep (lodge script) must include \| → | conversion.
    # Since _cmd_grep is sourced from lodge (not agent.sh), check the file directly.
    grep -q "s/\\\\\\\\|/|/g" "$LODGE_DIR/lodge"
    assert_ok $? "PCRE→ERE sed chain must include backslash-pipe transform"
  }

# ── Phase 9: Journal debug quip leak ──────────────────────────
describe "Journal debug suppression"

  it "journal_write_quip suppresses LODGE_DEBUG" && {
    body=$(declare -f journal_write_quip)
    echo "$body" | grep -q 'LODGE_DEBUG=0'
    assert_ok $? "quip writer must set LODGE_DEBUG=0"
  }

# ── Phase 10: JSON schema enforcement infrastructure ──────────
describe "_agent_extract_json helper"

  it "_agent_extract_json is defined" && {
    declare -f _agent_extract_json &>/dev/null
    assert_ok $?
  }

  it "extracts clean JSON with required fields" && {
    _t_result=$(_agent_extract_json '{"verdict":"COMPLETE","reason":"all done"}' "verdict" "reason") || true
    _t_v=$(echo "${_t_result:-}" | jq -r '.verdict' 2>/dev/null) || true
    assert_eq "${_t_v:-}" "COMPLETE"
  }

  it "extracts JSON wrapped in think blocks" && {
    _t_input=$(printf '<think>some reasoning</think>\n{"verdict":"INCOMPLETE","reason":"not finished"}')
    _t_result=$(_agent_extract_json "$_t_input" "verdict" "reason") || true
    _t_v=$(echo "${_t_result:-}" | jq -r '.verdict' 2>/dev/null) || true
    assert_eq "${_t_v:-}" "INCOMPLETE"
  }

  it "extracts JSON wrapped in markdown code fences" && {
    _t_input=$(printf '```json\n{"verdict":"SATISFIED","reason":"done","recommendation":"/write summary"}\n```')
    _t_result=$(_agent_extract_json "$_t_input" "verdict" "reason") || true
    _t_v=$(echo "${_t_result:-}" | jq -r '.verdict' 2>/dev/null) || true
    assert_eq "${_t_v:-}" "SATISFIED"
  }

  it "returns exit 1 on missing required field" && {
    _agent_extract_json '{"verdict":"COMPLETE"}' "verdict" "reason" >/dev/null 2>&1 || _t_exit=$?
    assert_fail "${_t_exit:-0}"
  }

  it "returns exit 1 on invalid JSON" && {
    _agent_extract_json 'not json at all' "verdict" >/dev/null 2>&1 || _t_exit=$?
    assert_fail "${_t_exit:-0}"
  }

  it "handles JSON with trailing text after closing brace" && {
    _t_result=$(_agent_extract_json '{"type":"abstract"} some extra text the model wrote' "type") || true
    _t_v=$(echo "${_t_result:-}" | jq -r '.type' 2>/dev/null) || true
    assert_eq "${_t_v:-}" "abstract"
  }

describe "GBNF grammar files"

  it "grammars/ directory exists" && {
    assert_dir_exists "$LODGE_DIR/grammars"
  }

  it "p1-evaluator.gbnf exists and has root rule" && {
    assert_file_exists "$LODGE_DIR/grammars/p1-evaluator.gbnf"
    grep -q 'root' "$LODGE_DIR/grammars/p1-evaluator.gbnf"
    assert_ok $?
  }

  it "task-classifier.gbnf exists and has type_enum" && {
    assert_file_exists "$LODGE_DIR/grammars/task-classifier.gbnf"
    grep -q 'type_enum' "$LODGE_DIR/grammars/task-classifier.gbnf"
    assert_ok $?
  }

  it "honeydew-items.gbnf exists and has item_list" && {
    assert_file_exists "$LODGE_DIR/grammars/honeydew-items.gbnf"
    grep -q 'item_list' "$LODGE_DIR/grammars/honeydew-items.gbnf"
    assert_ok $?
  }

  it "honeydew-evaluator.gbnf has recommendation field" && {
    assert_file_exists "$LODGE_DIR/grammars/honeydew-evaluator.gbnf"
    grep -q 'recommendation' "$LODGE_DIR/grammars/honeydew-evaluator.gbnf"
    assert_ok $?
  }

  it "metacog.gbnf exists and has progress_enum" && {
    assert_file_exists "$LODGE_DIR/grammars/metacog.gbnf"
    grep -q 'progress_enum' "$LODGE_DIR/grammars/metacog.gbnf"
    assert_ok $?
  }

describe "Grammar integration in llm.sh"

  it "_llm_load_grammar loads grammar from file" && {
    declare -f _llm_load_grammar &>/dev/null
    assert_ok $?
  }

  it "_llm_load_grammar returns grammar text for valid schema" && {
    _LLM_GRAMMAR_CACHE=()
    _t_g=$(_llm_load_grammar "p1-evaluator") || true
    assert_contains "${_t_g:-}" "verdict_val"
  }

  it "_llm_load_grammar returns empty for unknown schema" && {
    _LLM_GRAMMAR_CACHE=()
    _t_g=$(_llm_load_grammar "nonexistent-grammar" 2>/dev/null) || true
    assert_empty "${_t_g:-}"
  }

  it "_llm_load_grammar caches on second call" && {
    _LLM_GRAMMAR_CACHE=()
    _llm_load_grammar "task-classifier" >/dev/null
    # Cache key should exist now
    assert_not_empty "${_LLM_GRAMMAR_CACHE[task-classifier]:-}"
  }

describe "Schema enforcement wiring"

  it "P1 evaluator passes p1-evaluator schema_name" && {
    body=$(declare -f _agent_evaluate_milestone)
    echo "$body" | grep -q '"p1-evaluator"'
    assert_ok $? "P1 evaluator must pass p1-evaluator to llm_generate"
  }

  it "task classifier passes task-classifier schema_name" && {
    body=$(declare -f _agent_classify_task)
    echo "$body" | grep -q '"task-classifier"'
    assert_ok $? "task classifier must pass task-classifier to llm_generate"
  }

  it "honeydew builder passes honeydew-items schema_name" && {
    body=$(declare -f _agent_honeydew_build)
    echo "$body" | grep -q '"honeydew-items"'
    assert_ok $? "honeydew builder must pass honeydew-items to llm_generate"
  }

  it "honeydew evaluator passes honeydew-evaluator schema_name" && {
    body=$(declare -f _agent_evaluate_honeydew_item)
    echo "$body" | grep -q '"honeydew-evaluator"'
    assert_ok $? "honeydew evaluator must pass honeydew-evaluator to llm_generate"
  }

  it "honeydew evaluator extracts recommendation from JSON" && {
    body=$(declare -f _agent_evaluate_honeydew_item)
    echo "$body" | grep -q '\.recommendation'
    assert_ok $? "honeydew evaluator must extract .recommendation from JSON"
  }

describe "Reflexive integration"

  it "strategist prompt includes reflexive metacog injection" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'REFLEXIVE INSIGHT'
    assert_ok $? "strategist must have REFLEXIVE INSIGHT injection block"
  }

  it "strategist reflexive injection is guarded by REFLEXIVE_SELF_MODEL" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'REFLEXIVE_SELF_MODEL'
    assert_ok $? "strategist reflexive must be gated by REFLEXIVE_SELF_MODEL"
  }

  it "honeydew evaluator includes reflexive context injection" && {
    body=$(declare -f _agent_evaluate_honeydew_item)
    echo "$body" | grep -q 'REFLEXIVE CONTEXT'
    assert_ok $? "honeydew evaluator must inject reflexive context"
  }

  it "honeydew evaluator reflexive is guarded by REFLEXIVE_SELF_MODEL" && {
    body=$(declare -f _agent_evaluate_honeydew_item)
    echo "$body" | grep -q 'REFLEXIVE_SELF_MODEL'
    assert_ok $? "evaluator reflexive must be gated by REFLEXIVE_SELF_MODEL"
  }

  it "metacog LLM call passes metacog schema_name" && {
    source "$LODGE_DIR/lib/reflexive.sh"
    body=$(declare -f reflexive_metacog_assess)
    echo "$body" | grep -q '"metacog"'
    assert_ok $? "metacog assess must pass metacog schema to llm_generate"
  }

  it "metacog uses _agent_extract_json for JSON parsing" && {
    source "$LODGE_DIR/lib/reflexive.sh"
    body=$(declare -f reflexive_metacog_assess)
    echo "$body" | grep -q '_agent_extract_json'
    assert_ok $? "metacog assess must use _agent_extract_json for Layer 2"
  }

# ── Written file path tracking ───────────────────────────────
describe "Written file path tracking"

  it "_AGENT_WRITTEN_FILES array is declared in agent_run" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_AGENT_WRITTEN_FILES=()'
    assert_ok $? "_AGENT_WRITTEN_FILES must be declared as empty array"
  }

  it "successful /write commands are tracked in _AGENT_WRITTEN_FILES" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_AGENT_WRITTEN_FILES'
    assert_ok $? "inner loop must reference _AGENT_WRITTEN_FILES"
    echo "$body" | grep -q '_wf_rest'
    assert_ok $? "must extract rest of command for path"
  }

  it "file path is extracted from first word after verb" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_wf_path'
    assert_ok $? "must have _wf_path variable"
    echo "$body" | grep -q 'awk.*print \$1'
    assert_ok $? "must extract first word as path via awk"
  }

  it "duplicate file paths are not added twice" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_wf_dup=0'
    assert_ok $? "must have deduplication check"
    echo "$body" | grep -q '_wf_dup=1'
    assert_ok $? "must flag duplicates"
  }

  it "operator-guided writes are also tracked" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_wfg_path'
    assert_ok $? "operator-guided path extraction must exist"
    echo "$body" | grep -q 'operator_guided'
    assert_ok $? "operator_guided source tag must exist"
  }

  it "specialist prompt injects CREATED FILES when array is populated" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'CREATED FILES (this task)'
    assert_ok $? "specialist must inject CREATED FILES header"
    echo "$body" | grep -q 'Reference these EXACT paths'
    assert_ok $? "specialist must instruct to use exact paths"
  }

  it "specialist CREATED FILES injection is guarded by array length" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q '#_AGENT_WRITTEN_FILES\[@\]'
    assert_ok $? "must check array length before injecting"
  }

  it "strategist prompt injects created files when present" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_strat_written_files'
    assert_ok $? "strategist must have _strat_written_files variable"
    echo "$body" | grep -q 'CREATED FILES (this task)'
    assert_ok $? "strategist must inject CREATED FILES header"
  }

  it "strategist created files injection is included in macro_prompt" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'strat_written_files'
    assert_ok $? "macro_prompt must include _strat_written_files"
  }

  it "written-files debug logging is present" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'written-files: tracked'
    assert_ok $? "must debug-log when a file path is tracked"
    body_spec=$(declare -f _build_specialist_prompt)
    echo "$body_spec" | grep -q 'specialist <- created files'
    assert_ok $? "must debug-log specialist injection"
    body_strat=$(declare -f agent_run)
    echo "$body_strat" | grep -q 'strategist <- created files'
    assert_ok $? "must debug-log strategist injection"
  }

# ── Issue 1: Pre-LLM keyword gate for external-info tasks ──────
describe "Task classifier keyword gate"

  it "classifies news tasks as combined via keyword gate" && {
    body=$(declare -f _agent_classify_task)
    echo "$body" | grep -q 'news'
    assert_ok $? "keyword gate must match 'news'"
    echo "$body" | grep -q 'keyword gate'
    assert_ok $? "debug output must mention keyword gate"
  }

  it "classifies weather tasks as combined via keyword gate" && {
    body=$(declare -f _agent_classify_task)
    echo "$body" | grep -q 'weather'
    assert_ok $? "keyword gate must match 'weather'"
  }

  it "classifies latest tasks as combined via keyword gate" && {
    body=$(declare -f _agent_classify_task)
    echo "$body" | grep -q 'latest'
    assert_ok $? "keyword gate must match 'latest'"
  }

  it "classifies trending tasks as combined via keyword gate" && {
    body=$(declare -f _agent_classify_task)
    echo "$body" | grep -q 'trending'
    assert_ok $? "keyword gate must match 'trending'"
  }

  it "keyword gate returns before LLM call" && {
    body=$(declare -f _agent_classify_task)
    # The keyword gate block must have 'return 0' before the classify_prompt
    gate_line=$(echo "$body" | grep -n 'keyword gate' | head -1 | cut -d: -f1)
    prompt_line=$(echo "$body" | grep -n 'classify_prompt' | head -1 | cut -d: -f1)
    [ -n "$gate_line" ] && [ -n "$prompt_line" ] && [ "$gate_line" -lt "$prompt_line" ]
    assert_ok $? "keyword gate must appear before LLM classify_prompt"
  }

# ── Issue 2: Hallucinated command tracking ───────────────────
describe "Hallucinated command tracking in inner loop"

  it "hallucinated commands are added to _inner_cmd_history" && {
    body=$(declare -f agent_inner_loop)
    # After the hallucination rejection block, _inner_cmd_history should be updated
    echo "$body" | grep -A15 'Specialist hallucinated' | grep -q '_inner_cmd_history'
    assert_ok $? "hallucinated command rejection must track in _inner_cmd_history"
  }

# ── Issue 3: Sieve-aware honeydew decomposition ─────────────
describe "Honeydew build recall-first relaxation"

  it "honeydew build checks prior_context from macro_memory" && {
    body=$(declare -f _agent_honeydew_build)
    echo "$body" | grep -q 'prior_context'
    assert_ok $? "honeydew_build must check macro_memory for prior_context"
  }

  it "honeydew build checks prior_context_note from macro_memory" && {
    body=$(declare -f _agent_honeydew_build)
    echo "$body" | grep -q 'prior_context_note'
    assert_ok $? "honeydew_build must check macro_memory for prior_context_note"
  }

  it "honeydew build skips recall-first when sieve injected context" && {
    body=$(declare -f _agent_honeydew_build)
    echo "$body" | grep -q 'skipping recall-first (sieve injected prior_context)'
    assert_ok $? "must log skip when sieve injected prior_context"
  }

  it "honeydew build skips recall-first when sieve found nothing" && {
    body=$(declare -f _agent_honeydew_build)
    echo "$body" | grep -q 'skipping recall-first (sieve found nothing)'
    assert_ok $? "must log skip when sieve found nothing"
  }

  it "honeydew build uses SHOULD not MUST for abstract tasks" && {
    body=$(declare -f _agent_honeydew_build)
    # Check that abstract path uses SHOULD
    echo "$body" | grep 'abstract' -A10 | grep -q 'SHOULD'
    assert_ok $? "abstract exploration_priority must use SHOULD not MUST"
  }

  it "honeydew build uses SHOULD not MUST for combined fallback" && {
    body=$(declare -f _agent_honeydew_build)
    # The combined fallback block has "Follow with research" — check SHOULD there
    echo "$body" | grep -B3 'Follow with research' | grep -q 'SHOULD'
    assert_ok $? "combined fallback exploration_priority must use SHOULD not MUST"
  }

# ── Issue 4: Combined evaluator flexibility ─────────────────
describe "Honeydew evaluator combined-task flexibility"

  it "combined eval schema includes partial_progress" && {
    body=$(declare -f _agent_evaluate_honeydew_item)
    echo "$body" | grep -q 'partial_progress'
    assert_ok $? "combined eval_output_rule must include partial_progress"
  }

  it "combined eval schema includes pragmatic_threshold" && {
    body=$(declare -f _agent_evaluate_honeydew_item)
    echo "$body" | grep -q 'pragmatic_threshold'
    assert_ok $? "combined eval_output_rule must include pragmatic_threshold"
  }

  it "combined eval hint says lean toward SATISFIED" && {
    body=$(declare -f _agent_evaluate_honeydew_item)
    echo "$body" | grep -q 'lean toward SATISFIED'
    assert_ok $? "combined eval_output_hint must say lean toward SATISFIED"
  }

  it "eval prompt uses meaningfully address not contain specific data" && {
    body=$(declare -f _agent_evaluate_honeydew_item)
    echo "$body" | grep -q 'meaningfully address'
    assert_ok $? "eval prompt output_substance must use 'meaningfully address'"
    echo "$body" | grep -q 'contain specific data' && status=1 || status=0
    assert_ok $status "eval prompt must NOT contain old 'contain specific data' wording"
  }

# ── Issue 5: Cross-task file persistence ───────────────────
describe "Cross-task file persistence via GEORGE.md"

  it "AGENT_CONTEXT_FILES_MAX defaults to 10" && {
    assert_eq "${AGENT_CONTEXT_FILES_MAX}" "10"
  }

  it "agent_run persists written files to Context Files section" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'Context Files'
    assert_ok $? "agent_run must update Context Files section in GEORGE.md"
  }

  it "agent_run reads existing context files before appending" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'existing_cf'
    assert_ok $? "agent_run must read existing context files"
  }

  it "context files trimmed to AGENT_CONTEXT_FILES_MAX" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'AGENT_CONTEXT_FILES_MAX'
    assert_ok $? "agent_run must reference AGENT_CONTEXT_FILES_MAX for trimming"
  }

# ── Issue 5b: Prior task files injected into strategist ──────
describe "Prior task files strategist injection"

  it "strategist injects prior task files from GEORGE.md" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'PRIOR TASK FILES'
    assert_ok $? "strategist must inject PRIOR TASK FILES section"
  }

  it "prior task files injection prunes non-existent files" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '\-f.*_cf_path'
    assert_ok $? "prior files injection must check file existence"
  }

  it "macro_prompt includes _strat_prior_files" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_strat_prior_files'
    assert_ok $? "macro_prompt must include _strat_prior_files"
  }

# ── Issue 6: Reflexive awareness in rewrite router ──────────
describe "Reflexive metacog in honeydew rewrite router"

  it "rewrite router injects reflexive metacog state" && {
    body=$(declare -f _agent_honeydew_rewrite)
    echo "$body" | grep -q 'reflexive_metacog_state'
    assert_ok $? "rewrite router must call reflexive_metacog_state"
  }

  it "rewrite router has reflexive context variable" && {
    body=$(declare -f _agent_honeydew_rewrite)
    echo "$body" | grep -q '_router_reflexive'
    assert_ok $? "rewrite router must have _router_reflexive variable"
  }

  it "rewrite router reflexive injection suggests restructuring" && {
    body=$(declare -f _agent_honeydew_rewrite)
    echo "$body" | grep -q 'need restructuring'
    assert_ok $? "rewrite router reflexive must suggest restructuring"
  }

  it "rewrite router injects reflexive into router_prompt" && {
    body=$(declare -f _agent_honeydew_rewrite)
    echo "$body" | grep -q '_router_reflexive'
    assert_ok $? "router_prompt must include _router_reflexive"
  }

  it "rewrite router debug logs reflexive injection" && {
    body=$(declare -f _agent_honeydew_rewrite)
    echo "$body" | grep -q 'honeydew-rewrite-router <- reflexive metacog'
    assert_ok $? "must debug-log reflexive injection into rewrite router"
  }

# ── Configurable milestone char limit ─────────────────────────
describe "Configurable milestone character limit"

  it "AGENT_MILESTONE_CHARS config variable has default 200" && {
    assert_match "${AGENT_MILESTONE_CHARS}" "200" "AGENT_MILESTONE_CHARS must default to 200"
  }

  it "macro loop uses AGENT_MILESTONE_CHARS for truncation" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'AGENT_MILESTONE_CHARS'
    assert_ok $? "macro loop must reference AGENT_MILESTONE_CHARS"
  }

  it "macro loop stores full text in _STRATEGIST_FULL_OUTPUT before truncating" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_STRATEGIST_FULL_OUTPUT="$milestone"'
    assert_ok $? "must store full milestone in _STRATEGIST_FULL_OUTPUT"
  }

  it "macro loop passes _STRATEGIST_FULL_OUTPUT to agent_inner_loop" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_STRATEGIST_FULL_OUTPUT'
    assert_ok $? "agent_inner_loop call must include _STRATEGIST_FULL_OUTPUT"
  }

  it "agent_inner_loop accepts strategist full text as third parameter" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_strategist_full'
    assert_ok $? "inner loop must declare _strategist_full variable"
  }

  it "specialist prompt injects FULL STRATEGIST DIRECTIVE when truncated" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'FULL STRATEGIST DIRECTIVE'
    assert_ok $? "specialist prompt must include FULL STRATEGIST DIRECTIVE injection"
  }

  it "strategist directive injection is conditional on length difference" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '#_strategist_full.*-gt.*#micro_objective'
    assert_ok $? "injection must compare _strategist_full length to micro_objective"
  }

# ── Image Scrape Queue & Prompt Injection ─────────────────────
describe "Image Scrape Queue and Prompt Injection"

  it "extracts image URLs from scrape JSON output" && {
    json_data='{"title":"Test Page","images":["https://example.com/logo.png","https://example.com/hero.jpg"],"content":"Hello"}'
    results=$(_agent_extract_images_from_scrape "$json_data")
    assert_contains "$results" "https://example.com/logo.png"
    assert_contains "$results" "https://example.com/hero.jpg"
  }

  it "extracts image URLs from raw scrape text fallback" && {
    text_data="Here is an image: https://example.com/image.png and another: https://example.com/pic.jpg"
    results=$(_agent_extract_images_from_scrape "$text_data")
    assert_contains "$results" "https://example.com/image.png"
    assert_contains "$results" "https://example.com/pic.jpg"
  }

  it "injects discovered image URLs into specialist prompt" && {
    temp_ws="./george_test_ws_$$"
    mkdir -p "$temp_ws"
    echo "https://example.com/logo.png" > "$temp_ws/web_image_queue.txt"
    echo "https://example.com/banner.jpg" >> "$temp_ws/web_image_queue.txt"
    
    out=""
    AGENT_TASK_WORKSPACE="$temp_ws" out=$(_build_specialist_prompt "/download" "$temp_ws" "Download logo")
    rm -rf "$temp_ws"
    
    echo "$out" | grep -q "DISCOVERED IMAGE URLS"
    assert_ok $? "Must inject DISCOVERED IMAGE URLS section"
    echo "$out" | grep -q "https://example.com/logo.png"
    assert_ok $? "Must contain logo.png URL"
  }

test_end
