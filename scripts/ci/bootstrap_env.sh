#!/bin/bash
# ── Sovereign CI & Sandbox Environment Bootstrapper ─────────────────────
# Single source of truth for provisioning system dependencies and initializing
# a hermetic .george / recall.db state across Gitea Actions CI, pr_audit,
# and remediation sandboxes.

set -uo pipefail

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export LODGE_DIR

INSTALL_DEPS=0
for arg in "$@"; do
    case "$arg" in
        --install-deps) INSTALL_DEPS=1 ;;
        --no-apt)       INSTALL_DEPS=0 ;;
        --workdir=*)    LODGE_DIR="${arg#*=}"; export LODGE_DIR ;;
    esac
done

# 1. System & Python package parity with Dockerfile.cuda-sandbox (for container CI environments)
if [ "$INSTALL_DEPS" -eq 1 ] && command -v apt-get &>/dev/null; then
    _need_apt=0
    for _bin in jq sqlite3 rg zstd pdftotext ps; do
        command -v "$_bin" &>/dev/null || _need_apt=1
    done
    python3 -c "import yaml" &>/dev/null || _need_apt=1
    if [ "$_need_apt" -eq 1 ]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                jq sqlite3 ripgrep zstd poppler-utils procps python3-yaml 2>/dev/null || true
    fi
fi

# 1b. Workspace .venv Linking & Python Version Parity
HOST_VENV="${HOST_VENV_MOUNT:-/home/user/blue-lodge/.venv}"
if [ ! -e "$LODGE_DIR/.venv" ] && [ -x "$HOST_VENV/bin/python" ]; then
    ln -sfn "$HOST_VENV" "$LODGE_DIR/.venv" 2>/dev/null || true
fi
if [ -x "$LODGE_DIR/.venv/bin/python" ]; then
    export PATH="$LODGE_DIR/.venv/bin:$PATH"
    [ -n "${GITHUB_PATH:-}" ] && echo "$LODGE_DIR/.venv/bin" >> "$GITHUB_PATH" 2>/dev/null || true
    # In isolated CI containers where /usr/local/bin is writable by root, install an
    # exec wrapper at /usr/local/bin/python3 so argv[0] points inside .venv (allowing
    # CPython to locate pyvenv.cfg) even when subsequent steps invoke bare 'python3'.
    if [ "$(id -u)" -eq 0 ] && [ -w /usr/local/bin ] && [ "$LODGE_DIR" != "/home/user/blue-lodge" ]; then
        rm -f /usr/local/bin/python3 /usr/local/bin/python 2>/dev/null || true
        printf '#!/bin/sh\nexec "%s/.venv/bin/python" "$@"\n' "$LODGE_DIR" > /usr/local/bin/python3
        chmod +x /usr/local/bin/python3
        cp -f /usr/local/bin/python3 /usr/local/bin/python
    fi
fi
if [ -f "$LODGE_DIR/.python-version" ] && command -v python3 &>/dev/null; then
    _expected_py=$(tr -d '[:space:]' < "$LODGE_DIR/.python-version" | cut -d. -f1,2)
    _actual_py=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)
    if [ -n "$_expected_py" ] && [ -n "$_actual_py" ] && [ "$_expected_py" != "$_actual_py" ]; then
        echo "WARNING: Python minor version mismatch (expected ${_expected_py}.x from .python-version, got ${_actual_py})" >&2
    fi
fi

# 2. Hermetic .george & recall.db initialization
export GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"
export RECALL_DB="${RECALL_DB:-$GEORGE_DIR/recall.db}"
mkdir -p "$GEORGE_DIR" "$GEORGE_DIR/ipc/channels" "$GEORGE_DIR/ipc/promises" "$GEORGE_DIR/ipc/payloads" "$GEORGE_DIR/ipc/locks" 2>/dev/null || true

if [ -f "$LODGE_DIR/lib/memory/recall.sh" ] && command -v sqlite3 &>/dev/null; then
    # shellcheck disable=SC1091
    source "$LODGE_DIR/lib/memory/recall.sh" 2>/dev/null || true
    if declare -f recall_init &>/dev/null; then
        recall_init >/dev/null 2>&1 || true
    fi

    # Populate OKF graph nodes & edges if recall.db is cold/unindexed
    if [ -f "$LODGE_DIR/lib/tools/okf_sqlite_indexer.py" ] && command -v python3 &>/dev/null; then
        _edges=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM okf_edges;" 2>/dev/null || echo 0)
        if [ "${_edges:-0}" -lt 1000 ]; then
            GEORGE_DIR="$GEORGE_DIR" RECALL_DB="$RECALL_DB" \
                python3 "$LODGE_DIR/lib/tools/okf_sqlite_indexer.py" --index >/dev/null 2>&1 || true
        fi
    fi

    # Seed minimal baseline telemetry rows on cold start so summary queries succeed
    _tstats=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM tool_telemetry_stats;" 2>/dev/null || echo 0)
    if [ "${_tstats:-0}" -eq 0 ] && declare -f recall_record_tool_stat &>/dev/null; then
        recall_record_tool_stat "web_search" 250 0 0 "" >/dev/null 2>&1 || true
    fi
    _traces=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM routing_eval_trace;" 2>/dev/null || echo 0)
    if [ "${_traces:-0}" -eq 0 ] && declare -f recall_trace_record_allowlisted &>/dev/null; then
        recall_trace_record_allowlisted "hermetic_seed" '{"infeasibility_class":"none","evaluator_mode":"normal","task_outcome_class":"successful","redacted_diagnostic":"seed"}' >/dev/null 2>&1 || true
    fi
fi

exit 0
