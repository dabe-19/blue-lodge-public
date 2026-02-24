#!/bin/bash
# ── George: Social Media Integration ───────────────────────────
# Post, read, and interact on X, Mastodon, Bluesky, Discord,
# and Telegram — all via pure curl + their REST APIs.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/api.sh"

# ═══════════════════════════════════════════════════════════════
# X (Twitter) — v2 API with Bearer Token
# ═══════════════════════════════════════════════════════════════
# Setup: Create app at developer.x.com, get Bearer Token
# Key: X_BEARER_TOKEN

x_post() {
    local text="$1"
    local token
    token=$(api_require_key "X_BEARER_TOKEN" "X/Twitter") || return 1

    local data
    data=$(jq -n --arg t "$text" '{"text": $t}')

    local resp
    resp=$(api_post "https://api.x.com/2/tweets" "$data" \
        -H "Authorization: Bearer $token")
    local status=$?

    if [ $status -eq 0 ]; then
        local tweet_id
        tweet_id=$(api_json_get "$resp" '.data.id')
        ui_ok "Posted to X (ID: $tweet_id)"
        echo "$resp"
    else
        ui_err "X post failed: $(api_json_get "$resp" '.detail // .title // "unknown error"')"
        return 1
    fi
}

x_timeline() {
    local count="${1:-10}"
    local token
    token=$(api_require_key "X_BEARER_TOKEN" "X/Twitter") || return 1

    local resp
    resp=$(api_get "https://api.x.com/2/tweets/search/recent?max_results=$count&query=from:me" \
        -H "Authorization: Bearer $token")

    if [ $? -eq 0 ]; then
        echo "$resp" | jq -r '.data[]? | "[\(.id)] \(.text)"' 2>/dev/null
    else
        ui_err "Failed to fetch X timeline"
        return 1
    fi
}

x_reply() {
    local tweet_id="$1"
    local text="$2"
    local token
    token=$(api_require_key "X_BEARER_TOKEN" "X/Twitter") || return 1

    local data
    data=$(jq -n --arg t "$text" --arg id "$tweet_id" \
        '{"text": $t, "reply": {"in_reply_to_tweet_id": $id}}')

    api_post "https://api.x.com/2/tweets" "$data" \
        -H "Authorization: Bearer $token"
}

x_search() {
    local query="$1"
    local count="${2:-10}"
    local token
    token=$(api_require_key "X_BEARER_TOKEN" "X/Twitter") || return 1

    local encoded_query
    encoded_query=$(printf '%s' "$query" | jq -sRr @uri)

    api_get "https://api.x.com/2/tweets/search/recent?max_results=$count&query=$encoded_query" \
        -H "Authorization: Bearer $token" | \
        jq -r '.data[]? | "[\(.id)] \(.text)"' 2>/dev/null
}

x_delete() {
    local tweet_id="$1"
    local token
    token=$(api_require_key "X_BEARER_TOKEN" "X/Twitter") || return 1

    api_delete "https://api.x.com/2/tweets/$tweet_id" \
        -H "Authorization: Bearer $token"
}

# ═══════════════════════════════════════════════════════════════
# Mastodon — ActivityPub-compatible instances
# ═══════════════════════════════════════════════════════════════
# Setup: Settings → Development → New Application → Access Token
# Keys: MASTODON_INSTANCE, MASTODON_ACCESS_TOKEN

_mastodon_base() {
    local instance
    instance=$(api_get_key "MASTODON_INSTANCE")
    echo "${instance:-https://mastodon.social}"
}

mastodon_post() {
    local text="$1"
    local visibility="${2:-public}"  # public, unlisted, private, direct
    local token
    token=$(api_require_key "MASTODON_ACCESS_TOKEN" "Mastodon") || return 1
    local base
    base=$(_mastodon_base)

    local data
    data=$(jq -n --arg s "$text" --arg v "$visibility" \
        '{"status": $s, "visibility": $v}')

    local resp
    resp=$(api_post "$base/api/v1/statuses" "$data" \
        -H "Authorization: Bearer $token")

    if [ $? -eq 0 ]; then
        local url
        url=$(api_json_get "$resp" '.url')
        ui_ok "Posted to Mastodon: $url"
        echo "$resp"
    else
        ui_err "Mastodon post failed"
        return 1
    fi
}

