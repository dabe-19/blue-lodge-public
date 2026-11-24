#!/bin/bash
# DESC: Sovereign Telemetry & Anomaly Ring Inspector
# Usage: /telemetry [active|incidents|dump <task_id> [--raw]|help]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agents/telemetry.sh" 2>/dev/null || true

_telemetry_progressbar() {
    local pct="${1:-0}"
    local width="${2:-16}"
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar=""
    local i
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    printf "[%s] %3d%%" "$bar" "$pct"
}

_telemetry_render_active() {
    ui_section "George Sovereign Telemetry Ring: Active Tasks"
    local raw_json
    raw_json=$(telemetry_active_list)

    local count
    count=$(echo "$raw_json" | jq '. | length' 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then
        ui_dim "No active tasks currently registered in the telemetry ring."
        echo ""
        printf "  %b💡 Tip:%b Launch tasks via %b/react <goal>%b, %b/research start%b, or background with %b&%b.\n" \
            "$C_GOLD" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_GREEN" "$C_RESET"
        return 0
    fi

    local now
    now=$(date +%s)

    local i
    for ((i=0; i<count; i++)); do
        local task
        task=$(echo "$raw_json" | jq -c ".[$i]" 2>/dev/null)
        local tid st ttype workdir start_ts turn max_t pty_pid c_tok comp_tok comp_pct
        tid=$(echo "$task" | jq -r '.task_id // empty')
        st=$(echo "$task" | jq -r '.status // "RUNNING"')
        ttype=$(echo "$task" | jq -r '.type // "task"')
        workdir=$(echo "$task" | jq -r '.workdir // "."')
        start_ts=$(echo "$task" | jq -r '.started_ts // 0')
        turn=$(echo "$task" | jq -r '.turn // 0')
        max_t=$(echo "$task" | jq -r '.max_turns // 0')
        pty_pid=$(echo "$task" | jq -r '.pty_pid // empty')
        c_tok=$(echo "$task" | jq -r '.context_tokens // 0')
        comp_tok=$(echo "$task" | jq -r '.compaction_tokens // 0')
        comp_pct=$(echo "$task" | jq -r '.compaction_pct // 0')

        local elapsed=0
        if [ "$start_ts" -gt 0 ]; then
            elapsed=$(( now - start_ts ))
        fi

        local st_badge="${C_GREEN}[RUNNING]${C_RESET}"
        [ "$st" != "RUNNING" ] && st_badge="${C_YELLOW}[$st]${C_RESET}"

        local tpid
        tpid=$(echo "$task" | jq -r '.pid // .pty_pid // empty')
        local pid_str=""
        if [ -n "$tpid" ] && [ "$tpid" != "0" ] && [ "$tpid" != "null" ]; then
            pid_str=" (PID: $tpid)"
        elif [ -n "$pty_pid" ] && [ "$pty_pid" != "0" ] && [ "$pty_pid" != "null" ]; then
            pid_str=" (PID: $pty_pid)"
        fi

        printf "  %b %b%-24s%b%s  elapsed: %ds\n" \
            "$st_badge" "$C_BOLD$C_WHITE" "$tid" "$C_RESET" "$pid_str" "$elapsed"
        printf "     %bType:%b %-10s  %bTurn:%b %s/%s  %bTokens:%b %s/%s (%d%%)\n" \
            "$C_DIM" "$C_RESET" "$ttype" \
            "$C_DIM" "$C_RESET" "$turn" "${max_t:-∞}" \
            "$C_DIM" "$C_RESET" "$c_tok" "${comp_tok:-0}" "$comp_pct"
        printf "     %bWorkdir:%b %s\n" "$C_DIM" "$C_RESET" "$workdir"

        # Check for active asynchronous tool calls
        local active_tools
        active_tools=$(echo "$task" | jq -c '.active_tools // {}' 2>/dev/null)
        local t_count
        t_count=$(echo "$active_tools" | jq 'keys | length' 2>/dev/null || echo 0)

        if [ "$t_count" -gt 0 ]; then
            printf "     %bActive Asynchronous Tool Calls [%d]:%b\n" "$C_CYAN" "$t_count" "$C_RESET"
            local t_keys
            t_keys=$(echo "$active_tools" | jq -r 'keys[]' 2>/dev/null)
            local k_idx=0
            for k in $t_keys; do
                k_idx=$((k_idx + 1))
                local prefix="├─"
                [ "$k_idx" -eq "$t_count" ] && prefix="└─"

                local t_entry
                t_entry=$(echo "$active_tools" | jq -c ".\"$k\"" 2>/dev/null)
                local t_name t_status t_pct t_msg t_start
                t_name=$(echo "$t_entry" | jq -r '.tool // "tool"')
                t_status=$(echo "$t_entry" | jq -r '.status // "RUNNING"')
                t_pct=$(echo "$t_entry" | jq -r '.percent // 0')
                t_msg=$(echo "$t_entry" | jq -r '.message // ""')
                t_start=$(echo "$t_entry" | jq -r '.start_epoch // 0')

                local t_elapsed=0
                [ "$t_start" -gt 0 ] && t_elapsed=$(( now - t_start ))

                local pbar
                pbar=$(_telemetry_progressbar "$t_pct" 12)

                printf "     %b %b⚙ %s%b (%s) %b %s [%ds elapsed]\n" \
                    "$prefix" "$C_GOLD" "$t_name" "$C_RESET" "$k" \
                    "${C_GREEN}[$t_status]${C_RESET}" "$pbar" "$t_elapsed"
                if [ -n "$t_msg" ]; then
                    local sub_prefix="│ "
                    [ "$k_idx" -eq "$t_count" ] && sub_prefix="  "
                    printf "     %s   %bProgress:%b %s\n" "$sub_prefix" "$C_DIM" "$C_RESET" "$t_msg"
                fi
            done
        else
            printf "     %bActive Tools:%b (idle / synthesizing)\n" "$C_DIM" "$C_RESET"
        fi
        echo ""
    done
}

_telemetry_render_dump() {
    local tid="$1"
    local raw_flag="${2:-}"

    local ev_file="${TELEMETRY_ACTIVE_DIR}/${tid}.events.jsonl"
    if [ ! -f "$ev_file" ]; then
        ev_file=$(find "$TELEMETRY_ARCHIVE_DIR" -name "${tid}.events.jsonl" 2>/dev/null | head -n 1)
    fi

    if [ -z "$ev_file" ] || [ ! -f "$ev_file" ]; then
        ui_err "No telemetry events found for task: $tid"
        return 1
    fi

    if [ "$raw_flag" = "--raw" ] || [ "$raw_flag" = "--json" ]; then
        cat "$ev_file"
        return 0
    fi

    ui_section "Telemetry Event Stream: $tid"
    printf "  %bEvent Log:%b %s\n\n" "$C_DIM" "$C_RESET" "$ev_file"

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if ! echo "$line" | jq -e . >/dev/null 2>&1; then
            continue
        fi
        local ev_type ts epoch tool cid pct msg ec dur bytes pref st
        ev_type=$(echo "$line" | jq -r '.event_type // .class // "EVENT"' 2>/dev/null)
        ts=$(echo "$line" | jq -r '.timestamp // empty' 2>/dev/null)
        # Extract HH:MM:SS from ISO timestamp
        local time_str
        time_str=$(echo "$ts" | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}' || echo "$ts")

        case "$ev_type" in
            TOOL_START)
                tool=$(echo "$line" | jq -r '.tool // empty')
                cid=$(echo "$line" | jq -r '.call_id // empty')
                local chan
                chan=$(echo "$line" | jq -r '.channel // empty')
                local args
                args=$(echo "$line" | jq -r '.args // "{}"' 2>/dev/null)
                printf "  %b[%s]%b %b%-13s%b %b%s%b (%s)\n" \
                    "$C_DIM" "$time_str" "$C_RESET" \
                    "$C_CYAN" "[TOOL_START]" "$C_RESET" \
                    "$C_BOLD$C_WHITE" "$tool" "$C_RESET" "$cid"
                [ -n "$chan" ] && printf "           %bchannel:%b %s\n" "$C_DIM" "$C_RESET" "$chan"
                if [ -n "$args" ] && [ "$args" != "{}" ]; then
                    local flat_args
                    flat_args=$(echo "$args" | tr '\n\r\t' ' ' | tr -s ' ')
                    local trim_args="${flat_args:0:90}"
                    [ "${#flat_args}" -gt 90 ] && trim_args="${trim_args}..."
                    printf "           %bargs:%b    %s\n" "$C_DIM" "$C_RESET" "$trim_args"
                fi
                ;;
            TOOL_PROGRESS)
                cid=$(echo "$line" | jq -r '.call_id // empty')
                pct=$(echo "$line" | jq -r '.percent // 0')
                msg=$(echo "$line" | jq -r '.message // empty')
                local pbar
                pbar=$(_telemetry_progressbar "$pct" 12)
                printf "  %b[%s]%b %b%-13s%b %-12s %s %b%s%b\n" \
                    "$C_DIM" "$time_str" "$C_RESET" \
                    "$C_YELLOW" "[TOOL_PROG]" "$C_RESET" \
                    "$cid" "$pbar" \
                    "$C_WHITE" "$msg" "$C_RESET"
                ;;
            TOOL_END)
                tool=$(echo "$line" | jq -r '.tool // empty')
                cid=$(echo "$line" | jq -r '.call_id // empty')
                st=$(echo "$line" | jq -r '.status // "COMPLETED"')
                ec=$(echo "$line" | jq -r '.exit_code // 0')
                dur=$(echo "$line" | jq -r '.duration_ms // 0')
                bytes=$(echo "$line" | jq -r '.size_bytes // 0')
                pref=$(echo "$line" | jq -r '.payload_ref // empty')

                local badge="${C_GREEN}[TOOL_OK]${C_RESET}     "
                if [ "$ec" -ne 0 ]; then
                    badge="${C_RED}[TOOL_FAIL]${C_RESET}   "
                fi

                local sz_str=""
                if [ "$bytes" -ge 1048576 ]; then
                    sz_str="$(awk "BEGIN {printf \"%.1f MB\", $bytes/1048576}")"
                elif [ "$bytes" -ge 1024 ]; then
                    sz_str="$(awk "BEGIN {printf \"%.1f KB\", $bytes/1024}")"
                else
                    sz_str="${bytes}B"
                fi

                printf "  %b[%s]%b %b %b%-16s%b (%s) %sms | %s (exit %s)\n" \
                    "$C_DIM" "$time_str" "$C_RESET" \
                    "$badge" \
                    "$C_BOLD$C_WHITE" "$tool" "$C_RESET" \
                    "$cid" "$dur" "$sz_str" "$ec"
                if [ -n "$pref" ]; then
                    printf "           %bspillover payload:%b %s\n" "$C_DIM" "$C_RESET" "$pref"
                fi
                ;;
            *)
                # Anomaly or general telemetry event
                local aclass subsys amsg
                aclass=$(echo "$line" | jq -r '.class // "ANOMALY"')
                subsys=$(echo "$line" | jq -r '.subsystem // "core"')
                amsg=$(echo "$line" | jq -r '.message // ""')
                printf "  %b[%s]%b %b[%-13s]%b [%s] %s\n" \
                    "$C_DIM" "$time_str" "$C_RESET" \
                    "$C_RED" "$aclass" "$C_RESET" \
                    "$subsys" "$amsg"
                ;;
        esac
    done < "$ev_file"
}

