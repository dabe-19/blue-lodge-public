#!/bin/bash
# ── George: Visual Autonomic Sweep Runner ──────────────────────────
# Invoked by Windows Terminal (wt.exe) or terminal popups to display
# real-time telemetry and autonomic sweep progress without semicolon
# parsing issues in Windows Terminal CLI.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
sweep_type="${1:-all}"
hold="${2:-1}"

source "$LODGE_DIR/lib/cron.sh" 2>/dev/null || true

cron_run_visual_sweep "$sweep_type"
ec=$?

if [ "$ec" -eq 0 ]; then
    sleep 2.5
else
    if [ "$hold" -eq 1 ]; then
        echo ""
        read -r -p "[Press Enter to dismiss] " _dummy
    fi
fi

exit "$ec"
