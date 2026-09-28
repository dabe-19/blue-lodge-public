#!/bin/bash
# ── install/profile_compute_node.sh: Sovereign Compute Node Installer ──
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LODGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Installing Sovereign High-Power Compute Node Profile${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"

detect_environment
info "Detected: ${GPU_COUNT} NVIDIA GPU(s) (${GPU_NAMES}) — Total VRAM: $((VRAM_TOTAL_MB / 1024)) GB"

if [ "$GPU_COUNT" -lt 1 ]; then
    warn "No NVIDIA GPUs detected! Compute node profile is optimized for dual or high-VRAM GPUs."
fi

# 1. Setup Model Directory
setup_model_directory "${CUSTOM_MODELS_DIR:-}" "$LODGE_DIR"

# 2. Setup Workspace Virtual Environment (.venv)
if [ ! -d "$LODGE_DIR/.venv" ]; then
    info "Creating Python 3.12 workspace virtual environment (.venv)..."
    python3 -m venv "$LODGE_DIR/.venv" || {
        warn "python3 -m venv failed, attempting pyenv Python 3.12..."
        "$HOME/.pyenv/versions/3.12.3/bin/python3" -m venv "$LODGE_DIR/.venv"
    }
fi

info "Installing training & inference management tools into .venv..."
"$LODGE_DIR/.venv/bin/pip" install --quiet --upgrade pip
"$LODGE_DIR/.venv/bin/pip" install --quiet google-colab-cli PyYAML gguf requests

# 3. Configure lodge.conf for Sovereign PRISM Dual-GPU
CONF_FILE="$LODGE_DIR/.george/lodge.conf"
cat >> "$CONF_FILE" << EOF

# ── Sovereign Compute Node Profile ──
PROFILE_NAME="sovereign_compute_node"
INFERENCE_BACKEND="prism"
PRISM_PORT=8080
PRISM_HOST="0.0.0.0"
PRISM_TENSOR_SPLIT="14,9"
PRISM_CTX_SIZE=65536
AUTONOMIC_ENABLED=1
EOF
ok "Configured ${CONF_FILE} for dual-GPU PRISM"

# 4. Initialize Symlink Profile
"$LODGE_DIR/scripts/switch_inference.sh" sovereign 2>/dev/null || true
ok "Sovereign compute profile activated."
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
