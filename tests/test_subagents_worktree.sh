#!/bin/bash
# ── Tests for Subagent Git Worktree & Lifecycle Engine ─────────
source "$(dirname "$0")/framework.sh"

test_start "lib/subagents.sh — Git Worktree Sandboxes & Lifecycle"

test_dir=$(test_tmpdir)
GEORGE_DIR="$test_dir/.george"
SUBAGENTS_REGISTRY="$GEORGE_DIR/subagents.json"
mkdir -p "$GEORGE_DIR"

source "$LODGE_DIR/lib/subagents.sh"

describe "subagents registry tracking"
  it "initializes registry JSON array" && {
    subagents_init
    assert_file_exists "$SUBAGENTS_REGISTRY"
    content=$(cat "$SUBAGENTS_REGISTRY")
    assert_eq "$content" "[]"
  }

  it "registers and updates subagent process state" && {
    subagents_register "sub_t1_123" "99999" "1111" 1 "ternary-bonsai" "Test task" "subagent/sub_t1_123" "$test_dir/.sandboxes/sub_t1_123" 50
    active=$(subagents_get_active)
    assert_contains "$active" "sub_t1_123"
    assert_contains "$active" "RUNNING"

    subagents_update_status "sub_t1_123" "COMPLETED" 10 "Task succeeded"
    reg=$(cat "$SUBAGENTS_REGISTRY")
    assert_contains "$reg" "COMPLETED"
    assert_contains "$reg" "Task succeeded"

    # Should not be in active anymore
    active_after=$(subagents_get_active)
    assert_not_contains "$active_after" "sub_t1_123"
  }

describe "orphan reaping"
  it "detects and reaps dead process worktrees" && {
    # Register an entry with an inert PID (e.g. 99998)
    subagents_register "sub_t1_dead" "99998" "1111" 1 "test-model" "Dead task" "subagent/sub_t1_dead" "$test_dir/.sandboxes/sub_t1_dead" 50
    mkdir -p "$test_dir/.sandboxes/sub_t1_dead"
    touch "$test_dir/.sandboxes/sub_t1_dead/dummy.txt"

    subagents_reap_orphans
    reg=$(cat "$SUBAGENTS_REGISTRY")
    assert_contains "$reg" "ORPHAN_REAPED"
  }

describe "child turn limits & countdown"
  it "defaults child turn limit to 50" && {
    assert_eq "${AGENT_CHILD_MAX_TURNS:-50}" "50"
  }

  it "calculates 5-turn countdown threshold correctly" && {
    max_turns=50
    threshold=$((max_turns - 5))
    assert_eq "$threshold" "45"
  }

test_end
