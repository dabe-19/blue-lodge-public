#!/bin/bash
# ── Tests: GitFlow Protection (lib/git.sh) ────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/git.sh"

TMPDIR_FLOW=""

_setup_flow() {
    TMPDIR_FLOW=$(test_tmpdir)
    repo_dir="$TMPDIR_FLOW/repo"
    mkdir -p "$repo_dir"
    cd "$repo_dir"
    git init >/dev/null 2>&1
    git config user.name "Tester"
    git config user.email "tester@blue-lodge.local"
    echo "initial" > file.txt
    git add file.txt
    git commit -m "chore: initial commit" >/dev/null 2>&1
}

_teardown_flow() {
    cd /tmp 2>/dev/null
    rm -rf "$TMPDIR_FLOW"
}

test_start "GitFlow & Branch Protection"

describe "gitflow_guard_check"
    it "should allow valid integration branch 'develop'" && {
        _setup_flow
        gitflow_guard_check "develop"
        assert_ok $? "develop should be allowed"
        _teardown_flow
    }

    it "should allow candidate and feature branches" && {
        _setup_flow
        gitflow_guard_check "candidate/my-opt"
        assert_ok $? "candidate branch should be allowed"
        gitflow_guard_check "feature/new-feature"
        assert_ok $? "feature branch should be allowed"
        gitflow_guard_check "hotfix/urgent-patch"
        assert_ok $? "hotfix branch should be allowed"
        _teardown_flow
    }

    it "should strictly reject direct targeting of 'main'" && {
        _setup_flow
        gitflow_guard_check "main" >/dev/null 2>&1
        assert_fail $? "direct main targeting must fail"
        _teardown_flow
    }

    it "should strictly reject direct targeting of 'master'" && {
        _setup_flow
        gitflow_guard_check "master" >/dev/null 2>&1
        assert_fail $? "direct master targeting must fail"
        _teardown_flow
    }

describe "gitflow_init"
    it "should create develop branch if not present and install pre-push hook" && {
        _setup_flow
        gitflow_init "$repo_dir" >/dev/null 2>&1
        assert_ok $? "gitflow_init should succeed"
        git -C "$repo_dir" rev-parse --verify develop >/dev/null 2>&1
        assert_ok $? "develop branch must exist"
        assert_file_exists "$repo_dir/.git/hooks/pre-push" "pre-push hook must be installed"
        _teardown_flow
    }

describe "pre-push hook"
    it "should block direct pushes to main/master" && {
        _setup_flow
        gitflow_init "$repo_dir" >/dev/null 2>&1
        hook_path="$repo_dir/.git/hooks/pre-push"
        hook_out=$(echo "refs/heads/main 1234 refs/heads/main 0000" | bash "$hook_path" origin "git@example.com:repo.git" 2>&1 || true)
        assert_contains "$hook_out" "blocked by Lodge GitFlow" "Hook must reject push to main"

        echo "refs/heads/develop 1234 refs/heads/develop 0000" | bash "$hook_path" origin "git@example.com:repo.git" >/dev/null 2>&1
        assert_ok $? "Hook must allow pushing to develop"
        _teardown_flow
    }

test_end
