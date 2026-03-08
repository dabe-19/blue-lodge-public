# Command Dispatch & Extensions

> How slash commands are registered, routed, and dispatched — plus the slash extension system for user-created commands.

---

## Table of Contents

- [Design Philosophy](#design-philosophy)
- [Command Registration](#command-registration)
- [The Dispatch Pipeline](#the-dispatch-pipeline)
- [Auto-Route Detection](#auto-route-detection)
- [Dynamic Command Loading](#dynamic-command-loading)
- [The Command Catalog](#the-command-catalog)
- [Service Availability Checking](#service-availability-checking)
- [Slash Extensions](#slash-extensions)
- [The REPL Loop](#the-repl-loop)
- [Troubleshooting](#troubleshooting)
- [Key Functions Reference](#key-functions-reference)

---

## Design Philosophy

The command system is designed around two principles:

1. **Convention over configuration** — Commands follow a naming convention (`cmd_${name}()` in `${name}.sh`) that makes registration automatic
2. **LLM-friendly catalog** — The command list is serialized into a compact JSON format that fits in a 4B model's context window (~900 tokens)

The system supports three command sources:
- **Built-in** commands (registered via `commands_register()` in lib files)
- **Script commands** (standalone `.sh` files in `commands/`)
- **Slash extensions** (user-created commands in `.george/slash/`)

---

## Command Registration

### Associative Array Registry

Commands are stored in two parallel associative arrays:

```bash
declare -A CMD_REGISTRY     # name → handler function
declare -A CMD_DESC         # name → description string
```

### `commands_register()`

```bash
commands_register() {
    local name="$1"       # "web"
    local handler="$2"    # "_cmd_web"
    local desc="$3"       # "Fetch, search, and scrape web pages"

    CMD_REGISTRY["$name"]="$handler"
    CMD_DESC["$name"]="$desc"
}
```

**Bash Technique — Associative Arrays**: Declared with `declare -A`, these are bash's hash maps. Keys are command names, values are function names or descriptions. Lookup is O(1).

### Registration Happens at Source Time

Each library registers its commands when sourced:

```bash
# In lib/web.sh:
commands_register "web" "_cmd_web" "Fetch, search, and scrape web pages"

# In lib/social.sh:
commands_register "social" "_cmd_social" "Post to X, Mastodon, Bluesky, Discord, Telegram"
```

By the time the REPL starts, all commands are registered.

---

## The Dispatch Pipeline

### `commands_dispatch()`

```bash
commands_dispatch() {
    local input="$1"

    # Strip leading /
    input="${input#/}"

    # Split into command name and arguments
    local cmd="${input%% *}"
    local args="${input#"$cmd"}"
    args="${args# }"    # Trim leading space

    # Priority 1: Built-in commands
    if [[ "$cmd" == "help" ]]; then
        commands_help "$args"
        return 0
    fi
    if [[ "$cmd" == "quit" ]] || [[ "$cmd" == "exit" ]]; then
        return 255  # Special exit code
    fi

    # Priority 2: Registered commands (associative array)
    if [[ -n "${CMD_REGISTRY[$cmd]:-}" ]]; then
        local handler="${CMD_REGISTRY[$cmd]}"
        "$handler" "$args"
        return $?
    fi

    # Priority 3: Script commands (commands/*.sh)
    local script="${LODGE_COMMANDS_DIR}/${cmd}.sh"
    if [[ -f "$script" ]]; then
        source "$script"
        if declare -f "cmd_${cmd}" &>/dev/null; then
            "cmd_${cmd}" "$args"
            return $?
        fi
    fi

    # Priority 4: Slash extensions (.george/slash/*.sh)
    if slash_run "$cmd" "$args" 2>/dev/null; then
        return $?
    fi

    ui_err "Unknown command: /$cmd"
    return 127
}
```

**Bash Technique — `declare -f` Check**: `declare -f function_name &>/dev/null` tests whether a function exists without calling it. This is used to verify that `cmd_${name}()` was defined after sourcing the script.

### Return Code Semantics

| Code | Meaning |
|------|---------|
| 0 | Command succeeded |
| 1 | Command failed (generic error) |
| 127 | Unknown command (not found) |
| 255 | Exit request (quit/exit) |

---

## Auto-Route Detection

### The Problem

Users often type commands without the `/` prefix:

```
george> model temp 0.3         ← Should this be /model temp 0.3?
george> read the documentation ← Should this be /read the documentation?
```

The auto-router must distinguish between:
- **Command intent**: `model temp 0.3` → `/model temp 0.3` (safe to route)
- **Natural language**: `read the documentation` → NOT `/read` (ambiguous)

### `commands_is_safe_auto_route()`

```bash
commands_is_safe_auto_route() {
    local input="$1"
    local first_word="${input%% *}"

    # Single-word input is always safe to auto-route
    [[ "$input" == "$first_word" ]] && {
        commands_is_known_name "$first_word" && return 0
    }

    # Multi-word: block ambiguous verbs
    local -a ambiguous=(
        read write test build fix save plan ask push commit
        clone download model think debug config backend
    )

    for verb in "${ambiguous[@]}"; do
        [[ "$first_word" == "$verb" ]] && return 1  # Don't auto-route
    done

    # Not ambiguous? Check if it's a known command
    commands_is_known_name "$first_word" && return 0

    return 1
}
```

**Why these verbs are blocked**: `read`, `write`, `test`, `build`, `fix`, `save`, `plan`, `ask`, `push`, `commit` — all have natural language meanings. `"read the docs"` shouldn't become `/read the docs` (which tries to open a file named "the"). But `"model temp 0.3"` is unambiguously a command because "model" isn't a common English verb.

---

## Dynamic Command Loading

### Script-Based Commands

Files in `commands/` follow the naming convention `${name}.sh` with a `cmd_${name}()` function:

```bash
# commands/build.sh
cmd_build() {
    local args="$1"
    sandbox_build "$args"
}
```

### `commands_load_all()`

```bash
commands_load_all() {
    local dir="$LODGE_COMMANDS_DIR"
    [[ -d "$dir" ]] || return 0

    for script in "$dir"/*.sh; do
        [[ -f "$script" ]] || continue
        source "$script"
    done
}
```

This is called once at startup. Scripts are sourced into the main shell, making their functions available for the session.

---

## The Command Catalog

### `commands_catalog()`

Returns a JSON structure with all command syntax, designed for LLM injection:

```json
{
    "SYSTEM_CAPABILITIES": {
        "/backend": {"syntax": "/backend [ollama|llamacpp|show|url]", "desc": "Switch LLM backend"},
        "/model": {"syntax": "/model [temp|repeat|presence|top-p|top-k] [value]", "desc": "Adjust sampling"}
    },
    "PROJECT_&_CODE": {
        "/sandbox": {"syntax": "/sandbox [new|build|test|run|cd|rm] [name] [type]", "desc": "Project management"},
        "/save": {"syntax": "/save <filepath> <content>", "desc": "Write file"},
        "/read": {"syntax": "/read <filepath>", "desc": "Read file contents"}
    },
    "RESEARCH": {
        "/web": {"syntax": "/web [search|fetch|scrape-images|summary] <query|url>", "desc": "Web research"},
        "/recall": {"syntax": "/recall <query>", "desc": "Search knowledge base"}
    }
}
```

This catalog is ~900 tokens — compact enough for a 4B model's context window while comprehensive enough for accurate routing.

### Dynamic Service Splicing

The catalog dynamically includes configured services:

```bash
commands_catalog() {
    local catalog="..."
    local services
    services=$(commands_services_status)
    # Splice service availability into catalog
    catalog="${catalog/SERVICES_STATUS/$services}"
    echo "$catalog"
}
```

---

## Service Availability Checking

### `commands_services_status()`

Returns a compact string telling the LLM which services are configured:

```bash
commands_services_status() {
    local configured="" not_configured=""

    # Check each service key
    [[ -n "$(api_get_key DISCORD_BOT_TOKEN 2>/dev/null)" ]] && \
        configured+="discord, " || not_configured+="discord, "

    [[ -n "$(api_get_key TELEGRAM_BOT_TOKEN 2>/dev/null)" ]] && \
        configured+="telegram, " || not_configured+="telegram, "

    # ... check X, Mastodon, email, etc ...

    # Mastodon: query SQLite directly (no UI output)
    if sqlite3 "$MASTODON_DB" "SELECT COUNT(*) FROM instances" 2>/dev/null | grep -q '[1-9]'; then
        configured+="mastodon, "
    else
        not_configured+="mastodon, "
    fi

    echo "CONFIGURED: ${configured%, }"
    echo "NOT CONFIGURED: ${not_configured%, }"
}
```

**Why this matters**: Without service status, the router might pick `/social x post "hello"` when X isn't configured, wasting an LLM call and an execution attempt. By injecting availability into the router prompt, the LLM avoids unconfigured services.

---

## Slash Extensions

### Architecture

User-created commands live in `.george/slash/` as bash scripts:

```
.george/slash/
├── greet.sh       →  slash_greet()
├── deploy.sh      →  slash_deploy()
└── lint_code.sh   →  slash_lint_code()
```

### Creating Extensions (`slash_create`)

Extensions can be created via LLM generation or from a template:

```bash
slash_create() {
    local name="$1" description="$2"

    # Sanitize name: hyphens → underscores (bash functions can't have hyphens)
    local safe_name="${name//-/_}"
    if [[ "$safe_name" != "$name" ]]; then
        ui_warn "Renamed '$name' to '$safe_name' (bash functions can't have hyphens)"
    fi

    # Try LLM generation
    if llm_check >/dev/null 2>&1; then
        local code
        code=$(llm_generate "$(_slash_system_prompt)" "Create a command named '$safe_name': $description")
        code=$(_slash_extract_code "$code")

        # Validate syntax
        if bash -n <<< "$code" 2>/dev/null; then
            # Validate function exists
            if (bash -c "source /dev/stdin; declare -f slash_${safe_name}" <<< "$code") &>/dev/null; then
                echo "$code" > "${SLASH_DIR}/${safe_name}.sh"
                return 0
            fi
        fi
    fi

    # Fallback: write template
    _slash_write_template "$safe_name" "$description"
}
```

**Bash Technique — `bash -n`**: The `-n` flag makes bash check syntax without executing. This catches parse errors (missing quotes, unbalanced braces) before the generated code is saved.

**Bash Technique — Subshell Function Check**: `(bash -c "source /dev/stdin; declare -f slash_${name}")` sources the code in an isolated subshell, then checks if the expected function was defined. This verifies both syntax and correct function naming without polluting the current session.

### Running Extensions (`slash_run`)

```bash
slash_run() {
    local name="$1" args="$2"
    local script="${SLASH_DIR}/${name}.sh"

    [[ -f "$script" ]] || return 127

    # Source the script (makes function available)
    source "$script"

    # Call the function
    local func="slash_${name}"
    if declare -f "$func" &>/dev/null; then
        "$func" "$args"
        return $?
    fi

    ui_err "Script $script doesn't define function $func()"
    return 1
}
```

**Full Lodge Context**: Because the script is sourced (not executed in a subprocess), slash extensions have access to ALL library functions — `llm_generate()`, `web_fetch()`, `ui_info()`, etc.

### Extension Metadata

Each script stores metadata in header comments:

```bash
#!/bin/bash
# Description: Deploy the current project to production
# Created: 2026-03-08 14:30
# Author: George
# Version: 1.0

slash_deploy() {
    # Implementation...
}
```

```bash
_slash_meta() {
    local file="$1" key="$2"
    grep "^# ${key}:" "$file" | sed "s/^# ${key}:[[:space:]]*//"
}
```

### Extension Catalog

For LLM injection, extensions are serialized compactly:

```bash
slash_catalog() {
    local catalog=""
    for script in "$SLASH_DIR"/*.sh; do
        [[ -f "$script" ]] || continue
        local name=$(basename "$script" .sh)
        local desc=$(_slash_meta "$script" "Description")
        catalog+="/$name — ${desc:-custom command}\n"
    done
    echo "$catalog"
}
```

This is spliced into the router's command catalog so the LLM knows about user-defined commands.

---

## The REPL Loop

### `_repl()`

The main interactive loop in the `lodge` entry point:

```bash
_repl() {
    while true; do
        ui_prompt    # "🏛 george > "
        local input
        read -e input    # -e enables readline editing
        [[ -z "$input" ]] && continue

        # Save to history
        history -s "$input"

        # Health check (auto-restart backend if dead)
        llm_repl_health_check || {
            ui_err "No LLM backend available"
            continue
        }

        # Dispatch
        if commands_is_command "$input"; then
            # Explicit /command
            commands_dispatch "$input"
        elif commands_is_safe_auto_route "$input"; then
            # Auto-prefix /
            commands_dispatch "/$input"
        else
            # Natural language → agent
            agent_run "$input"
        fi

        local rc=$?
        [[ $rc -eq 255 ]] && break  # /quit
    done
}
```

**Bash Technique — `read -e`**: The `-e` flag enables readline, providing:
- Arrow key navigation
- History search (Ctrl+R)
- Line editing (Home, End, Ctrl+A, Ctrl+E)
- Tab completion (if configured)

### History Management

```bash
# At startup: load persistent history
history -r "$LODGE_HISTORY_FILE"

# Each command: append to in-memory history
history -s "$input"

# At exit: save to file
history -w "$LODGE_HISTORY_FILE"
```

**Bash Technique — `history -s`**: Adds a line to the in-memory history buffer without executing it. This means users can press Up to recall previous inputs, including natural language prompts.

### Health Check Pre-Dispatch

```bash
llm_repl_health_check() {
    # Quick health probe (2 second timeout)
    if llm_check 2>/dev/null; then
        return 0
    fi

    # Try to restart
    case "$_LLM_ACTIVE_BACKEND" in
        llamacpp)
            ui_warn "llama-server appears dead. Restarting..."
            _llm_start_llamacpp_server
            ;;
        ollama)
            ui_warn "Ollama not responding. Attempting start..."
            ollama serve &>/dev/null &
            sleep 2
            ;;
    esac

    # Verify restart worked
    llm_check 2>/dev/null
}
```

---

## Troubleshooting

### Command Not Found (127)

1. **Check registration**: Verify `CMD_REGISTRY` contains the command (`declare -p CMD_REGISTRY`)
2. **Check script exists**: Look for `commands/${name}.sh`
3. **Check function naming**: Script must define `cmd_${name}()`, not `${name}()` or something else
4. **Check sourcing order**: If the library containing the registration wasn't sourced, the command won't exist

### Auto-Route Triggering Wrongly

1. **Ambiguous verb list**: Check if the first word is in the ambiguous list in `commands_is_safe_auto_route()`
2. **Single-word exception**: Single-word input always routes if it matches a command name. This is intentional

### Slash Extension Not Running

1. **Function naming**: File `deploy.sh` must define `slash_deploy()` (not `cmd_deploy()` or `deploy()`)
2. **Syntax error**: Run `bash -n .george/slash/deploy.sh` to check
3. **Hyphen issue**: File `my-cmd.sh` requires function `slash_my_cmd()` (hyphens → underscores)
4. **Source error**: Check if the script has dependencies that aren't available

---

## Key Functions Reference

### Command Core (lib/commands.sh)

| Function | Purpose |
|----------|---------|
| `commands_register()` | Register command name → handler mapping |
| `commands_dispatch()` | Parse and route /command input |
| `commands_is_command()` | Test if input starts with / |
| `commands_is_known_name()` | Test if name exists in registry or commands/ |
| `commands_is_safe_auto_route()` | Guard against ambiguous verb auto-routing |
| `commands_help()` | List all commands with descriptions |
| `commands_load_all()` | Source all script commands |
| `commands_catalog()` | JSON catalog for LLM injection |
| `commands_services_status()` | Configured/unconfigured service report |

### Slash Extensions (lib/slash.sh)

| Function | Purpose |
|----------|---------|
| `slash_create()` | LLM-generate or template a new command |
| `slash_run()` | Source and execute a slash extension |
| `slash_test()` | Syntax check + function validation |
| `slash_edit()` | Re-generate with new description |
| `slash_list()` | Display all extensions with descriptions |
| `slash_show()` | Print source code |
| `slash_delete()` | Remove extension (with confirmation) |
| `slash_catalog()` | Compact list for LLM injection |

---

*Previous: [Agent Loop & Task Execution](AGENT_LOOP.md) | Next: [Memory, Recall & Journal](MEMORY_AND_RECALL.md)*
