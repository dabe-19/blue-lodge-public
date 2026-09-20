#!/bin/bash
# ── Tests for Subagent Process Stream Observability & Lifecycle ───
source "$(dirname "$0")/framework.sh"
source "$(dirname "$0")/../lib/endpoints.sh"
source "$(dirname "$0")/../lib/ui_dashboard.sh"
source "$(dirname "$0")/../lib/commands.sh"
source "$(dirname "$0")/../lib/subagents.sh"

test_start "lib/subagents.sh — Observability, Stream Logging & Deliverable Lifecycle"

test_dir=$(test_tmpdir)
GEORGE_DIR="$test_dir/.george"
SUBAGENTS_REGISTRY="$GEORGE_DIR/subagents.json"
mkdir -p "$GEORGE_DIR"

describe "subagent event logging & observability"
  it "records structured events to persistent log file" && {
    sub_id="sub_test_obs_1"
    subagents_register "$sub_id" "$$" "$$" 1 "ternary-bonsai" "Test observability" "subagent/$sub_id" "$test_dir/.sandboxes/$sub_id" 50

    _subagent_log_event "$sub_id" "SPAWN" "Tier 1 spawned"
    _subagent_log_event "$sub_id" "THOUGHT" "Analyzing task requirements"
    _subagent_log_event "$sub_id" "ACTION" "/bash echo 'hello'"
    _subagent_log_event "$sub_id" "OBSERVATION" "hello"
    _subagent_log_event "$sub_id" "RESULT" "Task finished"

    log_output=$(subagents_logs "$sub_id" 20)
    assert_contains "$log_output" "[SPAWN      ] Tier 1 spawned"
    assert_contains "$log_output" "[THOUGHT    ] Analyzing task requirements"
    assert_contains "$log_output" "[ACTION     ] /bash echo 'hello'"
    assert_contains "$log_output" "[OBSERVATION] hello"
    assert_contains "$log_output" "[RESULT     ] Task finished"
  }

describe "mock subagent execution with thought capture"
  it "captures reasoning thoughts, actions, and auto-commits deliverables" && {
    TIER2_ENABLED=1
    TIER2_URL="http://127.0.0.1:9999"
    _ENDPOINT_PROBE_CACHE[2]="0:$(date +%s)"

    # Mock curl with file counter across subshells
    curl_cnt_file="$test_dir/curl_count.txt"
    echo 0 > "$curl_cnt_file"
    curl() {
      local c
      c=$(cat "$curl_cnt_file" 2>/dev/null || echo 0)
      c=$((c + 1))
      echo "$c" > "$curl_cnt_file"
      if [ "$c" -eq 1 ]; then
        echo '{"choices":[{"message":{"content":"<think>I need to write greeting.txt</think>\nAction: /bash echo \"Hello from subagent clone\" > greeting.txt"}}]}'
      else
        echo '{"choices":[{"message":{"content":"<think>File written, now completing</think>\nAction: /respond Deliverable generated successfully."}}]}'
      fi
    }
    export -f curl

    # Run subagents_spawn
    out=$(subagents_spawn 2 "Generate greeting module" "Context" "$PWD" 5)
    assert_ok $?
    assert_contains "$out" "Deliverable generated successfully."

    # Look up spawned subagent id from registry
    latest_id=$(jq -r '.[-1].id' "$SUBAGENTS_REGISTRY")
    assert_not_empty "$latest_id"

    # Verify logs captured the <think> reasoning
    sub_logs=$(subagents_logs "$latest_id" 50)
    assert_contains "$sub_logs" "[THOUGHT    ] I need to write greeting.txt"
    assert_contains "$sub_logs" "[ACTION     ] /bash echo \"Hello from subagent clone\" > greeting.txt"
    assert_contains "$sub_logs" "[RESULT     ] Deliverable generated successfully."
    assert_contains "$sub_logs" "[FINISH     ] Status: COMPLETED"

    # Verify deliverable auto-committed in worktree and branch
    sub_diff=$(subagents_diff "$latest_id")
    assert_contains "$sub_diff" "greeting.txt"

    # Verify reap cleanly deletes worktree and branch
    reap_out=$(subagents_reap "$latest_id")
    assert_contains "$reap_out" "cleanly reaped"

    unset -f curl
  }

describe "slash command /subagents"
  it "lists subagents and displays logs via commands_dispatch" && {
    list_out=$(commands_dispatch "/subagents list" "$PWD")
    assert_ok $?
    assert_contains "$list_out" "Autonomous Subagents Registry"
    assert_contains "$list_out" "SUBAGENT ID"
  }

test_end
