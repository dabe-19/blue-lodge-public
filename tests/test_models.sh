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
# Model Registry — 2026 catalog
# ════════════════════════════════════════════════════════════════
describe "Model Registry — 2026 entries"

  it "gemma4-e2b-inst is registered with Gemma 4 base" && {
    _entry=$(_models_lookup "gemma4-e2b-inst")
    _models_parse_entry "$_entry"
    assert_not_empty "$_entry"
    echo "$_ME_BASE" | grep -q "gemma-4-E2B-it-qat-GGUF"
    assert_ok $? "Gemma 4 E2B must use 2026 base"
    assert_eq "$_ME_ROLE" "instruct"
  }

  it "gemma4-e4b-inst is registered with Gemma 4 base" && {
    _entry=$(_models_lookup "gemma4-e4b-inst")
    _models_parse_entry "$_entry"
    assert_not_empty "$_entry"
    echo "$_ME_BASE" | grep -q "gemma-4-E4B-it-qat-GGUF"
    assert_ok $? "Gemma 4 E4B must use 2026 base"
    assert_eq "$_ME_ROLE" "instruct"
  }

  it "qwen35-4b-think is thinking with qwen nothink method" && {
    _entry=$(_models_lookup "qwen35-4b-think")
    _models_parse_entry "$_entry"
    assert_not_empty "$_entry"
    assert_eq "$_ME_ROLE" "thinking"
    assert_eq "$_ME_THINKS" "1"
    assert_eq "$_ME_NOTHINK" "qwen"
    assert_eq "$_ME_STOP" '<|im_end|>'
  }

  it "granite41-3b-inst is present and uses IBM Granite 4.1 GGUF" && {
    _entry=$(_models_lookup "granite41-3b-inst")
    _models_parse_entry "$_entry"
    assert_not_empty "$_entry"
    echo "$_ME_BASE" | grep -q "granite-4.1-3b-GGUF"
    assert_ok $?
    assert_eq "$_ME_ROLE" "instruct"
  }

  it "nemotron3-nano-4b-inst is present and tagged edge" && {
    _entry=$(_models_lookup "nemotron3-nano-4b-inst")
    _models_parse_entry "$_entry"
    assert_not_empty "$_entry"
    assert_eq "$_ME_TIER" "edge"
  }

# ════════════════════════════════════════════════════════════════
# Model Families — 2026 definitions
# ════════════════════════════════════════════════════════════════
describe "Model Families — 2026 definitions"

  it "gemma4 family is defined with edge and central keys" && {
    _fam=$(_models_family_lookup "gemma4")
    _keys=$(_models_family_keys "$_fam")
    assert_not_empty "$_fam"
    echo "$_keys" | grep -q "gemma4-e4b-inst"
    assert_ok $?
    echo "$_keys" | grep -q "gemma4-12b-inst"
    assert_ok $?
  }

  it "qwen35 family includes both instruct and thinking keys" && {
    _fam=$(_models_family_lookup "qwen35")
    _keys=$(_models_family_keys "$_fam")
    assert_not_empty "$_fam"
    echo "$_keys" | grep -q "qwen35-4b-inst"
    assert_ok $?
    echo "$_keys" | grep -q "qwen35-4b-think"
    assert_ok $?
  }

  it "granite41 and nemotron3 families are available" && {
    _granite=$(_models_family_lookup "granite41")
    _nemotron=$(_models_family_lookup "nemotron3")
    assert_not_empty "$_granite"
    assert_not_empty "$_nemotron"
  }

  it "total family count is 4" && {
    _count=$(models_family_list | wc -l)
    assert_eq "$_count" "4"
  }

