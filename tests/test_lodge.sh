#!/bin/bash
# ── Tests: lodge (main script) ────────────────────────────────
# Tests command registration, version, REPL detection heuristic,
# and dependency checking.
source "$(dirname "$0")/framework.sh"

# Source all libs that lodge sources (same order)
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/llm.sh"
source "$LODGE_DIR/lib/memory.sh"
source "$LODGE_DIR/lib/tools.sh"
source "$LODGE_DIR/lib/agent.sh"
source "$LODGE_DIR/lib/commands.sh"
source "$LODGE_DIR/lib/sandbox.sh"
source "$LODGE_DIR/lib/container.sh"
source "$LODGE_DIR/lib/api.sh"
source "$LODGE_DIR/lib/social.sh"
source "$LODGE_DIR/lib/providers.sh"
source "$LODGE_DIR/lib/web.sh"
source "$LODGE_DIR/lib/backup.sh"
source "$LODGE_DIR/lib/journal.sh"

# Source the lodge script's functions (but don't run main)
# We extract the function definitions by sourcing in a subshell trick:
# The lodge script calls main "$@" at the end, so we mock main
# and source the whole file to get its function defs.
_original_main() { :; }
eval "$(sed 's/^main "$@"$//' "$LODGE_DIR/lodge" | grep -v '^set -uo pipefail')"

# Initialize model library (same as lodge main does at startup).
# Sets LODGE_MODEL from model slots and syncs sampling params.
models_init

test_start "lodge — Main Script"

# ── Version ────────────────────────────────────────────────────
describe "Version"

  it "LODGE_VERSION is set" && {
    assert_not_empty "$LODGE_VERSION"
  }

  it "LODGE_VERSION is semver-like" && {
    assert_match "$LODGE_VERSION" "^[0-9]+\.[0-9]+\.[0-9]+"
  }

# ── Environment ────────────────────────────────────────────────
describe "Environment variables"

  it "LODGE_DIR is set" && {
    assert_not_empty "$LODGE_DIR"
  }

  it "LODGE_PROJECT is set" && {
    assert_not_empty "$LODGE_PROJECT"
  }

# ── Command Registration ──────────────────────────────────────
describe "Command registration"

  # Run registration
  _register_commands

  it "registers init command" && {
    commands_is_command "/init"
    assert_ok $?
  }

  it "registers plan command" && {
    commands_is_command "/plan"
    assert_ok $?
  }

  it "registers ask command" && {
    commands_is_command "/ask"
    assert_ok $?
  }

  it "registers q command" && {
    commands_is_command "/q"
    assert_ok $?
  }

  it "registers compact command" && {
    commands_is_command "/compact"
    assert_ok $?
  }

  it "registers snapshot command" && {
    commands_is_command "/snapshot"
    assert_ok $?
  }

  it "registers memory command" && {
    commands_is_command "/memory"
    assert_ok $?
  }

  it "registers soul command" && {
    commands_is_command "/soul"
    assert_ok $?
  }

  it "registers status command" && {
    commands_is_command "/status"
    assert_ok $?
  }

  it "registers journal command" && {
    commands_is_command "/journal"
    assert_ok $?
  }

  it "registers sandbox command" && {
    commands_is_command "/sandbox"
    assert_ok $?
  }

  it "registers container command" && {
    commands_is_command "/container"
    assert_ok $?
  }

  it "registers api command" && {
    commands_is_command "/api"
    assert_ok $?
  }

  it "registers social command" && {
    commands_is_command "/social"
    assert_ok $?
  }

  it "registers provider command" && {
    commands_is_command "/provider"
    assert_ok $?
  }

  it "registers web command" && {
    commands_is_command "/web"
    assert_ok $?
  }

  it "registers backup command" && {
    commands_is_command "/backup"
    assert_ok $?
  }

  it "registers security command" && {
    commands_is_command "/security"
    assert_ok $?
  }

  it "registers readme command" && {
    commands_is_command "/readme"
    assert_ok $?
  }

  it "registers recall command" && {
    commands_is_command "/recall"
    assert_ok $?
  }

  it "registers clear command" && {
    commands_is_command "/clear"
    assert_ok $?
  }

  it "registers cd command" && {
    commands_is_command "/cd"
    assert_ok $?
  }

  it "registers files command" && {
    commands_is_command "/files"
    assert_ok $?
  }

  it "registers read command" && {
    commands_is_command "/read"
    assert_ok $?
  }

  it "registers secret command" && {
    commands_is_command "/secret"
    assert_ok $?
  }

  it "registers ingest command" && {
    commands_is_command "/ingest"
    assert_ok $?
  }

  it "registers gsuite command" && {
    commands_is_command "/gsuite"
    assert_ok $?
  }

  it "registers wallet command" && {
    commands_is_command "/wallet"
    assert_ok $?
  }

  it "registers email command" && {
    commands_is_command "/email"
    assert_ok $?
  }

# ── REPL heuristic ────────────────────────────────────────────
describe "REPL question vs task heuristic"

  it "short input with ? is a question pattern" && {
    input="what is this?"
    wc=$(echo "$input" | wc -w)
    [[ "$wc" -le 6 ]] && [[ "$input" == *"?"* ]]
    assert_ok $?
  }

  it "long input is a task pattern" && {
    input="refactor the entire authentication module to use JWT tokens instead of sessions"
    wc=$(echo "$input" | wc -w)
    [[ "$wc" -le 6 ]] && [[ "$input" == *"?"* ]]
    assert_fail $?
  }

  it "short input without ? is a task pattern" && {
    input="fix the bug"
    wc=$(echo "$input" | wc -w)
    [[ "$wc" -le 6 ]] && [[ "$input" == *"?"* ]]
    assert_fail $?
  }

# ── Unknown slash command: reject, don't run as task ──────────
describe "Unknown slash command handling"

  it "unknown slash command returns 127 not task fallthrough" && {
    commands_dispatch "/nonexistent_xyz_9999" "." 2>/dev/null
    assert_eq $? 127
  }

  it "REPL does not contain agent_run fallthrough for 127" && {
    # The _repl function must NOT fall through to agent_run on exit 127
    body=$(declare -f _repl)
    if echo "$body" | grep -q 'agent_run.*input.*127\|127.*agent_run\|Treating as task'; then
        assert_fail 1  # Bad — old fallthrough still present
    else
        assert_ok 0
    fi
  }

  it "REPL does not contain _is_conversational auto-route to ask" && {
    body=$(declare -f _repl)
    if echo "$body" | grep -q '_is_conversational\|agent_ask'; then
        assert_fail 1  # Bad — old /ask auto-routing still present
    else
        assert_ok 0
    fi
  }

  it "REPL uses commands_is_safe_auto_route for slashless dispatch" && {
    body=$(declare -f _repl)
    echo "$body" | grep -q 'commands_is_safe_auto_route'
    assert_ok $?
  }

