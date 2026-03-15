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
    REMOTE_JUMP_HOST=""
    REMOTE_LLAMACPP_BIN=""
    REMOTE_GPU_BACKEND="auto"
    REMOTE_KV_CACHE_TYPE="auto"
    REMOTE_FLASH_ATTN="auto"
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

# ── REMOTE_JUMP_HOST config persistence ────────────────────────
describe "REMOTE_JUMP_HOST config"

  it "saves and loads REMOTE_JUMP_HOST" && {
    _rt_setup
    REMOTE_JUMP_HOST="dabe@192.168.86.18"
    _remote_save_config
    REMOTE_JUMP_HOST=""
    _remote_load_config
    assert_eq "$REMOTE_JUMP_HOST" "dabe@192.168.86.18"
    _rt_teardown
  }

  it "defaults to empty when not set" && {
    _rt_setup
    _remote_save_config
    _remote_load_config
    assert_empty "$REMOTE_JUMP_HOST"
    _rt_teardown
  }

  it "conf file contains REMOTE_JUMP_HOST line" && {
    _rt_setup
    REMOTE_JUMP_HOST="user@jump"
    _remote_save_config
    assert_contains "$(cat "$GEORGE_DIR/remote.conf")" "REMOTE_JUMP_HOST=user@jump"
    _rt_teardown
  }

# ── GPU / flash-attn / KV cache config persistence ────────────
describe "GPU config persistence"

  it "saves and loads REMOTE_GPU_BACKEND" && {
    _rt_setup
    REMOTE_GPU_BACKEND="vulkan"
    _remote_save_config
    REMOTE_GPU_BACKEND="auto"
    _remote_load_config
    assert_eq "$REMOTE_GPU_BACKEND" "vulkan"
    _rt_teardown
  }

  it "saves and loads REMOTE_KV_CACHE_TYPE" && {
    _rt_setup
    REMOTE_KV_CACHE_TYPE="q8_0"
    _remote_save_config
    REMOTE_KV_CACHE_TYPE="auto"
    _remote_load_config
    assert_eq "$REMOTE_KV_CACHE_TYPE" "q8_0"
    _rt_teardown
  }

  it "saves and loads REMOTE_FLASH_ATTN" && {
    _rt_setup
    REMOTE_FLASH_ATTN="on"
    _remote_save_config
    REMOTE_FLASH_ATTN="auto"
    _remote_load_config
    assert_eq "$REMOTE_FLASH_ATTN" "on"
    _rt_teardown
  }

  it "saves and loads REMOTE_LLAMACPP_BIN" && {
    _rt_setup
    REMOTE_LLAMACPP_BIN="/home/dabe/llama.cpp/build/bin/llama-server"
    _remote_save_config
    REMOTE_LLAMACPP_BIN=""
    _remote_load_config
    assert_eq "$REMOTE_LLAMACPP_BIN" "/home/dabe/llama.cpp/build/bin/llama-server"
    _rt_teardown
  }

