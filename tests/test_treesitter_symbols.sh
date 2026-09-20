#!/bin/bash
# ── Tests for Tree-sitter AST Symbol Slicing & SQLite Indexing ──────
source "$(dirname "$0")/framework.sh"

test_start "lib/recall.sh & lib/treesitter.sh — AST Symbol Slicing & Indexing"

test_dir=$(test_tmpdir)
GEORGE_DIR="$test_dir/.george"
RECALL_DB="$GEORGE_DIR/recall.db"
mkdir -p "$GEORGE_DIR"

source "$LODGE_DIR/lib/treesitter.sh"
source "$LODGE_DIR/lib/recall.sh"

# Create a sample multi-function shell script
sample_sh="$test_dir/sample_script.sh"
cat > "$sample_sh" <<'EOF'
#!/bin/bash
# Header comments

first_helper() {
    echo "First helper execution"
    local a=1
    return 0
}

# Second section
second_worker() {
    local task="$1"
    if [ -n "$task" ]; then
        echo "Processing $task"
    fi
    return 0
}

main_entrypoint() {
    first_helper
    second_worker "sample"
}
EOF

describe "treesitter_extract_symbols"
  it "extracts bash function signatures and line boundaries" && {
    symbols=$(treesitter_extract_symbols "$sample_sh")
    assert_contains "$symbols" "first_helper"
    assert_contains "$symbols" "second_worker"
    assert_contains "$symbols" "main_entrypoint"
  }

describe "recall_symbol_sync & recall_symbol_get"
  it "indexes symbols into SQLite and retrieves exact function slice" && {
    recall_init
    recall_symbol_sync "$sample_sh"

    # Verify table has entries
    count=$(sqlite3 "$RECALL_DB" "SELECT count(*) FROM code_symbols WHERE file_path = '$(readlink -f "$sample_sh")';")
    assert_eq "$count" "3"

    # Retrieve first_helper
    fn1=$(recall_symbol_get "first_helper" "$sample_sh")
    assert_contains "$fn1" "first_helper()"
    assert_contains "$fn1" "First helper execution"
    assert_not_contains "$fn1" "second_worker"

    # Retrieve second_worker
    fn2=$(recall_symbol_get "second_worker" "$sample_sh")
    assert_contains "$fn2" "second_worker()"
    assert_contains "$fn2" "Processing \$task"
    assert_not_contains "$fn2" "first_helper"
  }

test_end
