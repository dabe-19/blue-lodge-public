#!/bin/bash
# ── George: Sovereign Autonomous Remediation Live Monitor ─────────────
# Displays real-time execution turns, thoughts, tool actions, and test
# verification for autonomous remediation on Slot 1. Launched via wt.exe.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
task_id="$1"
title="${2:-Autonomous Remediation}"
log_file="${3:-$LODGE_DIR/.george/remediation/logs/${task_id}.log}"

# Wait up to 5s for log file to appear
for _ in {1..20}; do
    [ -f "$log_file" ] && break
    sleep 0.25
done

clear
printf "\033[1;35m╭────────────────────────────────────────────────────────────────────────────╮\033[0m\n"
printf "\033[1;35m│\033[0m \033[1;37mGeorge Sovereign Remediation HUD — Live Operator Oversight\033[0m                 \033[1;35m│\033[0m\n"
printf "\033[1;35m│\033[0m Task: \033[1;33m%-25s\033[0m Slot: \033[1;32mSlot 1 (Isolated Worktree)\033[0m        \033[1;35m│\033[0m\n" "$task_id"
printf "\033[1;35m│\033[0m Goal: \033[1;36m%-66.66s\033[0m \033[1;35m│\033[0m\n" "$title"
printf "\033[1;35m╰────────────────────────────────────────────────────────────────────────────╯\033[0m\n\n"

if [ ! -f "$log_file" ]; then
    echo "Awaiting remediation task initialization..."
fi

lock_file="$LODGE_DIR/.george/remediation/.lock"
dead_checks=0
no_lock_checks=0

# Stream the remediation log until completion
tail -n +1 -F "$log_file" 2>/dev/null | while true; do
    if IFS= read -r -t 4 line; then
        echo "$line"
        dead_checks=0
        no_lock_checks=0
        if [[ "$line" == *"[REMEDIATION_COMPLETE]"* ]] || [[ "$line" == *"[REMEDIATION_FAILED]"* ]]; then
            pkill -P $$ tail 2>/dev/null || true
            break
        fi
    else
        # Periodic liveness check when no output is flowing
        if [ -f "$lock_file" ]; then
            rpid=$(cat "$lock_file" 2>/dev/null)
            if [ -n "$rpid" ] && ! kill -0 "$rpid" 2>/dev/null; then
                dead_checks=$((dead_checks + 1))
                if [ "$dead_checks" -ge 3 ]; then
                    echo ""
                    echo "⚠ Remediation process ($rpid) ended."
                    pkill -P $$ tail 2>/dev/null || true
                    break
                fi
            else
                dead_checks=0
            fi
        elif [ ! -f "$lock_file" ] && [ -f "$log_file" ]; then
            no_lock_checks=$((no_lock_checks + 1))
            if [ "$no_lock_checks" -ge 4 ]; then
                echo ""
                echo "⚠ Remediation task completed."
                pkill -P $$ tail 2>/dev/null || true
                break
            fi
        fi
    fi
done

printf "\n\033[1;35m────────────────────────────────────────────────────────────────────────────\033[0m\n"
printf "\033[2mRemediation session ended. Press any key or close window.\033[0m\n"
read -r -n 1 -s -t 15 2>/dev/null || true
