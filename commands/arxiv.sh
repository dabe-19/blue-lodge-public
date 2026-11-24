#!/bin/bash
# DESC: Search official arXiv preprints directly with title, URL, PDF, and abstract
# Usage: /arxiv <search topic or title> [max_results]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/commands/searxng.sh"

cmd_arxiv() {
    local query="${1:-}"
    if [ -z "$query" ]; then
        ui_err "Usage: /arxiv <search topic or title> [max_results]"
        return 1
    fi
    ui_step "Searching arXiv preprints for: '$query'..."
    cmd_searxng "arxiv $query"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_arxiv "$*"
fi
