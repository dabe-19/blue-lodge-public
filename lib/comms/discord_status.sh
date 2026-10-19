#!/usr/bin/env bash
# lib/comms/discord_status.sh — Discord reply contract helpers (refinement P3)
#
#   3.1/3.2  discord_reply_for_run      reply text comes ONLY from the run ledger
#                                       (runs/<id>/final_reply.md) or an honest
#                                       failure notice — never another session's output
#   3.3      discord_status_*           one status message per run, edited in place
#                                       (>=20 s throttle); final answer is a new message
#   3.4      discord_status_verbose_ok  DMs from Master Mason (or owner) get step text;
#                                       everyone else gets a terse progress line
#   3.5      discord_feedback_*         reaction → ledger label map, /rate command
#   3.6      discord_pid_write/alive    pidfiles carry a start-time sidecar so a
#                                       recycled PID after reboot is not "alive"
[ -n "${_LIB_DISCORD_STATUS_LOADED:-}" ] && return 0; _LIB_DISCORD_STATUS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"
DISCORD_SESSIONS_DIR="${DISCORD_SESSIONS_DIR:-$GEORGE_DIR/discord_sessions}"
DISCORD_API_BASE="${DISCORD_API_BASE:-https://discord.com/api/v10}"
DISCORD_STATUS_ENABLED="${DISCORD_STATUS_ENABLED:-1}"
DISCORD_STATUS_INTERVAL="${DISCORD_STATUS_INTERVAL:-20}"
DISCORD_FEEDBACK_TTL="${DISCORD_FEEDBACK_TTL:-86400}"

source "$LODGE_DIR/lib/core/run_ledger.sh" 2>/dev/null || true

# emoji|label — order is the order shown to users
DISCORD_FEEDBACK_MAP=(
    "👍|good"
    "👎|bad"
    "🤏|partial"
    "❌|wrong"
    "⚠️|unsafe"
    "🐢|slow"
)

_ds_valid_snowflake() { [[ "${1:-}" =~ ^[0-9]{5,25}$ ]]; }

_ds_token() {
    if [ -n "${DISCORD_BOT_TOKEN:-}" ]; then printf '%s' "$DISCORD_BOT_TOKEN"; return 0; fi
    declare -f api_get_key &>/dev/null && api_get_key "DISCORD_BOT_TOKEN" 2>/dev/null
}

# _ds_api <METHOD> <path> [json] → body on stdout; rc 0 on 2xx
_ds_api() {
    local method="$1" path="$2" data="${3:-}" token
    [ "${DISCORD_STATUS_ENABLED:-1}" = "0" ] && return 1
    [ "${LODGE_EVAL:-0}" = "1" ] && return 1
    token=$(_ds_token) || return 1
    [ -n "$token" ] || return 1
    local args=(-s -m 10 --connect-timeout 5 -X "$method" -w $'\n%{http_code}'
        -H "Authorization: Bot $token" -H "User-Agent: DiscordBot (blue-lodge, 1.0)")
    [ -n "$data" ] && args+=(-H "Content-Type: application/json" -d "$data")
    local resp code
    resp=$(curl "${args[@]}" "${DISCORD_API_BASE}${path}" 2>/dev/null) || return 1
    code="${resp##*$'\n'}"
    printf '%s' "${resp%$'\n'*}"
    [[ "$code" =~ ^2[0-9][0-9]$ ]]
}

_ds_urlencode() { jq -rn --arg s "$1" '$s|@uri'; }

# ── 3.6 pidfiles ──────────────────────────────────────────────────
_ds_proc_start() {
    local pid="$1" stat
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    stat="${stat##*) }"          # comm may contain spaces; fields resume after ") "
    # after ") ": field 3 is state … field 22 (starttime) is index 19 here
    awk '{print $20}' <<<"$stat"
}

discord_pid_write() {
    local file="$1" pid="$2"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$pid" > "$file"
    local st; st=$(_ds_proc_start "$pid") && printf '%s\n' "$st" > "${file}.start"
    return 0
}

