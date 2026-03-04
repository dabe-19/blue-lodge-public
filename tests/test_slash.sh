#!/bin/bash
# ── Tests: lib/slash.sh ───────────────────────────────────────
# Slash Extensions (Magnum Opus): create, test, run, delete,
# rename, export, list custom slash commands.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"

_test_tmpdir=""
_test_out=""
_test_rc=0

_setup_slash() {
    _test_tmpdir=$(test_tmpdir)
    export GEORGE_CONFIG_DIR="$_test_tmpdir/.george"
    export SLASH_DIR="$GEORGE_CONFIG_DIR/slash"
    source "$LODGE_DIR/lib/slash.sh"
}

_teardown_slash() {
    rm -rf "$_test_tmpdir"
}

# Write a valid custom command for testing
_create_test_command() {
    name="${1:-testcmd}"
    desc="${2:-A test command}"
    mkdir -p "$SLASH_DIR"
    cat > "$SLASH_DIR/${name}.sh" << 'CMDEOF'
#!/bin/bash
# ── Slash Extension: testcmd ───────────────────────────────────
# Description: A test command
# Created: 2026-02-22
# Author: George
# Version: 1

slash_testcmd() {
    args="$1"
    workdir="${2:-.}"
    echo "testcmd ran with args: $args"
}
CMDEOF
    chmod +x "$SLASH_DIR/${name}.sh"

    # Fix function name if not "testcmd"
    if [ "$name" != "testcmd" ]; then
        sed -i "s/slash_testcmd/slash_${name}/g" "$SLASH_DIR/${name}.sh"
        sed -i "s/Extension: testcmd/Extension: ${name}/g" "$SLASH_DIR/${name}.sh"
        sed -i "s/Description: A test command/Description: ${desc}/g" "$SLASH_DIR/${name}.sh"
        sed -i "s/testcmd ran with/${name} ran with/g" "$SLASH_DIR/${name}.sh"
    fi
}

test_start "lib/slash.sh — Slash Extensions (Magnum Opus)"

# ═══════════════════════════════════════════════════════════════
# Function existence
# ═══════════════════════════════════════════════════════════════
describe "Core functions"

  it "slash_init is defined" && {
    _setup_slash
    declare -f slash_init &>/dev/null
    assert_ok $?
    _teardown_slash
  }

  it "slash_list is defined" && {
    _setup_slash
    declare -f slash_list &>/dev/null
    assert_ok $?
    _teardown_slash
  }

  it "slash_create is defined" && {
    _setup_slash
    declare -f slash_create &>/dev/null
    assert_ok $?
    _teardown_slash
  }

  it "slash_run is defined" && {
    _setup_slash
    declare -f slash_run &>/dev/null
    assert_ok $?
    _teardown_slash
  }

  it "slash_test is defined" && {
    _setup_slash
    declare -f slash_test &>/dev/null
    assert_ok $?
    _teardown_slash
  }

  it "slash_show is defined" && {
    _setup_slash
    declare -f slash_show &>/dev/null
    assert_ok $?
    _teardown_slash
  }

  it "slash_delete is defined" && {
    _setup_slash
    declare -f slash_delete &>/dev/null
    assert_ok $?
    _teardown_slash
  }

  it "slash_edit is defined" && {
    _setup_slash
    declare -f slash_edit &>/dev/null
    assert_ok $?
    _teardown_slash
  }

  it "slash_export is defined" && {
    _setup_slash
    declare -f slash_export &>/dev/null
    assert_ok $?
    _teardown_slash
  }

  it "slash_rename is defined" && {
    _setup_slash
    declare -f slash_rename &>/dev/null
    assert_ok $?
    _teardown_slash
  }

  it "slash_catalog is defined" && {
    _setup_slash
    declare -f slash_catalog &>/dev/null
    assert_ok $?
    _teardown_slash
  }

