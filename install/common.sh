#!/bin/bash
# ── install/common.sh: Shared Utilities, Hardware Probing & Model Setup ──
set -euo pipefail

BLUE='\033[38;5;33m'
GREEN='\033[38;5;114m'
YELLOW='\033[38;5;221m'
RED='\033[38;5;203m'
CYAN='\033[36m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

info()  { printf " ${BLUE}●${RESET} %s\n" "$1"; }
ok()    { printf " ${GREEN}✓${RESET} %s\n" "$1"; }
warn()  { printf " ${YELLOW}⚠${RESET} %s\n" "$1"; }
err()   { printf " ${RED}✗${RESET} %s\n" "$1"; }

# ── Hardware & Environment Probing ───────────────────────────
detect_environment() {
    IS_TERMUX=0
    IS_PROOT=0
    IS_ISH=0
    IS_WSL=0
    IS_MACOS=0
    IS_LINUX=0

    [ -n "${TERMUX_VERSION:-}" ] || [ -d "/data/data/com.termux" ] && IS_TERMUX=1
    [ "$(id -u)" = "0" ] && [ -d "/host-rootfs" ] && IS_PROOT=1
    [ "$(uname -s)" = "Darwin" ] && IS_MACOS=1
    [ "$(uname -s)" = "Linux" ] && IS_LINUX=1
    grep -qi "microsoft" /proc/version 2>/dev/null && IS_WSL=1

    GPU_COUNT=0
    GPU_NAMES=""
    VRAM_TOTAL_MB=0

    if command -v nvidia-smi &>/dev/null; then
        GPU_COUNT=$(nvidia-smi --query-gpu=count --format=csv,noheader 2>/dev/null | head -1 || echo 0)
        GPU_COUNT=${GPU_COUNT:-0}
        if [ "$GPU_COUNT" -gt 0 ]; then
            GPU_NAMES=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | tr '\n' ',' | sed 's/,$//')
            local vram_list
            vram_list=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || echo 0)
            for v in $vram_list; do
                VRAM_TOTAL_MB=$((VRAM_TOTAL_MB + v))
            done
        fi
    fi
}

# ── Setup Model Directory & Update References ────────────────
setup_model_directory() {
    local requested_dir="${1:-}"
    local lodge_dir="${2:-$LODGE_DIR}"
    local default_dir="$HOME/models"

    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}  Model Storage Configuration${RESET}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"

    local target_dir=""
    if [ -n "$requested_dir" ]; then
        target_dir="$requested_dir"
    elif [ -t 0 ]; then
        echo -e "  Blue Lodge requires a local directory for GGUF model files and LoRA adapters."
        echo -e "  Default location: ${CYAN}${default_dir}${RESET}"
        printf "  Press Enter to accept [default], or type custom path: "
        read -r user_input
        target_dir="${user_input:-$default_dir}"
    else
        target_dir="$default_dir"
    fi

    # Expand tilde if present
    target_dir="${target_dir/#\~/$HOME}"
    target_dir="$(mkdir -p "$target_dir" && cd "$target_dir" && pwd)"

    info "Configuring model storage at: ${CYAN}${target_dir}${RESET}"

    # Setup standard partitioned directory structure
    mkdir -p "$target_dir/active/sovereign" \
             "$target_dir/active/experimental" \
             "$target_dir/archive/iterations_v5_v12" \
             "$target_dir/archive/ternary_legacy" \
             "$target_dir/archive/tarballs"

    # Default to sovereign profile if active pointer does not exist
    if [ ! -L "$target_dir/active/current" ] && [ ! -d "$target_dir/active/current" ]; then
        ln -sfn sovereign "$target_dir/active/current"
    fi

    # Create workspace symlink
    mkdir -p "$lodge_dir/.george"
    ln -sfn "$target_dir/active/current" "$lodge_dir/.george/models"
    ok "Linked workspace models: ${lodge_dir}/.george/models -> ${target_dir}/active/current"

    # Update lodge.conf
    local conf_file="$lodge_dir/.george/lodge.conf"
    touch "$conf_file"
    if grep -q "^MODELS_DIR=" "$conf_file" 2>/dev/null; then
        sed -i "s|^MODELS_DIR=.*|MODELS_DIR=\"$target_dir\"|" "$conf_file"
    else
        echo "MODELS_DIR=\"$target_dir\"" >> "$conf_file"
    fi
    ok "Updated ${conf_file} with MODELS_DIR=\"$target_dir\""

    # Update .env for Docker Compose
    local env_file="$lodge_dir/.env"
    touch "$env_file"
    if grep -q "^MODELS_DIR=" "$env_file" 2>/dev/null; then
        sed -i "s|^MODELS_DIR=.*|MODELS_DIR=$target_dir|" "$env_file"
    else
        echo "MODELS_DIR=$target_dir" >> "$env_file"
    fi
    ok "Updated ${env_file} with MODELS_DIR=$target_dir"

    # Export in user's shell RC
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$rc" ]; then
            if grep -q "export MODELS_DIR=" "$rc" 2>/dev/null; then
                sed -i "s|export MODELS_DIR=.*|export MODELS_DIR=\"$target_dir\"|" "$rc"
            else
                echo "export MODELS_DIR=\"$target_dir\"" >> "$rc"
            fi
        fi
    done
    export MODELS_DIR="$target_dir"
    ok "Persisted MODELS_DIR in shell environment"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
}
