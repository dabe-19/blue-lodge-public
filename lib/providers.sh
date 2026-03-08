#!/bin/bash
# ── George: AI Provider Integrations ───────────────────────────
# Unified interface to call external LLM APIs. George can route
# queries to cloud providers when local Ollama is insufficient
# or when the user explicitly requests a specific model.

[ -n "${_LIB_PROVIDERS_LOADED:-}" ] && return 0; _LIB_PROVIDERS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/api.sh"

# ── Provider Harness ──────────────────────────────────────────
# When GEORGE_PROVIDER is set, ALL llm_generate/llm_stream/llm_chat
# calls route through the cloud provider API instead of llama.cpp/Ollama.
# Activate:  /provider use google        (or any configured provider)
# Deactivate: /provider use local

GEORGE_PROVIDER="${GEORGE_PROVIDER:-}"

# ── Provider timeout (longer for LLM calls) ───────────────────
PROVIDER_TIMEOUT="${PROVIDER_TIMEOUT:-120}"

# ── Rate-limit / metering config ──────────────────────────────
# Defaults are tuned for Google AI free-tier Gemma models (27B/14B):
#   RPM: 30 req/min  |  TPM: 15K tok/min  |  RPD: 14.4K req/day
# At 7s delay + 8 calls/window: ~8.6 req/min, ~12.3K req/day — safely under all three.
PROVIDER_MAX_RETRIES="${PROVIDER_MAX_RETRIES:-4}"        # Max retries on 429
PROVIDER_INITIAL_BACKOFF="${PROVIDER_INITIAL_BACKOFF:-5}" # Initial backoff secs
PROVIDER_MAX_BACKOFF="${PROVIDER_MAX_BACKOFF:-60}"        # Max backoff secs
PROVIDER_COOLDOWN_WINDOW="${PROVIDER_COOLDOWN_WINDOW:-60}" # Metering window (secs)
PROVIDER_COOLDOWN_MAX="${PROVIDER_COOLDOWN_MAX:-8}"        # Max calls per window
PROVIDER_CALL_DELAY="${PROVIDER_CALL_DELAY:-7}"            # Min gap (secs) between calls

# Metering state (file-based to survive subshells)
_PROVIDER_METER_DIR="${TMPDIR:-/tmp}/george-provider-meter.$$"

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