# ── Command handler functions ─────────────────────────────────
describe "Command handler functions"

  it "_cmd_memory handles missing GEORGE.md" && {
    dir=$(test_tmpdir)
    output=$(_cmd_memory "" "$dir" 2>&1)
    assert_contains "$output" "No GEORGE.md"
  }

  it "_cmd_memory shows existing GEORGE.md" && {
    dir=$(test_tmpdir)
    echo "# Test Project" > "$dir/GEORGE.md"
    output=$(_cmd_memory "" "$dir" 2>&1)
    assert_contains "$output" "Test Project"
  }

  it "_cmd_soul shows soul.md with show arg" && {
    output=$(_cmd_soul "show" 2>&1)
    assert_not_empty "$output"
  }

  it "_cmd_soul toggles on" && {
    LODGE_SOUL=0
    _cmd_soul "on" >/dev/null 2>&1
    assert_eq "${LODGE_SOUL}" "1"
  }

  it "_cmd_soul toggles off" && {
    LODGE_SOUL=1
    _cmd_soul "off" >/dev/null 2>&1
    assert_eq "${LODGE_SOUL}" "0"
  }

  it "_cmd_soul toggles with no arg" && {
    LODGE_SOUL=0
    _cmd_soul "" >/dev/null 2>&1
    assert_eq "${LODGE_SOUL}" "1"
    _cmd_soul "" >/dev/null 2>&1
    assert_eq "${LODGE_SOUL}" "0"
  }

