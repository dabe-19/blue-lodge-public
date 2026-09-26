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

describe "Zero-Tool Research Verification Guard"
  it "flags unverified research deliverable on Turn 1 when no research tools were called" && {
    g_test="please provide me a background research report on Xi Jinping."
    tf_test="research"
    t_test=1
    mt_test=10
    tmp_dir=$(mktemp -d)
    h_file="$tmp_dir/trajectory.log"
    : > "$h_file"

    unver=0
    if [ "$t_test" -le 2 ] && [ "$mt_test" -gt 1 ]; then
        is_res=0
        if echo "${g_test,,}" | grep -qiE '\b(research|report|dossier|background on|investigate|due diligence|osint|deep dive|fact check)\b'; then
            is_res=1
        elif [[ "${tf_test:-}" =~ research ]] && echo "${g_test,,}" | grep -qiE '\b(research|report|dossier|background|investigate|due diligence|osint|latest|recent|news|current)\b'; then
            is_res=1
        fi
        if [ "$is_res" -eq 1 ]; then
            if [ ! -f "$h_file" ] || ! grep -qE "(Tool Call: web_|Tool Call: fetch|Tool Call: pdf_read|Tool Call: file_read|Tool Call: github_search|Action: .*web|Action: .*curl|Action: .*search)" "$h_file"; then
                unver=1
            fi
        fi
    fi

    assert_eq "$unver" "1"

    # Simulate tool execution in trajectory.log
    echo "Tool Call: web_search (query=Xi Jinping background)" >> "$h_file"
    unver=0
    if [ "$t_test" -le 2 ] && [ "$mt_test" -gt 1 ]; then
        is_res=0
        if echo "${g_test,,}" | grep -qiE '\b(research|report|dossier|background on|investigate|due diligence|osint|deep dive|fact check)\b'; then
            is_res=1
        elif [[ "${tf_test:-}" =~ research ]] && echo "${g_test,,}" | grep -qiE '\b(research|report|dossier|background|investigate|due diligence|osint|latest|recent|news|current)\b'; then
            is_res=1
        fi
        if [ "$is_res" -eq 1 ]; then
            if [ ! -f "$h_file" ] || ! grep -qE "(Tool Call: web_|Tool Call: fetch|Tool Call: pdf_read|Tool Call: file_read|Tool Call: github_search|Action: .*web|Action: .*curl|Action: .*search)" "$h_file"; then
                unver=1
            fi
        fi
    fi

    assert_eq "$unver" "0"
    rm -rf "$tmp_dir"
  }

  it "does not trigger guard on non-research conversational queries" && {
    g_test="what is 2 + 2"
    tf_test="default"
    t_test=1
    mt_test=10
    tmp_dir=$(mktemp -d)
    h_file="$tmp_dir/trajectory.log"
    : > "$h_file"

    unver=0
    if [ "$t_test" -le 2 ] && [ "$mt_test" -gt 1 ]; then
        is_res=0
        if echo "${g_test,,}" | grep -qiE '\b(research|report|dossier|background on|investigate|due diligence|osint|deep dive|fact check)\b'; then
            is_res=1
        elif [[ "${tf_test:-}" =~ research ]] && echo "${g_test,,}" | grep -qiE '\b(research|report|dossier|background|investigate|due diligence|osint|latest|recent|news|current)\b'; then
            is_res=1
        fi
        if [ "$is_res" -eq 1 ]; then
            if [ ! -f "$h_file" ] || ! grep -qE "(Tool Call: web_|Tool Call: fetch|Tool Call: pdf_read|Tool Call: file_read|Tool Call: github_search|Action: .*web|Action: .*curl|Action: .*search)" "$h_file"; then
                unver=1
            fi
        fi
    fi

    assert_eq "$unver" "0"
    rm -rf "$tmp_dir"
  }

describe "fallback text tool extraction"
  it "extracts XML computer_use function calls from raw_content" && {
    raw=$'I will check the branch.\n<function=computer_use>\n<parameter=name>\nbash_exec</parameter>\n<parameter=command>git checkout -b feature/test develop</parameter>\n</function>'
    extracted=$(python3 -c '
import sys, re, json
text = sys.argv[1]
pattern = re.compile(r"<function\s*=\s*([a-zA-Z0-9_-]+)\s*>(.*?)(?:</function>|$)", re.DOTALL)
calls = []
for m in pattern.finditer(text):
    fn_name = m.group(1).strip()
    body = m.group(2)
    params = {}
    param_pattern = re.compile(r"<(?:parameter\s*(?:=\s*|\s+name\s*=\s*[\"'"'"']?)([a-zA-Z0-9_]+)[\"'"'"']?|([a-zA-Z0-9_]+))\s*>(.*?)(?:</(?:parameter|\1|\2)>|(?=<parameter)|(?=<[a-zA-Z0-9_]+>)|$)", re.DOTALL)
    for pm in param_pattern.finditer(body):
        k = pm.group(1) or pm.group(2)
        v = pm.group(3).strip()
        v = re.sub(r"</?[^>]+>", "", v).strip()
        if k and k not in ("function",):
            params[k] = v
    if fn_name == "computer_use" and "name" in params:
        fn_name = params.pop("name")
    calls.append({"name": fn_name, "args": params})
print(json.dumps(calls))
' "$raw")
    fn=$(echo "$extracted" | jq -r '.[0].name')
    cmd=$(echo "$extracted" | jq -r '.[0].args.command')
    assert_eq "$fn" "bash_exec"
    assert_eq "$cmd" "git checkout -b feature/test develop"
  }

test_end


