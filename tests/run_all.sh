#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# ⌂ Blue Lodge — Automated Test Suite Runner
# ═══════════════════════════════════════════════════════════════
# Discovers and runs all test_*.sh files in the tests/ directory.
# Reports per-file and aggregate results. Exit code reflects
# overall pass/fail for CI integration.
#
# Usage:
#   bash tests/run_all.sh              # Run all tests
#   bash tests/run_all.sh test_ui      # Run specific test(s)
#   bash tests/run_all.sh -v           # Verbose (show all output)
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LODGE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
export LODGE_DIR

# ── Process guard (no lockfile) ───────────────────────────────
# Prevent overlapping full-suite runs in the same workspace. A timed-out
# foreground run can continue in the background; starting another run_all
# in that window doubles load and makes MCP suites look "stuck".
if [ "${RUN_ALL_ALLOW_CONCURRENT:-1}" != "1" ]; then
    _existing_pid=$(ps -eo pid=,etimes=,args= | awk -v self="$$" -v script="$TESTS_DIR/run_all.sh" '
        {
            pid=$1
            age=$2
            line=$0
            if (pid == self) next
            if (age < 2) next
            if (index(line, script) > 0 || line ~ /(^|[[:space:]])tests\/run_all\.sh([[:space:]]|$)/) {
                print pid
                exit
            }
        }
    ')

    if [ -n "${_existing_pid:-}" ]; then
        echo ""
        echo "Another test suite run is already active (pid $_existing_pid)."
        echo "Refusing to start a second concurrent run_all.sh."
        echo "If you intentionally want overlap, set RUN_ALL_ALLOW_CONCURRENT=1."
        exit 2
    fi
fi
# ── Colors ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Parse args ─────────────────────────────────────────────────
VERBOSE=0
FILTER=()
for arg in "$@"; do
    if [ "$arg" = "-v" ] || [ "$arg" = "--verbose" ]; then
        VERBOSE=1
    elif [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
        echo "Usage: $0 [-v|--verbose] [test_name ...]"
        echo ""
        echo "Options:"
        echo "  -v, --verbose    Show full test output"
        echo "  -h, --help       Show this help"
        echo ""
        echo "Examples:"
        echo "  $0                     Run all tests"
        echo "  $0 test_ui test_llm    Run specific tests"
        echo "  $0 -v test_api         Verbose single test"
        exit 0
    else
        FILTER+=("$arg")
    fi
done

# ── Banner ─────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  ⌂ Blue Lodge — Test Suite${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${DIM}  LODGE_DIR: $LODGE_DIR${RESET}"
echo -e "${DIM}  $(date)${RESET}"
echo ""

# ── Discover tests ─────────────────────────────────────────────
test_files=()
if [ ${#FILTER[@]} -gt 0 ]; then
    for name in "${FILTER[@]}"; do
        # Allow with or without test_ prefix and .sh suffix
        name="${name#test_}"
        name="${name%.sh}"
        local_file="$TESTS_DIR/test_${name}.sh"
        if [ -f "$local_file" ]; then
            test_files+=("$local_file")
        else
            echo -e "${RED}  ✗ Not found: test_${name}.sh${RESET}"
        fi
    done
else
    while IFS= read -r f; do
        test_files+=("$f")
    done < <(find "$TESTS_DIR" -name 'test_*.sh' -type f | sort)
fi

if [ ${#test_files[@]} -eq 0 ]; then
    echo -e "${RED}No test files found.${RESET}"
    exit 1
fi

echo -e "${CYAN}  Found ${#test_files[@]} test file(s)${RESET}"
echo ""

# ── Run tests ──────────────────────────────────────────────────
total_files=0
passed_files=0
failed_files=0
failed_names=()

total_start=$(date +%s)

for test_file in "${test_files[@]}"; do
    name=$(basename "$test_file" .sh)
    total_files=$((total_files + 1))
    
    echo -e "${BOLD}── ${name} ──${RESET}"
    
    file_start=$(date +%s)
    
    if [ "$VERBOSE" -eq 1 ]; then
        # Show all output
        bash "$test_file"
        result=$?
    else
        # Capture output, show only on failure or summary line
        output=$(bash "$test_file" 2>&1)
        result=$?
    fi
    
    file_end=$(date +%s)
    file_elapsed=$((file_end - file_start))
    
    if [ "$result" -eq 0 ]; then
        passed_files=$((passed_files + 1))
        if [ "$VERBOSE" -eq 0 ]; then
            # Show just the summary line from the test output
            summary=$(echo "$output" | grep -E '^[[:space:]]*(PASS|✓|Tests:)' | tail -1)
            if [ -n "$summary" ]; then
                echo -e "  ${GREEN}✓${RESET} $summary ${DIM}(${file_elapsed}s)${RESET}"
            else
                echo -e "  ${GREEN}✓ PASSED${RESET} ${DIM}(${file_elapsed}s)${RESET}"
            fi
        else
            echo -e "  ${GREEN}✓ PASSED${RESET} ${DIM}(${file_elapsed}s)${RESET}"
        fi
    else
        failed_files=$((failed_files + 1))
        failed_names+=("$name")
        if [ "$VERBOSE" -eq 0 ]; then
            # Show all output on failure so user can debug
            echo "$output"
        fi
        echo -e "  ${RED}✗ FAILED${RESET} ${DIM}(${file_elapsed}s)${RESET}"
    fi
    
    echo ""
done

# ── Summary ────────────────────────────────────────────────────
total_end=$(date +%s)
total_elapsed=$((total_end - total_start))

echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Results${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  Files:  ${total_files}"
echo -e "  Passed: ${GREEN}${passed_files}${RESET}"
echo -e "  Failed: ${RED}${failed_files}${RESET}"
echo -e "  Time:   ${total_elapsed}s"
echo ""

if [ ${#failed_names[@]} -gt 0 ]; then
    echo -e "  ${RED}Failed tests:${RESET}"
    for name in "${failed_names[@]}"; do
        echo -e "    ${RED}✗${RESET} $name"
    done
    echo ""
fi

if [ "$failed_files" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}All tests passed. ✓${RESET}"
    echo ""
    exit 0
else
    echo -e "  ${RED}${BOLD}${failed_files} test file(s) failed.${RESET}"
    echo ""
    exit 1
fi
