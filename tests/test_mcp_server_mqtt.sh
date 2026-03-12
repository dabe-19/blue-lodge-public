#!/bin/bash
# ── Tests: lib/mcp_server_mqtt.sh ─────────────────────────────
# Tests the pure-bash MCP MQTT server against the MCP protocol.
# Mocks mosquitto_pub/mosquitto_sub so no real broker is needed.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/cache.sh"
source "$LODGE_DIR/lib/mcp.sh"

test_start "lib/mcp_server_mqtt.sh — Pure-Bash MCP MQTT Server"

# ── Helpers ────────────────────────────────────────────────────
_SERVER_CMD="bash $LODGE_DIR/lib/mcp_server_mqtt.sh"
_MSM_TEST_DIR=""
_MSM_MOCK_BIN=""

_msm_setup() {
    _MSM_TEST_DIR=$(test_tmpdir)
    _MSM_MOCK_BIN="$_MSM_TEST_DIR/bin"
    mkdir -p "$_MSM_MOCK_BIN"

    # MCP client dirs
    MCP_CONFIG_DIR="$_MSM_TEST_DIR/config"
    MCP_RUN_DIR="$_MSM_TEST_DIR/run"
    MCP_SERVERS_FILE="$MCP_CONFIG_DIR/servers.conf"
    MCP_CATALOG_FILE="$MCP_CONFIG_DIR/catalog.conf"
    CACHE_DIR="$_MSM_TEST_DIR/cache"
    MCP_TIMEOUT=15
    mkdir -p "$MCP_CONFIG_DIR" "$MCP_RUN_DIR"
    cache_init

    # MQTT config (for the server process)
    GEORGE_CONFIG_DIR="$_MSM_TEST_DIR/george-config"
    mkdir -p "$GEORGE_CONFIG_DIR"
    cat > "$GEORGE_CONFIG_DIR/mqtt.conf" << 'CONF'
MQTT_BROKER=mock.broker
MQTT_PORT=1883
MQTT_CLIENT_ID=george-test
MQTT_PROTOCOL=5
MQTT_KEEPALIVE=60
MQTT_TLS=0
CONF

    # Mock mosquitto_pub: always succeed
    cat > "$_MSM_MOCK_BIN/mosquitto_pub" << 'MOCK'
#!/bin/bash
exit 0
MOCK
    chmod +x "$_MSM_MOCK_BIN/mosquitto_pub"

    # Mock mosquitto_sub: return canned message
    cat > "$_MSM_MOCK_BIN/mosquitto_sub" << 'MOCK'
#!/bin/bash
echo "mock-message-from-broker"
exit 0
MOCK
    chmod +x "$_MSM_MOCK_BIN/mosquitto_sub"

    # Export so the server subprocess sees them
    export GEORGE_CONFIG_DIR
    export PATH="$_MSM_MOCK_BIN:$PATH"
}

_msm_teardown() {
    mcp_stop_all 2>/dev/null
    rm -rf "$_MSM_TEST_DIR" 2>/dev/null
}

# Send a single JSON-RPC message and get response (one-shot)
_msm_one_shot() {
    printf '%s\n' "$1" | GEORGE_CONFIG_DIR="$GEORGE_CONFIG_DIR" PATH="$_MSM_MOCK_BIN:$PATH" \
        bash "$LODGE_DIR/lib/mcp_server_mqtt.sh" 2>/dev/null | head -1
}

# Send init + request, return last response
_msm_call() {
    _msm_init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
    _msm_notif='{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
    printf '%s\n%s\n%s\n' "$_msm_init" "$_msm_notif" "$1" | \
        GEORGE_CONFIG_DIR="$GEORGE_CONFIG_DIR" PATH="$_MSM_MOCK_BIN:$PATH" \
        bash "$LODGE_DIR/lib/mcp_server_mqtt.sh" 2>/dev/null | tail -1
}

