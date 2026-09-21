#!/bin/bash
# ── Tests: Social Broadcast Escalation & Autonomous Issue Generation ──

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/api.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/social.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/social_blog.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mcp_server_gitea.sh" 2>/dev/null || true
source "$LODGE_DIR/commands/gitea.sh" 2>/dev/null || true

TEST_TMP=$(mktemp -d /tmp/george-social-escalation-test-XXXXXX)
export GEORGE_CONFIG_DIR="$TEST_TMP/.george"
export GEORGE_BLOG_QUEUE_DIR="$GEORGE_CONFIG_DIR/social/queue"
export GEORGE_BLOG_HISTORY_FILE="$GEORGE_CONFIG_DIR/social/blog_history.jsonl"
export GITEA_CONF="$GEORGE_CONFIG_DIR/gitea.conf"

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

# Mock subagents_spawn in unit tests to prevent spawning background LLM processes
subagents_spawn() {
    ui_step "[MOCK] Spawning subagent tier=$1 objective='${2:0:60}'"
    return 0
}

test_start "Social Broadcast Escalation & Subagent Issue Sweeper"

describe "social_escalate_broadcast_failure"

it "quarantines payload and creates structured issue record" && {
    mkdir -p "$GEORGE_BLOG_QUEUE_DIR"
    test_qf="$GEORGE_BLOG_QUEUE_DIR/test_post_1.txt"
    echo "Sample research post content for testing" > "$test_qf"

    social_escalate_broadcast_failure "test_post_1.txt" "$test_qf" "X" "Mastodon" "Thread failed at tweet 1/5: parse error"

    # Verify quarantined file exists
    assert_file_exists "$GEORGE_BLOG_QUEUE_DIR/failed/test_post_1.txt"

    # Verify local issue record was created (since Gitea offline in hermetic unit test)
    issue_count=$(ls -1 "$GEORGE_CONFIG_DIR/issues"/issue_*.md 2>/dev/null | wc -l)
    assert_gt "$issue_count" 0

    issue_content=$(cat "$GEORGE_CONFIG_DIR/issues"/issue_*.md 2>/dev/null)
    assert_contains "$issue_content" "Social Broadcast Failure Report"
    assert_contains "$issue_content" "test_post_1.txt"
    assert_contains "$issue_content" "Thread failed at tweet 1/5"
}

describe "x_thread parsing resilience"

it "x_thread parses JSON response when UI text is on stderr" && {
    # Mock x_post and x_reply that output UI to stderr and JSON to stdout
    x_post() {
        ui_ok "Posted to X (ID: 1001)" >&2
        echo '{"data":{"id":"1001","text":"tweet 1"}}'
        return 0
    }
    x_reply() {
        local in_reply_to="$1"
        ui_ok "Replied to X (ID: 1002)" >&2
        echo '{"data":{"id":"1002","text":"tweet 2"}}'
        return 0
    }

    # Run x_thread on a 2-part text that exceeds 260 characters
    test_p1="Part 1 of our sovereign research on cybernetics, deterministic state machine loops, and local models. In order to properly test thread splitting across multiple tweets, this first paragraph must contain sufficient textual content that exceeds the maximum tweet character threshold."
    test_p2="Part 2 continuing the discussion on feedback loops, register states, and automated error handling across federated networks. When a tweet fails, the system must cleanly capture diagnostic traces and file actionable forge issues for autonomous subagent remediation."
    test_thread="${test_p1}\n\n${test_p2}"
    out=$(x_thread "$test_thread" 0 2>&1)

    assert_contains "$out" "Thread published successfully"
    assert_contains "$out" "Part 1/"
    assert_contains "$out" "Part 2/"
}

describe "x_blog_sweep escalation on partial failure"

it "quarantines failed items and records partial publication" && {
    mkdir -p "$GEORGE_BLOG_QUEUE_DIR"
    post_file="$GEORGE_BLOG_QUEUE_DIR/sweep_test.txt"
    echo "Threaded blog content for sweep test" > "$post_file"

    # Mock Mastodon to succeed and X to fail
    _mastodon_instance_token() { echo "fake_masto_token"; }
    mastodon_post() { return 0; }
    _x_cookie_auth_available() { return 0; }
    x_thread() { return 1; }

    x_blog_sweep

    # Queue file should be removed from main queue and quarantined in failed/
    assert_file_not_exists "$post_file"
    assert_file_exists "$GEORGE_BLOG_QUEUE_DIR/failed/sweep_test.txt"

    # History should record partial status
    assert_file_exists "$GEORGE_BLOG_HISTORY_FILE"
    hist_content=$(cat "$GEORGE_BLOG_HISTORY_FILE")
    assert_contains "$hist_content" '"status": "partial"'
    assert_contains "$hist_content" "Mastodon"
    assert_contains "$hist_content" "X"
}

describe "cmd_gitea issues sweep"

it "sweeps open issues and reports status cleanly" && {
    # Mock gitea_issue_list returning empty
    gitea_issue_list() { echo "[]"; }
    sweep_out=$(cmd_gitea "issues sweep" 2>&1)
    assert_contains "$sweep_out" "No open issues found to sweep"
}

test_end
