#!/bin/bash
# ── George: Phone Integration (Termux API) ─────────────────
# Location awareness, SMS access, telephony status, and more.
# Requires: Termux:API app + termux-api package
#
# Permissions needed (grant manually in Android Settings):
#   - ACCESS_FINE_LOCATION   (GPS/WiFi location)
#   - READ_PHONE_STATE       (call status, SIM info)
#   - READ_SMS               (text messages)
#   - READ_CALL_LOG          (call history)
#   - RECEIVE_SMS            (SMS notifications)

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Timeout for Termux API calls (seconds) ─────────────────────
PHONE_API_TIMEOUT="${PHONE_API_TIMEOUT:-10}"

# ── Detect proot environment ───────────────────────────────────
# Termux-API commands hang indefinitely inside proot-distro because
# the companion app can't communicate through the proot boundary.
phone_is_proot() {
    # Method 1: proot sets this env var
    [ -n "${PROOT_TMP_DIR:-}" ] && return 0
    # Method 2: check for proot marker in /proc
    [ -f /proc/self/status ] && grep -qi 'TracerPid:[[:space:]]*[1-9]' /proc/self/status 2>/dev/null && return 0
    # Method 3: common proot-distro install path
    [ -f /etc/proot-distro ] && return 0
    # Method 4: /host-rootfs exists (proot bind mount)
    [ -d /host-rootfs ] && return 0
    return 1
}

# ── Check Termux API availability ──────────────────────────────
phone_available() {
    # Fail fast if inside proot — commands will hang
    phone_is_proot && return 1
    # termux-battery-status is the most basic API command
    command -v termux-battery-status &>/dev/null
}

phone_check() {
    if phone_is_proot; then
        ui_warn "Termux:API commands do not work inside proot-distro"
        ui_dim "Phone features require running Lodge from native Termux."
        ui_dim "Exit proot first:  exit"
        ui_dim "Then run lodge from the Termux shell directly."
        return 1
    fi
    if ! phone_available; then
        ui_warn "Termux:API not available"
        ui_dim "Install: pkg install termux-api"
        ui_dim "Also install the Termux:API app from F-Droid"
        return 1
    fi
    return 0
}

# ── Safe wrapper: run a termux-* command with timeout ──────────
# Prevents indefinite hangs if permissions aren't granted or the
# Termux:API companion app is missing/broken.
phone_api_call() {
    local cmd="$1"; shift
    if phone_is_proot; then
        echo '{"error": "termux-api unavailable inside proot"}'
        return 1
    fi
    if ! command -v "$cmd" &>/dev/null; then
        echo "{\"error\": \"$cmd not installed\"}"
        return 1
    fi
    local result
    result=$(timeout "${PHONE_API_TIMEOUT}" "$cmd" "$@" 2>/dev/null)
    local rc=$?
    if [ $rc -eq 124 ]; then
        ui_warn "$cmd timed out after ${PHONE_API_TIMEOUT}s"
        ui_dim "Permissions may not be granted. Run: /phone permissions"
        echo '{"error": "timeout — check permissions"}'
        return 1
    fi
    echo "$result"
    return $rc
}

