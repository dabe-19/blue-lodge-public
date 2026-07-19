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

    # Strip surrounding quotes from the entire args string
    # (LLM often wraps arguments in shell-style quotes)
    args="${args#\"}"
    args="${args%\"}"
    args="${args#\'}"
    args="${args%\'}"

    # Parse: first token is filepath, rest is content
    # Fix LLM hallucination: missing spaces in output
    if declare -f tools_fix_llm_spacing &>/dev/null; then
        local _first_arg="${args%%[[:space:]]*}"
        local _rest_args="${args#*"$_first_arg"}"
        local _fixed_first
        _fixed_first=$(tools_fix_llm_spacing "$_first_arg")
        args="${_fixed_first}${_rest_args}"
    fi

    local filepath content
    if [[ "$args" == '"'* ]]; then
        if [[ "$args" =~ ^\"([^\"]+)\"([[:space:]]+(.*))?$ ]]; then
            filepath="${BASH_REMATCH[1]}"
            content="${BASH_REMATCH[3]}"
        fi
    elif [[ "$args" == "'"* ]]; then
        if [[ "$args" =~ ^\'([^\']+)\'([[:space:]]+(.*))?$ ]]; then
            filepath="${BASH_REMATCH[1]}"
            content="${BASH_REMATCH[3]}"
        fi
    else
        filepath=$(echo "$args" | head -1 | awk '{print $1}')
        content=$(echo "$args" | sed 's/^[^ ]* *//')
    fi

    # Expand tilde — LLMs emit ~/path which doesn't expand in quotes
    declare -f tools_expand_tilde &>/dev/null && filepath=$(tools_expand_tilde "$filepath")

    # Sanitize filename — strip quotes, spaces, special chars
    if declare -f tools_sanitize_filename &>/dev/null; then
        filepath=$(tools_sanitize_filename "$filepath")
    else
        # Inline fallback: strip quotes and spaces
        filepath=$(echo "$filepath" | sed 's/["'"'"'`]//g' | tr ' ' '-' | sed 's/[^a-zA-Z0-9_./-]//g')
    fi

    # Clean redundant project workdir prefix
    filepath=$(ui_clean_path_prefix "$filepath" "$workdir")

    # If content equals filepath (no content provided), clear it
    if [ "$content" = "$filepath" ]; then
        content=""
    fi

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

    # Resolve path relative to workdir/global workspace/fallbacks
    local fullpath
    fullpath=$(ui_resolve_path "$filepath" "$workdir" 1)

    if [ "$(basename "$fullpath")" = "GEORGE.md" ]; then
        ui_err "Cannot write/modify GEORGE.md: GEORGE.md is protected and managed exclusively by the system."
        return 1
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
