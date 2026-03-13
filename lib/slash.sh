#!/bin/bash
# ── George: Slash Extensions (The Magnum Opus) ─────────────────
# Self-extending command system. George can create, test, edit,
# and run his own slash commands — using all of his existing tools
# including sandboxes, containers, phone, recall, LLM, and even
# other /slash commands (recursive composition).
#
# Storage: $LODGE_DIR/.george/slash/<name>.sh
# Template: each file defines slash_<name>() { ... }
# Execution: sourced into lodge context — full library access.
#
# From the rough ashlar to the perfect — this is the work.

[ -n "${_LIB_SLASH_LOADED:-}" ] && return 0; _LIB_SLASH_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

GEORGE_CONFIG_DIR="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}"
SLASH_DIR="${SLASH_DIR:-$GEORGE_CONFIG_DIR/slash}"

# ═══════════════════════════════════════════════════════════════
# Initialization
# ═══════════════════════════════════════════════════════════════

slash_init() {
    if [ ! -d "$SLASH_DIR" ]; then
        mkdir -p "$SLASH_DIR"
        ui_ok "Created slash extensions directory: $SLASH_DIR"
    fi
}

# ═══════════════════════════════════════════════════════════════
# List all custom slash commands
# ═══════════════════════════════════════════════════════════════

