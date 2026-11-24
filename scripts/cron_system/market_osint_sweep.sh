#!/bin/bash
# ── Sovereign OSINT Market & Hardware Deal Sweep ──
# INTERVAL: 900
# ENABLED: 1
# DESC: Sovereign OSINT market & hardware deal watcher sweep
# SCOPE: system

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
LOG_FILE="${CRON_JOB_LOG:-$LODGE_DIR/.george/logs/cron/market_osint_sweep.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Running autonomous OSINT web watcher sweep..." >>"$LOG_FILE" 2>&1
# Use venv python (has PyYAML); system python3 may lack it (incident 2026-11-02: recurring PyYAML failures)
SWEEP_PY="$LODGE_DIR/.venv/bin/python"
[ -x "$SWEEP_PY" ] || SWEEP_PY="python3"
"$SWEEP_PY" "$LODGE_DIR/lib/tools/osint_watcher.py" --sweep >>"$LOG_FILE" 2>&1

# Keep the log bounded (retain last 100 lines)
tail -n 100 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE"
