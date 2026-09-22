#!/bin/bash
# DESC: Read file contents in the current workspace or sandbox
# Usage: /read <filepath> [start_line] [max_lines]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true

cmd_read() {
    local args="$1"
    local workdir="${2:-.}"

    if [ -z "$args" ]; then
        ui_err "Usage: /read <filepath> [start_line] [max_lines]"
        return 1
    fi

    local file="${args%% *}"
    local rest="${args#"$file"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    local start_line="${rest%% *}"
    local max_lines="${rest#"$start_line"}"
    max_lines="${max_lines#"${max_lines%%[![:space:]]*}"}"

    local target_path="$file"
    [[ "$target_path" != /* ]] && target_path="$workdir/$file"

    if [ ! -f "$target_path" ]; then
        ui_err "File not found: $file"
        return 1
    fi

    # PDF routing: extract text via Poppler rather than slicing raw binary
    if [[ "${target_path,,}" == *.pdf ]]; then
        source "$LODGE_DIR/lib/tools.sh" 2>/dev/null || true
        local p_start="${start_line:-1}"
        local p_max="${max_lines:-20}"
        if declare -f tools_read_pdf &>/dev/null; then
            tools_read_pdf "$target_path" "$p_start" "" "$p_max" 1
            return $?
        elif command -v pdftotext &>/dev/null; then
            pdftotext -layout -f "$p_start" -l "$((p_start + p_max - 1))" -q "$target_path" - 2>/dev/null
            return $?
        fi
    fi

    local s="${start_line:-1}"
    local m="${max_lines:-100}"
    if ! [[ "$s" =~ ^[0-9]+$ ]] || [ "$s" -lt 1 ]; then s=1; fi
    if ! [[ "$m" =~ ^[0-9]+$ ]] || [ "$m" -lt 1 ]; then m=100; elif [ "$m" -gt 200 ]; then m=200; fi

    local total
    total=$(wc -l < "$target_path" 2>/dev/null || echo "0")
    local end=$((s + m - 1))
    [ "$end" -gt "$total" ] && end="$total"

    ui_info "Showing lines $s to $end of $total ($file)"
    sed -n "${s},${end}p" "$target_path" | awk -v start="$s" '{print (start + NR - 1) ": " $0}'

    if [ "$end" -lt "$total" ]; then
        local next_start=$((end + 1))
        local remaining=$((total - end))
        echo ""
        ui_dim "  [... $remaining more lines. Use /read $file $next_start $m for next chunk ...]"
    fi
}
