#!/bin/bash
# DESC: Sovereign Telemetry & Anomaly Ring Inspector
# Usage: /telemetry [active|incidents|dump <task_id>|help]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/telemetry.sh" 2>/dev/null || true

cmd_telemetry() {
    local args="$1"
    local workdir="${2:-.}"

    telemetry_init

    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        ""|active|ls|status)
            telemetry_active_list
            ;;
        incidents|inc)
            telemetry_incidents_list
            ;;
        dump|events|log)
            if [ -z "$rest" ]; then
                ui_err "Task ID required: /telemetry dump <task_id>"
                return 1
            fi
            local ev_file="${TELEMETRY_ACTIVE_DIR}/${rest}.events.jsonl"
            if [ ! -f "$ev_file" ]; then
                # Check archives
                ev_file=$(find "$TELEMETRY_ARCHIVE_DIR" -name "${rest}.events.jsonl" 2>/dev/null | head -n 1)
            fi
            if [ -z "$ev_file" ] || [ ! -f "$ev_file" ]; then
                ui_err "No telemetry events found for task: $rest"
                return 1
            fi
            ui_section "Telemetry Event Stream: $rest"
            cat "$ev_file" | jq -c '.' 2>/dev/null || cat "$ev_file"
            ;;
        help|-h|--help)
            ui_section "George Sovereign Telemetry Ring"
            echo "Usage: /telemetry <command> [args]"
            echo ""
            echo "Commands:"
            echo "  active             List currently active registered tasks in the telemetry ring"
            echo "  incidents          List preserved diagnostic incident dossiers (.george/telemetry/incidents/)"
            echo "  dump <task_id>     Stream event log for a specific task"
            echo "  help               Show this help menu"
            return 0
            ;;
        *)
            ui_err "Unknown telemetry command: $subcmd (try /telemetry help)"
            return 1
            ;;
    esac
}
