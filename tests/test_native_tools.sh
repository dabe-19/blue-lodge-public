#!/bin/bash
# ── Tests for lib/native_tools.sh ─────────────────────────────────

source "$(dirname "$0")/framework.sh"
source "$(dirname "$0")/../lib/native_tools.sh"

test_start "lib/native_tools.sh — Native POSIX Tool Bridge & Schema Generator"

describe "native_tools_get_all_schemas"
  it "returns valid JSON array with all core tools" && {
    schemas=$(native_tools_get_all_schemas)
    echo "$schemas" | jq empty
    assert_ok $?
    len=$(echo "$schemas" | jq '. | length')
    [ "$len" -ge 72 ]
    assert_ok $?
  }

  it "contains required schemas across all expanded categories" && {
    schemas=$(native_tools_get_all_schemas)
    # 1. Execution & Files
    echo "$schemas" | jq -e '.[] | select(.function.name == "bash_exec")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "file_download")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "file_edit")' >/dev/null
    assert_ok $?
    # 2. Polyglot Runtimes & Git
    echo "$schemas" | jq -e '.[] | select(.function.name == "project_build")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "project_test")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "project_fix")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "project_init")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "git_clone")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "git_commit")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "git_push")' >/dev/null
    assert_ok $?
    # 3. Reflexive Intelligence
    echo "$schemas" | jq -e '.[] | select(.function.name == "reflexive_status")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "reflexive_toggle")' >/dev/null
    assert_ok $?
    # 4. Crypto Wallets
    echo "$schemas" | jq -e '.[] | select(.function.name == "wallet_status")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "crypto_send")' >/dev/null
    assert_ok $?
    # 5. Vision
    echo "$schemas" | jq -e '.[] | select(.function.name == "vision_analyze")' >/dev/null
    assert_ok $?
    # 6. Services & Sandboxes
    echo "$schemas" | jq -e '.[] | select(.function.name == "service_list")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "sandbox_create")' >/dev/null
    assert_ok $?
    # 7. Identity Backups & Cryptography
    echo "$schemas" | jq -e '.[] | select(.function.name == "backup_create")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "pgp_sign")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "gsuite_search")' >/dev/null
    assert_ok $?
    # 8. Memory & Semantic Recall
    echo "$schemas" | jq -e '.[] | select(.function.name == "memory_get_section")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "recall_search")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "journal_record")' >/dev/null
    assert_ok $?
    # 9. Model Parameters & REPL
    echo "$schemas" | jq -e '.[] | select(.function.name == "model_param_set")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "model_endpoint_status")' >/dev/null
    assert_ok $?
    # 10. MCP Management
    echo "$schemas" | jq -e '.[] | select(.function.name == "mcp_server_status")' >/dev/null
    assert_ok $?
    # 11. Comms & Swarm
    echo "$schemas" | jq -e '.[] | select(.function.name == "email_send")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "mqtt_publish")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "discord_send")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "discord_dm")' >/dev/null
    assert_ok $?
    # 12. Bidirectional Slash Commands
    echo "$schemas" | jq -e '.[] | select(.function.name == "slash_command_exec")' >/dev/null
    assert_ok $?
    # 13. AST & Operator Intelligence
    echo "$schemas" | jq -e '.[] | select(.function.name == "ask_operator")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "code_outline")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "code_symbol_get")' >/dev/null
    assert_ok $?
    echo "$schemas" | jq -e '.[] | select(.function.name == "code_validate")' >/dev/null
    assert_ok $?
  }

describe "native_tools_get_schemas"
  it "returns all schemas when filter is empty or all" && {
    all_s=$(native_tools_get_schemas)
    len_all=$(echo "$all_s" | jq '. | length')
    [ "$len_all" -ge 72 ]
    assert_ok $?

    all_explicit=$(native_tools_get_schemas "all")
    len_exp=$(echo "$all_explicit" | jq '. | length')
    assert_eq "$len_all" "$len_exp"
  }

  it "filters schemas strictly to requested comma-separated tools" && {
    scoped=$(native_tools_get_schemas "web_search, web_fetch, bash_exec")
    s_len=$(echo "$scoped" | jq '. | length')
    assert_eq "$s_len" "3"
    echo "$scoped" | jq -e '.[] | select(.function.name == "web_search")' >/dev/null
    assert_ok $?
    echo "$scoped" | jq -e '.[] | select(.function.name == "web_fetch")' >/dev/null
    assert_ok $?
    echo "$scoped" | jq -e '.[] | select(.function.name == "bash_exec")' >/dev/null
    assert_ok $?
    echo "$scoped" | jq -e '.[] | select(.function.name == "git_push")' >/dev/null
    assert_fail $?
  }

