#!/bin/bash
# ── Tests: lib/web.sh + lib/mcp.sh integration ────────────────
# Verifies MCP-first fetch in web_fetch, fallback to curl, and
# the _mcp_dispatch_intercept routing for slash commands.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/cache.sh"
source "$LODGE_DIR/lib/mcp.sh"
source "$LODGE_DIR/lib/web.sh"

test_start "lib/web.sh + lib/mcp.sh — MCP-First Fetch Integration"

# ── Test Setup ─────────────────────────────────────────────────
_WM_TEST_DIR=""

_wm_setup() {
    _WM_TEST_DIR=$(test_tmpdir)
    MCP_CONFIG_DIR="$_WM_TEST_DIR/config"
    MCP_RUN_DIR="$_WM_TEST_DIR/run"
    MCP_SERVERS_FILE="$MCP_CONFIG_DIR/servers.conf"
    MCP_CATALOG_FILE="$MCP_CONFIG_DIR/catalog.conf"
    MCP_TIMEOUT=5
    CACHE_DIR="$_WM_TEST_DIR/cache"
    GEORGE_CACHE_DIR="$_WM_TEST_DIR/web_cache"
    WEB_CACHE_TTL="${WEB_CACHE_TTL:-300}"
    mkdir -p "$MCP_CONFIG_DIR" "$MCP_RUN_DIR" "$GEORGE_CACHE_DIR"
    cache_init
}

_wm_teardown() {
    mcp_stop_all 2>/dev/null
    rm -rf "$_WM_TEST_DIR" 2>/dev/null
}

# ── mcp_enabled gate ──────────────────────────────────────────
describe "mcp_enabled gating"

  _wm_setup

  it "returns false when MCP_ENABLED=0" && {
    MCP_ENABLED=0
    mcp_enabled
    assert_fail $? "mcp_enabled should return 1 when disabled"
  }

  it "returns true when MCP_ENABLED=1 and jq available" && {
    MCP_ENABLED=1
    mcp_enabled
    assert_ok $? "mcp_enabled should return 0 when enabled"
  }

  MCP_ENABLED=0
  _wm_teardown

# ── mcp_web_fetch with mock server registration ──────────────
describe "mcp_web_fetch routing"

  _wm_setup
  MCP_ENABLED=1

  it "returns failure when no fetch server is registered" && {
    mcp_web_fetch "https://example.com" 2>/dev/null
    assert_fail $? "should fail with no servers"
  }

  it "returns failure when fetch server exists but is unreachable" && {
    echo "fetch|/nonexistent/server|Test fetch server" > "$MCP_SERVERS_FILE"
    mcp_web_fetch "https://example.com" 2>/dev/null
    assert_fail $? "should fail when server command is invalid"
  }

  _wm_teardown

# ── web_fetch MCP-first path (mocked) ────────────────────────
describe "web_fetch MCP-first integration"

  _wm_setup
  MCP_ENABLED=1

  it "uses MCP result when mcp_web_fetch succeeds" && {
    # Mock mcp_web_fetch to return content
    test_mock mcp_web_fetch 'echo "MCP fetched content for $1"'
    test_mock mcp_enabled 'return 0'
    # Clear any cache
    rm -f "$GEORGE_CACHE_DIR"/web_* 2>/dev/null

    result=""
    result=$(web_fetch "https://example.com/test" 2>/dev/null)
    assert_contains "$result" "MCP fetched content" "should contain MCP content"
    test_unmock mcp_web_fetch
    test_unmock mcp_enabled
  }

  it "caches MCP result to web cache dir" && {
    test_mock mcp_web_fetch 'echo "cached MCP data"'
    test_mock mcp_enabled 'return 0'
    rm -f "$GEORGE_CACHE_DIR"/web_* 2>/dev/null

    web_fetch "https://cache-test.example.com" >/dev/null 2>&1
    cache_count=""
    cache_count=$(ls "$GEORGE_CACHE_DIR"/web_* 2>/dev/null | wc -l)
    assert_eq "$cache_count" "1" "should create one cache file"
    test_unmock mcp_web_fetch
    test_unmock mcp_enabled
  }

  it "falls through to curl when MCP fails" && {
    test_mock mcp_web_fetch 'return 1'
    test_mock mcp_enabled 'return 0'
    rm -f "$GEORGE_CACHE_DIR"/web_* 2>/dev/null
    # This will attempt a real curl which may fail, but it should NOT
    # return MCP content — proving fallback occurred
    result=""
    result=$(web_fetch "https://127.0.0.1:1/nope" 2>/dev/null)
    rc=$?
    # Either fails (no server) or succeeds with non-MCP content
    assert_not_contains "${result:-}" "MCP fetched" "should not have MCP content"
    test_unmock mcp_web_fetch
    test_unmock mcp_enabled
  }

  it "skips MCP when mcp_enabled returns false" && {
    test_mock mcp_enabled 'return 1'
    test_mock mcp_web_fetch 'echo "SHOULD NOT SEE THIS"'
    rm -f "$GEORGE_CACHE_DIR"/web_* 2>/dev/null
    result=""
    result=$(web_fetch "https://127.0.0.1:1/nope" 2>/dev/null)
    assert_not_contains "${result:-}" "SHOULD NOT SEE" "MCP should be skipped"
    test_unmock mcp_enabled
    test_unmock mcp_web_fetch
  }

  _wm_teardown

