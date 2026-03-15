#!/bin/bash
# ── Tests: lib/remote.sh ──────────────────────────────────────
# Tests the SSH tunnel management library.
# Mocks ssh/curl so no real server is needed.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/remote.sh"

test_start "lib/remote.sh — Remote Inference Tunnel"

# ── Helpers ────────────────────────────────────────────────────
_RT_TEST_DIR=""
_RT_MOCK_BIN=""

_rt_setup() {
    _RT_TEST_DIR=$(test_tmpdir)
    _RT_MOCK_BIN="$_RT_TEST_DIR/bin"
    mkdir -p "$_RT_MOCK_BIN"

    # Override George dir for config persistence
    GEORGE_DIR="$_RT_TEST_DIR/george"
    _REMOTE_PID_FILE="$GEORGE_DIR/remote-tunnel.pid"
    mkdir -p "$GEORGE_DIR"

    # Reset state
    REMOTE_SSH_TARGET=""
    REMOTE_SSH_PORT="22"
    REMOTE_SSH_KEY="$_RT_TEST_DIR/.ssh/id_ed25519"
    REMOTE_OLLAMA_PORT="11434"
    REMOTE_LLAMACPP_PORT="8080"
    REMOTE_LOCAL_OLLAMA_PORT="11434"
    REMOTE_LOCAL_LLAMACPP_PORT="8080"
    REMOTE_FORWARD_HOST="localhost"
    _REMOTE_CONNECTED=0
    _REMOTE_WATCHDOG_PID_FILE="$GEORGE_DIR/remote-watchdog.pid"
}

_rt_teardown() {
    rm -rf "$_RT_TEST_DIR" 2>/dev/null
}

# ── Config persistence ─────────────────────────────────────────
describe "_remote_save_config / _remote_load_config"

  it "saves config to remote.conf" && {
    _rt_setup
    REMOTE_SSH_TARGET="dabe@george-home"
    _remote_save_config
    assert_file_exists "$GEORGE_DIR/remote.conf"
    assert_contains "$(cat "$GEORGE_DIR/remote.conf")" "dabe@george-home"
    _rt_teardown
  }

  it "loads config from remote.conf" && {
    _rt_setup
    REMOTE_SSH_TARGET="test@host"
    _remote_save_config
    REMOTE_SSH_TARGET=""
    _remote_load_config
    assert_eq "$REMOTE_SSH_TARGET" "test@host"
    _rt_teardown
  }

  it "saves and loads REMOTE_FORWARD_HOST" && {
    _rt_setup
    REMOTE_FORWARD_HOST="192.168.30.10"
    _remote_save_config
    REMOTE_FORWARD_HOST="localhost"
    _remote_load_config
    assert_eq "$REMOTE_FORWARD_HOST" "192.168.30.10"
    _rt_teardown
  }

  it "rejects unknown config keys" && {
    _rt_setup
    echo "EVIL_VAR=hacked" >> "$GEORGE_DIR/remote.conf"
    _remote_load_config
    assert_eq "${EVIL_VAR:-}" ""
    _rt_teardown
  }

# ── Tunnel alive check ────────────────────────────────────────
describe "_remote_tunnel_alive"

  it "returns false when no PID file" && {
    _rt_setup
    _remote_tunnel_alive
    assert_fail $?
    _rt_teardown
  }

  it "returns false for stale PID" && {
    _rt_setup
    echo "999999" > "$_REMOTE_PID_FILE"
    _remote_tunnel_alive
    assert_fail $?
    _rt_teardown
  }

  it "returns true for running PID" && {
    _rt_setup
    echo "$$" > "$_REMOTE_PID_FILE"
    _remote_tunnel_alive
    assert_ok $?
    _rt_teardown
  }

# ── Connect ────────────────────────────────────────────────────
describe "remote_connect"

  it "fails with no target" && {
    _rt_setup
    REMOTE_SSH_TARGET=""
    remote_connect "" 2>/dev/null
    assert_fail $?
    _rt_teardown
  }

  it "fails when ssh is not available" && {
    _rt_setup
    # Provide a mock ssh that fails
    cat > "$_RT_MOCK_BIN/ssh" << 'MOCK'
#!/bin/bash
exit 255
MOCK
    chmod +x "$_RT_MOCK_BIN/ssh"
    _old_path="$PATH"
    PATH="$_RT_MOCK_BIN:$PATH"
    remote_connect "dabe@test-host" 2>/dev/null
    assert_fail $?
    PATH="$_old_path"
    _rt_teardown
  }

