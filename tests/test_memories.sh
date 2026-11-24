#!/bin/bash
# ── Tests: memories.sh ───────────────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh"
source "$LODGE_DIR/lib/tools/tools.sh"
source "$LODGE_DIR/lib/ui/commands.sh"
source "$LODGE_DIR/lib/memory/memory.sh"

test_start "memories.sh — Namespaced Semantic Handles"

# Load commands
source "$LODGE_DIR/commands/write.sh"
source "$LODGE_DIR/commands/append.sh"
source "$LODGE_DIR/commands/save.sh"

describe "ui_resolve_path mem: prefix resolution"

  it "resolves mem:<slug> to .george/memories/<slug>.md" && {
    lodge_dir="/tmp/test-lodge-mem"
    mkdir -p "$lodge_dir/.george/memories"
    
    resolved=$(LODGE_DIR="$lodge_dir" ui_resolve_path "mem:springfield_housing" ".")
    assert_eq "$resolved" "$lodge_dir/.george/memories/springfield_housing.md"
    
    resolved=$(LODGE_DIR="$lodge_dir" ui_resolve_path "mem:gamestop-report" ".")
    assert_eq "$resolved" "$lodge_dir/.george/memories/gamestop-report.md"
    
    rm -rf "$lodge_dir"
  }

  it "sanitizes mem:<slug> to prevent directory traversal" && {
    lodge_dir="/tmp/test-lodge-mem"
    mkdir -p "$lodge_dir/.george/memories"
    
    resolved=$(LODGE_DIR="$lodge_dir" ui_resolve_path "mem:../../etc/passwd" ".")
    assert_eq "$resolved" "$lodge_dir/.george/memories/etcpasswd.md"
    
    rm -rf "$lodge_dir"
  }

  it "resolves mem:active_task to the active task slug" && {
    lodge_dir="/tmp/test-lodge-mem"
    mkdir -p "$lodge_dir/.george/memories"
    
    resolved=$(LODGE_DIR="$lodge_dir" AGENT_ACTIVE_TASK_SLUG="my_special_task" ui_resolve_path "mem:active_task" ".")
    assert_eq "$resolved" "$lodge_dir/.george/memories/my_special_task.md"
    
    rm -rf "$lodge_dir"
  }

  it "resolves mem:<index> using the registry JSON" && {
    lodge_dir="/tmp/test-lodge-mem"
    mkdir -p "$lodge_dir/.george/memories"
    echo '{"1": {"slug": "gamestop_report", "file": "gamestop_report.md"}}' > "$lodge_dir/.george/memories/registry.json"
    
    resolved=$(LODGE_DIR="$lodge_dir" ui_resolve_path "mem:1" ".")
    assert_eq "$resolved" "$lodge_dir/.george/memories/gamestop_report.md"
    
    rm -rf "$lodge_dir"
  }

  it "auto-routes new markdown writes and reads to memories" && {
    lodge_dir="/tmp/test-lodge-mem"
    mkdir -p "$lodge_dir/.george/memories"
    
    # Assert write (is_write=1) routes to memories
    resolved=$(LODGE_DIR="$lodge_dir" ui_resolve_path "some_analysis.md" "/tmp/test-lodge-mem/.george/workspaces/123" 1)
    assert_eq "$resolved" "$lodge_dir/.george/memories/some_analysis.md"
    
    # Assert read (is_write=0) routes to memories
    resolved=$(LODGE_DIR="$lodge_dir" ui_resolve_path "some_analysis.md" "/tmp/test-lodge-mem/.george/workspaces/123" 0)
    assert_eq "$resolved" "$lodge_dir/.george/memories/some_analysis.md"
    
    rm -rf "$lodge_dir"
  }

describe "commands and mem: handles integration"

  it "writes to a mem: file handle" && {
    test_dir=$(test_tmpdir)
    # Set LODGE_DIR to test_dir to isolate memory file creation
    LODGE_DIR="$test_dir" cmd_write "mem:springfield_housing # Springfield Illinois\nFirst time buyer advice." "$test_dir" 2>/dev/null
    
    assert_file_exists "$test_dir/.george/memories/springfield_housing.md"
    content=$(cat "$test_dir/.george/memories/springfield_housing.md")
    assert_contains "$content" "First time buyer advice."
    
    rm -rf "$test_dir"
  }

  it "appends to a mem: file handle" && {
    test_dir=$(test_tmpdir)
    LODGE_DIR="$test_dir" cmd_write "mem:test_log Log entry 1" "$test_dir" 2>/dev/null
    LODGE_DIR="$test_dir" cmd_append "mem:test_log Log entry 2" "$test_dir" 2>/dev/null
    
    content=$(cat "$test_dir/.george/memories/test_log.md")
    assert_contains "$content" "Log entry 1"
    assert_contains "$content" "Log entry 2"
    
    rm -rf "$test_dir"
  }

describe "tools_expand_file_refs with mem:"

  it "expands mem:<slug> references in messages" && {
    test_dir=$(test_tmpdir)
    mkdir -p "$test_dir/.george/memories"
    printf "Springfield Report Content" > "$test_dir/.george/memories/springfield_housing.md"
    
    expanded=$(LODGE_DIR="$test_dir" tools_expand_file_refs "Here is the report: mem:springfield_housing details" "$test_dir")
    
    assert_contains "$expanded" "Springfield Report Content details"
    
    rm -rf "$test_dir"
  }