# ════════════════════════════════════════════════════════════════
# Chat Template Mapping — 2026 models
# ════════════════════════════════════════════════════════════════
describe "Chat Template Mapping — 2026 models"

  it "Gemma 4 maps to gemma template" && {
    _entry=$(_models_lookup "gemma4-e4b-inst")
    _models_parse_entry "$_entry"
    _tmpl=$(_models_chat_template_name "$_ME_BASE")
    assert_eq "$_tmpl" "gemma"
  }

  it "Qwen 3.5 maps to chatml template" && {
    _entry=$(_models_lookup "qwen35-4b-inst")
    _models_parse_entry "$_entry"
    _tmpl=$(_models_chat_template_name "$_ME_BASE")
    assert_eq "$_tmpl" "chatml"
  }

  it "Granite 4.1 maps to granite template" && {
    _entry=$(_models_lookup "granite41-3b-inst")
    _models_parse_entry "$_entry"
    _tmpl=$(_models_chat_template_name "$_ME_BASE")
    assert_eq "$_tmpl" "granite"
  }

  it "Nemotron maps to chatml template" && {
    _entry=$(_models_lookup "nemotron3-nano-4b-inst")
    _models_parse_entry "$_entry"
    _tmpl=$(_models_chat_template_name "$_ME_BASE")
    assert_eq "$_tmpl" "chatml"
  }

# ════════════════════════════════════════════════════════════════
# Vision + thinking capabilities
# ════════════════════════════════════════════════════════════════
describe "Vision and think support"

  it "gemma4-e2b-inst has vision support" && {
    models_has_vision "blue-lodge-gemma4-inst:2b"
    assert_ok $?
  }

  it "gemma4-e4b-inst has vision support" && {
    models_has_vision "blue-lodge-gemma4-inst:4b"
    assert_ok $?
  }

  it "qwen35-4b-inst does not have vision support" && {
    models_has_vision "blue-lodge-qwen35-inst:4b"
    _rc=$?
    assert_fail $_rc
  }

  it "only qwen35-4b-think supports think flag" && {
    models_supports_think_flag "blue-lodge-qwen35-think:4b"
    assert_ok $?

    models_supports_think_flag "blue-lodge-qwen35-inst:4b"
    _rc=$?
    assert_fail $_rc
  }

  it "qwen35 thinking directive is template-native (empty)" && {
    _directive=$(LODGE_NOTHINK=0 models_thinking_directive "blue-lodge-qwen35-think:4b")
    assert_empty "$_directive"
  }

  it "nothink methods map correctly" && {
    _method_qwen=$(models_nothink_method "blue-lodge-qwen35-think:4b")
    _method_gemma=$(models_nothink_method "blue-lodge-gemma4-inst:4b")
    assert_eq "$_method_qwen" "qwen"
    assert_eq "$_method_gemma" "system"
  }

# ════════════════════════════════════════════════════════════════
# install.sh — family list handling
# ════════════════════════════════════════════════════════════════
describe "install.sh — family list handling"

  it "install.sh excludes gemma4 from extra_missing" && {
    _count=$(grep -c '\[ "\$_fm" = "gemma4" \] && continue' "$LODGE_DIR/install.sh")
    assert_eq "$_count" "2" "Must exclude gemma4 in both missing and partial loops"
  }

  it "install.sh defines 2026 recommended families" && {
    grep -q '_recommended_families=(qwen35 granite41 nemotron3)' "$LODGE_DIR/install.sh"
    assert_ok $?
  }

  it "install.sh uses default-model installed gate variable" && {
    grep -q '_default_model_installed' "$LODGE_DIR/install.sh"
    assert_ok $?
  }

  it "install.sh keeps recommended selection flow" && {
    grep -q '"$_user_families" = "recommended"' "$LODGE_DIR/install.sh"
    assert_ok $?
  }

  it "install.sh iterates families via canonical list API" && {
    grep -q 'for _fam_name in $(models_family_list); do' "$LODGE_DIR/install.sh"
    assert_ok $? "Installer must iterate using models_family_list"
    grep -q '_fam_entry=$(_models_family_lookup "$_fam_name") || continue' "$LODGE_DIR/install.sh"
    assert_ok $? "Installer must resolve each family via _models_family_lookup"
  }

  it "install.sh documents realistic all-family storage range" && {
    grep -q "~3-7 GB per family" "$LODGE_DIR/install.sh"
    assert_ok $? "Installer copy must reflect edge vs central tier storage"
  }

