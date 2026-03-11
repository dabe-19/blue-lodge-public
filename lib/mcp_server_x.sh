#!/bin/bash
# ── George: Pure-Bash MCP X (Twitter) Server ──────────────────
# A self-contained MCP server that speaks JSON-RPC 2.0 over stdio.
# Exposes X/Twitter v2 API operations as MCP tools so the agent
# can post, search, reply, and manage tweets via the MCP client.
#
# Tools exposed:
#   x_post          — Post a tweet
#   x_timeline      — Get recent tweets from your account
#   x_reply         — Reply to an existing tweet
#   x_search        — Search recent tweets by keyword
#   x_delete        — Delete a tweet by ID
#
# Auth: Requires X_BEARER_TOKEN environment variable.
#   Setup: developer.x.com → Apps → Keys and Tokens → Bearer Token
#
# Usage:
#   Register as MCP server:
#     /mcp add george-x "bash $LODGE_DIR/lib/mcp_server_x.sh"
#
#   Or run standalone:
#     echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | bash lib/mcp_server_x.sh

set -uo pipefail

# ── Bootstrap George libraries ─────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="${LODGE_DIR:-$(cd "$_SCRIPT_DIR/.." && pwd)}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/cache.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/social.sh"

# Ensure cache/config dirs exist
GEORGE_CACHE_DIR="${GEORGE_CACHE_DIR:-$GEORGE_DIR/cache/web}"
mkdir -p "$GEORGE_CACHE_DIR" 2>/dev/null

# ── jq (hard dependency — installed by install.sh) ────────────
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
    "name": "x_post",
    "description": "Post a tweet to X (Twitter). Returns the tweet ID and full API response on success.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "text": {
          "type": "string",
          "description": "The tweet text (max 280 characters)"
        }
      },
      "required": ["text"]
    }
  },
  {
    "name": "x_timeline",
    "description": "Get recent tweets from your X (Twitter) account. Returns tweet IDs and text.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "count": {
          "type": "integer",
          "description": "Number of tweets to return (default: 10, max: 100)"
        }
      }
    }
  },
  {
    "name": "x_reply",
    "description": "Reply to an existing tweet on X (Twitter). Requires the tweet ID to reply to and the reply text.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "tweet_id": {
          "type": "string",
          "description": "The ID of the tweet to reply to"
        },
        "text": {
          "type": "string",
          "description": "The reply text (max 280 characters)"
        }
      },
      "required": ["tweet_id", "text"]
    }
  },
  {
    "name": "x_search",
    "description": "Search recent tweets on X (Twitter) by keyword. Returns matching tweet IDs and text. Uses the v2 search/recent endpoint.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "description": "The search query"
        },
        "count": {
          "type": "integer",
          "description": "Number of results to return (default: 10, max: 100)"
        }
      },
      "required": ["query"]
    }
  },
  {
    "name": "x_delete",
    "description": "Delete a tweet from X (Twitter) by its ID.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "tweet_id": {
          "type": "string",
          "description": "The ID of the tweet to delete"
        }
      },
      "required": ["tweet_id"]
    }
  }
]'

# ── Tool Dispatch ──────────────────────────────────────────────

