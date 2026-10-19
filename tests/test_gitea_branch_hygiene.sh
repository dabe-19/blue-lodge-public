#!/bin/bash
# ── Tests: Gitea Branch Hygiene & Transient State Ignore ──────────────

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/tools/mcp_server_gitea.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agents/subagents.sh" 2>/dev/null || true

TEST_TMP=$(mktemp -d /tmp/george-branch-hygiene-test-XXXXXX)
export GEORGE_DIR="$TEST_TMP/.george"
export GEORGE_CONFIG_DIR="$GEORGE_DIR"
export LODGE_TEST_MODE=1
export _LODGE_TESTING=1

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

test_start "Gitea Branch Hygiene & Sandbox State Ignore"

describe "Transient State Git Ignore"

it "ignores .pid, .phase, .pr_issued, task_meta.json, and trajectory.log in git" && {
    ignored_pid=$(git -C "$LODGE_DIR" check-ignore .pid 2>/dev/null || echo "")
    ignored_phase=$(git -C "$LODGE_DIR" check-ignore .phase 2>/dev/null || echo "")
    ignored_meta=$(git -C "$LODGE_DIR" check-ignore task_meta.json 2>/dev/null || echo "")
    ignored_pr=$(git -C "$LODGE_DIR" check-ignore .pr_issued 2>/dev/null || echo "")
    ignored_traj=$(git -C "$LODGE_DIR" check-ignore trajectory.log 2>/dev/null || echo "")

    assert_not_empty "$ignored_pid" ".pid must be ignored"
    assert_not_empty "$ignored_phase" ".phase must be ignored"
    assert_not_empty "$ignored_meta" "task_meta.json must be ignored"
    assert_not_empty "$ignored_pr" ".pr_issued must be ignored"
    assert_not_empty "$ignored_traj" "trajectory.log must be ignored"
}

describe "Sandbox Git Cleanliness"

it "keeps git status clean when only transient task tracking files exist" && {
    # Create an isolated temporary git repository to verify sandbox behavior
    sandbox_repo="$TEST_TMP/mock_repo"
    mkdir -p "$sandbox_repo"
    git -C "$sandbox_repo" init -q -b develop
    git -C "$sandbox_repo" config user.name "George Test"
    git -C "$sandbox_repo" config user.email "test@bluelodge.local"

    # Copy repo .gitignore
    cp "$LODGE_DIR/.gitignore" "$sandbox_repo/.gitignore"
    echo "# Base repo" > "$sandbox_repo/README.md"
    git -C "$sandbox_repo" add .gitignore README.md
    git -C "$sandbox_repo" commit -q -m "Initial commit"

    # Simulate subagent worktree initialization
    sub_dir="$sandbox_repo/.sandboxes/sub_test_1"
    git -C "$sandbox_repo" worktree add -q -b "subagent/sub_test_1" "$sub_dir" develop

    # Write transient metadata files into subagent worktree
    echo "12345" > "$sub_dir/.pid"
    echo "Active" > "$sub_dir/.phase"
    cat > "$sub_dir/task_meta.json" << 'EOF'
{
  "id": "sub_test_1",
  "type": "subagent",
  "tier": "2",
  "objective": "Test objective"
}
EOF
    touch "$sub_dir/.done" "$sub_dir/.pr_issued" "$sub_dir/trajectory.log"

    # Verify status is completely clean
    st_out=$(git -C "$sub_dir" status --porcelain 2>/dev/null || echo "")
    assert_empty "$st_out" "Worktree must show 0 untracked or modified files for transient state"

    # Clean up worktree
    git -C "$sandbox_repo" worktree remove --force "$sub_dir" 2>/dev/null || true
}

describe "Protected Branch Deletion Guard"

it "prevents deleting develop, main, or master branches" && {
    out_dev=$(gitea_branch_delete "develop" 2>&1)
    status_dev=$?
    assert_neq "$status_dev" 0 "Must forbid deleting develop"
    assert_contains "$out_dev" "Protected branch"

    out_main=$(gitea_branch_delete "main" 2>&1)
    status_main=$?
    assert_neq "$status_main" 0 "Must forbid deleting main"
    assert_contains "$out_main" "Protected branch"

    out_master=$(gitea_branch_delete "master" 2>&1)
    status_master=$?
    assert_neq "$status_master" 0 "Must forbid deleting master"
    assert_contains "$out_master" "Protected branch"
}

describe "Branch Deletion & Pruning Mocking in Test Mode"

it "mocks branch deletion cleanly without live forge mutations in test mode" && {
    del_res=$(gitea_branch_delete "subagent/mock_test_branch" 2>&1)
    assert_ok $? "Must exit 0 in test mode"
    assert_contains "$del_res" '"deleted":true'
}

it "mocks branch pruning cleanly in test mode" && {
    prune_res=$(gitea_prune_orphaned_branches 2>&1)
    assert_ok $? "Must exit 0 in test mode"
    assert_contains "$prune_res" '"pruned":0'
}
