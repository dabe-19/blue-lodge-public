#!/bin/bash
# ── Autonomic API Trigger: Polymarket Top Prediction Markets Watcher ──
# INTERVAL: 180
# ENABLED: 1
# DESC: Polymarket top prediction markets watcher & shift emitter
# SCOPE: system

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ipc/event_bus.sh" 2>/dev/null || true

_API_URL="https://gamma-api.polymarket.com/markets?limit=10&active=true&closed=false&order=volume24hr&ascending=false"
_EVENT_TYPE="polymarket_market_shift"
_TRIGGER_ID="polymarket_active"

# Fetch endpoint data with 6-second timeout
_RESP=$(curl -s --connect-timeout 4 -m 6 "$_API_URL" 2>/dev/null)
[ -z "$_RESP" ] && exit 0

# Apply jq transformation filter
_FILTERED=$(printf '%s' "$_RESP" | jq -c '.[0:5] | map({id: .id, question: .question, volume: (.volume | tonumber), outcomePrices: .outcomePrices})' 2>/dev/null)
[ -z "$_FILTERED" ] || [ "$_FILTERED" = "null" ] && exit 0

# Check cache state for deduplication
_CACHE_FILE="$LODGE_DIR/.george/ipc/cache_api_$polymarket_active.hash"
_NEW_HASH=$(printf '%s' "$_FILTERED" | md5sum | cut -d' ' -f1)
_OLD_HASH=""
[ -f "$_CACHE_FILE" ] && _OLD_HASH=$(cat "$_CACHE_FILE" 2>/dev/null)

if [ "$_NEW_HASH" != "$_OLD_HASH" ]; then
    printf '%s' "$_NEW_HASH" > "$_CACHE_FILE" 2>/dev/null || true
    
    # Emit into Sovereign Event Bus
    event_bus_emit "$_EVENT_TYPE" "$_FILTERED" "api_trigger_$polymarket_active"
fi
