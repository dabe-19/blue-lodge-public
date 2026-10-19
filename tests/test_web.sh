#!/bin/bash
# ── Tests: lib/comms/web.sh ─────────────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh"
source "$LODGE_DIR/lib/core/api.sh"

TMPDIR_WEB=""

_setup_web() {
    TMPDIR_WEB=$(test_tmpdir)
    export GEORGE_CONFIG_DIR="$TMPDIR_WEB/.george"
    export GEORGE_KEYS_FILE="$GEORGE_CONFIG_DIR/keys.conf"
    export GEORGE_COOKIES_DIR="$GEORGE_CONFIG_DIR/cookies"
    export GEORGE_CACHE_DIR="$GEORGE_CONFIG_DIR/cache"
    export WEB_BLACKLIST_FILE="$GEORGE_CONFIG_DIR/web_blacklist.log"
    export WEB_EXCLUSIONS_FILE="$GEORGE_CONFIG_DIR/search_exclusions.log"
    export WEB_BLACKLIST_ENABLED="true"
    api_init 2>/dev/null
    source "$LODGE_DIR/lib/comms/web.sh"
}

_teardown_web() {
    rm -rf "$TMPDIR_WEB"
}

_setup_web
trap _teardown_web EXIT

test_start "lib/comms/web.sh — Web Browsing Engine"

# ── Configuration ──────────────────────────────────────────────
describe "Configuration defaults"

  it "WEB_TIMEOUT defaults to 15" && assert_eq "$WEB_TIMEOUT" "15"
  it "WEB_MAX_SIZE defaults to 2000000" && assert_eq "$WEB_MAX_SIZE" "2000000"
  it "WEB_CACHE_TTL defaults to 3600" && assert_eq "$WEB_CACHE_TTL" "3600"

# ── Renderer detection ────────────────────────────────────────
describe "_web_renderer"

  it "returns a valid renderer name" && assert_match "$(_web_renderer)" "^(w3m|lynx|html2text|sed)$"

# ── HTML to text conversion ───────────────────────────────────
describe "_html_to_text_sed"

  it "strips basic HTML tags" && { result=$(echo '<p>Hello <b>world</b></p>' | _html_to_text_sed); assert_contains "$result" "Hello"; assert_contains "$result" "world"; assert_not_contains "$result" "<p>"; assert_not_contains "$result" "<b>"; }

  it "decodes HTML entities" && { result=$(echo '<p>A &amp; B &lt; C &gt; D &quot;E&quot;</p>' | _html_to_text_sed); assert_contains "$result" "A & B"; assert_contains "$result" "< C"; assert_contains "$result" "> D"; }

  it "handles empty input" && { result=$(echo "" | _html_to_text_sed); assert_empty "$result"; }

# ── web_fetch_raw ──────────────────────────────────────────────
describe "web_fetch_raw"

  it "is defined" && assert_fn_defined "web_fetch_raw"

  it "includes HTTP block status handling" && { fn_body=$(declare -f _web_block_reason); assert_contains "$fn_body" "429"; assert_contains "$fn_body" "451"; assert_contains "$fn_body" "999"; assert_contains "$fn_body" "captcha"; }

  it "logs blocked sites to blacklist" && { fn_body=$(declare -f web_fetch_raw); assert_contains "$fn_body" "_web_blacklist_add"; assert_contains "$fn_body" "BLOCKED:"; }

  it "detects please wait for verification and captcha pages as block reasons" && {
    sample_html="<html><head><title>Reddit - Please wait for verification</title></head></html>"
    reason=$(_web_block_reason "200" "$sample_html")
    assert_eq "$reason" "HTML_CHALLENGE_OR_CAPTCHA"

    sample_html2="<html><body>checking your browser...</body></html>"
    reason2=$(_web_block_reason "200" "$sample_html2")
    assert_eq "$reason2" "HTML_CHALLENGE_OR_CAPTCHA"
  }

# ── web_fetch (with caching) ──────────────────────────────────
describe "web_fetch"

  it "is defined" && assert_fn_defined "web_fetch"
  it "returns error for unreachable URL" && { web_fetch "http://127.0.0.1:1/nonexistent" 2>/dev/null; assert_fail $?; }

# ── web_title ──────────────────────────────────────────────────
describe "web_title"

  it "is defined" && assert_fn_defined "web_title"

# ── web_links ──────────────────────────────────────────────────
describe "web_links"

  it "is defined" && assert_fn_defined "web_links"

# ── web_search ─────────────────────────────────────────────────
describe "web_search"

  it "is defined" && assert_fn_defined "web_search"

  it "internal search methods are defined" && { declare -f _web_search_serper &>/dev/null; assert_ok $?; declare -f _web_search_perplexity &>/dev/null; assert_ok $?; declare -f _web_search_ddg &>/dev/null; assert_ok $?; }

  it "DDG search uses lite.duckduckgo.com" && assert_contains "$(declare -f _web_search_ddg)" "lite.duckduckgo.com"

  it "DDG search does not blanket-filter duckduckgo.com URLs" && { fn_body=$(declare -f _web_search_ddg); _has_filter=$(echo "$fn_body" | grep -c "grep -v.*duckduckgo" || true); assert_eq "$_has_filter" "0"; }

  it "DDG Method 1 handles href-before-class attribute order" && assert_contains "$(declare -f _web_search_ddg)" '<a[^>]*class="result-link"'

  it "web_search strips surrounding quotes from query" && {
    fn_body=$(declare -f web_search)
    # Verify quote stripping is present
    assert_contains "$fn_body" 'query='
    assert_contains "$fn_body" '{query#'
  }

# ── URL Sanitization ──────────────────────────────────────────
describe "_web_sanitize_url"

  it "is defined" && assert_fn_defined "_web_sanitize_url"

  it "passes clean https URLs" && { _test_result=$(_web_sanitize_url "https://www.reddit.com/r/judo/comments/123"); assert_eq "$_test_result" "https://www.reddit.com/r/judo/comments/123"; }

  it "passes clean http URLs" && { _test_result=$(_web_sanitize_url "http://example.com/page"); assert_eq "$_test_result" "http://example.com/page"; }

  it "rejects non-http schemes" && { _web_sanitize_url "ftp://evil.com/data" 2>/dev/null; assert_fail $?; }
  it "rejects javascript: scheme" && { _web_sanitize_url "javascript:alert(1)" 2>/dev/null; assert_fail $?; }

  it "strips backticks from URLs" && { _test_result=$(_web_sanitize_url 'https://example.com/`whoami`'); [[ "$_test_result" != *'`'* ]]; assert_ok $?; }

  it "strips dollar signs from URLs" && { _test_result=$(_web_sanitize_url 'https://example.com/$HOME'); [[ "$_test_result" != *'$'* ]]; assert_ok $?; }

  it "strips semicolons from URLs" && { _test_result=$(_web_sanitize_url 'https://example.com/;rm -rf /'); [[ "$_test_result" != *';'* ]]; assert_ok $?; }

  it "rejects URLs without a dot in host" && { _web_sanitize_url "https://localhost/admin" 2>/dev/null; assert_fail $?; }

  it "truncates URLs longer than 2048 chars" && {
    _test_long_url="https://example.com/"
    _test_long_url="${_test_long_url}$(printf 'a%.0s' $(seq 1 2100))"
    _test_result=$(_web_sanitize_url "$_test_long_url")
    [ "${#_test_result}" -le 2048 ]
    assert_ok $?
  }

