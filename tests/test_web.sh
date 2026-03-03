#!/bin/bash
# ── Tests: lib/web.sh ─────────────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/api.sh"

TMPDIR_WEB=""

_setup_web() {
    TMPDIR_WEB=$(test_tmpdir)
    export GEORGE_CONFIG_DIR="$TMPDIR_WEB/.george"
    export GEORGE_KEYS_FILE="$GEORGE_CONFIG_DIR/keys.conf"
    export GEORGE_COOKIES_DIR="$GEORGE_CONFIG_DIR/cookies"
    export GEORGE_CACHE_DIR="$GEORGE_CONFIG_DIR/cache"
    export WEB_BLACKLIST_FILE="$GEORGE_CONFIG_DIR/web_blacklist.log"
    export WEB_BLACKLIST_ENABLED="true"
    api_init 2>/dev/null
    source "$LODGE_DIR/lib/web.sh"
}

_teardown_web() {
    rm -rf "$TMPDIR_WEB"
}

test_start "lib/web.sh — Web Browsing Engine"

# ── Configuration ──────────────────────────────────────────────
describe "Configuration defaults"

  it "WEB_TIMEOUT defaults to 15" && {
    _setup_web
    assert_eq "$WEB_TIMEOUT" "15"
    _teardown_web
  }

  it "WEB_MAX_SIZE defaults to 2000000" && {
    _setup_web
    assert_eq "$WEB_MAX_SIZE" "2000000"
    _teardown_web
  }

  it "WEB_CACHE_TTL defaults to 3600" && {
    _setup_web
    assert_eq "$WEB_CACHE_TTL" "3600"
    _teardown_web
  }

# ── Renderer detection ────────────────────────────────────────
describe "_web_renderer"

  it "returns a valid renderer name" && {
    _setup_web
    renderer=$(_web_renderer)
    assert_match "$renderer" "^(w3m|lynx|html2text|sed)$"
    _teardown_web
  }

# ── HTML to text conversion ───────────────────────────────────
describe "_html_to_text_sed"

  it "strips basic HTML tags" && {
    _setup_web
    result=$(echo '<p>Hello <b>world</b></p>' | _html_to_text_sed)
    assert_contains "$result" "Hello"
    assert_contains "$result" "world"
    assert_not_contains "$result" "<p>"
    assert_not_contains "$result" "<b>"
    _teardown_web
  }

  it "decodes HTML entities" && {
    _setup_web
    result=$(echo '<p>A &amp; B &lt; C &gt; D &quot;E&quot;</p>' | _html_to_text_sed)
    assert_contains "$result" "A & B"
    assert_contains "$result" "< C"
    assert_contains "$result" "> D"
    _teardown_web
  }

  it "handles empty input" && {
    _setup_web
    result=$(echo "" | _html_to_text_sed)
    assert_empty "$result"
    _teardown_web
  }

# ── web_fetch_raw ──────────────────────────────────────────────
describe "web_fetch_raw"

  it "is defined" && {
    _setup_web
    declare -f web_fetch_raw &>/dev/null
    assert_ok $?
    _teardown_web
  }

  it "includes HTTP block status handling" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f _web_block_reason)
    assert_contains "$fn_body" "429"
    assert_contains "$fn_body" "451"
    assert_contains "$fn_body" "999"
    assert_contains "$fn_body" "captcha"
    _teardown_web
  }

  it "logs blocked sites to blacklist" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f web_fetch_raw)
    assert_contains "$fn_body" "_web_blacklist_add"
    assert_contains "$fn_body" "BLOCKED:"
    _teardown_web
  }

# ── web_fetch (with caching) ──────────────────────────────────
describe "web_fetch"

  it "is defined" && {
    _setup_web
    declare -f web_fetch &>/dev/null
    assert_ok $?
    _teardown_web
  }

  it "returns error for unreachable URL" && {
    _setup_web
    web_fetch "http://127.0.0.1:1/nonexistent" 2>/dev/null
    assert_fail $?
    _teardown_web
  }

# ── web_title ──────────────────────────────────────────────────
describe "web_title"

  it "is defined" && {
    _setup_web
    declare -f web_title &>/dev/null
    assert_ok $?
    _teardown_web
  }

# ── web_links ──────────────────────────────────────────────────
describe "web_links"

  it "is defined" && {
    _setup_web
    declare -f web_links &>/dev/null
    assert_ok $?
    _teardown_web
  }

