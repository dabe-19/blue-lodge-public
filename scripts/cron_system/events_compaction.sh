#!/bin/bash
# ── Sovereign Event Store Rolling 90-Day Retention & Compaction ──
# INTERVAL: 43200
# ENABLED: 1
# DESC: Sovereign Event Store rolling 90-day retention & compaction
# SCOPE: system

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOG_FILE="${CRON_JOB_LOG:-$LODGE_DIR/.george/logs/cron/events_compaction.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Running rolling event store 90-day retention prune..." >>"$LOG_FILE" 2>&1
python3 "$LODGE_DIR/lib/tools/event_store.py" --prune --retention-days 90 >>"$LOG_FILE" 2>&1

echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Running SQLite VACUUM database compaction..." >>"$LOG_FILE" 2>&1
python3 "$LODGE_DIR/lib/tools/event_store.py" --compact >>"$LOG_FILE" 2>&1

# Keep the log bounded (retain last 100 lines)
tail -n 100 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE"
