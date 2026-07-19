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
ui_think() { printf " %b%s %b%s%b\n" "$C_PURPLE" "$SYM_THINK" "$C_GRAY" "$1" "$C_RESET"; _transcript_ui think "$1"; }
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
    _transcript_ui header "$title${sub:+ — $sub}"
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
        local frames=('◐' '◓' '◑' '◒')
        local i=0
        while true; do
            printf "\r %b%s %b%s...%b " "$C_PURPLE" "${frames[$i]}" "$C_GRAY" "$msg" "$C_RESET" > "$_tty" 2>/dev/null
            i=$(( (i + 1) % 4 ))
            sleep 0.3
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

# ── central path resolution ─────────────────────────────────────
# Resolves a relative or absolute filepath relative to workdir, global workspace, or project root fallbacks.
ui_resolve_path() {
    local filepath="$1"
    local workdir="${2:-.}"
    local is_write="${3:-0}" # 0=read, 1=write
    local lodge_dir="${LODGE_DIR:-$(pwd)}"

    # If the path contains the active workspaces directory segment, extract the relative part.
    # This dynamically maps absolute container paths (e.g. starting with /workspace/ or /home/blue-lodge/)
    # to the host lodge_dir by stripping the arbitrary prefix before .george/workspaces/.
    if [[ "$filepath" == *".george/workspaces/"* ]]; then
        filepath=".george/workspaces/${filepath#*.george/workspaces/}"
    fi

    # Check if we are running in an agent task workspace
    local is_agent_task=0
    if [[ "$workdir" == *".george/workspaces"* ]]; then
        is_agent_task=1
    fi

    # Check if absolute path
    if [[ "$filepath" == /* ]]; then
        if [[ "$filepath" == "$lodge_dir"* ]] || [[ "$filepath" == "$workdir"* ]]; then
            # Safe absolute path (under lodge_dir or workdir)
            echo "$filepath"
            return 0
        else
            # Strip leading / and treat as relative
            filepath="${filepath#/}"
        fi
    fi

    # 2. Expand tilde
    if declare -f tools_expand_tilde &>/dev/null; then
        filepath=$(tools_expand_tilde "$filepath")
    fi

    # 3. Explicit workspaces path
    if [[ "$filepath" == ".george/workspaces"* ]]; then
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
            echo "$workdir/$filepath"
            return 0
        fi

        # 5. Outside a sandbox (Relative path defaults to global workspace or project root fallbacks)
        local global_path="$lodge_dir/.george/workspaces/$filepath"
        local project_path="$lodge_dir/$filepath"

        if [ "$is_write" -eq 1 ]; then
            # For writing, check if it is part of project folders or exists in project root
            if [[ "$filepath" == "lib/"* ]] || [[ "$filepath" == "tests/"* ]] || [[ "$filepath" == "commands/"* ]] || [[ "$filepath" == "docs/"* ]] || [ -f "$project_path" ]; then
                echo "$project_path"
            else
                echo "$global_path"
            fi
        else
            # For reading, check if it exists in the global workspace first
            if [ -e "$global_path" ]; then
                echo "$global_path"
            elif [ -e "$project_path" ]; then
                echo "$project_path"
            else
                echo "$global_path" # Default to global path (file not found)
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
