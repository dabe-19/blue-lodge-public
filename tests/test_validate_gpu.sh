#!/bin/bash
# ── Tests: scripts/validate-gpu.sh ─────────────────────────────
# Unit tests for the GPU validation script. Tests function-level
# behavior and ensures no bash syntax errors (e.g., `local` at
# top-level scope) without requiring a running llama-server.
source "$(dirname "$0")/framework.sh"

# ── Setup helpers ──────────────────────────────────────────────
_VALIDATE_SCRIPT="$LODGE_DIR/scripts/validate-gpu.sh"

test_start "scripts/validate-gpu.sh — GPU Validation"

# ═══════════════════════════════════════════════════════════════
# Syntax validation
# ═══════════════════════════════════════════════════════════════
describe "Bash syntax validation"

  it "passes bash -n syntax check (no parse errors)" && {
    bash -n "$_VALIDATE_SCRIPT" 2>/dev/null
    assert_ok $?
  }

  it "has no 'local' outside function bodies" && {
    # Extract 'local' lines, exclude those inside function bodies.
    # Functions are detected by matching 'funcname() {' .. '}'.
    # Strategy: use awk to track function depth and flag any 'local'
    # at depth 0 (top-level scope).
    _bad_locals=$(awk '
      /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ { in_func++ }
      /^\}/ { if (in_func > 0) in_func-- }
      /^[[:space:]]+local / {
        if (in_func == 0) print NR": "$0
      }
    ' "$_VALIDATE_SCRIPT")
    assert_empty "$_bad_locals" "Found local outside function: $_bad_locals"
  }

# ═══════════════════════════════════════════════════════════════
# LODGE_DIR auto-detection
# ═══════════════════════════════════════════════════════════════
describe "LODGE_DIR auto-detection"

  it "LODGE_DIR resolves from script location (not hardcoded)" && {
    # The script should use dirname-based detection, not $HOME/blue-lodge
    _lodge_dir_line=$(grep '^LODGE_DIR=' "$_VALIDATE_SCRIPT" | head -1)
    assert_contains "$_lodge_dir_line" 'dirname' \
      "LODGE_DIR should auto-detect from script location"
  }

  it "LODGE_DIR respects environment override" && {
    _lodge_dir_line=$(grep '^LODGE_DIR=' "$_VALIDATE_SCRIPT" | head -1)
    assert_contains "$_lodge_dir_line" '${LODGE_DIR:-' \
      "LODGE_DIR should allow environment override"
  }

