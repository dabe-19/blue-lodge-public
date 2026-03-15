#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# inference-server-install.sh — Remote GPU Node Provisioner
# ═══════════════════════════════════════════════════════════════
# Sets up a Debian/Ubuntu machine as a George remote inference
# node with Ollama (model management) + llama-server (GPU inference).
#
# Supports:
#   - AMD GPUs via Vulkan (Navi 10, RDNA, etc.)
#   - NVIDIA GPUs via CUDA (auto-detected)
#   - CPU-only fallback
#
# Usage:
#   curl -sL <george_repo>/scripts/inference-server-install.sh | bash
#   # or:
#   scp scripts/inference-server-install.sh user@gpu-server:
#   ssh user@gpu-server bash inference-server-install.sh
#
# Environment overrides:
#   LLAMA_CPP_DIR       Where to clone/build llama.cpp (default: ~/llama.cpp)
#   LLAMA_CPP_PORT      llama-server listen port (default: 8080)
#   OLLAMA_PORT         Ollama listen port (default: 11434)
#   GPU_BACKEND         Force: vulkan, cuda, or cpu (default: auto-detect)
#   SKIP_BUILD          Set to 1 to skip llama.cpp build (if already built)
#   INSTALL_SYSTEMD     Set to 1 to install systemd service files

set -euo pipefail

# ── Error trap ─────────────────────────────────────────────────
trap 'printf "\n\033[31m✗ Failed at line %s: %s\033[0m\n" "$LINENO" "$BASH_COMMAND"; exit 1' ERR

# ── Colors ─────────────────────────────────────────────────────
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_CYAN='\033[36m'
C_GREEN='\033[32m'
C_RED='\033[31m'
C_YELLOW='\033[33m'
C_RESET='\033[0m'

_step()  { printf "\n${C_BOLD}${C_CYAN}[%s]${C_RESET} %s\n" "$1" "$2"; }
_ok()    { printf "${C_GREEN}  ✓ %s${C_RESET}\n" "$1"; }
_fail()  { printf "${C_RED}  ✗ %s${C_RESET}\n" "$1"; exit 1; }
_warn()  { printf "${C_YELLOW}  ⚠ %s${C_RESET}\n" "$1"; }
_dim()   { printf "${C_DIM}    %s${C_RESET}\n" "$1"; }

# ── Config ─────────────────────────────────────────────────────
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-$HOME/llama.cpp}"
LLAMA_CPP_PORT="${LLAMA_CPP_PORT:-8080}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
GPU_BACKEND="${GPU_BACKEND:-auto}"
SKIP_BUILD="${SKIP_BUILD:-0}"
INSTALL_SYSTEMD="${INSTALL_SYSTEMD:-0}"

printf "\n${C_BOLD}═══ George Remote Inference Node Setup ═══${C_RESET}\n"
_dim "Target: $(hostname) ($(uname -m))"
_dim "User: $(whoami)"
_dim "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ═══════════════════════════════════════════════════════════════
# Step 1: System dependencies
# ═══════════════════════════════════════════════════════════════
_step "1" "Installing system dependencies"

# Check for root/sudo
_SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo &>/dev/null; then
        _SUDO="sudo"
    else
        _warn "Not root and sudo not available — package install may fail"
    fi
fi

$_SUDO apt-get update -qq

# Core build tools + runtime deps
_PACKAGES=(
    build-essential cmake git curl jq
    pkg-config libcurl4-openssl-dev
)

# ── Step 1a: Detect GPU backend ───────────────────────────────
if [ "$GPU_BACKEND" = "auto" ]; then
    if command -v nvidia-smi &>/dev/null; then
        GPU_BACKEND="cuda"
    elif command -v vulkaninfo &>/dev/null || [ -d /usr/share/vulkan ]; then
        GPU_BACKEND="vulkan"
    elif lspci 2>/dev/null | grep -qi "vga.*amd\|vga.*radeon"; then
        GPU_BACKEND="vulkan"
    elif lspci 2>/dev/null | grep -qi "vga.*nvidia"; then
        GPU_BACKEND="cuda"
    else
        GPU_BACKEND="cpu"
    fi
fi

