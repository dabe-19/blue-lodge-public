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

_api_valid_key_name() {
    local key_name="$1"
    [[ "$key_name" =~ ^[A-Z][A-Z0-9_]*$ ]]
}

_api_value_is_safe() {
    local value="$1"
    # keys.conf is line-oriented; reject control chars to prevent breakout.
    if printf '%s' "$value" | grep -q '[[:cntrl:]]'; then
        return 1
    fi
    return 0
}

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
    if ! _api_valid_key_name "$key_name"; then
        return 1
    fi

    # 1. Fallback: Environment variable check first
    local env_val
    if env | grep -q "^${key_name}="; then
        env_val=$(eval echo "\${$key_name:-}")
        if [ -n "$env_val" ]; then
            echo "$env_val"
            return 0
        fi
    fi

    # 2. Fallback: If requesting SERPER_API_KEY, check environment for SERPER_API
    if [ "$key_name" = "SERPER_API_KEY" ]; then
        if env | grep -q "^SERPER_API="; then
            env_val=$(eval echo "\${SERPER_API:-}")
            if [ -n "$env_val" ]; then
                echo "$env_val"
                return 0
            fi
        fi
    fi

    # 3. Read from keys.conf
    if [ -f "$GEORGE_KEYS_FILE" ]; then
        local value
        value=$(awk -F= -v key="$key_name" '
            $1 == key {
                print substr($0, index($0, "=") + 1)
                found = 1
                exit
            }
            END {
                if (!found) exit 1
            }
        ' "$GEORGE_KEYS_FILE" 2>/dev/null)
        if [ -n "$value" ]; then
            echo "$value"
            return 0
        fi
    fi

    # 4. Fallback: If requesting SERPER_API_KEY, check keys.conf for SERPER_API
    if [ "$key_name" = "SERPER_API_KEY" ] && [ -f "$GEORGE_KEYS_FILE" ]; then
        local value
        value=$(awk -F= -v key="SERPER_API" '
            $1 == key {
                print substr($0, index($0, "=") + 1)
                found = 1
                exit
            }
            END {
                if (!found) exit 1
            }
        ' "$GEORGE_KEYS_FILE" 2>/dev/null)
        if [ -n "$value" ]; then
            echo "$value"
            return 0
        fi
    fi

    return 1
}

# ── Set a key in config ───────────────────────────────────────
api_set_key() {
    local key_name="$1"
    local value="$2"

    if ! _api_valid_key_name "$key_name"; then
        ui_err "Invalid key name '$key_name' (expected: A-Z, 0-9, _)"
        return 1
    fi

    if ! _api_value_is_safe "$value"; then
        ui_err "Refusing to persist key '$key_name' with control characters"
        return 1
    fi

    api_init

    local tmpfile
    tmpfile=$(mktemp)

    # Remove existing line if present, then append
    awk -F= -v key="$key_name" '$1 != key { print $0 }' "$GEORGE_KEYS_FILE" > "$tmpfile"
    printf '%s=%s\n' "$key_name" "$value" >> "$tmpfile"
    mv "$tmpfile" "$GEORGE_KEYS_FILE"
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
    local _ak_tmp
    _ak_tmp=$(mktemp "${TMPDIR:-/tmp}/lodge-keys.XXXXXX")
    grep "^[A-Z].*=" "$GEORGE_KEYS_FILE" 2>/dev/null > "$_ak_tmp" || true
    while IFS='=' read -r name _value; do
        local masked
        masked=$(echo "$_value" | sed 's/./*/g' | head -c 20)
        printf "  %b%-30s%b %s...\n" "$C_WHITE" "$name" "$C_RESET" "${masked:0:8}"
        _found=1
    done < "$_ak_tmp"
    rm -f "$_ak_tmp"
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
        --connect-timeout 10
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

# ── Model Source Normalization Helpers ───────────────────────
# Integration-layer utility for catalog/provisioning code paths.
# Returns stable caveat fields so core registry logic can consume
# external-source assumptions without hardcoding family specifics.

api_model_source_kind() {
    local source_ref="$1"
    local ref_lc
    ref_lc=$(printf '%s' "$source_ref" | tr '[:upper:]' '[:lower:]')

    if [[ "$ref_lc" == hf.co/* ]]; then
        echo "hf_ollama_registry"
    elif [[ "$ref_lc" =~ ^https?://.*\.gguf([?#].*)?$ ]]; then
        echo "gguf_url"
    elif [[ "$ref_lc" == *.gguf ]]; then
        echo "gguf_file"
    elif [[ "$ref_lc" =~ ^[a-z0-9._-]+/[a-z0-9._-]+:[a-z0-9._-]+$ ]]; then
        echo "ollama_namespaced"
    elif [[ "$ref_lc" =~ ^[a-z0-9._-]+:[a-z0-9._-]+$ ]]; then
        echo "ollama_library"
    else
        echo "unknown"
    fi
}

# Output format: key=value (one pair per line)
api_model_source_caveats() {
    local source_ref="$1"
    local family_hint="${2:-}"
    local role_hint="${3:-}"
    local ref_lc family_lc role_lc kind
    ref_lc=$(printf '%s' "$source_ref" | tr '[:upper:]' '[:lower:]')
    family_lc=$(printf '%s' "$family_hint" | tr '[:upper:]' '[:lower:]')
    role_lc=$(printf '%s' "$role_hint" | tr '[:upper:]' '[:lower:]')
    kind=$(api_model_source_kind "$source_ref")

    local pull_method="unknown"
    local runtime_compat="unknown"
    local multimodal="unknown"
    local thinking_behavior="none"
    local mobile_footprint="unknown"
    local notes=""

    case "$kind" in
        hf_ollama_registry)
            pull_method="ollama_pull_hf"
            runtime_compat="llama.cpp-capable"
            notes="hf.co GGUF pulled via Ollama manifests"
            ;;
        gguf_url|gguf_file)
            pull_method="direct_gguf"
            runtime_compat="llama.cpp-capable"
            notes="direct GGUF source"
            ;;
        ollama_namespaced|ollama_library)
            pull_method="ollama_pull"
            runtime_compat="ollama-only"
            notes="non-GGUF source metadata"
            ;;
    esac

    # Family/source overrides
    if [[ "$ref_lc" == *"unsloth"* ]] && [[ "$ref_lc" == *"gemma"* ]] && [[ "$ref_lc" == *"e4b"* ]] && [[ "$ref_lc" == *"qat"* ]]; then
        mobile_footprint="mobile-low-memory"
        multimodal="vision-capable"
        notes="${notes};unsloth gemma4 e4b qat profile"
    fi

    if [[ "$ref_lc" == *"qwen3.5"* ]] || [[ "$family_lc" == *"qwen35"* ]]; then
        thinking_behavior="template_kwargs-enable_thinking"
        runtime_compat="llama.cpp-capable"
        notes="${notes};thinking tokens require chat-template kwargs"
    elif [[ "$role_lc" == *"think"* ]] || [[ "$family_lc" == *"reason"* ]]; then
        thinking_behavior="native_or_prompt_emulated"
    fi

    if [[ "$ref_lc" == *"ministral"* ]] || [[ "$family_lc" == *"ministral"* ]]; then
        multimodal="vision-capable"
    elif [[ "$ref_lc" == *"gemma-3-4b"* ]] || [[ "$family_lc" == *"gemma"* ]]; then
        multimodal="vision-capable"
    elif [[ "$ref_lc" == *"gemma-3-1b"* ]]; then
        multimodal="text-only"
        mobile_footprint="ultra-light"
    fi

    if [ "$mobile_footprint" = "unknown" ]; then
        if [[ "$ref_lc" == *":1b"* ]] || [[ "$ref_lc" == *"-1b"* ]]; then
            mobile_footprint="ultra-light"
        elif [[ "$ref_lc" == *":2b"* ]] || [[ "$ref_lc" == *":3b"* ]] || [[ "$ref_lc" == *":4b"* ]] || [[ "$ref_lc" == *"-2b"* ]] || [[ "$ref_lc" == *"-3b"* ]] || [[ "$ref_lc" == *"-4b"* ]]; then
            mobile_footprint="light"
        elif [[ "$ref_lc" == *":7b"* ]] || [[ "$ref_lc" == *":8b"* ]] || [[ "$ref_lc" == *":9b"* ]] || [[ "$ref_lc" == *"-7b"* ]] || [[ "$ref_lc" == *"-8b"* ]] || [[ "$ref_lc" == *"-9b"* ]]; then
            mobile_footprint="medium"
        fi
    fi

    printf 'source_kind=%s\n' "$kind"
    printf 'pull_method=%s\n' "$pull_method"
    printf 'runtime_compat=%s\n' "$runtime_compat"
    printf 'multimodal=%s\n' "$multimodal"
    printf 'thinking_behavior=%s\n' "$thinking_behavior"
    printf 'mobile_footprint=%s\n' "$mobile_footprint"
    printf 'notes=%s\n' "${notes#;}"
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

# ── External availability probes (silent) ───────────────────
# These helpers are routing-safe: no UI output, deterministic
# return codes, and no dependency on provider-specific callers.
api_network_state() {
    local timeout="${1:-3}"

    if [ "${AGENT_FORCE_OFFLINE:-0}" -eq 1 ]; then
        echo "forced_offline"
        return 0
    fi

    if declare -f vitals_net_reachable &>/dev/null; then
        if vitals_net_reachable &>/dev/null; then
            echo "online"
        else
            echo "offline"
        fi
        return 0
    fi

    if command -v curl &>/dev/null; then
        if curl -fsSI --connect-timeout 2 --max-time "$timeout" https://example.com >/dev/null 2>&1; then
            echo "online"
        else
            echo "offline"
        fi
        return 0
    fi

    echo "unknown"
}

api_network_reachable() {
    [ "$(api_network_state "${1:-3}")" = "online" ]
}

api_endpoint_reachable() {
    local url="$1"
    local timeout="${2:-5}"

    [ -n "$url" ] || return 1
    command -v curl &>/dev/null || return 1

    local code
    code=$(curl -sI --connect-timeout 2 --max-time "$timeout" -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)

    case "$code" in
        2[0-9][0-9]|3[0-9][0-9]|401|403|405|429)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ── Coarse service-awareness normalization (integration layer) ─────────
# Emits stable, provider-agnostic inputs for infeasibility classification.
# Output format is line-oriented key/value so existing status pipelines can
# append this block without changing their current human-readable sections.
api_service_awareness_summary() {
    local network_state
    network_state=$(api_network_state 3)

    # DuckDuckGo is a built-in default provider requiring no API keys
    local web_provider_configured="configured"

    local web_policy_state="unlocked"
    [ "${_AGENT_WEB_LOCKED:-0}" -eq 1 ] && web_policy_state="locked"

    local web_capability_state="unavailable"
    if [ "$network_state" = "online" ] && [ "$web_provider_configured" = "configured" ] && [ "$web_policy_state" = "unlocked" ]; then
        web_capability_state="available"
    fi

    # Git uses built-in local tooling; there is no external provider key.
    local git_provider_configured="configured"
    local git_policy_state="unlocked"
    [ "${_AGENT_GIT_LOCKED:-0}" -eq 1 ] && git_policy_state="locked"

    local git_capability_state="unavailable"
    if [ "$network_state" = "online" ] && [ "$git_policy_state" = "unlocked" ]; then
        git_capability_state="available"
    fi

    echo "SERVICE_AWARENESS_VERSION: v1"
    echo "INFEASIBILITY_INPUT_NETWORK: $network_state"
    echo "INFEASIBILITY_INPUT_WEB_CAPABILITY: $web_capability_state"
    echo "INFEASIBILITY_INPUT_WEB_PROVIDER: $web_provider_configured"
    echo "INFEASIBILITY_INPUT_WEB_POLICY: $web_policy_state"
    echo "INFEASIBILITY_INPUT_GIT_CAPABILITY: $git_capability_state"
    echo "INFEASIBILITY_INPUT_GIT_PROVIDER: $git_provider_configured"
    echo "INFEASIBILITY_INPUT_GIT_POLICY: $git_policy_state"
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