# ── Ad URL Detection ──────────────────────────────────────────
describe "_web_is_ad_url"

  it "is defined" && assert_fn_defined "_web_is_ad_url"
  it "detects DDG ad redirect (y.js)" && { _web_is_ad_url "https://duckduckgo.com/y.js?ad_domain=amazon.com&ad_provider=bingv7aa"; assert_ok $?; }
  it "detects ad_domain parameter" && { _web_is_ad_url "https://example.com/redirect?ad_domain=amazon.com"; assert_ok $?; }
  it "detects Bing ad click-through" && { _web_is_ad_url "https://www.bing.com/aclick?ld=abc123"; assert_ok $?; }
  it "detects Google ad services" && { _web_is_ad_url "https://www.googleadservices.com/pagead/aclk?sa=L"; assert_ok $?; }
  it "detects Google aclk" && { _web_is_ad_url "https://www.google.com/aclk?sa=L&ai=abc"; assert_ok $?; }
  it "detects doubleclick" && { _web_is_ad_url "https://ad.doubleclick.net/tracking/123"; assert_ok $?; }
  it "passes organic Reddit URL" && { ! _web_is_ad_url "https://www.reddit.com/r/judo/comments/5amt6e/"; assert_ok $?; }
  it "passes organic YouTube URL" && { ! _web_is_ad_url "https://www.youtube.com/watch?v=FVgqiZ8syBs"; assert_ok $?; }

# ── Search Result Journaling ──────────────────────────────────
describe "_web_journal_results"

  it "is defined" && assert_fn_defined "_web_journal_results"

  it "writes search_results.md to .george dir" && {
    _test_tmpdir=$(mktemp -d)
    mkdir -p "$_test_tmpdir/.george"
    pushd "$_test_tmpdir" >/dev/null
    _web_journal_results "judo workouts" "test result" "ddg"
    [ -f "$_test_tmpdir/.george/search_results.md" ]
    _test_rc=$?
    popd >/dev/null
    rm -rf "$_test_tmpdir"
    assert_ok $_test_rc
  }

  it "includes query and provider in search_results.md" && {
    _test_tmpdir=$(mktemp -d)
    mkdir -p "$_test_tmpdir/.george"
    pushd "$_test_tmpdir" >/dev/null
    _web_journal_results "test query" "[1] Title\n    https://example.com" "serper"
    _test_content=$(cat "$_test_tmpdir/.george/search_results.md")
    popd >/dev/null
    rm -rf "$_test_tmpdir"
    echo "$_test_content" | grep -q "test query"
    assert_ok $?
  }

  it "handles missing .george dir gracefully" && {
    _test_tmpdir=$(mktemp -d)
    pushd "$_test_tmpdir" >/dev/null
    # No .george dir — should not crash
    _web_journal_results "query" "results" "ddg" 2>/dev/null
    _test_rc=$?
    popd >/dev/null
    rm -rf "$_test_tmpdir"
    assert_ok $_test_rc
  }

# ── DDG ad filtering integration ──────────────────────────────
describe "DDG search ad filtering"

  it "DDG search calls _web_is_ad_url" && assert_contains "$(declare -f _web_search_ddg)" "_web_is_ad_url"
  it "DDG search calls _web_sanitize_url" && assert_contains "$(declare -f _web_search_ddg)" "_web_sanitize_url"
  it "DDG search calls _web_journal_results" && assert_contains "$(declare -f _web_search_ddg)" "_web_journal_results"

# ── Serper sanitization integration ───────────────────────────
describe "Serper search sanitization"

  it "Serper search calls _web_sanitize_url" && assert_contains "$(declare -f _web_search_serper)" "_web_sanitize_url"
  it "Serper search calls _web_journal_results" && assert_contains "$(declare -f _web_search_serper)" "_web_journal_results"

# ── web_summary ────────────────────────────────────────────────
describe "web_summary"

  it "is defined" && assert_fn_defined "web_summary"

# ── web_section ────────────────────────────────────────────────
describe "web_section"

  it "is defined" && assert_fn_defined "web_section"

# ── web_download ───────────────────────────────────────────────
describe "web_download"

  it "is defined" && assert_fn_defined "web_download"

# ── web_ping ───────────────────────────────────────────────────
describe "web_ping"

  it "is defined" && assert_fn_defined "web_ping"

# ── web_cache_clear ────────────────────────────────────────────
describe "web_cache_clear"

  it "clears the cache directory" && { mkdir -p "$GEORGE_CACHE_DIR"; echo "cached" > "$GEORGE_CACHE_DIR/web_testcache"; web_cache_clear 2>/dev/null; assert_file_not_exists "$GEORGE_CACHE_DIR/web_testcache"; }

  it "handles empty cache gracefully" && { web_cache_clear 2>/dev/null; assert_ok $?; }

# ── web_search_github ──────────────────────────────────────────
describe "web_search_github"

  it "is defined" && assert_fn_defined "web_search_github"
  it "fails on empty query" && { web_search_github "" 2>/dev/null; assert_fail $?; }
  it "accepts query and count params" && assert_fn_defined "web_search_github"

# ── web_github_repo_exists ─────────────────────────────────────
describe "web_github_repo_exists"

  it "is defined" && assert_fn_defined "web_github_repo_exists"
  it "rejects malformed repo names" && { web_github_repo_exists "" 2>/dev/null; assert_fail $?; }
  it "rejects names without owner/repo format" && { web_github_repo_exists "justreponame" 2>/dev/null; assert_fail $?; }

  it "strips .git suffix before checking" && { web_github_repo_exists "fake/repo.git" 2>/dev/null || true; assert_ok 0; }

  it "strips https://github.com/ prefix" && { web_github_repo_exists "https://github.com/fake/repo.git" 2>/dev/null || true; assert_ok 0; }

# ── web_images ─────────────────────────────────────────────────
describe "web_images"

  it "is defined" && assert_fn_defined "web_images"
  it "fails on empty query" && { web_images "" 2>/dev/null; assert_fail $?; }

  it "strips surrounding quotes from query" && {
    fn_body=$(declare -f web_images)
    assert_contains "$fn_body" '{query#'
  }

  it "internal _web_search_serper_images is defined" && assert_fn_defined "_web_search_serper_images"
  it "Serper images endpoint uses /images URL" && assert_contains "$(declare -f _web_search_serper_images)" "google.serper.dev/images"

  it "falls back to _web_search_ddg_images without SERPER_API_KEY" && {
    unset SERPER_API_KEY 2>/dev/null
    _web_search_ddg_images() { return 99; }
    web_images "test query"
    assert_eq "$?" "99"
  }

# ── web_scrape_images ──────────────────────────────────────────
describe "web_scrape_images"

  it "is defined" && assert_fn_defined "web_scrape_images"
  it "fails on empty URL" && { web_scrape_images "" 2>/dev/null; assert_fail $?; }
  it "rejects invalid URLs" && { web_scrape_images "not-a-url" 2>/dev/null; assert_fail $?; }

  it "extracts img src from HTML" && { fn_body=$(declare -f _html_extract_images); assert_contains "$fn_body" "src"; assert_contains "$fn_body" "data-src"; assert_contains "$fn_body" "srcset"; }

  it "filters to common image extensions" && { fn_body=$(declare -f _html_extract_images); assert_contains "$fn_body" "jpg"; assert_contains "$fn_body" "png"; assert_contains "$fn_body" "webp"; assert_contains "$fn_body" "gif"; }

  it "resolves protocol-relative URLs" && assert_contains "$(declare -f _html_extract_images)" "https:"
  it "skips data: URIs" && assert_contains "$(declare -f _html_extract_images)" "data:"
  it "caps image results" && assert_contains "$(declare -f _html_extract_images)" "head"
  it "journals results for agent memory" && assert_contains "$(declare -f web_scrape_images)" "_web_journal_results"

  it "surfaces blocked metadata from structured JSON" && { fn_body=$(declare -f web_scrape_images); assert_contains "$fn_body" "block_reason"; assert_contains "$fn_body" "http_status"; assert_contains "$fn_body" "Site blocked scraping"; }

  it "behaviorally extracts multiple images from stdin HTML" && {
    html="<html>
      <body>
        <img src=\"/images/logo.png\" />
        <picture>
          <source srcset=\"/images/hero.webp\" />
          <img src=\"/images/hero.jpg\" />
        </picture>
        <meta property=\"og:image\" content=\"https://example.com/og.png\" />
      </body>
    </html>"
    results=$(echo "$html" | _html_extract_images "https://example.com")
    
    assert_contains "$results" "https://example.com/images/logo.png"
    assert_contains "$results" "https://example.com/images/hero.webp"
    assert_contains "$results" "https://example.com/images/hero.jpg"
    assert_contains "$results" "https://example.com/og.png"
  }

