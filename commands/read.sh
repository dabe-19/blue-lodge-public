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

    if [ -n "$start_line" ] && [[ "$start_line" =~ ^[0-9]+$ ]]; then
        local num="${max_lines:-100}"
        sed -n "${start_line},$((start_line + num - 1))p" "$target_path"
    else
        head -n 250 "$target_path"
        local total
        total=$(wc -l < "$target_path" 2>/dev/null || echo "0")
        if [ "$total" -gt 250 ]; then
            echo ""
            ui_dim "  [... truncated at line 250 of $total lines. Use /read $file 251 250 for next chunk ...]"
        fi
    fi
}
