#!/bin/bash
# ── Tests: .george/cron_jobs/music_research.sh — supervised wall-cap hand-off ──
# Regression suite for fingerprint job_fail_music_research (Gitea issue #510).
#
# Failure under test: a fully SUCCESSFUL agentic run (digest delivered to
# Discord, every milestone marked complete) failed to converge — the
# milestone evaluator was unavailable (single-slot LLM timeouts), so the ReAct
# loop kept re-verifying completion turn after turn with no wall-clock
# pressure, until an external SIGKILL (exit 137) arrived at 3284s. The cron
# daemon then recorded a fully delivered run as a false job failure.
#
# Contract under test (pure POSIX, job-script side only, no core files):
#   1. The agentic hand-off exports REACT_WALL_BUDGET_S so the runner's
#      wall-budget stage (converge at 70%, final turn forced at 85%) gives a
#      stuck loop pressure to terminate on its own.
#   2. A job-side hard cap (MUSIC_AGENT_HARD_MAX) SIGTERMs (grace period),
#      then SIGKILLs a pathologically stuck run, delivers the deterministic
#      compact digest instead, and exits 0 — the daily intelligence SLA and
#      the false-failure alarm both survive.
#   3. Fast agent exits are propagated unchanged (pre-#510 contract).
#
# The suite builds a disposable fixture workspace (stub `lodge`, stub Discord
# bridge, stub music pipeline) and drives the real job script against it.

source "$(dirname "$0")/framework.sh"

JOB_SCRIPT="$LODGE_DIR/.george/cron_jobs/music_research.sh"

_test_wc_tmp=""

_WC_DOSSIER='# 🎧 Blue Lodge · Music Intelligence Dossier
**Watchlist:** genres: Electronic · artists: Test Artist

