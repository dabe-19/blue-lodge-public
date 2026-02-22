#!/bin/bash
# ── Tests: lib/sandbox.sh ─────────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/sandbox.sh"

test_start "lib/sandbox.sh — Project Isolation"

TMPDIR_SANDBOX=""
ORIG_SANDBOXES=""

_setup_sandbox() {
    TMPDIR_SANDBOX=$(test_tmpdir)
    ORIG_SANDBOXES="$LODGE_SANDBOXES"
    export LODGE_SANDBOXES="$TMPDIR_SANDBOX/sandboxes"
}

_teardown_sandbox() {
    export LODGE_SANDBOXES="$ORIG_SANDBOXES"
    rm -rf "$TMPDIR_SANDBOX"
}

# ── sandbox_detect ─────────────────────────────────────────────
describe "sandbox_detect"

  it "returns a valid isolation method" && {
    method=$(sandbox_detect)
    assert_match "$method" "^(proot|unshare|directory)$"
  }

# ── sandbox_create ─────────────────────────────────────────────
describe "sandbox_create"

  it "creates a shell sandbox" && {
    _setup_sandbox
    out=$(sandbox_create "test_shell" "shell" 2>&1)
    assert_dir_exists "$LODGE_SANDBOXES/test_shell"
    assert_file_exists "$LODGE_SANDBOXES/test_shell/run.sh"
    _teardown_sandbox
  }

  it "warns if sandbox already exists" && {
    _setup_sandbox
    sandbox_create "existing" "shell" >/dev/null 2>&1
    out=$(sandbox_create "existing" "shell" 2>&1)
    assert_contains "$out" "already exists"
    _teardown_sandbox
  }

  it "creates src and tmp directories" && {
    _setup_sandbox
    sandbox_create "with_dirs" "shell" >/dev/null 2>&1
    assert_dir_exists "$LODGE_SANDBOXES/with_dirs/src"
    assert_dir_exists "$LODGE_SANDBOXES/with_dirs/tmp"
    _teardown_sandbox
  }

  it "initializes git in sandbox" && {
    _setup_sandbox
    sandbox_create "git_test" "shell" >/dev/null 2>&1
    assert_dir_exists "$LODGE_SANDBOXES/git_test/.git"
    _teardown_sandbox
  }

# ── sandbox_exec ───────────────────────────────────────────────
describe "sandbox_exec"

  it "runs a command inside a sandbox" && {
    _setup_sandbox
    sandbox_create "exec_test" "shell" >/dev/null 2>&1
    out=$(sandbox_exec "exec_test" "echo hello_from_sandbox" 2>&1)
    assert_contains "$out" "hello_from_sandbox"
    _teardown_sandbox
  }

  it "fails for nonexistent sandbox" && {
    _setup_sandbox
    sandbox_exec "nonexistent" "echo hi" 2>/dev/null
    assert_fail $?
    _teardown_sandbox
  }

# ── sandbox_list ───────────────────────────────────────────────
describe "sandbox_list"

  it "lists created sandboxes" && {
    _setup_sandbox
    sandbox_create "list_a" "shell" >/dev/null 2>&1
    sandbox_create "list_b" "shell" >/dev/null 2>&1
    out=$(sandbox_list 2>&1)
    assert_contains "$out" "list_a"
    assert_contains "$out" "list_b"
    _teardown_sandbox
  }

  it "shows 'no sandboxes' when empty" && {
    _setup_sandbox
    out=$(sandbox_list 2>&1)
    assert_contains "$out" "No sandboxes"
    _teardown_sandbox
  }

# ── sandbox_build ──────────────────────────────────────────────
describe "sandbox_build"

  it "builds a shell sandbox by running run.sh" && {
    _setup_sandbox
    sandbox_create "build_test" "shell" >/dev/null 2>&1
    out=$(sandbox_build "build_test" 2>&1)
    assert_contains "$out" "Shell sandbox ready"
    _teardown_sandbox
  }

  it "fails for nonexistent sandbox" && {
    _setup_sandbox
    sandbox_build "nope" 2>/dev/null
    assert_fail $?
    _teardown_sandbox
  }

# ── sandbox_remove (non-interactive) ──────────────────────────
describe "sandbox_remove"

  it "fails for nonexistent sandbox" && {
    _setup_sandbox
    sandbox_remove "nope" 2>/dev/null <<< "n"
    assert_fail $?
    _teardown_sandbox
  }

test_end
