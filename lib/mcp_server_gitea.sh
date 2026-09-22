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

gitea_set_endpoint() {
    local new_url="$1"
    [ -z "$new_url" ] && return 1
    [[ "$new_url" != http://* ]] && [[ "$new_url" != https://* ]] && new_url="http://$new_url"
    new_url="${new_url%/}"

    _gitea_load_conf
    mkdir -p "$(dirname "$GITEA_CONF")" 2>/dev/null || true

    if [ -f "$GITEA_CONF" ]; then
        if grep -q '^GITEA_URL=' "$GITEA_CONF" 2>/dev/null; then
            sed -i "s|^GITEA_URL=.*|GITEA_URL=\"$new_url\"|" "$GITEA_CONF"
        else
            echo "GITEA_URL=\"$new_url\"" >> "$GITEA_CONF"
        fi
    else
        cat << EOF > "$GITEA_CONF"
GITEA_URL="$new_url"
GITEA_USER="${GITEA_USER:-george}"
GITEA_TOKEN="${GITEA_TOKEN:-}"
GITEA_REPO="${GITEA_REPO:-blue-lodge}"
EOF
    fi

    GITEA_URL="$new_url"

    # Also update git remote 'gitea' if present in git repository (and not in unit test isolation)
    if [ "${LODGE_TEST_MODE:-0}" -ne 1 ] && [ -z "${TEST_TMP:-}" ]; then
        if command -v git &>/dev/null && git remote get-url gitea &>/dev/null; then
            local repo_path="${GITEA_USER:-george}/${GITEA_REPO:-blue-lodge}.git"
            local auth_part=""
            if [ -n "${GITEA_TOKEN:-}" ]; then
                auth_part="${GITEA_USER:-george}:${GITEA_TOKEN}@"
            fi
            local proto="${new_url%%://*}://"
            local host_part="${new_url#*://}"
            local new_remote="${proto}${auth_part}${host_part}/${repo_path}"
            git remote set-url gitea "$new_remote" 2>/dev/null || true
        fi
    fi

    return 0
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

    # Wait for mergeable status if pending
    local max_wait=5
    local wait_count=0
    while [ "$wait_count" -lt "$max_wait" ]; do
        local pr_info
        pr_info=$(curl -s "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/pulls/${index}" \
            -H "Authorization: token ${GITEA_TOKEN}" 2>/dev/null)
        local is_mergeable
        is_mergeable=$(echo "$pr_info" | jq -r '.mergeable // empty' 2>/dev/null)
        if [ "$is_mergeable" = "true" ]; then
            break
        elif [ "$is_mergeable" = "false" ]; then
            ui_err "PR #${index} has merge conflicts and cannot be merged."
            return 1
        fi
        sleep 1
        wait_count=$((wait_count + 1))
    done

    local tmp_resp
    tmp_resp=$(mktemp)
    local http_code
    http_code=$(curl -s -w "%{http_code}" -o "$tmp_resp" -X POST "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/pulls/${index}/merge" \
        -H "Authorization: token ${GITEA_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"Do\":\"${do_type}\"}" 2>/dev/null)
    local resp_body
    resp_body=$(cat "$tmp_resp" 2>/dev/null)
    rm -f "$tmp_resp"

    if [ "$http_code" = "200" ] || [ "$http_code" = "204" ] || [ "$http_code" = "201" ] || [ -z "$resp_body" ] || [ "$resp_body" = "null" ]; then
        ui_ok "Sovereign Gitea PR #${index} successfully merged via ${do_type}!"
        # Sync local develop branch
        git -C "$LODGE_DIR" fetch gitea develop >/dev/null 2>&1 || true
        local cur_branch
        cur_branch=$(git -C "$LODGE_DIR" branch --show-current 2>/dev/null)
        if [ "$cur_branch" = "develop" ]; then
            git -C "$LODGE_DIR" merge --ff-only gitea/develop >/dev/null 2>&1 || true
        fi
        return 0
    else
        ui_err "Failed to merge Gitea PR #${index} (HTTP $http_code): $resp_body"
        return 1
    fi
}

_gitea_resolve_label_ids() {
    local labels_csv="$1"
    [ -z "$labels_csv" ] && { echo "[]"; return 0; }

    _gitea_load_conf
    local existing
    existing=$(curl -s "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/labels" \
        -H "Authorization: token ${GITEA_TOKEN}" 2>/dev/null || echo "[]")

    local ids=()
    local IFS=','
    for raw in $labels_csv; do
        local name
        name=$(echo "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$name" ] && continue

        local lid
        lid=$(echo "$existing" | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' 2>/dev/null | head -n 1)

        if [ -z "$lid" ] || [ "$lid" = "null" ]; then
            # Create label
            local color="0284c7"
            case "$name" in
                escalation|needs-operator) color="e11d48" ;;
                blocked)                  color="f97316" ;;
                harness-bug)              color="8b5cf6" ;;
                audit-passed)             color="16a34a" ;;
                audit-failed)             color="dc2626" ;;
            esac
            local new_label
            new_label=$(curl -s -X POST "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/labels" \
                -H "Authorization: token ${GITEA_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{\"name\": \"$name\", \"color\": \"$color\"}" 2>/dev/null)
            lid=$(echo "$new_label" | jq -r .id 2>/dev/null || true)
        fi

        if [ -n "$lid" ] && [ "$lid" != "null" ]; then
            ids+=("$lid")
        fi
    done

    if [ ${#ids[@]} -eq 0 ]; then
        echo "[]"
    else
        printf '%s\n' "${ids[@]}" | jq -s '.'
    fi
}

gitea_issue_create() {
    local title="$1"
    local body="${2:-}"
    local labels="${3:-}"
    _gitea_load_conf
    if ! gitea_is_online; then
        echo "ERROR: Gitea server ($GITEA_URL) is offline."
        return 1
    fi

    local labels_ids
    labels_ids=$(_gitea_resolve_label_ids "$labels")

    local payload
    payload=$(jq -n \
        --arg title "$title" \
        --arg body "$body" \
        --argjson labels "$labels_ids" \
        '{
            title: $title,
            body: $body,
            labels: $labels
        }')

    local resp
    resp=$(curl -s -X POST "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/issues" \
        -H "Authorization: token ${GITEA_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    if echo "$resp" | jq -e .number &>/dev/null; then
        local num html_url
        num=$(echo "$resp" | jq -r .number)
        html_url=$(echo "$resp" | jq -r .html_url)
        ui_ok "Sovereign Gitea Issue #${num} created: $title" >&2
        ui_dim "  URL: $html_url" >&2
        echo "$resp"
        return 0
    else
        local err_msg
        err_msg=$(echo "$resp" | jq -r .message 2>/dev/null || echo "$resp")
        ui_err "Failed to create Gitea Issue: $err_msg" >&2
        echo "$resp"
        return 1
    fi
}

gitea_issue_list() {
    local state="${1:-open}"
    local format="${2:-text}"
    _gitea_load_conf
    if ! gitea_is_online; then
        echo "ERROR: Gitea server ($GITEA_URL) is offline."
        return 1
    fi

    local resp
    resp=$(curl -s "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/issues?state=${state}&type=issues" \
        -H "Authorization: token ${GITEA_TOKEN}" 2>/dev/null)

    if ! echo "$resp" | jq -e 'type == "array"' &>/dev/null; then
        echo "No issues returned or error: $resp"
        return 1
    fi

    if [ "$format" = "json" ] || [ "$state" = "--json" ]; then
        echo "$resp"
        return 0
    fi

    echo "$resp" | jq -r '.[] | "#\(.number) (\(.state)) [\(.labels | map(.name) | join(","))] \(.title)"'
}

gitea_issue_get() {
    local index="$1"
    _gitea_load_conf
    if [ -z "$index" ]; then
        echo "ERROR: index is required"
        return 1
    fi
    if ! gitea_is_online; then
        echo "ERROR: Gitea server ($GITEA_URL) is offline."
        return 1
    fi
    curl -s "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/issues/${index}" \
        -H "Authorization: token ${GITEA_TOKEN}" 2>/dev/null
}

gitea_issue_comment() {
    local index="$1"
    local body="$2"
    _gitea_load_conf
    if ! gitea_is_online; then
        echo "ERROR: Gitea server ($GITEA_URL) is offline."
        return 1
    fi

    local payload
    payload=$(jq -n --arg body "$body" '{"body": $body}')

    curl -s -X POST "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/issues/${index}/comments" \
        -H "Authorization: token ${GITEA_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null
}

gitea_issue_close() {
    local index="$1"
    local close_comment="${2:-}"
    _gitea_load_conf
    if ! gitea_is_online; then
        echo "ERROR: Gitea server ($GITEA_URL) is offline."
        return 1
    fi

    if [ -n "$close_comment" ]; then
        gitea_issue_comment "$index" "$close_comment" >/dev/null 2>&1 || true
    fi

    curl -s -X PATCH "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/issues/${index}" \
        -H "Authorization: token ${GITEA_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"state": "closed"}' 2>/dev/null
}

gitea_issue_label() {
    local index="$1"
    local label="$2"
    _gitea_load_conf
    if ! gitea_is_online; then
        return 1
    fi
    curl -s -X POST "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/issues/${index}/labels" \
        -H "Authorization: token ${GITEA_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"labels\": [\"$label\"]}" 2>/dev/null
}

gitea_pr_review() {
    local index="$1"
    local event="${2:-COMMENT}" # APPROVED, REQUEST_CHANGES, COMMENT
    local body="${3:-}"
    _gitea_load_conf
    if ! gitea_is_online; then
        echo "ERROR: Gitea server ($GITEA_URL) is offline."
        return 1
    fi

    local payload
    payload=$(jq -n --arg event "$event" --arg body "$body" '{"event": $event, "body": $body}')

    local resp
    resp=$(curl -s -X POST "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/pulls/${index}/reviews" \
        -H "Authorization: token ${GITEA_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    if echo "$resp" | jq -e .id &>/dev/null; then
        echo "$resp"
        return 0
    else
        echo "$resp"
        return 1
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
                        },
                        {
                            "name": "gitea_issue_create",
                            "description": "Create an issue on sovereign Gitea forge for subagent escalation or tracking.",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "title": { "type": "string", "description": "Issue title" },
                                    "body": { "type": "string", "description": "Markdown body with stack traces and diagnostics" },
                                    "labels": { "type": "string", "description": "Comma-separated labels" }
                                },
                                "required": ["title"]
                            }
                        },
                        {
                            "name": "gitea_issue_comment",
                            "description": "Post an auditable comment to a Gitea issue or PR.",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "index": { "type": "integer", "description": "Issue or PR number" },
                                    "body": { "type": "string", "description": "Markdown comment body" }
                                },
                                "required": ["index", "body"]
                            }
                        },
                        {
                            "name": "gitea_issue_close",
                            "description": "Close a Gitea issue with an optional resolution comment.",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "index": { "type": "integer", "description": "Issue number" },
                                    "comment": { "type": "string", "description": "Optional closing comment" }
                                },
                                "required": ["index"]
                            }
                        },
                        {
                            "name": "gitea_pr_review",
                            "description": "Submit a formal Three Degrees review on a Gitea PR (APPROVED, REQUEST_CHANGES, COMMENT).",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "index": { "type": "integer", "description": "PR number" },
                                    "event": { "type": "string", "description": "APPROVED, REQUEST_CHANGES, or COMMENT", "enum": ["APPROVED", "REQUEST_CHANGES", "COMMENT"] },
                                    "body": { "type": "string", "description": "Review reasoning and audit findings" }
                                },
                                "required": ["index", "event"]
                            }
                        },
                        {
                            "name": "gitea_issue_list",
                            "description": "List issues from Sovereign Gitea filtered by state (open, closed, all).",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "state": { "type": "string", "description": "Filter state: open, closed, all", "enum": ["open", "closed", "all"] }
                                }
                            }
                        },
                        {
                            "name": "gitea_issue_get",
                            "description": "Get complete metadata for a specific Gitea issue.",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "index": { "type": "integer", "description": "Issue number" }
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
                    gitea_issue_create)
                        t=$(printf '%s' "$arguments" | $_JQ -r '.title // empty' 2>/dev/null)
                        bdy=$(printf '%s' "$arguments" | $_JQ -r '.body // ""' 2>/dev/null)
                        lbl=$(printf '%s' "$arguments" | $_JQ -r '.labels // ""' 2>/dev/null)
                        res=$(gitea_issue_create "$t" "$bdy" "$lbl" 2>&1)
                        _respond_result "$id" "{\"content\":[{\"type\":\"text\",\"text\":$(printf '%s' "$res" | $_JQ -Rs .)}]}"
                        ;;
                    gitea_issue_list)
                        st=$(printf '%s' "$arguments" | $_JQ -r '.state // "open"' 2>/dev/null)
                        res=$(gitea_issue_list "$st" "json" 2>&1)
                        _respond_result "$id" "{\"content\":[{\"type\":\"text\",\"text\":$(printf '%s' "$res" | $_JQ -Rs .)}]}"
                        ;;
                    gitea_issue_get)
                        idx=$(printf '%s' "$arguments" | $_JQ -r '.index // empty' 2>/dev/null)
                        res=$(gitea_issue_get "$idx" 2>&1)
                        _respond_result "$id" "{\"content\":[{\"type\":\"text\",\"text\":$(printf '%s' "$res" | $_JQ -Rs .)}]}"
                        ;;
                    gitea_issue_comment)
                        idx=$(printf '%s' "$arguments" | $_JQ -r '.index // empty' 2>/dev/null)
                        bdy=$(printf '%s' "$arguments" | $_JQ -r '.body // ""' 2>/dev/null)
                        res=$(gitea_issue_comment "$idx" "$bdy" 2>&1)
                        _respond_result "$id" "{\"content\":[{\"type\":\"text\",\"text\":$(printf '%s' "$res" | $_JQ -Rs .)}]}"
                        ;;
                    gitea_issue_close)
                        idx=$(printf '%s' "$arguments" | $_JQ -r '.index // empty' 2>/dev/null)
                        cmt=$(printf '%s' "$arguments" | $_JQ -r '.comment // ""' 2>/dev/null)
                        res=$(gitea_issue_close "$idx" "$cmt" 2>&1)
                        _respond_result "$id" "{\"content\":[{\"type\":\"text\",\"text\":$(printf '%s' "$res" | $_JQ -Rs .)}]}"
                        ;;
                    gitea_pr_review)
                        idx=$(printf '%s' "$arguments" | $_JQ -r '.index // empty' 2>/dev/null)
                        evt=$(printf '%s' "$arguments" | $_JQ -r '.event // "COMMENT"' 2>/dev/null)
                        bdy=$(printf '%s' "$arguments" | $_JQ -r '.body // ""' 2>/dev/null)
                        res=$(gitea_pr_review "$idx" "$evt" "$bdy" 2>&1)
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
