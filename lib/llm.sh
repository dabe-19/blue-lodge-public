#!/bin/bash
# ── George: LLM Interface ─────────────────────────────────
# Multi-backend LLM wrapper. Supports Ollama and llama.cpp (llama-server).
# Auto-detects which backend is available; falls back gracefully.

[ -n "${_LIB_LLM_LOADED:-}" ] && return 0; _LIB_LLM_LOADED=1

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
# Detect GPU presence for dynamic defaults
_LLM_GPU_DETECTED=0
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    _LLM_GPU_DETECTED=1
elif [ -c /dev/nvidia0 ] 2>/dev/null || [ -c /dev/kfd ] 2>/dev/null; then
    _LLM_GPU_DETECTED=1
fi

# GPU layers and Context size defaults (offload to GPU and use 32K context when GPU is present)
if [ "$_LLM_GPU_DETECTED" -eq 1 ]; then
    LLAMA_CPP_GPU_LAYERS="${LLAMA_CPP_GPU_LAYERS:-99}"
    LLAMA_CPP_CTX_SIZE="${LLAMA_CPP_CTX_SIZE:-32768}"
else
    LLAMA_CPP_GPU_LAYERS="${LLAMA_CPP_GPU_LAYERS:-0}"
    LLAMA_CPP_CTX_SIZE="${LLAMA_CPP_CTX_SIZE:-8192}"
fi
# KV cache precision for llama.cpp. "auto" keeps llama.cpp defaults.
# Valid explicit examples: f16, q8_0, q5_0, q4_0.
LLAMA_CPP_KV_CACHE_TYPE="${LLAMA_CPP_KV_CACHE_TYPE:-q4_0}"
# Prompt cache controls (local llama.cpp server only).
# Keeping this enabled improves repeat prompt prefill latency in agent loops.
LLAMA_CPP_PROMPT_CACHE="${LLAMA_CPP_PROMPT_CACHE:-1}"
LLAMA_CPP_PROMPT_CACHE_ALL="${LLAMA_CPP_PROMPT_CACHE_ALL:-1}"
LLAMA_CPP_PROMPT_CACHE_FILE="${LLAMA_CPP_PROMPT_CACHE_FILE:-${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}/llama-prompt-cache.bin}"
# Optional Hugging Face startup path for llama-server (-hf ...).
# Default stays local GGUF (-m ...) resolved from Ollama blobs.
LLAMA_CPP_USE_HF="${LLAMA_CPP_USE_HF:-0}"
LLAMA_CPP_HF_REF="${LLAMA_CPP_HF_REF:-}"
# Memory mapping (mmap) control: disable in virtualized/PRoot environments to prevent SIGBUS/Aborted crashes.
if [ -d "/data/data/com.termux/files/home" ] && [ "$HOME" != "/data/data/com.termux/files/home" ]; then
    LLAMA_CPP_NO_MMAP="${LLAMA_CPP_NO_MMAP:-1}"
else
    LLAMA_CPP_NO_MMAP="${LLAMA_CPP_NO_MMAP:-0}"
fi
# Optional speculative decoding with MTP drafter.
# Note: -hf auto-discovery is not used on the Ollama-resolved -m path.
# Set LLAMA_CPP_DRAFT_MODEL to a local drafter GGUF to enable draft model usage.
LLAMA_CPP_SPEC_MTP="${LLAMA_CPP_SPEC_MTP:-0}"
LLAMA_CPP_SPEC_DRAFT_N_MAX="${LLAMA_CPP_SPEC_DRAFT_N_MAX:-4}"
LLAMA_CPP_DRAFT_MODEL="${LLAMA_CPP_DRAFT_MODEL:-}"
LLAMA_CPP_SPEC_DRAFT_HF="${LLAMA_CPP_SPEC_DRAFT_HF:-}"
# Flash attention control (llama.cpp -fa). Keep "auto" unless explicitly set.
LLAMA_CPP_FA="${LLAMA_CPP_FA:-auto}"
# Global constrained-decoding toggle.
# 0 = disable all GBNF grammar attachment (default)
# 1 = enable schema grammar loading/attachment when a schema is requested
LLM_GRAMMAR_ENABLED="${LLM_GRAMMAR_ENABLED:-0}"
# Backend preference: llamacpp (default — auto-starts when needed), ollama, auto
# Persisted to .george/lodge.conf along with token limits, budgets, sampling
# params, and debug mode so they survive sessions.
_LLM_CONFIG_FILE="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}/lodge.conf"
# Migrate legacy single-value backend.conf → lodge.conf
_LLM_BACKEND_PREF_FILE="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}/backend.conf"
if [ -f "$_LLM_BACKEND_PREF_FILE" ] && [ ! -f "$_LLM_CONFIG_FILE" ]; then
    _saved_backend=$(cat "$_LLM_BACKEND_PREF_FILE" 2>/dev/null)
    echo "LLM_BACKEND=${_saved_backend:-llamacpp}" > "$_LLM_CONFIG_FILE" 2>/dev/null
    rm -f "$_LLM_BACKEND_PREF_FILE"
    unset _saved_backend
fi

# ── Load persistent config ─────────────────────────────────────
# lodge.conf is a KEY=VALUE file.
# Default mode: only apply values that the environment hasn't already set
# (so env vars still win).
# --force mode: override all variables (used after models_apply_defaults
# to re-apply the user's persisted sampling params).
_llm_load_config() {
    [ -f "$_LLM_CONFIG_FILE" ] || return 0
    local _force=0
    [ "${1:-}" = "--force" ] && _force=1
    local _key _val
    while IFS='=' read -r _key _val; do
        # Skip comments and blanks
        [[ "$_key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$_key" ]] && continue
        _key=$(echo "$_key" | tr -d '[:space:]')
        _val=$(echo "$_val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ "$_force" -eq 1 ]; then
            printf -v "$_key" '%s' "$_val"
        else
            # Only set if not already defined in the environment
            if [ -z "${!_key+x}" ] || [ -z "${!_key}" ]; then
                printf -v "$_key" '%s' "$_val"
            fi
        fi
    done < "$_LLM_CONFIG_FILE"
}

# Save current settings to lodge.conf
_llm_save_config() {
    local _dir
    _dir=$(dirname "$_LLM_CONFIG_FILE")
    [ -d "$_dir" ] || return 1
    cat > "$_LLM_CONFIG_FILE" << EOF
# George lodge.conf — persistent settings
# Auto-generated by /config save, /backend, /debug, /model commands.
# Environment variables override these values.

# ── Models ─────────────────────────────────────────────────────
LODGE_MODEL_PRIMARY=${LODGE_MODEL_PRIMARY:-blue-lodge-gemma4-inst:2b}
LODGE_MODEL_SECONDARY=${LODGE_MODEL_SECONDARY:-blue-lodge-gemma4-inst:2b}
LODGE_SINGLE_MODEL=${LODGE_SINGLE_MODEL:-1}

# ── Backend ────────────────────────────────────────────────────
LLM_BACKEND=${LLM_BACKEND:-llamacpp}
LLAMA_CPP_GPU_LAYERS=${LLAMA_CPP_GPU_LAYERS:-0}
LLAMA_CPP_CTX_SIZE=${LLAMA_CPP_CTX_SIZE:-8192}
LLAMA_CPP_SLOTS=${LLAMA_CPP_SLOTS:-2}
LLAMA_CPP_KV_CACHE_TYPE=${LLAMA_CPP_KV_CACHE_TYPE:-q4_0}
LLAMA_CPP_PROMPT_CACHE=${LLAMA_CPP_PROMPT_CACHE:-1}
LLAMA_CPP_PROMPT_CACHE_ALL=${LLAMA_CPP_PROMPT_CACHE_ALL:-1}
LLAMA_CPP_PROMPT_CACHE_FILE=${LLAMA_CPP_PROMPT_CACHE_FILE:-${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}/llama-prompt-cache.bin}
LLAMA_CPP_USE_HF=${LLAMA_CPP_USE_HF:-0}
LLAMA_CPP_HF_REF=${LLAMA_CPP_HF_REF:-}
LLAMA_CPP_SPEC_MTP=${LLAMA_CPP_SPEC_MTP:-0}
LLAMA_CPP_SPEC_DRAFT_N_MAX=${LLAMA_CPP_SPEC_DRAFT_N_MAX:-4}
LLAMA_CPP_DRAFT_MODEL=${LLAMA_CPP_DRAFT_MODEL:-}
LLAMA_CPP_FA=${LLAMA_CPP_FA:-auto}

# ── Debug ──────────────────────────────────────────────────────
LODGE_DEBUG=${LODGE_DEBUG:-0}

# ── Token Limits (max output tokens per role) ──────────────────
LLM_MAX_TOKENS=${LLM_MAX_TOKENS:-20480}
LLM_ASK_TOKENS=${LLM_ASK_TOKENS:-20480}
LLM_AGENT_TOKENS=${LLM_AGENT_TOKENS:-20480}
LLM_STRATEGIST_TOKENS=${LLM_STRATEGIST_TOKENS:-4096}
LLM_EVALUATOR_TOKENS=${LLM_EVALUATOR_TOKENS:-4096}
LLM_ROUTER_TOKENS=${LLM_ROUTER_TOKENS:-512}

# ── Thinking Budgets (max thinking tokens before responding) ───
LLM_BUDGET_TOKENS=${LLM_BUDGET_TOKENS:-4096}
LLM_BUDGET_ASK=${LLM_BUDGET_ASK:-4096}
LLM_BUDGET_AGENT=${LLM_BUDGET_AGENT:-4096}
LLM_BUDGET_ROUTER=${LLM_BUDGET_ROUTER:-4096}
LLM_BUDGET_JOURNAL=${LLM_BUDGET_JOURNAL:-4096}
LLM_BUDGET_TOOL=${LLM_BUDGET_TOOL:-4096}

# ── Grammar ───────────────────────────────────────────────────
LLM_GRAMMAR_ENABLED=${LLM_GRAMMAR_ENABLED:-1}

# ── Sampling Parameters ───────────────────────────────────────
LLM_TEMPERATURE=${LLM_TEMPERATURE:-0.15}
LLM_REPEAT_PENALTY=${LLM_REPEAT_PENALTY:-1.2}
LLM_PRESENCE_PENALTY=${LLM_PRESENCE_PENALTY:-0.3}
LLM_TOP_P=${LLM_TOP_P:-0.9}
LLM_TOP_K=${LLM_TOP_K:-40}
LLM_MIN_P=${LLM_MIN_P:-0.0}

# ── MCP ────────────────────────────────────────────────────────
MCP_ENABLED=${MCP_ENABLED:-0}

# ── Reflexive Intelligence ─────────────────────────────────────
REFLEXIVE_SOUL_GATE=${REFLEXIVE_SOUL_GATE:-0}
REFLEXIVE_PROMPT_LEARN=${REFLEXIVE_PROMPT_LEARN:-0}
REFLEXIVE_ADAPT_TOKENS=${REFLEXIVE_ADAPT_TOKENS:-0}
REFLEXIVE_SPECULATE=${REFLEXIVE_SPECULATE:-0}
REFLEXIVE_SELF_MODEL=${REFLEXIVE_SELF_MODEL:-0}
REFLEXIVE_METACOG_LLM=${REFLEXIVE_METACOG_LLM:-0}
REFLEXIVE_SOUL_KEYWORDS=${REFLEXIVE_SOUL_KEYWORDS:-5}
REFLEXIVE_PROMPT_HISTORY=${REFLEXIVE_PROMPT_HISTORY:-8}
REFLEXIVE_TOKEN_FLOOR=${REFLEXIVE_TOKEN_FLOOR:-512}
REFLEXIVE_TOKEN_CEILING=${REFLEXIVE_TOKEN_CEILING:-8192}
REFLEXIVE_SPECULATE_BUDGET=${REFLEXIVE_SPECULATE_BUDGET:-3}
REFLEXIVE_METACOG_INTERVAL=${REFLEXIVE_METACOG_INTERVAL:-4}
EOF
    return 0
}

# Load config now (before defaults are applied below)
_llm_load_config

LLM_BACKEND="${LLM_BACKEND:-llamacpp}"
# Cached backend result (set by _llm_detect_backend, cleared on /backend change)
_LLM_BACKEND_CACHE=""
# Cached identity system prompt (invalidated when LODGE_MODEL changes)
_LLM_DEFAULT_SYSTEM_CACHE=""
_LLM_DEFAULT_SYSTEM_MODEL=""
# PID file for llama-server started by lodge
_LLAMA_CPP_PID_FILE="${TMPDIR:-/tmp}/.lodge-llama-server.pid"
# Cached llama-server help text for feature flag detection
_LLAMA_CPP_HELP_TEXT=""
_LLAMA_CPP_HELP_LOADED=0
LODGE_MODEL="${LODGE_MODEL:-blue-lodge}"
LLM_MAX_TOKENS="${LLM_MAX_TOKENS:-20480}"   # Default max output tokens (matches Modelfile num_predict ceiling)
LLM_ASK_TOKENS="${LLM_ASK_TOKENS:-20480}"   # Max output tokens for /ask (model stops at <|im_end|>; this is just a safety cap)
LLM_AGENT_TOKENS="${LLM_AGENT_TOKENS:-20480}" # Max output tokens for agent specialist
LLM_STRATEGIST_TOKENS="${LLM_STRATEGIST_TOKENS:-4096}" # Max output tokens for strategist (milestone description + thinking)
LLM_EVALUATOR_TOKENS="${LLM_EVALUATOR_TOKENS:-4096}"   # Max output tokens for evaluator (completion judge)
LLM_ROUTER_TOKENS="${LLM_ROUTER_TOKENS:-512}" # Max output tokens for agent router (think ~200 + tool name + context)
LLM_BUDGET_TOKENS="${LLM_BUDGET_TOKENS:-4096}" # Max thinking tokens before responding (0=unlimited)
LLM_BUDGET_ASK="${LLM_BUDGET_ASK:-4096}"     # Think budget for /ask conversations (extended thinking useful)
LLM_BUDGET_AGENT="${LLM_BUDGET_AGENT:-4096}"  # Think budget for strategist/specialist (needs room for rich milestone context)
LLM_BUDGET_ROUTER="${LLM_BUDGET_ROUTER:-4096}" # Think budget for router (pick tool + brief reasoning)
LLM_BUDGET_JOURNAL="${LLM_BUDGET_JOURNAL:-4096}" # Think budget for journal (background utility)
LLM_BUDGET_TOOL="${LLM_BUDGET_TOOL:-4096}"    # Think budget for tools (commit, web, recall, slash)
LODGE_THINK_LEVEL="${LODGE_THINK_LEVEL:-1}" # Configurable thinking depth: 1=low, 2=medium, 3=high

_llm_resolve_think_budget() {
    local base_budget="$1"
    case "${LODGE_THINK_LEVEL}" in
        low|1) echo 1024 ;;
        medium|2) echo 4096 ;;
        high|3) echo 16384 ;;
        *) echo "$base_budget" ;;
    esac
}

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
LODGE_THINK="${LODGE_THINK:-0}"               # 1=show thinking tokens dimmed, 0=hide thinking tokens (default)
LODGE_THINK_STREAM="${LODGE_THINK_STREAM:-1}"  # When LODGE_THINK=1: 0=hide thinking, 1=show dimmed, 2=show bright (cyan)
LODGE_NOTHINK="${LODGE_NOTHINK:-0}"             # 0=model thinks normally, 1=suppress reasoning (default)
LODGE_DEBUG="${LODGE_DEBUG:-0}"                 # 0=normal, 1=show timers + token counts per LLM call

# ── Thinking model token multiplier ────────────────────────────
# When a thinking model is active, output token budgets must be
# significantly larger because the model emits <think>...</think>
# blocks BEFORE the actual response. A 512-token cap that works
# for instruct models cuts off mid-think for reasoning models,
# causing unclosed [THINK] tags and empty milestones.
# Returns the multiplied value: tokens * 4 for thinking, unchanged otherwise.
_llm_apply_thinking_multiplier() {
    local tokens="${1:-0}"
    if models_current_has_thinking 2>/dev/null; then
        echo $(( tokens * 4 ))
    else
        echo "$tokens"
    fi
}

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
    _ntref="${_ntref//<|channel>thought/<think>}"
    _ntref="${_ntref//<channel|>/<\/think>}"
}

