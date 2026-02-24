#!/bin/bash
# ── George: LLM Interface ─────────────────────────────────
# Direct Ollama API wrapper. No proxy needed.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Config ─────────────────────────────────────────────────────
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
LODGE_MODEL="${LODGE_MODEL:-blue-lodge}"
LLM_MAX_TOKENS="${LLM_MAX_TOKENS:-1024}"    # Default max output tokens (task mode)
LLM_ASK_TOKENS="${LLM_ASK_TOKENS:-300}"     # Max output tokens for /ask (quick answers)
LLM_TIMEOUT="${LLM_TIMEOUT:-300}"           # Safety net: 300s max per request (Ctrl+C also works)
LLM_KEEP_ALIVE="${LLM_KEEP_ALIVE:-30m}"     # How long model stays loaded after last request
LODGE_THINK="${LODGE_THINK:-0}"               # 0=disable thinking (fast, default), 1=enable Qwen3 thinking
LODGE_THINK_STREAM="${LODGE_THINK_STREAM:-1}"  # When LODGE_THINK=1: 0=hide thinking, 1=show dimmed, 2=show bright (cyan)
LODGE_DEBUG="${LODGE_DEBUG:-0}"                 # 0=normal, 1=show timers + token counts per LLM call

# ── Debug tracking state ───────────────────────────────────────
_LLM_DEBUG_CALL_COUNT=0
_LLM_DEBUG_TOTAL_INPUT=0
_LLM_DEBUG_TOTAL_OUTPUT=0
_LLM_DEBUG_TASK_START=""

# ── Active request tracking (for cancellation) ─────────────────
_LLM_CURL_PID=""
_LLM_ACTIVE=0

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

# ── Check if model is currently loaded in memory ───────────────
llm_is_loaded() {
    local resp
    resp=$(curl -sf --max-time 5 "$OLLAMA_URL/api/ps" 2>/dev/null)
    [ $? -ne 0 ] && return 1
    echo "$resp" | jq -e ".models[] | select(.name == \"$LODGE_MODEL\")" &>/dev/null
}

# ── Unload model from memory ───────────────────────────────────
# Sends a request with keep_alive=0 to immediately free RAM.
# Safe to call — does not affect CLAUDE.md or journal persistence.
llm_unload() {
    if llm_is_loaded; then
        curl -sf --max-time 10 "$OLLAMA_URL/api/generate" \
            -H "Content-Type: application/json" \
            -d "{\"model\": \"$LODGE_MODEL\", \"prompt\": \"\", \"keep_alive\": 0}" &>/dev/null
        ui_dim "Model unloaded from memory"
    fi
}

# ── Cancel active LLM request ──────────────────────────────────
llm_cancel() {
    if [ -n "$_LLM_CURL_PID" ] && kill -0 "$_LLM_CURL_PID" 2>/dev/null; then
        kill "$_LLM_CURL_PID" 2>/dev/null
        wait "$_LLM_CURL_PID" 2>/dev/null
        _LLM_CURL_PID=""
    fi
    _LLM_ACTIVE=0
}

# ── Warm up model (pre-load weights into memory) ──────────────
# Sends a trivial prompt with num_predict=1 so the model loads
# but doesn't burn through the context window. This makes the
# first real request much faster on mobile hardware.
llm_warmup() {
    if llm_is_loaded; then
        return 0  # already hot
    fi
    local payload
    payload=$(jq -n \
        --arg model "$LODGE_MODEL" \
        --arg keep_alive "$LLM_KEEP_ALIVE" \
        '{model: $model, prompt: "Hello /nothink", stream: false, keep_alive: $keep_alive, options: {num_predict: 1}}')
    curl -sf "$OLLAMA_URL/api/generate" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1
}

