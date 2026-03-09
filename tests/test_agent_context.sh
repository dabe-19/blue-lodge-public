#!/bin/bash
# ── Tests: Agent Context Flow & Execution Loop Additions ──────
# Covers: workdir propagation, project context card, coding
# workflow card, pre-route remap, force rewrite, embedded
# command extraction, respond→social reroute, _macro_set.
#
# These are the non-deterministic "compile checks" — if a code
# path's key strings vanish or a function's contract breaks,
# these catch it immediately.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/llm.sh"
source "$LODGE_DIR/lib/memory.sh"
source "$LODGE_DIR/lib/tools.sh"
source "$LODGE_DIR/lib/journal.sh"
source "$LODGE_DIR/lib/agent.sh"

test_start "Agent Context Flow & Execution Loop"

# ═══════════════════════════════════════════════════════════════
# _macro_set — generic macro_memory JSON setter
# ═══════════════════════════════════════════════════════════════
describe "_macro_set"

  it "is defined" && {
    declare -f _macro_set &>/dev/null
    assert_ok $?
  }

  it "sets a new key in macro_memory JSON" && {
    _tmp=$(mktemp)
    echo '{"task":"hello"}' > "$_tmp"
    _macro_set "$_tmp" "mykey" "myval"
    _got=$(jq -r '.mykey' "$_tmp" 2>/dev/null)
    assert_eq "$_got" "myval"
    rm -f "$_tmp"
  }

  it "overwrites an existing key" && {
    _tmp=$(mktemp)
    echo '{"task":"hello","status":"old"}' > "$_tmp"
    _macro_set "$_tmp" "status" "new"
    _got=$(jq -r '.status' "$_tmp" 2>/dev/null)
    assert_eq "$_got" "new"
    rm -f "$_tmp"
  }

  it "preserves other keys when setting" && {
    _tmp=$(mktemp)
    echo '{"task":"hello","count":5}' > "$_tmp"
    _macro_set "$_tmp" "newkey" "newval"
    _task=$(jq -r '.task' "$_tmp" 2>/dev/null)
    assert_eq "$_task" "hello"
    _count=$(jq -r '.count' "$_tmp" 2>/dev/null)
    assert_eq "$_count" "5"
    rm -f "$_tmp"
  }

  it "uses atomic tmp+mv write pattern" && {
    body=$(declare -f _macro_set)
    echo "$body" | grep -q '\.tmp'
    assert_ok $? "Must use tmp file for atomic write"
    echo "$body" | grep -q 'mv'
    assert_ok $? "Must mv tmp to target"
  }

  it "sets project_context field (used by workdir propagation)" && {
    _tmp=$(mktemp)
    echo '{"task":"test","project_context":null}' > "$_tmp"
    _macro_set "$_tmp" "project_context" "# GEORGE — fizzbuzz"
    _got=$(jq -r '.project_context' "$_tmp" 2>/dev/null)
    assert_contains "$_got" "GEORGE"
    rm -f "$_tmp"
  }

# ═══════════════════════════════════════════════════════════════
# _AGENT_WORKDIR_CHANGED — workdir propagation signal
# ═══════════════════════════════════════════════════════════════
describe "Workdir propagation signal"

  it "/cd intercept sets _AGENT_WORKDIR_CHANGED" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_AGENT_WORKDIR_CHANGED=.*workdir'
    assert_ok $? "Must set _AGENT_WORKDIR_CHANGED in /cd intercept"
  }

  it "/cd intercept only signals on successful cd" && {
    body=$(declare -f agent_inner_loop)
    # The signal is inside an exit_code == 0 guard
    echo "$body" | grep -B2 '_AGENT_WORKDIR_CHANGED=.*workdir' | grep -q 'exit_code.*-eq 0'
    assert_ok $? "Must gate signal on exit_code 0"
  }

  it "POST-INIT sets _AGENT_WORKDIR_CHANGED" && {
    # Comments are stripped by declare -f, grep source file instead
    _src="$LODGE_DIR/lib/agent.sh"
    grep -q 'POST-INIT WORKDIR UPDATE' "$_src"
    assert_ok $? "Must have POST-INIT section"
    # The _AGENT_WORKDIR_CHANGED must appear near the POST-INIT block
    sed -n '/POST-INIT WORKDIR/,/last_success_cmd/p' "$_src" | grep -q '_AGENT_WORKDIR_CHANGED'
    assert_ok $? "Must set _AGENT_WORKDIR_CHANGED in POST-INIT block"
  }

  it "agent_run resets signal before each milestone" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_AGENT_WORKDIR_CHANGED=""'
    assert_ok $? "Must reset signal at top of macro loop"
  }

  it "agent_run propagates workdir on milestone success" && {
    _src="$LODGE_DIR/lib/agent.sh"
    grep -q 'WORKDIR PROPAGATION' "$_src"
    assert_ok $? "Must have WORKDIR PROPAGATION section"
    sed -n '/WORKDIR PROPAGATION/,/Track research/p' "$_src" | head -20 | grep -q '_AGENT_WORKDIR_CHANGED'
    assert_ok $? "Must check signal in success path"
  }

  it "agent_run propagates workdir on milestone failure" && {
    _src="$LODGE_DIR/lib/agent.sh"
    grep -q 'even on failure' "$_src"
    assert_ok $? "Must propagate workdir even when milestone fails"
  }

  it "propagation updates george_dir" && {
    body=$(declare -f agent_run)
    # After workdir update, must re-derive george_dir
    echo "$body" | grep -A5 'workdir=.*_AGENT_WORKDIR_CHANGED' | grep -q 'george_dir=.*workdir/.george'
    assert_ok $? "Must re-derive george_dir from new workdir"
  }

  it "propagation updates macro_file" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -A6 'workdir=.*_AGENT_WORKDIR_CHANGED' | grep -q 'macro_file=.*george_dir'
    assert_ok $? "Must re-derive macro_file from new george_dir"
  }

  it "propagation updates micro_file" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -A7 'workdir=.*_AGENT_WORKDIR_CHANGED' | grep -q 'micro_file=.*george_dir'
    assert_ok $? "Must re-derive micro_file from new george_dir"
  }

  it "propagation re-reads GEORGE.md into project_context" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -A15 'workdir=.*_AGENT_WORKDIR_CHANGED' | grep -q '_macro_set.*macro_file.*project_context'
    assert_ok $? "Must call _macro_set to update project_context"
  }

  it "propagation creates .george dir if missing" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -A10 'workdir=.*_AGENT_WORKDIR_CHANGED' | grep -q 'mkdir -p.*george_dir'
    assert_ok $? "Must mkdir -p new george_dir"
  }

  it "propagation has debug logging" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q 'macro workdir updated'
    assert_ok $? "Must log workdir update in debug mode"
  }

