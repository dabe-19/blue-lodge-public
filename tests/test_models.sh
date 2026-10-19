#!/bin/bash
# ── Tests: lib/core/models.sh — model-agnostic sampling parameters ──────────
# Blue Lodge ships no model list: per-model sampling comes only from the operator's own
# Model Hub profiles. These tests pin that contract (no hand-picked families anywhere).
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true

T="$GEORGE_TEST_SANDBOX/models_lib"; mkdir -p "$T/g/models/profiles"
export GEORGE_DIR="$T/g"
unset _LIB_MODELS_LOADED
source "$LODGE_DIR/lib/core/models.sh"

test_start "lib/core/models.sh — model-agnostic parameters"

describe "no curated model registry"
  it "has no hard-coded model portfolio" && {
    ! grep -qiE '_MODELS_PORTFOLIO|qwen|gemma|granite|nemotron|champion|bonsai' "$LODGE_DIR/lib/core/models.sh"
    assert_ok $? "lib/core/models.sh must not name specific models"
  }
  it "legacy portfolio functions are gone" && {
    ! declare -f models_list >/dev/null && ! declare -f models_download >/dev/null && ! declare -f models_switch_profile >/dev/null
    assert_ok $? "models_list/models_download/models_switch_profile removed"
  }
  it "no curated catalog file ships" && assert_file_not_exists "$LODGE_DIR/config/models/catalog.json"

describe "models_get_param without a profile"
  it "returns 1 for an unknown model" && { models_get_param "some-model" temp >/dev/null; assert_eq "$?" "1"; }
  it "models_apply_defaults falls back to generic defaults" && {
    models_apply_defaults "some-model"
    assert_eq "$LLM_TEMPERATURE" "$MODELS_DEFAULT_TEMPERATURE"
    assert_eq "$LLM_TOP_K" "$MODELS_DEFAULT_TOP_K"
    assert_eq "$LLM_REPEAT_PENALTY" "$MODELS_DEFAULT_REPEAT"
  }

describe "models_get_param from the operator's profile"
  cat > "$T/g/models/profiles/my-model.json" <<'EOF'
{"schema":1,"name":"my-model","source":{"provider":"local","repo":"","revision":""},
 "files":[{"role":"model","path":"m.gguf","size":1,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"},
          {"role":"mmproj","path":"p.gguf","size":1,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],
 "server":{"ctx":16384},"sampling":{"temperature":0.6,"top_p":0.9,"top_k":20,"repeat_penalty":1.05}}
EOF
  it "reads temperature by profile name" && assert_eq "$(models_get_param my-model temp)" "0.6"
  it "reads top_k" && assert_eq "$(models_get_param my-model top_k)" "20"
  it "reads context from server.ctx" && assert_eq "$(models_get_param my-model context)" "16384"
  it "unset sampling key returns 1" && { models_get_param my-model min_p >/dev/null; assert_eq "$?" "1"; }
  it "models_load_params fills MODELS_P_* in-shell" && {
    models_load_params my-model
    assert_eq "$MODELS_P_TEMP" "0.6"; assert_eq "$MODELS_P_REPEAT" "1.05"; assert_eq "$MODELS_P_MIN_P" ""
  }
  it "models_apply_defaults mixes profile values with generic defaults" && {
    LLM_TEMP_ASK=0.9
    models_apply_defaults my-model
    assert_eq "$LLM_TEMPERATURE" "0.6"; assert_eq "$LLM_MIN_P" "$MODELS_DEFAULT_MIN_P"; assert_eq "$LLM_TEMP_ASK" ""
  }
  it "active profile applies when the served model id differs" && {
    echo '{"name": "my-model", "runtime": "docker"}' > "$T/g/models/active_profile.json"
    assert_eq "$(models_get_param "Some-File-Q4_K_M" temp)" "0.6"
    rm -f "$T/g/models/active_profile.json"
  }
  it "path-like model keys are never used as file names" && { models_get_param "../../etc/passwd" temp >/dev/null; assert_eq "$?" "1"; }
  it "edits to the profile are picked up (memo keyed on content)" && {
    sed -i 's/"temperature":0.6/"temperature":0.3/' "$T/g/models/profiles/my-model.json"
    models_load_params my-model; assert_eq "$MODELS_P_TEMP" "0.3"
  }

describe "models_has_vision"
  it "profile with an mmproj has vision" && { MODELS_VISION_PROBE=0 models_has_vision my-model; assert_ok $?; }
  it "unknown model without a server has no vision" && {
    ACTIVE_ENDPOINT_URL="" LLAMA_CPP_URL="" MODELS_VISION_PROBE=0 models_has_vision nothing; assert_eq "$?" "1"
  }

test_end
