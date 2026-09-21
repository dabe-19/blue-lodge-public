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

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/pr.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/alerts.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/social.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/email.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/sentinel.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/discord_bridge.sh" 2>/dev/null || true

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
                CRON_POPUP_TERMINAL) CRON_POPUP_TERMINAL="$val" ;;
                CRON_POPUP_POS) CRON_POPUP_POS="$val" ;;
                CRON_POPUP_SIZE) CRON_POPUP_SIZE="$val" ;;
                CRON_POPUP_HOLD_ON_ERROR) CRON_POPUP_HOLD_ON_ERROR="$val" ;;
            esac
        done < "$CRON_CONF_FILE"
    fi

    if [ ! -f "$CRON_STATE_FILE" ]; then
        echo '{"jobs":{}}' > "$CRON_STATE_FILE" 2>/dev/null || true
    fi
}

_cron_get_last_run() {
    local job_name="$1"
    [ -f "$CRON_STATE_FILE" ] || return 0
    jq -r ".jobs.\"$job_name\".last_run // 0" "$CRON_STATE_FILE" 2>/dev/null || echo 0
}

_cron_set_last_run() {
    local job_name="$1"
    local exit_code="${2:-0}"
    local now
    now=$(date +%s)
    local tmp="${CRON_STATE_FILE}.tmp.$$"
    if [ -f "$CRON_STATE_FILE" ]; then
        jq --arg j "$job_name" --argjson lr "$now" --argjson ec "$exit_code" \
            '.jobs[$j] = { "last_run": $lr, "exit_code": $ec, "updated_at": (now | todate) }' \
            "$CRON_STATE_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$CRON_STATE_FILE"
    fi
}

cron_run_job() {
    local job_name="$1"
    cron_init

    local res=0
    case "$job_name" in
        sentinel_sweep)
            declare -f sentinel_sweep &>/dev/null && sentinel_sweep || true
            res=$?
            ;;
        pr_sweep)
            declare -f pr_sweep &>/dev/null && pr_sweep || true
            res=$?
            ;;
        issue_sweep)
            declare -f alerts_sweep &>/dev/null && alerts_sweep || true
            res=$?
            ;;
        discord_sweep)
            if declare -f discord_bridge_sweep &>/dev/null; then
                discord_bridge_sweep || true
            elif declare -f discord_mentions_poll &>/dev/null; then
                discord_mentions_poll || true
            fi
            res=$?
            ;;
        email_sweep)
            declare -f email_sweep &>/dev/null && email_sweep || true
            res=$?
            ;;
        x_social_sweep)
            declare -f x_social_sweep &>/dev/null && x_social_sweep || true
            res=$?
            ;;
        research_sweep|blog_sweep)
            declare -f x_blog_sweep &>/dev/null && x_blog_sweep || true
            res=$?
            ;;
        mastodon_sweep)
            declare -f mastodon_social_sweep &>/dev/null && mastodon_social_sweep || true
            res=$?
            ;;
        *)
            local script_name="${job_name%.sh}"
            if [ -f "$CRON_JOBS_DIR/${script_name}.sh" ]; then
                ui_step "Executing custom cron job '$script_name'..."
                bash "$CRON_JOBS_DIR/${script_name}.sh"
                res=$?
            else
                ui_err "Unknown cron job: $job_name"
                return 1
            fi
            ;;
    esac

    _cron_set_last_run "$job_name" "$res"
    return "$res"
}

