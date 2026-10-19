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

pid_file="$LODGE_DIR/.george/discord_sessions/session_${channel_id}.pid"
dead_checks=0
no_pid_checks=0

# Stream the session log until SESSION_CLOSED (follow across truncations with -F)
tail -n +1 -F "$session_log" 2>/dev/null | while true; do
    if IFS= read -r -t 4 line; then
        echo "$line"
        dead_checks=0
        no_pid_checks=0
        if [[ "$line" == *"[SESSION_CLOSED]"* ]]; then
            pkill -P $$ tail 2>/dev/null || true
            break
        fi
    else
        # Periodic liveness check when no output is flowing
        if [ -f "$pid_file" ]; then
            spid=$(cat "$pid_file" 2>/dev/null)
            if [ -n "$spid" ] && ! kill -0 "$spid" 2>/dev/null; then
                dead_checks=$((dead_checks + 1))
                if [ "$dead_checks" -ge 3 ]; then
                    echo ""
                    echo "⚠ Session process ($spid) ended."
                    pkill -P $$ tail 2>/dev/null || true
                    break
                fi
            else
                dead_checks=0
            fi
        elif [ ! -f "$pid_file" ] && [ -f "$session_log" ]; then
            no_pid_checks=$((no_pid_checks + 1))
            if [ "$no_pid_checks" -ge 4 ]; then
                echo ""
                echo "⚠ Session ended."
                pkill -P $$ tail 2>/dev/null || true
                break
            fi
        fi
    fi
done

printf "\n\033[1;32m✓ Discord live session closed.\033[0m\n"
echo ""
read -t 30 -r -p "[Press Enter to dismiss (auto-closing in 30s)] " _dummy || true
