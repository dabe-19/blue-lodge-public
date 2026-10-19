#!/bin/bash
# ── George: Sovereign Cardano Maker Sell Reactor (Path D) ───────────────────
# Reactive event handler for 'cardano/maker_filled' events on the POSIX FIFO Event Bus.
# Thin shell adapter: all logic lives in lib/tools/maker_sell_reactor.py, which
#   1. validates the payload (no bus data is ever interpolated into code),
#   2. atomically claims the filled cycle (idempotent: one listing per fill),
#   3. prices the ask from on-chain ADA spot with a break-even floor and reports the
#      model fill probability,
#   4. places a native MinswapV2 resting sell (policy-gated, actor=george) and records
#      PENDING_SELL with the real tx id, then emits 'cardano/maker_sell_placed'.
# Live execution: OFF by default (priced/simulated only). Operators opt in with
# GEORGE_EXECUTE_LIVE_SELL=1 in the env or .george/features.conf; is_simulated events never go live.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
FINANCE_DIR="${FINANCE_DIR:-$GEORGE_DIR/finance}"
MAKER_SELL_LOG="$FINANCE_DIR/maker_sell_reactor.log"

maker_sell_event_ingress() {
    local evt_type="${1:-}"
    local evt_payload="${2:-}"
    [ -z "$evt_payload" ] && return 0
    mkdir -p "$FINANCE_DIR" 2>/dev/null || true

    local py_bin="$LODGE_DIR/.venv/bin/python"
    [ ! -x "$py_bin" ] && py_bin="python3"

    local ts res
    ts=$(date -u +%FT%TZ)
    # Payload is passed as a single argv element (never evaluated by the shell or Python).
    res=$(cd "$LODGE_DIR" && "$py_bin" "$LODGE_DIR/lib/tools/maker_sell_reactor.py" "$evt_payload" 2>>"$MAKER_SELL_LOG" \
          || echo '{"status":"error","reason":"reactor crashed"}')
    printf '[%s] [%s] %s\n' "$ts" "$evt_type" "$res" >> "$MAKER_SELL_LOG"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    target_pay="${2:-}"
    [ -z "$target_pay" ] && target_pay="{}"
    maker_sell_event_ingress "${1:-cardano/maker_filled}" "$target_pay"
fi
