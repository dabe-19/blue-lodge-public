#!/bin/bash
# ── Autonomic Cron Trigger: pool history backfill ──
# INTERVAL: 1800
# ENABLED: 1
# SCOPE: system
# DESC: Chunked ~30-day Minswap V2 pool history backfill into market.db. Stays inside recorder.backfill_daily_budget and yields to live recording when the Blockfrost budget is tight. Self-completes (no-op once every pool is done).

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
_PY_BIN="$LODGE_DIR/.venv/bin/python"
[ -f "$_PY_BIN" ] || _PY_BIN="python3"
export PYTHONPATH="$LODGE_DIR"
_LOG="${CRON_JOB_LOG:-$LODGE_DIR/.george/logs/cron/pool_backfill.log}"
mkdir -p "$(dirname "$_LOG")" 2>/dev/null || true

_OUT=$("$_PY_BIN" "$LODGE_DIR/lib/tools/quant/pool_recorder.py" backfill 2>&1)
printf '[%s] %s\n' "$(date '+%F %T')" "$(printf '%s' "$_OUT" | jq -c '{status, calls_left, pools}' 2>/dev/null || printf '%s' "$_OUT" | head -c 300)" >> "$_LOG"
tail -n 300 "$_LOG" > "${_LOG}.tmp" 2>/dev/null && mv "${_LOG}.tmp" "$_LOG"
