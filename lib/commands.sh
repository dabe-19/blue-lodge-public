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

    # Fix missing spaces in LLM output — file extensions, code fences, asterisks.
    if declare -f tools_fix_llm_spacing &>/dev/null; then
        args=$(tools_fix_llm_spacing "$args")
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
        # Mastodon: check multi-instance registry first, then legacy key
        local _masto_ok=0
        if declare -f mastodon_instance_list &>/dev/null; then
            local _inst_count
            _inst_count=$(mastodon_instance_list 2>/dev/null | grep -c "^" || true)
            [ "${_inst_count:-0}" -gt 0 ] && _masto_ok=1
        fi
        if [ "$_masto_ok" -eq 0 ]; then
            api_get_key "MASTODON_ACCESS_TOKEN" &>/dev/null && _masto_ok=1
        fi
        [ "$_masto_ok" -eq 1 ] && _configured="${_configured}mastodon," || _unconfigured="${_unconfigured}mastodon,"
        api_get_key "BLUESKY_APP_PASSWORD" &>/dev/null && _configured="${_configured}bluesky," || _unconfigured="${_unconfigured}bluesky,"
        api_get_key "SERPER_API_KEY" &>/dev/null && _configured="${_configured}web-search," || _unconfigured="${_unconfigured}serper,"
        # Email check: look for per-provider configs or legacy config
        local _email_found=0
        if declare -f email_list_configured &>/dev/null; then
            local _eprovs
            _eprovs=$(email_list_configured 2>/dev/null)
            [ -n "$_eprovs" ] && _email_found=1
        fi
        if [ "$_email_found" -eq 0 ]; then
            local _email_provider
            _email_provider=$(api_get_key "EMAIL_PROVIDER" 2>/dev/null)
            [ -n "$_email_provider" ] && _email_found=1
        fi
        [ "$_email_found" -eq 1 ] && _configured="${_configured}email," || _unconfigured="${_unconfigured}email,"
    fi
    # Strip trailing commas
    _configured="${_configured%,}"
    _unconfigured="${_unconfigured%,}"
    echo "CONFIGURED: ${_configured:-none}"
    echo "NOT CONFIGURED: ${_unconfigured:-unknown}"
}

# ── Plan catalog (now delegates to full catalog) ──────────────
# Previously a lean ~400-token summary; now returns the full catalog
# since context windows have been increased. Kept as a wrapper so
# existing call sites and tests continue to work.
commands_catalog_plan() {
    commands_catalog
}

