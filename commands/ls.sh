#!/bin/bash
# DESC: List files and directory structure in the current workspace or sandbox
# Usage: /ls [path] [depth]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true

cmd_ls() {
    local args="$1"
    local workdir="${2:-.}"

    # Parse arguments: [path] [depth]
    local target depth
    target=$(echo "$args" | awk '{print $1}')
    depth=$(echo "$args" | awk '{print $2}')

    # Defaults
    [ -z "$target" ] && target="."
    [ -z "$depth" ] && depth=3

    # Expand tilde
    declare -f tools_expand_tilde &>/dev/null && target=$(tools_expand_tilde "$target")

    if [[ "$target" == /* ]]; then
        :
    else
        if declare -f ui_resolve_path &>/dev/null; then
            target=$(ui_resolve_path "$target" "$workdir" 0)
        else
            target="$workdir/$target"
        fi
    fi

    # Normalize (remove trailing slash, resolve ..)
    target=$(cd "$target" 2>/dev/null && pwd || echo "$target")

    if [ ! -d "$target" ]; then
        if [ -f "$target" ]; then
            ls -la "$target"
            return $?
        fi
        ui_err "Directory not found: $target" 2>/dev/null || echo "Directory not found: $target" >&2
        return 1
    fi

    # Clamp depth to safe range (1-8)
    if ! [[ "$depth" =~ ^[0-9]+$ ]] || [ "$depth" -lt 1 ]; then
        depth=3
    elif [ "$depth" -gt 8 ]; then
        depth=8
        declare -f ui_dim &>/dev/null && ui_dim "  (depth clamped to 8 to keep output manageable)"
    fi

    # Exclusions — build artifacts, VCS, caches, system dirs
    local -a excludes=(
        '.git' 'target' '__pycache__' '.venv' 'node_modules'
        '.mypy_cache' '.pytest_cache' '.tox' '.eggs' '*.egg-info'
        '.DS_Store' '.lodge-snapshots' '.agents'
        '.keyring' '.vault' 'cookies' 'cache' 'backups' 'mcp'
        'keys.conf' 'lodge.conf' 'remote.conf'
        'recall.db' 'discord_channels.db' 'discord_users.db'
        '*.db' '*.db-journal' '.lodge.lock' '.recall_mtimes'
        'routing_trace.jsonl'
    )

    declare -f ui_section &>/dev/null && ui_section "Files: ${target/#$HOME/~} (depth $depth)"
    local base_name
    base_name=$(basename "$target")
    printf "  %b%s/%b\n" "${C_CYAN:-}" "$base_name" "${C_RESET:-}"

    # Build find exclusion args
    local -a find_excludes=()
    for ex in "${excludes[@]}"; do
        find_excludes+=(-name "$ex" -prune -o)
    done

    # Use find to get all entries, then format as tree
    local count=0
    local max_entries=80
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        count=$((count + 1))
        if [ "$count" -gt "$max_entries" ]; then
            printf "  %b... (%d+ entries, showing first %d)%b\n" "${C_DIM:-}" "$count" "$max_entries" "${C_RESET:-}"
            break
        fi

        # Calculate relative path and depth-based indent
        local rel="${entry#$target/}"
        local indent_level
        indent_level=$(echo "$rel" | tr -cd '/' | wc -c)
        local indent=""
        local i
        for ((i=0; i<indent_level; i++)); do
            indent="${indent}│   "
        done

        local name
        name=$(basename "$entry")

        if [ -d "$entry" ]; then
            printf "  %s├── %b%s/%b\n" "$indent" "${C_CYAN:-}" "$name" "${C_RESET:-}"
        else
            printf "  %s├── %s\n" "$indent" "$name"
        fi
    done < <(find "$target" -mindepth 1 -maxdepth "$depth" \
        "${find_excludes[@]}" \
        -print 2>/dev/null | sort)

    if [ "$count" -eq 0 ]; then
        printf "  %b(empty directory)%b\n" "${C_DIM:-}" "${C_RESET:-}"
    fi
    echo ""
}
