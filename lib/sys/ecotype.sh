#!/usr/bin/env bash
# ── lib/sys/ecotype.sh: Software Phytology Ecotype & Upstream Pollination Engine ──
# Manages per-node `ecotype/<node-name>` branches so each sovereign George organism
# can evolve local adaptations (Foliage) independently while safely pollinating from
# and promoting node-agnostic improvements (Heartwood/Cambium) to `develop`.

[ -n "${_LIB_ECOTYPE_LOADED:-}" ] && return 0; _LIB_ECOTYPE_LOADED=1

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"

source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agents/phytology.sh" 2>/dev/null || true
declare -f ui_ok &>/dev/null   || ui_ok()   { printf "[✓] %s\n" "$*"; }
declare -f ui_info &>/dev/null || ui_info() { printf "[i] %s\n" "$*"; }
declare -f ui_warn &>/dev/null || ui_warn() { printf "[!] %s\n" "$*" >&2; }
declare -f ui_err &>/dev/null  || ui_err()  { printf "[✗] %s\n" "$*" >&2; }

# Foliage / personal paths that MUST NEVER be promoted to shared species branches (`develop` / `main`).
_ecotype_is_foliage_path() {
    local p="$1"
    case "$p" in
        .george/*|dossiers/*|market_cache/*|benchmarks/*|scratch/*|artifacts/*|*.db|*.gguf|*keys.conf|*secrets.env)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

ecotype_node_name() {
    local cfg="$GEORGE_DIR/configs/lodge.conf"
    [ ! -f "$cfg" ] && [ -f "$GEORGE_DIR/lodge.conf" ] && cfg="$GEORGE_DIR/lodge.conf"
    local name="${LODGE_NODE_NAME:-}"
    if [ -z "$name" ] && [ -f "$cfg" ]; then
        name=$(grep -m1 '^[[:space:]]*LODGE_NODE_NAME=' "$cfg" 2>/dev/null | cut -d= -f2- | tr -d "\"'[:space:]")
    fi
    if [ -z "$name" ]; then
        name=$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
    fi
    name=$(echo "${name:-george}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
    echo "${name:-george}"
}

ecotype_branch_name() {
    local n="${1:-$(ecotype_node_name)}"
    echo "ecotype/${n}"
}

_ecotype_git() {
    local _sock="${SSH_AUTH_SOCK:-}"
    if [ -z "$_sock" ] || ! [ -S "$_sock" ] || ! SSH_AUTH_SOCK="$_sock" ssh-add -l >/dev/null 2>&1; then
        local _s
        for _s in /tmp/ssh-*/agent.*; do
            [ -S "$_s" ] || continue
            if SSH_AUTH_SOCK="$_s" ssh-add -l >/dev/null 2>&1; then
                _sock="$_s"
                break
            fi
        done
    fi
    if [ -n "$_sock" ] && [ -S "$_sock" ]; then
        SSH_AUTH_SOCK="$_sock" git -C "$LODGE_DIR" -c safe.directory='*' "$@"
    else
        git -C "$LODGE_DIR" -c safe.directory='*' "$@"
    fi
}

