#!/bin/bash
# ── George: Slash Command Dispatcher ───────────────────────
# Registers and dispatches /commands similar to Claude Code.

[ -n "${_LIB_COMMANDS_LOADED:-}" ] && return 0; _LIB_COMMANDS_LOADED=1

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

# ── Is this a known command name (without slash)? ──────────────
# Used by REPL to auto-detect slashless commands like "model temp-ask".
commands_is_known_name() {
    local name="$1"
    # Built-ins
    case "$name" in
        help|quit|exit|q) return 0 ;;
    esac
    # Registry
    [ -n "${CMD_REGISTRY[$name]:-}" ] && return 0
    # Commands directory
    [ -f "$LODGE_COMMANDS_DIR/${name}.sh" ] && return 0
    return 1
}
# ── Is this safe to auto-route as a slash command? ─────────────
# When a user types "read foo.txt" we want /read, but "read the docs
# and summarize" is natural language. Guard against common verbs
# that overlap with slash commands when the input looks like prose.
# Single-word input always routes ("status" → /status).
# Multi-word input blocks ambiguous first words that are common
# English verbs, so "build a REST API" goes to agent_run instead
# of /build. Explicit slash always works: /build a REST API.
commands_is_safe_auto_route() {
    local input="$1"
    local first_word="${input%% *}"

    # Must be a known command name first
    commands_is_known_name "$first_word" || return 1

    # Single word → always safe ("status", "help", "vitals")
    [[ "$input" == *" "* ]] || return 0

    # Multi-word: block ambiguous verbs that are common in natural language.
    # These are command names that overlap with everyday English verbs —
    # when followed by additional words, the user almost certainly means
    # a natural-language instruction, not a slash command.
    case "$first_word" in
        read|write|test|build|fix|save|plan|ask|push|commit|clone|clear|compact|\
        init|reflect|think|recall|debug|model|status|email|backup|web|cd|ls|files|git|\
        service)
            return 1 ;;
    esac

    # Non-ambiguous command names (sandbox, container, phone, etc.) → safe
    return 0
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
        # NOTE: Do NOT call mastodon_instance_list here — it prints UI output
        # ("No Mastodon instances registered") that leaks into the status string
        # and gets injected into every strategist/specialist prompt as noise.
        # Instead, query the sqlite DB directly for a silent count check.
        local _masto_ok=0
        local _masto_db="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}/mastodon_instances.db"
        if [ -f "$_masto_db" ] && command -v sqlite3 &>/dev/null; then
            local _inst_count
            _inst_count=$(sqlite3 "$_masto_db" "SELECT COUNT(*) FROM instances;" 2>/dev/null)
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

