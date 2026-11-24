#!/bin/bash
# DESC: Push to GitHub (current branch)
# Usage: /push [branch]

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh"
source "$LODGE_DIR/lib/comms/email.sh"

_cmd_push_reconcile_and_push() {
    local branch="$1"
    # ── Reconcile autonomous gitea/$branch updates before pushing ─────────
    if git remote get-url gitea &>/dev/null; then
        ui_step "Fetching latest refs from gitea/$branch and origin/$branch..."
        git fetch gitea "$branch" --quiet 2>/dev/null || true
        git fetch origin "$branch" --quiet 2>/dev/null || true

        local local_sha gitea_sha
        local_sha=$(git rev-parse "refs/heads/$branch" 2>/dev/null || echo "")
        gitea_sha=$(git rev-parse "refs/remotes/gitea/$branch" 2>/dev/null || echo "")

        if [ -n "$local_sha" ] && [ -n "$gitea_sha" ] && [ "$local_sha" != "$gitea_sha" ]; then
            if git merge-base --is-ancestor "$local_sha" "$gitea_sha" 2>/dev/null; then
                ui_step "Fast-forwarding local $branch to include autonomous gitea/$branch commits ($local_sha -> $gitea_sha)..."
                if ! git merge --ff-only "gitea/$branch"; then
                    ui_err "Cannot fast-forward local $branch to gitea/$branch (dirty working tree). Stash or commit local changes first."
                    return 1
                fi
            elif ! git merge-base --is-ancestor "$gitea_sha" "$local_sha" 2>/dev/null; then
                ui_step "Local $branch and gitea/$branch have both advanced; rebasing local commits onto gitea/$branch..."
                if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
                    ui_err "Uncommitted changes present while local $branch and gitea/$branch have diverged. Commit or stash first, then run 'lodge push'."
                    return 1
                fi
                if ! git rebase "gitea/$branch"; then
                    git rebase --abort 2>/dev/null || true
                    ui_err "Automatic rebase onto gitea/$branch encountered a conflict (aborted cleanly). Run 'git pull --rebase gitea $branch' to resolve before pushing."
                    return 1
                fi
                # Refresh OKF graph if rebase combined two branches with graph updates
                if [ -f "$LODGE_DIR/lib/knowledge/okf.sh" ]; then
                    LODGE_DIR="$LODGE_DIR" bash -c "source '$LODGE_DIR/lib/knowledge/okf.sh' && okf_sync --quiet" || true
                    if ! git diff --quiet "$LODGE_DIR/okf/blue_lodge_graph.jsonld" 2>/dev/null; then
                        git add "$LODGE_DIR/okf/blue_lodge_graph.jsonld"
                        git commit -m "chore(okf): refresh knowledge graph after gitea/$branch reconciliation"
                    fi
                fi
            fi
        fi

        ui_step "Pushing to gitea/$branch..."
        if ! LODGE_MIRRORING_PUSH=1 git push gitea "$branch"; then
            ui_err "Push to gitea/$branch failed — aborting origin push to prevent remote split-brain."
            return 1
        fi
    fi

    ui_step "Pushing verified $branch to origin/$branch..."
    if LODGE_MIRRORING_PUSH=1 SKIP_PREPUSH_TESTS=1 git push origin "$branch"; then
        ui_ok "Synchronized local $branch, gitea/$branch, and origin/$branch ($(git rev-parse --short HEAD))"
    else
        ui_err "Push to origin/$branch failed"
        return 1
    fi
}

cmd_push() {
    local branch="${1:-}"
    local workdir="${2:-.}"
    
    cd "$workdir"
    
    if [ -z "$branch" ]; then
        branch=$(git branch --show-current 2>/dev/null)
    fi
    
    if [ -z "$branch" ]; then
        ui_err "Not a git repo or no branch detected"
        return 1
    fi

    # ── GitHub push guard: require George key only when using github.com-george or no operator SSH key exists ──
    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null || echo "")
    if [[ "$remote_url" == *"github.com-george"* ]] || { [ ! -f "$HOME/.ssh/id_ed25519" ] && [ -z "${SSH_AUTH_SOCK:-}" ]; }; then
        if declare -f github_push_guard &>/dev/null; then
            if ! github_push_guard "$remote_url"; then
                return 1
            fi
        fi
    fi

    # ── Acquire repository git sync lock so background gitea_sync never races lodge push ──
    local git_lock_dir="$LODGE_DIR/.george/locks"
    mkdir -p "$git_lock_dir" 2>/dev/null || true
    local git_lock_fd rc=0
    exec {git_lock_fd}>"$git_lock_dir/git_repo.lock"
    if command -v flock &>/dev/null; then
        if ! flock -w 30 "$git_lock_fd"; then
            eval "exec ${git_lock_fd}>&-"
            ui_err "Another git sync/push holds $git_lock_dir/git_repo.lock; retry in a moment."
            return 1
        fi
    fi

    _cmd_push_reconcile_and_push "$branch" || rc=$?
    eval "exec ${git_lock_fd}>&-"
    return "$rc"
}
