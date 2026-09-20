#!/bin/bash
# ── Tests for lib/subagents.sh ───────────────────────────────────

source "$(dirname "$0")/framework.sh"
source "$(dirname "$0")/../lib/endpoints.sh"
source "$(dirname "$0")/../lib/ui_dashboard.sh"
source "$(dirname "$0")/../lib/subagents.sh"

test_start "lib/subagents.sh — Isolated Subagent Delegation"

describe "subagents_spawn parameter validation"
  it "fails when called with empty tier or objective" && {
    out=$(subagents_spawn "" "" 2>&1)
    assert_fail $?
    assert_contains "$out" "requires tier and objective"
  }

describe "subagents_spawn offline handling"
  it "returns error when target tier is offline or unreachable" && {
    # Ensure tier 2 is offline
    TIER2_ENABLED=0
    _ENDPOINT_PROBE_CACHE[2]="1:$(date +%s)"
    out=$(subagents_spawn 2 "do something" 2>&1)
    assert_fail $?
    assert_contains "$out" "offline or unreachable"
  }

describe "subagents_spawn mock execution"
  it "handles successful completion response" && {
    # Mock tier 2 as reachable
    TIER2_ENABLED=1
    TIER2_URL="http://127.0.0.1:9999"
    _ENDPOINT_PROBE_CACHE[2]="0:$(date +%s)"

    # Mock curl to return a valid completion
    curl() {
      echo '{"choices":[{"message":{"content":"Action: /respond Subagent task completed successfully."}}]}'
    }
    export -f curl

    out=$(subagents_spawn 2 "research topic" "Parent context" "$PWD" 2)
    assert_ok $?
    assert_contains "$out" "Subagent task completed successfully."

    unset -f curl
  }

test_end
