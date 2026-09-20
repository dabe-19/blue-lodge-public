#!/bin/bash
# ── George: Pinned ANSI Terminal Dashboard (2026) ─────────────────────
# Visualizes concurrent subagents and parallel workers in pinned bottom terminal lanes.
# Preserves main scrollback buffer for clean primary thought streaming.

[ -n "${_LIB_UI_DASHBOARD_LOADED:-}" ] && return 0; _LIB_UI_DASHBOARD_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

declare -A _DASH_WORKERS 2>/dev/null || true
_DASH_WORKER_IDS=()
_DASH_ENABLED=1

ui_dashboard_init() {
    _DASH_WORKER_IDS=()
    # Check if stdout is interactive terminal
    if [ ! -t 1 ]; then
        _DASH_ENABLED=0
    fi
}

ui_dashboard_worker_start() {
    local id="$1"
    local tier="$2"
    local model="$3"
    local task="$4"
    local start_time
    start_time=$(date +%s)

    _DASH_WORKERS["$id"]="$tier|$model|$task|$start_time|active"
    _DASH_WORKER_IDS+=("$id")
    ui_dashboard_render
}

ui_dashboard_worker_update() {
    local id="$1"
    local status="$2"
    local entry="${_DASH_WORKERS[$id]:-}"
    [ -z "$entry" ] && return 0

    local tier model task start_time old_status
    IFS='|' read -r tier model task start_time old_status <<< "$entry"
    _DASH_WORKERS["$id"]="$tier|$model|$task|$start_time|$status"
    ui_dashboard_render
}

ui_dashboard_worker_finish() {
    local id="$1"
    local exit_code="${2:-0}"
    local entry="${_DASH_WORKERS[$id]:-}"
    [ -z "$entry" ] && return 0

    local tier model task start_time status
    IFS='|' read -r tier model task start_time status <<< "$entry"

    local final_status="done"
    [ "$exit_code" -ne 0 ] && final_status="error"

    _DASH_WORKERS["$id"]="$tier|$model|$task|$start_time|$final_status"
    ui_dashboard_render

    # Clean up from active tracking after brief delay
    local new_ids=()
    for item in "${_DASH_WORKER_IDS[@]}"; do
        [ "$item" != "$id" ] && new_ids+=("$item")
    done
    _DASH_WORKER_IDS=("${new_ids[@]}")
    unset "_DASH_WORKERS[$id]"
}

ui_dashboard_render() {
    [ "${_DASH_ENABLED:-0}" -ne 1 ] && return 0
    [ ${#_DASH_WORKER_IDS[@]} -eq 0 ] && return 0

    local lines cols
    lines=$(tput lines 2>/dev/null || echo 24)
    cols=$(tput cols 2>/dev/null || echo 80)

    # Number of lanes to draw
    local count=${#_DASH_WORKER_IDS[@]}
    local box_height=$((count + 2))
    local start_row=$((lines - box_height + 1))

    # Save cursor position
    printf "\033[s"

    # Move to start row
    printf "\033[%d;1H" "$start_row"

    # Draw header
    printf "${C_LODGE}┌─ Active Workers [%d] %s┐${C_RESET}\n" "$count" "$(printf '─%.0s' $(seq 1 $((cols - 25))))"

    local now
    now=$(date +%s)

    for id in "${_DASH_WORKER_IDS[@]}"; do
        local entry="${_DASH_WORKERS[$id]:-}"
        [ -z "$entry" ] && continue

        local tier model task start_time status
        IFS='|' read -r tier model task start_time status <<< "$entry"
        local elapsed=$((now - start_time))

        local status_sym="●"
        local status_color="$C_GREEN"
        [ "$status" = "active" ] && status_sym="⚙" && status_color="$C_CYAN"
        [ "$status" = "error" ] && status_sym="✗" && status_color="$C_RED"

        local task_trim="${task:0:$((cols - 35))}"
        printf "${C_LODGE}│${C_RESET} ${status_color}%s${C_RESET} [Tier %s: %s] %s (${elapsed}s)\033[K\n" "$status_sym" "$tier" "$model" "$task_trim"
    done

    # Draw footer
    printf "${C_LODGE}└%s┘${C_RESET}" "$(printf '─%.0s' $(seq 1 $((cols - 2))))"

    # Restore cursor
    printf "\033[u"
}