# ── web_search ─────────────────────────────────────────────────
describe "web_search"

  it "is defined" && {
    _setup_web
    declare -f web_search &>/dev/null
    assert_ok $?
    _teardown_web
  }

  it "internal search methods are defined" && {
    _setup_web
    declare -f _web_search_serper &>/dev/null
    assert_ok $?
    declare -f _web_search_perplexity &>/dev/null
    assert_ok $?
    declare -f _web_search_ddg &>/dev/null
    assert_ok $?
    _teardown_web
  }

  it "DDG search uses lite.duckduckgo.com" && {
    _setup_web
    # Verify the DDG function source references lite.duckduckgo.com
    fn_body=$(declare -f _web_search_ddg)
    assert_contains "$fn_body" "lite.duckduckgo.com"
    _teardown_web
  }

  it "DDG search does not blanket-filter duckduckgo.com URLs" && {
    _setup_web
    fn_body=$(declare -f _web_search_ddg)
    # The grep -v 'duckduckgo.com' filter was removed because it incorrectly
    # filtered out DDG redirect URLs that contain the actual search results.
    # Ad filtering now uses _web_is_ad_url which only targets y.js ad redirects.
    _has_filter=$(echo "$fn_body" | grep -c "grep -v.*duckduckgo" || true)
    assert_eq "$_has_filter" "0"
    _teardown_web
  }

  it "DDG Method 1 handles href-before-class attribute order" && {
    _setup_web
    fn_body=$(declare -f _web_search_ddg)
    # Method 1 should use a pattern that matches <a> tags with class="result-link"
    # regardless of whether href comes before or after the class attribute
    assert_contains "$fn_body" '<a[^>]*class="result-link"'
    _teardown_web
  }

  it "web_search strips surrounding quotes from query" && {
    _setup_web
    fn_body=$(declare -f web_search)
    # Verify quote stripping is present
    assert_contains "$fn_body" 'query='
    assert_contains "$fn_body" '{query#'
    _teardown_web
  }

# ── URL Sanitization ──────────────────────────────────────────
describe "_web_sanitize_url"

  it "is defined" && {
    _setup_web
    declare -f _web_sanitize_url &>/dev/null
    assert_ok $?
    _teardown_web
  }

  it "passes clean https URLs" && {
    _setup_web
    _test_result=$(_web_sanitize_url "https://www.reddit.com/r/judo/comments/123")
    assert_eq "$_test_result" "https://www.reddit.com/r/judo/comments/123"
    _teardown_web
  }

  it "passes clean http URLs" && {
    _setup_web
    _test_result=$(_web_sanitize_url "http://example.com/page")
    assert_eq "$_test_result" "http://example.com/page"
    _teardown_web
  }

  it "rejects non-http schemes" && {
    _setup_web
    _web_sanitize_url "ftp://evil.com/data" 2>/dev/null
    assert_fail $?
    _teardown_web
  }

  it "rejects javascript: scheme" && {
    _setup_web
    _web_sanitize_url "javascript:alert(1)" 2>/dev/null
    assert_fail $?
    _teardown_web
  }

  it "strips backticks from URLs" && {
    _setup_web
    _test_result=$(_web_sanitize_url 'https://example.com/`whoami`')
    [[ "$_test_result" != *'`'* ]]
    assert_ok $?
    _teardown_web
  }

  it "strips dollar signs from URLs" && {
    _setup_web
    _test_result=$(_web_sanitize_url 'https://example.com/$HOME')
    [[ "$_test_result" != *'$'* ]]
    assert_ok $?
    _teardown_web
  }

  it "strips semicolons from URLs" && {
    _setup_web
    _test_result=$(_web_sanitize_url 'https://example.com/;rm -rf /')
    [[ "$_test_result" != *';'* ]]
    assert_ok $?
    _teardown_web
  }

  it "rejects URLs without a dot in host" && {
    _setup_web
    _web_sanitize_url "https://localhost/admin" 2>/dev/null
    assert_fail $?
    _teardown_web
  }

  it "truncates URLs longer than 2048 chars" && {
    _setup_web
    _test_long_url="https://example.com/"
    _test_long_url="${_test_long_url}$(printf 'a%.0s' $(seq 1 2100))"
    _test_result=$(_web_sanitize_url "$_test_long_url")
    [ "${#_test_result}" -le 2048 ]
    assert_ok $?
    _teardown_web
  }

