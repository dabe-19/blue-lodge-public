#!/bin/bash
# ── Tests: lib/models.sh — Ollama dir resolution & native Linux paths ──
# Tests the 3-tier ollama_dir resolution added for native Linux support:
#   1. $OLLAMA_MODELS env var (explicit override)
#   2. /usr/share/ollama/.ollama/models (Linux systemd install)
#   3. _lodge_termux_home()/.ollama/models (Termux / user home fallback)
#
# Also tests install.sh shell block generation for the systemd path.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/models.sh"

test_start "lib/models.sh — Ollama Dir Resolution & Native Linux Paths"

# ── Helper: create mock Ollama directory structure ─────────────
# Creates a fake Ollama model store with manifest + blob for testing.
# Usage: _mk_mock_ollama <tmpdir> <model_name> <tag> <media_type> <digest>
_mk_mock_ollama() {
    local base_dir="$1" model_name="$2" tag="$3" media_type="$4" digest="$5"

    local manifest_dir
    if [[ "$model_name" == hf.co/* ]]; then
        manifest_dir="$base_dir/manifests/$model_name"
    elif [[ "$model_name" == */* ]]; then
        manifest_dir="$base_dir/manifests/registry.ollama.ai/$model_name"
    else
        manifest_dir="$base_dir/manifests/registry.ollama.ai/library/$model_name"
    fi

    mkdir -p "$manifest_dir"
    mkdir -p "$base_dir/blobs"

    local blob_path="$base_dir/blobs/${digest//:/-}"
    echo "fake-blob-content" > "$blob_path"

    cat > "$manifest_dir/$tag" << MANIFEST
{
  "layers": [
    {
      "mediaType": "$media_type",
      "digest": "$digest"
    }
  ]
}
MANIFEST

    echo "$blob_path"
}

