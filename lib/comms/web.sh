#!/bin/bash
# ── George: Web Browsing Engine ────────────────────────────────
# Fetch, parse, search, and summarize web content using only
# curl + sed/awk (with optional w3m/lynx for better rendering).
# George can now read the web and act on what he finds.

[ -n "${_LIB_WEB_LOADED:-}" ] && return 0; _LIB_WEB_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
export GEORGE_CONFIG_DIR="${GEORGE_CONFIG_DIR:-$LODGE_DIR/.george}"
source "$LODGE_DIR/lib/core/api.sh"

# ── Config ─────────────────────────────────────────────────────
WEB_TIMEOUT="${WEB_TIMEOUT:-15}"
WEB_MAX_SIZE="${WEB_MAX_SIZE:-2000000}"      # 2MB max HTML download
WEB_MAX_SIZE_PDF="${WEB_MAX_SIZE_PDF:-10000000}"  # 10MB max PDF download
WEB_CACHE_TTL="${WEB_CACHE_TTL:-3600}"     # Cache pages for 1 hour
WEB_BLACKLIST_FILE="${WEB_BLACKLIST_FILE:-${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}/web_blacklist.log}"
WEB_BLACKLIST_ENABLED="${WEB_BLACKLIST_ENABLED:-true}"
WEB_BLACKLIST_TTL="${WEB_BLACKLIST_TTL:-1800}"  # Dynamic blacklist entries expire after 30 minutes (seconds)
WEB_CONTENT_MAX_CHARS="${WEB_CONTENT_MAX_CHARS:-24000}"  # Max chars for cleaned web content (post-boilerplate)

WEB_BLACKLIST_DOMAINS="${WEB_BLACKLIST_DOMAINS:-linkedin.com,facebook.com,instagram.com,twitter.com,x.com,tiktok.com,pinterest.com,youtube.com,youtu.be}"

WEB_GREYLIST_DOMAINS="${WEB_GREYLIST_DOMAINS:-google.com,redfin.com,zillow.com,linkedin.com,bloomberg.com,medium.com,wsj.com,nytimes.com,wired.com,realtor.com}"
WEB_GREYLIST_FILE="${WEB_GREYLIST_FILE:-${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}/web_greylist.log}"
WEB_GREYLIST_ENABLED="${WEB_GREYLIST_ENABLED:-true}"
WEB_GREYLIST_TTL="${WEB_GREYLIST_TTL:-1800}"  # Dynamic greylist entries expire after 30 minutes

# Dynamic platform matching browser credentials
WEB_SEC_CH_UA="${WEB_SEC_CH_UA:-}"
WEB_SEC_CH_UA_MOBILE="${WEB_SEC_CH_UA_MOBILE:-}"
WEB_SEC_CH_UA_PLATFORM="${WEB_SEC_CH_UA_PLATFORM:-}"
WEB_USER_AGENT="${WEB_USER_AGENT:-Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36}"

_web_init_fingerprint() {
    if [ -n "${WEB_USER_AGENT:-}" ] && [ "${WEB_USER_AGENT}" != "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36" ]; then
        if [ -z "$WEB_SEC_CH_UA_PLATFORM" ]; then
            if [[ "$WEB_USER_AGENT" == *"Android"* ]]; then WEB_SEC_CH_UA_PLATFORM='"Android"'; WEB_SEC_CH_UA_MOBILE="?1"
            elif [[ "$WEB_USER_AGENT" == *"Linux"* ]]; then WEB_SEC_CH_UA_PLATFORM='"Linux"'; WEB_SEC_CH_UA_MOBILE="?0"
            elif [[ "$WEB_USER_AGENT" == *"iPhone"* || "$WEB_USER_AGENT" == *"iPad"* ]]; then WEB_SEC_CH_UA_PLATFORM='"iOS"'; WEB_SEC_CH_UA_MOBILE="?1"
            else WEB_SEC_CH_UA_PLATFORM='"Windows"'; WEB_SEC_CH_UA_MOBILE="?0"; fi
            WEB_SEC_CH_UA='"Not(A:Brand";v="99", "Google Chrome";v="133", "Chromium";v="133"'
        fi
        return 0
    fi
    local os_info="${_WEB_TEST_OS_OVERRIDE:-}"
    [ -z "$os_info" ] && [ -f /proc/version ] && os_info=$(cat /proc/version)
    [ -z "$os_info" ] && os_info=$(uname -a 2>/dev/null || echo "")
    WEB_SEC_CH_UA='"Not(A:Brand";v="99", "Google Chrome";v="133", "Chromium";v="133"'
    if [[ "$os_info" == *"Android"* || "$os_info" == *"android"* ]] || command -v termux-info &>/dev/null; then
        WEB_USER_AGENT="Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Mobile Safari/537.36"; WEB_SEC_CH_UA_MOBILE="?1"; WEB_SEC_CH_UA_PLATFORM='"Android"'
    elif [[ "$os_info" == *"Microsoft"* || "$os_info" == *"wsl"* || "$os_info" == *"WSL"* ]]; then
        WEB_USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"; WEB_SEC_CH_UA_MOBILE="?0"; WEB_SEC_CH_UA_PLATFORM='"Windows"'
    elif [[ "$(uname 2>/dev/null)" == "Darwin" ]]; then
        WEB_USER_AGENT="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"; WEB_SEC_CH_UA_MOBILE="?0"; WEB_SEC_CH_UA_PLATFORM='"macOS"'
    else
        WEB_USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"; WEB_SEC_CH_UA_MOBILE="?0"; WEB_SEC_CH_UA_PLATFORM='"Linux"'
    fi
}
_web_init_fingerprint

# ── Centralized curl wrapper ──────────────────────────────────
_WEB_COOKIE_JAR="${TMPDIR:-/tmp}/.lodge-web-cookies-$$.jar"

_web_curl() {
    curl -sL --compressed --connect-timeout 8 --speed-limit 100 --speed-time 10 \
        -b "$_WEB_COOKIE_JAR" -c "$_WEB_COOKIE_JAR" \
        -H "User-Agent: $WEB_USER_AGENT" \
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7" \
        -H "Accept-Language: en-US,en;q=0.9" -H "Connection: keep-alive" -H "Upgrade-Insecure-Requests: 1" \
        -H "Sec-Ch-Ua: $WEB_SEC_CH_UA" -H "Sec-Ch-Ua-Mobile: $WEB_SEC_CH_UA_MOBILE" -H "Sec-Ch-Ua-Platform: $WEB_SEC_CH_UA_PLATFORM" \
        -H "Sec-Fetch-Dest: document" -H "Sec-Fetch-Mode: navigate" -H "Sec-Fetch-Site: none" -H "Sec-Fetch-User: ?1" "$@"
}

# ── Blocked-site detection + blacklist ───────────────────────
_web_block_reason() {
    local status="$1" html="$2" lower_html
    lower_html=$(printf '%s' "$html" | tr '[:upper:]' '[:lower:]')
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
    if echo "$lower_html" | grep -qE 'cf-chl-bypass|cf-chl-widget|challenge-platform|_cf_chl_opt|verify you are human|just a moment\.\.\.|enable javascript and cookies|ray id|please wait for verification|checking your browser|security verification|human verification|checking if the site connection is secure|robot check|vercel security checkpoint|vercel-challenge|deployment-protection|datadome|perimeterx'; then
        echo "HTML_CHALLENGE_OR_CAPTCHA"; return 0
    fi
    if echo "$lower_html" | grep -qE 'captcha|request blocked|bot detection|incapsula' && [ "${#html}" -lt 20000 ]; then
        echo "HTML_CHALLENGE_OR_CAPTCHA"; return 0
    fi
    if echo "$lower_html" | grep -qE 'cloudflare|akamai|access denied|security check' && [ "${#html}" -lt 5000 ]; then
        local _vis; _vis=$(printf '%s' "$lower_html" | sed -e 's/<[^>]*>//g; s/https\?:\/\/[^ "]*//g')
        echo "$_vis" | grep -qE 'cloudflare|akamai|access denied|security check' && { echo "HTML_CHALLENGE_OR_CAPTCHA"; return 0; }
    fi
    return 1
}

_web_blacklist_is_enabled() {
    [[ "$WEB_BLACKLIST_ENABLED" == "true" || "$WEB_BLACKLIST_ENABLED" == "1" || "$WEB_BLACKLIST_ENABLED" == "yes" ]]
}

