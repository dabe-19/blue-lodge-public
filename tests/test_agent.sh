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
    local body
    body=$(declare -f agent_inner_loop)
    # Must check cancel file BEFORE making any LLM calls
    echo "$body" | grep -q '_LODGE_CANCELLED.*-eq 1.*_cancel_file'
    assert_ok $?
  }

  it "agent_inner_loop checks cancel after router LLM call" && {
    local body
    body=$(declare -f agent_inner_loop)
    # After llm_generate there should be a cancel check (3+ cancel checks total)
    local count
    count=$(echo "$body" | grep -c '_LODGE_CANCELLED.*_cancel_file')
    [ "$count" -ge 3 ]
    assert_ok $?
  }

  it "agent_inner_loop checks cancel after specialist LLM call" && {
    local body
    body=$(declare -f agent_inner_loop)
    # The cancel check pattern appears at loop top + after router + after specialist = 3+
    local count
    count=$(echo "$body" | grep -c '_cancel_file')
    [ "$count" -ge 4 ]
    assert_ok $?
  }

  it "agent_inner_loop skips terminal escalation when cancelled" && {
    local body
    body=$(declare -f agent_inner_loop)
    # After the while loop ends, should check cancel before operator prompt
    echo "$body" | grep -q 'CANCELLED.*macro_memory'
    assert_ok $?
  }

  it "agent_inner_loop writes CANCELLED to macro_memory on cancel" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'CANCELLED.*macro_memory'
    assert_ok $?
  }

# ── llm_stream cancellation propagation ───────────────────────
describe "llm_stream cancellation propagation"

  it "llm_stream checks cancel file after pipe completes" && {
    local body
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
    local body
    body=$(declare -f agent_plan)
    echo "$body" | grep -q "AGENT_INTERACTIVE_PLANNING"
    assert_ok $?
  }

  it "agent_plan includes 'Do NOT ask questions' instruction when non-interactive" && {
    local body
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
    local body
    body=$(declare -f agent_plan)
    echo "$body" | grep -q "CLARIFY:"
    assert_ok $?
  }

  it "agent_plan function body mentions AGENT_MAX_CLARIFY" && {
    local body
    body=$(declare -f agent_plan)
    echo "$body" | grep -q "AGENT_MAX_CLARIFY"
    assert_ok $?
  }

  it "agent_plan function body reads from /dev/tty for user input" && {
    local body
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

  it "specialist injects search_results.md for /web tool" && {
    local body
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'search_results.md'
    assert_ok $?
  }

  it "agent_inner_loop uses escalation matrix" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'Escalation L1\|Naive retry'
    assert_ok $?
  }

  it "agent_inner_loop implements identicality lockout" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'Identical failed command'
    assert_ok $?
  }

  it "agent_inner_loop validates router tool output" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_tool_valid'
    assert_ok $?
  }

  it "macro strategist injects lean command list" && {
    local body
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'YOUR WORKING COMMANDS'
    assert_ok $?
  }

  it "macro strategist has question detection rule" && {
    local body
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'ONLY use /ask for simple questions'
    assert_ok $?
  }

  it "macro strategist uses llm_generate for clean output" && {
    local body
    body=$(declare -f agent_run)
    # The strategist milestone call should use llm_generate (not llm_stream)
    # so that milestone text doesn't appear twice (once streamed, once via ui_info).
    echo "$body" | grep -q 'llm_generate.*macro_prompt.*macro_sys'
    assert_ok $?
  }

  it "macro strategist uses LLM_SCENARIO=strategist (not agent)" && {
    local body
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'LLM_SCENARIO=strategist'
    assert_ok $?
  }

  it "macro strategist uses LLM_STRATEGIST_TOKENS (not LLM_AGENT_TOKENS)" && {
    local body
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'LLM_STRATEGIST_TOKENS'
    assert_ok $?
  }

  it "macro strategist strips <think> blocks from milestone" && {
    local body
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
    echo "$body" | grep -q 'NOT use /sandbox to run slash'
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
    echo "$body" | grep -q 'NOT quote arguments'
    assert_ok $?
  }

  it "specialist prompt tells LLM one command per line" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'ONE command per line'
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
    local body
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'llm_debug_reset'
    assert_ok $?
  }

  it "agent_run prints debug summary" && {
    local body
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
    local body
    body=$(declare -f _agent_run_subtask)
    echo "$body" | grep -q 'SUBTASK'
    assert_ok $?
  }

  it "_agent_run_subtask function body checks AGENT_MAX_DEPTH" && {
    local body
    body=$(declare -f _agent_run_subtask)
    echo "$body" | grep -q 'AGENT_MAX_DEPTH'
    assert_ok $?
  }

  it "_agent_run_subtask function body calls agent_plan" && {
    local body
    body=$(declare -f _agent_run_subtask)
    echo "$body" | grep -q 'agent_plan'
    assert_ok $?
  }

