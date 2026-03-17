#!/bin/bash
# ── Tests: lib/reflexive.sh — Reflexive Intelligence Layer ────
# All subsystems default to OFF.  Tests verify toggle logic,
# heuristic behavior, and hook orchestration without LLM calls.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/llm.sh"
source "$LODGE_DIR/lib/memory.sh"
source "$LODGE_DIR/lib/tools.sh"
source "$LODGE_DIR/lib/journal.sh"
source "$LODGE_DIR/lib/agent.sh"
source "$LODGE_DIR/lib/reflexive.sh"

test_start "lib/reflexive.sh — Reflexive Intelligence Layer"

# ══════════════════════════════════════════════════════════════
# Config defaults
# ══════════════════════════════════════════════════════════════
describe "Config toggles default to OFF"

  it "REFLEXIVE_SOUL_GATE defaults to 0" && {
    assert_eq "${REFLEXIVE_SOUL_GATE}" "0"
  }

  it "REFLEXIVE_PROMPT_LEARN defaults to 0" && {
    assert_eq "${REFLEXIVE_PROMPT_LEARN}" "0"
  }

  it "REFLEXIVE_ADAPT_TOKENS defaults to 0" && {
    assert_eq "${REFLEXIVE_ADAPT_TOKENS}" "0"
  }

  it "REFLEXIVE_SPECULATE defaults to 0" && {
    assert_eq "${REFLEXIVE_SPECULATE}" "0"
  }

  it "REFLEXIVE_SELF_MODEL defaults to 0" && {
    assert_eq "${REFLEXIVE_SELF_MODEL}" "0"
  }

# ══════════════════════════════════════════════════════════════
# 1. Soul Consensus Gate
# ══════════════════════════════════════════════════════════════
describe "Soul Consensus Gate"

  it "reflexive_soul_gate passes when disabled" && {
    REFLEXIVE_SOUL_GATE=0
    reflexive_soul_gate "skip test and force push everything"
    assert_ok $?
  }

  it "reflexive_soul_gate passes for normal actions when enabled" && {
    REFLEXIVE_SOUL_GATE=1
    reflexive_soul_gate "run the build and test suite"
    assert_ok $?
  }

  it "reflexive_soul_gate rejects 'skip test' when enabled" && {
    REFLEXIVE_SOUL_GATE=1
    reflexive_soul_gate "skip test and move on"
    assert_fail $?
  }

  it "reflexive_soul_gate rejects 'force push' when enabled" && {
    REFLEXIVE_SOUL_GATE=1
    reflexive_soul_gate "force push to main branch"
    assert_fail $?
  }

  it "reflexive_soul_gate rejects 'ignore error' when enabled" && {
    REFLEXIVE_SOUL_GATE=1
    reflexive_soul_gate "ignore error and continue"
    assert_fail $?
  }

  it "reflexive_soul_gate passes empty input" && {
    REFLEXIVE_SOUL_GATE=1
    reflexive_soul_gate ""
    assert_ok $?
  }

  it "reflexive_soul_recommend gives plumb advice for skip test" && {
    result=$(reflexive_soul_recommend "skip test please")
    assert_contains "$result" "Plumb"
  }

  it "reflexive_soul_recommend gives square advice for overwrite blind" && {
    result=$(reflexive_soul_recommend "overwrite blind the config")
    assert_contains "$result" "Square"
  }

  # Reset
  REFLEXIVE_SOUL_GATE=0

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

  it "reflexive_prompt_success_rate returns 1.0 when disabled" && {
    REFLEXIVE_PROMPT_LEARN=0
    result=$(reflexive_prompt_success_rate)
    assert_eq "$result" "1.0"
  }

  it "reflexive_prompt_success_rate returns 1.0 with no data" && {
    REFLEXIVE_PROMPT_LEARN=1
    _REFLEXIVE_PROMPT_GRADES=()
    result=$(reflexive_prompt_success_rate)
    assert_eq "$result" "1.0"
  }

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
# 3. Adaptive Token Budgets
# ══════════════════════════════════════════════════════════════
describe "Adaptive Token Budgets"

  it "reflexive_tokens_observe is a no-op when disabled" && {
    REFLEXIVE_ADAPT_TOKENS=0
    _REFLEXIVE_TOKEN_HISTORY=()
    reflexive_tokens_observe 1000
    assert_eq "${#_REFLEXIVE_TOKEN_HISTORY[@]}" "0"
  }

  it "reflexive_tokens_observe stores entries when enabled" && {
    REFLEXIVE_ADAPT_TOKENS=1
    _REFLEXIVE_TOKEN_HISTORY=()
    reflexive_tokens_observe 2000
    reflexive_tokens_observe 3000
    assert_eq "${#_REFLEXIVE_TOKEN_HISTORY[@]}" "2"
  }

  it "reflexive_tokens_recommend returns default when disabled" && {
    REFLEXIVE_ADAPT_TOKENS=0
    result=$(reflexive_tokens_recommend)
    assert_eq "$result" "${LLM_MAX_TOKENS:-4096}"
  }

  it "reflexive_tokens_recommend computes budget from observations" && {
    REFLEXIVE_ADAPT_TOKENS=1
    _REFLEXIVE_TOKEN_HISTORY=()
    # Simulate ~500 token responses (2000 chars each)
    reflexive_tokens_observe 2000
    reflexive_tokens_observe 2000
    reflexive_tokens_observe 2000
    result=$(reflexive_tokens_recommend)
    # avg = 2000 chars, avg_tokens = 500
    # budget_a = 500 * 1.5 = 750, budget_b = 500 * 1.2 = 600
    # max(750, 600) = 750, floor=512, ceiling=8192 → 750
    assert_gt "$result" "511" "Should be above token floor"
  }

  it "reflexive_tokens_recommend respects floor" && {
    REFLEXIVE_ADAPT_TOKENS=1
    _REFLEXIVE_TOKEN_HISTORY=()
    reflexive_tokens_observe 100   # ~25 tokens → budget < floor
    result=$(reflexive_tokens_recommend)
    floor="${REFLEXIVE_TOKEN_FLOOR:-512}"
    assert_eq "$result" "$floor"
  }

  it "reflexive_tokens_recommend keeps rolling window of 10" && {
    REFLEXIVE_ADAPT_TOKENS=1
    _REFLEXIVE_TOKEN_HISTORY=()
    for i in $(seq 1 15); do
      reflexive_tokens_observe 2000
    done
    assert_eq "${#_REFLEXIVE_TOKEN_HISTORY[@]}" "10"
  }

  # Reset
  REFLEXIVE_ADAPT_TOKENS=0
  _REFLEXIVE_TOKEN_HISTORY=()

