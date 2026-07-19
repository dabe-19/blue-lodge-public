#!/bin/bash
# ── George: Tool Execution Engine ──────────────────────────
# Parses LLM responses and applies file/shell operations.
# Permissioned: asks before destructive actions.

[ -n "${_LIB_TOOLS_LOADED:-}" ] && return 0; _LIB_TOOLS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Permission Levels ──────────────────────────────────────────
# 0 = ask always, 1 = ask for destructive, 2 = auto-approve all
LODGE_PERMISSION="${LODGE_PERMISSION:-1}"

# ── Filename sanitization ──────────────────────────────────────
# Strips quotes, replaces spaces, removes special characters.
# Used everywhere a filename comes in from LLM output or user input.

# Expand ~ and ~/ at the start of a path to $HOME.
# Must be called BEFORE tools_sanitize_filename() which strips ~.
# Safe: only expands leading tilde, never interior tildes.
tools_expand_tilde() {
    local p="$1"
    case "$p" in
        '~/'*)  echo "${HOME}${p:1}" ;;
        '~')    echo "$HOME" ;;
        *)      echo "$p" ;;
    esac
}

tools_sanitize_filename() {
    local f="$1"
    # Strip leading/trailing whitespace
    f=$(echo "$f" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # Strip all quote characters (single, double, backtick)
    f=$(echo "$f" | sed 's/["'"'"'`]//g')
    # Replace spaces with hyphens
    f=$(echo "$f" | tr ' ' '-')
    # Remove characters that are problematic in filenames
    # Keep: alphanumeric, dash, underscore, dot, slash (for paths)
    f=$(echo "$f" | sed 's/[^a-zA-Z0-9_./-]//g')
    # Collapse multiple dashes/dots
    f=$(echo "$f" | sed 's/--\+/-/g; s/\.\.\+/./g')
    # Remove leading dash from the whole thing if no path
    f=$(echo "$f" | sed 's/^-//')
    # Never return empty
    [ -z "$f" ] && f="unnamed_file"
    echo "$f"
}

# ── File extension library ─────────────────────────────────────
# Sorted longest-first so greedy extensions (e.g. .jsonl) match before
# their shorter prefixes (.json). The awk pattern in tools_fix_ext_spacing()
# relies on this ordering to avoid false positives where .ts would match
# inside .tsx, or .js inside .json.
#
# Authoritative list derived from the George Agent File Extension Reference.
# Categories: programming/scripting, documentation/knowledge, image/vision,
# configuration/serialization, system/security, plus common extras.
_TOOLS_EXTENSIONS=(
    # 7+ char extensions (longest first)
    .gitignore
    # 5-6 char extensions
    .ipynb .jsonl .xhtml .phtml .shtml .class .cmake
    # 4-char extensions
    .json .yaml .toml .lock .bash .fish .conf .diff .spec .avif
    .html .scss .sass .less .wasm .http .jpeg .tiff .webp .webm
    .java .rust .dart .perl .ruby .lisp .hurl .text
    .make .flac .opus .epub .xlsx .docx .pptx
    # 3-char extensions (longer variants like .tsx before .ts, .jsx before .js)
    .tsx .jsx .cpp .hpp .cxx .hxx .zig .nim .lua .vim .sql .vue .svx
    .py .rs .js .ts .go .rb .sh .md .cs .fs .hs .el .ex .kt .jl
    .yml .ini .env .cfg .csv .xml .svg .tex .rst .org .txt .log .pid .enc
    .css .htm .php .asp .jsp .erb .ejs .hbs .pug
    .png .jpg .gif .bmp .ico .mp3 .mp4 .avi .mkv .mov .wav .ogg .pdf
    .zip .tar .rpm .deb .dmg .img .iso .apk .jar .war .gem .whl
    .bat .cmd .ps1 .psm .awk .sed .zsh .xsl .man .doc .ppt .xls .rtf
    # 2-char extensions
    # CAUTION: Single-letter extensions like .a, .o, .s, .v, .d are excluded.
    # They conflict with common TLDs (.ai, .org, .sh, .vc, .dev) and URL
    # path components, causing broken URLs. Only include 2-char extensions
    # that are unambiguous and commonly emitted by LLMs without spacing.
    .c .h .r .m
)

# ── Fix missing space after file extensions ────────────────────
# LLMs frequently hallucinate merged text like:
#   /write filename.txtThis is the file content
#   /save src/main.rsuse std::io;
# This function detects when a known file extension is immediately
# followed by a non-space, non-punctuation character and injects a
# space at the boundary.
#
# The extension list is sorted longest-first so that e.g. ".jsonl"
# is tested before ".json", preventing a false split at ".json" + "l...".
#
# Usage: fixed=$(tools_fix_ext_spacing "filename.txtSome content")
#        → "filename.txt Some content"
tools_fix_ext_spacing() {
    local input="$1"
    [ -z "$input" ] && return 0

    # ── URL PROTECTION ────────────────────────────────────────
    # URLs must be left completely untouched. If the input contains a URL
    # (http://, https://, or ftp://), temporarily replace it with a
    # placeholder, run the extension fixer on the remainder, then restore.
    # This prevents TLD/path components like .ai, .io, .com/path from
    # triggering false extension splits.
    local _url_placeholders=()
    local _url_idx=0
    local processed="$input"
    # Protect protocol URLs (http://, https://, ftp://)
    # AND bare www. URLs (www.example.com) that lack a scheme.
    while [[ "$processed" =~ (https?://[^[:space:]]+|ftp://[^[:space:]]+|www\.[^[:space:]]+) ]]; do
        local _url="${BASH_REMATCH[1]}"
        local _placeholder="__LODGE_URL_${_url_idx}__"
        _url_placeholders+=("$_url")
        processed="${processed/"$_url"/$_placeholder}"
        _url_idx=$((_url_idx + 1))
    done
    input="$processed"

    # Build an alternation pattern from the extension list, longest first.
    # Escape dots for regex. The list is already sorted longest-first.
    local ext_pattern=""
    for ext in "${_TOOLS_EXTENSIONS[@]}"; do
        local escaped="${ext//./\\.}"
        ext_pattern="${ext_pattern:+${ext_pattern}|}${escaped}"
    done

    # Match: (extension)(immediately followed by a word character that is
    # NOT another dot — a dot means it's a deeper extension like .tar.gz
    # or a dotfile path component).
    # We use perl-compatible lookahead via sed + capturing groups.
    # Strategy: for each extension (longest first), check if input contains
    # that extension followed immediately by [A-Za-z0-9_] and inject a space.
    #
    # We iterate extensions instead of one mega-regex because we need the
    # longest-match guarantee: if ".jsonl" matches, we must NOT also split
    # at ".json".
    local result="$input"
    for ext in "${_TOOLS_EXTENSIONS[@]}"; do
        local escaped="${ext//./\\.}"
        # Check: does the string contain this extension followed by a word char?
        # The word char must NOT be preceded by a longer extension that already
        # matched — but since we go longest-first the first match wins.
        #
        # Pattern: (escaped_ext)([A-Za-z0-9_])
        # But we must NOT match if a longer extension starting with this one
        # exists and matches. E.g., for .json, skip if .jsonl matches at
        # the same position. The longest-first iteration handles this: once
        # we inject a space for .jsonl, the .json pattern no longer sees a
        # word char immediately after .json (it sees "l " — but wait, we
        # already fixed it). Actually, after fixing .jsonl→".jsonl X", .json
        # won't falsely trigger because the char after .json is now "l" which
        # is part of the already-fixed extension. So we need a smarter check.
        #
        # Robust approach: only inject space if the char after the extension
        # is an uppercase letter (LLM hallucination: .txtThis, .rsuse) OR
        # if the token after extension doesn't form a longer known extension.
        # Simplification: check if ext + next chars forms a longer known ext.
        if echo "$result" | grep -qE "${escaped}[A-Za-z0-9_#<\"\`\(\[\{]"; then
            # Extract what's after the extension
            local after
            after=$(echo "$result" | sed -n "s/.*${escaped}\([A-Za-z0-9_#<\"\`\(\[\{].*\)/\1/p" | head -1)
            if [ -n "$after" ]; then
                # Check if adding this char to the extension creates a longer
                # known extension. E.g., ext=.json, after starts with "l" → .jsonl exists.
                local next_char="${after:0:1}"
                local extended="${ext}${next_char}"
                local is_longer_ext=0
                for longer in "${_TOOLS_EXTENSIONS[@]}"; do
                    if [[ "$longer" == "${extended}"* ]]; then
                        is_longer_ext=1
                        break
                    fi
                done
                if [ "$is_longer_ext" -eq 0 ]; then
                    # Safe to inject space — this is the true extension boundary
                    result=$(echo "$result" | sed "s/${escaped}\([A-Za-z0-9_#<\"\`\(\[\{]\)/${ext} \1/")
                fi
            fi
        fi
    done

    # ── Restore URLs from placeholders ────────────────────────
    for (( i=0; i<${#_url_placeholders[@]}; i++ )); do
        result="${result/__LODGE_URL_${i}__/${_url_placeholders[$i]}}"
    done

    echo "$result"
}

# ── Fix missing space around code fences ───────────────────────
# LLMs sometimes emit code fences glued to surrounding text:
#   "some text```bash\necho hi\n```more text"
# This injects a space on BOTH edges:
#   - Before opening ```: "text ```bash" (space before the backticks)
#   - After closing ```:  "``` more"     (space after the backticks)
# Only fires when there is NO existing space at the boundary.
tools_fix_fence_spacing() {
    local input="$1"
    [ -z "$input" ] && return 0

    local result="$input"
    # Leading edge: inject space before ``` when preceded by non-space, non-newline
    # Handles ```bash, ```python, ```rust, plain ``` etc.
    result=$(echo "$result" | sed 's/\([^ \t\n`]\)\(```\)/\1 \2/g')
    # Trailing edge: inject space after ``` when followed by non-space, non-newline
    # Careful: don't match ```bash (opening fence with lang tag) — only bare ```
    # followed by a non-backtick, non-space word character.
    # Strategy: match ``` at end-of-fence (followed by a word char that isn't
    # part of a language tag). We handle two cases:
    #   1. Closing ``` followed by text: "```some text" → "``` some text"
    #      But not "```bash" which is an opening fence.
    #   2. Opening ```lang followed by text after a newline is fine (that's code).
    # Heuristic: if ``` is followed by [A-Za-z], check if it looks like a
    # known fence language tag. If not, inject space.
    # Simple approach: inject space after ``` when followed by a character
    # that is NOT a letter (fence tags always start with a letter) and is
    # not a space/newline/backtick.
    result=$(echo "$result" | sed 's/```\([^a-zA-Z` \t\n]\)/``` \1/g')
    # Also handle: closing ``` immediately followed by a word (non-fence-tag)
    # where the word doesn't look like a language identifier.
    # This catches: "```Hello world" but not "```bash"
    # We check: does the text after ``` NOT match a known code fence language?
    # Pragmatic: inject space after ```<UPPERCASE> since lang tags are lowercase.
    result=$(echo "$result" | sed 's/```\([A-Z]\)/``` \1/g')

    echo "$result"
}

# ── Fix missing space around markdown asterisk sequences ───────
# LLMs sometimes glue bold/italic markers to surrounding words:
#   "some text**bold**more text"  → "some text **bold** more text"
#   "word***emphasis***next"      → "word ***emphasis*** next"
# Uses pair-counting (odd=opening, even=closing) to inject spaces
# only at OUTER boundaries, preserving internal **content** intact.
# Handles ** (bold) and *** (bold+italic). Single * is ignored
# (too common in bullet points and multiplication).
tools_fix_asterisk_spacing() {
    local input="$1"
    [ -z "$input" ] && return 0

    echo "$input" | awk '{
        line = $0
        result = ""
        pair_count = 0
        while (match(line, /\*\*\*?/)) {
            prefix = substr(line, 1, RSTART - 1)
            marker = substr(line, RSTART, RLENGTH)
            line   = substr(line, RSTART + RLENGTH)
            pair_count++

            if (pair_count % 2 == 1) {
                # Opening marker: ensure space BEFORE it if preceded by wordchar
                if (prefix != "" && match(prefix, /[a-zA-Z0-9)}\]]$/))
                    result = result prefix " " marker
                else
                    result = result prefix marker
            } else {
                # Closing marker: just append (no space before closing **)
                result = result prefix marker
                # Ensure space AFTER closing marker if followed by wordchar
                if (line != "" && match(line, /^[a-zA-Z0-9({[]/))
                    result = result " "
            }
        }
        result = result line
        print result
    }'
}

# ── Combined LLM output spacing fixer ─────────────────────────
# Applies all heuristic spacing fixes in sequence:
#   1. File extension spacing   (.txtContent → .txt Content)
#   2. Code fence spacing       (text```bash → text ```bash)
#   3. Asterisk spacing         (word**bold**next → word **bold** next)
# Use this as the single entry point wherever LLM output needs cleanup.
tools_fix_llm_spacing() {
    local input="$1"
    [ -z "$input" ] && return 0
    local result
    result=$(tools_fix_ext_spacing "$input")
    result=$(tools_fix_dash_separator "$result")
    result=$(tools_fix_fence_spacing "$result")
    result=$(tools_fix_asterisk_spacing "$result")
    echo "$result"
}

# ── Fix dash separator glued to file extensions ────────────────
# LLMs sometimes emit: /write tesla.md---# Tesla Data Report
# where "---" (2+ dashes) is glued to the file extension.
# This detects the pattern and injects a space at the boundary.
# Result: "tesla.md ---# Tesla Data Report" → awk splits correctly.
tools_fix_dash_separator() {
    local input="$1"
    [ -z "$input" ] && return 0
    # Match: known extension followed by 2+ dashes
    # Replace ext---content with "ext ---content" (space before dashes)
    # The --- will then be treated as content by the filepath parser.
    # Only fire if the input contains a dot (likely has an extension).
    if [[ "$input" != *.* ]]; then
        echo "$input"
        return 0
    fi
    # Pattern: (.ext)(---+)(content)  →  (.ext) (content after dashes)
    # Strip the dashes entirely — they're a formatting artifact, not content.
    local result
    result=$(echo "$input" | sed 's/\(\.[a-zA-Z0-9]\{1,10\}\)---*/ \1 /g')
    # If sed changed nothing (no match), the above is harmless.
    # However the above is aggressive. More precise: only match if
    # dashes are followed by non-dash content (not just trailing dashes).
    # Rewrite: use a targeted approach
    result="$input"
    if [[ "$input" =~ \.[a-zA-Z0-9]+--+ ]]; then
        # Extract extension+dashes pattern and split it
        result=$(echo "$input" | sed 's/\(\.[a-zA-Z0-9]\{1,10\}\)--\+\(.\)/\1 \2/g')
    fi
    echo "$result"
}

# ── Extract bash code blocks ──────────────────────────────────
# Resilient to common LLM formatting errors:
#   - Missing closing ``` (unterminated block)
#   - Extra whitespace around backticks
#   - ``bash (2 backticks) or ````bash (4 backticks)
tools_extract_bash() {
    local response="$1"
    # Normalize: strip leading whitespace on fence lines, tolerate 2-4 backticks
    local normalized
    normalized=$(echo "$response" | sed 's/^[[:space:]]*//' | sed 's/^`\{2,4\}bash/```bash/' | sed 's/^`\{2,4\}$/```/')
    # Extract between ```bash and ``` (or EOF if block is unterminated)
    echo "$normalized" | awk '
        /^```bash.+/ {
            # Inline block: ```bash<cmd>``` or ```bash<cmd> (no newline)
            line = $0
            sub(/^```bash/, "", line)
            sub(/```$/, "", line)
            if (line != "") print line
            # If closing ``` was on same line, done; otherwise start capture
            if ($0 ~ /```$/) next
            capture=1; next
        }
        /^```bash/ { capture=1; next }
        /^```$/    { if (capture) capture=0; next }
        capture    { print }
    '
}

# ── Extract slash commands from LLM response ──────────────────
# Scans for lines starting with / that match registered commands.
# Only extracts commands OUTSIDE of code blocks to avoid false
# positives from code examples.
tools_extract_slash_commands() {
    local response="$1"

    # Parse: skip lines inside code blocks, emit /command lines outside
    echo "$response" | awk '
        /^```/   { in_block = !in_block; next }
        in_block { next }
        /^\/[a-z]/ { print }
    '
}

# ── Extract file writes from response ─────────────────────────
# Format: ```lang\n# filepath: ./path/to/file\n...code...\n```
tools_extract_files() {
    local response="$1"
    local temp_dir
    temp_dir=$(mktemp -d)
    
    # Normalize backtick fences (2-4 backticks → 3) before parsing
    echo "$response" | sed 's/^[[:space:]]*//' | sed 's/^`\{2,4\}\([a-zA-Z]\)/```\1/' | sed 's/^`\{2,4\}$/```/' | awk -v outdir="$temp_dir" '
    /^```[a-zA-Z]/ { 
        in_block=1
        lang=substr($0, 4)
        gsub(/[^a-zA-Z0-9_-]/, "", lang)
        filepath=""
        content=""
        next 
    }
    /^```$/ { 
        if (in_block && filepath != "") {
            outfile = outdir "/" NR
            printf "%s\n%s", filepath, content > outfile
        }
        in_block=0
        next 
    }
    # Tolerate common LLM misspellings: filepath, file_path, file path, Filepath
    in_block && /^[[:space:]]*(\/\/|#) *(file_?path|file path|File_?[Pp]ath):/ {
        f = $0
        sub(/.*[Ff]ile[_ ]?[Pp]?ath:[[:space:]]*/, "", f)
        gsub(/[[:space:]]*$/, "", f)
        # Strip quotes from value (double, single, backtick)
        gsub(/["\047`]/, "", f)
        # Replace spaces with hyphens
        gsub(/ /, "-", f)
        # Remove problematic special characters (keep alnum . - _ /)
        gsub(/[^a-zA-Z0-9_./-]/, "", f)
        filepath = f
        next
    }
    in_block { content = content $0 "\n" }
    END {
        # Flush unterminated block if it had a filepath
        if (in_block && filepath != "") {
            outfile = outdir "/" NR
            printf "%s\n%s", filepath, content > outfile
        }
    }
    '
    
    echo "$temp_dir"
}

# ── Execute bash commands with permission check ────────────────
tools_exec_bash() {
    local commands="$1"
    local workdir="${2:-.}"
    
    if [ -z "$commands" ]; then return 0; fi
    
    # Show what will be executed
    ui_section "Shell Commands"
    ui_code_block "bash" "$commands"
    
    # Network audit mode: block network-accessing commands from LLM
    if [ "${LODGE_NETWORK_AUDIT:-0}" -eq 1 ]; then
        if ! security_check_network "$commands"; then
            ui_err "Blocked: command accesses the network (network audit mode is ON)"
            ui_dim "Disable with: LODGE_NETWORK_AUDIT=0"
            return 1
        fi
    fi
    
    # Permission check
    if [ "$LODGE_PERMISSION" -eq 0 ]; then
        if ! ui_confirm "Execute these commands?"; then
            ui_warn "Skipped by user"
            return 1
        fi
    elif [ "$LODGE_PERMISSION" -eq 1 ]; then
        # First check: is the command on the safe allowlist?
        if security_check_allowlist "$commands" 2>/dev/null; then
            : # Allowlisted — proceed without asking
        elif echo "$commands" | grep -qE '(rm -rf|sudo|chmod 777|dd if=|mkfs|>[[:space:]]*/dev/|curl.*\|[[:space:]]*(ba)?sh|wget.*\|[[:space:]]*(ba)?sh|nc[[:space:]]+-|ncat|/dev/tcp|mkfifo|eval[[:space:]]|(^|[^a-zA-Z])exec[[:space:]]|>[[:space:]]*/etc/)'; then
            ui_warn "Potentially dangerous command detected!"
            if ! ui_confirm "Execute anyway?" "n"; then
                ui_warn "Skipped by user"
                return 1
            fi
        else
            # Not allowlisted, not blocklisted — ask for confirmation
            if ! ui_confirm "Execute?"; then
                ui_warn "Skipped by user"
                return 1
            fi
        fi
    fi
    
    # Pre-exec resource check — prevent writes when disk is critically low
    if declare -f vitals_guard_disk &>/dev/null; then
        if ! vitals_guard_disk 2>/dev/null; then
            ui_err "Blocked: disk critically low — refusing to execute"
            LAST_CMD_EXIT=1
            return 1
        fi
    fi

    # Execute and capture output
    local output
    local exit_code
    output=$(cd "$workdir" && bash -e -c "$commands" 2>&1)
    exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        if [ -n "$output" ]; then
            # Truncate long output
            local lines
            lines=$(echo "$output" | wc -l)
            if [ "$lines" -gt 30 ]; then
                echo "$output" | head -15
                ui_dim "... ($((lines - 30)) lines omitted) ..."
                echo "$output" | tail -15
            else
                echo "$output"
            fi
        fi
        ui_ok "Command succeeded"
    else
        ui_err "Command failed (exit $exit_code)"
        echo "$output" | tail -20
    fi
    
    # Return output for memory updates
    LAST_CMD_OUTPUT="$output"
    LAST_CMD_EXIT=$exit_code
    return $exit_code
}

# ── Write files with permission check ─────────────────────────
tools_write_file() {
    local filepath="$1"
    local content="$2"
    local workdir="${3:-.}"
    
    # Sanitize the filename — strip quotes, spaces, special chars
    filepath=$(tools_sanitize_filename "$filepath")
    
    # Resolve path
    local fullpath
    if [[ "$filepath" == /* ]]; then
        fullpath="$filepath"
    else
        fullpath="$workdir/$filepath"
    fi
    
    # Normalize
    fullpath=$(realpath -m "$fullpath")
    
    # Safety: don't write outside workdir
    local real_workdir
    real_workdir=$(realpath "$workdir")
    if [[ ! "$fullpath" == "$real_workdir"* ]]; then
        ui_err "Refusing to write outside workspace: $filepath"
        return 1
    fi
    
    local exists=0
    [ -f "$fullpath" ] && exists=1
    
    if [ "$exists" -eq 1 ]; then
        ui_step "Overwriting: $filepath"
        
        # Show diff preview for existing files
        local tmpfile
        tmpfile=$(mktemp "${TMPDIR:-/tmp}/lodge-diff-XXXXXX")
        printf "%s" "$content" > "$tmpfile"
        if command -v diff &>/dev/null; then
            local diff_output
            diff_output=$(diff -u "$fullpath" "$tmpfile" 2>/dev/null | head -40) || true
            if [ -n "$diff_output" ]; then
                ui_section "Changes"
                echo "$diff_output" | while IFS= read -r dline; do
                    case "$dline" in
                        +*) printf "${C_GREEN}%s${C_RESET}\n" "$dline" ;;
                        -*) printf "${C_RED}%s${C_RESET}\n" "$dline" ;;
                        @*) printf "${C_CYAN}%s${C_RESET}\n" "$dline" ;;
                        *)  echo "$dline" ;;
                    esac
                done
                local diff_lines
                diff_lines=$(diff -u "$fullpath" "$tmpfile" 2>/dev/null | wc -l) || true
                if [ "$diff_lines" -gt 40 ]; then
                    ui_dim "(... $((diff_lines - 40)) more diff lines)"
                fi
            fi
        fi
        rm -f "$tmpfile"
    else
        ui_step "Creating: $filepath"
    fi
    
    # Show preview (first 10 lines) for new files only
    if [ "$exists" -eq 0 ]; then
        local preview
        preview=$(echo "$content" | head -10)
        local total_lines
        total_lines=$(echo "$content" | wc -l)
        ui_code_block "" "$preview"
        if [ "$total_lines" -gt 10 ]; then
            ui_dim "(... $((total_lines - 10)) more lines)"
        fi
    fi
    
    # Permission for overwrites
    if [ "$exists" -eq 1 ] && [ "$LODGE_PERMISSION" -le 1 ]; then
        if ! ui_confirm "Overwrite $filepath?"; then
            ui_warn "Skipped"
            return 1
        fi
    fi
    
    # Create directory if needed
    mkdir -p "$(dirname "$fullpath")"
    
    # Write
    local total_lines
    total_lines=$(echo "$content" | wc -l)
    printf "%s" "$content" > "$fullpath"
    ui_ok "Wrote $filepath ($total_lines lines)"
}

# ── Process full LLM response ─────────────────────────────────
# Extracts and executes all operations from a response
tools_process_response() {
    local response="$1"
    local workdir="${2:-.}"
    local results=""
    
    # 1. Extract and execute bash commands
    local bash_cmds
    bash_cmds=$(tools_extract_bash "$response")
    if [ -n "$bash_cmds" ]; then
        # Separate real bash commands from slash commands the LLM
        # mistakenly placed inside ```bash blocks
        local real_bash=""
        local extra_slash=""
        while IFS= read -r _line; do
            if [[ "$_line" =~ ^/[a-z] ]]; then
                extra_slash="${extra_slash:+${extra_slash}
}${_line}"
            else
                real_bash="${real_bash:+${real_bash}
}${_line}"
            fi
        done <<< "$bash_cmds"

        if [ -n "$real_bash" ]; then
            tools_exec_bash "$real_bash" "$workdir"
            local _bash_ts
            _bash_ts=$(date '+%Y-%m-%d %H:%M:%S')
            if [ "${LAST_CMD_EXIT:-0}" -eq 0 ]; then
                results="[$_bash_ts] OK: shell commands (exit 0)"
            else
                results="[$_bash_ts] FAIL: shell commands (exit $LAST_CMD_EXIT)"
            fi
        fi
    fi
    
    # 2. Extract and write files
    local files_dir
    files_dir=$(tools_extract_files "$response")
    if [ -d "$files_dir" ]; then
        for entry in "$files_dir"/*; do
            [ -f "$entry" ] || continue
            local fpath
            fpath=$(head -1 "$entry")
            local fcontent
            fcontent=$(tail -n +2 "$entry")
            if [ -n "$fpath" ] && [ -n "$fcontent" ]; then
                tools_write_file "$fpath" "$fcontent" "$workdir"
                local _write_ts
                _write_ts=$(date '+%Y-%m-%d %H:%M:%S')
                results="${results:+$results; }[$_write_ts] Wrote: $fpath"
            fi
        done
        rm -rf "$files_dir"
    fi

    # 3. Extract and execute slash commands from the response
    # George can invoke his own tools by outputting /command lines.
    # We scan lines outside of code blocks for registered commands,
    # plus any slash commands found inside bash blocks above.
    local slash_cmds
    slash_cmds=$(tools_extract_slash_commands "$response")
    if [ -n "${extra_slash:-}" ]; then
        slash_cmds="${slash_cmds:+${slash_cmds}
}${extra_slash}"
    fi
    if [ -n "$slash_cmds" ]; then
        while IFS= read -r scmd; do
            [ -z "$scmd" ] && continue
            local _cmd_start_ts
            _cmd_start_ts=$(date '+%Y-%m-%d %H:%M:%S')
            ui_section "Tool Invocation"
            ui_step "[$_cmd_start_ts] $scmd"
            if declare -f commands_dispatch &>/dev/null; then
                commands_dispatch "$scmd" "$workdir"
                local _cmd_rc=$?
                local _cmd_end_ts
                _cmd_end_ts=$(date '+%Y-%m-%d %H:%M:%S')
                if [ $_cmd_rc -eq 0 ]; then
                    results="${results:+$results; }[$_cmd_end_ts] OK: $scmd"
                else
                    results="${results:+$results; }[$_cmd_end_ts] FAIL(exit $_cmd_rc): $scmd"
                fi
            fi
        done <<< "$slash_cmds"
    fi
    
    echo "$results"
}

# ── Read file for context ─────────────────────────────────────
tools_read_file() {
    local filepath="$1"
    local max_lines="${2:-100}"
    
    if [ ! -f "$filepath" ]; then
        echo "ERROR: File not found: $filepath"
        return 1
    fi
    
    local total
    total=$(wc -l < "$filepath")
    
    if [ "$total" -le "$max_lines" ]; then
        cat "$filepath"
    else
        head -n "$max_lines" "$filepath"
        echo ""
        echo "... (truncated, $total total lines)"
    fi
}

# ── Phone App Integration (Termux API) ────────────────────────
# Each requires explicit permission

tools_phone_notify() {
    local title="$1"
    local msg="$2"
    if _lodge_termux_api_ok && command -v termux-notification &>/dev/null; then
        termux-notification --title "$title" --content "$msg"
        ui_ok "Notification sent"
    fi
}

tools_phone_clipboard_set() {
    local text="$1"
    if _lodge_termux_api_ok && command -v termux-clipboard-set &>/dev/null; then
        echo "$text" | termux-clipboard-set
        ui_ok "Copied to clipboard"
    fi
}

tools_phone_clipboard_get() {
    if _lodge_termux_api_ok && command -v termux-clipboard-get &>/dev/null; then
        termux-clipboard-get
    else
        echo ""
    fi
}

tools_phone_open_url() {
    local url="$1"
    if [ "$LODGE_PERMISSION" -le 1 ]; then
        if ! ui_confirm "Open URL: $url?"; then
            return 1
        fi
    fi
    if _lodge_termux_api_ok && command -v termux-open-url &>/dev/null; then
        termux-open-url "$url"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$url"
    fi
}

tools_phone_share() {
    local filepath="$1"
    if _lodge_termux_api_ok && command -v termux-share &>/dev/null; then
        termux-share "$filepath"
    fi
}

tools_phone_battery() {
    if _lodge_termux_api_ok && command -v termux-battery-status &>/dev/null; then
        timeout 3 termux-battery-status 2>/dev/null | jq '{percentage, status, temperature}' 2>/dev/null
    else
        echo '{"percentage": "unknown"}'
    fi
}

tools_phone_vibrate() {
    if _lodge_termux_api_ok && command -v termux-vibrate &>/dev/null; then
        termux-vibrate -d 100
    fi
}

tools_phone_toast() {
    local msg="$1"
    if _lodge_termux_api_ok && command -v termux-toast &>/dev/null; then
        termux-toast "$msg"
    fi
}

# ── Inline /read expansion ────────────────────────────────────
# When used inside a /email body or /write content, the LLM may
# embed "/read <filepath>" to inline file contents. This function
# detects and replaces such references with the actual file content.
#
# For PDF files, uses _web_extract_pdf (pdftotext + strings fallback)
# when available, otherwise falls back to strings(1) directly.
#
# Patterns matched:
#   /read <filepath>         — reads the file
#   /read <filepath> <extra> — reads the file, appends extra text
#
# Usage: expanded=$(tools_expand_inline_read "$text")
tools_expand_inline_read() {
    local text="$1"

    # Quick bail — nothing to expand
    [[ "$text" == */read\ * ]] || [[ "$text" == /read\ * ]] || [[ "$text" == read\ * ]] || return 0

    # Extract the /read reference: /read <filepath>
    # The filepath is the token immediately after /read
    local _read_path=""
    if [[ "$text" =~ ^/?read[[:space:]]+([^[:space:]]+) ]]; then
        _read_path="${BASH_REMATCH[1]}"
    elif [[ "$text" =~ /read[[:space:]]+([^[:space:]]+) ]]; then
        _read_path="${BASH_REMATCH[1]}"
    fi

    if [ -z "$_read_path" ]; then
        echo "$text"
        return 0
    fi

    if [ ! -f "$_read_path" ]; then
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [debug] inline /read: file not found: %s\n' "$_read_path" >&2
        echo "$text"
        return 0
    fi

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [debug] inline /read: expanding %s\n' "$_read_path" >&2

    local _file_content

    # ── PDF handling ─────────────────────────────────────────
    if [[ "${_read_path,,}" == *.pdf ]]; then
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [debug] inline /read: PDF detected, extracting text\n' >&2
        if declare -f _web_extract_pdf &>/dev/null; then
            _file_content=$(_web_extract_pdf "$_read_path")
        elif command -v pdftotext &>/dev/null; then
            _file_content=$(pdftotext -layout -q "$_read_path" - 2>/dev/null | head -2000)
        elif command -v strings &>/dev/null; then
            _file_content=$(strings "$_read_path" 2>/dev/null | grep -E '[a-zA-Z]{3,}' | head -1000)
        fi
        if [ -z "$_file_content" ]; then
            [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [debug] inline /read: PDF text extraction failed for %s\n' "$_read_path" >&2
            echo "$text"
            return 0
        fi
    else
        _file_content=$(cat "$_read_path")
    fi

    # Replace the /read <filepath> token with the file content
    # Preserve any text before or after the /read reference
    local _before _after
    _before="${text%%/read *}"
    # Remove leading / if text starts with /read (no prefix)
    [ -z "$_before" ] && [[ "$text" == /read* ]] && _before=""
    _after="${text#*/read }"
    # _after starts with "<filepath> <rest>" — remove the filepath token
    _after="${_after#"$_read_path"}"
    _after="${_after# }"  # trim leading space

    # Assemble: prefix + file content + suffix
    local _result="${_before}${_file_content}"
    [ -n "$_after" ] && _result="${_result}
${_after}"
    echo "$_result"
}

# ── Auto-expand readable file references in text ─────────────
# Scans a text string for tokens that look like paths to readable
# files (e.g. report.md, notes.txt, data.json). When found AND the
# file exists on disk, replaces the filename token with the full
# file contents inlined. This lets George reference files in
# /social, /email, and /write text and have them expanded
# transparently — no /read prefix required.
#
# Skips:
#   - URLs (http:// https://)
#   - Attachment flags (f=file, file=file, attach=file)
#   - Tokens inside markdown links [text](url)
#   - Files that don't exist
#   - Binary/image extensions
#
# Readable extensions (text-like files only):
#   .txt .md .rst .csv .json .jsonl .yaml .yml .toml .xml .html
#   .htm .log .conf .cfg .ini .env .sh .bash .zsh .py .rs .js
#   .ts .go .rb .c .h .cpp .hpp .java .kt .sql .graphql .tex
#   .org .diff .patch
#
# Usage: expanded=$(tools_expand_file_refs "$text" "$workdir" [max_chars])
#   max_chars: if >0, truncate each expanded file to N chars (0 or empty=unlimited)
tools_expand_file_refs() {
    local text="$1"
    local workdir="${2:-.}"
    local max_chars="${3:-}"
    local changed=0

    # Quick bail — no dots means no file extensions
    [[ "$text" == *.* ]] || { echo "$text"; return 0; }

    # Readable extension set (lowercase, no dot)
    local -A _readable_exts=(
        [txt]=1 [md]=1 [rst]=1 [csv]=1 [json]=1 [jsonl]=1
        [yaml]=1 [yml]=1 [toml]=1 [xml]=1 [html]=1 [htm]=1
        [log]=1 [conf]=1 [cfg]=1 [ini]=1 [env]=1
        [sh]=1 [bash]=1 [zsh]=1 [py]=1 [rs]=1 [js]=1 [ts]=1
        [go]=1 [rb]=1 [c]=1 [h]=1 [cpp]=1 [hpp]=1 [java]=1
        [kt]=1 [sql]=1 [graphql]=1 [tex]=1 [org]=1
        [diff]=1 [patch]=1 [pdf]=1
    )

    # Build result word by word
    local result=""
    local token prev_token=""
    local -A _ef_seen=()  # dedup: skip files already expanded in this call

    local _ef_tmp
    _ef_tmp=$(mktemp "${TMPDIR:-/tmp}/tools-expand.XXXXXX")
    # Quote $text to prevent glob expansion (*.md → GEORGE.md README.md ...)
    # and word-split the text safely by reading into an array first.
    local -a _ef_words
    read -ra _ef_words <<< "$text"
    printf '%s\0' "${_ef_words[@]}" > "$_ef_tmp"
    while IFS= read -r -d '' token || [ -n "$token" ]; do
        # Skip empty tokens from leading/trailing spaces
        [ -z "$token" ] && continue

        # Skip URLs
        if [[ "$token" =~ ^https?:// ]]; then
            result="${result:+$result }${token}"
            prev_token="$token"
            continue
        fi

        # Skip attachment flags: f=file, file=file, attach=file
        if [[ "$token" =~ ^(f|file|attach)= ]]; then
            result="${result:+$result }${token}"
            prev_token="$token"
            continue
        fi

        # Skip if inside markdown link syntax — previous token ends with ](
        # or token starts with ]( — these are URLs not files
        if [[ "$prev_token" == *"](" ]] || [[ "$token" == "]("* ]]; then
            result="${result:+$result }${token}"
            prev_token="$token"
            continue
        fi

        # Strip trailing punctuation for extension check but keep for replacement
        local clean="$token"
        clean="${clean%,}"
        clean="${clean%.}"
        clean="${clean%)}"
        clean="${clean%\"}"
        clean="${clean%\'}"

        # Check if this token has a readable extension
        local ext=""
        if [[ "$clean" =~ \.([a-zA-Z0-9]+)$ ]]; then
            ext="${BASH_REMATCH[1],,}"  # lowercase
        fi

        if [ -n "$ext" ] && [ -n "${_readable_exts[$ext]:-}" ]; then
            # Looks like a readable file reference — resolve path
            local fpath="$clean"

            # Strip backticks (LLM wraps in `filename.txt`)
            fpath="${fpath#\`}"
            fpath="${fpath%\`}"
            # Strip surrounding parens
            fpath="${fpath#(}"
            fpath="${fpath%)}"

            # Try: LODGE_DIR-qualified, as-is, workspace-relative, then /write-style sandbox
            local resolved=""
            if [[ "$fpath" == "${LODGE_DIR:-$HOME/blue-lodge}"/* ]] && [ -f "$fpath" ]; then
                # Fully qualified path within LODGE_DIR — use as-is
                resolved="$fpath"
            elif [ -f "$fpath" ]; then
                resolved="$fpath"
            elif [ -f "$workdir/$fpath" ]; then
                resolved="$workdir/$fpath"
            elif [[ "$fpath" == /* ]]; then
                # Absolute path not found as-is — strip leading /
                # and resolve relative to workdir (/write-style sandboxing)
                local _rel="${fpath#/}"
                if [ -f "$workdir/$_rel" ]; then
                    resolved="$workdir/$_rel"
                fi
            fi

            # Try newest workspace directory fallback (resolves write-sandboxed files)
            if [ -z "$resolved" ] && [ -f "$workdir/.george/workspaces/$fpath" ]; then
                resolved="$workdir/.george/workspaces/$fpath"
            fi
            if [ -z "$resolved" ]; then
                local _newest_ws
                _newest_ws=$(ls -td "$workdir/.george/workspaces"/*/ 2>/dev/null | head -1)
                if [ -n "$_newest_ws" ] && [ -f "${_newest_ws}${fpath}" ]; then
                    resolved="${_newest_ws}${fpath}"
                fi
            fi

            # Try AGENT_OUTPUT_DIR directory fallback
            if [ -z "$resolved" ] && [ -n "${AGENT_OUTPUT_DIR:-}" ]; then
                if [ -f "$workdir/${AGENT_OUTPUT_DIR}/${fpath}" ]; then
                    resolved="$workdir/${AGENT_OUTPUT_DIR}/${fpath}"
                fi
            fi

            if [ -n "$resolved" ]; then
                # Dedup: skip files already expanded in this call
                if [ -n "${_ef_seen[$resolved]:-}" ]; then
                    result="${result:+$result }${token}"
                    prev_token="$token"
                    continue
                fi
                _ef_seen[$resolved]=1
                local _content
                if [[ "${ext}" == "pdf" ]]; then
                    # PDF: use text extraction
                    if declare -f _web_extract_pdf &>/dev/null; then
                        _content=$(_web_extract_pdf "$resolved")
                    elif command -v pdftotext &>/dev/null; then
                        _content=$(pdftotext -layout -q "$resolved" - 2>/dev/null | head -2000)
                    elif command -v strings &>/dev/null; then
                        _content=$(strings "$resolved" 2>/dev/null | grep -E '[a-zA-Z]{3,}' | head -1000)
                    fi
                else
                    _content=$(cat "$resolved")
                fi

                if [ -n "$_content" ]; then
                    # Truncate to max_chars if set
                    local _truncated=0
                    if [ -n "$max_chars" ] && [ "$max_chars" -gt 0 ] 2>/dev/null && [ "${#_content}" -gt "$max_chars" ]; then
                        local _orig_len=${#_content}
                        _content="${_content:0:$max_chars}"
                        _content="${_content}
... ($((_orig_len - max_chars)) chars truncated)"
                        _truncated=1
                    fi
                    [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [debug] file-ref expand: %s (%d chars%s)\n' "$resolved" "${#_content}" "$([ $_truncated -eq 1 ] && echo ", capped at $max_chars")" >&2

                    # Preserve any trailing punctuation that was stripped
                    local suffix="${token#"$clean"}"
                    result="${result:+$result
}${_content}${suffix}"
                    changed=1
                    prev_token="$token"
                    continue
                fi
            fi
        fi

        result="${result:+$result }${token}"
        prev_token="$token"
    done < "$_ef_tmp"
    rm -f "$_ef_tmp"

    # If nothing changed, return original (preserves exact whitespace)
    if [ "$changed" -eq 0 ]; then
        echo "$text"
    else
        echo "$result"
    fi
}

# Auto-quote filename with spaces if it is unquoted and ends in a known extension.
# E.g., "report investment advice on United Healthgroup.md some content"
#       → "\"report investment advice on United Healthgroup.md\" some content"
tools_quote_filename_spaces() {
    local rest="$1"
    [ -z "$rest" ] && return 0

    if [[ "$rest" == '"'* ]] || [[ "$rest" == "'"* ]]; then
        echo "$rest"
        return 0
    fi

    local words=()
    read -r -a words <<< "$rest"
    
    local found_idx=-1
    local i
    for (( i=0; i<${#words[@]}; i++ )); do
        local word="${words[i]}"
        local ext
        for ext in "${_TOOLS_EXTENSIONS[@]}"; do
            if [[ "$word" == *"${ext}" ]]; then
                found_idx=$i
                break 2
            fi
        done
    done

    if [ "$found_idx" -gt 0 ]; then
        local count=$((found_idx + 1))
        local regex="^(([[:space:]]*[^[:space:]]+){$count})(.*)$"
        if [[ "$rest" =~ $regex ]]; then
            local prefix="${BASH_REMATCH[1]}"
            local content="${BASH_REMATCH[3]}"
            local clean_filename
            clean_filename=$(echo "$prefix" | xargs)
            echo "\"$clean_filename\"$content"
            return 0
        fi
    fi

    echo "$rest"
}

