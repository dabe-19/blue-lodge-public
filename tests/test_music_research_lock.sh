#!/bin/bash
# ── Tests: .george/cron_jobs/music_research.sh — lock-aware Phase 2 hand-off ──
# Regression suite for fingerprint job_fail_music_research (Gitea issue #476).
#
# Root cause under test: the cron daemon launches custom jobs concurrently in
# the background, and the one-shot `lodge` task mode takes an exclusive
# workspace lock (${GEORGE_CONFIG_DIR:-$PWD/.george}/.lodge.lock, live-PID
# gate). When a concurrent job holds that lock, the job must NOT exit 1 —
# it must wait (bounded) and then either run full agentic curation or
# degrade to a deterministic compact digest and exit 0.
#
# The suite builds a disposable fixture workspace (stub `lodge`, stub Discord
# bridge, stub music pipeline) and drives the real job script against it.

source "$(dirname "$0")/framework.sh"

JOB_SCRIPT="$LODGE_DIR/.george/cron_jobs/music_research.sh"

_test_mr_holder_pid=""
_test_mr_tmp=""

_setup_mr_fixture() {
    # Args: $1 = fixture root, $2 = dossier body, $3 = with_discord_bridge (0/1)
    local root="$1" dossier_body="$2" with_bridge="$3"
    mkdir -p "$root/.george/tools" "$root/.george/configs"
    [ "$with_bridge" -eq 1 ] && mkdir -p "$root/lib/comms"

    # Stub `lodge`: marks execution and exits with a sentinel code (7).
    cat > "$root/lodge" <<EOF
#!/bin/bash
echo "LUDGE_STUB_RAN \$@" > "${root}/lodge_ran"
exit 7
EOF
    chmod +x "$root/lodge"

    # Stub music pipeline: writes the dossier to its first argument.
    cat > "$root/.george/tools/music_pipeline.sh" <<EOF
#!/bin/bash
cat > "\$1" <<'DOSSIER'
${dossier_body}
DOSSIER
exit 0
EOF
    chmod +x "$root/.george/tools/music_pipeline.sh"

    # Watchlist (required by the job).
    cat > "$root/.george/configs/music_watchlist.conf" <<'EOF'
genre: Electronic
artist: Test Artist
EOF

    if [ "$with_bridge" -eq 1 ]; then
        cat > "$root/lib/comms/discord_bridge.sh" <<'EOF'
#!/bin/bash
discord_channel_resolve() { echo ""; return 0; }
EOF
        cat > "$root/lib/comms/social.sh" <<EOF
#!/bin/bash
discord_send() {
    printf '%s
' "\$2" > "${root}/discord_msg.txt"
    return 0
}
EOF
    fi
    return 0
}

_run_mr_job() {
    # Args: $1 = fixture root, $2 = lock wait max, $3 = poll interval
    # Defence-in-depth: refuse to run unless the fixture `lodge` stub is in
    # place, so a broken fixture can never fall through to the real lodge.
    local root="$1" wait_max="$2" poll="$3"
    [ -x "${root}/lodge" ] || { echo "FATAL(fixture): no lodge stub in $root" > "${root}/job.log"; return 99; }
    env LODGE_DIR="$root" \
        GEORGE_DIR="$root/.george" \
        GEORGE_CONFIG_DIR="$root/.george" \
        MUSIC_WATCHLIST_FILE="$root/.george/configs/music_watchlist.conf" \
        MUSIC_LOCK_WAIT_MAX="$wait_max" \
        MUSIC_LOCK_POLL="$poll" \
        bash "$JOB_SCRIPT" > "${root}/job.log" 2>&1
    return $?
}

_mr_teardown() {
    [ -n "$_test_mr_holder_pid" ] && kill "$_test_mr_holder_pid" 2>/dev/null
    _test_mr_holder_pid=""
    [ -n "$_test_mr_tmp" ] && rm -rf "$_test_mr_tmp"
    _test_mr_tmp=""
}

_DROPS_DOSSIER='# 🎧 Blue Lodge · Music Intelligence Dossier
**Watchlist:** genres: Electronic · artists: Test Artist