# ════════════════════════════════════════════════════════════════
# Code structure: 3-tier ollama_dir resolution
# ════════════════════════════════════════════════════════════════
describe "3-tier ollama_dir resolution — code structure"

  it "_models_find_ollama_gguf checks OLLAMA_MODELS first" && {
    _body=$(declare -f _models_find_ollama_gguf)
    echo "$_body" | grep -q 'OLLAMA_MODELS'
    assert_ok $? "Must check OLLAMA_MODELS env var"
  }

  it "_models_find_ollama_gguf checks Linux systemd path second" && {
    _body=$(declare -f _models_find_ollama_gguf)
    echo "$_body" | grep -q '/usr/share/ollama/.ollama/models'
    assert_ok $? "Must check /usr/share/ollama/.ollama/models"
  }

  it "_models_find_ollama_gguf falls back to _lodge_termux_home" && {
    _body=$(declare -f _models_find_ollama_gguf)
    echo "$_body" | grep -q '_lodge_termux_home'
    assert_ok $? "Must fall back to _lodge_termux_home"
  }

  it "_models_find_ollama_gguf checks OLLAMA_MODELS before systemd path" && {
    _body=$(declare -f _models_find_ollama_gguf)
    _ollama_line=$(echo "$_body" | grep -n 'OLLAMA_MODELS' | head -1 | cut -d: -f1)
    _systemd_line=$(echo "$_body" | grep -n '/usr/share/ollama' | head -1 | cut -d: -f1)
    [ -n "$_ollama_line" ] && [ -n "$_systemd_line" ] && [ "$_ollama_line" -lt "$_systemd_line" ]
    assert_ok $? "OLLAMA_MODELS check must come before systemd path check"
  }

  it "_models_find_ollama_gguf checks systemd path before termux home" && {
    _body=$(declare -f _models_find_ollama_gguf)
    _systemd_line=$(echo "$_body" | grep -n '/usr/share/ollama' | head -1 | cut -d: -f1)
    _termux_line=$(echo "$_body" | grep -n '_lodge_termux_home' | head -1 | cut -d: -f1)
    [ -n "$_systemd_line" ] && [ -n "$_termux_line" ] && [ "$_systemd_line" -lt "$_termux_line" ]
    assert_ok $? "Systemd path check must come before _lodge_termux_home fallback"
  }

  it "_models_find_ollama_mmproj checks OLLAMA_MODELS first" && {
    _body=$(declare -f _models_find_ollama_mmproj)
    echo "$_body" | grep -q 'OLLAMA_MODELS'
    assert_ok $? "Must check OLLAMA_MODELS env var"
  }

  it "_models_find_ollama_mmproj checks Linux systemd path" && {
    _body=$(declare -f _models_find_ollama_mmproj)
    echo "$_body" | grep -q '/usr/share/ollama/.ollama/models'
    assert_ok $? "Must check /usr/share/ollama/.ollama/models"
  }

  it "_models_find_ollama_mmproj falls back to _lodge_termux_home" && {
    _body=$(declare -f _models_find_ollama_mmproj)
    echo "$_body" | grep -q '_lodge_termux_home'
    assert_ok $? "Must fall back to _lodge_termux_home"
  }

  it "_models_find_ollama_template checks OLLAMA_MODELS first" && {
    _body=$(declare -f _models_find_ollama_template)
    echo "$_body" | grep -q 'OLLAMA_MODELS'
    assert_ok $? "Must check OLLAMA_MODELS env var"
  }

  it "_models_find_ollama_template checks Linux systemd path" && {
    _body=$(declare -f _models_find_ollama_template)
    echo "$_body" | grep -q '/usr/share/ollama/.ollama/models'
    assert_ok $? "Must check /usr/share/ollama/.ollama/models"
  }

  it "_models_find_ollama_template falls back to _lodge_termux_home" && {
    _body=$(declare -f _models_find_ollama_template)
    echo "$_body" | grep -q '_lodge_termux_home'
    assert_ok $? "Must fall back to _lodge_termux_home"
  }

  it "all three functions use identical resolution pattern" && {
    # Extract the ollama_dir resolution block from each function
    _gguf_block=$(declare -f _models_find_ollama_gguf | grep -A6 'local ollama_dir=""')
    _mmproj_block=$(declare -f _models_find_ollama_mmproj | grep -A6 'local ollama_dir=""')
    _template_block=$(declare -f _models_find_ollama_template | grep -A6 'local ollama_dir=""')
    assert_eq "$_gguf_block" "$_mmproj_block" "gguf and mmproj resolution blocks must match"
    assert_eq "$_gguf_block" "$_template_block" "gguf and template resolution blocks must match"
  }