# ── Countdown timer ───────────────────────────────────────────
# Shows a ticking countdown so the user knows the wait is intentional.
# Usage: _provider_countdown seconds "label"
_provider_countdown() {
    local secs="$1" label="${2:-Waiting}"
    local _tty="/dev/tty"
    [ -w /dev/tty ] 2>/dev/null || _tty="/dev/stderr"
    if [ "$secs" -le 0 ] 2>/dev/null; then return; fi

    # Pause any active spinner so it doesn't fight for the terminal line
    local _had_spinner=0
    if [ -n "${_SPINNER_PID:-}" ]; then
        _had_spinner=1
        ui_spinner_stop 2>/dev/null
    fi

    local i="$secs"
    while [ "$i" -gt 0 ]; do
        local filled=$(( (secs - i) * 20 / secs ))
        local empty=$(( 20 - filled ))
        printf "\r %b[%b" "\033[90m" "\033[34m" > "$_tty" 2>/dev/null
        local j=0; while [ $j -lt $filled ]; do printf '█' > "$_tty" 2>/dev/null; j=$((j+1)); done
        j=0; while [ $j -lt $empty ]; do printf '░' > "$_tty" 2>/dev/null; j=$((j+1)); done
        printf "%b] %b%s: %ds%b " "\033[90m" "\033[37m" "$label" "$i" "\033[0m" > "$_tty" 2>/dev/null
        sleep 1
        i=$((i - 1))
    done
    printf "\r%*s\r" 60 "" > "$_tty" 2>/dev/null
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

# ── Call metering ─────────────────────────────────────────────
# Track provider API calls within a rolling window.  Logs are
# written to temp files so they survive $(…) subshells.

_provider_meter_init() {
    mkdir -p "$_PROVIDER_METER_DIR" 2>/dev/null
}

# Record that a call just happened
_provider_meter_tick() {
    _provider_meter_init
    date +%s >> "$_PROVIDER_METER_DIR/calls" 2>/dev/null
}

# Count calls inside the current window
_provider_meter_count() {
    _provider_meter_init
    local now cutoff
    now=$(date +%s)
    cutoff=$((now - PROVIDER_COOLDOWN_WINDOW))
    if [ ! -f "$_PROVIDER_METER_DIR/calls" ]; then
        echo 0
        return
    fi
    awk -v c="$cutoff" '$1 >= c' "$_PROVIDER_METER_DIR/calls" 2>/dev/null | wc -l
}

# If near the limit, sleep until the oldest call falls outside the window
_provider_meter_throttle() {
    local count
    count=$(_provider_meter_count)
    if [ "$count" -ge "$PROVIDER_COOLDOWN_MAX" ]; then
        local oldest now wait_s
        oldest=$(awk -v c="$(($(date +%s) - PROVIDER_COOLDOWN_WINDOW))" '$1 >= c' \
                 "$_PROVIDER_METER_DIR/calls" 2>/dev/null | head -1)
        now=$(date +%s)
        wait_s=$(( (oldest + PROVIDER_COOLDOWN_WINDOW) - now + 1 ))
        [ "$wait_s" -lt 1 ] && wait_s=1
        [ "$wait_s" -gt "$PROVIDER_MAX_BACKOFF" ] && wait_s="$PROVIDER_MAX_BACKOFF"
        ui_warn "Provider rate-limit cooldown: pausing ${wait_s}s ($count calls in ${PROVIDER_COOLDOWN_WINDOW}s window)"
        _provider_countdown "$wait_s" "Cooldown"
        # Prune old entries
        local cutoff
        cutoff=$(($(date +%s) - PROVIDER_COOLDOWN_WINDOW))
        local tmpf; tmpf=$(mktemp)
        awk -v c="$cutoff" '$1 >= c' "$_PROVIDER_METER_DIR/calls" > "$tmpf" 2>/dev/null
        mv "$tmpf" "$_PROVIDER_METER_DIR/calls" 2>/dev/null
    fi
}

# Clean up meter (called on exit or /provider use local)
_provider_meter_reset() {
    rm -rf "$_PROVIDER_METER_DIR" 2>/dev/null
}

# ── Inter-call delay ──────────────────────────────────────────
# Enforces a minimum gap between provider API calls.  The last-call
# timestamp lives in _PROVIDER_METER_DIR so it survives subshells.

_provider_inter_call_delay() {
    [ "${PROVIDER_CALL_DELAY:-0}" -le 0 ] 2>/dev/null && return
    _provider_meter_init
    local last_file="$_PROVIDER_METER_DIR/last_call"
    if [ -f "$last_file" ]; then
        local last now elapsed remaining
        last=$(cat "$last_file" 2>/dev/null)
        now=$(date +%s)
        elapsed=$((now - last))
        remaining=$((PROVIDER_CALL_DELAY - elapsed))
        if [ "$remaining" -gt 0 ]; then
            _provider_countdown "$remaining" "API delay"
        fi
    fi
    # Stamp is written by _provider_call_with_backoff after the call
}

_provider_stamp_last_call() {
    _provider_meter_init
    date +%s > "$_PROVIDER_METER_DIR/last_call" 2>/dev/null
}

# ── Retry with exponential backoff ────────────────────────────
# Wraps provider_chat with rate-limit awareness.  On 429 (returned
# as exit-code 2 from api_request, or detected in the response body)
# it backs off exponentially.  On other failures it returns immediately.
#
# Usage: _provider_call_with_backoff provider message model system
_provider_call_with_backoff() {
    local provider="$1" message="$2" model="${3:-}" system="${4:-}"
    local attempt=0 delay="$PROVIDER_INITIAL_BACKOFF"
    local max="$PROVIDER_MAX_RETRIES"
    local resp rc

    while [ "$attempt" -le "$max" ]; do
        # Pre-flight: inter-call delay + meter throttle
        _provider_inter_call_delay
        _provider_meter_throttle

        # Record the call
        _provider_meter_tick

        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] provider/$provider: calling API..." >/dev/tty 2>/dev/null
        resp=$(provider_chat "$provider" "$message" "$model" "$system" 2>&1)
        rc=$?

        if [ $rc -eq 0 ] && [ -n "$resp" ]; then
            _provider_stamp_last_call
            echo "$resp"
            return 0
        fi

        # Detect rate limiting — either exit code 2 (from api_request) or
        # keywords in the error body (some providers return 200 with error JSON)
        local is_rate_limit=0
        if [ "$rc" -eq 2 ]; then
            is_rate_limit=1
        elif echo "$resp" | grep -qiE "rate.limit|quota.*exceed|too.many.request|429|retry.in"; then
            is_rate_limit=1
        fi

        if [ "$is_rate_limit" -eq 0 ]; then
            # Non-rate-limit error — don't retry, emit whatever provider_chat said
            echo "$resp" >&2
            return $rc
        fi

        attempt=$((attempt + 1))
        if [ "$attempt" -gt "$max" ]; then
            ui_err "Provider rate limit: gave up after $max retries"
            return 1
        fi

        # Parse "retry in Xs" hint from Google/etc if available
        local hint_wait
        hint_wait=$(echo "$resp" | grep -oiP 'retry\s+in\s+\K[0-9]+(\.[0-9]+)?' | head -1)
        if [ -n "$hint_wait" ]; then
            # Round up the hint
            delay=$(printf '%.0f' "$hint_wait" 2>/dev/null || echo "$delay")
            [ "$delay" -lt 1 ] && delay=1
        fi
        [ "$delay" -gt "$PROVIDER_MAX_BACKOFF" ] && delay="$PROVIDER_MAX_BACKOFF"

        ui_warn "Rate limited — retry ${attempt}/${max} in ${delay}s"
        _provider_countdown "$delay" "Backoff"
        delay=$((delay * 2))
    done
    return 1
}

# ── Streaming-aware backoff wrapper ──────────────────────────
# Like _provider_call_with_backoff but uses provider_stream_chat
# for real-time token output.  Falls back to sync on failure.
# Output: tokens stream to both stdout and /dev/tty.
_provider_stream_with_backoff() {
    local provider="$1" message="$2" model="${3:-}" system="${4:-}"
    local attempt=0 delay="$PROVIDER_INITIAL_BACKOFF"
    local max="$PROVIDER_MAX_RETRIES"
    local resp rc

    while [ "$attempt" -le "$max" ]; do
        _provider_inter_call_delay
        _provider_meter_throttle
        _provider_meter_tick

        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] provider/$provider: streaming API call..." >/dev/tty 2>/dev/null
        resp=$(provider_stream_chat "$provider" "$message" "$model" "$system")
        rc=$?

        if [ $rc -eq 0 ] && [ -n "$resp" ]; then
            _provider_stamp_last_call
            # Content already streamed to tty by the SSE loop — echo for capture
            echo "$resp"
            return 0
        fi

        local is_rate_limit=0
        if [ "$rc" -eq 2 ]; then
            is_rate_limit=1
        elif echo "$resp" | grep -qiE "rate.limit|quota.*exceed|too.many.request|429|retry.in"; then
            is_rate_limit=1
        fi

        [ "$is_rate_limit" -eq 0 ] && { echo "$resp" >&2; return $rc; }

        attempt=$((attempt + 1))
        [ "$attempt" -gt "$max" ] && { ui_err "Provider rate limit: gave up after $max retries"; return 1; }

        local hint_wait
        hint_wait=$(echo "$resp" | grep -oiP 'retry\s+in\s+\K[0-9]+(\.[0-9]+)?' | head -1)
        if [ -n "$hint_wait" ]; then
            delay=$(printf '%.0f' "$hint_wait" 2>/dev/null || echo "$delay")
            [ "$delay" -lt 1 ] && delay=1
        fi
        [ "$delay" -gt "$PROVIDER_MAX_BACKOFF" ] && delay="$PROVIDER_MAX_BACKOFF"

        ui_warn "Rate limited — retry ${attempt}/${max} in ${delay}s"
        _provider_countdown "$delay" "Backoff"
        delay=$((delay * 2))
    done
    return 1
}

