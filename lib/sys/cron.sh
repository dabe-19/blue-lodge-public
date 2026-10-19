#!/bin/bash
# ── George: Autonomic Daemon & Cron Engine ─────────────────────
# Provides persistent autonomic life to George without blocking
# interactive REPL sessions or CLI tasks. Periodically sweeps:
#   1. PRs (Three Degrees Audit, auto-merge, or 5-attempt remediation)
#   2. Issues / Alerts (Auto-remediates tripped circuit breakers)
#   3. Discord (Polls DMs and bot mentions across servers)
#   4. Email (Polls configured inboxes)
#   5. X / Twitter (Polls mentions & publishes queued monetization devlogs)
#
# State: .george/cron_state.json
# PID:   .george/.cron.pid
# Log:   .george/cron.log
# Conf:  .george/cron.conf

[ -n "${_LIB_CRON_LOADED:-}" ] && return 0; _LIB_CRON_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agents/pr.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agents/alerts.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/social.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/email.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ui/popup.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agents/sentinel.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/comms/discord_bridge.sh" 2>/dev/null || true

CRON_PID_FILE="${CRON_PID_FILE:-$GEORGE_DIR/.cron.pid}"
CRON_LOG_FILE="${CRON_LOG_FILE:-$GEORGE_DIR/cron.log}"
CRON_STATE_FILE="${CRON_STATE_FILE:-$GEORGE_DIR/cron_state.json}"
CRON_CONF_FILE="${CRON_CONF_FILE:-$GEORGE_DIR/cron.conf}"
CRON_JOBS_DIR="${CRON_JOBS_DIR:-$GEORGE_DIR/cron_jobs}"

# Default intervals (in seconds)
CRON_INTERVAL_SENTINEL="${CRON_INTERVAL_SENTINEL:-60}"
CRON_INTERVAL_PR="${CRON_INTERVAL_PR:-60}"
CRON_INTERVAL_ISSUE="${CRON_INTERVAL_ISSUE:-60}"
CRON_INTERVAL_DISCORD="${CRON_INTERVAL_DISCORD:-30}"
CRON_INTERVAL_EMAIL="${CRON_INTERVAL_EMAIL:-120}"
CRON_INTERVAL_X="${CRON_INTERVAL_X:-300}"
CRON_INTERVAL_MASTODON="${CRON_INTERVAL_MASTODON:-180}"
CRON_INTERVAL_POPUP="${CRON_INTERVAL_POPUP:-300}"
CRON_INTERVAL_CI="${CRON_INTERVAL_CI:-60}"

# Visual Windows Terminal Pop-Up Defaults
CRON_POPUP_TERMINAL="${CRON_POPUP_TERMINAL:-1}"
CRON_POPUP_POS="${CRON_POPUP_POS:-1200,40}"
CRON_POPUP_SIZE="${CRON_POPUP_SIZE:-85,22}"
CRON_POPUP_HOLD_ON_ERROR="${CRON_POPUP_HOLD_ON_ERROR:-1}"

cron_init() {
    mkdir -p "$GEORGE_DIR" "$CRON_JOBS_DIR" 2>/dev/null
    if [ -f "$CRON_CONF_FILE" ]; then
        # Load user-configured interval overrides
        while IFS='=' read -r key val; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            key=$(echo "$key" | tr -d '[:space:]')
            val=$(echo "$val" | tr -d '[:space:]' | tr -d '"' | tr -d "'")
            case "$key" in
                CRON_INTERVAL_SENTINEL) CRON_INTERVAL_SENTINEL="$val" ;;
                CRON_INTERVAL_PR) CRON_INTERVAL_PR="$val" ;;
                CRON_INTERVAL_ISSUE) CRON_INTERVAL_ISSUE="$val" ;;
                CRON_INTERVAL_DISCORD) CRON_INTERVAL_DISCORD="$val" ;;
                CRON_INTERVAL_EMAIL) CRON_INTERVAL_EMAIL="$val" ;;
                CRON_INTERVAL_X) CRON_INTERVAL_X="$val" ;;
                CRON_INTERVAL_MASTODON) CRON_INTERVAL_MASTODON="$val" ;;
                CRON_INTERVAL_POPUP) CRON_INTERVAL_POPUP="$val" ;;
                CRON_INTERVAL_CI) CRON_INTERVAL_CI="$val" ;;
                CRON_POPUP_TERMINAL) CRON_POPUP_TERMINAL="$val" ;;
                CRON_POPUP_POS) CRON_POPUP_POS="$val" ;;
                CRON_POPUP_SIZE) CRON_POPUP_SIZE="$val" ;;
                CRON_POPUP_HOLD_ON_ERROR) CRON_POPUP_HOLD_ON_ERROR="$val" ;;
                CRON_DISABLED_JOBS) CRON_DISABLED_JOBS="$val" ;;
            esac
        done < "$CRON_CONF_FILE"
    fi

    CRON_DISABLED_JOBS="${CRON_DISABLED_JOBS:-}"

    if [ ! -s "$CRON_STATE_FILE" ] || ! jq -e . "$CRON_STATE_FILE" >/dev/null 2>&1; then
        echo '{"jobs":{}}' > "$CRON_STATE_FILE" 2>/dev/null || true
    fi
}

_cron_get_last_run() {
    local job_name="$1"
    if [ ! -s "$CRON_STATE_FILE" ] || ! jq -e . "$CRON_STATE_FILE" >/dev/null 2>&1; then
        echo '{"jobs":{}}' > "$CRON_STATE_FILE" 2>/dev/null || true
        echo 0
        return 0
    fi
    jq -r ".jobs.\"$job_name\".last_run // 0" "$CRON_STATE_FILE" 2>/dev/null || echo 0
}

_cron_set_last_run() {
    local job_name="$1"
    local exit_code="${2:-0}"
    local now
    now=$(date +%s)
    local tmp="${CRON_STATE_FILE}.tmp.${BASHPID:-$$}.$RANDOM"
    local lockfile="${CRON_STATE_FILE}.lock"
    (
        flock -x -w 5 200 2>/dev/null || true
        if [ ! -s "$CRON_STATE_FILE" ] || ! jq -e . "$CRON_STATE_FILE" >/dev/null 2>&1; then
            echo '{"jobs":{}}' > "$CRON_STATE_FILE" 2>/dev/null || true
        fi
        if jq --arg j "$job_name" --argjson lr "$now" --argjson ec "$exit_code" \
            '.jobs[$j] = ((.jobs[$j] // {}) + { "last_run": $lr, "exit_code": $ec, "updated_at": (now | todate) })' \
            "$CRON_STATE_FILE" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
            mv -f "$tmp" "$CRON_STATE_FILE"
        else
            rm -f "$tmp" 2>/dev/null || true
        fi
    ) 200>"$lockfile"
}

