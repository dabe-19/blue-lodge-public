#!/bin/bash
# ── George: Sovereign Gitea MCP Server (2026) ────────────────────────
# Pure POSIX bash + curl JSON-RPC server implementing the Model Context Protocol.
# Manages Gitea repository operations, PR workflows, and GitFlow branches.
# Can run as standalone MCP server over stdio or be sourced by Lodge libraries.

[ -n "${_LIB_MCP_SERVER_GITEA_LOADED:-}" ] && return 0; _LIB_MCP_SERVER_GITEA_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
GITEA_CONF="${GITEA_CONF:-$GEORGE_DIR/gitea.conf}"

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/git.sh" 2>/dev/null || true

_gitea_load_conf() {
    if [ -f "$GITEA_CONF" ]; then
        GITEA_URL=$(grep '^GITEA_URL=' "$GITEA_CONF" 2>/dev/null | cut -d= -f2- | tr -d '"')
        GITEA_USER=$(grep '^GITEA_USER=' "$GITEA_CONF" 2>/dev/null | cut -d= -f2- | tr -d '"')
        GITEA_TOKEN=$(grep '^GITEA_TOKEN=' "$GITEA_CONF" 2>/dev/null | cut -d= -f2- | tr -d '"')
        GITEA_REPO=$(grep '^GITEA_REPO=' "$GITEA_CONF" 2>/dev/null | cut -d= -f2- | tr -d '"')
    fi
    GITEA_URL="${GITEA_URL:-http://127.0.0.1:3088}"
    GITEA_USER="${GITEA_USER:-george}"
    GITEA_REPO="${GITEA_REPO:-blue-lodge}"
}

gitea_is_online() {
    _gitea_load_conf
    curl -sf --max-time 1.5 "${GITEA_URL}/api/v1/version" &>/dev/null
}

