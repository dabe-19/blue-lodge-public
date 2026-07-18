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

  it "dispatches /q to registered handler" && {
    # /q is registered as brainstorm/quick question, not quit
    # It will fail (agent_ask not loaded) but should NOT return 99
    commands_dispatch "/q" "." 2>/dev/null
    assert_neq "$?" "99"
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

  it "unescapes literal \\n backslash sequences into actual newlines" && {
    _dispatch_nl_handler() {
      echo "$1"
    }
    commands_register "nltest" "newline test" "_dispatch_nl_handler"
    out=$(commands_dispatch $'/nltest first\\nsecond' ".")
    assert_contains "$out" $'first\nsecond'
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

  it "catalog contains SYSTEM CAPABILITIES header" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "SYSTEM CAPABILITIES & TOOLS"
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

  it "catalog documents social post syntax" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "/social post"
  }

  it "catalog documents social read actions" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "read|dm|timeline"
  }

  it "catalog contains journal command" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "/journal"
    assert_contains "$_cat_out" "persistent living memory"
  }

  it "catalog contains model/tuning controls" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "/models"
    assert_contains "$_cat_out" "/model"
  }

  it "catalog contains research and memory section" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "RESEARCH & MEMORY"
  }

  it "catalog contains task freedom section" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "TASK FREEDOM"
  }

  it "catalog contains /recall guidance" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "DO THIS FIRST BEFORE WEB SEARCH"
  }

  it "catalog contains /ingest" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "/ingest"
  }

  it "catalog contains workflow patterns section" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "WORKFLOW PATTERNS"
  }

  it "catalog contains core workflow pattern" && {
    _cat_out=$(commands_catalog)
    assert_contains "$_cat_out" "CORE WORKFLOW"
    assert_contains "$_cat_out" "HARD CONSTRAINTS"
  }

  it "plan catalog contains workflow patterns" && {
    _plan_out=$(commands_catalog_plan)
    assert_contains "$_plan_out" "WORKFLOW PATTERNS"
  }

  it "workflow patterns use generic flows not concrete task examples" && {
    _cat_out=$(commands_catalog)
    echo "$_cat_out" | grep -q '"pattern"'
    assert_ok $? "Patterns should use generic 'pattern' key"
    echo "$_cat_out" | grep -q '"flow"'
    assert_ok $? "Patterns should use generic 'flow' key"
  }

  it "plan catalog has hard constraints" && {
    _plan_out=$(commands_catalog_plan)
    assert_contains "$_plan_out" "HARD CONSTRAINTS"
  }

  it "plan catalog has social post syntax" && {
    _plan_out=$(commands_catalog_plan)
    assert_contains "$_plan_out" "/social post"
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

  it "dispatch strips hallucinated --flags from args" && {
    _flag_handler() { echo "ARGS:$1"; }
    commands_register "flagtest" "test" "_flag_handler"
    _fl_out=$(commands_dispatch "/flagtest search top news --limit 5 --source cnn" 2>&1)
    assert_contains "$_fl_out" "ARGS:search top news"
  }

  it "dispatch preserves URLs when stripping flags" && {
    _fl_out=$(commands_dispatch "/flagtest fetch https://example.com --output json" 2>&1)
    assert_contains "$_fl_out" "https://example.com"
  }

  it "dispatch skips flag stripping for content commands" && {
    _content_handler() { echo "ARGS:$1"; }
    commands_register "edit" "test" "_content_handler"
    _fl_out=$(commands_dispatch "/edit file.py s/--old/--new/g" 2>&1)
    assert_contains "$_fl_out" "ARGS:file.py s/--old/--new/g"
  }

  it "dispatch passes through clean args unchanged" && {
    _fl_out=$(commands_dispatch "/flagtest search breaking news" 2>&1)
    assert_contains "$_fl_out" "ARGS:search breaking news"
  }

  it "plan catalog contains task freedom section" && {
    _plan_out=$(commands_catalog_plan)
    assert_contains "$_plan_out" "TASK FREEDOM"
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

# ── commands_is_safe_auto_route ──────────────────────────────
describe "commands_is_safe_auto_route"

  # Register test commands to exercise the logic
  _safe_handler() { echo "safe"; }
  commands_register "sandbox" "test sandbox" "_safe_handler"
  commands_register "read" "test read" "_safe_handler"
  commands_register "write" "test write" "_safe_handler"
  commands_register "build" "test build" "_safe_handler"
  commands_register "test" "test test" "_safe_handler"
  commands_register "fix" "test fix" "_safe_handler"
  commands_register "plan" "test plan" "_safe_handler"
  commands_register "ask" "test ask" "_safe_handler"
  commands_register "model" "test model" "_safe_handler"
  commands_register "status" "test status" "_safe_handler"
  commands_register "recall" "test recall" "_safe_handler"
  commands_register "container" "test container" "_safe_handler"
  commands_register "phone" "test phone" "_safe_handler"
  commands_register "wallet" "test wallet" "_safe_handler"
  commands_register "vitals" "test vitals" "_safe_handler"

  it "allows single-word known commands (status)" && {
    commands_is_safe_auto_route "status"
    assert_ok $?
  }

  it "allows single-word known commands (sandbox)" && {
    commands_is_safe_auto_route "sandbox"
    assert_ok $?
  }

  it "allows single-word known commands (read)" && {
    commands_is_safe_auto_route "read"
    assert_ok $?
  }

  it "blocks multi-word 'read' (ambiguous verb)" && {
    commands_is_safe_auto_route "read the docs and summarize"
    assert_fail $?
  }

  it "blocks multi-word 'write' (ambiguous verb)" && {
    commands_is_safe_auto_route "write a REST API"
    assert_fail $?
  }

  it "blocks multi-word 'build' (ambiguous verb)" && {
    commands_is_safe_auto_route "build a todo app"
    assert_fail $?
  }

  it "blocks multi-word 'test' (ambiguous verb)" && {
    commands_is_safe_auto_route "test the login flow"
    assert_fail $?
  }

  it "blocks multi-word 'fix' (ambiguous verb)" && {
    commands_is_safe_auto_route "fix the bug in main"
    assert_fail $?
  }

  it "blocks multi-word 'plan' (ambiguous verb)" && {
    commands_is_safe_auto_route "plan a migration strategy"
    assert_fail $?
  }

  it "blocks multi-word 'ask' (ambiguous verb)" && {
    commands_is_safe_auto_route "ask George about his soul"
    assert_fail $?
  }

  it "blocks multi-word 'model' (ambiguous noun)" && {
    commands_is_safe_auto_route "model the database schema"
    assert_fail $?
  }

  it "blocks multi-word 'recall' (ambiguous verb)" && {
    commands_is_safe_auto_route "recall what we discussed"
    assert_fail $?
  }

  it "blocks multi-word 'status' (ambiguous noun)" && {
    commands_is_safe_auto_route "status of the deployment"
    assert_fail $?
  }

  it "allows multi-word 'sandbox new' (non-ambiguous)" && {
    commands_is_safe_auto_route "sandbox new myproject"
    assert_ok $?
  }

  it "allows multi-word 'container install' (non-ambiguous)" && {
    commands_is_safe_auto_route "container install ubuntu"
    assert_ok $?
  }

  it "allows multi-word 'phone call' (non-ambiguous)" && {
    commands_is_safe_auto_route "phone call 555-1234"
    assert_ok $?
  }

  it "allows multi-word 'wallet send' (non-ambiguous)" && {
    commands_is_safe_auto_route "wallet send 0.1 BTC"
    assert_ok $?
  }

  it "allows multi-word 'vitals show' (non-ambiguous)" && {
    commands_is_safe_auto_route "vitals show"
    assert_ok $?
  }

  it "rejects unknown first word entirely" && {
    commands_is_safe_auto_route "frobnicate the widgets"
    assert_fail $?
  }

  it "rejects unknown single word" && {
    commands_is_safe_auto_route "frobnicate"
    assert_fail $?
  }

test_end