# ── _mcp_dispatch_intercept ──────────────────────────────────
describe "_mcp_dispatch_intercept"

  _wm_setup
  MCP_ENABLED=1

  it "returns failure when MCP is disabled" && {
    MCP_ENABLED=0
    _mcp_dispatch_intercept "search" "test query" 2>/dev/null
    assert_fail $? "should fail when disabled"
    MCP_ENABLED=1
  }

  it "returns failure when no servers are running" && {
    _mcp_dispatch_intercept "fetch" "https://example.com" 2>/dev/null
    assert_fail $? "should fail with no running servers"
  }

  it "returns failure when no matching tool found" && {
    test_mock mcp_running_servers 'echo "mock_server"'
    test_mock mcp_tools_list 'echo "[]"'
    _mcp_dispatch_intercept "nonexistent" "args" 2>/dev/null
    assert_fail $? "should fail with no matching tool"
    test_unmock mcp_running_servers
    test_unmock mcp_tools_list
  }

  _wm_teardown

# ── web_fetch cache interaction with MCP ─────────────────────
describe "web_fetch cache + MCP interaction"

  _wm_setup
  MCP_ENABLED=1

  it "serves from cache even when MCP is enabled" && {
    # Pre-populate cache
    cache_key=""
    cache_key=$(printf '%s' "https://cached.example.com" | md5sum 2>/dev/null | cut -d' ' -f1)
    echo "cached content" > "$GEORGE_CACHE_DIR/web_${cache_key}"
    # Touch to make it fresh
    touch "$GEORGE_CACHE_DIR/web_${cache_key}"

    test_mock mcp_web_fetch 'echo "SHOULD NOT CALL MCP"'
    test_mock mcp_enabled 'return 0'

    result=""
    result=$(web_fetch "https://cached.example.com" 2>/dev/null)
    assert_contains "$result" "cached content" "should serve from cache"
    assert_not_contains "$result" "SHOULD NOT CALL MCP" "should not call MCP"
    test_unmock mcp_web_fetch
    test_unmock mcp_enabled
  }

  _wm_teardown

# ── mcp_web_fetch server preference ─────────────────────────
describe "mcp_web_fetch server preference"

  _wm_setup
  MCP_ENABLED=1

  it "tries fetch server before puppeteer" && {
    # _mcp_server_exists checks the servers.conf file
    echo "fetch|/bin/true|Fetch server" > "$MCP_SERVERS_FILE"
    echo "puppeteer|/bin/true|Puppeteer server" >> "$MCP_SERVERS_FILE"

    # Mock mcp_tool_call to track which server was tried
    test_mock mcp_tool_call '[[ "$1" == "fetch" ]] && echo "from-fetch-server" && return 0; return 1'

    result=$(mcp_web_fetch "https://example.com" 2>/dev/null)
    assert_eq "$result" "from-fetch-server" "should use fetch server first"
    test_unmock mcp_tool_call
  }

  it "falls back to puppeteer when fetch fails" && {
    echo "fetch|/bin/true|Fetch server" > "$MCP_SERVERS_FILE"
    echo "puppeteer|/bin/true|Puppeteer server" >> "$MCP_SERVERS_FILE"

    test_mock mcp_tool_call '[[ "$1" == "fetch" ]] && return 1; [[ "$1" == "puppeteer" ]] && echo "from-puppeteer" && return 0; return 1'

    result=$(mcp_web_fetch "https://example.com" 2>/dev/null)
    assert_eq "$result" "from-puppeteer" "should fall back to puppeteer"
    test_unmock mcp_tool_call
  }

  _wm_teardown

test_end
