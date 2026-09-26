#!/bin/bash
# ── George: Sovereign Task-to-Task MQTT Coordination & Sync ──────────
# Enables parallel executing agent nodes and remediation sandboxes to:
#   1. Publish heartbeat, status, and remediation events over MQTT
#   2. Asynchronously wait/listen for peer task events with timeouts
#   3. Safely pull and rebase develop changes across concurrent worktrees
#   4. Manage git index lock contention and file conflicts cleanly

[ -n "${_LIB_TASK_SYNC_LOADED:-}" ] && return 0; _LIB_TASK_SYNC_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mqtt.sh" 2>/dev/null || true

task_sync_init() {
    declare -f mqtt_init &>/dev/null && mqtt_init || true
}

# Publishes an event to MQTT topic george/tasks/<task_id>/<event_name>
task_sync_signal() {
    local task_id="$1"
    local event_name="$2"
    local payload="${3:-{}}"
    local retain="${4:---retain}"
    local topic="george/tasks/${task_id}/${event_name}"

    task_sync_init
    if declare -f mqtt_publish &>/dev/null; then
        mqtt_publish "$topic" "$payload" "$retain" >/dev/null 2>&1
        return $?
    fi
    return 1
}

# Waits for a specific event on an MQTT topic or specific remediation resolution
# Usage: task_sync_wait <topic> [timeout_seconds] [match_key] [match_val]
task_sync_wait() {
    local topic="$1"
    local timeout="${2:-15}"
    local match_key="${3:-}"
    local match_val="${4:-}"

    task_sync_init
    if ! declare -f mqtt_subscribe &>/dev/null; then
        return 1
    fi

    local start_ts now_ts elapsed
    start_ts=$(date +%s)

    while true; do
        now_ts=$(date +%s)
        elapsed=$((now_ts - start_ts))
        [ "$elapsed" -ge "$timeout" ] && break

        local rem_time=$((timeout - elapsed))
        [ "$rem_time" -gt 3 ] && rem_time=3
        [ "$rem_time" -lt 1 ] && rem_time=1

        local msg
        msg=$(mqtt_subscribe "$topic" --count 1 --timeout "$rem_time" 2>/dev/null || true)
        if [ -n "$msg" ]; then
            if [ -n "$match_key" ]; then
                local actual_val
                actual_val=$(echo "$msg" | jq -r --arg k "$match_key" '.[$k] // empty' 2>/dev/null || true)
                if [ "$actual_val" = "$match_val" ]; then
                    echo "$msg"
                    return 0
                fi
            else
                echo "$msg"
                return 0
            fi
        fi
        sleep 0.5
    done
    return 1
}

# Safely rebases current branch on develop, handling lock contention and conflicts
# Usage: task_sync_rebase_develop [worktree_dir]
task_sync_rebase_develop() {
    local wt_dir="${1:-$PWD}"
    local max_retries=5
    local attempt=1

    while [ $attempt -le $max_retries ]; do
        # Check for stale index lock
        if [ -f "$wt_dir/.git/index.lock" ]; then
            if ! pgrep -f "git.*$wt_dir" >/dev/null 2>&1; then
                rm -f "$wt_dir/.git/index.lock" 2>/dev/null || true
            fi
        fi

        # Fetch latest develop from remotes
        if git -C "$wt_dir" fetch origin develop >/dev/null 2>&1 || git -C "$wt_dir" fetch gitea develop >/dev/null 2>&1; then
            # Attempt rebase
            if git -C "$wt_dir" rebase origin/develop >/dev/null 2>&1; then
                declare -f ui_ok &>/dev/null && ui_ok "Successfully rebased on origin/develop in $wt_dir" >&2
                return 0
            else
                # Rebase failed: abort and try clean recursive merge strategy
                git -C "$wt_dir" rebase --abort >/dev/null 2>&1 || true
                declare -f ui_warn &>/dev/null && ui_warn "Rebase conflict detected in $wt_dir. Reconciling with develop..." >&2
                if git -C "$wt_dir" merge -X ours origin/develop -m "chore(sync): reconcile parallel updates with develop" >/dev/null 2>&1; then
                    declare -f ui_ok &>/dev/null && ui_ok "Cleanly merged origin/develop into $wt_dir" >&2
                    return 0
                fi
            fi
        fi

        attempt=$((attempt + 1))
        sleep 1
    done

    declare -f ui_err &>/dev/null && ui_err "Failed to synchronize $wt_dir with develop after $max_retries attempts" >&2
    return 1
}
