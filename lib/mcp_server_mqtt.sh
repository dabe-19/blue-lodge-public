#!/bin/bash
# ── George: Pure-Bash MCP MQTT Server ─────────────────────────
# A self-contained MCP server that speaks JSON-RPC 2.0 over stdio.
# Wraps mosquitto-clients for MQTT pub/sub — no Python, no Node.js.
#
# Tools exposed:
#   mqtt_publish   — Publish a message to an MQTT topic
#   mqtt_subscribe — Subscribe to a topic and read messages
#   mqtt_status    — Check MQTT broker connectivity
#
# Dependency: mosquitto-clients (pure C, ~200KB)
#   apt install mosquitto-clients
#
# Usage:
#   Register as MCP server:
#     /mcp add george-mqtt "bash $LODGE_DIR/lib/mcp_server_mqtt.sh"
#
#   Or run standalone:
#     echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | bash lib/mcp_server_mqtt.sh

set -uo pipefail

# ── Bootstrap George libraries ─────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="${LODGE_DIR:-$(cd "$_SCRIPT_DIR/.." && pwd)}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
GEORGE_CONFIG_DIR="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}"

# Source dependencies
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mqtt.sh"

# Initialize MQTT config (loads broker settings)
mqtt_init 2>/dev/null || true

# ── jq ────────────────────────────────────────────────────────
_JQ="jq"
command -v gojq >/dev/null 2>&1 && _JQ="gojq"

# ── JSON-RPC Response Helpers ──────────────────────────────────

_respond_result() {
    local id="$1"
    local result_json="$2"
    $_JQ -n -c \
        --argjson id "$id" \
        --argjson result "$result_json" \
        '{"jsonrpc":"2.0","id":$id,"result":$result}'
}

_respond_error() {
    local id="$1"
    local code="$2"
    local message="$3"
    if [ "$id" = "null" ]; then
        $_JQ -n -c \
            --argjson code "$code" \
            --arg message "$message" \
            '{"jsonrpc":"2.0","id":null,"error":{"code":$code,"message":$message}}'
    else
        $_JQ -n -c \
            --argjson id "$id" \
            --argjson code "$code" \
            --arg message "$message" \
            '{"jsonrpc":"2.0","id":$id,"error":{"code":$code,"message":$message}}'
    fi
}

_text_content() {
    local text="$1"
    $_JQ -n -c --arg text "$text" \
        '{"content":[{"type":"text","text":$text}]}'
}

# ── Tool Definitions ───────────────────────────────────────────

_TOOLS_JSON='[
  {
    "name": "mqtt_publish",
    "description": "Publish a message to an MQTT topic. The broker must be configured via /mqtt setup. Supports QoS 0-2 and retained messages.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "topic": {
          "type": "string",
          "description": "The MQTT topic to publish to (e.g. sensors/temperature, home/lights/kitchen)"
        },
        "message": {
          "type": "string",
          "description": "The message payload to publish"
        },
        "qos": {
          "type": "integer",
          "description": "Quality of Service level: 0 (at most once), 1 (at least once), 2 (exactly once). Default: 0"
        },
        "retain": {
          "type": "boolean",
          "description": "Whether the broker should retain this message for future subscribers. Default: false"
        }
      },
      "required": ["topic", "message"]
    }
  },
  {
    "name": "mqtt_subscribe",
    "description": "Subscribe to an MQTT topic and return received messages. Reads a fixed number of messages or times out. Use count=1 to read the last retained message on a topic.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "topic": {
          "type": "string",
          "description": "The MQTT topic to subscribe to. Supports wildcards: + (single level), # (multi level)"
        },
        "count": {
          "type": "integer",
          "description": "Number of messages to receive before returning. Default: 1"
        },
        "timeout": {
          "type": "integer",
          "description": "Maximum seconds to wait for messages. Default: 10"
        }
      },
      "required": ["topic"]
    }
  },
  {
    "name": "mqtt_status",
    "description": "Check connectivity to the configured MQTT broker. Returns connection status and broker version if available.",
    "inputSchema": {
      "type": "object",
      "properties": {},
      "required": []
    }
  }
]'

# ── Tool Dispatch ──────────────────────────────────────────────

