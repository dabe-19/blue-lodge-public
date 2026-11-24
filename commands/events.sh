#!/bin/bash
# DESC: Query and manage Sovereign 90-Day Rolling Event Store, FTS5 Search, and Compute Alpha Deals
# Usage:
#   /events status                  — Show SQLite event store telemetry, disk size, and retention stats
#   /events deals [GPU|RAM]         — Show active compute hardware deals (STEAL/DEAL) with unit economics
#   /events hardware                — Show hardware valuation benchmark, target FMVs, and observed prices
#   /events search <query>          — FTS5 full-text search across all historical event envelopes
#   /events list [limit]            — Show recent raw events from the historical log (default 25)
#   /events prune [days]            — Execute 90-day rolling retention pruner (default 90 days)
#   /events compact                 — Run database VACUUM and WAL checkpoint to reclaim disk space
#   /events contracts               — Show active event contracts and info models

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/event_bus.sh" 2>/dev/null || true

_events_py() {
    if [ -x "$LODGE_DIR/.venv/bin/python" ]; then
        "$LODGE_DIR/.venv/bin/python" "$LODGE_DIR/lib/tools/event_store.py" "$@"
    elif command -v uv &>/dev/null; then
        uv run --project "$LODGE_DIR" python "$LODGE_DIR/lib/tools/event_store.py" "$@"
    else
        python3 "$LODGE_DIR/lib/tools/event_store.py" "$@"
    fi
}

cmd_events() {
    local args="$1"
    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        ""|status)
            _events_py --stats
            ;;
        deals)
            local cat_arg=()
            if [ -n "$rest" ]; then
                local upper_cat
                upper_cat=$(echo "$rest" | tr '[:lower:]' '[:upper:]')
                if [[ "$upper_cat" == "GPU" || "$upper_cat" == "RAM" ]]; then
                    cat_arg=(--category "$upper_cat")
                fi
            fi
            _events_py --deals "${cat_arg[@]}"
            ;;
        verify)
            local target="${rest:-all}"
            declare -f ui_info &>/dev/null && ui_info "Invoking Sovereign Agentic Deal Verification Graph ($target)..."
            bash "$LODGE_DIR/lib/agents/deal_verifier_worker.sh" "$target"
            ;;
        audit|verifications)
            _events_py --verifications
            ;;
        hardware|specs)
            _events_py --hardware-stats
            ;;
        search)
            if [ -z "$rest" ]; then
                declare -f ui_err &>/dev/null && ui_err "Usage: /events search <query>"
                return 1
            fi
            _events_py --search "$rest"
            ;;
        list)
            local limit="${rest:-25}"
            _events_py --query-events --limit "$limit"
            ;;
        prune)
            local days="${rest:-90}"
            declare -f ui_info &>/dev/null && ui_info "Running rolling retention pruner (retention: ${days} days)..."
            _events_py --prune --retention-days "$days"
            ;;
        compact|vacuum)
            declare -f ui_info &>/dev/null && ui_info "Compacting SQLite event database (.george/events.db)..."
            _events_py --compact
            ;;
        contracts)
            if [ -f "$GEORGE_DIR/events.db" ]; then
                sqlite3 "$GEORGE_DIR/events.db" ".mode box" "SELECT event_type, domain, retention_days, description FROM event_contracts ORDER BY domain, event_type;"
            else
                declare -f ui_err &>/dev/null && ui_err "Event database not initialized yet. Run /events status to initialize."
            fi
            ;;
        help|--help|-h)
            echo "Usage: /events [status|deals|verify|audit|hardware|search|list|prune|compact|contracts]"
            echo "  /events status          - Database size, total events, reactions, and deal counts"
            echo "  /events deals [GPU|RAM] - List active compute deals classified as STEAL or DEAL"
            echo "  /events verify [id|all] - Run agentic verification graph on candidate deals"
            echo "  /events audit           - Show forensic deal verifications audit log"
            echo "  /events hardware        - Show tracked hardware valuation models and price history"
            echo "  /events search <query>  - FTS5 full-text search across historical event payloads"
            echo "  /events list [limit]    - Query raw historical events (default 25)"
            echo "  /events prune [days]    - Purge records older than N days (default 90 days)"
            echo "  /events compact         - Reclaim disk space via SQLite VACUUM"
            echo "  /events contracts       - Show registered info contracts"
            ;;
        *)
            declare -f ui_err &>/dev/null && ui_err "Unknown events subcommand: $subcmd"
            declare -f ui_dim &>/dev/null && ui_dim "Run '/events help' for available options."
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_events "$*"
fi
