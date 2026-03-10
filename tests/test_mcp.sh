#!/bin/bash
# ── Tests: lib/mcp.sh ─────────────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/cache.sh"
source "$LODGE_DIR/lib/mcp.sh"

test_start "lib/mcp.sh — MCP Client Integration"

# ── Test Setup ─────────────────────────────────────────────────
_MCP_TEST_DIR=""
_MCP_MOCK_SCRIPT=""

_mcp_test_setup() {
    _MCP_TEST_DIR=$(test_tmpdir)
    MCP_CONFIG_DIR="$_MCP_TEST_DIR/config"
    MCP_RUN_DIR="$_MCP_TEST_DIR/run"
    MCP_SERVERS_FILE="$MCP_CONFIG_DIR/servers.conf"
    MCP_CATALOG_FILE="$MCP_CONFIG_DIR/catalog.conf"
    MCP_TIMEOUT=5
    mkdir -p "$MCP_CONFIG_DIR" "$MCP_RUN_DIR"

    # Redirect cache to test temp dir so _cache_stat_bump doesn't
    # fail writing to the real GEORGE_DIR/cache/lru/.stats
    CACHE_DIR="$_MCP_TEST_DIR/cache"
    cache_init

    # Create mock MCP server script
    _MCP_MOCK_SCRIPT="$_MCP_TEST_DIR/mock_server.sh"
    cat > "$_MCP_MOCK_SCRIPT" << 'MOCK'
#!/bin/bash
while IFS= read -r line; do
    [ -z "$line" ] && continue
    id=$(printf '%s' "$line" | jq -r '.id // empty' 2>/dev/null)
    method=$(printf '%s' "$line" | jq -r '.method // empty' 2>/dev/null)
    case "$method" in
        initialize)
            printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"mock","version":"0.1"}}}\n' "$id"
            ;;
        tools/list)
            printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"mock_fetch","description":"Mock fetch tool","inputSchema":{"type":"object","properties":{"url":{"type":"string"}}}},{"name":"mock_search","description":"Mock search tool","inputSchema":{"type":"object","properties":{"query":{"type":"string"}}}}]}}\n' "$id"
            ;;
        tools/call)
            tool_name=$(printf '%s' "$line" | jq -r '.params.name // empty' 2>/dev/null)
            printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"Mock response from %s"}]}}\n' "$id" "$tool_name"
            ;;
        notifications/*)
            ;;
    esac
done
MOCK
    chmod +x "$_MCP_MOCK_SCRIPT"
}

_mcp_test_teardown() {
    mcp_stop_all 2>/dev/null
    rm -rf "$_MCP_TEST_DIR" 2>/dev/null
}

# ── Dependency check ───────────────────────────────────────────
describe "dependency check"

  it "detects jq availability" && {
    assert_not_empty "$_MCP_JQ_CMD" "jq or gojq should be available"
  }

  it "mcp_enabled returns false when MCP_ENABLED=0" && {
    MCP_ENABLED=0
    mcp_enabled
    assert_fail $?
  }

  it "mcp_enabled returns true when MCP_ENABLED=1" && {
    MCP_ENABLED=1
    mcp_enabled
    assert_ok $?
    MCP_ENABLED=0
  }

# ── Init ───────────────────────────────────────────────────────
describe "mcp_init"

  it "creates config directory" && {
    _mcp_test_setup
    mcp_init
    assert_dir_exists "$MCP_CONFIG_DIR"
    _mcp_test_teardown
  }

  it "creates default catalog" && {
    _mcp_test_setup
    mcp_init
    assert_file_exists "$MCP_CATALOG_FILE"
    _mcp_test_teardown
  }

  it "creates empty servers file" && {
    _mcp_test_setup
    mcp_init
    assert_file_exists "$MCP_SERVERS_FILE"
    _mcp_test_teardown
  }

# ── Server Registry ───────────────────────────────────────────
describe "mcp_server_add"

  it "registers a server" && {
    _mcp_test_setup
    mcp_init
    mcp_server_add "test-srv" "echo hello" "A test server"
    assert_ok $?
    exists=1
    _mcp_server_exists "test-srv" && exists=0
    assert_eq "$exists" "0"
    _mcp_test_teardown
  }

  it "stores command correctly" && {
    _mcp_test_setup
    mcp_init
    mcp_server_add "test-srv" "npx -y @test/server" "Test"
    cmd=$(_mcp_server_cmd "test-srv")
    assert_eq "$cmd" "npx -y @test/server"
    _mcp_test_teardown
  }

  it "stores description correctly" && {
    _mcp_test_setup
    mcp_init
    mcp_server_add "test-srv" "echo test" "My description"
    desc=$(_mcp_server_desc "test-srv")
    assert_eq "$desc" "My description"
    _mcp_test_teardown
  }

  it "rejects invalid server names" && {
    _mcp_test_setup
    mcp_init
    err=$(mcp_server_add "bad name!" "echo test" 2>&1)
    assert_fail $?
    assert_contains "$err" "alphanumeric"
    _mcp_test_teardown
  }

  it "updates existing server on re-add" && {
    _mcp_test_setup
    mcp_init
    mcp_server_add "dup" "cmd1" "First"
    mcp_server_add "dup" "cmd2" "Second"
    cmd=$(_mcp_server_cmd "dup")
    assert_eq "$cmd" "cmd2"
    count=$(grep -c "^dup|" "$MCP_SERVERS_FILE")
    assert_eq "$count" "1"
    _mcp_test_teardown
  }

describe "mcp_server_remove"

  it "removes a registered server" && {
    _mcp_test_setup
    mcp_init
    mcp_server_add "removeme" "echo test" "Remove me"
    mcp_server_remove "removeme"
    _mcp_server_exists "removeme"
    assert_fail $?
    _mcp_test_teardown
  }

  it "is idempotent on non-existent server" && {
    _mcp_test_setup
    mcp_init
    mcp_server_remove "nonexistent"
    assert_ok $? "Removing non-existent server should not fail fatally"
    _mcp_test_teardown
  }

describe "mcp_server_list"

  it "lists all registered servers" && {
    _mcp_test_setup
    mcp_init
    mcp_server_add "alpha" "cmd-a" "Server A"
    mcp_server_add "beta" "cmd-b" "Server B"
    listing=$(mcp_server_list)
    assert_contains "$listing" "alpha"
    assert_contains "$listing" "beta"
    _mcp_test_teardown
  }

  it "returns empty for no servers" && {
    _mcp_test_setup
    mcp_init
    listing=$(mcp_server_list)
    assert_empty "$listing"
    _mcp_test_teardown
  }

describe "mcp_server_names"

  it "returns only server names" && {
    _mcp_test_setup
    mcp_init
    mcp_server_add "srv1" "cmd1" "Desc 1"
    mcp_server_add "srv2" "cmd2" "Desc 2"
    names=$(mcp_server_names)
    assert_contains "$names" "srv1"
    assert_contains "$names" "srv2"
    assert_not_contains "$names" "cmd1"
    _mcp_test_teardown
  }

# ── JSON-RPC Helpers ───────────────────────────────────────────
describe "_mcp_build_request"

  it "builds valid JSON-RPC 2.0 request" && {
    req=$(_mcp_build_request 1 "tools/list" '{}')
    version=$(printf '%s' "$req" | jq -r '.jsonrpc')
    assert_eq "$version" "2.0"
    id_val=$(printf '%s' "$req" | jq -r '.id')
    assert_eq "$id_val" "1"
    method=$(printf '%s' "$req" | jq -r '.method')
    assert_eq "$method" "tools/list"
  }

  it "includes params when provided" && {
    req=$(_mcp_build_request 5 "tools/call" '{"name":"fetch","arguments":{}}')
    param_name=$(printf '%s' "$req" | jq -r '.params.name')
    assert_eq "$param_name" "fetch"
  }

  it "defaults params to empty object" && {
    req=$(_mcp_build_request 1 "tools/list" "")
    params_val=$(printf '%s' "$req" | jq -r '.params')
    assert_eq "$params_val" "{}"
  }

describe "_mcp_build_notification"

  it "builds notification without id" && {
    notif=$(_mcp_build_notification "notifications/initialized" '{}')
    has_id=$(printf '%s' "$notif" | jq 'has("id")')
    assert_eq "$has_id" "false"
    method=$(printf '%s' "$notif" | jq -r '.method')
    assert_eq "$method" "notifications/initialized"
  }

describe "_mcp_next_id"

  it "returns incrementing IDs" && {
    _mcp_test_setup
    name="test-id"
    mkdir -p "$MCP_RUN_DIR/$name"
    echo "0" > "$MCP_RUN_DIR/$name/req_id"
    id1=$(_mcp_next_id "$name")
    id2=$(_mcp_next_id "$name")
    id3=$(_mcp_next_id "$name")
    assert_eq "$id1" "1"
    assert_eq "$id2" "2"
    assert_eq "$id3" "3"
    _mcp_test_teardown
  }

# ── Server Lifecycle with Mock ─────────────────────────────────
describe "mcp_start (mock server)"

  it "starts mock server and completes handshake" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "mock" "bash $_MCP_MOCK_SCRIPT" "Mock server"
    mcp_start "mock"
    assert_ok $?
    _mcp_test_teardown
    MCP_ENABLED=0
  }

  it "creates ready file on success" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "mock" "bash $_MCP_MOCK_SCRIPT" "Mock server"
    mcp_start "mock"
    assert_file_exists "$MCP_RUN_DIR/mock/ready"
    _mcp_test_teardown
    MCP_ENABLED=0
  }

  it "stores server capabilities" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "mock" "bash $_MCP_MOCK_SCRIPT" "Mock server"
    mcp_start "mock"
    assert_file_exists "$MCP_RUN_DIR/mock/capabilities.json"
    proto=$(jq -r '.protocolVersion' "$MCP_RUN_DIR/mock/capabilities.json" 2>/dev/null)
    assert_eq "$proto" "2024-11-05"
    _mcp_test_teardown
    MCP_ENABLED=0
  }

  it "is idempotent when already running" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "mock" "bash $_MCP_MOCK_SCRIPT" "Mock server"
    mcp_start "mock"
    mcp_start "mock"
    assert_ok $?
    _mcp_test_teardown
    MCP_ENABLED=0
  }

  it "fails for unknown server" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    err=$(mcp_start "nonexistent" 2>&1)
    assert_fail $?
    assert_contains "$err" "Unknown"
    _mcp_test_teardown
    MCP_ENABLED=0
  }

  it "fails when jq is missing" && {
    saved="$_MCP_JQ_CMD"
    _MCP_JQ_CMD=""
    err=$(mcp_start "anything" 2>&1)
    assert_fail $?
    assert_contains "$err" "jq"
    _MCP_JQ_CMD="$saved"
  }

describe "mcp_stop"

  it "stops a running server" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "mock" "bash $_MCP_MOCK_SCRIPT" "Mock server"
    mcp_start "mock"
    mcp_stop "mock"
    mcp_status "mock"
    assert_fail $?
    _mcp_test_teardown
    MCP_ENABLED=0
  }

  it "removes ready file" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "mock" "bash $_MCP_MOCK_SCRIPT" "Mock server"
    mcp_start "mock"
    mcp_stop "mock"
    assert_file_not_exists "$MCP_RUN_DIR/mock/ready"
    _mcp_test_teardown
    MCP_ENABLED=0
  }

  it "is safe on non-running server" && {
    _mcp_test_setup
    mcp_stop "ghost"
    assert_ok $? "Stopping non-running server should be safe"
    _mcp_test_teardown
  }

describe "mcp_status"

  it "returns 0 for running server" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "mock" "bash $_MCP_MOCK_SCRIPT" "Mock server"
    mcp_start "mock"
    mcp_status "mock"
    assert_ok $?
    _mcp_test_teardown
    MCP_ENABLED=0
  }

  it "returns 1 for stopped server" && {
    _mcp_test_setup
    mcp_status "not-started"
    assert_fail $?
    _mcp_test_teardown
  }

describe "mcp_stop_all"

  it "stops all running servers" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "mock1" "bash $_MCP_MOCK_SCRIPT" "Mock 1"
    mcp_server_add "mock2" "bash $_MCP_MOCK_SCRIPT" "Mock 2"
    mcp_start "mock1"
    mcp_start "mock2"
    mcp_stop_all
    mcp_status "mock1" 2>/dev/null; rc1=$?
    mcp_status "mock2" 2>/dev/null; rc2=$?
    assert_fail "$rc1"
    assert_fail "$rc2"
    _mcp_test_teardown
    MCP_ENABLED=0
  }

describe "mcp_running_servers"

  it "lists only running servers" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "mock-a" "bash $_MCP_MOCK_SCRIPT" "Running"
    mcp_server_add "mock-b" "bash $_MCP_MOCK_SCRIPT" "Stopped"
    mcp_start "mock-a"
    running=$(mcp_running_servers)
    assert_contains "$running" "mock-a"
    assert_not_contains "$running" "mock-b"
    _mcp_test_teardown
    MCP_ENABLED=0
  }

# ── MCP Protocol: Tools ───────────────────────────────────────
describe "mcp_tools_list"

  it "retrieves tool list from mock server" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "mock" "bash $_MCP_MOCK_SCRIPT" "Mock"
    mcp_start "mock"
    tools=$(mcp_tools_list "mock")
    assert_not_empty "$tools"
    count=$(printf '%s' "$tools" | jq 'length')
    assert_eq "$count" "2"
    first_name=$(printf '%s' "$tools" | jq -r '.[0].name')
    assert_eq "$first_name" "mock_fetch"
    _mcp_test_teardown
    MCP_ENABLED=0
  }

  it "caches tool list in LRU cache" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    cache_init
    mcp_server_add "mock" "bash $_MCP_MOCK_SCRIPT" "Mock"
    mcp_start "mock"
    mcp_tools_list "mock" > /dev/null
    cached=$(cache_get "mcp:tools:mock" "$MCP_CACHE_NS")
    assert_not_empty "$cached"
    assert_contains "$cached" "mock_fetch"
    _mcp_test_teardown
    MCP_ENABLED=0
  }

  it "returns cached tools without running server" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    cache_init
    cache_put "mcp:tools:cached-srv" "$MCP_CACHE_NS" '[{"name":"cached_tool","description":"From cache"}]'
    mcp_server_add "cached-srv" "echo nope" "Cached"
    tools=$(mcp_tools_list "cached-srv")
    assert_contains "$tools" "cached_tool"
    _mcp_test_teardown
    MCP_ENABLED=0
  }

describe "mcp_tool_call"

  it "calls a tool and gets text response" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "mock" "bash $_MCP_MOCK_SCRIPT" "Mock"
    mcp_start "mock"
    result=$(mcp_tool_call "mock" "mock_fetch" '{"url":"https://example.com"}')
    assert_not_empty "$result"
    assert_contains "$result" "Mock response from mock_fetch"
    _mcp_test_teardown
    MCP_ENABLED=0
  }

  it "handles empty params gracefully" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "mock" "bash $_MCP_MOCK_SCRIPT" "Mock"
    mcp_start "mock"
    result=$(mcp_tool_call "mock" "mock_search" "")
    assert_not_empty "$result"
    _mcp_test_teardown
    MCP_ENABLED=0
  }

# ── Tool Discovery ────────────────────────────────────────────
describe "mcp_find_tool"

  it "finds which server has a tool" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    cache_init
    mcp_server_add "mock" "bash $_MCP_MOCK_SCRIPT" "Mock"
    mcp_start "mock"
    mcp_tools_list "mock" > /dev/null
    server=$(mcp_find_tool "mock_fetch")
    assert_eq "$server" "mock"
    _mcp_test_teardown
    MCP_ENABLED=0
  }

  it "returns failure for unknown tool" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    cache_init
    mcp_server_add "mock" "bash $_MCP_MOCK_SCRIPT" "Mock"
    mcp_start "mock"
    mcp_tools_list "mock" > /dev/null
    mcp_find_tool "nonexistent_tool"
    assert_fail $?
    _mcp_test_teardown
    MCP_ENABLED=0
  }

# ── Default Catalog ────────────────────────────────────────────
describe "mcp_catalog_list"

  it "returns default catalog entries" && {
    _mcp_test_setup
    mcp_init
    catalog=$(mcp_catalog_list)
    assert_contains "$catalog" "fetch"
    assert_contains "$catalog" "puppeteer"
    assert_contains "$catalog" "brave-search"
    assert_contains "$catalog" "github"
    _mcp_test_teardown
  }

describe "mcp_catalog_install"

  it "installs a server from catalog" && {
    _mcp_test_setup
    mcp_init
    mcp_catalog_install "fetch"
    assert_ok $?
    _mcp_server_exists "fetch"
    assert_ok $? "fetch server should be registered"
    _mcp_test_teardown
  }

  it "fails for unknown catalog entry" && {
    _mcp_test_setup
    mcp_init
    err=$(mcp_catalog_install "nonexistent" 2>&1)
    assert_fail $?
    assert_contains "$err" "not found"
    _mcp_test_teardown
  }

# ── Agent Catalog ──────────────────────────────────────────────
describe "mcp_catalog (agent injection)"

  it "returns empty when MCP disabled" && {
    MCP_ENABLED=0
    mcp_catalog
    assert_fail $?
  }

  it "returns tool info when MCP enabled with servers" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    cache_init
    mcp_server_add "mock" "bash $_MCP_MOCK_SCRIPT" "Mock server"
    mcp_start "mock"
    mcp_tools_list "mock" > /dev/null
    catalog=$(mcp_catalog)
    assert_contains "$catalog" "MCP INTEGRATION"
    assert_contains "$catalog" "mock_fetch"
    assert_contains "$catalog" "mock_search"
    _mcp_test_teardown
    MCP_ENABLED=0
  }

# ── /mcp Command Menu ─────────────────────────────────────────
describe "mcp_command (menu)"

  it "shows status on empty args" && {
    _mcp_test_setup
    MCP_ENABLED=0
    mcp_init
    out=$(mcp_command "")
    assert_contains "$out" "DISABLED"
    _mcp_test_teardown
  }

  it "enables MCP with on" && {
    _mcp_test_setup
    MCP_ENABLED=0
    mcp_init
    mcp_command "on" > /dev/null
    assert_eq "$MCP_ENABLED" "1"
    MCP_ENABLED=0
    _mcp_test_teardown
  }

  it "disables MCP with off" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    mcp_command "off" > /dev/null
    assert_eq "$MCP_ENABLED" "0"
    _mcp_test_teardown
  }

  it "shows help on help" && {
    _mcp_test_setup
    mcp_init
    out=$(mcp_command "help")
    assert_contains "$out" "/mcp on"
    assert_contains "$out" "/mcp call"
    _mcp_test_teardown
  }

  it "lists servers on list" && {
    _mcp_test_setup
    mcp_init
    mcp_server_add "test-list" "echo x" "Listed"
    out=$(mcp_command "list")
    assert_contains "$out" "test-list"
    _mcp_test_teardown
  }

  it "shows catalog on catalog" && {
    _mcp_test_setup
    mcp_init
    out=$(mcp_command "catalog")
    assert_contains "$out" "fetch"
    assert_contains "$out" "puppeteer"
    _mcp_test_teardown
  }

  it "installs from catalog with install" && {
    _mcp_test_setup
    mcp_init
    mcp_command "install memory" > /dev/null
    _mcp_server_exists "memory"
    assert_ok $?
    _mcp_test_teardown
  }

# ── Dispatch Intercept ─────────────────────────────────────────
describe "_mcp_dispatch_intercept"

  it "returns failure when MCP disabled" && {
    MCP_ENABLED=0
    _mcp_dispatch_intercept "fetch" "test"
    assert_fail $?
  }

  it "returns failure when no servers running" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    _mcp_dispatch_intercept "fetch" "test"
    assert_fail $?
    MCP_ENABLED=0
    _mcp_test_teardown
  }

  it "intercepts matching tool name" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    cache_init
    mcp_server_add "mock" "bash $_MCP_MOCK_SCRIPT" "Mock"
    mcp_start "mock"
    mcp_tools_list "mock" > /dev/null
    result=$(_mcp_dispatch_intercept "mock_fetch" "test args")
    assert_ok $?
    assert_contains "$result" "Mock response"
    _mcp_test_teardown
    MCP_ENABLED=0
  }

  it "returns failure for non-matching command" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    cache_init
    mcp_server_add "mock" "bash $_MCP_MOCK_SCRIPT" "Mock"
    mcp_start "mock"
    mcp_tools_list "mock" > /dev/null
    _mcp_dispatch_intercept "nonexistent_command" "args"
    assert_fail $?
    _mcp_test_teardown
    MCP_ENABLED=0
  }

# ── Edge Cases ─────────────────────────────────────────────────
describe "edge cases"

  it "handles server name with hyphens and underscores" && {
    _mcp_test_setup
    mcp_init
    mcp_server_add "my-test_server-01" "echo test" "Hyphenated"
    _mcp_server_exists "my-test_server-01"
    assert_ok $?
    _mcp_test_teardown
  }

  it "multiple servers dont interfere" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "mock-a" "bash $_MCP_MOCK_SCRIPT" "A"
    mcp_server_add "mock-b" "bash $_MCP_MOCK_SCRIPT" "B"
    mcp_start "mock-a"
    mcp_start "mock-b"
    result_a=$(mcp_tool_call "mock-a" "mock_fetch" '{"url":"a.com"}')
    result_b=$(mcp_tool_call "mock-b" "mock_search" '{"query":"test"}')
    assert_contains "$result_a" "Mock response"
    assert_contains "$result_b" "Mock response"
    _mcp_test_teardown
    MCP_ENABLED=0
  }

  it "req_id counter survives subshell calls" && {
    _mcp_test_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "mock" "bash $_MCP_MOCK_SCRIPT" "Mock"
    mcp_start "mock"
    mcp_tool_call "mock" "mock_fetch" '{}' > /dev/null
    mcp_tool_call "mock" "mock_search" '{}' > /dev/null
    current_id=$(cat "$MCP_RUN_DIR/mock/req_id" 2>/dev/null)
    assert_gt "$current_id" "2"
    _mcp_test_teardown
    MCP_ENABLED=0
  }

test_end
