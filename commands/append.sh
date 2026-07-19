#!/bin/bash
# DESC: Append content to end of an existing file
# Usage: /append <filepath> <content...>
#   Adds the given content to the end of the specified file.
#   Creates the file if it does not exist.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

cmd_append() {
    local args="$1"
    local workdir="${2:-.}"

    if [ -z "$args" ]; then
        ui_err "Usage: /append <filepath> <content...>"
        ui_dim "Examples:"
        ui_dim "  /append Cargo.toml [dependencies]\\nreqwest = \"0.11\""
        ui_dim "  /append README.md ## New Section\\nMore text here"
        return 1
    fi

    # Parse: first token is filepath, rest is content
    if declare -f tools_fix_llm_spacing &>/dev/null; then
        local _first_arg="${args%%[[:space:]]*}"
        local _rest_args="${args#*"$_first_arg"}"
        local _fixed_first
        _fixed_first=$(tools_fix_llm_spacing "$_first_arg")
        args="${_fixed_first}${_rest_args}"
    fi

    local filepath content
    filepath=$(echo "$args" | head -1 | awk '{print $1}')
    
    local first_line remaining_lines first_line_content
    first_line=$(echo "$args" | head -1)
    remaining_lines=$(echo "$args" | tail -n +2)
    first_line_content=$(echo "$first_line" | sed 's/^[^ ]* *//')
    if [ "$first_line_content" = "$first_line" ]; then
        first_line_content=""
    fi
    if [ -n "$remaining_lines" ]; then
        content="${first_line_content:+$first_line_content
}${remaining_lines}"
    else
        content="$first_line_content"
    fi

    # Strip trailing dashes from filepath
    filepath=$(echo "$filepath" | sed 's/--*$//')

    # Expand tilde — LLMs emit ~/path which doesn't expand in quotes
    declare -f tools_expand_tilde &>/dev/null && filepath=$(tools_expand_tilde "$filepath")

    # Sanitize filename
    if declare -f tools_sanitize_filename &>/dev/null; then
        filepath=$(tools_sanitize_filename "$filepath")
    else
        filepath=$(echo "$filepath" | sed 's/["'"'"'`]//g' | tr ' ' '-' | sed 's/[^a-zA-Z0-9_./-]//g')
    fi

    # Clean redundant project workdir prefix
    filepath=$(ui_clean_path_prefix "$filepath" "$workdir")

    # If content equals filepath (no content provided), clear it
    if [ "$content" = "$filepath" ]; then
        content=""
    fi

    # If no inline content, read from stdin if available
    if [ -z "$content" ] && [ ! -t 0 ]; then
        content=$(cat)
    fi

    if [ -z "$content" ]; then
        ui_err "No content to append"
        ui_dim "Provide content after the filepath"
        return 1
    fi

    # Auto-expand file references in content
    if [ "${AGENT_FILE_EXPAND:-1}" -eq 1 ] && declare -f tools_expand_file_refs &>/dev/null; then
        content=$(tools_expand_file_refs "$content" "$workdir")
    fi

    # Expand escape sequences (\n → real newlines)
    if declare -f ui_expand_escapes &>/dev/null; then
        content=$(ui_expand_escapes "$content")
    fi

    # Resolve path relative to workdir/global workspace/fallbacks
    local fullpath
    fullpath=$(ui_resolve_path "$filepath" "$workdir" 1)

    if [ "$(basename "$fullpath")" = "GEORGE.md" ]; then
        ui_err "Cannot write/modify GEORGE.md: GEORGE.md is protected and managed exclusively by the system."
        return 1
    fi

    # Create parent directories if needed
    if ! mkdir -p "$(dirname "$fullpath")" 2>/dev/null; then
        ui_err "Cannot create directory: $(dirname "$filepath")"
        return 1
    fi

    if [ ! -f "$fullpath" ]; then
        # File doesn't exist — create it
        printf '%s\n' "$content" > "$fullpath"
        local lines
        lines=$(printf '%s' "$content" | wc -l)
        ui_ok "Created: $filepath ($((lines + 1)) lines)"
        return 0
    fi

    printf '\n%s\n' "$content" >> "$fullpath"
    local lines
    lines=$(wc -l < "$fullpath")
    ui_ok "Appended to: $filepath ($lines total lines)"
    return 0
}