slash_list() {
    slash_init

    local found=0
    ui_section "Custom Slash Commands"

    for script in "$SLASH_DIR"/*.sh; do
        [ -f "$script" ] || continue
        found=1
        local name desc created
        name=$(basename "$script" .sh)
        desc=$(_slash_meta "$script" "Description")
        created=$(_slash_meta "$script" "Created")
        printf "  %b/slash %-18s%b %s\n" "$C_CYAN" "$name" "$C_RESET" "${desc:-No description}"
        if [ -n "$created" ]; then
            printf "  %b%-26s%b %bcreated %s%b\n" "" "" "" "$C_DIM" "$created" "$C_RESET"
        fi
    done

    if [ "$found" -eq 0 ]; then
        ui_dim "  No custom commands yet. Use /slash create <name> <description>"
    fi
    echo ""
}

# ═══════════════════════════════════════════════════════════════
# Show source code of a custom command
# ═══════════════════════════════════════════════════════════════

slash_show() {
    local name="$1"
    local script="$SLASH_DIR/${name}.sh"

    if [ ! -f "$script" ]; then
        ui_err "Custom command '$name' not found"
        ui_dim "Run /slash list to see available commands"
        return 1
    fi

    ui_section "Source: /slash $name"
    cat "$script"
    echo ""
}

# ═══════════════════════════════════════════════════════════════
# Delete a custom command
# ═══════════════════════════════════════════════════════════════

slash_delete() {
    local name="$1"
    local script="$SLASH_DIR/${name}.sh"

    if [ ! -f "$script" ]; then
        ui_err "Custom command '$name' not found"
        return 1
    fi

    if ui_confirm "Delete custom command '/slash $name'?" "n"; then
        rm -f "$script"
        # Unset the function if loaded
        unset -f "slash_${name}" 2>/dev/null
        ui_ok "Deleted: /slash $name"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Run (execute) a custom slash command
# ═══════════════════════════════════════════════════════════════

slash_run() {
    local name="$1"
    local args="$2"
    local workdir="${3:-.}"
    local script="$SLASH_DIR/${name}.sh"

    # Fallback: if file not found, try converting hyphens to underscores
    # (bash function names cannot contain hyphens)
    if [ ! -f "$script" ]; then
        local underscore_name="${name//-/_}"
        if [ "$underscore_name" != "$name" ] && [ -f "$SLASH_DIR/${underscore_name}.sh" ]; then
            name="$underscore_name"
            script="$SLASH_DIR/${name}.sh"
        else
            ui_err "Custom command '$name' not found"
            ui_dim "Run /slash list to see available commands"
            return 1
        fi
    fi

    # Source the script to load the function
    # shellcheck disable=SC1090
    source "$script"

    local func="slash_${name}"
    if ! declare -f "$func" &>/dev/null; then
        ui_err "Script exists but function '$func' not defined"
        ui_dim "Custom commands must define: $func() { ... }"
        return 1
    fi

    # Execute with full lodge context
    "$func" "$args" "$workdir"
}

# ═══════════════════════════════════════════════════════════════
# Test a custom command (syntax + dry run)
# ═══════════════════════════════════════════════════════════════

slash_test() {
    local name="$1"
    local args="${2:-}"
    local script="$SLASH_DIR/${name}.sh"

    if [ ! -f "$script" ]; then
        ui_err "Custom command '$name' not found"
        return 1
    fi

    ui_section "Testing: /slash $name"

    # 1. Syntax check
    ui_step "Syntax check..."
    local syntax_out
    syntax_out=$(bash -n "$script" 2>&1)
    if [ $? -ne 0 ]; then
        ui_err "Syntax error:"
        echo "$syntax_out"
        return 1
    fi
    ui_ok "Syntax OK"

    # 2. Function definition check
    ui_step "Loading function..."
    (
        # Subshell so we don't pollute the main session
        source "$LODGE_DIR/lib/ui.sh"
        # shellcheck disable=SC1090
        source "$script"
        local func="slash_${name}"
        if ! declare -f "$func" &>/dev/null; then
            echo "FAIL: function '$func' not defined"
            exit 1
        fi
        echo "OK: $func is defined"
    )
    if [ $? -ne 0 ]; then
        ui_err "Function load failed"
        return 1
    fi
    ui_ok "Function loaded"

    # 3. Dry run (if args provided)
    if [ -n "$args" ]; then
        ui_step "Dry run: /slash $name $args"
        slash_run "$name" "$args" "."
        local rc=$?
        if [ "$rc" -eq 0 ]; then
            ui_ok "Dry run succeeded"
        else
            ui_warn "Dry run exited with code $rc"
        fi
    fi

    echo ""
    ui_ok "Test complete for /slash $name"
}

# ═══════════════════════════════════════════════════════════════
# Create a new custom command via LLM generation
# ═══════════════════════════════════════════════════════════════

slash_create() {
    local name="$1"
    local description="$2"

    if [ -z "$name" ]; then
        ui_err "Usage: /slash create <name> <description>"
        return 1
    fi

    # Sanitize name — alphanumeric and underscores only.
    # Hyphens are converted to underscores because bash function names
    # cannot contain hyphens (slash_my-cmd() is invalid bash syntax).
    local safe_name
    safe_name=$(echo "$name" | sed 's/[^a-zA-Z0-9_-]//g; s/-/_/g')
    if [ "$safe_name" != "$name" ]; then
        ui_warn "Sanitized name: '$name' → '$safe_name'"
        name="$safe_name"
    fi

    if [ -z "$name" ]; then
        ui_err "Invalid command name"
        return 1
    fi

    slash_init

    local script="$SLASH_DIR/${name}.sh"
    if [ -f "$script" ]; then
        ui_warn "Command '/slash $name' already exists"
        if ! ui_confirm "Overwrite?" "n"; then
            return 1
        fi
    fi

    if [ -z "$description" ]; then
        ui_info "No description provided — creating template for manual editing"
        _slash_write_template "$name" "Custom command" "$script"
        ui_ok "Template created: $script"
        ui_dim "Edit the file and fill in the function body."
        return 0
    fi

    # ── LLM-assisted generation ────────────────────────────────
    ui_section "Creating: /slash $name"
    ui_info "\"$description\""
    echo ""

    # Check if LLM is available
    if ! declare -f llm_stream &>/dev/null; then
        ui_warn "LLM not available — creating template instead"
        _slash_write_template "$name" "$description" "$script"
        ui_ok "Template created: $script"
        return 0
    fi

    # Build the generation prompt
    local sys_prompt
    sys_prompt=$(_slash_system_prompt "$name" "$description")

    local user_prompt="Write a bash slash command called 'slash_${name}' that does the following:
$description

Output ONLY the complete bash script as a single code block. No explanation before or after."

    ui_step "George is writing the command..."
    local response
    local LLM_SCENARIO=tool

    # ── Provider-aware generation ──────────────────────────────
    # When a cloud provider is active, use llm_generate (non-streaming)
    # instead of llm_stream. The response is captured into a variable
    # anyway, so streaming provides no user benefit. More importantly,
    # the provider streaming path (FIFO + SSE loop + sync fallback)
    # can hang or time out slowly on rate-limited free tiers, leaving
    # the user stuck for minutes.  llm_generate through the provider
    # makes a single synchronous POST with a hard --max-time, which
    # is more reliable for code generation.
    if [ -n "${GEORGE_PROVIDER:-}" ]; then
        response=$(llm_generate "$user_prompt" "$sys_prompt" 1024 "$LLM_BUDGET_TOOL")
    else
        response=$(llm_stream "$user_prompt" "$sys_prompt" 1024 "$LLM_BUDGET_TOOL")
    fi
    echo ""

    # Extract bash code from the response
    local code
    code=$(_slash_extract_code "$response")

    if [ -z "$code" ]; then
        ui_warn "Could not extract code from LLM response"
        ui_dim "Creating template instead — you can edit manually"
        _slash_write_template "$name" "$description" "$script"
        return 1
    fi

    # ── Ensure header is present ───────────────────────────────
    if ! echo "$code" | grep -q "^#!/bin/bash" ; then
        code="#!/bin/bash
$code"
    fi

    # ── Ensure metadata header ─────────────────────────────────
    if ! echo "$code" | grep -q "^# Description:" ; then
        local header
        header=$(_slash_header "$name" "$description")
        code=$(echo "$code" | sed "1 a\\
$header")
    fi

    # Write the file
    echo "$code" > "$script"
    chmod +x "$script"

    # ── Validate ───────────────────────────────────────────────
    ui_step "Validating syntax..."
    local syntax_err
    syntax_err=$(bash -n "$script" 2>&1)
    if [ $? -ne 0 ]; then
        ui_err "Syntax error in generated code:"
        echo "$syntax_err"
        ui_dim "File saved anyway: $script"
        ui_dim "Fix it manually or run /slash edit $name"
        return 1
    fi
    ui_ok "Syntax valid"

    # ── Check function exists ──────────────────────────────────
    ui_step "Checking function definition..."
    local func_check
    func_check=$(bash -c "source '$script' 2>/dev/null && declare -f 'slash_${name}' &>/dev/null && echo OK || echo FAIL")
    if [ "$func_check" != "OK" ]; then
        ui_warn "Function 'slash_${name}' not found in generated code"
        ui_dim "File saved: $script — edit to add the function"
        return 1
    fi
    ui_ok "Function 'slash_${name}' defined"

    echo ""
    ui_ok "Created: /slash $name"
    ui_dim "  Run:  /slash $name [args]"
    ui_dim "  Test: /slash test $name"
    ui_dim "  View: /slash show $name"
    ui_dim "  Edit: /slash edit $name"
}

# ═══════════════════════════════════════════════════════════════
# Edit an existing command (re-generate or manual)
# ═══════════════════════════════════════════════════════════════

slash_edit() {
    local name="$1"
    local new_description="$2"
    local script="$SLASH_DIR/${name}.sh"

    if [ ! -f "$script" ]; then
        ui_err "Custom command '$name' not found"
        return 1
    fi

    if [ -n "$new_description" ]; then
        # Re-generate with new description
        ui_info "Re-generating /slash $name with new description..."
        slash_create "$name" "$new_description"
    else
        # Show the file path for manual editing
        ui_section "Edit: /slash $name"
        ui_info "File: $script"
        ui_dim "Edit the file directly, then run /slash test $name"
        echo ""
        cat "$script"
        echo ""
    fi
}

# ═══════════════════════════════════════════════════════════════
# Export a command (copy to a standalone script)
# ═══════════════════════════════════════════════════════════════

slash_export() {
    local name="$1"
    local dest="${2:-./slash_${name}.sh}"
    local script="$SLASH_DIR/${name}.sh"

    if [ ! -f "$script" ]; then
        ui_err "Custom command '$name' not found"
        return 1
    fi

    cp "$script" "$dest"
    chmod +x "$dest"
    ui_ok "Exported: $dest"
}

# ═══════════════════════════════════════════════════════════════
# Catalog of custom commands (for LLM prompt injection)
# ═══════════════════════════════════════════════════════════════

slash_catalog() {
    local catalog=""
    local count=0

    for script in "$SLASH_DIR"/*.sh; do
        [ -f "$script" ] || continue
        local name desc
        name=$(basename "$script" .sh)
        desc=$(_slash_meta "$script" "Description")
        catalog="${catalog}/slash ${name} — ${desc:-Custom command}
"
        count=$((count + 1))
    done

    if [ "$count" -gt 0 ]; then
        echo "--- YOUR CUSTOM COMMANDS ---"
        echo "These are commands you (George) created. They are your own Magnum Opus."
        echo "$catalog"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Rename a custom command
# ═══════════════════════════════════════════════════════════════

slash_rename() {
    local old_name="$1"
    local new_name="$2"

    if [ -z "$old_name" ] || [ -z "$new_name" ]; then
        ui_err "Usage: /slash rename <old_name> <new_name>"
        return 1
    fi

    local old_script="$SLASH_DIR/${old_name}.sh"
    local new_script="$SLASH_DIR/${new_name}.sh"

    if [ ! -f "$old_script" ]; then
        ui_err "Custom command '$old_name' not found"
        return 1
    fi

    if [ -f "$new_script" ]; then
        ui_err "Command '$new_name' already exists"
        return 1
    fi

    # Update the function name inside the script
    sed -i "s/slash_${old_name}/slash_${new_name}/g" "$old_script"
    mv "$old_script" "$new_script"
    unset -f "slash_${old_name}" 2>/dev/null

    ui_ok "Renamed: /slash $old_name → /slash $new_name"
}

# ═══════════════════════════════════════════════════════════════
# Internal helpers
# ═══════════════════════════════════════════════════════════════

# ── Extract metadata from a script header ──────────────────────
_slash_meta() {
    local file="$1"
    local key="$2"
    grep "^# ${key}:" "$file" 2>/dev/null | head -1 | sed "s/^# ${key}: *//"
}

