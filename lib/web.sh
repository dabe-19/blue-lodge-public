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

    # Use DuckDuckGo Lite — simpler HTML, more reliable parsing
    local html
    html=$(curl -sL \
        --max-time 10 \
        -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0" \
        -H "Accept: text/html" \
        -H "Accept-Language: en-US,en;q=0.5" \
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
    results=$(echo "$html" | grep -oP '<a[^>]*class="result-link"[^>]*>[^<]*' 2>/dev/null | \
        sed -n 's/.*href="\([^"]*\)".*>\([^<]*\)/\1|\2/p' | head -"$count")

    # Method 2: If no result-link, try result__a (standard DDG HTML)
    if [ -z "$results" ]; then
        results=$(echo "$html" | grep -oP 'class="result__a"[^>]*href="[^"]*"[^>]*>[^<]*' 2>/dev/null | \
            sed 's/.*href="//;s/"[^>]*>/|/' | head -"$count")
    fi

    # Method 3: Extract from DDG Lite table rows (most reliable)
    if [ -z "$results" ]; then
        results=$(echo "$html" | \
            grep -oP '<a[^>]+rel="nofollow"[^>]+href="[^"]+"[^>]*>[^<]+' 2>/dev/null | \
            sed 's/<a[^>]*href="//;s/"[^>]*>/|/' | head -"$count")
    fi

    if [ -n "$results" ]; then
        local i=1
        echo "$results" | while IFS='|' read -r url title; do
            # Decode DDG redirect URLs
            if [[ "$url" == *"uddg="* ]]; then
                url=$(echo "$url" | grep -oP 'uddg=\K[^&]+' | python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))' 2>/dev/null || echo "$url")
            fi
            printf '[%d] %s\n    %s\n\n' "$i" "${title:-$url}" "$url"
            i=$((i + 1))
        done
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
    result=$(llm_generate "$prompt" "You are George, summarizing web content for your user." 256)
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
    echo "$resp" | jq -r '.items[]? | "[\(.full_name)] ★\(.stargazers_count) (\(.language // "unknown"))\n    \(.description // "No description")\n    https://github.com/\(.full_name)\n"' 2>/dev/null
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