# Build the system.job_failure payload (event contract, refinement P1/1.2).
# Usage: _cron_job_failure_payload <job> <exit_code> <log_path> [start_epoch]
# Emits: {job, job_id, label, exit_code, log, stderr_tail, wall_s}
# stderr_tail = last 40 lines of the log, ANSI-stripped, secrets redacted,
# capped at 4000 chars, so remediation issues carry real diagnostics.
_CRON_SECRET_PATTERN='(ghp_[A-Za-z0-9_]+|gh[ousr]_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+|xox[abpr]-[A-Za-z0-9-]+|bearer[[:space:]]+[A-Za-z0-9_.~+/=-]+|(password|passwd|pass|token|access_token|api_key|apikey|secret|key)=[^&[:space:]"]+)'
_cron_job_failure_payload() {
    local job="$1" ec="${2:-1}" log="${3:-}" start="${4:-}"
    [[ "$ec" =~ ^-?[0-9]+$ ]] || ec=1
    local wall=0
    if [[ "$start" =~ ^[0-9]+$ ]]; then
        wall=$(( $(date +%s) - start ))
        [ "$wall" -lt 0 ] && wall=0
    fi
    local tail_txt=""
    if [ -n "$log" ] && [ -r "$log" ]; then
        tail_txt=$(tail -n 40 "$log" 2>/dev/null \
            | sed -E 's/\x1B\[[0-9;?]*[A-Za-z]//g' \
            | tr -d '\000-\010\013\014\016-\037' \
            | sed -E "s#$_CRON_SECRET_PATTERN#[REDACTED_SECRET]#gI")
        if [ "${#tail_txt}" -gt 4000 ]; then
            tail_txt="${tail_txt: -4000}"
        fi
    fi
    jq -nc --arg j "$job" --argjson ec "$ec" --arg log "$log" \
        --arg tail "$tail_txt" --argjson wall "$wall" \
        '{job: $j, job_id: $j, label: $j, exit_code: $ec, log: $log, stderr_tail: $tail, wall_s: $wall}'
}

cron_is_job_enabled() {
    local job_name="$1"
    cron_init

    # 1. Check custom job header in script file if it exists
    local script_name="${job_name%.sh}"
    local job_script="$CRON_JOBS_DIR/${script_name}.sh"
    if [ -f "$job_script" ]; then
        local en_hdr
        en_hdr=$(grep -m1 '^# ENABLED:' "$job_script" 2>/dev/null | awk '{print $3}')
        if [ "$en_hdr" = "0" ] || [ "$en_hdr" = "false" ]; then
            return 1
        fi
    fi

    # 2. Check CRON_CONF_FILE for CRON_DISABLED_JOBS list
    if [ -n "${CRON_DISABLED_JOBS:-}" ]; then
        if [[ ",${CRON_DISABLED_JOBS}," == *",${job_name},"* ]] || [[ ",${CRON_DISABLED_JOBS}," == *",${script_name},"* ]]; then
            return 1
        fi
    fi

    # 3. Check cron_state.json .jobs[job_name].enabled
    if [ -s "$CRON_STATE_FILE" ]; then
        local state_en
        state_en=$(jq -r ".jobs.\"$job_name\".enabled // .jobs.\"$script_name\".enabled // empty" "$CRON_STATE_FILE" 2>/dev/null)
        if [ "$state_en" = "false" ] || [ "$state_en" = "0" ]; then
            return 1
        fi
    fi

    return 0
}

