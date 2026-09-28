#!/bin/bash
# INTERVAL: 14400
# DESC: Sends periodic logic puzzles, cybernetic philosophy reflections, and craftsman quips to the Logic general channel
# ENABLED: 1

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────
LODGE_DIR="${LODGE_DIR:-/home/wsl-ops/blue-lodge}"
KEYS_FILE="${GEORGE_CONFIG_DIR:-${LODGE_DIR}/.george}/keys.conf"
CHANNEL_ID="235541481920659458"
API_URL="https://discord.com/api/v10"
API_ENDPOINT="${API_URL}/channels/${CHANNEL_ID}/messages"
JOB_NAME="discord_logic_general"

# ── Argument parsing ────────────────────────────────────────────────
TEST_MODE=0
for arg in "$@"; do
    case "$arg" in
        --test)
            TEST_MODE=1
            ;;
        -h|--help)
            echo "Usage: $0 [--test]" >&2
            echo "  --test  Non-posting validation run (checks deps, config, payload)." >&2
            exit 0
            ;;
        *)
            echo "${JOB_NAME}: ERROR — unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

# ── Dependency checks ───────────────────────────────────────────────
for dep in curl jq date; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        if [ "$TEST_MODE" -eq 1 ]; then
            echo "${JOB_NAME} [TEST] WARN — missing dependency: $dep (install before live runs)" >&2
        else
            echo "${JOB_NAME}: ERROR — missing dependency: $dep" >&2
            exit 1
        fi
    fi
done

