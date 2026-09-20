#!/bin/bash
# ── Tests: lib/transcript.sh ──────────────────────────────────
source "$(dirname "$0")/framework.sh"

# transcript.sh needs _transcript_ui to be available, and ui.sh needs it defined.
# Source transcript first (defines the functions), then ui.sh (calls them).
source "$LODGE_DIR/lib/transcript.sh"
source "$LODGE_DIR/lib/ui.sh"

test_start "lib/transcript.sh — Task Transcript Logging"

# ── Test workspace ─────────────────────────────────────────────
_TEST_WORKDIR=$(mktemp -d)
trap 'rm -rf "$_TEST_WORKDIR"' EXIT

# ── Core state ─────────────────────────────────────────────────
describe "Initial state"

  it "has no active transcript by default" && {
    assert_empty "$_TRANSCRIPT_FILE"
  }

  it "transcript_active returns false initially" && {
    transcript_active
    assert_fail $?
  }

  it "transcript_path returns empty string" && {
    p=$(transcript_path)
    assert_empty "$p"
  }

# ── transcript_start ──────────────────────────────────────────
describe "transcript_start"

  it "creates the transcript directory" && {
    transcript_start "test task" "$_TEST_WORKDIR"
    assert_dir_exists "$_TEST_WORKDIR/.george/transcripts"
    _TRANSCRIPT_FILE=""  # cleanup
  }

  it "sets _TRANSCRIPT_FILE" && {
    transcript_start "test task" "$_TEST_WORKDIR"
    assert_not_empty "$_TRANSCRIPT_FILE"
    saved="$_TRANSCRIPT_FILE"
    _TRANSCRIPT_FILE=""  # cleanup
    rm -f "$saved"
  }

  it "creates a .md file" && {
    transcript_start "test task" "$_TEST_WORKDIR"
    assert_file_exists "$_TRANSCRIPT_FILE"
    saved="$_TRANSCRIPT_FILE"
    _TRANSCRIPT_FILE=""
    rm -f "$saved"
  }

  it "writes header with task description" && {
    transcript_start "research quantum computing" "$_TEST_WORKDIR"
    content=$(cat "$_TRANSCRIPT_FILE")
    assert_contains "$content" "research quantum computing"
    saved="$_TRANSCRIPT_FILE"
    _TRANSCRIPT_FILE=""
    rm -f "$saved"
  }

  it "writes header with directory" && {
    transcript_start "test task" "$_TEST_WORKDIR"
    content=$(cat "$_TRANSCRIPT_FILE")
    assert_contains "$content" "$_TEST_WORKDIR"
    saved="$_TRANSCRIPT_FILE"
    _TRANSCRIPT_FILE=""
    rm -f "$saved"
  }

  it "includes model info in header" && {
    LODGE_MODEL="test-model:4b"
    transcript_start "test task" "$_TEST_WORKDIR"
    content=$(cat "$_TRANSCRIPT_FILE")
    assert_contains "$content" "test-model:4b"
    saved="$_TRANSCRIPT_FILE"
    _TRANSCRIPT_FILE=""
    rm -f "$saved"
  }

# ── transcript_log ─────────────────────────────────────────────
describe "transcript_log"

  it "does nothing when no transcript active" && {
    _TRANSCRIPT_FILE=""
    transcript_log "test" "should be ignored"
    # No file to check — just shouldn't error
    assert_ok 0
  }

  it "appends a tagged entry" && {
    transcript_start "test task" "$_TEST_WORKDIR"
    transcript_log "router" "/web"
    content=$(cat "$_TRANSCRIPT_FILE")
    assert_contains "$content" "**router:**"
    assert_contains "$content" "/web"
    saved="$_TRANSCRIPT_FILE"
    _TRANSCRIPT_FILE=""
    rm -f "$saved"
  }

  it "strips ANSI codes" && {
    transcript_start "test task" "$_TEST_WORKDIR"
    transcript_log "test" $'\033[38;5;75mcolored text\033[0m'
    content=$(cat "$_TRANSCRIPT_FILE")
    assert_contains "$content" "colored text"
    assert_not_contains "$content" "38;5;75"
    saved="$_TRANSCRIPT_FILE"
    _TRANSCRIPT_FILE=""
    rm -f "$saved"
  }

  it "includes timestamp" && {
    transcript_start "test task" "$_TEST_WORKDIR"
    transcript_log "info" "test message"
    content=$(cat "$_TRANSCRIPT_FILE")
    # Should have a HH:MM:SS pattern
    assert_match "$content" "[0-9][0-9]:[0-9][0-9]:[0-9][0-9]"
    saved="$_TRANSCRIPT_FILE"
    _TRANSCRIPT_FILE=""
    rm -f "$saved"
  }