_handle_tool_call() {
    local id="$1"
    local tool_name="$2"
    local arguments="$3"

    case "$tool_name" in
        mqtt_publish)
            local topic message qos retain
            topic=$(printf '%s' "$arguments" | $_JQ -r '.topic // empty' 2>/dev/null)
            message=$(printf '%s' "$arguments" | $_JQ -r '.message // empty' 2>/dev/null)
            qos=$(printf '%s' "$arguments" | $_JQ -r '.qos // empty' 2>/dev/null)
            retain=$(printf '%s' "$arguments" | $_JQ -r '.retain // empty' 2>/dev/null)

            if [ -z "$topic" ]; then
                _respond_result "$id" "$(_text_content "Error: topic parameter is required")"
                return
            fi
            if [ -z "$message" ]; then
                _respond_result "$id" "$(_text_content "Error: message parameter is required")"
                return
            fi

            local pub_args=("$topic" "$message")
            [ -n "$qos" ] && [ "$qos" != "null" ] && pub_args+=(--qos "$qos")
            [ "$retain" = "true" ] && pub_args+=(--retain)

            local pub_result
            pub_result=$(mqtt_publish "${pub_args[@]}" 2>&1)
            local pub_rc=$?

            if [ $pub_rc -eq 0 ]; then
                _respond_result "$id" "$(_text_content "Published to $topic: $message")"
            else
                _respond_result "$id" "$(_text_content "Error publishing to $topic: $pub_result")"
            fi
            ;;

        mqtt_subscribe)
            local topic count timeout
            topic=$(printf '%s' "$arguments" | $_JQ -r '.topic // empty' 2>/dev/null)
            count=$(printf '%s' "$arguments" | $_JQ -r '.count // empty' 2>/dev/null)
            timeout=$(printf '%s' "$arguments" | $_JQ -r '.timeout // empty' 2>/dev/null)
            [ -z "$count" ] || [ "$count" = "null" ] && count=1
            [ -z "$timeout" ] || [ "$timeout" = "null" ] && timeout=10

            if [ -z "$topic" ]; then
                _respond_result "$id" "$(_text_content "Error: topic parameter is required")"
                return
            fi

            local sub_result
            sub_result=$(mqtt_subscribe "$topic" --count "$count" --timeout "$timeout" 2>&1)
            local sub_rc=$?

            if [ $sub_rc -eq 0 ] && [ -n "$sub_result" ]; then
                _respond_result "$id" "$(_text_content "$sub_result")"
            elif [ $sub_rc -eq 0 ]; then
                _respond_result "$id" "$(_text_content "No messages received on $topic within ${timeout}s")"
            else
                _respond_result "$id" "$(_text_content "Error subscribing to $topic: $sub_result")"
            fi
            ;;

        mqtt_status)
            local status_result
            status_result=$(mqtt_status 2>&1)
            local status_rc=$?

            if [ $status_rc -eq 0 ]; then
                _respond_result "$id" "$(_text_content "MQTT broker $MQTT_BROKER:$MQTT_PORT — $status_result")"
            else
                _respond_result "$id" "$(_text_content "MQTT broker $MQTT_BROKER:$MQTT_PORT — $status_result")"
            fi
            ;;

        *)
            _respond_error "$id" -32601 "Unknown tool: $tool_name"
            ;;
    esac
}

# ── Main JSON-RPC Loop ────────────────────────────────────────

while IFS= read -r line; do
    [ -z "$line" ] && continue

    local_id=$(printf '%s' "$line" | $_JQ -r '.id // "null"' 2>/dev/null)
    local_method=$(printf '%s' "$line" | $_JQ -r '.method // empty' 2>/dev/null)

    if [ -z "$local_method" ]; then
        continue
    fi

    case "$local_method" in
        initialize)
            _respond_result "$local_id" '{
                "protocolVersion": "2024-11-05",
                "capabilities": {
                    "tools": {}
                },
                "serverInfo": {
                    "name": "george-mqtt",
                    "version": "1.0"
                }
            }'
            ;;

        tools/list)
            _respond_result "$local_id" "{\"tools\":$_TOOLS_JSON}"
            ;;

        tools/call)
            tool_name=$(printf '%s' "$line" | $_JQ -r '.params.name // empty' 2>/dev/null)
            tool_args=$(printf '%s' "$line" | $_JQ -r '.params.arguments // {}' 2>/dev/null)
            _handle_tool_call "$local_id" "$tool_name" "$tool_args"
            ;;

        notifications/*)
            ;;

        *)
            _respond_error "$local_id" -32601 "Method not found: $local_method"
            ;;
    esac
done