# Functional test: simulate the propagation chain
  it "propagation chain updates all derived paths" && (
    # Simulate what agent_run does when _AGENT_WORKDIR_CHANGED is set
    _AGENT_WORKDIR_CHANGED="/tmp/test_project_abc"
    workdir="/tmp/original"
    george_dir="$workdir/.george"
    macro_file="$george_dir/macro_memory.json"
    micro_file="$george_dir/micro_memory.json"
    fail_file="$george_dir/failures_log.md"

    # Apply the propagation logic
    if [ -n "${_AGENT_WORKDIR_CHANGED:-}" ]; then
        workdir="$_AGENT_WORKDIR_CHANGED"
        george_dir="$workdir/.george"
        macro_file="$george_dir/macro_memory.json"
        micro_file="$george_dir/micro_memory.json"
        fail_file="$george_dir/failures_log.md"
    fi

    assert_eq "$workdir" "/tmp/test_project_abc"
    assert_eq "$george_dir" "/tmp/test_project_abc/.george"
    assert_eq "$macro_file" "/tmp/test_project_abc/.george/macro_memory.json"
    assert_eq "$micro_file" "/tmp/test_project_abc/.george/micro_memory.json"
    assert_eq "$fail_file" "/tmp/test_project_abc/.george/failures_log.md"
  )

# ═══════════════════════════════════════════════════════════════
# Project context card — JSON injection in specialist
# ═══════════════════════════════════════════════════════════════
describe "Project context card (specialist)"

  it "_build_specialist_prompt contains PROJECT CONTEXT CARD section" && {
    _src="$LODGE_DIR/lib/agent.sh"
    grep -q 'PROJECT CONTEXT CARD' "$_src"
    assert_ok $? "Must have project context card section"
  }

  it "triggers for /write command" && {
    _src="$LODGE_DIR/lib/agent.sh"
    grep -q 'write|build|test|fix|init|save' "$_src"
    assert_ok $? "Must trigger for coding commands"
  }

  it "requires GEORGE.md to exist" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'workdir/GEORGE.md'
    assert_ok $? "Must check for GEORGE.md"
  }

  it "parses project name from GEORGE.md" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q "awk.*name:.*print"
    assert_ok $? "Must parse name field from GEORGE.md"
  }

  it "parses project type from GEORGE.md" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q "awk.*type:.*print"
    assert_ok $? "Must parse type field from GEORGE.md"
  }

  it "parses build command from GEORGE.md" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q "awk.*build:.*print"
    assert_ok $? "Must parse build field from GEORGE.md"
  }

  it "parses test command from GEORGE.md" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q "awk.*test:.*print"
    assert_ok $? "Must parse test field from GEORGE.md"
  }

  it "skips build key when N/A" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q '_build_cmd.*!=.*N/A'
    assert_ok $? "Must skip build when N/A"
  }

  it "skips test key when N/A" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q '_test_cmd.*!=.*N/A'
    assert_ok $? "Must skip test when N/A"
  }

  it "uses find for project structure listing" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'find.*workdir.*maxdepth 2'
    assert_ok $? "Must use find -maxdepth 2 for file listing"
  }

  it "excludes .george and .git dirs from listing" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q '.george'
    assert_ok $?
    echo "$body" | grep -q '.git'
    assert_ok $?
  }

  it "caps file listing at 15 entries" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'head -15'
    assert_ok $? "Must cap file listing to prevent token bloat"
  }

  it "outputs valid JSON project card" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q '"project":'
    assert_ok $? "Must output JSON with project key"
    echo "$body" | grep -q '"rules":'
    assert_ok $? "Must output JSON with rules key"
  }

  it "includes relative path rule in JSON" && {
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'ALL /write paths MUST be relative to project root'
    assert_ok $? "Must enforce relative paths rule"
  }

  it "does NOT trigger for /respond" && {
    _src="$LODGE_DIR/lib/agent.sh"
    # The case statement should NOT include respond
    _case_line=$(grep 'write|build|test|fix|init|save' "$_src")
    echo "$_case_line" | grep -qv 'respond'
    assert_ok $? "Respond must NOT trigger project context"
  }

  it "does NOT trigger for /web" && {
    _src="$LODGE_DIR/lib/agent.sh"
    _case_line=$(grep 'write|build|test|fix|init|save' "$_src")
    echo "$_case_line" | grep -qv '"web"'
    assert_ok $? "Web must NOT trigger project context"
  }

