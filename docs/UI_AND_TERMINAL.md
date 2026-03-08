# UI & Terminal Rendering

> How output is styled, spinners work, markdown is rendered, and the terminal stays responsive during streaming and background operations.

---

## Table of Contents

- [Design Philosophy](#design-philosophy)
- [Color System](#color-system)
- [Message Functions](#message-functions)
- [The Spinner System](#the-spinner-system)
- [Markdown-Lite Rendering](#markdown-lite-rendering)
- [Interactive Prompts](#interactive-prompts)
- [Transcript Hooks](#transcript-hooks)
- [Environment Detection](#environment-detection)
- [Troubleshooting](#troubleshooting)
- [Key Functions Reference](#key-functions-reference)

---

## Design Philosophy

The UI layer follows a **terminal-native** approach:

1. **No TUI framework** — Pure ANSI escape codes and printf. No ncurses, no dialog, no whiptail. This keeps dependencies at zero and works on every terminal emulator.
2. **256-color palette** — Uses `\033[38;5;Nm` codes for rich colors that work on modern terminals (including Termux on Android).
3. **Transcript-aware** — Every output function hooks into the transcript system, allowing session replay without ANSI escape noise.
4. **Task-mode awareness** — Interactive prompts auto-confirm when running inside an agent task, preventing the LLM from getting stuck on a confirmation dialog.

---

## Color System

### ANSI 256-Color Codes

Colors are exported as global variables for use across all libraries:

```bash
# Foreground colors (text)
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_BLUE='\033[38;5;33m'
C_CYAN='\033[38;5;44m'
C_GREEN='\033[38;5;34m'
C_YELLOW='\033[38;5;220m'
C_RED='\033[38;5;196m'
C_PURPLE='\033[38;5;135m'
C_GRAY='\033[38;5;245m'
C_WHITE='\033[38;5;255m'

# Background colors
C_BG_BLUE='\033[48;5;17m'

# Brand color
C_LODGE='\033[38;5;33m'   # Blue Lodge blue
```

**Bash Technique — `\033[38;5;Nm`**: This is the ANSI escape sequence for 256-color mode. `38;5` sets foreground, `48;5` sets background. `N` is the color number (0-255). This works on virtually all modern terminals, including Termux.

### Unicode Symbols

```bash
SYM_CHECK='✓'    # Success
SYM_CROSS='✗'    # Failure
SYM_ARROW='→'    # Step indicator
SYM_DOT='●'      # Info bullet
SYM_THINK='◆'    # Thought process
SYM_WARN='⚠'     # Warning
SYM_LODGE='🏛'   # Brand prompt icon
```

---

## Message Functions

### Core Output Pattern

Every message function follows the same pattern:

```bash
ui_info() {
    local msg="$1"
    printf "%b\n" "${C_BLUE}${SYM_DOT}${C_RESET} ${msg}"
    _transcript_ui "info" "$msg"
}
```

**Bash Technique — `printf "%b\n"`**: The `%b` format specifier interprets backslash escapes (like `\033[`) in the argument. This is safer than `echo -e` which has inconsistent behavior across platforms. `printf` is POSIX-guaranteed to support `%b`.

### Message Types

| Function | Symbol | Color | Purpose |
|----------|--------|-------|---------|
| `ui_info()` | ● | Blue | Informational messages |
| `ui_ok()` | ✓ | Green | Success confirmations |
| `ui_warn()` | ⚠ | Yellow | Warnings |
| `ui_err()` | ✗ | Red | Errors |
| `ui_step()` | → | Cyan | Step-by-step progress |
| `ui_think()` | ◆ | Purple | LLM thinking process |
| `ui_dim()` | (none) | Gray | Secondary information |
| `ui_code()` | (none) | Gray | Code snippets |

### Headers and Dividers

```bash
ui_header() {
    local title="$1" subtitle="${2:-}"
    local width=50

    # Top border
    printf "%b" "$C_LODGE"
    printf '┌'
    printf '─%.0s' $(seq 1 $((width - 2)))
    printf '┐\n'

    # Title line
    printf '│ %b%-*s│\n' "$C_BOLD" $((width - 4)) "$title"

    # Subtitle (optional)
    if [[ -n "$subtitle" ]]; then
        printf '│ %b%-*s│\n' "$C_GRAY" $((width - 4)) "$subtitle"
    fi

    # Bottom border
    printf '└'
    printf '─%.0s' $(seq 1 $((width - 2)))
    printf '┘%b\n' "$C_RESET"
}
```

**Bash Technique — `printf '─%.0s' $(seq 1 N)`**: This repeats the `─` character N times. `%.0s` tells printf to take the argument but print zero characters of it, while still consuming it from the argument list. Combined with `$(seq 1 N)`, this generates N copies of the character. It's a common bash idiom for string repetition.

### Progress Bar

```bash
ui_progress() {
    local current="$1" total="$2"
    local pct=$(( current * 100 / total ))
    local filled=$(( pct / 5 ))    # 20 blocks total
    local empty=$(( 20 - filled ))

    printf '\r%b[' "$C_CYAN"
    printf '█%.0s' $(seq 1 $filled) 2>/dev/null
    printf '░%.0s' $(seq 1 $empty) 2>/dev/null
    printf '] %d%%%b' "$pct" "$C_RESET"
}
```

The `\r` (carriage return) overwrites the current line, creating an in-place updating progress bar.

---

## The Spinner System

### Why Spinners Are Complex in Bash

Spinners need to:
1. Run continuously in the background (while the LLM processes)
2. Not interfere with stdout (which is being captured)
3. Be cleanly killable (without leaving artifacts)
4. Write to the terminal even when stdout is redirected

### `ui_spinner_start()`

```bash
ui_spinner_start() {
    local msg="${1:-Working...}"

    # Run in background subshell
    (
        local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        while true; do
            printf '\r%b %s %b' "${C_CYAN}${frames[$i]}" "$msg" "$C_RESET" > /dev/tty
            i=$(( (i + 1) % ${#frames[@]} ))
            sleep 0.1
        done
    ) &
    _SPINNER_PID=$!
    disown $_SPINNER_PID
}
```

**Bash Technique — `disown`**: After backgrounding the spinner with `&`, `disown` removes it from the shell's job table. Without this, when the parent exits or is interrupted, bash would print a "terminated" message for the spinner job — ugly output artifacts.

**Bash Technique — Writing to `/dev/tty`**: The spinner writes to `/dev/tty` instead of stdout because the parent process's stdout might be captured in a `$()` command substitution. `/dev/tty` always reaches the actual terminal.

### `ui_spinner_stop()`

```bash
ui_spinner_stop() {
    if [[ -n "${_SPINNER_PID:-}" ]]; then
        kill -9 "$_SPINNER_PID" 2>/dev/null
        wait "$_SPINNER_PID" 2>/dev/null
        _SPINNER_PID=""
    fi
    # Clear the spinner line
    printf '\r%*s\r' 50 '' > /dev/tty
}
```

**Why `kill -9`?** The spinner is a `while true` loop with `sleep 0.1`. A normal SIGTERM might be caught during sleep, causing a delay. `SIGKILL` is immediate and guaranteed. The `2>/dev/null` suppresses the error if the process already exited.

**Line Clearing**: `printf '\r%*s\r' 50 ''` moves to the start of the line, prints 50 spaces (overwriting the spinner text), then moves back to the start. This cleanly removes the spinner without leaving artifacts.

---

## Markdown-Lite Rendering

### `ui_render_response()`

Transforms LLM markdown output into styled terminal text:

```bash
ui_render_response() {
    local text="$1"

    echo "$text" | while IFS= read -r line; do
        # Headings
        if [[ "$line" =~ ^###\  ]]; then
            printf "%b%s%b\n" "$C_BOLD$C_CYAN" "${line#\#\#\# }" "$C_RESET"
        elif [[ "$line" =~ ^##\  ]]; then
            printf "%b%s%b\n" "$C_BOLD$C_BLUE" "${line#\#\# }" "$C_RESET"
        elif [[ "$line" =~ ^#\  ]]; then
            printf "%b%s%b\n" "$C_BOLD$C_WHITE" "${line#\# }" "$C_RESET"

        # Bullet points
        elif [[ "$line" =~ ^[[:space:]]*[-*]\  ]]; then
            printf "  %b•%b %s\n" "$C_CYAN" "$C_RESET" "${line#*[-*] }"

        # Code blocks (toggle state)
        elif [[ "$line" =~ ^\`\`\` ]]; then
            in_code=$(( 1 - ${in_code:-0} ))
            (( in_code )) && printf "%b" "$C_GRAY" || printf "%b" "$C_RESET"

        # Code content
        elif (( ${in_code:-0} )); then
            printf "%b  %s%b\n" "$C_GRAY" "$line" "$C_RESET"

        # Normal text
        else
            printf "%s\n" "$line"
        fi
    done
}
```

**Bash Technique — `${line#\#\#\# }`**: Parameter expansion with glob pattern removal. `#` removes the shortest prefix match from the start. The pattern `\#\#\# ` matches `### ` (the heading markup). This strips the markdown heading markers while keeping the heading text.

---

## Interactive Prompts

### `ui_confirm()` — Y/N with Task Mode

```bash
ui_confirm() {
    local msg="$1" default="${2:-n}"

    # Auto-confirm during agent tasks
    if [[ "${_LODGE_IN_TASK:-0}" == "1" ]]; then
        return 0   # Yes
    fi

    printf "%b%s [y/N] %b" "$C_YELLOW" "$msg" "$C_RESET"
    local answer
    read -r answer < /dev/tty
    [[ "${answer,,}" == "y"* ]]
}
```

**Bash Technique — `${answer,,}`**: Lowercase conversion. The `,,` operator converts the entire string to lowercase. This makes the comparison case-insensitive: `Y`, `y`, `Yes`, `yes` all match.

**Task Mode Auto-Confirm**: When `_LODGE_IN_TASK=1`, all confirmations return true. This prevents the agent from getting stuck waiting for human input on file write confirmations, dangerous command warnings, etc.

### `ui_select()` — Numbered Menu

```bash
ui_select() {
    local prompt="$1"
    shift
    local options=("$@")

    for i in "${!options[@]}"; do
        printf "  %b%d)%b %s\n" "$C_CYAN" $((i+1)) "$C_RESET" "${options[$i]}"
    done

    printf "%b%s: %b" "$C_YELLOW" "$prompt" "$C_RESET"
    local choice
    read -r choice < /dev/tty

    echo "${options[$((choice-1))]}"
}
```

**Bash Technique — `${!options[@]}`**: The `!` prefix gives array indices instead of values. This allows simultaneously printing the index number and the option text.

---

## Transcript Hooks

### Side-Channel Logging

Every UI function calls `_transcript_ui()` to log output without ANSI codes:

```bash
_transcript_ui() {
    local type="$1" msg="$2"
    # Strip ANSI codes for clean transcript
    local clean
    clean=$(echo "$msg" | sed 's/\x1b\[[0-9;]*m//g')
    transcript_append "[$type] $clean"
}
```

**Bash Technique — ANSI Stripping**: `sed 's/\x1b\[[0-9;]*m//g'` removes all ANSI escape codes. The pattern matches: `ESC` (`\x1b`), `[`, any combination of digits and semicolons, and `m` (the SGR terminator). This produces clean, readable transcript files.

### Stub Pattern

The transcript functions are initially stubs (no-ops) and get replaced when `lib/transcript.sh` is loaded:

```bash
# In ui.sh (loaded first):
_transcript_ui() { :; }         # No-op stub
transcript_section() { :; }     # No-op stub

# In transcript.sh (loaded later):
_transcript_ui() {
    # Real implementation...
}
```

This avoids dependency issues — UI functions can always call `_transcript_ui()` even if the transcript library isn't loaded yet.

---

## Environment Detection

### Proot Detection

```bash
_lodge_in_proot() {
    # Method 1: Environment variable
    [[ -n "${PROOT_TMP_DIR:-}" ]] && return 0

    # Method 2: Check for proot-distro marker
    [[ -d /etc/proot-distro ]] && return 0

    # Method 3: Check for host filesystem mount
    [[ -d /host-rootfs ]] && return 0

    # Method 4: Check UID (proot always runs as root)
    [[ "$(id -u)" == "0" ]] && [[ -f /etc/proot-distro ]] && return 0

    return 1
}
```

**Why multiple methods?** Different proot-distro versions expose different markers. The multi-method approach handles all known configurations.

### Termux API Gate

```bash
_lodge_termux_api_ok() {
    # Must be explicitly enabled
    [[ "${LODGE_TERMUX_API:-0}" != "1" ]] && return 1

    # Must have termux-battery-status command
    command -v termux-battery-status &>/dev/null || return 1

    # Must NOT be inside proot (API doesn't work from proot)
    _lodge_in_proot && return 1

    return 0
}
```

---

## Troubleshooting

### Colors Not Showing

1. **Terminal support**: Ensure terminal supports 256 colors (`echo $TERM` should be `xterm-256color` or similar)
2. **SSH sessions**: Some SSH configs strip color. Try `ssh -t` for forced TTY allocation
3. **Pipe mode**: Colors are disabled when stdout isn't a TTY (`[[ -t 1 ]]` check)

### Spinner Artifacts Left on Screen

1. **Killed without cleanup**: If the parent crashes, `ui_spinner_stop()` never runs. Manually clear: `printf '\r%*s\r' 80 ''`
2. **Multiple spinners**: Check for leaked `_SPINNER_PID`. Only one spinner should run at a time
3. **/dev/tty unavailable**: In some environments (cron, CI), `/dev/tty` doesn't exist. The spinner silently fails

### Progress Bar Not Updating

The progress bar uses `\r` (carriage return) for in-place updates. If the terminal is in a mode that treats `\r` as a newline, each update appears on a new line instead.

### Confirm Auto-Approving Unexpectedly

If confirmations are being skipped when they shouldn't be, check `_LODGE_IN_TASK`. This flag is set to 1 during agent execution and should be 0 during interactive use.

---

## Key Functions Reference

| Function | Purpose |
|----------|---------|
| `ui_print()` | Raw printf with transcript hook |
| `ui_info()` | Blue info message |
| `ui_ok()` | Green success message |
| `ui_warn()` | Yellow warning |
| `ui_err()` | Red error |
| `ui_step()` | Cyan step indicator |
| `ui_think()` | Purple thinking message |
| `ui_dim()` | Gray secondary text |
| `ui_header()` | Bordered box with title |
| `ui_section()` | Horizontal section divider |
| `ui_progress()` | In-place progress bar (20 blocks) |
| `ui_spinner_start()` | Background async spinner |
| `ui_spinner_stop()` | Kill spinner, clear line |
| `ui_prompt()` | REPL prompt with project name |
| `ui_code_block()` | Bordered code display |
| `ui_confirm()` | Y/N with task-mode auto-confirm |
| `ui_select()` | Numbered menu selection |
| `ui_render_response()` | Markdown-lite terminal rendering |
| `ui_expand_escapes()` | Convert `\n`/`\t` to real chars |
| `_lodge_in_proot()` | Detect proot environment |
| `_lodge_termux_api_ok()` | Check Termux API availability |

---

*Previous: [Memory, Recall & Journal](MEMORY_AND_RECALL.md) | Next: [Security & Secrets](SECURITY_AND_SECRETS.md)*
