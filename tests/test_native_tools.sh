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
    # 12. Bidirectional Slash Commands
    echo "$schemas" | jq -e '.[] | select(.function.name == "slash_command_exec")' >/dev/null
    assert_ok $?
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

  it "handles unknown tool gracefully" && {
    res=$(native_tools_dispatch "call_test3" "unknown_tool_foo" '{}' "$PWD")
    content=$(echo "$res" | jq -r '.content')
    assert_contains "$content" "Unknown tool"
  }

test_end

