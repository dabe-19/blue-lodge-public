#!/bin/bash
# ── Autonomic Cron Trigger: Sovereign On-Chain Wallet Monitor ──
# INTERVAL: 60
# ENABLED: 1
# DESC: Sovereign on-chain Cardano wallet UTxO & balance monitor
# SCOPE: system

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ipc/event_bus.sh" 2>/dev/null || true

_PY_BIN="$LODGE_DIR/.venv/bin/python"
[ -f "$_PY_BIN" ] || _PY_BIN="python3"

_CACHE_DIR="$LODGE_DIR/.george/wallets"
mkdir -p "$_CACHE_DIR" 2>/dev/null

_STATUS_JSON=$("$_PY_BIN" "$LODGE_DIR/lib/tools/wallet_status.py" 2>/dev/null)
[ -z "$_STATUS_JSON" ] && exit 0

# Verify valid JSON
if printf '%s' "$_STATUS_JSON" | jq -e .status >/dev/null 2>&1; then
    printf '%s' "$_STATUS_JSON" > "$_CACHE_DIR/status_cache.json"
    
    # Emit into Sovereign Event Bus
    event_bus_emit "wallet_balance_tick" "$_STATUS_JSON" "cron_wallet_poll" 2>/dev/null || true
fi
