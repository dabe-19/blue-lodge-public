#!/bin/bash
# ── Tests: commands/init.sh ────────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"

# Stub out dependencies used by cmd_init to avoid real project creation
memory_init() { :; }
ui_step() { echo "ui_step: $*"; }
ui_ok() { echo "ui_ok: $*"; }
ui_dim() { echo "ui_dim: $*"; }
ui_err() { echo "ui_err: $*" >&2; }
ui_section() { echo "ui_section: $*"; }
# Stub out tools that create real project files
cargo() { mkdir -p "$2/src" 2>/dev/null; touch "$2/Cargo.toml" 2>/dev/null; }
git() { :; }
uv() { :; }
python3() { :; }

source "$LODGE_DIR/commands/init.sh"

# Run cmd_init in a temporary directory to avoid polluting the repo
_init_in_tmpdir() {
    local tmpdir
    tmpdir=$(test_tmpdir)
    (
        cd "$tmpdir"
        cmd_init "$@"
    )
    local rc=$?
    rm -rf "$tmpdir"
    return $rc
}

test_start "commands/init.sh — /init argument handling"

# ── Type keyword detection ─────────────────────────────────────
describe "type-keyword as sole argument"

  it "detects 'rust' as a type keyword and prompts for name" && {
    # Simulate /init rust with "myapp" supplied at the name prompt
    out=$(echo "myapp" | _init_in_tmpdir "rust" 2>&1)
    # Should not error about unknown type
    [[ "$out" != *"Unknown type"* ]]
    assert_ok $?
  }

  it "detects 'python' as a type keyword" && {
    out=$(echo "myapp" | _init_in_tmpdir "python" 2>&1)
    [[ "$out" != *"Unknown type"* ]]
    assert_ok $?
  }

  it "detects 'shell' as a type keyword" && {
    out=$(echo "myapp" | _init_in_tmpdir "shell" 2>&1)
    [[ "$out" != *"Unknown type"* ]]
    assert_ok $?
  }

  it "detects 'rl' as a type keyword" && {
    out=$(echo "myapp" | _init_in_tmpdir "rl" 2>&1)
    [[ "$out" != *"Unknown type"* ]]
    assert_ok $?
  }

# ── Unknown type still errors ──────────────────────────────────
describe "unknown type argument"

  it "errors on unknown type in two-arg form" && {
    out=$(_init_in_tmpdir "myapp unknowntype" 2>&1)
    assert_contains "$out" "Unknown type"
  }

# ── Invalid project name ───────────────────────────────────────
describe "invalid project name"

  it "errors when prompted name is invalid for type keyword form" && {
    out=$(echo "5" | _init_in_tmpdir "rust" 2>&1)
    assert_contains "$out" "Invalid project name"
  }

test_end