# ── Ensure Ollama is running ───────────────────────────────────
llm_ensure() {
    # Capture llm_check return code immediately — $? gets overwritten
    # by subsequent commands (echo, if, ui_warn, etc.)
    llm_check
    local status=$?

    if [ "$status" -eq 1 ]; then
        ui_warn "Ollama not running. Attempting to start..."
        if command -v ollama &>/dev/null; then
            ollama serve > /tmp/lodge-ollama.log 2>&1 &
            sleep 3

            llm_check
            status=$?

            if [ "$status" -eq 1 ]; then
                ui_err "Failed to start Ollama. Check /tmp/lodge-ollama.log"
                return 1
            fi
        else
            ui_err "Ollama not found. Install: curl -fsSL https://ollama.com/install.sh | sh"
            return 1
        fi
    fi

    # Check if model is missing (status 2 = Ollama running, model absent)
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

# ── Debug output helpers ───────────────────────────────────────
# Print debug info to /dev/tty so it's visible even inside $() captures.
_llm_debug_print() {
    [ "${LODGE_DEBUG:-0}" -eq 0 ] && return
    local _tty="/dev/tty"
    [ -w /dev/tty ] 2>/dev/null || _tty="/dev/stderr"
    printf " %b  [debug] %s%b\n" "$C_DIM" "$1" "$C_RESET" > "$_tty" 2>/dev/null
}

_llm_debug_start_timer() {
    [ "${LODGE_DEBUG:-0}" -eq 0 ] && return
    _LLM_DEBUG_CALL_START=$(date +%s%N 2>/dev/null || date +%s)
    _LLM_DEBUG_CALL_COUNT=$((_LLM_DEBUG_CALL_COUNT + 1))
}

_llm_debug_end_timer() {
    [ "${LODGE_DEBUG:-0}" -eq 0 ] && return
    local label="${1:-LLM call}"
    local input_tok="${2:-?}"
    local output_tok="${3:-?}"
    local end_ns
    end_ns=$(date +%s%N 2>/dev/null || date +%s)
    local elapsed_ms=0
    if [[ "$_LLM_DEBUG_CALL_START" =~ [0-9]{10,} ]] && [[ "$end_ns" =~ [0-9]{10,} ]]; then
        elapsed_ms=$(( (end_ns - _LLM_DEBUG_CALL_START) / 1000000 ))
    else
        elapsed_ms=$(( end_ns - _LLM_DEBUG_CALL_START ))
        elapsed_ms=$((elapsed_ms * 1000))
    fi
    local elapsed_s
    elapsed_s=$(awk "BEGIN{printf \"%.1f\", $elapsed_ms/1000}")
    # Accumulate totals
    [[ "$input_tok" =~ ^[0-9]+$ ]] && _LLM_DEBUG_TOTAL_INPUT=$((_LLM_DEBUG_TOTAL_INPUT + input_tok))
    [[ "$output_tok" =~ ^[0-9]+$ ]] && _LLM_DEBUG_TOTAL_OUTPUT=$((_LLM_DEBUG_TOTAL_OUTPUT + output_tok))
    _llm_debug_print "${label}: ${elapsed_s}s | in:${input_tok} out:${output_tok} tok"
}

# Reset debug counters at task start
llm_debug_reset() {
    _LLM_DEBUG_CALL_COUNT=0
    _LLM_DEBUG_TOTAL_INPUT=0
    _LLM_DEBUG_TOTAL_OUTPUT=0
    _LLM_DEBUG_TASK_START=$(date +%s)
}

# Print task-level debug summary
llm_debug_summary() {
    [ "${LODGE_DEBUG:-0}" -eq 0 ] && return
    local now
    now=$(date +%s)
    local total_s=$(( now - ${_LLM_DEBUG_TASK_START:-$now} ))
    local _tty="/dev/tty"
    [ -w /dev/tty ] 2>/dev/null || _tty="/dev/stderr"
    printf "\n %b── Debug Summary ──────────────────────────────%b\n" "$C_DIM" "$C_RESET" > "$_tty" 2>/dev/null
    printf " %b  LLM calls:     %d%b\n" "$C_DIM" "$_LLM_DEBUG_CALL_COUNT" "$C_RESET" > "$_tty" 2>/dev/null
    printf " %b  Total input:   %d tokens%b\n" "$C_DIM" "$_LLM_DEBUG_TOTAL_INPUT" "$C_RESET" > "$_tty" 2>/dev/null
    printf " %b  Total output:  %d tokens%b\n" "$C_DIM" "$_LLM_DEBUG_TOTAL_OUTPUT" "$C_RESET" > "$_tty" 2>/dev/null
    printf " %b  Wall time:     %ds%b\n" "$C_DIM" "$total_s" "$C_RESET" > "$_tty" 2>/dev/null
    printf " %b──────────────────────────────────────────────%b\n" "$C_DIM" "$C_RESET" > "$_tty" 2>/dev/null
}

# ── Generate (blocking, no stream) ────────────────────────────
# Usage: llm_generate "prompt" [system_prompt] [max_tokens]
llm_generate() {
    local prompt="$1"
    local system="${2:-}"
    local max_tokens="${3:-$LLM_MAX_TOKENS}"
    local payload
    local timeout_args=()

    _llm_debug_start_timer

    # Qwen3 thinking mode control
    if [ "${LODGE_THINK:-0}" -eq 0 ]; then
        prompt="${prompt} /nothink"
    fi

    if [ -n "$system" ]; then
        payload=$(jq -n \
            --arg model "$LODGE_MODEL" \
            --arg prompt "$prompt" \
            --arg system "$system" \
            --arg keep_alive "$LLM_KEEP_ALIVE" \
            --argjson num_predict "$max_tokens" \
            '{model: $model, prompt: $prompt, system: $system, stream: false, keep_alive: $keep_alive, options: {num_predict: $num_predict}}')
    else
        payload=$(jq -n \
            --arg model "$LODGE_MODEL" \
            --arg prompt "$prompt" \
            --arg keep_alive "$LLM_KEEP_ALIVE" \
            --argjson num_predict "$max_tokens" \
            '{model: $model, prompt: $prompt, stream: false, keep_alive: $keep_alive, options: {num_predict: $num_predict}}')
    fi

    # Build timeout args: 0 means no timeout (user cancels via Ctrl+C)
    if [ "$LLM_TIMEOUT" -gt 0 ] 2>/dev/null; then
        timeout_args=(--max-time "$LLM_TIMEOUT")
    fi

    _LLM_ACTIVE=1
    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/lodge-llm-XXXXXX")
    # Ensure tmpfile is cleaned up even on unexpected exit
    trap 'rm -f "$tmpfile" 2>/dev/null' RETURN

    # Run curl in background so we can track and cancel it
    curl -sf "${timeout_args[@]}" \
        "$OLLAMA_URL/api/generate" \
        -H "Content-Type: application/json" \
        -d "$payload" > "$tmpfile" 2>/dev/null &
    _LLM_CURL_PID=$!

    # Wait for curl — if interrupted, the trap handler cleans up
    wait "$_LLM_CURL_PID"
    local curl_exit=$?
    _LLM_CURL_PID=""
    _LLM_ACTIVE=0

    if [ $curl_exit -ne 0 ]; then
        rm -f "$tmpfile"
        if [ $curl_exit -eq 143 ] || [ $curl_exit -eq 130 ]; then
            echo "ERROR: Request cancelled"
        else
            echo "ERROR: LLM request failed (exit $curl_exit)"
        fi
        return 1
    fi

    local response
    response=$(cat "$tmpfile")
    rm -f "$tmpfile"

    if [ -z "$response" ]; then
        echo "ERROR: Empty response from LLM"
        return 1
    fi

    # Extract token counts for debug (Ollama includes these in non-streaming response)
    if [ "${LODGE_DEBUG:-0}" -eq 1 ]; then
        local _dbg_in _dbg_out
        _dbg_in=$(echo "$response" | jq -r '.prompt_eval_count // 0' 2>/dev/null)
        _dbg_out=$(echo "$response" | jq -r '.eval_count // 0' 2>/dev/null)
        _llm_debug_end_timer "generate" "$_dbg_in" "$_dbg_out"
    fi

    # Strip any <think>...</think> blocks from Qwen3 thinking mode
    echo "$response" | jq -r '.response // "ERROR: Empty response"' | sed 's/<think>.*<\/think>//g; s/<think>[^<]*$//g'
}

# ── Generate with streaming (live output) ──────────────────────
# Usage: llm_stream "prompt" [system_prompt] [max_tokens]
llm_stream() {
    local prompt="$1"
    local system="${2:-}"
    local max_tokens="${3:-$LLM_MAX_TOKENS}"
    local payload
    local full_response=""

    _llm_debug_start_timer

    # Qwen3 thinking mode control: append /nothink or /think to user prompt
    # Thinking on a 4B CPU model burns tokens on internal reasoning (slow + noisy).
    # Default off (LODGE_THINK=0). Users can export LODGE_THINK=1 for complex tasks.
    if [ "${LODGE_THINK:-0}" -eq 0 ]; then
        prompt="${prompt} /nothink"
    fi

    if [ -n "$system" ]; then
        payload=$(jq -n \
            --arg model "$LODGE_MODEL" \
            --arg prompt "$prompt" \
            --arg system "$system" \
            --arg keep_alive "$LLM_KEEP_ALIVE" \
            --argjson num_predict "$max_tokens" \
            '{model: $model, prompt: $prompt, system: $system, stream: true, keep_alive: $keep_alive, options: {num_predict: $num_predict}}')
    else
        payload=$(jq -n \
            --arg model "$LODGE_MODEL" \
            --arg prompt "$prompt" \
            --arg keep_alive "$LLM_KEEP_ALIVE" \
            --argjson num_predict "$max_tokens" \
            '{model: $model, prompt: $prompt, stream: true, keep_alive: $keep_alive, options: {num_predict: $num_predict}}')
    fi

    # Build timeout args — belt-and-suspenders: both `timeout` command and curl's --max-time
    local curl_timeout="${LLM_TIMEOUT:-300}"
    local timeout_cmd=""
    if [ "$curl_timeout" -gt 0 ] 2>/dev/null; then
        # Use external `timeout` for hard kill (catches cases --max-time misses in streaming)
        if command -v timeout &>/dev/null; then
            timeout_cmd="timeout $curl_timeout"
        fi
    fi

    # Temp dir: use $TMPDIR (Termux) or /tmp
    local _tmpdir="${TMPDIR:-/tmp}"
    local _cancel_file="$_tmpdir/.lodge-cancel-$$"

    # Stream tokens to stdout AND /dev/tty (so user sees output even inside $())
    # Start a spinner that shows during prefill (killed on first token)
    _LLM_ACTIVE=1
    local _llm_spinner_pid=""
    local _llm_ft_file="$_tmpdir/.lodge-ft-$$"
    rm -f "$_llm_ft_file"
    ui_spinner_start "Thinking"
    _llm_spinner_pid="$_SPINNER_PID"

    # Determine TTY for visible output (even inside $() captures)
    local _tty="/dev/tty"
    [ -w /dev/tty ] 2>/dev/null || _tty="/dev/stderr"

    $timeout_cmd curl -sf --connect-timeout 10 --max-time "$curl_timeout" \
        "$OLLAMA_URL/api/generate" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null | while IFS= read -r line; do
        # Check for cancellation
        [ -f "$_cancel_file" ] && break
        local token
        token=$(echo "$line" | jq -r '.response // empty' 2>/dev/null)
        if [ -n "$token" ]; then
            # Kill spinner on first real token (thinking or otherwise)
            if [ ! -f "$_llm_ft_file" ]; then
                touch "$_llm_ft_file"
                kill "$_llm_spinner_pid" 2>/dev/null
                printf "\r%*s\r" 60 "" > "$_tty" 2>/dev/null
            fi

            # Track <think>...</think> blocks — stream based on LODGE_THINK_STREAM
            if [[ "$token" == *'<think>'* ]]; then
                _in_think_block=1
                if [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                    # Show thinking header + start style on tty
                    if [ "${LODGE_THINK_STREAM:-1}" -eq 2 ]; then
                        printf "\n\033[36m┌─ thinking ─\033[0m\n\033[36m" > "$_tty" 2>/dev/null
                    else
                        printf "\033[2m" > "$_tty" 2>/dev/null
                    fi
                fi
                continue
            fi
            if [[ "$token" == *'</think>'* ]]; then
                _in_think_block=0
                if [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                    if [ "${LODGE_THINK_STREAM:-1}" -eq 2 ]; then
                        printf "\033[0m\n\033[36m└────────────\033[0m\n" > "$_tty" 2>/dev/null
                    else
                        printf "\033[0m\n" > "$_tty" 2>/dev/null
                    fi
                fi
                continue
            fi
            if [ "${_in_think_block:-0}" -eq 1 ]; then
                # Stream thinking tokens to tty only — don't capture in response
                if [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                    printf "%s" "$token" > "$_tty" 2>/dev/null
                fi
                continue
            fi

            # Normal token — capture AND display
            printf "%s" "$token"
            printf "%s" "$token" > "$_tty" 2>/dev/null
        fi
        # Check if done
        local done_flag
        done_flag=$(echo "$line" | jq -r '.done // empty' 2>/dev/null)
        if [ "$done_flag" = "true" ]; then
            # Extract token counts from the final streaming response
            if [ "${LODGE_DEBUG:-0}" -eq 1 ]; then
                local _dbg_in _dbg_out
                _dbg_in=$(echo "$line" | jq -r '.prompt_eval_count // 0' 2>/dev/null)
                _dbg_out=$(echo "$line" | jq -r '.eval_count // 0' 2>/dev/null)
                _llm_debug_end_timer "stream" "$_dbg_in" "$_dbg_out"
            fi
            echo ""  # final newline for captured output
            echo "" > "$_tty" 2>/dev/null
            break
        fi
    done

    # Safety: ensure spinner is stopped even if no tokens arrived (timeout/error)
    ui_spinner_stop
    rm -f "$_llm_ft_file"
    _LLM_ACTIVE=0

    # Propagate cancellation: if the cancel file exists, return error so
    # the calling loop (agent_inner_loop) can detect and break immediately
    # instead of treating truncated output as a valid LLM response.
    if [ -f "$_cancel_file" ]; then
        return 1
    fi
}

# ── Chat format (multi-turn via /api/chat) ─────────────────────
# Usage: llm_chat "messages_json" [system_prompt]
# messages_json: [{"role":"user","content":"..."},...]
llm_chat() {
    local messages="$1"
    local system="${2:-}"
    local payload

    # Qwen3 thinking mode control: append /nothink to last user message
    if [ "${LODGE_THINK:-0}" -eq 0 ]; then
        messages=$(echo "$messages" | jq '
            if (. | length) > 0 then
                .[-1].content += " /nothink"
            else . end')
    fi

    if [ -n "$system" ]; then
        payload=$(jq -n \
            --arg model "$LODGE_MODEL" \
            --argjson messages "$messages" \
            --arg system "$system" \
            --arg keep_alive "$LLM_KEEP_ALIVE" \
            --argjson num_predict "$LLM_MAX_TOKENS" \
            '{model: $model, messages: ([{role:"system",content:$system}] + $messages), stream: false, keep_alive: $keep_alive, options: {num_predict: $num_predict}}')
    else
        payload=$(jq -n \
            --arg model "$LODGE_MODEL" \
            --argjson messages "$messages" \
            --arg keep_alive "$LLM_KEEP_ALIVE" \
            --argjson num_predict "$LLM_MAX_TOKENS" \
            '{model: $model, messages: $messages, stream: false, keep_alive: $keep_alive, options: {num_predict: $num_predict}}')
    fi

    # Build timeout args
    local timeout_args=()
    if [ "$LLM_TIMEOUT" -gt 0 ] 2>/dev/null; then
        timeout_args=(--max-time "$LLM_TIMEOUT")
    fi

    _LLM_ACTIVE=1
    local response
    response=$(curl -sf "${timeout_args[@]}" \
        "$OLLAMA_URL/api/chat" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)
    local chat_exit=$?
    _LLM_ACTIVE=0

    if [ $chat_exit -ne 0 ]; then
        echo "ERROR: Chat request failed"
        return 1
    fi

    # Strip <think>...</think> from Qwen3 thinking mode
    echo "$response" | jq -r '.message.content // "ERROR: Empty response"' | sed 's/<think>.*<\/think>//g; s/<think>[^<]*$//g'
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
