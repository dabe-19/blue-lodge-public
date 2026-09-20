#!/bin/bash
# ── Tests: Local PR Subsystem (lib/pr.sh) ─────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/git.sh"
source "$LODGE_DIR/lib/pr.sh"

TMPDIR_PR=""

_setup_pr_env() {
    TMPDIR_PR=$(test_tmpdir)
    export LODGE_DIR="$TMPDIR_PR"
    export GEORGE_DIR="$TMPDIR_PR/.george"
    export PR_DIR="$GEORGE_DIR/pulls"

    mkdir -p "$PR_DIR"
    cd "$TMPDIR_PR"
    git init >/dev/null 2>&1
    git config user.name "George Test"
    git config user.email "george@blue-lodge.local"

    echo "root file" > README.md
    git add README.md
    git commit -m "chore: root init" >/dev/null 2>&1

    # Create develop branch
    git branch develop HEAD
    git checkout develop >/dev/null 2>&1

    # Create candidate branch
    git checkout -b "candidate/speedup" >/dev/null 2>&1
    echo "fast algorithm" > algo.txt
    git add algo.txt
    git commit -m "perf: 10x faster hash lookup" >/dev/null 2>&1

    git checkout develop >/dev/null 2>&1
}

_teardown_pr_env() {
    cd /tmp 2>/dev/null
    rm -rf "$TMPDIR_PR"
}

test_start "Local Pull Request Subsystem"

describe "pr_init and pr_next_id"
    it "should generate sequential PR identifiers" && {
        _setup_pr_env
        id1=$(pr_next_id)
        assert_eq "$id1" "PR-001" "First PR id must be PR-001"
        touch "$PR_DIR/PR-001.json"
        id2=$(pr_next_id)
        assert_eq "$id2" "PR-002" "Second PR id must be PR-002"
        _teardown_pr_env
    }

describe "pr_create (local mode)"
    it "should create PR metadata JSON and markdown dossier" && {
        _setup_pr_env
        pr_out=$(pr_create "candidate/speedup" "Hash Speedup Optimization" "Benchmark shows 10x improvement" "develop" 1)
        pr_id=$(echo "$pr_out" | tail -n 1)
        assert_eq "$pr_id" "PR-001" "Created PR ID should be PR-001"
        assert_file_exists "$PR_DIR/PR-001.json" "Metadata JSON must exist"
        assert_file_exists "$PR_DIR/PR-001.dossier.md" "Dossier MD must exist"

        status=$(jq -r .status "$PR_DIR/PR-001.json")
        assert_eq "$status" "PROPOSED" "Initial status must be PROPOSED"

        src=$(jq -r .source_branch "$PR_DIR/PR-001.json")
        assert_eq "$src" "candidate/speedup" "Source branch must match"
        _teardown_pr_env
    }

describe "pr_show and pr_diff"
    it "should output markdown dossier and diff" && {
        _setup_pr_env
        pr_create "candidate/speedup" "Hash Speedup Optimization" "Benchmark shows 10x improvement" "develop" 1 >/dev/null
        dossier_out=$(pr_show "PR-001")
        assert_contains "$dossier_out" "Hash Speedup Optimization" "Dossier must contain title"
        assert_contains "$dossier_out" "Benchmark shows 10x improvement" "Dossier must contain rationale"

        diff_out=$(pr_diff "PR-001")
        assert_contains "$diff_out" "fast algorithm" "Diff must contain added content"
        _teardown_pr_env
    }

describe "pr_reject"
    it "should update PR status to REJECTED with reason" && {
        _setup_pr_env
        pr_create "candidate/speedup" "Hash Speedup Optimization" "Benchmark" "develop" 1 >/dev/null
        pr_reject "PR-001" "Benchmark results unverified" >/dev/null
        status=$(jq -r .status "$PR_DIR/PR-001.json")
        reason=$(jq -r .rejection_reason "$PR_DIR/PR-001.json")
        assert_eq "$status" "REJECTED" "Status must be REJECTED"
        assert_eq "$reason" "Benchmark results unverified" "Reason must be recorded"
        _teardown_pr_env
    }

describe "pr_accept"
    it "should merge candidate branch into target branch develop" && {
        _setup_pr_env
        pr_create "candidate/speedup" "Hash Speedup Optimization" "Benchmark" "develop" 1 >/dev/null
        pr_accept "PR-001" "merge" >/dev/null
        status=$(jq -r .status "$PR_DIR/PR-001.json")
        assert_eq "$status" "MERGED" "Status must be MERGED"

        # Verify algo.txt exists in develop branch
        git -C "$LODGE_DIR" checkout develop >/dev/null 2>&1
        assert_file_exists "$LODGE_DIR/algo.txt" "Merged file must exist in develop"
        _teardown_pr_env
    }

test_end