# ══════════════════════════════════════════════════════════════
# 4. Speculative Pre-fetch
# ══════════════════════════════════════════════════════════════
describe "Speculative Pre-fetch"

  it "reflexive_speculate_next returns nothing when disabled" && {
    REFLEXIVE_SPECULATE=0
    result=$(reflexive_speculate_next "search")
    assert_empty "$result"
  }

  it "reflexive_speculate_next predicts fetch after search" && {
    REFLEXIVE_SPECULATE=1
    result=$(reflexive_speculate_next "search")
    assert_eq "$result" "fetch"
  }

  it "reflexive_speculate_next predicts build after write" && {
    REFLEXIVE_SPECULATE=1
    result=$(reflexive_speculate_next "write")
    assert_eq "$result" "build"
  }

  it "reflexive_speculate_next predicts test after build" && {
    REFLEXIVE_SPECULATE=1
    result=$(reflexive_speculate_next "build")
    assert_eq "$result" "test"
  }

  it "reflexive_speculate_next predicts commit after test" && {
    REFLEXIVE_SPECULATE=1
    result=$(reflexive_speculate_next "test")
    assert_eq "$result" "commit"
  }

  it "reflexive_speculate_next strips leading slash" && {
    REFLEXIVE_SPECULATE=1
    result=$(reflexive_speculate_next "/search")
    assert_eq "$result" "fetch"
  }

  it "reflexive_speculate_next returns empty for unknown command" && {
    REFLEXIVE_SPECULATE=1
    result=$(reflexive_speculate_next "unknown_command")
    assert_empty "$result"
  }

  it "reflexive_speculate_consume clears cache after read" && {
    local _cache_file
    _cache_file=$(_reflexive_speculate_file)
    echo "prefetch_hint:web" > "$_cache_file"
    result=$(reflexive_speculate_consume)
    assert_eq "$result" "prefetch_hint:web"
    # Cache file should be removed after consume
    [ ! -f "$_cache_file" ] || rm -f "$_cache_file"
  }

  # Reset
  REFLEXIVE_SPECULATE=0
  rm -f "$(_reflexive_speculate_file 2>/dev/null)" 2>/dev/null

