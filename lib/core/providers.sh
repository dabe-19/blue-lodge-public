#!/bin/bash
# ── George: AI Provider Integrations ───────────────────────────
[ -n "${_LIB_PROVIDERS_LOADED:-}" ] && return 0; _LIB_PROVIDERS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/core/api.sh"

GEORGE_PROVIDER="${GEORGE_PROVIDER:-}"
PROVIDER_TIMEOUT="${PROVIDER_TIMEOUT:-120}"

PROVIDER_MAX_RETRIES="${PROVIDER_MAX_RETRIES:-4}"
PROVIDER_INITIAL_BACKOFF="${PROVIDER_INITIAL_BACKOFF:-5}"
PROVIDER_MAX_BACKOFF="${PROVIDER_MAX_BACKOFF:-60}"
PROVIDER_COOLDOWN_WINDOW="${PROVIDER_COOLDOWN_WINDOW:-60}"
PROVIDER_COOLDOWN_MAX="${PROVIDER_COOLDOWN_MAX:-8}"
PROVIDER_CALL_DELAY="${PROVIDER_CALL_DELAY:-7}"
_PROVIDER_METER_DIR="${TMPDIR:-/tmp}/george-provider-meter.$$"

_provider_canon() {
    case "$1" in
        openai|gpt) echo "OPENAI" ;; anthropic|claude) echo "ANTHROPIC" ;; google|gemini) echo "GOOGLE" ;;
        groq) echo "GROQ" ;; mistral) echo "MISTRAL" ;; together) echo "TOGETHER" ;; perplexity|pplx) echo "PERPLEXITY" ;;
        cohere) echo "COHERE" ;; deepseek) echo "DEEPSEEK" ;; xai|grok) echo "XAI" ;; *) echo "" ;;
    esac
}

_provider_resolve_model() {
    local explicit="$1" provider="$2" hardcoded="$3"
    [ -n "$explicit" ] && { echo "$explicit"; return; }
    local canon; canon=$(_provider_canon "$provider")
    if [ -n "$canon" ]; then
        local stored; stored=$(api_get_key "PROVIDER_MODEL_${canon}" 2>/dev/null)
        [ -n "$stored" ] && { echo "$stored"; return; }
    fi
    echo "$hardcoded"
}

provider_set_model() {
    local canon; canon=$(_provider_canon "$1")
    [ -z "$canon" ] && { ui_err "Unknown provider: $1"; return 1; }
    api_set_key "PROVIDER_MODEL_${canon}" "$2"
    ui_ok "Default model for $1 set to: $2"
}

provider_get_model() {
    local canon; canon=$(_provider_canon "$1")
    [ -z "$canon" ] && { ui_err "Unknown provider: $1"; return 1; }
    api_get_key "PROVIDER_MODEL_${canon}" 2>/dev/null
}

provider_clear_model() {
    local canon; canon=$(_provider_canon "$1")
    [ -z "$canon" ] && { ui_err "Unknown provider: $1"; return 1; }
    local key_name="PROVIDER_MODEL_${canon}"
    if grep -q "^${key_name}=" "$GEORGE_KEYS_FILE" 2>/dev/null; then
        local tmpfile; tmpfile=$(mktemp)
        grep -v "^${key_name}=" "$GEORGE_KEYS_FILE" > "$tmpfile"
        mv "$tmpfile" "$GEORGE_KEYS_FILE"; chmod 600 "$GEORGE_KEYS_FILE"
        ui_ok "Cleared custom model for $1 (back to built-in default)"
    else ui_info "No custom model set for $1"; fi
}

_provider_countdown() {
    local secs="$1" label="${2:-Waiting}" _tty="/dev/tty"
    { true >/dev/tty; } 2>/dev/null || _tty="/dev/stderr"
    [ "$secs" -le 0 ] 2>/dev/null && return
    [ -n "${_SPINNER_PID:-}" ] && ui_spinner_stop 2>/dev/null
    local i="$secs"
    while [ "$i" -gt 0 ]; do
        local filled=$(( (secs - i) * 20 / secs )) empty=$(( 20 - filled )) j=0
        printf "\r \033[90m[\033[34m" > "$_tty" 2>/dev/null
        while [ $j -lt $filled ]; do printf '█' > "$_tty" 2>/dev/null; j=$((j+1)); done
        j=0; while [ $j -lt $empty ]; do printf '░' > "$_tty" 2>/dev/null; j=$((j+1)); done
        printf "\033[90m] \033[37m%s: %ds\033[0m " "$label" "$i" > "$_tty" 2>/dev/null
        sleep 1; i=$((i - 1))
    done
    printf "\033[2K\r" > "$_tty" 2>/dev/null
}

_provider_check_response() {
    local exit_code="$1" resp="$2" jq_path="$3" label="$4"
    if [ "$exit_code" -eq 0 ]; then
        local text; text=$(api_json_get "$resp" "$jq_path")
        [ -n "$text" ] && [ "$text" != "null" ] && { echo "$text"; return 0; }
    fi
    local err_msg; err_msg=$(api_json_get "$resp" '.error.message // .error.type // .message // "unknown error"')
    [ -z "$err_msg" ] || [ "$err_msg" = "null" ] && err_msg="empty or blocked response"
    ui_err "$label: $err_msg"; return 1
}

_provider_meter_init() { mkdir -p "$_PROVIDER_METER_DIR" 2>/dev/null; }
_provider_meter_tick() { _provider_meter_init; date +%s >> "$_PROVIDER_METER_DIR/calls" 2>/dev/null; }

