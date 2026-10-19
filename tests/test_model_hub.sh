#!/usr/bin/env bash
# Model hub (Phase 5): providers, GGUF reader, fit calculator, profiles, approval gate, installer, auth hygiene.
# Fully hermetic: mock HF hub on 127.0.0.1, hardware from a fixture, models dir in the sandbox.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"
LODGE_DIR="$GEORGE_TEST_REPO"; export LODGE_DIR

test_start "model_hub"

S="$GEORGE_TEST_SANDBOX/hub"; mkdir -p "$S/g" "$S/models"
python3 "$LODGE_DIR/tests/helpers/mock_hub.py" "$S/port" "$S/req.log" &
MPID=$!
trap 'kill $MPID 2>/dev/null' EXIT
for _i in $(seq 50); do [ -s "$S/port" ] && break; sleep 0.1; done
PORT=$(cat "$S/port")

cat > "$S/hw.json" <<'EOF'
{"os":"Linux test","gpus":[{"index":0,"vendor":"nvidia","name":"Test GPU A","vram_total_mb":12288,"vram_used_mb":0,"vram_free_mb":12288,"backend":"cuda"},
 {"index":1,"vendor":"nvidia","name":"Test GPU B","vram_total_mb":12288,"vram_used_mb":0,"vram_free_mb":12288,"backend":"cuda"}],
 "gpu_backend":"cuda","vram_total_mb":24576,"ram_total_mb":32768,"ram_available_mb":30000,
 "cpu":{"name":"test","threads":8},"disk":{"path":"/tmp","free_mb":500000,"total_mb":900000}}
EOF

export GEORGE_DIR="$S/g" MODELS_DIR="$S/models" HF_ENDPOINT="http://127.0.0.1:$PORT" \
       MODEL_HUB_ALLOW_HTTP_HOSTS="127.0.0.1:$PORT,localhost:$PORT" MODEL_HUB_HW_FIXTURE="$S/hw.json"
unset HF_TOKEN HUGGING_FACE_HUB_TOKEN MODELSCOPE_API_TOKEN
MH() { timeout 60 python3 "$LODGE_DIR/lib/tools/model_hub_cli.py" "$@" 2>"$S/stderr.log"; }

describe "search + inspect (normalized, unsafe repo ids dropped)"
out=$(MH search tiny)
assert_eq "$(jq -r 'length' <<<"$out")" "1" "only valid repo ids returned"
assert_eq "$(jq -r '.[0].repo' <<<"$out")" "test/tiny-GGUF"
info=$(MH inspect huggingface test/tiny-GGUF)
assert_eq "$(jq -r '.revision' <<<"$info")" "0123456789abcdef0123456789abcdef01234567" "revision pinned to commit sha"
assert_eq "$(jq -r '.quants | keys | join(",")' <<<"$info")" "Q4_K_M,Q8_0" "quants detected"
assert_eq "$(jq -r '[.files[] | select(.kind=="mmproj")] | length' <<<"$info")" "1" "mmproj classified"
assert_contains "$(MH inspect huggingface '../../etc/passwd')" "invalid repo id" "path traversal repo rejected"

describe "GGUF header over HTTP Range (no full download)"
d=$(MH gguf huggingface test/tiny-GGUF tiny-Q8_0.gguf)
assert_eq "$(jq -r '.arch' <<<"$d")" "llama"
assert_eq "$(jq -r '.n_layer' <<<"$d")" "4"
assert_eq "$(jq -r '.n_head_kv' <<<"$d")" "2"
assert_eq "$(jq -r '.head_dim_k' <<<"$d")" "64" "head_dim = embd/heads"
assert_eq "$(jq -r '.n_vocab' <<<"$d")" "1000" "string array skipped, length kept"
assert_eq "$(grep -c '"range": "bytes=' "$S/req.log")" "$(grep -c 'tiny-Q8_0.gguf' "$S/req.log")" "every model-file request was ranged"

