#!/bin/bash
# DESC: Write content to a file (create, overwrite, or append)
# Usage: /write <filepath> <content...>
#        /write --append <filepath> <content...>
#        /write --edit <filepath> <sed_expression>
#   Writes the given content to the specified file.
#   Creates parent directories automatically.
#
# Modes:
#   Default  — create or overwrite (with protection in interactive mode)
#   --append — append content to end of existing file
#   --edit   — apply sed expression for inline edits
#   Agent    — in non-interactive mode, reads existing file first and
#              logs its contents to micro_memory so the LLM can see
#              what it's overwriting. Prevents blind overwrites.

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
        ui_dim "       /write --append <filepath> <content...>"
        ui_dim "       /write --edit <filepath> <sed_expression>"
        ui_dim "Examples:"
        ui_dim "  /write src/main.rs fn main() { println!(\"hello\"); }"
        ui_dim "  /write --append Cargo.toml [dependencies]\\nreqwest = \"0.11\""
        ui_dim "  /write --edit src/main.rs s/old_func/new_func/g"
        return 1
    fi

    # ── Parse flags ──────────────────────────────────────────
    local mode="write"  # write | append | edit
    case "$args" in
        --append\ *|--append)
            mode="append"
            args="${args#--append }"
            args="${args#--append}"
            ;;
        --edit\ *|--edit)
            mode="edit"
            args="${args#--edit }"
            args="${args#--edit}"
            ;;
    esac

    # Parse: first token is filepath, rest is content
    # Fix LLM hallucination: missing spaces in output
    # e.g. "filename.txtThis is the content" → "filename.txt This is the content"
    if declare -f tools_fix_llm_spacing &>/dev/null; then
        args=$(tools_fix_llm_spacing "$args")
    fi

    local filepath content
    filepath=$(echo "$args" | awk '{print $1}')
    content=$(echo "$args" | sed 's/^[^ ]* *//')

    # Strip trailing dashes from filepath — catches edge case where
    # LLM emits "/write tesla.md---# content" and tools_fix_llm_spacing
    # couldn't fully separate it (e.g., "tesla.md---#" as first token).
    filepath=$(echo "$filepath" | sed 's/--*$//')

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

    # ── Expand escape sequences ────────────────────────────────
    # The LLM sends multi-line content as a single line with \n
    # separators (as instructed by the syntax card). Expand them
    # to real newlines so files are written correctly.
    # SKIP expansion for --edit mode (sed expressions use their own
    # escape conventions).
    if [ "$mode" != "edit" ]; then
        content=$(ui_expand_escapes "$content")
    fi

    # Resolve path relative to workdir
    # SECURITY: Never allow writes outside the workdir tree.
    # LLMs frequently hallucinate absolute paths (e.g. /responses/file.json)
    # which would attempt to write to filesystem root. Strip leading / and
    # treat ALL paths as relative to workdir.
    local fullpath
    if [[ "$filepath" == /* ]]; then
        # Absolute path — make relative to workdir
        filepath="${filepath#/}"
    fi
    fullpath="$workdir/$filepath"

    # Create parent directories if needed
    if ! mkdir -p "$(dirname "$fullpath")" 2>/dev/null; then
        ui_err "Cannot create directory: $(dirname "$filepath")"
        return 1
    fi

    # ── Handle --edit mode (sed inline edits) ──────────────────
    # Validates that content looks like a sed expression before
    # attempting. The model sometimes tries to write entire multi-line
    # code blocks as sed, which always fails.
    if [ "$mode" = "edit" ]; then
        if [ ! -f "$fullpath" ]; then
            ui_err "Cannot edit — file does not exist: $filepath"
            return 1
        fi

        # Guard: reject content that's clearly NOT a sed expression.
        # Valid sed: s/old/new/g, /pattern/d, /pattern/a\text, etc.
        # Invalid: multi-line code the model tried to cram into sed.
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
            ui_dim "  --edit is for SIMPLE substitutions only (e.g. s/old_name/new_name/g)"
            ui_dim "  To rewrite a file, use: /write <filepath> <complete content>"
            return 1
        fi

        # Guard: reject excessively long sed expressions (> 200 chars).
        # These are almost always the model trying to write code as sed.
        if [ "${#content}" -gt 200 ]; then
            ui_err "Edit rejected — sed expression too long (${#content} chars)"
            ui_dim "  --edit is for small, targeted changes."
            ui_dim "  To rewrite a file, use: /write <filepath> <complete content>"
            return 1
        fi

        # content holds the sed expression
        local before_lines after_lines
        before_lines=$(wc -l < "$fullpath")
        if sed -i "$content" "$fullpath" 2>/dev/null; then
            after_lines=$(wc -l < "$fullpath")
            ui_ok "Edited: $filepath ($before_lines → $after_lines lines)"
            return 0
        else
            ui_err "Edit failed — invalid sed expression: $content"
            ui_dim "  --edit is for SIMPLE substitutions: s/old/new/g"
            ui_dim "  To rewrite a file, use: /write <filepath> <complete content>"
            return 1
        fi
    fi

    # ── Handle --append mode ───────────────────────────────────
    if [ "$mode" = "append" ]; then
        if [ ! -f "$fullpath" ]; then
            # File doesn't exist — create it (append to nothing = create)
            printf '%s\n' "$content" > "$fullpath"
            local lines
            lines=$(printf '%s' "$content" | wc -l)
            ui_ok "Created: $filepath ($((lines + 1)) lines)"
            return 0
        fi
        printf '\n%s\n' "$content" >> "$fullpath"
        local lines
        lines=$(wc -l < "$fullpath")
        ui_ok "Appended to: $filepath ($lines total lines)"
        return 0
    fi

    local existed=0
    [ -f "$fullpath" ] && existed=1

    # ── Agent-mode pre-read ───────────────────────────────────
    # When running inside the agent loop (non-interactive), read the
    # existing file and echo a WARNING + contents to stderr so it
    # gets captured in the 2000-byte output and written to micro_memory.
    # This gives the LLM visibility into what it's overwriting, so the
    # strategist/specialist can decide to use --append or --edit next.
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
        echo "OVERWRITING with new content. Use /write --append or /write --edit for partial updates." >&2
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
