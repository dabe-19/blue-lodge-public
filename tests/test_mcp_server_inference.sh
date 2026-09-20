#!/bin/bash
# ── Tests: lib/mcp_server_inference.sh ─────────────────────────
# Tests the pure-bash MCP Inference server against the MCP protocol.
# Mocks curl so no real Ollama/llama-server is needed.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/cache.sh"
source "$LODGE_DIR/lib/mcp.sh"

test_start "lib/mcp_server_inference.sh — Pure-Bash MCP Inference Server"

# ── Helpers ────────────────────────────────────────────────────
_SERVER_CMD="bash $LODGE_DIR/lib/mcp_server_inference.sh"
_MSI_TEST_DIR=""
_MSI_MOCK_BIN=""

_msi_setup() {
    _MSI_TEST_DIR=$(test_tmpdir)
    _MSI_MOCK_BIN="$_MSI_TEST_DIR/bin"
    mkdir -p "$_MSI_MOCK_BIN"

    # MCP client dirs
    MCP_CONFIG_DIR="$_MSI_TEST_DIR/config"
    MCP_RUN_DIR="$_MSI_TEST_DIR/run"
    MCP_SERVERS_FILE="$MCP_CONFIG_DIR/servers.conf"
    MCP_CATALOG_FILE="$MCP_CONFIG_DIR/catalog.conf"
    CACHE_DIR="$_MSI_TEST_DIR/cache"
    MCP_TIMEOUT=15
    mkdir -p "$MCP_CONFIG_DIR" "$MCP_RUN_DIR"
    cache_init

    # George dirs
    GEORGE_DIR="$_MSI_TEST_DIR/george"
    mkdir -p "$GEORGE_DIR"

    # URLs for mock server
    export OLLAMA_URL="http://127.0.0.1:11434"
    export LLAMA_CPP_URL="http://127.0.0.1:8080"

    # Mock curl: dispatch on URL to return canned responses
    cat > "$_MSI_MOCK_BIN/curl" << 'MOCK'
#!/bin/bash
# Parse the URL from arguments (last positional arg that starts with http)
_url=""
_data=""
for _arg in "$@"; do
    case "$_arg" in
        http*) _url="$_arg" ;;
    esac
done
# Parse -d data
_prev=""
for _arg in "$@"; do
    if [ "$_prev" = "-d" ]; then
        _data="$_arg"
    fi
    _prev="$_arg"
done

case "$_url" in
    */api/tags)
        cat << 'JSON'
{"models":[{"name":"qwen3:8b","size":5368709120,"details":{"family":"qwen3","parameter_size":"8B","quantization_level":"Q4_K_M"},"modified_at":"2025-07-01T00:00:00Z"},{"name":"llama3.1:8b","size":4815060992,"details":{"family":"llama","parameter_size":"8B","quantization_level":"Q4_K_M"},"modified_at":"2025-06-15T00:00:00Z"}]}
JSON
        exit 0 ;;
    */api/ps)
        cat << 'JSON'
{"models":[{"name":"qwen3:8b","size":5368709120,"size_vram":4735027200,"details":{"quantization_level":"Q4_K_M"},"expires_at":"2025-07-01T01:00:00Z"}]}
JSON
        exit 0 ;;
    */api/pull)
        echo '{"status":"success"}'
        exit 0 ;;
    */api/generate)
        echo '{"model":"qwen3:8b","response":"","done":true}'
        exit 0 ;;
    */health)
        echo '{"status":"ok"}'
        exit 0 ;;
    */props)
        echo '{"total_slots":4,"chat_template":"chatml"}'
        exit 0 ;;
    *)
        echo "mock: unknown URL $_url" >&2
        exit 1 ;;
esac
MOCK
    chmod +x "$_MSI_MOCK_BIN/curl"

    export PATH="$_MSI_MOCK_BIN:$PATH"
}

_msi_teardown() {
    mcp_stop_all 2>/dev/null
    rm -rf "$_MSI_TEST_DIR" 2>/dev/null
}

# Send a single JSON-RPC message and get response (one-shot)
_msi_one_shot() {
    printf '%s\n' "$1" | \
        OLLAMA_URL="$OLLAMA_URL" LLAMA_CPP_URL="$LLAMA_CPP_URL" PATH="$_MSI_MOCK_BIN:$PATH" \
        bash "$LODGE_DIR/lib/mcp_server_inference.sh" 2>/dev/null | head -1
}