# Functional test: build a real GEORGE.md and verify card output
  it "generates valid JSON for Rust project" && {
    _test_dir=$(mktemp -d)
    # Create GEORGE.md like init.sh would
    cat > "$_test_dir/GEORGE.md" << 'EOF'
# GEORGE — fizzbuzz

## Project
name: fizzbuzz
type: Rust

## Build
build: cargo build
test: cargo test

## Active Task
(none)

## Completed Milestones
(none)
EOF
    mkdir -p "$_test_dir/src"
    echo 'fn main() {}' > "$_test_dir/src/main.rs"
    echo '[package]' > "$_test_dir/Cargo.toml"

    _output=$(_build_specialist_prompt "/write" "$_test_dir" "write fizzbuzz source code" 2>/dev/null)
    # Must contain JSON project card
    assert_contains "$_output" '"project":'
    assert_contains "$_output" '"fizzbuzz"'
    assert_contains "$_output" '"Rust"'
    assert_contains "$_output" '"cargo build"'
    assert_contains "$_output" '"cargo test"'
    assert_contains "$_output" 'src/main.rs'
    # Validate it's parseable JSON (extract just the card line)
    _json_line=$(echo "$_output" | grep '"project":' | head -1)
    echo "$_json_line" | python3 -m json.tool >/dev/null 2>&1
    assert_ok $? "Project context card must be valid JSON"
    rm -rf "$_test_dir"
  }

  it "generates valid JSON with no build/test" && {
    _test_dir=$(mktemp -d)
    cat > "$_test_dir/GEORGE.md" << 'EOF'
# GEORGE — myapp

## Project
name: myapp
type: shell

## Build
build: N/A
test: N/A

## Active Task
(none)
EOF
    _output=$(_build_specialist_prompt "/write" "$_test_dir" "write a script" 2>/dev/null)
    assert_contains "$_output" '"myapp"'
    assert_contains "$_output" '"shell"'
    # Must NOT contain build or test keys
    assert_not_contains "$_output" '"build":"N/A"'
    assert_not_contains "$_output" '"test":"N/A"'
    # Still must be valid JSON
    _json_line=$(echo "$_output" | grep '"project":' | head -1)
    echo "$_json_line" | python3 -m json.tool >/dev/null 2>&1
    assert_ok $? "Card with no build/test must still be valid JSON"
    rm -rf "$_test_dir"
  }

  it "no project card when GEORGE.md missing" && {
    _test_dir=$(mktemp -d)
    _output=$(_build_specialist_prompt "/write" "$_test_dir" "write a file" 2>/dev/null)
    assert_not_contains "$_output" '"project":'
    rm -rf "$_test_dir"
  }

  it "no project card for /social command" && {
    _test_dir=$(mktemp -d)
    cat > "$_test_dir/GEORGE.md" << 'EOF'
# GEORGE — fizzbuzz
## Project
name: fizzbuzz
type: Rust
## Build
build: cargo build
test: cargo test
EOF
    _output=$(_build_specialist_prompt "/social" "$_test_dir" "post to discord" 2>/dev/null)
    assert_not_contains "$_output" '"project":'
    rm -rf "$_test_dir"
  }