# ── Think display helpers ──────────────────────────────────────
# Shared by both llamacpp and Ollama streaming paths.
# Show the ┌─ thinking ─ / └──────────── banner on tty
# when LODGE_THINK is enabled.
# Bright (2) = cyan, Dimmed (1) = gray (SGR 90, widely supported).
_llm_think_tty() {
    local _t="/dev/tty"
    (true >/dev/tty) 2>/dev/null || _t="/dev/null"
    echo "$_t"
}
_llm_think_color() {
    [ "${LODGE_THINK_STREAM:-1}" -eq 2 ] && printf "\033[36m" || printf "\033[90m"
}
_llm_think_open() {
    # Keep output conditional on settings
    if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
        local _t; _t=$(_llm_think_tty)
        local _c; _c=$(_llm_think_color)
        printf "\n%s┌─ thinking ─\033[0m\n%s" "$_c" "$_c" > "$_t" 2>/dev/null
    fi
}
_llm_think_close() {
    if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
        local _t; _t=$(_llm_think_tty)
        local _c; _c=$(_llm_think_color)
        printf "\033[0m\n%s└────────────\033[0m\n" "$_c" > "$_t" 2>/dev/null
    fi
}
_llm_think_show() {
    # Unconditionally write thinking tokens to the log file on disk if active
    if [ -n "${_think_log_file:-}" ]; then
        printf "%s" "$1" >> "$_think_log_file"
    fi
    # Only stream/output to TTY if settings dictate
    if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
        local _t; _t=$(_llm_think_tty)
        printf "%s" "$1" > "$_t" 2>/dev/null
    fi
}
_llm_think_log_start() {
    local _tmpdir="${TMPDIR:-/tmp}"
    _think_log_file="$_tmpdir/.lodge-think-log-$RANDOM-$BASHPID"
    rm -f "$_think_log_file"
    touch "$_think_log_file"
}
_llm_think_log_end() {
    if [ -f "${_think_log_file:-}" ]; then
        if [ -s "$_think_log_file" ] && [ -n "${_TRANSCRIPT_FILE:-}" ] && [ -f "$_TRANSCRIPT_FILE" ]; then
            # Format and append thinking block to transcript markdown file
            printf "\n**model-think:**\n\`\`\`\n" >> "$_TRANSCRIPT_FILE"
            cat "$_think_log_file" >> "$_TRANSCRIPT_FILE"
            printf "\n\`\`\`\n" >> "$_TRANSCRIPT_FILE"
        fi
        rm -f "$_think_log_file"
    fi
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
    local model_temp model_rep model_pres model_top_p model_top_k model_min_p
    if declare -f models_get_param &>/dev/null && [ -n "$LODGE_MODEL" ]; then
        model_temp=$(models_get_param "$LODGE_MODEL" temp 2>/dev/null) || model_temp=""
        model_rep=$(models_get_param "$LODGE_MODEL" repeat 2>/dev/null) || model_rep=""
        model_pres=$(models_get_param "$LODGE_MODEL" presence 2>/dev/null) || model_pres=""
        model_top_p=$(models_get_param "$LODGE_MODEL" top_p 2>/dev/null) || model_top_p=""
        model_top_k=$(models_get_param "$LODGE_MODEL" top_k 2>/dev/null) || model_top_k=""
        model_min_p=$(models_get_param "$LODGE_MODEL" min_p 2>/dev/null) || model_min_p=""
    fi
    # Fall back to globals if model lookup fails
    model_temp="${model_temp:-$LLM_TEMPERATURE}"
    model_temp="${model_temp:-0.7}"  # safety net: jq --argjson crashes on empty string
    model_rep="${model_rep:-$LLM_REPEAT_PENALTY}"
    model_rep="${model_rep:-1.2}"
    model_pres="${model_pres:-$LLM_PRESENCE_PENALTY}"
    model_pres="${model_pres:-0.3}"
    model_top_p="${model_top_p:-${LLM_TOP_P:-1.0}}"
    model_top_k="${model_top_k:-${LLM_TOP_K:-40}}"
    model_min_p="${model_min_p:-${LLM_MIN_P:-0.0}}"

    # ── Step 2: Apply per-scenario overrides ──────────────────
    # If a scenario-specific value is set, it REPLACES the model
    # default (absolute value, NOT additive). Empty = inherit model.
    local temp rep pres top_p top_k min_p
    case "$scenario" in
        ask)     temp="${LLM_TEMP_ASK:-$model_temp}"; rep="${LLM_REPEAT_ASK:-$model_rep}"; pres="${LLM_PRESENCE_ASK:-$model_pres}" ;;
        agent)      temp="${LLM_TEMP_AGENT:-$model_temp}"; rep="${LLM_REPEAT_AGENT:-$model_rep}"; pres="${LLM_PRESENCE_AGENT:-$model_pres}" ;;
        strategist) temp="${LLM_TEMP_AGENT:-$model_temp}"; rep="${LLM_REPEAT_AGENT:-$model_rep}"; pres="${LLM_PRESENCE_AGENT:-$model_pres}" ;;
        router)     temp="${LLM_TEMP_ROUTER:-$model_temp}"; rep="${LLM_REPEAT_ROUTER:-$model_rep}"; pres="${LLM_PRESENCE_ROUTER:-$model_pres}" ;;
        journal) temp="${LLM_TEMP_JOURNAL:-$model_temp}"; rep="${LLM_REPEAT_JOURNAL:-$model_rep}"; pres="${LLM_PRESENCE_JOURNAL:-$model_pres}" ;;
        tool)    temp="${LLM_TEMP_TOOL:-$model_temp}"; rep="${LLM_REPEAT_TOOL:-$model_rep}"; pres="${LLM_PRESENCE_TOOL:-$model_pres}" ;;
        *)       temp="$model_temp"; rep="$model_rep"; pres="$model_pres" ;;
    esac
    # top_p / top_k / min_p are model-specific, not scenario-specific
    top_p="$model_top_p"
    top_k="$model_top_k"
    min_p="$model_min_p"

    jq -n \
        --argjson np "$np" \
        --argjson temp "$temp" \
        --argjson rep "$rep" \
        --argjson pres "$pres" \
        --argjson top_p "$top_p" \
        --argjson top_k "$top_k" \
        --argjson min_p "$min_p" \
        --argjson num_ctx "${LLM_CONTEXT_WINDOW:-16384}" \
        '{num_predict:$np, temperature:$temp, repeat_penalty:$rep, presence_penalty:$pres, top_p:$top_p, top_k:$top_k, min_p:$min_p, num_ctx:$num_ctx}'
}

# ── Debug tracking state ───────────────────────────────────────
# File-based counters survive $() subshells (shell vars don't).
_LLM_DEBUG_DIR="${TMPDIR:-/tmp}/.lodge-debug-$$"
_LLM_DEBUG_TASK_START=""

# ── Active request tracking (for cancellation) ─────────────────
_LLM_CURL_PID=""
_LLM_ACTIVE=0

# ── Kill active curl + cancel server-side inference ────────────
# After breaking from a `curl | while read` pipe, the curl process
# is still alive with the TCP connection open, keeping llama-server's
# inference slot busy computing tokens nobody is reading.
# This helper:
#   1. Kills the curl process (closes TCP → server detects disconnect)
#   2. Sends a lightweight /slots cancel if the server supports it
#   3. Cleans up process tracking state
_llm_kill_curl() {
    # Kill tracked curl PID
    if [ -n "$_LLM_CURL_PID" ] && kill -0 "$_LLM_CURL_PID" 2>/dev/null; then
        kill "$_LLM_CURL_PID" 2>/dev/null
        wait "$_LLM_CURL_PID" 2>/dev/null 2>&1 || true
    fi
    _LLM_CURL_PID=""

    # Also kill any orphan curl processes targeting llama-server
    # (covers $() captures where PID tracking is lost to subshells)
    pkill -f "curl.*v1/chat/completions" 2>/dev/null || true

    _LLM_ACTIVE=0
}

