#!/bin/bash
# ── Tests: commands/service.sh ─────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"

# Provide stubs for memory functions that service.sh might call
memory_get_section() { echo ""; }

source "$LODGE_DIR/commands/service.sh"

test_start "commands/service.sh — Microservice Manager"

# ── Setup: temporary service dir ───────────────────────────────
_ORIG_SERVICE_DIR="$SERVICE_DIR"
_ORIG_LOG_DIR="$SERVICE_LOG_DIR"
_ORIG_BIN_DIR="$SERVICE_BIN_DIR"
_TEST_TMPDIR=$(mktemp -d)
SERVICE_DIR="$_TEST_TMPDIR/services"
SERVICE_LOG_DIR="$_TEST_TMPDIR/services/logs"
SERVICE_BIN_DIR="$_TEST_TMPDIR/bin"
mkdir -p "$SERVICE_DIR" "$SERVICE_LOG_DIR" "$SERVICE_BIN_DIR"

# Create a fake Cargo project for registration tests
_FAKE_PROJECT="$_TEST_TMPDIR/fake-project"
mkdir -p "$_FAKE_PROJECT"
cat > "$_FAKE_PROJECT/Cargo.toml" << 'TOML'
[package]
name = "test-svc"
version = "0.1.0"
edition = "2021"

[[bin]]
name = "test-svc"
path = "src/main.rs"
TOML
mkdir -p "$_FAKE_PROJECT/src"
echo 'fn main() { println!("hello"); }' > "$_FAKE_PROJECT/src/main.rs"

# ── Help ───────────────────────────────────────────────────────
describe "cmd_service (help)"

  it "shows help on empty args" && {
    out=$(cmd_service "" "." 2>&1)
    assert_contains "$out" "Microservice Manager"
    assert_contains "$out" "/service deploy"
  }

  it "shows help on 'help' subcommand" && {
    out=$(cmd_service "help" "." 2>&1)
    assert_contains "$out" "Microservice Manager"
  }

# ── Register ───────────────────────────────────────────────────
describe "_service_register"

  it "fails with no name" && {
    out=$(_service_register "" 2>&1)
    assert_fail $?
    assert_contains "$out" "Usage"
  }

  it "fails on non-existent path" && {
    out=$(_service_register "bad-svc" "/no/such/path" 2>&1)
    assert_fail $?
  }

  it "fails when no Cargo.toml" && {
    _tmp_dir=$(mktemp -d)
    out=$(_service_register "no-cargo" "$_tmp_dir" 2>&1)
    assert_fail $?
    assert_contains "$out" "Cargo.toml"
    rm -rf "$_tmp_dir"
  }

  it "registers a valid Cargo project" && {
    out=$(_service_register "mysvc" "$_FAKE_PROJECT" 2>&1)
    assert_ok $?
    assert_contains "$out" "Registered"
    assert_file_exists "$SERVICE_DIR/mysvc.conf"
  }

  it "stores correct config values" && {
    _t_bin=$(_service_get "mysvc" "bin")
    _t_path=$(_service_get "mysvc" "path")
    assert_eq "$_t_bin" "test-svc"
    assert_eq "$_t_path" "$_FAKE_PROJECT"
  }

  it "detects [[bin]] name from Cargo.toml" && {
    _t_bin2=$(_service_get "mysvc" "bin")
    assert_eq "$_t_bin2" "test-svc"
  }

  it "allows re-registration (update)" && {
    out=$(_service_register "mysvc" "$_FAKE_PROJECT" 2>&1)
    assert_ok $?
    assert_contains "$out" "already registered"
  }

# ── Existence checks ──────────────────────────────────────────
describe "_service_exists"

  it "returns true for registered service" && {
    _service_exists "mysvc"
    assert_ok $?
  }

  it "returns false for unknown service" && {
    _service_exists "nope"
    assert_fail $?
  }

