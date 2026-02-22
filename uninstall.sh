#!/bin/bash
# Blue Lodge — Uninstaller
set -euo pipefail

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

# Remove sandboxes (ask first)
if [ -d "$HOME/.lodge-sandboxes" ]; then
    printf " Remove all sandboxes (~/.lodge-sandboxes)? [y/N] "
    read -r ans
    if [[ "${ans,,}" == "y"* ]]; then
        rm -rf "$HOME/.lodge-sandboxes"
        echo " ✓ Removed sandboxes"
    fi
fi

# Remove history
rm -f "$HOME/.lodge_history"

echo ""
echo " ✓ Blue Lodge uninstalled."
echo " Note: ~/blue-lodge/ directory kept. Delete manually if desired:"
echo "   rm -rf ~/blue-lodge"
echo ""
