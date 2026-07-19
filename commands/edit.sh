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

    # Resolve path relative to workdir/global workspace/fallbacks
    local fullpath
    fullpath=$(ui_resolve_path "$filepath" "$workdir" 1)

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
            if [ "${AGENT_ASK_USER:-1}" -eq 1 ]; then
                ui_info "[INSTRUCTION] The required file is missing. You must pivot: either ask the operator to provide the content/location using /ask, create it with /write, or terminate the task."
            else
                ui_info "[INSTRUCTION] The required file is missing. Since /ask is disabled, you must immediately terminate the task and report the failure using /respond."
            fi
            ui_suggest_workspaces_tree
            return 1
        fi
    fi

    if [ ! -f "$fullpath" ]; then
        ui_err "Cannot edit — file does not exist: $filepath"
        if [ "${AGENT_ASK_USER:-1}" -eq 1 ]; then
            ui_info "[INSTRUCTION] The required file is missing. You must pivot: either ask the operator to provide the content/location using /ask, create it with /write, or terminate the task."
        else
            ui_info "[INSTRUCTION] The required file is missing. Since /ask is disabled, you must immediately terminate the task and report the failure using /respond."
        fi
        ui_suggest_workspaces_tree
        return 1
    fi

    local before_lines after_lines
    before_lines=$(wc -l < "$fullpath")

    local py_rc=1
    local py_err=""

    if command -v python3 &>/dev/null; then
        export CONTENT="$content"
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
        py_rc=$?
        unset CONTENT
    else
        # Pure Bash/Awk Fallback when python3 is not available
        local file_content
        file_content=$(cat "$fullpath")

        # Parse blocks
        local blocks_search=()
        local blocks_replace=()
        local state="outside"
        local cur_search=""
        local cur_replace=""

        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%$'\r'}"
            if [[ "$line" == "<<<<<<<"* ]]; then
                state="in_search"
                cur_search=""
            elif [[ "$line" == "======="* ]]; then
                state="in_replace"
                cur_replace=""
            elif [[ "$line" == ">>>>>>>"* ]]; then
                if [ "$state" = "in_replace" ]; then
                    blocks_search+=("$cur_search")
                    blocks_replace+=("$cur_replace")
                fi
                state="outside"
            else
                if [ "$state" = "in_search" ]; then
                    cur_search="${cur_search}${cur_search:+$'\n'}${line}"
                elif [ "$state" = "in_replace" ]; then
                    cur_replace="${cur_replace}${cur_replace:+$'\n'}${line}"
                elif [ "$state" = "outside" ] && [ -n "$(echo "$line" | tr -d '[:space:]')" ]; then
                    state="in_search"
                    cur_search="$line"
                fi
            fi
        done <<< "$content"

        if [ "${#blocks_search[@]}" -eq 0 ]; then
            py_err="Error: Edit rejected — invalid block-replace format. Could not parse any search/replace blocks."
            py_rc=1
        else
            strip_line_numbers() {
                local text="$1"
                echo "$text" | sed -E 's/^[[:space:]]*[0-9]+:[[:space:]]?//'
            }

            local new_content="$file_content"
            local i
            local success=1
            for ((i=0; i<${#blocks_search[@]}; i++)); do
                local search="${blocks_search[i]}"
                local replace="${blocks_replace[i]}"
                
                if [ -z "$search" ]; then
                    py_err="Error: Empty search pattern in block $((i+1))."
                    success=0
                    break
                fi

                local cleaned_search="$search"
                local cleaned_replace="$replace"

                if [[ "$new_content" != *"$search"* ]]; then
                    local cand_search
                    cand_search=$(strip_line_numbers "$search")
                    if [[ "$new_content" == *"$cand_search"* ]]; then
                        cleaned_search="$cand_search"
                        cleaned_replace=$(strip_line_numbers "$replace")
                    fi
                fi

                if [[ "$new_content" != *"$cleaned_search"* ]]; then
                    py_err="Error: Search pattern not found in target file (block $((i+1)))."
                    success=0
                    break
                fi

                local match_count
                match_count=$(awk -v search="$cleaned_search" '
                    BEGIN {
                        file_content = ""
                        while (getline line < "/dev/stdin") {
                            file_content = file_content (file_content == "" ? "" : "\n") line
                        }
                        count = 0
                        pos = index(file_content, search)
                        while (pos > 0) {
                            count++
                            file_content = substr(file_content, pos + length(search))
                            pos = index(file_content, search)
                        }
                        print count
                        exit
                    }
                ' <<< "$new_content")

                if [ "$match_count" -gt 1 ]; then
                    py_err="Error: Search pattern is not unique (found multiple matches) in block $((i+1))."
                    success=0
                    break
                fi

                new_content=$(awk -v search="$cleaned_search" -v replace="$cleaned_replace" '
                    BEGIN {
                        file_content = ""
                        while (getline line < "/dev/stdin") {
                            file_content = file_content (file_content == "" ? "" : "\n") line
                        }
                        pos = index(file_content, search)
                        if (pos > 0) {
                            file_content = substr(file_content, 1, pos - 1) replace substr(file_content, pos + length(search))
                        }
                        printf "%s", file_content
                        exit
                    }
                ' <<< "$new_content")
            done

            if [ "$success" -eq 1 ]; then
                printf "%s" "$new_content" > "$fullpath"
                py_err="Applied ${#blocks_search[@]} block edits (fallback)."
                py_rc=0
            else
                py_rc=1
            fi
        fi
    fi

    if [ "$py_rc" -eq 0 ]; then
        after_lines=$(wc -l < "$fullpath")
        ui_ok "Edited: $filepath ($before_lines → $after_lines lines) - $py_err"
        return 0
    else
        ui_err "Edit failed: $py_err"
        return 1
    fi
}
