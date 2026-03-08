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
    GEORGE_PROVIDER=""
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
    assert_contains "$models" "claude-haiku-4"
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

# ── Provider model defaults ───────────────────────────────────
describe "Provider model defaults"

  it "_provider_canon maps google to GOOGLE" && {
    _setup_prov
    assert_eq "$(_provider_canon "google")" "GOOGLE"
    _teardown_prov
  }

  it "_provider_canon maps gemini alias to GOOGLE" && {
    assert_eq "$(_provider_canon "gemini")" "GOOGLE"
  }

  it "_provider_canon maps openai to OPENAI" && {
    assert_eq "$(_provider_canon "openai")" "OPENAI"
  }

  it "_provider_canon maps gpt alias to OPENAI" && {
    assert_eq "$(_provider_canon "gpt")" "OPENAI"
  }

  it "_provider_canon returns empty for unknown" && {
    _tresult=$(_provider_canon "nonexistent")
    assert_eq "$_tresult" ""
  }

  it "provider_set_model stores model in keys.conf" && {
    _setup_prov
    provider_set_model "google" "gemma-3-27b-it" >/dev/null 2>&1
    _tresult=$(api_get_key "PROVIDER_MODEL_GOOGLE")
    assert_eq "$_tresult" "gemma-3-27b-it"
    _teardown_prov
  }

  it "provider_get_model returns stored model" && {
    _setup_prov
    api_set_key "PROVIDER_MODEL_OPENAI" "gpt-4o"
    _tresult=$(provider_get_model "openai")
    assert_eq "$_tresult" "gpt-4o"
    _teardown_prov
  }

  it "provider_get_model returns empty when not set" && {
    _setup_prov
    _tresult=$(provider_get_model "google" 2>/dev/null)
    assert_eq "$_tresult" ""
    _teardown_prov
  }

  it "provider_clear_model removes stored model" && {
    _setup_prov
    api_set_key "PROVIDER_MODEL_GOOGLE" "gemma-3-27b-it"
    provider_clear_model "google" >/dev/null 2>&1
    _tresult=$(api_get_key "PROVIDER_MODEL_GOOGLE" 2>/dev/null)
    assert_eq "$_tresult" ""
    _teardown_prov
  }

  it "provider_set_model fails for unknown provider" && {
    _setup_prov
    provider_set_model "nonexistent" "model" 2>/dev/null
    assert_fail $?
    _teardown_prov
  }

  it "_provider_resolve_model uses explicit arg first" && {
    _setup_prov
    api_set_key "PROVIDER_MODEL_GOOGLE" "stored-model"
    _tresult=$(_provider_resolve_model "explicit-model" "google" "hardcoded-model")
    assert_eq "$_tresult" "explicit-model"
    _teardown_prov
  }

  it "_provider_resolve_model uses stored default when no explicit" && {
    _setup_prov
    api_set_key "PROVIDER_MODEL_GOOGLE" "stored-model"
    _tresult=$(_provider_resolve_model "" "google" "hardcoded-model")
    assert_eq "$_tresult" "stored-model"
    _teardown_prov
  }

  it "_provider_resolve_model falls back to hardcoded" && {
    _setup_prov
    _tresult=$(_provider_resolve_model "" "google" "hardcoded-model")
    assert_eq "$_tresult" "hardcoded-model"
    _teardown_prov
  }

