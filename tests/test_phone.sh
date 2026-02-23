#!/bin/bash
# ── Tests: lib/phone.sh ───────────────────────────────────────
# Phone integration: location, SMS, telephony, WiFi, call log.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/phone.sh"

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
      
      _test_out=$(phone_sms_list 2>&1)
      assert_contains "$_test_out" "not available"
    else
      skip "termux-sms-list installed"
    fi
  }

  it "phone_telephony_info returns error without termux" && {
    if ! command -v termux-telephony-deviceinfo &>/dev/null; then
      
      _test_out=$(phone_telephony_info 2>&1)
      assert_contains "$_test_out" "not available"
    else
      skip "termux-telephony-deviceinfo installed"
    fi
  }

  it "phone_cell_info returns error without termux" && {
    if ! command -v termux-telephony-cellinfo &>/dev/null; then
      
      _test_out=$(phone_cell_info 2>&1)
      assert_contains "$_test_out" "not available"
    else
      skip "termux-telephony-cellinfo installed"
    fi
  }

  it "phone_call_log returns error without termux" && {
    if ! command -v termux-call-log &>/dev/null; then
      
      _test_out=$(phone_call_log 2>&1)
      assert_contains "$_test_out" "not available"
    else
      skip "termux-call-log installed"
    fi
  }

  it "phone_wifi_info returns error without termux" && {
    if ! command -v termux-wifi-connectioninfo &>/dev/null; then
      
      _test_out=$(phone_wifi_info 2>&1)
      assert_contains "$_test_out" "not available"
    else
      skip "termux-wifi-connectioninfo installed"
    fi
  }

  it "phone_wifi_scan returns error without termux" && {
    if ! command -v termux-wifi-scaninfo &>/dev/null; then
      
      _test_out=$(phone_wifi_scan 2>&1)
      assert_contains "$_test_out" "not available"
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

test_end
