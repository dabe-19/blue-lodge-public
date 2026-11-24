#!/bin/bash
# ── Tests: lib/core/reflexive.sh — Reflexive Intelligence Layer ────
# All subsystems default to OFF.  Tests verify toggle logic,
# heuristic behavior and retired-subsystem handling without LLM calls.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh"
source "$LODGE_DIR/lib/core/llm.sh"
source "$LODGE_DIR/lib/memory/memory.sh"
source "$LODGE_DIR/lib/tools/tools.sh"
source "$LODGE_DIR/lib/memory/journal.sh"
source "$LODGE_DIR/lib/core/agent_helpers.sh"
source "$LODGE_DIR/lib/core/reflexive.sh"

test_start "lib/core/reflexive.sh — Reflexive Intelligence Layer"

# ══════════════════════════════════════════════════════════════
# Config defaults
# ══════════════════════════════════════════════════════════════
describe "Config toggles default to OFF"

  it "REFLEXIVE_PROMPT_LEARN defaults to 0" && assert_eq "${REFLEXIVE_PROMPT_LEARN}" "0"
  it "REFLEXIVE_SELF_MODEL defaults to 0" && assert_eq "${REFLEXIVE_SELF_MODEL}" "0"

# ══════════════════════════════════════════════════════════════
# 2. Self-Improving Prompts
# ══════════════════════════════════════════════════════════════
describe "Self-Improving Prompts"

  it "reflexive_prompt_record is a no-op when disabled" && {
    REFLEXIVE_PROMPT_LEARN=0
    _REFLEXIVE_PROMPT_GRADES=()
    reflexive_prompt_record "success" "test action"
    assert_eq "${#_REFLEXIVE_PROMPT_GRADES[@]}" "0"
  }

  it "reflexive_prompt_record stores entries when enabled" && {
    REFLEXIVE_PROMPT_LEARN=1
    _REFLEXIVE_PROMPT_GRADES=()
    reflexive_prompt_record "success" "built project"
    reflexive_prompt_record "fail" "web search"
    assert_eq "${#_REFLEXIVE_PROMPT_GRADES[@]}" "2"
  }

  it "reflexive_prompt_record trims to history limit" && {
    REFLEXIVE_PROMPT_LEARN=1
    REFLEXIVE_PROMPT_HISTORY=3
    _REFLEXIVE_PROMPT_GRADES=()
    reflexive_prompt_record "success" "a1"
    reflexive_prompt_record "fail" "a2"
    reflexive_prompt_record "success" "a3"
    reflexive_prompt_record "retry" "a4"
    assert_eq "${#_REFLEXIVE_PROMPT_GRADES[@]}" "3"
    REFLEXIVE_PROMPT_HISTORY=8
  }

  it "reflexive_prompt_success_rate returns 1.0 when disabled" && { REFLEXIVE_PROMPT_LEARN=0; result=$(reflexive_prompt_success_rate); assert_eq "$result" "1.0"; }

  it "reflexive_prompt_success_rate returns 1.0 with no data" && { REFLEXIVE_PROMPT_LEARN=1; _REFLEXIVE_PROMPT_GRADES=(); result=$(reflexive_prompt_success_rate); assert_eq "$result" "1.0"; }

  it "reflexive_prompt_success_rate computes correctly" && {
    REFLEXIVE_PROMPT_LEARN=1
    _REFLEXIVE_PROMPT_GRADES=()
    reflexive_prompt_record "success" "a"
    reflexive_prompt_record "success" "b"
    reflexive_prompt_record "fail" "c"
    reflexive_prompt_record "success" "d"
    # 3/4 = 75% → "0.75"
    result=$(reflexive_prompt_success_rate)
    assert_eq "$result" "0.75"
  }

  it "reflexive_prompt_hint generates failure warning when more fails than successes" && {
    REFLEXIVE_PROMPT_LEARN=1
    _REFLEXIVE_PROMPT_GRADES=()
    reflexive_prompt_record "fail" "web search"
    reflexive_prompt_record "fail" "web search again"
    reflexive_prompt_record "fail" "still web search"
    result=$(reflexive_prompt_hint)
    assert_contains "$result" "REFLEXIVE NOTE"
    assert_contains "$result" "different strategy"
  }

  # Reset
  REFLEXIVE_PROMPT_LEARN=0
  _REFLEXIVE_PROMPT_GRADES=()