# ── Protocol Compliance ───────────────────────────────────────
describe "MCP protocol compliance"

  it "responds to initialize with correct protocol version" && {
    _msm_setup
    _msm_resp=$(_msm_one_shot '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    _msm_proto=$(printf '%s' "$_msm_resp" | jq -r '.result.protocolVersion' 2>/dev/null)
    assert_eq "$_msm_proto" "2024-11-05"
    _msm_teardown
  }

  it "includes server info with name george-mqtt" && {
    _msm_setup
    _msm_resp=$(_msm_one_shot '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    _msm_name=$(printf '%s' "$_msm_resp" | jq -r '.result.serverInfo.name' 2>/dev/null)
    assert_eq "$_msm_name" "george-mqtt"
    _msm_teardown
  }

  it "advertises tools capability" && {
    _msm_setup
    _msm_resp=$(_msm_one_shot '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    _msm_has=$(printf '%s' "$_msm_resp" | jq 'has("result") and (.result.capabilities | has("tools"))' 2>/dev/null)
    assert_eq "$_msm_has" "true"
    _msm_teardown
  }

  it "returns valid JSON-RPC 2.0 envelope" && {
    _msm_setup
    _msm_resp=$(_msm_one_shot '{"jsonrpc":"2.0","id":77,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    _msm_ver=$(printf '%s' "$_msm_resp" | jq -r '.jsonrpc' 2>/dev/null)
    assert_eq "$_msm_ver" "2.0"
    _msm_id=$(printf '%s' "$_msm_resp" | jq -r '.id' 2>/dev/null)
    assert_eq "$_msm_id" "77"
    _msm_teardown
  }

  it "returns error for unknown method" && {
    _msm_setup
    _msm_resp=$(_msm_one_shot '{"jsonrpc":"2.0","id":1,"method":"bogus/method","params":{}}')
    _msm_errcode=$(printf '%s' "$_msm_resp" | jq -r '.error.code' 2>/dev/null)
    assert_eq "$_msm_errcode" "-32601"
    _msm_teardown
  }

# ── tools/list ─────────────────────────────────────────────────
describe "tools/list"

  it "returns all 3 tools" && {
    _msm_setup
    _msm_resp=$(_msm_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    _msm_count=$(printf '%s' "$_msm_resp" | jq '.result.tools | length' 2>/dev/null)
    assert_eq "$_msm_count" "3"
    _msm_teardown
  }

  it "includes mqtt_publish tool" && {
    _msm_setup
    _msm_resp=$(_msm_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    _msm_has=$(printf '%s' "$_msm_resp" | jq '[.result.tools[] | select(.name == "mqtt_publish")] | length' 2>/dev/null)
    assert_eq "$_msm_has" "1"
    _msm_teardown
  }

  it "includes mqtt_subscribe tool" && {
    _msm_setup
    _msm_resp=$(_msm_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    _msm_has=$(printf '%s' "$_msm_resp" | jq '[.result.tools[] | select(.name == "mqtt_subscribe")] | length' 2>/dev/null)
    assert_eq "$_msm_has" "1"
    _msm_teardown
  }

  it "includes mqtt_status tool" && {
    _msm_setup
    _msm_resp=$(_msm_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    _msm_has=$(printf '%s' "$_msm_resp" | jq '[.result.tools[] | select(.name == "mqtt_status")] | length' 2>/dev/null)
    assert_eq "$_msm_has" "1"
    _msm_teardown
  }

  it "all tools have inputSchema" && {
    _msm_setup
    _msm_resp=$(_msm_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    _msm_cnt=$(printf '%s' "$_msm_resp" | jq '[.result.tools[] | select(.inputSchema != null)] | length' 2>/dev/null)
    assert_eq "$_msm_cnt" "3"
    _msm_teardown
  }

# ── tools/call — mqtt_publish ──────────────────────────────────
describe "tools/call — mqtt_publish"

  it "succeeds with topic and message" && {
    _msm_setup
    _msm_resp=$(_msm_call '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"mqtt_publish","arguments":{"topic":"test/pub","message":"hello"}}}')
    _msm_text=$(printf '%s' "$_msm_resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$_msm_text" "Published to test/pub"
    _msm_teardown
  }

  it "returns error when topic is missing" && {
    _msm_setup
    _msm_resp=$(_msm_call '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"mqtt_publish","arguments":{"message":"hello"}}}')
    _msm_text=$(printf '%s' "$_msm_resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$_msm_text" "Error"
    _msm_teardown
  }

  it "returns error when message is missing" && {
    _msm_setup
    _msm_resp=$(_msm_call '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"mqtt_publish","arguments":{"topic":"test/pub"}}}')
    _msm_text=$(printf '%s' "$_msm_resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$_msm_text" "Error"
    _msm_teardown
  }

# ── tools/call — mqtt_subscribe ────────────────────────────────
describe "tools/call — mqtt_subscribe"

  it "returns received message" && {
    _msm_setup
    _msm_resp=$(_msm_call '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"mqtt_subscribe","arguments":{"topic":"test/sub"}}}')
    _msm_text=$(printf '%s' "$_msm_resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$_msm_text" "mock-message-from-broker"
    _msm_teardown
  }

  it "returns error when topic is missing" && {
    _msm_setup
    _msm_resp=$(_msm_call '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"mqtt_subscribe","arguments":{}}}')
    _msm_text=$(printf '%s' "$_msm_resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$_msm_text" "Error"
    _msm_teardown
  }

# ── tools/call — mqtt_status ──────────────────────────────────
describe "tools/call — mqtt_status"

  it "returns broker info" && {
    _msm_setup
    _msm_resp=$(_msm_call '{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"mqtt_status","arguments":{}}}')
    _msm_text=$(printf '%s' "$_msm_resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$_msm_text" "mock.broker"
    _msm_teardown
  }

# ── Unknown tool ───────────────────────────────────────────────
describe "error handling"

  it "returns error for unknown tool" && {
    _msm_setup
    _msm_resp=$(_msm_call '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"nonexistent","arguments":{}}}')
    _msm_err=$(printf '%s' "$_msm_resp" | jq -r '.error.message' 2>/dev/null)
    assert_contains "$_msm_err" "Unknown tool"
    _msm_teardown
  }

# ── Integration with MCP client ────────────────────────────────
describe "integration with George MCP client"

  it "starts via mcp_start and completes handshake" && {
    _msm_setup
    MCP_ENABLED=1
    mcp_init
    # The server command needs the mock PATH and config
    _msm_server_cmd="PATH=$_MSM_MOCK_BIN:\$PATH GEORGE_CONFIG_DIR=$GEORGE_CONFIG_DIR bash $LODGE_DIR/lib/mcp_server_mqtt.sh"
    mcp_server_add "george-mqtt" "$_msm_server_cmd" "MQTT pub/sub"
    mcp_start "george-mqtt"
    assert_ok $?
    assert_file_exists "$MCP_RUN_DIR/george-mqtt/ready"
    _msm_teardown
    MCP_ENABLED=0
  }

  it "lists tools via mcp_tools_list" && {
    _msm_setup
    MCP_ENABLED=1
    mcp_init
    _msm_server_cmd="PATH=$_MSM_MOCK_BIN:\$PATH GEORGE_CONFIG_DIR=$GEORGE_CONFIG_DIR bash $LODGE_DIR/lib/mcp_server_mqtt.sh"
    mcp_server_add "george-mqtt" "$_msm_server_cmd" "MQTT pub/sub"
    mcp_start "george-mqtt"
    _msm_tools=$(mcp_tools_list "george-mqtt")
    _msm_tcount=$(printf '%s' "$_msm_tools" | jq 'length' 2>/dev/null)
    assert_eq "$_msm_tcount" "3"
    _msm_teardown
    MCP_ENABLED=0
  }

test_end
