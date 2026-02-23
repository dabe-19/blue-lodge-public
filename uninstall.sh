#!/bin/bash
# Blue Lodge — Uninstaller
set -euo pipefail

# Detect install dir from this script's location
_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LODGE_DIR="${LODGE_DIR:-$_SCRIPT_DIR}"

echo ""
echo " ⌂ Uninstalling Blue Lodge..."
echo ""

# Remove symlink
rm -f "$HOME/.local/bin/lodge"

# Remove model
if command -v ollama &>/dev/null; then
    ollama rm blue-lodge 2>/dev/null || true
    echo " ✓ Removed Ollama model"
fi

# Clean shell config
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    if [ -f "$rc" ]; then
        sed -i '/# ── Blue Lodge/,/alias lghelp/d' "$rc" 2>/dev/null
        echo " ✓ Cleaned $rc"
    fi
done

# Remove George's config (lives inside install dir)
if [ -d "$LODGE_DIR/.george" ]; then
    printf " Remove George's data ($LODGE_DIR/.george)? [y/N] "
    read -r ans
    if [[ "${ans,,}" == "y"* ]]; then
        rm -rf "$LODGE_DIR/.george"
        echo " ✓ Removed George's config"
    fi
fi

# Remove sandboxes (lives inside install dir)
if [ -d "$LODGE_DIR/.sandboxes" ]; then
    printf " Remove all sandboxes ($LODGE_DIR/.sandboxes)? [y/N] "
    read -r ans
    if [[ "${ans,,}" == "y"* ]]; then
        rm -rf "$LODGE_DIR/.sandboxes"
        echo " ✓ Removed sandboxes"
    fi
fi

# Remove history (lives inside install dir)
rm -f "$LODGE_DIR/.lodge_history"

# Clean any git config entries George may have set
git config --global --unset core.sshCommand 2>/dev/null || true
git config --global --unset user.signingkey 2>/dev/null || true
git config --global --unset commit.gpgsign 2>/dev/null || true
git config --global --unset tag.gpgsign 2>/dev/null || true
git config --global --unset gpg.program 2>/dev/null || true

echo ""
echo " ✓ Blue Lodge uninstalled."
echo " Note: $LODGE_DIR/ source kept. Delete manually if desired:"
echo "   rm -rf $LODGE_DIR"
echo ""
