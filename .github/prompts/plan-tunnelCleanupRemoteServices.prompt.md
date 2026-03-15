# Plan: Tunnel Cleanup + Remote Systemd Services + llama-server Detection Fix

## Overview

Three interrelated issues discovered from transcript review and live testing:

1. **Stale SSH tunnels** — `/quit` and Ctrl+C don't clean up tunnel processes + watchdog, leaving orphaned port forwards across Termux restarts
2. **Remote llama-server binary not found** — `_remote_detect_llamacpp_bin()` fails via SSH, causing `ERROR: Cannot find llama-server on remote` on every `/q`. Model switch never fires, llama-server never restarts, old model stays loaded.
3. **No persistent services on remote** — ollama and llama-server run manually (foreground `pts/3`), die on reboot or terminal close. Need systemd units.

**Port remap note**: The 11434→21434 / 8080→18080 remap is expected and correct — local ollama and llama-server are intentional separate instances. The tunnel remaps to avoid port conflicts with local services.

---

## Part 1: Fix llama-server Binary Detection (Blocking Bug)

### Problem

Every `/q` triggers `models_ensure_for_scenario()` → `_models_switch()` → `_remote_restart_llamacpp()` → `_remote_detect_llamacpp_bin()`. The detect function SSHes in and probes paths but returns empty, causing the error. Since the switch fails, `_MODELS_ACTIVE` never updates, so the next `/q` retries and fails again — infinite error loop on every query.

The model still responds because the existing llama-server on the remote is still running with the old model through the tunnel — the LLM call path works, only the switch path fails.

**Known remote state** (from `ps aux`):
```
/home/dabe/llama.cpp/build/bin/llama-server -m /usr/share/ollama/.ollama/models/blobs/sha256-667b0c... --port 8080 --host 0.0.0.0 --jinja -ngl 99
```

