#!/bin/bash
# DESC: Extract and view text from PDF files using Poppler
# Usage: /pdf <filepath> [page_start] [page_end]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools.sh" 2>/dev/null || true

cmd_pdf() {
    local args="$1"
    local workdir="${2:-$PWD}"

    if [ -z "$args" ]; then
        ui_section "PDF Document Reader (Poppler)"
        echo "Usage: /pdf <filepath> [page_start] [page_end]"
        echo ""
        echo "Examples:"
        echo "  /pdf paper.pdf            Read first 20 pages"
        echo "  /pdf paper.pdf 5          Read starting at page 5"
        echo "  /pdf paper.pdf 5 10       Read pages 5 through 10"
        return 0
    fi

    local file="${args%% *}"
    local rest="${args#"$file"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    local page_start="${rest%% *}"
    local page_end="${rest#"$page_start"}"
    page_end="${page_end#"${page_end%%[![:space:]]*}"}"

    local target_path="$file"
    [[ "$target_path" != /* ]] && target_path="$workdir/$file"

    if [ ! -f "$target_path" ]; then
        ui_err "PDF file not found: $file"
        return 1
    fi

    local p_start="${page_start:-1}"
    local p_end="${page_end:-}"

    if declare -f tools_read_pdf &>/dev/null; then
        tools_read_pdf "$target_path" "$p_start" "$p_end" 20 1
        return $?
    elif command -v pdftotext &>/dev/null; then
        local p_flag=""
        [ -n "$p_start" ] && p_flag+="-f $p_start "
        [ -n "$p_end" ] && p_flag+="-l $p_end "
        pdftotext -layout $p_flag -q "$target_path" - 2>/dev/null
        return $?
    else
        ui_err "pdftotext not available. Install Poppler: apt install poppler-utils"
        return 1
    fi
}
