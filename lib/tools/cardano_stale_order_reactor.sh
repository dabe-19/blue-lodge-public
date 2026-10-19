#!/bin/bash
# ── George: Sovereign Cardano Stale Order & Pool Trap Reactor ──────────────────
# Reactive event handler for 'cardano/order_stale' and 'dex/stale_pool_detected'
# on the POSIX FIFO Event Bus.
# Executes the Fiduciary Defense loop:
#   1. Inspects the affected resting order or pool trap alert.
#   2. Invokes the Plutus emergency cancellation engine (cardano_order_canceller.py).
#   3. Reclaims locked tokens and refundable ADA deposits back to sovereign hot wallet.
#   4. Emits 'cardano/order_cancelled' onto the FIFO Event Bus.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
FINANCE_DIR="${FINANCE_DIR:-$GEORGE_DIR/finance}"
STALE_REACTOR_LOG="$FINANCE_DIR/stale_reactor.log"

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/event_bus.sh" 2>/dev/null || true

stale_order_event_ingress() {
    local evt_type="${1:-}"
    local evt_payload="${2:-}"

    [ -z "$evt_payload" ] && return 0
    mkdir -p "$FINANCE_DIR" 2>/dev/null || true

    local ts
    ts=$(date -u +%FT%TZ)

    local order_id tx_id asset reason
    order_id=$(echo "$evt_payload" | jq -r '.order_id // empty' 2>/dev/null || echo "")
    tx_id=$(echo "$evt_payload" | jq -r '.tx_id // .tx_hash // empty' 2>/dev/null || echo "")
    asset=$(echo "$evt_payload" | jq -r '.asset // empty' 2>/dev/null || echo "")
    reason=$(echo "$evt_payload" | jq -r '.reason // "Stale batcher pool inactivity"' 2>/dev/null || echo "Stale batcher pool inactivity")

    echo "[$ts] [STALE_EVENT_INGRESS] Received $evt_type | Order: $order_id | Tx: $tx_id | Asset: $asset | Reason: $reason" >> "$STALE_REACTOR_LOG"

    local py_bin="$LODGE_DIR/.venv/bin/python"
    [ ! -x "$py_bin" ] && py_bin="python3"

    # 1. Execute Emergency Reclaim via cardano_order_canceller.py
    local cancel_args=()
    [ -n "$order_id" ] && cancel_args+=(--order-id "$order_id")
    [ -n "$tx_id" ] && cancel_args+=(--tx-in "$tx_id")

    # If live cancel execution enabled in environment (default dry-run for safety unless explicitly live)
    if [ "${GEORGE_AUTO_CANCEL_STALE:-0}" = "1" ]; then
        cancel_args+=(--execute)
    else
        cancel_args+=(--dry-run)
    fi
    cancel_args+=(--json)

    echo "[$ts] [EXECUTING_RECLAIM] Triggering emergency Plutus reclaimer..." >> "$STALE_REACTOR_LOG"
    local cancel_res
    cancel_res=$("$py_bin" "$LODGE_DIR/lib/tools/cardano_order_canceller.py" "${cancel_args[@]}" 2>> "$STALE_REACTOR_LOG" || echo '{"status":"failed"}')

    echo "[$ts] [RECLAIM_RESULT] $cancel_res" >> "$STALE_REACTOR_LOG"

    # 2. 'cardano/order_cancelled' is emitted by lib/tools/cardano_orders.py only after the
    #    reclaim is confirmed on-chain and the wallet delta is verified. Dry runs and
    #    failures must not emit it (downstream reactors would relist inventory we do not hold).
    if [ "$(echo "$cancel_res" | jq -r '.dry_run // true' 2>/dev/null)" = "true" ]; then
        echo "[$ts] [RECLAIM_DRY_RUN] Set GEORGE_AUTO_CANCEL_STALE=1 to broadcast." >> "$STALE_REACTOR_LOG"
    fi

    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    target_evt="${1:-cardano/order_stale}"
    target_pay="${2:-}"
    [ -z "$target_pay" ] && target_pay="{}"
    stale_order_event_ingress "$target_evt" "$target_pay"
fi
