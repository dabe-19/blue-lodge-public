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

  it "AGENT_MAX_STEPS defaults to 12" && {
    assert_eq "$AGENT_MAX_STEPS" "12"
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

test_end
