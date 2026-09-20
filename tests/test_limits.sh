#!/bin/bash
# ── Tests: Configurable Limits & Levers Engine ───────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/limits.sh"
source "$LODGE_DIR/commands/limits.sh"

test_start "lib/limits.sh — Swarm Operational Levers"

describe "Limits Initialization and Defaults"

  it "initializes limits.conf with default values" && {
    limits_init
    test -f "$LIMITS_CONF"
    assert_ok $?
  }

  it "retrieves default MAX_REMEDIATION_ATTEMPTS as 5" && {
    val=$(limits_get MAX_REMEDIATION_ATTEMPTS)
    assert_eq "$val" "5"
  }

  it "retrieves default WATCHDOG_TIMEOUT as 300" && {
    val=$(limits_get WATCHDOG_TIMEOUT)
    assert_eq "$val" "300"
  }

describe "Modifying and Resetting Levers"

  it "updates MAX_REMEDIATION_ATTEMPTS lever to 7" && {
    limits_set MAX_REMEDIATION_ATTEMPTS 7
    val=$(limits_get MAX_REMEDIATION_ATTEMPTS)
    assert_eq "$val" "7"
  }

  it "rejects non-numeric values for numeric levers" && {
    limits_set MAX_REMEDIATION_ATTEMPTS "invalid" 2>/dev/null
    rc=$?
    assert_neq "$rc" "0"
  }

  it "resets limits to canonical defaults" && {
    limits_reset
    val=$(limits_get MAX_REMEDIATION_ATTEMPTS)
    assert_eq "$val" "5"
  }

describe "Slash Command Dispatch"

  it "executes /limits list without error" && {
    cmd_limits "list" >/dev/null
    assert_ok $?
  }

  it "executes /limits get and set" && {
    cmd_limits "set WATCHDOG_TIMEOUT 450" >/dev/null
    val=$(cmd_limits "get WATCHDOG_TIMEOUT")
    assert_eq "$val" "450"
    cmd_limits "reset" >/dev/null
  }

test_end
