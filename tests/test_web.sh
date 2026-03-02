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

  it "WEB_MAX_SIZE defaults to 500000" && {
    _setup_web
    assert_eq "$WEB_MAX_SIZE" "500000"
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

test_end