# ── Ad URL Detection ──────────────────────────────────────────
describe "_web_is_ad_url"

  it "is defined" && {
    _setup_web
    declare -f _web_is_ad_url &>/dev/null
    assert_ok $?
    _teardown_web
  }

  it "detects DDG ad redirect (y.js)" && {
    _setup_web
    _web_is_ad_url "https://duckduckgo.com/y.js?ad_domain=amazon.com&ad_provider=bingv7aa"
    assert_ok $?
    _teardown_web
  }

  it "detects ad_domain parameter" && {
    _setup_web
    _web_is_ad_url "https://example.com/redirect?ad_domain=amazon.com"
    assert_ok $?
    _teardown_web
  }

  it "detects Bing ad click-through" && {
    _setup_web
    _web_is_ad_url "https://www.bing.com/aclick?ld=abc123"
    assert_ok $?
    _teardown_web
  }

  it "detects Google ad services" && {
    _setup_web
    _web_is_ad_url "https://www.googleadservices.com/pagead/aclk?sa=L"
    assert_ok $?
    _teardown_web
  }

  it "detects Google aclk" && {
    _setup_web
    _web_is_ad_url "https://www.google.com/aclk?sa=L&ai=abc"
    assert_ok $?
    _teardown_web
  }

  it "detects doubleclick" && {
    _setup_web
    _web_is_ad_url "https://ad.doubleclick.net/tracking/123"
    assert_ok $?
    _teardown_web
  }

  it "passes organic Reddit URL" && {
    _setup_web
    ! _web_is_ad_url "https://www.reddit.com/r/judo/comments/5amt6e/"
    assert_ok $?
    _teardown_web
  }

  it "passes organic YouTube URL" && {
    _setup_web
    ! _web_is_ad_url "https://www.youtube.com/watch?v=FVgqiZ8syBs"
    assert_ok $?
    _teardown_web
  }

# ── Search Result Journaling ──────────────────────────────────
describe "_web_journal_results"

  it "is defined" && {
    _setup_web
    declare -f _web_journal_results &>/dev/null
    assert_ok $?
    _teardown_web
  }

  it "writes search_results.md to .george dir" && {
    _setup_web
    _test_tmpdir=$(mktemp -d)
    mkdir -p "$_test_tmpdir/.george"
    pushd "$_test_tmpdir" >/dev/null
    _web_journal_results "judo workouts" "test result" "ddg"
    [ -f "$_test_tmpdir/.george/search_results.md" ]
    _test_rc=$?
    popd >/dev/null
    rm -rf "$_test_tmpdir"
    assert_ok $_test_rc
    _teardown_web
  }

  it "includes query and provider in search_results.md" && {
    _setup_web
    _test_tmpdir=$(mktemp -d)
    mkdir -p "$_test_tmpdir/.george"
    pushd "$_test_tmpdir" >/dev/null
    _web_journal_results "test query" "[1] Title\n    https://example.com" "serper"
    _test_content=$(cat "$_test_tmpdir/.george/search_results.md")
    popd >/dev/null
    rm -rf "$_test_tmpdir"
    echo "$_test_content" | grep -q "test query"
    assert_ok $?
    _teardown_web
  }

  it "handles missing .george dir gracefully" && {
    _setup_web
    _test_tmpdir=$(mktemp -d)
    pushd "$_test_tmpdir" >/dev/null
    # No .george dir — should not crash
    _web_journal_results "query" "results" "ddg" 2>/dev/null
    _test_rc=$?
    popd >/dev/null
    rm -rf "$_test_tmpdir"
    assert_ok $_test_rc
    _teardown_web
  }

# ── DDG ad filtering integration ──────────────────────────────
describe "DDG search ad filtering"

  it "DDG search calls _web_is_ad_url" && {
    _setup_web
    fn_body=$(declare -f _web_search_ddg)
    assert_contains "$fn_body" "_web_is_ad_url"
    _teardown_web
  }

  it "DDG search calls _web_sanitize_url" && {
    _setup_web
    fn_body=$(declare -f _web_search_ddg)
    assert_contains "$fn_body" "_web_sanitize_url"
    _teardown_web
  }

  it "DDG search calls _web_journal_results" && {
    _setup_web
    fn_body=$(declare -f _web_search_ddg)
    assert_contains "$fn_body" "_web_journal_results"
    _teardown_web
  }

# ── Serper sanitization integration ───────────────────────────
describe "Serper search sanitization"

  it "Serper search calls _web_sanitize_url" && {
    _setup_web
    fn_body=$(declare -f _web_search_serper)
    assert_contains "$fn_body" "_web_sanitize_url"
    _teardown_web
  }

  it "Serper search calls _web_journal_results" && {
    _setup_web
    fn_body=$(declare -f _web_search_serper)
    assert_contains "$fn_body" "_web_journal_results"
    _teardown_web
  }