describe "fit calculator arithmetic"
fit=$(cd "$LODGE_DIR/lib/tools" && python3 -c '
import json
from model_hub import fit
d={"n_layer":64,"n_head_kv":8,"head_dim_k":128,"head_dim_v":128,"ctx_train":131072,"n_vocab":152000,"n_embd":5120}
hw=json.load(open("'"$S/hw.json"'"))
r=fit.estimate(d, 16*1024**3, hw, ctx=16384)
kv,_=fit.kv_bytes_per_token(d)
print(json.dumps({"kv":kv,"v":r["verdict"],"split":r["tensor_split"],"maxctx":r["max_ctx"]}))
h={"n_layer":64,"n_head_kv":4,"head_dim_k":256,"head_dim_v":256,"hybrid_ssm":True,"full_attention_interval":4}
print(fit.kv_bytes_per_token(h)[0])
small=fit.estimate(d, 2*1024**3, hw, ctx=8192); print(small["verdict"], small.get("split_mode"), small["tensor_split"])
big=fit.estimate(d, 40*1024**3, hw, ctx=8192); print(big["verdict"], big["n_gpu_layers"])
huge=fit.estimate(d, 200*1024**3, hw, ctx=8192); print(huge["verdict"])
')
assert_eq "$(sed -n 1p <<<"$fit" | jq -r '.kv')" "262144.0" "KV/token = 64*8*(128*2+128*2)"
assert_eq "$(sed -n 1p <<<"$fit" | jq -r '.v')" "fits_gpu"
assert_eq "$(sed -n 1p <<<"$fit" | jq -c '.split')" "[49,51]" "two-GPU split weighted by usable VRAM (GPU0 holds full compute buffer)"
assert_eq "$(sed -n 2p <<<"$fit")" "65536.0" "hybrid SSM counts only 1/4 layers"
assert_eq "$(sed -n 3p <<<"$fit")" "fits_gpu none None" "small model pinned to one GPU"
assert_contains "$(sed -n 4p <<<"$fit")" "partial_offload" "oversize model offloads"
assert_eq "$(sed -n 5p <<<"$fit")" "does_not_fit"

describe "quants table + draft-from (sha-pinned, sampling from generation_config)"
q=$(MH quants huggingface test/tiny-GGUF --ctx 4096)
assert_eq "$(jq -r '.best_gpu_fit' <<<"$q")" "Q8_0" "largest quant that fits is preferred"
dr=$(MH draft-from hf test/tiny-GGUF Q4_K_M --ctx 4096 --with-mmproj --name tiny-q4)
assert_eq "$(jq -r '.status' <<<"$dr")" "draft"
assert_eq "$(jq -r '.profile.files | map(.role) | join(",")' <<<"$dr")" "model,mmproj"
assert_eq "$(jq -r '.profile.files[0].sha256 | length' <<<"$dr")" "64" "files sha-pinned"
assert_eq "$(jq -r '.profile.sampling.temperature' <<<"$dr")" "0.7" "sampling from generation_config.json"
assert_eq "$(jq -r '.profile.sampling.repeat_penalty' <<<"$dr")" "1.05"
assert_eq "$(jq -r '.profile.server.jinja' <<<"$dr")" "true" "chat template detected"

describe "approval gate: install refuses drafts and edited approvals"
assert_contains "$(MH install tiny-q4)" "not approved" "draft cannot be installed"
assert_file_not_exists "$S/models/hub/huggingface/test/tiny-GGUF/tiny-Q4_K_M.gguf"
MH approve tiny-q4 >/dev/null
pf="$S/g/models/profiles/tiny-q4.json"
jq '.server.ctx = 8192' "$pf" > "$pf.t" && mv "$pf.t" "$pf"
assert_contains "$(MH install tiny-q4)" "edited after approval" "post-approval edit invalidates approval"
assert_contains "$(MH env tiny-q4)" "approved and installed" "env refuses non-installed"
MH approve tiny-q4 >/dev/null

describe "installer downloads, verifies sha256, resumes"
root="$S/models/hub/huggingface/test/tiny-GGUF"
mkdir -p "$root"
head -c 1000 < <(curl -s "$HF_ENDPOINT/test/tiny-GGUF/resolve/x/tiny-Q4_K_M.gguf") > "$root/tiny-Q4_K_M.gguf.part"
out=$(MH install tiny-q4)
assert_eq "$(jq -r '.name' <<<"$out")" "tiny-q4" "install ok"
assert_file_exists "$root/tiny-Q4_K_M.gguf"
assert_file_exists "$root/mmproj-tiny-F16.gguf"
assert_contains "$(grep 'tiny-Q4_K_M' "$S/req.log" | tail -1)" '"range": "bytes=1000-"' "resumed from partial"
assert_eq "$(sha256sum "$root/tiny-Q4_K_M.gguf" | cut -c1-64)" "$(jq -r '.files[0].sha256' "$pf")" "on-disk sha matches pin"
assert_eq "$(jq -r '.status' "$pf")" "installed"
assert_eq "$(MH progress tiny-q4 | jq -r '.state')" "done"
n_before=$(wc -l < "$S/req.log")
MH install tiny-q4 >/dev/null
assert_eq "$(wc -l < "$S/req.log")" "$n_before" "re-install of verified files makes no requests"
env=$(MH env tiny-q4)
assert_eq "$(jq -r '.LLAMA_ARG_MODEL' <<<"$env")" "/models/hub/huggingface/test/tiny-GGUF/tiny-Q4_K_M.gguf" "container path"
assert_eq "$(jq -r '.LLAMA_ARG_MMPROJ' <<<"$env")" "/models/hub/huggingface/test/tiny-GGUF/mmproj-tiny-F16.gguf"
assert_eq "$(jq -r '.LLAMA_ARG_JINJA' <<<"$env")" "1"

describe "sha mismatch is rejected and the file discarded"
MH draft-from hf test/badsha-GGUF Q4_K_M --ctx 4096 --name bad >/dev/null
MH approve bad >/dev/null
assert_contains "$(MH install bad)" "sha256 mismatch" "bad sha rejected"
assert_file_not_exists "$S/models/hub/huggingface/test/badsha-GGUF/tiny-Q4_K_M.gguf"
assert_file_not_exists "$S/models/hub/huggingface/test/badsha-GGUF/tiny-Q4_K_M.gguf.part"

describe "profile validation blocks smuggled flags / paths / unpinned files"
bad=$(jq '.server["model"]="/etc/shadow" | .files[0].path="../../x.gguf" | .source.revision="main" | .files[0].sha256=""' "$pf")
out=$(MH save-draft <<<"$bad")
assert_contains "$out" "server.model: not an allowed key"
assert_contains "$out" "safe relative .gguf path"
assert_contains "$out" "pinned commit sha"
assert_contains "$out" "sha256: required"

describe "auth: login validates, stores 0600, never echoes; token not sent cross-host"
assert_contains "$(echo bogus | MH login huggingface)" "authentication required" "bad token rejected"
assert_file_not_exists "$S/g/keys.conf"
out=$(echo hf_goodtoken0123456789abcdef | MH login huggingface)
assert_eq "$(jq -r '.logged_in.user' <<<"$out")" "tester"
assert_not_contains "$out" "hf_goodtoken" "token never echoed"
assert_eq "$(stat -c %a "$S/g/keys.conf")" "600" "keys.conf is 0600"
assert_eq "$(MH accounts | jq -r '.[0].user')" "tester"
assert_eq "$(MH inspect huggingface test/gated-GGUF | jq -r '.gated')" "true" "gated repo readable with token"
: > "$S/req.log"
MH draft-from hf test/redirect-GGUF Q4_K_M --ctx 4096 --name redir >/dev/null
MH approve redir >/dev/null
MH install redir >/dev/null
assert_contains "$(grep '/resolve/' "$S/req.log" | grep 'tiny-Q4' | head -1)" '"auth": true' "token sent to the hub itself"
assert_contains "$(grep '/cdn/' "$S/req.log" | head -1)" '"auth": false' "token stripped on cross-host redirect"
assert_file_exists "$S/models/hub/huggingface/test/redirect-GGUF/tiny-Q4_K_M.gguf"
MH logout huggingface >/dev/null
assert_not_contains "$(cat "$S/g/keys.conf")" "HF_TOKEN" "logout removes token"

describe "host allow-list"
out=$(cd "$LODGE_DIR/lib/tools" && python3 -c '
from model_hub.common import host_allowed as h
print(h("https://huggingface.co/x"), h("https://cas-bridge.xethub.hf.co/x"), h("https://evil.com/x"),
      h("http://huggingface.co/x"), h("https://huggingface.co.evil.com/x"), h("file:///etc/passwd"))')
assert_eq "$out" "True True False False False False"

describe "George tool bridge (read/draft only) + model_hub profile scope"
source "$LODGE_DIR/lib/tools/model_hub.sh"
out=$(model_hub_tool hub_inspect '{"repo":"test/tiny-GGUF"}')
assert_eq "$(jq -r '.quants | join(",")' <<<"$out")" "Q4_K_M,Q8_0" "inspect trimmed for LLM"
assert_eq "$(jq -r '.aux[0].kind' <<<"$out")" "mmproj"
assert_eq "$(jq -r 'has("files")' <<<"$out")" "false" "raw file list not sent to the LLM"
assert_contains "$(model_hub_tool hub_quant_fit '{"repo":"test/tiny-GGUF","ctx":"4096; rm -rf /"}')" "ctx must be an integer" "argument injection rejected"
assert_eq "$(model_hub_tool hub_quant_fit '{"repo":"test/tiny-GGUF","quant":"Q8_0","ctx":4096}' | jq -r '.verdict')" "fits_gpu"
out=$(model_hub_tool hub_profile_draft '{"repo":"test/tiny-GGUF","quant":"Q8_0","ctx":4096,"name":"agent-pick"}')
assert_eq "$(jq -r '.profile.created_by' <<<"$out")" "george" "agent drafts are attributed"
assert_eq "$(jq -r '.status' <<<"$out")" "draft" "agent cannot produce approved profiles"
assert_contains "$(model_hub_tool hub_approve '{"name":"agent-pick"}')" "unknown hub tool" "no approve tool for the agent"
for t in hub_hw_probe hub_search hub_inspect hub_quant_fit hub_profile_draft hub_profiles; do
    assert_eq "$(jq -r --arg t "$t" '[.[] | select(.function.name==$t)] | length' "$LODGE_DIR/data/schemas/native_tools.json")" "1" "schema registered: $t"
done
names=$(LODGE_DIR="$LODGE_DIR" bash -c 'source "$LODGE_DIR/lib/tools/native_tools.sh" >/dev/null 2>&1; native_tools_resolve_profile model_hub | jq -r ".[].function.name"' | sort | tr '\n' ' ')
assert_contains "$names" "hub_quant_fit" "model_hub profile mounts hub tools"
assert_not_contains "$names" "bash_exec" "model_hub profile has no shell"
assert_not_contains "$names" "file_write" "model_hub profile has no file writes"
assert_contains "$(grep -c 'tool_filter:-}" = "model_hub"' "$LODGE_DIR/lib/core/react.sh")" "1" "strict tool mounting enforced for model_hub"

describe "/models routing"
out=$(bash -c 'source "$LODGE_DIR/commands/models.sh"; cmd_models "quants huggingface test/tiny-GGUF --ctx 4096"' 2>&1)
assert_contains "$out" "best GPU fit: Q8_0" "/models quants"
out=$(bash -c 'source "$LODGE_DIR/commands/models.sh"; cmd_models "profiles"' 2>&1)
assert_contains "$out" "tiny-q4	installed" "/models profiles"
assert_contains "$(bash -c 'source "$LODGE_DIR/commands/models.sh"; cmd_models "help"')" "/models ask" "help lists copilot"

describe "activation dry-run (no containers touched)"
printf 'TIER1_URL="http://x"\nTIER1_MODEL="old"\nTIER1_CONTEXT=1\n' > "$S/g/endpoints.conf"
out=$(bash "$LODGE_DIR/scripts/inference/activate_profile.sh" tiny-q4 --dry-run --runtime native 2>&1)
assert_contains "$out" "ENV: LLAMA_ARG_MODEL=$S/models/hub/huggingface/test/tiny-GGUF/tiny-Q4_K_M.gguf" "native env uses host path"
assert_contains "$out" "TIER1_CONTEXT=8192" "Tier 1 context retargeted (re-approved 8192 profile)"
assert_contains "$out" "DRY-RUN complete" "dry-run finishes"
assert_contains "$(cat "$S/g/endpoints.conf")" 'TIER1_MODEL="old"' "dry-run leaves endpoints.conf untouched"
assert_file_not_exists "$S/g/models/active.env"
assert_contains "$(bash "$LODGE_DIR/scripts/inference/activate_profile.sh" agent-pick --dry-run 2>&1)" "not installed" "draft cannot be activated"
assert_contains "$(bash "$LODGE_DIR/scripts/inference/activate_profile.sh" 'x;rm' --dry-run 2>&1)" "usage" "profile name validated"

describe "local adapters (LoRA / control vectors): attach resets approval, verified at install, passed as CLI args"
mkdir -p "$S/train"
{ printf 'GGUF'; head -c 4096 /dev/urandom; } > "$S/train/my-lora.gguf"
{ printf 'GGUF'; head -c 2048 /dev/urandom; } > "$S/train/calm.gguf"
printf 'not a gguf' > "$S/train/fake.gguf"
assert_contains "$(MH attach tiny-q4 lora "$S/train/fake.gguf")" "not a GGUF file" "non-GGUF rejected"
assert_contains "$(MH attach tiny-q4 lora "$S/train/my-lora.gguf" --scale 9)" "scale" "out-of-range scale rejected"
MH attach tiny-q4 vector "$S/train/my-lora.gguf" >/dev/null
assert_contains "$(cat "$S/stderr.log")" "invalid choice" "unknown role rejected"
out=$(MH attach tiny-q4 lora "$S/train/my-lora.gguf" --scale 0.8)
assert_eq "$(jq -r '.status' <<<"$out")" "draft" "attach resets profile to draft"
assert_file_exists "$S/models/adapters/my-lora.gguf"
assert_eq "$(jq -r '.adapters[0].sha256' "$pf")" "$(sha256sum "$S/train/my-lora.gguf" | cut -c1-64)" "adapter sha pinned"
MH attach tiny-q4 control_vector "$S/train/calm.gguf" --scale -0.5 >/dev/null
assert_eq "$(jq -r '.adapters | length' "$pf")" "2" "two adapters attached"
assert_contains "$(MH install tiny-q4)" "not approved" "attached profile needs re-approval"
MH approve tiny-q4 >/dev/null
n_before=$(wc -l < "$S/req.log")
out=$(MH install tiny-q4)
assert_eq "$(jq -r '.name' <<<"$out")" "tiny-q4" "install verifies local adapters"
assert_eq "$(wc -l < "$S/req.log")" "$n_before" "adapters need no network"
args=$(MH args tiny-q4 --native)
assert_contains "$args" "--lora-scaled" "lora passed as CLI arg (llama.cpp has no env var for it)"
assert_contains "$args" "$S/models/adapters/my-lora.gguf:0.8" "lora host path + scale"
assert_contains "$args" "$S/models/adapters/calm.gguf:-0.5" "control vector host path + scale"
assert_contains "$(MH args tiny-q4)" "/models/adapters/my-lora.gguf:0.8" "container path for docker"
assert_eq "$(MH env tiny-q4 | jq -r 'has("LLAMA_ARG_LORA")')" "false" "no ignored LLAMA_ARG_LORA env"
out=$(bash "$LODGE_DIR/scripts/inference/activate_profile.sh" tiny-q4 --dry-run --runtime native 2>&1)
assert_contains "$out" "--control-vector-scaled" "activation passes adapter args"
printf 'x' >> "$S/models/adapters/my-lora.gguf"
assert_contains "$(MH install tiny-q4)" "sha256 mismatch" "tampered adapter rejected at install"
assert_contains "$(MH args tiny-q4)" "sha256 mismatch" "tampered adapter blocks activation"
out=$(MH detach tiny-q4 my-lora.gguf)
assert_eq "$(jq -r '[.adapters[].path] | join(",")' <<<"$out")" "calm.gguf" "detach removes adapter"
assert_eq "$(jq -r '.status' <<<"$out")" "draft" "detach resets approval"

describe "local library: scan classifies the operator's own GGUFs from their metadata"
G="$LODGE_DIR/tests/helpers/make_gguf.py"
L="$S/models/mine"; mkdir -p "$L/sub" "$L/.hidden" "$L/repo.git" "$S/models/active" "$S/outside"
python3 "$G" "$L/my-model-Q4_K_M.gguf" --base-repo-url "https://huggingface.co/acme/base-7b" --temp 0.6
python3 "$G" "$L/sub/style-lora.gguf" --type adapter --pad 1000
python3 "$G" "$L/mmproj-my-F16.gguf" --arch clip --type mmproj --pad 5000
python3 "$G" "$L/mtp-my-Q4_0.gguf" --layers 1 --pad 5000
python3 "$G" "$L/.hidden/secret.gguf" --pad 100
python3 "$G" "$L/repo.git/vendored.gguf" --pad 100
python3 "$G" "$S/outside/escape.gguf" --pad 100
printf 'GGUF\x03\x00' > "$L/broken.gguf"
ln -sf ../mine/my-model-Q4_K_M.gguf "$S/models/active/current.gguf"
ln -sf "$S/outside/escape.gguf" "$L/escape.gguf"
ln -sf "$L/nope.gguf" "$L/dangling.gguf"
lib=$(MH library)
sel() { jq -r --arg r "$1" ".entries[] | select(.rel==\$r) | $2" <<<"$lib"; }
assert_eq "$(sel mine/my-model-Q4_K_M.gguf .kind)" "model" "full model classified"
assert_eq "$(sel mine/sub/style-lora.gguf .kind)" "adapter" "adapter classified from general.type"
assert_eq "$(sel mine/mmproj-my-F16.gguf .kind)" "mmproj" "projector classified"
assert_eq "$(sel mine/mtp-my-Q4_0.gguf .kind)" "draft" "draft classified from file name"
assert_contains "$(sel mine/broken.gguf .error)" "" "broken file listed"
assert_not_contains "$(jq -r '.entries[].rel' <<<"$lib")" "secret.gguf" "hidden dirs skipped"
assert_not_contains "$(jq -r '.entries[].rel' <<<"$lib")" "vendored.gguf" ".git dirs skipped"
assert_not_contains "$(jq -r '.entries[].rel' <<<"$lib")" "dangling" "dangling symlink ignored"
assert_eq "$(sel mine/my-model-Q4_K_M.gguf '.aliases | join(",")')" "active/current.gguf" "symlink folded into aliases"
assert_eq "$(sel mine/my-model-Q4_K_M.gguf .base_model)" "acme/base-7b" "base model from GGUF metadata"
assert_eq "$(sel mine/my-model-Q4_K_M.gguf .sampling.temperature)" "0.6" "sampling from GGUF metadata"
assert_eq "$(sel hub/huggingface/test/tiny-GGUF/tiny-Q4_K_M.gguf '.profiles[0].name')" "tiny-q4" "profile refs attached"
assert_eq "$(jq -r '[.entries[] | select(.file=="escape.gguf")][0].inside' <<<"$lib")" "false" "escaping symlink flagged as outside"
assert_file_exists "$S/g/models/library_cache.json"

describe "fit-local: boundary checks + kind guard + kv options"
assert_contains "$(MH fit-local ../outside/escape.gguf)" "relative .gguf path" "traversal rejected"
assert_contains "$(MH fit-local mine/escape.gguf)" "outside the models directory" "escaping symlink rejected"
assert_contains "$(MH fit-local mine/sub/style-lora.gguf)" "is an adapter" "adapters cannot be served alone"
fl=$(MH fit-local mine/my-model-Q4_K_M.gguf --ctx 4096 --mmproj mine/mmproj-my-F16.gguf)
assert_eq "$(jq -r '.verdict' <<<"$fl")" "fits_gpu"
assert_eq "$(jq -r '.kv_options | map(.kv) | join(",")' <<<"$fl")" "f16,q8_0,q4_0" "kv cache options offered"
assert_contains "$(MH fit-local mine/my-model-Q4_K_M.gguf --mmproj mine/mtp-my-Q4_0.gguf)" "not a mmproj" "aux kind checked"

describe "import-local: pin in place (no network, no sidecars), approve, serve"
: > "$S/req.log"
imp=$(MH import-local mine/my-model-Q4_K_M.gguf --ctx 4096 --mmproj mine/mmproj-my-F16.gguf --draft mine/mtp-my-Q4_0.gguf --name mine-q4)
assert_eq "$(jq -r '.status' <<<"$imp")" "draft" "import creates an operator draft"
lp="$S/g/models/profiles/mine-q4.json"
assert_eq "$(jq -r '.source.provider' "$lp")" "local"
assert_eq "$(jq -r '.files | map(.role) | join(",")' "$lp")" "model,mmproj,draft"
assert_eq "$(jq -r '.files[0].sha256' "$lp")" "$(sha256sum "$L/my-model-Q4_K_M.gguf" | cut -c1-64)" "sha pinned"
assert_eq "$(jq -r '.sampling.temperature' "$lp")" "0.6" "sampling carried from metadata"
assert_eq "$(jq -r '.server.draft_max' "$lp")" "8" "draft enables speculative decoding"
assert_eq "$(MH progress mine-q4 | jq -r '.kind')" "import" "import tracked as a job"
assert_contains "$(MH install mine-q4)" "not approved" "local imports still need approval"
MH approve mine-q4 >/dev/null
assert_eq "$(MH install mine-q4 | jq -r '.name')" "mine-q4" "local install verifies in place"
assert_eq "$(wc -l < "$S/req.log" | tr -d ' ')" "0" "no network requests for local models"
assert_file_not_exists "$L/my-model-Q4_K_M.gguf.sha256"
assert_eq "$(MH env mine-q4 | jq -r '.LLAMA_ARG_MODEL')" "/models/mine/my-model-Q4_K_M.gguf" "container path under /models"
assert_contains "$(MH jobs)" "mine-q4" "jobs lists the import"
assert_eq "$(MH import-local mine/my-model-Q4_K_M.gguf --ctx 2048 --name mine-fast --approve | jq -r '.status')" "installed" "--approve installs in one step"
out=$(bash "$LODGE_DIR/scripts/inference/activate_profile.sh" mine-q4 --dry-run --runtime native 2>&1)
assert_contains "$out" "ENV: LLAMA_ARG_MODEL=$S/models/mine/my-model-Q4_K_M.gguf" "native activation uses host path"
assert_contains "$out" "DRY-RUN complete"
assert_contains "$(MH import-local mine/sub/style-lora.gguf)" "is an adapter" "adapter import refused"
assert_contains "$(MH import-local mine/my-model-Q4_K_M.gguf --name 'Bad Name')" "invalid profile name" "name validated"

describe "tune: allow-listed keys only, null removes, no-op keeps approval"
out=$(MH tune mine-q4 <<<'{"sampling":{"temperature":0.3,"top_k":20}}')
assert_eq "$(jq -r '.sampling.temperature' <<<"$out")" "0.3"
assert_eq "$(jq -r '.status' <<<"$out")" "draft" "tuning resets approval"
assert_contains "$(MH tune mine-q4 <<<'{"server":{"model":"/etc/shadow"}}')" "not an allowed key" "smuggled flag rejected"
assert_contains "$(MH tune mine-q4 <<<'{"files":[]}')" "tune expects" "only server/sampling editable"
out=$(MH tune mine-q4 <<<'{"sampling":{"top_k":null}}')
assert_eq "$(jq -r '.sampling | has("top_k")' <<<"$out")" "false" "null removes a key"
MH approve mine-q4 >/dev/null
assert_eq "$(MH tune mine-q4 <<<'{"sampling":{"temperature":0.3}}' | jq -r '.status')" "approved" "no-op edit keeps approval"

describe "attach --from-library + delete-file safety"
out=$(MH attach mine-q4 lora mine/sub/style-lora.gguf --from-library --scale 0.5)
assert_eq "$(jq -r '.adapters[0].path' <<<"$out")" "style-lora.gguf" "library adapter attached"
assert_file_exists "$S/models/adapters/style-lora.gguf"
assert_contains "$(MH attach mine-q4 lora ../outside/escape.gguf --from-library)" "relative .gguf path" "library attach boundary-checked"
assert_contains "$(MH delete-file mine/my-model-Q4_K_M.gguf)" "in use by profile" "in-use file protected"
out=$(MH delete-file active/current.gguf)
assert_contains "$out" "symlink only" "symlink delete leaves target"
assert_file_exists "$L/my-model-Q4_K_M.gguf"
assert_eq "$(MH delete-file mine/broken.gguf | jq -r '.deleted[0]')" "mine/broken.gguf" "unused file deleted"
assert_file_not_exists "$L/broken.gguf"

describe "server-status reads the live llama-server (truthful 'now serving')"
mkdir -p "$S/models/active"; ln -sfn ../mine/my-model-Q4_K_M.gguf "$S/models/active/current.gguf"
printf 'TIER1_URL="http://127.0.0.1:%s"\nTIER1_MODEL="x"\n' "$PORT" > "$S/g/endpoints.conf"
st=$(MH server-status)
assert_eq "$(jq -r '.endpoints[0].ok' <<<"$st")" "true" "health reachable"
assert_eq "$(jq -r '.endpoints[0].n_ctx' <<<"$st")" "4096" "real n_ctx from /props"
assert_eq "$(jq -r '.endpoints[0].model_rel' <<<"$st")" "mine/my-model-Q4_K_M.gguf" "container path mapped to library file"

describe "operator presets (optional, validated, argv-only)"
assert_eq "$(MH presets | jq -r '.configured')" "false" "no presets shipped"
cat > "$S/g/models/presets.json" <<'EOF'
{"presets":[{"id":"rb","label":"Rollback","script":"scripts/inference/activate_profile.sh","args":["--dry-run","--rollback"]},
 {"id":"evil","script":"/bin/sh","args":["-c","id"]},{"id":"inj","script":"scripts/inference/activate_profile.sh","args":["x;rm"]}]}
EOF
pr=$(MH presets)
assert_eq "$(jq -r '.presets | map(.id) | join(",")' <<<"$pr")" "rb" "only valid presets listed"
assert_eq "$(jq -r '.errors | length' <<<"$pr")" "2" "bad script + bad args reported"
assert_contains "$(MH preset-run evil)" "no preset" "invalid preset cannot run"
rr=$(MH preset-run rb)
assert_eq "$(jq -r '.ok' <<<"$rr")" "false"
assert_contains "$(jq -r '.stderr' <<<"$rr")" "nothing to roll back" "preset ran with argv"
rm -f "$S/g/models/presets.json"

describe "fine-tuning: datasets, hub dataset pull (sha-verified), training kit"
mkdir -p "$S/g/datasets/lora_x"
printf '{"messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"yo"}]}\n%.0s' 1 2 3 > "$S/g/datasets/lora_x/train.jsonl"
ds=$(MH datasets)
assert_eq "$(jq -r '.datasets[] | select(.id=="exports:lora_x/train.jsonl") | .rows' <<<"$ds")" "3" "export dataset listed with rows"
assert_eq "$(jq -r '.datasets[] | select(.id=="exports:lora_x/train.jsonl") | .format' <<<"$ds")" "chat" "chat format detected"
assert_eq "$(MH dataset-files test/ds | jq -r '.files | length')" "2" "hub dataset files listed"
mkdir -p "$S/lodge"
pl=$(LODGE_DIR="$S/lodge" timeout 60 python3 "$LODGE_DIR/lib/tools/model_hub_cli.py" dataset-pull test/ds data/train.jsonl 2>"$S/stderr.log")
assert_eq "$(jq -r '.verified' <<<"$pl")" "true" "lfs sha verified"
assert_eq "$(jq -r '.rows' <<<"$pl")" "3"
assert_file_exists "$S/lodge/data/training/active/test__ds__data_train.jsonl"
assert_contains "$(MH dataset-pull test/ds ../../etc/passwd)" "not a dataset file" "unlisted path refused"
assert_contains "$(MH train-kit <<<'{"name":"k1","base_model":"../x","train":"exports:lora_x/train.jsonl"}')" "base_model" "base repo validated"
assert_contains "$(MH train-kit <<<'{"name":"k1","base_model":"acme/base-7b","train":"exports:../../etc/passwd"}')" "dataset" "dataset id boundary"
kit=$(MH train-kit <<<'{"name":"k1","base_model":"acme/base-7b","train":"exports:lora_x/train.jsonl","lora_r":8}')
assert_eq "$(jq -r '.config.lora_r' <<<"$kit")" "8"
assert_file_exists "$S/g/training/kits/k1/train_lora.py"
assert_file_exists "$S/g/training/kits/k1/run.sh"
assert_eq "$(MH kits | jq -r '.[0].name')" "k1" "kits listed"

describe "agent: hub_library tool + schema"
source "$LODGE_DIR/lib/tools/model_hub.sh"
assert_contains "$(model_hub_tool hub_library '{}')" "my-model-Q4_K_M.gguf" "agent can see the library"
assert_eq "$(jq -r '[.[] | select(.function.name=="hub_library")] | length' "$LODGE_DIR/data/schemas/native_tools.json")" "1" "schema registered: hub_library"
assert_file_not_exists "$LODGE_DIR/config/models/catalog.json"

test_end
