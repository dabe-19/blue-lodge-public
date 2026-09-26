#!/bin/bash
# ── Test: Software Phytology Module ───────────────────────────────────

set -euo pipefail
LODGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LODGE_DIR
source "$LODGE_DIR/tests/framework.sh"
source "$LODGE_DIR/lib/phytology.sh"

test_start "Software Phytology Living Tissue & Safe Grafting"

describe "Syntax validation"
it "validates valid scripts and catches syntax errors" && {
    valid_sh="/tmp/phytology_test_valid_$$.sh"
    invalid_sh="/tmp/phytology_test_invalid_$$.sh"
    echo "echo 'hello world'" > "$valid_sh"
    echo "if then fi invalid syntax" > "$invalid_sh"

    phytology_verify_syntax "$valid_sh"
    assert_ok $? "valid script should pass syntax check"

    rc=0
    phytology_verify_syntax "$invalid_sh" 2>/dev/null || rc=$?
    assert_fail "$rc" "invalid script should fail syntax check"

    rm -f "$valid_sh" "$invalid_sh"
}

describe "Safe grafting and rejection"
it "safely grafts valid content and blocks malformed content" && {
    target_script="$FOLIAGE_ROOT/test_sample_job_$$.sh"
    rm -f "$target_script"

    # Valid script graft succeeds
    valid_content="#!/bin/bash
# DESC: Phytology sample job
# INTERVAL: 300
echo 'Job running'
"
    phytology_graft "$target_script" "$valid_content" >/dev/null
    assert_file_exists "$target_script"

    # Malformed syntax graft is rejected and target file is preserved
    bad_content="#!/bin/bash
if then fi echo invalid syntax
"
    ! phytology_graft "$target_script" "$bad_content" >/dev/null 2>&1
    assert_ok $? "malformed graft should return non-zero"
    
    current_content=$(cat "$target_script")
    assert_contains "$current_content" "Job running"

    # Update and rollback
    updated_valid="#!/bin/bash
echo 'Updated job running'
"
    phytology_graft "$target_script" "$updated_valid" >/dev/null
    current_content=$(cat "$target_script")
    assert_contains "$current_content" "Updated job running"

    phytology_rollback "$target_script" >/dev/null
    current_content=$(cat "$target_script")
    assert_contains "$current_content" "Job running"

    rm -f "$target_script"
}

describe "Autonomic pruning"
it "disables failing foliage jobs" && {
    job_name="failing_leaf_$$"
    script="$FOLIAGE_ROOT/${job_name}.sh"
    echo -e "#!/bin/bash\n# ENABLED: 1\necho failing" > "$script"

    phytology_prune "$job_name" >/dev/null
    content=$(cat "$script")
    assert_contains "$content" "# ENABLED: 0"

    rm -f "$script"
}

describe "Living tissue audit"
it "audits healthy foliage and outputs valid telemetry" && {
    out=$(phytology_audit 2>&1)
    assert_contains "$out" "SOFTWARE PHYTOLOGY LIVING TISSUE AUDIT"
    assert_contains "$out" "AST Valid Tissue"

    json_out=$(phytology_audit --json 2>&1)
    assert_contains "$json_out" "\"status\": \"healthy\""
    assert_contains "$json_out" "\"invalid_ast\": 0"
}

it "detects corrupted foliage and flags non-zero exit" && {
    corrupted="$FOLIAGE_ROOT/corrupted_leaf_$$.sh"
    echo "if then fi invalid bash syntax" > "$corrupted"

    rc=0
    out=$(phytology_audit 2>&1) || rc=$?
    assert_fail "$rc" "audit should fail when corrupted foliage exists"
    assert_contains "$out" "CORRUPTED LIVING TISSUE DETECTED"
    assert_contains "$out" "corrupted_leaf_$$"

    rm -f "$corrupted"
}

describe "Autonomic self-healing"
it "auto-rolls back corrupted foliage when genetic snapshot exists" && {
    heal_target="$FOLIAGE_ROOT/heal_leaf_$$.sh"
    echo -e "#!/bin/bash\n# DESC: Valid heal test\necho 'valid before corruption'" > "$heal_target"
    phytology_snapshot "$heal_target" >/dev/null

    # Now corrupt it
    echo -e "if then fi corrupted syntax" > "$heal_target"

    heal_out=$(phytology_heal 2>&1)
    assert_contains "$heal_out" "HEAL_RESTORE"

    restored_content=$(cat "$heal_target")
    assert_contains "$restored_content" "valid before corruption"

    rm -f "$heal_target"
}

it "auto-prunes corrupted foliage when no snapshot exists" && {
    unrecoverable="$FOLIAGE_ROOT/unrecoverable_$$.sh"
    echo -e "#!/bin/bash\nif then fi unrecoverable syntax" > "$unrecoverable"

    heal_out=$(phytology_heal 2>&1)
    assert_contains "$heal_out" "HEAL_PRUNED"
    pruned_content=$(cat "$unrecoverable")
    assert_contains "$pruned_content" "# ENABLED: 0"

    rm -f "$unrecoverable"
}

