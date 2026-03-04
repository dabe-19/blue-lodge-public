#!/bin/bash
# ── Tests: /ls command (file tree listing) ─────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/commands.sh"

# Source the lodge file to get _cmd_ls
# We need the function definition — extract it by sourcing the main script
# functions without running the REPL.
# Instead, define a minimal shim that sources just what we need.
_LODGE_TESTING=1
export _LODGE_TESTING

# Source _cmd_ls directly from lodge (it's defined as a function)
eval "$(sed -n '/^_cmd_ls()/,/^_cmd_files()/{ /^_cmd_files()/d; p; }' "$LODGE_DIR/lodge")"
eval "$(sed -n '/^_cmd_files()/,/^}/p' "$LODGE_DIR/lodge")"

test_start "/ls — File Tree Listing"

TMPDIR_LS=""

_setup_ls() {
    TMPDIR_LS=$(test_tmpdir)
    # Build a realistic project structure
    mkdir -p "$TMPDIR_LS/src/api/handlers"
    mkdir -p "$TMPDIR_LS/src/db/migrations"
    mkdir -p "$TMPDIR_LS/tests"
    mkdir -p "$TMPDIR_LS/docs"
    mkdir -p "$TMPDIR_LS/.git/objects"          # should be excluded
    mkdir -p "$TMPDIR_LS/target/debug"           # should be excluded
    mkdir -p "$TMPDIR_LS/node_modules/foo"       # should be excluded
    mkdir -p "$TMPDIR_LS/__pycache__"            # should be excluded

    touch "$TMPDIR_LS/Cargo.toml"
    touch "$TMPDIR_LS/README.md"
    touch "$TMPDIR_LS/src/main.rs"
    touch "$TMPDIR_LS/src/lib.rs"
    touch "$TMPDIR_LS/src/api/mod.rs"
    touch "$TMPDIR_LS/src/api/routes.rs"
    touch "$TMPDIR_LS/src/api/handlers/auth.rs"
    touch "$TMPDIR_LS/src/api/handlers/users.rs"
    touch "$TMPDIR_LS/src/db/mod.rs"
    touch "$TMPDIR_LS/src/db/migrations/001_init.sql"
    touch "$TMPDIR_LS/tests/integration.rs"
    touch "$TMPDIR_LS/docs/SETUP.md"
    touch "$TMPDIR_LS/.git/config"
    touch "$TMPDIR_LS/target/debug/binary"
    touch "$TMPDIR_LS/node_modules/foo/index.js"
    touch "$TMPDIR_LS/__pycache__/cache.pyc"
}

_teardown_ls() {
    rm -rf "$TMPDIR_LS"
}

# ── Basic listing ──────────────────────────────────────────────
describe "_cmd_ls basic"

  it "lists files in a directory" && {
    _setup_ls
    out=$(_cmd_ls "" "$TMPDIR_LS" 2>&1)
    assert_contains "$out" "Cargo.toml"
    assert_contains "$out" "README.md"
    _teardown_ls
  }

  it "shows directories with trailing slash" && {
    _setup_ls
    out=$(_cmd_ls "" "$TMPDIR_LS" 2>&1)
    assert_contains "$out" "src/"
    assert_contains "$out" "tests/"
    _teardown_ls
  }

  it "shows nested files at depth 3" && {
    _setup_ls
    out=$(_cmd_ls "" "$TMPDIR_LS" 2>&1)
    # depth 3 should reach src/api/mod.rs
    assert_contains "$out" "mod.rs"
    assert_contains "$out" "routes.rs"
    _teardown_ls
  }

