#!/bin/bash
# ── George: Pure-Bash MCP Fetch Server ─────────────────────────
# A self-contained MCP server that speaks JSON-RPC 2.0 over stdio.
# Reuses George's web.sh scraping engine — no Node.js, no Python.
#
# Tools exposed:
#   fetch          — Fetch a URL, return clean extracted text
#   fetch_json     — Fetch a URL, return structured JSON (title, content, images)
#   fetch_pdf      — Fetch and extract text from a PDF URL
#   web_search     — Search the web (DDG, Serper, Perplexity)
#   web_images     — Search for images (Serper)
#   github_search  — Search GitHub repositories
#
# Compared to @anthropic/mcp-server-fetch:
#   ✓ Pure bash + curl (no Node.js runtime)
#   ✓ Semantic HTML extraction (<article>/<main> priority)
#   ✓ Anti-bot detection + blacklisting
#   ✓ PDF text extraction (pdftotext/strings fallback)
#   ✓ Multi-provider search (DDG, Serper, Perplexity)
#   ✓ Image extraction from HTML (og:image, srcset, etc.)
#   ✗ No JavaScript rendering (no headless browser)
#
# Usage:
#   Register as MCP server:
#     /mcp add fetch "bash $LODGE_DIR/lib/mcp_server_fetch.sh"
#
#   Or run standalone:
#     echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | bash lib/mcp_server_fetch.sh

set -uo pipefail

# ── Bootstrap George libraries ─────────────────────────────────
# Resolve LODGE_DIR from script location or environment.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="${LODGE_DIR:-$(cd "$_SCRIPT_DIR/.." && pwd)}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"

# Source only what we need — web.sh pulls in its own deps.
# Guard against double-sourcing with the library's own flags.
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/cache.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/web.sh"

# Ensure cache dir exists (web.sh needs it)
GEORGE_CACHE_DIR="${GEORGE_CACHE_DIR:-$GEORGE_DIR/cache/web}"
mkdir -p "$GEORGE_CACHE_DIR" 2>/dev/null

# ── jq (hard dependency — installed by install.sh) ────────────
# Prefer gojq if available (faster for streaming), otherwise jq.
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
    # id may be null for parse errors
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
    "name": "fetch",
    "description": "Fetch a URL and return clean extracted text. Handles HTML (semantic extraction from <article>/<main>), PDF (pdftotext), JSON, XML, and plain text. Includes anti-bot detection and automatic caching.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "url": {
          "type": "string",
          "description": "The URL to fetch"
        },
        "max_lines": {
          "type": "integer",
          "description": "Maximum lines of content to return (default: 500)"
        }
      },
      "required": ["url"]
    }
  },
  {
    "name": "fetch_json",
    "description": "Fetch a URL and return structured data: title, content text, and image URLs. Best for pages where you need metadata alongside the content.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "url": {
          "type": "string",
          "description": "The URL to fetch"
        }
      },
      "required": ["url"]
    }
  },
  {
    "name": "fetch_pdf",
    "description": "Fetch a PDF URL and extract its text content. Uses pdftotext when available, falls back to strings extraction.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "url": {
          "type": "string",
          "description": "The PDF URL to fetch"
        }
      },
      "required": ["url"]
    }
  },
  {
    "name": "web_search",
    "description": "Search the web. Uses DuckDuckGo by default, Serper (Google) if SERPER_API_KEY is set, or Perplexity if PERPLEXITY_API_KEY is set. Returns titles, URLs, and snippets.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "description": "The search query"
        },
        "count": {
          "type": "integer",
          "description": "Number of results to return (default: 5)"
        }
      },
      "required": ["query"]
    }
  },
  {
    "name": "web_images",
    "description": "Search for images. Requires SERPER_API_KEY. Returns image URLs with dimensions and source pages.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "description": "The image search query"
        },
        "count": {
          "type": "integer",
          "description": "Number of results to return (default: 5)"
        }
      },
      "required": ["query"]
    }
  },
  {
    "name": "github_search",
    "description": "Search GitHub repositories by keyword. Returns repo name, stars, language, and description. No auth needed.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "description": "The search query"
        },
        "count": {
          "type": "integer",
          "description": "Number of results to return (default: 5)"
        }
      },
      "required": ["query"]
    }
  }
]'

# ── Tool Dispatch ──────────────────────────────────────────────