# ═══════════════════════════════════════════════════════════════
# Provider Streaming Infrastructure
# ═══════════════════════════════════════════════════════════════
# SSE-based streaming for cloud provider APIs.  Tokens are emitted
# to a callback as they arrive, with optional thinking-block support.
#
# Token extraction varies by provider family:
#   OpenAI-compat: .choices[0].delta.content  (+ .reasoning_content for DeepSeek)
#   Anthropic:     content_block_delta events with .delta.text / .delta.thinking
#   Google:        .candidates[0].content.parts[0].text
#   Cohere:        .text in text-generation events

# ── Generic SSE read loop ─────────────────────────────────────
# Reads SSE lines from a FIFO, extracts tokens via a provider-specific
# jq filter, and calls callbacks for content and thinking tokens.
#
# Usage: _provider_sse_loop FIFO CURL_PID content_jq [think_jq] [done_match]
#   content_jq: jq expression to extract content delta from an SSE data line
#   think_jq:   jq expression to extract thinking delta (optional, "" to skip)
#   done_match: string that signals end-of-stream (default: "[DONE]")
#
# Output: content tokens to stdout, thinking tokens to /dev/tty (dimmed)
_provider_sse_loop() {
    local fifo="$1" curl_pid="$2" content_jq="$3"
    local think_jq="${4:-}" done_match="${5:-[DONE]}"
    local _tty="/dev/tty"
    [ -w /dev/tty ] 2>/dev/null || _tty="/dev/stderr"

    local _in_think=0 _think_banner=0
    local _got_content=0
    local _idle_timeout=45  # seconds — safety net if sentinel is missed

    while IFS= read -t "$_idle_timeout" -r line || [ -n "$line" ]; do
        # Strip \r from CRLF line endings (common in HTTP SSE)
        line="${line%$'\r'}"

        # SSE format: "data: {...}"
        [[ "$line" == data:* ]] || continue
        local json="${line#data: }"
        json="${json#"${json%%[![:space:]]*}"}"  # trim leading whitespace

        # End-of-stream sentinel
        [ "$json" = "$done_match" ] && break

        # ── Think tokens ──
        if [ -n "$think_jq" ]; then
            local think_tok
            think_tok=$(echo "$json" | jq -r "$think_jq" 2>/dev/null)
            if [ -n "$think_tok" ] && [ "$think_tok" != "null" ]; then
                if [ "$_think_banner" -eq 0 ]; then
                    _think_banner=1; _in_think=1
                    if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                        local _c; [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && _c="\033[36m" || _c="\033[90m"
                        printf "\n%b┌─ thinking ─\033[0m\n%b" "$_c" "$_c" > "$_tty" 2>/dev/null
                    fi
                fi
                if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                    printf "%s" "$think_tok" > "$_tty" 2>/dev/null
                fi
                continue
            fi
        fi

        # ── Content tokens ──
        local tok
        tok=$(echo "$json" | jq -r "$content_jq" 2>/dev/null)
        if [ -n "$tok" ] && [ "$tok" != "null" ]; then
            # Close thinking banner if transitioning from think → content
            if [ "$_in_think" -eq 1 ] && [ "$_think_banner" -eq 1 ]; then
                _in_think=0; _think_banner=0
                if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                    local _c; [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && _c="\033[36m" || _c="\033[90m"
                    printf "\033[0m\n%b└────────────\033[0m\n" "$_c" > "$_tty" 2>/dev/null
                fi
            fi
            _got_content=1
            printf "%s" "$tok"
            printf "%s" "$tok" > "$_tty" 2>/dev/null
        fi
    done < "$fifo"

    # Close unclosed thinking banner
    if [ "$_think_banner" -eq 1 ]; then
        if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
            local _c; [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && _c="\033[36m" || _c="\033[90m"
            printf "\033[0m\n%b└────────────\033[0m\n" "$_c" > "$_tty" 2>/dev/null
        fi
    fi

    kill "$curl_pid" 2>/dev/null
    wait "$curl_pid" 2>/dev/null 2>&1 || true

    [ "$_got_content" -eq 1 ] && return 0
    return 1
}

# ── Anthropic SSE loop (different event structure) ────────────
# Anthropic uses typed events: content_block_start, content_block_delta,
# message_delta, etc.  Thinking blocks have type "thinking".
_provider_anthropic_sse_loop() {
    local fifo="$1" curl_pid="$2"
    local _tty="/dev/tty"
    [ -w /dev/tty ] 2>/dev/null || _tty="/dev/stderr"

    local _in_think=0 _think_banner=0
    local _got_content=0
    local _event_type=""
    local _idle_timeout=45

    while IFS= read -t "$_idle_timeout" -r line || [ -n "$line" ]; do
        # Strip \r from CRLF line endings (common in HTTP SSE)
        line="${line%$'\r'}"

        # Track SSE event type
        if [[ "$line" == event:* ]]; then
            _event_type="${line#event: }"
            _event_type="${_event_type#"${_event_type%%[![:space:]]*}"}"
            continue
        fi
        [[ "$line" == data:* ]] || continue
        local json="${line#data: }"
        json="${json#"${json%%[![:space:]]*}"}"

        case "$_event_type" in
            content_block_start)
                local block_type
                block_type=$(echo "$json" | jq -r '.content_block.type // empty' 2>/dev/null)
                if [ "$block_type" = "thinking" ]; then
                    _in_think=1
                    if [ "$_think_banner" -eq 0 ]; then
                        _think_banner=1
                        if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                            local _c; [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && _c="\033[36m" || _c="\033[90m"
                            printf "\n%b┌─ thinking ─\033[0m\n%b" "$_c" "$_c" > "$_tty" 2>/dev/null
                        fi
                    fi
                else
                    if [ "$_in_think" -eq 1 ]; then
                        _in_think=0; _think_banner=0
                        if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                            local _c; [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && _c="\033[36m" || _c="\033[90m"
                            printf "\033[0m\n%b└────────────\033[0m\n" "$_c" > "$_tty" 2>/dev/null
                        fi
                    fi
                fi ;;
            content_block_delta)
                local tok
                tok=$(echo "$json" | jq -r '.delta.text // .delta.thinking // empty' 2>/dev/null)
                if [ -n "$tok" ]; then
                    if [ "$_in_think" -eq 1 ]; then
                        if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                            printf "%s" "$tok" > "$_tty" 2>/dev/null
                        fi
                    else
                        _got_content=1
                        printf "%s" "$tok"
                        printf "%s" "$tok" > "$_tty" 2>/dev/null
                    fi
                fi ;;
            message_stop) break ;;
        esac
    done < "$fifo"

    # Close unclosed thinking banner
    if [ "$_think_banner" -eq 1 ]; then
        if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
            local _c; [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && _c="\033[36m" || _c="\033[90m"
            printf "\033[0m\n%b└────────────\033[0m\n" "$_c" > "$_tty" 2>/dev/null
        fi
    fi

    kill "$curl_pid" 2>/dev/null
    wait "$curl_pid" 2>/dev/null 2>&1 || true

    [ "$_got_content" -eq 1 ] && return 0
    return 1
}

# ── Google SSE loop (array-based chunks) ──────────────────────
_provider_google_sse_loop() {
    local fifo="$1" curl_pid="$2"
    local _tty="/dev/tty"
    [ -w /dev/tty ] 2>/dev/null || _tty="/dev/stderr"
    local _got_content=0
    local _idle_timeout=45

    while IFS= read -t "$_idle_timeout" -r line || [ -n "$line" ]; do
        # Strip \r from CRLF line endings (common in HTTP SSE)
        line="${line%$'\r'}"

        [[ "$line" == data:* ]] || continue
        local json="${line#data: }"
        json="${json#"${json%%[![:space:]]*}"}"

        local tok
        tok=$(echo "$json" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null)
        if [ -n "$tok" ]; then
            _got_content=1
            printf "%s" "$tok"
            printf "%s" "$tok" > "$_tty" 2>/dev/null
        fi
    done < "$fifo"

    kill "$curl_pid" 2>/dev/null
    wait "$curl_pid" 2>/dev/null 2>&1 || true

    [ "$_got_content" -eq 1 ] && return 0
    return 1
}

# ── Cohere SSE loop ──────────────────────────────────────────
_provider_cohere_sse_loop() {
    local fifo="$1" curl_pid="$2"
    local _tty="/dev/tty"
    [ -w /dev/tty ] 2>/dev/null || _tty="/dev/stderr"
    local _got_content=0
    local _idle_timeout=45

    while IFS= read -t "$_idle_timeout" -r line || [ -n "$line" ]; do
        # Strip \r from CRLF line endings
        line="${line%$'\r'}"

        # Cohere sends NDJSON (one JSON per line, no "data:" prefix)
        [ -z "$line" ] && continue
        local event_type
        event_type=$(echo "$line" | jq -r '.event_type // empty' 2>/dev/null)
        case "$event_type" in
            text-generation)
                local tok
                tok=$(echo "$line" | jq -r '.text // empty' 2>/dev/null)
                if [ -n "$tok" ]; then
                    _got_content=1
                    printf "%s" "$tok"
                    printf "%s" "$tok" > "$_tty" 2>/dev/null
                fi ;;
            stream-end) break ;;
        esac
    done < "$fifo"

    kill "$curl_pid" 2>/dev/null
    wait "$curl_pid" 2>/dev/null 2>&1 || true

    [ "$_got_content" -eq 1 ] && return 0
    return 1
}

# ═══════════════════════════════════════════════════════════════
# Unified streaming dispatcher
# ═══════════════════════════════════════════════════════════════
# Streams tokens from a cloud provider.  Falls back to synchronous
# provider_chat if streaming fails.
#
# Usage: provider_stream_chat provider message [model] [system]
# Output: response tokens streamed to stdout + /dev/tty
provider_stream_chat() {
    local provider="$1" message="$2" model="${3:-}" system="${4:-}"

    local canon
    canon=$(_provider_canon "$provider")
    [ -z "$canon" ] && { provider_chat "$provider" "$message" "$model" "$system"; return $?; }

    local _tmpdir="${TMPDIR:-/tmp}"
    local _fifo="$_tmpdir/.lodge-provider-stream-$$"
    rm -f "$_fifo"
    mkfifo "$_fifo"

    local curl_pid resp_text

    case "$canon" in
        OPENAI|GROQ|MISTRAL|TOGETHER|PERPLEXITY|DEEPSEEK|XAI|COHERE)
            local key_name key url default_model
            case "$canon" in
                OPENAI)     key_name="OPENAI_API_KEY"; url="https://api.openai.com/v1/chat/completions"; default_model="gpt-4o-mini" ;;
                GROQ)       key_name="GROQ_API_KEY"; url="https://api.groq.com/openai/v1/chat/completions"; default_model="llama-3.3-70b-versatile" ;;
                MISTRAL)    key_name="MISTRAL_API_KEY"; url="https://api.mistral.ai/v1/chat/completions"; default_model="mistral-large-latest" ;;
                TOGETHER)   key_name="TOGETHER_API_KEY"; url="https://api.together.xyz/v1/chat/completions"; default_model="meta-llama/Llama-3.3-70B-Instruct-Turbo" ;;
                PERPLEXITY) key_name="PERPLEXITY_API_KEY"; url="https://api.perplexity.ai/chat/completions"; default_model="sonar" ;;
                DEEPSEEK)   key_name="DEEPSEEK_API_KEY"; url="https://api.deepseek.com/chat/completions"; default_model="deepseek-chat" ;;
                XAI)        key_name="XAI_API_KEY"; url="https://api.x.ai/v1/chat/completions"; default_model="grok-2" ;;
                COHERE)     key_name="COHERE_API_KEY"; url="https://api.cohere.com/v2/chat"; default_model="command-a-03-2025" ;;
            esac
            key=$(api_require_key "$key_name") || { rm -f "$_fifo"; return 1; }
            model=$(_provider_resolve_model "$model" "$provider" "$default_model")
            system="${system:-You are a helpful assistant.}"

            local data sys_role="system" _temp_clause='"temperature": 0.3,'
            # OpenAI o-series: developer role, no temperature
            if [ "$canon" = "OPENAI" ] && [[ "$model" == o1* || "$model" == o3* ]]; then
                sys_role="developer"; _temp_clause=""
            fi
            # DeepSeek reasoner: no temperature
            if [ "$canon" = "DEEPSEEK" ] && [[ "$model" == *reasoner* ]]; then
                _temp_clause=""
            fi
            data=$(jq -n --arg m "$model" --arg s "$system" --arg u "$message" --arg sr "$sys_role" \
                "{
                    \"model\": \$m,
                    \"messages\": [
                        {\"role\": \$sr, \"content\": \$s},
                        {\"role\": \"user\", \"content\": \$u}
                    ],
                    \"max_tokens\": 4096,
                    ${_temp_clause}
                    \"stream\": true
                }")

            curl_pid=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_stream_post \
                "$url" "$data" "$_fifo" \
                -H "Authorization: Bearer $key")

            # DeepSeek models may emit reasoning_content
            local think_jq=""
            [ "$canon" = "DEEPSEEK" ] && think_jq='.choices[0].delta.reasoning_content // empty'

            resp_text=$(_provider_sse_loop "$_fifo" "$curl_pid" \
                '.choices[0].delta.content // empty' "$think_jq") ;;

        ANTHROPIC)
            local key
            key=$(api_require_key "ANTHROPIC_API_KEY") || { rm -f "$_fifo"; return 1; }
            model=$(_provider_resolve_model "$model" "$provider" "claude-sonnet-4-20250514")
            system="${system:-You are a helpful assistant.}"

            local data
            data=$(jq -n --arg m "$model" --arg s "$system" --arg u "$message" '{
                "model": $m,
                "max_tokens": 4096,
                "system": $s,
                "messages": [{"role": "user", "content": $u}],
                "stream": true
            }')

            curl_pid=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_stream_post \
                "https://api.anthropic.com/v1/messages" "$data" "$_fifo" \
                -H "x-api-key: $key" \
                -H "anthropic-version: 2023-06-01")

            resp_text=$(_provider_anthropic_sse_loop "$_fifo" "$curl_pid") ;;

        GOOGLE)
            local key
            key=$(api_require_key "GOOGLE_AI_API_KEY") || { rm -f "$_fifo"; return 1; }
            model=$(_provider_resolve_model "$model" "$provider" "gemma-3-27b-it")

            local data
            if [ -n "$system" ] && ! _google_needs_system_workaround "$model"; then
                data=$(jq -n --arg s "$system" --arg u "$message" '{
                    "systemInstruction": {"parts": [{"text": $s}]},
                    "contents": [{"parts": [{"text": $u}]}],
                    "generationConfig": {"maxOutputTokens": 4096, "temperature": 0.3}
                }')
            elif [ -n "$system" ]; then
                data=$(jq -n --arg u "Instructions: ${system}

${message}" '{
                    "contents": [{"parts": [{"text": $u}]}],
                    "generationConfig": {"maxOutputTokens": 4096, "temperature": 0.3}
                }')
            else
                data=$(jq -n --arg u "$message" '{
                    "contents": [{"parts": [{"text": $u}]}],
                    "generationConfig": {"maxOutputTokens": 4096, "temperature": 0.3}
                }')
            fi

            local url="https://generativelanguage.googleapis.com/v1beta/models/${model}:streamGenerateContent?alt=sse&key=${key}"
            curl_pid=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_stream_post \
                "$url" "$data" "$_fifo")

            resp_text=$(_provider_google_sse_loop "$_fifo" "$curl_pid") ;;

        *)
            rm -f "$_fifo"
            provider_chat "$provider" "$message" "$model" "$system"
            return $? ;;
    esac

    local rc=$?
    rm -f "$_fifo"

    if [ $rc -eq 0 ] && [ -n "$resp_text" ]; then
        echo "$resp_text"
        return 0
    fi

    # Streaming failed — fall back to synchronous
    [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] provider stream failed, falling back to sync" >/dev/tty 2>/dev/null
    provider_chat "$provider" "$message" "$model" "$system"
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
    # o-series reasoning models require developer role + no temperature
    if [[ "$model" == o1* || "$model" == o3* ]]; then
        data=$(jq -n --arg m "$model" --arg s "$system" --arg u "$message" '{
            "model": $m,
            "messages": [
                {"role": "developer", "content": $s},
                {"role": "user", "content": $u}
            ],
            "max_completion_tokens": 4096
        }')
    else
        data=$(jq -n --arg m "$model" --arg s "$system" --arg u "$message" '{
            "model": $m,
            "messages": [
                {"role": "system", "content": $s},
                {"role": "user", "content": $u}
            ],
            "max_completion_tokens": 4096,
            "temperature": 0.3
        }')
    fi

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
    echo "claude-haiku-4-20250514"
}