# ═══════════════════════════════════════════════════════════════
# Initialization
# ═══════════════════════════════════════════════════════════════
describe "slash_init"

  it "creates the slash directory" && {
    _setup_slash
    slash_init 2>/dev/null
    assert_dir_exists "$SLASH_DIR"
    _teardown_slash
  }

  it "is idempotent" && {
    _setup_slash
    slash_init 2>/dev/null
    slash_init 2>/dev/null
    assert_dir_exists "$SLASH_DIR"
    _teardown_slash
  }

# ═══════════════════════════════════════════════════════════════
# Template creation (no LLM needed)
# ═══════════════════════════════════════════════════════════════
describe "slash_create (template mode)"

  it "creates template when no description given" && {
    _setup_slash
    slash_create "mytool" "" 2>/dev/null
    assert_file_exists "$SLASH_DIR/mytool.sh"
    _teardown_slash
  }

  it "template contains the function name" && {
    _setup_slash
    slash_create "mytool" "" 2>/dev/null
    _test_out=$(cat "$SLASH_DIR/mytool.sh")
    assert_contains "$_test_out" "slash_mytool()"
    _teardown_slash
  }

  it "template is syntactically valid bash" && {
    _setup_slash
    slash_create "mytool" "" 2>/dev/null
    bash -n "$SLASH_DIR/mytool.sh"
    assert_ok $?
    _teardown_slash
  }

  it "template is executable" && {
    _setup_slash
    slash_create "mytool" "" 2>/dev/null
    [ -x "$SLASH_DIR/mytool.sh" ]
    assert_ok $?
    _teardown_slash
  }

  it "sanitizes name with special characters" && {
    _setup_slash
    _test_out=$(slash_create "my tool!" "" 2>&1)
    assert_contains "$_test_out" "Sanitized"
    _teardown_slash
  }

  it "rejects empty name after sanitization" && {
    _setup_slash
    slash_create "!!!" "" 2>/dev/null
    _test_rc=$?
    assert_fail $_test_rc
    _teardown_slash
  }

  it "converts hyphens to underscores in name" && {
    _setup_slash
    _test_out=$(slash_create "my-cool-tool" "" 2>&1)
    assert_contains "$_test_out" "Sanitized"
    assert_file_exists "$SLASH_DIR/my_cool_tool.sh"
    _teardown_slash
  }

  it "template with hyphens has valid bash function name" && {
    _setup_slash
    slash_create "bullet-hell-game" "" 2>/dev/null
    _test_out=$(cat "$SLASH_DIR/bullet_hell_game.sh")
    assert_contains "$_test_out" "slash_bullet_hell_game()"
    bash -n "$SLASH_DIR/bullet_hell_game.sh"
    assert_ok $?
    _teardown_slash
  }

# ═══════════════════════════════════════════════════════════════
# Run (execute) custom commands
# ═══════════════════════════════════════════════════════════════
describe "slash_run"

  it "runs a custom command" && {
    _setup_slash
    _create_test_command "testcmd"
    _test_out=$(slash_run "testcmd" "hello world" "." 2>/dev/null)
    assert_contains "$_test_out" "testcmd ran with args: hello world"
    _teardown_slash
  }

  it "fails for nonexistent command" && {
    _setup_slash
    slash_run "nonexistent" "" "." 2>/dev/null
    assert_fail $?
    _teardown_slash
  }

  it "fails when function is missing from script" && {
    _setup_slash
    mkdir -p "$SLASH_DIR"
    echo '#!/bin/bash' > "$SLASH_DIR/broken.sh"
    echo 'echo "no function here"' >> "$SLASH_DIR/broken.sh"
    slash_run "broken" "" "." 2>/dev/null
    assert_fail $?
    _teardown_slash
  }

  it "resolves hyphenated name to underscored file" && {
    _setup_slash
    _create_test_command "my_cool_cmd"
    _test_out=$(slash_run "my-cool-cmd" "fallback test" "." 2>/dev/null)
    assert_contains "$_test_out" "my_cool_cmd ran with args: fallback test"
    _teardown_slash
  }