# ── /limits command ────────────────────────────────────────────
describe "Limits command"

  it "registers limits command" && {
    commands_is_command "/limits"
    assert_ok $?
  }

  it "_cmd_limits is defined" && {
    declare -f _cmd_limits &>/dev/null
    assert_ok $?
  }

  it "_cmd_limits show displays all limits" && {
    output=$(_cmd_limits "" 2>&1)
    echo "$output" | grep -q "Plan steps"
    assert_ok $?
  }

  it "_cmd_limits steps sets AGENT_PLAN_STEPS" && {
    _cmd_limits "steps 8" >/dev/null 2>&1
    assert_eq "$AGENT_PLAN_STEPS" "8"
    AGENT_PLAN_STEPS=6  # restore
  }

  it "_cmd_limits depth sets AGENT_MAX_DEPTH" && {
    _cmd_limits "depth 4" >/dev/null 2>&1
    assert_eq "$AGENT_MAX_DEPTH" "4"
    AGENT_MAX_DEPTH=3  # restore
  }

  it "_cmd_limits milestones sets AGENT_MAX_STEPS" && {
    _cmd_limits "milestones 30" >/dev/null 2>&1
    assert_eq "$AGENT_MAX_STEPS" "30"
    AGENT_MAX_STEPS=40  # restore
  }

  it "_cmd_limits inner sets AGENT_INNER_LOOPS" && {
    _cmd_limits "inner 10" >/dev/null 2>&1
    assert_eq "$AGENT_INNER_LOOPS" "10"
    AGENT_INNER_LOOPS=6  # restore
  }

  it "_cmd_limits delay sets AGENT_STEP_DELAY" && {
    _cmd_limits "delay 3" >/dev/null 2>&1
    assert_eq "$AGENT_STEP_DELAY" "3"
    AGENT_STEP_DELAY=1  # restore
  }

  it "_cmd_limits rejects invalid numbers" && {
    _cmd_limits "steps 0" >/dev/null 2>&1
    # Should remain at default since 0 is below min of 1
    assert_eq "$AGENT_PLAN_STEPS" "6"
  }

  it "_cmd_limits rejects out-of-range values" && {
    _cmd_limits "steps 999" >/dev/null 2>&1
    # Should remain at default since 999 exceeds max of 20
    assert_eq "$AGENT_PLAN_STEPS" "6"
  }

  it "_cmd_limits show points to /tuning" && {
    output=$(_cmd_limits "" 2>&1)
    echo "$output" | grep -q "/tuning"
    assert_ok $?
  }

  it "_cmd_limits web-sufficiency sets AGENT_WEB_SUFFICIENCY" && {
    _cmd_limits "web-sufficiency 5" >/dev/null 2>&1
    assert_eq "$AGENT_WEB_SUFFICIENCY" "5"
    AGENT_WEB_SUFFICIENCY=20  # restore
  }

  it "_cmd_limits milestone-retries sets AGENT_MAX_MILESTONE_RETRIES" && {
    _cmd_limits "milestone-retries 4" >/dev/null 2>&1
    assert_eq "$AGENT_MAX_MILESTONE_RETRIES" "4"
    AGENT_MAX_MILESTONE_RETRIES=20  # restore
  }

  it "_cmd_limits cmd-family sets AGENT_MAX_CMD_FAMILY" && {
    _cmd_limits "cmd-family 5" >/dev/null 2>&1
    assert_eq "$AGENT_MAX_CMD_FAMILY" "5"
    AGENT_MAX_CMD_FAMILY=10  # restore
  }

  it "_cmd_limits honeydew-match sets AGENT_HONEYDEW_MATCH" && {
    _cmd_limits "honeydew-match 5" >/dev/null 2>&1
    assert_eq "$AGENT_HONEYDEW_MATCH" "5"
    AGENT_HONEYDEW_MATCH=3  # restore
  }

  it "_cmd_limits expand on enables AGENT_HONEYDEW_EXPAND" && {
    _cmd_limits "expand on" >/dev/null 2>&1
    assert_eq "$AGENT_HONEYDEW_EXPAND" "1"
    AGENT_HONEYDEW_EXPAND=0  # restore
  }

  it "_cmd_limits expand off disables AGENT_HONEYDEW_EXPAND" && {
    AGENT_HONEYDEW_EXPAND=1
    _cmd_limits "expand off" >/dev/null 2>&1
    assert_eq "$AGENT_HONEYDEW_EXPAND" "0"
  }

  it "_cmd_limits expand accepts enable/disable aliases" && {
    _cmd_limits "expand enable" >/dev/null 2>&1
    assert_eq "$AGENT_HONEYDEW_EXPAND" "1"
    _cmd_limits "expand disable" >/dev/null 2>&1
    assert_eq "$AGENT_HONEYDEW_EXPAND" "0"
  }

  it "_cmd_limits expand rejects invalid value" && {
    AGENT_HONEYDEW_EXPAND=0
    _cmd_limits "expand maybe" >/dev/null 2>&1
    assert_eq "$AGENT_HONEYDEW_EXPAND" "0"
  }

  it "_cmd_limits file-expand on/off toggles AGENT_FILE_EXPAND" && {
    _cmd_limits "file-expand on" >/dev/null 2>&1
    assert_eq "$AGENT_FILE_EXPAND" "1"
    _cmd_limits "file-expand off" >/dev/null 2>&1
    assert_eq "$AGENT_FILE_EXPAND" "0"
    AGENT_FILE_EXPAND=1  # restore
  }

  it "_cmd_limits file-expand accepts enable/disable aliases" && {
    _cmd_limits "file-expand enable" >/dev/null 2>&1
    assert_eq "$AGENT_FILE_EXPAND" "1"
    _cmd_limits "file-expand disable" >/dev/null 2>&1
    assert_eq "$AGENT_FILE_EXPAND" "0"
    AGENT_FILE_EXPAND=1  # restore
  }

  it "_cmd_limits file-expand-chars sets AGENT_FILE_EXPAND_CHARS" && {
    _cmd_limits "file-expand-chars 500" >/dev/null 2>&1
    assert_eq "$AGENT_FILE_EXPAND_CHARS" "500"
    AGENT_FILE_EXPAND_CHARS=1000  # restore
  }

  it "_cmd_limits file-expand-chars rejects out-of-range values" && {
    AGENT_FILE_EXPAND_CHARS=1000
    _cmd_limits "file-expand-chars 99999" >/dev/null 2>&1
    assert_eq "$AGENT_FILE_EXPAND_CHARS" "1000"
  }

  it "_cmd_limits file-expand-chars accepts 0 for unlimited" && {
    _cmd_limits "file-expand-chars 0" >/dev/null 2>&1
    assert_eq "$AGENT_FILE_EXPAND_CHARS" "0"
    AGENT_FILE_EXPAND_CHARS=1000  # restore
  }

  it "_cmd_limits dm-scan-chars sets AGENT_DM_SCAN_CHARS" && {
    _cmd_limits "dm-scan-chars 120" >/dev/null 2>&1
    assert_eq "$AGENT_DM_SCAN_CHARS" "120"
    AGENT_DM_SCAN_CHARS=80  # restore
  }

  it "_cmd_limits show includes DM scan chars line" && {
    output=$(_cmd_limits "" 2>&1)
    echo "$output" | grep -q "DM scan chars"
    assert_ok $?
  }

  it "_cmd_limits max-items sets AGENT_HONEYDEW_MAX_ITEMS" && {
    _cmd_limits "max-items 12" >/dev/null 2>&1
    assert_eq "$AGENT_HONEYDEW_MAX_ITEMS" "12"
    AGENT_HONEYDEW_MAX_ITEMS=16  # restore
  }

  it "_cmd_limits max-items rejects below min" && {
    _cmd_limits "max-items 1" >/dev/null 2>&1
    assert_eq "$AGENT_HONEYDEW_MAX_ITEMS" "16"
  }

  it "_cmd_limits show includes agent loop lines" && {
    output=$(_cmd_limits "" 2>&1)
    echo "$output" | grep -q "Web sufficiency"
    assert_ok $?
    echo "$output" | grep -q "Milestone retries"
    assert_ok $?
    echo "$output" | grep -q "Command family"
    assert_ok $?
    echo "$output" | grep -q "Honeydew match"
    assert_ok $?
    echo "$output" | grep -q "File expand"
    assert_ok $?
    echo "$output" | grep -q "Honeydew expansion"
    assert_ok $?
    echo "$output" | grep -q "Honeydew max items"
    assert_ok $?
    echo "$output" | grep -q "Tight parsing"
    assert_ok $?
    echo "$output" | grep -q "Web search length"
    assert_ok $?
    echo "$output" | grep -q "Web search operators"
    assert_ok $?
  }

  it "_cmd_limits tight-parsing on/off toggles AGENT_WEB_SEARCH_TIGHT_PARSING" && {
    _cmd_limits "tight-parsing on" >/dev/null 2>&1
    assert_eq "$AGENT_WEB_SEARCH_TIGHT_PARSING" "1"
    _cmd_limits "tight-parsing off" >/dev/null 2>&1
    assert_eq "$AGENT_WEB_SEARCH_TIGHT_PARSING" "0"
  }

  it "_cmd_limits web-search-length sets AGENT_WEB_SEARCH_MAX_LENGTH" && {
    _cmd_limits "web-search-length 200" >/dev/null 2>&1
    assert_eq "$AGENT_WEB_SEARCH_MAX_LENGTH" "200"
    AGENT_WEB_SEARCH_MAX_LENGTH=160  # restore
  }

  it "_cmd_limits web-search-ops sets AGENT_WEB_SEARCH_MAX_OPERATORS" && {
    _cmd_limits "web-search-ops 5" >/dev/null 2>&1
    assert_eq "$AGENT_WEB_SEARCH_MAX_OPERATORS" "5"
    AGENT_WEB_SEARCH_MAX_OPERATORS=3  # restore
  }

  it "_cmd_limits show does not include token/budget lines" && {
    output=$(_cmd_limits "" 2>&1)
    echo "$output" | grep -q "Agent tokens" && { fail "should not show Agent tokens"; return 1; }
    echo "$output" | grep -q "Think Budgets" && { fail "should not show Think Budgets"; return 1; }
    assert_ok 0
  }

  it "_cmd_limits reset restores agent-behaviour defaults" && {
    AGENT_PLAN_STEPS=10
    AGENT_INNER_LOOPS=12
    AGENT_MAX_STEPS=50
    AGENT_MAX_DEPTH=5
    AGENT_STEP_DELAY=5
    _cmd_limits "reset" >/dev/null 2>&1
    assert_eq "$AGENT_PLAN_STEPS" "6"
    assert_eq "$AGENT_INNER_LOOPS" "6"
    assert_eq "$AGENT_MAX_STEPS" "40"
    assert_eq "$AGENT_MAX_DEPTH" "3"
    assert_eq "$AGENT_STEP_DELAY" "1"
    assert_eq "$AGENT_WEB_SUFFICIENCY" "20"
    assert_eq "$AGENT_MAX_MILESTONE_RETRIES" "2"
    assert_eq "$AGENT_MAX_CMD_FAMILY" "10"
    assert_eq "$AGENT_HONEYDEW_MATCH" "3"
    assert_eq "$AGENT_FILE_EXPAND" "1"
    assert_eq "$AGENT_DM_SCAN_CHARS" "80"
    assert_eq "$AGENT_HONEYDEW_EXPAND" "1"
    assert_eq "$AGENT_HONEYDEW_MAX_ITEMS" "8"
    assert_eq "$AGENT_SMART_ROUTE" "2"
    assert_eq "$AGENT_WEB_SEARCH_TIGHT_PARSING" "0"
    assert_eq "$AGENT_WEB_SEARCH_MAX_LENGTH" "160"
    assert_eq "$AGENT_WEB_SEARCH_MAX_OPERATORS" "3"
  }

  it "_cmd_limits reset does NOT touch tuning vars" && {
    LLM_AGENT_TOKENS=999
    PROVIDER_CALL_DELAY=99
    _cmd_limits "reset" >/dev/null 2>&1
    assert_eq "$LLM_AGENT_TOKENS" "999"
    assert_eq "$PROVIDER_CALL_DELAY" "99"
    LLM_AGENT_TOKENS=20480  # restore
    PROVIDER_CALL_DELAY=7   # restore
  }

  it "_cmd_limits show does not include provider rate limits" && {
    _toutput=$(_cmd_limits "" 2>&1)
    echo "$_toutput" | grep -q "Provider Rate Limits" && { fail "should not show Provider Rate Limits"; return 1; }
    assert_ok 0
  }

