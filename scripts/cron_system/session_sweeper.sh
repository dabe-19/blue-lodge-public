#!/bin/bash
# INTERVAL: 300
# DESC: Reconciler sweeper — force-closes zombie run.json files stuck RUNNING with no live process or IPC channel.
# SCOPE: system
# Part of Fix F4: durable safety net for abnormal react_run exits.

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"
RUNS_DIR="$GEORGE_DIR/runs"
IPC_DIR="${IPC_DIR:-$GEORGE_DIR/ipc}"
[ -d "$RUNS_DIR" ] || exit 0

SWEEPT=0

for run_json in "$RUNS_DIR"/*/run.json; do
    [ -f "$run_json" ] || continue
    session_dir=$(dirname "$run_json")
    session_id=$(jq -r '.session_id // .id // empty' "$run_json" 2>/dev/null)
    [ -z "$session_id" ] && session_id=$(basename "$session_dir")
    [ -z "$session_id" ] && continue

    status=$(jq -r '.status // empty' "$run_json" 2>/dev/null)
    [ "$status" != "RUNNING" ] && continue

    # Check if the driving process is still alive
    consumer_pid=$(jq -r '.consumer_pid // .pid // 0' "$run_json" 2>/dev/null)
    consumer_pid=${consumer_pid:-0}

    # Also check workspace .pid file if present
    ws_dir=$(jq -r '.workspace // empty' "$run_json" 2>/dev/null)
    ws_pid=0
    if [ -n "$ws_dir" ] && [ -f "$ws_dir/.pid" ]; then
        ws_pid=$(head -n1 "$ws_dir/.pid" 2>/dev/null | tr -cd '0-9')
        ws_pid=${ws_pid:-0}
    fi

    # Also check for any george-keeper process for this session
    keeper_alive=0
    if pgrep -f "george-keeper.*${session_id}" >/dev/null 2>&1; then
        keeper_alive=1
    fi

    # Check if any process with this session ID is running
    proc_alive=0
    if pgrep -f "${session_id}" >/dev/null 2>&1; then
        proc_alive=1
    fi

    # Check if IPC channel directory exists (non-blocking: just check dir, not FIFO)
    channel_open=0
    if [ -d "$IPC_DIR/$session_id" ]; then
        channel_open=1
    fi

    # Check if consumer PID is alive
    consumer_alive=0
    if [ "${consumer_pid:-0}" -ne 0 ] 2>/dev/null && kill -0 "$consumer_pid" 2>/dev/null; then
        consumer_alive=1
    fi
    if [ "${ws_pid:-0}" -ne 0 ] 2>/dev/null && kill -0 "$ws_pid" 2>/dev/null; then
        consumer_alive=1
    fi

    # If no live consumer, no running session process, no keeper, and no open channel → zombie
    if [ "$consumer_alive" -eq 0 ] && [ "$proc_alive" -eq 0 ] && [ "$keeper_alive" -eq 0 ] && [ "$channel_open" -eq 0 ]; then
        # Zombie detected — clean up
        echo "[sweeper] ZOMBIE: $session_id (no consumer, no proc, no keeper, no channel)" >&2

        # Close the run ledger
        if [ -f "$run_json" ]; then
            now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            tmp="${run_json}.sweeper.$$"
            jq --arg now "$now_iso" --arg why "SWEEPER: no live process or channel detected" \
               '.status = "FINISHED" | .outcome = "STALL" | .finished_at = $now | .reason = $why' \
               "$run_json" > "$tmp" 2>/dev/null && mv "$tmp" "$run_json"
        fi

        # Force-close IPC channel dir if it exists
        if [ -d "$IPC_DIR/$session_id" ]; then
            rm -rf "$IPC_DIR/$session_id" 2>/dev/null || true
        fi

        # Mark session dir as done
        touch "$session_dir/.done" 2>/dev/null || true

        SWEEPT=$((SWEEPT + 1))
    fi
done

# ── Sweep Stale Discord Session PID & Active Files ─────────────────────
DISCORD_SESSIONS_DIR="$GEORGE_DIR/discord_sessions"
if [ -d "$DISCORD_SESSIONS_DIR" ]; then
    if [ -f "$LODGE_DIR/lib/comms/discord_status.sh" ]; then
        source "$LODGE_DIR/lib/comms/discord_status.sh" 2>/dev/null || true
    fi

    for pf in "$DISCORD_SESSIONS_DIR"/*.pid "$DISCORD_SESSIONS_DIR"/active/*.pid; do
        [ -f "$pf" ] || continue
        is_alive=0
        if declare -f discord_pid_alive &>/dev/null; then
            discord_pid_alive "$pf" && is_alive=1
        else
            dpid=$(head -n1 "$pf" 2>/dev/null | tr -cd '0-9')
            [ -n "$dpid" ] && kill -0 "$dpid" 2>/dev/null && is_alive=1
        fi

        if [ "$is_alive" -eq 0 ]; then
            echo "[sweeper] Pruning dead Discord PID file: $pf" >&2
            rm -f "$pf" "${pf}.start" 2>/dev/null || true
            SWEEPT=$((SWEEPT + 1))
        fi
    done

    # Prune orphan .pid.start files whose base .pid is absent
    for ps in "$DISCORD_SESSIONS_DIR"/*.pid.start "$DISCORD_SESSIONS_DIR"/active/*.pid.start; do
        [ -f "$ps" ] || continue
        pf="${ps%.start}"
        if [ ! -f "$pf" ]; then
            rm -f "$ps" 2>/dev/null || true
            SWEEPT=$((SWEEPT + 1))
        fi
    done

    # Also clean orphaned active_run_*.json markers where process is dead
    for am in "$DISCORD_SESSIONS_DIR"/active_run_*.json; do
        [ -f "$am" ] || continue
        apid=$(jq -r '.pid // empty' "$am" 2>/dev/null | tr -cd '0-9')
        if [ -n "$apid" ] && ! kill -0 "$apid" 2>/dev/null; then
            echo "[sweeper] Pruning stale active run marker: $am (PID $apid dead)" >&2
            rm -f "$am" 2>/dev/null || true
            SWEEPT=$((SWEEPT + 1))
        fi
    done
fi

# ── Sweep Orphaned Subagents, Runtime Dirs & Agent SM Registry ─────────
if [ -f "$LODGE_DIR/lib/agents/subagents.sh" ]; then
    source "$LODGE_DIR/lib/agents/subagents.sh" 2>/dev/null || true
    declare -f subagents_reap_orphans &>/dev/null && subagents_reap_orphans >/dev/null 2>&1 || true
fi

if [ -f "$LODGE_DIR/lib/core/agent_sm.sh" ]; then
    source "$LODGE_DIR/lib/core/agent_sm.sh" 2>/dev/null || true
    declare -f agent_sm_prune &>/dev/null && agent_sm_prune 86400 >/dev/null 2>&1 || true
fi

# ── Sweep Stale PR FSM Files for Closed/Merged Gitea PRs ───────────────
PR_FSM_DIR="$GEORGE_DIR/state/prs"
if [ -d "$PR_FSM_DIR" ] && [ -f "$LODGE_DIR/lib/tools/mcp_server_gitea.sh" ]; then
    source "$LODGE_DIR/lib/tools/mcp_server_gitea.sh" 2>/dev/null || true
    if declare -f gitea_is_online &>/dev/null && gitea_is_online 2>/dev/null; then
        _gitea_load_conf 2>/dev/null || true
        for fsm_file in "$PR_FSM_DIR"/*.fsm.json; do
            [ -f "$fsm_file" ] || continue
            fsm_st=$(jq -r '.state // empty' "$fsm_file" 2>/dev/null)
            case "$fsm_st" in
                MERGED|CLOSED|REJECTED) continue ;;
            esac
            pr_num=$(jq -r '.pr_id // empty' "$fsm_file" 2>/dev/null)
            [ -z "$pr_num" ] && continue
            pr_api=$(curl -s -m 3 -H "Authorization: token ${GITEA_TOKEN:-}" "${GITEA_URL:-http://127.0.0.1:3088}/api/v1/repos/${GITEA_USER:-}/${GITEA_REPO:-}/pulls/${pr_num}" 2>/dev/null || true)
            g_state=$(echo "$pr_api" | jq -r '.state // empty' 2>/dev/null)
            g_merged=$(echo "$pr_api" | jq -r '.merged // false' 2>/dev/null)
            if [ "$g_state" = "closed" ]; then
                new_st="CLOSED"
                [ "$g_merged" = "true" ] && new_st="MERGED"
                tmp_fsm="${fsm_file}.tmp.$$"
                jq --arg st "$new_st" --argjson ts "$(date +%s)" '.state = $st | .updated_at = $ts | .last_transition_reason = "Reconciled with closed Gitea PR"' "$fsm_file" > "$tmp_fsm" 2>/dev/null && mv -f "$tmp_fsm" "$fsm_file" 2>/dev/null || rm -f "$tmp_fsm" 2>/dev/null
                SWEEPT=$((SWEEPT + 1))
            fi
        done
    fi
fi

[ "$SWEEPT" -gt 0 ] && echo "[sweeper] Reclaimed $SWEEPT zombie session(s) / stale lock(s)." >&2
exit 0
