#!/usr/bin/env bash
# ── start_prism.sh: Sovereign PRISM Inference Runner ──
set -euo pipefail

TARGET_MODEL="${LLAMA_ARG_MODEL:-/models/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf}"
[ ! -f "$TARGET_MODEL" ] && TARGET_MODEL="/models/Ternary-Bonsai-2-27B-PTQ1_0.gguf"
[ ! -f "$TARGET_MODEL" ] && TARGET_MODEL="/models/Ternary-Bonsai-2-27B-PQ2_0.gguf"

if [ ! -f "$TARGET_MODEL" ]; then
    echo "[!] Error: No compatible Ternary Bonsai model found in /models."
    exit 1
fi

echo "[+] Starting PRISM CUDA server with $TARGET_MODEL..."

# Setup library paths
PRISM_BIN="/usr/local/bin/llama-server-prism"
if [ -x /opt/llama-prism-latest/llama-server ]; then
    echo "[+] Using optimized PRISM binary from /opt/llama-prism-latest..."
    PRISM_BIN="/opt/llama-prism-latest/llama-server"
    export LD_LIBRARY_PATH="/opt/llama-prism-latest:${LD_LIBRARY_PATH:-}"
fi

# Build arguments array
ARGS=(
    "-m" "$TARGET_MODEL"
    "--host" "${LLAMA_ARG_HOST:-0.0.0.0}"
    "--port" "${LLAMA_ARG_PORT:-8080}"
    "-c" "${LLAMA_ARG_CTX_SIZE:-163840}"
    "-np" "${LLAMA_ARG_N_PARALLEL:-1}"
    "-ngl" "${LLAMA_ARG_N_GPU_LAYERS:-99}"
    "-b" "${LLAMA_ARG_BATCH:-2048}"
    "-ub" "${LLAMA_ARG_UBATCH:-1024}"
    "--flash-attn" "on"
    "-ctk" "q4_0"
    "-ctv" "q4_0"
    "-ctkd" "q4_0"
    "-ctvd" "q4_0"
    "--no-cache-idle-slots"
    "--reasoning-effort" "medium"
    "--load-mode" "mmap"
    "--jinja"
)

# Multimodal Vision Tower
if [ "${ENABLE_VISION:-1}" = "1" ] && [ -f /models/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf ]; then
    echo "[+] Offloading Vision Tower (mmproj-Q8_0)..."
    ARGS+=(
        "--mmproj" "/models/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf"
        "--mmproj-offload"
        "--image-min-tokens" "1024"
    )
fi

# Speculative Decoding (MTP)
if [[ "$TARGET_MODEL" == *"mtp"* ]] && [ "${ENABLE_MTP:-1}" = "1" ]; then
    echo "[+] Enabling MTP Speculative Decoding (draft-mtp, n-max 1)..."
    ARGS+=(
        "--spec-type" "draft-mtp"
        "--spec-draft-n-max" "1"
    )
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