# ═══════════════════════════════════════════════════════════════
# Coding workflow card — JSON in strategist
# ═══════════════════════════════════════════════════════════════
describe "Coding workflow card (strategist)"

  it "exists in agent_run" && {
    _src="$LODGE_DIR/lib/agent.sh"
    grep -q 'Coding workflow card' "$_src"
    assert_ok $?
  }

  it "uses _coding_card variable" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_coding_card='
    assert_ok $?
  }

  it "detection combines task and honeydew" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_coding_signal=.*task.*_strat_honeydew'
    assert_ok $? "Must combine task + honeydew for detection"
  }

  it "lowercases the detection signal" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q "_coding_signal.*tr.*'\\[:upper:\\]'.*'\\[:lower:\\]'"
    assert_ok $? "Must lowercase before regex match"
  }

  it "detects Rust keyword" && {
    _signal="build a rust cli tool"
    [[ "$_signal" =~ (rust|cargo|python|pip|node|npm) ]]
    assert_ok $?
  }

  it "detects Python keyword" && {
    _signal="create a python data pipeline"
    [[ "$_signal" =~ (rust|cargo|python|pip|node|npm) ]]
    assert_ok $?
  }

  it "detects cargo keyword" && {
    _signal="use cargo build to make it"
    [[ "$_signal" =~ (rust|cargo|python|pip|node|npm) ]]
    assert_ok $?
  }

  it "detects 'create a project' pattern" && {
    _signal="create a new project for the task"
    [[ "$_signal" =~ (create.*(project|app|cli|tool|program|binary|package|crate|module)) ]]
    assert_ok $?
  }

  it "detects 'scaffold' keyword" && {
    _signal="scaffold the api server"
    [[ "$_signal" =~ (scaffold|new.*project) ]]
    assert_ok $?
  }

  it "detects 'build the project' pattern" && {
    _signal="build the project and run tests"
    [[ "$_signal" =~ (build.*(it|the|this|project|app|code)) ]]
    assert_ok $?
  }

  it "detects .rs file extension" && {
    _signal="write main.rs with fizzbuzz logic"
    [[ "$_signal" =~ \.(rs|py|go|ts|js|cpp|c|java) ]]
    assert_ok $?
  }

  it "does NOT trigger on 'compile a report'" && {
    # "compile" alone must NOT match — it's ambiguous
    _signal="compile a report of findings"
    if [[ "$_signal" =~ (rust|cargo|python|pip|node|npm|typescript|java|maven|gradle|golang|makefile|cmake|clang|gcc|\.(rs|py|go|ts|js|cpp|c|java)\b|create.*(project|app|cli|tool|program|binary|package|crate|module)|scaffold|new.*project|build.*(it|the|this|project|app|code)|run.*(the|it|this).*(project|app|program|binary|executable)|init.*(project|app|repo)) ]]; then
        _test_fail "'compile a report' must NOT trigger coding card"
    else
        _test_pass
    fi
  }

  it "does NOT trigger on 'write a summary'" && {
    _signal="write a summary of the meeting notes"
    if [[ "$_signal" =~ (rust|cargo|python|pip|node|npm|typescript|java|maven|gradle|golang|makefile|cmake|clang|gcc|\.(rs|py|go|ts|js|cpp|c|java)\b|create.*(project|app|cli|tool|program|binary|package|crate|module)|scaffold|new.*project|build.*(it|the|this|project|app|code)|run.*(the|it|this).*(project|app|program|binary|executable)|init.*(project|app|repo)) ]]; then
        _test_fail "'write a summary' must NOT trigger coding card"
    else
        _test_pass
    fi
  }

  it "card JSON contains /init command description" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '"/init <name> <type>":"scaffold'
    assert_ok $? "Card must describe /init"
  }

  it "card JSON contains /build command" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '"/build":"build the project'
    assert_ok $? "Card must describe /build"
  }

  it "card JSON contains /test command" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '"/test":"run test suite'
    assert_ok $? "Card must describe /test"
  }

  it "card JSON contains /fix command" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '"/fix":"auto-fix errors'
    assert_ok $? "Card must describe /fix"
  }

  it "card JSON contains workflow sequence" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '"workflow":.*"/init".*"/write source files".*"/build".*"/test"'
    assert_ok $? "Card must contain workflow sequence"
  }

  it "card is valid JSON" && {
    _card='{"coding":{"commands":{"/init <name> <type>":"scaffold new project (Cargo.toml, pyproject.toml, etc.)","/build":"build the project (cargo build, make, etc.)","/test":"run test suite (cargo test, pytest, etc.)","/fix":"auto-fix errors from last /build or /test","/write <path> <code>":"write code to a FILE (not for building or running)"},"workflow":["/init","/write source files","/build","/test","/fix if needed"]}}'
    echo "$_card" | python3 -m json.tool >/dev/null 2>&1
    assert_ok $? "Coding workflow card must be valid JSON"
  }