describe "Phytology slash command"
it "dispatches /phytology status, audit, and test correctly" && {
    source "$LODGE_DIR/lib/commands.sh"
    
    status_out=$(commands_dispatch "/phytology status" 2>&1)
    assert_contains "$status_out" "GEORGE LIVING TISSUE & PHYTOLOGY MANIFEST"

    audit_out=$(commands_dispatch "/phytology audit" 2>&1)
    assert_contains "$audit_out" "SOFTWARE PHYTOLOGY LIVING TISSUE AUDIT"

    para_cmd_out=$(commands_dispatch "/phytology parallel-audit" 2>&1)
    assert_contains "$para_cmd_out" '"status":'
}

describe "Parallel Living Tissue Audit"
it "executes parallel audit via FIFO async/await and outputs structured telemetry" && {
    para_out=$(phytology_parallel_audit 10)
    assert_ok $? "parallel audit should exit 0 on clean foliage"
    st=$(echo "$para_out" | jq -r .status)
    assert_eq "$st" "healthy" "status should be healthy"
    inv=$(echo "$para_out" | jq -r .invalid)
    assert_eq "$inv" "0" "invalid should be 0"

    # Test degraded state detection
    corrupt_para="$FOLIAGE_ROOT/corrupt_para_$$.sh"
    echo "if then fi invalid syntax" > "$corrupt_para"

    degraded_out=$(phytology_parallel_audit 10)
    deg_st=$(echo "$degraded_out" | jq -r .status)
    assert_eq "$deg_st" "degraded" "status should be degraded"
    deg_inv=$(echo "$degraded_out" | jq -r .invalid)
    assert_eq "$deg_inv" "1" "invalid should be 1"
    assert_contains "$degraded_out" "corrupt_para_$$"

    rm -f "$corrupt_para"
}

describe "Autonomous Parallel Graft Engine"
it "executes parallel candidate grafts under credit window flow control" && {
    t1="$FOLIAGE_TOOLS_ROOT/para_t1_$$.sh"
    t2="$FOLIAGE_TOOLS_ROOT/para_t2_$$.sh"
    rm -f "$t1" "$t2"

    manifest=$(jq -nc \
        --arg t1 "$t1" --arg c1 "#!/bin/bash\necho 'para graft 1'\n" \
        --arg t2 "$t2" --arg c2 "#!/bin/bash\necho 'para graft 2'\n" \
        '[
            {target: $t1, content: $c1},
            {target: $t2, content: $c2}
        ]')

    graft_res=$(phytology_parallel_graft "$manifest" 2)
    assert_ok $? "parallel graft should complete successfully"
    tot=$(echo "$graft_res" | jq -r .total_grafts)
    assert_eq "$tot" "2" "total grafts should be 2"
    res=$(echo "$graft_res" | jq -r .resolved)
    assert_eq "$res" "2" "resolved grafts should be 2"
    fail=$(echo "$graft_res" | jq -r .failed)
    assert_eq "$fail" "0" "failed grafts should be 0"

    assert_file_exists "$t1"
    assert_file_exists "$t2"

    rm -f "$t1" "$t2"
}

describe "Autonomic Issue Remediation & Gitea Closed-Loop"
it "remediates corrupted tissue, files Gitea issue, rolls back from snapshot, and closes Gitea issue" && {
    rem_target="$FOLIAGE_TOOLS_ROOT/auto_rem_$$.sh"
    echo -e "#!/bin/bash\n# DESC: Healthy tissue\necho 'healthy tissue original'" > "$rem_target"
    phytology_snapshot "$rem_target" >/dev/null

    # Corrupt tissue
    echo -e "if then fi invalid syntax error" > "$rem_target"

    rem_out=$(phytology_auto_remediate "$rem_target" "TEST_CORRUPTION" 2>&1)
    assert_ok $? "auto_remediate should succeed when valid snapshot exists"
    assert_contains "$rem_out" "REMEDIATION_SUCCESS"

    # Verify restored content
    content=$(cat "$rem_target")
    assert_contains "$content" "healthy tissue original"

    # Verify syntax passes
    phytology_verify_syntax "$rem_target"
    assert_ok $? "restored tissue syntax should be valid"

    rm -f "$rem_target"
}

describe "Phenotypic Fitness Scoring"
it "calculates high fitness score and recommends lignification for fit candidate" && {
    tfile="$GEORGE_DIR/tools/healthy_test_$$.sh"
    echo -e '#!/bin/bash\n[ "$1" = "--test" ] && exit 0\necho healthy' > "$tfile"
    chmod +x "$tfile"
    phytology_snapshot "$tfile" >/dev/null 2>&1
    res=$(phytology_fitness "$tfile")
    fit=$(echo "$res" | jq -r '.fitness')
    rec=$(echo "$res" | jq -r '.recommendation')
    assert_eq "$rec" "LIGNIFY"
    rm -f "$tfile"
}

