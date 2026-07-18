#!/bin/bash
# ── Tests: iPhone 7+ Field Bug Fixes ──────────────────────────
# Verifies: file-ref expansion glob fix + dedup, pre-route failure
# breaker, /append command, /edit command, /write backward compat,
# sandbox routing clarity, coding workflow card.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/tools.sh"
source "$LODGE_DIR/lib/commands.sh"

test_start "iPhone Bug Fixes — tools.sh / agent.sh / commands"

# ══════════════════════════════════════════════════════════════
# Bug 1: File-ref expansion glob safety + dedup
# ══════════════════════════════════════════════════════════════
describe "tools_expand_file_refs glob safety"

  it "does not glob-expand *.md in content" && {
    _tmpdir=$(test_tmpdir)
    echo "real" > "$_tmpdir/README.md"
    echo "real" > "$_tmpdir/SECURITY.md"
    # Content contains literal *.md which should NOT become file list
    result=$(tools_expand_file_refs "Write *.md files to disk" "$_tmpdir")
    # Should NOT contain README.md or SECURITY.md (glob not expanded)
    assert_not_contains "$result" "README.md"
    assert_not_contains "$result" "SECURITY.md"
    rm -rf "$_tmpdir"
  }

  it "does not glob-expand *.txt in content" && {
    _tmpdir=$(test_tmpdir)
    echo "data" > "$_tmpdir/notes.txt"
    result=$(tools_expand_file_refs "All *.txt files" "$_tmpdir")
    # The word *.txt should pass through without becoming notes.txt
    assert_not_contains "$result" "data"
    rm -rf "$_tmpdir"
  }

  it "still expands actual file references" && {
    _tmpdir=$(test_tmpdir)
    echo "file content here" > "$_tmpdir/data.json"
    result=$(tools_expand_file_refs "Please read data.json carefully" "$_tmpdir")
    assert_contains "$result" "file content here"
    rm -rf "$_tmpdir"
  }

describe "tools_expand_file_refs dedup"

  it "expands same file only once per call" && {
    _tmpdir=$(test_tmpdir)
    echo "unique-content-xyz" > "$_tmpdir/config.json"
    result=$(tools_expand_file_refs "Read config.json then update config.json" "$_tmpdir")
    # Count occurrences of the file content — should be exactly 1
    count=$(echo "$result" | grep -o "unique-content-xyz" | wc -l)
    assert_eq "$count" "1" "same file should only be inlined once"
    rm -rf "$_tmpdir"
  }

  it "expands different files independently" && {
    _tmpdir=$(test_tmpdir)
    echo "content-A" > "$_tmpdir/a.json"
    echo "content-B" > "$_tmpdir/b.json"
    result=$(tools_expand_file_refs "Read a.json and b.json" "$_tmpdir")
    assert_contains "$result" "content-A"
    assert_contains "$result" "content-B"
    rm -rf "$_tmpdir"
  }

# ══════════════════════════════════════════════════════════════
# Bug 2: /append command
# ══════════════════════════════════════════════════════════════
source "$LODGE_DIR/commands/append.sh"