# ── Exclusions ─────────────────────────────────────────────────
describe "_cmd_ls exclusions"

  it "excludes .git directory" && {
    _setup_ls
    out=$(_cmd_ls "" "$TMPDIR_LS" 2>&1)
    assert_not_contains "$out" ".git/"
    assert_not_contains "$out" "objects"
    _teardown_ls
  }

  it "excludes target directory" && {
    _setup_ls
    out=$(_cmd_ls "" "$TMPDIR_LS" 2>&1)
    assert_not_contains "$out" "target/"
    assert_not_contains "$out" "debug"
    _teardown_ls
  }

  it "excludes node_modules directory" && {
    _setup_ls
    out=$(_cmd_ls "" "$TMPDIR_LS" 2>&1)
    assert_not_contains "$out" "node_modules"
    _teardown_ls
  }

  it "excludes __pycache__ directory" && {
    _setup_ls
    out=$(_cmd_ls "" "$TMPDIR_LS" 2>&1)
    assert_not_contains "$out" "__pycache__"
    assert_not_contains "$out" "cache.pyc"
    _teardown_ls
  }

# ── Depth control ──────────────────────────────────────────────
describe "_cmd_ls depth control"

  it "limits output to specified depth" && {
    _setup_ls
    # Depth 1 should show only immediate children
    out=$(_cmd_ls ". 1" "$TMPDIR_LS" 2>&1)
    assert_contains "$out" "src/"
    assert_contains "$out" "Cargo.toml"
    # Should NOT contain files nested beyond depth 1
    assert_not_contains "$out" "main.rs"
    assert_not_contains "$out" "lib.rs"
    _teardown_ls
  }

  it "shows deeper nesting at depth 5" && {
    _setup_ls
    out=$(_cmd_ls ". 5" "$TMPDIR_LS" 2>&1)
    # depth 5 should reach src/api/handlers/auth.rs
    assert_contains "$out" "auth.rs"
    assert_contains "$out" "users.rs"
    # and src/db/migrations/001_init.sql
    assert_contains "$out" "001_init.sql"
    _teardown_ls
  }

  it "clamps depth above 8 to 8" && {
    _setup_ls
    out=$(_cmd_ls ". 99" "$TMPDIR_LS" 2>&1)
    assert_contains "$out" "depth clamped to 8"
    _teardown_ls
  }

  it "defaults invalid depth to 3" && {
    _setup_ls
    out=$(_cmd_ls ". abc" "$TMPDIR_LS" 2>&1)
    # Should still work (defaulting to depth 3)
    assert_contains "$out" "depth 3"
    _teardown_ls
  }

# ── Path argument ──────────────────────────────────────────────
describe "_cmd_ls path argument"

  it "lists a subdirectory" && {
    _setup_ls
    out=$(_cmd_ls "src" "$TMPDIR_LS" 2>&1)
    assert_contains "$out" "main.rs"
    assert_contains "$out" "lib.rs"
    assert_contains "$out" "api/"
    _teardown_ls
  }

  it "lists a deeply nested subdirectory" && {
    _setup_ls
    out=$(_cmd_ls "src/api" "$TMPDIR_LS" 2>&1)
    assert_contains "$out" "mod.rs"
    assert_contains "$out" "routes.rs"
    assert_contains "$out" "handlers/"
    _teardown_ls
  }

  it "fails for non-existent directory" && {
    _setup_ls
    out=$(_cmd_ls "nonexistent" "$TMPDIR_LS" 2>&1)
    rc=$?
    assert_eq "$rc" "1"
    _teardown_ls
  }

# ── Empty directory ────────────────────────────────────────────
describe "_cmd_ls edge cases"

  it "handles empty directory" && {
    _setup_ls
    mkdir -p "$TMPDIR_LS/empty"
    out=$(_cmd_ls "empty" "$TMPDIR_LS" 2>&1)
    assert_contains "$out" "empty directory"
    _teardown_ls
  }

# ── Backward compatibility ─────────────────────────────────────
describe "_cmd_files backward compatibility"

  it "/files dispatches to /ls" && {
    _setup_ls
    out=$(_cmd_files "" "$TMPDIR_LS" 2>&1)
    assert_contains "$out" "src/"
    assert_contains "$out" "Cargo.toml"
    _teardown_ls
  }

test_end
