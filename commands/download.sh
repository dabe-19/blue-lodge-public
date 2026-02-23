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

    # Sanitize destination filename — strip quotes, spaces, special chars
    if declare -f tools_sanitize_filename &>/dev/null; then
        dest=$(tools_sanitize_filename "$dest")
    else
        dest=$(echo "$dest" | sed 's/["'"'"'`]//g' | tr ' ' '-' | sed 's/[^a-zA-Z0-9_./-]//g')
    fi

    # Resolve destination relative to workdir
    local fullpath
    if [[ "$dest" == /* ]]; then
        fullpath="$dest"
    else
        fullpath="$workdir/$dest"
    fi

    # Create parent directories
    mkdir -p "$(dirname "$fullpath")"

    # URL download
    if [[ "$source" == http://* ]] || [[ "$source" == https://* ]]; then
        ui_step "Downloading: $source"

        if command -v curl &>/dev/null; then
            if curl -fsSL -o "$fullpath" "$source" 2>&1; then
                local size
                size=$(wc -c < "$fullpath" 2>/dev/null || echo "0")
                ui_ok "Downloaded: $dest ($size bytes)"
                return 0
            else
                ui_err "Download failed: $source"
                return 1
            fi
        elif command -v wget &>/dev/null; then
            if wget -q -O "$fullpath" "$source" 2>&1; then
                ui_ok "Downloaded: $dest"
                return 0
            else
                ui_err "Download failed: $source"
                return 1
            fi
        else
            ui_err "No download tool available (need curl or wget)"
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
            ui_ok "Copied: $dest"
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
