#!/bin/bash
# ── Tests: lib/social.sh ──────────────────────────────────────
# Social media functions need API keys to actually work, so we
# test function existence, argument handling, and status display.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/api.sh"

TMPDIR_SOCIAL=""

_setup_social() {
    TMPDIR_SOCIAL=$(test_tmpdir)
    export GEORGE_CONFIG_DIR="$TMPDIR_SOCIAL/.george"
    export GEORGE_KEYS_FILE="$GEORGE_CONFIG_DIR/keys.conf"
    export GEORGE_COOKIES_DIR="$GEORGE_CONFIG_DIR/cookies"
    export GEORGE_CACHE_DIR="$GEORGE_CONFIG_DIR/cache"
    api_init 2>/dev/null
    source "$LODGE_DIR/lib/social.sh"
}

_teardown_social() {
    rm -rf "$TMPDIR_SOCIAL"
}

test_start "lib/social.sh — Social Media Integration"

# ── Function existence ─────────────────────────────────────────
describe "X (Twitter) functions"

  it "x_post is defined" && {
    _setup_social
    declare -f x_post &>/dev/null
    assert_ok $?
    _teardown_social
  }

  it "x_timeline is defined" && {
    declare -f x_timeline &>/dev/null
    assert_ok $?
  }

  it "x_search is defined" && {
    declare -f x_search &>/dev/null
    assert_ok $?
  }

  it "x_reply is defined" && {
    declare -f x_reply &>/dev/null
    assert_ok $?
  }

  it "x_delete is defined" && {
    declare -f x_delete &>/dev/null
    assert_ok $?
  }

describe "Mastodon functions"

  it "mastodon_post is defined" && {
    declare -f mastodon_post &>/dev/null
    assert_ok $?
  }

  it "mastodon_timeline is defined" && {
    declare -f mastodon_timeline &>/dev/null
    assert_ok $?
  }

  it "mastodon_search is defined" && {
    declare -f mastodon_search &>/dev/null
    assert_ok $?
  }

  it "mastodon_reply is defined" && {
    declare -f mastodon_reply &>/dev/null
    assert_ok $?
  }

  it "mastodon_notifications is defined" && {
    declare -f mastodon_notifications &>/dev/null
    assert_ok $?
  }

describe "Bluesky functions"

  it "bluesky_post is defined" && {
    declare -f bluesky_post &>/dev/null
    assert_ok $?
  }

  it "bluesky_timeline is defined" && {
    declare -f bluesky_timeline &>/dev/null
    assert_ok $?
  }

  it "bluesky_search is defined" && {
    declare -f bluesky_search &>/dev/null
    assert_ok $?
  }

describe "Discord functions"

  it "discord_webhook is defined" && {
    declare -f discord_webhook &>/dev/null
    assert_ok $?
  }

  it "discord_send is defined" && {
    declare -f discord_send &>/dev/null
    assert_ok $?
  }

  it "discord_read is defined" && {
    declare -f discord_read &>/dev/null
    assert_ok $?
  }

describe "Telegram functions"

  it "telegram_send is defined" && {
    declare -f telegram_send &>/dev/null
    assert_ok $?
  }

  it "telegram_get_updates is defined" && {
    declare -f telegram_get_updates &>/dev/null
    assert_ok $?
  }

  it "telegram_reply is defined" && {
    declare -f telegram_reply &>/dev/null
    assert_ok $?
  }

  it "telegram_get_me is defined" && {
    declare -f telegram_get_me &>/dev/null
    assert_ok $?
  }

# ── Missing key behavior ─────────────────────────────────────
describe "Missing API key handling"

  it "x_post fails without API key" && {
    _setup_social
    x_post "test" 2>/dev/null
    assert_fail $?
    _teardown_social
  }

  it "mastodon_post fails without API key" && {
    _setup_social
    mastodon_post "test" 2>/dev/null
    assert_fail $?
    _teardown_social
  }

  it "bluesky_post fails without credentials" && {
    _setup_social
    bluesky_post "test" 2>/dev/null
    assert_fail $?
    _teardown_social
  }

  it "telegram_send fails without bot token" && {
    _setup_social
    telegram_send "test" 2>/dev/null
    assert_fail $?
    _teardown_social
  }

  it "discord_send fails without bot token" && {
    _setup_social
    discord_send "235541481920659458" "test" 2>/dev/null
    assert_fail $?
    _teardown_social
  }

