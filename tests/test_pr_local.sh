#!/bin/bash
# ── Tests: Local PR Subsystem (lib/agents/pr.sh) ─────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh"
source "$LODGE_DIR/lib/tools/git.sh"
source "$LODGE_DIR/lib/agents/pr.sh"

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

describe "pr_audit write-scope denylist and test gate"
    it "should fail pr_audit when candidate branch modifies denylisted core file" && {
        _setup_pr_env
        git checkout -b "candidate/forbidden" >/dev/null 2>&1
        mkdir -p lib/core
        echo "# forbidden mutation" > lib/core/react.sh
        git add lib/core/react.sh
        git commit -m "feat: mutate core react loop" >/dev/null 2>&1
        git checkout develop >/dev/null 2>&1

        pr_create "candidate/forbidden" "Mutate Core Loop" "Testing denylist" "develop" 1 >/dev/null
        audit_ec=0
        pr_audit "PR-001" >/dev/null 2>&1 || audit_ec=$?
        assert_eq "$audit_ec" "1" "pr_audit must fail on denylisted path"
        status=$(jq -r .status "$PR_DIR/PR-001.json")
        verdict=$(jq -r .audit_verdict "$PR_DIR/PR-001.json")
        assert_eq "$status" "REJECTED" "Status must be REJECTED"
        assert_eq "$verdict" "SCOPE_DENYLIST" "Audit verdict must be SCOPE_DENYLIST"
        _teardown_pr_env
    }

    it "should fail pr_audit when test runner exits non-zero" && {
        _setup_pr_env
        mkdir -p tests
        cat > tests/run.sh << 'EOF'
#!/bin/bash
echo "1 failed"
exit 1
EOF
        chmod +x tests/run.sh
        git add tests/run.sh
        git commit -m "chore: add failing test runner" >/dev/null 2>&1

        git checkout candidate/speedup >/dev/null 2>&1
        git merge develop -m "sync develop" >/dev/null 2>&1
        git checkout develop >/dev/null 2>&1

        pr_create "candidate/speedup" "Speedup With Failing Test" "Benchmark" "develop" 1 >/dev/null
        audit_ec=0
        pr_audit "PR-001" >/dev/null 2>&1 || audit_ec=$?
        assert_eq "$audit_ec" "1" "pr_audit must fail when tests/run.sh exits non-zero"
        status=$(jq -r .status "$PR_DIR/PR-001.json")
        verdict=$(jq -r .audit_verdict "$PR_DIR/PR-001.json")
        assert_eq "$status" "REJECTED" "Status must be REJECTED"
        assert_eq "$verdict" "TEST_FAILURES" "Audit verdict must be TEST_FAILURES"
        _teardown_pr_env
    }

describe "pr_review and 1-reviewer acceptance gate in pr_auto_evaluate"
    it "should block PR_REQUIRE_REVIEW=1 pr_accept without reviewer approval and auto-merge after pr_review approves" && {
        _setup_pr_env
        mkdir -p tests
        cat > tests/run.sh << 'EOF'
#!/bin/bash
echo "All tests passed"
exit 0
EOF
        chmod +x tests/run.sh
        git add tests/run.sh
        git commit -m "chore: add passing test runner" >/dev/null 2>&1

        git checkout candidate/speedup >/dev/null 2>&1
        git merge develop -m "sync develop" >/dev/null 2>&1
        git checkout develop >/dev/null 2>&1

        pr_create "candidate/speedup" "Reviewed Speedup" "Clean change" "develop" 1 >/dev/null

        # Without review, PR_REQUIRE_REVIEW=1 pr_accept must fail
        gate_ec=0
        PR_REQUIRE_REVIEW=1 pr_accept "PR-001" "merge" >/dev/null 2>&1 || gate_ec=$?
        assert_eq "$gate_ec" "1" "PR_REQUIRE_REVIEW=1 pr_accept must reject unreviewed PR"

        # pr_auto_evaluate runs pr_audit -> pr_review -> pr_has_reviewer_acceptance -> pr_accept
        eval_ec=0
        pr_auto_evaluate "PR-001" >/dev/null 2>&1 || eval_ec=$?
        assert_eq "$eval_ec" "0" "pr_auto_evaluate must succeed after audit + review"

        status=$(jq -r .status "$PR_DIR/PR-001.json")
        review_verdict=$(jq -r .review_verdict "$PR_DIR/PR-001.json")
        assert_eq "$review_verdict" "APPROVED" "Reviewer verdict must be APPROVED"
        assert_eq "$status" "MERGED" "PR must be MERGED after passing audit and review"
        _teardown_pr_env
    }

test_end