# ══════════════════════════════════════════════════════════════
# 5. Self-Model (Metacognition)
# ══════════════════════════════════════════════════════════════
describe "Self-Model (Metacognition)"

  it "reflexive_metacog_assess returns OK for normal state" && { REFLEXIVE_SELF_MODEL=1; _REFLEXIVE_LOOP_COUNTER=3; _REFLEXIVE_PROMPT_GRADES=(); result=$(reflexive_metacog_assess); assert_contains "$result" "OK"; }

  it "reflexive_metacog_assess warns on high iteration count" && { REFLEXIVE_SELF_MODEL=1; _REFLEXIVE_LOOP_COUNTER=15; result=$(reflexive_metacog_assess); assert_contains "$result" "WARNING"; assert_contains "$result" "stuck loop"; }

  # Reset
  REFLEXIVE_SELF_MODEL=0
  REFLEXIVE_METACOG_INTERVAL=4
  _REFLEXIVE_LOOP_COUNTER=0

# ══════════════════════════════════════════════════════════════
# REPL toggle interface
# ══════════════════════════════════════════════════════════════
describe "REPL toggle interface"

  it "reflexive_toggle rejects retired subsystems" && { reflexive_toggle soul on >/dev/null; assert_fail $?; reflexive_toggle speculate on >/dev/null; assert_fail $?; reflexive_toggle tokens on >/dev/null; assert_fail $?; }

  it "reflexive_toggle flips state when no argument given" && { REFLEXIVE_PROMPT_LEARN=0; reflexive_toggle prompt >/dev/null; assert_eq "$REFLEXIVE_PROMPT_LEARN" "1"; reflexive_toggle prompt >/dev/null; assert_eq "$REFLEXIVE_PROMPT_LEARN" "0"; }

  it "reflexive_toggle all on enables live subsystems" && {
    REFLEXIVE_PROMPT_LEARN=0
    REFLEXIVE_SELF_MODEL=0
    REFLEXIVE_METACOG_LLM=0
    reflexive_toggle all on >/dev/null
    assert_eq "$REFLEXIVE_PROMPT_LEARN" "1"
    assert_eq "$REFLEXIVE_SELF_MODEL" "1"
    assert_eq "$REFLEXIVE_METACOG_LLM" "1"
    reflexive_toggle all off >/dev/null
  }

  it "reflexive_toggle all off disables live subsystems" && {
    reflexive_toggle all on >/dev/null
    reflexive_toggle all off >/dev/null
    assert_eq "$REFLEXIVE_PROMPT_LEARN" "0"
    assert_eq "$REFLEXIVE_SELF_MODEL" "0"
    assert_eq "$REFLEXIVE_METACOG_LLM" "0"
  }

  it "retired legacy hooks are gone" && {
    for f in reflexive_soul_gate reflexive_speculate_next reflexive_tokens_observe reflexive_metacog_tick reflexive_pre_route reflexive_post_execute reflexive_milestone_complete; do
      ! declare -f "$f" >/dev/null || { assert_fail 0 "$f should be retired"; }
    done
    assert_ok 0
  }

  it "reflexive_toggle unknown subsystem returns error" && { reflexive_toggle bogus on >/dev/null 2>&1; assert_fail $?; }
  it "reflexive_status is defined" && assert_fn_defined "reflexive_status"
  it "reflexive_status runs without error" && { reflexive_status >/dev/null 2>&1; assert_ok $?; }

# ══════════════════════════════════════════════════════════════
# Source integration
# ══════════════════════════════════════════════════════════════
describe "Source integration"

  it "lodge sources reflexive.sh" && { grep -q 'source.*reflexive.sh' "$LODGE_DIR/lodge"; assert_ok $?; }

  it "reflexive.sh is sourced after agent_helpers.sh in lodge" && { agent_line=$(grep -n 'source.*agent_helpers.sh' "$LODGE_DIR/lodge" | head -1 | cut -d: -f1); reflex_line=$(grep -n 'source.*reflexive.sh' "$LODGE_DIR/lodge" | head -1 | cut -d: -f1); [ "$reflex_line" -gt "$agent_line" ]; assert_ok $? "reflexive.sh must be sourced after agent_helpers.sh"; }

test_end
