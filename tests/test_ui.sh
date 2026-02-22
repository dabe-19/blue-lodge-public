#!/bin/bash
# ── Tests: lib/ui.sh ──────────────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"

test_start "lib/ui.sh — UI Rendering"

# ── Color exports ──────────────────────────────────────────────
describe "Color constants"

  it "exports C_RESET" && {
    assert_not_empty "$C_RESET"
  }

  it "exports C_BOLD" && {
    assert_not_empty "$C_BOLD"
  }

  it "exports C_BLUE" && {
    assert_contains "$C_BLUE" "38;5;75"
  }

  it "exports C_LODGE" && {
    assert_contains "$C_LODGE" "38;5;33"
  }

# ── Symbol exports ─────────────────────────────────────────────
describe "Symbol constants"

  it "exports SYM_CHECK" && {
    assert_eq "$SYM_CHECK" "✓"
  }

  it "exports SYM_CROSS" && {
    assert_eq "$SYM_CROSS" "✗"
  }

  it "exports SYM_LODGE" && {
    assert_eq "$SYM_LODGE" "⌂"
  }

# ── Print functions ────────────────────────────────────────────
describe "ui_print"

  it "outputs text" && {
    out=$(ui_print "hello world")
    assert_contains "$out" "hello world"
  }

describe "ui_info"

  it "outputs info with dot symbol" && {
    out=$(ui_info "test message")
    assert_contains "$out" "test message"
  }

describe "ui_ok"

  it "outputs success with check symbol" && {
    out=$(ui_ok "done")
    assert_contains "$out" "done"
  }

describe "ui_warn"

  it "outputs warning" && {
    out=$(ui_warn "caution")
    assert_contains "$out" "caution"
  }

describe "ui_err"

  it "outputs error" && {
    out=$(ui_err "failure")
    assert_contains "$out" "failure"
  }

describe "ui_step"

  it "outputs step with arrow" && {
    out=$(ui_step "next step")
    assert_contains "$out" "next step"
  }

describe "ui_think"

  it "outputs thinking indicator" && {
    out=$(ui_think "processing")
    assert_contains "$out" "processing"
  }

describe "ui_dim"

  it "outputs dimmed text" && {
    out=$(ui_dim "subtle detail")
    assert_contains "$out" "subtle detail"
  }

# ── Structured output ─────────────────────────────────────────
describe "ui_header"

  it "renders a header with title" && {
    out=$(ui_header "Test Title")
    assert_contains "$out" "Test Title"
    assert_contains "$out" "╭"
    assert_contains "$out" "╰"
  }

  it "renders a header with subtitle" && {
    out=$(ui_header "Main" "Sub info")
    assert_contains "$out" "Main"
    assert_contains "$out" "Sub info"
  }

describe "ui_section"

  it "renders a section divider" && {
    out=$(ui_section "Settings")
    assert_contains "$out" "Settings"
    assert_contains "$out" "──"
  }

describe "ui_divider"

  it "renders a horizontal line" && {
    out=$(ui_divider)
    assert_contains "$out" "─"
  }

# ── Progress bar ───────────────────────────────────────────────
describe "ui_progress"

  it "shows progress fraction" && {
    out=$(ui_progress 3 10 "building")
    assert_contains "$out" "3/10"
    assert_contains "$out" "building"
  }

  it "shows complete progress" && {
    out=$(ui_progress 10 10 "done")
    assert_contains "$out" "10/10"
  }

# ── Code block ─────────────────────────────────────────────────
describe "ui_code_block"

  it "wraps code in a box" && {
    out=$(ui_code_block "bash" 'echo "hello"')
    assert_contains "$out" "bash"
    assert_contains "$out" 'echo "hello"'
    assert_contains "$out" "┌"
    assert_contains "$out" "└"
  }

# ── Render response ───────────────────────────────────────────
describe "ui_render_response"

  it "renders plain text" && {
    out=$(ui_render_response "Hello world")
    assert_contains "$out" "Hello world"
  }

  it "renders headings" && {
    out=$(ui_render_response '# Title')
    assert_contains "$out" "Title"
  }

  it "renders bullet points" && {
    out=$(ui_render_response '- item one')
    assert_contains "$out" "item one"
  }

  it "renders code blocks" && {
    out=$(ui_render_response '```bash
echo hi
```')
    assert_contains "$out" "echo hi"
    assert_contains "$out" "┌"
    assert_contains "$out" "└"
  }

# ── prompt ─────────────────────────────────────────────────────
describe "ui_prompt"

  it "shows current project name" && {
    export LODGE_PROJECT="myapp"
    out=$(ui_prompt)
    assert_contains "$out" "myapp"
    assert_contains "$out" "❯"
  }

# ── Token estimate ─────────────────────────────────────────────
describe "llm_estimate_tokens (from llm.sh)"

  # We test this here to avoid needing Ollama
  it "estimates tokens from character count" && {
    source "$LODGE_DIR/lib/llm.sh" 2>/dev/null || true
    if declare -f llm_estimate_tokens &>/dev/null; then
      tokens=$(llm_estimate_tokens "This is a test string with about forty chars.")
      assert_gt "$tokens" 5
    else
      skip "llm_estimate_tokens not loaded"
    fi
  }

test_end
