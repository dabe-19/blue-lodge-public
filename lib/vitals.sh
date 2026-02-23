#!/bin/bash
# ── George: System Vitals ──────────────────────────────────────
# Stateful awareness of the physical environment: disk, RAM,
# battery, WiFi signal, cell signal. George uses these to make
# intelligent decisions about what operations are safe to attempt.
#
# Thresholds (configurable via environment):
#   VITALS_DISK_WARN_MB   — warn when free disk < this (default: 500)
#   VITALS_DISK_CRIT_MB   — block writes when < this (default: 100)
#   VITALS_RAM_WARN_MB    — warn when free RAM < this (default: 200)
#   VITALS_RAM_CRIT_MB    — block heavy ops when < this (default: 100)
#   VITALS_BATTERY_WARN   — warn when battery < this % (default: 15)
#   VITALS_BATTERY_CRIT   — block long ops when < this % (default: 5)

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Thresholds ─────────────────────────────────────────────────
VITALS_DISK_WARN_MB="${VITALS_DISK_WARN_MB:-500}"
VITALS_DISK_CRIT_MB="${VITALS_DISK_CRIT_MB:-100}"
VITALS_RAM_WARN_MB="${VITALS_RAM_WARN_MB:-200}"
VITALS_RAM_CRIT_MB="${VITALS_RAM_CRIT_MB:-100}"
VITALS_BATTERY_WARN="${VITALS_BATTERY_WARN:-15}"
VITALS_BATTERY_CRIT="${VITALS_BATTERY_CRIT:-5}"

# ── Cache: avoid re-reading expensive sensors multiple times ───
_VITALS_CACHE_TTL=30  # seconds
_VITALS_CACHE_TIME=0
_VITALS_CACHE_DISK_FREE_MB=""
_VITALS_CACHE_RAM_FREE_MB=""
_VITALS_CACHE_RAM_TOTAL_MB=""
_VITALS_CACHE_BATTERY_PCT=""
_VITALS_CACHE_BATTERY_STATUS=""
_VITALS_CACHE_WIFI_SSID=""
_VITALS_CACHE_WIFI_RSSI=""
_VITALS_CACHE_CELL_SIGNAL=""

# ═══════════════════════════════════════════════════════════════
# Raw Sensors
# ═══════════════════════════════════════════════════════════════

# ── Disk free space (MB) on the main filesystem ───────────────
vitals_disk_free_mb() {
    df -m "${HOME:-/}" 2>/dev/null | awk 'NR==2{print $4}'
}

# ── Disk total space (MB) ─────────────────────────────────────
vitals_disk_total_mb() {
    df -m "${HOME:-/}" 2>/dev/null | awk 'NR==2{print $2}'
}

# ── Disk usage percentage ─────────────────────────────────────
vitals_disk_pct() {
    df -m "${HOME:-/}" 2>/dev/null | awk 'NR==2{gsub(/%/,""); print $5}'
}

# ── RAM free (MB) — available, not just 'free' ────────────────
vitals_ram_free_mb() {
    # 'available' is the best metric — it includes reclaimable cache
    free -m 2>/dev/null | awk '/^Mem:/{print $7}'
}

# ── RAM total (MB) ────────────────────────────────────────────
vitals_ram_total_mb() {
    free -m 2>/dev/null | awk '/^Mem:/{print $2}'
}

# ── RAM used (MB) ─────────────────────────────────────────────
vitals_ram_used_mb() {
    free -m 2>/dev/null | awk '/^Mem:/{print $3}'
}

# ── Battery percentage (0-100) ────────────────────────────────
vitals_battery_pct() {
    if _lodge_termux_api_ok && command -v termux-battery-status &>/dev/null; then
        termux-battery-status 2>/dev/null | jq -r '.percentage // empty' 2>/dev/null
    elif [ -f /sys/class/power_supply/BAT0/capacity ]; then
        cat /sys/class/power_supply/BAT0/capacity 2>/dev/null
    else
        echo ""
    fi
}

# ── Battery charging status ───────────────────────────────────
vitals_battery_status() {
    if _lodge_termux_api_ok && command -v termux-battery-status &>/dev/null; then
        termux-battery-status 2>/dev/null | jq -r '.status // empty' 2>/dev/null
    elif [ -f /sys/class/power_supply/BAT0/status ]; then
        cat /sys/class/power_supply/BAT0/status 2>/dev/null
    else
        echo ""
    fi
}

