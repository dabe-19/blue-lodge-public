#!/bin/bash
# ── Tests for lib/react.sh Pseudo-LRU Tool Cache Integration ─────────

source "$(dirname "$0")/framework.sh"
source "$(dirname "$0")/../lib/cache.sh"
source "$(dirname "$0")/../lib/react.sh"

test_start "lib/react.sh — ReAct Pseudo-LRU Tool Cache Integration"

describe "_react_tool_is_cacheable"
  it "recognizes deterministic read tools as cacheable" && {
    _react_tool_is_cacheable "web_search"
    assert_eq "$?" "0"
    _react_tool_is_cacheable "web_fetch"
    assert_eq "$?" "0"
    _react_tool_is_cacheable "file_read"
    assert_eq "$?" "0"
    _react_tool_is_cacheable "pdf_read"
    assert_eq "$?" "0"
    _react_tool_is_cacheable "code_symbol_get"
    assert_eq "$?" "0"
    _react_tool_is_cacheable "code_outline"
    assert_eq "$?" "0"
    _react_tool_is_cacheable "recall"
    assert_eq "$?" "0"
  }

  it "recognizes mutating or non-deterministic tools as not cacheable" && {
    ! _react_tool_is_cacheable "file_write"
    ! _react_tool_is_cacheable "file_edit"
    ! _react_tool_is_cacheable "git_commit"
    ! _react_tool_is_cacheable "bash_exec"
  }

describe "_react_tool_cache_ns"
  it "maps tools to their correct namespaces" && {
    assert_eq "$(_react_tool_cache_ns 'web_search')" "web"
    assert_eq "$(_react_tool_cache_ns 'web_fetch')" "web"
    assert_eq "$(_react_tool_cache_ns 'pdf_read')" "web"
    assert_eq "$(_react_tool_cache_ns 'file_read')" "files"
    assert_eq "$(_react_tool_cache_ns 'code_symbol_get')" "files"
    assert_eq "$(_react_tool_cache_ns 'code_outline')" "files"
    assert_eq "$(_react_tool_cache_ns 'recall')" "recall"
    assert_eq "$(_react_tool_cache_ns 'unknown_tool')" "default"
  }

describe "_react_tool_is_mutating"
  it "identifies direct file and git mutation tools" && {
    _react_tool_is_mutating "file_write" '{}'
    assert_eq "$?" "0"
    _react_tool_is_mutating "file_edit" '{}'
    assert_eq "$?" "0"
    _react_tool_is_mutating "symbol_patch" '{}'
    assert_eq "$?" "0"
    _react_tool_is_mutating "git_commit" '{}'
    assert_eq "$?" "0"
  }

  it "detects mutating commands inside bash_exec" && {
    _react_tool_is_mutating "bash_exec" '{"command":"sed -i s/foo/bar/g file.txt"}'
    assert_eq "$?" "0"
    _react_tool_is_mutating "bash_exec" '{"command":"rm -rf temp/"}'
    assert_eq "$?" "0"
    _react_tool_is_mutating "bash_exec" '{"command":"git checkout -b feature/new"}'
    assert_eq "$?" "0"
    _react_tool_is_mutating "bash_exec" '{"command":"touch newfile.sh"}'
    assert_eq "$?" "0"
  }

  it "does not flag read-only commands inside bash_exec as mutating" && {
    ! _react_tool_is_mutating "bash_exec" '{"command":"ls -la"}'
    ! _react_tool_is_mutating "bash_exec" '{"command":"cat README.md"}'
    ! _react_tool_is_mutating "bash_exec" '{"command":"grep -r pattern ."}'
  }

describe "Cache storage and O(1) namespace invalidation"
  it "stores tool observations and allows retrieval" && {
    tmp_c_dir=$(mktemp -d)
    export CACHE_DIR="$tmp_c_dir"
    cache_init

    h=$(_react_action_hash "file_read" '{"path":"lib/foo.sh"}')
    k="tool:file_read:$h"
    ns=$(_react_tool_cache_ns "file_read")
    obs_content="echo 'hello world'"

    cache_put "$k" "$ns" "$obs_content"
    got=$(cache_get "$k" "$ns")
    assert_eq "$got" "$obs_content"

    rm -rf "$tmp_c_dir"
  }

  it "invalidates file tool cache on mutating actions while preserving web cache" && {
    tmp_c_dir=$(mktemp -d)
    export CACHE_DIR="$tmp_c_dir"
    cache_init

    # Store file observation
    fh=$(_react_action_hash "file_read" '{"path":"lib/bar.sh"}')
    fk="tool:file_read:$fh"
    cache_put "$fk" "files" "file contents"

    # Store web observation
    wh=$(_react_action_hash "web_search" '{"query":"posix"}' )
    wk="tool:web_search:$wh"
    cache_put "$wk" "web" "web results"

    # Verify both exist
    assert_eq "$(cache_get "$fk" "files")" "file contents"
    assert_eq "$(cache_get "$wk" "web")" "web results"

    # Mutate file namespace
    cache_invalidate_ns "files"

    # File cache must now be a miss (exit 1), web cache must still hit
    ! cache_get "$fk" "files" >/dev/null 2>&1
    assert_eq "$(cache_get "$wk" "web")" "web results"

    rm -rf "$tmp_c_dir"
  }

test_end