mastodon_timeline() {
    local count="${1:-20}"
    local token
    token=$(api_require_key "MASTODON_ACCESS_TOKEN" "Mastodon") || return 1
    local base
    base=$(_mastodon_base)

    api_get "$base/api/v1/timelines/home?limit=$count" \
        -H "Authorization: Bearer $token" | \
        jq -r '.[]? | "[\(.account.acct)] \(.content | gsub("<[^>]+>"; ""))"' 2>/dev/null
}

mastodon_reply() {
    local status_id="$1"
    local text="$2"
    local token
    token=$(api_require_key "MASTODON_ACCESS_TOKEN" "Mastodon") || return 1
    local base
    base=$(_mastodon_base)

    local data
    data=$(jq -n --arg s "$text" --arg id "$status_id" \
        '{"status": $s, "in_reply_to_id": $id}')

    api_post "$base/api/v1/statuses" "$data" \
        -H "Authorization: Bearer $token"
}

mastodon_search() {
    local query="$1"
    local token
    token=$(api_require_key "MASTODON_ACCESS_TOKEN" "Mastodon") || return 1
    local base
    base=$(_mastodon_base)

    local encoded
    encoded=$(printf '%s' "$query" | jq -sRr @uri)

    api_get "$base/api/v2/search?q=$encoded&type=statuses&limit=10" \
        -H "Authorization: Bearer $token" | \
        jq -r '.statuses[]? | "[\(.account.acct)] \(.content | gsub("<[^>]+>"; ""))"' 2>/dev/null
}

