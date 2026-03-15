#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# inference-server-deploy.sh — Push provisioning scripts to a remote node
# ═══════════════════════════════════════════════════════════════
# Copies the install + model loader scripts to a remote machine
# and optionally runs the install.  Runs from any George device
# (phone, laptop, Crostini, etc.).
#
# Usage:
#   ./scripts/inference-server-deploy.sh user@gpu-server
#   ./scripts/inference-server-deploy.sh user@gpu-server --install
#   ./scripts/inference-server-deploy.sh user@gpu-server --install --models qwen3:8b
#
# Flags:
#   --install           Run inference-server-install.sh after copying
#   --models <ref>      Run inference-server-models.sh <ref> after install
#   --port <n>          SSH port (default: 22)
#   --key <path>        SSH identity file

set -euo pipefail

# ── Colors ─────────────────────────────────────────────────────
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_CYAN='\033[36m'
C_GREEN='\033[32m'
C_RED='\033[31m'
C_RESET='\033[0m'

_step()  { printf "\n${C_BOLD}${C_CYAN}[%s]${C_RESET} %s\n" "$1" "$2"; }
_ok()    { printf "${C_GREEN}  ✓ %s${C_RESET}\n" "$1"; }
_fail()  { printf "${C_RED}  ✗ %s${C_RESET}\n" "$1"; exit 1; }
_dim()   { printf "${C_DIM}    %s${C_RESET}\n" "$1"; }

# ── Parse args ─────────────────────────────────────────────────
TARGET=""
SSH_PORT="22"
SSH_KEY=""
DO_INSTALL=0
MODEL_REF=""

while [ $# -gt 0 ]; do
    case "$1" in
        --install)  DO_INSTALL=1 ;;
        --models)   shift; MODEL_REF="${1:-}" ;;
        --port)     shift; SSH_PORT="${1:-22}" ;;
        --key)      shift; SSH_KEY="${1:-}" ;;
        --help|-h)
            printf "${C_BOLD}inference-server-deploy.sh${C_RESET} — Deploy George inference node scripts\n\n"
            printf "Usage: %s <user@host> [flags]\n\n" "$0"
            _dim "--install           Run install script after copying"
            _dim "--models <ref>      Pull model + start llama-server after install"
            _dim "--port <n>          SSH port (default: 22)"
            _dim "--key <path>        SSH identity file"
            echo ""
            printf "Examples:\n"
            _dim "$0 user@gpu-server"
            _dim "$0 user@gpu-server --install"
            _dim "$0 user@gpu-server --install --models qwen3:8b"
            exit 0
            ;;
        -*)
            _fail "Unknown flag: $1 (try --help)" ;;
        *)
            [ -z "$TARGET" ] && TARGET="$1" || _fail "Unexpected argument: $1" ;;
    esac
    shift
done

if [ -z "$TARGET" ]; then
    _fail "Usage: $0 <user@host> [--install] [--models <ref>]"
fi

# ── Locate scripts ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/inference-server-install.sh"
MODELS_SCRIPT="$SCRIPT_DIR/inference-server-models.sh"

[ -f "$INSTALL_SCRIPT" ] || _fail "Not found: $INSTALL_SCRIPT"
[ -f "$MODELS_SCRIPT" ]  || _fail "Not found: $MODELS_SCRIPT"

# ── Build SSH/SCP args ─────────────────────────────────────────
_SSH_ARGS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -p "$SSH_PORT")
[ -n "$SSH_KEY" ] && _SSH_ARGS+=(-i "$SSH_KEY")

printf "\n${C_BOLD}═══ Deploy to $TARGET ═══${C_RESET}\n"

# ── Step 1: Test connectivity ──────────────────────────────────
_step "1" "Testing SSH connection to $TARGET"
if ssh "${_SSH_ARGS[@]}" "$TARGET" "echo ok" &>/dev/null; then
    _ok "Connection successful"
else
    _fail "Cannot reach $TARGET on port $SSH_PORT"
fi

# ── Step 2: Copy scripts ──────────────────────────────────────
_step "2" "Copying scripts"
scp "${_SSH_ARGS[@]}" "$INSTALL_SCRIPT" "$MODELS_SCRIPT" "${TARGET}:" 2>/dev/null
_ok "Copied inference-server-install.sh"
_ok "Copied inference-server-models.sh"

# Make executable on remote
ssh "${_SSH_ARGS[@]}" "$TARGET" "chmod +x inference-server-install.sh inference-server-models.sh"
_ok "Set executable permissions"

# ── Step 3: Run install (optional) ─────────────────────────────
if [ "$DO_INSTALL" -eq 1 ]; then
    _step "3" "Running install on $TARGET"
    _dim "This may take a while (building llama.cpp)..."
    ssh "${_SSH_ARGS[@]}" -t "$TARGET" "bash inference-server-install.sh"
    _ok "Install complete"
else
    _step "3" "Skipping install (use --install to run)"
fi

# ── Step 4: Load model (optional) ─────────────────────────────
if [ -n "$MODEL_REF" ]; then
    _step "4" "Loading model: $MODEL_REF"
    ssh "${_SSH_ARGS[@]}" -t "$TARGET" "bash inference-server-models.sh '$MODEL_REF'"
    _ok "Model loaded"
else
    _step "4" "Skipping model load (use --models <ref>)"
fi

# ── Summary ────────────────────────────────────────────────────
printf "\n${C_BOLD}═══ Deploy Complete ═══${C_RESET}\n\n"
_dim "Scripts are in ${TARGET}:~/"
_dim ""
_dim "From the remote node:"
_dim "  bash inference-server-install.sh        # one-time setup"
_dim "  bash inference-server-models.sh qwen3:8b  # pull + load model"
_dim ""
_dim "From George:"
_dim "  /remote setup $TARGET"
_dim "  /remote connect"
echo ""