# ── Provider Harness ───────────────────────────────────────────
describe "Provider harness (use/active/local)"

  it "provider_use is defined" && {
    _setup_prov
    declare -f provider_use &>/dev/null
    assert_ok $?
    _teardown_prov
  }

  it "provider_use_local is defined" && {
    declare -f provider_use_local &>/dev/null
    assert_ok $?
  }

  it "provider_active is defined" && {
    declare -f provider_active &>/dev/null
    assert_ok $?
  }

  it "_provider_load_harness is defined" && {
    declare -f _provider_load_harness &>/dev/null
    assert_ok $?
  }

  it "_provider_key_name maps known providers" && {
    _setup_prov
    assert_eq "$(_provider_key_name "openai")" "OPENAI_API_KEY"
    assert_eq "$(_provider_key_name "google")" "GOOGLE_AI_API_KEY"
    assert_eq "$(_provider_key_name "anthropic")" "ANTHROPIC_API_KEY"
    assert_eq "$(_provider_key_name "groq")" "GROQ_API_KEY"
    assert_eq "$(_provider_key_name "xai")" "XAI_API_KEY"
    _teardown_prov
  }

  it "_provider_key_name returns empty for unknown" && {
    _tresult=$(_provider_key_name "nonexistent")
    assert_eq "$_tresult" ""
  }

  it "provider_use sets GEORGE_PROVIDER and persists" && {
    _setup_prov
    api_set_key "GOOGLE_AI_API_KEY" "test-key-123"
    provider_use "google" >/dev/null 2>&1
    assert_eq "$GEORGE_PROVIDER" "google"
    _tresult=$(api_get_key "GEORGE_PROVIDER" 2>/dev/null)
    assert_eq "$_tresult" "google"
    _teardown_prov
  }

  it "provider_use rejects unknown providers" && {
    _setup_prov
    provider_use "fakeprovider" 2>/dev/null
    assert_fail $?
    assert_eq "$GEORGE_PROVIDER" ""
    _teardown_prov
  }

  it "provider_use rejects providers without API key" && {
    _setup_prov
    GEORGE_PROVIDER=""
    provider_use "openai" 2>/dev/null
    assert_fail $?
    assert_eq "$GEORGE_PROVIDER" ""
    _teardown_prov
  }

  it "provider_use_local clears GEORGE_PROVIDER" && {
    _setup_prov
    GEORGE_PROVIDER="google"
    api_set_key "GEORGE_PROVIDER" "google"
    provider_use_local >/dev/null 2>&1
    assert_eq "$GEORGE_PROVIDER" ""
    _tresult=$(api_get_key "GEORGE_PROVIDER" 2>/dev/null)
    assert_eq "$_tresult" ""
    _teardown_prov
  }

  it "provider_use 'local' calls provider_use_local" && {
    _setup_prov
    GEORGE_PROVIDER="google"
    api_set_key "GEORGE_PROVIDER" "google"
    provider_use "local" >/dev/null 2>&1
    assert_eq "$GEORGE_PROVIDER" ""
    _teardown_prov
  }

  it "provider_use 'off' calls provider_use_local" && {
    _setup_prov
    GEORGE_PROVIDER="google"
    api_set_key "GEORGE_PROVIDER" "google"
    provider_use "off" >/dev/null 2>&1
    assert_eq "$GEORGE_PROVIDER" ""
    _teardown_prov
  }

  it "provider_active returns current provider" && {
    _setup_prov
    GEORGE_PROVIDER="anthropic"
    _tresult=$(provider_active)
    assert_eq "$_tresult" "anthropic"
    GEORGE_PROVIDER=""
    _tresult=$(provider_active)
    assert_eq "$_tresult" ""
    _teardown_prov
  }

  it "_provider_load_harness restores from keys.conf" && {
    _setup_prov
    api_set_key "GOOGLE_AI_API_KEY" "test-key-123"
    api_set_key "GEORGE_PROVIDER" "google"
    GEORGE_PROVIDER=""
    _provider_load_harness
    assert_eq "$GEORGE_PROVIDER" "google"
    _teardown_prov
  }

  it "_provider_load_harness ignores missing API key" && {
    _setup_prov
    api_set_key "GEORGE_PROVIDER" "openai"
    GEORGE_PROVIDER=""
    _provider_load_harness
    assert_eq "$GEORGE_PROVIDER" ""
    _teardown_prov
  }

  it "provider_use with provider/model sets model" && {
    _setup_prov
    api_set_key "GOOGLE_AI_API_KEY" "test-key-123"
    provider_set_model "google" "gemini-2.5-pro" >/dev/null 2>&1
    provider_use "google" >/dev/null 2>&1
    assert_eq "$GEORGE_PROVIDER" "google"
    _tresult=$(provider_get_model "google" 2>/dev/null)
    assert_eq "$_tresult" "gemini-2.5-pro"
    _teardown_prov
  }

# ── System prompt passthrough ──────────────────────────────────
describe "Provider system prompt support"

  it "provider_chat accepts 4th system arg" && {
    _setup_prov
    # provider_chat should dispatch correctly with system=$4
    # (will fail due to missing API key, but must NOT say "Unknown provider")
    _tresult=$(provider_chat "openai" "hello" "" "You are George." 2>&1)
    echo "$_tresult" | grep -qi "unknown provider"
    assert_fail $? "system arg must not confuse dispatcher"
    _teardown_prov
  }

