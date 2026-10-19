#!/bin/bash
# DESC: Search Hacker News practitioner discussions, stories, and comments via Algolia API
# Usage: /hn <search topic> [max_results]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true

cmd_hn() {
    local query="${1:-}"
    if [ -z "$query" ]; then
        ui_err "Usage: /hn <search topic> [max_results]"
        return 1
    fi

    local max_res=8
    local last_tok="${query##* }"
    if [[ "$last_tok" =~ ^[0-9]+$ ]] && [ "$query" != "$last_tok" ]; then
        max_res="$last_tok"
        query="${query% *}"
    fi

    local py_bin="python3"
    [ -x "$LODGE_DIR/.venv/bin/python" ] && py_bin="$LODGE_DIR/.venv/bin/python"

    ui_step "Searching Hacker News discussions for: '$query'..."
    "$py_bin" "$LODGE_DIR/lib/tools/searxng_backend.py" hn --query "$query" --max-results "$max_res" --format text
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_hn "$@"
fi
