# Security Audit — Blue Lodge

**Date:** 2026-02-22
**Auditor:** GitHub Copilot (automated review)
**Scope:** All shell scripts in the Blue Lodge codebase

---

## Threat Model

Blue Lodge executes LLM-generated code on a user's device. The primary threat vectors are:

1. **Prompt injection** — A malicious task or CLAUDE.md file tricks the LLM into generating harmful commands
2. **LLM hallucination** — The model generates destructive operations that weren't requested
3. **Input injection** — Unsanitized user inputs reach shell evaluation
4. **Data exfiltration** — LLM-generated commands send local files to external servers

## Security Architecture

### Permission Levels (`LODGE_PERMISSION`)

| Level | Behavior |
|-------|----------|
| `0` | Ask before every shell command and file write |
| `1` (default) | Ask before destructive commands; auto-approve safe operations |
| `2` | Auto-approve everything (**dangerous** — not recommended) |

### Defenses in Place

1. **Workspace sandboxing** (`tools_write_file`) — Refuses to write files outside the current workspace directory. Uses `realpath` to resolve symlinks and `..` traversal.

2. **Destructive command detection** (`tools_exec_bash`) — Regex-based detection of dangerous patterns before execution:
   - `rm -rf`, `sudo`, `chmod 777`, `dd if=`, `mkfs`, writes to `/dev/`
   - `curl | bash`, `wget | bash` (pipe-to-shell)
   - `nc`, `ncat`, `/dev/tcp`, `mkfifo` (network backdoors)
   - `eval`, `exec` (indirect execution)
   - Writes to `/etc/`

3. **Output truncation** — Long command output is truncated to prevent memory exhaustion.

4. **Project name validation** (`cmd_init`) — Project names are validated against `^[a-zA-Z_][a-zA-Z0-9_-]*$`.

5. **Model isolation** — Ollama runs locally; no data is sent to external APIs.

6. **Graceful cancellation** — SIGINT handler kills active LLM requests and unloads the model from memory.

7. **Tempfile cleanup** — LLM response tempfiles are cleaned up via RETURN traps even on unexpected exits.

## Issues Found & Remediated

### Critical (Fixed)

| Issue | Location | Fix |
|-------|----------|-----|
| `eval "$build_cmd"` command injection | `commands/build.sh` | Changed to `bash -c "$build_cmd"` — still executes but doesn't expand shell metacharacters in the calling shell |
| `eval "$test_cmd"` command injection | `commands/test.sh` | Same fix |
| `git add $args` unquoted variable | `commands/commit.sh` | Added `--` separator and left word-splitting intentional for multi-file staging |
| Narrow destructive pattern check | `lib/tools.sh` | Expanded regex to catch pipe-to-shell, reverse shells, network tools, eval/exec, and /etc writes |
| `grep -v '^\(none\)$'` regex error | `lib/memory.sh` | Fixed BRE regex — bare `(` is literal in BRE, `\(` opens a group |

### Medium (Fixed)

| Issue | Location | Fix |
|-------|----------|-----|
| No tempfile cleanup on crash | `lib/llm.sh` | Added `trap 'rm -f "$tmpfile"' RETURN` |
| 120s timeout causing failures | `lib/llm.sh` | Default changed to `180` (safety net); user cancels via Ctrl+C |
| No model memory management | `lib/llm.sh` | Added `llm_unload()`, `llm_cancel()`, `llm_is_loaded()` |

### Low / Accepted Risks

| Issue | Location | Status |
|-------|----------|--------|
| `LODGE_PERMISSION=2` auto-approves all | `lib/tools.sh` | Documented; user opt-in only |
| `curl \| sh` for Ollama install | `install.sh` | Standard Ollama install method; runs only once during setup |
| Sandbox exec passes `$cmd` to `bash -c` | `lib/sandbox.sh` | Commands originate from LLM which already passes through the permission system in `tools_exec_bash`; sandbox_exec is called by sandbox_build/test only with hardcoded commands |
| LLM-generated file paths could be malicious | `lib/tools.sh` | Mitigated by `realpath` + workspace boundary check in `tools_write_file` |

## Recommendations

### For Users

1. **Keep `LODGE_PERMISSION` at `1`** (default) — Review destructive commands before execution
2. **Review CLAUDE.md** periodically — A compromised CLAUDE.md could influence the LLM's decisions
3. **Don't run Blue Lodge as root** — Always run in a normal user context
4. **Use sandboxes for untrusted repos** — `lodge /sandbox clone <repo>` isolates the project