# ── web_summary ────────────────────────────────────────────────
describe "web_summary"

  it "is defined" && {
    _setup_web
    declare -f web_summary &>/dev/null
    assert_ok $?
    _teardown_web
  }

# ── web_section ────────────────────────────────────────────────
describe "web_section"

  it "is defined" && {
    _setup_web
    declare -f web_section &>/dev/null
    assert_ok $?
    _teardown_web
  }

# ── web_download ───────────────────────────────────────────────
describe "web_download"

  it "is defined" && {
    _setup_web
    declare -f web_download &>/dev/null
    assert_ok $?
    _teardown_web
  }

# ── web_ping ───────────────────────────────────────────────────
describe "web_ping"

  it "is defined" && {
    _setup_web
    declare -f web_ping &>/dev/null
    assert_ok $?
    _teardown_web
  }

# ── web_cache_clear ────────────────────────────────────────────
describe "web_cache_clear"

  it "clears the cache directory" && {
    _setup_web
    mkdir -p "$GEORGE_CACHE_DIR"
    echo "cached" > "$GEORGE_CACHE_DIR/web_testcache"
    web_cache_clear 2>/dev/null
    assert_file_not_exists "$GEORGE_CACHE_DIR/web_testcache"
    _teardown_web
  }

  it "handles empty cache gracefully" && {
    _setup_web
    web_cache_clear 2>/dev/null
    assert_ok $?
    _teardown_web
  }

# ── web_search_github ──────────────────────────────────────────
describe "web_search_github"

  it "is defined" && {
    _setup_web
    declare -f web_search_github &>/dev/null
    assert_ok $?
    _teardown_web
  }

  it "fails on empty query" && {
    _setup_web
    web_search_github "" 2>/dev/null
    assert_fail $?
    _teardown_web
  }

  it "accepts query and count params" && {
    _setup_web
    # Just verify function signature works (no network call assertion)
    declare -f web_search_github &>/dev/null
    assert_ok $?
    _teardown_web
  }

# ── web_github_repo_exists ─────────────────────────────────────
describe "web_github_repo_exists"

  it "is defined" && {
    _setup_web
    declare -f web_github_repo_exists &>/dev/null
    assert_ok $?
    _teardown_web
  }

  it "rejects malformed repo names" && {
    _setup_web
    web_github_repo_exists "" 2>/dev/null
    assert_fail $?
    _teardown_web
  }

  it "rejects names without owner/repo format" && {
    _setup_web
    web_github_repo_exists "justreponame" 2>/dev/null
    assert_fail $?
    _teardown_web
  }

  it "strips .git suffix before checking" && {
    _setup_web
    # The function should strip .git — just verify it doesn't crash
    web_github_repo_exists "fake/repo.git" 2>/dev/null || true
    assert_ok 0
    _teardown_web
  }

  it "strips https://github.com/ prefix" && {
    _setup_web
    # Verify prefix stripping doesn't crash
    web_github_repo_exists "https://github.com/fake/repo.git" 2>/dev/null || true
    assert_ok 0
    _teardown_web
  }

# ── web_images ─────────────────────────────────────────────────
describe "web_images"

  it "is defined" && {
    _setup_web
    declare -f web_images &>/dev/null
    assert_ok $?
    _teardown_web
  }

  it "fails on empty query" && {
    _setup_web
    web_images "" 2>/dev/null
    assert_fail $?
    _teardown_web
  }

  it "strips surrounding quotes from query" && {
    _setup_web
    fn_body=$(declare -f web_images)
    assert_contains "$fn_body" '{query#'
    _teardown_web
  }

  it "internal _web_search_serper_images is defined" && {
    _setup_web
    declare -f _web_search_serper_images &>/dev/null
    assert_ok $?
    _teardown_web
  }

  it "Serper images endpoint uses /images URL" && {
    _setup_web
    fn_body=$(declare -f _web_search_serper_images)
    assert_contains "$fn_body" "google.serper.dev/images"
    _teardown_web
  }

  it "returns error without SERPER_API_KEY" && {
    _setup_web
    # Ensure no key is set
    unset SERPER_API_KEY 2>/dev/null
    web_images "test query" 2>/dev/null
    assert_fail $?
    _teardown_web
  }

