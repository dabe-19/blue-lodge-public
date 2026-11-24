#!/bin/bash
# ── Hermetic Test Runner ────────────────────────────────────────────────
# Executes one or more test scripts inside a clean, ephemeral GEORGE_DIR /
# RECALL_DB environment (no host recall.db symlink) to guarantee CI parity.

set -uo pipefail

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export LODGE_DIR

_HERMETIC_TMP=$(mktemp -d /tmp/lodge_hermetic_george_XXXXXX)
cleanup_hermetic() {
    rm -rf "$_HERMETIC_TMP" 2>/dev/null || true
}
trap cleanup_hermetic EXIT INT TERM

export GEORGE_DIR="$_HERMETIC_TMP/.george"
export RECALL_DB="$GEORGE_DIR/recall.db"
export FIFO_IPC_DIR="$GEORGE_DIR/ipc"

bash "$LODGE_DIR/scripts/ci/bootstrap_env.sh" --no-apt || exit 1

if [ "$#" -eq 0 ]; then
    set -- "$LODGE_DIR/tests/test_okf.sh" "$LODGE_DIR/tests/test_graph_and_routing_parity.sh"
fi

overall_ec=0
for t in "$@"; do
    t_path="$t"
    if [ ! -f "$t_path" ] && [ -f "$LODGE_DIR/tests/${t}.sh" ]; then
        t_path="$LODGE_DIR/tests/${t}.sh"
    elif [ ! -f "$t_path" ] && [ -f "$LODGE_DIR/$t" ]; then
        t_path="$LODGE_DIR/$t"
    fi
    if [ ! -f "$t_path" ]; then
        echo "[HERMETIC FAIL] Test suite not found: $t" >&2
        overall_ec=1
        continue
    fi
    bash "$t_path" || overall_ec=$?
done

exit "$overall_ec"