describe "agent memory registration completion"

  it "registers new memory files in the registry" && {
    test_dir=$(test_tmpdir)
    mkdir -p "$test_dir/.george/memories"
    
    # Run helper in subshell to avoid side effects
    (
        source "$LODGE_DIR/lib/memory/memory.sh"
        echo "# Springfield Advisement" > "$test_dir/.george/memories/springfield_advisement.md"
        memory_register_files "$test_dir"
        
        val=$(jq -r '."1".slug' "$test_dir/.george/memories/registry.json")
        [ "$val" = "springfield_advisement" ]
    )
    assert_eq "$?" "0"
    
    rm -rf "$test_dir"
  }

describe "memory_get_task_slug and memory_catalog_context"

  it "generates clean task slugs from prompt text" && {
    slug=$(memory_get_task_slug "Research Springfield Illinois Housing Market!")
    assert_contains "$slug" "research_springfield_illinois_housing"
  }

  it "formats memory catalog context with active task and registry entries" && {
    test_dir=$(test_tmpdir)
    mkdir -p "$test_dir/.george/memories"
    cat << 'JSON' > "$test_dir/.george/memories/registry.json"
{
  "1": {
    "slug": "springfield_housing",
    "file": "springfield_housing.md",
    "title": "Springfield Housing Overview",
    "timestamp": "2026-09-20T00:00:00"
  },
  "2": {
    "slug": "gamestop_report",
    "file": "gamestop_report.md",
    "title": "GameStop Strategic Analysis",
    "timestamp": "2026-09-20T00:01:00"
  }
}
JSON
    catalog=$(AGENT_ACTIVE_TASK_SLUG="my_active_report" memory_catalog_context "$test_dir")
    assert_contains "$catalog" "mem:active_task -> Current task deliverable (.george/memories/my_active_report.md)"
    assert_contains "$catalog" "mem:2: GameStop Strategic Analysis [gamestop_report]"
    assert_contains "$catalog" "mem:1: Springfield Housing Overview [springfield_housing]"

    rm -rf "$test_dir"
  }

describe "Evidence Ledger Protection (scratchpad.md vs mem:active_task)"

  it "never resolves mem:active_task writes to scratchpad.md inside .sandboxes" && {
    test_dir=$(test_tmpdir)
    sandbox_dir="$test_dir/.sandboxes/research_raft_hlc_12345"
    sess_dir="$sandbox_dir/.george/workspaces/refine_thread_999"
    mkdir -p "$sess_dir"

    cat << 'EOF' > "$sandbox_dir/scratchpad.md"
# Phase 1 Scratchpad
- S1: https://cse.buffalo.edu/tech-reports/2014-04.pdf
- S2: https://arxiv.org/abs/1808.05698
- S3: https://arxiv.org/abs/2607.08666v1
EOF

    # 1. With active ReAct session in .sandboxes, writing mem:active_task routes to session active_task.md
    resolved_w=$(LODGE_DIR="$test_dir" AGENT_ACTIVE_SESSION_ID="refine_thread_999" AGENT_ACTIVE_SESSION_DIR="$sess_dir" \
        ui_resolve_path "mem:active_task" "$sandbox_dir" 1)
    assert_eq "$resolved_w" "$sess_dir/active_task.md"

    # Execute cmd_write on mem:active_task and verify scratchpad.md is untouched
    LODGE_DIR="$test_dir" AGENT_ACTIVE_SESSION_ID="refine_thread_999" AGENT_ACTIVE_SESSION_DIR="$sess_dir" \
        cmd_write "mem:active_task # Refinement Task Summary\nFixed 6 lines." "$sandbox_dir" 2>/dev/null

    sp_after=$(cat "$sandbox_dir/scratchpad.md")
    assert_contains "$sp_after" "https://arxiv.org/abs/1808.05698"
    assert_contains "$sp_after" "https://arxiv.org/abs/2607.08666v1"
    assert_file_exists "$sess_dir/active_task.md"

    # 2. Even without AGENT_ACTIVE_SESSION_ID, writing mem:active_task never resolves to scratchpad.md
    resolved_no_sess=$(LODGE_DIR="$test_dir" AGENT_ACTIVE_SESSION_ID="" AGENT_ACTIVE_SESSION_DIR="" \
        ui_resolve_path "mem:active_task" "$sandbox_dir" 1)
    assert_not_contains "$resolved_no_sess" "scratchpad.md"

    rm -rf "$test_dir"
  }

  it "auto-converts destructive file_write on scratchpad.md into non-destructive append in agent mode" && {
    test_dir=$(test_tmpdir)
    sandbox_dir="$test_dir/.sandboxes/research_raft_hlc_12345"
    mkdir -p "$sandbox_dir"

    cat << 'EOF' > "$sandbox_dir/scratchpad.md"
# Phase 1 Scratchpad
- S1: https://cse.buffalo.edu/tech-reports/2014-04.pdf
- S2: https://arxiv.org/abs/1808.05698
- S3: DOI: 10.1007/s11227-024-06438-6
EOF

    # Simulate non-interactive agent mode (stderr redirected to file) calling cmd_write on scratchpad.md
    LODGE_DIR="$test_dir" cmd_write "scratchpad.md ## Step 3 Notes\nVerified quorum intersection math." "$sandbox_dir" >/dev/null 2>&1

    sp_after=$(cat "$sandbox_dir/scratchpad.md")
    assert_contains "$sp_after" "https://cse.buffalo.edu/tech-reports/2014-04.pdf"
    assert_contains "$sp_after" "https://arxiv.org/abs/1808.05698"
    assert_contains "$sp_after" "10.1007/s11227-024-06438-6"
    assert_contains "$sp_after" "Verified quorum intersection math."

    rm -rf "$test_dir"
  }

test_end
