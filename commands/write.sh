#!/bin/bash
# DESC: Write content to a file (create or overwrite)
# Usage: /write <filepath> <content...>
#   Writes the given content to the specified file.
#   Creates parent directories automatically.
#
# For appending to files, use /append <filepath> <content>
# For sed edits, use /edit <filepath> <sed_expression>

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Detect if we're running inside the agent loop ─────────────
_write_is_agent_mode() {
    # Agent mode: not interactive AND no forced confirm
    [ ! -t 2 ] && [ -z "${LODGE_FORCE_CONFIRM:-}" ]
}

cmd_write() {
    local args="$1"
    local workdir="${2:-.}"

    if [ -z "$args" ]; then
        ui_err "Usage: /write <filepath> <content...>"
        ui_dim "Examples:"
        ui_dim "  /write src/main.rs fn main() { println!(\"hello\"); }"
        ui_dim "  /write README.md # My Project\\nFirst line of content"
        ui_dim ""
        ui_dim "Related: /append (add to file), /edit (sed substitution)"
        return 1
    fi

    # ── Legacy flag redirect ─────────────────────────────────
    # Transparently redirect --append and --edit to their new
    # standalone commands for backward compatibility.
    case "$args" in
        --append\ *|--append)
            local _redir_args="${args#--append }"
            _redir_args="${_redir_args#--append}"
            if declare -f cmd_append &>/dev/null || [ -f "${LODGE_DIR}/commands/append.sh" ]; then
                [ ! "$(type -t cmd_append)" = "function" ] && source "${LODGE_DIR}/commands/append.sh"
                cmd_append "$_redir_args" "$workdir"
                return $?
            fi
            ;;
        --edit\ *|--edit)
            local _redir_args="${args#--edit }"
            _redir_args="${_redir_args#--edit}"
            if declare -f cmd_edit &>/dev/null || [ -f "${LODGE_DIR}/commands/edit.sh" ]; then
                [ ! "$(type -t cmd_edit)" = "function" ] && source "${LODGE_DIR}/commands/edit.sh"
                cmd_edit "$_redir_args" "$workdir"
                return $?
            fi
            ;;
    esac

    # Parse: first token is filepath, rest is content
    # Fix LLM hallucination: missing spaces in output
    # e.g. "filename.txtThis is the content" → "filename.txt This is the content"
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

    # Strip trailing dashes from filepath — catches edge case where
    # LLM emits "/write tesla.md---# content" and tools_fix_llm_spacing
    # couldn't fully separate it (e.g., "tesla.md---#" as first token).
    filepath=$(echo "$filepath" | sed 's/--*$//')

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

    # If no inline content, read from stdin if available
    if [ -z "$content" ] && [ ! -t 0 ]; then
        content=$(cat)
    fi

    if [ -z "$content" ]; then
        ui_err "No content to write"
        ui_dim "Provide content after the filepath"
        return 1
    fi

    # ── Inline /read expansion ──────────────────────────────────
    # LLM may embed /read <file> in the content to inline another
    # file's contents (including PDFs via text extraction).
    if [[ "$content" == */read\ * ]] || [[ "$content" == /read\ * ]]; then
        if declare -f tools_expand_inline_read &>/dev/null; then
            content=$(tools_expand_inline_read "$content")
        fi
    fi

    # ── Auto-expand file references in content ─────────────────
    # File paths (e.g. data.json, notes.txt) in content are replaced
    # with their contents when AGENT_FILE_EXPAND=1.
    if [ "${AGENT_FILE_EXPAND:-1}" -eq 1 ] && declare -f tools_expand_file_refs &>/dev/null; then
        content=$(tools_expand_file_refs "$content" "$workdir")
    fi

    # ── Expand escape sequences ────────────────────────────────
    # The LLM sends multi-line content as a single line with \n
    # separators (as instructed by the syntax card). Expand them
    # to real newlines so files are written correctly.
    content=$(ui_expand_escapes "$content")

    # Resolve path relative to workdir/global workspace/fallbacks
    local fullpath
    fullpath=$(ui_resolve_path "$filepath" "$workdir" 1)

    if [ "$(basename "$fullpath")" = "GEORGE.md" ]; then
        ui_err "Cannot write/modify GEORGE.md: GEORGE.md is protected and managed exclusively by the system."
        return 1
    fi

    # Create parent directories if needed
    if ! mkdir -p "$(dirname "$fullpath")" 2>/dev/null; then
        ui_err "Cannot create directory: $(dirname "$filepath")"
        return 1
    fi

    local existed=0
    [ -f "$fullpath" ] && existed=1

    # ── Agent-mode pre-read ───────────────────────────────────
    # When running inside the agent loop (non-interactive), read the
    # existing file and echo a WARNING + contents to stderr so it
    # gets captured in the 2000-byte output and written to micro_memory.
    # This gives the LLM visibility into what it's overwriting, so the
    # strategist/specialist can decide to use /append or /edit next.
    if _write_is_agent_mode; then
        # Always show sibling files so the model knows what exists
        local _dir_listing
        _dir_listing=$(find "$(dirname "$fullpath")" -maxdepth 1 -type f -name '*.md' -o -name '*.json' -o -name '*.txt' -o -name '*.rs' -o -name '*.py' -o -name '*.sh' -o -name '*.toml' -o -name '*.yaml' -o -name '*.yml' 2>/dev/null | head -15 | sed "s|^$workdir/||")
        if [ -n "$_dir_listing" ]; then
            echo "EXISTING FILES in $(dirname "$filepath"):" >&2
            echo "$_dir_listing" >&2
            echo "---" >&2
        fi
    fi
    if [ "$existed" -eq 1 ] && _write_is_agent_mode; then
        local _existing_lines _existing_preview
        _existing_lines=$(wc -l < "$fullpath")
        # Show first 30 lines (enough for the LLM to see structure)
        _existing_preview=$(head -30 "$fullpath")
        echo "WARNING: $filepath already exists (${_existing_lines} lines). Content preview:" >&2
        echo "$_existing_preview" >&2
        if [ "$_existing_lines" -gt 30 ]; then
            echo "... (${_existing_lines} lines total, showing first 30)" >&2
        fi
        echo "---" >&2
        echo "OVERWRITING with new content. Use /append to add to existing content, or /edit for small changes." >&2
    fi

    # ── Overwrite protection ──────────────────────────────────
    # LODGE_WRITE_MODE controls behavior when the target file exists:
    #   confirm   — prompt the operator via /dev/tty (default)
    #   append    — append content instead of overwriting
    #   dangerous — silently overwrite (original behavior)
    if [ "$existed" -eq 1 ]; then
        local _wmode="${LODGE_WRITE_MODE:-confirm}"
        case "$_wmode" in
            confirm)
                # Skip prompt in non-interactive environments (tests, pipes).
                # /dev/tty may block even with || fallback in some contexts.
                if [ ! -t 2 ] && [ -z "${LODGE_FORCE_CONFIRM:-}" ]; then
                    # Non-interactive: fall through to overwrite silently
                    :
                else
                    local _existing_lines
                    _existing_lines=$(wc -l < "$fullpath")
                    printf " %b%s%b already exists (%s lines). %b[O]%bverwrite / %b[A]%bppend / %b[R]%bename / %b[S]%bkip? " \
                        "\033[1;33m" "$filepath" "\033[0m" "$_existing_lines" \
                        "\033[1;37m" "\033[0m" "\033[1;37m" "\033[0m" \
                        "\033[1;37m" "\033[0m" "\033[1;37m" "\033[0m"
                    local _choice
                    read -r _choice < /dev/tty 2>/dev/null || _choice="o"
                    _choice="${_choice,,}"
                    case "$_choice" in
                        o|overwrite) ;; # fall through to write
                        a|append)
                            printf '\n%s\n' "$content" >> "$fullpath"
                            local lines
                            lines=$(wc -l < "$fullpath")
                            ui_ok "Appended to: $filepath ($lines total lines)"
                            return 0 ;;
                        r|rename)
                            # Auto-generate numbered variant
                            local _base="${fullpath%.*}"
                            local _ext="${fullpath##*.}"
                            local _n=2
                            local _newpath
                            while true; do
                                if [ "$_base" = "$fullpath" ]; then
                                    _newpath="${fullpath}_${_n}"
                                else
                                    _newpath="${_base}_${_n}.${_ext}"
                                fi
                                [ ! -f "$_newpath" ] && break
                                _n=$((_n + 1))
                            done
                            fullpath="$_newpath"
                            filepath=$(basename "$_newpath")
                            existed=0 ;;
                        s|skip|*)
                            ui_info "Skipped: $filepath (not overwritten)"
                            return 0 ;;
                    esac
                fi
                ;;
            append)
                printf '\n%s\n' "$content" >> "$fullpath"
                local lines
                lines=$(wc -l < "$fullpath")
                ui_ok "Appended to: $filepath ($lines total lines)"
                return 0 ;;
            dangerous) ;; # fall through to write (original behavior)
        esac
    fi

    # Backup previous version to history directory if overwriting
    if [ "$existed" -eq 1 ]; then
        local _hist_dir
        _hist_dir="$(dirname "$fullpath")/.history"
        if mkdir -p "$_hist_dir" 2>/dev/null; then
            local _ts _fname
            _ts=$(date '+%Y%m%d_%H%M%S')
            _fname=$(basename "$fullpath")
            cp "$fullpath" "$_hist_dir/${_fname}_${_ts}" 2>/dev/null
        fi
    fi

    # Write the file
    if ! printf '%s\n' "$content" > "$fullpath" 2>/dev/null; then
        ui_err "Write failed: $filepath (permission denied or invalid path)"
        return 1
    fi
    local lines
    lines=$(printf '%s' "$content" | wc -l)
    lines=$((lines + 1))

    if [ "$existed" -eq 1 ]; then
        ui_ok "Overwrote: $filepath ($lines lines)"
    else
        ui_ok "Created: $filepath ($lines lines)"
    fi
}
