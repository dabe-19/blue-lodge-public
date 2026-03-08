#!/bin/bash
# ── George: REST API Client Core ───────────────────────────────
# Pure-curl HTTP client with auth, rate-limit awareness, and
# JSON helpers. Foundation for social media & provider integrations.

[ -n "${_LIB_API_LOADED:-}" ] && return 0; _LIB_API_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Config ─────────────────────────────────────────────────────
GEORGE_CONFIG_DIR="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}"
GEORGE_KEYS_FILE="$GEORGE_CONFIG_DIR/keys.conf"
GEORGE_COOKIES_DIR="$GEORGE_CONFIG_DIR/cookies"
GEORGE_CACHE_DIR="$GEORGE_CONFIG_DIR/cache"

API_USER_AGENT="George/0.1 (Blue Lodge Coding Agent)"
API_DEFAULT_TIMEOUT="${API_DEFAULT_TIMEOUT:-30}"

# ── Ensure config dir exists ──────────────────────────────────
api_init() {
    mkdir -p "$GEORGE_CONFIG_DIR" "$GEORGE_COOKIES_DIR" "$GEORGE_CACHE_DIR"
    chmod 700 "$GEORGE_CONFIG_DIR"
    if [ ! -f "$GEORGE_KEYS_FILE" ]; then
        cat > "$GEORGE_KEYS_FILE" << 'EOF'
# George API Keys Configuration
# This file stores API keys and tokens for external services.
# KEEP THIS FILE PRIVATE — never commit it to git.
#
# Format: KEY_NAME=value (no quotes, no spaces around =)
#
# ── Social Media ──────────────────────────────────────────
# X_BEARER_TOKEN=
# MASTODON_INSTANCE=https://mastodon.social
# MASTODON_ACCESS_TOKEN=
# BLUESKY_HANDLE=you.bsky.social
# BLUESKY_APP_PASSWORD=
# DISCORD_BOT_TOKEN=
# DISCORD_WEBHOOK_URL=
# TELEGRAM_BOT_TOKEN=
# TELEGRAM_CHAT_ID=
#
# ── AI Providers ──────────────────────────────────────────
# OPENAI_API_KEY=
# ANTHROPIC_API_KEY=
# GOOGLE_AI_API_KEY=
# GOOGLE_ADK_PROJECT_ID=
# GOOGLE_ADK_LOCATION=us-central1
# GROQ_API_KEY=
# MISTRAL_API_KEY=
# TOGETHER_API_KEY=
# PERPLEXITY_API_KEY=
# COHERE_API_KEY=
# DEEPSEEK_API_KEY=
# XAI_API_KEY=
#
# ── Web ───────────────────────────────────────────────────
# SERPER_API_KEY=
# (For Google search results — free tier available)
EOF
        chmod 600 "$GEORGE_KEYS_FILE"
        ui_dim "Created keys config at $GEORGE_KEYS_FILE"
    fi
}

# ── Load a key from config ─────────────────────────────────────
api_get_key() {
    local key_name="$1"
    if [ ! -f "$GEORGE_KEYS_FILE" ]; then
        return 1
    fi
    local value
    value=$(grep "^${key_name}=" "$GEORGE_KEYS_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    if [ -z "$value" ]; then
        return 1
    fi
    echo "$value"
}

# ── Set a key in config ───────────────────────────────────────
api_set_key() {
    local key_name="$1"
    local value="$2"
    api_init
    # Remove existing line if present, then append
    if grep -q "^${key_name}=" "$GEORGE_KEYS_FILE" 2>/dev/null; then
        local tmpfile
        tmpfile=$(mktemp)
        grep -v "^${key_name}=" "$GEORGE_KEYS_FILE" > "$tmpfile"
        mv "$tmpfile" "$GEORGE_KEYS_FILE"
    fi
    echo "${key_name}=${value}" >> "$GEORGE_KEYS_FILE"
    chmod 600 "$GEORGE_KEYS_FILE"
}

# ── List configured keys (names only, no values) ──────────────
api_list_keys() {
    if [ ! -f "$GEORGE_KEYS_FILE" ]; then
        ui_dim "No keys configured yet"
        return 0
    fi
    ui_section "Configured API Keys"
    local _found=0
    while IFS='=' read -r name _value; do
        local masked
        masked=$(echo "$_value" | sed 's/./*/g' | head -c 20)
        printf "  %b%-30s%b %s...\n" "$C_WHITE" "$name" "$C_RESET" "${masked:0:8}"
        _found=1
    done < <(grep "^[A-Z].*=" "$GEORGE_KEYS_FILE" 2>/dev/null)
    if [ "$_found" -eq 0 ]; then
        ui_dim "  No keys configured yet"
        ui_dim "  Set keys with: /api keys set KEY_NAME value"
    fi
    return 0
}

# ── Generic HTTP request ──────────────────────────────────────
# Usage: api_request METHOD URL [DATA] [EXTRA_CURL_ARGS...]
# Returns: response body on stdout, HTTP status on fd 3
api_request() {
    local method="$1"
    local url="$2"
    local data="${3:-}"
    shift 3 2>/dev/null || shift $#
    local extra_args=("$@")

    local curl_args=(
        -s
        -X "$method"
        -H "User-Agent: $API_USER_AGENT"
        --max-time "$API_DEFAULT_TIMEOUT"
        -w "\n%{http_code}"
    )

    # Add data if provided
    if [ -n "$data" ]; then
        curl_args+=(-H "Content-Type: application/json" -d "$data")
    fi

    # Add any extra args (auth headers, etc.)
    curl_args+=("${extra_args[@]}")
    curl_args+=("$url")

    local response
    response=$(curl "${curl_args[@]}" 2>/dev/null)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        ui_err "HTTP request failed (curl exit: $exit_code)"
        return 1
    fi

    # Split response body from status code
    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    # Store status and body for caller to check
    export _API_LAST_STATUS="$http_code"
    export _API_LAST_BODY="$body"

    echo "$body"

    # Return non-zero for error status codes
    case "$http_code" in
        2[0-9][0-9]) return 0 ;;
        429)
            ui_warn "Rate limited (429). Wait and retry."
            return 2 ;;
        4[0-9][0-9])
            ui_err "Client error ($http_code)"
            return 1 ;;
        5[0-9][0-9])
            ui_err "Server error ($http_code)"
            return 1 ;;
        *)
            return 1 ;;
    esac
}