_handle_tool_call() {
    local id="$1"
    local tool_name="$2"
    local arguments="$3"

    case "$tool_name" in
        fetch)
            local url max_lines
            url=$(printf '%s' "$arguments" | $_JQ -r '.url // empty' 2>/dev/null)
            max_lines=$(printf '%s' "$arguments" | $_JQ -r '.max_lines // empty' 2>/dev/null)
            [ -z "$max_lines" ] && max_lines=500

            if [ -z "$url" ]; then
                _respond_result "$id" "$(_text_content "Error: url parameter is required")"
                return
            fi

            local content
            content=$(web_fetch "$url" 2>/dev/null | head -"$max_lines")
            if [ -z "$content" ]; then
                _respond_result "$id" "$(_text_content "Error: Failed to fetch $url (may be blocked, unreachable, or empty)")"
                return
            fi

            _respond_result "$id" "$(_text_content "$content")"
            ;;

        fetch_json)
            local url
            url=$(printf '%s' "$arguments" | $_JQ -r '.url // empty' 2>/dev/null)

            if [ -z "$url" ]; then
                _respond_result "$id" "$(_text_content "Error: url parameter is required")"
                return
            fi

            local json_result
            json_result=$(web_fetch_json "$url" 2>/dev/null)
            if [ -z "$json_result" ]; then
                _respond_result "$id" "$(_text_content "Error: Failed to fetch $url")"
                return
            fi

            # Return the structured JSON as text content
            _respond_result "$id" "$(_text_content "$json_result")"
            ;;

        fetch_pdf)
            local url
            url=$(printf '%s' "$arguments" | $_JQ -r '.url // empty' 2>/dev/null)

            if [ -z "$url" ]; then
                _respond_result "$id" "$(_text_content "Error: url parameter is required")"
                return
            fi

            local pdf_text
            pdf_text=$(_web_extract_pdf "$url" 2>/dev/null)
            if [ -z "$pdf_text" ]; then
                _respond_result "$id" "$(_text_content "Error: Failed to extract PDF text from $url")"
                return
            fi

            _respond_result "$id" "$(_text_content "$pdf_text")"
            ;;

        web_search)
            local query count
            query=$(printf '%s' "$arguments" | $_JQ -r '.query // empty' 2>/dev/null)
            count=$(printf '%s' "$arguments" | $_JQ -r '.count // empty' 2>/dev/null)
            [ -z "$count" ] && count=5

            if [ -z "$query" ]; then
                _respond_result "$id" "$(_text_content "Error: query parameter is required")"
                return
            fi

            local results
            results=$(web_search "$query" "$count" 2>/dev/null)
            if [ -z "$results" ]; then
                _respond_result "$id" "$(_text_content "No results found for: $query")"
                return
            fi

            _respond_result "$id" "$(_text_content "$results")"
            ;;

        web_images)
            local query count
            query=$(printf '%s' "$arguments" | $_JQ -r '.query // empty' 2>/dev/null)
            count=$(printf '%s' "$arguments" | $_JQ -r '.count // empty' 2>/dev/null)
            [ -z "$count" ] && count=5

            if [ -z "$query" ]; then
                _respond_result "$id" "$(_text_content "Error: query parameter is required")"
                return
            fi

            local results
            results=$(web_images "$query" "$count" 2>/dev/null)
            if [ -z "$results" ]; then
                _respond_result "$id" "$(_text_content "Error: Image search requires SERPER_API_KEY")"
                return
            fi

            _respond_result "$id" "$(_text_content "$results")"
            ;;

        github_search)
            local query count
            query=$(printf '%s' "$arguments" | $_JQ -r '.query // empty' 2>/dev/null)
            count=$(printf '%s' "$arguments" | $_JQ -r '.count // empty' 2>/dev/null)
            [ -z "$count" ] && count=5

            if [ -z "$query" ]; then
                _respond_result "$id" "$(_text_content "Error: query parameter is required")"
                return
            fi

            local results
            results=$(web_search_github "$query" "$count" 2>/dev/null)
            if [ -z "$results" ]; then
                _respond_result "$id" "$(_text_content "No GitHub results for: $query")"
                return
            fi

            _respond_result "$id" "$(_text_content "$results")"
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
        # Not a valid JSON-RPC request — skip silently
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
                    "name": "george-fetch",
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
            # MCP notifications — acknowledged silently
            ;;

        # ── Unknown method ─────────────────────────────────────
        *)
            _respond_error "$local_id" -32601 "Method not found: $local_method"
            ;;
    esac
done
