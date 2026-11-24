#!/usr/bin/env bash
# ── switch_model.sh: Switch George Primary Inference Model ──
set -euo pipefail

TARGET="${1:-}"

if [ -z "$TARGET" ]; then
    echo "Usage: $0 [sovereign | champion | bonsai | /path/to/model.gguf]"
    echo "  sovereign : Load Qwen 3.8 27B UD-Q4_K_S Sovereign model"
    echo "  champion  : Load Blue-Llama 27B Champion-v5 Internal-MTP Calibrated model"
    echo "  bonsai    : Load PrismML Ternary Bonsai 2 27B model"
    exit 1
fi

case "$TARGET" in
    sovereign|qwen38|production)
        MODEL_PATH="/models/frontier_qwen38/Qwen3.8-27B-UD-Q4_K_S.gguf"
        CTX_SIZE="131072"
        echo "[+] Switching George (Port 8080) to Sovereign Model: $MODEL_PATH"
        ;;
    champion|champion-v5|v5)
        MODEL_PATH="/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Internal-MTP-Calibrated.gguf"
        CTX_SIZE="131072"
        echo "[+] Switching George (Port 8080) to Champion-v5 Model: $MODEL_PATH"
        ;;
    bonsai|ternary|default)
        MODEL_PATH="/models/Ternary-Bonsai-2-27B-PTQ1_0.gguf"
        CTX_SIZE="131072"
        echo "[+] Switching George (Port 8080) to Bonsai Model: $MODEL_PATH"
        ;;
    *)
        if [ -f "$TARGET" ]; then
            MODEL_PATH="$TARGET"
            CTX_SIZE="131072"
            echo "[+] Switching George (Port 8080) to Custom Model: $MODEL_PATH"
        else
            echo "[!] Unknown model target or file not found: $TARGET"
            echo "Valid options: sovereign, champion, bonsai, or absolute .gguf path"
            exit 1
        fi
        ;;
esac

LODGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LODGE_ROOT"

echo "[*] Restarting prism-inference on GPU 0..."
LLAMA_ARG_MODEL="$MODEL_PATH" LLAMA_ARG_CTX_SIZE="$CTX_SIZE" docker compose up -d prism-inference

# Synchronize endpoints.conf, limits.conf and web UI with the new model & context
ENDPOINTS_CONF="$LODGE_ROOT/.george/endpoints.conf"
if [ -f "$ENDPOINTS_CONF" ]; then
    COMPACT_TOKENS=$(( CTX_SIZE * 75 / 100 ))
    MAX_TOKENS=$(( CTX_SIZE * 90 / 100 ))
    sed -i "s|^TIER1_CONTEXT=.*|TIER1_CONTEXT=$CTX_SIZE|" "$ENDPOINTS_CONF"
    sed -i "s|^TIER1_MAX_TOKENS=.*|TIER1_MAX_TOKENS=$MAX_TOKENS|" "$ENDPOINTS_CONF"
    sed -i "s|^TIER1_COMPACT_TOKENS=.*|TIER1_COMPACT_TOKENS=$COMPACT_TOKENS|" "$ENDPOINTS_CONF"
    sed -i "s|^TIER1_TEMPERATURE=.*|TIER1_TEMPERATURE=1.0|" "$ENDPOINTS_CONF"
    sed -i "s|^TIER1_TOP_P=.*|TIER1_TOP_P=0.95|" "$ENDPOINTS_CONF"
    if [ -f "$LODGE_ROOT/lib/core/limits.sh" ]; then
        bash -c "source '$LODGE_ROOT/lib/core/limits.sh' && limits_scale_for_context $CTX_SIZE" 2>/dev/null || true
    fi
    systemctl --user restart george-web.service 2>/dev/null || true
fi

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