_provider_meter_count() {
    _provider_meter_init
    local cutoff=$(( $(date +%s) - PROVIDER_COOLDOWN_WINDOW ))
    [ ! -f "$_PROVIDER_METER_DIR/calls" ] && { echo 0; return; }
    awk -v c="$cutoff" '$1 >= c' "$_PROVIDER_METER_DIR/calls" 2>/dev/null | wc -l
}

_provider_meter_throttle() {
    local count; count=$(_provider_meter_count)
    if [ "$count" -ge "$PROVIDER_COOLDOWN_MAX" ]; then
        local oldest now wait_s
        oldest=$(awk -v c="$(($(date +%s) - PROVIDER_COOLDOWN_WINDOW))" '$1 >= c' "$_PROVIDER_METER_DIR/calls" 2>/dev/null | head -1)
        now=$(date +%s); wait_s=$(( (oldest + PROVIDER_COOLDOWN_WINDOW) - now + 1 ))
        [ "$wait_s" -lt 1 ] && wait_s=1; [ "$wait_s" -gt "$PROVIDER_MAX_BACKOFF" ] && wait_s="$PROVIDER_MAX_BACKOFF"
        ui_warn "Provider rate-limit cooldown: pausing ${wait_s}s ($count calls in ${PROVIDER_COOLDOWN_WINDOW}s window)"
        _provider_countdown "$wait_s" "Cooldown"
        local cutoff=$(($(date +%s) - PROVIDER_COOLDOWN_WINDOW)) tmpf; tmpf=$(mktemp)
        awk -v c="$cutoff" '$1 >= c' "$_PROVIDER_METER_DIR/calls" > "$tmpf" 2>/dev/null
        mv "$tmpf" "$_PROVIDER_METER_DIR/calls" 2>/dev/null
    fi
}

_provider_meter_reset() { rm -rf "$_PROVIDER_METER_DIR" 2>/dev/null; }

_provider_inter_call_delay() {
    [ "${PROVIDER_CALL_DELAY:-0}" -le 0 ] 2>/dev/null && return
    _provider_meter_init
    local last_file="$_PROVIDER_METER_DIR/last_call"
    if [ -f "$last_file" ]; then
        local last now elapsed remaining
        last=$(cat "$last_file" 2>/dev/null); now=$(date +%s)
        elapsed=$((now - last)); remaining=$((PROVIDER_CALL_DELAY - elapsed))
        [ "$remaining" -gt 0 ] && _provider_countdown "$remaining" "API delay"
    fi
}

_provider_stamp_last_call() { _provider_meter_init; date +%s > "$_PROVIDER_METER_DIR/last_call" 2>/dev/null; }

_provider_call_with_backoff() {
    local provider="$1" message="$2" model="${3:-}" system="${4:-}"
    local attempt=0 delay="$PROVIDER_INITIAL_BACKOFF" max="$PROVIDER_MAX_RETRIES" resp rc
    while [ "$attempt" -le "$max" ]; do
        _provider_inter_call_delay; _provider_meter_throttle; _provider_meter_tick
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] provider/$provider: calling API..." >/dev/tty 2>/dev/null
        resp=$(provider_chat "$provider" "$message" "$model" "$system" 2>&1); rc=$?
        if [ $rc -eq 0 ] && [ -n "$resp" ]; then _provider_stamp_last_call; echo "$resp"; return 0; fi

        local is_rate_limit=0
        if [ "$rc" -eq 2 ] || echo "$resp" | grep -qiE "rate.limit|quota.*exceed|too.many.request|429|retry.in"; then
            is_rate_limit=1
        fi
        [ "$is_rate_limit" -eq 0 ] && { echo "$resp" >&2; return $rc; }
        attempt=$((attempt + 1))
        [ "$attempt" -gt "$max" ] && { ui_err "Provider rate limit: gave up after $max retries"; return 1; }

        local hint_wait; hint_wait=$(echo "$resp" | sed -n 's/.*[Rr]etry[[:space:]]\{1,\}in[[:space:]]\{1,\}\([0-9]\{1,\}\(\.[0-9]\{1,\}\)\{0,1\}\).*/\1/p' | head -1)
        [ -n "$hint_wait" ] && delay=$(printf '%.0f' "$hint_wait" 2>/dev/null || echo "$delay")
        [ "$delay" -lt 1 ] && delay=1; [ "$delay" -gt "$PROVIDER_MAX_BACKOFF" ] && delay="$PROVIDER_MAX_BACKOFF"
        ui_warn "Rate limited — retry ${attempt}/${max} in ${delay}s"
        _provider_countdown "$delay" "Backoff"; delay=$((delay * 2))
    done
    return 1
}

_provider_stream_with_backoff() {
    local provider="$1" message="$2" model="${3:-}" system="${4:-}"
    local attempt=0 delay="$PROVIDER_INITIAL_BACKOFF" max="$PROVIDER_MAX_RETRIES" resp rc
    while [ "$attempt" -le "$max" ]; do
        _provider_inter_call_delay; _provider_meter_throttle; _provider_meter_tick
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] provider/$provider: streaming API call..." >/dev/tty 2>/dev/null
        resp=$(provider_stream_chat "$provider" "$message" "$model" "$system" 2>&1); rc=$?
        if [ $rc -eq 0 ] && [ -n "$resp" ]; then _provider_stamp_last_call; echo "$resp"; return 0; fi

        local is_rate_limit=0
        if [ "$rc" -eq 2 ] || echo "$resp" | grep -qiE "rate.limit|quota.*exceed|too.many.request|429|retry.in"; then
            is_rate_limit=1
        fi
        [ "$is_rate_limit" -eq 0 ] && { echo "$resp" >&2; return $rc; }
        attempt=$((attempt + 1))
        [ "$attempt" -gt "$max" ] && { ui_err "Provider rate limit: gave up after $max retries"; return 1; }

        local hint_wait; hint_wait=$(echo "$resp" | sed -n 's/.*[Rr]etry[[:space:]]\{1,\}in[[:space:]]\{1,\}\([0-9]\{1,\}\(\.[0-9]\{1,\}\)\{0,1\}\).*/\1/p' | head -1)
        [ -n "$hint_wait" ] && delay=$(printf '%.0f' "$hint_wait" 2>/dev/null || echo "$delay")
        [ "$delay" -lt 1 ] && delay=1; [ "$delay" -gt "$PROVIDER_MAX_BACKOFF" ] && delay="$PROVIDER_MAX_BACKOFF"
        ui_warn "Rate limited — retry ${attempt}/${max} in ${delay}s"
        _provider_countdown "$delay" "Backoff"; delay=$((delay * 2))
    done
    return 1
}

