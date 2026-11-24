#!/usr/bin/env bash
# ── scripts/infra/sync_guild_gitea.sh ───────────────────────────────────────
# Mirrors the Blue Lodge Guild catalog (blue-lodge-guild) and its cataloged
# external module repos from GitHub into the node's local Gitea forge.
# Handles both direct local Gitea (Docker/bare-metal) and in-cluster K8s Gitea
# (*.svc.cluster.local via kubectl exec deploy/george-web) cleanly with full
# non-shallow history so Gitea never rejects pushes.
#
# Usage:
#   ./scripts/infra/sync_guild_gitea.sh [--org <github_org>] [--only <repo1,repo2>]

set -euo pipefail

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"
K8S_NS="${K8S_NAMESPACE:-blue-lodge}"

GH_ORG=""
ONLY_REPOS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --org)  GH_ORG="${2:-}"; shift 2 ;;
        --only) ONLY_REPOS="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done

_info() { printf "\033[1;36m[guild-sync]\033[0m %s\n" "$1"; }
_ok()   { printf "\033[1;32m[✓]\033[0m %s\n" "$1"; }
_warn() { printf "\033[1;33m[!]\033[0m %s\n" "$1" >&2; }
_err()  { printf "\033[1;31m[✗]\033[0m %s\n" "$1" >&2; exit 1; }

# 1. Derive GitHub org from origin remote if not specified
if [ -z "$GH_ORG" ]; then
    _ourl=$(git -c safe.directory='*' -C "$LODGE_DIR" remote get-url origin 2>/dev/null || true)
    if [[ "$_ourl" =~ github\.com[:/]([^/]+)/blue-lodge(\.git)?$ ]]; then
        GH_ORG="${BASH_REMATCH[1]}"
    else
        GH_ORG="dabe-19"
    fi
fi

# 2. Derive local Gitea URL, owner, and token from gitea remote or lodge.conf
GITEA_REMOTE=$(git -c safe.directory='*' -C "$LODGE_DIR" remote get-url gitea 2>/dev/null || true)
[ -z "$GITEA_REMOTE" ] && _err "No 'gitea' git remote configured in $LODGE_DIR."

if [[ "$GITEA_REMOTE" =~ ^(https?://)([^:@]+):([^@]+)@([^/]+)/([^/]+)/blue-lodge(\.git)?$ ]]; then
    G_PROTO="${BASH_REMATCH[1]}"
    G_USER="${BASH_REMATCH[2]}"
    G_TOKEN="${BASH_REMATCH[3]}"
    G_HOST="${BASH_REMATCH[4]}"
    G_OWNER="${BASH_REMATCH[5]}"
    G_BASE_NOAUTH="${G_PROTO}${G_HOST}"
    G_BASE_AUTH="${G_PROTO}${G_USER}:${G_TOKEN}@${G_HOST}/${G_OWNER}"
else
    _err "Could not parse credentials/host from gitea remote: $GITEA_REMOTE"
fi

USE_K8S=0
if [[ "$G_HOST" == *".svc.cluster.local"* ]] && [ ! -f "/.dockerenv" ] && command -v kubectl >/dev/null 2>&1; then
    USE_K8S=1
fi

_gitea_ensure_repo() {
    local rname="$1"
    local cmd="code=\$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: token ${G_TOKEN}' '${G_BASE_NOAUTH}/api/v1/repos/${G_OWNER}/${rname}')
if [ \"\$code\" != '200' ]; then
    curl -sf -X POST -H 'Authorization: token ${G_TOKEN}' -H 'Content-Type: application/json' \
        -d '{\"name\":\"${rname}\",\"private\":false,\"auto_init\":false}' \
        '${G_BASE_NOAUTH}/api/v1/user/repos' >/dev/null
    echo 'created'
else
    echo 'exists'
fi"
    if [ "$USE_K8S" -eq 1 ]; then
        kubectl -n "$K8S_NS" exec deploy/george-web -- bash -c "$cmd"
    else
        bash -c "$cmd"
    fi
}

_gitea_push_mirror() {
    local rname="$1"
    local stage_rel=".george/tmp/guild_mirror_${rname}"
    if [ "$USE_K8S" -eq 1 ]; then
        kubectl -n "$K8S_NS" exec deploy/george-web -- git -c safe.directory='*' -C "/workspace/${stage_rel}" \
            push --force "${G_BASE_AUTH}/${rname}.git" HEAD:refs/heads/main >/dev/null
    else
        git -c safe.directory='*' -C "${LODGE_DIR}/${stage_rel}" \
            push --force "${G_BASE_AUTH}/${rname}.git" HEAD:refs/heads/main >/dev/null
    fi
}

_clone_from_github() {
    local rname="$1" dest="$2"
    rm -rf "$dest"
    if git clone --quiet "git@github.com:${GH_ORG}/${rname}.git" "$dest" 2>/dev/null; then
        return 0
    fi
    if GIT_TERMINAL_PROMPT=0 git clone --quiet "https://github.com/${GH_ORG}/${rname}.git" "$dest" 2>/dev/null; then
        return 0
    fi
    return 1
}

mkdir -p "$GEORGE_DIR/tmp"
trap 'rm -rf "$GEORGE_DIR/tmp"/guild_mirror_* 2>/dev/null || true' EXIT

# 3. Always mirror blue-lodge-guild first so we can read its catalog.json
REPOS=("blue-lodge-guild")
GUILD_STAGE="$GEORGE_DIR/tmp/guild_mirror_blue-lodge-guild"
_info "Cloning blue-lodge-guild from GitHub (${GH_ORG})..."
_clone_from_github "blue-lodge-guild" "$GUILD_STAGE" || _err "Failed to clone ${GH_ORG}/blue-lodge-guild from GitHub."

if [ -n "$ONLY_REPOS" ]; then
    IFS=',' read -r -a EXTRA <<< "$ONLY_REPOS"
    for r in "${EXTRA[@]}"; do
        [ -n "$r" ] && [ "$r" != "blue-lodge-guild" ] && REPOS+=("$r")
    done
elif [ -f "$GUILD_STAGE/catalog.json" ]; then
    while IFS= read -r mrepo; do
        [ -n "$mrepo" ] && REPOS+=("$mrepo")
    done < <(jq -r '.modules[]?.id // empty | "mod-" + .' "$GUILD_STAGE/catalog.json" 2>/dev/null || true)
fi

for rname in "${REPOS[@]}"; do
    stage="$GEORGE_DIR/tmp/guild_mirror_${rname}"
    if [ ! -d "$stage/.git" ]; then
        _info "Cloning ${rname} from GitHub (${GH_ORG})..."
        if ! _clone_from_github "$rname" "$stage"; then
            _warn "Skipping ${rname}: could not clone from GitHub (${GH_ORG}/${rname})."
            continue
        fi
    fi
    status=$(_gitea_ensure_repo "$rname")
    _gitea_push_mirror "$rname"
    sha=$(git -C "$stage" rev-parse --short HEAD 2>/dev/null || echo "?")
    _ok "Mirrored ${rname} @ ${sha} -> local Gitea ${G_OWNER}/${rname} (${status})"
done
