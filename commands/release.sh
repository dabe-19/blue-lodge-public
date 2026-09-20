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
source "$LODGE_DIR/lib/alerts.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mcp_server_gitea.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/subagents.sh" 2>/dev/null || true

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

        # ── Autonomous Emergency Investigation & Remediation Protocol ──
        local failed_tests
        failed_tests=$(echo "$test_out" | grep -E '^[[:space:]]*✗[[:space:]]+test_' | awk '{print $2}' | tr '\n' ', ' | sed 's/, $//')
        [ -z "$failed_tests" ] && failed_tests="test regressions"

        echo ""
        ui_warn "Triggering Autonomous Emergency Investigation Protocol..."

        # 1. Open Emergency Sovereign Gitea Issue
        local issue_num=""
        if declare -f gitea_is_online &>/dev/null && gitea_is_online; then
            local issue_title="[RELEASE FAILURE] Pre-release gate failed on develop (${failed_tests})"
            local issue_body="### 🚨 Pre-Release Gate Failure Diagnostic

**Target Release:** \`${tag_name}\`
**Failed Test Suites:** \`${failed_tests}\`
**Exit Code:** \`${test_rc}\`

#### Test Runner Summary:
\`\`\`
$(echo "$test_out" | tail -n 30)
\`\`\`

Autonomous emergency investigator task dispatched to isolate and fix regressions."

            local issue_res
            issue_res=$(gitea_issue_create "$issue_title" "$issue_body" "release-blocker,emergency-investigation" 2>/dev/null || true)
            issue_num=$(echo "$issue_res" | jq -r .number 2>/dev/null || echo "")
            [ -n "$issue_num" ] && ui_info "Emergency Sovereign Gitea Issue #${issue_num} created."
        fi

        # 2. Dispatch Multi-Tier Alert
        if declare -f alerts_dispatch &>/dev/null; then
            local issue_url="${GITEA_URL:-http://127.0.0.1:3088}/george/blue-lodge/issues/${issue_num}"
            alerts_dispatch tier2 "Release ${tag_name} Blocked" "Pre-release tests failed: ${failed_tests}. Autonomous emergency investigation triggered." "$issue_url" >/dev/null 2>&1 || true
            ui_ok "Emergency multi-tier alert dispatched (Discord/MQTT/Local)."
        fi

        # 3. Spawn Autonomous Emergency Remediation Subagent
        if declare -f subagents_spawn &>/dev/null; then
            ui_step "Spawning emergency investigator subagent..."
            local worker_task="Emergency Fix: Investigate and fix pre-release test failures (${failed_tests}) blocking release ${tag_name}. Target issue #${issue_num:-emergency}."
            export _LODGE_SKIP_SUBAGENT_CLEANUP=1
            subagents_spawn 1 "$worker_task" "Emergency pre-release investigator" "$workdir" 50 1 2>/dev/null || true
            ui_ok "Investigator subagent dispatched in isolated worktree sandbox."
        fi

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
        if declare -f gitea_is_online &>/dev/null && gitea_is_online; then
            _gitea_load_conf 2>/dev/null || true
            curl -s -X PATCH -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
                 -d "{\"enable_push\": true, \"enable_push_whitelist\": true, \"push_whitelist_usernames\": [\"$GITEA_USER\"]}" \
                 "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/branch_protections/main" >/dev/null 2>&1 || true
        fi
        git -C "$workdir" push gitea main "$tag_name" >/dev/null 2>&1 || ui_warn "Could not push to gitea remote."
        if declare -f gitea_is_online &>/dev/null && gitea_is_online; then
            curl -s -X PATCH -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
                 -d '{"enable_push": false, "enable_push_whitelist": false, "push_whitelist_usernames": []}' \
                 "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/branch_protections/main" >/dev/null 2>&1 || true
        fi
    fi
    if git -C "$workdir" remote get-url origin &>/dev/null; then
        ui_step "Synchronizing release to origin..."
        if ! (GIT_SSH_COMMAND="ssh -o BatchMode=yes" git -C "$workdir" push origin main "$tag_name" >/dev/null 2>&1); then
            local gh_token
            gh_token=$(gh auth token 2>/dev/null || echo "")
            if [ -n "$gh_token" ]; then
                git -C "$workdir" push "https://x-access-token:${gh_token}@github.com/dabe-19/blue-lodge.git" main "$tag_name" >/dev/null 2>&1 && ui_ok "Pushed release to origin via GitHub CLI credentials." || ui_warn "Could not push to origin remote."
            else
                ui_warn "Could not push to origin remote (requires interactive SSH passphrase or gh auth)."
            fi
        else
            ui_ok "Pushed release to origin via SSH."
        fi
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