# ════════════════════════════════════════════════════════════════
# install.sh — provisioning hardening
# ════════════════════════════════════════════════════════════════
describe "install.sh — provisioning hardening"

  it "control-char guard rejects all control characters" && {
    grep -q '\[\[ "\$value" != \*\[\[:cntrl:\]\]\* \]\]' "$LODGE_DIR/install.sh"
    assert_ok $? "Installer must reject control characters in persisted inputs"
  }

  it "remote setup validates SSH target before writing remote.conf" && {
    _validate_count=$(grep -c '_install_is_valid_ssh_target' "$LODGE_DIR/install.sh")
    [ "$_validate_count" -ge 2 ]
    assert_ok $? "Installer should validate SSH target in both remote flows"
  }

  it "provider exports are shell-quoted before rc persistence" && {
    grep -q '_escaped_provider=$(_install_quote_sh "$_INSTALL_PROVIDER")' "$LODGE_DIR/install.sh"
    assert_ok $?
    grep -q '_escaped_key=$(_install_quote_sh "$_INSTALL_PROVIDER_KEY_VALUE")' "$LODGE_DIR/install.sh"
    assert_ok $?
  }

  it "provider env lookup avoids indirect expansion" && {
    _bad=$(grep -n '\${!_INSTALL_PROVIDER_KEY_NAME' "$LODGE_DIR/install.sh" || true)
    assert_empty "$_bad" "Installer must not use indirect expansion for provider key lookup"
    grep -q '_install_read_provider_env_key()' "$LODGE_DIR/install.sh"
    assert_ok $? "Installer should use explicit provider env lookup helper"
  }

# ════════════════════════════════════════════════════════════════
# System prompt files — baseline checks
# ════════════════════════════════════════════════════════════════
describe "System prompt files — baseline checks"

  it "qwen35-4b-think.system exists" && {
    [ -f "$LODGE_DIR/models/qwen35-4b-think.system" ]
    assert_ok $?
  }

  it "default.system exists as fallback" && {
    [ -f "$LODGE_DIR/models/default.system" ]
    assert_ok $?
  }

# ════════════════════════════════════════════════════════════════
# Prompt contamination guards
# ════════════════════════════════════════════════════════════════
describe "Prompt contamination guards"

  it "minist-inst Modelfile SYSTEM has no Mistral tool-calling preamble" && {
    body=$(declare -f models_generate_modelfile)
    ! echo "$body" | grep -q 'TOOL CALLING INSTRUCTIONS'
    assert_ok $? "Mistral tool-calling preamble must be stripped"
  }

  it "minist-inst Modelfile SYSTEM has no Format using Markdown" && {
    body=$(declare -f models_generate_modelfile)
    ! echo "$body" | grep -q 'Format your response using Markdown'
    assert_ok $? "Markdown formatting instruction must be removed"
  }

  it "minist-think.system has no Format using Markdown" && {
    ! grep -q 'Format your response using Markdown' "$LODGE_DIR/models/minist-think.system"
    assert_ok $? "minist-think.system must not instruct Markdown formatting"
  }

  it "thinking directive for minist has no Format using Markdown" && {
    body=$(declare -f models_thinking_directive)
    ! echo "$body" | grep -q 'Format your response using Markdown'
    assert_ok $? "Thinking directive must not instruct Markdown formatting"
  }

  it "no .system file contains Format using Markdown" && {
    _found=$(grep -rl 'Format your response using Markdown' "$LODGE_DIR/models/"*.system 2>/dev/null || true)
    assert_empty "$_found" "No .system file should contain Markdown formatting instruction"
  }

test_end
