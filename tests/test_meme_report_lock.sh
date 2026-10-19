#!/bin/bash
# ── Tests: .george/cron_jobs/meme_report.sh — lock-aware one-shot hand-off ──
# Regression suite for fingerprint job_fail_meme_report (Gitea issue #487).
#
# Root cause under test: the cron daemon launches custom jobs concurrently in
# the background, and the one-shot `lodge` task mode takes an exclusive
# workspace lock (${GEORGE_CONFIG_DIR:-$LODGE_DIR/.george}/.lodge.lock,
# live-PID gate). When a concurrent job holds that lock, the job must NOT
# exit 1 — it must wait (bounded), reclaim stale locks, then either run the
# full agentic ReAct report or degrade to an honest deferral note and exit 0
# (state file untouched so the next tick can still deliver).
#
# The suite builds a disposable fixture workspace (stub `lodge`, stub Discord
# bridge) and drives the real job script against it with FORCE=1 so the
# Monday-morning self-gate is bypassed deterministically.

source "$(dirname "$0")/framework.sh"

JOB_SCRIPT="$LODGE_DIR/.george/cron_jobs/meme_report.sh"

_test_mm_holder_pid=""
_test_mm_tmp=""

_setup_mm_fixture() {
    # Args: $1 = fixture root
    local root="$1"
    mkdir -p "$root/.george" "$root/lib/comms"

    # Stub `lodge`: marks execution and exits with a sentinel code (7).
    cat > "$root/lodge" <<EOF
#!/bin/bash
echo "LODGE_STUB_RAN \$@" > "${root}/lodge_ran"
exit 7
EOF
    chmod +x "$root/lodge"

    # Stub Discord bridge: the job sources this ONLY on the degradation path.
    cat > "$root/lib/comms/social.sh" <<EOF
#!/bin/bash
discord_send() {
    printf '%s
' "\$2" > "${root}/discord_msg.txt"
    return 0
}
EOF
    return 0
}

_run_mm_job() {
    # Args: $1 = fixture root, $2 = lock wait max, $3 = poll interval
    # Defence-in-depth: refuse to run unless the fixture `lodge` stub is in
    # place, so a broken fixture can never fall through to the real lodge.
    local root="$1" wait_max="$2" poll="$3"
    [ -x "${root}/lodge" ] || { echo "FATAL(fixture): no lodge stub in $root" > "${root}/job.log"; return 99; }
    env LODGE_DIR="$root" \
        GEORGE_DIR="$root/.george" \
        GEORGE_CONFIG_DIR="$root/.george" \
        FORCE=1 \
        MEME_LOCK_WAIT_MAX="$wait_max" \
        MEME_LOCK_POLL="$poll" \
        bash "$JOB_SCRIPT" > "${root}/job.log" 2>&1
    return $?
}

_mm_teardown() {
    [ -n "$_test_mm_holder_pid" ] && kill "$_test_mm_holder_pid" 2>/dev/null
    _test_mm_holder_pid=""
    [ -n "$_test_mm_tmp" ] && rm -rf "$_test_mm_tmp"
    _test_mm_tmp=""
}

test_start "meme_report lock-aware hand-off (job_fail_meme_report #487)"

[ -f "$JOB_SCRIPT" ] || { echo "FATAL: job script missing: $JOB_SCRIPT"; exit 1; }

describe "Lock contention (original failure reproduction)"
  it "defers honestly and exits 0 when lock held by live PID" && {
    _test_mm_tmp=$(test_tmpdir)
    _setup_mm_fixture "$_test_mm_tmp"
    sleep 300 & _test_mm_holder_pid=$!
    echo "$_test_mm_holder_pid" > "$_test_mm_tmp/.george/.lodge.lock"
    rc=0; _run_mm_job "$_test_mm_tmp" 3 1 || rc=$?
    assert_eq 0 $rc "job must exit 0, not 1 (original failure)"
    assert_contains "$(cat "$_test_mm_tmp/job.log")" "deferring this cycle"
    assert_file_exists "$_test_mm_tmp/discord_msg.txt" "deferral note must reach the Discord bridge"
    assert_contains "$(cat "$_test_mm_tmp/discord_msg.txt")" "deferred" "deferral note is honestly labeled"
    assert_file_not_exists "$_test_mm_tmp/lodge_ran" "agentic phase must be skipped in degradation"
    assert_file_not_exists "$_test_mm_tmp/.george/cron_jobs/.meme_report_last_sent" "state file must stay untouched so the next tick can deliver"
    _mm_teardown
  }

describe "Lock wait and release"
  it "waits for lock release then runs full agentic report" && {
    _test_mm_tmp=$(test_tmpdir)
    _setup_mm_fixture "$_test_mm_tmp"
    sleep 2 & _test_mm_holder_pid=$!
    echo "$_test_mm_holder_pid" > "$_test_mm_tmp/.george/.lodge.lock"
    rc=0; _run_mm_job "$_test_mm_tmp" 15 1 || rc=$?
    assert_eq 7 $rc "job must exec the agentic lodge phase (stub sentinel 7)"
    assert_file_exists "$_test_mm_tmp/lodge_ran"
    assert_contains "$(cat "$_test_mm_tmp/job.log")" "waiting up to" "must log the bounded wait"
    assert_not_contains "$(cat "$_test_mm_tmp/job.log")" "deferring" "no deferral when lock frees in time"
    _mm_teardown
  }

  it "runs the agentic report immediately when no lock file exists" && {
    _test_mm_tmp=$(test_tmpdir)
    _setup_mm_fixture "$_test_mm_tmp"
    rc=0; _run_mm_job "$_test_mm_tmp" 3 1 || rc=$?
    assert_eq 7 $rc
    assert_file_exists "$_test_mm_tmp/lodge_ran"
    assert_not_contains "$(cat "$_test_mm_tmp/job.log")" "waiting up to"
    _mm_teardown
  }

  it "reclaims a stale lock (dead holder PID) immediately" && {
    _test_mm_tmp=$(test_tmpdir)
    _setup_mm_fixture "$_test_mm_tmp"
    # Spawn a short-lived process and use its (now dead) PID as the holder.
    dead_pid=
    sleep 0.05 & dead_pid=$!
    wait "$dead_pid" 2>/dev/null
    kill -0 "$dead_pid" 2>/dev/null && { echo "FATAL: PID not dead"; return 1; }
    echo "$dead_pid" > "$_test_mm_tmp/.george/.lodge.lock"
    rc=0; _run_mm_job "$_test_mm_tmp" 3 1 || rc=$?
    assert_eq 7 $rc "stale lock must not block the agentic phase"
    assert_file_exists "$_test_mm_tmp/lodge_ran"
    assert_not_contains "$(cat "$_test_mm_tmp/job.log")" "waiting up to"
    _mm_teardown
  }

test_end

# (exit status comes from test_end)