describe "cmd_append"

  it "is defined" && {
    declare -f cmd_append &>/dev/null
    assert_ok $?
  }

  it "fails with no arguments" && {
    _out=$(cmd_append "" "." 2>&1)
    assert_fail $?
    assert_contains "$_out" "Usage"
  }

  it "creates file if it does not exist" && {
    _tmpdir=$(test_tmpdir)
    cmd_append "new.txt Hello world" "$_tmpdir" 2>/dev/null
    assert_file_exists "$_tmpdir/new.txt"
    _content=$(cat "$_tmpdir/new.txt")
    assert_contains "$_content" "Hello world"
    rm -rf "$_tmpdir"
  }

  it "appends to existing file" && {
    _tmpdir=$(test_tmpdir)
    echo "original" > "$_tmpdir/existing.txt"
    cmd_append "existing.txt added content" "$_tmpdir" 2>/dev/null
    _content=$(cat "$_tmpdir/existing.txt")
    assert_contains "$_content" "original"
    assert_contains "$_content" "added content"
    rm -rf "$_tmpdir"
  }

  it "expands \\n to real newlines" && {
    _tmpdir=$(test_tmpdir)
    echo "base" > "$_tmpdir/multi.txt"
    cmd_append 'multi.txt line1\nline2\nline3' "$_tmpdir" 2>/dev/null
    _lines=$(wc -l < "$_tmpdir/multi.txt")
    [ "$_lines" -ge 4 ] && assert_ok 0 || assert_ok 1 "expected >=4 lines, got $_lines"
    rm -rf "$_tmpdir"
  }

  it "strips leading slash from filepath" && {
    _tmpdir=$(test_tmpdir)
    cmd_append "/absolute/path.txt safe content" "$_tmpdir" 2>/dev/null
    assert_file_exists "$_tmpdir/absolute/path.txt"
    assert_file_not_exists "/absolute/path.txt"
    rm -rf "$_tmpdir"
  }

  it "can be dispatched via commands_dispatch" && {
    _tmpdir=$(test_tmpdir)
    echo "start" > "$_tmpdir/dispatched.txt"
    commands_dispatch "/append dispatched.txt more data" "$_tmpdir" 2>/dev/null
    _content=$(cat "$_tmpdir/dispatched.txt")
    assert_contains "$_content" "start"
    assert_contains "$_content" "more data"
    rm -rf "$_tmpdir"
  }

# ══════════════════════════════════════════════════════════════
# Bug 2: /edit command
# ══════════════════════════════════════════════════════════════
source "$LODGE_DIR/commands/edit.sh"