describe "native_tools_dispatch"
  it "dispatches bash_exec successfully" && {
    res=$(native_tools_dispatch "call_test1" "bash_exec" '{"command":"echo test_success"}' "$PWD")
    assert_ok $?
    role=$(echo "$res" | jq -r '.role')
    id=$(echo "$res" | jq -r '.tool_call_id')
    content=$(echo "$res" | jq -r '.content')
    assert_eq "$role" "tool"
    assert_eq "$id" "call_test1"
    assert_contains "$content" "test_success"
  }

  it "dispatches reflexive_status successfully" && {
    res=$(native_tools_dispatch "call_test_refl" "reflexive_status" '{}' "$PWD")
    assert_ok $?
    role=$(echo "$res" | jq -r '.role')
    content=$(echo "$res" | jq -r '.content')
    assert_eq "$role" "tool"
    assert_contains "$content" "Reflexive Intelligence Layer"
  }

  it "dispatches wallet_status successfully" && {
    res=$(native_tools_dispatch "call_test_wal" "wallet_status" '{}' "$PWD")
    assert_ok $?
    role=$(echo "$res" | jq -r '.role')
    content=$(echo "$res" | jq -r '.content')
    assert_eq "$role" "tool"
    assert_contains "$content" "Cryptocurrency Wallets"
  }

  it "dispatches service_list successfully" && {
    res=$(native_tools_dispatch "call_test_svc" "service_list" '{}' "$PWD")
    assert_ok $?
    role=$(echo "$res" | jq -r '.role')
    content=$(echo "$res" | jq -r '.content')
    assert_eq "$role" "tool"
    assert_contains "$content" "Registered Services"
  }

  it "dispatches slash_command_exec successfully" && {
    res=$(native_tools_dispatch "call_test_slash" "slash_command_exec" '{"command":"/help"}' "$PWD")
    assert_ok $?
    role=$(echo "$res" | jq -r '.role')
    content=$(echo "$res" | jq -r '.content')
    assert_eq "$role" "tool"
    assert_contains "$content" "Slash Commands"
  }

  it "dispatches memory_get_section successfully" && {
    res=$(native_tools_dispatch "call_test_mem" "memory_get_section" '{"section":"Project"}' "$PWD")
    assert_ok $?
    role=$(echo "$res" | jq -r '.role')
    content=$(echo "$res" | jq -r '.content')
    assert_eq "$role" "tool"
    assert_contains "$content" "workspace"
  }

  it "dispatches model_endpoint_status successfully" && {
    res=$(native_tools_dispatch "call_test_ep" "model_endpoint_status" '{}' "$PWD")
    assert_ok $?
    role=$(echo "$res" | jq -r '.role')
    assert_eq "$role" "tool"
  }

  it "dispatches file_read and handles non-existent file gracefully" && {
    res=$(native_tools_dispatch "call_test2" "file_read" '{"path":"non_existent_file_xyz.txt"}' "$PWD")
    assert_ok $?
    content=$(echo "$res" | jq -r '.content')
    assert_contains "$content" "not found"
  }

  it "dispatches backup_list successfully" && {
    res=$(native_tools_dispatch "call_test_bak" "backup_list" '{}' "$PWD")
    assert_ok $?
    role=$(echo "$res" | jq -r '.role')
    assert_eq "$role" "tool"
  }

  it "dispatches discord_send and handles DM vs channel resolution" && {
    test_mock "api_post" 'echo "{\"id\": \"test_chan_123\"}"; export _API_LAST_STATUS="200"; export _API_LAST_BODY="{\"id\": \"test_chan_123\"}"; return 0'
    test_mock "api_get_key" 'echo "fake_token"; return 0'
    test_mock "discord_channel_resolve" 'echo "235541481920659458"; return 0'
    res=$(native_tools_dispatch "call_test_ds" "discord_send" '{"target":"logic","message":"hello logic"}' "$PWD")
    assert_ok $?
    content=$(echo "$res" | jq -r '.content')
    assert_contains "$content" "Sent to Discord"
    test_unmock "discord_channel_resolve"
    test_unmock "api_get_key"
    test_unmock "api_post"
  }

  it "dispatches discord_dm and sends DM via bot API" && {
    test_mock "api_post" 'echo "{\"id\": \"dm_chan_999\"}"; export _API_LAST_STATUS="200"; export _API_LAST_BODY="{\"id\": \"dm_chan_999\"}"; return 0'
    test_mock "api_get_key" 'echo "fake_token"; return 0'
    test_mock "discord_user_resolve" 'echo "190628469053325312"; return 0'
    res=$(native_tools_dispatch "call_test_dm" "discord_dm" '{"user":"dabe","message":"hello dabe"}' "$PWD")
    assert_ok $?
    content=$(echo "$res" | jq -r '.content')
    assert_contains "$content" "Sent to Discord"
    test_unmock "discord_user_resolve"
    test_unmock "api_get_key"
    test_unmock "api_post"
  }

  it "dispatches code_outline successfully" && {
    res=$(native_tools_dispatch "call_test_co" "code_outline" '{"path":"lib/treesitter.sh"}' "$PWD")
    assert_ok $?
    content=$(echo "$res" | jq -r '.content')
    assert_contains "$content" "treesitter_outline"
  }

  it "dispatches code_symbol_get successfully" && {
    res=$(native_tools_dispatch "call_test_cs" "code_symbol_get" '{"path":"lib/treesitter.sh","symbol":"treesitter_detect_lang"}' "$PWD")
    assert_ok $?
    content=$(echo "$res" | jq -r '.content')
    assert_contains "$content" "treesitter_detect_lang() {"
  }

  it "dispatches code_validate successfully" && {
    res=$(native_tools_dispatch "call_test_cv" "code_validate" '{"content":"echo test_valid","language":"bash"}' "$PWD")
    assert_ok $?
    content=$(echo "$res" | jq -r '.content')
    assert_contains "$content" "Syntax valid"
  }

  it "dispatches ask_operator successfully" && {
    test_mock "ui_ask_operator" 'echo "Operator approved: yes"; return 0'
    res=$(native_tools_dispatch "call_test_ao" "ask_operator" '{"question":"Can I proceed?"}' "$PWD")
    assert_ok $?
    content=$(echo "$res" | jq -r '.content')
    assert_contains "$content" "Operator approved"
    test_unmock "ui_ask_operator"
  }

  it "dispatches file_grep and uses ripgrep" && {
    res=$(native_tools_dispatch "call_test_fg" "file_grep" '{"pattern":"treesitter_detect_lang","path":"lib"}' "$PWD")
    assert_ok $?
    content=$(echo "$res" | jq -r '.content')
    assert_contains "$content" "treesitter.sh"
  }

  it "handles unknown tool gracefully" && {
    res=$(native_tools_dispatch "call_test3" "unknown_tool_foo" '{}' "$PWD")
    content=$(echo "$res" | jq -r '.content')
    assert_contains "$content" "Unknown tool"
  }

  it "file_write catches and rejects invalid syntax via Tree-sitter" && {
    tmp_bad="/tmp/test_bad_$$.py"
    res=$(native_tools_dispatch "call_test_bad" "file_write" "{\"path\":\"$tmp_bad\",\"content\":\"def broken(\"}" "$PWD")
    content=$(echo "$res" | jq -r '.content')
    assert_contains "$content" "Tree-sitter AST Syntax Validation Failed"
    [ ! -f "$tmp_bad" ]
    assert_ok $? "Corrupted file should not have been written"
  }

  it "file_write succeeds on valid syntax" && {
    tmp_good="/tmp/test_good_$$.py"
    res=$(native_tools_dispatch "call_test_good" "file_write" "{\"path\":\"$tmp_good\",\"content\":\"def hello():\\n    return 42\"}" "$PWD")
    content=$(echo "$res" | jq -r '.content')
    assert_contains "$content" "Created"
    rm -f "$tmp_good"
  }


  it "file_read resolves virtual mem: handles properly" && {
    tmp_dir="/tmp/test_mem_native_$$"
    mkdir -p "$tmp_dir/.george/memories"
    cat << 'JSON' > "$tmp_dir/.george/memories/registry.json"
{
  "1": {
    "slug": "sample_note",
    "file": "sample_note.md",
    "title": "Sample Note",
    "timestamp": "2026-09-20T00:00:00"
  }
}
JSON
    echo "Sample Note Content for George" > "$tmp_dir/.george/memories/sample_note.md"
    echo "Active Task Report Body" > "$tmp_dir/.george/memories/active_task_slug.md"

    # Test reading mem:1
    res=$(LODGE_DIR="$tmp_dir" native_tools_dispatch "call_test_mem1" "file_read" '{"path":"mem:1"}' "$tmp_dir")
    assert_ok $?
    content=$(echo "$res" | jq -r '.content')
    assert_contains "$content" "Sample Note Content for George"

    # Test reading mem:active_task
    res=$(LODGE_DIR="$tmp_dir" AGENT_ACTIVE_TASK_SLUG="active_task_slug" native_tools_dispatch "call_test_mem_act" "file_read" '{"path":"mem:active_task"}' "$tmp_dir")
    assert_ok $?
    content=$(echo "$res" | jq -r '.content')
    assert_contains "$content" "Active Task Report Body"

    rm -rf "$tmp_dir"
  }

test_end

