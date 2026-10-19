#!/bin/bash
# ── Tests: lib/sys/vitals.sh ──────────────────────────────────────
# System vitals: disk, RAM, battery, WiFi, cell signal,
# status assessments, guard functions, context strings, caching.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh"
source "$LODGE_DIR/lib/sys/vitals.sh"

_test_tmpdir=""
_test_out=""
_test_rc=0

_setup_vitals() {
    _test_tmpdir=$(test_tmpdir)
    export GEORGE_CONFIG_DIR="$_test_tmpdir/.george"
    mkdir -p "$GEORGE_CONFIG_DIR"
    # Reset cache
    _VITALS_CACHE_TIME=0
    source "$LODGE_DIR/lib/sys/vitals.sh"
}

_teardown_vitals() {
    test_unmock_all
    rm -rf "$_test_tmpdir"
}
trap _teardown_vitals EXIT

test_start "lib/sys/vitals.sh — System Vitals"

# ═══════════════════════════════════════════════════════════════
# Function existence
# ═══════════════════════════════════════════════════════════════
describe "Core functions exist"

  it "vitals_disk_free_mb is defined" && assert_fn_defined "vitals_disk_free_mb"
  it "vitals_disk_total_mb is defined" && assert_fn_defined "vitals_disk_total_mb"
  it "vitals_disk_pct is defined" && assert_fn_defined "vitals_disk_pct"
  it "vitals_ram_free_mb is defined" && assert_fn_defined "vitals_ram_free_mb"
  it "vitals_ram_total_mb is defined" && assert_fn_defined "vitals_ram_total_mb"
  it "vitals_ram_used_mb is defined" && assert_fn_defined "vitals_ram_used_mb"
  it "vitals_battery_pct is defined" && assert_fn_defined "vitals_battery_pct"
  it "vitals_battery_status is defined" && assert_fn_defined "vitals_battery_status"
  it "vitals_wifi_rssi is defined" && assert_fn_defined "vitals_wifi_rssi"
  it "vitals_wifi_ssid is defined" && assert_fn_defined "vitals_wifi_ssid"
  it "vitals_wifi_speed is defined" && assert_fn_defined "vitals_wifi_speed"
  it "vitals_cell_signal is defined" && assert_fn_defined "vitals_cell_signal"
  it "vitals_cell_type is defined" && assert_fn_defined "vitals_cell_type"
  it "vitals_net_reachable is defined" && assert_fn_defined "vitals_net_reachable"
  it "vitals_refresh is defined" && assert_fn_defined "vitals_refresh"
  it "vitals_context is defined" && assert_fn_defined "vitals_context"
  it "vitals_context_warnings is defined" && assert_fn_defined "vitals_context_warnings"
  it "vitals_dashboard is defined" && assert_fn_defined "vitals_dashboard"

# ═══════════════════════════════════════════════════════════════
# Status / assessment functions
# ═══════════════════════════════════════════════════════════════
describe "Status assessment functions"

  it "vitals_disk_status is defined" && assert_fn_defined "vitals_disk_status"
  it "vitals_ram_status is defined" && assert_fn_defined "vitals_ram_status"
  it "vitals_battery_status_level is defined" && assert_fn_defined "vitals_battery_status_level"
  it "vitals_wifi_status is defined" && assert_fn_defined "vitals_wifi_status"

# ═══════════════════════════════════════════════════════════════
# Guard functions
# ═══════════════════════════════════════════════════════════════
describe "Guard functions"

  it "vitals_guard_disk is defined" && assert_fn_defined "vitals_guard_disk"
  it "vitals_guard_ram is defined" && assert_fn_defined "vitals_guard_ram"
  it "vitals_guard_battery is defined" && assert_fn_defined "vitals_guard_battery"
  it "vitals_guard_network is defined" && assert_fn_defined "vitals_guard_network"
  it "vitals_preflight is defined" && assert_fn_defined "vitals_preflight"

