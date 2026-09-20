#!/bin/bash
# ── Tests for lib/treesitter.sh ───────────────────────────────────

source "$(dirname "$0")/framework.sh"
source "$(dirname "$0")/../lib/treesitter.sh"

test_start "lib/treesitter.sh — Tree-sitter & AST Structural Intelligence Engine"

describe "treesitter_detect_lang"
  it "detects languages by file extension" && {
    assert_eq "$(treesitter_detect_lang "script.sh")" "bash"
    assert_eq "$(treesitter_detect_lang "module.py")" "python"
    assert_eq "$(treesitter_detect_lang "lib.rs")" "rust"
    assert_eq "$(treesitter_detect_lang "app.ts")" "typescript"
    assert_eq "$(treesitter_detect_lang "server.js")" "javascript"
    assert_eq "$(treesitter_detect_lang "main.c")" "c"
    assert_eq "$(treesitter_detect_lang "main.go")" "go"
    assert_eq "$(treesitter_detect_lang "config.json")" "json"
  }

describe "treesitter_outline"
  it "extracts bash function outlines" && {
    tmp=$(test_tmpdir)/test_script.sh
    cat > "$tmp" << 'EOF'
#!/bin/bash
# ── Utility Functions ──
foo_bar() {
    echo "inside foo"
}
function baz_qux() {
    echo "inside baz"
}
EOF
    outline=$(treesitter_outline "$tmp")
    assert_contains "$outline" "fn foo_bar()"
    assert_contains "$outline" "fn baz_qux()"
    rm -rf "$(dirname "$tmp")"
  }

  it "extracts python class and def outlines with line numbers" && {
    tmp=$(test_tmpdir)/test_script.py
    cat > "$tmp" << 'EOF'
class DataProcessor:
    def __init__(self, data):
        self.data = data

    def process(self):
        return self.data.strip()

def standalone_helper():
    pass
EOF
    outline=$(treesitter_outline "$tmp")
    assert_contains "$outline" "class DataProcessor"
    assert_contains "$outline" "def __init__"
    assert_contains "$outline" "def process"
    assert_contains "$outline" "def standalone_helper"
    rm -rf "$(dirname "$tmp")"
  }

describe "treesitter_symbol"
  it "extracts targeted bash function body" && {
    tmp=$(test_tmpdir)/test_sym.sh
    cat > "$tmp" << 'EOF'
first_fn() {
    echo "first"
}

target_function() {
    local val="hello"
    if [ -n "$val" ]; then
        echo "$val"
    fi
}

third_fn() {
    echo "third"
}
EOF
    sym=$(treesitter_symbol "$tmp" "target_function")
    assert_contains "$sym" "target_function()"
    assert_contains "$sym" "local val=\"hello\""
    assert_not_contains "$sym" "first_fn"
    assert_not_contains "$sym" "third_fn"
    rm -rf "$(dirname "$tmp")"
  }

  it "extracts targeted python function body" && {
    tmp=$(test_tmpdir)/test_sym.py
    cat > "$tmp" << 'EOF'
def skip_me():
    return 1

def my_target(x, y):
    result = x + y
    return result

def other():
    return 2
EOF
    sym=$(treesitter_symbol "$tmp" "my_target")
    assert_contains "$sym" "def my_target(x, y):"
    assert_contains "$sym" "result = x + y"
    assert_not_contains "$sym" "skip_me"
    assert_not_contains "$sym" "other"
    rm -rf "$(dirname "$tmp")"
  }

describe "treesitter_validate"
  it "validates syntactically correct bash code" && {
    treesitter_validate 'echo "hello world"' "bash" >/dev/null
    assert_ok $?
  }

  it "catches bash syntax errors" && {
    out=$(treesitter_validate 'if [ -z "test"; then echo broken' "bash" 2>&1)
    assert_fail $?
    assert_contains "$out" "syntax error"
  }

  it "validates valid JSON and catches invalid JSON" && {
    treesitter_validate '{"valid": true, "items": [1, 2, 3]}' "json" >/dev/null
    assert_ok $?
    out=$(treesitter_validate '{"broken": true, missing_brace' "json" 2>&1)
    assert_fail $?
    assert_contains "$out" "JSON syntax error"
  }

describe "treesitter_format_tools_idl"
  it "converts tool schemas to typed TypeScript interface" && {
    mock_schemas='[
      {
        "type": "function",
        "function": {
          "name": "calc_add",
          "description": "Add two numbers.",
          "parameters": {
            "type": "object",
            "properties": {
              "a": { "type": "number", "description": "First number." },
              "b": { "type": "number", "description": "Second number." }
            },
            "required": ["a", "b"]
          }
        }
      }
    ]'
    idl=$(treesitter_format_tools_idl "$mock_schemas")
    assert_contains "$idl" "interface NativeTools"
    assert_contains "$idl" "calc_add(a: number, b: number): string;"
  }

test_end