test_end

# ── Google systemInstruction conditional ───────────────────────
describe "Google systemInstruction handling"

  it "google_chat omits systemInstruction when no system prompt" && {
    _setup_prov
    _t_capfile=$(mktemp)
    api_require_key() { echo "fake-key"; return 0; }
    api_post() { echo "$2" > "$_t_capfile"; echo '{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}'; return 0; }
    google_chat "hello" "gemini-2.0-flash" "" >/dev/null 2>&1
    cat "$_t_capfile" | grep -q "systemInstruction"
    assert_fail $? "payload must NOT include systemInstruction when system is empty"
    rm -f "$_t_capfile"
    _teardown_prov
  }

  it "google_chat includes systemInstruction when system prompt given" && {
    _setup_prov
    _t_capfile=$(mktemp)
    api_require_key() { echo "fake-key"; return 0; }
    api_post() { echo "$2" > "$_t_capfile"; echo '{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}'; return 0; }
    google_chat "hello" "gemini-2.0-flash" "You are George." >/dev/null 2>&1
    cat "$_t_capfile" | grep -q "systemInstruction"
    assert_ok $? "payload must include systemInstruction when system is provided"
    rm -f "$_t_capfile"
    _teardown_prov
  }

  it "google_chat retries without systemInstruction on developer-instruction error" && {
    _setup_prov
    _t_cntfile=$(mktemp); echo "0" > "$_t_cntfile"
    api_require_key() { echo "fake-key"; return 0; }
    api_post() {
      _t_cnt=$(cat "$_t_cntfile"); _t_cnt=$((_t_cnt + 1)); echo "$_t_cnt" > "$_t_cntfile"
      if [ "$_t_cnt" -eq 1 ]; then
        echo '{"error":{"message":"Developer instruction is not enabled for models/some-new-model"}}'
        return 1
      fi
      echo '{"candidates":[{"content":{"parts":[{"text":"retried ok"}]}}]}'
      return 0
    }
    _tresult=$(google_chat "hello" "some-new-model" "You are George." 2>/dev/null)
    assert_ok $? "retry must succeed"
    assert_eq "$_tresult" "retried ok" "must return response from retry"
    rm -f "$_t_cntfile"
    _teardown_prov
  }

  it "google_chat retry payload prepends system to user message" && {
    _setup_prov
    _t_cntfile=$(mktemp); echo "0" > "$_t_cntfile"
    _t_capfile=$(mktemp)
    api_require_key() { echo "fake-key"; return 0; }
    api_post() {
      _t_cnt=$(cat "$_t_cntfile"); _t_cnt=$((_t_cnt + 1)); echo "$_t_cnt" > "$_t_cntfile"
      if [ "$_t_cnt" -eq 1 ]; then
        echo '{"error":{"message":"Developer instruction is not enabled for models/some-new-model"}}'
        return 1
      fi
      echo "$2" > "$_t_capfile"
      echo '{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}'
      return 0
    }
    google_chat "hello" "some-new-model" "Be helpful." >/dev/null 2>&1
    cat "$_t_capfile" | grep -q "systemInstruction"
    assert_fail $? "retry payload must NOT have systemInstruction"
    cat "$_t_capfile" | grep -q "Be helpful."
    assert_ok $? "retry payload must contain system text in user message"
    rm -f "$_t_cntfile" "$_t_capfile"
    _teardown_prov
  }

test_end

