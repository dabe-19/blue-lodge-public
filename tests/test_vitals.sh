#!/bin/bash
# ── Tests: lib/vitals.sh ──────────────────────────────────────
# System vitals: disk, RAM, battery, WiFi, cell signal,
# status assessments, guard functions, context strings, caching.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"

_test_tmpdir=""
_test_out=""
_test_rc=0

_setup_vitals() {
    _test_tmpdir=$(test_tmpdir)
    export GEORGE_CONFIG_DIR="$_test_tmpdir/.george"
    mkdir -p "$GEORGE_CONFIG_DIR"
    # Reset cache
    _VITALS_CACHE_TIME=0
    source "$LODGE_DIR/lib/vitals.sh"
}

_teardown_vitals() {
    test_unmock_all
    rm -rf "$_test_tmpdir"
}

test_start "lib/vitals.sh — System Vitals"

# ═══════════════════════════════════════════════════════════════
# Function existence
# ═══════════════════════════════════════════════════════════════
describe "Core functions exist"

  it "vitals_disk_free_mb is defined" && {
    _setup_vitals
    declare -f vitals_disk_free_mb &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_disk_total_mb is defined" && {
    _setup_vitals
    declare -f vitals_disk_total_mb &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_disk_pct is defined" && {
    _setup_vitals
    declare -f vitals_disk_pct &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_ram_free_mb is defined" && {
    _setup_vitals
    declare -f vitals_ram_free_mb &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_ram_total_mb is defined" && {
    _setup_vitals
    declare -f vitals_ram_total_mb &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_ram_used_mb is defined" && {
    _setup_vitals
    declare -f vitals_ram_used_mb &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_battery_pct is defined" && {
    _setup_vitals
    declare -f vitals_battery_pct &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_battery_status is defined" && {
    _setup_vitals
    declare -f vitals_battery_status &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_wifi_rssi is defined" && {
    _setup_vitals
    declare -f vitals_wifi_rssi &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_wifi_ssid is defined" && {
    _setup_vitals
    declare -f vitals_wifi_ssid &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_wifi_speed is defined" && {
    _setup_vitals
    declare -f vitals_wifi_speed &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_cell_signal is defined" && {
    _setup_vitals
    declare -f vitals_cell_signal &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_cell_type is defined" && {
    _setup_vitals
    declare -f vitals_cell_type &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_net_reachable is defined" && {
    _setup_vitals
    declare -f vitals_net_reachable &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_refresh is defined" && {
    _setup_vitals
    declare -f vitals_refresh &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_context is defined" && {
    _setup_vitals
    declare -f vitals_context &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_context_warnings is defined" && {
    _setup_vitals
    declare -f vitals_context_warnings &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_dashboard is defined" && {
    _setup_vitals
    declare -f vitals_dashboard &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

# ═══════════════════════════════════════════════════════════════
# Status / assessment functions
# ═══════════════════════════════════════════════════════════════
describe "Status assessment functions"

  it "vitals_disk_status is defined" && {
    _setup_vitals
    declare -f vitals_disk_status &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_ram_status is defined" && {
    _setup_vitals
    declare -f vitals_ram_status &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_battery_status_level is defined" && {
    _setup_vitals
    declare -f vitals_battery_status_level &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_wifi_status is defined" && {
    _setup_vitals
    declare -f vitals_wifi_status &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

# ═══════════════════════════════════════════════════════════════
# Guard functions
# ═══════════════════════════════════════════════════════════════
describe "Guard functions"

  it "vitals_guard_disk is defined" && {
    _setup_vitals
    declare -f vitals_guard_disk &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_guard_ram is defined" && {
    _setup_vitals
    declare -f vitals_guard_ram &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_guard_battery is defined" && {
    _setup_vitals
    declare -f vitals_guard_battery &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_guard_network is defined" && {
    _setup_vitals
    declare -f vitals_guard_network &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "vitals_preflight is defined" && {
    _setup_vitals
    declare -f vitals_preflight &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

# ═══════════════════════════════════════════════════════════════
# Raw sensor reads (disk + RAM always available on Linux)
# ═══════════════════════════════════════════════════════════════
describe "Raw disk sensors"

  it "vitals_disk_free_mb returns a number" && {
    _setup_vitals
    _test_out=$(vitals_disk_free_mb)
    assert_match "$_test_out" "^[0-9]+$"
    _teardown_vitals
  }

  it "vitals_disk_total_mb returns a number" && {
    _setup_vitals
    _test_out=$(vitals_disk_total_mb)
    assert_match "$_test_out" "^[0-9]+$"
    _teardown_vitals
  }

  it "vitals_disk_pct returns a number" && {
    _setup_vitals
    _test_out=$(vitals_disk_pct)
    assert_match "$_test_out" "^[0-9]+$"
    _teardown_vitals
  }

  it "disk free <= disk total" && {
    _setup_vitals
    _test_free=$(vitals_disk_free_mb)
    _test_total=$(vitals_disk_total_mb)
    assert_gt "$_test_total" "$((_test_free - 1))"
    _teardown_vitals
  }

describe "Raw RAM sensors"

  it "vitals_ram_free_mb returns a number" && {
    _setup_vitals
    _test_out=$(vitals_ram_free_mb)
    assert_match "$_test_out" "^[0-9]+$"
    _teardown_vitals
  }

  it "vitals_ram_total_mb returns a number" && {
    _setup_vitals
    _test_out=$(vitals_ram_total_mb)
    assert_match "$_test_out" "^[0-9]+$"
    _teardown_vitals
  }

  it "vitals_ram_used_mb returns a number" && {
    _setup_vitals
    _test_out=$(vitals_ram_used_mb)
    assert_match "$_test_out" "^[0-9]+$"
    _teardown_vitals
  }

  it "RAM available <= RAM total" && {
    _setup_vitals
    _test_avail=$(vitals_ram_free_mb)
    _test_total=$(vitals_ram_total_mb)
    assert_gt "$((_test_total + 1))" "$_test_avail"
    _teardown_vitals
  }

# ═══════════════════════════════════════════════════════════════
# Disk status with mocked thresholds
# ═══════════════════════════════════════════════════════════════
describe "Disk status assessments"

  it "reports ok when plenty of disk" && {
    _setup_vitals
    VITALS_DISK_WARN_MB=10
    VITALS_DISK_CRIT_MB=5
    _VITALS_CACHE_TIME=0
    _test_out=$(vitals_disk_status)
    assert_eq "$_test_out" "ok"
    _teardown_vitals
  }

  it "reports warn with tight thresholds" && {
    _setup_vitals
    # Set warn threshold very high, crit low
    _test_real_free=$(vitals_disk_free_mb)
    VITALS_DISK_WARN_MB=$((_test_real_free + 1000))
    VITALS_DISK_CRIT_MB=1
    _VITALS_CACHE_TIME=0
    _test_out=$(vitals_disk_status)
    assert_eq "$_test_out" "warn"
    _teardown_vitals
  }

  it "reports critical with extreme thresholds" && {
    _setup_vitals
    _test_real_free=$(vitals_disk_free_mb)
    VITALS_DISK_CRIT_MB=$((_test_real_free + 1000))
    _VITALS_CACHE_TIME=0
    _test_out=$(vitals_disk_status)
    assert_eq "$_test_out" "critical"
    _teardown_vitals
  }

# ═══════════════════════════════════════════════════════════════
# RAM status with mocked thresholds
# ═══════════════════════════════════════════════════════════════
describe "RAM status assessments"

  it "reports ok when plenty of RAM" && {
    _setup_vitals
    VITALS_RAM_WARN_MB=10
    VITALS_RAM_CRIT_MB=5
    _VITALS_CACHE_TIME=0
    _test_out=$(vitals_ram_status)
    assert_eq "$_test_out" "ok"
    _teardown_vitals
  }

  it "reports warn with tight RAM thresholds" && {
    _setup_vitals
    _test_real_free=$(vitals_ram_free_mb)
    VITALS_RAM_WARN_MB=$((_test_real_free + 1000))
    VITALS_RAM_CRIT_MB=1
    _VITALS_CACHE_TIME=0
    _test_out=$(vitals_ram_status)
    assert_eq "$_test_out" "warn"
    _teardown_vitals
  }

  it "reports critical with extreme RAM thresholds" && {
    _setup_vitals
    _test_real_free=$(vitals_ram_free_mb)
    VITALS_RAM_CRIT_MB=$((_test_real_free + 1000))
    _VITALS_CACHE_TIME=0
    _test_out=$(vitals_ram_status)
    assert_eq "$_test_out" "critical"
    _teardown_vitals
  }

# ═══════════════════════════════════════════════════════════════
# Battery status (mocked — no Termux on host)
# ═══════════════════════════════════════════════════════════════
describe "Battery status (mocked)"

  it "reports ok when battery is high" && {
    _setup_vitals
    _VITALS_CACHE_BATTERY_PCT=85
    _VITALS_CACHE_BATTERY_STATUS="DISCHARGING"
    _VITALS_CACHE_TIME=$(date +%s)
    _test_out=$(vitals_battery_status_level)
    assert_eq "$_test_out" "ok"
    _teardown_vitals
  }

  it "reports ok when charging regardless of level" && {
    _setup_vitals
    _VITALS_CACHE_BATTERY_PCT=3
    _VITALS_CACHE_BATTERY_STATUS="CHARGING"
    _VITALS_CACHE_TIME=$(date +%s)
    _test_out=$(vitals_battery_status_level)
    assert_eq "$_test_out" "ok"
    _teardown_vitals
  }

  it "reports warn at low battery" && {
    _setup_vitals
    VITALS_BATTERY_WARN=20
    VITALS_BATTERY_CRIT=5
    _VITALS_CACHE_BATTERY_PCT=12
    _VITALS_CACHE_BATTERY_STATUS="DISCHARGING"
    _VITALS_CACHE_TIME=$(date +%s)
    _test_out=$(vitals_battery_status_level)
    assert_eq "$_test_out" "warn"
    _teardown_vitals
  }

  it "reports critical at very low battery" && {
    _setup_vitals
    VITALS_BATTERY_CRIT=10
    _VITALS_CACHE_BATTERY_PCT=3
    _VITALS_CACHE_BATTERY_STATUS="DISCHARGING"
    _VITALS_CACHE_TIME=$(date +%s)
    _test_out=$(vitals_battery_status_level)
    assert_eq "$_test_out" "critical"
    _teardown_vitals
  }

  it "reports ok when FULL" && {
    _setup_vitals
    _VITALS_CACHE_BATTERY_PCT=100
    _VITALS_CACHE_BATTERY_STATUS="FULL"
    _VITALS_CACHE_TIME=$(date +%s)
    _test_out=$(vitals_battery_status_level)
    assert_eq "$_test_out" "ok"
    _teardown_vitals
  }

# ═══════════════════════════════════════════════════════════════
# WiFi status (mocked)
# ═══════════════════════════════════════════════════════════════
describe "WiFi status (mocked)"

  it "reports none when no SSID or RSSI" && {
    _setup_vitals
    _VITALS_CACHE_WIFI_SSID=""
    _VITALS_CACHE_WIFI_RSSI=""
    _VITALS_CACHE_TIME=$(date +%s)
    _test_out=$(vitals_wifi_status)
    assert_eq "$_test_out" "none"
    _teardown_vitals
  }

  it "reports ok for strong signal" && {
    _setup_vitals
    _VITALS_CACHE_WIFI_SSID="TestNet"
    _VITALS_CACHE_WIFI_RSSI="-45"
    _VITALS_CACHE_TIME=$(date +%s)
    _test_out=$(vitals_wifi_status)
    assert_eq "$_test_out" "ok"
    _teardown_vitals
  }

  it "reports warn for medium signal" && {
    _setup_vitals
    _VITALS_CACHE_WIFI_SSID="TestNet"
    _VITALS_CACHE_WIFI_RSSI="-68"
    _VITALS_CACHE_TIME=$(date +%s)
    _test_out=$(vitals_wifi_status)
    assert_eq "$_test_out" "warn"
    _teardown_vitals
  }

  it "reports critical for weak signal" && {
    _setup_vitals
    _VITALS_CACHE_WIFI_SSID="TestNet"
    _VITALS_CACHE_WIFI_RSSI="-82"
    _VITALS_CACHE_TIME=$(date +%s)
    _test_out=$(vitals_wifi_status)
    assert_eq "$_test_out" "critical"
    _teardown_vitals
  }

  it "reports ok when SSID but no RSSI" && {
    _setup_vitals
    _VITALS_CACHE_WIFI_SSID="TestNet"
    _VITALS_CACHE_WIFI_RSSI=""
    _VITALS_CACHE_TIME=$(date +%s)
    _test_out=$(vitals_wifi_status)
    assert_eq "$_test_out" "ok"
    _teardown_vitals
  }

# ═══════════════════════════════════════════════════════════════
# Guard functions
# ═══════════════════════════════════════════════════════════════
describe "Guard functions — disk"

  it "guard_disk passes when disk OK" && {
    _setup_vitals
    VITALS_DISK_WARN_MB=10
    VITALS_DISK_CRIT_MB=5
    _VITALS_CACHE_TIME=0
    vitals_guard_disk &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "guard_disk warns but passes when disk warn" && {
    _setup_vitals
    _test_real_free=$(vitals_disk_free_mb)
    VITALS_DISK_WARN_MB=$((_test_real_free + 1000))
    VITALS_DISK_CRIT_MB=1
    _VITALS_CACHE_TIME=0
    vitals_guard_disk &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "guard_disk blocks when disk critical" && {
    _setup_vitals
    _test_real_free=$(vitals_disk_free_mb)
    VITALS_DISK_CRIT_MB=$((_test_real_free + 1000))
    _VITALS_CACHE_TIME=0
    vitals_guard_disk &>/dev/null
    _test_rc=$?
    assert_fail "$_test_rc"
    _teardown_vitals
  }

describe "Guard functions — RAM"

  it "guard_ram passes when RAM OK" && {
    _setup_vitals
    VITALS_RAM_WARN_MB=10
    VITALS_RAM_CRIT_MB=5
    _VITALS_CACHE_TIME=0
    vitals_guard_ram &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "guard_ram blocks when RAM critical" && {
    _setup_vitals
    _test_real_free=$(vitals_ram_free_mb)
    VITALS_RAM_CRIT_MB=$((_test_real_free + 1000))
    _VITALS_CACHE_TIME=0
    vitals_guard_ram &>/dev/null
    _test_rc=$?
    assert_fail "$_test_rc"
    _teardown_vitals
  }

describe "Guard functions — battery (mocked)"

  it "guard_battery passes when battery OK" && {
    _setup_vitals
    _VITALS_CACHE_BATTERY_PCT=85
    _VITALS_CACHE_BATTERY_STATUS="DISCHARGING"
    _VITALS_CACHE_TIME=$(date +%s)
    vitals_guard_battery &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "guard_battery blocks when battery critical" && {
    _setup_vitals
    VITALS_BATTERY_CRIT=10
    _VITALS_CACHE_BATTERY_PCT=3
    _VITALS_CACHE_BATTERY_STATUS="DISCHARGING"
    _VITALS_CACHE_TIME=$(date +%s)
    vitals_guard_battery &>/dev/null
    _test_rc=$?
    assert_fail "$_test_rc"
    _teardown_vitals
  }

# ═══════════════════════════════════════════════════════════════
# Pre-flight
# ═══════════════════════════════════════════════════════════════
describe "Pre-flight check"

  it "preflight passes when all OK" && {
    _setup_vitals
    VITALS_DISK_WARN_MB=10
    VITALS_DISK_CRIT_MB=5
    VITALS_RAM_WARN_MB=10
    VITALS_RAM_CRIT_MB=5
    _VITALS_CACHE_BATTERY_PCT=85
    _VITALS_CACHE_BATTERY_STATUS="DISCHARGING"
    _VITALS_CACHE_TIME=0
    vitals_preflight "warn" &>/dev/null
    assert_ok $?
    _teardown_vitals
  }

  it "preflight strict blocks on critical disk" && {
    _setup_vitals
    _test_real_free=$(vitals_disk_free_mb)
    VITALS_DISK_CRIT_MB=$((_test_real_free + 1000))
    VITALS_RAM_WARN_MB=10
    VITALS_RAM_CRIT_MB=5
    _VITALS_CACHE_BATTERY_PCT=85
    _VITALS_CACHE_BATTERY_STATUS="DISCHARGING"
    _VITALS_CACHE_TIME=0
    vitals_preflight "strict" &>/dev/null
    _test_rc=$?
    assert_fail "$_test_rc"
    _teardown_vitals
  }

  it "preflight strict blocks on critical RAM" && {
    _setup_vitals
    _test_real_free=$(vitals_ram_free_mb)
    VITALS_RAM_CRIT_MB=$((_test_real_free + 1000))
    VITALS_DISK_WARN_MB=10
    VITALS_DISK_CRIT_MB=5
    _VITALS_CACHE_BATTERY_PCT=85
    _VITALS_CACHE_BATTERY_STATUS="DISCHARGING"
    _VITALS_CACHE_TIME=0
    vitals_preflight "strict" &>/dev/null
    _test_rc=$?
    assert_fail "$_test_rc"
    _teardown_vitals
  }

# ═══════════════════════════════════════════════════════════════
# Context strings
# ═══════════════════════════════════════════════════════════════
describe "Context string for LLM"

  it "vitals_context starts with [Vitals:" && {
    _setup_vitals
    _VITALS_CACHE_TIME=0
    _test_out=$(vitals_context)
    assert_contains "$_test_out" "[Vitals:"
    _teardown_vitals
  }

  it "vitals_context contains Disk" && {
    _setup_vitals
    _VITALS_CACHE_TIME=0
    _test_out=$(vitals_context)
    assert_contains "$_test_out" "Disk"
    _teardown_vitals
  }

  it "vitals_context contains RAM" && {
    _setup_vitals
    _VITALS_CACHE_TIME=0
    _test_out=$(vitals_context)
    assert_contains "$_test_out" "RAM"
    _teardown_vitals
  }

  it "vitals_context contains GB unit" && {
    _setup_vitals
    _VITALS_CACHE_TIME=0
    _test_out=$(vitals_context)
    assert_contains "$_test_out" "GB"
    _teardown_vitals
  }

  it "vitals_context ends with ]" && {
    _setup_vitals
    _VITALS_CACHE_TIME=0
    _test_out=$(vitals_context)
    assert_match "$_test_out" '\]$'
    _teardown_vitals
  }

describe "Warnings-only context"

  it "returns empty when all systems OK" && {
    _setup_vitals
    VITALS_DISK_WARN_MB=10
    VITALS_DISK_CRIT_MB=5
    VITALS_RAM_WARN_MB=10
    VITALS_RAM_CRIT_MB=5
    _VITALS_CACHE_DISK_FREE_MB=50000
    _VITALS_CACHE_RAM_FREE_MB=8000
    _VITALS_CACHE_RAM_TOTAL_MB=12000
    _VITALS_CACHE_BATTERY_PCT=85
    _VITALS_CACHE_BATTERY_STATUS="DISCHARGING"
    _VITALS_CACHE_WIFI_SSID="TestNet"
    _VITALS_CACHE_WIFI_RSSI="-45"
    _VITALS_CACHE_CELL_SIGNAL="-90"
    _VITALS_CACHE_TIME=$(date +%s)
    _test_out=$(vitals_context_warnings)
    assert_empty "$_test_out"
    _teardown_vitals
  }

  it "returns WARNING when disk is low" && {
    _setup_vitals
    _test_real_free=$(vitals_disk_free_mb)
    VITALS_DISK_WARN_MB=$((_test_real_free + 1000))
    VITALS_DISK_CRIT_MB=1
    VITALS_RAM_WARN_MB=10
    VITALS_RAM_CRIT_MB=5
    _VITALS_CACHE_BATTERY_PCT=85
    _VITALS_CACHE_BATTERY_STATUS="DISCHARGING"
    _VITALS_CACHE_WIFI_SSID="TestNet"
    _VITALS_CACHE_WIFI_RSSI="-45"
    _VITALS_CACHE_TIME=$(date +%s)
    _test_out=$(vitals_context_warnings)
    assert_contains "$_test_out" "[WARNING:"
    _teardown_vitals
  }

  it "warning mentions Disk when disk is low" && {
    _setup_vitals
    _test_real_free=$(vitals_disk_free_mb)
    VITALS_DISK_WARN_MB=$((_test_real_free + 1000))
    VITALS_DISK_CRIT_MB=1
    VITALS_RAM_WARN_MB=10
    VITALS_RAM_CRIT_MB=5
    _VITALS_CACHE_BATTERY_PCT=85
    _VITALS_CACHE_BATTERY_STATUS="DISCHARGING"
    _VITALS_CACHE_WIFI_SSID="TestNet"
    _VITALS_CACHE_WIFI_RSSI="-45"
    _VITALS_CACHE_TIME=$(date +%s)
    _test_out=$(vitals_context_warnings)
    assert_contains "$_test_out" "Disk"
    _teardown_vitals
  }

# ═══════════════════════════════════════════════════════════════
# Dashboard
# ═══════════════════════════════════════════════════════════════
describe "Dashboard output"

  it "dashboard produces output" && {
    _setup_vitals
    _VITALS_CACHE_TIME=0
    _test_out=$(vitals_dashboard 2>&1)
    assert_not_empty "$_test_out"
    _teardown_vitals
  }

  it "dashboard contains Vitals header" && {
    _setup_vitals
    _VITALS_CACHE_TIME=0
    _test_out=$(vitals_dashboard 2>&1)
    assert_contains "$_test_out" "Vitals"
    _teardown_vitals
  }

  it "dashboard contains Disk line" && {
    _setup_vitals
    _VITALS_CACHE_TIME=0
    _test_out=$(vitals_dashboard 2>&1)
    assert_contains "$_test_out" "Disk"
    _teardown_vitals
  }

  it "dashboard contains RAM line" && {
    _setup_vitals
    _VITALS_CACHE_TIME=0
    _test_out=$(vitals_dashboard 2>&1)
    assert_contains "$_test_out" "RAM"
    _teardown_vitals
  }

# ═══════════════════════════════════════════════════════════════
# Cache mechanism
# ═══════════════════════════════════════════════════════════════
describe "Cache mechanism"

  it "cache refreshes when stale" && {
    _setup_vitals
    _VITALS_CACHE_TIME=0
    _VITALS_CACHE_DISK_FREE_MB=""
    _vitals_refresh_cache
    assert_not_empty "$_VITALS_CACHE_DISK_FREE_MB"
    _teardown_vitals
  }

  it "cache does not refresh when fresh" && {
    _setup_vitals
    _VITALS_CACHE_TIME=$(date +%s)
    _VITALS_CACHE_DISK_FREE_MB="9999"
    _vitals_refresh_cache
    # Should still be 9999 because TTL hasn't expired
    assert_eq "$_VITALS_CACHE_DISK_FREE_MB" "9999"
    _teardown_vitals
  }

  it "vitals_refresh forces cache refresh" && {
    _setup_vitals
    _VITALS_CACHE_TIME=$(date +%s)
    _VITALS_CACHE_DISK_FREE_MB="9999"
    vitals_refresh
    # After force refresh, it should be the real value (not 9999)
    assert_neq "$_VITALS_CACHE_DISK_FREE_MB" "9999"
    _teardown_vitals
  }

# ═══════════════════════════════════════════════════════════════
# Thresholds configuration
# ═══════════════════════════════════════════════════════════════
describe "Threshold configuration"

  it "default disk warn threshold is 500" && {
    _setup_vitals
    # Reset to default
    unset VITALS_DISK_WARN_MB
    unset _LIB_VITALS_LOADED
    source "$LODGE_DIR/lib/vitals.sh"
    assert_eq "$VITALS_DISK_WARN_MB" "500"
    _teardown_vitals
  }

  it "default disk crit threshold is 100" && {
    _setup_vitals
    unset VITALS_DISK_CRIT_MB
    unset _LIB_VITALS_LOADED
    source "$LODGE_DIR/lib/vitals.sh"
    assert_eq "$VITALS_DISK_CRIT_MB" "100"
    _teardown_vitals
  }

  it "default RAM warn threshold is 200" && {
    _setup_vitals
    unset VITALS_RAM_WARN_MB
    unset _LIB_VITALS_LOADED
    source "$LODGE_DIR/lib/vitals.sh"
    assert_eq "$VITALS_RAM_WARN_MB" "200"
    _teardown_vitals
  }

  it "default RAM crit threshold is 100" && {
    _setup_vitals
    unset VITALS_RAM_CRIT_MB
    unset _LIB_VITALS_LOADED
    source "$LODGE_DIR/lib/vitals.sh"
    assert_eq "$VITALS_RAM_CRIT_MB" "100"
    _teardown_vitals
  }

  it "default battery warn is 15" && {
    _setup_vitals
    unset VITALS_BATTERY_WARN
    unset _LIB_VITALS_LOADED
    source "$LODGE_DIR/lib/vitals.sh"
    assert_eq "$VITALS_BATTERY_WARN" "15"
    _teardown_vitals
  }

  it "default battery crit is 5" && {
    _setup_vitals
    unset VITALS_BATTERY_CRIT
    unset _LIB_VITALS_LOADED
    source "$LODGE_DIR/lib/vitals.sh"
    assert_eq "$VITALS_BATTERY_CRIT" "5"
    _teardown_vitals
  }

  it "custom thresholds are respected" && {
    _setup_vitals
    export VITALS_DISK_WARN_MB=2000
    unset _LIB_VITALS_LOADED
    source "$LODGE_DIR/lib/vitals.sh"
    assert_eq "$VITALS_DISK_WARN_MB" "2000"
    _teardown_vitals
  }

test_end
