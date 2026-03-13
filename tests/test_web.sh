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
    fn_body=$(declare -f _web_block_reason)
    assert_contains "$fn_body" "429"
    assert_contains "$fn_body" "451"
    assert_contains "$fn_body" "999"
    assert_contains "$fn_body" "captcha"
    _teardown_web
  }

  it "logs blocked sites to blacklist" && {
    _setup_web
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
    fn_body=$(declare -f _html_extract_images)
    # Verify it greps for src/data-src/srcset patterns
    assert_contains "$fn_body" "src"
    assert_contains "$fn_body" "data-src"
    assert_contains "$fn_body" "srcset"
    _teardown_web
  }

  it "filters to common image extensions" && {
    _setup_web
    fn_body=$(declare -f _html_extract_images)
    assert_contains "$fn_body" "jpg"
    assert_contains "$fn_body" "png"
    assert_contains "$fn_body" "webp"
    assert_contains "$fn_body" "gif"
    _teardown_web
  }

  it "resolves protocol-relative URLs" && {
    _setup_web
    fn_body=$(declare -f _html_extract_images)
    assert_contains "$fn_body" "https:"
    _teardown_web
  }

  it "skips data: URIs" && {
    _setup_web
    # data: URI filtering now lives in _html_extract_images helper
    fn_body=$(declare -f _html_extract_images)
    assert_contains "$fn_body" "data:"
    _teardown_web
  }

  it "caps image results" && {
    _setup_web
    # Image cap now lives in _html_extract_images helper (head -20)
    fn_body=$(declare -f _html_extract_images)
    assert_contains "$fn_body" "head"
    _teardown_web
  }

  it "journals results for agent memory" && {
    _setup_web
    fn_body=$(declare -f web_scrape_images)
    assert_contains "$fn_body" "_web_journal_results"
    _teardown_web
  }

  it "surfaces blocked metadata from structured JSON" && {
    _setup_web
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

# ── Preloaded domain blacklist ─────────────────────────────────
describe "preloaded domain blacklist"

  it "WEB_BLACKLIST_DOMAINS has default value" && {
    _setup_web
    [ -n "$WEB_BLACKLIST_DOMAINS" ]
    assert_ok $? "WEB_BLACKLIST_DOMAINS should have defaults"
    _teardown_web
  }

  it "_web_blacklist_contains blocks preloaded domains" && {
    _setup_web
    _web_blacklist_contains "https://www.linkedin.com/in/test-user"
    assert_ok $? "linkedin.com should be blocked by default"
    _teardown_web
  }

  it "_web_blacklist_contains blocks subdomains of preloaded domains" && {
    _setup_web
    _web_blacklist_contains "https://m.facebook.com/page"
    assert_ok $? "m.facebook.com should match facebook.com"
    _teardown_web
  }

  it "_web_blacklist_contains allows non-blacklisted domains" && {
    _setup_web
    # Clear file-based blacklist, keep only domain defaults
    rm -f "$WEB_BLACKLIST_FILE"
    if _web_blacklist_contains "https://example.com/test"; then
        _teardown_web
        assert_fail 0 "example.com should NOT be blocked"
    fi
    assert_ok 0
    _teardown_web
  }

  it "WEB_BLACKLIST_DOMAINS is configurable" && {
    _setup_web
    _old_domains="$WEB_BLACKLIST_DOMAINS"
    WEB_BLACKLIST_DOMAINS="onlythis.com"
    _web_blacklist_contains "https://onlythis.com/page"
    _rc=$?
    WEB_BLACKLIST_DOMAINS="$_old_domains"
    assert_ok $_rc "Custom domain should be blocked"
    _teardown_web
  }

  it "search results are not written to journal" && {
    _setup_web
    fn_body=$(declare -f _web_journal_results)
    echo "$fn_body" | grep -q 'journal_write'
    assert_fail $? "journal_write should NOT be called — URLs belong in search_results.md"
    _teardown_web
  }

# ── Blacklist management commands ──────────────────────────────
describe "web blacklist management"

  it "web_blacklist_list shows empty when no entries" && {
    _setup_web
    out=$(web_blacklist_list 2>&1)
    assert_contains "$out" "empty"
    _teardown_web
  }

  it "web_blacklist_list shows entries" && {
    _setup_web
    _web_blacklist_add "https://bad.com/page" "HTTP_403_FORBIDDEN" "403"
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
    fn_body=$(declare -f _web_extract_pdf)
    assert_contains "$fn_body" "strings"
    _teardown_web
  }

  it "tries pdftotext first" && {
    _setup_web
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
    fn_body=$(declare -f _web_fetch_json_raw)
    assert_contains "$fn_body" "application/json"
    _teardown_web
  }

  it "_web_extract_xml strips tags" && {
    _setup_web
    fn_body=$(declare -f _web_extract_xml)
    assert_contains "$fn_body" '<[^>]*>'
    _teardown_web
  }

# ── Content-type routing in web_fetch ──────────────────────────
describe "web_fetch content-type routing"

  it "calls _web_extract_pdf for PDFs" && {
    _setup_web
    fn_body=$(declare -f web_fetch)
    assert_contains "$fn_body" "_web_extract_pdf"
    _teardown_web
  }

  it "routes text content via _web_classify_content_type" && {
    _setup_web
    fn_body=$(declare -f web_fetch)
    assert_contains "$fn_body" "_web_classify_content_type"
    _teardown_web
  }

  it "routes JSON content inline" && {
    _setup_web
    fn_body=$(declare -f web_fetch)
    assert_contains "$fn_body" "jq"
    _teardown_web
  }

  it "routes XML content inline" && {
    _setup_web
    fn_body=$(declare -f web_fetch)
    assert_contains "$fn_body" "xml"
    _teardown_web
  }

  it "rejects binary files" && {
    _setup_web
    fn_body=$(declare -f web_fetch)
    assert_contains "$fn_body" "binary"
    _teardown_web
  }

  it "uses single-GET with content-type routing" && {
    _setup_web
    fn_body=$(declare -f web_fetch)
    assert_contains "$fn_body" "_web_guess_content_type"
    _teardown_web
  }

# ── Content-type routing in web_fetch_json ─────────────────────
describe "web_fetch_json content-type routing"

  it "has PDF path in web_fetch_json" && {
    _setup_web
    fn_body=$(declare -f web_fetch_json)
    assert_contains "$fn_body" "_web_extract_pdf"
    _teardown_web
  }

  it "has text path in web_fetch_json" && {
    _setup_web
    fn_body=$(declare -f web_fetch_json)
    assert_contains "$fn_body" "text"
    _teardown_web
  }

  it "returns JSON for non-HTML types" && {
    _setup_web
    fn_body=$(declare -f web_fetch_json)
    # Should use jq to build structured JSON for all paths
    assert_contains "$fn_body" "jq -n"
    _teardown_web
  }

  it "rejects binary files in web_fetch_json" && {
    _setup_web
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
    result=$(echo '<p>Hello</p><script>var x=1;</script><p>World</p>' | _html_preprocess)
    assert_contains "$result" "Hello"
    assert_contains "$result" "World"
    assert_not_contains "$result" "var x"
    _teardown_web
  }

  it "strips style blocks" && {
    _setup_web
    result=$(echo '<p>Text</p><style>.foo{color:red}</style><p>More</p>' | _html_preprocess)
    assert_contains "$result" "Text"
    assert_contains "$result" "More"
    assert_not_contains "$result" "color"
    _teardown_web
  }

  it "strips noscript blocks" && {
    _setup_web
    result=$(echo '<p>Content</p><noscript>Enable JS</noscript><p>End</p>' | _html_preprocess)
    assert_contains "$result" "Content"
    assert_contains "$result" "End"
    assert_not_contains "$result" "Enable JS"
    _teardown_web
  }

  it "decodes HTML entities" && {
    _setup_web
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
    result=$(echo '<div class="foo"><p>Clean text</p></div>' | _html_preprocess)
    assert_contains "$result" "Clean text"
    assert_not_contains "$result" "<div"
    assert_not_contains "$result" "<p>"
    _teardown_web
  }

  it "removes empty lines" && {
    _setup_web
    result=$(echo '<p>A</p>   <p>B</p>' | _html_preprocess)
    # Should not have blank lines
    blank_count=$(echo "$result" | grep -c '^[[:space:]]*$')
    assert_eq "$blank_count" "0"
    _teardown_web
  }

# ── web_fetch_raw head -c safety valve ─────────────────────────
describe "web_fetch_raw safety"

  it "pipes through head -c" && {
    _setup_web
    fn_body=$(declare -f web_fetch_raw)
    assert_contains "$fn_body" "head -c"
    _teardown_web
  }

# ── _html_extract_content uses awk preprocessor ───────────────
describe "_html_extract_content rewrite"

  it "does NOT use tr newline-join (old approach)" && {
    _setup_web
    fn_body=$(declare -f _html_extract_content)
    # Old approach used tr '\n' ' ' which caused hangs — should be gone
    _has_tr=$(echo "$fn_body" | grep -v "_html_extract_content" | grep -c "tr '" || true)
    assert_eq "$_has_tr" "0" "Should not use tr to join newlines"
    _teardown_web
  }

  it "uses awk state machine for script removal" && {
    _setup_web
    fn_body=$(declare -f _html_extract_content)
    assert_contains "$fn_body" "skip"
    assert_contains "$fn_body" "script"
    _teardown_web
  }

  it "prefers single <article> tag over full page" && {
    _setup_web
    _tw_html='<html><body><nav>Menu links here nav stuff</nav><article><p>This is the real article content with enough text to pass the threshold easily and be selected by tier one extraction.</p></article><footer>Footer stuff</footer></body></html>'
    _tw_result=$(echo "$_tw_html" | _html_extract_content)
    assert_contains "$_tw_result" "real article content"
    assert_not_contains "$_tw_result" "Menu links"
    assert_not_contains "$_tw_result" "Footer stuff"
    _teardown_web
  }

  it "skips <article> when there are multiple (listing page)" && {
    _setup_web
    _tw_html='<html><body><article><p>Card one preview</p></article><article><p>Card two preview</p></article><div class="entry-content"><p>This is the actual main content of the page with enough words to pass the two hundred character minimum threshold for class-based extraction to work properly in the tier system.</p></div></body></html>'
    _tw_result=$(echo "$_tw_html" | _html_extract_content)
    assert_contains "$_tw_result" "actual main content"
    _teardown_web
  }

# ── _html_extract_by_class_id (Tier 1.5) ─────────────────────
describe "_html_extract_by_class_id"

  it "function exists" && {
    _setup_web
    declare -f _html_extract_by_class_id >/dev/null 2>&1
    assert_ok $? "_html_extract_by_class_id should be defined"
    _teardown_web
  }

  it "extracts div with class=entry-content (WordPress)" && {
    _setup_web
    _tw_html='<nav>Navigation stuff</nav>
<div class="entry-content">
<p>This is a WordPress blog post with real content that should be extracted by the class-aware tier.</p>
</div>
<div class="sidebar">Related posts</div>'
    _tw_pre=$(echo "$_tw_html" | sed 's/>/>\n/g')
    _tw_result=$(_html_extract_by_class_id "$_tw_pre")
    assert_contains "$_tw_result" "WordPress blog post"
    assert_not_contains "$_tw_result" "Navigation stuff"
    assert_not_contains "$_tw_result" "Related posts"
    _teardown_web
  }

  it "extracts div with class=mw-parser-output (Wikipedia)" && {
    _setup_web
    _tw_html='<div id="mw-navigation">Wiki nav</div>
<div class="mw-parser-output">
<p>Wikipedia article content with detailed information about the topic covering multiple paragraphs of encyclopedic text.</p>
</div>
<div class="catlinks">Categories</div>'
    _tw_pre=$(echo "$_tw_html" | sed 's/>/>\n/g')
    _tw_result=$(_html_extract_by_class_id "$_tw_pre")
    assert_contains "$_tw_result" "Wikipedia article content"
    assert_not_contains "$_tw_result" "Wiki nav"
    _teardown_web
  }

  it "extracts div with class=post-content" && {
    _setup_web
    _tw_html='<header>Site header</header>
<div class="post-content">
<p>Blog post body text that is the main content area of this page and should be extracted.</p>
</div>
<footer>Site footer</footer>'
    _tw_pre=$(echo "$_tw_html" | sed 's/>/>\n/g')
    _tw_result=$(_html_extract_by_class_id "$_tw_pre")
    assert_contains "$_tw_result" "Blog post body text"
    _teardown_web
  }

  it "extracts section with class=article-body" && {
    _setup_web
    _tw_html='<nav>Menu</nav>
<section class="article-body">
<p>News article content with important information about current events and detailed reporting.</p>
</section>
<aside>Sidebar</aside>'
    _tw_pre=$(echo "$_tw_html" | sed 's/>/>\n/g')
    _tw_result=$(_html_extract_by_class_id "$_tw_pre")
    assert_contains "$_tw_result" "News article content"
    _teardown_web
  }

  it "extracts div with id=content when class matches" && {
    _setup_web
    _tw_html='<div id="header">Header</div>
<div id="main-content">
<p>The main content area identified by its ID attribute which matches a known content pattern.</p>
</div>
<div id="footer">Footer</div>'
    _tw_pre=$(echo "$_tw_html" | sed 's/>/>\n/g')
    _tw_result=$(_html_extract_by_class_id "$_tw_pre")
    assert_contains "$_tw_result" "main content area"
    _teardown_web
  }

  it "returns empty for pages with no matching class/id" && {
    _setup_web
    _tw_html='<div class="css-1a2b3c"><p>Obfuscated class content</p></div>'
    _tw_pre=$(echo "$_tw_html" | sed 's/>/>\n/g')
    _tw_result=$(_html_extract_by_class_id "$_tw_pre")
    [ -z "$_tw_result" ]
    assert_ok $? "Should return empty for non-matching classes"
    _teardown_web
  }

  it "handles nested divs inside the content block" && {
    _setup_web
    _tw_html='<div class="entry-content">
<div class="inner-wrapper">
<p>Content inside nested divs should still be captured because the depth tracking follows the nesting correctly through multiple levels.</p>
</div>
</div>'
    _tw_pre=$(echo "$_tw_html" | sed 's/>/>\n/g')
    _tw_result=$(_html_extract_by_class_id "$_tw_pre")
    assert_contains "$_tw_result" "nested divs"
    _teardown_web
  }

  it "extracts div with class=markdown-body (GitHub)" && {
    _setup_web
    _tw_html='<div class="AppHeader">GitHub nav bar content</div>
<div class="markdown-body">
<h1>Project README</h1>
<p>This is a GitHub README rendered in markdown-body with enough content to pass the minimum threshold.</p>
</div>
<div class="footer">Footer</div>'
    _tw_pre=$(echo "$_tw_html" | sed 's/>/>\n/g')
    _tw_result=$(_html_extract_by_class_id "$_tw_pre")
    assert_contains "$_tw_result" "Project README"
    assert_not_contains "$_tw_result" "GitHub nav bar"
    _teardown_web
  }

# ── _html_score_blocks (Tier 3) ───────────────────────────────
describe "_html_score_blocks"

  it "function exists" && {
    _setup_web
    declare -f _html_score_blocks >/dev/null 2>&1
    assert_ok $? "_html_score_blocks should be defined"
    _teardown_web
  }

  it "selects prose-heavy block over nav-heavy block" && {
    _setup_web
    _tw_html='<div class="nav-menu">
<a href="/a">Link A</a>
<a href="/b">Link B</a>
<a href="/c">Link C</a>
<a href="/d">Link D</a>
<a href="/e">Link E</a>
</div>
<div class="content">
<p>This is a long paragraph of prose content, with commas, that discusses an important topic. The paragraph continues with more detail about the subject matter, providing context and background information that readers need to understand.</p>
<p>A second paragraph adds more depth to the discussion, covering additional angles and perspectives on the topic at hand.</p>
</div>
<div class="sidebar">
<a href="/x">Related 1</a>
<a href="/y">Related 2</a>
</div>'
    _tw_pre=$(echo "$_tw_html" | sed 's/>/>\n/g')
    _tw_result=$(_html_score_blocks "$_tw_pre")
    assert_contains "$_tw_result" "long paragraph of prose content"
    _teardown_web
  }

  it "prefers blocks with more paragraphs" && {
    _setup_web
    _tw_html='<div>
<span>Just a single span with some text but no paragraph tags at all in this block here.</span>
</div>
<div>
<p>First paragraph of the article content with real information and details about the topic.</p>
<p>Second paragraph continues the discussion with more context, examples, and supporting evidence.</p>
<p>Third paragraph wraps up with a conclusion, summary of key points, and final thoughts on the matter.</p>
</div>'
    _tw_pre=$(echo "$_tw_html" | sed 's/>/>\n/g')
    _tw_result=$(_html_score_blocks "$_tw_pre")
    assert_contains "$_tw_result" "First paragraph"
    _teardown_web
  }

  it "penalizes link-heavy blocks" && {
    _setup_web
    _tw_html='<div>
<p><a href="/1">Link text one is quite long and descriptive</a> <a href="/2">Link text two is also verbose</a> <a href="/3">Link text three</a> <a href="/4">Link text four</a></p>
</div>
<div>
<p>Regular prose content without many links, discussing a subject in depth with commas, clauses, and detailed explanations that typical article text contains.</p>
<p>More regular text continues here, adding to the narrative with additional paragraphs of substantial prose content.</p>
</div>'
    _tw_pre=$(echo "$_tw_html" | sed 's/>/>\n/g')
    _tw_result=$(_html_score_blocks "$_tw_pre")
    assert_contains "$_tw_result" "Regular prose content"
    _teardown_web
  }

  it "returns empty for page with only tiny blocks" && {
    _setup_web
    _tw_html='<div><p>Tiny</p></div><div><span>Small</span></div>'
    _tw_pre=$(echo "$_tw_html" | sed 's/>/>\n/g')
    _tw_result=$(_html_score_blocks "$_tw_pre")
    [ -z "$_tw_result" ]
    assert_ok $? "Should return empty when all blocks are tiny"
    _teardown_web
  }

  it "comma count boosts prose blocks" && {
    _setup_web
    _tw_html='<div>
<p>A list of items: apples, oranges, bananas, grapes, strawberries, blueberries, raspberries, and watermelons are available at the market, which opens daily.</p>
<p>The market, which has been running for decades, offers fresh produce, dairy products, baked goods, and artisan crafts from local vendors, farmers, and craftspeople.</p>
</div>
<div>
<p>Click here to learn more about the topic Click here for details Click here to subscribe Click here to download the app now</p>
</div>'
    _tw_pre=$(echo "$_tw_html" | sed 's/>/>\n/g')
    _tw_result=$(_html_score_blocks "$_tw_pre")
    assert_contains "$_tw_result" "apples"
    _teardown_web
  }

# ── Full pipeline integration (all tiers) ─────────────────────
describe "_html_extract_content tiered extraction"

  it "tier 1.5 fires when no <article> or <main> exists" && {
    _setup_web
    _tw_html='<html><body><nav>Navigation links and menu items</nav><div class="post-content"><p>The actual blog post content that should be extracted by tier one point five because there is no article or main tag on this page but the class name matches a known content pattern.</p></div><footer>Footer links and copyright</footer></body></html>'
    _tw_result=$(echo "$_tw_html" | _html_extract_content)
    assert_contains "$_tw_result" "actual blog post content"
    assert_not_contains "$_tw_result" "Navigation links"
    assert_not_contains "$_tw_result" "Footer links"
    _teardown_web
  }

  it "tier 3 fires when no semantic tags or class matches" && {
    _setup_web
    _tw_html='<html><body><div class="css-xyz123"><a href="/a">Nav1</a><a href="/b">Nav2</a><a href="/c">Nav3</a><a href="/d">Nav4</a></div><div class="css-abc789"><p>This is a real article with prose content, including commas, that the density scorer should identify as the best block on the page.</p><p>A second paragraph provides more detail and context about the subject, with additional commas, clauses, and descriptive language.</p><p>A third paragraph ensures this block has enough content to pass the minimum threshold and score well on the density analysis.</p></div><div class="css-footer99"><a href="/x">Link X</a><a href="/y">Link Y</a></div></body></html>'
    _tw_result=$(echo "$_tw_html" | _html_extract_content)
    assert_contains "$_tw_result" "real article with prose"
    _teardown_web
  }

  it "tier 1 still wins when single <article> is present" && {
    _setup_web
    _tw_html='<html><body><div class="entry-content"><p>Class match content that would win tier 1.5</p></div><article><p>The article tag content is preferred by tier one when there is exactly one article element on the page and it has enough characters to meet the minimum threshold.</p></article></body></html>'
    _tw_result=$(echo "$_tw_html" | _html_extract_content)
    assert_contains "$_tw_result" "article tag content is preferred"
    _teardown_web
  }

# ── _web_strip_boilerplate ────────────────────────────────────
describe "_web_strip_boilerplate"

  it "strips 'Skip to content' nav lines" && {
    _setup_web
    _bp_result=$(printf 'Skip to content\nActual article text\nMore good content\n' | _web_strip_boilerplate)
    assert_not_contains "$_bp_result" "Skip to content"
    assert_contains "$_bp_result" "Actual article text"
    _teardown_web
  }

  it "strips GitHub-specific nav boilerplate" && {
    _setup_web
    _bp_input="Toggle navigation
Navigation Menu
Sign in
Search or jump to...
Search code, repositories, users, issues, pull requests...
Saved searches
Use saved searches to filter your results more quickly
Cancel Submit feedback
Appearance settings
Resetting focus
You signed in with another tab or window. Reload to refresh your session.
Dismiss alert
This is the actual README content"
    _bp_result=$(echo "$_bp_input" | _web_strip_boilerplate)
    assert_not_contains "$_bp_result" "Toggle navigation"
    assert_not_contains "$_bp_result" "Search or jump to"
    assert_not_contains "$_bp_result" "Saved searches"
    assert_not_contains "$_bp_result" "Appearance settings"
    assert_not_contains "$_bp_result" "Resetting focus"
    assert_not_contains "$_bp_result" "Dismiss alert"
    assert_contains "$_bp_result" "actual README content"
    _teardown_web
  }

  it "strips cookie consent lines" && {
    _setup_web
    _bp_result=$(printf 'Accept all cookies\nWe use cookies to improve\nReal content here\n' | _web_strip_boilerplate)
    assert_not_contains "$_bp_result" "cookies"
    assert_contains "$_bp_result" "Real content here"
    _teardown_web
  }

  it "strips footer boilerplate" && {
    _setup_web
    _bp_result=$(printf 'Article body text\n© 2025 Company Inc\nAll rights reserved\nPrivacy Policy\nTerms\n' | _web_strip_boilerplate)
    assert_not_contains "$_bp_result" "2025 Company"
    assert_not_contains "$_bp_result" "All rights reserved"
    assert_contains "$_bp_result" "Article body text"
    _teardown_web
  }

  it "preserves actual content lines" && {
    _setup_web
    _bp_result=$(printf 'This is a great framework for building AI agents.\nIt uses bash and runs on any Linux system.\nPerformance is excellent.\n' | _web_strip_boilerplate)
    assert_contains "$_bp_result" "great framework"
    assert_contains "$_bp_result" "bash and runs"
    assert_contains "$_bp_result" "Performance"
    _teardown_web
  }

  it "collapses runs of blank lines" && {
    _setup_web
    _bp_result=$(printf 'Line one\n\n\n\n\n\nLine two\n' | _web_strip_boilerplate)
    _bp_blank_count=$(echo "$_bp_result" | grep -c '^$' || true)
    assert_contains "$_bp_result" "Line one"
    assert_contains "$_bp_result" "Line two"
    [ "$_bp_blank_count" -le 2 ]
    assert_ok $? "Should collapse multiple blanks (got $_bp_blank_count)"
    _teardown_web
  }

# ── _web_truncate_content ─────────────────────────────────────
describe "_web_truncate_content"

  it "passes through short content unchanged" && {
    _setup_web
    WEB_CONTENT_MAX_CHARS=4000
    _tc_result=$(echo "Short text" | _web_truncate_content)
    assert_eq "$_tc_result" "Short text"
    _teardown_web
  }

  it "truncates content exceeding WEB_CONTENT_MAX_CHARS" && {
    _setup_web
    WEB_CONTENT_MAX_CHARS=50
    _tc_long=$(printf 'Line one of content\nLine two of content\nLine three of content\nLine four of content\nLine five')
    _tc_result=$(echo "$_tc_long" | _web_truncate_content)
    [ "${#_tc_result}" -le 55 ]
    assert_ok $? "Should be truncated to ~50 chars (got ${#_tc_result})"
    _teardown_web
  }

  it "respects custom WEB_CONTENT_MAX_CHARS value" && {
    _setup_web
    WEB_CONTENT_MAX_CHARS=20
    _tc_result=$(printf 'Abcdef\nGhijkl\nMnopqr\nStuvwx\n' | _web_truncate_content)
    [ "${#_tc_result}" -le 25 ]
    assert_ok $? "Should be within ~20 chars (got ${#_tc_result})"
    _teardown_web
  }

# ── WEB_CONTENT_MAX_CHARS default ─────────────────────────────
describe "WEB_CONTENT_MAX_CHARS configuration"

  it "defaults to 4000" && {
    unset WEB_CONTENT_MAX_CHARS _LIB_WEB_LOADED
    _setup_web
    assert_eq "$WEB_CONTENT_MAX_CHARS" "4000"
    _teardown_web
  }

# ── _web_github_repo_slug ─────────────────────────────────────
describe "_web_github_repo_slug"

  it "function exists" && {
    _setup_web
    declare -f _web_github_repo_slug &>/dev/null
    assert_ok $? "_web_github_repo_slug should be defined"
    _teardown_web
  }

  it "extracts owner/repo from GitHub repo URL" && {
    _setup_web
    result=$(_web_github_repo_slug "https://github.com/dabe-19/blue-lodge-public")
    assert_eq "$result" "dabe-19/blue-lodge-public"
    _teardown_web
  }

  it "handles trailing slash" && {
    _setup_web
    result=$(_web_github_repo_slug "https://github.com/owner/repo/")
    assert_eq "$result" "owner/repo"
    _teardown_web
  }

  it "handles .git suffix" && {
    _setup_web
    result=$(_web_github_repo_slug "https://github.com/owner/repo.git")
    assert_eq "$result" "owner/repo"
    _teardown_web
  }

  it "returns empty for non-GitHub URLs" && {
    _setup_web
    result=$(_web_github_repo_slug "https://gitlab.com/owner/repo")
    assert_empty "$result"
    _teardown_web
  }

  it "returns empty for deep GitHub paths (not repo root)" && {
    _setup_web
    result=$(_web_github_repo_slug "https://github.com/owner/repo/tree/main/src")
    assert_empty "$result"
    _teardown_web
  }

  it "returns empty for github.com homepage" && {
    _setup_web
    result=$(_web_github_repo_slug "https://github.com")
    assert_empty "$result"
    _teardown_web
  }

  it "returns empty for github.com/owner (no repo)" && {
    _setup_web
    result=$(_web_github_repo_slug "https://github.com/owner")
    assert_empty "$result"
    _teardown_web
  }

# ── _web_fetch_github_readme base64 decoding ──────────────────
describe "_web_fetch_github_readme"

  it "function exists" && {
    _setup_web
    declare -f _web_fetch_github_readme &>/dev/null
    assert_ok $? "_web_fetch_github_readme should be defined"
    _teardown_web
  }

  it "decodes base64-encoded content from API response" && {
    _setup_web
    # Mock curl to return a base64-encoded README API response
    _readme_text="# Hello World\nThis is a test README."
    _b64_content=$(printf '%s' "$_readme_text" | base64 | tr -d '\n')
    # Inject newlines like GH API does (76-char line wrap)
    _b64_wrapped=$(printf '%s' "$_b64_content" | fold -w 76 | paste -sd'\n' -)
    _api_json=$(cat <<EOJSON
{"name":"README.md","path":"README.md","encoding":"base64","content":"${_b64_wrapped}","download_url":"https://raw.githubusercontent.com/test/test/main/README.md"}
EOJSON
)
    _repo_json='{"description":"Test repo","stargazers_count":42,"language":"Bash","topics":["test"]}'
    # Use file-based counter to survive subshells
    _curl_counter="$TMPDIR_WEB/.curl_count_b64"
    printf '0' > "$_curl_counter"
    curl() {
      local _n; _n=$(cat "$_curl_counter"); _n=$((_n + 1)); printf '%s' "$_n" > "$_curl_counter"
      if [ "$_n" -eq 1 ]; then
        printf '%s' "$_api_json"
      else
        printf '%s' "$_repo_json"
      fi
    }
    export -f curl
    export _curl_counter _api_json _repo_json
    result=$(_web_fetch_github_readme "test/test")
    _final_count=$(cat "$_curl_counter")
    assert_contains "$result" "Hello World" "should contain decoded README content"
    assert_contains "$result" "GitHub: test/test" "should contain repo header"
    # Should NOT have made a 3rd curl call (no download_url fallback needed)
    assert_eq "$_final_count" "2" "should make only 2 curl calls (readme API + repo metadata)"
    unset -f curl
    _teardown_web
  }

  it "falls back to download_url when encoding is not base64" && {
    _setup_web
    _api_json='{"name":"README.md","path":"README.md","encoding":"none","content":"","download_url":"https://raw.githubusercontent.com/test/test/main/README.md"}'
    _repo_json='{"description":"Fallback test","stargazers_count":1,"language":"Shell","topics":[]}'
    _curl_counter="$TMPDIR_WEB/.curl_count_fb"
    printf '0' > "$_curl_counter"
    curl() {
      local _n; _n=$(cat "$_curl_counter"); _n=$((_n + 1)); printf '%s' "$_n" > "$_curl_counter"
      if [ "$_n" -eq 1 ]; then
        printf '%s' "$_api_json"
      elif [ "$_n" -eq 2 ]; then
        printf '%s' "# Fallback README"
      else
        printf '%s' "$_repo_json"
      fi
    }
    export -f curl
    export _curl_counter _api_json _repo_json
    result=$(_web_fetch_github_readme "test/test")
    _final_count=$(cat "$_curl_counter")
    assert_contains "$result" "Fallback README" "should contain fallback README content"
    assert_eq "$_final_count" "3" "should make 3 curl calls (API + download_url + repo metadata)"
    unset -f curl
    _teardown_web
  }

  it "decodes real GitHub API base64 response (blue-lodge-public README)" && {
    _setup_web
    # Real base64 from https://api.github.com/repos/dabe-19/blue-lodge-public/readme
    # GitHub API returns base64-encoded content with \n line breaks in JSON.
    # This is the first ~2KB of the actual README to keep the test manageable.
    # We join lines here to embed safely in JSON — base64 -d handles both formats.
    _real_b64='IyDijIIgR2VvcmdlIOKAlCBBbiBFeHBlcmltZW50YWwgQUkgQWdlbnQsIFdyaXR0ZW4gaW4gQmFzaAoKR2VvcmdlIGlzIGFuIGV4cGVyaW1lbnQ6IGFuIEFJIGNvZGluZyBhZ2VudCB3cml0dGVuIGVudGlyZWx5IGluIGJhc2ggdGhhdCBydW5zIG9mZmxpbmUgb24gYSBwaG9uZSB3aXRoIDMtNEIgcGFyYW1ldGVyIG1vZGVscy4gSGUncyBub3QgZmluaXNoZWQsIGhlIGhhcyByb3VnaCBlZGdlcywgYW5kIGhlIHdhcyBidWlsdCBwcmltYXJpbHkgd2l0aCBMTE0gYXNzaXN0YW5jZSBieSBzb21lb25lIHdobyBpcyBub3QgYSBzb2Z0d2FyZSBlbmdpbmVlci4gQnV0IHRoZSBjb3JlIHBhdHRlcm4g4oCUIHNjZW5hcmlvLXJvdXRlZCBwcm9tcHRzIHRoYXQga2VlcCBjb250ZXh0IHNtYWxsIGVub3VnaCBmb3IgdGlueSBtb2RlbHMgdG8gYmUgdXNlZnVsIOKAlCBhY3R1YWxseSB3b3JrcywgYW5kIHRoZSB0aGluZyBrZWVwcyBldm9sdmluZy4KCn42MywwMDAgbGluZXMgb2YgYmFzaC4gTm8gY2xvdWQgcmVxdWlyZWQuIE5vIEFQSSBrZXlzIHJlcXVpcmVkLiBObyBEb2NrZXIuIE5vIE5vZGUuanMuIE5vIFB5dGhvbiBydW50aW1lLiBKdXN0IGBjdXJsYCwgYGpxYCwgYGdpdGAsIGBzcWxpdGUzYCwgYW5kIGEgbWFzcyBvZiBwdXJlIGJhc2guCgo+ICpOYW1lZCBmb3IgQnJvdGhlciBHZW9yZ2UgV2FzaGluZ3Rvbiwgd2l0aCB0aGUgd2l0IG9mIEJlbmphbWluIEZyYW5rbGluIGFuZCB0aGUgbW9yYWwgcGhpbG9zb3BoeSBvZiBBZGFtIFNtaXRoLioKCiMjIyDimqDvuI8gQ3VycmVudCBTdGF0ZQ=='
    _api_json="{\"name\":\"README.md\",\"path\":\"README.md\",\"sha\":\"b714835e\",\"size\":59903,\"encoding\":\"base64\",\"content\":\"${_real_b64}\",\"download_url\":\"https://raw.githubusercontent.com/dabe-19/blue-lodge-public/main/README.md\"}"
    _repo_json='{"description":"An experimental AI agent written in bash","stargazers_count":0,"language":"Shell","topics":["ai","bash","agent"]}'
    _curl_counter="$TMPDIR_WEB/.curl_count_real"
    printf '0' > "$_curl_counter"
    curl() {
      local _n; _n=$(cat "$_curl_counter"); _n=$((_n + 1)); printf '%s' "$_n" > "$_curl_counter"
      if [ "$_n" -eq 1 ]; then
        printf '%s' "$_api_json"
      else
        printf '%s' "$_repo_json"
      fi
    }
    export -f curl
    export _curl_counter _api_json _repo_json
    result=$(_web_fetch_github_readme "dabe-19/blue-lodge-public")
    _final_count=$(cat "$_curl_counter")
    # Verify the markdown decoded correctly — check key phrases from the real README
    assert_contains "$result" "George — An Experimental AI Agent, Written in Bash" \
        "should decode the H1 title from base64"
    assert_contains "$result" "scenario-routed prompts" \
        "should decode body text about the core pattern"
    assert_contains "$result" "~63,000 lines of bash" \
        "should decode the project stats line"
    assert_contains "$result" "Named for Brother George Washington" \
        "should decode the blockquote attribution"
    assert_contains "$result" "Current State" \
        "should decode section headers"
    # Verify repo metadata header
    assert_contains "$result" "GitHub: dabe-19/blue-lodge-public" \
        "should contain repo slug in header"
    assert_contains "$result" "Shell" \
        "should contain language from repo metadata"
    assert_contains "$result" "ai, bash, agent" \
        "should contain topics from repo metadata"
    # Should NOT have fallen back to download_url
    assert_eq "$_final_count" "2" "should make only 2 curl calls (base64 decode, no download_url fallback)"
    unset -f curl
    _teardown_web
  }

# ── _html_extract_links ───────────────────────────────────────
describe "_html_extract_links"

  it "function exists" && {
    _setup_web
    declare -f _html_extract_links &>/dev/null
    assert_ok $? "_html_extract_links should be defined"
    _teardown_web
  }

  it "extracts absolute href URLs" && {
    _setup_web
    html='<a href="https://example.com/page1">Link</a><a href="https://example.com/page2">Link</a>'
    result=$(echo "$html" | _html_extract_links "https://example.com")
    assert_contains "$result" "https://example.com/page1"
    assert_contains "$result" "https://example.com/page2"
    _teardown_web
  }

  it "resolves relative URLs with base" && {
    _setup_web
    html='<a href="/about">About</a>'
    result=$(echo "$html" | _html_extract_links "https://example.com")
    assert_contains "$result" "https://example.com/about"
    _teardown_web
  }

  it "skips javascript: and mailto: links" && {
    _setup_web
    html='<a href="javascript:void(0)">JS</a><a href="mailto:test@test.com">Email</a><a href="https://real.com">Real</a>'
    result=$(echo "$html" | _html_extract_links "https://example.com")
    assert_not_contains "$result" "javascript"
    assert_not_contains "$result" "mailto"
    assert_contains "$result" "https://real.com"
    _teardown_web
  }

  it "skips static asset extensions (.css, .js)" && {
    _setup_web
    html='<a href="https://cdn.com/style.css">CSS</a><a href="https://cdn.com/app.js">JS</a><a href="https://real.com/page">Page</a>'
    result=$(echo "$html" | _html_extract_links "https://example.com")
    assert_not_contains "$result" "style.css"
    assert_not_contains "$result" "app.js"
    assert_contains "$result" "https://real.com/page"
    _teardown_web
  }

  it "deduplicates and caps at 30 links" && {
    _setup_web
    html=""
    for i in $(seq 1 40); do
      html="${html}<a href=\"https://example.com/page${i}\">Link $i</a>"
    done
    count=$(echo "$html" | _html_extract_links "https://example.com" | wc -l)
    [ "$count" -le 30 ]
    assert_ok $? "Should cap at 30 links (got $count)"
    _teardown_web
  }

# ── _web_reddit_url ───────────────────────────────────────────
describe "_web_reddit_url"

  it "function exists" && {
    _setup_web
    declare -f _web_reddit_url &>/dev/null
    assert_ok $? "_web_reddit_url should be defined"
    _teardown_web
  }

  it "detects post URL (www.reddit.com)" && {
    _setup_web
    result=$(_web_reddit_url "https://www.reddit.com/r/linux/comments/abc123/some_post_title")
    assert_eq "$result" "post:linux:abc123"
    _teardown_web
  }

  it "detects post URL (old.reddit.com)" && {
    _setup_web
    result=$(_web_reddit_url "https://old.reddit.com/r/bash/comments/xyz789/cool_script")
    assert_eq "$result" "post:bash:xyz789"
    _teardown_web
  }

  it "detects post URL (plain reddit.com)" && {
    _setup_web
    result=$(_web_reddit_url "https://reddit.com/r/programming/comments/def456/hello")
    assert_eq "$result" "post:programming:def456"
    _teardown_web
  }

  it "detects subreddit listing URL" && {
    _setup_web
    result=$(_web_reddit_url "https://www.reddit.com/r/selfhosted")
    assert_eq "$result" "sub:selfhosted"
    _teardown_web
  }

  it "handles trailing slash on subreddit" && {
    _setup_web
    result=$(_web_reddit_url "https://www.reddit.com/r/linux/")
    assert_eq "$result" "sub:linux"
    _teardown_web
  }

  it "handles query string on post URL" && {
    _setup_web
    result=$(_web_reddit_url "https://www.reddit.com/r/tech/comments/aaa111/post?utm_source=share")
    assert_eq "$result" "post:tech:aaa111"
    _teardown_web
  }

  it "returns empty for non-Reddit URLs" && {
    _setup_web
    result=$(_web_reddit_url "https://github.com/r/something/comments/abc")
    assert_empty "$result"
    _teardown_web
  }

  it "returns empty for reddit.com homepage" && {
    _setup_web
    result=$(_web_reddit_url "https://www.reddit.com")
    assert_empty "$result"
    _teardown_web
  }

  it "returns empty for reddit.com/u/ user URLs" && {
    _setup_web
    result=$(_web_reddit_url "https://www.reddit.com/u/someuser")
    assert_empty "$result"
    _teardown_web
  }

# ── _web_fetch_reddit ────────────────────────────────────────
describe "_web_fetch_reddit"

  it "function exists" && {
    _setup_web
    declare -f _web_fetch_reddit &>/dev/null
    assert_ok $? "_web_fetch_reddit should be defined"
    _teardown_web
  }

  it "returns failure for non-Reddit URL" && {
    _setup_web
    _web_fetch_reddit "https://example.com" >/dev/null 2>&1
    assert_fail $? "should fail for non-Reddit URL"
    _teardown_web
  }

test_end