# ── Plan prompt references configurable step limit ─────────────
describe "Plan prompt uses configurable step limit"

  it "agent_plan prompt uses AGENT_PLAN_STEPS variable" && {
    local body
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
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'AGENT_INNER_LOOPS'
    assert_ok $?
  }

  it "AGENT_MAX_RETRIES is removed (dead code)" && {
    local body
    body=$(cat "$LODGE_DIR/lib/agent.sh")
    ! echo "$body" | grep -q 'AGENT_MAX_RETRIES'
    assert_ok $?
  }

  it "agent_plan prompt mentions [SUBTASK] syntax" && {
    local body
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
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'recall_search_context\|Escalation L2'
    assert_ok $?
  }

  it "implements Level 5 forced web fallback" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'web_search\|Escalation L5'
    assert_ok $?
  }

  it "implements terminal escalation with operator input" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'read -r guidance'
    assert_ok $?
  }

# ── L3 failure history recall ─────────────────────────────────
describe "L3 failure history recall"

  it "L3 reads failure log for past recovery instructions" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'Past Recovery Instructions'
    assert_ok $?
  }

  it "L3 triggers at inner_attempts >= 2" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'inner_attempts.*-ge 2.*fail_file'
    assert_ok $?
  }

  it "L3 greps RECOVERY and OPERATOR GUIDANCE from failure log" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'RECOVERY.*OPERATOR GUIDANCE'
    assert_ok $?
  }

# ── Catalog-aware operator guided retry ───────────────────────
describe "Catalog-aware operator guided retry"

  it "guided retry injects command catalog" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'commands_catalog'
    assert_ok $?
  }

  it "guided retry extracts slash commands (not just bash)" && {
    local body
    body=$(declare -f agent_inner_loop)
    # Must handle both /command lines and ```bash blocks
    echo "$body" | grep -q 'final_is_slash'
    assert_ok $?
  }

  it "guided retry logs RECOVERY entry on success" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'RECOVERY:.*final_cmd'
    assert_ok $?
  }

  it "guided retry logs OPERATOR GUIDANCE in recovery entry" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'OPERATOR GUIDANCE:.*guidance'
    assert_ok $?
  }

  it "guided retry logs ORIGINAL FAILURE in recovery entry" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'ORIGINAL FAILURE:.*last_failed_cmd'
    assert_ok $?
  }

  it "guided retry logs failure when guided attempt also fails" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'FAILED COMMAND (guided)'
    assert_ok $?
  }

  it "guided retry uses commands_dispatch for slash commands" && {
    local body
    body=$(declare -f agent_inner_loop)
    # The guided retry section should dispatch slash commands properly
    echo "$body" | grep -q 'final_is_slash.*commands_dispatch'
    assert_ok $?
  }

# ── Soul injection in agent_run ───────────────────────────────
describe "Soul injection in dual-loop architecture"

  it "agent_run uses _memory_soul_identity for macro memory seed" && {
    local body
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_memory_soul_identity'
    assert_ok $?
  }

  it "agent_run does NOT use head -20 for soul extraction" && {
    local body
    body=$(declare -f agent_run)
    # Old pattern was 'head -20' — should be replaced
    ! echo "$body" | grep -q 'head -20'
    assert_ok $?
  }

  it "agent_plan calls memory_build_system_prompt with plan mode" && {
    local body
    body=$(declare -f agent_plan)
    echo "$body" | grep -q '"plan"'
    assert_ok $?
  }

