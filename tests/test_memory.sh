#!/bin/bash
# ── Tests: lib/memory.sh ──────────────────────────────────────
source "$(dirname "$0")/framework.sh"

# Memory.sh sources ui.sh internally
source "$LODGE_DIR/lib/memory.sh"

test_start "lib/memory.sh — Memory System"

TMPDIR_MEM=""

_setup_mem() {
    TMPDIR_MEM=$(test_tmpdir)
}

_teardown_mem() {
    rm -rf "$TMPDIR_MEM"
}

# ── memory_read_soul ───────────────────────────────────────────
describe "memory_read_soul"

  it "reads soul.md from LODGE_DIR" && {
    result=$(memory_read_soul)
    assert_not_empty "$result"
    # soul.md should contain George's name
    assert_contains "$result" "George"
  }

  it "returns fallback if soul.md is missing" && {
    orig="$LODGE_DIR"
    LODGE_DIR="/tmp/fake-nonexistent"
    result=$(memory_read_soul)
    LODGE_DIR="$orig"
    assert_contains "$result" "George"
  }

# ── memory_init ────────────────────────────────────────────────
describe "memory_init"

  it "creates CLAUDE.md with project name" && {
    _setup_mem
    memory_init "$TMPDIR_MEM" "TestProject" "Rust" "cargo build" "cargo test" >/dev/null 2>&1
    assert_file_exists "$TMPDIR_MEM/CLAUDE.md"
    content=$(cat "$TMPDIR_MEM/CLAUDE.md")
    assert_contains "$content" "TestProject"
    assert_contains "$content" "Rust"
    assert_contains "$content" "cargo build"
    assert_contains "$content" "cargo test"
    _teardown_mem
  }

  it "creates CLAUDE.md with defaults" && {
    _setup_mem
    memory_init "$TMPDIR_MEM" >/dev/null 2>&1
    assert_file_exists "$TMPDIR_MEM/CLAUDE.md"
    _teardown_mem
  }

# ── memory_read_project ───────────────────────────────────────
describe "memory_read_project"

  it "reads CLAUDE.md from a directory" && {
    _setup_mem
    echo "# Test Project" > "$TMPDIR_MEM/CLAUDE.md"
    result=$(memory_read_project "$TMPDIR_MEM")
    assert_contains "$result" "Test Project"
    _teardown_mem
  }

  it "returns empty for missing CLAUDE.md" && {
    _setup_mem
    result=$(memory_read_project "$TMPDIR_MEM")
    assert_empty "$result"
    _teardown_mem
  }

# ── memory_get_section ─────────────────────────────────────────
describe "memory_get_section"

  it "extracts a section from CLAUDE.md" && {
    _setup_mem
    memory_init "$TMPDIR_MEM" "Test" "Shell" "bash run.sh" "bash test.sh" >/dev/null 2>&1
    result=$(memory_get_section "Type" "$TMPDIR_MEM")
    assert_contains "$result" "Shell"
    _teardown_mem
  }

  it "extracts Build section" && {
    _setup_mem
    memory_init "$TMPDIR_MEM" "Test" "Rust" "cargo build" "cargo test" >/dev/null 2>&1
    result=$(memory_get_section "Build" "$TMPDIR_MEM")
    assert_contains "$result" "cargo build"
    _teardown_mem
  }

  it "returns empty for missing section" && {
    _setup_mem
    memory_init "$TMPDIR_MEM" "Test" >/dev/null 2>&1
    result=$(memory_get_section "NonExistentSection" "$TMPDIR_MEM")
    assert_empty "$result"
    _teardown_mem
  }

# ── memory_update_section ─────────────────────────────────────
describe "memory_update_section"

  it "replaces section content" && {
    _setup_mem
    memory_init "$TMPDIR_MEM" "Test" >/dev/null 2>&1
    memory_update_section "Current Task" "Build the API" "$TMPDIR_MEM"
    result=$(memory_get_section "Current Task" "$TMPDIR_MEM")
    assert_contains "$result" "Build the API"
    _teardown_mem
  }

  it "returns error for missing file" && {
    _setup_mem
    memory_update_section "Current Task" "nope" "$TMPDIR_MEM" 2>/dev/null
    assert_fail $?
    _teardown_mem
  }

