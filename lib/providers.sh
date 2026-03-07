#!/bin/bash
# ── George: AI Provider Integrations ───────────────────────────
# Unified interface to call external LLM APIs. George can route
# queries to cloud providers when local Ollama is insufficient
# or when the user explicitly requests a specific model.

[ -n "${_LIB_PROVIDERS_LOADED:-}" ] && return 0; _LIB_PROVIDERS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/api.sh"

# ── Provider timeout (longer for LLM calls) ───────────────────
PROVIDER_TIMEOUT="${PROVIDER_TIMEOUT:-120}"

# ── Provider model defaults ────────────────────────────────────────
# Stored in keys.conf as PROVIDER_MODEL_<PROVIDER>=<model>
# Resolved per call: explicit arg > stored default > hardcoded fallback

# Map provider name to canonical key name
_provider_canon() {
    case "$1" in
        openai|gpt)       echo "OPENAI" ;;
        anthropic|claude)  echo "ANTHROPIC" ;;
        google|gemini)     echo "GOOGLE" ;;
        groq)              echo "GROQ" ;;
        mistral)           echo "MISTRAL" ;;
        together)          echo "TOGETHER" ;;
        perplexity|pplx)   echo "PERPLEXITY" ;;
        cohere)            echo "COHERE" ;;
        deepseek)          echo "DEEPSEEK" ;;
        xai|grok)          echo "XAI" ;;
        *)                 echo "" ;;
    esac
}

# Resolve model: explicit arg > stored default > hardcoded fallback
_provider_resolve_model() {
    local explicit="$1" provider="$2" hardcoded="$3"
    # Explicit override wins
    if [ -n "$explicit" ]; then
        echo "$explicit"
        return
    fi
    # Check stored default
    local canon
    canon=$(_provider_canon "$provider")
    if [ -n "$canon" ]; then
        local stored
        stored=$(api_get_key "PROVIDER_MODEL_${canon}" 2>/dev/null)
        if [ -n "$stored" ]; then
            echo "$stored"
            return
        fi
    fi
    # Hardcoded fallback
    echo "$hardcoded"
}

provider_set_model() {
    local provider="$1" model="$2"
    local canon
    canon=$(_provider_canon "$provider")
    if [ -z "$canon" ]; then
        ui_err "Unknown provider: $provider"
        return 1
    fi
    api_set_key "PROVIDER_MODEL_${canon}" "$model"
    ui_ok "Default model for $provider set to: $model"
}

provider_get_model() {
    local provider="$1"
    local canon
    canon=$(_provider_canon "$provider")
    if [ -z "$canon" ]; then
        ui_err "Unknown provider: $provider"
        return 1
    fi
    api_get_key "PROVIDER_MODEL_${canon}" 2>/dev/null
}

provider_clear_model() {
    local provider="$1"
    local canon
    canon=$(_provider_canon "$provider")
    if [ -z "$canon" ]; then
        ui_err "Unknown provider: $provider"
        return 1
    fi
    local key_name="PROVIDER_MODEL_${canon}"
    if grep -q "^${key_name}=" "$GEORGE_KEYS_FILE" 2>/dev/null; then
        local tmpfile
        tmpfile=$(mktemp)
        grep -v "^${key_name}=" "$GEORGE_KEYS_FILE" > "$tmpfile"
        mv "$tmpfile" "$GEORGE_KEYS_FILE"
        chmod 600 "$GEORGE_KEYS_FILE"
        ui_ok "Cleared custom model for $provider (back to built-in default)"
    else
        ui_info "No custom model set for $provider"
    fi
}

# ── Response validation helper ────────────────────────────────
# Checks both HTTP errors and empty/null content from API responses.
# Usage: _provider_check_response $? "$resp" '.jq.path' "Label"
_provider_check_response() {
    local exit_code="$1" resp="$2" jq_path="$3" label="$4"
    if [ "$exit_code" -eq 0 ]; then
        local text
        text=$(api_json_get "$resp" "$jq_path")
        if [ -n "$text" ] && [ "$text" != "null" ]; then
            echo "$text"
            return 0
        fi
    fi
    local err_msg
    err_msg=$(api_json_get "$resp" '.error.message // .error.type // .message // "unknown error"')
    [ -z "$err_msg" ] || [ "$err_msg" = "null" ] && err_msg="empty or blocked response"
    ui_err "$label: $err_msg"
    return 1
}

