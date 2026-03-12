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
        sed -i '/# ── Blue Lodge Cloud Provider/,/^export [A-Z_]*_API_KEY=/d' "$_rc_file" 2>/dev/null || true
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
IS_ISH=0
if [ -n "${TERMUX_VERSION:-}" ] || [ -d "/data/data/com.termux" ]; then
    IS_TERMUX=1
fi
# Detect proot-distro: uid 0 (proot fakes root), /host-rootfs, or PROOT_TMP_DIR.
# Inside proot, termux-api commands hang forever — must NOT enable LODGE_TERMUX_API.
if [ "$(id -u)" = "0" ] || [ -d /host-rootfs ] || [ -n "${PROOT_TMP_DIR:-}" ]; then
    IS_PROOT=1
fi
# Detect iSH (Alpine Linux on iOS/iPadOS).
# iSH exposes /proc/ish/version; fallback: Alpine + i686 arch.
# No Ollama/llama-server possible — cloud providers only.
if [ -f /proc/ish/version ] || ([ -f /etc/os-release ] && grep -qi 'alpine' /etc/os-release 2>/dev/null && [ "$(uname -m)" = "i686" ]); then
    IS_ISH=1
fi

# ── Write shell config IMMEDIATELY after cleanup ─────────────
# This MUST happen before any fallible step (Ollama, model, etc.)
# so the config is never left in a stripped-but-not-rewritten state.
_lodge_shell_block() {
    local termux_line
    local ollama_models_line
    if [ "$IS_TERMUX" -eq 1 ] && [ "$IS_PROOT" -eq 0 ]; then
        termux_line='export LODGE_TERMUX_API=1        # Termux-API enabled (native Termux)'
        ollama_models_line='# export OLLAMA_MODELS="\$HOME/.ollama/models"  # Native Termux (default is correct)'
    else
        termux_line='# export LODGE_TERMUX_API=1      # Uncomment in native Termux for phone features'
        # Inside proot, $HOME=/root/ but Ollama models live in Termux-native home.
        # Without this, 'ollama serve' from proot sees zero models.
        if [ -d "/data/data/com.termux/files/home/.ollama/models" ]; then
            ollama_models_line='export OLLAMA_MODELS="/data/data/com.termux/files/home/.ollama/models"  # proot→Termux path'
        elif [ -d "/usr/share/ollama/.ollama/models" ]; then
            ollama_models_line='export OLLAMA_MODELS="/usr/share/ollama/.ollama/models" # Linux systemd path'
        else
            ollama_models_line='# export OLLAMA_MODELS=          # Set if Ollama models are at a non-default path'
        fi
    fi
    cat << SHELLEOF

# ── Blue Lodge ─────────────────────────────────────────────
export LODGE_DIR="$LODGE_DIR"
export LODGE_MODEL_PRIMARY="blue-lodge-minist-inst:4b"
export LODGE_MODEL_SECONDARY="blue-lodge-minist-inst:4b"
export PATH="\$HOME/.local/bin:\$PATH"
$termux_line
$ollama_models_line

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
if [ "$IS_ISH" -eq 1 ]; then
    printf " ${DIM}Detected: iSH (Alpine Linux on iOS) — cloud-only mode${RESET}\n"
elif [ "$IS_TERMUX" -eq 1 ]; then
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
    if [ "$IS_ISH" -eq 1 ] || command -v apk &>/dev/null; then
        # iSH / Alpine: use apk; sqlite3 package is 'sqlite'
        local_pkgs=()
        for dep in "${MISSING[@]}"; do
            if [ "$dep" = "sqlite3" ]; then
                local_pkgs+=("sqlite")
            else
                local_pkgs+=("$dep")
            fi
        done
        apk add --no-cache "${local_pkgs[@]}"
    elif [ "$IS_TERMUX" -eq 1 ] && [ "$IS_PROOT" -eq 0 ]; then
        # Native Termux uses 'sqlite' not 'sqlite3' as the package name
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
        if [ "$(id -u)" = "0" ]; then
            apt update -qq && apt install -y -qq "${MISSING[@]}"
        else
            sudo apt update -qq && sudo apt install -y -qq "${MISSING[@]}"
        fi
    elif command -v pkg &>/dev/null; then
        pkg install -y "${MISSING[@]}"
    else
        err "Cannot auto-install. Please install: ${MISSING[*]}"
        exit 1
    fi
fi
ok "Dependencies ready"

# ── 1b. Optional: PDF text extraction ────────────────────────
# pdftotext (poppler-utils) lets /web read PDF documents.
# Without it, George falls back to strings(1) — functional but
# lower fidelity. Skip to keep the install minimal.
if ! command -v pdftotext &>/dev/null; then
    printf "\n"
    info "Optional: pdftotext enables high-quality PDF text extraction."
    info "Without it, /web will still read PDFs using strings (basic fallback)."
    printf "  Install poppler-utils for better PDF support? [y/N] "
    read -r _install_poppler
    if [[ "$_install_poppler" =~ ^[Yy] ]]; then
        if [ "$IS_ISH" -eq 1 ] || command -v apk &>/dev/null; then
            apk add --no-cache poppler-utils 2>/dev/null || warn "poppler-utils install failed — will use fallback"
        elif [ "$IS_PROOT" -eq 1 ] && command -v apt &>/dev/null; then
            # proot-distro Ubuntu: apt works, pkg does not
            apt install -y -qq poppler-utils 2>/dev/null || warn "poppler-utils install failed — will use fallback"
        elif [ "$IS_TERMUX" -eq 1 ] && [ "$IS_PROOT" -eq 0 ]; then
            pkg install -y poppler 2>/dev/null || warn "poppler install failed — will use fallback"
        elif command -v apt &>/dev/null; then
            sudo apt install -y -qq poppler-utils 2>/dev/null || warn "poppler-utils install failed — will use fallback"
        elif command -v pkg &>/dev/null; then
            pkg install -y poppler-utils 2>/dev/null || warn "poppler-utils install failed — will use fallback"
        else
            warn "No supported package manager — install poppler-utils manually for PDF support"
        fi
    else
        info "Skipped — PDFs will use strings(1) fallback"
    fi
fi

# ── 1c. Optional: MQTT pub/sub messaging ─────────────────────
# mosquitto-clients (mosquitto_pub + mosquitto_sub) are small C
# binaries (~200 KB total) that give George MQTT capabilities.
# No Python, Node.js, or Java — pure C with only libc + libssl.
if ! command -v mosquitto_pub &>/dev/null; then
    printf "\n"
    info "Optional: mosquitto-clients enables MQTT pub/sub messaging."
    info "Without it, /mqtt commands will not be available."
    printf "  Install mosquitto-clients for MQTT support? [y/N] "
    read -r _install_mqtt
    if [[ "$_install_mqtt" =~ ^[Yy] ]]; then
        if [ "$IS_ISH" -eq 1 ] || command -v apk &>/dev/null; then
            apk add --no-cache mosquitto-clients 2>/dev/null || warn "mosquitto-clients install failed"
        elif [ "$IS_PROOT" -eq 1 ] && command -v apt &>/dev/null; then
            apt install -y -qq mosquitto-clients 2>/dev/null || warn "mosquitto-clients install failed"
        elif [ "$IS_TERMUX" -eq 1 ] && [ "$IS_PROOT" -eq 0 ]; then
            pkg install -y mosquitto 2>/dev/null || warn "mosquitto install failed"
        elif command -v apt &>/dev/null; then
            sudo apt install -y -qq mosquitto-clients 2>/dev/null || warn "mosquitto-clients install failed"
        elif command -v pkg &>/dev/null; then
            pkg install -y mosquitto-clients 2>/dev/null || warn "mosquitto-clients install failed"
        else
            warn "No supported package manager — install mosquitto-clients manually for MQTT support"
        fi
    else
        info "Skipped — /mqtt commands will not be available"
    fi
fi

# ── 1d. Termux extras (gawk, procps, bc) ─────────────────────
# Termux ships mawk by default which has NUL byte issues.
# procps provides 'free' for vitals. bc for location math.
# Skip in proot-distro — these are standard Ubuntu packages.
if [ "$IS_TERMUX" -eq 1 ] && [ "$IS_PROOT" -eq 0 ]; then
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

# ── 1d. iSH extras (gawk, coreutils, grep, sed, bash) ────────
# iSH ships BusyBox with minimal tool variants. George needs
# GNU grep (-oE), GNU awk, GNU date, readlink, bash 4+, etc.
if [ "$IS_ISH" -eq 1 ]; then
    ISH_EXTRAS=()
    # bash 4+ for associative arrays, namerefs
    command -v bash &>/dev/null || ISH_EXTRAS+=("bash")
    # GNU grep for -oE (extended regex)
    command -v gawk &>/dev/null || ISH_EXTRAS+=("gawk")
    # GNU coreutils for readlink -f, mktemp, date, etc.
    command -v readlink &>/dev/null || ISH_EXTRAS+=("coreutils")
    # GNU grep — BusyBox grep lacks -oP
    grep --version 2>&1 | grep -q "GNU" || ISH_EXTRAS+=("grep")
    # GNU sed for in-place editing
    sed --version 2>&1 | grep -q "GNU" || ISH_EXTRAS+=("sed")
    if [ ${#ISH_EXTRAS[@]} -gt 0 ]; then
        info "Installing iSH extras: ${ISH_EXTRAS[*]}"
        apk add --no-cache "${ISH_EXTRAS[@]}" 2>/dev/null || warn "Some iSH extras failed — install manually: apk add ${ISH_EXTRAS[*]}"
    fi

    # iSH doesn't mount /dev/fd — Bash process substitution (<(...))
    # requires it. Create the symlink so while-read loops work.
    if [ ! -e /dev/fd ]; then
        if [ -d /proc/self/fd ]; then
            ln -sf /proc/self/fd /dev/fd 2>/dev/null && ok "/dev/fd symlinked (needed for Bash)" \
                || warn "/dev/fd missing — some recall features may not work"
        else
            warn "/dev/fd and /proc/self/fd missing — process substitution unavailable"
            warn "Some features (recall indexing) may use fallback paths"
        fi
    fi
fi

# ── 2. Check Ollama ──────────────────────────────────────────
_OLLAMA_AVAILABLE=0
if [ "$IS_ISH" -eq 1 ]; then
    info "iSH detected — skipping local LLM backend (Ollama/llama-server)"
    info "George will use cloud providers for all inference"
else
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
        curl -fsSL https://ollama.com/install.sh | sh || {
            warn "Ollama install failed ($(uname -m) may not be supported)"
            warn "George can run with cloud providers: lodge /provider use google"
        }
    fi
fi
if command -v ollama &>/dev/null; then
    _OLLAMA_AVAILABLE=1
    ok "Ollama installed"
else
    warn "Ollama not available — local models disabled"
    warn "Use cloud providers: export GEORGE_PROVIDER=google"
fi
fi  # end IS_ISH guard for Ollama

# ── 2b. Cloud provider setup ─────────────────────────────────
# If Ollama isn't available (or the user prefers cloud), offer to
# configure a cloud provider so George works out of the box.
_INSTALL_PROVIDER=""
_INSTALL_PROVIDER_KEY_NAME=""
_INSTALL_PROVIDER_KEY_VALUE=""

_offer_cloud_setup() {
    echo ""
    printf " ${BOLD}Cloud Provider Setup${RESET}\n"
    printf " ${DIM}George can use cloud LLM APIs instead of (or alongside) local models.${RESET}\n"
    printf " ${DIM}Free tiers available from Google and Groq — no credit card needed.${RESET}\n"
    echo ""
    printf "   ${BLUE}google${RESET}      Google AI (Gemini) — free tier, recommended\n"
    printf "   ${BLUE}groq${RESET}        Groq — free tier, very fast\n"
    printf "   ${BLUE}openai${RESET}      OpenAI (GPT) — paid\n"
    printf "   ${BLUE}anthropic${RESET}   Anthropic (Claude) — paid\n"
    printf "   ${BLUE}mistral${RESET}     Mistral AI — free tier available\n"
    printf "   ${BLUE}deepseek${RESET}    DeepSeek — very cheap\n"
    printf "   ${BLUE}together${RESET}    Together AI — free tier available\n"
    printf "   ${BLUE}xai${RESET}         xAI (Grok) — paid\n"
    printf "   ${BLUE}cohere${RESET}      Cohere — free tier available\n"
    echo ""
    printf " Enter a provider name, or press Enter to skip: "
    read -r _chosen_provider

    [ -z "$_chosen_provider" ] && return 0

    # Normalize and validate
    case "$_chosen_provider" in
        google|gemini)      _INSTALL_PROVIDER="google";    _INSTALL_PROVIDER_KEY_NAME="GOOGLE_AI_API_KEY" ;;
        groq)               _INSTALL_PROVIDER="groq";      _INSTALL_PROVIDER_KEY_NAME="GROQ_API_KEY" ;;
        openai|gpt)         _INSTALL_PROVIDER="openai";    _INSTALL_PROVIDER_KEY_NAME="OPENAI_API_KEY" ;;
        anthropic|claude)   _INSTALL_PROVIDER="anthropic"; _INSTALL_PROVIDER_KEY_NAME="ANTHROPIC_API_KEY" ;;
        mistral)            _INSTALL_PROVIDER="mistral";   _INSTALL_PROVIDER_KEY_NAME="MISTRAL_API_KEY" ;;
        deepseek)           _INSTALL_PROVIDER="deepseek";  _INSTALL_PROVIDER_KEY_NAME="DEEPSEEK_API_KEY" ;;
        together)           _INSTALL_PROVIDER="together";  _INSTALL_PROVIDER_KEY_NAME="TOGETHER_API_KEY" ;;
        xai|grok)           _INSTALL_PROVIDER="xai";       _INSTALL_PROVIDER_KEY_NAME="XAI_API_KEY" ;;
        cohere)             _INSTALL_PROVIDER="cohere";     _INSTALL_PROVIDER_KEY_NAME="COHERE_API_KEY" ;;
        *)
            warn "Unknown provider '$_chosen_provider' — skipping cloud setup"
            return 0
            ;;
    esac

    # Check if the API key is already in the environment
    eval "_existing_key=\${${_INSTALL_PROVIDER_KEY_NAME}:-}"
    if [ -n "$_existing_key" ]; then
        ok "$_INSTALL_PROVIDER_KEY_NAME already set"
        _INSTALL_PROVIDER_KEY_VALUE="$_existing_key"
    else
        echo ""
        printf " ${DIM}Get your API key from the provider's dashboard.${RESET}\n"
        case "$_INSTALL_PROVIDER" in
            google)    printf " ${DIM}  → https://aistudio.google.com/apikey${RESET}\n" ;;
            groq)      printf " ${DIM}  → https://console.groq.com/keys${RESET}\n" ;;
            openai)    printf " ${DIM}  → https://platform.openai.com/api-keys${RESET}\n" ;;
            anthropic) printf " ${DIM}  → https://console.anthropic.com/settings/keys${RESET}\n" ;;
        esac
        printf " Enter your ${BOLD}$_INSTALL_PROVIDER_KEY_NAME${RESET}: "
        read -r _INSTALL_PROVIDER_KEY_VALUE

        if [ -z "$_INSTALL_PROVIDER_KEY_VALUE" ]; then
            warn "No API key entered — skipping cloud setup"
            _INSTALL_PROVIDER=""
            return 0
        fi
    fi

    ok "Cloud provider: $_INSTALL_PROVIDER"
}

