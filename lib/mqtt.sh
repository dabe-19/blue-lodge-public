#!/bin/bash
# ── George: MQTT Integration ──────────────────────────────────
# Pub/sub messaging via MQTT protocol using mosquitto-clients.
# Pure C binaries — no Python, no Node.js, no Java.
#
# Dependency: mosquitto-clients (mosquitto_pub + mosquitto_sub)
#   Debian/Ubuntu:  sudo apt install mosquitto-clients
#   Alpine/iSH:     apk add mosquitto-clients
#   Termux:         pkg install mosquitto
#   macOS:          brew install mosquitto
#
# mosquitto-clients is ~200KB compiled C. It handles all MQTT
# binary protocol framing (CONNECT, CONNACK, PUBLISH, SUBSCRIBE,
# PINGREQ/PINGRESP, DISCONNECT) internally. George just passes
# topic/message/flags — no raw byte manipulation needed.
#
# Supports MQTT v3.1.1 and v5.0, plain TCP (1883) and TLS (8883).
#
# Usage:
#   /mqtt setup broker.emqx.io:1883   — configure broker
#   /mqtt pub sensors/temp "22.5"      — publish message
#   /mqtt sub sensors/temp             — subscribe (one-shot)
#   /mqtt status                       — test connectivity
#   /mqtt topics                       — list tracked topics
#   /mqtt history [topic] [count]      — show message history

[ -n "${_LIB_MQTT_LOADED:-}" ] && return 0; _LIB_MQTT_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Config ─────────────────────────────────────────────────────
GEORGE_CONFIG_DIR="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}"
MQTT_CONFIG="${MQTT_CONFIG:-$GEORGE_CONFIG_DIR/mqtt.conf}"
MQTT_DB="${MQTT_DB:-$GEORGE_CONFIG_DIR/mqtt.db}"

# ── Defaults ───────────────────────────────────────────────────
MQTT_BROKER="${MQTT_BROKER:-}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_CLIENT_ID="${MQTT_CLIENT_ID:-}"
MQTT_PROTOCOL="${MQTT_PROTOCOL:-5}"
MQTT_KEEPALIVE="${MQTT_KEEPALIVE:-60}"
MQTT_TLS="${MQTT_TLS:-0}"
MQTT_CAFILE="${MQTT_CAFILE:-}"
MQTT_CERTFILE="${MQTT_CERTFILE:-}"
MQTT_KEYFILE="${MQTT_KEYFILE:-}"

