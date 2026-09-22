#!/bin/bash
# ── George: Centralized Non-Intrusive Terminal Popup Launcher ────────
# Provides seamless companion terminal popups (Windows Terminal / WSL)
# configured by default to launch minimized to the tray / taskbar without
# stealing keyboard focus or interrupting the operator's active window.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"

# Checks if GUI popups can be displayed in the current environment
popup_is_gui_available() {
    # Check if disabled by operator configuration
    if [ "${TERMINAL_POPUP_ENABLED:-1}" -ne 1 ]; then
        return 1
    fi

    # Verify wt.exe is available and we are in an interactive WSL desktop session (not headless SSH)
    if [ -n "${WSL_DISTRO_NAME:-}" ] && command -v wt.exe &>/dev/null; then
        if [ -z "${SSH_CONNECTION:-}" ] && [ -z "${SSH_CLIENT:-}" ]; then
            return 0
        fi
    fi
    return 1
}

# Launches a companion terminal popup
# Usage: popup_terminal_launch "Title" "Size" [command_args...]
# Examples:
#   popup_terminal_launch "George Autonomic Sentinel" "85,22" bash ./scripts/cron_visual_sweep.sh all 1
#   popup_terminal_launch "George Research HUD" "110,32" bash ./scripts/research_live_monitor.sh "topic" "slug" "/path/to/sandbox"
popup_terminal_launch() {
    local title="${1:-George Terminal}"
    local size="${2:-110,32}"
    shift 2
    local cmd=("$@")

    if ! popup_is_gui_available; then
        return 1
    fi

    local distro="${WSL_DISTRO_NAME:-ubuntu-local}"
    local minimized="${TERMINAL_POPUP_MINIMIZED:-1}"
    local launcher_exe="$LODGE_DIR/bin/wt_launch_minimized.exe"

    if [ "$minimized" -eq 1 ]; then
        if [ ! -x "$launcher_exe" ] && [ -f "$LODGE_DIR/bin/wt_launch_minimized.cs" ]; then
            local csc_bin="/mnt/c/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe"
            if [ -x "$csc_bin" ]; then
                "$csc_bin" /nologo /target:winexe /out:"$(wslpath -w "$launcher_exe")" "$(wslpath -w "$LODGE_DIR/bin/wt_launch_minimized.cs")" >/dev/null 2>&1 || true
                chmod +x "$launcher_exe" 2>/dev/null || true
            fi
        fi

        if [ -x "$launcher_exe" ]; then
            # Launch via native minimized helper: preserves active foreground window and minimizes new terminal
            "$launcher_exe" -w new --size "$size" \
                nt --title "$title" \
                wsl.exe -d "$distro" --cd "$LODGE_DIR" \
                "${cmd[@]}" >/dev/null 2>&1 &
            return 0
        fi
    fi

    # Fallback to standard wt.exe launch
    wt.exe -w new --size "$size" \
        nt --title "$title" \
        wsl.exe -d "$distro" --cd "$LODGE_DIR" \
        "${cmd[@]}" >/dev/null 2>&1 &
    return 0
}