# ════════════════════════════════════════════════════════════════
# Functional: _models_find_ollama_gguf with OLLAMA_MODELS
# ════════════════════════════════════════════════════════════════
describe "_models_find_ollama_gguf — OLLAMA_MODELS env var"

  it "uses OLLAMA_MODELS when set and dir exists" && {
    _tmp=$(test_tmpdir)
    _blob=$(_mk_mock_ollama "$_tmp/models" "testmodel" "latest" \
        "application/vnd.ollama.image.model" "sha256:gguf001")

    _result=$(OLLAMA_MODELS="$_tmp/models" _models_find_ollama_gguf "testmodel:latest")
    assert_eq "$_result" "$_blob"
    rm -rf "$_tmp"
  }

  it "resolves library model with explicit tag via OLLAMA_MODELS" && {
    _tmp=$(test_tmpdir)
    _blob=$(_mk_mock_ollama "$_tmp/models" "qwen3" "8b" \
        "application/vnd.ollama.image.model" "sha256:gguf002")

    _result=$(OLLAMA_MODELS="$_tmp/models" _models_find_ollama_gguf "qwen3:8b")
    assert_eq "$_result" "$_blob"
    rm -rf "$_tmp"
  }

  it "resolves hf.co model via OLLAMA_MODELS" && {
    _tmp=$(test_tmpdir)
    _blob=$(_mk_mock_ollama "$_tmp/models" "hf.co/unsloth/Ministral-3-3B" "UD-Q5" \
        "application/vnd.ollama.image.model" "sha256:gguf003")

    _result=$(OLLAMA_MODELS="$_tmp/models" _models_find_ollama_gguf "hf.co/unsloth/Ministral-3-3B:UD-Q5")
    assert_eq "$_result" "$_blob"
    rm -rf "$_tmp"
  }

  it "resolves namespaced model via OLLAMA_MODELS" && {
    _tmp=$(test_tmpdir)
    _blob=$(_mk_mock_ollama "$_tmp/models" "ibm/granite4" "tiny" \
        "application/vnd.ollama.image.model" "sha256:gguf004")

    _result=$(OLLAMA_MODELS="$_tmp/models" _models_find_ollama_gguf "ibm/granite4:tiny")
    assert_eq "$_result" "$_blob"
    rm -rf "$_tmp"
  }

  it "defaults to 'latest' tag when none specified" && {
    _tmp=$(test_tmpdir)
    _blob=$(_mk_mock_ollama "$_tmp/models" "mymodel" "latest" \
        "application/vnd.ollama.image.model" "sha256:gguf005")

    _result=$(OLLAMA_MODELS="$_tmp/models" _models_find_ollama_gguf "mymodel")
    assert_eq "$_result" "$_blob"
    rm -rf "$_tmp"
  }

  it "fails when OLLAMA_MODELS points to non-existent dir" && {
    _result=$(OLLAMA_MODELS="/nonexistent/path" _models_find_ollama_gguf "testmodel" 2>/dev/null)
    _rc=$?
    assert_fail $_rc "Should fail when OLLAMA_MODELS dir doesn't exist"
    rm -rf "$_tmp"
  }

  it "fails when manifest exists but blob is missing" && {
    _tmp=$(test_tmpdir)
    _blob=$(_mk_mock_ollama "$_tmp/models" "broken" "latest" \
        "application/vnd.ollama.image.model" "sha256:missing")
    # Remove the blob to simulate a broken install
    rm -f "$_blob"

    _result=$(OLLAMA_MODELS="$_tmp/models" _models_find_ollama_gguf "broken:latest" 2>/dev/null)
    _rc=$?
    assert_fail $_rc "Should fail when blob file is missing"
    rm -rf "$_tmp"
  }

# ════════════════════════════════════════════════════════════════
# Functional: _models_find_ollama_mmproj with OLLAMA_MODELS
# ════════════════════════════════════════════════════════════════
describe "_models_find_ollama_mmproj — OLLAMA_MODELS env var"

  it "finds projector blob via OLLAMA_MODELS" && {
    _tmp=$(test_tmpdir)
    _blob=$(_mk_mock_ollama "$_tmp/models" "vision-model" "latest" \
        "application/vnd.ollama.image.projector" "sha256:proj001")

    _result=$(OLLAMA_MODELS="$_tmp/models" _models_find_ollama_mmproj "vision-model:latest")
    assert_eq "$_result" "$_blob"
    rm -rf "$_tmp"
  }

  it "fails when no projector layer exists" && {
    _tmp=$(test_tmpdir)
    # Create a model-type blob (not projector)
    _blob=$(_mk_mock_ollama "$_tmp/models" "text-only" "latest" \
        "application/vnd.ollama.image.model" "sha256:notvision")

    _result=$(OLLAMA_MODELS="$_tmp/models" _models_find_ollama_mmproj "text-only:latest" 2>/dev/null)
    _rc=$?
    assert_fail $_rc "Should fail when no projector layer in manifest"
    rm -rf "$_tmp"
  }

  it "resolves hf.co projector blob" && {
    _tmp=$(test_tmpdir)
    _blob=$(_mk_mock_ollama "$_tmp/models" "hf.co/org/vision-model" "Q5" \
        "application/vnd.ollama.image.projector" "sha256:proj002")

    _result=$(OLLAMA_MODELS="$_tmp/models" _models_find_ollama_mmproj "hf.co/org/vision-model:Q5")
    assert_eq "$_result" "$_blob"
    rm -rf "$_tmp"
  }

