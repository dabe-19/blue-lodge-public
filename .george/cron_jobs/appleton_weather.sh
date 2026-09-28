#!/bin/bash
# INTERVAL: 600
# DESC: Agentic Weather Lookup for Appleton, WI dispatched to @dabe via Discord DM
# CREATED: 2026-09-27 11:15:35

set -euo pipefail

LODGE_DIR="${LODGE_DIR:-/home/wsl-ops/blue-lodge}"
KEYS_FILE="${GEORGE_CONFIG_DIR:-${LODGE_DIR}/.george}/keys.conf"
TARGET_USER_ID="190628469053325312"

# 1. Fetch live weather data for Appleton, WI
WEATHER_JSON=$(curl -fsS --connect-timeout 8 "https://api.open-meteo.com/v1/forecast?latitude=44.2619&longitude=-88.4154&current=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m&temperature_unit=fahrenheit&wind_speed_unit=mph" 2>/dev/null || echo "")

if [ -z "$WEATHER_JSON" ]; then
    echo "appleton_weather: Failed to fetch weather from Open-Meteo" >&2
    exit 1
fi

TEMP=$(echo "$WEATHER_JSON" | jq -r '.current.temperature_2m // "N/A"')
HUMIDITY=$(echo "$WEATHER_JSON" | jq -r '.current.relative_humidity_2m // "N/A"')
WIND=$(echo "$WEATHER_JSON" | jq -r '.current.wind_speed_10m // "N/A"')
WCODE=$(echo "$WEATHER_JSON" | jq -r '.current.weather_code // 0')

CONDITION="Clear"
case "$WCODE" in
    0) CONDITION="Clear sky" ;;
    1|2|3) CONDITION="Mainly clear / Overcast" ;;
    45|48) CONDITION="Fog" ;;
    51|53|55) CONDITION="Drizzle" ;;
    61|63|65) CONDITION="Rain" ;;
    71|73|75) CONDITION="Snow" ;;
    80|81|82) CONDITION="Rain showers" ;;
    95|96|99) CONDITION="Thunderstorm" ;;
esac

TIMESTAMP=$(date '+%Y-%m-%d %I:%M %p %Z')

REPORT="🌤️ **Appleton, WI Weather Report** ($TIMESTAMP)
• **Temperature:** ${TEMP}°F
• **Condition:** ${CONDITION}
• **Humidity:** ${HUMIDITY}%
• **Wind Speed:** ${WIND} mph
*Dispatched autonomously via George Autonomic Cron Engine.*"

# 2. Authenticate and dispatch Discord DM to @dabe
BOT_TOKEN=$(grep -m1 '^DISCORD_BOT_TOKEN=' "$KEYS_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d ' \r')
if [ -z "$BOT_TOKEN" ]; then
    echo "appleton_weather: DISCORD_BOT_TOKEN missing in $KEYS_FILE" >&2
    exit 1
fi

API_URL="https://discord.com/api/v10"
AUTH_HEADER="Authorization: Bot $BOT_TOKEN"
CONTENT_TYPE="Content-Type: application/json"

# Create / retrieve DM channel
DM_RESP=$(curl -sS -X POST \
    -H "$AUTH_HEADER" \
    -H "$CONTENT_TYPE" \
    -d "{\"recipient_id\": \"$TARGET_USER_ID\"}" \
    "${API_URL}/users/@me/channels" 2>/dev/null || echo "")

DM_CHAN_ID=$(echo "$DM_RESP" | jq -r '.id // empty' 2>/dev/null || echo "")
if [ -z "$DM_CHAN_ID" ]; then
    echo "appleton_weather: Could not resolve Discord DM channel ID" >&2
    exit 1
fi

# Send formatted report to Discord DM
ESCAPED_MSG=$(printf '%s' "$REPORT" | jq -Rs .)
SEND_RESP=$(curl -sS -X POST \
    -H "$AUTH_HEADER" \
    -H "$CONTENT_TYPE" \
    -d "{\"content\": $ESCAPED_MSG}" \
    "${API_URL}/channels/${DM_CHAN_ID}/messages" 2>/dev/null || echo "")

MSG_ID=$(echo "$SEND_RESP" | jq -r '.id // empty' 2>/dev/null || echo "")
if [ -n "$MSG_ID" ]; then
    echo "appleton_weather: Successfully delivered report to @dabe (Discord Message ID: $MSG_ID)"
    exit 0
else
    echo "appleton_weather: Failed to send Discord message: $SEND_RESP" >&2
    exit 1
fi