#!/bin/bash
# ── Test Suite: General Failure Loop & Operational Triage ─────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/framework.sh"

describe "Operational Failure Triage & Remediation Bridge"

_setup_triage_env() {
    export REPO_ROOT="$LODGE_DIR"
    export TEST_TMP_DIR=$(mktemp -d /tmp/george-test-triage-XXXXXX)
    export GEORGE_CONFIG_DIR="$TEST_TMP_DIR/.george"
    export GEORGE_DIR="$GEORGE_CONFIG_DIR"
    export TELEMETRY_DIR="$GEORGE_CONFIG_DIR/telemetry"
    export TELEMETRY_ACTIVE_DIR="$TELEMETRY_DIR/active"
    export TELEMETRY_INCIDENTS_DIR="$TELEMETRY_DIR/incidents"
    export TELEMETRY_ARCHIVE_DIR="$TELEMETRY_DIR/archive"
    export REMEDIATION_DIR="$GEORGE_CONFIG_DIR/remediation"
    export REMEDIATION_QUEUE_DIR="$REMEDIATION_DIR/queue"
    export REMEDIATION_ACTIVE_DIR="$REMEDIATION_DIR/in_progress"
    export REMEDIATION_COMPLETED_DIR="$REMEDIATION_DIR/completed"
    export REMEDIATION_FAILED_DIR="$REMEDIATION_DIR/failed"
    mkdir -p "$GEORGE_CONFIG_DIR/issues" "$TELEMETRY_DIR" "$REMEDIATION_QUEUE_DIR" 2>/dev/null || true

    # Source dependencies from repo
    source "$REPO_ROOT/lib/telemetry.sh"
    source "$REPO_ROOT/lib/remediation.sh"
    source "$REPO_ROOT/lib/memory.sh"
}

_teardown_triage_env() {
    rm -rf "$TEST_TMP_DIR" 2>/dev/null || true
}

it "triages operational failure into tracked issue and remediation queue" && {
    _setup_triage_env

    err_trace="SMTPAuthenticationError: 535-5.7.8 Username and Password not accepted."
    issue_path=$(telemetry_triage_operational_failure \
        "email_delivery" \
        "NOTIFICATION_DISPATCH_FAILURE" \
        "SMTP Authentication Rejected" \
        "$err_trace" \
        "$TEST_TMP_DIR")

    assert_ok $?
    [ -f "$issue_path" ]
    assert_ok $?

    # Verify issue content
    issue_body=$(cat "$issue_path")
    assert_contains "$issue_body" "Autonomous Telemetry Alert"
    assert_contains "$issue_body" "SMTPAuthenticationError"
    assert_contains "$issue_body" "[fingerprint:"

    # Verify queue entry
    queue_files=("$REMEDIATION_QUEUE_DIR"/*.json)
    [ -f "${queue_files[0]}" ]
    assert_ok $?

    q_body=$(cat "${queue_files[0]}")
    assert_contains "$q_body" "SMTP Authentication Rejected"
    assert_contains "$q_body" "QUEUED"

    _teardown_triage_env
}

it "deduplicates recurring operational failures using SHA256 fingerprint" && {
    _setup_triage_env

    err_trace="ConnectionRefusedError: [Errno 111] Connection refused on 127.0.0.1:1025"
    first_issue=$(telemetry_triage_operational_failure \
        "bridge_relay" \
        "SERVICE_UNAVAILABLE" \
        "Local Bridge Connection Refused" \
        "$err_trace" \
        "$TEST_TMP_DIR")

    second_issue=$(telemetry_triage_operational_failure \
        "bridge_relay" \
        "SERVICE_UNAVAILABLE" \
        "Local Bridge Connection Refused" \
        "$err_trace" \
        "$TEST_TMP_DIR")

    # Second call returns the existing issue without creating a duplicate
    [ "$first_issue" = "$second_issue" ]
    assert_ok $?

    issue_count=$(ls -1 "$GEORGE_CONFIG_DIR/issues"/*.md | wc -l)
    [ "$issue_count" -eq 1 ]
    assert_ok $?

    queue_count=$(ls -1 "$REMEDIATION_QUEUE_DIR"/*.json | wc -l)
    [ "$queue_count" -eq 1 ]
    assert_ok $?

    _teardown_triage_env
}

it "includes Sovereign Resourcefulness in system prompt" && {
    _setup_triage_env

    constraints=$(_memory_env_constraints)
    assert_contains "$constraints" "SOVEREIGN RESOURCEFULNESS & GENERAL PATHFINDING"
    assert_contains "$constraints" "Never stop at an initial tool or provider failure"
    assert_contains "$constraints" "Survey the workspace and filesystem for alternative tools"

    _teardown_triage_env
}

test_end
