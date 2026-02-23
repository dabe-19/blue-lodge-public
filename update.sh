#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# George (Blue Lodge) — Update Script
# ═══════════════════════════════════════════════════════════════
# Safely updates George while preserving identity and memory.
#
# Usage:
#   bash ~/blue-lodge/update.sh           # Normal update (pull + rebuild)
#   bash ~/blue-lodge/update.sh --clean   # Fresh clone (backs up first)
set -euo pipefail

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
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
printf " ${BOLD}⌂ George Update${RESET}\n"
echo ""

CLEAN_MODE=0
if [ "${1:-}" = "--clean" ]; then
    CLEAN_MODE=1
    warn "Clean mode: will remove and re-clone the repo"
fi

# ── Step 1: Backup identity ──────────────────────────────────
info "Step 1: Backing up George's identity..."

GEORGE_CONFIG_DIR="${GEORGE_CONFIG_DIR:-$HOME/.george}"
BACKUP_DIR="$GEORGE_CONFIG_DIR/backups"
BACKUP_REPO="$GEORGE_CONFIG_DIR/backup-repo"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="$BACKUP_DIR/$TIMESTAMP"
mkdir -p "$BACKUP_PATH"

# Core identity files
for f in soul.md journal.md Modelfile; do
    if [ -f "$LODGE_DIR/$f" ]; then
        cp "$LODGE_DIR/$f" "$BACKUP_PATH/$f"
    fi
done

# API keys
if [ -f "$GEORGE_CONFIG_DIR/keys.conf" ]; then
    cp "$GEORGE_CONFIG_DIR/keys.conf" "$BACKUP_PATH/keys.conf"
fi

# CLAUDE.md from current dir
[ -f "$PWD/CLAUDE.md" ] && cp "$PWD/CLAUDE.md" "$BACKUP_PATH/CLAUDE.md"

ok "Identity backed up to $BACKUP_PATH"

# Also save to git backup if available
if [ -d "$BACKUP_REPO/.git" ]; then
    info "Saving to git backup repo..."
    for f in soul.md journal.md Modelfile; do
        [ -f "$LODGE_DIR/$f" ] && cp "$LODGE_DIR/$f" "$BACKUP_REPO/$f"
    done
    [ -f "$GEORGE_CONFIG_DIR/keys.conf" ] && cp "$GEORGE_CONFIG_DIR/keys.conf" "$BACKUP_REPO/keys.conf"
    cd "$BACKUP_REPO"
    git add -A && git commit -q -m "Pre-update backup $TIMESTAMP" 2>/dev/null || true
    cd - > /dev/null
    ok "Git backup saved"
fi

# ── Step 2: Update code ──────────────────────────────────────
if [ "$CLEAN_MODE" -eq 1 ]; then
    info "Step 2: Clean re-clone..."

    # Get the remote URL before removing
    REMOTE_URL=""
    if [ -d "$LODGE_DIR/.git" ]; then
        REMOTE_URL=$(git -C "$LODGE_DIR" remote get-url origin 2>/dev/null || echo "")
    fi

    if [ -z "$REMOTE_URL" ]; then
        REMOTE_URL="https://github.com/dabe-19/blue-lodge.git"
        warn "No git remote found. Using default: $REMOTE_URL"
    fi

    # Remove old installation
    rm -rf "$LODGE_DIR"

    # Clone fresh
    info "Cloning from $REMOTE_URL..."
    git clone "$REMOTE_URL" "$LODGE_DIR"
    ok "Fresh clone complete"

else
    info "Step 2: Pulling latest changes..."
    cd "$LODGE_DIR"

    # Stash any local changes
    if ! git diff --quiet 2>/dev/null; then
        warn "Local changes detected — stashing"
        git stash push -m "pre-update-$TIMESTAMP"
    fi

    # Pull
    git pull origin main 2>/dev/null || git pull origin master 2>/dev/null || {
        err "Git pull failed. Try: bash ~/blue-lodge/update.sh --clean"
        exit 1
    }

    ok "Code updated"
    cd - > /dev/null
fi

# ── Step 3: Restore identity ─────────────────────────────────
info "Step 3: Restoring George's identity..."

