# Streaming Pipeline Architecture

> How tokens flow from LLM backends through FIFOs, SSE parsers, and thinking-tag state machines to the terminal.

---

## Table of Contents

- [Design Philosophy](#design-philosophy)
- [High-Level Data Flow](#high-level-data-flow)
- [Backend Detection and Initialization](#backend-detection-and-initialization)
- [The FIFO Streaming Pattern](#the-fifo-streaming-pattern)
- [SSE (Server-Sent Events) Parsing](#sse-server-sent-events-parsing)
- [Thinking Model Support](#thinking-model-support)
- [Token Budget and Sampling Resolution](#token-budget-and-sampling-resolution)
- [Cancellation and Cleanup](#cancellation-and-cleanup)
- [Streaming Inside Command Substitution](#streaming-inside-command-substitution)
- [Troubleshooting](#troubleshooting)
- [Key Functions Reference](#key-functions-reference)

---

## Design Philosophy

The streaming pipeline is built around three constraints:

1. **Mobile-first** — Running on Termux/ARM means tokens arrive slowly. Users must see output in real time, not wait for complete responses.
2. **Subshell survival** — Bash `$()` command substitution runs in a subshell, which normally prevents streaming to the terminal. The system works around this with `/dev/tty`.
3. **Responsive cancellation** — Ctrl+C must kill the active `curl` process immediately and return to the REPL prompt, not hang waiting for a response that's no longer needed.

These constraints drove every architectural decision: FIFOs for PID tracking, `/dev/tty` for visible streaming inside captures, file-based state for subshell survival, and trap handlers for cleanup.

---

## High-Level Data Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│                         LLM Backend                                  │
│  (Ollama /api/generate or llama-server /v1/chat/completions)        │
└──────────────────────┬───────────────────────────────────────────────┘
                       │ HTTP chunked response (SSE or NDJSON)
                       ▼
┌──────────────────────────────────────────────────────────────────────┐
│                      curl (background process)                       │
│  PID tracked in $_LLM_CURL_PID for cancellation                     │
│  Writes to FIFO (named pipe) or stdout depending on mode            │
└──────────────────────┬───────────────────────────────────────────────┘
                       │ Raw lines: data: {"content":"tok",...}
                       ▼
┌──────────────────────────────────────────────────────────────────────┐
│                    Read Loop (while IFS= read -r line)               │
│                                                                      │
│  ┌─ Backend Router ─────────────────────────────────────────────┐   │
│  │  Ollama:     jq '.response // .message.content'              │   │
│  │  llama-server: _llm_parse_llamacpp_sse() → jq delta.content  │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                       │                                              │
│                       ▼                                              │
│  ┌─ Thinking Tag State Machine ─────────────────────────────────┐   │
│  │  Phase 1: Buffer preamble (≤200 chars), detect <think>       │   │
│  │  Phase 2: Inside thinking block → show dimmed on /dev/tty    │   │
│  │  Phase 3: After </think> → output response tokens             │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                       │                                              │
│                       ▼                                              │
│  stdout (captured)  +  /dev/tty (visible to user)                    │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Backend Detection and Initialization

### `_llm_detect_backend()`

On startup, Blue Lodge probes for available LLM backends in this order:

```
1. Check LLM_BACKEND variable (user preference: "ollama", "llamacpp", "auto")
2. If "auto" or unset:
   a. Probe Ollama health endpoint (http://localhost:11434/api/tags) — 2s timeout
   b. Probe llama-server health endpoint (http://localhost:8080/health) — 2s timeout
   c. Use whichever responds first
3. Cache result in _LLM_ACTIVE_BACKEND (avoids re-probing)
```

**Why auto-detection matters**: On Termux, only one backend can hold the GPU at a time. Auto-detection finds whichever is already running.

### `_llm_start_llamacpp_server()`

When llama-server is selected but not running:

```bash
# Resolve model to GGUF file path
_models_resolve_gguf "$model_key"    # → /path/to/model.gguf

# Auto-detect vision projector (for multimodal models)
_models_find_ollama_mmproj "$model_key"  # → /path/to/mmproj.gguf or empty

# Launch with GPU configuration
llama-server \
  --model "$gguf_path" \
  --n-gpu-layers "$LLAMA_CPP_GPU_LAYERS" \  # 0=CPU, 27=all GPU
  --ctx-size "$context_size" \
  --port 8080 \
  ${mmproj:+--mmproj "$mmproj"} \           # Only if vision model
  &
```

The `${mmproj:+--mmproj "$mmproj"}` pattern is a **conditional parameter expansion** — the `--mmproj` flag is only included if `$mmproj` is non-empty. This avoids passing an empty `--mmproj ""` which would crash llama-server.

### GGUF Resolution Chain

When resolving an Ollama model reference to a GGUF blob path:

```
"blue-lodge-qwen3-think:4b"
  → Parse as Ollama tag: library/blue-lodge-qwen3-think:4b
  → Read manifest: ~/.ollama/models/manifests/registry.ollama.ai/library/...
  → Extract layer digest for application/vnd.ollama.image.model
  → Resolve to blob: ~/.ollama/models/blobs/sha256-<digest>
  → Return absolute path to GGUF file
```

This allows llama-server to use models already downloaded by Ollama without duplicating multi-gigabyte files.

---

## The FIFO Streaming Pattern

### Why FIFOs?

The core challenge: we need to **stream tokens to the terminal in real time** while also **capturing the complete response in a variable**. Bash makes this hard because:

- `result=$(curl ...)` blocks until curl finishes — no streaming
- Piping `curl | while read` loses the curl PID — can't cancel on Ctrl+C
- Background `curl &` plus polling is fragile and adds latency

FIFOs (named pipes) solve all three problems:

```bash
# Create a named pipe
local fifo
fifo=$(mktemp -u /tmp/lodge-llm-XXXXXX)
mkfifo "$fifo"

# Start curl writing TO the FIFO in background
curl -sN "$url" -d "$payload" > "$fifo" &
_LLM_CURL_PID=$!    # Track PID for cancellation

# Read FROM the FIFO in the foreground
local response=""
while IFS= read -r line; do
    token=$(_extract_token "$line")
    response+="$token"
    printf '%s' "$token"           # stdout (captured by caller's $())
    printf '%s' "$token" > /dev/tty  # visible to user NOW
done < "$fifo"

# Cleanup
rm -f "$fifo"
```

### How This Solves Each Problem

| Problem | Solution |
|---------|----------|
| No streaming in `$()` | Write to `/dev/tty` (bypasses subshell capture) |
| Can't track curl PID | curl runs as explicit background job, PID stored in `_LLM_CURL_PID` |
| Blocking read | FIFO naturally blocks until data arrives, then streams line by line |

### The `/dev/tty` Trick Explained

When code runs inside `$()` (command substitution), stdout is captured into the variable — anything printed to stdout is invisible to the user until the substitution completes. But `/dev/tty` always points to the user's actual terminal:

```bash
# This captures the response AND streams it visibly:
response=$(llm_stream "What is 2+2?")

# Inside llm_stream:
printf '%s' "$token"             # Goes to stdout → captured in $response
printf '%s' "$token" > /dev/tty  # Goes to terminal → user sees it immediately
```

This is the key insight that makes the entire streaming architecture work inside Bash.

---

## SSE (Server-Sent Events) Parsing

### Ollama NDJSON Format

Ollama streams newline-delimited JSON (one object per line):

```json
{"model":"qwen3","response":"Hello","done":false}
{"model":"qwen3","response":" world","done":false}
{"model":"qwen3","response":"","done":true,"total_duration":1234567890}
```

Parsing is straightforward — extract `.response` (for `/api/generate`) or `.message.content` (for `/api/chat`):

```bash
token=$(printf '%s' "$line" | jq -r '.response // empty')
```

The `// empty` jq operator returns nothing (instead of `null`) when the field is missing, preventing the literal string "null" from appearing in output.

### Ollama Native Thinking Field

Modern Ollama (with `think: true` in the request) provides a separate `.thinking` field:

```json
{"model":"qwen3","thinking":"Let me analyze...","response":"","done":false}
{"model":"qwen3","thinking":"","response":"The answer is 4","done":false}
```

When this field is present, no state machine is needed — thinking and response content are already separated by the API.

### llama-server SSE Format

llama-server follows the OpenAI-compatible SSE protocol:

```
data: {"id":"cmpl-123","choices":[{"delta":{"content":"Hello"}}]}
data: {"id":"cmpl-123","choices":[{"delta":{"content":" world"}}]}
data: [DONE]
```

Parsing requires stripping the `data: ` prefix and handling the `[DONE]` sentinel:

```bash
_llm_parse_llamacpp_sse() {
    local line="$1"
    # Strip SSE prefix
    line="${line#data: }"
    # Check for stream end
    [[ "$line" == "[DONE]" ]] && return 1
    # Extract content token
    printf '%s' "$line" | jq -r '.choices[0].delta.content // empty'
}
```

### llama-server Reasoning Content (b4000+)

Recent llama-server builds expose a `reasoning_content` field in the delta, similar to Ollama's `.thinking`:

```json
{"choices":[{"delta":{"reasoning_content":"Let me think...","content":""}}]}
{"choices":[{"delta":{"reasoning_content":"","content":"The answer"}}]}
```

When this field is present, the streaming loop bypasses the inline tag state machine entirely and uses the structured fields directly.

---

## Thinking Model Support

### The Problem

Thinking models (Qwen3, Ministral, Granite4) emit reasoning tokens before the actual response. These tokens appear as inline XML-like tags:

```
<think>
The user is asking about addition. 2+2=4. Simple arithmetic.
</think>
The answer is 4.
```

The streaming pipeline must:
1. **Detect** the `<think>` tag (which may arrive across multiple tokens)
2. **Display** thinking content dimmed/styled on the terminal
3. **Exclude** thinking content from the captured response
4. **Handle** models that don't think (no tags at all)

### Tag Normalization

Different models use different tag formats. The normalizer converts all variants to a canonical form:

```bash
_llm_normalize_think() {
    local -n _ntref=$1    # Nameref: modifies caller's variable directly
    _ntref="${_ntref//\[THINK\]/<think>}"
    _ntref="${_ntref//\[\/THINK\]/<\/think>}"
    _ntref="${_ntref//\[think\]/<think>}"
    _ntref="${_ntref//\[\/think\]/<\/think>}"
    # ... more variants
}
```

**Bash Technique — Namerefs**: The `local -n` declaration creates a **name reference** — `_ntref` becomes an alias for the caller's variable. When the function modifies `_ntref`, it directly modifies the original variable without any copying. This is critical for performance on ARM processors where string operations are expensive.

### The Three-Phase State Machine

When neither the Ollama `.thinking` field nor the llama-server `reasoning_content` field is available, the streaming loop falls back to an inline tag parser:

```
┌─────────────────────────────────────────────────────────┐
│ Phase 1: PREAMBLE                                       │
│   Buffer up to 200 characters                           │
│   Looking for: <think> anywhere in buffer               │
│   If found → enter Phase 2, show thinking banner        │
│   If 200 chars without tag → model doesn't think,       │
│     flush buffer to output, enter Phase 3               │
└───────────────────────┬─────────────────────────────────┘
                        │ <think> detected
                        ▼
┌─────────────────────────────────────────────────────────┐
│ Phase 2: INSIDE THINKING                                │
│   Accumulate thinking text                              │
│   Display dimmed on /dev/tty (if LODGE_THINK enabled)   │
│   Looking for: </think>                                 │
│   If found → close thinking banner, enter Phase 3       │
└───────────────────────┬─────────────────────────────────┘
                        │ </think> detected
                        ▼
┌─────────────────────────────────────────────────────────┐
│ Phase 3: RESPONSE                                       │
│   Output tokens to stdout + /dev/tty                    │
│   Handle rare late <think> re-entry (loop back to P2)   │
│   Continue until stream ends                            │
└─────────────────────────────────────────────────────────┘
```

### Phase 1: The Preamble Buffer

The 200-character buffer exists because tokens arrive one at a time, and `<think>` might be split across multiple tokens:

```
Token 1: "Let me "          → buffer: "Let me "
Token 2: "<thi"             → buffer: "Let me <thi"
Token 3: "nk>\nI need to"   → buffer contains "<think>" → Phase 2!
```

Without buffering, the parser would see `<thi` and `nk>` as separate tokens and miss the tag entirely.

### Thinking Display (`_llm_think_open`, `_llm_think_close`, `_llm_think_show`)

The thinking display is controlled by `LODGE_THINK`:

| Value | Behavior |
|-------|----------|
| `0` | Thinking completely hidden |
| `1` | Thinking shown dimmed (gray text) with banner |
| `2` | Thinking shown bright (normal text) with banner |

The banner format:

```
┌─ thinking ───────────────────────
│ Let me analyze this step by step.
│ The user wants to know about...
└──────────────────────────────────
```

These helpers write **only to `/dev/tty`** — thinking content never reaches stdout and is never captured in the response variable.

### Token Budget for Thinking Models

`_llm_apply_thinking_multiplier()` applies a 4x multiplier to `num_predict` when the current model is a thinking model:

```bash
_llm_apply_thinking_multiplier() {
    if models_current_has_thinking; then
        local base="${LLM_MAX_TOKENS:-8192}"
        echo $(( base * 4 ))
    else
        echo "${LLM_MAX_TOKENS:-8192}"
    fi
}
```

**Why 4x?** Thinking models can emit 3-4x more tokens than the visible response because the `<think>` block is often larger than the answer. Without the multiplier, the model would hit the token limit mid-thought and produce a truncated, incoherent response.

---

## Token Budget and Sampling Resolution

### Parameter Resolution Chain

Sampling parameters (temperature, repeat penalty, etc.) follow a 4-level priority chain:

```
Priority 1: Per-scenario override    LLM_TEMP_ASK=0.3
Priority 2: Per-model override       _MODEL_PARAM_qwen3_think_TEMP=0.5
Priority 3: Model registry default   _ME_TEMP (from models.sh entry)
Priority 4: Global default           LLM_TEMPERATURE=0.15
```

This is resolved in `_llm_build_opts()`:

```bash
_llm_build_opts() {
    local scenario="$1"  # "ask", "router", "specialist", "strategist"

    # Check per-scenario override first
    local scenario_upper="${scenario^^}"
    local temp_var="LLM_TEMP_${scenario_upper}"
    local temp="${!temp_var:-}"  # Indirect expansion: LLM_TEMP_ASK → value

    # If no per-scenario override, check model registry
    if [[ -z "$temp" ]]; then
        temp=$(models_get_param "$_CURRENT_MODEL" "TEMP")
    fi

    # Fallback to global
    temp="${temp:-${LLM_TEMPERATURE:-0.7}}"
}
```

**Bash Technique — Indirect Variable Expansion**: `${!temp_var}` expands the *value* of the variable whose *name* is stored in `$temp_var`. So if `scenario=ask`, then `temp_var=LLM_TEMP_ASK`, and `${!temp_var}` gives the value of `$LLM_TEMP_ASK`. This avoids a verbose case statement.

### Scenario-Specific Defaults

| Scenario | Ideal Temp | Purpose |
|----------|-----------|---------|
| `router` | 0.1 | Deterministic tool selection (no creativity needed) |
| `specialist` | 0.3 | Precise command syntax with minimal hallucination |
| `strategist` | 0.3 | Reliable task decomposition |
| `ask` | 0.5 | Conversational but focused |
| `journal` | 0.7 | Creative reflection |

---

## Cancellation and Cleanup

### Ctrl+C Flow

```
User presses Ctrl+C
        │
        ▼
_lodge_cleanup() trap fires
        │
        ├─ Kill curl: kill $_LLM_CURL_PID 2>/dev/null
        ├─ Kill spinner: kill $_SPINNER_PID 2>/dev/null
        ├─ Clean FIFO: rm -f $fifo
        ├─ Reset terminal: clear line, restore cursor
        │
        ▼
Return to REPL prompt (don't exit!)
```

**Critical detail**: The INT trap returns to the REPL loop instead of exiting. This means Ctrl+C during a long LLM response cancels just that response, not the entire session.

### Exit Cleanup

When the session ends (`/quit`, EOF, or terminal close):

```bash
_lodge_exit_cleanup() {
    # Kill any orphan curl processes (e.g., from crashed agent loops)
    pkill -f "curl.*localhost:11434" 2>/dev/null
    pkill -f "curl.*localhost:8080" 2>/dev/null

    # Clean temp files
    rm -f /tmp/lodge-llm-*
    rm -f /tmp/lodge-diff-*

    # Release Android wake lock (prevents battery drain)
    # ... termux-wake-unlock if available
}
```

---

## Streaming Inside Command Substitution

### The Core Challenge

Many callers need the LLM response as a string:

```bash
answer=$(llm_stream "What is 2+2?")
```

But `$()` captures stdout — the user would see nothing until curl finishes. The solution uses a dual-output pattern:

```bash
llm_stream() {
    local prompt="$1"
    # ... setup curl, FIFO, etc ...

    while IFS= read -r line; do
        token=$(_extract "$line")
        printf '%s' "$token"             # → stdout → captured in $answer
        printf '%s' "$token" > /dev/tty  # → terminal → user sees immediately
    done < "$fifo"
}
```

After this call:
- `$answer` contains the complete response text (from stdout)
- The user has already seen every token stream in real time (from `/dev/tty`)

### Why Not Just Pipe?

You might think `curl | tee /dev/tty` would work, but:
- `tee` adds a process, complicating PID tracking
- The read loop needs to parse JSON and handle thinking tags — raw piping doesn't work
- We need per-token control, not per-line

---

## Troubleshooting

### Tokens Not Appearing (Blank Response)

1. **Check backend health**: `llm_check` should return 0
2. **Check FIFO creation**: Look for `/tmp/lodge-llm-*` files
3. **Check jq parsing**: Manually curl and pipe through jq to verify JSON format
4. **Model not loaded**: Run `llm_warmup` to pre-load weights

### Thinking Tags Showing in Output

1. **Tag variant not normalized**: Check if the model uses a novel tag format (e.g., `{think}` instead of `<think>`)
2. **Phase 1 buffer too small**: If the model emits >200 chars before `<think>`, the state machine gives up and flushes to output
3. **Ollama version outdated**: Older Ollama doesn't support `think: true` — falls back to inline parsing

### Ctrl+C Not Cancelling

1. **curl PID not tracked**: `$_LLM_CURL_PID` might be empty if curl was started without background
2. **Trap overridden**: Another library might have replaced the INT trap
3. **Zombie FIFO**: A named pipe without a writer will block the reader forever — check for stale `/tmp/lodge-llm-*`

### Tokens Arriving But Not Streaming

1. **Not using `/dev/tty`**: The caller might be running in a context where `/dev/tty` doesn't exist (e.g., cron, SSH pipe)
2. **Buffering**: Some terminal emulators buffer output — try `stdbuf -oL` prefix

---

## Key Functions Reference

| Function | File | Purpose |
|----------|------|---------|
| `llm_generate()` | lib/llm.sh | Non-streaming generation (capture entire response) |
| `llm_stream()` | lib/llm.sh | Streaming generation (real-time + capture) |
| `llm_chat()` | lib/llm.sh | Multi-turn conversation streaming |
| `llm_vision()` | lib/llm.sh | Image analysis with base64 encoding |
| `_llm_detect_backend()` | lib/llm.sh | Auto-detect Ollama vs llama-server |
| `_llm_start_llamacpp_server()` | lib/llm.sh | Launch llama-server with GGUF model |
| `_llm_parse_llamacpp_sse()` | lib/llm.sh | Extract token from SSE `data:` line |
| `_llm_normalize_think()` | lib/llm.sh | Canonicalize thinking tag variants |
| `_llm_think_open()` | lib/llm.sh | Display thinking banner on /dev/tty |
| `_llm_think_close()` | lib/llm.sh | Close thinking banner |
| `_llm_think_show()` | lib/llm.sh | Stream thinking text dimmed |
| `_llm_apply_thinking_multiplier()` | lib/llm.sh | 4x token budget for thinking models |
| `_llm_build_opts()` | lib/llm.sh | Resolve sampling parameters (4-level chain) |
| `llm_check()` | lib/llm.sh | Health probe (0=ready, 1=fail, 2=loading) |
| `llm_warmup()` | lib/llm.sh | Pre-load model weights into VRAM |
| `llm_unload()` | lib/llm.sh | Free VRAM (keep_alive=0) |
| `llm_repl_health_check()` | lib/llm.sh | Pre-dispatch validation with auto-restart |

---

*Next: [Response Parsing Engine](RESPONSE_PARSING.md) — How raw LLM output is parsed, sanitized, and transformed into executable commands and displayable text.*