_provider_sse_loop() {
    local fifo="$1" curl_pid="$2" content_jq="$3" think_jq="${4:-}" done_match="${5:-[DONE]}"
    local _tty="/dev/tty"; { true >/dev/tty; } 2>/dev/null || _tty="/dev/stderr"
    local _cancel_file="${TMPDIR:-/tmp}/.lodge-cancel-$$" _in_think=0 _think_banner=0 _got_content=0 _idle_timeout=45 line

    while IFS= read -t "$_idle_timeout" -r line || [ -n "$line" ]; do
        [ -f "$_cancel_file" ] && break
        line="${line%$'\r'}"
        [[ "$line" == data:* ]] || continue
        local json="${line#data: }"; json="${json#"${json%%[![:space:]]*}"}"
        [ "$json" = "$done_match" ] && break

        if [ -n "$think_jq" ]; then
            local think_tok; think_tok=$(echo "$json" | jq -r "$think_jq" 2>/dev/null)
            if [ -n "$think_tok" ] && [ "$think_tok" != "null" ]; then
                if [ "$_think_banner" -eq 0 ]; then
                    _think_banner=1; _in_think=1
                    if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                        local _c; [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && _c="\033[36m" || _c="\033[90m"
                        printf "\n%b┌─ thinking ─\033[0m\n%b" "$_c" "$_c" > "$_tty" 2>/dev/null
                    fi
                fi
                [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ] && printf "%s" "$think_tok" > "$_tty" 2>/dev/null
                continue
            fi
        fi

        local tok; tok=$(echo "$json" | jq -r "$content_jq" 2>/dev/null)
        if [ -n "$tok" ] && [ "$tok" != "null" ]; then
            if [ "$_in_think" -eq 1 ] && [ "$_think_banner" -eq 1 ]; then
                _in_think=0; _think_banner=0
                if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                    local _c; [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && _c="\033[36m" || _c="\033[90m"
                    printf "\033[0m\n%b└────────────\033[0m\n" "$_c" > "$_tty" 2>/dev/null
                fi
            fi
            _got_content=1; printf "%s" "$tok"; printf "%s" "$tok" > "$_tty" 2>/dev/null
        fi
    done < "$fifo"

    if [ "$_think_banner" -eq 1 ] && [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
        local _c; [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && _c="\033[36m" || _c="\033[90m"
        printf "\033[0m\n%b└────────────\033[0m\n" "$_c" > "$_tty" 2>/dev/null
    fi
    kill "$curl_pid" 2>/dev/null; wait "$curl_pid" 2>/dev/null 2>&1 || true
    [ "$_got_content" -eq 1 ] && return 0
    return 1
}

_provider_anthropic_sse_loop() {
    local fifo="$1" curl_pid="$2" _tty="/dev/tty"; { true >/dev/tty; } 2>/dev/null || _tty="/dev/stderr"
    local _cancel_file="${TMPDIR:-/tmp}/.lodge-cancel-$$" _in_think=0 _think_banner=0 _got_content=0 _event_type="" _idle_timeout=45 line

    while IFS= read -t "$_idle_timeout" -r line || [ -n "$line" ]; do
        [ -f "$_cancel_file" ] && break
        line="${line%$'\r'}"
        if [[ "$line" == event:* ]]; then
            _event_type="${line#event: }"; _event_type="${_event_type#"${_event_type%%[![:space:]]*}"}"; continue
        fi
        [[ "$line" == data:* ]] || continue
        local json="${line#data: }"; json="${json#"${json%%[![:space:]]*}"}"

        case "$_event_type" in
            content_block_start)
                local block_type; block_type=$(echo "$json" | jq -r '.content_block.type // empty' 2>/dev/null)
                if [ "$block_type" = "thinking" ]; then
                    _in_think=1
                    if [ "$_think_banner" -eq 0 ]; then
                        _think_banner=1
                        if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                            local _c; [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && _c="\033[36m" || _c="\033[90m"
                            printf "\n%b┌─ thinking ─\033[0m\n%b" "$_c" "$_c" > "$_tty" 2>/dev/null
                        fi
                    fi
                elif [ "$_in_think" -eq 1 ]; then
                    _in_think=0; _think_banner=0
                    if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                        local _c; [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && _c="\033[36m" || _c="\033[90m"
                        printf "\033[0m\n%b└────────────\033[0m\n" "$_c" > "$_tty" 2>/dev/null
                    fi
                fi ;;
            content_block_delta)
                local tok; tok=$(echo "$json" | jq -r '.delta.text // .delta.thinking // empty' 2>/dev/null)
                if [ -n "$tok" ]; then
                    if [ "$_in_think" -eq 1 ]; then
                        [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ] && printf "%s" "$tok" > "$_tty" 2>/dev/null
                    else
                        _got_content=1; printf "%s" "$tok"; printf "%s" "$tok" > "$_tty" 2>/dev/null
                    fi
                fi ;;
            message_stop) break ;;
        esac
    done < "$fifo"

    if [ "$_think_banner" -eq 1 ] && [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
        local _c; [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && _c="\033[36m" || _c="\033[90m"
        printf "\033[0m\n%b└────────────\033[0m\n" "$_c" > "$_tty" 2>/dev/null
    fi
    kill "$curl_pid" 2>/dev/null; wait "$curl_pid" 2>/dev/null 2>&1 || true
    [ "$_got_content" -eq 1 ] && return 0
    return 1
}

_provider_google_sse_loop() {
    local fifo="$1" curl_pid="$2" _tty="/dev/tty"; { true >/dev/tty; } 2>/dev/null || _tty="/dev/stderr"
    local _got_content=0 _cancel_file="${TMPDIR:-/tmp}/.lodge-cancel-$$" _idle_timeout=45 line

    while IFS= read -t "$_idle_timeout" -r line || [ -n "$line" ]; do
        [ -f "$_cancel_file" ] && break
        line="${line%$'\r'}"
        [[ "$line" == data:* ]] || continue
        local json="${line#data: }"; json="${json#"${json%%[![:space:]]*}"}"
        local tok; tok=$(echo "$json" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null)
        if [ -n "$tok" ]; then
            _got_content=1; printf "%s" "$tok"; printf "%s" "$tok" > "$_tty" 2>/dev/null
        fi
    done < "$fifo"
    kill "$curl_pid" 2>/dev/null; wait "$curl_pid" 2>/dev/null 2>&1 || true
    [ "$_got_content" -eq 1 ] && return 0
    return 1
}

_provider_cohere_sse_loop() {
    local fifo="$1" curl_pid="$2" _tty="/dev/tty"; { true >/dev/tty; } 2>/dev/null || _tty="/dev/stderr"
    local _got_content=0 _cancel_file="${TMPDIR:-/tmp}/.lodge-cancel-$$" _idle_timeout=45 line

    while IFS= read -t "$_idle_timeout" -r line || [ -n "$line" ]; do
        [ -f "$_cancel_file" ] && break
        line="${line%$'\r'}"
        [ -z "$line" ] && continue
        local event_type; event_type=$(echo "$line" | jq -r '.event_type // empty' 2>/dev/null)
        case "$event_type" in
            text-generation)
                local tok; tok=$(echo "$line" | jq -r '.text // empty' 2>/dev/null)
                if [ -n "$tok" ]; then
                    _got_content=1; printf "%s" "$tok"; printf "%s" "$tok" > "$_tty" 2>/dev/null
                fi ;;
            stream-end) break ;;
        esac
    done < "$fifo"
    kill "$curl_pid" 2>/dev/null; wait "$curl_pid" 2>/dev/null 2>&1 || true
    [ "$_got_content" -eq 1 ] && return 0
    return 1
}

provider_stream_chat() {
    local provider="$1" message="$2" model="${3:-}" system="${4:-}"
    local canon; canon=$(_provider_canon "$provider")
    [ -z "$canon" ] && { provider_chat "$provider" "$message" "$model" "$system"; return $?; }

    local _tmpdir="${TMPDIR:-/tmp}" _fifo="$_tmpdir/.lodge-provider-stream-$$"
    rm -f "$_fifo"
    if [[ "${LODGE_PLATFORM:-}" == "ish" ]] || ! mkfifo "$_fifo" 2>/dev/null; then
        rm -f "$_fifo"; provider_chat "$provider" "$message" "$model" "$system"; return $?
    fi

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
            local data sys_role="system" _temp_clause='"temperature": 0.7,'
            if [ "$canon" = "OPENAI" ] && [[ "$model" == o1* || "$model" == o3* ]]; then
                sys_role="developer"; _temp_clause=""
            fi
            if [ "$canon" = "DEEPSEEK" ] && [[ "$model" == *reasoner* ]]; then _temp_clause=""; fi
            data=$(jq -n --arg m "$model" --arg s "$system" --arg u "$message" --arg sr "$sys_role" \
                "{\"model\": \$m, \"messages\": [{\"role\": \$sr, \"content\": \$s}, {\"role\": \"user\", \"content\": \$u}], \"max_tokens\": 4096, ${_temp_clause} \"stream\": true}")
            curl_pid=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_stream_post "$url" "$data" "$_fifo" -H "Authorization: Bearer $key")
            local think_jq=""
            [ "$canon" = "DEEPSEEK" ] && think_jq='.choices[0].delta.reasoning_content // empty'
            resp_text=$(_provider_sse_loop "$_fifo" "$curl_pid" '.choices[0].delta.content // empty' "$think_jq") ;;

        ANTHROPIC)
            local key; key=$(api_require_key "ANTHROPIC_API_KEY") || { rm -f "$_fifo"; return 1; }
            model=$(_provider_resolve_model "$model" "$provider" "claude-sonnet-4-20250514")
            system="${system:-You are a helpful assistant.}"
            local data; data=$(jq -n --arg m "$model" --arg s "$system" --arg u "$message" '{"model": $m, "max_tokens": 4096, "system": $s, "messages": [{"role": "user", "content": $u}], "stream": true}')
            curl_pid=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_stream_post "https://api.anthropic.com/v1/messages" "$data" "$_fifo" -H "x-api-key: $key" -H "anthropic-version: 2023-06-01")
            resp_text=$(_provider_anthropic_sse_loop "$_fifo" "$curl_pid") ;;

        GOOGLE)
            local key; key=$(api_require_key "GOOGLE_AI_API_KEY") || { rm -f "$_fifo"; return 1; }
            model=$(_provider_resolve_model "$model" "$provider" "gemma-3-27b-it")
            local data
            if [ -n "$system" ] && ! _google_needs_system_workaround "$model"; then
                data=$(jq -n --arg s "$system" --arg u "$message" '{"systemInstruction": {"parts": [{"text": $s}]}, "contents": [{"parts": [{"text": $u}]}], "generationConfig": {"maxOutputTokens": 4096, "temperature": 0.7}}')
            elif [ -n "$system" ]; then
                data=$(jq -n --arg u "Instructions: ${system}

${message}" '{"contents": [{"parts": [{"text": $u}]}], "generationConfig": {"maxOutputTokens": 4096, "temperature": 0.7}}')
            else
                data=$(jq -n --arg u "$message" '{"contents": [{"parts": [{"text": $u}]}], "generationConfig": {"maxOutputTokens": 4096, "temperature": 0.7}}')
            fi
            local url="https://generativelanguage.googleapis.com/v1beta/models/${model}:streamGenerateContent?alt=sse&key=${key}"
            curl_pid=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_stream_post "$url" "$data" "$_fifo")
            resp_text=$(_provider_google_sse_loop "$_fifo" "$curl_pid") ;;

        *) rm -f "$_fifo"; provider_chat "$provider" "$message" "$model" "$system"; return $? ;;
    esac

    local rc=$?
    rm -f "$_fifo"
    if [ $rc -eq 0 ] && [ -n "$resp_text" ]; then echo "$resp_text"; return 0; fi
    provider_chat "$provider" "$message" "$model" "$system"
}