## 🆕 New Drops — artist radar (cache-diffed, last 14d)
- **Test Single** — Test Artist · released 2026-10-09 · [https://music.apple.com/us/album/test-single/1]

## 📀 Genre Chart Drops — iTunes top albums (last 14d)
_No recent chart entries detected._

## 🗺 Tour Watch — setlist.fm (fetch each URL; extract upcoming date/venue/city)
- _No setlist.fm page found for Test Artist_

## 📰 Genre News — SearXNG, last week
- [PCB Connector Manufacturers in China 2026](https://example.com/pcb) — https://example.com/pcb _(via SearXNG news)_'

_setup_wc_fixture() {
    # Args: $1 = fixture root, $2 = lodge stub body, $3 = with_discord_bridge (0/1)
    local root="$1" stub_body="$2" with_bridge="$3"
    mkdir -p "$root/.george/tools" "$root/.george/configs"
    [ "$with_bridge" -eq 1 ] && mkdir -p "$root/lib/comms"

    cat > "$root/lodge" <<EOF
#!/bin/bash
${stub_body}
EOF
    chmod +x "$root/lodge"

    cat > "$root/.george/tools/music_pipeline.sh" <<EOF
#!/bin/bash
cat > "\$1" <<'DOSSIER'
${_WC_DOSSIER}
DOSSIER
exit 0
EOF
    chmod +x "$root/.george/tools/music_pipeline.sh"

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

_run_wc_job() {
    # Args: $1 = fixture root, $2 = hard cap s, $3 = poll s, $4 = kill grace s
    local root="$1" cap="$2" poll="$3" grace="$4"
    [ -x "${root}/lodge" ] || { echo "FATAL(fixture): no lodge stub in $root" > "${root}/job.log"; return 99; }
    env LODGE_DIR="$root" \
        GEORGE_DIR="$root/.george" \
        GEORGE_CONFIG_DIR="$root/.george" \
        MUSIC_WATCHLIST_FILE="$root/.george/configs/music_watchlist.conf" \
        MUSIC_LOCK_WAIT_MAX=3 \
        MUSIC_LOCK_POLL=1 \
        MUSIC_AGENT_HARD_MAX="$cap" \
        MUSIC_AGENT_POLL="$poll" \
        MUSIC_AGENT_KILL_GRACE="$grace" \
        bash "$JOB_SCRIPT" > "${root}/job.log" 2>&1
    return $?
}

_wc_teardown() {
    [ -n "$_test_wc_tmp" ] && rm -rf "$_test_wc_tmp"
    _test_wc_tmp=""
}

test_start "music_research supervised wall-cap hand-off (job_fail_music_research #510)"

[ -f "$JOB_SCRIPT" ] || { echo "FATAL: job script missing: $JOB_SCRIPT"; exit 1; }

describe "#510 reproduction: non-converging agentic run"
  it "caps the stuck run, delivers the compact digest, and exits 0" && {
    _test_wc_tmp=$(test_tmpdir)
    _setup_wc_fixture "$_test_wc_tmp" "sleep 120" 1
    rc=0; _run_wc_job "$_test_wc_tmp" 6 1 1 || rc=$?
    assert_eq 0 $rc "hard-capped run must exit 0, not 137/143 (original failure)"
    assert_contains "$(cat "$_test_wc_tmp/job.log")" "exceeded hard cap" "hard-cap kill must be logged"
    assert_contains "$(cat "$_test_wc_tmp/job.log")" "Hard-cap kill" "degradation path must be logged"
    assert_file_exists "$_test_wc_tmp/discord_msg.txt" "compact digest must still reach the Discord bridge"
    msg=$(cat "$_test_wc_tmp/discord_msg.txt")
    assert_contains "$msg" "auto-digest" "digest is honestly labeled as auto-digest"
    assert_contains "$msg" "wall-clock hard cap" "digest names the actual degradation reason"
    assert_contains "$msg" "Test Single" "digest keeps deterministic drop bullets"
    assert_not_contains "$msg" "PCB Connector" "raw uncurated news must be omitted"
    _wc_teardown
  }

  it "exits 0 with a WARN when the bridge is unavailable at cap-kill" && {
    _test_wc_tmp=$(test_tmpdir)
    _setup_wc_fixture "$_test_wc_tmp" "sleep 120" 0
    rc=0; _run_wc_job "$_test_wc_tmp" 6 1 1 || rc=$?
    assert_eq 0 $rc "cap-kill with dead bridge must not fail the job (lock-path policy)"
    assert_contains "$(cat "$_test_wc_tmp/job.log")" "WARN: Discord bridge unavailable"
    _wc_teardown
  }

describe "Wall-budget export into the agentic slot"
  it "exports REACT_WALL_BUDGET_S and AGENT_MAX_TURNS to the lodge child" && {
    _test_wc_tmp=$(test_tmpdir)
    _setup_wc_fixture "$_test_wc_tmp" "echo \"BUDGET=\${REACT_WALL_BUDGET_S:-unset} TURNS=\${AGENT_MAX_TURNS:-unset}\" > \"${_test_wc_tmp}/envdump\"; exit 7" 1
    rc=0; _run_wc_job "$_test_wc_tmp" 300 1 1 || rc=$?
    assert_eq 7 $rc "fast agent exit must propagate unchanged (pre-#510 contract)"
    assert_file_exists "$_test_wc_tmp/envdump" "stub must have captured its environment"
    envline=$(cat "$_test_wc_tmp/envdump")
    assert_contains "$envline" "BUDGET=2400" "default wall budget 2400s must be exported"
    assert_contains "$envline" "TURNS=40" "default turn ceiling 40 must be exported"
    assert_not_contains "$(cat "$_test_wc_tmp/job.log")" "degrading" "no degradation on a fast exit"
    _wc_teardown
  }

describe "Fast-exit contract regression"
  it "propagates a quick non-zero agent exit without degrading" && {
    _test_wc_tmp=$(test_tmpdir)
    _setup_wc_fixture "$_test_wc_tmp" "exit 7" 1
    rc=0; _run_wc_job "$_test_wc_tmp" 300 1 1 || rc=$?
    assert_eq 7 $rc "agent exit code must propagate (fixture sentinel 7)"
    assert_file_not_exists "$_test_wc_tmp/discord_msg.txt" "no digest posted when the agentic phase was not stuck"
    assert_not_contains "$(cat "$_test_wc_tmp/job.log")" "degrading"
    _wc_teardown
  }

test_end