mastodon_notifications() {
    local count="${1:-10}"
    local token
    token=$(api_require_key "MASTODON_ACCESS_TOKEN" "Mastodon") || return 1
    local base
    base=$(_mastodon_base)

    api_get "$base/api/v1/notifications?limit=$count" \
        -H "Authorization: Bearer $token" | \
        jq -r '.[]? | "\(.type): @\(.account.acct) — \(.status.content // "" | gsub("<[^>]+>"; "") | .[0:100])"' 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
# Bluesky — AT Protocol
# ═══════════════════════════════════════════════════════════════
# Setup: Settings → App Passwords → Add App Password
# Keys: BLUESKY_HANDLE, BLUESKY_APP_PASSWORD

_BLUESKY_SESSION=""

_bluesky_login() {
    local handle
    handle=$(api_require_key "BLUESKY_HANDLE" "Bluesky") || return 1
    local password
    password=$(api_require_key "BLUESKY_APP_PASSWORD" "Bluesky") || return 1

    local data
    data=$(jq -n --arg h "$handle" --arg p "$password" \
        '{"identifier": $h, "password": $p}')

    local resp
    resp=$(api_post "https://bsky.social/xrpc/com.atproto.server.createSession" "$data")

    if [ $? -eq 0 ]; then
        _BLUESKY_SESSION="$resp"
        return 0
    else
        ui_err "Bluesky login failed"
        return 1
    fi
}

_bluesky_token() {
    if [ -z "$_BLUESKY_SESSION" ]; then
        _bluesky_login || return 1
    fi
    api_json_get "$_BLUESKY_SESSION" '.accessJwt'
}

_bluesky_did() {
    if [ -z "$_BLUESKY_SESSION" ]; then
        _bluesky_login || return 1
    fi
    api_json_get "$_BLUESKY_SESSION" '.did'
}

bluesky_post() {
    local text="$1"
    local token
    token=$(_bluesky_token) || return 1
    local did
    did=$(_bluesky_did) || return 1

    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

    local data
    data=$(jq -n --arg did "$did" --arg text "$text" --arg now "$now" '{
        "repo": $did,
        "collection": "app.bsky.feed.post",
        "record": {
            "$type": "app.bsky.feed.post",
            "text": $text,
            "createdAt": $now
        }
    }')

    local resp
    resp=$(api_post "https://bsky.social/xrpc/com.atproto.repo.createRecord" "$data" \
        -H "Authorization: Bearer $token")

    if [ $? -eq 0 ]; then
        local uri
        uri=$(api_json_get "$resp" '.uri')
        ui_ok "Posted to Bluesky ($uri)"
        echo "$resp"
    else
        ui_err "Bluesky post failed"
        return 1
    fi
}

bluesky_timeline() {
    local count="${1:-20}"
    local token
    token=$(_bluesky_token) || return 1

    api_get "https://bsky.social/xrpc/app.bsky.feed.getTimeline?limit=$count" \
        -H "Authorization: Bearer $token" | \
        jq -r '.feed[]? | "[\(.post.author.handle)] \(.post.record.text)"' 2>/dev/null
}

bluesky_search() {
    local query="$1"
    local count="${2:-10}"
    local token
    token=$(_bluesky_token) || return 1

    local encoded
    encoded=$(printf '%s' "$query" | jq -sRr @uri)

    api_get "https://bsky.social/xrpc/app.bsky.feed.searchPosts?q=$encoded&limit=$count" \
        -H "Authorization: Bearer $token" | \
        jq -r '.posts[]? | "[\(.author.handle)] \(.record.text)"' 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
# Discord — Bot API or Webhook
# ═══════════════════════════════════════════════════════════════
# Setup (Webhook): Server Settings → Integrations → Webhooks
# Setup (Bot): discord.com/developers → Applications → Bot
# Keys: DISCORD_BOT_TOKEN, DISCORD_WEBHOOK_URL
# Channel DB: .george/discord_channels.db (name → ID registry)

DISCORD_CHANNELS_DB="${DISCORD_CHANNELS_DB:-${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}/discord_channels.db}"

discord_webhook() {
    local message="$1"
    local username="${2:-George}"
    local webhook_url
    webhook_url=$(api_require_key "DISCORD_WEBHOOK_URL" "Discord Webhook") || return 1

    local data
    data=$(jq -n --arg c "$message" --arg u "$username" \
        '{"content": $c, "username": $u}')

    api_post "$webhook_url" "$data" > /dev/null
    if [ $? -eq 0 ] || [ "${_API_LAST_STATUS:-}" = "204" ]; then
        ui_ok "Sent to Discord"
    else
        local err_msg
        err_msg=$(api_json_get "${_API_LAST_BODY:-}" '.message // .error // "unknown error"')
        ui_err "Discord webhook failed (HTTP ${_API_LAST_STATUS:-unknown}): $err_msg"
        return 1
    fi
}

discord_send() {
    local channel_id="$1"
    local message="$2"

    # Strip surrounding quotes — LLM wraps args in "..." or '...'
    channel_id=$(echo "$channel_id" | sed "s/^[\"']//; s/[\"']$//")
    message=$(echo "$message" | sed "s/^[\"']//; s/[\"']$//")

    # Resolve channel name → ID if not numeric
    if ! [[ "$channel_id" =~ ^[0-9]+$ ]]; then
        local resolved
        resolved=$(discord_channel_resolve "$channel_id")
        if [ -z "$resolved" ]; then
            ui_err "Unknown channel: $channel_id"
            ui_dim "Register it: /social discord channels add <name> <channel_id>"
            ui_dim "Or sync from Discord: /social discord channels sync"
            return 1
        fi
        channel_id="$resolved"
    fi

    local token
    token=$(api_require_key "DISCORD_BOT_TOKEN" "Discord Bot") || return 1

    local data
    data=$(jq -n --arg c "$message" '{"content": $c}')

    api_post "https://discord.com/api/v10/channels/$channel_id/messages" "$data" \
        -H "Authorization: Bot $token" > /dev/null
    local status=$?

    if [ $status -eq 0 ]; then
        ui_ok "Sent to Discord (channel: $channel_id)"
    else
        local err_msg
        err_msg=$(api_json_get "${_API_LAST_BODY:-}" '.message // .error // "unknown error"')
        local err_code
        err_code=$(api_json_get "${_API_LAST_BODY:-}" '.code // empty')
        ui_err "Discord send failed (HTTP ${_API_LAST_STATUS:-unknown}): $err_msg${err_code:+ (code: $err_code)}"
        ui_dim "Channel: $channel_id"
        return 1
    fi
}

discord_read() {
    local channel_id="$1"
    local count="${2:-10}"

    # Resolve channel name → ID if not numeric
    if ! [[ "$channel_id" =~ ^[0-9]+$ ]]; then
        local resolved
        resolved=$(discord_channel_resolve "$channel_id")
        if [ -z "$resolved" ]; then
            ui_err "Unknown channel: $channel_id"
            return 1
        fi
        channel_id="$resolved"
    fi

    local token
    token=$(api_require_key "DISCORD_BOT_TOKEN" "Discord Bot") || return 1

    api_get "https://discord.com/api/v10/channels/$channel_id/messages?limit=$count" \
        -H "Authorization: Bot $token" | \
        jq -r '.[]? | "[\(.author.username)] \(.content)"' 2>/dev/null
}

# ── Discord: Validate bot token ───────────────────────────────
# Calls GET /users/@me to verify the token is valid, then shows
# the bot's username, ID, and connected guilds.
discord_validate() {
    local token
    token=$(api_require_key "DISCORD_BOT_TOKEN" "Discord Bot") || return 1

    ui_info "Validating Discord bot token..."

    # Test the token against /users/@me
    local resp
    resp=$(api_get "https://discord.com/api/v10/users/@me" \
        -H "Authorization: Bot $token")
    local status=$?

    if [ $status -ne 0 ]; then
        local err_msg
        err_msg=$(api_json_get "${_API_LAST_BODY:-}" '.message // "unknown error"')
        local err_code
        err_code=$(api_json_get "${_API_LAST_BODY:-}" '.code // empty')
        ui_err "Token validation FAILED (HTTP ${_API_LAST_STATUS:-unknown}): $err_msg${err_code:+ (code: $err_code)}"
        case "${_API_LAST_STATUS:-}" in
            401) ui_dim "Token is invalid or revoked. Regenerate at discord.com/developers" ;;
            403) ui_dim "Token lacks required scopes. Check bot permissions." ;;
        esac
        return 1
    fi

    local bot_name bot_id bot_disc
    bot_name=$(api_json_get "$resp" '.username')
    bot_id=$(api_json_get "$resp" '.id')
    bot_disc=$(api_json_get "$resp" '.discriminator')

    ui_ok "Token valid — Bot: ${bot_name}#${bot_disc} (ID: ${bot_id})"

    # List connected guilds
    local guilds
    guilds=$(api_get "https://discord.com/api/v10/users/@me/guilds" \
        -H "Authorization: Bot $token")

    if [ $? -eq 0 ]; then
        local guild_count
        guild_count=$(echo "$guilds" | jq 'length' 2>/dev/null)
        if [ "${guild_count:-0}" -gt 0 ]; then
            ui_section "Connected Servers ($guild_count)"
            echo "$guilds" | jq -r '.[]? | "  \(.name) (ID: \(.id))"' 2>/dev/null
        else
            ui_warn "Bot is not in any servers"
            ui_dim "Invite it: https://discord.com/oauth2/authorize?client_id=${bot_id}&scope=bot&permissions=2048"
        fi
    fi
}

