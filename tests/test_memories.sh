#!/bin/bash
# ── Tests: memories.sh ───────────────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/tools.sh"
source "$LODGE_DIR/lib/commands.sh"

test_start "memories.sh — Namespaced Semantic Handles"

# Load commands
source "$LODGE_DIR/commands/write.sh"
source "$LODGE_DIR/commands/append.sh"
source "$LODGE_DIR/commands/save.sh"

describe "ui_resolve_path mem: prefix resolution"

  it "resolves mem:<slug> to .george/memories/<slug>.md" && {
    lodge_dir="/tmp/test-lodge-mem"
    mkdir -p "$lodge_dir/.george/memories"
    
    resolved=$(LODGE_DIR="$lodge_dir" ui_resolve_path "mem:appleton_housing" ".")
    assert_eq "$resolved" "$lodge_dir/.george/memories/appleton_housing.md"
    
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
    LODGE_DIR="$test_dir" cmd_write "mem:appleton_housing # Appleton Wisconsin\nFirst time buyer advice." "$test_dir" 2>/dev/null
    
    assert_file_exists "$test_dir/.george/memories/appleton_housing.md"
    content=$(cat "$test_dir/.george/memories/appleton_housing.md")
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
    printf "Appleton Report Content" > "$test_dir/.george/memories/appleton_housing.md"
    
    expanded=$(LODGE_DIR="$test_dir" tools_expand_file_refs "Here is the report: mem:appleton_housing details" "$test_dir")
    
    assert_contains "$expanded" "Appleton Report Content details"
    
    rm -rf "$test_dir"
  }

describe "agent memory registration completion"

  it "registers new memory files in the registry" && {
    test_dir=$(test_tmpdir)
    mkdir -p "$test_dir/.george/memories"
    
    # Run helper in subshell to avoid side effects
    (
        source "$LODGE_DIR/lib/agent.sh"
        echo "# Appleton Advisement" > "$test_dir/.george/memories/appleton_advisement.md"
        _agent_register_memory_file "$test_dir"
        
        val=$(jq -r '."1".slug' "$test_dir/.george/memories/registry.json")
        [ "$val" = "appleton_advisement" ]
    )
    assert_eq "$?" "0"
    
    rm -rf "$test_dir"
  }

test_end
