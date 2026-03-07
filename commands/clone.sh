#!/bin/bash
# DESC: Clone a GitHub repo into a sandbox
# Usage: /clone <repo_url_or_owner/name> [local_name]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/sandbox.sh"

cmd_clone() {
    local args="$1"
    local url name
    url=$(echo "$args" | awk '{print $1}')
    name=$(echo "$args" | awk '{print $2}')
    
    if [ -z "$url" ]; then
        printf " Repo URL or owner/name: "
        read -r url
    fi
    
    # Expand shorthand: owner/repo → full URL
    if [[ "$url" =~ ^[a-zA-Z0-9_-]+/[a-zA-Z0-9_.-]+$ ]]; then
        url="https://github.com/$url.git"
    fi
    
    if [ -z "$name" ]; then
        name=$(basename "$url" .git)
    fi
    
    sandbox_clone "$url" "$name"
    
    # Auto-detect project type and init GEORGE.md
    local dir="$LODGE_SANDBOXES/$name"
    if [ -d "$dir" ]; then
        cd "$dir"
        local type="General" build="make" test="make test"
        
        if [ -f "Cargo.toml" ]; then
            type="Rust"; build="cargo build"; test="cargo test"
        elif [ -f "pyproject.toml" ]; then
            type="Python"; build="uv run python main.py"; test="uv run pytest"
        elif [ -f "package.json" ]; then
            type="Node.js"; build="npm run build"; test="npm test"
        fi
        
        if [ ! -f "GEORGE.md" ]; then
            source "$LODGE_DIR/lib/memory.sh"
            memory_init "." "$name" "$type" "$build" "$test"
        fi
        
        export LODGE_PROJECT="$name"
        ui_ok "Now in: $dir"
        ui_dim "Use /sandbox cd $name to switch here later"
    fi
}
