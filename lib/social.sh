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
# Keys: MASTODON_ACCESS_TOKEN (legacy single-instance)
# Multi-instance: mastodon_instances.db (instance_url → access_token registry)
# Users can configure multiple Mastodon instances and tokens.

MASTODON_INSTANCES_DB="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}/mastodon_instances.db"

_mastodon_instances_init() {
    if ! command -v sqlite3 &>/dev/null; then
        ui_err "sqlite3 required for Mastodon instance registry"
        return 1
    fi
    mkdir -p "$(dirname "$MASTODON_INSTANCES_DB")"
    sqlite3 "$MASTODON_INSTANCES_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS instances (
    instance_url TEXT NOT NULL UNIQUE COLLATE NOCASE,
    access_token TEXT NOT NULL,
    display_name TEXT DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
SQL
}

# Add a Mastodon instance + token
mastodon_instance_add() {
    local instance_url="$1"
    local access_token="$2"
    local display_name="${3:-}"
    # Normalize: ensure https://
    [[ "$instance_url" != https://* ]] && [[ "$instance_url" != http://* ]] && instance_url="https://$instance_url"
    # Strip trailing slash
    instance_url="${instance_url%/}"
    _mastodon_instances_init || return 1
    sqlite3 "$MASTODON_INSTANCES_DB" \
        "INSERT OR REPLACE INTO instances(instance_url, access_token, display_name)
         VALUES ('$instance_url', '$access_token', '$display_name');"
    ui_ok "Registered Mastodon instance: $instance_url${display_name:+ ($display_name)}"
}

# Remove a Mastodon instance
mastodon_instance_remove() {
    local instance_url="$1"
    [[ "$instance_url" != https://* ]] && [[ "$instance_url" != http://* ]] && instance_url="https://$instance_url"
    instance_url="${instance_url%/}"
    _mastodon_instances_init || return 1
    sqlite3 "$MASTODON_INSTANCES_DB" \
        "DELETE FROM instances WHERE instance_url = '$instance_url' COLLATE NOCASE;"
    ui_ok "Removed Mastodon instance: $instance_url"
}

# List all Mastodon instances
mastodon_instance_list() {
    _mastodon_instances_init || return 1
    local count
    count=$(sqlite3 "$MASTODON_INSTANCES_DB" "SELECT COUNT(*) FROM instances;" 2>/dev/null)
    if [ "${count:-0}" -eq 0 ]; then
        # Check for legacy single-instance config
        if api_get_key "MASTODON_ACCESS_TOKEN" &>/dev/null; then
            local _inst
            _inst=$(_mastodon_base)
            printf "  %b●%b %s (legacy key)\n" "$C_GREEN" "$C_RESET" "$_inst"
        else
            ui_dim "No Mastodon instances registered"
            ui_dim "Add one: /social mastodon instances add <url> <token>"
        fi
        return
    fi
    ui_section "Mastodon Instances ($count)"
    sqlite3 -separator ' | ' "$MASTODON_INSTANCES_DB" \
        "SELECT instance_url, COALESCE(NULLIF(display_name,''), '(unnamed)') FROM instances ORDER BY instance_url;" 2>/dev/null | \
        while IFS= read -r line; do
            printf "  %b●%b %s\n" "$C_GREEN" "$C_RESET" "$line"
        done
}

# Get token for a specific instance (or default)
_mastodon_instance_token() {
    local instance_url="${1:-}"
    # Try instance registry first
    if [ -n "$instance_url" ]; then
        [[ "$instance_url" != https://* ]] && [[ "$instance_url" != http://* ]] && instance_url="https://$instance_url"
        instance_url="${instance_url%/}"
        _mastodon_instances_init 2>/dev/null
        local token
        token=$(sqlite3 "$MASTODON_INSTANCES_DB" \
            "SELECT access_token FROM instances WHERE instance_url = '$instance_url' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
        if [ -n "$token" ]; then
            echo "$token"
            return 0
        fi
    fi
    # Try first registered instance
    _mastodon_instances_init 2>/dev/null
    local first_token
    first_token=$(sqlite3 "$MASTODON_INSTANCES_DB" \
        "SELECT access_token FROM instances LIMIT 1;" 2>/dev/null)
    if [ -n "$first_token" ]; then
        echo "$first_token"
        return 0
    fi
    # Fall back to legacy single key
    api_get_key "MASTODON_ACCESS_TOKEN"
}

# Get base URL for a specific or default instance
_mastodon_instance_url() {
    local instance_url="${1:-}"
    if [ -n "$instance_url" ]; then
        [[ "$instance_url" != https://* ]] && [[ "$instance_url" != http://* ]] && instance_url="https://$instance_url"
        echo "${instance_url%/}"
        return
    fi
    # Try first registered instance
    _mastodon_instances_init 2>/dev/null
    local first_url
    first_url=$(sqlite3 "$MASTODON_INSTANCES_DB" \
        "SELECT instance_url FROM instances LIMIT 1;" 2>/dev/null)
    if [ -n "$first_url" ]; then
        echo "$first_url"
        return
    fi
    # Legacy fallback
    _mastodon_base
}

_mastodon_base() {
    local instance
    instance=$(api_get_key "MASTODON_INSTANCE")
    echo "${instance:-https://mastodon.social}"
}

mastodon_post() {
    local text="$1"
    local visibility="${2:-public}"  # public, unlisted, private, direct
    local instance="${3:-}"          # optional: specific instance URL
    local token
    token=$(_mastodon_instance_token "$instance")
    if [ -z "$token" ]; then
        ui_err "Mastodon: No access token configured"
        ui_dim "Add one: /social mastodon instances add <url> <token>"
        ui_dim "Or set: /api keys set MASTODON_ACCESS_TOKEN <token>"
        return 1
    fi
    local base
    base=$(_mastodon_instance_url "$instance")

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

    # Auto-resolve @mentions in the message to Discord <@user_id> format
    if [[ "$message" == *"@"* ]] && declare -f discord_resolve_mentions &>/dev/null; then
        message=$(discord_resolve_mentions "$message")
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

# ── Discord: User name→ID registry (SQLite) ──────────────────
# Stores username → user_id mappings so George can @mention users
# by name in Discord posts and send DMs.

DISCORD_USERS_DB="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}/discord_users.db"

_discord_users_init() {
    if ! command -v sqlite3 &>/dev/null; then
        ui_err "sqlite3 required for user registry"
        return 1
    fi
    mkdir -p "$(dirname "$DISCORD_USERS_DB")"
    sqlite3 "$DISCORD_USERS_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS users (
    username TEXT NOT NULL COLLATE NOCASE,
    display_name TEXT DEFAULT '',
    user_id TEXT NOT NULL UNIQUE,
    guild_name TEXT DEFAULT '',
    guild_id TEXT DEFAULT '',
    is_bot INTEGER DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username COLLATE NOCASE);
SQL
}

# Resolve a username to a Discord user ID
# Searches: username (exact) → display_name (exact) → username (prefix)
# This allows @Pompler to resolve even when the actual username is pomps5246
# (Pompler is the display_name).
discord_user_resolve() {
    local name="$1"
    # Strip leading @ if present
    name="${name#@}"
    # Strip surrounding quotes
    name=$(echo "$name" | sed 's/^["'\'']*//; s/["'\'']*$//')
    name="${name#@}"  # double-strip in case quotes wrapped the @
    _discord_users_init 2>/dev/null || return 1

    # 1. Exact username match (primary)
    local uid
    uid=$(sqlite3 "$DISCORD_USERS_DB" \
        "SELECT user_id FROM users WHERE username = '$name' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
    if [ -n "$uid" ]; then echo "$uid"; return 0; fi

    # 2. Exact display_name match (allows @Pompler → pomps5246's user_id)
    uid=$(sqlite3 "$DISCORD_USERS_DB" \
        "SELECT user_id FROM users WHERE display_name = '$name' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
    if [ -n "$uid" ]; then echo "$uid"; return 0; fi

    # 3. Prefix match on username (allows @pomps → pomps5246)
    uid=$(sqlite3 "$DISCORD_USERS_DB" \
        "SELECT user_id FROM users WHERE username LIKE '${name}%' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
    if [ -n "$uid" ]; then echo "$uid"; return 0; fi

    # 4. Prefix match on display_name
    uid=$(sqlite3 "$DISCORD_USERS_DB" \
        "SELECT user_id FROM users WHERE display_name LIKE '${name}%' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
    [ -n "$uid" ] && echo "$uid"
}

# Add a user mapping manually
discord_user_add() {
    local username="$1"
    local user_id="$2"
    local display_name="${3:-}"
    local guild_name="${4:-}"
    local guild_id="${5:-}"
    username="${username#@}"
    _discord_users_init || return 1
    sqlite3 "$DISCORD_USERS_DB" \
        "INSERT OR REPLACE INTO users(username, user_id, display_name, guild_name, guild_id)
         VALUES ('$username', '$user_id', '$display_name', '$guild_name', '$guild_id');"
    ui_ok "Registered user @${username} → ${user_id}${display_name:+ (${display_name})}"
}

# Remove a user mapping
discord_user_remove() {
    local username="$1"
    username="${username#@}"
    _discord_users_init || return 1
    sqlite3 "$DISCORD_USERS_DB" \
        "DELETE FROM users WHERE username = '$username' COLLATE NOCASE;"
    ui_ok "Removed user @${username}"
}

# List all registered users
discord_user_list() {
    _discord_users_init || return 1
    local count
    count=$(sqlite3 "$DISCORD_USERS_DB" "SELECT COUNT(*) FROM users;" 2>/dev/null)
    if [ "${count:-0}" -eq 0 ]; then
        ui_dim "No users registered"
        ui_dim "Sync from Discord: /social discord users sync"
        ui_dim "Or add manually: /social discord users add <username> <user_id>"
        return
    fi
    ui_section "Discord Users ($count)"
    sqlite3 -separator ' | ' "$DISCORD_USERS_DB" \
        "SELECT '@' || username, user_id, COALESCE(NULLIF(display_name,''), '(no display name)'), COALESCE(NULLIF(guild_name,''), '(no guild)') FROM users WHERE is_bot = 0 ORDER BY guild_name, username;" 2>/dev/null | \
        while IFS= read -r line; do
            printf "  %s\n" "$line"
        done
}

# Sync users from all connected guilds via the Discord API
discord_users_sync() {
    local token
    token=$(api_require_key "DISCORD_BOT_TOKEN" "Discord Bot") || return 1

    _discord_users_init || return 1

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
        ui_dim "  Syncing members: $gname ($gid)..."
        local members=""
        local after=""
        local batch_size=1000

        # Paginate through guild members (max 1000 per request)
        while true; do
            local url="https://discord.com/api/v10/guilds/$gid/members?limit=$batch_size"
            [ -n "$after" ] && url="${url}&after=${after}"

            local batch
            batch=$(api_get "$url" -H "Authorization: Bot $token")
            if [ $? -ne 0 ]; then
                ui_warn "  Failed to list members for $gname (may need SERVER MEMBERS intent)"
                break
            fi

            local batch_count
            batch_count=$(echo "$batch" | jq 'length' 2>/dev/null)
            [ "${batch_count:-0}" -eq 0 ] && break

            # Insert each member
            echo "$batch" | jq -r '.[]? | "\(.user.id) \(.user.username) \(.user.global_name // "") \(.user.bot // false)"' 2>/dev/null | while IFS=' ' read -r uid uname dname is_bot; do
                local bot_flag=0
                [ "$is_bot" = "true" ] && bot_flag=1
                sqlite3 "$DISCORD_USERS_DB" \
                    "INSERT OR REPLACE INTO users(username, user_id, display_name, guild_name, guild_id, is_bot)
                     VALUES ('$uname', '$uid', '$dname', '$gname', '$gid', $bot_flag);" 2>/dev/null
                total_added=$((total_added + 1))
            done

            # Check if there are more pages
            [ "$batch_count" -lt "$batch_size" ] && break
            after=$(echo "$batch" | jq -r '.[-1].user.id' 2>/dev/null)
            [ -z "$after" ] && break
        done
    done

    local final_count
    final_count=$(sqlite3 "$DISCORD_USERS_DB" "SELECT COUNT(*) FROM users WHERE is_bot = 0;" 2>/dev/null)
    ui_ok "User registry synced — $final_count users total (excluding bots)"
}

# ── Discord: @mention resolution ──────────────────────────────
# Replaces @username patterns in text with Discord <@user_id>
# format for proper @ mentions in Discord messages.
discord_resolve_mentions() {
    local text="$1"
    _discord_users_init 2>/dev/null || { echo "$text"; return; }

    # Find all @word patterns and try to resolve each
    local result="$text"
    local mentions
    mentions=$(echo "$text" | grep -oP '@[a-zA-Z0-9_.-]+' | sort -u)

    while IFS= read -r mention; do
        [ -z "$mention" ] && continue
        local username="${mention#@}"
        local user_id
        user_id=$(discord_user_resolve "$username")
        if [ -n "$user_id" ]; then
            # Replace @username with <@user_id> for Discord mention format
            result=$(echo "$result" | sed "s|@${username}|<@${user_id}>|g")
        fi
    done <<< "$mentions"

    echo "$result"
}

# ── Discord: DM (Direct Message) ─────────────────────────────
# Creates a DM channel with a user and sends a message.
# Requires the bot to share a server with the user.
discord_dm() {
    local user_id="$1"
    local message="$2"

    # Resolve username to ID if not numeric
    if ! [[ "$user_id" =~ ^[0-9]+$ ]]; then
        local resolved
        resolved=$(discord_user_resolve "$user_id")
        if [ -z "$resolved" ]; then
            ui_err "Unknown user: $user_id"
            ui_dim "Sync users: /social discord users sync"
            return 1
        fi
        user_id="$resolved"
    fi

    local token
    token=$(api_require_key "DISCORD_BOT_TOKEN" "Discord Bot") || return 1

    # Step 1: Create DM channel
    local dm_data
    dm_data=$(jq -n --arg r "$user_id" '{"recipient_id": $r}')

    local dm_resp
    dm_resp=$(api_post "https://discord.com/api/v10/users/@me/channels" "$dm_data" \
        -H "Authorization: Bot $token")

    if [ $? -ne 0 ]; then
        local err_msg
        err_msg=$(api_json_get "${_API_LAST_BODY:-}" '.message // "unknown error"')
        ui_err "Failed to create DM channel: $err_msg"
        ui_dim "The bot may lack permission to DM this user"
        return 1
    fi

    local dm_channel_id
    dm_channel_id=$(api_json_get "$dm_resp" '.id')
    if [ -z "$dm_channel_id" ]; then
        ui_err "Failed to get DM channel ID"
        return 1
    fi

    # Step 2: Send message to the DM channel
    discord_send "$dm_channel_id" "$message"
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
# Post to one or all platforms.
#
# Canonical form: social_post <platform> <channel_or_empty> <text>
# Toggle: SOCIAL_UNIFIED_POST=1 → /social post <text> broadcasts to ALL
#         SOCIAL_UNIFIED_POST=0 (default) → requires explicit platform

SOCIAL_UNIFIED_POST="${SOCIAL_UNIFIED_POST:-0}"

social_post() {
    local text="$1"
    shift
    local platforms=("$@")

    if [ ${#platforms[@]} -eq 0 ]; then
        if [ "${SOCIAL_UNIFIED_POST:-0}" -eq 1 ]; then
            platforms=("all")
        else
            ui_err "No platform specified. Use: /social post <platform> [channel] <text>"
            ui_dim "Or enable unified posting: /api keys set SOCIAL_UNIFIED_POST 1"
            return 1
        fi
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
                local _masto_token
                _masto_token=$(_mastodon_instance_token "" 2>/dev/null)
                [ -n "$_masto_token" ] && { mastodon_post "$text" && results+=("Mastodon: ✓") || results+=("Mastodon: ✗"); }
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

    # X / Twitter
    if api_get_key "X_BEARER_TOKEN" &>/dev/null; then
        printf "  %b●%b %-15s configured\n" "$C_GREEN" "$C_RESET" "X"
        configured=$((configured + 1))
    else
        printf "  %b○%b %-15s not configured\n" "$C_DIM" "$C_RESET" "X"
    fi

    # Mastodon — check multi-instance registry directly via DB count
    local _masto_instances=0
    if command -v sqlite3 &>/dev/null && [ -f "${MASTODON_INSTANCES_DB:-}" ]; then
        _masto_instances=$(sqlite3 "$MASTODON_INSTANCES_DB" "SELECT COUNT(*) FROM instances;" 2>/dev/null || echo 0)
    fi
    if [ "${_masto_instances:-0}" -gt 0 ]; then
        printf "  %b●%b %-15s configured (%s instance%s)\n" "$C_GREEN" "$C_RESET" "MASTODON" "$_masto_instances" "$([ "$_masto_instances" -ne 1 ] && echo 's')"
        configured=$((configured + 1))
    elif api_get_key "MASTODON_ACCESS_TOKEN" &>/dev/null; then
        printf "  %b●%b %-15s configured (legacy key)\n" "$C_GREEN" "$C_RESET" "MASTODON"
        configured=$((configured + 1))
    else
        printf "  %b○%b %-15s not configured\n" "$C_DIM" "$C_RESET" "MASTODON"
    fi

    # Bluesky
    if api_get_key "BLUESKY_APP_PASSWORD" &>/dev/null; then
        printf "  %b●%b %-15s configured\n" "$C_GREEN" "$C_RESET" "BLUESKY"
        configured=$((configured + 1))
    else
        printf "  %b○%b %-15s not configured\n" "$C_DIM" "$C_RESET" "BLUESKY"
    fi

    # Discord — query DB directly to avoid counting help text
    if api_get_key "DISCORD_BOT_TOKEN" &>/dev/null; then
        local _user_count=0
        if command -v sqlite3 &>/dev/null && [ -f "${DISCORD_USERS_DB:-}" ]; then
            _user_count=$(sqlite3 "$DISCORD_USERS_DB" "SELECT COUNT(*) FROM users;" 2>/dev/null || echo 0)
        fi
        printf "  %b●%b %-15s configured (bot" "$C_GREEN" "$C_RESET" "DISCORD"
        [ "${_user_count:-0}" -gt 0 ] && printf ", %s users" "$_user_count"
        printf ")\n"
        configured=$((configured + 1))
    elif api_get_key "DISCORD_WEBHOOK_URL" &>/dev/null; then
        printf "  %b●%b %-15s configured (webhook)\n" "$C_GREEN" "$C_RESET" "DISCORD"
        configured=$((configured + 1))
    else
        printf "  %b○%b %-15s not configured\n" "$C_DIM" "$C_RESET" "DISCORD"
    fi

    # Telegram
    if api_get_key "TELEGRAM_BOT_TOKEN" &>/dev/null; then
        printf "  %b●%b %-15s configured\n" "$C_GREEN" "$C_RESET" "TELEGRAM"
        configured=$((configured + 1))
    else
        printf "  %b○%b %-15s not configured\n" "$C_DIM" "$C_RESET" "TELEGRAM"
    fi

    # Unified post toggle
    echo ""
    if [ "${SOCIAL_UNIFIED_POST:-0}" -eq 1 ]; then
        ui_dim "  Unified posting: ON (posts broadcast to all platforms)"
    else
        ui_dim "  Unified posting: OFF (posts require explicit platform)"
    fi

    if [ "$configured" -eq 0 ]; then
        echo ""
        ui_dim "  Set keys with: /api keys set KEY_NAME value"
        ui_dim "  Or edit: $GEORGE_KEYS_FILE"
    fi
}