_provider_openai_compat_models() {
    local key_name="$1" prov_label="$2" url="$3" filter_regex="${4:-}" key
    key=$(api_require_key "$key_name" "$prov_label") || return 1
    if [ -n "$filter_regex" ]; then
        api_get "$url" -H "Authorization: Bearer $key" | jq -r '.data[]? | .id' 2>/dev/null | grep -E "$filter_regex" | sort
    else
        api_get "$url" -H "Authorization: Bearer $key" | jq -r '.data[]? | .id' 2>/dev/null | sort
    fi
}

_provider_openai_compat_chat() {
    local prov_label="$1" key_name="$2" endpoint="$3" default_model="$4"
    local message="$5" model_arg="${6:-}" system="${7:-You are a helpful assistant.}"
    local model; model=$(_provider_resolve_model "$model_arg" "$(echo "$prov_label" | tr '[:upper:]' '[:lower:]')" "$default_model")
    local key; key=$(api_require_key "$key_name" "$prov_label") || return 1

    local role="system" temp_arg=(--argjson temp 0.7) tok_key="max_tokens"
    if [[ "$model" == o1* || "$model" == o3* ]]; then
        role="developer"; temp_arg=(); tok_key="max_completion_tokens"
    elif [[ "$model" == *reasoner* ]]; then
        temp_arg=()
    elif [[ "$prov_label" == "OpenAI" ]]; then
        tok_key="max_completion_tokens"
    fi

    local data
    if [ "${#temp_arg[@]}" -gt 0 ]; then
        data=$(jq -n --arg m "$model" --arg s "$system" --arg u "$message" --arg r "$role" --arg tk "$tok_key" "${temp_arg[@]}" '{"model": $m, "messages": [{"role": $r, "content": $s}, {"role": "user", "content": $u}], ($tk): 4096, "temperature": $temp}')
    else
        data=$(jq -n --arg m "$model" --arg s "$system" --arg u "$message" --arg r "$role" --arg tk "$tok_key" '{"model": $m, "messages": [{"role": $r, "content": $s}, {"role": "user", "content": $u}], ($tk): 4096}')
    fi

    local resp rc; resp=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_post "$endpoint" "$data" -H "Authorization: Bearer $key"); rc=$?
    if [ $rc -eq 0 ] && [[ "$model" == *reasoner* ]]; then
        local text; text=$(api_json_get "$resp" '.choices[0].message.content')
        [ -z "$text" ] || [ "$text" = "null" ] && text=$(api_json_get "$resp" '.choices[0].message.reasoning_content')
        if [ -n "$text" ] && [ "$text" != "null" ]; then echo "$text"; return 0; fi
    fi
    _provider_check_response $rc "$resp" '.choices[0].message.content' "$prov_label"
}