# ═══════════════════════════════════════════════════════════════
# Test (validate) custom commands
# ═══════════════════════════════════════════════════════════════
describe "slash_test"

  it "validates a good command" && {
    _setup_slash
    _create_test_command "testcmd"
    _test_out=$(slash_test "testcmd" 2>&1)
    assert_contains "$_test_out" "Syntax OK"
    _teardown_slash
  }

  it "catches syntax errors" && {
    _setup_slash
    mkdir -p "$SLASH_DIR"
    echo '#!/bin/bash' > "$SLASH_DIR/badsyntax.sh"
    echo 'slash_badsyntax() {' >> "$SLASH_DIR/badsyntax.sh"
    echo '  if then fi' >> "$SLASH_DIR/badsyntax.sh"
    echo '}' >> "$SLASH_DIR/badsyntax.sh"
    _test_out=$(slash_test "badsyntax" 2>&1)
    assert_contains "$_test_out" "Syntax error"
    _teardown_slash
  }

  it "fails for nonexistent command" && {
    _setup_slash
    slash_test "nonexistent" 2>/dev/null
    assert_fail $?
    _teardown_slash
  }

# ═══════════════════════════════════════════════════════════════
# Show command source
# ═══════════════════════════════════════════════════════════════
describe "slash_show"

  it "displays command source" && {
    _setup_slash
    _create_test_command "testcmd"
    _test_out=$(slash_show "testcmd" 2>&1)
    assert_contains "$_test_out" "slash_testcmd()"
    _teardown_slash
  }

  it "fails for nonexistent command" && {
    _setup_slash
    slash_show "nonexistent" 2>/dev/null
    assert_fail $?
    _teardown_slash
  }

# ═══════════════════════════════════════════════════════════════
# Delete
# ═══════════════════════════════════════════════════════════════
describe "slash_delete"

  it "deletes a command when confirmed" && {
    _setup_slash
    _create_test_command "testcmd"
    # Mock ui_confirm to always return true
    test_mock "ui_confirm" "return 0"
    slash_delete "testcmd" 2>/dev/null
    assert_file_not_exists "$SLASH_DIR/testcmd.sh"
    test_unmock "ui_confirm"
    _teardown_slash
  }

  it "keeps command when not confirmed" && {
    _setup_slash
    _create_test_command "testcmd"
    test_mock "ui_confirm" "return 1"
    slash_delete "testcmd" 2>/dev/null
    assert_file_exists "$SLASH_DIR/testcmd.sh"
    test_unmock "ui_confirm"
    _teardown_slash
  }

# ═══════════════════════════════════════════════════════════════
# List
# ═══════════════════════════════════════════════════════════════
describe "slash_list"

  it "shows 'no custom commands' when empty" && {
    _setup_slash
    _test_out=$(slash_list 2>&1)
    assert_contains "$_test_out" "No custom commands"
    _teardown_slash
  }

  it "lists created commands" && {
    _setup_slash
    _create_test_command "testcmd"
    _test_out=$(slash_list 2>&1)
    assert_contains "$_test_out" "testcmd"
    _teardown_slash
  }

  it "shows description from header" && {
    _setup_slash
    _create_test_command "testcmd"
    _test_out=$(slash_list 2>&1)
    assert_contains "$_test_out" "A test command"
    _teardown_slash
  }

# ═══════════════════════════════════════════════════════════════
# Rename
# ═══════════════════════════════════════════════════════════════
describe "slash_rename"

  it "renames a command" && {
    _setup_slash
    _create_test_command "oldname"
    slash_rename "oldname" "newname" 2>/dev/null
    assert_file_exists "$SLASH_DIR/newname.sh"
    assert_file_not_exists "$SLASH_DIR/oldname.sh"
    _teardown_slash
  }

  it "updates function name inside script" && {
    _setup_slash
    _create_test_command "oldname"
    slash_rename "oldname" "newname" 2>/dev/null
    _test_out=$(cat "$SLASH_DIR/newname.sh")
    assert_contains "$_test_out" "slash_newname()"
    assert_not_contains "$_test_out" "slash_oldname()"
    _teardown_slash
  }

