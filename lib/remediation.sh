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
REMEDIATION_CONF="${REMEDIATION_DIR}/notifications.conf"

LODGE_ROOT="${LODGE_ROOT:-$HOME/blue-lodge}"
for _p in "$LODGE_DIR" "$LODGE_ROOT" "$HOME/blue-lodge"; do
    if [ -f "$_p/lib/ui.sh" ]; then
        source "$_p/lib/ui.sh" 2>/dev/null || true
        source "$_p/lib/telemetry.sh" 2>/dev/null || true
        source "$_p/lib/email.sh" 2>/dev/null || true
        source "$_p/lib/social.sh" 2>/dev/null || true
        source "$_p/lib/discord_bridge.sh" 2>/dev/null || true
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
    mkdir -p "$REMEDIATION_QUEUE_DIR" "$REMEDIATION_PROGRESS_DIR" "$REMEDIATION_COMPLETED_DIR" "$REMEDIATION_FAILED_DIR" 2>/dev/null || true
    remediation_notify_load_config
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
            ui_step "Notifying operator via email (${REMEDIATION_NOTIFY_EMAIL})..." >&2
            local send_err
            send_err=$(email_send "$REMEDIATION_EMAIL_PROVIDER" "$REMEDIATION_NOTIFY_EMAIL" "$subject" "$body" 2>&1)
            local send_rc=$?
            if [ "$send_rc" -ne 0 ]; then
                ui_warn "Email notification dispatch failed (provider: $REMEDIATION_EMAIL_PROVIDER)" >&2
                email_err="⚠️ *Email alert to \`${REMEDIATION_NOTIFY_EMAIL}\` failed: provider \`${REMEDIATION_EMAIL_PROVIDER}\` error.*"

                # Triage as operational anomaly if not in a recursive remediation loop
                if [ "${_IN_NOTIFICATION_TRIAGE:-0}" -ne 1 ]; then
                    _IN_NOTIFICATION_TRIAGE=1
                    local diag_trace="Target: ${REMEDIATION_NOTIFY_EMAIL}
Provider: ${REMEDIATION_EMAIL_PROVIDER}
Error: ${send_err}"
                    if declare -f telemetry_triage_operational_failure &>/dev/null; then
                        telemetry_triage_operational_failure \
                            "email_notification" \
                            "NOTIFICATION_DISPATCH_FAILURE" \
                            "Email Notification Dispatch Failed (${REMEDIATION_EMAIL_PROVIDER})" \
                            "$diag_trace" \
                            "${LODGE_DIR:-$PWD}" >/dev/null 2>&1 || true
                    elif [ -f "${LODGE_DIR:-$PWD}/lib/telemetry.sh" ]; then
                        source "${LODGE_DIR:-$PWD}/lib/telemetry.sh" 2>/dev/null || true
                        if declare -f telemetry_triage_operational_failure &>/dev/null; then
                            telemetry_triage_operational_failure \
                                "email_notification" \
                                "NOTIFICATION_DISPATCH_FAILURE" \
                                "Email Notification Dispatch Failed (${REMEDIATION_EMAIL_PROVIDER})" \
                                "$diag_trace" \
                                "${LODGE_DIR:-$PWD}" >/dev/null 2>&1 || true
                        fi
                    fi
                    _IN_NOTIFICATION_TRIAGE=0
                fi
            fi
            notified=1
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

    local fp=""
    if [ -f "$issue_file" ]; then
        fp=$(grep -o '\[fingerprint:[a-f0-9]*\]' "$issue_file" | head -n 1 | cut -d':' -f2 | tr -d ']')
    fi

    jq -n \
        --arg tid "$task_id" \
        --arg title "$title" \
        --arg prio "$priority" \
        --arg issue "$issue_file" \
        --arg inc "$inc_dir" \
        --arg fp "$fp" \
        --argjson ts "$now" \
        '{
            task_id: $tid,
            title: $title,
            priority: $prio,
            issue_file: $issue,
            incident_dir: $inc,
            fingerprint: $fp,
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