openai_chat() { _provider_openai_compat_chat "OpenAI" "OPENAI_API_KEY" "https://api.openai.com/v1/chat/completions" "gpt-4o-mini" "$@"; }
openai_models() { _provider_openai_compat_models "OPENAI_API_KEY" "OpenAI" "https://api.openai.com/v1/models" "^(gpt|o[0-9])"; }

anthropic_chat() {
    local message="$1" model system="${3:-You are a helpful assistant.}" key data resp
    model=$(_provider_resolve_model "$2" "anthropic" "claude-sonnet-4-20250514")
    key=$(api_require_key "ANTHROPIC_API_KEY" "Anthropic") || return 1
    data=$(jq -n --arg m "$model" --arg s "$system" --arg u "$message" '{"model": $m, "max_tokens": 4096, "system": $s, "messages": [{"role": "user", "content": $u}]}')
    resp=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_post "https://api.anthropic.com/v1/messages" "$data" -H "x-api-key: $key" -H "anthropic-version: 2023-06-01")
    _provider_check_response $? "$resp" '.content[0].text' "Anthropic"
}

anthropic_models() { echo -e "claude-opus-4-20250514\nclaude-sonnet-4-20250514\nclaude-haiku-4-20250514"; }

_google_needs_system_workaround() {
    case "$1" in gemma*|Gemma*) return 0 ;; *) return 1 ;; esac
}