# ── Disconnect ─────────────────────────────────────────────────
describe "remote_disconnect"

  it "removes PID file" && {
    _rt_setup
    sleep 60 &
    _rt_dummy_pid=$!
    echo "$_rt_dummy_pid" > "$_REMOTE_PID_FILE"
    _REMOTE_CONNECTED=1
    remote_disconnect >/dev/null
    assert_file_not_exists "$_REMOTE_PID_FILE"
    _rt_teardown
  }

  it "kills watchdog PID on disconnect" && {
    _rt_setup
    sleep 60 &
    _rt_dummy_pid=$!
    echo "$_rt_dummy_pid" > "$_REMOTE_PID_FILE"
    sleep 60 &
    _rt_watchdog_pid=$!
    echo "$_rt_watchdog_pid" > "$_REMOTE_WATCHDOG_PID_FILE"
    _REMOTE_CONNECTED=1
    remote_disconnect >/dev/null
    assert_file_not_exists "$_REMOTE_WATCHDOG_PID_FILE"
    # watchdog process should be dead
    ! kill -0 "$_rt_watchdog_pid" 2>/dev/null
    assert_ok $?
    _rt_teardown
  }

  it "resets URLs to localhost defaults" && {
    _rt_setup
    OLLAMA_URL="http://10.0.0.1:11434"
    LLAMA_CPP_URL="http://10.0.0.1:8080"
    remote_disconnect >/dev/null
    assert_eq "$OLLAMA_URL" "http://127.0.0.1:11434"
    assert_eq "$LLAMA_CPP_URL" "http://127.0.0.1:8080"
    _rt_teardown
  }

  it "clears connected flag" && {
    _rt_setup
    _REMOTE_CONNECTED=1
    remote_disconnect >/dev/null
    assert_eq "$_REMOTE_CONNECTED" "0"
    _rt_teardown
  }

# ── Status ─────────────────────────────────────────────────────
describe "remote_tunnel_status"

  it "shows disconnected when no tunnel" && {
    _rt_setup
    _status_out=$(remote_tunnel_status)
    assert_contains "$_status_out" "disconnected"
    _rt_teardown
  }

  it "shows connected when PID is alive" && {
    _rt_setup
    sleep 60 &
    _rt_dummy_pid=$!
    echo "$_rt_dummy_pid" > "$_REMOTE_PID_FILE"
    # Mock curl for endpoint probes
    cat > "$_RT_MOCK_BIN/curl" << 'MOCK'
#!/bin/bash
echo '{"status":"ok","models":[]}'
exit 0
MOCK
    chmod +x "$_RT_MOCK_BIN/curl"
    _old_path="$PATH"
    PATH="$_RT_MOCK_BIN:$PATH"
    _status_out=$(remote_tunnel_status)
    assert_contains "$_status_out" "connected"
    PATH="$_old_path"
    kill "$_rt_dummy_pid" 2>/dev/null; wait "$_rt_dummy_pid" 2>/dev/null
    _rt_teardown
  }

# ── SSH base args ────────────────────────────────────────────────
describe "_remote_ssh_base_args"

  it "includes forward host in -L flags" && {
    _rt_setup
    REMOTE_FORWARD_HOST="192.168.30.10"
    _remote_ssh_base_args
    _rt_args="${_REMOTE_SSH_ARGS[*]}"
    assert_contains "$_rt_args" "192.168.30.10"
    _rt_teardown
  }

  it "defaults forward host to localhost" && {
    _rt_setup
    REMOTE_FORWARD_HOST="localhost"
    _remote_ssh_base_args
    _rt_args="${_REMOTE_SSH_ARGS[*]}"
    assert_contains "$_rt_args" "localhost"
    _rt_teardown
  }

# ── Setup SSH ──────────────────────────────────────────────────
describe "remote_setup_ssh"

  it "requires target argument" && {
    _rt_setup
    remote_setup_ssh "" >/dev/null
    assert_fail $?
    _rt_teardown
  }

# ── _remote_ensure_agent ───────────────────────────────────────
describe "_remote_ensure_agent"

  it "succeeds when key has no passphrase" && {
    _rt_setup
    mkdir -p "$(dirname "$REMOTE_SSH_KEY")"
    ssh-keygen -t ed25519 -f "$REMOTE_SSH_KEY" -N "" -q 2>/dev/null
    _remote_ensure_agent
    assert_ok $?
    _rt_teardown
  }

  it "function is defined" && {
    declare -f _remote_ensure_agent >/dev/null
    assert_ok $?
  }

# ── remote_secure_key ─────────────────────────────────────────
describe "remote_secure_key"

  it "function is defined" && {
    declare -f remote_secure_key >/dev/null
    assert_ok $?
  }

  it "fails when no key exists" && {
    _rt_setup
    REMOTE_SSH_KEY="$_RT_TEST_DIR/nonexistent_key"
    remote_secure_key >/dev/null 2>&1
    assert_fail $?
    _rt_teardown
  }

# ── Config file permissions ────────────────────────────────────
describe "config file permissions"

  it "remote.conf has 600 permissions" && {
    _rt_setup
    REMOTE_SSH_TARGET="test@host"
    _remote_save_config
    _perms=$(stat -c '%a' "$GEORGE_DIR/remote.conf" 2>/dev/null)
    assert_eq "$_perms" "600"
    _rt_teardown
  }

test_end
