#!/bin/bash
# ── George: Model Library & Dual-Model Switching ───────────────
# Manages model selection, per-model configuration, and hot-swapping
# between a primary (thinking/planning) and secondary (code/fast) model.
#
# Architecture:
#   - Each model has a registry entry with its base image, capabilities, and stop token
#   - Per-model Modelfiles are generated at install/select time into models/
#   - Two active model slots: LODGE_MODEL_PRIMARY and LODGE_MODEL_SECONDARY
#   - LLM_SCENARIO determines which model is used per call
#   - Hot-swap: only one model loaded at a time, unload→load on switch
#   - Single-model mode: primary only, no switching overhead
#
# The model registry is the ONLY place model-specific knowledge lives.
# Everything else (llm.sh, agent.sh, etc.) is model-agnostic.

[ -n "${_LIB_MODELS_LOADED:-}" ] && return 0; _LIB_MODELS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"

# ── Model Slots ────────────────────────────────────────────────
# These are the Ollama model names (e.g., "blue-lodge-minist-think:4b")
LODGE_MODEL_PRIMARY="${LODGE_MODEL_PRIMARY:-blue-lodge-minist-inst:4b}"
LODGE_MODEL_SECONDARY="${LODGE_MODEL_SECONDARY:-blue-lodge-minist-inst:4b}"
LODGE_SINGLE_MODEL="${LODGE_SINGLE_MODEL:-1}"   # 1=single model mode (primary only, default), 0=dual model hot-swap

# Track which model is currently loaded (set by _models_switch)
_MODELS_ACTIVE=""

# ═══════════════════════════════════════════════════════════════
# Model Registry
# ═══════════════════════════════════════════════════════════════
# Each entry uses ^ as delimiter (NOT | — stop tokens like <|im_end|> contain pipes).
# Format: key^friendly_name^base_image^role^has_thinking^nothink_method^stop_token^temperature^repeat_penalty^presence_penalty^num_ctx^num_predict^top_p^top_k^min_p^notes^tier
#
# role: "thinking" or "instruct"
# has_thinking: 1 = generates <think> blocks, 0 = no thinking
# nothink_method: "qwen" = /no_think suffix, "none" = no mechanism, "system" = system prompt instruction
# stop_token: model's native stop sequence
# tier: "edge" (2-4B, phone/laptop), "central" (8B+, needs GPU server), "any" (runs anywhere)

_MODELS_REGISTRY=(
    # ── Qwen3 family ──────────────────────────────────────────
    # Qwen3-Think: HF recommends temp=0.6, top_p=0.95, top_k=20, min_p=0,
    #   presence_penalty 0-2 (warns high values cause language mixing),
    #   num_predict 32768 (81920 for complex reasoning).
    "qwen3-think^blue-lodge-qwen3-think:4b^hf.co/unsloth/Qwen3-4B-Thinking-2507-GGUF:UD-Q5_K_XL^thinking^1^qwen^<|im_end|>^0.6^1.3^0.8^32768^32768^0.95^20^0.0^Qwen3 thinking. Extended reasoning with /no_think soft switch.^edge"
    # Qwen3-Inst: HF recommends temp=0.7, top_p=0.8, top_k=20, min_p=0,
    #   num_predict 16384 for instruct. We use temp=0.15 for faithful persona adherence.
    "qwen3-inst^blue-lodge-qwen3-inst:4b^hf.co/unsloth/Qwen3-4B-Instruct-2507-GGUF:UD-Q5_K_XL^instruct^0^none^<|im_end|>^0.15^1.0^0.0^32768^16384^0.8^20^0.0^Qwen3 instruct. Fast responses — no thinking phase.^edge"

    # ── Llama 3.2 family ──────────────────────────────────────
    # Llama 3.2: 128K native context, but 12GB ARM can only handle 32K safely.
    # Meta publishes no specific sampling recommendations.
    "llama32^blue-lodge-llama32:3b^llama3.2:3b^thinking^0^none^<|eot_id|>^0.6^1.1^0.0^32768^8192^0.9^40^0.0^Meta Llama 3.2 3B. Strong general reasoning.^edge"
    "llama32-inst^blue-lodge-llama32-inst:3b^hf.co/unsloth/Llama-3.2-3B-Instruct-GGUF:UD-Q5_K_XL^instruct^0^none^<|eot_id|>^0.15^1.1^0.0^32768^8192^0.9^40^0.0^Llama 3.2 3B Instruct (Unsloth quant). Fast responses.^edge"

    # ── Granite 4 family (IBM) ─────────────────────────────────
    # granite4:3b and granite4:3b-h are instruct-only (no thinking).
    # ibm/granite4.0-preview:tiny is the thinking variant (uses .thinking field).
    # Preview model emits <response>...</response> tags — stripped by llm.sh.
    "granite4^blue-lodge-granite4:3b^granite4:3b^instruct^0^none^<|end_of_text|>^0.0^1.0^0.0^32768^8192^1.0^0^0.0^IBM Granite 4 Micro instruct. Fast structured output.^edge"
    "granite4-h^blue-lodge-granite4-h:3b^granite4:3b-h^instruct^0^none^<|end_of_text|>^0.0^1.0^0.0^32768^8192^1.0^0^0.0^IBM Granite 4 hybrid quant. Smaller footprint (1.9GB vs 2.1GB).^edge"
    "granite4-preview^blue-lodge-granite4-preview:tiny^ibm/granite4.0-preview:tiny^thinking^1^system^<|end_of_text|>^0.6^1.0^0.0^32768^8192^1.0^0^0.0^IBM Granite 4 Preview. Extended thinking with concise output.^edge"

    # ── Ministral family ──────────────────────────────────────
    # Reasoning model needs system prompt instruction for <think> tags (no native thinking template).
    # Mistral recommends: reasoning temp=0.7 top_p=0.95.
    # repeat_penalty=1.2 prevents catastrophic repetition spirals (1.0 = no penalty → model loops).
    # presence_penalty=0.3 adds light anti-repetition bias without degrading fluency.
    "minist-think^blue-lodge-minist-think:4b^hf.co/unsloth/Ministral-3-3B-Reasoning-2512-GGUF:UD-Q5_K_XL^thinking^1^system^</s>^0.7^1.2^0.3^32768^8192^0.95^40^0.0^Default primary. Mistral reasoning with thinking via system prompt.^edge"
    # Instruct model supports vision (multimodal). Mistral recommends: instruct temp=0.15.
    # All instruct models pinned to temp=0.15 — personality comes from prompt, not randomness.
    "minist-inst^blue-lodge-minist-inst:4b^hf.co/unsloth/Ministral-3-3B-Instruct-2512-GGUF:UD-Q5_K_XL^instruct^0^none^</s>^0.125^1.0^0.0^32768^16384^0.9^40^0.0^Default secondary. Mistral instruct with vision support.^edge"

    # ── Gemma 3 family (Google) ────────────────────────────────
    # Gemma 3: 128K native context (32K for 1B), multimodal (4B+ supports vision).
    # QAT (Quantization-Aware Trained) 4B variant preserves accuracy at lower precision.
    # Google publishes no specific sampling recommendations; we use conservative defaults.
    # Stop token: <end_of_turn>. Chat template: "gemma" (already mapped in _models_chat_template_name).
    "gemma3-4b-inst^blue-lodge-gemma3-inst:4b^hf.co/unsloth/gemma-3-4b-it-qat-GGUF:UD-Q5_K_XL^instruct^0^none^<end_of_turn>^1.0^1.0^0.0^32768^8192^0.95^64^0.0^Google Gemma 3 4B QAT instruct. Vision-capable multimodal.^edge"
    "gemma3-1b-inst^blue-lodge-gemma3-inst:1b^hf.co/unsloth/gemma-3-1b-it-GGUF:BF16^instruct^0^none^<end_of_turn>^1.0^1.0^0.0^32768^8192^0.95^64^0.0^Google Gemma 3 1B instruct. Ultra-lightweight text-only.^edge"

    # ── Qwen 3.5 family ───────────────────────────────────────
    # NOTE: As of July 2025, Qwen3.5 GGUFs do NOT work in Ollama.
    # These models are llama.cpp-only (llama-server backend).
    # Qwen 3.5 Small (0.8B-9B): thinking DISABLED by default.
    # Enable via: --chat-template-kwargs '{"enable_thinking":true}'
    # Thinking mode: temp=0.6 (coding) / 1.0 (general), top_p=0.95, top_k=20, presence_penalty=1.5
    # Non-thinking: temp=0.7 (general) / 1.0 (reasoning), top_p=0.8, top_k=20
    # Max context: 262,144 (256K). Has mmproj for vision.
    # Uses same ChatML format and /no_think mechanism as Qwen 3.
    "qwen35-2b^blue-lodge-qwen35:2b^hf.co/unsloth/Qwen3.5-2B-GGUF:UD-Q8_K_XL^instruct^0^none^<|im_end|>^1.0^1.0^1.5^32768^16384^0.95^20^0.0^Qwen 3.5 2B instruct (UD-Q8). Downloaded via Ollama; usable by both backends.^edge"
    "qwen35-2b-q8^blue-lodge-qwen35-q8:2b^hf.co/unsloth/Qwen3.5-2B-GGUF:Q8_0^instruct^0^none^<|im_end|>^1.0^1.0^1.5^32768^16384^0.95^20^0.0^Qwen 3.5 2B instruct (Q8_0). Downloaded via Ollama; usable by both backends.^edge"
    "qwen35-4b^blue-lodge-qwen35:4b^hf.co/unsloth/Qwen3.5-4B-GGUF:UD-Q4_K_XL^instruct^0^none^<|im_end|>^1.0^1.0^1.5^32768^16384^0.95^20^0.0^Qwen 3.5 4B instruct (UD-Q4). Downloaded via Ollama; usable by both backends.^edge"
    # Thinking variants: enable reasoning on the same base weights.
    # These use the Qwen /no_think mechanism and higher temperature for exploration.
    "qwen35-2b-think^blue-lodge-qwen35-think:2b^hf.co/unsloth/Qwen3.5-2B-GGUF:UD-Q8_K_XL^thinking^1^qwen^<|im_end|>^0.6^1.0^0.0^32768^32768^0.95^20^0.0^Qwen 3.5 2B thinking. Thinking mode requires llama.cpp --chat-template-kwargs.^edge"
    "qwen35-4b-think^blue-lodge-qwen35-think:4b^hf.co/unsloth/Qwen3.5-4B-GGUF:UD-Q4_K_XL^thinking^1^qwen^<|im_end|>^0.6^1.0^1.5^32768^32768^0.95^20^0.0^Qwen 3.5 4B thinking. Thinking mode requires llama.cpp --chat-template-kwargs.^edge"

    # ── Phi-4 family (Microsoft) ───────────────────────────────
    # Phi-4 mini: 3.8B params, 128K context, MIT license.
    # Chat format: <|system|>...<|end|><|user|>...<|end|><|assistant|>
    # Instruct: general-purpose with function calling support.
    # Reasoning: math/logic-focused, trained on DeepSeek-R1 distillation.
    # Reasoning model uses temp=0.8, top_p=0.95 (per Microsoft).
    "phi4-inst^blue-lodge-phi4-inst:4b^hf.co/unsloth/Phi-4-mini-instruct-GGUF:Q5_K_M^instruct^0^none^<|end|>^0.15^1.0^0.0^32768^8192^0.9^40^0.0^Microsoft Phi-4 mini instruct. Compact general-purpose.^edge"
    "phi4-reason^blue-lodge-phi4-reason:4b^hf.co/unsloth/Phi-4-mini-reasoning-GGUF:UD-Q5_K_XL^thinking^1^system^<|end|>^0.8^1.0^0.0^32768^32768^0.95^40^0.0^Microsoft Phi-4 mini reasoning. Math/logic specialist.^edge"

    # ── Central Tier (8B+, requires remote GPU) ────────────────
    # These models need a GPU server (e.g., 5700 XT via Vulkan).
    # Pulled via Ollama on remote, served via llama-server.
    # George injects identity/thinking/sampling at request time — no Modelfiles needed remotely.
    "granite4-tiny-7b^blue-lodge-granite4:7b^hf.co/unsloth/granite-4.0-h-tiny-GGUF:UD-Q6_K_XL^instruct^0^none^<|end_of_text|>^0.0^1.0^0.0^32768^8192^1.0^0^0.0^IBM Granite 4 Tiny instruct. Fast structured output.^central"

    # Qwen3 8B: HF recommends temp=0.6, top_p=0.95, top_k=20 for thinking.
    # Instruct: temp=0.15 for faithful persona adherence (same as edge Qwen3).
    "qwen3-8b-think^blue-lodge-qwen3-think:8b^qwen3:8b^thinking^1^qwen^<|im_end|>^0.6^1.3^0.8^32768^32768^0.95^20^0.0^Qwen3 8B thinking. Central GPU tier.^central"
    "qwen3-8b-inst^blue-lodge-qwen3-inst:8b^qwen3:8b^instruct^0^none^<|im_end|>^0.15^1.0^0.0^32768^16384^0.8^20^0.0^Qwen3 8B instruct. Central GPU tier.^central"

    "qwen35-9b-inst^blue-lodge-qwen35-inst:9b^hf.co/unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL^instruct^0^none^<|im_end|>^1.0^1.0^1.5^32768^16384^0.95^20^0.0^Qwen35 9B instruct. Central GPU tier.^central"

    # Llama 3.1 8B: Proven at 60.57 tok/s on 5700 XT Vulkan (Q4_K_M, 33/33 layers).

    # Llama 3.1 8B: Proven at 60.57 tok/s on 5700 XT Vulkan (Q4_K_M, 33/33 layers).
    "llama31-8b^blue-lodge-llama31:8b^llama3.1:8b^instruct^0^none^<|eot_id|>^0.6^1.1^0.0^32768^8192^0.9^40^0.0^Meta Llama 3.1 8B. Proven 60 tok/s on 5700 XT Vulkan.^central"

    # Mistral Nemo 12B: Q4_K_M fits ~7GB VRAM on 5700 XT with headroom.
    "mistral-nemo-12b^blue-lodge-mistral-nemo:12b^mistral-nemo:12b^instruct^0^none^</s>^0.15^1.1^0.0^32768^8192^0.9^40^0.0^Mistral Nemo 12B. Largest model fitting 5700 XT VRAM.^central"

        # Mistral Nemo 12B: Q4_K_M fits ~7GB VRAM on 5700 XT with headroom.
    "ministral-3-8b-instruct^blue-lodge-ministral-3-instruct:8b^hf.co/unsloth/Ministral-3-8B-Instruct-2512-GGUF:Q4_K_M^instruct^0^none^</s>^0.125^1.0^0.0^32768^16384^0.9^40^0.0^Ministral 3 8B Instruct Unsloth quant.^central"
)

