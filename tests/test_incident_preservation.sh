#!/bin/bash
# ── Tests: Incident Preservation & Issue Deduplication ─────────
source "$(dirname "$0")/framework.sh"

_test_tmpdir=""

_setup_preservation() {
    _test_tmpdir=$(test_tmpdir)
    export LODGE_DIR="$_test_tmpdir"
    export GEORGE_DIR="$_test_tmpdir/.george"
    export TELEMETRY_DIR="$GEORGE_DIR/telemetry"
    export TELEMETRY_ACTIVE_DIR="$TELEMETRY_DIR/active"
    export TELEMETRY_INCIDENTS_DIR="$TELEMETRY_DIR/incidents"
    export TELEMETRY_ARCHIVE_DIR="$TELEMETRY_DIR/archive"
    export SENTINEL_DIR="$GEORGE_DIR/sentinel"
    export SENTINEL_STATE="$SENTINEL_DIR/state.json"
    export SENTINEL_HISTORY="$SENTINEL_DIR/history.jsonl"
    export SENTINEL_LOG="$SENTINEL_DIR/sentinel.log"

    source "$HOME/blue-lodge/lib/telemetry.sh"
    source "$HOME/blue-lodge/lib/sentinel.sh"
    telemetry_init
    sentinel_init
}

_teardown_preservation() {
    rm -rf "$_test_tmpdir"
}

test_start "Incident Preservation & Fingerprint Deduplication"

describe "Incident Preservation Dossier"

  it "snapshots full task state and artifacts into diagnostic incident folder" && {
      _setup_preservation
      tid="task_inc_001"
      art_dir="$_test_tmpdir/artifacts"
      mkdir -p "$art_dir"
      echo "Sample artifact content" > "$art_dir/test.txt"

      telemetry_task_start "$tid" "react" "$_test_tmpdir" "" "0" "" >/dev/null
      telemetry_record_anomaly "$tid" "CAPABILITY_DEFICIT" "pdftotext" "pdftotext: not found on host" >/dev/null

      inc_dir=$(telemetry_preserve_incident "$tid" "CAPABILITY_DEFICIT" "pdftotext" "Missing pdf binary" "$art_dir")

      assert_neq "$inc_dir" ""
      assert_dir_exists "$inc_dir"
      assert_file_exists "$inc_dir/task_envelope.json"
      assert_file_exists "$inc_dir/trace.jsonl"
      assert_file_exists "$inc_dir/manifest.json"
      assert_file_exists "$inc_dir/artifacts/test.txt"

      mf_fp=$(jq -r '.fingerprint' "$inc_dir/manifest.json")
      assert_eq "${#mf_fp}" 12
      _teardown_preservation
  }

describe "Issue Deduplication & Recurrence Logging"

  it "deduplicates recurring anomalies to existing issue instead of creating duplicate" && {
      _setup_preservation
      probe_json='{
          "status": "DEGRADED",
          "gpu": {"temp_c": 50, "power_w": 40, "vram_used_mb": 1000, "vram_total_mb": 12000, "util_pct": 10},
          "slots": {"slot0": {"busy": false}, "slot1": {"busy": false}},
          "anomalies": ["ORPHAN_CURL_PID_1234: test process stalled"],
          "actions_needed": []
      }'

      issue1=$(sentinel_triage_tier2 "$probe_json" "Test remediation")
      assert_file_exists "$issue1"

      # Second triage with same anomaly signature
      issue2=$(sentinel_triage_tier2 "$probe_json" "Test remediation 2")

      # Should return same issue path without creating new file
      assert_eq "$issue1" "$issue2"
      assert_contains "$(cat "$issue1")" "Recurrence"
      _teardown_preservation
  }

test_end