# ── /tuning command ────────────────────────────────────────────
describe "Tuning command (tokens, budgets, provider, cache, web processing)"

  it "registers tuning command" && {
    commands_is_command "/tuning"
    assert_ok $?
  }

  it "_cmd_tuning is defined" && {
    declare -f _cmd_tuning &>/dev/null
    assert_ok $?
  }

  it "_cmd_tuning show displays tuning dashboard" && {
    output=$(_cmd_tuning "" 2>&1)
    echo "$output" | grep -q "Agent tokens"
    assert_ok $?
    echo "$output" | grep -q "Think Budgets"
    assert_ok $?
    echo "$output" | grep -q "Provider Rate Limits"
    assert_ok $?
  }

  it "_cmd_tuning tokens sets LLM_AGENT_TOKENS" && {
    _cmd_tuning "tokens 768" >/dev/null 2>&1
    assert_eq "$LLM_AGENT_TOKENS" "768"
    LLM_AGENT_TOKENS=20480  # restore
  }

  it "_cmd_tuning ask-tokens sets LLM_ASK_TOKENS" && {
    _cmd_tuning "ask-tokens 400" >/dev/null 2>&1
    assert_eq "$LLM_ASK_TOKENS" "400"
    LLM_ASK_TOKENS=20480  # restore
  }

  it "_cmd_tuning router-tokens sets LLM_ROUTER_TOKENS" && {
    _cmd_tuning "router-tokens 80" >/dev/null 2>&1
    assert_eq "$LLM_ROUTER_TOKENS" "80"
    LLM_ROUTER_TOKENS=512  # restore
  }

  it "_cmd_tuning max-tokens sets LLM_MAX_TOKENS" && {
    _cmd_tuning "max-tokens 8192" >/dev/null 2>&1
    assert_eq "$LLM_MAX_TOKENS" "8192"
    LLM_MAX_TOKENS=20480  # restore
  }

  it "_cmd_tuning tokens rejects out-of-range" && {
    _cmd_tuning "tokens 25000" >/dev/null 2>&1
    assert_eq "$LLM_AGENT_TOKENS" "20480"
  }

  it "_cmd_tuning router-tokens rejects below min" && {
    _cmd_tuning "router-tokens 5" >/dev/null 2>&1
    assert_eq "$LLM_ROUTER_TOKENS" "512"
  }

  it "_cmd_tuning budget sets LLM_BUDGET_TOKENS" && {
    _cmd_tuning "budget 2048" >/dev/null 2>&1
    assert_eq "$LLM_BUDGET_TOKENS" "2048"
    LLM_BUDGET_TOKENS=4096  # restore
  }

  it "_cmd_tuning budget-ask sets LLM_BUDGET_ASK" && {
    _cmd_tuning "budget-ask 2048" >/dev/null 2>&1
    assert_eq "$LLM_BUDGET_ASK" "2048"
    LLM_BUDGET_ASK=4096  # restore
  }

  it "_cmd_tuning budget-agent sets LLM_BUDGET_AGENT" && {
    _cmd_tuning "budget-agent 1024" >/dev/null 2>&1
    assert_eq "$LLM_BUDGET_AGENT" "1024"
    LLM_BUDGET_AGENT=4096  # restore
  }

  it "_cmd_tuning budget-router sets LLM_BUDGET_ROUTER" && {
    _cmd_tuning "budget-router 256" >/dev/null 2>&1
    assert_eq "$LLM_BUDGET_ROUTER" "256"
    LLM_BUDGET_ROUTER=4096  # restore
  }

  it "_cmd_tuning budget-journal sets LLM_BUDGET_JOURNAL" && {
    _cmd_tuning "budget-journal 128" >/dev/null 2>&1
    assert_eq "$LLM_BUDGET_JOURNAL" "128"
    LLM_BUDGET_JOURNAL=4096  # restore
  }

  it "_cmd_tuning budget-tool sets LLM_BUDGET_TOOL" && {
    _cmd_tuning "budget-tool 512" >/dev/null 2>&1
    assert_eq "$LLM_BUDGET_TOOL" "512"
    LLM_BUDGET_TOOL=4096  # restore
  }

  it "_cmd_tuning budget-tool allows zero (unlimited)" && {
    _cmd_tuning "budget-tool 0" >/dev/null 2>&1
    assert_eq "$LLM_BUDGET_TOOL" "0"
    LLM_BUDGET_TOOL=4096  # restore
  }

  it "_cmd_tuning api-delay sets PROVIDER_CALL_DELAY" && {
    _cmd_tuning "api-delay 10" >/dev/null 2>&1
    assert_eq "$PROVIDER_CALL_DELAY" "10"
    PROVIDER_CALL_DELAY=7  # restore
  }

  it "_cmd_tuning api-retries sets PROVIDER_MAX_RETRIES" && {
    _cmd_tuning "api-retries 6" >/dev/null 2>&1
    assert_eq "$PROVIDER_MAX_RETRIES" "6"
    PROVIDER_MAX_RETRIES=4  # restore
  }

  it "_cmd_tuning api-backoff sets PROVIDER_INITIAL_BACKOFF" && {
    _cmd_tuning "api-backoff 10" >/dev/null 2>&1
    assert_eq "$PROVIDER_INITIAL_BACKOFF" "10"
    PROVIDER_INITIAL_BACKOFF=5  # restore
  }

  it "_cmd_tuning api-max-backoff sets PROVIDER_MAX_BACKOFF" && {
    _cmd_tuning "api-max-backoff 90" >/dev/null 2>&1
    assert_eq "$PROVIDER_MAX_BACKOFF" "90"
    PROVIDER_MAX_BACKOFF=60  # restore
  }

  it "_cmd_tuning api-cooldown-max sets PROVIDER_COOLDOWN_MAX" && {
    _cmd_tuning "api-cooldown-max 15" >/dev/null 2>&1
    assert_eq "$PROVIDER_COOLDOWN_MAX" "15"
    PROVIDER_COOLDOWN_MAX=8  # restore
  }

  it "_cmd_tuning api-cooldown-window sets PROVIDER_COOLDOWN_WINDOW" && {
    _cmd_tuning "api-cooldown-window 120" >/dev/null 2>&1
    assert_eq "$PROVIDER_COOLDOWN_WINDOW" "120"
    PROVIDER_COOLDOWN_WINDOW=60  # restore
  }

  it "_cmd_tuning api-delay rejects out-of-range" && {
    PROVIDER_CALL_DELAY=7
    _cmd_tuning "api-delay 999" >/dev/null 2>&1
    assert_eq "$PROVIDER_CALL_DELAY" "7"
  }

  it "_cmd_tuning web-condense on/off toggles AGENT_WEB_CONDENSE" && {
    _cmd_tuning "web-condense off" >/dev/null 2>&1
    assert_eq "$AGENT_WEB_CONDENSE" "0"
    _cmd_tuning "web-condense on" >/dev/null 2>&1
    assert_eq "$AGENT_WEB_CONDENSE" "1"
  }

  it "_cmd_tuning condense-tokens sets LLM_WEB_CONDENSE_TOKENS" && {
    _cmd_tuning "condense-tokens 500" >/dev/null 2>&1
    assert_eq "$LLM_WEB_CONDENSE_TOKENS" "500"
    LLM_WEB_CONDENSE_TOKENS=200  # restore
  }

  it "_cmd_tuning web-content-max sets WEB_CONTENT_MAX_CHARS" && {
    _cmd_tuning "web-content-max 8000" >/dev/null 2>&1
    assert_eq "$WEB_CONTENT_MAX_CHARS" "8000"
    WEB_CONTENT_MAX_CHARS=4000  # restore
  }

  it "_cmd_tuning web-content-max rejects below min" && {
    WEB_CONTENT_MAX_CHARS=4000
    _cmd_tuning "web-content-max 100" >/dev/null 2>&1
    assert_eq "$WEB_CONTENT_MAX_CHARS" "4000"
  }

  it "_cmd_tuning help includes tuning params" && {
    _toutput=$(_cmd_tuning "help" 2>&1)
    echo "$_toutput" | grep -q "tokens"
    assert_ok $?
    echo "$_toutput" | grep -q "api-delay"
    assert_ok $?
    echo "$_toutput" | grep -q "web-condense"
    assert_ok $?
  }

  it "_cmd_tuning reset restores tuning defaults" && {
    LLM_MAX_TOKENS=4096
    LLM_AGENT_TOKENS=1024
    LLM_STRATEGIST_TOKENS=64
    LLM_ASK_TOKENS=500
    LLM_ROUTER_TOKENS=100
    LLM_BUDGET_TOKENS=4096
    LLM_BUDGET_ASK=4096
    LLM_BUDGET_AGENT=4096
    LLM_BUDGET_ROUTER=4096
    LLM_BUDGET_JOURNAL=4096
    LLM_BUDGET_TOOL=4096
    PROVIDER_CALL_DELAY=99
    PROVIDER_MAX_RETRIES=99
    AGENT_WEB_CONDENSE=0
    LLM_WEB_CONDENSE_TOKENS=999
    WEB_CONTENT_MAX_CHARS=999
    _cmd_tuning "reset" >/dev/null 2>&1
    assert_eq "$LLM_MAX_TOKENS" "20480"
    assert_eq "$LLM_AGENT_TOKENS" "20480"
    assert_eq "$LLM_STRATEGIST_TOKENS" "4096"
    assert_eq "$LLM_ASK_TOKENS" "20480"
    assert_eq "$LLM_ROUTER_TOKENS" "512"
    assert_eq "$LLM_BUDGET_TOKENS" "4096"
    assert_eq "$LLM_BUDGET_ASK" "4096"
    assert_eq "$LLM_BUDGET_AGENT" "4096"
    assert_eq "$LLM_BUDGET_ROUTER" "4096"
    assert_eq "$LLM_BUDGET_JOURNAL" "4096"
    assert_eq "$LLM_BUDGET_TOOL" "4096"
    assert_eq "$PROVIDER_CALL_DELAY" "7"
    assert_eq "$PROVIDER_MAX_RETRIES" "4"
    assert_eq "$AGENT_WEB_CONDENSE" "1"
    assert_eq "$LLM_WEB_CONDENSE_TOKENS" "200"
    assert_eq "$WEB_CONTENT_MAX_CHARS" "4000"
  }

  it "_cmd_tuning reset does NOT touch limits vars" && {
    AGENT_PLAN_STEPS=99
    _cmd_tuning "reset" >/dev/null 2>&1
    assert_eq "$AGENT_PLAN_STEPS" "99"
    AGENT_PLAN_STEPS=6  # restore
  }