# ═══════════════════════════════════════════════════════════════
# Pre-route /write → /init | /build | /test remap
# ═══════════════════════════════════════════════════════════════
describe "Pre-route coding verb remap"

  it "remap section exists in inner loop" && {
    _src="$LODGE_DIR/lib/agent.sh"
    grep -q 'CODING VERB REMAP' "$_src"
    assert_ok $?
  }

  it "only fires when pre-route command is write" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_pre_cmd.*=.*"write"'
    assert_ok $? "Must guard on _pre_cmd == write"
  }

  it "remaps write to init for scaffold objectives" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_pre_cmd="init"'
    assert_ok $? "Must set _pre_cmd to init"
    echo "$body" | grep -q 'coding scaffold detected'
    assert_ok $? "Must log scaffold detection"
  }

  it "remaps write to build for build objectives" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_pre_cmd="build"'
    assert_ok $? "Must set _pre_cmd to build"
    echo "$body" | grep -q 'build action detected'
    assert_ok $? "Must log build detection"
  }

  it "remaps write to test for test objectives" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_pre_cmd="test"'
    assert_ok $? "Must set _pre_cmd to test"
    echo "$body" | grep -q 'test action detected'
    assert_ok $? "Must log test detection"
  }

  # Functional: test the regex patterns directly
  it "scaffold regex matches 'create a new rust project'" && {
    _mo="create a new rust project called fizzbuzz"
    _mo_lower=$(echo "$_mo" | tr '[:upper:]' '[:lower:]')
    [[ "$_mo_lower" =~ (scaffold|create.*(new|a).*(project|app|crate|package|module)|initialize.*(project|app|repo|crate)|init.*(new|a|the).*(project|app)|new.*(rust|python|node|go|java|typescript).*(project|app)) ]]
    assert_ok $?
  }

  it "scaffold regex matches 'scaffold the api'" && {
    _mo="scaffold the api server"
    _mo_lower=$(echo "$_mo" | tr '[:upper:]' '[:lower:]')
    [[ "$_mo_lower" =~ (scaffold|create.*(new|a).*(project|app|crate|package|module)) ]]
    assert_ok $?
  }

  it "scaffold regex matches 'initialize a new app'" && {
    _mo="initialize a new app for tracking"
    _mo_lower=$(echo "$_mo" | tr '[:upper:]' '[:lower:]')
    [[ "$_mo_lower" =~ (initialize.*(project|app|repo|crate)) ]]
    assert_ok $?
  }

  it "build regex matches 'build the project'" && {
    _mo="build the project"
    _mo_lower=$(echo "$_mo" | tr '[:upper:]' '[:lower:]')
    [[ "$_mo_lower" =~ (build.*(the|this|it|project|app|code|binary|crate|package)|cargo.build|make[[:space:]]|npm.run.build|run.*(cargo|make|maven|gradle|cmake)) ]]
    assert_ok $?
  }

  it "build regex matches 'cargo build'" && {
    _mo="run cargo build in release mode"
    _mo_lower=$(echo "$_mo" | tr '[:upper:]' '[:lower:]')
    [[ "$_mo_lower" =~ (cargo.build) ]]
    assert_ok $?
  }

  it "build regex matches 'npm run build'" && {
    _mo="use npm run build to build it"
    _mo_lower=$(echo "$_mo" | tr '[:upper:]' '[:lower:]')
    [[ "$_mo_lower" =~ (npm.run.build) ]]
    assert_ok $?
  }

  it "test regex matches 'run the tests'" && {
    _mo="run the test suite"
    _mo_lower=$(echo "$_mo" | tr '[:upper:]' '[:lower:]')
    [[ "$_mo_lower" =~ (run.*(the|this)?.*(test|spec|suite)|cargo.test|pytest|npm.test|test.*(the|this|it|project|code)) ]]
    assert_ok $?
  }

  it "test regex matches 'cargo test'" && {
    _mo="execute cargo test"
    _mo_lower=$(echo "$_mo" | tr '[:upper:]' '[:lower:]')
    [[ "$_mo_lower" =~ (cargo.test) ]]
    assert_ok $?
  }

  it "test regex matches 'pytest'" && {
    _mo="use pytest to verify"
    _mo_lower=$(echo "$_mo" | tr '[:upper:]' '[:lower:]')
    [[ "$_mo_lower" =~ (pytest) ]]
    assert_ok $?
  }

  it "does NOT remap 'write the fizzbuzz source code'" && {
    _mo="write the fizzbuzz source code to src/main.rs"
    _mo_lower=$(echo "$_mo" | tr '[:upper:]' '[:lower:]')
    _remapped=0
    if [[ "$_mo_lower" =~ (scaffold|create.*(new|a).*(project|app|crate|package|module)|initialize.*(project|app|repo|crate)|init.*(new|a|the).*(project|app)|new.*(rust|python|node|go|java|typescript).*(project|app)) ]]; then
        _remapped=1
    elif [[ "$_mo_lower" =~ (build.*(the|this|it|project|app|code|binary|crate|package)|cargo.build|make[[:space:]]|npm.run.build|run.*(cargo|make|maven|gradle|cmake)) ]]; then
        _remapped=1
    elif [[ "$_mo_lower" =~ (run.*(the|this)?.*(test|spec|suite)|cargo.test|pytest|npm.test|test.*(the|this|it|project|code)) ]]; then
        _remapped=1
    fi
    assert_eq "$_remapped" "0" "Plain source file write must NOT be remapped"
  }

  it "does NOT remap 'write a report'" && {
    _mo="write a comprehensive report on market trends"
    _mo_lower=$(echo "$_mo" | tr '[:upper:]' '[:lower:]')
    _remapped=0
    if [[ "$_mo_lower" =~ (scaffold|create.*(new|a).*(project|app|crate|package|module)|initialize.*(project|app|repo|crate)) ]]; then
        _remapped=1
    elif [[ "$_mo_lower" =~ (build.*(the|this|it|project|app|code|binary|crate|package)|cargo.build) ]]; then
        _remapped=1
    fi
    assert_eq "$_remapped" "0" "Report writing must NOT be remapped"
  }

  it "avoids matching 'compile' as ambiguous" && {
    _src="$LODGE_DIR/lib/agent.sh"
    # The CODING VERB REMAP section must NOT include "compile"
    _section=$(sed -n '/CODING VERB REMAP/,/pre_valid/p' "$_src")
    echo "$_section" | grep -qv 'compile'
    assert_ok $? "Remap must NOT use compile as a keyword"
  }

