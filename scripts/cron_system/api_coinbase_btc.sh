#!/bin/bash
# ── Autonomic API Trigger: Coinbase BTC Spot Price Streamer ──
# INTERVAL: 60
# ENABLED: 1
# DESC: Coinbase Bitcoin (BTC-USD) spot price streamer to Event Bus
# SCOPE: system

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ipc/event_bus.sh" 2>/dev/null || true

_API_URL="https://api.coinbase.com/v2/prices/BTC-USD/spot"
_EVENT_TYPE="crypto_price_tick"
_TRIGGER_ID="coinbase_btc"

# Fetch endpoint data with 6-second timeout
_RESP=$(curl -s --connect-timeout 4 -m 6 "$_API_URL" 2>/dev/null)
[ -z "$_RESP" ] && exit 0

# Apply jq transformation filter
_FILTERED=$(printf '%s' "$_RESP" | jq -c '.data | {symbol: .base, price: (.amount | tonumber), currency: .currency}' 2>/dev/null)
[ -z "$_FILTERED" ] || [ "$_FILTERED" = "null" ] && exit 0

# Check cache state for deduplication
_CACHE_FILE="$LODGE_DIR/.george/ipc/cache_api_$coinbase_btc.hash"
_NEW_HASH=$(printf '%s' "$_FILTERED" | md5sum | cut -d' ' -f1)
_OLD_HASH=""
[ -f "$_CACHE_FILE" ] && _OLD_HASH=$(cat "$_CACHE_FILE" 2>/dev/null)

if [ "$_NEW_HASH" != "$_OLD_HASH" ]; then
    printf '%s' "$_NEW_HASH" > "$_CACHE_FILE" 2>/dev/null || true
    
    # Emit into Sovereign Event Bus
    event_bus_emit "$_EVENT_TYPE" "$_FILTERED" "api_trigger_$coinbase_btc"
fi