# ════════════════════════════════════════════════════════════════
# Functional: _models_find_ollama_template with OLLAMA_MODELS
# ════════════════════════════════════════════════════════════════
describe "_models_find_ollama_template — OLLAMA_MODELS env var"

  it "finds template blob via OLLAMA_MODELS" && {
    _tmp=$(test_tmpdir)
    _blob=$(_mk_mock_ollama "$_tmp/models" "templatemodel" "latest" \
        "application/vnd.ollama.image.template" "sha256:tmpl001")

    _result=$(OLLAMA_MODELS="$_tmp/models" _models_find_ollama_template "templatemodel:latest")
    assert_eq "$_result" "$_blob"
    rm -rf "$_tmp"
  }

  it "fails when no template layer exists" && {
    _tmp=$(test_tmpdir)
    _blob=$(_mk_mock_ollama "$_tmp/models" "notmpl" "latest" \
        "application/vnd.ollama.image.model" "sha256:notemplate")

    _result=$(OLLAMA_MODELS="$_tmp/models" _models_find_ollama_template "notmpl:latest" 2>/dev/null)
    _rc=$?
    assert_fail $_rc "Should fail when no template layer in manifest"
    rm -rf "$_tmp"
  }

  it "resolves namespaced template blob" && {
    _tmp=$(test_tmpdir)
    _blob=$(_mk_mock_ollama "$_tmp/models" "ibm/granite4" "3b" \
        "application/vnd.ollama.image.template" "sha256:tmpl002")

    _result=$(OLLAMA_MODELS="$_tmp/models" _models_find_ollama_template "ibm/granite4:3b")
    assert_eq "$_result" "$_blob"
    rm -rf "$_tmp"
  }

# ════════════════════════════════════════════════════════════════
# OLLAMA_MODELS takes priority over other paths
# ════════════════════════════════════════════════════════════════
describe "OLLAMA_MODELS priority"

  it "OLLAMA_MODELS overrides home dir models" && {
    # Create two model stores with different blobs
    _tmp=$(test_tmpdir)
    _blob_custom=$(_mk_mock_ollama "$_tmp/custom" "prioritytest" "latest" \
        "application/vnd.ollama.image.model" "sha256:custom111")
    _blob_home=$(_mk_mock_ollama "$_tmp/home" "prioritytest" "latest" \
        "application/vnd.ollama.image.model" "sha256:home222")

    # With OLLAMA_MODELS set, should use custom path
    _result=$(OLLAMA_MODELS="$_tmp/custom" _models_find_ollama_gguf "prioritytest:latest")
    assert_eq "$_result" "$_blob_custom" "Should use OLLAMA_MODELS path, not home"
    rm -rf "$_tmp"
  }

  it "ignores OLLAMA_MODELS when var is empty" && {
    # When OLLAMA_MODELS is empty string, should fall through to other paths
    _body=$(declare -f _models_find_ollama_gguf)
    echo "$_body" | grep -q '"\${OLLAMA_MODELS:-}"'
    assert_ok $? "Must use \${OLLAMA_MODELS:-} to handle empty/unset"
  }

  it "ignores OLLAMA_MODELS when dir does not exist" && {
    _body=$(declare -f _models_find_ollama_gguf)
    echo "$_body" | grep -q '\-d "$OLLAMA_MODELS"'
    assert_ok $? "Must verify OLLAMA_MODELS directory exists"
  }

# ════════════════════════════════════════════════════════════════
# _lodge_termux_home — base path resolution
# ════════════════════════════════════════════════════════════════
describe "_lodge_termux_home"

  it "is defined" && {
    declare -f _lodge_termux_home &>/dev/null
    assert_ok $?
  }

  it "returns a non-empty path" && {
    _result=$(_lodge_termux_home)
    assert_not_empty "$_result"
  }

  it "checks /data/data/com.termux before HOME" && {
    _body=$(declare -f _lodge_termux_home)
    _termux_line=$(echo "$_body" | grep -n 'data/data/com.termux' | head -1 | cut -d: -f1)
    _home_line=$(echo "$_body" | grep -n 'HOME.*ollama' | head -1 | cut -d: -f1)
    [ -n "$_termux_line" ] && [ -n "$_home_line" ] && [ "$_termux_line" -lt "$_home_line" ]
    assert_ok $? "Termux path check must precede HOME check"
  }

  it "caches result in _LODGE_TERMUX_HOME" && {
    _body=$(declare -f _lodge_termux_home)
    echo "$_body" | grep -q '_LODGE_TERMUX_HOME'
    assert_ok $? "Must use _LODGE_TERMUX_HOME cache variable"
  }

