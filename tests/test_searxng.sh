#!/bin/bash
# ── Tests: SearXNG Sovereign Metasearch, MCP Server & Reverse Visual Search ──
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh"
source "$LODGE_DIR/lib/sys/cache.sh"
source "$LODGE_DIR/lib/tools/mcp.sh"
source "$LODGE_DIR/lib/comms/web.sh"
source "$LODGE_DIR/lib/tools/native_tools.sh"

test_start "SearXNG Sovereign Metasearch, MCP Server & Reverse Visual Search Pipeline"

# ── 1. SearXNG Backend Health Probe ───────────────────────────
describe "SearXNG container and backend connectivity"

  it "probes SearXNG service endpoint on port 8081" && {
    _py_bin="python3"
    [ -x "$LODGE_DIR/.venv/bin/python" ] && _py_bin="$LODGE_DIR/.venv/bin/python"
    _status=$("$_py_bin" -c "
from lib.tools.searxng_backend import check_searxng_health
res = check_searxng_health()
print(res.get('status', 'unknown'))
" 2>/dev/null)
    assert_eq "$_status" "healthy" "SearXNG backend check_searxng_health() status must be healthy"
  }

# ── 2. SearXNG Specialized Search Capabilities ────────────────
describe "SearXNG Python Backend Specialized Search Methods"

  it "retrieves structured results for sovereign general search query" && {
    _py_bin="python3"
    [ -x "$LODGE_DIR/.venv/bin/python" ] && _py_bin="$LODGE_DIR/.venv/bin/python"
    _count=$("$_py_bin" -c "
from lib.tools.searxng_backend import search_searxng
hits = search_searxng('Linux kernel architecture', max_results=3)
print(len(hits))
" 2>/dev/null)
    [ -n "$_count" ] && [ "$_count" -ge 1 ]
    assert_ok $? "SearXNG must return at least 1 valid result for general query"
  }

  it "executes search_code across IT engines" && {
    _py_bin="python3"
    [ -x "$LODGE_DIR/.venv/bin/python" ] && _py_bin="$LODGE_DIR/.venv/bin/python"
    _count=$("$_py_bin" -c "
from lib.tools.searxng_backend import search_code
hits = search_code('tokio async rust', max_results=3)
print(len(hits))
" 2>/dev/null)
    [ -n "$_count" ] && [ "$_count" -ge 1 ]
    assert_ok $? "search_code must return at least 1 IT/code result"
  }

  it "executes search_science across academic engines" && {
    _py_bin="python3"
    [ -x "$LODGE_DIR/.venv/bin/python" ] && _py_bin="$LODGE_DIR/.venv/bin/python"
    _count=$("$_py_bin" -c "
from lib.tools.searxng_backend import search_science
hits = search_science('quantum computing entanglement', max_results=3)
print(len(hits))
" 2>/dev/null)
    [ -n "$_count" ] && [ "$_count" -ge 1 ]
    assert_ok $? "search_science must return at least 1 academic paper result"
  }

  it "introspects available engines via get_available_engines" && {
    _py_bin="python3"
    [ -x "$LODGE_DIR/.venv/bin/python" ] && _py_bin="$LODGE_DIR/.venv/bin/python"
    _engine_count=$("$_py_bin" -c "
from lib.tools.searxng_backend import get_available_engines
data = get_available_engines()
print(len(data))
" 2>/dev/null)
    [ -n "$_engine_count" ] && [ "$_engine_count" -ge 5 ]
    assert_ok $? "get_available_engines must discover configured search engines"
  }

# ── 3. SearXNG MCP Server JSON-RPC Protocol ───────────────────
describe "SearXNG MCP Server JSON-RPC 2.0 interface"

  it "responds to tools/list advertising all 8 registered tools" && {
    _req='{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
    _resp=$(echo "$_req" | bash "$LODGE_DIR/lib/tools/mcp_server_searxng.sh" 2>/dev/null)
    _tools=$(echo "$_resp" | jq -r '.result.tools[].name' 2>/dev/null)
    echo "$_tools" | grep -qx "searxng_search" && \
    echo "$_tools" | grep -qx "searxng_code_search" && \
    echo "$_tools" | grep -qx "searxng_science_search" && \
    echo "$_tools" | grep -qx "searxng_news_search" && \
    echo "$_tools" | grep -qx "searxng_images" && \
    echo "$_tools" | grep -qx "searxng_rss" && \
    echo "$_tools" | grep -qx "searxng_engines" && \
    echo "$_tools" | grep -qx "searxng_health"
    assert_ok $? "MCP tools/list must advertise all 8 SearXNG tools"
  }

  it "executes tools/call for searxng_health successfully" && {
    _req='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"searxng_health","arguments":{}}}'
    _resp=$(echo "$_req" | bash "$LODGE_DIR/lib/tools/mcp_server_searxng.sh" 2>/dev/null)
    assert_contains "$_resp" "healthy" "searxng_health tool call must return status: healthy"
  }

  it "executes tools/call for searxng_code_search successfully" && {
    _req='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"searxng_code_search","arguments":{"query":"epoll socket linux","max_results":2}}}'
    _resp=$(echo "$_req" | bash "$LODGE_DIR/lib/tools/mcp_server_searxng.sh" 2>/dev/null)
    assert_contains "$_resp" "result" "searxng_code_search must return a valid JSON-RPC result"
  }

# ── 4. Slash Command (/searxng) & Native Dispatch ─────────────
describe "POSIX slash command /searxng and native tool dispatch"

  it "executes /searxng status via commands/searxng.sh" && {
    _out=$(bash "$LODGE_DIR/commands/searxng.sh" status 2>/dev/null)
    assert_contains "$_out" "running" "/searxng status must report container is running"
  }

  it "dispatches searxng_code_search via native_tools_dispatch" && {
    _args='{"query":"linux epoll kqueue","max_results":2}'
    _out=$(native_tools_dispatch "call_test_1" "searxng_code_search" "$_args" 2>/dev/null)
    assert_contains "$_out" "tool_call_id" "native_tools_dispatch must return valid tool response structure"
  }

  it "dispatches searxng_science_search via native_tools_dispatch" && {
    _args='{"query":"attention is all you need","max_results":2}'
    _out=$(native_tools_dispatch "call_test_2" "searxng_science_search" "$_args" 2>/dev/null)
    assert_contains "$_out" "tool_call_id" "native_tools_dispatch must return valid tool response structure"
  }

# ── 5. Default Routing & Fallback in web_search ────────────────
describe "Default SearXNG routing and fallback cascade in web_search"

  it "detects SearXNG availability via _web_searxng_is_available" && {
    _web_searxng_is_available
    assert_ok $? "_web_searxng_is_available must return 0 when SearXNG is running"
  }

  it "routes web_search through SearXNG by default" && {
    _res=$(web_search "gnu coreutils awk" 2 2>/dev/null)
    assert_contains "$_res" "[1]" "web_search must return numbered search hits"
  }

  it "falls back gracefully when SearXNG is offline (simulated)" && {
    USE_SEARXNG=0
    _AGENT_WEB_LOCKED=1
    _ddg_res=$(web_search "posix shell standards" 1 2>/dev/null)
    _rc=$?
    USE_SEARXNG=1
    _AGENT_WEB_LOCKED=0
    # Even if DDG is rate-limited or locked, function returns integer exit code without fatal error
    [ "$_rc" -eq 0 ] || [ "$_rc" -eq 1 ]
    assert_ok $? "web_search must handle fallback without fatal crash"
  }

# ── 6. Filename Query Sanitization & Anti-Pollution ───────────
describe "Visual Search anti-pollution and query sanitization"

  it "discards raw filenames and extensions from search queries" && {
    _py_bin="python3"
    [ -x "$LODGE_DIR/.venv/bin/python" ] && _py_bin="$LODGE_DIR/.venv/bin/python"
    _clean_res=$("$_py_bin" -c "
from lib.tools.reverse_image_search import _sanitize_query_hint
print('1:' + str(_sanitize_query_hint('Hoogs', 'data/assets/Hoogs.png')))
print('2:' + str(_sanitize_query_hint('Hoogs.png', 'data/assets/Hoogs.png')))
print('3:' + str(_sanitize_query_hint('STM32 pinout', 'data/assets/Hoogs.png')))
" 2>/dev/null)
    _line1=$(echo "$_clean_res" | grep '^1:' | cut -d: -f2)
    _line2=$(echo "$_clean_res" | grep '^2:' | cut -d: -f2)
    _line3=$(echo "$_clean_res" | grep '^3:' | cut -d: -f2)
    assert_eq "$_line1" "None" "Filename stem 'Hoogs' must be sanitized to None"
    assert_eq "$_line2" "None" "Filename 'Hoogs.png' must be sanitized to None"
    assert_eq "$_line3" "STM32 pinout" "Legitimate technical hint must be preserved"
  }

test_end
