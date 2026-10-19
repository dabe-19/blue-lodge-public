#!/bin/bash
# DESC: Manage Sovereign Reactive Event Bus, reactors, and autonomic triggers
# Usage:
#   /react status                      — Show Event Bus daemon status, PID, and throughput
#   /react start                       — Start the Event Bus background daemon
#   /react stop                        — Stop the Event Bus daemon
#   /react restart                     — Restart the Event Bus daemon
#   /react list                        — List all registered reactors
#   /react add <id> <type> <pat> <act> — Register a new reactor (optional --debounce N --overflow drop|coalesce|queue
#                                        --concurrency N --timeout SECS)
#   /react set <id> <field> <value>    — Tune a reactor field (overflow, max_concurrency, timeout_secs, debounce_secs)
#   /react seed                        — Register built-in system reactors (WAKE_TASK, FAULT_QUARANTINE)
#   /react remove <id>                 — Delete a reactor
#   /react toggle <id>                 — Enable/disable a reactor
#   /react emit <type> <payload>       — Emit an event into the bus
#   /react logs [n]                    — Show last N lines of event bus log (default 30)
#   /react rss-test <topic>            — Run live SearXNG Google News RSS reaction test
#   /react api-search <query>          — Search keyless APIs in catalog for triggers
#   /react api-categories              — List all keyless API catalog categories
#   /react api-presets                 — List pre-configured API trigger recipes
#   /react api-build <preset>          — Deploy an API trigger & register reactor
#   /react events [action]             — Query global rolling SQLite event store & FTS5 search

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/event_bus.sh" 2>/dev/null || true

cmd_react() {
    local args="$1"
    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    event_bus_init

    case "$subcmd" in
        ""|status)
            _react_status
            ;;
        start)
            event_bus_start
            ;;
        stop)
            event_bus_stop
            ;;
        restart)
            event_bus_stop
            sleep 0.2
            event_bus_start
            ;;
        list)
            _react_list
            ;;
        add)
            _react_add "$rest"
            ;;
        set)
            local s_id s_field s_val
            read -r s_id s_field s_val <<< "$rest"
            if reactor_set "$s_id" "$s_field" "$s_val"; then
                declare -f ui_ok &>/dev/null && ui_ok "Reactor '$s_id': $s_field = $s_val"
            else
                declare -f ui_err &>/dev/null && ui_err "Usage: /react set <id> <field> <value>"
                return 1
            fi
            ;;
        seed)
            event_bus_seed_system_reactors
            ;;
        remove|rm|del)
            _react_remove "$rest"
            ;;
        toggle)
            _react_toggle "$rest"
            ;;
        emit)
            _react_emit "$rest"
            ;;
        logs)
            _react_logs "$rest"
            ;;
        rss-test)
            _react_rss_test "$rest"
            ;;
        api-search)
            python3 "$LODGE_DIR/lib/tools/api_trigger_builder.py" --search "$rest"
            ;;
        api-categories)
            python3 "$LODGE_DIR/lib/tools/api_trigger_builder.py" --categories
            ;;
        api-presets)
            python3 "$LODGE_DIR/lib/tools/api_trigger_builder.py" --presets
            ;;
        api-build)
            python3 "$LODGE_DIR/lib/tools/api_trigger_builder.py" --build-preset "$rest"
            ;;
        osint-sweep|osint)
            bash "$LODGE_DIR/commands/osint.sh" sweep "$rest"
            ;;
        events|store|db)
            bash "$LODGE_DIR/commands/events.sh" $rest
            ;;
        *)
            declare -f ui_err &>/dev/null && ui_err "Unknown /react action: $subcmd"
            declare -f ui_dim &>/dev/null && ui_dim "Usage: /react [status|start|stop|restart|list|add|set|seed|remove|toggle|emit|logs|rss-test|api-search|api-categories|api-presets|api-build|osint-sweep|events]"
            return 1
            ;;
    esac
}

