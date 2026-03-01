#!/bin/bash
# ── George: LLM Interface ─────────────────────────────────
# Multi-backend LLM wrapper. Supports Ollama and llama.cpp (llama-server).
# Auto-detects which backend is available; falls back gracefully.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/models.sh"

# ── Config ─────────────────────────────────────────────────────
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
LLAMA_CPP_URL="${LLAMA_CPP_URL:-http://127.0.0.1:8080}"
# Tell Ollama where the model blobs actually live. Inside proot-distro
# $HOME=/root/ but models were pulled in native Termux. Without this,
# Ollama defaults to /root/.ollama/models (empty inside proot).
export OLLAMA_MODELS="${OLLAMA_MODELS:-$(_lodge_termux_home)/.ollama/models}"
# Path to llama-server binary (resolved via _lodge_termux_home for proot compat)
LLAMA_CPP_SERVER_BIN="${LLAMA_CPP_SERVER_BIN:-$(_lodge_termux_home)/llama.cpp/build/bin/llama-server}"
# Path to GGUF model file for llama-server
LLAMA_CPP_MODEL="${LLAMA_CPP_MODEL:-}"
# GPU layers to offload (1 = minimal GPU validation, 0 = CPU only)
LLAMA_CPP_GPU_LAYERS="${LLAMA_CPP_GPU_LAYERS:-1}"
# Context size for llama-server
LLAMA_CPP_CTX_SIZE="${LLAMA_CPP_CTX_SIZE:-8192}"
# Backend preference: auto (detect llamacpp first, fallback ollama), llamacpp, ollama
LLM_BACKEND="${LLM_BACKEND:-auto}"
# Cached backend result (set by _llm_detect_backend, cleared on /backend change)
_LLM_BACKEND_CACHE=""
# PID file for llama-server started by lodge
_LLAMA_CPP_PID_FILE="${TMPDIR:-/tmp}/.lodge-llama-server.pid"
LODGE_MODEL="${LODGE_MODEL:-blue-lodge}"
LLM_MAX_TOKENS="${LLM_MAX_TOKENS:-20480}"   # Default max output tokens (matches Modelfile num_predict ceiling)
LLM_ASK_TOKENS="${LLM_ASK_TOKENS:-20480}"   # Max output tokens for /ask (model stops at <|im_end|>; this is just a safety cap)
LLM_AGENT_TOKENS="${LLM_AGENT_TOKENS:-20480}" # Max output tokens for agent specialist
LLM_STRATEGIST_TOKENS="${LLM_STRATEGIST_TOKENS:-512}" # Max output tokens for strategist (one sentence milestone + thinking)
LLM_EVALUATOR_TOKENS="${LLM_EVALUATOR_TOKENS:-512}"   # Max output tokens for evaluator (completion judge)
LLM_ROUTER_TOKENS="${LLM_ROUTER_TOKENS:-256}" # Max output tokens for agent router (think ~100-200 + tool name)
LLM_BUDGET_TOKENS="${LLM_BUDGET_TOKENS:-1024}" # Max thinking tokens before responding (0=unlimited)
LLM_BUDGET_ASK="${LLM_BUDGET_ASK:-1024}"     # Think budget for /ask conversations (extended thinking useful)
LLM_BUDGET_AGENT="${LLM_BUDGET_AGENT:-512}"  # Think budget for strategist/specialist (focused output)
LLM_BUDGET_ROUTER="${LLM_BUDGET_ROUTER:-128}" # Think budget for router (just pick a tool name)
LLM_BUDGET_JOURNAL="${LLM_BUDGET_JOURNAL:-64}" # Think budget for journal (background utility, fast)
LLM_BUDGET_TOOL="${LLM_BUDGET_TOOL:-256}"    # Think budget for tools (commit, web, recall, slash)

# ── Sampling parameters (per-scenario, override model defaults) ──
# ── Sampling parameters ────────────────────────────────────────
# Global defaults are set from the active model's registry at init
# by models_apply_defaults(). When a model is switched, all params
# are reset to the new model's values. Users can override any
# param via /model and it persists until the next model switch or
# /model reset.
#
# Safety-net defaults below cover the gap between llm.sh sourcing
# and models_init() being called. Once models_init() runs, these
# are overwritten with registry values from the active model.
LLM_TEMPERATURE="${LLM_TEMPERATURE:-0.15}"
LLM_REPEAT_PENALTY="${LLM_REPEAT_PENALTY:-1.2}"
LLM_PRESENCE_PENALTY="${LLM_PRESENCE_PENALTY:-0.3}"

# Per-scenario overrides (empty = use model default from registry).
# Set via /model temp-ask, /model repeat-agent, etc.
# When empty, _llm_build_opts() falls through to the model base.
LLM_TEMP_ASK="${LLM_TEMP_ASK:-}"
LLM_REPEAT_ASK="${LLM_REPEAT_ASK:-}"
LLM_PRESENCE_ASK="${LLM_PRESENCE_ASK:-}"

LLM_TEMP_AGENT="${LLM_TEMP_AGENT:-}"
LLM_REPEAT_AGENT="${LLM_REPEAT_AGENT:-}"
LLM_PRESENCE_AGENT="${LLM_PRESENCE_AGENT:-}"

LLM_TEMP_ROUTER="${LLM_TEMP_ROUTER:-}"
LLM_REPEAT_ROUTER="${LLM_REPEAT_ROUTER:-}"
LLM_PRESENCE_ROUTER="${LLM_PRESENCE_ROUTER:-}"

LLM_TEMP_JOURNAL="${LLM_TEMP_JOURNAL:-}"
LLM_REPEAT_JOURNAL="${LLM_REPEAT_JOURNAL:-}"
LLM_PRESENCE_JOURNAL="${LLM_PRESENCE_JOURNAL:-}"

LLM_TEMP_TOOL="${LLM_TEMP_TOOL:-}"
LLM_REPEAT_TOOL="${LLM_REPEAT_TOOL:-}"
LLM_PRESENCE_TOOL="${LLM_PRESENCE_TOOL:-}"

LLM_TIMEOUT="${LLM_TIMEOUT:-600}"           # Safety net: 600s max per request (thinking models on ARM need headroom; Ctrl+C also works)
LLM_KEEP_ALIVE="${LLM_KEEP_ALIVE:-30m}"     # How long model stays loaded after last request
LODGE_THINK="${LODGE_THINK:-1}"               # 1=show thinking tokens dimmed (default), 0=hide thinking tokens (model always thinks)
LODGE_THINK_STREAM="${LODGE_THINK_STREAM:-1}"  # When LODGE_THINK=1: 0=hide thinking, 1=show dimmed, 2=show bright (cyan)
LODGE_NOTHINK="${LODGE_NOTHINK:-0}"             # 0=model thinks normally, 1=suppress reasoning (model-specific: /no_think for Qwen, system prompt for Granite)
LODGE_DEBUG="${LODGE_DEBUG:-0}"                 # 0=normal, 1=show timers + token counts per LLM call

# ── Bracket think-tag normalizer ───────────────────────────────
# Models hallucinate various bracket think tags: [THINK], [think],
# [THOUGHT], [thought] and their closing counterparts.
# This helper normalises them all to <think>/</ think> in-place
# via a bash nameref — zero subshell overhead on the hot token path.
_llm_normalize_think() {
    local -n _ntref="$1"
    _ntref="${_ntref//\[THINK\]/<think>}"
    _ntref="${_ntref//\[\/THINK\]/<\/think>}"
    _ntref="${_ntref//\[think\]/<think>}"
    _ntref="${_ntref//\[\/think\]/<\/think>}"
    _ntref="${_ntref//\[THOUGHT\]/<think>}"
    _ntref="${_ntref//\[\/THOUGHT\]/<\/think>}"
    _ntref="${_ntref//\[thought\]/<think>}"
    _ntref="${_ntref//\[\/thought\]/<\/think>}"
}