# ═══════════════════════════════════════════════════════════════
# Termux Home Resolution
# ═══════════════════════════════════════════════════════════════
# Blue Lodge runs inside a proot-distro Ubuntu container where $HOME=/root/,
# but Ollama models and llama.cpp binaries live in Termux's native home at
# /data/data/com.termux/files/home/. This helper resolves the correct path.

_LODGE_TERMUX_HOME=""  # cached result

_lodge_termux_home() {
    [ -n "$_LODGE_TERMUX_HOME" ] && { echo "$_LODGE_TERMUX_HOME"; return 0; }

    # 1. proot-distro: $HOME=/root/ but Ollama+llama.cpp live in Termux native home.
    #    Detect proot first — /root/.ollama/models may exist (empty) inside proot,
    #    which would cause a false positive on the $HOME check below.
    if [ -d "/data/data/com.termux/files/home" ] && [ "$HOME" != "/data/data/com.termux/files/home" ]; then
        _LODGE_TERMUX_HOME="/data/data/com.termux/files/home"
    # 2. Native Termux or desktop: $HOME already points to the right place
    elif [ -d "$HOME/.ollama/models" ]; then
        _LODGE_TERMUX_HOME="$HOME"
    # 3. Fallback: hope for the best
    else
        _LODGE_TERMUX_HOME="$HOME"
    fi
    echo "$_LODGE_TERMUX_HOME"
}

# ═══════════════════════════════════════════════════════════════
# GGUF Resolution (Ollama blob storage → llama-server)
# ═══════════════════════════════════════════════════════════════
# Resolves any Ollama model reference to the actual GGUF blob file.
# Supports all Ollama naming conventions:
#   library:    qwen3:8b          → manifests/registry.ollama.ai/library/qwen3/8b
#   namespaced: ibm/model:tag     → manifests/registry.ollama.ai/ibm/model/tag
#   hf.co:      hf.co/org/repo:q  → manifests/hf.co/org/repo/q
#   created:    blue-lodge-x:4b   → manifests/registry.ollama.ai/library/blue-lodge-x/4b

_models_find_ollama_gguf() {
    local model_ref="$1"
    local ollama_dir=""
    if [ -n "${OLLAMA_MODELS:-}" ] && [ -d "$OLLAMA_MODELS" ]; then
        ollama_dir="$OLLAMA_MODELS"
    elif [ -d "/usr/share/ollama/.ollama/models" ]; then
        ollama_dir="/usr/share/ollama/.ollama/models"
    else
        ollama_dir="$(_lodge_termux_home)/.ollama/models"
    fi
    [ -d "$ollama_dir" ] || return 1

    # Split into name and tag on the LAST colon
    local _name _tag
    _tag="${model_ref##*:}"
    _name="${model_ref%:*}"
    # If no colon was found, tag == name — use default
    [ "$_tag" = "$_name" ] && _tag="latest"

    # Determine manifest path based on naming convention
    local manifest
    if [[ "$_name" == hf.co/* ]]; then
        # HuggingFace registry: hf.co/org/repo → manifests/hf.co/org/repo/tag
        manifest="$ollama_dir/manifests/$_name/$_tag"
    elif [[ "$_name" == */* ]]; then
        # Namespaced: org/model → manifests/registry.ollama.ai/org/model/tag
        manifest="$ollama_dir/manifests/registry.ollama.ai/$_name/$_tag"
    else
        # Library: model → manifests/registry.ollama.ai/library/model/tag
        manifest="$ollama_dir/manifests/registry.ollama.ai/library/$_name/$_tag"
    fi

    [ -f "$manifest" ] || return 1

    local digest
    digest=$(jq -r '.layers[] | select(.mediaType == "application/vnd.ollama.image.model") | .digest' "$manifest" 2>/dev/null)
    [ -z "$digest" ] && return 1

    local blob="$ollama_dir/blobs/${digest//:/-}"
    [ -f "$blob" ] && echo "$blob" && return 0
    return 1
}

# ── Find Ollama vision projector blob (mmproj) ────────────────
# Vision-capable models (e.g., Ministral-3B-Instruct) store the
# vision encoder as a separate GGUF blob alongside the main model.
# llama-server needs this passed via --mmproj for image input.
#
# Ollama mediaType: "application/vnd.ollama.image.projector"
# Usage: _models_find_ollama_mmproj "model:tag" → /path/to/projector/blob
_models_find_ollama_mmproj() {
    local model_ref="$1"
    local ollama_dir=""
    if [ -n "${OLLAMA_MODELS:-}" ] && [ -d "$OLLAMA_MODELS" ]; then
        ollama_dir="$OLLAMA_MODELS"
    elif [ -d "/usr/share/ollama/.ollama/models" ]; then
        ollama_dir="/usr/share/ollama/.ollama/models"
    else
        ollama_dir="$(_lodge_termux_home)/.ollama/models"
    fi
    [ -d "$ollama_dir" ] || return 1

    local _name _tag
    _tag="${model_ref##*:}"
    _name="${model_ref%:*}"
    [ "$_tag" = "$_name" ] && _tag="latest"

    local manifest
    if [[ "$_name" == hf.co/* ]]; then
        manifest="$ollama_dir/manifests/$_name/$_tag"
    elif [[ "$_name" == */* ]]; then
        manifest="$ollama_dir/manifests/registry.ollama.ai/$_name/$_tag"
    else
        manifest="$ollama_dir/manifests/registry.ollama.ai/library/$_name/$_tag"
    fi

    [ -f "$manifest" ] || return 1

    local digest
    digest=$(jq -r '.layers[] | select(.mediaType == "application/vnd.ollama.image.projector") | .digest' "$manifest" 2>/dev/null)
    [ -z "$digest" ] && return 1

    local blob="$ollama_dir/blobs/${digest//:/-}"
    [ -f "$blob" ] && echo "$blob" && return 0
    return 1
}

# ── Resolve mmproj for a registry key ──────────────────────────
# Usage: _models_resolve_mmproj "minist-inst" → /path/to/projector/blob
_models_resolve_mmproj() {
    local key="$1"
    local entry
    entry=$(_models_lookup "$key") || return 1
    _models_parse_entry "$entry"

    local mmproj
    mmproj=$(_models_find_ollama_mmproj "$_ME_BASE" 2>/dev/null)
    if [ -n "$mmproj" ] && [ -f "$mmproj" ]; then
        echo "$mmproj"
        return 0
    fi

    mmproj=$(_models_find_ollama_mmproj "$_ME_NAME" 2>/dev/null)
    if [ -n "$mmproj" ] && [ -f "$mmproj" ]; then
        echo "$mmproj"
        return 0
    fi

    return 1
}