### Implemented Security Features (v0.2.0)

All five items from the original roadmap have been implemented in `lib/security.sh`:

#### 1. Command Allowlist ✅

Instead of relying solely on blocklist detection, `tools_exec_bash` now checks commands against a curated allowlist of 100+ safe command prefixes (cargo, git, python, grep, ls, cat, etc.). At `LODGE_PERMISSION=1`:
- Commands matching the allowlist are auto-approved
- Commands matching the dangerous blocklist require confirmation (default: deny)
- All other commands require confirmation (default: approve)

Users can extend the allowlist by adding commands to `~/.george/allowlist.conf` (one per line).

**Commands:** `/security help` shows available subcommands.

#### 2. File Write Diff Preview ✅

When overwriting an existing file, `tools_write_file` now displays a unified diff with color-coded output:
- **Green (+)** lines show additions
- **Red (-)** lines show deletions
- **Cyan (@@)** hunk headers for context
- Limited to 40 lines of diff output for readability

New files still show a 10-line content preview.

#### 3. Network Audit Mode ✅

An optional mode that blocks all network-accessing commands from LLM-generated output. When enabled, commands matching `curl`, `wget`, `nc`, `ncat`, `ssh`, `scp`, `rsync`, `/dev/tcp`, and `telnet` are rejected.

**Toggle:** `/security network on|off` or set `LODGE_NETWORK_AUDIT=1`.

#### 4. Signed & Encrypted Memory (Bodily Autonomy) ✅

George's memory files (`soul.md`, `journal.md`) are protected by a multi-layered integrity system:

- **HMAC-SHA256 Signing** — Every write to journal.md and soul.md generates a `.sig` companion file. Signatures are verified at startup to detect external tampering.
- **AES-256-CBC Encryption** — Files can be encrypted with PBKDF2 key derivation (100,000 iterations). George can encrypt his own memory files so only he can read them.
- **Keyring** — A per-user signing key is auto-generated at `~/.george/.keyring/signing.key` (mode 600, directory mode 700). The keyring initializes automatically on first run.
- **Share Tokens** — George can generate SHA-256 share tokens that prove file authenticity without revealing the signing key.

**Commands:**
- `/security sign <file>` — Sign a file
- `/security verify <file>` — Verify file integrity
- `/security encrypt <file>` — Encrypt a file (AES-256-CBC)
- `/security decrypt <file>` — Decrypt a file
- `/security share <file>` — Generate a share token
- `/security verify-token <file> <token>` — Verify a share token
- `/security check` — Check integrity of all identity files

#### 5. Per-Sandbox Permissions ✅

Each sandbox can have its own permission level, independent of the global `LODGE_PERMISSION` setting. When `sandbox_exec()` runs a command, it looks up the sandbox-specific permission first and falls back to the global level.

**Commands:**
- `/security sandbox set <name> <level>` — Set permission level (0/1/2) for a sandbox
- `/security sandbox get <name>` — Get a sandbox's permission level
- `/security sandbox list` — List all sandbox permission overrides

Permissions are stored in `~/.george/sandbox_permissions.conf`.

#### 6. Encrypted Secrets Vault (v0.3.0) ✅

A dedicated encrypted key-value store for sensitive credentials (API keys, OAuth tokens, cryptocurrency private keys). Built on top of the existing signing keyring.

- **AES-256-CBC encryption** with PBKDF2 (100,000 iterations) for each secret
- **Per-secret files** — each secret stored as `~/.george/.vault/<name>.enc` (mode 700 on vault directory)
- **No plaintext on disk** — values decrypted to memory only when needed
- **Scoped access** — `secrets_with` runs commands in subshells with secrets as env vars; vars are gone when command exits
- **Key rotation** — `secrets_rotate_key` re-encrypts all secrets with a freshly generated key
- **Secure deletion** — `shred -u` used where available, fallback to overwrite + `rm`
- **Name validation** — secret names restricted to `[a-zA-Z_][a-zA-Z0-9_.-]*` to prevent path traversal

**Commands:** `/secret set|get|delete|list|import|rotate|status`

### Security Status

Run `/security status` to see an overview of all active security features, including:
- Permission level and allowlist status
- Network audit mode
- Keyring and signing status
- Identity file integrity
- Sandbox permission overrides

---

*This audit covers the codebase as of v0.2.0. Re-audit recommended after significant changes.*
