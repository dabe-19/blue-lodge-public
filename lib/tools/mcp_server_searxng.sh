#!/bin/bash
# ── George: Sovereign SearXNG MCP Server ────────────────────────
# Speaks JSON-RPC 2.0 over stdio per Model Context Protocol standard.
# Provides sovereign, keyless metasearch queries across Google, Bing,
# DuckDuckGo, Brave, Wikipedia, GitHub, StackOverflow, arXiv, PubMed,
# and RSS feeds for George.
#
# Tools exposed:
#   searxng_search         — Sovereign multi-engine general metasearch
#   searxng_code_search    — IT/Developer code, repo, and Q&A search
#   searxng_science_search — Academic publications, arXiv, and research search
#   searxng_news_search    — Time-sensitive news searches with recency filters
#   searxng_images         — Multi-engine visual image search
#   searxng_rss            — Real-time RSS news feed combing
#   searxng_engines        — Introspection of active engines, shortcuts, and categories
#   searxng_health         — Health, latency, and status probe of SearXNG container
#
# Usage:
#   echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | bash lib/tools/mcp_server_searxng.sh

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="${LODGE_DIR:-$(cd "$_SCRIPT_DIR/../.." && pwd)}"

_JQ="jq"
command -v gojq >/dev/null 2>&1 && _JQ="gojq"

_PYTHON="python3"
if [ -x "$LODGE_DIR/.venv/bin/python" ]; then
    _PYTHON="$LODGE_DIR/.venv/bin/python"
elif command -v uv >/dev/null 2>&1; then
    _PYTHON="uv run --project $LODGE_DIR python"
fi

_SEARXNG_BACKEND="$LODGE_DIR/lib/tools/searxng_backend.py"

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

_TOOLS_JSON='[
  {
    "name": "searxng_search",
    "description": "Execute sovereign keyless metasearch across Google, Bing, DuckDuckGo, Brave, Wikipedia, and eBay. Supports category filtering, bang syntax (!it, !science, !gh, !arxiv), and time ranges.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "query": { "type": "string", "description": "The search query phrase or bang syntax" },
        "category": { "type": "string", "description": "Search category: general, it, science, news, images, files, social media (default: general)", "enum": ["general", "it", "science", "news", "images", "files", "social media"] },
        "engines": { "type": "string", "description": "Optional comma-separated list of specific engines to query (e.g. google,bing,duckduckgo)" },
        "time_range": { "type": "string", "description": "Time range filter: day, week, month, year", "enum": ["day", "week", "month", "year"] },
        "language": { "type": "string", "description": "Language code (e.g. en)" },
        "pageno": { "type": "integer", "description": "Page number (1-indexed, default: 1)" },
        "max_results": { "type": "integer", "description": "Maximum number of results to return (default: 8)" }
      },
      "required": ["query"]
    }
  },
  {
    "name": "searxng_code_search",
    "description": "Search developer code repositories, documentation, and technical Q&A across GitHub, GitLab, StackOverflow, crates.io, PyPI, npm, Arch Wiki, MDN, and Docker Hub.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "query": { "type": "string", "description": "Code, repository, library, or error message to search" },
        "engines": { "type": "string", "description": "Optional comma-separated engines (default: github,gitlab,stackoverflow,crates.io,pypi,npm,arch linux wiki,mdn,docker hub,huggingface)" },
        "max_results": { "type": "integer", "description": "Maximum results to return (default: 8)" }
      },
      "required": ["query"]
    }
  },
  {
    "name": "searxng_science_search",
    "description": "Search academic publications, scientific papers, and research databases across arXiv, PubMed, Crossref, Google Scholar, Semantic Scholar, and Europe PMC.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "query": { "type": "string", "description": "Research paper topic, author, DOI, or scientific concept" },
        "engines": { "type": "string", "description": "Optional comma-separated engines (default: arxiv,pubmed,crossref,google scholar,semantic scholar,europepmc)" },
        "time_range": { "type": "string", "description": "Time filter: day, week, month, year", "enum": ["day", "week", "month", "year"] },
        "max_results": { "type": "integer", "description": "Maximum papers to return (default: 8)" }
      },
      "required": ["query"]
    }
  },
  {
    "name": "searxng_news_search",
    "description": "Search recent news articles with recency filters across Google News, Bing News, and DuckDuckGo News.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "query": { "type": "string", "description": "News topic or current event" },
        "time_range": { "type": "string", "description": "Recency: day, week, month (default: week)", "enum": ["day", "week", "month"] },
        "max_results": { "type": "integer", "description": "Maximum news articles to return (default: 8)" }
      },
      "required": ["query"]
    }
  },
  {
    "name": "searxng_images",
    "description": "Execute sovereign multi-engine image search across Google Images, Bing Images, and DuckDuckGo Images. Returns thumbnail URLs, source URLs, and titles.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "query": { "type": "string", "description": "The image search query" },
        "max_results": { "type": "integer", "description": "Maximum image results to return (default: 10)" }
      },
      "required": ["query"]
    }
  },
  {
    "name": "searxng_rss",
    "description": "Comb RSS news and media feeds for breaking real-time coverage and current events without rate limits.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "query": { "type": "string", "description": "Topic or entity to comb news feeds for" },
        "max_results": { "type": "integer", "description": "Maximum RSS articles to return (default: 8)" }
      },
      "required": ["query"]
    }
  },
  {
    "name": "searxng_engines",
    "description": "Discover active SearXNG search engines, shortcuts, and categories to introspect available search capabilities.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "category": { "type": "string", "description": "Optional category filter (e.g. it, science, general, news, images)" }
      }
    }
  },
  {
    "name": "searxng_health",
    "description": "Probe health, latency, and reachable search engines of the local SearXNG metasearch container.",
    "inputSchema": {
      "type": "object",
      "properties": {}
    }
  }
]'