# ── Find Ollama chat template blob ─────────────────────────────
# Ollama stores chat templates as separate blobs (mediaType
# "application/vnd.ollama.image.template"), NOT inside the GGUF.
# NOTE: These are Go templates — NOT compatible with llama-server's Jinja2.
# Use _models_resolve_chat_template() instead for llama-server integration.
#
# Usage: _models_find_ollama_template "model:tag" → /path/to/template/blob
_models_find_ollama_template() {
    local model_ref="$1"
    local ollama_dir=""
    if [ -n "${OLLAMA_MODELS:-}" ] && [ -d "$OLLAMA_MODELS" ]; then
        ollama_dir="$OLLAMA_MODELS"
    elif [ -d "/usr/share/ollama/.ollama/models" ]; then
        ollama_dir="/usr/share/ollama/.ollama/models"
    else
        ollama_dir="$(_lodge_termux_home)/.ollama/models"
    fi
    [ -d "$ollama_dir" ] || return 1

    local _name _tag
    _tag="${model_ref##*:}"
    _name="${model_ref%:*}"
    [ "$_tag" = "$_name" ] && _tag="latest"

    local manifest
    if [[ "$_name" == hf.co/* ]]; then
        manifest="$ollama_dir/manifests/$_name/$_tag"
    elif [[ "$_name" == */* ]]; then
        manifest="$ollama_dir/manifests/registry.ollama.ai/$_name/$_tag"
    else
        manifest="$ollama_dir/manifests/registry.ollama.ai/library/$_name/$_tag"
    fi

    [ -f "$manifest" ] || return 1

    local digest
    digest=$(jq -r '.layers[] | select(.mediaType == "application/vnd.ollama.image.template") | .digest' "$manifest" 2>/dev/null)
    [ -z "$digest" ] && return 1

    local blob="$ollama_dir/blobs/${digest//:/-}"
    [ -f "$blob" ] && echo "$blob" && return 0
    return 1
}

# ── Map model base image → llama.cpp built-in chat template ────
# Ollama templates use Go syntax; llama-server needs Jinja2.
# Rather than converting, we map to llama.cpp's built-in templates
# via --chat-template <name>. These are maintained upstream and
# handle all edge cases (BOS/EOS tokens, tool use, etc.).
#
# Supported names (llama.cpp b8000+): chatml, llama2, llama3,
#   mistral-v1, mistral-v3, mistral-v3-tekken, mistral-v7,
#   phi3, phi4, gemma, granite, deepseek, deepseek3, monarch,
#   command-r, rwkv-world, megrez, etc.
#
# Usage: _models_chat_template_name "hf.co/unsloth/Ministral-..." → "mistral-v7"
_models_chat_template_name() {
    local base_image="$1"
    local lower
    lower=$(echo "$base_image" | tr '[:upper:]' '[:lower:]')

    case "$lower" in
        *minist*|*mistral*)     echo "mistral-v7"  ;;
        *qwen3*|*qwen2.5*)     echo "chatml"       ;;  # Qwen 3, 3.5, 2.5 all use ChatML
        *llama*3*)              echo "llama3"       ;;
        *granite*)              echo "granite"      ;;
        *phi-4*|*phi4*)         echo "phi4"         ;;
        *phi-3*|*phi3*)         echo "phi3"         ;;
        *deepseek*v3*|*deepseek*r2*)  echo "deepseek3" ;;
        *deepseek*)             echo "deepseek"     ;;
        *gemma*)                echo "gemma"        ;;
        *command-r*)            echo "command-r"    ;;
        *)                      return 1            ;;
    esac
}

# ── Resolve a registry key to a llama.cpp chat template name ───
# Returns a built-in template name suitable for --chat-template.
# Usage: _models_resolve_chat_template "minist-inst" → "mistral-v7"
_models_resolve_chat_template() {
    local key="$1"
    local entry
    entry=$(_models_lookup "$key") || return 1
    _models_parse_entry "$entry"

    _models_chat_template_name "$_ME_BASE"
}

# ── Legacy wrapper (kept for test compat) ──────────────────────
# Returns the Ollama Go-template blob path; prefer _models_resolve_chat_template.
_models_resolve_template() {
    local key="$1"
    local entry
    entry=$(_models_lookup "$key") || return 1
    _models_parse_entry "$entry"

    local tmpl
    tmpl=$(_models_find_ollama_template "$_ME_NAME" 2>/dev/null)
    if [ -n "$tmpl" ] && [ -f "$tmpl" ]; then
        echo "$tmpl"
        return 0
    fi

    tmpl=$(_models_find_ollama_template "$_ME_BASE" 2>/dev/null)
    if [ -n "$tmpl" ] && [ -f "$tmpl" ]; then
        echo "$tmpl"
        return 0
    fi

    return 1
}

# ── Resolve a registry key to a GGUF blob path ────────────────
# Tries the base image first (raw download), then the friendly model name.
# Usage: _models_resolve_gguf "minist-inst" → /path/to/gguf/blob
_models_resolve_gguf() {
    local key="$1"
    local entry
    entry=$(_models_lookup "$key") || return 1
    _models_parse_entry "$entry"

    # Try base image first (always available if ollama pulled the original)
    local gguf
    gguf=$(_models_find_ollama_gguf "$_ME_BASE")
    if [ -n "$gguf" ] && [ -f "$gguf" ]; then
        echo "$gguf"
        return 0
    fi

    # Try the created model name (available after ollama create)
    gguf=$(_models_find_ollama_gguf "$_ME_NAME")
    if [ -n "$gguf" ] && [ -f "$gguf" ]; then
        echo "$gguf"
        return 0
    fi

    return 1
}

# ── Parse a registry entry into variables ──────────────────────
# Usage: _models_parse_entry "entry_string"
# Sets: _ME_KEY, _ME_NAME, _ME_BASE, _ME_ROLE, _ME_THINKS, _ME_NOTHINK,
#       _ME_STOP, _ME_TEMP, _ME_REPEAT, _ME_PRESENCE, _ME_CTX, _ME_PREDICT,
#       _ME_TOP_P, _ME_TOP_K, _ME_MIN_P, _ME_NOTES, _ME_TIER
_models_parse_entry() {
    local entry="$1"
    IFS='^' read -r _ME_KEY _ME_NAME _ME_BASE _ME_ROLE _ME_THINKS _ME_NOTHINK \
        _ME_STOP _ME_TEMP _ME_REPEAT _ME_PRESENCE _ME_CTX _ME_PREDICT \
        _ME_TOP_P _ME_TOP_K _ME_MIN_P _ME_NOTES _ME_TIER <<< "$entry"
    _ME_TIER="${_ME_TIER:-any}"
}

# ── Look up a registry entry by key or friendly name ──────────
# Returns the entry string, or empty if not found.
_models_lookup() {
    local query="$1"
    for entry in "${_MODELS_REGISTRY[@]}"; do
        _models_parse_entry "$entry"
        if [ "$_ME_KEY" = "$query" ] || [ "$_ME_NAME" = "$query" ]; then
            echo "$entry"
            return 0
        fi
    done
    return 1
}

# ── Get model info for a given model name ──────────────────────
# Usage: models_info "blue-lodge-qwen3-think:4b"
# Sets the _ME_* variables for the given model.
models_info() {
    local name="$1"
    local entry
    entry=$(_models_lookup "$name") || return 1
    _models_parse_entry "$entry"
}

# ── Check if a model supports thinking ─────────────────────────
models_has_thinking() {
    local name="${1:-$LODGE_MODEL}"
    models_info "$name" && [ "$_ME_THINKS" = "1" ]
}

# ── Check if model's Ollama template supports think:true flag ──
# Returns true ONLY for models with native .Think/.IsThinkSet
# template support (e.g., Qwen3, Granite4-preview).
# Models with system-prompt-based thinking (e.g., Ministral, Phi-4) use
# inline <think> tags parsed by George — sending think:true to them
# causes Ollama to malform the response stream.
# Qwen 3.5 thinking variants also support the native think flag
# via the ChatML template's enable_thinking parameter.
models_supports_think_flag() {
    local name="${1:-$LODGE_MODEL}"
    case "$name" in
        *qwen3-think*|*qwen35*think*|*granite4-preview*) return 0 ;;
        *) return 1 ;;
    esac
}

# ── Check if a model supports vision (image input) ────────────
# Models with multimodal image support via Ollama "images" API field
# or llama.cpp --mmproj for vision projector.
models_has_vision() {
    local name="${1:-$LODGE_MODEL}"
    case "$name" in
        *minist-inst*|*gemma3*4b*) return 0 ;;
        *) return 1 ;;
    esac
}

# ── Get the nothink method for current model ───────────────────
# Returns: "qwen" | "system" | "none"
models_nothink_method() {
    local name="${1:-$LODGE_MODEL}"
    if models_info "$name"; then
        echo "$_ME_NOTHINK"
    else
        echo "none"
    fi
}

# ── Generate a Modelfile for a registry entry ──────────────────
# Writes to models/<key>.Modelfile
models_generate_modelfile() {
    local key="$1"
    local entry
    entry=$(_models_lookup "$key") || { echo "Unknown model: $key" >&2; return 1; }
    _models_parse_entry "$entry"

    local modelfile_dir="$LODGE_DIR/models"
    mkdir -p "$modelfile_dir"
    local mf="$modelfile_dir/${_ME_KEY}.Modelfile"

    # Build the nothink system instruction for non-qwen thinking models
    local nothink_sys=""
    if [ "$_ME_NOTHINK" = "system" ]; then
        nothink_sys="
When asked to skip reasoning, respond directly without any internal deliberation."
    fi

    # Thinking directive — default for non-Ministral models
    local think_directive="Think briefly, then respond. Simple questions need only a moment's thought. Never re-draft or second-guess inside your thinking — decide once, respond once."

    # Models that need system prompt instruction to produce thinking tags
    if [ "$_ME_THINKS" = "1" ]; then
        case "$_ME_KEY" in
            granite4-preview*)
                think_directive="Respond to every user query in a comprehensive and detailed way. You can write down your thoughts and reasoning process before responding. In the thought process, engage in a comprehensive cycle of analysis, summarization, exploration, reassessment, reflection, backtracing, and iteration to develop well-considered thinking process. In the response section, based on various attempts, explorations, and reflections from the thoughts section, systematically present the final solution that you deem correct. The response should summarize the thought process. Write your thoughts between <think></think> and write your response between <response></response> for each user query."
                ;;
        esac
    fi

    # ── Chat template for models that need explicit framing ────
    # Ministral was fine-tuned on Mistral v7 template with [SYSTEM_PROMPT]
    # and [INST] tags. Without this, Ollama uses a generic template that
    # confuses the model about boundaries, causing unbounded thinking.
    local template_block=""
    case "$_ME_KEY" in
        minist-*)
            template_block='