google_chat() {
    local message="$1" model system="${3:-}" key _use_sys_inst=1 data url resp rc
    model=$(_provider_resolve_model "$2" "google" "gemma-3-27b-it")
    key=$(api_require_key "GOOGLE_AI_API_KEY" "Google AI") || return 1
    _google_needs_system_workaround "$model" && _use_sys_inst=0

    if [ -n "$system" ] && [ "$_use_sys_inst" -eq 1 ]; then
        data=$(jq -n --arg s "$system" --arg u "$message" '{"systemInstruction": {"parts": [{"text": $s}]}, "contents": [{"parts": [{"text": $u}]}], "generationConfig": {"maxOutputTokens": 4096, "temperature": 0.7}}')
    elif [ -n "$system" ]; then
        data=$(jq -n --arg u "Instructions: ${system}

${message}" '{"contents": [{"parts": [{"text": $u}]}], "generationConfig": {"maxOutputTokens": 4096, "temperature": 0.7}}')
    else
        data=$(jq -n --arg u "$message" '{"contents": [{"parts": [{"text": $u}]}], "generationConfig": {"maxOutputTokens": 4096, "temperature": 0.7}}')
    fi

    url="https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${key}"
    resp=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_post "$url" "$data"); rc=$?
    if [ $rc -ne 0 ] && [ "$_use_sys_inst" -eq 1 ] && [ -n "$system" ] && echo "$resp" | grep -qi "developer instruction"; then
        data=$(jq -n --arg u "Instructions: ${system}

${message}" '{"contents": [{"parts": [{"text": $u}]}], "generationConfig": {"maxOutputTokens": 4096, "temperature": 0.7}}')
        resp=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_post "$url" "$data"); rc=$?
    fi
    _provider_check_response $rc "$resp" '.candidates[0].content.parts[0].text' "Google AI"
}

google_models() {
    local key; key=$(api_require_key "GOOGLE_AI_API_KEY" "Google AI") || return 1
    api_get "https://generativelanguage.googleapis.com/v1beta/models?key=${key}" | jq -r '.models[]? | .name' 2>/dev/null | sed 's|^models/||' | sort
}

google_adk_create_agent() {
    local display_name="$1" instructions="${2:-You are a helpful agent.}" key project location data resp agent_name
    key=$(api_require_key "GOOGLE_AI_API_KEY" "Google AI") || return 1
    project=$(api_require_key "GOOGLE_ADK_PROJECT_ID" "Google ADK") || return 1
    location=$(api_get_key "GOOGLE_ADK_LOCATION"); location="${location:-us-central1}"
    data=$(jq -n --arg dn "$display_name" --arg inst "$instructions" '{"displayName": $dn, "defaultLanguageCode": "en", "generativeInfo": {"agentContent": $inst}}')
    resp=$(api_post "https://${location}-dialogflow.googleapis.com/v3/projects/${project}/locations/${location}/agents" "$data" -H "Authorization: Bearer $key")
    if [ $? -eq 0 ]; then
        agent_name=$(api_json_get "$resp" '.name'); ui_ok "ADK Agent created: $agent_name"; echo "$resp"
    else ui_err "ADK agent creation failed"; return 1; fi
}

google_adk_list_agents() {
    local key project location
    key=$(api_require_key "GOOGLE_AI_API_KEY" "Google AI") || return 1
    project=$(api_require_key "GOOGLE_ADK_PROJECT_ID" "Google ADK") || return 1
    location=$(api_get_key "GOOGLE_ADK_LOCATION"); location="${location:-us-central1}"
    api_get "https://${location}-dialogflow.googleapis.com/v3/projects/${project}/locations/${location}/agents" -H "Authorization: Bearer $key" | jq -r '.agents[]? | "\(.displayName) — \(.name)"' 2>/dev/null
}

groq_chat() { _provider_openai_compat_chat "Groq" "GROQ_API_KEY" "https://api.groq.com/openai/v1/chat/completions" "llama-3.3-70b-versatile" "$@"; }
groq_models() {
    local key; key=$(api_require_key "GROQ_API_KEY" "Groq") || return 1
    api_get "https://api.groq.com/openai/v1/models" -H "Authorization: Bearer $key" | jq -r '.data[]? | .id' 2>/dev/null | sort
}

mistral_chat() { _provider_openai_compat_chat "Mistral" "MISTRAL_API_KEY" "https://api.mistral.ai/v1/chat/completions" "mistral-large-latest" "$@"; }
together_chat() { _provider_openai_compat_chat "Together" "TOGETHER_API_KEY" "https://api.together.xyz/v1/chat/completions" "meta-llama/Llama-3.3-70B-Instruct-Turbo" "$@"; }
perplexity_chat() { _provider_openai_compat_chat "Perplexity" "PERPLEXITY_API_KEY" "https://api.perplexity.ai/chat/completions" "sonar" "$@"; }

cohere_chat() {
    local message="$1" model system="${3:-You are a helpful assistant.}" key data resp
    model=$(_provider_resolve_model "$2" "cohere" "command-a-03-2025")
    key=$(api_require_key "COHERE_API_KEY" "Cohere") || return 1
    data=$(jq -n --arg m "$model" --arg s "$system" --arg u "$message" '{"model": $m, "messages": [{"role": "system", "content": $s}, {"role": "user", "content": $u}], "max_tokens": 4096, "temperature": 0.7}')
    resp=$(API_DEFAULT_TIMEOUT=$PROVIDER_TIMEOUT api_post "https://api.cohere.com/v2/chat" "$data" -H "Authorization: Bearer $key")
    _provider_check_response $? "$resp" '.message.content[0].text' "Cohere"
}

