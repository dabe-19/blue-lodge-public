#!/bin/bash
# ── George: Web Browsing Engine ────────────────────────────────
# Fetch, parse, search, and summarize web content using only
# curl + sed/awk (with optional w3m/lynx for better rendering).
# George can now read the web and act on what he finds.

[ -n "${_LIB_WEB_LOADED:-}" ] && return 0; _LIB_WEB_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/api.sh"

# ── Config ─────────────────────────────────────────────────────
WEB_TIMEOUT="${WEB_TIMEOUT:-15}"
WEB_MAX_SIZE="${WEB_MAX_SIZE:-2000000}"      # 2MB max HTML download
WEB_MAX_SIZE_PDF="${WEB_MAX_SIZE_PDF:-10000000}"  # 10MB max PDF download
WEB_CACHE_TTL="${WEB_CACHE_TTL:-3600}"     # Cache pages for 1 hour
WEB_BLACKLIST_FILE="${WEB_BLACKLIST_FILE:-${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}/web_blacklist.log}"
WEB_BLACKLIST_ENABLED="${WEB_BLACKLIST_ENABLED:-true}"

# Preloaded domain blacklist — sites that aggressively block bots.
# Comma-separated list. Fetch/scrape is skipped for these hosts,
# but search-result headers (title + snippet) are still used.
# Override in .george/config or environment to add/remove domains.
WEB_BLACKLIST_DOMAINS="${WEB_BLACKLIST_DOMAINS:-linkedin.com,facebook.com,instagram.com,twitter.com,x.com,tiktok.com,pinterest.com}"

# ── Centralized curl wrapper ──────────────────────────────────
# All web-browsing curl calls route through _web_curl to ensure:
#   - Current, realistic User-Agent (prevents UA-based bot detection)
#   - --compressed (gzip/deflate/br — many CDNs require this)
#   - Cookie jar (prevents cookie-wall and CF challenge failures)
#   - Accept-Language
# Override WEB_USER_AGENT in env or .george/config to customize.
WEB_USER_AGENT="${WEB_USER_AGENT:-Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.6943.150 Mobile Safari/537.36}"
_WEB_COOKIE_JAR="${TMPDIR:-/tmp}/.lodge-web-cookies-$$.jar"

_web_curl() {
    curl -sL \
        --compressed \
        -b "$_WEB_COOKIE_JAR" -c "$_WEB_COOKIE_JAR" \
        -H "User-Agent: $WEB_USER_AGENT" \
        -H "Accept-Language: en-US,en;q=0.9" \
        "$@"
}

# ── Blocked-site detection + blacklist ───────────────────────
_web_block_reason() {
    local status="$1"
    local html="$2"
    local lower_html
    lower_html=$(printf '%s' "$html" | tr '[:upper:]' '[:lower:]')

    # HTTP status based blocking / throttling / WAF signals
    case "$status" in
        401) echo "HTTP_401_UNAUTHORIZED"; return 0 ;;
        403) echo "HTTP_403_FORBIDDEN"; return 0 ;;
        407) echo "HTTP_407_PROXY_AUTH"; return 0 ;;
        429) echo "HTTP_429_RATE_LIMIT"; return 0 ;;
        451) echo "HTTP_451_LEGAL_RESTRICTED"; return 0 ;;
        503) echo "HTTP_503_UNAVAILABLE"; return 0 ;;
        520|521|522|523|525|530) echo "HTTP_${status}_EDGE_BLOCK"; return 0 ;;
        999) echo "HTTP_999_PLATFORM_BLOCK"; return 0 ;;
    esac

    # HTML challenge/captcha/waf detection
    if echo "$lower_html" | grep -qE 'captcha|cf-chl|challenge-platform|verify you are human|security check|request blocked|access denied|bot detection|cloudflare|incapsula|akamai'; then
        echo "HTML_CHALLENGE_OR_CAPTCHA"
        return 0
    fi

    return 1
}

_web_blacklist_is_enabled() {
    [[ "$WEB_BLACKLIST_ENABLED" == "true" || "$WEB_BLACKLIST_ENABLED" == "1" || "$WEB_BLACKLIST_ENABLED" == "yes" ]]
}