gitea_status() {
    _gitea_load_conf
    local online=0
    local ver="offline"
    if curl -sf --max-time 1.5 "${GITEA_URL}/api/v1/version" &>/dev/null; then
        online=1
        ver=$(curl -s "${GITEA_URL}/api/v1/version" | jq -r .version 2>/dev/null || echo "online")
    fi

    local repo_info="{}"
    if [ "$online" -eq 1 ] && [ -n "$GITEA_TOKEN" ]; then
        repo_info=$(curl -s -H "Authorization: token ${GITEA_TOKEN}" "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}" 2>/dev/null || echo "{}")
    fi

    jq -n \
        --arg online "$online" \
        --arg ver "$ver" \
        --arg url "$GITEA_URL" \
        --arg user "$GITEA_USER" \
        --arg repo "$GITEA_REPO" \
        --argjson rinfo "$repo_info" \
        '{
            online: ($online == "1"),
            version: $ver,
            url: $url,
            owner: $user,
            repo: $repo,
            default_branch: ($rinfo.default_branch // "develop"),
            stars: ($rinfo.stars_count // 0),
            open_prs: ($rinfo.open_pr_counter // 0)
        }'
}

gitea_repo_sync() {
    local branch="${1:-develop}"
    _gitea_load_conf
    if ! gitea_is_online; then
        echo "ERROR: Gitea server ($GITEA_URL) is offline."
        return 1
    fi

    local out
    out=$(git -C "$LODGE_DIR" push gitea "$branch" 2>&1)
    local code=$?
    echo "$out"
    return "$code"
}

gitea_pr_create() {
    local head="$1"
    local base="${2:-develop}"
    local title="$3"
    local body="${4:-}"

    _gitea_load_conf
    if ! gitea_is_online; then
        echo "ERROR: Gitea server ($GITEA_URL) is offline."
        return 1
    fi

    # GitFlow check: Never allow direct PR to main/master without release flag
    if ! gitflow_guard_check "$base"; then
        return 1
    fi

    # Push head branch to Gitea first
    git -C "$LODGE_DIR" push gitea "$head" >/dev/null 2>&1 || true

    local payload
    payload=$(jq -n \
        --arg head "$head" \
        --arg base "$base" \
        --arg title "$title" \
        --arg body "$body" \
        '{
            head: $head,
            base: $base,
            title: $title,
            body: $body
        }')

    local resp
    resp=$(curl -s -X POST "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/pulls" \
        -H "Authorization: token ${GITEA_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    if echo "$resp" | jq -e .number &>/dev/null; then
        local num html_url
        num=$(echo "$resp" | jq -r .number)
        html_url=$(echo "$resp" | jq -r .html_url)
        ui_ok "Sovereign Gitea PR #${num} created: $title"
        ui_dim "  URL: $html_url"
        echo "$resp"
        return 0
    else
        local err_msg
        err_msg=$(echo "$resp" | jq -r .message 2>/dev/null || echo "$resp")
        ui_err "Failed to create Gitea PR: $err_msg"
        echo "$resp"
        return 1
    fi
}

gitea_pr_list() {
    local state="${1:-open}"
    _gitea_load_conf
    if ! gitea_is_online; then
        echo "ERROR: Gitea server ($GITEA_URL) is offline."
        return 1
    fi

    local resp
    resp=$(curl -s "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/pulls?state=${state}" \
        -H "Authorization: token ${GITEA_TOKEN}" 2>/dev/null)

    if echo "$resp" | jq -e 'type == "array"' &>/dev/null; then
        echo "$resp" | jq -r '.[] | "#\(.number) [\(.head.ref) → \(.base.ref)] (\(.state)) \(.title)"'
    else
        echo "No PRs returned or error: $resp"
    fi
}

gitea_pr_get() {
    local index="$1"
    _gitea_load_conf
    if [ -z "$index" ]; then
        echo "ERROR: index is required"
        return 1
    fi
    curl -s "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/pulls/${index}" \
        -H "Authorization: token ${GITEA_TOKEN}" 2>/dev/null
}

gitea_pr_merge() {
    local index="$1"
    local strategy="${2:-merge}" # merge or squash
    _gitea_load_conf
    if [ -z "$index" ]; then
        echo "ERROR: index is required"
        return 1
    fi

    local do_type="merge"
    [ "$strategy" = "squash" ] && do_type="squash"

    local resp
    resp=$(curl -s -X POST "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/pulls/${index}/merge" \
        -H "Authorization: token ${GITEA_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"Do\":\"${do_type}\"}" 2>/dev/null)

    if [ -z "$resp" ] || echo "$resp" | grep -q "null"; then
        ui_ok "Sovereign Gitea PR #${index} successfully merged via ${do_type}!"
        # Sync local develop branch
        git -C "$LODGE_DIR" fetch gitea develop >/dev/null 2>&1 || true
        return 0
    else
        echo "$resp"
    fi
}

# ── JSON-RPC 2.0 MCP Protocol Loop (if run directly) ────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _JQ=$(command -v jq 2>/dev/null || echo "")

    _respond_result() {
        local id="$1" content="$2"
        printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$id" "$content"
    }

    _respond_error() {
        local id="$1" code="$2" message="$3"
        printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%d,"message":"%s"}}\n' \
            "${id:-null}" "$code" "$message"
    }

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        method=$(printf '%s' "$line" | $_JQ -r '.method // empty' 2>/dev/null)
        id=$(printf '%s' "$line" | $_JQ '.id // null' 2>/dev/null)

        case "$method" in
            initialize)
                _respond_result "$id" '{
                    "protocolVersion": "2024-11-05",
                    "capabilities": { "tools": {} },
                    "serverInfo": { "name": "george-gitea-mcp", "version": "1.0.0" }
                }'
                ;;
            tools/list)
                _respond_result "$id" '{
                    "tools": [
                        {
                            "name": "gitea_status",
                            "description": "Inspect sovereign Gitea server health, version, and repository statistics.",
                            "inputSchema": { "type": "object", "properties": {} }
                        },
                        {
                            "name": "gitea_repo_sync",
                            "description": "Push local develop branch or specified branch to sovereign Gitea remote.",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "branch": { "type": "string", "description": "Branch to push (default: develop)" }
                                }
                            }
                        },
                        {
                            "name": "gitea_pr_create",
                            "description": "Create a pull request on sovereign Gitea targeting develop.",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "head": { "type": "string", "description": "Source candidate branch" },
                                    "base": { "type": "string", "description": "Target branch (default: develop)" },
                                    "title": { "type": "string", "description": "Pull request title" },
                                    "body": { "type": "string", "description": "Markdown dossier and empirical proof" }
                                },
                                "required": ["head", "title"]
                            }
                        },
                        {
                            "name": "gitea_pr_list",
                            "description": "List pull requests from sovereign Gitea forge.",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "state": { "type": "string", "description": "open, closed, or all", "enum": ["open", "closed", "all"] }
                                }
                            }
                        },
                        {
                            "name": "gitea_pr_merge",
                            "description": "Merge an approved pull request on sovereign Gitea into target branch.",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "index": { "type": "integer", "description": "PR number" },
                                    "strategy": { "type": "string", "description": "Merge strategy: merge or squash", "enum": ["merge", "squash"] }
                                },
                                "required": ["index"]
                            }
                        }
                    ]
                }'
                ;;
            tools/call)
                tool_name=$(printf '%s' "$line" | $_JQ -r '.params.name // empty' 2>/dev/null)
                arguments=$(printf '%s' "$line" | $_JQ -c '.params.arguments // {}' 2>/dev/null)
                case "$tool_name" in
                    gitea_status)
                        res=$(gitea_status 2>&1)
                        _respond_result "$id" "{\"content\":[{\"type\":\"text\",\"text\":$(printf '%s' "$res" | $_JQ -Rs .)}]}"
                        ;;
                    gitea_repo_sync)
                        b=$(printf '%s' "$arguments" | $_JQ -r '.branch // "develop"' 2>/dev/null)
                        res=$(gitea_repo_sync "$b" 2>&1)
                        _respond_result "$id" "{\"content\":[{\"type\":\"text\",\"text\":$(printf '%s' "$res" | $_JQ -Rs .)}]}"
                        ;;
                    gitea_pr_create)
                        h=$(printf '%s' "$arguments" | $_JQ -r '.head // empty' 2>/dev/null)
                        bs=$(printf '%s' "$arguments" | $_JQ -r '.base // "develop"' 2>/dev/null)
                        t=$(printf '%s' "$arguments" | $_JQ -r '.title // empty' 2>/dev/null)
                        bdy=$(printf '%s' "$arguments" | $_JQ -r '.body // ""' 2>/dev/null)
                        res=$(gitea_pr_create "$h" "$bs" "$t" "$bdy" 2>&1)
                        _respond_result "$id" "{\"content\":[{\"type\":\"text\",\"text\":$(printf '%s' "$res" | $_JQ -Rs .)}]}"
                        ;;
                    gitea_pr_list)
                        st=$(printf '%s' "$arguments" | $_JQ -r '.state // "open"' 2>/dev/null)
                        res=$(gitea_pr_list "$st" 2>&1)
                        _respond_result "$id" "{\"content\":[{\"type\":\"text\",\"text\":$(printf '%s' "$res" | $_JQ -Rs .)}]}"
                        ;;
                    gitea_pr_merge)
                        idx=$(printf '%s' "$arguments" | $_JQ -r '.index // empty' 2>/dev/null)
                        strat=$(printf '%s' "$arguments" | $_JQ -r '.strategy // "merge"' 2>/dev/null)
                        res=$(gitea_pr_merge "$idx" "$strat" 2>&1)
                        _respond_result "$id" "{\"content\":[{\"type\":\"text\",\"text\":$(printf '%s' "$res" | $_JQ -Rs .)}]}"
                        ;;
                    *)
                        _respond_error "$id" -32601 "Unknown tool: $tool_name"
                        ;;
                esac
                ;;
            *)
                _respond_error "$id" -32601 "Unknown method: $method"
                ;;
        esac
    done
fi
