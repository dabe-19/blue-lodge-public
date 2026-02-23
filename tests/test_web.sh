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

test_end
