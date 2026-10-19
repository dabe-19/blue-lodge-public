#!/bin/bash
# ── George Slash Command: /okf ───────────────────────────────────────
# DESC: Search, query and inspect Google Open Knowledge Graph (OKF) & standards
# USAGE: /okf [search <query> | query <path> | standards [id] | tree [subsys] | validate]

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/knowledge/okf.sh" 2>/dev/null || true

cmd_okf() {
    local args="$1"
    local workdir="${2:-$PWD}"

    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        search)
            [ -z "$rest" ] && { ui_err "Usage: /okf search <query>"; return 1; }
            okf_search "$rest"
            ;;
        query|get|show)
            [ -z "$rest" ] && { ui_err "Usage: /okf query <path_or_id>"; return 1; }
            okf_query "$rest"
            ;;
        standards|standard|std)
            okf_standards "$rest"
            ;;
        tree)
            okf_tree "$rest"
            ;;
        validate|check|audit)
            okf_validate
            ;;
        sync|refresh|generate)
            okf_sync
            ;;
        help|"")
            cat <<EOF
/okf — Google Open Knowledge Graph & Programming Standards Interface

Usage:
  /okf search <query>       Search codebase entities, standards, and modules
  /okf query <path_or_id>   Inspect metadata, dependencies, exports for an entity
  /okf standards [id]       View formal architectural standards (OKF)
  /okf tree [subsystem]     Render hierarchical knowledge tree
  /okf validate             Verify OKF graph schema and file existence on disk
  /okf sync                 Regenerate and validate knowledge graph from codebase

Examples:
  /okf search ipc
  /okf query lib/ipc/fifo_ipc.sh
  /okf standards fifo-async-ipc-flowcontrol
  /okf tree core
  /okf validate
  /okf sync
EOF
            ;;
        *)
            # If user just types /okf <query>, treat as search
            okf_search "$args"
            ;;
    esac
}
