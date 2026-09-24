#!/bin/bash
# ── Tests: lib/cron.sh & commands/cron.sh ──────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"

_test_tmpdir=""

_setup_cron() {
    _test_tmpdir=$(test_tmpdir)
    export GEORGE_DIR="$_test_tmpdir/.george"
    export GEORGE_CONFIG_DIR="$GEORGE_DIR"
    export CRON_PID_FILE="$GEORGE_DIR/.cron.pid"
    export CRON_LOG_FILE="$GEORGE_DIR/cron.log"
    export CRON_STATE_FILE="$GEORGE_DIR/cron_state.json"
    export CRON_CONF_FILE="$GEORGE_DIR/cron.conf"
    mkdir -p "$GEORGE_DIR"
    unset _LIB_CRON_LOADED
    source "$LODGE_DIR/lib/cron.sh"
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
    source "$LODGE_DIR/lib/commands.sh"
    source "$LODGE_DIR/commands/cron.sh"
    out=$(cmd_cron "status")
    assert_contains "$out" "George Autonomic Life & Cron Status"
    _teardown_cron
  }

  it "dispatches /cron trigger without args to display available job catalog" && {
    _setup_cron
    source "$LODGE_DIR/lib/commands.sh"
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
    source "$LODGE_DIR/lib/commands.sh"
    source "$LODGE_DIR/commands/cron.sh"
    out=$(cmd_cron "trigger issue_sweep")
    assert_contains "$out" "Executing Autonomic Sweep / Job: issue_sweep"
    _teardown_cron
  }

  it "enables, disables, and toggles cron jobs" && {
    _setup_cron
    source "$LODGE_DIR/lib/commands.sh"
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
