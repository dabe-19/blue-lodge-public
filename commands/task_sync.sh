#!/bin/bash
# DESC: Manage task-to-task MQTT signaling, status exchange, and rebase synchronization
# Usage: /task_sync [signal|wait|status|rebase] [args]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mqtt.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/task_sync.sh" 2>/dev/null || true

cmd_task_sync() {
    local args="$1"
    local workdir="${2:-.}"

    task_sync_init

    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        ""|status)
            echo "── Sovereign Task Synchronization Bridge ──"
            if declare -f mqtt_status &>/dev/null; then
                mqtt_status
            else
                echo "MQTT library not loaded."
            fi
            ;;
        signal|pub|emit)
            local task_id event_name payload
            task_id=$(echo "$rest" | awk '{print $1}')
            event_name=$(echo "$rest" | awk '{print $2}')
            payload=$(echo "$rest" | cut -d' ' -f3-)
            [ -z "$payload" ] && payload="{}"
            if task_sync_signal "$task_id" "$event_name" "$payload"; then
                ui_ok "Signal emitted: george/tasks/${task_id}/${event_name}"
            else
                ui_err "Failed to emit signal (MQTT unavailable)"
            fi
            ;;
        wait|sub)
            local topic timeout
            topic=$(echo "$rest" | awk '{print $1}')
            timeout=$(echo "$rest" | awk '{print $2}')
            [ -z "$timeout" ] && timeout=10
            local received
            received=$(task_sync_wait "$topic" "$timeout")
            if [ -n "$received" ]; then
                echo "$received"
            else
                ui_warn "Wait timed out after ${timeout}s on topic: $topic"
                return 1
            fi
            ;;
        rebase|sync)
            local target_wt="${rest:-$workdir}"
            task_sync_rebase_develop "$target_wt"
            ;;
        *)
            echo "Usage: /task_sync [status|signal <task_id> <event> <json>|wait <topic> [timeout]|rebase [dir]]"
            ;;
    esac
}