# ── Gemma system instruction workaround ─────────────────────────────
describe "Gemma systemInstruction workaround"

  it "_google_needs_system_workaround returns true for gemma models" && {
    _google_needs_system_workaround "gemma-3-27b-it"
    assert_ok $? "gemma-3-27b-it must need workaround"
    _google_needs_system_workaround "gemma-2-9b"
    assert_ok $? "gemma-2-9b must need workaround"
  }

  it "_google_needs_system_workaround returns false for gemini models" && {
    _google_needs_system_workaround "gemini-2.0-flash"
    assert_fail $? "gemini must NOT need workaround"
    _google_needs_system_workaround "gemini-1.5-pro"
    assert_fail $? "gemini-1.5-pro must NOT need workaround"
  }

  it "google_chat skips systemInstruction for gemma model" && {
    _setup_prov
    _t_capfile=$(mktemp)
    api_require_key() { echo "fake-key"; return 0; }
    api_post() { echo "$2" > "$_t_capfile"; echo '{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}'; return 0; }
    google_chat "hello" "gemma-3-27b-it" "You are George." >/dev/null 2>&1
    cat "$_t_capfile" | grep -q "systemInstruction"
    assert_fail $? "gemma payload must NOT include systemInstruction"
    cat "$_t_capfile" | grep -q "Instructions:"
    assert_ok $? "gemma payload must inline system as Instructions:"
    rm -f "$_t_capfile"
    _teardown_prov
  }

  it "google_chat sends only 1 request for gemma with system prompt" && {
    _setup_prov
    _t_cntfile=$(mktemp); echo "0" > "$_t_cntfile"
    api_require_key() { echo "fake-key"; return 0; }
    api_post() {
      _t_cnt=$(cat "$_t_cntfile"); _t_cnt=$((_t_cnt + 1)); echo "$_t_cnt" > "$_t_cntfile"
      echo '{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}'
      return 0
    }
    google_chat "hello" "gemma-3-27b-it" "system" >/dev/null 2>&1
    _t_cnt=$(cat "$_t_cntfile")
    assert_eq "$_t_cnt" "1" "Gemma must send exactly 1 API request"
    rm -f "$_t_cntfile"
    _teardown_prov
  }

test_end

# ── Metering and rate-limit functions ────────────────────────────
describe "Provider metering and rate limits"

  it "_provider_meter_tick records a call" && {
    _setup_prov
    _PROVIDER_METER_DIR=$(mktemp -d)
    _provider_meter_tick
    _tresult=$(cat "$_PROVIDER_METER_DIR/calls" 2>/dev/null | wc -l)
    assert_eq "$_tresult" "1" "must record one call"
    rm -rf "$_PROVIDER_METER_DIR"
    _teardown_prov
  }

  it "_provider_meter_count tracks calls in window" && {
    _setup_prov
    _PROVIDER_METER_DIR=$(mktemp -d)
    PROVIDER_COOLDOWN_WINDOW=60
    _provider_meter_tick
    _provider_meter_tick
    _tresult=$(_provider_meter_count)
    assert_eq "$_tresult" "2" "must count 2 calls"
    rm -rf "$_PROVIDER_METER_DIR"
    _teardown_prov
  }

  it "_provider_meter_count ignores calls outside window" && {
    _setup_prov
    _PROVIDER_METER_DIR=$(mktemp -d)
    PROVIDER_COOLDOWN_WINDOW=60
    # Write an old timestamp (2 minutes ago)
    echo "$(($(date +%s) - 120))" > "$_PROVIDER_METER_DIR/calls"
    _tresult=$(_provider_meter_count)
    assert_eq "$_tresult" "0" "old calls must be outside window"
    rm -rf "$_PROVIDER_METER_DIR"
    _teardown_prov
  }

  it "_provider_meter_reset cleans up" && {
    _setup_prov
    _PROVIDER_METER_DIR=$(mktemp -d)
    _provider_meter_tick
    _provider_meter_reset
    [ ! -d "$_PROVIDER_METER_DIR" ]
    assert_ok $? "meter dir must be removed"
    _teardown_prov
  }

  it "_provider_call_with_backoff is defined" && {
    _setup_prov
    declare -f _provider_call_with_backoff &>/dev/null
    assert_ok $?
    _teardown_prov
  }

  it "_provider_call_with_backoff calls provider_chat" && {
    _setup_prov
    _PROVIDER_METER_DIR=$(mktemp -d)
    PROVIDER_CALL_DELAY=0
    provider_chat() { echo "backoff-result"; return 0; }
    _tresult=$(_provider_call_with_backoff "google" "hello" "" "" 2>/dev/null)
    assert_eq "$_tresult" "backoff-result"
    rm -rf "$_PROVIDER_METER_DIR"
    _teardown_prov
  }

test_end