# ── Web Sufficiency Gate ───────────────────────────────────────
describe "Web sufficiency gate in agent_inner_loop"

  it "AGENT_WEB_SUFFICIENCY defaults to 3" && {
    assert_eq "$AGENT_WEB_SUFFICIENCY" "3"
  }

  it "inner loop body contains SUFFICIENCY REACHED injection" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'SUFFICIENCY REACHED'
    assert_ok $?
  }

  it "sufficiency gate checks _web_ok_count against threshold" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'AGENT_WEB_SUFFICIENCY'
    assert_ok $?
  }

  it "sufficiency gate only fires for /web commands" && {
    local body
    body=$(declare -f agent_inner_loop)
    # Must contain the conditional: cmd == /web*
    echo "$body" | grep -q '/web\*'
    assert_ok $?
  }

# ── Primary Objective Injection ────────────────────────────────
describe "Primary objective injection in inner loop"

  it "inner loop injects primary objective from macro_memory.md" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'Primary Objective'
    assert_ok $?
  }

  it "injection reads from macro_memory.md" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'macro_memory.md'
    assert_ok $?
  }

  it "injection only adds objective when different from micro objective" && {
    local body
    body=$(declare -f agent_inner_loop)
    # Must compare _primary_obj != micro_objective
    echo "$body" | grep -q '_primary_obj.*!=.*micro_objective'
    assert_ok $?
  }

# ── Router Research Guidance ────────────────────────────────────
describe "Router web research sufficiency guidance"

  it "route_prompt includes WEB RESEARCH RULE for search objectives" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'WEB RESEARCH RULE'
    assert_ok $?
  }

  it "research guidance triggers for search-related objectives" && {
    local body
    body=$(declare -f agent_inner_loop)
    # Must check for web/search/fetch/find keywords
    echo "$body" | grep -q '_obj_lower_rt.*search'
    assert_ok $?
  }

# ── Abort Propagation ─────────────────────────────────────────
describe "Abort propagation from inner loop to macro loop"

  it "abort sets _LODGE_CANCELLED flag" && {
    local body
    body=$(declare -f agent_inner_loop)
    # Must contain: guidance = abort -> _LODGE_CANCELLED=1
    echo "$body" | grep -q 'guidance.*abort'
    assert_ok $?
    echo "$body" | grep -q '_LODGE_CANCELLED=1'
    assert_ok $?
  }

  it "abort touches cancel file for subshell visibility" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'touch.*_cancel_file'
    assert_ok $?
  }

  it "abort writes ABORTED to macro_memory" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'ABORTED by operator'
    assert_ok $?
  }

  it "abort returns 1 immediately without guided retry" && {
    # Verify abort block (with return 1) appears before guided retry block
    # in the source file. declare -f strips comments so we read the file.
    local abort_line guided_line
    abort_line=$(grep -n 'ABORTED by operator' "$LODGE_DIR/lib/agent.sh" | head -1 | cut -d: -f1)
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
    local body
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_attempted_milestones'
    assert_ok $?
  }

  it "agent_run tracks milestone outcomes (OK/FAILED) in array" && {
    local body
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'OK|'
    assert_ok $?
    echo "$body" | grep -q 'FAILED|'
    assert_ok $?
  }

  it "strategist prompt includes 'do NOT repeat failed milestones' rule" && {
    # Check the source file directly since declare -f may mangle multi-byte
    # characters (em dashes) in string literals.
    grep -q 'Do NOT regenerate a milestone that previously FAILED' "$LODGE_DIR/lib/agent.sh"
    assert_ok $?
  }

  it "milestone history injected into strategist system prompt" && {
    local body
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'PREVIOUSLY ATTEMPTED MILESTONES'
    assert_ok $?
  }

  it "duplicate milestones are skipped after max retries" && {
    local body
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'SKIPPED (duplicate of failed milestone)'
    assert_ok $?
  }

  it "deduplication checks first 40 chars for similarity" && {
    local body
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_milestone_lower:0:40'
    assert_ok $?
  }

