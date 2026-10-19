#!/bin/bash
# DESC: Multi-node MQTT Swarm & FIFO-Backed Remote Worker Delegation (/swarm status|delegate|enroll)
# ── George: /swarm Command Suite ─────────────────────────────────────
# Manages multi-node MQTT swarm membership, topology, delegation, and policy.

source "${LODGE_DIR:-$HOME/blue-lodge}/lib/agents/swarm.sh" 2>/dev/null || true

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
            local broker node_name node_mode
            broker=$(echo "$rest" | awk '{print $1}')
            node_name=$(echo "$rest" | awk '{print $2}')
            node_mode=$(echo "$rest" | awk '{print $3}')
            swarm_join "$broker" "$node_name" "$node_mode"
            ;;
        enroll)
            local target jump node_name mode tier
            target=$(echo "$rest" | awk '{print $1}')
            jump=$(echo "$rest" | awk '{print $2}')
            node_name=$(echo "$rest" | awk '{print $3}')
            mode=$(echo "$rest" | awk '{print $4}')
            tier=$(echo "$rest" | awk '{print $5}')
            swarm_enroll_remote "$target" "$jump" "$node_name" "$mode" "$tier"
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
        triage)
            local target_node issue_num
            target_node=$(echo "$rest" | awk '{print $1}')
            issue_num=$(echo "$rest" | awk '{print $2}')
            if [[ "$target_node" =~ ^[0-9]+$ ]] && [ -z "$issue_num" ]; then
                issue_num="$target_node"
                target_node="${REMOTE_NODE_NAME:-george-home}"
            fi
            if [ -z "$issue_num" ]; then
                ui_err "Usage: /swarm triage [node_name] <gitea_issue_number>"
                return 1
            fi
            local gtoken=""
            for gf in "${GEORGE_DIR:-$LODGE_DIR/.george}/gitea.conf" "${GEORGE_DIR:-$LODGE_DIR/.george}/secrets.env"; do
                if [ -f "$gf" ]; then
                    gtoken=$(grep -E '^GITEA_TOKEN=' "$gf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"'")
                    [ -n "$gtoken" ] && break
                fi
            done
            swarm_delegate "$target_node" "bash -c 'source ~/blue-lodge/lib/agents/remote_sentinel.sh && remote_sentinel_triage_issue ${issue_num} ${gtoken}'"
            ;;
        sentinel)
            local sfile="${GEORGE_DIR:-$LODGE_DIR/.george}/swarm/sentinel_reports.jsonl"
            ui_header "Secondary Node Sentinel & Stage-0 Triage Reports"
            if [ -f "$sfile" ] && [ -s "$sfile" ]; then
                tail -n 10 "$sfile" | jq -r '"  [\(.params.timestamp // "now")] [\(.method)] node=\(.params.node_id // "worker") event=\(.params.event_type // ("issue #" + (.params.issue_number|tostring))) -> \((.params.diagnosis // .params.brief // "") | gsub("\n"; " ") | .[0:160])"' 2>/dev/null || tail -n 10 "$sfile"
            else
                ui_dim "  (no sentinel reports recorded yet)"
            fi
            ;;
        leave|disconnect|stop)
            swarm_leave
            ;;
        ""|help)
            ui_info "Blue Lodge Multi-Node MQTT Swarm"
            ui_dim "  /swarm host [broker:port]          — Start master node listener"
            ui_dim "  /swarm enroll <user@host> [jump] [name] [mode] — Enroll remote SSH node (inference|worker|hybrid)"
            ui_dim "  /swarm join <broker:port> [name]   — Join cluster as a worker node"
            ui_dim "  /swarm status                      — Show connected nodes, GPU vitals, FIFO credits & queue"
            ui_dim "  /swarm delegate <node> <command>   — Delegate task/test execution via FIFO-MQTT bridge"
            ui_dim "  /swarm triage [node] <issue_num>   — Dispatch Stage-0 Gitea Issue Triage to secondary GPU node"
            ui_dim "  /swarm sentinel                    — View recent remote Sentinel & Stage-0 Triage reports"
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

cmd_swarm() {
    _cmd_swarm "$@"
}

cmd_swarm_delegate() {
    local args="$1"
    _cmd_swarm "delegate $args"
}

if declare -f commands_register &>/dev/null; then
    commands_register "swarm" "Multi-node MQTT Swarm & FIFO Worker Delegation (/swarm status|delegate|enroll)" "cmd_swarm"
    commands_register "swarm_delegate" "Delegate a command or task to a remote worker node via 1-slot FIFO-MQTT bridge" "cmd_swarm_delegate"
fi