# ═══════════════════════════════════════════════════════════════
# resolve_model function
# ═══════════════════════════════════════════════════════════════
describe "resolve_model()"

  # Source just the parts we need for testing resolve_model.
  # We create a controlled environment with stubs.
  # Extract resolve_model function ONCE into this test shell
  # (must be done at this scope, not inside a subshell)
  GGUF_PATH=""
  MODEL_LABEL=""
  _HAS_REGISTRY=0
  OLLAMA_DIR=""
  eval "$(awk '/^resolve_model\(\) \{/{found=1} found{print; if(/^\}/) exit}' "$_VALIDATE_SCRIPT")"

  _mk_resolve_tmp() {
    local tmpdir
    tmpdir=$(test_tmpdir)
    GGUF_PATH=""
    MODEL_LABEL=""
    _HAS_REGISTRY=0
    OLLAMA_DIR="$tmpdir/ollama_models"
    echo "$tmpdir"
  }

  it "resolves a direct GGUF file path" && {
    _tmp=$(_mk_resolve_tmp)
    _gguf="$_tmp/test-model.gguf"
    touch "$_gguf"

    resolve_model "$_gguf"
    assert_ok $?
    assert_eq "$GGUF_PATH" "$_gguf"
    assert_eq "$MODEL_LABEL" "test-model.gguf"
    rm -rf "$_tmp"
  }

  it "returns error for non-existent path" && {
    _tmp=$(_mk_resolve_tmp)
    resolve_model "/nonexistent/path/model.gguf" 2>/dev/null
    assert_fail $?
    rm -rf "$_tmp"
  }

  it "resolves Ollama model via manual manifest lookup" && {
    _tmp=$(_mk_resolve_tmp)
    OLLAMA_DIR="$_tmp/ollama_models"

    # Create fake Ollama manifest structure
    _mf_dir="$OLLAMA_DIR/manifests/registry.ollama.ai/library/testmodel"
    mkdir -p "$_mf_dir"
    mkdir -p "$OLLAMA_DIR/blobs"

    # Create a fake GGUF blob
    _blob="$OLLAMA_DIR/blobs/sha256-abc123"
    echo "fake-gguf-content" > "$_blob"

    # Create manifest pointing to our blob
    cat > "$_mf_dir/latest" << 'MANIFEST'
{
  "layers": [
    {
      "mediaType": "application/vnd.ollama.image.model",
      "digest": "sha256:abc123"
    }
  ]
}
MANIFEST

    resolve_model "testmodel"
    assert_ok $?
    assert_eq "$GGUF_PATH" "$_blob"
    assert_contains "$MODEL_LABEL" "ollama"
    rm -rf "$_tmp"
  }

  it "resolves Ollama model with explicit tag" && {
    _tmp=$(_mk_resolve_tmp)
    OLLAMA_DIR="$_tmp/ollama_models"

    _mf_dir="$OLLAMA_DIR/manifests/registry.ollama.ai/library/qwen3"
    mkdir -p "$_mf_dir"
    mkdir -p "$OLLAMA_DIR/blobs"

    _blob="$OLLAMA_DIR/blobs/sha256-def456"
    echo "fake-gguf" > "$_blob"

    cat > "$_mf_dir/8b" << 'MANIFEST'
{
  "layers": [
    {
      "mediaType": "application/vnd.ollama.image.model",
      "digest": "sha256:def456"
    }
  ]
}
MANIFEST

    resolve_model "qwen3:8b"
    assert_ok $?
    assert_eq "$GGUF_PATH" "$_blob"
    rm -rf "$_tmp"
  }

  it "falls back to 'latest' tag when none specified" && {
    _tmp=$(_mk_resolve_tmp)
    OLLAMA_DIR="$_tmp/ollama_models"

    _mf_dir="$OLLAMA_DIR/manifests/registry.ollama.ai/library/mymodel"
    mkdir -p "$_mf_dir"
    mkdir -p "$OLLAMA_DIR/blobs"

    _blob="$OLLAMA_DIR/blobs/sha256-latest999"
    echo "fake" > "$_blob"

    cat > "$_mf_dir/latest" << 'MANIFEST'
{
  "layers": [
    {
      "mediaType": "application/vnd.ollama.image.model",
      "digest": "sha256:latest999"
    }
  ]
}
MANIFEST

    resolve_model "mymodel"
    assert_ok $?
    assert_eq "$GGUF_PATH" "$_blob"
    rm -rf "$_tmp"
  }

  it "fails when manifest exists but blob is missing" && {
    _tmp=$(_mk_resolve_tmp)
    OLLAMA_DIR="$_tmp/ollama_models"

    _mf_dir="$OLLAMA_DIR/manifests/registry.ollama.ai/library/broken"
    mkdir -p "$_mf_dir"
    mkdir -p "$OLLAMA_DIR/blobs"

    cat > "$_mf_dir/latest" << 'MANIFEST'
{
  "layers": [
    {
      "mediaType": "application/vnd.ollama.image.model",
      "digest": "sha256:missingblob"
    }
  ]
}
MANIFEST

    resolve_model "broken" 2>/dev/null
    assert_fail $?
    rm -rf "$_tmp"
  }

  it "tries hf.co prefix for HuggingFace models" && {
    _tmp=$(_mk_resolve_tmp)
    OLLAMA_DIR="$_tmp/ollama_models"

    _mf_dir="$OLLAMA_DIR/manifests/hf.co/hfuser/hfmodel"
    mkdir -p "$_mf_dir"
    mkdir -p "$OLLAMA_DIR/blobs"

    _blob="$OLLAMA_DIR/blobs/sha256-hf789"
    echo "hf-fake" > "$_blob"

    cat > "$_mf_dir/latest" << 'MANIFEST'
{
  "layers": [
    {
      "mediaType": "application/vnd.ollama.image.model",
      "digest": "sha256:hf789"
    }
  ]
}
MANIFEST

    # Note: resolve_model splits on ":" and tries each prefix
    # For "hfuser/hfmodel", _lib="hfuser/hfmodel", _tag="latest"
    resolve_model "hfuser/hfmodel"
    assert_ok $?
    assert_eq "$GGUF_PATH" "$_blob"
    rm -rf "$_tmp"
  }

# ═══════════════════════════════════════════════════════════════
# Display and utility functions
# ═══════════════════════════════════════════════════════════════
describe "Display helpers"

  it "defines all display helper functions" && {
    # Source enough of the script to get the helper definitions
    # without actually running the full script
    _funcs=$(grep -P '^_\w+\(\)' "$_VALIDATE_SCRIPT" | sed 's/().*//')
    assert_contains "$_funcs" "_header"
    assert_contains "$_funcs" "_step"
    assert_contains "$_funcs" "_ok"
    assert_contains "$_funcs" "_fail"
    assert_contains "$_funcs" "_warn"
    assert_contains "$_funcs" "_dim"
    assert_contains "$_funcs" "_log"
  }

  it "defines cleanup trap function" && {
    assert_contains "$(grep 'cleanup()' "$_VALIDATE_SCRIPT")" "cleanup"
  }