deepseek_chat() { _provider_openai_compat_chat "DeepSeek" "DEEPSEEK_API_KEY" "https://api.deepseek.com/chat/completions" "deepseek-chat" "$@"; }
xai_chat() { _provider_openai_compat_chat "xAI" "XAI_API_KEY" "https://api.x.ai/v1/chat/completions" "grok-2" "$@"; }

provider_chat() {
    local provider="$1" message="$2" model="${3:-}" system="${4:-}"
    case "$provider" in
        openai|gpt) openai_chat "$message" "$model" "$system" ;;
        anthropic|claude) anthropic_chat "$message" "$model" "$system" ;;
        google|gemini) google_chat "$message" "$model" "$system" ;;
        groq) groq_chat "$message" "$model" "$system" ;;
        mistral) mistral_chat "$message" "$model" "$system" ;;
        together) together_chat "$message" "$model" "$system" ;;
        perplexity|pplx) perplexity_chat "$message" "$model" "$system" ;;
        cohere) cohere_chat "$message" "$model" "$system" ;;
        deepseek) deepseek_chat "$message" "$model" "$system" ;;
        xai|grok) xai_chat "$message" "$model" "$system" ;;
        *) ui_err "Unknown provider: $provider"; return 1 ;;
    esac
}

provider_models() {
    local provider; provider=$(_provider_canon "$1")
    [ -z "$provider" ] && { ui_err "Unknown provider: $1"; return 1; }
    case "$provider" in
        OPENAI) openai_models ;;
        ANTHROPIC) anthropic_models ;;
        GOOGLE) google_models ;;
        GROQ) groq_models ;;
        *)
            local _canon_lower; _canon_lower=$(echo "$provider" | tr '[:upper:]' '[:lower:]')
            local _limits_file="${LODGE_DIR}/models/free-tier-limits.json"
            if [ -f "$_limits_file" ]; then
                jq -r --arg p "$_canon_lower" '.[$p].models // {} | keys[]' "$_limits_file" 2>/dev/null | sort
            else ui_dim "No model listing available for $provider"; return 1; fi ;;
    esac
}

provider_model_limits() {
    local provider="$1" model="$2" _limits_file="${LODGE_DIR}/models/free-tier-limits.json"
    [ -f "$_limits_file" ] || return 1
    local _canon; _canon=$(_provider_canon "$provider")
    local _canon_lower; _canon_lower=$(echo "${_canon:-$provider}" | tr '[:upper:]' '[:lower:]')
    jq -r --arg p "$_canon_lower" --arg m "$model" '.[$p].models[$m] // empty' "$_limits_file" 2>/dev/null
}

provider_suggested_limits() {
    local provider="$1" _limits_file="${LODGE_DIR}/models/free-tier-limits.json"
    [ -f "$_limits_file" ] || return 1
    local _canon; _canon=$(_provider_canon "$provider")
    local _canon_lower; _canon_lower=$(echo "${_canon:-$provider}" | tr '[:upper:]' '[:lower:]')
    jq -r --arg p "$_canon_lower" '.[$p].suggested // empty | to_entries[] | select(.key != "_doc") | "\(.key) \(.value)"' "$_limits_file" 2>/dev/null
}

provider_apply_suggested_limits() {
    local provider="$1" _line _pl_tmp _key _val
    _pl_tmp=$(mktemp "${TMPDIR:-/tmp}/lodge-limits.XXXXXX")
    provider_suggested_limits "$provider" > "$_pl_tmp"
    while read -r _key _val; do
        [ -z "$_key" ] && continue
        case "$_key" in
            api-delay)           PROVIDER_CALL_DELAY="$_val" ;;
            api-retries)         PROVIDER_MAX_RETRIES="$_val" ;;
            api-backoff)         PROVIDER_INITIAL_BACKOFF="$_val" ;;
            api-max-backoff)     PROVIDER_MAX_BACKOFF="$_val" ;;
            api-cooldown-max)    PROVIDER_COOLDOWN_MAX="$_val" ;;
            api-cooldown-window) PROVIDER_COOLDOWN_WINDOW="$_val" ;;
        esac
    done < "$_pl_tmp"
    rm -f "$_pl_tmp"
}

_provider_key_name() {
    case "$1" in
        openai|gpt) echo "OPENAI_API_KEY" ;; anthropic|claude) echo "ANTHROPIC_API_KEY" ;; google|gemini) echo "GOOGLE_AI_API_KEY" ;;
        groq) echo "GROQ_API_KEY" ;; mistral) echo "MISTRAL_API_KEY" ;; together) echo "TOGETHER_API_KEY" ;;
        perplexity|pplx) echo "PERPLEXITY_API_KEY" ;; cohere) echo "COHERE_API_KEY" ;; deepseek) echo "DEEPSEEK_API_KEY" ;;
        xai|grok) echo "XAI_API_KEY" ;; *) echo "" ;;
    esac
}

provider_use() {
    local provider="$1"
    if [ -z "$provider" ] || [ "$provider" = "local" ] || [ "$provider" = "off" ]; then
        provider_use_local; return
    fi
    local canon; canon=$(_provider_canon "$provider")
    [ -z "$canon" ] && { ui_err "Unknown provider: $provider"; return 1; }
    local key_name; key_name=$(_provider_key_name "$provider")
    if [ -n "$key_name" ] && ! api_get_key "$key_name" &>/dev/null; then
        ui_err "No API key configured for $provider"; return 1
    fi
    GEORGE_PROVIDER="$provider"
    api_set_key "GEORGE_PROVIDER" "$provider"
    local _model; _model=$(provider_get_model "$provider" 2>/dev/null)
    ui_ok "Provider harness active: all LLM calls → $provider"
    [ -n "$_model" ] && ui_dim "  Model: $_model"
}

