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

  it "discord_channel_resolve strips quotes from name" && {
    _setup_social
    body=$(declare -f discord_channel_resolve)
    # Verify it strips # and quotes via sed
    echo "$body" | grep -q 'sed'
    assert_ok $?
    # Verify double-# strip (once before quotes, once after)
    echo "$body" | grep -c 'name#' | grep -q '2'
    assert_ok $?
    _teardown_social
  }

  it "discord_send strips quotes from channel and message" && {
    _setup_social
    body=$(declare -f discord_send)
    # Verify channel_id quote stripping
    echo "$body" | grep -q 'channel_id=.*sed'
    assert_ok $?
    # Verify message quote stripping
    echo "$body" | grep -q 'message=.*sed'
    assert_ok $?
    _teardown_social
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

# ── discord_validate ──────────────────────────────────────────
describe "discord_validate"

  it "discord_validate is defined" && {
    declare -f discord_validate &>/dev/null
    assert_ok $?
  }

  it "fails without bot token" && {
    _setup_social
    discord_validate 2>/dev/null
    assert_fail $?
    _teardown_social
  }

  it "shows error on invalid token" && {
    _setup_social
    api_set_key "DISCORD_BOT_TOKEN" "fake_token"
    test_mock "api_get" 'export _API_LAST_STATUS="401"; export _API_LAST_BODY="{\"message\": \"401: Unauthorized\", \"code\": 0}"; echo "$_API_LAST_BODY"; return 1'
    out=$(discord_validate 2>&1)
    assert_contains "$out" "FAILED"
    test_unmock "api_get"
    _teardown_social
  }

  it "shows bot info on valid token" && {
    _setup_social
    api_set_key "DISCORD_BOT_TOKEN" "fake_token"
    call_count=0
    test_mock "api_get" '
      call_count=$((${call_count:-0} + 1))
      if [[ "$1" == *"/users/@me/guilds"* ]]; then
        export _API_LAST_STATUS="200"
        export _API_LAST_BODY="[]"
        echo "[]"
        return 0
      else
        export _API_LAST_STATUS="200"
        export _API_LAST_BODY="{\"username\":\"TestBot\",\"id\":\"123\",\"discriminator\":\"0001\"}"
        echo "{\"username\":\"TestBot\",\"id\":\"123\",\"discriminator\":\"0001\"}"
        return 0
      fi'
    out=$(discord_validate 2>&1)
    assert_contains "$out" "TestBot"
    test_unmock "api_get"
    _teardown_social
  }

# ── Discord channel registry ─────────────────────────────────
describe "Discord channel registry"

  it "discord_channel_add is defined" && {
    declare -f discord_channel_add &>/dev/null
    assert_ok $?
  }

  it "discord_channel_list is defined" && {
    declare -f discord_channel_list &>/dev/null
    assert_ok $?
  }

  it "discord_channel_resolve is defined" && {
    declare -f discord_channel_resolve &>/dev/null
    assert_ok $?
  }

  it "discord_channels_sync is defined" && {
    declare -f discord_channels_sync &>/dev/null
    assert_ok $?
  }

  it "discord_default_channel is defined" && {
    declare -f discord_default_channel &>/dev/null
    assert_ok $?
  }

  it "registers and resolves a channel" && {
    _setup_social
    export DISCORD_CHANNELS_DB="$TMPDIR_SOCIAL/discord_channels.db"
    discord_channel_add "general" "123456789012345678" 2>/dev/null
    resolved=$(discord_channel_resolve "general")
    assert_eq "$resolved" "123456789012345678"
    _teardown_social
  }

  it "resolves with leading # stripped" && {
    _setup_social
    export DISCORD_CHANNELS_DB="$TMPDIR_SOCIAL/discord_channels.db"
    discord_channel_add "dev" "987654321098765432" 2>/dev/null
    resolved=$(discord_channel_resolve "#dev")
    assert_eq "$resolved" "987654321098765432"
    _teardown_social
  }

  it "lists registered channels" && {
    _setup_social
    export DISCORD_CHANNELS_DB="$TMPDIR_SOCIAL/discord_channels.db"
    discord_channel_add "general" "111111111111111111" 2>/dev/null
    discord_channel_add "dev" "222222222222222222" 2>/dev/null
    out=$(discord_channel_list 2>&1)
    assert_contains "$out" "general"
    assert_contains "$out" "dev"
    _teardown_social
  }

  it "removes a channel" && {
    _setup_social
    export DISCORD_CHANNELS_DB="$TMPDIR_SOCIAL/discord_channels.db"
    discord_channel_add "temp" "333333333333333333" 2>/dev/null
    discord_channel_remove "temp" 2>/dev/null
    resolved=$(discord_channel_resolve "temp")
    assert_eq "$resolved" ""
    _teardown_social
  }

  it "default_channel returns general when registered" && {
    _setup_social
    export DISCORD_CHANNELS_DB="$TMPDIR_SOCIAL/discord_channels.db"
    discord_channel_add "general" "444444444444444444" 2>/dev/null
    discord_channel_add "random" "555555555555555555" 2>/dev/null
    def=$(discord_default_channel)
    assert_eq "$def" "444444444444444444"
    _teardown_social
  }

  it "default_channel respects DISCORD_DEFAULT_CHANNEL key" && {
    _setup_social
    export DISCORD_CHANNELS_DB="$TMPDIR_SOCIAL/discord_channels.db"
    api_set_key "DISCORD_DEFAULT_CHANNEL" "666666666666666666"
    def=$(discord_default_channel)
    assert_eq "$def" "666666666666666666"
    _teardown_social
  }

  it "discord_send resolves channel names" && {
    _setup_social
    export DISCORD_CHANNELS_DB="$TMPDIR_SOCIAL/discord_channels.db"
    discord_channel_add "general" "777777777777777777" 2>/dev/null
    api_set_key "DISCORD_BOT_TOKEN" "fake_token"
    test_mock "api_post" 'export _API_LAST_STATUS="200"; export _API_LAST_BODY="{}"; return 0'
    out=$(discord_send "general" "hello" 2>&1)
    assert_contains "$out" "Sent to Discord"
    assert_contains "$out" "777777777777777777"
    test_unmock "api_post"
    _teardown_social
  }

  it "discord_send errors on unknown channel name" && {
    _setup_social
    export DISCORD_CHANNELS_DB="$TMPDIR_SOCIAL/discord_channels.db"
    api_set_key "DISCORD_BOT_TOKEN" "fake_token"
    out=$(discord_send "nonexistent" "hello" 2>&1)
    assert_fail $?
    assert_contains "$out" "Unknown channel"
    _teardown_social
  }

# ── social_post Discord bot fallback ─────────────────────────
describe "social_post Discord bot token fallback"

  it "social_post 'discord' uses bot API with default channel" && {
    _setup_social
    export DISCORD_CHANNELS_DB="$TMPDIR_SOCIAL/discord_channels.db"
    discord_channel_add "general" "888888888888888888" 2>/dev/null
    api_set_key "DISCORD_BOT_TOKEN" "fake_token"
    test_mock "api_post" 'export _API_LAST_STATUS="200"; export _API_LAST_BODY="{}"; return 0'
    out=$(social_post "test message" "discord" 2>&1)
    assert_contains "$out" "Discord: ✓"
    test_unmock "api_post"
    _teardown_social
  }

  it "social_post 'discord' errors without webhook or default channel" && {
    _setup_social
    export DISCORD_CHANNELS_DB="$TMPDIR_SOCIAL/discord_channels.db"
    api_set_key "DISCORD_BOT_TOKEN" "fake_token"
    out=$(social_post "test message" "discord" 2>&1)
    assert_contains "$out" "no default channel"
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

# ── /social post dispatch (lodge _cmd_social) ──────────────────
describe "social_post dispatch parsing"

  it "social_post requires platform when unified toggle off" && {
    _setup_social
    export SOCIAL_UNIFIED_POST=0
    out=$(social_post "Hello world this is a test message" 2>&1)
    rc=$?
    assert_eq "$rc" "1"
    assert_contains "$out" "No platform specified"
    _teardown_social
  }

  it "social_post broadcasts when unified toggle on" && {
    _setup_social
    export SOCIAL_UNIFIED_POST=1
    out=$(social_post "Hello world this is a test message" 2>&1)
    assert_ok $?
    _teardown_social
  }

  it "social_post accepts platform + message" && {
    _setup_social
    out=$(social_post "Hello world" "discord" 2>&1)
    # Discord not configured, but should still parse correctly
    assert_contains "$out" "Discord"
    _teardown_social
  }

  it "social_post handles quoted message with spaces" && {
    _setup_social
    export SOCIAL_UNIFIED_POST=1
    out=$(social_post "Brothers and sisters in the great Discord of thought" 2>&1)
    assert_ok $?
    _teardown_social
  }

# ── Mastodon multi-instance registry ──────────────────────────
describe "Mastodon multi-instance registry"

  it "_mastodon_instances_init creates DB" && {
    _setup_social
    _mastodon_instances_init
    [ -f "$MASTODON_INSTANCES_DB" ]
    assert_ok $?
    _teardown_social
  }

  it "mastodon_instance_add registers an instance" && {
    _setup_social
    out=$(mastodon_instance_add "mastodon.social" "tok123" 2>&1)
    assert_ok $?
    assert_contains "$out" "mastodon.social"
    _teardown_social
  }

  it "mastodon_instance_list shows registered instances" && {
    _setup_social
    mastodon_instance_add "mastodon.social" "tok123" &>/dev/null
    mastodon_instance_add "fosstodon.org" "tok456" &>/dev/null
    out=$(mastodon_instance_list 2>&1)
    assert_contains "$out" "mastodon.social"
    assert_contains "$out" "fosstodon.org"
    _teardown_social
  }

  it "mastodon_instance_remove removes an instance" && {
    _setup_social
    mastodon_instance_add "mastodon.social" "tok123" &>/dev/null
    mastodon_instance_remove "mastodon.social" &>/dev/null
    out=$(mastodon_instance_list 2>&1)
    [[ "$out" != *"mastodon.social"* ]]
    assert_ok $?
    _teardown_social
  }

  it "_mastodon_instance_token resolves specific instance" && {
    _setup_social
    mastodon_instance_add "mastodon.social" "tok123" &>/dev/null
    mastodon_instance_add "fosstodon.org" "tok456" &>/dev/null
    token=$(_mastodon_instance_token "fosstodon.org")
    assert_eq "$token" "tok456"
    _teardown_social
  }

  it "_mastodon_instance_token falls back to first registered" && {
    _setup_social
    mastodon_instance_add "mastodon.social" "tok_first" &>/dev/null
    token=$(_mastodon_instance_token "")
    assert_eq "$token" "tok_first"
    _teardown_social
  }

  it "_mastodon_instance_token falls back to legacy key" && {
    _setup_social
    api_set_key "MASTODON_ACCESS_TOKEN" "legacy_tok"
    token=$(_mastodon_instance_token "")
    assert_eq "$token" "legacy_tok"
    _teardown_social
  }

  it "_mastodon_instance_url returns full URL for registered instance" && {
    _setup_social
    mastodon_instance_add "fosstodon.org" "tok456" &>/dev/null
    url=$(_mastodon_instance_url "fosstodon.org")
    assert_eq "$url" "https://fosstodon.org"
    _teardown_social
  }

# ── Discord user registry ─────────────────────────────────────
describe "Discord user registry"

  it "_discord_users_init creates DB" && {
    _setup_social
    _discord_users_init
    [ -f "$DISCORD_USERS_DB" ]
    assert_ok $?
    _teardown_social
  }

  it "discord_user_add registers a user" && {
    _setup_social
    out=$(discord_user_add "pompler" "123456789012345678" 2>&1)
    assert_ok $?
    assert_contains "$out" "pompler"
    _teardown_social
  }

  it "discord_user_list shows registered users" && {
    _setup_social
    discord_user_add "pompler" "123456789012345678" &>/dev/null
    discord_user_add "testuser" "987654321098765432" &>/dev/null
    out=$(discord_user_list 2>&1)
    assert_contains "$out" "pompler"
    assert_contains "$out" "testuser"
    _teardown_social
  }

  it "discord_user_remove removes a user" && {
    _setup_social
    discord_user_add "pompler" "123456789012345678" &>/dev/null
    discord_user_remove "pompler" &>/dev/null
    out=$(discord_user_list 2>&1)
    [[ "$out" != *"pompler"* ]] || [ -z "$out" ]
    assert_ok $?
    _teardown_social
  }

  it "discord_user_resolve returns user ID by name" && {
    _setup_social
    discord_user_add "pompler" "123456789012345678" &>/dev/null
    uid=$(discord_user_resolve "pompler")
    assert_eq "$uid" "123456789012345678"
    _teardown_social
  }

  it "discord_user_resolve returns empty for unknown" && {
    _setup_social
    uid=$(discord_user_resolve "nobody_here" 2>/dev/null)
    assert_eq "$uid" ""
    _teardown_social
  }

  it "discord_users_sync function is defined" && {
    _setup_social
    declare -f discord_users_sync &>/dev/null
    assert_ok $?
    _teardown_social
  }

# ── Discord @mention resolution ───────────────────────────────
describe "Discord @mention resolution"

  it "discord_resolve_mentions replaces @username with <@id>" && {
    _setup_social
    discord_user_add "pompler" "123456789012345678" &>/dev/null
    result=$(discord_resolve_mentions "Hey @pompler check this out")
    assert_eq "$result" "Hey <@123456789012345678> check this out"
    _teardown_social
  }

  it "discord_resolve_mentions handles multiple @mentions" && {
    _setup_social
    discord_user_add "pompler" "111111111111111111" &>/dev/null
    discord_user_add "dabe" "222222222222222222" &>/dev/null
    result=$(discord_resolve_mentions "Hey @pompler and @dabe!")
    assert_contains "$result" "<@111111111111111111>"
    assert_contains "$result" "<@222222222222222222>"
    _teardown_social
  }

  it "discord_resolve_mentions leaves unknown @mentions alone" && {
    _setup_social
    result=$(discord_resolve_mentions "Hey @nobody here")
    assert_eq "$result" "Hey @nobody here"
    _teardown_social
  }

# ── Discord DM ────────────────────────────────────────────────
describe "Discord DM support"

  it "discord_dm function is defined" && {
    _setup_social
    declare -f discord_dm &>/dev/null
    assert_ok $?
    _teardown_social
  }

# ── Escape expansion in social functions ───────────────────────
describe "LLM escape expansion in social output"

  it "x_post expands escapes" && {
    _setup_social
    fn_body=$(declare -f x_post)
    assert_contains "$fn_body" "ui_expand_escapes"
    _teardown_social
  }

  it "mastodon_post expands escapes" && {
    _setup_social
    fn_body=$(declare -f mastodon_post)
    assert_contains "$fn_body" "ui_expand_escapes"
    _teardown_social
  }

  it "bluesky_post expands escapes" && {
    _setup_social
    fn_body=$(declare -f bluesky_post)
    assert_contains "$fn_body" "ui_expand_escapes"
    _teardown_social
  }

  it "discord_webhook expands escapes" && {
    _setup_social
    fn_body=$(declare -f discord_webhook)
    assert_contains "$fn_body" "ui_expand_escapes"
    _teardown_social
  }

  it "discord_send expands escapes" && {
    _setup_social
    fn_body=$(declare -f discord_send)
    assert_contains "$fn_body" "ui_expand_escapes"
    _teardown_social
  }

  it "telegram_send expands escapes" && {
    _setup_social
    fn_body=$(declare -f telegram_send)
    assert_contains "$fn_body" "ui_expand_escapes"
    _teardown_social
  }

test_end
