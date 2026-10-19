#!/bin/bash
# ── George: model sampling parameters (model-agnostic) ───────────────
# Blue Lodge does not ship a model list. Per-model sampling comes from the operator's own Model Hub
# profile (the one currently activated, or one whose name matches the model id), which the operator
# can edit in the Model Workbench (Serve & Tune) or with /models tune. When no profile applies,
# callers fall back to the global LLM_* defaults in lib/core/llm.sh.
#
# Public API (used by lib/core/llm.sh, lib/tools/native_tools.sh, tests):
#   models_get_param <model_key> <param>   → value on stdout, or return 1 when no profile applies
#   models_apply_defaults [model_key]      → set LLM_* globals (profile values, else generic defaults)
#   models_has_vision [model_key]          → 0 when the active profile/served model has a vision projector
#   models_init [model_key]                → alias for models_apply_defaults

[ -n "${_LIB_MODELS_LOADED:-}" ] && return 0; _LIB_MODELS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"

# Generic, model-neutral fallbacks (close to llama.cpp's own defaults).
MODELS_DEFAULT_TEMPERATURE="${MODELS_DEFAULT_TEMPERATURE:-0.8}"
MODELS_DEFAULT_TOP_P="${MODELS_DEFAULT_TOP_P:-0.95}"
MODELS_DEFAULT_TOP_K="${MODELS_DEFAULT_TOP_K:-40}"
MODELS_DEFAULT_MIN_P="${MODELS_DEFAULT_MIN_P:-0.05}"
MODELS_DEFAULT_REPEAT="${MODELS_DEFAULT_REPEAT:-1.0}"
MODELS_DEFAULT_PRESENCE="${MODELS_DEFAULT_PRESENCE:-0.0}"

_MODELS_CACHE_SRC=""      # raw profile JSON the cache was built from
_MODELS_CACHE_VALS=""     # "temp|top_p|top_k|min_p|repeat|presence|ctx|mmproj"

# Resolve which profile file applies to a model key. Prints its path or returns 1.
_models_profile_file() {
    local key="${1:-}" dir="$GEORGE_DIR/models/profiles" f
    if [[ "$key" =~ ^[a-z0-9][a-z0-9._-]{1,63}$ ]] && [ -f "$dir/$key.json" ]; then
        echo "$dir/$key.json"; return 0
    fi
    if [ -f "$GEORGE_DIR/models/active_profile.json" ]; then
        local raw active
        raw=$(<"$GEORGE_DIR/models/active_profile.json")
        [[ "$raw" =~ \"name\"[[:space:]]*:[[:space:]]*\"([a-z0-9][a-z0-9._-]{1,63})\" ]] && active="${BASH_REMATCH[1]}"
        f="$dir/${active:-_none_}.json"
        [ -n "${active:-}" ] && [ -f "$f" ] && { echo "$f"; return 0; }
    fi
    return 1
}

# Load (and memoise) the sampling block of the applicable profile.
_models_load() {
    local f src
    f=$(_models_profile_file "${1:-}") || return 1
    src=$(<"$f") || return 1
    if [ "$src" != "$_MODELS_CACHE_SRC" ]; then
        _MODELS_CACHE_VALS=$(jq -r '[.sampling.temperature, .sampling.top_p, .sampling.top_k, .sampling.min_p,
                                    .sampling.repeat_penalty, .sampling.presence_penalty, .server.ctx,
                                    ([.files[]? | select(.role=="mmproj")] | length)]
                                   | map(if . == null then "" else tostring end) | join("|")' <<<"$src" 2>/dev/null) || return 1
        _MODELS_CACHE_SRC="$src"
    fi
    return 0
}

# In-shell loader (no subshell): sets MODELS_P_{TEMP,TOP_P,TOP_K,MIN_P,REPEAT,PRESENCE,CTX} (empty = unset
# in the profile). Returns 1 when no profile applies. Used by llm.sh on every request, so it is memoised.
models_load_params() {
    MODELS_P_TEMP="" MODELS_P_TOP_P="" MODELS_P_TOP_K="" MODELS_P_MIN_P="" MODELS_P_REPEAT="" MODELS_P_PRESENCE="" MODELS_P_CTX=""
    _models_load "${1:-}" || return 1
    local _mm
    IFS='|' read -r MODELS_P_TEMP MODELS_P_TOP_P MODELS_P_TOP_K MODELS_P_MIN_P MODELS_P_REPEAT MODELS_P_PRESENCE \
        MODELS_P_CTX _mm <<<"$_MODELS_CACHE_VALS"
    return 0
}

models_get_param() {
    local key="$1" param="$2"
    _models_load "$key" || return 1
    local t p k m r pr ctx mm
    IFS='|' read -r t p k m r pr ctx mm <<<"$_MODELS_CACHE_VALS"
    local v=""
    case "$param" in
        temp|temperature) v="$t" ;;
        top_p) v="$p" ;;
        top_k) v="$k" ;;
        min_p) v="$m" ;;
        repeat|repeat_penalty) v="$r" ;;
        presence|presence_penalty) v="$pr" ;;
        context|num_ctx) v="$ctx" ;;
        *) return 1 ;;
    esac
    [ -n "$v" ] || return 1
    echo "$v"
}

