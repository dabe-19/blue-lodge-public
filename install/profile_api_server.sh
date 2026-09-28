#!/bin/bash
# ── install/profile_api_server.sh: Headless Model API Server Installer ──
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LODGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Installing Headless Model API Server Profile${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"

detect_environment

# 1. Setup Model Directory
setup_model_directory "${CUSTOM_MODELS_DIR:-}" "$LODGE_DIR"

# 2. Configure lodge.conf for Headless API Server
CONF_FILE="$LODGE_DIR/.george/lodge.conf"
cat >> "$CONF_FILE" << EOF

# ── Headless Model API Server Profile ──
PROFILE_NAME="headless_api_server"
INFERENCE_BACKEND="prism"
PRISM_PORT=8080
PRISM_HOST="0.0.0.0"
PRISM_CTX_SIZE=65536
HEADLESS_API_ONLY=1
AUTONOMIC_ENABLED=0
EOF
ok "Configured ${CONF_FILE} for headless OpenAI API service"

echo -e "${GREEN}✓ Headless API Server Profile Ready! Serving on port 8080.${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