## 🆕 New Drops — artist radar (cache-diffed, last 14d)
- **Test Single** — Test Artist · released 2026-10-09 · [https://music.apple.com/us/album/test-single/1]

## 📀 Genre Chart Drops — iTunes top albums (last 14d)
_No recent chart entries detected._

## 🗺 Tour Watch — setlist.fm (fetch each URL; extract upcoming date/venue/city)
- _No setlist.fm page found for '"'"'Test Artist'"'"'_

## 📰 Genre News — SearXNG, last week
- [PCB Connector Manufacturers in China 2026](https://example.com/pcb) — https://example.com/pcb _(via SearXNG news)_

## 🎤 Artist News — SearXNG, last month
- [Unrelated Politics Story](https://example.com/pol) — https://example.com/pol _(via SearXNG news)_'

test_start "music_research lock-aware hand-off (job_fail_music_research #476)"

[ -f "$JOB_SCRIPT" ] || { echo "FATAL: job script missing: $JOB_SCRIPT"; exit 1; }

describe "Lock contention (original failure reproduction)"
  it "degrades to deterministic digest and exits 0 when lock held by live PID" && {
    _test_mr_tmp=$(test_tmpdir)
    _setup_mr_fixture "$_test_mr_tmp" "$_DROPS_DOSSIER" 1
    sleep 300 & _test_mr_holder_pid=$!
    echo "$_test_mr_holder_pid" > "$_test_mr_tmp/.george/.lodge.lock"
    rc=0; _run_mr_job "$_test_mr_tmp" 3 1 || rc=$?
    assert_eq 0 $rc "job must exit 0, not 1 (original failure)"
    assert_contains "$(cat "$_test_mr_tmp/job.log")" "degrading to deterministic compact digest"
    assert_file_exists "$_test_mr_tmp/discord_msg.txt" "degraded digest must reach the Discord bridge"
    msg=$(cat "$_test_mr_tmp/discord_msg.txt")
    assert_contains "$msg" "Test Single" "digest keeps deterministic drop bullets"
    assert_contains "$msg" "auto-digest" "digest is honestly labeled"
    assert_not_contains "$msg" "PCB Connector" "raw uncurated news must be omitted"
    assert_not_contains "$msg" "Politics Story" "raw uncurated news must be omitted"
    assert_not_contains "$msg" "_No setlist" "placeholder lines must be filtered"
    assert_file_not_exists "$_test_mr_tmp/lodge_ran" "agentic phase must be skipped in degradation"
    _mr_teardown
  }

  it "sends quiet-cycle message when dossier has no actionable bullets" && {
    _test_mr_tmp=$(test_tmpdir)
    quiet_dossier=
    quiet_dossier=$(printf '%s
' \
        '# 🎧 Blue Lodge · Music Intelligence Dossier' \
        '## 🆕 New Drops — artist radar (cache-diffed, last 14d)' \
        '## 📀 Genre Chart Drops — iTunes top albums (last 14d)' \
        '_No recent chart entries detected._' \
        '## 🗺 Tour Watch — setlist.fm' \
        "- _No setlist.fm page found for 'Test Artist'_")
    _setup_mr_fixture "$_test_mr_tmp" "$quiet_dossier" 1
    sleep 300 & _test_mr_holder_pid=$!
    echo "$_test_mr_holder_pid" > "$_test_mr_tmp/.george/.lodge.lock"
    rc=0; _run_mr_job "$_test_mr_tmp" 3 1 || rc=$?
    assert_eq 0 $rc "quiet-cycle degradation must exit 0"
    msg=$(cat "$_test_mr_tmp/discord_msg.txt")
    assert_contains "$msg" "Quiet cycle"
    _mr_teardown
  }

describe "Lock wait and release"
  it "waits for lock release then runs full agentic curation" && {
    _test_mr_tmp=$(test_tmpdir)
    _setup_mr_fixture "$_test_mr_tmp" "$_DROPS_DOSSIER" 1
    sleep 2 & _test_mr_holder_pid=$!
    echo "$_test_mr_holder_pid" > "$_test_mr_tmp/.george/.lodge.lock"
    rc=0; _run_mr_job "$_test_mr_tmp" 15 1 || rc=$?
    assert_eq 7 $rc "job must exec the agentic lodge phase (stub sentinel 7)"
    assert_file_exists "$_test_mr_tmp/lodge_ran"
    assert_contains "$(cat "$_test_mr_tmp/job.log")" "waiting up to" "must log the bounded wait"
    assert_not_contains "$(cat "$_test_mr_tmp/job.log")" "degrading" "no degradation when lock frees in time"
    _mr_teardown
  }

  it "runs agentic curation immediately when no lock file exists" && {
    _test_mr_tmp=$(test_tmpdir)
    _setup_mr_fixture "$_test_mr_tmp" "$_DROPS_DOSSIER" 1
    rc=0; _run_mr_job "$_test_mr_tmp" 3 1 || rc=$?
    assert_eq 7 $rc
    assert_file_exists "$_test_mr_tmp/lodge_ran"
    assert_not_contains "$(cat "$_test_mr_tmp/job.log")" "waiting up to"
    _mr_teardown
  }

  it "reclaims a stale lock (dead holder PID) immediately" && {
    _test_mr_tmp=$(test_tmpdir)
    _setup_mr_fixture "$_test_mr_tmp" "$_DROPS_DOSSIER" 1
    # Spawn a short-lived process and use its (now dead) PID as the holder.
    dead_pid=
    sleep 0.05 & dead_pid=$!
    wait "$dead_pid" 2>/dev/null
    kill -0 "$dead_pid" 2>/dev/null && { echo "FATAL: PID not dead"; return 1; }
    echo "$dead_pid" > "$_test_mr_tmp/.george/.lodge.lock"
    rc=0; _run_mr_job "$_test_mr_tmp" 3 1 || rc=$?
    assert_eq 7 $rc "stale lock must not block the agentic phase"
    assert_file_exists "$_test_mr_tmp/lodge_ran"
    assert_not_contains "$(cat "$_test_mr_tmp/job.log")" "waiting up to"
    _mr_teardown
  }

describe "Bridge fallback"
  it "preserves dossier and exits 0 when Discord bridge is unavailable" && {
    _test_mr_tmp=$(test_tmpdir)
    _setup_mr_fixture "$_test_mr_tmp" "$_DROPS_DOSSIER" 0   # no bridge stubs
    sleep 300 & _test_mr_holder_pid=$!
    echo "$_test_mr_holder_pid" > "$_test_mr_tmp/.george/.lodge.lock"
    rc=0; _run_mr_job "$_test_mr_tmp" 3 1 || rc=$?
    assert_eq 0 $rc "missing bridge must not fail the job"
    assert_contains "$(cat "$_test_mr_tmp/job.log")" "WARN: Discord bridge unavailable"
    assert_file_not_exists "$_test_mr_tmp/lodge_ran"
    _mr_teardown
  }

test_end