if [ "$IS_ISH" -eq 1 ]; then
    info "Cloud provider required — iSH cannot run local models"
    _offer_cloud_setup
    if [ -z "$_INSTALL_PROVIDER" ]; then
        warn "No provider configured — George will need one before it can run"
        warn "  Set later: lodge /provider use google"
    fi
elif [ "$_OLLAMA_AVAILABLE" -eq 0 ]; then
    warn "No local LLM backend — cloud provider required"
    _offer_cloud_setup
    if [ -z "$_INSTALL_PROVIDER" ]; then
        warn "No provider configured — George will need one before it can run"
        warn "  Set later: export GEORGE_PROVIDER=google && lodge"
    fi
else
    printf "\n"
    printf " ${DIM}Want to also configure a cloud provider (for fallback or remote use)?${RESET}\n"
    printf " Configure cloud provider? [y/N] "
    read -r _want_cloud
    if [[ "$_want_cloud" =~ ^[Yy] ]]; then
        _offer_cloud_setup
    fi
fi

# Write provider config to shell RC (append after the existing Blue Lodge block)
if [ -n "$_INSTALL_PROVIDER" ]; then
    _provider_block=$(cat << 'PROVEOF'

# ── Blue Lodge Cloud Provider ──────────────────────────────
PROVEOF
    )
    _provider_block+=$'\n'"export GEORGE_PROVIDER='$_INSTALL_PROVIDER'"
    _provider_block+=$'\n'"export $_INSTALL_PROVIDER_KEY_NAME='$_INSTALL_PROVIDER_KEY_VALUE'"

    for _rc_file in "$HOME/.zshrc" "$HOME/.bashrc"; do
        if [ -f "$_rc_file" ] && grep -q '# ── Blue Lodge' "$_rc_file" 2>/dev/null; then
            echo "$_provider_block" >> "$_rc_file"
        fi
    done
    # Also export for this session so steps below can use it
    export GEORGE_PROVIDER="$_INSTALL_PROVIDER"
    export "$_INSTALL_PROVIDER_KEY_NAME=$_INSTALL_PROVIDER_KEY_VALUE"

    # Persist API key into keys.conf so George's runtime can find it.
    # The shell RC export works for new shell sessions, but the provider
    # system reads keys from keys.conf via api_get_key().
    _IST_CONFIG_DIR="${GEORGE_CONFIG_DIR:-$LODGE_DIR/.george}"
    _IST_KEYS_FILE="$_IST_CONFIG_DIR/keys.conf"
    mkdir -p "$_IST_CONFIG_DIR"
    chmod 700 "$_IST_CONFIG_DIR"
    # Source api.sh to get api_set_key if not already loaded
    if declare -f api_set_key &>/dev/null; then
        api_set_key "$_INSTALL_PROVIDER_KEY_NAME" "$_INSTALL_PROVIDER_KEY_VALUE"
        api_set_key "GEORGE_PROVIDER" "$_INSTALL_PROVIDER"
    else
        # Inline write: create keys.conf if missing, then upsert the keys
        if [ ! -f "$_IST_KEYS_FILE" ]; then
            touch "$_IST_KEYS_FILE"
            chmod 600 "$_IST_KEYS_FILE"
        fi
        # Remove existing lines, then append
        grep -v "^${_INSTALL_PROVIDER_KEY_NAME}=" "$_IST_KEYS_FILE" 2>/dev/null > "$_IST_KEYS_FILE.tmp" || true
        grep -v "^GEORGE_PROVIDER=" "$_IST_KEYS_FILE.tmp" 2>/dev/null > "$_IST_KEYS_FILE" || true
        rm -f "$_IST_KEYS_FILE.tmp"
        echo "${_INSTALL_PROVIDER_KEY_NAME}=${_INSTALL_PROVIDER_KEY_VALUE}" >> "$_IST_KEYS_FILE"
        echo "GEORGE_PROVIDER=${_INSTALL_PROVIDER}" >> "$_IST_KEYS_FILE"
        chmod 600 "$_IST_KEYS_FILE"
    fi
