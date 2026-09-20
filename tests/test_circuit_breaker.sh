#!/bin/bash
# ── Tests: Subagent Circuit Breaker & Escalation Engine ───────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/subagents.sh"
source "$LODGE_DIR/commands/subagents.sh"

test_start "lib/subagents.sh — Circuit Breaker & Escalation Engine"

describe "Circuit Breaker Alert File & Status Management"

  it "creates alert file and records ESCALATED_TO_PARENT status on tripped breaker" && {
    test_id="sub_test_cb_unit"
    mkdir -p "$LODGE_DIR/.george/alerts"
    rm -f "$LODGE_DIR/.george/alerts/alert_${test_id}.json"

    # Clean any prior test entries
    subagents_init
    tmp_reg="${SUBAGENTS_REGISTRY}.tmp.$$"
    jq --arg id "$test_id" 'map(select(.id != $id))' "$SUBAGENTS_REGISTRY" > "$tmp_reg" && mv "$tmp_reg" "$SUBAGENTS_REGISTRY"

    # Seed registry with single record
    jq --arg id "$test_id" '. + [{
      id: $id,
      pid: 99999,
      parent_pid: 99998,
      tier: "1",
      model: "test-model",
      objective: "trigger circuit breaker",
      branch: "subagent/test",
      worktree_dir: "/tmp",
      log_file: "/dev/null",
      max_turns: 10,
      current_turn: 3,
      status: "RUNNING"
    }]' "$SUBAGENTS_REGISTRY" > "$tmp_reg" && mv "$tmp_reg" "$SUBAGENTS_REGISTRY"

    # Simulate circuit breaker trip
    alert_file="$LODGE_DIR/.george/alerts/alert_${test_id}.json"
    jq -n \
      --arg id "$test_id" \
      --arg tier "1" \
      --arg model "test-model" \
      --arg obj "trigger circuit breaker" \
      --arg ts "2026-09-20T12:00:00Z" \
      --argjson turn 3 \
      --argjson failures 3 \
      --arg act "/bash broken_command" \
      --arg err "command not found: broken_command" \
      --arg worktree "/tmp" \
      --arg branch "subagent/test" \
      '{
        id: $id,
        tier: $tier,
        model: $model,
        objective: $obj,
        timestamp: $ts,
        turn: $turn,
        consecutive_failures: $failures,
        failed_action: $act,
        last_error: $err,
        worktree: $worktree,
        branch: $branch,
        status: "ESCALATED_TO_PARENT"
      }' > "$alert_file"

    subagents_update_status "$test_id" "ESCALATED_TO_PARENT" 3 "Circuit breaker tripped"

    # Verify alert file exists
    assert_file_exists "$alert_file"

    # Verify status in registry
    status=$(jq -r --arg id "$test_id" '[.[] | select(.id == $id)][0].status' "$SUBAGENTS_REGISTRY")
    assert_eq "$status" "ESCALATED_TO_PARENT"

    # Test /subagents alerts command
    out=$(cmd_subagents "alerts" ".")
    assert_contains "$out" "$test_id"
    assert_contains "$out" "ESCALATED"

    # Test /subagents dismiss command
    dismiss_out=$(cmd_subagents "dismiss $test_id" ".")
    assert_contains "$dismiss_out" "Dismissed circuit breaker alert"
    assert_file_not_exists "$alert_file"

    # Clean up test entry from registry
    jq --arg id "$test_id" 'map(select(.id != $id))' "$SUBAGENTS_REGISTRY" > "$tmp_reg" && mv "$tmp_reg" "$SUBAGENTS_REGISTRY"
  }

test_end