provider_use_local() {
    GEORGE_PROVIDER=""
    if [ -f "$GEORGE_KEYS_FILE" ] && grep -q "^GEORGE_PROVIDER=" "$GEORGE_KEYS_FILE" 2>/dev/null; then
        local tmpfile; tmpfile=$(mktemp)
        grep -v "^GEORGE_PROVIDER=" "$GEORGE_KEYS_FILE" > "$tmpfile"
        mv "$tmpfile" "$GEORGE_KEYS_FILE"; chmod 600 "$GEORGE_KEYS_FILE"
    fi
    ui_ok "Provider harness off — LLM calls → local backend (llama.cpp/Ollama)"
}

provider_active() { echo "${GEORGE_PROVIDER:-}"; }

_provider_load_harness() {
    local stored; stored=$(api_get_key "GEORGE_PROVIDER" 2>/dev/null)
    if [ -n "$stored" ]; then
        local canon key_name; canon=$(_provider_canon "$stored"); key_name=$(_provider_key_name "$stored")
        if [ -n "$canon" ] && [ -n "$key_name" ] && api_get_key "$key_name" &>/dev/null; then
            GEORGE_PROVIDER="$stored"
        else GEORGE_PROVIDER=""; fi
    fi
    local stored_delay; stored_delay=$(api_get_key "PROVIDER_CALL_DELAY" 2>/dev/null)
    if [ -n "$stored_delay" ] && [ "$stored_delay" -gt 0 ] 2>/dev/null; then
        PROVIDER_CALL_DELAY="$stored_delay"
    fi
}

provider_set_delay() {
    local secs="$1"
    if ! [[ "$secs" =~ ^[0-9]+$ ]]; then
        ui_err "Delay must be a number of seconds (e.g. 30)"
        return 1
    fi
    PROVIDER_CALL_DELAY="$secs"
    api_set_key "PROVIDER_CALL_DELAY" "$secs"
    if [ "$secs" -eq 0 ]; then ui_ok "Provider call delay disabled"
    else ui_ok "Provider call delay set to ${secs}s between LLM calls"; fi
}

provider_get_delay() { echo "${PROVIDER_CALL_DELAY:-0}"; }

provider_status() {
    if [ -n "${GEORGE_PROVIDER:-}" ]; then
        echo ""; ui_section "Provider Harness"
        local _h_model; _h_model=$(provider_get_model "$GEORGE_PROVIDER" 2>/dev/null)
        if [ -n "$_h_model" ]; then
            printf "  %b★%b %-15s active  %bmodel: %s%b\n" "$C_GREEN" "$C_RESET" "$GEORGE_PROVIDER" "$C_DIM" "$_h_model" "$C_RESET"
        else
            printf "  %b★%b %-15s active (all LLM calls routed here)\n" "$C_GREEN" "$C_RESET" "$GEORGE_PROVIDER"
        fi
        local _s_delay="${PROVIDER_CALL_DELAY:-0}"
        [ "$_s_delay" -gt 0 ] 2>/dev/null && printf "  %b  %-15s %s%b\n" "$C_DIM" "" "call delay: ${_s_delay}s" "$C_RESET"
    fi

    echo ""; ui_section "Web & Search"
    if api_get_key "SERPER_API_KEY" &>/dev/null; then printf "  %b●%b %-15s configured\n" "$C_GREEN" "$C_RESET" "Serper"
    else printf "  %b○%b %-15s not configured  %b%s%b\n" "$C_DIM" "$C_RESET" "Serper" "$C_DIM" "SERPER_API_KEY" "$C_RESET"; fi
    if api_get_key "PERPLEXITY_API_KEY" &>/dev/null; then printf "  %b●%b %-15s configured\n" "$C_GREEN" "$C_RESET" "Perplexity"
    else printf "  %b○%b %-15s not configured  %b%s%b\n" "$C_DIM" "$C_RESET" "Perplexity" "$C_DIM" "PERPLEXITY_API_KEY" "$C_RESET"; fi
    printf "  %b●%b %-15s always available (no key needed)\n" "$C_GREEN" "$C_RESET" "DuckDuckGo"

    echo ""; ui_section "AI Providers"
    local configured=0
    local -A provider_keys=(
        [OpenAI]="OPENAI_API_KEY" [Anthropic]="ANTHROPIC_API_KEY" [Google_AI]="GOOGLE_AI_API_KEY"
        [Groq]="GROQ_API_KEY" [Mistral]="MISTRAL_API_KEY" [Together]="TOGETHER_API_KEY"
        [Perplexity]="PERPLEXITY_API_KEY" [Cohere]="COHERE_API_KEY" [DeepSeek]="DEEPSEEK_API_KEY" [xAI]="XAI_API_KEY"
    )
    for name in $(echo "${!provider_keys[@]}" | tr ' ' '\n' | sort); do
        local key="${provider_keys[$name]}"
        if api_get_key "$key" &>/dev/null; then
            local _model_val; _model_val=$(api_get_key "PROVIDER_MODEL_${name^^}" 2>/dev/null)
            [ -z "$_model_val" ] && [ "$name" = "Google_AI" ] && _model_val=$(api_get_key "PROVIDER_MODEL_GOOGLE" 2>/dev/null)
            if [ -n "$_model_val" ]; then
                printf "  %b\u25cf%b %-15s configured  %bmodel: %s%b\n" "$C_GREEN" "$C_RESET" "$name" "$C_DIM" "$_model_val" "$C_RESET"
            else printf "  %b\u25cf%b %-15s configured\n" "$C_GREEN" "$C_RESET" "$name"; fi
            configured=$((configured + 1))
        else printf "  %b○%b %-15s not configured  %b%s%b\n" "$C_DIM" "$C_RESET" "$name" "$C_DIM" "$key" "$C_RESET"; fi
    done
}
