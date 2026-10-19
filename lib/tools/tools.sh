#!/bin/bash
# ── George: Tool Execution Engine ──────────────────────────
[ -n "${_LIB_TOOLS_LOADED:-}" ] && return 0; _LIB_TOOLS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$LODGE_DIR:$PATH"
source "$LODGE_DIR/lib/ui/ui.sh"

# 0 = ask always, 1 = ask for destructive, 2 = auto-approve all
LODGE_PERMISSION="${LODGE_PERMISSION:-1}"

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
    f=$(echo "$f" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    f=$(echo "$f" | sed 's/["'"'"'`]//g')
    f=$(echo "$f" | tr ' ' '-')
    f=$(echo "$f" | sed 's/[^a-zA-Z0-9_./-]//g')
    f=$(echo "$f" | sed 's/--\+/-/g; s/\.\.\+/./g')
    f=$(echo "$f" | sed 's/^-//')
    [ -z "$f" ] && f="unnamed_file"
    echo "$f"
}

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
    .c .h .r .m
)

tools_fix_ext_spacing() {
    local input="$1"
    [ -z "$input" ] && return 0

    local _url_placeholders=() _url_idx=0 processed="$input"
    while [[ "$processed" =~ (https?://[^[:space:]]+|ftp://[^[:space:]]+|www\.[^[:space:]]+) ]]; do
        local _url="${BASH_REMATCH[1]}"
        local _placeholder="__LODGE_URL_${_url_idx}__"
        _url_placeholders+=("$_url")
        processed="${processed/"$_url"/$_placeholder}"
        _url_idx=$((_url_idx + 1))
    done
    input="$processed"

    local result="$input" ext
    for ext in "${_TOOLS_EXTENSIONS[@]}"; do
        local escaped="${ext//./\\.}"
        if echo "$result" | grep -qE "${escaped}[A-Za-z0-9_#<\"\`\(\[\{]"; then
            local after
            after=$(echo "$result" | sed -n "s/.*${escaped}\([A-Za-z0-9_#<\"\`\(\[\{].*\)/\1/p" | head -1)
            if [ -n "$after" ]; then
                local next_char="${after:0:1}"
                local extended="${ext}${next_char}"
                local is_longer_ext=0 longer
                for longer in "${_TOOLS_EXTENSIONS[@]}"; do
                    if [[ "$longer" == "${extended}"* ]]; then
                        is_longer_ext=1; break
                    fi
                done
                if [ "$is_longer_ext" -eq 0 ]; then
                    result=$(echo "$result" | sed "s/\(${escaped}\)\([A-Za-z0-9_#<\"\`\(\[\{]\)/\1 \2/g")
                fi
            fi
        fi
    done

    _url_idx=0
    for _url in "${_url_placeholders[@]}"; do
        local _placeholder="__LODGE_URL_${_url_idx}__"
        result="${result/"$_placeholder"/"$_url"}"
        _url_idx=$((_url_idx + 1))
    done

    echo "$result"
}

tools_fix_fence_spacing() {
    local input="$1"
    [ -z "$input" ] && return 0
    local result="$input"
    result=$(echo "$result" | sed 's/\([^ \t\n`]\)\(```\)/\1 \2/g')
    result=$(echo "$result" | sed 's/```\([^a-zA-Z` \t\n]\)/``` \1/g')
    result=$(echo "$result" | sed 's/```\([A-Z]\)/``` \1/g')
    echo "$result"
}

tools_fix_asterisk_spacing() {
    local input="$1"
    [ -z "$input" ] && return 0
    echo "$input" | awk '{
        line = $0; result = ""; pair_count = 0
        while (match(line, /\*\*\*?/)) {
            prefix = substr(line, 1, RSTART - 1)
            marker = substr(line, RSTART, RLENGTH)
            line   = substr(line, RSTART + RLENGTH)
            pair_count++
            if (pair_count % 2 == 1) {
                if (prefix != "" && match(prefix, /[a-zA-Z0-9)}\]]$/))
                    result = result prefix " " marker
                else
                    result = result prefix marker
            } else {
                result = result prefix marker
                if (line != "" && match(line, /^[a-zA-Z0-9({[]/))
                    result = result " "
            }
        }
        result = result line; print result
    }'
}

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

tools_fix_dash_separator() {
    local input="$1"
    [ -z "$input" ] && return 0
    [[ "$input" != *.* ]] && { echo "$input"; return 0; }
    local result="$input"
    if [[ "$input" =~ \.[a-zA-Z0-9]+--+ ]]; then
        result=$(echo "$input" | sed 's/\(\.[a-zA-Z0-9]\{1,10\}\)--\+\(.\)/\1 \2/g')
    fi
    echo "$result"
}

tools_extract_bash() {
    local response="$1"
    local normalized
    normalized=$(echo "$response" | sed 's/^[[:space:]]*//' | sed 's/^`\{2,4\}bash/```bash/' | sed 's/^`\{2,4\}$/```/')
    echo "$normalized" | awk '
        /^```bash.+/ {
            line = $0; sub(/^```bash/, "", line); sub(/```$/, "", line)
            if (line != "") print line
            if ($0 ~ /```$/) next
            capture=1; next
        }
        /^```bash/ { capture=1; next }
        /^```$/    { if (capture) capture=0; next }
        capture    { print }
    '
}

