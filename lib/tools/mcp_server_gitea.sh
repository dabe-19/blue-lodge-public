#!/bin/bash
# ── George: Sovereign Gitea MCP Server (2026) ────────────────────────
# Pure POSIX bash + curl JSON-RPC server implementing the Model Context Protocol.
# Manages Gitea repository operations, PR workflows, and GitFlow branches.
# Can run as standalone MCP server over stdio or be sourced by Lodge libraries.

[ -n "${_LIB_MCP_SERVER_GITEA_LOADED:-}" ] && return 0; _LIB_MCP_SERVER_GITEA_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
GITEA_CONF="${GITEA_CONF:-$GEORGE_DIR/gitea.conf}"

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/git.sh" 2>/dev/null || true

_gitea_load_conf() {
    local conf="$GITEA_CONF"
    if [ ! -f "$conf" ] && [ -f "$GEORGE_DIR/gitea.conf" ]; then
        conf="$GEORGE_DIR/gitea.conf"
    fi
    if [ ! -f "$conf" ] && [ -f "$HOME/blue-lodge/.george/gitea.conf" ]; then
        conf="$HOME/blue-lodge/.george/gitea.conf"
    fi
    if [ -f "$conf" ]; then
        GITEA_URL=$(grep '^GITEA_URL=' "$conf" 2>/dev/null | cut -d= -f2- | tr -d '"')
        GITEA_USER=$(grep '^GITEA_USER=' "$conf" 2>/dev/null | cut -d= -f2- | tr -d '"')
        GITEA_TOKEN=$(grep '^GITEA_TOKEN=' "$conf" 2>/dev/null | cut -d= -f2- | tr -d '"')
        GITEA_REPO=$(grep '^GITEA_REPO=' "$conf" 2>/dev/null | cut -d= -f2- | tr -d '"')
    fi
    GITEA_URL="${GITEA_URL:-http://127.0.0.1:3088}"
    GITEA_USER="${GITEA_USER:-george}"
    GITEA_REPO="${GITEA_REPO:-blue-lodge}"
}