# ── Specialist key injection ──────────────────────────────────
describe "Specialist per-command key status"

  it "_specialist_key_status is defined" && {
    declare -f _specialist_key_status &>/dev/null
    assert_ok $?
  }

  it "returns empty for commands with no keys (build)" && {
    local out
    out=$(_specialist_key_status "build" 2>/dev/null)
    assert_empty "$out"
  }

  it "returns empty for commands with no keys (test)" && {
    local out
    out=$(_specialist_key_status "test" 2>/dev/null)
    assert_empty "$out"
  }

  it "maps web command to SERPER and PERPLEXITY keys" && {
    local body
    body=$(declare -f _specialist_key_status)
    echo "$body" | grep -q 'SERPER_API_KEY'
    assert_ok $?
    echo "$body" | grep -q 'PERPLEXITY_API_KEY'
    assert_ok $?
  }

  it "maps social command to platform tokens" && {
    local body
    body=$(declare -f _specialist_key_status)
    echo "$body" | grep -q 'DISCORD_BOT_TOKEN'
    assert_ok $?
    echo "$body" | grep -q 'TELEGRAM_BOT_TOKEN'
    assert_ok $?
  }

  it "maps email command to EMAIL_PROVIDER" && {
    local body
    body=$(declare -f _specialist_key_status)
    echo "$body" | grep -q 'EMAIL_PROVIDER'
    assert_ok $?
  }

  it "specialist prompt calls _specialist_key_status" && {
    local body
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

  it "evaluator uses personality-free system prompt" && {
    local body
    body=$(declare -f _agent_evaluate_completion)
    echo "$body" | grep -q 'strict task-completion evaluator'
    assert_ok $?
    echo "$body" | grep -q 'no personality'
    assert_ok $?
  }

  it "evaluator reads macro_memory file" && {
    local body
    body=$(declare -f _agent_evaluate_completion)
    echo "$body" | grep -q 'macro_file'
    assert_ok $?
    echo "$body" | grep -q 'macro_context'
    assert_ok $?
  }

  it "evaluator expects COMPLETE or INCOMPLETE verdict" && {
    local body
    body=$(declare -f _agent_evaluate_completion)
    echo "$body" | grep -q 'COMPLETE'
    assert_ok $?
    echo "$body" | grep -q 'INCOMPLETE'
    assert_ok $?
  }

  it "evaluator supports interactive mode via AGENT_EVAL_MODE" && {
    local body
    body=$(declare -f _agent_evaluate_completion)
    echo "$body" | grep -q 'AGENT_EVAL_MODE'
    assert_ok $?
    echo "$body" | grep -q 'interactive'
    assert_ok $?
  }

  it "evaluator generates summary in auto mode" && {
    local body
    body=$(declare -f _agent_evaluate_completion)
    echo "$body" | grep -q 'summary_prompt'
    assert_ok $?
  }

  it "evaluator uses LLM_SCENARIO=evaluator" && {
    local body
    body=$(declare -f _agent_evaluate_completion)
    echo "$body" | grep -q 'LLM_SCENARIO=evaluator'
    assert_ok $?
  }

  it "evaluator is called in agent_run after successful milestones" && {
    local body
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_agent_evaluate_completion'
    assert_ok $?
  }

  it "evaluator is skipped when AGENT_EVAL_MODE=disabled" && {
    local body
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'AGENT_EVAL_MODE.*!=.*disabled'
    assert_ok $?
  }

  it "evaluator only triggers when completed_milestones > 0" && {
    local body
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
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_last_success_cmd='
    assert_ok $?
  }

  it "inner loop tracks _last_success_snippet" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_last_success_snippet='
    assert_ok $?
  }

  it "inner loop updates _last_success_cmd on exit 0" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_last_success_cmd="\$cmd"'
    assert_ok $?
  }

  it "SUCCESS macro_memory entry includes timestamp" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'Step \[\$_step_ts\]'
    assert_ok $?
  }

  it "SUCCESS macro_memory entry includes ran: command" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'ran: \$_last_success_cmd'
    assert_ok $?
  }

  it "FAILED macro_memory entry includes timestamp" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep 'FAILED' | grep -q '_step_ts'
    assert_ok $?
  }

  it "CANCELLED macro_memory entry includes timestamp" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep 'CANCELLED' | grep -q '_step_ts'
    assert_ok $?
  }

  it "ABORTED macro_memory entry includes timestamp" && {
    local body
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep 'ABORTED' | grep -q '_step_ts'
    assert_ok $?
  }

  it "guided recovery macro_memory entry includes ran: command" && {
    local body
    body=$(declare -f agent_inner_loop)
    # The guided recovery writes: ran: $final_cmd (exit 0)
    echo "$body" | grep -q 'ran: \$final_cmd'
    assert_ok $?
  }

test_end
