#!/bin/bash
# ── George Test Framework ──────────────────────────────────────
# Minimal pure-bash unit test framework. No dependencies beyond bash.
#
# Usage in test files:
#   source "$(dirname "$0")/framework.sh"
#   test_start "Module Name"
#   describe "function_name"
#     it "should do something" && {
#       result=$(some_function "input")
#       assert_eq "$result" "expected"
#     }
#   test_end
#
# Assertions:
#   assert_eq   VALUE EXPECTED [MSG]  — string equality
#   assert_neq  VALUE EXPECTED [MSG]  — string inequality
#   assert_contains STR SUBSTR [MSG]  — substring match
#   assert_not_contains STR SUBSTR    — no substring match
#   assert_match STR PATTERN [MSG]    — regex match
#   assert_ok   EXIT_CODE [MSG]       — exit code 0
#   assert_fail EXIT_CODE [MSG]       — non-zero exit code
#   assert_file_exists PATH [MSG]     — file exists
#   assert_file_not_exists PATH [MSG] — file does not exist
#   assert_dir_exists PATH [MSG]      — directory exists
#   assert_empty VAR [MSG]            — variable is empty
#   assert_not_empty VAR [MSG]        — variable is not empty
#   assert_gt N M [MSG]               — N > M (numeric)

set -uo pipefail

# ── State ──────────────────────────────────────────────────────
_TEST_TOTAL=0
_TEST_PASSED=0
_TEST_FAILED=0
_TEST_SKIPPED=0
_TEST_ERRORS=()
_TEST_MODULE=""
_TEST_DESCRIBE=""
_CURRENT_TEST=""

# ── Colors ─────────────────────────────────────────────────────
_T_RED='\033[38;5;203m'
_T_GREEN='\033[38;5;114m'
_T_YELLOW='\033[38;5;221m'
_T_BLUE='\033[38;5;75m'
_T_DIM='\033[2m'
_T_BOLD='\033[1m'
_T_RESET='\033[0m'

# ── Helpers ────────────────────────────────────────────────────
_test_pass() {
    _TEST_TOTAL=$((_TEST_TOTAL + 1))
    _TEST_PASSED=$((_TEST_PASSED + 1))
    printf "    ${_T_GREEN}✓${_T_RESET} %s\n" "$_CURRENT_TEST"
}

_test_fail() {
    local msg="${1:-}"
    _TEST_TOTAL=$((_TEST_TOTAL + 1))
    _TEST_FAILED=$((_TEST_FAILED + 1))
    printf "    ${_T_RED}✗${_T_RESET} %s\n" "$_CURRENT_TEST"
    if [ -n "$msg" ]; then
        printf "      ${_T_RED}%s${_T_RESET}\n" "$msg"
    fi
    _TEST_ERRORS+=("$_TEST_DESCRIBE > $_CURRENT_TEST: $msg")
}

_test_skip() {
    local reason="${1:-}"
    _TEST_TOTAL=$((_TEST_TOTAL + 1))
    _TEST_SKIPPED=$((_TEST_SKIPPED + 1))
    printf "    ${_T_YELLOW}⊘${_T_RESET} %s ${_T_DIM}(skipped: %s)${_T_RESET}\n" "$_CURRENT_TEST" "$reason"
}

# ── Structural ─────────────────────────────────────────────────
test_start() {
    _TEST_MODULE="$1"
    _TEST_TOTAL=0
    _TEST_PASSED=0
    _TEST_FAILED=0
    _TEST_SKIPPED=0
    _TEST_ERRORS=()
    echo ""
    printf "${_T_BOLD}${_T_BLUE}━━ %s ━━${_T_RESET}\n" "$_TEST_MODULE"
}

describe() {
    _TEST_DESCRIBE="$1"
    echo ""
    printf "  ${_T_BOLD}%s${_T_RESET}\n" "$_TEST_DESCRIBE"
}

it() {
    _CURRENT_TEST="$1"
    return 0  # proceed to test body
}

skip() {
    _test_skip "$1"
    return 1  # skip test body
}

# ── Assertions ─────────────────────────────────────────────────
assert_eq() {
    local actual="$1"
    local expected="$2"
    local msg="${3:-Expected '$expected', got '$actual'}"
    if [ "$actual" = "$expected" ]; then
        _test_pass
    else
        _test_fail "$msg"
    fi
}

assert_neq() {
    local actual="$1"
    local not_expected="$2"
    local msg="${3:-Expected not '$not_expected', but got it}"
    if [ "$actual" != "$not_expected" ]; then
        _test_pass
    else
        _test_fail "$msg"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-Expected '$haystack' to contain '$needle'}"
    if [[ "$haystack" == *"$needle"* ]]; then
        _test_pass
    else
        _test_fail "$msg"
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-Expected '$haystack' NOT to contain '$needle'}"
    if [[ "$haystack" != *"$needle"* ]]; then
        _test_pass
    else
        _test_fail "$msg"
    fi
}

assert_match() {
    local value="$1"
    local pattern="$2"
    local msg="${3:-Expected '$value' to match pattern '$pattern'}"
    if [[ "$value" =~ $pattern ]]; then
        _test_pass
    else
        _test_fail "$msg"
    fi
}

