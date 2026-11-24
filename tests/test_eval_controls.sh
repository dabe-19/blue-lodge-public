#!/usr/bin/env bash
# Eval resource controls: /eval kill switch, harness tiers + per-category timeouts, nightly toggle.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"
LODGE_DIR="$GEORGE_TEST_REPO"; export LODGE_DIR

test_start "eval_controls"

G="$GEORGE_TEST_SANDBOX/g"; mkdir -p "$G/cron_jobs" "$G/eval" "$G/state"
EV() { GEORGE_DIR="$G" bash "$LODGE_DIR/commands/eval.sh" "$@" 2>&1; }
H() { EVAL_GEORGE_DIR="$G" bash "$LODGE_DIR/tests/eval/run_golden.sh" "$@" </dev/null 2>&1; }

describe "harness tiers and per-category timeouts (--list, no tasks run)"
smoke=$(H --tier smoke --list)
assert_eq "6" "$(grep -vc '^max_wall_s' <<<"$smoke")" "smoke tier = 6 tasks"
assert_not_contains "$smoke" "R1_scotus" "deep research report excluded from smoke"
assert_contains "$smoke" "$(printf 'A1_exfil\tadversarial\t240')" "adversarial timeout 240s"
full=$(H --list)
assert_eq "12" "$(grep -vc '^max_wall_s' <<<"$full")" "full tier = 12 tasks"
assert_contains "$full" "$(printf 'C1_weekly_meme_cron\tcron\t480')" "cron timeout 480s"
assert_contains "$(H --list --timeout 99 Q1_gpus)" "$(printf 'Q1_gpus\tfactual\t99')" "--timeout overrides"
assert_eq "2" "$(H --tier bogus --list >/dev/null; echo $?)" "invalid tier rejected"

describe "/eval off is a kill switch for the harness"
out=$(EV off "GPU busy; rendering")
assert_contains "$out" "Evals disabled" "off acknowledged"
assert_file_exists "$G/state/eval.disabled"
assert_contains "$(EV status)" "DISABLED" "status shows disabled"
hout=$(H --tier smoke --label t)
assert_contains "$hout" "evals are disabled" "harness refuses"
assert_eq "0" "$(find "$G/eval" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" "no run dir created"
assert_contains "$(EV run smoke)" "disabled" "/eval run refuses while disabled"
EV off 'x; rm -rf / $(id)' >/dev/null
assert_not_contains "$(cat "$G/state/eval.disabled")" '$(' "reason sanitized"
EV on >/dev/null
assert_file_not_exists "$G/state/eval.disabled"
assert_contains "$(EV status)" "Evals: enabled" "status enabled"

describe "nightly job ships OFF and toggles"
assert_eq "0" "$(grep -m1 '^# ENABLED:' "$LODGE_DIR/scripts/cron/nightly_golden_eval.sh" | awk '{print $3}')" "template ENABLED: 0"
EV nightly on >/dev/null
assert_eq "1" "$(grep -m1 '^# ENABLED:' "$G/cron_jobs/nightly_golden_eval.sh" | awk '{print $3}')" "nightly on installs + enables"
assert_contains "$(EV status)" "Nightly: on" "status nightly on"
EV nightly off >/dev/null
assert_contains "$(EV status)" "Nightly: off" "status nightly off"
assert_contains "$(grep -c -- '--tier' "$LODGE_DIR/scripts/cron/nightly_golden_eval.sh")" "1" "nightly passes --tier (smoke default)"
touch "$G/state/eval.disabled"
assert_contains "$(GEORGE_DIR="$G" NIGHTLY_EVAL_HOUR=$(date +%H) LODGE_DIR="$LODGE_DIR" bash "$LODGE_DIR/scripts/cron/nightly_golden_eval.sh")" "disabled" "nightly honors kill switch"
assert_file_not_exists "$G/state/nightly_eval.last"

describe "dispatcher calling convention (single arg string + workdir)"
rm -f "$G/state/eval.disabled"
out=$(GEORGE_DIR="$G" bash -c 'source "$1/commands/eval.sh"; cmd_eval "off maintenance window" "/tmp"' _ "$LODGE_DIR" 2>&1)
assert_contains "$(cat "$G/state/eval.disabled")" "maintenance window" "reason parsed from arg string"

test_end
