#!/bin/bash
# ── George: UI Rendering ──────────────────────────────────
# Lightweight TUI components using ANSI escape codes.
# No ncurses, no Python — pure bash for mobile.

[ -n "${_LIB_UI_LOADED:-}" ] && return 0; _LIB_UI_LOADED=1

# ── Colors ─────────────────────────────────────────────────────
export C_RESET='\033[0m'
export C_BOLD='\033[1m'
export C_DIM='\033[2m'
export C_ITALIC='\033[3m'
export C_BLUE='\033[38;5;75m'
export C_CYAN='\033[38;5;117m'
export C_GREEN='\033[38;5;114m'
export C_YELLOW='\033[38;5;226m'     # Radiant top peak
export C_GOLD='\033[38;5;220m'       # Front face bright gold
export C_AMBER='\033[38;5;214m'      # 3D shadow face amber
export C_RED='\033[38;5;203m'
export C_PURPLE='\033[38;5;141m'
export C_GRAY='\033[38;5;245m'
export C_WHITE='\033[38;5;255m'
export C_BG_BLUE='\033[48;5;24m'
export C_LODGE='\033[38;5;33m'     # Lodge blue

# ── Symbols ────────────────────────────────────────────────────
export SYM_CHECK="✓"
export SYM_CROSS="✗"
export SYM_ARROW="▸"
export SYM_DOT="●"
export SYM_THINK="◆"
export SYM_WARN="⚠"
export SYM_LODGE="⌂"
export SYM_EYE="👁"
export SYM_PYRAMID="▲"

# ── Termux API opt-in gate ──────────────────────────────────────
# Termux-API commands hang inside proot-distro (the companion app
# cannot communicate through the proot boundary). Default: DISABLED.
# Enable with:  export LODGE_TERMUX_API=1  (native Termux only)
export LODGE_TERMUX_API="${LODGE_TERMUX_API:-0}"

# Runtime proot detection: force-disable even if env says enabled.
# The shell RC may have LODGE_TERMUX_API=1 from a native Termux install,
# but inside proot-distro ALL termux-api commands hang forever.
# Detection: /host-rootfs (proot bind), PROOT_TMP_DIR env, or
# uid 0 (proot always runs as fake root). Native Termux never runs as uid 0.
_lodge_in_proot() {
    [ -d /host-rootfs ] && return 0
    [ -n "${PROOT_TMP_DIR:-}" ] && return 0
    # proot-distro always emulates uid 0; native Termux never does
    [[ "$(id -u)" == "0" ]] && return 0
    return 1
}
if [[ "$LODGE_TERMUX_API" == "1" ]] && _lodge_in_proot; then
    export LODGE_TERMUX_API=0
fi

# Quick predicate — returns 0 (true) only when explicitly opted in.
_lodge_termux_api_ok() {
    [[ "$LODGE_TERMUX_API" == "1" ]]
}

# ── Transcript hook stubs ──────────────────────────────────────
# No-op unless lib/transcript.sh is loaded (overrides with real impls).
declare -f _transcript_ui  &>/dev/null || _transcript_ui()  { :; }
declare -f transcript_section &>/dev/null || transcript_section() { :; }

# ── Core Print Functions ───────────────────────────────────────
ui_print() { printf "%b\n" "$1"; _transcript_ui print "$1"; }
ui_info()  { printf " %b%s %b%s%b\n" "$C_BLUE" "$SYM_DOT" "$C_WHITE" "$1" "$C_RESET"; _transcript_ui info "$1"; }
ui_ok()    { printf " %b%s %b%s%b\n" "$C_GREEN" "$SYM_CHECK" "$C_WHITE" "$1" "$C_RESET"; _transcript_ui ok "$1"; }
ui_warn()  { printf " %b%s %b%s%b\n" "$C_YELLOW" "$SYM_WARN" "$C_WHITE" "$1" "$C_RESET"; _transcript_ui warn "$1"; }
ui_err()   { printf " %b%s %b%s%b\n" "$C_RED" "$SYM_CROSS" "$C_WHITE" "$1" "$C_RESET"; _transcript_ui error "$1"; }
ui_step()  { printf " %b%s %b%s%b\n" "$C_CYAN" "$SYM_ARROW" "$C_WHITE" "$1" "$C_RESET"; _transcript_ui step "$1"; }
ui_think() { printf " %b%s %b%s%b\n" "$C_GOLD" "$SYM_EYE" "$C_GRAY" "$1" "$C_RESET"; _transcript_ui think "$1"; }
ui_dim()   { printf " %b  %s%b\n" "$C_DIM" "$1" "$C_RESET"; _transcript_ui dim "$1"; }
ui_code()  { printf " %b  %s%b\n" "$C_GRAY" "$1" "$C_RESET"; _transcript_ui code "$1"; }

# ── Limitation Messaging ─────────────────────────────────────
# Track one prompt per infeasibility episode key.
_UI_LIMITATION_EPISODE_KEY=""
_UI_LIMITATION_PROMPT_SHOWN=0