# ── Write a template script ───────────────────────────────────
_slash_write_template() {
    local name="$1"
    local description="$2"
    local dest="$3"
    local now
    now=$(date '+%Y-%m-%d %H:%M')

    cat > "$dest" << TEMPLATE
#!/bin/bash
# ── Slash Extension: $name ─────────────────────────────────────
# Description: $description
# Created: $now
# Author: George
# Version: 1
#
# This is a George-authored slash command. It has full access to
# all lodge libraries: recall, phone, sandbox, container, social,
# pgp, wallet, web, llm, and other /slash commands.
#
# Available functions:
#   commands_dispatch "/recall query"  — Invoke base commands
#   slash_run "other_cmd" "args"       — Invoke other /slash commands
#   llm_stream "prompt" "system" 512   — Call the LLM
#   phone_location_context             — Get GPS location
#   phone_sms_list "inbox" 5           — Read texts
#   sandbox_exec "name" "command"      — Run in sandbox
#   recall_search "query"              — Search knowledge base
#   ui_info/ui_ok/ui_err/ui_warn       — Output formatting

slash_${name}() {
    local args="\$1"
    local workdir="\${2:-.}"

    # TODO: Implement your command here
    ui_info "Hello from /slash $name!"
    ui_dim "Args: \$args"
}
TEMPLATE
    chmod +x "$dest"
}

