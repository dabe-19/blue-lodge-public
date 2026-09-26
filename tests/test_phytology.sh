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
}

test_end