# ── FIFO safety check ─────────────────────────────────────────
# Named pipes (mkfifo) deadlock on iSH (iOS QEMU emulation) because
# the userspace scheduler can't synchronise concurrent open() calls
# on both ends of the FIFO. Pipe-based streaming works fine (kernel
# sets up both endpoints in a single pipe() syscall before fork).
# Returns 0 (true) when FIFOs are safe; 1 (false) when they aren't.
_llm_is_fifo_safe() {
    [[ "${LODGE_PLATFORM:-}" == "ish" ]] && return 1
    return 0
}

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

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && [[ "${LODGE_PLATFORM:-}" == "ish" ]] && [ "${_REMOTE_CONNECTED:-0}" -eq 1 ] \
        && ui_dim "  [debug] iSH + remote: pipe-based streaming (FIFO bypass)" 2>/dev/null >/dev/tty

    # Manual override — skip detection
    case "$LLM_BACKEND" in
        llamacpp|llama-cpp|llama_cpp)
            # Verify server is actually responding; if not, try to start it.
            # This handles: phone sleep killed the process, OOM, session restart.
            if ! curl -sf --max-time 2 "$LLAMA_CPP_URL/health" 2>/dev/null | grep -q '"status"'; then
                # Not healthy — attempt auto-start (quiet, non-recursive)
                if [ "${_LLM_AUTOSTART_GUARD:-0}" -eq 0 ]; then
                    _LLM_AUTOSTART_GUARD=1
                    local _gguf="$LLAMA_CPP_MODEL"
                    if [ -z "$_gguf" ] || [ ! -f "$_gguf" ]; then
                        local _key=""
                        for entry in "${_MODELS_REGISTRY[@]}"; do
                            _models_parse_entry "$entry"
                            if [ "$_ME_NAME" = "$LODGE_MODEL_PRIMARY" ] || [ "$_ME_KEY" = "$LODGE_MODEL_PRIMARY" ]; then
                                _key="$_ME_KEY"
                                break
                            fi
                        done
                        [ -n "$_key" ] && _gguf=$(_models_resolve_gguf "$_key" 2>/dev/null)
                        if [ -z "$_gguf" ] && [ "${LLAMA_CPP_USE_HF:-0}" = "1" ]; then
                            _gguf="hf-harness-auto-resolved"
                        fi
                    fi
                    if [ -n "$_gguf" ] && { [ -f "$_gguf" ] || [ "${LLAMA_CPP_USE_HF:-0}" = "1" ]; }; then
                        _llm_kill_ollama --quiet 2>/dev/null
                        _llm_start_llamacpp_server "$_gguf" "--quiet" 2>/dev/null
                    fi
                    _LLM_AUTOSTART_GUARD=0
                fi
            fi
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

    # Process-based port discovery: if configured port didn't respond, check
    # for a running llama-server and try its actual --port value.
    local _running_port
    _running_port=$(ps aux 2>/dev/null | sed -n 's/.*llama-server.*--port[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
    if [ -z "$_running_port" ]; then
        # pgrep + /proc/PID/cmdline fallback (Termux/proot may lack ps aux)
        local _srv_pid
        _srv_pid=$(pgrep -f "llama-server" 2>/dev/null | head -1)
        if [ -n "$_srv_pid" ] && [ -f "/proc/$_srv_pid/cmdline" ]; then
            _running_port=$(tr '\0' ' ' < "/proc/$_srv_pid/cmdline" 2>/dev/null | sed -n 's/.*--port[[:space:]]*\([0-9]*\).*/\1/p')
        fi
    fi
    if [ -n "$_running_port" ] && [ "$_running_port" != "$(echo "$LLAMA_CPP_URL" | sed -n 's/.*:\([0-9]*\)$/\1/p')" ]; then
        local _alt_url="http://127.0.0.1:$_running_port"
        if curl -sf --max-time 2 "$_alt_url/health" 2>/dev/null | grep -q '"status"'; then
            LLAMA_CPP_URL="$_alt_url"
            _LLM_BACKEND_CACHE="llamacpp"
            echo "llamacpp"
            return 0
        fi
    fi

    # Fallback to Ollama
    if curl -sf --max-time 2 "$OLLAMA_URL/api/tags" &>/dev/null; then
        _LLM_BACKEND_CACHE="ollama"
        echo "ollama"
        return 0
    fi

    # Neither available — default to llamacpp (llm_ensure will handle startup)
    _LLM_BACKEND_CACHE="llamacpp"
    echo "llamacpp"
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

# Restart the llama.cpp backend if it is running.
llm_backend_restart() {
    local _backend
    _backend=$(_llm_detect_backend 2>/dev/null)
    if [ "$_backend" = "llamacpp" ]; then
        if curl -sf --max-time 2 "$LLAMA_CPP_URL/health" &>/dev/null; then
            declare -f ui_info &>/dev/null && ui_info "Stopping llama-server..." || echo "Stopping llama-server..."
            _llm_stop_llamacpp_server
            # Clear active model tracking to force reload
            _MODELS_ACTIVE=""
            # Switch back to the active model to restart the server
            _models_switch "$LODGE_MODEL"
        fi
    fi
}

# Read and cache llama-server --help output once per session.
_llm_load_llamacpp_help() {
    [ "$_LLAMA_CPP_HELP_LOADED" -eq 1 ] && return 0
    _LLAMA_CPP_HELP_TEXT=""
    [ -x "$LLAMA_CPP_SERVER_BIN" ] || {
        _LLAMA_CPP_HELP_LOADED=1
        return 1
    }

    # Some builds support -h but not --help; try both quietly.
    _LLAMA_CPP_HELP_TEXT=$("$LLAMA_CPP_SERVER_BIN" --help 2>&1)
    if [ -z "$_LLAMA_CPP_HELP_TEXT" ]; then
        _LLAMA_CPP_HELP_TEXT=$("$LLAMA_CPP_SERVER_BIN" -h 2>&1)
    fi
    _LLAMA_CPP_HELP_LOADED=1
    [ -n "$_LLAMA_CPP_HELP_TEXT" ]
}

# Returns 0 when llama-server help contains the given long flag.
_llm_llamacpp_supports_flag() {
    local _flag="$1"
    [ -n "$_flag" ] || return 1
    _llm_load_llamacpp_help >/dev/null 2>&1 || return 1
    echo "$_LLAMA_CPP_HELP_TEXT" | grep -Fq -- "$_flag"
}

# Start llama-server with the given GGUF model path.
# Args: model_path [--quiet] [chat_template_file]
# Returns 0 when server is healthy, 1 on failure.
_llm_start_llamacpp_server() {
    local model_path="$1"
    local quiet="${2:-}"
    local chat_template_file="${3:-}"   # optional path to .jinja template file override
    local _hf_ref=""
    local _hf_fallback_ref=""
    local _launch_mode="model"

    # Optional -hf startup path. This can enable llama.cpp auto-discovery
    # for repo-root MTP drafters on compatible model repos.
    if [ "${LLAMA_CPP_USE_HF:-0}" = "1" ]; then
        if [ -n "${LLAMA_CPP_HF_REF:-}" ]; then
            _hf_ref="$LLAMA_CPP_HF_REF"
        elif [ -n "${LODGE_MODEL:-}" ] && declare -f _models_lookup &>/dev/null && declare -f _models_parse_entry &>/dev/null; then
            local _entry
            _entry=$(_models_lookup "$LODGE_MODEL" 2>/dev/null)
            if [ -n "$_entry" ]; then
                _models_parse_entry "$_entry"
                if [[ "${_ME_BASE:-}" == hf.co/* ]]; then
                    _hf_ref="${_ME_BASE#hf.co/}"
                fi
            fi
        fi
        if [ -n "$_hf_ref" ]; then
            _launch_mode="hf"
            # Startup fallback for quantized HF refs: BF16 -> F16.
            # This is useful on devices/backends where BF16 startup fails.
            if [[ "$_hf_ref" =~ :[Bb][Ff]16$ ]]; then
                _hf_fallback_ref="${_hf_ref%:*}:F16"
            fi
        fi
    fi

    # Validate
    if [ "$_launch_mode" = "model" ]; then
        if [ ! -f "$model_path" ]; then
            [ "$quiet" != "--quiet" ] && ui_err "Model file not found: $model_path"
            return 1
        fi
    fi
    if [ ! -x "$LLAMA_CPP_SERVER_BIN" ]; then
        [ "$quiet" != "--quiet" ] && ui_err "llama-server not found: $LLAMA_CPP_SERVER_BIN"
        return 1
    fi

    # Check if already running — adopt the existing server instead of failing.
    # This handles: another Lodge session started it, the smoke test left it
    # running, or this session's own PID file is still valid.
    local _port_check
    _port_check=$(echo "$LLAMA_CPP_URL" | sed -n 's/.*:\([0-9]*\)$/\1/p')
    _port_check="${_port_check:-8080}"
    if curl -sf --max-time 2 "$LLAMA_CPP_URL/health" 2>/dev/null | grep -q '"status"'; then
        # Verify the running server's GPU layers match our config.
        # A stale server from a previous session might have been launched
        # with -ngl >0 (Vulkan), producing gibberish on Adreno 830.
        local _running_ngl="" _srv_pid_adopt
        _srv_pid_adopt=$(pgrep -f "llama-server.*--port" 2>/dev/null | head -1)
        if [ -n "$_srv_pid_adopt" ] && [ -f "/proc/$_srv_pid_adopt/cmdline" ]; then
            _running_ngl=$(tr '\0' ' ' < "/proc/$_srv_pid_adopt/cmdline" 2>/dev/null \
                | sed -n 's/.*-ngl[[:space:]]*\([0-9]*\).*/\1/p')
        fi
        # Also try ps if /proc wasn't available
        if [ -z "$_running_ngl" ] && [ -n "$_srv_pid_adopt" ]; then
            _running_ngl=$(ps -p "$_srv_pid_adopt" -o args= 2>/dev/null \
                | sed -n 's/.*-ngl[[:space:]]*\([0-9]*\).*/\1/p')
        fi
        if [ -n "$_running_ngl" ] && [ "$_running_ngl" != "$LLAMA_CPP_GPU_LAYERS" ]; then
            [ "$quiet" != "--quiet" ] && ui_warn "Running llama-server has -ngl $_running_ngl but config wants $LLAMA_CPP_GPU_LAYERS — restarting"
            kill -9 "$_srv_pid_adopt" 2>/dev/null
            wait "$_srv_pid_adopt" 2>/dev/null
            sleep 1
        else
            [ "$quiet" != "--quiet" ] && ui_ok "llama-server already running on port $_port_check (adopted)"
            _LLM_BACKEND_CACHE=""
            LLAMA_CPP_MODEL="$model_path"
            LLAMA_CPP_SERVER_NOTHINK="${LODGE_NOTHINK:-0}"
            LLAMA_CPP_SERVER_SPEC_MTP="${LLAMA_CPP_SPEC_MTP:-0}"
            LLAMA_CPP_SERVER_DRAFT_MODEL="${LLAMA_CPP_DRAFT_MODEL:-}"
            return 0
        fi
    fi
    # Server may be loading a model — wait up to 30s for it
    local _loading_resp
    _loading_resp=$(curl -sf --max-time 2 "$LLAMA_CPP_URL/health" 2>/dev/null)
    if echo "$_loading_resp" | grep -q '"loading model"'; then
        [ "$quiet" != "--quiet" ] && ui_dim "llama-server loading model on port $_port_check — waiting..."
        local _wait=0
        while [ $_wait -lt 30 ]; do
            sleep 1
            if curl -sf --max-time 2 "$LLAMA_CPP_URL/health" 2>/dev/null | grep -q '"ok"'; then
                [ "$quiet" != "--quiet" ] && ui_ok "llama-server ready (adopted after ${_wait}s)"
                _LLM_BACKEND_CACHE=""
                LLAMA_CPP_MODEL="$model_path"
                LLAMA_CPP_SERVER_NOTHINK="${LODGE_NOTHINK:-0}"
                LLAMA_CPP_SERVER_SPEC_MTP="${LLAMA_CPP_SPEC_MTP:-0}"
                LLAMA_CPP_SERVER_DRAFT_MODEL="${LLAMA_CPP_DRAFT_MODEL:-}"
                return 0
            fi
            _wait=$((_wait + 1))
        done
        [ "$quiet" != "--quiet" ] && ui_warn "llama-server still loading after 30s — starting fresh"
    fi
    # Check PID file — kill stale process before starting new one
    if [ -f "$_LLAMA_CPP_PID_FILE" ]; then
        local _existing_pid
        _existing_pid=$(cat "$_LLAMA_CPP_PID_FILE" 2>/dev/null)
        if kill -0 "$_existing_pid" 2>/dev/null; then
            [ "$quiet" != "--quiet" ] && ui_dim "Stopping stale llama-server (PID $_existing_pid)"
            kill "$_existing_pid" 2>/dev/null
            sleep 1
            kill -9 "$_existing_pid" 2>/dev/null
            wait "$_existing_pid" 2>/dev/null
        fi
        rm -f "$_LLAMA_CPP_PID_FILE"
    fi
    # Also kill any orphan llama-server (e.g. smoke test or crashed session)
    local _orphan_pid
    _orphan_pid=$(pgrep -f "llama-server.*--port" 2>/dev/null | head -1)
    if [ -n "$_orphan_pid" ]; then
        [ "$quiet" != "--quiet" ] && ui_dim "Killing orphan llama-server (PID $_orphan_pid)"
        kill -9 "$_orphan_pid" 2>/dev/null
        wait "$_orphan_pid" 2>/dev/null
        sleep 1
    fi

    # Unload Ollama models to free GPU VRAM before starting llama-server.
    # This prevents Out Of Memory crashes on Termux.
    if _llm_ollama_responding; then
        local _ps_resp
        _ps_resp=$(curl -sf --max-time 3 "$OLLAMA_URL/api/ps" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$_ps_resp" ]; then
            local _active_models
            _active_models=$(echo "$_ps_resp" | jq -r '.models[].name' 2>/dev/null || echo "")
            if [ -n "$_active_models" ]; then
                local _am _unloaded=0
                for _am in $_active_models; do
                    [ -z "$_am" ] && continue
                    [ "$quiet" != "--quiet" ] && [ "$_unloaded" -eq 0 ] && ui_dim "Unloading Ollama models to free GPU VRAM..."
                    curl -sf --max-time 5 "$OLLAMA_URL/api/generate" \
                        -H "Content-Type: application/json" \
                        -d "{\"model\": \"$_am\", \"prompt\": \"\", \"keep_alive\": 0}" &>/dev/null
                    _unloaded=1
                done
                if [ "$_unloaded" -eq 1 ]; then
                    sleep 2 # cooling period to let GPU driver recycle allocations
                fi
            fi
        fi
    fi

    local _port
    _port=$(echo "$LLAMA_CPP_URL" | sed -n 's/.*:\([0-9]*\)$/\1/p')
    _port="${_port:-8080}"

    [ "$quiet" != "--quiet" ] && ui_dim "Starting llama-server on port $_port..."

    # Build launch args
    local _launch_args=(
        --port "$_port"
        -ngl "$LLAMA_CPP_GPU_LAYERS"
        -c "$((LLAMA_CPP_CTX_SIZE * LLAMA_CPP_SLOTS))"
        --threads "$(nproc 2>/dev/null || echo 4)"
        --parallel "$LLAMA_CPP_SLOTS"
    )

    if [ "${LLAMA_CPP_NO_MMAP:-0}" = "1" ]; then
        if _llm_llamacpp_supports_flag "--no-mmap"; then
            _launch_args+=(--no-mmap)
            [ "$quiet" != "--quiet" ] && ui_dim "Memory mapping: disabled (--no-mmap)"
        fi
    fi

    if [ "$_launch_mode" = "hf" ]; then
        _launch_args=(-hf "$_hf_ref" "${_launch_args[@]}")
        [ "$quiet" != "--quiet" ] && ui_dim "Model source: -hf $_hf_ref"
    else
        _launch_args=(-m "$model_path" "${_launch_args[@]}")
        [ "$quiet" != "--quiet" ] && ui_dim "Model source: -m $model_path"
    fi

    # KV cache precision tuning: apply only when explicitly requested.
    # On mobile devices q8_0 can cut memory traffic while preserving quality.
    if [ -n "${LLAMA_CPP_KV_CACHE_TYPE:-}" ] && [ "${LLAMA_CPP_KV_CACHE_TYPE}" != "auto" ]; then
        case "${LLAMA_CPP_KV_CACHE_TYPE}" in
            f16|bf16|q8_0|q6_K|q5_0|q5_1|q5_K|q4_0|q4_1|q4_K)
                _launch_args+=(--cache-type-k "$LLAMA_CPP_KV_CACHE_TYPE" --cache-type-v "$LLAMA_CPP_KV_CACHE_TYPE")
                [ "$quiet" != "--quiet" ] && ui_dim "KV cache type: ${LLAMA_CPP_KV_CACHE_TYPE}"
                ;;
            *)
                [ "$quiet" != "--quiet" ] && ui_warn "Ignoring unsupported LLAMA_CPP_KV_CACHE_TYPE='$LLAMA_CPP_KV_CACHE_TYPE' (using llama.cpp default)"
                ;;
        esac
    fi

    # Prompt cache: reuses prompt prefill across repeated/system-heavy calls.
    # Older llama.cpp builds may not support these flags, so gate by --help.
    if [ "${LLAMA_CPP_PROMPT_CACHE:-1}" = "1" ]; then
        local _pc_file="${LLAMA_CPP_PROMPT_CACHE_FILE:-${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}/llama-prompt-cache.bin}"
        mkdir -p "$(dirname "$_pc_file")" 2>/dev/null
        if _llm_llamacpp_supports_flag "--prompt-cache"; then
            _launch_args+=(--prompt-cache "$_pc_file")
            if [ "${LLAMA_CPP_PROMPT_CACHE_ALL:-1}" = "1" ]; then
                if _llm_llamacpp_supports_flag "--prompt-cache-all"; then
                    _launch_args+=(--prompt-cache-all)
                else
                    [ "$quiet" != "--quiet" ] && ui_warn "llama-server does not support --prompt-cache-all (skipping)"
                fi
            fi
            [ "$quiet" != "--quiet" ] && ui_dim "Prompt cache: $_pc_file"
        else
            [ "$quiet" != "--quiet" ] && ui_warn "llama-server does not support --prompt-cache (skipping prompt cache flags)"
        fi
    fi

    # Flash attention toggle for mobile stability/perf experiments.
    case "${LLAMA_CPP_FA:-auto}" in
        on|off)
            _launch_args+=(-fa "${LLAMA_CPP_FA}")
            [ "$quiet" != "--quiet" ] && ui_dim "Flash attention: ${LLAMA_CPP_FA}"
            ;;
        auto|"") ;;
        *)
            [ "$quiet" != "--quiet" ] && ui_warn "Ignoring invalid LLAMA_CPP_FA='${LLAMA_CPP_FA}' (expected auto|on|off)"
            ;;
    esac

    # Optional speculative decoding (MTP draft).
    # With Ollama-resolved GGUF (-m path), llama.cpp cannot auto-discover the
    # repo-root MTP draft from -hf metadata, so support explicit local draft file.
    local _use_mtp=0
    local _spec_mtp=0
    if [ "${LLAMA_CPP_SPEC_MTP:-0}" = "1" ]; then
        if declare -f models_has_mtp &>/dev/null; then
            if models_has_mtp "$LODGE_MODEL"; then
                _use_mtp=1
            fi
        else
            # Fallback check if models_has_mtp is not loaded yet
            case "$LODGE_MODEL" in
                *gemma4-inst:4b*|*gemma4-inst:12b*|*e4b*|*12b*)
                    _use_mtp=1
                    ;;
            esac
        fi

        # Auto-configure external 2B draft model GGUF path if the file exists
        case "$LODGE_MODEL" in
            *gemma4-inst:2b*|*e2b*)
                local _g2b_draft="${LODGE_DIR:-/workspace}/.george/models/mtp-gemma-4-E2B-it.gguf"
                if [ -L "$_g2b_draft" ] && [ ! -e "$_g2b_draft" ]; then
                    [ "$quiet" != "--quiet" ] && ui_warn "Broken symlink detected at $_g2b_draft. Removing it."
                    rm -f "$_g2b_draft"
                fi
                if [ ! -f "$_g2b_draft" ]; then
                    [ "$quiet" != "--quiet" ] && ui_step "Downloading Gemma 4 E2B MTP draft model from Hugging Face..."
                    mkdir -p "$(dirname "$_g2b_draft")"
                    if curl -L -o "$_g2b_draft" "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/MTP/mtp-gemma-4-E2B-it-BF16.gguf"; then
                        [ "$quiet" != "--quiet" ] && ui_ok "Gemma 4 E2B MTP draft model downloaded successfully!"
                    else
                        [ "$quiet" != "--quiet" ] && ui_err "Failed to download Gemma 4 E2B MTP draft model. Bypassing speculative decoding."
                        rm -f "$_g2b_draft"
                    fi
                fi
                if [ -f "$_g2b_draft" ]; then
                    LLAMA_CPP_DRAFT_MODEL="$_g2b_draft"
                    _use_mtp=1
                fi
                ;;
        esac
    fi

    if [ "$_use_mtp" -eq 1 ]; then
        if [ "$_launch_mode" = "hf" ] && [ -z "${LLAMA_CPP_DRAFT_MODEL:-}" ]; then
            [ "$quiet" != "--quiet" ] && ui_dim "MTP: using llama.cpp -hf auto-discovery for repo draft model"
        fi
        _spec_mtp=1
    fi

    if [ "$_spec_mtp" = "1" ]; then
        # Resolve MTP draft model HF reference or local file
        local _spec_draft_hf=""
        if [ -n "${LLAMA_CPP_SPEC_DRAFT_HF:-}" ]; then
            _spec_draft_hf="$LLAMA_CPP_SPEC_DRAFT_HF"
        elif [ "$_launch_mode" = "hf" ] && [ -n "$_hf_ref" ]; then
            # If main model is gemma-4 E2B, auto-specify the MTP draft reference
            if [[ "$_hf_ref" == unsloth/gemma-4-E2B-it-qat-GGUF* ]]; then
                local _repo_only="${_hf_ref%:*}"
                _spec_draft_hf="${_repo_only}:mtp-gemma-4-E2B-it"
            fi
        elif [ "$_launch_mode" = "model" ] && [ -z "${LLAMA_CPP_DRAFT_MODEL:-}" ]; then
            # If main model is local GGUF, but is Gemma-4 E2B, load draft from HF
            if [[ "${LODGE_MODEL:-}" == "gemma4-e2b-inst" ]]; then
                _spec_draft_hf="unsloth/gemma-4-E2B-it-qat-GGUF:mtp-gemma-4-E2B-it"
            elif [[ "${LODGE_MODEL:-}" == gemma4-* ]]; then
                # Embedded MTP models: use the main model GGUF path itself
                LLAMA_CPP_DRAFT_MODEL="$model_path"
            fi
        fi

        # Safety Check: If no draft GGUF was resolved/configured, and we are not in HF auto-discovery mode,
        # disable speculative decoding to prevent llama-server from crashing.
        if [ -z "${LLAMA_CPP_DRAFT_MODEL:-}" ] && [ -z "$_spec_draft_hf" ] && [ "$_launch_mode" = "model" ]; then
            [ "$quiet" != "--quiet" ] && ui_warn "No speculative draft GGUF configured/resolved for $LODGE_MODEL. Disabling speculation."
            _spec_mtp=0
        fi
    fi

    if [ "$_spec_mtp" = "1" ]; then
        _launch_args+=(--spec-type draft-mtp --spec-draft-n-max "${LLAMA_CPP_SPEC_DRAFT_N_MAX:-4}")

        # If spec-draft-hf is determined, we must pre-download it because llama.cpp
        # does not support concurrent Hugging Face downloads for main + draft models.
        if [ -n "$_spec_draft_hf" ]; then
            local _d_repo="${_spec_draft_hf%%:*}"
            local _d_tag="${_spec_draft_hf#*:}"
            [ "$_d_tag" = "$_d_repo" ] && _d_tag="mtp-gemma-4-E2B-it"
            
            local _d_filename="${_d_tag##*/}.gguf"
            local _d_dir="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}/models"
            local _d_local_path="${_d_dir}/${_d_filename}"
            
            if [ ! -f "$_d_local_path" ]; then
                mkdir -p "$_d_dir" 2>/dev/null
                [ "$quiet" != "--quiet" ] && ui_dim "Downloading MTP draft model to $_d_local_path..."
                local _d_url="https://huggingface.co/${_d_repo}/resolve/main/${_d_tag}.gguf"
                if ! curl -sSL --connect-timeout 10 -o "$_d_local_path" "$_d_url"; then
                    rm -f "$_d_local_path"
                    [ "$quiet" != "--quiet" ] && ui_warn "Failed to download MTP draft model from $_d_url (speculative decoding disabled)"
                    _spec_draft_hf=""
                fi
            fi
            
            if [ -f "$_d_local_path" ]; then
                LLAMA_CPP_DRAFT_MODEL="$_d_local_path"
                _spec_draft_hf="" # disable HF draft mode, use local model-draft instead
            fi
        fi

        if [ -n "$_spec_draft_hf" ]; then
            if _llm_llamacpp_supports_flag "--spec-draft-hf"; then
                _launch_args+=(--spec-draft-hf "$_spec_draft_hf")
                [ "$quiet" != "--quiet" ] && ui_dim "MTP draft HF: $_spec_draft_hf"
            elif _llm_llamacpp_supports_flag "--hf-repo-draft"; then
                _launch_args+=(--hf-repo-draft "$_spec_draft_hf")
                [ "$quiet" != "--quiet" ] && ui_dim "MTP draft HF: $_spec_draft_hf"
            else
                [ "$quiet" != "--quiet" ] && ui_warn "llama-server does not support --spec-draft-hf (skipping MTP draft)"
            fi
        elif [ -n "${LLAMA_CPP_DRAFT_MODEL:-}" ]; then
            if [ -f "$LLAMA_CPP_DRAFT_MODEL" ]; then
                _launch_args+=(--model-draft "$LLAMA_CPP_DRAFT_MODEL")
                [ "$quiet" != "--quiet" ] && ui_dim "MTP draft model: $LLAMA_CPP_DRAFT_MODEL"
            else
                [ "$quiet" != "--quiet" ] && ui_warn "LLAMA_CPP_DRAFT_MODEL not found: $LLAMA_CPP_DRAFT_MODEL (using target-only verify path)"
            fi
        elif [ "$_launch_mode" = "hf" ]; then
            [ "$quiet" != "--quiet" ] && ui_dim "MTP: using llama.cpp -hf auto-discovery for repo draft model"
        fi
    else
        [ "$quiet" != "--quiet" ] && [ "${LLAMA_CPP_SPEC_MTP:-0}" = "1" ] && ui_dim "MTP speculative decoding disabled (not supported by model: $LODGE_MODEL)"
    fi

    # Vision projector: if the model has an mmproj blob (e.g., Ministral-3B-Instruct),
    # pass it to llama-server so /vision can send images.
    if declare -f _models_resolve_mmproj &>/dev/null; then
        local _mmproj
        _mmproj=$(_models_resolve_mmproj "$LODGE_MODEL" 2>/dev/null)
        if [ -n "$_mmproj" ] && [ -f "$_mmproj" ]; then
            _launch_args+=(--mmproj "$_mmproj")
            [ "$quiet" != "--quiet" ] && ui_dim "Vision projector: $_mmproj"
        fi
    fi

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

    # Optional chat template kwargs for thinking/reasoning control (e.g. Gemma 4, Qwen 3.5)
    local _chat_template_kwargs=""
    if declare -f models_supports_think_flag &>/dev/null && models_supports_think_flag "$LODGE_MODEL" 2>/dev/null; then
        if [ "${LODGE_NOTHINK:-0}" -eq 1 ]; then
            _chat_template_kwargs='{"enable_thinking":false}'
        else
            _chat_template_kwargs='{"enable_thinking":true}'
        fi
    fi
    if [ -n "$_chat_template_kwargs" ]; then
        if _llm_llamacpp_supports_flag "--chat-template-kwargs"; then
            _launch_args+=(--chat-template-kwargs "$_chat_template_kwargs")
            [ "$quiet" != "--quiet" ] && ui_dim "Chat template kwargs: $_chat_template_kwargs"
        fi
    fi

    # When GPU_LAYERS=0, prevent llama.cpp from even initializing the
    # Vulkan backend.  On Adreno 830 (Snapdragon 8 Elite), Vulkan init
    # alone can corrupt GPU state — especially through proot's syscall
    # translation layer — causing gibberish output and phone lockup.
    local _server_env=()
    if [ "$LLAMA_CPP_GPU_LAYERS" = "0" ]; then
        _server_env=(env GGML_VK_VISIBLE_DEVICES="" GGML_CUDA_VISIBLE_DEVICES="")
        [ "$quiet" != "--quiet" ] && ui_dim "Vulkan disabled (GPU layers = 0)"
    fi

    local _pid
    _pid=$( ( set -m; "${_server_env[@]}" "$LLAMA_CPP_SERVER_BIN" "${_launch_args[@]}" > "${TMPDIR:-/tmp}/lodge-llama-server.log" 2>&1 & echo $! ) 2>/dev/null )
    echo "$_pid" > "$_LLAMA_CPP_PID_FILE"

    # Wait for healthy (up to 30s)
    local _tries=0
    while [ $_tries -lt 30 ]; do
        sleep 1
        if curl -sf --max-time 2 "$LLAMA_CPP_URL/health" 2>/dev/null | grep -q '"status"'; then
            _LLM_BACKEND_CACHE=""
            LLAMA_CPP_MODEL="$model_path"
            LLAMA_CPP_SERVER_NOTHINK="${LODGE_NOTHINK:-0}"
            LLAMA_CPP_SERVER_SPEC_MTP="${LLAMA_CPP_SPEC_MTP:-0}"
            LLAMA_CPP_SERVER_DRAFT_MODEL="${LLAMA_CPP_DRAFT_MODEL:-}"
            [ "$quiet" != "--quiet" ] && ui_ok "llama-server started (PID $_pid)"
            # Verify no unexpected GPU offload
            local _log_file="${TMPDIR:-/tmp}/lodge-llama-server.log"
            if [ "$LLAMA_CPP_GPU_LAYERS" = "0" ] && grep -qi 'offloaded.*layers to GPU\|vulkan' "$_log_file" 2>/dev/null; then
                local _gpu_msg
                _gpu_msg=$(grep -i 'offloaded\|vulkan' "$_log_file" 2>/dev/null | head -3)
                [ "$quiet" != "--quiet" ] && ui_warn "Unexpected GPU activity in server log:"
                echo "$_gpu_msg" | while IFS= read -r _l; do [ "$quiet" != "--quiet" ] && ui_dim "  $_l"; done
            fi
            return 0
        fi
        # Check if process died
        if ! kill -0 "$_pid" 2>/dev/null; then
            [ "$quiet" != "--quiet" ] && ui_err "llama-server died during startup"
            [ "$quiet" != "--quiet" ] && tail -5 "${TMPDIR:-/tmp}/lodge-llama-server.log" 2>/dev/null | while IFS= read -r _line; do ui_dim "  $_line"; done
            rm -f "$_LLAMA_CPP_PID_FILE"
            if [ "$_launch_mode" = "hf" ] && [ -n "$_hf_fallback_ref" ] && [ -z "${_LLM_HF_FALLBACK_TRIED:-}" ]; then
                [ "$quiet" != "--quiet" ] && ui_warn "Retrying llama.cpp with fallback HF ref: $_hf_fallback_ref"
                LLAMA_CPP_HF_REF="$_hf_fallback_ref" _LLM_HF_FALLBACK_TRIED=1 _llm_start_llamacpp_server "$model_path" "$quiet" "$chat_template_file"
                return $?
            fi
            return 1
        fi
        _tries=$((_tries + 1))
    done

    # Timeout
    [ "$quiet" != "--quiet" ] && ui_err "llama-server failed to start within 30s"
    [ "$quiet" != "--quiet" ] && ui_dim "  Log: ${TMPDIR:-/tmp}/lodge-llama-server.log"
    kill "$_pid" 2>/dev/null
    rm -f "$_LLAMA_CPP_PID_FILE"
    if [ "$_launch_mode" = "hf" ] && [ -n "$_hf_fallback_ref" ] && [ -z "${_LLM_HF_FALLBACK_TRIED:-}" ]; then
        [ "$quiet" != "--quiet" ] && ui_warn "Retrying llama.cpp with fallback HF ref: $_hf_fallback_ref"
        LLAMA_CPP_HF_REF="$_hf_fallback_ref" _LLM_HF_FALLBACK_TRIED=1 _llm_start_llamacpp_server "$model_path" "$quiet" "$chat_template_file"
        return $?
    fi
    return 1
}