# ═══════════════════════════════════════════════════════════════
# Google AI Studio (Gemini) & ADK
# ═══════════════════════════════════════════════════════════════
# Key: GOOGLE_AI_API_KEY
# ADK Keys: GOOGLE_ADK_PROJECT_ID, GOOGLE_ADK_LOCATION

# Detect models that don't support Google's systemInstruction field.
# Gemma (open-weight) models return 400 "Developer instruction is not enabled".
# Returns 0 (true) if the model requires the workaround.
_google_needs_system_workaround() {
    local model="$1"
    case "$model" in
        gemma*|Gemma*) return 0 ;;
        *)             return 1 ;;
    esac
}

google_chat() {
    local message="$1"
    local model
    model=$(_provider_resolve_model "$2" "google" "gemma-3-27b-it")
    local system="${3:-}"
    local key
    key=$(api_require_key "GOOGLE_AI_API_KEY" "Google AI") || return 1

    # Gemma models reject systemInstruction — prepend system to user message
    local _use_sys_inst=1
    if _google_needs_system_workaround "$model"; then
        _use_sys_inst=0
    fi

    local data
    if [ -n "$system" ] && [ "$_use_sys_inst" -eq 1 ]; then
        data=$(jq -n --arg s "$system" --arg u "$message" '{
            "systemInstruction": {"parts": [{"text": $s}]},
            "contents": [{"parts": [{"text": $u}]}],
            "generationConfig": {
                "maxOutputTokens": 4096,
                "temperature": 0.3
            }
        }')
    elif [ -n "$system" ]; then
        # System prompt inlined into user message for Gemma-class models
        data=$(jq -n --arg u "Instructions: ${system}

${message}" '{
            "contents": [{"parts": [{"text": $u}]}],
            "generationConfig": {
                "maxOutputTokens": 4096,
                "temperature": 0.3
            }
        }')
    else
        data=$(jq -n --arg u "$message" '{
            "contents": [{"parts": [{"text": $u}]}],
            "generationConfig": {
                "maxOutputTokens": 4096,
                "temperature": 0.3
            }
        }')
    fi

    local url="https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${key}"
    local resp rc
    resp=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_post "$url" "$data")
    rc=$?

    # Safety net: if a non-Gemma model also rejects systemInstruction,
    # retry with the inline workaround (one-time fallback, not every call)
    if [ $rc -ne 0 ] && [ "$_use_sys_inst" -eq 1 ] && [ -n "$system" ] \
       && echo "$resp" | grep -qi "developer instruction"; then
        data=$(jq -n --arg u "Instructions: ${system}

${message}" '{
            "contents": [{"parts": [{"text": $u}]}],
            "generationConfig": {
                "maxOutputTokens": 4096,
                "temperature": 0.3
            }
        }')
        resp=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_post "$url" "$data")
        rc=$?
    fi

    _provider_check_response $rc "$resp" '.candidates[0].content.parts[0].text' "Google AI"
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
    local system="${3:-You are a helpful assistant.}"
    local key
    key=$(api_require_key "GROQ_API_KEY" "Groq") || return 1

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
        "https://api.groq.com/openai/v1/chat/completions" "$data" \
        -H "Authorization: Bearer $key")

    _provider_check_response $? "$resp" '.choices[0].message.content' "Groq"
}

