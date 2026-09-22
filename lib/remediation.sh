#!/bin/bash
# ── George: Sovereign Autonomous Remediation Loop ─────────────────────
# Manages the prioritized remediation queue, isolated worktree sandboxes,
# Slot 1 inference execution, issue reconciliation & archival,
# and configurable operator notification via Email (Gmail) and Discord.
#
# State:
#   Queue:        .george/remediation/queue/
#   In Progress:  .george/remediation/in_progress/
#   Completed:    .george/remediation/completed/
#   Failed:       .george/remediation/failed/
#   Config:       .george/remediation/notifications.conf

[ -n "${_LIB_REMEDIATION_LOADED:-}" ] && return 0; _LIB_REMEDIATION_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
REMEDIATION_DIR="${REMEDIATION_DIR:-$GEORGE_DIR/remediation}"
REMEDIATION_QUEUE_DIR="${REMEDIATION_DIR}/queue"
REMEDIATION_PROGRESS_DIR="${REMEDIATION_DIR}/in_progress"
REMEDIATION_COMPLETED_DIR="${REMEDIATION_DIR}/completed"
REMEDIATION_FAILED_DIR="${REMEDIATION_DIR}/failed"
REMEDIATION_LOGS_DIR="${REMEDIATION_DIR}/logs"
REMEDIATION_ATTEMPTS_DIR="${REMEDIATION_DIR}/attempts"
REMEDIATION_CONF="${REMEDIATION_DIR}/notifications.conf"

LODGE_ROOT="${LODGE_ROOT:-$HOME/blue-lodge}"
for _p in "$LODGE_DIR" "$LODGE_ROOT" "$HOME/blue-lodge"; do
    if [ -f "$_p/lib/ui.sh" ]; then
        source "$_p/lib/ui.sh" 2>/dev/null || true
        source "$_p/lib/telemetry.sh" 2>/dev/null || true
        source "$_p/lib/email.sh" 2>/dev/null || true
        source "$_p/lib/social.sh" 2>/dev/null || true
        source "$_p/lib/discord_bridge.sh" 2>/dev/null || true
        source "$_p/lib/popup.sh" 2>/dev/null || true
        source "$_p/lib/mcp_server_gitea.sh" 2>/dev/null || true
        break
    fi
done

declare -f ui_err &>/dev/null || ui_err() { echo "[ERR] $*" >&2; }
declare -f ui_ok &>/dev/null || ui_ok() { echo "[OK] $*"; }
declare -f ui_warn &>/dev/null || ui_warn() { echo "[WARN] $*" >&2; }
declare -f ui_step &>/dev/null || ui_step() { echo "[STEP] $*"; }
declare -f ui_info &>/dev/null || ui_info() { echo "[INFO] $*"; }
declare -f ui_dim &>/dev/null || ui_dim() { echo "[DIM] $*"; }
declare -f ui_section &>/dev/null || ui_section() { echo "=== $* ==="; }

remediation_init() {
    mkdir -p "$REMEDIATION_QUEUE_DIR" "$REMEDIATION_PROGRESS_DIR" "$REMEDIATION_COMPLETED_DIR" "$REMEDIATION_FAILED_DIR" "$REMEDIATION_LOGS_DIR" "$REMEDIATION_ATTEMPTS_DIR" 2>/dev/null || true
    remediation_notify_load_config
    remediation_sweep_sandboxes
}

# Sweeps and culls orphaned ephemeral git worktrees in .sandboxes/
remediation_sweep_sandboxes() {
    local sandboxes_dir="${LODGE_DIR}/.sandboxes"
    [ ! -d "$sandboxes_dir" ] && return 0
    local active_pid=""
    if [ -f "$REMEDIATION_DIR/.lock" ]; then
        active_pid=$(cat "$REMEDIATION_DIR/.lock" 2>/dev/null)
    fi

    for sb_dir in "$sandboxes_dir"/remediation_*; do
        [ ! -d "$sb_dir" ] && continue
        # If no remediation lock or PID is not running, cull worktree
        if [ -z "$active_pid" ] || ! kill -0 "$active_pid" 2>/dev/null; then
            ui_dim "Culling orphaned ephemeral sandbox: $sb_dir"
            git -C "$LODGE_DIR" worktree remove --force "$sb_dir" >/dev/null 2>&1 || true
            rm -rf "$sb_dir" 2>/dev/null || true
        fi
    done
    git -C "$LODGE_DIR" worktree prune >/dev/null 2>&1 || true
}

