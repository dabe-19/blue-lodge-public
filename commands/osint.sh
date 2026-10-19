#!/bin/bash
# DESC: Sovereign OSINT Web Watcher, index monitoring, and e-commerce listing sentinels
# Usage:
#   /osint status           — Show active OSINT watchers, seen database items, and SearXNG state
#   /osint sweep [id]       — Execute index sweep across configured watchers and emit new events
#   /osint test <id>        — Dry-run search sweep for a specific watcher without state commit
#   /osint list             — List configured watchers from .george/osint_watchers.yaml
#   /osint template         — Show or restore default OSINT YAML configuration template
#   /osint seen [clear]     — Inspect or clear the seen items cache (.george/ipc/osint_seen.json)
#   /osint finance <action> — Financial OSINT analyzer (sweep|test|status|init|brief)
#   /osint deals [GPU|RAM]  — View active compute deals (STEAL/DEAL) from event store
#   /osint hardware         — View compute hardware benchmark specs and observed prices

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/ipc/event_bus.sh" 2>/dev/null || true

_osint_py() {
    if [ -x "$LODGE_DIR/.venv/bin/python" ]; then
        "$LODGE_DIR/.venv/bin/python" "$LODGE_DIR/lib/tools/osint_watcher.py" "$@"
    elif command -v uv &>/dev/null; then
        uv run --project "$LODGE_DIR" python "$LODGE_DIR/lib/tools/osint_watcher.py" "$@"
    else
        python3 "$LODGE_DIR/lib/tools/osint_watcher.py" "$@"
    fi
}

cmd_osint() {
    local args="$1"
    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        ""|status)
            _osint_status
            ;;
        sweep)
            _osint_sweep "$rest"
            ;;
        test)
            if [ -z "$rest" ]; then
                declare -f ui_err &>/dev/null && ui_err "Usage: /osint test <watcher_id>"
                return 1
            fi
            _osint_test "$rest"
            ;;
        list)
            _osint_list
            ;;
        template)
            _osint_template "$rest"
            ;;
        seen)
            _osint_seen "$rest"
            ;;
        finance|fin)
            _osint_finance "$rest"
            ;;
        deals)
            bash "$LODGE_DIR/commands/events.sh" deals "$rest"
            ;;
        hardware|specs)
            bash "$LODGE_DIR/commands/events.sh" hardware
            ;;
        *)
            declare -f ui_err &>/dev/null && ui_err "Unknown /osint action: $subcmd"
            declare -f ui_dim &>/dev/null && ui_dim "Usage: /osint [status|sweep|test|list|template|seen|finance|deals|hardware]"
            return 1
            ;;
    esac
}

_osint_status() {
    declare -f ui_section &>/dev/null && ui_section "Sovereign OSINT Web Watcher Status"
    _osint_py --status
}

_osint_list() {
    declare -f ui_section &>/dev/null && ui_section "Active OSINT Web Watchers (.george/osint_watchers.yaml)"
    _osint_py --status
}

_osint_sweep() {
    local target="$1"
    declare -f ui_section &>/dev/null && ui_section "Running OSINT Index Sweep"

    if [ -n "$target" ]; then
        declare -f ui_step &>/dev/null && ui_step "Executing sweep for target: $target..."
        _osint_py --config "$GEORGE_DIR/osint_watchers.yaml" --test "$target"
    else
        declare -f ui_step &>/dev/null && ui_step "Executing sweep across all enabled watchers..."
        _osint_py --config "$GEORGE_DIR/osint_watchers.yaml" --sweep
    fi
}

_osint_test() {
    local target="$1"
    declare -f ui_section &>/dev/null && ui_section "Testing OSINT Watcher (Dry-Run): $target"
    _osint_py --config "$GEORGE_DIR/osint_watchers.yaml" --test "$target"
}