case "$GPU_BACKEND" in
    vulkan)
        _ok "GPU backend: Vulkan"
        _PACKAGES+=(libvulkan-dev mesa-vulkan-drivers vulkan-tools)
        _CMAKE_GPU_FLAGS="-DGGML_VULKAN=ON"
        ;;
    cuda)
        _ok "GPU backend: CUDA"
        # CUDA toolkit should already be installed; just need headers.
        _PACKAGES+=(nvidia-cuda-toolkit)
        _CMAKE_GPU_FLAGS="-DGGML_CUDA=ON"
        ;;
    cpu)
        _warn "GPU backend: CPU only"
        _CMAKE_GPU_FLAGS=""
        ;;
    *)
        _fail "Unknown GPU_BACKEND: $GPU_BACKEND (use: vulkan, cuda, cpu)"
        ;;
esac

$_SUDO apt-get install -y -qq "${_PACKAGES[@]}"
_ok "System packages installed"

# ═══════════════════════════════════════════════════════════════
# Step 2: Verify GPU (if not CPU-only)
# ═══════════════════════════════════════════════════════════════
if [ "$GPU_BACKEND" = "vulkan" ]; then
    _step "2" "Verifying Vulkan GPU"
    if command -v vulkaninfo &>/dev/null; then
        _gpu_name=$(vulkaninfo --summary 2>/dev/null | grep -i "deviceName" | head -1 | sed 's/.*= //')
        _gpu_type=$(vulkaninfo --summary 2>/dev/null | grep -i "deviceType" | head -1 | sed 's/.*= //')
        if [ -n "$_gpu_name" ]; then
            _ok "GPU: $_gpu_name ($_gpu_type)"
        else
            _warn "vulkaninfo ran but no GPU detected"
        fi
    else
        _warn "vulkaninfo not available — install vulkan-tools to verify"
    fi
elif [ "$GPU_BACKEND" = "cuda" ]; then
    _step "2" "Verifying CUDA GPU"
    if command -v nvidia-smi &>/dev/null; then
        _gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
        _vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1)
        _ok "GPU: $_gpu_name (${_vram})"
    else
        _warn "nvidia-smi not available"
    fi
else
    _step "2" "Skipping GPU verification (CPU mode)"
fi

# ═══════════════════════════════════════════════════════════════
# Step 3: Install Ollama
# ═══════════════════════════════════════════════════════════════
_step "3" "Installing Ollama"

if command -v ollama &>/dev/null; then
    _ok "Ollama already installed: $(ollama --version 2>/dev/null || echo 'unknown version')"
else
    _dim "Running official Ollama installer..."
    curl -fsSL https://ollama.com/install.sh | sh
    _ok "Ollama installed"
fi

# Ensure ollama user group membership (for blob access)
if getent group ollama &>/dev/null; then
    if ! id -nG "$(whoami)" 2>/dev/null | grep -qw ollama; then
        $_SUDO usermod -aG ollama "$(whoami)"
        _warn "Added $(whoami) to ollama group — log out/in for effect"
    else
        _ok "User $(whoami) in ollama group"
    fi
fi

# Start Ollama service
if ! curl -sf --max-time 3 "http://127.0.0.1:${OLLAMA_PORT}/api/tags" &>/dev/null; then
    _dim "Starting Ollama..."
    if command -v systemctl &>/dev/null && systemctl is-active ollama &>/dev/null; then
        _ok "Ollama systemd service running"
    else
        # Start in background
        OLLAMA_HOST="0.0.0.0:${OLLAMA_PORT}" ollama serve &>/dev/null &
        sleep 2
        if curl -sf --max-time 3 "http://127.0.0.1:${OLLAMA_PORT}/api/tags" &>/dev/null; then
            _ok "Ollama started (PID $!)"
        else
            _warn "Ollama may not have started — check manually"
        fi
    fi
else
    _ok "Ollama already responding on port $OLLAMA_PORT"
fi

# ═══════════════════════════════════════════════════════════════
# Step 4: Build llama.cpp + llama-server
# ═══════════════════════════════════════════════════════════════
_step "4" "Building llama.cpp (llama-server)"

_LLAMA_BIN="$LLAMA_CPP_DIR/build/bin/llama-server"

