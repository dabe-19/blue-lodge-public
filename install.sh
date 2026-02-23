#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# George (Blue Lodge) — Installation Script
# ═══════════════════════════════════════════════════════════════
# Run: bash install.sh
# Installs George, configures Ollama model, sets up shell.
set -euo pipefail

# Detect where this script lives — install relative to clone location
_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LODGE_DIR="${LODGE_DIR:-$_SCRIPT_DIR}"
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

# ── Detect environment ────────────────────────────────────────
IS_TERMUX=0
if [ -n "${TERMUX_VERSION:-}" ] || [ -d "/data/data/com.termux" ]; then
    IS_TERMUX=1
fi

echo ""
printf " ${BOLD}⌂ George Installer${RESET}\n"
if [ "$IS_TERMUX" -eq 1 ]; then
    printf " ${DIM}Detected: Termux (native Android)${RESET}\n"
fi
echo ""

# ── 1. Check dependencies ────────────────────────────────────
info "Checking dependencies..."

MISSING=()
command -v curl &>/dev/null  || MISSING+=("curl")
command -v jq   &>/dev/null  || MISSING+=("jq")
command -v git  &>/dev/null  || MISSING+=("git")
command -v sqlite3 &>/dev/null || MISSING+=("sqlite3")

if [ ${#MISSING[@]} -gt 0 ]; then
    warn "Missing: ${MISSING[*]}"
    info "Installing..."
    if [ "$IS_TERMUX" -eq 1 ]; then
        # Termux uses 'sqlite' not 'sqlite3' as the package name
        local_pkgs=()
        for dep in "${MISSING[@]}"; do
            if [ "$dep" = "sqlite3" ]; then
                local_pkgs+=("sqlite")
            else
                local_pkgs+=("$dep")
            fi
        done
        pkg install -y "${local_pkgs[@]}"
    elif command -v apt &>/dev/null; then
        sudo apt update -qq && sudo apt install -y -qq "${MISSING[@]}"
    elif command -v pkg &>/dev/null; then
        pkg install -y "${MISSING[@]}"
    else
        err "Cannot auto-install. Please install: ${MISSING[*]}"
        exit 1
    fi
fi
ok "Dependencies ready"

# ── 1b. Termux extras (gawk, procps, bc) ─────────────────────
# Termux ships mawk by default which has NUL byte issues.
# procps provides 'free' for vitals. bc for location math.
if [ "$IS_TERMUX" -eq 1 ]; then
    TERMUX_EXTRAS=()
    command -v gawk &>/dev/null || TERMUX_EXTRAS+=("gawk")
    command -v free &>/dev/null || TERMUX_EXTRAS+=("procps")
    command -v bc   &>/dev/null || TERMUX_EXTRAS+=("bc")
    if [ ${#TERMUX_EXTRAS[@]} -gt 0 ]; then
        info "Installing Termux extras: ${TERMUX_EXTRAS[*]}"
        pkg install -y "${TERMUX_EXTRAS[@]}"
    fi
    # Install termux-api if Termux:API app is present
    if [ ! -f "${PREFIX:-/data/data/com.termux/files/usr}/bin/termux-battery-status" ]; then
        info "Installing termux-api (phone integration)..."
        pkg install -y termux-api 2>/dev/null || warn "termux-api install failed — install manually: pkg install termux-api"
    fi
fi

# ── 2. Check Ollama ──────────────────────────────────────────
info "Checking Ollama..."
if ! command -v ollama &>/dev/null; then
    warn "Ollama not found. Installing..."
    if [ "$IS_TERMUX" -eq 1 ]; then
        info "Downloading Ollama for Termux (ARM64)..."
        # The install.sh from ollama.com expects systemd — use direct binary instead
        OLLAMA_VER=$(curl -sf https://api.github.com/repos/ollama/ollama/releases/latest | jq -r '.tag_name' 2>/dev/null || echo "v0.6.2")
        OLLAMA_URL="https://github.com/ollama/ollama/releases/download/${OLLAMA_VER}/ollama-linux-arm64.tgz"
        mkdir -p "$HOME/.local/bin"
        curl -fSL "$OLLAMA_URL" | tar xz -C "$HOME/.local/bin/" 2>/dev/null \
            || curl -fSL "https://github.com/ollama/ollama/releases/download/${OLLAMA_VER}/ollama-linux-arm64" -o "$HOME/.local/bin/ollama"
        chmod +x "$HOME/.local/bin/ollama"
        export PATH="$HOME/.local/bin:$PATH"
    else
        curl -fsSL https://ollama.com/install.sh | sh
    fi
fi
ok "Ollama installed"

# ── 3. Ensure Ollama is running ──────────────────────────────
if ! curl -sf http://127.0.0.1:11434/api/tags &>/dev/null; then
    info "Starting Ollama..."
    local_tmpdir="${TMPDIR:-/tmp}"
    ollama serve > "$local_tmpdir/lodge-ollama.log" 2>&1 &
    sleep 3
    if ! curl -sf http://127.0.0.1:11434/api/tags &>/dev/null; then
        err "Ollama failed to start. Check $local_tmpdir/lodge-ollama.log"
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

# ── 7. Bootstrap knowledge base ──────────────────────────────
info "Indexing knowledge base (FTS5)..."
if command -v sqlite3 &>/dev/null; then
    # Source the recall system and index all docs
    export LODGE_DIR
    export GEORGE_DIR="${GEORGE_DIR:-$HOME/.george}"
    mkdir -p "$GEORGE_DIR"
    source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
    source "$LODGE_DIR/lib/recall.sh" 2>/dev/null
    if recall_available 2>/dev/null; then
        recall_reindex 2>/dev/null
        local_chunks=$(sqlite3 "$GEORGE_DIR/recall.db" "SELECT COUNT(*) FROM chunks;" 2>/dev/null || echo "0")
        ok "Knowledge base ready ($local_chunks chunks indexed)"
    else
        warn "sqlite3 FTS5 not available — recall will be disabled"
        warn "Install with: apt install sqlite3 (or: pkg install sqlite)"
    fi
else
    warn "sqlite3 not found — knowledge base not indexed"
    warn "George will auto-index on first run if sqlite3 is installed"
fi

# ── 8. Add to PATH ──────────────────────────────────────────
info "Setting up shell integration..."

# Create a bin symlink
mkdir -p "$HOME/.local/bin"
ln -sf "$LODGE_DIR/lodge" "$HOME/.local/bin/lodge"
ok "Symlinked: lodge → ~/.local/bin/lodge"

# ── 9. Shell config ─────────────────────────────────────────
SHELL_RC=""
if [ -f "$HOME/.zshrc" ]; then
    SHELL_RC="$HOME/.zshrc"
elif [ -f "$HOME/.bashrc" ]; then
    SHELL_RC="$HOME/.bashrc"
fi

if [ -n "$SHELL_RC" ]; then
    # Check if already configured
    if ! grep -q "LODGE_DIR" "$SHELL_RC" 2>/dev/null; then
        # Detect if running in native Termux (not proot) — safe to enable Termux-API
        local_termux_api_line=""
        if [ "$IS_TERMUX" -eq 1 ] && [ -z "${PROOT_TMP_DIR:-}" ] && [ ! -d /host-rootfs ]; then
            local_termux_api_line='export LODGE_TERMUX_API=1        # Termux-API enabled (native Termux)'
        else
            local_termux_api_line='# export LODGE_TERMUX_API=1      # Uncomment in native Termux for phone features'
        fi
        cat >> "$SHELL_RC" << SHELLEOF

# ── Blue Lodge ─────────────────────────────────────────────
export LODGE_DIR="$LODGE_DIR"
export LODGE_MODEL="blue-lodge"
export PATH="\$HOME/.local/bin:\$PATH"
$local_termux_api_line

# Aliases
alias lodge="\$LODGE_DIR/lodge"
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
    echo "  export LODGE_DIR=\"$LODGE_DIR\""
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# ── 10. Remove Claude Code (if present) ──────────────────────
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

# ── 11. Remove old qwen-lab setup ────────────────────────────
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
