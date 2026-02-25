#!/bin/bash
# ── Tests: lib/llm.sh ─────────────────────────────────────────
# LLM tests that don't require a running Ollama instance.
# Tests configuration, token estimation, and function structure.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/llm.sh"

test_start "lib/llm.sh — LLM Interface"

# ── Configuration ──────────────────────────────────────────────
describe "Configuration defaults"

  it "OLLAMA_URL defaults to localhost" && {
    assert_eq "$OLLAMA_URL" "http://127.0.0.1:11434"
  }

  it "LODGE_MODEL defaults to blue-lodge" && {
    assert_eq "$LODGE_MODEL" "blue-lodge"
  }

  it "LLM_MAX_TOKENS defaults to 20480" && {
    assert_eq "$LLM_MAX_TOKENS" "20480"
  }

  it "LLM_ASK_TOKENS defaults to 20480" && {
    assert_eq "$LLM_ASK_TOKENS" "20480"
  }

  it "LLM_AGENT_TOKENS defaults to 20480" && {
    assert_eq "$LLM_AGENT_TOKENS" "20480"
  }

  it "LLM_ROUTER_TOKENS defaults to 256" && {
    assert_eq "$LLM_ROUTER_TOKENS" "256"
  }

  it "LLM_TIMEOUT defaults to 300 (safety net)" && {
    assert_eq "$LLM_TIMEOUT" "300"
  }

  it "LLM_KEEP_ALIVE defaults to 30m" && {
    assert_eq "$LLM_KEEP_ALIVE" "30m"
  }

  it "LODGE_DEBUG defaults to 0" && {
    assert_eq "$LODGE_DEBUG" "0"
  }

# ── Function existence ─────────────────────────────────────────
describe "Core LLM functions"

  it "llm_check is defined" && {
    declare -f llm_check &>/dev/null
    assert_ok $?
  }

  it "llm_is_loaded is defined" && {
    declare -f llm_is_loaded &>/dev/null
    assert_ok $?
  }

  it "llm_unload is defined" && {
    declare -f llm_unload &>/dev/null
    assert_ok $?
  }

  it "llm_cancel is defined" && {
    declare -f llm_cancel &>/dev/null
    assert_ok $?
  }

  it "llm_ensure is defined" && {
    declare -f llm_ensure &>/dev/null
    assert_ok $?
  }

  it "llm_create_model is defined" && {
    declare -f llm_create_model &>/dev/null
    assert_ok $?
  }

  it "llm_generate is defined" && {
    declare -f llm_generate &>/dev/null
    assert_ok $?
  }

  it "llm_stream is defined" && {
    declare -f llm_stream &>/dev/null
    assert_ok $?
  }

  it "llm_chat is defined" && {
    declare -f llm_chat &>/dev/null
    assert_ok $?
  }

  it "llm_ask is defined" && {
    declare -f llm_ask &>/dev/null
    assert_ok $?
  }

  it "llm_info is defined" && {
    declare -f llm_info &>/dev/null
    assert_ok $?
  }

# ── Token estimation ──────────────────────────────────────────
describe "llm_estimate_tokens"

  it "returns positive number for text" && {
    tokens=$(llm_estimate_tokens "Hello world, this is a test.")
    assert_gt "$tokens" 0
  }

  it "scales with text length" && {
    local short_tokens long_tokens
    short_tokens=$(llm_estimate_tokens "short")
    long_tokens=$(llm_estimate_tokens "This is a much longer string that should produce more tokens than the short one above")
    assert_gt "$long_tokens" "$short_tokens"
  }

  it "returns 0 for empty string" && {
    tokens=$(llm_estimate_tokens "")
    assert_eq "$tokens" "0"
  }

# ── Cancellation state ────────────────────────────────────────
describe "Cancellation tracking"

  it "_LLM_ACTIVE starts at 0" && {
    assert_eq "$_LLM_ACTIVE" "0"
  }

  it "_LLM_CURL_PID starts empty" && {
    assert_empty "$_LLM_CURL_PID"
  }

  it "llm_cancel sets _LLM_ACTIVE to 0" && {
    _LLM_ACTIVE=1
    llm_cancel
    assert_eq "$_LLM_ACTIVE" "0"
  }

  it "llm_cancel clears _LLM_CURL_PID" && {
    _LLM_CURL_PID=""
    llm_cancel
    assert_empty "$_LLM_CURL_PID"
  }

# ── Warmup function ───────────────────────────────────────────
describe "Model warmup"

  it "llm_warmup function exists" && {
    declare -f llm_warmup &>/dev/null
    assert_eq "$?" "0"
  }

  it "llm_warmup returns 0 when model already loaded" && {
    # Stub llm_is_loaded to return 0 (loaded)
    llm_is_loaded() { return 0; }
    llm_warmup
    assert_eq "$?" "0"
  }

