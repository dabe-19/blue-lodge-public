#!/usr/bin/env bash
# ── start_prism.sh: Sovereign PRISM Inference Runner ──
set -euo pipefail

TARGET_MODEL="${LLAMA_ARG_MODEL:-/models/active/current/base.gguf}"
[ ! -f "$TARGET_MODEL" ] && TARGET_MODEL="/models/hub/huggingface/unsloth/gemma-4-31B-it-GGUF/gemma-4-31B-it-UD-Q4_K_XL.gguf"
[ ! -f "$TARGET_MODEL" ] && TARGET_MODEL="/models/frontier_qwen38/Qwen3.8-27B-UD-Q4_K_S.gguf"
[ ! -f "$TARGET_MODEL" ] && TARGET_MODEL="/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Internal-MTP-Calibrated.gguf"

if [ ! -f "$TARGET_MODEL" ]; then
    echo "[!] Error: No compatible model found at $TARGET_MODEL."
    exit 1
fi

echo "[+] Starting Sovereign CUDA server with $TARGET_MODEL..."

# Ensure WSL2 CUDA passthrough library directory is on LD_LIBRARY_PATH if mounted
if [ -d /usr/lib/wsl/lib ]; then
    export LD_LIBRARY_PATH="/usr/lib/wsl/lib:/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
fi

# Setup library paths (prefer stock llama-server when present, fallback to legacy prism binaries)
PRISM_BIN="/usr/local/bin/llama-server"
if [ ! -x "$PRISM_BIN" ]; then
    PRISM_BIN="/usr/local/bin/blue-llama-server"
fi
if [ ! -x "$PRISM_BIN" ]; then
    PRISM_BIN="/usr/local/bin/llama-server-prism"
fi
if [ -x /workspace/build_prism/llama.cpp-prism/build/bin/llama-server ]; then
    echo "[+] Using locally compiled engine from /workspace/build_prism/..."
    PRISM_BIN="/workspace/build_prism/llama.cpp-prism/build/bin/llama-server"
    export LD_LIBRARY_PATH="/workspace/build_prism/llama.cpp-prism/build/bin:/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
elif [ -x /opt/llama-prism-latest/bin/llama-server ]; then
    echo "[+] Using binary from /opt/llama-prism-latest/bin..."
    PRISM_BIN="/opt/llama-prism-latest/bin/llama-server"
    export LD_LIBRARY_PATH="/opt/llama-prism-latest/lib:/opt/llama-prism-latest:${LD_LIBRARY_PATH:-}"
fi
if [ -d /opt/llama.cpp/build/bin ]; then
    export LD_LIBRARY_PATH="/opt/llama.cpp/build/bin:${LD_LIBRARY_PATH:-}"
fi

# Chat template file resolution (only use external ChatML template for Qwen3.8/Champion unless explicitly requested)
CHAT_TEMPLATE="${LLAMA_ARG_CHAT_TEMPLATE:-}"
if [ -z "$CHAT_TEMPLATE" ] && ([[ "$TARGET_MODEL" == *"Qwen3.8"* ]] || [[ "$TARGET_MODEL" == *"Champion"* ]]); then
    CHAT_TEMPLATE="/models/active/current/jinja.template"
    [ ! -f "$CHAT_TEMPLATE" ] && CHAT_TEMPLATE="/models/frontier_qwen38/blue_lodge_jinja_template.jinja"
    [ ! -f "$CHAT_TEMPLATE" ] && CHAT_TEMPLATE="/workspace/configs/blue_lodge_jinja_template.jinja"
fi

# Kernel Optimizations:
export GGML_CUDA_BATCH_INVARIANT="${PRISM_BATCH_INVARIANT:-0}"

# Build arguments array
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