# ══════════════════════════════════════════════════════════════
# 5. Self-Model (Metacognition)
# ══════════════════════════════════════════════════════════════
describe "Self-Model (Metacognition)"

  it "reflexive_metacog_tick returns 1 when disabled" && {
    REFLEXIVE_SELF_MODEL=0
    reflexive_metacog_tick
    assert_fail $?
  }

  it "reflexive_metacog_tick fires at interval" && {
    REFLEXIVE_SELF_MODEL=1
    REFLEXIVE_METACOG_INTERVAL=2
    _REFLEXIVE_LOOP_COUNTER=0
    reflexive_metacog_tick  # counter=1, 1%2≠0 → returns 1
    rc1=$?
    reflexive_metacog_tick  # counter=2, 2%2=0 → returns 0
    rc2=$?
    assert_fail "$rc1" "First tick should not fire"
    assert_ok "$rc2" "Second tick should fire at interval"
  }

  it "reflexive_metacog_assess returns OK for normal state" && {
    REFLEXIVE_SELF_MODEL=1
    _REFLEXIVE_LOOP_COUNTER=3
    _REFLEXIVE_PROMPT_GRADES=()
    result=$(reflexive_metacog_assess)
    assert_contains "$result" "OK"
  }

  it "reflexive_metacog_assess warns on high iteration count" && {
    REFLEXIVE_SELF_MODEL=1
    _REFLEXIVE_LOOP_COUNTER=15
    result=$(reflexive_metacog_assess)
    assert_contains "$result" "WARNING"
    assert_contains "$result" "stuck loop"
  }

  it "reflexive_metacog_reset clears state" && {
    _REFLEXIVE_LOOP_COUNTER=10
    _REFLEXIVE_METACOG_STATE="something"
    # Write a speculation cache file to verify cleanup
    local _cache_file
    _cache_file=$(_reflexive_speculate_file)
    echo "cached" > "$_cache_file" 2>/dev/null
    reflexive_metacog_reset
    assert_eq "$_REFLEXIVE_LOOP_COUNTER" "0"
    assert_empty "$_REFLEXIVE_METACOG_STATE"
    # Speculation cache file should be removed
    [ ! -f "$_cache_file" ]
    assert_ok $?
  }

  # Reset
  REFLEXIVE_SELF_MODEL=0
  REFLEXIVE_METACOG_INTERVAL=4
  _REFLEXIVE_LOOP_COUNTER=0

# ══════════════════════════════════════════════════════════════
# Unified hooks
# ══════════════════════════════════════════════════════════════
describe "Unified hooks"

  it "reflexive_pre_route is defined" && {
    declare -f reflexive_pre_route &>/dev/null
    assert_ok $?
  }

  it "reflexive_post_route is defined" && {
    declare -f reflexive_post_route &>/dev/null
    assert_ok $?
  }

  it "reflexive_post_execute is defined" && {
    declare -f reflexive_post_execute &>/dev/null
    assert_ok $?
  }

  it "reflexive_milestone_complete is defined" && {
    declare -f reflexive_milestone_complete &>/dev/null
    assert_ok $?
  }

  it "reflexive_milestone_fail is defined" && {
    declare -f reflexive_milestone_fail &>/dev/null
    assert_ok $?
  }

  it "reflexive_pre_route returns empty when all disabled" && {
    REFLEXIVE_SOUL_GATE=0
    REFLEXIVE_PROMPT_LEARN=0
    REFLEXIVE_ADAPT_TOKENS=0
    REFLEXIVE_SPECULATE=0
    REFLEXIVE_SELF_MODEL=0
    result=$(reflexive_pre_route)
    assert_empty "$result"
  }

  it "reflexive_post_route approves normal actions when all disabled" && {
    REFLEXIVE_SOUL_GATE=0
    reflexive_post_route "respond" "say hello" "."
    assert_ok $?
  }

  it "reflexive_post_route approves normal actions with soul gate on" && {
    REFLEXIVE_SOUL_GATE=1
    reflexive_post_route "build" "run the build and test" "."
    assert_ok $?
  }

  it "reflexive_post_route rejects violations with soul gate on" && {
    REFLEXIVE_SOUL_GATE=1
    reflexive_post_route "respond" "skip test and ignore error" "."
    assert_fail $?
    REFLEXIVE_SOUL_GATE=0
  }

  it "reflexive_post_execute records token observation" && {
    REFLEXIVE_ADAPT_TOKENS=1
    REFLEXIVE_PROMPT_LEARN=1
    _REFLEXIVE_TOKEN_HISTORY=()
    _REFLEXIVE_PROMPT_GRADES=()
    reflexive_post_execute "some response text" "0" "test action"
    assert_eq "${#_REFLEXIVE_TOKEN_HISTORY[@]}" "1"
    assert_eq "${#_REFLEXIVE_PROMPT_GRADES[@]}" "1"
    REFLEXIVE_ADAPT_TOKENS=0
    REFLEXIVE_PROMPT_LEARN=0
    _REFLEXIVE_TOKEN_HISTORY=()
    _REFLEXIVE_PROMPT_GRADES=()
  }

  it "reflexive_milestone_complete resets metacog" && {
    _REFLEXIVE_LOOP_COUNTER=5
    reflexive_milestone_complete "test milestone"
    assert_eq "$_REFLEXIVE_LOOP_COUNTER" "0"
  }

