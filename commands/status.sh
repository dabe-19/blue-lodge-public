#!/bin/bash
# DESC: Display live George engine vitals, compute topology, and active tasks
# Usage: /status

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/core/endpoints.sh" 2>/dev/null || true

cmd_status() {
    ui_section "Status"
    printf "  %bModel:%b      %s\n" "${C_CYAN:-}" "${C_RESET:-}" "${LODGE_MODEL:-default}"
    if declare -f endpoints_cascade &>/dev/null; then
        endpoints_cascade >/dev/null 2>&1 || true
        if [ -n "${ACTIVE_TIER:-}" ]; then
            printf "  %bInference:%b  Tier %s [%s] (%s @ %s)\n" "${C_CYAN:-}" "${C_RESET:-}" "$ACTIVE_TIER" "$ACTIVE_ENDPOINT_NAME" "$ACTIVE_ENDPOINT_MODEL" "$ACTIVE_ENDPOINT_URL"
            printf "  %bContext:%b    %s tokens\n" "${C_CYAN:-}" "${C_RESET:-}" "$ACTIVE_ENDPOINT_CONTEXT"
        fi
    else
        endpoints_init 2>/dev/null || true
        local inf_url="${TIER1_URL:-http://127.0.0.1:8080}"
        local inf_model="${TIER1_MODEL:-ternary-bonsai-27b}"
        printf "  %bInference:%b  Tier 1 [Master] (%s @ %s)\n" "${C_CYAN:-}" "${C_RESET:-}" "$inf_model" "$inf_url"
        printf "  %bContext:%b    %s tokens\n" "${C_CYAN:-}" "${C_RESET:-}" "${TIER1_CONTEXT:-24576}"
    fi
    printf "  %bProject:%b    %s\n" "${C_CYAN:-}" "${C_RESET:-}" "${LODGE_PROJECT:-none}"
    printf "  %bWorkdir:%b    %s\n" "${C_CYAN:-}" "${C_RESET:-}" "$PWD"
    if [ -n "${LODGE_PERMISSION:-}" ]; then
        printf "  %bPermission:%b %s\n" "${C_CYAN:-}" "${C_RESET:-}" "$([ "$LODGE_PERMISSION" -eq 0 ] && echo 'ask-all' || ([ "$LODGE_PERMISSION" -eq 1 ] && echo 'ask-destructive' || echo 'auto'))"
    fi
    local mem_exists="no"
    [ -f "./GEORGE.md" ] && mem_exists="yes"
    printf "  %bGEORGE.md:%b  %s\n" "${C_CYAN:-}" "${C_RESET:-}" "$mem_exists"
    if declare -f journal_count &>/dev/null; then
        local j_count
        j_count=$(journal_count)
        printf "  %bJournal:%b    %s entries\n" "${C_CYAN:-}" "${C_RESET:-}" "$j_count"
    fi

    # GPU Hardware
    if command -v nvidia-smi &>/dev/null; then
        local gpu_info
        gpu_info=$(nvidia-smi --query-gpu=name,temperature.gpu,power.draw,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -n 1)
        if [ -n "$gpu_info" ]; then
            IFS=',' read -r gname gtemp gpow gused gtot <<< "$gpu_info"
            printf "  %bGPU 0:%b      %s [%s°C, %sW, %s/%s MB VRAM]\n" "${C_CYAN:-}" "${C_RESET:-}" "$(echo "$gname" | xargs)" "${gtemp// /}" "$(echo "$gpow" | xargs)" "$(echo "$gused" | xargs)" "$(echo "$gtot" | xargs)"
        fi
    fi

    # Web UI Daemon
    local web_pid
    web_pid=$(pgrep -f "george-web" 2>/dev/null | head -n 1)
    if [ -n "$web_pid" ]; then
        printf "  %bWeb UI:%b     Online (PID %s @ http://127.0.0.1:3000)\n" "${C_CYAN:-}" "${C_RESET:-}" "$web_pid"
    else
        printf "  %bWeb UI:%b     Offline\n" "${C_CYAN:-}" "${C_RESET:-}"
    fi

    # Active Tasks
    local active_count=0
    if [ -d "$LODGE_DIR/.sandboxes" ]; then
        active_count=$(find "$LODGE_DIR/.sandboxes" -maxdepth 1 -type d ! -name ".*" ! -exec test -e "{}/.done" ';' -print 2>/dev/null | wc -l)
    fi
    printf "  %bLive Tasks:%b %s active\n" "${C_CYAN:-}" "${C_RESET:-}" "$active_count"

    # Battery if available
    if declare -f tools_phone_battery &>/dev/null; then
        local batt
        batt=$(tools_phone_battery 2>/dev/null)
        if [ -n "$batt" ] && [ "$batt" != '{"percentage": "unknown"}' ]; then
            local pct
            pct=$(echo "$batt" | jq -r '.percentage' 2>/dev/null)
            printf "  %bBattery:%b    %s%%\n" "${C_CYAN:-}" "${C_RESET:-}" "$pct"
        fi
    fi
    echo ""
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_status "$@"
fi
