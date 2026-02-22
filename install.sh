#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# Blue Lodge — Installation Script
# ═══════════════════════════════════════════════════════════════
# Run: bash install.sh
# Installs Blue Lodge, configures Ollama model, sets up shell.
set -euo pipefail

LODGE_DIR="$HOME/blue-lodge"
BLUE='\033[38;5;33m'
GREEN='\033[38;5;114m'
YELLOW='\033[38;5;221m'
RED='\033[38;5;203m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

info()  { printf " ${BLUE}●${RESET} %s\n" "$1"; }
ok()    { printf " ${GREEN}✓${RESET} %s\n" "$1"; }
warn()  { printf " ${YELLOW}⚠${RESET} %s\n" "$1"; }
err()   { printf " ${RED}✗${RESET} %s\n" "$1"; }

echo ""
printf " ${BOLD}⌂ Blue Lodge Installer${RESET}\n"
echo ""

# ── 1. Check dependencies ────────────────────────────────────
info "Checking dependencies..."

MISSING=()
command -v curl &>/dev/null  || MISSING+=("curl")
command -v jq   &>/dev/null  || MISSING+=("jq")
command -v git  &>/dev/null  || MISSING+=("git")

if [ ${#MISSING[@]} -gt 0 ]; then
    warn "Missing: ${MISSING[*]}"
    info "Installing..."
    if command -v apt &>/dev/null; then
        sudo apt update -qq && sudo apt install -y -qq "${MISSING[@]}"
    elif command -v pkg &>/dev/null; then
        pkg install -y "${MISSING[@]}"
    else
        err "Cannot auto-install. Please install: ${MISSING[*]}"
        exit 1
    fi
fi
ok "Dependencies ready"

# ── 2. Check Ollama ──────────────────────────────────────────
info "Checking Ollama..."
if ! command -v ollama &>/dev/null; then
    warn "Ollama not found. Installing..."
    curl -fsSL https://ollama.com/install.sh | sh
fi
ok "Ollama installed"

# ── 3. Ensure Ollama is running ──────────────────────────────
if ! curl -sf http://127.0.0.1:11434/api/tags &>/dev/null; then
    info "Starting Ollama..."
    ollama serve > /tmp/lodge-ollama.log 2>&1 &
    sleep 3
    if ! curl -sf http://127.0.0.1:11434/api/tags &>/dev/null; then
        err "Ollama failed to start. Check /tmp/lodge-ollama.log"
        exit 1
    fi
fi
ok "Ollama running"

# ── 4. Create the model ─────────────────────────────────────
info "Creating blue-lodge model (this may download ~3GB on first run)..."
if ollama list 2>/dev/null | grep -q "blue-lodge"; then
    ok "Model 'blue-lodge' already exists"
else
    ollama create blue-lodge -f "$LODGE_DIR/Modelfile"
    ok "Model created"
fi

# ── 5. Quick model test ─────────────────────────────────────
info "Testing model responsiveness..."
RESPONSE=$(curl -sf --max-time 60 http://127.0.0.1:11434/api/generate \
    -d '{"model":"blue-lodge","prompt":"Reply with only: OK","stream":false,"options":{"num_predict":5}}' \
    | jq -r '.response' 2>/dev/null || echo "TIMEOUT")

if [[ "$RESPONSE" == *"OK"* ]] || [ -n "$RESPONSE" ] && [ "$RESPONSE" != "TIMEOUT" ]; then
    ok "Model responds: $RESPONSE"
else
    warn "Model slow or unresponsive. It may need a warm-up on first run."
fi

# ── 6. Make lodge executable ─────────────────────────────────
chmod +x "$LODGE_DIR/lodge"
chmod +x "$LODGE_DIR/commands/"*.sh 2>/dev/null || true
ok "Scripts are executable"

# ── 7. Add to PATH ──────────────────────────────────────────
info "Setting up shell integration..."

# Create a bin symlink
mkdir -p "$HOME/.local/bin"
ln -sf "$LODGE_DIR/lodge" "$HOME/.local/bin/lodge"
ok "Symlinked: lodge → ~/.local/bin/lodge"

# ── 8. Shell config ─────────────────────────────────────────
SHELL_RC=""
if [ -f "$HOME/.zshrc" ]; then
    SHELL_RC="$HOME/.zshrc"
elif [ -f "$HOME/.bashrc" ]; then
    SHELL_RC="$HOME/.bashrc"
fi

if [ -n "$SHELL_RC" ]; then
    # Check if already configured
    if ! grep -q "LODGE_DIR" "$SHELL_RC" 2>/dev/null; then
        cat >> "$SHELL_RC" << 'SHELLEOF'

# ── Blue Lodge ─────────────────────────────────────────────
export LODGE_DIR="$HOME/blue-lodge"
export LODGE_MODEL="blue-lodge"
export PATH="$HOME/.local/bin:$PATH"

# Aliases
alias lodge="$LODGE_DIR/lodge"
alias lg="lodge"                    # Quick alias
alias lgi="lodge /init"             # Scaffold project
alias lgf="lodge /fix"              # Fix errors
alias lgt="lodge /test"             # Run tests
alias lgb="lodge /build"            # Build project
alias lgc="lodge /commit"           # Smart commit
alias lgp="lodge /push"             # Push to GitHub
alias lgs="lodge /status"           # Agent status
alias lgm="lodge /memory"           # Show memory
alias lgx="lodge /sandbox"          # Sandbox management
alias lgcl="lodge /clone"           # Clone repo
alias lghelp="lodge /help"          # Show help
SHELLEOF
        ok "Added Blue Lodge config to $SHELL_RC"
    else
        ok "Shell already configured"
    fi
else
    warn "No .zshrc or .bashrc found. Add manually:"
    echo "  export LODGE_DIR=\"\$HOME/blue-lodge\""
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# ── 9. Remove Claude Code (if present) ──────────────────────
echo ""
if command -v claude &>/dev/null; then
    warn "Claude Code CLI detected."
    printf " Remove it? [y/N] "
    read -r remove_claude
    if [[ "${remove_claude,,}" == "y"* ]]; then
        info "Removing Claude Code..."
        # npm global uninstall
        npm uninstall -g @anthropic-ai/claude-code 2>/dev/null || true
        # Clean up env vars from shell rc
        if [ -n "$SHELL_RC" ]; then
            sed -i '/ANTHROPIC_BASE_URL/d' "$SHELL_RC" 2>/dev/null
            sed -i '/ANTHROPIC_AUTH_TOKEN/d' "$SHELL_RC" 2>/dev/null
            sed -i '/ANTHROPIC_API_KEY/d' "$SHELL_RC" 2>/dev/null
            sed -i '/CLAUDE_CODE_MAX_CONCURRENT/d' "$SHELL_RC" 2>/dev/null
        fi
        # Kill proxy if running
        pkill -f "anthropic-proxy" 2>/dev/null || true
        # Remove proxy binary
        rm -f "$HOME/.cargo/bin/anthropic-proxy" 2>/dev/null
        # Clean config dir
        rm -rf "$HOME/.claude" 2>/dev/null
        ok "Claude Code removed"
    else
        ok "Keeping Claude Code (it won't conflict)"
    fi
fi

# ── 10. Remove old qwen-lab setup ────────────────────────────
if [ -f "$HOME/qwen-lab.sh" ]; then
    info "Found old qwen-lab.sh"
    printf " Remove it? [y/N] "
    read -r remove_lab
    if [[ "${remove_lab,,}" == "y"* ]]; then
        rm -f "$HOME/qwen-lab.sh"
        # Remove old model
        ollama rm claude-oryon 2>/dev/null || true
        ok "Old setup cleaned"
    fi
fi

# ── Done ─────────────────────────────────────────────────────
echo ""
printf " ${GREEN}${BOLD}⌂ Blue Lodge installed!${RESET}\n"
echo ""
printf " ${DIM}Reload your shell, then:${RESET}\n"
echo ""
printf "   ${BLUE}lodge${RESET}                    # Interactive mode\n"
printf "   ${BLUE}lodge /init myapp rust${RESET}   # New Rust project\n"
printf "   ${BLUE}lodge \"add CLI parsing\"${RESET}  # Give it a task\n"
printf "   ${BLUE}lodge /help${RESET}              # All commands\n"
echo ""
printf " ${DIM}Or use short aliases: lg, lgi, lgf, lgt, lgb, lgc${RESET}\n"
echo ""
printf " ${DIM}Reload shell: source $SHELL_RC${RESET}\n"
echo ""