# ═══════════════════════════════════════════════════════════════
# AGENT_FORCE_REWRITE — honeydew force rewrite toggle
# ═══════════════════════════════════════════════════════════════
describe "AGENT_FORCE_REWRITE"

  it "defaults to 1 (enabled)" && {
    assert_eq "${AGENT_FORCE_REWRITE}" "1"
  }

  it "is overridable" && {
    (
      AGENT_FORCE_REWRITE=0
      assert_eq "$AGENT_FORCE_REWRITE" "0"
    )
    assert_ok $?
  }

  it "_agent_honeydew_rewrite accepts force_rewrite parameter" && {
    body=$(declare -f _agent_honeydew_rewrite)
    echo "$body" | grep -q 'force_rewrite='
    assert_ok $? "Must accept force_rewrite parameter"
  }

  it "force_rewrite overrides KEEP verdict" && {
    body=$(declare -f _agent_honeydew_rewrite)
    echo "$body" | grep -q 'force_rewrite=1.*overriding to REWRITE\|force_rewrite.*-eq 1'
    assert_ok $? "Must override KEEP when force_rewrite=1"
  }

  it "interlock failure passes AGENT_FORCE_REWRITE" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_agent_honeydew_rewrite.*AGENT_FORCE_REWRITE'
    assert_ok $? "Interlock recovery must pass force rewrite flag"
  }

  it "failure auto-recovery passes AGENT_FORCE_REWRITE" && {
    body=$(declare -f agent_run)
    echo "$body" | grep -q '_agent_honeydew_rewrite.*AGENT_FORCE_REWRITE'
    assert_ok $? "Auto-recovery must pass force rewrite flag"
  }

# ═══════════════════════════════════════════════════════════════
# Embedded command extraction
# ═══════════════════════════════════════════════════════════════
describe "Embedded command extraction"

  it "section exists in inner loop" && {
    _src="$LODGE_DIR/lib/agent.sh"
    grep -q 'EMBEDDED COMMAND EXTRACTION' "$_src"
    assert_ok $?
  }

  it "triggers on /respond wrapper" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'cmd.*==.*/respond'
    assert_ok $?
  }

  it "triggers on /write wrapper" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'cmd.*==.*/write'
    assert_ok $?
  }

  it "extracts /social commands" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'social|email'
    assert_ok $? "Must match /social in embedded body"
  }

  it "extracts /email commands" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'social|email'
    assert_ok $? "Must match /email in embedded body"
  }

  it "writes EMBEDDED_CMD note to micro_memory" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'EMBEDDED_CMD.*Extracted'
    assert_ok $? "Must log extraction to micro_memory"
  }

  it "promotes extracted command to primary" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'cmd=.*_embed_match'
    assert_ok $? "Must set cmd to extracted command"
  }

  # Functional: test extraction regex directly
  it "extracts /social from /respond body" && {
    _body="/social dm jazzy92012 Hey there"
    _match=$(printf '%s\n' "$_body" | grep -oE '^[[:space:]]*/(social|email)[[:space:]][[:space:]]*[^[:space:]].*' | head -1 | sed 's/^[[:space:]]*//')
    assert_eq "$_match" "/social dm jazzy92012 Hey there"
  }

  it "extracts /email from /respond body" && {
    _body="/email send user@test.com Subject This is the body"
    _match=$(printf '%s\n' "$_body" | grep -oE '^[[:space:]]*/(social|email)[[:space:]][[:space:]]*[^[:space:]].*' | head -1 | sed 's/^[[:space:]]*//')
    assert_eq "$_match" "/email send user@test.com Subject This is the body"
  }

  it "extracts embedded /social from /write multi-line body" && {
    _body=$'report.md\n/social post discord general Check this out'
    _embed_body=$(echo "$_body" | tail -n +2)
    _match=$(printf '%s\n' "$_embed_body" | grep -oE '^[[:space:]]*/(social|email)[[:space:]][[:space:]]*[^[:space:]].*' | head -1 | sed 's/^[[:space:]]*//')
    assert_eq "$_match" "/social post discord general Check this out"
  }

  it "extracts inline /social not at line start" && {
    _body="Here is the result: /social dm jazzy92012 Done"
    _match=$(printf '%s\n' "$_body" | grep -oE '/(social|email)[[:space:]][[:space:]]*[^[:space:]].*' | head -1)
    assert_eq "$_match" "/social dm jazzy92012 Done"
  }

  it "does NOT extract /web from /respond" && {
    _body="/web search something"
    _match=$(printf '%s\n' "$_body" | grep -oE '^[[:space:]]*/(social|email)[[:space:]][[:space:]]*[^[:space:]].*' | head -1 | sed 's/^[[:space:]]*//')
    assert_empty "$_match" "Must only extract /social and /email"
  }

  it "does NOT extract /build from /respond" && {
    _body="/build release"
    _match=$(printf '%s\n' "$_body" | grep -oE '^[[:space:]]*/(social|email)[[:space:]][[:space:]]*[^[:space:]].*' | head -1 | sed 's/^[[:space:]]*//')
    assert_empty "$_match" "Must only extract /social and /email"
  }

