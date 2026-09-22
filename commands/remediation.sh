#!/bin/bash
# DESC: Sovereign Autonomous Remediation Loop & Notification Manager
# Usage: /remediation [queue|run [id]|notify [show|set <k> <v>]|sweep|help]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/remediation.sh" 2>/dev/null || true

cmd_remediation() {
    local args="$1"
    local workdir="${2:-.}"

    remediation_init

    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        ""|queue|list|ls)
            remediation_queue_list
            ;;
        run|start|exec)
            remediation_run "$rest"
            ;;
        notify|conf|config)
            local n_sub="${rest%% *}"
            local n_rest="${rest#"$n_sub"}"
            n_rest="${n_rest#"${n_rest%%[![:space:]]*}"}"

            case "$n_sub" in
                ""|show|get)
                    remediation_notify_show
                    ;;
                set)
                    local k="${n_rest%% *}"
                    local v="${n_rest#"$k"}"
                    v="${v#"${v%%[![:space:]]*}"}"
                    if [ -z "$k" ] || [ -z "$v" ]; then
                        ui_err "Usage: /remediation notify set <email|provider|discord|server|channel|enabled> <val>"
                        return 1
                    fi
                    remediation_notify_set "$k" "$v"
                    ;;
                clear|unset|reset)
                    local k="${n_rest%% *}"
                    if [ -z "$k" ]; then
                        ui_err "Usage: /remediation notify clear <email|discord|server|channel>"
                        return 1
                    fi
                    remediation_notify_set "$k" ""
                    ;;
                test)
                    ui_step "Testing remediation notification channels..."
                    remediation_notify_dispatch "test_task" "Diagnostic Notification Test" "TEST" \
                        "This is an automated test from /remediation notify test."
                    ui_ok "Test notifications dispatched."
                    ;;
                *)
                    ui_err "Unknown notify command: $n_sub (valid: show, set, clear, test)"
                    return 1
                    ;;
            esac
            ;;
        sweep)
            ui_step "Sweeping issues for unqueued remediation tasks..."
            local issues_dir="${GEORGE_DIR:-$LODGE_DIR/.george}/issues"
            local queued_count=0
            if [ -d "$issues_dir" ]; then
                for isf in "$issues_dir"/*.md; do
                    [ ! -f "$isf" ] && continue
                    local fp
                    fp=$(grep -o '\[fingerprint:[a-f0-9]*\]' "$isf" | head -n 1 | cut -d':' -f2 | tr -d ']')
                    # Check if already in queue, progress, or completed
                    local already=0
                    if [ -n "$fp" ]; then
                        grep -q "\"fingerprint\": \"$fp\"" "$REMEDIATION_QUEUE_DIR"/*.json "$REMEDIATION_PROGRESS_DIR"/*.json "$REMEDIATION_COMPLETED_DIR"/*.json 2>/dev/null && already=1
                    fi
                    if [ "$already" -eq 0 ]; then
                        remediation_queue_add "$isf" "" "normal" >/dev/null 2>&1
                        queued_count=$((queued_count + 1))
                    fi
                done
            fi
            ui_ok "Remediation sweep complete: $queued_count new task(s) enqueued."
            ;;
        help|-h|--help)
            ui_section "George Sovereign Autonomous Remediation"
            echo "Usage: /remediation <command> [args]"
            echo ""
            echo "Commands:"
            echo "  queue                         List pending, running, and completed remediation tasks"
            echo "  run [task_id]                 Execute remediation on Slot 1 in isolated worktree"
            echo "  notify [show]                 Display configured Email & Discord notification settings"
            echo "  notify set <key> <val>        Update configuration (email, provider, discord, server, channel, enabled)"
            echo "  notify clear <key>            Clear/unset a notification target"
            echo "  notify test                   Send test dispatch to configured Email and Discord"
            echo "  sweep                         Enforce queue alignment across all existing issues"
            echo "  help                          Show this help menu"
            return 0
            ;;
        *)
            ui_err "Unknown remediation command: $subcmd (try /remediation help)"
            return 1
            ;;
    esac
}
