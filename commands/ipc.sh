#!/bin/bash
# DESC: Manage Sovereign IPC channels, flow control credit windows, and async tasks
# Usage: /ipc [channel | flow | write | read | async | await | status | config]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/fifo_ipc.sh" 2>/dev/null || true

cmd_ipc() {
    local args="$1"
    local workdir="${2:-.}"

    if [ -z "$args" ] || [ "$args" = "help" ] || [ "$args" = "--help" ] || [ "$args" = "-h" ]; then
        echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
        echo -e "${BOLD}  Blue Lodge — Sovereign IPC & Flow Control Engine${RESET}"
        echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
        echo "Usage: /ipc <subcommand> [options]"
        echo ""
        echo "Subcommands:"
        echo "  /ipc channels                List all active IPC channels and their credit windows"
        echo "  /ipc status <channel_id>     Show state, sequence numbers, and metrics for channel"
        echo "  /ipc send <id> [type] [body] Send OKF-framed NDJSON message with atomic pipe guarantees"
        echo "  /ipc recv <id> [timeout]     Receive framed message with correlation filtering"
        echo "  /ipc pause <channel_id>      Assert backpressure pause on channel producer"
        echo "  /ipc resume <channel_id>     Release backpressure and resume channel producer"
        echo "  /ipc grant <channel_id> [N]  Grant N transmission credits to channel"
        echo "  /ipc cancel <promise_id>     Cancel running async task and reap process tree"
        echo "  /ipc unstick <channel_id>    Emergency reset backpressure and restore window credits"
        echo "  /ipc flush <channel_id>      Drain unread frames from data pipe and reset credits"
        echo "  /ipc gc [--force|--dry-run]  Sweep stale channels, dead keepers, and wedged queues"
        echo "  /ipc log [lines]             View recent structured IPC log messages"
        echo "  /ipc config                  Display configured IPC tunables and buffer thresholds"
        return 0
    fi

    local action="${args%% *}"
    local subargs="${args#* }"
    [ "$action" = "$args" ] && subargs=""

    case "$action" in
        channels|list|ls)
            ui_section "Active IPC Channels"
            ipc_channel_list
            ;;
        status|inspect)
            if [ -z "$subargs" ]; then
                ui_err "Usage: /ipc status <channel_id>"
                return 1
            fi
            "$LODGE_DIR/bin/george-ipc" channel status "$subargs"
            ;;
        pause)
            if [ -z "$subargs" ]; then
                ui_err "Usage: /ipc pause <channel_id>"
                return 1
            fi
            ipc_flow_pause "$subargs"
            ui_ok "Channel '$subargs' paused (backpressure asserted)"
            ;;
        resume)
            if [ -z "$subargs" ]; then
                ui_err "Usage: /ipc resume <channel_id>"
                return 1
            fi
            ipc_flow_resume "$subargs"
            ui_ok "Channel '$subargs' resumed (backpressure cleared)"
            ;;
        grant)
            local cid amt
            cid=$(echo "$subargs" | awk '{print $1}')
            amt=$(echo "$subargs" | awk '{print $2}')
            if [ -z "$cid" ]; then
                ui_err "Usage: /ipc grant <channel_id> [amount]"
                return 1
            fi
            ipc_flow_grant "$cid" "${amt:-1}"
            ui_ok "Granted ${amt:-1} credits to channel '$cid'"
            ;;
        unstick)
            if [ -z "$subargs" ]; then
                ui_err "Usage: /ipc unstick <channel_id>"
                return 1
            fi
            ipc_flow_unstick "$subargs"
            ui_ok "Channel '$subargs' unstuck and reset"
            ;;
        flush)
            if [ -z "$subargs" ]; then
                ui_err "Usage: /ipc flush <channel_id>"
                return 1
            fi
            ipc_channel_flush "$subargs"
            ui_ok "Channel '$subargs' drained and credits reset"
            ;;
        gc|reap|sweep)
            ui_section "IPC Protocol Garbage Collector"
            local res
            res=$(ipc_gc $subargs)
            echo "$res" | jq . 2>/dev/null || echo "$res"
            ;;
        config)
            ui_section "IPC Configuration"
            "$LODGE_DIR/bin/george-ipc" config
            ;;
        *)
            "$LODGE_DIR/bin/george-ipc" "$action" $subargs
            ;;
    esac
}

[ "${BASH_SOURCE[0]}" = "$0" ] && cmd_ipc "$@"
