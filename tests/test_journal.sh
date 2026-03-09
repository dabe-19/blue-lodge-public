#!/bin/bash
# ── Tests: lib/journal.sh ─────────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/journal.sh"

test_start "lib/journal.sh — Temporal Memory"

TMPDIR_JOURNAL=""
ORIG_JOURNAL_FILE="${JOURNAL_FILE:-}"

_setup_journal() {
    TMPDIR_JOURNAL=$(test_tmpdir)
    ORIG_JOURNAL_FILE="${JOURNAL_FILE:-}"
    JOURNAL_FILE="$TMPDIR_JOURNAL/journal.md"
}

_teardown_journal() {
    JOURNAL_FILE="$ORIG_JOURNAL_FILE"
    rm -rf "$TMPDIR_JOURNAL"
}

# ── journal_init ───────────────────────────────────────────────
describe "journal_init"

  it "creates a new journal file" && {
    _setup_journal
    journal_init 2>/dev/null
    assert_file_exists "$JOURNAL_FILE"
    content=$(cat "$JOURNAL_FILE")
    assert_contains "$content" "Journal of George"
    assert_contains "$content" "Sediment"
    _teardown_journal
  }

  it "does not overwrite existing journal" && {
    _setup_journal
    echo "# My existing journal" > "$JOURNAL_FILE"
    journal_init 2>/dev/null
    content=$(cat "$JOURNAL_FILE")
    assert_contains "$content" "My existing journal"
    _teardown_journal
  }

# ── journal_write ──────────────────────────────────────────────
describe "journal_write"

  it "appends a timestamped entry" && {
    _setup_journal
    journal_init 2>/dev/null
    journal_write "reflection" "I learned something today."
    content=$(cat "$JOURNAL_FILE")
    assert_contains "$content" "reflection"
    assert_contains "$content" "I learned something today."
    # Header should have date format
    assert_match "$content" "[0-9]{4}-[0-9]{2}-[0-9]{2}"
    _teardown_journal
  }

  it "supports different entry types" && {
    _setup_journal
    journal_init 2>/dev/null
    journal_write "learning" "Functions are first-class in bash."
    journal_write "struggle" "AWK is hard."
    journal_write "beauty" "The sunset was code-colored."
    content=$(cat "$JOURNAL_FILE")
    assert_contains "$content" "learning"
    assert_contains "$content" "struggle"
    assert_contains "$content" "beauty"
    _teardown_journal
  }

# ── journal_write_failure ──────────────────────────────────────
describe "journal_write_failure"

  it "journal_write_failure is defined" && {
    _setup_journal
    declare -f journal_write_failure &>/dev/null
    assert_ok $?
    _teardown_journal
  }

  it "writes a structured failure entry" && {
    _setup_journal
    journal_init 2>/dev/null
    journal_write_failure "/slash create broken-cmd" "Function not found" "build a game"
    content=$(cat "$JOURNAL_FILE")
    assert_contains "$content" "task_failure"
    assert_contains "$content" "FAILED: /slash create broken-cmd"
    assert_contains "$content" "Error: Function not found"
    assert_contains "$content" "Task: build a game"
    _teardown_journal
  }

  it "works without task context" && {
    _setup_journal
    journal_init 2>/dev/null
    journal_write_failure "/build" "No build command found"
    content=$(cat "$JOURNAL_FILE")
    assert_contains "$content" "FAILED: /build"
    assert_contains "$content" "Error: No build command found"
    assert_not_contains "$content" "Task:"
    _teardown_journal
  }

  it "counts as a journal entry" && {
    _setup_journal
    journal_init 2>/dev/null
    journal_write_failure "/test" "test failed"
    count=$(journal_count)
    assert_eq "$count" "1"
    _teardown_journal
  }

# ── journal_count ──────────────────────────────────────────────
describe "journal_count"

  it "counts entries in journal" && {
    _setup_journal
    journal_init 2>/dev/null
    journal_write "reflection" "Entry 1"
    journal_write "learning" "Entry 2"
    journal_write "beauty" "Entry 3"
    count=$(journal_count)
    assert_eq "$count" "3"
    _teardown_journal
  }

  it "returns 0 for empty journal" && {
    _setup_journal
    journal_init 2>/dev/null
    count=$(journal_count)
    assert_eq "$count" "0"
    _teardown_journal
  }

