# API Layer & Cloud Providers

> How HTTP requests are made, how cloud AI providers are integrated, and how the metering/retry system prevents rate limiting.

---

## Table of Contents

- [Design Philosophy](#design-philosophy)
- [The API Core (lib/api.sh)](#the-api-core)
- [Cloud Provider Architecture (lib/providers.sh)](#cloud-provider-architecture)
- [Provider-Specific SSE Parsing](#provider-specific-sse-parsing)
- [Metering and Rate Limiting](#metering-and-rate-limiting)
- [Retry with Exponential Backoff](#retry-with-exponential-backoff)
- [Model Quirks and Special Handling](#model-quirks-and-special-handling)
- [Provider Configuration](#provider-configuration)
- [Adding a New Provider](#adding-a-new-provider)
- [Troubleshooting](#troubleshooting)
- [Key Functions Reference](#key-functions-reference)

---

## Design Philosophy

The API and provider layers follow an **offline-first with cloud fallback** design:

1. **Local by default** — All LLM calls go to local Ollama or llama-server
2. **Provider harness** — When `GEORGE_PROVIDER` is set, calls redirect to cloud APIs
3. **Rate limit resilience** — File-based metering with inter-call delays prevents 429 errors
4. **SSE normalization** — Each provider's streaming format is parsed into the same token stream that the local backend produces

The API layer (`lib/api.sh`) provides generic HTTP primitives. The provider layer (`lib/providers.sh`) builds on those primitives with AI-specific logic.

---

## The API Core

### `api_request()` — The Foundation

Every outbound HTTP call flows through this function:

```bash
api_request() {
    local method="$1"     # GET, POST, PUT, DELETE
    local url="$2"        # Full URL
    local data="$3"       # Request body (JSON)
    shift 3
    local extra_args=("$@")  # Additional curl flags

    local response http_code
    response=$(curl -s -w "\n%{http_code}" \
        -X "$method" \
        -H "Content-Type: application/json" \
        -H "User-Agent: George/0.1 (Blue Lodge Coding Agent)" \
        ${data:+-d "$data"} \
        "${extra_args[@]}" \
        "$url")

    # Split body from status code
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    _API_LAST_STATUS="$http_code"

    case "$http_code" in
        2*) echo "$body"; return 0 ;;
        429) echo "$body"; return 2 ;;   # Rate limited
        *)   echo "$body"; return 1 ;;   # Error
    esac
}
```

**Bash Technique — `curl -w "\n%{http_code}"`**: This appends the HTTP status code as the last line of output. The function then uses `tail -1` to extract it and `sed '$d'` to remove it from the body. This avoids needing separate `-o` and `-D` flags or temp files.

**Bash Technique — `${data:+-d "$data"}`**: Conditional expansion — the `-d "$data"` flag is only included when `$data` is non-empty. This allows GET requests (no body) and POST requests (with body) to use the same code path.

### Convenience Wrappers

```bash
api_get()    { api_request "GET"    "$@"; }
api_post()   { api_request "POST"   "$@"; }
api_put()    { api_request "PUT"    "$@"; }
api_delete() { api_request "DELETE" "$@"; }
```

### `api_stream_post()` — Streaming POST

For SSE-based endpoints (LLM streaming), the function starts curl in the background and returns its PID:

```bash
api_stream_post() {
    local url="$1" data="$2"
    shift 2
    local extra_args=("$@")

    curl -sN \
        -X POST \
        -H "Content-Type: application/json" \
        "${extra_args[@]}" \
        -d "$data" \
        "$url" &
    echo $!    # Return curl PID
}
```

The `-N` flag disables curl's output buffering, ensuring tokens arrive immediately as the server sends them.

### Key Management

API keys are stored in `~/.george/keys.conf` — a simple `KEY=VALUE` file:

```bash
api_get_key() {
    local name="$1"
    grep "^${name}=" "$KEYS_FILE" | cut -d= -f2-
}

api_set_key() {
    local name="$1" value="$2"
    # Remove old entry, append new
    grep -v "^${name}=" "$KEYS_FILE" > "${KEYS_FILE}.tmp"
    echo "${name}=${value}" >> "${KEYS_FILE}.tmp"
    mv "${KEYS_FILE}.tmp" "$KEYS_FILE"
}
```

**Bash Technique — `grep -v` + append**: To update a key, first remove any existing line matching the key name, then append the new value. This pattern is simpler and safer than `sed -i` for key-value files because it handles keys with special characters in their values.

### `api_require_key()` — Defensive Key Checking

```bash
api_require_key() {
    local name="$1"
    local value
    value=$(api_get_key "$name")
    if [[ -z "$value" ]]; then
        ui_err "API key '$name' not configured"
        ui_info "Run: /api set $name <your-key>"
        return 1
    fi
    echo "$value"
}
```

This is called before any API operation. Instead of silently failing with an authentication error, it tells the user exactly how to fix the missing key.

### Rate Limit Retry

```bash
api_retry() {
    local max_retries="$1"
    shift
    local cmd=("$@")

    local attempt=0 delay=2
    while (( attempt < max_retries )); do
        "${cmd[@]}" && return 0

        if [[ "$_API_LAST_STATUS" == "429" ]]; then
            ui_warn "Rate limited. Waiting ${delay}s..."
            sleep "$delay"
            delay=$(( delay * 2 ))    # Exponential backoff: 2→4→8→16
            ((attempt++))
        else
            return 1   # Non-429 error, don't retry
        fi
    done
    return 1
}
```

---

## Cloud Provider Architecture

### The Provider Harness

When `GEORGE_PROVIDER` is set (e.g., `openai`, `anthropic`, `google`), all LLM calls are intercepted and rerouted:

```
Normal flow:          llm_stream() → curl localhost:11434
Provider flow:        llm_stream() → provider_stream_chat() → curl api.openai.com
```

This interception happens inside `llm_stream()` and `llm_generate()`:

```bash
llm_stream() {
    # ... setup ...
    if [[ -n "${GEORGE_PROVIDER:-}" ]]; then
        provider_stream_chat "$system_prompt" "$user_prompt"
        return $?
    fi
    # ... local backend code ...
}
```

### Supported Providers

| Provider | Endpoint | Models | Notes |
|----------|----------|--------|-------|
| OpenAI | api.openai.com | GPT-4o, GPT-4o-mini, o1, o3 | o1/o3 use `developer` role |
| Anthropic | api.anthropic.com | Claude Sonnet, Opus, Haiku | Custom SSE format |
| Google | generativelanguage.googleapis.com | Gemini models | Array-based chunks |
| Groq | api.groq.com | Llama 3.3, Mixtral | OpenAI-compatible |
| Mistral | api.mistral.ai | Mistral Large | OpenAI-compatible |
| Together | api.together.xyz | Llama, open-source | OpenAI-compatible |
| Perplexity | api.perplexity.ai | Sonar (search-augmented) | OpenAI-compatible |
| Cohere | api.cohere.com | Command R+ | NDJSON format |
| DeepSeek | api.deepseek.com | deepseek-chat, deepseek-reasoner | Reasoner strips temp |
| xAI | api.x.ai | Grok | OpenAI-compatible |

### `provider_chat()` — Synchronous Call

```bash
provider_chat() {
    local system_prompt="$1" user_prompt="$2"

    _provider_meter_throttle   # Wait if too many recent calls

    local payload
    payload=$(_provider_build_payload "$system_prompt" "$user_prompt")

    local endpoint url headers
    _provider_resolve_endpoint  # Sets url, headers based on GEORGE_PROVIDER

    local response
    response=$(api_post "$url" "$payload" "${headers[@]}")

    _provider_extract_content "$response"  # Provider-specific content extraction
}
```

### `provider_stream_chat()` — Streaming Call

```bash
provider_stream_chat() {
    local system_prompt="$1" user_prompt="$2"

    _provider_meter_throttle

    local payload
    payload=$(_provider_build_payload "$system_prompt" "$user_prompt" "stream")

    local url headers
    _provider_resolve_endpoint

    # Start streaming curl in background
    local curl_pid
    curl_pid=$(api_stream_post "$url" "$payload" "${headers[@]}")

    # Dispatch to provider-specific SSE parser
    case "$GEORGE_PROVIDER" in
        anthropic)  _provider_anthropic_sse_loop "$curl_pid" ;;
        google)     _provider_google_sse_loop "$curl_pid" ;;
        cohere)     _provider_cohere_sse_loop "$curl_pid" ;;
        *)          _provider_sse_loop "$curl_pid" ;;  # OpenAI-compatible
    esac
}
```

---

## Provider-Specific SSE Parsing

### OpenAI-Compatible (`_provider_sse_loop`)

Most providers follow the OpenAI SSE format. The generic loop handles them all:

```bash
_provider_sse_loop() {
    local curl_pid="$1"
    local full_response="" in_think=0

    while IFS= read -r line <&3; do
        # Strip SSE prefix
        [[ "$line" != data:* ]] && continue
        line="${line#data: }"
        [[ "$line" == "[DONE]" ]] && break

        # Extract content token
        local token
        token=$(printf '%s' "$line" | jq -r '.choices[0].delta.content // empty')
        [[ -z "$token" ]] && continue

        # Handle thinking tags (shared with local backend)
        if [[ "$token" == *"<think>"* ]]; then
            _llm_think_open
            in_think=1
        fi

        if (( in_think )); then
            _llm_think_show "$token"
            if [[ "$token" == *"</think>"* ]]; then
                _llm_think_close
                in_think=0
            fi
        else
            printf '%s' "$token"
            printf '%s' "$token" > /dev/tty
            full_response+="$token"
        fi
    done 3< <(cat /proc/$curl_pid/fd/1 2>/dev/null || wait $curl_pid)

    echo "$full_response"
}
```

### Anthropic (`_provider_anthropic_sse_loop`)

Anthropic uses typed events instead of simple data lines:

```
event: message_start
data: {"type": "message_start", "message": {"id": "msg_..."}}

event: content_block_delta
data: {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "Hello"}}

event: message_stop
data: {"type": "message_stop"}
```

The parser must switch behavior based on the event type:

```bash
_provider_anthropic_sse_loop() {
    local event_type=""
    while IFS= read -r line; do
        if [[ "$line" == event:* ]]; then
            event_type="${line#event: }"
            continue
        fi
        [[ "$line" != data:* ]] && continue
        line="${line#data: }"

        case "$event_type" in
            content_block_delta)
                local token
                token=$(printf '%s' "$line" | jq -r '.delta.text // empty')
                [[ -n "$token" ]] && printf '%s' "$token"
                ;;
            message_stop)
                break
                ;;
        esac
    done
}
```

### Google (`_provider_google_sse_loop`)

Google streams JSON arrays rather than SSE events:

```json
[{"candidates":[{"content":{"parts":[{"text":"Hello"}]}}]}]
```

The parser handles this non-standard format:

```bash
_provider_google_sse_loop() {
    while IFS= read -r line; do
        local token
        token=$(printf '%s' "$line" | \
            jq -r '.[0].candidates[0].content.parts[0].text // empty' 2>/dev/null)
        [[ -n "$token" ]] && printf '%s' "$token"
    done
}
```

### Cohere (`_provider_cohere_sse_loop`)

Cohere uses newline-delimited JSON (NDJSON) with event type fields:

```json
{"event_type":"text-generation","text":"Hello"}
{"event_type":"text-generation","text":" world"}
{"event_type":"stream-end","finish_reason":"COMPLETE"}
```

---

## Metering and Rate Limiting

### File-Based Call Tracking

The metering system uses temp files to survive subshells (bash variables are lost in `$()`):

```
~/.cache/george-provider-meter.$PID/
├── calls          ← Timestamps of each API call (one per line)
└── last_call      ← Timestamp of most recent call
```

```bash
_provider_meter_init() {
    _METER_DIR="${HOME}/.cache/george-provider-meter.$$"
    mkdir -p "$_METER_DIR"
    touch "$_METER_DIR/calls" "$_METER_DIR/last_call"
}

_provider_meter_count() {
    local window_seconds="${1:-60}"
    local cutoff=$(( $(date +%s) - window_seconds ))
    awk -v cutoff="$cutoff" '$1 >= cutoff' "$_METER_DIR/calls" | wc -l
}
```

**Why file-based?** Because provider calls often happen inside `$()` command substitution (subshells). A bash variable set inside `$()` is invisible to the parent shell. Files persist across subshell boundaries.

### Inter-Call Delay

```bash
_provider_inter_call_delay() {
    local now=$(date +%s)
    local last=$(cat "$_METER_DIR/last_call" 2>/dev/null || echo 0)
    local elapsed=$(( now - last ))
    local delay="${PROVIDER_CALL_DELAY:-7}"

    if (( elapsed < delay )); then
        local wait_time=$(( delay - elapsed ))
        sleep "$wait_time"
    fi

    echo "$now" > "$_METER_DIR/last_call"
    echo "$now" >> "$_METER_DIR/calls"
}
```

**Why 7 seconds?** Most free-tier APIs allow ~10 requests per minute. A 7-second inter-call delay keeps the system under 9 calls/minute, providing headroom. This is configurable via `PROVIDER_CALL_DELAY`.

### Throttle Gate

```bash
_provider_meter_throttle() {
    _provider_inter_call_delay

    # Check rolling window limit
    local count
    count=$(_provider_meter_count 60)
    local limit="${PROVIDER_RPM_LIMIT:-10}"

    if (( count >= limit )); then
        local wait=$((60 - $(date +%s) % 60))
        ui_warn "Rate limit approaching ($count/$limit RPM). Waiting ${wait}s..."
        sleep "$wait"
    fi
}
```

---

## Retry with Exponential Backoff

### `_provider_call_with_backoff()`

Wraps synchronous provider calls with intelligent retry:

```bash
_provider_call_with_backoff() {
    local max_retries="${PROVIDER_MAX_RETRIES:-4}"
    local backoff="${PROVIDER_INITIAL_BACKOFF:-5}"
    local max_backoff="${PROVIDER_MAX_BACKOFF:-60}"

    local attempt=0
    while (( attempt < max_retries )); do
        local response exit_code
        response=$(provider_chat "$@")
        exit_code=$?

        # Success
        (( exit_code == 0 )) && { echo "$response"; return 0; }

        # Check for retryable errors
        if _provider_is_retryable "$response" "$exit_code"; then
            ui_warn "Attempt $((attempt+1))/$max_retries failed. Retrying in ${backoff}s..."
            sleep "$backoff"
            backoff=$(( backoff * 2 ))
            (( backoff > max_backoff )) && backoff=$max_backoff
            ((attempt++))
        else
            echo "$response"
            return 1   # Non-retryable error
        fi
    done

    ui_err "All $max_retries attempts failed."
    return 1
}
```

### Retryable Error Detection

```bash
_provider_is_retryable() {
    local response="$1" exit_code="$2"

    # HTTP 429 (rate limit)
    [[ "$_API_LAST_STATUS" == "429" ]] && return 0

    # Common rate limit strings in response body
    echo "$response" | grep -qiE 'rate.limit|quota.exceeded|too.many.requests' && return 0

    # Server errors (temporary)
    [[ "$_API_LAST_STATUS" == 5* ]] && return 0

    return 1   # Not retryable
}
```

### Streaming Fallback

If streaming fails (some providers return errors on stream requests but work on sync), the system falls back:

```bash
_provider_stream_with_backoff() {
    # Try streaming first
    provider_stream_chat "$@" && return 0

    # Fallback to sync on stream failure
    ui_warn "Streaming failed, falling back to synchronous call"
    _provider_call_with_backoff "$@"
}
```

---

## Model Quirks and Special Handling

### OpenAI o1/o3 (No System Role)

OpenAI's reasoning models reject the `system` role in messages. The provider rewrites it:

```bash
# Normal payload:
# {"messages": [{"role":"system","content":"..."}, {"role":"user","content":"..."}]}

# o1/o3 payload:
# {"messages": [{"role":"developer","content":"..."}, {"role":"user","content":"..."}]}
```

### DeepSeek Reasoner (No Temperature)

DeepSeek's reasoning model crashes if temperature is included:

```bash
if [[ "$provider_model" == *"reasoner"* ]]; then
    payload=$(echo "$payload" | jq 'del(.temperature)')
fi
```

### DeepSeek Reasoning Content

The reasoner puts its thinking in `reasoning_content` instead of inline tags:

```bash
# If content is empty but reasoning_content exists
token=$(echo "$line" | jq -r '.choices[0].delta.reasoning_content // empty')
```

### Google Gemma (No System Instruction)

Gemma models reject the `systemInstruction` field. The provider inlines the system prompt as a preamble to the first user message:

```bash
if [[ "$provider_model" == *"gemma"* ]]; then
    user_content="[System Instructions]\n${system_prompt}\n\n[User]\n${user_prompt}"
    # Remove systemInstruction from payload
fi
```

---

## Provider Configuration

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `GEORGE_PROVIDER` | (empty) | Active provider name |
| `PROVIDER_CALL_DELAY` | 7 | Seconds between API calls |
| `PROVIDER_MAX_RETRIES` | 4 | Retry attempts on 429 |
| `PROVIDER_INITIAL_BACKOFF` | 5 | Initial backoff seconds |
| `PROVIDER_MAX_BACKOFF` | 60 | Backoff ceiling seconds |
| `PROVIDER_RPM_LIMIT` | 10 | Rolling window call limit |

### API Key Requirements

| Provider | Key Variable | How to Get |
|----------|-------------|------------|
| OpenAI | `OPENAI_API_KEY` | platform.openai.com |
| Anthropic | `ANTHROPIC_API_KEY` | console.anthropic.com |
| Google | `GOOGLE_AI_API_KEY` | aistudio.google.com |
| Groq | `GROQ_API_KEY` | console.groq.com |
| DeepSeek | `DEEPSEEK_API_KEY` | platform.deepseek.com |

---

## Adding a New Provider

To add a new cloud provider:

### 1. Define the Endpoint

In `_provider_resolve_endpoint()`:

```bash
newprovider)
    url="https://api.newprovider.com/v1/chat/completions"
    headers=(-H "Authorization: Bearer $(api_get_key NEWPROVIDER_API_KEY)")
    ;;
```

### 2. Build the Payload

If the provider is OpenAI-compatible, the default payload builder works. Otherwise, add a case to `_provider_build_payload()`:

```bash
newprovider)
    # Custom payload format
    payload=$(jq -n \
        --arg model "$provider_model" \
        --arg system "$system_prompt" \
        --arg user "$user_prompt" \
        '{model: $model, messages: [{role:"system",content:$system},{role:"user",content:$user}]}')
    ;;
```

### 3. Add SSE Parser (if non-standard)

If the provider uses a custom streaming format:

```bash
_provider_newprovider_sse_loop() {
    while IFS= read -r line; do
        # Parse provider-specific format
        local token
        token=$(echo "$line" | jq -r '.your.custom.path // empty')
        [[ -n "$token" ]] && printf '%s' "$token"
    done
}
```

Add to the dispatch in `provider_stream_chat()`:

```bash
newprovider) _provider_newprovider_sse_loop "$curl_pid" ;;
```

### 4. Register Models

Add supported models to `provider_models()`:

```bash
newprovider)
    echo "newprovider-large"
    echo "newprovider-small"
    ;;
```

### 5. Handle Quirks

If the provider has special requirements (no system role, different auth, etc.), add to the appropriate case statements.

---

## Troubleshooting

### 429 Rate Limit Errors

1. **Increase inter-call delay**: `PROVIDER_CALL_DELAY=15`
2. **Check metering**: Look for `~/.cache/george-provider-meter.*` directories
3. **Manual throttle test**: Count calls in last 60 seconds from the calls file

### Empty Responses from Provider

1. **Check API key**: `/api status` shows configured keys
2. **Check model name**: Some providers use exact naming (`gpt-4o` not `gpt4o`)
3. **Check SSE parser**: Add `set -x` before the SSE loop to see raw lines

### Streaming Works But Sync Doesn't (or Vice Versa)

1. **Stream flag**: Ensure `"stream": true` is in the payload for streaming calls
2. **Content-Type**: Some providers require `application/json` even for SSE
3. **Timeout**: Sync calls may need longer timeout than streaming

### Thinking Not Displayed for Cloud Models

1. **Provider support**: Not all cloud models support thinking tags
2. **SSE parser**: Verify the parser checks for `<think>` in tokens
3. **LODGE_THINK**: Must be ≥ 1 to display thinking

---

## Key Functions Reference

### API Core (lib/api.sh)

| Function | Purpose |
|----------|---------|
| `api_request()` | Base HTTP client with status code extraction |
| `api_get/post/put/delete()` | Method-specific wrappers |
| `api_stream_post()` | Background streaming POST, returns PID |
| `api_json_escape()` | Escape strings via jq |
| `api_bearer_header()` | Build OAuth2 Bearer header |
| `api_get_key()` / `api_set_key()` | Encrypted key storage |
| `api_require_key()` | Fail with setup instructions if missing |
| `api_retry()` | Exponential backoff on 429 |

### Provider Layer (lib/providers.sh)

| Function | Purpose |
|----------|---------|
| `provider_chat()` | Synchronous cloud LLM call |
| `provider_stream_chat()` | Streaming cloud LLM call |
| `provider_models()` | List available models |
| `_provider_sse_loop()` | Generic OpenAI-compatible SSE parser |
| `_provider_anthropic_sse_loop()` | Anthropic typed-event SSE parser |
| `_provider_google_sse_loop()` | Google array-based SSE parser |
| `_provider_cohere_sse_loop()` | Cohere NDJSON parser |
| `_provider_meter_throttle()` | Rate limit gate (sleep if needed) |
| `_provider_call_with_backoff()` | Retry with exponential backoff |
| `_provider_inter_call_delay()` | Enforce minimum gap between calls |

---

*Previous: [Response Parsing Engine](RESPONSE_PARSING.md) | Next: [Agent Loop & Task Execution](AGENT_LOOP.md)*