# ═══════════════════════════════════════════════════════════════
# OpenAI — GPT-4o, GPT-4o-mini, o1, o3, etc.
# ═══════════════════════════════════════════════════════════════
# Key: OPENAI_API_KEY

openai_chat() {
    local message="$1"
    local model
    model=$(_provider_resolve_model "$2" "openai" "gpt-4o-mini")
    local system="${3:-You are a helpful assistant.}"
    local key
    key=$(api_require_key "OPENAI_API_KEY" "OpenAI") || return 1

    local data
    data=$(jq -n --arg m "$model" --arg s "$system" --arg u "$message" '{
        "model": $m,
        "messages": [
            {"role": "system", "content": $s},
            {"role": "user", "content": $u}
        ],
        "max_tokens": 4096,
        "temperature": 0.3
    }')

    local resp
    resp=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_post \
        "https://api.openai.com/v1/chat/completions" "$data" \
        -H "Authorization: Bearer $key")

    _provider_check_response $? "$resp" '.choices[0].message.content' "OpenAI"
}

openai_models() {
    local key
    key=$(api_require_key "OPENAI_API_KEY" "OpenAI") || return 1

    api_get "https://api.openai.com/v1/models" \
        -H "Authorization: Bearer $key" | \
        jq -r '.data[]? | .id' 2>/dev/null | grep -E "^(gpt|o[0-9])" | sort
}

# ═══════════════════════════════════════════════════════════════
# Anthropic — Claude 4, Sonnet, Haiku, etc.
# ═══════════════════════════════════════════════════════════════
# Key: ANTHROPIC_API_KEY

anthropic_chat() {
    local message="$1"
    local model
    model=$(_provider_resolve_model "$2" "anthropic" "claude-sonnet-4-20250514")
    local system="${3:-You are a helpful assistant.}"
    local key
    key=$(api_require_key "ANTHROPIC_API_KEY" "Anthropic") || return 1

    local data
    data=$(jq -n --arg m "$model" --arg s "$system" --arg u "$message" '{
        "model": $m,
        "max_tokens": 4096,
        "system": $s,
        "messages": [
            {"role": "user", "content": $u}
        ]
    }')

    local resp
    resp=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_post \
        "https://api.anthropic.com/v1/messages" "$data" \
        -H "x-api-key: $key" \
        -H "anthropic-version: 2023-06-01")

    _provider_check_response $? "$resp" '.content[0].text' "Anthropic"
}

anthropic_models() {
    echo "claude-opus-4-20250514"
    echo "claude-sonnet-4-20250514"
    echo "claude-haiku-3-20240307"
}

# ═══════════════════════════════════════════════════════════════
# Google AI Studio (Gemini) & ADK
# ═══════════════════════════════════════════════════════════════
# Key: GOOGLE_AI_API_KEY
# ADK Keys: GOOGLE_ADK_PROJECT_ID, GOOGLE_ADK_LOCATION

google_chat() {
    local message="$1"
    local model
    model=$(_provider_resolve_model "$2" "google" "gemini-2.0-flash")
    local key
    key=$(api_require_key "GOOGLE_AI_API_KEY" "Google AI") || return 1

    local data
    data=$(jq -n --arg u "$message" '{
        "contents": [{"parts": [{"text": $u}]}],
        "generationConfig": {
            "maxOutputTokens": 4096,
            "temperature": 0.3
        }
    }')

    local resp
    resp=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_post \
        "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${key}" \
        "$data")

    _provider_check_response $? "$resp" '.candidates[0].content.parts[0].text' "Google AI"
}

google_models() {
    local key
    key=$(api_require_key "GOOGLE_AI_API_KEY" "Google AI") || return 1

    api_get "https://generativelanguage.googleapis.com/v1beta/models?key=${key}" | \
        jq -r '.models[]? | .name' 2>/dev/null | sed 's|^models/||' | sort
}