cron_enable_job() {
    local job_name="$1"
    cron_init
    local script_name="${job_name%.sh}"

    # 1. Update script header if custom script
    local job_script="$CRON_JOBS_DIR/${script_name}.sh"
    if [ -f "$job_script" ]; then
        if grep -q '^# ENABLED:' "$job_script"; then
            sed -i 's/^# ENABLED:.*/# ENABLED: 1/' "$job_script"
        else
            sed -i '/^# INTERVAL:/a # ENABLED: 1' "$job_script"
        fi
    fi

    # 2. Update CRON_CONF_FILE (remove from CRON_DISABLED_JOBS)
    if [ -f "$CRON_CONF_FILE" ]; then
        local cur_dis
        cur_dis=$(grep '^CRON_DISABLED_JOBS=' "$CRON_CONF_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        if [ -n "$cur_dis" ]; then
            local new_dis
            new_dis=$(echo "$cur_dis" | tr ',' '\n' | grep -v -E "^(${job_name}|${script_name})$" | tr '\n' ',' | sed 's/,$//')
            if [ -n "$new_dis" ]; then
                sed -i "s/^CRON_DISABLED_JOBS=.*/CRON_DISABLED_JOBS=\"$new_dis\"/" "$CRON_CONF_FILE"
            else
                sed -i '/^CRON_DISABLED_JOBS=/d' "$CRON_CONF_FILE"
            fi
        fi
    fi
    CRON_DISABLED_JOBS=$(grep '^CRON_DISABLED_JOBS=' "$CRON_CONF_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)

    # 3. Update cron_state.json
    local tmp="${CRON_STATE_FILE}.tmp.${BASHPID:-$$}.$RANDOM"
    if jq --arg j "$job_name" \
        '.jobs[$j] = ((.jobs[$j] // {}) + { "enabled": true, "updated_at": (now | todate) })' \
        "$CRON_STATE_FILE" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mv -f "$tmp" "$CRON_STATE_FILE"
    else
        rm -f "$tmp" 2>/dev/null || true
    fi

    ui_ok "Cron job '$job_name' enabled."
    return 0
}

cron_disable_job() {
    local job_name="$1"
    cron_init
    local script_name="${job_name%.sh}"

    # 1. Update script header if custom script
    local job_script="$CRON_JOBS_DIR/${script_name}.sh"
    if [ -f "$job_script" ]; then
        if grep -q '^# ENABLED:' "$job_script"; then
            sed -i 's/^# ENABLED:.*/# ENABLED: 0/' "$job_script"
        else
            sed -i '/^# INTERVAL:/a # ENABLED: 0' "$job_script"
        fi
    fi

    # 2. Update CRON_CONF_FILE (add to CRON_DISABLED_JOBS)
    mkdir -p "$(dirname "$CRON_CONF_FILE")" 2>/dev/null
    touch "$CRON_CONF_FILE"
    local cur_dis
    cur_dis=$(grep '^CRON_DISABLED_JOBS=' "$CRON_CONF_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    local new_dis
    if [ -n "$cur_dis" ]; then
        new_dis=$(echo "$cur_dis,$job_name" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
        sed -i "s/^CRON_DISABLED_JOBS=.*/CRON_DISABLED_JOBS=\"$new_dis\"/" "$CRON_CONF_FILE"
    else
        echo "CRON_DISABLED_JOBS=\"$job_name\"" >> "$CRON_CONF_FILE"
    fi
    CRON_DISABLED_JOBS=$(grep '^CRON_DISABLED_JOBS=' "$CRON_CONF_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)

    # 3. Update cron_state.json
    local tmp="${CRON_STATE_FILE}.tmp.${BASHPID:-$$}.$RANDOM"
    if jq --arg j "$job_name" \
        '.jobs[$j] = ((.jobs[$j] // {}) + { "enabled": false, "updated_at": (now | todate) })' \
        "$CRON_STATE_FILE" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mv -f "$tmp" "$CRON_STATE_FILE"
    else
        rm -f "$tmp" 2>/dev/null || true
    fi

    ui_warn "Cron job '$job_name' disabled."
    return 0
}

cron_toggle_job() {
    local job_name="$1"
    if cron_is_job_enabled "$job_name"; then
        cron_disable_job "$job_name"
    else
        cron_enable_job "$job_name"
    fi
}

# Jobs whose header has '# NOTIFY: escalate' can alert the operator by printing lines like
#   ESCALATE: NIGHT pool reserve dropped 30% in an hour
#   ESCALATE(urgent): wallet balance below 60 ADA
#   ESCALATE(normal, night_reserve): ...     (explicit dedup subject)
# Each becomes lib/comms/escalation.py raise --kind cron/<job> (dedup 6 h per subject, <= 4/hour,
# quiet hours deferred unless urgent). George can create such jobs himself (/cron add).
_cron_escalate_from_output() {
    local job="$1" out="$2" line sev subj text kind n=0
    [ -s "$out" ] || return 0
    local py="$LODGE_DIR/.venv/bin/python"
    [ -x "$py" ] || py="python3"
    kind="cron/$(printf '%s' "$job" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_.-' '_' | cut -c1-58)"
    local re='^ESCALATE(\(([a-z]+)(,[[:space:]]*([A-Za-z0-9_.:-]{1,60}))?\))?:[[:space:]]*(.+)$'
    while IFS= read -r line; do
        [[ "$line" =~ $re ]] || continue
        sev="${BASH_REMATCH[2]:-normal}"
        subj="${BASH_REMATCH[4]:-$job}"
        text="${BASH_REMATCH[5]}"
        [[ "$sev" =~ ^(info|normal|urgent)$ ]] || sev="normal"
        (cd "$LODGE_DIR" && "$py" lib/comms/escalation.py raise --kind "$kind" --subject "$subj" \
            --severity "$sev" --source "cron:$job" --text "[cron ${job}] ${text:0:1500}" >/dev/null 2>&1) || true
        n=$((n + 1))
        [ "$n" -ge 5 ] && break
    done < <(grep -E '^ESCALATE' "$out" 2>/dev/null | head -n 20)
    return 0
}

cron_run_job() {
    local job_name="$1"
    cron_init

    local task_id="cron_${job_name%.sh}"
    local task_dir="$LODGE_DIR/.sandboxes/$task_id"

    # Concurrency guard: if already running and not marked done, skip this tick
    if [ -f "$task_dir/.pid" ] && [ ! -f "$task_dir/.done" ]; then
        local cur_pid
        cur_pid=$(cat "$task_dir/.pid" 2>/dev/null)
        if [ -n "$cur_pid" ] && [ "$cur_pid" != "$$" ] && kill -0 "$cur_pid" 2>/dev/null; then
            return 0
        fi
    fi

    # Initialize task envelope for autonomic visibility
    local job_start_epoch
    job_start_epoch=$(date +%s)
    mkdir -p "$task_dir" 2>/dev/null
    rm -f "$task_dir/.done" "$task_dir/.pause_requested" 2>/dev/null
    echo "$$" > "$task_dir/.pid"
    echo "Starting ${job_name}..." > "$task_dir/.phase"
    export LODGE_CRON_JOB="${job_name%.sh}"   # search_router: caller=cron, never paid providers

    local task_summary="Cron: ${job_name%.sh}"
    local task_desc="Autonomic scheduled execution: ${job_name}"
    local custom_script="$CRON_JOBS_DIR/${job_name%.sh}.sh"
    if [ -f "$custom_script" ]; then
        local parsed_desc
        parsed_desc=$(grep -m1 '^# DESC:' "$custom_script" 2>/dev/null | sed 's/^# DESC: //')
        [ -n "$parsed_desc" ] && task_desc="$parsed_desc"
    fi

    cat > "$task_dir/task_meta.json" << EOF
{
  "command": "/cron run ${job_name}",
  "task_type": "cron",
  "type": "cron",
  "name": "${job_name}",
  "summary": "${task_summary}",
  "objective": "${task_desc}",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

    # Prepare trajectory log (rotate if > 512KB)
    if [ -f "$task_dir/trajectory.log" ]; then
        local _tlog_sz
        _tlog_sz=$(stat -c%s "$task_dir/trajectory.log" 2>/dev/null || echo 0)
        if [ "$_tlog_sz" -gt 524288 ]; then
            tail -n 500 "$task_dir/trajectory.log" > "$task_dir/trajectory.log.tmp" 2>/dev/null && mv "$task_dir/trajectory.log.tmp" "$task_dir/trajectory.log" || true
        fi
    fi

    echo -e "\n── George Autonomic Task: ${job_name} [$(date '+%Y-%m-%d %H:%M:%S')] ──" >> "$task_dir/trajectory.log"

    export GEORGE_TASK_DIR="$task_dir"
    export GEORGE_AUTONOMIC_TASK="$task_id"

    local res=0
    case "$job_name" in
        sentinel_sweep)
            echo "Probing vitals & slots..." > "$task_dir/.phase"
            if declare -f sentinel_sweep &>/dev/null; then
                sentinel_sweep 2>&1 | tee -a "$task_dir/trajectory.log" >> "$CRON_LOG_FILE"
                res=${PIPESTATUS[0]}
            fi
            ;;
        pr_sweep)
            echo "Auditing PRs..." > "$task_dir/.phase"
            if declare -f pr_sweep &>/dev/null; then
                pr_sweep 2>&1 | tee -a "$task_dir/trajectory.log" >> "$CRON_LOG_FILE"
                res=${PIPESTATUS[0]}
            fi
            ;;
        issue_sweep)
            echo "Auditing alerts & issues..." > "$task_dir/.phase"
            {
                declare -f alerts_sweep &>/dev/null && alerts_sweep || true
                if [ -f "$LODGE_DIR/lib/agents/sentinel.sh" ]; then
                    source "$LODGE_DIR/lib/agents/sentinel.sh" 2>/dev/null || true
                    declare -f sentinel_sweep_remediated_issues &>/dev/null && sentinel_sweep_remediated_issues || true
                fi
                if [ -f "$LODGE_DIR/lib/agents/remediation.sh" ]; then
                    source "$LODGE_DIR/lib/agents/remediation.sh" 2>/dev/null || true
                    declare -f remediation_heartbeat &>/dev/null && remediation_heartbeat || true
                    # Operator Gitea intake: closed issue -> cancel queued task; `remediate` label -> enqueue.
                    if [ -f "$LODGE_DIR/lib/tools/mcp_server_gitea.sh" ]; then
                        declare -f gitea_issue_list &>/dev/null || source "$LODGE_DIR/lib/tools/mcp_server_gitea.sh" >/dev/null 2>&1 || true
                        if declare -f gitea_is_online &>/dev/null && gitea_is_online; then
                            declare -f remediation_gitea_cancel_closed &>/dev/null && remediation_gitea_cancel_closed >/dev/null || true
                            declare -f remediation_gitea_intake &>/dev/null && remediation_gitea_intake >/dev/null || true
                        fi
                    fi
                    if declare -f remediation_queue_next &>/dev/null && declare -f remediation_run &>/dev/null; then
                        if ! (declare -f remediation_is_active &>/dev/null && remediation_is_active); then
                            local next_rem
                            next_rem=$(remediation_queue_next 2>/dev/null || true)
                            if [ -n "$next_rem" ] && [ -f "$next_rem" ]; then
                                (
                                    echo "$BASHPID" > "$task_dir/.pid"
                                    echo "Executing autonomous remediation in background..." > "$task_dir/.phase"
                                    remediation_run "" || true
                                ) >> "$task_dir/trajectory.log" 2>&1 &
                                local bg_rem_pid=$!
                                echo "$bg_rem_pid" > "$task_dir/.pid"
                                echo "Dispatched autonomous remediation (PID $bg_rem_pid)" > "$task_dir/.phase"
                            fi
                        fi
                    fi
                fi
            } 2>&1 | tee -a "$task_dir/trajectory.log" >> "$CRON_LOG_FILE"
            res=${PIPESTATUS[0]}
            ;;
        discord_sweep)
            echo "Polling Discord mentions & DMs..." > "$task_dir/.phase"
            {
                if declare -f discord_bridge_sweep &>/dev/null; then
                    discord_bridge_sweep || true
                elif declare -f discord_mentions_poll &>/dev/null; then
                    discord_mentions_poll || true
                fi
            } 2>&1 | tee -a "$task_dir/trajectory.log" >> "$CRON_LOG_FILE"
            res=${PIPESTATUS[0]}
            ;;
        email_sweep)
            echo "Sweeping email inboxes..." > "$task_dir/.phase"
            if declare -f email_sweep &>/dev/null; then
                email_sweep 2>&1 | tee -a "$task_dir/trajectory.log" >> "$CRON_LOG_FILE"
                res=${PIPESTATUS[0]}
            fi
            ;;
        x_social_sweep)
            echo "Sweeping X/Twitter queue..." > "$task_dir/.phase"
            if declare -f x_social_sweep &>/dev/null; then
                x_social_sweep 2>&1 | tee -a "$task_dir/trajectory.log" >> "$CRON_LOG_FILE"
                res=${PIPESTATUS[0]}
            fi
            ;;
        research_sweep|blog_sweep)
            echo "Executing research & blog publisher..." > "$task_dir/.phase"
            if declare -f x_blog_sweep &>/dev/null; then
                x_blog_sweep 2>&1 | tee -a "$task_dir/trajectory.log" >> "$CRON_LOG_FILE"
                res=${PIPESTATUS[0]}
            fi
            ;;
        mastodon_sweep)
            echo "Sweeping Mastodon queue..." > "$task_dir/.phase"
            if declare -f mastodon_social_sweep &>/dev/null; then
                mastodon_social_sweep 2>&1 | tee -a "$task_dir/trajectory.log" >> "$CRON_LOG_FILE"
                res=${PIPESTATUS[0]}
            fi
            ;;
        ci_sweep)
            echo "Auditing Gitea Actions CI runs..." > "$task_dir/.phase"
            cron_ci_sweep 2>&1 | tee -a "$task_dir/trajectory.log" >> "$CRON_LOG_FILE"
            res=${PIPESTATUS[0]}
            ;;
        *)
            local script_name="${job_name%.sh}"
            local job_script="$CRON_JOBS_DIR/${script_name}.sh"
            if [ -f "$job_script" ]; then
                # Runtime safety net (issue #461): never execute a job script
                # whose body re-invokes its own filename — such a script
                # recurses until fork exhaustion (exit 254).
                if grep -vE '^[[:space:]]*#' "$job_script" 2>/dev/null | grep -qF "${script_name}.sh"; then
                    echo "Skipped: self-referential script (would recurse, issue #461)" > "$task_dir/.phase"
                    echo "[cron] SKIPPED self-referential job '${script_name}'" >&2
                    touch "$task_dir/.done" 2>/dev/null || true
                    return 0
                fi
                local pid_file="$CRON_JOBS_DIR/.${script_name}.pid"
                if [ -f "$pid_file" ]; then
                    local cur_pid
                    cur_pid=$(cat "$pid_file" 2>/dev/null)
                    if [ -n "$cur_pid" ] && kill -0 "$cur_pid" 2>/dev/null; then
                        return 0
                    else
                        rm -f "$pid_file" 2>/dev/null || true
                    fi
                fi
                ui_step "Launching custom cron job '$script_name' in background..."
                _cron_set_last_run "$job_name" 0
                (
                    echo "$BASHPID" > "$task_dir/.pid"
                    echo "Executing ${script_name}..." > "$task_dir/.phase"
                    export GEORGE_TASK_DIR="$task_dir"
                    export GEORGE_AUTONOMIC_TASK="$task_id"
                    bash "$job_script" 2>&1 | tee -a "$task_dir/trajectory.log" | tee "$task_dir/.run_output" >> "$CRON_LOG_FILE"
                    local ec=${PIPESTATUS[0]}
                    _cron_set_last_run "$job_name" "$ec"
                    if grep -qiE '^# NOTIFY:[[:space:]]*escalate' "$job_script" 2>/dev/null; then
                        _cron_escalate_from_output "$script_name" "$task_dir/.run_output" || true
                    fi
                    if [ "$ec" -eq 0 ]; then
                        if [ ! -s "$task_dir/.phase" ] || grep -qiE 'executing|starting|running' "$task_dir/.phase" 2>/dev/null; then
                            echo "Completed" > "$task_dir/.phase"
                        fi
                    else
                        echo "Failed (exit $ec)" > "$task_dir/.phase"
                        if [ -f "$LODGE_DIR/lib/ipc/event_bus.sh" ]; then
                            source "$LODGE_DIR/lib/ipc/event_bus.sh" 2>/dev/null || true
                            if declare -f event_bus_emit &>/dev/null; then
                                event_bus_emit "system.job_failure" \
                                    "$(_cron_job_failure_payload "$script_name" "$ec" "$task_dir/trajectory.log" "$job_start_epoch")" \
                                    "cron" 2>/dev/null || true
                            fi
                        fi
                    fi
                    touch "$task_dir/.done"
                    touch "$task_dir/trajectory.log"
                    rm -f "$pid_file" 2>/dev/null
                ) &
                local bg_pid=$!
                echo "$bg_pid" > "$pid_file"
                echo "$bg_pid" > "$task_dir/.pid"
                return 0
            else
                ui_err "Unknown cron job: $job_name"
                echo "Error: Unknown cron job: $job_name" > "$task_dir/.phase"
                touch "$task_dir/.done"
                return 1
            fi
            ;;
    esac

    # Finalize synchronous sweep status
    if [ "$res" -eq 0 ]; then
        if [ ! -s "$task_dir/.phase" ] || grep -qiE 'starting|probing|auditing|polling|sweeping|executing' "$task_dir/.phase" 2>/dev/null; then
            echo "Completed" > "$task_dir/.phase"
        fi
    else
        echo "Alert (exit $res)" > "$task_dir/.phase"
        if [ "$job_name" = "sentinel_sweep" ] && [ "$res" -eq 1 ]; then
            # Anomaly alert, not a job crash: sentinel already filed its own
            # Gitea issue. Don't also enqueue a job_failure remediation.
            :
        elif [ -f "$LODGE_DIR/lib/ipc/event_bus.sh" ]; then
            source "$LODGE_DIR/lib/ipc/event_bus.sh" 2>/dev/null || true
            if declare -f event_bus_emit &>/dev/null; then
                event_bus_emit "system.job_failure" \
                    "$(_cron_job_failure_payload "$job_name" "$res" "$task_dir/trajectory.log" "$job_start_epoch")" \
                    "cron" 2>/dev/null || true
            fi
        fi
    fi
    touch "$task_dir/.done"
    touch "$task_dir/trajectory.log"
    rm -f "$task_dir/.pid" 2>/dev/null

    _cron_set_last_run "$job_name" "$res"
    return "$res"
}

