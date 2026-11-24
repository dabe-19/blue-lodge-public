#!/bin/bash
# ── Autonomic Cron Trigger: Cardano Multi-Headed Pair Ticker ──
# INTERVAL: 60
# ENABLED: 1
# DESC: Cardano multi-headed DEX pair ticker & spread poller
# SCOPE: system

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
_PY_BIN="$LODGE_DIR/.venv/bin/python"
[ -f "$_PY_BIN" ] || _PY_BIN="python3"

"$_PY_BIN" "$LODGE_DIR/lib/tools/cardano_pair_ticker.py" --poll >/dev/null 2>&1 || true
