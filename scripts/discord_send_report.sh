#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# George Pure Bash Discord Delivery Helper
# ══════════════════════════════════════════════════════════════════════
# Delivers report text or markdown file to a Discord user DM or channel
# with safe chunking (<1800 characters) via curl and jq.
# Zero Python dependency.
#
# Usage:
#   scripts/discord_send_report.sh <recipient> <report_file_or_text>
# ══════════════════════════════════════════════════════════════════════

set -euo pipefail

LODGE_DIR="${LODGE_DIR:-/home/wsl-ops/blue-lodge}"
KEYS_FILE="$LODGE_DIR/.george/keys.conf"

BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"
if [ -z "$BOT_TOKEN" ] && [ -f "$KEYS_FILE" ]; then
    BOT_TOKEN=$(grep -E '^DISCORD_BOT_TOKEN=' "$KEYS_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"\r\n' || true)
fi

if [ -z "$BOT_TOKEN" ]; then
    echo "[!] DISCORD_BOT_TOKEN not configured." >&2
    exit 1
fi

RECIPIENT="${1:-}"
PAYLOAD="${2:-}"

# Polymorphic argument order: if arg 1 is an existing file and arg 2 is not, swap
if [ -f "$RECIPIENT" ] && [ ! -f "$PAYLOAD" ]; then
    local_swap="$RECIPIENT"
    RECIPIENT="$PAYLOAD"
    PAYLOAD="$local_swap"
fi

if [ -z "$RECIPIENT" ] || [ -z "$PAYLOAD" ]; then
    echo "Usage: discord_send_report.sh <recipient> <report_file_or_text>" >&2
    exit 1
fi

CONTENT=""
if [ -f "$PAYLOAD" ]; then
    CONTENT=$(cat "$PAYLOAD")
else
    CONTENT="$PAYLOAD"
fi

if [ -z "$CONTENT" ]; then
    echo "[!] Empty report content." >&2
    exit 1
fi

# Resolve recipient user ID
TARGET_UID="$RECIPIENT"
if [ "$RECIPIENT" = "@dabe" ] || [ "$RECIPIENT" = "dabe" ]; then
    TARGET_UID="190628469053325312"
elif [[ "$RECIPIENT" =~ ^@ ]]; then
    TARGET_UID="${RECIPIENT#@}"
fi

# 1. Create DM channel
API_URL="https://discord.com/api/v10"
DM_RESP=$(curl -sL -X POST "${API_URL}/users/@me/channels" \
    -H "Authorization: Bot ${BOT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"recipient_id\": \"${TARGET_UID}\"}" 2>/dev/null || true)

CHAN_ID=$(echo "$DM_RESP" | jq -r '.id // empty' 2>/dev/null || true)

if [ -z "$CHAN_ID" ]; then
    echo "[!] Failed to open DM channel with $RECIPIENT: $DM_RESP" >&2
    exit 1
fi

# 2. Chunk markdown text into safe chunks (<1800 chars) via pure awk
CHUNKS=()
while IFS= read -r -d $'\x1e' chunk; do
    [ -n "$chunk" ] && CHUNKS+=("$chunk")
done < <(echo "$CONTENT" | awk '
BEGIN { cur = ""; len = 0 }
{
    line = $0 "\n"
    l_len = length(line)
    if (len + l_len > 1800 && len > 0) {
        printf "%s\x1e", cur
        cur = line
        len = l_len
    } else {
        cur = cur line
        len += l_len
    }
}
END {
    if (len > 0) {
        printf "%s\x1e", cur
    }
}')

# 3. Dispatch chunks
TOTAL=${#CHUNKS[@]}
IDX=1
for c in "${CHUNKS[@]}"; do
    POST_DATA=$(jq -n --arg content "$c" '{"content": $content}')
    RESP=$(curl -sL -X POST "${API_URL}/channels/${CHAN_ID}/messages" \
        -H "Authorization: Bot ${BOT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$POST_DATA" 2>/dev/null || true)
    
    MSG_ID=$(echo "$RESP" | jq -r '.id // empty' 2>/dev/null || true)
    if [ -n "$MSG_ID" ]; then
        echo "  ✓ Dispatched chunk ${IDX}/${TOTAL} (Discord Message ID: ${MSG_ID})"
    else
        echo "[!] Failed to dispatch chunk ${IDX}/${TOTAL}: $RESP" >&2
        exit 1
    fi
    IDX=$((IDX + 1))
    sleep 0.5
done

exit 0
