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

    if [ -z "$content" ]; then
        ui_err "No search/replace block provided"
        ui_dim "Provide a search/replace block after the filepath"
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

    # Parse search pattern and replacement pattern from content
    local search_pattern replacement_pattern
    search_pattern=$(echo "$content" | awk '
        /^<<<<<<</ { inside=1; next }
        /^=======/ { inside=0; exit }
        inside { print }
    ')
    replacement_pattern=$(echo "$content" | awk '
        /^=======/ { inside=1; next }
        /^>>>>>>>/ { inside=0; exit }
        inside { print }
    ')

    if [ -z "$search_pattern" ]; then
        ui_err "Edit rejected — invalid block-replace format"
        ui_dim "Use the following format:"
        ui_dim "  /edit <filepath>"
        ui_dim "  <<<<<<<"
        ui_dim "  <search_lines>"
        ui_dim "  ======="
        ui_dim "  <replace_lines>"
        ui_dim "  >>>>>>>"
        return 1
    fi

    local before_lines after_lines
    before_lines=$(wc -l < "$fullpath")

    export SEARCH_PAT="$search_pattern"
    export REPLACE_PAT="$replacement_pattern"

    local py_err
    py_err=$(python3 -c '
import sys, os
fullpath = sys.argv[1]
with open(fullpath, "r", encoding="utf-8") as f:
    content = f.read()
search = os.environ.get("SEARCH_PAT", "")
replace = os.environ.get("REPLACE_PAT", "")
if not search:
    print("Error: Empty search pattern", file=sys.stderr)
    sys.exit(1)
if search not in content:
    print("Error: Search pattern not found in target file.", file=sys.stderr)
    sys.exit(1)
if content.count(search) > 1:
    print("Error: Search pattern is not unique (found multiple matches).", file=sys.stderr)
    sys.exit(1)
new_content = content.replace(search, replace)
with open(fullpath, "w", encoding="utf-8") as f:
    f.write(new_content)
' "$fullpath" 2>&1)
    local py_rc=$?

    unset SEARCH_PAT REPLACE_PAT

    if [ "$py_rc" -eq 0 ]; then
        after_lines=$(wc -l < "$fullpath")
        ui_ok "Edited: $filepath ($before_lines → $after_lines lines)"
        return 0
    else
        ui_err "Edit failed: $py_err"
        return 1
    fi
}