_handle_tool_call() {
    local id="$1"
    local tool_name="$2"
    local arguments="$3"

    # Pre-check: X_BEARER_TOKEN required for all tools
    if [ -z "${X_BEARER_TOKEN:-}" ]; then
        _respond_result "$id" "$(_text_content "Error: X_BEARER_TOKEN not set. Configure it: /secret set X_BEARER_TOKEN <token>")"
        return
    fi

    case "$tool_name" in
        x_post)
            local text
            text=$(printf '%s' "$arguments" | $_JQ -r '.text // empty' 2>/dev/null)

            if [ -z "$text" ]; then
                _respond_result "$id" "$(_text_content "Error: text parameter is required")"
                return
            fi

            local result
            result=$(x_post "$text" 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$result" ]; then
                local tweet_id
                tweet_id=$(printf '%s' "$result" | $_JQ -r '.data.id // empty' 2>/dev/null)
                _respond_result "$id" "$(_text_content "Posted to X (ID: ${tweet_id:-unknown})\n$result")"
            else
                _respond_result "$id" "$(_text_content "Error: Failed to post to X. Check X_BEARER_TOKEN permissions.")"
            fi
            ;;

        x_timeline)
            local count
            count=$(printf '%s' "$arguments" | $_JQ -r '.count // empty' 2>/dev/null)
            [ -z "$count" ] && count=10

            local result
            result=$(x_timeline "$count" 2>/dev/null)
            if [ -n "$result" ]; then
                _respond_result "$id" "$(_text_content "$result")"
            else
                _respond_result "$id" "$(_text_content "No recent tweets found or API error")"
            fi
            ;;

        x_reply)
            local tweet_id text
            tweet_id=$(printf '%s' "$arguments" | $_JQ -r '.tweet_id // empty' 2>/dev/null)
            text=$(printf '%s' "$arguments" | $_JQ -r '.text // empty' 2>/dev/null)

            if [ -z "$tweet_id" ]; then
                _respond_result "$id" "$(_text_content "Error: tweet_id parameter is required")"
                return
            fi
            if [ -z "$text" ]; then
                _respond_result "$id" "$(_text_content "Error: text parameter is required")"
                return
            fi

            local result
            result=$(x_reply "$tweet_id" "$text" 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$result" ]; then
                _respond_result "$id" "$(_text_content "Replied to tweet $tweet_id\n$result")"
            else
                _respond_result "$id" "$(_text_content "Error: Failed to reply to tweet $tweet_id")"
            fi
            ;;

        x_search)
            local query count
            query=$(printf '%s' "$arguments" | $_JQ -r '.query // empty' 2>/dev/null)
            count=$(printf '%s' "$arguments" | $_JQ -r '.count // empty' 2>/dev/null)
            [ -z "$count" ] && count=10

            if [ -z "$query" ]; then
                _respond_result "$id" "$(_text_content "Error: query parameter is required")"
                return
            fi

            local result
            result=$(x_search "$query" "$count" 2>/dev/null)
            if [ -n "$result" ]; then
                _respond_result "$id" "$(_text_content "$result")"
            else
                _respond_result "$id" "$(_text_content "No results found for: $query")"
            fi
            ;;

        x_delete)
            local tweet_id
            tweet_id=$(printf '%s' "$arguments" | $_JQ -r '.tweet_id // empty' 2>/dev/null)

            if [ -z "$tweet_id" ]; then
                _respond_result "$id" "$(_text_content "Error: tweet_id parameter is required")"
                return
            fi

            local result
            result=$(x_delete "$tweet_id" 2>/dev/null)
            if [ $? -eq 0 ]; then
                _respond_result "$id" "$(_text_content "Deleted tweet $tweet_id")"
            else
                _respond_result "$id" "$(_text_content "Error: Failed to delete tweet $tweet_id")"
            fi
            ;;

        *)
            _respond_error "$id" -32601 "Unknown tool: $tool_name"
            ;;
    esac
}

# ── Main JSON-RPC Loop ────────────────────────────────────────
# Reads one JSON-RPC message per line from stdin, dispatches, and
# writes responses to stdout. This is the MCP stdio transport.

while IFS= read -r line; do
    [ -z "$line" ] && continue

    # Parse the request
    local_id=$(printf '%s' "$line" | $_JQ -r '.id // "null"' 2>/dev/null)
    local_method=$(printf '%s' "$line" | $_JQ -r '.method // empty' 2>/dev/null)

    if [ -z "$local_method" ]; then
        continue
    fi

    case "$local_method" in
        # ── MCP Lifecycle ──────────────────────────────────────
        initialize)
            _respond_result "$local_id" '{
                "protocolVersion": "2024-11-05",
                "capabilities": {
                    "tools": {}
                },
                "serverInfo": {
                    "name": "george-x",
                    "version": "1.0"
                }
            }'
            ;;

        # ── Tool Discovery ─────────────────────────────────────
        tools/list)
            _respond_result "$local_id" "{\"tools\":$_TOOLS_JSON}"
            ;;

        # ── Tool Execution ─────────────────────────────────────
        tools/call)
            tool_name=$(printf '%s' "$line" | $_JQ -r '.params.name // empty' 2>/dev/null)
            tool_args=$(printf '%s' "$line" | $_JQ -r '.params.arguments // {}' 2>/dev/null)
            _handle_tool_call "$local_id" "$tool_name" "$tool_args"
            ;;

        # ── Notifications (no response) ────────────────────────
        notifications/*)
            ;;

        # ── Unknown method ─────────────────────────────────────
        *)
            _respond_error "$local_id" -32601 "Method not found: $local_method"
            ;;
    esac
done