# Google ADK (Agent Development Kit) — Vertex AI Agent Builder
google_adk_create_agent() {
    local display_name="$1"
    local instructions="${2:-You are a helpful agent.}"
    local key
    key=$(api_require_key "GOOGLE_AI_API_KEY" "Google AI") || return 1
    local project
    project=$(api_require_key "GOOGLE_ADK_PROJECT_ID" "Google ADK") || return 1
    local location
    location=$(api_get_key "GOOGLE_ADK_LOCATION")
    location="${location:-us-central1}"

    local data
    data=$(jq -n --arg dn "$display_name" --arg inst "$instructions" '{
        "displayName": $dn,
        "defaultLanguageCode": "en",
        "generativeInfo": {
            "agentContent": $inst
        }
    }')

    local resp
    resp=$(api_post \
        "https://${location}-dialogflow.googleapis.com/v3/projects/${project}/locations/${location}/agents" \
        "$data" \
        -H "Authorization: Bearer $key")

    if [ $? -eq 0 ]; then
        local agent_name
        agent_name=$(api_json_get "$resp" '.name')
        ui_ok "ADK Agent created: $agent_name"
        echo "$resp"
    else
        ui_err "ADK agent creation failed"
        return 1
    fi
}

google_adk_list_agents() {
    local key
    key=$(api_require_key "GOOGLE_AI_API_KEY" "Google AI") || return 1
    local project
    project=$(api_require_key "GOOGLE_ADK_PROJECT_ID" "Google ADK") || return 1
    local location
    location=$(api_get_key "GOOGLE_ADK_LOCATION")
    location="${location:-us-central1}"

    api_get \
        "https://${location}-dialogflow.googleapis.com/v3/projects/${project}/locations/${location}/agents" \
        -H "Authorization: Bearer $key" | \
        jq -r '.agents[]? | "\(.displayName) — \(.name)"' 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
# Groq — Fast inference (Llama, Mixtral, etc.)
# ═══════════════════════════════════════════════════════════════
# Key: GROQ_API_KEY

groq_chat() {
    local message="$1"
    local model
    model=$(_provider_resolve_model "$2" "groq" "llama-3.3-70b-versatile")
    local key
    key=$(api_require_key "GROQ_API_KEY" "Groq") || return 1

    local data
    data=$(jq -n --arg m "$model" --arg u "$message" '{
        "model": $m,
        "messages": [{"role": "user", "content": $u}],
        "max_tokens": 4096,
        "temperature": 0.3
    }')

    local resp
    resp=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_post \
        "https://api.groq.com/openai/v1/chat/completions" "$data" \
        -H "Authorization: Bearer $key")

    _provider_check_response $? "$resp" '.choices[0].message.content' "Groq"
}

# ═══════════════════════════════════════════════════════════════
# Mistral AI
# ═══════════════════════════════════════════════════════════════
# Key: MISTRAL_API_KEY

mistral_chat() {
    local message="$1"
    local model
    model=$(_provider_resolve_model "$2" "mistral" "mistral-large-latest")
    local key
    key=$(api_require_key "MISTRAL_API_KEY" "Mistral") || return 1

    local data
    data=$(jq -n --arg m "$model" --arg u "$message" '{
        "model": $m,
        "messages": [{"role": "user", "content": $u}],
        "max_tokens": 4096,
        "temperature": 0.3
    }')

    local resp
    resp=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_post \
        "https://api.mistral.ai/v1/chat/completions" "$data" \
        -H "Authorization: Bearer $key")

    _provider_check_response $? "$resp" '.choices[0].message.content' "Mistral"
}

# ═══════════════════════════════════════════════════════════════
# Together AI — Open-source models
# ═══════════════════════════════════════════════════════════════
# Key: TOGETHER_API_KEY

together_chat() {
    local message="$1"
    local model
    model=$(_provider_resolve_model "$2" "together" "meta-llama/Llama-3.3-70B-Instruct-Turbo")
    local key
    key=$(api_require_key "TOGETHER_API_KEY" "Together") || return 1

    local data
    data=$(jq -n --arg m "$model" --arg u "$message" '{
        "model": $m,
        "messages": [{"role": "user", "content": $u}],
        "max_tokens": 4096,
        "temperature": 0.3
    }')

    local resp
    resp=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_post \
        "https://api.together.xyz/v1/chat/completions" "$data" \
        -H "Authorization: Bearer $key")

    _provider_check_response $? "$resp" '.choices[0].message.content' "Together"
}

