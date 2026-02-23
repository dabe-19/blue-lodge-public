#!/bin/bash
# DESC: Write content to a file (create or overwrite)
# Usage: /write <filepath> <content...>
#   Writes the given content to the specified file.
#   Creates parent directories automatically.
#   Aliases: works like /save but designed for code generation steps.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

cmd_write() {
    local args="$1"
    local workdir="${2:-.}"

    if [ -z "$args" ]; then
        ui_err "Usage: /write <filepath> <content...>"
        ui_dim "Examples:"
        ui_dim "  /write src/main.rs fn main() { println!(\"hello\"); }"
        ui_dim "  /write README.md # My Project"
        return 1
    fi

    # Parse: first token is filepath, rest is content
    local filepath content
    filepath=$(echo "$args" | awk '{print $1}')
    content=$(echo "$args" | sed 's/^[^ ]* *//')

    # Sanitize filename — strip quotes, spaces, special chars
    if declare -f tools_sanitize_filename &>/dev/null; then
        filepath=$(tools_sanitize_filename "$filepath")
    else
        # Inline fallback: strip quotes and spaces
        filepath=$(echo "$filepath" | sed 's/["'"'"'`]//g' | tr ' ' '-' | sed 's/[^a-zA-Z0-9_./-]//g')
    fi

    # If content equals filepath (no content provided), clear it
    if [ "$content" = "$filepath" ]; then
        content=""
    fi

    # If no inline content, read from stdin if available
    if [ -z "$content" ] && [ ! -t 0 ]; then
        content=$(cat)
    fi

    if [ -z "$content" ]; then
        ui_err "No content to write"
        ui_dim "Provide content after the filepath"
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

    local existed=0
    [ -f "$fullpath" ] && existed=1

    # Write the file
    printf '%s\n' "$content" > "$fullpath"
    local lines
    lines=$(printf '%s' "$content" | wc -l)
    lines=$((lines + 1))

    if [ "$existed" -eq 1 ]; then
        ui_ok "Overwrote: $filepath ($lines lines)"
    else
        ui_ok "Created: $filepath ($lines lines)"
    fi
}
