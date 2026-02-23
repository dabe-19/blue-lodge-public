#!/bin/bash
# ── Tests: lib/sandbox.sh ─────────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/sandbox.sh"

test_start "lib/sandbox.sh — Project Isolation"

TMPDIR_SANDBOX=""
ORIG_SANDBOXES=""
ORIG_GEORGE_DIR=""
ORIG_SANDBOX_JOURNAL=""

_setup_sandbox() {
    TMPDIR_SANDBOX=$(test_tmpdir)
    ORIG_SANDBOXES="$LODGE_SANDBOXES"
    ORIG_GEORGE_DIR="$GEORGE_DIR"
    ORIG_SANDBOX_JOURNAL="$SANDBOX_JOURNAL"
    export LODGE_SANDBOXES="$TMPDIR_SANDBOX/sandboxes"
    export GEORGE_DIR="$TMPDIR_SANDBOX/george"
    export SANDBOX_JOURNAL="$TMPDIR_SANDBOX/george/sandbox_journal.jsonl"
    mkdir -p "$GEORGE_DIR"
}

_teardown_sandbox() {
    export LODGE_SANDBOXES="$ORIG_SANDBOXES"
    export GEORGE_DIR="$ORIG_GEORGE_DIR"
    export SANDBOX_JOURNAL="$ORIG_SANDBOX_JOURNAL"
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

# ── sandbox_test ───────────────────────────────────────────────
describe "sandbox_test"

  it "runs shell sandbox via run.sh" && {
    _setup_sandbox
    sandbox_create "test_shell_run" "shell" >/dev/null 2>&1
    out=$(sandbox_test "test_shell_run" 2>&1)
    assert_contains "$out" "Shell sandbox ready"
    _teardown_sandbox
  }

  it "fails for nonexistent sandbox" && {
    _setup_sandbox
    sandbox_test "nope" 2>/dev/null
    assert_fail $?
    _teardown_sandbox
  }

# ── sandbox_journal_log ───────────────────────────────────────
describe "sandbox_journal_log"

  it "creates journal file on first write" && {
    _setup_sandbox
    sandbox_journal_log "create" "testbox" "shell" "0"
    assert_file_exists "$SANDBOX_JOURNAL"
    _teardown_sandbox
  }

  it "writes valid JSONL entries" && {
    _setup_sandbox
    sandbox_journal_log "create" "mybox" "rust" "0"
    sandbox_journal_log "exec" "mybox" "cargo build" "0"
    lines=$(wc -l < "$SANDBOX_JOURNAL")
    assert_eq "$lines" "2"
    assert_contains "$(cat "$SANDBOX_JOURNAL")" '"ev":"create"'
    assert_contains "$(cat "$SANDBOX_JOURNAL")" '"ev":"exec"'
    _teardown_sandbox
  }

  it "escapes double quotes in detail" && {
    _setup_sandbox
    sandbox_journal_log "exec" "mybox" 'echo "hello"' "0"
    # Should not break JSON structure — quotes become \"
    line=$(cat "$SANDBOX_JOURNAL")
    assert_contains "$line" 'echo \"hello\"'
    _teardown_sandbox
  }

# ── sandbox_journal_read ──────────────────────────────────────
describe "sandbox_journal_read"

  it "reads last N entries" && {
    _setup_sandbox
    sandbox_journal_log "create" "a" "shell" "0"
    sandbox_journal_log "exec" "a" "echo 1" "0"
    sandbox_journal_log "exec" "a" "echo 2" "0"
    out=$(sandbox_journal_read 2)
    lines=$(echo "$out" | wc -l)
    assert_eq "$lines" "2"
    _teardown_sandbox
  }

  it "returns nothing if no journal exists" && {
    _setup_sandbox
    out=$(sandbox_journal_read 10)
    assert_eq "$out" ""
    _teardown_sandbox
  }

# ── sandbox_journal_summary ──────────────────────────────────
describe "sandbox_journal_summary"

  it "returns nothing when no sandboxes exist" && {
    _setup_sandbox
    out=$(sandbox_journal_summary 2>&1)
    assert_eq "$out" ""
    _teardown_sandbox
  }

  it "lists existing sandboxes with metadata" && {
    _setup_sandbox
    sandbox_create "sum_test" "shell" >/dev/null 2>&1
    out=$(sandbox_journal_summary 2>&1)
    assert_contains "$out" "SANDBOX INVENTORY"
    assert_contains "$out" "sum_test"
    assert_contains "$out" "shell"
    _teardown_sandbox
  }

  it "includes event count from journal" && {
    _setup_sandbox
    sandbox_create "counted" "shell" >/dev/null 2>&1
    sandbox_journal_log "exec" "counted" "echo hi" "0"
    sandbox_journal_log "exec" "counted" "echo bye" "0"
    out=$(sandbox_journal_summary 2>&1)
    # 1 create + 2 execs = 3 events
    assert_contains "$out" "3 events"
    _teardown_sandbox
  }

# ── sandbox_status ────────────────────────────────────────────
describe "sandbox_status"

  it "shows status for an existing sandbox" && {
    _setup_sandbox
    sandbox_create "stat_test" "shell" >/dev/null 2>&1
    out=$(sandbox_status "stat_test" 2>&1)
    assert_contains "$out" "stat_test"
    assert_contains "$out" "shell"
    assert_contains "$out" "Path:"
    _teardown_sandbox
  }

  it "fails for nonexistent sandbox" && {
    _setup_sandbox
    sandbox_status "nope" 2>/dev/null
    assert_fail $?
    _teardown_sandbox
  }

  it "shows recent journal activity" && {
    _setup_sandbox
    sandbox_create "active_box" "shell" >/dev/null 2>&1
    sandbox_journal_log "exec" "active_box" "echo test" "0"
    out=$(sandbox_status "active_box" 2>&1)
    assert_contains "$out" "Recent activity"
    assert_contains "$out" "exec"
    _teardown_sandbox
  }

# ── sandbox_create journals events ────────────────────────────
describe "sandbox_create (journal integration)"

  it "logs a create event to the journal" && {
    _setup_sandbox
    sandbox_create "journaled" "shell" >/dev/null 2>&1
    assert_file_exists "$SANDBOX_JOURNAL"
    assert_contains "$(cat "$SANDBOX_JOURNAL")" '"ev":"create"'
    assert_contains "$(cat "$SANDBOX_JOURNAL")" '"name":"journaled"'
    _teardown_sandbox
  }

# ── sandbox_exec journals events ──────────────────────────────
describe "sandbox_exec (journal integration)"

  it "logs an exec event to the journal" && {
    _setup_sandbox
    sandbox_create "exec_jrnl" "shell" >/dev/null 2>&1
    sandbox_exec "exec_jrnl" "echo hello" >/dev/null 2>&1
    journal=$(cat "$SANDBOX_JOURNAL")
    assert_contains "$journal" '"ev":"exec"'
    assert_contains "$journal" '"name":"exec_jrnl"'
    _teardown_sandbox
  }

# ── sandbox_exec sets HOME and TMPDIR ─────────────────────────
describe "sandbox_exec (isolation)"

  it "sets HOME to sandbox directory" && {
    _setup_sandbox
    sandbox_create "home_test" "shell" >/dev/null 2>&1
    home_out=$(sandbox_exec "home_test" 'echo $HOME' 2>&1)
    assert_contains "$home_out" "home_test"
    _teardown_sandbox
  }

  it "sets TMPDIR to sandbox tmp directory" && {
    _setup_sandbox
    sandbox_create "tmp_test" "shell" >/dev/null 2>&1
    tmp_out=$(sandbox_exec "tmp_test" 'echo $TMPDIR' 2>&1)
    assert_contains "$tmp_out" "tmp_test/tmp"
    _teardown_sandbox
  }

# ── sandbox_list shows journal metadata ───────────────────────
describe "sandbox_list (enriched)"

  it "shows column headers" && {
    _setup_sandbox
    sandbox_create "hdr_test" "shell" >/dev/null 2>&1
    out=$(sandbox_list 2>&1)
    assert_contains "$out" "NAME"
    assert_contains "$out" "TYPE"
    _teardown_sandbox
  }

# ── sandbox_check_prereqs ─────────────────────────────────────
describe "sandbox_check_prereqs"

  it "is defined" && {
    declare -f sandbox_check_prereqs &>/dev/null
    assert_ok $?
  }

  it "passes for shell type (always available)" && {
    sandbox_check_prereqs "shell"
    assert_ok $?
  }

  it "passes for shell by default (no arg)" && {
    sandbox_check_prereqs
    assert_ok $?
  }

  it "sets _SANDBOX_PREREQ_MSG to empty on success" && {
    sandbox_check_prereqs "shell"
    assert_eq "$_SANDBOX_PREREQ_MSG" ""
  }

  it "checks rust toolchain (rustup must exist)" && {
    if command -v rustup &>/dev/null; then
      sandbox_check_prereqs "rust"
      assert_ok $?
    else
      sandbox_check_prereqs "rust" 2>/dev/null
      assert_fail $?
      assert_not_empty "$_SANDBOX_PREREQ_MSG"
    fi
  }

  it "checks python toolchain" && {
    if command -v uv &>/dev/null || command -v python3 &>/dev/null; then
      sandbox_check_prereqs "python"
      assert_ok $?
    else
      sandbox_check_prereqs "python" 2>/dev/null
      assert_fail $?
      assert_not_empty "$_SANDBOX_PREREQ_MSG"
    fi
  }

# ── sandbox_toolchain_info ─────────────────────────────────────
describe "sandbox_toolchain_info"

  it "is defined" && {
    declare -f sandbox_toolchain_info &>/dev/null
    assert_ok $?
  }

  it "returns bash version for shell type" && {
    info=$(sandbox_toolchain_info "shell")
    assert_contains "$info" "bash"
  }

  it "returns version info for python if available" && {
    if command -v uv &>/dev/null || command -v python3 &>/dev/null; then
      info=$(sandbox_toolchain_info "python")
      assert_not_empty "$info"
    else
      info=$(sandbox_toolchain_info "python")
      assert_contains "$info" "no python"
    fi
  }

  it "returns version info for rust if available" && {
    if command -v cargo &>/dev/null; then
      info=$(sandbox_toolchain_info "rust")
      assert_contains "$info" "cargo"
    else
      info=$(sandbox_toolchain_info "rust")
      assert_contains "$info" "not found"
    fi
  }

# ── sandbox_create prereq gate ─────────────────────────────────
describe "sandbox_create (prereq gate)"

  it "creates shell sandbox without prereq failure" && {
    _setup_sandbox
    sandbox_create "prereq_shell" "shell" >/dev/null 2>&1
    assert_dir_exists "$LODGE_SANDBOXES/prereq_shell"
    _teardown_sandbox
  }

test_end
