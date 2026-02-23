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

  it "agent_execute_step is defined" && {
    declare -f agent_execute_step &>/dev/null
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

# ── agent_run input validation ─────────────────────────────────
describe "agent_run input validation"

  it "fails with empty task" && {
    agent_run "" "." 2>/dev/null
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

# ── Direct slash command dispatch ─────────────────────────────
describe "Direct slash command dispatch in execute_step"

  it "agent_execute_step detects slash commands (starts with /)" && {
    local body
    body=$(declare -f agent_execute_step)
    echo "$body" | grep -q 'commands_dispatch'
    assert_ok $?
  }

  it "agent_execute_step prompt mentions slash commands" && {
    local body
    body=$(declare -f agent_execute_step)
    echo "$body" | grep -q 'Slash commands'
    assert_ok $?
  }

# ── Recursive planning config ─────────────────────────────────
describe "Recursive planning config"

  it "AGENT_MAX_DEPTH defaults to 5" && {
    assert_eq "$AGENT_MAX_DEPTH" "5"
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

  it "agent_run function body detects [SUBTASK] markers" && {
    local body
    body=$(declare -f agent_run)
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

  it "agent_plan prompt references AGENT_MAX_STEPS variable" && {
    local body
    body=$(declare -f agent_plan)
    echo "$body" | grep -q 'AGENT_MAX_STEPS'
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

# ── Error propagation ─────────────────────────────────────────
describe "Error propagation in agent_execute_step"

  it "captures stderr detail when slash command fails" && {
    local body
    body=$(declare -f agent_execute_step)
    # Should reference _cmd_stderr_file for capturing error detail
    echo "$body" | grep -q "_cmd_stderr_file\|_cmd_detail\|_SANDBOX_PREREQ_MSG"
    assert_ok $?
  }

  it "includes prereq message in _AGENT_LAST_ERROR" && {
    local body
    body=$(declare -f agent_execute_step)
    echo "$body" | grep -q "_SANDBOX_PREREQ_MSG"
    assert_ok $?
  }

  it "captures specific error not just generic 'Slash command failed'" && {
    local body
    body=$(declare -f agent_execute_step)
    # Should append detail to err_msg (the " — " separator)
    echo "$body" | grep -q '_cmd_detail'
    assert_ok $?
  }

test_end