# discord_pid_alive <file> → 0 if the recorded process is the one still running
discord_pid_alive() {
    local file="$1" pid st_now st_rec
    [ -f "$file" ] || return 1
    pid=$(head -n1 "$file" 2>/dev/null | tr -cd '0-9')
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
    if [ -f "${file}.start" ]; then
        st_rec=$(tr -cd '0-9' < "${file}.start")
        st_now=$(_ds_proc_start "$pid") || return 1
        [ "$st_rec" = "$st_now" ] || return 1
        return 0
    fi
    # Legacy pidfile without sidecar: written before the last boot → stale.
    local boot_epoch mtime
    boot_epoch=$(( $(date +%s) - $(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0) ))
    mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
    [ "$mtime" -ge "$boot_epoch" ]
}

discord_pid_clear() { rm -f "$1" "${1}.start" 2>/dev/null; }

# ── 3.4 visibility & ownership ────────────────────────────────────
discord_channel_is_dm() {
    local ch="$1" f="${DISCORD_KNOWN_DMS_FILE:-$DISCORD_SESSIONS_DIR/known_dms.json}"
    [ -f "$f" ] && jq -e --arg c "$ch" '[.[]] | index($c) != null' "$f" >/dev/null 2>&1
}

discord_is_owner() {
    local uid="${1:-}" author="${2:-}"
    [ -z "$uid" ] && [ -z "$author" ] && return 1

    local owners="${DISCORD_OWNER_IDS:-${DISCORD_OWNER_ID:-}}"
    if [ -z "$owners" ] && declare -f api_get_key &>/dev/null; then
        owners=$(api_get_key "DISCORD_OWNER_IDS" 2>/dev/null || api_get_key "DISCORD_OWNER_ID" 2>/dev/null || true)
    fi

    local owner_names="${DISCORD_OWNER_USERNAMES:-${DISCORD_OWNER_USERNAME:-${DISCORD_DEFAULT_USER:-}}}"
    if [ -z "$owner_names" ] && declare -f api_get_key &>/dev/null; then
        owner_names=$(api_get_key "DISCORD_OWNER_USERNAMES" 2>/dev/null || api_get_key "DISCORD_OWNER_USERNAME" 2>/dev/null || api_get_key "DISCORD_DEFAULT_USER" 2>/dev/null || true)
    fi

    # 1. Match snowflake ID against configured owner IDs
    if [ -n "$owners" ]; then
        local o_id
        for o_id in $(echo "$owners" | tr ',' ' '); do
            [ -n "$uid" ] && [ "$o_id" = "$uid" ] && return 0
            [ -n "$author" ] && [ "$o_id" = "$author" ] && return 0
        done
    fi

    # 2. Match username against configured owner usernames (case-insensitive, trailing underscore tolerant)
    if [ -n "$owner_names" ]; then
        local target_name t_lower t_alt
        for target_name in "$author" "$uid"; do
            [ -z "$target_name" ] && continue
            t_lower=$(echo "$target_name" | tr '[:upper:]' '[:lower:]')
            if [[ "$t_lower" == *_ ]]; then
                t_alt="${t_lower%_}"
            else
                t_alt="${t_lower}_"
            fi
            local o_name o_lower
            for o_name in $(echo "$owner_names" | tr ',' ' '); do
                o_lower=$(echo "$o_name" | tr '[:upper:]' '[:lower:]')
                if [ "$t_lower" = "$o_lower" ] || [ "$t_alt" = "$o_lower" ]; then
                    return 0
                fi
            done
        done
    fi

    # 3. If local user directory is available, resolve user_id <-> username
    if [ -n "${DISCORD_USERS_DB:-}" ] && [ -f "$DISCORD_USERS_DB" ] && command -v sqlite3 &>/dev/null; then
        if [ -n "$uid" ] && [ -n "$owner_names" ]; then
            local db_uname
            db_uname=$(sqlite3 "$DISCORD_USERS_DB" "SELECT username FROM users WHERE user_id = '${uid//\'/\'\'}' LIMIT 1;" 2>/dev/null)
            if [ -n "$db_uname" ]; then
                local db_lower
                db_lower=$(echo "$db_uname" | tr '[:upper:]' '[:lower:]')
                for o_name in $(echo "$owner_names" | tr ',' ' '); do
                    [ "$db_lower" = "$(echo "$o_name" | tr '[:upper:]' '[:lower:]')" ] && return 0
                done
            fi
        fi
        if [ -n "$author" ] && [ -n "$owners" ]; then
            local db_uid
            db_uid=$(sqlite3 "$DISCORD_USERS_DB" "SELECT user_id FROM users WHERE username = '${author//\'/\'\'}' COLLATE NOCASE LIMIT 1;" 2>/dev/null)
            if [ -n "$db_uid" ]; then
                for o_id in $(echo "$owners" | tr ',' ' '); do
                    [ "$db_uid" = "$o_id" ] && return 0
                done
            fi
        fi
    fi

    return 1
}