_react_status() {
    declare -f ui_section &>/dev/null && ui_section "Sovereign Reactive Event Bus Status"

    local st
    st=$(event_bus_status)
    local pid="" alive=0 count=0 evts=0 rxns=0 last_ts=0 fifo="" inflight=0 spooled=0 k v
    while IFS='=' read -r k v; do
        case "$k" in
            EVENT_BUS_PID) pid="$v" ;;
            EVENT_BUS_ALIVE) alive="$v" ;;
            EVENT_BUS_REACTORS_COUNT) count="$v" ;;
            EVENT_BUS_EVENTS_TOTAL) evts="$v" ;;
            EVENT_BUS_REACTIONS_TOTAL) rxns="$v" ;;
            EVENT_BUS_LAST_EVENT_TS) last_ts="$v" ;;
            EVENT_BUS_INFLIGHT) inflight="$v" ;;
            EVENT_BUS_SPOOLED) spooled="$v" ;;
            EVENT_BUS_FIFO) fifo="$v" ;;
        esac
    done <<< "$st"

    if [ "$alive" = "1" ]; then
        declare -f ui_ok &>/dev/null && ui_ok "Daemon: Active (PID: $pid)"
    else
        declare -f ui_warn &>/dev/null && ui_warn "Daemon: Inactive"
    fi

    printf "  Ingress FIFO:     %s\n" "$fifo"
    printf "  Active Reactors:  %s\n" "$count"
    printf "  Events Processed: %s\n" "$evts"
    printf "  Reactions Fired:  %s\n" "$rxns"
    printf "  In-flight:        %s\n" "$inflight"
    printf "  Spooled (replay): %s\n" "$spooled"
    if [[ "$last_ts" =~ ^[0-9]+$ ]] && [ "$last_ts" -gt 0 ]; then
        local ago=$(( ${EPOCHSECONDS:-$(date +%s)} - last_ts ))
        printf "  Last Event:       %ss ago\n" "$ago"
    else
        printf "  Last Event:       Never\n"
    fi
}

_react_list() {
    declare -f ui_section &>/dev/null && ui_section "Registered Reactors (.george/reactors.json)"

    local reactors
    reactors=$(reactor_list)
    local len
    len=$(echo "$reactors" | jq '. | length' 2>/dev/null || echo 0)

    if [ "$len" -eq 0 ]; then
        declare -f ui_dim &>/dev/null && ui_dim "  No reactors registered. Add one with: /react add <id> <type> <pattern> <action>"
        return 0
    fi

    printf "%-18s %-16s %-18s %-8s %-9s %-4s %-8s %s\n" "ID" "EVENT_TYPE" "PATTERN" "DEBOUNCE" "OVERFLOW" "CONC" "STATUS" "ACTION"
    printf "%-18s %-16s %-18s %-8s %-9s %-4s %-8s %s\n" "------------------" "----------------" "------------------" "--------" "---------" "----" "--------" "------"

    echo "$reactors" | jq -r '.[] | "\(.id)\t\(.event_type)\t\(.pattern // "*")\t\(.debounce_secs // 0)s\t\(.overflow // "drop")\t\(.max_concurrency // 4)\t\(if .enabled then "ENABLED" else "DISABLED" end)\t\(.action)"' | while IFS=$'\t' read -r id type pat deb ovf conc status act; do
        printf "%-18s %-16s %-18s %-8s %-9s %-4s %-8s %s\n" "$id" "$type" "$pat" "$deb" "$ovf" "$conc" "$status" "$act"
    done
}

_react_add() {
    local raw="$1"
    if [ -z "$raw" ]; then
        declare -f ui_err &>/dev/null && ui_err "Usage: /react add <id> <event_type> <pattern> <action> [--debounce N]"
        return 1
    fi

    local debounce=2 overflow="" concurrency="" timeout_s=""
    if [[ "$raw" =~ --debounce[[:space:]]+([0-9]+) ]]; then
        debounce="${BASH_REMATCH[1]}"
        raw="${raw/${BASH_REMATCH[0]}/}"
    fi
    if [[ "$raw" =~ --overflow[[:space:]]+(drop|coalesce|queue) ]]; then
        overflow="${BASH_REMATCH[1]}"
        raw="${raw/${BASH_REMATCH[0]}/}"
    fi
    if [[ "$raw" =~ --concurrency[[:space:]]+([0-9]+) ]]; then
        concurrency="${BASH_REMATCH[1]}"
        raw="${raw/${BASH_REMATCH[0]}/}"
    fi
    if [[ "$raw" =~ --timeout[[:space:]]+([0-9]+) ]]; then
        timeout_s="${BASH_REMATCH[1]}"
        raw="${raw/${BASH_REMATCH[0]}/}"
    fi

    # Read positional arguments
    read -r rid rtype rpat raction <<< "$raw"

    if [ -z "$rid" ] || [ -z "$rtype" ] || [ -z "$raction" ]; then
        declare -f ui_err &>/dev/null && ui_err "Missing arguments. Required: <id> <event_type> <pattern> <action>"
        return 1
    fi

    if reactor_add "$rid" "$rtype" "$rpat" "$raction" "$debounce" "$overflow" "$concurrency" "$timeout_s"; then
        declare -f ui_ok &>/dev/null && ui_ok "Reactor '$rid' registered on '$rtype'"
    else
        declare -f ui_err &>/dev/null && ui_err "Failed to register reactor"
        return 1
    fi
}

_react_remove() {
    local rid="$1"
    if [ -z "$rid" ]; then
        declare -f ui_err &>/dev/null && ui_err "Usage: /react remove <id>"
        return 1
    fi

    if reactor_remove "$rid"; then
        declare -f ui_ok &>/dev/null && ui_ok "Reactor '$rid' removed"
    else
        declare -f ui_err &>/dev/null && ui_err "Failed to remove reactor '$rid'"
        return 1
    fi
}