groq_models() {
    local key
    key=$(api_require_key "GROQ_API_KEY" "Groq") || return 1

    api_get "https://api.groq.com/openai/v1/models" \
        -H "Authorization: Bearer $key" | \
        jq -r '.data[]? | .id' 2>/dev/null | sort
}

# ═══════════════════════════════════════════════════════════════
# Mistral AI
# ═══════════════════════════════════════════════════════════════
# Key: MISTRAL_API_KEY

mistral_chat() {
    local message="$1"
    local model
    model=$(_provider_resolve_model "$2" "mistral" "mistral-large-latest")
    local system="${3:-You are a helpful assistant.}"
    local key
    key=$(api_require_key "MISTRAL_API_KEY" "Mistral") || return 1

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
    local system="${3:-You are a helpful assistant.}"
    local key
    key=$(api_require_key "TOGETHER_API_KEY" "Together") || return 1

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
    local system="${3:-You are a helpful assistant.}"
    local key
    key=$(api_require_key "PERPLEXITY_API_KEY" "Perplexity") || return 1

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
    model=$(_provider_resolve_model "$2" "cohere" "command-a-03-2025")
    local system="${3:-You are a helpful assistant.}"
    local key
    key=$(api_require_key "COHERE_API_KEY" "Cohere") || return 1

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
        "https://api.cohere.com/v2/chat" "$data" \
        -H "Authorization: Bearer $key")

    _provider_check_response $? "$resp" '.message.content[0].text' "Cohere"
}