# ── Sampling parameter resolver ────────────────────────────────
# Resolves per-scenario sampling parameters based on LLM_SCENARIO.
# Callers set `local LLM_SCENARIO=ask` before calling llm_generate/llm_stream/llm_chat.
# Returns a jq-compatible JSON fragment for options injection.
#
# Priority chain (highest → lowest):
#   1. Per-scenario override (LLM_TEMP_ASK, etc.)
#   2. Per-model override (set via /models param)
#   3. Model registry default (from _MODELS_REGISTRY)
#   4. Global default (LLM_TEMPERATURE, etc.)
#
# Scenarios: ask, agent, router, journal, tool (empty = model/global defaults)
_llm_build_opts() {
    local np="$1"  # num_predict
    local scenario="${LLM_SCENARIO:-}"

    # ── Step 1: Get model-specific base values ────────────────
    # These come from the model registry + any per-model overrides,
    # so Llama/Granite/Ministral get their own tuned defaults
    # instead of Qwen3's values.
    local model_temp model_rep model_pres
    if declare -f models_get_param &>/dev/null && [ -n "$LODGE_MODEL" ]; then
        model_temp=$(models_get_param "$LODGE_MODEL" temp 2>/dev/null) || model_temp=""
        model_rep=$(models_get_param "$LODGE_MODEL" repeat 2>/dev/null) || model_rep=""
        model_pres=$(models_get_param "$LODGE_MODEL" presence 2>/dev/null) || model_pres=""
    fi
    # Fall back to globals if model lookup fails
    model_temp="${model_temp:-$LLM_TEMPERATURE}"
    model_temp="${model_temp:-0.7}"  # safety net: jq --argjson crashes on empty string
    model_rep="${model_rep:-$LLM_REPEAT_PENALTY}"
    model_rep="${model_rep:-1.2}"
    model_pres="${model_pres:-$LLM_PRESENCE_PENALTY}"
    model_pres="${model_pres:-0.3}"

    # ── Step 2: Apply per-scenario overrides ──────────────────
    # If a scenario-specific value is set, it REPLACES the model
    # default (absolute value, NOT additive). Empty = inherit model.
    local temp rep pres
    case "$scenario" in
        ask)     temp="${LLM_TEMP_ASK:-$model_temp}"; rep="${LLM_REPEAT_ASK:-$model_rep}"; pres="${LLM_PRESENCE_ASK:-$model_pres}" ;;
        agent)      temp="${LLM_TEMP_AGENT:-$model_temp}"; rep="${LLM_REPEAT_AGENT:-$model_rep}"; pres="${LLM_PRESENCE_AGENT:-$model_pres}" ;;
        strategist) temp="${LLM_TEMP_AGENT:-$model_temp}"; rep="${LLM_REPEAT_AGENT:-$model_rep}"; pres="${LLM_PRESENCE_AGENT:-$model_pres}" ;;
        router)     temp="${LLM_TEMP_ROUTER:-$model_temp}"; rep="${LLM_REPEAT_ROUTER:-$model_rep}"; pres="${LLM_PRESENCE_ROUTER:-$model_pres}" ;;
        journal) temp="${LLM_TEMP_JOURNAL:-$model_temp}"; rep="${LLM_REPEAT_JOURNAL:-$model_rep}"; pres="${LLM_PRESENCE_JOURNAL:-$model_pres}" ;;
        tool)    temp="${LLM_TEMP_TOOL:-$model_temp}"; rep="${LLM_REPEAT_TOOL:-$model_rep}"; pres="${LLM_PRESENCE_TOOL:-$model_pres}" ;;
        *)       temp="$model_temp"; rep="$model_rep"; pres="$model_pres" ;;
    esac

    jq -n \
        --argjson np "$np" \
        --argjson temp "$temp" \
        --argjson rep "$rep" \
        --argjson pres "$pres" \
        '{num_predict:$np, temperature:$temp, repeat_penalty:$rep, presence_penalty:$pres}'
}

# ── Debug tracking state ───────────────────────────────────────
# File-based counters survive $() subshells (shell vars don't).
_LLM_DEBUG_DIR="${TMPDIR:-/tmp}/.lodge-debug-$$"
_LLM_DEBUG_TASK_START=""

# ── Active request tracking (for cancellation) ─────────────────
_LLM_CURL_PID=""
_LLM_ACTIVE=0

# ── Backend detection ──────────────────────────────────────────
# Returns "llamacpp" or "ollama". Caches result for the session
# to avoid repeated network pings. Clear _LLM_BACKEND_CACHE to re-detect.
#
# Priority: LLM_BACKEND preference → auto-detect (llamacpp first, ollama fallback)
_llm_detect_backend() {
    # Return cache if available
    if [ -n "$_LLM_BACKEND_CACHE" ]; then
        echo "$_LLM_BACKEND_CACHE"
        return 0
    fi

    # Manual override — skip detection
    case "$LLM_BACKEND" in
        llamacpp|llama-cpp|llama_cpp)
            _LLM_BACKEND_CACHE="llamacpp"
            echo "llamacpp"
            return 0
            ;;
        ollama)
            _LLM_BACKEND_CACHE="ollama"
            echo "ollama"
            return 0
            ;;
    esac

    # Auto-detect: try llama-server health endpoint first (faster GPU path)
    if curl -sf --max-time 2 "$LLAMA_CPP_URL/health" 2>/dev/null | grep -q '"status"'; then
        _LLM_BACKEND_CACHE="llamacpp"
        echo "llamacpp"
        return 0
    fi

    # Fallback to Ollama
    if curl -sf --max-time 2 "$OLLAMA_URL/api/tags" &>/dev/null; then
        _LLM_BACKEND_CACHE="ollama"
        echo "ollama"
        return 0
    fi

    # Neither available — default to ollama (llm_ensure will handle startup)
    _LLM_BACKEND_CACHE="ollama"
    echo "ollama"
    return 1
}

# ── llama-server lifecycle helpers ─────────────────────────────
# Shared by _models_switch() (model hot-swap) and /backend command.

# Stop the running llama-server (if any).
# Returns 0 whether it stopped or wasn't running.
_llm_stop_llamacpp_server() {
    local quiet="${1:-}"
    if [ -f "$_LLAMA_CPP_PID_FILE" ]; then
        local _pid
        _pid=$(cat "$_LLAMA_CPP_PID_FILE" 2>/dev/null)
        if kill -0 "$_pid" 2>/dev/null; then
            kill "$_pid" 2>/dev/null
            # Wait up to 5s for graceful shutdown
            local _tries=0
            while [ $_tries -lt 10 ] && kill -0 "$_pid" 2>/dev/null; do
                sleep 0.5
                _tries=$((_tries + 1))
            done
            kill -9 "$_pid" 2>/dev/null  # force if still alive
            [ "$quiet" != "--quiet" ] && ui_ok "llama-server stopped (was PID $_pid)"
        else
            [ "$quiet" != "--quiet" ] && ui_dim "llama-server was not running (stale PID file removed)"
        fi
        rm -f "$_LLAMA_CPP_PID_FILE"
    else
        # No PID file — try pgrep
        local _pid
        _pid=$(pgrep -f "llama-server.*--port" 2>/dev/null | head -1)
        if [ -n "$_pid" ]; then
            kill "$_pid" 2>/dev/null
            sleep 1
            kill -9 "$_pid" 2>/dev/null
            [ "$quiet" != "--quiet" ] && ui_ok "llama-server stopped (PID $_pid)"
        else
            [ "$quiet" != "--quiet" ] && ui_dim "llama-server is not running"
        fi
    fi
    _LLM_BACKEND_CACHE=""
    return 0
}

# Start llama-server with the given GGUF model path.
# Args: model_path [--quiet]
# Returns 0 when server is healthy, 1 on failure.
_llm_start_llamacpp_server() {
    local model_path="$1"
    local quiet="${2:-}"
    local chat_template_file="${3:-}"   # optional path to .jinja template file override

    # Validate
    if [ ! -f "$model_path" ]; then
        [ "$quiet" != "--quiet" ] && ui_err "Model file not found: $model_path"
        return 1
    fi
    if [ ! -x "$LLAMA_CPP_SERVER_BIN" ]; then
        [ "$quiet" != "--quiet" ] && ui_err "llama-server not found: $LLAMA_CPP_SERVER_BIN"
        return 1
    fi

    # Check if already running
    if [ -f "$_LLAMA_CPP_PID_FILE" ]; then
        local _existing_pid
        _existing_pid=$(cat "$_LLAMA_CPP_PID_FILE" 2>/dev/null)
        if kill -0 "$_existing_pid" 2>/dev/null; then
            [ "$quiet" != "--quiet" ] && ui_warn "llama-server already running (PID $_existing_pid). Stop it first."
            return 1
        fi
        rm -f "$_LLAMA_CPP_PID_FILE"
    fi

    local _port
    _port=$(echo "$LLAMA_CPP_URL" | grep -oP ':\K[0-9]+$' || echo "8080")

    [ "$quiet" != "--quiet" ] && ui_dim "Starting llama-server on port $_port..."

    # Build launch args
    local _launch_args=(
        -m "$model_path"
        --port "$_port"
        -ngl "$LLAMA_CPP_GPU_LAYERS"
        -c "$LLAMA_CPP_CTX_SIZE"
        --threads "$(nproc 2>/dev/null || echo 4)"
    )

    # Chat template: use the Jinja2 engine for the template embedded in the
    # GGUF's tokenizer.chat_template metadata.  This replaces the old approach
    # of mapping model names to built-in C++ template names (--chat-template),
    # which produced gibberish for fine-tuned models (e.g. Unsloth) whose
    # templates include custom tokens ([THINK]/[/THINK], [SYSTEM_PROMPT], etc).
    if [ -n "$chat_template_file" ] && [ -f "$chat_template_file" ]; then
        _launch_args+=(--jinja --chat-template-file "$chat_template_file")
        [ "$quiet" != "--quiet" ] && ui_dim "Chat template: $chat_template_file (external file, jinja)"
    else
        _launch_args+=(--jinja)
        [ "$quiet" != "--quiet" ] && ui_dim "Chat template: GGUF-embedded (--jinja)"
    fi

    "$LLAMA_CPP_SERVER_BIN" "${_launch_args[@]}" \
        > "${TMPDIR:-/tmp}/lodge-llama-server.log" 2>&1 &
    local _pid=$!
    echo "$_pid" > "$_LLAMA_CPP_PID_FILE"

    # Wait for healthy (up to 30s)
    local _tries=0
    while [ $_tries -lt 30 ]; do
        sleep 1
        if curl -sf --max-time 2 "$LLAMA_CPP_URL/health" 2>/dev/null | grep -q '"status"'; then
            _LLM_BACKEND_CACHE=""
            LLAMA_CPP_MODEL="$model_path"
            [ "$quiet" != "--quiet" ] && ui_ok "llama-server started (PID $_pid)"
            return 0
        fi
        # Check if process died
        if ! kill -0 "$_pid" 2>/dev/null; then
            [ "$quiet" != "--quiet" ] && ui_err "llama-server died during startup"
            [ "$quiet" != "--quiet" ] && tail -5 "${TMPDIR:-/tmp}/lodge-llama-server.log" 2>/dev/null | while IFS= read -r _line; do ui_dim "  $_line"; done
            rm -f "$_LLAMA_CPP_PID_FILE"
            return 1
        fi
        _tries=$((_tries + 1))
    done

    # Timeout
    [ "$quiet" != "--quiet" ] && ui_err "llama-server failed to start within 30s"
    [ "$quiet" != "--quiet" ] && ui_dim "  Log: ${TMPDIR:-/tmp}/lodge-llama-server.log"
    kill "$_pid" 2>/dev/null
    rm -f "$_LLAMA_CPP_PID_FILE"
    return 1
}

