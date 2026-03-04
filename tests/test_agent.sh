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
source "$LODGE_DIR/lib/agent.sh"

test_start "lib/agent.sh — Agent Loop"

# ── Configuration ──────────────────────────────────────────────
describe "Configuration defaults"

  it "AGENT_MAX_STEPS defaults to 20" && {
    assert_eq "$AGENT_MAX_STEPS" "20"
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
    body=$(declare -f _build_router_prompt)
    echo "$body" | grep -q '/journal.*Read or write'
    assert_ok $?
  }

  it "strategist tool summary lists journal read and write" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '/journal (read).*journal write (write)'
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

  it "macro strategist has question detection rule" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '/ask.*ONLY for questions\|no tools needed'
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
    echo "$body" | grep -q '<think>'
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

  it "macro strategist has anti-email-for-social rule" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'NOT.*email'
    assert_ok $?
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
    body=$(declare -f _build_router_prompt)
    echo "$body" | grep -q 'NOT.*email'
    assert_ok $?
  }

  it "router prompt has anti-sandbox rule" && {
    body=$(declare -f _build_router_prompt)
    echo "$body" | grep -q 'NOT route to /sandbox'
    assert_ok $?
  }

  it "specialist prompt has anti-sandbox instruction" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'NOT use /sandbox to run slash'
    assert_ok $?
  }

  it "specialist prompt tells LLM not to quote arguments" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'quotes_on_args\|NOT quote arguments'
    assert_ok $?
  }

  it "specialist prompt tells LLM one command per line" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'multiple_commands_per_line\|ONE command per line'
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

