#!/bin/bash
# ── Tests: Remediation Queue & Notification Configuration ─────
source "$(dirname "$0")/framework.sh"

_test_tmpdir=""

_setup_remediation() {
    _test_tmpdir=$(test_tmpdir)
    export LODGE_DIR="$_test_tmpdir"
    export GEORGE_DIR="$_test_tmpdir/.george"
    export REMEDIATION_DIR="$GEORGE_DIR/remediation"
    export REMEDIATION_QUEUE_DIR="$REMEDIATION_DIR/queue"
    export REMEDIATION_PROGRESS_DIR="$REMEDIATION_DIR/in_progress"
    export REMEDIATION_COMPLETED_DIR="$REMEDIATION_DIR/completed"
    export REMEDIATION_FAILED_DIR="$REMEDIATION_DIR/failed"
    export REMEDIATION_CONF="$REMEDIATION_DIR/notifications.conf"

    source "$HOME/blue-lodge/lib/remediation.sh"
    remediation_init
}

_teardown_remediation() {
    rm -rf "$_test_tmpdir"
}

test_start "Remediation Queue & Notification Configuration"

describe "Notification Configuration (Configurable, Not Hardcoded)"

  it "initializes without hardcoded personal addresses" && {
      _setup_remediation
      assert_file_exists "$REMEDIATION_CONF"

      # Default values must never contain hardcoded personal contacts
      assert_eq "$REMEDIATION_NOTIFY_EMAIL" ""
      assert_eq "$REMEDIATION_EMAIL_PROVIDER" "gmail"
      assert_eq "$REMEDIATION_NOTIFY_DISCORD" ""
      assert_eq "$REMEDIATION_DISCORD_SERVER" ""
      assert_eq "$REMEDIATION_NOTIFY_CHANNEL" ""
      assert_eq "$REMEDIATION_NOTIFY_ENABLED" "1"
      _teardown_remediation
  }

  it "dynamically updates, persists, and clears notification settings" && {
      _setup_remediation
      # Update settings dynamically via operator command
      remediation_notify_set "email" "operator@example.com"
      remediation_notify_set "discord" "@custom_user"
      remediation_notify_set "server" "production_server"
      remediation_notify_set "channel" "system-alerts"

      assert_eq "$REMEDIATION_NOTIFY_EMAIL" "operator@example.com"
      assert_eq "$REMEDIATION_NOTIFY_DISCORD" "@custom_user"
      assert_eq "$REMEDIATION_DISCORD_SERVER" "production_server"
      assert_eq "$REMEDIATION_NOTIFY_CHANNEL" "system-alerts"

      conf_content=$(cat "$REMEDIATION_CONF")
      assert_contains "$conf_content" "operator@example.com"
      assert_contains "$conf_content" "@custom_user"
      assert_contains "$conf_content" "production_server"
      assert_contains "$conf_content" "system-alerts"

      # Clear settings dynamically
      remediation_notify_set "email" "clear"
      assert_eq "$REMEDIATION_NOTIFY_EMAIL" ""

      # Test notification dispatch with no targets
      remediation_notify_dispatch "test_1" "Issue #1" "RESOLVED" "All clean" >/dev/null 2>&1
      _teardown_remediation
  }

describe "Remediation Task Queue"

  it "enqueues, lists, and retrieves remediation tasks" && {
      _setup_remediation
      dummy_issue="$GEORGE_DIR/issues/issue_test_01.md"
      mkdir -p "$(dirname "$dummy_issue")"
      echo "# Test Issue Title" > "$dummy_issue"
      echo "**Error Fingerprint:** [fingerprint:abcdef123456]" >> "$dummy_issue"

      tid=$(remediation_queue_add "$dummy_issue" "" "high" "Fix broken pdf parsing")

      assert_neq "$tid" ""
      assert_file_exists "$REMEDIATION_QUEUE_DIR/${tid}.json"
      assert_eq "$(jq -r '.priority' "$REMEDIATION_QUEUE_DIR/${tid}.json")" "high"
      assert_eq "$(jq -r '.fingerprint' "$REMEDIATION_QUEUE_DIR/${tid}.json")" "abcdef123456"

      next_task=$(remediation_queue_next)
      assert_eq "$next_task" "$REMEDIATION_QUEUE_DIR/${tid}.json"
      _teardown_remediation
  }

test_end