# ── Ollama → OpenAI penalty conversion ─────────────────────────
# Ollama `repeat_penalty` is MULTIPLICATIVE: logit /= penalty for
# each occurrence (1.0 = off, 1.2 = moderate, 1.5 = heavy).
# OpenAI `frequency_penalty` is ADDITIVE: logit -= penalty * count
# (0.0 = off, 0.5 = moderate, 2.0 = max).
# Passing repeat_penalty (1.2) straight as frequency_penalty causes
# catastrophic over-penalisation → gibberish on small models.
#
# Conversion: freq = (repeat - 1.0) * 2.0, clamped to [0.0, 2.0].
#   1.0 → 0.0   1.1 → 0.2   1.2 → 0.4   1.5 → 1.0
_llm_repeat_to_freq() {
    awk "BEGIN { v = ($1 - 1.0) * 2.0; if (v < 0) v = 0; if (v > 2) v = 2; printf \"%.2f\", v }"
}

# ── Build llama.cpp payload ────────────────────────────────────
# Translates Blue Lodge parameters into OpenAI-compatible payload
# for llama-server's /v1/chat/completions endpoint.
# Usage: _llm_build_llamacpp_payload "prompt" "system" "opts_json" "max_tokens" [stream] [grammar] [stop_token]
_llm_build_llamacpp_payload() {
    local prompt="$1"
    local system="${2:-}"
    local opts_json="$3"
    local max_tokens="$4"
    local stream="${5:-true}"
    local grammar="${6:-}"
    local stop_token="${7:-}"

    # Extract all sampling params in a single jq call (6→1).
    # Each jq invocation costs ~20-50ms on ARM (process spawn + parse).
    # Batching saves ~100-250ms per LLM call.
    local temp rep_raw pres top_p top_k min_p
    read -r temp rep_raw pres top_p top_k min_p <<< "$(echo "$opts_json" | jq -r '[.temperature // 0.7, .repeat_penalty // 1.2, .presence_penalty // 0.3, .top_p // 1.0, .top_k // 40, .min_p // 0.0] | @tsv')"

    # Convert Ollama repeat_penalty → OpenAI frequency_penalty
    local freq
    freq=$(_llm_repeat_to_freq "$rep_raw")

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

    # top_p is standard OpenAI; top_k and min_p are llama-server extensions
    # stream_options.include_usage tells llama-server to emit token counts
    # in the final SSE chunk before [DONE] (prompt_tokens + completion_tokens).
    # ── Optional GBNF grammar for constrained decoding ──────
    # When a grammar is provided, llama-server constrains token
    # sampling to only produce output matching the grammar rules.
    # This gives Layer 1 schema enforcement at the decoding level.
    if [ "$stream" = "true" ]; then
        jq -n \
            --argjson messages "$messages" \
            --argjson max_tokens "$max_tokens" \
            --argjson temperature "$temp" \
            --argjson frequency_penalty "$freq" \
            --argjson presence_penalty "$pres" \
            --argjson top_p "$top_p" \
            --argjson top_k "$top_k" \
            --argjson min_p "$min_p" \
            --argjson stream "$stream" \
            --arg grammar "$grammar" \
            --arg stop "$stop_token" \
            '{messages:$messages, max_tokens:$max_tokens, temperature:$temperature, frequency_penalty:$frequency_penalty, presence_penalty:$presence_penalty, top_p:$top_p, top_k:$top_k, min_p:$min_p, stream:$stream, stream_options:{include_usage:true}} + (if ($grammar | length) > 0 then {grammar:$grammar} else {} end) + (if ($stop | length) > 0 then {stop:[$stop]} else {} end)'
    else
        jq -n \
            --argjson messages "$messages" \
            --argjson max_tokens "$max_tokens" \
            --argjson temperature "$temp" \
            --argjson frequency_penalty "$freq" \
            --argjson presence_penalty "$pres" \
            --argjson top_p "$top_p" \
            --argjson top_k "$top_k" \
            --argjson min_p "$min_p" \
            --argjson stream "$stream" \
            --arg grammar "$grammar" \
            --arg stop "$stop_token" \
            '{messages:$messages, max_tokens:$max_tokens, temperature:$temperature, frequency_penalty:$frequency_penalty, presence_penalty:$presence_penalty, top_p:$top_p, top_k:$top_k, min_p:$min_p, stream:$stream} + (if ($grammar | length) > 0 then {grammar:$grammar} else {} end) + (if ($stop | length) > 0 then {stop:[$stop]} else {} end)'
    fi
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
    # Provider harness: no local backend needed
    [ -n "${GEORGE_PROVIDER:-}" ] && return 0

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

    local resp
    resp=$(curl -sf --max-time 5 "$OLLAMA_URL/api/ps" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$resp" ]; then
        local loaded_models
        loaded_models=$(echo "$resp" | jq -r '.models[].name' 2>/dev/null || echo "")
        if [ -n "$loaded_models" ]; then
            local m
            for m in $loaded_models; do
                [ -z "$m" ] && continue
                ui_dim "Unloading model $m from memory..."
                curl -sf --max-time 10 "$OLLAMA_URL/api/generate" \
                    -H "Content-Type: application/json" \
                    -d "{\"model\": \"$m\", \"prompt\": \"\", \"keep_alive\": 0}" &>/dev/null
            done
            sleep 1
            ui_dim "All Ollama models unloaded from memory"
        fi
    fi
}

# ── Cancel active LLM request ──────────────────────────────────
llm_cancel() {
    _llm_kill_curl
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
        (true >/dev/tty) 2>/dev/null || _tty="/dev/null"

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
                _llm_start_ollama_server || true
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

# Check if Ollama is running and responding (cache result to prevent repeated timeout delays)
_llm_ollama_responding() {
    if [ "${_LLM_OLLAMA_RESPONDING_CACHE:-}" = "1" ]; then
        return 0
    elif [ "${_LLM_OLLAMA_RESPONDING_CACHE:-}" = "0" ]; then
        return 1
    fi

    if curl -sf --max-time 1 "$OLLAMA_URL/api/tags" &>/dev/null; then
        _LLM_OLLAMA_RESPONDING_CACHE=1
        return 0
    else
        _LLM_OLLAMA_RESPONDING_CACHE=0
        return 1
    fi
}

# ── Kill Ollama and free its RAM ───────────────────────────────
# Sends SIGKILL (Ollama ignores SIGTERM with a loaded model).
_llm_kill_ollama() {
    local quiet="${1:-}"
    if pgrep -f ollama &>/dev/null; then
        pkill -9 -f ollama 2>/dev/null
        sleep 1
        [ "$quiet" != "--quiet" ] && ui_dim "Stopped Ollama (freed RAM for llama-server)"
    fi
}

# Start Ollama and confirm the API is reachable.
# Returns 0 on success, 1 on failure.
_llm_start_ollama_server() {
    local _log_file="${TMPDIR:-/tmp}/lodge-ollama.log"
    local _pid
    _pid=$( ( set -m; ollama serve > "$_log_file" 2>&1 & echo $! ) 2>/dev/null )
    sleep 3

    if curl -sf --max-time 2 "$OLLAMA_URL/api/tags" &>/dev/null; then
        return 0
    fi

    if ! kill -0 "$_pid" 2>/dev/null; then
        ui_dim "  Ollama exited during startup (PID $_pid). This is often OOM on low-memory devices."
    fi
    ui_dim "  Ollama log: $_log_file"
    return 1
}

# ── Ensure LLM backend is running ─────────────────────────────
# Strategy: try llama-server first (custom-compiled, faster on this
# hardware), kill Ollama if llamacpp succeeds, fall back to Ollama
# only when llamacpp is unavailable.
llm_ensure() {
    # Provider harness: no local backend needed
    [ -n "${GEORGE_PROVIDER:-}" ] && return 0

    # Ensure active model reflects LODGE_MODEL_PRIMARY for checks/resolving
    if [ -n "${LODGE_MODEL_PRIMARY:-}" ]; then
        LODGE_MODEL="$LODGE_MODEL_PRIMARY"
    fi

    local backend
    backend=$(_llm_detect_backend)

    # ── llamacpp already running and healthy? ─────────────────
    if [ "$backend" = "llamacpp" ]; then
        llm_check
        local status=$?
        if [ "$status" -eq 0 ]; then
            if declare -f models_supports_think_flag &>/dev/null && models_supports_think_flag "$LODGE_MODEL" 2>/dev/null && [ "${LLAMA_CPP_SERVER_NOTHINK:-}" != "${LODGE_NOTHINK:-0}" ]; then
                ui_dim "llama-server thinking mode changed — restarting..."
                _llm_stop_llamacpp_server --quiet
            else
                _llm_kill_ollama --quiet
                return 0
            fi
        fi
        # Server exists but still loading — wait for it
        if [ "$status" -eq 2 ]; then
            ui_dim "llama-server loading model — waiting..."
            local _wait=0
            while [ $_wait -lt 30 ]; do
                sleep 1
                llm_check
                status=$?
                [ "$status" -eq 0 ] && { _llm_kill_ollama --quiet; return 0; }
                [ "$status" -ne 2 ] && break  # died or errored
                _wait=$((_wait + 1))
            done
            # If we timed out but it's still loading, don't start another
            llm_check
            [ $? -eq 0 ] && { _llm_kill_ollama --quiet; return 0; }
            [ $? -eq 2 ] && { ui_warn "llama-server still loading after 30s"; return 0; }
        fi
    fi

    # ── Try to auto-start llama-server (preferred backend) ─────
    if [ "${LLM_BACKEND:-}" != "ollama" ] && [ -x "$LLAMA_CPP_SERVER_BIN" ]; then
        if [ "$backend" != "llamacpp" ] || ! curl -sf --max-time 2 "$LLAMA_CPP_URL/health" 2>/dev/null | grep -q '"status"'; then
            ui_dim "llama-server available — starting..."
            # Resolve GGUF model to load
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
                    if [ -z "$_gguf" ] && [ "${LLAMA_CPP_USE_HF:-0}" = "1" ]; then
                        _gguf="hf-harness-auto-resolved"
                    fi
                fi
            fi
            if [ -n "$_gguf" ] && { [ -f "$_gguf" ] || [ "${LLAMA_CPP_USE_HF:-0}" = "1" ]; }; then
                # Kill Ollama first — frees RAM and avoids port conflicts
                _llm_kill_ollama --quiet
                if _llm_start_llamacpp_server "$_gguf"; then
                    _LLM_BACKEND_CACHE="llamacpp"
                    LLM_BACKEND="llamacpp"
                    _MODELS_ACTIVE="$LODGE_MODEL_PRIMARY"
                    LODGE_MODEL="$LODGE_MODEL_PRIMARY"
                    return 0
                fi
                ui_warn "llama-server failed to start — falling back to Ollama"
            else
                ui_dim "  No GGUF found for $LODGE_MODEL_PRIMARY — trying Ollama"
            fi
        fi
    fi

    # ── Ollama fallback ────────────────────────────────────────
    # Final fallback starts ollama serve via _llm_start_ollama_server.
    LLM_BACKEND="ollama"
    _LLM_BACKEND_CACHE=""  # Clear so detection re-checks
    backend=$(_llm_detect_backend)
    llm_check
    local status=$?

    if [ "$status" -eq 1 ]; then
        # Ollama not running — attempt to start
        if command -v ollama &>/dev/null; then
            : "ollama serve fallback"
            ui_warn "Starting Ollama as fallback..."
            _llm_start_ollama_server
            _LLM_BACKEND_CACHE=""
            llm_check
            status=$?

            if [ "$status" -eq 1 ]; then
                ui_err "No LLM backend available."
                ui_dim "  llama-server: $LLAMA_CPP_SERVER_BIN"
                [ ! -x "$LLAMA_CPP_SERVER_BIN" ] && ui_dim "    ^ not found — build: docs/ADRENO_GPU_SETUP.md"
                ui_dim "  Ollama: failed to start. Check ${TMPDIR:-/tmp}/lodge-ollama.log"
                return 1
            fi
        else
            ui_err "No LLM backend available."
            ui_dim "  llama-server: ${LLAMA_CPP_SERVER_BIN:-<not set>}"
            ui_dim "  Ollama: not installed"
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

# ── REPL health check — lightweight pre-input validation ──────
# Called before each REPL input dispatch to verify the active
# backend is still alive. If llamacpp dies (OOM, crash, phone
# sleep), this detects it and either restarts or falls back.
# Returns 0 = healthy, 1 = no backend available.
llm_repl_health_check() {
    # Provider harness: no local backend needed
    [ -n "${GEORGE_PROVIDER:-}" ] && return 0

    local backend
    backend=$(_llm_detect_backend 2>/dev/null)

    if [ "$backend" = "llamacpp" ]; then
        # Quick health probe — 2s timeout, no retry
        if curl -sf --max-time 2 "$LLAMA_CPP_URL/health" 2>/dev/null | grep -q '"status"'; then
            return 0  # healthy
        fi

        # Server died — try to restart
        ui_warn "llama-server not responding — restarting..."
        _LLM_BACKEND_CACHE=""
        if _llm_start_llamacpp_server "${LLAMA_CPP_MODEL:-}" "--quiet" 2>/dev/null; then
            _LLM_BACKEND_CACHE="llamacpp"
            ui_ok "llama-server restarted"
            return 0
        fi

        # Restart failed — fall back to Ollama if in auto mode
        if [ "${LLM_BACKEND:-auto}" = "auto" ] || [ -z "${LLM_BACKEND:-}" ]; then
            ui_warn "llama-server restart failed — falling back to Ollama"
            _LLM_BACKEND_CACHE=""
            if curl -sf --max-time 2 "$OLLAMA_URL/api/tags" &>/dev/null; then
                _LLM_BACKEND_CACHE="ollama"
                return 0
            fi
            # Try starting Ollama
            if command -v ollama &>/dev/null; then
                if _llm_start_ollama_server; then
                    _LLM_BACKEND_CACHE="ollama"
                    return 0
                fi
            fi
        fi

        ui_err "No LLM backend available — commands requiring LLM will fail"
        return 1
    fi

    # Ollama backend — quick check
    if [ "$backend" = "ollama" ]; then
        if curl -sf --max-time 2 "$OLLAMA_URL/api/tags" &>/dev/null; then
            return 0
        fi
        ui_warn "Ollama not responding"
        _LLM_BACKEND_CACHE=""
        return 1
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
    (true >/dev/tty) 2>/dev/null || _tty="/dev/null"
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
    # Compute tokens/sec from output tokens and elapsed time
    local _tok_s=""
    if [[ "$output_tok" =~ ^[0-9]+$ ]] && [ "$output_tok" -gt 0 ] && [ "$elapsed_ms" -gt 0 ]; then
        _tok_s=$(awk "BEGIN{printf \"%.1f\", ($output_tok / ($elapsed_ms / 1000.0))}")
        _tok_s=" ${_tok_s} tok/s"
    fi
    # Write per-call record to file — survives $() subshells
    mkdir -p "$_LLM_DEBUG_DIR" 2>/dev/null
    local _in_n=0 _out_n=0
    [[ "$input_tok" =~ ^[0-9]+$ ]] && _in_n="$input_tok"
    [[ "$output_tok" =~ ^[0-9]+$ ]] && _out_n="$output_tok"
    echo "$_in_n $_out_n $elapsed_ms" >> "$_LLM_DEBUG_DIR/calls.log" 2>/dev/null
    _llm_debug_print "${label}: ${elapsed_s}s | in:${input_tok} out:${output_tok} tok${_tok_s}"
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
    local now _calls _total_in _total_out _total_ms
    now=$(date +%s)
    local total_s=$(( now - ${_LLM_DEBUG_TASK_START:-$now} ))
    # Sum from the file-based log
    _calls=0; _total_in=0; _total_out=0; _total_ms=0
    if [ -f "$_LLM_DEBUG_DIR/calls.log" ]; then
        while read -r _in _out _ms; do
            _calls=$((_calls + 1))
            _total_in=$((_total_in + _in))
            _total_out=$((_total_out + _out))
            _total_ms=$((_total_ms + ${_ms:-0}))
        done < "$_LLM_DEBUG_DIR/calls.log"
    fi
    # Compute aggregate tok/s from total output tokens and total LLM time
    local _agg_tok_s=""
    if [ "$_total_out" -gt 0 ] && [ "$_total_ms" -gt 0 ]; then
        _agg_tok_s=$(awk "BEGIN{printf \"%.1f\", ($_total_out / ($_total_ms / 1000.0))}")
    fi
    local _tty="/dev/tty"
    (true >/dev/tty) 2>/dev/null || _tty="/dev/null"
    printf "\n %b── Debug Summary ──────────────────────────────%b\n" "$C_DIM" "$C_RESET" > "$_tty" 2>/dev/null
    printf " %b  LLM calls:     %d%b\n" "$C_DIM" "$_calls" "$C_RESET" > "$_tty" 2>/dev/null
    printf " %b  Total input:   %d tokens%b\n" "$C_DIM" "$_total_in" "$C_RESET" > "$_tty" 2>/dev/null
    printf " %b  Total output:  %d tokens%b\n" "$C_DIM" "$_total_out" "$C_RESET" > "$_tty" 2>/dev/null
    [ -n "$_agg_tok_s" ] && printf " %b  Avg throughput: %s tok/s%b\n" "$C_DIM" "$_agg_tok_s" "$C_RESET" > "$_tty" 2>/dev/null
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
# ── Grammar cache ──────────────────────────────────────────────
# Avoids re-reading .gbnf files from disk on every LLM call.
# Each grammar is ~200-500 bytes; caching saves ~5ms per call on ARM.
declare -gA _LLM_GRAMMAR_CACHE 2>/dev/null || true

# Load a GBNF grammar by schema name, using cache.
# Usage: _llm_load_grammar "p1-evaluator" → grammar string on stdout
_llm_load_grammar() {
    local schema_name="$1"
    [ -z "$schema_name" ] && return 1

    # Return from cache if available
    if [ -n "${_LLM_GRAMMAR_CACHE[$schema_name]+x}" ]; then
        echo "${_LLM_GRAMMAR_CACHE[$schema_name]}"
        return 0
    fi

    # Locate grammar file relative to LODGE_DIR
    local grammar_file="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/grammars/${schema_name}.gbnf"
    if [ ! -f "$grammar_file" ]; then
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] grammar file not found: $grammar_file" 2>/dev/null
        return 1
    fi

    local grammar_text
    grammar_text=$(cat "$grammar_file") || return 1
    _LLM_GRAMMAR_CACHE["$schema_name"]="$grammar_text"
    echo "$grammar_text"
}

llm_generate() {
    local prompt="$1"
    local system="${2:-}"
    local max_tokens="${3:-$LLM_MAX_TOKENS}"
    local budget="${4:-$LLM_BUDGET_TOKENS}"
    budget=$(_llm_resolve_think_budget "$budget")
    local schema_name="${5:-}"
    local payload

    # Log injected prompt to active transcript if configured
    if declare -f transcript_log_prompt &>/dev/null; then
        echo "  [debug] llm_generate: logging prompt role=${LLM_PROMPT_ROLE:-llm} file=$_PROMPT_LOG_FILE" 2>/dev/null >/dev/tty
        transcript_log_prompt "${LLM_PROMPT_ROLE:-llm}" "$prompt" "$system"
    else
        echo "  [debug] llm_generate: transcript_log_prompt function is NOT defined!" 2>/dev/null >/dev/tty
        echo "  [debug] llm_generate: defined transcript functions: $(declare -F | grep transcript || echo "none")" 2>/dev/null >/dev/tty
    fi

    # ── Provider harness intercept ─────────────────────────────
    # When a cloud provider is active, skip all local backend logic
    # and route directly through the provider API.
    if [ -n "${GEORGE_PROVIDER:-}" ] && declare -f _provider_call_with_backoff &>/dev/null; then
        _llm_debug_start_timer
        ui_spinner_start "$GEORGE_PROVIDER" 2>/dev/null >/dev/tty
        local _provider_resp
        _provider_resp=$(_provider_call_with_backoff "$GEORGE_PROVIDER" "$prompt" "" "$system")
        local _rc=$?
        ui_spinner_stop 2>/dev/null
        if [ $_rc -eq 0 ] && [ -n "$_provider_resp" ]; then
            echo "$_provider_resp"
            _llm_debug_end_timer "provider/$GEORGE_PROVIDER"
            return 0
        fi
        return $_rc
    fi

    # Capture thinking tokens dynamically for the transcript
    local _think_log_file=""
    _llm_think_log_start

    # Detect active backend
    local _active_backend
    _active_backend=$(_llm_detect_backend)

    # Thinking model 4x multiplier: thinking models emit <think> blocks
    # before the response, so token budgets must be larger to avoid
    # truncating mid-think (which causes unclosed [THINK] tags).
    max_tokens=$(_llm_apply_thinking_multiplier "$max_tokens")

    # Cap max_tokens to prevent llama-server context limit failures
    if [ "$_active_backend" = "llamacpp" ]; then
        local approx_prompt_tokens=$(( ( ${#prompt} + ${#system} ) / 3 ))
        local max_possible_output=$(( LLAMA_CPP_CTX_SIZE - approx_prompt_tokens - 32 ))
        if [ "$max_possible_output" -lt 16 ]; then
            max_possible_output=16
        fi
        if [ "$max_tokens" -gt "$max_possible_output" ]; then
            max_tokens=$max_possible_output
        fi
    fi

    _llm_debug_start_timer

    # Optimize system prompt for KV cache reuse in llama-server
    if [ "$_active_backend" = "llamacpp" ] && [ "${LLAMA_CPP_PROMPT_CACHE:-1}" = "1" ] && [ -n "$system" ]; then
        if [[ "$system" == *"[Current time:"* ]]; then
            local _time_line
            _time_line=$(echo "$system" | grep -o '^\[Current time: [^]]*\]' | head -1)
            if [ -n "$_time_line" ]; then
                system=$(echo "$system" | grep -F -v "$_time_line")
                prompt="${_time_line}
${prompt}"
            fi
        fi
        if [[ "$system" == *"[Vitals:"* ]]; then
            local _vitals_line
            _vitals_line=$(echo "$system" | grep -o '^\[Vitals: [^]]*\]' | head -1)
            if [ -n "$_vitals_line" ]; then
                system=$(echo "$system" | grep -F -v "$_vitals_line")
                prompt="${_vitals_line}
${prompt}"
            fi
        fi
    fi

    # Ensure correct model is loaded for this scenario
    if ! models_ensure_for_scenario "${LLM_SCENARIO:-}"; then
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] model switch failed, proceeding with current model"
    fi

    # ── Identity fallback (llamacpp only) ──────────────────────
    # Ollama bakes Modelfiles in — the SYSTEM block persists even
    # when callers pass no system prompt. llamacpp loads a raw GGUF
    # with no Modelfile — without this, the model reverts to its base
    # training identity ("I am Qwen", "I am Mistral", etc.).
    # Uses cached _LLM_DEFAULT_SYSTEM to avoid re-reading the .system
    # file from disk on every call (~20ms saved per call on ARM).
    if [ -z "$system" ] && [ "$_active_backend" = "llamacpp" ] \
       && declare -f models_default_system &>/dev/null; then
        if [ -z "${_LLM_DEFAULT_SYSTEM_CACHE:-}" ] || [ "${_LLM_DEFAULT_SYSTEM_MODEL:-}" != "$LODGE_MODEL" ]; then
            _LLM_DEFAULT_SYSTEM_CACHE=$(models_default_system 2>/dev/null)
            _LLM_DEFAULT_SYSTEM_MODEL="$LODGE_MODEL"
        fi
        system="$_LLM_DEFAULT_SYSTEM_CACHE"
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && [ -n "$system" ] && ui_dim "  [debug] inject: ${_ME_KEY:-default}.system identity (${#system} chars, cached)"
    fi

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

    # ── Load GBNF grammar for constrained decoding (Layer 1) ──
    local _grammar=""
    if [ "${LLM_GRAMMAR_ENABLED:-0}" -eq 1 ] && [ -n "$schema_name" ] && [ "$_active_backend" = "llamacpp" ]; then
        _grammar=$(_llm_load_grammar "$schema_name" 2>/dev/null) || true
    fi

    # ── llama.cpp path (OpenAI-compatible) ─────────────────────
    # Early-return branch: avoids touching Ollama's thinking-token
    # parsing. llama-server has no thinking API — all output is
    # content tokens via SSE /v1/chat/completions.
    if [ "$_active_backend" = "llamacpp" ]; then
        local _stop=""
        if declare -f models_info &>/dev/null; then
            local _ME_STOP=""
            models_info "$LODGE_MODEL" 2>/dev/null && _stop="$_ME_STOP"
        fi
        payload=$(_llm_build_llamacpp_payload "$prompt" "$system" "$_opts" "$max_tokens" true "$_grammar" "$_stop")

        local curl_timeout="${LLM_TIMEOUT:-600}"
        local timeout_cmd=""
        if [ "$curl_timeout" -gt 0 ] 2>/dev/null; then
            command -v timeout &>/dev/null && timeout_cmd="timeout $curl_timeout"
        fi

        _LLM_ACTIVE=1
        local _tty="/dev/tty"
        (true >/dev/tty) 2>/dev/null || _tty="/dev/null"
        local _tmpdir="${TMPDIR:-/tmp}"
        local _got_tokens="$_tmpdir/.lodge-gen-tok-$RANDOM-$BASHPID"
        local _cancel_file="$_tmpdir/.lodge-cancel-$$"
        local _curl_pid_file="$_tmpdir/.lodge-curl-pid-$$"
        rm -f "$_got_tokens" "$_curl_pid_file"

        local _dbg_out=0
        local _dbg_in=0

        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf "\n [debug] generate (llamacpp): url=%s max_tokens=%s\n" "$LLAMA_CPP_URL" "$max_tokens" > "$_tty" 2>/dev/null
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && [ -n "$_grammar" ] && printf " [debug] grammar: %s.gbnf (%d chars) → payload\n" "$schema_name" "${#_grammar}" > "$_tty" 2>/dev/null

        # ── Think-tag state machine for llamacpp ─────────────────
        # Reuses the same per-token inline-tag parsing infrastructure
        # developed for Ollama. llama-server has no .thinking field so
        # we are always in inline-tag fallback mode.
        local _in_think_block=0
        local _think_banner_open=0
        local _can_think=0
        models_current_has_thinking && _can_think=1
        local _think_pending=""
        local _response_pending=""
        local _think_detect_limit=4000

        # Debug tty echo helper (same as Ollama path)
        _gen_tty() {
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && [ -n "$1" ] && printf "\033[90m%s\033[0m" "$1" > "$_tty" 2>/dev/null
        }

        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf " [debug] generate(llamacpp) think: _can_think=%s model=%s\n" "$_can_think" "$LODGE_MODEL" > "$_tty" 2>/dev/null

        # Use a FIFO so we can track and kill the curl PID independently
        # of the read loop. Without this, curl survives `break` and keeps
        # llama-server's slot busy (phone stays hot).
        # On iSH (iOS QEMU) FIFOs deadlock — fall back to a plain pipe.
        local _fifo="$_tmpdir/.lodge-fifo-gen-$$"
        local _use_fifo=1
        if ! _llm_is_fifo_safe; then
            _use_fifo=0
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf " [debug] generate(llamacpp): FIFO bypass (platform=%s)\n" "${LODGE_PLATFORM:-}" > "$_tty" 2>/dev/null
        elif ! (rm -f "$_fifo" && mkfifo "$_fifo") 2>/dev/null; then
            _use_fifo=0
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf " [debug] generate(llamacpp): mkfifo failed, falling back to pipe\n" > "$_tty" 2>/dev/null
        fi

        if [ "$_use_fifo" -eq 1 ]; then
            $timeout_cmd curl -sN --connect-timeout 10 --max-time "$curl_timeout" \
                "$LLAMA_CPP_URL/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "$payload" > "$_fifo" 2>/dev/null &
            local _bg_curl=$!
            echo "$_bg_curl" > "$_curl_pid_file"
            _LLM_CURL_PID="$_bg_curl"
        fi

        # _llm_gen_sse_loop: shared read loop body extracted as a function
        # so the same token-processing code runs in both FIFO and pipe modes.
        # In pipe mode the loop runs in a subshell (right side of |), so
        # variable updates (_dbg_out etc.) are lost — acceptable trade-off.
        _llm_gen_sse_loop() {
        local _reasoning_content_active=0
        while IFS= read -r line; do
            [ -f "$_cancel_file" ] && break

            # SSE format: lines prefixed with "data: "
            [[ "$line" == data:* ]] || continue
            local json="${line#data: }"

            # Stream termination — flush buffers and break
            if [ "$json" = "[DONE]" ]; then
                # Close thinking banner if still open
                if [ "$_think_banner_open" -eq 1 ]; then
                    if [ "${LODGE_THINK:-0}" -eq 1 ] && [ "${LODGE_THINK_STREAM:-1}" -ge 1 ]; then
                        _llm_think_close "$_tty"
                    fi
                fi
                # Flush response_pending buffer (short response, <think> never arrived)
                if [ -n "$_response_pending" ]; then
                    _llm_normalize_think _response_pending
                    _response_pending="${_response_pending//<\/think>/}"
                    _response_pending="${_response_pending//<think>/}"
                    [ -n "$_response_pending" ] && printf "%s" "$_response_pending"
                    [ -n "$_response_pending" ] && _gen_tty "$_response_pending"
                fi
                # Flush pending think text as response if </think> never arrived
                if [ "$_in_think_block" -eq 1 ] && [ -n "$_think_pending" ]; then
                    _llm_normalize_think _think_pending
                    _think_pending="${_think_pending//<\/think>/}"
                    printf "%s" "$_think_pending"
                    _gen_tty "$_think_pending"
                fi
                if [ "${LODGE_DEBUG:-0}" -eq 1 ]; then
                    _llm_debug_end_timer "generate(llamacpp)" "$_dbg_in" "$_dbg_out"
                fi
                break
            fi

            local token=""
            if [[ "$json" =~ \"content\":\"(([^\"]|\\\")*)\" ]]; then
                token="${BASH_REMATCH[1]}"
                token="${token//\\n/$'\n'}"
                token="${token//\\t/$'\t'}"
                token="${token//\\\"/\"}"
                token="${token//\\\\/\\}"
            fi

            # ── reasoning_content support (llama-server ≥ b4000) ──
            # When the model's chat template has <think> support,
            # llama-server separates thinking from content:
            #   .choices[0].delta.reasoning_content = think tokens
            #   .choices[0].delta.content            = response tokens
            # This bypasses the inline-tag state machine entirely.
            local _rc=""
            if [[ "$json" =~ \"reasoning_content\":\"(([^\"]|\\\")*)\" ]]; then
                _rc="${BASH_REMATCH[1]}"
                _rc="${_rc//\\n/$'\n'}"
                _rc="${_rc//\\t/$'\t'}"
                _rc="${_rc//\\\"/\"}"
                _rc="${_rc//\\\\/\\}"
            fi
            if [ -n "$_rc" ]; then
                _reasoning_content_active=1
                [ -f "$_got_tokens" ] || touch "$_got_tokens"
                _dbg_out=$((_dbg_out + 1))
                if [ "$_think_banner_open" -eq 0 ] && [ "$_can_think" -eq 1 ]; then
                    _think_banner_open=1
                    _in_think_block=1
                    _llm_think_open "$_tty"
                fi
                _llm_think_show "$_rc" "$_tty"
                _response_pending=""
                continue
            fi
            # Close think banner when switching from reasoning to content
            if [ "$_in_think_block" -eq 1 ] && [ -n "$token" ] && [ "$_think_banner_open" -eq 1 ] && [ "$_reasoning_content_active" -eq 1 ]; then
                _think_banner_open=0
                _in_think_block=0
                _llm_think_close "$_tty"
                _response_pending=""
                _can_think=0  # disable inline detection — server handles it
                _reasoning_content_active=0
            fi

            # ── Capture usage stats from SSE chunks ──────────────
            # llama-server emits usage in the final content chunk
            # (with finish_reason) when stream_options.include_usage
            # is set. Capture on every line; last value wins.
            local _usage_pt=""
            if [[ "$json" =~ \"prompt_tokens\":([0-9]+) ]]; then
                _usage_pt="${BASH_REMATCH[1]}"
                [ -n "$_usage_pt" ] && _dbg_in="$_usage_pt"
            fi

            [ -n "$token" ] || continue
            [ -f "$_got_tokens" ] || touch "$_got_tokens"
            _dbg_out=$((_dbg_out + 1))

            # Strip <response>...</response> wrapper tags (Granite4 format)
            token="${token//<response>/}"
            token="${token//<\/response>/}"

            # Normalize bracket think tags → <think>/</think>
            _llm_normalize_think token

            # ── Inline-tag state machine (mirrors Ollama path) ─────
            # Phase 1: Preamble buffering — detect <think> in early tokens
            if [ "$_can_think" -eq 1 ] && [ "$_in_think_block" -eq 0 ]; then
                _response_pending+="$token"
                _llm_normalize_think _response_pending
                if [[ "$_response_pending" == *"<think>"* ]]; then
                    _in_think_block=1
                    _think_pending="${_response_pending#*<think>}"
                    [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf " [debug] generate(llamacpp): <think> detected inline (at %d chars)\n" "${#_response_pending}" > "$_tty" 2>/dev/null
                    # Output anything before <think> as response (preamble)
                    local _before="${_response_pending%%<think>*}"
                    _before="${_before//<\/think>/}"
                    [ -n "$_before" ] && printf "%s" "$_before"
                    [ -n "$_before" ] && _gen_tty "$_before"
                    _response_pending=""
                    _think_banner_open=1
                    _llm_think_open "$_tty"
                elif [[ "$_response_pending" == *"</think>"* ]]; then
                    # Implicit start of think block at character 0, ending now
                    local _think_before="${_response_pending%%</think>*}"
                    local _after_think="${_response_pending#*</think>}"
                    _after_think="${_after_think//<\/think>/}"
                    if [ "$_can_think" -eq 1 ]; then
                        _llm_think_open "$_tty"
                        _llm_think_show "$_think_before" "$_tty"
                        _llm_think_close "$_tty"
                    fi
                    _in_think_block=0
                    _can_think=0
                    _response_pending=""
                    if [ -n "$_after_think" ]; then
                        printf "%s" "$_after_think"
                        _gen_tty "$_after_think"
                    fi
                elif [ ${#_response_pending} -ge $_think_detect_limit ]; then
                    # No <think> found in preamble buffer — flush and disable
                    [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf " [debug] generate(llamacpp): no <think> in %d chars, flushing\n" "$_think_detect_limit" > "$_tty" 2>/dev/null
                    _response_pending="${_response_pending//<\/think>/}"
                    printf "%s" "$_response_pending"
                    _gen_tty "$_response_pending"
                    _response_pending=""
                    _can_think=0
                fi
                continue
            fi

            # Phase 2: Inside think block — look for </think>
            if [ "$_in_think_block" -eq 1 ]; then
                _think_pending+="$token"
                _llm_normalize_think _think_pending
                if [[ "$_think_pending" == *"</think>"* ]]; then
                    local _think_before="${_think_pending%%</think>*}"
                    local _after_think="${_think_pending#*</think>}"
                    _after_think="${_after_think//<\/think>/}"
                    _llm_think_show "$_think_before" "$_tty"
                    _think_banner_open=0
                    _llm_think_close "$_tty"
                    _in_think_block=0
                    _think_pending=""
                    [ -n "$_after_think" ] && printf "%s" "$_after_think"
                    [ -n "$_after_think" ] && _gen_tty "$_after_think"
                    continue
                fi
                # Flush safe prefix, keep 7-char tail for split </think> detection
                local _plen=${#_think_pending}
                if [ "$_plen" -gt 7 ]; then
                    local _flen=$((_plen - 7))
                    local _ftxt="${_think_pending:0:_flen}"
                    _think_pending="${_think_pending:_flen}"
                    _llm_think_show "$_ftxt" "$_tty"
                fi
                continue
            fi

            # Phase 3: Normal response token (after </think> or non-thinking model)
            # Strip orphan </think> tags
            token="${token//<\/think>/}"
            # Check for late <think> re-entry
            if [[ "$token" == *"<think>"* ]]; then
                local _before_late="${token%%<think>*}"
                [ -n "$_before_late" ] && printf "%s" "$_before_late"
                [ -n "$_before_late" ] && _gen_tty "$_before_late"
                _in_think_block=1
                _can_think=1
                _think_pending="${token#*<think>}"
                _think_banner_open=1
                _llm_think_open "$_tty"
                continue
            fi
            [ -n "$token" ] && printf "%s" "$token"
            [ -n "$token" ] && _gen_tty "$token"
        done
        }  # end _llm_gen_sse_loop

        if [ "$_use_fifo" -eq 1 ]; then
            _llm_gen_sse_loop < "$_fifo"
            # Kill curl immediately — closes the TCP connection so llama-server
            # aborts the inference slot instead of computing tokens nobody reads.
            kill "$_bg_curl" 2>/dev/null
            wait "$_bg_curl" 2>/dev/null 2>&1 || true
            _LLM_CURL_PID=""
            rm -f "$_fifo" "$_curl_pid_file"
        else
            # Pipe mode: curl terminates via SIGPIPE when loop exits.
            $timeout_cmd curl -sN --connect-timeout 10 --max-time "$curl_timeout" \
                "$LLAMA_CPP_URL/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "$payload" 2>/dev/null | _llm_gen_sse_loop
        fi

        _LLM_ACTIVE=0
        if [ ! -f "$_got_tokens" ]; then
            rm -f "$_got_tokens"
            echo "ERROR: LLM request failed or returned no tokens (llamacpp)"
            _llm_think_log_end
            return 1
        fi
        rm -f "$_got_tokens"
        _llm_think_log_end
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

    local _effective_nothink="${LODGE_NOTHINK:-0}"
    case "${LLM_SCENARIO:-}" in
        strategist|evaluator|ask) _effective_nothink=0 ;;
    esac

    # Inject budget_tokens at top level (Ollama ignores it inside options)
    local _inject_budget="${budget:-0}"
    if [ "$_effective_nothink" -eq 1 ] && models_has_thinking "$LODGE_MODEL" 2>/dev/null; then
        _inject_budget=1
    fi
    if [ "$_inject_budget" -gt 0 ]; then
        payload=$(echo "$payload" | jq --argjson bt "$_inject_budget" '. + {budget_tokens: $bt}')
    fi

    # Inject think:true for models with native thinking template support
    # Required for granite4-preview (Ollama .thinking field), improves Qwen3 (separate field vs inline tags)
    # NOT sent to system-prompt thinkers (Ministral) — causes Ollama to malform response stream
    if [ "$_effective_nothink" -eq 0 ] && models_supports_think_flag "$LODGE_MODEL" 2>/dev/null; then
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

    local _tty; [ -t 2 ] && (true >/dev/tty) 2>/dev/null && _tty="/dev/tty" || _tty="/dev/null"

    # Marker file: touched inside the pipe subshell when first token
    # arrives. If missing after the pipe, the request failed entirely.
    local _tmpdir="${TMPDIR:-/tmp}"
    local _got_tokens="$_tmpdir/.lodge-gen-tok-$RANDOM-$BASHPID"
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
    local _think_detect_limit=4000

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
            if [ "$_think_banner_open" -eq 0 ]; then
                _think_banner_open=1
                _llm_think_open "$_tty"
            fi
            _llm_think_show "$think_token" "$_tty"
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
                    _llm_think_close "$_tty"
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
                        _think_banner_open=1
                        _llm_think_open "$_tty"
                    elif [[ "$_response_pending" == *"</think>"* ]]; then
                        # Implicit start of think block at character 0, ending now
                        local _think_before="${_response_pending%%</think>*}"
                        local _after_think="${_response_pending#*</think>}"
                        _after_think="${_after_think//<\/think>/}"
                        if [ "$_can_think" -eq 1 ]; then
                            _llm_think_open "$_tty"
                            _llm_think_show "$_think_before" "$_tty"
                            _llm_think_close "$_tty"
                        fi
                        _in_think_block=0
                        _can_think=0
                        _response_pending=""
                        if [ -n "$_after_think" ]; then
                            printf "%s" "$_after_think"
                            _gen_tty "$_after_think"
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
                        _llm_think_show "$_think_before" "$_tty"
                        _think_banner_open=0
                        _llm_think_close "$_tty"
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
                        _llm_think_show "$_ftxt" "$_tty"
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
                    _think_banner_open=1
                    _llm_think_open "$_tty"
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
                _llm_think_close "$_tty"
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
        _llm_think_log_end
        return 1
    fi
    rm -f "$_got_tokens"
    _llm_think_log_end
}

# ── Generate with streaming (live output) ──────────────────────
# Usage: llm_stream "prompt" [system_prompt] [max_tokens] [budget_tokens]
llm_stream() {
    local prompt="$1"
    local system="${2:-}"
    local max_tokens="${3:-$LLM_MAX_TOKENS}"
    local budget="${4:-$LLM_BUDGET_TOKENS}"
    budget=$(_llm_resolve_think_budget "$budget")
    local payload
    local full_response=""

    # Log injected prompt to active transcript if configured
    if declare -f transcript_log_prompt &>/dev/null; then
        echo "  [debug] llm_stream: logging prompt role=${LLM_PROMPT_ROLE:-llm} file=$_PROMPT_LOG_FILE" 2>/dev/null >/dev/tty
        transcript_log_prompt "${LLM_PROMPT_ROLE:-llm}" "$prompt" "$system"
    else
        echo "  [debug] llm_stream: transcript_log_prompt function is NOT defined!" 2>/dev/null >/dev/tty
    fi

    # ── Provider harness intercept ─────────────────────────────
    # Route through cloud provider with real-time SSE streaming.
    # Tokens appear on tty as they arrive, with thinking-block display.
    if [ -n "${GEORGE_PROVIDER:-}" ] && declare -f _provider_stream_with_backoff &>/dev/null; then
        _llm_debug_start_timer
        printf "\r\033[K" 2>/dev/null >/dev/tty
        local _provider_resp
        _provider_resp=$(_provider_stream_with_backoff "$GEORGE_PROVIDER" "$prompt" "" "$system")
        local _rc=$?
        if [ $_rc -eq 0 ] && [ -n "$_provider_resp" ]; then
            echo "$_provider_resp"
            _llm_debug_end_timer "provider/$GEORGE_PROVIDER"
            return 0
        fi
        return $_rc
    fi

    # Detect active backend
    local _active_backend
    _active_backend=$(_llm_detect_backend)

    # Thinking model 4x multiplier (see llm_generate for rationale)
    max_tokens=$(_llm_apply_thinking_multiplier "$max_tokens")

    # Cap max_tokens to prevent llama-server context limit failures
    if [ "$_active_backend" = "llamacpp" ]; then
        local approx_prompt_tokens=$(( ( ${#prompt} + ${#system} ) / 3 ))
        local max_possible_output=$(( LLAMA_CPP_CTX_SIZE - approx_prompt_tokens - 32 ))
        if [ "$max_possible_output" -lt 16 ]; then
            max_possible_output=16
        fi
        if [ "$max_tokens" -gt "$max_possible_output" ]; then
            max_tokens=$max_possible_output
        fi
    fi

    _llm_debug_start_timer

    # Optimize system prompt for KV cache reuse in llama-server
    if [ "$_active_backend" = "llamacpp" ] && [ "${LLAMA_CPP_PROMPT_CACHE:-1}" = "1" ] && [ -n "$system" ]; then
        if [[ "$system" == *"[Current time:"* ]]; then
            local _time_line
            _time_line=$(echo "$system" | grep -o '^\[Current time: [^]]*\]' | head -1)
            if [ -n "$_time_line" ]; then
                system=$(echo "$system" | grep -F -v "$_time_line")
                prompt="${_time_line}
${prompt}"
            fi
        fi
        if [[ "$system" == *"[Vitals:"* ]]; then
            local _vitals_line
            _vitals_line=$(echo "$system" | grep -o '^\[Vitals: [^]]*\]' | head -1)
            if [ -n "$_vitals_line" ]; then
                system=$(echo "$system" | grep -F -v "$_vitals_line")
                prompt="${_vitals_line}
${prompt}"
            fi
        fi
    fi

    # Ensure correct model is loaded for this scenario
    if ! models_ensure_for_scenario "${LLM_SCENARIO:-}"; then
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] model switch failed, proceeding with current model"
    fi

    # ── Identity fallback (llamacpp only) ──────────────────────
    # (see llm_generate for rationale — uses cached .system file)
    if [ -z "$system" ] && [ "$_active_backend" = "llamacpp" ] \
       && declare -f models_default_system &>/dev/null; then
        if [ -z "${_LLM_DEFAULT_SYSTEM_CACHE:-}" ] || [ "${_LLM_DEFAULT_SYSTEM_MODEL:-}" != "$LODGE_MODEL" ]; then
            _LLM_DEFAULT_SYSTEM_CACHE=$(models_default_system 2>/dev/null)
            _LLM_DEFAULT_SYSTEM_MODEL="$LODGE_MODEL"
        fi
        system="$_LLM_DEFAULT_SYSTEM_CACHE"
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && [ -n "$system" ] && ui_dim "  [debug] inject: ${_ME_KEY:-default}.system identity (${#system} chars, cached)"
    fi

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

    # Capture thinking tokens dynamically for the transcript
    local _think_log_file=""
    _llm_think_log_start

    # Build options with per-scenario sampling parameters
    local _opts
    _opts=$(_llm_build_opts "$max_tokens")

    # ── llama.cpp streaming path ───────────────────────────────
    # SSE-based streaming to tty. No thinking API — all output is
    # content tokens. Uses spinner for prefill wait.
    # curl runs in background writing to a FIFO so we can track its
    # PID and kill it on break/cancel — otherwise the TCP connection
    # stays open and llama-server keeps computing (phone stays hot).
    if [ "$_active_backend" = "llamacpp" ]; then
        local _stop=""
        if declare -f models_info &>/dev/null; then
            local _ME_STOP=""
            models_info "$LODGE_MODEL" 2>/dev/null && _stop="$_ME_STOP"
        fi
        payload=$(_llm_build_llamacpp_payload "$prompt" "$system" "$_opts" "$max_tokens" true "" "$_stop")

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
        (true >/dev/tty) 2>/dev/null || _tty="/dev/null"

        local _dbg_out=0
        local _dbg_in=0

        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf "\n [debug] stream (llamacpp): url=%s max_tokens=%s\n" "$LLAMA_CPP_URL" "$max_tokens" > "$_tty" 2>/dev/null

        # ── Think-tag state machine for llamacpp streaming ───────
        # Reuses the same per-token inline-tag parsing infrastructure
        # developed for Ollama. llama-server has no .thinking field so
        # we are always in inline-tag fallback mode.
        local _think_banner_open=0
        local _in_think_block=0
        local _can_think=0
        models_current_has_thinking && _can_think=1
        local _think_pending=""
        local _response_pending=""
        local _think_detect_limit=4000

        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf " [debug] stream(llamacpp) think: _can_think=%s model=%s LODGE_THINK=%s\n" "$_can_think" "$LODGE_MODEL" "${LODGE_THINK:-0}" > "$_tty" 2>/dev/null

        # FIFO for curl → read loop decoupling (enables PID tracking)
        # On iSH (iOS QEMU) FIFOs deadlock — fall back to a plain pipe.
        local _fifo="$_tmpdir/.lodge-fifo-stream-$$"
        local _use_fifo=1
        if ! _llm_is_fifo_safe; then
            _use_fifo=0
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf " [debug] stream(llamacpp): FIFO bypass (platform=%s)\n" "${LODGE_PLATFORM:-}" > "$_tty" 2>/dev/null
        elif ! (rm -f "$_fifo" && mkfifo "$_fifo") 2>/dev/null; then
            _use_fifo=0
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf " [debug] stream(llamacpp): mkfifo failed, falling back to pipe\n" > "$_tty" 2>/dev/null
        fi

        if [ "$_use_fifo" -eq 1 ]; then
            $timeout_cmd curl -sN --connect-timeout 10 --max-time "$curl_timeout" \
                "$LLAMA_CPP_URL/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "$payload" > "$_fifo" 2>/dev/null &
            local _bg_curl=$!
            _LLM_CURL_PID="$_bg_curl"
        fi

        # _llm_stream_sse_loop: shared read loop body so the same token-processing
        # code runs in both FIFO and pipe modes. In pipe mode the loop runs in a
        # subshell — variable updates (_dbg_out etc.) are lost (acceptable).
        _llm_stream_sse_loop() {
        while IFS= read -r line; do
            [ -f "$_cancel_file" ] && break

            [[ "$line" == data:* ]] || continue
            local json="${line#data: }"

            # Stream termination — flush buffers and break
            if [ "$json" = "[DONE]" ]; then
                # Close thinking banner if still open
                if [ "$_think_banner_open" -eq 1 ]; then
                    _llm_think_close "$_tty"
                fi
                # Flush response_pending buffer (short response, <think> never arrived)
                if [ -n "$_response_pending" ]; then
                    _llm_normalize_think _response_pending
                    _response_pending="${_response_pending//<\/think>/}"
                    _response_pending="${_response_pending//<think>/}"
                    [ -n "$_response_pending" ] && printf "%s" "$_response_pending"
                    [ -n "$_response_pending" ] && printf "%s" "$_response_pending" > "$_tty" 2>/dev/null
                fi
                # Flush pending think text as response if </think> never arrived
                if [ "$_in_think_block" -eq 1 ] && [ -n "$_think_pending" ]; then
                    _llm_normalize_think _think_pending
                    _think_pending="${_think_pending//<\/think>/}"
                    [ -n "$_think_pending" ] && printf "%s" "$_think_pending"
                    [ -n "$_think_pending" ] && printf "%s" "$_think_pending" > "$_tty" 2>/dev/null
                fi
                if [ "${LODGE_DEBUG:-0}" -eq 1 ]; then
                    _llm_debug_end_timer "stream(llamacpp)" "$_dbg_in" "$_dbg_out"
                fi
                echo ""
                echo "" > "$_tty" 2>/dev/null
                break
            fi

            local token=""
            if [[ "$json" =~ \"content\":\"(([^\"]|\\\")*)\" ]]; then
                token="${BASH_REMATCH[1]}"
                token="${token//\\n/$'\n'}"
                token="${token//\\t/$'\t'}"
                token="${token//\\\"/\"}"
                token="${token//\\\\/\\}"
            fi

            # ── reasoning_content support (llama-server ≥ b4000) ──
            # Same as llm_generate path — llama-server puts thinking
            # in a separate field when the template supports <think>.
            local _rc=""
            if [[ "$json" =~ \"reasoning_content\":\"(([^\"]|\\\")*)\" ]]; then
                _rc="${BASH_REMATCH[1]}"
                _rc="${_rc//\\n/$'\n'}"
                _rc="${_rc//\\t/$'\t'}"
                _rc="${_rc//\\\"/\"}"
                _rc="${_rc//\\\\/\\}"
            fi
            if [ -n "$_rc" ]; then
                # Kill spinner on first think token
                if [ ! -f "$_llm_ft_file" ]; then
                    touch "$_llm_ft_file"
                    kill "$_llm_spinner_pid" 2>/dev/null
                    printf "\r%*s\r" 60 "" > "$_tty" 2>/dev/null
                fi
                _dbg_out=$((_dbg_out + 1))
                if [ "$_think_banner_open" -eq 0 ] && [ "$_can_think" -eq 1 ]; then
                    _think_banner_open=1
                    _in_think_block=1
                    _llm_think_open "$_tty"
                fi
                _llm_think_show "$_rc" "$_tty"
                _response_pending=""
                continue
            fi
            # Close think banner when switching from reasoning to content
            if [ "$_in_think_block" -eq 1 ] && [ -n "$token" ] && [ "$_think_banner_open" -eq 1 ]; then
                _think_banner_open=0
                _in_think_block=0
                _llm_think_close "$_tty"
                _response_pending=""
                _can_think=0  # disable inline detection — server handles it
            fi

            # ── Capture usage stats from SSE chunks ──────────────
            # llama-server emits usage in the final content chunk
            # (with finish_reason) when stream_options.include_usage
            # is set. Capture on every line; last value wins.
            local _usage_pt=""
            if [[ "$json" =~ \"prompt_tokens\":([0-9]+) ]]; then
                _usage_pt="${BASH_REMATCH[1]}"
                [ -n "$_usage_pt" ] && _dbg_in="$_usage_pt"
            fi
            [ -n "$token" ] || continue

            # Kill spinner on first token
            if [ ! -f "$_llm_ft_file" ]; then
                touch "$_llm_ft_file"
                kill "$_llm_spinner_pid" 2>/dev/null
                printf "\r%*s\r" 60 "" > "$_tty" 2>/dev/null
            fi

            _dbg_out=$((_dbg_out + 1))

            # Strip <response>...</response> wrapper tags (Granite4 format)
            token="${token//<response>/}"
            token="${token//<\/response>/}"

            # Normalize bracket think tags → <think>/</think>
            _llm_normalize_think token

            # ── Inline-tag state machine (mirrors Ollama path) ─────
            # Phase 1: Preamble buffering — detect <think> in early tokens
             if [ "$_can_think" -eq 1 ] && [ "$_in_think_block" -eq 0 ]; then
                 _response_pending+="$token"
                 _llm_normalize_think _response_pending
                 if [[ "$_response_pending" == *"<think>"* ]]; then
                     _in_think_block=1
                     _think_pending="${_response_pending#*<think>}"
                     [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf " [debug] stream(llamacpp): <think> detected inline (at %d chars)\n" "${#_response_pending}" > "$_tty" 2>/dev/null
                     # Output anything before <think> as response (preamble)
                     local _before="${_response_pending%%<think>*}"
                     _before="${_before//<\/think>/}"
                     if [ -n "$_before" ]; then
                         printf "%s" "$_before"
                         printf "%s" "$_before" > "$_tty" 2>/dev/null
                     fi
                     _response_pending=""
                     _think_banner_open=1
                     _llm_think_open "$_tty"
                 elif [[ "$_response_pending" == *"</think>"* ]]; then
                     # Implicit start of think block at character 0, ending now
                     local _think_before="${_response_pending%%</think>*}"
                     local _after_think="${_response_pending#*</think>}"
                     _after_think="${_after_think//<\/think>/}"
                     if [ "$_can_think" -eq 1 ]; then
                         _llm_think_open "$_tty"
                         _llm_think_show "$_think_before" "$_tty"
                         _llm_think_close "$_tty"
                     fi
                     _in_think_block=0
                     _can_think=0
                     _response_pending=""
                     if [ -n "$_after_think" ]; then
                         printf "%s" "$_after_think"
                         printf "%s" "$_after_think" > "$_tty" 2>/dev/null
                     fi
                 elif [ ${#_response_pending} -ge $_think_detect_limit ]; then
                     # No <think> found in preamble buffer — flush and disable
                     [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf " [debug] stream(llamacpp): no <think> in %d chars, flushing\n" "$_think_detect_limit" > "$_tty" 2>/dev/null
                     _response_pending="${_response_pending//<\/think>/}"
                     printf "%s" "$_response_pending"
                     printf "%s" "$_response_pending" > "$_tty" 2>/dev/null
                     _response_pending=""
                     _can_think=0
                 fi
                 continue
             fi

            # Phase 2: Inside think block — look for </think>
            if [ "$_in_think_block" -eq 1 ]; then
                _think_pending+="$token"
                _llm_normalize_think _think_pending
                if [[ "$_think_pending" == *"</think>"* ]]; then
                    local _think_before="${_think_pending%%</think>*}"
                    local _after_think="${_think_pending#*</think>}"
                    _after_think="${_after_think//<\/think>/}"
                    _llm_think_show "$_think_before" "$_tty"
                    _think_banner_open=0
                    _llm_think_close "$_tty"
                    _in_think_block=0
                    _think_pending=""
                    if [ -n "$_after_think" ]; then
                        printf "%s" "$_after_think"
                        printf "%s" "$_after_think" > "$_tty" 2>/dev/null
                    fi
                    continue
                fi
                # Flush safe prefix, keep 7-char tail for split </think> detection
                local _plen=${#_think_pending}
                if [ "$_plen" -gt 7 ]; then
                    local _flen=$((_plen - 7))
                    local _ftxt="${_think_pending:0:_flen}"
                    _think_pending="${_think_pending:_flen}"
                    _llm_think_show "$_ftxt" "$_tty"
                fi
                continue
            fi

            # Phase 3: Normal response token (after </think> or non-thinking model)
            # Strip orphan </think> tags
            token="${token//<\/think>/}"
            # Check for late <think> re-entry
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
                _llm_think_open "$_tty"
                continue
            fi
            [ -n "$token" ] && printf "%s" "$token"
            [ -n "$token" ] && printf "%s" "$token" > "$_tty" 2>/dev/null
        done
        }  # end _llm_stream_sse_loop

        if [ "$_use_fifo" -eq 1 ]; then
            _llm_stream_sse_loop < "$_fifo"
            # Kill curl → closes TCP → llama-server aborts inference slot
            kill "$_bg_curl" 2>/dev/null
            wait "$_bg_curl" 2>/dev/null 2>&1 || true
            _LLM_CURL_PID=""
            rm -f "$_fifo"
        else
            # Pipe mode: curl terminates via SIGPIPE when loop exits.
            $timeout_cmd curl -sN --connect-timeout 10 --max-time "$curl_timeout" \
                "$LLAMA_CPP_URL/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "$payload" 2>/dev/null | _llm_stream_sse_loop
        fi

        ui_spinner_stop
        rm -f "$_llm_ft_file"
        _LLM_ACTIVE=0

        if [ -f "$_cancel_file" ]; then
            _llm_think_log_end
            return 1
        fi
        _llm_think_log_end
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

    local _effective_nothink="${LODGE_NOTHINK:-0}"
    case "${LLM_SCENARIO:-}" in
        strategist|evaluator|ask) _effective_nothink=0 ;;
    esac

    # Inject budget_tokens at top level (Ollama ignores it inside options)
    local _inject_budget="${budget:-0}"
    if [ "$_effective_nothink" -eq 1 ] && models_has_thinking "$LODGE_MODEL" 2>/dev/null; then
        _inject_budget=1
    fi
    if [ "$_inject_budget" -gt 0 ]; then
        payload=$(echo "$payload" | jq --argjson bt "$_inject_budget" '. + {budget_tokens: $bt}')
    fi

    # Inject think:true for models with native thinking template support
    # NOT sent to system-prompt thinkers (Ministral)
    if [ "$_effective_nothink" -eq 0 ] && models_supports_think_flag "$LODGE_MODEL" 2>/dev/null; then
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
    (true >/dev/tty) 2>/dev/null || _tty="/dev/null"

    # ── Think display helpers ─────────────────────────────────────
    # Both modes get the same ┌─ thinking ─ / └──────────── structure.
    # Bright (2) = cyan, Dimmed (1) = gray (SGR 90, widely supported).
    # Delegate to top-level _llm_think_* functions (shared with llamacpp).
    _think_color() { _llm_think_color; }
    _think_open() { _llm_think_open; }
    _think_close() { _llm_think_close; }
    _think_show() { _llm_think_show "$@"; }

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
    local _think_detect_limit=4000

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
                    elif [[ "$_response_pending" == *"</think>"* ]]; then
                        # Implicit start of think block at character 0, ending now
                        local _think_before="${_response_pending%%</think>*}"
                        local _after_think="${_response_pending#*</think>}"
                        _after_think="${_after_think//<\/think>/}"
                        if [ "$_can_think" -eq 1 ]; then
                            _think_open
                            _think_show "$_think_before"
                            _think_close
                        fi
                        _in_think_block=0
                        _can_think=0
                        _response_pending=""
                        if [ -n "$_after_think" ]; then
                            printf "%s" "$_after_think"
                            printf "%s" "$_after_think" > "$_tty" 2>/dev/null
                        fi
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
        _llm_think_log_end
        return 1
    fi

    rm -f "$_llm_ft_file"
    _LLM_ACTIVE=0

    _llm_think_log_end
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
    budget=$(_llm_resolve_think_budget "$budget")
    local payload

    # ── Provider harness intercept ─────────────────────────────
    # Extract the last user message and route through the provider.
    if [ -n "${GEORGE_PROVIDER:-}" ] && declare -f _provider_call_with_backoff &>/dev/null; then
        local _last_msg
        _last_msg=$(echo "$messages" | jq -r '[.[] | select(.role == "user")] | last | .content // empty' 2>/dev/null)
        if [ -n "$_last_msg" ]; then
            ui_spinner_start "$GEORGE_PROVIDER" 2>/dev/null >/dev/tty
            local _provider_resp
            _provider_resp=$(_provider_call_with_backoff "$GEORGE_PROVIDER" "$_last_msg" "" "$system")
            local _rc=$?
            ui_spinner_stop 2>/dev/null
            if [ $_rc -eq 0 ] && [ -n "$_provider_resp" ]; then
                echo "$_provider_resp"
                return 0
            fi
            return $_rc
        fi
    fi

    # Detect active backend
    local _active_backend
    _active_backend=$(_llm_detect_backend)

    # Ensure correct model is loaded for this scenario
    if ! models_ensure_for_scenario "${LLM_SCENARIO:-}"; then
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] model switch failed, proceeding with current model"
    fi

    # ── Identity fallback (llamacpp only) ──────────────────────
    # (see llm_generate for rationale — uses cached .system file)
    if [ -z "$system" ] && [ "$_active_backend" = "llamacpp" ] \
       && declare -f models_default_system &>/dev/null; then
        if [ -z "${_LLM_DEFAULT_SYSTEM_CACHE:-}" ] || [ "${_LLM_DEFAULT_SYSTEM_MODEL:-}" != "$LODGE_MODEL" ]; then
            _LLM_DEFAULT_SYSTEM_CACHE=$(models_default_system 2>/dev/null)
            _LLM_DEFAULT_SYSTEM_MODEL="$LODGE_MODEL"
        fi
        system="$_LLM_DEFAULT_SYSTEM_CACHE"
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && [ -n "$system" ] && ui_dim "  [debug] inject: ${_ME_KEY:-default}.system identity (${#system} chars, cached)"
    fi

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

    # Thinking model 4x multiplier for chat (see llm_generate for rationale)
    if models_current_has_thinking 2>/dev/null; then
        local _chat_np
        _chat_np=$(echo "$_opts" | jq -r '.num_predict // 4096')
        _opts=$(echo "$_opts" | jq --argjson np $(( _chat_np * 4 )) '.num_predict = $np')
    fi

    # ── llama.cpp chat path ────────────────────────────────────
    # Cleanest backend translation — llama-server natively uses
    # OpenAI messages format. No payload wrapping needed.
    if [ "$_active_backend" = "llamacpp" ]; then
        # Extract all sampling params in a single jq call (7→1).
        local temp rep_raw pres max_tok freq top_p top_k min_p
        read -r temp rep_raw pres max_tok top_p top_k min_p <<< "$(echo "$_opts" | jq -r '[.temperature // 0.7, .repeat_penalty // 1.2, .presence_penalty // 0.3, .num_predict // 4096, .top_p // 1.0, .top_k // 40, .min_p // 0.0] | @tsv')"

        # Convert Ollama repeat_penalty → OpenAI frequency_penalty
        freq=$(_llm_repeat_to_freq "$rep_raw")

        # Build messages with system prompt prepended
        local full_messages
        if [ -n "$system" ]; then
            full_messages=$(echo "$messages" | jq --arg sys "$system" \
                '[{role:"system",content:$sys}] + .')
        else
            full_messages="$messages"
        fi

        # top_p is standard OpenAI; top_k and min_p are llama-server extensions
        payload=$(jq -n \
            --argjson messages "$full_messages" \
            --argjson max_tokens "$max_tok" \
            --argjson temperature "$temp" \
            --argjson frequency_penalty "$freq" \
            --argjson presence_penalty "$pres" \
            --argjson top_p "$top_p" \
            --argjson top_k "$top_k" \
            --argjson min_p "$min_p" \
            '{messages:$messages, max_tokens:$max_tokens, temperature:$temperature, frequency_penalty:$frequency_penalty, presence_penalty:$presence_penalty, top_p:$top_p, top_k:$top_k, min_p:$min_p, stream:true}')

        local curl_timeout="${LLM_TIMEOUT:-600}"
        local timeout_cmd=""
        if [ "$curl_timeout" -gt 0 ] 2>/dev/null; then
            command -v timeout &>/dev/null && timeout_cmd="timeout $curl_timeout"
        fi

        _LLM_ACTIVE=1
        local _tmpdir="${TMPDIR:-/tmp}"
        local _got_tokens="$_tmpdir/.lodge-chat-tok-$RANDOM-$BASHPID"
        rm -f "$_got_tokens"

        # FIFO for curl → read loop decoupling (enables PID tracking)
        # On iSH (iOS QEMU) FIFOs deadlock — fall back to a plain pipe.
        local _fifo="$_tmpdir/.lodge-fifo-chat-$$"
        local _use_fifo=1
        if ! _llm_is_fifo_safe; then
            _use_fifo=0
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf " [debug] chat(llamacpp): FIFO bypass (platform=%s)\n" "${LODGE_PLATFORM:-}" > /dev/stderr 2>/dev/null
        elif ! (rm -f "$_fifo" && mkfifo "$_fifo") 2>/dev/null; then
            _use_fifo=0
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf " [debug] chat(llamacpp): mkfifo failed, falling back to pipe\n" > /dev/stderr 2>/dev/null
        fi

        if [ "$_use_fifo" -eq 1 ]; then
            $timeout_cmd curl -sN --connect-timeout 10 --max-time "$curl_timeout" \
                "$LLAMA_CPP_URL/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "$payload" > "$_fifo" 2>/dev/null &
            local _bg_curl=$!
            _LLM_CURL_PID="$_bg_curl"
        fi

        _llm_chat_sse_loop() {
        while IFS= read -r line; do

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
        }  # end _llm_chat_sse_loop

        if [ "$_use_fifo" -eq 1 ]; then
            _llm_chat_sse_loop < "$_fifo"
            # Kill curl → closes TCP → server aborts inference
            kill "$_bg_curl" 2>/dev/null
            wait "$_bg_curl" 2>/dev/null 2>&1 || true
            _LLM_CURL_PID=""
            rm -f "$_fifo"
        else
            # Pipe mode: curl terminates via SIGPIPE when loop exits.
            $timeout_cmd curl -sN --connect-timeout 10 --max-time "$curl_timeout" \
                "$LLAMA_CPP_URL/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "$payload" 2>/dev/null | _llm_chat_sse_loop
        fi

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

    local _effective_nothink="${LODGE_NOTHINK:-0}"
    case "${LLM_SCENARIO:-}" in
        strategist|evaluator|ask) _effective_nothink=0 ;;
    esac

    # Inject budget_tokens at top level (Ollama ignores it inside options)
    local _inject_budget="${budget:-0}"
    if [ "$_effective_nothink" -eq 1 ] && models_has_thinking "$LODGE_MODEL" 2>/dev/null; then
        _inject_budget=1
    fi
    if [ "$_inject_budget" -gt 0 ]; then
        payload=$(echo "$payload" | jq --argjson bt "$_inject_budget" '. + {budget_tokens: $bt}')
    fi

    # Inject think:true for models with native thinking template support
    # NOT sent to system-prompt thinkers (Ministral)
    if [ "$_effective_nothink" -eq 0 ] && models_supports_think_flag "$LODGE_MODEL" 2>/dev/null; then
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
    local _got_tokens="$_tmpdir/.lodge-chat-tok-$RANDOM-$BASHPID"
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

    if ! models_ensure_for_scenario "${LLM_SCENARIO:-}"; then
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] model switch failed, proceeding with current model"
    fi

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
        local temp max_tok top_p top_k min_p
        temp=$(echo "$_opts" | jq -r '.temperature // 0.7')
        max_tok=$(echo "$_opts" | jq -r '.num_predict // 4096')
        top_p=$(echo "$_opts" | jq -r '.top_p // 1.0')
        top_k=$(echo "$_opts" | jq -r '.top_k // 40')
        min_p=$(echo "$_opts" | jq -r '.min_p // 0.0')

        # Detect MIME type
        local mime_type="image/jpeg"
        case "$image_path" in
            *.png)  mime_type="image/png" ;;
            *.gif)  mime_type="image/gif" ;;
            *.webp) mime_type="image/webp" ;;
        esac

        # Ensure the prompt contains <image> placeholder for llama.cpp multimodal models
        local _effective_prompt="$prompt"
        if [[ "$_effective_prompt" != *"<image>"* ]]; then
            _effective_prompt="<image>\n$_effective_prompt"
        fi

        # Build multimodal messages payload directly to avoid command line limits
        payload=$(printf '%s' "$img_base64" | jq -R -s \
            --arg sys "${system:-}" \
            --arg prompt "$_effective_prompt" \
            --arg mime "$mime_type" \
            --argjson max_tokens "$max_tok" \
            --argjson temperature "$temp" \
            --argjson top_p "$top_p" \
            --argjson top_k "$top_k" \
            --argjson min_p "$min_p" \
            '
            ("data:" + $mime + ";base64," + .) as $img_url |
            [{type: "text", text: $prompt}, {type: "image_url", image_url: {url: $img_url}}] as $user_content |
            (if $sys != "" then
                [{role: "system", content: $sys}, {role: "user", content: $user_content}]
             else
                [{role: "user", content: $user_content}]
             end) as $messages |
            {messages: $messages, max_tokens: $max_tokens, temperature: $temperature, top_p: $top_p, top_k: $top_k, min_p: $min_p, stream: true}
            ')

        local curl_timeout="${LLM_TIMEOUT:-600}"
        local timeout_cmd=""
        if [ "$curl_timeout" -gt 0 ] 2>/dev/null; then
            command -v timeout &>/dev/null && timeout_cmd="timeout $curl_timeout"
        fi

        _LLM_ACTIVE=1
        local _tty="/dev/tty"
        (true >/dev/tty) 2>/dev/null || _tty="/dev/null"
        local _got_tokens="$_tmpdir/.lodge-vision-tok-$RANDOM-$BASHPID"
        rm -f "$_got_tokens"

        ui_spinner_start "Analyzing image"
        local _spinner_pid="$_SPINNER_PID"
        local _first_token=0

        printf '%s' "$payload" | $timeout_cmd curl -sN --connect-timeout 10 --max-time "$curl_timeout" \
            "$LLAMA_CPP_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d @- 2>/tmp/lodge-vision-curl.err | while IFS= read -r line; do

            [[ "$line" == data:* ]] || continue
            local json="${line#data: }"
            if [ "$json" = "[DONE]" ]; then
                echo ""
                break
            fi
            local token _rc
            token=$(echo "$json" | jq -r '.choices[0].delta.content // empty' 2>/dev/null)
            _rc=$(echo "$json" | jq -r '.choices[0].delta.reasoning_content // empty' 2>/dev/null)
            if [ -n "$token" ] || [ -n "$_rc" ]; then
                if [ "$_first_token" -eq 0 ]; then
                    _first_token=1
                    touch "$_got_tokens"
                    kill "$_spinner_pid" 2>/dev/null; wait "$_spinner_pid" 2>/dev/null
                    printf "\r%*s\r" 60 "" > "$_tty" 2>/dev/null
                fi
                [ -n "$_rc" ] && printf "%s" "$_rc"
                [ -n "$token" ] && printf "%s" "$token"
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

    payload=$(printf '%s' "$img_base64" | jq -R -s \
        --arg model "$LODGE_MODEL" \
        --arg prompt "$prompt" \
        --arg sys "${system:-}" \
        --arg keep_alive "$LLM_KEEP_ALIVE" \
        --argjson options "$_opts" \
        '
        {
          model: $model,
          prompt: $prompt,
          images: [ . ],
          stream: true,
          keep_alive: $keep_alive,
          options: $options
        } + (if $sys != "" then {system: $sys} else {} end)
        ')

    local curl_timeout="${LLM_TIMEOUT:-600}"
    local timeout_cmd=""
    if [ "$curl_timeout" -gt 0 ] 2>/dev/null; then
        if command -v timeout &>/dev/null; then
            timeout_cmd="timeout $curl_timeout"
        fi
    fi

    _LLM_ACTIVE=1

    local _tty="/dev/tty"
    (true >/dev/tty) 2>/dev/null || _tty="/dev/null"

    local _got_tokens="$_tmpdir/.lodge-vision-tok-$RANDOM-$BASHPID"
    rm -f "$_got_tokens"

    ui_spinner_start "Analyzing image"
    local _spinner_pid="$_SPINNER_PID"
    local _first_token=0

    printf '%s' "$payload" | $timeout_cmd curl -sN --connect-timeout 10 --max-time "$curl_timeout" \
        "$OLLAMA_URL/api/generate" \
        -H "Content-Type: application/json" \
        -d @- 2>/dev/null | while IFS= read -r line; do

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
