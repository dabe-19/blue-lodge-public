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

    it "should remediate a failing PR via pr_sweep and merge it on the next sweep cycle" && {
        _setup_pr_env
        mkdir -p tests
        cat > tests/run.sh << 'EOF'
#!/bin/bash
[ -f "fixed.flag" ] && exit 0
echo "regression: fixed.flag missing"
exit 1
EOF
        chmod +x tests/run.sh
        git add tests/run.sh
        git commit -m "chore: add conditional test runner" >/dev/null 2>&1

        git checkout candidate/speedup >/dev/null 2>&1
        git merge develop -m "sync develop" >/dev/null 2>&1
        git checkout develop >/dev/null 2>&1

        pr_create "candidate/speedup" "Broken Speedup PR" "Needs remediation" "develop" 1 >/dev/null

        # Mock subagents_spawn to verify target branch & existing PR args and commit the fix onto SUBAGENT_TARGET_BRANCH
        subagents_spawn() {
            local tier="$1" obj="$2" ctx="$3" wd="$4" turns="$5" async="$6"
            echo "${SUBAGENT_TARGET_BRANCH}|${SUBAGENT_EXISTING_PR}|${turns}|${async}" > "$PR_DIR/spawned.meta"
            (
                git -C "$LODGE_DIR" checkout "$SUBAGENT_TARGET_BRANCH" >/dev/null 2>&1
                echo "1" > "$LODGE_DIR/fixed.flag"
                git -C "$LODGE_DIR" add fixed.flag
                git -C "$LODGE_DIR" commit -m "fix(remediation): satisfy test runner" >/dev/null 2>&1
                git -C "$LODGE_DIR" checkout develop >/dev/null 2>&1
            )
            return 0
        }

        # Tick 1: pr_sweep fails audit, marks status REMEDIATING, and spawns remediation on candidate/speedup
        pr_sweep >/dev/null 2>&1 || true
        assert_file_exists "$PR_DIR/spawned.meta" "subagents_spawn must be invoked on failing PR"
        spawn_meta=$(cat "$PR_DIR/spawned.meta")
        assert_eq "$spawn_meta" "candidate/speedup|PR-001|50|1" "subagents_spawn must target candidate/speedup and PR-001"
        stat_t1=$(jq -r .status "$PR_DIR/PR-001.json")
        assert_eq "$stat_t1" "REMEDIATING" "PR status must transition to REMEDIATING after dispatching subagent"

        # Tick 2: pr_sweep re-evaluates REMEDIATING PR, passes audit + review, and merges into develop
        pr_sweep >/dev/null 2>&1
        stat_t2=$(jq -r .status "$PR_DIR/PR-001.json")
        assert_eq "$stat_t2" "MERGED" "Remediated PR must be MERGED on next pr_sweep cycle"
        git -C "$LODGE_DIR" checkout develop >/dev/null 2>&1
        assert_file_exists "$LODGE_DIR/fixed.flag" "Remediated fix must be merged into develop"
        unset -f subagents_spawn
        _teardown_pr_env
    }

    it "should block merge on REQUEST_CHANGES (even when followed by COMMENT), spawn remediation, and merge after fix commit" && {
        _setup_pr_env
        mkdir -p tests
        cat > tests/run.sh << 'EOF'
#!/bin/bash
exit 0
EOF
        chmod +x tests/run.sh
        git add tests/run.sh
        git commit -m "chore: add passing test runner" >/dev/null 2>&1

        git checkout candidate/speedup >/dev/null 2>&1
        git merge develop -m "sync develop" >/dev/null 2>&1
        git checkout develop >/dev/null 2>&1

        pr_create "candidate/speedup" "Needs Review Changes PR" "Test review rejection loop" "develop" 1 >/dev/null

        # Verify pr_record_review preserves REQUEST_CHANGES when followed by a supplementary COMMENT
        pr_record_review "PR-001" "REQUEST_CHANGES" "Primary defect: missing flock guard"
        pr_record_review "PR-001" "COMMENT" "Supplementary finding: redundant ticker. Verdict unchanged: **REQUEST_CHANGES**."
        rec_v=$(jq -r .verdict "$PR_DIR/PR-001.review.json")
        rec_c=$(jq -r .comment "$PR_DIR/PR-001.review.json")
        assert_eq "$rec_v" "REQUEST_CHANGES" "Supplementary COMMENT must not overwrite REQUEST_CHANGES verdict"
        assert_contains "$rec_c" "Primary defect: missing flock guard" "Primary comment must be preserved"
        assert_contains "$rec_c" "Supplementary finding" "Supplementary comment must be appended"
        rm -f "$PR_DIR/PR-001.review.json"

        # Verify _gitea_persist_local_pr_review and pr_record_review preserve APPROVED even when prose mentions REQUEST_CHANGES
        _gitea_persist_local_pr_review "PR-001" "APPROVED" "Prior REQUEST_CHANGES items are resolved. VERDICT: APPROVED" >/dev/null
        assert_file_exists "$PR_DIR/PR-001.review.json" "_gitea_persist_local_pr_review must write review.json when sourced"
        assert_eq "$(jq -r .verdict "$PR_DIR/PR-001.review.json")" "APPROVED" "APPROVED review mentioning REQUEST_CHANGES in prose must remain APPROVED"
        pr_has_reviewer_acceptance "PR-001"
        assert_eq "$?" "0" "pr_has_reviewer_acceptance must accept APPROVED review mentioning REQUEST_CHANGES in prose"
        rm -f "$PR_DIR/PR-001.review.json"

        # Mock react_run to emit REQUEST_CHANGES until review_fixed.txt is committed on the branch
        export _PR_FORCE_REACT_REVIEW=1
        react_run() {
            local prompt="$1" wt="$2" turns="$3" tier="$4" sess="$5"
            mkdir -p "$wt/.george/runs/$sess"
            if [ -f "$wt/review_fixed.txt" ]; then
                echo "All issues resolved. VERDICT: APPROVED" > "$wt/.george/runs/$sess/final_reply.md"
            else
                echo "Defect (REQUEST_CHANGES): concurrent writer race in telemetry_task_heartbeat. VERDICT: REQUEST_CHANGES" > "$wt/.george/runs/$sess/final_reply.md"
            fi
            return 0
        }

        subagents_spawn() {
            local tier="$1" obj="$2" ctx="$3" wd="$4" turns="$5" async="$6"
            echo "$obj" > "$PR_DIR/review_spawned.obj"
            (
                git -C "$LODGE_DIR" checkout "$SUBAGENT_TARGET_BRANCH" >/dev/null 2>&1
                echo "flock applied" > "$LODGE_DIR/review_fixed.txt"
                git -C "$LODGE_DIR" add review_fixed.txt
                git -C "$LODGE_DIR" commit -m "fix(review): add flock guard per PR review" >/dev/null 2>&1
                git -C "$LODGE_DIR" checkout develop >/dev/null 2>&1
            )
            return 0
        }

        # Tick 1: audit passes, pr_review emits REQUEST_CHANGES -> merge blocked, status=REMEDIATING, subagent spawned
        pr_sweep >/dev/null 2>&1 || true
        stat_r1=$(jq -r .status "$PR_DIR/PR-001.json")
        verdict_r1=$(jq -r .review_verdict "$PR_DIR/PR-001.json")
        assert_eq "$verdict_r1" "REQUEST_CHANGES" "Review verdict on Tick 1 must be REQUEST_CHANGES"
        assert_eq "$stat_r1" "REMEDIATING" "PR status must transition to REMEDIATING on REQUEST_CHANGES"
        assert_file_exists "$PR_DIR/review_spawned.obj" "Remediation subagent must be spawned on REQUEST_CHANGES"
        spawn_obj=$(cat "$PR_DIR/review_spawned.obj")
        assert_contains "$spawn_obj" "concurrent writer race" "Subagent objective must include reviewer feedback"

        # Tick 2: new commit detected on candidate/speedup -> stale review cleared, re-reviewed -> APPROVED -> MERGED
        pr_sweep >/dev/null 2>&1
        stat_r2=$(jq -r .status "$PR_DIR/PR-001.json")
        verdict_r2=$(jq -r .review_verdict "$PR_DIR/PR-001.json")
        assert_eq "$verdict_r2" "APPROVED" "Review verdict on Tick 2 must be APPROVED"
        assert_eq "$stat_r2" "MERGED" "PR must be MERGED after review remediation commit"
        git -C "$LODGE_DIR" checkout develop >/dev/null 2>&1
        assert_file_exists "$LODGE_DIR/review_fixed.txt" "Review fix must be present on develop"

        unset _PR_FORCE_REACT_REVIEW
        unset -f react_run
        unset -f subagents_spawn
        _teardown_pr_env
    }