ui_limitation_block() {
    local constraint="$1"
    local tried="$2"
    local choices="$3"
    local outcome="$4"
    local episode_key="${5:-$constraint}"

    if [ "$episode_key" != "$_UI_LIMITATION_EPISODE_KEY" ]; then
        _UI_LIMITATION_EPISODE_KEY="$episode_key"
        _UI_LIMITATION_PROMPT_SHOWN=0
    fi

    if [ "$outcome" = "limitation_prompt_pending" ] && [ "$_UI_LIMITATION_PROMPT_SHOWN" -eq 1 ]; then
        return 0
    fi

    [ "$outcome" = "limitation_prompt_pending" ] && _UI_LIMITATION_PROMPT_SHOWN=1

    ui_warn "Constraint: $constraint"
    ui_info "What George tried: $tried"
    if [ "$outcome" = "limitation_prompt_pending" ]; then
        ui_step "Available next choices: RESCOPE | ALT_PATH | TERMINATE"
        ui_dim "  Decision token required: RESCOPE | ALT_PATH | TERMINATE"
    else
        ui_step "Available next choices: $choices"
    fi
    ui_dim "  Outcome state: $outcome"
}

ui_respond_outcome_class() {
    local text="$1"
    local lower
    lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')

    if [[ "$lower" =~ (graceful[[:space:]]termination|blocked_by_capability|blocked_by_policy|user_terminated|cannot[[:space:]]proceed|constraint[[:space:]]detected|constraint[[:space:]]unavailable) ]]; then
        echo "graceful_termination_due_to_constraints"
        return 0
    fi

    echo "successful_completion"
}