_telemetry_render_incidents() {
    ui_section "George Sovereign Telemetry Ring: Preserved Incidents"
    local raw_json
    raw_json=$(telemetry_incidents_list)

    local count
    count=$(echo "$raw_json" | jq '. | length' 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then
        ui_dim "No diagnostic incident dossiers currently preserved in .george/telemetry/incidents/."
        return 0
    fi

    printf "  %b%-20s %-14s %-12s %s%b\n" "$C_BOLD$C_CYAN" "INCIDENT ID" "TIMESTAMP" "CLASS" "SUMMARY" "$C_RESET"
    printf "  %s\n" "$(printf '─%.0s' $(seq 1 76))"

    local i
    for ((i=0; i<count; i++)); do
        local inc
        inc=$(echo "$raw_json" | jq -c ".[$i]" 2>/dev/null)
        local iid its icls isum
        iid=$(echo "$inc" | jq -r '.incident_id // empty')
        its=$(echo "$inc" | jq -r '.timestamp // empty')
        icls=$(echo "$inc" | jq -r '.anomaly_class // "UNKNOWN"')
        isum=$(echo "$inc" | jq -r '.summary // ""')

        local ts_clean
        ts_clean=$(echo "$its" | cut -d'T' -f1)

        printf "  %-20s %-14s %b%-12s%b %s\n" \
            "$iid" "$ts_clean" "$C_RED" "$icls" "$C_RESET" "${isum:0:36}"
    done
}

cmd_telemetry() {
    local args="$1"
    local workdir="${2:-.}"

    telemetry_init

    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        ""|active|ls|status)
            _telemetry_render_active
            ;;
        incidents|inc)
            _telemetry_render_incidents
            ;;
        dump|events|log|stream)
            if [ -z "$rest" ]; then
                ui_err "Task ID required: /telemetry dump <task_id> [--raw]"
                return 1
            fi
            local target_tid="${rest%% *}"
            local flag="${rest#"$target_tid"}"
            flag="${flag#"${flag%%[![:space:]]*}"}"
            _telemetry_render_dump "$target_tid" "$flag"
            ;;
        gc|prune)
            local pruned
            pruned=$(telemetry_gc 7 20)
            ui_ok "Telemetry ring cleaned: pruned $pruned stale incident dossiers."
            ;;
        help|-h|--help)
            ui_section "George Sovereign Telemetry Ring"
            echo "Usage: /telemetry <command> [args]"
            echo ""
            echo "Commands:"
            echo "  active                List active tasks with live asynchronous tool calls & progress"
            echo "  dump <task_id>        Render formatted event stream for a specific task"
            echo "  dump <task_id> --raw  Output raw NDJSON stream for machine parsing"
            echo "  incidents             List preserved diagnostic incident dossiers"
            echo "  gc                    Prune old incident dossiers (> 7 days or > 20 records)"
            echo "  help                  Show this help menu"
            return 0
            ;;
        *)
            ui_err "Unknown telemetry command: $subcmd (try /telemetry help)"
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_telemetry "$*"
fi