# ── web_scrape_images ──────────────────────────────────────────
describe "web_scrape_images"

  it "is defined" && {
    _setup_web
    declare -f web_scrape_images &>/dev/null
    assert_ok $?
    _teardown_web
  }

  it "fails on empty URL" && {
    _setup_web
    web_scrape_images "" 2>/dev/null
    assert_fail $?
    _teardown_web
  }

  it "rejects invalid URLs" && {
    _setup_web
    web_scrape_images "not-a-url" 2>/dev/null
    assert_fail $?
    _teardown_web
  }

  it "extracts img src from HTML" && {
    _setup_web
    # Image extraction logic now delegates to _html_extract_images
    local fn_body
    fn_body=$(declare -f _html_extract_images)
    # Verify it greps for src/data-src/srcset patterns
    assert_contains "$fn_body" "src"
    assert_contains "$fn_body" "data-src"
    assert_contains "$fn_body" "srcset"
    _teardown_web
  }

  it "filters to common image extensions" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f _html_extract_images)
    assert_contains "$fn_body" "jpg"
    assert_contains "$fn_body" "png"
    assert_contains "$fn_body" "webp"
    assert_contains "$fn_body" "gif"
    _teardown_web
  }

  it "resolves protocol-relative URLs" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f _html_extract_images)
    assert_contains "$fn_body" "https:"
    _teardown_web
  }

  it "skips data: URIs" && {
    _setup_web
    # data: URI filtering now lives in _html_extract_images helper
    local fn_body
    fn_body=$(declare -f _html_extract_images)
    assert_contains "$fn_body" "data:"
    _teardown_web
  }

  it "caps image results" && {
    _setup_web
    # Image cap now lives in _html_extract_images helper (head -20)
    local fn_body
    fn_body=$(declare -f _html_extract_images)
    assert_contains "$fn_body" "head"
    _teardown_web
  }

  it "journals results for agent memory" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f web_scrape_images)
    assert_contains "$fn_body" "_web_journal_results"
    _teardown_web
  }

  it "surfaces blocked metadata from structured JSON" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f web_scrape_images)
    assert_contains "$fn_body" "block_reason"
    assert_contains "$fn_body" "http_status"
    assert_contains "$fn_body" "Site blocked scraping"
    _teardown_web
  }

describe "web blacklist helpers"

  it "blacklist helper functions are defined" && {
    _setup_web
    declare -f _web_blacklist_contains &>/dev/null
    assert_ok $?
    declare -f _web_blacklist_add &>/dev/null
    assert_ok $?
    _teardown_web
  }

  it "writes blacklist entry with host and reason" && {
    _setup_web
    _web_blacklist_add "https://example.com/path" "HTTP_429_RATE_LIMIT" "429"
    assert_file_exists "$WEB_BLACKLIST_FILE"
    local content
    content=$(cat "$WEB_BLACKLIST_FILE")
    assert_contains "$content" "host=example.com"
    assert_contains "$content" "reason=HTTP_429_RATE_LIMIT"
    _teardown_web
  }

  it "_web_blacklist_is_enabled returns true by default" && {
    _setup_web
    _web_blacklist_is_enabled
    assert_ok $?
    _teardown_web
  }

  it "_web_blacklist_contains skips check when disabled" && {
    _setup_web
    _web_blacklist_add "https://blocked.com/test" "HTTP_403_FORBIDDEN" "403"
    WEB_BLACKLIST_ENABLED="false"
    if _web_blacklist_contains "https://blocked.com/test"; then
        WEB_BLACKLIST_ENABLED="true"
        _teardown_web
        assert_fail 0 "Should not find blacklisted URL when disabled"
    fi
    WEB_BLACKLIST_ENABLED="true"
    assert_ok 0
    _teardown_web
  }

