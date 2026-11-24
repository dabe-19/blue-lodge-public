#!/usr/bin/env bash
# ── Autonomic Cron Trigger: The Tyler Multi-Room RF Mesh & 15s Sampler Watchdog ──
# INTERVAL: 60
# ENABLED: 1
# SCOPE: system
# DESC: Ensures the resident 15-second in-process RF sampler (canary-daemon) is active, performs 4-Stage Hampel/EWMA/Z-Score/CUSUM RF conditioning across all 10 household corridors, and runs 2-tier SQLite compaction (72h raw 15s -> 90d 5m rollups).

set -euo pipefail

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
PY_BIN="$LODGE_DIR/.venv/bin/python"
[ -x "$PY_BIN" ] || PY_BIN="python3"
export PYTHONPATH="$LODGE_DIR"

LOG_FILE="${CRON_JOB_LOG:-$LODGE_DIR/.george/logs/cron/tyler_rf_mesh_sweep.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# 1. Ensure resident canary-daemon (which runs the zero-fork 15s _rf_15s_sampler_loop) is running
"$PY_BIN" "$LODGE_DIR/lib/tools/tyler_guardian.py" canary --action start >/dev/null 2>&1 || true

# 2. Check age of latest sample in rf_telemetry_timeseries; run catch-up sample if >25s stale
LAST_AGE=$("$PY_BIN" -c '
import sqlite3, time
conn = sqlite3.connect("'"$LODGE_DIR"'/.george/state/lan_devices.db")
r = conn.execute("SELECT MAX(ts) FROM rf_telemetry_timeseries").fetchone()
print(int(time.time() - (r[0] or 0)))
' 2>/dev/null || echo 999)

if [ "${LAST_AGE:-999}" -gt 25 ]; then
    OUT=$("$PY_BIN" "$LODGE_DIR/lib/tools/tyler_guardian.py" wifi-spelunk --mode rf_motion_sense --timeout 2 2>&1 || true)
    SUMMARY=$(printf '%s' "$OUT" | jq -c '{status, ts, mode: "catchup_15s", total_chords_monitored, active_motion_corridors_count, active_zones: [.active_motion_corridors[]?.zone]}' 2>/dev/null || printf '%s' "$OUT" | head -c 260)
else
    SUMMARY=$(printf '{"status":"ok","mode":"daemon_15s_active","last_sample_age_s":%s}' "$LAST_AGE")
fi

# 3. Run lightweight 2-tier RRD compaction (72h raw 15s -> 90d 5m rollups)
"$PY_BIN" "$LODGE_DIR/lib/tools/tyler_guardian.py" prune >/dev/null 2>&1 || true

printf '[%s] %s\n' "$(date '+%F %T')" "$SUMMARY" >> "$LOG_FILE"
tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE"
