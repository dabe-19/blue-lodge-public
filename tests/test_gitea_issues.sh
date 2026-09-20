#!/bin/bash
# ── Tests: Sovereign Gitea Issues & Review Comments ──────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/mcp_server_gitea.sh"

test_start "lib/mcp_server_gitea.sh — Issues, Reviews & Auditing"

describe "Gitea Server Online Check"

  it "verifies Sovereign Gitea instance is online" && {
    gitea_is_online
    assert_ok $?
  }

describe "Gitea Issue Lifecycle and Comments"

  it "creates an escalation issue with labels, adds a comment, and closes it" && {
    res=$(gitea_issue_create "Automated Harness Canary Issue" "Diagnostic trace: testing swarm escalation" "escalation,blocked")
    num=$(echo "$res" | jq -r .number 2>/dev/null)
    assert_not_empty "$num"
    assert_neq "$num" "null"

    # Add an auditable comment
    cmt_res=$(gitea_issue_comment "$num" "[Tester Agent]: Verified auditable comment stream.")
    cmt_id=$(echo "$cmt_res" | jq -r .id 2>/dev/null)
    assert_not_empty "$cmt_id"
    assert_neq "$cmt_id" "null"

    # Close issue with resolution comment
    close_res=$(gitea_issue_close "$num" "[Tester Agent]: Resolved and closed.")
    closed_state=$(echo "$close_res" | jq -r .state 2>/dev/null)
    assert_eq "$closed_state" "closed"
  }

describe "Gitea PR Review Comments"

  it "submits formal Three Degrees review comments on PR #3" && {
    # PR #3 is an existing merged/closed PR in Sovereign Gitea
    review_res=$(gitea_pr_review 3 "COMMENT" "[The Tyler: Security Gate] Verified zero high-risk shell patterns.")
    review_id=$(echo "$review_res" | jq -r .id 2>/dev/null)
    assert_not_empty "$review_id"
    assert_neq "$review_id" "null"
  }

test_end