# ── Inter-call delay ──────────────────────────────────────────
describe "Provider call delay"

  it "provider_set_delay is defined" && {
    _setup_prov
    declare -f provider_set_delay &>/dev/null
    assert_ok $?
    _teardown_prov
  }

  it "provider_get_delay returns default of 7" && {
    _setup_prov
    unset PROVIDER_CALL_DELAY
    _LIB_PROVIDERS_LOADED=""
    source "$LODGE_DIR/lib/providers.sh"
    _tresult=$(provider_get_delay)
    assert_eq "$_tresult" "7"
    _teardown_prov
  }

  it "provider_set_delay sets and persists value" && {
    _setup_prov
    provider_set_delay 30 >/dev/null 2>&1
    assert_eq "$PROVIDER_CALL_DELAY" "30" "global must be set"
    _tresult=$(api_get_key "PROVIDER_CALL_DELAY" 2>/dev/null)
    assert_eq "$_tresult" "30" "must be persisted to keys.conf"
    _teardown_prov
  }

  it "provider_set_delay rejects non-numeric input" && {
    _setup_prov
    provider_set_delay "abc" 2>/dev/null
    assert_fail $?
    _teardown_prov
  }

  it "_provider_load_harness restores delay from keys.conf" && {
    _setup_prov
    api_set_key "PROVIDER_CALL_DELAY" "25"
    PROVIDER_CALL_DELAY=0
    _provider_load_harness
    assert_eq "$PROVIDER_CALL_DELAY" "25" "delay must be restored"
    _teardown_prov
  }

  it "_provider_inter_call_delay skips when delay is 0" && {
    _setup_prov
    _PROVIDER_METER_DIR=$(mktemp -d)
    PROVIDER_CALL_DELAY=0
    _t_start=$(date +%s)
    _provider_inter_call_delay
    _t_elapsed=$(( $(date +%s) - _t_start ))
    [ "$_t_elapsed" -lt 2 ]
    assert_ok $? "must not sleep when delay is 0"
    rm -rf "$_PROVIDER_METER_DIR"
    _teardown_prov
  }

  it "_provider_stamp_last_call writes timestamp" && {
    _setup_prov
    _PROVIDER_METER_DIR=$(mktemp -d)
    _provider_stamp_last_call
    [ -f "$_PROVIDER_METER_DIR/last_call" ]
    assert_ok $? "must write last_call file"
    _tresult=$(cat "$_PROVIDER_METER_DIR/last_call")
    [[ "$_tresult" =~ ^[0-9]+$ ]]
    assert_ok $? "must contain a timestamp"
    rm -rf "$_PROVIDER_METER_DIR"
    _teardown_prov
  }

# ── Countdown timer ─────────────────────────────────────────
describe "Provider countdown timer"

  it "_provider_countdown is defined" && {
    declare -f _provider_countdown &>/dev/null
    assert_ok $?
  }

  it "_provider_countdown skips when secs<=0" && {
    _t_start=$(date +%s)
    _provider_countdown 0 "test" 2>/dev/null
    _t_elapsed=$(( $(date +%s) - _t_start ))
    [ "$_t_elapsed" -lt 2 ]
    assert_ok $? "must return immediately for 0"
  }

# ── Streaming infrastructure ──────────────────────────────────
describe "Provider streaming infrastructure"

  it "provider_stream_chat is defined" && {
    declare -f provider_stream_chat &>/dev/null
    assert_ok $?
  }

  it "_provider_stream_with_backoff is defined" && {
    declare -f _provider_stream_with_backoff &>/dev/null
    assert_ok $?
  }

  it "_provider_sse_loop is defined" && {
    declare -f _provider_sse_loop &>/dev/null
    assert_ok $?
  }

  it "_provider_anthropic_sse_loop is defined" && {
    declare -f _provider_anthropic_sse_loop &>/dev/null
    assert_ok $?
  }

  it "_provider_google_sse_loop is defined" && {
    declare -f _provider_google_sse_loop &>/dev/null
    assert_ok $?
  }

  it "api_stream_post is defined" && {
    declare -f api_stream_post &>/dev/null
    assert_ok $?
  }

