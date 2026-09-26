#!/usr/bin/env bash
# ── start_prism.sh: Sovereign PRISM Inference Runner ──
set -euo pipefail

TARGET_MODEL="${LLAMA_ARG_MODEL:-/models/frontier_qwen38/Blue-Llama-27B-Champion-v5.gguf}"
[ ! -f "$TARGET_MODEL" ] && TARGET_MODEL="/models/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf"
[ ! -f "$TARGET_MODEL" ] && TARGET_MODEL="/models/Ternary-Bonsai-2-27B-PTQ1_0.gguf"

if [ ! -f "$TARGET_MODEL" ]; then
    echo "[!] Error: No compatible model found at $TARGET_MODEL."
    exit 1
fi

echo "[+] Starting PRISM CUDA server with $TARGET_MODEL..."

# Setup library paths
PRISM_BIN="/usr/local/bin/blue-llama-server"
if [ ! -x "$PRISM_BIN" ]; then
    PRISM_BIN="/usr/local/bin/llama-server-prism"
fi
if [ -x /workspace/build_prism/llama.cpp-prism/build/bin/llama-server ]; then
    echo "[+] Using locally compiled PRISM engine with SPTQ support from /workspace/build_prism/..."
    PRISM_BIN="/workspace/build_prism/llama.cpp-prism/build/bin/llama-server"
    export LD_LIBRARY_PATH="/workspace/build_prism/llama.cpp-prism/build/bin:/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
elif [ -x /opt/llama-prism-latest/bin/llama-server ]; then
    echo "[+] Using optimized PRISM binary from /opt/llama-prism-latest/bin..."
    PRISM_BIN="/opt/llama-prism-latest/bin/llama-server"
    export LD_LIBRARY_PATH="/opt/llama-prism-latest/lib:/opt/llama-prism-latest:${LD_LIBRARY_PATH:-}"
fi

# Build arguments array
ARGS=(
    "-m" "$TARGET_MODEL"
    "--host" "${LLAMA_ARG_HOST:-0.0.0.0}"
    "--port" "${LLAMA_ARG_PORT:-8080}"
    "-c" "${LLAMA_ARG_CTX_SIZE:-262144}"
    "-np" "${LLAMA_ARG_N_PARALLEL:-1}"
    "-ngl" "${LLAMA_ARG_N_GPU_LAYERS:-99}"
    "-b" "${LLAMA_ARG_BATCH:-2048}"
    "-ub" "${LLAMA_ARG_UBATCH:-1024}"
    "--flash-attn" "on"
    "-ctk" "${LLAMA_ARG_CTK:-q4_0}"
    "-ctv" "${LLAMA_ARG_CTV:-q4_0}"
    "-ctkd" "${LLAMA_ARG_CTKD:-q4_0}"
    "-ctvd" "${LLAMA_ARG_CTVD:-q4_0}"
    "--no-cache-idle-slots"
    "--reasoning-effort" "${LLAMA_ARG_REASONING_EFFORT:-medium}"
    "--reasoning-budget" "${LLAMA_ARG_REASONING_BUDGET:-2048}"
    "--load-mode" "mmap"
    "--jinja"
)

# LoRA Adapter Attachment
LORA_PATH="${LLAMA_ARG_LORA:-}"
if [ -z "$LORA_PATH" ] && [[ "$TARGET_MODEL" == *"Champion-v5"* ]] && [ -f /models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration4-Fused-LoRA.gguf ]; then
    LORA_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration4-Fused-LoRA.gguf"
fi
if [ -n "$LORA_PATH" ] && [ -f "$LORA_PATH" ]; then
    echo "[+] Attaching Fused LoRA Adapter: $LORA_PATH"
    ARGS+=("--lora" "$LORA_PATH")
fi

# Multimodal Vision Tower (Explicitly off on GPU 0, enabled on GPU 1 if ENABLE_VISION=1)
MMPROJ_PATH="${LLAMA_ARG_MMPROJ:-/models/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf}"
if [ "${ENABLE_VISION:-0}" = "1" ] && [ -f "$MMPROJ_PATH" ]; then
    echo "[+] Offloading Multimodal Vision Tower ($MMPROJ_PATH)..."
    ARGS+=(
        "--mmproj" "$MMPROJ_PATH"
        "--mmproj-offload"
        "--image-min-tokens" "1024"
    )
else
    echo "[+] Multimodal Vision Tower disabled for this node."
fi

# Speculative Decoding (MTP Draft Layer)
DRAFT_PATH="${LLAMA_ARG_DRAFT:-}"
if [ "${ENABLE_MTP:-0}" = "1" ]; then
    if ([[ "$TARGET_MODEL" == *"Internal-MTP"* ]] || [[ "$TARGET_MODEL" == *"mtp-lean"* ]] || [ -z "$DRAFT_PATH" ]); then
        DRAFT_N_MAX="${LLAMA_ARG_SPEC_DRAFT_N_MAX:-1}"
        DRAFT_P_MIN="${LLAMA_ARG_SPEC_DRAFT_P_MIN:-0.70}"
        echo "[+] Enabling Native Internal MTP Speculative Decoding (draft-mtp, n-max ${DRAFT_N_MAX}, p-min ${DRAFT_P_MIN})..."
        ARGS+=(
            "--spec-type" "draft-mtp"
            "--spec-draft-n-max" "$DRAFT_N_MAX"
            "--spec-draft-p-min" "$DRAFT_P_MIN"
            "--spec-draft-ngl" "99"
        )
    elif [ -n "$DRAFT_PATH" ] && [ -f "$DRAFT_PATH" ]; then
        echo "[+] Enabling External MTP Draft Speculative Decoding: $DRAFT_PATH"
        ARGS+=(
            "-md" "$DRAFT_PATH"
            "--spec-type" "draft-mtp"
            "-ngld" "99"
        )
    fi
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