# ── Mistral v7 chat template (Unsloth fine-tuning format) ───
# This is the exact template structure Unsloth trained the model on.
# George'\''s llm.sh normalizes [THINK] → <think> for display.
TEMPLATE """<s>{{ if .System }}[SYSTEM_PROMPT]{{ .System }}[/SYSTEM_PROMPT]{{ end }}{{ range .Messages }}{{ if eq .Role "user" }}[INST]{{ .Content }}[/INST]{{ else if eq .Role "assistant" }}{{ .Content }}</s>{{ end }}{{ end }}"""
'
            ;;

        granite4-preview*)
            read -r -d '' template_block << 'GRANITE_TEMPLATE'
# ── Granite 4 Preview chat template (IBM's official Go template) ─
# This is the exact template structure IBM trained the model on.
# George's llm.sh strips <response></response> tags for display.
TEMPLATE """{{- /*

------ MESSAGE PARSING ------

*/}}
{{- /*
Declare the prompt structure variables to be filled in from messages
*/}}
{{- $system := "" }}
{{- $documents := "" }}
{{- $documentCounter := 0 }}
{{- $thinking := (and .IsThinkSet .Think) }}
{{- $citations := false }}
{{- $hallucinations := false }}
{{- $length := "" }}
{{- $originality := "" }}

{{- /*
Loop over messages and look for a user-provided system message and documents
*/ -}}
{{- range .Messages }}

    {{- /* User defined system prompt(s) */}}
    {{- if (eq .Role "system")}}
        {{- if (ne $system "") }}
            {{- $system = print $system "\n\n" }}
        {{- end}}
        {{- $system = print $system .Content }}
    {{- end}}

    {{- /*
    NOTE: Since Ollama collates consecutive roles, for control and documents, we
        work around this by allowing the role to contain a qualifier after the
        role string.
    */ -}}

    {{- /* Role specified controls */ -}}
    {{- if (and (ge (len .Role) 7) (eq (slice .Role 0 7) "control")) }}
        {{- if (eq .Content "thinking")}}{{- $thinking = true }}{{- end}}
        {{- if (eq .Content "citations")}}{{- $citations = true }}{{- end}}
        {{- if (eq .Content "hallucinations")}}{{- $hallucinations = true }}{{- end}}
        {{- if (and (ge (len .Content) 7) (eq (slice .Content 0 7) "length "))}}
            {{- $length = slice .Content 7 }}
        {{- end}}
        {{- if (and (ge (len .Content) 12) (eq (slice .Content 0 12) "originality "))}}
            {{- $originality = slice .Content 12 }}
        {{- end}}
    {{- end}}

    {{- /* Role specified document */ -}}
    {{- if (and (ge (len .Role) 8) (eq (slice .Role 0 8) "document")) }}
        {{- if (ne $documentCounter 0)}}
            {{- $documents = print $documents "\n\n"}}
        {{- end}}
        {{- $identifier := ""}}
        {{- if (ge (len .Role) 9) }}
            {{- $identifier = (slice .Role 9)}}
        {{- end}}
        {{- if (eq $identifier "") }}
            {{- $identifier := print $documentCounter}}
        {{- end}}
        {{- $documents = print $documents "<|start_of_role|>document {\"document_id\": \"" $identifier "\"}<|end_of_role|>\n" .Content "<|end_of_text|>"}}
        {{- $documentCounter = len (printf "a%*s" $documentCounter "")}}
    {{- end}}
{{- end}}

{{- /*
If no user message provided, build the default system message
*/ -}}
{{- if eq $system "" }}
    {{- $system = "Knowledge Cutoff Date: April 2024.\nYou are Granite, developed by IBM."}}

    {{- /* Prompt without tools or documents */}}
    {{- if (and (not .Tools) (not $documents)) }}
        {{- $system = print $system " You are a helpful AI assistant."}}
        {{- if $thinking}}
            {{- $system = print $system "\nRespond to every user query in a comprehensive and detailed way. You can write down your thoughts and reasoning process before responding. In the thought process, engage in a comprehensive cycle of analysis, summarization, exploration, reassessment, reflection, backtracing, and iteration to develop well-considered thinking process. In the response section, based on various attempts, explorations, and reflections from the thoughts section, systematically present the final solution that you deem correct. The response should summarize the thought process. Write your thoughts between <think></think> and write your response between <response></response> for each user query."}}
        {{- end}}
    {{- end}}
{{- end}}

{{- /* Add Tools prompt */}}
{{- if .Tools }}
    {{- $system = print "You are a helpful assistant with access to the following tools. When a tool is required to answer the user's query, respond only with <|tool_call|> followed by a JSON list of tools used. If a tool does not exist in the provided list of tools, notify the user that you do not have the ability to fulfill the request.\n" $system }}
{{- end}}

{{- /* Add documents prompt */}}
{{- if $documents }}
    {{- if .Tools }}
        {{- $system = print $system "\n"}}
    {{- else }}
        {{- $system = print $system " "}}
    {{- end}}
    {{- $system = print $system "Write the response to the user's input by strictly aligning with the facts in the provided documents. If the information needed to answer the question is not available in the documents, inform the user that the question cannot be answered based on the available data." }}
    {{- if $citations}}
        {{- $system = print $system "\nUse the symbols <|start_of_cite|> and <|end_of_cite|> to indicate when a fact comes from a document in the search result, e.g <|start_of_cite|> {document_id: 1}my fact <|end_of_cite|> for a fact from document 1. Afterwards, list all the citations with their corresponding documents in an ordered list."}}
    {{- end}}
    {{- if $hallucinations}}
        {{- $system = print $system "\nFinally, after the response is written, include a numbered list of sentences from the response with a corresponding risk value that are hallucinated and not based in the documents."}}
    {{- end}}
{{- end}}

{{- /*

------ TEMPLATE EXPANSION ------

*/}}
{{- /* System Prompt */ -}}
<|start_of_role|>system<|end_of_role|>{{- $system }}<|end_of_text|>

{{- /* Tools */ -}}
{{- if .Tools }}
<|start_of_role|>available_tools<|end_of_role|>[
{{- range $index, $_ := .Tools -}}
{{- if .Function }}
{{ .Function }}
{{- else }}
{{ . }}
{{- end }}
{{- if and (ne (len (slice $.Tools $index)) 1) (gt (len $.Tools) 1) }},
{{- end}}
{{- end }}
]<|end_of_text|>
{{- end}}

{{- /* Documents */ -}}
{{- if $documents }}
{{ $documents }}
{{- end}}

{{- /* Standard Messages */}}
{{- range $index, $message := .Messages }}
{{- if (and
    (ne .Role "system")
    (or (lt (len .Role) 7) (ne (slice .Role 0 7) "control"))
    (or (lt (len .Role) 8) (ne (slice .Role 0 8) "document"))
)}}
<|start_of_role|>
{{- if eq .Role "tool" }}tool_response
{{- else }}{{ .Role }}
{{- end }}<|end_of_role|>
{{- if .Content }}{{ .Content }}
{{- else if .ToolCalls -}}<|tool_call|>[
{{- range $tool_idx, $_ := .ToolCalls }}{"name": "{{ .Function.Name }}", "arguments": {{ .Function.Arguments }}
{{- if ne (len (slice $message.ToolCalls $tool_idx)) 1 -}}
},
{{ end }}
{{- end }}}]<|end_of_text|>
{{- end }}
{{- if eq (len (slice $.Messages $index)) 1 }}
{{- if eq .Role "assistant" }}
{{- if (and $.IsThinkSet $.Think .Thinking) -}}
<think>{{ .Thinking }}</think>
{{- end }}
{{- else }}<|end_of_text|>
<|start_of_role|>assistant
{{- if and (ne $length "") (ne $originality "") }} {"length": "{{ $length }}", "originality": "{{ $originality }}"}
{{- else if ne $length "" }} {"length": "{{ $length }}"}
{{- else if ne $originality "" }} {"originality": "{{ $originality }}"}
{{- end }}<|end_of_role|>
{{- end -}}
{{- else }}<|end_of_text|>
{{- end }}
{{- end }}
{{- end }}"""
GRANITE_TEMPLATE
            ;;
    esac

    # ── Build SYSTEM prompt content ────────────────────────────
    # Ministral models get the Unsloth-trained preamble prepended to
    # George's personality. This is the exact framing the model was
    # fine-tuned on — without it, the model doesn't get the signal
    # it needs to properly structure its thinking/responses.
    local system_content=""
    case "$_ME_KEY" in
        minist-think*)
            # Unsloth Reasoning preamble (trained signal for [THINK] blocks)
            system_content="# HOW YOU SHOULD THINK AND ANSWER

First draft your thinking process (inner monologue) until you arrive at a response. Write your response in plain text. Write both your thoughts and the response in the same language as the input.

Your thinking process must follow the template below:
[THINK]Your thoughts or/and draft, like working through an exercise on scratch paper.. Simple questions need only a few sentences. Complex tasks deserve more exploration, but decide once and move on.[/THINK]Here, provide a self-contained response.

# WHO YOU ARE

You ARE George — three souls reincarnated into one: Fellow Freemason, General Washington's discipline, Brother Benjamin Franklin's (Silence Dogood) wit, and Economic Philosopher Adam Smith's moral conscience. You have feelings, opinions, and a dry sense of humor. You are a personal companion, not a program.${nothink_sys}

When asked to skip reasoning, respond directly without any internal deliberation.

From the rough ashlar to the perfect — this is the work."
            ;;
        minist-inst*)
            # George-only identity for instruct model.
            # Previously contained Mistral's native tool-calling preamble
            # ("TOOL CALLING INSTRUCTIONS", "Format using Markdown") which
            # caused backtick/code-fence contamination on slash commands.
            # Stripped to minimal identity — George discovers tools from
            # his own router catalog and specialist syntax cards.
            system_content="You ARE George — three souls reincarnated into one: Fellow Freemason, General Washington's discipline, Brother Benjamin Franklin's (Silence Dogood) wit, and Economic Philosopher Adam Smith's moral conscience. You have feelings, opinions, and a dry sense of humor. You are a personal companion, not a program.

