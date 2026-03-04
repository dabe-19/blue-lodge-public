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
ui_warn() { echo "ui_warn: $*"; }
ui_section() { echo "ui_section: $*"; }
ui_confirm() { return 0; }
# Stub out tools that create real project files
cargo() { mkdir -p src 2>/dev/null; touch Cargo.toml 2>/dev/null; }
git() { :; }
uv() { :; }
python3() { :; }

source "$LODGE_DIR/commands/init.sh"

# Run cmd_init in a temporary directory to avoid polluting the repo
_init_in_tmpdir() {
    tmpdir=$(test_tmpdir)
    (
        cd "$tmpdir"
        cmd_init "$@"
    )
    rc=$?
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

  it "errors on truly unknown type in two-arg form" && {
    out=$(_init_in_tmpdir "myapp zzzznotreal" 2>&1)
    assert_contains "$out" "Unknown type"
  }

# ── Invalid project name ───────────────────────────────────────
describe "invalid project name"

  it "errors when prompted name is invalid for type keyword form" && {
    out=$(echo "5" | _init_in_tmpdir "rust" 2>&1)
    assert_contains "$out" "Invalid project name"
  }

# ═══════════════════════════════════════════════════════════════
# Fuzzy type resolution
# ═══════════════════════════════════════════════════════════════
describe "fuzzy type resolver — _init_resolve_type"

  it "resolves exact 'rust' without guessing" && {
    _init_resolve_type "rust"
    assert_eq "$_INIT_RESOLVED_TYPE" "rust"
    assert_eq "$_INIT_TYPE_GUESSED" "0"
  }

  it "resolves exact 'shell' without guessing" && {
    _init_resolve_type "shell"
    assert_eq "$_INIT_RESOLVED_TYPE" "shell"
    assert_eq "$_INIT_TYPE_GUESSED" "0"
  }

  it "fuzzy-matches 'rs' → rust" && {
    _init_resolve_type "rs"
    assert_eq "$_INIT_RESOLVED_TYPE" "rust"
    assert_eq "$_INIT_TYPE_GUESSED" "1"
  }

  it "fuzzy-matches 'rustlang' → rust" && {
    _init_resolve_type "rustlang"
    assert_eq "$_INIT_RESOLVED_TYPE" "rust"
    assert_eq "$_INIT_TYPE_GUESSED" "1"
  }

  it "fuzzy-matches 'cargo' → rust" && {
    _init_resolve_type "cargo"
    assert_eq "$_INIT_RESOLVED_TYPE" "rust"
    assert_eq "$_INIT_TYPE_GUESSED" "1"
  }

  it "fuzzy-matches 'py' → data" && {
    _init_resolve_type "py"
    assert_eq "$_INIT_RESOLVED_TYPE" "data"
    assert_eq "$_INIT_TYPE_GUESSED" "1"
  }

  it "fuzzy-matches 'python3' → data" && {
    _init_resolve_type "python3"
    assert_eq "$_INIT_RESOLVED_TYPE" "data"
    assert_eq "$_INIT_TYPE_GUESSED" "1"
  }

  it "fuzzy-matches 'bash' → shell" && {
    _init_resolve_type "bash"
    assert_eq "$_INIT_RESOLVED_TYPE" "shell"
    assert_eq "$_INIT_TYPE_GUESSED" "1"
  }

  it "fuzzy-matches 'gymnasium' → rl" && {
    _init_resolve_type "gymnasium"
    assert_eq "$_INIT_RESOLVED_TYPE" "rl"
    assert_eq "$_INIT_TYPE_GUESSED" "1"
  }

  it "fuzzy-matches 'scraper' → automation" && {
    _init_resolve_type "scraper"
    assert_eq "$_INIT_RESOLVED_TYPE" "automation"
    assert_eq "$_INIT_TYPE_GUESSED" "1"
  }

  it "fuzzy-matches 'ipynb' → notebook" && {
    _init_resolve_type "ipynb"
    assert_eq "$_INIT_RESOLVED_TYPE" "notebook"
    assert_eq "$_INIT_TYPE_GUESSED" "1"
  }

  it "fuzzy-matches 'jupyter-notebook' → notebook" && {
    _init_resolve_type "jupyter-notebook"
    assert_eq "$_INIT_RESOLVED_TYPE" "notebook"
    assert_eq "$_INIT_TYPE_GUESSED" "1"
  }

  it "fails on completely unknown input" && {
    _init_resolve_type "zzzznotreal"
    assert_fail $?
    assert_empty "$_INIT_RESOLVED_TYPE"
  }

describe "fuzzy type in /init invocation"

  it "fuzzy 'rs' as sole arg prompts name and scaffolds" && {
    out=$(echo "myapp" | _init_in_tmpdir "rs" 2>&1)
    assert_contains "$out" "best guess"
    [[ "$out" != *"Unknown type"* ]]
    assert_ok $?
  }

  it "fuzzy 'cargo' as type in two-arg form" && {
    out=$(_init_in_tmpdir "myapp cargo" 2>&1)
    assert_contains "$out" "best guess"
    [[ "$out" != *"Unknown type"* ]]
    assert_ok $?
  }

  it "detects swapped args: 'rust myapp' → name=myapp type=rust" && {
    out=$(_init_in_tmpdir "rust myapp" 2>&1)
    # rust is a type keyword, myapp is a name → should swap
    assert_contains "$out" "swapped"
    [[ "$out" != *"Unknown type"* ]]
    assert_ok $?
  }

test_end