assert_ok() {
    local exit_code="$1"
    local msg="${2:-Expected exit code 0, got $exit_code}"
    # Treat SIGPIPE (141) as success — happens when `echo "$body" | grep -q`
    # finds a match and closes the pipe while echo is still writing.
    # With pipefail enabled, the pipe exit code becomes 141 instead of 0.
    # This is normal grep behavior, not a test failure.
    if [ "$exit_code" -eq 0 ] || [ "$exit_code" -eq 141 ]; then
        _test_pass
    else
        _test_fail "$msg"
    fi
}

assert_fail() {
    local exit_code="$1"
    local msg="${2:-Expected non-zero exit code, got 0}"
    if [ "$exit_code" -ne 0 ]; then
        _test_pass
    else
        _test_fail "$msg"
    fi
}

assert_file_exists() {
    local path="$1"
    local msg="${2:-Expected file to exist: $path}"
    if [ -f "$path" ]; then
        _test_pass
    else
        _test_fail "$msg"
    fi
}

assert_file_not_exists() {
    local path="$1"
    local msg="${2:-Expected file NOT to exist: $path}"
    if [ ! -f "$path" ]; then
        _test_pass
    else
        _test_fail "$msg"
    fi
}

assert_dir_exists() {
    local path="$1"
    local msg="${2:-Expected directory to exist: $path}"
    if [ -d "$path" ]; then
        _test_pass
    else
        _test_fail "$msg"
    fi
}

assert_empty() {
    local value="$1"
    local msg="${2:-Expected empty string, got '$value'}"
    if [ -z "$value" ]; then
        _test_pass
    else
        _test_fail "$msg"
    fi
}

assert_not_empty() {
    local value="$1"
    local msg="${2:-Expected non-empty string}"
    if [ -n "$value" ]; then
        _test_pass
    else
        _test_fail "$msg"
    fi
}

assert_gt() {
    local actual="$1"
    local threshold="$2"
    local msg="${3:-Expected $actual > $threshold}"
    if [ "$actual" -gt "$threshold" ]; then
        _test_pass
    else
        _test_fail "$msg"
    fi
}

# ── Report ─────────────────────────────────────────────────────
test_end() {
    echo ""
    printf "${_T_DIM}──────────────────────────────────────${_T_RESET}\n"
    printf "  ${_T_GREEN}%d passed${_T_RESET}" "$_TEST_PASSED"
    if [ "$_TEST_FAILED" -gt 0 ]; then
        printf "  ${_T_RED}%d failed${_T_RESET}" "$_TEST_FAILED"
    fi
    if [ "$_TEST_SKIPPED" -gt 0 ]; then
        printf "  ${_T_YELLOW}%d skipped${_T_RESET}" "$_TEST_SKIPPED"
    fi
    printf "  ${_T_DIM}(%d total)${_T_RESET}\n" "$_TEST_TOTAL"

    if [ ${#_TEST_ERRORS[@]} -gt 0 ]; then
        echo ""
        printf "  ${_T_RED}${_T_BOLD}Failures:${_T_RESET}\n"
        for err in "${_TEST_ERRORS[@]}"; do
            printf "    ${_T_RED}• %s${_T_RESET}\n" "$err"
        done
    fi

    # Return exit code for CI
    [ "$_TEST_FAILED" -eq 0 ]
}

# ── Temp dir helper ────────────────────────────────────────────
# Creates a clean temp directory, returns path. Caller should clean up.
test_tmpdir() {
    local dir
    dir=$(mktemp -d /tmp/george-test-XXXXXX)
    echo "$dir"
}

# ── Mock helper ────────────────────────────────────────────────
# Override a function with a mock. Restores on test_unmock.
declare -A _MOCK_ORIGINALS

test_mock() {
    local func_name="$1"
    local mock_body="$2"
    # Save original if not already saved
    if [ -z "${_MOCK_ORIGINALS[$func_name]:-}" ]; then
        _MOCK_ORIGINALS[$func_name]=$(declare -f "$func_name" 2>/dev/null || echo "")
    fi
    eval "$func_name() { $mock_body; }"
}

test_unmock() {
    local func_name="$1"
    if [ -n "${_MOCK_ORIGINALS[$func_name]:-}" ]; then
        eval "${_MOCK_ORIGINALS[$func_name]}"
        unset "_MOCK_ORIGINALS[$func_name]"
    fi
}

test_unmock_all() {
    for func_name in "${!_MOCK_ORIGINALS[@]}"; do
        test_unmock "$func_name"
    done
}

# ── Setup LODGE_DIR for testing ────────────────────────────────
# Points LODGE_DIR to the repo root, sets up a clean test environment.
# GEORGE_CONFIG_DIR is set to a fresh temp directory so tests never
# read the real lodge.conf (which would leak persisted user settings
# into assertions about code defaults).
_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LODGE_DIR="$(dirname "$_TESTS_DIR")"
# Redirect stdin of the test shell to /dev/null so any interactive prompts immediately return EOF and do not hang/suspend.
exec 0</dev/null
_FRAMEWORK_CONFIG_DIR=$(mktemp -d /tmp/george-test-config-XXXXXX)
export GEORGE_CONFIG_DIR="$_FRAMEWORK_CONFIG_DIR"
# Cleanup on exit
trap 'rm -rf "$_FRAMEWORK_CONFIG_DIR" 2>/dev/null' EXIT
