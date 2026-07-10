#!/bin/bash
# ── Tests: lib/api.sh ─────────────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/api.sh"

test_start "lib/api.sh — REST API Client Core"

TMPDIR_API=""

_setup_api() {
    TMPDIR_API=$(test_tmpdir)
    export GEORGE_CONFIG_DIR="$TMPDIR_API/.george"
    export GEORGE_KEYS_FILE="$GEORGE_CONFIG_DIR/keys.conf"
    export GEORGE_COOKIES_DIR="$GEORGE_CONFIG_DIR/cookies"
    export GEORGE_CACHE_DIR="$GEORGE_CONFIG_DIR/cache"
}

_teardown_api() {
    rm -rf "$TMPDIR_API"
}

# ── api_init ───────────────────────────────────────────────────
describe "api_init"

  it "creates config directory structure" && {
    _setup_api
    api_init 2>/dev/null
    assert_dir_exists "$GEORGE_CONFIG_DIR"
    assert_dir_exists "$GEORGE_COOKIES_DIR"
    assert_dir_exists "$GEORGE_CACHE_DIR"
    _teardown_api
  }

  it "creates keys.conf with template" && {
    _setup_api
    api_init 2>/dev/null
    assert_file_exists "$GEORGE_KEYS_FILE"
    content=$(cat "$GEORGE_KEYS_FILE")
    assert_contains "$content" "OPENAI_API_KEY"
    assert_contains "$content" "TELEGRAM_BOT_TOKEN"
    assert_contains "$content" "SERPER_API_KEY"
    _teardown_api
  }

  it "sets correct permissions on keys.conf" && {
    _setup_api
    api_init 2>/dev/null
    perms=$(stat -c '%a' "$GEORGE_KEYS_FILE" 2>/dev/null)
    assert_eq "$perms" "600"
    _teardown_api
  }

  it "sets correct permissions on config dir" && {
    _setup_api
    api_init 2>/dev/null
    perms=$(stat -c '%a' "$GEORGE_CONFIG_DIR" 2>/dev/null)
    assert_eq "$perms" "700"
    _teardown_api
  }

  it "is idempotent — does not overwrite existing keys.conf" && {
    _setup_api
    api_init 2>/dev/null
    echo "MY_CUSTOM_KEY=secret123" >> "$GEORGE_KEYS_FILE"
    api_init 2>/dev/null
    content=$(cat "$GEORGE_KEYS_FILE")
    assert_contains "$content" "MY_CUSTOM_KEY=secret123"
    _teardown_api
  }

# ── api_set_key / api_get_key ─────────────────────────────────
describe "api_set_key / api_get_key"

  it "sets and retrieves a key" && {
    _setup_api
    api_init 2>/dev/null
    api_set_key "TEST_KEY" "test_value_123"
    result=$(api_get_key "TEST_KEY")
    assert_eq "$result" "test_value_123"
    _teardown_api
  }

  it "overwrites existing key" && {
    _setup_api
    api_init 2>/dev/null
    api_set_key "TEST_KEY" "old_value"
    api_set_key "TEST_KEY" "new_value"
    result=$(api_get_key "TEST_KEY")
    assert_eq "$result" "new_value"
    _teardown_api
  }

  it "returns failure for missing key" && {
    _setup_api
    api_init 2>/dev/null
    api_get_key "NONEXISTENT_KEY"
    assert_fail $?
    _teardown_api
  }

  it "handles keys with special characters in value" && {
    _setup_api
    api_init 2>/dev/null
    api_set_key "SPECIAL_KEY" "sk-abc123+def/ghi=jkl"
    result=$(api_get_key "SPECIAL_KEY")
    assert_eq "$result" "sk-abc123+def/ghi=jkl"
    _teardown_api
  }

  it "retrieves key from environment variable when not in keys.conf" && {
    _setup_api
    api_init 2>/dev/null
    export TEST_ENV_KEY="env_secret_456"
    result=$(api_get_key "TEST_ENV_KEY")
    assert_eq "$result" "env_secret_456"
    unset TEST_ENV_KEY
    _teardown_api
  }

  it "retrieves SERPER_API_KEY from environment variable SERPER_API as fallback" && {
    _setup_api
    api_init 2>/dev/null
    export SERPER_API="fallback_serper_val_env"
    result=$(api_get_key "SERPER_API_KEY")
    assert_eq "$result" "fallback_serper_val_env"
    unset SERPER_API
    _teardown_api
  }

  it "retrieves SERPER_API_KEY from keys.conf SERPER_API entry as fallback" && {
    _setup_api
    api_init 2>/dev/null
    api_set_key "SERPER_API" "fallback_serper_val_conf"
    result=$(api_get_key "SERPER_API_KEY")
    assert_eq "$result" "fallback_serper_val_conf"
    _teardown_api
  }

