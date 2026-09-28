#!/bin/bash
# ── install/profile_mobile.sh: Mobile & Edge Node Installer ──
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LODGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Installing Mobile / Edge Node Profile (Termux/PRoot/iSH)${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"

detect_environment
info "Environment: Termux=$IS_TERMUX, PRoot=$IS_PROOT, iSH=$IS_ISH"

# 1. Setup Model Directory
setup_model_directory "${CUSTOM_MODELS_DIR:-}" "$LODGE_DIR"

# 2. Configure lodge.conf for Mobile/Edge (2B-4B models, low footprint)
CONF_FILE="$LODGE_DIR/.george/lodge.conf"
cat >> "$CONF_FILE" << EOF

# ── Mobile & Edge Node Profile ──
PROFILE_NAME="mobile_edge_node"
INFERENCE_BACKEND="ollama"
OLLAMA_HOST="http://127.0.0.1:11434"
DEFAULT_MODEL="qwen2.5:3b"
LOW_MEMORY_MODE=1
AUTONOMIC_ENABLED=0
EOF
ok "Configured ${CONF_FILE} for mobile edge device"

echo -e "${GREEN}✓ Mobile / Edge Profile Ready!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
