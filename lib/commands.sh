#!/bin/bash
# ── George: Slash Command Dispatcher ───────────────────────
# Registers and dispatches /commands similar to Claude Code.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
LODGE_COMMANDS_DIR="$LODGE_DIR/commands"

# ── Registry ───────────────────────────────────────────────────
declare -A CMD_REGISTRY
declare -A CMD_DESC

commands_register() {
    local name="$1"
    local desc="$2"
    local handler="$3"
    CMD_REGISTRY["$name"]="$handler"
    CMD_DESC["$name"]="$desc"
}

# ── Dispatch ───────────────────────────────────────────────────
commands_dispatch() {
    local input="$1"
    local workdir="${2:-.}"
    
    # Parse: /command [args...]
    local cmd
    cmd=$(echo "$input" | awk '{print $1}' | sed 's|^/||')
    local args
    args=$(echo "$input" | sed 's|^/[^ ]* *||')
    
    # Check built-in commands first
    case "$cmd" in
        help)
            if [ -n "$args" ] && [ "$args" != "$input" ]; then
                commands_help_topic "$args"
            else
                commands_help
            fi
            return 0 ;;
        quit|exit|q) return 99 ;;
    esac
    
    # Check registry
    if [ -n "${CMD_REGISTRY[$cmd]:-}" ]; then
        "${CMD_REGISTRY[$cmd]}" "$args" "$workdir"
        return $?
    fi
    
    # Check commands directory for scripts
    local script="$LODGE_COMMANDS_DIR/${cmd}.sh"
    if [ -f "$script" ]; then
        source "$script"
        "cmd_${cmd}" "$args" "$workdir"
        return $?
    fi
    
    return 1  # Not a command
}

# ── Is this a slash command? ───────────────────────────────────
commands_is_command() {
    local input="$1"
    [[ "$input" == /* ]]
}

# ── Show help ──────────────────────────────────────────────────
commands_help() {
    source "$LODGE_DIR/lib/ui.sh"
    
    ui_section "Slash Commands"
    
    # Built-in
    printf "  %b/help%b       Show this help\n" "$C_CYAN" "$C_RESET"
    printf "  %b/quit%b       Exit George\n" "$C_CYAN" "$C_RESET"
    echo ""
    
    # Registered — iterate safely over associative array keys
    local _cmd_names
    _cmd_names=$(for _k in "${!CMD_REGISTRY[@]}"; do echo "$_k"; done | sort)
    for name in $_cmd_names; do
        [ -z "$name" ] && continue
        printf "  %b/%-10s%b %s\n" "$C_CYAN" "$name" "$C_RESET" "${CMD_DESC[$name]:-}"
    done
    
    # Script-based
    if [ -d "$LODGE_COMMANDS_DIR" ]; then
        for script in "$LODGE_COMMANDS_DIR"/*.sh; do
            [ -f "$script" ] || continue
            local name
            name=$(basename "$script" .sh)
            if [ -z "${CMD_REGISTRY[$name]:-}" ]; then
                local desc
                desc=$(head -3 "$script" | grep '# DESC:' | sed 's/.*DESC: *//')
                printf "  %b/%-10s%b %s\n" "$C_CYAN" "$name" "$C_RESET" "${desc:-Custom command}"
            fi
        done
    fi
    echo ""
}

# ── Load all command scripts ───────────────────────────────────
commands_load_all() {
    if [ ! -d "$LODGE_COMMANDS_DIR" ]; then return; fi
    
    for script in "$LODGE_COMMANDS_DIR"/*.sh; do
        [ -f "$script" ] || continue
        source "$script"
    done
}

# ── Per-command detailed help ──────────────────────────────────
# Delegates to the command's own handler with no args (which shows help)
# or shows the description if that's all we have.
commands_help_topic() {
    local topic="$1"
    # Strip leading / if present
    topic="${topic#/}"

    if [ -n "${CMD_REGISTRY[$topic]:-}" ]; then
        # Dispatch with empty args — most handlers show help on empty args
        "${CMD_REGISTRY[$topic]}" "" "."
    elif [ -f "$LODGE_COMMANDS_DIR/${topic}.sh" ]; then
        source "$LODGE_COMMANDS_DIR/${topic}.sh"
        "cmd_${topic}" "" "."
    else
        ui_err "Unknown command: /$topic"
        ui_dim "Run /help to see all commands"
    fi
}

# ── Compact command catalog for LLM injection ─────────────────
# Returns a token-efficient summary (~150-200 tokens) of all
# available slash commands that George can use as working tools.
# This is injected into system prompts so George knows his tools.
commands_catalog() {
    cat << 'CATALOG'
--- YOUR WORKING COMMANDS ---
You have these slash commands as tools. USE THEM in your plans and steps.
To invoke: output a line starting with / (e.g., /recall docker setup).

/plan <task>         — Plan a task (no execution)
/ask <question>      — Quick question
/init <name> <lang>  — Scaffold a new project
/recall <query>      — Search your knowledge base (docs, soul, journal)
/social post <text>  — Post to all configured social platforms
/social <platform> <action> — X/Mastodon/Bluesky/Discord/Telegram
/pgp sign <msg>      — PGP-sign a message for authenticity
/pgp signpost <msg>  — Sign and post to social media
/pgp export          — Export your public key
/sandbox create <n>  — Create isolated sandbox
/sandbox run <n> <cmd> — Run command in sandbox
/container create <distro> — Create proot-distro container
/container enter <name>    — Enter a container
/api keys set <K> <V> — Set an API key
/api keys list        — Show configured keys
/secret set <k> <v>   — Store encrypted secret
/secret get <k>       — Retrieve a secret
/web search <query>   — Search the web
/web fetch <url>      — Fetch a URL
/journal write <text> — Write to your journal
/journal read         — Read recent journal entries
/wallet <coin> <action> — Crypto wallet operations
/gsuite gmail|drive|docs — Google Workspace
/phone                 — Full phone dashboard (battery, carrier, WiFi, GPS)
/phone location        — Get current GPS/network location
/phone where           — One-line location context
/phone sms [inbox|sent] — Read text messages
/phone sms send <num> <msg> — Send a text message
/phone calls           — Recent call log
/phone telephony       — Carrier, SIM, data state
/phone wifi            — WiFi connection info
/backup save          — Backup your identity
/slash                 — List your custom commands
/slash create <name> <desc> — Create a new custom command (LLM-assisted)
/slash <name> [args]   — Run a custom command you created
/slash test <name>     — Test a custom command
/files                — List workspace files
/read <file>          — Read a file
/status               — Show agent status
/memory               — Show CLAUDE.md

TIP: If unsure how a command works, use /recall <command name> to look it up.
All command docs are indexed in your knowledge base.
CATALOG

    # Append custom slash commands if any exist
    if declare -f slash_catalog &>/dev/null; then
        slash_catalog
    fi
}