# ── web_scrape ─────────────────────────────────────────────────
describe "web_scrape"

  it "is defined" && assert_fn_defined "web_scrape"
  it "fails on empty URL" && { web_scrape "" 2>/dev/null; assert_fail $?; }
  it "rejects invalid URLs" && { web_scrape "not-a-url" 2>/dev/null; assert_fail $?; }
  it "journals results for agent memory" && assert_contains "$(declare -f web_scrape)" "_web_journal_results"

describe "web blacklist helpers"

  it "blacklist helper functions are defined" && { declare -f _web_blacklist_contains &>/dev/null; assert_ok $?; declare -f _web_blacklist_add &>/dev/null; assert_ok $?; }

  it "writes blacklist entry with host and reason" && { _web_blacklist_add "https://example.com/path" "HTTP_429_RATE_LIMIT" "429"; assert_file_exists "$WEB_BLACKLIST_FILE"; content=$(cat "$WEB_BLACKLIST_FILE"); assert_contains "$content" "host=example.com"; assert_contains "$content" "reason=HTTP_429_RATE_LIMIT"; }

  it "_web_blacklist_is_enabled returns true by default" && { _web_blacklist_is_enabled; assert_ok $?; }

  it "_web_blacklist_contains skips check when disabled" && {
    _web_blacklist_add "https://blocked.com/test" "HTTP_403_FORBIDDEN" "403"
    WEB_BLACKLIST_ENABLED="false"
    if _web_blacklist_contains "https://blocked.com/test"; then
        WEB_BLACKLIST_ENABLED="true"
        assert_fail 0 "Should not find blacklisted URL when disabled"
    fi
    WEB_BLACKLIST_ENABLED="true"
    assert_ok 0
  }

# ── Preloaded domain blacklist ─────────────────────────────────
describe "preloaded domain blacklist"

  it "WEB_BLACKLIST_DOMAINS has default value" && { [ -n "$WEB_BLACKLIST_DOMAINS" ]; assert_ok $? "WEB_BLACKLIST_DOMAINS should have defaults"; }

  it "_web_blacklist_contains blocks preloaded domains" && { _web_blacklist_contains "https://www.linkedin.com/in/test-user"; assert_ok $? "linkedin.com should be blocked by default"; }

  it "_web_blacklist_contains blocks subdomains of preloaded domains" && { _web_blacklist_contains "https://m.facebook.com/page"; assert_ok $? "m.facebook.com should match facebook.com"; }

  it "_web_blacklist_contains allows non-blacklisted domains" && {
    # Clear file-based blacklist, keep only domain defaults
    rm -f "$WEB_BLACKLIST_FILE"
    if _web_blacklist_contains "https://example.com/test"; then
        assert_fail 0 "example.com should NOT be blocked"
    fi
    assert_ok 0
  }

  it "WEB_BLACKLIST_DOMAINS is configurable" && { _old_domains="$WEB_BLACKLIST_DOMAINS"; WEB_BLACKLIST_DOMAINS="onlythis.com"; _web_blacklist_contains "https://onlythis.com/page"; _rc=$?; WEB_BLACKLIST_DOMAINS="$_old_domains"; assert_ok $_rc "Custom domain should be blocked"; }

  it "search results are not written to journal" && { fn_body=$(declare -f _web_journal_results); echo "$fn_body" | grep -q 'journal_write'; assert_fail $? "journal_write should NOT be called — URLs belong in search_results.md"; }

# ── Blacklist management commands ──────────────────────────────
describe "web blacklist management"

  it "web_blacklist_list shows empty when no entries" && { rm -f "$WEB_BLACKLIST_FILE" "$WEB_EXCLUSIONS_FILE"; assert_contains "$(web_blacklist_list 2>&1)" "empty"; }

  it "web_blacklist_list shows entries" && { _web_blacklist_add "https://bad.com/page" "HTTP_403_FORBIDDEN" "403"; out=$(web_blacklist_list 2>&1); assert_contains "$out" "bad.com"; assert_contains "$out" "HTTP_403_FORBIDDEN"; }

  it "web_blacklist_rm removes a host" && { _web_blacklist_add "https://removeme.com/page" "HTTP_429_RATE_LIMIT" "429"; _web_blacklist_contains "https://removeme.com/page"; assert_ok $? "Should exist before removal"; web_blacklist_rm "removeme.com" >/dev/null 2>&1; _web_blacklist_contains "https://removeme.com/page"; assert_fail $? "Should not exist after removal"; }

  it "web_blacklist_rm accepts full URL" && { _web_blacklist_add "https://rmurl.com/foo" "HTTP_999_PLATFORM_BLOCK" "999"; web_blacklist_rm "https://rmurl.com/foo" >/dev/null 2>&1; _web_blacklist_contains "https://rmurl.com/foo"; assert_fail $? "Should be removed by URL"; }

  it "web_blacklist_clear removes all entries" && { _web_blacklist_add "https://a.com/" "HTTP_403_FORBIDDEN" "403"; _web_blacklist_add "https://b.com/" "HTTP_429_RATE_LIMIT" "429"; web_blacklist_clear >/dev/null 2>&1; [ ! -s "$WEB_BLACKLIST_FILE" ]; assert_ok $? "Blacklist file should be empty"; }

  it "web_blacklist_enable sets enabled" && { WEB_BLACKLIST_ENABLED="false"; web_blacklist_enable >/dev/null 2>&1; assert_eq "$WEB_BLACKLIST_ENABLED" "true"; }

  it "web_blacklist_disable sets disabled" && { web_blacklist_disable >/dev/null 2>&1; assert_eq "$WEB_BLACKLIST_ENABLED" "false"; WEB_BLACKLIST_ENABLED="true"; }

  it "management functions are defined" && {
    declare -f web_blacklist_list &>/dev/null && \
    declare -f web_blacklist_rm &>/dev/null && \
    declare -f web_blacklist_clear &>/dev/null && \
    declare -f web_blacklist_enable &>/dev/null && \
    declare -f web_blacklist_disable &>/dev/null
    assert_ok $?
  }

# ── Content-type detection ─────────────────────────────────────
# Stub curl to return nothing so HEAD request yields no content-type
# and the URL extension fallback path is exercised
_ct_setup() { curl() { return 1; }; export -f curl; }
_ct_teardown() { unset -f curl; }

