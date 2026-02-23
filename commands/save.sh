#!/bin/bash
# DESC: Save content to a file
# Usage: /save <filepath> [content...]
#   If content is provided, writes it to the file.
#   If no content, reads from stdin (pipe or interactive).

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

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

    # Parse: first token is filepath, rest is content
    local filepath content
    filepath=$(echo "$args" | awk '{print $1}')
    content=$(echo "$args" | sed 's/^[^ ]* *//')

    # If content equals filepath (no content provided), clear it
    if [ "$content" = "$filepath" ]; then
        content=""
    fi

    # If no inline content, read from stdin if available
    if [ -z "$content" ] && [ ! -t 0 ]; then
        content=$(cat)
    fi

    if [ -z "$content" ]; then
        ui_err "No content to save"
        ui_dim "Provide content after the filepath, or pipe content in"
        return 1
    fi

    # Resolve path relative to workdir
    local fullpath
    if [[ "$filepath" == /* ]]; then
        fullpath="$filepath"
    else
        fullpath="$workdir/$filepath"
    fi

    # Create parent directories if needed
    mkdir -p "$(dirname "$fullpath")"

    # Write the file
    printf '%s\n' "$content" > "$fullpath"
    local lines
    lines=$(echo "$content" | wc -l)

    ui_ok "Saved: $filepath ($lines lines)"
}
