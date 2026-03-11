#!/bin/bash
# ── Tests: lib/mcp_server_git.sh ─────────────────────────────
# Tests the pure-bash MCP git server against the MCP protocol.
# Uses the actual server process (not mocks) for protocol compliance.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/cache.sh"
source "$LODGE_DIR/lib/mcp.sh"

test_start "lib/mcp_server_git.sh — Pure-Bash MCP Git Server"

# ── Helpers ────────────────────────────────────────────────────
_SERVER_CMD="bash $LODGE_DIR/lib/mcp_server_git.sh"
_TEST_DIR=""
_ORIG_DIR="$PWD"

_msg_setup() {
    _TEST_DIR=$(test_tmpdir)
    MCP_CONFIG_DIR="$_TEST_DIR/config"
    MCP_RUN_DIR="$_TEST_DIR/run"
    MCP_SERVERS_FILE="$MCP_CONFIG_DIR/servers.conf"
    MCP_CATALOG_FILE="$MCP_CONFIG_DIR/catalog.conf"
    CACHE_DIR="$_TEST_DIR/cache"
    MCP_TIMEOUT=15
    mkdir -p "$MCP_CONFIG_DIR" "$MCP_RUN_DIR"
    cache_init
    cd "$_ORIG_DIR"
}

_msg_teardown() {
    cd "$_ORIG_DIR"
    mcp_stop_all 2>/dev/null
    rm -rf "$_TEST_DIR" 2>/dev/null
}

# Send a single JSON-RPC message and get response
_msg_one_shot() {
    cd "$_ORIG_DIR" 2>/dev/null
    printf '%s\n' "$1" | bash "$LODGE_DIR/lib/mcp_server_git.sh" 2>/dev/null | head -1
}

# Send multiple messages (init + request) and get last response
_msg_call() {
    cd "$_ORIG_DIR" 2>/dev/null
    local init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
    local notif='{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
    printf '%s\n%s\n%s\n' "$init" "$notif" "$1" | bash "$LODGE_DIR/lib/mcp_server_git.sh" 2>/dev/null | tail -1
}

# Create a temporary git repo for testing — returns path, no CWD change
_msg_create_repo() {
    local repo_dir="$_TEST_DIR/test-repo"
    mkdir -p "$repo_dir"
    (
        cd "$repo_dir"
        git init -q
        git config user.name "Test"
        git config user.email "test@test.com"
        echo "hello" > README.md
        git add README.md
        git commit -q -m "Initial commit"
    )
    echo "$repo_dir"
}

