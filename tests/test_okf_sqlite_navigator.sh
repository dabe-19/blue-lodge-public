#!/bin/bash
# ── Test Suite: OKF Dynamic Codebase Graph & SQLite FTS5 BM25 Navigator ──────

source "$(dirname "$0")/framework.sh"
LODGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

test_start "OKF Codebase Graph, AST File Explorer & SQLite BM25 Navigator"

describe "1. Python OKF SQLite Indexer CLI & Database Schema"
  it "indexes OKF graph into .george/recall.db" && {
    out=$(python3 "$LODGE_DIR/lib/tools/okf_sqlite_indexer.py" --index 2>&1)
    assert_ok $?
    assert_contains "$out" "[OKF INDEXER] Indexed"
    assert_contains "$out" "symbols"
  }

  it "returns valid stats via --stats CLI" && {
    out=$(python3 "$LODGE_DIR/lib/tools/okf_sqlite_indexer.py" --stats --json 2>&1)
    assert_ok $?
    total=$(echo "$out" | jq '.total_modules // 0')
    [ "$total" -gt 300 ] || _test_fail "check failed at line $LINENO"
    subs=$(echo "$out" | jq '(.subsystem_breakdown | length) // 0')
    [ "$subs" -ge 10 ] || assert_fail 2
  }

  it "executes CLI FTS5 BM25 search for 'fifo'" && {
    out=$(python3 "$LODGE_DIR/lib/tools/okf_sqlite_indexer.py" --search "fifo" 2>&1)
    assert_ok $?
    assert_contains "$out" "fifo_ipc.sh"
    assert_contains "$out" "Asynchronous FIFO IPC"
  }

  it "executes CLI FTS5 BM25 search with subsystem filter" && {
    out=$(python3 "$LODGE_DIR/lib/tools/okf_sqlite_indexer.py" --search "router" --subsystem "tools" 2>&1)
    assert_ok $?
    assert_contains "$out" "event_router.sh"
  }

describe "2. Backend File Hierarchy Scanner (/api/files/list)"
  it "scans all refactored subdirectories recursively" && {
    resp=$(curl -s "http://127.0.0.1:3000/api/files/list")
    assert_ok $?
    count=$(echo "$resp" | jq '.total_files // 0')
    [ "$count" -gt 500 ] || _test_fail "check failed at line $LINENO"
  }

  it "returns lib subdirectories including lib/ipc, lib/tools, lib/core" && {
    resp=$(curl -s "http://127.0.0.1:3000/api/files/list")
    assert_ok $?
    echo "$resp" | jq -e '.files[] | select(.path == "lib/ipc/fifo_ipc.sh")' >/dev/null || _test_fail "check failed at line $LINENO"
    echo "$resp" | jq -e '.files[] | select(.path == "lib/tools/event_router.sh")' >/dev/null || assert_fail 2
    echo "$resp" | jq -e '.files[] | select(.path == "lib/core/banner.sh")' >/dev/null || assert_fail 3
  }

  it "includes AST exports count and categories in file metadata" && {
    resp=$(curl -s "http://127.0.0.1:3000/api/files/list")
    assert_ok $?
    cat=$(echo "$resp" | jq -r '.files[] | select(.path == "lib/ipc/fifo_ipc.sh") | .category')
    [ -n "$cat" ] && [ "$cat" != "null" ] || _test_fail "check failed at line $LINENO"
    exp_count=$(echo "$resp" | jq -r '.files[] | select(.path == "lib/ipc/fifo_ipc.sh") | .exports_count')
    [ "$exp_count" -gt 0 ] || assert_fail 2
  }

  it "provides hierarchical directory tree object" && {
    resp=$(curl -s "http://127.0.0.1:3000/api/files/list")
    assert_ok $?
    tree_type=$(echo "$resp" | jq -r '.tree.type')
    [ "$tree_type" = "directory" ] || _test_fail "check failed at line $LINENO"
    echo "$resp" | jq -e '.tree.children[] | select(.name == "lib")' >/dev/null || assert_fail 2
  }