# ═══════════════════════════════════════════════════════════════
# Termux home resolution
# ═══════════════════════════════════════════════════════════════
describe "_resolve_termux_home()"

  it "is defined as a function" && {
    assert_contains "$(grep '_resolve_termux_home()' "$_VALIDATE_SCRIPT")" "_resolve_termux_home"
  }

  it "returns HOME when .ollama/models exists at HOME" && {
    # Extract and run the function in isolation
    _func_body=$(sed -n '/_resolve_termux_home()/,/^}/p' "$_VALIDATE_SCRIPT")
    _tmp=$(test_tmpdir)
    mkdir -p "$_tmp/.ollama/models"

    _result=$(HOME="$_tmp" bash -c "$_func_body; _resolve_termux_home")
    assert_eq "$_result" "$_tmp"
    rm -rf "$_tmp"
  }

  it "checks proot (Termux native path) before HOME/.ollama/models" && {
    # The function must check /data/data/com.termux first, because inside
    # proot $HOME=/root/ and /root/.ollama/models can exist but is wrong.
    _func_body=$(sed -n '/_resolve_termux_home()/,/^}/p' "$_VALIDATE_SCRIPT")
    # The Termux path check should come BEFORE the HOME check
    _termux_line=$(echo "$_func_body" | grep -n 'data/data/com.termux' | head -1 | cut -d: -f1)
    _home_line=$(echo "$_func_body" | grep -n 'HOME.*ollama' | head -1 | cut -d: -f1)
    [ -n "$_termux_line" ] && [ -n "$_home_line" ] && [ "$_termux_line" -lt "$_home_line" ]
    assert_ok $? "Termux path check must come before HOME check"
  }

# ═══════════════════════════════════════════════════════════════
# set -e safety
# ═══════════════════════════════════════════════════════════════
describe "set -e safety for model scanning"

  it "GGUF resolution uses || true to survive set -e" && {
    _resolve_line=$(grep '_models_resolve_gguf' "$_VALIDATE_SCRIPT")
    assert_contains "$_resolve_line" "|| true" "_models_resolve_gguf must have || true guard"
  }

# ═══════════════════════════════════════════════════════════════
# Script structure  
# ═══════════════════════════════════════════════════════════════
describe "Script structure"

  it "uses set -euo pipefail" && {
    assert_contains "$(head -30 "$_VALIDATE_SCRIPT")" "set -euo pipefail"
  }

  it "sets up ERR trap or EXIT trap" && {
    _traps=$(grep '^trap ' "$_VALIDATE_SCRIPT")
    assert_not_empty "$_traps" "Should have at least one trap"
  }

  it "sources models.sh conditionally" && {
    _source_line=$(grep 'source.*models.sh' "$_VALIDATE_SCRIPT")
    assert_not_empty "$_source_line"
  }

  it "has all 8 validation steps" && {
    assert_contains "$(grep 'Step 1' "$_VALIDATE_SCRIPT")" "Step 1"
    assert_contains "$(grep 'Step 2' "$_VALIDATE_SCRIPT")" "Step 2"
    assert_contains "$(grep 'Step 3' "$_VALIDATE_SCRIPT")" "Step 3"
    assert_contains "$(grep 'Step 4' "$_VALIDATE_SCRIPT")" "Step 4"
    assert_contains "$(grep 'Step 5' "$_VALIDATE_SCRIPT")" "Step 5"
    assert_contains "$(grep 'Step 6' "$_VALIDATE_SCRIPT")" "Step 6"
    assert_contains "$(grep 'Step 7' "$_VALIDATE_SCRIPT")" "Step 7"
    assert_contains "$(grep 'Step 8' "$_VALIDATE_SCRIPT")" "Step 8"
  }

# ═══════════════════════════════════════════════════════════════
# Config defaults
# ═══════════════════════════════════════════════════════════════
describe "Configuration defaults"

  it "defaults GPU layers to 99" && {
    _line=$(grep 'LLAMA_CPP_GPU_LAYERS=' "$_VALIDATE_SCRIPT" | head -1)
    assert_contains "$_line" "99"
  }

  it "defaults context size to 4096" && {
    _line=$(grep 'LLAMA_CPP_CTX_SIZE=' "$_VALIDATE_SCRIPT" | head -1)
    assert_contains "$_line" "4096"
  }

  it "defaults validation port to 8090" && {
    _line=$(grep 'VALIDATE_PORT=' "$_VALIDATE_SCRIPT" | head -1)
    assert_contains "$_line" "8090"
  }

  it "uses separate port from Ollama (11434)" && {
    _port_line=$(grep 'VALIDATE_PORT=' "$_VALIDATE_SCRIPT" | head -1)
    assert_not_contains "$_port_line" "11434"
  }

test_end
