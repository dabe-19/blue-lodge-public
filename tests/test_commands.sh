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

  it "returns 127 for unknown command" && {
    commands_dispatch "/nonexistent_xyz" "." 2>/dev/null
    assert_eq $? 127
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

# ── commands_catalog ──────────────────────────────────────────
describe "commands_catalog"

  it "returns a non-empty catalog" && {
    _cat_out=$(commands_catalog)
    assert_not_empty "$_cat_out"
  }

  it "catalog contains YOUR WORKING COMMANDS header" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "YOUR WORKING COMMANDS"
  }

  it "catalog lists /recall" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "/recall"
  }

  it "catalog lists /social" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "/social"
  }

  it "catalog lists /pgp" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "/pgp"
  }

  it "catalog lists /sandbox" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "/sandbox"
  }

  it "catalog lists /web" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "/web"
  }

  it "catalog documents discord send with channel_id" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "/social discord send <channel_id>"
  }

  it "catalog documents discord read with channel_id" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "/social discord read <channel_id>"
  }

  it "catalog contains MEMORY LOOP section" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "MEMORY LOOP"
  }

  it "catalog memory loop shows read-remember-respond pattern" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "/journal write"
    assert_contains "$_cat_out" "/social discord read"
  }

  it "plan catalog contains memory loop" && {
    _plan_out=$(commands_catalog_plan)
    assert_contains "$_plan_out" "MEMORY LOOP"
  }

  it "plan catalog has anti-sandbox rule" && {
    _plan_out=$(commands_catalog_plan)
    assert_contains "$_plan_out" "do NOT use /sandbox to run slash commands"
  }

  it "plan catalog has discord-specific social syntax" && {
    _plan_out=$(commands_catalog_plan)
    assert_contains "$_plan_out" "/social post discord"
  }

  it "plan catalog tells LLM not to quote arguments" && {
    _plan_out=$(commands_catalog_plan)
    assert_contains "$_plan_out" "Do NOT quote arguments"
  }

  it "dispatch strips outer wrapping double-quotes from args" && {
    _quote_handler() {
        echo "ARGS:$1"
    }
    commands_register "quotetest" "test" "_quote_handler"
    _qt_out=$(commands_dispatch '/quotetest "hello world"' 2>&1)
    assert_contains "$_qt_out" "ARGS:hello world"
  }

  it "dispatch strips outer wrapping single-quotes from args" && {
    _qt_out=$(commands_dispatch "/quotetest 'hello world'" 2>&1)
    assert_contains "$_qt_out" "ARGS:hello world"
  }

  it "plan catalog marks /email as not for social" && {
    _plan_out=$(commands_catalog_plan)
    assert_contains "$_plan_out" "ONLY for actual email"
  }

# ── commands_services_status ───────────────────────────────────
describe "commands_services_status"

  it "commands_services_status is defined" && {
    declare -f commands_services_status &>/dev/null
    assert_ok $?
  }

  it "outputs CONFIGURED and NOT CONFIGURED lines" && {
    # Stub api_get_key to always fail (nothing configured)
    api_get_key() { return 1; }
    _svc_out=$(commands_services_status)
    assert_contains "$_svc_out" "CONFIGURED:"
    assert_contains "$_svc_out" "NOT CONFIGURED:"
    unset -f api_get_key
  }

  it "reports configured service when api_get_key succeeds" && {
    api_get_key() {
      [[ "$1" == "DISCORD_BOT_TOKEN" ]] && echo "fake" && return 0
      return 1
    }
    _svc_out=$(commands_services_status)
    assert_contains "$_svc_out" "discord"
    unset -f api_get_key
  }

  it "plan catalog injects service status" && {
    api_get_key() { return 1; }
    _plan_out=$(commands_catalog_plan)
    assert_contains "$_plan_out" "CONFIGURED:"
    unset -f api_get_key
  }

  it "catalog contains /soul command" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "/soul"
  }

# ── commands_help_topic ────────────────────────────────────────
describe "commands_help_topic"

  it "shows help for a registered command" && {
    _topic_handler() {
        if [ -z "$1" ]; then echo "TOPIC_HELP_SHOWN"; fi
    }
    commands_register "topictest" "topic test" "_topic_handler"
    _topic_out=$(commands_help_topic "topictest" 2>&1)
    assert_contains "$_topic_out" "TOPIC_HELP_SHOWN"
  }

  it "handles /help for unknown command" && {
    _topic_out=$(commands_help_topic "nonexistent_zzz" 2>&1)
    assert_contains "$_topic_out" "Unknown command"
  }

  it "strips leading slash from topic" && {
    _slash_handler() {
        if [ -z "$1" ]; then echo "SLASH_STRIPPED_OK"; fi
    }
    commands_register "slashtest" "slash test" "_slash_handler"
    _topic_out=$(commands_help_topic "/slashtest" 2>&1)
    assert_contains "$_topic_out" "SLASH_STRIPPED_OK"
  }

test_end