# ── Full command catalog for LLM injection ─────────────────────
# Returns the detailed command reference with syntax and examples.
# Injected during planning, routing, guided retry, and execution.
commands_catalog() {
    local _catalog_ts
    _catalog_ts=$(date '+%Y-%m-%d %H:%M:%S %Z')
    printf '# SYSTEM CAPABILITIES & TOOLS\nTime: %s.\n' "$_catalog_ts"
    cat << 'CATALOG'
Invoke tools using `/`. Do NOT quote arguments (parsed by whitespace). 
Never guess syntax; use `/recall <cmd>`. If a tool is missing, use `/slash create <name> <desc>`.

## CORE WORKFLOW (Read → Gather → Ingest → Respond)
1. **READ:** Check memory (`/recall <topic>`) or source (`/social discord read`).
2. **GATHER:** If missing info, autonomously find it (`/web search`, `/github search`, `/secret get`). *Never give up due to missing info—find it first.*
3. **INGEST:** Save new facts to memory (`/journal write <fact>`).
4. **RESPOND:** Execute final action.

## 1. PROJECT & CODE
/init <name> <lang>  — Setup project (langs: rust, python, rl, data, shell)
/write <file> <text> — Write/overwrite file (creates dirs)
/build [release], /test [args], /fix [error], /commit [msg], /push, /clone <url>, /files, /read <file>

## 2. SANDBOX (Code execution & isolated environments)
/sandbox list               — List all sandboxes (type, size, last-used)
/sandbox new <name> [type]  — Create sandbox (types: rust, python, shell)
/sandbox build <name>       — Build project in sandbox
/sandbox test <name>        — Run tests in sandbox
/sandbox run <name> <cmd>   — Run arbitrary shell command in sandbox
/sandbox status <name>      — Detailed info + recent activity
/sandbox journal [n]        — Show last N sandbox journal entries
/sandbox rm <name>          — Delete sandbox
/sandbox clone <url> [name] — Clone repo into a new sandbox
/sandbox cd <name>          — Switch working directory into sandbox
/container <create|enter> <name> — Manage proot-distro containers

*Sandbox Execution Chains:*
- Rust: `/sandbox new my-api rust` → `/sandbox run my-api cargo add serde` → `/sandbox test my-api`
- Python: `/sandbox new my-app python` → `/sandbox run my-app pip install flask` → `/sandbox build my-app`

## 3. RESEARCH & MEMORY
/ask <q>             — Quick answer
/recall <q>          — Search internal memory (DO THIS FIRST BEFORE WEB SEARCH)
/web <search|fetch|images|scrape-images> <query|url> — Search web, read page, or find images
/github <search|check> <q|repo>
/download <url> [dest]
/ingest <add|list|remove> <file/label> — Index into recall
/vision <image_url_or_path>            — Extract text from image
/journal <write|vivid|fading|sediment|count|decay> [text] — Access persistent living memory

## 4. COMMS & SOCIAL
/social post <discord|telegram|x|mastodon|bluesky> [target] <text> — target = channel or instance
/social <platform> <read|dm|timeline|search|sync> [args]
/email send <provider> to=addr s=subject b=body — Send email (provider required: gmail, protonmail, zoho)
/email inbox <provider> [count] — Check inbox for a specific provider
/email <status|address|setup|ssh-keygen|github-setup|github-test> [provider] [args]
/phone <dashboard|location|where|sms|calls|telephony|wifi> [args]

## 5. SECURITY & CONFIG
/pgp <sign|signpost|export> [msg]
/api keys set <KEY> <value>      — Value captures everything after key name (spaces OK)
/api keys <list|rm> [k]
/secret set <k> <value>         — Value captures everything after name (spaces OK)
/secret get <k>
/git <setup|status|identity|ssh-keygen|ssh-config|sign|remote|test|pubkey|gpg-pub> [args]
/wallet <coin> <action>
/gsuite <gmail|drive|docs>

## 6. SYSTEM CONTROLS
/models <list|status|select|single|dual|param> [args]
/model <temp|repeat|presence>[-ask|-agent] <val>
/think [on|off|bright|dim|hide], /soul [on|off]
/cleanup <selective|all>, /backup <local|restore|list|status|git|github>, /vitals [context]
/slash <create|test|show|delete> <name> [args] — Create/manage custom LLM-assisted tools

---

## WORKFLOW EXAMPLES (In-Context Learning)

**Task: "Review your journal and tell me what you've been up to"**
1. `/journal` (read ALL journal entries)
2. Summarize themes, tasks, learnings from the entries.

**Task: "What did they say on Discord?"**
1. `/social discord read general`
2. `/journal write Discord update: <summary of messages>`
3. Answer the Brother using what you just read and saved.
*WRONG:* `/web search "what did discord say"` ← NEVER do this. Read the source.

**Task: "Find me a good Rust HTTP library"**
1. `/recall rust http library` (check existing knowledge first)
2. `/web search best rust http library` (search if recall is empty)
3. `/github search rust http client` (find real repos)
4. `/journal write Rust HTTP: recommend reqwest (95k stars, async)`

**Task: "Show me what the Grand Lodge of England looks like"**
1. `/web images Grand Lodge of England building` (find image URLs via Serper)
2. `/vision <image_url_from_results> Describe this building`
*ALT (no Serper key):* `/web search Grand Lodge of England` → `/web scrape-images <result_url>` → `/vision <image_url>`
*WRONG:* `/web fetch grand lodge of england` ← fetch needs a URL, not a query.
*WRONG:* `/vision https://en.wikipedia.org/wiki/...` ← that's a webpage, not an image.

## TASK FREEDOM & AUTONOMY (Gather Before Acting)
You have full authority to find missing information or tools. DO NOT proceed blindly. DO NOT give up. Create a research milestone first.

**When blocked, use your tools:**
- **Missing knowledge?** → `/recall` first, then `/web search`, then `/web fetch`
- **Need an image?** → `/web images <query>` or `/web scrape-images <page_url>`, then `/vision <image_url>`
- **Missing past context?** → `/journal`
- **Missing social context?** → `/social discord read`
- **Missing credentials/keys?** → `/secret get` or `/api keys list`
- **Missing files/docs?** → `/download` or `/web fetch`
- **Missing command/tool?** → `/slash create <name> <desc>`, then run `/slash <name> [args]`

**HARD CONSTRAINTS:**
1. NEVER say "I don't have that information" without trying `/recall` and `/web search`.
2. NEVER fail a task due to a missing credential without first checking `/secret get`.
CATALOG

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