_web_blacklist_contains() {
    _web_blacklist_is_enabled || return 1
    local url="$1"
    local host
    host=$(echo "$url" | sed 's|^https\?://||' | cut -d'/' -f1)

    # Check preloaded domain blacklist first (fast, no file I/O)
    if [ -n "${WEB_BLACKLIST_DOMAINS:-}" ]; then
        local _domain
        local _host_lower
        _host_lower=$(echo "$host" | tr '[:upper:]' '[:lower:]')
        IFS=',' read -ra _bl_domains <<< "$WEB_BLACKLIST_DOMAINS"
        for _domain in "${_bl_domains[@]}"; do
            _domain=$(echo "$_domain" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')
            [ -z "$_domain" ] && continue
            # Match exact or subdomain (e.g., www.linkedin.com matches linkedin.com)
            if [[ "$_host_lower" == "$_domain" ]] || [[ "$_host_lower" == *".${_domain}" ]]; then
                return 0
            fi
        done
    fi

    [ -f "$WEB_BLACKLIST_FILE" ] || return 1
    grep -qE "\|url=${url//\//\\/}(\||$)|\|host=${host//\./\\.}(\||$)" "$WEB_BLACKLIST_FILE" 2>/dev/null
}

_web_blacklist_reason() {
    local url="$1"
    local host
    host=$(echo "$url" | sed 's|^https\?://||' | cut -d'/' -f1)

    [ -f "$WEB_BLACKLIST_FILE" ] || return 1

    # Prefer exact URL match, fallback to host match
    local line
    line=$(grep "|url=$url|" "$WEB_BLACKLIST_FILE" 2>/dev/null | tail -1)
    if [ -z "$line" ]; then
        line=$(grep "|host=$host|" "$WEB_BLACKLIST_FILE" 2>/dev/null | tail -1)
    fi
    [ -z "$line" ] && return 1

    echo "$line" | sed -n 's/.*|reason=\([^|]*\).*/\1/p'
}

_web_blacklist_add() {
    local url="$1"
    local reason="$2"
    local status="$3"
    local host
    host=$(echo "$url" | sed 's|^https\?://||' | cut -d'/' -f1)

    mkdir -p "$(dirname "$WEB_BLACKLIST_FILE")" 2>/dev/null

    # Avoid duplicate entries for the same host+reason in the same file
    if [ -f "$WEB_BLACKLIST_FILE" ] && grep -q "|host=$host|" "$WEB_BLACKLIST_FILE" 2>/dev/null && grep -q "|reason=$reason" "$WEB_BLACKLIST_FILE" 2>/dev/null; then
        return 0
    fi

    printf '%s|url=%s|host=%s|status=%s|reason=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$url" "$host" "${status:-unknown}" "$reason" >> "$WEB_BLACKLIST_FILE"
}

# ── Blacklist management commands ─────────────────────────────
web_blacklist_list() {
    if [ ! -f "$WEB_BLACKLIST_FILE" ] || [ ! -s "$WEB_BLACKLIST_FILE" ]; then
        ui_info "Blacklist is empty"
        return 0
    fi

    local _state="enabled"
    _web_blacklist_is_enabled || _state="disabled"
    ui_section "Web Blacklist ($_state)"

    local count=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local ts host reason status
        ts=$(echo "$line" | sed -n 's/^\([^|]*\)|.*/\1/p')
        host=$(echo "$line" | sed -n 's/.*|host=\([^|]*\).*/\1/p')
        reason=$(echo "$line" | sed -n 's/.*|reason=\([^|]*\).*/\1/p')
        status=$(echo "$line" | sed -n 's/.*|status=\([^|]*\).*/\1/p')
        printf '  %b%-30s%b  status=%-4s  %s  %b(%s)%b\n' \
            "$C_WHITE" "$host" "$C_RESET" "$status" "$reason" "$C_DIM" "$ts" "$C_RESET"
        count=$((count + 1))
    done < "$WEB_BLACKLIST_FILE"

    echo ""
    ui_dim "  $count entries total"
}

web_blacklist_rm() {
    local target="$1"
    if [ -z "$target" ]; then
        ui_err "Usage: /web blacklist rm <host-or-url>"
        return 1
    fi

    if [ ! -f "$WEB_BLACKLIST_FILE" ]; then
        ui_info "Blacklist is empty — nothing to remove"
        return 0
    fi

    # Extract host from URL if a full URL was given
    local host
    host=$(echo "$target" | sed 's|^https\?://||' | cut -d'/' -f1)

    local before after
    before=$(wc -l < "$WEB_BLACKLIST_FILE")
    grep -v "|host=$host|" "$WEB_BLACKLIST_FILE" > "${WEB_BLACKLIST_FILE}.tmp" 2>/dev/null
    mv "${WEB_BLACKLIST_FILE}.tmp" "$WEB_BLACKLIST_FILE"
    after=$(wc -l < "$WEB_BLACKLIST_FILE")

    local removed=$((before - after))
    if [ "$removed" -gt 0 ]; then
        ui_ok "Removed $removed entries for $host"
    else
        ui_info "No entries found for $host"
    fi
}

web_blacklist_clear() {
    if [ ! -f "$WEB_BLACKLIST_FILE" ] || [ ! -s "$WEB_BLACKLIST_FILE" ]; then
        ui_info "Blacklist is already empty"
        return 0
    fi

    local count
    count=$(wc -l < "$WEB_BLACKLIST_FILE")
    : > "$WEB_BLACKLIST_FILE"
    ui_ok "Cleared $count blacklist entries"
}

web_blacklist_enable() {
    WEB_BLACKLIST_ENABLED="true"
    ui_ok "Web blacklist enabled"
}

web_blacklist_disable() {
    WEB_BLACKLIST_ENABLED="false"
    ui_warn "Web blacklist disabled — blocked sites will be retried"
}

# ── URL Sanitization ──────────────────────────────────────────
# Whitelist-based URL cleaner. Strips control characters, validates
# the scheme, and truncates to a safe length. This prevents injection
# attacks when URLs from search results are stored in journal entries
# or injected into LLM prompts / shell commands.
#
# Rules:
#   1. Only http:// and https:// schemes allowed
#   2. Strip control chars (\x00-\x1f, \x7f), backticks, $, semicolons
#   3. Truncate to 2048 chars (browser practical limit)
#   4. Must contain a dot in the host portion
_web_sanitize_url() {
    local url="$1"

    # Strip leading/trailing whitespace
    url=$(echo "$url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Remove control characters, backticks, $, semicolons, pipes, and newlines
    url=$(printf '%s' "$url" | tr -d '\000-\037\177\`$;|')

    # Must start with http:// or https://
    if [[ ! "$url" =~ ^https?:// ]]; then
        return 1
    fi

    # Must have a dot in the host portion (reject http://localhost-style injections)
    local host
    host=$(echo "$url" | sed 's|^https\?://||' | cut -d'/' -f1 | cut -d'?' -f1)
    if [[ ! "$host" == *.* ]]; then
        return 1
    fi

    # Truncate to 2048 characters
    url="${url:0:2048}"

    printf '%s' "$url"
}

# ── Ad URL Detection ─────────────────────────────────────────
# Returns 0 (true) if the URL looks like a search engine ad/tracking
# redirect. Currently covers:
#   - DuckDuckGo:  duckduckgo.com/y.js (ad redirect), ad_domain=, ad_provider=
#   - Bing:        bing.com/aclick (ad click-through)
#   - Google:      googleadservices.com, google.com/aclk
#   - Generic:     doubleclick.net, ad.doubleclick.net
_web_is_ad_url() {
    local url="$1"
    case "$url" in
        *duckduckgo.com/y.js*)       return 0 ;;
        *ad_domain=*|*ad_provider=*) return 0 ;;
        *bing.com/aclick*)           return 0 ;;
        *googleadservices.com*)      return 0 ;;
        *google.com/aclk*)           return 0 ;;
        *doubleclick.net*)           return 0 ;;
        *googlesyndication.com*)     return 0 ;;
        *)                           return 1 ;;
    esac
}

# ── Journal Search Results ───────────────────────────────────
# Write a structured journal entry so George can reference URLs
# from a previous search in follow-up /web fetch|summary|title
# commands. Each entry records the query and numbered results
# with clean titles and sanitized URLs.
#
# Also writes to .george/search_results.md (if .george/ exists)
# for the current task's micro/macro memory to consume.
_web_journal_results() {
    local query="$1"
    local results_text="$2"  # The formatted [n] title\n    url\n output
    local provider="$3"      # ddg, serper, perplexity, github

    [ -z "$results_text" ] && return 0

    # NOTE: Search results are NOT written to journal.
    # Journal is for task reflection, quips, and personality — not raw URLs.
    # All search data goes to .george/search_results.md (current task memory).

    # Write to .george/search_results.md (current task memory)
    # This file is read by the agent inner loop when it needs to
    # reference search results for follow-up web commands.
    local george_dir=".george"
    if [ -d "$george_dir" ]; then
        {
            echo "## Web Search: $query"
            echo "Provider: $provider"
            echo "Time: $(date '+%Y-%m-%d %H:%M')"
            echo ""
            echo "$results_text"
            echo "---"
        } >> "$george_dir/search_results.md"
    fi
}

# ── Detect best text renderer ──────────────────────────────────
_web_renderer() {
    if command -v w3m &>/dev/null; then
        echo "w3m"
    elif command -v lynx &>/dev/null; then
        echo "lynx"
    elif command -v html2text &>/dev/null; then
        echo "html2text"
    else
        echo "sed"  # fallback: strip HTML with sed
    fi
}

# ── Content-type classification ─────────────────────────────────
# Classify a raw Content-Type header value (e.g. "text/html; charset=utf-8")
# into a category: html, pdf, text, json, xml, binary, or empty string
# if unrecognized.  Pure string logic — no network call.
_web_classify_content_type() {
    local ct="$1"
    ct=$(echo "$ct" | cut -d';' -f1 | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    [ -z "$ct" ] && return 0
    case "$ct" in
        application/pdf)                echo "pdf" ;;
        text/plain|text/csv|text/markdown|text/tab-separated-values) echo "text" ;;
        application/json|text/json)     echo "json" ;;
        application/xml|text/xml|application/rss+xml|application/atom+xml) echo "xml" ;;
        text/html*|application/xhtml+xml) echo "html" ;;
        application/octet-stream)       ;; # ambiguous — caller falls through
        image/*|audio/*|video/*)        echo "binary" ;;
    esac
}

# Guess content type from URL extension alone — no network call.
_web_guess_content_type() {
    local url="$1"
    local path
    path=$(echo "$url" | sed 's/[?#].*//' | tr '[:upper:]' '[:lower:]')
    case "$path" in
        *.pdf)                      echo "pdf" ;;
        *.txt|*.log|*.cfg|*.ini)    echo "text" ;;
        *.csv|*.tsv)                echo "text" ;;
        *.md|*.markdown|*.rst)      echo "text" ;;
        *.json|*.jsonl|*.geojson)   echo "json" ;;
        *.xml|*.rss|*.atom|*.svg)   echo "xml" ;;
        *.jpg|*.jpeg|*.png|*.gif|*.webp|*.bmp|*.ico) echo "binary" ;;
        *.mp3|*.mp4|*.wav|*.avi|*.mov) echo "binary" ;;
        *.zip|*.tar|*.gz|*.bz2|*.7z|*.rar) echo "binary" ;;
        *.doc|*.docx|*.ppt|*.pptx|*.xls|*.xlsx) echo "binary" ;;
        *)                          echo "html" ;;
    esac
}