# ── WiFi signal strength (RSSI in dBm, e.g. -45) ─────────────
vitals_wifi_rssi() {
    if _lodge_termux_api_ok && command -v termux-wifi-connectioninfo &>/dev/null; then
        termux-wifi-connectioninfo 2>/dev/null | jq -r '.rssi // empty' 2>/dev/null
    else
        # Fallback: iwconfig or /proc/net/wireless
        cat /proc/net/wireless 2>/dev/null | awk 'NR==3{gsub(/\./,""); print -$4}' || echo ""
    fi
}

# ── WiFi SSID ─────────────────────────────────────────────────
vitals_wifi_ssid() {
    if _lodge_termux_api_ok && command -v termux-wifi-connectioninfo &>/dev/null; then
        local ssid
        ssid=$(termux-wifi-connectioninfo 2>/dev/null | jq -r '.ssid // empty' 2>/dev/null)
        # Filter out "unknown" values
        if [ "$ssid" = "<unknown ssid>" ] || [ "$ssid" = "null" ]; then
            echo ""
        else
            echo "$ssid"
        fi
    else
        iwgetid -r 2>/dev/null || echo ""
    fi
}

# ── WiFi link speed (Mbps) ────────────────────────────────────
vitals_wifi_speed() {
    if _lodge_termux_api_ok && command -v termux-wifi-connectioninfo &>/dev/null; then
        termux-wifi-connectioninfo 2>/dev/null | jq -r '.link_speed_mbps // empty' 2>/dev/null
    else
        echo ""
    fi
}

