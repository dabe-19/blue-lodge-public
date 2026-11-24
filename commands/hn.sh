#!/bin/bash
# DESC: Search Hacker News practitioner discussions, stories, and comments via Algolia API
# Usage: /hn <search topic> [max_results]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/commands/searxng.sh"

cmd_hn() {
    local query="${1:-}"
    if [ -z "$query" ]; then
        ui_err "Usage: /hn <search topic> [max_results]"
        return 1
    fi
    ui_step "Searching Hacker News discussions for: '$query'..."
    cmd_searxng "hn $query"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_hn "$*"
fi
