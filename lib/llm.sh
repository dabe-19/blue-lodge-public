#!/bin/bash
# ── Blue Lodge: LLM Interface ─────────────────────────────────
# Direct Ollama API wrapper. No proxy needed.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Config ─────────────────────────────────────────────────────
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
LODGE_MODEL="${LODGE_MODEL:-blue-lodge}"
LLM_MAX_TOKENS="${LLM_MAX_TOKENS:-2048}"
LLM_TIMEOUT="${LLM_TIMEOUT:-120}"

# ── Health Check ───────────────────────────────────────────────
llm_check() {
    local resp
    resp=$(curl -sf --max-time 5 "$OLLAMA_URL/api/tags" 2>/dev/null)
    if [ $? -ne 0 ]; then
        return 1
    fi
    # Check if our model exists
    if echo "$resp" | jq -r '.models[].name' 2>/dev/null | grep -q "$LODGE_MODEL"; then
        return 0
    else
        return 2  # Ollama running but model not found
    fi
}

# ── Ensure Ollama is running ───────────────────────────────────
llm_ensure() {
    if ! llm_check; then
        ui_warn "Ollama not running. Attempting to start..."
        if command -v ollama &>/dev/null; then
            ollama serve > /tmp/lodge-ollama.log 2>&1 &
            sleep 3
            if ! llm_check; then
                ui_err "Failed to start Ollama. Check /tmp/lodge-ollama.log"
                return 1
            fi
        else
            ui_err "Ollama not found. Install: curl -fsSL https://ollama.com/install.sh | sh"
            return 1
        fi
    fi
    local status=$?
    if [ "$status" -eq 2 ]; then
        ui_warn "Model '$LODGE_MODEL' not found. Creating..."
        llm_create_model
    fi
    return 0
}

# ── Create the model from Modelfile ────────────────────────────
llm_create_model() {
    if [ -f "$LODGE_DIR/Modelfile" ]; then
        ollama create "$LODGE_MODEL" -f "$LODGE_DIR/Modelfile" 2>&1
    else
        ui_err "No Modelfile found at $LODGE_DIR/Modelfile"
        return 1
    fi
}

# ── Generate (blocking, no stream) ────────────────────────────
# Usage: llm_generate "prompt" [system_prompt]
llm_generate() {
    local prompt="$1"
    local system="${2:-}"
    local payload

    if [ -n "$system" ]; then
        payload=$(jq -n \
            --arg model "$LODGE_MODEL" \
            --arg prompt "$prompt" \
            --arg system "$system" \
            --argjson num_predict "$LLM_MAX_TOKENS" \
            '{model: $model, prompt: $prompt, system: $system, stream: false, options: {num_predict: $num_predict}}')
    else
        payload=$(jq -n \
            --arg model "$LODGE_MODEL" \
            --arg prompt "$prompt" \
            --argjson num_predict "$LLM_MAX_TOKENS" \
            '{model: $model, prompt: $prompt, stream: false, options: {num_predict: $num_predict}}')
    fi

    local response
    response=$(curl -sf --max-time "$LLM_TIMEOUT" \
        "$OLLAMA_URL/api/generate" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "ERROR: LLM request failed or timed out after ${LLM_TIMEOUT}s"
        return 1
    fi

    echo "$response" | jq -r '.response // "ERROR: Empty response"'
}

# ── Generate with streaming (live output) ──────────────────────
# Usage: llm_stream "prompt" [system_prompt]
llm_stream() {
    local prompt="$1"
    local system="${2:-}"
    local payload
    local full_response=""

    if [ -n "$system" ]; then
        payload=$(jq -n \
            --arg model "$LODGE_MODEL" \
            --arg prompt "$prompt" \
            --arg system "$system" \
            --argjson num_predict "$LLM_MAX_TOKENS" \
            '{model: $model, prompt: $prompt, system: $system, stream: true, options: {num_predict: $num_predict}}')
    else
        payload=$(jq -n \
            --arg model "$LODGE_MODEL" \
            --arg prompt "$prompt" \
            --argjson num_predict "$LLM_MAX_TOKENS" \
            '{model: $model, prompt: $prompt, stream: true, options: {num_predict: $num_predict}}')
    fi

    # Stream tokens to stdout, collect full response
    curl -sf --max-time "$LLM_TIMEOUT" \
        "$OLLAMA_URL/api/generate" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null | while IFS= read -r line; do
        local token
        token=$(echo "$line" | jq -r '.response // empty' 2>/dev/null)
        if [ -n "$token" ]; then
            printf "%s" "$token"
        fi
        # Check if done
        local done_flag
        done_flag=$(echo "$line" | jq -r '.done // empty' 2>/dev/null)
        if [ "$done_flag" = "true" ]; then
            echo ""  # final newline
            break
        fi
    done
}

# ── Chat format (multi-turn via /api/chat) ─────────────────────
# Usage: llm_chat "messages_json" [system_prompt]
# messages_json: [{"role":"user","content":"..."},...]
llm_chat() {
    local messages="$1"
    local system="${2:-}"
    local payload

    if [ -n "$system" ]; then
        payload=$(jq -n \
            --arg model "$LODGE_MODEL" \
            --argjson messages "$messages" \
            --arg system "$system" \
            --argjson num_predict "$LLM_MAX_TOKENS" \
            '{model: $model, messages: ([{role:"system",content:$system}] + $messages), stream: false, options: {num_predict: $num_predict}}')
    else
        payload=$(jq -n \
            --arg model "$LODGE_MODEL" \
            --argjson messages "$messages" \
            --argjson num_predict "$LLM_MAX_TOKENS" \
            '{model: $model, messages: $messages, stream: false, options: {num_predict: $num_predict}}')
    fi

    local response
    response=$(curl -sf --max-time "$LLM_TIMEOUT" \
        "$OLLAMA_URL/api/chat" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "ERROR: Chat request failed"
        return 1
    fi

    echo "$response" | jq -r '.message.content // "ERROR: Empty response"'
}

# ── Quick one-shot with role ────────────────────────────────────
# Usage: llm_ask "question" [context]  
llm_ask() {
    local question="$1"
    local context="${2:-}"
    local prompt="$question"
    
    if [ -n "$context" ]; then
        prompt="CONTEXT:
$context

QUESTION: $question

Answer concisely."
    fi
    
    llm_generate "$prompt"
}

# ── Token estimate (rough) ─────────────────────────────────────
llm_estimate_tokens() {
    local text="$1"
    # Rough: ~4 chars per token for English
    local chars=${#text}
    echo $(( chars / 4 ))
}

# ── Model info ─────────────────────────────────────────────────
llm_info() {
    curl -sf "$OLLAMA_URL/api/show" \
        -d "{\"name\":\"$LODGE_MODEL\"}" 2>/dev/null | \
        jq '{model: .modelinfo.general_architecture, params: .details.parameter_size, quant: .details.quantization_level, family: .details.family}' 2>/dev/null
}