_react_toggle() {
    local rid="$1"
    if [ -z "$rid" ]; then
        declare -f ui_err &>/dev/null && ui_err "Usage: /react toggle <id>"
        return 1
    fi

    reactor_toggle "$rid"
    declare -f ui_ok &>/dev/null && ui_ok "Toggled reactor '$rid'"
}

_react_emit() {
    local raw="$1"
    local evt_type="${raw%% *}"
    local payload="${raw#"$evt_type"}"
    payload="${payload#"${payload%%[![:space:]]*}"}"

    if [ -z "$evt_type" ]; then
        declare -f ui_err &>/dev/null && ui_err "Usage: /react emit <event_type> <payload_json_or_string>"
        return 1
    fi

    [ -z "$payload" ] && payload="{}"

    if event_bus_emit "$evt_type" "$payload" "cli_operator"; then
        declare -f ui_ok &>/dev/null && ui_ok "Emitted '$evt_type' event to bus"
    else
        declare -f ui_err &>/dev/null && ui_err "Failed to emit event"
        return 1
    fi
}

_react_logs() {
    local count="${1:-30}"
    if [ ! -f "$EVENT_BUS_LOG" ]; then
        declare -f ui_info &>/dev/null && ui_info "No event bus logs found at $EVENT_BUS_LOG"
        return 0
    fi

    declare -f ui_section &>/dev/null && ui_section "Event Bus Logs (last $count lines)"
    tail -n "$count" "$EVENT_BUS_LOG"
}

_react_rss_test() {
    local topic="${1:-artificial intelligence}"
    declare -f ui_section &>/dev/null && ui_section "SearXNG Google News RSS Reaction Verification"

    # 1. Ensure event bus daemon is running
    local st
    st=$(event_bus_status)
    local alive
    alive=$(echo "$st" | grep '^EVENT_BUS_ALIVE=' | cut -d= -f2)
    if [ "$alive" != "1" ]; then
        declare -f ui_step &>/dev/null && ui_step "Starting Reactive Event Bus daemon..."
        event_bus_start
        sleep 0.3
    fi

    # 2. Register test reactor
    local test_log="$EVENT_BUS_DIR/rss_reactions.log"
    rm -f "$test_log" 2>/dev/null || true
    local test_action="printf '[REACTION_TRIGGERED] Title: %s | URL: %s\n' \"\$(printf '%s' \"\$EVENT_PAYLOAD\" | jq -r .title)\" \"\$(printf '%s' \"\$EVENT_PAYLOAD\" | jq -r .url)\" >> $test_log"

    declare -f ui_step &>/dev/null && ui_step "Registering test reactor 'rss_news_reactor' for topic: $topic..."
    reactor_add "rss_news_reactor" "searxng_rss" ".*" "$test_action" 0

    # 3. Fetch RSS feeds via SearXNG
    declare -f ui_step &>/dev/null && ui_step "Querying live Google News RSS via SearXNG for: '$topic'..."
    local raw_output
    raw_output=$(bash "$LODGE_DIR/commands/searxng.sh" rss "$topic" 2>/dev/null || true)

    if [ -z "$raw_output" ]; then
        declare -f ui_warn &>/dev/null && ui_warn "SearXNG RSS query returned empty or container offline"
        return 1
    fi

    # 4. Parse articles and pump into event bus
    local count=0
    local cur_title="" cur_url=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^\[[0-9]+\][[:space:]]+(.*) ]]; then
            cur_title="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]+(http[s]?://[^[:space:]]+) ]]; then
            cur_url="${BASH_REMATCH[1]}"
            if [ -n "$cur_title" ] && [ -n "$cur_url" ]; then
                local article_json
                article_json=$(jq -n -c --arg t "$cur_title" --arg u "$cur_url" --arg q "$topic" \
                    '{title: $t, url: $u, topic: $q}')
                event_bus_emit "searxng_rss" "$article_json" "searxng_rss_watcher"
                count=$((count + 1))
                cur_title=""
                cur_url=""
                [ "$count" -ge 3 ] && break
            fi
        fi
    done <<< "$raw_output"

    declare -f ui_ok &>/dev/null && ui_ok "Dispatched $count RSS article events into the bus"

    # 5. Wait briefly for async reactions to complete
    sleep 0.8

    # 6. Verify reactions fired
    if [ -f "$test_log" ] && [ -s "$test_log" ]; then
        declare -f ui_ok &>/dev/null && ui_ok "Reactions successfully fired! Output from $test_log:"
        cat "$test_log"
        return 0
    else
        declare -f ui_err &>/dev/null && ui_err "No reactions detected in $test_log"
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_react "$*"
fi