# ── Discord verbose error reporting ───────────────────────────
describe "Discord verbose error reporting"

  it "discord_send shows HTTP status and error message on failure" && {
    _setup_social
    api_set_key "DISCORD_BOT_TOKEN" "fake_token"
    test_mock "api_post" 'export _API_LAST_STATUS="403"; export _API_LAST_BODY="{\"message\": \"Missing Permissions\", \"code\": 50013}"; return 1'
    out=$(discord_send "235541481920659458" "test" 2>&1)
    assert_contains "$out" "403"
    assert_contains "$out" "Missing Permissions"
    assert_contains "$out" "50013"
    test_unmock "api_post"
    _teardown_social
  }

  it "discord_send shows channel ID on failure" && {
    _setup_social
    api_set_key "DISCORD_BOT_TOKEN" "fake_token"
    test_mock "api_post" 'export _API_LAST_STATUS="404"; export _API_LAST_BODY="{\"message\": \"Unknown Channel\", \"code\": 10003}"; return 1'
    out=$(discord_send "235541481920659458" "test" 2>&1)
    assert_contains "$out" "235541481920659458"
    test_unmock "api_post"
    _teardown_social
  }

  it "discord_webhook shows HTTP status on failure" && {
    _setup_social
    api_set_key "DISCORD_WEBHOOK_URL" "https://discord.com/api/webhooks/fake"
    test_mock "api_post" 'export _API_LAST_STATUS="401"; export _API_LAST_BODY="{\"message\": \"401: Unauthorized\"}"; return 1'
    out=$(discord_webhook "test" 2>&1)
    assert_contains "$out" "401"
    assert_contains "$out" "Unauthorized"
    test_unmock "api_post"
    _teardown_social
  }

  it "discord_send prints success with channel ID on success" && {
    _setup_social
    api_set_key "DISCORD_BOT_TOKEN" "fake_token"
    test_mock "api_post" 'export _API_LAST_STATUS="200"; export _API_LAST_BODY="{\"id\": \"123456\"}"; return 0'
    out=$(discord_send "235541481920659458" "test" 2>&1)
    assert_contains "$out" "Sent to Discord"
    assert_contains "$out" "235541481920659458"
    test_unmock "api_post"
    _teardown_social
  }

# ── social_post dispatcher ────────────────────────────────────
describe "social_post (unified dispatcher)"

  it "social_post is defined" && {
    declare -f social_post &>/dev/null
    assert_ok $?
  }

  it "handles 'all' with no keys configured" && {
    _setup_social
    out=$(social_post "test" "all" 2>&1)
    # Should complete without crash — no platforms configured
    assert_ok $?
    _teardown_social
  }

# ── social_status ─────────────────────────────────────────────
describe "social_status"

  it "shows status for all platforms" && {
    _setup_social
    out=$(social_status 2>&1)
    assert_contains "$out" "Social Integrations"
    assert_contains "$out" "not configured"
    _teardown_social
  }

  it "shows configured platform when key is set" && {
    _setup_social
    api_set_key "X_BEARER_TOKEN" "test_token"
    out=$(social_status 2>&1)
    assert_contains "$out" "configured"
    _teardown_social
  }

# ── _mastodon_base ─────────────────────────────────────────────
describe "_mastodon_base"

  it "returns default instance when not configured" && {
    _setup_social
    base=$(_mastodon_base)
    assert_eq "$base" "https://mastodon.social"
    _teardown_social
  }

  it "returns configured instance" && {
    _setup_social
    api_set_key "MASTODON_INSTANCE" "https://fosstodon.org"
    base=$(_mastodon_base)
    assert_eq "$base" "https://fosstodon.org"
    _teardown_social
  }

test_end