# ── Debug instrumentation ─────────────────────────────────────
describe "Debug instrumentation"

  it "llm_debug_reset is defined" && {
    declare -f llm_debug_reset &>/dev/null
    assert_ok $?
  }

  it "llm_debug_summary is defined" && {
    declare -f llm_debug_summary &>/dev/null
    assert_ok $?
  }

  it "_llm_debug_print is defined" && {
    declare -f _llm_debug_print &>/dev/null
    assert_ok $?
  }

  it "llm_debug_reset creates debug directory" && {
    llm_debug_reset
    [ -d "$_LLM_DEBUG_DIR" ]
    assert_ok $?
    rm -rf "$_LLM_DEBUG_DIR"
  }

  it "llm_debug_reset clears previous call log" && {
    mkdir -p "$_LLM_DEBUG_DIR"
    echo "100 50" > "$_LLM_DEBUG_DIR/calls.log"
    llm_debug_reset
    [ ! -s "$_LLM_DEBUG_DIR/calls.log" ] || [ ! -f "$_LLM_DEBUG_DIR/calls.log" ]
    assert_ok $?
    rm -rf "$_LLM_DEBUG_DIR"
  }

  it "_llm_debug_end_timer writes to calls.log file" && {
    LODGE_DEBUG=1
    llm_debug_reset
    _LLM_DEBUG_CALL_START=$(date +%s%N 2>/dev/null || date +%s)
    _llm_debug_end_timer "test" "100" "50" 2>/dev/null
    [ -f "$_LLM_DEBUG_DIR/calls.log" ]
    assert_ok $?
    head -1 "$_LLM_DEBUG_DIR/calls.log" | grep -q "100 50"
    assert_ok $?
    LODGE_DEBUG=0
    rm -rf "$_LLM_DEBUG_DIR"
  }

  it "_llm_debug_print is silent when LODGE_DEBUG=0" && {
    LODGE_DEBUG=0
    output=$(_llm_debug_print "test" 2>&1)
    assert_empty "$output"
    LODGE_DEBUG=0  # restore
  }

  it "_LLM_DEBUG_TASK_START is set by llm_debug_reset" && {
    llm_debug_reset
    assert_match "$_LLM_DEBUG_TASK_START" "^[0-9]+$"
  }

# ── Thinking mode ─────────────────────────────────────────────
describe "Thinking mode configuration (thinking-only model)"

  it "LODGE_THINK defaults to 0" && {
    assert_eq "$LODGE_THINK" "0"
  }

  it "LODGE_THINK_STREAM defaults to 1" && {
    assert_eq "$LODGE_THINK_STREAM" "1"
  }

  it "llm_generate does NOT append /nothink or /think (thinking-only model)" && {
    body=$(declare -f llm_generate)
    echo "$body" | grep -q '/nothink'
    assert_eq $? 1
    echo "$body" | grep -q 'prompt=.*\/think'
    assert_eq $? 1
  }

  it "llm_stream does NOT append /nothink or /think (thinking-only model)" && {
    body=$(declare -f llm_stream)
    echo "$body" | grep -q '/nothink'
    assert_eq $? 1
    echo "$body" | grep -q 'prompt=.*\/think'
    assert_eq $? 1
  }

  it "llm_generate strips think tokens via </think> marker" && {
    body=$(declare -f llm_generate)
    echo "$body" | grep -q '</think>'
    assert_ok $?
    echo "$body" | grep -q 'full_text'
    assert_ok $?
  }

  it "llm_generate displays think content when LODGE_THINK=1" && {
    body=$(declare -f llm_generate)
    echo "$body" | grep -q 'LODGE_THINK.*LODGE_THINK_STREAM'
    assert_ok $?
    echo "$body" | grep -q '_think_content'
    assert_ok $?
  }

  it "llm_stream starts in think mode (_in_think_block=1)" && {
    body=$(declare -f llm_stream)
    echo "$body" | grep -q '_in_think_block=1'
    assert_ok $?
  }

  it "llm_stream transitions at </think> marker" && {
    body=$(declare -f llm_stream)
    echo "$body" | grep -q '_in_think_block=0'
    assert_ok $?
    echo "$body" | grep -q '</think>'
    assert_ok $?
  }

  it "llm_stream shows bright thinking header when LODGE_THINK_STREAM=2" && {
    body=$(declare -f llm_stream)
    echo "$body" | grep -q 'LODGE_THINK_STREAM.*-eq 2'
    assert_ok $?
    echo "$body" | grep -q 'thinking'
    assert_ok $?
  }

test_end
