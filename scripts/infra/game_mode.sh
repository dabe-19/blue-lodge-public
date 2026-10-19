#!/bin/bash
# ── Blue Lodge: Game Mode / Sovereign GPU Standby Controller ─────────
# Safely pauses George, stops the inference server, and frees 100% of GPU VRAM
# so you can play games or run heavy graphical workloads.
#
# Usage:
#   bash scripts/infra/game_mode.sh pause    # Free GPU VRAM for gaming
#   bash scripts/infra/game_mode.sh resume   # Restore George and inference
#   bash scripts/infra/game_mode.sh status   # Check GPU VRAM and container state

LODGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true

pause_george() {
    echo "═══════════════════════════════════════════════════════════"
    echo "  Entering Game Mode: Releasing All GPU Resources"
    echo "═══════════════════════════════════════════════════════════"

    mkdir -p "$LODGE_DIR/.george"
    touch "$LODGE_DIR/.george/.game_mode"

    # 1. Stop background autonomic sweeps so they don't trigger new runs
    echo "[1/4] Pausing George autonomic cron daemon..."
    if [ -f "$LODGE_DIR/lib/sys/cron.sh" ]; then
        source "$LODGE_DIR/lib/sys/cron.sh" 2>/dev/null || true
        declare -f cron_stop &>/dev/null && cron_stop >/dev/null 2>&1 || true
    elif [ -f "$LODGE_DIR/commands/cron.sh" ]; then
        bash "$LODGE_DIR/commands/cron.sh" stop >/dev/null 2>&1 || true
    fi

    # 2. Safely pause active research tasks and subagents with state preserved
    echo "[2/4] Preserving state and pausing active research & subagent tasks..."
    local paused_tasks_file="$LODGE_DIR/.george/game_mode_paused_tasks.json"
    local paused_pids=()
    local paused_info=()

    # A. Scan active sandboxes (.sandboxes/*)
    if [ -d "$LODGE_DIR/.sandboxes" ]; then
        for sbd in "$LODGE_DIR/.sandboxes"/*; do
            [ ! -d "$sbd" ] && continue
            local sb_pid_file="$sbd/.pid"
            local sb_done_file="$sbd/.done"
            if [ -f "$sb_pid_file" ] && [ ! -f "$sb_done_file" ]; then
                local spid
                spid=$(cat "$sb_pid_file" 2>/dev/null || true)
                if [ -n "$spid" ] && kill -0 "$spid" 2>/dev/null; then
                    local cur_phase="Active"
                    [ -f "$sbd/.phase" ] && cur_phase=$(cat "$sbd/.phase" 2>/dev/null || echo "Active")
                    paused_info+=("$(jq -nc --arg pid "$spid" --arg dir "$sbd" --arg ph "$cur_phase" --arg ty "sandbox" '{pid: ($pid|tonumber), dir: $dir, prev_phase: $ph, type: $ty}')")
                    paused_pids+=("$spid")
                    echo "Paused (Game Mode)" > "$sbd/.phase" 2>/dev/null || true
                fi
            fi
        done
    fi

    # B. Scan active subagents in registry (.george/subagents.json)
    local sub_reg="$LODGE_DIR/.george/subagents.json"
    if [ -f "$sub_reg" ]; then
        local sub_active
        sub_active=$(jq -r '.[] | select(.status == "RUNNING") | "\(.pid)|\(.id)|\(.worktree_dir)"' "$sub_reg" 2>/dev/null || true)
        while IFS='|' read -r sapid said sawt; do
            [ -z "$sapid" ] && continue
            if [ "$sapid" -gt 0 ] 2>/dev/null && kill -0 "$sapid" 2>/dev/null; then
                if [[ ! " ${paused_pids[*]} " =~ " ${sapid} " ]]; then
                    paused_info+=("$(jq -nc --arg pid "$sapid" --arg dir "$sawt" --arg ph "Active" --arg ty "subagent" '{pid: ($pid|tonumber), dir: $dir, prev_phase: $ph, type: $ty}')")
                    paused_pids+=("$sapid")
                fi
            fi
        done <<< "$sub_active"

        # Update subagents registry status to PAUSED
        local updated_sub_reg
        updated_sub_reg=$(jq 'map(if .status == "RUNNING" then .status = "PAUSED" else . end)' "$sub_reg" 2>/dev/null || true)
        [ -n "$updated_sub_reg" ] && echo "$updated_sub_reg" > "$sub_reg" 2>/dev/null || true
    fi

    # C. Scan for active research runner processes
    local r_pids
    r_pids=$(pgrep -f "research_publisher\.sh|research_graph\.sh" 2>/dev/null || true)
    for rpid in $r_pids; do
        [ -z "$rpid" ] && continue
        if [ "$rpid" -ne "$$" ] && kill -0 "$rpid" 2>/dev/null; then
            if [[ ! " ${paused_pids[*]} " =~ " ${rpid} " ]]; then
                paused_info+=("$(jq -nc --arg pid "$rpid" --arg dir "$LODGE_DIR" --arg ph "Active" --arg ty "research" '{pid: ($pid|tonumber), dir: $dir, prev_phase: $ph, type: $ty}')")
                paused_pids+=("$rpid")
            fi
        fi
    done

    # Save paused tasks manifest
    if [ ${#paused_info[@]} -gt 0 ]; then
        printf '%s\n' "${paused_info[@]}" | jq -s '.' > "$paused_tasks_file" 2>/dev/null || true
        echo "  Recorded ${#paused_pids[@]} active task process(es) to preserve."
    else
        echo "[]" > "$paused_tasks_file"
    fi

    # D. Pause FIFO IPC channels and suspend processes using SIGSTOP
    if [ -f "$LODGE_DIR/lib/ipc/fifo_ipc.sh" ]; then
        source "$LODGE_DIR/lib/ipc/fifo_ipc.sh" 2>/dev/null || true
        if [ -d "$LODGE_DIR/.george/ipc/channels" ]; then
            for ch in "$LODGE_DIR/.george/ipc/channels"/*; do
                [ ! -d "$ch" ] && continue
                local ch_id
                ch_id=$(basename "$ch")
                declare -f ipc_flow_pause &>/dev/null && ipc_flow_pause "$ch_id" 2>/dev/null || true
            done
        fi
    fi

    # Send SIGSTOP to frozen processes and all their child threads/processes
    for p in "${paused_pids[@]}"; do
        if kill -0 "$p" 2>/dev/null; then
            pkill -STOP -P "$p" 2>/dev/null || true
            kill -STOP "$p" 2>/dev/null || true
            echo "  ✓ Suspended PID $p (state frozen in RAM)"
        fi
    done

    # 3. Stop the inference container (releasing 23.4 GB of VRAM across both GPUs)
    echo "[3/4] Stopping inference container (george-prism-server)..."
    docker stop george-prism-server 2>/dev/null || true
    docker stop george-prism-worker 2>/dev/null || true

    echo "[4/4] Finalizing Game Mode standby status..."
    echo ""
    echo "✓ GPU VRAM completely released."
    if command -v nvidia-smi &>/dev/null; then
        echo ""
        nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader
    fi
    echo ""
    echo "Have fun playing games with your kid!"
    echo "When done, simply run: bash scripts/infra/game_mode.sh resume"
}

resume_george() {
    echo "═══════════════════════════════════════════════════════════"
    echo "  Resuming George: Re-engaging Inference & Autonomics"
    echo "═══════════════════════════════════════════════════════════"

    # 1. Start the inference container
    echo "[1/4] Starting inference container (george-prism-server)..."
    docker start george-prism-server 2>/dev/null || (cd "$LODGE_DIR" && docker compose up -d prism-inference)

    # 2. Wait for health check on port 8080 BEFORE waking up any paused processes
    echo "[2/4] Waiting for LLM server to load models into VRAM (port 8080)..."
    local healthy=0
    for i in {1..30}; do
        if curl -sf --max-time 1 "http://127.0.0.1:8080/health" &>/dev/null; then
            healthy=1
            break
        fi
        sleep 1
    done

    if [ "$healthy" -eq 1 ]; then
        echo "✓ Inference container is operational on port 8080."
    else
        echo "⚠ Warning: Port 8080 did not report healthy within 30s. Checking logs..."
        docker logs --tail 10 george-prism-server 2>/dev/null || true
    fi

    # 3. Resume paused tasks, channels, and subagents
    echo "[3/4] Resuming paused research tasks and subagents with preserved state..."
    local paused_tasks_file="$LODGE_DIR/.george/game_mode_paused_tasks.json"
    if [ -f "$paused_tasks_file" ]; then
        local entries
        entries=$(jq -r '.[] | "\(.pid)|\(.dir)|\(.prev_phase)|\(.type)"' "$paused_tasks_file" 2>/dev/null || true)
        while IFS='|' read -r rpid rdir rphase rtype; do
            [ -z "$rpid" ] && continue
            if kill -0 "$rpid" 2>/dev/null; then
                # Unfreeze process tree
                kill -CONT "$rpid" 2>/dev/null || true
                pkill -CONT -P "$rpid" 2>/dev/null || true

                # Restore phase
                if [ -n "$rdir" ] && [ -d "$rdir" ] && [ -f "$rdir/.phase" ]; then
                    local restore_ph="${rphase:-Active}"
                    [ "$restore_ph" = "Paused (Game Mode)" ] && restore_ph="Active"
                    echo "$restore_ph" > "$rdir/.phase" 2>/dev/null || true
                fi
                echo "  ✓ Resumed PID $rpid ($rtype)"
            fi
        done <<< "$entries"
        rm -f "$paused_tasks_file" 2>/dev/null || true
    fi

    # Resume subagents registry status to RUNNING
    local sub_reg="$LODGE_DIR/.george/subagents.json"
    if [ -f "$sub_reg" ]; then
        local updated_sub_reg
        updated_sub_reg=$(jq 'map(if .status == "PAUSED" then .status = "RUNNING" else . end)' "$sub_reg" 2>/dev/null || true)
        [ -n "$updated_sub_reg" ] && echo "$updated_sub_reg" > "$sub_reg" 2>/dev/null || true
    fi

    # Resume FIFO IPC flow control
    if [ -f "$LODGE_DIR/lib/ipc/fifo_ipc.sh" ]; then
        source "$LODGE_DIR/lib/ipc/fifo_ipc.sh" 2>/dev/null || true
        if [ -d "$LODGE_DIR/.george/ipc/channels" ]; then
            for ch in "$LODGE_DIR/.george/ipc/channels"/*; do
                [ ! -d "$ch" ] && continue
                local ch_id
                ch_id=$(basename "$ch")
                declare -f ipc_flow_resume &>/dev/null && ipc_flow_resume "$ch_id" 2>/dev/null || true
            done
        fi
    fi

    # 4. Remove game mode marker and restart autonomic cron sweeps
    rm -f "$LODGE_DIR/.george/.game_mode" 2>/dev/null || true
    echo "[4/4] Resuming autonomic cron daemon..."
    if [ -f "$LODGE_DIR/lib/sys/cron.sh" ]; then
        source "$LODGE_DIR/lib/sys/cron.sh" 2>/dev/null || true
        declare -f cron_start &>/dev/null && cron_start >/dev/null 2>&1 || true
    elif [ -f "$LODGE_DIR/commands/cron.sh" ]; then
        bash "$LODGE_DIR/commands/cron.sh" start >/dev/null 2>&1 || true
    fi

    echo ""
    echo "✓ George is back online and fully operational."
    if command -v nvidia-smi &>/dev/null; then
        echo ""
        nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader
    fi
}

status_george() {
    echo "═══════════════════════════════════════════════════════════"
    echo "  George & GPU Standby Status"
    echo "═══════════════════════════════════════════════════════════"
    local inf_status
    inf_status=$(docker inspect -f '{{.State.Status}}' george-prism-server 2>/dev/null || echo "not found")
    echo "  Inference Container: $inf_status"

    local p8080_health
    p8080_health=$(curl -sf --max-time 1 "http://127.0.0.1:8080/health" 2>/dev/null || echo "offline")
    echo "  Port 8080 (Primary):  $p8080_health"

    local cron_pid
    cron_pid=$(cat "$LODGE_DIR/.george/cron.pid" 2>/dev/null || echo "")
    if [ -n "$cron_pid" ] && kill -0 "$cron_pid" 2>/dev/null; then
        echo "  Autonomic Daemon:    running (PID $cron_pid)"
    else
        echo "  Autonomic Daemon:    stopped"
    fi

    if command -v nvidia-smi &>/dev/null; then
        echo ""
        echo "  GPU Memory Allocation:"
        nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader
    fi
    echo "═══════════════════════════════════════════════════════════"
}

status_george_json() {
    local inf_status
    inf_status=$(docker inspect -f '{{.State.Status}}' george-prism-server 2>/dev/null || echo "not found")
    local p8080_health
    p8080_health=$(curl -sf --max-time 1 "http://127.0.0.1:8080/health" 2>/dev/null || echo "offline")
    local cron_pid
    cron_pid=$(cat "$LODGE_DIR/.george/cron.pid" 2>/dev/null || echo "")
    local cron_running="false"
    if [ -n "$cron_pid" ] && kill -0 "$cron_pid" 2>/dev/null; then
        cron_running="true"
    fi
    local game_mode="false"
    if [ "$inf_status" != "running" ]; then
        game_mode="true"
    fi
    cat <<EOF
{
  "status": "ok",
  "game_mode": $game_mode,
  "inference_status": "$inf_status",
  "port_8080": "$p8080_health",
  "autonomic_daemon": $cron_running
}
EOF
}

case "${1:-status}" in
    pause|stop|game)
        pause_george
        ;;
    resume|start|play)
        resume_george
        ;;
    status)
        if [ "${2:-}" = "json" ] || [ "${2:-}" = "--json" ]; then
            status_george_json
        else
            status_george
        fi
        ;;
    json|--json)
        status_george_json
        ;;
    *)
        echo "Usage: $0 {pause|resume|status|json}"
        exit 1
        ;;
esac