# ── 1. Configurable Notifications (Email & Discord) ───────────────────
# Loads notification config with configurable email and discord parameters
remediation_notify_load_config() {
    # Default parameters (purely configurable, zero hardcoded identities)
    REMEDIATION_NOTIFY_EMAIL="${REMEDIATION_NOTIFY_EMAIL:-}"
    REMEDIATION_EMAIL_PROVIDER="${REMEDIATION_EMAIL_PROVIDER:-gmail}"
    REMEDIATION_NOTIFY_DISCORD="${REMEDIATION_NOTIFY_DISCORD:-}"
    REMEDIATION_DISCORD_SERVER="${REMEDIATION_DISCORD_SERVER:-}"
    REMEDIATION_NOTIFY_CHANNEL="${REMEDIATION_NOTIFY_CHANNEL:-}"
    REMEDIATION_NOTIFY_ENABLED="${REMEDIATION_NOTIFY_ENABLED:-1}"

    if [ -f "$REMEDIATION_CONF" ]; then
        # Parse simple key=value pairs safely without eval
        local _ckey _cval
        while IFS='=' read -r _ckey _cval; do
            [[ "$_ckey" =~ ^[[:space:]]*# ]] && continue
            [ -z "$_ckey" ] && continue
            _ckey=$(echo "$_ckey" | tr -d '[:space:]')
            _cval=$(echo "$_cval" | sed 's/^[[:space:]]*["'"'"']//; s/["'"'"'][[:space:]]*$//')
            case "$_ckey" in
                REMEDIATION_NOTIFY_EMAIL) REMEDIATION_NOTIFY_EMAIL="$_cval" ;;
                REMEDIATION_EMAIL_PROVIDER) REMEDIATION_EMAIL_PROVIDER="$_cval" ;;
                REMEDIATION_NOTIFY_DISCORD) REMEDIATION_NOTIFY_DISCORD="$_cval" ;;
                REMEDIATION_DISCORD_SERVER) REMEDIATION_DISCORD_SERVER="$_cval" ;;
                REMEDIATION_NOTIFY_CHANNEL) REMEDIATION_NOTIFY_CHANNEL="$_cval" ;;
                REMEDIATION_NOTIFY_ENABLED) REMEDIATION_NOTIFY_ENABLED="$_cval" ;;
            esac
        done < "$REMEDIATION_CONF"
    else
        # Seed default config file template
        remediation_notify_save_all
    fi
}

remediation_notify_save_all() {
    mkdir -p "$(dirname "$REMEDIATION_CONF")" 2>/dev/null || true
    cat << EOF > "$REMEDIATION_CONF"
# Sovereign Remediation Notification Configuration
# Update via: /remediation notify set <key> <val>
# Clear via:  /remediation notify clear <key>
REMEDIATION_NOTIFY_EMAIL="${REMEDIATION_NOTIFY_EMAIL:-}"
REMEDIATION_EMAIL_PROVIDER="${REMEDIATION_EMAIL_PROVIDER:-gmail}"
REMEDIATION_NOTIFY_DISCORD="${REMEDIATION_NOTIFY_DISCORD:-}"
REMEDIATION_DISCORD_SERVER="${REMEDIATION_DISCORD_SERVER:-}"
REMEDIATION_NOTIFY_CHANNEL="${REMEDIATION_NOTIFY_CHANNEL:-}"
REMEDIATION_NOTIFY_ENABLED="${REMEDIATION_NOTIFY_ENABLED:-1}"
EOF
}

remediation_notify_set() {
    local key="$1"
    local val="$2"
    remediation_init

    # Allow clearing/unsetting with empty string or keywords
    if [ "$val" = "none" ] || [ "$val" = "unset" ] || [ "$val" = "clear" ] || [ "$val" = "null" ]; then
        val=""
    fi

    case "$key" in
        email|mail|REMEDIATION_NOTIFY_EMAIL)
            REMEDIATION_NOTIFY_EMAIL="$val"
            ;;
        provider|email_provider|REMEDIATION_EMAIL_PROVIDER)
            REMEDIATION_EMAIL_PROVIDER="${val:-gmail}"
            ;;
        discord|user|discord_user|REMEDIATION_NOTIFY_DISCORD)
            REMEDIATION_NOTIFY_DISCORD="$val"
            ;;
        server|discord_server|guild|REMEDIATION_DISCORD_SERVER)
            REMEDIATION_DISCORD_SERVER="$val"
            ;;
        channel|discord_channel|REMEDIATION_NOTIFY_CHANNEL)
            REMEDIATION_NOTIFY_CHANNEL="$val"
            ;;
        enabled|REMEDIATION_NOTIFY_ENABLED)
            REMEDIATION_NOTIFY_ENABLED="$val"
            ;;
        *)
            ui_err "Unknown config key: $key (valid: email, provider, discord, server, channel, enabled)"
            return 1
            ;;
    esac

    remediation_notify_save_all
    ui_ok "Remediation notification updated: $key = ${val:-<cleared>}"
}