# ═══════════════════════════════════════════════════════════════
# DeepSeek
# ═══════════════════════════════════════════════════════════════
# Key: DEEPSEEK_API_KEY

deepseek_chat() {
    local message="$1"
    local model
    model=$(_provider_resolve_model "$2" "deepseek" "deepseek-chat")
    local system="${3:-You are a helpful assistant.}"
    local key
    key=$(api_require_key "DEEPSEEK_API_KEY" "DeepSeek") || return 1

    local data
    # deepseek-reasoner rejects temperature != 1 and puts output in reasoning_content
    if [[ "$model" == *reasoner* ]]; then
        data=$(jq -n --arg m "$model" --arg s "$system" --arg u "$message" '{
            "model": $m,
            "messages": [
                {"role": "system", "content": $s},
                {"role": "user", "content": $u}
            ],
            "max_tokens": 4096
        }')
    else
        data=$(jq -n --arg m "$model" --arg s "$system" --arg u "$message" '{
            "model": $m,
            "messages": [
                {"role": "system", "content": $s},
                {"role": "user", "content": $u}
            ],
            "max_tokens": 4096,
            "temperature": 0.3
        }')
    fi

    local resp
    resp=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_post \
        "https://api.deepseek.com/chat/completions" "$data" \
        -H "Authorization: Bearer $key")

    # For reasoner models, try to extract reasoning_content if content is empty
    local rc=$?
    if [ $rc -eq 0 ] && [[ "$model" == *reasoner* ]]; then
        local text
        text=$(api_json_get "$resp" '.choices[0].message.content')
        if [ -z "$text" ] || [ "$text" = "null" ]; then
            text=$(api_json_get "$resp" '.choices[0].message.reasoning_content')
        fi
        if [ -n "$text" ] && [ "$text" != "null" ]; then
            echo "$text"
            return 0
        fi
    fi

    _provider_check_response $rc "$resp" '.choices[0].message.content' "DeepSeek"
}