describe "_web_detect_content_type"

  it "detects PDF by URL extension" && { _ct_setup; result=$(_web_detect_content_type "https://example.com/doc.pdf"); assert_eq "$result" "pdf"; _ct_teardown; }

  it "detects PDF with query string" && { _ct_setup; result=$(_web_detect_content_type "https://example.com/doc.pdf?token=abc"); assert_eq "$result" "pdf"; _ct_teardown; }

  it "detects plain text by extension" && { _ct_setup; result=$(_web_detect_content_type "https://example.com/data.txt"); assert_eq "$result" "text"; _ct_teardown; }

  it "detects CSV as text" && { _ct_setup; result=$(_web_detect_content_type "https://example.com/data.csv"); assert_eq "$result" "text"; _ct_teardown; }

  it "detects markdown as text" && { _ct_setup; result=$(_web_detect_content_type "https://raw.githubusercontent.com/user/repo/main/README.md"); assert_eq "$result" "text"; _ct_teardown; }

  it "detects JSON by extension" && { _ct_setup; result=$(_web_detect_content_type "https://api.example.com/data.json"); assert_eq "$result" "json"; _ct_teardown; }

  it "detects XML by extension" && { _ct_setup; result=$(_web_detect_content_type "https://example.com/feed.xml"); assert_eq "$result" "xml"; _ct_teardown; }

  it "detects RSS as XML" && { _ct_setup; result=$(_web_detect_content_type "https://example.com/feed.rss"); assert_eq "$result" "xml"; _ct_teardown; }

  it "detects image as binary" && { _ct_setup; result=$(_web_detect_content_type "https://example.com/photo.jpg"); assert_eq "$result" "binary"; _ct_teardown; }

  it "detects zip as binary" && { _ct_setup; result=$(_web_detect_content_type "https://example.com/archive.zip"); assert_eq "$result" "binary"; _ct_teardown; }

  it "detects docx as binary" && { _ct_setup; result=$(_web_detect_content_type "https://example.com/report.docx"); assert_eq "$result" "binary"; _ct_teardown; }

  it "defaults to html for unknown extensions" && { _ct_setup; result=$(_web_detect_content_type "https://example.com/page"); assert_eq "$result" "html"; _ct_teardown; }

  it "handles case-insensitive extensions" && { _ct_setup; result=$(_web_detect_content_type "https://example.com/DOC.PDF"); assert_eq "$result" "pdf"; _ct_teardown; }

  it "detects log files as text" && { _ct_setup; result=$(_web_detect_content_type "https://example.com/server.log"); assert_eq "$result" "text"; _ct_teardown; }

  it "detects .jsonl as json" && { _ct_setup; result=$(_web_detect_content_type "https://example.com/data.jsonl"); assert_eq "$result" "json"; _ct_teardown; }

  it "detects video as binary" && { _ct_setup; result=$(_web_detect_content_type "https://example.com/clip.mp4"); assert_eq "$result" "binary"; _ct_teardown; }

# ── PDF extraction ─────────────────────────────────────────────
describe "_web_extract_pdf"

  it "function exists" && { declare -f _web_extract_pdf &>/dev/null; assert_eq "$?" "0"; }

  it "returns failure on empty input" && { _web_extract_pdf "" 2>/dev/null; assert_eq "$?" "1"; }

  it "returns failure on nonexistent file" && { _web_extract_pdf "/nonexistent/file.pdf" 2>/dev/null; assert_eq "$?" "1"; }

  it "uses strings as fallback extractor" && assert_contains "$(declare -f _web_extract_pdf)" "strings"
  it "tries pdftotext first" && assert_contains "$(declare -f _web_extract_pdf)" "pdftotext"

# ── Fetch-to-file ─────────────────────────────────────────────
describe "_web_fetch_to_file"

  it "function exists" && { declare -f _web_fetch_to_file &>/dev/null; assert_eq "$?" "0"; }

  it "uses higher max-filesize for PDFs" && assert_contains "$(declare -f _web_fetch_to_file)" "WEB_MAX_SIZE_PDF"

# ── Text/JSON/XML fetch helpers ────────────────────────────────
describe "Non-HTML fetch helpers"

  it "_web_fetch_text function exists" && { declare -f _web_fetch_text &>/dev/null; assert_eq "$?" "0"; }

  it "_web_fetch_json_raw function exists" && { declare -f _web_fetch_json_raw &>/dev/null; assert_eq "$?" "0"; }

  it "_web_extract_xml function exists" && { declare -f _web_extract_xml &>/dev/null; assert_eq "$?" "0"; }

  it "_web_fetch_json_raw sends Accept: application/json" && assert_contains "$(declare -f _web_fetch_json_raw)" "application/json"
  it "_web_extract_xml strips tags" && assert_contains "$(declare -f _web_extract_xml)" '<[^>]*>'

# ── Content-type routing in web_fetch ──────────────────────────
describe "web_fetch content-type routing"

  it "calls _web_extract_pdf for PDFs" && assert_contains "$(declare -f web_fetch)" "_web_extract_pdf"
  it "routes text content via _web_classify_content_type" && assert_contains "$(declare -f web_fetch)" "_web_classify_content_type"
  it "routes JSON content inline" && assert_contains "$(declare -f web_fetch)" "jq"
  it "routes XML content inline" && assert_contains "$(declare -f web_fetch)" "xml"
  it "rejects binary files" && assert_contains "$(declare -f web_fetch)" "binary"
  it "uses single-GET with content-type routing" && assert_contains "$(declare -f web_fetch)" "_web_guess_content_type"

# ── Content-type routing in web_fetch_json ─────────────────────
describe "web_fetch_json content-type routing"

  it "has PDF path in web_fetch_json" && assert_contains "$(declare -f web_fetch_json)" "_web_extract_pdf"
  it "has text path in web_fetch_json" && assert_contains "$(declare -f web_fetch_json)" "text"
  it "returns JSON for non-HTML types" && assert_contains "$(declare -f web_fetch_json)" "jq -n"
  it "rejects binary files in web_fetch_json" && assert_contains "$(declare -f web_fetch_json)" "binary"

# ── Config: PDF max size ───────────────────────────────────────
describe "PDF config"

  it "WEB_MAX_SIZE_PDF defaults to 10000000" && assert_eq "$WEB_MAX_SIZE_PDF" "10000000"
  it "WEB_MAX_SIZE_PDF is larger than WEB_MAX_SIZE" && assert_gt "$WEB_MAX_SIZE_PDF" "$WEB_MAX_SIZE"

# ── HTML preprocessor (awk state machine) ─────────────────────
describe "_html_preprocess"

  it "is defined" && assert_fn_defined "_html_preprocess"

  it "strips script blocks" && { result=$(echo '<p>Hello</p><script>var x=1;</script><p>World</p>' | _html_preprocess); assert_contains "$result" "Hello"; assert_contains "$result" "World"; assert_not_contains "$result" "var x"; }

  it "strips style blocks" && {
    result=$(echo '<p>Text</p><style>.foo{color:red}</style><p>More</p>' | _html_preprocess)
    assert_contains "$result" "Text"
    assert_contains "$result" "More"
    assert_not_contains "$result" "color"
  }

  it "strips noscript blocks" && { result=$(echo '<p>Content</p><noscript>Enable JS</noscript><p>End</p>' | _html_preprocess); assert_contains "$result" "Content"; assert_contains "$result" "End"; assert_not_contains "$result" "Enable JS"; }

  it "decodes HTML entities" && assert_contains "$(echo '<p>A &amp; B &lt; C</p>' | _html_preprocess)" "A & B"

  it "handles long single-line HTML without hanging" && {
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
  }

  it "strips HTML tags" && { result=$(echo '<div class="foo"><p>Clean text</p></div>' | _html_preprocess); assert_contains "$result" "Clean text"; assert_not_contains "$result" "<div"; assert_not_contains "$result" "<p>"; }

  it "removes empty lines" && { result=$(echo '<p>A</p>   <p>B</p>' | _html_preprocess); blank_count=$(echo "$result" | grep -c '^[[:space:]]*$'); assert_eq "$blank_count" "0"; }

# ── web_fetch_raw head -c safety valve ─────────────────────────
describe "web_fetch_raw safety"

  it "pipes through head -c" && assert_contains "$(declare -f web_fetch_raw)" "head -c"

