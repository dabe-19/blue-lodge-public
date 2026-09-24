#!/bin/bash
# DESC: Manage George's persistent life autonomic daemon and scheduled sweeps
# Usage: /cron [start|stop|status|run|list|logs] [target]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/cron.sh" 2>/dev/null || true

cmd_cron() {
    local args="$1"
    local workdir="${2:-.}"

    cron_init

    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        ""|status)
            cron_status
            ;;
        start)
            cron_start
            ;;
        stop)
            cron_stop
            ;;
        restart)
            cron_stop
            sleep 1
            cron_start
            ;;
        run|exec|trigger)
            cron_run_once "$rest"
            ;;
        list)
            cron_status
            ;;
        add)
            local jname="${rest%% *}"
            local jrest="${rest#"$jname"}"
            jrest="${jrest#"${jrest%%[![:space:]]*}"}"
            local jiv="${jrest%% *}"
            local jcmd="${jrest#"$jiv"}"
            jcmd="${jcmd#"${jcmd%%[![:space:]]*}"}"
            cron_add_job "$jname" "$jiv" "$jcmd"
            ;;
        enable)
            cron_enable_job "${rest%% *}"
            ;;
        disable)
            cron_disable_job "${rest%% *}"
            ;;
        toggle)
            cron_toggle_job "${rest%% *}"
            ;;
        remove|rm|delete)
            cron_remove_job "${rest%% *}"
            ;;
        create|wizard|new)
            cron_interactive_create
            ;;
        log|logs)
            if [ -f "$CRON_LOG_FILE" ]; then
                tail -n 30 "$CRON_LOG_FILE"
            else
                ui_info "No cron log file found at $CRON_LOG_FILE."
            fi
            ;;
        sentinel|watchdog|vitals)
            if declare -f sentinel_render_dashboard &>/dev/null; then
                sentinel_render_dashboard
            fi
            if declare -f sentinel_sweep &>/dev/null; then
                sentinel_sweep
            fi
            ;;
        popup|window)
            ui_info "Launching visual Windows Terminal sweep pop-up..."
            cron_launch_visual "${rest:-all}"
            ;;
        visual|sweep)
            cron_run_visual_sweep "${rest:-all}"
            ;;
        *)
            ui_err "Unknown /cron command: '$subcmd'"
            ui_info "Usage: /cron [start|stop|restart|status|sentinel|popup|visual|run <job>|add <name> <iv> <cmd>|remove <name>|enable <name>|disable <name>|toggle <name>|logs]"
            return 1
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cmd_cron "$*"
fi