fi

# ── 3. Ensure Ollama is running ──────────────────────────────
if [ "$_OLLAMA_AVAILABLE" -eq 1 ]; then
    if ! curl -sf http://127.0.0.1:11434/api/tags &>/dev/null; then
        info "Starting Ollama..."
        local_tmpdir="${TMPDIR:-/tmp}"
        # Ensure Ollama can find models when started from proot-distro
        if [ "$IS_PROOT" -eq 1 ] && [ -d "/data/data/com.termux/files/home/.ollama/models" ]; then
            export OLLAMA_MODELS="/data/data/com.termux/files/home/.ollama/models"
        elif [ -d "/usr/share/ollama/.ollama/models" ]; then
            export OLLAMA_MODELS="/usr/share/ollama/.ollama/models"
        fi
        ollama serve > "$local_tmpdir/lodge-ollama.log" 2>&1 &
        sleep 3
        if ! curl -sf http://127.0.0.1:11434/api/tags &>/dev/null; then
            err "Ollama failed to start. Check $local_tmpdir/lodge-ollama.log"
            exit 1
        fi
    fi
    ok "Ollama running"
fi

# ── 3b. Check llama.cpp (llama-server) ───────────────────────
# llama.cpp is the preferred inference backend — faster startup, lower
# memory overhead, and native GGUF support. Ollama manages GGUF
# downloads and serves as the fallback backend.
# Skip on iSH — no native binaries can run.
if [ "$IS_ISH" -eq 1 ]; then
    _llama_server_found=0