# ═══════════════════════════════════════════════════════════════
# Export
# ═══════════════════════════════════════════════════════════════
describe "slash_export"

  it "exports a command to a file" && {
    _setup_slash
    _create_test_command "testcmd"
    _test_out="$_test_tmpdir/exported.sh"
    slash_export "testcmd" "$_test_out" 2>/dev/null
    assert_file_exists "$_test_out"
    _teardown_slash
  }

  it "exported file is executable" && {
    _setup_slash
    _create_test_command "testcmd"
    _test_out="$_test_tmpdir/exported.sh"
    slash_export "testcmd" "$_test_out" 2>/dev/null
    [ -x "$_test_out" ]
    assert_ok $?
    _teardown_slash
  }

# ═══════════════════════════════════════════════════════════════
# Catalog (for LLM injection)
# ═══════════════════════════════════════════════════════════════
describe "slash_catalog"

  it "returns empty when no commands" && {
    _setup_slash
    _test_out=$(slash_catalog 2>/dev/null)
    assert_empty "$_test_out"
    _teardown_slash
  }

  it "includes custom commands in catalog" && {
    _setup_slash
    _create_test_command "testcmd"
    _test_out=$(slash_catalog 2>/dev/null)
    assert_contains "$_test_out" "/slash testcmd"
    assert_contains "$_test_out" "YOUR CUSTOM COMMANDS"
    _teardown_slash
  }

  it "includes description in catalog" && {
    _setup_slash
    _create_test_command "testcmd" "A test command"
    _test_out=$(slash_catalog 2>/dev/null)
    assert_contains "$_test_out" "A test command"
    _teardown_slash
  }

# ═══════════════════════════════════════════════════════════════
# Metadata extraction
# ═══════════════════════════════════════════════════════════════
describe "_slash_meta"

  it "extracts Description" && {
    _setup_slash
    _create_test_command "testcmd"
    _test_out=$(_slash_meta "$SLASH_DIR/testcmd.sh" "Description")
    assert_eq "$_test_out" "A test command"
    _teardown_slash
  }

  it "extracts Author" && {
    _setup_slash
    _create_test_command "testcmd"
    _test_out=$(_slash_meta "$SLASH_DIR/testcmd.sh" "Author")
    assert_eq "$_test_out" "George"
    _teardown_slash
  }

# ═══════════════════════════════════════════════════════════════
# Code extraction from LLM responses
# ═══════════════════════════════════════════════════════════════
describe "_slash_extract_code"

  it "extracts code from bash fenced block" && {
    _setup_slash
    _test_out=$(_slash_extract_code '
Some text
```bash
echo "hello"
```
More text')
    assert_contains "$_test_out" 'echo "hello"'
    _teardown_slash
  }

  it "extracts code from generic fenced block" && {
    _setup_slash
    _test_out=$(_slash_extract_code '
```
echo "hello"
```')
    assert_contains "$_test_out" 'echo "hello"'
    _teardown_slash
  }

  it "falls back to raw response if contains slash_" && {
    _setup_slash
    _test_out=$(_slash_extract_code 'slash_test() { echo hi; }')
    assert_contains "$_test_out" "slash_test"
    _teardown_slash
  }

# ═══════════════════════════════════════════════════════════════
# Recursive composition
# ═══════════════════════════════════════════════════════════════
describe "Recursive composition"

  it "custom command can call slash_run for another command" && {
    _setup_slash
    _create_test_command "inner" "Inner command"
    # Create an outer command that calls inner
    mkdir -p "$SLASH_DIR"
    cat > "$SLASH_DIR/outer.sh" << 'EOF'
#!/bin/bash
# Description: Outer command
# Author: George
slash_outer() {
    args="$1"
    workdir="${2:-.}"
    result=$(slash_run "inner" "from outer" "$workdir" 2>/dev/null)
    echo "outer got: $result"
}
EOF
    chmod +x "$SLASH_DIR/outer.sh"
    _test_out=$(slash_run "outer" "" "." 2>/dev/null)
    assert_contains "$_test_out" "outer got: inner ran with args: from outer"
    _teardown_slash
  }

test_end