# ── Recursive planning config ─────────────────────────────────
describe "Recursive planning config"

  it "AGENT_MAX_DEPTH defaults to 2" && {
    assert_eq "$AGENT_MAX_DEPTH" "2"
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

  it "AGENT_PLAN_STEPS defaults to 5" && {
    assert_eq "$AGENT_PLAN_STEPS" "5"
  }

  it "AGENT_PLAN_STEPS is overridable" && {
    (
      AGENT_PLAN_STEPS=8
      assert_eq "$AGENT_PLAN_STEPS" "8"
    )
    assert_ok $?
  }

  it "AGENT_INNER_LOOPS defaults to 6" && {
    assert_eq "$AGENT_INNER_LOOPS" "6"
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
    echo "$body" | grep -q 'Date:.*_strat_now\|current date and time'
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

  it "AGENT_WEB_SUFFICIENCY defaults to 3" && {
    assert_eq "$AGENT_WEB_SUFFICIENCY" "3"
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

  it "AGENT_MAX_MILESTONE_RETRIES defaults to 2" && {
    assert_eq "$AGENT_MAX_MILESTONE_RETRIES" "2"
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

  it "deduplication checks first 40 chars for similarity" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_milestone_lower:0:40'
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
    echo "$body" | grep -q 'Milestone skipped (duplicate)'
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

  it "evaluator generates summary in auto mode" && {
    body=$(declare -f _agent_evaluate_completion)
    echo "$body" | grep -q 'summary_prompt'
    assert_ok $?
  }

  it "evaluator uses LLM_SCENARIO=evaluator" && {
    body=$(declare -f _agent_evaluate_completion)
    echo "$body" | grep -q 'LLM_SCENARIO=evaluator'
    assert_ok $?
  }

  it "dual evaluator is called in agent_run after successful milestones" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_agent_evaluate_milestone'
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
    # Feedback is set from both evaluator passes
    echo "$body" | grep -q 'Still missing'
    assert_ok $?
    echo "$body" | grep -q 'was NOT completed'
    assert_ok $?
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

  it "LLM_EVALUATOR_TOKENS defaults to 512" && {
    assert_eq "$LLM_EVALUATOR_TOKENS" "512"
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

  it "inner loop saves research_buffer.md from successful /web outputs" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'research_buffer.md'
    assert_ok $? "Must reference research_buffer.md"
  }

  it "inner loop injects research buffer into micro_memory on start" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_micro_set.*micro_file.*research_context'
    assert_ok $? "Must inject research buffer via _micro_set"
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

  it "research buffer is capped at 1500 chars" && {
    body=$(declare -f _agent_complete_milestone)
    echo "$body" | grep -q '1500'
    assert_ok $? "Must cap research buffer at 1500 chars"
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
    echo "$body" | grep -q 'research_buffer.md'
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

  it "router prompt forbids SUCCESS/DONE output" && {
    body=$(declare -f _build_router_prompt)
    echo "$body" | grep -q 'NEVER output SUCCESS or DONE'
    assert_ok $? "Router must be told to never output SUCCESS"
  }

  it "router prompt outputs only tool names" && {
    body=$(declare -f _build_router_prompt)
    echo "$body" | grep -q '"output":"ONLY the tool name'
    assert_ok $? "Router output instruction: only tool names"
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
    printf '## Honeydew List\nPrimary task: test\n\n1. [ ] First task\n2. [ ] Second task\n3. [ ] Third task\n' > "$_tmpdir/.george/honeydew.md"
    _agent_honeydew_mark 2 "$_tmpdir"
    grep -q '^2\. \[x\] Second task' "$_tmpdir/.george/honeydew.md"
    assert_ok $? "Item 2 should be marked [x]"
    grep -q '^1\. \[ \] First task' "$_tmpdir/.george/honeydew.md"
    assert_ok $? "Item 1 should remain [ ]"
    rm -rf "$_tmpdir"
  }

  it "honeydew_status reports correct counts" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    printf '## Honeydew List\nPrimary task: test\n\n1. [x] Done task\n2. [ ] Pending task\n3. [ ] Another pending\n' > "$_tmpdir/.george/honeydew.md"
    status=$(_agent_honeydew_status "$_tmpdir")
    echo "$status" | grep -q '1/3 complete'
    assert_ok $? "Should show 1/3 complete, got: $status"
    rm -rf "$_tmpdir"
  }

  it "honeydew_status shows all-done when fully checked" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    printf '## Honeydew List\nPrimary task: test\n\n1. [x] Done\n2. [x] Also done\n' > "$_tmpdir/.george/honeydew.md"
    status=$(_agent_honeydew_status "$_tmpdir")
    echo "$status" | grep -q 'All tasks done'
    assert_ok $? "Should report all done, got: $status"
    rm -rf "$_tmpdir"
  }

  it "honeydew_read returns file contents" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    printf '## Honeydew List\n1. [ ] Test item\n' > "$_tmpdir/.george/honeydew.md"
    content=$(_agent_honeydew_read "$_tmpdir")
    echo "$content" | grep -q 'Honeydew List'
    assert_ok $? "Should contain honeydew header"
    rm -rf "$_tmpdir"
  }

  it "honeydew_auto_check matches milestone to item by keywords" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    printf '## Honeydew List\nPrimary task: test\n\n1. [ ] Search the web for HiBy M500 specs\n2. [ ] Write markdown report\n3. [ ] Email the report\n' > "$_tmpdir/.george/honeydew.md"
    _agent_honeydew_auto_check "Search the web for HiBy M500 specifications and pricing" "$_tmpdir"
    assert_ok $? "Should match item 1"
    grep -q '^1\. \[x\]' "$_tmpdir/.george/honeydew.md"
    assert_ok $? "Item 1 should be auto-checked"
    rm -rf "$_tmpdir"
  }

  it "honeydew_auto_check requires minimum 2 word overlap" && {
    _tmpdir=$(mktemp -d)
    mkdir -p "$_tmpdir/.george"
    printf '## Honeydew List\nPrimary task: test\n\n1. [ ] Search web for HiBy specs\n2. [ ] Write report about findings\n' > "$_tmpdir/.george/honeydew.md"
    _agent_honeydew_auto_check "completely unrelated milestone about cats" "$_tmpdir" || true
    # Verify no items were checked
    grep -q '^1\. \[ \]' "$_tmpdir/.george/honeydew.md"
    assert_ok $? "Item 1 should remain unchecked with no keyword overlap"
    grep -q '^2\. \[ \]' "$_tmpdir/.george/honeydew.md"
    assert_ok $? "Item 2 should remain unchecked with no keyword overlap"
    rm -rf "$_tmpdir"
  }

  it "agent_run calls _agent_honeydew_build" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_agent_honeydew_build'
    assert_ok $? "agent_run must call honeydew build"
  }

  it "agent_run auto-checks honeydew on milestone success" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_agent_honeydew_auto_check'
    assert_ok $? "agent_run must auto-check honeydew items"
  }

  it "overall evaluator includes honeydew list injection" && {
    body=$(declare -f _agent_evaluate_completion)
    echo "$body" | grep -q 'HONEYDEW LIST'
    assert_ok $? "Pass 2 evaluator must reference honeydew"
    echo "$body" | grep -q 'INCOMPLETE\|NOT done\|= INCOMPLETE'
    assert_ok $? "Pass 2 evaluator must enforce unchecked items as incomplete"
  }

  it "strategist rules reference honeydew list" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'honeydew\|HONEYDEW'
    assert_ok $? "Strategist must know about honeydew list"
  }

  it "inner loop injects honeydew status into micro_memory" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'honeydew_progress'
    assert_ok $? "Inner loop must inject honeydew status"
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

  it "specialist /web card includes research flow example" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'Research flow.*search.*fetch.*summarize'
    assert_ok $? "Must show research flow chain"
  }

  it "specialist /web card includes report flow example" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'Report flow.*search.*fetch.*write.*email'
    assert_ok $? "Must show report flow chain"
  }

test_end
