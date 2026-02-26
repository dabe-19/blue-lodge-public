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

    # Write to journal (persistent cross-task memory)
    if declare -f journal_write &>/dev/null; then
        local entry="Web search ($provider): $query\n\n$results_text"
        journal_write "web_search" "$entry" 2>/dev/null
    fi

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

# ── Extract image URLs from a page ─────────────────────────────
# Scrapes <img src>, <img data-src>, and <source srcset> attributes
# from the raw HTML of a page.  Returns only absolute image URLs
# (http/https) filtered to common image extensions.  Relative URLs
# are resolved against the page's base URL.
#
# Usage: web_scrape_images "https://en.wikipedia.org/wiki/Grand_Lodge"
# Output:
#   [1] https://upload.wikimedia.org/…/Grand_Lodge.jpg
#   [2] https://upload.wikimedia.org/…/Coat_of_Arms.png
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

    ui_dim "Scraping images from: $clean_url"
    local html
    html=$(web_fetch_raw "$clean_url")
    if [ -z "$html" ]; then
        ui_err "Failed to fetch: $clean_url"
        return 1
    fi

    # Extract the base URL (scheme + host) for resolving relative paths
    local base_url
    base_url=$(echo "$clean_url" | sed 's|^\(https\?://[^/]*\).*|\1|')

    # Extract image URLs from multiple HTML patterns:
    #   1. <img src="...">
    #   2. <img data-src="...">  (lazy-loaded images)
    #   3. <source srcset="...">  (picture elements)
    local raw_urls
    raw_urls=$(
        echo "$html" | grep -oP '(?:src|data-src|srcset)="[^"]+"' | \
            sed 's/^[^"]*"//;s/"$//' | \
            sed 's/ [0-9]*[wx].*$//' | \
            sort -u
    )

    if [ -z "$raw_urls" ]; then
        ui_warn "No images found on: $clean_url"
        return 1
    fi

    # Resolve relative URLs and filter to image extensions
    local output=""
    local i=1
    while IFS= read -r img_url; do
        [ -z "$img_url" ] && continue

        # Skip data: URIs, inline SVG, and tracking pixels
        [[ "$img_url" == data:* ]] && continue
        [[ "$img_url" == javascript:* ]] && continue

        # Resolve protocol-relative URLs
        if [[ "$img_url" == //* ]]; then
            img_url="https:$img_url"
        # Resolve absolute-path URLs
        elif [[ "$img_url" == /* ]]; then
            img_url="${base_url}${img_url}"
        # Skip if not already a full URL
        elif [[ "$img_url" != http* ]]; then
            # Relative path — resolve against page URL (strip filename)
            local page_dir
            page_dir=$(echo "$clean_url" | sed 's|/[^/]*$|/|')
            img_url="${page_dir}${img_url}"
        fi

        # Filter to common image extensions
        if [[ "$img_url" =~ \.(jpg|jpeg|png|gif|webp|bmp|svg|avif|tiff)(\?|$) ]]; then
            # Sanitize the resolved URL
            local safe_url
            safe_url=$(_web_sanitize_url "$img_url")
            [ -z "$safe_url" ] && continue

            printf '[%d] %s\n' "$i" "$safe_url"
            output="${output}[$i] $safe_url\n"
            i=$((i + 1))

            # Cap at 30 results to avoid flooding
            [ "$i" -gt 30 ] && break
        fi
    done <<< "$raw_urls"

    if [ -z "$output" ]; then
        ui_warn "No image URLs found (page may use JavaScript-loaded images)"
        return 1
    fi

    # Journal the results for agent memory
    _web_journal_results "images from $clean_url" "$output" "scrape"
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
        local i=1
        while IFS='|' read -r _pos url title snippet; do
            local clean_url
            clean_url=$(_web_sanitize_url "$url")
            [ -z "$clean_url" ] && continue

            local entry
            entry=$(printf '[%d] %s\n    %s\n    %s\n' "$i" "$title" "$clean_url" "$snippet")
            output="${output}${entry}\n"
            printf '[%d] %s\n    %s\n    %s\n\n' "$i" "$title" "$clean_url" "$snippet"
            i=$((i + 1))
        done <<< "$raw_results"

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
        # Filter ads and sanitize URLs, then output + journal
        local clean_results=""
        local output=""
        local i=1

        while IFS='|' read -r url title; do
            # Decode DDG redirect URLs (uddg= parameter)
            if [[ "$url" == *"uddg="* ]]; then
                url=$(echo "$url" | grep -oP 'uddg=\K[^&]+' | python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))' 2>/dev/null || echo "$url")
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
