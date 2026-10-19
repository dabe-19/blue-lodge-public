#!/bin/bash
# ── George: Sovereign Cardano Stop & OCO Bracket Reactor ─────────────────────
# Reactive event handler for 'cardano/price_tick' events on the POSIX FIFO Event Bus.
# Validates payload, checks break thresholds, evaluates macro gates, and triggers executions.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
FINANCE_DIR="${FINANCE_DIR:-$GEORGE_DIR/finance}"
STOP_REACTOR_LOG="$FINANCE_DIR/stop_reactor.log"

stop_reactor_event_ingress() {
    local evt_type="${1:-}"
    local evt_payload="${2:-}"
    [ -z "$evt_payload" ] && return 0
    mkdir -p "$FINANCE_DIR" 2>/dev/null || true

    local py_bin="$LODGE_DIR/.venv/bin/python"
    [ ! -x "$py_bin" ] && py_bin="python3"

    local ts res
    ts=$(date -u +%FT%TZ)
    # Payload is passed as a single argv element (never evaluated by shell).
    res=$(cd "$LODGE_DIR" && "$py_bin" "$LODGE_DIR/lib/tools/cardano_stop_reactor.py" "$evt_payload" 2>>"$STOP_REACTOR_LOG" \
          || echo '{"status":"error","reason":"stop reactor crashed"}')
    printf '[%s] [%s] %s\n' "$ts" "$evt_type" "$res" >> "$STOP_REACTOR_LOG"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    target_pay="${2:-}"
    [ -z "$target_pay" ] && target_pay="{}"
    stop_reactor_event_ingress "${1:-cardano/price_tick}" "$target_pay"
fi