# ── Build llama.cpp payload ────────────────────────────────────
# Translates Blue Lodge parameters into OpenAI-compatible payload
# for llama-server's /v1/chat/completions endpoint.
# Usage: _llm_build_llamacpp_payload "prompt" "system" "opts_json" "max_tokens" [stream]
_llm_build_llamacpp_payload() {
    local prompt="$1"
    local system="${2:-}"
    local opts_json="$3"
    local max_tokens="$4"
    local stream="${5:-true}"

    # Extract sampling params from opts_json
    local temp rep pres
    temp=$(echo "$opts_json" | jq -r '.temperature // 0.7')
    rep=$(echo "$opts_json" | jq -r '.repeat_penalty // 1.2')
    pres=$(echo "$opts_json" | jq -r '.presence_penalty // 0.3')

    # Build messages array (OpenAI format)
    local messages
    if [ -n "$system" ]; then
        messages=$(jq -n \
            --arg sys "$system" \
            --arg usr "$prompt" \
            '[{role:"system",content:$sys},{role:"user",content:$usr}]')
    else
        messages=$(jq -n \
            --arg usr "$prompt" \
            '[{role:"user",content:$usr}]')
    fi

    jq -n \
        --argjson messages "$messages" \
        --argjson max_tokens "$max_tokens" \
        --argjson temperature "$temp" \
        --argjson frequency_penalty "$rep" \
        --argjson presence_penalty "$pres" \
        --argjson stream "$stream" \
        '{messages:$messages, max_tokens:$max_tokens, temperature:$temperature, frequency_penalty:$frequency_penalty, presence_penalty:$presence_penalty, stream:$stream}'
}

# ── Parse llama.cpp SSE stream line ────────────────────────────
# Extracts content token from a single SSE line.
# Returns the token text, or sets _LLAMACPP_DONE=1 on [DONE].
# Usage: _llm_parse_llamacpp_sse "data: {...}" → token in stdout
_LLAMACPP_DONE=0
_llm_parse_llamacpp_sse() {
    local line="$1"

    # Skip empty lines and non-data lines (SSE format)
    [[ "$line" == data:* ]] || return 0

    # Strip "data: " prefix
    local json="${line#data: }"

    # Check for stream termination
    if [ "$json" = "[DONE]" ]; then
        _LLAMACPP_DONE=1
        return 0
    fi

    # Extract content from OpenAI delta format
    echo "$json" | jq -r '.choices[0].delta.content // empty' 2>/dev/null
}

# ── Health Check ───────────────────────────────────────────────
llm_check() {
    local backend
    backend=$(_llm_detect_backend)

    if [ "$backend" = "llamacpp" ]; then
        # llama-server /health returns {"status":"ok"} when ready
        local resp
        resp=$(curl -sf --max-time 5 "$LLAMA_CPP_URL/health" 2>/dev/null)
        if [ $? -ne 0 ]; then
            return 1
        fi
        local status
        status=$(echo "$resp" | jq -r '.status // empty' 2>/dev/null)
        if [ "$status" = "ok" ]; then
            return 0
        elif [ "$status" = "loading model" ] || [ "$status" = "no slot available" ]; then
            return 2  # Server running but not ready
        fi
        return 1
    fi

    # Ollama path (original)
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
    local backend
    backend=$(_llm_detect_backend)

    if [ "$backend" = "llamacpp" ]; then
        # llama-server always has its model loaded if /health returns ok
        local resp
        resp=$(curl -sf --max-time 2 "$LLAMA_CPP_URL/health" 2>/dev/null)
        [ $? -ne 0 ] && return 1
        echo "$resp" | jq -e '.status == "ok"' &>/dev/null
        return $?
    fi

    local resp
    resp=$(curl -sf --max-time 5 "$OLLAMA_URL/api/ps" 2>/dev/null)
    [ $? -ne 0 ] && return 1
    echo "$resp" | jq -e ".models[] | select(.name == \"$LODGE_MODEL\")" &>/dev/null
}

# ── Unload model from memory ───────────────────────────────────
# Sends a request with keep_alive=0 to immediately free RAM.
# Safe to call — does not affect GEORGE.md or journal persistence.
# llama-server: no-op (model lifecycle managed by server process)
llm_unload() {
    local backend
    backend=$(_llm_detect_backend)

    if [ "$backend" = "llamacpp" ]; then
        ui_dim "llama-server manages its own model lifecycle (no-op)"
        return 0
    fi

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
# llama-server: model is always loaded; sends a minimal completion to verify.
llm_warmup() {
    if llm_is_loaded; then
        return 0  # already hot
    fi

    local backend
    backend=$(_llm_detect_backend)

    if [ "$backend" = "llamacpp" ]; then
        # llama-server loads the model at startup. Send a trivial
        # completion to verify it's responsive.
        curl -sf --max-time 10 "$LLAMA_CPP_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":1}' > /dev/null 2>&1
        return 0
    fi

    # Ollama warmup
    # Model-aware warmup: use nothink suffix to skip reasoning if supported.
    # For Qwen: "Hello /no_think". For others: just "Hello" with num_predict=1.
    local _warmup_prompt="Hello"
    local _method
    _method=$(models_nothink_method)
    [ "$_method" = "qwen" ] && _warmup_prompt="Hello /no_think"
    local payload
    payload=$(jq -n \
        --arg model "$LODGE_MODEL" \
        --arg prompt "$_warmup_prompt" \
        --arg keep_alive "$LLM_KEEP_ALIVE" \
        '{model: $model, prompt: $prompt, stream: false, keep_alive: $keep_alive, options: {num_predict: 1}}')
    local _warmup_resp
    _warmup_resp=$(curl -s --max-time 30 "$OLLAMA_URL/api/generate" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)
    local _warmup_err
    _warmup_err=$(echo "$_warmup_resp" | jq -r '.error // empty' 2>/dev/null)
    if [ -n "$_warmup_err" ]; then
        local _tty="/dev/tty"
        [ -w /dev/tty ] 2>/dev/null || _tty="/dev/stderr"

        # Detect stale Ollama binary from package-manager update (dpkg/apt).
        # When Ollama is updated while running, the daemon caches the old
        # binary path (e.g. ollama.dpkg-tmp) which no longer exists.
        # Fix: kill the stale daemon and start a fresh one.
        if [[ "$_warmup_err" == *"dpkg-tmp"* ]] || [[ "$_warmup_err" == *"dpkg-new"* ]]; then
            printf "\033[33m⚠ Ollama has a stale binary (package update while running)\033[0m\n" > "$_tty" 2>/dev/null
            if command -v ollama &>/dev/null; then
                printf "\033[2m  Restarting Ollama...\033[0m\n" > "$_tty" 2>/dev/null
                killall ollama 2>/dev/null || true
                sleep 2
                ollama serve > /tmp/lodge-ollama.log 2>&1 &
                disown 2>/dev/null
                # Wait for Ollama to become responsive
                local _retries=0
                while [ $_retries -lt 10 ]; do
                    if curl -sf --max-time 2 "$OLLAMA_URL/api/tags" &>/dev/null; then
                        break
                    fi
                    sleep 1
                    _retries=$((_retries + 1))
                done
                # Retry warmup with fresh daemon
                _warmup_resp=$(curl -s --max-time 30 "$OLLAMA_URL/api/generate" \
                    -H "Content-Type: application/json" \
                    -d "$payload" 2>/dev/null)
                _warmup_err=$(echo "$_warmup_resp" | jq -r '.error // empty' 2>/dev/null)
                if [ -z "$_warmup_err" ]; then
                    printf "\033[32m  ✓ Ollama restarted — model loaded\033[0m\n" > "$_tty" 2>/dev/null
                    return 0
                fi
                printf "\033[31m  ✗ Restart failed: %s\033[0m\n" "$_warmup_err" > "$_tty" 2>/dev/null
            else
                printf "\033[33m  Restart Ollama manually: killall ollama && ollama serve &\033[0m\n" > "$_tty" 2>/dev/null
            fi
            return 1
        fi

        printf "\033[33m⚠ Warmup failed: %s\033[0m\n" "$_warmup_err" > "$_tty" 2>/dev/null
        return 1
    fi
}

