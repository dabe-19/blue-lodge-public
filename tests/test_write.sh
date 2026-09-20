#!/bin/bash
# ── Tests: commands/write.sh ───────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/tools.sh"
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

  it "overwrites existing file and saves backup to .history" && {
    _tmpdir=$(test_tmpdir)
    echo "old" > "$_tmpdir/existing.txt"
    _out=$(cmd_write "existing.txt new content" "$_tmpdir" 2>&1)
    _content=$(cat "$_tmpdir/existing.txt")
    assert_contains "$_content" "new content"
    assert_contains "$_out" "Overwrote"
    
    # Check if backup exists in .history
    backup_count=$(find "$_tmpdir/.history" -type f -name "existing.txt_*" 2>/dev/null | wc -l)
    assert_eq "$backup_count" "1"
    backup_file=$(find "$_tmpdir/.history" -type f -name "existing.txt_*")
    backup_content=$(cat "$backup_file")
    assert_eq "$backup_content" "old"
    
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

  it "writes to unquoted filename with spaces and extension" && {
    _tmpdir=$(test_tmpdir)
    cmd_write "My Deep Analysis Report.md # Gamestop (GME) Market Analysis" "$_tmpdir" 2>/dev/null
    assert_file_exists "$_tmpdir/My-Deep-Analysis-Report.md"
    _content=$(cat "$_tmpdir/My-Deep-Analysis-Report.md")
    assert_contains "$_content" "# Gamestop (GME) Market Analysis"
    rm -rf "$_tmpdir"
  }

  it "appends .md fallback when filename has no extension" && {
    _tmpdir=$(test_tmpdir)
    _out=$(cmd_write "no_extension_file content here" "$_tmpdir" 2>&1)
    assert_file_exists "$_tmpdir/no_extension_file.md"
    assert_contains "$_out" "No file extension detected"
    _content=$(cat "$_tmpdir/no_extension_file.md")
    assert_contains "$_content" "content here"
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

  it "accepts valid block-replacement" && {
    _tmpdir=$(test_tmpdir)
    echo "old_name" > "$_tmpdir/edit.txt"
    _out=$(cmd_write $'--edit edit.txt\n<<<<<<<\nold_name\n=======\nnew_name\n>>>>>>>' "$_tmpdir" 2>&1)
    assert_ok $?
    _content=$(cat "$_tmpdir/edit.txt")
    assert_contains "$_content" "new_name"
    rm -rf "$_tmpdir"
  }

  it "rejects invalid block-replace format" && {
    _tmpdir=$(test_tmpdir)
    echo "placeholder" > "$_tmpdir/code.rs"
    _out=$(cmd_write '--edit code.rs fn main() { println!("Hello"); }' "$_tmpdir" 2>&1)
    assert_fail $?
    assert_contains "$_out" "invalid block-replace format"
    rm -rf "$_tmpdir"
  }

  it "rejects block-replace with non-unique search pattern" && {
    _tmpdir=$(test_tmpdir)
    printf "target\ntarget\n" > "$_tmpdir/duplicate.txt"
    _out=$(cmd_write $'--edit duplicate.txt\n<<<<<<<\ntarget\n=======\nreplacement\n>>>>>>>' "$_tmpdir" 2>&1)
    assert_fail $?
    assert_contains "$_out" "multiple matches"
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
    echo 'old_value\ntext' > "$_tmpdir/cfg.txt"
    cmd_write $'--edit cfg.txt\n<<<<<<<\nold_value\\ntext\n=======\nnew_value\n>>>>>>>' "$_tmpdir" 2>&1
    content=$(cat "$_tmpdir/cfg.txt")
    assert_contains "$content" "new_value"
    rm -rf "$_tmpdir"
  }

# ── Inline /read expansion in /write content ───────────────
describe "Inline /read expansion in /write"

  it "cmd_write has inline read expansion" && {
    fn_body=$(declare -f cmd_write)
    assert_contains "$fn_body" "tools_expand_inline_read"
  }

  it "/write inlines file content from /read reference" && {
    _tmpdir=$(test_tmpdir)
    echo "Source file content" > "$_tmpdir/source.txt"
    cmd_write "output.txt /read $_tmpdir/source.txt" "$_tmpdir" 2>&1
    content=$(cat "$_tmpdir/output.txt")
    assert_contains "$content" "Source file content"
    rm -rf "$_tmpdir"
  }

  it "/write preserves prefix text before /read" && {
    _tmpdir=$(test_tmpdir)
    echo "inline data" > "$_tmpdir/data.txt"
    cmd_write "output.txt Header text /read $_tmpdir/data.txt" "$_tmpdir" 2>&1
    content=$(cat "$_tmpdir/output.txt")
    assert_contains "$content" "Header text"
    assert_contains "$content" "inline data"
    rm -rf "$_tmpdir"
  }

test_end
