#!/bin/bash
# ── Tests: lib/sys/cron.sh & commands/cron.sh ──────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh"

_test_tmpdir=""

_setup_cron() {
    _test_tmpdir=$(test_tmpdir)
    export GEORGE_DIR="$_test_tmpdir/.george"
    export GEORGE_CONFIG_DIR="$GEORGE_DIR"
    export GEORGE_SANDBOXES_DIR="$_test_tmpdir/.sandboxes"
    export CRON_PID_FILE="$GEORGE_DIR/.cron.pid"
    export CRON_LOG_FILE="$GEORGE_DIR/cron.log"
    export CRON_STATE_FILE="$GEORGE_DIR/cron_state.json"
    export CRON_CONF_FILE="$GEORGE_DIR/cron.conf"
    mkdir -p "$GEORGE_DIR" "$GEORGE_SANDBOXES_DIR"
    unset _LIB_CRON_LOADED
    source "$LODGE_DIR/lib/sys/cron.sh"
}

_teardown_cron() {
    cron_stop 2>/dev/null || true
    rm -rf "$_test_tmpdir"
}

describe "George Autonomic Cron Engine"
  it "initializes cron state file and default intervals" && {
    _setup_cron
    cron_init
    assert_file_exists "$CRON_STATE_FILE"
    assert_eq "60" "$CRON_INTERVAL_PR"
    assert_eq "60" "$CRON_INTERVAL_ISSUE"
    assert_eq "30" "$CRON_INTERVAL_DISCORD"
    _teardown_cron
  }

  it "loads custom intervals from cron.conf" && {
    _setup_cron
    cat > "$CRON_CONF_FILE" << 'EOF'
CRON_INTERVAL_PR=15
CRON_INTERVAL_DISCORD=10
EOF
    cron_init
    assert_eq "15" "$CRON_INTERVAL_PR"
    assert_eq "10" "$CRON_INTERVAL_DISCORD"
    _teardown_cron
  }

  it "executes cron_run_once and updates state file with timestamps" && {
    _setup_cron
    cron_run_once issue_sweep >/dev/null 2>&1
    assert_file_exists "$CRON_STATE_FILE"
    last_run=$(jq -r '.jobs.issue_sweep.last_run // 0' "$CRON_STATE_FILE")
    [ "$last_run" -gt 0 ]
    assert_ok $?
    _teardown_cron
  }

  it "displays stopped and running status cleanly" && {
    _setup_cron
    out=$(cron_status)
    assert_contains "$out" "STOPPED"
    assert_contains "$out" "pr_sweep"
    assert_contains "$out" "discord_sweep"
    _teardown_cron
  }

describe "Slash command /cron"
  it "dispatches /cron status via slash commands" && {
    _setup_cron
    source "$LODGE_DIR/lib/ui/commands.sh"
    source "$LODGE_DIR/commands/cron.sh"
    out=$(cmd_cron "status")
    assert_contains "$out" "George Autonomic Life & Cron Status"
    _teardown_cron
  }

  it "dispatches /cron trigger without args to display available job catalog" && {
    _setup_cron
    source "$LODGE_DIR/lib/ui/commands.sh"
    source "$LODGE_DIR/commands/cron.sh"
    out=$(cmd_cron "trigger")
    assert_contains "$out" "George Autonomic Job Trigger"
    assert_contains "$out" "pr_sweep"
    assert_contains "$out" "issue_sweep"
    assert_contains "$out" "/cron trigger <job_name>"
    _teardown_cron
  }

  it "dispatches /cron trigger <job> to execute specific sweep" && {
    _setup_cron
    source "$LODGE_DIR/lib/ui/commands.sh"
    source "$LODGE_DIR/commands/cron.sh"
    out=$(cmd_cron "trigger issue_sweep")
    assert_contains "$out" "Executing Autonomic Sweep / Job: issue_sweep"
    _teardown_cron
  }

  it "enables, disables, and toggles cron jobs" && {
    _setup_cron
    source "$LODGE_DIR/lib/ui/commands.sh"
    source "$LODGE_DIR/commands/cron.sh"

    # Default: enabled
    cron_is_job_enabled "pr_sweep"
    assert_ok $?

    # Disable pr_sweep
    cmd_cron "disable pr_sweep" >/dev/null 2>&1
    ! cron_is_job_enabled "pr_sweep"
    assert_ok $?

    # Status displays DISABLED
    out=$(cmd_cron "status")
    assert_contains "$out" "[DISABLED]"

    # Toggle pr_sweep back to enabled
    cmd_cron "toggle pr_sweep" >/dev/null 2>&1
    cron_is_job_enabled "pr_sweep"
    assert_ok $?

    # Enable explicitly
    cmd_cron "enable pr_sweep" >/dev/null 2>&1
    cron_is_job_enabled "pr_sweep"
    assert_ok $?

    _teardown_cron
  }

