# Bash Techniques Reference

> Every advanced bash pattern, idiom, and trick used across the codebase, documented with rationale, real examples, and gotchas.

---

## Table of Contents

- [Why Bash?](#why-bash)
- [Named References (Namerefs)](#named-references-namerefs)
- [FIFOs (Named Pipes)](#fifos-named-pipes)
- [Process Substitution](#process-substitution)
- [Background Jobs & Process Management](#background-jobs--process-management)
- [Traps & Cleanup](#traps--cleanup)
- [Associative Arrays](#associative-arrays)
- [Regex Matching & BASH_REMATCH](#regex-matching--bash_rematch)
- [Parameter Expansion](#parameter-expansion)
- [Here-Documents & Here-Strings](#here-documents--here-strings)
- [IFS Manipulation & Read Tricks](#ifs-manipulation--read-tricks)
- [Arithmetic Contexts](#arithmetic-contexts)
- [Epoch Arithmetic](#epoch-arithmetic)
- [PIPESTATUS](#pipestatus)
- [Awk State Machines](#awk-state-machines)
- [Printf Patterns](#printf-patterns)
- [Null-Byte-Safe File Iteration](#null-byte-safe-file-iteration)
- [Indirect Expansion](#indirect-expansion)
- [Function Existence Checks](#function-existence-checks)
- [Stub Pattern (Lazy Loading)](#stub-pattern-lazy-loading)
- [Conditional Debug Output](#conditional-debug-output)
- [Secure Deletion Fallback](#secure-deletion-fallback)
- [Quick Reference Table](#quick-reference-table)

---

## Why Bash?

Blue Lodge runs on Termux (Android ARM phones), Debian chroots inside ChromeOS, and standard Linux workstations. Bash is the only language guaranteed to be present on all these platforms without installing runtimes. The following constraints shape every technique choice:

1. **No external runtimes** — No Python, Node, Ruby, or Perl required
2. **Minimal dependencies** — Only `curl`, `jq`, `sqlite3`, `awk`, `sed`, and `openssl`
3. **ARM-aware** — Avoid patterns that waste CPU cycles (unnecessary subshells, busy loops)
4. **Offline-first** — Everything must work without network access

---

## Named References (Namerefs)

### What

`local -n varname="$1"` creates an alias to the caller's variable, allowing in-place modification without subshell overhead.

### Where Used

`lib/llm.sh` — `_llm_normalize_think()`:

```bash
_llm_normalize_think() {
    local -n _ntref="$1"
    _ntref="${_ntref//\[THINK\]/<think>}"
    _ntref="${_ntref//\[\/THINK\]/<\/think>}"
    _ntref="${_ntref//\[think\]/<think>}"
    _ntref="${_ntref//\[\/think\]/<\/think>}"
    # ... 8 total patterns
}
```

### Why

The streaming pipeline calls this on every chunk. Without namerefs, you'd need:

```bash
# BAD: Subshell + capture = buffer copy on every token
result=$(_llm_normalize_think "$chunk")

# GOOD: Nameref modifies caller's variable directly
_llm_normalize_think chunk    # Zero copy
```

On ARM (Snapdragon 8 Elite), the subshell version causes measurable latency at high token throughput. The nameref version has zero allocation overhead.

### Gotchas

- Namerefs require Bash 4.3+. Not available in `sh` or `dash`.
- Don't use the same name for the nameref and the target variable — it creates a circular reference.
- Don't export namerefs across subshells — the alias doesn't survive `$()`.

---

## FIFOs (Named Pipes)

### What

`mkfifo` creates a special file that acts as a pipe between processes. One process writes, another reads, and the kernel synchronizes them.

### Where Used

Every LLM streaming function: `lib/llm.sh` (5 instances), `lib/providers.sh` (1 instance).

```bash
local _fifo
_fifo=$(mktemp -u)    # Generate path without creating file
mkfifo "$_fifo"        # Create the named pipe

# Writer: curl runs in background, writes to FIFO
curl -sN "$url" -d "$payload" > "$_fifo" 2>/dev/null &
local curl_pid=$!

# Reader: while loop reads from FIFO in foreground
while IFS= read -r line; do
    # Process streaming tokens...
done < "$_fifo"

# Cleanup
kill "$curl_pid" 2>/dev/null
wait "$curl_pid" 2>/dev/null
rm -f "$_fifo"
```

### Why Not Just Pipe?

```bash
# Pipe version — curl PID is LOST (in subshell)
curl -sN "$url" | while read -r line; do
    # Can't kill curl from here
    # Variables set here are lost (subshell!)
done
```

With a FIFO:
1. **You keep the curl PID** — You can kill it cleanly on Ctrl+C or timeout
2. **The read loop runs in the main shell** — Variables persist after the loop
3. **No orphaned processes** — On ARM phones, orphaned curl processes burn battery

### Cleanup Pattern

Always clean up FIFOs in a trap:

```bash
trap "rm -f '$_fifo'; kill '$curl_pid' 2>/dev/null" EXIT INT TERM
```

### Gotchas

- If the writer dies before the reader opens the FIFO, the reader blocks forever. Always background the writer first.
- `mktemp -u` generates a name without creating the file — `mkfifo` creates it as a pipe. Don't use `mktemp` (without -u) which creates a regular file.
- FIFOs live on the filesystem. If the process crashes without cleanup, stale FIFOs accumulate. The trap pattern handles this.

---

## Process Substitution

### What

`<(command)` treats command output as a file descriptor, enabling loops that preserve parent-shell variable scope.

### Where Used

`lib/recall.sh`, `lib/agent.sh`, `lib/backup.sh`:

```bash
# lib/agent.sh — Parse plan steps
local -a steps=()
while IFS= read -r line; do
    steps+=("$line")     # This variable persists after the loop!
done < <(_agent_parse_steps "$plan")

echo "Got ${#steps[@]} steps"   # Works! 'steps' is in parent scope
```

### Why Not Pipe?

```bash
# BAD: Pipe creates subshell — 'steps' is lost after loop
_agent_parse_steps "$plan" | while IFS= read -r line; do
    steps+=("$line")
done
echo "${#steps[@]}"   # Always 0 — different scope!
```

The `< <()` pattern is the idiom for "loop over command output while keeping variables."

### Gotchas

- Process substitution is a bashism. Not available in `sh`, `dash`, or POSIX-only shells.
- The command inside `<()` runs asynchronously. If it produces output slowly, the `read` will block.

---

## Background Jobs & Process Management

### PID Tracking

```bash
curl -sN "$url" > "$_fifo" 2>/dev/null &
local curl_pid=$!    # $! = PID of last backgrounded process
```

### `disown` — Prevent Job Notifications

```bash
some_command &
disown $!   # Remove from job table
```

Without `disown`, when the background process terminates, bash prints `[1]+ Done some_command` or `[1]+ Terminated some_command`. This is ugly during spinner animation or LLM streaming.

Used in: `lib/ui.sh` (spinner), `lib/agent.sh` (background journal), `lib/llm.sh`.

### Safe Kill + Wait

```bash
kill "$pid" 2>/dev/null     # Send SIGTERM
wait "$pid" 2>/dev/null     # Reap zombie
```

Always `wait` after `kill`. Without it, the kernel keeps the process as a zombie (entry in the process table) until the parent reads its exit status.

---

## Traps & Cleanup

### Signal Traps

`lodge` (main entry point):

```bash
trap '_lodge_cleanup' INT TERM     # Ctrl+C or kill
trap '_lodge_exit_cleanup' EXIT    # Normal exit
```

### ERR Trap with Line Number

`install.sh`:

```bash
trap '_install_error $LINENO' ERR
```

`$LINENO` expands to the line number where the error occurred. This makes debugging installation failures straightforward.

### RETURN Trap

From SECURITY.md:

```bash
my_function() {
    local tmpfile=$(mktemp)
    trap 'rm -f "$tmpfile"' RETURN     # Cleanup when function returns

    # ... use tmpfile ...
    # Cleanup happens automatically, even on early return
}
```

The `RETURN` trap fires when the current function returns. It's scoped to the function, not the entire script.

### Why Dual Traps?

```bash
trap 'cleanup' INT TERM     # Signal handler
trap 'final_cleanup' EXIT   # Always runs
```

- `INT TERM` traps catch Ctrl+C and `kill`. You can do signal-specific work here (like printing a message).
- `EXIT` trap always runs — on normal exit, error exit, or signal. Use it for guaranteed cleanup (removing FIFOs, temp files).

If you only use `EXIT`, you can't distinguish between normal exit and Ctrl+C. If you only use `INT`, you miss normal exits.

---

## Associative Arrays

### Declaration and Lookup

`lib/commands.sh`:

```bash
declare -A CMD_REGISTRY     # command name → handler function
declare -A CMD_DESC         # command name → help text

_cmd_register() {
    CMD_REGISTRY["$1"]="$2"
    CMD_DESC["$1"]="$3"
}

_cmd_register "test"  "cmd_test"  "Run project tests"
_cmd_register "build" "cmd_build" "Build the project"

# O(1) dispatch:
local handler="${CMD_REGISTRY[$command]}"
"$handler" "$@"
```

### Iterating Keys

```bash
for cmd in "${!CMD_REGISTRY[@]}"; do
    echo "$cmd → ${CMD_REGISTRY[$cmd]}"
done
```

`${!array[@]}` gives the **keys**, not the values. This is the `!` prefix on array expansion.

### As In-Memory Store

`lib/secrets.sh` — Key rotation uses an associative array as temporary decrypted storage:

```bash
local -A decrypted
for f in "$VAULT_DIR"/*.enc; do
    local name=$(basename "$f" .enc)
    decrypted["$name"]=$(secrets_get "$name")
done
# Re-encrypt with new key...
```

The associative array exists only in the function's stack frame. When the function returns, the memory is freed — no plaintext persists.

### Gotchas

- Associative arrays require Bash 4.0+.
- You must `declare -A` before use. Regular assignment creates indexed arrays.
- Key order is not guaranteed (it's a hash map).

---

## Regex Matching & BASH_REMATCH

### Basic Pattern

```bash
if [[ "$line" =~ ^[0-9]{1,2}[\.\)][[:space:]]*(.*) ]]; then
    local item="${BASH_REMATCH[1]}"    # Capture group 1
fi
```

### Where Used

`lib/agent.sh` — Parsing is almost entirely regex-based:

| Pattern | Purpose |
|---------|---------|
| `^[0-9]{1,2}[\.\)]` | Extract numbered list items from LLM plans |
| `(compare\|contrast\|evaluate).*(and\|vs)` | Detect comparison queries for decomposition |
| `^/sandbox\ +[a-z]+\ +([^ ]+)` | Extract sandbox name from slash commands |
| `command not found: (.+)` | Parse error messages for package recommendations |

### Case-Insensitive Matching

Bash regex doesn't have an `i` flag. The codebase handles this two ways:

```bash
# Method 1: Character classes (used for verdict parsing)
if [[ "$text" =~ [Rr][Ee][Cc][Oo][Mm][Mm][Ee][Nn][Dd] ]]; then

# Method 2: Lowercase conversion before matching
local lower="${text,,}"
if [[ "$lower" =~ recommend ]]; then
```

### Why Not Grep?

```bash
# BAD: grep in subshell — forks a process, slower
if result=$(echo "$line" | grep -oP 'pattern'); then

# GOOD: bash regex — no fork, BASH_REMATCH for captures
if [[ "$line" =~ pattern ]]; then
    result="${BASH_REMATCH[1]}"
fi
```

On ARM, the fork overhead of `grep` is measurable when called in tight loops (like token parsing).

---

## Parameter Expansion

### Default Values — `${var:-default}`

Used everywhere for configuration:

```bash
LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
LODGE_NETWORK_AUDIT="${LODGE_NETWORK_AUDIT:-0}"
PROVIDER_TIMEOUT="${PROVIDER_TIMEOUT:-30}"
```

### Alternate Value — `${var:+alternate}`

```bash
# Only add the flag if LODGE_DEBUG is set
local debug_flag="${LODGE_DEBUG:+--verbose}"
curl $debug_flag "$url"
```

### Prefix Removal — `${var#pattern}` and `${var##pattern}`

```bash
# Strip "data: " SSE prefix
local json="${line#data: }"

# Strip heading markers: "### Title" → "Title"
local title="${line#\#\#\# }"

# Strip all leading path components: /usr/bin/git → git
local cmd="${path##*/}"     # Same as basename
```

`#` removes the **shortest** match. `##` removes the **longest** match.

### Suffix Removal — `${var%pattern}` and `${var%%pattern}`

```bash
# Strip file extension: "config.json" → "config"
local name="${filename%.enc}"

# Strip everything after first dot: "file.tar.gz" → "file"
local base="${filename%%.*}"
```

### Global Substitution — `${var//old/new}`

```bash
# Normalize all thinking tag variants to standard format
_ntref="${_ntref//\[THINK\]/<think>}"
_ntref="${_ntref//\[\/THINK\]/<\/think>}"
_ntref="${_ntref//\[think\]/<think>}"

# Escape single quotes for shell eval
value="${value//\'/\'\\\'\'}"
```

### Lowercase/Uppercase — `${var,,}` and `${var^^}`

```bash
# Case-insensitive comparison
[[ "${answer,,}" == "y"* ]]    # "Yes", "YES", "y" all match

# Uppercase for environment variable names
local env_name="${provider^^}_API_KEY"
```

---

## Here-Documents & Here-Strings

### Here-Document — Multi-Line Content

`lib/pgp.sh`:

```bash
_pgp_gpg --gen-key <<EOF
%echo Generating key...
Key-Type: RSA
Key-Length: 4096
Name-Real: $name
Name-Email: $email
%commit
EOF
```

`lib/memory.sh` — Initializing template files:

```bash
cat > "$dir/GEORGE.md" << MEMEOF
# Project Memory
## Summary
(no project loaded)
## Stack
(unknown)
MEMEOF
```

### Here-String — Variable as Stdin

```bash
# Feed variable content to a while loop
while IFS= read -r line; do
    process "$line"
done <<< "$raw_list"
```

**Why not `echo "$var" | while`?** The pipe creates a subshell for the while loop, so variables set inside the loop are lost when it exits.

### Indented Here-Document — `<<-`

```bash
cat <<-EOF
	This text can be indented with tabs
	The leading tabs are stripped
EOF
```

The `-` variant strips leading **tabs** (not spaces). Useful for keeping heredocs aligned with surrounding code.

---

## IFS Manipulation & Read Tricks

### Preserve Whitespace — `IFS=`

```bash
while IFS= read -r line; do
    echo "$line"    # Leading/trailing whitespace preserved
done < "$file"
```

Without `IFS=`, read strips leading and trailing whitespace. For streaming LLM output where indentation matters (code blocks), this is critical.

### Split on Custom Delimiter

```bash
# Split on '=' only (preserve spaces in values)
while IFS='=' read -r key value; do
    echo "Key: $key, Value: $value"
done < config.conf
```

### Read with Timeout — `read -t`

`lib/providers.sh` — SSE streaming:

```bash
while IFS= read -t "$_idle_timeout" -r line || [ -n "$line" ]; do
    # Process SSE line...
done < "$_fifo"
```

If no line arrives within `$_idle_timeout` seconds, `read` returns non-zero (timeout). The `|| [ -n "$line" ]` catches the case where the last line doesn't end with a newline.

### Read into Array — `read -ra`

```bash
IFS=' ' read -ra words <<< "$sentence"
echo "First word: ${words[0]}"
echo "Word count: ${#words[@]}"
```

### Null-Byte Delimiter — `read -d ''`

See the [Null-Byte-Safe File Iteration](#null-byte-safe-file-iteration) section below.

---

## Arithmetic Contexts

### `$(( ))` — Arithmetic Expansion

Returns the result as a string:

```bash
# Exponential backoff
delay=$((delay * 2))

# Percentage calculation
local pct=$(( current * 100 / total ))

# Epoch offset (3 days in seconds)
local cutoff=$(( now_epoch - 3 * 86400 ))
```

### `(( ))` — Arithmetic Conditional

Returns exit code 0 (true) if the expression is non-zero:

```bash
# Loop counter
while (( attempt < max_retries )); do
    (( attempt++ ))
done

# Boolean check (0 = false, non-zero = true)
if (( in_think )); then
    # Inside a thinking block...
fi

# Increment
(( failed++ ))
```

### Gotchas

- Division is integer-only. `$(( 7 / 2 ))` gives `3`, not `3.5`.
- For float math, use `awk`: `awk "BEGIN{printf \"%.1f\", 7/2}"` — avoids installing `bc`.

---

## Epoch Arithmetic

### Pattern

Convert everything to Unix timestamps (seconds since 1970-01-01) for arithmetic:

```bash
# Current time
local now=$(date +%s)

# 60-second rate window
local cutoff=$((now - 60))

# 3-day memory decay
local vivid_cutoff=$(( now - 3 * 86400 ))

# Token expiry countdown
local deadline=$(( $(date +%s) + expires_in ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 1
done
```

### Why Not `date -d`?

`date -d "3 days ago"` is a **GNU extension**. It doesn't work on:
- macOS (BSD date)
- Busybox (Alpine, some embedded)
- Termux (sometimes)

Epoch arithmetic (`now - N * 86400`) works everywhere.

### Used For

| Feature | Calculation |
|---------|------------|
| Rate limiting | `now - COOLDOWN_WINDOW` for call count in window |
| Memory decay | `now - N * 86400` for vivid/fading/sediment tiers |
| Token expiry | `now + expires_in` for OAuth deadlines |
| Timeout detection | `now - start_time > MAX_DURATION` |

---

## PIPESTATUS

### What

`${PIPESTATUS[@]}` is an array of exit codes from the last pipeline. `${PIPESTATUS[0]}` is the first command, `${PIPESTATUS[1]}` is the second, etc.

### Where Used

`lib/agent.sh`:

```bash
jq -r '.items[]' "$honeydew" | agent_inner_loop
exit_code=${PIPESTATUS[0]}    # jq's exit code (not agent_inner_loop's)
```

### Why

In a pipeline `A | B`, `$?` gives you B's exit code. If you need A's exit code (e.g., to check if jq failed to parse), you need `PIPESTATUS`.

### Gotchas

- `PIPESTATUS` is overwritten by the next command. Capture it immediately:

```bash
cmd1 | cmd2
local -a pipe_status=("${PIPESTATUS[@]}")   # Save immediately
# Now you can safely use pipe_status[0], pipe_status[1]
```

---

## Awk State Machines

### Multi-Line Section Parsing

`lib/memory.sh` — Parse GEORGE.md sections:

```bash
awk '
    BEGIN { section = "(preamble)"; content = "" }
    /^## / {
        if (section != "(preamble)" && content != "") {
            print section "|||" content
        }
        section = $0
        content = ""
        next
    }
    { content = content $0 "\n" }
    END {
        if (content != "") print section "|||" content
    }
' "$GEORGE_MD"
```

This processes the file in a single pass, accumulating content for each section, emitting when a new section header is found.

### Rate Limit Filtering

`lib/providers.sh` — Filter timestamps within a window:

```bash
awk -v cutoff="$cutoff" '$1 >= cutoff' "$meter_file" | wc -l
```

Count calls within the rate window: single-pass awk filter + wc for count.

### Why Awk Over Bash Loops?

```bash
# BAD: Bash while loop — forks process per line for any command
while read -r line; do
    # Each 'echo' or computation here is slow
done < big_file

# GOOD: Awk — compiled pattern matcher, processes entire file in one C-level loop
awk '/pattern/ { count++ } END { print count }' big_file
```

Awk is orders of magnitude faster for line-by-line file processing. Bash loops should only be used when you need to call shell functions or modify shell variables.

---

## Printf Patterns

### `%b` — Interpret Backslash Escapes

```bash
printf "%b\n" "${C_BLUE}${SYM_DOT}${C_RESET} ${msg}"
```

`%b` interprets `\033[...m` escape codes. `echo -e` does this too, but `printf %b` is POSIX-guaranteed.

### Character Repetition

```bash
printf '─%.0s' $(seq 1 50)    # Print '─' 50 times
```

`%.0s` tells printf to print zero characters of the argument (but still consume it from the argument list). `seq 1 50` provides 50 arguments, so `─` is printed 50 times.

### In-Place Line Update

```bash
printf '\r%s' "$message"      # Overwrite current line (progress bar)
printf '\r%*s\r' 80 ''        # Clear line (80 spaces, then back to start)
```

### Fixed-Width Columns

```bash
printf "  %-30s %b%s bytes%b\n" "$name" "$C_DIM" "$size" "$C_RESET"
```

`%-30s` left-aligns in a 30-character field. Keeps tables aligned.

### Float Formatting (via Awk)

```bash
# Bash has no float support. Use awk's printf:
awk "BEGIN{printf \"%.1f\", $bytes / 1073741824}"    # GB with 1 decimal
```

---

## Null-Byte-Safe File Iteration

### Problem

Filenames can contain spaces, newlines, and special characters. Normal `for f in $(find ...)` breaks on spaces.

### Solution

```bash
while IFS= read -r -d '' filepath; do
    process "$filepath"
done < <(find "$dir" -name "GEORGE.md" -print0)
```

`-print0` uses null bytes (`\0`) as separators instead of newlines. `read -d ''` reads until null byte. Null bytes cannot appear in filenames (it's the one character prohibited), making this completely safe.

Used in: `lib/backup.sh` for iterating project files across sandboxes.

---

## Indirect Expansion

### `${!var}` — Variable Variable

```bash
local key_name="PROVIDER_MODEL_OPENAI"
echo "${!key_name}"    # Prints the VALUE of PROVIDER_MODEL_OPENAI
```

Used in `lib/providers.sh` for dynamic provider configuration lookup.

### Dynamic Variable Assignment

```bash
# Method 1: eval (dangerous if input untrusted)
eval "$var_name=$val"

# Method 2: printf -v (safer)
printf -v "$var_name" '%s' "$val"

# Method 3: declare (safest for local scope)
declare "$var_name=$val"
```

The codebase uses `eval` sparingly and only with validated input (e.g., numeric values for rate limits).

---

## Function Existence Checks

### `declare -f` — Test Without Calling

```bash
if declare -f slash_${name} &>/dev/null; then
    slash_${name} "$@"    # Call it
else
    ui_err "Unknown slash command: $name"
fi
```

`declare -f funcname` returns 0 if the function exists, 1 if not. The `&>/dev/null` suppresses the function definition that `declare -f` would normally print.

### `command -v` — Check for External Commands

```bash
if command -v openssl &>/dev/null; then
    # Use openssl
else
    # Fallback
fi
```

Prefer `command -v` over `which` — it's a bash builtin (no fork) and handles aliases and functions correctly.

---

## Stub Pattern (Lazy Loading)

### Problem

`lib/ui.sh` is loaded early and calls `_transcript_ui()`, but `lib/transcript.sh` is loaded later.

### Solution

Define no-op stubs that get overwritten:

```bash
# In ui.sh (loaded first):
_transcript_ui() { :; }         # No-op (: is the null command)
transcript_section() { :; }     # No-op

# In transcript.sh (loaded later):
_transcript_ui() {
    # Real implementation replaces the stub
    local type="$1" msg="$2"
    local clean=$(echo "$msg" | sed 's/\x1b\[[0-9;]*m//g')
    transcript_append "[$type] $clean"
}
```

When `transcript.sh` is sourced, bash's `function` redefinition replaces the stub. Any calls made before loading still succeed (they just do nothing).

---

## Conditional Debug Output

### Pattern

```bash
[ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] $msg"
```

The short-circuit `&&` ensures the `ui_dim` call (which involves `printf` + transcript logging) only executes when debug mode is enabled. Without this guard, every debug statement would format strings and call functions even when nobody is watching.

Used in: `lib/providers.sh`, `lib/agent.sh`.

---

## Secure Deletion Fallback

### Pattern

```bash
if command -v shred &>/dev/null; then
    shred -u "$file" 2>/dev/null
else
    dd if=/dev/urandom of="$file" \
        bs=$(stat -c %s "$file" 2>/dev/null || echo 256) count=1 2>/dev/null
    rm -f "$file"
fi
```

**Tier 1 (shred)**: Multi-pass overwrite + unlink. Best option on traditional HDDs.  
**Tier 2 (dd + rm)**: Single-pass random overwrite. Works on systems without `shred` (Termux).

**Caveat**: On flash storage (phones, SSDs) and CoW filesystems (btrfs, ZFS), previous file contents may persist in unallocated blocks regardless of overwrite method. The vault encryption is the primary protection; secure deletion is defense in depth.

Used in: `lib/secrets.sh` for vault operations.

---

## Quick Reference Table

| Technique | Syntax | Purpose | Where |
|-----------|--------|---------|-------|
| Nameref | `local -n ref="$1"` | Zero-copy pass-by-reference | llm.sh |
| FIFO | `mkfifo "$path"` | Decouple processes | llm.sh, providers.sh |
| Process substitution | `< <(cmd)` | Loop without subshell scope loss | agent.sh, recall.sh |
| Background PID | `cmd &; pid=$!` | Track async processes | providers.sh, ui.sh |
| Disown | `disown $pid` | Suppress job notifications | ui.sh, agent.sh |
| Trap | `trap 'cleanup' EXIT` | Guaranteed resource cleanup | lodge, install.sh |
| Associative array | `declare -A map` | O(1) command dispatch | commands.sh |
| BASH_REMATCH | `[[ x =~ (pat) ]]` | Regex capture without grep fork | agent.sh |
| Default value | `${var:-default}` | Config fallback | everywhere |
| Prefix strip | `${var#pattern}` | Remove SSE "data: " prefix | llm.sh |
| Global replace | `${var//old/new}` | Normalize think tags | llm.sh |
| Lowercase | `${var,,}` | Case-insensitive compare | ui.sh |
| Here-string | `<<< "$var"` | Variable as stdin | agent.sh |
| IFS= read | `IFS= read -r` | Preserve whitespace in streams | providers.sh |
| Read with timeout | `read -t N` | Detect stalled SSE connections | providers.sh |
| Epoch math | `$((now - N * 86400))` | Cross-platform date comparison | providers.sh, journal.sh |
| PIPESTATUS | `${PIPESTATUS[0]}` | Exit code from pipe stage | agent.sh |
| Awk state machine | `awk '/^##/ { emit }` | Single-pass section parsing | memory.sh |
| printf %b | `printf "%b" "$esc"` | POSIX escape interpretation | ui.sh |
| Null-safe find | `find -print0 \| read -d ''` | Handle filenames with spaces | backup.sh |
| Indirect expansion | `${!var}` | Dynamic variable lookup | providers.sh |
| Function check | `declare -f name` | Test existence without calling | slash.sh |
| Stub pattern | `func() { :; }` | Lazy-loaded function slots | ui.sh |
| Debug guard | `[[ $DBG ]] && msg` | Skip formatting when off | providers.sh |
| Secure delete | `shred -u \|\| dd+rm` | Overwrite before delete | secrets.sh |

---

*Previous: [Security & Secrets](SECURITY_AND_SECRETS.md) | Next: [Architecture Index](ARCHITECTURE_INDEX.md)*