The binary IS at `$HOME/llama.cpp/build/bin/llama-server` — one of the probed paths. So either:
- The SSH exec itself is failing (key/auth issue in BatchMode, or the remote shell doesn't expand `$HOME`)
- The `2>/dev/null` is swallowing a meaningful error
- The SSH key path or port in remote.conf doesn't match the tunnel's auth context

### Diagnosis Steps

```bash
# 1. Check what remote.conf has
cat ~/.george/remote.conf

# 2. Test SSH exec directly (same args as _remote_exec)
ssh -o BatchMode=yes -o ConnectTimeout=10 \
    -p 22 -i ~/.ssh/id_ed25519 \
    dabe@george-home 'echo HOME=$HOME; which llama-server; ls -la ~/llama.cpp/build/bin/llama-server'

# 3. If that fails, test without BatchMode to see interactive errors
ssh dabe@george-home 'which llama-server; ls ~/llama.cpp/build/bin/llama-server'

# 4. Check if the binary is in PATH on remote
ssh dabe@george-home 'command -v llama-server'
```

### Code Fixes

**File: `lib/remote.sh` — `_remote_detect_llamacpp_bin()`** (~L253)

Current probing swallows all errors. Fix:
- Add fallback: parse running process (`pgrep -a llama-server`) to extract the binary path
- Add more probe paths (varies by install method)
- Don't suppress stderr on the SSH call so we can debug connection issues

```bash
_remote_detect_llamacpp_bin() {
    [ -n "$REMOTE_LLAMACPP_BIN" ] && return 0
    local _bin
    # Try common paths + extract from running process as fallback
    _bin=$(_remote_exec "command -v llama-server 2>/dev/null || \
        for p in \$HOME/llama.cpp/build/bin/llama-server \
                 /usr/local/bin/llama-server \
                 /opt/llama.cpp/build/bin/llama-server \
                 /usr/bin/llama-server; do \
            [ -x \"\$p\" ] && echo \"\$p\" && break; \
        done; \
        # Fallback: extract path from running process
        if [ -z \"\$p\" ] || [ ! -x \"\$p\" 2>/dev/null ]; then \
            pgrep -a llama-server 2>/dev/null | grep -oP '^\d+\s+\K/\S*llama-server' | head -1; \
        fi" 2>/dev/null)
    if [ -n "$_bin" ]; then
        REMOTE_LLAMACPP_BIN="$_bin"
        _remote_save_config
        return 0
    fi
    return 1
}
```

**File: `lib/models.sh` — `_models_switch()` remote llamacpp path** (~L880)

The error currently fires on every `/q` because the switch fails and `_MODELS_ACTIVE` never updates. Fix: when already connected and the model hasn't changed, don't try to restart — just track it. The `_MODELS_ACTIVE != target` check at the top handles this, BUT on first query after connect, `_MODELS_ACTIVE` is empty/stale. Need a "soft switch" that sets the active model without restarting if the remote server is already healthy:

```bash
# In the remote llamacpp branch, before calling _remote_restart:
# If the remote server is already healthy, just track the model
if curl -sf --max-time 3 "$LLAMA_CPP_URL/health" 2>/dev/null | grep -q '"ok"'; then
    # Server is running — set tracking without restart
    _MODELS_ACTIVE="$target"
    LODGE_MODEL="$target"
    [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] remote llama-server healthy — tracking $target without restart"
    return 0
fi
```

This way, the first `/q` after connect sees a healthy server and just tracks it. Subsequent queries hit the `_MODELS_ACTIVE == target` fast path. Actual restarts only happen when `models_use <different-model>` is called.

---

## Part 2: Fix Stale SSH Tunnel Cleanup

### Problem

`_lodge_exit_cleanup()` (EXIT trap in `lodge` ~L137) and `_lodge_cleanup()` (INT/TERM trap ~L84) never call `remote_disconnect()`. The SSH tunnel + bash watchdog (which respawns every 15s) survive after lodge exits. On Termux kill + relaunch, orphaned processes from old PIDs hold ports.

### Code Fixes

**File: `lodge` — `_lodge_exit_cleanup()`** (~L137)

Add `remote_disconnect` call at the top of exit cleanup:

```bash
_lodge_exit_cleanup() {
    # Tear down SSH tunnel + watchdog (must happen first —
    # watchdog respawns tunnel if killed after)
    declare -f remote_disconnect &>/dev/null && remote_disconnect 2>/dev/null

    # Kill any leftover curl → LLM processes
    pkill -f "curl.*v1/chat/completions" 2>/dev/null || true
    # ... rest of existing cleanup ...
}
```

**File: `lib/remote.sh` — `remote_connect()`** (~L428)

Add orphan tunnel sweep at the top, before opening a new tunnel. This catches processes from sessions where the PID file was lost but SSH is still running:

```bash
remote_connect() {
    local target="${1:-$REMOTE_SSH_TARGET}"
    # ...existing validation...

    # Kill existing tunnel if any (tracked by PID file)
    if _remote_tunnel_alive; then
        remote_disconnect 2>/dev/null
    fi

    # ── Orphan sweep: kill SSH tunnels from dead sessions ──────
    # If a previous lodge session was killed (Termux swipe-close),
    # the PID file may be gone but the SSH process persists.
    if [ -n "$target" ]; then
        local _orphan_pids
        _orphan_pids=$(ps aux 2>/dev/null | grep "ssh.*-N.*${target}" | grep -v grep | awk '{print $2}')
        if [ -n "$_orphan_pids" ]; then
            echo "$_orphan_pids" | xargs kill 2>/dev/null
            sleep 1
            # Also kill any watchdog loops
            local _orphan_watchdogs
            _orphan_watchdogs=$(ps aux 2>/dev/null | grep "_remote_watchdog.*${target}" | grep -v grep | awk '{print $2}')
            [ -n "$_orphan_watchdogs" ] && echo "$_orphan_watchdogs" | xargs kill 2>/dev/null
        fi
    fi

    # ...rest of existing connect logic...
}
```

### Verification

```bash
# Test 1: /quit cleanup
# Start lodge → /remote connect → /quit → check:
ps aux | grep 'ssh.*george-home' | grep -v grep  # should be empty

# Test 2: Ctrl+C cleanup
# Start lodge → /remote connect → Ctrl+C → check same

# Test 3: Orphan sweep on reconnect
# Start lodge → /remote connect → kill Termux → relaunch →
# /remote connect → ports bind normally, no error
```

---

## Part 3: Persistent Systemd Services on Remote Node

### Existing Script Audit

| Script | Systemd? | Ollama override? | Enables service? | Gaps |
|--------|----------|------------------|------------------|------|
| `scripts/inference-server-install.sh` | llama-server only (gated `INSTALL_SYSTEMD=1`, default 0) | No `OLLAMA_HOST=0.0.0.0` override | No (prints instructions only) | No `-m` flag in ExecStart; doesn't enable; no Ollama binding fix |
| `scripts/inference-server-deploy.sh` | Delegates to install.sh | No | No | Doesn't pass `INSTALL_SYSTEMD=1` |
| `scripts/inference-server-models.sh` | No | No | No | Direct kill/start via PID in `/tmp`, no systemd awareness |

**Current setup was done manually** — the install scripts were not used. Both services run in foreground terminals. The existing scripts can create a llama-server unit but have gaps we'll fix.

### Phase A: One-Time Manual Setup (Your Current Install)

This wraps your existing manual setup in systemd **without reinstalling or re-downloading blobs**.

#### A1: Ollama Service (likely already exists from official installer)

```bash
# Check if ollama.service exists
ssh dabe@george-home "systemctl status ollama"

# If active but binding 127.0.0.1, create the override:
ssh dabe@george-home 'sudo mkdir -p /etc/systemd/system/ollama.service.d && \
  echo -e "[Service]\nEnvironment=\"OLLAMA_HOST=0.0.0.0:11434\"" | \
  sudo tee /etc/systemd/system/ollama.service.d/override.conf && \
  sudo systemctl daemon-reload && \
  sudo systemctl enable --now ollama'

# Verify binding (must show 0.0.0.0:11434, NOT 127.0.0.1)
ssh dabe@george-home "ss -tlnp | grep 11434"
```

#### A2: llama-server Service (new)

Base unit has **no `-m` flag** — model is set via a systemd override file. On reboot, the last-used override persists automatically. On model switch, `_remote_restart_llamacpp()` writes a new override and restarts.

```bash
# Create base unit (no model — loaded via override)
ssh dabe@george-home 'sudo tee /etc/systemd/system/llama-server.service > /dev/null << EOF
[Unit]
Description=llama.cpp inference server (George remote node)
After=network.target ollama.service

[Service]
Type=simple
User=dabe
ExecStart=/home/dabe/llama.cpp/build/bin/llama-server \
    --port 8080 --host 0.0.0.0 \
    --jinja -ngl 99
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable llama-server'
```

Note: The binary path (`/home/dabe/llama.cpp/build/bin/llama-server`) and GPU layers (`-ngl 99`) may vary per install. The `/remote config` command stores these values for the code path.

#### A3: Set Initial Model Override (current GGUF blob)

```bash
# Using the known blob from ps aux:
GGUF="/usr/share/ollama/.ollama/models/blobs/sha256-667b0c1932bc6ffc593ed1d03f895bf2dc8dc6df21db3042284a6f4416b06a29"

ssh dabe@george-home "sudo mkdir -p /etc/systemd/system/llama-server.service.d && \
sudo tee /etc/systemd/system/llama-server.service.d/override.conf > /dev/null << EOF
[Service]
ExecStart=
ExecStart=/home/dabe/llama.cpp/build/bin/llama-server \\
    -m $GGUF \\
    --port 8080 --host 0.0.0.0 \\
    --jinja -ngl 99
EOF
sudo systemctl daemon-reload && sudo systemctl restart llama-server"

# Verify
ssh dabe@george-home "systemctl status llama-server --no-pager -l | head -15"
ssh dabe@george-home "curl -s http://127.0.0.1:8080/health"
```

The `ExecStart=` (empty line) clears the base unit's ExecStart before setting the override — this is how systemd override files work.

#### A4: Kill the Manual foreground Process

After systemd is managing llama-server, kill the old foreground process in `pts/3`:

```bash
ssh dabe@george-home "kill 14043"  # the old manual process
# systemd's llama-server.service is now the only instance
```

### Phase B: Update `_remote_restart_llamacpp()` for Systemd

**File: `lib/remote.sh` — `_remote_restart_llamacpp()`** (~L330)

Add systemd-aware path: detect if `llama-server.service` is managed, write override with new GGUF, restart via systemctl. Fall back to direct kill/spawn if no systemd.

```bash
_remote_restart_llamacpp() {
    local _model_name="$1"
    local _model_base="$2"

    # ...existing validation and GGUF resolution...

    local _port="${REMOTE_LLAMACPP_PORT:-8080}"
    local _ngl="${REMOTE_LLAMACPP_GPU_LAYERS:-99}"
    local _ctx="${REMOTE_LLAMACPP_CTX_SIZE:-32768}"
    local _bin="$REMOTE_LLAMACPP_BIN"

    # Detect if llama-server is managed by systemd on remote
    local _has_systemd=0
    if _remote_exec "systemctl is-enabled llama-server 2>/dev/null" | grep -q 'enabled'; then
        _has_systemd=1
    fi

    if [ "$_has_systemd" -eq 1 ]; then
        # ── Systemd path: write override + restart service ─────
        _remote_exec "
            sudo mkdir -p /etc/systemd/system/llama-server.service.d
            sudo tee /etc/systemd/system/llama-server.service.d/override.conf > /dev/null << OVERRIDE
[Service]
ExecStart=
ExecStart=$_bin -m '$_remote_gguf' \\
    --port $_port --host 0.0.0.0 \\
    --jinja -ngl $_ngl -c $_ctx \\
    --threads \$(nproc 2>/dev/null || echo 4) --parallel 1
OVERRIDE
            sudo systemctl daemon-reload
            sudo systemctl restart llama-server
        " 2>/dev/null
    else
        # ── Direct path: kill + nohup (existing behavior) ──────
        # ...existing kill/spawn logic...
    fi

    # ...existing health check polling...
}
```

### Phase C: Fix Install Scripts for Future Deployments

These changes make the scripts do the right thing for new installs so nobody has to do manual Phase A again.

**File: `scripts/inference-server-install.sh`**

1. Default `INSTALL_SYSTEMD=1` instead of 0
2. Add Ollama `OLLAMA_HOST=0.0.0.0` override creation
3. Add `systemctl enable --now` after creating the unit
4. Keep base ExecStart without `-m` (model loaded separately via models script)

**File: `scripts/inference-server-deploy.sh`**

1. Pass `INSTALL_SYSTEMD=1` when calling remote install:
   ```bash
   ssh ... "INSTALL_SYSTEMD=1 bash inference-server-install.sh"
   ```

**File: `scripts/inference-server-models.sh`**

1. Detect systemd: if `systemctl is-enabled llama-server` succeeds, use override+restart instead of direct kill/spawn
2. Same override pattern as `_remote_restart_llamacpp()`

---

## Part 4: Future — `/remote setup-services` Subcommand

Automate Phase A entirely from George via SSH:

```
/remote setup-services    → SSHes to remote, creates both units + overrides, enables, verifies
```

This would:
1. Detect if ollama.service exists → create OLLAMA_HOST override if needed
2. Detect llama-server binary path (using improved detection)
3. Create llama-server.service base unit
4. Create model override from currently running GGUF (parse `pgrep -a llama-server`)
5. Enable both services
6. Verify health endpoints

Recommend as a follow-up after confirming manual setup works.

---

## Execution Order

1. **Part 1** (detection fix) — immediate code change, unblocks model switching
2. **Part 2** (tunnel cleanup) — immediate code change, fixes orphan process leak
3. **Part 3 Phase A** (manual service setup) — run SSH commands against george-home
4. **Part 3 Phase B** (systemd-aware restart) — code change after Phase A confirmed working
5. **Part 3 Phase C** (fix install scripts) — code change for future deployments
6. **Part 4** (`/remote setup-services`) — follow-up convenience command

## Verification Checklist

- [ ] `/q hello` with debug on — no "Cannot find llama-server" error
- [ ] `/model use <different-model>` — remote server restarts with new model via systemd
- [ ] `/quit` — `ps aux | grep ssh.*george-home` empty
- [ ] Ctrl+C — same check
- [ ] Kill Termux → relaunch → `/remote connect` — tunnel binds normally
- [ ] `ssh dabe@george-home "sudo reboot"` → wait → both services auto-start
- [ ] `ssh dabe@george-home "curl -s localhost:8080/health"` → `{"status":"ok"}`
- [ ] `ssh dabe@george-home "curl -s localhost:11434/api/tags"` → JSON model list
- [ ] From George: `/remote connect` → `/remote status` → both tunnels healthy