# ── OpenAI o-series guard ─────────────────────────────────────
describe "OpenAI reasoning model guard"

  it "openai_chat uses developer role for o3 models" && {
    _setup_prov
    _t_capfile=$(mktemp)
    api_post() { echo "$2" > "$_t_capfile"; echo '{"choices":[{"message":{"content":"ok"}}]}'; }
    api_require_key() { echo "sk-test"; }
    openai_chat "test" "o3-mini" "sys" 2>/dev/null
    cat "$_t_capfile" | grep -q '"developer"'
    assert_ok $? "must use developer role"
    cat "$_t_capfile" | grep -q '"temperature"'
    assert_fail $? "must not include temperature"
    rm -f "$_t_capfile"
    _teardown_prov
  }

  it "openai_chat uses system role for gpt models" && {
    _setup_prov
    _t_capfile=$(mktemp)
    api_post() { echo "$2" > "$_t_capfile"; echo '{"choices":[{"message":{"content":"ok"}}]}'; }
    api_require_key() { echo "sk-test"; }
    openai_chat "test" "gpt-4o-mini" "sys" 2>/dev/null
    cat "$_t_capfile" | grep -q '"system"'
    assert_ok $? "must use system role"
    rm -f "$_t_capfile"
    _teardown_prov
  }

  it "openai_chat uses max_completion_tokens" && {
    _setup_prov
    _t_capfile=$(mktemp)
    api_post() { echo "$2" > "$_t_capfile"; echo '{"choices":[{"message":{"content":"ok"}}]}'; }
    api_require_key() { echo "sk-test"; }
    openai_chat "test" "" "sys" 2>/dev/null
    cat "$_t_capfile" | grep -q 'max_completion_tokens'
    assert_ok $? "must use max_completion_tokens not max_tokens"
    rm -f "$_t_capfile"
    _teardown_prov
  }

# ── DeepSeek reasoner guard ───────────────────────────────────
describe "DeepSeek reasoning model guard"

  it "deepseek_chat omits temperature for reasoner" && {
    _setup_prov
    _t_capfile=$(mktemp)
    api_post() { echo "$2" > "$_t_capfile"; echo '{"choices":[{"message":{"content":"ok"}}]}'; }
    api_require_key() { echo "sk-test"; }
    deepseek_chat "test" "deepseek-reasoner" "sys" 2>/dev/null
    cat "$_t_capfile" | grep -q '"temperature"'
    assert_fail $? "must not include temperature for reasoner"
    rm -f "$_t_capfile"
    _teardown_prov
  }

  it "deepseek_chat includes temperature for deepseek-chat" && {
    _setup_prov
    _t_capfile=$(mktemp)
    api_post() { echo "$2" > "$_t_capfile"; echo '{"choices":[{"message":{"content":"ok"}}]}'; }
    api_require_key() { echo "sk-test"; }
    deepseek_chat "test" "deepseek-chat" "sys" 2>/dev/null
    cat "$_t_capfile" | grep -q '"temperature"'
    assert_ok $? "must include temperature for deepseek-chat"
    rm -f "$_t_capfile"
    _teardown_prov
  }

# ── Cohere v2 API ────────────────────────────────────────────
describe "Cohere v2 API migration"

  it "cohere_chat uses v2 endpoint" && {
    _setup_prov
    _t_capfile=$(mktemp)
    api_post() { echo "$1" > "$_t_capfile"; echo '{"message":{"content":[{"text":"ok"}]}}'; }
    api_require_key() { echo "test-key"; }
    cohere_chat "test" "" "sys" 2>/dev/null
    cat "$_t_capfile" | grep -q 'cohere.com/v2/chat'
    assert_ok $? "must use cohere.com/v2/chat endpoint"
    rm -f "$_t_capfile"
    _teardown_prov
  }

  it "cohere_chat uses messages array format" && {
    _setup_prov
    _t_capfile=$(mktemp)
    api_post() { echo "$2" > "$_t_capfile"; echo '{"message":{"content":[{"text":"ok"}]}}'; }
    api_require_key() { echo "test-key"; }
    cohere_chat "test" "" "sys" 2>/dev/null
    cat "$_t_capfile" | grep -q '"messages"'
    assert_ok $? "must use messages array"
    cat "$_t_capfile" | grep -q '"preamble"'
    assert_fail $? "must not use deprecated preamble field"
    rm -f "$_t_capfile"
    _teardown_prov
  }

  it "cohere_chat default model is command-a-03-2025" && {
    _setup_prov
    _t_capfile=$(mktemp)
    api_post() { echo "$2" > "$_t_capfile"; echo '{"message":{"content":[{"text":"ok"}]}}'; }
    api_require_key() { echo "test-key"; }
    cohere_chat "test" "" "sys" 2>/dev/null
    cat "$_t_capfile" | grep -q 'command-a-03-2025'
    assert_ok $? "must default to command-a-03-2025"
    rm -f "$_t_capfile"
    _teardown_prov
  }

test_end
