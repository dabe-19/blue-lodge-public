#!/bin/bash
# ── George: Tool Execution Engine ──────────────────────────
# Parses LLM responses and applies file/shell operations.
# Permissioned: asks before destructive actions.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Permission Levels ──────────────────────────────────────────
# 0 = ask always, 1 = ask for destructive, 2 = auto-approve all
LODGE_PERMISSION="${LODGE_PERMISSION:-1}"

# ── Extract bash code blocks ──────────────────────────────────
tools_extract_bash() {
    local response="$1"
    # Extract content between ```bash and ```
    echo "$response" | sed -n '/^```bash/,/^```$/p' | sed '/^```/d'
}

# ── Extract file writes from response ─────────────────────────
# Format: ```lang\n# filepath: ./path/to/file\n...code...\n```
tools_extract_files() {
    local response="$1"
    local temp_dir
    temp_dir=$(mktemp -d)
    
    echo "$response" | awk -v outdir="$temp_dir" '
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
            printf "%s\n%s" filepath, content > outfile
        }
        in_block=0
        next 
    }
    in_block && /^[[:space:]]*(\/\/|#) filepath:/ {
        f = $0
        sub(/.*filepath:[[:space:]]*/, "", f)
        gsub(/[[:space:]]*$/, "", f)
        filepath = f
        next
    }
    in_block { content = content $0 "\n" }
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
        elif echo "$commands" | grep -qE '(rm -rf|sudo|chmod 777|dd if=|mkfs|>\s*/dev/|curl.*\|\s*(ba)?sh|wget.*\|\s*(ba)?sh|nc\s+-|ncat|/dev/tcp|mkfifo|eval\s|\bexec\s|>\s*/etc/)'; then
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
        tmpfile=$(mktemp /tmp/lodge-diff-XXXXXX)
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
        tools_exec_bash "$bash_cmds" "$workdir"
        results="Commands: exit $LAST_CMD_EXIT"
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
                results="${results:+$results; }Wrote: $fpath"
            fi
        done
        rm -rf "$files_dir"
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
    if command -v termux-notification &>/dev/null; then
        termux-notification --title "$title" --content "$msg"
        ui_ok "Notification sent"
    else
        ui_warn "termux-notification not available"
    fi
}

tools_phone_clipboard_set() {
    local text="$1"
    if command -v termux-clipboard-set &>/dev/null; then
        echo "$text" | termux-clipboard-set
        ui_ok "Copied to clipboard"
    else
        ui_warn "termux-clipboard-set not available"
    fi
}

tools_phone_clipboard_get() {
    if command -v termux-clipboard-get &>/dev/null; then
        termux-clipboard-get
    else
        ui_warn "termux-clipboard-get not available"
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
    if command -v termux-open-url &>/dev/null; then
        termux-open-url "$url"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$url"
    fi
}

tools_phone_share() {
    local filepath="$1"
    if command -v termux-share &>/dev/null; then
        termux-share "$filepath"
    fi
}

tools_phone_battery() {
    if command -v termux-battery-status &>/dev/null; then
        termux-battery-status | jq '{percentage, status, temperature}' 2>/dev/null
    else
        echo '{"percentage": "unknown"}'
    fi
}

tools_phone_vibrate() {
    if command -v termux-vibrate &>/dev/null; then
        termux-vibrate -d 100
    fi
}

tools_phone_toast() {
    local msg="$1"
    if command -v termux-toast &>/dev/null; then
        termux-toast "$msg"
    fi
}