# ── Permission troubleshooter ──────────────────────────────────
phone_fix_permissions() {
    ui_section "Termux:API Permission Setup"
    echo ""
    ui_info "Termux:API needs TWO things installed:"
    echo ""
    printf "  %b1.%b The %btermux-api%b package:\n" "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf "     pkg install termux-api\n"
    echo ""
    printf "  %b2.%b The %bTermux:API%b Android app (separate from Termux):\n" "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf "     Install from F-Droid: https://f-droid.org\n"
    printf "     Search for \"Termux:API\" and install it\n"
    echo ""
    ui_info "Then grant permissions manually in Android Settings:"
    echo ""
    printf "  %bSettings → Apps → Termux:API → Permissions%b\n" "$C_BOLD" "$C_RESET"
    echo ""
    printf "  Enable these permissions:\n"
    printf "    • %bLocation%b        (for /phone location, /phone where)\n" "$C_CYAN" "$C_RESET"
    printf "    • %bPhone%b           (for /phone telephony, /phone cell)\n" "$C_CYAN" "$C_RESET"
    printf "    • %bSMS%b             (for /phone sms)\n" "$C_CYAN" "$C_RESET"
    printf "    • %bCall logs%b       (for /phone calls)\n" "$C_CYAN" "$C_RESET"
    printf "    • %bNotifications%b   (for /phone notify)\n" "$C_CYAN" "$C_RESET"
    echo ""
    printf "  Also grant the same permissions for the %bTermux%b app itself:\n" "$C_BOLD" "$C_RESET"
    printf "  %bSettings → Apps → Termux → Permissions%b\n" "$C_BOLD" "$C_RESET"
    echo ""
    ui_warn "IMPORTANT: Android 12+ often does NOT auto-prompt for permissions."
    ui_dim "You MUST grant them manually through Settings as described above."
    echo ""
    ui_warn "proot limitation: /phone commands must run from native Termux."
    ui_dim "If you're inside proot-distro Ubuntu, exit first, then run lodge."
    echo ""

    # Quick connectivity test
    if phone_is_proot; then
        ui_err "⚠  You are currently inside proot. Exit first to use phone features."
    elif command -v termux-battery-status &>/dev/null; then
        ui_step "Testing termux-battery-status..."
        local test_out
        test_out=$(timeout 8 termux-battery-status 2>/dev/null)
        if [ -n "$test_out" ] && echo "$test_out" | jq -e '.percentage' &>/dev/null 2>&1; then
            ui_ok "Termux:API is working! Battery: $(echo "$test_out" | jq -r '.percentage')%"
        else
            ui_err "termux-battery-status returned no data."
            ui_dim "The Termux:API app may not be installed, or permissions are missing."
        fi
    else
        ui_err "termux-api package not installed. Run: pkg install termux-api"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Location
# ═══════════════════════════════════════════════════════════════

# ── Get current location ──────────────────────────────────────
# Provider: gps | network | passive
# GPS is most accurate but slow indoors; network uses WiFi/cell towers.
phone_location() {
    local provider="${1:-network}"
    local timeout="${2:-30}"

    if phone_is_proot; then
        ui_warn "Location not available inside proot"
        echo '{"error": "termux-api unavailable inside proot"}'
        return 1
    fi
    if ! command -v termux-location &>/dev/null; then
        ui_warn "termux-location not available"
        echo '{"error": "termux-location not installed"}'
        return 1
    fi

    ui_step "Getting location (provider: $provider)..."
    local loc
    loc=$(timeout "$timeout" termux-location -p "$provider" 2>/dev/null)

    if [ -z "$loc" ] || [ "$loc" = "null" ]; then
        ui_warn "Location unavailable (provider: $provider)"
        # Fallback: try network if GPS failed
        if [ "$provider" = "gps" ]; then
            ui_dim "Falling back to network provider..."
            loc=$(timeout "$timeout" termux-location -p network 2>/dev/null)
        fi
    fi

    if [ -z "$loc" ] || [ "$loc" = "null" ]; then
        echo '{"error": "location unavailable"}'
        return 1
    fi

    echo "$loc"
}

# ── Get location as human-readable summary ─────────────────────
phone_location_summary() {
    local loc
    loc=$(phone_location "${1:-network}" "${2:-30}")

    if echo "$loc" | jq -e '.error' &>/dev/null 2>&1; then
        echo "$loc"
        return 1
    fi

    local lat lon alt acc
    lat=$(echo "$loc" | jq -r '.latitude // "unknown"' 2>/dev/null)
    lon=$(echo "$loc" | jq -r '.longitude // "unknown"' 2>/dev/null)
    alt=$(echo "$loc" | jq -r '.altitude // "unknown"' 2>/dev/null)
    acc=$(echo "$loc" | jq -r '.accuracy // "unknown"' 2>/dev/null)

    printf "  %bLatitude:%b  %s\n" "$C_CYAN" "$C_RESET" "$lat"
    printf "  %bLongitude:%b %s\n" "$C_CYAN" "$C_RESET" "$lon"
    printf "  %bAltitude:%b  %s m\n" "$C_CYAN" "$C_RESET" "$alt"
    printf "  %bAccuracy:%b  %s m\n" "$C_CYAN" "$C_RESET" "$acc"
}

# ── Get location as compact context for LLM injection ──────────
# Returns a single line like: "Location: 38.8977° N, 77.0365° W (±15m)"
phone_location_context() {
    local loc
    loc=$(phone_location "network" "15" 2>/dev/null)
    local rc=$?

    if [ $rc -ne 0 ] || [ -z "$loc" ] || echo "$loc" | jq -e '.error' &>/dev/null; then
        echo "Location: unavailable"
        return 1
    fi

    local lat lon acc
    lat=$(echo "$loc" | jq -r '.latitude' 2>/dev/null)
    lon=$(echo "$loc" | jq -r '.longitude' 2>/dev/null)
    acc=$(echo "$loc" | jq -r '.accuracy // "?"' 2>/dev/null)

    # Format with N/S E/W
    local lat_dir="N" lon_dir="E"
    if (( $(echo "$lat < 0" | bc -l 2>/dev/null || echo 0) )); then
        lat_dir="S"
        lat=$(echo "$lat" | sed 's/^-//')
    fi
    if (( $(echo "$lon < 0" | bc -l 2>/dev/null || echo 0) )); then
        lon_dir="W"
        lon=$(echo "$lon" | sed 's/^-//')
    fi

    echo "Location: ${lat}° ${lat_dir}, ${lon}° ${lon_dir} (±${acc}m)"
}

# ═══════════════════════════════════════════════════════════════
# SMS (Text Messages)
# ═══════════════════════════════════════════════════════════════

# ── List recent text messages ─────────────────────────────────
# Type: inbox | sent | draft | all
phone_sms_list() {
    local type="${1:-inbox}"
    local limit="${2:-10}"
    local offset="${3:-0}"

    local msgs
    msgs=$(phone_api_call termux-sms-list -t "$type" -l "$limit" -o "$offset")
    [ $? -ne 0 ] && return 1

    if [ -z "$msgs" ] || [ "$msgs" = "[]" ]; then
        ui_dim "  No messages found (type: $type)"
        return 0
    fi

    echo "$msgs"
}

# ── Display SMS messages in human-readable format ──────────────
phone_sms_pretty() {
    local type="${1:-inbox}"
    local limit="${2:-10}"

    local msgs
    msgs=$(phone_sms_list "$type" "$limit")
    [ -z "$msgs" ] && return 0

    echo "$msgs" | jq -r '.[] | "  [\(.received // .date)] \(.number): \(.body[0:120])"' 2>/dev/null
}

# ── Send an SMS ───────────────────────────────────────────────
phone_sms_send() {
    local number="$1"
    local body="$2"

    if [ -z "$number" ] || [ -z "$body" ]; then
        ui_err "Usage: phone_sms_send <number> <message>"
        return 1
    fi

    if ! command -v termux-sms-send &>/dev/null; then
        ui_warn "termux-sms-send not available"
        return 1
    fi

    # Require explicit permission — sending SMS costs money
    if [ "${LODGE_PERMISSION:-1}" -le 1 ]; then
        if ! ui_confirm "Send SMS to $number: \"${body:0:60}...\"?"; then
            ui_dim "SMS cancelled"
            return 1
        fi
    fi

    termux-sms-send -n "$number" "$body"
    ui_ok "SMS sent to $number"
}

# ═══════════════════════════════════════════════════════════════
# Telephony Status
# ═══════════════════════════════════════════════════════════════

# ── Get telephony info (SIM, network, call state) ─────────────
phone_telephony_info() {
    phone_api_call termux-telephony-deviceinfo
}

# ── Get current call state ────────────────────────────────────
# Returns: idle | ringing | offhook (in call)
phone_call_state() {
    local info
    info=$(phone_telephony_info)
    [ -z "$info" ] && return 1

    local state
    state=$(echo "$info" | jq -r '.device_phone_type // "unknown"' 2>/dev/null)
    # The call state is part of telephony-cellinfo or phone_type
    # Termux doesn't expose call state directly, but we can check:
    echo "$info" | jq -r '{
        phone_type: .device_phone_type,
        network_operator: .network_operator_name,
        network_type:     .network_type,
        sim_operator:     .sim_operator_name,
        sim_state:        .sim_state,
        data_state:       .data_state
    }' 2>/dev/null
}