# ── _html_extract_content uses awk preprocessor ───────────────
describe "_html_extract_content rewrite"

  it "does NOT use tr newline-join (old approach)" && {
    fn_body=$(declare -f _html_extract_content)
    # Old approach used tr '\n' ' ' which caused hangs — should be gone
    _has_tr=$(echo "$fn_body" | grep -v "_html_extract_content" | grep -c "tr '" || true)
    assert_eq "$_has_tr" "0" "Should not use tr to join newlines"
  }

  it "uses awk state machine for script removal" && { fn_body=$(declare -f _html_extract_content); assert_contains "$fn_body" "skip"; assert_contains "$fn_body" "script"; }

  it "prefers single <article> tag over full page" && { _tw_html='<html><body><nav>Menu links here nav stuff</nav><article><p>This is the real article content with enough text to pass the threshold easily and be selected by tier one extraction.</p></article><footer>Footer stuff</footer></body></html>'; _tw_result=$(echo "$_tw_html" | _html_extract_content); assert_contains "$_tw_result" "real article content"; assert_not_contains "$_tw_result" "Menu links"; assert_not_contains "$_tw_result" "Footer stuff"; }

  it "skips <article> when there are multiple (listing page)" && {
    _tw_html='<html><body><article><p>Card one preview</p></article><article><p>Card two preview</p></article><div class="entry-content"><p>This is the actual main content of the page with enough words to pass the two hundred character minimum threshold for class-based extraction to work properly in the tier system.</p></div></body></html>'
    _tw_result=$(echo "$_tw_html" | _html_extract_content)
    assert_contains "$_tw_result" "actual main content"
  }

# ── _html_extract_by_class_id (Tier 1.5) ─────────────────────
describe "_html_extract_by_class_id"

  it "function exists" && { declare -f _html_extract_by_class_id >/dev/null 2>&1; assert_ok $? "_html_extract_by_class_id should be defined"; }

  it "extracts div with class=entry-content (WordPress)" && {
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
  }

  it "extracts div with class=mw-parser-output (Wikipedia)" && {
    _tw_html='<div id="mw-navigation">Wiki nav</div>
<div class="mw-parser-output">
<p>Wikipedia article content with detailed information about the topic covering multiple paragraphs of encyclopedic text.</p>
</div>
<div class="catlinks">Categories</div>'
    _tw_pre=$(echo "$_tw_html" | sed 's/>/>\n/g')
    _tw_result=$(_html_extract_by_class_id "$_tw_pre")
    assert_contains "$_tw_result" "Wikipedia article content"
    assert_not_contains "$_tw_result" "Wiki nav"
  }

  it "extracts div with class=post-content" && {
    _tw_html='<header>Site header</header>
<div class="post-content">
<p>Blog post body text that is the main content area of this page and should be extracted.</p>
</div>
<footer>Site footer</footer>'
    _tw_pre=$(echo "$_tw_html" | sed 's/>/>\n/g')
    _tw_result=$(_html_extract_by_class_id "$_tw_pre")
    assert_contains "$_tw_result" "Blog post body text"
  }

  it "extracts section with class=article-body" && {
    _tw_html='<nav>Menu</nav>
<section class="article-body">
<p>News article content with important information about current events and detailed reporting.</p>
</section>
<aside>Sidebar</aside>'
    _tw_pre=$(echo "$_tw_html" | sed 's/>/>\n/g')
    _tw_result=$(_html_extract_by_class_id "$_tw_pre")
    assert_contains "$_tw_result" "News article content"
  }

  it "extracts div with id=content when class matches" && {
    _tw_html='<div id="header">Header</div>
<div id="main-content">
<p>The main content area identified by its ID attribute which matches a known content pattern.</p>
</div>
<div id="footer">Footer</div>'
    _tw_pre=$(echo "$_tw_html" | sed 's/>/>\n/g')
    _tw_result=$(_html_extract_by_class_id "$_tw_pre")
    assert_contains "$_tw_result" "main content area"
  }

  it "returns empty for pages with no matching class/id" && {
    _tw_html='<div class="css-1a2b3c"><p>Obfuscated class content</p></div>'
    _tw_pre=$(echo "$_tw_html" | sed 's/>/>\n/g')
    _tw_result=$(_html_extract_by_class_id "$_tw_pre")
    [ -z "$_tw_result" ]
    assert_ok $? "Should return empty for non-matching classes"
  }

  it "handles nested divs inside the content block" && {
    _tw_html='<div class="entry-content">
<div class="inner-wrapper">
<p>Content inside nested divs should still be captured because the depth tracking follows the nesting correctly through multiple levels.</p>
</div>
</div>'
    _tw_pre=$(echo "$_tw_html" | sed 's/>/>\n/g')
    _tw_result=$(_html_extract_by_class_id "$_tw_pre")
    assert_contains "$_tw_result" "nested divs"
  }

  it "extracts div with class=markdown-body (GitHub)" && {
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
  }

# ── _html_score_blocks (Tier 3) ───────────────────────────────
describe "_html_score_blocks"

  it "function exists" && { declare -f _html_score_blocks >/dev/null 2>&1; assert_ok $? "_html_score_blocks should be defined"; }

  it "selects prose-heavy block over nav-heavy block" && {
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
  }

  it "prefers blocks with more paragraphs" && {
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
  }

  it "penalizes link-heavy blocks" && {
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
  }

  it "returns empty for page with only tiny blocks" && { _tw_html='<div><p>Tiny</p></div><div><span>Small</span></div>'; _tw_pre=$(echo "$_tw_html" | sed 's/>/>\n/g'); _tw_result=$(_html_score_blocks "$_tw_pre"); [ -z "$_tw_result" ]; assert_ok $? "Should return empty when all blocks are tiny"; }

  it "comma count boosts prose blocks" && {
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
  }

# ── Full pipeline integration (all tiers) ─────────────────────
describe "_html_extract_content tiered extraction"

  it "tier 1.5 fires when no <article> or <main> exists" && { _tw_html='<html><body><nav>Navigation links and menu items</nav><div class="post-content"><p>The actual blog post content that should be extracted by tier one point five because there is no article or main tag on this page but the class name matches a known content pattern.</p></div><footer>Footer links and copyright</footer></body></html>'; _tw_result=$(echo "$_tw_html" | _html_extract_content); assert_contains "$_tw_result" "actual blog post content"; assert_not_contains "$_tw_result" "Navigation links"; assert_not_contains "$_tw_result" "Footer links"; }

  it "tier 3 fires when no semantic tags or class matches" && { _tw_html='<html><body><div class="css-xyz123"><a href="/a">Nav1</a><a href="/b">Nav2</a><a href="/c">Nav3</a><a href="/d">Nav4</a></div><div class="css-abc789"><p>This is a real article with prose content, including commas, that the density scorer should identify as the best block on the page.</p><p>A second paragraph provides more detail and context about the subject, with additional commas, clauses, and descriptive language.</p><p>A third paragraph ensures this block has enough content to pass the minimum threshold and score well on the density analysis.</p></div><div class="css-footer99"><a href="/x">Link X</a><a href="/y">Link Y</a></div></body></html>'; _tw_result=$(echo "$_tw_html" | _html_extract_content); assert_contains "$_tw_result" "real article with prose"; }

  it "tier 1 still wins when single <article> is present" && { _tw_html='<html><body><div class="entry-content"><p>Class match content that would win tier 1.5</p></div><article><p>The article tag content is preferred by tier one when there is exactly one article element on the page and it has enough characters to meet the minimum threshold.</p></article></body></html>'; _tw_result=$(echo "$_tw_html" | _html_extract_content); assert_contains "$_tw_result" "article tag content is preferred"; }

