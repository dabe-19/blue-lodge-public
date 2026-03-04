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

test_start "lib/models.sh — Ollama Dir Resolution & Native Linux Paths + Model Families"

# ── Helper: create mock Ollama directory structure ─────────────
# Creates a fake Ollama model store with manifest + blob for testing.
# Usage: _mk_mock_ollama <tmpdir> <model_name> <tag> <media_type> <digest>
_mk_mock_ollama() {
    base_dir="$1" model_name="$2" tag="$3" media_type="$4" digest="$5"

    if [[ "$model_name" == hf.co/* ]]; then
        manifest_dir="$base_dir/manifests/$model_name"
    elif [[ "$model_name" == */* ]]; then
        manifest_dir="$base_dir/manifests/registry.ollama.ai/$model_name"
    else
        manifest_dir="$base_dir/manifests/registry.ollama.ai/library/$model_name"
    fi

    mkdir -p "$manifest_dir"
    mkdir -p "$base_dir/blobs"

    blob_path="$base_dir/blobs/${digest//:/-}"
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

# ════════════════════════════════════════════════════════════════
# Model Registry — New Families (Gemma 3, Qwen 3.5, Phi-4)
# ════════════════════════════════════════════════════════════════
describe "Model Registry — Gemma 3 entries"

  it "gemma3-4b-inst is registered" && {
    _entry=$(_models_lookup "gemma3-4b-inst")
    assert_not_empty "$_entry"
  }

  it "gemma3-4b-inst has correct base image" && {
    _entry=$(_models_lookup "gemma3-4b-inst")
    _models_parse_entry "$_entry"
    echo "$_ME_BASE" | grep -q "gemma-3-4b-it-qat-GGUF"
    assert_ok $?
  }

  it "gemma3-4b-inst is instruct role" && {
    _entry=$(_models_lookup "gemma3-4b-inst")
    _models_parse_entry "$_entry"
    assert_eq "$_ME_ROLE" "instruct"
  }

  it "gemma3-4b-inst has <end_of_turn> stop token" && {
    _entry=$(_models_lookup "gemma3-4b-inst")
    _models_parse_entry "$_entry"
    assert_eq "$_ME_STOP" "<end_of_turn>"
  }

  it "gemma3-1b-inst is registered" && {
    _entry=$(_models_lookup "gemma3-1b-inst")
    assert_not_empty "$_entry"
  }

  it "gemma3-1b-inst has BF16 quant" && {
    _entry=$(_models_lookup "gemma3-1b-inst")
    _models_parse_entry "$_entry"
    echo "$_ME_BASE" | grep -q "BF16"
    assert_ok $?
  }

describe "Model Registry — Qwen 3.5 entries"

  it "qwen35-2b is registered" && {
    _entry=$(_models_lookup "qwen35-2b")
    assert_not_empty "$_entry"
  }

  it "qwen35-2b has correct base image" && {
    _entry=$(_models_lookup "qwen35-2b")
    _models_parse_entry "$_entry"
    echo "$_ME_BASE" | grep -q "Qwen3.5-2B-GGUF:UD-Q8_K_XL"
    assert_ok $?
  }

  it "qwen35-2b is instruct with no thinking" && {
    _entry=$(_models_lookup "qwen35-2b")
    _models_parse_entry "$_entry"
    assert_eq "$_ME_ROLE" "instruct"
    assert_eq "$_ME_THINKS" "0"
  }

  it "qwen35-2b-q8 uses Q8_0 quant" && {
    _entry=$(_models_lookup "qwen35-2b-q8")
    _models_parse_entry "$_entry"
    echo "$_ME_BASE" | grep -q ":Q8_0"
    assert_ok $?
  }

  it "qwen35-4b is registered" && {
    _entry=$(_models_lookup "qwen35-4b")
    assert_not_empty "$_entry"
  }

  it "qwen35-2b-think has thinking enabled" && {
    _entry=$(_models_lookup "qwen35-2b-think")
    _models_parse_entry "$_entry"
    assert_eq "$_ME_ROLE" "thinking"
    assert_eq "$_ME_THINKS" "1"
    assert_eq "$_ME_NOTHINK" "qwen"
  }

  it "qwen35-4b-think has thinking enabled" && {
    _entry=$(_models_lookup "qwen35-4b-think")
    _models_parse_entry "$_entry"
    assert_eq "$_ME_ROLE" "thinking"
    assert_eq "$_ME_THINKS" "1"
  }

  it "qwen35 instruct and thinking share same base GGUF" && {
    _entry_inst=$(_models_lookup "qwen35-2b")
    _models_parse_entry "$_entry_inst"
    _base_inst="$_ME_BASE"
    _entry_think=$(_models_lookup "qwen35-2b-think")
    _models_parse_entry "$_entry_think"
    _base_think="$_ME_BASE"
    assert_eq "$_base_inst" "$_base_think" "Same GGUF, different configs"
  }

  it "all qwen35 entries use <|im_end|> stop token" && {
    for _key in qwen35-2b qwen35-2b-q8 qwen35-4b qwen35-2b-think qwen35-4b-think; do
      _entry=$(_models_lookup "$_key")
      _models_parse_entry "$_entry"
      assert_eq "$_ME_STOP" '<|im_end|>' "qwen35 stop token for $_key"
    done
  }

  it "qwen35 instruct notes say downloaded via Ollama" && {
    for _key in qwen35-2b qwen35-2b-q8 qwen35-4b; do
      _entry=$(_models_lookup "$_key")
      _models_parse_entry "$_entry"
      echo "$_ME_NOTES" | grep -q "Downloaded via Ollama"
      assert_ok $? "Notes for $_key should mention Ollama download"
    done
  }

  it "qwen35 notes do NOT say llama.cpp only" && {
    for _key in qwen35-2b qwen35-2b-q8 qwen35-4b qwen35-2b-think qwen35-4b-think; do
      _entry=$(_models_lookup "$_key")
      _models_parse_entry "$_entry"
      ! echo "$_ME_NOTES" | grep -q "llama.cpp only"
      assert_ok $? "Notes for $_key should not say llama.cpp only"
    done
  }

  it "qwen35 thinking notes mention --chat-template-kwargs" && {
    for _key in qwen35-2b-think qwen35-4b-think; do
      _entry=$(_models_lookup "$_key")
      _models_parse_entry "$_entry"
      echo "$_ME_NOTES" | grep -q "chat-template-kwargs"
      assert_ok $? "Notes for $_key should mention chat-template-kwargs"
    done
  }

describe "Model Registry — Phi-4 entries"

  it "phi4-inst is registered" && {
    _entry=$(_models_lookup "phi4-inst")
    assert_not_empty "$_entry"
  }

  it "phi4-inst has Q5_K_M quant" && {
    _entry=$(_models_lookup "phi4-inst")
    _models_parse_entry "$_entry"
    echo "$_ME_BASE" | grep -q "Q5_K_M"
    assert_ok $?
  }

  it "phi4-inst is instruct with no thinking" && {
    _entry=$(_models_lookup "phi4-inst")
    _models_parse_entry "$_entry"
    assert_eq "$_ME_ROLE" "instruct"
    assert_eq "$_ME_THINKS" "0"
  }

  it "phi4-reason is registered" && {
    _entry=$(_models_lookup "phi4-reason")
    assert_not_empty "$_entry"
  }

  it "phi4-reason has thinking via system prompt" && {
    _entry=$(_models_lookup "phi4-reason")
    _models_parse_entry "$_entry"
    assert_eq "$_ME_ROLE" "thinking"
    assert_eq "$_ME_THINKS" "1"
    assert_eq "$_ME_NOTHINK" "system"
  }

  it "phi4-reason has <|end|> stop token" && {
    _entry=$(_models_lookup "phi4-reason")
    _models_parse_entry "$_entry"
    assert_eq "$_ME_STOP" '<|end|>'
  }

  it "phi4-reason uses higher temperature for exploration" && {
    _entry=$(_models_lookup "phi4-reason")
    _models_parse_entry "$_entry"
    # Should be 0.8 per Microsoft recommendation
    assert_eq "$_ME_TEMP" "0.8"
  }

# ════════════════════════════════════════════════════════════════
# Model Families — new definitions
# ════════════════════════════════════════════════════════════════
describe "Model Families — new definitions"

  it "gemma family is defined" && {
    _fam=$(_models_family_lookup "gemma")
    assert_not_empty "$_fam"
  }

  it "gemma family contains gemma3-4b-inst and gemma3-1b-inst" && {
    _fam=$(_models_family_lookup "gemma")
    _keys=$(_models_family_keys "$_fam")
    echo "$_keys" | grep -q "gemma3-4b-inst"
    assert_ok $? "Must contain gemma3-4b-inst"
    echo "$_keys" | grep -q "gemma3-1b-inst"
    assert_ok $? "Must contain gemma3-1b-inst"
  }

  it "qwen35 family is defined" && {
    _fam=$(_models_family_lookup "qwen35")
    assert_not_empty "$_fam"
  }

  it "qwen35 family description does not say llama.cpp only" && {
    _fam=$(_models_family_lookup "qwen35")
    ! echo "$_fam" | grep -q "llama.cpp only"
    assert_ok $? "Family description should not say llama.cpp only"
  }

  it "qwen35 family contains instruct and thinking variants" && {
    _fam=$(_models_family_lookup "qwen35")
    _keys=$(_models_family_keys "$_fam")
    echo "$_keys" | grep -q "qwen35-2b"
    assert_ok $? "Must contain qwen35-2b"
    echo "$_keys" | grep -q "qwen35-4b"
    assert_ok $? "Must contain qwen35-4b"
    echo "$_keys" | grep -q "qwen35-2b-think"
    assert_ok $? "Must contain qwen35-2b-think"
    echo "$_keys" | grep -q "qwen35-4b-think"
    assert_ok $? "Must contain qwen35-4b-think"
  }

  it "phi4 family is defined" && {
    _fam=$(_models_family_lookup "phi4")
    assert_not_empty "$_fam"
  }

  it "phi4 family contains phi4-inst and phi4-reason" && {
    _fam=$(_models_family_lookup "phi4")
    _keys=$(_models_family_keys "$_fam")
    echo "$_keys" | grep -q "phi4-inst"
    assert_ok $? "Must contain phi4-inst"
    echo "$_keys" | grep -q "phi4-reason"
    assert_ok $? "Must contain phi4-reason"
  }

  it "total family count is 7" && {
    _count=$(models_family_list | wc -l)
    assert_eq "$_count" "7" "Should have 7 families: qwen, llama, granite, ministral, gemma, qwen35, phi4"
  }

# ════════════════════════════════════════════════════════════════
# Chat Template Mapping — new models
# ════════════════════════════════════════════════════════════════
describe "Chat Template Mapping — new models"

  it "gemma3 maps to 'gemma' template" && {
    _entry=$(_models_lookup "gemma3-4b-inst")
    _models_parse_entry "$_entry"
    _tmpl=$(_models_chat_template_name "$_ME_BASE")
    assert_eq "$_tmpl" "gemma"
  }

  it "qwen35 maps to 'chatml' template" && {
    _entry=$(_models_lookup "qwen35-2b")
    _models_parse_entry "$_entry"
    _tmpl=$(_models_chat_template_name "$_ME_BASE")
    assert_eq "$_tmpl" "chatml"
  }

  it "qwen35 thinking variant maps to 'chatml' template" && {
    _entry=$(_models_lookup "qwen35-4b-think")
    _models_parse_entry "$_entry"
    _tmpl=$(_models_chat_template_name "$_ME_BASE")
    assert_eq "$_tmpl" "chatml"
  }

  it "phi4-inst maps to 'phi4' template" && {
    _entry=$(_models_lookup "phi4-inst")
    _models_parse_entry "$_entry"
    _tmpl=$(_models_chat_template_name "$_ME_BASE")
    assert_eq "$_tmpl" "phi4"
  }

  it "phi4-reason maps to 'phi4' template" && {
    _entry=$(_models_lookup "phi4-reason")
    _models_parse_entry "$_entry"
    _tmpl=$(_models_chat_template_name "$_ME_BASE")
    assert_eq "$_tmpl" "phi4"
  }

# ════════════════════════════════════════════════════════════════
# Vision Support — new models
# ════════════════════════════════════════════════════════════════
describe "Vision Support — new models"

  it "gemma3-4b-inst has vision support" && {
    models_has_vision "blue-lodge-gemma3-inst:4b"
    assert_ok $?
  }

  it "gemma3-1b-inst does NOT have vision support" && {
    models_has_vision "blue-lodge-gemma3-inst:1b"
    _rc=$?
    assert_fail $_rc "1B model should not have vision"
  }

  it "phi4-inst does NOT have vision support" && {
    models_has_vision "blue-lodge-phi4-inst:4b"
    _rc=$?
    assert_fail $_rc "Phi-4 mini is text-only"
  }

  it "minist-inst still has vision support" && {
    models_has_vision "blue-lodge-minist-inst:4b"
    assert_ok $?
  }

# ════════════════════════════════════════════════════════════════
# Think Flag Support — new models
# ════════════════════════════════════════════════════════════════
describe "Think Flag Support — new models"

  it "qwen35-think supports think flag" && {
    models_supports_think_flag "blue-lodge-qwen35-think:2b"
    assert_ok $?
  }

  it "qwen35-think:4b supports think flag" && {
    models_supports_think_flag "blue-lodge-qwen35-think:4b"
    assert_ok $?
  }

  it "qwen35 instruct does NOT support think flag" && {
    models_supports_think_flag "blue-lodge-qwen35:2b"
    _rc=$?
    assert_fail $_rc "Instruct Qwen 3.5 should not support think flag"
  }

  it "phi4-reason does NOT support think flag (system-prompt method)" && {
    models_supports_think_flag "blue-lodge-phi4-reason:4b"
    _rc=$?
    assert_fail $_rc "Phi-4 reasoning uses system prompt, not think:true"
  }

  it "phi4-inst does NOT support think flag" && {
    models_supports_think_flag "blue-lodge-phi4-inst:4b"
    _rc=$?
    assert_fail $_rc
  }

  it "qwen3-think still supports think flag" && {
    models_supports_think_flag "blue-lodge-qwen3-think:4b"
    assert_ok $?
  }

# ════════════════════════════════════════════════════════════════
# Thinking Directive — new models
# ════════════════════════════════════════════════════════════════
describe "Thinking Directive — Qwen 3.5 excluded"

  it "qwen35 thinking variants return no directive (template-native)" && {
    # Qwen 3.5 uses ChatML template with enable_thinking — no system prompt injection needed
    _directive=$(LODGE_NOTHINK=0 models_thinking_directive "blue-lodge-qwen35-think:2b")
    assert_empty "$_directive" "Qwen 3.5 should return empty directive (template handles thinking)"
  }

describe "Thinking Directive — Phi-4 reasoning"

  it "phi4-reason returns thinking directive with George personality" && {
    _directive=$(LODGE_NOTHINK=0 models_thinking_directive "blue-lodge-phi4-reason:4b")
    echo "$_directive" | grep -q '<think>'
    assert_ok $? "Must include <think> tags instruction"
    echo "$_directive" | grep -q 'George'
    assert_ok $? "Must include George personality"
  }

# ════════════════════════════════════════════════════════════════
# Nothink Method — new models
# ════════════════════════════════════════════════════════════════
describe "Nothink Method — new models"

  it "qwen35-2b-think uses qwen nothink method" && {
    _method=$(models_nothink_method "blue-lodge-qwen35-think:2b")
    assert_eq "$_method" "qwen"
  }

  it "phi4-reason uses system nothink method" && {
    _method=$(models_nothink_method "blue-lodge-phi4-reason:4b")
    assert_eq "$_method" "system"
  }

  it "gemma3-4b-inst uses none nothink method" && {
    _method=$(models_nothink_method "blue-lodge-gemma3-inst:4b")
    assert_eq "$_method" "none"
  }

# ════════════════════════════════════════════════════════════════
# install.sh — family list handling
# ════════════════════════════════════════════════════════════════
describe "install.sh — family list handling"

  it "install.sh does NOT exclude qwen from extra_missing" && {
    # qwen should appear in the available families list like any other optional family
    _block=$(sed -n '/_extra_missing/,/^done$/p' "$LODGE_DIR/install.sh")
    ! echo "$_block" | grep -q '"qwen".*continue'
    assert_ok $? "qwen must NOT be skipped in extra_missing loops"
  }

  it "install.sh excludes ministral from extra_missing" && {
    # ministral is the required default family, should not appear in the extra download prompt
    _block=$(sed -n '/_extra_missing/,/^done$/p' "$LODGE_DIR/install.sh")
    echo "$_block" | grep -q '"ministral".*continue'
    assert_ok $? "Must exclude ministral from extra_missing"
  }

  it "install.sh does NOT have _need_qwen auto-create block" && {
    ! grep -q '_need_qwen' "$LODGE_DIR/install.sh"
    assert_ok $? "No _need_qwen variable — qwen is offered in the normal family list"
  }

  it "install.sh prompts before installing default Ministral model" && {
    grep -q 'Install the default model now?' "$LODGE_DIR/install.sh"
    assert_ok $? "Must ask user before installing Ministral"
  }

  it "install.sh tells user Ministral is the configured default" && {
    grep -q 'configured as the default model' "$LODGE_DIR/install.sh"
    assert_ok $? "Must inform user that Ministral is the default"
  }

  it "install.sh skips model test when default not installed" && {
    grep -q '_minist_installed.*-eq 0' "$LODGE_DIR/install.sh"
    assert_ok $? "Must gate model test on _minist_installed"
  }

# ════════════════════════════════════════════════════════════════
# System prompt files — new models
# ════════════════════════════════════════════════════════════════
describe "System prompt files — new models"

  it "phi4-reason.system exists" && {
    [ -f "$LODGE_DIR/models/phi4-reason.system" ]
    assert_ok $?
  }

  it "phi4-reason.system contains thinking instruction" && {
    grep -q '<think>' "$LODGE_DIR/models/phi4-reason.system"
    assert_ok $?
  }

  it "qwen35-2b-think.system exists" && {
    [ -f "$LODGE_DIR/models/qwen35-2b-think.system" ]
    assert_ok $?
  }

  it "qwen35-4b-think.system exists" && {
    [ -f "$LODGE_DIR/models/qwen35-4b-think.system" ]
    assert_ok $?
  }

  it "default.system exists as fallback" && {
    [ -f "$LODGE_DIR/models/default.system" ]
    assert_ok $?
  }

test_end
