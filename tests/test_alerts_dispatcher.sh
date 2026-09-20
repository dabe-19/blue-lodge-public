#!/bin/bash
# ── Tests: Multi-Tier Alerts & Notification Dispatcher ───────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/alerts.sh"

test_start "lib/alerts.sh — Swarm Multi-Tier Alerts"

describe "Alert Creation and File Persistence"

  it "creates structured alert file for Tier 1 escalation" && {
    alert_file=$(alerts_dispatch tier1 "Unit Test Tier 1" "Testing Tier 1 alert persistence" "http://localhost:3088/issue/1" '{"tool": "unit"}')
    assert_file_exists "$alert_file"
    status=$(jq -r .status "$alert_file")
    assert_eq "$status" "ACTIVE"
    tier=$(jq -r .tier "$alert_file")
    assert_eq "$tier" "tier1"
    rm -f "$alert_file"
  }

  it "creates structured alert file for Tier 3 escalation" && {
    alert_file=$(alerts_dispatch tier3 "Unit Test Tier 3" "Testing Tier 3 operator alert" "http://localhost:3088/issue/2" '{"need": "secrets"}')
    assert_file_exists "$alert_file"
    status=$(jq -r .status "$alert_file")
    assert_eq "$status" "ACTIVE"
    tier=$(jq -r .tier "$alert_file")
    assert_eq "$tier" "tier3"
    rm -f "$alert_file"
  }

describe "Alert Dismissal"

  it "dismisses an active alert" && {
    alert_file=$(alerts_dispatch tier2 "Unit Test Tier 2" "Testing dismissal" "" '{}')
    aid=$(basename "$alert_file" .json)
    alerts_dismiss "$aid"
    status=$(jq -r .status "$alert_file")
    assert_eq "$status" "DISMISSED"
    rm -f "$alert_file"
  }

test_end
