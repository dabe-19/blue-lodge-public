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
    echo -e "${BOLD}Usage:${RESET} $0 [sovereign | experimental | status]"
    echo ""
    echo "Profiles:"
    echo "  sovereign     Dual-GPU Production (Qwen3.8-27B-UD-Q4_K_S + MTP Draft + SVD32) on port 8080"
    echo "  experimental  Dual-Endpoint Research (Champion-v5 4.9GB Internal-MTP on 8080, Vision Worker on 18080)"
    echo "  status        Display active profile, symlinks, container health, and GPU VRAM"
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
        echo -e "${CYAN}[*] Switching to SOVEREIGN Production Profile (Dual-GPU Qwen 3.8 + SVD32)...${RESET}"
        if [ ! -d "$ACTIVE_DIR/sovereign" ]; then
            echo -e "${RED}[!] Error: $ACTIVE_DIR/sovereign not found.${RESET}"
            exit 1
        fi
        ln -sfn sovereign "$ACTIVE_DIR/current"
        mkdir -p "$WORKSPACE_DIR/.george"
        ln -sfn "$ACTIVE_DIR/current" "$WORKSPACE_DIR/.george/models"

        # Stop experimental worker if running
        echo "[*] Stopping experimental worker container (if active)..."
        docker stop george-prism-worker 2>/dev/null || true

        # Restart primary server
        echo "[*] Launching sovereign inference server on dual GPUs..."
        if docker ps -a --format '{{.Names}}' | grep -q "^george-prism-server$"; then
            docker restart george-prism-server
        else
            (cd "$WORKSPACE_DIR" && docker compose up -d prism-inference)
        fi
        _check_health 8080
        echo -e "${GREEN}✓ Sovereign Production Profile Active!${RESET}"
        _status
        ;;

    experimental)
        echo -e "${CYAN}[*] Switching to EXPERIMENTAL Research Profile (Champion-v5 Internal-MTP + Vision)...${RESET}"
        if [ ! -d "$ACTIVE_DIR/experimental" ]; then
            echo -e "${RED}[!] Error: $ACTIVE_DIR/experimental not found.${RESET}"
            exit 1
        fi
        ln -sfn experimental "$ACTIVE_DIR/current"
        mkdir -p "$WORKSPACE_DIR/.george"
        ln -sfn "$ACTIVE_DIR/current" "$WORKSPACE_DIR/.george/models"

        # Launch both primary (GPU 1, 131k context) and worker (GPU 0, vision)
        echo "[*] Launching dual experimental endpoints (Primary 8080 + Vision Worker 18080)..."
        (cd "$WORKSPACE_DIR" && docker compose --profile worker up -d)
        _check_health 8080
        _check_health 18080
        echo -e "${GREEN}✓ Experimental Research Profile Active!${RESET}"
        _status
        ;;

    status)
        _status
        ;;

    *)
        _usage
        ;;
esac
