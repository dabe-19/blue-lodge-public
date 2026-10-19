#!/bin/bash
# ── install/profile_workstation.sh: Developer Workstation Installer ──
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LODGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Installing Developer Workstation Profile${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"

detect_environment
info "Detected platform: WSL=$IS_WSL, Linux=$IS_LINUX, macOS=$IS_MACOS"

# 1. Setup Model Directory
setup_model_directory "${CUSTOM_MODELS_DIR:-}" "$LODGE_DIR"

# 2. Configure lodge.conf for Workstation (8B–14B models, local UI)
CONF_FILE="$LODGE_DIR/.george/lodge.conf"
cat >> "$CONF_FILE" << EOF

# ── Developer Workstation Profile ──
PROFILE_NAME="developer_workstation"
INFERENCE_BACKEND="prism"
PRISM_PORT=8080
PRISM_HOST="127.0.0.1"
PRISM_CTX_SIZE=32768
WEB_UI_PORT=3000
AUTONOMIC_ENABLED=1
EOF
ok "Configured ${CONF_FILE} for developer workstation"

echo -e "${GREEN}✓ Developer Workstation Profile Ready!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