describe "cmd_edit"

  it "is defined" && {
    declare -f cmd_edit &>/dev/null
    assert_ok $?
  }

  it "fails with no arguments" && {
    _out=$(cmd_edit "" "." 2>&1)
    assert_fail $?
    assert_contains "$_out" "Usage"
  }

  it "applies valid block-replacement" && {
    _tmpdir=$(test_tmpdir)
    echo "old_name = true" > "$_tmpdir/config.txt"
    _out=$(cmd_edit $'config.txt\n<<<<<<<\nold_name = true\n=======\nnew_name = true\n>>>>>>>' "$_tmpdir" 2>&1)
    assert_ok $?
    _content=$(cat "$_tmpdir/config.txt")
    assert_contains "$_content" "new_name = true"
    assert_not_contains "$_content" "old_name = true"
    rm -rf "$_tmpdir"
  }

  it "rejects invalid block-replace format" && {
    _tmpdir=$(test_tmpdir)
    echo "placeholder" > "$_tmpdir/code.rs"
    _out=$(cmd_edit 'code.rs fn main() { println!("Hello"); }' "$_tmpdir" 2>&1)
    assert_fail $?
    assert_contains "$_out" "invalid block-replace format"
    rm -rf "$_tmpdir"
  }

  it "rejects non-unique block-replace patterns" && {
    _tmpdir=$(test_tmpdir)
    printf "x\nx\n" > "$_tmpdir/long.txt"
    _out=$(cmd_edit $'long.txt\n<<<<<<<\nx\n=======\ny\n>>>>>>>' "$_tmpdir" 2>&1)
    assert_fail $?
    assert_contains "$_out" "multiple matches"
    rm -rf "$_tmpdir"
  }

  it "fails on non-existent file" && {
    _tmpdir=$(test_tmpdir)
    _out=$(cmd_edit $'missing.txt\n<<<<<<<\na\n=======\nb\n>>>>>>>' "$_tmpdir" 2>&1)
    assert_fail $?
    assert_contains "$_out" "does not exist"
    rm -rf "$_tmpdir"
  }

  it "strips leading slash from filepath" && {
    _tmpdir=$(test_tmpdir)
    mkdir -p "$_tmpdir/src"
    echo "old" > "$_tmpdir/src/main.rs"
    cmd_edit $'/src/main.rs\n<<<<<<<\nold\n=======\nnew\n>>>>>>>' "$_tmpdir" 2>/dev/null
    _content=$(cat "$_tmpdir/src/main.rs")
    assert_contains "$_content" "new"
    rm -rf "$_tmpdir"
  }

  it "can be dispatched via commands_dispatch" && {
    _tmpdir=$(test_tmpdir)
    echo "value=100" > "$_tmpdir/settings.txt"
    commands_dispatch $'/edit settings.txt\n<<<<<<<\nvalue=100\n=======\nvalue=200\n>>>>>>>' "$_tmpdir" 2>/dev/null
    _content=$(cat "$_tmpdir/settings.txt")
    assert_contains "$_content" "200"
    rm -rf "$_tmpdir"
  }

  it "supports blockless query mode and outputs line numbers" && {
    _tmpdir=$(test_tmpdir)
    echo -e "first\nsecond" > "$_tmpdir/query.txt"
    _out=$(cmd_edit "query.txt" "$_tmpdir" 2>&1)
    assert_ok $?
    assert_contains "$_out" "1: first"
    assert_contains "$_out" "2: second"
    rm -rf "$_tmpdir"
  }

  it "automatically strips line number prefixes from search/replace patterns" && {
    _tmpdir=$(test_tmpdir)
    echo -e "line a\nline b\nline c" > "$_tmpdir/strip.txt"
    _out=$(cmd_edit $'strip.txt\n<<<<<<<\n2: line b\n=======\n2: line b modified\n>>>>>>>' "$_tmpdir" 2>&1)
    assert_ok $?
    _content=$(cat "$_tmpdir/strip.txt")
    assert_contains "$_content" "line b modified"
    assert_not_contains "$_content" "2: "
    rm -rf "$_tmpdir"
  }

  it "correctly unescapes literal \\n sequences passed through commands_dispatch for /edit" && {
    _tmpdir=$(test_tmpdir)
    echo "original_text" > "$_tmpdir/nl_edit.txt"
    commands_dispatch '/edit nl_edit.txt\n<<<<<<<\noriginal_text\n=======\nreplaced_text\n>>>>>>>' "$_tmpdir" 2>/dev/null
    _content=$(cat "$_tmpdir/nl_edit.txt")
    assert_contains "$_content" "replaced_text"
    rm -rf "$_tmpdir"
  }

# ══════════════════════════════════════════════════════════════
# Bug 2: /write backward compatibility (--append/--edit redirect)
# ══════════════════════════════════════════════════════════════
source "$LODGE_DIR/commands/write.sh"

describe "/write backward compat"

  it "/write --append redirects to cmd_append" && {
    _tmpdir=$(test_tmpdir)
    echo "original" > "$_tmpdir/compat.txt"
    cmd_write "--append compat.txt appended data" "$_tmpdir" 2>/dev/null
    _content=$(cat "$_tmpdir/compat.txt")
    assert_contains "$_content" "original"
    assert_contains "$_content" "appended data"
    rm -rf "$_tmpdir"
  }

  it "/write --edit redirects to cmd_edit" && {
    _tmpdir=$(test_tmpdir)
    echo "old_value" > "$_tmpdir/compat_edit.txt"
    cmd_write $'--edit compat_edit.txt\n<<<<<<<\nold_value\n=======\nnew_value\n>>>>>>>' "$_tmpdir" 2>/dev/null
    _content=$(cat "$_tmpdir/compat_edit.txt")
    assert_contains "$_content" "new_value"
    rm -rf "$_tmpdir"
  }

  it "/write without flags still writes/overwrites" && {
    _tmpdir=$(test_tmpdir)
    cmd_write "fresh.txt brand new content" "$_tmpdir" 2>/dev/null
    assert_file_exists "$_tmpdir/fresh.txt"
    _content=$(cat "$_tmpdir/fresh.txt")
    assert_contains "$_content" "brand new content"
    rm -rf "$_tmpdir"
  }

