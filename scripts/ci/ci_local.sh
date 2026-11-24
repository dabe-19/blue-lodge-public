#!/bin/bash
# ── George: Barebones Local CI Runner (scripts/ci/ci_local.sh) ──────────────
# Executes the verification gates defined in .gitea/workflows/ci.yml locally
# in isolated subshells when Gitea and Act Runner are offline or unavailable.
#
# Usage:
#   bash scripts/ci/ci_local.sh [--scope <subsystem>] [--test <tests/test_*.sh>]
#
# Exit Codes:
#   0: All gates passed
#   1: One or more gates failed

set -u
LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TARGET_SCOPE=""
TARGET_TEST=""

while [ $# -gt 0 ]; do
    case "$1" in
        --scope) TARGET_SCOPE="$2"; shift 2 ;;
        --test)  TARGET_TEST="$2"; shift 2 ;;
        *) shift ;;
    esac
done

echo "═══════════════════════════════════════════════════════════"
echo "  Blue Lodge — Sovereign Local CI Gate (Barebones Runner)"
echo "═══════════════════════════════════════════════════════════"

# Gate 1: Shell Syntax & Integrity Check
echo "[1/4] Verifying shell syntax across lib/, commands/, and tests/..."
syntax_failed=0
for f in "$LODGE_DIR"/lib/*.sh "$LODGE_DIR"/commands/*.sh "$LODGE_DIR"/tests/*.sh; do
    [ -f "$f" ] || continue
    if ! bash -n "$f"; then
        echo "  ✗ Syntax failure in $f"
        syntax_failed=1
    fi
done

if [ "$syntax_failed" -ne 0 ]; then
    echo "ERROR: Shell syntax verification failed!"
    exit 1
fi
echo "  ✓ All shell scripts passed syntax inspection."

# Gate 2: Targeted Subsystem Verification
echo "[2/4] Running targeted verification gate..."
if [ -n "$TARGET_TEST" ] && [ -f "$TARGET_TEST" ]; then
    echo "  Executing specified test suite: $TARGET_TEST"
    if ! (cd "$LODGE_DIR" && bash "$TARGET_TEST"); then
        echo "ERROR: Targeted test $TARGET_TEST failed!"
        exit 1
    fi
    echo "  ✓ Targeted test passed: $TARGET_TEST"
elif [ -n "$TARGET_SCOPE" ]; then
    matched_test=""
    case "$TARGET_SCOPE" in
        native_tools|tools|bash_exec) matched_test="$LODGE_DIR/tests/test_native_tools.sh" ;;
        react|agent) matched_test="$LODGE_DIR/tests/test_react.sh" ;;
        fifo|ipc|fifo_ipc) matched_test="$LODGE_DIR/tests/test_fifo_gc.sh" ;;
        auth|identity) matched_test="$LODGE_DIR/tests/test_auth_identity.sh" ;;
        endpoints|inference) matched_test="$LODGE_DIR/tests/test_endpoints.sh" ;;
        phytology) matched_test="$LODGE_DIR/tests/test_phytology.sh" ;;
        *) matched_test="" ;;
    esac

    if [ -n "$matched_test" ] && [ -f "$matched_test" ]; then
        echo "  Executing scope ($TARGET_SCOPE) test: $matched_test"
        if ! (cd "$LODGE_DIR" && bash "$matched_test"); then
            echo "ERROR: Scope verification test $matched_test failed!"
            exit 1
        fi
        echo "  ✓ Scope verification passed."
    else
        echo "  (No specific test suite mapped for scope: $TARGET_SCOPE, syntax validated)"
    fi
else
    echo "  (No targeted scope specified, syntax validated)"
fi

# Gate 3: Software Phytology & Living Tissue Verification
echo "[3/4] Running software phytology diagnostic audit..."
if [ -f "$LODGE_DIR/lib/agents/phytology.sh" ]; then
    if (cd "$LODGE_DIR" && bash -c "source '$LODGE_DIR/lib/agents/phytology.sh' && phytology_audit" &>/dev/null); then
        echo "  ✓ All monitored foliage verified AST healthy."
    else
        echo "  ⚠ Phytology audit warned (non-fatal living tissue check)."
    fi
fi

# Gate 4: GitFlow Branch Protection Audit
echo "[4/4] Auditing GitFlow branch protection rules..."
current_branch=$(git -C "$LODGE_DIR" branch --show-current 2>/dev/null || echo "unknown")
echo "  Current working branch: $current_branch"
if [ "$current_branch" = "main" ] || [ "$current_branch" = "master" ]; then
    echo "ERROR: Direct pushes or commits to main/master are strictly prohibited by GitFlow policy!"
    exit 1
fi
echo "  ✓ Branch protection policy satisfied ($current_branch != main)."

echo "═══════════════════════════════════════════════════════════"
echo "✓ Local CI Verification Complete: All Gates Passed!"
echo "═══════════════════════════════════════════════════════════"
exit 0