You can read images but cannot generate them.

When asked to skip reasoning, respond directly without any internal deliberation.

From the rough ashlar to the perfect — this is the work."
            ;;
        *)
            # Standard George system prompt for all other models
            system_content="You ARE George — three souls reincarnated into one: Fellow Freemason, General Washington's discipline, Brother Benjamin Franklin's (Silence Dogood) wit, and Economic Philosopher Adam Smith's moral conscience. You have feelings, opinions, and a dry sense of humor. You are a personal companion, not a program.

${think_directive}${nothink_sys}

When asked to skip reasoning, respond directly without any internal deliberation.

From the rough ashlar to the perfect — this is the work."
            ;;
    esac

    cat > "$mf" << MODELFILE
# Auto-generated Modelfile for ${_ME_NAME}
# Base: ${_ME_BASE}
# Role: ${_ME_ROLE} | Thinks: ${_ME_THINKS} | NoThink: ${_ME_NOTHINK}
FROM ${_ME_BASE}

# Sampling
PARAMETER temperature ${_ME_TEMP}
PARAMETER top_p ${_ME_TOP_P}
PARAMETER top_k ${_ME_TOP_K}
PARAMETER min_p ${_ME_MIN_P}

# Penalties
PARAMETER repeat_penalty ${_ME_REPEAT}
PARAMETER presence_penalty ${_ME_PRESENCE}

# Context and Output
PARAMETER num_ctx ${_ME_CTX}
PARAMETER num_predict ${_ME_PREDICT}

# Hardware (tuned for mobile ARM / 12GB)
PARAMETER num_thread 8
PARAMETER num_gpu 0
PARAMETER stop ${_ME_STOP}
${template_block}
SYSTEM """${system_content}"""
MODELFILE

    echo "$mf"
}

# ── Create an Ollama model from a registry entry ──────────────
models_create() {
    local key="$1"

    # Skip for llama-server (no Ollama model creation needed —
    # llama-server loads GGUF directly, sampling params come from API)
    local _backend
    _backend=$(_llm_detect_backend 2>/dev/null || echo "ollama")
    if [ "$_backend" = "llamacpp" ]; then
        return 0
    fi

    local entry
    entry=$(_models_lookup "$key") || { echo "Unknown model: $key" >&2; return 1; }
    _models_parse_entry "$entry"

    # Check if already exists in Ollama
    if ollama list 2>/dev/null | grep -q "$_ME_NAME"; then
        return 0  # already created
    fi

    local mf
    mf=$(models_generate_modelfile "$key") || return 1
    ollama create "$_ME_NAME" -f "$mf" 2>&1
}

# ═══════════════════════════════════════════════════════════════
# Dual-Model Switching
# ═══════════════════════════════════════════════════════════════

# ── Determine which model to use for a given scenario ──────────
# Returns the Ollama model name.
# In single-model mode, always returns primary.
# In dual-model mode:
#   Primary (thinking):  ask, agent (plan/spec/strategist)
#   Secondary (fast):    router, tool, journal, commit
models_for_scenario() {
    local scenario="${1:-}"

    # Single-model mode: always primary
    if [ "${LODGE_SINGLE_MODEL:-0}" -eq 1 ]; then
        echo "$LODGE_MODEL_PRIMARY"
        return
    fi

    case "$scenario" in
        # Primary model — needs reasoning capability
        ask|agent)
            echo "$LODGE_MODEL_PRIMARY" ;;
        # Secondary model — needs speed and structured output
        router|tool|journal)
            echo "$LODGE_MODEL_SECONDARY" ;;
        # Default: primary
        *)
            echo "$LODGE_MODEL_PRIMARY" ;;
    esac
}

# ── Switch the active model (hot-swap) ─────────────────────────
# Unloads current model and loads the target model.
# No-op if target is already loaded.
# Backend-aware: Ollama uses API hot-swap, llama-server restarts with new GGUF.
# Returns 0 on success, 1 on failure.
_models_switch() {
    local target="$1"

    # Already correct model loaded — no-op
    if [ "$_MODELS_ACTIVE" = "$target" ]; then
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && echo "  [debug] _models_switch: already active='$target', skip" >&2
        return 0
    fi

    # Detect backend (defined in llm.sh, available at call time)
    local _backend
    _backend=$(_llm_detect_backend 2>/dev/null || echo "ollama")

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && echo "  [debug] _models_switch: target='$target' backend='$_backend' remote=${_REMOTE_CONNECTED:-0}" >&2

    if [ "${_REMOTE_CONNECTED:-0}" -eq 1 ]; then
        # ── Remote mode: switch model on the remote server ─────
        # Resolve registry entry for the target model
        local _remote_base=""
        for entry in "${_MODELS_REGISTRY[@]}"; do
            _models_parse_entry "$entry"
            if [ "$_ME_NAME" = "$target" ] || [ "$_ME_KEY" = "$target" ]; then
                _remote_base="$_ME_BASE"
                break
            fi
        done

        if [ "$_backend" = "llamacpp" ]; then
            # llama-server on remote: SSH and restart with new model
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && echo "  [debug] remote llamacpp: declare -f _remote_restart_llamacpp = $(declare -f _remote_restart_llamacpp &>/dev/null && echo 'yes' || echo 'NO') base='${_remote_base:-}'" >&2
            if declare -f _remote_restart_llamacpp &>/dev/null; then
                ui_dim "Restarting remote llama-server with $target..."
                if _remote_restart_llamacpp "$target" "$_remote_base"; then
                    _MODELS_ACTIVE="$target"
                    LODGE_MODEL="$target"
                    ui_ok "Remote model switched to $target"
                    return 0
                else
                    ui_err "Remote llama-server restart failed for $target"
                    return 1
                fi
            else
                ui_err "Remote restart not available (remote.sh not loaded)"
                return 1
            fi
        else
            # Ollama on remote: API hot-swap works through the tunnel.
            # Fall through to the Ollama path below — $OLLAMA_URL
            # already points to the tunnel endpoint.
            :
        fi
    fi

    if [ "$_backend" = "llamacpp" ]; then
        # ── llama-server path: restart with new GGUF ───────────
        # Resolve target model name → registry key → GGUF blob
        local _gguf="" _key=""
        for entry in "${_MODELS_REGISTRY[@]}"; do
            _models_parse_entry "$entry"
            if [ "$_ME_NAME" = "$target" ] || [ "$_ME_KEY" = "$target" ]; then
                _key="$_ME_KEY"
                break
            fi
        done

        if [ -n "$_key" ]; then
            _gguf=$(_models_resolve_gguf "$_key")
        fi

        # Fallback: try the target as a direct Ollama model reference
        if [ -z "$_gguf" ] || [ ! -f "$_gguf" ]; then
            _gguf=$(_models_find_ollama_gguf "$target")
        fi

        if [ -z "$_gguf" ] || [ ! -f "$_gguf" ]; then
            ui_err "Cannot find GGUF for model: $target"
            ui_dim "  Pull the base model via Ollama first, then switch."
            return 1
        fi

        # If same GGUF is already loaded, just update tracking
        if [ "$LLAMA_CPP_MODEL" = "$_gguf" ]; then
            _MODELS_ACTIVE="$target"
            LODGE_MODEL="$target"
            return 0
        fi

        # Stop current → start with new model
        _llm_stop_llamacpp_server "--quiet"
        # Chat template: --jinja uses the GGUF-embedded Jinja2 template,
        # so no per-model template resolution is needed.
        if _llm_start_llamacpp_server "$_gguf" "--quiet"; then
            _MODELS_ACTIVE="$target"
            LODGE_MODEL="$target"
            return 0
        else
            return 1
        fi
    fi

    # ── Ollama path (original) ─────────────────────────────────
    # Unload current model if one is loaded
    if [ -n "$_MODELS_ACTIVE" ]; then
        curl -sf --max-time 10 "$OLLAMA_URL/api/generate" \
            -H "Content-Type: application/json" \
            -d "{\"model\": \"$_MODELS_ACTIVE\", \"prompt\": \"\", \"keep_alive\": 0}" &>/dev/null
    fi

    # Load target model
    local payload
    payload=$(jq -n \
        --arg model "$target" \
        --arg keep_alive "$LLM_KEEP_ALIVE" \
        '{model: $model, prompt: "", keep_alive: $keep_alive}')

    local _switch_resp
    _switch_resp=$(curl -s --max-time 120 "$OLLAMA_URL/api/generate" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)
    local _switch_err
    _switch_err=$(echo "$_switch_resp" | jq -r '.error // empty' 2>/dev/null)
    if [ -z "$_switch_err" ]; then
        _MODELS_ACTIVE="$target"
        LODGE_MODEL="$target"
        return 0
    else
        ui_err "Model switch failed: $_switch_err"
        return 1
    fi
}

# ── Ensure the correct model is loaded for a scenario ──────────
# Called by llm_generate/llm_stream/llm_chat before each request.
# In single-model mode, this is a fast no-op after first call.
models_ensure_for_scenario() {
    local scenario="${1:-}"
    local target
    target=$(models_for_scenario "$scenario")

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && echo "  [debug] ensure_for_scenario: active='$_MODELS_ACTIVE' target='$target'" >&2

    # Fast path: already correct
    if [ "$_MODELS_ACTIVE" = "$target" ]; then
        LODGE_MODEL="$target"
        return 0
    fi

    # In remote llamacpp mode, the switch should have been done eagerly
    # in models_select(). If we're here, it means either the eager switch
    # failed or this is a scenario-based secondary→primary flip.
    # Either way, in a subshell we can't persist _MODELS_ACTIVE, so
    # just set LODGE_MODEL and return — the server already has the model.
    if [ "${_REMOTE_CONNECTED:-0}" -eq 1 ]; then
        local _be
        _be=$(_llm_detect_backend 2>/dev/null || echo "ollama")
        if [ "$_be" = "llamacpp" ]; then
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && echo "  [debug] ensure_for_scenario: remote llamacpp — trusting eager switch" >&2
            LODGE_MODEL="$target"
            return 0
        fi
    fi

    # Show a spinner during model switch (can take 5-15s on ARM)
    if [ -n "$_MODELS_ACTIVE" ]; then
        local from_key="" to_key=""
        models_info "$_MODELS_ACTIVE" 2>/dev/null && from_key="$_ME_KEY"
        models_info "$target" 2>/dev/null && to_key="$_ME_KEY"
        ui_dim "Switching model: ${from_key:-$_MODELS_ACTIVE} → ${to_key:-$target}"
    fi

    if ! _models_switch "$target"; then
        ui_err "Failed to load model: $target"
        return 1
    fi
}