# ── Ensure LLM backend is running ─────────────────────────────
llm_ensure() {
    local backend
    backend=$(_llm_detect_backend)

    # Capture llm_check return code immediately — $? gets overwritten
    # by subsequent commands (echo, if, ui_warn, etc.)
    llm_check
    local status=$?

    if [ "$backend" = "llamacpp" ]; then
        if [ "$status" -eq 0 ]; then
            return 0
        fi
        # llama-server not responding — attempt auto-start
        if [ -x "$LLAMA_CPP_SERVER_BIN" ]; then
            ui_warn "llama-server not responding. Attempting to start..."
            # Resolve model to start with
            local _gguf="$LLAMA_CPP_MODEL"
            if [ -z "$_gguf" ] || [ ! -f "$_gguf" ]; then
                # Try to resolve from the current primary model
                local _key=""
                for entry in "${_MODELS_REGISTRY[@]}"; do
                    _models_parse_entry "$entry"
                    if [ "$_ME_NAME" = "$LODGE_MODEL_PRIMARY" ] || [ "$_ME_KEY" = "$LODGE_MODEL_PRIMARY" ]; then
                        _key="$_ME_KEY"
                        break
                    fi
                done
                if [ -n "$_key" ]; then
                    _gguf=$(_models_resolve_gguf "$_key" 2>/dev/null)
                fi
            fi
            if [ -n "$_gguf" ] && [ -f "$_gguf" ]; then
                if _llm_start_llamacpp_server "$_gguf"; then
                    _MODELS_ACTIVE="$LODGE_MODEL_PRIMARY"
                    LODGE_MODEL="$LODGE_MODEL_PRIMARY"
                    return 0
                fi
            fi
            ui_err "Could not auto-start llama-server (no GGUF found for $LODGE_MODEL_PRIMARY)"
            ui_dim "  Pull a model first: ollama pull <model>"
            ui_dim "  Then start manually: /backend start <model-key>"
        else
            ui_err "llama-server not found at: $LLAMA_CPP_SERVER_BIN"
            ui_dim "  Build guide: docs/ADRENO_GPU_SETUP.md"
        fi
        return 1
    fi

    # Ollama path
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

# ── Create the model from registry Modelfile ───────────────────
# Resolves LODGE_MODEL to a registry key, generates the correct
# per-model Modelfile, and creates. Falls back to root Modelfile
# only if the model isn't in the registry (legacy/custom models).
llm_create_model() {
    local _model="${LODGE_MODEL:-}"
    [ -z "$_model" ] && { ui_err "LODGE_MODEL not set"; return 1; }

    # Try registry lookup by model name → get key for Modelfile generation
    local _entry _key=""
    _entry=$(_models_lookup "$_model" 2>/dev/null) && {
        _models_parse_entry "$_entry"
        _key="$_ME_KEY"
    }

    if [ -n "$_key" ]; then
        # Registry model — generate correct per-model Modelfile
        local _mf
        _mf=$(models_generate_modelfile "$_key") || {
            ui_err "Failed to generate Modelfile for '$_key'"
            return 1
        }
        ollama create "$_model" -f "$_mf" 2>&1
    elif [ -f "$LODGE_DIR/Modelfile" ]; then
        # Fallback: root Modelfile (legacy/custom models only)
        ui_warn "Model '$_model' not in registry — using root Modelfile"
        ollama create "$_model" -f "$LODGE_DIR/Modelfile" 2>&1
    else
        ui_err "No Modelfile found for '$_model'"
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

    # Detect active backend
    local _active_backend
    _active_backend=$(_llm_detect_backend)

    # Ensure correct model is loaded for this scenario
    models_ensure_for_scenario "${LLM_SCENARIO:-}"

    # Model-aware nothink: append model-specific suffix (e.g., /no_think for Qwen3)
    local _nt
    _nt=$(models_nothink_suffix)
    [ -n "$_nt" ] && prompt="${prompt}${_nt}"

    # ── Thinking directive injection ───────────────────────────
    # When a runtime system prompt is passed, it REPLACES the
    # Modelfile's SYSTEM block — silently losing the thinking
    # instruction. Prepend it so the model always sees it.
    # SKIP for router: it just picks a tool name (one word).
    # Strategist gets thinking — safeguarded by LLM_STRATEGIST_TOKENS
    # cap, repeat_penalty, and milestone cleanup in agent.sh.
    if [ -n "$system" ] && declare -f models_thinking_directive &>/dev/null \
       && [ "${LLM_SCENARIO:-}" != "router" ]; then
        local _think_dir
        _think_dir=$(models_thinking_directive)
        if [ -n "$_think_dir" ]; then
            system="${_think_dir}\n\n${system}"
        fi
    fi

    # Build options with per-scenario sampling parameters
    local _opts
    _opts=$(_llm_build_opts "$max_tokens")

    # ── llama.cpp path (OpenAI-compatible) ─────────────────────
    # Early-return branch: avoids touching Ollama's thinking-token
    # parsing. llama-server has no thinking API — all output is
    # content tokens via SSE /v1/chat/completions.
    if [ "$_active_backend" = "llamacpp" ]; then
        payload=$(_llm_build_llamacpp_payload "$prompt" "$system" "$_opts" "$max_tokens" true)

        local curl_timeout="${LLM_TIMEOUT:-600}"
        local timeout_cmd=""
        if [ "$curl_timeout" -gt 0 ] 2>/dev/null; then
            command -v timeout &>/dev/null && timeout_cmd="timeout $curl_timeout"
        fi

        _LLM_ACTIVE=1
        local _tty="/dev/tty"
        [ -w /dev/tty ] 2>/dev/null || _tty="/dev/stderr"
        local _tmpdir="${TMPDIR:-/tmp}"
        local _got_tokens="$_tmpdir/.lodge-gen-tok-$$"
        local _cancel_file="$_tmpdir/.lodge-cancel-$$"
        rm -f "$_got_tokens"

        local _dbg_out=0

        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf "\n [debug] generate (llamacpp): url=%s max_tokens=%s\n" "$LLAMA_CPP_URL" "$max_tokens" > "$_tty" 2>/dev/null

        $timeout_cmd curl -sN --connect-timeout 10 --max-time "$curl_timeout" \
            "$LLAMA_CPP_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null | while IFS= read -r line; do
            [ -f "$_cancel_file" ] && break

            # SSE format: lines prefixed with "data: "
            [[ "$line" == data:* ]] || continue
            local json="${line#data: }"

            # Stream termination
            if [ "$json" = "[DONE]" ]; then
                if [ "${LODGE_DEBUG:-0}" -eq 1 ]; then
                    _llm_debug_end_timer "generate(llamacpp)" "?" "$_dbg_out"
                fi
                break
            fi

            local token
            token=$(echo "$json" | jq -r '.choices[0].delta.content // empty' 2>/dev/null)
            if [ -n "$token" ]; then
                [ -f "$_got_tokens" ] || touch "$_got_tokens"
                printf "%s" "$token"
                _dbg_out=$((_dbg_out + 1))
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf "\033[90m%s\033[0m" "$token" > "$_tty" 2>/dev/null
            fi
        done

        _LLM_ACTIVE=0
        if [ ! -f "$_got_tokens" ]; then
            rm -f "$_got_tokens"
            echo "ERROR: LLM request failed or returned no tokens (llamacpp)"
            return 1
        fi
        rm -f "$_got_tokens"
        return 0
    fi

    # ── Ollama path (original) ─────────────────────────────────

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

    # Inject budget_tokens at top level (Ollama ignores it inside options)
    if [ "${budget:-0}" -gt 0 ] 2>/dev/null; then
        payload=$(echo "$payload" | jq --argjson bt "$budget" '. + {budget_tokens: $bt}')
    fi

    # Inject think:true for models with native thinking template support
    # Required for granite4-preview (Ollama .thinking field), improves Qwen3 (separate field vs inline tags)
    # NOT sent to system-prompt thinkers (Ministral) — causes Ollama to malform response stream
    if [ "${LODGE_NOTHINK:-0}" -eq 0 ] && models_supports_think_flag "$LODGE_MODEL" 2>/dev/null; then
        payload=$(echo "$payload" | jq '. + {think: true}')
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
    # Start outside think block — detect <think> dynamically.
    # Previously assumed has_thinking models always start with <think>,
    # but Granite4 (and others) may skip thinking on simple queries,
    # causing the entire response to be buffered as "thinking".
    local _in_think_block=0
    local _can_think=0
    models_current_has_thinking && _can_think=1
    local _think_pending=""
    local _response_pending=""    # buffer to detect <think> at start of response
    # Ministral needs a larger buffer — it may emit a few words of preamble
    # before starting <think> tags. 200 chars catches most cases.
    local _think_detect_limit=200

    # ── Debug tty echo helper ─────────────────────────────────
    # When LODGE_DEBUG=1, echo response tokens to tty (dimmed) so
    # the user can watch generation in real time. Without this,
    # llm_generate is completely silent during the $() capture.
    _gen_tty() {
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && [ -n "$1" ] && printf "\033[90m%s\033[0m" "$1" > "$_tty" 2>/dev/null
    }

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf "\n [debug] generate think: _can_think=%s model=%s\n" "$_can_think" "$LODGE_MODEL" > "$_tty" 2>/dev/null

    $timeout_cmd curl -sN --connect-timeout 10 --max-time "$curl_timeout" \
        "$OLLAMA_URL/api/generate" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null | while IFS= read -r line; do
        # Cooperative cancellation check
        [ -f "$_cancel_file" ] && break

        # Check for Ollama error response (e.g., model not found, OOM)
        local _ollama_err
        _ollama_err=$(echo "$line" | jq -r '.error // empty' 2>/dev/null)
        if [ -n "$_ollama_err" ]; then
            if [ -n "$_SPINNER_PID" ] && kill -0 "$_SPINNER_PID" 2>/dev/null; then
                kill "$_SPINNER_PID" 2>/dev/null
                printf "\r%*s\r" 60 "" > "$_tty" 2>/dev/null
            fi
            printf "\033[31mOllama error: %s\033[0m\n" "$_ollama_err" > "$_tty" 2>/dev/null
            echo "ERROR: $_ollama_err"
            break
        fi

        local think_token token
        think_token=$(echo "$line" | jq -r '.thinking // empty' 2>/dev/null)
        token=$(echo "$line" | jq -r '.response // empty' 2>/dev/null)

        # Strip <response>...</response> wrapper tags (Granite preview emits these)
        token="${token//<response>/}"
        token="${token//<\/response>/}"

        # Normalize bracket think tags → <think>/</think>
        _llm_normalize_think token

        # ── Handle .thinking field (Ollama separate-field mode) ──
        if [ -n "$think_token" ]; then
            # Late-arriving .thinking field: if we already flushed the
            # response buffer in inline-tag mode, switch to separate-field
            # mode now. This handles models that emit a few .response
            # tokens before .thinking (e.g., Granite4-preview).
            if [ "$_saw_thinking_field" -eq 0 ]; then
                _saw_thinking_field=1
                _can_think=0  # disable inline-tag parsing
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf " [debug] generate: .thinking field detected — switching to separate-field mode\n" > "$_tty" 2>/dev/null
            fi
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
                # Emit response to stdout (captured by caller's $())
                printf "%s" "$token"
                _gen_tty "$token"
            else
                # ── Inline-tag fallback mode ──
                # Detect <think> anywhere in the early response buffer.
                # Models may emit conversational preamble before <think>.
                # Buffer up to 50 chars to catch late-arriving tags.
                if [ "$_can_think" -eq 1 ] && [ "$_in_think_block" -eq 0 ]; then
                    _response_pending+="$token"
                    # Normalize bracket think tags in buffer (may split across tokens)
                    _llm_normalize_think _response_pending
                    if [[ "$_response_pending" == *"<think>"* ]]; then
                        _in_think_block=1
                        _think_pending="${_response_pending#*<think>}"
                        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf " [debug] generate: <think> detected inline (at %d chars)\n" "${#_response_pending}" > "$_tty" 2>/dev/null
                        # Output anything before <think> as response (preamble)
                        local _before="${_response_pending%%<think>*}"
                        _before="${_before//<\/think>/}"
                        [ -n "$_before" ] && printf "%s" "$_before"
                        [ -n "$_before" ] && _gen_tty "$_before"
                        _response_pending=""
                        if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                            _think_banner_open=1
                            local _c; [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && _c="\033[36m" || _c="\033[90m"
                            printf "\n%b┌─ thinking ─\033[0m\n%b" "$_c" "$_c" > "$_tty" 2>/dev/null
                        fi
                    elif [ ${#_response_pending} -ge $_think_detect_limit ]; then
                        # Buffer overflow guard — no <think> found in buffer
                        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf " [debug] generate: no <think> in %d chars, flushing buffer\n" "$_think_detect_limit" > "$_tty" 2>/dev/null
                        _response_pending="${_response_pending//<\/think>/}"
                        printf "%s" "$_response_pending"
                        _gen_tty "$_response_pending"
                        _response_pending=""
                        _can_think=0
                    fi
                    continue
                fi

                if [ "$_in_think_block" -eq 1 ]; then
                    _think_pending+="$token"
                    # Normalize bracket think tags in buffer (may split across tokens)
                    _llm_normalize_think _think_pending
                    if [[ "$_think_pending" == *"</think>"* ]]; then
                        local _think_before="${_think_pending%%</think>*}"
                        local _after_think="${_think_pending#*</think>}"
                        _after_think="${_after_think//<\/think>/}"
                        if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                            [ -n "$_think_before" ] && printf "%s" "$_think_before" > "$_tty" 2>/dev/null
                            _think_banner_open=0
                            local _c; [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && _c="\033[36m" || _c="\033[90m"
                            printf "\033[0m\n%b└────────────\033[0m\n" "$_c" > "$_tty" 2>/dev/null
                        fi
                        _in_think_block=0
                        _think_pending=""
                        [ -n "$_after_think" ] && printf "%s" "$_after_think"
                        [ -n "$_after_think" ] && _gen_tty "$_after_think"
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
                # Strip orphan </think> tags (some models emit duplicates)
                token="${token//<\/think>/}"
                # Check for late <think> tag (model re-entered thinking)
                if [[ "$token" == *"<think>"* ]]; then
                    local _before_late="${token%%<think>*}"
                    [ -n "$_before_late" ] && printf "%s" "$_before_late"
                    [ -n "$_before_late" ] && _gen_tty "$_before_late"
                    _in_think_block=1
                    _can_think=1
                    _think_pending="${token#*<think>}"
                    if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                        _think_banner_open=1
                        local _c; [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && _c="\033[36m" || _c="\033[90m"
                        printf "\n%b┌─ thinking ─\033[0m\n%b" "$_c" "$_c" > "$_tty" 2>/dev/null
                    fi
                    continue
                fi
                [ -n "$token" ] && printf "%s" "$token"
                [ -n "$token" ] && _gen_tty "$token"
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
            # Flush any response_pending buffer (very short response, never reached 7 chars)
            if [ -n "$_response_pending" ]; then
                _response_pending="${_response_pending//\[THINK\]/<think>}"
                _response_pending="${_response_pending//\[\/THINK\]/<\/think>}"
                _response_pending="${_response_pending//<\/think>/}"
                _response_pending="${_response_pending//<think>/}"
                [ -n "$_response_pending" ] && printf "%s" "$_response_pending"
                [ -n "$_response_pending" ] && _gen_tty "$_response_pending"
            fi
            # Flush pending think text as response if </think> never arrived
            if [ "$_in_think_block" -eq 1 ] && [ -n "$_think_pending" ]; then
                _think_pending="${_think_pending//\[\/THINK\]/<\/think>}"
                _think_pending="${_think_pending//<\/think>/}"
                printf "%s" "$_think_pending"
                _gen_tty "$_think_pending"
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

    # Detect active backend
    local _active_backend
    _active_backend=$(_llm_detect_backend)

    # Ensure correct model is loaded for this scenario
    models_ensure_for_scenario "${LLM_SCENARIO:-}"

    # Model-aware nothink: append model-specific suffix (e.g., /no_think for Qwen3)
    local _nt
    _nt=$(models_nothink_suffix)
    [ -n "$_nt" ] && prompt="${prompt}${_nt}"

    # ── Thinking directive injection ───────────────────────────
    # Runtime system prompt REPLACES the Modelfile's SYSTEM block.
    # Prepend the thinking directive so it's never lost.
    # Skip for router — it just picks a tool name.
    if [ -n "$system" ] && declare -f models_thinking_directive &>/dev/null \
       && [ "${LLM_SCENARIO:-}" != "router" ]; then
        local _think_dir
        _think_dir=$(models_thinking_directive)
        if [ -n "$_think_dir" ]; then
            system="${_think_dir}\n\n${system}"
        fi
    fi

    # Build options with per-scenario sampling parameters
    local _opts
    _opts=$(_llm_build_opts "$max_tokens")

    # ── llama.cpp streaming path ───────────────────────────────
    # SSE-based streaming to tty. No thinking API — all output is
    # content tokens. Uses spinner for prefill wait.
    if [ "$_active_backend" = "llamacpp" ]; then
        payload=$(_llm_build_llamacpp_payload "$prompt" "$system" "$_opts" "$max_tokens" true)

        local curl_timeout="${LLM_TIMEOUT:-300}"
        local timeout_cmd=""
        if [ "$curl_timeout" -gt 0 ] 2>/dev/null; then
            command -v timeout &>/dev/null && timeout_cmd="timeout $curl_timeout"
        fi

        local _tmpdir="${TMPDIR:-/tmp}"
        local _cancel_file="$_tmpdir/.lodge-cancel-$$"

        _LLM_ACTIVE=1
        local _llm_spinner_pid=""
        local _llm_ft_file="$_tmpdir/.lodge-ft-$$"
        rm -f "$_llm_ft_file"
        ui_spinner_start "Thinking"
        _llm_spinner_pid="$_SPINNER_PID"

        local _tty="/dev/tty"
        [ -w /dev/tty ] 2>/dev/null || _tty="/dev/stderr"

        local _dbg_out=0

        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf "\n [debug] stream (llamacpp): url=%s max_tokens=%s\n" "$LLAMA_CPP_URL" "$max_tokens" > "$_tty" 2>/dev/null

        $timeout_cmd curl -sN --connect-timeout 10 --max-time "$curl_timeout" \
            "$LLAMA_CPP_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null | while IFS= read -r line; do
            [ -f "$_cancel_file" ] && break

            [[ "$line" == data:* ]] || continue
            local json="${line#data: }"

            if [ "$json" = "[DONE]" ]; then
                if [ "${LODGE_DEBUG:-0}" -eq 1 ]; then
                    _llm_debug_end_timer "stream(llamacpp)" "?" "$_dbg_out"
                fi
                echo ""
                echo "" > "$_tty" 2>/dev/null
                break
            fi

            local token
            token=$(echo "$json" | jq -r '.choices[0].delta.content // empty' 2>/dev/null)
            if [ -n "$token" ]; then
                # Kill spinner on first token
                if [ ! -f "$_llm_ft_file" ]; then
                    touch "$_llm_ft_file"
                    kill "$_llm_spinner_pid" 2>/dev/null
                    printf "\r%*s\r" 60 "" > "$_tty" 2>/dev/null
                fi
                printf "%s" "$token"
                printf "%s" "$token" > "$_tty" 2>/dev/null
                _dbg_out=$((_dbg_out + 1))
            fi
        done

        ui_spinner_stop
        rm -f "$_llm_ft_file"
        _LLM_ACTIVE=0

        if [ -f "$_cancel_file" ]; then
            return 1
        fi
        return 0
    fi

    # ── Ollama path (original) ─────────────────────────────────

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

    # Inject budget_tokens at top level (Ollama ignores it inside options)
    if [ "${budget:-0}" -gt 0 ] 2>/dev/null; then
        payload=$(echo "$payload" | jq --argjson bt "$budget" '. + {budget_tokens: $bt}')
    fi

    # Inject think:true for models with native thinking template support
    # NOT sent to system-prompt thinkers (Ministral)
    if [ "${LODGE_NOTHINK:-0}" -eq 0 ] && models_supports_think_flag "$LODGE_MODEL" 2>/dev/null; then
        payload=$(echo "$payload" | jq '. + {think: true}')
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
    # Start outside think block — detect <think> dynamically.
    # Previously assumed has_thinking models always start with <think>,
    # but Granite4 (and others) may skip thinking on simple queries,
    # causing the entire response to be buffered as "thinking".
    local _in_think_block=0
    local _can_think=0
    models_current_has_thinking && _can_think=1
    local _think_pending=""       # fallback mode: buffer for split </think>
    local _response_pending=""    # buffer to detect <think> at start of response
    # Ministral needs a larger buffer — it may emit preamble before <think>.
    local _think_detect_limit=200

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf "\n [debug] stream think: _can_think=%s model=%s LODGE_THINK=%s\n" "$_can_think" "$LODGE_MODEL" "${LODGE_THINK:-0}" > "$_tty" 2>/dev/null

    $timeout_cmd curl -sN --connect-timeout 10 --max-time "$curl_timeout" \
        "$OLLAMA_URL/api/generate" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null | while IFS= read -r line; do
        # Check for cancellation
        [ -f "$_cancel_file" ] && break

        # Check for Ollama error response (e.g., model not found, OOM)
        local _ollama_err
        _ollama_err=$(echo "$line" | jq -r '.error // empty' 2>/dev/null)
        if [ -n "$_ollama_err" ]; then
            kill "$_llm_spinner_pid" 2>/dev/null
            printf "\r%*s\r" 60 "" > "$_tty" 2>/dev/null
            printf "\033[31mOllama error: %s\033[0m\n" "$_ollama_err" > "$_tty" 2>/dev/null
            echo "ERROR: $_ollama_err"
            break
        fi

        local think_token token
        think_token=$(echo "$line" | jq -r '.thinking // empty' 2>/dev/null)
        token=$(echo "$line" | jq -r '.response // empty' 2>/dev/null)

        # Strip <response>...</response> wrapper tags (Granite preview emits these)
        token="${token//<response>/}"
        token="${token//<\/response>/}"

        # Normalize bracket think tags → <think>/</think>
        _llm_normalize_think token

        # ── Handle .thinking field (Ollama separate-field mode) ──
        if [ -n "$think_token" ]; then
            # Late-arriving .thinking field: switch to separate-field mode
            # even if we already started parsing inline tags.
            if [ "$_saw_thinking_field" -eq 0 ]; then
                _saw_thinking_field=1
                _can_think=0  # disable inline-tag parsing
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf " [debug] stream: .thinking field detected — switching to separate-field mode\n" > "$_tty" 2>/dev/null
                # If we buffered response text before .thinking arrived,
                # flush it before switching modes (it was preamble)
                if [ -n "$_response_pending" ]; then
                    _llm_normalize_think _response_pending
                    _response_pending="${_response_pending//<\/think>/}"
                    [ -n "$_response_pending" ] && printf "%s" "$_response_pending"
                    [ -n "$_response_pending" ] && printf "%s" "$_response_pending" > "$_tty" 2>/dev/null
                    _response_pending=""
                fi
            fi
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
                # Detect <think> anywhere in the early response buffer.
                # Models may emit conversational preamble before <think>.
                # Buffer up to 50 chars to catch late-arriving tags.
                if [ "$_can_think" -eq 1 ] && [ "$_in_think_block" -eq 0 ]; then
                    _response_pending+="$token"
                    # Normalize bracket think tags in buffer (may split across tokens)
                    _llm_normalize_think _response_pending
                    if [[ "$_response_pending" == *"<think>"* ]]; then
                        _in_think_block=1
                        _think_pending="${_response_pending#*<think>}"
                        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf " [debug] stream: <think> detected inline (at %d chars)\n" "${#_response_pending}" > "$_tty" 2>/dev/null
                        # Output anything before <think> as response (preamble)
                        local _before="${_response_pending%%<think>*}"
                        _before="${_before//<\/think>/}"
                        if [ -n "$_before" ]; then
                            printf "%s" "$_before"
                            printf "%s" "$_before" > "$_tty" 2>/dev/null
                        fi
                        _response_pending=""
                        _think_banner_open=1
                        _think_open
                    elif [ ${#_response_pending} -ge $_think_detect_limit ]; then
                        # Buffer overflow guard — no <think> found in buffer
                        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf " [debug] stream: no <think> in %d chars, flushing buffer\n" "$_think_detect_limit" > "$_tty" 2>/dev/null
                        _response_pending="${_response_pending//<\/think>/}"
                        printf "%s" "$_response_pending"
                        printf "%s" "$_response_pending" > "$_tty" 2>/dev/null
                        _response_pending=""
                        _can_think=0
                    fi
                    continue
                fi

                if [ "$_in_think_block" -eq 1 ]; then
                    _think_pending+="$token"
                    # Normalize bracket think tags in buffer (may split across tokens)
                    _llm_normalize_think _think_pending
                    # Check for </think> end tag (handles split across token boundaries)
                    if [[ "$_think_pending" == *"</think>"* ]]; then
                        local _think_before="${_think_pending%%</think>*}"
                        local _after_think="${_think_pending#*</think>}"
                        _after_think="${_after_think//<\/think>/}"
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
                # Strip orphan </think> tags (some models emit duplicates)
                token="${token//<\/think>/}"
                # Check for late <think> tag (model re-entered thinking)
                if [[ "$token" == *"<think>"* ]]; then
                    local _before_late="${token%%<think>*}"
                    if [ -n "$_before_late" ]; then
                        printf "%s" "$_before_late"
                        printf "%s" "$_before_late" > "$_tty" 2>/dev/null
                    fi
                    _in_think_block=1
                    _can_think=1
                    _think_pending="${token#*<think>}"
                    _think_banner_open=1
                    _think_open
                    continue
                fi
                [ -n "$token" ] && printf "%s" "$token"
                [ -n "$token" ] && printf "%s" "$token" > "$_tty" 2>/dev/null
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
            # Flush any response_pending buffer (very short response, never reached 7 chars)
            if [ -n "$_response_pending" ]; then
                _response_pending="${_response_pending//\[THINK\]/<think>}"
                _response_pending="${_response_pending//\[\/THINK\]/<\/think>}"
                _response_pending="${_response_pending//<\/think>/}"
                _response_pending="${_response_pending//<think>/}"
                [ -n "$_response_pending" ] && printf "%s" "$_response_pending"
                [ -n "$_response_pending" ] && printf "%s" "$_response_pending" > "$_tty" 2>/dev/null
            fi
            # Fallback mode: flush any buffered text as response if </think> never arrived
            if [ "$_in_think_block" -eq 1 ] && [ -n "$_think_pending" ]; then
                _think_pending="${_think_pending//\[\/THINK\]/<\/think>}"
                _think_pending="${_think_pending//<\/think>/}"
                [ -n "$_think_pending" ] && printf "%s" "$_think_pending"
                [ -n "$_think_pending" ] && printf "%s" "$_think_pending" > "$_tty" 2>/dev/null
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

    # Check if we received any tokens at all (matches llm_generate's pattern)
    if [ ! -f "$_llm_ft_file" ]; then
        rm -f "$_llm_ft_file"
        _LLM_ACTIVE=0
        printf "\033[33m⚠ No response from model — check Ollama status (ollama ps)\033[0m\n" > "$_tty" 2>/dev/null
        echo "ERROR: LLM stream failed or returned no tokens"
        return 1
    fi

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

    # Detect active backend
    local _active_backend
    _active_backend=$(_llm_detect_backend)

    # Ensure correct model is loaded for this scenario
    models_ensure_for_scenario "${LLM_SCENARIO:-}"

    # Model-aware nothink: append model-specific suffix to last user message
    local _nt
    _nt=$(models_nothink_suffix)
    if [ -n "$_nt" ]; then
        messages=$(echo "$messages" | jq --arg nt "$_nt" '
            (map(select(.role == "user")) | length) as $n |
            if $n > 0 then
                reduce range(length) as $i (.;
                    if .[$i].role == "user" and ([.[$i+1:][] | select(.role == "user")] | length) == 0
                    then .[$i].content += $nt
                    else . end)
            else . end')
    fi

    # ── Thinking directive injection ───────────────────────────
    # Runtime system prompt REPLACES the Modelfile's SYSTEM block.
    # Prepend the thinking directive so it's never lost.
    # Skip for router — it just picks a tool name.
    if [ -n "$system" ] && declare -f models_thinking_directive &>/dev/null \
       && [ "${LLM_SCENARIO:-}" != "router" ]; then
        local _think_dir
        _think_dir=$(models_thinking_directive)
        if [ -n "$_think_dir" ]; then
            system="${_think_dir}\n\n${system}"
        fi
    fi

    # Build options with per-scenario sampling parameters
    local _opts
    _opts=$(_llm_build_opts "$LLM_MAX_TOKENS")

    # ── llama.cpp chat path ────────────────────────────────────
    # Cleanest backend translation — llama-server natively uses
    # OpenAI messages format. No payload wrapping needed.
    if [ "$_active_backend" = "llamacpp" ]; then
        local temp rep pres max_tok
        temp=$(echo "$_opts" | jq -r '.temperature // 0.7')
        rep=$(echo "$_opts" | jq -r '.repeat_penalty // 1.2')
        pres=$(echo "$_opts" | jq -r '.presence_penalty // 0.3')
        max_tok=$(echo "$_opts" | jq -r '.num_predict // 4096')

        # Build messages with system prompt prepended
        local full_messages
        if [ -n "$system" ]; then
            full_messages=$(echo "$messages" | jq --arg sys "$system" \
                '[{role:"system",content:$sys}] + .')
        else
            full_messages="$messages"
        fi

        payload=$(jq -n \
            --argjson messages "$full_messages" \
            --argjson max_tokens "$max_tok" \
            --argjson temperature "$temp" \
            --argjson frequency_penalty "$rep" \
            --argjson presence_penalty "$pres" \
            '{messages:$messages, max_tokens:$max_tokens, temperature:$temperature, frequency_penalty:$frequency_penalty, presence_penalty:$presence_penalty, stream:true}')

        local curl_timeout="${LLM_TIMEOUT:-600}"
        local timeout_cmd=""
        if [ "$curl_timeout" -gt 0 ] 2>/dev/null; then
            command -v timeout &>/dev/null && timeout_cmd="timeout $curl_timeout"
        fi

        _LLM_ACTIVE=1
        local _tmpdir="${TMPDIR:-/tmp}"
        local _got_tokens="$_tmpdir/.lodge-chat-tok-$$"
        rm -f "$_got_tokens"

        $timeout_cmd curl -sN --connect-timeout 10 --max-time "$curl_timeout" \
            "$LLAMA_CPP_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null | while IFS= read -r line; do

            [[ "$line" == data:* ]] || continue
            local json="${line#data: }"
            [ "$json" = "[DONE]" ] && break

            local token
            token=$(echo "$json" | jq -r '.choices[0].delta.content // empty' 2>/dev/null)
            if [ -n "$token" ]; then
                [ -f "$_got_tokens" ] || touch "$_got_tokens"
                printf "%s" "$token"
            fi
        done

        _LLM_ACTIVE=0
        if [ ! -f "$_got_tokens" ]; then
            rm -f "$_got_tokens"
            echo "ERROR: Chat request failed (llamacpp)"
            return 1
        fi
        rm -f "$_got_tokens"
        return 0
    fi

    # ── Ollama path (original) ─────────────────────────────────

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

    # Inject budget_tokens at top level (Ollama ignores it inside options)
    if [ "${budget:-0}" -gt 0 ] 2>/dev/null; then
        payload=$(echo "$payload" | jq --argjson bt "$budget" '. + {budget_tokens: $bt}')
    fi

    # Inject think:true for models with native thinking template support
    # NOT sent to system-prompt thinkers (Ministral)
    if [ "${LODGE_NOTHINK:-0}" -eq 0 ] && models_supports_think_flag "$LODGE_MODEL" 2>/dev/null; then
        payload=$(echo "$payload" | jq '. + {think: true}')
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
    models_current_has_thinking || _in_think_block=0
    local _think_pending=""

    $timeout_cmd curl -sN --connect-timeout 10 --max-time "$curl_timeout" \
        "$OLLAMA_URL/api/chat" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null | while IFS= read -r line; do

        # Check for Ollama error response
        local _ollama_err
        _ollama_err=$(echo "$line" | jq -r '.error // empty' 2>/dev/null)
        if [ -n "$_ollama_err" ]; then
            echo "ERROR: $_ollama_err"
            break
        fi

        local think_token token
        think_token=$(echo "$line" | jq -r '.message.thinking // empty' 2>/dev/null)
        token=$(echo "$line" | jq -r '.message.content // empty' 2>/dev/null)

        # Normalize bracket think tags → <think>/</think>
        _llm_normalize_think token

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
                    # Normalize bracket think tags in buffer (may split across tokens)
                    _llm_normalize_think _think_pending
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

# ── Vision: image analysis via Ollama images API ───────────────
# Usage: llm_vision "image_path_or_url" ["prompt"] ["system"] [max_tokens]
# Sends a base64-encoded image to the current model.
# Streams response to stdout and /dev/tty.
llm_vision() {
    local image_path="$1"
    local prompt="${2:-Describe this image in detail. Note any text, objects, people, and relevant details.}"
    local system="${3:-}"
    local max_tokens="${4:-${LLM_MAX_TOKENS:-4096}}"

    if [ -z "$image_path" ]; then
        echo "ERROR: No image path provided"
        return 1
    fi

    # Download if URL
    local _tmpdir="${TMPDIR:-/tmp}"
    local _tmp_img=""
    if [[ "$image_path" == http* ]]; then
        _tmp_img="$_tmpdir/.lodge-vision-$$.img"
        if ! curl -sfL --max-time 30 "$image_path" -o "$_tmp_img" 2>/dev/null; then
            echo "ERROR: Failed to download image: $image_path"
            rm -f "$_tmp_img"
            return 1
        fi
        image_path="$_tmp_img"
    fi

    if [ ! -f "$image_path" ]; then
        echo "ERROR: Image file not found: $image_path"
        return 1
    fi

    # Base64 encode (Linux -w0 vs macOS no flag)
    local img_base64
    img_base64=$(base64 -w0 "$image_path" 2>/dev/null || base64 "$image_path" 2>/dev/null)

    if [ -z "$img_base64" ]; then
        echo "ERROR: Failed to encode image"
        rm -f "$_tmp_img"
        return 1
    fi

    models_ensure_for_scenario "${LLM_SCENARIO:-}"

    # Detect active backend
    local _active_backend
    _active_backend=$(_llm_detect_backend)

    # Build options
    local _opts
    _opts=$(_llm_build_opts "$max_tokens")

    # ── llama.cpp vision path ──────────────────────────────────
    # Uses OpenAI multimodal format: image as base64 data URL in
    # content array. Requires a multimodal model loaded in llama-server.
    if [ "$_active_backend" = "llamacpp" ]; then
        local temp max_tok
        temp=$(echo "$_opts" | jq -r '.temperature // 0.7')
        max_tok=$(echo "$_opts" | jq -r '.num_predict // 4096')

        # Detect MIME type
        local mime_type="image/jpeg"
        case "$image_path" in
            *.png)  mime_type="image/png" ;;
            *.gif)  mime_type="image/gif" ;;
            *.webp) mime_type="image/webp" ;;
        esac

        # Build multimodal messages payload
        local messages
        if [ -n "$system" ]; then
            messages=$(jq -n \
                --arg sys "$system" \
                --arg prompt "$prompt" \
                --arg img "data:${mime_type};base64,${img_base64}" \
                '[{role:"system",content:$sys},{role:"user",content:[{type:"text",text:$prompt},{type:"image_url",image_url:{url:$img}}]}]')
        else
            messages=$(jq -n \
                --arg prompt "$prompt" \
                --arg img "data:${mime_type};base64,${img_base64}" \
                '[{role:"user",content:[{type:"text",text:$prompt},{type:"image_url",image_url:{url:$img}}]}]')
        fi

        payload=$(jq -n \
            --argjson messages "$messages" \
            --argjson max_tokens "$max_tok" \
            --argjson temperature "$temp" \
            '{messages:$messages, max_tokens:$max_tokens, temperature:$temperature, stream:true}')

        local curl_timeout="${LLM_TIMEOUT:-600}"
        local timeout_cmd=""
        if [ "$curl_timeout" -gt 0 ] 2>/dev/null; then
            command -v timeout &>/dev/null && timeout_cmd="timeout $curl_timeout"
        fi

        _LLM_ACTIVE=1
        local _tty="/dev/tty"
        [ -w /dev/tty ] 2>/dev/null || _tty="/dev/stderr"
        local _got_tokens="$_tmpdir/.lodge-vision-tok-$$"
        rm -f "$_got_tokens"

        ui_spinner_start "Analyzing image"
        local _spinner_pid="$_SPINNER_PID"
        local _first_token=0

        $timeout_cmd curl -sN --connect-timeout 10 --max-time "$curl_timeout" \
            "$LLAMA_CPP_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null | while IFS= read -r line; do

            [[ "$line" == data:* ]] || continue
            local json="${line#data: }"
            if [ "$json" = "[DONE]" ]; then
                echo ""
                echo "" > "$_tty" 2>/dev/null
                break
            fi
            local token
            token=$(echo "$json" | jq -r '.choices[0].delta.content // empty' 2>/dev/null)
            if [ -n "$token" ]; then
                if [ "$_first_token" -eq 0 ]; then
                    _first_token=1
                    touch "$_got_tokens"
                    kill "$_spinner_pid" 2>/dev/null; wait "$_spinner_pid" 2>/dev/null
                    printf "\r%*s\r" 60 "" > "$_tty" 2>/dev/null
                fi
                printf "%s" "$token"
                printf "%s" "$token" > "$_tty" 2>/dev/null
            fi
        done

        ui_spinner_stop
        _LLM_ACTIVE=0
        rm -f "$_tmp_img" 2>/dev/null

        if [ ! -f "$_got_tokens" ]; then
            rm -f "$_got_tokens"
            echo "ERROR: Vision request failed (llamacpp) — model may not support images"
            return 1
        fi
        rm -f "$_got_tokens"
        return 0
    fi

    # ── Ollama path (original) ─────────────────────────────────

    local payload
    if [ -n "$system" ]; then
        payload=$(jq -n \
            --arg model "$LODGE_MODEL" \
            --arg prompt "$prompt" \
            --arg system "$system" \
            --arg img "$img_base64" \
            --arg keep_alive "$LLM_KEEP_ALIVE" \
            --argjson options "$_opts" \
            '{model: $model, prompt: $prompt, system: $system, images: [$img], stream: true, keep_alive: $keep_alive, options: $options}')
    else
        payload=$(jq -n \
            --arg model "$LODGE_MODEL" \
            --arg prompt "$prompt" \
            --arg img "$img_base64" \
            --arg keep_alive "$LLM_KEEP_ALIVE" \
            --argjson options "$_opts" \
            '{model: $model, prompt: $prompt, images: [$img], stream: true, keep_alive: $keep_alive, options: $options}')
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

    local _got_tokens="$_tmpdir/.lodge-vision-tok-$$"
    rm -f "$_got_tokens"

    ui_spinner_start "Analyzing image"
    local _spinner_pid="$_SPINNER_PID"
    local _first_token=0

    $timeout_cmd curl -sN --connect-timeout 10 --max-time "$curl_timeout" \
        "$OLLAMA_URL/api/generate" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null | while IFS= read -r line; do

        # Check for Ollama error response
        local _ollama_err
        _ollama_err=$(echo "$line" | jq -r '.error // empty' 2>/dev/null)
        if [ -n "$_ollama_err" ]; then
            kill "$_spinner_pid" 2>/dev/null
            printf "\r%*s\r" 60 "" > "$_tty" 2>/dev/null
            printf "\033[31mOllama error: %s\033[0m\n" "$_ollama_err" > "$_tty" 2>/dev/null
            echo "ERROR: $_ollama_err"
            break
        fi

        local token
        token=$(echo "$line" | jq -r '.response // empty' 2>/dev/null)
        if [ -n "$token" ]; then
            if [ "$_first_token" -eq 0 ]; then
                _first_token=1
                touch "$_got_tokens"
                kill "$_spinner_pid" 2>/dev/null; wait "$_spinner_pid" 2>/dev/null
                printf "\r%*s\r" 60 "" > "$_tty" 2>/dev/null
            fi
            printf "%s" "$token"
            printf "%s" "$token" > "$_tty" 2>/dev/null
        fi

        local done_flag
        done_flag=$(echo "$line" | jq -r '.done // empty' 2>/dev/null)
        if [ "$done_flag" = "true" ]; then
            echo ""
            echo "" > "$_tty" 2>/dev/null
            break
        fi
    done

    ui_spinner_stop
    _LLM_ACTIVE=0

    # Clean up temp files
    rm -f "$_tmp_img" 2>/dev/null

    if [ ! -f "$_got_tokens" ]; then
        rm -f "$_got_tokens"
        echo "ERROR: Vision request failed — model may not support images"
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
    
    local LLM_SCENARIO=ask
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
    local backend
    backend=$(_llm_detect_backend)

    if [ "$backend" = "llamacpp" ]; then
        # llama-server doesn't have /api/show — report what we can from /props
        local resp
        resp=$(curl -sf --max-time 5 "$LLAMA_CPP_URL/props" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$resp" ]; then
            echo "$resp" | jq '{backend:"llamacpp", url:"'"$LLAMA_CPP_URL"'"}' 2>/dev/null
        else
            echo '{"backend":"llamacpp","note":"server not responding"}'
        fi
        return 0
    fi

    curl -sf "$OLLAMA_URL/api/show" \
        -d "{\"name\":\"$LODGE_MODEL\"}" 2>/dev/null | \
        jq '{model: .modelinfo.general_architecture, params: .details.parameter_size, quant: .details.quantization_level, family: .details.family}' 2>/dev/null
}
