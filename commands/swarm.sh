#!/bin/bash
# ── George: /swarm Command Suite ─────────────────────────────────────
# Manages multi-node MQTT swarm membership, topology, delegation, and policy.

source "${LODGE_DIR:-$HOME/blue-lodge}/lib/swarm.sh" 2>/dev/null || true

_cmd_swarm() {
    local args="$1"
    local subcmd
    subcmd=$(echo "$args" | awk '{print $1}')
    local rest
    rest=$(echo "$args" | sed 's/^[^ ]* *//')
    [ "$rest" = "$subcmd" ] && rest=""

    case "$subcmd" in
        host|master)
            swarm_host "$rest"
            ;;
        join|worker)
            local broker node_name
            broker=$(echo "$rest" | awk '{print $1}')
            node_name=$(echo "$rest" | awk '{print $2}')
            swarm_join "$broker" "$node_name"
            ;;
        status|list|info)
            swarm_status
            ;;
        delegate|run)
            local target_node cmd
            target_node=$(echo "$rest" | awk '{print $1}')
            cmd=$(echo "$rest" | sed 's/^[^ ]* *//')
            [ "$cmd" = "$target_node" ] && cmd=""
            if [ -z "$target_node" ] || [ -z "$cmd" ]; then
                ui_err "Usage: /swarm delegate <node_name> <command>"
                return 1
            fi
            swarm_delegate "$target_node" "$cmd"
            ;;
        policy)
            swarm_policy "$rest"
            ;;
        approve)
            swarm_approve "$rest"
            ;;
        reject)
            swarm_reject "$rest"
            ;;
        leave|disconnect|stop)
            swarm_leave
            ;;
        ""|help)
            ui_info "Blue Lodge Multi-Node MQTT Swarm"
            ui_dim "  /swarm host [broker:port]          — Start master node listener"
            ui_dim "  /swarm join <broker:port> [name]   — Join cluster as a worker node"
            ui_dim "  /swarm status                      — Show connected nodes, GPU vitals & queue"
            ui_dim "  /swarm delegate <node> <command>   — Delegate task/test execution to a worker"
            ui_dim "  /swarm policy [auto|manual]        — Toggle autonomous Slot 1 execution vs gate"
            ui_dim "  /swarm approve <req_id>            — Approve a queued worker command"
            ui_dim "  /swarm reject <req_id>             — Reject a queued worker command"
            ui_dim "  /swarm leave                       — Disconnect node from swarm"
            ui_dim ""
            ui_dim "Remote command proxy shortcut:"
            ui_dim "  /remote-master <cmd>               — Run command directly on Master node"
            ;;
    esac
}