# ── Get signal strength / cell info ───────────────────────────
phone_cell_info() {
    phone_api_call termux-telephony-cellinfo
}

# ── Get call log ──────────────────────────────────────────────
phone_call_log() {
    local limit="${1:-10}"
    local offset="${2:-0}"

    phone_api_call termux-call-log -l "$limit" -o "$offset"
}

# ── Display call log in human-readable format ─────────────────
phone_call_log_pretty() {
    local limit="${1:-10}"

    local log
    log=$(phone_call_log "$limit")
    [ -z "$log" ] && return 0

    echo "$log" | jq -r '.[] | "  [\(.date)] \(.type) — \(.name // .number) (\(.duration)s)"' 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
# WiFi & Connectivity
# ═══════════════════════════════════════════════════════════════

# ── Get WiFi connection info ──────────────────────────────────
phone_wifi_info() {
    phone_api_call termux-wifi-connectioninfo
}

# ── Scan nearby WiFi networks ─────────────────────────────────
phone_wifi_scan() {
    phone_api_call termux-wifi-scaninfo
}

# ═══════════════════════════════════════════════════════════════
# Sensors & Status
# ═══════════════════════════════════════════════════════════════

# ── Comprehensive phone status for LLM context ────────────────
# Gathers battery + location + connectivity into a compact summary.
phone_status_context() {
    if phone_is_proot; then echo ""; return 0; fi
    local ctx=""

    # Battery
    local batt
    batt=$(phone_api_call termux-battery-status 2>/dev/null)
    if [ -n "$batt" ] && echo "$batt" | jq -e '.percentage' &>/dev/null 2>&1; then
        local pct status
        pct=$(echo "$batt" | jq -r '.percentage // "?"' 2>/dev/null)
        status=$(echo "$batt" | jq -r '.status // "?"' 2>/dev/null)
        ctx="Battery: ${pct}% ($status)"
    fi

    # WiFi
    local wifi
    wifi=$(phone_api_call termux-wifi-connectioninfo 2>/dev/null)
    if [ -n "$wifi" ] && echo "$wifi" | jq -e '.ssid' &>/dev/null 2>&1; then
        local ssid
        ssid=$(echo "$wifi" | jq -r '.ssid // "disconnected"' 2>/dev/null)
        if [ "$ssid" != "null" ] && [ "$ssid" != "<unknown ssid>" ]; then
            ctx="${ctx:+$ctx | }WiFi: $ssid"
        fi
    fi

    # Location (quick, network only, 10s timeout)
    local loc_ctx
    loc_ctx=$(phone_location_context 2>/dev/null)
    if [ -n "$loc_ctx" ] && [[ "$loc_ctx" != *"unavailable"* ]]; then
        ctx="${ctx:+$ctx | }$loc_ctx"
    fi

    echo "$ctx"
}

# ── Full phone dashboard ──────────────────────────────────────
phone_dashboard() {
    if ! phone_check; then return 1; fi
    ui_section "Phone Status"

    # Battery
    local batt
    batt=$(phone_api_call termux-battery-status 2>/dev/null)
    if [ -n "$batt" ] && echo "$batt" | jq -e '.percentage' &>/dev/null 2>&1; then
        local pct status temp
        pct=$(echo "$batt" | jq -r '.percentage' 2>/dev/null)
        status=$(echo "$batt" | jq -r '.status' 2>/dev/null)
        temp=$(echo "$batt" | jq -r '.temperature' 2>/dev/null)
        printf "  %bBattery:%b    %s%% (%s, %s°C)\n" "$C_CYAN" "$C_RESET" "$pct" "$status" "$temp"
    fi

    # Telephony
    local tel
    tel=$(phone_api_call termux-telephony-deviceinfo 2>/dev/null)
    if [ -n "$tel" ] && echo "$tel" | jq -e '.network_operator_name' &>/dev/null 2>&1; then
        local carrier sim_state data
        carrier=$(echo "$tel" | jq -r '.network_operator_name // "unknown"' 2>/dev/null)
        sim_state=$(echo "$tel" | jq -r '.sim_state // "unknown"' 2>/dev/null)
        data=$(echo "$tel" | jq -r '.data_state // "unknown"' 2>/dev/null)
        printf "  %bCarrier:%b    %s (SIM: %s, Data: %s)\n" "$C_CYAN" "$C_RESET" "$carrier" "$sim_state" "$data"
    fi

    # WiFi
    local wifi
    wifi=$(phone_api_call termux-wifi-connectioninfo 2>/dev/null)
    if [ -n "$wifi" ] && echo "$wifi" | jq -e '.ssid' &>/dev/null 2>&1; then
        local ssid freq rssi ip
        ssid=$(echo "$wifi" | jq -r '.ssid // "disconnected"' 2>/dev/null)
        freq=$(echo "$wifi" | jq -r '.frequency_mhz // "?"' 2>/dev/null)
        rssi=$(echo "$wifi" | jq -r '.rssi // "?"' 2>/dev/null)
        ip=$(echo "$wifi" | jq -r '.ip // "?"' 2>/dev/null)
        printf "  %bWiFi:%b       %s (%s MHz, %s dBm)\n" "$C_CYAN" "$C_RESET" "$ssid" "$freq" "$rssi"
        printf "  %bIP:%b         %s\n" "$C_CYAN" "$C_RESET" "$ip"
    fi

    # Location
    echo ""
    ui_dim "  Requesting location..."
    phone_location_summary "network" "15"

    echo ""
}