it "calculates low fitness score and recommends pruning for broken candidate" && {
    bfile="$GEORGE_DIR/tools/broken_test_$$.sh"
    echo -e 'if then fi' > "$bfile"
    res=$(phytology_fitness "$bfile" 2>/dev/null || true)
    rec=$(echo "$res" | jq -r '.recommendation')
    assert_eq "$rec" "PRUNE"
    rm -f "$bfile"
}

describe "Tissue Lignification & Morphogenesis"
it "promotes fit foliage to Cambium command and creates companion test" && {
    ffile="$GEORGE_DIR/tools/foliage_sample_$$.sh"
    echo -e '#!/bin/bash\n# DESC: Sample lignified command\n[ "$1" = "--test" ] && exit 0\necho "Sample"' > "$ffile"
    chmod +x "$ffile"
    phytology_snapshot "$ffile" >/dev/null 2>&1
    phytology_lignify "$ffile" "sample_cmd_$$"
    assert_file_exists "$LODGE_DIR/commands/sample_cmd_$$.sh"
    assert_file_exists "$LODGE_DIR/tests/test_lignified_sample_cmd_$$.sh"
    bash "$LODGE_DIR/tests/test_lignified_sample_cmd_$$.sh"
    rm -f "$ffile" "$LODGE_DIR/commands/sample_cmd_$$.sh" "$LODGE_DIR/tests/test_lignified_sample_cmd_$$.sh"
}

describe "Tissue Cache Coordination & Invalidation"
it "invalidates files and phytology cache namespaces upon grafting and pruning" && {
    cache_init
    cache_put "tool:file_read:test" "files" "old file content"
    cache_put "audit:0:test" "phytology" "old audit"

    # Verify cached
    assert_eq "$(cache_get "tool:file_read:test" "files")" "old file content"
    assert_eq "$(cache_get "audit:0:test" "phytology")" "old audit"

    # Graft tissue -> must invalidate both namespaces
    test_tissue="$FOLIAGE_TOOLS_ROOT/cache_sync_$$.sh"
    phytology_graft "$test_tissue" "echo 'cache sync test'" >/dev/null

    # Both must now be cache misses (exit 1)
    ! cache_get "tool:file_read:test" "files" >/dev/null 2>&1
    ! cache_get "audit:0:test" "phytology" >/dev/null 2>&1

    rm -f "$test_tissue"
}

describe "Cached Living Tissue Audit"
it "caches audit results and serves identical result on --cached" && {
    cache_init
    phytology_invalidate_cache

    # First audit without cache
    out1=$(phytology_audit --json)
    assert_contains "$out1" '"status": "healthy"'

    # Second audit with --cached
    out2=$(phytology_audit --json --cached)
    assert_eq "$out1" "$out2"
}

describe "Autonomic Healing Circuit Breaker"
it "trips circuit breaker after consecutive failures, quarantining defective tissue" && {
    broken_job="$FOLIAGE_ROOT/unhealable_$$.sh"
    echo "if then fi invalid" > "$broken_job"
    # Ensure no valid snapshots exist
    rm -f "$PHYTOLOGY_SNAPSHOTS_DIR/unhealable_$$.*" 2>/dev/null || true

    # Simulate strikes reaching threshold (3)
    echo "unhealable_$$.sh:2:$(date +%s)" > "$GEORGE_DIR/.phytology_strikes"

    heal_out=$(phytology_heal)
    assert_contains "$heal_out" "HEAL_CIRCUIT_BREAKER"
    assert_contains "$heal_out" "quarantined by circuit breaker"

    # Check alert file written
    alert_matches=$(find "$GEORGE_DIR/alerts" -name "alert_phytology_unhealable_$$*.json" 2>/dev/null | wc -l)
    [ "$alert_matches" -ge 1 ]

    # Check quarantine file exists
    q_matches=$(find "$GEORGE_DIR/quarantine" -name "unhealable_$$.sh.quarantine.*" 2>/dev/null | wc -l)
    [ "$q_matches" -ge 1 ]

    # Original broken job removed/quarantined from foliage
    [ ! -f "$broken_job" ]

    # Clean up test artifacts
    rm -f "$GEORGE_DIR/alerts/alert_phytology_unhealable_$$*.json" "$GEORGE_DIR/quarantine/unhealable_$$.sh.quarantine.*" 2>/dev/null || true
}

describe "Phytology Cache Slash Commands"
it "executes /phytology audit --cached, cache-status, and cache-invalidate" && {
    source "$LODGE_DIR/commands/phytology.sh"

    c_inv=$(cmd_phytology "cache-invalidate" "$LODGE_DIR")
    assert_contains "$c_inv" "Phytology cache invalidated"

    c_stat=$(cmd_phytology "cache-status" "$LODGE_DIR")
    assert_contains "$c_stat" "Cache"

    c_aud=$(cmd_phytology "audit --cached" "$LODGE_DIR")
    assert_contains "$c_aud" "LIVING TISSUE AUDIT"
}

test_end

