#!/bin/bash
# ── George Slash Command: /node ──────────────────────────────────────
# DESC: Manage node identity, callsign, topology mode (independent|federated|swarm), and Discord swarm posture
# USAGE: /node [status | callsign <name> | mode <independent|federated|swarm> | posture <direct-on-mention|strict-subordinate> | master <bot_id> | peer <add|rm|clear> [bot_id]]

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
declare -f ui_ok &>/dev/null || ui_ok() { echo "[✓] $*"; }
declare -f ui_err &>/dev/null || ui_err() { echo "[✗] $*" >&2; }

_node_conf_file() {
    local dir="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}/configs"
    mkdir -p "$dir" 2>/dev/null || true
    echo "$dir/lodge.conf"
}

_node_set_kv() {
    local key="$1" val="$2"
    local cfg
    cfg="$(_node_conf_file)"
    touch "$cfg"
    if grep -qE "^[[:space:]]*${key}=" "$cfg" 2>/dev/null; then
        sed -i "s|^[[:space:]]*${key}=.*|${key}=${val}|" "$cfg"
    else
        echo "${key}=${val}" >> "$cfg"
    fi
    printf -v "$key" '%s' "$val"
    export "${key}=${val}"
}

cmd_node() {
    local args="${*:-status}"
    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    source "$LODGE_DIR/lib/comms/discord_bridge.sh" 2>/dev/null || true
    declare -f _discord_load_node_identity &>/dev/null && _discord_load_node_identity

    case "$subcmd" in
        status|"")
            echo "═══ Sovereign Node Identity & Swarm Posture ═══"
            echo "  Node Name:             ${LODGE_NODE_NAME:-george}"
            echo "  Discord Callsign:      @${LODGE_NODE_CALLSIGN:-george}"
            echo "  Topology Mode:         ${LODGE_NODE_MODE:-independent}  (independent | federated | swarm)"
            echo "  Swarm Channel Posture: ${DISCORD_SWARM_POSTURE:-direct-on-mention}  (direct-on-mention | strict-subordinate)"
            echo "  Master Bot ID:         ${DISCORD_MASTER_BOT_ID:-<unset>}"
            echo "  Trusted Peer Bot IDs:  ${DISCORD_PEER_BOT_IDS:-<none>}"
            echo "  Max Bot-to-Bot Hops:   ${DISCORD_MAX_BOT_HOPS:-5}"
            ;;
        callsign|name)
            local clean
            clean=$(echo "$rest" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
            if [ -z "$clean" ]; then
                ui_err "Usage: /node callsign <name> (e.g., hiram, george, blackwell)"
                return 1
            fi
            _node_set_kv "LODGE_NODE_NAME" "$clean"
            _node_set_kv "LODGE_NODE_CALLSIGN" "$clean"
            ui_ok "Node callsign updated to @${clean}"
            ;;
        mode)
            case "$rest" in
                independent|federated|swarm)
                    _node_set_kv "LODGE_NODE_MODE" "$rest"
                    ui_ok "Node topology mode set to '${rest}'"
                    ;;
                *)
                    ui_err "Usage: /node mode <independent|federated|swarm>"
                    return 1
                    ;;
            esac
            ;;
        posture)
            case "$rest" in
                direct-on-mention|strict-subordinate)
                    _node_set_kv "DISCORD_SWARM_POSTURE" "$rest"
                    ui_ok "Discord swarm posture set to '${rest}'"
                    ;;
                *)
                    ui_err "Usage: /node posture <direct-on-mention|strict-subordinate>"
                    return 1
                    ;;
            esac
            ;;
        master)
            local bid
            bid=$(echo "$rest" | tr -cd '0-9')
            _node_set_kv "DISCORD_MASTER_BOT_ID" "$bid"
            ui_ok "Master Discord Bot ID set to '${bid:-<cleared>}'"
            ;;
        peer)
            local p_act="${rest%% *}"
            local p_id="${rest#"$p_act"}"
            p_id=$(echo "$p_id" | tr -cd '0-9')
            case "$p_act" in
                add)
                    [ -z "$p_id" ] && { ui_err "Usage: /node peer add <discord_bot_id>"; return 1; }
                    local cur="${DISCORD_PEER_BOT_IDS:-}"
                    if [[ ",$cur," != *",$p_id,"* ]]; then
                        cur="${cur:+$cur,}$p_id"
                    fi
                    _node_set_kv "DISCORD_PEER_BOT_IDS" "$cur"
                    ui_ok "Added peer Discord Bot ID $p_id (peers: $cur)"
                    ;;
                rm|remove)
                    [ -z "$p_id" ] && { ui_err "Usage: /node peer rm <discord_bot_id>"; return 1; }
                    local next
                    next=$(echo "${DISCORD_PEER_BOT_IDS:-}" | tr ',' '\n' | grep -vx "$p_id" | paste -sd, -)
                    _node_set_kv "DISCORD_PEER_BOT_IDS" "$next"
                    ui_ok "Removed peer Discord Bot ID $p_id (peers: ${next:-<none>})"
                    ;;
                clear)
                    _node_set_kv "DISCORD_PEER_BOT_IDS" ""
                    ui_ok "Cleared all peer Discord Bot IDs"
                    ;;
                *)
                    ui_err "Usage: /node peer <add|rm|clear> [discord_bot_id]"
                    return 1
                    ;;
            esac
            ;;
        help|--help|-h)
            cat <<EOF
/node — Multi-Node Identity, Discord Callsign & Swarm Topology Manager

Usage:
  /node status                                      Show current node identity & swarm posture
  /node callsign <name>                             Set node name & Discord @callsign (default: hiram)
  /node mode <independent|federated|swarm>          Switch topology mode
  /node posture <direct-on-mention|strict-subordinate>
                                                    In 'swarm' mode:
                                                      direct-on-mention: subordinate for general channel chatter,
                                                        but answers direct <@bot_id> / @callsign mentions & DMs
                                                      strict-subordinate: in public channels, only accepts tasks
                                                        from DISCORD_MASTER_BOT_ID (owner DMs remain open)
  /node master <discord_bot_id>                     Set the Master node's Discord Bot ID
  /node peer <add|rm|clear> [discord_bot_id]        Manage allowlisted peer Discord Bot IDs for bot-to-bot turns
EOF
            ;;
        *)
            ui_err "Unknown /node subcommand: $subcmd (try /node help)"
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_node "$*"
fi
