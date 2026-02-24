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
    local _dispatch_ts
    _dispatch_ts=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Parse: /command [args...]
    local cmd
    cmd=$(echo "$input" | awk '{print $1}' | sed 's|^/||')
    local args
    args=$(echo "$input" | sed 's|^/[^ ]* *||')

    # Strip surrounding quotes from args — LLM wraps arguments in shell-style
    # quotes like /init python "pid loop tuning assistant" but slash commands
    # don't use shell parsing so the quotes come through literally.
    # Only strip outer wrapping quotes when entire args is quoted.
    if [[ "$args" =~ ^\"(.*)\"$ ]]; then
        args="${BASH_REMATCH[1]}"
    elif [[ "$args" =~ ^\'(.*)\'$ ]]; then
        args="${BASH_REMATCH[1]}"
    fi
    
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
        local _rc=$?
        local _done_ts
        _done_ts=$(date '+%Y-%m-%d %H:%M:%S')
        if [ $_rc -ne 0 ]; then
            ui_err "[$_done_ts] /$cmd failed (exit $_rc)" 2>/dev/null
        fi
        return $_rc
    fi
    
    # Check commands directory for scripts
    local script="$LODGE_COMMANDS_DIR/${cmd}.sh"
    if [ -f "$script" ]; then
        source "$script"
        "cmd_${cmd}" "$args" "$workdir"
        local _rc=$?
        local _done_ts
        _done_ts=$(date '+%Y-%m-%d %H:%M:%S')
        if [ $_rc -ne 0 ]; then
            ui_err "[$_done_ts] /$cmd failed (exit $_rc)" 2>/dev/null
        fi
        return $_rc
    fi
    
    local _fail_ts
    _fail_ts=$(date '+%Y-%m-%d %H:%M:%S')
    ui_err "[$_fail_ts] Unknown command: /$cmd" 2>/dev/null
    return 127  # Not found — distinct from command-failed (1)
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

# ── Service availability check (~50 tokens) ───────────────────
# Quick status of which external services are actually configured.
# Injected into strategist/router prompts so the model avoids
# choosing unconfigured services (e.g. /email when email isn't set up).
commands_services_status() {
    local _configured="" _unconfigured=""
    if declare -f api_get_key &>/dev/null; then
        api_get_key "DISCORD_BOT_TOKEN" &>/dev/null && _configured="${_configured}discord," || _unconfigured="${_unconfigured}discord,"
        api_get_key "DISCORD_WEBHOOK_URL" &>/dev/null && _configured="${_configured}discord-webhook,"
        api_get_key "TELEGRAM_BOT_TOKEN" &>/dev/null && _configured="${_configured}telegram," || _unconfigured="${_unconfigured}telegram,"
        api_get_key "X_BEARER_TOKEN" &>/dev/null && _configured="${_configured}x/twitter," || _unconfigured="${_unconfigured}x/twitter,"
        api_get_key "MASTODON_ACCESS_TOKEN" &>/dev/null && _configured="${_configured}mastodon," || _unconfigured="${_unconfigured}mastodon,"
        api_get_key "BLUESKY_APP_PASSWORD" &>/dev/null && _configured="${_configured}bluesky," || _unconfigured="${_unconfigured}bluesky,"
        api_get_key "SERPER_API_KEY" &>/dev/null && _configured="${_configured}web-search," || _unconfigured="${_unconfigured}serper,"
        # Email check: look for provider config
        local _email_provider
        _email_provider=$(api_get_key "EMAIL_PROVIDER" 2>/dev/null)
        [ -n "$_email_provider" ] && _configured="${_configured}email," || _unconfigured="${_unconfigured}email,"
    fi
    # Strip trailing commas
    _configured="${_configured%,}"
    _unconfigured="${_unconfigured%,}"
    echo "CONFIGURED: ${_configured:-none}"
    echo "NOT CONFIGURED: ${_unconfigured:-unknown}"
}

# ── Lean plan catalog (~400 tokens) ────────────────────────────
# Minimal command reference for planning. One line per command,
# no examples, no sub-variants. George uses /recall to look up
# exact syntax during step execution.
commands_catalog_plan() {
    cat << 'PLANCAT'
--- COMMANDS (use ONLY these — /recall <cmd> for syntax) ---
NOTE: Do NOT quote arguments. Slash commands parse by spaces, not shell quoting.
/ask <question>      — Quick answer (no plan needed)
/init <name> <lang>  — Scaffold project (name=no_spaces, lang: rust, python, shell, etc.)
/recall <query>      — Search knowledge base
/save <file> <text>  — Save content to file
/write <file> <text> — Write/overwrite a file
/download <url> [dest] — Download a URL
/sandbox new <name> [type] — Create sandbox (ONLY for building code projects)
/sandbox build|test|run|cd|rm <name> — Sandbox operations
/sandbox clone <url> [name] — Clone repo into sandbox
/clone <url>         — Clone and setup a repo
/build [release]     — Build project
/test [args]         — Run tests
/fix [error]         — Diagnose and fix
/commit [msg]        — AI commit message + commit
/push                — Push to GitHub
/web search <query>  — Web search
/github search <q>   — Find GitHub repos
/journal write <text> — Write to journal
/social post discord <channel> <text> — Post to Discord channel (no quotes needed)
/social post telegram <text>  — Post to Telegram
/social post x <text>        — Post to X/Twitter
/social post <text>            — Post to all configured platforms
/pgp sign <msg>      — PGP-sign a message
/email send <to> <subj> <body> — Send email (ONLY for actual email, not social posts)
/phone               — Phone dashboard
/secret set|get <k>  — Encrypted secrets
/slash create <name> <desc> — Create custom command
/vitals              — System dashboard
/soul [on|off]       — Toggle full personality injection

RULES:
- Slash commands run directly — do NOT use /sandbox to run slash commands
- To post to Discord/Telegram/X, use /social (not /email)
- /email is ONLY for actual email addresses, NEVER for social platforms
- Check SERVICES section below for what is actually configured

MEMORY LOOP — How to read, remember, and respond:
  1. /social discord read <channel>  ← read messages
  2. /journal write "<summary>"      ← save to living memory
  3. /recall <topic>                 ← retrieve when needed
  Use this loop for ANY external input: socials, web, conversations.
  Never web-search for info that came from a social channel — read it.
PLANCAT

    # Inject live service configuration status
    if declare -f commands_services_status &>/dev/null; then
        echo ""
        commands_services_status
    fi

    # Append custom slash commands if any exist
    if declare -f slash_catalog &>/dev/null; then
        slash_catalog
    fi
}

# ── Full command catalog for LLM injection ─────────────────────
# Returns the detailed command reference with syntax and examples.
# Used in task/step execution mode where George needs exact syntax.
commands_catalog() {
    local _catalog_ts
    _catalog_ts=$(date '+%Y-%m-%d %H:%M:%S %Z')
    cat << CATALOG
--- YOUR WORKING COMMANDS ---
You have these slash commands as tools. USE THEM in your plans and steps.
To invoke: output a line starting with / (e.g., /recall docker setup).

CURRENT DATE/TIME (from real-time clock): $_catalog_ts
ALWAYS use this timestamp for any date references. NEVER make up a date.

RULES — read these EVERY time:
1. ONLY use commands listed below. Do NOT invent commands that are not in this list.
2. Before using a command, use /recall <command name> to check its exact syntax.
3. If you need a command that is NOT listed, use /slash create <name> <description> to create it first.
4. Never guess at command syntax — look it up with /recall first.

/plan <task>         — Plan a task (no execution)
/ask <question>      — Quick question
/init <name> <lang>  — Scaffold a new project (types: rust, python, rl, data, automation, notebook, shell)
/recall <query>      — Search your knowledge base (docs, soul, journal)
/save <file> <content> — Save content to a file (creates parent dirs)
/write <file> <content> — Write content to a file (create or overwrite)
/download <url|path> [dest] — Download a URL or copy a local file
/social post <text>  — Post to all configured social platforms
/social <platform> <action> — X/Mastodon/Bluesky/Discord/Telegram
/social discord send <text> — Send to Discord via webhook
/social discord send <channel_id> <text> — Send to a specific Discord channel via bot
/social discord read <channel_id> — Read recent messages from a Discord channel
/pgp sign <msg>      — PGP-sign a message for authenticity
/pgp signpost <msg>  — Sign and post to social media
/pgp export          — Export your public key
/sandbox list               — List all sandboxes (type, size, last-used, events)
/sandbox new <name> [type]  — Create sandbox (types: rust, python, shell)
/sandbox build <name>       — Build project in sandbox
/sandbox test <name>        — Run tests in sandbox
/sandbox run <name> <cmd>   — Run arbitrary command in sandbox
/sandbox status <name>      — Detailed sandbox info + recent activity
/sandbox journal [n]        — Show last N sandbox journal entries
/sandbox rm <name>          — Delete a sandbox
/sandbox clone <url> [name] — Clone repo into a new sandbox
/sandbox cd <name>          — Switch working directory into sandbox
Examples:
  /sandbox new my-api rust       ← create a Rust sandbox
  /sandbox run my-api cargo test  ← run cargo test inside it
  /sandbox run my-api cargo add serde --features derive  ← add a Rust crate
  /sandbox new my-app python     ← create a Python sandbox
  /sandbox run my-app uv add requests  ← add a Python package (uv)
  /sandbox run my-app pip install flask ← add a Python package (pip)
  /sandbox build my-api           ← build using detected toolchain
  /sandbox test my-api            ← test using detected toolchain
  /sandbox list                   ← see what sandboxes exist
  /sandbox status my-api          ← detailed info + journal
/container create <distro> — Create proot-distro container
/container enter <name>    — Enter a container
/api keys set <K> <V> — Set an API key
/api keys list        — Show configured keys
/secret set <k> <v>   — Store encrypted secret
/secret get <k>       — Retrieve a secret
/web search <query>   — Search the web
/web fetch <url>      — Fetch a URL
/github search <query> — Find real GitHub repos by keyword (returns owner/repo, stars, description)
/github check <owner/repo> — Verify a GitHub repo exists before cloning
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
/email setup [provider] — Configure email (protonmail/zoho/tuta/disposable)
/email send <to> <subj> <body> — Send an email
/email inbox [count]   — Check inbox
/email status          — Show email + SSH configuration
/email address         — Show George's email address
/email ssh-keygen      — Generate SSH key for George
/email github-setup    — Full GitHub setup (email + SSH + git identity)
/email github-test     — Test SSH connection to GitHub
/git setup             — Full auto-setup (identity + SSH + GPG + GitHub)
/git status            — Show git configuration overview
/git identity [name] [email] — Set/show git user identity
/git ssh-keygen        — Generate SSH key + write persistent config
/git ssh-config        — Write persistent SSH config for GitHub
/git sign [off]        — Enable/disable GPG commit signing
/git remote [name] <url> — Add/update a git remote (auto HTTPS→SSH)
/git test              — Test SSH connection to GitHub
/git pubkey            — Show SSH public key
/git gpg-pub           — Show GPG public key for GitHub
/cleanup               — Show what George has created (file inventory)
/cleanup selective     — Interactively choose what to remove
/cleanup all           — Remove ALL George data (requires YES)
/backup local          — Quick file backup of identity & memory
/backup restore [name] — Restore from a backup
/backup list           — Show all backups
/backup status         — Show backup system status
/backup git save       — Commit current state to backup repo
/backup github         — Save + push to GitHub
/build [release]       — Build the project (reads CLAUDE.md ## Build)
/test [args]           — Run tests (reads CLAUDE.md ## Test)
/commit [msg]          — Generate AI commit message and commit
/fix [error]           — Diagnose and fix errors
/clone <url>           — Clone and setup a repository
/push                  — Push to GitHub
/slash                 — List your custom commands
/slash create <name> <desc> — Create a new custom command (LLM-assisted)
/slash <name> [args]   — Run a custom command you created
/slash test <name>     — Test a custom command
/vitals                — System vitals dashboard (disk, RAM, battery, WiFi, cell)
/vitals context        — One-line vitals for LLM context injection
/files                — List workspace files
/read <file>          — Read a file
/status               — Show agent status
/memory               — Show CLAUDE.md
/soul [on|off]        — Toggle full personality injection (on=full soul.md, off=Practical Craft only)
/think [on|off|bright|dim|hide] — Toggle thinking mode
/help [command]       — Show help for a command

── MEMORY LOOP (Read → Remember → Respond) ──────────────────
When information comes from an external source (social media, web, email),
you MUST capture it into persistent memory before responding. Do NOT rely
on the context window alone — it will be lost next session.

Pattern:
  1. READ    — /social discord read general     ← read the source
  2. INGEST  — /journal write "Key fact: ..."   ← save to journal (living memory)
             — /ingest add /tmp/data.txt label  ← or index a file into recall
  3. RECALL  — /recall <topic>                  ← retrieve later when needed
  4. RESPOND — /social discord post general "reply"  ← respond with knowledge

Examples:
  Brother asks "what did they say on Discord?":
    1. /social discord read general
    2. /journal write "Discord update: <summary of messages>"
    3. Answer the Brother using what you just read and saved

  Brother asks you to monitor and reply:
    1. /social discord read general
    2. /journal write "Conversation context: <key points>"
    3. /social discord post general "<your reply based on what you read>"

  WRONG: /web search "what did discord say" ← NEVER do this. Read the source.
──────────────────────────────────────────────────────────────

If a command you need is NOT listed above, create it:
  /slash create <name> <description>
Then use it: /slash <name> [args]
CATALOG

    # Append custom slash commands if any exist
    if declare -f slash_catalog &>/dev/null; then
        slash_catalog
    fi
}
