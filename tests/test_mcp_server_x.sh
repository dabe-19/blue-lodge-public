#!/bin/bash
# ── Tests: lib/mcp_server_x.sh ────────────────────────────────
# Tests the pure-bash MCP X/Twitter server against the MCP protocol.
# Protocol compliance tests use the actual server process.
# Tool dispatch tests verify parameter validation and auth gating
# without requiring real X API credentials.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/cache.sh"
source "$LODGE_DIR/lib/mcp.sh"

test_start "lib/mcp_server_x.sh — Pure-Bash MCP X/Twitter Server"

# ── Helpers ────────────────────────────────────────────────────
_SERVER_CMD="bash $LODGE_DIR/lib/mcp_server_x.sh"
_TEST_DIR=""

_msx_setup() {
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

_msx_teardown() {
    mcp_stop_all 2>/dev/null
    rm -rf "$_TEST_DIR" 2>/dev/null
}

# Send a single JSON-RPC message and get response
_msx_one_shot() {
    printf '%s\n' "$1" | bash "$LODGE_DIR/lib/mcp_server_x.sh" 2>/dev/null | head -1
}

# Send multiple messages (init + request) and get last response
_msx_call() {
    local init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
    local notif='{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
    printf '%s\n%s\n%s\n' "$init" "$notif" "$1" | bash "$LODGE_DIR/lib/mcp_server_x.sh" 2>/dev/null | tail -1
}

# Same but with X_BEARER_TOKEN set to a dummy value
_msx_call_authed() {
    local init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
    local notif='{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
    printf '%s\n%s\n%s\n' "$init" "$notif" "$1" | X_BEARER_TOKEN="test-token-fake" bash "$LODGE_DIR/lib/mcp_server_x.sh" 2>/dev/null | tail -1
}

# ══════════════════════════════════════════════════════════════
# Protocol Compliance
# ══════════════════════════════════════════════════════════════
describe "MCP protocol compliance"

  it "responds to initialize with correct protocol version" && {
    resp=$(_msx_one_shot '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    proto=$(printf '%s' "$resp" | jq -r '.result.protocolVersion' 2>/dev/null)
    assert_eq "$proto" "2024-11-05"
  }

  it "includes server info with name george-x" && {
    resp=$(_msx_one_shot '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    name=$(printf '%s' "$resp" | jq -r '.result.serverInfo.name' 2>/dev/null)
    assert_eq "$name" "george-x"
  }

  it "includes server version" && {
    resp=$(_msx_one_shot '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    version=$(printf '%s' "$resp" | jq -r '.result.serverInfo.version' 2>/dev/null)
    assert_eq "$version" "1.0"
  }

  it "advertises tools capability" && {
    resp=$(_msx_one_shot '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    has_tools=$(printf '%s' "$resp" | jq 'has("result") and (.result.capabilities | has("tools"))' 2>/dev/null)
    assert_eq "$has_tools" "true"
  }

  it "returns valid JSON-RPC 2.0 envelope" && {
    resp=$(_msx_one_shot '{"jsonrpc":"2.0","id":42,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    version=$(printf '%s' "$resp" | jq -r '.jsonrpc' 2>/dev/null)
    assert_eq "$version" "2.0"
    id_val=$(printf '%s' "$resp" | jq -r '.id' 2>/dev/null)
    assert_eq "$id_val" "42"
  }

  it "echoes back request id" && {
    resp=$(_msx_one_shot '{"jsonrpc":"2.0","id":99,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    id_val=$(printf '%s' "$resp" | jq -r '.id' 2>/dev/null)
    assert_eq "$id_val" "99"
  }

  it "returns error for unknown method" && {
    resp=$(_msx_one_shot '{"jsonrpc":"2.0","id":1,"method":"bogus/method","params":{}}')
    err_code=$(printf '%s' "$resp" | jq -r '.error.code' 2>/dev/null)
    assert_eq "$err_code" "-32601"
  }

  it "error message includes method name" && {
    resp=$(_msx_one_shot '{"jsonrpc":"2.0","id":1,"method":"bogus/method","params":{}}')
    err_msg=$(printf '%s' "$resp" | jq -r '.error.message' 2>/dev/null)
    assert_contains "$err_msg" "bogus/method"
  }

  it "silently handles notifications without response" && {
    resp=$(_msx_one_shot '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}')
    assert_empty "$resp" "notifications should produce no response"
  }

# ══════════════════════════════════════════════════════════════
# tools/list
# ══════════════════════════════════════════════════════════════
describe "tools/list"

  it "returns all 5 tools" && {
    resp=$(_msx_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    count=$(printf '%s' "$resp" | jq '.result.tools | length' 2>/dev/null)
    assert_eq "$count" "5"
  }

  it "includes x_post tool" && {
    resp=$(_msx_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    has=$(printf '%s' "$resp" | jq '[.result.tools[] | select(.name == "x_post")] | length' 2>/dev/null)
    assert_eq "$has" "1"
  }

  it "includes x_timeline tool" && {
    resp=$(_msx_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    has=$(printf '%s' "$resp" | jq '[.result.tools[] | select(.name == "x_timeline")] | length' 2>/dev/null)
    assert_eq "$has" "1"
  }

  it "includes x_reply tool" && {
    resp=$(_msx_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    has=$(printf '%s' "$resp" | jq '[.result.tools[] | select(.name == "x_reply")] | length' 2>/dev/null)
    assert_eq "$has" "1"
  }

  it "includes x_search tool" && {
    resp=$(_msx_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    has=$(printf '%s' "$resp" | jq '[.result.tools[] | select(.name == "x_search")] | length' 2>/dev/null)
    assert_eq "$has" "1"
  }

  it "includes x_delete tool" && {
    resp=$(_msx_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    has=$(printf '%s' "$resp" | jq '[.result.tools[] | select(.name == "x_delete")] | length' 2>/dev/null)
    assert_eq "$has" "1"
  }

  it "all tools have inputSchema" && {
    resp=$(_msx_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    all_have=$(printf '%s' "$resp" | jq '[.result.tools[] | select(.inputSchema != null)] | length' 2>/dev/null)
    assert_eq "$all_have" "5" "all tools should have inputSchema"
  }

  it "all tools have descriptions" && {
    resp=$(_msx_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    all_have=$(printf '%s' "$resp" | jq '[.result.tools[] | select(.description != null and .description != "")] | length' 2>/dev/null)
    assert_eq "$all_have" "5" "all tools should have descriptions"
  }

  it "x_post requires text parameter" && {
    resp=$(_msx_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    req=$(printf '%s' "$resp" | jq -r '.result.tools[] | select(.name == "x_post") | .inputSchema.required[0]' 2>/dev/null)
    assert_eq "$req" "text"
  }

  it "x_reply requires tweet_id and text parameters" && {
    resp=$(_msx_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    reqs=$(printf '%s' "$resp" | jq -r '.result.tools[] | select(.name == "x_reply") | .inputSchema.required | join(",")' 2>/dev/null)
    assert_contains "$reqs" "tweet_id"
    assert_contains "$reqs" "text"
  }

  it "x_search requires query parameter" && {
    resp=$(_msx_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    req=$(printf '%s' "$resp" | jq -r '.result.tools[] | select(.name == "x_search") | .inputSchema.required[0]' 2>/dev/null)
    assert_eq "$req" "query"
  }

  it "x_delete requires tweet_id parameter" && {
    resp=$(_msx_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    req=$(printf '%s' "$resp" | jq -r '.result.tools[] | select(.name == "x_delete") | .inputSchema.required[0]' 2>/dev/null)
    assert_eq "$req" "tweet_id"
  }

  it "x_timeline has no required parameters" && {
    resp=$(_msx_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    reqs=$(printf '%s' "$resp" | jq -r '.result.tools[] | select(.name == "x_timeline") | .inputSchema.required // [] | length' 2>/dev/null)
    assert_eq "${reqs:-0}" "0"
  }

# ══════════════════════════════════════════════════════════════
# tools/call — auth gate (no X_BEARER_TOKEN)
# ══════════════════════════════════════════════════════════════
describe "tools/call — auth gate (no token)"

  it "x_post returns auth error without X_BEARER_TOKEN" && {
    resp=$(printf '%s\n%s\n%s\n' \
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
      '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
      '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"x_post","arguments":{"text":"hello"}}}' \
      | X_BEARER_TOKEN="" bash "$LODGE_DIR/lib/mcp_server_x.sh" 2>/dev/null | tail -1)
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "X_BEARER_TOKEN"
  }

  it "x_timeline returns auth error without X_BEARER_TOKEN" && {
    resp=$(printf '%s\n%s\n%s\n' \
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
      '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
      '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"x_timeline","arguments":{}}}' \
      | X_BEARER_TOKEN="" bash "$LODGE_DIR/lib/mcp_server_x.sh" 2>/dev/null | tail -1)
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "X_BEARER_TOKEN"
  }

  it "x_search returns auth error without X_BEARER_TOKEN" && {
    resp=$(printf '%s\n%s\n%s\n' \
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
      '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
      '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"x_search","arguments":{"query":"test"}}}' \
      | X_BEARER_TOKEN="" bash "$LODGE_DIR/lib/mcp_server_x.sh" 2>/dev/null | tail -1)
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "X_BEARER_TOKEN"
  }

  it "x_reply returns auth error without X_BEARER_TOKEN" && {
    resp=$(printf '%s\n%s\n%s\n' \
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
      '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
      '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"x_reply","arguments":{"tweet_id":"123","text":"hi"}}}' \
      | X_BEARER_TOKEN="" bash "$LODGE_DIR/lib/mcp_server_x.sh" 2>/dev/null | tail -1)
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "X_BEARER_TOKEN"
  }

  it "x_delete returns auth error without X_BEARER_TOKEN" && {
    resp=$(printf '%s\n%s\n%s\n' \
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
      '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
      '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"x_delete","arguments":{"tweet_id":"123"}}}' \
      | X_BEARER_TOKEN="" bash "$LODGE_DIR/lib/mcp_server_x.sh" 2>/dev/null | tail -1)
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "X_BEARER_TOKEN"
  }

# ══════════════════════════════════════════════════════════════
# tools/call — parameter validation (with fake token)
# ══════════════════════════════════════════════════════════════
describe "tools/call — parameter validation"

  it "x_post returns error when text is missing" && {
    resp=$(_msx_call_authed '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"x_post","arguments":{}}}')
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Error"
    assert_contains "$text" "text"
  }

  it "x_reply returns error when tweet_id is missing" && {
    resp=$(_msx_call_authed '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"x_reply","arguments":{"text":"hello"}}}')
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Error"
    assert_contains "$text" "tweet_id"
  }

  it "x_reply returns error when text is missing" && {
    resp=$(_msx_call_authed '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"x_reply","arguments":{"tweet_id":"123"}}}')
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Error"
    assert_contains "$text" "text"
  }

  it "x_search returns error when query is missing" && {
    resp=$(_msx_call_authed '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"x_search","arguments":{}}}')
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Error"
    assert_contains "$text" "query"
  }

  it "x_delete returns error when tweet_id is missing" && {
    resp=$(_msx_call_authed '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"x_delete","arguments":{}}}')
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Error"
    assert_contains "$text" "tweet_id"
  }

  it "returns error for unknown tool" && {
    resp=$(_msx_call_authed '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"nonexistent","arguments":{}}}')
    err=$(printf '%s' "$resp" | jq -r '.error.message' 2>/dev/null)
    assert_contains "$err" "Unknown tool"
  }

  it "returns MCP text content format" && {
    resp=$(_msx_call_authed '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"x_post","arguments":{}}}')
    content_type=$(printf '%s' "$resp" | jq -r '.result.content[0].type' 2>/dev/null)
    assert_eq "$content_type" "text"
  }

# ══════════════════════════════════════════════════════════════
# Integration with George MCP client
# ══════════════════════════════════════════════════════════════
describe "integration with George MCP client"

  it "starts via mcp_start and completes handshake" && {
    _msx_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "george-x" "$_SERVER_CMD" "George built-in X/Twitter"
    mcp_start "george-x"
    assert_ok $?
    assert_file_exists "$MCP_RUN_DIR/george-x/ready"
    _msx_teardown
    MCP_ENABLED=0
  }

  it "lists 5 tools via mcp_tools_list" && {
    _msx_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "george-x" "$_SERVER_CMD" "George built-in X/Twitter"
    mcp_start "george-x"
    tools=$(mcp_tools_list "george-x")
    count=$(printf '%s' "$tools" | jq 'length' 2>/dev/null)
    assert_eq "$count" "5" "should have 5 tools"
    _msx_teardown
    MCP_ENABLED=0
  }

  it "tool names match expected set" && {
    _msx_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "george-x" "$_SERVER_CMD" "George built-in X/Twitter"
    mcp_start "george-x"
    tools=$(mcp_tools_list "george-x")
    names=$(printf '%s' "$tools" | jq -r '.[].name' 2>/dev/null | sort | tr '\n' ',')
    assert_contains "$names" "x_delete"
    assert_contains "$names" "x_post"
    assert_contains "$names" "x_reply"
    assert_contains "$names" "x_search"
    assert_contains "$names" "x_timeline"
    _msx_teardown
    MCP_ENABLED=0
  }

  it "mcp_tool_call returns auth error without token" && {
    _msx_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "george-x" "$_SERVER_CMD" "George built-in X/Twitter"
    mcp_start "george-x"
    result=$(mcp_tool_call "george-x" "x_post" '{"text":"test"}' 2>/dev/null)
    assert_contains "$result" "X_BEARER_TOKEN"
    _msx_teardown
    MCP_ENABLED=0
  }

  it "appears in mcp_catalog output" && {
    _msx_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "george-x" "$_SERVER_CMD" "George built-in X/Twitter"
    mcp_start "george-x"
    catalog=$(mcp_catalog 2>/dev/null)
    assert_contains "$catalog" "george-x"
    assert_contains "$catalog" "x_post"
    _msx_teardown
    MCP_ENABLED=0
  }

test_end