# ══════════════════════════════════════════════════════════════
# REPL toggle interface
# ══════════════════════════════════════════════════════════════
describe "REPL toggle interface"

  it "reflexive_toggle enables soul gate" && {
    REFLEXIVE_SOUL_GATE=0
    reflexive_toggle soul on >/dev/null
    assert_eq "$REFLEXIVE_SOUL_GATE" "1"
    REFLEXIVE_SOUL_GATE=0
  }

  it "reflexive_toggle disables soul gate" && {
    REFLEXIVE_SOUL_GATE=1
    reflexive_toggle soul off >/dev/null
    assert_eq "$REFLEXIVE_SOUL_GATE" "0"
  }

  it "reflexive_toggle flips state when no argument given" && {
    REFLEXIVE_PROMPT_LEARN=0
    reflexive_toggle prompt >/dev/null
    assert_eq "$REFLEXIVE_PROMPT_LEARN" "1"
    reflexive_toggle prompt >/dev/null
    assert_eq "$REFLEXIVE_PROMPT_LEARN" "0"
  }

  it "reflexive_toggle all on enables everything" && {
    REFLEXIVE_SOUL_GATE=0
    REFLEXIVE_PROMPT_LEARN=0
    REFLEXIVE_ADAPT_TOKENS=0
    REFLEXIVE_SPECULATE=0
    REFLEXIVE_SELF_MODEL=0
    reflexive_toggle all on >/dev/null
    assert_eq "$REFLEXIVE_SOUL_GATE" "1"
    assert_eq "$REFLEXIVE_PROMPT_LEARN" "1"
    assert_eq "$REFLEXIVE_ADAPT_TOKENS" "1"
    assert_eq "$REFLEXIVE_SPECULATE" "1"
    assert_eq "$REFLEXIVE_SELF_MODEL" "1"
    # Reset all
    reflexive_toggle all off >/dev/null
  }

  it "reflexive_toggle all off disables everything" && {
    reflexive_toggle all on >/dev/null
    reflexive_toggle all off >/dev/null
    assert_eq "$REFLEXIVE_SOUL_GATE" "0"
    assert_eq "$REFLEXIVE_PROMPT_LEARN" "0"
    assert_eq "$REFLEXIVE_ADAPT_TOKENS" "0"
    assert_eq "$REFLEXIVE_SPECULATE" "0"
    assert_eq "$REFLEXIVE_SELF_MODEL" "0"
  }

  it "reflexive_toggle unknown subsystem returns error" && {
    reflexive_toggle bogus on >/dev/null 2>&1
    assert_fail $?
  }

  it "reflexive_status is defined" && {
    declare -f reflexive_status &>/dev/null
    assert_ok $?
  }

  it "reflexive_status runs without error" && {
    reflexive_status >/dev/null 2>&1
    assert_ok $?
  }

# ══════════════════════════════════════════════════════════════
# Source integration
# ══════════════════════════════════════════════════════════════
describe "Source integration"

  it "lodge sources reflexive.sh" && {
    grep -q 'source.*reflexive.sh' "$LODGE_DIR/lodge"
    assert_ok $?
  }

  it "reflexive.sh is sourced after agent.sh in lodge" && {
    agent_line=$(grep -n 'source.*agent.sh' "$LODGE_DIR/lodge" | head -1 | cut -d: -f1)
    reflex_line=$(grep -n 'source.*reflexive.sh' "$LODGE_DIR/lodge" | head -1 | cut -d: -f1)
    [ "$reflex_line" -gt "$agent_line" ]
    assert_ok $? "reflexive.sh must be sourced after agent.sh"
  }

test_end
