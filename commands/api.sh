#!/bin/bash
# DESC: Sovereign Public APIs Catalog, API Key Store & REST Endpoint Discovery Tool
# Usage:
#   /api keys [list|set|rm]   — Manage encrypted/local API keys in GEORGE_KEYS_FILE
#   /api status               — Show social & provider API connection status
#   /api search <query>       — Search 1,950+ free public APIs (prioritizes keyless)
#   /api keyless <query>      — Search strictly keyless / zero-auth APIs
#   /api category <name>      — Search or list APIs within a category
#   /api categories           — List all 52 categories with counts
#   /api info <name>          — Inspect endpoint details, auth, and features
#   /api sync                 — Refresh catalog from upstream GitHub dataset
#   /api stats                — Show database statistics

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true

_py_exec() {
    if [ -x "$LODGE_DIR/.venv/bin/python" ]; then
        "$LODGE_DIR/.venv/bin/python" "$@"
    elif command -v uv &>/dev/null; then
        uv run --project "$LODGE_DIR" python "$@"
    else
        python3 "$@"
    fi
}

cmd_api() {
    local args="$1"
    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "$subcmd" in
        keys)
            local sub keyargs
            sub=$(echo "$rest" | awk '{print $1}')
            keyargs=$(echo "$rest" | sed 's/^[^ ]* *//')
            case "$sub" in
                list|ls|"")
                    declare -f api_list_keys &>/dev/null && api_list_keys
                    ;;
                set)
                    local kname kval
                    kname=$(echo "$keyargs" | awk '{print $1}')
                    kval=$(echo "$keyargs" | sed 's/^[^ ]* *//')
                    if [ -z "$kname" ] || [ -z "$kval" ] || [ "$kval" = "$kname" ]; then
                        ui_err "Usage: /api keys set KEY_NAME value"
                        ui_dim "  Value may contain spaces — no quotes needed"
                        ui_dim "  Example: /api keys set EMAIL_PASSWORD abcd efgh ijkl mnop"
                        return 1
                    fi
                    declare -f api_init &>/dev/null && api_init
                    declare -f api_set_key &>/dev/null && api_set_key "$kname" "$kval"
                    ui_ok "Key $kname saved"
                    ;;
                rm|remove)
                    local kname
                    kname=$(echo "$keyargs" | awk '{print $1}')
                    if [ -n "$kname" ] && [ -n "${GEORGE_KEYS_FILE:-}" ] && [ -f "$GEORGE_KEYS_FILE" ]; then
                        local tmpfile
                        tmpfile=$(mktemp)
                        grep -v "^${kname}=" "$GEORGE_KEYS_FILE" > "$tmpfile"
                        mv "$tmpfile" "$GEORGE_KEYS_FILE"
                        ui_ok "Key $kname removed"
                    fi
                    ;;
                *)
                    ui_info "Usage: /api keys <list|set|rm>"
                    ;;
            esac
            return 0
            ;;
        status)
            declare -f api_init &>/dev/null && api_init
            declare -f social_status &>/dev/null && social_status
            echo ""
            declare -f provider_status &>/dev/null && provider_status
            return 0
            ;;
        ""|help)
            echo "═══════════════════════════════════════════════════════════"
            echo "  Blue Lodge — Sovereign API Keys & Public APIs Catalog"
            echo "═══════════════════════════════════════════════════════════"
            echo "  Usage:"
            echo "    /api keys [list|set|rm]   Manage API keys"
            echo "    /api status               Show provider & social API status"
            echo "    /api search <query>       Search APIs (prioritizes keyless)"
            echo "    /api keyless <query>      Search only keyless / zero-auth APIs"
            echo "    /api category <name>      Filter APIs by category"
            echo "    /api categories           List all 52 categories and counts"
            echo "    /api info <name>          Show detailed metadata for an API"
            echo "    /api sync                 Refresh catalog from upstream GitHub"
            echo "    /api stats                Show database statistics"
            echo "═══════════════════════════════════════════════════════════"
            return 0
            ;;
    esac

    local backend="$LODGE_DIR/lib/tools/public_apis_backend.py"
    if [ ! -f "$backend" ]; then
        ui_err "Public APIs backend script missing at $backend"
        return 1
    fi

    case "$subcmd" in
        search)
            if [ -z "$rest" ]; then
                ui_err "Usage: /api search <query>"
                return 1
            fi
            _py_exec "$backend" search --query "$rest" --limit 8
            ;;
        keyless|noauth|free)
            if [ -z "$rest" ]; then
                ui_err "Usage: /api keyless <query>"
                return 1
            fi
            _py_exec "$backend" search --query "$rest" --no-auth --limit 8
            ;;
        category)
            if [ -z "$rest" ]; then
                ui_err "Usage: /api category <category name> [query]"
                return 1
            fi
            local cat_name="${rest%% *}"
            local cat_query="${rest#"$cat_name"}"
            cat_query="${cat_query#"${cat_query%%[![:space:]]*}"}"
            if [ -n "$cat_query" ]; then
                _py_exec "$backend" search --query "$cat_query" --category "$cat_name" --limit 10
            else
                _py_exec "$backend" search --query "%" --category "$cat_name" --limit 15
            fi
            ;;
        categories|cats)
            _py_exec "$backend" categories
            ;;
        info)
            if [ -z "$rest" ]; then
                ui_err "Usage: /api info <API name>"
                return 1
            fi
            _py_exec "$backend" info --name "$rest"
            ;;
        sync|refresh|update)
            echo "── Synchronizing Public APIs catalog from upstream repository..."
            _py_exec "$backend" sync
            ;;
        stats)
            _py_exec "$backend" stats
            ;;
        *)
            _py_exec "$backend" search --query "$args" --limit 8
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_api "$*"
fi