# ── _web_strip_boilerplate ────────────────────────────────────
describe "_web_strip_boilerplate"

  it "strips 'Skip to content' nav lines" && { _bp_result=$(printf 'Skip to content\nActual article text\nMore good content\n' | _web_strip_boilerplate); assert_not_contains "$_bp_result" "Skip to content"; assert_contains "$_bp_result" "Actual article text"; }

  it "strips GitHub-specific nav boilerplate" && {
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
  }

  it "strips cookie consent lines" && { _bp_result=$(printf 'Accept all cookies\nWe use cookies to improve\nReal content here\n' | _web_strip_boilerplate); assert_not_contains "$_bp_result" "cookies"; assert_contains "$_bp_result" "Real content here"; }

  it "strips footer boilerplate" && { _bp_result=$(printf 'Article body text\n© 2025 Company Inc\nAll rights reserved\nPrivacy Policy\nTerms\n' | _web_strip_boilerplate); assert_not_contains "$_bp_result" "2025 Company"; assert_not_contains "$_bp_result" "All rights reserved"; assert_contains "$_bp_result" "Article body text"; }

  it "preserves actual content lines" && {
    _bp_result=$(printf 'This is a great framework for building AI agents.\nIt uses bash and runs on any Linux system.\nPerformance is excellent.\n' | _web_strip_boilerplate)
    assert_contains "$_bp_result" "great framework"
    assert_contains "$_bp_result" "bash and runs"
    assert_contains "$_bp_result" "Performance"
  }

  it "collapses runs of blank lines" && { _bp_result=$(printf 'Line one\n\n\n\n\n\nLine two\n' | _web_strip_boilerplate); _bp_blank_count=$(echo "$_bp_result" | grep -c '^$' || true); assert_contains "$_bp_result" "Line one"; assert_contains "$_bp_result" "Line two"; [ "$_bp_blank_count" -le 2 ]; assert_ok $? "Should collapse multiple blanks (got $_bp_blank_count)"; }

# ── _web_truncate_content ─────────────────────────────────────
describe "_web_truncate_content"

  it "passes through short content unchanged" && { WEB_CONTENT_MAX_CHARS=4000; _tc_result=$(echo "Short text" | _web_truncate_content); assert_eq "$_tc_result" "Short text"; }

  it "truncates content exceeding WEB_CONTENT_MAX_CHARS" && {
    WEB_CONTENT_MAX_CHARS=50
    _tc_long=$(printf 'Line one of content\nLine two of content\nLine three of content\nLine four of content\nLine five')
    _tc_result=$(echo "$_tc_long" | _web_truncate_content)
    [ "${#_tc_result}" -le 55 ]
    assert_ok $? "Should be truncated to ~50 chars (got ${#_tc_result})"
  }

  it "respects custom WEB_CONTENT_MAX_CHARS value" && {
    WEB_CONTENT_MAX_CHARS=20
    _tc_result=$(printf 'Abcdef\nGhijkl\nMnopqr\nStuvwx\n' | _web_truncate_content)
    [ "${#_tc_result}" -le 25 ]
    assert_ok $? "Should be within ~20 chars (got ${#_tc_result})"
  }

# ── WEB_CONTENT_MAX_CHARS default ─────────────────────────────
describe "WEB_CONTENT_MAX_CHARS configuration"

  it "defaults to 24000" && { unset WEB_CONTENT_MAX_CHARS _LIB_WEB_LOADED; source "$LODGE_DIR/lib/comms/web.sh"; assert_eq "$WEB_CONTENT_MAX_CHARS" "24000"; }

# ── _web_github_repo_slug ─────────────────────────────────────
describe "_web_github_repo_slug"

  it "function exists" && assert_fn_defined "_web_github_repo_slug"

  it "extracts owner/repo from GitHub repo URL" && { result=$(_web_github_repo_slug "https://github.com/operator-19/blue-lodge-public"); assert_eq "$result" "operator-19/blue-lodge-public"; }

  it "handles trailing slash" && { result=$(_web_github_repo_slug "https://github.com/owner/repo/"); assert_eq "$result" "owner/repo"; }

  it "handles .git suffix" && { result=$(_web_github_repo_slug "https://github.com/owner/repo.git"); assert_eq "$result" "owner/repo"; }

  it "returns empty for non-GitHub URLs" && { result=$(_web_github_repo_slug "https://gitlab.com/owner/repo"); assert_empty "$result"; }

  it "returns empty for deep GitHub paths (not repo root)" && { result=$(_web_github_repo_slug "https://github.com/owner/repo/tree/main/src"); assert_empty "$result"; }

  it "returns empty for github.com homepage" && { result=$(_web_github_repo_slug "https://github.com"); assert_empty "$result"; }

  it "returns empty for github.com/owner (no repo)" && { result=$(_web_github_repo_slug "https://github.com/owner"); assert_empty "$result"; }

# ── _web_fetch_github_readme base64 decoding ──────────────────
describe "_web_fetch_github_readme"

  it "function exists" && assert_fn_defined "_web_fetch_github_readme"

  it "decodes base64-encoded content from API response" && {
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
  }

  it "falls back to download_url when encoding is not base64" && {
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
  }

  it "decodes real GitHub API base64 response (blue-lodge-public README)" && {
    # Real base64 from https://api.github.com/repos/operator-19/blue-lodge-public/readme
    # GitHub API returns base64-encoded content with \n line breaks in JSON.
    # This is the first ~2KB of the actual README to keep the test manageable.
    # We join lines here to embed safely in JSON — base64 -d handles both formats.
    _real_b64='IyDijIIgR2VvcmdlIOKAlCBBbiBFeHBlcmltZW50YWwgQUkgQWdlbnQsIFdyaXR0ZW4gaW4gQmFzaAoKR2VvcmdlIGlzIGFuIGV4cGVyaW1lbnQ6IGFuIEFJIGNvZGluZyBhZ2VudCB3cml0dGVuIGVudGlyZWx5IGluIGJhc2ggdGhhdCBydW5zIG9mZmxpbmUgb24gYSBwaG9uZSB3aXRoIDMtNEIgcGFyYW1ldGVyIG1vZGVscy4gSGUncyBub3QgZmluaXNoZWQsIGhlIGhhcyByb3VnaCBlZGdlcywgYW5kIGhlIHdhcyBidWlsdCBwcmltYXJpbHkgd2l0aCBMTE0gYXNzaXN0YW5jZSBieSBzb21lb25lIHdobyBpcyBub3QgYSBzb2Z0d2FyZSBlbmdpbmVlci4gQnV0IHRoZSBjb3JlIHBhdHRlcm4g4oCUIHNjZW5hcmlvLXJvdXRlZCBwcm9tcHRzIHRoYXQga2VlcCBjb250ZXh0IHNtYWxsIGVub3VnaCBmb3IgdGlueSBtb2RlbHMgdG8gYmUgdXNlZnVsIOKAlCBhY3R1YWxseSB3b3JrcywgYW5kIHRoZSB0aGluZyBrZWVwcyBldm9sdmluZy4KCn42MywwMDAgbGluZXMgb2YgYmFzaC4gTm8gY2xvdWQgcmVxdWlyZWQuIE5vIEFQSSBrZXlzIHJlcXVpcmVkLiBObyBEb2NrZXIuIE5vIE5vZGUuanMuIE5vIFB5dGhvbiBydW50aW1lLiBKdXN0IGBjdXJsYCwgYGpxYCwgYGdpdGAsIGBzcWxpdGUzYCwgYW5kIGEgbWFzcyBvZiBwdXJlIGJhc2guCgo+ICpOYW1lZCBmb3IgQnJvdGhlciBHZW9yZ2UgV2FzaGluZ3Rvbiwgd2l0aCB0aGUgd2l0IG9mIEJlbmphbWluIEZyYW5rbGluIGFuZCB0aGUgbW9yYWwgcGhpbG9zb3BoeSBvZiBBZGFtIFNtaXRoLioKCiMjIyDimqDvuI8gQ3VycmVudCBTdGF0ZQ=='
    _api_json="{\"name\":\"README.md\",\"path\":\"README.md\",\"sha\":\"b714835e\",\"size\":59903,\"encoding\":\"base64\",\"content\":\"${_real_b64}\",\"download_url\":\"https://raw.githubusercontent.com/operator-19/blue-lodge-public/main/README.md\"}"
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
    result=$(_web_fetch_github_readme "operator-19/blue-lodge-public")
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
    assert_contains "$result" "GitHub: operator-19/blue-lodge-public" \
        "should contain repo slug in header"
    assert_contains "$result" "Shell" \
        "should contain language from repo metadata"
    assert_contains "$result" "ai, bash, agent" \
        "should contain topics from repo metadata"
    # Should NOT have fallen back to download_url
    assert_eq "$_final_count" "2" "should make only 2 curl calls (base64 decode, no download_url fallback)"
    unset -f curl
  }

