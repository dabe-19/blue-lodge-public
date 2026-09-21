#!/bin/bash
# ── George: Social Media Integration ───────────────────────────
# Post, read, and interact on X, Mastodon, Bluesky, Discord,
# and Telegram — all via pure curl + their REST APIs.

[ -n "${_LIB_SOCIAL_LOADED:-}" ] && return 0; _LIB_SOCIAL_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/api.sh"
source "$LODGE_DIR/lib/pgp.sh"
[ -f "$LODGE_DIR/lib/social_blog.sh" ] && source "$LODGE_DIR/lib/social_blog.sh"

# ═══════════════════════════════════════════════════════════════
# X (Twitter) — v2 API (OAuth 1.0a User Context & Bearer)
# ═══════════════════════════════════════════════════════════════
# Setup: Developer Portal (developer.x.com)
# Posting as User requires User Context:
#   X_CONSUMER_KEY (API Key), X_CONSUMER_SECRET (API Secret)
#   X_ACCESS_TOKEN, X_ACCESS_TOKEN_SECRET
# Or OAuth 2.0 User Context / Bearer:
#   X_BEARER_TOKEN

_x_percent_encode() {
    local string="$1"
    if command -v python3 &>/dev/null; then
        python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''), end='')" "$string"
    elif command -v jq &>/dev/null; then
        printf '%s' "$string" | jq -sRr @uri
    else
        local strlen=${#string}
        local encoded=""
        local pos c o
        for (( pos=0 ; pos<strlen ; pos++ )); do
            c=${string:$pos:1}
            case "$c" in
                [-_.~a-zA-Z0-9] ) o="${c}" ;;
                * ) printf -v o '%%%02X' "'$c"
            esac
            encoded+="${o}"
        done
        printf '%s' "${encoded}"
    fi
}

_x_oauth1_header() {
    local method="$1"
    local url="$2"
    local consumer_key="$3"
    local consumer_secret="$4"
    local token="$5"
    local token_secret="$6"

    local nonce
    nonce=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    local timestamp
    timestamp=$(date +%s)

    local enc_ckey enc_nonce enc_token
    enc_ckey=$(_x_percent_encode "$consumer_key")
    enc_nonce=$(_x_percent_encode "$nonce")
    enc_token=$(_x_percent_encode "$token")

    local params="oauth_consumer_key=${enc_ckey}&oauth_nonce=${enc_nonce}&oauth_signature_method=HMAC-SHA1&oauth_timestamp=${timestamp}&oauth_token=${enc_token}&oauth_version=1.0"

    local encoded_method encoded_url encoded_params
    encoded_method=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')
    encoded_url=$(_x_percent_encode "$url")
    encoded_params=$(_x_percent_encode "$params")

    local base_string="${encoded_method}&${encoded_url}&${encoded_params}"
    local signing_key="$(_x_percent_encode "$consumer_secret")&$(_x_percent_encode "$token_secret")"

    local signature
    signature=$(printf '%s' "$base_string" | openssl dgst -sha1 -hmac "$signing_key" -binary | base64 | tr -d '\n')
    local encoded_sig
    encoded_sig=$(_x_percent_encode "$signature")

    echo "Authorization: OAuth oauth_consumer_key=\"$consumer_key\", oauth_nonce=\"$nonce\", oauth_signature=\"$encoded_sig\", oauth_signature_method=\"HMAC-SHA1\", oauth_timestamp=\"$timestamp\", oauth_token=\"$token\", oauth_version=\"1.0\""
}

_x_auth_header() {
    local method="${1:-POST}"
    local url="${2:-https://api.x.com/2/tweets}"

    local ckey csec atok atoksec bearer
    ckey=$(api_get_key "X_CONSUMER_KEY" 2>/dev/null || api_get_key "X_API_KEY" 2>/dev/null || echo "")
    csec=$(api_get_key "X_CONSUMER_SECRET" 2>/dev/null || api_get_key "X_API_SECRET" 2>/dev/null || echo "")
    atok=$(api_get_key "X_ACCESS_TOKEN" 2>/dev/null || echo "")
    atoksec=$(api_get_key "X_ACCESS_TOKEN_SECRET" 2>/dev/null || echo "")
    bearer=$(api_get_key "X_BEARER_TOKEN" 2>/dev/null || echo "")

    if [ -n "$ckey" ] && [ -n "$csec" ] && [ -n "$atok" ] && [ -n "$atoksec" ]; then
        _x_oauth1_header "$method" "$url" "$ckey" "$csec" "$atok" "$atoksec"
        return 0
    elif [ -n "$bearer" ]; then
        echo "Authorization: Bearer $bearer"
        return 0
    fi
    return 1
}

_x_cookie_auth_available() {
    local auth_token ct0
    auth_token=$(api_get_key "X_AUTH_TOKEN" 2>/dev/null || echo "")
    ct0=$(api_get_key "X_CT0" 2>/dev/null || echo "")
    [ -n "$auth_token" ] && [ -n "$ct0" ]
}

_x_cookie_post() {
    local text="$1"
    local reply_to_id="${2:-}"

    local auth_token ct0
    auth_token=$(api_get_key "X_AUTH_TOKEN" 2>/dev/null || echo "")
    ct0=$(api_get_key "X_CT0" 2>/dev/null || echo "")

    if [ -z "$auth_token" ] || [ -z "$ct0" ]; then
        return 1
    fi

    local resp
    resp=$(python3 "$LODGE_DIR/lib/social_cookie.py" post "$auth_token" "$ct0" "$text" "$reply_to_id" 2>/dev/null)
    local status
    status=$(echo "$resp" | jq -r '.status // empty' 2>/dev/null)
    if [ "$status" = "ok" ]; then
        local tweet_id
        tweet_id=$(echo "$resp" | jq -r '.tweet_id // empty' 2>/dev/null)
        ui_ok "Posted to X via Web Session (ID: ${tweet_id:-posted})" >&2
        echo "$resp"
        return 0
    else
        local detail
        detail=$(echo "$resp" | jq -r '.detail // "unknown error"' 2>/dev/null)
        ui_err "X Web Session post failed: $detail" >&2
        return 1
    fi
}