describe "3. OKF Graph and BM25 Endpoints (/api/okf/*)"
  it "serves OKF JSON-LD graph via /api/okf/graph" && {
    resp=$(curl -s "http://127.0.0.1:3000/api/okf/graph")
    assert_ok $?
    status=$(echo "$resp" | jq -r '.status')
    [ "$status" = "ok" ] || _test_fail "check failed at line $LINENO"
    nodes=$(echo "$resp" | jq '.nodes_count // 0')
    [ "$nodes" -gt 300 ] || assert_fail 2
  }

  it "performs BM25 search via /api/okf/search?q=fifo" && {
    resp=$(curl -s "http://127.0.0.1:3000/api/okf/search?q=fifo")
    assert_ok $?
    hit=$(echo "$resp" | jq -r '.results[0].name')
    [ "$hit" = "fifo_ipc.sh" ] || _test_fail "check failed at line $LINENO"
    score=$(echo "$resp" | jq -r '.results[0].bm25_score')
    [ -n "$score" ] && [ "$score" != "null" ] || assert_fail 2
  }

  it "filters by subsystem via /api/okf/search?subsystem=tools" && {
    resp=$(curl -s "http://127.0.0.1:3000/api/okf/search?subsystem=tools&limit=20")
    assert_ok $?
    # every hit must belong to the requested subsystem (result ranking is data-dependent)
    echo "$resp" | jq -e '(.results | length) > 0 and all(.results[]; (.subsystem // .subsystem_name // "") | test("tools"))' >/dev/null || _test_fail "subsystem filter returned foreign or no results"
  }

  it "triggers reindexing via POST /api/okf/reindex" && {
    resp=$(curl -s -X POST "http://127.0.0.1:3000/api/okf/reindex")
    assert_ok $?
    st=$(echo "$resp" | jq -r '.status')
    [ "$st" = "ok" ] || _test_fail "check failed at line $LINENO"
    idx=$(echo "$resp" | jq -r '.result.indexed_modules // 0')
    [ "$idx" -gt 300 ] || assert_fail 2
  }

describe "4. SQLite Query Studio OKF Database Integration"
  it "supports direct SQL queries against okf_modules" && {
    resp=$(curl -s "http://127.0.0.1:3000/api/sqlite/query" \
      -H "Content-Type: application/json" \
      -d '{"query":"SELECT count(*) as total FROM okf_modules","db":"okf"}')
    assert_ok $?
    total=$(echo "$resp" | jq -r '.rows[0].total // 0')
    [ "$total" -gt 300 ] || _test_fail "check failed at line $LINENO"
  }

  it "supports BM25 keyword search against okf_modules_fts" && {
    resp=$(curl -s "http://127.0.0.1:3000/api/sqlite/query" \
      -H "Content-Type: application/json" \
      -d '{"search":"searxng","db":"okf"}')
    assert_ok $?
    cnt=$(echo "$resp" | jq '(.rows | length) // 0')
    [ "$cnt" -gt 0 ] || _test_fail "check failed at line $LINENO"
  }

describe "5. Workbench UI Structure & File Explorer Assets"
  it "includes OKF navigator tab and subpane in index.html" && {
    grep -q 'data-sub="okf"' "$LODGE_DIR/web/static/index.html" || _test_fail "OKF chronicle tab button missing"
    grep -q 'id="subpane-okf"' "$LODGE_DIR/web/static/index.html" || assert_fail 2
    grep -q 'id="okfBm25SearchInput"' "$LODGE_DIR/web/static/index.html" || assert_fail 3
    grep -q 'id="okfModuleList"' "$LODGE_DIR/web/static/index.html" || assert_fail 4
  }

  it "includes sidebar mode switchers in index.html" && {
    grep -q 'id="btnSidebarModeCat"' "$LODGE_DIR/web/static/index.html" || _test_fail "check failed at line $LINENO"
    grep -q 'id="btnSidebarModeTree"' "$LODGE_DIR/web/static/index.html" || assert_fail 2
  }

  it "includes OKF navigator controller and openVimFile in app.js" && {
    grep -q 'loadOkfNavigator' "$LODGE_DIR/web/static/app.js" || _test_fail "check failed at line $LINENO"
    grep -q 'window.openVimFile' "$LODGE_DIR/web/static/app.js" || assert_fail 2
    grep -q 'renderTreeNode' "$LODGE_DIR/web/static/app.js" || assert_fail 3
  }

  it "includes sidebar tree and OKF navigator CSS in app.css" && {
    grep -q '\.sidebar-mode-switcher' "$LODGE_DIR/web/static/app.css" || _test_fail "check failed at line $LINENO"
    grep -q '\.sidebar-tree-folder' "$LODGE_DIR/web/static/app.css" || assert_fail 2
    grep -q '\.okf-module-card' "$LODGE_DIR/web/static/app.css" || assert_fail 3
    grep -q '\.okf-badge-score' "$LODGE_DIR/web/static/app.css" || assert_fail 4
  }

test_end