_gitea_is_test_mode() {
    [ "${GITEA_ALLOW_LIVE_MUTATIONS:-0}" -eq 1 ] && return 1
    [ "${_LODGE_TESTING:-0}" -eq 1 ] || [ "${LODGE_TEST_MODE:-0}" -eq 1 ] || [ -n "${TEST_TMP:-}" ] || [ -n "${GEORGE_TEST_SANDBOX:-}" ]
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

# Version probe. Sends the token when configured because the forge runs with
# REQUIRE_SIGNIN_VIEW=true (anonymous API calls get 403). Prints the HTTP code
# (000 = unreachable); body goes to the file in $1 when given.
_gitea_probe() {
    local body_out="${1:-/dev/null}"
    local -a hdr=()
    [ -n "${GITEA_TOKEN:-}" ] && hdr=(-H "Authorization: token ${GITEA_TOKEN}")
    curl -s --max-time 1.5 -o "$body_out" -w '%{http_code}' "${hdr[@]}" "${GITEA_URL}/api/v1/version" 2>/dev/null || true
}

# Online = the server answered HTTP at all (auth problems surface on the real call).
gitea_is_online() {
    _gitea_load_conf
    local code
    code=$(_gitea_probe)
    [ -n "$code" ] && [ "$code" != "000" ]
}

gitea_status() {
    _gitea_load_conf
    local online=0
    local ver="offline"
    local tmp code
    tmp=$(mktemp)
    code=$(_gitea_probe "$tmp")
    if [ -n "$code" ] && [ "$code" != "000" ]; then
        online=1
        ver=$(jq -r '.version // "online"' "$tmp" 2>/dev/null || echo "online")
        [ -z "$ver" ] && ver="online"
    fi
    rm -f "$tmp"

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

    if _gitea_is_test_mode; then
        declare -f ui_dim &>/dev/null && ui_dim "[MOCK] PR created (test mode): $title" >&2
        jq -nc --arg title "$title" --arg head "$head" --arg base "$base" \
            '{number: 9999, id: 9999, title: $title, head: {ref: $head}, base: {ref: $base}, state: "open"}'
        return 0
    fi

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
    if _gitea_is_test_mode; then
        declare -f ui_dim &>/dev/null && ui_dim "[MOCK] PR #${index} merged (test mode)" >&2
        jq -nc --argjson idx "${index:-1}" '{number: $idx, merged: true, message: "Pull request successfully merged"}'
        return 0
    fi

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
        -d "{\"Do\":\"${do_type}\",\"delete_branch_after_merge\":true}" 2>/dev/null)
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

        # Also ensure head branch is deleted locally and remotely
        local head_ref
        head_ref=$(echo "$pr_info" | jq -r '.head.ref // empty' 2>/dev/null)
        if [ -n "$head_ref" ] && [ "$head_ref" != "develop" ] && [ "$head_ref" != "main" ] && [ "$head_ref" != "master" ]; then
            git -C "$LODGE_DIR" push gitea --delete "$head_ref" >/dev/null 2>&1 || true
            git -C "$LODGE_DIR" branch -D "$head_ref" >/dev/null 2>&1 || true
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
                remediate)                color="ca8a04" ;;
                george-queued)            color="64748b" ;;
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

    if _gitea_is_test_mode; then
        local m_store="${GEORGE_TEST_SANDBOX:-${GEORGE_DIR:-/tmp}}/.gitea_mock_issues.json"
        local cur_cnt=1
        [ -f "$m_store" ] && cur_cnt=$(jq '. | length + 1' "$m_store" 2>/dev/null || echo 1)
        local mock_num=$(( 9000 + cur_cnt ))
        local mock_resp
        mock_resp=$(jq -nc \
            --argjson num "$mock_num" \
            --arg title "$title" \
            --arg body "$body" \
            --arg url "http://127.0.0.1:3088/george/blue-lodge/issues/$mock_num" \
            '{
                id: $num,
                number: $num,
                title: $title,
                body: $body,
                state: "open",
                html_url: $url,
                labels: [],
                comments: 0,
                created_at: "2026-10-09T00:00:00Z"
            }')
        mkdir -p "$(dirname "$m_store")" 2>/dev/null || true
        if [ -f "$m_store" ]; then
            jq --argjson it "$mock_resp" '. + [$it]' "$m_store" > "${m_store}.tmp" 2>/dev/null && mv "${m_store}.tmp" "$m_store"
        else
            echo "[$mock_resp]" > "$m_store"
        fi
        declare -f ui_dim &>/dev/null && ui_dim "[MOCK] Sovereign Gitea Issue #${mock_num} created (test mode): $title" >&2
        echo "$mock_resp"
        return 0
    fi

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
    local label_filter="${3:-}"   # optional: server-side label filter (comma list)
    [ "$state" = "--json" ] && { state="open"; format="json"; }
    case "$state" in open|closed|all) ;; *) state="open" ;; esac
    _gitea_load_conf
    if ! gitea_is_online; then
        echo "ERROR: Gitea server ($GITEA_URL) is offline."
        return 1
    fi

    local q="state=${state}&type=issues&limit=50"
    if [ -n "$label_filter" ]; then
        [[ "$label_filter" =~ ^[A-Za-z0-9._/,-]+$ ]] || return 1
        q="${q}&labels=${label_filter}"
    fi
    local resp
    resp=$(curl -s "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/issues?${q}" \
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
    if [ -z "$index" ]; then
        echo "ERROR: index is required"
        return 1
    fi
    if _gitea_is_test_mode; then
        local m_store="${GEORGE_TEST_SANDBOX:-${GEORGE_DIR:-/tmp}}/.gitea_mock_issues.json"
        if [ -f "$m_store" ]; then
            local found
            found=$(jq -c --argjson idx "$index" '.[] | select(.number == $idx)' "$m_store" 2>/dev/null | head -n 1)
            if [ -n "$found" ]; then
                echo "$found"
                return 0
            fi
        fi
    fi
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
    if _gitea_is_test_mode; then
        declare -f ui_dim &>/dev/null && ui_dim "[MOCK] Comment posted to Issue #${index} (test mode)" >&2
        jq -nc --argjson num "$index" --arg body "$body" \
            '{id: ($num * 10 + 1), issue_id: $num, body: $body, created_at: "2026-10-09T00:00:00Z"}'
        return 0
    fi
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
    if _gitea_is_test_mode; then
        local m_store="${GEORGE_TEST_SANDBOX:-${GEORGE_DIR:-/tmp}}/.gitea_mock_issues.json"
        if [ -f "$m_store" ]; then
            jq --argjson idx "$index" 'map(if .number == $idx then .state = "closed" else . end)' "$m_store" > "${m_store}.tmp" 2>/dev/null && mv "${m_store}.tmp" "$m_store"
        fi
        declare -f ui_dim &>/dev/null && ui_dim "[MOCK] Issue #${index} closed (test mode)" >&2
        jq -nc --argjson idx "$index" '{number: $idx, state: "closed"}'
        return 0
    fi
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
    _gitea_is_test_mode && return 0
    _gitea_load_conf
    if ! gitea_is_online; then
        return 1
    fi
    curl -s -X POST "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/issues/${index}/labels" \
        -H "Authorization: token ${GITEA_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"labels\": [\"$label\"]}" 2>/dev/null
}

