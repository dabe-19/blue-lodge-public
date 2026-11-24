#!/usr/bin/env bash
# ── switch_inference.sh: Dual Inference Profile Switcher ──
# Allows effortless toggling between Sovereign Production (Dual-GPU Qwen 3.8)
# and Experimental Research (Champion-v5-Internal-MTP + Vision) modes.
set -euo pipefail

MODELS_DIR="${MODELS_DIR:-$HOME/models}"
ACTIVE_DIR="$MODELS_DIR/active"
WORKSPACE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

BOLD='\033[1m'
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

_usage() {
    echo -e "${BOLD}Usage:${RESET} $0 [sovereign [model] | experimental | status]"
    echo ""
    echo "Profiles:"
    echo "  sovereign [model]  Unified Multi-GPU Sovereign Host (All GPUs pooled, 64k context)."
    echo "                     Single model node across GPUs; download & switch quants freely."
    echo "                     Default: Qwen 3.8 27B UD-Q4_K_S + MTP Draft Layer."
    echo "  experimental       Reserved Split-GPU Research Stack (Custom ternary-pruned v5 Champion,"
    echo "                     GPU 1 text reasoning on 8080 + GPU 0 vision worker on 18080, 131k context)."
    echo "  status             Display active profile, symlinks, container health, and GPU VRAM"
    echo ""
    exit 1
}

_check_health() {
    local port="$1"
    local timeout="${2:-45}"
    local elapsed=0
    echo -ne "  Waiting for server on port ${port}..."
    while [ "$elapsed" -lt "$timeout" ]; do
        if curl -sf --max-time 2 "http://127.0.0.1:${port}/health" 2>/dev/null | grep -qi "ok"; then
            echo -e " ${GREEN}✓ Ready!${RESET}"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        echo -ne "."
    done
    echo -e " ${YELLOW}⚠ Timed out waiting for port ${port}${RESET}"
    return 1
}

_status() {
    echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}  Blue Lodge — Inference Engine Status${RESET}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
    
    local active_profile="unknown"
    if [ -L "$ACTIVE_DIR/current" ]; then
        active_profile=$(basename "$(readlink -f "$ACTIVE_DIR/current")")
    fi
    echo -e "  Active Profile: ${CYAN}${BOLD}${active_profile}${RESET}"
    echo -e "  Active Directory: $ACTIVE_DIR/current"
    
    if [ -f "$ACTIVE_DIR/current/base.gguf" ]; then
        echo -e "  Base Model:       $(readlink -f "$ACTIVE_DIR/current/base.gguf")"
    fi
    if [ -f "$ACTIVE_DIR/current/draft.gguf" ]; then
        echo -e "  Draft Model:      $(readlink -f "$ACTIVE_DIR/current/draft.gguf")"
    fi
    if [ -f "$ACTIVE_DIR/current/champion.gguf" ]; then
        echo -e "  Champion Adapter: $(readlink -f "$ACTIVE_DIR/current/champion.gguf")"
    fi
    echo ""

    echo -e "  ${BOLD}Container Endpoints:${RESET}"
    local p8080_health=$(curl -sf --max-time 2 "http://127.0.0.1:8080/health" 2>/dev/null || echo "offline")
    echo -e "  - Port 8080 (Primary):  $([ "$p8080_health" != "offline" ] && echo -e "${GREEN}${p8080_health}${RESET}" || echo -e "${RED}offline${RESET}")"
    
    local p18080_health=$(curl -sf --max-time 2 "http://127.0.0.1:18080/health" 2>/dev/null || echo "offline")
    echo -e "  - Port 18080 (Worker):  $([ "$p18080_health" != "offline" ] && echo -e "${GREEN}${p18080_health}${RESET}" || echo -e "${YELLOW}offline (profile inactive)${RESET}")"
    echo ""

    if command -v nvidia-smi &>/dev/null; then
        echo -e "  ${BOLD}GPU VRAM Utilization:${RESET}"
        nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits | while IFS=, read -r idx name used total util; do
            echo -e "  - GPU ${idx} (${name}): ${used}MB / ${total}MB (${util}% load)"
        done
    fi
    echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
}