if [ "$SKIP_BUILD" = "1" ] && [ -x "$_LLAMA_BIN" ]; then
    _ok "Skipping build (SKIP_BUILD=1), binary exists: $_LLAMA_BIN"
else
    # Clone or update
    if [ -d "$LLAMA_CPP_DIR/.git" ]; then
        _dim "Updating existing llama.cpp..."
        git -C "$LLAMA_CPP_DIR" pull --ff-only 2>/dev/null || true
    else
        _dim "Cloning llama.cpp..."
        git clone --depth 1 https://github.com/ggerganov/llama.cpp.git "$LLAMA_CPP_DIR"
    fi
    _ok "Source ready: $LLAMA_CPP_DIR"

    # Build
    _dim "Building with: cmake $_CMAKE_GPU_FLAGS"
    cd "$LLAMA_CPP_DIR"
    cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLAMA_CURL=ON \
        ${_CMAKE_GPU_FLAGS} \
        2>&1 | tail -5
    cmake --build build --config Release -j "$(nproc)" -- llama-server 2>&1 | tail -10

    if [ -x "$_LLAMA_BIN" ]; then
        _ok "Built: $_LLAMA_BIN"
    else
        _fail "Build failed — llama-server binary not found at $_LLAMA_BIN"
    fi
    cd - >/dev/null
fi

# ═══════════════════════════════════════════════════════════════
# Step 5: Quick smoke test
# ═══════════════════════════════════════════════════════════════
_step "5" "Smoke test"

# Verify llama-server can start (just check --help exits 0)
if "$_LLAMA_BIN" --help &>/dev/null; then
    _ok "llama-server --help OK"
else
    _warn "llama-server --help failed — binary may have missing libraries"
fi

# Print Ollama model count
_model_count=$(curl -sf --max-time 3 "http://127.0.0.1:${OLLAMA_PORT}/api/tags" 2>/dev/null | jq '.models | length' 2>/dev/null || echo "?")
_ok "Ollama models available: $_model_count"

# ═══════════════════════════════════════════════════════════════
# Step 6: Optional systemd services
# ═══════════════════════════════════════════════════════════════
if [ "$INSTALL_SYSTEMD" = "1" ]; then
    _step "6" "Installing systemd service for llama-server"

    _SERVICE_FILE="/etc/systemd/system/llama-server.service"
    $_SUDO tee "$_SERVICE_FILE" > /dev/null << UNIT
[Unit]
Description=llama.cpp inference server (George remote node)
After=network.target ollama.service

[Service]
Type=simple
User=$(whoami)
ExecStart=${_LLAMA_BIN} --port ${LLAMA_CPP_PORT} --jinja -ngl 99 --host 0.0.0.0
Restart=on-failure
RestartSec=5
# Model must be loaded separately via the API or a companion script.
# This service just keeps the server process running.

[Install]
WantedBy=multi-user.target
UNIT

    $_SUDO systemctl daemon-reload
    _ok "Service installed: llama-server.service"
    _dim "Start with: sudo systemctl start llama-server"
    _dim "Enable at boot: sudo systemctl enable llama-server"
    _dim "Note: Load a model via Ollama API or pass -m /path/to/model.gguf"
else
    _step "6" "Skipping systemd install (set INSTALL_SYSTEMD=1 to enable)"
fi

# ═══════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════
printf "\n${C_BOLD}═══ Setup Complete ═══${C_RESET}\n\n"
printf "  %-22s %s\n" "GPU backend:" "$GPU_BACKEND"
printf "  %-22s %s\n" "llama-server:" "$_LLAMA_BIN"
printf "  %-22s %s\n" "Ollama port:" "$OLLAMA_PORT"
printf "  %-22s %s\n" "llama-server port:" "$LLAMA_CPP_PORT"
printf "  %-22s %s\n" "Ollama models:" "$_model_count"

printf "\n${C_BOLD}Next steps:${C_RESET}\n"
_dim "1. Pull models:  ollama pull qwen3:8b"
_dim "2. Load a model: scripts/inference-server-models.sh qwen3:8b"
_dim "3. From George:  /remote setup $(whoami)@$(hostname -I 2>/dev/null | awk '{print $1}')"
_dim "                 /remote connect"
_dim "                 /remote benchmark"
echo ""