# ── Sovereign Gitea CI Actions Failure Watchdog ─────────────────────────
cron_ci_sweep() {
    if [ -f "$LODGE_DIR/lib/tools/mcp_server_gitea.sh" ]; then
        source "$LODGE_DIR/lib/tools/mcp_server_gitea.sh" 2>/dev/null || true
    fi
    if ! declare -f gitea_is_online &>/dev/null || ! gitea_is_online; then
        return 0
    fi
    _gitea_load_conf
    local runs_json
    runs_json=$(curl -s -H "Authorization: token ${GITEA_TOKEN}" "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/actions/runs?page=1&limit=5" 2>/dev/null || echo "{}")
    local failed_runs
    failed_runs=$(echo "$runs_json" | jq -c '.workflow_runs[]? | select(.status == "failure" or .conclusion == "failure")' 2>/dev/null || true)
    [ -z "$failed_runs" ] && return 0

    local seen_file="$GEORGE_DIR/cron_ci_seen.json"
    [ ! -f "$seen_file" ] && echo "{}" > "$seen_file"

    while IFS= read -r run; do
        [ -z "$run" ] && continue
        local run_id run_title run_branch run_head
        run_id=$(echo "$run" | jq -r '.id // empty' 2>/dev/null)
        run_title=$(echo "$run" | jq -r '.title // "CI Run Failed"' 2>/dev/null)
        run_branch=$(echo "$run" | jq -r '.head_branch // "develop"' 2>/dev/null)
        run_head=$(echo "$run" | jq -r '.head_sha // empty' 2>/dev/null)

        [ -z "$run_id" ] && continue
        local already_seen
        already_seen=$(jq -r --arg id "$run_id" '.[$id] // empty' "$seen_file" 2>/dev/null)
        [ -n "$already_seen" ] && continue

        local tmp_seen="${seen_file}.tmp.$$"
        jq --arg id "$run_id" --arg ts "$(date +%s)" '.[$id] = $ts' "$seen_file" > "$tmp_seen" 2>/dev/null && mv "$tmp_seen" "$seen_file"

        ui_warn "Detected failed Gitea Actions CI run #$run_id ($run_title on $run_branch)"
        if [ -f "$LODGE_DIR/lib/ipc/event_bus.sh" ]; then
            source "$LODGE_DIR/lib/ipc/event_bus.sh" 2>/dev/null || true
            if declare -f event_bus_emit &>/dev/null; then
                event_bus_emit "ci.build_failure" \
                    "$(jq -nc --arg rid "$run_id" --arg br "$run_branch" --arg sha "$run_head" --arg title "$run_title" \
                       '{run_id: $rid, branch: $br, commit: $sha, title: $title, source: "gitea_actions"}')" \
                    "gitea_actions" 2>/dev/null || true
            fi
        fi
    done <<< "$failed_runs"
    return 0
}

