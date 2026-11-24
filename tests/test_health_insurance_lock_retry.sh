#!/bin/bash
# ── Tests: .george/cron_jobs/health_insurance_intel.sh — post-dispatch lock-collision retry ──
# Regression suite for fingerprint job_fail_health_insurance_intel
# (issue_remediation_1794014915_767, incident 2026-11-06 19:27).
#
# Root cause under test: TOCTOU lock race. The job's pre-flight lock guard passes
# when ${LOCK_FILE} is absent, but the one-shot `lodge` task mode re-checks the
# shared workspace lock only AFTER its startup window (source index + MCP
# auto-start, ~10s+). A concurrent lodge process (PID 3056732 in the incident)
# created the lock inside that window; the gate's 15s non-interactive wait
# expired and exited 1, which the job propagated as a genuine failure and which
# spawned a false remediation pipeline.
#
# Remediation under test (pure POSIX, job-local, no core-file mutation):
#   1. The monitored runner classifies a gate refusal ("Another lodge process"
#      in the run log, delivery unconfirmed) as condition code 2.
#   2. The driver re-enters a bounded lock wait (with stale-lock reclamation)
#      while a viable run budget remains under the wall cap, then retries ONCE.
#   3. If the lock persists past the retry budget the job defers gracefully
#      (exit 0) — house policy: lock contention must never hard-fail a
#      12h-cadence intel job and spawn a false remediation.
#
# The suite builds a disposable fixture workspace (stateful stub `lodge`, stub
# Discord bridge) and drives the real job script against it with small env
# budgets so every scenario completes in seconds.

source "$(dirname "$0")/framework.sh"

JOB_SCRIPT="$LODGE_DIR/.george/cron_jobs/health_insurance_intel.sh"

_test_hi_holder_pid=""
_test_hi_tmp=""

# Stub `lodge` behaviors (selected via STUB_MODE at run time):
#   collide_once        — 1st call: create lock w/ live holder, print gate
#                         refusal; 2nd call: delivery marker, success (rc 0)
#   always_collide      — every call: fresh long-lived holder + gate refusal
#   genuine_fail        — neutral log, exit 42
#   delivered_nonzero   — delivery marker, exit 1
#   clean               — delivery marker, success (rc 0)
_setup_hi_fixture() {
    local root="$1" mode="$2"
    mkdir -p "$root/.george" "$root/lib/comms"

    cat > "$root/lib/comms/discord_bridge.sh" <<'EOF'
#!/bin/bash
discord_channel_resolve() { echo ""; return 0; }
EOF

    # Fully-quoted heredoc: the stub resolves paths from its own environment
    # ($LODGE_DIR is exported by the job driver), never from fixture-setup time.
    cat > "$root/lodge" <<'EOF'
#!/bin/bash
LOG="${LODGE_DIR}/lodge_ran"
LOCKF="${LODGE_DIR}/.george/.lodge.lock"
echo "RAN" >> "$LOG"
n=$(wc -l < "$LOG" 2>/dev/null || echo 0)
case "${STUB_MODE:-clean}" in
    collide_once)
        if [ "$n" -le 1 ]; then
            sleep 5 & hp=$!
            disown 2>/dev/null || true
            echo "$hp" > "$LOCKF"
            echo "Indexed 3 sources"
            echo "Another lodge process (PID $hp) is already running in this workspace."
            echo "If this is a stale lock, run: rm -f $LOCKF"
            exit 1
        fi
        echo "Observation received from discord_send: delivered 1 chunk to #general"
        ;;
    always_collide)
        sleep 30 & hp=$!
        disown 2>/dev/null || true
        echo "$hp" > "$LOCKF"
        echo "Another lodge process (PID $hp) is already running in this workspace."
        exit 1
        ;;
    genuine_fail)
        echo "Indexed 3 sources"
        echo "research_sandbox crashed with an internal error"
        exit 42
        ;;
    delivered_nonzero)
        echo "Observation received from discord_send: delivered 1 chunk to #general"
        exit 1
        ;;
    clean)
        echo "Observation received from discord_send: delivered 1 chunk to #general"
        ;;
esac
EOF
    chmod +x "$root/lodge"
    return 0
}

_run_hi_job() {
    # Args: $1 = fixture root, $2 = MIN_RUN_BUDGET, $3 = STUB_MODE
    local root="$1" min_budget="$2" mode="$3"
    [ -x "${root}/lodge" ] || { echo "FATAL(fixture): no lodge stub in $root" > "${root}/job.log"; return 99; }
    env LODGE_DIR="$root" \
        GEORGE_CONFIG_DIR="$root/.george" \
        STUB_MODE="$mode" \
        HEALTH_INTEL_LOCK_WAIT=120 \
        HEALTH_INTEL_LOCK_POLL=1 \
        HEALTH_INTEL_WALL_MAX=120 \
        HEALTH_INTEL_MIN_RUN_BUDGET="$min_budget" \
        HEALTH_INTEL_POLL=1 \
        bash "$JOB_SCRIPT" > "${root}/job.log" 2>&1
    return $?
}

