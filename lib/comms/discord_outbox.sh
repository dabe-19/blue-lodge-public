#!/usr/bin/env bash
# lib/comms/discord_outbox.sh — what George has already said in the current Discord run
#
# A Discord run (discord_generate_response) exports:
#   _DISCORD_CURRENT_CHANNEL      channel id the conversation is in
#   _DISCORD_CURRENT_CHANNEL_NAME channel name (may be empty for DMs)
#   _DISCORD_CURRENT_AUTHOR       username of the person George is answering
#   _DISCORD_CURRENT_AUTHOR_ID    their user id
#   DISCORD_RUN_OUTBOX            <run workspace>/outbox.jsonl
#
# Every message George posts during the run (discord_send tool, auto-posted
# drafts) is appended to the outbox. The bridge uses it to:
#   - route "reply to the person I'm talking to" into the current channel
#     instead of silently opening a DM (discord_session_target)
#   - let George edit his own last message (discord_edit tool)
#   - avoid re-posting the same content as the final reply (discord_reply_is_duplicate)
[ -n "${_LIB_DISCORD_OUTBOX_LOADED:-}" ] && return 0; _LIB_DISCORD_OUTBOX_LOADED=1

DISCORD_OUTBOX_DUP_RATIO="${DISCORD_OUTBOX_DUP_RATIO:-0.6}"

# discord_outbox_record <channel_id> <message_id> <text> [kind]
discord_outbox_record() {
    local ch="$1" mid="$2" text="$3" kind="${4:-send}" ob="${DISCORD_RUN_OUTBOX:-}"
    [ -n "$ob" ] || return 0
    [[ "$ch" =~ ^[0-9]{5,25}$ ]] || return 0
    [[ "$mid" =~ ^[0-9]{5,25}$ ]] || mid=""
    mkdir -p "$(dirname "$ob")" 2>/dev/null || return 0
    jq -cn --arg ch "$ch" --arg mid "$mid" --arg t "${text:0:8000}" --arg k "$kind" --argjson ts "$(date +%s)" \
        '{ts:$ts, channel:$ch, message_id:$mid, kind:$k, len:($t|length), text:$t}' >> "$ob" 2>/dev/null || true
}

# discord_outbox_last_id [channel] → id of the last message George posted in this run (optionally in channel)
discord_outbox_last_id() {
    local ch="${1:-}" ob="${DISCORD_RUN_OUTBOX:-}"
    [ -s "$ob" ] || return 1
    local id
    id=$(jq -rs --arg ch "$ch" '[.[] | select(.message_id != "" and ($ch == "" or .channel == $ch))] | last | .message_id // empty' "$ob" 2>/dev/null)
    [ -n "$id" ] && printf '%s' "$id"
}

# discord_outbox_has_id <message_id> → 0 if George posted that message in this run
discord_outbox_has_id() {
    local mid="$1" ob="${DISCORD_RUN_OUTBOX:-}"
    [ -s "$ob" ] && [[ "$mid" =~ ^[0-9]{5,25}$ ]] || return 1
    jq -es --arg m "$mid" 'any(.[]; .message_id == $m)' "$ob" >/dev/null 2>&1
}

# discord_outbox_channel_of <message_id>
discord_outbox_channel_of() {
    local mid="$1" ob="${DISCORD_RUN_OUTBOX:-}"
    [ -s "$ob" ] || return 1
    jq -rs --arg m "$mid" '[.[] | select(.message_id == $m)] | last | .channel // empty' "$ob" 2>/dev/null
}

# discord_outbox_count [outbox] → number of posts
discord_outbox_count() {
    local ob="${1:-${DISCORD_RUN_OUTBOX:-}}"
    [ -s "$ob" ] || { echo 0; return 0; }
    wc -l < "$ob" | tr -d ' '
}

# discord_outbox_texts [outbox] [channel] → posted text (optionally only in channel), oldest first
discord_outbox_texts() {
    local ob="${1:-${DISCORD_RUN_OUTBOX:-}}" ch="${2:-}"
    [ -s "$ob" ] || return 0
    jq -r --arg ch "$ch" 'select($ch == "" or .channel == $ch) | .text' "$ob" 2>/dev/null
}

# _discord_norm_name <s> → lowercase, no leading @/#, no quotes/spaces at the edges
_discord_norm_name() {
    local s="${1,,}"
    s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
    s="${s#\"}"; s="${s%\"}"; s="${s#\'}"; s="${s%\'}"
    s="${s#@}"; s="${s#\#}"
    printf '%s' "$s"
}