cron_tick() {
    cron_init
    local now
    now=$(date +%s)

    # 0. Sentinel Telemetry & Self-Healing Sweep
    local last_sentinel
    last_sentinel=$(_cron_get_last_run "sentinel_sweep")
    if [ $((now - last_sentinel)) -ge "$CRON_INTERVAL_SENTINEL" ]; then
        cron_run_job "sentinel_sweep"
    fi

    # 1. PR Sweep
    local last_pr
    last_pr=$(_cron_get_last_run "pr_sweep")
    if [ $((now - last_pr)) -ge "$CRON_INTERVAL_PR" ]; then
        cron_run_job "pr_sweep"
    fi

    # 2. Issue / Circuit Breaker Remediation Sweep
    local last_issue
    last_issue=$(_cron_get_last_run "issue_sweep")
    if [ $((now - last_issue)) -ge "$CRON_INTERVAL_ISSUE" ]; then
        cron_run_job "issue_sweep"
    fi

    # 3. Discord DM & Mention Sweep
    local last_discord
    last_discord=$(_cron_get_last_run "discord_sweep")
    if [ $((now - last_discord)) -ge "$CRON_INTERVAL_DISCORD" ]; then
        cron_run_job "discord_sweep"
    fi

    # 4. Email Sweep
    local last_email
    last_email=$(_cron_get_last_run "email_sweep")
    if [ $((now - last_email)) -ge "$CRON_INTERVAL_EMAIL" ]; then
        cron_run_job "email_sweep"
    fi

    # 5. X Social & Monetization Sweep
    local last_x
    last_x=$(_cron_get_last_run "x_social_sweep")
    if [ $((now - last_x)) -ge "$CRON_INTERVAL_X" ]; then
        cron_run_job "x_social_sweep"
    fi

    # 6. Mastodon Social & Mentions Sweep
    local last_mastodon
    last_mastodon=$(_cron_get_last_run "mastodon_sweep")
    if [ $((now - last_mastodon)) -ge "$CRON_INTERVAL_MASTODON" ]; then
        cron_run_job "mastodon_sweep"
    fi

    # 7. Custom Operator Jobs in $CRON_JOBS_DIR
    if [ -d "$CRON_JOBS_DIR" ]; then
        for cscript in "$CRON_JOBS_DIR"/*.sh; do
            [ -f "$cscript" ] || continue
            local cjob civ
            cjob=$(basename "$cscript" .sh)
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
    fi

    # 4. Social & Monetization Queue Sweep
    if [ "$sweep_type" = "all" ] || [ "$sweep_type" = "social" ]; then
        declare -f x_social_sweep &>/dev/null && x_social_sweep
        declare -f x_blog_sweep &>/dev/null && x_blog_sweep
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

    if ! cron_is_gui_available || [ "$CRON_POPUP_TERMINAL" -ne 1 ]; then
        cron_run_visual_sweep "$sweep_type"
        return $?
    fi

    local distro="${WSL_DISTRO_NAME:-ubuntu-local}"
    local pos="${CRON_POPUP_POS:-1200,40}"
    local size="${CRON_POPUP_SIZE:-85,22}"
    local hold="${CRON_POPUP_HOLD_ON_ERROR:-1}"

    wt.exe -w new --size "$size" \
        nt --title "George Autonomic Sentinel" \
        wsl.exe -d "$distro" --cd "$LODGE_DIR" \
        bash ./scripts/cron_visual_sweep.sh "$sweep_type" "$hold" 2>/dev/null &
    return 0
}

_cron_loop_runner() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] George Autonomic Daemon started (PID $$)" >> "$CRON_LOG_FILE"
    trap 'echo "[$(date "+%Y-%m-%d %H:%M:%S")] George Autonomic Daemon stopped (PID $$)" >> "$CRON_LOG_FILE"; rm -f "$CRON_PID_FILE"; exit 0' SIGTERM SIGINT

    local last_popup=0
    while true; do
        local now
        now=$(date +%s)

        if [ "$CRON_POPUP_TERMINAL" -eq 1 ] && cron_is_gui_available; then
            if [ $((now - last_popup)) -ge "$CRON_INTERVAL_POPUP" ]; then
                cron_launch_visual "all" >> "$CRON_LOG_FILE" 2>&1
                last_popup="$now"
            fi
        fi

        cron_tick >> "$CRON_LOG_FILE" 2>&1
        sleep 5
    done
}

cron_start() {
    cron_init
    if [ -f "$CRON_PID_FILE" ]; then
        local pid
        pid=$(cat "$CRON_PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            ui_warn "George Autonomic Daemon is already running (PID $pid)."
            return 0
        fi
        rm -f "$CRON_PID_FILE" 2>/dev/null
    fi

    # Launch non-blocking daemon runner
    (
        nohup bash -c "source '$LODGE_DIR/lib/cron.sh' && _cron_loop_runner" >> "$CRON_LOG_FILE" 2>&1 &
        echo "$!" > "$CRON_PID_FILE"
    )

    sleep 1
    local new_pid
    new_pid=$(cat "$CRON_PID_FILE" 2>/dev/null)
    if [ -n "$new_pid" ] && kill -0 "$new_pid" 2>/dev/null; then
        ui_ok "George Autonomic Daemon started successfully (PID $new_pid)."
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
            ui_ok "George Autonomic Daemon (PID $pid) stopped."
            return 0
        fi
        rm -f "$CRON_PID_FILE" 2>/dev/null
    fi
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
    for j in "sentinel_sweep" "pr_sweep" "issue_sweep" "discord_sweep" "email_sweep" "x_social_sweep" "mastodon_sweep"; do
        local iv desc
        case "$j" in
            sentinel_sweep) iv="$CRON_INTERVAL_SENTINEL"; desc="Hardware vitals, orphaned processes, and slot triage" ;;
            pr_sweep) iv="$CRON_INTERVAL_PR"; desc="PR Audit, auto-merge, and regression re-attempts" ;;
            issue_sweep) iv="$CRON_INTERVAL_ISSUE"; desc="Tripped circuit breaker and subagent escalation fixes" ;;
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
        printf "  %b%-16s%b every %-4ss (last: %-10s) — %s\n" \
            "$C_CYAN" "$j" "$C_RESET" "$iv" "$lr_str" "$desc"
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
            printf "  %b%-16s%b every %-4ss (last: %-10s) — %s\n" \
                "$C_GREEN" "$cjob" "$C_RESET" "$civ" "$lr_str" "${cdesc:-Custom job}"
        done
    fi
}

cron_add_job() {
    local name="$1"
    local interval="$2"
    shift 2
    local cmd="$*"

    if [ -z "$name" ] || [ -z "$interval" ] || [ -z "$cmd" ]; then
        ui_err "Usage: /cron add <name> <interval_seconds> <command...>"
        return 1
    fi

    cron_init
    mkdir -p "$CRON_JOBS_DIR" 2>/dev/null
    local target_file="$CRON_JOBS_DIR/${name}.sh"

    cat > "$target_file" << EOF
#!/bin/bash
# INTERVAL: ${interval}
# DESC: Custom operator cron job: ${name}
# CREATED: $(date '+%Y-%m-%d %H:%M:%S')

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
        echo "  • pr_sweep            - PR audit, auto-merge, and remediation"
        echo "  • issue_sweep         - Circuit breaker escalation and issue fixes"
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
            cron_run_job "pr_sweep"
            cron_run_job "issue_sweep"
            cron_run_job "discord_sweep"
            cron_run_job "email_sweep"
            cron_run_job "x_social_sweep"
            cron_run_job "mastodon_sweep"
            ;;
        pr_sweep|pr)
            cron_run_job "pr_sweep"
            ;;
        issue_sweep|issue|issues)
            cron_run_job "issue_sweep"
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
