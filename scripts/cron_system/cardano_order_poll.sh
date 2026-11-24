#!/bin/bash
# ── Autonomic Cron Trigger: Cardano Unified Engine Daemon (UCOM) ──
# INTERVAL: 60
# ENABLED: 1
# DESC: Cardano Unified Engine Daemon (UCOM) on-chain order poller
# SCOPE: system

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
_PY_BIN="$LODGE_DIR/.venv/bin/python"
[ -f "$_PY_BIN" ] || _PY_BIN="python3"

"$_PY_BIN" "$LODGE_DIR/lib/tools/cardano_engine_daemon.py" --once >/dev/null 2>&1 || true