MODE="${1:-}"
[ -z "$MODE" ] && _usage

case "$MODE" in
    sovereign)
        TARGET_MODEL="${2:-}"
        MODEL_NAME="qwen38-27b"
        MODEL_ENV=""

        if [ -n "$TARGET_MODEL" ]; then
            case "$TARGET_MODEL" in
                qwen38|qwen38-27b|default)
                    MODEL_ENV=""
                    MODEL_NAME="qwen38-27b"
                    ;;
                champion|v5)
                    MODEL_ENV="/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Internal-MTP-Calibrated.gguf"
                    MODEL_NAME="champion-v5"
                    ;;
                bonsai|ternary)
                    MODEL_ENV="/models/Ternary-Bonsai-2-27B-PTQ1_0.gguf"
                    MODEL_NAME="ternary-bonsai-27b"
                    ;;
                *)
                    MODEL_ENV="$TARGET_MODEL"
                    MODEL_NAME=$(basename "$TARGET_MODEL" .gguf)
                    ;;
            esac
            echo -e "${CYAN}[*] Switching SOVEREIGN Unified Host to Model: ${MODEL_NAME}...${RESET}"
        else
            echo -e "${CYAN}[*] Switching to SOVEREIGN Production Profile (Unified Multi-GPU Host, Qwen 3.8 + SVD32)...${RESET}"
        fi

        if [ ! -d "$ACTIVE_DIR/sovereign" ]; then
            echo -e "${RED}[!] Error: $ACTIVE_DIR/sovereign not found.${RESET}"
            exit 1
        fi
        ln -sfn sovereign "$ACTIVE_DIR/current"
        mkdir -p "$WORKSPACE_DIR/.george"
        ln -sfn "$ACTIVE_DIR/current" "$WORKSPACE_DIR/.george/models"

        # Update endpoints.conf for Sovereign profile (Unified Multi-GPU Host: 96k Context, 85% Compaction)
        if [ -f "$WORKSPACE_DIR/.george/endpoints.conf" ]; then
            sed -i 's|^TIER1_URL=.*|TIER1_URL="http://127.0.0.1:8080"|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i "s|^TIER1_MODEL=.*|TIER1_MODEL=\"${MODEL_NAME}\"|" "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER1_CONTEXT=.*|TIER1_CONTEXT=98304|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER1_MAX_TOKENS=.*|TIER1_MAX_TOKENS=93388|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER1_COMPACT_TOKENS=.*|TIER1_COMPACT_TOKENS=83558|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER1_TEMPERATURE=.*|TIER1_TEMPERATURE=1.0|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER1_TOP_P=.*|TIER1_TOP_P=0.95|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER2_URL=.*|TIER2_URL="http://127.0.0.1:18080"|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i "s|^TIER2_MODEL=.*|TIER2_MODEL=\"${MODEL_NAME}\"|" "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER2_CONTEXT=.*|TIER2_CONTEXT=65536|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER2_MAX_TOKENS=.*|TIER2_MAX_TOKENS=58982|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER2_COMPACT_TOKENS=.*|TIER2_COMPACT_TOKENS=49152|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER2_TEMPERATURE=.*|TIER2_TEMPERATURE=1.0|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER2_TOP_P=.*|TIER2_TOP_P=0.95|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER2_ENABLED=.*|TIER2_ENABLED=0|' "$WORKSPACE_DIR/.george/endpoints.conf"
        fi

        # Synchronize limits and levers
        if [ -f "$WORKSPACE_DIR/lib/core/limits.sh" ]; then
            bash -c "source '$WORKSPACE_DIR/lib/core/limits.sh' && limits_scale_for_context 98304 85" 2>/dev/null || true
        fi
        systemctl --user restart george-web.service 2>/dev/null || true

        # Stop experimental worker if running
        echo "[*] Stopping experimental worker container (if active)..."
        docker stop george-prism-worker 2>/dev/null || true

        # Restart primary server with 96k context, 13,10 split, and ubatch 512
        echo "[*] Launching sovereign inference server across all GPUs (98304 ctx, 13:10 split)..."
        sov_vars="LLAMA_ARG_CTX_SIZE=98304 LLAMA_ARG_TENSOR_SPLIT=14,9 LLAMA_ARG_UBATCH=512"
        [ -n "$MODEL_ENV" ] && sov_vars="$sov_vars LLAMA_ARG_MODEL=$MODEL_ENV"
        (cd "$WORKSPACE_DIR" && env $sov_vars docker compose up -d prism-inference)
        _check_health 8080
        echo -e "${GREEN}✓ Sovereign Production Profile Active on Unified Multi-GPU Host (96k context, 85% compaction)!${RESET}"
        _status
        ;;

    experimental)
        echo -e "${CYAN}[*] Activating EXPERIMENTAL Research Profile (Dedicated Split-GPU Setup with Champion-v5 Internal-MTP + Vision, 131k context)...${RESET}"
        if [ ! -d "$ACTIVE_DIR/experimental" ]; then
            echo -e "${RED}[!] Error: $ACTIVE_DIR/experimental not found.${RESET}"
            exit 1
        fi
        ln -sfn experimental "$ACTIVE_DIR/current"
        mkdir -p "$WORKSPACE_DIR/.george"
        ln -sfn "$ACTIVE_DIR/current" "$WORKSPACE_DIR/.george/models"

        # Update endpoints.conf: Tier 1 (Port 8080, GPU 1) and Tier 2 (Port 18080, GPU 0 Vision)
        if [ -f "$WORKSPACE_DIR/.george/endpoints.conf" ]; then
            sed -i 's|^TIER1_URL=.*|TIER1_URL="http://127.0.0.1:8080"|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER1_MODEL=.*|TIER1_MODEL="champion-v5"|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER1_CONTEXT=.*|TIER1_CONTEXT=131072|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER1_MAX_TOKENS=.*|TIER1_MAX_TOKENS=117964|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER1_COMPACT_TOKENS=.*|TIER1_COMPACT_TOKENS=98304|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER1_TEMPERATURE=.*|TIER1_TEMPERATURE=1.0|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER1_TOP_P=.*|TIER1_TOP_P=0.95|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER2_URL=.*|TIER2_URL="http://127.0.0.1:18080"|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER2_MODEL=.*|TIER2_MODEL="champion-v5-vision"|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER2_CONTEXT=.*|TIER2_CONTEXT=131072|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER2_MAX_TOKENS=.*|TIER2_MAX_TOKENS=117964|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER2_COMPACT_TOKENS=.*|TIER2_COMPACT_TOKENS=98304|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER2_TEMPERATURE=.*|TIER2_TEMPERATURE=1.0|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER2_TOP_P=.*|TIER2_TOP_P=0.95|' "$WORKSPACE_DIR/.george/endpoints.conf"
            sed -i 's|^TIER2_ENABLED=.*|TIER2_ENABLED=1|' "$WORKSPACE_DIR/.george/endpoints.conf"
        fi

        # Synchronize limits and levers
        if [ -f "$WORKSPACE_DIR/lib/core/limits.sh" ]; then
            bash -c "source '$WORKSPACE_DIR/lib/core/limits.sh' && limits_scale_for_context 131072" 2>/dev/null || true
        fi
        systemctl --user restart george-web.service 2>/dev/null || true

        # Stop previous inference containers to cleanly release VRAM
        echo "[*] Stopping previous inference containers to release VRAM..."
        docker stop george-prism-server george-prism-worker 2>/dev/null || true

        # Launch both primary (GPU 1, 131k context) and worker (GPU 0, vision, 131k context)
        echo "[*] Launching split-GPU research endpoints (Primary 8080 + Vision Worker 18080 at 131k ctx)..."
        (cd "$WORKSPACE_DIR" && LLAMA_ARG_CTX_SIZE=131072 docker compose --profile worker up -d)
        _check_health 8080
        _check_health 18080
        echo -e "${GREEN}✓ Experimental Research Profile Active (131k context)!${RESET}"
        _status
        ;;

    status)
        _status
        ;;

    *)
        _usage
        ;;
esac