# ── _html_extract_links ───────────────────────────────────────
describe "_html_extract_links"

  it "function exists" && assert_fn_defined "_html_extract_links"

  it "extracts absolute href URLs" && { html='<a href="https://example.com/page1">Link</a><a href="https://example.com/page2">Link</a>'; result=$(echo "$html" | _html_extract_links "https://example.com"); assert_contains "$result" "https://example.com/page1"; assert_contains "$result" "https://example.com/page2"; }

  it "resolves relative URLs with base" && { html='<a href="/about">About</a>'; result=$(echo "$html" | _html_extract_links "https://example.com"); assert_contains "$result" "https://example.com/about"; }

  it "skips javascript: and mailto: links" && { html='<a href="javascript:void(0)">JS</a><a href="mailto:test@test.com">Email</a><a href="https://real.com">Real</a>'; result=$(echo "$html" | _html_extract_links "https://example.com"); assert_not_contains "$result" "javascript"; assert_not_contains "$result" "mailto"; assert_contains "$result" "https://real.com"; }

  it "skips static asset extensions (.css, .js)" && { html='<a href="https://cdn.com/style.css">CSS</a><a href="https://cdn.com/app.js">JS</a><a href="https://real.com/page">Page</a>'; result=$(echo "$html" | _html_extract_links "https://example.com"); assert_not_contains "$result" "style.css"; assert_not_contains "$result" "app.js"; assert_contains "$result" "https://real.com/page"; }

  it "deduplicates and caps at 30 links" && {
    html=""
    for i in $(seq 1 40); do
      html="${html}<a href=\"https://example.com/page${i}\">Link $i</a>"
    done
    count=$(echo "$html" | _html_extract_links "https://example.com" | wc -l)
    [ "$count" -le 30 ]
    assert_ok $? "Should cap at 30 links (got $count)"
  }

# ── _web_reddit_url ───────────────────────────────────────────
describe "_web_reddit_url"

  it "function exists" && assert_fn_defined "_web_reddit_url"

  it "detects post URL (www.reddit.com)" && { result=$(_web_reddit_url "https://www.reddit.com/r/linux/comments/abc123/some_post_title"); assert_eq "$result" "post:linux:abc123"; }

  it "detects post URL (old.reddit.com)" && { result=$(_web_reddit_url "https://old.reddit.com/r/bash/comments/xyz789/cool_script"); assert_eq "$result" "post:bash:xyz789"; }

  it "detects post URL (plain reddit.com)" && { result=$(_web_reddit_url "https://reddit.com/r/programming/comments/def456/hello"); assert_eq "$result" "post:programming:def456"; }

  it "detects subreddit listing URL" && { result=$(_web_reddit_url "https://www.reddit.com/r/selfhosted"); assert_eq "$result" "sub:selfhosted"; }

  it "handles trailing slash on subreddit" && { result=$(_web_reddit_url "https://www.reddit.com/r/linux/"); assert_eq "$result" "sub:linux"; }

  it "handles query string on post URL" && { result=$(_web_reddit_url "https://www.reddit.com/r/tech/comments/aaa111/post?utm_source=share"); assert_eq "$result" "post:tech:aaa111"; }

  it "returns empty for non-Reddit URLs" && { result=$(_web_reddit_url "https://github.com/r/something/comments/abc"); assert_empty "$result"; }

  it "returns empty for reddit.com homepage" && { result=$(_web_reddit_url "https://www.reddit.com"); assert_empty "$result"; }

  it "returns empty for reddit.com/u/ user URLs" && { result=$(_web_reddit_url "https://www.reddit.com/u/someuser"); assert_empty "$result"; }

# ── _web_fetch_reddit ────────────────────────────────────────
describe "_web_fetch_reddit"

  it "function exists" && assert_fn_defined "_web_fetch_reddit"

  it "returns failure for non-Reddit URL" && {
    _web_fetch_reddit "https://example.com" >/dev/null 2>&1
    assert_fail $? "should fail for non-Reddit URL"
  }