# ── SSH base args with jump host ───────────────────────────────
describe "_remote_ssh_base_args with REMOTE_JUMP_HOST"

  # Dual-path architecture: tunnel connects DIRECTLY to jump host (no -J).
  # -L forwards use REMOTE_FORWARD_HOST as the destination.
  # ProxyJump (-J) is only used by _remote_exec for exec path.

  it "omits -J in tunnel args (tunnel connects to jump host directly)" && {
    _rt_setup
    REMOTE_JUMP_HOST="dabe@192.168.86.18"
    REMOTE_FORWARD_HOST="192.168.30.10"
    _remote_ssh_base_args
    _rt_args="${_REMOTE_SSH_ARGS[*]}"
    assert_not_contains "$_rt_args" "-J"
    _rt_teardown
  }

  it "uses REMOTE_FORWARD_HOST in -L flags when jump host is set" && {
    _rt_setup
    REMOTE_JUMP_HOST="dabe@192.168.86.18"
    REMOTE_FORWARD_HOST="192.168.30.10"
    _remote_ssh_base_args
    _rt_args="${_REMOTE_SSH_ARGS[*]}"
    assert_contains "$_rt_args" "192.168.30.10"
    _rt_teardown
  }

  it "omits -J flag when REMOTE_JUMP_HOST is empty" && {
    _rt_setup
    REMOTE_JUMP_HOST=""
    _remote_ssh_base_args
    _rt_args="${_REMOTE_SSH_ARGS[*]}"
    assert_not_contains "$_rt_args" "-J"
    _rt_teardown
  }

  it "includes forward host in -L flags with jump host topology" && {
    _rt_setup
    REMOTE_JUMP_HOST="user@jump-box"
    REMOTE_FORWARD_HOST="10.0.0.50"
    _remote_ssh_base_args
    _rt_args="${_REMOTE_SSH_ARGS[*]}"
    assert_contains "$_rt_args" "10.0.0.50"
    assert_not_contains "$_rt_args" "user@jump-box"
    _rt_teardown
  }

  it "tunnel target returns jump host when REMOTE_JUMP_HOST is set" && {
    _rt_setup
    REMOTE_JUMP_HOST="user@jump-box"
    REMOTE_SSH_TARGET="user@gpu-server"
    local _tt
    _tt=$(_remote_tunnel_target)
    assert_eq "$_tt" "user@jump-box"
    _rt_teardown
  }

# ── _remote_exec with mock SSH ─────────────────────────────────
describe "_remote_exec"

  it "fails when REMOTE_SSH_TARGET is empty" && {
    _rt_setup
    REMOTE_SSH_TARGET=""
    _remote_exec "echo hello" 2>/dev/null
    assert_fail $?
    _rt_teardown
  }

  it "passes -J to ssh when REMOTE_JUMP_HOST is set" && {
    _rt_setup
    # Mock ssh that records its args to a file
    cat > "$_RT_MOCK_BIN/ssh" << 'MOCK'
#!/bin/bash
echo "$@" > /tmp/_rt_ssh_args_capture
exit 0
MOCK
    chmod +x "$_RT_MOCK_BIN/ssh"
    _old_path="$PATH"
    PATH="$_RT_MOCK_BIN:$PATH"
    REMOTE_SSH_TARGET="dabe@george-home"
    REMOTE_JUMP_HOST="dabe@192.168.86.18"
    _remote_exec "echo hello" 2>/dev/null
    _captured=$(cat /tmp/_rt_ssh_args_capture 2>/dev/null)
    assert_contains "$_captured" "-J"
    assert_contains "$_captured" "dabe@192.168.86.18"
    assert_contains "$_captured" "dabe@george-home"
    PATH="$_old_path"
    rm -f /tmp/_rt_ssh_args_capture
    _rt_teardown
  }

  it "omits -J when REMOTE_JUMP_HOST is empty" && {
    _rt_setup
    cat > "$_RT_MOCK_BIN/ssh" << 'MOCK'
#!/bin/bash
echo "$@" > /tmp/_rt_ssh_args_capture
exit 0
MOCK
    chmod +x "$_RT_MOCK_BIN/ssh"
    _old_path="$PATH"
    PATH="$_RT_MOCK_BIN:$PATH"
    REMOTE_SSH_TARGET="dabe@direct-host"
    REMOTE_JUMP_HOST=""
    _remote_exec "echo hello" 2>/dev/null
    _captured=$(cat /tmp/_rt_ssh_args_capture 2>/dev/null)
    assert_not_contains "$_captured" "-J"
    assert_contains "$_captured" "dabe@direct-host"
    PATH="$_old_path"
    rm -f /tmp/_rt_ssh_args_capture
    _rt_teardown
  }