# ── Full command catalog for LLM injection (JSON) ─────────────
# Returns a structured JSON command reference with syntax, examples,
# and rules keyed per command/subcommand.  Structured format helps
# 4B models on edge devices parse tool syntax unambiguously.
# Injected during planning, routing, guided retry, and execution.
commands_catalog() {
    local _catalog_ts
    _catalog_ts=$(date '+%Y-%m-%d %H:%M:%S %Z')

    # ── Dynamic parts (captured first, spliced into JSON below) ──
    local _svc_json=""
    if declare -f commands_services_status &>/dev/null; then
        local _svc_raw
        _svc_raw=$(commands_services_status 2>/dev/null)
        # Escape for JSON: newlines → \n, quotes → \"
        _svc_json=$(printf '%s' "$_svc_raw" | sed ':a;N;$!ba;s/\n/\\n/g;s/"/\\"/g')
    fi

    local _slash_json=""
    if declare -f slash_catalog &>/dev/null; then
        local _slash_raw
        _slash_raw=$(slash_catalog 2>/dev/null)
        if [ -n "$_slash_raw" ]; then
            _slash_json=$(printf '%s' "$_slash_raw" | sed ':a;N;$!ba;s/\n/\\n/g;s/"/\\"/g')
        fi
    fi

    # ── JSON catalog body ─────────────────────────────────────
    # Keys match section names expected by tests and other consumers.
    # Examples are keyed under their parent command for in-context learning.
    cat << CATALOG
{"SYSTEM CAPABILITIES & TOOLS":{"time":"${_catalog_ts}",
"note":"Do NOT quote arguments (parsed by whitespace). Never guess syntax; use /recall <cmd>.",
"CORE WORKFLOW":["READ: /recall or source","GATHER: /web, /secret get","INGEST: /journal write","RESPOND: execute"],
"commands":{
  "PROJECT & CODE":{
    "/init":{"syntax":"/init <name> <lang>","desc":"Scaffold project (rust,python,rl,data,shell)","ex":["/init task-manager rust"]},
    "/write":{"syntax":"/write <file> <content>","desc":"Write/overwrite file (creates dirs)",
      "variants":{"--append":"Append to end of file","--edit":"Sed substitution ONLY (short, max 200 chars)"},
      "rules":["Use \\\\n for newlines","--edit ONLY for short sed, NEVER multi-line code","Include COMPLETE source for code files","Creates parent dirs automatically"],
      "ex":["/write src/main.rs fn main() { println!(\"Hello\"); }","/write --append Cargo.toml \\\\n[dependencies]\\\\nreqwest = \"0.11\"","/write --edit src/main.rs s/old_fn/new_fn/g"]},
    "/read":{"syntax":"/read <file>","desc":"Read file contents (first 100 lines)"},
    "/ls":{"syntax":"/ls [path] [depth]","desc":"List files as tree (depth 1-8, default 3)",
      "ex":[{"cmd":"/ls","out":"my-project/\n\u251c\u2500\u2500 src/\n\u2502   \u251c\u2500\u2500 lib.rs\n\u2502   \u2514\u2500\u2500 main.rs\n\u251c\u2500\u2500 Cargo.toml\n\u2514\u2500\u2500 README.md"},
            {"cmd":"/ls src/config 2","out":"config/\n\u251c\u2500\u2500 mod.rs\n\u251c\u2500\u2500 database/\n\u2502   \u251c\u2500\u2500 mod.rs\n\u2502   \u2514\u2500\u2500 pool.rs\n\u2514\u2500\u2500 settings.rs"},
            "/ls . 5"]},
    "/build":{"syntax":"/build [release]","desc":"Build (auto-detects Cargo/pyproject/Make)"},
    "/test":{"syntax":"/test [args]","desc":"Run tests"},
    "/fix":{"syntax":"/fix [error]","desc":"Diagnose and fix errors"},
    "/commit":{"syntax":"/commit [msg]","desc":"AI commit message + commit"},
    "/push":{"syntax":"/push","desc":"Push to GitHub"},
    "/clone":{"syntax":"/clone <url>","desc":"Clone and setup repo"},
    "/save":{"syntax":"/save <file> <text>","desc":"Save content to file"}
  },
  "SANDBOX & SERVICES":{
    "/sandbox":{"syntax":"/sandbox <action> <name> [args]","desc":"Code execution sandboxes",
      "actions":{"list":"list all","new":"new <name> [type] (rust/python/shell)","build":"build <name>","test":"test <name>","run":"run <name> <cmd>","status":"status <name>","cd":"cd <name>","rm":"rm <name>","clone":"clone <url> [name]","journal":"journal [n]"},
      "rules":["Do NOT use /sandbox to run slash commands"],
      "ex":[{"task":"Rust sandbox","chain":["/sandbox new my-api rust","/sandbox run my-api cargo add serde","/sandbox test my-api"]},
            {"task":"Python sandbox","chain":["/sandbox new my-app python","/sandbox run my-app pip install flask"]}]},
    "/container":{"syntax":"/container <create|enter|exec|rm> <distro>","desc":"Linux containers (ubuntu/alpine/debian/fedora)"},
    "/service":{"syntax":"/service <action> <name>","desc":"Rust binary lifecycle",
      "actions":{"register":"register <name> [path]","build":"build <name>","deploy":"deploy <name>","start":"start <name>","stop":"stop <name>","restart":"restart <name>","status":"status <name>","logs":"logs <name> [n]","list":"list","unregister":"unregister <name>"},
      "ex":[{"task":"Deploy pipeline","chain":["/service register ingestion .","/service deploy ingestion","/service status ingestion"]}]}
  },
  "RESEARCH & MEMORY":{
    "/ask":{"syntax":"/ask <q>","desc":"Quick answer from knowledge (no tools)"},
    "/recall":{"syntax":"/recall <q>","desc":"Search knowledge base FTS5 (DO THIS FIRST BEFORE WEB SEARCH)","ex":["/recall trout stocking schedule"]},
    "/web":{"syntax":"/web <action> <query|url>","desc":"Web search and fetch",
      "actions":{"search":"/web search <query> (returns URLs+snippets)","fetch":"/web fetch <url> (read webpage, NOT images)","images":"/web images <query> (find image URLs)","scrape-images":"/web scrape-images <url> (extract text+images as JSON)"},
      "rules":["search=QUERY, fetch=URL, NEVER swap","Use /vision for images, NOT /web fetch","1 search + 1-2 fetches is enough","scrape-images returns {url,title,content,images[]}"],
      "chains":["Research: /web search <topic> -> /web fetch <url> -> summarize","Images: /web search <topic> -> pick image URL -> /vision <url>","Deep: /web scrape-images <url> -> read content field -> /vision <img>"],
      "ex":["/web search rust async tutorial 2025"]},
    "/github":{"syntax":"/github <search|check> <q|repo>","desc":"Search GitHub repos"},
    "/download":{"syntax":"/download <url> [dest]","desc":"Download a file"},
    "/vision":{"syntax":"/vision <url|path> [prompt]","desc":"Analyze image (accepts URLs directly, no /download needed)","ex":["/vision https://example.com/photo.jpg describe this scene"]},
    "/journal":{"syntax":"/journal [show] [tier]","desc":"Access persistent living memory",
      "actions":{"read":"/journal (no args=read ALL)","show vivid":"/journal show vivid","show fading":"/journal show fading","show sediment":"/journal show sediment","write":"/journal write <text>","count":"/journal count","decay":"/journal decay"},
      "rules":["To READ: /journal (no args). To WRITE: /journal write <text>","NEVER write when task says check/read/review/show journal"],
      "ex":["/journal","/journal show vivid","/journal write Today I learned about moral sentiments"]},
    "/ingest":{"syntax":"/ingest <add|summarize|list|remove> [file] [label]","desc":"Upload docs to knowledge base"}
  },
  "COMMS & SOCIAL":{
    "/social":{"syntax":"/social <action> <platform> [target] <text>","desc":"Post to Discord/Telegram/X/Mastodon/Bluesky (NOT email)",
      "actions":{"post":"/social post <discord|telegram|x|mastodon|bluesky> [channel] <text>","read|dm|timeline|search|sync":"/social <platform> <action> [args]"},
      "rules":["ALWAYS include channel name for Discord post","Do NOT wrap args in quotes","@DisplayName auto-resolved to <@user_id>","Channel goes BEFORE text"],
      "ex":["/social post discord lunkers @Pompler Just landed a 5lb bass","/social discord read general","/social discord dm Pompler Hey check this out"]},
    "/email":{"syntax":"/email <action> <provider> [args]","desc":"Send/check actual email (gmail/protonmail/zoho)",
      "actions":{"send":"/email send <provider> <addr> subject=<subj> body=<body>","inbox":"/email inbox <provider> [count]","status":"/email status"},
      "rules":["For social platforms use /social NOT /email"],
      "ex":["/email send gmail user@test.com subject=Hello body=How are you?"]},
    "/phone":{"syntax":"/phone [dashboard|location|sms|calls|wifi]","desc":"Phone dashboard, SMS, calls"}
  },
  "SECURITY & CONFIG":{
    "/pgp":{"syntax":"/pgp <sign|signpost|export> [msg]","desc":"PGP operations"},
    "/api":{"syntax":"/api keys <set|list|rm> <KEY> [value]","desc":"API key management"},
    "/secret":{"syntax":"/secret <set|get> <key> [value]","desc":"Encrypted vault (AES-256-CBC)"},
    "/git":{"syntax":"/git <setup|status|ssh-keygen|ssh-config|sign|remote|test|pubkey|gpg-pub>","desc":"Git configuration"},
    "/wallet":{"syntax":"/wallet <coin> <action>","desc":"Crypto wallets"},
    "/gsuite":{"syntax":"/gsuite <gmail|drive|docs>","desc":"Google Suite"},
    "/backup":{"syntax":"/backup <local|restore|list|status|git|github>","desc":"Backup operations"},
    "/vitals":{"syntax":"/vitals [context]","desc":"System dashboard (disk, RAM, battery, network)"}
  },
  "SYSTEM CONTROLS & META":{
    "/ls":{"syntax":"/ls [path] [depth]","desc":"Tree view of files (depth 1-8, default 3)"},
    "/cd":{"syntax":"/cd <dir>","desc":"Change working directory"},
    "/models":{"syntax":"/models <list|status|select|single|dual|param>","desc":"Model management"},
    "/model":{"syntax":"/model <param>[-scenario] <val>","desc":"Tune sampling hyper-parameters",
      "actions":{"temp":"/model temp[-ask|-agent|-router|-journal|-tool] <val>","repeat":"/model repeat[-scenario] <val>","presence":"/model presence[-scenario] <val>","reset":"/model reset","write-mode":"/model write-mode <confirm|append|dangerous>"},
      "ex":["/model temp-agent 0.4","/model reset"]},
    "/limits":{"syntax":"/limits [param] [val]","desc":"Tune planning parameters",
      "actions":{"steps":"steps <n>","depth":"depth <n>","milestones":"milestones <n>","inner":"inner <n>","tokens":"tokens <n>","eval-mode":"eval-mode <val>"}},
    "/think":{"syntax":"/think [on|off|bright|dim|hide]","desc":"Toggle/configure thinking mode"},
    "/soul":{"syntax":"/soul [on|off]","desc":"Toggle full personality injection"},
    "/config":{"syntax":"/config <show|save|reset|edit>","desc":"Persistent settings"},
    "/debug":{"syntax":"/debug [on|off]","desc":"Toggle debug mode"},
    "/backend":{"syntax":"/backend <auto|ollama|llamacpp>","desc":"Switch LLM backend"},
    "/gpu":{"syntax":"/gpu <layers>","desc":"Set GPU offload layers"},
    "/cleanup":{"syntax":"/cleanup <selective|all>","desc":"Cleanup temp files"},
    "/slash":{"syntax":"/slash <create|test|show|delete> <name> [args]","desc":"Create/manage custom commands","ex":["/slash create morning-brief Show weather, calendar, unread messages"]}
  }
},
"WORKFLOW EXAMPLES":[
  {"task":"What files do we have?","steps":["/ls"]},
  {"task":"Check config module","steps":["/ls src/config 2","/read src/config/mod.rs"]},
  {"task":"Full project tree","steps":["/ls . 5"]},
  {"task":"Review journal","steps":["/journal"],"note":"Summarize themes and learnings","wrong":"/write or /web search"},
  {"task":"What did they say on Discord?","steps":["/social discord read general","/journal write Discord update: <summary>"],"wrong":"/web search 'discord'"},
  {"task":"Find Rust HTTP library","steps":["/recall rust http library","/github search rust http client","/web search best rust http library","/journal write Rust HTTP: recommend reqwest"]},
  {"task":"Show Grand Lodge of England","steps":["/web search Grand Lodge photos","/web scrape-images <url>","/vision <image_url> Describe building"],"wrong":"/web fetch <image_url>"},
  {"task":"Lower agent temperature","steps":["/model temp-agent 0.4"],"wrong":"Editing config files"}
],
"TASK FREEDOM & AUTONOMY":{"principle":"Full authority to find missing info. DO NOT give up.",
  "when_blocked":{
    "missing_knowledge":"/recall first, then /web search, then /web fetch",
    "need_image":"/web images <query> or /web scrape-images <url>, then /vision <url>",
    "missing_context":"/journal or /social discord read",
    "missing_creds":"/secret get or /api keys list",
    "missing_files":"/ls or /read, then /download or /web fetch",
    "missing_tool":"/slash create <name> <desc>",
    "tune_behavior":"/model (sampling), /limits (planning), /think (reasoning)"},
  "HARD CONSTRAINTS":["NEVER say 'I don't have that' without trying /recall and /web search",
    "NEVER fail due to missing credential without /secret get first",
    "NEVER edit a file without checking it exists with /ls or /read"]
},
"services":"${_svc_json}",
"custom_commands":"${_slash_json}"
}}
CATALOG
}