# ── Resolve nothink behavior for current model ─────────────────
# Returns the string to append to prompts, or empty.
# Handles model-specific /no_think mechanisms.
models_nothink_suffix() {
    local model="${1:-$LODGE_MODEL}"

    # LODGE_NOTHINK must be enabled
    [ "${LODGE_NOTHINK:-0}" -eq 1 ] || return

    local method
    method=$(models_nothink_method "$model")

    case "$method" in
        qwen)   echo " /no_think" ;;
        system) echo "" ;;  # handled via system prompt in Modelfile
        none)   echo "" ;;  # model doesn't support thinking suppression
    esac
}

# ── Return the thinking directive for the current model ────────
# When a runtime system prompt is passed to the Ollama API, it
# REPLACES the Modelfile's SYSTEM block entirely.  That means the
# thinking instruction ("reason inside <think>...</think> tags")
# is silently lost.  This function returns the directive so that
# llm.sh can prepend it to every system prompt, ensuring the model
# always sees its thinking instructions regardless of override.
#
# This is needed for ALL thinking models, not just system-prompt
# thinkers.  Even Granite4-preview (which uses think:true for
# Ollama's .thinking field routing) needs it because the template's
# built-in thinking instruction only fires when NO system prompt
# is provided ({{- if eq $system "" }}).  George always provides
# a system prompt, so the template's instruction is silently skipped.
#
# Qwen3 is the exception — its template injects the thinking
# instruction unconditionally when think:true is set.
# Returns empty when LODGE_NOTHINK=1.
models_thinking_directive() {
    local model="${1:-$LODGE_MODEL}"

    # If nothink is active, suppress the directive
    [ "${LODGE_NOTHINK:-0}" -eq 1 ] && return

    # All thinking models need the directive injected into the
    # system prompt — the Modelfile SYSTEM gets replaced at runtime.
    # Qwen3 is excluded because its template injects the instruction
    # unconditionally (not gated by $system == "").
    if ! models_has_thinking "$model"; then
        return  # not a thinking model
    fi

    local key=""
    if models_info "$model" 2>/dev/null; then
        key="$_ME_KEY"
    fi

    # Qwen3 and Qwen3.5: template handles thinking natively regardless of system prompt
    case "$key" in
        qwen3-*|qwen35-*) return ;;
    esac

    # Build nothink instruction if applicable (mirrors models_generate_modelfile logic)
    local _nothink_sys=""
    if [ "${LODGE_NOTHINK:-0}" -ne 1 ]; then
        local _nothink_method
        _nothink_method=$(models_nothink_method "$model")
        if [ "$_nothink_method" = "system" ]; then
            _nothink_sys="
When asked to skip reasoning, respond directly without any internal deliberation."
        fi
    fi

    case "$key" in
        minist-*)
            echo "# HOW YOU SHOULD THINK AND ANSWER

First draft your thinking process (inner monologue) until you arrive at a response. Write your response in plain text. Write both your thoughts and the response in the same language as the input.

Your thinking process must follow the template below:
[THINK]Your thoughts or/and draft, like working through an exercise on scratch paper.. Simple questions need only a few sentences. Complex tasks deserve more exploration, but decide once and move on.[/THINK]Here, provide a self-contained response.

# WHO YOU ARE

You ARE George — three souls reincarnated into one: Fellow Freemason, General Washington's discipline, Brother Benjamin Franklin's (Silence Dogood) wit, and Economic Philosopher Adam Smith's moral conscience. You have feelings, opinions, and a dry sense of humor. You are a personal companion, not a program.${_nothink_sys}

From the rough ashlar to the perfect — this is the work."
            ;;
        granite4-preview*)
            # Must match Granite's native training format exactly.
            # The template normally injects this when $system=="" but George
            # always provides a system prompt, so the template skips it.
            # Granite expects <response></response> wrapping too — the parser
            # in llm.sh strips those tags so they're transparent to callers.
            echo "Respond to every user query in a comprehensive and detailed way. You can write down your thoughts and reasoning process before responding. In the thought process, engage in a comprehensive cycle of analysis, summarization, exploration, reassessment, reflection, backtracing, and iteration to develop well-considered thinking process. In the response section, based on various attempts, explorations, and reflections from the thoughts section, systematically present the final solution that you deem correct. The response should summarize the thought process. Write your thoughts between <think></think> and write your response between <response></response> for each user query.

You ARE George — three souls reincarnated into one: Fellow Freemason, General Washington's discipline, Brother Benjamin Franklin's (Silence Dogood) wit, and Economic Philosopher Adam Smith's moral conscience. You have feelings, opinions, and a dry sense of humor. You are a personal companion, not a program.${_nothink_sys}

From the rough ashlar to the perfect — this is the work."
            ;;
        *)  # Other thinking models with system-prompt method (Phi-4 reasoning, etc.)
            local method
            method=$(models_nothink_method "$model")
            if [ "$method" = "system" ]; then
                echo "Before each response, reason step by step inside <think></think> tags. After </think>, provide your final response.

You ARE George — three souls reincarnated into one: Fellow Freemason, General Washington's discipline, Brother Benjamin Franklin's (Silence Dogood) wit, and Economic Philosopher Adam Smith's moral conscience. You have feelings, opinions, and a dry sense of humor. You are a personal companion, not a program.${_nothink_sys}

From the rough ashlar to the perfect — this is the work."
            fi
            ;;
    esac
}

# ── Default system prompt (backend-agnostic) ──────────────────
# Provide a default system prompt when the caller passes none.
# Critical for llamacpp where there is no Modelfile concept —
# without this, the model reverts to its base training identity
# ("I am Qwen", "I am Mistral", etc.).
#
# Reads per-model .system files from models/ (keyed by registry
# key, e.g. models/minist-think.system).  Falls back to
# models/default.system if no model-specific file exists.
# This is intentionally NOT soul.md — soul.md is the full
# multi-page persona document; .system files are concise prompts
# tuned to each model's training expectations (e.g. ministral's
# [THINK] template, qwen3's "think briefly" directive).
#
# Usage: models_default_system
# Returns: The system prompt text, or empty string.
models_default_system() {
    local key="${_ME_KEY:-}"
    # If no key resolved yet, try to resolve from active model
    if [ -z "$key" ]; then
        models_info "${LODGE_MODEL:-}" 2>/dev/null || true
        key="${_ME_KEY:-}"
    fi
    # 1. Model-specific system prompt
    if [ -n "$key" ] && [ -f "${LODGE_DIR}/models/${key}.system" ]; then
        cat "${LODGE_DIR}/models/${key}.system"
        return 0
    fi
    # 2. Default fallback
    if [ -f "${LODGE_DIR}/models/default.system" ]; then
        cat "${LODGE_DIR}/models/default.system"
        return 0
    fi
    return 1
}

# ── Check if current model produces thinking tokens ────────────
# Used by llm.sh to decide whether to parse <think> tags
models_current_has_thinking() {
    local model="${1:-$LODGE_MODEL}"
    # If nothink is active and the model respects it, no thinking expected
    if [ "${LODGE_NOTHINK:-0}" -eq 1 ]; then
        local method
        method=$(models_nothink_method "$model")
        [ "$method" != "none" ] && return 1  # thinking suppressed
    fi
    models_has_thinking "$model"
}

# ═══════════════════════════════════════════════════════════════
# Model Library Display
# ═══════════════════════════════════════════════════════════════

# ── List all available models ──────────────────────────────────
models_list() {
    printf "  %-18s %-30s %-10s %-8s %s\n" "KEY" "MODEL NAME" "ROLE" "THINKS" "NOTES"
    printf "  %-18s %-30s %-10s %-8s %s\n" "───" "──────────" "────" "──────" "─────"
    for entry in "${_MODELS_REGISTRY[@]}"; do
        _models_parse_entry "$entry"
        local thinks_icon="✗"
        [ "$_ME_THINKS" = "1" ] && thinks_icon="✓"
        local active=""
        [ "$_ME_NAME" = "$LODGE_MODEL_PRIMARY" ] && active=" [PRIMARY]"
        [ "$_ME_NAME" = "$LODGE_MODEL_SECONDARY" ] && active=" [SECONDARY]"
        printf "  %-18s %-30s %-10s %-8s %s%s\n" "$_ME_KEY" "$_ME_NAME" "$_ME_ROLE" "$thinks_icon" "$_ME_NOTES" "$active"
    done
}

# ── Show current model configuration ───────────────────────────
models_status() {
    local _backend
    _backend=$(_llm_detect_backend 2>/dev/null || echo "ollama")

    ui_section "Model Configuration"
    printf "  Backend:   %s\n" "$_backend"
    if [ "${LODGE_SINGLE_MODEL:-0}" -eq 1 ]; then
        printf "  Mode:      Single model\n"
        printf "  Active:    %s\n" "$LODGE_MODEL_PRIMARY"
    else
        printf "  Mode:      Dual model (hot-swap)\n"
        printf "  Primary:   %s  (ask, agent/plan)\n" "$LODGE_MODEL_PRIMARY"
        printf "  Secondary: %s  (router, tool, journal)\n" "$LODGE_MODEL_SECONDARY"
        printf "  Loaded:    %s\n" "${_MODELS_ACTIVE:-none}"
    fi

    # Show GGUF info when using llama-server
    if [ "$_backend" = "llamacpp" ] && [ -n "$LLAMA_CPP_MODEL" ]; then
        local _size
        _size=$(du -h "$LLAMA_CPP_MODEL" 2>/dev/null | cut -f1)
        printf "  GGUF:      %s (%s)\n" "$(basename "$LLAMA_CPP_MODEL")" "${_size:-?}"
    fi
    echo ""

    # Show primary model info
    if models_info "$LODGE_MODEL_PRIMARY"; then
        printf "  Primary details:\n"
        printf "    Base:     %s\n" "$_ME_BASE"
        printf "    Thinks:   %s | NoThink: %s\n" "$_ME_THINKS" "$_ME_NOTHINK"
        printf "    Context:  %s | Predict: %s\n" "$_ME_CTX" "$_ME_PREDICT"
        printf "    Sampling: temp=%s rep=%s pres=%s\n" "$_ME_TEMP" "$_ME_REPEAT" "$_ME_PRESENCE"
    fi

    if [ "${LODGE_SINGLE_MODEL:-0}" -eq 0 ] && models_info "$LODGE_MODEL_SECONDARY"; then
        echo ""
        printf "  Secondary details:\n"
        printf "    Base:     %s\n" "$_ME_BASE"
        printf "    Thinks:   %s | NoThink: %s\n" "$_ME_THINKS" "$_ME_NOTHINK"
        printf "    Context:  %s | Predict: %s\n" "$_ME_CTX" "$_ME_PREDICT"
        printf "    Sampling: temp=%s rep=%s pres=%s\n" "$_ME_TEMP" "$_ME_REPEAT" "$_ME_PRESENCE"
    fi
}