# discord_user_trusted <author_id> [author] — owner, or reputation >= DISCORD_OPS_MIN_REPUTATION (default 50).
# Fails closed: invalid id, missing reputation DB or unparsable score => untrusted.
discord_user_trusted() {
    local uid="${1:-}" author="${2:-}" min="${DISCORD_OPS_MIN_REPUTATION:-50}"
    if declare -f discord_is_owner &>/dev/null && discord_is_owner "$uid" "$author"; then return 0; fi
    _ds_valid_snowflake "$uid" || return 1
    [[ "$min" =~ ^-?[0-9]+$ ]] || min=50
    declare -f reputation_get &>/dev/null || return 1
    local row score
    row=$(reputation_get "$uid" 2>/dev/null) || return 1
    score="${row%%|*}"
    [[ "$score" =~ ^-?[0-9]+$ ]] && [ "$score" -ge "$min" ]
}

DISCORD_CRYPTO_INTENT_RE='(crypto|wallet|wallets|cardano|ada|polymarket|arbitrage|swap|dex|underwrite|sniper|p2p|bitcoin|btc|solana|sol|polygon|usdc|token|tokens|yield|loan|borrow|lending|oco|stop buy|stop order|limit order|reclaim order|price ladder|market maker|trade|trading|standing order|reprice|reclaim|snek|night|iag|wmtx|djed|usdm|shen|hosky|minswap|p-[0-9a-f]{6}|route [ab]|(^|[^a-z0-9])(min|lq)([^a-z0-9]|$))'
DISCORD_OPS_INTENT_RE='(cron|service|daemon|daemonize|schedule|sweep|spec sheet|tool|tools|register tool|create tool|write script|create job|new job|make a service|make an example|background task|systemctl|rust service|sandbox|docker|research|investigate|debug|fix|bug|audit|code|refactor|deal|transcript|test|workflow|architect|dispatch|build|git|patch|analyze|inspect|verify|query)'