# Legacy wrapper — now uses URL-extension guess only (no HEAD request).
# Kept for backward compatibility with tests and any external callers.
_web_detect_content_type() {
    _web_guess_content_type "$1"
}

# ── Download to temp file ─────────────────────────────────────
# For binary formats (PDF) that need file-based processing.
# Prints the temp file path. Caller must rm -f when done.
_web_fetch_to_file() {
    local url="$1"
    local max_size="${2:-$WEB_MAX_SIZE_PDF}"
    local _tmpdir="${TMPDIR:-/tmp}"
    local tmpfile="$_tmpdir/.lodge-web-dl-$$.tmp"

    if ! _web_curl \
        --max-time "$((WEB_TIMEOUT * 3))" \
        --max-filesize "$max_size" \
        -o "$tmpfile" \
        "$url" 2>/dev/null; then
        rm -f "$tmpfile"
        return 1
    fi

    if [ ! -s "$tmpfile" ]; then
        rm -f "$tmpfile"
        return 1
    fi

    echo "$tmpfile"
}

# ── PDF text extraction ───────────────────────────────────────
# Requires pdftotext (poppler-utils). Falls back to strings(1).
# Input: URL or file path. Output: plain text to stdout.
_web_extract_pdf() {
    local source="$1"
    local tmpfile=""
    local pdf_path

    if [[ "$source" == http* ]]; then
        tmpfile=$(_web_fetch_to_file "$source")
        if [ -z "$tmpfile" ]; then
            return 1
        fi
        pdf_path="$tmpfile"
    else
        pdf_path="$source"
    fi

    local text=""
    if command -v pdftotext &>/dev/null; then
        # pdftotext -layout preserves formatting; -q suppresses warnings
        text=$(pdftotext -layout -q "$pdf_path" - 2>/dev/null | head -2000)
    fi

    # Last resort: strings(1) — crude but extracts readable ASCII
    if [ -z "$text" ] && command -v strings &>/dev/null; then
        text=$(strings "$pdf_path" 2>/dev/null | \
            grep -E '[a-zA-Z]{3,}' | \
            head -1000)
    fi

    [ -n "$tmpfile" ] && rm -f "$tmpfile"

    if [ -z "$text" ]; then
        return 1
    fi
    echo "$text"
}

# ── Plain text / structured text fetch ─────────────────────────
# For text/plain, CSV, Markdown, etc. — just return raw content.
_web_fetch_text() {
    local url="$1"
    _web_curl \
        --max-time "$WEB_TIMEOUT" \
        --max-filesize "$WEB_MAX_SIZE" \
        "$url" 2>/dev/null | head -2000
}

# ── JSON fetch ─────────────────────────────────────────────────
# Returns prettified JSON.
_web_fetch_json_raw() {
    local url="$1"
    _web_curl \
        --max-time "$WEB_TIMEOUT" \
        --max-filesize "$WEB_MAX_SIZE" \
        -H "Accept: application/json" \
        "$url" 2>/dev/null | jq '.' 2>/dev/null | head -2000
}

# ── XML/RSS to text ────────────────────────────────────────────
# Strips XML tags and decodes entities for readable text.
_web_extract_xml() {
    local url="$1"
    _web_curl \
        --max-time "$WEB_TIMEOUT" \
        --max-filesize "$WEB_MAX_SIZE" \
        "$url" 2>/dev/null | \
        sed -e 's/<[^>]*>//g' \
            -e 's/&amp;/\&/g' \
            -e 's/&lt;/</g' \
            -e 's/&gt;/>/g' \
            -e 's/&quot;/"/g' \
            -e "s/&#39;/'/g" \
            -e '/^[[:space:]]*$/d' | \
        awk '{$1=$1}1' | \
        head -2000
}

# ── Fetch raw HTML ─────────────────────────────────────────────
# Returns raw HTML/content on success, empty string on failure.
# Writes the HTTP status / error code to _WEB_STATUS_FILE and the
# response Content-Type to _WEB_CTYPE_FILE so callers can route
# based on the actual server-reported type (no separate HEAD needed).
_WEB_STATUS_FILE="${TMPDIR:-/tmp}/.lodge-web-status-$$.tmp"
_WEB_CTYPE_FILE="${TMPDIR:-/tmp}/.lodge-web-ctype-$$.tmp"
web_fetch_raw() {
    local url="$1"
    local _tmpdir="${TMPDIR:-/tmp}"
    local _hdr_file="$_tmpdir/.lodge-web-hdr-$$.tmp"

    local html
    html=$(_web_curl \
        --max-time "$WEB_TIMEOUT" \
        --max-filesize "$WEB_MAX_SIZE" \
        -D "$_hdr_file" \
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
        "$url" 2>/dev/null | head -c "$WEB_MAX_SIZE")
    local _curl_rc=$?

    # Extract HTTP status code and Content-Type from response headers.
    # Both are written to shared temp files so callers outside subshells
    # can read them (the GET body arrives via stdout / subshell capture).
    local _status="" _content_type=""
    if [ -f "$_hdr_file" ]; then
        _status=$(sed -n 's/.*HTTP\/[0-9.]* \([0-9]\{3\}\).*/\1/p' "$_hdr_file" 2>/dev/null | tail -1)
        _content_type=$(grep -i '^content-type:' "$_hdr_file" 2>/dev/null | tail -1 | sed 's/^[Cc]ontent-[Tt]ype:[[:space:]]*//' | tr -d '\r')
        rm -f "$_hdr_file"
    fi

    # ── Retry once on total network failure ──────────────────
    # If curl returned nothing (no HTML, no headers), it's likely a
    # transient DNS/timeout/connection error.  Retry once after 1s.
    if [ -z "$html" ] && [ -z "$_status" ]; then
        sleep 1
        html=$(_web_curl \
            --max-time "$WEB_TIMEOUT" \
            --max-filesize "$WEB_MAX_SIZE" \
            -D "$_hdr_file" \
            -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
            "$url" 2>/dev/null | head -c "$WEB_MAX_SIZE")
        _curl_rc=$?
        if [ -f "$_hdr_file" ]; then
            _status=$(sed -n 's/.*HTTP\/[0-9.]* \([0-9]\{3\}\).*/\1/p' "$_hdr_file" 2>/dev/null | tail -1)
            _content_type=$(grep -i '^content-type:' "$_hdr_file" 2>/dev/null | tail -1 | sed 's/^[Cc]ontent-[Tt]ype:[[:space:]]*//' | tr -d '\r')
            rm -f "$_hdr_file"
        fi
    fi

    # curl exit code meanings for better diagnostics
    if [ "$_curl_rc" -ne 0 ] && [ -z "$html" ]; then
        case "$_curl_rc" in
            6)  _status="DNS_FAIL" ;;
            7)  _status="CONN_REFUSED" ;;
            28) _status="TIMEOUT" ;;
            35) _status="SSL_ERROR" ;;
            56) _status="RECV_ERROR" ;;
            63) _status="MAX_SIZE" ;;
            *)  _status="CURL_ERR_$_curl_rc" ;;
        esac
        echo "$_status" > "$_WEB_STATUS_FILE" 2>/dev/null
        return 1
    fi

    # Treat explicit HTTP errors as failures (curl -L still returns HTML body).
    if [[ "$_status" =~ ^[0-9]+$ ]] && [ "$_status" -ge 400 ]; then
        local _reason
        _reason=$(_web_block_reason "$_status" "$html")
        if [ -n "$_reason" ]; then
            _web_blacklist_add "$url" "$_reason" "$_status"
            echo "BLOCKED:${_reason}:${_status}" > "$_WEB_STATUS_FILE" 2>/dev/null
        else
            echo "$_status" > "$_WEB_STATUS_FILE" 2>/dev/null
        fi
        return 1
    fi

    # Some anti-bot pages return HTTP 200 with challenge HTML.
    local _html_reason
    _html_reason=$(_web_block_reason "${_status:-200}" "$html")
    if [ -n "$_html_reason" ]; then
        _web_blacklist_add "$url" "$_html_reason" "${_status:-200}"
        echo "BLOCKED:${_html_reason}:${_status:-200}" > "$_WEB_STATUS_FILE" 2>/dev/null
        return 1
    fi

    echo "${_status:-200}" > "$_WEB_STATUS_FILE" 2>/dev/null
    echo "$_content_type" > "$_WEB_CTYPE_FILE" 2>/dev/null
    echo "$html"
}

