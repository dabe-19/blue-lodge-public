#!/usr/bin/env bash
# ── start_inference.sh: Sovereign Stock llama.cpp Inference Runner ──
# Launches upstream llama-server with native SPTQ/ternary, MTP, vision mmproj,
# and dynamic multi-role LoRA / SVD-32 hot-swapping (POST /lora-adapters).
set -euo pipefail

TARGET_MODEL="${LLAMA_ARG_MODEL:-/models/active/current/base.gguf}"
[ ! -f "$TARGET_MODEL" ] && TARGET_MODEL="/models/hub/huggingface/unsloth/gemma-4-31B-it-GGUF/gemma-4-31B-it-UD-Q4_K_XL.gguf"
[ ! -f "$TARGET_MODEL" ] && TARGET_MODEL="/models/frontier_qwen38/Qwen3.8-27B-UD-Q4_K_S.gguf"

if [ ! -f "$TARGET_MODEL" ]; then
    echo "[!] Error: No compatible model found at $TARGET_MODEL."
    echo "    Set LLAMA_ARG_MODEL or activate a profile via the Model Workbench (/models)."
    exit 1
fi

echo "[+] Starting Sovereign llama.cpp server with $TARGET_MODEL..."

# Ensure WSL2 CUDA passthrough library directory is on LD_LIBRARY_PATH if mounted
if [ -d /usr/lib/wsl/lib ]; then
    export LD_LIBRARY_PATH="/usr/lib/wsl/lib:/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
fi

# Resolve stock llama-server binary
LLAMA_BIN="${LLAMA_CPP_SERVER_BIN:-/usr/local/bin/llama-server}"
if [ ! -x "$LLAMA_BIN" ] && [ -x /opt/llama.cpp/build/bin/llama-server ]; then
    LLAMA_BIN="/opt/llama.cpp/build/bin/llama-server"
fi
if [ ! -x "$LLAMA_BIN" ]; then
    LLAMA_BIN="$(command -v llama-server 2>/dev/null || true)"
fi
if [ -z "$LLAMA_BIN" ] || [ ! -x "$LLAMA_BIN" ]; then
    echo "[!] Error: stock llama-server binary not found."
    exit 1
fi
if [ -d /opt/llama.cpp/build/bin ]; then
    export LD_LIBRARY_PATH="/opt/llama.cpp/build/bin:${LD_LIBRARY_PATH:-}"
fi

# Chat template file resolution (external ChatML template for Qwen3.8/Champion when present)
CHAT_TEMPLATE="${LLAMA_ARG_CHAT_TEMPLATE:-}"
if [ -z "$CHAT_TEMPLATE" ] && ([[ "$TARGET_MODEL" == *"Qwen3.8"* ]] || [[ "$TARGET_MODEL" == *"Champion"* ]]); then
    CHAT_TEMPLATE="/models/active/current/jinja.template"
    [ ! -f "$CHAT_TEMPLATE" ] && CHAT_TEMPLATE="/models/frontier_qwen38/blue_lodge_jinja_template.jinja"
    [ ! -f "$CHAT_TEMPLATE" ] && CHAT_TEMPLATE="/workspace/configs/blue_lodge_jinja_template.jinja"
fi

# Display-safe Ampere/Blackwell CUDA kernel behavior
export GGML_CUDA_BATCH_INVARIANT="${LLAMA_BATCH_INVARIANT:-${PRISM_BATCH_INVARIANT:-0}}"

ARGS=(
    "-m" "$TARGET_MODEL"
    "--host" "${LLAMA_ARG_HOST:-0.0.0.0}"
    "--port" "${LLAMA_ARG_PORT:-8080}"
    "-c" "${LLAMA_ARG_CTX_SIZE:-98304}"
    "-np" "${LLAMA_ARG_N_PARALLEL:-1}"
    "-ngl" "${LLAMA_ARG_N_GPU_LAYERS:-999}"
    "-b" "${LLAMA_ARG_BATCH:-2048}"
    "-ub" "${LLAMA_ARG_UBATCH:-512}"
    "--flash-attn" "on"
    "-ctk" "${LLAMA_ARG_CACHE_TYPE_K:-${LLAMA_ARG_CTK:-q4_0}}"
    "-ctv" "${LLAMA_ARG_CACHE_TYPE_V:-${LLAMA_ARG_CTV:-q4_0}}"
    "--reasoning-budget" "${LLAMA_ARG_REASONING_BUDGET:-12288}"
    "--temp" "${LLAMA_ARG_TEMP:-1.0}"
    "--top-p" "${LLAMA_ARG_TOP_P:-0.95}"
    "--jinja"
)

