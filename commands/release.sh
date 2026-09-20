#!/bin/bash
# ── George: Sovereign GitFlow Release Engine (2026) ───────────────────
# DESC: Promotes tested deliverables from 'develop' into permanent 'main'
# Usage: /release <version> [summary]
# Enforces Inviolable Landmarks:
#   - The Plumb: All 66 test suites must be 100% green before release.
#   - Branch Guard: Safely unlocks ALLOW_RELEASE_PUSH=1 for canon promotion.
#   - The Trowel: Tags release and syncs both local and sovereign forge.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/git.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/journal.sh" 2>/dev/null || true

cmd_release() {
    local args="$1"
    local workdir="${2:-$LODGE_DIR}"

    local version="${args%% *}"
    local summary="${args#"$version"}"
    summary="${summary#"${summary%%[![:space:]]*}"}"

    if [ -z "$version" ]; then
        ui_err "Usage: /release <version> [summary]"
        ui_info "Example: /release 1.0.0 'First sovereign modernized release'"
        return 1
    fi

    # Strip leading 'v' if provided for consistency
    version="${version#v}"
    local tag_name="v${version}"
    [ -z "$summary" ] && summary="Release ${tag_name}"

    ui_section "George Sovereign Release: ${tag_name}"
    ui_step "First Degree: Verifying repository cleanliness and branch topology..."

    local curr_branch
    curr_branch=$(git -C "$workdir" branch --show-current 2>/dev/null || echo "HEAD")

    # Check for uncommitted working tree changes
    if [ -n "$(git -C "$workdir" status --porcelain 2>/dev/null)" ]; then
        ui_err "Working tree has uncommitted modifications. Commit or stash them before releasing."
        return 1
    fi

    # Ensure develop branch exists
    if ! git -C "$workdir" rev-parse --verify develop &>/dev/null; then
        ui_err "GitFlow 'develop' branch does not exist."
        return 1
    fi

    # Ensure main branch exists
    if ! git -C "$workdir" rev-parse --verify main &>/dev/null; then
        ui_err "Canon 'main' branch does not exist."
        return 1
    fi

    ui_step "Second Degree: Executing pre-release test harness (The Plumb)..."
    ui_dim "Running all test suites on develop..."

    # Temporarily switch to develop to run tests
    git -C "$workdir" checkout develop >/dev/null 2>&1
    local test_out
    test_out=$(bash "$workdir/tests/run_all.sh" 2>&1)
    local test_rc=$?

    if [ "$test_rc" -ne 0 ]; then
        ui_err "Release aborted: Test harness failed with exit code $test_rc."
        echo "$test_out" | tail -n 15
        [ "$curr_branch" != "develop" ] && git -C "$workdir" checkout "$curr_branch" >/dev/null 2>&1
        return 1
    fi
    ui_ok "All test suites passed 100% green."

    ui_step "Third Degree: Promoting 'develop' into 'main' with release protection bypass..."

    # Checkout main and merge develop
    git -C "$workdir" checkout main >/dev/null 2>&1
    local merge_out
    merge_out=$(git -C "$workdir" merge --no-ff -m "chore(release): ${tag_name} — ${summary}" develop 2>&1)
    local merge_rc=$?

    if [ "$merge_rc" -ne 0 ]; then
        ui_err "Merge conflict while promoting develop into main: $merge_out"
        git -C "$workdir" merge --abort >/dev/null 2>&1 || true
        [ "$curr_branch" != "main" ] && git -C "$workdir" checkout "$curr_branch" >/dev/null 2>&1
        return 1
    fi

    # Create annotated tag
    git -C "$workdir" tag -a "$tag_name" -m "${summary}" 2>/dev/null || git -C "$workdir" tag -f "$tag_name"

    ui_ok "Merged 'develop' into 'main' and tagged '${tag_name}'."

    # Push to remotes under ALLOW_RELEASE_PUSH=1
    export ALLOW_RELEASE_PUSH=1
    if git -C "$workdir" remote get-url gitea &>/dev/null; then
        ui_step "Synchronizing release to Sovereign Gitea Forge..."
        git -C "$workdir" push gitea main "$tag_name" >/dev/null 2>&1 || ui_warn "Could not push to gitea remote."
    fi
    if git -C "$workdir" remote get-url origin &>/dev/null; then
        ui_step "Synchronizing release to origin..."
        git -C "$workdir" push origin main "$tag_name" >/dev/null 2>&1 || ui_warn "Could not push to origin remote."
    fi
    unset ALLOW_RELEASE_PUSH

    # If develop needs syncing back (or curr_branch)
    if [ "$curr_branch" != "main" ]; then
        git -C "$workdir" checkout "$curr_branch" >/dev/null 2>&1
        # If the original branch was refactor/modernization, merge develop or main into it to keep it aligned
        if [ "$curr_branch" != "develop" ]; then
            git -C "$workdir" merge --no-edit main >/dev/null 2>&1 || true
            ui_info "Synchronized active working branch '$curr_branch' with released 'main'."
        fi
    fi

    # Journal reflection
    journal_write "reflection" "Release ${tag_name} completed: ${summary}. Promoted develop into main and tagged." 2>/dev/null || true

    ui_ok "Sovereign Release ${tag_name} completed successfully!"
    return 0
}
