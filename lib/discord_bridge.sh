#!/bin/bash
# ── George: Autonomic Discord Bridge & Interactive Chat Service ──
# Connects George to the Discord Bot API. Handles:
#   1. Inbound Direct Messages & Channel @Mentions.
#   2. Interactive live chat sessions with a 120-second inactivity watchdog.
#   3. Multipart file & image uploads to Discord channels/DMs.
#   4. Inbound image downloading into .george/discord_media/ for vision analysis.
#   5. Autonomic sweep integration via cron and sentinel.
#
# State:   .george/discord_sessions/
# Media:   .george/discord_media/
# Track:   .george/discord_sessions/last_seen.json

[ -n "${_LIB_DISCORD_BRIDGE_LOADED:-}" ] && return 0; _LIB_DISCORD_BRIDGE_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
DISCORD_SESSIONS_DIR="${DISCORD_SESSIONS_DIR:-$GEORGE_DIR/discord_sessions}"
DISCORD_MEDIA_DIR="${DISCORD_MEDIA_DIR:-$GEORGE_DIR/discord_media}"
DISCORD_HISTORY_DIR="${DISCORD_HISTORY_DIR:-$DISCORD_SESSIONS_DIR/history}"
DISCORD_LAST_SEEN_FILE="${DISCORD_LAST_SEEN_FILE:-$DISCORD_SESSIONS_DIR/last_seen.json}"
DISCORD_KNOWN_DMS_FILE="${DISCORD_KNOWN_DMS_FILE:-$DISCORD_SESSIONS_DIR/known_dms.json}"
DISCORD_BRIDGE_LOG="${DISCORD_BRIDGE_LOG:-$DISCORD_SESSIONS_DIR/bridge.log}"

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/api.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/social.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/react.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/reputation.sh" 2>/dev/null || true

discord_bridge_init() {
    mkdir -p "$DISCORD_SESSIONS_DIR" "$DISCORD_MEDIA_DIR" "$DISCORD_HISTORY_DIR" 2>/dev/null
    if [ ! -f "$DISCORD_LAST_SEEN_FILE" ]; then
        mkdir -p "$(dirname "$DISCORD_LAST_SEEN_FILE")" 2>/dev/null || true
        echo '{"channels":{}}' > "$DISCORD_LAST_SEEN_FILE" 2>/dev/null || true
    fi
    if [ ! -f "$DISCORD_KNOWN_DMS_FILE" ]; then
        mkdir -p "$(dirname "$DISCORD_KNOWN_DMS_FILE")" 2>/dev/null || true
        echo '{}' > "$DISCORD_KNOWN_DMS_FILE" 2>/dev/null || true
    fi
}