# Adds labels (comma list) to an issue by resolved id; creates missing labels.
gitea_issue_add_labels() {
    local index="$1" labels_csv="$2"
    [[ "$index" =~ ^[0-9]+$ ]] || return 1
    _gitea_is_test_mode && return 0
    _gitea_load_conf
    local ids
    ids=$(_gitea_resolve_label_ids "$labels_csv")
    [ "$ids" = "[]" ] && return 1
    curl -s -X POST "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/issues/${index}/labels" \
        -H "Authorization: token ${GITEA_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc --argjson l "$ids" '{labels: $l}')" 2>/dev/null
}

gitea_pr_review() {
    local index="$1"
    local event="${2:-COMMENT}" # APPROVED, REQUEST_CHANGES, COMMENT
    local body="${3:-}"
    if _gitea_is_test_mode; then
        declare -f ui_dim &>/dev/null && ui_dim "[MOCK] PR Review on #${index} recorded (test mode)" >&2
        jq -nc --argjson idx "$index" --arg event "$event" --arg body "$body" \
            '{id: ($idx * 100 + 1), state: $event, body: $body}'
        return 0
    fi
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

gitea_branch_create() {
    local branch_name="$1"
    local base="${2:-develop}"

    if [ -z "$branch_name" ]; then
        echo "ERROR: branch_name is required."
        return 1
    fi

    if _gitea_is_test_mode; then
        declare -f ui_dim &>/dev/null && ui_dim "[MOCK] Branch created (test mode): $branch_name" >&2
        jq -nc --arg name "$branch_name" '{name: $name}'
        return 0
    fi

    _gitea_load_conf
    if ! gitea_is_online; then
        if [ -d "$LODGE_DIR/.git" ]; then
            git -C "$LODGE_DIR" branch "$branch_name" "$base" 2>&1
            return $?
        fi
        echo "ERROR: Gitea server ($GITEA_URL) is offline."
        return 1
    fi

    local payload
    payload=$(jq -n \
        --arg nb "$branch_name" \
        --arg ob "$base" \
        '{
            new_branch_name: $nb,
            old_branch_name: $ob
        }')

    local resp
    resp=$(curl -s -X POST "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/branches" \
        -H "Authorization: token ${GITEA_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    if echo "$resp" | jq -e '.name' &>/dev/null; then
        echo "$resp"
        return 0
    elif echo "$resp" | jq -e '.message' &>/dev/null; then
        echo "ERROR: $(echo "$resp" | jq -r '.message')"
        return 1
    else
        echo "$resp"
        return 0
    fi
}

gitea_branch_delete() {
    local branch_name="$1"
    if [ -z "$branch_name" ]; then
        echo "ERROR: branch_name is required."
        return 1
    fi
    if [ "$branch_name" = "develop" ] || [ "$branch_name" = "main" ] || [ "$branch_name" = "master" ]; then
        echo "ERROR: Protected branch '$branch_name' cannot be deleted."
        return 1
    fi

    if _gitea_is_test_mode; then
        declare -f ui_dim &>/dev/null && ui_dim "[MOCK] Branch deleted (test mode): $branch_name" >&2
        jq -nc --arg name "$branch_name" '{name: $name, deleted: true}'
        return 0
    fi

    _gitea_load_conf
    if ! gitea_is_online; then
        if [ -d "$LODGE_DIR/.git" ]; then
            git -C "$LODGE_DIR" branch -D "$branch_name" 2>&1 || true
            return 0
        fi
        echo "ERROR: Gitea server ($GITEA_URL) is offline."
        return 1
    fi

    local http_code
    http_code=$(curl -s -w "%{http_code}" -o /dev/null -X DELETE \
        "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/branches/${branch_name}" \
        -H "Authorization: token ${GITEA_TOKEN}" 2>/dev/null)

    # Also delete via git push as fallback/sync
    git -C "$LODGE_DIR" push gitea --delete "$branch_name" >/dev/null 2>&1 || true
    git -C "$LODGE_DIR" branch -D "$branch_name" >/dev/null 2>&1 || true

    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ] || [ "$http_code" = "404" ]; then
        jq -nc --arg name "$branch_name" '{name: $name, deleted: true}'
        return 0
    else
        echo "ERROR: Failed to delete branch $branch_name (HTTP $http_code)"
        return 1
    fi
}

gitea_branch_list() {
    if _gitea_is_test_mode; then
        echo '[{"name":"develop"},{"name":"main"}]'
        return 0
    fi

    _gitea_load_conf
    if ! gitea_is_online; then
        echo "ERROR: Gitea server ($GITEA_URL) is offline."
        return 1
    fi

    curl -s -H "Authorization: token ${GITEA_TOKEN}" \
        "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/branches?limit=100" 2>/dev/null || echo "[]"
}

gitea_prune_orphaned_branches() {
    if _gitea_is_test_mode; then
        declare -f ui_dim &>/dev/null && ui_dim "[MOCK] Pruned orphaned branches (test mode)" >&2
        jq -nc '{pruned: 0, message: "Mock prune complete"}'
        return 0
    fi

    _gitea_load_conf
    if ! gitea_is_online; then
        echo "ERROR: Gitea server is offline."
        return 1
    fi

    declare -f ui_step &>/dev/null && ui_step "Inspecting Sovereign Gitea branches for orphaned or merged candidates..."
    local branches_json
    branches_json=$(curl -s -H "Authorization: token ${GITEA_TOKEN}" \
        "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/branches?limit=100" 2>/dev/null || echo "[]")

    local b_count
    b_count=$(echo "$branches_json" | jq '. | length' 2>/dev/null || echo 0)
    if [ "$b_count" -eq 0 ]; then
        declare -f ui_ok &>/dev/null && ui_ok "No branches found on Gitea."
        jq -nc '{pruned: 0, branches: []}'
        return 0
    fi

    # Fetch latest develop so we know what is merged
    git -C "$LODGE_DIR" fetch gitea develop >/dev/null 2>&1 || true

    # Get list of open PR head branches so we never delete branches with active open PRs
    local open_pr_heads
    open_pr_heads=$(curl -s -H "Authorization: token ${GITEA_TOKEN}" \
        "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/pulls?state=open&limit=100" 2>/dev/null | \
        jq -r '.[].head.ref // empty' 2>/dev/null || echo "")

    local pruned=0
    local pruned_list=()
    local i
    for (( i=0; i<b_count; i++ )); do
        local b_name
        b_name=$(echo "$branches_json" | jq -r ".[$i].name" 2>/dev/null)
        [ -z "$b_name" ] && continue

        # Protected branches
        if [ "$b_name" = "develop" ] || [ "$b_name" = "main" ] || [ "$b_name" = "master" ]; then
            continue
        fi

        # Only prune ephemeral subagent, remediation, and checkpoint branches
        if [[ ! "$b_name" =~ ^(subagent/|remediation/|checkpoint/) ]]; then
            continue
        fi

        # Do not prune if there is an active open PR for this branch
        if echo "$open_pr_heads" | grep -qx "$b_name"; then
            continue
        fi

        local should_prune=0
        local reason=""

        # Fetch the remote branch ref to check commit distance
        git -C "$LODGE_DIR" fetch gitea "$b_name" >/dev/null 2>&1 || true

        # 1. Check if branch is fully merged into develop
        if git -C "$LODGE_DIR" merge-base --is-ancestor "gitea/$b_name" "gitea/develop" 2>/dev/null; then
            should_prune=1
            reason="Merged into develop"
        else
            # 2. Check if branch has 0 substantive commits ahead of develop
            local ahead_count
            ahead_count=$(git -C "$LODGE_DIR" rev-list --count "gitea/develop..gitea/$b_name" 2>/dev/null || echo 0)
            if [ "$ahead_count" -eq 0 ]; then
                should_prune=1
                reason="0 commits ahead of develop"
            elif [ "$ahead_count" -eq 1 ]; then
                # Check if the single commit only touched transient/state files
                local files_touched
                files_touched=$(git -C "$LODGE_DIR" diff --name-only "gitea/develop..gitea/$b_name" 2>/dev/null | \
                    grep -vE '^(\.pid|\.phase|\.pr_issued|task_meta\.json|\.done|.*\.fifo|trajectory\.log|\.pause_requested|\.resume_requested)' || true)
                if [ -z "$files_touched" ]; then
                    should_prune=1
                    reason="Only contains transient tracking files"
                else
                    # Check if commit author is a subagent and branch is older than 2 hours with no open PR
                    local commit_date
                    commit_date=$(git -C "$LODGE_DIR" log -1 --format=%ct "gitea/$b_name" 2>/dev/null || echo 0)
                    local now_epoch
                    now_epoch=$(date +%s)
                    if [ $((now_epoch - commit_date)) -ge 7200 ]; then
                        should_prune=1
                        reason="Abandoned subagent branch (>2h old, no open PR)"
                    fi
                fi
            else
                # Check if older than 24 hours with no open PR
                local commit_date
                commit_date=$(git -C "$LODGE_DIR" log -1 --format=%ct "gitea/$b_name" 2>/dev/null || echo 0)
                local now_epoch
                now_epoch=$(date +%s)
                if [ $((now_epoch - commit_date)) -ge 86400 ]; then
                    should_prune=1
                    reason="Stale ephemeral branch (>24h old, no open PR)"
                fi
            fi
        fi

        if [ "$should_prune" -eq 1 ]; then
            declare -f ui_info &>/dev/null && ui_info "Pruning orphaned branch '$b_name' ($reason)..."
            gitea_branch_delete "$b_name" >/dev/null 2>&1 || true
            pruned=$((pruned + 1))
            pruned_list+=("$b_name ($reason)")
        fi
    done

    # Prune local git tracking branches
    git -C "$LODGE_DIR" fetch gitea --prune >/dev/null 2>&1 || true

    if [ "$pruned" -gt 0 ]; then
        declare -f ui_ok &>/dev/null && ui_ok "Pruned $pruned orphaned branch(es) from sovereign Gitea."
    else
        declare -f ui_dim &>/dev/null && ui_dim "No orphaned subagent/remediation branches found on Gitea."
    fi

    jq -nc --argjson count "$pruned" --arg details "$(printf '%s\n' "${pruned_list[@]}")" \
        '{pruned: $count, details: $details}'
}

# ── JSON-RPC 2.0 MCP Protocol Loop (if run directly) ────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _JQ=$(command -v jq 2>/dev/null || echo "")

    _respond_result() {
        local id="$1" content="$2"
        local compact_res
        compact_res=$(printf '%s' "$content" | $_JQ -c . 2>/dev/null || printf '%s' "$content" | tr -d '\n\r')
        printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$id" "$compact_res"
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
                _respond_result "$id" '{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"george-gitea-mcp","version":"1.0.0"}}'
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
                        },
                        {
                            "name": "gitea_branch_create",
                            "description": "Create a new branch in the sovereign Gitea repository.",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "branch_name": { "type": "string", "description": "Name of the new branch" },
                                    "base": { "type": "string", "description": "Base branch or commit to branch from (default: develop)" }
                                },
                                "required": ["branch_name"]
                            }
                        },
                        {
                            "name": "gitea_branch_delete",
                            "description": "Delete a branch in the sovereign Gitea repository.",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "branch_name": { "type": "string", "description": "Name of the branch to delete" }
                                },
                                "required": ["branch_name"]
                            }
                        },
                        {
                            "name": "gitea_branch_prune",
                            "description": "Prune merged and orphaned subagent/remediation branches from Gitea.",
                            "inputSchema": {
                                "type": "object",
                                "properties": {}
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
                    gitea_branch_create)
                        bn=$(printf '%s' "$arguments" | $_JQ -r '.branch_name // empty' 2>/dev/null)
                        bs=$(printf '%s' "$arguments" | $_JQ -r '.base // "develop"' 2>/dev/null)
                        res=$(gitea_branch_create "$bn" "$bs" 2>&1)
                        _respond_result "$id" "{\"content\":[{\"type\":\"text\",\"text\":$(printf '%s' "$res" | $_JQ -Rs .)}]}"
                        ;;
                    gitea_branch_delete)
                        bn=$(printf '%s' "$arguments" | $_JQ -r '.branch_name // empty' 2>/dev/null)
                        res=$(gitea_branch_delete "$bn" 2>&1)
                        _respond_result "$id" "{\"content\":[{\"type\":\"text\",\"text\":$(printf '%s' "$res" | $_JQ -Rs .)}]}"
                        ;;
                    gitea_branch_prune)
                        res=$(gitea_prune_orphaned_branches 2>&1)
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
