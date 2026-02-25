#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# George (Blue Lodge) — Installation Script
# ═══════════════════════════════════════════════════════════════
# Run: bash install.sh
# Installs George, configures Ollama model, sets up shell.
set -euo pipefail

# ── Error trap: print what failed so the user can troubleshoot ──
_install_error() {
    local exit_code=$?
    local line_no=$1
    echo ""
    printf " \033[38;5;203m✗ Install failed at line %s (exit code %s)\033[0m\n" "$line_no" "$exit_code"
    printf " \033[2mCommand: %s\033[0m\n" "$BASH_COMMAND"
    printf " \033[2mLODGE_DIR=%s\033[0m\n" "${LODGE_DIR:-unset}"
    printf " \033[2mRe-run with: bash -x install.sh  (for full trace)\033[0m\n"
    echo ""
}
trap '_install_error $LINENO' ERR

# Detect where this script lives — install relative to clone location
# Always use the script's actual directory (ignore stale LODGE_DIR from prior installs)
_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LODGE_DIR="$_SCRIPT_DIR"

# ── Early cleanup: remove stale Blue Lodge config from ALL shell RC files ────
# This MUST run before anything else — a stale LODGE_DIR in .bashrc/.zshrc
# from a prior install to a different directory will break git, SSH, and aliases.
# We clean both files unconditionally so moving the install dir always works.
for _rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$_rc_file" ] && grep -q '# ── Blue Lodge' "$_rc_file" 2>/dev/null; then
        sed -i '/# ── Blue Lodge/,/alias lghelp/d' "$_rc_file" 2>/dev/null
        sed -i '/^$/N;/^\n$/d' "$_rc_file" 2>/dev/null
    fi
done

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
IS_PROOT=0
if [ -n "${TERMUX_VERSION:-}" ] || [ -d "/data/data/com.termux" ]; then
    IS_TERMUX=1
fi
# Detect proot-distro: uid 0 (proot fakes root), /host-rootfs, or PROOT_TMP_DIR.
# Inside proot, termux-api commands hang forever — must NOT enable LODGE_TERMUX_API.
if [ "$(id -u)" = "0" ] || [ -d /host-rootfs ] || [ -n "${PROOT_TMP_DIR:-}" ]; then
    IS_PROOT=1
fi

# ── Write shell config IMMEDIATELY after cleanup ─────────────
# This MUST happen before any fallible step (Ollama, model, etc.)
# so the config is never left in a stripped-but-not-rewritten state.
_lodge_shell_block() {
    local termux_line
    if [ "$IS_TERMUX" -eq 1 ] && [ "$IS_PROOT" -eq 0 ]; then
        termux_line='export LODGE_TERMUX_API=1        # Termux-API enabled (native Termux)'
    else
        termux_line='# export LODGE_TERMUX_API=1      # Uncomment in native Termux for phone features'
    fi
    cat << SHELLEOF

# ── Blue Lodge ─────────────────────────────────────────────
export LODGE_DIR="$LODGE_DIR"
export LODGE_MODEL_PRIMARY="blue-lodge-qwen3-think:4b"
export LODGE_MODEL_SECONDARY="blue-lodge-qwen3-inst:4b"
export PATH="\$HOME/.local/bin:\$PATH"
$termux_line

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
}

_rc_written=0
for _rc_file in "$HOME/.zshrc" "$HOME/.bashrc"; do
    if [ -f "$_rc_file" ]; then
        _lodge_shell_block >> "$_rc_file"
        _rc_written=1
    fi
done

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

# Source model library for model creation
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/models.sh" 2>/dev/null || true

# ── 4. Create models ────────────────────────────────────────
info "Creating models (first run may download ~3GB per model)..."

# Primary model (thinking/planning)
if ollama list 2>/dev/null | grep -q "$LODGE_MODEL_PRIMARY"; then
    ok "Primary model '$LODGE_MODEL_PRIMARY' already exists"
else
    info "Creating primary model: $LODGE_MODEL_PRIMARY"
    _mf=$(models_generate_modelfile "qwen3-think")
    ollama create "$LODGE_MODEL_PRIMARY" -f "$_mf"
    ok "Primary model created"
fi

# Secondary model (fast/instruct)
if ollama list 2>/dev/null | grep -q "$LODGE_MODEL_SECONDARY"; then
    ok "Secondary model '$LODGE_MODEL_SECONDARY' already exists"
else
    info "Creating secondary model: $LODGE_MODEL_SECONDARY"
    _mf=$(models_generate_modelfile "qwen3-inst")
    ollama create "$LODGE_MODEL_SECONDARY" -f "$_mf"
    ok "Secondary model created"
fi

# ── 5. Quick model test ─────────────────────────────────────
# Two-phase approach: first, preload model weights into memory (this can
# take 30-60s on ARM with a cold cache). Then test responsiveness with a
# trivial prompt. Separating the two prevents the weight-load time from
# eating into the response timeout.
info "Loading model into memory (first time may take 30-60s)..."
# Phase 1: Preload weights. The /api/generate endpoint with an empty prompt
# and keep_alive loads the model without generating anything.
if curl -sf --connect-timeout 10 --max-time 180 http://127.0.0.1:11434/api/generate \
    -d "{\"model\":\"$LODGE_MODEL_PRIMARY\",\"prompt\":\"\",\"keep_alive\":\"30m\"}" \
    >/dev/null 2>&1; then
    ok "Model loaded"
else
    warn "Model preload timed out — continuing anyway"
fi

info "Testing model responsiveness..."
_MODEL_OK=0
# Phase 2: With weights already in memory, a trivial prompt should respond
# in seconds. budget_tokens:2 = near-zero thinking, num_predict:4 = tiny output.
if curl -sfN --connect-timeout 5 --max-time 30 http://127.0.0.1:11434/api/generate \
    -d "{\"model\":\"$LODGE_MODEL_PRIMARY\",\"prompt\":\"Say OK\",\"stream\":true,\"budget_tokens\":2,\"options\":{\"num_predict\":4}}" \
    2>/dev/null | while IFS= read -r _line; do
        _tok=$(echo "$_line" | jq -r '.response // empty' 2>/dev/null)
        _think=$(echo "$_line" | jq -r '.thinking // empty' 2>/dev/null)
        if [ -n "$_tok" ] || [ -n "$_think" ]; then
            # Got at least one token — model is alive
            exit 0
        fi
        _done=$(echo "$_line" | jq -r '.done // empty' 2>/dev/null)
        [ "$_done" = "true" ] && exit 0
    done; then
    _MODEL_OK=1
fi

if [ "$_MODEL_OK" -eq 1 ]; then
    ok "Model responsive"
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
    export GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"
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
# Already written at top of script (before any fallible step).
if [ "$_rc_written" -eq 1 ]; then
    ok "Shell config written (exports + aliases)"
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
printf " ${DIM}LODGE_DIR=$LODGE_DIR${RESET}\n"
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
# Pick the best RC file to suggest for source command
if [ -f "$HOME/.zshrc" ]; then
    _suggest_rc="$HOME/.zshrc"
elif [ -f "$HOME/.bashrc" ]; then
    _suggest_rc="$HOME/.bashrc"
else
    _suggest_rc="~/.bashrc"
fi
printf " ${YELLOW}→ Run now:  source $_suggest_rc${RESET}\n"
echo ""