# ═══════════════════════════════════════════════════════════════
# /respond → /social reroute
# ═══════════════════════════════════════════════════════════════
describe "Respond to social reroute"

  it "section exists in inner loop" && {
    _src="$LODGE_DIR/lib/agent.sh"
    grep -q 'RESPOND.*SOCIAL REMAP' "$_src"
    assert_ok $?
  }

  it "only triggers when selected_tool is respond" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'selected_tool.*==.*respond'
    assert_ok $?
  }

  it "remaps to social" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'selected_tool="social"'
    assert_ok $?
  }

  it "rewrites /respond to /social in micro_objective" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'micro_objective=.*respond.*social'
    assert_ok $? "Must rewrite objective text"
  }

  # Functional: test the detection regex directly
  it "detects 'discord' in objective" && {
    _mo="dm jazzy92012 on discord with the report"
    _mo_lower=$(echo "$_mo" | tr '[:upper:]' '[:lower:]')
    [[ "$_mo_lower" =~ (discord|telegram|mastodon|bluesky|x/twitter|slack)[[:space:]] ]]
    assert_ok $?
  }

  it "detects 'telegram' in objective" && {
    _mo="Send this via telegram to the group"
    _mo_lower=$(echo "$_mo" | tr '[:upper:]' '[:lower:]')
    [[ "$_mo_lower" =~ (discord|telegram|mastodon|bluesky|x/twitter|slack)[[:space:]] ]]
    assert_ok $?
  }

  it "detects 'dm' in objective" && {
    _mo="Use /respond to dm the user"
    _mo_lower=$(echo "$_mo" | tr '[:upper:]' '[:lower:]')
    [[ "$_mo_lower" =~ [[:space:]](dm|direct.message)[[:space:]] ]]
    assert_ok $?
  }

  it "detects 'post to discord' pattern" && {
    _mo="post the results to discord channel"
    _mo_lower=$(echo "$_mo" | tr '[:upper:]' '[:lower:]')
    [[ "$_mo_lower" =~ (post.*(to|on).*(discord|telegram|mastodon|bluesky|channel)) ]]
    assert_ok $?
  }

  it "detects 'send a message' pattern" && {
    _mo="send a message to the team"
    _mo_lower=$(echo "$_mo" | tr '[:upper:]' '[:lower:]')
    [[ "$_mo_lower" =~ (send.*(message|dm)) ]]
    assert_ok $?
  }

  it "does NOT trigger on 'present findings to user'" && {
    _mo="present the findings to the user"
    _mo_lower=$(echo "$_mo" | tr '[:upper:]' '[:lower:]')
    if [[ "$_mo_lower" =~ (discord|telegram|mastodon|bluesky|x/twitter|slack)[[:space:]]|[[:space:]](dm|direct.message)[[:space:]]|(send.*(message|dm)|post.*(to|on).*(discord|telegram|mastodon|bluesky|channel)) ]]; then
        _test_fail "'present findings to user' must NOT trigger social reroute"
    else
        _test_pass
    fi
  }

  it "does NOT trigger on 'respond with a summary'" && {
    _mo="respond with a summary of the data"
    _mo_lower=$(echo "$_mo" | tr '[:upper:]' '[:lower:]')
    if [[ "$_mo_lower" =~ (discord|telegram|mastodon|bluesky|x/twitter|slack)[[:space:]]|[[:space:]](dm|direct.message)[[:space:]]|(send.*(message|dm)|post.*(to|on).*(discord|telegram|mastodon|bluesky|channel)) ]]; then
        _test_fail "'respond with a summary' must NOT trigger social reroute"
    else
        _test_pass
    fi
  }

