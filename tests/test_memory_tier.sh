#!/bin/bash
# ── Tests: Tiered Memory Archive and Compaction ────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh"
source "$LODGE_DIR/lib/memory/recall.sh"
source "$LODGE_DIR/lib/memory/memory.sh"
source "$LODGE_DIR/lib/core/agent_helpers.sh"

test_start "Tiered Memory Archive and Compaction"

# Prepare sandbox temp directories
TMP_GEORGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lodge-test-george.XXXXXX")
export GEORGE_DIR="$TMP_GEORGE_DIR"
export RECALL_DB="$GEORGE_DIR/recall.db"
export RECALL_MTIME_FILE="$GEORGE_DIR/.recall_mtimes"

# Clean up on exit
trap 'rm -rf "$TMP_GEORGE_DIR"' EXIT

# Initialize recall database
recall_init

describe "recall_archive_milestone and recall_search_milestones"

  it "archives a completed milestone and retrieves it lexically" && {
    recall_archive_milestone "Initialize Bash project system_shield" "Successfully scaffolded project main.sh" "system_shield/main.sh"
    
    # Search by keyword "system_shield"
    results=""
    results=$(recall_search_milestones "system_shield" 1 400)
    
    assert_not_empty "$results"
    echo "$results" | grep -q "Initialize Bash project system_shield"
    assert_ok $?
    
    # Verify no duplicates are added
    recall_archive_milestone "Initialize Bash project system_shield" "Successfully scaffolded project main.sh" "system_shield/main.sh"
    count=""
    count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='milestone_archive';" 2>/dev/null)
    assert_eq "$count" "1"
  }

describe "memory_compact with pre-archiving"

  it "archives live completed milestones from GEORGE.md before compaction" && {
    test_project_dir=""
    test_project_dir=$(mktemp -d "${TMPDIR:-/tmp}/lodge-test-proj.XXXXXX")
    
    # Initialize a dummy GEORGE.md
    memory_init "$test_project_dir" "test_compact" "Shell" "bash main.sh" "bash test.sh"
    
    # Append 12 dummy milestones
    i=""
    for i in {1..12}; do
      memory_append_section "Completed Milestones" "Milestone step number $i completed successfully" "$test_project_dir"
    done
    
    # Run compaction
    memory_compact "$test_project_dir"
    
    # Check that GEORGE.md has compacted Completed Milestones (keeps 5, plus 1 older milestones archived banner)
    milestones=""
    milestones=$(memory_get_section "Completed Milestones" "$test_project_dir")
    count=""
    count=$(echo "$milestones" | wc -l)
    assert_eq "$count" "6"
    
    # Verify that all 12 milestones were archived in the SQLite recall database
    archive_count=""
    archive_count=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM chunks WHERE source='milestone_archive';" 2>/dev/null)
    # 1 (from previous test) + 12 = 13
    assert_eq "$archive_count" "13"
    
    rm -rf "$test_project_dir"
  }

describe "memory_json_commit and action log compaction"

  it "commits valid JSON and rejects malformed updates" && {
    test_json="$TMP_GEORGE_DIR/test_validate.json"
    echo '{"status": "ok"}' > "$test_json"

    # Test valid JSON update
    tmp_json="${test_json}.tmp"
    echo '{"status": "updated"}' > "$tmp_json"
    memory_json_commit "$tmp_json" "$test_json"
    assert_eq "$(jq -r '.status' "$test_json")" "updated"

    # Test malformed JSON rejection
    echo '{"status": "corrupt"' > "$tmp_json"
    memory_json_commit "$tmp_json" "$test_json"
    # Original should be preserved
    assert_eq "$(jq -r '.status' "$test_json")" "updated"
  }



test_end
