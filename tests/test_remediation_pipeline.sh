#!/bin/bash
# ── Tests: Sovereign Autonomic GitFlow Remediation Pipeline ───────────
# End-to-end verification of:
#   1. Milestone Summarizer (concise Gitea checkpoints: DIAGNOSIS, STAGING, VERIFICATION, DELIVERY)
#   2. Reactive Event Ingress (phytology faults, CI failures, deduplication, 3-strike guard)
#   3. Task Bay Metadata (task_type: remediation, phase tracking, trajectory log)
#   4. Turn-Level Cooperative Yielding & IPC Priority 20
#   5. Dual-Sync Merge Policy (merge into Gitea develop + local develop, origin untouched)
#   6. Isolated Worktree Sandbox Lifecycle & Culling

source "$(dirname "$0")/framework.sh"

_test_tmpdir=""
_orig_dir="$PWD"

_setup_pipeline() {
    _test_tmpdir=$(test_tmpdir)
    export LODGE_DIR="$_test_tmpdir/repo"
    export GEORGE_DIR="$LODGE_DIR/.george"
    export REMEDIATION_DIR="$GEORGE_DIR/remediation"
    export REMEDIATION_QUEUE_DIR="$REMEDIATION_DIR/queue"
    export REMEDIATION_PROGRESS_DIR="$REMEDIATION_DIR/in_progress"
    export REMEDIATION_COMPLETED_DIR="$REMEDIATION_DIR/completed"
    export REMEDIATION_FAILED_DIR="$REMEDIATION_DIR/failed"
    export REMEDIATION_LOGS_DIR="$REMEDIATION_DIR/logs"
    export REMEDIATION_ATTEMPTS_DIR="$REMEDIATION_DIR/attempts"
    export REMEDIATION_CONF="$REMEDIATION_DIR/notifications.conf"
    export EVENT_BUS_DIR="$GEORGE_DIR/ipc"
    export EVENT_BUS_FIFO="$EVENT_BUS_DIR/event_bus.fifo"
    export EVENT_BUS_REACTORS="$GEORGE_DIR/reactors.json"
    export EVENT_BUS_LOG="$EVENT_BUS_DIR/event_bus.log"
    export EVENT_STORE_DB=""
    export GITEA_URL="http://127.0.0.1:3088"
    export GITEA_USER="george"
    export GITEA_REPO="blue-lodge"
    export GITEA_TOKEN="dummy_token_test"

    mkdir -p "$LODGE_DIR" "$GEORGE_DIR" "$REMEDIATION_DIR" "$EVENT_BUS_DIR"

    # Set up mock git repo with develop branch and remote 'gitea'
    cd "$LODGE_DIR"
    git init >/dev/null 2>&1
    git config user.name "George Test"
    git config user.email "george@blue-lodge.local"
    echo "# Blue Lodge Test Repository" > README.md
    git add README.md
    git commit -m "chore: initial commit on develop" >/dev/null 2>&1
    git branch -M develop

    # Create bare 'gitea' remote repo
    bare_gitea="$_test_tmpdir/gitea_remote.git"
    git clone --bare "$LODGE_DIR" "$bare_gitea" >/dev/null 2>&1
    git remote add gitea "$bare_gitea"
    git fetch gitea >/dev/null 2>&1

    # Source remediation engine
    source "$_orig_dir/lib/agents/remediation.sh"
    remediation_init
}

_teardown_pipeline() {
    cd "$_orig_dir" 2>/dev/null
    rm -rf "$_test_tmpdir" 2>/dev/null || true
}

test_start "Autonomic GitFlow Remediation Pipeline"

describe "1. Milestone Summarizer (remediation_post_checkpoint)"

    it "formats concise structured executive markdown checkpoints without raw token dumps" && {
        _setup_pipeline
        posted_comments=()
        gitea_issue_comment() {
            idx="$1"
            body="$2"
            posted_comments+=("$body")
            return 0
        }

        remediation_post_checkpoint "42" "DIAGNOSIS" "Software Phytology living tissue contract degraded." "- **Tissue:** living_tissue\n- **Target Tier:** Tier 2" "rem_test_01"

        assert_eq "${#posted_comments[@]}" "1" "Must emit exactly one checkpoint comment"
        assert_contains "${posted_comments[0]}" "Remediation Checkpoint: \`DIAGNOSIS\`" "Contains header"
        assert_contains "${posted_comments[0]}" "Software Phytology living tissue contract degraded." "Contains summary"
        assert_contains "${posted_comments[0]}" "rem_test_01" "Contains task id"
        assert_not_contains "${posted_comments[0]}" "<think>" "Zero raw reasoning token dump"
        _teardown_pipeline
    }

