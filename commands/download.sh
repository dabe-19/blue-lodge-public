#!/bin/bash
# DESC: Download a URL or copy a local file to the workspace
# Usage: /download <source> [destination]
#   source: URL (http/https) or local file path
#   destination: target path (defaults to filename from source)

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

cmd_download() {
    local args="$1"
    local workdir="${2:-.}"

    if [ -z "$args" ]; then
        ui_err "Usage: /download <source> [destination]"
        ui_dim "Examples:"
        ui_dim "  /download https://example.com/file.tar.gz"
        ui_dim "  /download https://example.com/data.json data/input.json"
        ui_dim "  /download ~/Documents/notes.txt ./notes.txt"
        return 1
    fi

    # Parse: first token is source, second (optional) is destination
    local source dest
    source=$(echo "$args" | awk '{print $1}')
    dest=$(echo "$args" | awk '{print $2}')

    # Default destination: basename of source, in workdir
    if [ -z "$dest" ]; then
        dest=$(basename "$source" | sed 's/[?#].*//')
        # Fallback if basename is empty or just '/'
        [ -z "$dest" ] || [ "$dest" = "/" ] && dest="downloaded_file"
    fi

    # Expand tilde — LLMs emit ~/path which doesn't expand in quotes
    declare -f tools_expand_tilde &>/dev/null && dest=$(tools_expand_tilde "$dest")

    # Sanitize destination filename — strip quotes, spaces, special chars
    if declare -f tools_sanitize_filename &>/dev/null; then
        dest=$(tools_sanitize_filename "$dest")
    else
        dest=$(echo "$dest" | sed 's/["'"'"'`]//g' | tr ' ' '-' | sed 's/[^a-zA-Z0-9_./-]//g')
    fi

    # Resolve destination path relative to sandbox, global workspace, or fallbacks
    local fullpath
    fullpath=$(ui_resolve_path "$dest" "$workdir" 1)
    local log_dest
    log_dest=$(ui_clean_path_prefix "$fullpath" "$LODGE_DIR")

    # Create parent directories
    if ! mkdir -p "$(dirname "$fullpath")" 2>/dev/null; then
        ui_err "Cannot create directory: $(dirname "$dest")"
        return 1
    fi

    # URL download
    if [[ "$source" == http://* ]] || [[ "$source" == https://* ]]; then
        ui_step "Downloading: $source"

        local success=0
        if command -v curl &>/dev/null; then
            if curl -fsSL -o "$fullpath" "$source" 2>&1; then
                success=1
            fi
        elif command -v wget &>/dev/null; then
            if wget -q -O "$fullpath" "$source" 2>&1; then
                success=1
            fi
        else
            ui_err "No download tool available (need curl or wget)"
            return 1
        fi

        if [ "$success" -eq 1 ]; then
            # Verify that we didn't download HTML text when expecting a binary/image file
            local lower_dest
            lower_dest=$(echo "$dest" | tr '[:upper:]' '[:lower:]')
            if [[ "$lower_dest" =~ \.(jpg|jpeg|png|gif|webp|bmp|svg|avif|tiff|pdf|tar|gz|zip|json)$ ]]; then
                local head_bytes
                head_bytes=$(head -c 500 "$fullpath" 2>/dev/null | tr '[:upper:]' '[:lower:]')
                if [[ "$head_bytes" == *"<html"* ]] || [[ "$head_bytes" == *"<!doctype html"* ]]; then
                    rm -f "$fullpath"
                    ui_err "Downloaded content is HTML text, not the expected binary/image file: $dest"
                    ui_dim "Hint: You may have downloaded a webpage/description page (like Wikimedia Commons) instead of the raw file."
                    ui_dim "Use /web scrape-images on the webpage URL to find the actual direct image URL, then download that."
                    return 1
                fi
            fi

            local size
            size=$(wc -c < "$fullpath" 2>/dev/null || echo "0")
            ui_ok "Downloaded: $log_dest ($size bytes)"
            return 0
        else
            ui_err "Download failed: $source"
            return 1
        fi
    fi

    # Local file copy
    if [ -e "$source" ]; then
        ui_step "Copying: $source → $dest"
        if [ -d "$source" ]; then
            cp -r "$source" "$fullpath"
        else
            cp "$source" "$fullpath"
        fi
        if [ $? -eq 0 ]; then
            ui_ok "Copied: $log_dest"
            return 0
        else
            ui_err "Copy failed: $source → $dest"
            return 1
        fi
    fi

    # Source doesn't exist
    ui_err "Source not found: $source"
    ui_dim "Provide a URL (http/https) or an existing file path"
    return 1
}