# ── /model command ─────────────────────────────────────────────
describe "Model command (sampling parameters)"

  it "registers model command" && {
    commands_is_command "/model"
    assert_ok $?
  }

  it "_cmd_model is defined" && {
    declare -f _cmd_model &>/dev/null
    assert_ok $?
  }

  it "_cmd_model show displays sampling parameters" && {
    output=$(_cmd_model "" 2>&1)
    echo "$output" | grep -q "Sampling Parameters"
    assert_ok $?
  }

  it "_cmd_model temp sets LLM_TEMPERATURE" && {
    _cmd_model "temp 0.7" >/dev/null 2>&1
    assert_eq "$LLM_TEMPERATURE" "0.7"
    LLM_TEMPERATURE=0.15  # restore to model default
  }

  it "_cmd_model presence sets LLM_PRESENCE_PENALTY" && {
    _cmd_model "presence 2.0" >/dev/null 2>&1
    assert_eq "$LLM_PRESENCE_PENALTY" "2.0"
    LLM_PRESENCE_PENALTY=0.3  # restore to model default
  }

  it "_cmd_model repeat sets LLM_REPEAT_PENALTY" && {
    _cmd_model "repeat 1.5" >/dev/null 2>&1
    assert_eq "$LLM_REPEAT_PENALTY" "1.5"
    LLM_REPEAT_PENALTY=1.2  # restore to model default
  }

  it "_cmd_model temp-ask sets LLM_TEMP_ASK" && {
    _cmd_model "temp-ask 0.8" >/dev/null 2>&1
    assert_eq "$LLM_TEMP_ASK" "0.8"
    LLM_TEMP_ASK=""  # restore to empty (model default)
  }

  it "_cmd_model presence-router sets LLM_PRESENCE_ROUTER" && {
    _cmd_model "presence-router 2.5" >/dev/null 2>&1
    assert_eq "$LLM_PRESENCE_ROUTER" "2.5"
    LLM_PRESENCE_ROUTER=""  # restore to empty (model default)
  }

  it "_cmd_model rejects out-of-range temp" && {
    LLM_TEMPERATURE=0.15
    _cmd_model "temp 5.0" >/dev/null 2>&1
    assert_eq "$LLM_TEMPERATURE" "0.15"
  }

  it "_cmd_model rejects non-numeric input" && {
    LLM_TEMPERATURE=0.15
    _cmd_model "temp abc" >/dev/null 2>&1
    assert_eq "$LLM_TEMPERATURE" "0.15"
  }

  it "_cmd_model reset restores model defaults" && {
    # Set everything to non-default values
    LLM_TEMPERATURE=0.9
    LLM_REPEAT_PENALTY=2.0
    LLM_PRESENCE_PENALTY=0.5
    LLM_TEMP_ASK=0.9
    LLM_TEMP_ROUTER=0.9
    LLM_PRESENCE_JOURNAL=0.5
    _cmd_model "reset" >/dev/null 2>&1
    # After reset, globals match model registry (minist-inst: 0.125/1.0/0.0)
    assert_eq "$LLM_TEMPERATURE" "0.125"
    assert_eq "$LLM_REPEAT_PENALTY" "1.0"
    assert_eq "$LLM_PRESENCE_PENALTY" "0.0"
    # Per-scenario overrides are cleared (empty = inherit model default)
    assert_eq "$LLM_TEMP_ASK" ""
    assert_eq "$LLM_TEMP_ROUTER" ""
    assert_eq "$LLM_PRESENCE_JOURNAL" ""
  }

