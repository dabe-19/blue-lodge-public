#!/bin/bash
# ── George: Phone Integration (Termux API) ─────────────────
# Location awareness, SMS access, telephony status, and more.
# Requires: Termux:API app + termux-api package
#
# Permissions needed (Android will prompt on first use):
#   - ACCESS_FINE_LOCATION   (GPS/WiFi location)
#   - READ_PHONE_STATE       (call status, SIM info)
#   - READ_SMS               (text messages)
#   - READ_CALL_LOG          (call history)
#   - RECEIVE_SMS            (SMS notifications)

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Check Termux API availability ──────────────────────────────
phone_available() {
    # termux-battery-status is the most basic API command
    command -v termux-battery-status &>/dev/null
}

phone_check() {
    if ! phone_available; then
        ui_warn "Termux:API not available"
        ui_dim "Install: pkg install termux-api"
        ui_dim "Also install the Termux:API app from F-Droid"
        return 1
    fi
    return 0
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

    if ! command -v termux-sms-list &>/dev/null; then
        ui_warn "termux-sms-list not available"
        return 1
    fi

    local msgs
    msgs=$(termux-sms-list -t "$type" -l "$limit" -o "$offset" 2>/dev/null)

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
    if ! command -v termux-telephony-deviceinfo &>/dev/null; then
        ui_warn "termux-telephony-deviceinfo not available"
        return 1
    fi

    termux-telephony-deviceinfo 2>/dev/null
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
    if ! command -v termux-telephony-cellinfo &>/dev/null; then
        ui_warn "termux-telephony-cellinfo not available"
        return 1
    fi

    termux-telephony-cellinfo 2>/dev/null
}

# ── Get call log ──────────────────────────────────────────────
phone_call_log() {
    local limit="${1:-10}"
    local offset="${2:-0}"

    if ! command -v termux-call-log &>/dev/null; then
        ui_warn "termux-call-log not available"
        return 1
    fi

    termux-call-log -l "$limit" -o "$offset" 2>/dev/null
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
    if ! command -v termux-wifi-connectioninfo &>/dev/null; then
        ui_warn "termux-wifi-connectioninfo not available"
        return 1
    fi

    termux-wifi-connectioninfo 2>/dev/null
}

# ── Scan nearby WiFi networks ─────────────────────────────────
phone_wifi_scan() {
    if ! command -v termux-wifi-scaninfo &>/dev/null; then
        ui_warn "termux-wifi-scaninfo not available"
        return 1
    fi

    termux-wifi-scaninfo 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
# Sensors & Status
# ═══════════════════════════════════════════════════════════════

# ── Comprehensive phone status for LLM context ────────────────
# Gathers battery + location + connectivity into a compact summary.
phone_status_context() {
    local ctx=""

    # Battery
    if command -v termux-battery-status &>/dev/null; then
        local batt
        batt=$(termux-battery-status 2>/dev/null)
        local pct status
        pct=$(echo "$batt" | jq -r '.percentage // "?"' 2>/dev/null)
        status=$(echo "$batt" | jq -r '.status // "?"' 2>/dev/null)
        ctx="Battery: ${pct}% ($status)"
    fi

    # WiFi
    if command -v termux-wifi-connectioninfo &>/dev/null; then
        local wifi
        wifi=$(termux-wifi-connectioninfo 2>/dev/null)
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
    ui_section "Phone Status"

    # Battery
    if command -v termux-battery-status &>/dev/null; then
        local batt
        batt=$(termux-battery-status 2>/dev/null)
        if [ -n "$batt" ]; then
            local pct status temp
            pct=$(echo "$batt" | jq -r '.percentage' 2>/dev/null)
            status=$(echo "$batt" | jq -r '.status' 2>/dev/null)
            temp=$(echo "$batt" | jq -r '.temperature' 2>/dev/null)
            printf "  %bBattery:%b    %s%% (%s, %s°C)\n" "$C_CYAN" "$C_RESET" "$pct" "$status" "$temp"
        fi
    fi

    # Telephony
    if command -v termux-telephony-deviceinfo &>/dev/null; then
        local tel
        tel=$(termux-telephony-deviceinfo 2>/dev/null)
        if [ -n "$tel" ]; then
            local carrier sim_state data
            carrier=$(echo "$tel" | jq -r '.network_operator_name // "unknown"' 2>/dev/null)
            sim_state=$(echo "$tel" | jq -r '.sim_state // "unknown"' 2>/dev/null)
            data=$(echo "$tel" | jq -r '.data_state // "unknown"' 2>/dev/null)
            printf "  %bCarrier:%b    %s (SIM: %s, Data: %s)\n" "$C_CYAN" "$C_RESET" "$carrier" "$sim_state" "$data"
        fi
    fi

    # WiFi
    if command -v termux-wifi-connectioninfo &>/dev/null; then
        local wifi
        wifi=$(termux-wifi-connectioninfo 2>/dev/null)
        if [ -n "$wifi" ]; then
            local ssid freq rssi ip
            ssid=$(echo "$wifi" | jq -r '.ssid // "disconnected"' 2>/dev/null)
            freq=$(echo "$wifi" | jq -r '.frequency_mhz // "?"' 2>/dev/null)
            rssi=$(echo "$wifi" | jq -r '.rssi // "?"' 2>/dev/null)
            ip=$(echo "$wifi" | jq -r '.ip // "?"' 2>/dev/null)
            printf "  %bWiFi:%b       %s (%s MHz, %s dBm)\n" "$C_CYAN" "$C_RESET" "$ssid" "$freq" "$rssi"
            printf "  %bIP:%b         %s\n" "$C_CYAN" "$C_RESET" "$ip"
        fi
    fi

    # Location
    echo ""
    ui_dim "  Requesting location..."
    phone_location_summary "network" "15"

    echo ""
}
