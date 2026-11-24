#!/bin/bash
# DESC: Write content to a file (create or overwrite)
# Usage: /write <filepath> <content...>
#   Writes the given content to the specified file.
#   Creates parent directories automatically.
#
# For appending to files, use /append <filepath> <content>
# For sed edits, use /edit <filepath> <sed_expression>

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh"

# ── Detect if we're running inside the agent loop ─────────────
_write_is_agent_mode() {
    # Agent mode: not interactive AND no forced confirm
    [ ! -t 2 ] && [ -z "${LODGE_FORCE_CONFIRM:-}" ]
}

# ── Extract verifiable source anchors (URLs, arXiv IDs, DOIs) from stdin ──
_write_extract_source_anchors() {
    grep -Eo '(https?://[^][ ()"'\''<>`]+|arXiv:[0-9]{4}\.[0-9]{4,5}(v[0-9]+)?|10\.[0-9]{4,9}/[-._;()/:A-Za-z0-9]+)' 2>/dev/null \
        | sed -E 's/[.,;:]+$//' | sort -u
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

    source "$LODGE_DIR/lib/tools/tools.sh" 2>/dev/null || true
    local filepath="" fullpath="" content=""
    if [ "${LODGE_RAW_CONTENT_SET:-0}" -eq 1 ]; then
        tools_parse_file_cmd_args "$args" "$workdir" 1 0 || return 1
        filepath="$_PARSED_FILEPATH"
        fullpath="$_PARSED_FULLPATH"
        content="${LODGE_RAW_CONTENT:-}"
        if [ -z "$content" ]; then
            ui_err "No content to write"
            ui_dim "Provide content after the filepath"
            return 1
        fi
    else
        tools_parse_file_cmd_args "$args" "$workdir" 1 1 || return 1
        filepath="$_PARSED_FILEPATH"
        fullpath="$_PARSED_FULLPATH"
        content="$_PARSED_CONTENT"

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
        if [[ "$content" == */read\ * ]] || [[ "$content" == /read\ * ]]; then
            if declare -f tools_expand_inline_read &>/dev/null; then
                content=$(tools_expand_inline_read "$content")
            fi
        fi

        # ── Auto-expand file references in content ─────────────────
        if [ "${AGENT_FILE_EXPAND:-1}" -eq 1 ] && declare -f tools_expand_file_refs &>/dev/null; then
            content=$(tools_expand_file_refs "$content" "$workdir")
        fi

        # ── Expand escape sequences ────────────────────────────────
        content=$(ui_expand_escapes "$content")
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
    # ── Evidence Ledger Overwrite & Shrinkage Protection ──────
    # Prevent autonomous agents from accidentally clobbering collected Phase 1
    # research sources in scratchpad.md / evidence_ledger.md via file_write.
    local _bname
    _bname=$(basename "$fullpath")
    if [ "$existed" -eq 1 ] && _write_is_agent_mode && [ "${LODGE_ALLOW_SCRATCHPAD_OVERWRITE:-0}" != "1" ]; then
        if [ "$_bname" = "evidence_ledger.md" ] || [ "$_bname" = ".evidence_ledger_snapshot.md" ]; then
            local _sp_redir="$(dirname "$fullpath")/scratchpad.md"
            printf '\n%s\n' "$content" >> "$_sp_redir"
            local _sp_lines
            _sp_lines=$(wc -l < "$_sp_redir" 2>/dev/null | tr -d ' ')
            echo "PROTECTED EVIDENCE LEDGER: $_bname is an immutable Phase 2 evidence snapshot. Appended your new notes to scratchpad.md instead." >&2
            ui_ok "Appended to: scratchpad.md (${_sp_lines:-0} total lines, protected evidence snapshot)"
            return 0
        elif [ "$_bname" = "scratchpad.md" ]; then
            local _existing_lines _old_bytes _new_bytes _shrunk=0
            _existing_lines=$(wc -l < "$fullpath" 2>/dev/null | tr -d ' ')
            _old_bytes=$(wc -c < "$fullpath" 2>/dev/null | tr -d ' ')
            _new_bytes=${#content}
            if [ "${_old_bytes:-0}" -gt 800 ] && [ $((_new_bytes * 100)) -lt $((_old_bytes * 80)) ]; then
                _shrunk=1
            fi

            local _existing_anchors _missing_anchors=0 _total_anchors=0
            _existing_anchors=$(_write_extract_source_anchors < "$fullpath")
            if [ -n "$_existing_anchors" ]; then
                while IFS= read -r _anchor; do
                    [ -z "$_anchor" ] && continue
                    _total_anchors=$((_total_anchors + 1))
                    if ! printf '%s\n' "$content" | grep -Fq "$_anchor" 2>/dev/null; then
                        _missing_anchors=$((_missing_anchors + 1))
                    fi
                done <<< "$_existing_anchors"
            fi

            if [ "$_missing_anchors" -gt 0 ] || { [ "$_total_anchors" -gt 0 ] && [ "$_shrunk" -eq 1 ]; } || { [ "${_existing_lines:-0}" -gt 25 ] && [ "$_shrunk" -eq 1 ]; }; then
                local _hist_dir
                _hist_dir="$(dirname "$fullpath")/.history"
                if mkdir -p "$_hist_dir" 2>/dev/null; then
                    cp "$fullpath" "$_hist_dir/scratchpad.md_$(date '+%Y%m%d_%H%M%S')" 2>/dev/null || true
                fi
                printf '\n%s\n' "$content" >> "$fullpath"
                local _tot_lines
                _tot_lines=$(wc -l < "$fullpath" 2>/dev/null | tr -d ' ')
                echo "PROTECTED EVIDENCE LEDGER: Preserved existing collected sources in $filepath (${_total_anchors} verified source anchors, ${_existing_lines} lines) and APPENDED new content instead of overwriting." >&2
                ui_ok "Appended to: $filepath (${_tot_lines} total lines, protected existing sources)"
                return 0
            fi
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

    # ── Safe Append-at-EOF Intent Detection ───────────────────
    # If target file exists and content explicitly states append intent in header, append safely
    if [ "$existed" -eq 1 ] && echo "$content" | head -n 3 | grep -qiE '(appended? at EOF|append to)'; then
        printf '\n%s\n' "$content" >> "$fullpath"
        ui_ok "Appended to: $filepath"
        return 0
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

    # Write the file atomically via temp file + mv
    local _tmp_write="${fullpath}.tmp.$$"
    if [ -f "$fullpath" ]; then
        cp -p "$fullpath" "$_tmp_write" 2>/dev/null || true
    fi
    if ! printf '%s\n' "$content" > "$_tmp_write" 2>/dev/null || ! mv -f "$_tmp_write" "$fullpath" 2>/dev/null; then
        rm -f "$_tmp_write" 2>/dev/null || true
        if ! printf '%s\n' "$content" > "$fullpath" 2>/dev/null; then
            ui_err "Write failed: $filepath (permission denied or invalid path)"
            return 1
        fi
    fi
    local lines
    lines=$(printf '%s' "$content" | wc -l)
    lines=$((lines + 1))

    # Ambient Tree-sitter AST validation badge
    declare -f tools_check_treesitter_badge &>/dev/null && tools_check_treesitter_badge "$filepath" "$content" "Tree-sitter AST syntax warning for"

    local _loc_note=""
    if [ -n "$fullpath" ] && [[ "$fullpath" == *"/.george/workspaces/"* ]] && [[ "$filepath" != *".george/workspaces/"* ]]; then
        _loc_note=" [resolved: ${fullpath#${LODGE_DIR}/}]"
    fi
    if [ "$existed" -eq 1 ]; then
        ui_ok "Overwrote: $filepath ($lines lines)${_loc_note}"
    else
        ui_ok "Created: $filepath ($lines lines)${_loc_note}"
    fi
}
