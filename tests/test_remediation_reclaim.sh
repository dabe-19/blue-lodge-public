#!/bin/bash
# ── Tests: Remediation orphan reclaim, apply-mode gate, job-failure contract ──
# Refinement plan Phase 1 (1.2, 1.5, 1.6). Fully sandboxed: never touches live .george.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"
source "$TEST_DIR/framework.sh"

_setup() {
    _t=$(mktemp -d /tmp/george-remed-reclaim-XXXXXX)
    export LODGE_DIR="$REPO_DIR"
    export GEORGE_DIR="$_t/.george"
    export REMEDIATION_DIR="$GEORGE_DIR/remediation"
    export GITEA_URL="http://127.0.0.1:9"          # unreachable -> no network side effects
    export EVENT_BUS_DIR="$_t/bus"
    unset _LIB_REMEDIATION_LOADED
    source "$REPO_DIR/lib/agents/remediation.sh"
    gitea_is_online() { return 1; }                  # hard-disable Gitea in tests
    remediation_run() { echo "RUN_CALLED" >> "$_t/run_calls"; }  # never launch a worker
    remediation_init
}
_teardown() { rm -rf "$_t"; }

_mk_item() { # $1=dir $2=task_id $3=age_secs [$4=extra jq]
    local f="$REMEDIATION_DIR/$1/$2.json" ts=$(( $(date +%s) - $3 ))
    jq -n --arg id "$2" --argjson ts "$ts" '{task_id:$id,title:"t",fingerprint:("fp_"+$id),status:"IN_PROGRESS",created_ts:$ts}' > "$f"
    [ -n "${4:-}" ] && jq "$4" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    touch -d "@$ts" "$f"
}

test_start "Remediation reclaim, apply-mode gate & job-failure contract"

describe "remediation_is_active / orphan reclaim"

it "treats an in_progress item with no live lock as an orphan (not active)" && {
    _setup
    _mk_item in_progress rem_orphan 600
    remediation_is_active; rc=$?
    assert_eq "$rc" "1"
    _teardown
}

it "requeues a first-time orphan with reclaim_count=1" && {
    _setup
    _mk_item in_progress rem_orphan 600
    remediation_is_active >/dev/null
    assert_file_exists "$REMEDIATION_DIR/queue/rem_orphan.json"
    assert_eq "$(jq -r .reclaim_count "$REMEDIATION_DIR/queue/rem_orphan.json")" "1"
    assert_eq "$(jq -r .status "$REMEDIATION_DIR/queue/rem_orphan.json")" "QUEUED"
    _teardown
}

it "fails an orphan that was already reclaimed once" && {
    _setup
    _mk_item in_progress rem_twice 600 '.reclaim_count = 1'
    remediation_is_active >/dev/null
    assert_file_exists "$REMEDIATION_DIR/failed/rem_twice.json"
    assert_eq "$(jq -r .status "$REMEDIATION_DIR/failed/rem_twice.json")" "ORPHANED_RECLAIMED"
    _teardown
}

it "fails an orphan older than the TTL even on first reclaim" && {
    _setup
    _mk_item in_progress rem_ancient $(( 8 * 86400 ))
    remediation_is_active >/dev/null
    assert_file_exists "$REMEDIATION_DIR/failed/rem_ancient.json"
    _teardown
}

it "reports active and leaves in_progress untouched while a live runner holds the lock" && {
    _setup
    _mk_item in_progress rem_live 60
    sleep 300 & live=$!
    echo "$live" > "$REMEDIATION_DIR/.lock"
    remediation_is_active; rc=$?
    kill "$live" 2>/dev/null
    assert_eq "$rc" "0"
    assert_file_exists "$REMEDIATION_DIR/in_progress/rem_live.json"
    _teardown
}

describe "apply mode (propose-only during migration)"

it "defaults to propose" && {
    _setup
    assert_eq "$(remediation_apply_mode)" "propose"
    _teardown
}

it "honours the mode file" && {
    _setup
    echo auto > "$REMEDIATION_DIR/mode"
    assert_eq "$(remediation_apply_mode)" "auto"
    echo "garbage; rm -rf /" > "$REMEDIATION_DIR/mode"
    assert_eq "$(remediation_apply_mode)" "propose"
    _teardown
}

describe "write-scope denylist"

it "flags changes to denylisted paths" && {
    _setup
    out=$(printf 'lib/core/react.sh\nlib/tools/foo.sh\n' | remediation_scope_violations_from_list)
    assert_contains "$out" "lib/core/react.sh"
    _teardown
}

it "passes changes outside the denylist" && {
    _setup
    out=$(printf '.george/cron_jobs/weather_report.sh\nlib/tools/foo.sh\n' | remediation_scope_violations_from_list)
    assert_eq "$out" ""
    _teardown
}

describe "system.job_failure contract (producer {job,...} -> consumer)"

it "derives title and fingerprint from the job field" && {
    _setup
    qid=$(remediation_event_ingress "system.job_failure" '{"job":"weather_report","exit_code":137,"log":"/tmp/x.log","stderr_tail":"Killed"}' 2>/dev/null | tail -1)
    qf="$REMEDIATION_DIR/queue/${qid}.json"
    assert_file_exists "$qf"
    assert_contains "$(jq -r .title "$qf")" "weather_report"
    assert_eq "$(jq -r .fingerprint "$qf")" "job_fail_weather_report"
    _teardown
}

it "does not collapse different jobs into one fingerprint" && {
    _setup
    remediation_event_ingress "system.job_failure" '{"job":"job_a","exit_code":1}' >/dev/null 2>&1
    remediation_event_ingress "system.job_failure" '{"job":"job_b","exit_code":1}' >/dev/null 2>&1
    n=$(ls "$REMEDIATION_DIR/queue/"*.json 2>/dev/null | wc -l)
    assert_eq "$n" "2"
    _teardown
}

describe "heartbeat"

it "writes a heartbeat file with epoch and queue depth" && {
    _setup
    _mk_item queue rem_q1 10
    remediation_heartbeat >/dev/null 2>&1
    assert_file_exists "$REMEDIATION_DIR/.heartbeat"
    assert_eq "$(jq -r .queue_depth "$REMEDIATION_DIR/.heartbeat")" "1"
    _teardown
}

test_end