_web_list_contains() {
    local domains="$1" file="$2" ttl="${3:-1800}" url="$4"
    local host; host=$(echo "$url" | sed 's|^https\?://||' | cut -d'/' -f1 | tr '[:upper:]' '[:lower:]')
    if [ -n "$domains" ]; then
        local d; IFS=',' read -ra d_list <<< "$domains"
        for d in "${d_list[@]}"; do
            d=$(echo "$d" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')
            [ -n "$d" ] && { [[ "$host" == "$d" || "$host" == *".$d" ]] && return 0; }
        done
    fi
    [ -f "$file" ] || return 1
    local now; now=$(date +%s)
    local match; match=$(grep -E "\|url=${url//\//\\/}(\||$)|\|host=${host//\./\\.}(\||$)" "$file" 2>/dev/null | tail -1)
    [ -z "$match" ] && return 1
    local line_ts; line_ts=$(echo "$match" | sed -n 's/^\([^|]*\)|.*/\1/p')
    if [ -n "$line_ts" ]; then
        local line_epoch; line_epoch=$(date -d "$line_ts" +%s 2>/dev/null || echo 0)
        [ $((now - line_epoch)) -gt "$ttl" ] && return 1
    fi
    return 0
}

_web_blacklist_contains() {
    _web_blacklist_is_enabled || return 1
    local _domains="${WEB_BLACKLIST_DOMAINS:-}"
    local _age=0
    [ "$_age" -ge "${WEB_BLACKLIST_TTL:-1800}" ] 2>/dev/null || true
    _web_list_contains "$_domains" "$WEB_BLACKLIST_FILE" "${WEB_BLACKLIST_TTL:-1800}" "$1"
}

_web_blacklist_reason() {
    local url="$1" host; host=$(echo "$url" | sed 's|^https\?://||' | cut -d'/' -f1)
    [ -f "$WEB_BLACKLIST_FILE" ] || return 1
    local line; line=$(grep "|url=$url|" "$WEB_BLACKLIST_FILE" 2>/dev/null | tail -1)
    [ -z "$line" ] && line=$(grep "|host=$host|" "$WEB_BLACKLIST_FILE" 2>/dev/null | tail -1)
    [ -z "$line" ] && return 1
    echo "$line" | sed -n 's/.*|reason=\([^|]*\).*/\1/p'
}

_web_greylist_is_enabled() {
    [[ "$WEB_GREYLIST_ENABLED" == "true" || "$WEB_GREYLIST_ENABLED" == "1" || "$WEB_GREYLIST_ENABLED" == "yes" ]]
}

_web_greylist_contains() {
    _web_greylist_is_enabled || return 1
    _web_list_contains "${WEB_GREYLIST_DOMAINS:-}" "$WEB_GREYLIST_FILE" "${WEB_GREYLIST_TTL:-1800}" "$1"
}

_web_greylist_add() {
    local host="$1" reason="${2:-challenge_block}"
    [ -z "$host" ] && return 1
    mkdir -p "$(dirname "$WEB_GREYLIST_FILE")" 2>/dev/null
    printf '%s|host=%s|reason=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$host" "$reason" >> "$WEB_GREYLIST_FILE"
}

_web_greylist_fallback() {
    local url="$1" search_file="${AGENT_TASK_WORKSPACE:-.george/workspaces}/last_search.json"
    if [ -f "$search_file" ] && command -v jq &>/dev/null; then
        local match_data; match_data=$(jq -c --arg url "$url" '.results[]? | select(.url == $url) // empty' "$search_file" 2>/dev/null | tail -1)
        if [ -n "$match_data" ]; then
            local title snippet
            title=$(echo "$match_data" | jq -r '.title // "No Title"')
            snippet=$(echo "$match_data" | jq -r '.snippet // ""')
            local fallback_content="[SYSTEM NOTE: Domain is grey-listed for direct curls. Serving cached search engine snippet instead of hitting the live server.]\n\n$snippet"
            jq -n --arg url "$url" --arg title "$title" --arg content "$fallback_content" '{"url":$url,"title":$title,"content":$content,"images":[]}'
            return 0
        fi
    fi
    return 1
}

WEB_EXCLUSIONS_FILE="${WEB_EXCLUSIONS_FILE:-${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}/search_exclusions.log}"

_web_exclusions_add() {
    local host="$1"
    [ -z "$host" ] && return 1
    mkdir -p "$(dirname "$WEB_EXCLUSIONS_FILE")" 2>/dev/null
    local strike_count=1 existing_entry=""
    [ -f "$WEB_EXCLUSIONS_FILE" ] && existing_entry=$(grep "|host=$host|" "$WEB_EXCLUSIONS_FILE" 2>/dev/null | tail -1)
    if [ -n "$existing_entry" ]; then
        local prev_strikes; prev_strikes=$(echo "$existing_entry" | awk -F'|' '{print $3}' | sed 's/strike_count=//')
        strike_count=$((prev_strikes + 1))
    fi
    local ttl=86400
    [ "$strike_count" -eq 2 ] && ttl=604800
    [ "$strike_count" -ge 3 ] && ttl=2592000
    printf '%s|host=%s|strike_count=%s|ttl_seconds=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$host" "$strike_count" "$ttl" >> "$WEB_EXCLUSIONS_FILE"
}

_web_exclusions_get_active_filters() {
    local active_filters=""
    if [ -n "${WEB_BLACKLIST_DOMAINS:-}" ]; then
        local _d; IFS=',' read -ra _bl_domains <<< "$WEB_BLACKLIST_DOMAINS"
        for _d in "${_bl_domains[@]}"; do
            _d=$(echo "$_d" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')
            [ -n "$_d" ] && active_filters="${active_filters} -site:${_d}"
        done
    fi
    local now_epoch; now_epoch=$(date -u '+%s')
    if [ -f "${WEB_BLACKLIST_FILE:-}" ] && [ -s "${WEB_BLACKLIST_FILE:-}" ]; then
        declare -A latest_bl_lines
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local host; host=$(echo "$line" | sed -n 's/.*|host=\([^|]*\).*/\1/p')
            [ -n "$host" ] && latest_bl_lines["$host"]="$line"
        done < "$WEB_BLACKLIST_FILE"
        for host in "${!latest_bl_lines[@]}"; do
            local ts; ts=$(echo "${latest_bl_lines[$host]}" | sed -n 's/^\([^|]*\)|.*/\1/p')
            if [ -n "$ts" ]; then
                local ts_epoch; ts_epoch=$(date -u -d "$ts" '+%s' 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" "+%s" 2>/dev/null)
                if [ -n "$ts_epoch" ] && [ $((now_epoch - ts_epoch)) -lt "${WEB_BLACKLIST_TTL:-1800}" ]; then
                    active_filters="${active_filters} -site:${host}"
                fi
            fi
        done
    fi
    if [ -f "${WEB_EXCLUSIONS_FILE:-}" ] && [ -s "${WEB_EXCLUSIONS_FILE:-}" ]; then
        declare -A latest_excl_lines
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local host; host=$(echo "$line" | sed -n 's/.*|host=\([^|]*\).*/\1/p')
            [ -n "$host" ] && latest_excl_lines["$host"]="$line"
        done < "$WEB_EXCLUSIONS_FILE"
        for host in "${!latest_excl_lines[@]}"; do
            local entry="${latest_excl_lines[$host]}"
            local ts ttl_part ts_epoch
            ts=$(echo "$entry" | sed -n 's/^\([^|]*\)|.*/\1/p')
            ttl_part=$(echo "$entry" | sed -n 's/.*|ttl_seconds=\([^|]*\).*/\1/p')
            ts_epoch=$(date -u -d "$ts" '+%s' 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" "+%s" 2>/dev/null)
            if [ -n "$ts_epoch" ] && [ -n "$ttl_part" ] && [ $((now_epoch - ts_epoch)) -lt "$ttl_part" ]; then
                active_filters="${active_filters} -site:${host}"
            fi
        done
    fi
    [ -n "$active_filters" ] && echo "$active_filters" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

_web_blacklist_add() {
    local url="$1" reason="$2" status="$3" host
    host=$(echo "$url" | sed 's|^https\?://||' | cut -d'/' -f1)
    mkdir -p "$(dirname "$WEB_BLACKLIST_FILE")" 2>/dev/null
    if [ -f "$WEB_BLACKLIST_FILE" ] && grep -q "|host=$host|" "$WEB_BLACKLIST_FILE" 2>/dev/null && grep -q "|reason=$reason" "$WEB_BLACKLIST_FILE" 2>/dev/null; then
        return 0
    fi
    printf '%s|url=%s|host=%s|status=%s|reason=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$url" "$host" "${status:-unknown}" "$reason" >> "$WEB_BLACKLIST_FILE"
    _web_exclusions_add "$host"
}

# ── Blacklist management commands ─────────────────────────────
web_blacklist_list() {
    local has_bl=0 has_excl=0
    [ -f "$WEB_BLACKLIST_FILE" ] && [ -s "$WEB_BLACKLIST_FILE" ] && has_bl=1
    [ -f "$WEB_EXCLUSIONS_FILE" ] && [ -s "$WEB_EXCLUSIONS_FILE" ] && has_excl=1
    if [ "$has_bl" -eq 0 ] && [ "$has_excl" -eq 0 ]; then
        ui_info "Blacklist and search exclusions are empty"
        return 0
    fi
    if [ "$has_bl" -eq 1 ]; then
        local _state="enabled"; _web_blacklist_is_enabled || _state="disabled"
        ui_section "Web Blacklist ($_state)"
        local count=0
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local ts host reason status
            ts=$(echo "$line" | sed -n 's/^\([^|]*\)|.*/\1/p')
            host=$(echo "$line" | sed -n 's/.*|host=\([^|]*\).*/\1/p')
            reason=$(echo "$line" | sed -n 's/.*|reason=\([^|]*\).*/\1/p')
            status=$(echo "$line" | sed -n 's/.*|status=\([^|]*\).*/\1/p')
            printf '  %b%-30s%b  status=%-4s  %s  %b(%s)%b\n' "$C_WHITE" "$host" "$C_RESET" "$status" "$reason" "$C_DIM" "$ts" "$C_RESET"
            count=$((count + 1))
        done < "$WEB_BLACKLIST_FILE"
        echo ""; ui_dim "  $count entries total"
    fi
    if [ "$has_excl" -eq 1 ]; then
        [ "$has_bl" -eq 1 ] && echo ""
        ui_section "Web Search Exclusions"
        local now_epoch; now_epoch=$(date -u '+%s')
        declare -A latest_lines
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local host; host=$(echo "$line" | awk -F'|' '{print $2}' | sed 's/host=//')
            [ -n "$host" ] && latest_lines["$host"]="$line"
        done < "$WEB_EXCLUSIONS_FILE"
        local excl_count=0
        for host in "${!latest_lines[@]}"; do
            local entry="${latest_lines[$host]}" ts strike_part ttl_part ts_epoch
            ts=$(echo "$entry" | awk -F'|' '{print $1}')
            strike_part=$(echo "$entry" | awk -F'|' '{print $3}' | sed 's/strike_count=//')
            ttl_part=$(echo "$entry" | awk -F'|' '{print $4}' | sed 's/ttl_seconds=//')
            ts_epoch=$(date -u -d "$ts" '+%s' 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" "+%s" 2>/dev/null)
            if [ -n "$ts_epoch" ] && [ -n "$ttl_part" ]; then
                local time_left=$((ttl_part - (now_epoch - ts_epoch)))
                if [ "$time_left" -gt 0 ]; then
                    local time_str="$((time_left / 60))m remaining"
                    [ "$time_left" -ge 3600 ] && time_str="$((time_left / 3600))h remaining"
                    [ "$time_left" -ge 86400 ] && time_str="$((time_left / 86400))d remaining"
                    printf '  %b%-30s%b  strikes=%-2s  ttl=%-7ss  %s  %b(%s)%b\n' "$C_WHITE" "$host" "$C_RESET" "$strike_part" "$ttl_part" "$time_str" "$C_DIM" "$ts" "$C_RESET"
                    excl_count=$((excl_count + 1))
                fi
            fi
        done
        echo ""; ui_dim "  $excl_count active exclusion(s)"
    fi
}

web_blacklist_rm() {
    local target="$1"
    [ -z "$target" ] && { ui_err "Usage: /web blacklist rm <host-or-url>"; return 1; }
    local host; host=$(echo "$target" | sed 's|^https\?://||' | cut -d'/' -f1)
    local removed_bl=0 removed_excl=0
    if [ -f "$WEB_BLACKLIST_FILE" ]; then
        local b a; b=$(wc -l < "$WEB_BLACKLIST_FILE")
        grep -v "|host=$host|" "$WEB_BLACKLIST_FILE" > "${WEB_BLACKLIST_FILE}.tmp" 2>/dev/null || true
        mv "${WEB_BLACKLIST_FILE}.tmp" "$WEB_BLACKLIST_FILE"
        a=$(wc -l < "$WEB_BLACKLIST_FILE"); removed_bl=$((b - a))
    fi
    if [ -f "$WEB_EXCLUSIONS_FILE" ]; then
        local b a; b=$(wc -l < "$WEB_EXCLUSIONS_FILE")
        grep -v "|host=$host|" "$WEB_EXCLUSIONS_FILE" > "${WEB_EXCLUSIONS_FILE}.tmp" 2>/dev/null || true
        mv "${WEB_EXCLUSIONS_FILE}.tmp" "$WEB_EXCLUSIONS_FILE"
        a=$(wc -l < "$WEB_EXCLUSIONS_FILE"); removed_excl=$((b - a))
    fi
    if [ "$removed_bl" -gt 0 ] || [ "$removed_excl" -gt 0 ]; then
        ui_ok "Removed matching entries for $host (blacklist: $removed_bl, exclusions: $removed_excl)"
    else
        ui_info "No entries found for $host"
    fi
}

web_blacklist_clear() {
    local count_bl=0 count_excl=0
    [ -f "$WEB_BLACKLIST_FILE" ] && { count_bl=$(wc -l < "$WEB_BLACKLIST_FILE"); : > "$WEB_BLACKLIST_FILE"; }
    [ -f "$WEB_EXCLUSIONS_FILE" ] && { count_excl=$(wc -l < "$WEB_EXCLUSIONS_FILE"); : > "$WEB_EXCLUSIONS_FILE"; }
    ui_ok "Cleared blacklist ($count_bl entries) and search exclusions ($count_excl entries)"
}

web_blacklist_enable() { WEB_BLACKLIST_ENABLED="true"; ui_ok "Web blacklist enabled"; }
web_blacklist_disable() { WEB_BLACKLIST_ENABLED="false"; ui_warn "Web blacklist disabled — blocked sites will be retried"; }

# ── DNS Pre-Check ─────────────────────────────────────────────
_web_dns_precheck() {
    local host; host=$(echo "$1" | sed 's|^https\?://||' | cut -d'/' -f1 | cut -d':' -f1)
    [ -z "$host" ] && return 1
    case "$host" in localhost|127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|[0-9]*.[0-9]*.[0-9]*.[0-9]*) return 0 ;; esac
    if command -v getent >/dev/null 2>&1; then getent ahosts "$host" >/dev/null 2>&1 && return 0
    elif command -v host >/dev/null 2>&1; then host -W 2 "$host" >/dev/null 2>&1 && return 0
    elif command -v dig >/dev/null 2>&1; then dig +short +time=2 "$host" 2>/dev/null | grep -q . && return 0
    else return 0; fi
    return 1
}

# ── URL Sanitization ──────────────────────────────────────────
_web_sanitize_url() {
    local url; url=$(echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    url=$(printf '%s' "$url" | tr -d '\000-\037\177\`$;|')
    [[ ! "$url" =~ ^https?:// ]] && return 1
    local host; host=$(echo "$url" | sed 's|^https\?://||' | cut -d'/' -f1 | cut -d'?' -f1)
    [[ ! "$host" == *.* ]] && return 1
    printf '%s' "${url:0:2048}"
}

# ── Ad URL Detection ─────────────────────────────────────────
_web_is_ad_url() {
    case "$1" in
        *duckduckgo.com/y.js*|*ad_domain=*|*ad_provider=*|*bing.com/aclick*|*googleadservices.com*|*google.com/aclk*|*doubleclick.net*|*googlesyndication.com*) return 0 ;;
        *) return 1 ;;
    esac
}

# ── Journal Search Results ───────────────────────────────────
_web_journal_results() {
    local query="$1" results_text="$2" provider="$3"
    [ -z "$results_text" ] && return 0
    if [ -d ".george" ]; then
        {
            echo "## Web Search: $query"
            echo "Provider: $provider"
            echo "Time: $(date '+%Y-%m-%d %H:%M')"
            echo ""; echo "$results_text"; echo "---"
        } >> ".george/search_results.md"
    fi
}

# ── Detect best text renderer ──────────────────────────────────
_web_renderer() {
    if command -v w3m &>/dev/null; then echo "w3m"
    elif command -v lynx &>/dev/null; then echo "lynx"
    elif command -v html2text &>/dev/null; then echo "html2text"
    else echo "sed"; fi
}

# ── Content-type classification ─────────────────────────────────
_web_classify_content_type() {
    local ct; ct=$(echo "$1" | cut -d';' -f1 | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    [ -z "$ct" ] && return 0
    case "$ct" in
        application/pdf) echo "pdf" ;;
        text/plain|text/csv|text/markdown|text/tab-separated-values) echo "text" ;;
        application/json|text/json) echo "json" ;;
        application/xml|text/xml|application/rss+xml|application/atom+xml) echo "xml" ;;
        text/html*|application/xhtml+xml) echo "html" ;;
        application/octet-stream) ;;
        image/*|audio/*|video/*) echo "binary" ;;
    esac
}

_web_guess_content_type() {
    local path; path=$(echo "$1" | sed 's/[?#].*//' | tr '[:upper:]' '[:lower:]')
    case "$path" in
        *.pdf) echo "pdf" ;;
        *.txt|*.log|*.cfg|*.ini|*.csv|*.tsv|*.md|*.markdown|*.rst) echo "text" ;;
        *.json|*.jsonl|*.geojson) echo "json" ;;
        *.xml|*.rss|*.atom|*.svg) echo "xml" ;;
        *.jpg|*.jpeg|*.png|*.gif|*.webp|*.bmp|*.ico|*.mp3|*.mp4|*.wav|*.avi|*.mov|*.zip|*.tar|*.gz|*.bz2|*.7z|*.rar|*.doc|*.docx|*.ppt|*.pptx|*.xls|*.xlsx) echo "binary" ;;
        *) echo "html" ;;
    esac
}

_web_detect_content_type() { _web_guess_content_type "$1"; }

# ── Download to temp file ─────────────────────────────────────
_web_fetch_to_file() {
    local url="$1" max_size="${2:-$WEB_MAX_SIZE_PDF}" tmpfile="${TMPDIR:-/tmp}/.lodge-web-dl-$$.tmp"
    if ! _web_curl --max-time "$((WEB_TIMEOUT * 3))" --max-filesize "$max_size" -o "$tmpfile" "$url" 2>/dev/null || [ ! -s "$tmpfile" ]; then
        rm -f "$tmpfile"; return 1
    fi
    echo "$tmpfile"
}

# ── PDF text extraction ───────────────────────────────────────
_web_extract_pdf() {
    local source="$1" tmpfile="" pdf_path
    if [[ "$source" == http* ]] && declare -f mcp_enabled &>/dev/null && mcp_enabled; then
        local _mcp_pdf; _mcp_pdf=$(mcp_web_fetch_pdf "$source" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$_mcp_pdf" ]; then
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && ui_dim "  [debug] _web_extract_pdf: MCP succeeded (${#_mcp_pdf} bytes)"
            echo "$_mcp_pdf"; return 0
        fi
    fi
    if [[ "$source" == http* ]]; then
        tmpfile=$(_web_fetch_to_file "$source")
        [ -z "$tmpfile" ] && return 1
        pdf_path="$tmpfile"
    else
        pdf_path="$source"
    fi
    local text=""
    if command -v pdftotext &>/dev/null; then text=$(pdftotext -layout -q "$pdf_path" - 2>/dev/null | head -2000); fi
    if [ -z "$text" ] && command -v strings &>/dev/null; then text=$(strings "$pdf_path" 2>/dev/null | grep -E '[a-zA-Z]{3,}' | head -1000); fi
    [ -n "$tmpfile" ] && rm -f "$tmpfile"
    [ -z "$text" ] && return 1
    echo "$text"
}

_web_fetch_text() { _web_curl --max-time "$WEB_TIMEOUT" --max-filesize "$WEB_MAX_SIZE" "$1" 2>/dev/null | head -2000; }
_web_fetch_json_raw() { _web_curl --max-time "$WEB_TIMEOUT" --max-filesize "$WEB_MAX_SIZE" -H "Accept: application/json" "$1" 2>/dev/null | jq '.' 2>/dev/null | head -2000; }
_web_extract_xml() {
    _web_curl --max-time "$WEB_TIMEOUT" --max-filesize "$WEB_MAX_SIZE" "$1" 2>/dev/null | \
        sed -e 's/<[^>]*>//g' -e 's/&amp;/\&/g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&#39;/'/g" -e '/^[[:space:]]*$/d' | awk '{$1=$1}1' | head -2000
}

# ── Fetch raw HTML ─────────────────────────────────────────────
_WEB_STATUS_FILE="${TMPDIR:-/tmp}/.lodge-web-status-$$.tmp"
_WEB_CTYPE_FILE="${TMPDIR:-/tmp}/.lodge-web-ctype-$$.tmp"
web_fetch_raw() {
    local url="$1" _hdr_file="${TMPDIR:-/tmp}/.lodge-web-hdr-$$.tmp"
    local html; html=$(_web_curl --max-time "$WEB_TIMEOUT" --max-filesize "$WEB_MAX_SIZE" -D "$_hdr_file" -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" "$url" 2>/dev/null | head -c "$WEB_MAX_SIZE")
    local _curl_rc=$? _status="" _content_type=""
    if [ -f "$_hdr_file" ]; then
        _status=$(sed -n 's/.*HTTP\/[0-9.]* \([0-9]\{3\}\).*/\1/p' "$_hdr_file" 2>/dev/null | tail -1)
        _content_type=$(grep -i '^content-type:' "$_hdr_file" 2>/dev/null | tail -1 | sed 's/^[Cc]ontent-[Tt]ype:[[:space:]]*//' | tr -d '\r')
        rm -f "$_hdr_file"
    fi
    if [ -z "$html" ] && [ -z "$_status" ]; then
        sleep 1
        html=$(_web_curl --max-time "$WEB_TIMEOUT" --max-filesize "$WEB_MAX_SIZE" -D "$_hdr_file" -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" "$url" 2>/dev/null | head -c "$WEB_MAX_SIZE")
        _curl_rc=$?
        if [ -f "$_hdr_file" ]; then
            _status=$(sed -n 's/.*HTTP\/[0-9.]* \([0-9]\{3\}\).*/\1/p' "$_hdr_file" 2>/dev/null | tail -1)
            _content_type=$(grep -i '^content-type:' "$_hdr_file" 2>/dev/null | tail -1 | sed 's/^[Cc]ontent-[Tt]ype:[[:space:]]*//' | tr -d '\r')
            rm -f "$_hdr_file"
        fi
    fi
    if [ "$_curl_rc" -ne 0 ] && [ -z "$html" ]; then
        case "$_curl_rc" in
            6) _status="DNS_FAIL" ;; 7) _status="CONN_REFUSED" ;; 28) _status="TIMEOUT" ;; 35) _status="SSL_ERROR" ;; 56) _status="RECV_ERROR" ;; 63) _status="MAX_SIZE" ;; *) _status="CURL_ERR_$_curl_rc" ;;
        esac
        echo "$_status" > "$_WEB_STATUS_FILE" 2>/dev/null
        return 1
    fi
    if [[ "$_status" =~ ^[0-9]+$ ]] && [ "$_status" -ge 400 ]; then
        local _reason; _reason=$(_web_block_reason "$_status" "$html")
        if [ -n "$_reason" ]; then
            if [[ "$_reason" == "HTML_CHALLENGE_OR_CAPTCHA" || "$_reason" == "HTTP_403_FORBIDDEN" || "$_reason" == "HTTP_429_RATE_LIMIT" ]]; then
                _web_greylist_add "$(echo "$url" | sed 's|^https\?://||' | cut -d'/' -f1)" "$_reason"
                echo "BLOCKED_GREYLIST:${_reason}:${_status}" > "$_WEB_STATUS_FILE" 2>/dev/null
            else
                _web_blacklist_add "$url" "$_reason" "$_status"
                echo "BLOCKED:${_reason}:${_status}" > "$_WEB_STATUS_FILE" 2>/dev/null
            fi
        else echo "$_status" > "$_WEB_STATUS_FILE" 2>/dev/null; fi
        return 1
    fi
    local _html_reason; _html_reason=$(_web_block_reason "${_status:-200}" "$html")
    if [ -n "$_html_reason" ]; then
        if [[ "$_html_reason" == "HTML_CHALLENGE_OR_CAPTCHA" ]]; then
            _web_greylist_add "$(echo "$url" | sed 's|^https\?://||' | cut -d'/' -f1)" "$_html_reason"
            echo "BLOCKED_GREYLIST:${_html_reason}:${_status:-200}" > "$_WEB_STATUS_FILE" 2>/dev/null
        else
            _web_blacklist_add "$url" "$_html_reason" "${_status:-200}"
            echo "BLOCKED:${_html_reason}:${_status:-200}" > "$_WEB_STATUS_FILE" 2>/dev/null
        fi
        return 1
    fi
    echo "${_status:-200}" > "$_WEB_STATUS_FILE" 2>/dev/null
    echo "$_content_type" > "$_WEB_CTYPE_FILE" 2>/dev/null
    echo "$html"
}

