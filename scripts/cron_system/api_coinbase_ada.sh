#!/bin/bash
# ── Autonomic API Trigger: Coinbase Cardano Spot Price Streamer ──
# INTERVAL: 60
# ENABLED: 1
# DESC: Coinbase Cardano (ADA-USD) spot price streamer to Event Bus
# SCOPE: system

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ipc/event_bus.sh" 2>/dev/null || true

_API_URL="https://api.coinbase.com/v2/prices/ADA-USD/spot"
_EVENT_TYPE="crypto_price_tick"
_TRIGGER_ID="coinbase_ada"

# Fetch endpoint data with 6-second timeout
_RESP=$(curl -s --connect-timeout 4 -m 6 "$_API_URL" 2>/dev/null)
[ -z "$_RESP" ] && exit 0

# Apply jq transformation filter
_FILTERED=$(printf '%s' "$_RESP" | jq -c '.data | {symbol: .base, price: (.amount | tonumber), currency: .currency}' 2>/dev/null)
[ -z "$_FILTERED" ] || [ "$_FILTERED" = "null" ] && exit 0

# Persist every tick to market.db (S3 stablecoin fair value = 1/ADAUSD). Unchanged prices are
# still recorded: a flat CEX price is information, a missing tick is not.
_PRICE=$(printf '%s' "$_FILTERED" | jq -r '.price // empty' 2>/dev/null)
_PY_BIN="$LODGE_DIR/.venv/bin/python"
if [ -n "$_PRICE" ] && [ -x "$_PY_BIN" ]; then
    PYTHONPATH="$LODGE_DIR" "$_PY_BIN" "$LODGE_DIR/lib/tools/quant/market_db.py" cex-tick --symbol=ADA-USD "--price=$_PRICE" >/dev/null 2>&1 || true
fi

# Check cache state for deduplication
_CACHE_FILE="$LODGE_DIR/.george/ipc/cache_api_${_TRIGGER_ID}.hash"
_NEW_HASH=$(printf '%s' "$_FILTERED" | md5sum | cut -d' ' -f1)
_OLD_HASH=""
[ -f "$_CACHE_FILE" ] && _OLD_HASH=$(cat "$_CACHE_FILE" 2>/dev/null)

if [ "$_NEW_HASH" != "$_OLD_HASH" ]; then
    printf '%s' "$_NEW_HASH" > "$_CACHE_FILE" 2>/dev/null || true
    
    # Emit into Sovereign Event Bus
    event_bus_emit "$_EVENT_TYPE" "$_FILTERED" "api_trigger_${_TRIGGER_ID}"
fi