# ── Init ───────────────────────────────────────────────────────
mqtt_init() {
    mkdir -p "$(dirname "$MQTT_CONFIG")" 2>/dev/null

    # Load saved config
    if [ -f "$MQTT_CONFIG" ]; then
        while IFS='=' read -r _key _val; do
            [[ "$_key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$_key" ]] && continue
            _key=$(echo "$_key" | tr -d '[:space:]')
            _val=$(echo "$_val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            # Only set if not already defined in environment
            if [ -z "${!_key+x}" ] || [ -z "${!_key}" ]; then
                printf -v "$_key" '%s' "$_val"
            fi
        done < "$MQTT_CONFIG"
    fi

    # Auto-generate client ID if not set
    if [ -z "$MQTT_CLIENT_ID" ]; then
        MQTT_CLIENT_ID="george-$$"
    fi

    # Initialize SQLite DB for topic tracking + message history
    _mqtt_db_init

    return 0
}

# ── Dependency check ───────────────────────────────────────────
mqtt_available() {
    command -v mosquitto_pub &>/dev/null && command -v mosquitto_sub &>/dev/null
}

_mqtt_require_tools() {
    if ! mqtt_available; then
        declare -f ui_err &>/dev/null && ui_err "mosquitto-clients not installed"
        declare -f ui_dim &>/dev/null && ui_dim "Install: sudo apt install mosquitto-clients"
        return 1
    fi
}

_mqtt_require_config() {
    _mqtt_require_tools || return 1
    if [ -z "$MQTT_BROKER" ]; then
        declare -f ui_err &>/dev/null && ui_err "MQTT broker not configured"
        declare -f ui_dim &>/dev/null && ui_dim "Run: /mqtt setup <broker:port>"
        return 1
    fi
}

# ── Build common mosquitto args ────────────────────────────────
_mqtt_build_args() {
    _MQTT_ARGS=()
    _MQTT_ARGS+=(-h "$MQTT_BROKER")
    _MQTT_ARGS+=(-p "$MQTT_PORT")
    _MQTT_ARGS+=(-i "$MQTT_CLIENT_ID")
    _MQTT_ARGS+=(--keepalive "$MQTT_KEEPALIVE")

    # Protocol version
    if [ "$MQTT_PROTOCOL" = "5" ]; then
        _MQTT_ARGS+=(-V 5)
    else
        _MQTT_ARGS+=(-V 311)
    fi

    # Credentials from vault or environment
    _mqtt_cred_user=""
    _mqtt_cred_pass=""
    if declare -f secrets_get &>/dev/null; then
        _mqtt_cred_user=$(secrets_get "mqtt_username" 2>/dev/null) || true
        _mqtt_cred_pass=$(secrets_get "mqtt_password" 2>/dev/null) || true
    fi
    [ -z "$_mqtt_cred_user" ] && _mqtt_cred_user="${MQTT_USERNAME:-}"
    [ -z "$_mqtt_cred_pass" ] && _mqtt_cred_pass="${MQTT_PASSWORD:-}"

    if [ -n "$_mqtt_cred_user" ]; then
        _MQTT_ARGS+=(-u "$_mqtt_cred_user")
    fi
    if [ -n "$_mqtt_cred_pass" ]; then
        _MQTT_ARGS+=(-P "$_mqtt_cred_pass")
    fi

    # TLS
    if [ "$MQTT_TLS" = "1" ]; then
        if [ -n "$MQTT_CAFILE" ] && [ -f "$MQTT_CAFILE" ]; then
            _MQTT_ARGS+=(--cafile "$MQTT_CAFILE")
        fi
        if [ -n "$MQTT_CERTFILE" ] && [ -f "$MQTT_CERTFILE" ]; then
            _MQTT_ARGS+=(--cert "$MQTT_CERTFILE")
        fi
        if [ -n "$MQTT_KEYFILE" ] && [ -f "$MQTT_KEYFILE" ]; then
            _MQTT_ARGS+=(--key "$MQTT_KEYFILE")
        fi
    fi

    printf '%s\n' "${_MQTT_ARGS[@]}"
}

# ── Publish ────────────────────────────────────────────────────
mqtt_publish() {
    # MCP-first: route through george-mqtt mqtt_publish tool
    if declare -f mcp_enabled &>/dev/null && mcp_enabled; then
        # Pre-parse topic and message for the MCP fast path
        local _mcp_topic="" _mcp_msg="" _mcp_qos=0 _mcp_retain="false"
        local _mcp_args=("$@")
        local _mcp_i=0
        while [ $_mcp_i -lt ${#_mcp_args[@]} ]; do
            case "${_mcp_args[$_mcp_i]}" in
                --qos)   _mcp_i=$((_mcp_i+1)); _mcp_qos="${_mcp_args[$_mcp_i]:-0}" ;;
                --retain) _mcp_retain="true" ;;
                *)
                    if [ -z "$_mcp_topic" ]; then
                        _mcp_topic="${_mcp_args[$_mcp_i]}"
                    elif [ -z "$_mcp_msg" ]; then
                        _mcp_msg="${_mcp_args[$_mcp_i]}"
                    fi
                    ;;
            esac
            _mcp_i=$((_mcp_i+1))
        done
        if [ -n "$_mcp_topic" ] && [ -n "$_mcp_msg" ]; then
            local _mcp_result
            _mcp_result=$(mcp_mqtt_publish "$_mcp_topic" "$_mcp_msg" "$_mcp_qos" "$_mcp_retain" 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$_mcp_result" ]; then
                echo "$_mcp_result"
                return 0
            fi
        fi
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
            ui_dim "  [debug] mqtt_publish: MCP failed — falling through to direct"
    fi

    _mqtt_require_config || return 1

    _mp_topic=""
    _mp_message=""
    _mp_qos=0
    _mp_retain=0

    # Parse args
    while [ $# -gt 0 ]; do
        case "$1" in
            --qos)   shift; _mp_qos="${1:-0}" ;;
            --retain) _mp_retain=1 ;;
            *)
                if [ -z "$_mp_topic" ]; then
                    _mp_topic="$1"
                elif [ -z "$_mp_message" ]; then
                    _mp_message="$1"
                fi
                ;;
        esac
        shift
    done

    if [ -z "$_mp_topic" ] || [ -z "$_mp_message" ]; then
        declare -f ui_err &>/dev/null && ui_err "Usage: mqtt_publish <topic> <message> [--qos N] [--retain]"
        return 1
    fi

    _mqtt_build_args
    _mp_cmd_args=("${_MQTT_ARGS[@]}")
    _mp_cmd_args+=(-t "$_mp_topic")
    _mp_cmd_args+=(-m "$_mp_message")
    _mp_cmd_args+=(-q "$_mp_qos")
    [ "$_mp_retain" -eq 1 ] && _mp_cmd_args+=(-r)

    mosquitto_pub "${_mp_cmd_args[@]}" 2>&1
    _mp_rc=$?

    if [ $_mp_rc -eq 0 ]; then
        _mqtt_track_topic "$_mp_topic" "publish"
        _mqtt_log_message "$_mp_topic" "out" "$_mp_message"
    fi

    return $_mp_rc
}

