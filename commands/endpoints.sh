#!/bin/bash
# ── George: /endpoints Slash Command ──────────────────────────────────────
# Manage the 4-tier inference hardware ladder, IPC FIFO slot states, and
# Objective-to-Endpoint routing assignments.

[ -n "${_CMD_ENDPOINTS_LOADED:-}" ] && return 0; _CMD_ENDPOINTS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
[ -f "$LODGE_DIR/lib/core/endpoints.sh" ] && source "$LODGE_DIR/lib/core/endpoints.sh"
[ -f "$LODGE_DIR/lib/ipc/fifo_ipc.sh" ] && source "$LODGE_DIR/lib/ipc/fifo_ipc.sh"
[ -f "$LODGE_DIR/lib/ui/ui.sh" ] && source "$LODGE_DIR/lib/ui/ui.sh"

cmd_endpoints() {
    local args="$1"
    local sub rest
    sub=$(echo "$args" | awk '{print $1}')
    rest=$(echo "$args" | cut -d' ' -f2-)
    [ "$sub" = "$rest" ] && rest=""

    case "$sub" in
        ""|status)
            endpoints_status_table
            ;;
        objectives|routes|routing)
            endpoints_init
            ui_section "Objective-to-Endpoint Routing Policies"
            local objs=(INTERACTIVE REMEDIATION PR_REVIEW EVALUATOR ADVISOR SDR_SUMMARY SUBAGENTS CLONE_WORKER PHYTOLOGY)
            local o var_name spec resolved r_tier r_name r_url r_model o_lower
            for o in "${objs[@]}"; do
                var_name="OBJECTIVE_${o}"
                spec="${!var_name:-}"
                o_lower=$(echo "$o" | tr '[:upper:]' '[:lower:]')
                resolved=$(endpoints_resolve_for_objective "$o_lower" 2>/dev/null || true)
                if [ -n "$resolved" ]; then
                    IFS='|' read -r r_tier r_name r_url r_model <<< "$resolved"
                    printf "  %-16s %-18s → %bTier %s [%s]%b (%s @ %s)\n" \
                        "$o_lower" "[$spec]" "${C_GREEN}" "$r_tier" "$r_name" "${C_RESET}" "$r_model" "$r_url"
                else
                    printf "  %-16s %-18s → %b(unresolved / offline)%b\n" \
                        "$o_lower" "[$spec]" "${C_DIM}" "${C_RESET}"
                fi
            done
            echo ""
            ui_dim "  Assign: /endpoints assign <objective> <spec>  (e.g. /endpoints assign evaluator 2:idle,1)"
            ;;
        assign)
            local obj spec
            obj=$(echo "$rest" | awk '{print $1}')
            spec=$(echo "$rest" | awk '{print $2}')
            if [ -z "$obj" ] || [ -z "$spec" ]; then
                ui_err "Usage: /endpoints assign <objective> <tier_spec>"
                ui_dim "  Examples:"
                ui_dim "    /endpoints assign remediation 1,3"
                ui_dim "    /endpoints assign evaluator 2:idle,1"
                ui_dim "    /endpoints assign phytology 2:idle,1"
                return 1
            fi
            if endpoints_assign_objective "$obj" "$spec"; then
                local resolved
                resolved=$(endpoints_resolve_for_objective "$obj" 2>/dev/null || true)
                ui_ok "Updated OBJECTIVE_$(echo "$obj" | tr '[:lower:]-' '[:upper:]_') = \"$spec\""
                if [ -n "$resolved" ]; then
                    local rt rn ru rm
                    IFS='|' read -r rt rn ru rm <<< "$resolved"
                    ui_info "Currently resolves to: Tier $rt [$rn] ($rm @ $ru)"
                fi
            else
                ui_err "Failed to assign objective '$obj' to '$spec' (invalid characters or empty spec)"
                return 1
            fi
            ;;
        resolve)
            local obj
            obj=$(echo "$rest" | awk '{print $1}')
            [ -z "$obj" ] && obj="interactive"
            local resolved
            resolved=$(endpoints_resolve_for_objective "$obj" 2>/dev/null || true)
            if [ -n "$resolved" ]; then
                local rt rn ru rm
                IFS='|' read -r rt rn ru rm <<< "$resolved"
                ui_ok "Objective '$obj' resolves to: Tier $rt [$rn] ($rm @ $ru)"
                echo "$resolved"
            else
                ui_err "Objective '$obj' could not be resolved to any online/idle endpoint"
                return 1
            fi
            ;;
        set|update)
            local tier kvs
            tier=$(echo "$rest" | awk '{print $1}')
            kvs=$(echo "$rest" | cut -d' ' -f2-)
            [ "$tier" = "$kvs" ] && kvs=""
            if [[ ! "$tier" =~ ^[0123]$ ]] || [ -z "$kvs" ]; then
                ui_err "Usage: /endpoints set <tier 0-3> KEY=VAL [KEY=VAL ...]"
                ui_dim "  Supported keys: NAME, URL, MODEL, HARDWARE, CONTEXT, ROLES, ENABLED"
                return 1
            fi
            # shellcheck disable=SC2086
            if endpoints_update_tier "$tier" $kvs; then
                ui_ok "Updated Tier $tier configuration in endpoints.conf"
            else
                ui_err "Failed to update Tier $tier"
                return 1
            fi
            ;;
        json)
            endpoints_status_json
            ;;
        help|*)
            ui_section "Endpoints & Objective Routing Commands"
            echo "  /endpoints [status]                   Show 4-tier hardware ladder, FIFO slots, & objectives"
            echo "  /endpoints objectives                 Show Objective-to-Endpoint routing table"
            echo "  /endpoints assign <objective> <spec>  Assign tier/node cascade to an objective (e.g. 2:idle,1)"
            echo "  /endpoints resolve <objective>        Resolve the active endpoint for an objective right now"
            echo "  /endpoints set <tier> KEY=VAL ...     Update a tier's NAME, URL, MODEL, CONTEXT, or ENABLED"
            echo "  /endpoints json                       Output tier & FIFO slot status as JSON"
            echo ""
            ;;
    esac
}