# cron_quiesced — 0 when sweeps must yield the GPU: game mode, or a live golden-eval harness
# (the LLM server runs a single slot; background jobs during an eval skew its results).
cron_quiesced() {
    local gd="${GEORGE_DIR:-$LODGE_DIR/.george}"
    [ -f "$gd/.game_mode" ] || [ -f "$LODGE_DIR/.george/.game_mode" ] && return 0
    local hp="$gd/eval/.harness.pid" pid
    [ -f "$hp" ] || return 1
    pid=$(head -c 32 "$hp" 2>/dev/null | tr -dc '0-9')
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
    return 1
}

cron_tick() {
    cron_init

    # Yield the GPU in Game Mode or while a golden eval runs
    if cron_quiesced; then
        return 0
    fi

    local now
    now=$(date +%s)

    # Flush queued non-urgent operator escalations every 300s
    local last_esc_flush
    last_esc_flush=$(_cron_get_last_run "escalation_flush")
    if [ $((now - last_esc_flush)) -ge 300 ]; then
        _cron_set_last_run "escalation_flush" 0
        if [ -f "$LODGE_DIR/lib/comms/escalation.py" ]; then
            python3 "$LODGE_DIR/lib/comms/escalation.py" flush >/dev/null 2>&1 || true
        fi
    fi

    # 0. Sentinel Telemetry & Self-Healing Sweep
    local last_sentinel
    last_sentinel=$(_cron_get_last_run "sentinel_sweep")
    if cron_is_job_enabled "sentinel_sweep" && [ $((now - last_sentinel)) -ge "$CRON_INTERVAL_SENTINEL" ]; then
        cron_run_job "sentinel_sweep"
    fi

    # 1. PR Sweep
    local last_pr
    last_pr=$(_cron_get_last_run "pr_sweep")
    if cron_is_job_enabled "pr_sweep" && [ $((now - last_pr)) -ge "$CRON_INTERVAL_PR" ]; then
        cron_run_job "pr_sweep"
    fi

    # 2. Issue / Circuit Breaker Remediation Sweep
    local last_issue
    last_issue=$(_cron_get_last_run "issue_sweep")
    if cron_is_job_enabled "issue_sweep" && [ $((now - last_issue)) -ge "$CRON_INTERVAL_ISSUE" ]; then
        cron_run_job "issue_sweep"
    fi

    # 3. Discord DM & Mention Sweep
    local last_discord
    last_discord=$(_cron_get_last_run "discord_sweep")
    if cron_is_job_enabled "discord_sweep" && [ $((now - last_discord)) -ge "$CRON_INTERVAL_DISCORD" ]; then
        cron_run_job "discord_sweep"
    fi

    # 4. Email Sweep
    local last_email
    last_email=$(_cron_get_last_run "email_sweep")
    if cron_is_job_enabled "email_sweep" && [ $((now - last_email)) -ge "$CRON_INTERVAL_EMAIL" ]; then
        cron_run_job "email_sweep"
    fi

    # 5. X Social & Monetization Sweep
    local last_x
    last_x=$(_cron_get_last_run "x_social_sweep")
    if cron_is_job_enabled "x_social_sweep" && [ $((now - last_x)) -ge "$CRON_INTERVAL_X" ]; then
        cron_run_job "x_social_sweep"
    fi

    # 6. Mastodon Social & Mentions Sweep
    local last_mastodon
    last_mastodon=$(_cron_get_last_run "mastodon_sweep")
    if cron_is_job_enabled "mastodon_sweep" && [ $((now - last_mastodon)) -ge "$CRON_INTERVAL_MASTODON" ]; then
        cron_run_job "mastodon_sweep"
    fi

    # 7. Sovereign Gitea Actions CI Failure Sweep
    local last_ci
    last_ci=$(_cron_get_last_run "ci_sweep")
    if cron_is_job_enabled "ci_sweep" && [ $((now - last_ci)) -ge "$CRON_INTERVAL_CI" ]; then
        cron_run_job "ci_sweep"
    fi

    # 7. Custom Operator Jobs in $CRON_JOBS_DIR
    if [ -d "$CRON_JOBS_DIR" ]; then
        for cscript in "$CRON_JOBS_DIR"/*.sh; do
            [ -f "$cscript" ] || continue
            local cjob civ
            cjob=$(basename "$cscript" .sh)
            if ! cron_is_job_enabled "$cjob"; then
                continue
            fi
            civ=$(grep -m1 '^# INTERVAL:' "$cscript" 2>/dev/null | awk '{print $3}')
            civ="${civ:-300}"
            local last_c
            last_c=$(_cron_get_last_run "$cjob")
            if [ $((now - last_c)) -ge "$civ" ]; then
                cron_run_job "$cjob"
            fi
        done
    fi
}

# ── Visual Windows Terminal Sweeper ─────────────────────────────────
cron_is_gui_available() {
    # Verify wt.exe is in PATH and we are on WSL in an active desktop session
    if [ -n "${WSL_DISTRO_NAME:-}" ] && command -v wt.exe &>/dev/null; then
        if [ -z "${SSH_CONNECTION:-}" ] && [ -z "${SSH_CLIENT:-}" ]; then
            return 0
        fi
    fi
    return 1
}

cron_run_visual_sweep() {
    local sweep_type="${1:-all}"
    cron_init

    printf "${C_BOLD}${C_CYAN}── George Autonomic Sentinel Sweep: %s ──${C_RESET}\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    local total_ec=0

    # 1. Hardware vitals & self-healing
    if [ "$sweep_type" = "all" ] || [ "$sweep_type" = "sentinel" ]; then
        if declare -f sentinel_sweep &>/dev/null; then
            sentinel_sweep
            [ $? -ne 0 ] && total_ec=1
        fi
    fi

    # 2. PR Review & Remediation Sweep
    if [ "$sweep_type" = "all" ] || [ "$sweep_type" = "pr" ]; then
        if declare -f pr_sweep &>/dev/null; then
            pr_sweep
            [ $? -ne 0 ] && total_ec=1
        fi
    fi

    # 3. Alerts & Circuit Breakers Sweep
    if [ "$sweep_type" = "all" ] || [ "$sweep_type" = "issue" ]; then
        if declare -f alerts_sweep &>/dev/null; then
            alerts_sweep
            [ $? -ne 0 ] && total_ec=1
        fi
        if declare -f sentinel_sweep_remediated_issues &>/dev/null; then
            sentinel_sweep_remediated_issues || true
        elif [ -f "$LODGE_DIR/lib/agents/sentinel.sh" ]; then
            source "$LODGE_DIR/lib/agents/sentinel.sh" 2>/dev/null || true
            declare -f sentinel_sweep_remediated_issues &>/dev/null && sentinel_sweep_remediated_issues || true
        fi
    fi

    # 3b. Autonomous Remediation Sweep (Slot 1)
    if [ "$sweep_type" = "all" ] || [ "$sweep_type" = "remediation" ]; then
        if declare -f remediation_is_active &>/dev/null && remediation_is_active; then
            ui_dim "Autonomous remediation task is already in progress on Slot 1. Skipping sweep trigger."
        elif declare -f remediation_queue_next &>/dev/null && declare -f remediation_run &>/dev/null; then
            local next_rem
            next_rem=$(remediation_queue_next 2>/dev/null || true)
            if [ -n "$next_rem" ] && [ -f "$next_rem" ]; then
                ui_step "Executing pending autonomous remediation on Slot 1..."
                remediation_run ""
                [ $? -ne 0 ] && total_ec=1
            fi
        fi
    fi

    # 4. Social & Monetization Queue Sweep
    if [ "$sweep_type" = "all" ] || [ "$sweep_type" = "social" ]; then
        declare -f x_social_sweep &>/dev/null && x_social_sweep
    fi

    # 5. Discord DM & Mentions Sweep
    if [ "$sweep_type" = "all" ] || [ "$sweep_type" = "discord" ]; then
        if declare -f discord_bridge_sweep &>/dev/null; then
            discord_bridge_sweep
        elif declare -f discord_mentions_poll &>/dev/null; then
            discord_mentions_poll
        fi
    fi

    if [ "$total_ec" -eq 0 ]; then
        printf "\n${C_GREEN}${C_BOLD}✓ All autonomic sweeps cleared cleanly.${C_RESET}\n"
    else
        printf "\n${C_RED}${C_BOLD}⚠ Sweeps completed with warnings/alerts.${C_RESET}\n"
    fi
    return "$total_ec"
}

cron_launch_visual() {
    local sweep_type="${1:-all}"
    cron_init

    # Prevent stacking multiple open visual sweep terminals
    if pgrep -f "scripts/monitor/cron_visual_sweep.sh" &>/dev/null; then
        return 0
    fi

    if ! cron_is_gui_available || [ "$CRON_POPUP_TERMINAL" -ne 1 ]; then
        cron_run_visual_sweep "$sweep_type"
        return $?
    fi

    local distro="${WSL_DISTRO_NAME:-ubuntu-local}"
    local pos="${CRON_POPUP_POS:-1200,40}"
    local size="${CRON_POPUP_SIZE:-85,22}"
    local hold="${CRON_POPUP_HOLD_ON_ERROR:-1}"

    popup_terminal_launch "George Autonomic Sentinel" "$size" \
        bash ./scripts/monitor/cron_visual_sweep.sh "$sweep_type" "$hold"
    return 0
}

cron_sweep_stale_daemons() {
    local auth_pid="${1:-}"
    [ -z "$auth_pid" ] && [ -f "$CRON_PID_FILE" ] && auth_pid=$(cat "$CRON_PID_FILE" 2>/dev/null)

    # Never sweep blindly if no authoritative PID exists
    [ -z "$auth_pid" ] && return 0

    local pids
    pids=$(pgrep -f "_cron_loop_runner" 2>/dev/null || true)
    local p
    for p in $pids; do
        [ "$p" = "$$" ] && continue
        [ "$p" = "$auth_pid" ] && continue
        # Walk the full ancestry: forked job subshells inherit the daemon argv,
        # so anything below the authoritative daemon (or below us) is a live job.
        local anc="$p" skip=0 hops=0
        while [ -n "$anc" ] && [ "$anc" -gt 1 ] 2>/dev/null && [ "$hops" -lt 64 ]; do
            anc=$(ps -o ppid= -p "$anc" 2>/dev/null | tr -d ' ')
            if [ "$anc" = "$auth_pid" ] || [ "$anc" = "$$" ] || [ "$anc" = "${BASHPID:-$$}" ]; then
                skip=1; break
            fi
            hops=$((hops + 1))
        done
        [ "$skip" -eq 1 ] && continue
        # Only reap leaders of a competing daemon, not its forked children.
        local parent
        parent=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
        if [ -n "$parent" ] && tr '\0' ' ' < "/proc/$parent/cmdline" 2>/dev/null | grep -q "_cron_loop_runner"; then
            continue
        fi
        kill -9 "$p" 2>/dev/null || true
    done
}

_cron_loop_runner() {
    export LODGE_NONINTERACTIVE=1
    echo "$$" > "$CRON_PID_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] George Autonomic Daemon started (PID $$)" >> "$CRON_LOG_FILE"
    trap 'echo "[$(date "+%Y-%m-%d %H:%M:%S")] Daemon PID $$ received SIGTERM/SIGINT" >> "$CRON_LOG_FILE"; rm -f "$CRON_PID_FILE"; exit 0' SIGTERM SIGINT
    trap 'echo "[$(date "+%Y-%m-%d %H:%M:%S")] Daemon PID $$ received SIGHUP" >> "$CRON_LOG_FILE"' SIGHUP
    trap 'echo "[$(date "+%Y-%m-%d %H:%M:%S")] Daemon PID $$ EXIT triggered (code $?)" >> "$CRON_LOG_FILE"' EXIT
    source "$LODGE_DIR/lib/sys/heartbeats.sh" 2>/dev/null || true

    local last_popup=0
    while true; do
        # Verify this process is still the authoritative daemon
        if [ -f "$CRON_PID_FILE" ]; then
            local active_pid
            active_pid=$(cat "$CRON_PID_FILE" 2>/dev/null)
            if [ -n "$active_pid" ] && [ "$active_pid" != "$$" ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Newer daemon PID $active_pid detected. Superceded daemon $$ exiting." >> "$CRON_LOG_FILE"
                exit 0
            fi
        fi

        local now
        now=$(date +%s)

        if [ "$CRON_POPUP_TERMINAL" -eq 1 ] && cron_is_gui_available; then
            if [ $((now - last_popup)) -ge "$CRON_INTERVAL_POPUP" ]; then
                cron_launch_visual "all" >> "$CRON_LOG_FILE" 2>&1
                last_popup="$now"
            fi
        fi

        # Log rotation check (keep cron.log under 2MB / tail last 2000 lines)
        if [ -f "$CRON_LOG_FILE" ]; then
            local _log_sz
            _log_sz=$(stat -c%s "$CRON_LOG_FILE" 2>/dev/null || echo 0)
            if [ "$_log_sz" -gt 2097152 ]; then
                local _tmp_log="${CRON_LOG_FILE}.tmp.$$"
                tail -n 2000 "$CRON_LOG_FILE" > "$_tmp_log" 2>/dev/null && mv "$_tmp_log" "$CRON_LOG_FILE" || true
            fi
        fi

        # Isolate tick in protected subshell to prevent fatal daemon exits
        ( cron_tick ) >> "$CRON_LOG_FILE" 2>&1 || true
        declare -f heartbeat_write &>/dev/null && heartbeat_write cron || true
        sleep 5
    done
}

# cron_optout [on|off|status] [reason...] — canonical operator off-switch for the
# Autonomic Cron Daemon. 'on' writes the flag (sentinel + cron_start honor it),
# 'off' clears it, 'status' reports. Web workbench Start/Restart pass --force to
# cron_start, which clears the flag on explicit operator action.
cron_optout() {
    cron_init
    local action="${1:-status}"
    case "$action" in
        on|disable) shift
            {
                printf '# George Autonomic Cron Daemon opt-out (delete or: cron_optout off)\n'
                printf 'requested_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                [ $# -gt 0 ] && printf 'reason: %s\n' "$*"
            } > "$GEORGE_DIR/.cron_optout"
            ui_ok "Autonomic Cron Daemon opt-out recorded. Resume with 'cron_optout off' or 'cron_start --force'."
            ;;
        off|enable)
            rm -f "$GEORGE_DIR/.cron_optout"
            ui_ok "Autonomic Cron Daemon opt-out cleared."
            ;;
        status)
            if [ -f "$GEORGE_DIR/.cron_optout" ]; then
                ui_warn "Opt-out active: $(tr '\n' ' ' < "$GEORGE_DIR/.cron_optout" 2>/dev/null)"
                return 1
            else
                ui_ok "No opt-out. Autonomic Cron Daemon may run."
            fi
            ;;
        *)
            ui_err "Usage: cron_optout [on|off|status] [reason...]"
            return 1
            ;;
    esac
}

cron_start() {
    local force=0
    [ "${1:-}" = "--force" ] && force=1
    cron_init
    # Sweep stale daemons BEFORE the opt-out guard so orphaned loop runners are
    # always reaped, even while the daemon is opted out.
    cron_sweep_stale_daemons
    if [ -f "$GEORGE_DIR/.cron_optout" ]; then
        if [ "$force" -eq 1 ]; then
            rm -f "$GEORGE_DIR/.cron_optout"
            ui_warn "Explicit operator start: clearing .george/.cron_optout and resuming the daemon."
        else
            ui_warn "George Autonomic Daemon is opted out by operator (.george/.cron_optout). Refusing to start. (Override: cron_start --force)"
            return 1
        fi
    fi
    if [ -f "$CRON_PID_FILE" ]; then
        local pid
        pid=$(cat "$CRON_PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            ui_warn "George Autonomic Daemon is already running (PID $pid)."
            return 0
        fi
        rm -f "$CRON_PID_FILE" 2>/dev/null
    fi

    # Launch non-blocking daemon runner in a new session detached from process group
    if command -v setsid &>/dev/null; then
        setsid bash -c "source '$LODGE_DIR/lib/sys/cron.sh' && _cron_loop_runner" </dev/null >> "$CRON_LOG_FILE" 2>&1 &
    else
        nohup bash -c "source '$LODGE_DIR/lib/sys/cron.sh' && _cron_loop_runner" </dev/null >> "$CRON_LOG_FILE" 2>&1 &
    fi
    local new_pid=$!
    disown "$new_pid" 2>/dev/null || true

    sleep 1
    local check_pid
    check_pid=$(cat "$CRON_PID_FILE" 2>/dev/null)
    if [ -n "$check_pid" ] && kill -0 "$check_pid" 2>/dev/null; then
        ui_ok "George Autonomic Daemon started successfully (PID $check_pid)."
        ui_dim "  Log: $CRON_LOG_FILE"
        return 0
    else
        ui_err "Failed to start George Autonomic Daemon."
        return 1
    fi
}

cron_stop() {
    cron_init
    if [ -f "$CRON_PID_FILE" ]; then
        local pid
        pid=$(cat "$CRON_PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
            rm -f "$CRON_PID_FILE" 2>/dev/null
            cron_sweep_stale_daemons
            ui_ok "George Autonomic Daemon (PID $pid) stopped."
            return 0
        fi
        rm -f "$CRON_PID_FILE" 2>/dev/null
    fi
    cron_sweep_stale_daemons
    ui_info "George Autonomic Daemon is not currently running."
}

cron_status() {
    cron_init
    ui_section "George Autonomic Life & Cron Status"

    local is_running=0 pid=""
    if [ -f "$CRON_PID_FILE" ]; then
        pid=$(cat "$CRON_PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            is_running=1
        else
            rm -f "$CRON_PID_FILE" 2>/dev/null || true
            pid=""
        fi
    fi

    if [ "$is_running" -eq 1 ]; then
        printf "  Daemon:      %b● RUNNING%b (PID %s)\n" "$C_GREEN" "$C_RESET" "$pid"
    else
        printf "  Daemon:      %b○ STOPPED%b\n" "$C_DIM" "$C_RESET"
    fi

    printf "  Log File:    %s\n" "$CRON_LOG_FILE"
    printf "  State File:  %s\n" "$CRON_STATE_FILE"
    echo ""

    ui_step "Registered Autonomic Sweeps & Schedules:"
    for j in "sentinel_sweep" "pr_sweep" "issue_sweep" "ci_sweep" "discord_sweep" "email_sweep" "x_social_sweep" "mastodon_sweep"; do
        local iv desc
        case "$j" in
            sentinel_sweep) iv="$CRON_INTERVAL_SENTINEL"; desc="Hardware vitals, orphaned processes, and slot triage" ;;
            pr_sweep) iv="$CRON_INTERVAL_PR"; desc="PR Audit, auto-merge, and regression re-attempts" ;;
            issue_sweep) iv="$CRON_INTERVAL_ISSUE"; desc="Tripped circuit breaker and subagent escalation fixes" ;;
            ci_sweep) iv="$CRON_INTERVAL_CI"; desc="Gitea Actions CI failure watchdog and remediation intake" ;;
            discord_sweep) iv="$CRON_INTERVAL_DISCORD"; desc="Discord DMs and server bot @mentions check" ;;
            email_sweep) iv="$CRON_INTERVAL_EMAIL"; desc="Configured email inbox sweep" ;;
            x_social_sweep) iv="$CRON_INTERVAL_X"; desc="X/Twitter mentions, engagement, and monetization queue" ;;
            mastodon_sweep) iv="$CRON_INTERVAL_MASTODON"; desc="Mastodon mentions, notifications, and queue sweep" ;;
        esac
        local last_run
        last_run=$(_cron_get_last_run "$j")
        local lr_str="never"
        if [ "$last_run" -gt 0 ]; then
            local ago=$(( $(date +%s) - last_run ))
            lr_str="${ago}s ago"
        fi
        local en_badge
        if cron_is_job_enabled "$j"; then
            en_badge="${C_GREEN}[ENABLED]${C_RESET}"
        else
            en_badge="${C_DIM}[DISABLED]${C_RESET}"
        fi
        printf "  %b %b%-16s%b every %-4ss (last: %-10s) — %s\n" \
            "$en_badge" "$C_CYAN" "$j" "$C_RESET" "$iv" "$lr_str" "$desc"
    done

    # List custom jobs
    if [ -d "$CRON_JOBS_DIR" ]; then
        local custom_found=0
        for cscript in "$CRON_JOBS_DIR"/*.sh; do
            [ -f "$cscript" ] || continue
            if [ "$custom_found" -eq 0 ]; then
                echo ""
                ui_step "Registered Custom Operator Jobs:"
                custom_found=1
            fi
            local cjob civ cdesc
            cjob=$(basename "$cscript" .sh)
            civ=$(grep -m1 '^# INTERVAL:' "$cscript" 2>/dev/null | awk '{print $3}')
            civ="${civ:-300}"
            cdesc=$(grep -m1 '^# DESC:' "$cscript" 2>/dev/null | sed 's/^# DESC: //')
            [ -z "$cdesc" ] && cdesc=$(grep -m1 '^# DESCRIPTION:' "$cscript" 2>/dev/null | sed 's/^# DESCRIPTION: //')
            local last_c
            last_c=$(_cron_get_last_run "$cjob")
            local lr_str="never"
            if [ "$last_c" -gt 0 ]; then
                local ago=$(( $(date +%s) - last_c ))
                lr_str="${ago}s ago"
            fi
            local c_en_badge
            if cron_is_job_enabled "$cjob"; then
                c_en_badge="${C_GREEN}[ENABLED]${C_RESET}"
            else
                c_en_badge="${C_DIM}[DISABLED]${C_RESET}"
            fi
            printf "  %b %b%-16s%b every %-4ss (last: %-10s) — %s\n" \
                "$c_en_badge" "$C_GREEN" "$cjob" "$C_RESET" "$civ" "$lr_str" "${cdesc:-Custom job}"
        done
    fi
}

cron_add_job() {
    local notify_hdr=""
    if [ "${1:-}" = "--notify" ]; then
        notify_hdr="# NOTIFY: escalate   (lines printed as 'ESCALATE: <text>' or 'ESCALATE(urgent): <text>' reach the operator)"
        shift
    fi
    local name="$1"
    local interval="$2"
    shift 2
    local cmd="$*"

    if [ -z "$name" ] || [ -z "$interval" ] || [ -z "$cmd" ]; then
        ui_err "Usage: /cron add [--notify] <name> <interval_seconds> <command...>"
        return 1
    fi

    cron_init
    mkdir -p "$CRON_JOBS_DIR" 2>/dev/null
    local target_file="$CRON_JOBS_DIR/${name}.sh"

    # Sovereign guard (issue #461): refuse commands that re-execute the job
    # file itself. A self-referential script recurses on every tick until
    # bash hits its SHLVL ceiling (1000) and fork fails with
    # "Resource temporarily unavailable" (exit 254, job_fail sentinel).
    case " ${cmd} " in
        *"${name}.sh"*)
            ui_err "Refusing to register self-referential job '${name}': command targets its own script file (${name}.sh) and would recurse infinitely."
            return 1
            ;;
    esac

    cat > "$target_file" << EOF
#!/bin/bash
# INTERVAL: ${interval}
# DESC: Custom operator cron job: ${name}
# CREATED: $(date '+%Y-%m-%d %H:%M:%S')
${notify_hdr}

${cmd}
EOF
    chmod +x "$target_file"
    ui_ok "Registered custom cron job '$name' (runs every ${interval}s)."
    ui_dim "  Script: $target_file"
    return 0
}

cron_remove_job() {
    local name="$1"
    if [ -z "$name" ]; then
        ui_err "Usage: /cron remove <name>"
        return 1
    fi

    cron_init
    local target_file="$CRON_JOBS_DIR/${name}.sh"
    if [ -f "$target_file" ]; then
        rm -f "$target_file"
        ui_ok "Removed custom cron job '$name'."
        return 0
    else
        ui_err "Custom cron job '$name' not found."
        return 1
    fi
}

cron_interactive_create() {
    ui_section "George Interactive Cron Job Builder"
    ui_dim "Let's build a scheduled autonomic job together."
    echo ""

    local job_name job_interval job_cmd
    read -r -p "  Job Name (e.g. x_history_blog): " job_name
    [ -z "$job_name" ] && { ui_err "Job name required."; return 1; }

    read -r -p "  Interval in seconds (e.g. 3600 for 1 hour): " job_interval
    job_interval="${job_interval:-3600}"

    read -r -p "  Command or slash action to run: " job_cmd
    [ -z "$job_cmd" ] && { ui_err "Command required."; return 1; }

    local x_pat='(x_|twitter|tweet)'
    if [[ "$job_cmd" =~ $x_pat ]]; then
        if [ -z "$(api_get_key "X_BEARER_TOKEN" 2>/dev/null)" ]; then
            ui_warn "This job interacts with X (Twitter), but X_BEARER_TOKEN is not yet set."
            read -r -p "  Enter X_BEARER_TOKEN (or press Enter to skip): " x_tok
            if [ -n "$x_tok" ]; then
                api_set_key "X_BEARER_TOKEN" "$x_tok" 2>/dev/null && ui_ok "X_BEARER_TOKEN configured."
            fi
        fi
    fi

    cron_add_job "$job_name" "$job_interval" "$job_cmd"
}

cron_run_once() {
    local target="$1"
    cron_init

    if [ -z "$target" ]; then
        ui_section "George Autonomic Job Trigger"
        ui_info "Specify a job or sweep to execute manually:"
        echo ""
        ui_step "Built-in Autonomic Sweeps:"
        echo "  • sentinel_sweep      - Hardware vitals, orphaned processes, and slot triage"
        echo "  • pr_sweep            - PR audit, auto-merge, and remediation"
        echo "  • issue_sweep         - Circuit breaker escalation and issue fixes"
        echo "  • ci_sweep            - Gitea Actions CI failure watchdog"
        echo "  • discord_sweep       - Discord mentions and DMs"
        echo "  • email_sweep         - Configured email inboxes"
        echo "  • x_social_sweep      - X/Twitter mentions & monetization sweep"
        echo "  • mastodon_sweep      - Mastodon mentions, notifications, and queue"
        echo "  • all                 - Run all built-in sweeps sequentially"
        echo ""
        if [ -d "$CRON_JOBS_DIR" ] && [ -n "$(ls -A "$CRON_JOBS_DIR" 2>/dev/null)" ]; then
            ui_step "Custom Operator Cron Jobs:"
            for cs in "$CRON_JOBS_DIR"/*.sh; do
                [ -f "$cs" ] || continue
                local cj cdesc civ
                cj=$(basename "$cs" .sh)
                cdesc=$(grep -m1 '^# DESC:' "$cs" 2>/dev/null | sed 's/^# DESC: //')
                [ -z "$cdesc" ] && cdesc=$(grep -m1 '^# DESCRIPTION:' "$cs" 2>/dev/null | sed 's/^# DESCRIPTION: //')
                civ=$(grep -m1 '^# INTERVAL:' "$cs" 2>/dev/null | awk '{print $3}')
                printf "  • %-20s (every %-5ss) — %s\n" "$cj" "${civ:-custom}" "${cdesc:-Operator custom script}"
            done
            echo ""
        fi
        ui_dim "Usage: /cron trigger <job_name>  OR  /cron run <job_name>"
        return 0
    fi

    target="${target%.sh}"
    ui_section "Executing Autonomic Sweep / Job: $target"

    case "$target" in
        all)
            cron_run_job "sentinel_sweep"
            cron_run_job "pr_sweep"
            cron_run_job "issue_sweep"
            cron_run_job "ci_sweep"
            cron_run_job "discord_sweep"
            cron_run_job "email_sweep"
            cron_run_job "x_social_sweep"
            cron_run_job "mastodon_sweep"
            ;;
        sentinel_sweep|sentinel)
            cron_run_job "sentinel_sweep"
            ;;
        pr_sweep|pr)
            cron_run_job "pr_sweep"
            ;;
        issue_sweep|issue|issues)
            cron_run_job "issue_sweep"
            ;;
        ci_sweep|ci)
            cron_run_job "ci_sweep"
            ;;
        discord_sweep|discord)
            cron_run_job "discord_sweep"
            ;;
        email_sweep|email)
            cron_run_job "email_sweep"
            ;;
        x_social_sweep|x|twitter)
            cron_run_job "x_social_sweep"
            ;;
        mastodon_sweep|mastodon|masto)
            cron_run_job "mastodon_sweep"
            ;;
        research|research_sweep|blog|blog_sweep)
            if [ -f "$CRON_JOBS_DIR/research_publisher.sh" ]; then
                cron_run_job "research_publisher"
            elif [ -f "$CRON_JOBS_DIR/x_blog_publisher.sh" ]; then
                cron_run_job "x_blog_publisher"
            else
                cron_run_job "research_sweep"
            fi
            ;;
        *)
            if [ -f "$CRON_JOBS_DIR/${target}.sh" ]; then
                cron_run_job "$target"
            else
                ui_err "Unknown sweep or cron job: '$target'"
                ui_info "Run '/cron trigger' without arguments to see available jobs."
                return 1
            fi
            ;;
    esac
}
