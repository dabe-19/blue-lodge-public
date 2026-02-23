#!/bin/bash
# ── Tests: lib/phone.sh ───────────────────────────────────────
# Phone integration: location, SMS, telephony, WiFi, call log.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/phone.sh"

# Enable the Termux API gate for testing.
# Tests that check graceful fallback expect phone_api_call to reach
# the "command not found" check rather than stopping at the opt-in gate.
export LODGE_TERMUX_API=1

_test_out=""

test_start "lib/phone.sh — Phone Integration (Termux API)"

# ═══════════════════════════════════════════════════════════════
# Function existence
# ═══════════════════════════════════════════════════════════════
describe "Core functions"

  it "phone_available is defined" && {
    declare -f phone_available &>/dev/null
    assert_ok $?
  }

  it "phone_check is defined" && {
    declare -f phone_check &>/dev/null
    assert_ok $?
  }

  it "phone_location is defined" && {
    declare -f phone_location &>/dev/null
    assert_ok $?
  }

  it "phone_location_summary is defined" && {
    declare -f phone_location_summary &>/dev/null
    assert_ok $?
  }

  it "phone_location_context is defined" && {
    declare -f phone_location_context &>/dev/null
    assert_ok $?
  }

  it "phone_sms_list is defined" && {
    declare -f phone_sms_list &>/dev/null
    assert_ok $?
  }

  it "phone_sms_pretty is defined" && {
    declare -f phone_sms_pretty &>/dev/null
    assert_ok $?
  }

  it "phone_sms_send is defined" && {
    declare -f phone_sms_send &>/dev/null
    assert_ok $?
  }

  it "phone_telephony_info is defined" && {
    declare -f phone_telephony_info &>/dev/null
    assert_ok $?
  }

  it "phone_call_state is defined" && {
    declare -f phone_call_state &>/dev/null
    assert_ok $?
  }

  it "phone_cell_info is defined" && {
    declare -f phone_cell_info &>/dev/null
    assert_ok $?
  }

  it "phone_call_log is defined" && {
    declare -f phone_call_log &>/dev/null
    assert_ok $?
  }

  it "phone_call_log_pretty is defined" && {
    declare -f phone_call_log_pretty &>/dev/null
    assert_ok $?
  }

  it "phone_wifi_info is defined" && {
    declare -f phone_wifi_info &>/dev/null
    assert_ok $?
  }

  it "phone_wifi_scan is defined" && {
    declare -f phone_wifi_scan &>/dev/null
    assert_ok $?
  }

  it "phone_status_context is defined" && {
    declare -f phone_status_context &>/dev/null
    assert_ok $?
  }

  it "phone_dashboard is defined" && {
    declare -f phone_dashboard &>/dev/null
    assert_ok $?
  }

# ═══════════════════════════════════════════════════════════════
# Graceful degradation when Termux API unavailable
# ═══════════════════════════════════════════════════════════════
describe "Graceful fallback (no Termux API)"

  it "phone_available returns false without termux" && {
    if ! command -v termux-battery-status &>/dev/null; then
      phone_available
      assert_fail $?
    else
      skip "termux-api installed — testing live"
    fi
  }

  it "phone_check warns without termux" && {
    if ! command -v termux-battery-status &>/dev/null; then
      
      _test_out=$(phone_check 2>&1)
      assert_contains "$_test_out" "not available"
    else
      skip "termux-api installed"
    fi
  }

  it "phone_location returns error JSON without termux" && {
    if ! command -v termux-location &>/dev/null; then
      
      _test_out=$(phone_location 2>&1)
      assert_contains "$_test_out" "not available"
    else
      skip "termux-location installed"
    fi
  }

  it "phone_sms_list returns error without termux" && {
    if ! command -v termux-sms-list &>/dev/null; then
      # phone_api_call returns JSON error to stdout which phone_sms_list
      # captures internally, then returns 1. Output may be empty.
      phone_sms_list 2>/dev/null
      assert_fail $?
    else
      skip "termux-sms-list installed"
    fi
  }

  it "phone_telephony_info returns error without termux" && {
    if ! command -v termux-telephony-deviceinfo &>/dev/null; then
      
      _test_out=$(phone_telephony_info 2>&1)
      assert_contains "$_test_out" "not installed"
    else
      skip "termux-telephony-deviceinfo installed"
    fi
  }

  it "phone_cell_info returns error without termux" && {
    if ! command -v termux-telephony-cellinfo &>/dev/null; then
      
      _test_out=$(phone_cell_info 2>&1)
      assert_contains "$_test_out" "not installed"
    else
      skip "termux-telephony-cellinfo installed"
    fi
  }

  it "phone_call_log returns error without termux" && {
    if ! command -v termux-call-log &>/dev/null; then
      
      _test_out=$(phone_call_log 2>&1)
      assert_contains "$_test_out" "not installed"
    else
      skip "termux-call-log installed"
    fi
  }

  it "phone_wifi_info returns error without termux" && {
    if ! command -v termux-wifi-connectioninfo &>/dev/null; then
      
      _test_out=$(phone_wifi_info 2>&1)
      assert_contains "$_test_out" "not installed"
    else
      skip "termux-wifi-connectioninfo installed"
    fi
  }

  it "phone_wifi_scan returns error without termux" && {
    if ! command -v termux-wifi-scaninfo &>/dev/null; then
      
      _test_out=$(phone_wifi_scan 2>&1)
      assert_contains "$_test_out" "not installed"
    else
      skip "termux-wifi-scaninfo installed"
    fi
  }

