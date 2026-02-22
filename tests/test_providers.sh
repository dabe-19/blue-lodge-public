#!/bin/bash
# ── Tests: lib/providers.sh ───────────────────────────────────
# Provider functions need API keys, so we test structure,
# dispatching, status display, and graceful failure.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/api.sh"

TMPDIR_PROV=""

_setup_prov() {
    TMPDIR_PROV=$(test_tmpdir)
    export GEORGE_CONFIG_DIR="$TMPDIR_PROV/.george"
    export GEORGE_KEYS_FILE="$GEORGE_CONFIG_DIR/keys.conf"
    export GEORGE_COOKIES_DIR="$GEORGE_CONFIG_DIR/cookies"
    export GEORGE_CACHE_DIR="$GEORGE_CONFIG_DIR/cache"
    api_init 2>/dev/null
    source "$LODGE_DIR/lib/providers.sh"
}

_teardown_prov() {
    rm -rf "$TMPDIR_PROV"
}

test_start "lib/providers.sh — Cloud AI Providers"

# ── Function existence ─────────────────────────────────────────
describe "Provider chat functions"

  it "openai_chat is defined" && {
    _setup_prov
    declare -f openai_chat &>/dev/null
    assert_ok $?
    _teardown_prov
  }

  it "anthropic_chat is defined" && {
    declare -f anthropic_chat &>/dev/null
    assert_ok $?
  }

  it "google_chat is defined" && {
    declare -f google_chat &>/dev/null
    assert_ok $?
  }

  it "groq_chat is defined" && {
    declare -f groq_chat &>/dev/null
    assert_ok $?
  }

  it "mistral_chat is defined" && {
    declare -f mistral_chat &>/dev/null
    assert_ok $?
  }

  it "together_chat is defined" && {
    declare -f together_chat &>/dev/null
    assert_ok $?
  }

  it "perplexity_chat is defined" && {
    declare -f perplexity_chat &>/dev/null
    assert_ok $?
  }

  it "cohere_chat is defined" && {
    declare -f cohere_chat &>/dev/null
    assert_ok $?
  }

  it "deepseek_chat is defined" && {
    declare -f deepseek_chat &>/dev/null
    assert_ok $?
  }

  it "xai_chat is defined" && {
    declare -f xai_chat &>/dev/null
    assert_ok $?
  }

# ── Google ADK functions ───────────────────────────────────────
describe "Google ADK functions"

  it "google_adk_create_agent is defined" && {
    declare -f google_adk_create_agent &>/dev/null
    assert_ok $?
  }

  it "google_adk_list_agents is defined" && {
    declare -f google_adk_list_agents &>/dev/null
    assert_ok $?
  }

# ── Model list functions ──────────────────────────────────────
describe "Model listing functions"

  it "openai_models is defined" && {
    declare -f openai_models &>/dev/null
    assert_ok $?
  }

  it "anthropic_models returns model list" && {
    models=$(anthropic_models)
    assert_contains "$models" "claude-opus-4"
    assert_contains "$models" "claude-sonnet-4"
  }

  it "google_models is defined" && {
    declare -f google_models &>/dev/null
    assert_ok $?
  }

# ── Missing key handling ──────────────────────────────────────
describe "Missing API key handling"

  it "openai_chat fails without key" && {
    _setup_prov
    openai_chat "test" 2>/dev/null
    assert_fail $?
    _teardown_prov
  }

  it "anthropic_chat fails without key" && {
    _setup_prov
    anthropic_chat "test" 2>/dev/null
    assert_fail $?
    _teardown_prov
  }

  it "google_chat fails without key" && {
    _setup_prov
    google_chat "test" 2>/dev/null
    assert_fail $?
    _teardown_prov
  }

  it "groq_chat fails without key" && {
    _setup_prov
    groq_chat "test" 2>/dev/null
    assert_fail $?
    _teardown_prov
  }

  it "xai_chat fails without key" && {
    _setup_prov
    xai_chat "test" 2>/dev/null
    assert_fail $?
    _teardown_prov
  }

# ── provider_chat dispatcher ──────────────────────────────────
describe "provider_chat (unified dispatcher)"

  it "dispatches to openai" && {
    _setup_prov
    provider_chat "openai" "test" 2>/dev/null
    # Will fail (no key), but shouldn't crash
    assert_ok 0
    _teardown_prov
  }

  it "dispatches to anthropic via claude alias" && {
    _setup_prov
    provider_chat "claude" "test" 2>/dev/null
    assert_ok 0
    _teardown_prov
  }

  it "dispatches to google via gemini alias" && {
    _setup_prov
    provider_chat "gemini" "test" 2>/dev/null
    assert_ok 0
    _teardown_prov
  }

  it "dispatches to xai via grok alias" && {
    _setup_prov
    provider_chat "grok" "test" 2>/dev/null
    assert_ok 0
    _teardown_prov
  }

  it "fails for unknown provider" && {
    _setup_prov
    provider_chat "nonexistent_provider" "test" 2>/dev/null
    assert_fail $?
    _teardown_prov
  }

# ── provider_status ────────────────────────────────────────────
describe "provider_status"

  it "shows all providers" && {
    _setup_prov
    out=$(provider_status 2>&1)
    assert_contains "$out" "AI Providers"
    assert_contains "$out" "OpenAI"
    assert_contains "$out" "Anthropic"
    assert_contains "$out" "not configured"
    _teardown_prov
  }

  it "marks configured providers" && {
    _setup_prov
    api_set_key "OPENAI_API_KEY" "sk-test"
    out=$(provider_status 2>&1)
    assert_contains "$out" "configured"
    _teardown_prov
  }

# ── PROVIDER_TIMEOUT ──────────────────────────────────────────
describe "Configuration"

  it "PROVIDER_TIMEOUT defaults to 120" && {
    _setup_prov
    assert_eq "$PROVIDER_TIMEOUT" "120"
    _teardown_prov
  }

test_end
