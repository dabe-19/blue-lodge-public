#!/bin/bash
# ── George: LLM Interface ─────────────────────────────────
# Direct Ollama API wrapper. No proxy needed.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Config ─────────────────────────────────────────────────────
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
LODGE_MODEL="${LODGE_MODEL:-blue-lodge}"
LLM_MAX_TOKENS="${LLM_MAX_TOKENS:-20480}"   # Default max output tokens (matches Modelfile num_predict ceiling)
LLM_ASK_TOKENS="${LLM_ASK_TOKENS:-20480}"   # Max output tokens for /ask (model stops at <|im_end|>; this is just a safety cap)
LLM_AGENT_TOKENS="${LLM_AGENT_TOKENS:-20480}" # Max output tokens for agent specialist/strategist
LLM_ROUTER_TOKENS="${LLM_ROUTER_TOKENS:-256}" # Max output tokens for agent router (think ~100-200 + tool name)
LLM_BUDGET_TOKENS="${LLM_BUDGET_TOKENS:-1024}" # Max thinking tokens before responding (0=unlimited)
LLM_BUDGET_ASK="${LLM_BUDGET_ASK:-1024}"     # Think budget for /ask conversations (extended thinking useful)
LLM_BUDGET_AGENT="${LLM_BUDGET_AGENT:-512}"  # Think budget for strategist/specialist (focused output)
LLM_BUDGET_ROUTER="${LLM_BUDGET_ROUTER:-128}" # Think budget for router (just pick a tool name)
LLM_BUDGET_JOURNAL="${LLM_BUDGET_JOURNAL:-64}" # Think budget for journal (background utility, fast)
LLM_BUDGET_TOOL="${LLM_BUDGET_TOOL:-256}"    # Think budget for tools (commit, web, recall, slash)
LLM_TIMEOUT="${LLM_TIMEOUT:-600}"           # Safety net: 600s max per request (thinking models on ARM need headroom; Ctrl+C also works)
LLM_KEEP_ALIVE="${LLM_KEEP_ALIVE:-30m}"     # How long model stays loaded after last request
LODGE_THINK="${LODGE_THINK:-1}"               # 1=show thinking tokens dimmed (default), 0=hide thinking tokens (model always thinks)
LODGE_THINK_STREAM="${LODGE_THINK_STREAM:-1}"  # When LODGE_THINK=1: 0=hide thinking, 1=show dimmed, 2=show bright (cyan)
LODGE_DEBUG="${LODGE_DEBUG:-0}"                 # 0=normal, 1=show timers + token counts per LLM call

# ── Debug tracking state ───────────────────────────────────────
# File-based counters survive $() subshells (shell vars don't).
_LLM_DEBUG_DIR="${TMPDIR:-/tmp}/.lodge-debug-$$"
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
# Safe to call — does not affect GEORGE.md or journal persistence.
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
        '{model: $model, prompt: "Hello", stream: false, keep_alive: $keep_alive, options: {num_predict: 1}}')
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
    # Write per-call record to file — survives $() subshells
    mkdir -p "$_LLM_DEBUG_DIR" 2>/dev/null
    local _in_n=0 _out_n=0
    [[ "$input_tok" =~ ^[0-9]+$ ]] && _in_n="$input_tok"
    [[ "$output_tok" =~ ^[0-9]+$ ]] && _out_n="$output_tok"
    echo "$_in_n $_out_n" >> "$_LLM_DEBUG_DIR/calls.log" 2>/dev/null
    _llm_debug_print "${label}: ${elapsed_s}s | in:${input_tok} out:${output_tok} tok"
}

# Reset debug counters at task start
llm_debug_reset() {
    rm -rf "$_LLM_DEBUG_DIR" 2>/dev/null
    mkdir -p "$_LLM_DEBUG_DIR" 2>/dev/null
    _LLM_DEBUG_TASK_START=$(date +%s)
}

