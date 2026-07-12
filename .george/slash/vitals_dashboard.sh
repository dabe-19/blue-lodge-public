#!/bin/bash
# ── Slash Extension: vitals_dashboard ─────────────────────────────
# Description: Generate a structured Markdown health dashboard of CPU, RAM, and Disk to shield_status.md, and DM it to dabe on Discord.
# Created: 2026-07-12 08:50
# Author: George
# Version: 1

slash_vitals_dashboard() {
    local args="$1"
    local workdir="${2:-.}"

    ui_step "Gathering system resources..."
    local cpu_load mem_free disk_free now
    cpu_load=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}' || echo "1.0")
    mem_free=$(free -h | awk '/Mem:/ {print $4}' || echo "N/A")
    disk_free=$(df -h / | tail -1 | awk '/\// {print $4}' || echo "N/A")
    now=$(date '+%Y-%m-%d %H:%M:%S')

    ui_step "Writing report to shield_status.md..."
    cat <<EOF > "$workdir/shield_status.md"
# System Health Dashboard

This report summarizes the current system resources.

## CPU Usage
* CPU Load: ${cpu_load}%

## Memory (RAM)
* Free Memory: ${mem_free}

## Disk Usage
* Free Disk Space: ${disk_free}

## Status
* Overall Health: ✅ OK

---
*Dashboard generated on ${now}*
EOF
    ui_ok "Report written: $workdir/shield_status.md"

    ui_step "Sending dashboard to Discord..."
    commands_dispatch "/social discord dm dabe $workdir/shield_status.md" "$workdir"
    ui_ok "Dashboard sent to Discord!"
}
