#!/bin/bash
# ── Autonomic Cron Trigger: market.db janitor ──
# INTERVAL: 86400
# ENABLED: 1
# SCOPE: system
# DESC: Downsample raw pool/CEX data older than 1 day to 5-min bars, enforce 30d raw / 1y bar retention and the 2 GB hard cap, VACUUM.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
_PY_BIN="$LODGE_DIR/.venv/bin/python"
[ -f "$_PY_BIN" ] || _PY_BIN="python3"
export PYTHONPATH="$LODGE_DIR"
_LOG="${CRON_JOB_LOG:-$LODGE_DIR/.george/logs/cron/market_janitor.log}"
mkdir -p "$(dirname "$_LOG")" 2>/dev/null || true

_OUT=$("$_PY_BIN" "$LODGE_DIR/lib/tools/quant/market_db.py" janitor 2>&1)
printf '[%s] %s\n' "$(date '+%F %T')" "$(printf '%s' "$_OUT" | jq -c . 2>/dev/null || printf '%s' "$_OUT" | head -c 300)" >> "$_LOG"
tail -n 200 "$_LOG" > "${_LOG}.tmp" 2>/dev/null && mv "${_LOG}.tmp" "$_LOG"