# ── /debug command ─────────────────────────────────────────────
describe "Debug command"

  it "registers debug command" && {
    commands_is_command "/debug"
    assert_ok $?
  }

  it "_cmd_debug is defined" && {
    declare -f _cmd_debug &>/dev/null
    assert_ok $?
  }

  it "_cmd_debug toggles on" && {
    LODGE_DEBUG=0
    _cmd_debug "on" >/dev/null 2>&1
    assert_eq "$LODGE_DEBUG" "1"
  }

  it "_cmd_debug toggles off" && {
    LODGE_DEBUG=1
    _cmd_debug "off" >/dev/null 2>&1
    assert_eq "$LODGE_DEBUG" "0"
  }

  it "_cmd_debug toggles with no arg" && {
    LODGE_DEBUG=0
    _cmd_debug "" >/dev/null 2>&1
    assert_eq "$LODGE_DEBUG" "1"
    _cmd_debug "" >/dev/null 2>&1
    assert_eq "$LODGE_DEBUG" "0"
  }

  it "_cmd_clear is defined" && {
    declare -f _cmd_clear &>/dev/null
    assert_ok $?
  }

  it "_cmd_files is defined" && {
    declare -f _cmd_files &>/dev/null
    assert_ok $?
  }

  it "_cmd_read is defined" && {
    declare -f _cmd_read &>/dev/null
    assert_ok $?
  }

  it "_cmd_email is defined" && {
    declare -f _cmd_email &>/dev/null
    assert_ok $?
  }

  it "_cmd_git is defined" && {
    declare -f _cmd_git &>/dev/null
    assert_ok $?
  }

  it "_cmd_cleanup is defined" && {
    declare -f _cmd_cleanup &>/dev/null
    assert_ok $?
  }

# ── Sandbox fuzzy action resolver ──────────────────────────────
describe "Sandbox fuzzy action resolver — _sandbox_fuzzy_action"

  it "resolves exact 'list'" && {
    _sandbox_fuzzy_action "list"
    assert_eq "$_SANDBOX_ACTION" "list"
  }

  it "resolves 'show' → list" && {
    _sandbox_fuzzy_action "show"
    assert_eq "$_SANDBOX_ACTION" "list"
  }

  it "resolves 'make' → new" && {
    _sandbox_fuzzy_action "make"
    assert_eq "$_SANDBOX_ACTION" "new"
  }

  it "resolves 'create' → new" && {
    _sandbox_fuzzy_action "create"
    assert_eq "$_SANDBOX_ACTION" "new"
  }

  it "resolves 'delete' → rm" && {
    _sandbox_fuzzy_action "delete"
    assert_eq "$_SANDBOX_ACTION" "rm"
  }

  it "resolves 'destroy' → rm" && {
    _sandbox_fuzzy_action "destroy"
    assert_eq "$_SANDBOX_ACTION" "rm"
  }

  it "resolves 'enter' → cd" && {
    _sandbox_fuzzy_action "enter"
    assert_eq "$_SANDBOX_ACTION" "cd"
  }

  it "resolves 'execute' → run" && {
    _sandbox_fuzzy_action "execute"
    assert_eq "$_SANDBOX_ACTION" "run"
  }

  it "resolves 'compile' → build" && {
    _sandbox_fuzzy_action "compile"
    assert_eq "$_SANDBOX_ACTION" "build"
  }

  it "resolves 'verify' → test" && {
    _sandbox_fuzzy_action "verify"
    assert_eq "$_SANDBOX_ACTION" "test"
  }

  it "resolves 'info' → status" && {
    _sandbox_fuzzy_action "info"
    assert_eq "$_SANDBOX_ACTION" "status"
  }

  it "resolves 'history' → journal" && {
    _sandbox_fuzzy_action "history"
    assert_eq "$_SANDBOX_ACTION" "journal"
  }

  it "is case-insensitive" && {
    _sandbox_fuzzy_action "CREATE"
    assert_eq "$_SANDBOX_ACTION" "new"
  }

  it "fails on gibberish" && {
    _sandbox_fuzzy_action "xyzzy"
    assert_fail $?
  }

# ── Sandbox fuzzy type resolver ───────────────────────────────
describe "Sandbox fuzzy type resolver — _sandbox_fuzzy_type"

  it "resolves exact 'rust'" && {
    _sandbox_fuzzy_type "rust"
    assert_eq "$_SANDBOX_TYPE" "rust"
  }

  it "resolves 'rs' → rust" && {
    _sandbox_fuzzy_type "rs"
    assert_eq "$_SANDBOX_TYPE" "rust"
  }

  it "resolves 'cargo' → rust" && {
    _sandbox_fuzzy_type "cargo"
    assert_eq "$_SANDBOX_TYPE" "rust"
  }

  it "resolves 'py' → python" && {
    _sandbox_fuzzy_type "py"
    assert_eq "$_SANDBOX_TYPE" "python"
  }

  it "resolves 'python3' → python" && {
    _sandbox_fuzzy_type "python3"
    assert_eq "$_SANDBOX_TYPE" "python"
  }

  it "resolves 'bash' → shell" && {
    _sandbox_fuzzy_type "bash"
    assert_eq "$_SANDBOX_TYPE" "shell"
  }

  it "resolves 'cli' → shell" && {
    _sandbox_fuzzy_type "cli"
    assert_eq "$_SANDBOX_TYPE" "shell"
  }

  it "resolves 'rustlang' → rust via substring" && {
    _sandbox_fuzzy_type "rustlang"
    assert_eq "$_SANDBOX_TYPE" "rust"
  }

  it "is case-insensitive" && {
    _sandbox_fuzzy_type "PYTHON"
    assert_eq "$_SANDBOX_TYPE" "python"
  }

  it "fails on gibberish" && {
    _sandbox_fuzzy_type "xyzzy"
    assert_fail $?
  }

# ── Cancellation infrastructure ───────────────────────────────
describe "Cancellation infrastructure"

  it "_lodge_cleanup is defined" && {
    declare -f _lodge_cleanup &>/dev/null
    assert_ok $?
  }

  it "INT trap is set" && {
    traps=$(trap -p INT)
    assert_not_empty "$traps"
  }

  it "TERM trap is set" && {
    traps=$(trap -p TERM)
    assert_not_empty "$traps"
  }

  it "EXIT trap is set for exit cleanup" && {
    traps=$(trap -p EXIT)
    assert_not_empty "$traps"
  }

  it "_lodge_exit_cleanup is defined" && {
    declare -f _lodge_exit_cleanup &>/dev/null
    assert_ok $?
  }

  it "_lodge_cleanup kills llama-server curls (v1/chat/completions)" && {
    _body=$(declare -f _lodge_cleanup 2>/dev/null || echo "")
    echo "$_body" | grep -q 'v1/chat/completions'
    assert_ok $? "cleanup must kill curls targeting llama-server endpoint"
  }

  it "_lodge_cleanup kills tracked _LLM_CURL_PID" && {
    _body=$(declare -f _lodge_cleanup 2>/dev/null || echo "")
    echo "$_body" | grep -q '_LLM_CURL_PID'
    assert_ok $? "cleanup must kill tracked curl PID"
  }

  it "_lodge_cleanup removes FIFO temp files" && {
    _body=$(declare -f _lodge_cleanup 2>/dev/null || echo "")
    echo "$_body" | grep -q 'lodge-fifo'
    assert_ok $? "cleanup must remove FIFO files"
  }

  it "_lodge_exit_cleanup kills orphan llama-server curls" && {
    _body=$(declare -f _lodge_exit_cleanup 2>/dev/null || echo "")
    echo "$_body" | grep -q 'v1/chat/completions'
    assert_ok $? "exit cleanup must kill curls targeting llama-server"
  }

