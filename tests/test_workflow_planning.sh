#!/bin/bash
# ── Tests: Workflow Planning & Interactive Scoping ───────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/transcript.sh"
source "$LODGE_DIR/lib/workflows.sh"
source "$LODGE_DIR/lib/native_tools.sh"

test_start "Interactive Workflow Planning & Operator Scoping"

TMP_WP_DIR=$(test_tmpdir)

describe "ui_ask_operator (lib/ui.sh)"

  it "reads piped input from non-interactive stream" && {
    ans=$(echo "Approved by George" | ui_ask_operator "Should we proceed?")
    assert_contains "$ans" "Approved by George"
  }

  it "logs questions and responses to active transcript" && {
    transcript_start "test_scope" "$TMP_WP_DIR"
    tr_path="$_TRANSCRIPT_FILE"
    echo "Decision Alpha" | ui_ask_operator "What is our architecture tradeoff?" >/dev/null
    transcript_stop
    
    test -f "$tr_path"
    assert_ok $?
    content=$(cat "$tr_path")
    assert_contains "$content" "What is our architecture tradeoff?"
    assert_contains "$content" "Decision Alpha"
  }

describe "workflow_interactive_plan (lib/workflows.sh)"

  it "runs interactive plan session with objective and context" && {
    test_mock "_workflow_run_architect" 'touch "$2/implementation_plan.md"; return 0'
    out=$(workflow_interactive_plan "Add sports model" "arXiv papers downloaded" "" "$TMP_WP_DIR" 2>&1)
    assert_ok $?
    assert_contains "$out" "George Interactive Team Scoping & Workflow Planning"
    assert_contains "$out" "Objective: Add sports model"
    assert_contains "$out" "Context: arXiv papers downloaded"
    test_unmock "_workflow_run_architect"
  }

  it "prompts operator for questions and incorporates answers" && {
    test_mock "_workflow_run_architect" 'touch "$2/implementation_plan.md"; return 0'
    test_mock "ui_ask_operator" 'echo "Use random forest with calibration"; return 0'
    out=$(workflow_interactive_plan "Tune ML" "" "Which model family should we standardize on?" "$TMP_WP_DIR" 2>&1)
    assert_ok $?
    assert_contains "$out" "Agent formulated design questions for George / Operator"
    assert_contains "$out" "Scoping Decision: Use random forest with calibration"
    test_unmock "ui_ask_operator"
    test_unmock "_workflow_run_architect"
  }

describe "Native Tool Bridge: workflow_plan & workflow_run"

  it "dispatches workflow_plan tool call and returns plan result" && {
    test_mock "_workflow_run_architect" 'touch "$2/implementation_plan.md"; echo "the-architect completed plan"; return 0'
    res=$(native_tools_dispatch "call_wp_test" "workflow_plan" '{"objective":"Implement PDF reader","context":"Use Poppler pdftotext"}' "$TMP_WP_DIR")
    assert_ok $?
    role=$(echo "$res" | jq -r '.role')
    assert_eq "$role" "tool"
    content=$(echo "$res" | jq -r '.content')
    assert_contains "$content" "George Interactive Team Scoping & Workflow Planning"
    test_unmock "_workflow_run_architect"
  }

  it "dispatches workflow_run tool call" && {
    test_mock "_workflow_run_architect" 'touch "$2/implementation_plan.md"; echo "the-architect completed plan"; return 0'
    res=$(native_tools_dispatch "call_wr_test" "workflow_run" '{"name":"the-architect","args":"Verify research standard"}' "$TMP_WP_DIR")
    assert_ok $?
    role=$(echo "$res" | jq -r '.role')
    assert_eq "$role" "tool"
    content=$(echo "$res" | jq -r '.content')
    assert_contains "$content" "architect"
    test_unmock "_workflow_run_architect"
  }

rm -rf "$TMP_WP_DIR"
test_end