if [ -n "$CHAT_TEMPLATE" ] && [ -f "$CHAT_TEMPLATE" ]; then
    ARGS+=("--chat-template-file" "$CHAT_TEMPLATE")
fi

if [[ "$TARGET_MODEL" == *"Qwen3.8"* ]] || [[ "$TARGET_MODEL" == *"Champion"* ]] || [ -n "${LLAMA_ARG_REASONING_FORMAT:-}" ]; then
    ARGS+=(
        "--reasoning" "${LLAMA_ARG_REASONING:-on}"
        "--reasoning-format" "${LLAMA_ARG_REASONING_FORMAT:-deepseek}"
    )
fi

# ── LoRA / SVD-32 Adapter Attachment & Multi-Role Hot-Swap Preloading ──
# Supports:
#   1. LLAMA_ARG_LORA_SCALED="pathA.gguf:1.0,pathB.gguf:0.0"  (hot-swappable via POST /lora-adapters)
#   2. LLAMA_ARG_LORA="/models/adapters/<model>/<role>/active.gguf" or /models/active/current/adapter.gguf
#   3. /models/active/current/adapters.conf (one "path[:scale]" per line for multi-role preloading)
REAL_BASE_MODEL=$(readlink -f "$TARGET_MODEL" 2>/dev/null || echo "$TARGET_MODEL")
if [[ "$REAL_BASE_MODEL" == *"Baked"* ]] || [[ "$REAL_BASE_MODEL" == *"Merged"* ]] || [ -f "/models/active/current/.lora_baked" ]; then
    echo "[+] Base model ($REAL_BASE_MODEL) already has LoRA weights baked in — skipping runtime --lora attachment."
elif [ -n "${LLAMA_ARG_LORA_SCALED:-}" ]; then
    echo "[+] Preloading hot-swappable LoRA/SVD adapters: ${LLAMA_ARG_LORA_SCALED}"
    ARGS+=("--lora-scaled" "${LLAMA_ARG_LORA_SCALED}")
    [ "${LLAMA_ARG_LORA_INIT_WITHOUT_APPLY:-0}" = "1" ] && ARGS+=("--lora-init-without-apply")