describe "pr_drift_sweep (Working-Tree Drift Partner & 5 Risk Mitigations)"
    it "mitigates all 5 risks: lock/cooldown gate, human WIP separation, AST/secret gate, hash dedup, and non-destructive merge reconciliation" && {
        _setup_pr_env
        mkdir -p "$LODGE_DIR/.george/cron_jobs" "$LODGE_DIR/lib"

        # 1. Create a valid Foliage cron script, a Ledger-attributed lib file, and an unattributed Human WIP edit
        cat > "$LODGE_DIR/.george/cron_jobs/metro_watch.sh" << 'EOF'
#!/bin/bash
set -euo pipefail
echo "metro schedule check"
EOF
        chmod +x "$LODGE_DIR/.george/cron_jobs/metro_watch.sh"

        cat > "$LODGE_DIR/lib/agent_helper.sh" << 'EOF'
#!/bin/bash
agent_helper_ok() { return 0; }
EOF
        jq -nc --argjson ts "$(date +%s)" '{ts: $ts, rel_path: "lib/agent_helper.sh", tool: "file_write", task_id: "test_1"}' > "$GEORGE_DIR/uncommitted_agent_edits.jsonl"

        # Human WIP file (NOT in Foliage and NOT in uncommitted_agent_edits.jsonl)
        echo "human operator work in progress" >> "$LODGE_DIR/README.md"

        # Invalid syntax script & secret-leaking script (Risk 5 Warden Gate should skip both)
        cat > "$LODGE_DIR/.george/cron_jobs/broken_syntax.sh" << 'EOF'
#!/bin/bash
if [ -f "foo" ; then echo "missing fi"
EOF
        cat > "$LODGE_DIR/.george/cron_jobs/leaked_secret.sh" << 'EOF'
#!/bin/bash
GITEA_TOKEN=abcdef1234567890abcdef
EOF

        # Risk 1A: Active .lodge.lock held by current live PID ($$) must defer sweep
        echo "$$" > "$GEORGE_DIR/.lodge.lock"
        GEORGE_DRIFT_QUIET_SECONDS=0 pr_drift_sweep "$LODGE_DIR" >/dev/null 2>&1
        assert_file_not_exists "$PR_DIR/PR-001.json" "Active .lodge.lock must defer pr_drift_sweep"
        rm -f "$GEORGE_DIR/.lodge.lock"

        # Risk 1B: Cooldown window (9999s) must defer sweep when files were just modified
        GEORGE_DRIFT_QUIET_SECONDS=9999 pr_drift_sweep "$LODGE_DIR" >/dev/null 2>&1
        assert_file_not_exists "$PR_DIR/PR-001.json" "Recent file mtime within cooldown window must defer pr_drift_sweep"

        # Now run with GEORGE_DRIFT_QUIET_SECONDS=0 -> should promote metro_watch.sh + lib/agent_helper.sh into PR-001
        GEORGE_DRIFT_QUIET_SECONDS=0 pr_drift_sweep "$LODGE_DIR" >/dev/null 2>&1
        assert_file_exists "$PR_DIR/PR-001.json" "pr_drift_sweep must create PR-001 once quiet window passes"

        # Risk 3: Live working tree files must still exist on disk while PR-001 is open
        assert_file_exists "$LODGE_DIR/.george/cron_jobs/metro_watch.sh" "Non-destructive promotion must keep cron job on disk"
        assert_file_exists "$LODGE_DIR/lib/agent_helper.sh" "Non-destructive promotion must keep agent helper on disk"

        # Risk 2 & 5: Verify PR diff contains ONLY the 2 valid attributed files (not README.md, broken_syntax.sh, or leaked_secret.sh)
        drift_diff=$(pr_diff "PR-001")
        assert_contains "$drift_diff" "metro_watch.sh" "PR diff must include valid Foliage cron job"
        assert_contains "$drift_diff" "agent_helper.sh" "PR diff must include ledger-attributed file"
        ! echo "$drift_diff" | grep -q "human operator work in progress"
        assert_eq "$?" "0" "PR diff must NOT include unattributed human WIP in README.md"
        ! echo "$drift_diff" | grep -q "broken_syntax.sh"
        assert_eq "$?" "0" "PR diff must NOT include script failing bash -n AST check"
        ! echo "$drift_diff" | grep -q "leaked_secret.sh"
        assert_eq "$?" "0" "PR diff must NOT include script with hardcoded secret"

        # Risk 4: Running pr_drift_sweep again with identical content must be deduplicated (no PR-002)
        GEORGE_DRIFT_QUIET_SECONDS=0 pr_drift_sweep "$LODGE_DIR" >/dev/null 2>&1
        assert_file_not_exists "$PR_DIR/PR-002.json" "Content-hash ledger must prevent duplicate PR creation"

        # End-to-End Merge Reconciliation: accepting PR-001 must cleanly adopt both promoted files into develop
        # without clobbering human WIP in README.md
        rm -f "$LODGE_DIR/.george/cron_jobs/broken_syntax.sh" "$LODGE_DIR/.george/cron_jobs/leaked_secret.sh"
        pr_accept "PR-001" "merge" >/dev/null 2>&1
        assert_file_exists "$LODGE_DIR/.george/cron_jobs/metro_watch.sh" "Merged cron job must remain in develop"
        assert_file_exists "$LODGE_DIR/lib/agent_helper.sh" "Merged helper must remain in develop"
        git -C "$LODGE_DIR" ls-files --error-unmatch ".george/cron_jobs/metro_watch.sh" >/dev/null 2>&1
        assert_eq "$?" "0" "metro_watch.sh must now be tracked in git on develop"
        readme_wip=$(cat "$LODGE_DIR/README.md")
        assert_contains "$readme_wip" "human operator work in progress" "Human WIP in README.md must remain intact after merge"

        _teardown_pr_env
    }

describe "pr_fsm explicit state machine transitions"
    it "should skip redundant local pr_audit while in WAITING_FOR_CI and preserve attempt count across commits" && {
        _setup_pr_env
        mkdir -p tests
        cat > tests/run.sh << 'EOF'
#!/bin/bash
echo "AUDIT_RUN" >> "$PR_DIR/audit_runs.log"
exit 0
EOF
        chmod +x tests/run.sh
        git add tests/run.sh
        git commit -m "chore: add counting test runner" >/dev/null 2>&1

        git checkout candidate/speedup >/dev/null 2>&1
        git merge develop -m "sync develop" >/dev/null 2>&1
        git checkout develop >/dev/null 2>&1

        pr_create "candidate/speedup" "FSM Test PR" "Verify WAITING_FOR_CI skips duplicate pr_audit" "develop" 1 >/dev/null

        # Simulate pending CI (rc=2) on first two ticks, then failing CI (rc=1) on tick 3
        _mock_ci_rc=2
        _pr_check_gitea_ci_status() {
            _PR_CI_FAILURE_LOG="Simulated container CI failure"
            return "$_mock_ci_rc"
        }
        subagents_spawn() { return 0; }

        # Tick 1: PROPOSED -> runs pr_audit (1st time) -> transitions to WAITING_FOR_CI (ci_rc=2)
        pr_auto_evaluate "PR-001" >/dev/null 2>&1
        assert_eq "$(pr_fsm_get "PR-001" ".state")" "WAITING_FOR_CI" "FSM must transition to WAITING_FOR_CI when CI is pending"
        audit_cnt_1=$(wc -l < "$PR_DIR/audit_runs.log" 2>/dev/null | tr -d ' ')
        assert_eq "$audit_cnt_1" "1" "pr_audit must run once on initial PROPOSED state"

        # Tick 2: Still WAITING_FOR_CI (ci_rc=2) -> must NOT re-run pr_audit!
        pr_auto_evaluate "PR-001" >/dev/null 2>&1
        assert_eq "$(pr_fsm_get "PR-001" ".state")" "WAITING_FOR_CI" "FSM must remain in WAITING_FOR_CI"
        audit_cnt_2=$(wc -l < "$PR_DIR/audit_runs.log" 2>/dev/null | tr -d ' ')
        assert_eq "$audit_cnt_2" "1" "WAITING_FOR_CI must skip redundant local pr_audit runs"

        # Tick 3: CI fails (ci_rc=1) -> transitions WAITING_FOR_CI -> REMEDIATING with attempts=1
        _mock_ci_rc=1
        pr_auto_evaluate "PR-001" >/dev/null 2>&1 || true
        assert_eq "$(pr_fsm_get "PR-001" ".state")" "REMEDIATING" "FSM must transition to REMEDIATING on CI failure"
        assert_eq "$(pr_fsm_get "PR-001" ".attempts")" "1" "FSM attempts must increment to 1"

        # Tick 4: New commit pushed -> edge trigger resets state to PROPOSED while preserving attempts=1!
        git checkout candidate/speedup >/dev/null 2>&1
        echo "ci fix" >> algo.txt
        git add algo.txt
        git commit -m "fix: resolve container CI" >/dev/null 2>&1
        git checkout develop >/dev/null 2>&1

        # Let CI fail a second time on the new commit -> attempts must become 2 (not reset to 1!)
        pr_auto_evaluate "PR-001" >/dev/null 2>&1 || true
        assert_eq "$(pr_fsm_get "PR-001" ".state")" "REMEDIATING" "FSM must transition to REMEDIATING on 2nd CI failure"
        assert_eq "$(pr_fsm_get "PR-001" ".attempts")" "2" "FSM must preserve and increment attempts to 2 across new commits"

        unset -f _pr_check_gitea_ci_status subagents_spawn
        source "$LODGE_DIR/lib/agents/pr.sh" 2>/dev/null || true
        _teardown_pr_env
    }

test_end

