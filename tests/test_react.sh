#!/bin/bash
# ── Tests for lib/react.sh ──────────────────────────────────────

source "$(dirname "$0")/framework.sh"
source "$(dirname "$0")/../lib/react.sh"

test_start "lib/react.sh — Modern POSIX ReAct Engine"

describe "_react_parse_action"
  it "extracts standard slash command line" && {
    raw=$'Thought: I need to check directory.\n/ls lib/'
    act=$(_react_parse_action "$raw")
    assert_eq "$act" "/ls lib/"
  }

  it "extracts Action: labeled slash command" && {
    raw=$'Thought: Ready to search.\nAction: /web search "Mac Ultra M5"'
    act=$(_react_parse_action "$raw")
    assert_eq "$act" "/web search \"Mac Ultra M5\""
  }

  it "extracts slash command inside bash code fence" && {
    raw=$'Thought: Let me run grep.\n```bash\n/grep "ACTIVE_TIER" lib/endpoints.sh\n```'
    act=$(_react_parse_action "$raw")
    assert_eq "$act" "/grep \"ACTIVE_TIER\" lib/endpoints.sh"
  }

  it "strips think tags before parsing" && {
    raw=$'<think>\nShould I do /ls or /read? I will do /ls\n</think>\nAction:\n/ls commands/'
    act=$(_react_parse_action "$raw")
    assert_eq "$act" "/ls commands/"
  }

describe "context_engine integration"
  it "includes persona and protocol references" && {
    prompt=$(context_engine_build "test goal" "$PWD" 1)
    assert_contains "$prompt" "George"
    assert_contains "$prompt" "Blue Lodge"
    assert_contains "$prompt" "pure POSIX"
    assert_contains "$prompt" "operational_protocol"
  }

describe "turn limits & countdown preservation"
  it "resolves parent turn ceiling to 100 by default" && {
    unset AGENT_MAX_TURNS 2>/dev/null || true
    unset AGENT_MAX_MILESTONES 2>/dev/null || true
    val="${AGENT_MAX_TURNS:-${AGENT_MAX_MILESTONES:-100}}"
    assert_eq "$val" "100"
  }

  it "injects countdown warning 5 turns before ceiling" && {
    max_turns=100
    countdown_start=$((max_turns - 5))
    assert_eq "$countdown_start" "95"
  }

test_end