# ── _remote_detect_llamacpp_bin with mock SSH ──────────────────
describe "_remote_detect_llamacpp_bin"

  it "skips detection when REMOTE_LLAMACPP_BIN already set" && {
    _rt_setup
    REMOTE_LLAMACPP_BIN="/already/set/llama-server"
    _remote_detect_llamacpp_bin
    assert_ok $?
    assert_eq "$REMOTE_LLAMACPP_BIN" "/already/set/llama-server"
    _rt_teardown
  }

  it "detects binary via /proc/PID/exe (strategy 1)" && {
    _rt_setup
    # Mock ssh that simulates /proc/PID/exe readlink
    cat > "$_RT_MOCK_BIN/ssh" << 'MOCK'
#!/bin/bash
# Return the fake binary path for strategy 1
echo "/home/dabe/llama.cpp/build/bin/llama-server"
exit 0
MOCK
    chmod +x "$_RT_MOCK_BIN/ssh"
    _old_path="$PATH"
    PATH="$_RT_MOCK_BIN:$PATH"
    REMOTE_SSH_TARGET="dabe@george-home"
    REMOTE_LLAMACPP_BIN=""
    _remote_detect_llamacpp_bin
    assert_ok $?
    assert_eq "$REMOTE_LLAMACPP_BIN" "/home/dabe/llama.cpp/build/bin/llama-server"
    PATH="$_old_path"
    _rt_teardown
  }

  it "persists detected binary to remote.conf" && {
    _rt_setup
    cat > "$_RT_MOCK_BIN/ssh" << 'MOCK'
#!/bin/bash
echo "/opt/llama.cpp/build/bin/llama-server"
exit 0
MOCK
    chmod +x "$_RT_MOCK_BIN/ssh"
    _old_path="$PATH"
    PATH="$_RT_MOCK_BIN:$PATH"
    REMOTE_SSH_TARGET="dabe@george-home"
    REMOTE_LLAMACPP_BIN=""
    _remote_detect_llamacpp_bin
    # Verify it was persisted
    _saved=$(grep "REMOTE_LLAMACPP_BIN" "$GEORGE_DIR/remote.conf" 2>/dev/null)
    assert_contains "$_saved" "/opt/llama.cpp/build/bin/llama-server"
    PATH="$_old_path"
    _rt_teardown
  }

  it "fails when all strategies return empty" && {
    _rt_setup
    # Mock ssh that returns nothing
    cat > "$_RT_MOCK_BIN/ssh" << 'MOCK'
#!/bin/bash
exit 0
MOCK
    chmod +x "$_RT_MOCK_BIN/ssh"
    _old_path="$PATH"
    PATH="$_RT_MOCK_BIN:$PATH"
    REMOTE_SSH_TARGET="dabe@george-home"
    REMOTE_LLAMACPP_BIN=""
    _remote_detect_llamacpp_bin
    assert_fail $?
    assert_empty "$REMOTE_LLAMACPP_BIN"
    PATH="$_old_path"
    _rt_teardown
  }

  it "rejects non-absolute paths from strategy 2" && {
    _rt_setup
    # Mock ssh: strategy 1 returns empty, strategy 2 returns relative path
    _rt_call_count=0
    cat > "$_RT_MOCK_BIN/ssh" << 'MOCK'
#!/bin/bash
cmd="$*"
# Strategy 1 (pgrep/readlink): return empty
if echo "$cmd" | grep -q "pgrep"; then
    exit 0
fi
# Strategy 2 (ps/awk): return relative path (should be rejected)
if echo "$cmd" | grep -q "awk"; then
    echo "llama-server"
    exit 0
fi
# All others: empty
exit 0
MOCK
    chmod +x "$_RT_MOCK_BIN/ssh"
    _old_path="$PATH"
    PATH="$_RT_MOCK_BIN:$PATH"
    REMOTE_SSH_TARGET="dabe@george-home"
    REMOTE_LLAMACPP_BIN=""
    _remote_detect_llamacpp_bin
    # It should have fallen through to later strategies (which also return empty)
    # or found something — but the relative path should NOT be accepted
    # If _bin was set, it should start with /
    if [ -n "$REMOTE_LLAMACPP_BIN" ]; then
        assert_match "$REMOTE_LLAMACPP_BIN" "^/"
    fi
    PATH="$_old_path"
    _rt_teardown
  }

