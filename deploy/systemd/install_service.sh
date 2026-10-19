#!/bin/bash
# ── Install George Reactive Event Bus systemd User Service ───────────────────
set -euo pipefail

SERVICE_NAME="george-event-router.service"
SRC_FILE="$(dirname "$0")/$SERVICE_NAME"
TARGET_DIR="$HOME/.config/systemd/user"

mkdir -p "$TARGET_DIR"
cp -f "$SRC_FILE" "$TARGET_DIR/$SERVICE_NAME"
echo "[OK] Installed $SERVICE_NAME to $TARGET_DIR/"

if command -v systemctl &>/dev/null; then
    systemctl --user daemon-reload || true
    echo "[OK] Reloaded systemd user daemon."
    echo ""
    echo "To enable and start the service:"
    echo "  systemctl --user enable $SERVICE_NAME"
    echo "  systemctl --user start $SERVICE_NAME"
    echo "  systemctl --user status $SERVICE_NAME"
    echo ""
    echo "To keep the service running after logout (lingering):"
    echo "  loginctl enable-linger $USER 2>/dev/null || true"
else
    echo "[WARN] systemctl not found in current environment."
fi
