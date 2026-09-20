#!/bin/bash
# ── Tests: lib/mcp_server_fetch.sh ────────────────────────────
# Tests the pure-bash MCP fetch server against the MCP protocol.
# Uses the actual server process (not mocks) for protocol compliance.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/cache.sh"
source "$LODGE_DIR/lib/mcp.sh"

test_start "lib/mcp_server_fetch.sh — Pure-Bash MCP Fetch Server"

# ── Helpers ────────────────────────────────────────────────────
_SERVER_CMD="bash $LODGE_DIR/lib/mcp_server_fetch.sh"
_TEST_DIR=""

_msf_setup() {
    _TEST_DIR=$(test_tmpdir)
    MCP_CONFIG_DIR="$_TEST_DIR/config"
    MCP_RUN_DIR="$_TEST_DIR/run"
    MCP_SERVERS_FILE="$MCP_CONFIG_DIR/servers.conf"
    MCP_CATALOG_FILE="$MCP_CONFIG_DIR/catalog.conf"
    CACHE_DIR="$_TEST_DIR/cache"
    MCP_TIMEOUT=15
    mkdir -p "$MCP_CONFIG_DIR" "$MCP_RUN_DIR"
    cache_init
}

_msf_teardown() {
    mcp_stop_all 2>/dev/null
    rm -rf "$_TEST_DIR" 2>/dev/null
}

# Send a single JSON-RPC message and get response
_msf_one_shot() {
    printf '%s\n' "$1" | bash "$LODGE_DIR/lib/mcp_server_fetch.sh" 2>/dev/null | head -1
}

# Send multiple messages (init + request) and get last response
_msf_call() {
    local init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
    local notif='{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
    printf '%s\n%s\n%s\n' "$init" "$notif" "$1" | bash "$LODGE_DIR/lib/mcp_server_fetch.sh" 2>/dev/null | tail -1
}

