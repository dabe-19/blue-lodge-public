#!/bin/bash
# ── Tests for SQLite FTS5 BM25 Tool Search & Dynamic Auto-Mounting ─────

source "$(dirname "$0")/framework.sh"
source "$(dirname "$0")/../lib/native_tools.sh"

test_start "lib/native_tools.sh — SQLite FTS5 BM25 Tool Search & Composable Bundles"

describe "native_tools_fts_init"
  it "initializes SQLite FTS5 index containing all native tools" && {
    native_tools_fts_init 1
    assert_file_exists "$_LODGE_TOOLS_FTS_DB"
    count=$(sqlite3 "$_LODGE_TOOLS_FTS_DB" "SELECT count(*) FROM tools_fts;" 2>/dev/null)
    [ "$count" -ge 90 ]
    assert_ok $?
  }

describe "native_tools_resolve_profile"
  it "resolves research profile with bedrock, web, files, vision, and memory" && {
    res=$(native_tools_resolve_profile "research")
    echo "$res" | jq -e '.[] | select(.function.name == "bash_exec")' >/dev/null
    assert_ok $?
    echo "$res" | jq -e '.[] | select(.function.name == "slash_command_exec")' >/dev/null
    assert_ok $?
    echo "$res" | jq -e '.[] | select(.function.name == "tool_search")' >/dev/null
    assert_ok $?
    echo "$res" | jq -e '.[] | select(.function.name == "web_search")' >/dev/null
    assert_ok $?
    echo "$res" | jq -e '.[] | select(.function.name == "vision_analyze")' >/dev/null
    assert_ok $?
    # Ensure git tools not in initial research profile
    echo "$res" | jq -e '.[] | select(.function.name == "git_push")' >/dev/null
    assert_fail $?
  }

  it "resolves code profile with files, code, and git" && {
    res=$(native_tools_resolve_profile "code")
    echo "$res" | jq -e '.[] | select(.function.name == "bash_exec")' >/dev/null
    assert_ok $?
    echo "$res" | jq -e '.[] | select(.function.name == "git_commit")' >/dev/null
    assert_ok $?
    echo "$res" | jq -e '.[] | select(.function.name == "project_build")' >/dev/null
    assert_ok $?
  }

  it "resolves default profile to lightweight 18-tool working set" && {
    res=$(native_tools_resolve_profile "default")
    len=$(echo "$res" | jq '. | length')
    [ "$len" -le 24 ]
    assert_ok $?
    [ "$len" -ge 15 ]
    assert_ok $?
    echo "$res" | jq -e '.[] | select(.function.name == "git_commit")' >/dev/null
    assert_ok $?
    echo "$res" | jq -e '.[] | select(.function.name == "web_search")' >/dev/null
    assert_ok $?
    # Ensure empty string resolves to default
    res_empty=$(native_tools_resolve_profile "")
    len_empty=$(echo "$res_empty" | jq '. | length')
    [ "$len_empty" -eq "$len" ]
    assert_ok $?
  }

describe "native_tools_search direct bundle lookup"
  it "attaches bundle directly when queried by bundle name" && {
    tmp_dir=$(mktemp -d /tmp/test_fts_XXXXXX)
    out=$(native_tools_search "+git" "$tmp_dir" 24)
    assert_contains "$out" "Attached bundle '+git'"
    assert_file_exists "$tmp_dir/active_tools.json"
    len=$(jq '. | length' "$tmp_dir/active_tools.json")
    [ "$len" -ge 5 ]
    assert_ok $?
    jq -e '.[] | select(.function.name == "git_commit")' "$tmp_dir/active_tools.json" >/dev/null
    assert_ok $?
    rm -rf "$tmp_dir"
  }

describe "native_tools_search BM25 semantic query"
  it "matches +social bundle for discord notification query" && {
    tmp_dir=$(mktemp -d /tmp/test_fts_XXXXXX)
    out=$(native_tools_search "send alert notification to discord channel" "$tmp_dir" 24)
    assert_contains "$out" "Attached bundle '+social'"
    jq -e '.[] | select(.function.name == "discord_send")' "$tmp_dir/active_tools.json" >/dev/null
    assert_ok $?
    rm -rf "$tmp_dir"
  }

  it "matches +web bundle for academic arxiv search query" && {
    tmp_dir=$(mktemp -d /tmp/test_fts_XXXXXX)
    out=$(native_tools_search "search research papers on arxiv" "$tmp_dir" 24)
    assert_contains "$out" "Attached bundle '+web'"
    jq -e '.[] | select(.function.name == "web_search")' "$tmp_dir/active_tools.json" >/dev/null
    assert_ok $?
    rm -rf "$tmp_dir"
  }

describe "native_tools_search 24-tool ceiling & LRU eviction"
  it "enforces 24-tool ceiling and evicts inactive bundles while preserving bedrock" && {
    tmp_dir=$(mktemp -d /tmp/test_fts_XXXXXX)
    # Seed session with Bedrock + Files + Web + Git (17 tools)
    native_tools_resolve_profile "bedrock, +files, +web, +git" > "$tmp_dir/active_tools.json"
    initial_count=$(jq '. | length' "$tmp_dir/active_tools.json")
    [ "$initial_count" -ge 15 ]
    assert_ok $?

    # Simulate activity in trajectory.log: web and files were called, git was never called
    cat << 'EOF' > "$tmp_dir/trajectory.log"
Tool Call: web_search ({"query":"quantum computing"})
Tool Call: file_write ({"path":"notes.md"})
Tool Call: web_fetch ({"url":"https://arxiv.org"})
EOF

    # Now attach +ops (13 tools) which would push count to ~30, exceeding 24!
    out=$(native_tools_search "+ops" "$tmp_dir" 24)
    assert_contains "$out" "Attached bundle '+ops'"
    assert_contains "$out" "Pruned inactive bundle"

    final_count=$(jq '. | length' "$tmp_dir/active_tools.json")
    [ "$final_count" -le 24 ]
    assert_ok $?

    # Verify Bedrock tools remained untouched
    jq -e '.[] | select(.function.name == "bash_exec")' "$tmp_dir/active_tools.json" >/dev/null
    assert_ok $?
    jq -e '.[] | select(.function.name == "slash_command_exec")' "$tmp_dir/active_tools.json" >/dev/null
    assert_ok $?
    jq -e '.[] | select(.function.name == "tool_search")' "$tmp_dir/active_tools.json" >/dev/null
    assert_ok $?

    rm -rf "$tmp_dir"
  }

describe "native_tools_dispatch tool_search"
  it "dispatches tool_search and returns OpenAI tool message JSON" && {
    tmp_dir=$(mktemp -d /tmp/test_fts_XXXXXX)
    export AGENT_ACTIVE_SESSION_DIR="$tmp_dir"
    resp=$(native_tools_dispatch "call_999" "tool_search" '{"query":"+vision"}' "$PWD")
    echo "$resp" | jq -e '.role == "tool"' >/dev/null
    assert_ok $?
    echo "$resp" | jq -e '.tool_call_id == "call_999"' >/dev/null
    assert_ok $?
    echo "$resp" | jq -r '.content' | grep -q "Attached bundle '+vision'"
    assert_ok $?
    rm -rf "$tmp_dir"
  }

test_end
