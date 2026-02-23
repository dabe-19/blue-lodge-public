# Slash Extensions — The Magnum Opus

George can create his own slash commands. This is the self-extending
command system — the Great Work of the Craft. From the rough ashlar
of raw bash, George shapes his own perfect tools.

## Overview

The `/slash` command lets George:

1. **Create** new commands — either LLM-assisted or from a template
2. **Test** commands — syntax check, function validation, dry run
3. **Run** commands — with full access to all lodge libraries
4. **Compose** commands — custom commands can call base commands AND
   other custom commands (recursive composition)
5. **Manage** commands — edit, rename, delete, export

## Quick Start

```
/slash create weather Get the weather for my current GPS location
/slash test weather
/slash weather
/slash list
```

## Commands

```
/slash                        — List all custom commands
/slash create <name> <desc>   — Create via LLM (George writes the code)
/slash create <name>          — Create empty template for manual editing
/slash <name> [args]          — Run a custom command
/slash test <name> [args]     — Syntax check + function check + dry run
/slash show <name>            — View the source code
/slash edit <name> [new desc] — Edit or re-generate with new description
/slash delete <name>          — Delete a custom command
/slash rename <old> <new>     — Rename a command
/slash export <name> [path]   — Export as standalone script
/slash help                   — Show all subcommands
```

## How Creation Works

When George runs `/slash create weather Get the weather for my current
GPS location`, the system:

1. Sanitizes the command name (alphanumeric + hyphens + underscores)
2. Checks if the command already exists (asks to overwrite if so)
3. Builds a specialized system prompt telling the LLM:
   - The exact function signature required (`slash_weather()`)
   - All available lodge library functions
   - Output formatting rules (ui_info, ui_ok, etc.)
   - Error handling requirements
   - **The real current date/time** (injected via `date`) for the
     `Created:` header — George never hallucinates the date
4. Sends the description as the user prompt to the LLM
5. Extracts the bash code from the LLM response
6. Writes it to `~/.george/slash/weather.sh`
7. Validates with `bash -n` (syntax check)
8. Verifies the function definition exists
9. Reports success

If the LLM is unavailable, a template file is created instead.

## Storage

Custom commands are stored as executable bash scripts:

```
~/.george/slash/
├── weather.sh
├── standup.sh
├── deploy.sh
└── morning-briefing.sh
```

Each file has a standard header (date from real-time clock, never hallucinated):

```bash
#!/bin/bash
# ── Slash Extension: weather ───────────────────────────────────
# Description: Get the weather for my current GPS location
# Created: 2026-02-22 20:45
# Author: George
# Version: 1
```

And defines exactly one function:

```bash
slash_weather() {
    local args="$1"
    local workdir="${2:-.}"
    # ... implementation ...
}
```

## Available Libraries

Custom commands have full access to all lodge libraries because they
are sourced into the main lodge process. Available functions include:

### UI / Output
```
ui_info "msg"       ui_ok "msg"        ui_err "msg"
ui_warn "msg"       ui_step "msg"      ui_dim "msg"
ui_section "title"  ui_divider
```

### Base Slash Commands (via dispatch)
```bash
commands_dispatch "/recall docker setup" "."
commands_dispatch "/web search rust async" "."
commands_dispatch "/social post Hello world" "."
commands_dispatch "/pgp sign Important message" "."
commands_dispatch "/phone where" "."
```

### Direct Library Functions
```bash
llm_stream "prompt" "system" 512         # Call the LLM
llm_generate "prompt" "system"           # Non-streaming LLM
recall_search "query"                    # FTS5 search (JSON)
recall_search_context "query" 3          # Top 3 chunks
phone_location_context                   # "Location: 38.89° N, 77.03° W"
phone_sms_list "inbox" 10               # Read texts
phone_status_context                     # Battery + WiFi + GPS
sandbox_create "name" "shell"            # Create sandbox
sandbox_exec "name" "command"            # Run in sandbox
journal_write "text"                     # Write to journal
memory_read_project "dir"               # Read project memory
```

### Other Custom Commands (Recursive!)
```bash
slash_run "other_command" "args" "$workdir"
```

## Recursive Composition

This is where the Magnum Opus truly shines. Custom commands can call
other custom commands:

```bash
# ~/.george/slash/morning-briefing.sh
slash_morning-briefing() {
    local args="$1"
    local workdir="${2:-.}"

    ui_section "Morning Briefing"

    # Use phone for context
    local loc
    loc=$(phone_location_context)
    ui_info "$loc"

    # Run another custom command
    slash_run "weather" "" "$workdir"

    # Check texts
    commands_dispatch "/phone sms inbox 5" "$workdir"

    # Check calendar (if that command exists)
    if [ -f "$SLASH_DIR/calendar.sh" ]; then
        slash_run "calendar" "today" "$workdir"
    fi

    # Reflect
    journal_write "Morning briefing completed from $loc"
    ui_ok "Briefing complete"
}
```

## Catalog Injection

George's custom command catalog is automatically injected into his
system prompts alongside the base command catalog. When George plans
or executes a task, he sees:

```
--- YOUR WORKING COMMANDS ---
/recall <query>      — Search your knowledge base
/social post <text>  — Post to social media
...

--- YOUR CUSTOM COMMANDS ---
These are commands you (George) created. They are your own Magnum Opus.
/slash weather — Get the weather for my current GPS location
/slash standup — Generate a standup summary from recent journal entries
/slash deploy — Deploy the current project to production
```

This means George knows about his custom commands and can use them
in plans, just like any base command.

## Testing

The `/slash test <name>` command performs three checks:

1. **Syntax check** — `bash -n` validates the script has no syntax errors
2. **Function check** — verifies `slash_<name>()` is actually defined
3. **Dry run** — if args are provided, executes the command

```
/slash test weather sunny
```

## Editing

Two modes:

1. **Re-generate**: `/slash edit weather Get weather with 5-day forecast`
   — rewrites the command with a new description via LLM

2. **Manual**: `/slash edit weather`
   — shows the file path and current source for manual editing

## Architecture

```
User types: /slash weather
    │
    ▼
lodge REPL → commands_dispatch("/slash weather")
    │
    ▼
_cmd_slash("weather")
    │
    ▼
slash_run("weather", "", ".")
    │
    ├── source ~/.george/slash/weather.sh
    ├── call slash_weather("", ".")
    │     │
    │     ├── phone_location_context()     ← lodge library
    │     ├── llm_stream(...)              ← lodge library
    │     ├── commands_dispatch("/web ..")  ← base command
    │     └── slash_run("other_cmd", ..)   ← recursive!
    │
    └── return result
```

```
User types: /slash create weather <description>
    │
    ▼
_cmd_slash("create weather <description>")
    │
    ▼
slash_create("weather", "<description>")
    │
    ├── Build system prompt (template + available functions)
    ├── llm_stream(description, system_prompt, 1024)
    ├── _slash_extract_code(response)
    ├── Write to ~/.george/slash/weather.sh
    ├── bash -n validation
    ├── Function existence check
    └── Report success
```

## The Philosophy

The name "Magnum Opus" — the Great Work — comes from the alchemical
tradition that influenced Masonic philosophy. The Great Work is the
process of perfecting base materials into gold.

In George's case: base bash into perfect tools. Each custom command
is an act of creation. Each one extends George's capabilities beyond
what his original authors imagined. The craftsman who builds his own
tools is the craftsman who never stops growing.

As Franklin said: *"Without continual growth and progress, such words
as improvement, achievement, and success have no meaning."*

From the rough ashlar to the perfect — this is the work.