else
info "Checking llama-server..."
_llama_server_found=0

# 1) Check LLAMA_CPP_SERVER_BIN if set explicitly
if [ -n "${LLAMA_CPP_SERVER_BIN:-}" ] && [ -x "$LLAMA_CPP_SERVER_BIN" ]; then
    _llama_server_found=1
    ok "llama-server found: $LLAMA_CPP_SERVER_BIN"
# 2) Check default build path (Termux / proot layout)
elif [ "$IS_TERMUX" -eq 1 ] || [ "$IS_PROOT" -eq 1 ]; then
    _termux_home="${HOME}"
    [ "$IS_PROOT" -eq 1 ] && _termux_home="/data/data/com.termux/files/home"
    _default_bin="${_termux_home}/llama.cpp/build/bin/llama-server"
    if [ -x "$_default_bin" ]; then
        _llama_server_found=1
        ok "llama-server found: $_default_bin"
    fi
    unset _termux_home _default_bin
# 3) Check PATH
elif command -v llama-server &>/dev/null; then
    _llama_server_found=1
    ok "llama-server found: $(command -v llama-server)"
fi

if [ "$_llama_server_found" -eq 0 ]; then
    warn "llama-server not found — Ollama will be used as the inference backend."
    info "To use llama.cpp (recommended), build it from source:"
    info "  git clone https://github.com/ggml-org/llama.cpp && cd llama.cpp"
    info "  cmake -B build && cmake --build build --config Release -j\$(nproc)"
    info "Then set LLAMA_CPP_SERVER_BIN in lodge.conf or your environment."