_handle_tool_call() {
    local id="$1"
    local name="$2"
    local args_json="$3"

    case "$name" in
        searxng_search)
            local query
            query=$(echo "$args_json" | $_JQ -r '.query // empty')
            [ -z "$query" ] && { _respond_error "$id" -32602 "Missing required parameter: query"; return; }
            local cat
            cat=$(echo "$args_json" | $_JQ -r '.category // "general"')
            local max_res
            max_res=$(echo "$args_json" | $_JQ -r '.max_results // 8')
            local time_range
            time_range=$(echo "$args_json" | $_JQ -r '.time_range // empty')
            local engines
            engines=$(echo "$args_json" | $_JQ -r '.engines // empty')
            local lang
            lang=$(echo "$args_json" | $_JQ -r '.language // empty')
            local page
            page=$(echo "$args_json" | $_JQ -r '.pageno // 1')

            local py_args=(search --query "$query" --category "$cat" --max-results "$max_res" --page "$page" --format json)
            [ -n "$time_range" ] && py_args+=(--time-range "$time_range")
            [ -n "$engines" ] && py_args+=(--engines "$engines")
            [ -n "$lang" ] && py_args+=(--language "$lang")

            local out
            out=$($_PYTHON "$_SEARXNG_BACKEND" "${py_args[@]}" 2>/dev/null)
            _respond_result "$id" "$(_text_content "$out")"
            ;;

        searxng_code_search)
            local query
            query=$(echo "$args_json" | $_JQ -r '.query // empty')
            [ -z "$query" ] && { _respond_error "$id" -32602 "Missing required parameter: query"; return; }
            local max_res
            max_res=$(echo "$args_json" | $_JQ -r '.max_results // 8')
            local engines
            engines=$(echo "$args_json" | $_JQ -r '.engines // empty')

            local py_args=(code --query "$query" --max-results "$max_res" --format json)
            [ -n "$engines" ] && py_args+=(--engines "$engines")

            local out
            out=$($_PYTHON "$_SEARXNG_BACKEND" "${py_args[@]}" 2>/dev/null)
            _respond_result "$id" "$(_text_content "$out")"
            ;;

        searxng_science_search)
            local query
            query=$(echo "$args_json" | $_JQ -r '.query // empty')
            [ -z "$query" ] && { _respond_error "$id" -32602 "Missing required parameter: query"; return; }
            local max_res
            max_res=$(echo "$args_json" | $_JQ -r '.max_results // 8')
            local time_range
            time_range=$(echo "$args_json" | $_JQ -r '.time_range // empty')
            local engines
            engines=$(echo "$args_json" | $_JQ -r '.engines // empty')

            local py_args=(science --query "$query" --max-results "$max_res" --format json)
            [ -n "$time_range" ] && py_args+=(--time-range "$time_range")
            [ -n "$engines" ] && py_args+=(--engines "$engines")

            local out
            out=$($_PYTHON "$_SEARXNG_BACKEND" "${py_args[@]}" 2>/dev/null)
            _respond_result "$id" "$(_text_content "$out")"
            ;;

        searxng_news_search)
            local query
            query=$(echo "$args_json" | $_JQ -r '.query // empty')
            [ -z "$query" ] && { _respond_error "$id" -32602 "Missing required parameter: query"; return; }
            local max_res
            max_res=$(echo "$args_json" | $_JQ -r '.max_results // 8')
            local time_range
            time_range=$(echo "$args_json" | $_JQ -r '.time_range // "week"')

            local out
            out=$($_PYTHON "$_SEARXNG_BACKEND" news --query "$query" --time-range "$time_range" --max-results "$max_res" --format json 2>/dev/null)
            _respond_result "$id" "$(_text_content "$out")"
            ;;

        searxng_images)
            local query
            query=$(echo "$args_json" | $_JQ -r '.query // empty')
            [ -z "$query" ] && { _respond_error "$id" -32602 "Missing required parameter: query"; return; }
            local max_res
            max_res=$(echo "$args_json" | $_JQ -r '.max_results // 10')

            local out
            out=$($_PYTHON "$_SEARXNG_BACKEND" images --query "$query" --max-results "$max_res" --format json 2>/dev/null)
            _respond_result "$id" "$(_text_content "$out")"
            ;;

        searxng_rss)
            local query
            query=$(echo "$args_json" | $_JQ -r '.query // empty')
            [ -z "$query" ] && { _respond_error "$id" -32602 "Missing required parameter: query"; return; }
            local max_res
            max_res=$(echo "$args_json" | $_JQ -r '.max_results // 8')

            local out
            out=$($_PYTHON "$_SEARXNG_BACKEND" rss --query "$query" --max-results "$max_res" --format json 2>/dev/null)
            _respond_result "$id" "$(_text_content "$out")"
            ;;

        searxng_engines)
            local cat
            cat=$(echo "$args_json" | $_JQ -r '.category // empty')
            local py_args=(engines --format json)
            [ -n "$cat" ] && py_args+=(--category "$cat")

            local out
            out=$($_PYTHON "$_SEARXNG_BACKEND" "${py_args[@]}" 2>/dev/null)
            _respond_result "$id" "$(_text_content "$out")"
            ;;

        searxng_health)
            local out
            out=$($_PYTHON "$_SEARXNG_BACKEND" health 2>/dev/null)
            _respond_result "$id" "$(_text_content "$out")"
            ;;

        *)
            _respond_error "$id" -32601 "Method not found: $name"
            ;;
    esac
}

while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue

    method=$(echo "$line" | $_JQ -r '.method // empty')
    id=$(echo "$line" | $_JQ -r '.id // "null"')

    case "$method" in
        initialize)
            _respond_result "$id" '{
              "protocolVersion": "2024-11-05",
              "capabilities": {
                "tools": { "listChanged": false }
              },
              "serverInfo": {
                "name": "george-searxng",
                "version": "1.0.0"
              }
            }'
            ;;

        notifications/initialized)
            # Notification: no response required
            ;;

        ping)
            _respond_result "$id" '{}'
            ;;

        tools/list)
            _respond_result "$id" "{\"tools\": $_TOOLS_JSON}"
            ;;

        tools/call)
            name=$(echo "$line" | $_JQ -r '.params.name // empty')
            args_json=$(echo "$line" | $_JQ -c '.params.arguments // {}')
            _handle_tool_call "$id" "$name" "$args_json"
            ;;

        *)
            _respond_error "$id" -32601 "Method not found: $method"
            ;;
    esac
done
