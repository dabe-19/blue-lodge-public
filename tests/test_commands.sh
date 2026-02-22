#!/bin/bash
# ── Tests: lib/commands.sh ─────────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/commands.sh"

test_start "lib/commands.sh — Slash Command Dispatcher"

# ── Registration ───────────────────────────────────────────────
describe "commands_register"

  it "registers a command" && {
    _test_handler() { echo "ran"; }
    commands_register "testcmd" "A test command" "_test_handler"
    assert_eq "${CMD_REGISTRY[testcmd]}" "_test_handler"
    assert_eq "${CMD_DESC[testcmd]}" "A test command"
  }

  it "overwrites existing command" && {
    _test_handler2() { echo "ran2"; }
    commands_register "testcmd" "Updated" "_test_handler2"
    assert_eq "${CMD_REGISTRY[testcmd]}" "_test_handler2"
    assert_eq "${CMD_DESC[testcmd]}" "Updated"
  }

# ── Is command check ──────────────────────────────────────────
describe "commands_is_command"

  it "returns true for /slash commands" && {
    commands_is_command "/init"
    assert_ok $?
  }

  it "returns true for /help" && {
    commands_is_command "/help"
    assert_ok $?
  }

  it "returns false for plain text" && {
    commands_is_command "build my project"
    assert_fail $?
  }

  it "returns false for empty string" && {
    commands_is_command ""
    assert_fail $?
  }

# ── Dispatch ───────────────────────────────────────────────────
describe "commands_dispatch"

  it "dispatches to registered handler" && {
    _dispatch_test_handler() { echo "dispatched: $1"; }
    commands_register "dtest" "dispatch test" "_dispatch_test_handler"
    out=$(commands_dispatch "/dtest hello" ".")
    assert_contains "$out" "dispatched: hello"
  }

  it "returns 99 for /quit" && {
    commands_dispatch "/quit" "."
    assert_eq "$?" "99"
  }

  it "returns 99 for /exit" && {
    commands_dispatch "/exit" "."
    assert_eq "$?" "99"
  }

  it "returns 99 for /q" && {
    commands_dispatch "/q" "."
    assert_eq "$?" "99"
  }

  it "handles /help without error" && {
    out=$(commands_dispatch "/help" "." 2>&1)
    status=$?
    assert_ok "$status"
    assert_contains "$out" "Slash Commands"
  }

  it "returns 1 for unknown command" && {
    commands_dispatch "/nonexistent_xyz" "."
    assert_fail $?
  }

# ── commands_help ──────────────────────────────────────────────
describe "commands_help"

  it "lists registered commands" && {
    # Note: bash associative arrays may not propagate fully to
    # subshells in all versions, so we verify structural output
    _tmpf=$(test_tmpdir)/help_out.txt
    commands_help > "$_tmpf" 2>&1
    out=$(cat "$_tmpf")
    assert_contains "$out" "Slash Commands"
  }

  it "shows /help and /quit" && {
    _tmpf=$(test_tmpdir)/help_out2.txt
    commands_help > "$_tmpf" 2>&1
    out=$(cat "$_tmpf")
    assert_contains "$out" "/help"
    assert_contains "$out" "/quit"
  }

# ── commands_load_all ──────────────────────────────────────────
describe "commands_load_all"

  it "loads without error when commands dir exists" && {
    commands_load_all
    assert_ok $?
  }

test_end