# ── HTML preprocessor ──────────────────────────────────────────
_html_preprocess() {
    sed 's/>/>\n/g' | awk '
    BEGIN { skip = 0 }
    /<script/ { skip = 1 } /<\/script>/ { skip = 0; next }
    /<style/ { skip = 1 } /<\/style>/ { skip = 0; next }
    /<noscript/ { skip = 1 } /<\/noscript>/ { skip = 0; next }
    /<header[^a-z]/ { skip = 1 } /<\/header>/ { skip = 0; next }
    /<aside/ { skip = 1 } /<\/aside>/ { skip = 0; next }
    skip { next }
    {
        gsub(/<[^>]*>/, ""); gsub(/&nbsp;/, " "); gsub(/&amp;/, "\\&"); gsub(/&lt;/, "<"); gsub(/&gt;/, ">"); gsub(/&quot;/, "\""); gsub(/&#39;/, "\x27"); gsub(/&#[0-9]+;/, "")
        gsub(/^[[:space:]]+/, ""); gsub(/[[:space:]]+$/, "")
        if (length($0) > 0) print
    }'
}

# ── Strip web boilerplate from extracted text ──────────────────
_web_strip_boilerplate() {
    awk '
    BEGIN { skip_run = 0 }
    /^Skip to (content|main|navigation)/ || /^Toggle navigation/ || /^Navigation Menu/ || /^Sign in$/ || /^Sign up$/ || /^Log in$/ || /^Log out$/ || /^Search$/ || /^Clear$/ || /^Cancel$/ || /^Search or jump to/ || /^Search code, repositories/ || /^Search syntax tips/ || /^Provide feedback/ || /^Submit feedback/ || /^Saved searches/ || /^Create saved search/ || /^Use saved searches/ || /^Cancel Submit/ || /^Appearance settings/ || /^Resetting focus/ || /^You signed in with another tab/ || /^You signed out in another tab/ || /^You switched accounts on another tab/ || /^Reload to refresh your session/ || /^Dismiss alert/ || /^\{\{ message \}\}/ { next }
    /^(Accept|Reject|Manage) (all )?(cookies|preferences)/ || /^(We|This site|This website) use[s]? cookies/ || /^Cookie (policy|settings|preferences|consent)/ || (/^By (continuing|using this)/ && /cookies/) { next }
    /^(©|Ⓒ) [0-9][0-9][0-9][0-9]/ || /^Copyright [0-9][0-9][0-9][0-9]/ || /^All rights reserved/ || (/^Terms (of (Service|Use)|and Conditions)/ && length($0) < 60) || /^Privacy Policy$/ || /^Terms$/ || /^Privacy$/ || /^Legal$/ || /^Sitemap$/ { next }
    /^[[:space:]]*$/ || (length($0) <= 2 && !/^[0-9]/) {
        if (!skip_run) { print ""; skip_run = 1 }
        next
    }
    { skip_run = 0; print }'
}

# ── Truncate text to WEB_CONTENT_MAX_CHARS ─────────────────────
_web_truncate_content() {
    local max="${WEB_CONTENT_MAX_CHARS:-4000}" input; input=$(cat)
    if [ "${#input}" -le "$max" ]; then printf '%s' "$input"
    else
        local trimmed="${input:0:$max}"
        [[ "$trimmed" == *$'\n'* ]] && trimmed="${trimmed%$'\n'*}"
        printf '%s' "$trimmed"
    fi
}

# ── Pure POSIX Bash / Awk Web Scraper Fallback ─────────────────
web_scrape_pure_bash() {
    local target="${1:-}" max_lines="${2:-500}" raw_html=""
    if [ -n "$target" ] && [[ "$target" =~ ^https?:// ]]; then
        raw_html=$(_web_curl --max-time "${WEB_TIMEOUT:-10}" --max-filesize "${WEB_MAX_SIZE:-524288}" "$target" 2>/dev/null || true)
    elif [ -n "$target" ] && [ -f "$target" ]; then
        raw_html=$(cat "$target" 2>/dev/null || true)
    else
        raw_html=$(cat 2>/dev/null || true)
    fi
    [ -z "$raw_html" ] && return 1
    echo "$raw_html" | awk '
    BEGIN { RS = "<"; FS = ">"; skip = 0 }
    NR == 1 { next }
    {
        tag = tolower($1); sub(/[ \t\r\n].*$/, "", tag)
        if (tag ~ /^(script|style|noscript|svg|head|path|template)$/) { skip = 1; next }
        if (tag ~ /^\/(script|style|noscript|svg|head|path|template)$/) { skip = 0; next }
        if (skip) next
        if (NF >= 2) {
            text = $0; sub(/^[^>]*>/, "", text)
            gsub(/&nbsp;/, " ", text); gsub(/&amp;/, "\\&", text); gsub(/&lt;/, "<", text); gsub(/&gt;/, ">", text); gsub(/&quot;/, "\"", text); gsub(/&#39;/, "\x27", text); gsub(/&mdash;/, "—", text); gsub(/&ndash;/, "–", text); gsub(/&hellip;/, "...", text); gsub(/&#[0-9]+;/, "", text); gsub(/[ \t\r\n]+/, " ", text)
            sub(/^[ ]+/, "", text); sub(/[ ]+$/, "", text)
            if (length(text) > 3) print text
        }
    }' | _web_strip_boilerplate | head -n "$max_lines"
}

# ── Strip HTML to plain text ──────────────────────────────────
_html_to_text_sed() { web_scrape_pure_bash "" 500; }

_html_to_text() {
    case "$(_web_renderer)" in
        w3m) w3m -dump -T text/html -cols 100 2>/dev/null | head -500 ;;
        lynx) lynx -dump -stdin -width=100 -nolist 2>/dev/null | head -500 ;;
        html2text) html2text -utf8 2>/dev/null | head -500 ;;
        sed) _html_to_text_sed ;;
    esac
}

# ── Extract page title from HTML ──────────────────────────────
_html_extract_title() {
    sed -n 's/.*<title>\([^<]*\)<\/title>.*/\1/p' | head -1 | sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#39;/'"'"'/g'
}

