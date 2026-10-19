#!/bin/bash
# ── George: Google Open Knowledge Graph (OKF) Engine ─────────────────
# Turns Blue Lodge codebase hierarchies into knowable, searchable semantic
# graphs. Provides high-performance query, search, standards lookup,
# graph validation, and tree rendering for internal and external agents.
#
# Architectural Standard:
# Shell functions serve as thin, low-latency dispatchers. Semantic graph
# traversal, JSON-LD parsing, and validation are delegated to the discrete
# Python backend at lib/knowledge/okf_backend.py.

[ -n "${_LIB_OKF_LOADED:-}" ] && return 0; _LIB_OKF_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
OKF_DIR="${OKF_DIR:-$LODGE_DIR/okf}"
OKF_GRAPH_FILE="${OKF_GRAPH_FILE:-$OKF_DIR/blue_lodge_graph.jsonld}"
OKF_SCHEMA_FILE="${OKF_SCHEMA_FILE:-$LODGE_DIR/data/schemas/okf_graph.schema.json}"
OKF_BACKEND="${OKF_BACKEND:-$LODGE_DIR/lib/knowledge/okf_backend.py}"

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true

# ── Python Interpreter Resolution ─────────────────────────────────────
_okf_resolve_python() {
    if [ -n "${GEORGE_PYTHON:-}" ] && command -v "$GEORGE_PYTHON" &>/dev/null; then
        echo "$GEORGE_PYTHON"
    elif [ -x "$LODGE_DIR/.venv/bin/python" ]; then
        echo "$LODGE_DIR/.venv/bin/python"
    elif [ -x "$LODGE_DIR/.george/venv/bin/python" ]; then
        echo "$LODGE_DIR/.george/venv/bin/python"
    elif command -v python3 &>/dev/null; then
        echo "python3"
    elif command -v uv &>/dev/null; then
        echo "uv run --quiet python"
    else
        echo ""
    fi
}

okf_init() {
    if [ ! -f "$OKF_GRAPH_FILE" ]; then
        if [ -f "$LODGE_DIR/okf.jsonld" ]; then
            OKF_GRAPH_FILE="$LODGE_DIR/okf.jsonld"
        fi
    fi
}

# ── OKF Search ────────────────────────────────────────────────────────
# Usage: okf_search <query> [--json]
okf_search() {
    local query="$1"
    local as_json=0
    [ "${2:-}" = "--json" ] && as_json=1

    okf_init
    if [ ! -f "$OKF_GRAPH_FILE" ]; then
        echo "Error: OKF graph file not found at $OKF_GRAPH_FILE" >&2
        return 1
    fi

    if [ -z "$query" ]; then
        echo "Usage: okf_search <query> [--json]" >&2
        return 1
    fi

    local py_bin
    py_bin=$(_okf_resolve_python)
    if [ -z "$py_bin" ]; then
        echo "Error: Python runtime required for OKF semantic search. Please install python3 or run ./install.sh" >&2
        return 1
    fi

    local -a json_arg=()
    [ "$as_json" -eq 1 ] && json_arg=("--json")

    $py_bin "$OKF_BACKEND" --graph "$OKF_GRAPH_FILE" search "$query" "${json_arg[@]}"
}

# ── OKF Query ─────────────────────────────────────────────────────────
# Usage: okf_query <path_or_id> [--json]
okf_query() {
    local target="$1"
    local as_json=0
    [ "${2:-}" = "--json" ] && as_json=1

    okf_init
    if [ ! -f "$OKF_GRAPH_FILE" ]; then
        echo "Error: OKF graph file not found at $OKF_GRAPH_FILE" >&2
        return 1
    fi

    if [ -z "$target" ]; then
        echo "Usage: okf_query <path_or_id> [--json]" >&2
        return 1
    fi

    local py_bin
    py_bin=$(_okf_resolve_python)
    if [ -z "$py_bin" ]; then
        echo "Error: Python runtime required for OKF query. Please install python3 or run ./install.sh" >&2
        return 1
    fi

    local -a json_arg=()
    [ "$as_json" -eq 1 ] && json_arg=("--json")

    $py_bin "$OKF_BACKEND" --graph "$OKF_GRAPH_FILE" query "$target" "${json_arg[@]}"
}

