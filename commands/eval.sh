#!/bin/bash
# DESC: Golden-task eval control: on/off kill switch, status, run smoke|full, nightly toggle
# Usage: /eval status | off [reason] | on | run [smoke|full] | nightly on|off

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true

_eval_george_dir() { echo "${GEORGE_DIR:-$LODGE_DIR/.george}"; }

cmd_eval() {
    # Dispatcher convention: $1 = whole argument string, $2 = workdir (ignored).
    local -a _argv=(); read -r -a _argv <<< "${1:-}"
    set -- "${_argv[@]}"
    local sub="${1:-status}"; shift 2>/dev/null || true
    local gd flag pidf nightly
    gd=$(_eval_george_dir)
    flag="$gd/state/eval.disabled"
    pidf="$gd/eval/.harness.pid"
    nightly="$gd/cron_jobs/nightly_golden_eval.sh"
    mkdir -p "$gd/state"

    case "$sub" in
        off|disable)
            local reason="${*:-disabled by operator}"
            reason=$(printf '%s' "$reason" | tr -cd '[:alnum:] ._,:/()-' | head -c 160)
            printf '%s (%s)\n' "$reason" "$(date -Iseconds)" > "$flag"
            ui_ok "Evals disabled. Harness and nightly job will no-op (override: run_golden.sh --force)."
            local pid; pid=$(cat "$pidf" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                ui_warn "An eval is running now (pid $pid). Stop it with: /eval stop"
            fi
            ;;
        on|enable)
            rm -f "$flag"
            ui_ok "Evals enabled."
            ;;
        stop)
            local pid; pid=$(cat "$pidf" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
                ui_ok "Sent TERM to eval harness (pid $pid); it restores cron state on exit."
            else
                ui_info "No eval running."
            fi
            ;;
        run)
            local tier="${1:-smoke}"
            case "$tier" in smoke|full) ;; *) ui_err "Usage: /eval run [smoke|full]"; return 1 ;; esac
            if [ -f "$flag" ]; then ui_err "Evals are disabled ($(cat "$flag")). Use /eval on first."; return 1; fi
            local pid; pid=$(cat "$pidf" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then ui_err "An eval is already running (pid $pid)."; return 1; fi
            mkdir -p "$gd/eval"
            setsid nohup bash "$LODGE_DIR/tests/eval/run_golden.sh" --tier "$tier" --label "manual_$tier" \
                </dev/null >> "$gd/eval/manual.log" 2>&1 &
            ui_ok "Started $tier eval (pid $!). Log: $gd/eval/manual.log"
            ;;
        nightly)
            local mode="${1:-}"
            if [ ! -f "$nightly" ]; then
                if [ "$mode" = "on" ] && [ -f "$LODGE_DIR/scripts/cron/nightly_golden_eval.sh" ]; then
                    cp "$LODGE_DIR/scripts/cron/nightly_golden_eval.sh" "$nightly"
                else
                    ui_err "Nightly job not installed (scripts/cron/nightly_golden_eval.sh)."; return 1
                fi
            fi
            case "$mode" in
                on)  sed -i 's/^# ENABLED: .*/# ENABLED: 1/' "$nightly"; ui_ok "Nightly smoke eval enabled (03:00)." ;;
                off) sed -i 's/^# ENABLED: .*/# ENABLED: 0/' "$nightly"; ui_ok "Nightly eval disabled." ;;
                *)   ui_err "Usage: /eval nightly on|off"; return 1 ;;
            esac
            ;;
        status|"")
            if [ -f "$flag" ]; then echo "Evals: DISABLED — $(cat "$flag")"; else echo "Evals: enabled"; fi
            local en="not installed"
            [ -f "$nightly" ] && en=$(grep -m1 '^# ENABLED:' "$nightly" | awk '{print ($3=="1")?"on (03:00, smoke)":"off"}')
            echo "Nightly: $en"
            local pid; pid=$(cat "$pidf" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                echo "Running: pid $pid"
            else
                echo "Running: no"
            fi
            local last; last=$(ls -1dt "$gd"/eval/2*/ 2>/dev/null | head -1)
            if [ -n "$last" ] && [ -f "$last/metrics.json" ]; then
                jq -r --arg d "$(basename "$last")" '"Last: \($d) — success \(.success_rate * 100 | floor)% of \(.n) tasks, \(.wall_s_total|floor)s"' "$last/metrics.json" 2>/dev/null
            elif [ -n "$last" ]; then
                echo "Last: $(basename "$last") (in progress or unscored)"
            fi
            ;;
        *)
            ui_err "Usage: /eval status | off [reason] | on | stop | run [smoke|full] | nightly on|off"; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_eval "$*"
fi
