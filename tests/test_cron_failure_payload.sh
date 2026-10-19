#!/usr/bin/env bash
# Tests the system.job_failure payload contract emitted by lib/sys/cron.sh
# Contract (D1/1.2): {job, job_id, label, exit_code, log, stderr_tail, wall_s}
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"

LODGE_DIR="$GEORGE_TEST_REPO"
export LODGE_DIR
# Only the pure helper is under test; stub UI so sourcing is quiet.
ui_step() { :; }; ui_err() { :; }; ui_ok() { :; }; ui_warn() { :; }
source "$LODGE_DIR/lib/sys/cron.sh" 2>/dev/null

test_start "cron job_failure payload contract"

assert_fn_defined _cron_job_failure_payload

tmp_log="$(mktemp)"
{
    for i in $(seq 1 100); do echo "line $i"; done
    printf '\033[31mERROR: boom\033[0m\n'
    echo "curl -H 'Authorization: Bearer abcDEF123.secret' token=xyz987 api_key=KEY123"
} > "$tmp_log"

start=$(( $(date +%s) - 7 ))
payload="$(_cron_job_failure_payload "eval_job" 3 "$tmp_log" "$start" 2>/dev/null)"

jq -e . >/dev/null 2>&1 <<<"$payload"
assert_ok $? "payload must be valid JSON: $payload"
assert_eq "$(jq -r '.job' <<<"$payload")"       "eval_job"
assert_eq "$(jq -r '.job_id' <<<"$payload")"    "eval_job"
assert_eq "$(jq -r '.label' <<<"$payload")"     "eval_job"
assert_eq "$(jq -r '.exit_code' <<<"$payload")" "3"
assert_eq "$(jq -r '.log' <<<"$payload")"       "$tmp_log"

wall="$(jq -r '.wall_s // 0' <<<"$payload" 2>/dev/null)"
assert_match "$wall" '^[0-9]+$' "wall_s must be an integer, got '$wall'"
[[ "$wall" =~ ^[0-9]+$ ]] || wall=0
[ "$wall" -ge 7 ] && [ "$wall" -lt 60 ]
assert_ok $? "wall_s should be ~7, got $wall"

tail_txt="$(jq -r '.stderr_tail // ""' <<<"$payload" 2>/dev/null)"
assert_contains     "$tail_txt" "ERROR: boom"
assert_not_contains "$tail_txt" $'line 5\n' "early lines must be dropped"
assert_not_contains "$tail_txt" $'\033'     "ANSI must be stripped"
assert_not_contains "$tail_txt" "abcDEF123" "bearer must be redacted"
assert_not_contains "$tail_txt" "xyz987"    "token must be redacted"
assert_not_contains "$tail_txt" "KEY123"    "api_key must be redacted"
[ "${#tail_txt}" -le 4000 ]
assert_ok $? "tail must be <=4000 chars"

# Missing log + no start -> still valid, empty tail, wall_s 0.
p2="$(_cron_job_failure_payload "j2" 1 "/nonexistent/log" "" 2>/dev/null)"
assert_eq "$(jq -r '.stderr_tail' <<<"$p2" 2>/dev/null)" ""
assert_eq "$(jq -r '.wall_s' <<<"$p2" 2>/dev/null)" "0"

rm -f "$tmp_log"
test_end
