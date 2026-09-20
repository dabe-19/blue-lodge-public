#!/bin/bash
# ── Tests: Boot Reaper, Quarantine Preservation & Pruning ────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/subagents.sh"
source "$LODGE_DIR/commands/subagents.sh"

test_start "lib/subagents.sh — Sanitation, Reaper & Crash Recovery"

describe "Boot-Time Orphan Reaper"

  it "detects and reaps dead RUNNING process on init" && {
    dead_id="sub_test_dead_orphan_1"
    subagents_init

    # Register fake dead running subagent with PID 99991
    subagents_register "$dead_id" 99991 99990 "1" "test-model" "dead process test" "subagent/$dead_id" "/tmp/$dead_id" 10

    # Run reaper
    subagents_reap_orphans

    # Check status
    st=$(jq -r --arg id "$dead_id" '[.[] | select(.id == $id)][0].status' "$SUBAGENTS_REGISTRY")
    assert_eq "$st" "ORPHAN_REAPED"

    # Clean up test entry
    tmp_reg="${SUBAGENTS_REGISTRY}.tmp.$$"
    jq --arg id "$dead_id" 'map(select(.id != $id))' "$SUBAGENTS_REGISTRY" > "$tmp_reg" && mv "$tmp_reg" "$SUBAGENTS_REGISTRY"
  }

  it "preserves PAUSED_BLOCKED quarantined worker without reaping" && {
    blocked_id="sub_test_paused_blocked_1"
    subagents_init

    # Register fake PAUSED_BLOCKED worker with PID 99992
    subagents_register "$blocked_id" 99992 99990 "1" "test-model" "paused blocked test" "checkpoint/$blocked_id" "/tmp/$blocked_id" 10
    subagents_update_status "$blocked_id" "PAUSED_BLOCKED" 2 "Quarantined at checkpoint"

    # Run reaper
    subagents_reap_orphans

    # Status must STILL be PAUSED_BLOCKED
    st=$(jq -r --arg id "$blocked_id" '[.[] | select(.id == $id)][0].status' "$SUBAGENTS_REGISTRY")
    assert_eq "$st" "PAUSED_BLOCKED"

    # Clean up test entry
    tmp_reg="${SUBAGENTS_REGISTRY}.tmp.$$"
    jq --arg id "$blocked_id" 'map(select(.id != $id))' "$SUBAGENTS_REGISTRY" > "$tmp_reg" && mv "$tmp_reg" "$SUBAGENTS_REGISTRY"
  }

describe "Worktree Pruning Command"

  it "executes /subagents prune without error" && {
    cmd_subagents "prune" >/dev/null
    assert_ok $?
  }

test_end