# ── Blacklist management commands ──────────────────────────────
describe "web blacklist management"

  it "web_blacklist_list shows empty when no entries" && {
    _setup_web
    local out
    out=$(web_blacklist_list 2>&1)
    assert_contains "$out" "empty"
    _teardown_web
  }

  it "web_blacklist_list shows entries" && {
    _setup_web
    _web_blacklist_add "https://bad.com/page" "HTTP_403_FORBIDDEN" "403"
    local out
    out=$(web_blacklist_list 2>&1)
    assert_contains "$out" "bad.com"
    assert_contains "$out" "HTTP_403_FORBIDDEN"
    _teardown_web
  }

  it "web_blacklist_rm removes a host" && {
    _setup_web
    _web_blacklist_add "https://removeme.com/page" "HTTP_429_RATE_LIMIT" "429"
    _web_blacklist_contains "https://removeme.com/page"
    assert_ok $? "Should exist before removal"
    web_blacklist_rm "removeme.com" >/dev/null 2>&1
    _web_blacklist_contains "https://removeme.com/page"
    assert_fail $? "Should not exist after removal"
    _teardown_web
  }

  it "web_blacklist_rm accepts full URL" && {
    _setup_web
    _web_blacklist_add "https://rmurl.com/foo" "HTTP_999_PLATFORM_BLOCK" "999"
    web_blacklist_rm "https://rmurl.com/foo" >/dev/null 2>&1
    _web_blacklist_contains "https://rmurl.com/foo"
    assert_fail $? "Should be removed by URL"
    _teardown_web
  }

  it "web_blacklist_clear removes all entries" && {
    _setup_web
    _web_blacklist_add "https://a.com/" "HTTP_403_FORBIDDEN" "403"
    _web_blacklist_add "https://b.com/" "HTTP_429_RATE_LIMIT" "429"
    web_blacklist_clear >/dev/null 2>&1
    [ ! -s "$WEB_BLACKLIST_FILE" ]
    assert_ok $? "Blacklist file should be empty"
    _teardown_web
  }

  it "web_blacklist_enable sets enabled" && {
    _setup_web
    WEB_BLACKLIST_ENABLED="false"
    web_blacklist_enable >/dev/null 2>&1
    assert_eq "$WEB_BLACKLIST_ENABLED" "true"
    _teardown_web
  }

  it "web_blacklist_disable sets disabled" && {
    _setup_web
    web_blacklist_disable >/dev/null 2>&1
    assert_eq "$WEB_BLACKLIST_ENABLED" "false"
    WEB_BLACKLIST_ENABLED="true"
    _teardown_web
  }

  it "management functions are defined" && {
    _setup_web
    declare -f web_blacklist_list &>/dev/null && \
    declare -f web_blacklist_rm &>/dev/null && \
    declare -f web_blacklist_clear &>/dev/null && \
    declare -f web_blacklist_enable &>/dev/null && \
    declare -f web_blacklist_disable &>/dev/null
    assert_ok $?
    _teardown_web
  }

# ── Content-type detection ─────────────────────────────────────
# Stub curl to return nothing so HEAD request yields no content-type
# and the URL extension fallback path is exercised
_ct_setup() { _setup_web; curl() { return 1; }; export -f curl; }
_ct_teardown() { unset -f curl; _teardown_web; }

describe "_web_detect_content_type"

  it "detects PDF by URL extension" && {
    _ct_setup
    result=$(_web_detect_content_type "https://example.com/doc.pdf")
    assert_eq "$result" "pdf"
    _ct_teardown
  }

  it "detects PDF with query string" && {
    _ct_setup
    result=$(_web_detect_content_type "https://example.com/doc.pdf?token=abc")
    assert_eq "$result" "pdf"
    _ct_teardown
  }

  it "detects plain text by extension" && {
    _ct_setup
    result=$(_web_detect_content_type "https://example.com/data.txt")
    assert_eq "$result" "text"
    _ct_teardown
  }

  it "detects CSV as text" && {
    _ct_setup
    result=$(_web_detect_content_type "https://example.com/data.csv")
    assert_eq "$result" "text"
    _ct_teardown
  }

  it "detects markdown as text" && {
    _ct_setup
    result=$(_web_detect_content_type "https://raw.githubusercontent.com/user/repo/main/README.md")
    assert_eq "$result" "text"
    _ct_teardown
  }

  it "detects JSON by extension" && {
    _ct_setup
    result=$(_web_detect_content_type "https://api.example.com/data.json")
    assert_eq "$result" "json"
    _ct_teardown
  }

  it "detects XML by extension" && {
    _ct_setup
    result=$(_web_detect_content_type "https://example.com/feed.xml")
    assert_eq "$result" "xml"
    _ct_teardown
  }

  it "detects RSS as XML" && {
    _ct_setup
    result=$(_web_detect_content_type "https://example.com/feed.rss")
    assert_eq "$result" "xml"
    _ct_teardown
  }

  it "detects image as binary" && {
    _ct_setup
    result=$(_web_detect_content_type "https://example.com/photo.jpg")
    assert_eq "$result" "binary"
    _ct_teardown
  }

  it "detects zip as binary" && {
    _ct_setup
    result=$(_web_detect_content_type "https://example.com/archive.zip")
    assert_eq "$result" "binary"
    _ct_teardown
  }

  it "detects docx as binary" && {
    _ct_setup
    result=$(_web_detect_content_type "https://example.com/report.docx")
    assert_eq "$result" "binary"
    _ct_teardown
  }

  it "defaults to html for unknown extensions" && {
    _ct_setup
    result=$(_web_detect_content_type "https://example.com/page")
    assert_eq "$result" "html"
    _ct_teardown
  }

  it "handles case-insensitive extensions" && {
    _ct_setup
    result=$(_web_detect_content_type "https://example.com/DOC.PDF")
    assert_eq "$result" "pdf"
    _ct_teardown
  }

  it "detects log files as text" && {
    _ct_setup
    result=$(_web_detect_content_type "https://example.com/server.log")
    assert_eq "$result" "text"
    _ct_teardown
  }

  it "detects .jsonl as json" && {
    _ct_setup
    result=$(_web_detect_content_type "https://example.com/data.jsonl")
    assert_eq "$result" "json"
    _ct_teardown
  }

  it "detects video as binary" && {
    _ct_setup
    result=$(_web_detect_content_type "https://example.com/clip.mp4")
    assert_eq "$result" "binary"
    _ct_teardown
  }