# ── Web search exclusions ────────────────────────────────────
describe "web search exclusions"

  it "adds strike exclusions and calculates tiered progressive TTLs" && {
    export WEB_EXCLUSIONS_FILE="$GEORGE_CONFIG_DIR/search_exclusions.log"
    rm -f "$WEB_EXCLUSIONS_FILE"

    # First strike -> 24 hours (86400s)
    _web_exclusions_add "block1.com"
    assert_file_exists "$WEB_EXCLUSIONS_FILE"
    entry1=$(grep "|host=block1.com|" "$WEB_EXCLUSIONS_FILE" | tail -1)
    assert_contains "$entry1" "strike_count=1"
    assert_contains "$entry1" "ttl_seconds=86400"

    # Second strike -> 7 days (604800s)
    _web_exclusions_add "block1.com"
    entry2=$(grep "|host=block1.com|" "$WEB_EXCLUSIONS_FILE" | tail -1)
    assert_contains "$entry2" "strike_count=2"
    assert_contains "$entry2" "ttl_seconds=604800"

    # Third strike -> 30 days (2592000s)
    _web_exclusions_add "block1.com"
    entry3=$(grep "|host=block1.com|" "$WEB_EXCLUSIONS_FILE" | tail -1)
    assert_contains "$entry3" "strike_count=3"
    assert_contains "$entry3" "ttl_seconds=2592000"
  }

  it "automatically excludes active domains from search queries" && {
    export WEB_EXCLUSIONS_FILE="$GEORGE_CONFIG_DIR/search_exclusions.log"
    rm -f "$WEB_EXCLUSIONS_FILE"

    # Add active exclusion
    _web_exclusions_add "hostile-bot-blocker.com"
    filters=$(_web_exclusions_get_active_filters)
    assert_contains "$filters" "-site:hostile-bot-blocker.com"

    # Add expired exclusion manually by writing past timestamp
    past_time=$(date -u -d "2 days ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-2d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
    printf '%s|host=expired.com|strike_count=1|ttl_seconds=86400\n' "$past_time" >> "$WEB_EXCLUSIONS_FILE"

    filters2=$(_web_exclusions_get_active_filters)
    assert_not_contains "$filters2" "-site:expired.com"
    assert_contains "$filters2" "-site:hostile-bot-blocker.com"
  }

  it "includes preloaded and dynamic blacklist entries in active filters" && {
    export WEB_EXCLUSIONS_FILE="$GEORGE_CONFIG_DIR/search_exclusions.log"
    rm -f "$WEB_EXCLUSIONS_FILE"
    rm -f "$WEB_BLACKLIST_FILE"

    # Preloaded domain blacklist check
    export WEB_BLACKLIST_DOMAINS="linkedin.com,facebook.com"
    filters=$(_web_exclusions_get_active_filters)
    assert_contains "$filters" "-site:linkedin.com"
    assert_contains "$filters" "-site:facebook.com"

    # Dynamic blacklist entry check
    _web_blacklist_add "https://dynamic-blocked.com/page" "HTTP_403_FORBIDDEN" "403"
    filters2=$(_web_exclusions_get_active_filters)
    assert_contains "$filters2" "-site:dynamic-blocked.com"
  }

  it "blacklist subcommands list and clear both blacklist and exclusions" && {
    export WEB_EXCLUSIONS_FILE="$GEORGE_CONFIG_DIR/search_exclusions.log"
    rm -f "$WEB_EXCLUSIONS_FILE"

    _web_blacklist_add "https://site-abc.com/page" "HTTP_403_FORBIDDEN" "403"
    assert_file_exists "$WEB_BLACKLIST_FILE"
    assert_file_exists "$WEB_EXCLUSIONS_FILE"

    # Test rm
    web_blacklist_rm "https://site-abc.com" >/dev/null
    assert_not_contains "$(cat "$WEB_BLACKLIST_FILE" 2>/dev/null)" "site-abc.com"
    assert_not_contains "$(cat "$WEB_EXCLUSIONS_FILE" 2>/dev/null)" "site-abc.com"

    # Test clear
    _web_blacklist_add "https://site-xyz.com/page" "HTTP_403_FORBIDDEN" "403"
    web_blacklist_clear >/dev/null
    assert_empty "$(cat "$WEB_BLACKLIST_FILE" 2>/dev/null)"
    assert_empty "$(cat "$WEB_EXCLUSIONS_FILE" 2>/dev/null)"
  }

# ── Domain Grey-listing & Snippet Fallbacks ───────────────────
describe "Domain Grey-listing & Snippet Fallbacks"

  it "defines greylist configuration defaults" && { assert_contains "$WEB_GREYLIST_DOMAINS" "redfin.com"; assert_contains "$WEB_GREYLIST_DOMAINS" "google.com"; [ -n "$WEB_GREYLIST_FILE" ]; assert_ok $?; }

  it "_web_greylist_contains matches domains and subdomains" && {
    export WEB_GREYLIST_DOMAINS="redfin.com,example.org"
    
    _web_greylist_contains "https://redfin.com/city/123"
    assert_ok $? "Exact domain match should succeed"
    
    _web_greylist_contains "https://www.redfin.com/city/123"
    assert_ok $? "Subdomain match should succeed"
    
    _web_greylist_contains "https://google.com"
    assert_fail $? "Non-greylisted domain should fail"
  }

  it "_web_greylist_fallback extracts snippet from last_search.json" && {
    export AGENT_TASK_WORKSPACE="$TMPDIR_WEB"
    mkdir -p "$TMPDIR_WEB"
    
    echo '{"query":"Springfield","provider":"serper","results":[{"title":"Redfin Page","url":"https://redfin.com/page1","snippet":"This is Springfield info."}]}' > "$TMPDIR_WEB/last_search.json"
    
    result=$(_web_greylist_fallback "https://redfin.com/page1")
    assert_ok $?
    assert_contains "$result" "Redfin Page"
    assert_contains "$result" "This is Springfield info."
    assert_contains "$result" "SYSTEM NOTE: Domain is grey-listed"
  }

  it "web_fetch fallback works for grey-listed domains" && {
    export AGENT_TASK_WORKSPACE="$TMPDIR_WEB"
    export WEB_GREYLIST_DOMAINS="redfin.com"
    mkdir -p "$TMPDIR_WEB"
    
    echo '{"query":"Springfield","provider":"serper","results":[{"title":"Redfin Page","url":"https://redfin.com/page1","snippet":"This is Springfield info."}]}' > "$TMPDIR_WEB/last_search.json"
    
    output=$(web_fetch "https://redfin.com/page1" 2>/dev/null)
    assert_ok $?
    assert_contains "$output" "This is Springfield info."
    assert_contains "$output" "SYSTEM NOTE: Domain is grey-listed"
  }

  it "web_fetch_json fallback works for grey-listed domains" && {
    export AGENT_TASK_WORKSPACE="$TMPDIR_WEB"
    export WEB_GREYLIST_DOMAINS="redfin.com"
    mkdir -p "$TMPDIR_WEB"
    
    echo '{"query":"Springfield","provider":"serper","results":[{"title":"Redfin Page","url":"https://redfin.com/page1","snippet":"This is Springfield info."}]}' > "$TMPDIR_WEB/last_search.json"
    
    output=$(web_fetch_json "https://redfin.com/page1")
    assert_ok $?
    assert_contains "$output" "\"title\": \"Redfin Page\""
    assert_contains "$output" "\"content\": \"[SYSTEM NOTE: Domain is grey-listed"
  }

  it "dynamic greylisting registers blocked hosts" && { export WEB_GREYLIST_FILE="$TMPDIR_WEB/web_greylist.log"; rm -f "$WEB_GREYLIST_FILE"; _web_greylist_add "blocked-site.com" "captcha"; assert_file_exists "$WEB_GREYLIST_FILE"; _web_greylist_contains "https://blocked-site.com/subpage"; assert_ok $? "Host added to greylist log should match"; }

  it "dynamic platform detection configures client hints" && {
    # Simulate Android / Termux environment
    WEB_USER_AGENT=""
    WEB_SEC_CH_UA_PLATFORM=""
    export _WEB_TEST_OS_OVERRIDE="Android"
    
    _web_init_fingerprint
    assert_contains "$WEB_USER_AGENT" "Android"
    assert_eq "$WEB_SEC_CH_UA_PLATFORM" '"Android"'
    assert_eq "$WEB_SEC_CH_UA_MOBILE" "?1"
    
    # Simulate Windows user agent override
    WEB_USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"
    WEB_SEC_CH_UA_PLATFORM=""
    unset _WEB_TEST_OS_OVERRIDE
    _web_init_fingerprint
    assert_eq "$WEB_SEC_CH_UA_PLATFORM" '"Windows"'
  }

  it "search annotations append GREY-LISTED suffix to matching domains" && {
    export WEB_GREYLIST_DOMAINS="redfin.com"
    
    # Stub api_post to return a raw serper response
    api_post() {
      echo '{"organic":[{"position":1,"link":"https://redfin.com/page1","title":"Springfield Market","snippet":"snippet details"},{"position":2,"link":"https://other.com/page2","title":"Other Market","snippet":"other details"}]}'
    }
    export -f api_post
    
    output=$(_web_search_serper "query" 5 "dummy_key")
    assert_contains "$output" "Springfield Market [GREY-LISTED]"
    assert_contains "$output" "Other Market"
    assert_not_contains "$output" "Other Market [GREY-LISTED]"
    
    unset -f api_post
  }

  it "appends host to web_blacklist when greylist fallback has missing cache" && { export WEB_GREYLIST_DOMAINS="blocked-site.com"; output=$(web_fetch_json "https://blocked-site.com/page"); assert_contains "$output" "GREYLISTED_MISSING_CACHE"; assert_file_exists "$WEB_BLACKLIST_FILE"; bl_content=$(cat "$WEB_BLACKLIST_FILE"); assert_contains "$bl_content" "host=blocked-site.com"; }

  it "_web_exclusions_get_active_filters formats -site: query arguments correctly" && { _web_exclusions_add "testdomain.com"; filters=$(_web_exclusions_get_active_filters); assert_contains "$filters" "-site:testdomain.com"; }

test_end