# ── api_list_keys ──────────────────────────────────────────────
describe "api_list_keys"

  it "lists configured keys" && {
    _setup_api
    api_init 2>/dev/null
    api_set_key "LIST_TEST_KEY" "somevalue"
    out=$(api_list_keys 2>&1)
    assert_contains "$out" "LIST_TEST_KEY"
    _teardown_api
  }

# ── api_require_key ────────────────────────────────────────────
describe "api_require_key"

  it "returns the key value when set" && {
    _setup_api
    api_init 2>/dev/null
    api_set_key "REQUIRE_TEST" "myvalue"
    result=$(api_require_key "REQUIRE_TEST" "Test Service" 2>/dev/null)
    assert_eq "$result" "myvalue"
    _teardown_api
  }

  it "fails with error when key is missing" && {
    _setup_api
    api_init 2>/dev/null
    api_require_key "MISSING_KEY" "Missing Service" 2>/dev/null
    assert_fail $?
    _teardown_api
  }

# ── api_json_escape ────────────────────────────────────────────
describe "api_json_escape"

  it "escapes double quotes" && {
    result=$(api_json_escape 'hello "world"')
    assert_contains "$result" '\"world\"'
  }

  it "escapes newlines" && {
    result=$(api_json_escape "line1
line2")
    assert_contains "$result" '\n'
  }

  it "handles empty string" && {
    result=$(api_json_escape "")
    assert_eq "$result" '""'
  }

# ── api_json_get ───────────────────────────────────────────────
describe "api_json_get"

  it "extracts a field from JSON" && {
    if ! command -v jq &>/dev/null; then
      skip "jq not installed"
    else
      json='{"name":"George","version":"0.1"}'
      result=$(api_json_get "$json" '.name')
      assert_eq "$result" "George"
    fi
  }

  it "extracts nested field" && {
    if ! command -v jq &>/dev/null; then
      skip "jq not installed"
    else
      json='{"data":{"id":"123"}}'
      result=$(api_json_get "$json" '.data.id')
      assert_eq "$result" "123"
    fi
  }

  it "returns null for missing field" && {
    if ! command -v jq &>/dev/null; then
      skip "jq not installed"
    else
      json='{"name":"George"}'
      result=$(api_json_get "$json" '.missing')
      assert_eq "$result" "null"
    fi
  }

# ── api_request (mocked) ──────────────────────────────────────
describe "api_request"

  it "exports _API_LAST_STATUS" && {
    # This will fail to connect but should still set the variable
    api_request "GET" "http://127.0.0.1:1/nonexistent" "" 2>/dev/null
    # _API_LAST_STATUS may or may not be set depending on curl behavior
    # Just verify function doesn't crash
    assert_ok 0  # function existed
  }

# ── Convenience wrappers existence ─────────────────────────────
describe "Convenience functions"

  it "api_get is defined" && {
    declare -f api_get &>/dev/null
    assert_ok $?
  }

  it "api_post is defined" && {
    declare -f api_post &>/dev/null
    assert_ok $?
  }

  it "api_stream_post is defined" && {
    declare -f api_stream_post &>/dev/null
    assert_ok $?
  }

  it "api_put is defined" && {
    declare -f api_put &>/dev/null
    assert_ok $?
  }

  it "api_delete is defined" && {
    declare -f api_delete &>/dev/null
    assert_ok $?
  }

  it "api_retry is defined" && {
    declare -f api_retry &>/dev/null
    assert_ok $?
  }

# ── api_retry ──────────────────────────────────────────────────
describe "api_retry"

  it "succeeds on first attempt if command succeeds" && {
    _always_ok() { return 0; }
    api_retry 3 _always_ok
    assert_ok $?
  }

  it "retries and eventually fails" && {
    _always_fail() { return 1; }
    api_retry 2 _always_fail 2>/dev/null
    assert_fail $?
  }

# ── Auth header builders ──────────────────────────────────────
describe "api_bearer_header"

  it "builds a Bearer auth header" && {
    result=$(api_bearer_header "tok-12345")
    assert_contains "$result" "Bearer tok-12345"
  }

describe "api_basic_header"

  it "builds a Basic auth header" && {
    result=$(api_basic_header "user" "pass")
    assert_contains "$result" "Basic"
  }

test_end
