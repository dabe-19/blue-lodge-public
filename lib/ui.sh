#!/bin/bash
# ── George: UI Rendering ──────────────────────────────────
# Lightweight TUI components using ANSI escape codes.
# No ncurses, no Python — pure bash for mobile.

# ── Colors ─────────────────────────────────────────────────────
export C_RESET='\033[0m'
export C_BOLD='\033[1m'
export C_DIM='\033[2m'
export C_ITALIC='\033[3m'
export C_BLUE='\033[38;5;75m'
export C_CYAN='\033[38;5;117m'
export C_GREEN='\033[38;5;114m'
export C_YELLOW='\033[38;5;221m'
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

# ── Core Print Functions ───────────────────────────────────────
ui_print() { printf "%b\n" "$1"; }
ui_info()  { printf " %b%s %b%s%b\n" "$C_BLUE" "$SYM_DOT" "$C_WHITE" "$1" "$C_RESET"; }
ui_ok()    { printf " %b%s %b%s%b\n" "$C_GREEN" "$SYM_CHECK" "$C_WHITE" "$1" "$C_RESET"; }
ui_warn()  { printf " %b%s %b%s%b\n" "$C_YELLOW" "$SYM_WARN" "$C_WHITE" "$1" "$C_RESET"; }
ui_err()   { printf " %b%s %b%s%b\n" "$C_RED" "$SYM_CROSS" "$C_WHITE" "$1" "$C_RESET"; }
ui_step()  { printf " %b%s %b%s%b\n" "$C_CYAN" "$SYM_ARROW" "$C_WHITE" "$1" "$C_RESET"; }
ui_think() { printf " %b%s %b%s%b\n" "$C_PURPLE" "$SYM_THINK" "$C_GRAY" "$1" "$C_RESET"; }
ui_dim()   { printf " %b  %s%b\n" "$C_DIM" "$1" "$C_RESET"; }
ui_code()  { printf " %b  %s%b\n" "$C_GRAY" "$1" "$C_RESET"; }

# ── Structured Output ──────────────────────────────────────────
ui_header() {
    local title="$1"
    local sub="${2:-}"
    local w=48
    local pad_title=$(( (w - ${#title} - 4) / 2 ))
    echo ""
    printf " %b╭" "$C_LODGE"
    printf '─%.0s' $(seq 1 $w)
    printf "╮%b\n" "$C_RESET"
    printf " %b│%b" "$C_LODGE" "$C_RESET"
    printf "%*s" $pad_title ""
    printf "%b%s %s%b" "$C_BOLD" "$SYM_LODGE" "$title" "$C_RESET"
    printf "%*s" $(( w - pad_title - ${#title} - 3 )) ""
    printf "%b│%b\n" "$C_LODGE" "$C_RESET"
    if [ -n "$sub" ]; then
        local pad_sub=$(( (w - ${#sub}) / 2 ))
        printf " %b│%b" "$C_LODGE" "$C_RESET"
        printf "%*s" $pad_sub ""
        printf "%b%s%b" "$C_DIM" "$sub" "$C_RESET"
        printf "%*s" $(( w - pad_sub - ${#sub} )) ""
        printf "%b│%b\n" "$C_LODGE" "$C_RESET"
    fi
    printf " %b╰" "$C_LODGE"
    printf '─%.0s' $(seq 1 $w)
    printf "╯%b\n" "$C_RESET"
    echo ""
}

ui_section() {
    local title="$1"
    echo ""
    printf " %b── %s %b" "$C_LODGE" "$title" "$C_DIM"
    printf '─%.0s' $(seq 1 $(( 40 - ${#title} )))
    printf "%b\n" "$C_RESET"
}

ui_divider() {
    printf " %b" "$C_DIM"
    printf '─%.0s' $(seq 1 48)
    printf "%b\n" "$C_RESET"
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
ui_spinner_start() {
    local msg="${1:-Thinking}"
    (
        local frames=('◐' '◓' '◑' '◒')
        local i=0
        while true; do
            printf "\r %b%s %b%s...%b " "$C_PURPLE" "${frames[$i]}" "$C_GRAY" "$msg" "$C_RESET" > /dev/tty 2>/dev/null
            i=$(( (i + 1) % 4 ))
            sleep 0.2
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
        printf "\r%*s\r" 60 "" > /dev/tty 2>/dev/null  # clear line on tty
    fi
}

# ── Prompt ─────────────────────────────────────────────────────
ui_prompt() {
    local project="${LODGE_PROJECT:-~}"
    printf "%b%s%b %b❯%b " "$C_BLUE" "$project" "$C_RESET" "$C_LODGE" "$C_RESET"
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
