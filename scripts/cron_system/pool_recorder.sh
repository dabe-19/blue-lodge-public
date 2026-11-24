#!/bin/bash
# ── Autonomic Cron Trigger: Minswap V2 pool-state recorder ──
# INTERVAL: 60
# ENABLED: 1
# SCOPE: system
# DESC: Exact pool reserves + per-order swap flow into .george/finance/market.db (Blockfrost budget-guarded, Koios overflow).
#
# Read-only. Per-pool cadence (60s fast / 300s slow pools) and budget degradation are handled
# inside pool_recorder.py; this wrapper just runs one pass, then the signal scan on fresh data.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
_PY_BIN="$LODGE_DIR/.venv/bin/python"
[ -f "$_PY_BIN" ] || _PY_BIN="python3"
export PYTHONPATH="$LODGE_DIR"
_LOG="${CRON_JOB_LOG:-$LODGE_DIR/.george/logs/cron/pool_recorder.log}"
mkdir -p "$(dirname "$_LOG")" 2>/dev/null || true

_OUT=$("$_PY_BIN" "$LODGE_DIR/lib/tools/quant/pool_recorder.py" tick 2>&1)
printf '[%s] %s\n' "$(date '+%F %T')" "$(printf '%s' "$_OUT" | jq -c '{status, provider, cadence_multiplier, pools: [.pools[]? | "\(.asset):\(.applied)"], errors: (.errors | length)}' 2>/dev/null || printf '%s' "$_OUT" | head -c 300)" >> "$_LOG"

if [ -f "$LODGE_DIR/lib/tools/quant/signals.py" ]; then
    _SIG=$("$_PY_BIN" "$LODGE_DIR/lib/tools/quant/signals.py" scan --emit 2>>"$_LOG" || true)
    if [ -n "$_SIG" ] && printf '%s' "$_SIG" | jq -e '((.new_signals // []) | length > 0) or ((.standing_triggers // []) | length > 0)' >/dev/null 2>&1; then
        printf '[%s] [SIGNALS] %s\n' "$(date '+%F %T')" "$(printf '%s' "$_SIG" | jq -c '{new_signals, standing_triggers}')" >> "$_LOG"
    fi
fi

tail -n 500 "$_LOG" > "${_LOG}.tmp" 2>/dev/null && mv "${_LOG}.tmp" "$_LOG"