# ── HTML preprocessor ──────────────────────────────────────────
# Modern sites pack 100KB+ of JavaScript and CSS onto single lines.
# Greedy sed regexes (s/<script.*<\/script>//) backtrack for minutes
# on lines that long. This preprocessor:
#   1. Splits HTML at every > to create short lines (~50-200 chars)
#   2. Uses an awk state machine to skip script/style/noscript blocks
#      (no greedy regex — O(n) on any line length)
#   3. Strips remaining HTML tags and decodes common entities
# Result: clean text lines, ready for head -N truncation.
# Benchmarks: 350KB NYT → 7ms, 2.5MB Wired → 22ms.
_html_preprocess() {
    sed 's/>/>\n/g' | awk '
    BEGIN { skip = 0 }
    /<script/  { skip = 1 }
    /<\/script>/  { skip = 0; next }
    /<style/   { skip = 1 }
    /<\/style>/   { skip = 0; next }
    /<noscript/ { skip = 1 }
    /<\/noscript>/ { skip = 0; next }
    /<header[^a-z]/ { skip = 1 }
    /<\/header>/    { skip = 0; next }
    /<aside/    { skip = 1 }
    /<\/aside>/    { skip = 0; next }
    skip { next }
    {
        gsub(/<[^>]*>/, "")
        gsub(/&nbsp;/, " ")
        gsub(/&amp;/, "\\&")
        gsub(/&lt;/, "<")
        gsub(/&gt;/, ">")
        gsub(/&quot;/, "\"")
        gsub(/&#39;/, "\x27")
        gsub(/&#[0-9]+;/, "")
        gsub(/^[[:space:]]+/, "")
        gsub(/[[:space:]]+$/, "")
        if (length($0) > 0) print
    }'
}

# ── Strip HTML to plain text ──────────────────────────────────
_html_to_text_sed() {
    # awk state-machine preprocessor — safe on any line length.
    # Replaces the old greedy-sed approach that hung on modern
    # SPA pages (NYT 350KB, Wired 2.5MB single-line blobs).
    _html_preprocess | head -500
}

_html_to_text() {
    local renderer
    renderer=$(_web_renderer)

    case "$renderer" in
        w3m)
            w3m -dump -T text/html -cols 100 2>/dev/null | head -500 ;;
        lynx)
            lynx -dump -stdin -width=100 -nolist 2>/dev/null | head -500 ;;
        html2text)
            html2text -utf8 2>/dev/null | head -500 ;;
        sed)
            _html_to_text_sed ;;
    esac
}

# ── Extract page title from HTML ──────────────────────────────
_html_extract_title() {
    sed -n 's/.*<title>\([^<]*\)<\/title>.*/\1/p' | head -1 | \
        sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#39;/'"'"'/g'
}

