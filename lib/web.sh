#!/bin/bash
# ── George: Web Browsing Engine ────────────────────────────────
# Fetch, parse, search, and summarize web content using only
# curl + sed/awk (with optional w3m/lynx for better rendering).
# George can now read the web and act on what he finds.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/api.sh"

# ── Config ─────────────────────────────────────────────────────
WEB_TIMEOUT="${WEB_TIMEOUT:-15}"
WEB_MAX_SIZE="${WEB_MAX_SIZE:-500000}"  # 500KB max download
WEB_CACHE_TTL="${WEB_CACHE_TTL:-3600}" # Cache pages for 1 hour

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

# ── Fetch raw HTML ─────────────────────────────────────────────
web_fetch_raw() {
    local url="$1"
    curl -sL \
        --max-time "$WEB_TIMEOUT" \
        --max-filesize "$WEB_MAX_SIZE" \
        -H "User-Agent: Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 Chrome/131.0 Safari/537.36" \
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
        -H "Accept-Language: en-US,en;q=0.9" \
        "$url" 2>/dev/null
}

# ── Strip HTML to plain text ──────────────────────────────────
_html_to_text_sed() {
    # Pure sed/awk fallback — works everywhere
    sed -e 's/<script[^>]*>.*<\/script>//g' \
        -e 's/<style[^>]*>.*<\/style>//g' \
        -e 's/<nav[^>]*>.*<\/nav>//gi' \
        -e 's/<header[^>]*>.*<\/header>//gi' \
        -e 's/<footer[^>]*>.*<\/footer>//gi' \
        -e 's/<[^>]*>//g' \
        -e 's/&nbsp;/ /g' \
        -e 's/&amp;/\&/g' \
        -e 's/&lt;/</g' \
        -e 's/&gt;/>/g' \
        -e 's/&quot;/"/g' \
        -e "s/&#39;/'/g" \
        -e 's/&#[0-9]*;//g' \
        -e '/^[[:space:]]*$/d' | \
        awk '{$1=$1}1' | \
        head -500
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

# ── Fetch a URL and return clean text ─────────────────────────
web_fetch() {
    local url="$1"

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

    ui_dim "Fetching: $url"
    local html
    html=$(web_fetch_raw "$url")
    if [ -z "$html" ]; then
        ui_err "Failed to fetch: $url"
        return 1
    fi

    local text
    text=$(echo "$html" | _html_to_text)

    # Cache result
    mkdir -p "$GEORGE_CACHE_DIR"
    echo "$text" > "$cache_file" 2>/dev/null

    echo "$text"
}

# ── Extract just the title from a page ────────────────────────
web_title() {
    local url="$1"
    local html
    html=$(web_fetch_raw "$url")
    echo "$html" | grep -oP '(?<=<title>).*?(?=</title>)' | head -1 | \
        sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g'
}

# ── Extract all links from a page ─────────────────────────────
web_links() {
    local url="$1"
    local html
    html=$(web_fetch_raw "$url")
    echo "$html" | grep -oP 'href="[^"]*"' | sed 's/href="//;s/"$//' | \
        grep -E '^https?://' | sort -u | head -50
}

# ── Search the web ────────────────────────────────────────────
# Uses Serper.dev API (Google results) if key is set,
# otherwise falls back to DuckDuckGo HTML scraping

web_search() {
    local query="$1"
    local count="${2:-5}"

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
        echo "$resp" | jq -r '.organic[]? | "[\(.position)] \(.title)\n    \(.link)\n    \(.snippet)\n"' 2>/dev/null
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

    local html
    html=$(curl -sL \
        --max-time 10 \
        -H "User-Agent: Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36" \
        "https://html.duckduckgo.com/html/?q=$encoded" 2>/dev/null)

    if [ -z "$html" ]; then
        ui_err "DuckDuckGo search failed"
        return 1
    fi

    # Parse results from DDG HTML
    echo "$html" | grep -oP 'class="result__a"[^>]*href="[^"]*"[^>]*>[^<]*' | \
        sed 's/.*href="//;s/"[^>]*>/\n    /' | \
        head -$((count * 2)) | \
        awk 'NR % 2 == 0 {title=$0} NR % 2 == 1 {print "[" int(NR/2)+1 "] " title; print "    " $0; print ""}'

    # Sometimes DDG HTML format varies, try alternate parse
    if [ $? -ne 0 ] || [ -z "$(echo "$html" | grep 'result__a')" ]; then
        echo "$html" | _html_to_text_sed | head -40
    fi
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

    llm_generate "$prompt" "You are George, summarizing web content for your user."
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

# ── Clear web cache ───────────────────────────────────────────
web_cache_clear() {
    if [ -d "$GEORGE_CACHE_DIR" ]; then
        rm -f "$GEORGE_CACHE_DIR"/web_* 2>/dev/null
        ui_ok "Web cache cleared"
    fi
}