# Send init + request, return last response
_msi_call() {
    _msi_init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
    _msi_notif='{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
    printf '%s\n%s\n%s\n' "$_msi_init" "$_msi_notif" "$1" | \
        OLLAMA_URL="$OLLAMA_URL" LLAMA_CPP_URL="$LLAMA_CPP_URL" PATH="$_MSI_MOCK_BIN:$PATH" \
        bash "$LODGE_DIR/lib/mcp_server_inference.sh" 2>/dev/null | tail -1
}

# ── Protocol Compliance ───────────────────────────────────────
describe "MCP protocol compliance"

  it "responds to initialize with correct protocol version" && {
    _msi_setup
    _msi_resp=$(_msi_one_shot '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    _msi_proto=$(printf '%s' "$_msi_resp" | jq -r '.result.protocolVersion' 2>/dev/null)
    assert_eq "$_msi_proto" "2024-11-05"
    _msi_teardown
  }

  it "includes server info with name george-inference" && {
    _msi_setup
    _msi_resp=$(_msi_one_shot '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    _msi_name=$(printf '%s' "$_msi_resp" | jq -r '.result.serverInfo.name' 2>/dev/null)
    assert_eq "$_msi_name" "george-inference"
    _msi_teardown
  }

  it "advertises tools capability" && {
    _msi_setup
    _msi_resp=$(_msi_one_shot '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    _msi_has=$(printf '%s' "$_msi_resp" | jq 'has("result") and (.result.capabilities | has("tools"))' 2>/dev/null)
    assert_eq "$_msi_has" "true"
    _msi_teardown
  }

  it "returns valid JSON-RPC 2.0 envelope" && {
    _msi_setup
    _msi_resp=$(_msi_one_shot '{"jsonrpc":"2.0","id":42,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    _msi_ver=$(printf '%s' "$_msi_resp" | jq -r '.jsonrpc' 2>/dev/null)
    assert_eq "$_msi_ver" "2.0"
    _msi_id=$(printf '%s' "$_msi_resp" | jq -r '.id' 2>/dev/null)
    assert_eq "$_msi_id" "42"
    _msi_teardown
  }

  it "returns error for unknown method" && {
    _msi_setup
    _msi_resp=$(_msi_one_shot '{"jsonrpc":"2.0","id":1,"method":"bogus/method","params":{}}')
    _msi_errcode=$(printf '%s' "$_msi_resp" | jq -r '.error.code' 2>/dev/null)
    assert_eq "$_msi_errcode" "-32601"
    _msi_teardown
  }

# ── tools/list ─────────────────────────────────────────────────
describe "tools/list"

  it "returns all 5 tools" && {
    _msi_setup
    _msi_resp=$(_msi_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    _msi_count=$(printf '%s' "$_msi_resp" | jq '.result.tools | length' 2>/dev/null)
    assert_eq "$_msi_count" "5"
    _msi_teardown
  }

  it "includes inference_status tool" && {
    _msi_setup
    _msi_resp=$(_msi_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    _msi_has=$(printf '%s' "$_msi_resp" | jq '[.result.tools[] | select(.name == "inference_status")] | length' 2>/dev/null)
    assert_eq "$_msi_has" "1"
    _msi_teardown
  }

  it "includes inference_models tool" && {
    _msi_setup
    _msi_resp=$(_msi_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    _msi_has=$(printf '%s' "$_msi_resp" | jq '[.result.tools[] | select(.name == "inference_models")] | length' 2>/dev/null)
    assert_eq "$_msi_has" "1"
    _msi_teardown
  }

  it "includes inference_pull tool" && {
    _msi_setup
    _msi_resp=$(_msi_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    _msi_has=$(printf '%s' "$_msi_resp" | jq '[.result.tools[] | select(.name == "inference_pull")] | length' 2>/dev/null)
    assert_eq "$_msi_has" "1"
    _msi_teardown
  }

  it "all tools have inputSchema" && {
    _msi_setup
    _msi_resp=$(_msi_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    _msi_cnt=$(printf '%s' "$_msi_resp" | jq '[.result.tools[] | select(.inputSchema != null)] | length' 2>/dev/null)
    assert_eq "$_msi_cnt" "5"
    _msi_teardown
  }

# ── tools/call — inference_status ──────────────────────────────
describe "tools/call — inference_status"

  it "returns combined status of both endpoints" && {
    _msi_setup
    _msi_resp=$(_msi_call '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"inference_status","arguments":{}}}')
    _msi_text=$(printf '%s' "$_msi_resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$_msi_text" "Ollama: running"
    assert_contains "$_msi_text" "llama-server: ok"
    _msi_teardown
  }

# ── tools/call — inference_models ──────────────────────────────
describe "tools/call — inference_models"

  it "returns model list from Ollama" && {
    _msi_setup
    _msi_resp=$(_msi_call '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"inference_models","arguments":{}}}')
    _msi_text=$(printf '%s' "$_msi_resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$_msi_text" "qwen3:8b"
    assert_contains "$_msi_text" "llama3.1:8b"
    _msi_teardown
  }

# ── tools/call — inference_ps ──────────────────────────────────
describe "tools/call — inference_ps"

  it "returns loaded model info" && {
    _msi_setup
    _msi_resp=$(_msi_call '{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"inference_ps","arguments":{}}}')
    _msi_text=$(printf '%s' "$_msi_resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$_msi_text" "qwen3:8b"
    _msi_teardown
  }

# ── tools/call — inference_pull ────────────────────────────────
describe "tools/call — inference_pull"

  it "succeeds with valid model tag" && {
    _msi_setup
    _msi_resp=$(_msi_call '{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"inference_pull","arguments":{"model":"qwen3:8b"}}}')
    _msi_text=$(printf '%s' "$_msi_resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$_msi_text" "success"
    _msi_teardown
  }

  it "returns error when model is missing" && {
    _msi_setup
    _msi_resp=$(_msi_call '{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"inference_pull","arguments":{}}}')
    _msi_text=$(printf '%s' "$_msi_resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$_msi_text" "Error"
    _msi_teardown
  }

  it "rejects model tag with invalid characters" && {
    _msi_setup
    _msi_resp=$(_msi_call '{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"inference_pull","arguments":{"model":"$(evil)"}}}')
    _msi_text=$(printf '%s' "$_msi_resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$_msi_text" "Invalid"
    _msi_teardown
  }

# ── tools/call — inference_load ────────────────────────────────
describe "tools/call — inference_load"

  it "succeeds with valid model name" && {
    _msi_setup
    _msi_resp=$(_msi_call '{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"inference_load","arguments":{"model":"qwen3:8b"}}}')
    _msi_text=$(printf '%s' "$_msi_resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$_msi_text" "loaded"
    _msi_teardown
  }

  it "returns error when model is missing" && {
    _msi_setup
    _msi_resp=$(_msi_call '{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"inference_load","arguments":{}}}')
    _msi_text=$(printf '%s' "$_msi_resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$_msi_text" "Error"
    _msi_teardown
  }

# ── Unknown tool ───────────────────────────────────────────────
describe "error handling"

  it "returns error for unknown tool" && {
    _msi_setup
    _msi_resp=$(_msi_call '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"nonexistent","arguments":{}}}')
    _msi_err=$(printf '%s' "$_msi_resp" | jq -r '.error.message' 2>/dev/null)
    assert_contains "$_msi_err" "Unknown tool"
    _msi_teardown
  }

# ── Integration with MCP client ────────────────────────────────
describe "integration with George MCP client"

  it "starts via mcp_start and completes handshake" && {
    _msi_setup
    MCP_ENABLED=1
    mcp_init
    _msi_server_cmd="PATH=$_MSI_MOCK_BIN:\$PATH OLLAMA_URL=$OLLAMA_URL LLAMA_CPP_URL=$LLAMA_CPP_URL bash $LODGE_DIR/lib/mcp_server_inference.sh"
    mcp_server_add "george-inference" "$_msi_server_cmd" "Remote inference"
    mcp_start "george-inference"
    assert_ok $?
    assert_file_exists "$MCP_RUN_DIR/george-inference/ready"
    _msi_teardown
    MCP_ENABLED=0
  }

  it "lists tools via mcp_tools_list" && {
    _msi_setup
    MCP_ENABLED=1
    mcp_init
    _msi_server_cmd="PATH=$_MSI_MOCK_BIN:\$PATH OLLAMA_URL=$OLLAMA_URL LLAMA_CPP_URL=$LLAMA_CPP_URL bash $LODGE_DIR/lib/mcp_server_inference.sh"
    mcp_server_add "george-inference" "$_msi_server_cmd" "Remote inference"
    mcp_start "george-inference"
    _msi_tools=$(mcp_tools_list "george-inference")
    _msi_tcount=$(printf '%s' "$_msi_tools" | jq 'length' 2>/dev/null)
    assert_eq "$_msi_tcount" "5"
    _msi_teardown
    MCP_ENABLED=0
  }

test_end
