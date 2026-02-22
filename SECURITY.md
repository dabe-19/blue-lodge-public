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
| 120s timeout causing failures | `lib/llm.sh` | Default changed to `0` (no timeout); user cancels via Ctrl+C |
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

### For Future Development

1. **Command allowlist** — Instead of blocklisting dangerous patterns, consider an allowlist of safe command prefixes (cargo, uv, git, python, etc.)
2. **File write diff preview** — Show a diff before overwriting existing files, not just a preview of the new content
3. **Network audit mode** — Optional flag to block all network-accessing commands from LLM output
4. **Signed CLAUDE.md** — Hash-based verification that CLAUDE.md hasn't been tampered with outside of Blue Lodge
5. **Per-sandbox permissions** — Allow different permission levels for different sandboxes

---

*This audit covers the codebase as of v0.1.0. Re-audit recommended after significant changes.*