models_apply_defaults() {
    local target="${1:-${LODGE_MODEL:-}}"
    LLM_TEMPERATURE=$(models_get_param "$target" temp) || LLM_TEMPERATURE="$MODELS_DEFAULT_TEMPERATURE"
    LLM_TOP_P=$(models_get_param "$target" top_p) || LLM_TOP_P="$MODELS_DEFAULT_TOP_P"
    LLM_TOP_K=$(models_get_param "$target" top_k) || LLM_TOP_K="$MODELS_DEFAULT_TOP_K"
    LLM_MIN_P=$(models_get_param "$target" min_p) || LLM_MIN_P="$MODELS_DEFAULT_MIN_P"
    LLM_REPEAT_PENALTY=$(models_get_param "$target" repeat) || LLM_REPEAT_PENALTY="$MODELS_DEFAULT_REPEAT"
    LLM_PRESENCE_PENALTY=$(models_get_param "$target" presence) || LLM_PRESENCE_PENALTY="$MODELS_DEFAULT_PRESENCE"

    # Switching models clears per-scenario overrides so the new model's values apply everywhere.
    LLM_TEMP_ASK=""; LLM_REPEAT_ASK=""; LLM_PRESENCE_ASK=""
    LLM_TEMP_AGENT=""; LLM_REPEAT_AGENT=""; LLM_PRESENCE_AGENT=""
    LLM_TEMP_ROUTER=""; LLM_REPEAT_ROUTER=""; LLM_PRESENCE_ROUTER=""
    LLM_TEMP_JOURNAL=""; LLM_REPEAT_JOURNAL=""; LLM_PRESENCE_JOURNAL=""
    LLM_TEMP_TOOL=""; LLM_REPEAT_TOOL=""; LLM_PRESENCE_TOOL=""
    return 0
}

# Vision: the applicable profile pins an mmproj, or the live server reports vision modality.
models_has_vision() {
    local key="${1:-${LODGE_MODEL:-}}"
    if _models_load "$key"; then
        local mm; mm="${_MODELS_CACHE_VALS##*|}"
        [ "${mm:-0}" -gt 0 ] 2>/dev/null && return 0
    fi
    local url="${ACTIVE_ENDPOINT_URL:-${LLAMA_CPP_URL:-}}"
    if [ -n "$url" ] && [ "${MODELS_VISION_PROBE:-1}" = "1" ] && command -v curl >/dev/null 2>&1; then
        curl -sf --connect-timeout 1 --max-time 1.5 "$url/props" 2>/dev/null \
            | jq -e '.modalities.vision == true' >/dev/null 2>&1 && return 0
    fi
    return 1
}

models_init() {
    models_apply_defaults "$@"
}

# _models_switch [model_key] — re-apply sampling after a setting change (/think, /backend, /models spec).
# Server launch flags are owned by the activated Model Hub profile, so this never restarts llama-server
# on its own: it refreshes the in-shell sampling values and tells the operator how to re-serve.
_models_switch() {
    models_apply_defaults "${1:-${LODGE_MODEL:-}}"
    local f name=""
    if f=$(_models_profile_file "${1:-}"); then
        name=$(basename "$f" .json)
    fi
    local msg
    if [ -n "$name" ]; then
        msg="Saved. Server flags apply on the next launch: /models activate $name"
    else
        msg="Saved. Server flags apply on the next llama-server launch (/models activate <profile>)."
    fi
    if declare -f ui_dim &>/dev/null; then ui_dim "  $msg"; else echo "  $msg"; fi
    return 0
}

# ── Scenario Helpers (Model-Agnostic) ──────────────────────────

# Ensure correct model is loaded for this scenario (no-op in model-agnostic workbench)
models_ensure_for_scenario() {
    return 0
}

