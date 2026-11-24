#!/bin/bash
# ── Tests: ask_operator interactive vs autonomous masking and timeout ──────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh"
source "$LODGE_DIR/lib/tools/native_tools.sh"
source "$LODGE_DIR/commands/ask.sh"

test_start "ask_operator — Interactive Scoping, Autonomous Masking & Timeout"

describe "is_interactive_operator_session"

  it "returns false (1) in non-interactive/autonomous context" && {
    LODGE_NONINTERACTIVE=1
    _DISCORD_IN_SESSION=0
    if is_interactive_operator_session; then
      assert_eq "true" "false"
    else
      assert_ok 0 "Expected non-interactive to return false"
    fi
  }

  it "returns true (0) when _DISCORD_IN_SESSION=1" && {
    LODGE_NONINTERACTIVE=0
    _DISCORD_IN_SESSION=1
    _DISCORD_CURRENT_CHANNEL="123456789"
    if is_interactive_operator_session; then
      assert_ok 0 "Expected discord session to return true"
    else
      assert_eq "false" "true"
    fi
    _DISCORD_IN_SESSION=0
    _DISCORD_CURRENT_CHANNEL=""
  }

describe "get_ask_operator_timeout"

  it "defaults to 120 seconds" && {
    unset ASK_OPERATOR_TIMEOUT DISCORD_ASK_TIMEOUT UI_INPUT_TIMEOUT
    rm -f "$GEORGE_DIR/ask_timeout"
    t=$(get_ask_operator_timeout)
    assert_eq "$t" "120"
  }

  it "respects ASK_OPERATOR_TIMEOUT env var" && {
    ASK_OPERATOR_TIMEOUT=45
    t=$(get_ask_operator_timeout)
    assert_eq "$t" "45"
    unset ASK_OPERATOR_TIMEOUT
  }

  it "reads from .george/ask_timeout config file" && {
    unset ASK_OPERATOR_TIMEOUT
    mkdir -p "$GEORGE_DIR"
    echo "75" > "$GEORGE_DIR/ask_timeout"
    t=$(get_ask_operator_timeout)
    assert_eq "$t" "75"
    rm -f "$GEORGE_DIR/ask_timeout"
  }

describe "ui_ask_operator safety in autonomous mode"

  it "refuses to run and returns error 1 in autonomous mode" && {
    LODGE_NONINTERACTIVE=1
    _DISCORD_IN_SESSION=0
    ret=0
    out=$(ui_ask_operator "What is your preference?" 2>&1) || ret=$?
    assert_eq "$ret" "1"
    assert_contains "$out" "ERROR: ask_operator is not available in autonomous/headless mode"
  }

describe "Native tools schema masking"

  it "masks ask_operator from native_tools_get_schemas in autonomous mode" && {
    LODGE_NONINTERACTIVE=1
    _DISCORD_IN_SESSION=0
    schemas=$(native_tools_get_schemas "all")
    assert_not_contains "$schemas" '"name": "ask_operator"'
  }

  it "exposes ask_operator in native_tools_get_schemas in Discord session" && {
    LODGE_NONINTERACTIVE=0
    _DISCORD_IN_SESSION=1
    _DISCORD_CURRENT_CHANNEL="123456789"
    schemas=$(native_tools_get_schemas "all")
    assert_contains "$schemas" '"name": "ask_operator"'
    _DISCORD_IN_SESSION=0
    _DISCORD_CURRENT_CHANNEL=""
  }

  it "masks ask_operator from native_tools_resolve_profile in autonomous mode" && {
    LODGE_NONINTERACTIVE=1
    _DISCORD_IN_SESSION=0
    schemas=$(native_tools_resolve_profile "default")
    assert_not_contains "$schemas" '"name": "ask_operator"'
  }

  it "exposes ask_operator in native_tools_resolve_profile in Discord session" && {
    LODGE_NONINTERACTIVE=0
    _DISCORD_IN_SESSION=1
    _DISCORD_CURRENT_CHANNEL="123456789"
    schemas=$(native_tools_resolve_profile "default")
    assert_contains "$schemas" '"name": "ask_operator"'
    _DISCORD_IN_SESSION=0
    _DISCORD_CURRENT_CHANNEL=""
  }

describe "cmd_ask timeout tuning"

  it "updates and reports timeout via cmd_ask timeout" && {
    unset ASK_OPERATOR_TIMEOUT
    rm -f "$GEORGE_DIR/ask_timeout"

    set_out=$(cmd_ask timeout 180)
    assert_contains "$set_out" "Operator question timeout updated to 180s"

    query_out=$(cmd_ask timeout)
    assert_contains "$query_out" "Current operator question timeout: 180s"

    t=$(get_ask_operator_timeout)
    assert_eq "$t" "180"

    rm -f "$GEORGE_DIR/ask_timeout"
  }

test_end