describe "2. Reactive Event Ingress (remediation_event_ingress)"

    it "ingests system.phytology_fault and queues remediation task with fingerprint" && {
        _setup_pipeline
        fault_payload='{"status":"degraded","invalid_count":1,"invalid_tissues":["tissue_terminal_ui"],"issues":["Expected active widget"]}'
        
        # Mock Gitea issue creation
        gitea_is_online() { return 0; }
        gitea_issue_create() {
            echo '{"number": 99, "title": "Phytology Living Tissue Degraded"}'
        }

        task_id=$(remediation_event_ingress "system.phytology_fault" "$fault_payload")

        assert_neq "$task_id" "" "Task must be queued"
        assert_file_exists "$REMEDIATION_QUEUE_DIR/${task_id}.json" "Queue file must exist"
        
        q_fp=$(jq -r '.fingerprint' "$REMEDIATION_QUEUE_DIR/${task_id}.json")
        assert_contains "$q_fp" "phytology_" "Fingerprint prefixed with phytology"
        assert_eq "$(jq -r '.gitea_issue' "$REMEDIATION_QUEUE_DIR/${task_id}.json")" "99" "Links Gitea issue #99"
        assert_eq "$(jq -r '.priority' "$REMEDIATION_QUEUE_DIR/${task_id}.json")" "high" "High priority for phytology faults"
        _teardown_pipeline
    }

    it "deduplicates repeated events with identical fingerprint" && {
        _setup_pipeline
        fault_payload='{"status":"degraded","invalid_count":1,"invalid_tissues":["tissue_cache"],"issues":["Stale cache"]}'
        gitea_is_online() { return 0; }
        gitea_issue_create() { echo '{"number": 100}'; }

        tid1=$(remediation_event_ingress "system.phytology_fault" "$fault_payload")
        tid2=$(remediation_event_ingress "system.phytology_fault" "$fault_payload")

        assert_neq "$tid1" "" "First ingress must succeed"
        assert_eq "$tid2" "" "Second ingress must be deduplicated and skipped"
        _teardown_pipeline
    }

    it "enforces 3-strike escalation ceiling against repeated defect failures" && {
        _setup_pipeline
        fault_payload='{"status":"degraded","invalid_count":1,"invalid_tissues":["tissue_stubborn"],"issues":["Unresolvable defect"]}'
        gitea_is_online() { return 0; }
        gitea_issue_create() { echo '{"number": 101}'; }

        # Simulate 3 strikes recorded in attempts directory
        fp="phytology_$(echo -n "tissue_stubborn" | md5sum | cut -d' ' -f1 | head -c 12)"
        mkdir -p "$REMEDIATION_ATTEMPTS_DIR"
        echo '{"task_id":"old_task","key":"'"$fp"'","attempts":3,"last_failure_ts":12345678}' > "$REMEDIATION_ATTEMPTS_DIR/${fp}.json"

        blocked_tid=$(remediation_event_ingress "system.phytology_fault" "$fault_payload")

        assert_eq "$blocked_tid" "" "Must block ingress after 3 strikes ceiling"
        _teardown_pipeline
    }

describe "3. Task Bay Card Metadata & Trajectory Logging"

    it "creates task_meta.json with task_type: remediation, phase: Staging, and links trajectory.log" && {
        _setup_pipeline
        dummy_issue="$GEORGE_DIR/issues/issue_test_card.md"
        mkdir -p "$(dirname "$dummy_issue")"
        echo "# Bug: Memory Leak in IPC" > "$dummy_issue"
        echo "[fingerprint:memleak_001]" >> "$dummy_issue"

        tid=$(remediation_queue_add "$dummy_issue" "" "high" "Fix IPC Memory Leak")

        # Mock react_run to inspect sandbox before completion
        react_run() {
            sdir="$2"
            cat "$sdir/task_meta.json" > "$_test_tmpdir/sandbox_meta.json" 2>/dev/null || true
            [ -f "$sdir/trajectory.log" ] && touch "$_test_tmpdir/has_traj"
            echo "$AGENT_MAX_TURNS" > "$_test_tmpdir/turns.txt"
            echo "$AGENT_IPC_PRIORITY" > "$_test_tmpdir/prio.txt"
            return 0
        }

        remediation_run "$tid"

        sandbox_meta=$(cat "$_test_tmpdir/sandbox_meta.json" 2>/dev/null)
        assert_contains "$sandbox_meta" '"type": "remediation"' "Task Bay card type is remediation"
        assert_contains "$sandbox_meta" '"task_type": "remediation"' "Task Bay task_type is remediation"
        [ -f "$_test_tmpdir/has_traj" ]
        assert_ok $? "Sandbox must link trajectory.log"
        assert_eq "$(cat "$_test_tmpdir/turns.txt" 2>/dev/null)" "200" "Turn limit must be 200"
        assert_eq "$(cat "$_test_tmpdir/prio.txt" 2>/dev/null)" "20" "IPC priority must be 20 (REMEDIATION)"
        _teardown_pipeline
    }

