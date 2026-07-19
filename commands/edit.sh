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

    # Resolve path relative to workdir (security: no absolute paths)
    local fullpath
    if [[ "$filepath" == /* ]]; then
        filepath="${filepath#/}"
    fi
    fullpath="$workdir/$filepath"

    if [ "$(basename "$fullpath")" = "GEORGE.md" ]; then
        ui_err "Cannot write/modify GEORGE.md: GEORGE.md is protected and managed exclusively by the system."
        return 1
    fi

    if [ -z "$content" ]; then
        if [ -f "$fullpath" ]; then
            ui_info "File loaded. Line numbers (e.g., '14:') are reference metadata ONLY — do NOT include them in your search/replace patterns."
            echo "--- start of $filepath ---"
            awk '{print NR ": " $0}' "$fullpath"
            echo "--- end of $filepath ---"
            return 0
        else
            ui_err "No search/replace block provided and file does not exist: $filepath"
            return 1
        fi
    fi

    if [ ! -f "$fullpath" ]; then
        ui_err "Cannot edit — file does not exist: $filepath"
        return 1
    fi

    local before_lines after_lines
    before_lines=$(wc -l < "$fullpath")

    export CONTENT="$content"

    local py_err
    py_err=$(python3 -c '
import sys, os
fullpath = sys.argv[1]
content_str = os.environ.get("CONTENT", "")

# Parse blocks
blocks = []
current_search = []
current_replace = []
state = "outside"

for line in content_str.split("\n"):
    line = line.rstrip("\r")
    if line.startswith("<<<<<<<"):
        state = "in_search"
        current_search = []
    elif line.startswith("======="):
        state = "in_replace"
        current_replace = []
    elif line.startswith(">>>>>>>"):
        if state == "in_replace":
            blocks.append(("\n".join(current_search), "\n".join(current_replace)))
        state = "outside"
    else:
        if state == "in_search":
            current_search.append(line)
        elif state == "in_replace":
            current_replace.append(line)
        elif state == "outside" and line.strip():
            state = "in_search"
            current_search = [line]

if not blocks:
    print("Error: Edit rejected — invalid block-replace format. Could not parse any search/replace blocks.", file=sys.stderr)
    sys.exit(1)

import re
with open(fullpath, "r", encoding="utf-8") as f:
    file_content = f.read()

def strip_line_numbers(text):
    lines = text.split("\n")
    cleaned_lines = []
    for line in lines:
        m = re.match(r"^\s*\d+:\s?(.*)", line)
        if m:
            cleaned_lines.append(m.group(1))
        else:
            cleaned_lines.append(line)
    return "\n".join(cleaned_lines)

# Clean and verify blocks
cleaned_blocks = []
for idx, (search, replace) in enumerate(blocks):
    if not search:
        print(f"Error: Empty search pattern in block {idx+1}.", file=sys.stderr)
        sys.exit(1)
    
    cleaned_search = search
    cleaned_replace = replace
    if search not in file_content:
        candidate_search = strip_line_numbers(search)
        if candidate_search in file_content:
            cleaned_search = candidate_search
            cleaned_replace = strip_line_numbers(replace)

    if cleaned_search not in file_content:
        print(f"Error: Search pattern not found in target file (block {idx+1}).", file=sys.stderr)
        sys.exit(1)
    if file_content.count(cleaned_search) > 1:
        print(f"Error: Search pattern is not unique (found multiple matches) in block {idx+1}.", file=sys.stderr)
        sys.exit(1)
    cleaned_blocks.append((cleaned_search, cleaned_replace))

# Apply all replacements
new_content = file_content
for search, replace in cleaned_blocks:
    new_content = new_content.replace(search, replace)

with open(fullpath, "w", encoding="utf-8") as f:
    f.write(new_content)

print(f"Applied {len(cleaned_blocks)} block edits.")
' "$fullpath" 2>&1)
    local py_rc=$?

    unset CONTENT

    if [ "$py_rc" -eq 0 ]; then
        after_lines=$(wc -l < "$fullpath")
        ui_ok "Edited: $filepath ($before_lines → $after_lines lines) - $py_err"
        return 0
    else
        ui_err "Edit failed: $py_err"
        return 1
    fi
}
