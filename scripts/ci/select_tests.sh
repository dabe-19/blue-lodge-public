#!/bin/bash
# ── Dynamic Changed-File to Test-Suite Selector ─────────────────────────
# Shared by .gitea/workflows/ci.yml and pr_audit (lib/agents/pr.sh) so CI
# and local PR audits run the exact same targeted test suites.
# Usage:
#   printf '%s\n' $changed_files | bash scripts/ci/select_tests.sh --stdin
#   bash scripts/ci/select_tests.sh <base_ref> [head_ref]

set -uo pipefail

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

changed_files=""
ci_mode=0
if [ "${1:-}" = "--stdin" ]; then
    changed_files=$(cat)
elif [ "${1:-}" = "--ci" ]; then
    ci_mode=1
    if git -C "$LODGE_DIR" rev-parse --verify origin/develop &>/dev/null && \
       [ "$(git -C "$LODGE_DIR" rev-parse HEAD 2>/dev/null)" != "$(git -C "$LODGE_DIR" rev-parse origin/develop 2>/dev/null)" ]; then
        changed_files=$(git -C "$LODGE_DIR" diff --name-only origin/develop...HEAD 2>/dev/null || git -C "$LODGE_DIR" diff --name-only HEAD~1 HEAD 2>/dev/null || true)
    else
        changed_files=$(git -C "$LODGE_DIR" diff --name-only HEAD~1 HEAD 2>/dev/null || true)
    fi
else
    base_ref="${1:-develop}"
    head_ref="${2:-HEAD}"
    changed_files=$(git -C "$LODGE_DIR" diff --name-only "$base_ref" "$head_ref" 2>/dev/null || true)
fi

declare -a suites=()
_add_suite() {
    local s="$1"
    [ -f "$LODGE_DIR/tests/${s}.sh" ] || return 0
    local existing
    for existing in "${suites[@]:-}"; do
        [ "$existing" = "$s" ] && return 0
    done
    suites+=("$s")
}

while IFS= read -r f; do
    [ -z "$f" ] && continue
    base=$(basename "$f")
    stem="${base%.*}"

    if [[ "$stem" == test_* ]]; then
        _add_suite "$stem"
    elif [ -f "$LODGE_DIR/tests/test_${stem}.sh" ]; then
        _add_suite "test_${stem}"
    fi

    case "$f" in
        okf/*|lib/knowledge/*|lib/tools/okf_sqlite_indexer.py)
            _add_suite "test_okf"
            _add_suite "test_graph_and_routing_parity"
            ;;
        lib/tools/capability_graph_router.py|lib/tools/telemetry_query.py|lib/tools/honeydew_strategist.py|scripts/training/runs.py)
            _add_suite "test_graph_and_routing_parity"
            ;;
        lib/agents/phytology.sh)
            _add_suite "test_phytology"
            ;;
        lib/ipc/fifo_ipc.sh)
            _add_suite "test_fifo_ipc"
            _add_suite "test_fifo_gc"
            ;;
        lib/ipc/event_bus.sh)
            _add_suite "test_event_bus"
            ;;
        lib/agents/pr.sh|lib/agents/remediation.sh|lib/agents/subagents.sh|lib/sys/cron.sh|scripts/ci/*|.gitea/workflows/*)
            _add_suite "test_ci_cd_evolution"
            ;;
        lib/tools/trading/*|lib/tools/cardano_*|tests/trading_policy_checks.py)
            _add_suite "test_trading_policy"
            ;;
    esac
done <<< "$changed_files"

for s in "${suites[@]:-}"; do
    [ -z "$s" ] && continue
    if [ "$ci_mode" -eq 1 ]; then
        case "$s" in
            test_okf|test_graph_and_routing_parity|test_ci_cd_evolution|test_phytology)
                continue
                ;;
        esac
    fi
    echo "$s"
done