# LoRA Adapter Attachment
LORA_PATH="${LLAMA_ARG_LORA:-/models/active/current/champion.gguf}"
if [ ! -f "$LORA_PATH" ] && ([[ "$TARGET_MODEL" == *"Champion-v5"* ]] || [[ "$TARGET_MODEL" == *"Qwen3.8"* ]]); then
    if [ -f /models/frontier_qwen38/Blue-Llama-27B-Champion-v14-Fused-SVD32.gguf ]; then
        LORA_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v14-Fused-SVD32.gguf"
    elif [ -f /models/frontier_qwen38/Blue-Llama-27B-Champion-v14-Fused-LoRA.gguf ]; then
        LORA_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v14-Fused-LoRA.gguf"
    elif [ -f /models/frontier_qwen38/Blue-Llama-27B-Champion-v13-Fused-SVD32.gguf ]; then
        LORA_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v13-Fused-SVD32.gguf"
    elif [ -f /models/frontier_qwen38/Blue-Llama-27B-Champion-v13-Fused-LoRA.gguf ]; then
        LORA_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v13-Fused-LoRA.gguf"
    elif [ -f /models/frontier_qwen38/Blue-Llama-27B-Champion-v12-Fused-SVD32.gguf ]; then
        LORA_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v12-Fused-SVD32.gguf"
    elif [ -f /models/frontier_qwen38/Blue-Llama-27B-Champion-v12-Fused-LoRA.gguf ]; then
        LORA_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v12-Fused-LoRA.gguf"
    elif [ -f /models/frontier_qwen38/Blue-Llama-27B-Champion-v11-Fused-SVD32.gguf ]; then
        LORA_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v11-Fused-SVD32.gguf"
    elif [ -f /models/frontier_qwen38/Blue-Llama-27B-Champion-v11-Fused-LoRA.gguf ]; then
        LORA_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v11-Fused-LoRA.gguf"
    elif [ -f /models/frontier_qwen38/Blue-Llama-27B-Champion-v10-Fused-SVD32.gguf ]; then
        LORA_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v10-Fused-SVD32.gguf"
    elif [ -f /models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration9-Fused-LoRA.gguf ]; then
        LORA_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration9-Fused-LoRA.gguf"
    elif [ -f /models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration9-Fused-SVD32.gguf ]; then
        LORA_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration9-Fused-SVD32.gguf"
    elif [ -f /models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration8-Fused-LoRA.gguf ]; then
        LORA_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration8-Fused-LoRA.gguf"
    elif [ -f /models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration8-Fused-SVD32.gguf ]; then
        LORA_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration8-Fused-SVD32.gguf"
    elif [ "${USE_SVD16:-0}" = "1" ] && [ -f /models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration7-Fused-SVD16.gguf ]; then
        LORA_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration7-Fused-SVD16.gguf"
    elif [ -f /models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration7-Fused-LoRA.gguf ]; then
        LORA_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration7-Fused-LoRA.gguf"
    elif [ -f /models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration6-Weighted-SVD16.gguf ]; then
        LORA_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration6-Weighted-SVD16.gguf"
    elif [ "${USE_SVD16:-1}" = "1" ] && [ -f /models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration6-Fused-SVD16.gguf ]; then
        LORA_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration6-Fused-SVD16.gguf"
    elif [ -f /models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration6-Fused-LoRA.gguf ]; then
        LORA_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration6-Fused-LoRA.gguf"
    elif [ -f /models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration5-Fused-LoRA.gguf ]; then
        LORA_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration5-Fused-LoRA.gguf"
    elif [ -f /models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration4-Fused-LoRA.gguf ]; then
        LORA_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration4-Fused-LoRA.gguf"
    fi
fi
REAL_BASE_MODEL=$(readlink -f "$TARGET_MODEL" 2>/dev/null || echo "$TARGET_MODEL")
if [[ "$REAL_BASE_MODEL" == *"Baked"* ]] || [[ "$REAL_BASE_MODEL" == *"Merged"* ]] || [ -f "/models/active/current/.lora_baked" ]; then
    echo "[+] Base model ($REAL_BASE_MODEL) already has LoRA weights baked in — skipping runtime --lora attachment for full CUDA Graph speed."
elif [ -n "$LORA_PATH" ] && [ -f "$LORA_PATH" ]; then
    echo "[+] Attaching Fused LoRA Adapter: $LORA_PATH"
    ARGS+=("--lora" "$LORA_PATH")
fi

# Multimodal Vision Tower
MMPROJ_PATH="${LLAMA_ARG_MMPROJ:-/models/active/current/mmproj.gguf}"
[ ! -f "$MMPROJ_PATH" ] && [ -f "/models/frontier_qwen38/mmproj-BF16.gguf" ] && MMPROJ_PATH="/models/frontier_qwen38/mmproj-BF16.gguf"
[ ! -f "$MMPROJ_PATH" ] && MMPROJ_PATH="/models/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf"

if ([ "${ENABLE_VISION:-0}" = "1" ] || [ -f "/models/active/current/mmproj.gguf" ]) && [ -f "$MMPROJ_PATH" ]; then
    # GPU 1 (CUDA1) is the display-driving card (Windows DWM/desktop uses ~1.1 GB on CUDA1),
    # while GPU 0 (CUDA0) is headless with ~1.8 GB free. Keep the 889 MB vision tower on CUDA0
    # so CUDA1 never spills into WDDM Shared System Memory over PCIe.
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
REAL_TARGET=$(readlink -f "$TARGET_MODEL" 2>/dev/null || echo "$TARGET_MODEL")

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
    elif ([[ "$REAL_TARGET" == *"Internal-MTP"* ]] || [[ "$REAL_TARGET" == *"mtp-lean"* ]]); then
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

# Append any extra arguments passed directly to start_prism.sh (e.g. --lora-scaled from Model Hub)
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

echo "[+] Executing: $PRISM_BIN ${ARGS[*]}"
exec "$PRISM_BIN" "${ARGS[@]}"