# ── List ───────────────────────────────────────────────────────
describe "_service_list"

  it "lists registered services" && {
    out=$(_service_list 2>&1)
    assert_contains "$out" "mysvc"
    assert_contains "$out" "test-svc"
  }

  it "shows empty message when no services" && {
    _bak_svcdir="$SERVICE_DIR"
    SERVICE_DIR="$_TEST_TMPDIR/empty-services"
    mkdir -p "$SERVICE_DIR"
    out=$(_service_list 2>&1)
    assert_contains "$out" "No services"
    SERVICE_DIR="$_bak_svcdir"
  }

# ── Start/Stop without real binary ─────────────────────────────
describe "_service_start (no binary)"

  it "fails when binary not installed" && {
    # Remove any installed path
    _service_set "mysvc" "installed" ""
    out=$(_service_start "mysvc" 2>&1)
    assert_fail $?
    assert_contains "$out" "Binary not found"
  }

# ── Start/Stop with a real process ─────────────────────────────
describe "_service_start/_service_stop (live process)"

  it "starts a process" && {
    # Create a fake binary that just sleeps
    cat > "$SERVICE_BIN_DIR/test-svc" << 'SCRIPT'
#!/bin/bash
while true; do sleep 60; done
SCRIPT
    chmod +x "$SERVICE_BIN_DIR/test-svc"
    _service_set "mysvc" "installed" "$SERVICE_BIN_DIR/test-svc"

    out=$(_service_start "mysvc" 2>&1)
    assert_ok $?
    assert_contains "$out" "started"
  }

  it "detects running service" && {
    _service_is_running "mysvc"
    assert_ok $?
  }

  it "warns if already running" && {
    out=$(_service_start "mysvc" 2>&1)
    assert_ok $?
    assert_contains "$out" "already running"
  }

  it "shows status for running service" && {
    out=$(_service_status "mysvc" 2>&1)
    assert_contains "$out" "RUNNING"
    assert_contains "$out" "test-svc"
  }

  it "stops the service" && {
    out=$(_service_stop "mysvc" 2>&1)
    assert_ok $?
    assert_contains "$out" "stopped"
  }

  it "detects stopped service" && {
    _service_is_running "mysvc"
    assert_fail $?
  }

# ── Logs ───────────────────────────────────────────────────────
describe "_service_logs"

  it "shows logs when they exist" && {
    echo "test log line" > "$SERVICE_LOG_DIR/mysvc.log"
    out=$(_service_logs "mysvc" 10 2>&1)
    assert_contains "$out" "test log line"
  }

  it "shows empty message when no logs" && {
    rm -f "$SERVICE_LOG_DIR/mysvc.log"
    out=$(_service_logs "mysvc" 10 2>&1)
    assert_contains "$out" "No logs"
  }

  it "fails for unknown service" && {
    out=$(_service_logs "nope" 2>&1)
    assert_fail $?
    assert_contains "$out" "Unknown"
  }

# ── Unregister ─────────────────────────────────────────────────
describe "_service_unregister"

  it "unregisters a service" && {
    out=$(_service_unregister "mysvc" 2>&1)
    assert_ok $?
    assert_contains "$out" "Unregistered"
    assert_file_not_exists "$SERVICE_DIR/mysvc.conf"
  }

  it "fails for unknown service" && {
    out=$(_service_unregister "nope" 2>&1)
    assert_fail $?
    assert_contains "$out" "Unknown"
  }

# ── Unknown subcommand ─────────────────────────────────────────
describe "cmd_service (bad subcommand)"

  it "rejects unknown subcommands" && {
    out=$(cmd_service "frobnicate" "." 2>&1)
    assert_fail $?
    assert_contains "$out" "Unknown subcommand"
  }

# ── Cleanup ────────────────────────────────────────────────────
# Kill any leftover test processes
for pf in "$SERVICE_DIR"/*.pid; do
    [ -f "$pf" ] || continue
    pid=$(cat "$pf" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
done
rm -rf "$_TEST_TMPDIR"
SERVICE_DIR="$_ORIG_SERVICE_DIR"
SERVICE_LOG_DIR="$_ORIG_LOG_DIR"
SERVICE_BIN_DIR="$_ORIG_BIN_DIR"

test_end