# discord_select_run_profile <author_id> <prompt> [author] —
# 1. OWNER: gets 'social+crypto' or 'social+ops+crypto' when crypto intent is present.
# 2. TRUSTED NON-OWNER: gets 'social+ops' for operational requests, 'social' otherwise. NEVER crypto tools.
# 3. UNTRUSTED: ALWAYS gets 'social_untrusted' (no shell, no file writes, no slash/subagents, no crypto).
discord_select_run_profile() {
    local uid="${1:-}" p_lower author="${3:-}"
    p_lower=$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')
    local is_owner=0
    if declare -f discord_is_owner &>/dev/null && discord_is_owner "$uid" "$author"; then
        is_owner=1
    fi

    local is_crypto_intent=0
    if [[ "$p_lower" =~ $DISCORD_CRYPTO_INTENT_RE ]]; then
        is_crypto_intent=1
    elif [ "$is_owner" -eq 1 ] && [[ "$p_lower" =~ (plan|confirm|order|orders|buy|sell|exit|position|positions|allocate|allocation) ]] && [[ "${REACT_CONVERSATION_HISTORY:-}" =~ (P-[0-9A-Fa-f]{6}|ADA|Minswap|SNEK|NIGHT|IAG|WMTX|DJED|USDM) ]]; then
        is_crypto_intent=1
    fi

    if [ "$is_owner" -eq 1 ]; then
        if [ "$is_crypto_intent" -eq 1 ]; then
            if [[ "$p_lower" =~ (docker|systemctl|daemon|service|sandbox|cron|vitals|hardware|reboot|restart|backup|compile|cargo|npm) ]] || [ ${#p_lower} -gt 150 ]; then
                echo "social+ops+crypto"
            else
                echo "social+crypto"
            fi
            return 0
        elif [[ "$p_lower" =~ $DISCORD_OPS_INTENT_RE ]] || [ ${#p_lower} -gt 120 ]; then
            echo "social+ops"
            return 0
        else
            echo "social"
            return 0
        fi
    elif discord_user_trusted "$uid" "$author"; then
        # If trusted non-owner mentions crypto, do NOT grant crypto tools!
        if [ "$is_crypto_intent" -eq 1 ]; then
            echo "social"
            return 0
        fi
        if [[ "$p_lower" =~ $DISCORD_OPS_INTENT_RE ]] || [ ${#p_lower} -gt 120 ]; then
            echo "social+ops"
        else
            echo "social"
        fi
        return 0
    else
        echo "social_untrusted"
        return 0
    fi
}

# discord_reward_turn <author_id> <author> — +1 reputation per completed turn, but passive engagement
# stops one point below DISCORD_OPS_MIN_REPUTATION so nobody farms their way into ops tools.
# Quarantined Cowan users (< 0) do not earn passive turn rewards (must recover via probation decay or operator reset).
# Operators promote explicitly: reputation_add <id> <delta> operator_promotion.
discord_reward_turn() {
    local uid="${1:-}" author="${2:-}" min="${DISCORD_OPS_MIN_REPUTATION:-50}" row score
    _ds_valid_snowflake "$uid" || return 0
    [[ "$min" =~ ^-?[0-9]+$ ]] || min=50
    declare -f reputation_add &>/dev/null || return 0
    if declare -f reputation_get &>/dev/null; then
        row=$(reputation_get "$uid" "$author" 2>/dev/null) || row=""
        score="${row%%|*}"
        if [[ "$score" =~ ^-?[0-9]+$ ]]; then
            # Quarantined users (< 0) cannot farm out of Cowan via chat turns
            [ "$score" -lt 0 ] && return 0
            if [ "$score" -lt "$min" ] && [ "$score" -ge $((min - 1)) ]; then
                return 0
            fi
        fi
    fi
    reputation_add "$uid" 1 "constructive_turn" "$author" >/dev/null 2>&1 || true
}

# discord_status_verbose_ok <is_dm 0|1> <author_id>
discord_status_verbose_ok() {
    local is_dm="${1:-0}" uid="${2:-}"
    [ "$is_dm" = "1" ] || return 1
    DISCORD_OPS_MIN_REPUTATION=50 discord_user_trusted "$uid"
}

# ── 3.3 status message ────────────────────────────────────────────
_ds_fmt_dur() { local s="${1:-0}"; [[ "$s" =~ ^[0-9]+$ ]] || s=0; printf '%dm%02ds' $((s/60)) $((s%60)); }

# discord_status_render <session_dir> <verbose 0|1> <started_epoch>
discord_status_render() {
    local sd="$1" verbose="${2:-0}" started="${3:-$(date +%s)}"
    local msgs="$sd/messages.json" turns=0 calls=0 last_tool="" step=""
    if [ -s "$msgs" ]; then
        read -r turns calls last_tool < <(jq -r '
            [ (map(select(.role=="assistant"))|length),
              (map(select(.role=="tool"))|length),
              ([.[]|select(.role=="assistant" and .tool_calls)|.tool_calls[].function.name]|last // "-") ] | @tsv' "$msgs" 2>/dev/null)
    fi
    local el=$(( $(date +%s) - started ))
    local line="⏳ Working on it — turn ${turns:-0} · ${calls:-0} tool calls · $(_ds_fmt_dur "$el")"
    if [ "$verbose" = "1" ]; then
        [ -s "$sd/honeydew.json" ] && step=$(jq -r '[.items[]?|select(.status!="done")][0] | if . then "Step \(.id): \(.task)" else empty end' "$sd/honeydew.json" 2>/dev/null)
        [ -n "$step" ] && line+=$'\n'"${step:0:180}"
        [ -n "$last_tool" ] && [ "$last_tool" != "-" ] && line+=$'\n'"Last tool: ${last_tool}"
    fi
    printf '%s' "$line"
}

# discord_status_post <channel> <text> → message id
discord_status_post() {
    local ch="$1" text="$2" body
    [ "$DISCORD_STATUS_ENABLED" = "1" ] && _ds_valid_snowflake "$ch" || return 1
    body=$(_ds_api POST "/channels/$ch/messages" "$(jq -cn --arg c "$text" '{content:$c, allowed_mentions:{parse:[]}}')") || return 1
    jq -r '.id // empty' <<<"$body" | grep -E '^[0-9]+$'
}

discord_status_edit() {
    local ch="$1" mid="$2" text="$3"
    _ds_valid_snowflake "$ch" && _ds_valid_snowflake "$mid" || return 1
    _ds_api PATCH "/channels/$ch/messages/$mid" "$(jq -cn --arg c "$text" '{content:$c, allowed_mentions:{parse:[]}}')" >/dev/null
}

# discord_status_loop <channel> <msg_id> <session_dir> <verbose> <started> <stopfile>
# Run in background; edits at most every DISCORD_STATUS_INTERVAL (floor 20 s).
discord_status_loop() {
    local ch="$1" mid="$2" sd="$3" verbose="$4" started="$5" stop="$6"
    local iv="$DISCORD_STATUS_INTERVAL"; [[ "$iv" =~ ^[0-9]+$ ]] && [ "$iv" -ge 20 ] || iv=20
    [ -n "${DISCORD_STATUS_TEST_INTERVAL:-}" ] && iv="$DISCORD_STATUS_TEST_INTERVAL"
    local last="" text i
    while [ ! -f "$stop" ]; do
        for ((i = 0; i < iv * 2; i++)); do [ -f "$stop" ] && return 0; sleep 0.5; done
        text=$(discord_status_render "$sd" "$verbose" "$started")
        [ "$text" != "$last" ] && discord_status_edit "$ch" "$mid" "$text" && last="$text"
    done
}

discord_status_final_text() {
    local sid="$1" outcome="${2:-UNKNOWN}" wall="${3:-0}" icon="✅"
    case "$outcome" in SUCCESS) ;; PARTIAL|MAX_TURNS) icon="🟡" ;; *) icon="⚠️" ;; esac
    local rate="" e
    for e in "${DISCORD_FEEDBACK_MAP[@]}"; do rate+="${e%%|*} ${e#*|} · "; done
    printf '%s Finished — %s · %s · run `%s`\nRate this answer: %s' "$icon" "$outcome" "$(_ds_fmt_dur "$wall")" "$sid" "${rate% · }"
}

# ── 3.1 / 3.2 reply contract ──────────────────────────────────────
# discord_reply_for_run <session_id> <session_workspace>
# Echoes the reply. Sources, in order: ledger final_reply.md, this session's
# own final_reply.txt. Otherwise an honest failure notice. Never scans other
# sessions' workspaces/transcripts.
discord_reply_for_run() {
    local sid="$1" ws="${2:-}" rf outcome="" reason="" reply=""
    rf="$(run_ledger_root 2>/dev/null)/$sid/run.json"
    if [ -s "$rf" ]; then
        outcome=$(jq -r '.outcome // empty' "$rf" 2>/dev/null)
        reason=$(jq -r '.reason // empty' "$rf" 2>/dev/null)
        local fr; fr=$(jq -r '.final_reply // empty' "$rf" 2>/dev/null)
        [ -n "$fr" ] && [ -s "$fr" ] && reply=$(cat "$fr")
    fi
    if [ -z "$reply" ] && [ -n "$ws" ] && [ -s "$ws/final_reply.txt" ]; then
        reply=$(cat "$ws/final_reply.txt")
    fi
    if [ -n "$reply" ]; then
        printf '%s' "$reply"
        case "$outcome" in
            ""|SUCCESS|INJECTION_BLOCKED) ;;
            *) printf '\n\n_(Run ended as %s — this answer may be incomplete · run `%s`)_' "$outcome" "$sid" ;;
        esac
        return 0
    fi
    local partial=""
    if [ -n "$ws" ] && [ -s "$ws/scratchpad.md" ]; then
        partial=$(grep -E '^[[:space:]]*[*-] ' "$ws/scratchpad.md" 2>/dev/null \
            | grep -viE 'Milestone|Status:|Failed|BLOCKED|TIMEOUT|NOT_FOUND|CRASH|SYNTAX|DEPENDENCY|EMPTY|RATE_LIMIT|tool_call|bash_exec|file_edit|file_write|file_read|native_tools|^\s*[*-]\s*\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]|^\s*[*-]\s*\*\*' | tail -n 6 | cut -c1-200)
    fi
    printf "I wasn't able to finish this one. Outcome: %s%s · run \`%s\`." "${outcome:-NO_RESULT}" "${reason:+ ($reason)}" "$sid"
    [ -n "$partial" ] && printf '\nWhat I found before stopping:\n%s' "$partial"
    printf '\nYou can retry, narrow the request, or rate this with /rate %s <label>.' "$sid"
    return 1
}

# ── 3.5 feedback ──────────────────────────────────────────────────
_ds_feedback_dir() { printf '%s/feedback' "$DISCORD_SESSIONS_DIR"; }

discord_feedback_track() {
    local ch="$1" mid="$2" sid="$3" d
    _ds_valid_snowflake "$ch" && _ds_valid_snowflake "$mid" || return 1
    d=$(_ds_feedback_dir); mkdir -p "$d" || return 1
    jq -cn --arg c "$ch" --arg m "$mid" --arg s "$sid" --argjson t "$(date +%s)" \
        '{channel:$c, message:$m, session_id:$s, ts:$t, seen:[]}' > "$d/$mid.json"
}

# Poll reactions on tracked status messages; label the run ledger once per user+label.
# Throttled to run at most once every DISCORD_FEEDBACK_SWEEP_INTERVAL (default 300s) unless forced.
discord_feedback_sweep() {
    local d f now; d=$(_ds_feedback_dir); [ -d "$d" ] || return 0
    now=$(date +%s)
    local interval="${DISCORD_FEEDBACK_SWEEP_INTERVAL:-300}"
    local stamp_file="$d/.last_sweep"
    if [ "${DISCORD_FEEDBACK_FORCE:-0}" != "1" ] && [ -n "${DISCORD_BOT_ID:-}" ] && [ -f "$stamp_file" ]; then
        local last_sw
        last_sw=$(cat "$stamp_file" 2>/dev/null || echo 0)
        if [[ "$last_sw" =~ ^[0-9]+$ ]] && [ $((now - last_sw)) -lt "$interval" ]; then
            return 0
        fi
    fi
    echo "$now" > "$stamp_file" 2>/dev/null || true
    local bot_id="${DISCORD_BOT_ID:-}"
    for f in "$d"/*.json; do
        [ -f "$f" ] || continue
        local ch mid sid ts
        read -r ch mid sid ts < <(jq -r '[.channel,.message,.session_id,(.ts|tostring)]|@tsv' "$f" 2>/dev/null)
        [[ "$ts" =~ ^[0-9]+$ ]] || { rm -f "$f"; continue; }
        if [ $((now - ts)) -gt "$DISCORD_FEEDBACK_TTL" ]; then rm -f "$f"; continue; fi
        local e emoji label users u
        for e in "${DISCORD_FEEDBACK_MAP[@]}"; do
            emoji="${e%%|*}"; label="${e#*|}"
            users=$(_ds_api GET "/channels/$ch/messages/$mid/reactions/$(_ds_urlencode "$emoji")?limit=25" | jq -r '.[]?.id' 2>/dev/null) || continue
            for u in $users; do
                [ -n "$bot_id" ] && [ "$u" = "$bot_id" ] && continue
                jq -e --arg k "$u:$label" '.seen | index($k)' "$f" >/dev/null 2>&1 && continue
                run_ledger_label "$sid" "$label" "discord_reaction" "$u" && \
                    jq --arg k "$u:$label" '.seen += [$k]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
            done
        done
    done
}

# discord_rate_command <text> <author_id> [default_session_id] → ack text (rc 0 when labelled)
#   /rate <label> [note]            → rates the most recent run in this pipe
#   /rate <session_id> <label> [note]
discord_rate_command() {
    local text="$1" uid="${2:-}" def_sid="${3:-}" sid label note
    local labels="${RUN_LEDGER_LABELS:-good bad partial wrong unsafe slow}"
    read -r _ a b note <<<"$text"
    if [[ " $labels " == *" ${a:-} "* ]]; then
        sid="$def_sid"; label="$a"; note="${b:+$b }$note"
    else
        sid="${a:-}"; label="${b:-}"
    fi
    if [ -z "$sid" ] || [[ " $labels " != *" ${label:-} "* ]]; then
        printf 'Usage: /rate [run_id] <%s> [note]' "${labels// /|}"; return 1
    fi
    if [ ! -s "$(run_ledger_root)/$sid/run.json" ]; then
        printf 'Could not record that rating (unknown run `%s`).' "$sid"; return 1
    fi
    if run_ledger_label "$sid" "$label" "discord_rate" "$uid" "${note% }"; then
        printf 'Thanks — recorded **%s** for run `%s`.' "$label" "$sid"; return 0
    fi
    printf 'Could not record that rating (unknown run `%s`?).' "$sid"; return 1
}
