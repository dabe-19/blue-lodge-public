#!/bin/bash
# ── George: Autonomous Deep Research Live Companion HUD ──────────────
# Displays real-time research inquiry phases, turns, arXiv document
# extractions, mathematical formulas, and long-form dossier synthesis.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
topic="${1:-Autonomous Research}"
slug="${2:-research}"
sandbox_dir="${3:-}"

if [ -z "$sandbox_dir" ] || [ ! -d "$sandbox_dir" ]; then
    # Try finding the most recent research sandbox
    latest_sb=$(find "$LODGE_DIR/.sandboxes" -maxdepth 1 -name "research_*" -type d 2>/dev/null | sort -r | head -n 1)
    if [ -n "$latest_sb" ]; then
        sandbox_dir="$latest_sb"
    else
        echo "Error: Research sandbox directory not found."
        read -t 10 -r -p "[Press Enter to dismiss] " _dummy || true
        exit 1
    fi
fi

clear
printf "\033[1;34m╭────────────────────────────────────────────────────────────────────────────╮\033[0m\n"
printf "\033[1;34m│\033[0m \033[1;37mGeorge Autonomous Research HUD — Deep Scholarly Oversight\033[0m                 \033[1;34m│\033[0m\n"
printf "\033[1;34m│\033[0m Topic:   \033[1;33m%-66.66s\033[0m \033[1;34m│\033[0m\n" "$topic"
printf "\033[1;34m│\033[0m Sandbox: \033[1;36m%-66.66s\033[0m \033[1;34m│\033[0m\n" "$(basename "$sandbox_dir")"
printf "\033[1;34m╰────────────────────────────────────────────────────────────────────────────╯\033[0m\n\n"

# Locate active trajectory log or workspace
ws_dir=$(find "$sandbox_dir/.george/workspaces" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)
traj_log=""
if [ -n "$ws_dir" ] && [ -f "$ws_dir/trajectory.log" ]; then
    traj_log="$ws_dir/trajectory.log"
fi

current_phase=""
dead_checks=0

# Stream loop
while true; do
    # Check for phase updates
    if [ -f "$sandbox_dir/.phase" ]; then
        new_phase=$(cat "$sandbox_dir/.phase" 2>/dev/null)
        if [ "$new_phase" != "$current_phase" ]; then
            current_phase="$new_phase"
            printf "\033[1;35m>>> [RESEARCH STAGE] %s\033[0m\n" "$current_phase"
        fi
    fi

    # Check for scratchpad reference count
    if [ -f "$sandbox_dir/scratchpad.md" ]; then
        ref_count=$(grep -E -c '#### (Reference|Source)' "$sandbox_dir/scratchpad.md" 2>/dev/null || true)
        pdf_count=$(find "$sandbox_dir" -maxdepth 2 -name "*.pdf" 2>/dev/null | wc -l)
    fi

    # Locate trajectory log if newly created
    if [ -z "$traj_log" ]; then
        ws_dir=$(find "$sandbox_dir/.george/workspaces" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)
        if [ -n "$ws_dir" ] && [ -f "$ws_dir/trajectory.log" ]; then
            traj_log="$ws_dir/trajectory.log"
            printf "\033[1;32m[Trajectory connected: %s]\033[0m\n" "$(basename "$ws_dir")"
        fi
    fi

    # Check for completion marker
    if [ -f "$sandbox_dir/dossier.md" ] && [ -f "$sandbox_dir/.done" ]; then
        printf "\n\033[1;32m✓ Autonomous Deep Research Complete!\033[0m\n"
        printf "\033[1;37mFinal Dossier: %s/dossier.md\033[0m\n" "$sandbox_dir"
        printf "\033[2mVerified References: %s | PDFs Harvested: %s\033[0m\n\n" "${ref_count:-0}" "${pdf_count:-0}"
        break
    fi

    # Check if research publisher process is dead
    if ! pgrep -f "research_publisher.sh" &>/dev/null && ! pgrep -f "$sandbox_dir" &>/dev/null; then
        dead_checks=$((dead_checks + 1))
        if [ "$dead_checks" -ge 6 ]; then
            printf "\n\033[1;33m⚠ Research process concluded.\033[0m\n"
            if [ -f "$sandbox_dir/dossier.md" ]; then
                printf "\033[1;32m✓ Dossier generated successfully: %s/dossier.md\033[0m\n" "$sandbox_dir"
            fi
            break
        fi
    else
        dead_checks=0
    fi

    sleep 1.5
done &
mon_pid=$!

# Stream recent trajectory log if available
if [ -n "$traj_log" ]; then
    tail -n 40 -F "$traj_log" 2>/dev/null &
    tail_pid=$!
else
    # Follow any newly appearing trajectory log
    (
        while [ ! -f "$traj_log" ]; do
            sleep 1
            ws_dir=$(find "$sandbox_dir/.george/workspaces" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)
            [ -n "$ws_dir" ] && [ -f "$ws_dir/trajectory.log" ] && traj_log="$ws_dir/trajectory.log"
        done
        tail -n 40 -F "$traj_log" 2>/dev/null
    ) &
    tail_pid=$!
fi

# Wait for monitor to conclude
wait $mon_pid 2>/dev/null
kill $tail_pid 2>/dev/null || true

printf "\n\033[1;34m────────────────────────────────────────────────────────────────────────────\033[0m\n"
printf "\033[2mResearch session ended. Press any key or close window.\033[0m\n"
read -t 30 -r -s _dummy || true
exit 0