# ════════════════════════════════════════════════════════════════
# install.sh — shell block includes systemd path
# ════════════════════════════════════════════════════════════════
describe "install.sh — Linux systemd path support"

  it "shell block checks for /usr/share/ollama/.ollama/models" && {
    _block=$(grep -A2 '/usr/share/ollama' "$LODGE_DIR/install.sh" | head -5)
    assert_not_empty "$_block" "install.sh must reference systemd models path"
  }

  it "shell block exports OLLAMA_MODELS for systemd path" && {
    # The shell block should contain an export line for the systemd path
    grep -q 'OLLAMA_MODELS.*"/usr/share/ollama/.ollama/models"' "$LODGE_DIR/install.sh"
    assert_ok $? "Must export OLLAMA_MODELS with systemd path"
  }

  it "systemd path check comes after proot check in shell block" && {
    # In the _lodge_shell_block function, the systemd check is an elif
    # after the proot/Termux check
    _proot_line=$(grep -n 'data/data/com.termux/files/home/.ollama/models' "$LODGE_DIR/install.sh" | head -1 | cut -d: -f1)
    _systemd_line=$(grep -n '/usr/share/ollama/.ollama/models' "$LODGE_DIR/install.sh" | head -1 | cut -d: -f1)
    [ -n "$_proot_line" ] && [ -n "$_systemd_line" ] && [ "$_proot_line" -lt "$_systemd_line" ]
    assert_ok $? "Proot check must come before systemd path check"
  }

  it "Ollama serve startup checks systemd path" && {
    # After the proot OLLAMA_MODELS export, there should be an elif for systemd
    _serve_block=$(sed -n '/Ensure Ollama is running/,/ollama serve/p' "$LODGE_DIR/install.sh")
    echo "$_serve_block" | grep -q '/usr/share/ollama/.ollama/models'
    assert_ok $? "Ollama serve startup must check systemd models path"
  }

  it "Ollama serve systemd check exports OLLAMA_MODELS" && {
    _serve_block=$(sed -n '/Ensure Ollama is running/,/ollama serve/p' "$LODGE_DIR/install.sh")
    echo "$_serve_block" | grep -q 'export OLLAMA_MODELS="/usr/share/ollama/.ollama/models"'
    assert_ok $? "Must export OLLAMA_MODELS for systemd path at serve startup"
  }

# ════════════════════════════════════════════════════════════════
# Consistency: models.sh and install.sh use the same systemd path
# ════════════════════════════════════════════════════════════════
describe "Cross-file consistency"

  it "models.sh and install.sh reference the same systemd path" && {
    _models_path=$(grep -o '/usr/share/ollama/[^"]*' "$LODGE_DIR/lib/models.sh" | head -1)
    _install_path=$(grep -o '/usr/share/ollama/[^"]*' "$LODGE_DIR/install.sh" | head -1)
    assert_eq "$_models_path" "$_install_path" "Systemd path must be consistent across files"
  }

  it "all three find functions use the same systemd path string" && {
    _gguf_path=$(declare -f _models_find_ollama_gguf | grep -o '/usr/share/ollama/[^"]*' | head -1)
    _mmproj_path=$(declare -f _models_find_ollama_mmproj | grep -o '/usr/share/ollama/[^"]*' | head -1)
    _template_path=$(declare -f _models_find_ollama_template | grep -o '/usr/share/ollama/[^"]*' | head -1)
    assert_eq "$_gguf_path" "$_mmproj_path" "gguf and mmproj must use same path"
    assert_eq "$_gguf_path" "$_template_path" "gguf and template must use same path"
  }

test_end
