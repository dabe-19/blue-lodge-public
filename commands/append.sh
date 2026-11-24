#!/bin/bash
# DESC: Append content to end of an existing file
# Usage: /append <filepath> <content...>
#   Adds the given content to the end of the specified file.
#   Creates the file if it does not exist.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh"

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

    source "$LODGE_DIR/lib/tools/tools.sh" 2>/dev/null || true
    local filepath="" fullpath="" content=""
    if [ "${LODGE_RAW_CONTENT_SET:-0}" -eq 1 ]; then
        tools_parse_file_cmd_args "$args" "$workdir" 0 0 || return 1
        filepath="$_PARSED_FILEPATH"
        fullpath="$_PARSED_FULLPATH"
        content="${LODGE_RAW_CONTENT:-}"
        if [ -z "$content" ]; then
            ui_err "No content to append"
            ui_dim "Provide content after the filepath"
            return 1
        fi
    else
        tools_parse_file_cmd_args "$args" "$workdir" 0 1 || return 1
        filepath="$_PARSED_FILEPATH"
        fullpath="$_PARSED_FULLPATH"
        content="$_PARSED_CONTENT"

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