# ═══════════════════════════════════════════════════════════════
# Perplexity — Search-augmented LLM
# ═══════════════════════════════════════════════════════════════
# Key: PERPLEXITY_API_KEY

perplexity_chat() {
    local message="$1"
    local model
    model=$(_provider_resolve_model "$2" "perplexity" "sonar")
    local key
    key=$(api_require_key "PERPLEXITY_API_KEY" "Perplexity") || return 1

    local data
    data=$(jq -n --arg m "$model" --arg u "$message" '{
        "model": $m,
        "messages": [{"role": "user", "content": $u}],
        "max_tokens": 4096,
        "temperature": 0.3
    }')

    local resp
    resp=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_post \
        "https://api.perplexity.ai/chat/completions" "$data" \
        -H "Authorization: Bearer $key")

    _provider_check_response $? "$resp" '.choices[0].message.content' "Perplexity"
}

# ═══════════════════════════════════════════════════════════════
# Cohere — Command R+, Embed, Rerank
# ═══════════════════════════════════════════════════════════════
# Key: COHERE_API_KEY

cohere_chat() {
    local message="$1"
    local model
    model=$(_provider_resolve_model "$2" "cohere" "command-r-plus")
    local key
    key=$(api_require_key "COHERE_API_KEY" "Cohere") || return 1

    local data
    data=$(jq -n --arg m "$model" --arg u "$message" '{
        "model": $m,
        "message": $u,
        "max_tokens": 4096,
        "temperature": 0.3
    }')

    local resp
    resp=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_post \
        "https://api.cohere.ai/v1/chat" "$data" \
        -H "Authorization: Bearer $key")

    _provider_check_response $? "$resp" '.text' "Cohere"
}

# ═══════════════════════════════════════════════════════════════
# DeepSeek
# ═══════════════════════════════════════════════════════════════
# Key: DEEPSEEK_API_KEY

deepseek_chat() {
    local message="$1"
    local model
    model=$(_provider_resolve_model "$2" "deepseek" "deepseek-chat")
    local key
    key=$(api_require_key "DEEPSEEK_API_KEY" "DeepSeek") || return 1

    local data
    data=$(jq -n --arg m "$model" --arg u "$message" '{
        "model": $m,
        "messages": [{"role": "user", "content": $u}],
        "max_tokens": 4096,
        "temperature": 0.3
    }')

    local resp
    resp=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_post \
        "https://api.deepseek.com/chat/completions" "$data" \
        -H "Authorization: Bearer $key")

    _provider_check_response $? "$resp" '.choices[0].message.content' "DeepSeek"
}

# ═══════════════════════════════════════════════════════════════
# xAI (Grok)
# ═══════════════════════════════════════════════════════════════
# Key: XAI_API_KEY

xai_chat() {
    local message="$1"
    local model
    model=$(_provider_resolve_model "$2" "xai" "grok-2")
    local key
    key=$(api_require_key "XAI_API_KEY" "xAI") || return 1

    local data
    data=$(jq -n --arg m "$model" --arg u "$message" '{
        "model": $m,
        "messages": [{"role": "user", "content": $u}],
        "max_tokens": 4096,
        "temperature": 0.3
    }')

    local resp
    resp=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_post \
        "https://api.x.ai/v1/chat/completions" "$data" \
        -H "Authorization: Bearer $key")

    _provider_check_response $? "$resp" '.choices[0].message.content' "xAI"
}

# ═══════════════════════════════════════════════════════════════
# Unified provider dispatcher
# ═══════════════════════════════════════════════════════════════