# ── memory_append_section ─────────────────────────────────────
describe "memory_append_section"

  it "appends to a section" && {
    _setup_mem
    memory_init "$TMPDIR_MEM" "Test" >/dev/null 2>&1
    memory_append_section "Completed Steps" "Step 1 done" "$TMPDIR_MEM"
    memory_append_section "Completed Steps" "Step 2 done" "$TMPDIR_MEM"
    result=$(memory_get_section "Completed Steps" "$TMPDIR_MEM")
    assert_contains "$result" "Step 1 done"
    assert_contains "$result" "Step 2 done"
    _teardown_mem
  }

  it "replaces (none) placeholder" && {
    _setup_mem
    memory_init "$TMPDIR_MEM" "Test" >/dev/null 2>&1
    memory_append_section "Current Task" "New task" "$TMPDIR_MEM"
    result=$(memory_get_section "Current Task" "$TMPDIR_MEM")
    assert_not_contains "$result" "(none)"
    assert_contains "$result" "New task"
    _teardown_mem
  }

# ── memory_compact ─────────────────────────────────────────────
describe "memory_compact"

  it "compacts when more than 10 steps" && {
    _setup_mem
    memory_init "$TMPDIR_MEM" "Test" >/dev/null 2>&1
    for i in $(seq 1 15); do
        memory_append_section "Completed Steps" "Step $i complete" "$TMPDIR_MEM"
    done
    memory_compact "$TMPDIR_MEM" >/dev/null 2>&1
    result=$(memory_get_section "Completed Steps" "$TMPDIR_MEM")
    assert_contains "$result" "compacted"
    assert_contains "$result" "Step 15"
    _teardown_mem
  }

  it "does nothing with few steps" && {
    _setup_mem
    memory_init "$TMPDIR_MEM" "Test" >/dev/null 2>&1
    memory_append_section "Completed Steps" "Step 1" "$TMPDIR_MEM"
    memory_compact "$TMPDIR_MEM" >/dev/null 2>&1
    result=$(memory_get_section "Completed Steps" "$TMPDIR_MEM")
    assert_not_contains "$result" "compacted"
    _teardown_mem
  }

# ── memory_snapshot ────────────────────────────────────────────
describe "memory_snapshot"

  it "creates a timestamped snapshot" && {
    _setup_mem
    memory_init "$TMPDIR_MEM" "Test" >/dev/null 2>&1
    memory_snapshot "$TMPDIR_MEM" >/dev/null 2>&1
    assert_dir_exists "$TMPDIR_MEM/.lodge-snapshots"
    snapshot_count=$(ls "$TMPDIR_MEM/.lodge-snapshots/" 2>/dev/null | wc -l)
    assert_gt "$snapshot_count" 0
    _teardown_mem
  }

# ── memory_build_system_prompt ─────────────────────────────────
describe "memory_build_system_prompt"

  it "includes soul.md content" && {
    _setup_mem
    prompt=$(memory_build_system_prompt "$TMPDIR_MEM")
    assert_contains "$prompt" "George"
    _teardown_mem
  }

  it "includes CLAUDE.md when present" && {
    _setup_mem
    memory_init "$TMPDIR_MEM" "PromptTest" >/dev/null 2>&1
    prompt=$(memory_build_system_prompt "$TMPDIR_MEM")
    assert_contains "$prompt" "PromptTest"
    _teardown_mem
  }

