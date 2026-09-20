#!/bin/bash
# ── Tests: Code payload escaping in lib/commands.sh ───────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/commands.sh"

test_start "lib/commands.sh — Code Escaping & Payload Preservation"

describe "commands_dispatch with python and bash payloads"

  it "preserves literal \\n inside python string expressions without breaking syntax" && {
    out=$(commands_dispatch '/bash python3 -c "s = \"hello\nworld\"; print(s.splitlines()[1])"' ".")
    assert_ok $?
    assert_eq "$out" "world"
  }

  it "preserves quotes and multi-line strings in /bash" && {
    out=$(commands_dispatch '/bash python3 -c "toc = \"12. [Title](#link)\n\"; print(len(toc))"' ".")
    assert_ok $?
    assert_eq "$out" "19"
  }

  it "preserves return codes from failing commands" && {
    commands_dispatch '/bash false' "." >/dev/null 2>&1
    rc=$?
    assert_eq "$rc" "1"
  }

test_end