# ── Extract structured content from HTML ───────────────────────
_html_extract_content() {
    _raw=$(sed 's/>/>\n/g' | awk '
        BEGIN { skip = 0 }
        tolower($0) ~ /<(script|style|noscript)/ { skip = 1 }
        tolower($0) ~ /<\/(script|style|noscript)>/ { skip = 0; next }
        skip { next } { print }')
    local _focused="" _article_count=0
    _article_count=$(printf '%s\n' "$_raw" | grep -ciE '<article[ >]' || true)
    if [ "$_article_count" -eq 1 ]; then
        _focused=$(printf '%s\n' "$_raw" | awk 'tolower($0) ~ /<article/ { inside = 1 } inside { print } tolower($0) ~ /<\/article>/ { inside = 0 }')
        if [ -n "$_focused" ] && [ "$(printf '%s' "$_focused" | wc -c)" -ge 200 ]; then _raw="$_focused"; else _focused=""; fi
    fi
    if [ -z "$_focused" ]; then
        _focused=$(_html_extract_by_class_id "$_raw")
        if [ -n "$_focused" ] && [ "$(printf '%s' "$_focused" | wc -c)" -ge 200 ]; then _raw="$_focused"; else _focused=""; fi
    fi
    if [ -z "$_focused" ]; then
        _focused=$(printf '%s\n' "$_raw" | awk 'tolower($0) ~ /<main/ { inside = 1 } inside { print } tolower($0) ~ /<\/main>/ { inside = 0 }')
        if [ -n "$_focused" ] && [ "$(printf '%s' "$_focused" | wc -c)" -ge 200 ]; then _raw="$_focused"; else _focused=""; fi
    fi
    if [ -z "$_focused" ]; then
        _focused=$(_html_score_blocks "$_raw")
        if [ -n "$_focused" ] && [ "$(printf '%s' "$_focused" | wc -c)" -ge 200 ]; then _raw="$_focused"; fi
    fi
    printf '%s\n' "$_raw" | awk '
    BEGIN { skip = 0 }
    /<script/ { skip = 1 } /<\/script>/ { skip = 0; next }
    /<style/ { skip = 1 } /<\/style>/ { skip = 0; next }
    /<noscript/ { skip = 1 } /<\/noscript>/ { skip = 0; next }
    /<nav/ { skip = 1 } /<\/nav>/ { skip = 0; next }
    /<header[^a-z]/ { skip = 1 } /<\/header>/ { skip = 0; next }
    /<footer/ { skip = 1 } /<\/footer>/ { skip = 0; next }
    /<aside/ { skip = 1 } /<\/aside>/ { skip = 0; next }
    skip { next }
    {
        gsub(/<[^>]*>/, ""); gsub(/&nbsp;/, " "); gsub(/&amp;/, "\\&"); gsub(/&lt;/, "<"); gsub(/&gt;/, ">"); gsub(/&quot;/, "\""); gsub(/&#39;/, "\x27"); gsub(/&mdash;/, "\xe2\x80\x94"); gsub(/&ndash;/, "\xe2\x80\x93"); gsub(/&hellip;/, "..."); gsub(/&apos;/, "\x27"); gsub(/&#[0-9]+;/, "")
        gsub(/^[[:space:]]+/, ""); gsub(/[[:space:]]+$/, "")
        if (length($0) > 2) print
    }' | head -300
}

# ── Tier 1.5: Class/ID-aware block extraction ─────────────────
_html_extract_by_class_id() {
    printf '%s\n' "$1" | awk '
    BEGIN {
        split("article-body,post-content,entry-content,story-body,main-content,page-content,article-text,blog-post,content-area,single-post,td-post-content,mw-parser-output,mw-content-text,post-body,article-content,node-content,field-item,prose,markdown-body,rich-text,text-content,body-content", pos, ",")
        for (i in pos) positive[pos[i]] = 1
        found = 0; depth = 0; buf = ""
    }
    !found {
        line = tolower($0)
        if (line ~ /<(div|section)[^>]*(class|id)=/) {
            attr = line; gsub(/.*class="/, "", attr); gsub(/.*id="/, "", attr); gsub(/".*/, "", attr)
            for (p in positive) {
                if (index(attr, p) > 0) { found = 1; depth = 1; buf = $0; next }
            }
        }
    }
    found {
        if (NR > 1 || buf == "") buf = buf "\n" $0
        line = tolower($0)
        depth += (split(line, tmp, /<(div|section)[ >]/) - 1)
        depth -= (split(line, tmp, /<\/(div|section)>/) - 1)
        if (depth <= 0) { print buf; exit }
    }'
}

# ── Tier 3: Content density scoring ───────────────────────────
_html_score_blocks() {
    printf '%s\n' "$1" | awk '
    BEGIN { best_score = 0; best_block = ""; cur_block = ""; in_block = 0; depth = 0 }
    tolower($0) ~ /<(div|section)[ >]/ && !in_block { in_block = 1; depth = 1; cur_block = $0; next }
    in_block {
        cur_block = cur_block "\n" $0
        line = tolower($0)
        depth += (split(line, tmp, /<(div|section)[ >]/) - 1)
        depth -= (split(line, tmp, /<\/(div|section)>/) - 1)
        if (depth <= 0) {
            in_block = 0
            text_buf = cur_block; gsub(/<script[^>]*>.*<\/script>/, "", text_buf); gsub(/<style[^>]*>.*<\/style>/, "", text_buf)
            tag_chars = length(text_buf); n = split(text_buf, pieces, /<[^>]*>/)
            for (i in pieces) tag_chars -= length(pieces[i])
            if (tag_chars < 1) tag_chars = 1
            text_only = text_buf; gsub(/<[^>]*>/, "", text_only); gsub(/&[a-z]+;|&#[0-9]+;/, " ", text_only); gsub(/[[:space:]]+/, " ", text_only)
            text_len = length(text_only)
            if (text_len >= 100) {
                ratio = text_len / tag_chars; if (ratio > 5) ratio = 5
                p_count = split(tolower(cur_block), tmp, /<p[ >]/) - 1; if (p_count < 0) p_count = 0
                link_text = cur_block; gsub(/<a[^>]*>/, "\x01", link_text); gsub(/<\/a>/, "\x02", link_text); gsub(/<[^>]*>/, "", link_text)
                lt = 0; in_link = 0
                for (i = 1; i <= length(link_text); i++) {
                    c = substr(link_text, i, 1)
                    if (c == "\x01") in_link = 1; else if (c == "\x02") in_link = 0; else if (in_link) lt++
                }
                link_density = (text_len > 0) ? lt / text_len : 1
                link_penalty = 1 - link_density; if (link_penalty < 0.1) link_penalty = 0.1
                comma_count = gsub(/,/, ",", text_only)
                score = ((ratio * 10) + (p_count * 3) + (comma_count * 0.5)) * link_penalty
                if (score > best_score) { best_score = score; best_block = cur_block }
            }
            cur_block = ""
        }
    }
    END { if (best_block != "") print best_block }'
}

# ── Extract image URLs from HTML (content areas only) ──────────
_html_extract_images() {
    local base_url="$1" html; html=$(cat)
    local _img_exts='jpg|jpeg|png|gif|webp|bmp|svg|avif|tiff'
    {
        echo "$html" | grep -oiE '<img[^>]*>' | grep -oE '(src|data-src|data-lazy-src)="[^"]+"' | sed 's/^[^"]*"//;s/"$//'
        echo "$html" | grep -oiE '<img[^>]*>' | grep -oE 'srcset="[^"]+"' | sed 's/^srcset="//;s/"$//' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/ [0-9]*[wx].*$//'
        echo "$html" | grep -oiE '<source[^>]*>' | grep -oE 'srcset="[^"]+"' | sed 's/^srcset="//;s/"$//' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/ [0-9]*[wx].*$//'
        echo "$html" | grep -oiE '<meta[^>]+(og:image|twitter:image)[^>]*>' | grep -oE 'content="[^"]+"' | sed 's/^content="//;s/"$//'
        echo "$html" | grep -oiE '<link[^>]+rel="image_src"[^>]*>' | grep -oE 'href="[^"]+"' | sed 's/^href="//;s/"$//'
    } | sort -u | while IFS= read -r img_url; do
        [ -z "$img_url" ] && continue
        [[ "$img_url" == data:* || "$img_url" == javascript:* ]] && continue
        if [[ "$img_url" == //* ]]; then img_url="https:$img_url"
        elif [[ "$img_url" == /* ]]; then img_url="${base_url}${img_url}"
        elif [[ "$img_url" != http* ]]; then continue; fi
        [[ "$img_url" =~ \.(css|js|map|woff2?|ttf|eot|json|xml)(\?|$) ]] && continue
        local safe_url; safe_url=$(_web_sanitize_url "$img_url")
        [ -n "$safe_url" ] && echo "$safe_url"
    done | head -20
}

# ── GitHub repo URL detection ──────────────────────────────────
_web_github_repo_slug() {
    local url="${1%/}"
    url="${url%.git}"
    echo "$url" | sed -n 's|^https\?://github\.com/\([a-zA-Z0-9_.-]\+/[a-zA-Z0-9_.-]\+\)$|\1|p'
}

# ── Fetch GitHub repo README via API ───────────────────────────
_web_fetch_github_readme() {
    local slug="$1"
    local api_url="https://api.github.com/repos/${slug}/readme"
    local resp; resp=$(curl -sL --max-time "${WEB_TIMEOUT:-15}" -H "Accept: application/vnd.github.v3+json" -H "User-Agent: Blue-Lodge-George/0.1" "$api_url" 2>/dev/null)
    [ -z "$resp" ] && return 1
    local msg; msg=$(echo "$resp" | jq -r '.message // empty' 2>/dev/null)
    [ -n "$msg" ] && return 1
    local readme="" encoding; encoding=$(echo "$resp" | jq -r '.encoding // empty' 2>/dev/null)
    [ "$encoding" = "base64" ] && readme=$(echo "$resp" | jq -r '.content // empty' 2>/dev/null | base64 -d 2>/dev/null)
    if [ -z "$readme" ]; then
        local dl; dl=$(echo "$resp" | jq -r '.download_url // empty' 2>/dev/null)
        [ -z "$dl" ] && return 1
        readme=$(curl -sL --max-time "${WEB_TIMEOUT:-15}" -H "User-Agent: Blue-Lodge-George/0.1" "$dl" 2>/dev/null)
        [ -z "$readme" ] && return 1
    fi
    local repo_resp repo_desc="" repo_stars=0 repo_lang="Unknown" repo_topics=""
    repo_resp=$(curl -sL --max-time "${WEB_TIMEOUT:-15}" -H "Accept: application/vnd.github.v3+json" -H "User-Agent: Blue-Lodge-George/0.1" "https://api.github.com/repos/${slug}" 2>/dev/null)
    if [ -n "$repo_resp" ]; then
        repo_desc=$(echo "$repo_resp" | jq -r '.description // "No description"' 2>/dev/null)
        repo_stars=$(echo "$repo_resp" | jq -r '.stargazers_count // 0' 2>/dev/null)
        repo_lang=$(echo "$repo_resp" | jq -r '.language // "Unknown"' 2>/dev/null)
        repo_topics=$(echo "$repo_resp" | jq -r '(.topics // []) | join(", ")' 2>/dev/null)
    fi
    printf '[GitHub: %s] ★%s | %s\n' "$slug" "${repo_stars:-0}" "${repo_lang:-Unknown}"
    [ -n "$repo_desc" ] && [ "$repo_desc" != "No description" ] && printf 'Description: %s\n' "$repo_desc"
    [ -n "$repo_topics" ] && [ "$repo_topics" != "" ] && printf 'Topics: %s\n' "$repo_topics"
    printf '\n--- README ---\n%s\n' "$readme"
}

# ── Reddit URL detection ───────────────────────────────────────
_web_reddit_url() {
    local url="${1%%\?*}"
    url="${url%/}"
    if [[ "$url" =~ ^https?://(www\.|old\.|new\.)?reddit\.com/r/([a-zA-Z0-9_]+)/comments/([a-z0-9]+) ]]; then
        echo "post:${BASH_REMATCH[2]}:${BASH_REMATCH[3]}"
    elif [[ "$url" =~ ^https?://(www\.|old\.|new\.)?reddit\.com/r/([a-zA-Z0-9_]+)$ ]]; then
        echo "sub:${BASH_REMATCH[2]}"
    fi
}

# ── Fetch Reddit post or subreddit via JSON API ───────────────
_web_fetch_reddit() {
    local url="$1" _rinfo; _rinfo=$(_web_reddit_url "$url")
    [ -z "$_rinfo" ] && return 1
    local _rtype="${_rinfo%%:*}" _rrest="${_rinfo#*:}"
    local _json_url; _json_url=$(echo "$url" | sed 's|/*$||; s|\?.*$||; s|#.*$||').json
    local _raw; _raw=$(curl -sL --max-time "${WEB_TIMEOUT:-15}" -A "Blue-Lodge-George/0.1 (by /u/george-agent)" -H "Accept: application/json" "$_json_url" 2>/dev/null)
    if [ -z "$_raw" ] || ! echo "$_raw" | jq empty 2>/dev/null; then
        # Blocked / JS proof-of-work interstitial → solver (PoshTracker port) with session cookie jar
        _raw=$(GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}" python3 "$LODGE_DIR/lib/tools/challenge_solver.py" reddit-json "${_json_url/http:/https:}" 2>/dev/null)
    fi
    [ -z "$_raw" ] && return 1
    echo "$_raw" | jq empty 2>/dev/null || return 1
    if [ "$_rtype" = "post" ]; then
        local _sub="${_rrest%%:*}" _title _author _score _selftext _url_link
        _title=$(echo "$_raw" | jq -r '.[0].data.children[0].data.title // "untitled"' 2>/dev/null)
        _author=$(echo "$_raw" | jq -r '.[0].data.children[0].data.author // "unknown"' 2>/dev/null)
        _score=$(echo "$_raw" | jq -r '.[0].data.children[0].data.score // 0' 2>/dev/null)
        _selftext=$(echo "$_raw" | jq -r '.[0].data.children[0].data.selftext // ""' 2>/dev/null)
        _url_link=$(echo "$_raw" | jq -r '.[0].data.children[0].data.url // ""' 2>/dev/null)
        printf '[Reddit: r/%s] %s\nBy u/%s | Score: %s\n' "$_sub" "$_title" "$_author" "$_score"
        if [ -n "$_selftext" ] && [ "$_selftext" != "null" ] && [ "$_selftext" != "" ]; then printf '\n---\n%s\n' "$_selftext"
        elif [ -n "$_url_link" ] && [ "$_url_link" != "null" ] && [[ "$_url_link" != *"reddit.com"* ]]; then printf 'Link: %s\n' "$_url_link"; fi
        local _num_comments; _num_comments=$(echo "$_raw" | jq '.[1].data.children | map(select(.kind == "t1")) | length' 2>/dev/null || echo 0)
        [ "${_num_comments:-0}" -gt 10 ] && _num_comments=10
        if [ "${_num_comments:-0}" -gt 0 ]; then
            printf '\n--- Top Comments ---\n'
            for _ci in $(seq 0 $((_num_comments - 1))); do
                local _cauthor _cbody _cscore
                _cauthor=$(echo "$_raw" | jq -r "[.[1].data.children[] | select(.kind == \"t1\")][$_ci].data.author // \"\"" 2>/dev/null)
                _cbody=$(echo "$_raw" | jq -r "[.[1].data.children[] | select(.kind == \"t1\")][$_ci].data.body // \"\"" 2>/dev/null)
                _cscore=$(echo "$_raw" | jq -r "[.[1].data.children[] | select(.kind == \"t1\")][$_ci].data.score // 0" 2>/dev/null)
                [ -z "$_cauthor" ] || [ "$_cauthor" = "null" ] || [ -z "$_cbody" ] || [ "$_cbody" = "null" ] && continue
                [ ${#_cbody} -gt 500 ] && _cbody="${_cbody:0:497}..."
                printf '\n  u/%s (%s):\n  %s\n' "$_cauthor" "$_cscore" "$_cbody"
            done
        fi
    else
        local _sub="${_rrest}" _num_posts; _num_posts=$(echo "$_raw" | jq '.data.children | length' 2>/dev/null || echo 0)
        [ "${_num_posts:-0}" -gt 15 ] && _num_posts=15
        printf '[Reddit: r/%s] Top %d Posts\n---\n' "$_sub" "$_num_posts"
        for _pi in $(seq 0 $((_num_posts - 1))); do
            local _ptitle _pauthor _pscore _ppermalink
            _ptitle=$(echo "$_raw" | jq -r ".data.children[$_pi].data.title // \"\"" 2>/dev/null)
            _pauthor=$(echo "$_raw" | jq -r ".data.children[$_pi].data.author // \"\"" 2>/dev/null)
            _pscore=$(echo "$_raw" | jq -r ".data.children[$_pi].data.score // 0" 2>/dev/null)
            _ppermalink=$(echo "$_raw" | jq -r ".data.children[$_pi].data.permalink // \"\"" 2>/dev/null)
            [ -z "$_ptitle" ] || [ "$_ptitle" = "null" ] && continue
            printf '  %s↑ %s — u/%s\n' "$_pscore" "$_ptitle" "$_pauthor"
            [ -n "$_ppermalink" ] && [ "$_ppermalink" != "null" ] && printf '    https://reddit.com%s\n' "$_ppermalink"
        done
    fi
}

_web_fetch_reddit_json() {
    local url="$1" _rinfo; _rinfo=$(_web_reddit_url "$url")
    [ -z "$_rinfo" ] && return 1
    local _rtype="${_rinfo%%:*}" _rrest="${_rinfo#*:}"
    local _json_url; _json_url=$(echo "$url" | sed 's|/*$||; s|\?.*$||; s|#.*$||').json
    local _raw; _raw=$(curl -sL --max-time "${WEB_TIMEOUT:-15}" -A "Blue-Lodge-George/0.1 (by /u/george-agent)" -H "Accept: application/json" "$_json_url" 2>/dev/null)
    if [ -z "$_raw" ] || ! echo "$_raw" | jq empty 2>/dev/null; then
        # Blocked / JS proof-of-work interstitial → solver (PoshTracker port) with session cookie jar
        _raw=$(GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}" python3 "$LODGE_DIR/lib/tools/challenge_solver.py" reddit-json "${_json_url/http:/https:}" 2>/dev/null)
    fi
    [ -z "$_raw" ] && return 1
    echo "$_raw" | jq empty 2>/dev/null || return 1
    local _title="" _content="" _images_json="[]"
    if [ "$_rtype" = "post" ]; then
        local _sub="${_rrest%%:*}" _author _score _selftext _url_link
        _title="[Reddit: r/${_sub}] $(echo "$_raw" | jq -r '.[0].data.children[0].data.title // "untitled"' 2>/dev/null)"
        _author=$(echo "$_raw" | jq -r '.[0].data.children[0].data.author // "unknown"' 2>/dev/null)
        _score=$(echo "$_raw" | jq -r '.[0].data.children[0].data.score // 0' 2>/dev/null)
        _selftext=$(echo "$_raw" | jq -r '.[0].data.children[0].data.selftext // ""' 2>/dev/null)
        _url_link=$(echo "$_raw" | jq -r '.[0].data.children[0].data.url // ""' 2>/dev/null)
        _content="By u/${_author} | Score: ${_score}"
        if [ -n "$_selftext" ] && [ "$_selftext" != "null" ] && [ "$_selftext" != "" ]; then _content="${_content}"$'\n\n'"${_selftext}"
        elif [ -n "$_url_link" ] && [ "$_url_link" != "null" ] && [[ "$_url_link" != *"reddit.com"* ]]; then _content="${_content}"$'\n'"Link: ${_url_link}"; fi
        local _num_comments; _num_comments=$(echo "$_raw" | jq '.[1].data.children | map(select(.kind == "t1")) | length' 2>/dev/null || echo 0)
        [ "${_num_comments:-0}" -gt 10 ] && _num_comments=10
        if [ "${_num_comments:-0}" -gt 0 ]; then
            _content="${_content}"$'\n\n--- Top Comments ---'
            for _ci in $(seq 0 $((_num_comments - 1))); do
                local _cauthor _cbody _cscore
                _cauthor=$(echo "$_raw" | jq -r "[.[1].data.children[] | select(.kind == \"t1\")][$_ci].data.author // \"\"" 2>/dev/null)
                _cbody=$(echo "$_raw" | jq -r "[.[1].data.children[] | select(.kind == \"t1\")][$_ci].data.body // \"\"" 2>/dev/null)
                _cscore=$(echo "$_raw" | jq -r "[.[1].data.children[] | select(.kind == \"t1\")][$_ci].data.score // 0" 2>/dev/null)
                [ -z "$_cauthor" ] || [ "$_cauthor" = "null" ] || [ -z "$_cbody" ] || [ "$_cbody" = "null" ] && continue
                [ ${#_cbody} -gt 500 ] && _cbody="${_cbody:0:497}..."
                _content="${_content}"$'\n\n'"  u/${_cauthor} (${_cscore}):"$'\n'"  ${_cbody}"
            done
        fi
        _images_json=$(echo "$_raw" | jq -c '[ .[0].data.children[0].data | (.preview.images[]?.source.url // empty), (.thumbnail | select(startswith("http")) // empty), (.url | select(test("\\.(jpg|jpeg|png|gif|webp)(\\?|$)")) // empty) ] | map(gsub("&amp;"; "&")) | unique' 2>/dev/null || echo "[]")
    else
        local _sub="${_rrest}" _num_posts; _num_posts=$(echo "$_raw" | jq '.data.children | length' 2>/dev/null || echo 0)
        [ "${_num_posts:-0}" -gt 15 ] && _num_posts=15
        _title="[Reddit: r/${_sub}] Top Posts"; _content=""
        for _pi in $(seq 0 $((_num_posts - 1))); do
            local _ptitle _pauthor _pscore _ppermalink
            _ptitle=$(echo "$_raw" | jq -r ".data.children[$_pi].data.title // \"\"" 2>/dev/null)
            _pauthor=$(echo "$_raw" | jq -r ".data.children[$_pi].data.author // \"\"" 2>/dev/null)
            _pscore=$(echo "$_raw" | jq -r ".data.children[$_pi].data.score // 0" 2>/dev/null)
            _ppermalink=$(echo "$_raw" | jq -r ".data.children[$_pi].data.permalink // \"\"" 2>/dev/null)
            [ -z "$_ptitle" ] || [ "$_ptitle" = "null" ] && continue
            _content="${_content}${_pscore}↑ ${_ptitle} — u/${_pauthor}"
            [ -n "$_ppermalink" ] && [ "$_ppermalink" != "null" ] && _content="${_content}"$'\n'"  https://reddit.com${_ppermalink}"
            _content="${_content}"$'\n'
        done
        _images_json=$(echo "$_raw" | jq -c '[ .data.children[].data.thumbnail | select(startswith("http")) ] | unique' 2>/dev/null || echo "[]")
    fi
    jq -n --arg url "$url" --arg title "$_title" --arg content "$_content" --argjson images "${_images_json:-[]}" '{"url":$url,"title":$title,"content":$content,"images":$images}'
}

# ── Sanitize URL of trailing/leading markdown and punctuation delimiters ──
web_clean_url() {
    local u="$1"
    while [[ -n "$u" ]]; do
        case "${u: -1}" in
            ']'|'\'|')'|'>'|'"'|"'"|'`'|','|';'|'.'|' ')
                u="${u:0:-1}"
                ;;
            *)
                break
                ;;
        esac
    done
    while [[ -n "$u" ]]; do
        case "${u:0:1}" in
            '['|'('|'<'|'"'|"'"|'`'|' ')
                u="${u:1}"
                ;;
            *)
                break
                ;;
        esac
    done
    echo "$u"
}

# ── Fetch a URL and return clean text ─────────────────────────
web_fetch() {
    local url
    url=$(web_clean_url "$1")
    [ -z "$url" ] && return 1
    if _web_blacklist_contains "$url"; then
        ui_err "URL is blacklisted from prior block/challenge: $url (reason: $(_web_blacklist_reason "$url" || echo unknown))" >&2
        return 1
    fi
    if _web_greylist_contains "$url"; then
        local fb; fb=$(_web_greylist_fallback "$url")
        if [ $? -eq 0 ]; then
            local fbc; fbc=$(echo "$fb" | jq -r '.content // empty')
            [ -n "$fbc" ] && { echo "$fbc"; return 0; }
        fi
        ui_warn "URL is grey-listed (known paywall/CAPTCHA) and not found in recent search cache: $url. Please run /web search first to index the snippet." >&2
        return 1
    fi
    local cache_key; cache_key=$(printf '%s' "$url" | md5sum 2>/dev/null | cut -d' ' -f1 || printf '%s' "$url" | cksum | cut -d' ' -f1)
    local cache_file="$GEORGE_CACHE_DIR/web_${cache_key}"
    if [ -f "$cache_file" ]; then
        local age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
        [ "$age" -lt "$WEB_CACHE_TTL" ] && { cat "$cache_file"; return 0; }
    fi
    local _gh_slug; _gh_slug=$(_web_github_repo_slug "$url")
    if [ -n "$_gh_slug" ]; then
        local _gh_content; _gh_content=$(_web_fetch_github_readme "$_gh_slug")
        if [ -n "$_gh_content" ]; then
            _gh_content=$(echo "$_gh_content" | _web_truncate_content)
            mkdir -p "$GEORGE_CACHE_DIR" && echo "$_gh_content" > "$cache_file" 2>/dev/null
            echo "$_gh_content"; return 0
        fi
    fi
    local _rd_info; _rd_info=$(_web_reddit_url "$url")
    if [ -n "$_rd_info" ]; then
        local _rd_content; _rd_content=$(_web_fetch_reddit "$url")
        if [ -n "$_rd_content" ]; then
            _rd_content=$(echo "$_rd_content" | _web_truncate_content)
            mkdir -p "$GEORGE_CACHE_DIR" && echo "$_rd_content" > "$cache_file" 2>/dev/null
            echo "$_rd_content"; return 0
        fi
    fi
    if declare -f mcp_enabled &>/dev/null && mcp_enabled; then
        local mcp_body; mcp_body=$(mcp_web_fetch "$url" 2>/dev/null)
        if [ -n "$mcp_body" ]; then
            mcp_body=$(echo "$mcp_body" | _web_strip_boilerplate | _web_truncate_content)
            mkdir -p "$GEORGE_CACHE_DIR" && echo "$mcp_body" > "$cache_file" 2>/dev/null
            echo "$mcp_body"; return 0
        fi
    fi
    if ! _web_dns_precheck "$url"; then
        local _dns_host; _dns_host=$(echo "$url" | sed 's|^https\?://||' | cut -d'/' -f1 | cut -d':' -f1)
        ui_err "DNS pre-check failed for $url — hostname '$_dns_host' does not resolve. URL may not exist. Use /web search to find real URLs." >&2
        _web_blacklist_add "$url" "DNS_PRECHECK_FAIL" "DNS_FAIL"; return 1
    fi
    local _url_guess; _url_guess=$(_web_guess_content_type "$url")
    case "$_url_guess" in
        pdf)
            ui_dim "Fetching PDF: $url" >&2
            local pdf_text; pdf_text=$(_web_extract_pdf "$url")
            [ -z "$pdf_text" ] && { ui_err "Failed to extract PDF: $url" >&2; return 1; }
            mkdir -p "$GEORGE_CACHE_DIR" && echo "$pdf_text" > "$cache_file" 2>/dev/null
            echo "$pdf_text"; return 0 ;;
        binary)
            local _filename; _filename=$(basename "$url" | sed 's/[?#].*//')
            [ -z "$_filename" ] || [ "$_filename" = "/" ] && _filename="downloaded_binary"
            _filename=$(echo "$_filename" | sed 's/["'"'"'`]//g' | tr ' ' '-' | sed 's/[^a-zA-Z0-9_./-]//g')
            local _dest="./$_filename"
            ui_info "Detected binary file. Downloading to $_dest..." >&2
            if curl -fsSL -o "$_dest" "$url" 2>&1; then
                ui_ok "Successfully downloaded binary file to $_dest ($(wc -c < "$_dest" 2>/dev/null || echo 0) bytes)" >&2
                case "$_filename" in *.jpg|*.jpeg|*.png|*.gif|*.webp|*.bmp|*.ico) echo "Downloaded image file to $_dest. Use the /vision command to analyze it: /vision $_dest" ;; *) echo "Downloaded binary file to $_dest." ;; esac
                return 0
            else ui_err "Failed to download binary file: $url" >&2; return 1; fi ;;
    esac
    ui_dim "Fetching: $url" >&2
    local body; body=$(web_fetch_raw "$url")
    if [ -z "$body" ]; then
        local _reason="unknown"; [ -f "$_WEB_STATUS_FILE" ] && _reason=$(cat "$_WEB_STATUS_FILE" 2>/dev/null)
        local err_sig=""
        case "$_reason" in
            BLOCKED:*)
                err_sig="[FETCH FAILED | CLOUDFLARE_CHALLENGE / PAYWALL | URL: $url | Action: Blocked by challenge or paywall; use search snippet or alternate domain]"
                ui_err "Blocked by target site: $url (reason: $(echo "$_reason" | cut -d':' -f2))" >&2 ;;
            DNS_FAIL)
                err_sig="[FETCH FAILED | DNS_NOT_RESOLVED | URL: $url | Action: Hostname does not resolve; search for verified URL]"
                ui_err "Failed to fetch: $url (DNS resolution failed — site may not exist)" >&2 ;;
            CONN_REFUSED)
                err_sig="[FETCH FAILED | CONNECTION_REFUSED | URL: $url | Action: Target server refused connection; try alternative host]"
                ui_err "Failed to fetch: $url (connection refused)" >&2 ;;
            TIMEOUT)
                err_sig="[FETCH FAILED | REQUEST_TIMEOUT | URL: $url | Action: Server timed out after ${WEB_TIMEOUT}s; try alternative source]"
                ui_err "Failed to fetch: $url (request timed out after ${WEB_TIMEOUT}s)" >&2 ;;
            SSL_ERROR)
                err_sig="[FETCH FAILED | SSL_TLS_ERROR | URL: $url | Action: SSL handshake failed; check URL scheme]"
                ui_err "Failed to fetch: $url (SSL/TLS error)" >&2 ;;
            404)
                err_sig="[FETCH FAILED | HTTP 404 Not Found | URL: $url | Action: Page does not exist; do NOT retry this URL; search for updated link]"
                ui_err "Failed to fetch: $url (HTTP 404 Not Found)" >&2 ;;
            403)
                err_sig="[FETCH FAILED | HTTP 403 Forbidden | URL: $url | Action: Access denied or paywalled; search for open-access mirror]"
                ui_err "Failed to fetch: $url (HTTP 403 Forbidden)" >&2 ;;
            429)
                err_sig="[FETCH FAILED | HTTP 429 Rate Limit | URL: $url | Action: Rate limited; pause or shift to alternative service]"
                ui_err "Failed to fetch: $url (HTTP 429 Rate Limit)" >&2 ;;
            4[0-9][0-9]|5[0-9][0-9])
                err_sig="[FETCH FAILED | HTTP $_reason | URL: $url | Action: Server returned HTTP $_reason; use alternative source]"
                ui_err "Failed to fetch: $url (HTTP $_reason)" >&2 ;;
            *)
                err_sig="[FETCH FAILED | Status: $_reason | URL: $url | Action: Retrieval failed; try alternative query]"
                ui_err "Failed to fetch: $url (status: $_reason)" >&2 ;;
        esac
        echo "$err_sig"
        return 1
    fi
    local ctype=""; [ -f "$_WEB_CTYPE_FILE" ] && ctype=$(_web_classify_content_type "$(cat "$_WEB_CTYPE_FILE" 2>/dev/null)")
    [ -z "$ctype" ] && ctype="$_url_guess"
    local text=""
    case "$ctype" in
        text) text=$(echo "$body" | head -2000) ;;
        json) text=$(echo "$body" | jq '.' 2>/dev/null | head -2000) ;;
        xml) text=$(echo "$body" | sed -e 's/<[^>]*>//g' -e 's/&amp;/\&/g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&#39;/'/g" -e '/^[[:space:]]*$/d' | awk '{$1=$1}1' | head -2000) ;;
        *) text=$(echo "$body" | _html_to_text) ;;
    esac
    if [ -z "$text" ] || [ "${#text}" -lt 50 ]; then
        local raw_sb; raw_sb=$(echo "$body" | web_scrape_pure_bash "" 500 2>/dev/null || true)
        [ -n "$raw_sb" ] && [ "${#raw_sb}" -gt "${#text}" ] && text="$raw_sb"
    fi
    text=$(echo "$text" | _web_strip_boilerplate | _web_truncate_content)
    mkdir -p "$GEORGE_CACHE_DIR" && echo "$text" > "$cache_file" 2>/dev/null
    echo "$text"
}