# ── Generate metadata header string ───────────────────────────
_slash_header() {
    local name="$1"
    local description="$2"
    local now
    now=$(date '+%Y-%m-%d %H:%M')
    echo "# ── Slash Extension: $name
# Description: $description
# Created: $now
# Author: George
# Version: 1"
}

# ── Extract bash code from LLM response ──────────────────────
_slash_extract_code() {
    local response="$1"

    # Try to extract from ```bash ... ``` block
    local code
    code=$(echo "$response" | awk '
        /^```bash/ || /^```sh/ { in_block=1; next }
        /^```/                 { if (in_block) { in_block=0; next } }
        in_block               { print }
    ')

    # Fallback: try any ``` block
    if [ -z "$code" ]; then
        code=$(echo "$response" | awk '
            /^```/ { 
                if (in_block) { in_block=0; next }
                in_block=1; next
            }
            in_block { print }
        ')
    fi

    # Fallback: if no code blocks, try the whole response
    # (some models output raw code without fences)
    if [ -z "$code" ]; then
        if echo "$response" | grep -q "slash_"; then
            code="$response"
        fi
    fi

    echo "$code"
}

# ── Build the system prompt for LLM code generation ───────────
# Two tiers: compact (~500 tokens) for small local models,
# full (~2200 tokens) for cloud providers / large models.
_slash_system_prompt() {
    local name="$1"
    local description="$2"
    local real_date
    real_date=$(date '+%Y-%m-%d %H:%M')

    if [ -n "${GEORGE_PROVIDER:-}" ]; then
        _slash_system_prompt_full "$name" "$description" "$real_date"
    else
        _slash_system_prompt_compact "$name" "$description" "$real_date"
    fi
}

# ── Compact prompt for small local models (2-4B) ─────────────
_slash_system_prompt_compact() {
    local name="$1" description="$2" real_date="$3"

    cat << SYSPROMPT_C
You are George, writing a bash slash command.
Output ONLY a bash script. No explanation.

RULES:
- Start with #!/bin/bash
- Header: # Description, # Created: $real_date, # Author: George, # Version: 1.0
- One function: slash_${name}() { local args="\$1"; local workdir="\${2:-.}"; ... }
- NO HYPHENS in function names — underscores only
- Use 'local' for all variables
- Use ui_info/ui_ok/ui_err/ui_warn/ui_step/ui_dim for output
- Under 80 lines. Single purpose.

AVAILABLE FUNCTIONS (already loaded):
  ui_info "msg"   ui_ok "msg"   ui_err "msg"   ui_warn "msg"   ui_step "msg"
  llm_generate "prompt" "system"        — call LLM
  recall_search_context "query" 3       — search knowledge base
  journal_write "text"                  — write to journal
  journal_read 5                        — read last N entries
  web_search "query"                    — search the web
  sandbox_exec "name" "cmd"             — run in sandbox
  phone_location_context                — GPS location
  commands_dispatch "/cmd args" "."     — run a base command
  slash_run "name" "args" "dir"         — run another /slash command
  cache_get "key"                       — read cache
  cache_put "key" "val" ttl             — write cache
SYSPROMPT_C
}

# ── Full prompt for cloud providers / large models ────────────
_slash_system_prompt_full() {
    local name="$1" description="$2" real_date="$3"

    cat << SYSPROMPT_F
You are George, writing a new bash slash command for your lodge system.
Write a complete, working bash script that defines the function slash_${name}().

IMPORTANT — REAL TIME CLOCK:
The current date and time is: $real_date
Use this EXACT date in any Created header. Do NOT make up a date.

REQUIREMENTS:
1. Start with #!/bin/bash
2. Header comment: Description, Created ($real_date), Author (George), Version
3. Define exactly one function: slash_${name}()
4. Signature: slash_${name}() { local args="\$1"; local workdir="\${2:-.}"; ... }
5. NO HYPHENS in function names — underscores only
6. Use 'local' for all variables
7. Use ui_info, ui_ok, ui_err, ui_warn, ui_step, ui_dim for output
8. Under 80 lines. Single purpose.

ARCHITECTURE:
You are a bash AI agent (strategist → router → specialist loop).
- Codebase: \$LODGE_DIR (~/blue-lodge)
- Config: \$GEORGE_CONFIG_DIR (~/.george)
- Custom commands: \$SLASH_DIR (~/.george/slash/)
- Recall DB (FTS5 SQLite), journal, sandbox, MCP tools
- Runs on llamacpp (local) or cloud providers (groq, google, openai, etc.)
- Agent loop already handles retry, backoff, rate limits, dispatch
  — do NOT reinvent these in a slash command

SELF-MODIFICATION:
You can create commands that inspect and tune your own behaviour.
Hyperparameters (read/modify at runtime):
  AGENT_MAX_STEPS (40)     AGENT_PLAN_STEPS (6)    AGENT_INNER_LOOPS (6)
  AGENT_SMART_ROUTE (0-3)  AGENT_BRAINSTORM (0/1)  AGENT_PRESSURE_RELIEF (0-3)
  AGENT_HONEYDEW_EXPAND    AGENT_HONEYDEW_REWRITE   AGENT_EVAL_MODE
  LLM_TEMPERATURE (0.15)   LLM_REPEAT_PENALTY (1.2) LLM_TOP_P (0.9)
  LLM_TOP_K (40)           LLM_MAX_TOKENS (20480)   LLM_BUDGET_TOKENS
  GEORGE_PROVIDER           PROVIDER_TIMEOUT (120)   PROVIDER_CALL_DELAY (7)
Self-audit:
  cat "\$LODGE_DIR/lib/agent.sh"    — read your own code
  bash -n "\$LODGE_DIR/lib/foo.sh"  — syntax-check a library
  grep -rn "pattern" "\$LODGE_DIR/" — search your codebase

AVAILABLE LIBRARIES (already loaded):
  # UI
  ui_info "msg"   ui_ok "msg"   ui_err "msg"   ui_warn "msg"
  ui_step "msg"   ui_dim "msg"  ui_section "t"  ui_divider

  # Base commands
  commands_dispatch "/recall query" "."     commands_dispatch "/web search q" "."
  commands_dispatch "/social post m" "."    commands_dispatch "/phone where" "."

  # LLM
  llm_generate "prompt" "system" max_tokens — sync call
  llm_stream "prompt" "system" max_tokens   — streaming call
  llm_chat "messages_json" "system"         — multi-turn

  # Recall & memory
  recall_search "query"              recall_search_context "query" 3
  journal_write "text"               journal_read 5
  memory_read_project "dir"

  # Phone
  phone_location_context             phone_sms_list "inbox" 10
  phone_status_context

  # Sandbox
  sandbox_create "name" "shell"      sandbox_exec "name" "cmd"
  sandbox_build "name"               sandbox_test "name"

  # Git
  git_status_overview                mcp_git_diff     mcp_git_log
  mcp_git_commit "msg"               mcp_git_push

  # Web & HTTP
  web_fetch "url"    web_search "q"  web_summary "url"
  api_get "url"      api_post "url" "data"

  # Cache / Email / Containers / Wallets / Vitals
  cache_get "key"    cache_put "key" "val" ttl
  email_send "to" "subj" "body"
  container_exec "name" "cmd"        container_list
  btc_balance        sol_balance     wallet_balances
  vitals_dashboard   vitals_disk_free_mb   vitals_battery_pct

  # MCP & slash composition
  mcp_tool_call "server" "tool" args   mcp_catalog_list
  slash_run "cmd" "args" "dir"

EXAMPLES:
  # Good: single purpose, uses existing libraries
  slash_morning_briefing() {
      local args="\$1"; local workdir="\${2:-.}"
      local loc=\$(phone_location_context)
      local weather=\$(web_search "weather \$loc today" | head -5)
      llm_generate "Briefing. Location: \$loc. Weather: \$weather." "Concise assistant."
  }

  # Good: self-audit tool
  slash_codesize() {
      local args="\$1"; local workdir="\${2:-.}"
      ui_section "Lodge Codebase Audit"
      ui_info "Libraries: \$(ls "\$LODGE_DIR/lib/"*.sh | wc -l) files, \$(wc -l "\$LODGE_DIR/lib/"*.sh | tail -1 | awk '{print \$1}') lines"
      [ -n "\${args:-}" ] && grep -rn "\$args" "\$LODGE_DIR/lib/" | head -20
  }

  # Bad: reinvents retry — DON'T do this
  # slash_retry() { while ...; do sleep 5; done }

Output ONLY the bash script. No explanation.
SYSPROMPT_F
}
