#!/bin/bash
# ── Tests: commands/download.sh ────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/commands.sh"

test_start "commands/download.sh — Download / Copy Files"

# ── Load the command ───────────────────────────────────────────
source "$LODGE_DIR/commands/download.sh"

# ── cmd_download basics ────────────────────────────────────────
describe "cmd_download"

  it "is defined" && {
    declare -f cmd_download &>/dev/null
    assert_ok $?
  }

  it "fails with no arguments" && {
    _out=$(cmd_download "" "." 2>&1)
    assert_fail $?
    assert_contains "$_out" "Usage"
  }

  it "copies a local file" && {
    _tmpdir=$(test_tmpdir)
    echo "source content" > "$_tmpdir/source.txt"
    cmd_download "$_tmpdir/source.txt $_tmpdir/dest.txt" "$_tmpdir" 2>/dev/null
    assert_file_exists "$_tmpdir/dest.txt"
    _content=$(cat "$_tmpdir/dest.txt")
    assert_contains "$_content" "source content"
    rm -rf "$_tmpdir"
  }

  it "copies a local file with default name" && {
    _tmpdir=$(test_tmpdir)
    echo "auto name" > "$_tmpdir/autoname.txt"
    cmd_download "$_tmpdir/autoname.txt" "$_tmpdir" 2>/dev/null
    assert_file_exists "$_tmpdir/autoname.txt"
    rm -rf "$_tmpdir"
  }

  it "fails for nonexistent source" && {
    _tmpdir=$(test_tmpdir)
    _out=$(cmd_download "/nonexistent/file.txt" "$_tmpdir" 2>&1)
    assert_fail $?
    assert_contains "$_out" "not found"
    rm -rf "$_tmpdir"
  }

  it "copies a directory recursively" && {
    _tmpdir=$(test_tmpdir)
    mkdir -p "$_tmpdir/srcdir/sub"
    echo "file1" > "$_tmpdir/srcdir/a.txt"
    echo "file2" > "$_tmpdir/srcdir/sub/b.txt"
    cmd_download "$_tmpdir/srcdir $_tmpdir/destdir" "$_tmpdir" 2>/dev/null
    assert_dir_exists "$_tmpdir/destdir"
    rm -rf "$_tmpdir"
  }

# ── Dispatch integration ──────────────────────────────────────
describe "dispatch integration"

  it "can be dispatched via commands_dispatch" && {
    _tmpdir=$(test_tmpdir)
    echo "dispatch test" > "$_tmpdir/src.txt"
    commands_dispatch "/download $_tmpdir/src.txt $_tmpdir/dst.txt" "$_tmpdir" 2>/dev/null
    assert_file_exists "$_tmpdir/dst.txt"
    rm -rf "$_tmpdir"
  }

test_end