# Print task-level debug summary (reads file-based counters)
llm_debug_summary() {
    [ "${LODGE_DEBUG:-0}" -eq 0 ] && return
    local now _calls _total_in _total_out
    now=$(date +%s)
    local total_s=$(( now - ${_LLM_DEBUG_TASK_START:-$now} ))
    # Sum from the file-based log
    _calls=0; _total_in=0; _total_out=0
    if [ -f "$_LLM_DEBUG_DIR/calls.log" ]; then
        while read -r _in _out; do
            _calls=$((_calls + 1))
            _total_in=$((_total_in + _in))
            _total_out=$((_total_out + _out))
        done < "$_LLM_DEBUG_DIR/calls.log"
    fi
    local _tty="/dev/tty"
    [ -w /dev/tty ] 2>/dev/null || _tty="/dev/stderr"
    printf "\n %b── Debug Summary ──────────────────────────────%b\n" "$C_DIM" "$C_RESET" > "$_tty" 2>/dev/null
    printf " %b  LLM calls:     %d%b\n" "$C_DIM" "$_calls" "$C_RESET" > "$_tty" 2>/dev/null
    printf " %b  Total input:   %d tokens%b\n" "$C_DIM" "$_total_in" "$C_RESET" > "$_tty" 2>/dev/null
    printf " %b  Total output:  %d tokens%b\n" "$C_DIM" "$_total_out" "$C_RESET" > "$_tty" 2>/dev/null
    printf " %b  Wall time:     %ds%b\n" "$C_DIM" "$total_s" "$C_RESET" > "$_tty" 2>/dev/null
    printf " %b──────────────────────────────────────────────%b\n" "$C_DIM" "$C_RESET" > "$_tty" 2>/dev/null
    # Cleanup
    rm -rf "$_LLM_DEBUG_DIR" 2>/dev/null
}