# discord_session_target <target> → prints "<channel_id>\t<mention_prefix>" when, inside a
# Discord run, the target means "the conversation I'm in":
#   empty, here, this channel, current, reply, default, webhook, the current channel's
#   name/id, or the person George is answering (name, @name, <@id>, id).
# Any other *username* inside a public-channel run is also kept in the channel, with an
# @mention prefix — DMs require an explicit "dm:<user>" target or the discord_dm tool.
# Returns 1 (prints nothing) when the target should be resolved normally.
discord_session_target() {
    local raw="${1:-}" ch="${_DISCORD_CURRENT_CHANNEL:-}"
    [ "${_DISCORD_IN_SESSION:-0}" = "1" ] && [[ "$ch" =~ ^[0-9]{5,25}$ ]] || return 1
    [[ "$raw" == dm:* ]] && return 1
    local t; t=$(_discord_norm_name "$raw")
    local author; author=$(_discord_norm_name "${_DISCORD_CURRENT_AUTHOR:-}")
    local author_id="${_DISCORD_CURRENT_AUTHOR_ID:-}"
    local chname; chname=$(_discord_norm_name "${_DISCORD_CURRENT_CHANNEL_NAME:-}")
    case "$t" in
        me|operator|owner) return 1 ;;
        ""|here|this|"this channel"|current|"current channel"|reply|default|webhook|channel|thread|"the user"|user)
            printf '%s\t' "$ch"; return 0 ;;
    esac
    if [ "$t" = "$ch" ] || { [ -n "$chname" ] && [ "$t" = "$chname" ]; }; then
        printf '%s\t' "$ch"; return 0
    fi
    if { [ -n "$author" ] && [ "$t" = "$author" ]; } || { [ -n "$author_id" ] && { [ "$t" = "$author_id" ] || [ "$t" = "<@$author_id>" ] || [ "$t" = "<@!$author_id>" ]; }; }; then
        printf '%s\t' "$ch"; return 0
    fi
    # A different known channel name/id → let normal resolution handle it.
    if [[ "$t" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if declare -f discord_channel_resolve &>/dev/null && [ -n "$(discord_channel_resolve "$t" 2>/dev/null)" ]; then
        return 1
    fi
    # Some other user: in a DM run that's a different person → normal resolution (DM).
    if declare -f discord_channel_is_dm &>/dev/null && discord_channel_is_dm "$ch"; then
        return 1
    fi
    # Public channel: keep it in the conversation, addressed to them.
    if [[ "$t" =~ ^[a-z0-9_.]{2,32}$ ]]; then
        printf '%s\t@%s ' "$ch" "$t"; return 0
    fi
    return 1
}

# discord_strip_meta_lines <text> → drops self-narration about delivery
# ("Message delivered to @x via Discord DM", "Action taken: Sent a reply…", "**What I did:** - Posted the in-channel answer…").
discord_strip_meta_lines() {
    printf '%s\n' "$1" | grep -viE '^[[:space:]]*[*_>`-]*[[:space:]]*(\(?message (was )?(delivered|sent|posted) (to|in|via)|action taken:|what i did:?|done,[[:space:]]*brother[.!]?$|delivered (to|via) (@|discord|the channel)|(posted|sent|delivered) the (in-channel )?(answer|reply|response|message|report) (to|in|via)|milestone(s)? (marked )?(complete|completed|done)|(i|i have|i'"'"'ve) (just )?(sent|posted|delivered) (a |the |my )?(direct |in-channel )?(reply|message|response|report|answer|dm) (to|in|via))' \
        | sed -e '/./,$!d'
}

# _discord_tokens <text> → unique lowercase word tokens (>=4 chars), one per line
_discord_tokens() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '\n' | awk 'length($0) >= 4' | sort -u
}

# discord_reply_is_duplicate <reply> [outbox] [channel] → 0 when the reply adds nothing new:
# its tokens are >= DISCORD_OUTBOX_DUP_RATIO covered by what the run already posted (in channel).
discord_reply_is_duplicate() {
    local reply="$1" ob="${2:-${DISCORD_RUN_OUTBOX:-}}" ch="${3:-}"
    [ -s "$ob" ] || return 1
    local posted; posted=$(discord_outbox_texts "$ob" "$ch")
    [ -n "${posted//[[:space:]]/}" ] || return 1
    local rt pt
    rt=$(_discord_tokens "$reply"); pt=$(_discord_tokens "$posted")
    local total; total=$(printf '%s\n' "$rt" | grep -c . || true)
    [ "${total:-0}" -gt 0 ] || return 0
    local common; common=$(comm -12 <(printf '%s\n' "$rt") <(printf '%s\n' "$pt") | grep -c . || true)
    awk -v c="${common:-0}" -v t="$total" -v r="$DISCORD_OUTBOX_DUP_RATIO" 'BEGIN { exit !((c / t) >= r) }'
}