# ── Subscribe ──────────────────────────────────────────────────
mqtt_subscribe() {
    # MCP-first: route through george-mqtt mqtt_subscribe tool
    if declare -f mcp_enabled &>/dev/null && mcp_enabled; then
        local _mcp_topic="" _mcp_count=1 _mcp_timeout=10
        local _mcp_args=("$@")
        local _mcp_i=0
        while [ $_mcp_i -lt ${#_mcp_args[@]} ]; do
            case "${_mcp_args[$_mcp_i]}" in
                --count)   _mcp_i=$((_mcp_i+1)); _mcp_count="${_mcp_args[$_mcp_i]:-1}" ;;
                --timeout) _mcp_i=$((_mcp_i+1)); _mcp_timeout="${_mcp_args[$_mcp_i]:-10}" ;;
                *)
                    [ -z "$_mcp_topic" ] && _mcp_topic="${_mcp_args[$_mcp_i]}"
                    ;;
            esac
            _mcp_i=$((_mcp_i+1))
        done
        if [ -n "$_mcp_topic" ]; then
            local _mcp_result
            _mcp_result=$(mcp_mqtt_subscribe "$_mcp_topic" "$_mcp_count" "$_mcp_timeout" 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$_mcp_result" ]; then
                printf '%s' "$_mcp_result"
                return 0
            fi
        fi
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
            ui_dim "  [debug] mqtt_subscribe: MCP failed — falling through to direct"
    fi

    _mqtt_require_config || return 1

    _ms_topic=""
    _ms_count=1
    _ms_timeout=10

    # Parse args
    while [ $# -gt 0 ]; do
        case "$1" in
            --count)   shift; _ms_count="${1:-1}" ;;
            --timeout) shift; _ms_timeout="${1:-10}" ;;
            *)
                if [ -z "$_ms_topic" ]; then
                    _ms_topic="$1"
                fi
                ;;
        esac
        shift
    done

    if [ -z "$_ms_topic" ]; then
        declare -f ui_err &>/dev/null && ui_err "Usage: mqtt_subscribe <topic> [--count N] [--timeout N]"
        return 1
    fi

    _mqtt_build_args
    _ms_cmd_args=("${_MQTT_ARGS[@]}")
    _ms_cmd_args+=(-t "$_ms_topic")
    _ms_cmd_args+=(-C "$_ms_count")
    _ms_cmd_args+=(-W "$_ms_timeout")

    _ms_output=$(mosquitto_sub "${_ms_cmd_args[@]}" 2>&1)
    _ms_rc=$?

    if [ $_ms_rc -eq 0 ] && [ -n "$_ms_output" ]; then
        _mqtt_track_topic "$_ms_topic" "subscribe"
        # Log each received message
        while IFS= read -r _ms_line; do
            [ -n "$_ms_line" ] && _mqtt_log_message "$_ms_topic" "in" "$_ms_line"
        done <<< "$_ms_output"
    fi

    printf '%s' "$_ms_output"
    return $_ms_rc
}