# ═══════════════════════════════════════════════════════════════
# Raw sensor reads (disk + RAM always available on Linux)
# ═══════════════════════════════════════════════════════════════
describe "Raw disk sensors"

  it "vitals_disk_free_mb returns a number" && assert_match "$(vitals_disk_free_mb)" "^[0-9]+$"

  it "vitals_disk_total_mb returns a number" && assert_match "$(vitals_disk_total_mb)" "^[0-9]+$"

  it "vitals_disk_pct returns a number" && assert_match "$(vitals_disk_pct)" "^[0-9]+$"

  it "disk free <= disk total" && { _test_free=$(vitals_disk_free_mb); _test_total=$(vitals_disk_total_mb); assert_gt "$_test_total" "$((_test_free - 1))"; }

describe "Raw RAM sensors"

  it "vitals_ram_free_mb returns a number" && assert_match "$(vitals_ram_free_mb)" "^[0-9]+$"

  it "vitals_ram_total_mb returns a number" && assert_match "$(vitals_ram_total_mb)" "^[0-9]+$"

  it "vitals_ram_used_mb returns a number" && assert_match "$(vitals_ram_used_mb)" "^[0-9]+$"

  it "RAM available <= RAM total" && { _test_avail=$(vitals_ram_free_mb); _test_total=$(vitals_ram_total_mb); assert_gt "$((_test_total + 1))" "$_test_avail"; }

# ═══════════════════════════════════════════════════════════════
# Disk status with mocked thresholds
# ═══════════════════════════════════════════════════════════════
describe "Disk status assessments"

  it "reports ok when plenty of disk" && { VITALS_DISK_WARN_MB=10; VITALS_DISK_CRIT_MB=5; _VITALS_CACHE_TIME=0; _test_out=$(vitals_disk_status); assert_eq "$_test_out" "ok"; }

  it "reports warn with tight thresholds" && { _test_real_free=$(vitals_disk_free_mb); VITALS_DISK_WARN_MB=$((_test_real_free + 1000)); VITALS_DISK_CRIT_MB=1; _VITALS_CACHE_TIME=0; _test_out=$(vitals_disk_status); assert_eq "$_test_out" "warn"; }

  it "reports critical with extreme thresholds" && { _test_real_free=$(vitals_disk_free_mb); VITALS_DISK_CRIT_MB=$((_test_real_free + 1000)); _VITALS_CACHE_TIME=0; _test_out=$(vitals_disk_status); assert_eq "$_test_out" "critical"; }

# ═══════════════════════════════════════════════════════════════
# RAM status with mocked thresholds
# ═══════════════════════════════════════════════════════════════
describe "RAM status assessments"

  it "reports ok when plenty of RAM" && { VITALS_RAM_WARN_MB=10; VITALS_RAM_CRIT_MB=5; _VITALS_CACHE_TIME=0; _test_out=$(vitals_ram_status); assert_eq "$_test_out" "ok"; }

  it "reports warn with tight RAM thresholds" && { _test_real_free=$(vitals_ram_free_mb); VITALS_RAM_WARN_MB=$((_test_real_free + 1000)); VITALS_RAM_CRIT_MB=1; _VITALS_CACHE_TIME=0; _test_out=$(vitals_ram_status); assert_eq "$_test_out" "warn"; }

  it "reports critical with extreme RAM thresholds" && { _test_real_free=$(vitals_ram_free_mb); VITALS_RAM_CRIT_MB=$((_test_real_free + 1000)); _VITALS_CACHE_TIME=0; _test_out=$(vitals_ram_status); assert_eq "$_test_out" "critical"; }

