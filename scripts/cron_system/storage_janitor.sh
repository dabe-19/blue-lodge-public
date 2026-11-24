#!/bin/bash
# ── Storage Retention Janitor (runs/, transcripts/, workspaces/, discord_sessions/) ──
# INTERVAL: 86400
# ENABLED: 1
# DESC: Storage Retention Janitor (runs/, transcripts/, workspaces/, discord_sessions/)
# SCOPE: system

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"
LOG_FILE="${CRON_JOB_LOG:-$GEORGE_DIR/logs/cron/storage_janitor.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

source "$LODGE_DIR/lib/sys/janitor.sh" || exit 1
echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $(janitor_run 30 7)" >> "$LOG_FILE" 2>&1

tail -n 100 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE"