# ── Status (quick connectivity test) ──────────────────────────
mqtt_status() {
    # MCP-first: route through george-mqtt mqtt_status tool
    if declare -f mcp_enabled &>/dev/null && mcp_enabled; then
        local _mcp_result
        _mcp_result=$(mcp_mqtt_status 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$_mcp_result" ]; then
            echo "$_mcp_result"
            return 0
        fi
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
            ui_dim "  [debug] mqtt_status: MCP failed — falling through to direct"
    fi

    _mqtt_require_config || return 1

    _mqtt_build_args
    _mst_args=("${_MQTT_ARGS[@]}")
    # Subscribe to $SYS/broker/version with 0 messages, 3s timeout
    # This tests the full CONNECT/CONNACK handshake
    _mst_args+=(-t '$SYS/broker/version' -C 1 -W 3)

    _mst_output=$(mosquitto_sub "${_mst_args[@]}" 2>&1)
    _mst_rc=$?

    if [ $_mst_rc -eq 0 ]; then
        printf 'connected'
        [ -n "$_mst_output" ] && printf ' (%s)' "$_mst_output"
        printf '\n'
        return 0
    else
        # Timeout with no message is still a successful handshake for
        # brokers that don't publish $SYS topics. A connection refusal
        # returns a different error code.
        if [ $_mst_rc -eq 27 ]; then
            # mosquitto_sub returns 27 on timeout — means we connected but got no messages
            printf 'connected (no $SYS messages)\n'
            return 0
        fi
        printf 'connection failed: %s\n' "$_mst_output"
        return 1
    fi
}

# ── Setup (interactive or one-shot) ───────────────────────────
mqtt_setup() {
    _msu_input="${1:-}"

    if [ -n "$_msu_input" ]; then
        # One-shot: parse broker:port
        if [[ "$_msu_input" == *:* ]]; then
            MQTT_BROKER="${_msu_input%%:*}"
            MQTT_PORT="${_msu_input##*:}"
        else
            MQTT_BROKER="$_msu_input"
            MQTT_PORT=1883
        fi
    else
        # Interactive setup
        declare -f ui_section &>/dev/null && ui_section "MQTT Setup"

        printf "  Broker hostname [broker.emqx.io]: "
        read -r _msu_broker
        MQTT_BROKER="${_msu_broker:-broker.emqx.io}"

        printf "  Port [1883]: "
        read -r _msu_port
        MQTT_PORT="${_msu_port:-1883}"

        printf "  Protocol version (5 or 311) [5]: "
        read -r _msu_proto
        MQTT_PROTOCOL="${_msu_proto:-5}"

        printf "  Username (empty for anonymous): "
        read -r _msu_user
        if [ -n "$_msu_user" ]; then
            printf "  Password: "
            read -rs _msu_pass
            echo ""
            if declare -f secrets_set &>/dev/null; then
                secrets_set "mqtt_username" "$_msu_user"
                secrets_set "mqtt_password" "$_msu_pass"
            else
                MQTT_USERNAME="$_msu_user"
                MQTT_PASSWORD="$_msu_pass"
            fi
        fi

        printf "  Enable TLS? [y/N]: "
        read -r _msu_tls
        if [[ "$_msu_tls" =~ ^[Yy] ]]; then
            MQTT_TLS=1
            [ "$MQTT_PORT" = "1883" ] && MQTT_PORT=8883
            printf "  CA certificate file (empty for system default): "
            read -r _msu_ca
            [ -n "$_msu_ca" ] && MQTT_CAFILE="$_msu_ca"
        fi
    fi

    # Save config
    _mqtt_save_config

    declare -f ui_ok &>/dev/null && ui_ok "MQTT configured: $MQTT_BROKER:$MQTT_PORT"

    # Test connectivity if tools available
    if mqtt_available; then
        declare -f ui_step &>/dev/null && ui_step "Testing connection..."
        if mqtt_status >/dev/null 2>&1; then
            declare -f ui_ok &>/dev/null && ui_ok "Broker reachable"
        else
            declare -f ui_warn &>/dev/null && ui_warn "Broker not reachable — check settings"
        fi
    fi
}

_mqtt_save_config() {
    mkdir -p "$(dirname "$MQTT_CONFIG")" 2>/dev/null
    cat > "$MQTT_CONFIG" << EOF
# George MQTT Configuration
MQTT_BROKER=$MQTT_BROKER
MQTT_PORT=$MQTT_PORT
MQTT_CLIENT_ID=$MQTT_CLIENT_ID
MQTT_PROTOCOL=$MQTT_PROTOCOL
MQTT_KEEPALIVE=$MQTT_KEEPALIVE
MQTT_TLS=$MQTT_TLS
MQTT_CAFILE=$MQTT_CAFILE
MQTT_CERTFILE=$MQTT_CERTFILE
MQTT_KEYFILE=$MQTT_KEYFILE
EOF
    chmod 600 "$MQTT_CONFIG"
}

mqtt_show_config() {
    if [ ! -f "$MQTT_CONFIG" ]; then
        declare -f ui_warn &>/dev/null && ui_warn "MQTT not configured"
        declare -f ui_dim &>/dev/null && ui_dim "Run: /mqtt setup <broker:port>"
        return 1
    fi
    declare -f ui_section &>/dev/null && ui_section "MQTT Configuration"
    printf "  Broker:    %s:%s\n" "$MQTT_BROKER" "$MQTT_PORT"
    printf "  Protocol:  MQTT v%s\n" "$([ "$MQTT_PROTOCOL" = "5" ] && echo "5.0" || echo "3.1.1")"
    printf "  Client ID: %s\n" "$MQTT_CLIENT_ID"
    printf "  Keepalive: %ss\n" "$MQTT_KEEPALIVE"
    printf "  TLS:       %s\n" "$([ "$MQTT_TLS" = "1" ] && echo "enabled" || echo "disabled")"

    # Show credential status without revealing values
    _msc_user=""
    if declare -f secrets_get &>/dev/null; then
        _msc_user=$(secrets_get "mqtt_username" 2>/dev/null) || true
    fi
    [ -z "$_msc_user" ] && _msc_user="${MQTT_USERNAME:-}"
    if [ -n "$_msc_user" ]; then
        printf "  Auth:      %s / ****\n" "$_msc_user"
    else
        printf "  Auth:      anonymous\n"
    fi
}

# ── SQLite: Topic Tracking + Message History ──────────────────

_mqtt_db_init() {
    command -v sqlite3 &>/dev/null || return 0
    [ -z "$MQTT_DB" ] && return 0
    mkdir -p "$(dirname "$MQTT_DB")" 2>/dev/null
    sqlite3 "$MQTT_DB" << 'SQL'
CREATE TABLE IF NOT EXISTS topics (
    topic       TEXT NOT NULL UNIQUE,
    direction   TEXT NOT NULL DEFAULT 'both',
    first_seen  TEXT NOT NULL DEFAULT (datetime('now')),
    last_used   TEXT NOT NULL DEFAULT (datetime('now')),
    use_count   INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS messages (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    topic       TEXT NOT NULL,
    direction   TEXT NOT NULL,
    payload     TEXT NOT NULL,
    timestamp   TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_messages_topic ON messages(topic);
CREATE INDEX IF NOT EXISTS idx_messages_ts ON messages(timestamp);
SQL
}

_mqtt_track_topic() {
    command -v sqlite3 &>/dev/null || return 0
    [ -z "$MQTT_DB" ] || [ ! -f "$MQTT_DB" ] && return 0
    _mt_topic="$1"
    _mt_direction="${2:-both}"
    # Sanitize inputs for SQL
    _mt_topic_safe="${_mt_topic//\'/\'\'}"
    _mt_dir_safe="${_mt_direction//\'/\'\'}"
    sqlite3 "$MQTT_DB" \
        "INSERT INTO topics(topic, direction) VALUES ('${_mt_topic_safe}', '${_mt_dir_safe}')
         ON CONFLICT(topic) DO UPDATE SET
            last_used = datetime('now'),
            use_count = use_count + 1;"
}

_mqtt_log_message() {
    command -v sqlite3 &>/dev/null || return 0
    [ -z "$MQTT_DB" ] || [ ! -f "$MQTT_DB" ] && return 0
    _ml_topic="$1"
    _ml_direction="$2"
    _ml_payload="$3"
    # Sanitize
    _ml_topic_safe="${_ml_topic//\'/\'\'}"
    _ml_dir_safe="${_ml_direction//\'/\'\'}"
    _ml_pay_safe="${_ml_payload//\'/\'\'}"
    sqlite3 "$MQTT_DB" \
        "INSERT INTO messages(topic, direction, payload) VALUES ('${_ml_topic_safe}', '${_ml_dir_safe}', '${_ml_pay_safe}');"
    # Prune old messages (keep last 1000 per topic)
    sqlite3 "$MQTT_DB" \
        "DELETE FROM messages WHERE id NOT IN (
            SELECT id FROM messages WHERE topic = '${_ml_topic_safe}' ORDER BY id DESC LIMIT 1000
         ) AND topic = '${_ml_topic_safe}';" 2>/dev/null
}

mqtt_topics() {
    command -v sqlite3 &>/dev/null || { echo "sqlite3 required"; return 1; }
    [ -f "$MQTT_DB" ] || { echo "No topics tracked yet"; return 0; }
    sqlite3 -header -column "$MQTT_DB" \
        "SELECT topic, direction, use_count, last_used FROM topics ORDER BY last_used DESC;"
}

mqtt_history() {
    command -v sqlite3 &>/dev/null || { echo "sqlite3 required"; return 1; }
    [ -f "$MQTT_DB" ] || { echo "No messages recorded yet"; return 0; }
    _mh_topic="${1:-}"
    _mh_count="${2:-20}"

    if [ -n "$_mh_topic" ]; then
        _mh_safe="${_mh_topic//\'/\'\'}"
        sqlite3 -header -column "$MQTT_DB" \
            "SELECT timestamp, direction, payload FROM messages
             WHERE topic = '${_mh_safe}' ORDER BY id DESC LIMIT $_mh_count;"
    else
        sqlite3 -header -column "$MQTT_DB" \
            "SELECT timestamp, topic, direction, payload FROM messages
             ORDER BY id DESC LIMIT $_mh_count;"
    fi
}