# ═══════════════════════════════════════════════════════════════
# Battery status (mocked — no Termux on host)
# ═══════════════════════════════════════════════════════════════
describe "Battery status (mocked)"

  it "reports ok when battery is high" && { _VITALS_CACHE_BATTERY_PCT=85; _VITALS_CACHE_BATTERY_STATUS="DISCHARGING"; _VITALS_CACHE_TIME=$(date +%s); _test_out=$(vitals_battery_status_level); assert_eq "$_test_out" "ok"; }

  it "reports ok when charging regardless of level" && { _VITALS_CACHE_BATTERY_PCT=3; _VITALS_CACHE_BATTERY_STATUS="CHARGING"; _VITALS_CACHE_TIME=$(date +%s); _test_out=$(vitals_battery_status_level); assert_eq "$_test_out" "ok"; }

  it "reports warn at low battery" && {
    VITALS_BATTERY_WARN=20
    VITALS_BATTERY_CRIT=5
    _VITALS_CACHE_BATTERY_PCT=12
    _VITALS_CACHE_BATTERY_STATUS="DISCHARGING"
    _VITALS_CACHE_TIME=$(date +%s)
    _test_out=$(vitals_battery_status_level)
    assert_eq "$_test_out" "warn"
  }

  it "reports critical at very low battery" && { VITALS_BATTERY_CRIT=10; _VITALS_CACHE_BATTERY_PCT=3; _VITALS_CACHE_BATTERY_STATUS="DISCHARGING"; _VITALS_CACHE_TIME=$(date +%s); _test_out=$(vitals_battery_status_level); assert_eq "$_test_out" "critical"; }

  it "reports ok when FULL" && { _VITALS_CACHE_BATTERY_PCT=100; _VITALS_CACHE_BATTERY_STATUS="FULL"; _VITALS_CACHE_TIME=$(date +%s); _test_out=$(vitals_battery_status_level); assert_eq "$_test_out" "ok"; }

# ═══════════════════════════════════════════════════════════════
# WiFi status (mocked)
# ═══════════════════════════════════════════════════════════════
describe "WiFi status (mocked)"

  it "reports none when no SSID or RSSI" && { _VITALS_CACHE_WIFI_SSID=""; _VITALS_CACHE_WIFI_RSSI=""; _VITALS_CACHE_TIME=$(date +%s); _test_out=$(vitals_wifi_status); assert_eq "$_test_out" "none"; }

  it "reports ok for strong signal" && { _VITALS_CACHE_WIFI_SSID="TestNet"; _VITALS_CACHE_WIFI_RSSI="-45"; _VITALS_CACHE_TIME=$(date +%s); _test_out=$(vitals_wifi_status); assert_eq "$_test_out" "ok"; }

  it "reports warn for medium signal" && { _VITALS_CACHE_WIFI_SSID="TestNet"; _VITALS_CACHE_WIFI_RSSI="-68"; _VITALS_CACHE_TIME=$(date +%s); _test_out=$(vitals_wifi_status); assert_eq "$_test_out" "warn"; }

  it "reports critical for weak signal" && { _VITALS_CACHE_WIFI_SSID="TestNet"; _VITALS_CACHE_WIFI_RSSI="-82"; _VITALS_CACHE_TIME=$(date +%s); _test_out=$(vitals_wifi_status); assert_eq "$_test_out" "critical"; }

  it "reports ok when SSID but no RSSI" && { _VITALS_CACHE_WIFI_SSID="TestNet"; _VITALS_CACHE_WIFI_RSSI=""; _VITALS_CACHE_TIME=$(date +%s); _test_out=$(vitals_wifi_status); assert_eq "$_test_out" "ok"; }