# ── 1. Discord Multipart File & Image Upload ─────────────────────────
# Transmits an image or file attachment to a Discord channel or DM.
# Supports PNG, JPG, WEBP, GIF, PDF, TXT, etc.
discord_send_file() {
    local channel_id="$1"
    local file_path="$2"
    local message="${3:-}"

    if [ -z "$channel_id" ] || [ -z "$file_path" ]; then
        ui_err "Usage: discord_send_file <channel_or_user> <file_path> [message]"
        return 1
    fi

    local token
    token=$(api_require_key "DISCORD_BOT_TOKEN" "Discord Bot") || return 1

    local target_ch=""
    if [[ "$channel_id" =~ ^[0-9]+$ ]]; then
        # Check if numeric target is channel or user
        local is_chan is_usr
        is_chan=$(sqlite3 "${DISCORD_CHANNELS_DB:-$GEORGE_DIR/discord_channels.db}" "SELECT 1 FROM channels WHERE channel_id = '$channel_id' LIMIT 1;" 2>/dev/null || true)
        if [ -z "$is_chan" ]; then
            is_usr=$(sqlite3 "${DISCORD_USERS_DB:-$GEORGE_DIR/discord_users.db}" "SELECT 1 FROM users WHERE user_id = '$channel_id' LIMIT 1;" 2>/dev/null || true)
            if [ -n "$is_usr" ]; then
                local dm_resp
                dm_resp=$(curl -s -X POST "https://discord.com/api/v10/users/@me/channels" \
                    -H "Authorization: Bot $token" \
                    -H "Content-Type: application/json" \
                    -d "{\"recipient_id\":\"$channel_id\"}" 2>/dev/null)
                target_ch=$(echo "$dm_resp" | jq -r .id 2>/dev/null)
            fi
        fi
        [ -z "$target_ch" ] && target_ch="$channel_id"
    else
        # Try resolving as channel name
        target_ch=$(discord_channel_resolve "$channel_id" 2>/dev/null || true)
        if [ -z "$target_ch" ]; then
            # Try resolving as username
            local u_id
            u_id=$(discord_user_resolve "$channel_id" 2>/dev/null || true)
            if [ -n "$u_id" ]; then
                local dm_resp
                dm_resp=$(curl -s -X POST "https://discord.com/api/v10/users/@me/channels" \
                    -H "Authorization: Bot $token" \
                    -H "Content-Type: application/json" \
                    -d "{\"recipient_id\":\"$u_id\"}" 2>/dev/null)
                target_ch=$(echo "$dm_resp" | jq -r .id 2>/dev/null)
            fi
        fi
    fi

    if [ -z "$target_ch" ] || [ "$target_ch" = "null" ]; then
        ui_err "Could not resolve Discord target: '$channel_id'"
        return 1
    fi
    channel_id="$target_ch"

    if [ ! -f "$file_path" ]; then
        ui_err "Attachment file does not exist: $file_path"
        return 1
    fi

    local bname
    bname=$(basename "$file_path")
    ui_info "Uploading attachment '$bname' to Discord channel $channel_id..."

    local payload_json
    payload_json=$(jq -n --arg msg "$message" '{content: $msg}')

    local resp http_status
    resp=$(curl -s -w "\n%{http_code}" -X POST "https://discord.com/api/v10/channels/$channel_id/messages" \
        -H "Authorization: Bot $token" \
        -F "payload_json=$payload_json" \
        -F "files[0]=@$file_path;filename=$bname" 2>/dev/null)

    http_status=$(echo "$resp" | tail -n 1)
    local body
    body=$(echo "$resp" | sed '$d')

    if [ "$http_status" = "200" ] || [ "$http_status" = "201" ]; then
        local msg_id
        msg_id=$(echo "$body" | jq -r .id 2>/dev/null)
        ui_ok "Uploaded '$bname' to Discord (Message ID: $msg_id)"
        echo "$body"
        return 0
    else
        local err_msg
        err_msg=$(echo "$body" | jq -r .message 2>/dev/null || echo "$body")
        ui_err "Discord file upload failed (HTTP $http_status): $err_msg"
        return 1
    fi
}

