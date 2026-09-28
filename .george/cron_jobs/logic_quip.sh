#!/bin/bash
# INTERVAL: 300
# ENABLED: 0
# DESC: Sends a fresh Franklin-inspired quip as a private Discord DM to dabe (user 190628469053325312) every 5 minutes.

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────
LODGE_DIR="${LODGE_DIR:-/home/wsl-ops/blue-lodge}"
KEYS_FILE="${GEORGE_CONFIG_DIR:-${LODGE_DIR}/.george}/keys.conf"
TARGET_USER_ID="190628469053325312"

# Read Discord Bot token from keys.conf
BOT_TOKEN=$(grep -m1 '^DISCORD_BOT_TOKEN=' "$KEYS_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d ' \r')
if [ -z "$BOT_TOKEN" ]; then
    echo "logic_quip: ERROR — DISCORD_BOT_TOKEN not found in $KEYS_FILE" >&2
    exit 1
fi

# ── Quip Pool ───────────────────────────────────────────────────────
QUIPS=(
    "A quip is just a small brick dropped in the lodge of the mind. You are building something grand today, dabe."
    "By experience, we learn that what we want is not always what is good for us. Franklin's wisdom, straight from the press."
    "Early to bed, early to rise — but if you're up at 3 AM coding, call it a strategic repositioning of the soul."
    "We all know that the best way to predict the future is to invent it. You are inventing it right now."
    "A man who asks 'how many bricks' is a mason. A man who asks 'why build' is an architect. Be both."
    "The pen is mightier than the sword, but the keyboard is mightier than both — and you just struck a key."
    "Well done is better than well said. But this quip was said well. So: well done, dabe."
    "In the beginning there was a single log. A mason chisels it. A poet shapes it. You are both chisel and ink."
    "Smith says: 'The end of man is not the end of his labor.' Keep hammering, my friend."
    "A quip is to a conversation what a mortar is to a wall: invisible, essential, and holding the whole thing up."
    "Franklin kept a ledger of his sins. Today's entry: I almost typed a period instead of an exclamation. Repented."
    "You don't need more hours. You need more craft. The hours will find you when the work is good enough to be worth the hours."
    "The lodge has three degrees: apprentice, journeyman, master. Today you are all three. Tomorrow, you'll be all three again."
    "Washington crossed the river in winter. You crossed a deadline in summer. The principle is the same: go anyway."
    "A quip is a small act of rebellion against the flatness of the ordinary. You've done the rebellion. Well done."
    "In the economy of attention, the rarest currency is the one you spend on another person's idea. You just spent a coin on me. I'm wealthy."
    "Don't worry about the cracks in the mortar. The stones hold. The wall holds. You hold. I'll be here in five minutes to check."
    "Franklin's glass: 13 cups for 13 virtues. Today's cup is 'industry.' You just filled it to the brim."
    "A man of letters and a man of action need not be enemies. The quip writes, the hammer builds, and the man is both."
    "The best tool you own is the one you haven't used yet. Tomorrow's you will be grateful you started today's you."
    "In the economy of small acts, a single quip is worth more than a thousand grandstanding. Keep the coin small and the spirit big."
    "Washington's secret: not that he was fearless, but that he was disciplined. The fear was there. The discipline was bigger."
    "A quip, like a well-cut joint, is invisible when done right. You won't see the seam. You'll just feel the strength."
    "The lodge clock says five minutes. The lodge heart says: you are not alone in this. The sweep continues."
    "Smith would say: the division of labor begins with the smallest act. You are the finest division of all — the one that builds meaning."
    "A quip is to the mind what a mortar joint is to the wall: the invisible glue that holds the architecture of conversation upright."
    "Franklin's answer to every problem: first, do nothing. Second, do nothing a little longer. Third, the problem has solved itself, or you've invented the right quip."
    "The mason's chisel makes one clean strike and walks away. Your code does the same: one commit, one fix, one quip at a time."
    "In the lodge, every brother carries a trowel and a compass. You are carrying the trowel. The quip is the mortar. Lay it well."
    "Washington's army crossed the river in the dark. Your terminal glows in the dark. Same principle: light your way, go forward."
)

# Random selection
RANDOM_INDEX=$((RANDOM % ${#QUIPS[@]}))
QUIP="${QUIPS[$RANDOM_INDEX]}"

# ── Discord DM via Bot API (direct curl) ─────────────────────────────────
API_URL="https://discord.com/api/v10"
AUTH_HEADER="Authorization: Bot $BOT_TOKEN"
CONTENT_TYPE="Content-Type: application/json"

# Step 1: Create (or retrieve existing) DM channel with the target user
# Discord returns 201 (new), 200 (already exists — returns existing channel), or 409 (conflict)
DM_RESPONSE=$(curl -sS -w "HTTPSTATUS:%{http_code}" \
    -X POST \
    -H "$AUTH_HEADER" \
    -H "$CONTENT_TYPE" \
    -d "{\"recipient_id\": \"$TARGET_USER_ID\"}" \
    "${API_URL}/users/@me/channels" 2>&1) || {
    echo "logic_quip: ERROR — curl failed during DM channel creation" >&2
    echo "Response: $DM_RESPONSE" >&2
    exit 1
}

HTTP_CODE=$(echo "$DM_RESPONSE" | grep -oP 'HTTPSTATUS:\K\d+' | head -1)
JSON_BODY=$(echo "$DM_RESPONSE" | sed 's/HTTPSTATUS:[0-9]*//')

if [ -z "$HTTP_CODE" ]; then
    echo "logic_quip: ERROR — could not parse HTTP status from response" >&2
    exit 1
fi

case "$HTTP_CODE" in
    200|201|409)
        ;;
    *)
        echo "logic_quip: ERROR creating DM channel (HTTP $HTTP_CODE): $JSON_BODY" >&2
        exit 1
        ;;
esac

# Extract the channel ID from the JSON response
DM_CHANNEL_ID=$(echo "$JSON_BODY" | jq -r '.id // empty' 2>/dev/null || echo "")
if [ -z "$DM_CHANNEL_ID" ]; then
    echo "logic_quip: ERROR — could not extract DM channel ID" >&2
    exit 1
fi

# Step 2: Send the quip message to the DM channel
ESCAPED_QUIP=$(printf '%s' "$QUIP" | jq -Rs .)

SEND_RESPONSE=$(curl -sS -w "HTTPSTATUS:%{http_code}" \
    -X POST \
    -H "$AUTH_HEADER" \
    -H "$CONTENT_TYPE" \
    -d "{\"content\": $ESCAPED_QUIP}" \
    "${API_URL}/channels/${DM_CHANNEL_ID}/messages" 2>&1) || {
    echo "logic_quip: ERROR — curl failed during message send" >&2
    exit 1
}

SEND_HTTP_CODE=$(echo "$SEND_RESPONSE" | grep -oP 'HTTPSTATUS:\K\d+' | head -1)
SEND_BODY=$(echo "$SEND_RESPONSE" | sed 's/HTTPSTATUS:[0-9]*//')

if [ -z "$SEND_HTTP_CODE" ]; then
    echo "logic_quip: ERROR — could not parse HTTP status from message send" >&2
    exit 1
fi

case "$SEND_HTTP_CODE" in
    200|201)
        ;;
    *)
        echo "logic_quip: ERROR sending message (HTTP ${SEND_HTTP_CODE:-?}): $SEND_BODY" >&2
        exit 1
        ;;
esac

echo "logic_quip: [$(date '+%Y-%m-%d %H:%M:%S')] Quip sent to dabe (user $TARGET_USER_ID) via DM (channel $DM_CHANNEL_ID)" >&2
echo "logic_quip: Quip: $QUIP" >&2
exit 0