tools_extract_slash_commands() {
    local response="$1"
    echo "$response" | awk '
        /^```/   { in_block = !in_block; next }
        in_block { next }
        /^\/[a-z]/ { print }
    '
}

tools_extract_files() {
    local response="$1"
    local temp_dir
    temp_dir=$(mktemp -d)
    echo "$response" | sed 's/^[[:space:]]*//' | sed 's/^`\{2,4\}\([a-zA-Z]\)/```\1/' | sed 's/^`\{2,4\}$/```/' | awk -v outdir="$temp_dir" '
    /^```[a-zA-Z]/ { 
        in_block=1; lang=substr($0, 4); gsub(/[^a-zA-Z0-9_-]/, "", lang); filepath=""; content=""; next 
    }
    /^```$/ { 
        if (in_block && filepath != "") { outfile = outdir "/" NR; printf "%s\n%s", filepath, content > outfile }
        in_block=0; next 
    }
    in_block && /^[[:space:]]*(\/\/|#) *(file_?path|file path|File_?[Pp]ath):/ {
        f = $0; sub(/.*[Ff]ile[_ ]?[Pp]?ath:[[:space:]]*/, "", f); gsub(/[[:space:]]*$/, "", f)
        gsub(/["\047`]/, "", f); gsub(/ /, "-", f); gsub(/[^a-zA-Z0-9_./-]/, "", f); filepath = f; next
    }
    in_block { content = content $0 "\n" }
    END {
        if (in_block && filepath != "") { outfile = outdir "/" NR; printf "%s\n%s", filepath, content > outfile }
    }
    '
    echo "$temp_dir"
}

tools_exec_bash() {
    local commands="$1" workdir="${2:-.}"
    [ -z "$commands" ] && return 0
    
    ui_section "Shell Commands"
    ui_code_block "bash" "$commands"
    
    if [ "${LODGE_NETWORK_AUDIT:-0}" -eq 1 ]; then
        if ! security_check_network "$commands"; then
            ui_err "Blocked: command accesses the network (network audit mode is ON)"
            ui_dim "Disable with: LODGE_NETWORK_AUDIT=0"
            return 1
        fi
    fi
    
    if [ "$LODGE_PERMISSION" -eq 0 ]; then
        if ! ui_confirm "Execute these commands?"; then
            ui_warn "Skipped by user"; return 1
        fi
    elif [ "$LODGE_PERMISSION" -eq 1 ]; then
        if security_check_allowlist "$commands" 2>/dev/null; then
            :
        elif echo "$commands" | grep -qE '(rm -rf|sudo|chmod 777|dd if=|mkfs|>[[:space:]]*/dev/|curl.*\|[[:space:]]*(ba)?sh|wget.*\|[[:space:]]*(ba)?sh|nc[[:space:]]+-|ncat|/dev/tcp|mkfifo|eval[[:space:]]|(^|[^a-zA-Z])exec[[:space:]]|>[[:space:]]*/etc/)'; then
            ui_warn "Potentially dangerous command detected!"
            if ! ui_confirm "Execute anyway?" "n"; then
                ui_warn "Skipped by user"; return 1
            fi
        elif ! ui_confirm "Execute?"; then
            ui_warn "Skipped by user"; return 1
        fi
    fi
    
    if declare -f vitals_guard_disk &>/dev/null; then
        if ! vitals_guard_disk 2>/dev/null; then
            ui_err "Blocked: disk critically low — refusing to execute"
            LAST_CMD_EXIT=1; return 1
        fi
    fi

    local output exit_code
    output=$(cd "$workdir" && bash -e -c "$commands" 2>&1)
    exit_code=$?
    LAST_CMD_EXIT=$exit_code
    
    if [ $exit_code -eq 0 ]; then
        [ -n "$output" ] && ui_code_block "" "$output"
        ui_ok "Commands executed successfully"
    else
        [ -n "$output" ] && ui_code_block "" "$output"
        ui_err "Commands failed with exit code $exit_code"
    fi
    return $exit_code
}

