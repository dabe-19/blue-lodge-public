#!/usr/bin/env bash
# ── switch_model.sh: Switch George Primary Inference Model ──
set -euo pipefail

TARGET="${1:-}"

if [ -z "$TARGET" ]; then
    echo "Usage: $0 [sptq2 | bonsai]"
    echo "  sptq2  : Load sub-4GB Qwen3.8-27B-SPTQ2_0-Sparse (3.92 GB)"
    echo "  bonsai : Load baseline Ternary-Bonsai-2-27B-PTQ1_0 (5.87 GB)"
    exit 1
fi

case "$TARGET" in
    sptq2-clean|clean|sub4gb)
        MODEL_PATH="/models/frontier_qwen38/Qwen3.8-27B-SPTQ2_0-Sub4GB-Clean.gguf"
        CTX_SIZE="65536"
        echo "[+] Switching George (Port 8080) to Sub-4GB Clean Model: $MODEL_PATH"
        ;;
    sptq1-clean|hybrid-clean)
        MODEL_PATH="/models/frontier_qwen38/Qwen3.8-27B-SPTQ1_0-Hybrid-Clean.gguf"
        CTX_SIZE="65536"
        echo "[+] Switching George (Port 8080) to Hybrid Clean Model: $MODEL_PATH"
        ;;
    sptq2|sparse|sptq)
        MODEL_PATH="/models/frontier_qwen38/Qwen3.8-27B-SPTQ2_0-Sparse.gguf"
        CTX_SIZE="65536"
        echo "[+] Switching George (Port 8080) to Sub-4GB Frontier Model: $MODEL_PATH"
        ;;
    bonsai|baseline|default)
        MODEL_PATH="/models/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf"
        CTX_SIZE="147456"
        echo "[+] Switching George (Port 8080) to Bonsai Baseline Model: $MODEL_PATH"
        ;;
    *)
        echo "[!] Unknown model target: $TARGET"
        echo "Valid options: sptq2, bonsai"
        exit 1
        ;;
esac

LODGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LODGE_ROOT"

echo "[*] Restarting prism-inference on GPU 0..."
LLAMA_ARG_MODEL="$MODEL_PATH" LLAMA_ARG_CTX_SIZE="$CTX_SIZE" docker compose up -d prism-inference

echo "[*] Waiting for server healthcheck on port 8080..."
for i in {1..30}; do
    if curl -s http://127.0.0.1:8080/health | grep -q '"status":"ok"'; then
        echo "[✓] George inference server is healthy and ready on Port 8080!"
        break
    fi
    sleep 1
done

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " Active Model : $MODEL_PATH"
echo " Endpoint     : http://127.0.0.1:8080"
echo " You can now chat with George using:"
echo "   ./lodge                   (Interactive TUI mode)"
echo "   ./lodge \"<your prompt>\"     (One-shot task mode)"
echo "   http://localhost:3000     (George Web UI)"
echo "══════════════════════════════════════════════════════════════════════"
