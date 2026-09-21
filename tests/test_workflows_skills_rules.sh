#!/bin/bash
# ── Tests: Workflows, Skills, and Rules Subsystems ───────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/workflows.sh"
source "$LODGE_DIR/lib/skills.sh"
source "$LODGE_DIR/lib/rules.sh"
source "$LODGE_DIR/lib/commands.sh"

test_start "Workflows, Skills, and Rules Integration Tests"

# ── Workflows Subsystem ──────────────────────────────────────────────
describe "Workflows subsystem (lib/workflows.sh)"

  _t_wf_list() {
    local list_json
    list_json=$(workflows_list "$LODGE_DIR")
    assert_ok $?
    local count
    count=$(echo "$list_json" | jq '. | length')
    [ "$count" -ge 10 ] || { echo "Expected at least 10 workflows, got $count"; return 1; }
  }
  it "discovers workflows in .agents/workflows" && _t_wf_list

  _t_wf_locate() {
    local f1 f2
    f1=$(workflows_get_file "the-architect" "$LODGE_DIR")
    f2=$(workflows_get_file "architect" "$LODGE_DIR")
    [ -f "$f1" ] || { echo "File $f1 not found"; return 1; }
    [ "$f1" = "$f2" ] || { echo "Mismatched $f1 vs $f2"; return 1; }
  }
  it "locates workflow files by short or full name" && _t_wf_locate

  _t_wf_norm() {
    local norm
    norm=$(workflows_normalize_name "dispatcher.agent")
    assert_eq "$norm" "dispatcher"
  }
  it "normalizes workflow names properly" && _t_wf_norm

# ── Skills Subsystem ─────────────────────────────────────────────────
describe "Skills subsystem (lib/skills.sh)"

  _t_skills_discover() {
    local list_json
    list_json=$(skills_list "$LODGE_DIR")
    assert_ok $?
    local count
    count=$(echo "$list_json" | jq '. | length')
    [ "$count" -ge 4 ] || { echo "Expected at least 4 skills, got $count"; return 1; }
  }
  it "discovers skills in .agents/skills" && _t_skills_discover

  _t_skills_locate() {
    local f
    f=$(skills_get_file "caveman" "$LODGE_DIR")
    [ -f "$f" ] || { echo "Caveman skill not found"; return 1; }
    local norm
    norm=$(skills_normalize_name "/grill-me")
    assert_eq "$norm" "grill-me"
  }
  it "finds caveman skill file and normalizes name" && _t_skills_locate

  _t_skills_caveman() {
    _GEORGE_CAVEMAN_MODE=0
    skills_toggle_caveman >/dev/null
    assert_eq "$_GEORGE_CAVEMAN_MODE" "1"
    skills_toggle_caveman >/dev/null
    assert_eq "$_GEORGE_CAVEMAN_MODE" "0"
  }
  it "toggles caveman mode" && _t_skills_caveman

  _t_skills_tdd() {
    _GEORGE_TDD_MODE=0
    skills_toggle_tdd >/dev/null
    assert_eq "$_GEORGE_TDD_MODE" "1"
    skills_toggle_tdd >/dev/null
    assert_eq "$_GEORGE_TDD_MODE" "0"
  }
  it "toggles tdd mode" && _t_skills_tdd

# ── Rules Subsystem ──────────────────────────────────────────────────
describe "Rules subsystem (lib/rules.sh)"

  _t_rules_list() {
    local r_json
    r_json=$(rules_list "$LODGE_DIR")
    assert_ok $?
    local count
    count=$(echo "$r_json" | jq '. | length')
    [ "$count" -ge 15 ] || { echo "Expected at least 15 rules, got $count"; return 1; }
  }
  it "recursively lists categorized rules" && _t_rules_list

  _t_rules_get() {
    local f
    f=$(rules_get_file "modern-cpp" "$LODGE_DIR")
    [ -f "$f" ] || { echo "Rule modern-cpp not found"; return 1; }
  }
  it "finds specific rule file by name" && _t_rules_get

  _t_rules_summary() {
    local summary
    summary=$(rules_summary_for_context "$LODGE_DIR")
    [[ "$summary" == *"Rule [architecture/general-patterns]"* ]] || { echo "Summary missing architecture rule"; return 1; }
  }
  it "generates summary lines for context engine" && _t_rules_summary

# ── REPL Command Integration ─────────────────────────────────────────
describe "REPL commands integration"

  _t_repl_known() {
    commands_is_known_name "workflow"
    assert_ok $?
    commands_is_known_name "skill"
    assert_ok $?
    commands_is_known_name "rules"
    assert_ok $?
    commands_is_known_name "architect"
    assert_ok $?
    commands_is_known_name "caveman"
    assert_ok $?
  }
  it "recognizes workflow, skill, and rules command names" && _t_repl_known

  _t_repl_wf_list() {
    local out
    out=$(commands_dispatch "/workflow list")
    assert_ok $?
    [[ "$out" == *"Available Agent Workflows"* ]] || { echo "Unexpected output: $out"; return 1; }
  }
  it "dispatches /workflow list successfully" && _t_repl_wf_list

  _t_repl_skill_list() {
    local out
    out=$(commands_dispatch "/skill list")
    assert_ok $?
    [[ "$out" == *"Available Skills"* ]] || { echo "Unexpected output: $out"; return 1; }
  }
  it "dispatches /skill list successfully" && _t_repl_skill_list

  _t_repl_rules_list() {
    local out
    out=$(commands_dispatch "/rules list")
    assert_ok $?
    [[ "$out" == *"Workspace Rules & Coding Standards"* ]] || { echo "Unexpected output: $out"; return 1; }
  }
  it "dispatches /rules list successfully" && _t_repl_rules_list

  _t_repl_caveman() {
    _GEORGE_CAVEMAN_MODE=0
    commands_dispatch "/caveman" >/dev/null
    assert_eq "$_GEORGE_CAVEMAN_MODE" "1"
    commands_dispatch "/caveman" >/dev/null
    assert_eq "$_GEORGE_CAVEMAN_MODE" "0"
  }
  it "dispatches /caveman toggle" && _t_repl_caveman

test_end