# ── _remote_detect_gpu with mock SSH ──────────────────────────
describe "_remote_detect_gpu"

  it "skips detection when all values already resolved" && {
    _rt_setup
    REMOTE_GPU_BACKEND="vulkan"
    REMOTE_KV_CACHE_TYPE="f16"
    REMOTE_FLASH_ATTN="off"
    REMOTE_SSH_TARGET="dabe@host"
    # No SSH mock needed — should return immediately
    _remote_detect_gpu
    assert_ok $?
    assert_eq "$REMOTE_GPU_BACKEND" "vulkan"
    _rt_teardown
  }

  it "detects CUDA and sets flash-attn on + q8_0 KV" && {
    _rt_setup
    cat > "$_RT_MOCK_BIN/ssh" << 'MOCK'
#!/bin/bash
echo "cuda"
MOCK
    chmod +x "$_RT_MOCK_BIN/ssh"
    _old_path="$PATH"
    PATH="$_RT_MOCK_BIN:$PATH"
    REMOTE_SSH_TARGET="dabe@host"
    REMOTE_GPU_BACKEND="auto"
    REMOTE_KV_CACHE_TYPE="auto"
    REMOTE_FLASH_ATTN="auto"
    _remote_detect_gpu
    assert_eq "$REMOTE_GPU_BACKEND" "cuda"
    assert_eq "$REMOTE_FLASH_ATTN" "on"
    assert_eq "$REMOTE_KV_CACHE_TYPE" "q8_0"
    PATH="$_old_path"
    _rt_teardown
  }

  it "detects Vulkan and sets flash-attn off + f16 KV" && {
    _rt_setup
    cat > "$_RT_MOCK_BIN/ssh" << 'MOCK'
#!/bin/bash
echo "vulkan"
MOCK
    chmod +x "$_RT_MOCK_BIN/ssh"
    _old_path="$PATH"
    PATH="$_RT_MOCK_BIN:$PATH"
    REMOTE_SSH_TARGET="dabe@host"
    REMOTE_GPU_BACKEND="auto"
    REMOTE_KV_CACHE_TYPE="auto"
    REMOTE_FLASH_ATTN="auto"
    _remote_detect_gpu
    assert_eq "$REMOTE_GPU_BACKEND" "vulkan"
    assert_eq "$REMOTE_FLASH_ATTN" "off"
    assert_eq "$REMOTE_KV_CACHE_TYPE" "f16"
    PATH="$_old_path"
    _rt_teardown
  }

  it "defaults to cpu when SSH returns empty" && {
    _rt_setup
    cat > "$_RT_MOCK_BIN/ssh" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$_RT_MOCK_BIN/ssh"
    _old_path="$PATH"
    PATH="$_RT_MOCK_BIN:$PATH"
    REMOTE_SSH_TARGET="dabe@host"
    REMOTE_GPU_BACKEND="auto"
    REMOTE_KV_CACHE_TYPE="auto"
    REMOTE_FLASH_ATTN="auto"
    _remote_detect_gpu
    assert_eq "$REMOTE_GPU_BACKEND" "cpu"
    assert_eq "$REMOTE_FLASH_ATTN" "off"
    assert_eq "$REMOTE_KV_CACHE_TYPE" "f16"
    PATH="$_old_path"
    _rt_teardown
  }

  it "persists GPU config to remote.conf" && {
    _rt_setup
    cat > "$_RT_MOCK_BIN/ssh" << 'MOCK'
#!/bin/bash
echo "cuda"
MOCK
    chmod +x "$_RT_MOCK_BIN/ssh"
    _old_path="$PATH"
    PATH="$_RT_MOCK_BIN:$PATH"
    REMOTE_SSH_TARGET="dabe@host"
    REMOTE_GPU_BACKEND="auto"
    REMOTE_KV_CACHE_TYPE="auto"
    REMOTE_FLASH_ATTN="auto"
    _remote_detect_gpu
    # Check persisted values
    REMOTE_GPU_BACKEND="auto"
    REMOTE_FLASH_ATTN="auto"
    REMOTE_KV_CACHE_TYPE="auto"
    _remote_load_config
    assert_eq "$REMOTE_GPU_BACKEND" "cuda"
    assert_eq "$REMOTE_FLASH_ATTN" "on"
    assert_eq "$REMOTE_KV_CACHE_TYPE" "q8_0"
    PATH="$_old_path"
    _rt_teardown
  }