# ═══════════════════════════════════════════════════════════════
# xAI (Grok)
# ═══════════════════════════════════════════════════════════════
# Key: XAI_API_KEY

xai_chat() {
    local message="$1"
    local model
    model=$(_provider_resolve_model "$2" "xai" "grok-2")
    local system="${3:-You are a helpful assistant.}"
    local key
    key=$(api_require_key "XAI_API_KEY" "xAI") || return 1

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
    local system="${4:-}"

    case "$provider" in
        openai|gpt)         openai_chat "$message" "$model" "$system" ;;
        anthropic|claude)   anthropic_chat "$message" "$model" "$system" ;;
        google|gemini)      google_chat "$message" "$model" "$system" ;;
        groq)               groq_chat "$message" "$model" "$system" ;;
        mistral)            mistral_chat "$message" "$model" "$system" ;;
        together)           together_chat "$message" "$model" "$system" ;;
        perplexity|pplx)    perplexity_chat "$message" "$model" "$system" ;;
        cohere)             cohere_chat "$message" "$model" "$system" ;;
        deepseek)           deepseek_chat "$message" "$model" "$system" ;;
        xai|grok)           xai_chat "$message" "$model" "$system" ;;
        *)
            ui_err "Unknown provider: $provider"
            ui_dim "Available: openai, anthropic, google, groq, mistral, together, perplexity, cohere, deepseek, xai"
            return 1 ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
# Provider Model Listing — Unified dispatcher for all providers
# ═══════════════════════════════════════════════════════════════

# List available models from a provider's API.
# Usage: provider_models <provider>
provider_models() {
    local provider
    provider=$(_provider_canon "$1")
    if [ -z "$provider" ]; then
        ui_err "Unknown provider: $1"
        return 1
    fi

    case "$provider" in
        OPENAI)     openai_models ;;
        ANTHROPIC)  anthropic_models ;;
        GOOGLE)     google_models ;;
        GROQ)       groq_models ;;
        # Providers without API model listing fall back to config file
        *)
            local _canon_lower
            _canon_lower=$(echo "$provider" | tr '[:upper:]' '[:lower:]')
            local _limits_file="${LODGE_DIR}/models/free-tier-limits.json"
            if [ -f "$_limits_file" ]; then
                jq -r --arg p "$_canon_lower" '.[$p].models // {} | keys[]' "$_limits_file" 2>/dev/null | sort
            else
                ui_dim "No model listing available for $provider (no API endpoint or config)"
                return 1
            fi ;;
    esac
}

# ── Free-tier rate limit lookup ────────────────────────────────
# Returns JSON object with rpm, rpd, tpm, tpd for a specific model.
# Usage: provider_model_limits <provider> <model>
provider_model_limits() {
    local provider="$1" model="$2"
    local _limits_file="${LODGE_DIR}/models/free-tier-limits.json"

    [ -f "$_limits_file" ] || return 1

    local _canon
    _canon=$(_provider_canon "$provider")
    local _canon_lower
    _canon_lower=$(echo "${_canon:-$provider}" | tr '[:upper:]' '[:lower:]')

    jq -r --arg p "$_canon_lower" --arg m "$model" \
        '.[$p].models[$m] // empty' "$_limits_file" 2>/dev/null
}

# ── Suggested /limit settings for a provider ───────────────────
# Returns the suggested rate-limit config from the free-tier file.
# Usage: provider_suggested_limits <provider>
provider_suggested_limits() {
    local provider="$1"
    local _limits_file="${LODGE_DIR}/models/free-tier-limits.json"

    [ -f "$_limits_file" ] || return 1

    local _canon
    _canon=$(_provider_canon "$provider")
    local _canon_lower
    _canon_lower=$(echo "${_canon:-$provider}" | tr '[:upper:]' '[:lower:]')

    jq -r --arg p "$_canon_lower" \
        '.[$p].suggested // empty | to_entries[] | select(.key != "_doc") | "\(.key) \(.value)"' \
        "$_limits_file" 2>/dev/null
}

# ── Apply suggested limits for a provider ──────────────────────
# Reads the suggested config and sets the corresponding variables.
# Usage: provider_apply_suggested_limits <provider>
provider_apply_suggested_limits() {
    local provider="$1"
    local _line

    while IFS= read -r _line; do
        [ -z "$_line" ] && continue
        local _key _val
        _key=$(echo "$_line" | awk '{print $1}')
        _val=$(echo "$_line" | awk '{print $2}')
        case "$_key" in
            api-delay)           PROVIDER_CALL_DELAY="$_val" ;;
            api-retries)         PROVIDER_MAX_RETRIES="$_val" ;;
            api-backoff)         PROVIDER_INITIAL_BACKOFF="$_val" ;;
            api-max-backoff)     PROVIDER_MAX_BACKOFF="$_val" ;;
            api-cooldown-max)    PROVIDER_COOLDOWN_MAX="$_val" ;;
            api-cooldown-window) PROVIDER_COOLDOWN_WINDOW="$_val" ;;
        esac
    done < <(provider_suggested_limits "$provider")
}

# ═══════════════════════════════════════════════════════════════
# Provider Harness — Route ALL LLM calls through a cloud provider
# ═══════════════════════════════════════════════════════════════