_hi_teardown() {
    if [ -n "$_test_hi_holder_pid" ]; then
        kill "$_test_hi_holder_pid" 2>/dev/null
        _test_hi_holder_pid=""
    fi
    # Any leftover long-lived lock holder written by the stub
    if [ -n "$_test_hi_tmp" ] && [ -f "$_test_hi_tmp/.george/.lodge.lock" ]; then
        _hi_leftover="$(cat "$_test_hi_tmp/.george/.lodge.lock" 2>/dev/null || true)"
        [ -n "$_hi_leftover" ] && kill "$_hi_leftover" 2>/dev/null
        rm -f "$_test_hi_tmp/.george/.lodge.lock" 2>/dev/null
    fi
    [ -n "$_test_hi_tmp" ] && rm -rf "$_test_hi_tmp"
    _test_hi_tmp=""
}

test_start "health_insurance_intel post-dispatch lock-collision retry (job_fail_health_insurance_intel)"

[ -f "$JOB_SCRIPT" ] || { echo "FATAL: job script missing: $JOB_SCRIPT"; exit 1; }
bash -n "$JOB_SCRIPT" || { echo "FATAL: job script has a bash syntax error"; exit 1; }

describe "Lock collision after pre-flight guard (original failure reproduction)"
  it "retries once after a TOCTOU collision and exits 0 when the retry succeeds" && {
    _test_hi_tmp=$(test_tmpdir)
    _setup_hi_fixture "$_test_hi_tmp" "collide_once"
    rc=0; _run_hi_job "$_test_hi_tmp" 5 "collide_once" || rc=$?
    assert_eq 0 $rc "job must exit 0 (original failure: this path exited 1)"
    _attempts=$(wc -l < "$_test_hi_tmp/lodge_ran" 2>/dev/null || echo 0)
    assert_eq 2 "$_attempts" "agentic run must have been attempted twice (original + retry)"
    assert_contains "$(cat "$_test_hi_tmp/job.log")" "refused on workspace lock collision" "driver must classify the collision"
    assert_contains "$(cat "$_test_hi_tmp/job.log")" "retrying monitored agentic run" "driver must log the retry"
    _hi_teardown
  }

describe "Persistent lock collision"
  it "defers gracefully (exit 0) when the lock outlives the retry budget" && {
    _test_hi_tmp=$(test_tmpdir)
    _setup_hi_fixture "$_test_hi_tmp" "always_collide"
    rc=0; _run_hi_job "$_test_hi_tmp" 999999 "always_collide" || rc=$?
    assert_eq 0 $rc "persistent collision must defer (exit 0), never hard-fail (original failure)"
    assert_contains "$(cat "$_test_hi_tmp/job.log")" "deferring this cycle" "deferral must be honestly logged"
    assert_not_contains "$(cat "$_test_hi_tmp/job.log")" "delivery not confirmed" "collision must not be mislabeled a delivery failure"
    _hi_teardown
  }

describe "Genuine failures still propagate"
  it "propagates the lodge exit code when the failure is NOT a lock collision" && {
    _test_hi_tmp=$(test_tmpdir)
    _setup_hi_fixture "$_test_hi_tmp" "genuine_fail"
    rc=0; _run_hi_job "$_test_hi_tmp" 5 "genuine_fail" || rc=$?
    assert_eq 42 $rc "genuine run failure must propagate (exit 42)"
    assert_contains "$(cat "$_test_hi_tmp/job.log")" "run failed (exit 42), delivery not confirmed"
    assert_not_contains "$(cat "$_test_hi_tmp/job.log")" "retrying monitored agentic run" "non-collision failures must not retry"
    _hi_teardown
  }

describe "Delivery semantics preserved"
  it "treats a non-zero exit after confirmed delivery as success" && {
    _test_hi_tmp=$(test_tmpdir)
    _setup_hi_fixture "$_test_hi_tmp" "delivered_nonzero"
    rc=0; _run_hi_job "$_test_hi_tmp" 5 "delivered_nonzero" || rc=$?
    assert_eq 0 $rc "confirmed delivery must survive a non-zero natural exit"
    assert_contains "$(cat "$_test_hi_tmp/job.log")" "treating as success"
    _hi_teardown
  }

  it "exits 0 on a clean run" && {
    _test_hi_tmp=$(test_tmpdir)
    _setup_hi_fixture "$_test_hi_tmp" "clean"
    rc=0; _run_hi_job "$_test_hi_tmp" 5 "clean" || rc=$?
    assert_eq 0 $rc
    assert_contains "$(cat "$_test_hi_tmp/job.log")" "DELIVERY CONFIRMED"
    _hi_teardown
  }

test_end
