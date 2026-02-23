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

  it "LLM_MAX_TOKENS defaults to 2048" && {
    assert_eq "$LLM_MAX_TOKENS" "2048"
  }

  it "LLM_ASK_TOKENS defaults to 300" && {
    assert_eq "$LLM_ASK_TOKENS" "300"
  }

  it "LLM_TIMEOUT defaults to 300 (safety net)" && {
    assert_eq "$LLM_TIMEOUT" "300"
  }

  it "LLM_KEEP_ALIVE defaults to 30m" && {
    assert_eq "$LLM_KEEP_ALIVE" "30m"
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

test_end