# Map provider name to its required API key name
_provider_key_name() {
    case "$1" in
        openai|gpt)       echo "OPENAI_API_KEY" ;;
        anthropic|claude)  echo "ANTHROPIC_API_KEY" ;;
        google|gemini)     echo "GOOGLE_AI_API_KEY" ;;
        groq)              echo "GROQ_API_KEY" ;;
        mistral)           echo "MISTRAL_API_KEY" ;;
        together)          echo "TOGETHER_API_KEY" ;;
        perplexity|pplx)   echo "PERPLEXITY_API_KEY" ;;
        cohere)            echo "COHERE_API_KEY" ;;
        deepseek)          echo "DEEPSEEK_API_KEY" ;;
        xai|grok)          echo "XAI_API_KEY" ;;
        *)                 echo "" ;;
    esac
}

# Activate a cloud provider for ALL LLM calls
provider_use() {
    local provider="$1"

    # Switch back to local backend
    if [ -z "$provider" ] || [ "$provider" = "local" ] || [ "$provider" = "off" ]; then
        provider_use_local
        return
    fi

    # Validate provider name
    local canon
    canon=$(_provider_canon "$provider")
    if [ -z "$canon" ]; then
        ui_err "Unknown provider: $provider"
        ui_dim "Available: openai, anthropic, google, groq, mistral, together, perplexity, cohere, deepseek, xai"
        return 1
    fi

    # Verify API key is configured
    local key_name
    key_name=$(_provider_key_name "$provider")
    if [ -n "$key_name" ] && ! api_get_key "$key_name" &>/dev/null; then
        ui_err "No API key configured for $provider"
        ui_dim "  Set it: /api keys set $key_name <your-key>"
        return 1
    fi

    GEORGE_PROVIDER="$provider"
    api_set_key "GEORGE_PROVIDER" "$provider"

    local _model
    _model=$(provider_get_model "$provider" 2>/dev/null)
    ui_ok "Provider harness active: all LLM calls → $provider"
    [ -n "$_model" ] && ui_dim "  Model: $_model"
    local _delay="${PROVIDER_CALL_DELAY:-0}"
    [ "$_delay" -gt 0 ] 2>/dev/null && ui_dim "  Call delay: ${_delay}s between LLM calls"
    ui_dim "  Switch back: /provider use local"
}

# Deactivate provider harness — return to local backend
provider_use_local() {
    GEORGE_PROVIDER=""
    # Remove from keys.conf
    if [ -f "$GEORGE_KEYS_FILE" ] && grep -q "^GEORGE_PROVIDER=" "$GEORGE_KEYS_FILE" 2>/dev/null; then
        local tmpfile
        tmpfile=$(mktemp)
        grep -v "^GEORGE_PROVIDER=" "$GEORGE_KEYS_FILE" > "$tmpfile"
        mv "$tmpfile" "$GEORGE_KEYS_FILE"
        chmod 600 "$GEORGE_KEYS_FILE"
    fi
    ui_ok "Provider harness off — LLM calls → local backend (llama.cpp/Ollama)"
}

# Return the active provider name (empty = local backend)
provider_active() {
    echo "${GEORGE_PROVIDER:-}"
}

# Load persisted provider setting (called at startup)
_provider_load_harness() {
    local stored
    stored=$(api_get_key "GEORGE_PROVIDER" 2>/dev/null)
    if [ -n "$stored" ]; then
        # Validate it's still a known provider with a key
        local canon
        canon=$(_provider_canon "$stored")
        local key_name
        key_name=$(_provider_key_name "$stored")
        if [ -n "$canon" ] && [ -n "$key_name" ] && api_get_key "$key_name" &>/dev/null; then
            GEORGE_PROVIDER="$stored"
        else
            # Stale or misconfigured — clear it
            GEORGE_PROVIDER=""
        fi
    fi
    # Restore persisted call delay
    local stored_delay
    stored_delay=$(api_get_key "PROVIDER_CALL_DELAY" 2>/dev/null)
    if [ -n "$stored_delay" ] && [ "$stored_delay" -gt 0 ] 2>/dev/null; then
        PROVIDER_CALL_DELAY="$stored_delay"
    fi
}

# Set inter-call delay (persisted to keys.conf)
provider_set_delay() {
    local secs="$1"
    if ! [[ "$secs" =~ ^[0-9]+$ ]]; then
        ui_err "Delay must be a number of seconds (e.g. 30)"
        return 1
    fi
    PROVIDER_CALL_DELAY="$secs"
    api_set_key "PROVIDER_CALL_DELAY" "$secs"
    if [ "$secs" -eq 0 ]; then
        ui_ok "Provider call delay disabled"
    else
        ui_ok "Provider call delay set to ${secs}s between LLM calls"
    fi
}

# Return current delay
provider_get_delay() {
    echo "${PROVIDER_CALL_DELAY:-0}"
}

# Show which providers are configured
provider_status() {
    # ── Active Provider Harness ──
    if [ -n "${GEORGE_PROVIDER:-}" ]; then
        echo ""
        ui_section "Provider Harness"
        local _h_model
        _h_model=$(provider_get_model "$GEORGE_PROVIDER" 2>/dev/null)
        if [ -n "$_h_model" ]; then
            printf "  %b★%b %-15s active  %bmodel: %s%b\n" "$C_GREEN" "$C_RESET" "$GEORGE_PROVIDER" "$C_DIM" "$_h_model" "$C_RESET"
        else
            printf "  %b★%b %-15s active (all LLM calls routed here)\n" "$C_GREEN" "$C_RESET" "$GEORGE_PROVIDER"
        fi
        local _s_delay="${PROVIDER_CALL_DELAY:-0}"
        [ "$_s_delay" -gt 0 ] 2>/dev/null && \
            printf "  %b  %-15s %s%b\n" "$C_DIM" "" "call delay: ${_s_delay}s" "$C_RESET"
    fi

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