# ── Discord: Channel name→ID registry (SQLite) ───────────────
# Stores channel_name → channel_id mappings so George can
# reference channels by human-readable names instead of IDs.

_discord_channels_init() {
    if ! command -v sqlite3 &>/dev/null; then
        ui_err "sqlite3 required for channel registry"
        return 1
    fi
    mkdir -p "$(dirname "$DISCORD_CHANNELS_DB")"
    sqlite3 "$DISCORD_CHANNELS_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS channels (
    name TEXT NOT NULL COLLATE NOCASE,
    channel_id TEXT NOT NULL UNIQUE,
    guild_name TEXT DEFAULT '',
    guild_id TEXT DEFAULT '',
    type TEXT DEFAULT 'text',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_channels_name_guild
    ON channels(name, guild_id);
SQL
}

# Resolve a channel name to its ID (returns first match)
discord_channel_resolve() {
    local name="$1"
    # Strip leading # if present
    name="${name#\#}"
    # Strip surrounding quotes (LLM often wraps channel names in quotes)
    name=$(echo "$name" | sed 's/^["'\''"'\'']*//; s/["'\''"'\'']*$//')
    # Strip # again in case it was inside quotes like "#lunkers"
    name="${name#\#}"
    _discord_channels_init 2>/dev/null || return 1
    sqlite3 "$DISCORD_CHANNELS_DB" \
        "SELECT channel_id FROM channels WHERE name = '$name' COLLATE NOCASE LIMIT 1;" 2>/dev/null
}

# Add a channel mapping manually
discord_channel_add() {
    local name="$1"
    local channel_id="$2"
    local guild_name="${3:-}"
    local guild_id="${4:-}"
    name="${name#\#}"
    _discord_channels_init || return 1
    sqlite3 "$DISCORD_CHANNELS_DB" \
        "INSERT OR REPLACE INTO channels(name, channel_id, guild_name, guild_id)
         VALUES ('$name', '$channel_id', '$guild_name', '$guild_id');"
    ui_ok "Registered channel #${name} → ${channel_id}${guild_name:+ (${guild_name})}"
}

# Remove a channel mapping
discord_channel_remove() {
    local name="$1"
    name="${name#\#}"
    _discord_channels_init || return 1
    sqlite3 "$DISCORD_CHANNELS_DB" \
        "DELETE FROM channels WHERE name = '$name' COLLATE NOCASE;"
    ui_ok "Removed channel #${name}"
}

# List all registered channels
discord_channel_list() {
    _discord_channels_init || return 1
    local count
    count=$(sqlite3 "$DISCORD_CHANNELS_DB" "SELECT COUNT(*) FROM channels;" 2>/dev/null)
    if [ "${count:-0}" -eq 0 ]; then
        ui_dim "No channels registered"
        ui_dim "Add one: /social discord channels add <name> <channel_id>"
        ui_dim "Or sync from Discord: /social discord channels sync"
        return
    fi
    ui_section "Discord Channels ($count)"
    sqlite3 -separator ' | ' "$DISCORD_CHANNELS_DB" \
        "SELECT '#' || name, channel_id, COALESCE(NULLIF(guild_name,''), '(no guild)') FROM channels ORDER BY guild_name, name;" 2>/dev/null | \
        while IFS= read -r line; do
            printf "  %s\n" "$line"
        done
}

# Sync channels from all connected guilds via the Discord API
discord_channels_sync() {
    local token
    token=$(api_require_key "DISCORD_BOT_TOKEN" "Discord Bot") || return 1

    _discord_channels_init || return 1

    ui_info "Fetching guilds..."
    local guilds
    guilds=$(api_get "https://discord.com/api/v10/users/@me/guilds" \
        -H "Authorization: Bot $token")
    if [ $? -ne 0 ]; then
        ui_err "Failed to fetch guilds"
        return 1
    fi

    local guild_count
    guild_count=$(echo "$guilds" | jq 'length' 2>/dev/null)
    if [ "${guild_count:-0}" -eq 0 ]; then
        ui_warn "Bot is not in any servers"
        return 1
    fi

    local total_added=0

    echo "$guilds" | jq -r '.[]? | "\(.id) \(.name)"' 2>/dev/null | while IFS=' ' read -r gid gname; do
        ui_dim "  Syncing: $gname ($gid)..."
        local channels
        channels=$(api_get "https://discord.com/api/v10/guilds/$gid/channels" \
            -H "Authorization: Bot $token")
        if [ $? -ne 0 ]; then
            ui_warn "  Failed to list channels for $gname"
            continue
        fi

        # Insert text channels (type 0) and announcement channels (type 5)
        echo "$channels" | jq -r '.[]? | select(.type == 0 or .type == 5) | "\(.id) \(.name)"' 2>/dev/null | while IFS=' ' read -r cid cname; do
            sqlite3 "$DISCORD_CHANNELS_DB" \
                "INSERT OR REPLACE INTO channels(name, channel_id, guild_name, guild_id, type)
                 VALUES ('$cname', '$cid', '$gname', '$gid', 'text');" 2>/dev/null
            total_added=$((total_added + 1))
        done
    done

    local final_count
    final_count=$(sqlite3 "$DISCORD_CHANNELS_DB" "SELECT COUNT(*) FROM channels;" 2>/dev/null)
    ui_ok "Channel registry synced — $final_count channels total"
}

# Get the default channel ID (first registered, or from DISCORD_DEFAULT_CHANNEL key)
discord_default_channel() {
    # Check for explicit default
    local explicit
    explicit=$(api_get_key "DISCORD_DEFAULT_CHANNEL" 2>/dev/null)
    if [ -n "$explicit" ]; then
        # Could be a name or an ID
        if [[ "$explicit" =~ ^[0-9]+$ ]]; then
            echo "$explicit"
        else
            discord_channel_resolve "$explicit"
        fi
        return
    fi
    # Fall back to first "general" channel, then any first channel
    _discord_channels_init 2>/dev/null || return 1
    local cid
    cid=$(sqlite3 "$DISCORD_CHANNELS_DB" \
        "SELECT channel_id FROM channels WHERE name = 'general' LIMIT 1;" 2>/dev/null)
    if [ -n "$cid" ]; then
        echo "$cid"
        return
    fi
    sqlite3 "$DISCORD_CHANNELS_DB" \
        "SELECT channel_id FROM channels LIMIT 1;" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
# Telegram — Bot API
# ═══════════════════════════════════════════════════════════════
# Setup: Message @BotFather on Telegram → /newbot → get token
# Keys: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID

_telegram_api() {
    local method="$1"
    shift
    local token
    token=$(api_require_key "TELEGRAM_BOT_TOKEN" "Telegram Bot") || return 1
    api_post "https://api.telegram.org/bot${token}/${method}" "$@"
}

telegram_send() {
    local text="$1"
    local chat_id="${2:-}"
    if [ -z "$chat_id" ]; then
        chat_id=$(api_require_key "TELEGRAM_CHAT_ID" "Telegram") || return 1
    fi
    local token
    token=$(api_get_key "TELEGRAM_BOT_TOKEN") || return 1

    local data
    data=$(jq -n --arg t "$text" --arg c "$chat_id" \
        '{"chat_id": $c, "text": $t, "parse_mode": "Markdown"}')

    local resp
    resp=$(api_post "https://api.telegram.org/bot${token}/sendMessage" "$data")

    if [ $? -eq 0 ]; then
        ui_ok "Sent to Telegram"
        echo "$resp"
    else
        ui_err "Telegram send failed"
        return 1
    fi
}

telegram_get_updates() {
    local count="${1:-10}"
    local token
    token=$(api_require_key "TELEGRAM_BOT_TOKEN" "Telegram Bot") || return 1

    api_get "https://api.telegram.org/bot${token}/getUpdates?limit=$count" | \
        jq -r '.result[]? | "[\(.message.from.username // "unknown")] \(.message.text // "[media]")"' 2>/dev/null
}

telegram_reply() {
    local chat_id="$1"
    local message_id="$2"
    local text="$3"
    local token
    token=$(api_get_key "TELEGRAM_BOT_TOKEN") || return 1

    local data
    data=$(jq -n --arg t "$text" --arg c "$chat_id" --arg m "$message_id" \
        '{"chat_id": $c, "text": $t, "reply_to_message_id": ($m | tonumber), "parse_mode": "Markdown"}')

    api_post "https://api.telegram.org/bot${token}/sendMessage" "$data"
}

telegram_get_me() {
    local token
    token=$(api_require_key "TELEGRAM_BOT_TOKEN" "Telegram Bot") || return 1
    api_get "https://api.telegram.org/bot${token}/getMe" | jq '.' 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
# Unified social dispatcher
# ═══════════════════════════════════════════════════════════════
# Post to one or more platforms at once

social_post() {
    local text="$1"
    shift
    local platforms=("$@")

    if [ ${#platforms[@]} -eq 0 ]; then
        platforms=("all")
    fi

    local results=()

    for platform in "${platforms[@]}"; do
        case "$platform" in
            x|twitter)
                x_post "$text" && results+=("X: ✓") || results+=("X: ✗") ;;
            mastodon|masto)
                mastodon_post "$text" && results+=("Mastodon: ✓") || results+=("Mastodon: ✗") ;;
            bluesky|bsky)
                bluesky_post "$text" && results+=("Bluesky: ✓") || results+=("Bluesky: ✗") ;;
            discord)
                # Try webhook first, fall back to bot API with default channel
                if api_get_key "DISCORD_WEBHOOK_URL" &>/dev/null; then
                    discord_webhook "$text" && results+=("Discord: ✓") || results+=("Discord: ✗")
                elif api_get_key "DISCORD_BOT_TOKEN" &>/dev/null; then
                    local _def_chan
                    _def_chan=$(discord_default_channel)
                    if [ -n "$_def_chan" ]; then
                        discord_send "$_def_chan" "$text" && results+=("Discord: ✓") || results+=("Discord: ✗")
                    else
                        ui_err "Discord bot token configured but no default channel set"
                        ui_dim "Set one: /api keys set DISCORD_DEFAULT_CHANNEL <channel_id_or_name>"
                        ui_dim "Or sync: /social discord channels sync"
                        results+=("Discord: ✗ (no default channel)")
                    fi
                else
                    ui_err "Discord not configured (need DISCORD_WEBHOOK_URL or DISCORD_BOT_TOKEN)"
                    results+=("Discord: ✗")
                fi ;;
            telegram|tg)
                telegram_send "$text" && results+=("Telegram: ✓") || results+=("Telegram: ✗") ;;
            all)
                # Try all configured platforms
                api_get_key "X_BEARER_TOKEN" &>/dev/null && { x_post "$text" && results+=("X: ✓") || results+=("X: ✗"); }
                api_get_key "MASTODON_ACCESS_TOKEN" &>/dev/null && { mastodon_post "$text" && results+=("Mastodon: ✓") || results+=("Mastodon: ✗"); }
                api_get_key "BLUESKY_APP_PASSWORD" &>/dev/null && { bluesky_post "$text" && results+=("Bluesky: ✓") || results+=("Bluesky: ✗"); }
                # Discord: webhook preferred, bot API fallback
                if api_get_key "DISCORD_WEBHOOK_URL" &>/dev/null; then
                    discord_webhook "$text" && results+=("Discord: ✓") || results+=("Discord: ✗")
                elif api_get_key "DISCORD_BOT_TOKEN" &>/dev/null; then
                    local _def_chan
                    _def_chan=$(discord_default_channel)
                    if [ -n "$_def_chan" ]; then
                        discord_send "$_def_chan" "$text" && results+=("Discord: ✓") || results+=("Discord: ✗")
                    else
                        results+=("Discord: ✗ (no default channel)")
                    fi
                fi
                api_get_key "TELEGRAM_BOT_TOKEN" &>/dev/null && { telegram_send "$text" && results+=("Telegram: ✓") || results+=("Telegram: ✗"); }
                ;;
            *)
                ui_warn "Unknown platform: $platform" ;;
        esac
    done

    if [ ${#results[@]} -gt 0 ]; then
        echo ""
        ui_section "Post Results"
        for r in "${results[@]}"; do
            printf "  %s\n" "$r"
        done
    fi
}

# ── Show social status ────────────────────────────────────────
social_status() {
    ui_section "Social Integrations"
    local configured=0

    for platform in X_BEARER_TOKEN MASTODON_ACCESS_TOKEN BLUESKY_APP_PASSWORD DISCORD_BOT_TOKEN DISCORD_WEBHOOK_URL TELEGRAM_BOT_TOKEN; do
        local name
        name=$(echo "$platform" | sed 's/_BEARER_TOKEN//;s/_ACCESS_TOKEN//;s/_APP_PASSWORD//;s/_BOT_TOKEN//;s/_WEBHOOK_URL//')
        if api_get_key "$platform" &>/dev/null; then
            printf "  %b●%b %-15s configured\n" "$C_GREEN" "$C_RESET" "$name"
            configured=$((configured + 1))
        else
            printf "  %b○%b %-15s not configured\n" "$C_DIM" "$C_RESET" "$name"
        fi
    done

    if [ "$configured" -eq 0 ]; then
        echo ""
        ui_dim "  Set keys with: /api keys set KEY_NAME value"
        ui_dim "  Or edit: $GEORGE_KEYS_FILE"
    fi
}