_osint_template() {
    local action="$1"
    local tmpl="$LODGE_DIR/config/osint_watchers.yaml.template"
    local active="$GEORGE_DIR/osint_watchers.yaml"

    if [ "$action" = "restore" ] || [ "$action" = "init" ]; then
        mkdir -p "$GEORGE_DIR"
        cp "$tmpl" "$active"
        declare -f ui_ok &>/dev/null && ui_ok "Restored default OSINT configuration template to $active"
    else
        declare -f ui_section &>/dev/null && ui_section "OSINT YAML Configuration Template"
        cat "$tmpl"
    fi
}

_osint_seen() {
    local action="$1"
    local seen_file="$GEORGE_DIR/ipc/osint_seen.json"

    if [ "$action" = "clear" ]; then
        echo '{"version":1,"items":{}}' > "$seen_file"
        declare -f ui_ok &>/dev/null && ui_ok "Cleared OSINT seen items database"
        return 0
    fi

    if [ ! -f "$seen_file" ]; then
        echo "No seen items recorded yet."
        return 0
    fi

    local count
    count=$(jq '.items | length' "$seen_file" 2>/dev/null || echo 0)
    printf "Recorded seen URLs: %s\n" "$count"
    jq -r '.items[] | "  - [\(.watcher_id)] \(.title) (\(.url))"' "$seen_file" 2>/dev/null | head -n 20
    if [ "$count" -gt 20 ]; then
        printf "  ... and %s more\n" "$((count - 20))"
    fi
}

# ── Financial OSINT Analyzer ─────────────────────────────────────────

_finance_py() {
    if [ -x "$LODGE_DIR/.venv/bin/python" ]; then
        "$LODGE_DIR/.venv/bin/python" "$LODGE_DIR/lib/tools/finance_analyzer.py" "$@"
    elif command -v uv &>/dev/null; then
        uv run --project "$LODGE_DIR" python "$LODGE_DIR/lib/tools/finance_analyzer.py" "$@"
    else
        python3 "$LODGE_DIR/lib/tools/finance_analyzer.py" "$@"
    fi
}

_osint_finance() {
    local args="$1"
    local action="${args%% *}"
    local rest="${args#"$action"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$action" in
        ""|status)
            declare -f ui_section &>/dev/null && ui_section "Financial OSINT Analyzer Status"
            _finance_py --status
            ;;
        sweep)
            declare -f ui_section &>/dev/null && ui_section "Running Financial OSINT Sweep"
            if [ -n "$rest" ]; then
                declare -f ui_step &>/dev/null && ui_step "Sweeping finance watcher: $rest..."
                _finance_py --config "$GEORGE_DIR/finance_osint.yaml" --test "$rest"
            else
                declare -f ui_step &>/dev/null && ui_step "Executing full financial sweep..."
                _finance_py --config "$GEORGE_DIR/finance_osint.yaml" --sweep
            fi
            ;;
        test)
            if [ -z "$rest" ]; then
                declare -f ui_err &>/dev/null && ui_err "Usage: /osint finance test <watcher_id>"
                return 1
            fi
            declare -f ui_section &>/dev/null && ui_section "Testing Finance Watcher (Dry-Run): $rest"
            _finance_py --config "$GEORGE_DIR/finance_osint.yaml" --test "$rest"
            ;;
        init|restore)
            local tmpl="$LODGE_DIR/config/finance_osint.yaml"
            local active="$GEORGE_DIR/finance_osint.yaml"
            if [ ! -f "$tmpl" ]; then
                declare -f ui_err &>/dev/null && ui_err "Template not found: $tmpl"
                return 1
            fi
            mkdir -p "$GEORGE_DIR"
            cp "$tmpl" "$active"
            declare -f ui_ok &>/dev/null && ui_ok "Initialized financial OSINT config: $active"
            ;;
        brief)
            declare -f ui_section &>/dev/null && ui_section "Financial OSINT Intelligence Brief"
            _finance_py --config "$GEORGE_DIR/finance_osint.yaml" --sweep --brief
            ;;
        *)
            declare -f ui_err &>/dev/null && ui_err "Unknown finance action: $action"
            declare -f ui_dim &>/dev/null && ui_dim "Usage: /osint finance [status|sweep|test|init|brief]"
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_osint "$*"
fi