# ═══════════════════════════════════════════════════════════════
# SMS permission gating
# ═══════════════════════════════════════════════════════════════
describe "SMS send permission gating"

  it "phone_sms_send rejects empty number" && {
    
    _test_out=$(phone_sms_send "" "hello" 2>&1)
    assert_fail $?
  }

  it "phone_sms_send rejects empty body" && {
    
    _test_out=$(phone_sms_send "+15555555555" "" 2>&1)
    assert_fail $?
  }

# ═══════════════════════════════════════════════════════════════
# Location context format
# ═══════════════════════════════════════════════════════════════
describe "Location context format"

  it "phone_location_context returns 'Location:' prefix" && {
    
    _test_out=$(phone_location_context 2>/dev/null)
    assert_contains "$_test_out" "Location:"
  }

  it "phone_location_context says 'unavailable' when no API" && {
    if ! command -v termux-location &>/dev/null; then
      
      _test_out=$(phone_location_context 2>/dev/null)
      assert_contains "$_test_out" "unavailable"
    else
      skip "termux-location installed — would return real data"
    fi
  }

# ═══════════════════════════════════════════════════════════════
# phone_status_context format
# ═══════════════════════════════════════════════════════════════
describe "phone_status_context"

  it "returns a string (may be empty without termux)" && {
    
    _test_out=$(phone_status_context 2>/dev/null)
    # Should not crash, output may be empty on non-termux
    assert_ok $?
  }

# ═══════════════════════════════════════════════════════════════
# proot detection
# ═══════════════════════════════════════════════════════════════
describe "proot detection"

  it "phone_is_proot is defined" && {
    declare -f phone_is_proot &>/dev/null
    assert_ok $?
  }

  it "phone_is_proot returns 1 on non-proot systems" && {
    if [ -z "${PROOT_TMP_DIR:-}" ] && [ ! -d /host-rootfs ]; then
      phone_is_proot
      assert_fail $?
    else
      skip "Running inside proot"
    fi
  }

  it "phone_is_proot detects PROOT_TMP_DIR" && {
    (
      export PROOT_TMP_DIR="/tmp/proot"
      phone_is_proot
    )
    assert_ok $?
  }

# ═══════════════════════════════════════════════════════════════
# phone_api_call safe wrapper
# ═══════════════════════════════════════════════════════════════
describe "phone_api_call safe wrapper"

  it "phone_api_call is defined" && {
    declare -f phone_api_call &>/dev/null
    assert_ok $?
  }

  it "phone_api_call fails for missing command" && {
    _test_out=$(phone_api_call no-such-termux-cmd 2>&1)
    assert_fail $?
  }

  it "phone_api_call returns error JSON for missing command" && {
    _test_out=$(phone_api_call no-such-termux-cmd 2>/dev/null)
    assert_contains "$_test_out" "not installed"
  }

  it "phone_api_call fails inside proot" && {
    (
      export PROOT_TMP_DIR="/tmp/proot"
      export LODGE_TERMUX_API=1
      _test_out=$(phone_api_call termux-battery-status 2>/dev/null)
      echo "$_test_out"
    ) | grep -q "proot"
    assert_ok $?
  }

  it "PHONE_API_TIMEOUT defaults to 10" && {
    assert_eq "$PHONE_API_TIMEOUT" "10"
  }

# ═══════════════════════════════════════════════════════════════
# phone_fix_permissions guide
# ═══════════════════════════════════════════════════════════════
describe "phone_fix_permissions"

  it "phone_fix_permissions is defined" && {
    declare -f phone_fix_permissions &>/dev/null
    assert_ok $?
  }

  it "phone_fix_permissions outputs setup instructions" && {
    _test_out=$(phone_fix_permissions 2>/dev/null)
    assert_contains "$_test_out" "Permission"
  }

  it "phone_fix_permissions mentions F-Droid" && {
    _test_out=$(phone_fix_permissions 2>/dev/null)
    assert_contains "$_test_out" "F-Droid"
  }

  it "phone_fix_permissions mentions Android Settings" && {
    _test_out=$(phone_fix_permissions 2>/dev/null)
    assert_contains "$_test_out" "Settings"
  }

test_end
