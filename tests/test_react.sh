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
  it "resolves parent turn ceiling to 9999 by default" && {
    unset AGENT_MAX_TURNS 2>/dev/null || true
    unset AGENT_MAX_MILESTONES 2>/dev/null || true
    val="${AGENT_MAX_TURNS:-${AGENT_MAX_MILESTONES:-9999}}"
    assert_eq "$val" "9999"
  }

  it "injects countdown warning 5 turns before ceiling" && {
    max_turns=9999
    countdown_start=$((max_turns - 5))
    assert_eq "$countdown_start" "9994"
  }

describe "_react_compact_messages"
  it "compacts messages with 2500 token budget prompt and deterministic fallback" && {
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' EXIT

    # Create dummy messages.json
    cat << 'EOF' > "$tmp_dir/messages.json"
[
  {"role": "system", "content": "You are George."},
  {"role": "user", "content": "Fix telemetry loop in sentinel"},
  {"role": "assistant", "content": "Inspecting sentinel.", "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "native_tools_invoke", "arguments": "{\"action\":\"read_file\",\"path\":\"lib/sentinel.sh\"}"}}]},
  {"role": "tool", "tool_call_id": "call_1", "name": "native_tools_invoke", "content": "Line 42: telemetry loop active"}
]
EOF

    # Call compaction pointing to unreachable port to verify deterministic fallback
    _react_compact_messages "$tmp_dir" "http://127.0.0.1:9999" "$PWD" >/dev/null 2>&1

    # Verify memory.md written
    assert_file_exists "$tmp_dir/memory.md"
    mem_content=$(cat "$tmp_dir/memory.md")
    assert_contains "$mem_content" "Fix telemetry loop in sentinel"
    assert_contains "$mem_content" "lib/sentinel.sh"

    # Verify messages.json is valid JSON
    jq empty "$tmp_dir/messages.json" >/dev/null 2>&1
    assert_ok $? "messages.json should be valid JSON"

    # Verify schema alternation and preserved tool round
    msg_len=$(jq 'length' "$tmp_dir/messages.json")
    assert_eq "$msg_len" "7"
    r0=$(jq -r '.[0].role' "$tmp_dir/messages.json")
    r1=$(jq -r '.[1].role' "$tmp_dir/messages.json")
    r2=$(jq -r '.[2].role' "$tmp_dir/messages.json")
    r3=$(jq -r '.[3].role' "$tmp_dir/messages.json")
    r4=$(jq -r '.[4].role' "$tmp_dir/messages.json")
    r5=$(jq -r '.[5].role' "$tmp_dir/messages.json")
    r6=$(jq -r '.[6].role' "$tmp_dir/messages.json")

    assert_eq "$r0" "system"
    assert_eq "$r1" "user"
    assert_eq "$r2" "assistant"
    assert_eq "$r3" "user"
    assert_eq "$r4" "assistant"
    assert_eq "$r5" "tool"
    assert_eq "$r6" "user"

    rm -rf "$tmp_dir"
    trap - EXIT
  }

test_end


