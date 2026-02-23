#!/bin/bash
# ── Tests: commands/write.sh ───────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/commands.sh"

test_start "commands/write.sh — Write Files"

# ── Load the command ───────────────────────────────────────────
source "$LODGE_DIR/commands/write.sh"

# ── cmd_write basics ───────────────────────────────────────────
describe "cmd_write"

  it "is defined" && {
    declare -f cmd_write &>/dev/null
    assert_ok $?
  }

  it "fails with no arguments" && {
    _out=$(cmd_write "" "." 2>&1)
    assert_fail $?
    assert_contains "$_out" "Usage"
  }

  it "writes content to a new file" && {
    _tmpdir=$(test_tmpdir)
    cmd_write "hello.txt Hello from write" "$_tmpdir" 2>/dev/null
    assert_file_exists "$_tmpdir/hello.txt"
    _content=$(cat "$_tmpdir/hello.txt")
    assert_contains "$_content" "Hello from write"
    rm -rf "$_tmpdir"
  }

  it "creates parent directories" && {
    _tmpdir=$(test_tmpdir)
    cmd_write "a/b/c.txt Deep content" "$_tmpdir" 2>/dev/null
    assert_file_exists "$_tmpdir/a/b/c.txt"
    rm -rf "$_tmpdir"
  }

  it "overwrites existing file" && {
    _tmpdir=$(test_tmpdir)
    echo "old" > "$_tmpdir/existing.txt"
    _out=$(cmd_write "existing.txt new content" "$_tmpdir" 2>&1)
    _content=$(cat "$_tmpdir/existing.txt")
    assert_contains "$_content" "new content"
    assert_contains "$_out" "Overwrote"
    rm -rf "$_tmpdir"
  }

  it "fails with filepath but no content" && {
    _tmpdir=$(test_tmpdir)
    _out=$(cmd_write "empty.txt" "$_tmpdir" 2>&1)
    assert_fail $?
    assert_contains "$_out" "No content"
    rm -rf "$_tmpdir"
  }

  it "reads content from stdin" && {
    _tmpdir=$(test_tmpdir)
    echo "stdin content" | cmd_write "stdin.txt" "$_tmpdir" 2>/dev/null
    assert_file_exists "$_tmpdir/stdin.txt"
    _content=$(cat "$_tmpdir/stdin.txt")
    assert_contains "$_content" "stdin content"
    rm -rf "$_tmpdir"
  }

# ── Dispatch integration ──────────────────────────────────────
describe "dispatch integration"

  it "can be dispatched via commands_dispatch" && {
    _tmpdir=$(test_tmpdir)
    commands_dispatch "/write test.txt dispatch write works" "$_tmpdir" 2>/dev/null
    assert_file_exists "$_tmpdir/test.txt"
    rm -rf "$_tmpdir"
  }

test_end