# Route a query to a specific provider
provider_chat() {
    local provider="$1"
    local message="$2"
    local model="${3:-}"

    case "$provider" in
        openai|gpt)         openai_chat "$message" "$model" ;;
        anthropic|claude)   anthropic_chat "$message" "$model" ;;
        google|gemini)      google_chat "$message" "$model" ;;
        groq)               groq_chat "$message" "$model" ;;
        mistral)            mistral_chat "$message" "$model" ;;
        together)           together_chat "$message" "$model" ;;
        perplexity|pplx)    perplexity_chat "$message" "$model" ;;
        cohere)             cohere_chat "$message" "$model" ;;
        deepseek)           deepseek_chat "$message" "$model" ;;
        xai|grok)           xai_chat "$message" "$model" ;;
        *)
            ui_err "Unknown provider: $provider"
            ui_dim "Available: openai, anthropic, google, groq, mistral, together, perplexity, cohere, deepseek, xai"
            return 1 ;;
    esac
}

# Show which providers are configured
provider_status() {
    # ── Web & Search Tools ──
    echo ""
    ui_section "Web & Search"
    local web_configured=0

    if api_get_key "SERPER_API_KEY" &>/dev/null; then
        printf "  %b●%b %-15s configured\n" "$C_GREEN" "$C_RESET" "Serper"
        web_configured=$((web_configured + 1))
    else
        printf "  %b○%b %-15s not configured  %b%s%b\n" "$C_DIM" "$C_RESET" "Serper" "$C_DIM" "SERPER_API_KEY" "$C_RESET"
    fi

    if api_get_key "PERPLEXITY_API_KEY" &>/dev/null; then
        printf "  %b●%b %-15s configured\n" "$C_GREEN" "$C_RESET" "Perplexity"
        web_configured=$((web_configured + 1))
    else
        printf "  %b○%b %-15s not configured  %b%s%b\n" "$C_DIM" "$C_RESET" "Perplexity" "$C_DIM" "PERPLEXITY_API_KEY" "$C_RESET"
    fi

    printf "  %b●%b %-15s always available (no key needed)\n" "$C_GREEN" "$C_RESET" "DuckDuckGo"

    if [ "$web_configured" -eq 0 ]; then
        echo ""
        ui_dim "  DuckDuckGo works out of the box."
        ui_dim "  For better results: /api keys set SERPER_API_KEY <key>"
    fi

    # ── AI Providers ──
    echo ""
    ui_section "AI Providers"
    local configured=0

    local -A provider_keys=(
        [OpenAI]="OPENAI_API_KEY"
        [Anthropic]="ANTHROPIC_API_KEY"
        [Google_AI]="GOOGLE_AI_API_KEY"
        [Groq]="GROQ_API_KEY"
        [Mistral]="MISTRAL_API_KEY"
        [Together]="TOGETHER_API_KEY"
        [Perplexity]="PERPLEXITY_API_KEY"
        [Cohere]="COHERE_API_KEY"
        [DeepSeek]="DEEPSEEK_API_KEY"
        [xAI]="XAI_API_KEY"
    )

    for name in $(echo "${!provider_keys[@]}" | tr ' ' '\n' | sort); do
        local key="${provider_keys[$name]}"
        if api_get_key "$key" &>/dev/null; then
            local _model_val
            _model_val=$(api_get_key "PROVIDER_MODEL_${name^^}" 2>/dev/null)
            # Google_AI^^ = GOOGLE_AI but stored as PROVIDER_MODEL_GOOGLE
            [ -z "$_model_val" ] && [ "$name" = "Google_AI" ] && _model_val=$(api_get_key "PROVIDER_MODEL_GOOGLE" 2>/dev/null)
            if [ -n "$_model_val" ]; then
                printf "  %b\u25cf%b %-15s configured  %bmodel: %s%b\n" "$C_GREEN" "$C_RESET" "$name" "$C_DIM" "$_model_val" "$C_RESET"
            else
                printf "  %b\u25cf%b %-15s configured\n" "$C_GREEN" "$C_RESET" "$name"
            fi
            configured=$((configured + 1))
        else
            printf "  %b○%b %-15s not configured  %b%s%b\n" "$C_DIM" "$C_RESET" "$name" "$C_DIM" "$key" "$C_RESET"
        fi
    done

    if [ "$configured" -eq 0 ]; then
        echo ""
        ui_dim "  George runs locally by default (Ollama)."
        ui_dim "  Cloud providers are optional for when you need more power."
        ui_dim "  Set keys: /api keys set OPENAI_API_KEY sk-..."
    fi
}