# ── transcript_log_block ──────────────────────────────────────
describe "transcript_log_block"

  it "wraps content in code fences" && {
    transcript_start "test task" "$_TEST_WORKDIR"
    transcript_log_block "output" "line 1\nline 2\nline 3"
    content=$(cat "$_TRANSCRIPT_FILE")
    assert_contains "$content" '```'
    assert_contains "$content" "line 1"
    saved="$_TRANSCRIPT_FILE"
    _TRANSCRIPT_FILE=""
    rm -f "$saved"
  }

  it "includes tag name" && {
    transcript_start "test task" "$_TEST_WORKDIR"
    transcript_log_block "specialist" "/web search test"
    content=$(cat "$_TRANSCRIPT_FILE")
    assert_contains "$content" "**specialist:**"
    saved="$_TRANSCRIPT_FILE"
    _TRANSCRIPT_FILE=""
    rm -f "$saved"
  }

# ── transcript_section ────────────────────────────────────────
describe "transcript_section"

  it "writes a markdown section" && {
    transcript_start "test task" "$_TEST_WORKDIR"
    transcript_section "Milestone 1"
    content=$(cat "$_TRANSCRIPT_FILE")
    assert_contains "$content" "### Milestone 1"
    saved="$_TRANSCRIPT_FILE"
    _TRANSCRIPT_FILE=""
    rm -f "$saved"
  }

# ── transcript_stop ───────────────────────────────────────────
describe "transcript_stop"

  it "writes footer with end time" && {
    transcript_start "test task" "$_TEST_WORKDIR"
    saved="$_TRANSCRIPT_FILE"
    transcript_stop > /dev/null
    content=$(cat "$saved")
    assert_contains "$content" "**Ended:**"
    rm -f "$saved"
  }

  it "includes duration" && {
    transcript_start "test task" "$_TEST_WORKDIR"
    saved="$_TRANSCRIPT_FILE"
    sleep 1
    transcript_stop > /dev/null
    content=$(cat "$saved")
    assert_contains "$content" "**Duration:**"
    rm -f "$saved"
  }

  it "returns the file path" && {
    transcript_start "test task" "$_TEST_WORKDIR"
    saved="$_TRANSCRIPT_FILE"
    result=$(transcript_stop)
    assert_contains "$result" ".md"
    assert_eq "$result" "$saved"
    rm -f "$saved"
  }

  it "clears the active transcript" && {
    transcript_start "test task" "$_TEST_WORKDIR"
    transcript_stop > /dev/null
    assert_empty "$_TRANSCRIPT_FILE"
  }

# ── transcript_active ─────────────────────────────────────────
describe "transcript_active"

  it "returns true when active" && {
    transcript_start "test task" "$_TEST_WORKDIR"
    assert_ok $?
    _TRANSCRIPT_FILE=""
  }

  it "returns false when stopped" && {
    transcript_start "test task" "$_TEST_WORKDIR"
    transcript_stop > /dev/null
    transcript_active
    assert_fail $?
  }