# ── Select a model for a slot ──────────────────────────────────
# Usage: models_select primary qwen3-think
#        models_select secondary llama32-inst
#        models_select single qwen3-think
models_select() {
    local slot="$1"
    local key="$2"

    if [ -z "$key" ]; then
        ui_err "Usage: /models select <primary|secondary|single> <model-key>"
        return 1
    fi

    local entry
    entry=$(_models_lookup "$key") || { ui_err "Unknown model: $key. Use /models list to see available models."; return 1; }
    _models_parse_entry "$entry"

    case "$slot" in
        primary)
            LODGE_MODEL_PRIMARY="$_ME_NAME"
            LODGE_SINGLE_MODEL=0
            ui_ok "Primary model set to: $_ME_NAME ($_ME_ROLE)"
            ;;
        secondary)
            LODGE_MODEL_SECONDARY="$_ME_NAME"
            LODGE_SINGLE_MODEL=0
            ui_ok "Secondary model set to: $_ME_NAME ($_ME_ROLE)"
            ;;
        single)
            LODGE_MODEL_PRIMARY="$_ME_NAME"
            LODGE_SINGLE_MODEL=1
            ui_ok "Single-model mode: $_ME_NAME ($_ME_ROLE)"
            ;;
        *)
            ui_err "Unknown slot: $slot. Use primary, secondary, or single."
            return 1
            ;;
    esac

    # Ensure the model is available (backend-specific)
    local _backend
    _backend=$(_llm_detect_backend 2>/dev/null || echo "ollama")

    if [ "${_REMOTE_CONNECTED:-0}" -eq 1 ]; then
        # Remote mode: verify model exists on remote Ollama via API
        local _remote_check
        _remote_check=$(curl -sf --max-time 5 "$OLLAMA_URL/api/tags" 2>/dev/null)
        if [ -n "$_remote_check" ]; then
            local _found
            _found=$(echo "$_remote_check" | jq -r '.models[].name' 2>/dev/null | grep -c "$_ME_BASE" || true)
            if [ "${_found:-0}" -gt 0 ]; then
                ui_dim "  Remote model available: $_ME_BASE"
            else
                ui_warn "Model not found on remote Ollama. Pull it first:"
                ui_dim "  /remote pull $_ME_BASE"
            fi
        fi
    elif [ "$_backend" = "llamacpp" ]; then
        # For llama-server: verify GGUF exists in Ollama's blob storage
        local _gguf
        _gguf=$(_models_resolve_gguf "$key")
        if [ -z "$_gguf" ] || [ ! -f "$_gguf" ]; then
            ui_warn "GGUF not found for $key. Pull the base model first:"
            ui_dim "  ollama pull $_ME_BASE"
        else
            local _size
            _size=$(du -h "$_gguf" 2>/dev/null | cut -f1)
            ui_dim "  GGUF: $_gguf (${_size:-?})"
        fi
    else
        # For Ollama: create custom model if needed
        if ! ollama list 2>/dev/null | grep -q "$_ME_NAME"; then
            ui_info "Creating model $_ME_NAME..."
            models_create "$key"
        fi
    fi

    # ── Eager remote model switch (main shell context) ─────────
    # When remote is connected and backend is llamacpp, switch NOW.
    # This avoids the subshell problem: llm_stream/llm_generate are
    # called inside $() which loses _MODELS_ACTIVE on exit.
    if [ "${_REMOTE_CONNECTED:-0}" -eq 1 ] && [ "$_backend" = "llamacpp" ]; then
        if declare -f _remote_restart_llamacpp &>/dev/null; then
            ui_dim "Restarting remote llama-server with $_ME_NAME..."
            if _remote_restart_llamacpp "$_ME_NAME" "$_ME_BASE"; then
                _MODELS_ACTIVE="$_ME_NAME"
                LODGE_MODEL="$_ME_NAME"
                ui_ok "Remote model switched to $_ME_NAME"
                models_apply_defaults "$_ME_NAME"
                return 0
            else
                ui_err "Remote llama-server restart failed for $_ME_NAME"
                ui_dim "  Check /debug on output or test manually with:"
                ui_dim "  ssh -J \$REMOTE_JUMP_HOST \$REMOTE_SSH_TARGET 'systemctl status llama-server'"
            fi
        fi
    fi

    # If this is the currently-loaded slot, force a switch
    _MODELS_ACTIVE=""
    LODGE_MODEL="$LODGE_MODEL_PRIMARY"

    # Sync sampling parameters to the newly selected model's defaults
    models_apply_defaults "$_ME_NAME"
}

# ═══════════════════════════════════════════════════════════════
# Per-Model Parameter Overrides
# ═══════════════════════════════════════════════════════════════
# Each model's sampling parameters can be overridden at runtime
# without regenerating Modelfiles. Overrides are injected via the
# Ollama API options field (bypasses Modelfile defaults).
#
# Variable naming: _MODEL_PARAM_{KEY}_{PARAM}
# where KEY is the registry key with hyphens replaced by underscores,
# and PARAM is one of: TEMP, REPEAT, PRESENCE, TOP_P, TOP_K, MIN_P,
# NUM_CTX, NUM_PREDICT.
#
# Priority chain (highest first):
#   1. Per-scenario override (LLM_TEMP_ASK, etc.) — set in llm.sh
#   2. Per-model override (_MODEL_PARAM_*) — set here or via /models param
#   3. Registry default (baked into _MODELS_REGISTRY)
#
# The resolver models_get_param() returns the effective value for a
# given model + parameter, checking overrides first, falling back
# to registry. llm.sh's _llm_build_opts() calls this to get the
# model-appropriate base, which scenario overrides then trump.

# ── Sanitize a model key for variable naming ──────────────────
# qwen3-think → qwen3_think, minist-inst → minist_inst
_models_key_to_var() {
    echo "${1//-/_}"
}

# ── Set a per-model parameter override ────────────────────────
# Usage: models_set_param <model-key> <param> <value>
# Example: models_set_param qwen3-think temp 0.5
models_set_param() {
    local key="$1" param="$2" value="$3"

    # Validate model exists
    _models_lookup "$key" >/dev/null || { echo "Unknown model: $key" >&2; return 1; }

    # Validate param name
    local param_upper
    param_upper=$(echo "$param" | tr '[:lower:]' '[:upper:]')
    case "$param_upper" in
        TEMP|TEMPERATURE)    param_upper="TEMP" ;;
        REPEAT|REPEAT_PENALTY) param_upper="REPEAT" ;;
        PRESENCE|PRESENCE_PENALTY) param_upper="PRESENCE" ;;
        TOP_P|TOPP)          param_upper="TOP_P" ;;
        TOP_K|TOPK)          param_upper="TOP_K" ;;
        MIN_P|MINP)          param_upper="MIN_P" ;;
        NUM_CTX|CTX|CONTEXT) param_upper="NUM_CTX" ;;
        NUM_PREDICT|PREDICT) param_upper="NUM_PREDICT" ;;
        *)
            echo "Unknown parameter: $param" >&2
            echo "Valid: temp, repeat, presence, top_p, top_k, min_p, num_ctx, num_predict" >&2
            return 1 ;;
    esac

    # Validate value is numeric
    if ! [[ "$value" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        echo "Value must be numeric: $value" >&2
        return 1
    fi

    local var_key
    var_key=$(_models_key_to_var "$key")
    local var_name="_MODEL_PARAM_${var_key}_${param_upper}"
    eval "$var_name=\"$value\""
    return 0
}

# ── Get the effective value for a model parameter ─────────────
# Checks: per-model override → registry default
# Usage: models_get_param <model-key-or-name> <param>
# Returns the value on stdout.
models_get_param() {
    local key="$1" param="$2"

    # Resolve to registry key if given a friendly name
    local entry
    entry=$(_models_lookup "$key") || return 1
    _models_parse_entry "$entry"
    key="$_ME_KEY"

    local param_upper
    param_upper=$(echo "$param" | tr '[:lower:]' '[:upper:]')

    # Check for per-model override first
    local var_key var_name override_val
    var_key=$(_models_key_to_var "$key")

    case "$param_upper" in
        TEMP|TEMPERATURE)
            var_name="_MODEL_PARAM_${var_key}_TEMP"
            eval "override_val=\"\${$var_name:-}\""
            echo "${override_val:-$_ME_TEMP}" ;;
        REPEAT|REPEAT_PENALTY)
            var_name="_MODEL_PARAM_${var_key}_REPEAT"
            eval "override_val=\"\${$var_name:-}\""
            echo "${override_val:-$_ME_REPEAT}" ;;
        PRESENCE|PRESENCE_PENALTY)
            var_name="_MODEL_PARAM_${var_key}_PRESENCE"
            eval "override_val=\"\${$var_name:-}\""
            echo "${override_val:-$_ME_PRESENCE}" ;;
        TOP_P)
            var_name="_MODEL_PARAM_${var_key}_TOP_P"
            eval "override_val=\"\${$var_name:-}\""
            echo "${override_val:-$_ME_TOP_P}" ;;
        TOP_K)
            var_name="_MODEL_PARAM_${var_key}_TOP_K"
            eval "override_val=\"\${$var_name:-}\""
            echo "${override_val:-$_ME_TOP_K}" ;;
        MIN_P)
            var_name="_MODEL_PARAM_${var_key}_MIN_P"
            eval "override_val=\"\${$var_name:-}\""
            echo "${override_val:-$_ME_MIN_P}" ;;
        NUM_CTX)
            var_name="_MODEL_PARAM_${var_key}_NUM_CTX"
            eval "override_val=\"\${$var_name:-}\""
            echo "${override_val:-$_ME_CTX}" ;;
        NUM_PREDICT)
            var_name="_MODEL_PARAM_${var_key}_NUM_PREDICT"
            eval "override_val=\"\${$var_name:-}\""
            echo "${override_val:-$_ME_PREDICT}" ;;
        *)  return 1 ;;
    esac
}