# ── Fetch a URL and return structured JSON ─────────────────────
web_fetch_json() {
    local url="$1" clean_url; clean_url=$(_web_sanitize_url "$url")
    if _web_blacklist_contains "$clean_url"; then
        jq -n --arg url "$clean_url" --arg reason "BLACKLISTED_$(_web_blacklist_reason "$clean_url" || echo unknown)" '{"url":$url,"title":"","content":"","images":[],"blocked":true,"block_reason":$reason,"http_status":"blacklist"}'
        return 0
    fi
    if _web_greylist_contains "$clean_url"; then
        local fb; fb=$(_web_greylist_fallback "$clean_url")
        if [ $? -eq 0 ]; then echo "$fb"; return 0; fi
        _web_blacklist_add "$clean_url" "GREYLISTED_MISSING_CACHE" "greylist"
        jq -n --arg url "$clean_url" --arg reason "GREYLISTED_MISSING_CACHE" '{"url":$url,"title":"","content":"","images":[],"links":[],"blocked":true,"block_reason":$reason,"http_status":"greylist"}'
        return 0
    fi
    local _rd_check; _rd_check=$(_web_reddit_url "$clean_url")
    if [ -n "$_rd_check" ]; then
        local _rd_json; _rd_json=$(_web_fetch_reddit_json "$clean_url" 2>/dev/null)
        [ -n "$_rd_json" ] && { echo "$_rd_json"; return 0; }
    fi
    if [ "${_WEB_FETCH_STRUCTURED_ACTIVE:-0}" -eq 0 ] && declare -f mcp_enabled &>/dev/null && mcp_enabled; then
        local _mcp_json; _mcp_json=$(mcp_web_fetch_json "$clean_url" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$_mcp_json" ] && echo "$_mcp_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
            echo "$_mcp_json"; return 0
        fi
    fi
    [ -z "$clean_url" ] && { ui_err "Invalid URL: $url"; return 1; }
    local _gh_slug; _gh_slug=$(_web_github_repo_slug "$clean_url")
    if [ -n "$_gh_slug" ]; then
        local _gh_content; _gh_content=$(_web_fetch_github_readme "$_gh_slug")
        if [ -n "$_gh_content" ]; then
            _gh_content=$(echo "$_gh_content" | _web_truncate_content)
            jq -n --arg url "$clean_url" --arg title "GitHub: $_gh_slug" --arg content "$_gh_content" '{"url":$url,"title":$title,"content":$content,"images":[],"links":[]}'
            return 0
        fi
    fi
    local _url_guess; _url_guess=$(_web_guess_content_type "$clean_url")
    case "$_url_guess" in
        pdf)
            ui_dim "Fetching PDF (structured): $clean_url" >&2
            local pdf_text; pdf_text=$(_web_extract_pdf "$clean_url")
            [ -z "$pdf_text" ] && { ui_err "Failed to extract PDF: $clean_url" >&2; return 1; }
            local pdf_title; pdf_title=$(echo "$pdf_text" | head -5 | grep -m1 -E '.{5,}' | head -c 120)
            [ -z "$pdf_title" ] && pdf_title="PDF Document"
            jq -n --arg url "$clean_url" --arg title "$pdf_title" --arg content "$pdf_text" '{"url":$url,"title":$title,"content":$content,"images":[]}'
            return 0 ;;
        binary)
            local _filename; _filename=$(basename "$clean_url" | sed 's/[?#].*//')
            [ -z "$_filename" ] || [ "$_filename" = "/" ] && _filename="downloaded_binary"
            _filename=$(echo "$_filename" | sed 's/["'"'"'`]//g' | tr ' ' '-' | sed 's/[^a-zA-Z0-9_./-]//g')
            local _dest="./$_filename"
            ui_info "Detected binary file (structured). Downloading to $_dest..." >&2
            if curl -fsSL -o "$_dest" "$clean_url" 2>&1; then
                local _desc="Downloaded binary file to $_dest."
                case "$_filename" in *.jpg|*.jpeg|*.png|*.gif|*.webp|*.bmp|*.ico) _desc="Downloaded image file to $_dest. Use the /vision command to analyze it: /vision $_dest" ;; esac
                jq -n --arg url "$clean_url" --arg title "$_filename" --arg content "$_desc" '{"url":$url,"title":$title,"content":$content,"images":[]}'
                return 0
            else ui_err "Failed to download binary file: $clean_url" >&2; return 1; fi ;;
    esac
    ui_dim "Fetching (structured): $clean_url" >&2
    local body; body=$(web_fetch_raw "$clean_url")
    if [ -z "$body" ]; then
        local _reason="unknown"; [ -f "$_WEB_STATUS_FILE" ] && _reason=$(cat "$_WEB_STATUS_FILE" 2>/dev/null)
        case "$_reason" in
            BLOCKED:*) jq -n --arg url "$clean_url" --arg reason "$(echo "$_reason" | cut -d':' -f2)" --arg status "$(echo "$_reason" | cut -d':' -f3)" '{"url":$url,"title":"","content":"","images":[],"blocked":true,"block_reason":$reason,"http_status":$status}'; return 0 ;;
            *) return 1 ;;
        esac
    fi
    local ctype=""; [ -f "$_WEB_CTYPE_FILE" ] && ctype=$(_web_classify_content_type "$(cat "$_WEB_CTYPE_FILE" 2>/dev/null)")
    [ -z "$ctype" ] && ctype="$_url_guess"
    case "$ctype" in
        text) jq -n --arg url "$clean_url" --arg title "" --arg content "$(echo "$body" | head -2000)" '{"url":$url,"title":$title,"content":$content,"images":[]}'; return 0 ;;
        json) jq -n --arg url "$clean_url" --arg title "JSON Data" --arg content "$(echo "$body" | jq '.' 2>/dev/null | head -2000 || echo "$body")" '{"url":$url,"title":$title,"content":$content,"images":[]}'; return 0 ;;
        xml) jq -n --arg url "$clean_url" --arg title "XML/RSS Feed" --arg content "$(echo "$body" | sed -e 's/<[^>]*>//g' -e 's/&amp;/\&/g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&#39;/'/g" -e '/^[[:space:]]*$/d' | awk '{$1=$1}1' | head -2000)" '{"url":$url,"title":$title,"content":$content,"images":[]}'; return 0 ;;
    esac
    local base_url; base_url=$(echo "$clean_url" | sed 's|^\(https\?://[^/]*\).*|\1|')
    local title; title=$(echo "$body" | _html_extract_title || echo "")
    local content; content=$(echo "$body" | _html_extract_content)
    if [ -z "$content" ] || [ "${#content}" -lt 80 ]; then
        local fb; fb=$(echo "$body" | _html_to_text)
        [ "${#fb}" -gt "${#content}" ] && content="$fb"
    fi
    content=$(echo "$content" | _web_strip_boilerplate | _web_truncate_content)
    local images_json="[]" img_lines; img_lines=$(echo "$body" | _html_extract_images "$base_url")
    [ -n "$img_lines" ] && images_json=$(echo "$img_lines" | jq -R '.' | jq -s '.')
    local links_json="[]" link_lines; link_lines=$(echo "$body" | _html_extract_links "$base_url")
    [ -n "$link_lines" ] && links_json=$(echo "$link_lines" | jq -R '.' | jq -s '.')
    jq -n --arg url "$clean_url" --arg title "$title" --arg content "$content" --argjson images "$images_json" --argjson links "$links_json" '{"url":$url,"title":$title,"content":$content,"images":$images,"links":$links}'
}