_ecotype_push_gitea() {
    local refspec="$1"
    if ! _ecotype_git remote get-url gitea >/dev/null 2>&1; then
        return 0
    fi
    if _ecotype_git push --no-verify gitea "$refspec" >/dev/null 2>&1; then
        return 0
    fi
    # If running on host while gitea remote uses in-cluster DNS (.svc.cluster.local), exec via george-web pod
    if command -v kubectl >/dev/null 2>&1; then
        local pod
        pod=$(kubectl -n "${K8S_NAMESPACE:-blue-lodge}" get pods -l app=george-web -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        if [ -n "$pod" ]; then
            kubectl -n "${K8S_NAMESPACE:-blue-lodge}" exec "$pod" -- sh -c "git config --global --add safe.directory '*' && git -C /workspace push gitea '$refspec'" >/dev/null 2>&1 && return 0
        fi
    fi
    return 1
}

ecotype_upstream_ref() {
    if _ecotype_git show-ref --verify --quiet refs/remotes/origin/develop; then
        echo "origin/develop"
    elif _ecotype_git show-ref --verify --quiet refs/remotes/gitea/develop; then
        echo "gitea/develop"
    else
        echo "develop"
    fi
}

# Ensures this node is operating on `ecotype/<node-name>`.
ecotype_init() {
    local requested="${1:-}"
    if [ -n "$requested" ]; then
        local clean
        clean=$(echo "$requested" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
        if [ -n "$clean" ]; then
            mkdir -p "$GEORGE_DIR/configs" 2>/dev/null || true
            local cfg="$GEORGE_DIR/configs/lodge.conf"
            touch "$cfg"
            if grep -q '^[[:space:]]*LODGE_NODE_NAME=' "$cfg" 2>/dev/null; then
                sed -i "s|^[[:space:]]*LODGE_NODE_NAME=.*|LODGE_NODE_NAME=${clean}|" "$cfg"
            else
                echo "LODGE_NODE_NAME=${clean}" >> "$cfg"
            fi
            LODGE_NODE_NAME="$clean"
        fi
    fi

    local node target_branch cur_branch
    node="$(ecotype_node_name)"
    target_branch="ecotype/${node}"
    cur_branch="$(_ecotype_git branch --show-current 2>/dev/null || echo "")"

    if [ "$cur_branch" = "$target_branch" ]; then
        ui_ok "Already on node ecotype branch '${target_branch}' (node: ${node})."
    elif _ecotype_git show-ref --verify --quiet "refs/heads/${target_branch}"; then
        _ecotype_git checkout "$target_branch" || return 1
        ui_ok "Switched to existing node ecotype branch '${target_branch}'."
    else
        _ecotype_git checkout -b "$target_branch" || return 1
        ui_ok "Created and switched to node ecotype branch '${target_branch}' from '${cur_branch:-HEAD}'."
    fi

    if _ecotype_push_gitea "${target_branch}:${target_branch}"; then
        ui_info "Synced '${target_branch}' to local Gitea forge."
    fi
    if [ -z "${GEORGE_TEST_SANDBOX:-}" ] && [ "${_LODGE_TESTING:-0}" != "1" ] && _ecotype_git remote get-url origin >/dev/null 2>&1; then
        if GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10" _ecotype_git push --no-verify -u origin "${target_branch}:${target_branch}" >/dev/null 2>&1; then
            ui_info "Synced '${target_branch}' to origin (GitHub) and set upstream tracking."
        fi
    fi
}

ecotype_status() {
    local as_json=0
    [ "${1:-}" = "--json" ] && as_json=1

    local node expected_branch cur_branch upstream ahead behind dirty_count
    node="$(ecotype_node_name)"
    expected_branch="ecotype/${node}"
    cur_branch="$(_ecotype_git branch --show-current 2>/dev/null || echo "detached")"
    upstream="$(ecotype_upstream_ref)"

    ahead=0
    behind=0
    if _ecotype_git rev-parse --verify "$upstream" >/dev/null 2>&1; then
        local counts
        counts=$(_ecotype_git rev-list --left-right --count "${upstream}...HEAD" 2>/dev/null || echo "0 0")
        behind=$(echo "$counts" | awk '{print $1}')
        ahead=$(echo "$counts" | awk '{print $2}')
    fi

    local dirty_files_list=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local path_part="${line:3}"
        # Handle rename entries ("old -> new")
        if [[ "$path_part" == *" -> "* ]]; then
            path_part="${path_part##* -> }"
        fi
        dirty_files_list+=("$path_part")
    done < <(_ecotype_git status --porcelain 2>/dev/null || true)
    dirty_count=${#dirty_files_list[@]}

    local heartwood_files=()
    local foliage_files=()
    local upstream_commits_json="[]"
    local local_commits_json="[]"
    if _ecotype_git rev-parse --verify "$upstream" >/dev/null 2>&1; then
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            if _ecotype_is_foliage_path "$f"; then
                foliage_files+=("$f")
            else
                heartwood_files+=("$f")
            fi
        done < <(_ecotype_git diff --name-only "${upstream}...HEAD" 2>/dev/null || true)

        if [ "$as_json" -eq 1 ]; then
            upstream_commits_json=$(_ecotype_git log --format='%h%x09%s' -n 25 "HEAD..${upstream}" 2>/dev/null | \
                jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {sha: .[0], subject: (.[1] // "")})' 2>/dev/null || echo "[]")
            local_commits_json=$(_ecotype_git log --format='%h%x09%s' -n 25 "${upstream}..HEAD" 2>/dev/null | \
                jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {sha: .[0], subject: (.[1] // "")})' 2>/dev/null || echo "[]")
        fi
    fi

    if [ "$as_json" -eq 1 ]; then
        local hw_json="[]" fol_json="[]" dirty_json="[]"
        if [ ${#heartwood_files[@]} -gt 0 ]; then
            hw_json=$(printf '%s\n' "${heartwood_files[@]}" | jq -R . | jq -s .)
        fi
        if [ ${#foliage_files[@]} -gt 0 ]; then
            fol_json=$(printf '%s\n' "${foliage_files[@]}" | jq -R . | jq -s .)
        fi
        if [ ${#dirty_files_list[@]} -gt 0 ]; then
            dirty_json=$(printf '%s\n' "${dirty_files_list[@]}" | head -n 50 | jq -R . | jq -s .)
        fi
        jq -n \
            --arg node "$node" \
            --arg expected_branch "$expected_branch" \
            --arg current_branch "$cur_branch" \
            --arg upstream "$upstream" \
            --argjson on_ecotype "$( [ "$cur_branch" = "$expected_branch" ] && echo true || echo false )" \
            --argjson ahead "${ahead:-0}" \
            --argjson behind "${behind:-0}" \
            --argjson dirty "${dirty_count:-0}" \
            --argjson heartwood "$hw_json" \
            --argjson foliage "$fol_json" \
            --argjson dirty_list "$dirty_json" \
            --argjson upstream_commits "$upstream_commits_json" \
            --argjson local_commits "$local_commits_json" \
            '{
                status: "ok",
                node: $node,
                expected_branch: $expected_branch,
                current_branch: $current_branch,
                on_ecotype: $on_ecotype,
                upstream: $upstream,
                ahead: $ahead,
                behind: $behind,
                dirty_files: $dirty,
                dirty_list: $dirty_list,
                diverged_heartwood_count: ($heartwood | length),
                diverged_foliage_count: ($foliage | length),
                diverged_heartwood: $heartwood,
                diverged_foliage: $foliage,
                upstream_commits: $upstream_commits,
                local_commits: $local_commits
            }'
        return 0
    fi

    echo "═══ Software Phytology: Ecotype Status ═══"
    echo "  Organism Identity:     ${node}"
    echo "  Expected Ecotype:      ${expected_branch}"
    echo "  Active Git Branch:     ${cur_branch}$( [ "$cur_branch" = "$expected_branch" ] && echo " ✓" || echo " (run '/ecotype init' to switch)" )"
    echo "  Species Trunk Ref:     ${upstream}"
    echo "  Divergence vs Trunk:   +${ahead} commits ahead, -${behind} commits behind"
    echo "  Modified Tissue Split: ${#heartwood_files[@]} Heartwood/Cambium file(s) | ${#foliage_files[@]} Foliage (.george) file(s)"
    local mod_summary="none"
    if [ -f "$GEORGE_DIR/ecotype_manifest.json" ] && command -v jq >/dev/null 2>&1; then
        local _b_on _m_on
        _b_on=$(jq -r '[.builtins | to_entries[] | select(.value.enabled == true) | .key] | length' "$GEORGE_DIR/ecotype_manifest.json" 2>/dev/null || echo 0)
        _m_on=$(jq -r '[.modules | to_entries[] | select(.value.enabled == true) | .key] | join(", ")' "$GEORGE_DIR/ecotype_manifest.json" 2>/dev/null || echo "")
        mod_summary="${_b_on} built-in enabled | external: ${_m_on:-none}"
    fi
    echo "  Working Tree State:    $( [ "${dirty_count:-0}" -eq 0 ] && echo "clean" || echo "${dirty_count} uncommitted file(s)" )"
    echo "  Lodge Guild Modules:   ${mod_summary}"
}

# Sandboxed Pollination: fetches upstream `develop`, test-merges into an isolated worktree,
# verifies AST syntax on changed files, and only fast-forwards/merges live branch if clean.
ecotype_sync() {
    local remote_name="${1:-origin}"
    local remote_branch="${2:-develop}"
    local node cur_branch
    node="$(ecotype_node_name)"
    cur_branch="$(_ecotype_git branch --show-current 2>/dev/null || echo "")"
    if [ -z "$cur_branch" ]; then
        ui_err "Cannot run ecotype sync on a detached HEAD."
        return 1
    fi

    if [ -n "$(_ecotype_git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        ui_err "Working tree has uncommitted tracked changes. Commit or '/ecotype save' before pollinating from upstream."
        return 1
    fi

    ui_info "Fetching latest species genome from ${remote_name}/${remote_branch}..."
    if ! _ecotype_git fetch "$remote_name" "$remote_branch" >/dev/null 2>&1; then
        ui_warn "Could not reach '${remote_name}' over network; checking local cached ref '${remote_name}/${remote_branch}'."
    fi

    local target_ref="${remote_name}/${remote_branch}"
    if ! _ecotype_git rev-parse --verify "$target_ref" >/dev/null 2>&1; then
        ui_err "Upstream reference '${target_ref}' not found."
        return 1
    fi

    local behind
    behind=$(_ecotype_git rev-list --count "HEAD..${target_ref}" 2>/dev/null || echo 0)
    if [ "${behind:-0}" -eq 0 ]; then
        ui_ok "Branch '${cur_branch}' already contains all commits from '${target_ref}' (0 behind)."
        return 0
    fi

    local ts tmp_wt tmp_br
    ts=$(date +%s)
    mkdir -p "$GEORGE_DIR/tmp" 2>/dev/null || true
    tmp_wt="$GEORGE_DIR/tmp/pollinate_${ts}"
    tmp_br="tmp/pollinate-${node}-${ts}"

    ui_info "Testing pollination merge (${behind} new upstream commit(s)) in isolated sandbox worktree..."
    if ! _ecotype_git worktree add -b "$tmp_br" "$tmp_wt" HEAD >/dev/null 2>&1; then
        ui_err "Failed to create temporary pollination worktree at $tmp_wt"
        return 1
    fi

    local rc=0
    if ! git -C "$tmp_wt" -c safe.directory='*' merge --no-edit "$target_ref" >/dev/null 2>&1; then
        local conflicts
        conflicts=$(git -C "$tmp_wt" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
        git -C "$tmp_wt" merge --abort >/dev/null 2>&1 || true
        _ecotype_git worktree remove --force "$tmp_wt" >/dev/null 2>&1 || rm -rf "$tmp_wt"
        _ecotype_git branch -D "$tmp_br" >/dev/null 2>&1 || true
        ui_err "Pollination paused: merge conflict detected in [${conflicts}]. Live workspace was NOT modified."
        ui_info "Ask George to resolve '${target_ref}' into '${cur_branch}' inside a dedicated PR worktree."
        return 2
    fi

    # Verify syntax of any modified .sh / .py files in the sandbox
    while IFS= read -r changed; do
        [ -z "$changed" ] && continue
        [ -f "$tmp_wt/$changed" ] || continue
        if declare -f phytology_verify_syntax &>/dev/null; then
            if ! phytology_verify_syntax "$tmp_wt/$changed"; then
                ui_err "AST verification failed on merged file '$changed' in sandbox! Aborting pollination."
                rc=1
                break
            fi
        fi
    done < <(git -C "$tmp_wt" diff --name-only "HEAD@{1}..HEAD" 2>/dev/null || true)

    local merged_sha
    merged_sha=$(git -C "$tmp_wt" rev-parse HEAD)
    _ecotype_git worktree remove --force "$tmp_wt" >/dev/null 2>&1 || rm -rf "$tmp_wt"
    _ecotype_git branch -D "$tmp_br" >/dev/null 2>&1 || true

    if [ "$rc" -ne 0 ]; then
        return 1
    fi

    # Check if merged upstream commits modify the Rust web cockpit binary/Dockerfile
    local _web_changed=""
    _web_changed=$(_ecotype_git diff --name-only "HEAD..${merged_sha}" 2>/dev/null | grep -E '^web/(src/|Cargo\.toml|Cargo\.lock|Dockerfile)' | head -n 5 || true)

    # Fast-forward live branch to the verified sandbox merge commit
    _ecotype_git merge --ff-only "$merged_sha" >/dev/null 2>&1 || _ecotype_git merge --no-edit "$target_ref" >/dev/null 2>&1
    _ecotype_push_gitea "${cur_branch}:${cur_branch}" || true

    # Keep local 'develop' (and gitea/develop) aligned if it cleanly fast-forwards to upstream develop
    if [ "$remote_branch" = "develop" ] && [ "$cur_branch" != "develop" ]; then
        if _ecotype_git show-ref --verify --quiet refs/heads/develop && \
           _ecotype_git merge-base --is-ancestor refs/heads/develop "$target_ref" 2>/dev/null; then
            _ecotype_git branch -f develop "$target_ref" >/dev/null 2>&1 || true
            _ecotype_push_gitea "develop:develop" || true
        fi
    fi

    ui_ok "Successfully pollinated ${behind} upstream commit(s) from '${target_ref}' into '${cur_branch}'!"
    if [ -n "$_web_changed" ]; then
        ui_warn "Rust web cockpit changed in upstream merge — rebuild george-web to activate new API routes:"
        ui_info "  K8s:    ./scripts/infra/k8s_deploy.sh build web && ./scripts/infra/k8s_deploy.sh restart web"
        ui_info "  Docker: docker compose up -d --build george-web"
    fi
}

# Foliage-Firewalled Promotion: extracts ONLY specified Heartwood files onto a clean
# `candidate/<slug>` branch forked off `origin/develop`, blocking `.george/*` & personal alpha.
ecotype_promote() {
    local title="" push_origin=0
    local paths=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --title|-t)
                shift
                title="${1:-}"
                ;;
            --push-origin|--origin)
                push_origin=1
                ;;
            --)
                shift
                while [ $# -gt 0 ]; do paths+=("$1"); shift; done
                break
                ;;
            *)
                paths+=("$1")
                ;;
        esac
        [ $# -gt 0 ] && shift || true
    done

    if [ ${#paths[@]} -eq 0 ]; then
        ui_err "Usage: /ecotype promote --title \"<summary>\" [--push-origin] <heartwood_path1> [path2...]"
        return 1
    fi

    for p in "${paths[@]}"; do
        if _ecotype_is_foliage_path "$p"; then
            ui_err "FOLIAGE FIREWALL BLOCKED '${p}': personal .george/, dossiers/, keys, and market state cannot be promoted to shared Heartwood."
            return 1
        fi
    done

    local upstream slug cand_branch ts tmp_wt src_sha
    upstream="$(ecotype_upstream_ref)"
    src_sha="$(_ecotype_git rev-parse HEAD)"
    [ -z "$title" ] && title="Promote lignified heartwood from $(ecotype_node_name)"
    slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40)
    ts=$(date +%Y%m%d-%H%M%S)
    cand_branch="candidate/${slug}-${ts}"
    mkdir -p "$GEORGE_DIR/tmp" 2>/dev/null || true
    tmp_wt="$GEORGE_DIR/tmp/promote_${ts}"

    if ! _ecotype_git worktree add -b "$cand_branch" "$tmp_wt" "$upstream" >/dev/null 2>&1; then
        ui_err "Failed to create clean promotion worktree from '${upstream}'."
        return 1
    fi

    if ! git -C "$tmp_wt" -c safe.directory='*' checkout "$src_sha" -- "${paths[@]}" 2>/dev/null; then
        _ecotype_git worktree remove --force "$tmp_wt" >/dev/null 2>&1 || rm -rf "$tmp_wt"
        _ecotype_git branch -D "$cand_branch" >/dev/null 2>&1 || true
        ui_err "One or more paths could not be checked out from current HEAD."
        return 1
    fi

    if [ -z "$(git -C "$tmp_wt" status --porcelain 2>/dev/null)" ]; then
        _ecotype_git worktree remove --force "$tmp_wt" >/dev/null 2>&1 || rm -rf "$tmp_wt"
        _ecotype_git branch -D "$cand_branch" >/dev/null 2>&1 || true
        ui_info "Selected Heartwood path(s) are already identical to '${upstream}'."
        return 0
    fi

    git -C "$tmp_wt" add -A
    git -C "$tmp_wt" commit -m "feat(heartwood): ${title}" >/dev/null 2>&1
    _ecotype_git worktree remove --force "$tmp_wt" >/dev/null 2>&1 || rm -rf "$tmp_wt"

    _ecotype_push_gitea "${cand_branch}:${cand_branch}" || true
    if [ "$push_origin" -eq 1 ]; then
        _ecotype_git push origin "${cand_branch}:${cand_branch}" >/dev/null 2>&1 && \
            ui_ok "Pushed clean Heartwood candidate branch '${cand_branch}' to origin (GitHub)!"
    fi
    ui_ok "Created clean Heartwood promotion branch '${cand_branch}' (0 foliage files leaked)."
    echo "$cand_branch"
}

# Commits (if requested) and backs up `ecotype/<node>` to local Gitea and optionally GitHub `origin/ecotype/<node>`.
ecotype_backup() {
    local push_cloud=0 msg=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --cloud|--origin)
                push_cloud=1
                ;;
            -m|--message)
                shift
                msg="${1:-}"
                ;;
        esac
        [ $# -gt 0 ] && shift || true
    done

    local node expected_branch cur_branch
    node="$(ecotype_node_name)"
    expected_branch="ecotype/${node}"
    cur_branch="$(_ecotype_git branch --show-current 2>/dev/null || echo "")"

    if [ -n "$msg" ] && [ -n "$(_ecotype_git status --porcelain 2>/dev/null)" ]; then
        _ecotype_git add -A
        _ecotype_git commit -m "chore(${node}): ${msg}" >/dev/null 2>&1 || true
    fi

    local push_src="${cur_branch:-HEAD}"
    if _ecotype_push_gitea "${push_src}:refs/heads/${expected_branch}"; then
        ui_ok "Backed up '${push_src}' -> local Gitea '${expected_branch}'."
    else
        ui_warn "Local Gitea push skipped or unreachable."
    fi

    if [ "$push_cloud" -eq 1 ]; then
        if _ecotype_git push origin "${push_src}:refs/heads/${expected_branch}" >/dev/null 2>&1; then
            ui_ok "Mirrored '${expected_branch}' to cloud backup 'origin/${expected_branch}' (origin/develop untouched)."
        else
            ui_err "Cloud push to 'origin/${expected_branch}' failed (check SSH/network)."
            return 1
        fi
    fi
}

# Fetch upstream refs without touching the working tree or active branch.
ecotype_fetch() {
    local fetched=0
    if _ecotype_git remote get-url origin >/dev/null 2>&1; then
        if GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10" _ecotype_git fetch origin --prune >/dev/null 2>&1; then
            ui_ok "Fetched latest Heartwood refs from origin."
            fetched=1
        else
            ui_warn "Could not reach origin (offline or SSH key unavailable)."
        fi
    fi
    if _ecotype_git remote get-url gitea >/dev/null 2>&1; then
        if _ecotype_git fetch gitea --prune >/dev/null 2>&1; then
            ui_ok "Fetched latest refs from local Gitea."
            fetched=1
        fi
    fi
    if [ "$fetched" -eq 0 ]; then
        ui_warn "No remotes fetched; showing local git refs."
    fi
}

# Show diff between upstream Heartwood trunk and current ecotype (whole summary or single path).
ecotype_diff() {
    local target_path="${1:-}"
    local upstream
    upstream="$(ecotype_upstream_ref)"

    if ! _ecotype_git rev-parse --verify "$upstream" >/dev/null 2>&1; then
        ui_err "Upstream trunk ref '${upstream}' not found."
        return 1
    fi

    if [ -n "$target_path" ]; then
        if [[ "$target_path" == *".."* || "$target_path" == /* ]]; then
            ui_err "Invalid path: '${target_path}'"
            return 1
        fi
        local out
        out=$(_ecotype_git diff --no-color "${upstream}...HEAD" -- "$target_path" 2>/dev/null || true)
        if [ -z "$out" ]; then
            out=$(_ecotype_git diff --no-color "${upstream}..HEAD" -- "$target_path" 2>/dev/null || true)
        fi
        if [ -z "$out" ]; then
            echo "(No diff between '${upstream}' and HEAD for '${target_path}')"
        else
            printf '%s\n' "$out"
        fi
        return 0
    fi

    echo "═══ Heartwood vs Ecotype Diff (${upstream}...HEAD) ═══"
    _ecotype_git diff --stat --no-color "${upstream}...HEAD" 2>/dev/null || true
}