# ═══════════════════════════════════════════════════════════════
# Guard functions
# ═══════════════════════════════════════════════════════════════
describe "Guard functions — disk"

  it "guard_disk passes when disk OK" && { VITALS_DISK_WARN_MB=10; VITALS_DISK_CRIT_MB=5; _VITALS_CACHE_TIME=0; vitals_guard_disk &>/dev/null; assert_ok $?; }

  it "guard_disk warns but passes when disk warn" && { _test_real_free=$(vitals_disk_free_mb); VITALS_DISK_WARN_MB=$((_test_real_free + 1000)); VITALS_DISK_CRIT_MB=1; _VITALS_CACHE_TIME=0; vitals_guard_disk &>/dev/null; assert_ok $?; }

  it "guard_disk blocks when disk critical" && { _test_real_free=$(vitals_disk_free_mb); VITALS_DISK_CRIT_MB=$((_test_real_free + 1000)); _VITALS_CACHE_TIME=0; vitals_guard_disk &>/dev/null; _test_rc=$?; assert_fail "$_test_rc"; }

describe "Guard functions — RAM"

  it "guard_ram passes when RAM OK" && { VITALS_RAM_WARN_MB=10; VITALS_RAM_CRIT_MB=5; _VITALS_CACHE_TIME=0; vitals_guard_ram &>/dev/null; assert_ok $?; }

  it "guard_ram blocks when RAM critical" && { _test_real_free=$(vitals_ram_free_mb); VITALS_RAM_CRIT_MB=$((_test_real_free + 1000)); _VITALS_CACHE_TIME=0; vitals_guard_ram &>/dev/null; _test_rc=$?; assert_fail "$_test_rc"; }

describe "Guard functions — battery (mocked)"

  it "guard_battery passes when battery OK" && { _VITALS_CACHE_BATTERY_PCT=85; _VITALS_CACHE_BATTERY_STATUS="DISCHARGING"; _VITALS_CACHE_TIME=$(date +%s); vitals_guard_battery &>/dev/null; assert_ok $?; }

  it "guard_battery blocks when battery critical" && {
    VITALS_BATTERY_CRIT=10
    _VITALS_CACHE_BATTERY_PCT=3
    _VITALS_CACHE_BATTERY_STATUS="DISCHARGING"
    _VITALS_CACHE_TIME=$(date +%s)
    vitals_guard_battery &>/dev/null
    _test_rc=$?
    assert_fail "$_test_rc"
  }

# ═══════════════════════════════════════════════════════════════
# Pre-flight
# ═══════════════════════════════════════════════════════════════
describe "Pre-flight check"

  it "preflight passes when all OK" && {
    VITALS_DISK_WARN_MB=10
    VITALS_DISK_CRIT_MB=5
    VITALS_RAM_WARN_MB=10
    VITALS_RAM_CRIT_MB=5
    _VITALS_CACHE_BATTERY_PCT=85
    _VITALS_CACHE_BATTERY_STATUS="DISCHARGING"
    _VITALS_CACHE_TIME=0
    vitals_preflight "warn" &>/dev/null
    assert_ok $?
  }

  it "preflight strict blocks on critical disk" && {
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
  }

  it "preflight strict blocks on critical RAM" && {
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
  }

# ═══════════════════════════════════════════════════════════════
# Context strings
# ═══════════════════════════════════════════════════════════════
describe "Context string for LLM"

  it "vitals_context starts with [Vitals:" && { _VITALS_CACHE_TIME=0; _test_out=$(vitals_context); assert_contains "$_test_out" "[Vitals:"; }

  it "vitals_context contains Disk" && { _VITALS_CACHE_TIME=0; _test_out=$(vitals_context); assert_contains "$_test_out" "Disk"; }

  it "vitals_context contains RAM" && { _VITALS_CACHE_TIME=0; _test_out=$(vitals_context); assert_contains "$_test_out" "RAM"; }

  it "vitals_context contains GB unit" && { _VITALS_CACHE_TIME=0; _test_out=$(vitals_context); assert_contains "$_test_out" "GB"; }

  it "vitals_context ends with ]" && { _VITALS_CACHE_TIME=0; _test_out=$(vitals_context); assert_match "$_test_out" '\]$'; }

describe "Warnings-only context"

  it "returns empty when all systems OK" && {
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
  }

  it "returns WARNING when disk is low" && {
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
  }

  it "warning mentions Disk when disk is low" && {
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
  }

