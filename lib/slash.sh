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
    response=$(llm_stream "$user_prompt" "$sys_prompt" 1024 "$LLM_BUDGET_TOOL")
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
_slash_system_prompt() {
    local name="$1"
    local description="$2"
    local real_date
    real_date=$(date '+%Y-%m-%d %H:%M')

    cat << SYSPROMPT
You are George, writing a new bash slash command for your lodge system.
Write a complete, working bash script that defines the function slash_${name}().

IMPORTANT — REAL TIME CLOCK:
The current date and time is: $real_date
Use this EXACT date in any Created header. Do NOT make up a date.

REQUIREMENTS:
1. Start with #!/bin/bash
2. Include a header comment with: Description, Created date (use $real_date), Author (George), Version
3. Define exactly one function: slash_${name}()
4. The function signature: slash_${name}() { local args="\$1"; local workdir="\${2:-.}"; ... }
5. CRITICAL: Bash function names can ONLY contain letters, digits, and underscores.
   NO HYPHENS in function names. "slash_my-cmd()" is INVALID bash — use "slash_my_cmd()".
6. Use 'local' for all variables inside the function
7. Handle errors gracefully — check inputs, validate before acting
8. Use ui_info, ui_ok, ui_err, ui_warn, ui_step, ui_dim for all user-facing output
9. Keep it under 80 lines
10. This is a SINGLE-PURPOSE tool. Do NOT embed an entire project plan or workflow.
    The command should do ONE thing well.

AVAILABLE LODGE LIBRARIES (already loaded, call directly):
  # Output / UI
  ui_info "msg"              ui_ok "msg"           ui_err "msg"
  ui_warn "msg"              ui_step "msg"          ui_dim "msg"
  ui_section "title"         ui_divider

  # Base slash commands (invoke via commands_dispatch)
  commands_dispatch "/recall query" "."        — Search knowledge base
  commands_dispatch "/web search query" "."    — Web search
  commands_dispatch "/social post msg" "."     — Post to social media
  commands_dispatch "/pgp sign msg" "."        — PGP sign a message
  commands_dispatch "/phone where" "."         — Get location

  # Direct library functions
  llm_stream "prompt" "system_prompt" max_tokens   — Call the LLM
  llm_generate "prompt" "system_prompt"            — Non-streaming LLM call
  recall_search "query"              — FTS5 search (returns JSON)
  recall_search_context "query" 3    — Get top 3 relevant chunks
  phone_location_context             — Compact location string
  phone_sms_list "inbox" 10          — Read text messages
  phone_status_context               — Battery + WiFi + Location
  sandbox_create "name" "shell"      — Create a sandbox
  sandbox_exec "name" "command"      — Run in sandbox
  journal_write "text"               — Write to journal
  memory_read_project "dir"          — Read project memory

  # Other /slash commands (recursive!)
  slash_run "command_name" "args" "workdir"   — Run another custom command

STYLE:
- Concise, idiomatic bash
- Error messages start with the command name for clarity
- Use jq for JSON parsing if needed
- Prefer built-in commands over raw curl/wget

Output ONLY the bash script. No explanation.
SYSPROMPT
}