for f in soul.md journal.md Modelfile; do
    if [ -f "$BACKUP_PATH/$f" ] && [ ! -f "$LODGE_DIR/$f" -o "$CLEAN_MODE" -eq 1 ]; then
        cp "$BACKUP_PATH/$f" "$LODGE_DIR/$f"
        ok "  Restored: $f"
    elif [ -f "$BACKUP_PATH/$f" ]; then
        # File exists in both — keep backup version for identity files
        if [ "$f" = "soul.md" ] || [ "$f" = "journal.md" ]; then
            cp "$BACKUP_PATH/$f" "$LODGE_DIR/$f"
            ok "  Restored (preserved identity): $f"
        fi
    fi
done

# Restore keys
if [ -f "$BACKUP_PATH/keys.conf" ]; then
    mkdir -p "$GEORGE_CONFIG_DIR"
    cp "$BACKUP_PATH/keys.conf" "$GEORGE_CONFIG_DIR/keys.conf"
    chmod 600 "$GEORGE_CONFIG_DIR/keys.conf"
    ok "  Restored: keys.conf"
fi

# ── Step 4: Rebuild Ollama model ──────────────────────────────
info "Step 4: Rebuilding Ollama model..."

if command -v ollama &>/dev/null; then
    # Check if Ollama is running
    if curl -sf --max-time 3 http://127.0.0.1:11434/api/tags &>/dev/null; then
        ollama create blue-lodge -f "$LODGE_DIR/Modelfile" 2>&1
        ok "Model rebuilt"
    else
        warn "Ollama not running. Rebuild manually:"
        echo "    ollama serve &"
        echo "    ollama create blue-lodge -f ~/blue-lodge/Modelfile"
    fi
else
    warn "Ollama not found. Install it first, then:"
    echo "    ollama create blue-lodge -f ~/blue-lodge/Modelfile"
fi

# ── Step 5: Verify ──────────────────────────────────────────
info "Step 5: Verifying installation..."

ERRORS=0
for f in lodge lib/ui.sh lib/llm.sh lib/agent.sh lib/tools.sh lib/memory.sh lib/commands.sh lib/sandbox.sh lib/container.sh lib/api.sh lib/social.sh lib/providers.sh lib/web.sh lib/backup.sh lib/journal.sh; do
    if [ ! -f "$LODGE_DIR/$f" ]; then
        err "Missing: $f"
        ERRORS=$((ERRORS + 1))
    fi
done

# Syntax check key files
for f in lodge lib/*.sh; do
    if [ -f "$LODGE_DIR/$f" ]; then
        if ! bash -n "$LODGE_DIR/$f" 2>/dev/null; then
            err "Syntax error in: $f"
            ERRORS=$((ERRORS + 1))
        fi
    fi
done

if [ "$ERRORS" -eq 0 ]; then
    ok "All files present and valid"
else
    err "$ERRORS issue(s) found"
fi

# ── Step 6: Reindex knowledge base ───────────────────────────
info "Step 6: Reindexing knowledge base..."

if command -v sqlite3 &>/dev/null; then
    export LODGE_DIR
    export GEORGE_DIR="${GEORGE_DIR:-$HOME/.george}"
    mkdir -p "$GEORGE_DIR"
    source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
    source "$LODGE_DIR/lib/recall.sh" 2>/dev/null
    if recall_available 2>/dev/null; then
        recall_reindex 2>/dev/null
        local_chunks=$(sqlite3 "$GEORGE_DIR/recall.db" "SELECT COUNT(*) FROM chunks;" 2>/dev/null || echo "0")
        ok "Knowledge base reindexed ($local_chunks chunks)"
    else
        warn "sqlite3 FTS5 not available — skipping reindex"
    fi
else
    warn "sqlite3 not found — knowledge base not reindexed"
    warn "George will auto-index on first run if sqlite3 is installed"
fi

# ── Done ──────────────────────────────────────────────────────
echo ""
ok "George updated successfully!"
echo ""
info "Backup preserved at: $BACKUP_PATH"
info "To start: lodge"
echo ""

if [ "$CLEAN_MODE" -eq 1 ]; then
    printf " ${DIM}You may need to: source ~/.bashrc${RESET}\n"
    echo ""
fi