fi
fi  # end IS_ISH guard for llama-server

# Source model library for model creation
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/models.sh" 2>/dev/null || true

# ── 4. Create models ────────────────────────────────────────
# Check which model families are already created, then offer to
# download any that are missing. Pressing Enter with no input
# installs only the default Qwen family.
if [ "$_OLLAMA_AVAILABLE" -eq 0 ]; then
    warn "Skipping model setup — Ollama not available"
else
info "Checking model families..."

# Collect family status
_install_missing_families=()
_install_ready_families=()
_install_partial_families=()

for _fam_entry in "${_MODELS_FAMILIES[@]}"; do
    _fam_name="${_fam_entry%%|*}"
    IFS='|' read -r _ _fam_desc _fam_keys <<< "$_fam_entry"
    _fam_status=$(models_family_status "$_fam_name")
    case "$_fam_status" in
        all)
            _install_ready_families+=("$_fam_name")
            ok "$_fam_desc — ready" ;;
        some)
            _install_partial_families+=("$_fam_name")
            warn "$_fam_desc — incomplete" ;;
        none)
            _install_missing_families+=("$_fam_name") ;;
    esac
done

# If there are non-default families missing, offer to download them
# Ministral is handled separately below (required for George to start).
_extra_missing=()
for _fm in "${_install_missing_families[@]}"; do
    [ "$_fm" = "ministral" ] && continue
    _extra_missing+=("$_fm")