# ── Lean prompt mode (ask) ───────────────────────────────────
describe "memory_build_system_prompt lean mode"

  it "returns lean prompt for ask mode" && {
    _setup_mem
    prompt=$(memory_build_system_prompt "$TMPDIR_MEM" "hello" "ask")
    assert_contains "$prompt" "George"
    assert_contains "$prompt" "concisely"
    _teardown_mem
  }

  it "lean prompt does NOT include full soul.md" && {
    _setup_mem
    prompt=$(memory_build_system_prompt "$TMPDIR_MEM" "hello" "ask")
    # Full soul.md has Impartial Spectator — lean should not
    assert_not_contains "$prompt" "Impartial Spectator"
    _teardown_mem
  }

  it "lean prompt is much shorter than full prompt" && {
    _setup_mem
    _lean=$(memory_build_system_prompt "$TMPDIR_MEM" "hello" "ask")
    _full=$(memory_build_system_prompt "$TMPDIR_MEM" "hello" "task")
    _lean_len=${#_lean}
    _full_len=${#_full}
    # Lean should be less than half the size of full
    assert_gt "$_full_len" "$_lean_len"
    _teardown_mem
  }

# ── Plan prompt mode ─────────────────────────────────────────
describe "memory_build_system_prompt plan mode"

  it "returns plan prompt with George identity" && {
    _setup_mem
    prompt=$(memory_build_system_prompt "$TMPDIR_MEM" "" "plan")
    assert_contains "$prompt" "George"
    _teardown_mem
  }

  it "task prompt is the largest of the three modes" && {
    _setup_mem
    _ask=$(memory_build_system_prompt "$TMPDIR_MEM" "hello" "ask")
    _plan=$(memory_build_system_prompt "$TMPDIR_MEM" "" "plan")
    _full=$(memory_build_system_prompt "$TMPDIR_MEM" "hello" "task")
    _ask_len=${#_ask}
    _plan_len=${#_plan}
    _full_len=${#_full}
    assert_gt "$_full_len" "$_ask_len"
    assert_gt "$_full_len" "$_plan_len"
    _teardown_mem
  }

# ── Soul mode toggle ─────────────────────────────────────────
describe "memory_build_system_prompt soul mode"

  it "LODGE_SOUL=1 includes full soul.md (Impartial Spectator)" && {
    _setup_mem
    LODGE_SOUL=1
    prompt=$(memory_build_system_prompt "$TMPDIR_MEM" "hello" "task")
    assert_contains "$prompt" "Impartial Spectator"
    LODGE_SOUL=0
    _teardown_mem
  }

  it "LODGE_SOUL=0 excludes philosophy sections" && {
    _setup_mem
    LODGE_SOUL=0
    prompt=$(memory_build_system_prompt "$TMPDIR_MEM" "hello" "task")
    # Practical Craft should be present, but not the deep philosophy
    assert_contains "$prompt" "Practical Craft"
    _teardown_mem
  }

  it "soul mode ON produces larger prompt than OFF" && {
    _setup_mem
    LODGE_SOUL=1
    _on=$(memory_build_system_prompt "$TMPDIR_MEM" "hello" "task")
    LODGE_SOUL=0
    _off=$(memory_build_system_prompt "$TMPDIR_MEM" "hello" "task")
    _on_len=${#_on}
    _off_len=${#_off}
    assert_gt "$_on_len" "$_off_len"
    LODGE_SOUL=0
    _teardown_mem
  }

  it "plan prompt does NOT include journal" && {
    _setup_mem
    prompt=$(memory_build_system_prompt "$TMPDIR_MEM" "" "plan")
    assert_not_contains "$prompt" "JOURNAL"
    _teardown_mem
  }

# ── Plan prompt command glossary ──────────────────────────────
describe "memory_build_system_prompt plan mode command glossary"

  it "plan prompt warns not to invent commands" && {
    _setup_mem
    prompt=$(memory_build_system_prompt "$TMPDIR_MEM" "" "plan")
    assert_contains "$prompt" "NOT invent commands"
    _teardown_mem
  }

  it "plan prompt falls back to compact list when commands_catalog is unavailable" && {
    _setup_mem
    if declare -f commands_catalog &>/dev/null; then
      test_mock commands_catalog 'return 1'
      prompt=$(memory_build_system_prompt "$TMPDIR_MEM" "" "plan")
      test_unmock commands_catalog
    else
      prompt=$(memory_build_system_prompt "$TMPDIR_MEM" "" "plan")
    fi
    assert_contains "$prompt" "COMMANDS"
    _teardown_mem
  }

  it "plan prompt includes full command syntax when commands_catalog is loaded" && {
    _setup_mem
    source "$LODGE_DIR/lib/commands.sh"
    if ! declare -f commands_catalog &>/dev/null; then
      skip "commands_catalog failed to load from commands.sh"
    else
      prompt=$(memory_build_system_prompt "$TMPDIR_MEM" "" "plan")
      assert_contains "$prompt" "/web search <query>"
      assert_contains "$prompt" "/save <file>"
    fi
    _teardown_mem
  }

describe "memory_build_system_prompt system clock"

  it "all modes include current time" && {
    _setup_mem
    for mode in ask plan task; do
      prompt=$(memory_build_system_prompt "$TMPDIR_MEM" "test" "$mode")
      assert_contains "$prompt" "[Current time:"
    done
    _teardown_mem
  }

  it "timestamp includes day of week and year" && {
    _setup_mem
    prompt=$(memory_build_system_prompt "$TMPDIR_MEM" "" "ask")
    # Should contain the current year
    assert_contains "$prompt" "$(date +%Y)"
    _teardown_mem
  }

test_end
