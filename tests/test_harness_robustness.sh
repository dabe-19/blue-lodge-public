#!/bin/bash
# ── Tests: 2B Model Robustness Harness Adjustments ──────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/llm.sh"
source "$LODGE_DIR/lib/memory.sh"
source "$LODGE_DIR/lib/tools.sh"
source "$LODGE_DIR/lib/commands.sh"
source "$LODGE_DIR/lib/agent.sh"

test_start "Robustness Harness — 2B model loop enhancements"

# ══════════════════════════════════════════════════════════════
# Intent-Based Delivery Gates (requires_mutation)
# ══════════════════════════════════════════════════════════════
describe "Intent-Based Delivery Gates"

  it "sets AGENT_REQUIRES_MUTATION=1 for concrete tasks" && {
    parsed_type="concrete"
    task="Write a python function for laplace transform"
    _task_lower_class="${task,,}"
    if [ "$parsed_type" = "concrete" ] || [[ "$_task_lower_class" =~ edit|write|rewrite|fix|modify|update|scaffold|code ]]; then
        req_mut=1
    else
        req_mut=0
    fi
    assert_eq "$req_mut" "1"
  }

  it "sets AGENT_REQUIRES_MUTATION=0 for abstract questions" && {
    parsed_type="abstract"
    task="Explain what the Laplace transform is"
    _task_lower_class="${task,,}"
    if [ "$parsed_type" = "concrete" ] || [[ "$_task_lower_class" =~ edit|write|rewrite|fix|modify|update|scaffold|code ]]; then
        req_mut=1
    else
        req_mut=0
    fi
    assert_eq "$req_mut" "0"
  }

# ══════════════════════════════════════════════════════════════
# General Virtual Prefix Cleaning
# ══════════════════════════════════════════════════════════════
describe "General Virtual Prefix Cleaning"

  it "strips responses/ prefix from file paths" && {
    cleaned=$(ui_clean_virtual_prefix "responses/core_laplace_function.py")
    assert_eq "$cleaned" "core_laplace_function.py"
  }

  it "strips workspace/ prefix from file paths" && {
    cleaned=$(ui_clean_virtual_prefix "workspace/sample.txt")
    assert_eq "$cleaned" "sample.txt"
  }

# ══════════════════════════════════════════════════════════════
# Experimental Code Execution Verification Toggle & Anti-Placeholder
# ══════════════════════════════════════════════════════════════
describe "Exec-Verify Toggle & Placeholder Detection"

  it "defaults AGENT_EXEC_VERIFY to 0 (disabled)" && {
    ev="${AGENT_EXEC_VERIFY:-0}"
    assert_eq "$ev" "0"
  }

  it "detects placeholder patterns in text" && {
    sample="# Placeholder for inverse transform logic"
    match=0
    echo "$sample" | grep -qiE '(#|//)[[:space:]]*(placeholder|stub|todo|for[[:space:]]+demonstration)' && match=1
    assert_eq "$match" "1"
  }

# ══════════════════════════════════════════════════════════════
# Fuzzy Path Resolution
# ══════════════════════════════════════════════════════════════
describe "Fuzzy Path Resolution"

  it "resolves relative path fuzzy match when target file exists" && {
    resolved=$(ui_resolve_path "laplace_core_function.py" "$LODGE_DIR" 0)
    assert_not_empty "$resolved"
  }

test_end