# ── Convenience wrappers ──────────────────────────────────────
api_get() {
    local url="$1"
    shift
    api_request "GET" "$url" "" "$@"
}

api_post() {
    local url="$1"
    local data="$2"
    shift 2
    api_request "POST" "$url" "$data" "$@"
}

# ── Streaming POST ────────────────────────────────────────────
# Launches curl in unbuffered streaming mode, writing SSE data to
# a FIFO.  Caller reads from the FIFO and must kill the PID when done.
# Usage: api_stream_post URL DATA FIFO [EXTRA_CURL_ARGS...]
#   Writes curl PID to stdout.  Caller reads from FIFO.
api_stream_post() {
    local url="$1" data="$2" fifo="$3"
    shift 3
    local extra_args=("$@")

    curl -sN --connect-timeout 10 --max-time "${API_DEFAULT_TIMEOUT}" \
        -X POST \
        -H "Content-Type: application/json" \
        -H "User-Agent: $API_USER_AGENT" \
        -d "$data" \
        "${extra_args[@]}" \
        "$url" > "$fifo" 2>/dev/null &
    echo $!
}

api_put() {
    local url="$1"
    local data="$2"
    shift 2
    api_request "PUT" "$url" "$data" "$@"
}

api_delete() {
    local url="$1"
    shift
    api_request "DELETE" "$url" "" "$@"
}

# ── JSON helpers ──────────────────────────────────────────────
# Build a JSON string safely (escapes special chars)
api_json_escape() {
    local str="$1"
    printf '%s' "$str" | jq -Rs '.'
}

# Extract a field from JSON
api_json_get() {
    local json="$1"
    local field="$2"
    echo "$json" | jq -r "$field" 2>/dev/null
}

# ── Auth header builders ──────────────────────────────────────
api_bearer_header() {
    local token="$1"
    echo -H "Authorization: Bearer $token"
}

api_basic_header() {
    local user="$1"
    local pass="$2"
    local encoded
    encoded=$(printf '%s:%s' "$user" "$pass" | base64 -w0 2>/dev/null || printf '%s:%s' "$user" "$pass" | base64 2>/dev/null)
    echo -H "Authorization: Basic $encoded"
}

# ── Rate-limit aware retry ────────────────────────────────────
# Retries a function up to N times with exponential backoff
api_retry() {
    local max_retries="${1:-3}"
    local delay=2
    shift
    local cmd=("$@")

    local attempt=0
    while [ "$attempt" -lt "$max_retries" ]; do
        "${cmd[@]}" && return 0
        local status=$?

        attempt=$((attempt + 1))
        if [ "$attempt" -lt "$max_retries" ]; then
            if [ "$status" -eq 2 ]; then
                # Rate limited — wait longer
                ui_dim "Rate limited. Waiting ${delay}s..."
                sleep "$delay"
                delay=$((delay * 2))
            else
                sleep 1
            fi
        fi
    done
    return 1
}

# ── Require a key or fail with setup instructions ─────────────
api_require_key() {
    local key_name="$1"
    local service_name="${2:-$key_name}"
    local value
    value=$(api_get_key "$key_name")
    if [ -z "$value" ]; then
        ui_err "No $service_name API key configured"
        ui_dim "Set it with: /api keys set $key_name <your-key>"
        ui_dim "Or edit: $GEORGE_KEYS_FILE"
        return 1
    fi
    echo "$value"
}