# ══════════════════════════════════════════════════════════════
# Bug 3: Pre-route and interlock thresholds
# ══════════════════════════════════════════════════════════════
source "$LODGE_DIR/lib/agent.sh" 2>/dev/null

describe "pre-route failure breaker (agent.sh)"

  it "pre-route failure breaker code is present" && {
    fn_body=$(declare -f _agent_inner_loop 2>/dev/null || cat "$LODGE_DIR/lib/agent.sh")
    assert_contains "$fn_body" "Pre-route failure breaker"
  }

  it "increments _p1_incomplete_consec on pre-route failure" && {
    agent_code=$(cat "$LODGE_DIR/lib/agent.sh")
    # Should have: if [ -n "$_pre_route" ]; then _p1_incomplete_consec=
    assert_contains "$agent_code" '_pre_route" ]; then'
    assert_contains "$agent_code" '_p1_incomplete_consec=$((_p1_incomplete_consec + 1))'
  }

describe "interlock threshold"

  it "interlock fires at _fail_count >= 2 (not 3)" && {
    agent_code=$(cat "$LODGE_DIR/lib/agent.sh")
    assert_contains "$agent_code" '_fail_count" -ge 2 ]'
    # Should NOT have the old threshold of 3 for the interlock
    assert_not_contains "$agent_code" 'Levels 3-4: Prevents'
  }

# ══════════════════════════════════════════════════════════════
# Bug 3: Sandbox/routing clarity
# ══════════════════════════════════════════════════════════════
describe "sandbox syntax card clarity"

  it "sandbox card contains when_to_use guidance" && {
    agent_code=$(cat "$LODGE_DIR/lib/agent.sh")
    assert_contains "$agent_code" "when_to_use"
    assert_contains "$agent_code" "USE /build"
    assert_contains "$agent_code" "USE /init"
  }

describe "coding workflow card"

  it "includes /append and /edit commands" && {
    agent_code=$(cat "$LODGE_DIR/lib/agent.sh")
    assert_contains "$agent_code" '"/append <path> <code>"'
    assert_contains "$agent_code" '"/edit <path>"'
  }

  it "warns not to retry /init on existing project" && {
    agent_code=$(cat "$LODGE_DIR/lib/agent.sh")
    assert_contains "$agent_code" "NEVER retry /init"
  }

# ══════════════════════════════════════════════════════════════
# Command catalog updates
# ══════════════════════════════════════════════════════════════
describe "command catalog"

  it "catalog includes /append entry" && {
    catalog=$(commands_catalog 2>/dev/null)
    assert_contains "$catalog" '"/append"'
  }

  it "catalog includes /edit entry" && {
    catalog=$(commands_catalog 2>/dev/null)
    assert_contains "$catalog" '"/edit"'
  }

  it "/write no longer has --append/--edit variants" && {
    catalog=$(commands_catalog 2>/dev/null)
    assert_not_contains "$catalog" '"--append"'
    assert_not_contains "$catalog" '"--edit"'
  }

describe "tool summary includes new commands"

  it "FILES list includes /append and /edit" && {
    grep -q '"/edit","/append"' "$LODGE_DIR/lib/agent.sh"
    assert_ok $? "agent.sh should list /edit and /append in FILES"
  }

# ══════════════════════════════════════════════════════════════
# Sandbox interlock keyword routing
# ══════════════════════════════════════════════════════════════
describe "sandbox interlock keyword routing"

  it "routes append-like objectives to /append" && {
    agent_code=$(cat "$LODGE_DIR/lib/agent.sh")
    assert_contains "$agent_code" '*append*to*'
  }

  it "routes edit-like objectives to /edit" && {
    agent_code=$(cat "$LODGE_DIR/lib/agent.sh")
    assert_contains "$agent_code" '*edit*file*'
  }

test_end
