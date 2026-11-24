#!/usr/bin/env bash
# Liveness heartbeats (refinement P1/1.6)
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"
LODGE_DIR="$GEORGE_TEST_REPO"; export LODGE_DIR
unset _LIB_HEARTBEATS_LOADED
source "$LODGE_DIR/lib/sys/heartbeats.sh"

test_start "heartbeats"

assert_fn_defined heartbeat_write
assert_fn_defined heartbeat_stale

describe "write"
heartbeat_write cron
f="$GEORGE_DIR/heartbeats/cron.json"
assert_file_exists "$f"
assert_eq "$(jq -r '.name' "$f")" "cron"
assert_match "$(jq -r '.ts' "$f")" '^[0-9]+$'
heartbeat_write remediation '{"queue_depth":3,"mode":"propose"}'
assert_eq "$(jq -r '.queue_depth' "$GEORGE_DIR/heartbeats/remediation.json")" "3"
assert_eq "$(jq -r '.name' "$GEORGE_DIR/heartbeats/remediation.json")" "remediation"

describe "name validation"
heartbeat_write '../evil' >/dev/null 2>&1
assert_eq "$?" "1" "path traversal names rejected"
assert_file_not_exists "$GEORGE_DIR/evil.json"

describe "staleness"
heartbeat_stale 1800 >/dev/null
assert_eq "$?" "0" "fresh heartbeats are not stale"
old=$(( $(date +%s) - 4000 ))
jq --argjson t "$old" '.ts = $t' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
out="$(heartbeat_stale 1800)"; rc=$?
assert_eq "$rc" "1" "stale heartbeat reported"
assert_contains "$out" '"name":"cron"'
assert_not_contains "$out" '"name":"remediation"'

describe "cron + remediation integration"
ui_step() { :; }; ui_err() { :; }; ui_ok() { :; }; ui_warn() { :; }
source "$LODGE_DIR/lib/sys/cron.sh" 2>/dev/null
assert_fn_contains _cron_loop_runner heartbeat_write
source "$LODGE_DIR/lib/agents/remediation.sh" 2>/dev/null
assert_fn_contains remediation_heartbeat heartbeat_write

test_end