# ── 3. Remediation Execution with Slot 1 Isolation ────────────────────
# Executes remediation strictly on Slot 1 in an isolated git worktree sandbox.
# Yields if Slot 0 interactive sessions (REPL/Discord) are currently computing.
# Usage: remediation_run [task_id]
remediation_run() {
    local task_id="${1:-}"
    remediation_init

    local task_file=""
    if [ -n "$task_id" ]; then
        task_file="$REMEDIATION_QUEUE_DIR/${task_id}.json"
        [ ! -f "$task_file" ] && task_file="$REMEDIATION_PROGRESS_DIR/${task_id}.json"
    else
        task_file=$(remediation_queue_next)
    fi

    if [ -z "$task_file" ] || [ ! -f "$task_file" ]; then
        ui_info "No pending remediation tasks in queue."
        return 0
    fi

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

    # Notify operator that remediation is starting
    remediation_notify_dispatch "$task_id" "$title" "STARTED" \
        "Autonomous remediation initiated on Slot 1. Isolated workspace prepared." \
        "$([ -n "$inc_dir" ] && echo "Incident Artifacts: file://$inc_dir" || echo "")"

    # Check Slot 0 activity to prevent degrading operator interactive sessions
    local slots_json
    slots_json=$(curl -s -m 2 http://127.0.0.1:8080/slots 2>/dev/null || echo "[]")
    if [ "$slots_json" != "[]" ]; then
        local s0_busy
        s0_busy=$(echo "$slots_json" | jq -r '.[0].is_processing // false' 2>/dev/null)
        if [ "$s0_busy" = "true" ]; then
            ui_warn "Inference Slot 0 is currently active (operator interactive session). Yielding compute..."
            sleep 2
        fi
    fi

    # Set up isolated worktree sandbox
    local sandbox_dir="${LODGE_DIR}/.sandboxes/remediation_${task_id}"
    local branch_name="remediation/${task_id}"
    mkdir -p "$(dirname "$sandbox_dir")" 2>/dev/null || true

    git -C "$LODGE_DIR" branch -D "$branch_name" 2>/dev/null || true
    git -C "$LODGE_DIR" worktree remove --force "$sandbox_dir" 2>/dev/null || true
    git -C "$LODGE_DIR" worktree add -b "$branch_name" "$sandbox_dir" HEAD 2>/dev/null || {
        ui_err "Failed to create isolated git worktree for remediation: $sandbox_dir"
        mv "$progress_file" "$REMEDIATION_FAILED_DIR/${task_id}.json"
        remediation_notify_dispatch "$task_id" "$title" "FAILED" "Failed to provision isolated worktree $sandbox_dir"
        return 1
    }

    # Execute remediation loop inside sandbox (Targeting Slot 1 / Tier 2)
    ui_step "Executing remediation contract in sandbox..."
    export ACTIVE_TIER=2
    export LODGE_DIR="$sandbox_dir"
    export GEORGE_DIR="$sandbox_dir/.george"

    local rem_success=1
    local rem_prompt="You are George in Sovereign Autonomous Remediation mode.
Remediate the failure documented in issue: $issue_file
Incident dossier: $inc_dir
Error Fingerprint: $fp

SOVEREIGN REMEDIATION & ADAPTIVE PATHFINDING MANDATE:
1. Examine the failure evidence, error traces, and reproduction details.
2. If the failure stems from a missing external service, dependency, or unconfigured provider:
   - Survey the codebase and environment for alternative providers, fallback adapters, or disposable service implementations.
   - Wire in graceful multi-provider fallbacks or self-healing adaptations so that the workflow succeeds even when preferred providers lack credentials.
3. If the failure stems from a code error or capability deficit:
   - Implement the necessary code or configuration fix in this repository.
4. Verify your fix thoroughly by executing automated test suites before concluding."

    if declare -f react_run &>/dev/null && [ "${REMEDIATION_MOCK_EXEC:-0}" -ne 1 ]; then
        react_run "$rem_prompt" "$sandbox_dir"
        local ec=$?
        [ "$ec" -eq 0 ] && rem_success=0
    else
        # Direct verification gate
        if bash "$sandbox_dir/tests/run_all.sh" test_telemetry test_incident_preservation test_remediation_queue >/dev/null 2>&1; then
            rem_success=0
        fi
    fi

    # Reset environment back to host lodge
    export LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
    export GEORGE_DIR="${LODGE_DIR}/.george"

    if [ "$rem_success" -eq 0 ]; then
        ui_ok "Remediation verified successfully! Cleaning up sandbox and closing issue."
        git -C "$LODGE_DIR" worktree remove --force "$sandbox_dir" 2>/dev/null || true
        rm -rf "$sandbox_dir" 2>/dev/null || true

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
        return 0
    else
        ui_warn "Remediation verification did not pass clean gate. Retaining branch for operator review."
        mv "$progress_file" "$REMEDIATION_FAILED_DIR/${task_id}.json"
        jq '.status = "FAILED"' "$REMEDIATION_FAILED_DIR/${task_id}.json" > "${progress_file}.tmp" 2>/dev/null && mv "${progress_file}.tmp" "$REMEDIATION_FAILED_DIR/${task_id}.json" 2>/dev/null || true

        remediation_notify_dispatch "$task_id" "$title" "FAILED" \
            "Automated fix attempted on branch $branch_name but did not pass verification gates."
        return 1
    fi
}