tools_write_file() {
    local filepath="$1" content="$2" workdir="${3:-.}"
    filepath=$(tools_sanitize_filename "$filepath")
    
    local fullpath
    [[ "$filepath" == /* ]] && fullpath="$filepath" || fullpath="$workdir/$filepath"
    fullpath=$(realpath -m "$fullpath")
    
    local real_workdir=$(realpath "$workdir")
    if [[ ! "$fullpath" == "$real_workdir"* ]]; then
        ui_err "Refusing to write outside workspace: $filepath"
        return 1
    fi
    
    local exists=0
    [ -f "$fullpath" ] && exists=1
    
    if [ "$exists" -eq 1 ]; then
        ui_step "Overwriting: $filepath"
        local tmpfile=$(mktemp "${TMPDIR:-/tmp}/lodge-diff-XXXXXX")
        printf "%s" "$content" > "$tmpfile"
        if command -v diff &>/dev/null; then
            local diff_output=$(diff -u "$fullpath" "$tmpfile" 2>/dev/null | head -40) || true
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
                local diff_lines=$(diff -u "$fullpath" "$tmpfile" 2>/dev/null | wc -l) || true
                [ "$diff_lines" -gt 40 ] && ui_dim "(... $((diff_lines - 40)) more diff lines)"
            fi
        fi
        rm -f "$tmpfile"
    else
        ui_step "Creating: $filepath"
    fi
    
    if [ "$exists" -eq 0 ]; then
        local preview=$(echo "$content" | head -10)
        local total_lines=$(echo "$content" | wc -l)
        ui_code_block "" "$preview"
        [ "$total_lines" -gt 10 ] && ui_dim "(... $((total_lines - 10)) more lines)"
    fi
    
    if [ "$exists" -eq 1 ] && [ "$LODGE_PERMISSION" -le 1 ]; then
        if ! ui_confirm "Overwrite $filepath?"; then
            ui_warn "Skipped"; return 1
        fi
    fi
    
    mkdir -p "$(dirname "$fullpath")"
    local total_lines=$(echo "$content" | wc -l)
    printf "%s" "$content" > "$fullpath"
    ui_ok "Wrote $filepath ($total_lines lines)"
}

tools_process_response() {
    local response="$1" workdir="${2:-.}" results=""
    
    local bash_cmds=$(tools_extract_bash "$response")
    if [ -n "$bash_cmds" ]; then
        local real_bash="" extra_slash="" _line
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
            local _bash_ts=$(date '+%Y-%m-%d %H:%M:%S')
            if [ "${LAST_CMD_EXIT:-0}" -eq 0 ]; then
                results="[$_bash_ts] OK: shell commands (exit 0)"
            else
                results="[$_bash_ts] FAIL: shell commands (exit $LAST_CMD_EXIT)"
            fi
        fi
    fi
    
    local files_dir=$(tools_extract_files "$response")
    if [ -d "$files_dir" ]; then
        for entry in "$files_dir"/*; do
            [ -f "$entry" ] || continue
            local fpath=$(head -1 "$entry")
            local fcontent=$(tail -n +2 "$entry")
            if [ -n "$fpath" ] && [ -n "$fcontent" ]; then
                tools_write_file "$fpath" "$fcontent" "$workdir"
                local _write_ts=$(date '+%Y-%m-%d %H:%M:%S')
                results="${results:+$results; }[$_write_ts] Wrote: $fpath"
            fi
        done
        rm -rf "$files_dir"
    fi

    local slash_cmds=$(tools_extract_slash_commands "$response")
    [ -n "${extra_slash:-}" ] && slash_cmds="${slash_cmds:+${slash_cmds}
}${extra_slash}"
    if [ -n "$slash_cmds" ]; then
        while IFS= read -r scmd; do
            [ -z "$scmd" ] && continue
            local _cmd_start_ts=$(date '+%Y-%m-%d %H:%M:%S')
            ui_section "Tool Invocation"
            ui_step "[$_cmd_start_ts] $scmd"
            if declare -f commands_dispatch &>/dev/null; then
                commands_dispatch "$scmd" "$workdir"
                local _cmd_rc=$? _cmd_end_ts=$(date '+%Y-%m-%d %H:%M:%S')
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

tools_read_pdf() {
    local filepath="$1" page_start="${2:-1}" page_end="${3:-}" max_pages="${4:-20}" layout="${5:-1}"
    [ ! -f "$filepath" ] && { echo "ERROR: File not found: $filepath"; return 1; }
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$LODGE_DIR:$PATH"
    command -v pdftotext &>/dev/null || { echo "ERROR: pdftotext not found. Install Poppler: apt install poppler-utils or install to ~/.local/bin."; return 1; }

    { ! [[ "$page_start" =~ ^[0-9]+$ ]] || [ "$page_start" -lt 1 ]; } && page_start=1
    local total_pages=""
    command -v pdfinfo &>/dev/null && total_pages=$(pdfinfo "$filepath" 2>/dev/null | grep -i '^Pages:' | awk '{print $2}')

    if [ -n "$page_end" ] && [[ "$page_end" =~ ^[0-9]+$ ]] && [ "$page_end" -ge "$page_start" ]; then
        :
    elif [ -n "$total_pages" ] && [ "$total_pages" -gt 0 ]; then
        page_end=$((page_start + max_pages - 1))
        [ "$page_end" -gt "$total_pages" ] && page_end="$total_pages"
    else
        page_end=$((page_start + max_pages - 1))
    fi

    local layout_flag="-layout"
    [ "$layout" = "0" ] && layout_flag=""
    local total_info=""
    [ -n "$total_pages" ] && total_info=" of $total_pages"

    local fname
    fname=$(basename "$filepath")

    # Emit progress if in tool execution context
    declare -f native_tool_progress &>/dev/null && native_tool_progress 25 "Extracting PDF pages $page_start-$page_end ($fname)"

    # Rich ANSI Header
    local c_blue="${C_LODGE:-\033[38;5;33m}"
    local c_cyan="${C_CYAN:-\033[38;5;117m}"
    local c_bold="${C_BOLD:-\033[1m}"
    local c_dim="${C_DIM:-\033[2m}"
    local c_reset="${C_RESET:-\033[0m}"

    printf "%b╭── 📄 PDF Document:%b %b%s%b %b[Pages %s to %s%s]%b\n" \
        "$c_blue" "$c_reset" "$c_bold$c_cyan" "$fname" "$c_reset" "$c_dim" "$page_start" "$page_end" "$total_info" "$c_reset"
    printf "%b│%b  %bPath:%b %s\n" "$c_blue" "$c_reset" "$c_dim" "$c_reset" "$filepath"
    printf "%b╰─────────────────────────────────────────────────────────────%b\n\n" "$c_blue" "$c_reset"

    local pdf_content
    pdf_content=$(pdftotext $layout_flag -f "$page_start" -l "$page_end" -q "$filepath" - 2>/dev/null)
    printf "%s\n\n" "$pdf_content"

    local rem_info=""
    if [ -n "$total_pages" ] && [ "$page_end" -lt "$total_pages" ]; then
        local rem_pages=$((total_pages - page_end))
        rem_info=" ($rem_pages remaining — use /pdf $fname $((page_end + 1)) to read next page)"
    fi

    printf "%b╭─────────────────────────────────────────────────────────────%b\n" "$c_blue" "$c_reset"
    printf "%b│%b  %b✓ Extracted Pages %s-%s%s%b%s\n" "$c_blue" "$c_reset" "$c_bold" "$page_start" "$page_end" "$total_info" "$c_reset" "$rem_info"
    printf "%b╰─────────────────────────────────────────────────────────────%b\n" "$c_blue" "$c_reset"

    declare -f native_tool_progress &>/dev/null && native_tool_progress 100 "PDF extraction complete ($fname)"
    return 0
}

tools_read_file() {
    local filepath="$1" max_lines="${2:-100}" start_line="${3:-1}"
    [ ! -f "$filepath" ] && { echo "ERROR: File not found: $filepath"; return 1; }
    [[ "${filepath,,}" == *.pdf ]] && { tools_read_pdf "$filepath" 1 "" 20 1; return $?; }
    
    { ! [[ "$start_line" =~ ^[0-9]+$ ]] || [ "$start_line" -lt 1 ]; } && start_line=1
    local max_allowed="${AGENT_FILE_READ_MAX_LINES:-500}"
    if ! [[ "$max_lines" =~ ^[0-9]+$ ]] || [ "$max_lines" -lt 1 ]; then
        max_lines=100
    elif [ "$max_lines" -gt "$max_allowed" ]; then
        max_lines="$max_allowed"
    fi
    
    local total=$(wc -l < "$filepath")
    if [ "$start_line" -gt "$total" ]; then
        if [ "$total" -eq 0 ]; then
            echo "--- start of $filepath (empty file) ---"; echo "--- end of $filepath ---"; return 0
        fi
        echo "ERROR: start line $start_line is past end of file ($total lines total)"; return 1
    fi
    
    local end_line=$((start_line + max_lines - 1))
    [ "$end_line" -gt "$total" ] && end_line="$total"
    
    ui_info "Showing lines $start_line to $end_line of $total ($filepath)" 2>/dev/null || true
    echo "--- start of $filepath (lines $start_line-$end_line of $total) ---"
    sed -n "${start_line},${end_line}p" "$filepath" | awk -v start="$start_line" '{print (start + NR - 1) ": " $0}'
    echo "--- end of chunk ($filepath) ---"
    
    if [ "$end_line" -lt "$total" ]; then
        local next_start=$((end_line + 1)) remaining=$((total - end_line))
        echo ""
        echo "[Remaining: $remaining lines (truncated). Next chunk: file_read {\"path\": \"$filepath\", \"start_line\": $next_start, \"max_lines\": $max_lines} or /read $filepath $next_start $max_lines]"
        echo "[Tip: Use file_grep or code_symbol_get to jump directly to specific functions rather than scanning linearly.]"
    fi
}

tools_phone_notify() {
    local title="$1" msg="${2:-}"
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
    [ "$LODGE_PERMISSION" -le 1 ] && { ui_confirm "Open URL: $url?" || return 1; }
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

tools_expand_inline_read() {
    local text="$1"
    [[ "$text" == */read\ * ]] || [[ "$text" == /read\ * ]] || [[ "$text" == read\ * ]] || return 0

    local _read_path=""
    if [[ "$text" =~ ^/?read[[:space:]]+([^[:space:]]+) ]] || [[ "$text" =~ /read[[:space:]]+([^[:space:]]+) ]]; then
        _read_path="${BASH_REMATCH[1]}"
    fi
    [ -z "$_read_path" ] && { echo "$text"; return 0; }
    if [ ! -f "$_read_path" ]; then
        [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [debug] inline /read: file not found: %s\n' "$_read_path" >&2
        echo "$text"; return 0
    fi

    [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [debug] inline /read: expanding %s\n' "$_read_path" >&2
    local _file_content=""
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
            echo "$text"; return 0
        fi
    else
        _file_content=$(cat "$_read_path")
    fi

    local _before="${text%%/read *}"
    [ -z "$_before" ] && [[ "$text" == /read* ]] && _before=""
    local _after="${text#*/read }"
    _after="${_after#"$_read_path"}"
    _after="${_after# }"

    local _result="${_before}${_file_content}"
    [ -n "$_after" ] && _result="${_result}
${_after}"
    echo "$_result"
}

_tools_resolve_ref_path() {
    local p="$1" w="$2" res=""
    local resolved_ui
    resolved_ui=$(ui_resolve_path "$p" "$w" 2>/dev/null)
    if [ -f "$resolved_ui" ]; then
        res="$resolved_ui"
    elif [[ "$p" == "${LODGE_DIR:-$HOME/blue-lodge}"/* ]] && [ -f "$p" ]; then
        res="$p"
    elif [ -f "$p" ]; then
        res="$p"
    elif [ -f "$w/$p" ]; then
        res="$w/$p"
    elif [[ "$p" == /* ]]; then
        local _r="${p#/}"
        [ -f "$w/$_r" ] && res="$w/$_r"
    fi
    if [ -z "$res" ]; then
        if [ -f "$w/.george/workspaces/$p" ]; then
            res="$w/.george/workspaces/$p"
        else
            local _nws=$(ls -td "$w/.george/workspaces"/*/ 2>/dev/null | head -1)
            [ -n "$_nws" ] && [ -f "${_nws}${p}" ] && res="${_nws}${p}"
        fi
    fi
    if [ -z "$res" ] && [ -n "${AGENT_OUTPUT_DIR:-}" ]; then
        [ -f "$w/${AGENT_OUTPUT_DIR}/${p}" ] && res="$w/${AGENT_OUTPUT_DIR}/${p}"
    fi
    if [ -z "$res" ] && declare -f tools_sanitize_filename &>/dev/null; then
        local _san=$(tools_sanitize_filename "$p")
        [ -n "$_san" ] && [ "$_san" != "$p" ] && res=$(_tools_resolve_ref_path "$_san" "$w")
    fi
    echo "$res"
}

tools_expand_file_refs() {
    local text="$1" workdir="${2:-.}" max_chars="${3:-}" changed=0
    [[ "$text" == *.* ]] || [[ "$text" == *mem:* ]] || { echo "$text"; return 0; }

    local -A _readable_exts=(
        [txt]=1 [md]=1 [rst]=1 [csv]=1 [json]=1 [jsonl]=1
        [yaml]=1 [yml]=1 [toml]=1 [xml]=1 [html]=1 [htm]=1
        [log]=1 [conf]=1 [cfg]=1 [ini]=1 [env]=1
        [sh]=1 [bash]=1 [zsh]=1 [py]=1 [rs]=1 [js]=1 [ts]=1
        [go]=1 [rb]=1 [c]=1 [h]=1 [cpp]=1 [hpp]=1 [java]=1
        [kt]=1 [sql]=1 [graphql]=1 [tex]=1 [org]=1
        [diff]=1 [patch]=1 [pdf]=1
    )
    local result="" token prev_token=""
    local -A _ef_seen=()
    local -a _ef_words
    read -ra _ef_words <<< "$text"

    for token in "${_ef_words[@]}"; do
        [ -z "$token" ] && continue
        if [[ "$token" =~ ^https?:// ]] || [[ "$token" =~ ^(f|file|attach)= ]] || \
           [[ "$prev_token" == *"](" ]] || [[ "$token" == "]("* ]]; then
            result="${result:+$result }${token}"; prev_token="$token"; continue
        fi
        local clean="$token"
        clean="${clean%,}"; clean="${clean%.}"; clean="${clean%)}"; clean="${clean%\"}"; clean="${clean%\'}"

        local ext="" is_mem=0
        if [[ "$clean" == mem:* ]]; then
            is_mem=1; ext="md"
        elif [[ "$clean" =~ \.([a-zA-Z0-9]+)$ ]]; then
            ext="${BASH_REMATCH[1],,}"
        fi

        if [ "$is_mem" -eq 1 ] || { [ -n "$ext" ] && [ -n "${_readable_exts[$ext]:-}" ]; }; then
            local fpath="$clean"
            fpath="${fpath#\`}"; fpath="${fpath%\`}"; fpath="${fpath#(}"; fpath="${fpath%)}"
            local resolved=$(_tools_resolve_ref_path "$fpath" "$workdir")

            if [ -z "$resolved" ]; then
                local -a _prev_words
                read -ra _prev_words <<< "$result"
                local _num_prev=${#_prev_words[@]}
                local _back_idx=$((_num_prev - 1))
                local _check_limit=$((_num_prev - 15))
                [ "$_check_limit" -lt 0 ] && _check_limit=0
                while [ "$_back_idx" -ge "$_check_limit" ]; do
                    local _prepended="" i
                    for (( i=_back_idx; i<_num_prev; i++ )); do
                        _prepended="${_prepended:+$_prepended }${_prev_words[i]}"
                    done
                    local _candidate="${_prepended} ${fpath}"
                    local _cand_resolved=$(_tools_resolve_ref_path "$_candidate" "$workdir")
                    if [ -n "$_cand_resolved" ]; then
                        resolved="$_cand_resolved"
                        local _new_result="" j
                        for (( j=0; j<_back_idx; j++ )); do
                            _new_result="${_new_result:+$_new_result }${_prev_words[j]}"
                        done
                        result="$_new_result"
                        break
                    fi
                    _back_idx=$((_back_idx - 1))
                done
            fi

            if [ -n "$resolved" ]; then
                if [ -n "${_ef_seen[$resolved]:-}" ]; then
                    result="${result:+$result }${token}"; prev_token="$token"; continue
                fi
                _ef_seen[$resolved]=1
                local _content=""
                if [[ "${ext}" == "pdf" ]]; then
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
                    local _truncated=0
                    if [ -n "$max_chars" ] && [ "$max_chars" -gt 0 ] 2>/dev/null && [ "${#_content}" -gt "$max_chars" ]; then
                        local _orig_len=${#_content}
                        _content="${_content:0:$max_chars}
... ($((_orig_len - max_chars)) chars truncated)"
                        _truncated=1
                    fi
                    [ "${LODGE_DEBUG:-0}" -eq 1 ] && printf '  [debug] file-ref expand: %s (%d chars%s)\n' "$resolved" "${#_content}" "$([ $_truncated -eq 1 ] && echo ", capped at $max_chars")" >&2
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
    done

    [ "$changed" -eq 0 ] && echo "$text" || echo "$result"
}

tools_quote_filename_spaces() {
    local rest="$1"
    [ -z "$rest" ] && return 0
    if [[ "$rest" == '"'* ]] || [[ "$rest" == "'"* ]]; then
        echo "$rest"; return 0
    fi
    local candidate_exts=(
        .txt .md .rst .csv .json .jsonl .yaml .yml .toml .lock .conf
        .sh .bash .zsh .py .rs .js .ts .go .rb .c .h .cpp .hpp .java
        .html .css .xml .svg .pdf .log .ini .env .cfg
    )
    local ext_pattern="" e
    for e in "${candidate_exts[@]}"; do
        ext_pattern="${ext_pattern:+${ext_pattern}|}${e//./\\.}"
    done
    if echo "$rest" | grep -qE "(${ext_pattern})[[:space:]]"; then
        local ext_match=$(echo "$rest" | grep -oE "[^[:space:]]+(${ext_pattern})" | head -1)
        if [ -n "$ext_match" ]; then
            local before_ext="${rest%%"$ext_match"*}"
            if [ -n "$before_ext" ] && [[ "$before_ext" =~ [[:space:]] ]]; then
                local filename="${before_ext}${ext_match}"
                filename="${filename#"${filename%%[![:space:]]*}"}"
                local trailing="${rest#*"$ext_match"}"
                echo "\"${filename}\"${trailing}"
                return 0
            fi
        fi
    fi
    echo "$rest"
}
