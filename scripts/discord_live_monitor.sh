#!/bin/bash
# ── George: Live Discord Companion & Session Monitor ─────────────────
# Displays real-time conversation turns, thoughts, and replies during
# interactive Discord sessions. Launched via Windows Terminal (wt.exe).

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
channel_id="$1"
author="${2:-user}"
session_log="${3:-$LODGE_DIR/.george/discord_sessions/session_${channel_id}.log}"

# Wait up to 5s for session log to appear
for _ in {1..20}; do
    [ -f "$session_log" ] && break
    sleep 0.25
done

clear
printf "\033[1;36m╭──────────────────────────────────────────────────────────────╮\033[0m\n"
printf "\033[1;36m│\033[0m \033[1;37mGeorge Discord Companion — Live Operator Monitor\033[0m            \033[1;36m│\033[0m\n"
printf "\033[1;36m│\033[0m Chatter: \033[1;33m@%-15s\033[0m Channel: \033[1;35m%-22s\033[0m \033[1;36m│\033[0m\n" "$author" "$channel_id"
printf "\033[1;36m╰──────────────────────────────────────────────────────────────╯\033[0m\n\n"

if [ ! -f "$session_log" ]; then
    echo "Awaiting session initialization..."
fi

# Stream the session log until SESSION_CLOSED (follow across truncations with -F)
tail -n +1 -F "$session_log" 2>/dev/null | while IFS= read -r line; do
    echo "$line"
    if [[ "$line" == *"[SESSION_CLOSED]"* ]]; then
        pkill -P $$ tail 2>/dev/null || true
        break
    fi
done

printf "\n\033[1;32m✓ Discord live session closed.\033[0m\n"
echo ""
read -r -p "[Press Enter to dismiss] " _dummy