# ── journal_read (with decay) ─────────────────────────────────
describe "journal_read"

  it "returns journal output header" && {
    _setup_journal
    journal_init 2>/dev/null
    journal_write "reflection" "Test entry for read."
    output=$(journal_read 800)
    assert_contains "$output" "JOURNAL"
    _teardown_journal
  }

  it "includes recent entries in vivid section" && {
    _setup_journal
    journal_init 2>/dev/null
    journal_write "reflection" "This is a fresh entry."
    output=$(journal_read 800)
    assert_contains "$output" "This is a fresh entry."
    _teardown_journal
  }

# ── journal_greeting ──────────────────────────────────────────
describe "journal_greeting"

  it "gives first session greeting when journal is empty" && {
    _setup_journal
    journal_init 2>/dev/null
    greeting=$(journal_greeting)
    assert_contains "$greeting" "first"
    _teardown_journal
  }

  it "mentions entry count for returning user" && {
    _setup_journal
    journal_init 2>/dev/null
    journal_write "reflection" "entry 1"
    journal_write "learning" "entry 2"
    greeting=$(journal_greeting)
    assert_match "$greeting" "[0-9]"
    _teardown_journal
  }

# ── journal_show ───────────────────────────────────────────────
describe "journal_show"

  it "shows journal without error" && {
    _setup_journal
    journal_init 2>/dev/null
    journal_write "reflection" "show test"
    out=$(journal_show 2>&1)
    assert_ok $?
    _teardown_journal
  }

# ── Decay parameters ──────────────────────────────────────────
describe "Decay constants"

  it "DECAY_VIVID_DAYS is set" && {
    _setup_journal
    assert_eq "$DECAY_VIVID_DAYS" "3"
    _teardown_journal
  }

  it "DECAY_FADING_DAYS is set" && {
    _setup_journal
    assert_eq "$DECAY_FADING_DAYS" "14"
    _teardown_journal
  }

  it "DECAY_SEDIMENT_DAYS is set" && {
    _setup_journal
    assert_eq "$DECAY_SEDIMENT_DAYS" "60"
    _teardown_journal
  }

# ── journal_get_old_entries ────────────────────────────────────
describe "journal_get_old_entries"

  it "returns empty for fresh journal with recent entries" && {
    _setup_journal
    journal_init 2>/dev/null
    journal_write "reflection" "brand new entry"
    # Use a cutoff far in the past so today's entry is NOT old
    cutoff=$(date -d "2020-01-01" +%s 2>/dev/null || echo 0)
    result=$(journal_get_old_entries "$cutoff")
    # Recent entry should NOT be "old" (its epoch is after the cutoff)
    assert_not_contains "$result" "brand new entry"
    _teardown_journal
  }

# ── journal_reflect prompt ─────────────────────────────────────
describe "journal_reflect prompt"

  it "journal_reflect asks for specific factual entries" && {
    _setup_journal
    body=$(declare -f journal_reflect)
    echo "$body" | grep -q "ONLY reference steps"
    assert_ok $?
    _teardown_journal
  }

  it "journal_reflect does not ask for poetry" && {
    _setup_journal
    body=$(declare -f journal_reflect)
    # Old prompt asked to "Speak as a craftsman reflecting at the end of the day"
    echo "$body" | grep -q "craftsman reflecting"
    assert_fail $?
    _teardown_journal
  }

  it "journal_reflect includes current timestamp in prompt" && {
    _setup_journal
    body=$(declare -f journal_reflect)
    echo "$body" | grep -q 'Current date/time'
    assert_ok $?
    _teardown_journal
  }

# ── ANSI stripping ────────────────────────────────────────────
describe "ANSI escape code stripping"

  it "strips terminal color codes from journal entries" && {
    _setup_journal
    journal_init 2>/dev/null
    journal_write "web_search" $'\x1b[38;5;203m✗ \x1b[38;5;255mSearch failed: timeout\x1b[0m'
    content=$(cat "$JOURNAL_FILE")
    assert_contains "$content" "Search failed: timeout"
    # Must NOT contain raw escape codes
    if printf '%s' "$content" | grep -q $'\x1b\['; then
      assert_ok 1  # fail — escape codes still present
    else
      assert_ok 0
    fi
    _teardown_journal
  }

test_end