# ── Port conflict detection ────────────────────────────────────
describe "_remote_port_in_use"

  it "detects port not in use" && {
    _rt_setup
    # Use a high random port that should be free
    _remote_port_in_use 59999
    assert_fail $?
    _rt_teardown
  }

# ── Config security: rejects unknown keys ──────────────────────
describe "config security"

  it "rejects injected config keys" && {
    _rt_setup
    REMOTE_SSH_TARGET="test@host"
    _remote_save_config
    # Inject a dangerous key
    echo "PATH=/evil/bin" >> "$GEORGE_DIR/remote.conf"
    echo "HOME=/evil" >> "$GEORGE_DIR/remote.conf"
    _old_path="$PATH"
    _remote_load_config
    assert_eq "$PATH" "$_old_path"
    assert_neq "$HOME" "/evil"
    _rt_teardown
  }

  it "rejects REMOTE_JUMP_HOST-like typos" && {
    _rt_setup
    _remote_save_config
    echo "REMOTE_JUMP=hacked@host" >> "$GEORGE_DIR/remote.conf"
    _remote_load_config
    assert_eq "${REMOTE_JUMP:-}" ""
    _rt_teardown
  }

# ── Full round-trip: jump host topology config ─────────────────
describe "jump host topology round-trip"

  it "saves and restores full jump host config set" && {
    _rt_setup
    REMOTE_SSH_TARGET="dabe@george-home"
    REMOTE_JUMP_HOST="dabe@192.168.86.18"
    REMOTE_FORWARD_HOST="192.168.30.10"
    REMOTE_LLAMACPP_BIN="/home/dabe/llama.cpp/build/bin/llama-server"
    REMOTE_GPU_BACKEND="vulkan"
    REMOTE_KV_CACHE_TYPE="f16"
    REMOTE_FLASH_ATTN="off"
    _remote_save_config
    # Wipe all vars
    REMOTE_SSH_TARGET=""
    REMOTE_JUMP_HOST=""
    REMOTE_FORWARD_HOST="localhost"
    REMOTE_LLAMACPP_BIN=""
    REMOTE_GPU_BACKEND="auto"
    REMOTE_KV_CACHE_TYPE="auto"
    REMOTE_FLASH_ATTN="auto"
    # Reload
    _remote_load_config
    assert_eq "$REMOTE_SSH_TARGET" "dabe@george-home"
    assert_eq "$REMOTE_JUMP_HOST" "dabe@192.168.86.18"
    assert_eq "$REMOTE_FORWARD_HOST" "192.168.30.10"
    assert_eq "$REMOTE_LLAMACPP_BIN" "/home/dabe/llama.cpp/build/bin/llama-server"
    assert_eq "$REMOTE_GPU_BACKEND" "vulkan"
    assert_eq "$REMOTE_KV_CACHE_TYPE" "f16"
    assert_eq "$REMOTE_FLASH_ATTN" "off"
    _rt_teardown
  }

test_end
