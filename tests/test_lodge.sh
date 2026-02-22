#!/bin/bash
# ── Tests: lodge (main script) ────────────────────────────────
# Tests command registration, version, REPL detection heuristic,
# and dependency checking.
source "$(dirname "$0")/framework.sh"

# Source all libs that lodge sources (same order)
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/llm.sh"
source "$LODGE_DIR/lib/memory.sh"
source "$LODGE_DIR/lib/tools.sh"
source "$LODGE_DIR/lib/agent.sh"
source "$LODGE_DIR/lib/commands.sh"
source "$LODGE_DIR/lib/sandbox.sh"
source "$LODGE_DIR/lib/container.sh"
source "$LODGE_DIR/lib/api.sh"
source "$LODGE_DIR/lib/social.sh"
source "$LODGE_DIR/lib/providers.sh"
source "$LODGE_DIR/lib/web.sh"
source "$LODGE_DIR/lib/backup.sh"
source "$LODGE_DIR/lib/journal.sh"

# Source the lodge script's functions (but don't run main)
# We extract the function definitions by sourcing in a subshell trick:
# The lodge script calls main "$@" at the end, so we mock main
# and source the whole file to get its function defs.
_original_main() { :; }
eval "$(sed 's/^main "$@"$//' "$LODGE_DIR/lodge" | grep -v '^set -uo pipefail')"

test_start "lodge — Main Script"

# ── Version ────────────────────────────────────────────────────
describe "Version"

  it "LODGE_VERSION is set" && {
    assert_not_empty "$LODGE_VERSION"
  }

  it "LODGE_VERSION is semver-like" && {
    assert_match "$LODGE_VERSION" "^[0-9]+\.[0-9]+\.[0-9]+"
  }

# ── Environment ────────────────────────────────────────────────
describe "Environment variables"

  it "LODGE_DIR is set" && {
    assert_not_empty "$LODGE_DIR"
  }

  it "LODGE_PROJECT is set" && {
    assert_not_empty "$LODGE_PROJECT"
  }

# ── Command Registration ──────────────────────────────────────
describe "Command registration"

  # Run registration
  _register_commands

  it "registers init command" && {
    commands_is_command "/init"
    assert_ok $?
  }

  it "registers plan command" && {
    commands_is_command "/plan"
    assert_ok $?
  }

  it "registers ask command" && {
    commands_is_command "/ask"
    assert_ok $?
  }

  it "registers compact command" && {
    commands_is_command "/compact"
    assert_ok $?
  }

  it "registers snapshot command" && {
    commands_is_command "/snapshot"
    assert_ok $?
  }

  it "registers memory command" && {
    commands_is_command "/memory"
    assert_ok $?
  }

  it "registers soul command" && {
    commands_is_command "/soul"
    assert_ok $?
  }

  it "registers status command" && {
    commands_is_command "/status"
    assert_ok $?
  }

  it "registers journal command" && {
    commands_is_command "/journal"
    assert_ok $?
  }

  it "registers sandbox command" && {
    commands_is_command "/sandbox"
    assert_ok $?
  }

  it "registers container command" && {
    commands_is_command "/container"
    assert_ok $?
  }

  it "registers api command" && {
    commands_is_command "/api"
    assert_ok $?
  }

  it "registers social command" && {
    commands_is_command "/social"
    assert_ok $?
  }

  it "registers provider command" && {
    commands_is_command "/provider"
    assert_ok $?
  }

  it "registers web command" && {
    commands_is_command "/web"
    assert_ok $?
  }

  it "registers backup command" && {
    commands_is_command "/backup"
    assert_ok $?
  }

  it "registers security command" && {
    commands_is_command "/security"
    assert_ok $?
  }

  it "registers readme command" && {
    commands_is_command "/readme"
    assert_ok $?
  }

  it "registers recall command" && {
    commands_is_command "/recall"
    assert_ok $?
  }

  it "registers clear command" && {
    commands_is_command "/clear"
    assert_ok $?
  }

  it "registers cd command" && {
    commands_is_command "/cd"
    assert_ok $?
  }

  it "registers files command" && {
    commands_is_command "/files"
    assert_ok $?
  }

  it "registers read command" && {
    commands_is_command "/read"
    assert_ok $?
  }

  it "registers secret command" && {
    commands_is_command "/secret"
    assert_ok $?
  }

  it "registers ingest command" && {
    commands_is_command "/ingest"
    assert_ok $?
  }

  it "registers gsuite command" && {
    commands_is_command "/gsuite"
    assert_ok $?
  }

  it "registers wallet command" && {
    commands_is_command "/wallet"
    assert_ok $?
  }

# ── REPL heuristic ────────────────────────────────────────────
describe "REPL question vs task heuristic"

  it "short input with ? is a question pattern" && {
    input="what is this?"
    wc=$(echo "$input" | wc -w)
    [[ "$wc" -le 6 ]] && [[ "$input" == *"?"* ]]
    assert_ok $?
  }

  it "long input is a task pattern" && {
    input="refactor the entire authentication module to use JWT tokens instead of sessions"
    wc=$(echo "$input" | wc -w)
    [[ "$wc" -le 6 ]] && [[ "$input" == *"?"* ]]
    assert_fail $?
  }

  it "short input without ? is a task pattern" && {
    input="fix the bug"
    wc=$(echo "$input" | wc -w)
    [[ "$wc" -le 6 ]] && [[ "$input" == *"?"* ]]
    assert_fail $?
  }

# ── Command handler functions ─────────────────────────────────
describe "Command handler functions"

  it "_cmd_memory handles missing CLAUDE.md" && {
    dir=$(test_tmpdir)
    output=$(_cmd_memory "" "$dir" 2>&1)
    assert_contains "$output" "No CLAUDE.md"
  }

  it "_cmd_memory shows existing CLAUDE.md" && {
    dir=$(test_tmpdir)
    echo "# Test Project" > "$dir/CLAUDE.md"
    output=$(_cmd_memory "" "$dir" 2>&1)
    assert_contains "$output" "Test Project"
  }

  it "_cmd_soul shows soul.md" && {
    output=$(_cmd_soul 2>&1)
    assert_not_empty "$output"
  }

  it "_cmd_clear is defined" && {
    declare -f _cmd_clear &>/dev/null
    assert_ok $?
  }

  it "_cmd_files is defined" && {
    declare -f _cmd_files &>/dev/null
    assert_ok $?
  }

  it "_cmd_read is defined" && {
    declare -f _cmd_read &>/dev/null
    assert_ok $?
  }

# ── Cancellation infrastructure ───────────────────────────────
describe "Cancellation infrastructure"

  it "_lodge_cleanup is defined" && {
    declare -f _lodge_cleanup &>/dev/null
    assert_ok $?
  }

  it "INT trap is set" && {
    traps=$(trap -p INT)
    assert_not_empty "$traps"
  }

test_end