# ── Structured Output ──────────────────────────────────────────
ui_header() {
    local title="$1"
    local sub="${2:-}"
    local w=52
    [ ${#title} -ge $((w - 6)) ] && w=$(( ${#title} + 8 ))
    local pad_title=$(( (w - ${#title} - 4) / 2 ))
    [ $pad_title -lt 1 ] && pad_title=1
    echo ""
    printf " %b╭" "$C_LODGE"
    printf '─%.0s' $(seq 1 $w)
    printf "╮%b\n" "$C_RESET"
    printf " %b│%b" "$C_LODGE" "$C_RESET"
    printf "%*s" $pad_title ""
    printf "%b%s %s%b" "$C_BOLD" "$SYM_LODGE" "$title" "$C_RESET"
    printf "%*s" $(( w - pad_title - ${#title} - 3 )) ""
    printf "%b│%b\n" "$C_LODGE" "$C_RESET"
    printf " %b╰" "$C_LODGE"
    printf '─%.0s' $(seq 1 $w)
    printf "╯%b\n" "$C_RESET"
    if [ -n "$sub" ]; then
        echo -e " ${C_DIM}${sub}${C_RESET}"
    fi
    echo ""
    _transcript_ui header "$title${sub:+ — $sub}"
}

# ── Mascot: Eye of Providence (3D Pyramid All-Seeing Eye) ──────
ui_mascot_eye() {
    local state="${1:-center}"
    local eye_str=" 👁 "
    case "$state" in
        left)   eye_str="◓  " ;;
        right)  eye_str="  ◓ " ;;
        blink)  eye_str=" ─ " ;;
        glow)   eye_str="✦👁✦" ;;
        sleep)  eye_str=" - " ;;
        *)      eye_str=" 👁 " ;;
    esac

    printf " %b          ▲ %b█%b\n" "$C_YELLOW" "$C_GRAY" "$C_RESET"
    printf " %b         / %b\\ %b█%b\n" "$C_GOLD" "$C_AMBER" "$C_GRAY" "$C_RESET"
    printf " %b        /%b%s%b\\ %b█%b\n" "$C_GOLD" "$C_YELLOW" "$eye_str" "$C_AMBER" "$C_GRAY" "$C_RESET"
    printf " %b       /%b_____%b\\ %b█%b\n" "$C_GOLD" "$C_AMBER" "$C_AMBER" "$C_GRAY" "$C_RESET"
    printf " %b      ∴   %b✦%b   ∵ %b█%b\n" "$C_AMBER" "$C_YELLOW" "$C_AMBER" "$C_GRAY" "$C_RESET"
    printf " %b     /%b ┌─┬─┬─┐ %b\\ %b█%b\n" "$C_GOLD" "$C_LODGE" "$C_AMBER" "$C_GRAY" "$C_RESET"
    printf " %b    /__%b┴─┴─┴─┴%b__\\ %b█%b\n" "$C_GOLD" "$C_LODGE" "$C_AMBER" "$C_GRAY" "$C_RESET"
}

ui_mascot_banner() {
    local title="$1"
    local sub="${2:-}"
    local eye_state="${3:-center}"
    
    local eye_str=" 👁 "
    case "$eye_state" in
        left)   eye_str="◓  " ;;
        right)  eye_str="  ◓ " ;;
        blink)  eye_str=" ─ " ;;
        glow)   eye_str="✦👁✦" ;;
        sleep)  eye_str=" - " ;;
        *)      eye_str=" 👁 " ;;
    esac

    local box_w=72
    local title_len=${#title}
    local sub_len=${#sub}
    if [ $sub_len -gt 67 ]; then
        sub="${sub:0:64}..."
        sub_len=67
    fi
    
    local pad_t=$(( box_w - 4 - title_len ))
    local pad_s=$(( box_w - 2 - sub_len ))
    [ $pad_t -lt 0 ] && pad_t=0
    [ $pad_s -lt 0 ] && pad_s=0

    echo ""
    printf " %b          ▲ %b█%b          %b\n" "$C_YELLOW" "$C_GRAY" "$C_RESET" "$C_RESET"
    printf " %b         / %b\\ %b█%b         %b╭──────────────────────────────────────────────────────────────────────╮%b\n" "$C_GOLD" "$C_AMBER" "$C_GRAY" "$C_RESET" "$C_LODGE" "$C_RESET"
    printf " %b        /%b%s%b\\ %b█%b        %b│%b  %b%s %s%b%*s%b│%b\n" "$C_GOLD" "$C_YELLOW" "$eye_str" "$C_AMBER" "$C_GRAY" "$C_RESET" "$C_LODGE" "$C_RESET" "$C_BOLD" "$SYM_LODGE" "$title" "$C_RESET" "$pad_t" "" "$C_LODGE" "$C_RESET"
    printf " %b       /%b_____%b\\ %b█%b       %b│%b  %b%s%b%*s%b│%b\n" "$C_GOLD" "$C_AMBER" "$C_AMBER" "$C_GRAY" "$C_RESET" "$C_LODGE" "$C_RESET" "$C_DIM" "$sub" "$C_RESET" "$pad_s" "" "$C_LODGE" "$C_RESET"
    printf " %b      ∴   %b✦%b   ∵ %b█%b      %b╰──────────────────────────────────────────────────────────────────────╯%b\n" "$C_AMBER" "$C_YELLOW" "$C_AMBER" "$C_GRAY" "$C_RESET" "$C_LODGE" "$C_RESET"
    printf " %b     /%b ┌─┬─┬─┐ %b\\ %b█%b     %b\n" "$C_GOLD" "$C_LODGE" "$C_AMBER" "$C_GRAY" "$C_RESET" "$C_RESET"
    printf " %b    /__%b┴─┴─┴─┴%b__\\ %b█%b    %b\n" "$C_GOLD" "$C_LODGE" "$C_AMBER" "$C_GRAY" "$C_RESET" "$C_RESET"
    echo ""
    echo ""
    _transcript_ui header "$title${sub:+ — $sub}"
    return 0
}

_TUI_ACTIVE=0

ui_tui_start() {
    local title="${1:-George}"
    local sub="${2:-}"
    local eye_state="${3:-center}"
    
    # Enter Alternate Screen Buffer & Clear Screen
    if [ "${LODGE_TUI:-1}" -eq 1 ] && [ -t 1 ]; then
        printf "\033[?1049h\033[2J\033[1;1H" >&1
        _TUI_ACTIVE=1
        trap 'ui_tui_stop' EXIT INT TERM
    fi
    
    ui_mascot_banner "$title" "$sub" "$eye_state"
}

ui_tui_stop() {
    if [ "${_TUI_ACTIVE:-0}" -eq 1 ]; then
        _TUI_ACTIVE=0
        # Restore Standard Screen Buffer
        printf "\033[?1049l" >&1
    fi
}

ui_mascot_pin() {
    [ "${LODGE_PIN_MASCOT:-0}" -eq 1 ] || return 0
    local tty_rows
    tty_rows=$(tput lines 2>/dev/null || echo 24)
    if [ "$tty_rows" -ge 12 ]; then
        # Lock rows 1..8 for mascot banner, scroll rows 9..tty_rows
        printf "\033[9;%dr" "$tty_rows" >&2
        printf "\033[9;1H" >&2
    fi
}

ui_mascot_unpin() {
    printf "\033[r" >&2
}

ui_exec_stream() {
    local cmd="$1"
    local prefix="${2:-  │ }"
    local full_out=""
    local tmp_err
    tmp_err=$(mktemp "${TMPDIR:-/tmp}/lodge_exec.XXXXXX")
    
    ( bash -c "$cmd" 2>&1; echo $? > "$tmp_err" ) | while IFS= read -r line || [ -n "$line" ]; do
        full_out+="$line"$'\n'
        if [ "${LODGE_QUIET:-0}" -eq 0 ]; then
            printf "%b%s%b%s\n" "$C_DIM" "$prefix" "$C_RESET" "$line" >&2
        fi
    done
    
    local exit_code=0
    if [ -f "$tmp_err" ]; then
        exit_code=$(cat "$tmp_err" 2>/dev/null)
        rm -f "$tmp_err" 2>/dev/null
    fi
    
    _LAST_EXEC_OUT="$full_out"
    return ${exit_code:-0}
}

ui_section() {
    local title="$1"
    echo ""
    printf " %b── %s %b" "$C_LODGE" "$title" "$C_DIM"
    printf '─%.0s' $(seq 1 $(( 40 - ${#title} )))
    printf "%b\n" "$C_RESET"
    transcript_section "$title"
}

ui_divider() {
    printf " %b" "$C_DIM"
    printf '─%.0s' $(seq 1 48)
    printf "%b\n" "$C_RESET"
    _transcript_ui divider "────────────────────────────────────────────────"
}

# ── Progress ───────────────────────────────────────────────────
ui_progress() {
    local current=$1
    local total=$2
    local label="${3:-}"
    local pct=$(( current * 100 / total ))
    local filled=$(( pct / 5 ))
    local empty=$(( 20 - filled ))
    printf "\r %b[%b" "$C_DIM" "$C_BLUE"
    printf '█%.0s' $(seq 1 $filled) 2>/dev/null
    printf '%b' "$C_DIM"
    printf '░%.0s' $(seq 1 $empty) 2>/dev/null
    printf "%b] %b%d/%d%b" "$C_DIM" "$C_WHITE" "$current" "$total" "$C_RESET"
    if [ -n "$label" ]; then
        printf " %b%s%b" "$C_GRAY" "$label" "$C_RESET"
    fi
    if [ "$current" -eq "$total" ]; then echo ""; fi
}

# ── Spinner ────────────────────────────────────────────────────
_SPINNER_PID=""
# Detect best output target: /dev/tty if available, else stderr
[ -t 2 ] && { true >/dev/tty; } 2>/dev/null && _SPINNER_TTY="/dev/tty" || _SPINNER_TTY="/dev/stderr"

ui_spinner_start() {
    local msg="${1:-Thinking}"
    local _tty="$_SPINNER_TTY"
    (
        # Close inherited stdout/stderr so this subshell doesn't hold
        # the write-end of any $() pipe open (prevents FD-leak hangs).
        exec >/dev/null 2>/dev/null
        local frames=('▲ (👁 )' '▲ (◓ )' '▲ (👁 )' '▲ ( ◓ )' '▲ (✦👁 ✦)' '▲ ( ─ )')
        local i=0
        while true; do
            printf "\r %b%s%b %b%s...%b " "$C_GOLD" "${frames[$i]}" "$C_RESET" "$C_GRAY" "$msg" "$C_RESET" > "$_tty" 2>/dev/null
            i=$(( (i + 1) % 6 ))
            sleep 0.25
        done
    ) &
    _SPINNER_PID=$!
    disown "$_SPINNER_PID" 2>/dev/null
}

ui_spinner_stop() {
    if [ -n "$_SPINNER_PID" ]; then
        kill "$_SPINNER_PID" 2>/dev/null
        wait "$_SPINNER_PID" 2>/dev/null
        _SPINNER_PID=""
        printf "\033[2K\r" > "$_SPINNER_TTY" 2>/dev/null
    fi
}

# ── Ambient Prefill Craftsman Ticker ──────────────────────────
_PREFILL_TICKER_PID=""
ui_prefill_ticker_start() {
    local session_dir="${1:-}"

    # Only run animated ticker if stderr is connected to an interactive TTY terminal
    [ ! -t 2 ] && return 0
    [ "${LODGE_NONINTERACTIVE:-0}" -eq 1 ] && return 0
    [ "${_DISCORD_IN_SESSION:-0}" -eq 1 ] && return 0
    [ -n "${_DISCORD_IN_SESSION:-}" ] && return 0
    [ -n "${LODGE_REMEDIATION_SANDBOX:-}" ] && return 0
    [ -n "${_LODGE_TESTING:-}" ] && return 0

    [ -n "$_PREFILL_TICKER_PID" ] && ui_prefill_ticker_stop "$session_dir"

    local pid_file="${session_dir:+$session_dir/.prefill_ticker.pid}"
    [ -z "$pid_file" ] && pid_file="${TMPDIR:-/tmp}/.lodge_prefill_ticker_${$}"

    exec 3>&2
    (
        exec 2>/dev/null >/dev/null
        local phrases=(
            "Squaring the rough ashlar"
            "Consulting Franklin's almanac"
            "Aligning the 24-inch gauge"
            "Measuring stones with the Plumb"
            "Transmitting context across the ether"
            "Inscribing blueprints on the trestleboard"
            "Verifying joints with the Square"
            "Evaluating masonry tokens"
        )
        local i=0
        local n=${#phrases[@]}
        local frames=('▲ (👁 )' '▲ (◓ )' '▲ (👁 )' '▲ ( ◓ )' '▲ (✦👁 ✦)' '▲ ( ─ )')
        local f=0
        while [ -f "$pid_file" ]; do
            printf "\r %b%s%b %b%s...%b \033[K" "$C_GOLD" "${frames[$f]}" "$C_RESET" "$C_GRAY" "${phrases[$i]}" "$C_RESET" >&3 2>/dev/null
            f=$(( (f + 1) % 6 ))
            [ $(( f % 6 )) -eq 0 ] && i=$(( (i + 1) % n ))
            sleep 0.35
        done
        printf "\r\033[2K" >&3 2>/dev/null
        exec 3>&-
    ) &
    _PREFILL_TICKER_PID=$!
    exec 3>&-
    disown "$_PREFILL_TICKER_PID" 2>/dev/null
    echo "$_PREFILL_TICKER_PID" > "$pid_file" 2>/dev/null
}

ui_prefill_ticker_stop() {
    local session_dir="${1:-}"
    local pid_file="${session_dir:+$session_dir/.prefill_ticker.pid}"
    [ -z "$pid_file" ] && pid_file="${TMPDIR:-/tmp}/.lodge_prefill_ticker_${$}"

    local tpid="${_PREFILL_TICKER_PID:-}"
    [ -z "$tpid" ] && [ -f "$pid_file" ] && tpid=$(cat "$pid_file" 2>/dev/null)
    rm -f "$pid_file" 2>/dev/null
    _PREFILL_TICKER_PID=""
    if [ -n "$tpid" ]; then
        kill -9 "$tpid" 2>/dev/null
        wait "$tpid" 2>/dev/null
    fi
    [ -t 2 ] && printf "\r\033[2K" >&2 2>/dev/null
}

# ── Prompt ─────────────────────────────────────────────────────
ui_prompt() {
    local project="${LODGE_PROJECT:-~}"
    printf "%b%s%b %b❯%b " "$C_BLUE" "$project" "$C_RESET" "$C_LODGE" "$C_RESET"
}

# Build a readline-safe prompt string for use with read -p.
# Non-printing ANSI escapes wrapped in \001..\002 so readline
# correctly calculates visible width (prevents backspace-into-prompt
# and cursor misalignment on long input lines).
ui_prompt_string() {
    local project="${LODGE_PROJECT:-~}"
    printf '\001%b\002%s\001%b\002 \001%b\002❯\001%b\002 ' \
        "$C_BLUE" "$project" "$C_RESET" "$C_LODGE" "$C_RESET"
}

# ── Code Block Rendering ──────────────────────────────────────
ui_code_block() {
    local lang="${1:-}"
    local code="$2"
    printf " %b┌─ %s%b\n" "$C_DIM" "$lang" "$C_RESET"
    while IFS= read -r line; do
        printf " %b│%b %s\n" "$C_DIM" "$C_RESET" "$line"
    done <<< "$code"
    printf " %b└─%b\n" "$C_DIM" "$C_RESET"
}

# ── Confirmation Prompt ────────────────────────────────────────
ui_confirm() {
    local msg="$1"
    local default="${2:-y}"

    # Auto-confirm during plan execution — interactive prompts block agents
    if [ "${_LODGE_IN_TASK:-0}" -eq 1 ]; then
        ui_dim "  (auto-confirmed during task: $msg)"
        return 0
    fi

    local hint="[Y/n]"
    [ "$default" = "n" ] && hint="[y/N]"
    printf " %b%s%b %b%s%b " "$C_WHITE" "$msg" "$C_RESET" "$C_DIM" "$hint" "$C_RESET"
    read -r answer
    answer="${answer:-$default}"
    [[ "${answer,,}" == "y"* ]]
}

# ── Selection Menu ─────────────────────────────────────────────
ui_select() {
    local prompt="$1"
    shift
    local options=("$@")
    printf " %b%s%b\n" "$C_WHITE" "$prompt" "$C_RESET"
    for i in "${!options[@]}"; do
        printf "   %b[%d]%b %s\n" "$C_BLUE" $((i+1)) "$C_RESET" "${options[$i]}"
    done
    printf " %b❯%b " "$C_LODGE" "$C_RESET"
    read -r choice
    echo "$choice"
}

# ── Render LLM Response (markdown-lite) ────────────────────────
ui_render_response() {
    local text="$1"
    local outcome_class
    outcome_class=$(ui_respond_outcome_class "$text")

    if [ "$outcome_class" = "graceful_termination_due_to_constraints" ]; then
        ui_warn "Response outcome: graceful termination due to constraints"
    else
        ui_ok "Response outcome: successful completion"
    fi
    _transcript_ui respond_outcome "$outcome_class"

    local in_code=0
    local lang=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^\`\`\`(.*)$ ]]; then
            if [ "$in_code" -eq 0 ]; then
                in_code=1
                lang="${BASH_REMATCH[1]}"
                printf " %b┌─ %s%b\n" "$C_DIM" "$lang" "$C_RESET"
            else
                in_code=0
                printf " %b└─%b\n" "$C_DIM" "$C_RESET"
            fi
        elif [ "$in_code" -eq 1 ]; then
            printf " %b│%b %s\n" "$C_DIM" "$C_GREEN" "$line"
        elif [[ "$line" =~ ^#\  ]]; then
            printf "\n %b%s%b\n" "$C_BOLD" "${line#\# }" "$C_RESET"
        elif [[ "$line" =~ ^##\  ]]; then
            printf "\n %b%s%b\n" "$C_CYAN" "${line#\#\# }" "$C_RESET"
        elif [[ "$line" =~ ^-\  ]]; then
            printf " %b•%b %s\n" "$C_BLUE" "$C_RESET" "${line#- }"
        elif [ -n "$line" ]; then
            printf " %s\n" "$line"
        else
            echo ""
        fi
    done <<< "$text"
    printf "%b" "$C_RESET"
}

# ── Expand LLM escape sequences ───────────────────────────────
# LLMs emit literal \n, \t etc. in single-line output. This
# converts them to real characters for output endpoints (email,
# social, file writes).
#
# printf '%b' interprets C-style escapes:
#   \n → newline    \t → tab    \\ → literal backslash
#
# Expand literal escape sequences from LLM output.
# If text has no real newlines, use printf %b (full expansion).
# If text already has real newlines, use targeted sed to resolve
# only literal \n/\t/\\ without disturbing existing formatting.
ui_expand_escapes() {
    local text="$1"
    [ -z "$text" ] && return 0
    if [[ "$text" == *'\n'* ]] || [[ "$text" == *'\t'* ]]; then
        text=$(printf '%s' "$text" | ui_unescape_literals)
    fi
    printf '%s' "$text"
}

# ── Resolve literal \n, \t, \\ in text ────────────────────────
# Unlike ui_expand_escapes, this works on text that ALREADY has
# real newlines — it only targets literal two-character sequences
# the model wrote (e.g. backslash-n) that should have been actual
# escape characters.  Safe for mixed content.
ui_unescape_literals() {
    sed -e 's/\\\\/\x00/g' -e 's/\\n/\n/g' -e 's/\\t/\t/g' -e 's/\x00/\\/g'
}

# ── Clean path prefix ─────────────────────────────────────────
# Cleans paths to remove redundant workdir/project folder prefixes.
# E.g., if workdir=/workspace/system_shield and filepath=system_shield/main.sh,
# this strips the redundant prefix to return "main.sh".
ui_clean_path_prefix() {
    local filepath="$1"
    local workdir="$2"
    [ -z "$filepath" ] && return 0
    [ -z "$workdir" ] && { echo "$filepath"; return 0; }

    local wd_base
    wd_base=$(basename "$workdir")
    
    # Strip leading workdir basename if present
    if [[ "$filepath" == "$wd_base/"* ]]; then
        filepath="${filepath#$wd_base/}"
    elif [[ "$filepath" == "$wd_base" ]]; then
        filepath="."
    fi
    echo "$filepath"
}

ui_clean_virtual_prefix() {
    local filepath="$1"
    local cleaned="$filepath"
    while [[ "$cleaned" =~ ^(\./)?(responses|workspace|output|artifacts|tmp)(/|$) ]]; do
        if [[ "$cleaned" == *"/"* ]]; then
            cleaned="${cleaned#*/}"
        else
            cleaned="."
            break
        fi
    done
    echo "$cleaned"
}

# ── central path resolution ─────────────────────────────────────
# Resolves a relative or absolute filepath relative to workdir, global workspace, or project root fallbacks.
ui_resolve_path() {
    local filepath="$1"
    filepath=$(echo "$filepath" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    local workdir="${2:-.}"
    [ -z "$filepath" ] && { echo "${workdir:-.}"; return 0; }
    local is_write="${3:-0}"      # 0=read, 1=write
    local is_explicit="${4:-0}"   # 0=system context inspection, 1=explicit slash command (/read, /edit, /write)
    local lodge_dir="${LODGE_DIR:-$(pwd)}"
    if [ -n "$LODGE_DIR" ] && [ ! -d "$LODGE_DIR" ]; then
        if [ -d "/workspace" ]; then
            lodge_dir="/workspace"
        else
            lodge_dir="$(pwd)"
        fi
    fi

    # General Virtual Prefix Cleaning (responses/, workspace/, output/, artifacts/, tmp/)
    filepath=$(ui_clean_virtual_prefix "$filepath")

    # Truncated path prefix matching fallback (e.g. filename... from small models)
    if [[ "$filepath" == *"\.\.\."* ]] || [[ "$filepath" == *"\.\."* ]]; then
        local _trunc_prefix
        _trunc_prefix=$(echo "$filepath" | sed -E 's/\.\.+$//')
        _trunc_prefix=$(basename -- "$_trunc_prefix" 2>/dev/null)
        if [ -n "$_trunc_prefix" ] && [ "${#_trunc_prefix}" -ge 4 ]; then
            local _prefix_match
            _prefix_match=$(find "$lodge_dir/.george/workspaces" -maxdepth 5 -type f -name "${_trunc_prefix}*" 2>/dev/null | head -1)
            if [ -n "$_prefix_match" ] && [ -f "$_prefix_match" ]; then
                echo "$_prefix_match"
                return 0
            fi
        fi
    fi

    # 0. Resolve Namespaced Semantic Handles
    if [[ "$filepath" == "mem:active_task" ]]; then
        local active_slug="${AGENT_ACTIVE_TASK_SLUG:-active_report}"
        echo "$lodge_dir/.george/memories/${active_slug}.md"
        return 0
    elif [[ "$filepath" =~ ^mem:[0-9]+$ ]]; then
        local idx="${filepath#mem:}"
        local reg_file="$lodge_dir/.george/memories/registry.json"
        if [ -f "$reg_file" ] && command -v jq &>/dev/null; then
            local matched_slug
            matched_slug=$(jq -r --arg idx "$idx" '.[$idx].slug // empty' "$reg_file" 2>/dev/null)
            if [ -n "$matched_slug" ]; then
                echo "$lodge_dir/.george/memories/${matched_slug}.md"
                return 0
            fi
        fi
        echo "$lodge_dir/.george/memories/memory_${idx}.md"
        return 0
    elif [[ "$filepath" == mem:* ]]; then
        local clean_slug
        clean_slug="${filepath#mem:}"
        clean_slug="${clean_slug%.md}"
        clean_slug=$(echo "$clean_slug" | sed 's|[^a-zA-Z0-9_-]||g')
        echo "$lodge_dir/.george/memories/${clean_slug}.md"
        return 0
    fi

    # 1. Check if absolute path first (under lodge_dir, workdir, /tmp, or existing file on filesystem)
    if [[ "$filepath" == /* ]]; then
        if [[ "$filepath" == "$lodge_dir"* ]] || [[ "$filepath" == "$workdir"* ]] || [ -e "$filepath" ] || [[ "$filepath" == /tmp/* ]]; then
            # Safe absolute path
            echo "$filepath"
            return 0
        else
            # Strip leading / and treat as relative
            filepath="${filepath#/}"
        fi
    fi

    # Check if we are running in an agent task workspace or sandbox
    local is_agent_task=0
    if [[ "$workdir" != *".george/workspaces"* ]] && [ -n "${AGENT_TASK_WORKSPACE:-}" ]; then
        workdir="$AGENT_TASK_WORKSPACE"
    fi
    if [[ "$workdir" == *".george/workspaces"* ]] || [[ "$workdir" == *"/.sandboxes/"* ]] || [[ "$(pwd)" == *"/.sandboxes/"* ]]; then
        is_agent_task=1
    fi

    # Auto-route general document files (e.g. .md, .txt) that are not codebase files to memories
    if [ "$is_agent_task" -eq 1 ] && [[ "$1" != *".george/workspaces"* ]] && [[ "$1" != *".george/memories"* ]] && [[ "$1" != *".george/issues"* ]]; then
        if [[ "$filepath" == *.md ]] || [[ "$filepath" == *.txt ]]; then
            if [[ "$filepath" != "lib/"* ]] && [[ "$filepath" != "tests/"* ]] && [[ "$filepath" != "commands/"* ]] && [[ "$filepath" != "docs/"* ]] && [[ "$filepath" != *".george/issues/"* ]] && [ ! -f "$filepath" ] && [ ! -f "$lodge_dir/$filepath" ] && [ ! -f "$workdir/$filepath" ] && [ ! -f "$lodge_dir/.george/workspaces/$filepath" ]; then
                local auto_slug
                auto_slug=$(basename "$filepath" | sed -e 's/\.md$//' -e 's/\.txt$//' | sed 's|[^a-zA-Z0-9_-]||g')
                echo "$lodge_dir/.george/memories/${auto_slug}.md"
                return 0
            fi
        fi
    fi

    # If the path contains the active workspaces/memories directory segment, extract the relative part.
    # This dynamically maps absolute container paths (e.g. starting with /workspace/ or /home/blue-lodge/)
    # to the host lodge_dir by stripping the arbitrary prefix before .george/workspaces/ or .george/memories/.
    if [[ "$filepath" == *".george/workspaces/"* ]]; then
        local _ws_rel="${filepath#*.george/workspaces/}"
        if [ -e "$lodge_dir/.george/workspaces/$_ws_rel" ]; then
            echo "$lodge_dir/.george/workspaces/$_ws_rel"
            return 0
        fi
        filepath="$_ws_rel"
        # Strip any leading timestamp folder prefix (e.g. 20260722_200714/)
        filepath=$(echo "$filepath" | sed -E 's|^[0-9]{8}_[0-9]{6}/||')
    elif [[ "$filepath" == *".george/memories/"* ]]; then
        filepath=".george/memories/${filepath#*.george/memories/}"
    fi

    # 2. Expand tilde
    if declare -f tools_expand_tilde &>/dev/null; then
        filepath=$(tools_expand_tilde "$filepath")
    fi

    # 3. Explicit memories path
    if [[ "$filepath" == ".george/memories"* ]]; then
        echo "$lodge_dir/$filepath"
        return 0
    fi

    if [ "$is_agent_task" -eq 1 ]; then
        # Check if inside a sandbox
        local in_sandbox=0
        if [[ "$(pwd)" == *"/.sandboxes/"* ]] || [[ "$workdir" == *"/.sandboxes/"* ]]; then
            in_sandbox=1
        fi

        # 4. Inside a sandbox
        if [ "$in_sandbox" -eq 1 ]; then
            local _primary_root="${LODGE_ROOT:-}"
            if [ -z "$_primary_root" ] && [[ "$workdir" == *"/.sandboxes/"* ]]; then
                _primary_root="${workdir%%/.sandboxes/*}"
            fi
            [ -z "$_primary_root" ] && _primary_root="${LODGE_DIR:-$(pwd)}"

            if [ "$is_write" -eq 1 ]; then
                echo "$workdir/$filepath"
                return 0
            elif [ -e "$workdir/$filepath" ]; then
                echo "$workdir/$filepath"
                return 0
            elif [ -e "$lodge_dir/$filepath" ]; then
                echo "$lodge_dir/$filepath"
                return 0
            elif [ -e "$_primary_root/$filepath" ]; then
                echo "$_primary_root/$filepath"
                return 0
            fi
            echo "$workdir/$filepath"
            return 0
        fi

        # 5. Outside a sandbox (Relative path defaults to active task workspace or project root fallbacks)
        local global_path="$workdir/$filepath"
        if [[ "$workdir" != *".george/workspaces"* ]]; then
            global_path="$lodge_dir/.george/workspaces/$filepath"
        fi
        local project_path="$lodge_dir/$filepath"

        if [ "$is_write" -eq 1 ]; then
            # For writing, check if it is part of project folders or exists in project root
            if [[ "$filepath" == "lib/"* ]] || [[ "$filepath" == "tests/"* ]] || [[ "$filepath" == "commands/"* ]] || [[ "$filepath" == "docs/"* ]] || [ -f "$project_path" ]; then
                echo "$project_path"
            else
                # Copy-on-Write: If missing in active task workspace, check prior workspaces to initialize active copy
                if [ ! -f "$global_path" ] && [ -d "$lodge_dir/.george/workspaces" ]; then
                    local _prior_src
                    _prior_src=$(find "$lodge_dir/.george/workspaces" -maxdepth 5 -type f -name "$(basename -- "$filepath" 2>/dev/null)" ! -path "$workdir/*" 2>/dev/null | head -1)
                    if [ -n "$_prior_src" ] && [ -f "$_prior_src" ]; then
                        mkdir -p "$(dirname "$global_path")"
                        cp "$_prior_src" "$global_path" 2>/dev/null
                    fi
                fi
                echo "$global_path"
            fi
        else
            # For reading, check if it exists in active task workspace first
            if [ -e "$global_path" ]; then
                echo "$global_path"
            elif [ -e "$project_path" ]; then
                echo "$project_path"
            else
                # Copy-on-Read: Check if file exists in a prior task workspace
                local _prior_src=""
                if [ -d "$lodge_dir/.george/workspaces" ]; then
                    _prior_src=$(find "$lodge_dir/.george/workspaces" -maxdepth 5 -type f -name "$(basename -- "$filepath" 2>/dev/null)" ! -path "$workdir/*" 2>/dev/null | head -1)
                fi
                if [ -n "$_prior_src" ] && [ -f "$_prior_src" ]; then
                    # Copy-on-Read: Trigger if explicit slash command (/read, /edit), write mode, or source code file
                    if [ "$is_explicit" -eq 1 ] || [ "$is_write" -eq 1 ] || [[ "$filepath" == *.py ]] || [[ "$filepath" == *.rs ]] || [[ "$filepath" == *.sh ]] || [[ "$filepath" == *.js ]] || [[ "$filepath" == *.c ]] || [[ "$filepath" == *.cpp ]]; then
                        mkdir -p "$(dirname "$global_path")"
                        cp "$_prior_src" "$global_path" 2>/dev/null
                        echo "$global_path"
                    else
                        # Automatic context injection for reports/documents references prior file in-place
                        echo "$_prior_src"
                    fi
                else
                    # Fuzzy path resolution before defaulting (only for meaningful names, not numbers or short tokens)
                    local _base _match="" _token
                    _base=$(basename -- "$filepath" 2>/dev/null)
                    if [ -n "$_base" ] && [ "${#_base}" -ge 4 ] && ! [[ "$_base" =~ ^[0-9]+$ ]]; then
                        _match=$(find "$lodge_dir" "$workdir" -maxdepth 3 -type f -name "*${_base}*" ! -path '*/.git/*' ! -path '*/.george/memories/*' 2>/dev/null | head -1)
                        if [ -z "$_match" ]; then
                            _token=$(echo "$_base" | tr '_.-' ' ' | awk '{print $1}')
                            if [ -n "$_token" ] && [ "${#_token}" -ge 4 ] && ! [[ "$_token" =~ ^[0-9]+$ ]]; then
                                _match=$(find "$lodge_dir" "$workdir" -maxdepth 3 -type f -name "*${_token}*" ! -path '*/.git/*' ! -path '*/.george/memories/*' 2>/dev/null | head -1)
                            fi
                        fi
                    fi
                    if [ -n "$_match" ] && [ -f "$_match" ]; then
                        echo "$_match"
                    else
                        echo "$global_path" # Default to global path (file not found)
                    fi
                fi
            fi
        fi
    else
        # Standard CLI or unit test: resolve relative to workdir
        echo "$workdir/$filepath"
    fi
}

# Suggests files in workspaces when a target file is not found
ui_suggest_workspaces_tree() {
    local rec_mode="${AGENT_FILE_RECOVERY:-auto}"
    [ "$rec_mode" = "off" ] && return 0

    ui_info "Workspaces file tree (up to depth 4):"
    local f
    while IFS= read -r f || [ -n "$f" ]; do
        if [ -n "$f" ]; then
            local clean_f
            clean_f=$(ui_clean_path_prefix "$f" "${LODGE_DIR:-.}")
            ui_info "  - $clean_f"
        fi
    done < <(find "${LODGE_DIR:-.}/.george/workspaces" -maxdepth 4 -type f 2>/dev/null | sort | head -n 30)
}

# ── Interactive Operator Communication ─────────────────────────
# Prompts the operator directly via /dev/tty and captures their response.
# Used by /ask and the native ask_operator tool.
ui_ask_operator() {
    local question="$1"
    local tty=""
    if [ -z "${_LODGE_TESTING:-}" ] && { [ -t 0 ] || [ -n "${FORCE_INTERACTIVE:-}" ]; }; then
        if { true >/dev/tty; } 2>/dev/null; then
            tty="/dev/tty"
        fi
    fi

    local banner="╔════════════════════════════════════════════════════════════════╗\n║  🏛️  GEORGE REPL: AGENT INTERACTIVE SCOPING & PLANNING         ║\n╚════════════════════════════════════════════════════════════════╝"

    if [ -n "$tty" ]; then
        echo -e "\n${C_BOLD}${C_CYAN}${banner}${C_RESET}\n" > "$tty"
        printf "  %bAgent Question:%b %s\n" "$C_YELLOW" "$C_RESET" "$question" > "$tty"
        echo "" > "$tty"
        printf "  %bGeorge/Operator Answer > %b" "$C_BOLD" "$C_RESET" > "$tty"
        local answer=""
        read -t "${UI_INPUT_TIMEOUT:-60}" -r answer < "$tty" 2>/dev/null || read -t "${UI_INPUT_TIMEOUT:-60}" -r answer 2>/dev/null || true
    else
        echo -e "\n${C_BOLD}${C_CYAN}${banner}${C_RESET}\n" >&2
        printf "  %bAgent Question:%b %s\n" "$C_YELLOW" "$C_RESET" "$question" >&2
        echo "" >&2
        printf "  %bGeorge/Operator Answer > %b" "$C_BOLD" "$C_RESET" >&2
        local answer=""
        read -t 2 -r answer 2>/dev/null || true
    fi

    if [ -z "$answer" ]; then
        answer="(no answer provided)"
    fi

    # Log interactive conversation to transcript for full audit provenance
    if declare -f transcript_log &>/dev/null; then
        transcript_log "operator_interaction" "Question: $question"
    fi
    if declare -f transcript_log_block &>/dev/null; then
        transcript_log_block "operator_response" "$answer"
    fi

    echo "$answer"
}