# ── transcript_list ───────────────────────────────────────────
describe "transcript_list"

  it "shows recent transcripts" && {
    # Create a couple of transcripts
    _TEST_WORKDIR_LIST=$(mktemp -d)
    transcript_start "task one" "$_TEST_WORKDIR_LIST"
    transcript_log "info" "first task"
    transcript_stop > /dev/null
    sleep 1
    transcript_start "task two" "$_TEST_WORKDIR_LIST"
    transcript_log "info" "second task"
    transcript_stop > /dev/null

    listing=$(transcript_list "$_TEST_WORKDIR_LIST" 10)
    assert_contains "$listing" "task one"
    assert_contains "$listing" "task two"
    rm -rf "$_TEST_WORKDIR_LIST"
  }

  it "shows (no transcripts) when none exist" && {
    empty_dir=$(mktemp -d)
    listing=$(transcript_list "$empty_dir" 10)
    assert_contains "$listing" "(no transcripts)"
    rm -rf "$empty_dir"
  }

# ── transcript_last ───────────────────────────────────────────
describe "transcript_last"

  it "returns path to most recent transcript" && {
    last=$(transcript_last "$_TEST_WORKDIR")
    assert_not_empty "$last"
    assert_file_exists "$last"
  }

# ── UI hook integration ───────────────────────────────────────
describe "_transcript_ui via ui_ok"

  it "captures ui_ok output in transcript" && {
    transcript_start "ui hook test" "$_TEST_WORKDIR"
    ui_ok "operation succeeded" > /dev/null
    content=$(cat "$_TRANSCRIPT_FILE")
    assert_contains "$content" "operation succeeded"
    assert_contains "$content" "**ok:**"
    transcript_stop > /dev/null
  }

  it "captures ui_err output in transcript" && {
    transcript_start "ui hook test" "$_TEST_WORKDIR"
    ui_err "something failed" > /dev/null
    content=$(cat "$_TRANSCRIPT_FILE")
    assert_contains "$content" "something failed"
    assert_contains "$content" "**error:**"
    transcript_stop > /dev/null
  }

  it "captures ui_step output in transcript" && {
    transcript_start "ui hook test" "$_TEST_WORKDIR"
    ui_step "Running: /web search test" > /dev/null
    content=$(cat "$_TRANSCRIPT_FILE")
    assert_contains "$content" "/web search test"
    assert_contains "$content" "**step:**"
    transcript_stop > /dev/null
  }

# ── Zero overhead when inactive ────────────────────────────────
describe "Performance (inactive)"

  it "transcript_log is no-op when inactive" && {
    _TRANSCRIPT_FILE=""
    # Should complete without error and very quickly
    transcript_log "test" "ignored"
    transcript_log_block "test" "also ignored"
    transcript_section "ignored"
    assert_ok 0
  }

# ── Full lifecycle test ────────────────────────────────────────
describe "Full lifecycle"

  it "captures a complete task flow" && {
    transcript_start "build a REST API" "$_TEST_WORKDIR"
    ui_info "Planning task..." > /dev/null
    transcript_log "strategist" "Create project scaffold"
    transcript_section "Milestone 1"
    transcript_log "router" "/init"
    transcript_log_block "specialist" "/init python rest-api"
    ui_step "Running: /init python rest-api" > /dev/null
    transcript_log_block "output (exit 0)" "/init python rest-api\nProject created"
    ui_ok "Project initialized" > /dev/null
    transcript_section "Milestone 2"
    transcript_log "router" "/write"
    ui_step "Running: /write main.py" > /dev/null
    ui_ok "Task complete: 2/2 milestones succeeded" > /dev/null

    saved="$_TRANSCRIPT_FILE"
    result=$(transcript_stop)

    content=$(cat "$saved")

    # Verify structure
    assert_contains "$content" "# Task Transcript"
    assert_contains "$content" "**Task:** build a REST API"
    assert_contains "$content" "### Milestone 1"
    assert_contains "$content" "### Milestone 2"
    assert_contains "$content" "**router:**"
    assert_contains "$content" "**specialist:**"
    assert_contains "$content" "Project created"
    assert_contains "$content" "2/2 milestones succeeded"
    assert_contains "$content" "**Ended:**"
    assert_contains "$content" "**Duration:**"
  }

# ── Cleanup ────────────────────────────────────────────────────
rm -rf "$_TEST_WORKDIR"

test_end