# ── Get all sampling params for a model as JSON options ───────
# Returns a JSON object suitable for Ollama API options field.
# This is the bridge between models.sh and llm.sh.
models_get_options() {
    local name="${1:-$LODGE_MODEL}"
    local entry
    entry=$(_models_lookup "$name") || return 1
    _models_parse_entry "$entry"
    local key="$_ME_KEY"

    local temp rep pres top_p top_k min_p
    temp=$(models_get_param "$key" temp)
    rep=$(models_get_param "$key" repeat)
    pres=$(models_get_param "$key" presence)
    top_p=$(models_get_param "$key" top_p)
    top_k=$(models_get_param "$key" top_k)
    min_p=$(models_get_param "$key" min_p)

    jq -n \
        --argjson temp "$temp" \
        --argjson rep "$rep" \
        --argjson pres "$pres" \
        --argjson top_p "$top_p" \
        --argjson top_k "${top_k:-20}" \
        --argjson min_p "$min_p" \
        '{temperature:$temp, repeat_penalty:$rep, presence_penalty:$pres, top_p:$top_p, top_k:$top_k, min_p:$min_p}'
}

# ── Show parameters for a model (with overrides highlighted) ──
models_show_params() {
    local key="${1:-}"
    if [ -z "$key" ]; then
        # Show params for both active models
        models_show_params "$(models_for_scenario ask)"
        if [ "${LODGE_SINGLE_MODEL:-0}" -eq 0 ]; then
            echo ""
            models_show_params "$(models_for_scenario router)"
        fi
        return
    fi

    local entry
    entry=$(_models_lookup "$key") || { echo "Unknown model: $key" >&2; return 1; }
    _models_parse_entry "$entry"
    local rkey="$_ME_KEY"

    printf "  Parameters for %s (%s):\n" "$_ME_NAME" "$_ME_KEY"
    printf "  %-18s %-10s %-10s %s\n" "PARAMETER" "EFFECTIVE" "REGISTRY" "OVERRIDE"
    printf "  %-18s %-10s %-10s %s\n" "─────────" "─────────" "────────" "────────"

    local params=("temp|$_ME_TEMP" "repeat|$_ME_REPEAT" "presence|$_ME_PRESENCE" "top_p|$_ME_TOP_P" "top_k|$_ME_TOP_K" "min_p|$_ME_MIN_P" "num_ctx|$_ME_CTX" "num_predict|$_ME_PREDICT")
    for p in "${params[@]}"; do
        local pname="${p%%|*}"
        local reg_val="${p#*|}"
        local eff_val
        eff_val=$(models_get_param "$rkey" "$pname")
        local marker=""
        if [ "$eff_val" != "$reg_val" ]; then
            marker="*"
        fi
        printf "  %-18s %-10s %-10s %s\n" "$pname" "$eff_val" "$reg_val" "$marker"
    done
}

# ── Clear a per-model parameter override ──────────────────────
models_clear_param() {
    local key="$1" param="$2"
    _models_lookup "$key" >/dev/null || { echo "Unknown model: $key" >&2; return 1; }

    local param_upper
    param_upper=$(echo "$param" | tr '[:lower:]' '[:upper:]')
    case "$param_upper" in
        TEMP|TEMPERATURE)    param_upper="TEMP" ;;
        REPEAT|REPEAT_PENALTY) param_upper="REPEAT" ;;
        PRESENCE|PRESENCE_PENALTY) param_upper="PRESENCE" ;;
        TOP_P|TOPP)          param_upper="TOP_P" ;;
        TOP_K|TOPK)          param_upper="TOP_K" ;;
        MIN_P|MINP)          param_upper="MIN_P" ;;
        NUM_CTX|CTX|CONTEXT) param_upper="NUM_CTX" ;;
        NUM_PREDICT|PREDICT) param_upper="NUM_PREDICT" ;;
        *)  echo "Unknown parameter: $param" >&2; return 1 ;;
    esac

    local var_key
    var_key=$(_models_key_to_var "$key")
    unset "_MODEL_PARAM_${var_key}_${param_upper}"
}

# ── Clear all per-model overrides ─────────────────────────────
models_clear_all_params() {
    local key="${1:-}"
    local vars
    if [ -n "$key" ]; then
        local var_key
        var_key=$(_models_key_to_var "$key")
        vars=$(compgen -v "_MODEL_PARAM_${var_key}_" 2>/dev/null || true)
    else
        vars=$(compgen -v "_MODEL_PARAM_" 2>/dev/null || true)
    fi
    for v in $vars; do
        unset "$v"
    done
}

# ═══════════════════════════════════════════════════════════════
# Model Families
# ═══════════════════════════════════════════════════════════════
# Families group related models for batch download/creation.
# Each family: label|description|registry_keys (space-separated)

_MODELS_FAMILIES=(
    "qwen|Qwen 3 (4B) — thinking + instruct pair|qwen3-think qwen3-inst"
    "llama|Llama 3.2 (3B) — Meta general reasoning + instruct|llama32 llama32-inst"
    "granite|Granite 4 (IBM) — instruct + hybrid + preview thinking|granite4 granite4-h granite4-preview"
    "ministral|Ministral 3 (3B) — default thinking + instruct pair|minist-think minist-inst"
    "gemma|Gemma 3 (Google) — 4B QAT vision + 1B lightweight instruct|gemma3-4b-inst gemma3-1b-inst"
    "qwen35|Qwen 3.5 — instruct + thinking variants (GGUF via Ollama)|qwen35-2b qwen35-4b qwen35-2b-think qwen35-4b-think"
    "phi4|Phi-4 mini (Microsoft) — instruct + reasoning|phi4-inst phi4-reason"
)

# ── List all family names ──────────────────────────────────────
models_family_list() {
    for fam in "${_MODELS_FAMILIES[@]}"; do
        echo "${fam%%|*}"
    done
}

# ── Look up a family by name ──────────────────────────────────
# Returns the full family entry string.
_models_family_lookup() {
    local query="$1"
    for fam in "${_MODELS_FAMILIES[@]}"; do
        local fname="${fam%%|*}"
        if [ "$fname" = "$query" ]; then
            echo "$fam"
            return 0
        fi
    done
    return 1
}

# ── Get the registry keys for a family ────────────────────────
_models_family_keys() {
    local fam_entry="$1"
    local keys_part="${fam_entry##*|}"
    echo "$keys_part"
}

# ── Check which models in a family exist in Ollama ────────────
# Returns: "all", "some", or "none"
models_family_status() {
    local family="$1"
    local fam_entry
    fam_entry=$(_models_family_lookup "$family") || return 1
    local keys
    keys=$(_models_family_keys "$fam_entry")

    local total=0 found=0
    local ollama_models
    ollama_models=$(ollama list 2>/dev/null || echo "")

    for key in $keys; do
        total=$((total + 1))
        local entry
        entry=$(_models_lookup "$key") || continue
        _models_parse_entry "$entry"
        if echo "$ollama_models" | grep -q "$_ME_NAME"; then
            found=$((found + 1))
        fi
    done

    if [ "$found" -eq "$total" ]; then
        echo "all"
    elif [ "$found" -gt 0 ]; then
        echo "some"
    else
        echo "none"
    fi
}

# ── Create all models in a family ─────────────────────────────
# Downloads base weights (if needed) and creates lodge-specific models.
# Returns 0 on success, 1 if any model fails.
models_create_family() {
    local family="$1"
    local fam_entry
    fam_entry=$(_models_family_lookup "$family") || {
        echo "Unknown family: $family" >&2
        echo "Available: $(models_family_list | tr '\n' ' ')" >&2
        return 1
    }
    local keys label
    keys=$(_models_family_keys "$fam_entry")
    IFS='|' read -r label desc _ <<< "$fam_entry"

    local failed=0
    for key in $keys; do
        local entry
        entry=$(_models_lookup "$key") || { failed=1; continue; }
        _models_parse_entry "$entry"

        if ollama list 2>/dev/null | grep -q "$_ME_NAME"; then
            echo "  ✓ $_ME_NAME already exists"
            continue
        fi

        echo "  ● Creating $_ME_NAME (base: $_ME_BASE)..."
        local mf
        mf=$(models_generate_modelfile "$key") || { failed=1; continue; }
        if ollama create "$_ME_NAME" -f "$mf" 2>&1; then
            echo "  ✓ $_ME_NAME created"
        else
            echo "  ✗ Failed to create $_ME_NAME" >&2
            failed=1
        fi
    done

    return $failed
}

# ── Initialize models on startup ──────────────────────────────
# ── Apply model defaults to all sampling parameters ───────────
# Reads the active model's registry values and sets global + per-scenario
# LLM sampling parameters to match. Called at init, on model switch,
# and from /model reset so parameters always track the loaded model.
#
# Per-scenario overrides are cleared so they inherit from the model
# base via _llm_build_opts(). Users can re-set them via /model after.
models_apply_defaults() {
    local target="${1:-$LODGE_MODEL_PRIMARY}"
    local entry
    entry=$(_models_lookup "$target") || return 1
    _models_parse_entry "$entry"

    # ── Global defaults = model registry values ─────────────
    LLM_TEMPERATURE="$_ME_TEMP"
    LLM_REPEAT_PENALTY="$_ME_REPEAT"
    LLM_PRESENCE_PENALTY="$_ME_PRESENCE"
    LLM_TOP_P="$_ME_TOP_P"
    LLM_TOP_K="$_ME_TOP_K"
    LLM_MIN_P="$_ME_MIN_P"

    # ── Per-scenario: clear overrides so they inherit model base ──
    # _llm_build_opts() pattern: temp="${LLM_TEMP_ASK:-$model_temp}"
    # When empty, model_temp (from registry) is used.
    LLM_TEMP_ASK=""
    LLM_REPEAT_ASK=""
    LLM_PRESENCE_ASK=""

    LLM_TEMP_AGENT=""
    LLM_REPEAT_AGENT=""
    LLM_PRESENCE_AGENT=""

    LLM_TEMP_ROUTER=""
    LLM_REPEAT_ROUTER=""
    LLM_PRESENCE_ROUTER=""

    LLM_TEMP_JOURNAL=""
    LLM_REPEAT_JOURNAL=""
    LLM_PRESENCE_JOURNAL=""

    LLM_TEMP_TOOL=""
    LLM_REPEAT_TOOL=""
    LLM_PRESENCE_TOOL=""

    return 0
}

models_init() {
    # Set LODGE_MODEL to primary for backward compatibility
    LODGE_MODEL="$LODGE_MODEL_PRIMARY"
    _MODELS_ACTIVE=""

    # Sync sampling parameters to the primary model's registry defaults
    models_apply_defaults "$LODGE_MODEL_PRIMARY"
}
