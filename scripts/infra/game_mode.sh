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
GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"
K8S_NS="${K8S_NAMESPACE:-blue-lodge}"
K8S_INF_DEPLOY="${K8S_INFERENCE_DEPLOY:-george-inference}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true

_gm_k8s_available() {
    command -v kubectl &>/dev/null && kubectl -n "$K8S_NS" get deploy "$K8S_INF_DEPLOY" &>/dev/null
}

_gm_health_url() {
    if [ -n "${KUBERNETES_SERVICE_HOST:-}" ]; then
        echo "http://${K8S_INF_DEPLOY}:8080/health"
    elif [ -n "${LLAMA_CPP_URL:-}" ]; then
        echo "${LLAMA_CPP_URL%/}/health"
    else
        echo "http://127.0.0.1:8080/health"
    fi
}

_gm_probe_inference() {
    # Sets GM_BACKEND ("k8s"|"docker"), GM_REPLICAS ("1/1"|""), GM_INF_STATUS, GM_HEALTH
    GM_BACKEND="docker"
    GM_REPLICAS=""
    GM_INF_STATUS="not found"
    local hurl
    hurl=$(_gm_health_url)
    GM_HEALTH=$(curl -sf --max-time 2 "$hurl" 2>/dev/null || echo "offline")

    if _gm_k8s_available; then
        GM_BACKEND="k8s"
        local spec_rep ready_rep
        spec_rep=$(kubectl -n "$K8S_NS" get deploy "$K8S_INF_DEPLOY" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
        ready_rep=$(kubectl -n "$K8S_NS" get deploy "$K8S_INF_DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        spec_rep="${spec_rep:-0}"
        ready_rep="${ready_rep:-0}"
        GM_REPLICAS="${ready_rep}/${spec_rep}"
        if [ "$spec_rep" -eq 0 ] 2>/dev/null; then
            GM_INF_STATUS="paused"
        elif [ "$ready_rep" -ge 1 ] 2>/dev/null; then
            GM_INF_STATUS="running"
            if [ "$GM_HEALTH" = "offline" ]; then
                # Host-side fallback: probe inside pod if localhost:8080 isn't port-forwarded
                local pod_h
                pod_h=$(kubectl -n "$K8S_NS" exec "deploy/$K8S_INF_DEPLOY" -- curl -sf --max-time 2 http://127.0.0.1:8080/health 2>/dev/null || echo "")
                [ -n "$pod_h" ] && GM_HEALTH="$pod_h"
            fi
        else
            GM_INF_STATUS="starting"
        fi
    else
        GM_INF_STATUS=$(docker inspect -f '{{.State.Status}}' george-prism-server 2>/dev/null || echo "not found")
        if [ "$GM_INF_STATUS" != "running" ] && [ "$GM_HEALTH" != "offline" ]; then
            GM_INF_STATUS="running"
        fi
    fi
}

pause_george() {
    echo "═══════════════════════════════════════════════════════════"
    echo "  Entering Game Mode: Releasing All GPU Resources"
    echo "═══════════════════════════════════════════════════════════"

    mkdir -p "$LODGE_DIR/.george"
    touch "$LODGE_DIR/.george/.game_mode"

    # 1. Switch autonomic cron daemon into Game Mode Standby (skips GPU/LLM sweeps,
    #    keeps zero-GPU crypto corridor watchers like pool_recorder & cardano_order_poll alive)
    echo "[1/4] Switching George autonomic cron daemon to Game Mode Standby (zero-GPU crypto watchers stay live)..."
    if [ -f "$LODGE_DIR/lib/sys/cron.sh" ]; then
        source "$LODGE_DIR/lib/sys/cron.sh" 2>/dev/null || true
        declare -f cron_sweep_stale_daemons &>/dev/null && cron_sweep_stale_daemons >/dev/null 2>&1 || true
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

    # C. Scan for active research, LLM cron, and SDR ingest runner processes
    local r_pids
    r_pids=$(pgrep -f "research_publisher\.sh|research_graph\.sh|trading_reporter\.sh|music_research\.sh|health_insurance_intel\.sh|meme_report\.sh|sdr_ingest\.py" 2>/dev/null || true)
    for rpid in $r_pids; do
        [ -z "$rpid" ] && continue
        if [ "$rpid" -ne "$$" ] && kill -0 "$rpid" 2>/dev/null; then
            if [[ ! " ${paused_pids[*]} " =~ " ${rpid} " ]]; then
                paused_info+=("$(jq -nc --arg pid "$rpid" --arg dir "$LODGE_DIR" --arg ph "Active" --arg ty "background_worker" '{pid: ($pid|tonumber), dir: $dir, prev_phase: $ph, type: $ty}')")
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

    # 3. Stop/scale down inference (releasing 100% of GPU VRAM while keeping george-web, MQTT, SearXNG & zero-GPU crons alive)
    echo "[3/4] Releasing GPU VRAM (k3s deploy/$K8S_INF_DEPLOY / docker inference)..."
    if _gm_k8s_available; then
        local cur_rep
        cur_rep=$(kubectl -n "$K8S_NS" get deploy "$K8S_INF_DEPLOY" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        [ "${cur_rep:-0}" -gt 0 ] 2>/dev/null && printf '%s\n' "$cur_rep" > "$GEORGE_DIR/game_mode_k8s_replicas"
        kubectl -n "$K8S_NS" scale "deploy/$K8S_INF_DEPLOY" --replicas=0 2>/dev/null || true
        echo "  Waiting for k3s inference pod ($K8S_INF_DEPLOY) to terminate and release GPU VRAM..."
        kubectl -n "$K8S_NS" wait --for=delete pod -l "app=$K8S_INF_DEPLOY" --timeout=45s >/dev/null 2>&1 || true
        echo "  ✓ k3s deploy/$K8S_INF_DEPLOY scaled to 0 (george-web & support services remain online)"
    fi
    docker stop george-prism-server 2>/dev/null || true
    docker stop george-prism-worker 2>/dev/null || true

    # Drop Linux VM page cache & compact memory so ~30 GB of mmap'd .gguf pages return to Windows host RAM
    sync 2>/dev/null || true
    if [ -w /proc/sys/vm/drop_caches ]; then
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        [ -w /proc/sys/vm/compact_memory ] && echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
    elif command -v docker &>/dev/null; then
        timeout 5 docker run --rm --privileged --entrypoint sh eclipse-mosquitto:latest -c 'sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; echo 1 > /proc/sys/vm/compact_memory 2>/dev/null' >/dev/null 2>&1 || true
    fi

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

    # 1. Restore inference (k3s deployment or Docker container)
    echo "[1/4] Restoring inference (k3s deploy/$K8S_INF_DEPLOY / docker inference)..."
    local _health_url
    _health_url=$(_gm_health_url)
    local _is_k8s=0
    if _gm_k8s_available; then
        _is_k8s=1
        local target_rep=1
        if [ -f "$GEORGE_DIR/game_mode_k8s_replicas" ]; then
            local saved_rep
            saved_rep=$(cat "$GEORGE_DIR/game_mode_k8s_replicas" 2>/dev/null || echo "1")
            [[ "$saved_rep" =~ ^[1-9][0-9]*$ ]] && target_rep="$saved_rep"
            rm -f "$GEORGE_DIR/game_mode_k8s_replicas" 2>/dev/null || true
        fi
        kubectl -n "$K8S_NS" scale "deploy/$K8S_INF_DEPLOY" --replicas="$target_rep" 2>/dev/null || true
        echo "  Waiting for k3s deploy/$K8S_INF_DEPLOY rollout (replicas=$target_rep)..."
        kubectl -n "$K8S_NS" rollout status "deploy/$K8S_INF_DEPLOY" --timeout=120s 2>/dev/null || true
    else
        docker start george-prism-server 2>/dev/null || (cd "$LODGE_DIR" && docker compose up -d prism-inference)
    fi

    # 2. Wait for health check on port 8080 BEFORE waking up any paused processes
    echo "[2/4] Waiting for LLM server to load model weights into VRAM..."
    local healthy=0
    for i in $(seq 1 90); do
        if curl -sf --max-time 2 "$_health_url" &>/dev/null; then
            healthy=1
            break
        fi
        if [ "$_is_k8s" -eq 1 ] && [ -z "${KUBERNETES_SERVICE_HOST:-}" ]; then
            if kubectl -n "$K8S_NS" exec "deploy/$K8S_INF_DEPLOY" -- curl -sf --max-time 2 http://127.0.0.1:8080/health &>/dev/null; then
                healthy=1
                break
            fi
        fi
        sleep 1
    done

    if [ "$healthy" -eq 1 ]; then
        echo "✓ Inference server is operational and healthy."
    else
        echo "⚠ Warning: Inference server did not report healthy within 90s. Recent logs:"
        if [ "$_is_k8s" -eq 1 ]; then
            kubectl -n "$K8S_NS" logs --tail=15 "deploy/$K8S_INF_DEPLOY" 2>/dev/null || true
        else
            docker logs --tail 10 george-prism-server 2>/dev/null || true
        fi
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
    _gm_probe_inference
    echo "  Inference Backend:   $GM_BACKEND${GM_REPLICAS:+ (deploy/$K8S_INF_DEPLOY $GM_REPLICAS)}"
    echo "  Inference Status:    $GM_INF_STATUS"
    echo "  Port 8080 (Primary): $GM_HEALTH"

    local cron_pid
    cron_pid=$(cat "$GEORGE_DIR/.cron.pid" 2>/dev/null || cat "$GEORGE_DIR/cron.pid" 2>/dev/null || echo "")
    if [ -n "$cron_pid" ] && kill -0 "$cron_pid" 2>/dev/null; then
        if [ -f "$GEORGE_DIR/.game_mode" ]; then
            echo "  Autonomic Daemon:    standby (PID $cron_pid — zero-GPU crypto watchers only)"
        else
            echo "  Autonomic Daemon:    running (PID $cron_pid)"
        fi
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
    _gm_probe_inference
    local cron_pid
    cron_pid=$(cat "$GEORGE_DIR/.cron.pid" 2>/dev/null || cat "$GEORGE_DIR/cron.pid" 2>/dev/null || echo "")
    local cron_running="false"
    if [ -n "$cron_pid" ] && kill -0 "$cron_pid" 2>/dev/null; then
        cron_running="true"
    fi
    local game_mode="false"
    if [ "$GM_INF_STATUS" != "running" ] || [ -f "$GEORGE_DIR/.game_mode" ]; then
        game_mode="true"
    fi
    jq -nc \
        --argjson gm "$game_mode" \
        --arg be "$GM_BACKEND" \
        --arg rep "$GM_REPLICAS" \
        --arg st "$GM_INF_STATUS" \
        --arg h "$GM_HEALTH" \
        --argjson cr "$cron_running" \
        '{status:"ok", game_mode:$gm, backend:$be, k8s_replicas:$rep, inference_status:$st, port_8080:$h, autonomic_daemon:$cr}'
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

