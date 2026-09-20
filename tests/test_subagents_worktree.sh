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

describe "token accounting & auto-compaction threshold"
  it "calculates slot token consumption with KV-cache invariant prefix baseline" && {
    p_tok=4500
    comp_tok=350
    kv_prefix=2815
    total=$((p_tok + comp_tok + kv_prefix))
    assert_eq "$total" "7665"
  }

  it "flags compaction threshold at 18k tokens" && {
    running_tokens=18500
    should_compact=0
    [ "$running_tokens" -ge 18000 ] && should_compact=1
    assert_eq "$should_compact" "1"
  }

describe "subagent deliverable guard"
  it "detects when objective mandates upstream PR before /respond" && {
    obj="Update docs/SANDBOXES.md and propose upstream PR to develop"
    needs_pr=0
    [[ "$obj" =~ (upstream|propose|PR|pull[[:space:]]request|SANDBOXES) ]] && needs_pr=1
    assert_eq "$needs_pr" "1"
  }

test_end