x_post() {
    local text="$1"
    # Auto-expand readable file references in text
    if [ "${AGENT_FILE_EXPAND:-1}" -eq 1 ] && declare -f tools_expand_file_refs &>/dev/null; then
        text=$(tools_expand_file_refs "$text")
    fi
    # Expand LLM escape sequences (literal \n → real newlines)
    text=$(ui_expand_escapes "$text")

    # Sign with George GPG key if enabled (cryptographic provenance)
    if [ "${SOCIAL_GPG_SIGN:-1}" -eq 1 ]; then
        if [ -f "$LODGE_DIR/lib/pgp.sh" ]; then
            source "$LODGE_DIR/lib/pgp.sh"
            if declare -f pgp_sign_social &>/dev/null; then
                text=$(pgp_sign_social "$text")
            fi
        fi
    fi

    # 1. Prefer cookie session if available and not forced to API
    if _x_cookie_auth_available && [ "${SOCIAL_PREFER_API:-0}" -ne 1 ]; then
        if _x_cookie_post "$text"; then
            return 0
        fi
    fi

    # MCP-first: route through george-x x_post tool
    if declare -f mcp_enabled &>/dev/null && mcp_enabled; then
        local _mcp_result
        _mcp_result=$(mcp_x_post "$text" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$_mcp_result" ]; then
            echo "$_mcp_result"
            return 0
        fi
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
            ui_dim "  [debug] x_post: MCP failed — falling through to direct"
    fi

    local auth_header
    auth_header=$(_x_auth_header "POST" "https://api.x.com/2/tweets")
    if [ -z "$auth_header" ]; then
        ui_err "No X credentials configured (need OAuth 1.0a User keys, Session Cookies, or Bearer Token)"
        ui_dim "To post via Web Session ($0 extra): /secret set X_AUTH_TOKEN <token> & /secret set X_CT0 <ct0>"
        ui_dim "To post via API:                   /secret set X_ACCESS_TOKEN <token>"
        ui_dim "Or validate existing:              /social x validate"
        return 1
    fi

    local data
    data=$(jq -n --arg t "$text" '{"text": $t}')

    local resp
    resp=$(api_post "https://api.x.com/2/tweets" "$data" -H "$auth_header")
    local status=$?

    if [ $status -eq 0 ]; then
        local tweet_id
        tweet_id=$(api_json_get "$resp" '.data.id')
        ui_ok "Posted to X (ID: $tweet_id)" >&2
        echo "$resp"
    else
        local err_msg
        err_msg=$(api_json_get "$resp" '.detail // .title // "unknown error"')
        ui_err "X post failed: $err_msg" >&2
        return 1
    fi
}

x_timeline() {
    local count="${1:-10}"

    # MCP-first: route through george-x x_timeline tool
    if declare -f mcp_enabled &>/dev/null && mcp_enabled; then
        local _mcp_result
        _mcp_result=$(mcp_x_timeline "$count" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$_mcp_result" ]; then
            echo "$_mcp_result"
            return 0
        fi
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
            ui_dim "  [debug] x_timeline: MCP failed — falling through to direct"
    fi

    local auth_header
    auth_header=$(_x_auth_header "GET" "https://api.x.com/2/tweets/search/recent")
    if [ -z "$auth_header" ]; then
        ui_err "No X credentials configured"
        return 1
    fi

    local resp
    resp=$(api_get "https://api.x.com/2/tweets/search/recent?max_results=$count&query=from:me" \
        -H "$auth_header")

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

    if [ "${SOCIAL_GPG_SIGN:-1}" -eq 1 ]; then
        if [ -f "$LODGE_DIR/lib/pgp.sh" ]; then
            source "$LODGE_DIR/lib/pgp.sh"
            if declare -f pgp_sign_social &>/dev/null; then
                text=$(pgp_sign_social "$text")
            fi
        fi
    fi

    # 1. Prefer cookie session if available
    if _x_cookie_auth_available && [ "${SOCIAL_PREFER_API:-0}" -ne 1 ]; then
        if _x_cookie_post "$text" "$tweet_id"; then
            return 0
        fi
    fi

    # MCP-first: route through george-x x_reply tool
    if declare -f mcp_enabled &>/dev/null && mcp_enabled; then
        local _mcp_result
        _mcp_result=$(mcp_x_reply "$tweet_id" "$text" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$_mcp_result" ]; then
            echo "$_mcp_result"
            return 0
        fi
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
            ui_dim "  [debug] x_reply: MCP failed — falling through to direct"
    fi

    local auth_header
    auth_header=$(_x_auth_header "POST" "https://api.x.com/2/tweets")
    if [ -z "$auth_header" ]; then
        ui_err "No X credentials configured"
        return 1
    fi

    local data
    data=$(jq -n --arg t "$text" --arg id "$tweet_id" \
        '{"text": $t, "reply": {"in_reply_to_tweet_id": $id}}')

    local resp
    resp=$(api_post "https://api.x.com/2/tweets" "$data" -H "$auth_header")
    local status=$?
    if [ $status -eq 0 ]; then
        local reply_id
        reply_id=$(echo "$resp" | jq -r '.data.id // .id // empty' 2>/dev/null)
        ui_ok "Replied to X (ID: ${reply_id:-posted})" >&2
        echo "$resp"
        return 0
    else
        local err_msg
        err_msg=$(echo "$resp" | jq -r '.detail // .title // "unknown error"' 2>/dev/null)
        ui_err "X reply failed: $err_msg" >&2
        return 1
    fi
}

x_thread() {
    local full_text="$1"
    local delay="${2:-2}"

    if [ -z "$full_text" ]; then
        ui_err "Usage: x_thread <text>"
        return 1
    fi

    # Auto-expand file references
    if [ "${AGENT_FILE_EXPAND:-1}" -eq 1 ] && declare -f tools_expand_file_refs &>/dev/null; then
        full_text=$(tools_expand_file_refs "$full_text")
    fi
    full_text=$(ui_expand_escapes "$full_text")

    # Split text into chunks (~240 chars each to leave room for [N/M] and signatures)
    # Using python to split nicely at paragraph or sentence boundaries
    local chunks_json
    chunks_json=$(python3 -c '
import sys, re

text = sys.argv[1]
max_len = 220
paragraphs = [p.strip() for p in text.split("\n\n") if p.strip()]

chunks = []
current = ""
for p in paragraphs:
    if len(current) + len(p) + 2 <= max_len:
        current = (current + "\n\n" + p).strip()
    else:
        if current:
            chunks.append(current)
        if len(p) <= max_len:
            current = p
        else:
            # Split long paragraph by sentences
            sentences = re.split(r"(?<=[.?!])\s+", p)
            s_curr = ""
            for s in sentences:
                if len(s_curr) + len(s) + 1 <= max_len:
                    s_curr = (s_curr + " " + s).strip()
                else:
                    if s_curr:
                        chunks.append(s_curr)
                    s_curr = s
            current = s_curr
if current:
    chunks.append(current)

import json
print(json.dumps(chunks))
' "$full_text" 2>/dev/null)

    local count
    count=$(echo "$chunks_json" | jq '. | length' 2>/dev/null)
    if [ -z "$count" ] || [ "$count" -le 1 ]; then
        # Post single tweet
        x_post "$full_text"
        return $?
    fi

    ui_info "Publishing X thread (${count} tweets)..."
    local prev_id=""
    local root_id=""
    local idx=0

    while [ "$idx" -lt "$count" ]; do
        local chunk
        chunk=$(echo "$chunks_json" | jq -r ".[$idx]")
        local num=$((idx + 1))
        # Strip existing [X/Y] prefix if present to avoid doubling
        chunk=$(echo "$chunk" | sed -E 's/^\[[0-9]+\/[0-9]+\][[:space:]]*//')
        local post_content="[$num/$count] $chunk"

        local resp
        if [ -z "$prev_id" ]; then
            resp=$(x_post "$post_content")
        else
            resp=$(x_reply "$prev_id" "$post_content")
        fi

        prev_id=$(echo "$resp" | jq -r '.data.id // .tweet_id // .id // empty' 2>/dev/null)
        if [ -z "$prev_id" ]; then
            prev_id=$(echo "$resp" | grep -oE '"id"\s*:\s*"[0-9]+"' | head -n 1 | grep -oE '[0-9]+' || echo "")
        fi
        if [ -z "$prev_id" ]; then
            ui_err "Thread failed at tweet $num/$count (could not extract tweet ID from response)"
            return 1
        fi
        [ -z "$root_id" ] && root_id="$prev_id"
        ui_info "  Part $num/$count: https://x.com/i/web/status/$prev_id"

        idx=$((idx + 1))
        [ "$idx" -lt "$count" ] && sleep "$delay"
    done

    ui_ok "Thread published successfully ($count tweets, root ID: ${root_id:-$prev_id})"
    return 0
}

x_search() {
    local query="$1"
    local count="${2:-10}"

    # MCP-first: route through george-x x_search tool
    if declare -f mcp_enabled &>/dev/null && mcp_enabled; then
        local _mcp_result
        _mcp_result=$(mcp_x_search "$query" "$count" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$_mcp_result" ]; then
            echo "$_mcp_result"
            return 0
        fi
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
            ui_dim "  [debug] x_search: MCP failed — falling through to direct"
    fi

    local auth_header
    auth_header=$(_x_auth_header "GET" "https://api.x.com/2/tweets/search/recent")
    if [ -z "$auth_header" ]; then
        ui_err "No X credentials configured"
        return 1
    fi

    local encoded_query
    encoded_query=$(printf '%s' "$query" | jq -sRr @uri)

    api_get "https://api.x.com/2/tweets/search/recent?max_results=$count&query=$encoded_query" \
        -H "$auth_header" | \
        jq -r '.data[]? | "[\(.id)] \(.text)"' 2>/dev/null
}

x_delete() {
    local tweet_id="$1"

    # MCP-first: route through george-x x_delete tool
    if declare -f mcp_enabled &>/dev/null && mcp_enabled; then
        local _mcp_result
        _mcp_result=$(mcp_x_delete "$tweet_id" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$_mcp_result" ]; then
            echo "$_mcp_result"
            return 0
        fi
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
            ui_dim "  [debug] x_delete: MCP failed — falling through to direct"
    fi

    local auth_header
    auth_header=$(_x_auth_header "DELETE" "https://api.x.com/2/tweets/$tweet_id")
    if [ -z "$auth_header" ]; then
        ui_err "No X credentials configured"
        return 1
    fi

    api_delete "https://api.x.com/2/tweets/$tweet_id" \
        -H "$auth_header"
}

# ── X: Validate Credentials & Diagnostics ─────────────────────
x_validate() {
    ui_section "X (Twitter) Credentials Validation"

    local has_creds=0
    local consumer_key consumer_secret access_token access_token_secret bearer_token
    consumer_key=$(api_get_key "X_CONSUMER_KEY" 2>/dev/null || api_get_key "X_API_KEY" 2>/dev/null || echo "")
    consumer_secret=$(api_get_key "X_CONSUMER_SECRET" 2>/dev/null || api_get_key "X_API_SECRET" 2>/dev/null || echo "")
    access_token=$(api_get_key "X_ACCESS_TOKEN" 2>/dev/null || echo "")
    access_token_secret=$(api_get_key "X_ACCESS_TOKEN_SECRET" 2>/dev/null || echo "")
    bearer_token=$(api_get_key "X_BEARER_TOKEN" 2>/dev/null || echo "")

    # ── Check 0: Browser Session / Cookie Auth ($0 Extra, X Premium) ──
    local cookie_auth_token cookie_ct0
    cookie_auth_token=$(api_get_key "X_AUTH_TOKEN" 2>/dev/null || echo "")
    cookie_ct0=$(api_get_key "X_CT0" 2>/dev/null || echo "")
    if [ -n "$cookie_auth_token" ] && [ -n "$cookie_ct0" ]; then
        has_creds=1
        ui_step "Testing X Web Session (Cookie Auth)..."
        local c_resp
        c_resp=$(python3 "$LODGE_DIR/lib/social_cookie.py" verify "$cookie_auth_token" "$cookie_ct0" 2>/dev/null)
        local c_status c_uname c_name c_blue
        c_status=$(echo "$c_resp" | jq -r '.status // empty' 2>/dev/null)
        c_uname=$(echo "$c_resp" | jq -r '.screen_name // empty' 2>/dev/null)
        c_name=$(echo "$c_resp" | jq -r '.name // empty' 2>/dev/null)
        c_blue=$(echo "$c_resp" | jq -r '.is_blue_verified // false' 2>/dev/null)

        if [ "$c_status" = "ok" ] && [ -n "$c_uname" ]; then
            ui_ok "X Web Session VALID: Logged in as @${c_uname} (${c_name})"
            if [ "$c_blue" = "true" ]; then
                ui_info "X Premium Verified: 25,000-char posts & algorithmic privileges active!"
            else
                ui_info "Direct Web Session active: Posting enabled with $0 API fees."
            fi
            return 0
        else
            local c_err
            c_err=$(echo "$c_resp" | jq -r '.detail // "Session expired or rejected"' 2>/dev/null)
            ui_warn "X Web Session check failed: $c_err"
        fi
    fi

    # ── Check 1: OAuth 1.0a User Context (Direct posting) ──
    if [ -n "$consumer_key" ] && [ -n "$consumer_secret" ] && [ -n "$access_token" ] && [ -n "$access_token_secret" ]; then
        has_creds=1
        ui_step "Testing OAuth 1.0a User Context credentials..."
        local auth_hdr
        auth_hdr=$(_x_oauth1_header "GET" "https://api.x.com/2/users/me" "$consumer_key" "$consumer_secret" "$access_token" "$access_token_secret")
        local user_resp
        user_resp=$(curl -s "https://api.x.com/2/users/me" -H "$auth_hdr" 2>/dev/null)
        local uname uid
        uname=$(echo "$user_resp" | jq -r '.data.username // empty' 2>/dev/null)
        uid=$(echo "$user_resp" | jq -r '.data.id // empty' 2>/dev/null)

        if [ -n "$uname" ]; then
            ui_ok "OAuth 1.0a User Context VALID: Authenticated as @${uname} (ID: ${uid})"
            ui_info "Write permissions active: George can post tweets as @${uname}!"
            return 0
        else
            local err_detail
            err_detail=$(echo "$user_resp" | jq -r '.detail // .title // "Authentication failed"' 2>/dev/null)
            ui_warn "OAuth 1.0a check failed: $err_detail"
        fi
    fi

    # ── Check 2: Bearer Token ──
    if [ -n "$bearer_token" ]; then
        has_creds=1
        ui_step "Testing X Bearer Token..."

        # Test A: User Context
        local user_resp
        user_resp=$(curl -s "https://api.x.com/2/users/me" -H "Authorization: Bearer $bearer_token" 2>/dev/null)
        local uname uid
        uname=$(echo "$user_resp" | jq -r '.data.username // empty' 2>/dev/null)
        uid=$(echo "$user_resp" | jq -r '.data.id // empty' 2>/dev/null)

        if [ -n "$uname" ]; then
            ui_ok "Bearer Token VALID (User Context): Authenticated as @${uname} (ID: ${uid})"
            ui_info "Write permissions active: George can post tweets as @${uname}!"
            return 0
        fi

        local err_type err_title err_detail
        err_type=$(echo "$user_resp" | jq -r '.type // empty' 2>/dev/null)
        err_title=$(echo "$user_resp" | jq -r '.title // empty' 2>/dev/null)
        err_detail=$(echo "$user_resp" | jq -r '.detail // empty' 2>/dev/null)

        # Test B: App-Only reading
        local app_resp
        app_resp=$(curl -s "https://api.x.com/2/tweets/search/recent?query=from:X&max_results=10" -H "Authorization: Bearer $bearer_token" 2>/dev/null)
        local sample_id app_reason app_detail
        sample_id=$(echo "$app_resp" | jq -r '.data[0].id // empty' 2>/dev/null)
        app_reason=$(echo "$app_resp" | jq -r '.reason // empty' 2>/dev/null)
        app_detail=$(echo "$app_resp" | jq -r '.detail // empty' 2>/dev/null)

        if [ -n "$sample_id" ]; then
            ui_ok "Bearer Token VALID (App-Only Context) — Connected to X API v2 (Read/Search)."
            ui_warn "This token is App-Only. Posting tweets requires User Context (OAuth 1.0a or OAuth 2.0 User Token)."
            ui_dim "To enable posting as your account, configure User Context keys:"
            ui_dim "  /secret set X_CONSUMER_KEY <API Key>"
            ui_dim "  /secret set X_CONSUMER_SECRET <API Key Secret>"
            ui_dim "  /secret set X_ACCESS_TOKEN <Access Token>"
            ui_dim "  /secret set X_ACCESS_TOKEN_SECRET <Access Token Secret>"
            return 0
        elif [ "$app_reason" = "client-not-enrolled" ]; then
            ui_err "Bearer Token REJECTED: Developer App is not attached to a Project."
            ui_dim "X API v2 requires your App to be inside a Project in the Developer Portal:"
            ui_dim "  1. Visit https://developer.x.com"
            ui_dim "  2. Go to Projects & Apps -> Add your App to a Project (or create one)."
            ui_dim "  3. Re-validate: /social x validate"
            return 1
        elif [ -n "$err_detail" ]; then
            ui_err "Bearer Token check returned: $err_title ($err_detail)"
            return 1
        else
            ui_err "Bearer Token validation failed: $(echo "$app_resp" | jq -r '.detail // "unknown error"')"
            return 1
        fi
    fi

    if [ "$has_creds" -eq 0 ]; then
        ui_err "No X (Twitter) credentials found in vault or keys.conf."
        ui_dim "To post as your account, set your OAuth 1.0a User credentials from developer.x.com:"
        ui_dim "  /secret set X_CONSUMER_KEY <API Key>"
        ui_dim "  /secret set X_CONSUMER_SECRET <API Key Secret>"
        ui_dim "  /secret set X_ACCESS_TOKEN <Access Token>"
        ui_dim "  /secret set X_ACCESS_TOKEN_SECRET <Access Token Secret>"
        ui_dim "Or set a Bearer Token for reading: /secret set X_BEARER_TOKEN <token>"
        return 1
    fi
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
         VALUES ('${instance_url//\'/\'\'}', '${access_token//\'/\'\'}', '${display_name//\'/\'\'}');"
    ui_ok "Registered Mastodon instance: $instance_url${display_name:+ ($display_name)}"
}

# Remove a Mastodon instance
mastodon_instance_remove() {
    local instance_url="$1"
    [[ "$instance_url" != https://* ]] && [[ "$instance_url" != http://* ]] && instance_url="https://$instance_url"
    instance_url="${instance_url%/}"
    _mastodon_instances_init || return 1
    sqlite3 "$MASTODON_INSTANCES_DB" \
        "DELETE FROM instances WHERE instance_url = '${instance_url//\'/\'\'}' COLLATE NOCASE;"
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
            "SELECT access_token FROM instances WHERE instance_url = '${instance_url//\'/\'\'}' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
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
    # Auto-expand readable file references in text
    if [ "${AGENT_FILE_EXPAND:-1}" -eq 1 ] && declare -f tools_expand_file_refs &>/dev/null; then
        text=$(tools_expand_file_refs "$text")
    fi
    # Expand LLM escape sequences (literal \n → real newlines)
    text=$(ui_expand_escapes "$text")
    local visibility="${2:-public}"  # public, unlisted, private, direct
    local instance="${3:-}"          # optional: specific instance URL

    # If post exceeds standard Mastodon limit (480 chars), thread it
    if [ "${#text}" -gt 480 ]; then
        mastodon_thread "$text" "$visibility" "$instance"
        return $?
    fi

    local token
    token=$(_mastodon_instance_token "$instance")
    if [ -z "$token" ]; then
        ui_err "Mastodon: No access token configured"
        ui_dim "Add one: /social mastodon instances add <url> <token>"
        ui_dim "Or set: /secret set MASTODON_ACCESS_TOKEN <token>"
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

mastodon_thread() {
    local full_text="$1"
    local visibility="${2:-public}"
    local instance="${3:-}"
    local delay="${4:-1}"

    if [ -z "$full_text" ]; then
        ui_err "Usage: mastodon_thread <text> [visibility] [instance]"
        return 1
    fi

    if [ "${AGENT_FILE_EXPAND:-1}" -eq 1 ] && declare -f tools_expand_file_refs &>/dev/null; then
        full_text=$(tools_expand_file_refs "$full_text")
    fi
    full_text=$(ui_expand_escapes "$full_text")

    local token base
    token=$(_mastodon_instance_token "$instance")
    if [ -z "$token" ]; then
        ui_err "Mastodon: No access token configured"
        ui_dim "Add one: /social mastodon instances add <url> <token>"
        ui_dim "Or set: /secret set MASTODON_ACCESS_TOKEN <token>"
        return 1
    fi
    base=$(_mastodon_instance_url "$instance")

    local chunks_json
    chunks_json=$(python3 -c '
import sys, re

text = sys.argv[1]
max_len = 440
paragraphs = [p.strip() for p in text.split("\n\n") if p.strip()]

chunks = []
current = ""
for p in paragraphs:
    if len(current) + len(p) + 2 <= max_len:
        current = (current + "\n\n" + p).strip()
    else:
        if current:
            chunks.append(current)
        if len(p) <= max_len:
            current = p
        else:
            sentences = re.split(r"(?<=[.?!])\s+", p)
            s_curr = ""
            for s in sentences:
                if len(s_curr) + len(s) + 1 <= max_len:
                    s_curr = (s_curr + " " + s).strip()
                else:
                    if s_curr:
                        chunks.append(s_curr)
                    s_curr = s
            current = s_curr
if current:
    chunks.append(current)

import json
print(json.dumps(chunks))
' "$full_text" 2>/dev/null)

    local total_chunks
    total_chunks=$(echo "$chunks_json" | jq '. | length' 2>/dev/null || echo 0)

    if [ "$total_chunks" -le 1 ]; then
        local data resp url
        data=$(jq -n --arg s "$full_text" --arg v "$visibility" '{"status": $s, "visibility": $v}')
        resp=$(api_post "$base/api/v1/statuses" "$data" -H "Authorization: Bearer $token")
        if [ $? -eq 0 ]; then
            url=$(api_json_get "$resp" '.url')
            ui_ok "Posted to Mastodon: $url"
            return 0
        else
            ui_err "Mastodon post failed"
            return 1
        fi
    fi

    ui_step "Posting $total_chunks-part thread to Mastodon ($base)..."
    local prev_id=""
    local first_url=""

    for (( i=0; i<total_chunks; i++ )); do
        local chunk
        chunk=$(echo "$chunks_json" | jq -r ".[$i]")
        local part_num=$((i + 1))
        local post_content="[${part_num}/${total_chunks}] ${chunk}"

        local post_data
        if [ -z "$prev_id" ]; then
            post_data=$(jq -n --arg s "$post_content" --arg v "$visibility" \
                '{"status": $s, "visibility": $v}')
        else
            post_data=$(jq -n --arg s "$post_content" --arg v "$visibility" --arg id "$prev_id" \
                '{"status": $s, "visibility": $v, "in_reply_to_id": $id}')
        fi

        local resp
        resp=$(api_post "$base/api/v1/statuses" "$post_data" -H "Authorization: Bearer $token")
        local status=$?

        if [ $status -eq 0 ]; then
            prev_id=$(api_json_get "$resp" '.id')
            local status_url
            status_url=$(api_json_get "$resp" '.url')
            [ -z "$first_url" ] && first_url="$status_url"
            ui_info "  Part ${part_num}/${total_chunks}: $status_url"
            [ "$part_num" -lt "$total_chunks" ] && sleep "$delay"
        else
            ui_err "Failed at part ${part_num}/${total_chunks}"
            return 1
        fi
    done

    ui_ok "Published full thread to Mastodon: $first_url"
    return 0
}

mastodon_validate() {
    local instance="${1:-}"
    ui_section "Mastodon Credentials Validation"

    local token base
    token=$(_mastodon_instance_token "$instance")
    base=$(_mastodon_instance_url "$instance")

    if [ -z "$token" ]; then
        ui_err "No Mastodon access token found."
        echo ""
        ui_step "How to connect your Mastodon account:"
        ui_info "  1. Log into your Mastodon instance in your browser (${base:-https://mastodon.social})"
        ui_info "  2. Navigate to Preferences → Development → New Application"
        ui_info "  3. Application name: 'George (Blue Lodge Agent)'"
        ui_info "  4. Scopes: Keep 'read' and 'write' checked (uncheck 'admin' or others)"
        ui_info "  5. Click 'Submit', then click into your new application"
        ui_info "  6. Copy 'Your access token'"
        echo ""
        ui_step "Save your credentials:"
        ui_info "  /secret set MASTODON_INSTANCE https://<your-mastodon-instance>"
        ui_info "  /secret set MASTODON_ACCESS_TOKEN <your_access_token>"
        ui_dim "  (Or multi-instance: /social mastodon instances add <url> <token>)"
        return 1
    fi

    ui_step "Verifying credentials on $base..."
    local resp http_code
    resp=$(curl -s -w "\n%{http_code}" -X GET "$base/api/v1/accounts/verify_credentials" \
        -H "Authorization: Bearer $token" \
        -H "User-Agent: George-BlueLodge/1.0" \
        --connect-timeout 10 --max-time 15 2>/dev/null)

    http_code=$(echo "$resp" | tail -n1)
    local body
    body=$(echo "$resp" | sed '$d')

    if [ "$http_code" = "200" ]; then
        local uname acct dname url followers statuses
        uname=$(echo "$body" | jq -r '.username // empty' 2>/dev/null)
        acct=$(echo "$body" | jq -r '.acct // empty' 2>/dev/null)
        dname=$(echo "$body" | jq -r '.display_name // empty' 2>/dev/null)
        url=$(echo "$body" | jq -r '.url // empty' 2>/dev/null)
        followers=$(echo "$body" | jq -r '.followers_count // 0' 2>/dev/null)
        statuses=$(echo "$body" | jq -r '.statuses_count // 0' 2>/dev/null)

        ui_ok "Mastodon Credentials VALID: Logged in as @${acct:-$uname}${dname:+ ($dname)}"
        ui_info "  Instance:    $base"
        ui_info "  Profile:     ${url:-https://$base/@$uname}"
        ui_info "  Toots:       $statuses | Followers: $followers"
        ui_dim "  Ready for autonomic and manual posting via /social post mastodon <text>"
        return 0
    else
        local err_msg
        err_msg=$(echo "$body" | jq -r '.error // empty' 2>/dev/null)
        ui_err "Mastodon authentication failed (HTTP $http_code)${err_msg:+: $err_msg}"
        ui_dim "Verify that instance URL ($base) is correct and token has 'read' & 'write' scopes."
        return 1
    fi
}

mastodon_timeline() {
    local count="${1:-20}"
    local instance="${2:-}"
    local token base
    token=$(_mastodon_instance_token "$instance") || return 1
    base=$(_mastodon_instance_url "$instance")

    api_get "$base/api/v1/timelines/home?limit=$count" \
        -H "Authorization: Bearer $token" | \
        jq -r '.[]? | "[\(.account.acct)] \(.content | gsub("<[^>]+>"; ""))"' 2>/dev/null
}

mastodon_reply() {
    local status_id="$1"
    local text="$2"
    local instance="${3:-}"
    local token base
    token=$(_mastodon_instance_token "$instance") || return 1
    base=$(_mastodon_instance_url "$instance")

    local data
    data=$(jq -n --arg s "$text" --arg id "$status_id" \
        '{"status": $s, "in_reply_to_id": $id}')

    api_post "$base/api/v1/statuses" "$data" \
        -H "Authorization: Bearer $token"
}

mastodon_search() {
    local query="$1"
    local instance="${2:-}"
    local token base
    token=$(_mastodon_instance_token "$instance") || return 1
    base=$(_mastodon_instance_url "$instance")

    local encoded
    encoded=$(printf '%s' "$query" | jq -sRr @uri)

    api_get "$base/api/v2/search?q=$encoded&type=statuses&limit=10" \
        -H "Authorization: Bearer $token" | \
        jq -r '.statuses[]? | "[\(.account.acct)] \(.content | gsub("<[^>]+>"; ""))"' 2>/dev/null
}

mastodon_notifications() {
    local count="${1:-10}"
    local instance="${2:-}"
    local token base
    token=$(_mastodon_instance_token "$instance") || return 1
    base=$(_mastodon_instance_url "$instance")

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
    # Auto-expand readable file references in text
    if [ "${AGENT_FILE_EXPAND:-1}" -eq 1 ] && declare -f tools_expand_file_refs &>/dev/null; then
        text=$(tools_expand_file_refs "$text")
    fi
    # Expand LLM escape sequences (literal \n → real newlines)
    text=$(ui_expand_escapes "$text")
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
    # Auto-expand readable file references in message
    if [ "${AGENT_FILE_EXPAND:-1}" -eq 1 ] && declare -f tools_expand_file_refs &>/dev/null; then
        message=$(tools_expand_file_refs "$message")
    fi
    # Expand LLM escape sequences (literal \n → real newlines)
    message=$(ui_expand_escapes "$message")
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

    # Detect unresolved file references before expansion
    local _unresolved_refs=""
    local _words
    read -ra _words <<< "$message"
    local _i
    for (( _i=0; _i<${#_words[@]}; _i++ )); do
        local _word="${_words[_i]}"
        local _clean_word
        _clean_word=$(echo "$_word" | tr -d '`()"\x27')
        _clean_word="${_clean_word%,}"
        _clean_word="${_clean_word%.}"
        local is_mem=0
        if [[ "$_clean_word" == mem:* ]]; then
            is_mem=1
        fi
        if [ "$is_mem" -eq 1 ] || [[ "$_clean_word" =~ \.(md|txt|json|yaml|yml|toml|conf|cfg|sh|bash|py|rs|go|js|ts|sql|csv)$ ]]; then
            local resolved=""
            local resolved_ui
            resolved_ui=$(ui_resolve_path "$_clean_word" "$PWD")
            if [ -f "$resolved_ui" ]; then
                resolved="$resolved_ui"
            elif [[ "$_clean_word" == "${LODGE_DIR:-$HOME/blue-lodge}"/* ]] && [ -f "$_clean_word" ]; then
                resolved="$_clean_word"
            elif [ -f "$_clean_word" ]; then
                resolved="$_clean_word"
            elif [ -f "$PWD/$_clean_word" ]; then
                resolved="$PWD/$_clean_word"
            elif [ -f "$PWD/.george/workspaces/$_clean_word" ]; then
                resolved="$PWD/.george/workspaces/$_clean_word"
            fi
            
            if [ -z "$resolved" ]; then
                local _check_limit=$((_i - 15))
                [ "$_check_limit" -lt 0 ] && _check_limit=0
                local _back_idx=$((_i - 1))
                while [ "$_back_idx" -ge "$_check_limit" ]; do
                    local _prepended=""
                    local k
                    for (( k=_back_idx; k<_i; k++ )); do
                        local _clean_k
                        _clean_k=$(echo "${_words[k]}" | tr -d '`()"\x27')
                        _prepended="${_prepended:+$_prepended }$_clean_k"
                    done
                    local _candidate="${_prepended} ${_clean_word}"
                    
                    local _cand_resolved=""
                    local _cand_sanitized=""
                    if declare -f tools_sanitize_filename &>/dev/null; then
                        _cand_sanitized=$(tools_sanitize_filename "$_candidate")
                    else
                        _cand_sanitized=$(echo "$_candidate" | sed 's/["'"'"'`]//g' | tr ' ' '-' | sed 's/[^a-zA-Z0-9_./-]//g')
                    fi
                    
                    local resolved_cand_ui
                    resolved_cand_ui=$(ui_resolve_path "$_candidate" "$PWD")
                    if [ -f "$resolved_cand_ui" ]; then
                        _cand_resolved="$resolved_cand_ui"
                    elif [ -f "$_candidate" ]; then
                        _cand_resolved="$_candidate"
                    elif [ -f "$PWD/$_candidate" ]; then
                        _cand_resolved="$PWD/$_candidate"
                    elif [ -f "$PWD/.george/workspaces/$_candidate" ]; then
                        _cand_resolved="$PWD/.george/workspaces/$_candidate"
                    elif [ -n "$_cand_sanitized" ] && [ -f "$_cand_sanitized" ]; then
                        _cand_resolved="$_cand_sanitized"
                    elif [ -n "$_cand_sanitized" ] && [ -f "$PWD/$_cand_sanitized" ]; then
                        _cand_resolved="$PWD/$_cand_sanitized"
                    elif [ -n "$_cand_sanitized" ] && [ -f "$PWD/.george/workspaces/$_cand_sanitized" ]; then
                        _cand_resolved="$PWD/.george/workspaces/$_cand_sanitized"
                    fi
                    
                    if [ -n "$_cand_resolved" ]; then
                        resolved="$_cand_resolved"
                        break
                    fi
                    _back_idx=$((_back_idx - 1))
                done
            fi
            
            if [ -z "$resolved" ]; then
                _unresolved_refs="${_unresolved_refs:+$_unresolved_refs, }'$_clean_word'"
            fi
        fi
    done

    # Auto-expand readable file references in message
    if [ "${AGENT_FILE_EXPAND:-1}" -eq 1 ] && declare -f tools_expand_file_refs &>/dev/null; then
        message=$(tools_expand_file_refs "$message")
    fi

    # Expand LLM escape sequences (literal \n → real newlines)
    message=$(ui_expand_escapes "$message")

    # Prepare truncated preview for Transmission Receipt to prevent prompt bloat
    local _preview_len="${AGENT_SOCIAL_RECEIPT_MAX_CHARS:-1000}"
    local _preview="$message"
    if [ ${#_preview} -gt "$_preview_len" ]; then
        _preview="${_preview:0:$_preview_len} ... (truncated: total ${#message} chars)"
    fi

    # Check if target is a user or DM (unless already executing within discord_dm)
    if [ "${_DISCORD_IN_DM:-0}" -ne 1 ]; then
        if [[ "$channel_id" == dm:* ]]; then
            _DISCORD_IN_DM=1 discord_dm "${channel_id#dm:}" "$message"
            return $?
        fi

        # Check if channel_id is a known user ID or resolves to a user (and not a channel)
        if [[ "$channel_id" =~ ^[0-9]+$ ]]; then
            _discord_users_init 2>/dev/null || true
            _discord_channels_init 2>/dev/null || true
            local is_chan is_usr
            is_chan=$(sqlite3 "$DISCORD_CHANNELS_DB" "SELECT 1 FROM channels WHERE channel_id = '$channel_id' LIMIT 1;" 2>/dev/null || true)
            if [ -z "$is_chan" ]; then
                is_usr=$(sqlite3 "$DISCORD_USERS_DB" "SELECT 1 FROM users WHERE user_id = '$channel_id' LIMIT 1;" 2>/dev/null || true)
                if [ -n "$is_usr" ]; then
                    _DISCORD_IN_DM=1 discord_dm "$channel_id" "$message"
                    return $?
                fi
            fi
        else
            local resolved
            resolved=$(discord_channel_resolve "$channel_id")
            if [ -z "$resolved" ]; then
                # If channel not found, check if it resolves as a user (e.g. "dabe", "me", "@user")
                local usr_resolved
                usr_resolved=$(discord_user_resolve "$channel_id" 2>/dev/null || true)
                if [ -n "$usr_resolved" ]; then
                    _DISCORD_IN_DM=1 discord_dm "$usr_resolved" "$message"
                    return $?
                fi
                ui_err "Unknown channel or user: $channel_id"
                ui_dim "Register it: /social discord channels add <name> <channel_id>"
                ui_dim "Or sync from Discord: /social discord channels sync"
                return 1
            fi
            channel_id="$resolved"
        fi
    fi

    # Auto-resolve @mentions in the message to Discord <@user_id> format
    if [[ "$message" == *"@"* ]] && declare -f discord_resolve_mentions &>/dev/null; then
        message=$(discord_resolve_mentions "$message")
    fi

    local token
    token=$(api_require_key "DISCORD_BOT_TOKEN" "Discord Bot") || return 1

    # ── Discord message length limit (2000 chars) ──────────────
    # Discord rejects messages > 2000 characters. Split long messages
    # into multiple sends, breaking at newline boundaries when possible.
    if [ ${#message} -gt 2000 ]; then
        local _chunks=() _chunk="" _line
        while IFS= read -r _line || [ -n "$_line" ]; do
            if [ -n "$_chunk" ] && [ $(( ${#_chunk} + ${#_line} + 1 )) -gt 2000 ]; then
                _chunks+=("$_chunk")
                _chunk=""
            fi
            if [ ${#_line} -gt 2000 ]; then
                [ -n "$_chunk" ] && { _chunks+=("$_chunk"); _chunk=""; }
                while [ ${#_line} -gt 2000 ]; do
                    _chunks+=("${_line:0:2000}")
                    _line="${_line:2000}"
                done
                [ -n "$_line" ] && _chunk="$_line"
            else
                [ -n "$_chunk" ] && _chunk+=$'\n'
                _chunk+="$_line"
            fi
        done <<< "$message"
        [ -n "$_chunk" ] && _chunks+=("$_chunk")

        local _chunk_count=${#_chunks[@]} _chunk_i=0 _chunk_ok=0
        for _ci in "${_chunks[@]}"; do
            _chunk_i=$((_chunk_i + 1))
            local data
            data=$(jq -n --arg c "$_ci" '{"content": $c}')
            api_post "https://discord.com/api/v10/channels/$channel_id/messages" "$data" \
                -H "Authorization: Bot $token" > /dev/null
            [ $? -eq 0 ] && _chunk_ok=$((_chunk_ok + 1))
            # Brief delay between chunks to respect rate limits
            [ $_chunk_i -lt $_chunk_count ] && sleep 0.5
        done
        if [ "$_chunk_ok" -eq "$_chunk_count" ]; then
            ui_ok "Sent to Discord (channel: $channel_id) — ${_chunk_count} parts"
            sleep 1
            echo "--- Transmission Receipt ---"
            echo "Payload transmitted successfully (chunked)."
            if [ -n "$_unresolved_refs" ]; then
                ui_warn "File reference(s) $_unresolved_refs could not be resolved."
            fi
            echo "Content sent:"
            echo "$_preview"
            echo "----------------------------"
        else
            ui_warn "Discord: ${_chunk_ok}/${_chunk_count} message parts sent (channel: $channel_id)"
        fi
        return 0
    fi

    local data
    data=$(jq -n --arg c "$message" '{"content": $c}')

    api_post "https://discord.com/api/v10/channels/$channel_id/messages" "$data" \
        -H "Authorization: Bot $token" > /dev/null
    local status=$?

    if [ $status -eq 0 ]; then
        ui_ok "Sent to Discord (channel: $channel_id)"
        sleep 1
        echo "--- Transmission Receipt ---"
        echo "Payload transmitted successfully."
        if [ -n "$_unresolved_refs" ]; then
            ui_warn "File reference(s) $_unresolved_refs could not be resolved."
        fi
        echo "Content sent:"
        echo "$_preview"
        echo "----------------------------"
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
    local cid
    cid=$(sqlite3 "$DISCORD_CHANNELS_DB" \
        "SELECT channel_id FROM channels WHERE name = '${name//\'/\'\'}' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
    if [ -n "$cid" ]; then
        echo "$cid"
        return 0
    fi
    # Also resolve by server / guild name (e.g. "logic" -> general channel in Logic server)
    sqlite3 "$DISCORD_CHANNELS_DB" \
        "SELECT channel_id FROM channels WHERE guild_name = '${name//\'/\'\'}' COLLATE NOCASE ORDER BY CASE WHEN name = 'general' THEN 0 ELSE 1 END LIMIT 1;" 2>/dev/null
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
         VALUES ('${name//\'/\'\'}', '${channel_id//\'/\'\'}', '${guild_name//\'/\'\'}', '${guild_id//\'/\'\'}');"
    ui_ok "Registered channel #${name} → ${channel_id}${guild_name:+ (${guild_name})}"
}

# Remove a channel mapping
discord_channel_remove() {
    local name="$1"
    name="${name#\#}"
    _discord_channels_init || return 1
    sqlite3 "$DISCORD_CHANNELS_DB" \
        "DELETE FROM channels WHERE name = '${name//\'/\'\'}' COLLATE NOCASE;"
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

# ── Compact social context for LLM injection ─────────────────
# Returns a terse summary of registered Discord channels and
# Mastodon instances for injection into strategist/specialist
# prompts. Silent — no UI output, returns empty string when
# nothing is configured.
social_context_compact() {
    local _out=""

    # Discord channels
    if [ -n "${DISCORD_CHANNELS_DB:-}" ] && [ -f "$DISCORD_CHANNELS_DB" ] && command -v sqlite3 &>/dev/null; then
        local _ch_count
        _ch_count=$(sqlite3 "$DISCORD_CHANNELS_DB" "SELECT COUNT(*) FROM channels;" 2>/dev/null || echo 0)
        if [ "${_ch_count:-0}" -gt 0 ]; then
            local _ch_list
            _ch_list=$(sqlite3 "$DISCORD_CHANNELS_DB" \
                "SELECT name || ' (' || COALESCE(NULLIF(guild_name,''), '?') || ')' FROM channels ORDER BY guild_name, name;" 2>/dev/null)
            _out="Discord channels: ${_ch_list//$'\n'/, }"
        fi
    fi

    # Mastodon instances
    if [ -n "${MASTODON_INSTANCES_DB:-}" ] && [ -f "$MASTODON_INSTANCES_DB" ] && command -v sqlite3 &>/dev/null; then
        local _mi_count
        _mi_count=$(sqlite3 "$MASTODON_INSTANCES_DB" "SELECT COUNT(*) FROM instances;" 2>/dev/null || echo 0)
        if [ "${_mi_count:-0}" -gt 0 ]; then
            local _mi_list
            _mi_list=$(sqlite3 "$MASTODON_INSTANCES_DB" \
                "SELECT COALESCE(NULLIF(display_name,''), instance_url) FROM instances ORDER BY instance_url;" 2>/dev/null)
            [ -n "$_out" ] && _out="${_out}\n"
            _out="${_out}Mastodon instances: ${_mi_list//$'\n'/, }"
        fi
    fi

    echo -e "$_out"
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
                 VALUES ('${cname//\'/\'\'}', '${cid//\'/\'\'}', '${gname//\'/\'\'}', '${gid//\'/\'\'}', 'text');" 2>/dev/null
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

    # ── Aggressive name cleaning ──────────────────────────
    # The LLM often garbles handles with email-like suffixes or
    # doubled names:
    #   @Babadoo@discord.com@Babadoo  →  Babadoo
    #   Nubster@discord.com           →  Nubster
    #   @user@user                    →  user
    # Split on @ and take the first non-domain token.
    if [[ "$name" == *@* ]]; then
        local _clean_name="" _part
        IFS='@' read -ra _parts <<< "$name"
        for _part in "${_parts[@]}"; do
            [ -z "$_part" ] && continue
            # Skip domain-like tokens (contain a dot)
            [[ "$_part" == *.* ]] && continue
            _clean_name="$_part"
            break
        done
        [ -n "$_clean_name" ] && name="$_clean_name"
    fi

    # Strip trailing punctuation the LLM may leave
    name=$(echo "$name" | sed 's/[,;:!?.]*$//')

    [ -z "$name" ] && return 1
    _discord_users_init 2>/dev/null || return 1

    # Sanitize for SQL (escape single quotes)
    local _safe="${name//\'/\'\'}"

    # Alias check for "me", "operator", "owner", "self"
    local _lower
    _lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    if [ "$_lower" = "me" ] || [ "$_lower" = "operator" ] || [ "$_lower" = "owner" ] || [ "$_lower" = "self" ]; then
        local _def_user="${DISCORD_DEFAULT_USER:-dabe_}"
        local _uid
        _uid=$(sqlite3 "$DISCORD_USERS_DB" \
            "SELECT user_id FROM users WHERE username = '${_def_user//\'/\'\'}' OR display_name = '${_def_user//\'/\'\'}' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
        if [ -n "$_uid" ]; then echo "$_uid"; return 0; fi
    fi

    # 1. Exact username match (primary)
    local uid
    uid=$(sqlite3 "$DISCORD_USERS_DB" \
        "SELECT user_id FROM users WHERE username = '$_safe' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
    if [ -n "$uid" ]; then echo "$uid"; return 0; fi

    # 2. Exact display_name match (allows @Pompler → pomps5246's user_id)
    uid=$(sqlite3 "$DISCORD_USERS_DB" \
        "SELECT user_id FROM users WHERE display_name = '$_safe' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
    if [ -n "$uid" ]; then echo "$uid"; return 0; fi

    # 3. Prefix match on username (allows @pomps → pomps5246)
    uid=$(sqlite3 "$DISCORD_USERS_DB" \
        "SELECT user_id FROM users WHERE username LIKE '$_safe%' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
    if [ -n "$uid" ]; then echo "$uid"; return 0; fi

    # 4. Prefix match on display_name
    uid=$(sqlite3 "$DISCORD_USERS_DB" \
        "SELECT user_id FROM users WHERE display_name LIKE '$_safe%' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
    if [ -n "$uid" ]; then echo "$uid"; return 0; fi

    # 5. Substring match on username
    uid=$(sqlite3 "$DISCORD_USERS_DB" \
        "SELECT user_id FROM users WHERE username LIKE '%$_safe%' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
    if [ -n "$uid" ]; then echo "$uid"; return 0; fi

    # 6. Substring match on display_name
    uid=$(sqlite3 "$DISCORD_USERS_DB" \
        "SELECT user_id FROM users WHERE display_name LIKE '%$_safe%' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
    [ -n "$uid" ] && echo "$uid"
}

# ── Discord: Multi-DM recipient parser ──────────────────────────
# Scans the first AGENT_DM_SCAN_CHARS characters of the text for
# Discord usernames/handles. Populates:
#   _DM_RESOLVED_IDS  — array of unique numeric user IDs
#   _DM_MESSAGE        — the message text after the name section
# Handles connectors ("and", "&") between names.
discord_dm_parse_recipients() {
    local text="$1"
    local scan_chars="${2:-${AGENT_DM_SCAN_CHARS:-80}}"

    _DM_RESOLVED_IDS=()
    _DM_MESSAGE=""

    local _consumed=0 _words_consumed=0 _pending_connectors=0

    for _word in $text; do
        # Stop if past scan window
        [ $_consumed -ge "$scan_chars" ] && break
        _consumed=$(( _consumed + ${#_word} + 1 ))

        # Buffer connector words — only consume if followed by a resolved name
        case "${_word,,}" in
            and|"&"|","|"+") _pending_connectors=$((_pending_connectors + 1)); continue ;;
        esac

        # Skip common stop words to prevent false name resolution
        local _clean_word
        _clean_word=$(echo "${_word,,}" | tr -d '"@,;:!?.' | tr -d "'")
        case "$_clean_word" in
            the|a|an|to|for|of|in|on|at|with|by|as|from|into|about|like|this|that|it|its|they|them|he|him|she|her|you|your|me|my|we|us|our|is|am|are|was|were|be|been|have|has|had|do|does|did|will|would|shall|should|can|could|may|might|must|send|write|report|contents|file|message|text|here)
                break
                ;;
        esac

        # Try to resolve as a Discord user
        local _uid
        _uid=$(discord_user_resolve "$_word" 2>/dev/null)
        if [ -n "$_uid" ]; then
            # Accept the pending connectors
            _words_consumed=$((_words_consumed + _pending_connectors + 1))
            _pending_connectors=0
            # Deduplicate
            local _dup=0 _ex
            for _ex in "${_DM_RESOLVED_IDS[@]}"; do
                [ "$_ex" == "$_uid" ] && { _dup=1; break; }
            done
            [ "$_dup" -eq 0 ] && _DM_RESOLVED_IDS+=("$_uid")
        else
            # Not a name — stop scanning
            break
        fi
    done

    # Strip consumed words from front to get message.
    # Use bash parameter expansion (not sed) so multi-line text
    # only strips from the front, not from every line.
    _DM_MESSAGE="$text"
    local _i=0 _w
    for _w in $text; do
        [ $_i -ge $_words_consumed ] && break
        _DM_MESSAGE="${_DM_MESSAGE#"${_DM_MESSAGE%%[![:space:]]*}"}"
        _DM_MESSAGE="${_DM_MESSAGE#"$_w"}"
        _i=$((_i + 1))
    done
    _DM_MESSAGE="${_DM_MESSAGE#"${_DM_MESSAGE%%[![:space:]]*}"}"
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
         VALUES ('${username//\'/\'\'}', '${user_id//\'/\'\'}', '${display_name//\'/\'\'}', '${guild_name//\'/\'\'}', '${guild_id//\'/\'\'}');"
    ui_ok "Registered user @${username} → ${user_id}${display_name:+ (${display_name})}"
}

# Remove a user mapping
discord_user_remove() {
    local username="$1"
    username="${username#@}"
    _discord_users_init || return 1
    sqlite3 "$DISCORD_USERS_DB" \
        "DELETE FROM users WHERE username = '${username//\'/\'\'}' COLLATE NOCASE;"
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
                     VALUES ('${uname//\'/\'\'}', '${uid//\'/\'\'}', '${dname//\'/\'\'}', '${gname//\'/\'\'}', '${gid//\'/\'\'}', $bot_flag);" 2>/dev/null
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
    mentions=$(echo "$text" | grep -oE '@[a-zA-Z0-9_.-]+' | sort -u)

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
            if [ -f "$DISCORD_USERS_DB" ]; then
                local _matched_users
                _matched_users=$(sqlite3 "$DISCORD_USERS_DB" "SELECT username, display_name FROM users LIMIT 10;" 2>/dev/null)
                if [ -n "$_matched_users" ]; then
                    ui_dim "Currently synced users (up to 10):"
                    echo "$_matched_users" | while IFS='|' read -r _uname _dname; do
                        ui_dim "  - $_uname ($_dname)"
                    done
                fi
            fi
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
    _DISCORD_IN_DM=1 discord_send "$dm_channel_id" "$message"
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
    # Auto-expand readable file references in text
    if [ "${AGENT_FILE_EXPAND:-1}" -eq 1 ] && declare -f tools_expand_file_refs &>/dev/null; then
        text=$(tools_expand_file_refs "$text")
    fi
    # Expand LLM escape sequences (literal \n → real newlines)
    text=$(ui_expand_escapes "$text")
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

social_provider_configured() {
    local platform="$1"

    case "$platform" in
        x|twitter)
            api_get_key "X_BEARER_TOKEN" &>/dev/null
            ;;
        mastodon|masto)
            local _masto_token
            _masto_token=$(_mastodon_instance_token "" 2>/dev/null)
            [ -n "$_masto_token" ] || api_get_key "MASTODON_ACCESS_TOKEN" &>/dev/null
            ;;
        bluesky|bsky)
            api_get_key "BLUESKY_APP_PASSWORD" &>/dev/null && api_get_key "BLUESKY_HANDLE" &>/dev/null
            ;;
        discord)
            api_get_key "DISCORD_WEBHOOK_URL" &>/dev/null || api_get_key "DISCORD_BOT_TOKEN" &>/dev/null
            ;;
        telegram|tg)
            api_get_key "TELEGRAM_BOT_TOKEN" &>/dev/null && api_get_key "TELEGRAM_CHAT_ID" &>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

social_provider_reachable() {
    local platform="$1"

    social_provider_configured "$platform" || return 1
    api_network_reachable 3 || return 1

    case "$platform" in
        x|twitter)
            api_endpoint_reachable "https://api.x.com/2/tweets" 4
            ;;
        mastodon|masto)
            local _base
            _base=$(_mastodon_base 2>/dev/null)
            [ -n "$_base" ] || return 1
            api_endpoint_reachable "${_base}/api/v1/instance" 4
            ;;
        bluesky|bsky)
            api_endpoint_reachable "https://bsky.social/xrpc/com.atproto.server.describeServer" 4
            ;;
        discord)
            api_endpoint_reachable "https://discord.com/api/v10/users/@me" 4
            ;;
        telegram|tg)
            api_endpoint_reachable "https://api.telegram.org" 4
            ;;
        *)
            return 1
            ;;
    esac
}

social_availability_summary() {
    local enabled="yes"
    local configured=()
    local reachable=()
    local p

    for p in x mastodon bluesky discord telegram; do
        if social_provider_configured "$p"; then
            configured+=("$p")
            if social_provider_reachable "$p"; then
                reachable+=("$p")
            fi
        fi
    done

    echo "SOCIAL_ENABLED: $enabled"
    echo "SOCIAL_CONFIGURED: ${configured[*]:-none}" | sed 's/ /,/g'
    echo "SOCIAL_REACHABLE: ${reachable[*]:-none}" | sed 's/ /,/g'
    echo "SOCIAL_NETWORK: $(api_network_state 3)"
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
        printf "  %b○%b %-15s not configured  %b%s%b\n" "$C_DIM" "$C_RESET" "X" "$C_DIM" "X_BEARER_TOKEN" "$C_RESET"
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
        printf "  %b○%b %-15s not configured  %b%s%b\n" "$C_DIM" "$C_RESET" "MASTODON" "$C_DIM" "MASTODON_ACCESS_TOKEN" "$C_RESET"
    fi

    # Bluesky
    if api_get_key "BLUESKY_APP_PASSWORD" &>/dev/null; then
        printf "  %b●%b %-15s configured\n" "$C_GREEN" "$C_RESET" "BLUESKY"
        configured=$((configured + 1))
    else
        printf "  %b○%b %-15s not configured  %b%s + %s%b\n" "$C_DIM" "$C_RESET" "BLUESKY" "$C_DIM" "BLUESKY_HANDLE" "BLUESKY_APP_PASSWORD" "$C_RESET"
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
        printf "  %b○%b %-15s not configured  %b%s%b\n" "$C_DIM" "$C_RESET" "DISCORD" "$C_DIM" "DISCORD_BOT_TOKEN or DISCORD_WEBHOOK_URL" "$C_RESET"
    fi

    # Telegram
    if api_get_key "TELEGRAM_BOT_TOKEN" &>/dev/null; then
        printf "  %b●%b %-15s configured\n" "$C_GREEN" "$C_RESET" "TELEGRAM"
        configured=$((configured + 1))
    else
        printf "  %b○%b %-15s not configured  %b%s + %s%b\n" "$C_DIM" "$C_RESET" "TELEGRAM" "$C_DIM" "TELEGRAM_BOT_TOKEN" "TELEGRAM_CHAT_ID" "$C_RESET"
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

# ── Autonomic Social & Comms Sweeps ───────────────────────────

discord_mentions_poll() {
    local token
    token=$(api_get_key "DISCORD_BOT_TOKEN" 2>/dev/null)
    if [ -z "$token" ]; then
        ui_dim "  Discord sweep: DISCORD_BOT_TOKEN not configured."
        return 0
    fi

    local me_resp
    me_resp=$(curl -s "https://discord.com/api/v10/users/@me" -H "Authorization: Bot $token" 2>/dev/null)
    local bot_id bot_name
    bot_id=$(echo "$me_resp" | jq -r .id 2>/dev/null)
    bot_name=$(echo "$me_resp" | jq -r .username 2>/dev/null)
    if [ -z "$bot_id" ] || [ "$bot_id" = "null" ]; then
        ui_dim "  Discord sweep: Could not authenticate bot token."
        return 0
    fi

    ui_step "Sweeping Discord channels for mentions of bot @${bot_name} (${bot_id})..."
    local channels_db="${DISCORD_CHANNELS_DB:-${GEORGE_DIR:-$PWD/.george}/discord_channels.db}"
    if [ ! -f "$channels_db" ]; then
        ui_dim "  Discord sweep: No discord_channels.db found."
        return 0
    fi

    local ch_list
    ch_list=$(sqlite3 "$channels_db" "SELECT name, channel_id FROM channels LIMIT 20;" 2>/dev/null || true)
    local mentions_found=0

    while IFS='|' read -r ch_name ch_id; do
        [ -z "$ch_id" ] && continue
        local msgs
        msgs=$(curl -s "https://discord.com/api/v10/channels/$ch_id/messages?limit=5" -H "Authorization: Bot $token" 2>/dev/null)
        local mentions
        mentions=$(echo "$msgs" | jq -c --arg bid "$bot_id" '.[]? | select(.author.id != $bid and (.content | contains("<@" + $bid + ">") or contains("<@!" + $bid + ">")))' 2>/dev/null || true)
        if [ -n "$mentions" ]; then
            while IFS= read -r m; do
                [ -z "$m" ] && continue
                local mid mauthor mcontent
                mid=$(echo "$m" | jq -r .id)
                mauthor=$(echo "$m" | jq -r .author.username)
                mcontent=$(echo "$m" | jq -r .content)
                ui_info "Discord mention in #$ch_name by @$mauthor: $mcontent"
                mkdir -p "${GEORGE_DIR:-$PWD/.george}/events" 2>/dev/null
                echo "{\"platform\":\"discord\",\"type\":\"mention\",\"channel_id\":\"$ch_id\",\"channel_name\":\"$ch_name\",\"message_id\":\"$mid\",\"author\":\"$mauthor\",\"content\":\"$mcontent\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> "${GEORGE_DIR:-$PWD/.george}/events/comms_events.jsonl"
                mentions_found=$((mentions_found + 1))
            done <<< "$mentions"
        fi
    done <<< "$ch_list"

    if [ "$mentions_found" -eq 0 ]; then
        ui_dim "  No new Discord mentions found across registered channels."
    else
        ui_ok "Discord sweep found $mentions_found new mention(s)."
    fi
}

x_social_sweep() {
    ui_step "Sweeping X (Twitter) social & blog queue..."
    local auth_header
    auth_header=$(_x_auth_header "GET" "https://api.x.com/2/tweets/search/recent")

    if [ -z "$auth_header" ]; then
        ui_dim "  X sweep: No X credentials configured in vault or keys.conf."
        ui_dim "  To activate X posting & monetization: /social x validate"
        return 0
    fi

    # Check recent timeline / mentions
    local timeline
    timeline=$(curl -s "https://api.x.com/2/tweets/search/recent?query=from:me&max_results=5" -H "$auth_header" 2>/dev/null)
    local t_count
    t_count=$(echo "$timeline" | jq '.meta.result_count // 0' 2>/dev/null)
    if [ -n "$t_count" ] && [ "$t_count" != "null" ]; then
        ui_dim "  X account connected (Recent posts: $t_count)"
    fi

    # Check for pending scheduled posts in .george/social/queue
    local queue_dir="${GEORGE_DIR:-$PWD/.george}/social/queue"
    mkdir -p "$queue_dir" 2>/dev/null
    local post_files
    post_files=("$queue_dir"/*.txt)
    if [ -e "${post_files[0]}" ]; then
        for pf in "${post_files[@]}"; do
            [ -f "$pf" ] || continue
            local tweet_body
            tweet_body=$(cat "$pf")
            if [ -n "$tweet_body" ]; then
                ui_info "Publishing queued post to X: ${tweet_body:0:60}..."
                if x_thread "$tweet_body" >/dev/null 2>&1; then
                    rm -f "$pf"
                    ui_ok "Published queued X post successfully."
                fi
            fi
        done
    else
        ui_dim "  No pending posts in social queue."
    fi
}

mastodon_social_sweep() {
    ui_step "Sweeping Mastodon notifications & mentions..."
    local token base
    token=$(_mastodon_instance_token "" 2>/dev/null)
    base=$(_mastodon_instance_url "" 2>/dev/null)

    if [ -z "$token" ]; then
        ui_dim "  Mastodon sweep: No Mastodon token configured."
        return 0
    fi

    # 1. Poll notifications for mentions & replies
    local notifs
    notifs=$(curl -s -X GET "$base/api/v1/notifications?limit=10" \
        -H "Authorization: Bearer $token" \
        -H "User-Agent: George-BlueLodge/1.0" \
        --connect-timeout 10 --max-time 15 2>/dev/null)

    local notif_count
    notif_count=$(echo "$notifs" | jq '. | length' 2>/dev/null || echo 0)

    if [ "$notif_count" -gt 0 ]; then
        mkdir -p "${GEORGE_DIR:-$PWD/.george}/events" 2>/dev/null
        local mentions_processed=0
        for (( i=0; i<notif_count; i++ )); do
            local item
            item=$(echo "$notifs" | jq -c ".[$i]" 2>/dev/null)
            [ -z "$item" ] && continue
            local ntype
            ntype=$(echo "$item" | jq -r .type 2>/dev/null)
            [ "$ntype" != "mention" ] && continue

            local nid acct content status_id
            nid=$(echo "$item" | jq -r .id)
            acct=$(echo "$item" | jq -r .account.acct)
            status_id=$(echo "$item" | jq -r '.status.id // empty')
            content=$(echo "$item" | jq -r '.status.content // ""' | sed 's/<[^>]*>//g')

            ui_info "Mastodon mention from @$acct (ID: $status_id): ${content:0:60}..."
            echo "{\"platform\":\"mastodon\",\"type\":\"mention\",\"notification_id\":\"$nid\",\"author\":\"$acct\",\"status_id\":\"$status_id\",\"content\":\"$content\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> "${GEORGE_DIR:-$PWD/.george}/events/comms_events.jsonl"
            mentions_processed=$((mentions_processed + 1))
        done
        if [ "$mentions_processed" -gt 0 ]; then
            ui_ok "Mastodon sweep recorded $mentions_processed mention(s) to event log."
        else
            ui_dim "  No new Mastodon mentions."
        fi
    else
        ui_dim "  No new Mastodon notifications."
    fi
}