elif [ -f "/models/active/current/adapters.conf" ]; then
    _lora_csv=""
    while IFS= read -r _line; do
        _line="${_line%%#*}"
        _line="${_line#"${_line%%[![:space:]]*}"}"
        _line="${_line%"${_line##*[![:space:]]}"}"
        [ -z "$_line" ] && continue
        _p="${_line%%:*}"
        [ -f "$_p" ] || continue
        _lora_csv="${_lora_csv:+${_lora_csv},}${_line}"
    done < "/models/active/current/adapters.conf"
    if [ -n "$_lora_csv" ]; then
        echo "[+] Preloading multi-role LoRA/SVD adapters from adapters.conf: $_lora_csv"
        ARGS+=("--lora-scaled" "$_lora_csv")
    fi
else
    LORA_PATH="${LLAMA_ARG_LORA:-}"
    if [ -z "$LORA_PATH" ]; then
        if [ -f "/models/active/current/adapter.gguf" ]; then
            LORA_PATH="/models/active/current/adapter.gguf"
        elif [ -f "/models/active/current/champion.gguf" ]; then
            LORA_PATH="/models/active/current/champion.gguf"
        fi
    fi
    if [ -n "$LORA_PATH" ] && [ -f "$LORA_PATH" ]; then
        echo "[+] Attaching LoRA/SVD Adapter: $LORA_PATH"
        ARGS+=("--lora" "$LORA_PATH")
    fi
fi

# Multimodal Vision Tower
MMPROJ_PATH="${LLAMA_ARG_MMPROJ:-/models/active/current/mmproj.gguf}"
[ ! -f "$MMPROJ_PATH" ] && [ -f "/models/frontier_qwen38/mmproj-BF16.gguf" ] && MMPROJ_PATH="/models/frontier_qwen38/mmproj-BF16.gguf"

if ([ "${ENABLE_VISION:-0}" = "1" ] || [ -f "/models/active/current/mmproj.gguf" ]) && [ -f "$MMPROJ_PATH" ]; then
    if [ -z "${MTMD_BACKEND_DEVICE:-}" ] && [[ "${LLAMA_ARG_TENSOR_SPLIT:-}" == *","* ]]; then
        export MTMD_BACKEND_DEVICE="CUDA0"
    fi
    echo "[+] Offloading Multimodal Vision Tower ($MMPROJ_PATH) [device=${MTMD_BACKEND_DEVICE:-CUDA0}, max_tokens=${LLAMA_ARG_IMAGE_MAX_TOKENS:-1024}]..."
    ARGS+=(
        "--mmproj" "$MMPROJ_PATH"
        "--mmproj-offload"
        "--image-min-tokens" "${LLAMA_ARG_IMAGE_MIN_TOKENS:-256}"
        "--image-max-tokens" "${LLAMA_ARG_IMAGE_MAX_TOKENS:-1024}"
    )
else
    echo "[+] Multimodal Vision Tower disabled for this node."
fi

# Speculative Decoding (MTP Draft Layer)
DRAFT_PATH="${LLAMA_ARG_MODEL_DRAFT:-${LLAMA_ARG_DRAFT:-/models/active/current/draft.gguf}}"
if [ "${ENABLE_MTP:-0}" = "1" ] || [ -n "${LLAMA_ARG_MODEL_DRAFT:-}" ] || [ "${LLAMA_ARG_SPEC_TYPE:-}" = "draft-mtp" ]; then
    if [ -n "$DRAFT_PATH" ] && [ -f "$DRAFT_PATH" ]; then
        DRAFT_N_MAX="${LLAMA_ARG_SPEC_DRAFT_N_MAX:-${LLAMA_ARG_DRAFT_MAX:-4}}"
        echo "[+] Enabling External MTP Draft Speculative Decoding: $DRAFT_PATH (n-max ${DRAFT_N_MAX})"
        ARGS+=(
            "--model-draft" "$DRAFT_PATH"
            "--spec-type" "${LLAMA_ARG_SPEC_TYPE:-draft-mtp}"
            "--spec-draft-n-max" "$DRAFT_N_MAX"
            "-ngld" "999"
        )
    elif ([[ "$REAL_BASE_MODEL" == *"Internal-MTP"* ]] || [[ "$REAL_BASE_MODEL" == *"mtp-lean"* ]]); then
        DRAFT_N_MAX="${LLAMA_ARG_SPEC_DRAFT_N_MAX:-3}"
        DRAFT_P_MIN="${LLAMA_ARG_SPEC_DRAFT_P_MIN:-0.70}"
        echo "[+] Enabling Native Internal MTP Speculative Decoding (draft-mtp, n-max ${DRAFT_N_MAX}, p-min ${DRAFT_P_MIN})..."
        ARGS+=(
            "--spec-type" "draft-mtp"
            "--spec-draft-n-max" "$DRAFT_N_MAX"
            "--spec-draft-p-min" "$DRAFT_P_MIN"
            "--spec-draft-ngl" "99"
        )
    fi
fi

# Append any extra arguments passed directly (e.g. --lora-scaled from Model Hub)
if [ $# -gt 0 ]; then
    ARGS+=("$@")
fi

# Multi-GPU Tensor Split if requested
if [ -n "${LLAMA_ARG_TENSOR_SPLIT:-}" ]; then
    echo "[+] Applying Tensor Split: $LLAMA_ARG_TENSOR_SPLIT"
    ARGS+=(
        "--tensor-split" "$LLAMA_ARG_TENSOR_SPLIT"
        "-sm" "layer"
    )
fi

echo "[+] Executing: $LLAMA_BIN ${ARGS[*]}"
exec "$LLAMA_BIN" "${ARGS[@]}"
