#!/bin/bash
# DESC: Search official arXiv preprints directly with title, URL, PDF, and abstract
# Usage: /arxiv <search topic or title> [max_results]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true

cmd_arxiv() {
    local query="${1:-}"
    if [ -z "$query" ]; then
        ui_err "Usage: /arxiv <search topic or title> [max_results]"
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

    ui_step "Searching arXiv preprints for: '$query'..."
    "$py_bin" "$LODGE_DIR/lib/tools/searxng_backend.py" arxiv --query "$query" --max-results "$max_res" --format text
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_arxiv "$@"
fi
