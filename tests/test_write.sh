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

# ── Filename sanitization ───────────────────────────────────
describe "filename sanitization in cmd_write"

  it "strips double quotes from filepath" && {
    _tmpdir=$(test_tmpdir)
    cmd_write '"quoted.txt" Written content' "$_tmpdir" 2>/dev/null
    assert_file_exists "$_tmpdir/quoted.txt"
    assert_file_not_exists "$_tmpdir/\"quoted.txt\""
    rm -rf "$_tmpdir"
  }

# ── Newline expansion ─────────────────────────────────────────
describe "newline expansion"

  it "expands \\n to real newlines in written files" && {
    _tmpdir=$(test_tmpdir)
    cmd_write 'multi.txt line1\nline2\nline3' "$_tmpdir" 2>/dev/null
    _lines=$(wc -l < "$_tmpdir/multi.txt")
    assert_eq "$_lines" "3"
    _content=$(cat "$_tmpdir/multi.txt")
    assert_contains "$_content" "line2"
    rm -rf "$_tmpdir"
  }

  it "expands \\n in --append mode" && {
    _tmpdir=$(test_tmpdir)
    echo "existing" > "$_tmpdir/append.txt"
    cmd_write '--append append.txt \n[deps]\nfoo = "1.0"' "$_tmpdir" 2>/dev/null
    _content=$(cat "$_tmpdir/append.txt")
    assert_contains "$_content" "[deps]"
    # Should have real newlines, not literal \n
    _lines=$(wc -l < "$_tmpdir/append.txt")
    [ "$_lines" -ge 3 ] && assert_ok 0 || assert_ok 1
    rm -rf "$_tmpdir"
  }

  it "preserves content with real newlines from stdin" && {
    _tmpdir=$(test_tmpdir)
    printf 'line1\nline2\nline3\n' | cmd_write "stdin_multi.txt" "$_tmpdir" 2>/dev/null
    _lines=$(wc -l < "$_tmpdir/stdin_multi.txt")
    assert_eq "$_lines" "3"
    rm -rf "$_tmpdir"
  }

# ── Edit mode validation ──────────────────────────────────────
describe "--edit mode validation"

  it "accepts valid sed substitution" && {
    _tmpdir=$(test_tmpdir)
    echo "old_name" > "$_tmpdir/edit.txt"
    _out=$(cmd_write '--edit edit.txt s/old_name/new_name/g' "$_tmpdir" 2>&1)
    assert_ok $?
    _content=$(cat "$_tmpdir/edit.txt")
    assert_contains "$_content" "new_name"
    rm -rf "$_tmpdir"
  }

  it "rejects multi-line code as sed expression" && {
    _tmpdir=$(test_tmpdir)
    echo "placeholder" > "$_tmpdir/code.rs"
    _out=$(cmd_write '--edit code.rs fn main() { println!("Hello"); }' "$_tmpdir" 2>&1)
    assert_fail $?
    assert_contains "$_out" "not a valid sed"
    rm -rf "$_tmpdir"
  }

  it "rejects excessively long sed expressions" && {
    _tmpdir=$(test_tmpdir)
    echo "x" > "$_tmpdir/long.txt"
    _long_sed="s/x/$(head -c 250 /dev/zero | tr '\0' 'y')/g"
    _out=$(cmd_write "--edit long.txt $_long_sed" "$_tmpdir" 2>&1)
    assert_fail $?
    assert_contains "$_out" "too long"
    rm -rf "$_tmpdir"
  }

# ── Escape expansion in write ─────────────────────────────────
describe "LLM escape expansion in /write"

  it "cmd_write uses ui_expand_escapes" && {
    fn_body=$(declare -f cmd_write)
    assert_contains "$fn_body" "ui_expand_escapes"
  }

  it "expands literal backslash-n in file content" && {
    _tmpdir=$(test_tmpdir)
    cmd_write 'output.txt line1\nline2\nline3' "$_tmpdir" 2>&1
    lines=$(wc -l < "$_tmpdir/output.txt")
    assert_gt "$lines" 1
    rm -rf "$_tmpdir"
  }

  it "skips expansion for --edit mode" && {
    _tmpdir=$(test_tmpdir)
    echo "old_value" > "$_tmpdir/cfg.txt"
    cmd_write '--edit cfg.txt s/old_value/new_value/' "$_tmpdir" 2>&1
    content=$(cat "$_tmpdir/cfg.txt")
    assert_contains "$content" "new_value"
    rm -rf "$_tmpdir"
  }

test_end