# ── Email send parser: address= alias ───────────────────────────────
describe "Email send parser — address= alias"

  it "_cmd_email normalizes address= to to=" && {
    body=$(declare -f _cmd_email)
    echo "$body" | grep -q 'address=/to='
    assert_ok $?
  }

  it "_cmd_email help mentions address=" && {
    body=$(declare -f _cmd_email)
    echo "$body" | grep -q 'address='
    assert_ok $?
  }

  it "_cmd_email accepted formats comment includes address=" && {
    body=$(declare -f _cmd_email)
    echo "$body" | grep -q 'address=addr'
    assert_ok $?
  }

# ── GPU command ───────────────────────────────────────────────
describe "GPU layers command (/gpu)"

  it "_cmd_gpu is defined" && {
    declare -f _cmd_gpu &>/dev/null
    assert_ok $?
  }

  it "/gpu is registered" && {
    assert_not_empty "${CMD_REGISTRY[gpu]:-}" "/gpu must be registered"
  }

  it "LLAMA_CPP_GPU_LAYERS defaults to 0 (CPU only — Adreno 830 Vulkan broken)" && {
    # Re-source to check default
    _gpu_default=$(grep 'LLAMA_CPP_GPU_LAYERS=' "$LODGE_DIR/lib/llm.sh" | head -1)
    echo "$_gpu_default" | grep -q ':-0}'
    assert_ok $? "Default should be 0, got: $_gpu_default"
  }

  it "/gpu sets LLAMA_CPP_GPU_LAYERS" && {
    _gpu_old="${LLAMA_CPP_GPU_LAYERS:-}"
    _cmd_gpu "15" 2>/dev/null
    assert_eq "$LLAMA_CPP_GPU_LAYERS" "15"
    LLAMA_CPP_GPU_LAYERS="$_gpu_old"
  }

  it "/gpu rejects non-integer input" && {
    _gpu_old="${LLAMA_CPP_GPU_LAYERS:-}"
    _cmd_gpu "abc" 2>/dev/null || true
    # Should remain unchanged
    assert_eq "${LLAMA_CPP_GPU_LAYERS:-}" "$_gpu_old"
  }

  it "/gpu 0 is valid (CPU only)" && {
    _gpu_old="${LLAMA_CPP_GPU_LAYERS:-}"
    _cmd_gpu "0" 2>/dev/null
    assert_eq "$LLAMA_CPP_GPU_LAYERS" "0"
    LLAMA_CPP_GPU_LAYERS="$_gpu_old"
  }

  it "/backend start uses --jinja (not per-model template names)" && {
    _gpu_body=$(declare -f _cmd_backend)
    echo "$_gpu_body" | grep -q '_llm_start_llamacpp_server'
    assert_ok $? "/backend start must call _llm_start_llamacpp_server"
    # Should NOT resolve per-model template names — --jinja handles it
    ! echo "$_gpu_body" | grep -q '_models_resolve_chat_template'
    assert_ok $? "/backend start should rely on --jinja, not template name mapping"
  }

# ── Email attachment parser ────────────────────────────────────
describe "Email send parser — attachment support"

  it "_cmd_email normalizes file= to f=" && {
    body=$(declare -f _cmd_email)
    echo "$body" | grep -q 'file=/f='
    assert_ok $? "Must alias file= to f="
  }

  it "_cmd_email normalizes attach= to f=" && {
    body=$(declare -f _cmd_email)
    echo "$body" | grep -q 'attach=/f='
    assert_ok $? "Must alias attach= to f="
  }

  it "_cmd_email passes attachment to email_send" && {
    body=$(declare -f _cmd_email)
    echo "$body" | grep -q 'email_send.*attachment'
    assert_ok $? "Must pass attachment parameter to email_send"
  }

  it "_cmd_email help shows f= parameter" && {
    body=$(declare -f _cmd_email)
    echo "$body" | grep -q 'f=file.txt\|f=.*\.md\|f=.*\.txt'
    assert_ok $? "Help must mention f= parameter"
  }

  it "b= parser stops at f=" && {
    body=$(declare -f _cmd_email)
    # Body parsing should strip f= to avoid including it in body text
    echo "$body" | grep -q 'body.*f=\|%% f='
    assert_ok $? "Body parser must stop at f= boundary"
  }

  it "s= parser stops at f=" && {
    body=$(declare -f _cmd_email)
    # Subject parsing should also respect f= boundary
    echo "$body" | grep -q 'f=.*subject\|subject.*f='
    assert_ok $? "Subject parser must stop at f= boundary"
  }

# ── Email provider normalization ───────────────────────────────
describe "Email provider normalization"

  it "_cmd_email defines _normalize_provider helper" && {
    body=$(declare -f _cmd_email)
    echo "$body" | grep -q '_normalize_provider'
    assert_ok $? "Must define _normalize_provider"
  }

  it "_normalize_provider strips provider= prefix" && {
    body=$(declare -f _cmd_email)
    echo "$body" | grep -q 'provider='
    assert_ok $? "Must handle provider= prefix"
  }

  it "_normalize_provider strips p= prefix" && {
    body=$(declare -f _cmd_email)
    echo "$body" | grep -q '{_val#p=}'
    assert_ok $? "Must handle p= prefix"
  }

  it "send action normalizes provider" && {
    body=$(declare -f _cmd_email)
    echo "$body" | grep -A2 'send)' | head -20
    echo "$body" | grep -q '_normalize_provider.*provider\|provider.*_normalize_provider'
    assert_ok $? "send must normalize provider"
  }

  it "inbox action normalizes provider" && {
    body=$(declare -f _cmd_email)
    echo "$body" | grep -q '_normalize_provider.*_inbox_provider\|_inbox_provider.*_normalize_provider'
    assert_ok $? "inbox must normalize provider"
  }

  it "status action normalizes provider" && {
    body=$(declare -f _cmd_email)
    echo "$body" | grep -q '_normalize_provider.*_st_provider\|_st_provider=\$(_normalize_provider'
    assert_ok $? "status must normalize provider"
  }

  it "address action normalizes provider" && {
    body=$(declare -f _cmd_email)
    echo "$body" | grep -q '_normalize_provider.*_addr_provider\|_addr_provider=\$(_normalize_provider'
    assert_ok $? "address must normalize provider"
  }

  it "setup action normalizes provider" && {
    body=$(declare -f _cmd_email)
    # setup uses $rest directly — must normalize before passing
    echo "$body" | grep -B1 'email_setup' | grep -q '_normalize_provider'
    assert_ok $? "setup must normalize provider"
  }

  it "_normalize_provider resolves provider=gmail to gmail" && {
    # _normalize_provider is local to _cmd_email; exercise via direct call
    _cmd_email "send provider=gmail test@x.com s=Hi b=Hello" 2>/dev/null || true
    # If normalisation works, it won't blow up looking for "provider=gmail" as a provider name.
    # Introspect: the body must strip provider= before passing to email_send
    body=$(declare -f _cmd_email)
    echo "$body" | grep -q '{_val#provider=}'
    assert_ok $? "provider= prefix strip must exist"
  }

  it "_normalize_provider resolves p=zoho to zoho" && {
    body=$(declare -f _cmd_email)
    echo "$body" | grep -q '{_val#p=}'
    assert_ok $? "p= prefix strip must exist"
  }

