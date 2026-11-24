#!/bin/bash
# ── George: Sovereign Trade Event Trigger & Flow Controller ──────────────────
# Automated event-bus trigger and reactor coordinator for sovereign crypto trading.
# Integrates with FIFO flow control (.george/ipc/event_bus.fifo) and SQLite event store.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
FINANCE_DIR="${FINANCE_DIR:-$GEORGE_DIR/finance}"
EVENT_STORE_DB="${EVENT_STORE_DB:-$GEORGE_DIR/events.db}"

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/event_bus.sh" 2>/dev/null || true

trade_trigger_help() {
    echo "Usage: trade_event_trigger.sh <command> [args]"
    echo "Commands:"
    echo "  stale-scan          — Run liquidity squeeze audit and emit cardano/order_stale for stranded orders"
    echo "  emit-fill <order_id> <asset> <tokens> <cost_ada> — Manually trigger maker_filled reactor"
    echo "  emit-stale <order_id> [reason] — Manually trigger emergency stale cancel reactor"
    echo "  status              — Show live registered trading reactors and event queue status"
}

trade_trigger_stale_scan() {
    declare -f ui_info &>/dev/null && ui_info "Running DEX liquidity squeeze audit against active resting orders..."
    local py_bin="$LODGE_DIR/.venv/bin/python"
    [ ! -x "$py_bin" ] && py_bin="python3"

    # Query active resting orders
    local active_orders
    active_orders=$("$py_bin" -c "
import sqlite3, json
try:
    conn = sqlite3.connect('$FINANCE_DIR/maker_orders.db')
    conn.row_factory = sqlite3.Row
    rows = conn.execute(\"SELECT * FROM maker_orders WHERE status IN ('PENDING_BUY', 'PENDING_SELL')\").fetchall()
    print(json.dumps([dict(r) for r in rows]))
except Exception:
    print('[]')
")

    local count
    count=$(echo "$active_orders" | jq '. | length' 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then
        declare -f ui_dim &>/dev/null && ui_dim "No active resting limit orders currently in DB."
        return 0
    fi

    echo "Auditing $count active resting orders for pool staleness..."
    local idx=0
    while [ "$idx" -lt "$count" ]; do
        local order asset oid txid
        order=$(echo "$active_orders" | jq ".[$idx]")
        oid=$(echo "$order" | jq -r '.order_id')
        asset=$(echo "$order" | jq -r '.asset')
        txid=$(echo "$order" | jq -r '.tx_id // .sell_tx_id')

        # Run pool liquidity audit
        local audit_json
        audit_json=$("$py_bin" "$LODGE_DIR/lib/tools/dex_liquidity_squeeze_detector.py" --pair "${asset}/ADA" --json 2>/dev/null || echo '{"is_stale_trap":false}')
        local is_stale
        is_stale=$(echo "$audit_json" | jq -r '.is_stale_trap // false')

        if [ "$is_stale" = "true" ]; then
            declare -f ui_warn &>/dev/null && ui_warn "Stale pool detected for resting order $oid ($asset)! Emitting cardano/order_stale..."
            local payload
            payload=$(echo "$order" | jq -c '. + {"reason": "Automated staleness threshold breached"}')
            if declare -f event_bus_emit &>/dev/null; then
                event_bus_emit "cardano/order_stale" "$payload" "trade_event_trigger"
            fi
        else
            declare -f ui_ok &>/dev/null && ui_ok "Order $oid ($asset) pool is healthy and active."
        fi
        idx=$((idx + 1))
    done
}

trade_trigger_emit_fill() {
    local oid="${1:-}"
    local asset="${2:-}"
    local tokens="${3:-0}"
    local cost="${4:-0}"

    if [ -z "$oid" ] || [ -z "$asset" ]; then
        echo "Error: order_id and asset required"
        return 1
    fi

    local payload
    payload=$(jq -nc \
        --arg oid "$oid" \
        --arg asset "$asset" \
        --arg tokens "$tokens" \
        --arg cost "$cost" \
        '{order_id: $oid, asset: $asset, tokens_filled: ($tokens|tonumber), net_cost_basis_ada: ($cost|tonumber), is_simulated: false}')

    declare -f ui_info &>/dev/null && ui_info "Emitting cardano/maker_filled to event bus..."
    if declare -f event_bus_emit &>/dev/null; then
        event_bus_emit "cardano/maker_filled" "$payload" "trade_event_trigger"
    fi
}

trade_trigger_emit_stale() {
    local oid="${1:-}"
    local reason="${2:-Manual operator stale order trigger}"

    if [ -z "$oid" ]; then
        echo "Error: order_id required"
        return 1
    fi

    local payload
    payload=$(jq -nc --arg oid "$oid" --arg reason "$reason" '{order_id: $oid, reason: $reason}')

    declare -f ui_info &>/dev/null && ui_info "Emitting cardano/order_stale for $oid..."
    if declare -f event_bus_emit &>/dev/null; then
        event_bus_emit "cardano/order_stale" "$payload" "trade_event_trigger"
    fi
}

trade_trigger_status() {
    echo "================================================================================"
    echo "           SOVEREIGN TRADING EVENT BUS REACTORS & IPC FLOW CONTROL"
    echo "================================================================================"
    if [ -f "$GEORGE_DIR/reactors.json" ]; then
        echo "Registered Trading & Financial Reactors:"
        jq -r '.reactors[] | select(.id | test("trade|maker|stale|coinbase|poly|sovereign")) | "  [" + .id + "] -> Event: " + .event_type + " (Debounce: " + (.debounce_secs|tostring) + "s, Overflow: " + (.overflow // "drop") + ")"' "$GEORGE_DIR/reactors.json"
    fi
    echo "--------------------------------------------------------------------------------"
    if [ -f "$EVENT_STORE_DB" ] && command -v sqlite3 &>/dev/null; then
        echo "Recent Financial & Trading Events in Event Store:"
        sqlite3 "$EVENT_STORE_DB" "SELECT id, event_type, source, datetime(created_at, 'unixepoch') FROM events WHERE event_type LIKE '%cardano%' OR event_type LIKE '%trade%' OR event_type LIKE '%poly%' ORDER BY created_at DESC LIMIT 6;" 2>/dev/null || echo "No events found"
    fi
    echo "================================================================================"
}

cmd="${1:-status}"
shift || true

case "$cmd" in
    stale-scan|scan)
        trade_trigger_stale_scan
        ;;
    emit-fill|fill)
        trade_trigger_emit_fill "$@"
        ;;
    emit-stale|stale)
        trade_trigger_emit_stale "$@"
        ;;
    status)
        trade_trigger_status
        ;;
    *)
        trade_trigger_help
        ;;
esac