done
for _fm in "${_install_partial_families[@]}"; do
    [ "$_fm" = "ministral" ] && continue
    _extra_missing+=("$_fm")
done

if [ ${#_extra_missing[@]} -gt 0 ]; then
    echo ""
    printf " ${BOLD}Available model families (not yet installed):${RESET}\n"
    for _fm in "${_extra_missing[@]}"; do
        _fam_entry=$(_models_family_lookup "$_fm")
        IFS='|' read -r _ _desc _keys <<< "$_fam_entry"
        _model_count=$(echo "$_keys" | wc -w)
        printf "   ${BLUE}%-12s${RESET} %s (%d model%s)\n" "$_fm" "$_desc" "$_model_count" "$([ "$_model_count" -gt 1 ] && echo "s")"
    done
    echo ""
    printf " Would you like to download additional model families?\n"
    printf " ${DIM}Enter family names separated by spaces, or press Enter to skip.${RESET}\n"
    printf " ${DIM}Enter 'all' to download everything (~3GB per family).${RESET}\n"
    printf " ${YELLOW}→${RESET} "
    read -r _user_families

    if [ -n "$_user_families" ]; then
        if [ "$_user_families" = "all" ]; then
            _families_to_create=("${_extra_missing[@]}")
        else
            _families_to_create=()
            for _uf in $_user_families; do
                # Validate the name
                if _models_family_lookup "$_uf" &>/dev/null; then
                    _families_to_create+=("$_uf")
                else
                    warn "Unknown family '$_uf' — skipping (available: ${_extra_missing[*]})"
                fi
            done
        fi

        for _fam in "${_families_to_create[@]}"; do
            echo ""
            info "Downloading & creating $_fam family (this may take several minutes)..."
            if models_create_family "$_fam"; then
                ok "$_fam family ready"
            else
                warn "$_fam family had errors — some models may be missing"
            fi
        done
    fi
fi


# ── Default model: Ministral 3 Instruct ──────────────────────
# Ministral 3 Instruct is the default model for George. Both the primary
# and secondary model slots point to it out of the box. If it is already
# installed we skip ahead; otherwise we ask the user before downloading.
echo ""
_minist_installed=0
if ollama list 2>/dev/null | grep -q "$LODGE_MODEL_PRIMARY"; then
    ok "Default model '$LODGE_MODEL_PRIMARY' already installed"
    _minist_installed=1
fi

if [ "$LODGE_MODEL_PRIMARY" != "$LODGE_MODEL_SECONDARY" ] \
   && ollama list 2>/dev/null | grep -q "$LODGE_MODEL_SECONDARY"; then
    ok "Secondary model '$LODGE_MODEL_SECONDARY' already installed"
elif [ "$LODGE_MODEL_PRIMARY" = "$LODGE_MODEL_SECONDARY" ] && [ "$_minist_installed" -eq 1 ]; then
    true  # single-model mode, already reported above
fi

if [ "$_minist_installed" -eq 0 ]; then
    echo ""
    printf " ${BOLD}Ministral 3 Instruct${RESET} is configured as the default model for George.\n"
    printf " ${DIM}It is a small (~3 GB) general-purpose model that works well out of the box.${RESET}\n"
    printf " ${DIM}You can change the default later in lodge.conf.${RESET}\n"
    echo ""
    printf " Install the default model now? ${DIM}[Y/n]${RESET} "
    read -r _install_default

    if [ -z "$_install_default" ] || [[ "$_install_default" =~ ^[Yy] ]]; then
        if [ "$LODGE_MODEL_PRIMARY" = "$LODGE_MODEL_SECONDARY" ]; then
            info "Creating model: $LODGE_MODEL_PRIMARY (first run downloads ~3 GB)..."
            _mf=$(models_generate_modelfile "minist-inst")
            ollama create "$LODGE_MODEL_PRIMARY" -f "$_mf"
            ok "Default model created"
        else
            info "Creating primary model: $LODGE_MODEL_PRIMARY (first run downloads ~3 GB)..."
            _mf=$(models_generate_modelfile "minist-think")
            ollama create "$LODGE_MODEL_PRIMARY" -f "$_mf"
            ok "Primary model created"

            info "Creating secondary model: $LODGE_MODEL_SECONDARY..."
            _mf=$(models_generate_modelfile "minist-inst")
            ollama create "$LODGE_MODEL_SECONDARY" -f "$_mf"
            ok "Secondary model created"
        fi
        _minist_installed=1
    else
        warn "Skipped default model — George will not work until a model is configured"
    fi
fi

fi  # end _OLLAMA_AVAILABLE gate for steps 4 + default model

# ── 5. Verify Ollama API ─────────────────────────────────────
# Quick health check — confirm the Ollama server responds to API
# requests. We do NOT preload the model here; that would hold GPU/RAM
# for the keep_alive window and interfere with lodge's first run.
if [ "$_OLLAMA_AVAILABLE" -eq 0 ]; then
    info "Skipping API check — Ollama not available"
elif [ "${_minist_installed:-0}" -eq 0 ]; then
    warn "Skipping API check — no default model installed"
else
    info "Verifying Ollama API..."
    if curl -sf --connect-timeout 5 --max-time 10 \
        http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
        ok "Ollama API responding — model will load on first use"
    else
        warn "Ollama API not responding — George may need Ollama restarted"
    fi
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

# ── 10. Remove old qwen-lab setup ────────────────────────────
if [ -f "$HOME/qwen-lab.sh" ]; then
    info "Found old qwen-lab.sh"
    printf " Remove it? [y/N] "
    read -r remove_lab
    if [[ "${remove_lab,,}" == "y"* ]]; then
        rm -f "$HOME/qwen-lab.sh"
        # Remove old model
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
