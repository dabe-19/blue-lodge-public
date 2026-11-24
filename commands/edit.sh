#!/bin/bash
# DESC: Surgical file editing via the 4-tier fuzzy match backend (lib/tools/edit_backend.py)
# Usage:
#   /edit <filepath> <expression>                     Legacy <<<<<<< SEARCH / >>>>>>> REPLACE blocks
#   /edit <filepath> (via EDITS_JSON env, native tool) Structured JSON, three supported forms:
#     Single hunk:   {"target": "exact existing text", "replacement": "new text", "replace_all": false, "start_line": 10, "end_line": 15}
#     Line-anchored: {"start_line": 10, "end_line": 15, "replacement": "new text"}
#     Multi-hunk:    {"edits": [{"target": "...", "replacement": "...", "start_line": 10, "end_line": 15}, ...]}   (atomic: all-or-nothing, bottom-up line range application)
#   Matching cascade: exact -> line-number prefix strip -> whitespace/indent normalization
#   -> Unicode typography normalization. Success output reports the tier(s) used,
#   e.g. "Applied 2 block edits [exact, indent_norm]."
#   Fallback: pure bash/awk block replace when python3 is unavailable.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh"

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

    source "$LODGE_DIR/lib/tools/tools.sh" 2>/dev/null || true
    local filepath="" fullpath="" content=""
    if [ "${LODGE_RAW_CONTENT_SET:-0}" -eq 1 ] || [ -n "${EDITS_JSON:-}" ]; then
        tools_parse_file_cmd_args "$args" "$workdir" 0 0 || return 1
        filepath="$_PARSED_FILEPATH"
        fullpath="$_PARSED_FULLPATH"
        content="${LODGE_RAW_CONTENT:-$_PARSED_CONTENT}"
    else
        tools_parse_file_cmd_args "$args" "$workdir" 0 0 || return 1
        filepath="$_PARSED_FILEPATH"
        fullpath="$_PARSED_FULLPATH"
        content="$_PARSED_CONTENT"
    fi

    if [ -z "$content" ] && [ -z "${EDITS_JSON:-}" ]; then
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

    local py_bin=""
    if [ -x "$LODGE_DIR/.venv/bin/python" ]; then
        py_bin="$LODGE_DIR/.venv/bin/python"
    elif [ -n "${GEORGE_PYTHON:-}" ] && command -v "$GEORGE_PYTHON" &>/dev/null; then
        py_bin="$GEORGE_PYTHON"
    elif command -v python3 &>/dev/null; then
        py_bin="python3"
    fi

    if [ -n "$py_bin" ] && [ -f "$LODGE_DIR/lib/tools/edit_backend.py" ]; then
        export CONTENT="$content"
        export EDITS_JSON="${EDITS_JSON:-}"
        py_err=$("$py_bin" "$LODGE_DIR/lib/tools/edit_backend.py" "$fullpath" 2>&1)
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
        declare -f tools_check_treesitter_badge &>/dev/null && tools_check_treesitter_badge "$filepath" "$(cat "$fullpath")" "Tree-sitter AST syntax warning after edit on"
        ui_ok "Edited: $filepath ($before_lines → $after_lines lines) - $py_err"
        return 0
    else
        ui_err "Edit failed: $py_err"
        return 1
    fi
}
