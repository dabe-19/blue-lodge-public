#!/bin/bash
# DESC: Save content to a file
# Usage: /save <filepath> [content...]
#   If content is provided, writes it to the file.
#   If no content, reads from stdin (pipe or interactive).

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh"

cmd_save() {
    local args="$1"
    local workdir="${2:-.}"

    if [ -z "$args" ]; then
        ui_err "Usage: /save <filepath> [content...]"
        ui_dim "Examples:"
        ui_dim "  /save notes.md This is the content"
        ui_dim "  /save src/main.rs"
        ui_dim "  echo 'hello' | /save greeting.txt"
        return 1
    fi

    # Strip surrounding quotes from the entire args string
    args="${args#\"}"
    args="${args%\"}"
    args="${args#\'}"
    args="${args%\'}"

    source "$LODGE_DIR/lib/tools/tools.sh" 2>/dev/null || true
    tools_parse_file_cmd_args "$args" "$workdir" 0 0 || return 1
    local filepath="$_PARSED_FILEPATH"
    local fullpath="$_PARSED_FULLPATH"
    local content="$_PARSED_CONTENT"

    # Also clear content if it matches the original args (single quoted arg, no content)
    local args_stripped
    args_stripped=$(echo "$args" | sed 's/["'"'"'`]//g')
    if [ "$content" = "$args" ] || [ "$content" = "$args_stripped" ]; then
        content=""
    fi

    # If no inline content, read from stdin if available
    if [ -z "$content" ] && [ ! -t 0 ]; then
        content=$(cat)
    fi

    # If no content but file already exists, confirm it's saved
    if [ -z "$content" ] && [ -f "$fullpath" ]; then
        local lines
        lines=$(wc -l < "$fullpath")
        ui_ok "Saved: $filepath ($lines lines)"
        return 0
    fi

    if [ -z "$content" ]; then
        ui_err "No content to save"
        ui_dim "Provide content after the filepath, or pipe content in"
        return 1
    fi

    # Expand LLM escape sequences (literal \n → real newlines)
    # Skip if content already contains real newlines (stdin input)
    content=$(ui_expand_escapes "$content")

    # Create parent directories if needed
    if ! mkdir -p "$(dirname "$fullpath")" 2>/dev/null; then
        ui_err "Cannot create directory: $(dirname "$filepath")"
        return 1
    fi

    # Write the file
    if ! printf '%s\n' "$content" > "$fullpath" 2>/dev/null; then
        ui_err "Write failed: $filepath (permission denied or invalid path)"
        return 1
    fi
    local lines
    lines=$(printf '%s' "$content" | wc -l)
    lines=$((lines + 1))

    ui_ok "Saved: $filepath ($lines lines)"
}
