#!/bin/bash
# DESC: Edit a file using sed substitution (short, targeted changes)
# Usage: /edit <filepath> <sed_expression>
#   Applies a sed expression to the specified file.
#   Only for short, simple substitutions (max 200 chars).

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

cmd_edit() {
    local args="$1"
    local workdir="${2:-.}"

    if [ -z "$args" ]; then
        ui_err "Usage: /edit <filepath> <sed_expression>"
        ui_dim "Examples:"
        ui_dim "  /edit src/main.rs s/old_func/new_func/g"
        ui_dim "  /edit config.toml s/port = 8080/port = 3000/"
        ui_dim ""
        ui_dim "For large changes, use /write with COMPLETE file contents."
        return 1
    fi

    # Parse: first token is filepath, rest is sed expression
    if declare -f tools_fix_llm_spacing &>/dev/null; then
        args=$(tools_fix_llm_spacing "$args")
    fi

    local filepath content
    filepath=$(echo "$args" | head -1 | awk '{print $1}')
    content=$(echo "$args" | sed 's/^[^ ]* *//')

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

    if [ -z "$content" ]; then
        ui_err "No sed expression provided"
        ui_dim "Provide a sed expression after the filepath"
        return 1
    fi

    # Resolve path relative to workdir (security: no absolute paths)
    local fullpath
    if [[ "$filepath" == /* ]]; then
        filepath="${filepath#/}"
    fi
    fullpath="$workdir/$filepath"

    if [ ! -f "$fullpath" ]; then
        ui_err "Cannot edit — file does not exist: $filepath"
        return 1
    fi

    # Auto-heal missing trailing delimiter for 's' commands
    if [[ "$content" =~ ^s([/\|,\#]) ]]; then
        local delim="${BASH_REMATCH[1]}"
        local temp="${content//\\$delim/_}"
        local count
        count=$(echo -n "$temp" | tr -cd "$delim" | wc -c)
        if [ "$count" -eq 2 ]; then
            content="${content}${delim}"
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && ui_dim "  [debug] Auto-healed missing trailing sed delimiter: $content"
        fi
    fi

    # Guard: reject content that's clearly NOT a sed expression
    local _sed_ok=0
    if [[ "$content" =~ ^s[/\|,\#] ]]; then
        _sed_ok=1  # substitution: s/old/new/ s|old|new| etc
    elif [[ "$content" =~ ^[0-9]*,?[0-9]*/.*/ ]]; then
        _sed_ok=1  # address + command: /pattern/d, 3,5d, etc
    elif [[ "$content" =~ ^[0-9]+[dips] ]]; then
        _sed_ok=1  # line-addressed command: 5d, 3i, etc
    fi

    if [ "$_sed_ok" -eq 0 ]; then
        ui_err "Edit rejected — content is not a valid sed expression: ${content:0:80}"
        ui_dim "  /edit is for SIMPLE substitutions only (e.g. s/old_name/new_name/g)"
        ui_dim "  To rewrite a file, use: /write <filepath> <complete content>"
        return 1
    fi

    # Guard: reject excessively long sed expressions (> 200 chars)
    if [ "${#content}" -gt 200 ]; then
        ui_err "Edit rejected — sed expression too long (${#content} chars)"
        ui_dim "  /edit is for small, targeted changes."
        ui_dim "  To rewrite a file, use: /write <filepath> <complete content>"
        return 1
    fi

    local before_lines after_lines
    before_lines=$(wc -l < "$fullpath")
    if sed -i "$content" "$fullpath" 2>/dev/null; then
        after_lines=$(wc -l < "$fullpath")
        ui_ok "Edited: $filepath ($before_lines → $after_lines lines)"
        return 0
    else
        ui_err "Edit failed — invalid sed expression: $content"
        ui_dim "  /edit is for SIMPLE substitutions: s/old/new/g"
        ui_dim "  To rewrite a file, use: /write <filepath> <complete content>"
        return 1
    fi
}
