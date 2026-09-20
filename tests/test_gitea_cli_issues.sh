#!/bin/bash
# ── Tests: Sovereign Gitea Issues CLI & Query Tools ──────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/mcp_server_gitea.sh"
source "$LODGE_DIR/commands/gitea.sh"

test_start "commands/gitea.sh — Issues CLI & Query API"

describe "Gitea Server Online Check"

  it "verifies Sovereign Gitea is running" && {
    gitea_is_online
    assert_ok $?
  }

describe "Low-Level Issue Query Functions"

  it "lists issues via gitea_issue_list" && {
    list_out=$(gitea_issue_list "all")
    assert_ok $?
    assert_not_empty "$list_out"
    # Should contain issue lines formatted with #
    echo "$list_out" | grep -q "#"
    assert_ok $?
  }

  it "retrieves issue details via gitea_issue_get" && {
    issue_json=$(gitea_issue_get 5)
    assert_ok $?
    num=$(echo "$issue_json" | jq -r .number 2>/dev/null)
    assert_eq "$num" "5"
  }

describe "TUI Slash Command: /gitea issues"

  it "executes /gitea issues list without error" && {
    out=$(cmd_gitea "issues list all")
    assert_ok $?
    assert_not_empty "$out"
  }

  it "executes /gitea issues show <id>" && {
    show_out=$(cmd_gitea "issues show 5")
    assert_ok $?
    assert_not_empty "$show_out"
    echo "$show_out" | grep -q "Issue #5"
    assert_ok $?
  }

  it "creates, comments on, and closes a temporary issue via /gitea issues" && {
    # 1. Create issue
    create_out=$(cmd_gitea "issues create TUI_Canary_Issue Automated verification from /gitea issues create")
    new_id=$(echo "$create_out" | jq -r .number 2>/dev/null)
    assert_not_empty "$new_id"
    assert_neq "$new_id" "null"

    # 2. Add comment
    cmt_out=$(cmd_gitea "issues comment $new_id Operator comment from TUI harness")
    assert_ok $?
    echo "$cmt_out" | grep -q "Comment posted to Issue #${new_id}"
    assert_ok $?

    # 3. Close issue
    close_out=$(cmd_gitea "issues close $new_id Closed via TUI harness test")
    assert_ok $?
    echo "$close_out" | grep -q "Issue #${new_id} closed."
    assert_ok $?

    # 4. Verify closed state
    check_json=$(gitea_issue_get "$new_id")
    final_state=$(echo "$check_json" | jq -r .state 2>/dev/null)
    assert_eq "$final_state" "closed"
  }

test_end