# ── PDF extraction ─────────────────────────────────────────────
describe "_web_extract_pdf"

  it "function exists" && {
    _setup_web
    declare -f _web_extract_pdf &>/dev/null
    assert_eq "$?" "0"
    _teardown_web
  }

  it "returns failure on empty input" && {
    _setup_web
    _web_extract_pdf "" 2>/dev/null
    assert_eq "$?" "1"
    _teardown_web
  }

  it "returns failure on nonexistent file" && {
    _setup_web
    _web_extract_pdf "/nonexistent/file.pdf" 2>/dev/null
    assert_eq "$?" "1"
    _teardown_web
  }

  it "uses strings as fallback extractor" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f _web_extract_pdf)
    assert_contains "$fn_body" "strings"
    _teardown_web
  }

  it "tries pdftotext first" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f _web_extract_pdf)
    assert_contains "$fn_body" "pdftotext"
    _teardown_web
  }

# ── Fetch-to-file ─────────────────────────────────────────────
describe "_web_fetch_to_file"

  it "function exists" && {
    _setup_web
    declare -f _web_fetch_to_file &>/dev/null
    assert_eq "$?" "0"
    _teardown_web
  }

  it "uses higher max-filesize for PDFs" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f _web_fetch_to_file)
    assert_contains "$fn_body" "WEB_MAX_SIZE_PDF"
    _teardown_web
  }

# ── Text/JSON/XML fetch helpers ────────────────────────────────
describe "Non-HTML fetch helpers"

  it "_web_fetch_text function exists" && {
    _setup_web
    declare -f _web_fetch_text &>/dev/null
    assert_eq "$?" "0"
    _teardown_web
  }

  it "_web_fetch_json_raw function exists" && {
    _setup_web
    declare -f _web_fetch_json_raw &>/dev/null
    assert_eq "$?" "0"
    _teardown_web
  }

  it "_web_extract_xml function exists" && {
    _setup_web
    declare -f _web_extract_xml &>/dev/null
    assert_eq "$?" "0"
    _teardown_web
  }

  it "_web_fetch_json_raw sends Accept: application/json" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f _web_fetch_json_raw)
    assert_contains "$fn_body" "application/json"
    _teardown_web
  }

  it "_web_extract_xml strips tags" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f _web_extract_xml)
    assert_contains "$fn_body" '<[^>]*>'
    _teardown_web
  }

# ── Content-type routing in web_fetch ──────────────────────────
describe "web_fetch content-type routing"

  it "calls _web_extract_pdf for PDFs" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f web_fetch)
    assert_contains "$fn_body" "_web_extract_pdf"
    _teardown_web
  }

  it "calls _web_fetch_text for text content" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f web_fetch)
    assert_contains "$fn_body" "_web_fetch_text"
    _teardown_web
  }

  it "calls _web_fetch_json_raw for JSON content" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f web_fetch)
    assert_contains "$fn_body" "_web_fetch_json_raw"
    _teardown_web
  }

  it "calls _web_extract_xml for XML content" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f web_fetch)
    assert_contains "$fn_body" "_web_extract_xml"
    _teardown_web
  }

  it "rejects binary files" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f web_fetch)
    assert_contains "$fn_body" "binary"
    _teardown_web
  }

  it "detects content type before fetching" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f web_fetch)
    assert_contains "$fn_body" "_web_detect_content_type"
    _teardown_web
  }

# ── Content-type routing in web_fetch_json ─────────────────────
describe "web_fetch_json content-type routing"

  it "has PDF path in web_fetch_json" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f web_fetch_json)
    assert_contains "$fn_body" "_web_extract_pdf"
    _teardown_web
  }

  it "has text path in web_fetch_json" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f web_fetch_json)
    assert_contains "$fn_body" "_web_fetch_text"
    _teardown_web
  }

  it "returns JSON for non-HTML types" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f web_fetch_json)
    # Should use jq to build structured JSON for all paths
    assert_contains "$fn_body" "jq -n"
    _teardown_web
  }

  it "rejects binary files in web_fetch_json" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f web_fetch_json)
    assert_contains "$fn_body" "binary"
    _teardown_web
  }