# ── 2. Download Inbound Discord Attachments ──────────────────────────
# Extracts and downloads image attachments from a Discord message JSON.
# Returns newline-separated list of downloaded local file paths.
discord_download_attachments() {
    local msg_json="$1"
    local channel_id="${2:-shared}"

    discord_bridge_init

    local attachments
    attachments=$(echo "$msg_json" | jq -c '.attachments[]? // empty' 2>/dev/null || true)
    [ -z "$attachments" ] && return 0

    local downloaded=()

    while read -r att; do
        [ -z "$att" ] && continue
        local att_url att_fname att_id
        att_url=$(echo "$att" | jq -r '.url // empty')
        att_fname=$(echo "$att" | jq -r '.filename // "attachment.bin"')
        att_id=$(echo "$att" | jq -r '.id // "0"')

        [ -z "$att_url" ] && continue

        local safe_fname
        safe_fname=$(echo -n "$att_fname" | sed 's/[^a-zA-Z0-9._-]/_/g')
        local local_target="$DISCORD_MEDIA_DIR/${channel_id}_${att_id}_${safe_fname}"

        if [ ! -f "$local_target" ]; then
            if curl -sL -m 30 "$att_url" -o "$local_target" 2>/dev/null; then
                downloaded+=("$local_target")
                ui_ok "Downloaded inbound Discord media: $safe_fname" >&2
            fi
        else
            downloaded+=("$local_target")
        fi
    done <<< "$attachments"

    if [ ${#downloaded[@]} -gt 0 ]; then
        printf '%s\n' "${downloaded[@]}"
    fi
}

# ── 3. Discord Typing Indicator & Continuous Heartbeat Pulse ─────────
discord_typing_start() {
    local channel_id="$1"
    local token
    token=$(api_get_key "DISCORD_BOT_TOKEN" 2>/dev/null)
    [ -z "$token" ] && return 0
    curl -s -X POST "https://discord.com/api/v10/channels/$channel_id/typing" \
        -H "Authorization: Bot $token" </dev/null >/dev/null 2>&1 || true
}

discord_typing_pulse_start() {
    local channel_id="$1"
    local token
    token=$(api_get_key "DISCORD_BOT_TOKEN" 2>/dev/null)
    [ -z "$token" ] && return 0

    (
        while true; do
            curl -s -X POST "https://discord.com/api/v10/channels/$channel_id/typing" \
                -H "Authorization: Bot $token" </dev/null >/dev/null 2>&1 || true
            sleep 6
        done
    ) </dev/null >/dev/null 2>&1 &
    local ppid=$!
    echo "$ppid"
}

discord_typing_pulse_stop() {
    local pid="$1"
    if [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null; then
        pkill -P "$pid" 2>/dev/null || true
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        sleep 0.05
    fi
}

# ── 4. Multi-Turn Conversational History Buffer ──────────────────────
discord_history_get() {
    local channel_id="$1"
    local max_turns="${2:-6}"
    local hfile="$DISCORD_HISTORY_DIR/history_${channel_id}.json"

    [ ! -f "$hfile" ] && return 0

    local hist
    hist=$(jq -r --argjson n "$max_turns" '
        .[-$n:]? | .[]? |
        (if .role == "user" then "@" + .author + ": " else "George: " end) +
        (.content | gsub("\n"; " ") | if length > 300 then .[0:297] + "..." else . end)
    ' "$hfile" 2>/dev/null || true)

    if [ -n "$hist" ]; then
        printf "[Recent Conversation Context]:\n%s\n" "$hist"
    fi
}

discord_history_append() {
    local channel_id="$1"
    local role="$2"
    local author="$3"
    local content="$4"
    local hfile="$DISCORD_HISTORY_DIR/history_${channel_id}.json"

    mkdir -p "$DISCORD_HISTORY_DIR" 2>/dev/null || true
    if [ ! -f "$hfile" ]; then
        echo "[]" > "$hfile"
    fi

    local now
    now=$(date +%s)
    local updated
    updated=$(jq --arg r "$role" --arg a "$author" --arg c "$content" --argjson t "$now" \
        '. + [{"role": $r, "author": $a, "content": $c, "timestamp": $t}] | .[-12:]' \
        "$hfile" 2>/dev/null || cat "$hfile")

    echo "$updated" > "$hfile"
}

discord_history_clear() {
    local channel_id="$1"
    rm -f "$DISCORD_HISTORY_DIR/history_${channel_id}.json" 2>/dev/null || true
}

# ── 5. Desktop Live Session Monitor Launcher ─────────────────────────
discord_launch_visual_monitor() {
    local channel_id="$1"
    local author="$2"
    local session_log="$3"

    if ! command -v wt.exe &>/dev/null || [ -z "${WSL_DISTRO_NAME:-}" ]; then
        return 0
    fi

    # Clean up any stale or lingering monitor processes for this channel
    local existing_mon
    existing_mon=$(pgrep -f "scripts/discord_live_monitor.sh $channel_id" 2>/dev/null || true)
    if [ -n "$existing_mon" ]; then
        kill $existing_mon 2>/dev/null || true
        sleep 0.2
    fi

    local distro="${WSL_DISTRO_NAME:-ubuntu-local}"
    local size="${CRON_POPUP_SIZE:-110,32}"

    wt.exe -w new --size "$size" \
        nt --title "George Discord Live - @$author" \
        wsl.exe -d "$distro" --cd "$LODGE_DIR" \
        bash ./scripts/discord_live_monitor.sh "$channel_id" "$author" "$session_log" 2>/dev/null &
}

# ── 6. Process Message Turn with George ──────────────────────────────
discord_generate_response() {
    local prompt="$1"
    local channel_id="$2"
    local author="$3"
    local attachment_files="${4:-}"
    local session_log="${5:-}"
    local author_id="${6:-}"
    local out_reply_file="${7:-}"

    # Check if this is an explicit score / standing inquiry
    local score_query_pat='(what.*(score|rank|standing|privilege|reputation)|my score|my rank|my standing|my reputation|who am i to george|am i worthy)'
    local p_lower
    p_lower=$(echo "$prompt" | tr '[:upper:]' '[:lower:]')
    if [[ "$p_lower" =~ $score_query_pat ]] && declare -f reputation_format_status &>/dev/null; then
        local rep_reply
        rep_reply=$(reputation_format_status "${author_id:-$author}" "$author")
        if [ -n "$session_log" ]; then
            printf "[%s] ── Answering reputation inquiry directly from Judgment Ledger.\n" "$(date '+%H:%M:%S')" >> "$session_log"
        fi
        [ -n "$out_reply_file" ] && printf '%s\n' "$rep_reply" > "$out_reply_file"
        echo "$rep_reply"
        discord_history_append "$channel_id" "user" "$author" "$prompt"
        discord_history_append "$channel_id" "assistant" "George" "$rep_reply"
        return 0
    fi

    # Build prompt with history
    local hist_ctx
    hist_ctx=$(discord_history_get "$channel_id" 6)

    local full_prompt=""
    if [ -n "$hist_ctx" ]; then
        full_prompt="${hist_ctx}\n\n[Current Inbound Message from @${author}]:\n${prompt}"
    else
        full_prompt="$prompt"
    fi

    if [ -n "$attachment_files" ]; then
        full_prompt+="\n[Inbound User Attachments downloaded locally to: $attachment_files. You can inspect them using vision_analyze, or upload files/images back using discord_send_file or [IMAGE: /path/to/image].]"
    fi

    if [ -n "$session_log" ]; then
        printf "[%s] ── Starting ReAct reasoning turn with George...\n" "$(date '+%H:%M:%S')" >> "$session_log"
    fi

    # Invoke ReAct engine with 'social' profile (web, social, memory, vision, bedrock)
    local session_uuid
    session_uuid="discord_${channel_id}_$(date +%s)"
    local session_out_dir="$DISCORD_SESSIONS_DIR/$session_uuid"
    mkdir -p "$session_out_dir" 2>/dev/null

    local discord_max_turns="${DISCORD_AGENT_MAX_TURNS:-200}"
    local reply=""
    if declare -f react_run &>/dev/null; then
        local raw_out_file="$session_out_dir/raw_react.log"
        if [ -n "$session_log" ]; then
            react_run "$full_prompt" "$LODGE_DIR" "$discord_max_turns" 1 "$session_uuid" "social" 2>&1 | tee -a "$session_log" > "$raw_out_file" || true
        else
            react_run "$full_prompt" "$LODGE_DIR" "$discord_max_turns" 1 "$session_uuid" "social" 2>&1 > "$raw_out_file" || true
        fi

        # 1. Primary: Extract from isolated session workspace
        local session_workspace="$LODGE_DIR/.george/workspaces/$session_uuid"
        local session_final="$session_workspace/final_reply.txt"
        local session_json="$session_workspace/messages.json"

        if [ -f "$session_final" ] && [ -s "$session_final" ]; then
            reply=$(cat "$session_final")
        elif [ -f "$session_json" ]; then
            reply=$(jq -r '[.[] | select(.role == "assistant" and .content != null and .content != "")] | last | .content // empty' "$session_json" 2>/dev/null || true)
        fi

        # 2. Fallback: Extract from session-isolated raw output log
        if [ -z "$reply" ] && [ -f "$raw_out_file" ]; then
            local raw_out
            raw_out=$(cat "$raw_out_file")
            local cleaned
            cleaned=$(printf '%s\n' "$raw_out" | sed -r 's/\x1B\[[0-9;]*[a-zA-Z]//g')
            if echo "$cleaned" | grep -q "Task Complete!"; then
                reply=$(echo "$cleaned" | awk '
                    /── Turn / { block="" }
                    /\[thought\]/ { in_thought=1 }
                    /\[observation\]|Observation:/ { in_thought=0; block="" }
                    /Task Complete!/ { in_ans=0; print block; exit }
                    !in_thought && !/Task Complete!|Transcript:|── Turn/ { block = block "\n" $0 }
                ' | sed '/^[[:space:]]*$/d')
                [ -z "$reply" ] && reply=$(echo "$cleaned" | awk '/Task Complete!/{flag=1; next} /Transcript:/{flag=0} flag' | sed '/^[[:space:]]*$/d' | head -n 50)
            fi
        fi
    fi

    # Fallback to direct agent ask if react_run did not emit a string
    if [ -z "$reply" ]; then
        reply="Hello @${author}, George is here. I have cataloged your inquiry: '${prompt}'. Our sovereign tools are active."
    fi

    # Record turn in persistent history buffer
    discord_history_append "$channel_id" "user" "$author" "$prompt"
    discord_history_append "$channel_id" "assistant" "George" "$reply"

    # Reward constructive engagement on the Square
    if declare -f reputation_add &>/dev/null && [ -n "$author_id" ]; then
        reputation_add "$author_id" 1 "constructive_turn" "$author" >/dev/null 2>&1 || true
    fi

    if [ -n "$session_log" ]; then
        printf "[%s] ── Reasoning turn completed.\n" "$(date '+%H:%M:%S')" >> "$session_log"
    fi

    [ -n "$out_reply_file" ] && printf '%s\n' "$reply" > "$out_reply_file"
    echo "$reply"
}

# ── 7. Interactive Chat Session Pipe with 120s Inactivity Timeout ─────
discord_chat_session() {
    local channel_id="$1"
    local initial_msg="$2"
    local author="$3"
    local initial_msg_id="$4"
    local is_dm="${5:-1}"
    local initial_attachments="${6:-}"
    local author_id="${7:-}"

    discord_bridge_init

    local pid_file="$DISCORD_SESSIONS_DIR/session_${channel_id}.pid"
    echo "${BASHPID:-$$}" > "$pid_file"
    local pulse_pid=""
    cleanup_session() {
        rm -f "$pid_file" 2>/dev/null || true
        [ -n "$pulse_pid" ] && discord_typing_pulse_stop "$pulse_pid"
        if [ -f "$session_log" ] && ! grep -q "\[SESSION_CLOSED\]" "$session_log"; then
            printf "\n[%s] [SESSION_CLOSED] Session ended.\n" "$(date '+%H:%M:%S')" >> "$session_log"
        fi
    }
    trap cleanup_session EXIT INT TERM

    local token
    token=$(api_require_key "DISCORD_BOT_TOKEN" "Discord Bot") || return 1

    local bot_id
    bot_id=$(curl -s "https://discord.com/api/v10/users/@me" -H "Authorization: Bot $token" 2>/dev/null | jq -r .id)

    local session_log="$DISCORD_SESSIONS_DIR/session_${channel_id}.log"
    printf "==========================================================\n" > "$session_log"
    printf "  George Live Discord Session with @%s\n" "$author" >> "$session_log"
    printf "  Channel: %s | Started: %s\n" "$channel_id" "$(date '+%Y-%m-%d %H:%M:%S')" >> "$session_log"
    printf "==========================================================\n\n" >> "$session_log"

    ui_step "Entering interactive live Discord pipe in channel $channel_id with @$author (120s timeout)..."
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Live chat started with @$author in $channel_id" >> "$DISCORD_BRIDGE_LOG"

    # Launch live desktop visual monitor
    discord_launch_visual_monitor "$channel_id" "$author" "$session_log"

    # 1. Process Initial Inbound Turn
    printf "[%s] [Inbound from @%s]: %s\n" "$(date '+%H:%M:%S')" "$author" "$initial_msg" >> "$session_log"
    pulse_pid=$(discord_typing_pulse_start "$channel_id")

    local reply_tmp="$DISCORD_SESSIONS_DIR/turn_init_${channel_id}.txt"
    rm -f "$reply_tmp" 2>/dev/null
    discord_generate_response "$initial_msg" "$channel_id" "$author" "$initial_attachments" "$session_log" "$author_id" "$reply_tmp"
    local first_reply=""
    [ -f "$reply_tmp" ] && first_reply=$(cat "$reply_tmp")
    rm -f "$reply_tmp" 2>/dev/null

    discord_typing_pulse_stop "$pulse_pid"
    pulse_pid=""

    # Format reply with mention if in a public channel
    local final_first_reply="$first_reply"
    if [ "$is_dm" -eq 0 ]; then
        local tag_prefix=""
        if [ -n "$author_id" ] && [[ "$author_id" =~ ^[0-9]+$ ]]; then
            tag_prefix="<@${author_id}> "
        else
            tag_prefix="@${author} "
        fi
        if [[ "$final_first_reply" != *"$tag_prefix"* && "$final_first_reply" != *"@$author"* ]]; then
            final_first_reply="${tag_prefix}${final_first_reply}"
        fi
    fi

    # Send response back to Discord
    if [ -n "$final_first_reply" ]; then
        discord_send "$channel_id" "$final_first_reply" >/dev/null 2>&1
        ui_ok "Dispatched initial reply to @$author in $channel_id"
        printf "[%s] [George Response]:\n%s\n\n" "$(date '+%H:%M:%S')" "$final_first_reply" >> "$session_log"
    fi

    local last_seen_id="$initial_msg_id"
    local last_active_ts
    last_active_ts=$(date +%s)

    # 2. Inactivity Watchdog & Live Monitoring Loop
    while true; do
        sleep 2.5
        local now
        now=$(date +%s)

        # Check 120s Inactivity Timeout
        local elapsed=$((now - last_active_ts))
        if [ "$elapsed" -ge 120 ]; then
            ui_info "Discord chat session with @$author in $channel_id timed out after ${elapsed}s of inactivity."
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Session timed out (120s inactivity) in $channel_id" >> "$DISCORD_BRIDGE_LOG"
            printf "\n[%s] [SESSION_CLOSED] Inactivity timeout reached (%ds).\n" "$(date '+%H:%M:%S')" "$elapsed" >> "$session_log"
            break
        fi

        # Poll for new messages from user in this channel
        local raw_msgs
        raw_msgs=$(curl -s "https://discord.com/api/v10/channels/$channel_id/messages?limit=3" -H "Authorization: Bot $token" 2>/dev/null)
        [ -z "$raw_msgs" ] && continue

        local new_user_msg
        new_user_msg=$(echo "$raw_msgs" | jq -c --arg bid "$bot_id" --arg lid "$last_seen_id" '
            [.[]? | select(.author.id != $bid and (.id > $lid))] | last // empty
        ' 2>/dev/null || true)

        if [ -n "$new_user_msg" ]; then
            local n_id n_content n_author n_author_id
            n_id=$(echo "$new_user_msg" | jq -r .id)
            n_content=$(echo "$new_user_msg" | jq -r .content)
            n_author=$(echo "$new_user_msg" | jq -r .author.username)
            n_author_id=$(echo "$new_user_msg" | jq -r .author.id)

            last_seen_id="$n_id"
            # Keep last_seen.json synchronized with every turn processed in the session
            if [ -f "$DISCORD_LAST_SEEN_FILE" ]; then
                local lsd
                lsd=$(cat "$DISCORD_LAST_SEEN_FILE" 2>/dev/null || echo '{"channels":{}}')
                lsd=$(echo "$lsd" | jq --arg cid "$channel_id" --arg mid "$n_id" '.channels[$cid] = $mid' 2>/dev/null || true)
                [ -n "$lsd" ] && echo "$lsd" > "$DISCORD_LAST_SEEN_FILE"
            fi

            ui_info "Inbound Discord message from @$n_author: $n_content"
            printf "[%s] [Inbound from @%s]: %s\n" "$(date '+%H:%M:%S')" "$n_author" "$n_content" >> "$session_log"

            local pulse_pid_turn=""
            pulse_pid_turn=$(discord_typing_pulse_start "$channel_id")

            # Download any attached media
            local n_attachments
            n_attachments=$(discord_download_attachments "$new_user_msg" "$channel_id")

            # Generate reply
            local turn_reply_tmp="$DISCORD_SESSIONS_DIR/turn_${n_id}_${channel_id}.txt"
            rm -f "$turn_reply_tmp" 2>/dev/null
            discord_generate_response "$n_content" "$channel_id" "$n_author" "$n_attachments" "$session_log" "$n_author_id" "$turn_reply_tmp"
            local reply=""
            [ -f "$turn_reply_tmp" ] && reply=$(cat "$turn_reply_tmp")
            rm -f "$turn_reply_tmp" 2>/dev/null

            discord_typing_pulse_stop "$pulse_pid_turn"
            pulse_pid_turn=""

            local final_reply="$reply"
            if [ "$is_dm" -eq 0 ]; then
                local tag_prefix=""
                if [ -n "$n_author_id" ] && [[ "$n_author_id" =~ ^[0-9]+$ ]]; then
                    tag_prefix="<@${n_author_id}> "
                else
                    tag_prefix="@${n_author} "
                fi
                if [[ "$final_reply" != *"$tag_prefix"* && "$final_reply" != *"@$n_author"* ]]; then
                    final_reply="${tag_prefix}${final_reply}"
                fi
            fi

            # Check if reply instructs an image upload
            if [[ "$final_reply" == *"[IMAGE:"* ]]; then
                local img_to_send
                img_to_send=$(echo "$final_reply" | grep -o '\[IMAGE: [^]]*\]' | head -n 1 | sed 's/\[IMAGE: //;s/\]//')
                local clean_reply
                clean_reply=$(echo "$final_reply" | sed 's/\[IMAGE: [^]]*\]//')
                if [ -f "$img_to_send" ]; then
                    discord_send_file "$channel_id" "$img_to_send" "$clean_reply" >/dev/null 2>&1
                else
                    discord_send "$channel_id" "$final_reply" >/dev/null 2>&1
                fi
            else
                discord_send "$channel_id" "$final_reply" >/dev/null 2>&1
            fi
            ui_ok "Dispatched reply to @$n_author"
            printf "[%s] [George Response]:\n%s\n\n" "$(date '+%H:%M:%S')" "$final_reply" >> "$session_log"

            # Reset inactivity timer AFTER dispatching reply so operator gets full window
            last_active_ts=$(date +%s)
        fi
    done
}

# ── 8. Discord Ingress Sweeper ───────────────────────────────────────
# Sweeps DMs and channel @mentions. Dispatches interactive session on hit.
discord_bridge_sweep() {
    discord_bridge_init

    local token
    token=$(api_get_key "DISCORD_BOT_TOKEN" 2>/dev/null)
    if [ -z "$token" ]; then
        ui_dim "  Discord Bridge: DISCORD_BOT_TOKEN not configured."
        return 0
    fi

    local me_resp
    me_resp=$(curl -s "https://discord.com/api/v10/users/@me" -H "Authorization: Bot $token" 2>/dev/null)
    local bot_id bot_name
    bot_id=$(echo "$me_resp" | jq -r .id 2>/dev/null)
    bot_name=$(echo "$me_resp" | jq -r .username 2>/dev/null)
    if [ -z "$bot_id" ] || [ "$bot_id" = "null" ]; then
        ui_dim "  Discord Bridge: Authentication failed."
        return 0
    fi

    ui_step "Sweeping Discord for incoming DMs and @${bot_name} mentions..."

    local last_seen_data
    last_seen_data=$(cat "$DISCORD_LAST_SEEN_FILE" 2>/dev/null || echo '{"channels":{}}')

    # A. Sweep Known Direct Message Channels
    if [ -f "$DISCORD_KNOWN_DMS_FILE" ]; then
        local dm_channels
        dm_channels=$(jq -r 'to_entries[] | .value' "$DISCORD_KNOWN_DMS_FILE" 2>/dev/null || true)
        for dm_ch_id in $dm_channels; do
            [ -z "$dm_ch_id" ] && continue
            local dm_msgs
            dm_msgs=$(curl -s "https://discord.com/api/v10/channels/$dm_ch_id/messages?limit=3" -H "Authorization: Bot $token" 2>/dev/null)
            local last_seen
            last_seen=$(echo "$last_seen_data" | jq -r --arg cid "$dm_ch_id" '.channels[$cid] // "0"')

            local pending_msg
            pending_msg=$(echo "$dm_msgs" | jq -c --arg bid "$bot_id" --arg lseen "$last_seen" '
                [.[]? | select(.author.id != $bid and (.id > $lseen))] | last // empty
            ' 2>/dev/null || true)

            if [ -n "$pending_msg" ]; then
                local p_id p_content p_author p_author_id
                p_id=$(echo "$pending_msg" | jq -r .id)
                p_content=$(echo "$pending_msg" | jq -r .content)
                p_author=$(echo "$pending_msg" | jq -r .author.username)
                p_author_id=$(echo "$pending_msg" | jq -r .author.id)

                # Check if session already actively running for this channel
                local pid_file="$DISCORD_SESSIONS_DIR/session_${dm_ch_id}.pid"
                if [ -f "$pid_file" ]; then
                    local cur_pid
                    cur_pid=$(cat "$pid_file" 2>/dev/null)
                    if [ -n "$cur_pid" ] && kill -0 "$cur_pid" 2>/dev/null; then
                        continue
                    fi
                fi

                # Update last seen before entering session
                last_seen_data=$(echo "$last_seen_data" | jq --arg cid "$dm_ch_id" --arg mid "$p_id" '.channels[$cid] = $mid')
                echo "$last_seen_data" > "$DISCORD_LAST_SEEN_FILE"

                local attachments
                attachments=$(discord_download_attachments "$pending_msg" "$dm_ch_id")

                ui_info "Direct Message from @$p_author: $p_content"
                ( discord_chat_session "$dm_ch_id" "$p_content" "$p_author" "$p_id" 1 "$attachments" "$p_author_id" ) >> "$DISCORD_BRIDGE_LOG" 2>&1 &
                echo "$!" > "$pid_file"
                continue
            fi
        done
    fi

    # B. Sweep Public Channels for @Mentions
    local channels_db="${DISCORD_CHANNELS_DB:-$GEORGE_DIR/discord_channels.db}"
    if [ -f "$channels_db" ]; then
        local ch_list
        ch_list=$(sqlite3 "$channels_db" "SELECT name, channel_id FROM channels LIMIT 15;" 2>/dev/null || true)
        while IFS='|' read -r ch_name ch_id; do
            [ -z "$ch_id" ] && continue
            local ch_msgs
            ch_msgs=$(curl -s "https://discord.com/api/v10/channels/$ch_id/messages?limit=3" -H "Authorization: Bot $token" 2>/dev/null)
            local last_seen
            last_seen=$(echo "$last_seen_data" | jq -r --arg cid "$ch_id" '.channels[$cid] // "0"')

            local pending_mention
            pending_mention=$(echo "$ch_msgs" | jq -c --arg bid "$bot_id" --arg lseen "$last_seen" '
                . as $root |
                (($root[0].author.id != $bid) and ($root[1]?.author.id == $bid)) as $direct_followup |
                [$root[] | select(.author.id != $bid and (.id > $lseen) and (
                    (.content | contains("<@" + $bid + ">") or contains("<@!" + $bid + ">") or test("@george|<@&"; "i")) or ($direct_followup and .id == $root[0].id)
                ))] | last // empty
            ' 2>/dev/null || true)

            if [ -n "$pending_mention" ]; then
                local m_id m_content m_author m_author_id
                m_id=$(echo "$pending_mention" | jq -r .id)
                m_content=$(echo "$pending_mention" | jq -r .content)
                m_author=$(echo "$pending_mention" | jq -r .author.username)
                m_author_id=$(echo "$pending_mention" | jq -r .author.id)

                # Check if session already actively running for this channel
                local pid_file="$DISCORD_SESSIONS_DIR/session_${ch_id}.pid"
                if [ -f "$pid_file" ]; then
                    local cur_pid
                    cur_pid=$(cat "$pid_file" 2>/dev/null)
                    if [ -n "$cur_pid" ] && kill -0 "$cur_pid" 2>/dev/null; then
                        continue
                    fi
                fi

                # Clean mention and role tags from prompt
                m_content=$(echo "$m_content" | sed -E "s/<@!?[0-9]+>//g; s/<@&[0-9]+>//g; s/^@[Gg]eorge\b//g" | sed 's/^[[:space:]]*//')

                last_seen_data=$(echo "$last_seen_data" | jq --arg cid "$ch_id" --arg mid "$m_id" '.channels[$cid] = $mid')
                echo "$last_seen_data" > "$DISCORD_LAST_SEEN_FILE"

                local attachments
                attachments=$(discord_download_attachments "$pending_mention" "$ch_id")

                ui_info "Mention in #$ch_name from @$m_author: $m_content"
                ( discord_chat_session "$ch_id" "$m_content" "$m_author" "$m_id" 0 "$attachments" "$m_author_id" ) >> "$DISCORD_BRIDGE_LOG" 2>&1 &
                echo "$!" > "$pid_file"
                continue
            fi
        done <<< "$ch_list"
    fi

    ui_dim "  No new DMs or @mentions found across Discord channels."
    return 0
}