describe "Cron quiesce (game mode / live golden eval)"
  it "defers sweeps only while a live eval harness or game mode holds the GPU" && {
    _setup_cron
    cron_quiesced; assert_fail $? "no lock -> not quiesced"
    mkdir -p "$GEORGE_DIR/eval"
    echo "$$" > "$GEORGE_DIR/eval/.harness.pid"
    cron_quiesced; assert_ok $? "live harness pid -> quiesced"
    echo "999999999" > "$GEORGE_DIR/eval/.harness.pid"
    cron_quiesced; assert_fail $? "stale harness pid ignored"
    echo "abc" > "$GEORGE_DIR/eval/.harness.pid"
    cron_quiesced; assert_fail $? "garbage pidfile ignored"
    rm -f "$GEORGE_DIR/eval/.harness.pid"
    touch "$GEORGE_DIR/.game_mode"
    cron_game_mode_active; assert_ok $? "game mode -> game_mode_active"
    _teardown_cron
  }

describe "cron_sweep_stale_daemons (2026-10-04 exit-137 regression)"
  it "spares forked descendants of the live daemon and reaps only competing leaders" && {
    _setup_cron
    M="_cron_loop_runner_testmarker_$$"
    # Double-fork so neither process is our descendant (the sweep always spares
    # its own ancestry); in production the daemon is detached the same way.
    # Authoritative daemon with a nested forked subshell (inherits argv, like a job).
    ( bash -c "( ( sleep 30; : ); : ) & wait" "$M" & )
    # Competing stale daemon leader.
    ( bash -c "sleep 31; :" "$M" & )
    sleep 0.5
    auth=$(command pgrep -f "wait $M" | head -1)
    rival=$(command pgrep -f "sleep 31; : $M" | head -1)
    # Mock pgrep so the test only ever sees its own processes, never a real daemon.
    pgrep() { command pgrep -f "$M"; }
    desc=$(command pgrep -f "$M" | grep -vx "$auth" | grep -vx "$rival" | head -1)
    [ -n "$auth" ] && [ -n "$rival" ]; assert_ok $? "fixture processes started"
    cron_sweep_stale_daemons "$auth"
    sleep 0.3
    unset -f pgrep
    _cron_pid_is_alive "$auth"; assert_ok $? "authoritative daemon alive"
    [ -n "$desc" ] && _cron_pid_is_alive "$desc"; assert_ok $? "forked job subshell of daemon alive"
    _cron_pid_is_alive "$rival"; assert_fail $? "competing leader reaped"
    for p in $(command pgrep -f "$M"); do
      for cp in $(ps --ppid "$p" -o pid= 2>/dev/null); do kill -9 "$cp" 2>/dev/null; done
      kill -9 "$p" 2>/dev/null
    done
    _teardown_cron
  }

  it "spares re-parented background tasks carrying _CRON_DAEMON_LEADER_PID or protected .pid files" && {
    _setup_cron
    M="_cron_loop_runner_reparent_$$"
    ( bash -c "sleep 30; :" "$M" >/dev/null 2>&1 </dev/null & )
    sleep 0.2
    auth=$(command pgrep -f "sleep 30; : $M" | head -1)
    echo "$auth" > "$CRON_PID_FILE"
    cron_is_running; assert_ok $? "cron_is_running detects live daemon"

    # Spawn a child whose intermediate parent exits immediately (re-parented to init/systemd)
    ( export _CRON_DAEMON_LEADER_PID="$auth"; ( bash -c "sleep 31; :" "$M" >/dev/null 2>&1 </dev/null & ) )
    sleep 0.3
    reparented=$(command pgrep -f "sleep 31; : $M" | head -1)
    [ -n "$auth" ] && [ -n "$reparented" ]; assert_ok $? "reparented fixture started"

    pgrep() { command pgrep -f "$M"; }
    cron_sweep_stale_daemons "$auth"
    sleep 0.2
    unset -f pgrep

    _cron_pid_is_alive "$reparented"; assert_ok $? "re-parented child with _CRON_DAEMON_LEADER_PID spared"
    for p in $(command pgrep -f "$M"); do
      for cp in $(ps --ppid "$p" -o pid= 2>/dev/null); do kill -9 "$cp" 2>/dev/null; done
      kill -9 "$p" 2>/dev/null
    done
    rm -f "$CRON_PID_FILE"
    _teardown_cron
  }

test_end