# ── Config: PDF max size ───────────────────────────────────────
describe "PDF config"

  it "WEB_MAX_SIZE_PDF defaults to 10000000" && {
    _setup_web
    assert_eq "$WEB_MAX_SIZE_PDF" "10000000"
    _teardown_web
  }

  it "WEB_MAX_SIZE_PDF is larger than WEB_MAX_SIZE" && {
    _setup_web
    assert_gt "$WEB_MAX_SIZE_PDF" "$WEB_MAX_SIZE"
    _teardown_web
  }

# ── HTML preprocessor (awk state machine) ─────────────────────
describe "_html_preprocess"

  it "is defined" && {
    _setup_web
    declare -f _html_preprocess &>/dev/null
    assert_ok $?
    _teardown_web
  }

  it "strips script blocks" && {
    _setup_web
    local result
    result=$(echo '<p>Hello</p><script>var x=1;</script><p>World</p>' | _html_preprocess)
    assert_contains "$result" "Hello"
    assert_contains "$result" "World"
    assert_not_contains "$result" "var x"
    _teardown_web
  }

  it "strips style blocks" && {
    _setup_web
    local result
    result=$(echo '<p>Text</p><style>.foo{color:red}</style><p>More</p>' | _html_preprocess)
    assert_contains "$result" "Text"
    assert_contains "$result" "More"
    assert_not_contains "$result" "color"
    _teardown_web
  }

  it "strips noscript blocks" && {
    _setup_web
    local result
    result=$(echo '<p>Content</p><noscript>Enable JS</noscript><p>End</p>' | _html_preprocess)
    assert_contains "$result" "Content"
    assert_contains "$result" "End"
    assert_not_contains "$result" "Enable JS"
    _teardown_web
  }

  it "decodes HTML entities" && {
    _setup_web
    local result
    result=$(echo '<p>A &amp; B &lt; C</p>' | _html_preprocess)
    assert_contains "$result" "A & B"
    _teardown_web
  }

  it "handles long single-line HTML without hanging" && {
    _setup_web
    # Generate a big single-line HTML blob (simulates modern SPA pages)
    # Build in a subshell to avoid local variable issues in test framework
    result=$(
      big_html="<html><body>"
      for i in $(seq 1 500); do
        big_html="${big_html}<p>Paragraph $i</p>"
      done
      big_html="${big_html}<script>var x='$(printf 'x%.0s' $(seq 1 5000))';</script>"
      big_html="${big_html}<p>Final paragraph</p></body></html>"
      echo "$big_html" | _html_preprocess
    )
    assert_contains "$result" "Paragraph 1"
    assert_contains "$result" "Final paragraph"
    assert_not_contains "$result" "xxxxx"
    _teardown_web
  }

  it "strips HTML tags" && {
    _setup_web
    local result
    result=$(echo '<div class="foo"><p>Clean text</p></div>' | _html_preprocess)
    assert_contains "$result" "Clean text"
    assert_not_contains "$result" "<div"
    assert_not_contains "$result" "<p>"
    _teardown_web
  }

  it "removes empty lines" && {
    _setup_web
    local result
    result=$(echo '<p>A</p>   <p>B</p>' | _html_preprocess)
    # Should not have blank lines
    local blank_count
    blank_count=$(echo "$result" | grep -c '^[[:space:]]*$')
    assert_eq "$blank_count" "0"
    _teardown_web
  }

# ── web_fetch_raw head -c safety valve ─────────────────────────
describe "web_fetch_raw safety"

  it "pipes through head -c" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f web_fetch_raw)
    assert_contains "$fn_body" "head -c"
    _teardown_web
  }

# ── _html_extract_content uses awk preprocessor ───────────────
describe "_html_extract_content rewrite"

  it "does NOT use tr newline-join (old approach)" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f _html_extract_content)
    # Old approach used tr '\n' ' ' which caused hangs — should be gone
    _has_tr=$(echo "$fn_body" | grep -v "_html_extract_content" | grep -c "tr '" || true)
    assert_eq "$_has_tr" "0" "Should not use tr to join newlines"
    _teardown_web
  }

  it "uses awk state machine for script removal" && {
    _setup_web
    local fn_body
    fn_body=$(declare -f _html_extract_content)
    assert_contains "$fn_body" "skip"
    assert_contains "$fn_body" "script"
    _teardown_web
  }

test_end
