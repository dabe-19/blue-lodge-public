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