# ── Extract structured content from HTML ───────────────────────
# Uses semantic HTML priority: prefer <article> or <main> content,
# then fall back to full-page extraction with junk blocks stripped.
# Strips script/style/nav/header/footer/aside before extracting,
# then decodes entities and emits clean text lines.
_html_extract_content() {
    local _raw
    _raw=$(sed 's/>/>\n/g')

    # Priority: narrow scope to <article> or <main> if present.
    # These semantic containers hold the actual content on modern sites
    # and dramatically improve signal-to-noise ratio.
    local _focused
    _focused=$(printf '%s\n' "$_raw" | awk '
        tolower($0) ~ /<article/ { inside = 1 }
        inside { print }
        tolower($0) ~ /<\/article>/ { inside = 0 }
    ')
    if [ -z "$_focused" ] || [ "$(printf '%s' "$_focused" | wc -c)" -lt 200 ]; then
        _focused=$(printf '%s\n' "$_raw" | awk '
            tolower($0) ~ /<main/ { inside = 1 }
            inside { print }
            tolower($0) ~ /<\/main>/ { inside = 0 }
        ')
    fi
    if [ -n "$_focused" ] && [ "$(printf '%s' "$_focused" | wc -c)" -ge 200 ]; then
        _raw="$_focused"
    fi

    printf '%s\n' "$_raw" | awk '
    BEGIN { skip = 0 }
    /<script/      { skip = 1 }
    /<\/script>/   { skip = 0; next }
    /<style/       { skip = 1 }
    /<\/style>/    { skip = 0; next }
    /<noscript/    { skip = 1 }
    /<\/noscript>/ { skip = 0; next }
    /<nav/         { skip = 1 }
    /<\/nav>/      { skip = 0; next }
    /<header[^a-z]/ { skip = 1 }
    /<\/header>/   { skip = 0; next }
    /<footer/      { skip = 1 }
    /<\/footer>/   { skip = 0; next }
    /<aside/       { skip = 1 }
    /<\/aside>/    { skip = 0; next }
    skip { next }
    {
        gsub(/<[^>]*>/, "")
        gsub(/&nbsp;/, " ")
        gsub(/&amp;/, "\\&")
        gsub(/&lt;/, "<")
        gsub(/&gt;/, ">")
        gsub(/&quot;/, "\"")
        gsub(/&#39;/, "\x27")
        gsub(/&mdash;/, "\xe2\x80\x94")
        gsub(/&ndash;/, "\xe2\x80\x93")
        gsub(/&hellip;/, "...")
        gsub(/&apos;/, "\x27")
        gsub(/&#[0-9]+;/, "")
        gsub(/^[[:space:]]+/, "")
        gsub(/[[:space:]]+$/, "")
        if (length($0) > 2) print
    }' | head -300
}

# ── Extract image URLs from HTML (content areas only) ──────────
_html_extract_images() {
    local base_url="$1"
    # Accepted image types — kept as a variable so tests can verify coverage.
    local _img_exts='jpg|jpeg|png|gif|webp|bmp|svg|avif|tiff'
    # Pull image URLs from:
    #  1) <img src|data-src|data-lazy-src|srcset=...>
    #  2) <picture><source srcset=...> (modern responsive images)
    #  3) <meta property="og:image" content="..."> and twitter:image
    #  4) <link rel="image_src" href="...">
    {
        # <img> tags — src, data-src, data-lazy-src attributes
        grep -oiE '<img[^>]*>' | grep -oE '(src|data-src|data-lazy-src)="[^"]+"' | sed 's/^[^"]*"//;s/"$//'
        # <img> srcset — extract individual URLs from comma-separated entries
        grep -oiE '<img[^>]*>' | grep -oE 'srcset="[^"]+"' | sed 's/^srcset="//;s/"$//' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/ [0-9]*[wx].*$//'
        # <picture><source> srcset — responsive image sources
        grep -oiE '<source[^>]*>' | grep -oE 'srcset="[^"]+"' | sed 's/^srcset="//;s/"$//' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/ [0-9]*[wx].*$//'
        # Open Graph and Twitter Card meta images
        grep -oiE '<meta[^>]+(og:image|twitter:image)[^>]*>' | grep -oE 'content="[^"]+"' | sed 's/^content="//;s/"$//'
        # <link rel="image_src">
        grep -oiE '<link[^>]+rel="image_src"[^>]*>' | grep -oE 'href="[^"]+"' | sed 's/^href="//;s/"$//'
    } | sort -u | \
    while IFS= read -r img_url; do
        [ -z "$img_url" ] && continue
        [[ "$img_url" == data:* ]] && continue
        [[ "$img_url" == javascript:* ]] && continue
        # Resolve relative URLs
        if [[ "$img_url" == //* ]]; then
            img_url="https:$img_url"
        elif [[ "$img_url" == /* ]]; then
            img_url="${base_url}${img_url}"
        elif [[ "$img_url" != http* ]]; then
            continue  # skip truly relative paths for safety
        fi

        # Keep image-like URLs; reject obvious non-image static assets.
        if [[ "$img_url" =~ \.(css|js|map|woff2?|ttf|eot|json|xml)(\?|$) ]]; then
            continue
        fi

        # Prefer known image extensions (${_preferred_img_exts}),
        # but allow extensionless URLs from image tags/meta cards.
        local safe_url
        safe_url=$(_web_sanitize_url "$img_url")
        [ -n "$safe_url" ] && echo "$safe_url"
    done | head -20
}

# ── Fetch a URL and return clean text ─────────────────────────
web_fetch() {
    local url="$1"

    if _web_blacklist_contains "$url"; then
        local _bl_reason
        _bl_reason=$(_web_blacklist_reason "$url")
        ui_err "URL is blacklisted from prior block/challenge: $url (reason: ${_bl_reason:-unknown})" >&2
        return 1
    fi

    # Check cache first
    local cache_key
    cache_key=$(printf '%s' "$url" | md5sum 2>/dev/null | cut -d' ' -f1 || printf '%s' "$url" | cksum | cut -d' ' -f1)
    local cache_file="$GEORGE_CACHE_DIR/web_${cache_key}"

    if [ -f "$cache_file" ]; then
        local age
        age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
        if [ "$age" -lt "$WEB_CACHE_TTL" ]; then
            cat "$cache_file"
            return 0
        fi
    fi

    # ── Pre-screen by URL extension for formats needing special fetch ──
    # PDF/binary need file-based download, not streaming through web_fetch_raw.
    local _url_guess
    _url_guess=$(_web_guess_content_type "$url")
    case "$_url_guess" in
        pdf)
            ui_dim "Fetching PDF: $url" >&2
            local pdf_text
            pdf_text=$(_web_extract_pdf "$url")
            if [ -z "$pdf_text" ]; then
                ui_err "Failed to extract PDF: $url" >&2
                ui_dim "  Hint: install poppler-utils for best results (apt install poppler-utils)" >&2
                return 1
            fi
            mkdir -p "$GEORGE_CACHE_DIR"
            echo "$pdf_text" > "$cache_file" 2>/dev/null
            echo "$pdf_text"
            return 0
            ;;
        binary)
            ui_err "Cannot extract text from binary file: $url" >&2
            return 1
            ;;
    esac

    # ── Single GET — then route by server Content-Type ──────────
    # One request for everything: HTML, text, JSON, XML.  The old
    # approach did HEAD (content-type detection) then GET (fetch) —
    # two requests per page, doubling rate-limit/captcha exposure.
    ui_dim "Fetching: $url" >&2
    local body
    body=$(web_fetch_raw "$url")
    if [ -z "$body" ]; then
        local _reason="unknown"
        [ -f "$_WEB_STATUS_FILE" ] && _reason=$(cat "$_WEB_STATUS_FILE" 2>/dev/null)
        case "$_reason" in
            BLOCKED:*)
                local _b_reason _b_code
                _b_reason=$(echo "$_reason" | cut -d':' -f2)
                _b_code=$(echo "$_reason" | cut -d':' -f3)
                ui_err "Blocked by target site: $url (reason: ${_b_reason:-unknown}, status: ${_b_code:-unknown})" >&2
                ;;
            DNS_FAIL)     ui_err "Failed to fetch: $url (DNS resolution failed — site may not exist)" >&2 ;;
            CONN_REFUSED) ui_err "Failed to fetch: $url (connection refused)" >&2 ;;
            TIMEOUT)      ui_err "Failed to fetch: $url (request timed out after ${WEB_TIMEOUT}s)" >&2 ;;
            SSL_ERROR)    ui_err "Failed to fetch: $url (SSL/TLS error)" >&2 ;;
            4[0-9][0-9])  ui_err "Failed to fetch: $url (HTTP $_reason)" >&2 ;;
            5[0-9][0-9])  ui_err "Failed to fetch: $url (server error HTTP $_reason)" >&2 ;;
            *)            ui_err "Failed to fetch: $url (status: $_reason)" >&2 ;;
        esac
        return 1
    fi

    # Classify by server Content-Type header, fallback to URL extension
    local ctype=""
    [ -f "$_WEB_CTYPE_FILE" ] && ctype=$(_web_classify_content_type "$(cat "$_WEB_CTYPE_FILE" 2>/dev/null)")
    [ -z "$ctype" ] && ctype="$_url_guess"

    local text=""
    case "$ctype" in
        text)   text=$(echo "$body" | head -2000) ;;
        json)   text=$(echo "$body" | jq '.' 2>/dev/null | head -2000) ;;
        xml)    text=$(echo "$body" | sed -e 's/<[^>]*>//g' \
                    -e 's/&amp;/\&/g' -e 's/&lt;/</g' -e 's/&gt;/>/g' \
                    -e 's/&quot;/"/g' -e "s/&#39;/'/g" -e '/^[[:space:]]*$/d' | \
                    awk '{$1=$1}1' | head -2000) ;;
        *)      text=$(echo "$body" | _html_to_text) ;;
    esac

    # Cache result
    mkdir -p "$GEORGE_CACHE_DIR"
    echo "$text" > "$cache_file" 2>/dev/null

    echo "$text"
}

# ── Fetch a URL and return structured JSON ─────────────────────
# Returns: {"url":"...","title":"...","content":"...","images":[...]}
# Uses tag-based extraction for better structured output than
# plain-text dumping. Falls back to _html_to_text for content
# if semantic extraction yields nothing.
web_fetch_json() {
    local url="$1"
    local clean_url
    clean_url=$(_web_sanitize_url "$url")
        if _web_blacklist_contains "$clean_url"; then
            local _bl_reason
            _bl_reason=$(_web_blacklist_reason "$clean_url")
            jq -n \
                --arg url "$clean_url" \
                --arg title "" \
                --arg content "" \
                --arg reason "BLACKLISTED_${_bl_reason:-unknown}" \
                --arg status "blacklist" \
                '{"url":$url,"title":$title,"content":$content,"images":[],"blocked":true,"block_reason":$reason,"http_status":$status}'
            return 0
        fi

    if [ -z "$clean_url" ]; then
        ui_err "Invalid URL: $url"
        return 1
    fi

    # ── Pre-screen by URL extension for formats needing special fetch ──
    local _url_guess
    _url_guess=$(_web_guess_content_type "$clean_url")
    case "$_url_guess" in
        pdf)
            ui_dim "Fetching PDF (structured): $clean_url" >&2
            local pdf_text
            pdf_text=$(_web_extract_pdf "$clean_url")
            if [ -z "$pdf_text" ]; then
                ui_err "Failed to extract PDF: $clean_url" >&2
                ui_dim "  Hint: install poppler-utils for best results (apt install poppler-utils)" >&2
                return 1
            fi
            local pdf_title
            pdf_title=$(echo "$pdf_text" | head -5 | grep -m1 -E '.{5,}' | head -c 120)
            [ -z "$pdf_title" ] && pdf_title="PDF Document"
            jq -n \
                --arg url "$clean_url" \
                --arg title "$pdf_title" \
                --arg content "$pdf_text" \
                '{"url":$url,"title":$title,"content":$content,"images":[]}'
            return 0
            ;;
        binary)
            ui_err "Cannot extract text from binary file: $clean_url" >&2
            return 1
            ;;
    esac

    # ── Single GET — then route by server Content-Type ──────────
    ui_dim "Fetching (structured): $clean_url" >&2
    local body
    body=$(web_fetch_raw "$clean_url")
    if [ -z "$body" ]; then
        local _reason="unknown"
        [ -f "$_WEB_STATUS_FILE" ] && _reason=$(cat "$_WEB_STATUS_FILE" 2>/dev/null)
        case "$_reason" in
            BLOCKED:*)
                local _b_reason _b_code
                _b_reason=$(echo "$_reason" | cut -d':' -f2)
                _b_code=$(echo "$_reason" | cut -d':' -f3)
                jq -n \
                    --arg url "$clean_url" \
                    --arg title "" \
                    --arg content "" \
                    --arg reason "${_b_reason:-unknown}" \
                    --arg status "${_b_code:-unknown}" \
                    '{"url":$url,"title":$title,"content":$content,"images":[],"blocked":true,"block_reason":$reason,"http_status":$status}'
                return 0
                ;;
            DNS_FAIL)     ui_err "Failed to fetch: $clean_url (DNS resolution failed — site may not exist)" >&2 ;;
            CONN_REFUSED) ui_err "Failed to fetch: $clean_url (connection refused)" >&2 ;;
            TIMEOUT)      ui_err "Failed to fetch: $clean_url (request timed out after ${WEB_TIMEOUT}s)" >&2 ;;
            SSL_ERROR)    ui_err "Failed to fetch: $clean_url (SSL/TLS error)" >&2 ;;
            4[0-9][0-9])  ui_err "Failed to fetch: $clean_url (HTTP $_reason)" >&2 ;;
            5[0-9][0-9])  ui_err "Failed to fetch: $clean_url (server error HTTP $_reason)" >&2 ;;
            *)            ui_err "Failed to fetch: $clean_url (status: $_reason)" >&2 ;;
        esac
        return 1
    fi

    # Classify by server Content-Type header, fallback to URL extension
    local ctype=""
    [ -f "$_WEB_CTYPE_FILE" ] && ctype=$(_web_classify_content_type "$(cat "$_WEB_CTYPE_FILE" 2>/dev/null)")
    [ -z "$ctype" ] && ctype="$_url_guess"

    case "$ctype" in
        text)
            jq -n \
                --arg url "$clean_url" \
                --arg title "" \
                --arg content "$(echo "$body" | head -2000)" \
                '{"url":$url,"title":$title,"content":$content,"images":[]}'
            return 0
            ;;
        json)
            local _pretty
            _pretty=$(echo "$body" | jq '.' 2>/dev/null | head -2000)
            jq -n \
                --arg url "$clean_url" \
                --arg title "JSON Data" \
                --arg content "${_pretty:-$body}" \
                '{"url":$url,"title":$title,"content":$content,"images":[]}'
            return 0
            ;;
        xml)
            local _xml_text
            _xml_text=$(echo "$body" | sed -e 's/<[^>]*>//g' \
                -e 's/&amp;/\&/g' -e 's/&lt;/</g' -e 's/&gt;/>/g' \
                -e 's/&quot;/"/g' -e "s/&#39;/'/g" -e '/^[[:space:]]*$/d' | \
                awk '{$1=$1}1' | head -2000)
            jq -n \
                --arg url "$clean_url" \
                --arg title "XML/RSS Feed" \
                --arg content "$_xml_text" \
                '{"url":$url,"title":$title,"content":$content,"images":[]}'
            return 0
            ;;
    esac

    # Default: treat as HTML
    local base_url
    base_url=$(echo "$clean_url" | sed 's|^\(https\?://[^/]*\).*|\1|')

    local title
    title=$(echo "$body" | _html_extract_title)
    [ -z "$title" ] && title=""

    local content
    content=$(echo "$body" | _html_extract_content)
    if [ -z "$content" ] || [ "${#content}" -lt 80 ]; then
        local fallback
        fallback=$(echo "$body" | _html_to_text)
        if [ "${#fallback}" -gt "${#content}" ]; then
            content="$fallback"
        fi
    fi

    local images_json="[]"
    local img_lines
    img_lines=$(echo "$body" | _html_extract_images "$base_url")
    if [ -n "$img_lines" ]; then
        images_json=$(echo "$img_lines" | jq -R '.' | jq -s '.')
    fi

    jq -n \
        --arg url "$clean_url" \
        --arg title "$title" \
        --arg content "$content" \
        --argjson images "$images_json" \
        '{"url":$url,"title":$title,"content":$content,"images":$images}'
}

# ── Extract just the title from a page ────────────────────────
web_title() {
    local url="$1"
    local html
    html=$(web_fetch_raw "$url")
    echo "$html" | _html_extract_title
}

# ── Extract all links from a page ─────────────────────────────
web_links() {
    local url="$1"
    local html
    html=$(web_fetch_raw "$url")
    echo "$html" | grep -oE 'href="[^"]*"' | sed 's/href="//;s/"$//' | \
        grep -E '^https?://' | sort -u | head -50
}

# ── Extract image URLs from a page (JSON) ──────────────────────
# Scrapes page content AND images into structured JSON format.
# Returns: {"url":"...","title":"...","content":"...","images":[...]}
#
# This replaces the old web_scrape_images which returned only a
# numbered list of image URLs. The new format gives the agent
# structured context: page title, body text, and image URLs.
#
# Usage: web_scrape_images "https://en.wikipedia.org/wiki/Grand_Lodge"
# Output: JSON object with url, title, content, images keys
web_scrape_images() {
    local url="$1"

    if [ -z "$url" ]; then
        ui_err "Usage: web_scrape_images <url>"
        return 1
    fi

    # Validate URL
    local clean_url
    clean_url=$(_web_sanitize_url "$url")
    if [ -z "$clean_url" ]; then
        ui_err "Invalid URL: $url"
        return 1
    fi

    # Delegate to the JSON fetcher for structured output
    local json_result
    json_result=$(web_fetch_json "$clean_url")
    if [ -z "$json_result" ]; then
        return 1
    fi

    # Guard: ensure stdout from web_fetch_json is parseable JSON.
    if ! echo "$json_result" | jq -e '.' >/dev/null 2>&1; then
        ui_err "web_scrape_images produced invalid JSON for: $clean_url"
        return 1
    fi

    # Display human-readable summary to stderr (keep stdout clean for agent)
    local title img_count content_lines is_blocked block_reason http_status
    title=$(echo "$json_result" | jq -r '.title // "Untitled"' 2>/dev/null)
    img_count=$(echo "$json_result" | jq -r '.images | length' 2>/dev/null)
    is_blocked=$(echo "$json_result" | jq -r '.blocked // false' 2>/dev/null)
    block_reason=$(echo "$json_result" | jq -r '.block_reason // ""' 2>/dev/null)
    http_status=$(echo "$json_result" | jq -r '.http_status // ""' 2>/dev/null)

    if [ "$is_blocked" = "true" ]; then
        ui_warn "Site blocked scraping (reason: ${block_reason:-unknown}, status: ${http_status:-unknown})" >&2
    fi

    content_lines=$(echo "$json_result" | jq -r '.content // ""' 2>/dev/null | awk 'NF{c++} END{print c+0}')

    # Naive fallback: if scrape returns no content lines, switch to /web fetch
    # style extraction for the same URL and inject that text into JSON.
    if [ "$is_blocked" != "true" ] && [ "${content_lines:-0}" -eq 0 ]; then
        ui_warn "scrape-images returned 0 content lines; falling back to fetch" >&2
        local fetched_text
        fetched_text=$(web_fetch "$clean_url" 2>/dev/null)
        if [ -n "$fetched_text" ]; then
            json_result=$(echo "$json_result" | jq --arg content "$fetched_text" '.content = $content' 2>/dev/null)
            content_lines=$(echo "$json_result" | jq -r '.content // ""' 2>/dev/null | awk 'NF{c++} END{print c+0}')
        fi
    fi

    ui_ok "Scraped: $title" >&2
    ui_dim "  Content: ~${content_lines} lines | Images: ${img_count}" >&2

    # Journal the structured result for agent memory
    local journal_text="Title: $title\nImages: $img_count\nContent excerpt: $(echo "$json_result" | jq -r '.content' 2>/dev/null | head -10)"
    _web_journal_results "scrape $clean_url" "$journal_text" "scrape"

    # Return the full JSON to stdout (captured by agent)
    echo "$json_result"
}

# ── Search the web ────────────────────────────────────────────
# Uses Serper.dev API (Google results) if key is set,
# otherwise falls back to DuckDuckGo HTML scraping.
#
# Sets _WEB_LAST_SEARCH_JSON with structured results for debug
# output and agent consumption.

_WEB_LAST_SEARCH_JSON=""

web_search() {
    local query="$1"
    local count="${2:-5}"

    # Strip surrounding quotes (LLM often wraps queries in shell-style quotes)
    query="${query#\"}"
    query="${query%\"}"
    query="${query#\'}"
    query="${query%\'}"

    # Try Serper first (better results)
    local serper_key
    serper_key=$(api_get_key "SERPER_API_KEY" 2>/dev/null)

    if [ -n "$serper_key" ]; then
        _web_search_serper "$query" "$count" "$serper_key"
        return $?
    fi

    # Try Perplexity as search engine (if configured)
    local pplx_key
    pplx_key=$(api_get_key "PERPLEXITY_API_KEY" 2>/dev/null)

    if [ -n "$pplx_key" ]; then
        _web_search_perplexity "$query" "$pplx_key"
        return $?
    fi

    # Fallback: DuckDuckGo HTML scraping
    _web_search_ddg "$query" "$count"
}

_web_search_serper() {
    local query="$1"
    local count="$2"
    local key="$3"

    local data
    data=$(jq -n --arg q "$query" --argjson n "$count" '{"q": $q, "num": $n}')

    local resp
    resp=$(api_post "https://google.serper.dev/search" "$data" \
        -H "X-API-KEY: $key")

    if [ $? -eq 0 ]; then
        # Serper .organic[] already excludes ads (ads are in .ads[]).
        # Sanitize URLs before output.
        local raw_results
        raw_results=$(echo "$resp" | jq -r '.organic[]? | "\(.position)|\(.link)|\(.title)|\(.snippet)"' 2>/dev/null)

        if [ -z "$raw_results" ]; then
            ui_warn "Serper returned no organic results, falling back to DuckDuckGo"
            _web_search_ddg "$query" "$count"
            return $?
        fi

        local output=""
        local json_results="[]"
        local i=1
        while IFS='|' read -r _pos url title snippet; do
            local clean_url
            clean_url=$(_web_sanitize_url "$url")
            [ -z "$clean_url" ] && continue

            local entry
            entry=$(printf '[%d] %s\n    %s\n    %s\n' "$i" "$title" "$clean_url" "$snippet")
            output="${output}${entry}\n"
            printf '[%d] %s\n    %s\n    %s\n\n' "$i" "$title" "$clean_url" "$snippet"
            json_results=$(echo "$json_results" | jq --arg t "$title" --arg u "$clean_url" --arg s "$snippet" '. + [{"title":$t,"url":$u,"snippet":$s}]')
            i=$((i + 1))
        done <<< "$raw_results"

        _WEB_LAST_SEARCH_JSON=$(jq -n --arg q "$query" --arg p "serper" --argjson r "$json_results" '{"query":$q,"provider":$p,"results":$r}')
        _web_journal_results "$query" "$output" "serper"
    else
        ui_warn "Serper search failed, falling back to DuckDuckGo"
        _web_search_ddg "$query" "$count"
    fi
}

_web_search_perplexity() {
    local query="$1"
    local key="$2"

    local data
    data=$(jq -n --arg q "$query" '{
        "model": "sonar",
        "messages": [{"role": "user", "content": $q}]
    }')

    local resp
    resp=$(api_post "https://api.perplexity.ai/chat/completions" "$data" \
        -H "Authorization: Bearer $key")

    if [ $? -eq 0 ]; then
        api_json_get "$resp" '.choices[0].message.content'
    fi
}

_web_search_ddg() {
    local query="$1"
    local count="$2"

    local encoded
    encoded=$(printf '%s' "$query" | jq -sRr @uri)

    # Use DuckDuckGo Lite — simpler HTML, more reliable parsing
    local html
    html=$(_web_curl \
        --max-time 10 \
        -H "Accept: text/html" \
        "https://lite.duckduckgo.com/lite/?q=$encoded" 2>/dev/null)

    if [ -z "$html" ]; then
        ui_err "DuckDuckGo search failed"
        return 1
    fi

    # DDG Lite returns results in <a class="result-link"> or plain <a> tags
    # inside <td> elements. Extract result links and snippets.
    local results=""
    local n=0

    # Method 1: Parse result-link class (DDG Lite format)
    # Handle both attribute orders: class before href AND href before class
    results=$(echo "$html" | grep -oE '<a[^>]*class="result-link"[^>]*>[^<]*' 2>/dev/null | \
        sed -n 's/.*href="\([^"]*\)".*>\([^<]*\)/\1|\2/p' | head -"$count")

    # Method 2: If no result-link, try result__a (standard DDG HTML)
    if [ -z "$results" ]; then
        results=$(echo "$html" | grep -oE 'class="result__a"[^>]*href="[^"]*"[^>]*>[^<]*' 2>/dev/null | \
            sed 's/.*href="//;s/"[^>]*>/|/' | head -"$count")
    fi

    # Method 3: Extract from DDG Lite table rows (most reliable)
    if [ -z "$results" ]; then
        results=$(echo "$html" | \
            grep -oE '<a[^>]+rel="nofollow"[^>]+href="[^"]+"[^>]*>[^<]+' 2>/dev/null | \
            sed 's/<a[^>]*href="//;s/"[^>]*>/|/' | head -"$count")
    fi

    if [ -n "$results" ]; then
        # Filter ads and sanitize URLs, then output + journal
        local clean_results=""
        local output=""
        local i=1

        while IFS='|' read -r url title; do
            # Decode DDG redirect URLs (uddg= parameter)
            if [[ "$url" == *"uddg="* ]]; then
                url=$(echo "$url" | sed -n 's/.*uddg=\([^&]*\).*/\1/p' | python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))' 2>/dev/null || echo "$url")
            fi

            # Skip ad/tracking URLs
            if _web_is_ad_url "$url"; then
                continue
            fi

            # Sanitize URL
            local clean_url
            clean_url=$(_web_sanitize_url "$url")
            [ -z "$clean_url" ] && continue

            local entry
            entry=$(printf '[%d] %s\n    %s' "$i" "${title:-$clean_url}" "$clean_url")
            output="${output}${entry}\n\n"
            printf '[%d] %s\n    %s\n\n' "$i" "${title:-$clean_url}" "$clean_url"
            i=$((i + 1))
        done <<< "$results"

        # Build JSON and journal
        _WEB_LAST_SEARCH_JSON=$(echo "$output" | awk -F'\n' -v q="$query" '
            BEGIN { printf "{\"query\":\"%s\",\"provider\":\"ddg\",\"results\":[", q }
            /^\[/ { if(NR>1) printf ","; gsub(/^\[[0-9]+\] /,""); title=$0; getline; gsub(/^    /,""); url=$0; printf "{\"title\":\"%s\",\"url\":\"%s\"}", title, url }
            END { print "]}" }
        ' 2>/dev/null || echo '{"query":"'"$query"'","provider":"ddg","results":[]}')
        # Journal the clean results for agent memory
        if [ -n "$output" ]; then
            _web_journal_results "$query" "$output" "ddg"
        fi
        return 0
    fi

    # Final fallback: extract any meaningful text
    local text_results
    text_results=$(echo "$html" | _html_to_text_sed | grep -v '^$' | head -40)
    if [ -n "$text_results" ]; then
        echo "$text_results"
        return 0
    fi

    ui_err "No results found for: $query"
    return 1
}

# ── Search for images ─────────────────────────────────────────
# Returns direct image URLs suitable for /vision or /web download.
# Uses Serper.dev /images endpoint (Google Image Search) if key is
# set. No DDG fallback — DDG image search requires JavaScript.
#
# Usage: web_images "Grand Lodge of England" [count]
# Output:
#   [1] Title of image
#       https://example.com/image.jpg (1200x800)
#       Source: https://example.com/page
web_images() {
    local query="$1"
    local count="${2:-5}"

    # Strip surrounding quotes (LLM often wraps queries in shell-style quotes)
    query="${query#\"}"
    query="${query%\"}"
    query="${query#\'}"
    query="${query%\'}"

    if [ -z "$query" ]; then
        ui_err "Usage: web_images <query> [count]"
        return 1
    fi

    # Try Serper image search
    local serper_key
    serper_key=$(api_get_key "SERPER_API_KEY" 2>/dev/null)

    if [ -n "$serper_key" ]; then
        _web_search_serper_images "$query" "$count" "$serper_key"
        return $?
    fi

    ui_err "Image search requires SERPER_API_KEY. Set with: /secret set SERPER_API_KEY <key>"
    return 1
}

_web_search_serper_images() {
    local query="$1"
    local count="$2"
    local key="$3"

    local data
    data=$(jq -n --arg q "$query" --argjson n "$count" '{"q": $q, "num": $n}')

    local resp
    resp=$(api_post "https://google.serper.dev/images" "$data" \
        -H "X-API-KEY: $key")

    if [ $? -ne 0 ]; then
        ui_err "Serper image search request failed"
        return 1
    fi

    local raw_results
    raw_results=$(echo "$resp" | jq -r '.images[]? | "\(.title)|\(.imageUrl)|\(.imageWidth)x\(.imageHeight)|\(.link)"' 2>/dev/null)

    if [ -z "$raw_results" ]; then
        ui_warn "No image results for: $query"
        return 1
    fi

    local output=""
    local i=1
    while IFS='|' read -r title image_url dimensions source_url; do
        # Sanitize the image URL
        local clean_url
        clean_url=$(_web_sanitize_url "$image_url")
        [ -z "$clean_url" ] && continue

        local entry
        entry=$(printf '[%d] %s\n    %s (%s)\n    Source: %s\n' "$i" "$title" "$clean_url" "$dimensions" "$source_url")
        output="${output}${entry}\n"
        printf '[%d] %s\n    %s (%s)\n    Source: %s\n\n' "$i" "$title" "$clean_url" "$dimensions" "$source_url"
        i=$((i + 1))
    done <<< "$raw_results"

    # Journal the image results for agent memory
    _web_journal_results "$query" "$output" "serper-images"
}

# ── Summarize a web page via local LLM ────────────────────────
web_summary() {
    local url="$1"

    local text
    text=$(web_fetch "$url")
    if [ -z "$text" ]; then
        return 1
    fi

    # Truncate to fit in context
    local truncated
    truncated=$(echo "$text" | head -200)

    source "$LODGE_DIR/lib/llm.sh"

    local prompt="Summarize this web page in 3-5 bullet points. Be concise and factual.

URL: $url

Content:
$truncated"

    ui_spinner_start "Summarizing"
    local result
    local LLM_SCENARIO=tool
    result=$(llm_generate "$prompt" "You are George, summarizing web content for your user." 256 "$LLM_BUDGET_TOOL")
    ui_spinner_stop
    echo "$result"
}

# ── Read a specific page section (by heading) ─────────────────
web_section() {
    local url="$1"
    local heading="$2"

    local text
    text=$(web_fetch "$url")
    if [ -z "$text" ]; then
        return 1
    fi

    # Extract section under a heading
    echo "$text" | awk -v h="$heading" '
        tolower($0) ~ tolower(h) { found=1; print; next }
        found && /^[A-Z]/ && !/^[[:space:]]/ { found=0 }
        found { print }
    ' | head -100
}

# ── Download a file ───────────────────────────────────────────
web_download() {
    local url="$1"
    local output="${2:-$(basename "$url")}"

    ui_step "Downloading: $url"
    curl -sL --max-time 60 \
        -H "User-Agent: $API_USER_AGENT" \
        -o "$output" \
        "$url" 2>/dev/null

    if [ $? -eq 0 ] && [ -f "$output" ]; then
        local size
        size=$(du -h "$output" | cut -f1)
        ui_ok "Downloaded: $output ($size)"
    else
        ui_err "Download failed"
        return 1
    fi
}

# ── Check if a URL is reachable ───────────────────────────────
web_ping() {
    local url="$1"
    local start end elapsed
    start=$(date +%s%N 2>/dev/null || date +%s)

    local status
    status=$(curl -sI --max-time 5 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)

    end=$(date +%s%N 2>/dev/null || date +%s)

    if [ ${#start} -gt 10 ]; then
        elapsed=$(( (end - start) / 1000000 ))
        printf "  %s → %s (%dms)\n" "$url" "$status" "$elapsed"
    else
        printf "  %s → %s\n" "$url" "$status"
    fi
}

# ── GitHub Repository Search ───────────────────────────────────
# Uses the GitHub REST API (no auth required for public repos) to
# find real, verified repositories. Returns owner/name, description,
# stars, and language. This prevents George from hallucinating repo URLs.
#
# Usage: web_search_github "TI-84 calculator rust" 5
web_search_github() {
    local query="$1"
    local count="${2:-5}"

    if [ -z "$query" ]; then
        ui_err "Usage: web_search_github <query> [count]"
        return 1
    fi

    local encoded
    encoded=$(printf '%s' "$query" | jq -sRr @uri)

    local resp
    resp=$(curl -sL \
        --max-time "$WEB_TIMEOUT" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "User-Agent: Blue-Lodge-George/0.1" \
        "https://api.github.com/search/repositories?q=${encoded}&sort=stars&order=desc&per_page=${count}" 2>/dev/null)

    if [ -z "$resp" ]; then
        ui_err "GitHub API request failed"
        return 1
    fi

    # Check for API errors
    local msg
    msg=$(echo "$resp" | jq -r '.message // empty' 2>/dev/null)
    if [ -n "$msg" ]; then
        ui_err "GitHub API: $msg"
        return 1
    fi

    local total
    total=$(echo "$resp" | jq -r '.total_count // 0' 2>/dev/null)
    if [ "$total" -eq 0 ] 2>/dev/null; then
        ui_dim "No repositories found for: $query"
        return 0
    fi

    # Format results: [n] owner/repo ★stars (language)
    #     description
    #     https://github.com/owner/repo
    local gh_output
    gh_output=$(echo "$resp" | jq -r '.items[]? | "[\(.full_name)] ★\(.stargazers_count) (\(.language // "unknown"))\n    \(.description // "No description")\n    https://github.com/\(.full_name)\n"' 2>/dev/null)
    echo "$gh_output"

    # Journal GitHub results for agent memory
    _web_journal_results "$query" "$gh_output" "github"
}

# ── Verify a GitHub repo exists ────────────────────────────────
# Quick HEAD check against the GitHub API. Returns 0 if the repo
# exists and is accessible, 1 otherwise. No auth needed for public repos.
#
# Usage: web_github_repo_exists "owner/repo"
web_github_repo_exists() {
    local repo="$1"

    # Strip .git suffix and https://github.com/ prefix if present
    repo="${repo%.git}"
    repo="${repo#https://github.com/}"
    repo="${repo#http://github.com/}"

    if [[ ! "$repo" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]]; then
        return 1
    fi

    local status
    status=$(curl -sI --max-time 5 \
        -o /dev/null -w "%{http_code}" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "User-Agent: Blue-Lodge-George/0.1" \
        "https://api.github.com/repos/$repo" 2>/dev/null)

    [ "$status" = "200" ]
}

# ── Clear web cache ───────────────────────────────────────────
web_cache_clear() {
    if [ -d "$GEORGE_CACHE_DIR" ]; then
        rm -f "$GEORGE_CACHE_DIR"/web_* 2>/dev/null
        ui_ok "Web cache cleared"
    fi
}
