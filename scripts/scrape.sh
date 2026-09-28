#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# George Sovereign Pure Bash Web Scraper
# ══════════════════════════════════════════════════════════════════════
# 100% pure bash, curl, and POSIX awk state machine.
# Zero Python, zero w3m, zero lynx, zero external runtime dependencies.
#
# Usage:
#   scripts/scrape.sh <url> [max_lines]
#   scripts/scrape.sh --json <url>
#   cat file.html | scripts/scrape.sh -
# ══════════════════════════════════════════════════════════════════════

set -euo pipefail

LODGE_DIR="${LODGE_DIR:-/home/wsl-ops/blue-lodge}"
export GEORGE_CONFIG_DIR="${GEORGE_CONFIG_DIR:-$LODGE_DIR/.george}"
source "$LODGE_DIR/lib/web.sh" 2>/dev/null || true

AS_JSON=0
if [ "${1:-}" = "--json" ]; then
    AS_JSON=1
    shift
fi

TARGET="${1:-}"
MAX_LINES="${2:-500}"

if [ -z "$TARGET" ]; then
    echo "Usage: scrape.sh [--json] <url_or_file_or_-> [max_lines]" >&2
    exit 1
fi

if [ "$TARGET" = "-" ]; then
    TARGET=""
fi

if [ "$AS_JSON" -eq 1 ]; then
    # Structured JSON output via pure bash/awk/jq
    TITLE=""
    RAW_HTML=""
    if [ -n "$TARGET" ] && [[ "$TARGET" =~ ^https?:// ]]; then
        RAW_HTML=$(_web_curl --max-time "${WEB_TIMEOUT:-10}" --max-filesize "${WEB_MAX_SIZE:-524288}" "$TARGET" 2>/dev/null || true)
    elif [ -n "$TARGET" ] && [ -f "$TARGET" ]; then
        RAW_HTML=$(cat "$TARGET" 2>/dev/null || true)
    else
        RAW_HTML=$(cat 2>/dev/null || true)
    fi

    TITLE=$(echo "$RAW_HTML" | _html_extract_title 2>/dev/null || echo "Web Page")
    [ -z "$TITLE" ] && TITLE="Web Page"

    CONTENT=$(echo "$RAW_HTML" | web_scrape_pure_bash "" "$MAX_LINES" 2>/dev/null || true)
    
    jq -n \
        --arg url "${TARGET:-stdin}" \
        --arg title "$TITLE" \
        --arg content "$CONTENT" \
        '{"url": $url, "title": $title, "content": $content}'
else
    web_scrape_pure_bash "$TARGET" "$MAX_LINES"
fi
