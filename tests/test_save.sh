#!/bin/bash
# ── Tests: commands/save.sh ────────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/commands.sh"

test_start "commands/save.sh — Save Files"

# ── Load the command ───────────────────────────────────────────
source "$LODGE_DIR/commands/save.sh"

# ── cmd_save basics ────────────────────────────────────────────
describe "cmd_save"

  it "is defined" && {
    declare -f cmd_save &>/dev/null
    assert_ok $?
  }

  it "fails with no arguments" && {
    _out=$(cmd_save "" "." 2>&1)
    assert_fail $?
    assert_contains "$_out" "Usage"
  }

  it "saves content to a file" && {
    _tmpdir=$(test_tmpdir)
    cmd_save "test.txt Hello world" "$_tmpdir" 2>/dev/null
    assert_file_exists "$_tmpdir/test.txt"
    _content=$(cat "$_tmpdir/test.txt")
    assert_contains "$_content" "Hello world"
    rm -rf "$_tmpdir"
  }

  it "creates parent directories" && {
    _tmpdir=$(test_tmpdir)
    cmd_save "sub/dir/test.txt Nested content" "$_tmpdir" 2>/dev/null
    assert_file_exists "$_tmpdir/sub/dir/test.txt"
    _content=$(cat "$_tmpdir/sub/dir/test.txt")
    assert_contains "$_content" "Nested content"
    rm -rf "$_tmpdir"
  }

  it "fails with filepath but no content" && {
    _tmpdir=$(test_tmpdir)
    _out=$(cmd_save "empty.txt" "$_tmpdir" 2>&1)
    assert_fail $?
    assert_contains "$_out" "No content"
    rm -rf "$_tmpdir"
  }

  it "saves multi-word content" && {
    _tmpdir=$(test_tmpdir)
    cmd_save "readme.md This is a longer piece of content with spaces" "$_tmpdir" 2>/dev/null
    assert_file_exists "$_tmpdir/readme.md"
    _content=$(cat "$_tmpdir/readme.md")
    assert_contains "$_content" "longer piece of content"
    rm -rf "$_tmpdir"
  }

  it "reads content from stdin" && {
    _tmpdir=$(test_tmpdir)
    echo "piped content" | cmd_save "piped.txt" "$_tmpdir" 2>/dev/null
    assert_file_exists "$_tmpdir/piped.txt"
    _content=$(cat "$_tmpdir/piped.txt")
    assert_contains "$_content" "piped content"
    rm -rf "$_tmpdir"
  }

# ── Dispatch integration ──────────────────────────────────────
describe "dispatch integration"

  it "can be dispatched via commands_dispatch" && {
    _tmpdir=$(test_tmpdir)
    commands_dispatch "/save test.txt dispatch works" "$_tmpdir" 2>/dev/null
    assert_file_exists "$_tmpdir/test.txt"
    rm -rf "$_tmpdir"
  }

# ── Filename sanitization ───────────────────────────────────
describe "filename sanitization in cmd_save"

  it "strips double quotes from filepath" && {
    _tmpdir=$(test_tmpdir)
    cmd_save '"quoted.txt" Content here' "$_tmpdir" 2>/dev/null
    assert_file_exists "$_tmpdir/quoted.txt"
    assert_file_not_exists "$_tmpdir/\"quoted.txt\""
    rm -rf "$_tmpdir"
  }

  it "strips single quotes from filepath" && {
    _tmpdir=$(test_tmpdir)
    cmd_save "'singleq.txt' Some content" "$_tmpdir" 2>/dev/null
    assert_file_exists "$_tmpdir/singleq.txt"
    rm -rf "$_tmpdir"
  }

# ── Existing file without content ─────────────────────────────
describe "save existing file without content"

  it "succeeds when file already exists and no content given" && {
    _tmpdir=$(test_tmpdir)
    echo "existing content" > "$_tmpdir/existing.md"
    _out=$(cmd_save "existing.md" "$_tmpdir" 2>&1)
    assert_ok $?
    assert_contains "$_out" "Saved"
    rm -rf "$_tmpdir"
  }

  it "succeeds with quoted filename for existing file" && {
    _tmpdir=$(test_tmpdir)
    echo "workout plan" > "$_tmpdir/workout.md"
    _out=$(cmd_save '"workout.md"' "$_tmpdir" 2>&1)
    assert_ok $?
    assert_contains "$_out" "Saved"
    rm -rf "$_tmpdir"
  }

  it "still fails when file does not exist and no content" && {
    _tmpdir=$(test_tmpdir)
    _out=$(cmd_save "nonexistent.md" "$_tmpdir" 2>&1)
    assert_fail $?
    assert_contains "$_out" "No content"
    rm -rf "$_tmpdir"
  }

# ── Escape expansion in save ──────────────────────────────────
describe "LLM escape expansion in /save"

  it "cmd_save expands literal backslash-n to real newlines" && {
    _tmpdir=$(test_tmpdir)
    cmd_save 'test.md line1\nline2\nline3' "$_tmpdir" 2>&1
    lines=$(wc -l < "$_tmpdir/test.md")
    assert_gt "$lines" 1
    rm -rf "$_tmpdir"
  }

  it "cmd_save function references ui_expand_escapes" && {
    fn_body=$(declare -f cmd_save)
    assert_contains "$fn_body" "ui_expand_escapes"
  }

test_end