# ═══════════════════════════════════════════════════════════════
# Dashboard
# ═══════════════════════════════════════════════════════════════
describe "Dashboard output"

  it "dashboard produces output" && { _VITALS_CACHE_TIME=0; _test_out=$(vitals_dashboard 2>&1); assert_not_empty "$_test_out"; }

  it "dashboard contains Vitals header" && { _VITALS_CACHE_TIME=0; _test_out=$(vitals_dashboard 2>&1); assert_contains "$_test_out" "Vitals"; }

  it "dashboard contains Disk line" && { _VITALS_CACHE_TIME=0; _test_out=$(vitals_dashboard 2>&1); assert_contains "$_test_out" "Disk"; }

  it "dashboard contains RAM line" && { _VITALS_CACHE_TIME=0; _test_out=$(vitals_dashboard 2>&1); assert_contains "$_test_out" "RAM"; }

# ═══════════════════════════════════════════════════════════════
# Cache mechanism
# ═══════════════════════════════════════════════════════════════
describe "Cache mechanism"

  it "cache refreshes when stale" && { _VITALS_CACHE_TIME=0; _VITALS_CACHE_DISK_FREE_MB=""; _vitals_refresh_cache; assert_not_empty "$_VITALS_CACHE_DISK_FREE_MB"; }

  it "cache does not refresh when fresh" && { _VITALS_CACHE_TIME=$(date +%s); _VITALS_CACHE_DISK_FREE_MB="9999"; _vitals_refresh_cache; assert_eq "$_VITALS_CACHE_DISK_FREE_MB" "9999"; }

  it "vitals_refresh forces cache refresh" && { _VITALS_CACHE_TIME=$(date +%s); _VITALS_CACHE_DISK_FREE_MB="9999"; vitals_refresh; assert_neq "$_VITALS_CACHE_DISK_FREE_MB" "9999"; }

# ═══════════════════════════════════════════════════════════════
# Thresholds configuration
# ═══════════════════════════════════════════════════════════════
describe "Threshold configuration"

  it "default disk warn threshold is 500" && { unset VITALS_DISK_WARN_MB; unset _LIB_VITALS_LOADED; source "$LODGE_DIR/lib/sys/vitals.sh"; assert_eq "$VITALS_DISK_WARN_MB" "500"; }

  it "default disk crit threshold is 100" && { unset VITALS_DISK_CRIT_MB; unset _LIB_VITALS_LOADED; source "$LODGE_DIR/lib/sys/vitals.sh"; assert_eq "$VITALS_DISK_CRIT_MB" "100"; }

  it "default RAM warn threshold is 200" && { unset VITALS_RAM_WARN_MB; unset _LIB_VITALS_LOADED; source "$LODGE_DIR/lib/sys/vitals.sh"; assert_eq "$VITALS_RAM_WARN_MB" "200"; }

  it "default RAM crit threshold is 100" && { unset VITALS_RAM_CRIT_MB; unset _LIB_VITALS_LOADED; source "$LODGE_DIR/lib/sys/vitals.sh"; assert_eq "$VITALS_RAM_CRIT_MB" "100"; }

  it "default battery warn is 15" && { unset VITALS_BATTERY_WARN; unset _LIB_VITALS_LOADED; source "$LODGE_DIR/lib/sys/vitals.sh"; assert_eq "$VITALS_BATTERY_WARN" "15"; }

  it "default battery crit is 5" && { unset VITALS_BATTERY_CRIT; unset _LIB_VITALS_LOADED; source "$LODGE_DIR/lib/sys/vitals.sh"; assert_eq "$VITALS_BATTERY_CRIT" "5"; }

  it "custom thresholds are respected" && { export VITALS_DISK_WARN_MB=2000; unset _LIB_VITALS_LOADED; source "$LODGE_DIR/lib/sys/vitals.sh"; assert_eq "$VITALS_DISK_WARN_MB" "2000"; }

test_end