# ── Cell signal level (dBm or ASU) ────────────────────────────
vitals_cell_signal() {
    if _lodge_termux_api_ok && command -v termux-telephony-cellinfo &>/dev/null; then
        # Extract the first registered cell's signal strength
        termux-telephony-cellinfo 2>/dev/null | jq -r '
            [.[] | select(.registered == true)] | .[0] |
            (.dbm // .rssi // .signal_strength // .asu // empty)
        ' 2>/dev/null
    else
        echo ""
    fi
}

# ── Cell network type (LTE, NR, etc.) ─────────────────────────
vitals_cell_type() {
    if _lodge_termux_api_ok && command -v termux-telephony-deviceinfo &>/dev/null; then
        termux-telephony-deviceinfo 2>/dev/null | jq -r '.network_type // empty' 2>/dev/null
    else
        echo ""
    fi
}

# ── Network connectivity (quick check) ────────────────────────
vitals_net_reachable() {
    # Fast: just check if we can reach DNS, 2s timeout
    timeout 2 bash -c 'echo >/dev/tcp/1.1.1.1/53' 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
# Cached Snapshot
# ═══════════════════════════════════════════════════════════════

# Refresh the cache if stale (older than TTL seconds)
_vitals_refresh_cache() {
    local now
    now=$(date +%s)
    local age=$(( now - _VITALS_CACHE_TIME ))

    if [ "$age" -lt "$_VITALS_CACHE_TTL" ] && [ "$_VITALS_CACHE_TIME" -gt 0 ]; then
        return 0  # cache is fresh
    fi

    _VITALS_CACHE_DISK_FREE_MB=$(vitals_disk_free_mb)
    _VITALS_CACHE_RAM_FREE_MB=$(vitals_ram_free_mb)
    _VITALS_CACHE_RAM_TOTAL_MB=$(vitals_ram_total_mb)
    _VITALS_CACHE_BATTERY_PCT=$(vitals_battery_pct)
    _VITALS_CACHE_BATTERY_STATUS=$(vitals_battery_status)
    _VITALS_CACHE_WIFI_SSID=$(vitals_wifi_ssid)
    _VITALS_CACHE_WIFI_RSSI=$(vitals_wifi_rssi)
    _VITALS_CACHE_CELL_SIGNAL=$(vitals_cell_signal)
    _VITALS_CACHE_TIME=$now
}

# Force-refresh (bypass TTL)
vitals_refresh() {
    _VITALS_CACHE_TIME=0
    _vitals_refresh_cache
}

# ═══════════════════════════════════════════════════════════════
# Status Assessments (Green / Yellow / Red)
# ═══════════════════════════════════════════════════════════════

# Returns: ok | warn | critical
vitals_disk_status() {
    _vitals_refresh_cache
    local free="${_VITALS_CACHE_DISK_FREE_MB:-0}"
    if [ "$free" -lt "$VITALS_DISK_CRIT_MB" ] 2>/dev/null; then
        echo "critical"
    elif [ "$free" -lt "$VITALS_DISK_WARN_MB" ] 2>/dev/null; then
        echo "warn"
    else
        echo "ok"
    fi
}

vitals_ram_status() {
    _vitals_refresh_cache
    local free="${_VITALS_CACHE_RAM_FREE_MB:-0}"
    if [ "$free" -lt "$VITALS_RAM_CRIT_MB" ] 2>/dev/null; then
        echo "critical"
    elif [ "$free" -lt "$VITALS_RAM_WARN_MB" ] 2>/dev/null; then
        echo "warn"
    else
        echo "ok"
    fi
}

vitals_battery_status_level() {
    _vitals_refresh_cache
    local pct="${_VITALS_CACHE_BATTERY_PCT:-100}"
    local status="${_VITALS_CACHE_BATTERY_STATUS:-}"

    # Charging is always OK
    if [ "$status" = "CHARGING" ] || [ "$status" = "FULL" ]; then
        echo "ok"
        return
    fi

    if [ "$pct" -lt "$VITALS_BATTERY_CRIT" ] 2>/dev/null; then
        echo "critical"
    elif [ "$pct" -lt "$VITALS_BATTERY_WARN" ] 2>/dev/null; then
        echo "warn"
    else
        echo "ok"
    fi
}

# WiFi: ok (>-60), warn (-60 to -75), critical (<-75 or disconnected)
vitals_wifi_status() {
    _vitals_refresh_cache
    local rssi="${_VITALS_CACHE_WIFI_RSSI:-}"
    local ssid="${_VITALS_CACHE_WIFI_SSID:-}"

    if [ -z "$ssid" ] && [ -z "$rssi" ]; then
        echo "none"
        return
    fi

    if [ -z "$rssi" ]; then
        echo "ok"  # connected but no RSSI data
        return
    fi

    # RSSI is negative; closer to 0 = better
    if [ "$rssi" -gt -60 ] 2>/dev/null; then
        echo "ok"
    elif [ "$rssi" -gt -75 ] 2>/dev/null; then
        echo "warn"
    else
        echo "critical"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Guard Functions — Call before risky operations
# ═══════════════════════════════════════════════════════════════

# Check if it's safe to write files (disk not critically low)
vitals_guard_disk() {
    local status
    status=$(vitals_disk_status)
    if [ "$status" = "critical" ]; then
        ui_err "DISK CRITICAL: Only ${_VITALS_CACHE_DISK_FREE_MB}MB free — aborting to prevent data loss"
        ui_dim "Free up space: du -sh $LODGE_DIR/.sandboxes/* $LODGE_DIR/.george/slash/*"
        return 1
    elif [ "$status" = "warn" ]; then
        ui_warn "Disk low: ${_VITALS_CACHE_DISK_FREE_MB}MB free (threshold: ${VITALS_DISK_WARN_MB}MB)"
    fi
    return 0
}

# Check if it's safe to run memory-intensive operations
vitals_guard_ram() {
    local status
    status=$(vitals_ram_status)
    if [ "$status" = "critical" ]; then
        ui_err "RAM CRITICAL: Only ${_VITALS_CACHE_RAM_FREE_MB}MB available — operation may fail"
        ui_dim "Free RAM: close other apps or use /compact"
        return 1
    elif [ "$status" = "warn" ]; then
        ui_warn "RAM low: ${_VITALS_CACHE_RAM_FREE_MB}MB available (threshold: ${VITALS_RAM_WARN_MB}MB)"
    fi
    return 0
}

# Check if it's safe to run long operations (battery not critical)
vitals_guard_battery() {
    local status
    status=$(vitals_battery_status_level)
    if [ "$status" = "critical" ]; then
        ui_err "BATTERY CRITICAL: ${_VITALS_CACHE_BATTERY_PCT}% — aborting to preserve power"
        ui_dim "Plug in the charger before running long tasks"
        return 1
    elif [ "$status" = "warn" ]; then
        ui_warn "Battery low: ${_VITALS_CACHE_BATTERY_PCT}% — keep tasks short"
    fi
    return 0
}

# Check if network operations are feasible
vitals_guard_network() {
    _vitals_refresh_cache
    local wifi="${_VITALS_CACHE_WIFI_SSID:-}"
    local cell="${_VITALS_CACHE_CELL_SIGNAL:-}"

    # If we have neither WiFi nor cell, warn
    if [ -z "$wifi" ] && [ -z "$cell" ]; then
        # Quick reachability check
        if ! vitals_net_reachable; then
            ui_err "NO NETWORK: WiFi disconnected, no cell signal, host unreachable"
            ui_dim "Network operations will fail — skip web/API calls"
            return 1
        fi
    fi

    # If WiFi signal is critical
    local wifi_status
    wifi_status=$(vitals_wifi_status)
    if [ "$wifi_status" = "critical" ]; then
        ui_warn "WiFi signal weak (RSSI: ${_VITALS_CACHE_WIFI_RSSI}dBm) — network may be unreliable"
    fi

    return 0
}

# Combined pre-flight check — call before any significant operation
vitals_preflight() {
    local severity="${1:-warn}"  # "warn" = non-blocking, "strict" = abort on any issue
    local issues=0

    _vitals_refresh_cache

    # Disk
    local disk_st
    disk_st=$(vitals_disk_status)
    if [ "$disk_st" = "critical" ]; then
        vitals_guard_disk
        [ "$severity" = "strict" ] && return 1
        issues=$((issues + 1))
    elif [ "$disk_st" = "warn" ]; then
        vitals_guard_disk
    fi

    # RAM
    local ram_st
    ram_st=$(vitals_ram_status)
    if [ "$ram_st" = "critical" ]; then
        vitals_guard_ram
        [ "$severity" = "strict" ] && return 1
        issues=$((issues + 1))
    elif [ "$ram_st" = "warn" ]; then
        vitals_guard_ram
    fi

    # Battery
    local batt_st
    batt_st=$(vitals_battery_status_level)
    if [ "$batt_st" = "critical" ]; then
        vitals_guard_battery
        [ "$severity" = "strict" ] && return 1
        issues=$((issues + 1))
    fi

    return "$issues"
}

# ═══════════════════════════════════════════════════════════════
# Context Strings (for LLM prompt injection)
# ═══════════════════════════════════════════════════════════════

# Compact one-line vitals string for system prompt injection.
# ~30-50 tokens. Only includes concerning items + always disk/RAM.
# Example: "[Vitals: Disk 2.1GB/24GB | RAM 1.8GB/12GB | Bat 72% | WiFi -52dBm]"
vitals_context() {
    _vitals_refresh_cache

    local parts=()

    # Disk — always include
    local disk_free="${_VITALS_CACHE_DISK_FREE_MB:-?}"
    local disk_total
    disk_total=$(vitals_disk_total_mb)
    if [ -n "$disk_free" ] && [ "$disk_free" != "?" ]; then
        local disk_gb
        disk_gb=$(awk "BEGIN{printf \"%.1f\", $disk_free / 1024}" 2>/dev/null || echo "$disk_free")
        local disk_total_gb
        disk_total_gb=$(awk "BEGIN{printf \"%.0f\", ${disk_total:-0} / 1024}" 2>/dev/null || echo "?")
        local disk_tag="Disk ${disk_gb}GB/${disk_total_gb}GB"
        local disk_st
        disk_st=$(vitals_disk_status)
        [ "$disk_st" = "critical" ] && disk_tag="DISK LOW ${disk_gb}GB/${disk_total_gb}GB"
        [ "$disk_st" = "warn" ] && disk_tag="Disk ${disk_gb}GB/${disk_total_gb}GB(!)"
        parts+=("$disk_tag")
    fi

    # RAM — always include
    local ram_free="${_VITALS_CACHE_RAM_FREE_MB:-?}"
    local ram_total="${_VITALS_CACHE_RAM_TOTAL_MB:-?}"
    if [ -n "$ram_free" ] && [ "$ram_free" != "?" ]; then
        local ram_gb
        ram_gb=$(awk "BEGIN{printf \"%.1f\", $ram_free / 1024}" 2>/dev/null || echo "$ram_free")
        local ram_total_gb
        ram_total_gb=$(awk "BEGIN{printf \"%.0f\", ${ram_total:-0} / 1024}" 2>/dev/null || echo "?")
        local ram_tag="RAM ${ram_gb}GB/${ram_total_gb}GB"
        local ram_st
        ram_st=$(vitals_ram_status)
        [ "$ram_st" = "critical" ] && ram_tag="RAM LOW ${ram_gb}GB/${ram_total_gb}GB"
        [ "$ram_st" = "warn" ] && ram_tag="RAM ${ram_gb}GB/${ram_total_gb}GB(!)"
        parts+=("$ram_tag")
    fi

    # Battery — include if available
    local batt="${_VITALS_CACHE_BATTERY_PCT:-}"
    if [ -n "$batt" ]; then
        local batt_tag="Bat ${batt}%"
        local charge="${_VITALS_CACHE_BATTERY_STATUS:-}"
        [ "$charge" = "CHARGING" ] && batt_tag="Bat ${batt}%⚡"
        local batt_st
        batt_st=$(vitals_battery_status_level)
        [ "$batt_st" = "critical" ] && batt_tag="BAT LOW ${batt}%"
        [ "$batt_st" = "warn" ] && batt_tag="Bat ${batt}%(!)"
        parts+=("$batt_tag")
    fi

    # WiFi — include if connected
    local ssid="${_VITALS_CACHE_WIFI_SSID:-}"
    local rssi="${_VITALS_CACHE_WIFI_RSSI:-}"
    if [ -n "$ssid" ]; then
        local wifi_tag="WiFi"
        [ -n "$rssi" ] && wifi_tag="WiFi ${rssi}dBm"
        local wifi_st
        wifi_st=$(vitals_wifi_status)
        [ "$wifi_st" = "critical" ] && wifi_tag="WiFi WEAK ${rssi}dBm"
        parts+=("$wifi_tag")
    elif [ -z "$ssid" ] && [ -z "${_VITALS_CACHE_CELL_SIGNAL:-}" ]; then
        parts+=("NO NET")
    fi

    # Cell — include if no WiFi or if signal available
    local cell="${_VITALS_CACHE_CELL_SIGNAL:-}"
    if [ -n "$cell" ] && [ -z "$ssid" ]; then
        local cell_type
        cell_type=$(vitals_cell_type)
        parts+=("Cell ${cell_type:-?} ${cell}dBm")
    fi

    # Build the line
    local joined
    joined=$(IFS=" | "; echo "${parts[*]}")
    echo "[Vitals: $joined]"
}

# ── Warnings-only context (for ask mode — ultra compact) ───────
# Only includes items that are warn/critical. Empty string if all OK.
vitals_context_warnings() {
    _vitals_refresh_cache
    local warnings=()

    local disk_st
    disk_st=$(vitals_disk_status)
    [ "$disk_st" != "ok" ] && warnings+=("Disk ${_VITALS_CACHE_DISK_FREE_MB}MB free")

    local ram_st
    ram_st=$(vitals_ram_status)
    [ "$ram_st" != "ok" ] && warnings+=("RAM ${_VITALS_CACHE_RAM_FREE_MB}MB free")

    local batt_st
    batt_st=$(vitals_battery_status_level)
    [ "$batt_st" != "ok" ] && warnings+=("Battery ${_VITALS_CACHE_BATTERY_PCT}%")

    local wifi_st
    wifi_st=$(vitals_wifi_status)
    [ "$wifi_st" = "none" ] && warnings+=("No WiFi")
    [ "$wifi_st" = "critical" ] && warnings+=("WiFi weak")

    if [ ${#warnings[@]} -gt 0 ]; then
        local joined
        joined=$(IFS=", "; echo "${warnings[*]}")
        echo "[WARNING: $joined]"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Dashboard (human-readable)
# ═══════════════════════════════════════════════════════════════

vitals_dashboard() {
    vitals_refresh  # force fresh read

    ui_section "System Vitals"

    # ── Disk ───────────────────────────────────────────────────
    local disk_free disk_total disk_pct disk_st
    disk_free="${_VITALS_CACHE_DISK_FREE_MB:-?}"
    disk_total=$(vitals_disk_total_mb)
    disk_pct=$(vitals_disk_pct)
    disk_st=$(vitals_disk_status)
    local disk_color="$C_GREEN"
    [ "$disk_st" = "warn" ] && disk_color="$C_YELLOW"
    [ "$disk_st" = "critical" ] && disk_color="$C_RED"
    printf "  %bDisk:%b     %b%s MB free%b / %s MB total (%s%% used)\n" \
        "$C_CYAN" "$C_RESET" "$disk_color" "$disk_free" "$C_RESET" "$disk_total" "$disk_pct"

    # ── RAM ────────────────────────────────────────────────────
    local ram_free ram_used ram_total ram_st
    ram_free="${_VITALS_CACHE_RAM_FREE_MB:-?}"
    ram_used=$(vitals_ram_used_mb)
    ram_total="${_VITALS_CACHE_RAM_TOTAL_MB:-?}"
    ram_st=$(vitals_ram_status)
    local ram_color="$C_GREEN"
    [ "$ram_st" = "warn" ] && ram_color="$C_YELLOW"
    [ "$ram_st" = "critical" ] && ram_color="$C_RED"
    printf "  %bRAM:%b      %b%s MB available%b / %s MB total (%s MB used)\n" \
        "$C_CYAN" "$C_RESET" "$ram_color" "$ram_free" "$C_RESET" "$ram_total" "$ram_used"

    # ── Battery ────────────────────────────────────────────────
    local batt_pct batt_status batt_st
    batt_pct="${_VITALS_CACHE_BATTERY_PCT:-}"
    batt_status="${_VITALS_CACHE_BATTERY_STATUS:-}"
    if [ -n "$batt_pct" ]; then
        batt_st=$(vitals_battery_status_level)
        local batt_color="$C_GREEN"
        [ "$batt_st" = "warn" ] && batt_color="$C_YELLOW"
        [ "$batt_st" = "critical" ] && batt_color="$C_RED"
        printf "  %bBattery:%b  %b%s%%%b (%s)\n" \
            "$C_CYAN" "$C_RESET" "$batt_color" "$batt_pct" "$C_RESET" "$batt_status"
    else
        printf "  %bBattery:%b  %b(not available)%b\n" "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET"
    fi

    # ── WiFi ───────────────────────────────────────────────────
    local ssid rssi wifi_st
    ssid="${_VITALS_CACHE_WIFI_SSID:-}"
    rssi="${_VITALS_CACHE_WIFI_RSSI:-}"
    wifi_st=$(vitals_wifi_status)
    if [ -n "$ssid" ]; then
        local wifi_color="$C_GREEN"
        [ "$wifi_st" = "warn" ] && wifi_color="$C_YELLOW"
        [ "$wifi_st" = "critical" ] && wifi_color="$C_RED"
        local speed
        speed=$(vitals_wifi_speed)
        local speed_str=""
        [ -n "$speed" ] && speed_str=", ${speed}Mbps"
        printf "  %bWiFi:%b     %b%s%b (RSSI: %s dBm%s)\n" \
            "$C_CYAN" "$C_RESET" "$wifi_color" "$ssid" "$C_RESET" "${rssi:-?}" "$speed_str"
    else
        printf "  %bWiFi:%b     %b(disconnected)%b\n" "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET"
    fi

    # ── Cell ───────────────────────────────────────────────────
    local cell cell_type
    cell="${_VITALS_CACHE_CELL_SIGNAL:-}"
    if [ -n "$cell" ]; then
        cell_type=$(vitals_cell_type)
        printf "  %bCell:%b     %s %s dBm\n" "$C_CYAN" "$C_RESET" "${cell_type:-?}" "$cell"
    else
        printf "  %bCell:%b     %b(not available)%b\n" "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET"
    fi

    # ── Network reachability ───────────────────────────────────
    printf "  %bNetwork:%b  " "$C_CYAN" "$C_RESET"
    if vitals_net_reachable; then
        printf "%b✓ reachable%b\n" "$C_GREEN" "$C_RESET"
    else
        printf "%b✗ unreachable%b\n" "$C_RED" "$C_RESET"
    fi

    echo ""

    # ── Summary line ───────────────────────────────────────────
    echo "  $(vitals_context)"
    echo ""
}