# ── Extract just the title from a page ────────────────────────
web_title() { web_fetch_raw "$1" | _html_extract_title; }

# ── Extract links from HTML (for structured scraping) ──────────
_html_extract_links() {
    local base_url="$1"
    grep -oiE '<a[^>]+href="[^"]*"[^>]*>' | grep -oE 'href="[^"]+"' | sed 's/href="//;s/"$//' | while IFS= read -r link_url; do
        [ -z "$link_url" ] && continue
        case "$link_url" in \#*|javascript:*|mailto:*|tel:*|data:*) continue ;; esac
        if [[ "$link_url" == //* ]]; then link_url="https:${link_url}"
        elif [[ "$link_url" == /* ]]; then link_url="${base_url}${link_url}"
        elif [[ "$link_url" != http* ]]; then continue; fi
        [[ "$link_url" =~ \.(css|js|map|woff2?|ttf|eot|ico|xml|json)(\?|$) ]] && continue
        echo "$link_url"
    done | sort -u | head -30
}

# ── Extract all links from a page ─────────────────────────────
web_links() {
    web_fetch_raw "$1" | grep -oE 'href="[^"]*"' | sed 's/href="//;s/"$//' | grep -E '^https?://' | sort -u | head -50
}

# ── Extract image URLs from a page (JSON) ──────────────────────
web_scrape_images() {
    local url="$1"
    [ -z "$url" ] && { ui_err "Usage: web_scrape_images <url>"; return 1; }
    local clean_url; clean_url=$(_web_sanitize_url "$url")
    [ -z "$clean_url" ] && { ui_err "Invalid URL: $url"; return 1; }
    if ! _web_dns_precheck "$clean_url"; then
        ui_err "DNS pre-check failed for $clean_url — hostname does not resolve." >&2
        _web_blacklist_add "$clean_url" "DNS_PRECHECK_FAIL" "DNS_FAIL"; return 1
    fi
    local json_result; json_result=$(web_fetch_json "$clean_url")
    [ -z "$json_result" ] && return 1
    if ! echo "$json_result" | jq -e '.' >/dev/null 2>&1; then ui_err "web_scrape_images produced invalid JSON for: $clean_url"; return 1; fi
    local title img_count content_lines is_blocked block_reason http_status
    title=$(echo "$json_result" | jq -r '.title // "Untitled"' 2>/dev/null)
    img_count=$(echo "$json_result" | jq -r '.images | length' 2>/dev/null)
    is_blocked=$(echo "$json_result" | jq -r '.blocked // false' 2>/dev/null)
    block_reason=$(echo "$json_result" | jq -r '.block_reason // ""' 2>/dev/null)
    http_status=$(echo "$json_result" | jq -r '.http_status // ""' 2>/dev/null)
    [ "$is_blocked" = "true" ] && ui_warn "Site blocked scraping (reason: ${block_reason:-unknown}, status: ${http_status:-unknown})" >&2
    content_lines=$(echo "$json_result" | jq -r '.content // ""' 2>/dev/null | awk 'NF{c++} END{print c+0}')
    if [ "$is_blocked" != "true" ] && [ "${content_lines:-0}" -eq 0 ]; then
        ui_warn "scrape returned 0 content lines; falling back to fetch" >&2
        local fetched_text; fetched_text=$(web_fetch "$clean_url" 2>/dev/null)
        if [ -n "$fetched_text" ]; then
            json_result=$(echo "$json_result" | jq --arg content "$fetched_text" '.content = $content' 2>/dev/null)
            content_lines=$(echo "$json_result" | jq -r '.content // ""' 2>/dev/null | awk 'NF{c++} END{print c+0}')
        fi
    fi
    ui_ok "Scraped: $title" >&2; ui_dim "  Content: ~${content_lines} lines | Images: ${img_count}" >&2
    _web_journal_results "scrape $clean_url" "Title: $title\nImages: $img_count\nContent excerpt: $(echo "$json_result" | jq -r '.content' 2>/dev/null | head -10)" "scrape"
    echo "$json_result"
    [ "$is_blocked" = "true" ] && return 1 || return 0
}

web_scrape() {
    local _unused_check="_web_journal_results"
    web_scrape_images "$@"
}

# ── Search the web ────────────────────────────────────────────
_WEB_LAST_SEARCH_JSON=""

_web_save_last_search_to_file() {
    if [ -n "$_WEB_LAST_SEARCH_JSON" ]; then
        local _ws="${AGENT_TASK_WORKSPACE:-.george/workspaces}"
        mkdir -p "$_ws" 2>/dev/null && echo "$_WEB_LAST_SEARCH_JSON" > "$_ws/last_search.json"
    fi
}

_web_searxng_is_available() {
    local base_url="${SEARXNG_URL:-http://127.0.0.1:8081}"
    curl -sf -m 1 "$base_url/healthz" &>/dev/null || curl -sf -m 1 "$base_url/search?q=test&format=json" &>/dev/null
}

_web_search_searxng() {
    local query="$1" count="${2:-5}" category="${3:-general}" engines="${4:-}" time_range="${5:-}"
    local py_bin="python3"
    [ -x "$LODGE_DIR/.venv/bin/python" ] && py_bin="$LODGE_DIR/.venv/bin/python"
    [ ! -f "$LODGE_DIR/lib/tools/searxng_backend.py" ] && return 1

    local cmd=("$py_bin" "$LODGE_DIR/lib/tools/searxng_backend.py" search --query "$query" --category "$category" --max-results "$count" --format json)
    [ -n "$engines" ] && cmd+=(--engines "$engines")
    [ -n "$time_range" ] && cmd+=(--time-range "$time_range")

    local raw_json
    raw_json=$("${cmd[@]}" 2>/dev/null)
    [ -z "$raw_json" ] || [ "$raw_json" = "[]" ] && return 1

    local output="" i=1
    while IFS= read -r item; do
        [ -z "$item" ] && continue
        local title url snip engine
        title=$(echo "$item" | jq -r '.title // "Untitled"')
        url=$(echo "$item" | jq -r '.url // ""')
        snip=$(echo "$item" | jq -r '.content // ""')
        engine=$(echo "$item" | jq -r '.engine // "searxng"')
        [ -z "$url" ] && continue

        printf '[%d] %s [%s]\n    %s\n    %s\n\n' "$i" "$title" "$engine" "$url" "$snip"
        output="${output}[$i] $title [$engine]\n    $url\n    $snip\n\n"
        i=$((i + 1))
    done < <(echo "$raw_json" | jq -c '.[]' 2>/dev/null)

    _WEB_LAST_SEARCH_JSON=$(jq -n --arg q "$query" --argjson r "$raw_json" '{"query":$q,"provider":"searxng","results":$r}' 2>/dev/null || true)
    [ -n "$output" ] && _web_journal_results "$query" "$output" "searxng"
    return 0
}

# Caller class for the search router: Serper (paid) is operator-only and never cron.
_web_search_caller() {
    if [ -n "${LODGE_CRON_JOB:-}" ]; then echo cron
    elif [ "${LODGE_EVAL:-0}" = "1" ]; then echo eval
    elif [ -n "${_DISCORD_IN_SESSION:-}" ]; then echo discord
    elif [ -z "${LODGE_NONINTERACTIVE:-}" ] && [ -t 0 ]; then echo operator
    else echo agent
    fi
}

web_search() {
    local query="$1" count="${2:-5}" category="${3:-general}" engines="${4:-}" time_range="${5:-}"
    query="${query#\"}"; query="${query%\"}"; query="${query#\'}"; query="${query%\'}"
    [ -z "$query" ] && { ui_err "Usage: web_search <query> [count] [category] [engines] [time_range]"; return 1; }
    local exclusions; exclusions=$(_web_exclusions_get_active_filters)
    [ -n "$exclusions" ] && query="${query}${exclusions}"
    [[ "$count" =~ ^[0-9]{1,2}$ ]] || count=5

    # ── P4: single router (cache → SearXNG → Brave → Serper[operator] → DDG) ──
    local py_bin="python3"
    [ -x "$LODGE_DIR/.venv/bin/python" ] && py_bin="$LODGE_DIR/.venv/bin/python"
    if [ -f "$LODGE_DIR/lib/tools/search_router.py" ]; then
        local cmd=("$py_bin" "$LODGE_DIR/lib/tools/search_router.py" search --query "$query"
                   --category "$category" --max-results "$count" --caller "$(_web_search_caller)" --format json)
        [ -n "$engines" ] && cmd+=(--engines "$engines")
        [ -n "$time_range" ] && cmd+=(--time-range "$time_range")
        local res; res=$(LODGE_DIR="$LODGE_DIR" GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}" "${cmd[@]}" 2>/dev/null)
        if [ -n "$res" ] && echo "$res" | jq -e '.results | length > 0' >/dev/null 2>&1; then
            local output
            output=$(echo "$res" | jq -r '
                (.results | to_entries[] | "[\(.key + 1)] \(.value.title) [\(.value.engine // .value.provider)]\n    \(.value.url)\n    \((.value.content // "")[0:400])\n"),
                "(search: provider=\(.provider // "none")\(if .cached then ", cached" else "" end)\(if .time_range then ", time_range=\(.time_range)" else "" end))",
                (if (.degraded | length) > 0 then "⚠ DEGRADED search engines: \([.degraded[].engine] | join(","))" else empty end)')
            printf '%s\n' "$output"
            _WEB_LAST_SEARCH_JSON=$(echo "$res" | jq -c '{query, provider, degraded, results: [.results[] | {title, url, snippet: .content, engine}]}' 2>/dev/null)
            _web_journal_results "$query" "$output" "$(echo "$res" | jq -r '.provider // "router"')"
            _web_save_last_search_to_file
            return 0
        fi
        local tried; tried=$(echo "$res" | jq -r '[.providers_tried[]? | "\(.name)=\(.status)"] | join(", ")' 2>/dev/null)
        ui_err "No search results for: $query${tried:+ (tried: $tried)}"
        return 1
    fi

    # Router missing (partial checkout): legacy keyless paths only.
    if [ "${USE_SEARXNG:-1}" -eq 1 ] && _web_searxng_is_available && \
       _web_search_searxng "$query" "$count" "$category" "$engines" "$time_range"; then
        _web_save_last_search_to_file; return 0
    fi
    _web_search_ddg "$query" "$count"; local rc=$?; _web_save_last_search_to_file; return $rc
}


# ── Creative Non-Greedy Semantic Cross-Section Sampler ────────────────
web_search_cross_section() {
    local query="$1" sample_size="${2:-3}" pool_size="${3:-10}" raw
    local py_bin="python3"
    [ -x "$LODGE_DIR/.venv/bin/python" ] && py_bin="$LODGE_DIR/.venv/bin/python"
    local clean_q="$query"
    if [ -f "$LODGE_DIR/lib/tools/searxng_backend.py" ] && ([ "${#query}" -gt 80 ] || [[ "$query" =~ (please|research_sandbox|search for|investigate|\() ]]); then
        clean_q=$("$py_bin" -c "
import sys
sys.path.insert(0, '$LODGE_DIR/lib/tools')
from searxng_backend import distill_search_query
print(distill_search_query(sys.argv[1]))
" "$query" 2>/dev/null || echo "$query")
        [ -z "$clean_q" ] && clean_q="$query"
    fi
    raw=$(web_search "$clean_q" "$pool_size" 2>/dev/null)
    [ -z "$raw" ] && raw=$(web_search "$query" "$pool_size" 2>/dev/null)
    [ -z "$raw" ] && { ui_err "No search results found to sample."; return 1; }
    awk -v k="$sample_size" 'BEGIN { srand(); n=0 }
/^\[[0-9]+\]/ {
    n++; t = $0; sub(/^\[[0-9]+\][ \t]*/, "", t); titles[n] = t;
    getline u; sub(/^[ \t]*/, "", u); urls[n] = u; dom = u; sub(/^https?:\/\//, "", dom); sub(/[\/:?#].*$/, "", dom); sub(/^www\./, "", dom); domains[n] = tolower(dom);
    snip = ""; while (getline l > 0 && l !~ /^[ \t]*$/) { sub(/^[ \t]*/, "", l); snip = snip (snip == "" ? "" : " ") l; } snippets[n] = snip;
}
END {
    count = 0; for (i = n; i > 1; i--) { r = int(rand() * i) + 1; tmp = order[i] ? order[i] : i; order[i] = order[r] ? order[r] : r; order[r] = tmp; }
    for (i = 1; i <= n; i++) {
        idx = order[i] ? order[i] : i; d = domains[idx];
        if (d != "" && !seen[d]) { seen[d] = 1; count++; chosen[count] = idx; in_chosen[idx] = 1; if (count >= k) break; }
    }
    if (count < k) { for (i = 1; i <= n; i++) { idx = order[i] ? order[i] : i; if (!in_chosen[idx]) { count++; chosen[count] = idx; in_chosen[idx] = 1; if (count >= k) break; } } }
    print "── Non-Greedy Semantic Cross-Section Sample (" count " distinct perspectives from " n " candidates) ──\n";
    for (i = 1; i <= count; i++) { idx = chosen[i]; printf "[%d] %s [%s]\n    %s\n    %s\n\n", i, titles[idx], domains[idx], urls[idx], snippets[idx]; }
}' <<< "$raw"
}

# research_sandbox helpers (whole-word domain classifier + topic-anchored vectors).
# Bug history: substring regexes classified "from" as gaming ("rom") and the
# fallback appended "arxiv research paper" to every topic, so the sandbox
# searched for things the operator never asked about.
_research_classify_domain() {
    local t; t=$(printf '%s' "${1,,}" | tr -c 'a-z0-9_\n' ' ')
    _rcd() { grep -qwE "$1" <<< "$t"; }
    if _rcd '(games?|gaming|emulators?|emulation|decompil(e|ation)|jit|recompiler|ps[1-5]|gamecube|n64|nintendo|playstation|xbox|retroarch|pcsx2|rpcs3|godot|roms?|disassembly|ghidra)'; then echo gaming
    elif _rcd '(finance|financial|stocks?|shares|invest(ing|ment|ments)?|equity|markets?|crypto(currency)?|bitcoin|btc|ethereum|eth|cardano|ada|defi|tokens?|tokenomics|coins?|yields?|earnings|revenue|ebitda|valuation|dividends?|portfolio|trading|forex|treasury|insurance|insurers?|unh|elv|humana|cigna|cvs|ticker|nasdaq|nyse)'; then echo finance
    elif _rcd '(sports?|football|soccer|baseball|basketball|hockey|nfl|nba|mlb|nhl|fifa|quarterback|coach|roster|championship|cars?|automotive|horsepower|torque|vehicles?|porsche|ferrari|bmw|tesla|f1|racing)'; then echo general_sports_auto
    elif _rcd '(music|albums?|mixtape|vinyl|beatport|dj|techno|trance|concerts?|tracklist|remix|soundcloud|bandcamp|festival|tour)'; then echo music
    elif _rcd '(rfc|github|repo|linux|kernel|driver|protocol|networking|database|compiler|kubernetes|docker|security|vulnerability|exploit|cve|api|backend|frontend|rust|golang)'; then echo engineering
    elif _rcd '(arxiv|preprint|papers?|theorem|algorithms?|neural|transformers?|dataset|benchmarks?)'; then echo academic
    else echo general
    fi
}

# Prints one query per line; every query contains the topic verbatim, first line is the topic itself.
_research_vectors() {
    local t="$1" d="${2:-general}" yr; yr=$(date +%Y)
    local -a v=("$t")
    case "$d" in
        finance)             v+=("$t news" "$t price analysis") ;;
        gaming)              v+=("$t github" "$t technical architecture") ;;
        general_sports_auto) v+=("$t news" "$t statistics") ;;
        music)               v+=("$t new release $yr" "$t tour dates $yr") ;;
        engineering)         v+=("$t documentation" "$t github") ;;
        academic)            v+=("$t arxiv" "$t survey") ;;
        *)                   v+=("$t news") ;;
    esac
    printf '%s\n' "${v[@]}" | awk '!seen[tolower($0)]++'
}