# ── Generate (internally streamed) ─────────────────────────────
# Usage: llm_generate "prompt" [system_prompt] [max_tokens]
#
# Uses stream:true internally to avoid the thinking-model blocking
# problem: with stream:false, Ollama buffers ALL computation
# (thinking + response) before sending any bytes. On constrained
# hardware this easily exceeds --max-time → exit 28, 0 tokens.
# With stream:true, tokens arrive continuously keeping the
# connection alive. Response tokens go to stdout (captured by
# the caller's $()). Thinking tokens go to /dev/tty when enabled.
# Usage: llm_generate "prompt" [system_prompt] [max_tokens] [budget_tokens]
llm_generate() {
    local prompt="$1"
    local system="${2:-}"
    local max_tokens="${3:-$LLM_MAX_TOKENS}"
    local budget="${4:-$LLM_BUDGET_TOKENS}"
    local payload

    _llm_debug_start_timer

    # Build options with optional budget_tokens
    local _opts
    if [ "${budget:-0}" -gt 0 ] 2>/dev/null; then
        _opts=$(jq -n --argjson np "$max_tokens" --argjson bt "$budget" '{num_predict:$np, budget_tokens:$bt}')
    else
        _opts=$(jq -n --argjson np "$max_tokens" '{num_predict:$np}')
    fi

    if [ -n "$system" ]; then
        payload=$(jq -n \
            --arg model "$LODGE_MODEL" \
            --arg prompt "$prompt" \
            --arg system "$system" \
            --arg keep_alive "$LLM_KEEP_ALIVE" \
            --argjson options "$_opts" \
            '{model: $model, prompt: $prompt, system: $system, stream: true, keep_alive: $keep_alive, options: $options}')
    else
        payload=$(jq -n \
            --arg model "$LODGE_MODEL" \
            --arg prompt "$prompt" \
            --arg keep_alive "$LLM_KEEP_ALIVE" \
            --argjson options "$_opts" \
            '{model: $model, prompt: $prompt, stream: true, keep_alive: $keep_alive, options: $options}')
    fi

    local curl_timeout="${LLM_TIMEOUT:-600}"
    local timeout_cmd=""
    if [ "$curl_timeout" -gt 0 ] 2>/dev/null; then
        if command -v timeout &>/dev/null; then
            timeout_cmd="timeout $curl_timeout"
        fi
    fi

    _LLM_ACTIVE=1

    local _tty="/dev/tty"
    [ -w /dev/tty ] 2>/dev/null || _tty="/dev/stderr"

    # Marker file: touched inside the pipe subshell when first token
    # arrives. If missing after the pipe, the request failed entirely.
    local _tmpdir="${TMPDIR:-/tmp}"
    local _got_tokens="$_tmpdir/.lodge-gen-tok-$$"
    rm -f "$_got_tokens"

    # Cancel file for cooperative cancellation from agent loops
    local _cancel_file="$_tmpdir/.lodge-cancel-$$"

    # Thinking display state (same auto-detection as llm_stream)
    local _saw_thinking_field=0
    local _think_banner_open=0
    local _in_think_block=1
    local _think_pending=""

    $timeout_cmd curl -sfN --connect-timeout 10 --max-time "$curl_timeout" \
        "$OLLAMA_URL/api/generate" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null | while IFS= read -r line; do
        # Cooperative cancellation check
        [ -f "$_cancel_file" ] && break

        local think_token token
        think_token=$(echo "$line" | jq -r '.thinking // empty' 2>/dev/null)
        token=$(echo "$line" | jq -r '.response // empty' 2>/dev/null)

        # ── Handle .thinking field (Ollama separate-field mode) ──
        if [ -n "$think_token" ]; then
            _saw_thinking_field=1
            [ -f "$_got_tokens" ] || touch "$_got_tokens"
            # Kill any external spinner on first think token
            if [ -n "$_SPINNER_PID" ] && kill -0 "$_SPINNER_PID" 2>/dev/null; then
                kill "$_SPINNER_PID" 2>/dev/null
                printf "\r%*s\r" 60 "" > "$_tty" 2>/dev/null
            fi
            # Show thinking to tty (never captured to stdout)
            if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                if [ "$_think_banner_open" -eq 0 ]; then
                    _think_banner_open=1
                    local _c; [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && _c="\033[36m" || _c="\033[90m"
                    printf "\n%b┌─ thinking ─\033[0m\n%b" "$_c" "$_c" > "$_tty" 2>/dev/null
                fi
                printf "%s" "$think_token" > "$_tty" 2>/dev/null
            fi
        fi

        # ── Handle .response field ───────────────────────────────
        if [ -n "$token" ]; then
            [ -f "$_got_tokens" ] || touch "$_got_tokens"
            # Kill any external spinner on first response token
            if [ -n "$_SPINNER_PID" ] && kill -0 "$_SPINNER_PID" 2>/dev/null; then
                kill "$_SPINNER_PID" 2>/dev/null
                printf "\r%*s\r" 60 "" > "$_tty" 2>/dev/null
            fi

            if [ "$_saw_thinking_field" -eq 1 ]; then
                # ── Separate-field mode: .response is clean content ──
                if [ "$_think_banner_open" -eq 1 ]; then
                    _think_banner_open=0
                    if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                        local _c; [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && _c="\033[36m" || _c="\033[90m"
                        printf "\033[0m\n%b└────────────\033[0m\n" "$_c" > "$_tty" 2>/dev/null
                    fi
                fi
                # Emit response to stdout only (captured by caller's $())
                printf "%s" "$token"
            else
                # ── Inline-tag fallback mode ──
                if [ "$_think_banner_open" -eq 0 ] && [ "$_in_think_block" -eq 1 ]; then
                    if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                        _think_banner_open=1
                        local _c; [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && _c="\033[36m" || _c="\033[90m"
                        printf "\n%b┌─ thinking ─\033[0m\n%b" "$_c" "$_c" > "$_tty" 2>/dev/null
                    fi
                fi

                if [ "$_in_think_block" -eq 1 ]; then
                    _think_pending+="$token"
                    if [[ "$_think_pending" == *"</think>"* ]]; then
                        local _think_before="${_think_pending%%</think>*}"
                        local _after_think="${_think_pending#*</think>}"
                        if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                            [ -n "$_think_before" ] && printf "%s" "$_think_before" > "$_tty" 2>/dev/null
                            _think_banner_open=0
                            local _c; [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && _c="\033[36m" || _c="\033[90m"
                            printf "\033[0m\n%b└────────────\033[0m\n" "$_c" > "$_tty" 2>/dev/null
                        fi
                        _in_think_block=0
                        _think_pending=""
                        [ -n "$_after_think" ] && printf "%s" "$_after_think"
                        continue
                    fi
                    # Flush safe prefix, keep tail for split </think> detection
                    local _plen=${#_think_pending}
                    if [ "$_plen" -gt 7 ]; then
                        local _flen=$((_plen - 7))
                        local _ftxt="${_think_pending:0:_flen}"
                        _think_pending="${_think_pending:_flen}"
                        if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                            [ -n "$_ftxt" ] && printf "%s" "$_ftxt" > "$_tty" 2>/dev/null
                        fi
                    fi
                    continue
                fi
                # Normal response token after </think>
                printf "%s" "$token"
            fi
        fi

        # ── Check if stream is done ──────────────────────────────
        local done_flag
        done_flag=$(echo "$line" | jq -r '.done // empty' 2>/dev/null)
        if [ "$done_flag" = "true" ]; then
            # Close thinking banner if still open
            if [ "$_think_banner_open" -eq 1 ]; then
                if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                    local _c; [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && _c="\033[36m" || _c="\033[90m"
                    printf "\033[0m\n%b└────────────\033[0m\n" "$_c" > "$_tty" 2>/dev/null
                fi
            fi
            # Flush pending think text as response if </think> never arrived
            if [ "$_in_think_block" -eq 1 ] && [ -n "$_think_pending" ]; then
                printf "%s" "$_think_pending"
            fi
            # Debug: extract token counts from the final streaming JSON
            if [ "${LODGE_DEBUG:-0}" -eq 1 ]; then
                local _dbg_in _dbg_out
                _dbg_in=$(echo "$line" | jq -r '.prompt_eval_count // 0' 2>/dev/null)
                _dbg_out=$(echo "$line" | jq -r '.eval_count // 0' 2>/dev/null)
                _llm_debug_end_timer "generate" "$_dbg_in" "$_dbg_out"
            fi
            break
        fi
    done

    _LLM_ACTIVE=0

    # Check if we received any tokens at all
    if [ ! -f "$_got_tokens" ]; then
        rm -f "$_got_tokens"
        echo "ERROR: LLM request failed or returned no tokens"
        return 1
    fi
    rm -f "$_got_tokens"
}

# ── Generate with streaming (live output) ──────────────────────
# Usage: llm_stream "prompt" [system_prompt] [max_tokens] [budget_tokens]
llm_stream() {
    local prompt="$1"
    local system="${2:-}"
    local max_tokens="${3:-$LLM_MAX_TOKENS}"
    local budget="${4:-$LLM_BUDGET_TOKENS}"
    local payload
    local full_response=""

    _llm_debug_start_timer

    # Thinking-only model: no /nothink or /think suffixes needed.
    # The model always thinks — LODGE_THINK controls display only.

    # Build options with optional budget_tokens
    local _opts
    if [ "${budget:-0}" -gt 0 ] 2>/dev/null; then
        _opts=$(jq -n --argjson np "$max_tokens" --argjson bt "$budget" '{num_predict:$np, budget_tokens:$bt}')
    else
        _opts=$(jq -n --argjson np "$max_tokens" '{num_predict:$np}')
    fi

    if [ -n "$system" ]; then
        payload=$(jq -n \
            --arg model "$LODGE_MODEL" \
            --arg prompt "$prompt" \
            --arg system "$system" \
            --arg keep_alive "$LLM_KEEP_ALIVE" \
            --argjson options "$_opts" \
            '{model: $model, prompt: $prompt, system: $system, stream: true, keep_alive: $keep_alive, options: $options}')
    else
        payload=$(jq -n \
            --arg model "$LODGE_MODEL" \
            --arg prompt "$prompt" \
            --arg keep_alive "$LLM_KEEP_ALIVE" \
            --argjson options "$_opts" \
            '{model: $model, prompt: $prompt, stream: true, keep_alive: $keep_alive, options: $options}')
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

    # ── Think display helpers ─────────────────────────────────────
    # Both modes get the same ┌─ thinking ─ / └──────────── structure.
    # Bright (2) = cyan, Dimmed (1) = gray (SGR 90, widely supported).
    # Extracted so every open/close site is consistent.
    _think_color() {
        [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && printf "\033[36m" || printf "\033[90m"
    }
    _think_open() {
        [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ] || return
        local _c; _c=$(_think_color)
        printf "\n%s┌─ thinking ─\033[0m\n%s" "$_c" "$_c" > "$_tty" 2>/dev/null
    }
    _think_close() {
        [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ] || return
        local _c; _c=$(_think_color)
        printf "\033[0m\n%s└────────────\033[0m\n" "$_c" > "$_tty" 2>/dev/null
    }
    _think_show() {
        [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ] || return
        printf "%s" "$1" > "$_tty" 2>/dev/null
    }

    # ── Thinking detection modes ──────────────────────────────────
    # Modern Ollama (0.9+) sends thinking tokens in a separate .thinking
    # JSON field. Older versions / some models embed <think>...</think>
    # tags inline in .response. We auto-detect which mode we're in:
    #   _saw_thinking_field=1 → separate-field mode (preferred)
    #   _saw_thinking_field=0 → inline-tag fallback mode
    local _saw_thinking_field=0
    local _think_banner_open=0
    local _in_think_block=1       # fallback mode: assume starts in think
    local _think_pending=""       # fallback mode: buffer for split </think>

    $timeout_cmd curl -sfN --connect-timeout 10 --max-time "$curl_timeout" \
        "$OLLAMA_URL/api/generate" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null | while IFS= read -r line; do
        # Check for cancellation
        [ -f "$_cancel_file" ] && break

        local think_token token
        think_token=$(echo "$line" | jq -r '.thinking // empty' 2>/dev/null)
        token=$(echo "$line" | jq -r '.response // empty' 2>/dev/null)

        # ── Handle .thinking field (Ollama separate-field mode) ──
        if [ -n "$think_token" ]; then
            _saw_thinking_field=1
            # Kill spinner on first token of any kind
            if [ ! -f "$_llm_ft_file" ]; then
                touch "$_llm_ft_file"
                kill "$_llm_spinner_pid" 2>/dev/null
                printf "\r%*s\r" 60 "" > "$_tty" 2>/dev/null
            fi
            # Open thinking banner on first think token
            if [ "$_think_banner_open" -eq 0 ]; then
                _think_banner_open=1
                _think_open
            fi
            # Stream thinking token to tty only (never captured to stdout)
            _think_show "$think_token"
        fi

        # ── Handle .response field ───────────────────────────────
        if [ -n "$token" ]; then
            # Kill spinner on first token of any kind
            if [ ! -f "$_llm_ft_file" ]; then
                touch "$_llm_ft_file"
                kill "$_llm_spinner_pid" 2>/dev/null
                printf "\r%*s\r" 60 "" > "$_tty" 2>/dev/null
            fi

            if [ "$_saw_thinking_field" -eq 1 ]; then
                # ── Separate-field mode ──
                # .response tokens are always actual response content.
                # Close thinking banner if it was open.
                if [ "$_think_banner_open" -eq 1 ]; then
                    _think_banner_open=0
                    _think_close
                fi
                # Emit response token — capture to stdout AND display on tty
                printf "%s" "$token"
                printf "%s" "$token" > "$_tty" 2>/dev/null
            else
                # ── Inline-tag fallback mode ──
                # Thinking tokens are embedded in .response with </think> separator.
                # Open thinking banner on first token if not yet open
                if [ "$_think_banner_open" -eq 0 ] && [ "$_in_think_block" -eq 1 ]; then
                    _think_banner_open=1
                    _think_open
                fi

                if [ "$_in_think_block" -eq 1 ]; then
                    _think_pending+="$token"
                    # Check for </think> end tag (handles split across token boundaries)
                    if [[ "$_think_pending" == *"</think>"* ]]; then
                        local _think_before="${_think_pending%%</think>*}"
                        local _after_think="${_think_pending#*</think>}"
                        # Flush remaining think text
                        [ -n "$_think_before" ] && _think_show "$_think_before"
                        # Close thinking banner
                        _think_banner_open=0
                        _think_close
                        _in_think_block=0
                        _think_pending=""
                        # Emit any response text bundled with the </think> token
                        if [ -n "$_after_think" ]; then
                            printf "%s" "$_after_think"
                            printf "%s" "$_after_think" > "$_tty" 2>/dev/null
                        fi
                        continue
                    fi
                    # No end tag yet — flush safe prefix, keep tail for split-tag detection
                    local _plen=${#_think_pending}
                    if [ "$_plen" -gt 7 ]; then
                        local _flen=$((_plen - 7))
                        local _ftxt="${_think_pending:0:_flen}"
                        _think_pending="${_think_pending:_flen}"
                        [ -n "$_ftxt" ] && _think_show "$_ftxt"
                    fi
                    continue
                fi
                # Normal token after </think> in fallback mode
                printf "%s" "$token"
                printf "%s" "$token" > "$_tty" 2>/dev/null
            fi
        fi

        # ── Check if stream is done ──────────────────────────────
        local done_flag
        done_flag=$(echo "$line" | jq -r '.done // empty' 2>/dev/null)
        if [ "$done_flag" = "true" ]; then
            # Close thinking banner if still open at end of stream
            if [ "$_think_banner_open" -eq 1 ]; then
                _think_close
            fi
            # Fallback mode: flush any buffered text as response if </think> never arrived
            if [ "$_in_think_block" -eq 1 ] && [ -n "$_think_pending" ]; then
                printf "%s" "$_think_pending"
                printf "%s" "$_think_pending" > "$_tty" 2>/dev/null
            fi
            # Debug: extract token counts from the final streaming JSON
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
# Usage: llm_chat "messages_json" [system_prompt] [budget_tokens]
# messages_json: [{"role":"user","content":"..."},...]
#
# Internally streamed (same rationale as llm_generate) to avoid
# thinking-model timeout with stream:false.
llm_chat() {
    local messages="$1"
    local system="${2:-}"
    local budget="${3:-$LLM_BUDGET_TOKENS}"
    local payload

    # Build options with optional budget_tokens
    local _opts
    if [ "${budget:-0}" -gt 0 ] 2>/dev/null; then
        _opts=$(jq -n --argjson np "$LLM_MAX_TOKENS" --argjson bt "$budget" '{num_predict:$np, budget_tokens:$bt}')
    else
        _opts=$(jq -n --argjson np "$LLM_MAX_TOKENS" '{num_predict:$np}')
    fi

    if [ -n "$system" ]; then
        payload=$(jq -n \
            --arg model "$LODGE_MODEL" \
            --argjson messages "$messages" \
            --arg system "$system" \
            --arg keep_alive "$LLM_KEEP_ALIVE" \
            --argjson options "$_opts" \
            '{model: $model, messages: ([{role:"system",content:$system}] + $messages), stream: true, keep_alive: $keep_alive, options: $options}')
    else
        payload=$(jq -n \
            --arg model "$LODGE_MODEL" \
            --argjson messages "$messages" \
            --arg keep_alive "$LLM_KEEP_ALIVE" \
            --argjson options "$_opts" \
            '{model: $model, messages: $messages, stream: true, keep_alive: $keep_alive, options: $options}')
    fi

    local curl_timeout="${LLM_TIMEOUT:-600}"
    local timeout_cmd=""
    if [ "$curl_timeout" -gt 0 ] 2>/dev/null; then
        if command -v timeout &>/dev/null; then
            timeout_cmd="timeout $curl_timeout"
        fi
    fi

    _LLM_ACTIVE=1

    local _tmpdir="${TMPDIR:-/tmp}"
    local _got_tokens="$_tmpdir/.lodge-chat-tok-$$"
    rm -f "$_got_tokens"

    # Chat API uses .message.thinking and .message.content
    local _saw_thinking_field=0
    local _in_think_block=1
    local _think_pending=""

    $timeout_cmd curl -sfN --connect-timeout 10 --max-time "$curl_timeout" \
        "$OLLAMA_URL/api/chat" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null | while IFS= read -r line; do

        local think_token token
        think_token=$(echo "$line" | jq -r '.message.thinking // empty' 2>/dev/null)
        token=$(echo "$line" | jq -r '.message.content // empty' 2>/dev/null)

        if [ -n "$think_token" ]; then
            _saw_thinking_field=1
            [ -f "$_got_tokens" ] || touch "$_got_tokens"
            # Thinking tokens are discarded (caller only gets response)
        fi

        if [ -n "$token" ]; then
            [ -f "$_got_tokens" ] || touch "$_got_tokens"

            if [ "$_saw_thinking_field" -eq 1 ]; then
                printf "%s" "$token"
            else
                # Inline-tag fallback
                if [ "$_in_think_block" -eq 1 ]; then
                    _think_pending+="$token"
                    if [[ "$_think_pending" == *"</think>"* ]]; then
                        local _after_think="${_think_pending#*</think>}"
                        _in_think_block=0
                        _think_pending=""
                        [ -n "$_after_think" ] && printf "%s" "$_after_think"
                        continue
                    fi
                    local _plen=${#_think_pending}
                    if [ "$_plen" -gt 7 ]; then
                        _think_pending="${_think_pending:$((_plen - 7))}"
                    fi
                    continue
                fi
                printf "%s" "$token"
            fi
        fi

        local done_flag
        done_flag=$(echo "$line" | jq -r '.done // empty' 2>/dev/null)
        if [ "$done_flag" = "true" ]; then
            if [ "$_in_think_block" -eq 1 ] && [ -n "$_think_pending" ]; then
                printf "%s" "$_think_pending"
            fi
            break
        fi
    done

    _LLM_ACTIVE=0

    if [ ! -f "$_got_tokens" ]; then
        rm -f "$_got_tokens"
        echo "ERROR: Chat request failed"
        return 1
    fi
    rm -f "$_got_tokens"
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
