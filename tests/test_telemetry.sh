#!/bin/bash
# ── Tests: lib/telemetry.sh ───────────────────────────────────
source "$(dirname "$0")/framework.sh"

_test_tmpdir=""

_setup_telemetry() {
    _test_tmpdir=$(test_tmpdir)
    export LODGE_DIR="$_test_tmpdir"
    export GEORGE_DIR="$_test_tmpdir/.george"
    export TELEMETRY_DIR="$GEORGE_DIR/telemetry"
    export TELEMETRY_ACTIVE_DIR="$TELEMETRY_DIR/active"
    export TELEMETRY_INCIDENTS_DIR="$TELEMETRY_DIR/incidents"
    export TELEMETRY_ARCHIVE_DIR="$TELEMETRY_DIR/archive"
    source "$HOME/blue-lodge/lib/telemetry.sh"
    telemetry_init
}

_teardown_telemetry() {
    rm -rf "$_test_tmpdir"
}

test_start "lib/telemetry.sh — Sovereign Telemetry & Anomaly Ring"

describe "Telemetry Core Functions & Initialization"

  it "initializes active, incident, and archive directories" && {
      _setup_telemetry
      assert_dir_exists "$TELEMETRY_ACTIVE_DIR"
      assert_dir_exists "$TELEMETRY_INCIDENTS_DIR"
      assert_dir_exists "$TELEMETRY_ARCHIVE_DIR"
      _teardown_telemetry
  }

  it "redacts API keys and sensitive tokens" && {
      _setup_telemetry
      secret_str="Testing secret: sk-1234567890abcdef and ghp_abc1234567890"
      redacted=$(telemetry_redact "$secret_str")
      assert_not_contains "$redacted" "sk-1234567890abcdef"
      assert_not_contains "$redacted" "ghp_abc1234567890"
      assert_contains "$redacted" "[REDACTED_SECRET]"
      _teardown_telemetry
  }

  it "generates deterministic 12-char error fingerprints" && {
      _setup_telemetry
      fp1=$(telemetry_fingerprint "SHELL_RUNTIME" "bash_exec" "line 95: /tmp/file: No such file or directory")
      fp2=$(telemetry_fingerprint "SHELL_RUNTIME" "bash_exec" "line 120: /tmp/file: No such file or directory")
      fp3=$(telemetry_fingerprint "CAPABILITY_DEFICIT" "pdftotext" "pdftotext: not found")

      assert_eq "$fp1" "$fp2"
      assert_eq "${#fp1}" 12
      assert_neq "$fp1" "$fp3"
      _teardown_telemetry
  }

describe "Task Lifecycle & Heartbeat"

  it "registers and tracks an active task" && {
      _setup_telemetry
      tid="task_test_123"
      telemetry_task_start "$tid" "test_task" "$_test_tmpdir" "" "0" "" >/dev/null

      active_file="$TELEMETRY_ACTIVE_DIR/${tid}.json"
      assert_file_exists "$active_file"
      assert_eq "$(jq -r '.task_id' "$active_file")" "$tid"
      assert_eq "$(jq -r '.status' "$active_file")" "RUNNING"
      _teardown_telemetry
  }

  it "updates task heartbeat, current turn, and last invoked tool" && {
      _setup_telemetry
      tid="task_hb_456"
      telemetry_task_start "$tid" "test_hb" "$_test_tmpdir" "" "0" "" >/dev/null
      telemetry_task_heartbeat "$tid" 5 "pdf_read" 200

      active_file="$TELEMETRY_ACTIVE_DIR/${tid}.json"
      assert_eq "$(jq -r '.turn' "$active_file")" "5"
      assert_eq "$(jq -r '.last_tool' "$active_file")" "pdf_read"
      assert_eq "$(jq -r '.max_turns' "$active_file")" "200"
      _teardown_telemetry
  }

  it "records anomaly events and increments failure streaks" && {
      _setup_telemetry
      tid="task_anom_789"
      telemetry_task_start "$tid" "test_anom" "$_test_tmpdir" "" "0" "" >/dev/null

      fp=$(telemetry_record_anomaly "$tid" "CAPABILITY_DEFICIT" "pdf_read" "pdftotext: not found")

      active_file="$TELEMETRY_ACTIVE_DIR/${tid}.json"
      events_file="$TELEMETRY_ACTIVE_DIR/${tid}.events.jsonl"

      assert_file_exists "$events_file"
      assert_eq "$(jq -r '.consecutive_failures' "$active_file")" "1"
      assert_eq "$(jq -r '.anomalies_count' "$active_file")" "1"

      telemetry_reset_consecutive_failures "$tid"
      assert_eq "$(jq -r '.consecutive_failures' "$active_file")" "0"
      _teardown_telemetry
  }

  it "concludes task and moves record to date-based archive" && {
      _setup_telemetry
      tid="task_end_999"
      telemetry_task_start "$tid" "test_end" "$_test_tmpdir" "" "0" "" >/dev/null
      telemetry_task_end "$tid" 0 "COMPLETED"

      assert_file_not_exists "$TELEMETRY_ACTIVE_DIR/${tid}.json"
      today=$(date '+%Y-%m-%d')
      assert_file_exists "$TELEMETRY_ARCHIVE_DIR/$today/${tid}.json"
      assert_eq "$(jq -r '.status' "$TELEMETRY_ARCHIVE_DIR/$today/${tid}.json")" "COMPLETED"
      _teardown_telemetry
  }

  it "cleans up active telemetry on abnormal exit when AGENT_ACTIVE_SESSION_ID is set" && {
      _setup_telemetry
      tid="session_interrupt_test"
      telemetry_task_start "$tid" "react" "$_test_tmpdir" "" "0" "" >/dev/null
      export AGENT_ACTIVE_SESSION_ID="$tid"

      # Simulate exit cleanup
      if [ -n "${AGENT_ACTIVE_SESSION_ID:-}" ]; then
          telemetry_task_end "$AGENT_ACTIVE_SESSION_ID" 130 "INTERRUPTED" >/dev/null 2>&1 || true
          export AGENT_ACTIVE_SESSION_ID=""
      fi

      assert_file_not_exists "$TELEMETRY_ACTIVE_DIR/${tid}.json"
      today=$(date '+%Y-%m-%d')
      assert_file_exists "$TELEMETRY_ARCHIVE_DIR/$today/${tid}.json"
      assert_eq "$(jq -r '.status' "$TELEMETRY_ARCHIVE_DIR/$today/${tid}.json")" "INTERRUPTED"
      assert_eq "$AGENT_ACTIVE_SESSION_ID" ""
      _teardown_telemetry
  }

test_end