describe "4. Dual-Sync Merge Policy & Worktree Sandbox Lifecycle"

    it "pushes to gitea remote, creates PR, merges into Gitea develop + local develop, and culls worktree" && {
        _setup_pipeline
        dummy_issue="$GEORGE_DIR/issues/issue_test_dualsync.md"
        mkdir -p "$(dirname "$dummy_issue")"
        echo "# Bug: Phytology Tissue Sync" > "$dummy_issue"
        echo "[fingerprint:phytsync_002]" >> "$dummy_issue"
        echo "**Gitea Issue:** #77" >> "$dummy_issue"

        tid=$(remediation_queue_add "$dummy_issue" "" "high" "Fix Phytology Tissue Sync")

        gitea_pr_create() {
            head="$1"
            base="$2"
            title="$3"
            echo "$head -> $base" > "$_test_tmpdir/pr_created_for.txt"
            echo '{"number": 15, "html_url": "http://127.0.0.1:3088/george/blue-lodge/pulls/15"}'
        }

        gitea_pr_merge() {
            pnum="$1"
            echo "$pnum" > "$_test_tmpdir/pr_merged_idx.txt"
            # Update bare gitea repo develop branch to simulate remote PR merge
            bare="$_test_tmpdir/gitea_remote.git"
            git -C "$bare" branch -f develop "remediation/${tid}" 2>/dev/null || true
            return 0
        }

        gitea_issue_close() {
            echo "$1" > "$_test_tmpdir/issue_closed_idx.txt"
            return 0
        }

        gitea_issue_comment() { return 0; }

        # Mock react_run to commit a fix to the sandbox branch
        react_run() {
            sdir="$2"
            echo "fixed tissue health logic" >> "$sdir/README.md"
            git -C "$sdir" add README.md
            git -C "$sdir" commit -m "fix(phytology): restore tissue contract" >/dev/null 2>&1
            return 0
        }

        REMEDIATION_APPLY_MODE=auto remediation_run "$tid"  # auto-merge path under test

        # Assert PR creation targeted develop
        pr_created_for=$(cat "$_test_tmpdir/pr_created_for.txt" 2>/dev/null)
        pr_merged_idx=$(cat "$_test_tmpdir/pr_merged_idx.txt" 2>/dev/null)
        issue_closed_idx=$(cat "$_test_tmpdir/issue_closed_idx.txt" 2>/dev/null)
        assert_eq "$pr_created_for" "remediation/${tid} -> develop" "PR created from remediation branch to develop"
        assert_eq "$pr_merged_idx" "15" "PR #15 was merged via gitea_pr_merge"
        assert_eq "$issue_closed_idx" "77" "Gitea issue #77 was closed"

        # Assert dual-sync: local develop updated with commit from remediation
        cur_readme=$(cat "$LODGE_DIR/README.md")
        assert_contains "$cur_readme" "fixed tissue health logic" "Local develop synchronized with merged remediation commit"

        # Assert worktree sandbox was culled
        [ ! -d "$LODGE_DIR/.sandboxes/remediation_${tid}" ]
        assert_ok $? "Worktree sandbox culled after completion"
        assert_file_exists "$REMEDIATION_COMPLETED_DIR/${tid}.json" "Task moved to completed"
        _teardown_pipeline
    }

describe "5. Event Bus Dispatch Integration (system.phytology_fault -> reactor -> ingress)"

    it "dispatches system.phytology_fault envelope through reactor registry to enqueue remediation task" && {
        _setup_pipeline
        source "$_orig_dir/lib/ipc/event_bus.sh"
        event_bus_init

        # Register reactor for phytology faults
        reactor_add "rx_remediation_phytology" "system.phytology_fault" ".*" \
            "source \"$_orig_dir/lib/agents/remediation.sh\" && remediation_event_ingress \"\$EVENT_TYPE\" \"\$EVENT_PAYLOAD\"" 0

        # Mock Gitea issue creation
        gitea_is_online() { return 0; }
        gitea_issue_create() { echo '{"number": 202, "title": "Phytology Fault"}'; }

        envelope=$(jq -n -c \
            --arg id "evt_test_123" \
            --arg type "system.phytology_fault" \
            --arg src "phytology_daemon" \
            --argjson pl '{"status":"degraded","invalid_count":1,"invalid_tissues":["tissue_reactor_test"],"issues":["Test fault"]}' \
            --argjson dp 0 \
            --argjson ts "$(date +%s)" \
            '{event_id: $id, type: $type, source: $src, payload: $pl, depth: $dp, timestamp: $ts}')

        event_bus_dispatch_single "$envelope"

        for _ in 1 2 3 4 5 6 7 8 9 10; do
            [ $(ls -1 "$REMEDIATION_QUEUE_DIR"/*.json 2>/dev/null | wc -l) -gt 0 ] && break
            sleep 0.1
        done

        # Check if queued task was generated
        queued_count=$(ls -1 "$REMEDIATION_QUEUE_DIR"/*.json 2>/dev/null | wc -l)
        assert_gt "$queued_count" "0" "Event bus reaction enqueued remediation task"

        qf=$(ls -1 "$REMEDIATION_QUEUE_DIR"/*.json 2>/dev/null | head -n 1)
        assert_contains "$(cat "$qf")" "phytology_" "Queued task contains phytology fingerprint"
        assert_contains "$(cat "$qf")" "tissue_reactor_test" "Queued task references degraded tissue"
        _teardown_pipeline
    }

test_end