# ── /provider use command ──────────────────────────────────────
describe "/provider use command"

  it "_cmd_provider handles 'use' action" && {
    body=$(declare -f _cmd_provider)
    echo "$body" | grep -q 'use.*harness'
    assert_ok $? "_cmd_provider must handle use|harness action"
  }

  it "_cmd_provider use calls provider_use" && {
    body=$(declare -f _cmd_provider)
    echo "$body" | grep -q 'provider_use'
    assert_ok $? "_cmd_provider use must call provider_use"
  }

  it "_cmd_provider help mentions use" && {
    body=$(declare -f _cmd_provider)
    echo "$body" | grep -q 'use.*provider.*Route\|use.*local.*Switch'
    assert_ok $? "help text must mention /provider use"
  }

  it "_cmd_provider use supports provider/model syntax" && {
    body=$(declare -f _cmd_provider)
    echo "$body" | grep -q 'model_override.*provider#\*/\|provider%%/\*'
    assert_ok $? "provider/model syntax must be parsed"
  }

  it "_cmd_provider handles delay action" && {
    body=$(declare -f _cmd_provider)
    echo "$body" | grep -q 'delay.*throttle'
    assert_ok $? "_cmd_provider must handle delay|throttle action"
  }

  it "_cmd_provider delay calls provider_set_delay" && {
    body=$(declare -f _cmd_provider)
    echo "$body" | grep -q 'provider_set_delay'
    assert_ok $? "delay action must call provider_set_delay"
  }

  it "_cmd_provider help mentions delay" && {
    body=$(declare -f _cmd_provider)
    echo "$body" | grep -q 'delay.*seconds.*gap\|delay.*Set'
    assert_ok $? "help text must mention /provider delay"
  }

# ── /limits subcommands ────────────────────────────────────────
describe "/limits models subcommand"

  it "_cmd_limits handles models action" && {
    body=$(declare -f _cmd_limits)
    echo "$body" | grep -q 'models)'
    assert_ok $? "_cmd_limits must have models case branch"
  }

  it "_cmd_limits models uses free-tier-limits.json" && {
    body=$(declare -f _cmd_limits)
    echo "$body" | grep -q 'free-tier-limits.json'
    assert_ok $? "models must reference config file"
  }

  it "_cmd_limits models reads rate limit data from config" && {
    body=$(declare -f _cmd_limits)
    echo "$body" | grep -q 'free-tier-limits.json'
    assert_ok $? "models must read from config file"
  }

describe "/limits suggest subcommand"

  it "_cmd_limits handles suggest action" && {
    body=$(declare -f _cmd_limits)
    echo "$body" | grep -q 'suggest)'
    assert_ok $? "_cmd_limits must have suggest case branch"
  }

  it "_cmd_limits suggest calls provider_suggested_limits" && {
    body=$(declare -f _cmd_limits)
    echo "$body" | grep -q 'provider_suggested_limits'
    assert_ok $? "suggest must call provider_suggested_limits"
  }

describe "/limits apply subcommand"

  it "_cmd_limits handles apply action" && {
    body=$(declare -f _cmd_limits)
    echo "$body" | grep -q 'apply)'
    assert_ok $? "_cmd_limits must have apply case branch"
  }

  it "_cmd_limits apply calls provider_apply_suggested_limits" && {
    body=$(declare -f _cmd_limits)
    echo "$body" | grep -q 'provider_apply_suggested_limits'
    assert_ok $? "apply must call provider_apply_suggested_limits"
  }

describe "/limits fetch subcommand"

  it "_cmd_limits handles fetch action" && {
    body=$(declare -f _cmd_limits)
    echo "$body" | grep -q 'fetch)'
    assert_ok $? "_cmd_limits must have fetch case branch"
  }

  it "_cmd_limits fetch calls provider_models" && {
    body=$(declare -f _cmd_limits)
    echo "$body" | grep -q 'provider_models'
    assert_ok $? "fetch must call provider_models"
  }

describe "/limits help text"

  it "help mentions models subcommand" && {
    body=$(declare -f _cmd_limits)
    echo "$body" | grep -q 'models.*free-tier\|models.*rate limit'
    assert_ok $? "help must mention /limits models"
  }

  it "help mentions suggest subcommand" && {
    body=$(declare -f _cmd_limits)
    echo "$body" | grep -q 'suggest.*recommended\|suggest.*settings'
    assert_ok $? "help must mention /limits suggest"
  }

  it "help mentions apply subcommand" && {
    body=$(declare -f _cmd_limits)
    echo "$body" | grep -q 'apply.*suggested\|apply.*settings\|apply.*automatically'
    assert_ok $? "help must mention /limits apply"
  }

  it "help mentions fetch subcommand" && {
    body=$(declare -f _cmd_limits)
    echo "$body" | grep -q 'fetch.*API\|fetch.*models'
    assert_ok $? "help must mention /limits fetch"
  }

# ── /recall subcommands ───────────────────────────────────────
describe "/recall REPL subcommands"

  it "_cmd_recall handles prefs subcommand" && {
    body=$(declare -f _cmd_recall)
    echo "$body" | grep -q 'prefs'
    assert_ok $? "_cmd_recall must handle prefs subcommand"
  }

  it "_cmd_recall handles prune subcommand" && {
    body=$(declare -f _cmd_recall)
    echo "$body" | grep -q 'prune'
    assert_ok $? "_cmd_recall must handle prune subcommand"
  }

  it "_cmd_recall handles compact subcommand" && {
    body=$(declare -f _cmd_recall)
    echo "$body" | grep -q 'compact'
    assert_ok $? "_cmd_recall must handle compact subcommand"
  }

  it "_cmd_recall handles clearprefs subcommand" && {
    body=$(declare -f _cmd_recall)
    echo "$body" | grep -q 'clearprefs'
    assert_ok $? "_cmd_recall must handle clearprefs subcommand"
  }

  it "_cmd_recall help mentions prune usage" && {
    body=$(declare -f _cmd_recall)
    echo "$body" | grep -q 'recall prune'
    assert_ok $? "help must show /recall prune usage"
  }

test_end