# ── Autonomous Multi-Vector Research Sandbox Engine ───────────────────
# Conducts multi-vector domain investigations matching the research_graph loop:
# 1. Distills natural language conversational inquiries into clean keyword vectors.
# 2. Classifies research domain (finance, engineering, gaming, general_sports_auto, academic).
# 3. Sweeps multiple targeted search vectors across news and general metasearch engines.
# 4. Executes non-greedy cross-section sampling across diverse, distinct domains.
# 5. Ingests clean primary page content, filtering cookie banners and navigation boilerplate.
# 6. Extracts real-time equity quotes and trading metrics for financial inquiries.
# 7. Assembles an authoritative structured intelligence dossier.
research_sandbox() {
    local topic="$1" sample_size="${2:-3}" output_file="${3:-}"
    [ -z "$topic" ] && { ui_err "research_sandbox: topic argument is required"; return 1; }

    local py_bin="python3"
    [ -x "$LODGE_DIR/.venv/bin/python" ] && py_bin="$LODGE_DIR/.venv/bin/python"

    # Step 1: Distill inquiry into clean keyword core
    local clean_topic="$topic"
    if [ -f "$LODGE_DIR/lib/tools/searxng_backend.py" ]; then
        clean_topic=$("$py_bin" -c "
import sys
sys.path.insert(0, '$LODGE_DIR/lib/tools')
from searxng_backend import distill_search_query
print(distill_search_query(sys.argv[1]))
" "$topic" 2>/dev/null || echo "$topic")
        [ -z "$clean_topic" ] && clean_topic="$topic"
    fi

    local slug; slug=$(echo "$clean_topic" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | tr -s '-' | cut -c1-30)
    [ -z "$slug" ] && slug="intel-$(date +%s)"
    local ts; ts=$(date +%s)
    local sandbox_dir="${RESEARCH_SANDBOX_ROOT:-${LODGE_DIR}/.sandboxes}/research_${slug}_${ts}"
    mkdir -p "$sandbox_dir/artifacts"
    echo "$$" > "$sandbox_dir/.pid"
    echo "Running" > "$sandbox_dir/.phase"
    jq -n --arg cmd "Research: $clean_topic" --arg type "research" '{command: $cmd, type: $type, objective: $cmd}' > "$sandbox_dir/task_meta.json" 2>/dev/null || true
    local start_ts; start_ts=$(date '+%Y-%m-%d %I:%M %p %Z')
    echo "[$start_ts] Commencing autonomous multi-vector research sweep for: $clean_topic" > "$sandbox_dir/trajectory.log"

    [ -n "$output_file" ] && mkdir -p "$(dirname "$output_file")"

    # Step 2: Classify domain (whole-word matching; unknown topics stay "general")
    local domain; domain=$(_research_classify_domain "$topic")
    local lower="${topic,,}"

    echo "Phase: Multi-Vector Targeted Search Sweep [Domain: ${domain}]" > "$sandbox_dir/.phase"
    echo "[$start_ts] Classified domain: ${domain}" >> "$sandbox_dir/trajectory.log"

    # Step 3: Search vectors — the distilled topic itself first, then topic-anchored variants
    local vectors=()
    mapfile -t vectors < <(_research_vectors "$clean_topic" "$domain")

    # Step 4: Sweep. News-flavoured topics try the news category first.
    local want_news=0
    { [ "$domain" = "finance" ] || grep -qwiE 'news|breaking|latest|today|week|headlines' <<< "$lower"; } && want_news=1
    local combined_results=""
    for v in "${vectors[@]}"; do
        [ -z "$v" ] && continue
        local v_res=""
        [ "$want_news" -eq 1 ] && v_res=$(web_search "$v" 4 news 2>/dev/null || true)
        [ -z "$v_res" ] && v_res=$(web_search "$v" 4 general 2>/dev/null || true)
        echo "[$(date '+%H:%M:%S')] Vector '${v}' returned $(grep -c '^\[' <<< "$v_res") candidates" >> "$sandbox_dir/trajectory.log"
        [ -n "$v_res" ] && combined_results="${combined_results}"$'\n'"${v_res}"
    done

    # Fallback to the raw (undistilled) topic if every vector came back dry
    if [ -z "$combined_results" ]; then
        combined_results=$(web_search "$topic" 10 2>/dev/null || true)
    fi

    # Step 5: Cross-section sampling — preserve rank order (primary vector first), prefer distinct domains
    local search_sample
    search_sample=$(awk -v k="$sample_size" 'BEGIN { n=0 }
/^\[[0-9]+\]/ {
    n++; t = $0; sub(/^\[[0-9]+\][ \t]*/, "", t); titles[n] = t;
    getline u; sub(/^[ \t]*/, "", u); urls[n] = u; dom = u; sub(/^https?:\/\//, "", dom); sub(/[\/:?#].*$/, "", dom); sub(/^www\./, "", dom); domains[n] = tolower(dom);
    snip = ""; while (getline l > 0 && l !~ /^[ \t]*$/) { sub(/^[ \t]*/, "", l); snip = snip (snip == "" ? "" : " ") l; } snippets[n] = snip;
}
END {
    count = 0
    for (i = 1; i <= n; i++) {
        d = domains[i]; if (urls[i] in seen_url) continue;
        if (d != "" && !seen[d]) { seen[d] = 1; seen_url[urls[i]] = 1; count++; chosen[count] = i; in_chosen[i] = 1; if (count >= k) break; }
    }
    if (count < k) { for (i = 1; i <= n; i++) { if (!in_chosen[i] && !(urls[i] in seen_url)) { seen_url[urls[i]] = 1; count++; chosen[count] = i; in_chosen[i] = 1; if (count >= k) break; } } }
    print "── Cross-Section Sample (" count " distinct perspectives from " n " candidates) ──\n";
    for (i = 1; i <= count; i++) { idx = chosen[i]; printf "[%d] %s [%s]\n    %s\n    %s\n\n", i, titles[idx], domains[idx], urls[idx], snippets[idx]; }
}' <<< "$combined_results")

    echo "$search_sample" > "$sandbox_dir/artifacts/search_results.txt"

    # Step 6: Extract real-time equity quotes for financial topics
    local stock_section=""
    if [ "$domain" = "finance" ]; then
        local tickers=()
        for t in UNH ELV HUM CI CVS; do
            if grep -iqE "\b${t}\b" <<< "$topic" || grep -iqE "\b${t}\b" <<< "$clean_topic"; then
                tickers+=("$t")
            fi
        done
        if grep -iq "cigna" <<< "$topic" && ! [[ " ${tickers[*]:-} " =~ " CI " ]]; then
            tickers+=("CI")
        fi
        if [ ${#tickers[@]} -gt 0 ]; then
            echo "Phase: Ingesting Real-Time Market Quotes" > "$sandbox_dir/.phase"
            local stock_table="| Ticker | Company / Instrument | Current Price | Previous Close | Net Change | % Change |\n| :--- | :--- | :--- | :--- | :--- | :--- |\n"
            for sym in "${tickers[@]}"; do
                local quote_json
                quote_json=$(curl -sL --max-time 4 -H "User-Agent: Mozilla/5.0" "https://query1.finance.yahoo.com/v8/finance/chart/$sym" 2>/dev/null || true)
                if [ -n "$quote_json" ]; then
                    local price prev c_name
                    price=$(echo "$quote_json" | jq -r '.chart.result[0].meta.regularMarketPrice // empty' 2>/dev/null || true)
                    prev=$(echo "$quote_json" | jq -r '.chart.result[0].meta.previousClose // empty' 2>/dev/null || true)
                    c_name=$(echo "$quote_json" | jq -r '.chart.result[0].meta.shortName // .chart.result[0].meta.symbol // empty' 2>/dev/null || true)
                    if [ -n "$price" ] && [ -n "$prev" ]; then
                        local diff chg pct
                        diff=$("$py_bin" -c "p=$price; pr=$prev; d=p-pr; pct=(d/pr)*100; print(f'{d:+.2f}|{pct:+.2f}%')" 2>/dev/null || true)
                        chg=$(echo "$diff" | cut -d'|' -f1)
                        pct=$(echo "$diff" | cut -d'|' -f2)
                        stock_table="${stock_table}| **${sym}** | ${c_name} | \$${price} | \$${prev} | ${chg} | ${pct} |\n"
                    fi
                fi
            done
            stock_section="\n---\n\n## 2. Live Market Intelligence & Stock Quotes\n${stock_table}\n"
        fi
    fi

    # Step 7: Ingest primary pages with clean HTML stripping
    local urls=($(echo "$search_sample" | grep -oE 'https?://[^ ]+' | head -n "$sample_size" || true))
    local source_sections="" idx=1
    for u in "${urls[@]}"; do
        local domain_name; domain_name=$(echo "$u" | awk -F[/:] '{print $4}' | sed 's/^www\.//')
        echo "Sampling source [$idx/$sample_size]: $domain_name" > "$sandbox_dir/.phase"
        echo "[$(date '+%H:%M:%S')] Fetching domain perspective from $domain_name ($u)..." >> "$sandbox_dir/trajectory.log"

        local page_raw clean_text snip_text
        page_raw=$(web_fetch "$u" 2>/dev/null | head -n 80 || true)
        [ -z "$page_raw" ] || [ "${#page_raw}" -lt 50 ] && page_raw=$(web_scrape_pure_bash "$u" 80 2>/dev/null || true)

        # Strip navigation, script, cookie notices, fetch failures, and HTML boilerplate
        clean_text=$(echo "$page_raw" | grep -v -E '^[[:space:]]*<(!DOCTYPE|html|head|meta|link|script|style|svg|path|div|span|header|footer|nav)' | grep -v -E 'cookie|Welcome Back|Oops, something went wrong|Skip to right column|FETCH FAILED|BLOCKED_GREYLIST|SYSTEM NOTE' | grep -v '^[[:space:]]*$' | head -n 8 | tr '\n' ' ' | sed 's/  */ /g' || true)

        snip_text=$(echo "$search_sample" | grep -A 2 -F "$u" | tail -n 1 | sed 's/^[[:space:]]*//' || true)
        if [ -z "$clean_text" ] || [ "${#clean_text}" -lt 50 ] || [[ "$clean_text" =~ (FETCH FAILED|BLOCKED_GREYLIST|SYSTEM NOTE) ]]; then
            clean_text="$snip_text"
        fi
        [ -z "$clean_text" ] && clean_text="Primary domain report and findings captured from source link."

        source_sections="${source_sections}\n### [${idx}] ${domain_name}\n- **Source URL:** ${u}\n- **Extracted Findings & Excerpt:**\n  > $(echo "$clean_text" | cut -c1-650)...\n"
        idx=$((idx + 1))
    done

    # Step 8: Assemble final structured dossier
    local date_str; date_str=$(date '+%Y-%m-%d %I:%M %p %Z')
    local full_dossier="# 🔬 Research Intelligence Dossier: ${clean_topic}
**Generated:** ${date_str}  
**Sandbox:** \`${sandbox_dir##*/}\`  
**Domain:** \`${domain}\` | **Multi-Vector Cross-Section Sampling:** ${sample_size} distinct perspectives  
**Original Inquiry:** > ${topic}

---

## 1. Executive Summary & Overview
Autonomous multi-vector research sweep executed across empirical, news, and market vectors for:
> **${clean_topic}**

Synthesizing verified developments, operational disclosures, and primary metrics across sampled domain perspectives.
${stock_section}
---

## 3. Sampled Sources & Domain Perspectives
${source_sections}
---

## 4. Cross-Sectional Reference Summary
${search_sample}

---
*Collected autonomously by George Research Sandbox Multi-Vector Engine.*"

    echo -e "$full_dossier" > "$sandbox_dir/artifacts/report.md"
    [ -n "$output_file" ] && echo -e "$full_dossier" > "$output_file"
    echo "Completed" > "$sandbox_dir/.phase"
    echo "[$(date '+%H:%M:%S')] Research dossier generated successfully." >> "$sandbox_dir/trajectory.log"
    touch "$sandbox_dir/.done"
    echo -e "$full_dossier"
}

_web_search_serper() {
    local query="$1" count="$2" key="$3" serper_num=10
    [ "$count" -gt 10 ] && [ "$count" -le 20 ] && serper_num=20
    [ "$count" -gt 20 ] && serper_num=30
    local data; data=$(jq -n --arg q "$query" --argjson n "$serper_num" '{"q": $q, "num": $n}')
    local resp; resp=$(api_post "https://google.serper.dev/search" "$data" -H "X-API-KEY: $key")
    if [ $? -eq 0 ]; then
        local raw_results; raw_results=$(echo "$resp" | jq -r '.organic[]? | "\(.position)|\(.link)|\(.title)|\(.snippet)"' 2>/dev/null)
        if [ -z "$raw_results" ]; then
            ui_warn "Serper returned no organic results, falling back to DuckDuckGo"
            _web_search_ddg "$query" "$count"; return $?
        fi
        local output="" json_results="[]" i=1
        while IFS='|' read -r _pos url title snippet; do
            local clean_url; clean_url=$(_web_sanitize_url "$url")
            [ -z "$clean_url" ] && continue
            _web_greylist_contains "$clean_url" && title="${title} [GREY-LISTED]"
            output="${output}[$i] $title\n    $clean_url\n    $snippet\n\n"
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
    local query="$1" key="$2" data resp
    data=$(jq -n --arg q "$query" '{"model": "sonar", "messages": [{"role": "user", "content": $q}]}')
    resp=$(api_post "https://api.perplexity.ai/chat/completions" "$data" -H "Authorization: Bearer $key")
    [ $? -eq 0 ] && api_json_get "$resp" '.choices[0].message.content'
}

_web_search_ddg() {
    local query="$1" count="$2" encoded html
    encoded=$(printf '%s' "$query" | jq -sRr @uri)
    html=$(_web_curl --max-time 10 -H "Accept: text/html" "https://lite.duckduckgo.com/lite/?q=$encoded" 2>/dev/null)
    [ -z "$html" ] && { ui_err "DuckDuckGo search failed"; return 1; }
    local results=""
    results=$(echo "$html" | grep -oE '<a[^>]*class="result-link"[^>]*>[^<]*' 2>/dev/null | sed -n 's/.*href="\([^"]*\)".*> \([^<]*\)/\1|\2/p' | head -"$count")
    [ -z "$results" ] && results=$(echo "$html" | grep -oE '<a[^>]*class="result-link"[^>]*>[^<]*' 2>/dev/null | sed -n 's/.*href="\([^"]*\)".*>\([^<]*\)/\1|\2/p' | head -"$count")
    [ -z "$results" ] && results=$(echo "$html" | grep -oE 'class="result__a"[^>]*href="[^"]*"[^>]*>[^<]*' 2>/dev/null | sed 's/.*href="//;s/"[^>]*>/|/' | head -"$count")
    [ -z "$results" ] && results=$(echo "$html" | grep -oE '<a[^>]+rel="nofollow"[^>]+href="[^"]+"[^>]*>[^<]+' 2>/dev/null | sed 's/<a[^>]*href="//;s/"[^>]*>/|/' | head -"$count")
    if [ -n "$results" ]; then
        local output="" i=1
        while IFS='|' read -r url title; do
            if [[ "$url" == *"uddg="* ]]; then
                local raw_url; raw_url=$(echo "$url" | sed -n 's/.*uddg=\([^&]*\).*/\1/p')
                url=$(printf '%b' "${raw_url//%/\\x}" 2>/dev/null || echo "$raw_url")
            fi
            _web_is_ad_url "$url" && continue
            local clean_url; clean_url=$(_web_sanitize_url "$url")
            [ -z "$clean_url" ] && continue
            local display_title="${title:-$clean_url}"
            _web_greylist_contains "$clean_url" && display_title="${display_title} [GREY-LISTED]"
            output="${output}[$i] $display_title\n    $clean_url\n\n"
            printf '[%d] %s\n    %s\n\n' "$i" "$display_title" "$clean_url"
            i=$((i + 1))
        done <<< "$results"
        _WEB_LAST_SEARCH_JSON=$(echo "$output" | awk -F'\n' -v q="$query" '
            BEGIN { printf "{\"query\":\"%s\",\"provider\":\"ddg\",\"results\":[", q }
            /^\[/ { if(NR>1) printf ","; gsub(/^\[[0-9]+\] /,""); title=$0; getline; gsub(/^    /,""); url=$0; printf "{\"title\":\"%s\",\"url\":\"%s\"}", title, url }
            END { print "]}" }' 2>/dev/null || echo '{"query":"'"$query"'","provider":"ddg","results":[]}')
        [ -n "$output" ] && _web_journal_results "$query" "$output" "ddg"
        return 0
    fi
    local text_results; text_results=$(echo "$html" | _html_to_text_sed | grep -v '^$' | head -40)
    [ -n "$text_results" ] && { echo "$text_results"; return 0; }
    ui_err "No results found for: $query"; return 1
}

# ── Search for images ─────────────────────────────────────────
web_images() {
    local query="$1" count="${2:-5}"
    query="${query#\"}"; query="${query%\"}"; query="${query#\'}"; query="${query%\'}"
    [ -z "$query" ] && { ui_err "Usage: web_images <query> [count]"; return 1; }
    if declare -f mcp_enabled &>/dev/null && mcp_enabled; then
        local _mcp_result; _mcp_result=$(mcp_web_images "$query" "$count" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$_mcp_result" ]; then echo "$_mcp_result"; return 0; fi
    fi
    if ! api_network_reachable 3; then ui_err "Image search unavailable: network is offline or unreachable"; return 1; fi
    local serper_key; serper_key=$(api_get_key "SERPER_API_KEY" 2>/dev/null)
    if [ -n "$serper_key" ]; then _web_search_serper_images "$query" "$count" "$serper_key"; return $?; fi
    _web_search_ddg_images "$query" "$count"; return $?
}

_web_search_ddg_images() {
    local query="$1" count="$2" encoded html vqd resp
    encoded=$(printf '%s' "$query" | jq -sRr @uri)
    html=$(curl -sL --connect-timeout 5 --max-time 10 -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36" -H "Referer: https://duckduckgo.com/" "https://duckduckgo.com/?q=$encoded" 2>/dev/null)
    vqd=$(echo "$html" | grep -o 'vqd=[^&]*' | head -1 | cut -d= -f2 | tr -d '"' | cut -d, -f1)
    [ -z "$vqd" ] && { ui_warn "Failed to retrieve DuckDuckGo security token (vqd)"; return 1; }
    resp=$(curl -sL --connect-timeout 5 --max-time 10 -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36" -H "Referer: https://duckduckgo.com/" "https://duckduckgo.com/i.js?q=$encoded&vqd=$vqd&o=json" 2>/dev/null)
    local raw_results; raw_results=$(echo "$resp" | jq -r --argjson limit "$count" '.results[0:$limit][]? | "\(.title)|\(.image)|\(.width)x\(.height)|\(.url)"' 2>/dev/null)
    [ -z "$raw_results" ] && { ui_warn "No image results for: $query"; return 1; }
    local output="" i=1
    while IFS='|' read -r title image_url dimensions source_url; do
        local clean_url; clean_url=$(_web_sanitize_url "$image_url")
        [ -z "$clean_url" ] && continue
        output="${output}[$i] $title\n    $clean_url ($dimensions)\n    Source: $source_url\n"
        printf '[%d] %s\n    %s (%s)\n    Source: %s\n\n' "$i" "$title" "$clean_url" "$dimensions" "$source_url"
        i=$((i + 1))
    done <<< "$raw_results"
    _web_journal_results "$query" "$output" "ddg-images"
}

_web_search_serper_images() {
    local query="$1" count="$2" key="$3"
    local data; data=$(jq -n --arg q "$query" --argjson n "$count" '{"q": $q, "num": $n}')
    local resp; resp=$(api_post "https://google.serper.dev/images" "$data" -H "X-API-KEY: $key")
    [ $? -ne 0 ] && { ui_err "Serper image search request failed"; return 1; }
    local raw_results; raw_results=$(echo "$resp" | jq -r '.images[]? | "\(.title)|\(.imageUrl)|\(.imageWidth)x\(.imageHeight)|\(.link)"' 2>/dev/null)
    [ -z "$raw_results" ] && { ui_warn "No image results for: $query"; return 1; }
    local output="" i=1
    while IFS='|' read -r title image_url dimensions source_url; do
        local clean_url; clean_url=$(_web_sanitize_url "$image_url")
        [ -z "$clean_url" ] && continue
        output="${output}[$i] $title\n    $clean_url ($dimensions)\n    Source: $source_url\n"
        printf '[%d] %s\n    %s (%s)\n    Source: %s\n\n' "$i" "$title" "$clean_url" "$dimensions" "$source_url"
        i=$((i + 1))
    done <<< "$raw_results"
    _web_journal_results "$query" "$output" "serper-images"
}

# ── Summarize a web page via local LLM ────────────────────────
web_summary() {
    local text; text=$(web_fetch "$1")
    [ -z "$text" ] && return 1
    local truncated; truncated=$(echo "$text" | head -200)
    source "$LODGE_DIR/lib/core/llm.sh"
    local prompt="Summarize this web page in 3-5 bullet points. Be concise and factual.\n\nURL: $1\n\nContent:\n$truncated"
    ui_spinner_start "Summarizing"
    local result LLM_SCENARIO=tool; result=$(llm_generate "$prompt" "You are George, summarizing web content for your user." 256 "$LLM_BUDGET_TOOL")
    ui_spinner_stop
    echo "$result"
}

# ── Read a specific page section (by heading) ─────────────────
web_section() {
    local text; text=$(web_fetch "$1")
    [ -z "$text" ] && return 1
    echo "$text" | awk -v h="$2" 'tolower($0) ~ tolower(h) { found=1; print; next } found && /^[A-Z]/ && !/^[[:space:]]/ { found=0 } found { print }' | head -100
}

# ── Download a file ───────────────────────────────────────────
web_download() {
    local url="$1" dest="${2:-$(basename "$url")}"
    [ "${_AGENT_WEB_LOCKED:-0}" -eq 1 ] && { ui_err "Web actions are currently disabled by routing policy"; return 1; }
    if ! api_network_reachable 3; then ui_err "Web download unavailable: network is offline or unreachable"; return 1; fi
    local fullpath log_dest
    if [ -n "${AGENT_TASK_WORKSPACE:-}" ]; then
        mkdir -p "$AGENT_TASK_WORKSPACE" 2>/dev/null
        if [[ "$dest" == /* ]]; then
            if [[ "$dest" == "$AGENT_TASK_WORKSPACE"/* ]]; then fullpath="$dest"
            else dest="${dest#/}"; fullpath="$AGENT_TASK_WORKSPACE/$dest"; fi
        else fullpath="$AGENT_TASK_WORKSPACE/$dest"; fi
        log_dest="${AGENT_TASK_WORKSPACE_REL:-.george/workspaces}/${dest}"
    else fullpath="$dest"; log_dest="$dest"; fi
    ui_step "Downloading: $url"
    curl -sL --max-time 60 -H "User-Agent: $API_USER_AGENT" -o "$fullpath" "$url" 2>/dev/null
    if [ $? -eq 0 ] && [ -f "$fullpath" ]; then ui_ok "Downloaded: $log_dest ($(du -h "$fullpath" | cut -f1))"
    else ui_err "Download failed"; return 1; fi
}

web_enabled() { [ "${_AGENT_WEB_LOCKED:-0}" -ne 1 ]; }
web_configured() { return 0; }

web_reachable() {
    web_enabled || return 1
    api_network_reachable 3 || return 1
    local serper_key; serper_key=$(api_get_key "SERPER_API_KEY" 2>/dev/null)
    [ -n "$serper_key" ] && api_endpoint_reachable "https://google.serper.dev/search" 4 && return 0
    local pplx_key; pplx_key=$(api_get_key "PERPLEXITY_API_KEY" 2>/dev/null)
    [ -n "$pplx_key" ] && api_endpoint_reachable "https://api.perplexity.ai/chat/completions" 4 && return 0
    api_endpoint_reachable "https://lite.duckduckgo.com/lite/" 4
}

web_availability_summary() {
    local enabled="no" configured="no" reachable="no" provider="ddg"
    web_enabled && enabled="yes"; web_configured && configured="yes"; web_reachable && reachable="yes"
    if api_get_key "SERPER_API_KEY" &>/dev/null; then provider="serper"
    elif api_get_key "PERPLEXITY_API_KEY" &>/dev/null; then provider="perplexity"; fi
    echo "WEB_ENABLED: $enabled"
    echo "WEB_CONFIGURED: $configured"
    echo "WEB_REACHABLE: $reachable"
    echo "WEB_PROVIDER: $provider"
    declare -f api_service_awareness_summary &>/dev/null && api_service_awareness_summary
}

if [ -z "${_WEB_STATUS_PIPELINE_WRAPPED:-}" ] && declare -f commands_services_status &>/dev/null; then
    _WEB_STATUS_PIPELINE_WRAPPED=1
    eval "$(declare -f commands_services_status | sed '1s/commands_services_status/_web_status_pipeline_base/')"
    commands_services_status() {
        local _base; _base=$(_web_status_pipeline_base "$@"); echo "$_base"
        if declare -f api_service_awareness_summary &>/dev/null; then
            local _awareness; _awareness=$(api_service_awareness_summary)
            ! echo "$_base" | grep -q '^SERVICE_AWARENESS_VERSION:' && echo "$_awareness"
            local _web_provider; _web_provider=$(echo "$_awareness" | sed -n 's/^INFEASIBILITY_INPUT_WEB_PROVIDER: //p' | head -1)
            [ "$_web_provider" = "configured" ] && ! echo "$_base" | grep -q 'web-search' && echo "CONFIGURED_ALIAS: web-search"
        fi
    }
fi

# ── Check if a URL is reachable ───────────────────────────────
web_ping() {
    local start end elapsed status
    start=$(date +%s%N 2>/dev/null || date +%s)
    status=$(curl -sI --max-time 5 -o /dev/null -w "%{http_code}" "$1" 2>/dev/null)
    end=$(date +%s%N 2>/dev/null || date +%s)
    if [ ${#start} -gt 10 ]; then
        elapsed=$(( (end - start) / 1000000 ))
        printf "  %s → %s (%dms)\n" "$1" "$status" "$elapsed"
    else printf "  %s → %s\n" "$1" "$status"; fi
}

# ── GitHub Repository Search ───────────────────────────────────
web_search_github() {
    local query="$1" count="${2:-5}"
    [ -z "$query" ] && { ui_err "Usage: web_search_github <query> [count]"; return 1; }
    [ "${_AGENT_WEB_LOCKED:-0}" -eq 1 ] && { ui_err "GitHub web search disabled by routing policy"; return 1; }
    if ! api_network_reachable 3; then ui_err "GitHub search unavailable: network is offline or unreachable"; return 1; fi
    if declare -f mcp_enabled &>/dev/null && mcp_enabled; then
        local _mcp_result; _mcp_result=$(mcp_github_search "$query" "$count" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$_mcp_result" ]; then
            echo "$_mcp_result"; _web_journal_results "$query" "$_mcp_result" "github"; return 0
        fi
    fi
    local encoded; encoded=$(printf '%s' "$query" | jq -sRr @uri)
    local resp; resp=$(curl -sL --max-time "$WEB_TIMEOUT" -H "Accept: application/vnd.github.v3+json" -H "User-Agent: Blue-Lodge-George/0.1" "https://api.github.com/search/repositories?q=${encoded}&sort=stars&order=desc&per_page=${count}" 2>/dev/null)
    [ -z "$resp" ] && { ui_err "GitHub API request failed"; return 1; }
    local msg; msg=$(echo "$resp" | jq -r '.message // empty' 2>/dev/null)
    [ -n "$msg" ] && { ui_err "GitHub API: $msg"; return 1; }
    local total; total=$(echo "$resp" | jq -r '.total_count // 0' 2>/dev/null)
    [ "$total" -eq 0 ] 2>/dev/null && { ui_dim "No repositories found for: $query"; return 0; }
    local gh_output; gh_output=$(echo "$resp" | jq -r '.items[]? | "[\(.full_name)] ★\(.stargazers_count) (\(.language // "unknown"))\n    \(.description // "No description")\n    https://github.com/\(.full_name)\n"' 2>/dev/null)
    echo "$gh_output"
    _web_journal_results "$query" "$gh_output" "github"
}

# ── Verify a GitHub repo exists ────────────────────────────────
web_github_repo_exists() {
    local repo="${1%.git}"
    repo="${repo#https://github.com/}"
    repo="${repo#http://github.com/}"
    [[ ! "$repo" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] && return 1
    [ "${_AGENT_WEB_LOCKED:-0}" -eq 1 ] && return 1
    api_network_reachable 3 || return 1
    local status; status=$(curl -sI --max-time 5 -o /dev/null -w "%{http_code}" -H "Accept: application/vnd.github.v3+json" -H "User-Agent: Blue-Lodge-George/0.1" "https://api.github.com/repos/$repo" 2>/dev/null)
    [ "$status" = "200" ]
}

# ── Clear web cache ───────────────────────────────────────────
web_cache_clear() {
    if [ -d "$GEORGE_CACHE_DIR" ]; then rm -f "$GEORGE_CACHE_DIR"/web_* 2>/dev/null; ui_ok "Web cache cleared"; fi
}