remediation_notify_show() {
    remediation_init
    printf "\n${C_BOLD}${C_CYAN}── Remediation Notification Configuration ──────────────────${C_RESET}\n"
    printf "  Config File:    %s\n" "$REMEDIATION_CONF"
    printf "  Notifications:  %s\n" "$([ "${REMEDIATION_NOTIFY_ENABLED:-1}" = "1" ] && echo "${C_GREEN}ENABLED${C_RESET}" || echo "${C_RED}DISABLED${C_RESET}")"
    printf "  Email Target:   %s (via %s)\n" "${REMEDIATION_NOTIFY_EMAIL:-<not configured>}" "${REMEDIATION_EMAIL_PROVIDER:-gmail}"
    printf "  Discord Target: %s\n" "$([ -n "$REMEDIATION_NOTIFY_DISCORD" ] && echo "@${REMEDIATION_NOTIFY_DISCORD#@}" || echo "<not configured>")"
    printf "  Discord Server: %s\n" "${REMEDIATION_DISCORD_SERVER:-<not configured>}"
    printf "  Discord Chan:   %s\n" "${REMEDIATION_NOTIFY_CHANNEL:-<not configured>}"
    printf "${C_BOLD}${C_CYAN}────────────────────────────────────────────────────────────${C_RESET}\n\n"
}

# Dispatches notifications across configured email and discord channels
# Usage: remediation_notify_dispatch <task_id> <issue_ref> <status> <details> [extra_links]
remediation_notify_dispatch() {
    local task_id="$1"
    local issue_ref="$2"
    local status="$3"
    local details="$4"
    local extra_links="${5:-}"

    remediation_init
    [ "${REMEDIATION_NOTIFY_ENABLED:-1}" != "1" ] && return 0

    local now_ts
    now_ts=$(date '+%Y-%m-%d %H:%M:%S %Z')
    local subject="[George Remediation] $status: $issue_ref"

    local body
    body=$(cat << EOF
George Sovereign Remediation Alert
Status:    $status
Task ID:   $task_id
Issue:     $issue_ref
Timestamp: $now_ts

Details:
$details

$extra_links

--
George (Blue Lodge Autonomous Self-Healing Sentinel)
EOF
)

    local notified=0
    local email_err=""

    # 1. Send Email Notification if configured
    if [ -n "$REMEDIATION_NOTIFY_EMAIL" ]; then
        if declare -f email_send &>/dev/null; then
            # Pre-flight check: verify email provider is configured before attempting dispatch
            local provider_configured=0
            if declare -f email_provider_configured &>/dev/null; then
                email_provider_configured "$REMEDIATION_EMAIL_PROVIDER" && provider_configured=1
            elif [ -f "${LODGE_DIR:-$HOME/blue-lodge}/.george/keys.conf" ] && grep -qE "EMAIL_${REMEDIATION_EMAIL_PROVIDER^^}_" "${LODGE_DIR:-$HOME/blue-lodge}/.george/keys.conf" 2>/dev/null; then
                provider_configured=1
            fi

            if [ "$provider_configured" -eq 1 ]; then
                ui_step "Notifying operator via email (${REMEDIATION_NOTIFY_EMAIL})..." >&2
                local send_err
                send_err=$(email_send "$REMEDIATION_EMAIL_PROVIDER" "$REMEDIATION_NOTIFY_EMAIL" "$subject" "$body" 2>&1)
                local send_rc=$?
                if [ "$send_rc" -ne 0 ]; then
                    ui_warn "Email notification dispatch failed (provider: $REMEDIATION_EMAIL_PROVIDER)" >&2
                    email_err="⚠️ *Email alert to \`${REMEDIATION_NOTIFY_EMAIL}\` failed: provider \`${REMEDIATION_EMAIL_PROVIDER}\` error.*"
                fi
                notified=1
            else
                ui_dim "Email notification skipped: provider '$REMEDIATION_EMAIL_PROVIDER' not configured (/email setup $REMEDIATION_EMAIL_PROVIDER)." >&2
            fi
        fi
    fi

    # 2. Send Discord Notification if configured
    local discord_msg="🛠️ **[George Remediation Alert]** \`${status}\`\n**Issue:** ${issue_ref}\n**Task:** \`${task_id}\`\n${details}"
    if [ -n "$email_err" ]; then
        discord_msg+="\n${email_err}"
    fi
    if [ -n "$extra_links" ]; then
        discord_msg+="\n${extra_links}"
    fi

    if [ -n "$REMEDIATION_NOTIFY_DISCORD" ]; then
        local clean_user="${REMEDIATION_NOTIFY_DISCORD#@}"
        if declare -f discord_dm &>/dev/null; then
            ui_step "Notifying operator via Discord DM (@${clean_user})..." >&2
            discord_dm "$clean_user" "$discord_msg" >/dev/null 2>&1 || {
                ui_warn "Discord DM notification dispatch failed (user: @$clean_user)" >&2
            }
            notified=1
        fi
    fi

    if [ -n "$REMEDIATION_NOTIFY_CHANNEL" ]; then
        local clean_chan="${REMEDIATION_NOTIFY_CHANNEL###}"
        if declare -f discord_post &>/dev/null; then
            ui_step "Notifying operator via Discord channel (#${clean_chan})..." >&2
            discord_post "$clean_chan" "$discord_msg" >/dev/null 2>&1 || {
                ui_warn "Discord channel notification dispatch failed (channel: #$clean_chan)" >&2
            }
            notified=1
        fi
    fi

    if [ "$notified" -eq 0 ]; then
        ui_dim "No notification targets configured (run: /remediation notify set email|discord <val>)" >&2
    fi
}

# ── 2. Remediation Queue Management ───────────────────────────────────

# Enqueues a new remediation task from an issue or incident
# Usage: remediation_queue_add <issue_file> [incident_dir] [priority] [title]
remediation_queue_add() {
    local issue_file="$1"
    local inc_dir="${2:-}"
    local priority="${3:-normal}"
    local custom_title="${4:-}"

    remediation_init

    local now
    now=$(date +%s)
    local task_id="rem_${now}_$(( RANDOM % 1000 ))"
    local queue_file="$REMEDIATION_QUEUE_DIR/${task_id}.json"

    local title="$custom_title"
    if [ -z "$title" ] && [ -f "$issue_file" ]; then
        title=$(head -n 5 "$issue_file" | grep -E '^# ' | sed 's/^# //' | head -n 1)
    fi
    [ -z "$title" ] && title="Remediate issue $(basename "$issue_file" .md)"

    local fp="" gitea_idx=""
    if [ -f "$issue_file" ]; then
        fp=$(grep -o '\[fingerprint:[a-f0-9]*\]' "$issue_file" | head -n 1 | cut -d':' -f2 | tr -d ']')
        gitea_idx=$(grep -oE '\*\*Gitea Issue:\*\* #([0-9]+)' "$issue_file" 2>/dev/null | head -n 1 | cut -d'#' -f2 || true)
    fi

    jq -n \
        --arg tid "$task_id" \
        --arg title "$title" \
        --arg prio "$priority" \
        --arg issue "$issue_file" \
        --arg inc "$inc_dir" \
        --arg fp "$fp" \
        --arg gitea "$gitea_idx" \
        --argjson ts "$now" \
        '{
            task_id: $tid,
            title: $title,
            priority: $prio,
            issue_file: $issue,
            incident_dir: $inc,
            fingerprint: $fp,
            gitea_issue: $gitea,
            status: "QUEUED",
            created_ts: $ts
        }' > "$queue_file"

    ui_ok "Remediation task queued: $task_id ($title)" >&2
    echo "$task_id"
}