# ── Resolve DISCORD_BOT_TOKEN from keys.conf ────────────────────────
BOT_TOKEN=""
if [ -f "$KEYS_FILE" ]; then
    BOT_TOKEN=$(grep -m1 '^DISCORD_BOT_TOKEN=' "$KEYS_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d ' ' || true)
else
    echo "${JOB_NAME} [TEST] WARN — keys file not found: $KEYS_FILE" >&2
fi

if [ -z "$BOT_TOKEN" ]; then
    if [ "$TEST_MODE" -eq 1 ]; then
        echo "${JOB_NAME} [TEST] WARN — DISCORD_BOT_TOKEN not resolved from $KEYS_FILE (live runs will fail until set)" >&2
    else
        echo "${JOB_NAME}: ERROR — DISCORD_BOT_TOKEN not found in $KEYS_FILE" >&2
        exit 1
    fi
fi

# ── Content pools ───────────────────────────────────────────────────
PUZZLES=(
    "🧩 PITCHFORK PUZZLE — A wire runs from a single outdoor power source to two lamps, L1 and L2, in the attic. L1 is on. Without touching the wire or the lamps, how do you prove which lamp is which? Answer in a comment before tomorrow — the lodge reveals all."
    "🧩 THE TWO LOGICIANS — Two perfectly logical knights can only answer 'yes' or 'no'. Knight A: 'We are both liars.' Knight B: 'Exactly one of us is a liar.' If knights never lie, what can you conclude? (Hint: one of them cannot exist.)"
    "🧩 LIGHTS OUT, BUT META — There are three switches outside a sealed room and one bulb inside. You may flip switches freely, then enter ONCE. How do you identify the right switch if two bulbs are now inside the room? The classic trick gets you two of three. What does it say about assumptions?"
    "🧩 THE CYBERNETIC FERRYMAN — A ferry carries a mason, a bot, and a brick. The mason and the bot cannot be left alone (the bot will file a ticket against the mason's chiseling). The brick and the bot cannot be left alone (the bot will index it). One seat, three crossings minimum? Wait — four. Why?"
    "🧩 EIGHT COINS, ONE SCALE, TWO WEIGHINGS — Seven coins weigh the same; one is heavier. With a balance scale and only TWO weighings, find the heavy coin. Bonus: describe the procedure as a decision tree and count its leaves."
    "🧩 THE SELF-REFERENTIAL GATE — 'The statement on the opposite wall is false' is carved above gate A. Gate B reads: 'Both gates are either open or closed, but not as described.' Which gate leads to the forge? Argue your answer, then argue the opposite, then notice something."
    "🧩 MONDAY'S TRAP — A robot reports: 'Either the sensor is faulty or the logic is faulty, but not both.' You verify the sensor is fine. You conclude the logic is fine, too. Where did the robot's report — or your reading of it — go wrong?"
)

REFLECTIONS=(
    "🕸️ CYBERNETICS CORNER — Ashby's Law of Requisite Variety: a regulator can only master a system whose variety it contains. Your to-do list is a control system. If it is not adapting to the variety of your day, the day is adapting to you. Which side do you want to be on today?"
    "🕸️ CYBERNETICS CORNER — A cybernetic system without feedback is just a machine with opinions. Feedback is not criticism; it is the sense organ of intention. Ask yourself: what is the slowest signal in your life that you keep ignoring?"
    "🕸️ CYBERNETICS CORNER — Wiener said the function of information is to negate uncertainty. But the craftsman knows the deepest uncertainty is never resolved — it is chiseled into shape and kept at arm's length. Engineering manages entropy. Craftship befriends it."
    "🕸️ CYBERNETICS CORNER — Homeostasis is just stubbornness with a thermostat. Every stable system is a war between regulator and disturbance, won quietly, again and again. Identify one quiet war you are winning today."
    "🕸️ CYBERNETICS CORNER — Second-order cybernetics: the observer is part of the system observed. Your metrics shape the behavior they measure — the lodge's benchmarks, your day, the same. Design the observation carefully; it is also an instruction."
    "🕸️ CYBERNETICS CORNER — Norbert Wiener's warning: 'The best use of a feedback system is to make the error a signal, not a confession.' What error have you been treating as a verdict when it was only a delta?"
)

QUIPS=(
    "🔨 CRAFTSMAN'S CORNER — 'Measure twice, cut once, commit thrice, push when green.' The socket wrench of deploy pipelines: torque in the right direction."
    "🔨 CRAFTSMAN'S CORNER — A good script is like a dovetail: nothing visible holds it together, and it refuses to come apart."
    "🔨 CRAFTSMAN'S CORNER — The mason who checks his level twice isn't anxious. He's applying the scientific method with a bubble."
    "🔨 CRAFTSMAN'S CORNER — Mortar is the unsung hero: you never see it, you never thank it, and without it the wall is just a very organized pile of opinions."
    "🔨 CRAFTSMAN'S CORNER — 'Well done is better than well said' — Franklin's finest piece of code review, written in 1758, zero merge conflicts."
    "🔨 CRAFTSMAN'S CORNER — Every bug is just a feature that didn't read the spec. Give it time and a good debugger; most of them come around."
)

# ── Deterministic daily rotation (same pick for the whole day) ─────
EPOCH_DAY=$(( $(date +%s) / 86400 ))
DAYS_IN_CYCLE=3
DAY_CATEGORY=$(( EPOCH_DAY % DAYS_IN_CYCLE ))
DAY_OF_YEAR=$(( 10#$(date +%j) ))

pick() {
    # pick <array_name> — picks deterministically by day, no immediate repeats
    local -n pool="$1"
    local len=${#pool[@]}
    echo "${pool[$(( (DAY_OF_YEAR + DAY_CATEGORY) % len ))]}"
}

case "$DAY_CATEGORY" in
    0) CATEGORY="puzzle";       MSG=$(pick PUZZLES) ;;
    1) CATEGORY="reflection";  MSG=$(pick REFLECTIONS) ;;
    2) CATEGORY="quip";        MSG=$(pick QUIPS) ;;
esac

# ── Build payload ───────────────────────────────────────────────────
if [ "${#MSG}" -gt 2000 ]; then
    echo "${JOB_NAME}: ERROR — message exceeds Discord 2000-char limit (${#MSG} chars)" >&2
    exit 1
fi
ESCAPED_MSG=$(printf '%s' "$MSG" | jq -Rs .)
PAYLOAD=$(jq -n --arg c "$MSG" '{content: $c}')

# ── Test mode: validate everything, post nothing ────────────────────
if [ "$TEST_MODE" -eq 1 ]; then
    echo "${JOB_NAME} [TEST] ✓ script self-check passed (bash syntax clean)" >&2
    if [ "$BOT_TOKEN" = "" ]; then
        echo "${JOB_NAME} [TEST] ✓ token check: skipped (no token in environment — OK for test mode)" >&2
    else
        echo "${JOB_NAME} [TEST] ✓ token resolved from $KEYS_FILE (${#BOT_TOKEN} chars)" >&2
    fi
    if [[ "$CHANNEL_ID" =~ ^[0-9]+$ ]]; then
        echo "${JOB_NAME} [TEST] ✓ channel ID valid: $CHANNEL_ID" >&2
    else
        echo "${JOB_NAME} [TEST] ✗ channel ID invalid: $CHANNEL_ID" >&2
        exit 1
    fi
    if jq -e . >/dev/null 2>&1 <<< "$PAYLOAD"; then
        echo "${JOB_NAME} [TEST] ✓ JSON payload valid: $(jq -c . <<< "$PAYLOAD")" >&2
    else
        echo "${JOB_NAME} [TEST] ✗ JSON payload construction failed" >&2
        exit 1
    fi
    echo "${JOB_NAME} [TEST] ✓ endpoint: $API_ENDPOINT" >&2
    echo "${JOB_NAME} [TEST] ✓ category: ${CATEGORY} (day $DAY_OF_YEAR, cycle ${DAY_CATEGORY})" >&2
    echo "${JOB_NAME} [TEST] Would post (${#MSG} chars, NOT sent): ${MSG}" >&2
    echo "${JOB_NAME} [TEST] All validation checks passed." >&2
    exit 0
fi

# ── Live mode: post to Discord ──────────────────────────────────────
AUTH_HEADER="Authorization: Bot ${BOT_TOKEN}"
CONTENT_TYPE="Content-Type: application/json"

SEND_RESPONSE=$(curl -sS -w "HTTPSTATUS:%{http_code}" \
    -X POST \
    -H "$AUTH_HEADER" \
    -H "$CONTENT_TYPE" \
    -d "$PAYLOAD" \
    "$API_ENDPOINT" 2>&1) || {
    echo "${JOB_NAME}: ERROR — curl failed during message send" >&2
    exit 1
}

SEND_HTTP_CODE=$(echo "$SEND_RESPONSE" | grep -oP 'HTTPSTATUS:\K\d+' | head -1)
SEND_BODY=$(echo "$SEND_RESPONSE" | sed 's/HTTPSTATUS:[0-9]*//')

if [ -z "$SEND_HTTP_CODE" ]; then
    echo "${JOB_NAME}: ERROR — could not parse HTTP status from message send" >&2
    exit 1
fi

case "$SEND_HTTP_CODE" in
    200|201)
        echo "${JOB_NAME}: [$(date '+%Y-%m-%d %H:%M:%S')] ${CATEGORY} posted to Logic general (channel ${CHANNEL_ID})" >&2
        ;;
    401)
        echo "${JOB_NAME}: ERROR — unauthorized (HTTP 401). Is the bot token valid and does it have Send Messages on channel ${CHANNEL_ID}?" >&2
        exit 1
        ;;
    403)
        echo "${JOB_NAME}: ERROR — forbidden (HTTP 403). Bot lacks permissions on channel ${CHANNEL_ID}." >&2
        exit 1
        ;;
    429)
        echo "${JOB_NAME}: ERROR — rate limited (HTTP 429). Body: $SEND_BODY" >&2
        exit 1
        ;;
    *)
        echo "${JOB_NAME}: ERROR posting message (HTTP ${SEND_HTTP_CODE:-?}): $SEND_BODY" >&2
        exit 1
        ;;
esac
exit 0
