#!/bin/bash
# DESC: Inspect and manage autonomous George subagents and process streams
# Usage: /subagents [list|logs|stream|diff|merge|reap|pause|resume|abort|spawn] [args...]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/subagents.sh" 2>/dev/null || true

cmd_subagents() {
    local args="$1"
    local workdir="${2:-.}"

    subagents_init

    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        ""|list)
            local reg_file
            reg_file=$(subagents_registry_file)
            if [ ! -f "$reg_file" ] || [ "$(jq 'length' "$reg_file" 2>/dev/null)" = "0" ]; then
                ui_info "No subagents registered."
                return 0
            fi

            ui_step "Autonomous Subagents Registry:"
            printf "%-26s %-6s %-12s %-10s %-18s %s\n" "SUBAGENT ID" "TIER" "STATUS" "TURNS" "MODEL" "OBJECTIVE"
            printf "%-26s %-6s %-12s %-10s %-18s %s\n" "--------------------------" "------" "------------" "----------" "------------------" "-------------------------"

            jq -r '.[] | "\(.id)|\(.tier)|\(.status)|\(.current_turn // 1)/\(.max_turns)|\(.model)|\(.objective)"' "$reg_file" 2>/dev/null | \
            while IFS='|' read -r sid stier sstat sturn smodel sobj; do
                local status_color="$sstat"
                case "$sstat" in
                    RUNNING)   status_color="${COLOR_GREEN:-}${sstat}${COLOR_RESET:-}" ;;
                    PAUSED)    status_color="${COLOR_YELLOW:-}${sstat}${COLOR_RESET:-}" ;;
                    COMPLETED) status_color="${COLOR_CYAN:-}${sstat}${COLOR_RESET:-}" ;;
                    FAILED|ORPHAN_REAPED|KILLED*) status_color="${COLOR_RED:-}${sstat}${COLOR_RESET:-}" ;;
                esac
                printf "%-26s %-6s %-21b %-10s %-18s %s\n" "$sid" "T$stier" "$status_color" "$sturn" "${smodel:0:17}" "${sobj:0:40}"
            done
            ;;

        logs)
            local target_id="${rest%% *}"
            local lines="${rest#"$target_id"}"
            lines="${lines#"${lines%%[![:space:]]*}"}"
            lines="${lines:-50}"
            if [ -z "$target_id" ]; then
                ui_err "Usage: /subagents logs <subagent_id> [lines]"
                return 1
            fi
            ui_step "Process Stream Logs for Subagent $target_id (last $lines lines):"
            subagents_logs "$target_id" "$lines"
            ;;

        stream)
            local target_id="${rest%% *}"
            if [ -z "$target_id" ]; then
                ui_err "Usage: /subagents stream <subagent_id>"
                return 1
            fi
            ui_step "Streaming Process Stream for Subagent $target_id (Ctrl+C to stop stream)..."
            subagents_stream "$target_id"
            ;;

        diff)
            local target_id="${rest%% *}"
            local opt="${rest#"$target_id"}"
            opt="${opt#"${opt%%[![:space:]]*}"}"
            if [ -z "$target_id" ]; then
                ui_err "Usage: /subagents diff <subagent_id> [--stat]"
                return 1
            fi
            local stat_only=false
            [[ "$opt" == *"--stat"* ]] && stat_only=true
            subagents_diff "$target_id" "$stat_only"
            ;;

        merge)
            local target_id="${rest%% *}"
            local strat="${rest#"$target_id"}"
            strat="${strat#"${strat%%[![:space:]]*}"}"
            strat="${strat:-merge}"
            if [ -z "$target_id" ]; then
                ui_err "Usage: /subagents merge <subagent_id> [merge|squash]"
                return 1
            fi
            subagents_merge "$target_id" "$strat"
            ;;

        reap)
            local target_id="${rest%% *}"
            if [ -z "$target_id" ]; then
                ui_err "Usage: /subagents reap <subagent_id>"
                return 1
            fi
            subagents_reap "$target_id"
            ;;

        pause)
            local target_id="${rest%% *}"
            if [ -z "$target_id" ]; then
                ui_err "Usage: /subagents pause <subagent_id>"
                return 1
            fi
            local fifo="$LODGE_DIR/.sandboxes/$target_id/control.fifo"
            if [ -p "$fifo" ]; then
                printf 'PAUSE\n' > "$fifo" 2>/dev/null || true
                ui_ok "Transmitted PAUSE directive to $target_id"
            else
                ui_err "Control FIFO not found for $target_id (process may have completed)"
                return 1
            fi
            ;;

        resume)
            local target_id="${rest%% *}"
            if [ -z "$target_id" ]; then
                ui_err "Usage: /subagents resume <subagent_id>"
                return 1
            fi
            local fifo="$LODGE_DIR/.sandboxes/$target_id/control.fifo"
            if [ -p "$fifo" ]; then
                printf 'RESUME\n' > "$fifo" 2>/dev/null || true
                ui_ok "Transmitted RESUME directive to $target_id"
            else
                ui_err "Control FIFO not found for $target_id"
                return 1
            fi
            ;;

        abort)
            local target_id="${rest%% *}"
            if [ -z "$target_id" ]; then
                ui_err "Usage: /subagents abort <subagent_id>"
                return 1
            fi
            local fifo="$LODGE_DIR/.sandboxes/$target_id/control.fifo"
            if [ -p "$fifo" ]; then
                printf 'ABORT\n' > "$fifo" 2>/dev/null || true
                ui_ok "Transmitted ABORT directive to $target_id"
            else
                ui_err "Control FIFO not found for $target_id"
                return 1
            fi
            ;;

        spawn)
            local tier="${rest%% *}"
            local rest_args="${rest#"$tier"}"
            rest_args="${rest_args#"${rest_args%%[![:space:]]*}"}"
            local turns="${AGENT_CHILD_MAX_TURNS:-200}"
            local is_async=0

            while [[ "$rest_args" == --* ]]; do
                if [[ "$rest_args" =~ ^--turns[[:space:]]+([0-9]+)[[:space:]]*(.*) ]]; then
                    turns="${BASH_REMATCH[1]}"
                    rest_args="${BASH_REMATCH[2]}"
                elif [[ "$rest_args" =~ ^--async[[:space:]]*(.*) ]]; then
                    is_async=1
                    rest_args="${BASH_REMATCH[1]}"
                else
                    break
                fi
            done
            local obj="$rest_args"
            if [ -z "$tier" ] || [ -z "$obj" ]; then
                ui_err "Usage: /subagents spawn <tier> [--turns <N>] [--async] <objective...>"
                return 1
            fi
            ui_info "Spawning subagent on Tier $tier (max turns: $turns, async: $is_async): $obj"
            subagents_spawn "$tier" "$obj" "Delegated via /subagents spawn" "$workdir" "$turns" "$is_async"
            ;;

        *)
            ui_err "Unknown subagents command: '$subcmd'"
            ui_info "Available subcommands: list, logs <id>, stream <id>, diff <id>, merge <id>, reap <id>, pause <id>, resume <id>, abort <id>, spawn <tier> <obj>"
            return 1
            ;;
    esac
}

cmd_subagent() {
    cmd_subagents "$@"
}