# ── Protocol Compliance ───────────────────────────────────────
describe "MCP protocol compliance"

  it "responds to initialize with correct protocol version" && {
    resp=$(_msf_one_shot '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    proto=$(printf '%s' "$resp" | jq -r '.result.protocolVersion' 2>/dev/null)
    assert_eq "$proto" "2024-11-05"
  }

  it "includes server info in initialize response" && {
    resp=$(_msf_one_shot '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    name=$(printf '%s' "$resp" | jq -r '.result.serverInfo.name' 2>/dev/null)
    assert_eq "$name" "george-fetch"
  }

  it "advertises tools capability" && {
    resp=$(_msf_one_shot '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    has_tools=$(printf '%s' "$resp" | jq 'has("result") and (.result.capabilities | has("tools"))' 2>/dev/null)
    assert_eq "$has_tools" "true"
  }

  it "returns valid JSON-RPC 2.0 envelope" && {
    resp=$(_msf_one_shot '{"jsonrpc":"2.0","id":42,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    version=$(printf '%s' "$resp" | jq -r '.jsonrpc' 2>/dev/null)
    assert_eq "$version" "2.0"
    id_val=$(printf '%s' "$resp" | jq -r '.id' 2>/dev/null)
    assert_eq "$id_val" "42"
  }

  it "returns error for unknown method" && {
    resp=$(_msf_one_shot '{"jsonrpc":"2.0","id":1,"method":"bogus/method","params":{}}')
    err_code=$(printf '%s' "$resp" | jq -r '.error.code' 2>/dev/null)
    assert_eq "$err_code" "-32601"
  }

  it "silently handles notifications without response" && {
    resp=$(_msf_one_shot '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}')
    assert_empty "$resp" "notifications should produce no response"
  }

# ── tools/list ─────────────────────────────────────────────────
describe "tools/list"

  it "returns all 7 tools" && {
    resp=$(_msf_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    count=$(printf '%s' "$resp" | jq '.result.tools | length' 2>/dev/null)
    assert_eq "$count" "7"
  }

  it "includes fetch tool" && {
    resp=$(_msf_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    has_fetch=$(printf '%s' "$resp" | jq '[.result.tools[] | select(.name == "fetch")] | length' 2>/dev/null)
    assert_eq "$has_fetch" "1"
  }

  it "includes web_search tool" && {
    resp=$(_msf_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    has_search=$(printf '%s' "$resp" | jq '[.result.tools[] | select(.name == "web_search")] | length' 2>/dev/null)
    assert_eq "$has_search" "1"
  }

  it "includes github_search tool" && {
    resp=$(_msf_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    has_gh=$(printf '%s' "$resp" | jq '[.result.tools[] | select(.name == "github_search")] | length' 2>/dev/null)
    assert_eq "$has_gh" "1"
  }
  it "includes fetch_reddit tool" && {
    resp=$(_msf_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    has_rd=$(printf '%s' "$resp" | jq '[.result.tools[] | select(.name == "fetch_reddit")] | length' 2>/dev/null)
    assert_eq "$has_rd" "1"
  }
  it "tools have required inputSchema" && {
    resp=$(_msf_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    all_have_schema=$(printf '%s' "$resp" | jq '[.result.tools[] | select(.inputSchema != null)] | length' 2>/dev/null)
    assert_eq "$all_have_schema" "7" "all tools should have inputSchema"
  }

# ── tools/call — fetch ─────────────────────────────────────────
describe "tools/call — fetch"

  it "returns error when url is missing" && {
    resp=$(_msf_call '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"fetch","arguments":{}}}')
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Error" "should return error text"
  }

  it "returns error for unknown tool" && {
    resp=$(_msf_call '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"nonexistent","arguments":{}}}')
    err=$(printf '%s' "$resp" | jq -r '.error.message' 2>/dev/null)
    assert_contains "$err" "Unknown tool"
  }

  it "returns content in MCP text content format" && {
    resp=$(_msf_call '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"fetch","arguments":{"url":"https://example.com"}}}')
    content_type=$(printf '%s' "$resp" | jq -r '.result.content[0].type' 2>/dev/null)
    assert_eq "$content_type" "text"
  }

  it "fetches example.com successfully" && {
    resp=$(_msf_call '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"fetch","arguments":{"url":"https://example.com"}}}')
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Example Domain"
  }

  it "respects max_lines parameter" && {
    resp=$(_msf_call '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"fetch","arguments":{"url":"https://example.com","max_lines":2}}}')
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    line_count=$(printf '%s' "$text" | wc -l)
    # head -2 means at most 2 lines
    assert_gt "3" "$line_count" "should be 2 or fewer lines"
  }

# ── tools/call — web_search ────────────────────────────────────
describe "tools/call — web_search"

  it "returns error when query is missing" && {
    resp=$(_msf_call '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"web_search","arguments":{}}}')
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Error" "should require query"
  }

# ── tools/call — fetch_reddit ──────────────────────────────────
describe "tools/call — fetch_reddit"

  it "returns error when url is missing" && {
    resp=$(_msf_call '{"jsonrpc":"2.0","id":25,"method":"tools/call","params":{"name":"fetch_reddit","arguments":{}}}')
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Error" "should require url"
  }

  it "returns error for non-Reddit URL" && {
    resp=$(_msf_call '{"jsonrpc":"2.0","id":26,"method":"tools/call","params":{"name":"fetch_reddit","arguments":{"url":"https://example.com"}}}')
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Not a valid Reddit URL"
  }

# ── tools/call — github_search ─────────────────────────────────
describe "tools/call — github_search"

  it "returns error when query is missing" && {
    resp=$(_msf_call '{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"github_search","arguments":{}}}')
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Error" "should require query"
  }

# ── Integration with MCP client ────────────────────────────────
describe "integration with George MCP client"

  it "starts via mcp_start and completes handshake" && {
    _msf_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "george-fetch" "$_SERVER_CMD" "George built-in fetch"
    mcp_start "george-fetch"
    assert_ok $?
    assert_file_exists "$MCP_RUN_DIR/george-fetch/ready"
    _msf_teardown
    MCP_ENABLED=0
  }

  it "lists tools via mcp_tools_list" && {
    _msf_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "george-fetch" "$_SERVER_CMD" "George built-in fetch"
    mcp_start "george-fetch"
    tools=$(mcp_tools_list "george-fetch")
    count=$(printf '%s' "$tools" | jq 'length' 2>/dev/null)
    assert_eq "$count" "7" "should have 7 tools"
    _msf_teardown
    MCP_ENABLED=0
  }

  it "calls fetch tool via mcp_tool_call" && {
    _msf_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "george-fetch" "$_SERVER_CMD" "George built-in fetch"
    mcp_start "george-fetch"
    result=$(mcp_tool_call "george-fetch" "fetch" '{"url":"https://example.com"}')
    assert_contains "$result" "Example Domain"
    _msf_teardown
    MCP_ENABLED=0
  }

test_end
