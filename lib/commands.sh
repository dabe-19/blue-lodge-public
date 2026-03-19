#!/bin/bash
# ── George: Slash Command Dispatcher ───────────────────────
# Registers and dispatches George /commands.

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
    
    # Parse: /command [args...] — parameter expansion (replaces awk + 2 sed forks)
    local _first_word="${input%% *}"
    local cmd="${_first_word#/}"
    local args="${input#"${_first_word}"}"
    args="${args#"${args%%[![:space:]]*}"}"

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

    # ── Strip hallucinated --flags from slash command args ──────────
    # Small LLMs hallucinate bash-style flags (--limit, --output, etc.)
    # on slash commands. No slash command accepts --flags — they use
    # positional args only. Content commands are skipped because their
    # freeform text args may legitimately contain double-dashes.
    case "$cmd" in
        edit|respond|write|append|save|social|email|commit|fix) ;;
        *)
            local _cleaned=() _skip_next=0 _stripped_any=0
            for _tok in $args; do
                if [ "$_skip_next" -eq 1 ]; then
                    _skip_next=0
                    [[ "$_tok" == --* || "$_tok" == http* || "$_tok" == /* ]] || continue
                fi
                if [[ "$_tok" =~ ^--[a-zA-Z] ]]; then
                    _skip_next=1; _stripped_any=1; continue
                fi
                _cleaned+=("$_tok")
            done
            if [ "$_stripped_any" -eq 1 ]; then
                [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && \
                    ui_dim "  [debug] commands_dispatch: stripped flags from /$cmd: ${args} → ${_cleaned[*]}"
                args="${_cleaned[*]}"
            fi
            ;;
    esac

    # ── MCP intercept — when MCP is enabled and has a matching tool,
    # try it first. Falls through to normal dispatch on failure.
    if declare -f _mcp_dispatch_intercept &>/dev/null; then
        local _mcp_out
        _mcp_out=$(_mcp_dispatch_intercept "$cmd" "$args" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$_mcp_out" ]; then
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && declare -f ui_dim &>/dev/null && ui_dim "  [debug] commands_dispatch: MCP intercepted /$cmd (${#_mcp_out} bytes)"
            echo "$_mcp_out"
            return 0
        fi
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
        quit|exit) return 99 ;;
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
        help|quit|exit) return 0 ;;
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
        read|write|append|edit|test|build|fix|save|plan|ask|push|commit|clone|clear|compact|\
        init|reflect|think|recall|debug|model|status|email|backup|web|cd|ls|files|git|\
        grep|service)
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
    # Examples use <placeholder> tags — fill keys explain what to substitute.
    # Commands split into TOOLS (gather/execute) and DELIVERY (output to user).
    cat << CATALOG
{"SYSTEM CAPABILITIES & TOOLS":{"time":"${_catalog_ts}",
"note":"Do NOT quote arguments (parsed by whitespace). Slash commands do NOT accept --flags (no --limit, --output, --source, --date). ONLY positional args as shown in syntax. Never guess syntax; use /recall <cmd>.",
"CORE WORKFLOW":["READ: /recall or source","GATHER: /web, /secret get","INGEST: /journal write","RESPOND: execute"],
"DEFAULT RULE":"If the task does NOT explicitly require /write, /append, /edit, /save, /email, /social, /commit, or /push, use /respond to deliver the answer.",
"commands":{
  "PROJECT & CODE (TOOLS — gather info, execute work)":{
    "/init":{"syntax":"/init <name> <lang>","desc":"Scaffold project (rust,python,rl,data,shell)",
      "format_only_ex":["/init <name> <lang>"],
      "fill":{"<name>":"project name, no spaces, use underscores","<lang>":"one of: rust, python, rl, data, shell"}},
    "/edit":{"syntax":"/edit <file> <sed_expr>","desc":"Small sed substitution (max 200 chars)",
      "rules":["ONLY for short substitutions: s/old/new/g","NEVER multi-line code","Max 200 chars","If changing >1 line, use /write with COMPLETE file"],
      "format_only_ex":["/edit <filepath> s/<old>/<new>/g"],
      "fill":{"<filepath>":"target file path","<old>":"text to find","<new>":"replacement text"}},
    "/append":{"syntax":"/append <file> <content>","desc":"Append content to END of existing file",
      "rules":["Use \\\\n for newlines","Creates file if it does not exist","Use for: deps, new functions, new sections"],
      "format_only_ex":["/append <filepath> <content to add>"],
      "fill":{"<filepath>":"target file path","<content>":"text to append"}},
    "/write":{"syntax":"/write <file> <content>","desc":"Write/overwrite COMPLETE file (creates dirs) [DELIVERY]",
      "rules":["Use \\\\n for newlines","Include COMPLETE source for code files","Creates parent dirs automatically","To ADD to a file use /append, to change one line use /edit"],
      "format_only_ex":["/write <filepath> <complete file content with \\\\n>"],
      "fill":{"<filepath>":"target file path","<complete file content>":"entire file source, use \\\\n for newlines"}},
    "/read":{"syntax":"/read <file>","desc":"Read file contents (first 100 lines)",
      "format_only_ex":["/read <filepath>"],"fill":{"<filepath>":"path to file to read"}},
    "/ls":{"syntax":"/ls [path] [depth]","desc":"List files as tree (depth 1-8, default 3)",
      "format_only_ex":["/ls","/ls <path> <depth>"],"fill":{"<path>":"directory to list","<depth>":"tree depth 1-8"}},
    "/build":{"syntax":"/build [release]","desc":"Build (auto-detects Cargo/pyproject/Make)",
      "format_only_ex":["/build","/build release"]},
    "/test":{"syntax":"/test [args]","desc":"Run tests",
      "format_only_ex":["/test","/test <specific_test>"],"fill":{"<specific_test>":"optional test name or filter"}},
    "/fix":{"syntax":"/fix [error]","desc":"Diagnose and fix errors",
      "format_only_ex":["/fix <file-or-error>"],"fill":{"<file-or-error>":"filename or error description"}},
    "/clone":{"syntax":"/clone <url>","desc":"Clone and setup repo",
      "format_only_ex":["/clone <url>"],"fill":{"<url>":"repository URL or owner/repo"}}
  },
  "DELIVERY — present output to user (one per milestone; a full task may chain several across milestones, e.g. /write then /email)":{
    "/respond":{"syntax":"/respond <text>","desc":"Present answer directly to operator — DEFAULT when no file/email/post needed [DELIVERY]",
      "format_only_ex":["/respond <answer text>"],"fill":{"<answer text>":"your complete response to the user"}},
    "/commit":{"syntax":"/commit [msg]","desc":"AI commit message + commit [DELIVERY]",
      "format_only_ex":["/commit","/commit <files>"],"fill":{"<files>":"optional specific files to stage"}},
    "/push":{"syntax":"/push","desc":"Push to GitHub [DELIVERY]"},
    "/save":{"syntax":"/save <file> <text>","desc":"Save content to file [DELIVERY]",
      "format_only_ex":["/save <filepath> <content>"],"fill":{"<filepath>":"target filename","<content>":"text to save"}}
  },
  "SANDBOX & SERVICES (TOOLS)":{
    "/sandbox":{"syntax":"/sandbox <action> <name> [args]","desc":"Code execution sandboxes",
      "actions":{"list":"list all","new":"new <name> [type] (rust/python/shell)","build":"build <name>","test":"test <name>","run":"run <name> <cmd>","status":"status <name>","cd":"cd <name>","rm":"rm <name>","clone":"clone <url> [name]","journal":"journal [n]"},
      "rules":["Do NOT use /sandbox to run slash commands"],
      "format_only_ex":["/sandbox new <name> <type>","/sandbox run <name> <cmd>","/sandbox test <name>"],
      "fill":{"<name>":"sandbox project name","<type>":"one of: rust, python, shell","<cmd>":"command to run inside sandbox"}},
    "/container":{"syntax":"/container <create|enter|exec|rm> <distro>","desc":"Linux containers (ubuntu/alpine/debian/fedora)"},
    "/service":{"syntax":"/service <action> <name>","desc":"Rust binary lifecycle",
      "actions":{"register":"register <name> [path]","build":"build <name>","deploy":"deploy <name>","start":"start <name>","stop":"stop <name>","restart":"restart <name>","status":"status <name>","logs":"logs <name> [n]","list":"list","unregister":"unregister <name>"},
      "format_only_ex":["/service <action> <name>"],
      "fill":{"<action>":"one of: register, build, deploy, start, stop, restart, status, logs, list","<name>":"service name"}}
  },
  "RESEARCH & MEMORY (TOOLS)":{
    "/recall":{"syntax":"/recall <q>","desc":"Search knowledge base FTS5 (DO THIS FIRST BEFORE WEB SEARCH)",
      "format_only_ex":["/recall <keywords>"],"fill":{"<keywords>":"search terms for knowledge base"}},
    "/ask":{"syntax":"/ask <question>","desc":"Ask the HUMAN OPERATOR a question — use when you need real preferences, dietary details, names, allergies, or any info only the user knows. User types an answer.",
      "rules":["ONE specific question per /ask","Ask about concrete details the user must provide","Do NOT ask rhetorical or philosophical questions"],
      "format_only_ex":["/ask What dietary restrictions does the family have?"]},
    "/brainstorm":{"syntax":"/brainstorm <question or topic>","desc":"George thinks/reasons/brainstorms using his OWN knowledge — NO human input. Use to generate ideas, weigh options, or reason through problems. Alias: /q",
      "contrast":"/ask asks the HUMAN. /brainstorm = George figures it out himself.",
      "format_only_ex":["/brainstorm What are good chicken dinner recipes with rice and peppers?","/brainstorm What are the pros and cons of SQLite vs PostgreSQL?"]},
    "/web":{"syntax":"/web <action> <query|url>","desc":"Web search, fetch/scrape, and image extraction",
      "actions":{
        "search":"/web search <query> — returns list of URLs + text snippets from search engines (Serper/DuckDuckGo)",
        "fetch":"/web fetch <url> — downloads and extracts readable TEXT from a webpage (HTML→text, PDF→text, JSON→text). Returns plain text content only, NO images. Alias: /web scrape",
        "scrape":"/web scrape <url> — alias for /web fetch. Downloads and extracts readable TEXT from a webpage.",
        "scrape-images":"/web scrape-images <url> — returns STRUCTURED JSON: {url, title, content, images:[]} with page text AND image URIs. Use this when you need BOTH text and images from a page. Image URIs can be passed to /vision for analysis.",
        "images":"/web images <query> — searches for image URLs by keyword query via Serper API (requires SERPER_API_KEY). Returns image URLs only, no page content."},
      "rules":["search=QUERY (keywords), fetch/scrape/scrape-images=URL — NEVER swap","/web fetch (or /web scrape) returns TEXT only — use /web scrape-images when you need images","1 search + 1-2 fetches is enough — do NOT fetch every result","scrape-images returns {url,title,content,images[]} — pass images[] URLs to /vision","LOCAL FILES: NEVER use /web fetch on local files or relative paths — use /read for text files, /vision for images","ONE URL PER COMMAND — never put multiple URLs in one /web call. The URL must be the LAST token — nothing after it."],
      "chains":["Text research: /web search <topic> -> /web fetch <url> -> summarize","Scrape workflow: /web search <topic> -> /web scrape <url> -> summarize","Image research: /web scrape-images <url> -> /vision <image_url_from_images[]>","Image search: /web images <query> -> /vision <image_url>","Deep page analysis: /web scrape-images <url> -> read content + /vision on each image"],
      "format_only_ex":["/web search <keywords>","/web fetch <url>","/web scrape <url>","/web scrape-images <url>","/web images <keywords>"],
      "fill":{"<keywords>":"3-5 search terms derived from the task","<url>":"full https:// URL from search results or task — NEVER a local file path"}},
    "/github":{"syntax":"/github <search|check> <q|repo>","desc":"Search GitHub repos",
      "format_only_ex":["/github search <keywords>"],"fill":{"<keywords>":"search terms for GitHub"}},
    "/download":{"syntax":"/download <url> [dest]","desc":"Download a file",
      "format_only_ex":["/download <url>"],"fill":{"<url>":"URL to download"}},
    "/vision":{"syntax":"/vision <url|path> [prompt]","desc":"Analyze/describe an image using vision model. Accepts URLs directly (no /download needed). Returns detailed text description of image contents.",
      "notes":["Supports jpg/png/gif/webp/bmp","Pair with /web scrape-images to analyze images from web pages","Default prompt: describe image in detail (text, objects, people)"],
      "format_only_ex":["/vision <image> <prompt>"],
      "fill":{"<image>":"URL or local path to image (e.g. from /web scrape-images images[] array)","<prompt>":"what to analyze or describe"}},
    "/journal":{"syntax":"/journal [show] [tier]","desc":"Access persistent living memory",
      "actions":{"read":"/journal (no args=read ALL)","show vivid":"/journal show vivid","show fading":"/journal show fading","show sediment":"/journal show sediment","write":"/journal write <text>","count":"/journal count","decay":"/journal decay"},
      "rules":["To READ: /journal (no args). To WRITE: /journal write <text>","NEVER write when task says check/read/review/show journal"],
      "format_only_ex":["/journal","/journal show <tier>","/journal write <text>"],
      "fill":{"<tier>":"one of: vivid, fading, sediment","<text>":"journal entry content"}},
    "/ingest":{"syntax":"/ingest <add|summarize|list|remove> [file] [label]","desc":"Upload docs to knowledge base"}
  },
  "COMMS & SOCIAL (DELIVERY)":{
    "/social":{"syntax":"/social <action> <platform> [target] <text>","desc":"Post to Discord/Telegram/X/Mastodon/Bluesky (NOT email) [DELIVERY]",
      "actions":{"post":"/social post <discord|telegram|x|mastodon|bluesky> [channel] <text>","read|dm|timeline|search|sync":"/social <platform> <action> [args]"},
      "rules":["ALWAYS include channel name for Discord post","Do NOT wrap args in quotes","@DisplayName auto-resolved to <@user_id>","Channel goes BEFORE text","FILE REFS AUTO-EXPAND: Any readable file path (e.g. report.md, notes.txt) in message text is automatically replaced with the file contents. Just mention the filename — no /read needed.","PREFER FILE REFS FOR LONG CONTENT: When sending reports, summaries, or multi-paragraph text via DM or post, ALWAYS /write the content to a file first, then reference the file path in the message. This avoids Discord's 2000-char limit and keeps commands clean.","MULTI-DM: /social discord dm accepts multiple recipients separated by 'and' — e.g. /social discord dm Babadoo and Nubster Hey!","NAME CLEANING: Garbled handles like @User@discord.com or @User@User are auto-cleaned to the bare username before lookup"],
      "format_only_ex":["/social post discord <channel> <text>","/social discord read <channel>","/social discord dm <user> <text>","/social discord dm Babadoo and Nubster Check this out!","/social post discord general Check this out: report.md","/social discord dm PageOfABook Here is the report: scrape-report.md"],
      "fill":{"<channel>":"Discord channel name without #","<text>":"message content (file paths auto-expand to contents)","<user>":"Discord username (bare name — no @domain suffix)"}},
    "/email":{"syntax":"/email <action> <provider> [args]","desc":"Send/check actual email (gmail/protonmail/zoho) [DELIVERY]",
      "actions":{"send":"/email send <provider> <addr> subject=<subj> body=<body>","inbox":"/email inbox <provider> [count]","status":"/email status"},
      "rules":["For social platforms use /social NOT /email","FILE REFS AUTO-EXPAND: File paths in body= text (e.g. body=report.md) are auto-replaced with file contents. Just reference the file."],
      "format_only_ex":["/email send <provider> <addr> subject=<subj> body=<body>","/email send gmail user@x.com s=Report b=See the full report: results.txt","/email inbox <provider>"],
      "fill":{"<provider>":"one of: gmail, protonmail, zoho","<addr>":"recipient email address","<subj>":"email subject line","<body>":"email body text (file paths auto-expand to contents)"}},
    "/phone":{"syntax":"/phone [dashboard|location|sms|calls|wifi]","desc":"Phone dashboard, SMS, calls"}
  },
  "SECURITY & CONFIG (TOOLS)":{
    "/pgp":{"syntax":"/pgp <sign|signpost|export> [msg]","desc":"PGP operations"},
    "/api":{"syntax":"/api keys <set|list|rm> <KEY> [value]","desc":"API key management"},
    "/secret":{"syntax":"/secret <set|get> <key> [value]","desc":"Encrypted vault (AES-256-CBC)"},
    "/git":{"syntax":"/git <setup|status|search|check|clone|commit|push|sign|remote|test|pubkey>","desc":"Git & GitHub — unified entrypoint for all git workflows",
      "actions":{
        "search":"/git search <query> — Search GitHub repos by keyword",
        "check":"/git check <owner/repo> — Verify a GitHub repo exists",
        "clone":"/git clone <url|owner/repo> — Clone a repo into sandbox",
        "commit":"/git commit [files] — AI-generated commit message",
        "push":"/git push [branch] — Push current branch to remote",
        "setup":"/git setup — Full auto-setup (identity + SSH + GPG)",
        "status":"/git status — Show git configuration overview"},
      "rules":["Prefer /git over /github, /clone, /commit, /push — they all route through /git"],
      "format_only_ex":["/git search <keywords>","/git check <owner/repo>","/git clone <url>","/git commit","/git push"]},
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
      "format_only_ex":["/model <param> <value>"],
      "fill":{"<param>":"temp, repeat, presence, reset, or write-mode","<value>":"numeric value or mode"}},
    "/limits":{"syntax":"/limits [param] [val]","desc":"Tune planning parameters",
      "actions":{"steps":"steps <n>","depth":"depth <n>","milestones":"milestones <n>","inner":"inner <n>","tokens":"tokens <n>","eval-mode":"eval-mode <val>"}},
    "/think":{"syntax":"/think [on|off|bright|dim|hide]","desc":"Toggle/configure thinking mode"},
    "/soul":{"syntax":"/soul [on|off]","desc":"Toggle full personality injection"},
    "/config":{"syntax":"/config <show|save|reset|edit>","desc":"Persistent settings"},
    "/debug":{"syntax":"/debug [on|off]","desc":"Toggle debug mode"},
    "/backend":{"syntax":"/backend <auto|ollama|llamacpp>","desc":"Switch LLM backend"},
    "/gpu":{"syntax":"/gpu <layers>","desc":"Set GPU offload layers"},
    "/cleanup":{"syntax":"/cleanup <selective|all>","desc":"Cleanup temp files"},
    "/slash":{"syntax":"/slash <create|test|show|delete> <name> [args]","desc":"Create/manage custom commands",
      "format_only_ex":["/slash create <name> <description>","/slash run <name> <args>"],
      "fill":{"<name>":"short hyphenated command name","<description>":"what the command should do","<args>":"runtime arguments"}}
  }
},
"WORKFLOW PATTERNS":[
  {"pattern":"List files","flow":"/ls [path] [depth]"},
  {"pattern":"Read before edit","flow":"/ls -> /read <file> -> /edit or /write <file>"},
  {"pattern":"Review journal","flow":"/journal (read only)","wrong":"/write or /web search"},
  {"pattern":"Check social","flow":"/social discord read <channel>","wrong":"/web search 'discord'"},
  {"pattern":"Research topic","flow":"/recall <keywords> -> /web search <keywords> -> /web fetch <url>"},
  {"pattern":"Find images","flow":"/web scrape-images <url> -> /vision <image_url_from_images[]>","alt":"/web images <query> -> /vision <url>","wrong":"/web fetch <image_url>"},
  {"pattern":"Write then email","flow":"/web search -> /web fetch -> /write report.md -> /email send gmail addr s=Report b=report.md","note":"Multi-delivery: /write creates the artifact, /email delivers it. File paths in body= auto-expand to file contents — no /read step needed."},
  {"pattern":"Tune settings","flow":"/model <param> <value> or /limits <param> <value>"},
  {"pattern":"Present answer","flow":"After gathering info with TOOLS, use /respond to deliver the result"}
],
"COMMAND TYPES":{
  "TOOLS":"Commands that gather info or execute work: /web, /recall, /read, /ls, /build, /test, /fix, /init, /clone, /download, /vision, /github, /sandbox, /container, /secret, /vitals, /phone, /pgp, /git, /backup, /slash, /journal, bash",
  "DELIVERY":"Commands that present output to user: /respond (DEFAULT), /write, /save, /email, /social, /commit, /push",
  "RULE":"After using TOOLS commands to gather info, you MUST use a DELIVERY command to present the result. If no specific output format is required, use /respond.",
  "MULTI_DELIVERY":"A task may require MULTIPLE delivery commands across separate milestones (e.g., /write a report THEN /email it). Each honeydew item can use its own delivery command. Common chain: research -> /write report.md -> /social post discord general report.md (file contents auto-expand). File paths in /social, /email body, and /write text are automatically replaced with the file's contents."},
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