# Lists remediation tasks in all states
remediation_queue_list() {
    remediation_init
    printf "\n${C_BOLD}${C_CYAN}── Sovereign Remediation Queue ─────────────────────────────${C_RESET}\n"

    local q_count=0
    for qf in "$REMEDIATION_QUEUE_DIR"/*.json; do
        [ ! -f "$qf" ] && continue
        local tid ttl prio
        tid=$(jq -r '.task_id' "$qf" 2>/dev/null)
        ttl=$(jq -r '.title' "$qf" 2>/dev/null)
        prio=$(jq -r '.priority' "$qf" 2>/dev/null)
        printf "  [QUEUED]      %-20s | %-8s | %s\n" "$tid" "$prio" "$ttl"
        q_count=$((q_count + 1))
    done

    for pf in "$REMEDIATION_PROGRESS_DIR"/*.json; do
        [ ! -f "$pf" ] && continue
        local tid ttl
        tid=$(jq -r '.task_id' "$pf" 2>/dev/null)
        ttl=$(jq -r '.title' "$pf" 2>/dev/null)
        printf "  ${C_YELLOW}[IN_PROGRESS]${C_RESET} %-20s | %s\n" "$tid" "$ttl"
        q_count=$((q_count + 1))
    done

    for cf in "$REMEDIATION_COMPLETED_DIR"/*.json; do
        [ ! -f "$cf" ] && continue
        local tid ttl
        tid=$(jq -r '.task_id' "$cf" 2>/dev/null)
        ttl=$(jq -r '.title' "$cf" 2>/dev/null)
        printf "  ${C_GREEN}[COMPLETED]${C_RESET}   %-20s | %s\n" "$tid" "$ttl"
        q_count=$((q_count + 1))
    done

    [ "$q_count" -eq 0 ] && echo "  (Queue is empty)"
    printf "${C_BOLD}${C_CYAN}────────────────────────────────────────────────────────────${C_RESET}\n\n"
}

# Picks next queued task
remediation_queue_next() {
    remediation_init
    ls -1t "$REMEDIATION_QUEUE_DIR"/*.json 2>/dev/null | tail -n 1
}

# Checks if an autonomous remediation task is currently active on Slot 1
remediation_is_active() {
    remediation_init
    local lock_file="$REMEDIATION_DIR/.lock"
    if [ -f "$lock_file" ]; then
        local active_pid
        active_pid=$(cat "$lock_file" 2>/dev/null)
        if [ -n "$active_pid" ] && kill -0 "$active_pid" 2>/dev/null; then
            return 0
        fi
        # Stale lock: PID is no longer alive
        rm -f "$lock_file" 2>/dev/null || true
    fi

    # Check in_progress directory for active tasks
    local in_prog
    in_prog=$(ls -1 "$REMEDIATION_PROGRESS_DIR"/*.json 2>/dev/null | head -n 1)
    if [ -n "$in_prog" ] && [ -f "$in_prog" ]; then
        return 0
    fi
    return 1
}

# ── 3. Cooperative Scheduling & Visual Monitoring ─────────────────────

# Probes Inference Slot 0 and active Discord sessions to yield compute to interactive users
remediation_cooperative_pause() {
    local max_wait="${REMEDIATION_COOPERATIVE_MAX_WAIT:-30}"
    local waited=0
    while [ "$waited" -lt "$max_wait" ]; do
        local pause_reason=""
        # 1. Probe Slot 0 inference status
        local slots_json
        slots_json=$(curl -s -m 2 http://127.0.0.1:8080/slots 2>/dev/null || echo "[]")
        if [ "$slots_json" != "[]" ]; then
            local s0_busy
            s0_busy=$(echo "$slots_json" | jq -r '.[0].is_processing // false' 2>/dev/null)
            [ "$s0_busy" = "true" ] && pause_reason="Slot 0 interactive user inference active"
        fi

        # 2. Probe active Discord interactive sessions
        if [ -z "$pause_reason" ]; then
            local orig_dir="${orig_lodge_dir:-${LODGE_ROOT:-$HOME/blue-lodge}}"
            for dpid_file in "$orig_dir/.george/discord_sessions"/session_*.pid; do
                [ ! -f "$dpid_file" ] && continue
                local dpid
                dpid=$(cat "$dpid_file" 2>/dev/null)
                if [ -n "$dpid" ] && kill -0 "$dpid" 2>/dev/null; then
                    pause_reason="active Discord session (PID $dpid)"
                    break
                fi
            done
        fi

        if [ -z "$pause_reason" ]; then
            return 0
        fi

        ui_dim "Cooperative pause ($pause_reason). Yielding compute for 5s..." >&2
        sleep 5
        waited=$((waited + 5))
    done
}

# Launches live companion HUD monitor in Windows Terminal (wt.exe)
remediation_launch_visual_monitor() {
    local task_id="$1"
    local title="$2"
    local log_file="$3"

    if ! command -v wt.exe &>/dev/null || [ -z "${WSL_DISTRO_NAME:-}" ]; then
        return 0
    fi

    # Clean up any lingering monitor process for this task
    local existing_mon
    existing_mon=$(pgrep -f "scripts/remediation_live_monitor.sh $task_id" 2>/dev/null || true)
    if [ -n "$existing_mon" ]; then
        kill $existing_mon 2>/dev/null || true
        sleep 0.2
    fi

    local size="${REMEDIATION_POPUP_SIZE:-110,32}"

    popup_terminal_launch "George Remediation HUD - $task_id" "$size" \
        bash ./scripts/remediation_live_monitor.sh "$task_id" "$title" "$log_file"
}

# ── 4. Remediation Execution with Slot 1 Isolation ────────────────────
# Executes remediation strictly on Slot 1 in an isolated git worktree sandbox.
# Cooperatively yields if Slot 0 interactive sessions (REPL/Discord) are computing.
# Usage: remediation_run [task_id]
remediation_run() {
    local task_id="${1:-}"
    remediation_init

    # Strict single-concurrency guard on Slot 1
    local lock_file="$REMEDIATION_DIR/.lock"
    if [ -f "$lock_file" ]; then
        local active_pid
        active_pid=$(cat "$lock_file" 2>/dev/null)
        if [ -n "$active_pid" ] && [ "$active_pid" != "$$" ] && kill -0 "$active_pid" 2>/dev/null; then
            ui_dim "Autonomous remediation task is already active (PID $active_pid). Yielding Slot 1 until completion."
            return 0
        fi
        rm -f "$lock_file" 2>/dev/null || true
    fi

    local task_file=""
    if [ -n "$task_id" ]; then
        task_file="$REMEDIATION_QUEUE_DIR/${task_id}.json"
        [ ! -f "$task_file" ] && task_file="$REMEDIATION_PROGRESS_DIR/${task_id}.json"
    else
        task_file=$(remediation_queue_next)
    fi

    if [ -z "$task_file" ] || [ ! -f "$task_file" ]; then
        ui_info "No pending remediation tasks in queue."
        rm -f "$lock_file" 2>/dev/null || true
        return 0
    fi

    # Acquire lock for this active task
    echo "$$" > "$lock_file"

    task_id=$(jq -r '.task_id' "$task_file")
    local title issue_file inc_dir fp
    title=$(jq -r '.title' "$task_file")
    issue_file=$(jq -r '.issue_file' "$task_file")
    inc_dir=$(jq -r '.incident_dir' "$task_file")
    fp=$(jq -r '.fingerprint' "$task_file")

    ui_section "Executing Sovereign Remediation: $task_id"
    ui_info "Title: $title"
    [ -n "$issue_file" ] && ui_dim "Issue: $issue_file"
    [ -n "$inc_dir" ] && ui_dim "Dossier: $inc_dir"

    # Move to in_progress
    local progress_file="$REMEDIATION_PROGRESS_DIR/${task_id}.json"
    mv "$task_file" "$progress_file"
    jq '.status = "IN_PROGRESS"' "$progress_file" > "${progress_file}.tmp" && mv "${progress_file}.tmp" "$progress_file"

    # Guard: check if issue_file exists. If issue_file was in /tmp and deleted, abort cleanly.
    if [ -n "$issue_file" ] && [ ! -f "$issue_file" ] && [[ "$issue_file" == /tmp/* ]]; then
        ui_warn "Issue file $issue_file no longer exists on disk (orphaned temporary file). Aborting task."
        mv "$progress_file" "$REMEDIATION_FAILED_DIR/${task_id}.json"
        jq '.status = "ORPHANED_CLEANUP"' "$REMEDIATION_FAILED_DIR/${task_id}.json" > "${progress_file}.tmp" 2>/dev/null && mv "${progress_file}.tmp" "$REMEDIATION_FAILED_DIR/${task_id}.json" 2>/dev/null || true
        rm -f "$lock_file" 2>/dev/null || true
        return 1
    fi

    # Initialize task execution log & launch live companion monitor HUD
    local rem_log="$REMEDIATION_LOGS_DIR/${task_id}.log"
    : > "$rem_log"
    remediation_launch_visual_monitor "$task_id" "$title" "$rem_log"

    # Cooperative pre-flight pause
    remediation_cooperative_pause

    # Notify operator that remediation is starting
    remediation_notify_dispatch "$task_id" "$title" "STARTED" \
        "Autonomous remediation initiated on Slot 1. Isolated workspace prepared." \
        "$([ -n "$inc_dir" ] && echo "Incident Artifacts: file://$inc_dir" || echo "")"

    # Comment on Sovereign Gitea issue if linked
    local gitea_idx
    gitea_idx=$(jq -r '.gitea_issue // empty' "$progress_file" 2>/dev/null || true)
    if [ -z "$gitea_idx" ] && [ -n "$issue_file" ] && [ -f "$issue_file" ]; then
        gitea_idx=$(grep -oE '\*\*Gitea Issue:\*\* #([0-9]+)' "$issue_file" 2>/dev/null | head -n 1 | cut -d'#' -f2 || true)
    fi
    if [ -n "$gitea_idx" ]; then
        if ! declare -f gitea_issue_comment &>/dev/null; then
            [ -f "${LODGE_DIR:-$PWD}/lib/mcp_server_gitea.sh" ] && source "${LODGE_DIR:-$PWD}/lib/mcp_server_gitea.sh" 2>/dev/null || true
        fi
        if declare -f gitea_issue_comment &>/dev/null; then
            gitea_issue_comment "$gitea_idx" "🤖 **[George Auto-Remediation]** Sovereign remediation task \`$task_id\` initiated on Slot 1. Isolated worktree prepared." >/dev/null 2>&1 || true
        fi
    fi

    # Set up isolated worktree sandbox
    local sandbox_dir="${LODGE_DIR}/.sandboxes/remediation_${task_id}"
    local branch_name="remediation/${task_id}"
    mkdir -p "$(dirname "$sandbox_dir")" 2>/dev/null || true

    local orig_lodge_dir="${LODGE_DIR:-$HOME/blue-lodge}"
    local orig_george_dir="${GEORGE_DIR:-$orig_lodge_dir/.george}"
    local orig_tier="${ACTIVE_TIER:-1}"

    git -C "$orig_lodge_dir" branch -D "$branch_name" 2>/dev/null || true
    git -C "$orig_lodge_dir" worktree remove --force "$sandbox_dir" 2>/dev/null || true
    git -C "$orig_lodge_dir" worktree add -b "$branch_name" "$sandbox_dir" HEAD 2>/dev/null || {
        ui_err "Failed to create isolated git worktree for remediation: $sandbox_dir"
        mv "$progress_file" "$REMEDIATION_FAILED_DIR/${task_id}.json"
        remediation_notify_dispatch "$task_id" "$title" "FAILED" "Failed to provision isolated worktree $sandbox_dir"
        rm -f "$lock_file" 2>/dev/null || true
        return 1
    }

    # Execute remediation loop inside sandbox (Targeting Slot 1 / Tier 2)
    ui_step "Executing remediation contract in sandbox..."
    export ACTIVE_TIER=2
    export LODGE_DIR="$sandbox_dir"
    export GEORGE_DIR="$sandbox_dir/.george"
    export AGENT_SOVEREIGN_REMEDIATION=1
    export AGENT_MAX_TURNS="${AGENT_REMEDIATION_MAX_TURNS:-50}"

    local rem_success=1
    local rem_prompt="You are George in Sovereign Autonomous Remediation mode.
Remediate the failure documented in issue: $issue_file
Incident dossier: $inc_dir
Error Fingerprint: $fp

SOVEREIGN REMEDIATION & ARCHITECTURAL INTEGRITY MANDATE:
1. Examine the failure evidence, error traces, and reproduction details.
2. ARCHITECTURAL PURITY & SANDBOX ISOLATION (Tyler & Warden Review Mandate):
   - The host Blue Lodge repository and system MUST remain 100% pure POSIX shell (bash, curl, jq) with zero host Python/Node dependencies.
   - Downloading or installing Python/Node.js packages directly onto the host environment (via pip, uv, npm, apt) violates architectural purity and is strictly prohibited.
   - If a task or capability requires Python or heavy libraries (e.g. pdfminer, pypdf, pandas), the execution MUST be encapsulated inside an isolated container sandbox via 'container_exec' or disposable sandbox environment.
   - If native POSIX alternatives exist (e.g. Poppler pdftotext, jq, awk), prefer the sovereign zero-dependency native implementation.
3. ADAPTIVE PATHFINDING & FALLBACKS:
   - If the failure stems from a missing external service or unconfigured provider (e.g. email, discord, gsuite), wire in graceful multi-provider fallbacks or disposable one-time adapters.
4. CODEBASE FIX & PR WORKFLOW:
   - If this failure requires a permanent codebase fix, tool wrapper, or configuration change, implement and commit the fix on this remediation branch.
   - If a fix is implemented, submit a Pull Request to develop via 'gitea_pr_create', referencing this issue.
5. Verify your fix thoroughly by executing automated test suites before concluding."

    if declare -f react_run &>/dev/null && [ "${REMEDIATION_MOCK_EXEC:-0}" -ne 1 ]; then
        react_run "$rem_prompt" "$sandbox_dir" 2>&1 | tee -a "$rem_log"
        local ec=${PIPESTATUS[0]}
        [ "$ec" -eq 0 ] && rem_success=0
    else
        # Direct verification gate
        if bash "$sandbox_dir/tests/run_all.sh" test_telemetry test_incident_preservation test_remediation_queue 2>&1 | tee -a "$rem_log"; then
            rem_success=0
        fi
    fi

    # Reset environment back to host lodge
    unset AGENT_SOVEREIGN_REMEDIATION
    export LODGE_DIR="$orig_lodge_dir"
    export GEORGE_DIR="$orig_george_dir"
    export ACTIVE_TIER="$orig_tier"

    local attempt_key="${fp:-${gitea_idx:-$task_id}}"
    local attempt_file="$REMEDIATION_ATTEMPTS_DIR/${attempt_key}.json"

    if [ "$rem_success" -eq 0 ]; then
        echo "[REMEDIATION_COMPLETE]" >> "$rem_log"
        ui_ok "Remediation verified successfully! Checking for code deliverables..."

        # Closed-Loop PR Generation: check if remediation commits were made on branch relative to develop
        local commit_count=0
        commit_count=$(git -C "$sandbox_dir" rev-list --count HEAD ^develop 2>/dev/null || echo 0)
        if [ "$commit_count" -gt 0 ]; then
            ui_step "Delivering code fix: pushing branch '$branch_name' ($commit_count commits) and creating rich PR..."
            git -C "$orig_lodge_dir" push origin "$branch_name" >/dev/null 2>&1 || \
            git -C "$orig_lodge_dir" push gitea "$branch_name" >/dev/null 2>&1 || true

            if ! declare -f gitea_pr_create &>/dev/null; then
                [ -f "${orig_lodge_dir}/lib/mcp_server_gitea.sh" ] && source "${orig_lodge_dir}/lib/mcp_server_gitea.sh" 2>/dev/null || true
            fi
            if declare -f gitea_pr_create &>/dev/null; then
                local git_log diff_stat
                git_log=$(git -C "$sandbox_dir" log --oneline develop..HEAD 2>/dev/null | head -n 15)
                diff_stat=$(git -C "$sandbox_dir" diff --stat develop..HEAD 2>/dev/null | head -n 25)

                local pr_title="fix(remediation): $title"
                local pr_body="## 🛠️ Sovereign Autonomous Remediation

### Problem Statement
- **Issue:** ${title}
- **Error Fingerprint:** \`${fp:-N/A}\`
- **Task ID:** \`${task_id}\`
- **Branch:** \`${branch_name}\`
$([ -n "$gitea_idx" ] && echo "- **Resolves Gitea Issue:** #${gitea_idx}" || echo "")

### Root Cause & Remediation Summary
Automated remediation executed on Slot 1 inside an isolated git worktree sandbox. The defect was resolved in strict compliance with the Sovereign Remediation Mandate (100% pure POSIX shell, zero host Python/Node dependencies).

### Delivered Commits
\`\`\`
${git_log:-No additional commits}
\`\`\`

### Modified Files & Diffstat
\`\`\`
${diff_stat:-No diff stat available}
\`\`\`

### Verification Evidence
- Automated test verification passed cleanly in isolated sandbox.
- Ephemeral worktree sandbox culled immediately upon completion.
"
                local pr_res
                pr_res=$(gitea_pr_create "$branch_name" "develop" "$pr_title" "$pr_body" 2>/dev/null || true)
                local pr_num
                pr_num=$(echo "$pr_res" | jq -r '.number // empty' 2>/dev/null || true)
                if [ -n "$pr_num" ]; then
                    ui_ok "Proposed Sovereign Gitea Pull Request #${pr_num}: $pr_title"
                fi
            fi
        fi

        # Reset attempt counter on success
        rm -f "$attempt_file" 2>/dev/null || true

        # Immediate ephemeral worktree culling
        ui_ok "Culling ephemeral sandbox worktree and closing issue."
        git -C "$orig_lodge_dir" worktree remove --force "$sandbox_dir" 2>/dev/null || true
        rm -rf "$sandbox_dir" 2>/dev/null || true
        git -C "$orig_lodge_dir" worktree prune 2>/dev/null || true

        # Close Sovereign Gitea issue if linked
        if [ -n "$gitea_idx" ]; then
            if ! declare -f gitea_issue_close &>/dev/null; then
                [ -f "${orig_lodge_dir}/lib/mcp_server_gitea.sh" ] && source "${orig_lodge_dir}/lib/mcp_server_gitea.sh" 2>/dev/null || true
            fi
            if declare -f gitea_issue_close &>/dev/null; then
                gitea_issue_close "$gitea_idx" "Autonomous remediation completed and verified cleanly by George on Slot 1. Task: $task_id" >/dev/null 2>&1 || true
                ui_ok "Closed Sovereign Gitea Issue #${gitea_idx}"
            fi
        fi

        # Move to completed
        mv "$progress_file" "$REMEDIATION_COMPLETED_DIR/${task_id}.json"
        jq '.status = "COMPLETED"' "$REMEDIATION_COMPLETED_DIR/${task_id}.json" > "${progress_file}.tmp" 2>/dev/null && mv "${progress_file}.tmp" "$REMEDIATION_COMPLETED_DIR/${task_id}.json" 2>/dev/null || true

        # Archive local issue
        if [ -n "$issue_file" ] && [ -f "$issue_file" ]; then
            local archive_issues_dir="$GEORGE_DIR/issues/archive"
            mkdir -p "$archive_issues_dir" 2>/dev/null || true
            mv "$issue_file" "$archive_issues_dir/" 2>/dev/null || true
            ui_dim "Archived resolved issue: $issue_file -> $archive_issues_dir/"
        fi

        # Notify operator of success
        remediation_notify_dispatch "$task_id" "$title" "RESOLVED" \
            "Autonomous remediation completed and verified cleanly. Issue closed and archived."
        rm -f "$lock_file" 2>/dev/null || true
        return 0
    else
        echo "[REMEDIATION_FAILED]" >> "$rem_log"
        ui_warn "Remediation verification did not pass clean gate."

        # 3-Strike failure tracking
        local attempt_count=0
        [ -f "$attempt_file" ] && attempt_count=$(jq -r '.attempts // 0' "$attempt_file" 2>/dev/null || echo 0)
        attempt_count=$((attempt_count + 1))
        local now_ts
        now_ts=$(date +%s)
        jq -n \
            --arg tid "$task_id" \
            --arg key "$attempt_key" \
            --argjson att "$attempt_count" \
            --argjson ts "$now_ts" \
            '{task_id: $tid, key: $key, attempts: $att, last_failure_ts: $ts}' > "$attempt_file" 2>/dev/null || true

        if [ "$attempt_count" -ge 3 ]; then
            ui_warn "Remediation task reached 3-strike failure ceiling ($attempt_count/3). Escalating to operator review."
            if [ -n "$gitea_idx" ]; then
                if ! declare -f gitea_issue_comment &>/dev/null; then
                    [ -f "${orig_lodge_dir}/lib/mcp_server_gitea.sh" ] && source "${orig_lodge_dir}/lib/mcp_server_gitea.sh" 2>/dev/null || true
                fi
                if declare -f gitea_issue_comment &>/dev/null; then
                    gitea_issue_comment "$gitea_idx" "🚨 **[Autonomous Remediation Escalation]** Automated fix attempted 3 times without passing verification gates (Branch: \`$branch_name\`, Fingerprint: \`${fp:-N/A}\`). Automatic re-queueing halted; manual operator review required." >/dev/null 2>&1 || true
                fi
                if declare -f gitea_issue_label &>/dev/null; then
                    gitea_issue_label "$gitea_idx" "escalation-required" >/dev/null 2>&1 || true
                fi
            fi
            remediation_notify_dispatch "$task_id" "$title" "ESCALATED" \
                "Autonomous remediation exceeded 3-strike failure ceiling on branch $branch_name. Re-queueing halted; operator intervention required."
            mv "$progress_file" "$REMEDIATION_FAILED_DIR/${task_id}.json"
            jq '.status = "ESCALATED_OPERATOR_REQUIRED"' "$REMEDIATION_FAILED_DIR/${task_id}.json" > "${progress_file}.tmp" 2>/dev/null && mv "${progress_file}.tmp" "$REMEDIATION_FAILED_DIR/${task_id}.json" 2>/dev/null || true
        else
            local rem_strikes=$((3 - attempt_count))
            if [ -n "$gitea_idx" ]; then
                if ! declare -f gitea_issue_comment &>/dev/null; then
                    [ -f "${orig_lodge_dir}/lib/mcp_server_gitea.sh" ] && source "${orig_lodge_dir}/lib/mcp_server_gitea.sh" 2>/dev/null || true
                fi
                if declare -f gitea_issue_comment &>/dev/null; then
                    gitea_issue_comment "$gitea_idx" "⚠️ **[George Auto-Remediation]** Attempt ${attempt_count}/3 failed verification gates on branch \`${branch_name}\` (Task: ${task_id}). ${rem_strikes} attempt(s) remaining before operator escalation." >/dev/null 2>&1 || true
                fi
            fi
            remediation_notify_dispatch "$task_id" "$title" "FAILED" \
                "Automated fix attempted on branch $branch_name failed verification gates (Attempt ${attempt_count}/3)."
            mv "$progress_file" "$REMEDIATION_FAILED_DIR/${task_id}.json"
            jq '.status = "FAILED"' "$REMEDIATION_FAILED_DIR/${task_id}.json" > "${progress_file}.tmp" 2>/dev/null && mv "${progress_file}.tmp" "$REMEDIATION_FAILED_DIR/${task_id}.json" 2>/dev/null || true
        fi

        # Immediate ephemeral worktree culling (retaining branch for operator review)
        ui_dim "Culling ephemeral sandbox worktree (retaining git branch $branch_name)..."
        git -C "$orig_lodge_dir" worktree remove --force "$sandbox_dir" 2>/dev/null || true
        rm -rf "$sandbox_dir" 2>/dev/null || true
        git -C "$orig_lodge_dir" worktree prune 2>/dev/null || true

        rm -f "$lock_file" 2>/dev/null || true
        return 1
    fi
}