# ── Protocol Compliance ───────────────────────────────────────
describe "MCP protocol compliance"

  it "responds to initialize with correct protocol version" && {
    resp=$(_msg_one_shot '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    proto=$(printf '%s' "$resp" | jq -r '.result.protocolVersion' 2>/dev/null)
    assert_eq "$proto" "2024-11-05"
  }

  it "includes server info in initialize response" && {
    resp=$(_msg_one_shot '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    name=$(printf '%s' "$resp" | jq -r '.result.serverInfo.name' 2>/dev/null)
    assert_eq "$name" "george-git"
  }

  it "advertises tools capability" && {
    resp=$(_msg_one_shot '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    has_tools=$(printf '%s' "$resp" | jq 'has("result") and (.result.capabilities | has("tools"))' 2>/dev/null)
    assert_eq "$has_tools" "true"
  }

  it "returns valid JSON-RPC 2.0 envelope" && {
    resp=$(_msg_one_shot '{"jsonrpc":"2.0","id":42,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    version=$(printf '%s' "$resp" | jq -r '.jsonrpc' 2>/dev/null)
    assert_eq "$version" "2.0"
    id_val=$(printf '%s' "$resp" | jq -r '.id' 2>/dev/null)
    assert_eq "$id_val" "42"
  }

  it "returns error for unknown method" && {
    resp=$(_msg_one_shot '{"jsonrpc":"2.0","id":1,"method":"bogus/method","params":{}}')
    err_code=$(printf '%s' "$resp" | jq -r '.error.code' 2>/dev/null)
    assert_eq "$err_code" "-32601"
  }

  it "silently handles notifications without response" && {
    resp=$(_msg_one_shot '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}')
    assert_empty "$resp" "notifications should produce no response"
  }

# ── tools/list ─────────────────────────────────────────────────
describe "tools/list"

  it "returns all 12 tools" && {
    resp=$(_msg_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    count=$(printf '%s' "$resp" | jq '.result.tools | length' 2>/dev/null)
    assert_eq "$count" "12"
  }

  it "includes git_status tool" && {
    resp=$(_msg_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    has=$(printf '%s' "$resp" | jq '[.result.tools[] | select(.name == "git_status")] | length' 2>/dev/null)
    assert_eq "$has" "1"
  }

  it "includes git_commit tool" && {
    resp=$(_msg_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    has=$(printf '%s' "$resp" | jq '[.result.tools[] | select(.name == "git_commit")] | length' 2>/dev/null)
    assert_eq "$has" "1"
  }

  it "includes github_search tool" && {
    resp=$(_msg_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    has=$(printf '%s' "$resp" | jq '[.result.tools[] | select(.name == "github_search")] | length' 2>/dev/null)
    assert_eq "$has" "1"
  }

  it "includes github_check tool" && {
    resp=$(_msg_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    has=$(printf '%s' "$resp" | jq '[.result.tools[] | select(.name == "github_check")] | length' 2>/dev/null)
    assert_eq "$has" "1"
  }

  it "includes git_clone tool" && {
    resp=$(_msg_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    has=$(printf '%s' "$resp" | jq '[.result.tools[] | select(.name == "git_clone")] | length' 2>/dev/null)
    assert_eq "$has" "1"
  }

  it "includes git_branch tool" && {
    resp=$(_msg_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    has=$(printf '%s' "$resp" | jq '[.result.tools[] | select(.name == "git_branch")] | length' 2>/dev/null)
    assert_eq "$has" "1"
  }

  it "includes git_setup_status tool" && {
    resp=$(_msg_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    has=$(printf '%s' "$resp" | jq '[.result.tools[] | select(.name == "git_setup_status")] | length' 2>/dev/null)
    assert_eq "$has" "1"
  }

  it "all tools have required inputSchema" && {
    resp=$(_msg_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    all_have=$(printf '%s' "$resp" | jq '[.result.tools[] | select(.inputSchema != null)] | length' 2>/dev/null)
    assert_eq "$all_have" "12" "all tools should have inputSchema"
  }

# ── tools/call — git_status ───────────────────────────────────
describe "tools/call — git_status"

  it "returns status for a git repo" && {
    _msg_setup
    repo_dir=$(_msg_create_repo)
    resp=$(_msg_call "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"git_status\",\"arguments\":{\"path\":\"$repo_dir\"}}}")
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Branch:"
    assert_contains "$text" "clean"
    _msg_teardown
  }

  it "shows modified files" && {
    _msg_setup
    repo_dir=$(_msg_create_repo)
    echo "changed" >> "$repo_dir/README.md"
    resp=$(_msg_call "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"git_status\",\"arguments\":{\"path\":\"$repo_dir\"}}}")
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "README.md"
    _msg_teardown
  }

  it "returns error for non-repo path" && {
    _msg_setup
    resp=$(_msg_call "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"git_status\",\"arguments\":{\"path\":\"$_TEST_DIR\"}}}")
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Error"
    _msg_teardown
  }

# ── tools/call — git_log ──────────────────────────────────────
describe "tools/call — git_log"

  it "returns commit history" && {
    _msg_setup
    repo_dir=$(_msg_create_repo)
    resp=$(_msg_call "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"git_log\",\"arguments\":{\"path\":\"$repo_dir\"}}}")
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Initial commit"
    _msg_teardown
  }

  it "respects count parameter" && {
    _msg_setup
    repo_dir=$(_msg_create_repo)
    (cd "$repo_dir" && echo "two" > file2.txt && git add file2.txt && git commit -q -m "Second commit")
    (cd "$repo_dir" && echo "three" > file3.txt && git add file3.txt && git commit -q -m "Third commit")
    resp=$(_msg_call "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"git_log\",\"arguments\":{\"path\":\"$repo_dir\",\"count\":1}}}")
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Third commit"
    line_count=$(printf '%s\n' "$text" | wc -l)
    assert_eq "$line_count" "1"
    _msg_teardown
  }

  it "supports oneline format" && {
    _msg_setup
    repo_dir=$(_msg_create_repo)
    resp=$(_msg_call "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"git_log\",\"arguments\":{\"path\":\"$repo_dir\",\"oneline\":true}}}")
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Initial commit"
    _msg_teardown
  }

# ── tools/call — git_diff ─────────────────────────────────────
describe "tools/call — git_diff"

  it "shows diff of working tree" && {
    _msg_setup
    repo_dir=$(_msg_create_repo)
    echo "new content" >> "$repo_dir/README.md"
    resp=$(_msg_call "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"git_diff\",\"arguments\":{\"path\":\"$repo_dir\"}}}")
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "new content"
    _msg_teardown
  }

  it "shows staged diff" && {
    _msg_setup
    repo_dir=$(_msg_create_repo)
    echo "staged change" >> "$repo_dir/README.md"
    (cd "$repo_dir" && git add README.md)
    resp=$(_msg_call "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"git_diff\",\"arguments\":{\"path\":\"$repo_dir\",\"staged\":true}}}")
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "staged change"
    _msg_teardown
  }

  it "returns no-diff message when clean" && {
    _msg_setup
    repo_dir=$(_msg_create_repo)
    resp=$(_msg_call "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"git_diff\",\"arguments\":{\"path\":\"$repo_dir\"}}}")
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "No differences"
    _msg_teardown
  }

  it "supports stat_only mode" && {
    _msg_setup
    repo_dir=$(_msg_create_repo)
    echo "stat change" >> "$repo_dir/README.md"
    resp=$(_msg_call "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"git_diff\",\"arguments\":{\"path\":\"$repo_dir\",\"stat_only\":true}}}")
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "README.md"
    _msg_teardown
  }

# ── tools/call — git_commit ───────────────────────────────────
describe "tools/call — git_commit"

  it "commits all changes with message" && {
    _msg_setup
    repo_dir=$(_msg_create_repo)
    echo "new file" > "$repo_dir/new.txt"
    resp=$(_msg_call "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"tools/call\",\"params\":{\"name\":\"git_commit\",\"arguments\":{\"path\":\"$repo_dir\",\"message\":\"Add new file\"}}}")
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Add new file"
    # Verify commit exists
    last_msg=$(cd "$repo_dir" && git log --oneline -1 2>/dev/null)
    assert_contains "$last_msg" "Add new file"
    _msg_teardown
  }

  it "commits specific files" && {
    _msg_setup
    repo_dir=$(_msg_create_repo)
    echo "a" > "$repo_dir/a.txt"
    echo "b" > "$repo_dir/b.txt"
    resp=$(_msg_call "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"tools/call\",\"params\":{\"name\":\"git_commit\",\"arguments\":{\"path\":\"$repo_dir\",\"message\":\"Add a only\",\"files\":\"a.txt\"}}}")
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Add a only"
    # b.txt should still be untracked
    bstatus=$(cd "$repo_dir" && git status --short)
    assert_contains "$bstatus" "b.txt"
    _msg_teardown
  }

  it "requires message parameter" && {
    _msg_setup
    repo_dir=$(_msg_create_repo)
    resp=$(_msg_call "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"tools/call\",\"params\":{\"name\":\"git_commit\",\"arguments\":{\"path\":\"$repo_dir\"}}}")
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Error"
    _msg_teardown
  }

# ── tools/call — git_branch ───────────────────────────────────
describe "tools/call — git_branch"

  it "lists branches" && {
    _msg_setup
    repo_dir=$(_msg_create_repo)
    resp=$(_msg_call "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"tools/call\",\"params\":{\"name\":\"git_branch\",\"arguments\":{\"path\":\"$repo_dir\"}}}")
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_not_empty "$text" "should list branches"
    _msg_teardown
  }

  it "creates a new branch" && {
    _msg_setup
    repo_dir=$(_msg_create_repo)
    resp=$(_msg_call "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"tools/call\",\"params\":{\"name\":\"git_branch\",\"arguments\":{\"path\":\"$repo_dir\",\"action\":\"create\",\"name\":\"feature/test\"}}}")
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "feature/test"
    _msg_teardown
  }

  it "switches branch" && {
    _msg_setup
    repo_dir=$(_msg_create_repo)
    (cd "$repo_dir" && git checkout -b other-branch -q && git checkout - -q)
    resp=$(_msg_call "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"tools/call\",\"params\":{\"name\":\"git_branch\",\"arguments\":{\"path\":\"$repo_dir\",\"action\":\"switch\",\"name\":\"other-branch\"}}}")
    branch=$(cd "$repo_dir" && git branch --show-current)
    assert_eq "$branch" "other-branch"
    _msg_teardown
  }

  it "requires name for create" && {
    _msg_setup
    repo_dir=$(_msg_create_repo)
    resp=$(_msg_call "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"tools/call\",\"params\":{\"name\":\"git_branch\",\"arguments\":{\"path\":\"$repo_dir\",\"action\":\"create\"}}}")
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Error"
    _msg_teardown
  }

# ── tools/call — git_remote ───────────────────────────────────
describe "tools/call — git_remote"

  it "lists remotes (empty for new repo)" && {
    _msg_setup
    repo_dir=$(_msg_create_repo)
    resp=$(_msg_call "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"tools/call\",\"params\":{\"name\":\"git_remote\",\"arguments\":{\"path\":\"$repo_dir\"}}}")
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "No remotes"
    _msg_teardown
  }

  it "adds a remote" && {
    _msg_setup
    repo_dir=$(_msg_create_repo)
    resp=$(_msg_call "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"tools/call\",\"params\":{\"name\":\"git_remote\",\"arguments\":{\"path\":\"$repo_dir\",\"action\":\"add\",\"name\":\"origin\",\"url\":\"https://github.com/test/repo.git\"}}}")
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "origin"
    remote_url=$(cd "$repo_dir" && git remote get-url origin 2>/dev/null)
    assert_eq "$remote_url" "https://github.com/test/repo.git"
    _msg_teardown
  }

  it "requires url for add" && {
    _msg_setup
    repo_dir=$(_msg_create_repo)
    resp=$(_msg_call "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"tools/call\",\"params\":{\"name\":\"git_remote\",\"arguments\":{\"path\":\"$repo_dir\",\"action\":\"add\",\"name\":\"origin\"}}}")
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Error"
    _msg_teardown
  }

# ── tools/call — git_clone ────────────────────────────────────
describe "tools/call — git_clone"

  it "requires url parameter" && {
    resp=$(_msg_call '{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"git_clone","arguments":{}}}')
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Error"
  }

  it "expands owner/repo shorthand" && {
    _msg_setup
    # Clone will fail for nonexistent repo but the error should show expanded URL
    resp=$(_msg_call '{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"git_clone","arguments":{"url":"nonexistent/repo-xyz-12345"}}}')
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "github.com"
    _msg_teardown
  }

# ── tools/call — github_search ────────────────────────────────
describe "tools/call — github_search"

  it "requires query parameter" && {
    resp=$(_msg_call '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"github_search","arguments":{}}}')
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Error"
  }

# ── tools/call — github_check ─────────────────────────────────
describe "tools/call — github_check"

  it "requires repo parameter" && {
    resp=$(_msg_call '{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"github_check","arguments":{}}}')
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Error"
  }

# ── tools/call — git_setup_status ─────────────────────────────
describe "tools/call — git_setup_status"

  it "returns setup status" && {
    resp=$(_msg_call '{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"git_setup_status","arguments":{}}}')
    text=$(printf '%s' "$resp" | jq -r '.result.content[0].text' 2>/dev/null)
    assert_contains "$text" "Identity:"
  }

# ── Unknown tool ───────────────────────────────────────────────
describe "tools/call — error handling"

  it "returns error for unknown tool" && {
    resp=$(_msg_call '{"jsonrpc":"2.0","id":99,"method":"tools/call","params":{"name":"nonexistent","arguments":{}}}')
    err=$(printf '%s' "$resp" | jq -r '.error.message' 2>/dev/null)
    assert_contains "$err" "Unknown tool"
  }

# ── Integration with MCP client ────────────────────────────────
describe "integration with George MCP client"

  it "starts via mcp_start and completes handshake" && {
    _msg_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "george-git" "$_SERVER_CMD" "George built-in git"
    mcp_start "george-git"
    assert_ok $?
    assert_file_exists "$MCP_RUN_DIR/george-git/ready"
    _msg_teardown
    MCP_ENABLED=0
  }

  it "lists tools via mcp_tools_list" && {
    _msg_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "george-git" "$_SERVER_CMD" "George built-in git"
    mcp_start "george-git"
    tools=$(mcp_tools_list "george-git")
    count=$(printf '%s' "$tools" | jq 'length' 2>/dev/null)
    assert_eq "$count" "12" "should have 12 tools"
    _msg_teardown
    MCP_ENABLED=0
  }

  it "calls git_status via mcp_tool_call" && {
    _msg_setup
    MCP_ENABLED=1
    mcp_init
    mcp_server_add "george-git" "$_SERVER_CMD" "George built-in git"
    mcp_start "george-git"
    result=$(mcp_tool_call "george-git" "git_status" '{}')
    assert_contains "$result" "Branch:"
    _msg_teardown
    MCP_ENABLED=0
  }

test_end
