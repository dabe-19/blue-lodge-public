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

discord_webhook() {
    local message="$1"
    local username="${2:-George}"
    local webhook_url
    webhook_url=$(api_require_key "DISCORD_WEBHOOK_URL" "Discord Webhook") || return 1

    local data
    data=$(jq -n --arg c "$message" --arg u "$username" \
        '{"content": $c, "username": $u}')

    local resp
    resp=$(api_post "$webhook_url" "$data")
    if [ $? -eq 0 ] || [ "$_API_LAST_STATUS" = "204" ]; then
        ui_ok "Sent to Discord"
    else
        ui_err "Discord webhook failed"
        return 1
    fi
}

discord_send() {
    local channel_id="$1"
    local message="$2"
    local token
    token=$(api_require_key "DISCORD_BOT_TOKEN" "Discord Bot") || return 1

    local data
    data=$(jq -n --arg c "$message" '{"content": $c}')

    api_post "https://discord.com/api/v10/channels/$channel_id/messages" "$data" \
        -H "Authorization: Bot $token"
}

discord_read() {
    local channel_id="$1"
    local count="${2:-10}"
    local token
    token=$(api_require_key "DISCORD_BOT_TOKEN" "Discord Bot") || return 1

    api_get "https://discord.com/api/v10/channels/$channel_id/messages?limit=$count" \
        -H "Authorization: Bot $token" | \
        jq -r '.[]? | "[\(.author.username)] \(.content)"' 2>/dev/null
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
                discord_webhook "$text" && results+=("Discord: ✓") || results+=("Discord: ✗") ;;
            telegram|tg)
                telegram_send "$text" && results+=("Telegram: ✓") || results+=("Telegram: ✗") ;;
            all)
                # Try all configured platforms
                api_get_key "X_BEARER_TOKEN" &>/dev/null && { x_post "$text" && results+=("X: ✓") || results+=("X: ✗"); }
                api_get_key "MASTODON_ACCESS_TOKEN" &>/dev/null && { mastodon_post "$text" && results+=("Mastodon: ✓") || results+=("Mastodon: ✗"); }
                api_get_key "BLUESKY_APP_PASSWORD" &>/dev/null && { bluesky_post "$text" && results+=("Bluesky: ✓") || results+=("Bluesky: ✗"); }
                api_get_key "DISCORD_WEBHOOK_URL" &>/dev/null && { discord_webhook "$text" && results+=("Discord: ✓") || results+=("Discord: ✗"); }
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