# ── OKF Standards ─────────────────────────────────────────────────────
# Usage: okf_standards [standard_name_or_id] [--json]
okf_standards() {
    local target="${1:-}"
    local as_json=0
    [ "${2:-}" = "--json" ] && as_json=1

    okf_init
    if [ ! -f "$OKF_GRAPH_FILE" ]; then
        echo "Error: OKF graph file not found at $OKF_GRAPH_FILE" >&2
        return 1
    fi

    local py_bin
    py_bin=$(_okf_resolve_python)
    if [ -z "$py_bin" ]; then
        echo "Error: Python runtime required for OKF standards. Please install python3 or run ./install.sh" >&2
        return 1
    fi

    local -a json_arg=()
    [ "$as_json" -eq 1 ] && json_arg=("--json")

    if [ -n "$target" ]; then
        $py_bin "$OKF_BACKEND" --graph "$OKF_GRAPH_FILE" standards "$target" "${json_arg[@]}"
    else
        $py_bin "$OKF_BACKEND" --graph "$OKF_GRAPH_FILE" standards "${json_arg[@]}"
    fi
}

# ── OKF Tree ──────────────────────────────────────────────────────────
# Usage: okf_tree [subsystem_id]
okf_tree() {
    local target_subsys="${1:-}"

    okf_init
    if [ ! -f "$OKF_GRAPH_FILE" ]; then
        echo "Error: OKF graph file not found at $OKF_GRAPH_FILE" >&2
        return 1
    fi

    local py_bin
    py_bin=$(_okf_resolve_python)
    if [ -z "$py_bin" ]; then
        echo "Error: Python runtime required for OKF tree rendering. Please install python3 or run ./install.sh" >&2
        return 1
    fi

    if [ -n "$target_subsys" ]; then
        $py_bin "$OKF_BACKEND" --graph "$OKF_GRAPH_FILE" tree "$target_subsys"
    else
        $py_bin "$OKF_BACKEND" --graph "$OKF_GRAPH_FILE" tree
    fi
}

# ── OKF Validate ──────────────────────────────────────────────────────
# Usage: okf_validate
okf_validate() {
    okf_init
    if [ ! -f "$OKF_GRAPH_FILE" ]; then
        echo "✗ FAIL: OKF graph file missing: $OKF_GRAPH_FILE" >&2
        return 1
    fi

    local py_bin
    py_bin=$(_okf_resolve_python)
    if [ -z "$py_bin" ]; then
        echo "Error: Python runtime required for OKF graph validation. Please install python3 or run ./install.sh" >&2
        return 1
    fi

    $py_bin "$OKF_BACKEND" --graph "$OKF_GRAPH_FILE" validate --schema "$OKF_SCHEMA_FILE" --lodge-dir "$LODGE_DIR"
}

# ── OKF Sync / Regenerate ─────────────────────────────────────────────
# Usage: okf_sync [--quiet]
okf_sync() {
    local quiet=0
    if [ "${1:-}" = "--quiet" ] || [ "${1:-}" = "-q" ]; then
        quiet=1
    fi

    okf_init
    local generator="$LODGE_DIR/okf/generate_okf_graph.py"
    if [ ! -f "$generator" ]; then
        echo "Error: OKF generator script not found at $generator" >&2
        return 1
    fi

    local py_bin
    py_bin=$(_okf_resolve_python)
    if [ -z "$py_bin" ]; then
        echo "Error: Python runtime required for OKF sync. Please install python3 or run ./install.sh" >&2
        return 1
    fi

    [ "$quiet" -eq 0 ] && echo "==> Synchronizing OKF knowledge graph for Blue Lodge..."

    LODGE_DIR="$LODGE_DIR" $py_bin "$generator" || {
        echo "✗ Error: Failed to generate OKF knowledge graph" >&2
        return 1
    }

    okf_validate || {
        echo "✗ Error: OKF knowledge graph failed validation after sync" >&2
        return 1
    }

    local fts_indexer="$LODGE_DIR/lib/tools/okf_sqlite_indexer.py"
    if [ -f "$fts_indexer" ]; then
        LODGE_DIR="$LODGE_DIR" $py_bin "$fts_indexer" --index >/dev/null 2>&1 || true
    fi

    [ "$quiet" -eq 0 ] && echo "✓ OKF knowledge graph synchronized and validated."
    return 0
}