# ═══════════════════════════════════════════════════════════════
# POST-INIT workdir update — name extraction
# ═══════════════════════════════════════════════════════════════
describe "POST-INIT name extraction"

  it "handles /init name type format" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'awk.*print \$2'
    assert_ok $? "Must try \$2 first for name"
  }

  it "handles /init type name (swapped args)" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'awk.*print \$3'
    assert_ok $? "Must fall back to \$3 for swapped args"
  }

  it "verifies directory exists before updating workdir" && {
    body=$(declare -f agent_inner_loop)
    # Final workdir update guarded by -d check
    echo "$body" | grep -q '"\$workdir/\$_init_name"'
    assert_ok $? "Must verify target dir exists"
  }

# Functional: simulate name extraction
  it "extracts name from /init fizzbuzz rust" && {
    _cmd="/init fizzbuzz rust"
    _name=$(echo "$_cmd" | awk '{print $2}')
    assert_eq "$_name" "fizzbuzz"
  }

  it "extracts name from /init rust fizzbuzz (swapped)" && {
    _cmd="/init rust fizzbuzz"
    # If $2 doesn't match a dir, try $3
    _name=$(echo "$_cmd" | awk '{print $2}')
    _alt=$(echo "$_cmd" | awk '{print $3}')
    # In real code, it checks -d to decide. Here just verify extraction.
    assert_eq "$_name" "rust"
    assert_eq "$_alt" "fizzbuzz"
  }

# ═══════════════════════════════════════════════════════════════
# /cd intercept — directory change handling
# ═══════════════════════════════════════════════════════════════
describe "/cd intercept"

  it "intercept exists in inner loop" && {
    _src="$LODGE_DIR/lib/agent.sh"
    grep -q 'DIRECTORY CHANGE INTERCEPTION' "$_src"
    assert_ok $?
  }

  it "handles relative paths" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'workdir/\$_cd_target'
    assert_ok $? "Must try relative to workdir first"
  }

  it "handles absolute paths" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_cd_target'
    assert_ok $? "Must try absolute path as fallback"
  }

  it "logs to micro_memory" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q '_micro_add_action.*cd_intercept'
    assert_ok $? "Must log /cd to action log"
  }

  it "reports error on nonexistent directory" && {
    body=$(declare -f agent_inner_loop)
    echo "$body" | grep -q 'Directory not found'
    assert_ok $? "Must report missing directory"
  }

# Functional: simulate /cd workdir resolution
  it "resolves relative /cd into correct absolute path" && {
    _tmpbase=$(mktemp -d)
    mkdir -p "$_tmpbase/subdir"
    _workdir="$_tmpbase"
    _cd_target="subdir"
    _result=$(cd "$_workdir/$_cd_target" && pwd)
    assert_eq "$_result" "$_tmpbase/subdir"
    rm -rf "$_tmpbase"
  }

# ═══════════════════════════════════════════════════════════════
# Integration: end-to-end propagation path existence
# ═══════════════════════════════════════════════════════════════
describe "End-to-end propagation path"

  it "/cd -> _AGENT_WORKDIR_CHANGED -> agent_run workdir update" && {
    # Verify the full signal chain exists: set in inner, checked in outer
    inner=$(declare -f agent_inner_loop)
    outer=$(declare -f agent_run)
    echo "$inner" | grep -q '_AGENT_WORKDIR_CHANGED="$workdir"'
    assert_ok $? "Inner loop must set signal"
    echo "$outer" | grep -q '_AGENT_WORKDIR_CHANGED=""'
    assert_ok $? "Outer loop must reset signal"
    echo "$outer" | grep -q 'workdir=.*_AGENT_WORKDIR_CHANGED'
    assert_ok $? "Outer loop must read signal into workdir"
  }

  it "/init -> _AGENT_WORKDIR_CHANGED -> macro_memory project_context" && {
    inner=$(declare -f agent_inner_loop)
    _src="$LODGE_DIR/lib/agent.sh"
    # Inner: /init sets signal
    grep -q 'post-init workdir' "$_src"
    assert_ok $? "Inner must have POST-INIT section"
    sed -n '/POST-INIT WORKDIR/,/last_success_cmd/p' "$_src" | grep -q '_AGENT_WORKDIR_CHANGED'
    assert_ok $? "POST-INIT must signal via _AGENT_WORKDIR_CHANGED"
    # Outer: reads signal -> updates macro_memory
    outer=$(declare -f agent_run)
    echo "$outer" | grep -q '_macro_set.*project_context'
    assert_ok $? "Outer must update macro_memory project_context"
  }

  it "specialist gets project context for coding commands after /init" && {
    # Verify the specialist prompt builder reads GEORGE.md
    body=$(declare -f _build_specialist_prompt)
    echo "$body" | grep -q 'GEORGE.md'
    assert_ok $? "Specialist must read GEORGE.md"
    echo "$body" | grep -q '"project":'
    assert_ok $? "Specialist must output JSON project card"
    _src="$LODGE_DIR/lib/agent.sh"
    grep -q 'write|build|test|fix|init|save' "$_src"
    assert_ok $? "Card must trigger for coding commands"
  }

test_end
