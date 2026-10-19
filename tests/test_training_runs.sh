#!/usr/bin/env bash
# Training-run manager (scripts/training/runs.py): spec validation, preflight, local driver end-to-end with a
# stub trainer/converter, loss parsing, merge-to-adapters, colab bundle planning, cancel. Hermetic: no torch,
# no GPU, no network, never calls the colab CLI.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"
LODGE_DIR="$GEORGE_TEST_REPO"; export LODGE_DIR

test_start "training runs"

S="$GEORGE_TEST_SANDBOX/runs"; G="$S/g"; M="$S/models"
mkdir -p "$G/datasets/f1" "$S/base" "$S/llama" "$M"
echo '{"model_type":"stub"}' >"$S/base/config.json"
printf '%s\n' '{"messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"hello"}]}' \
  >"$G/datasets/f1/sft_train.jsonl"
printf '%s\n' '{"prompt":"p","chosen":"a","rejected":"b"}' >"$G/datasets/f1/dpo_train.jsonl"

# Stub "training python": answers the preflight probe, fakes a TRL run, fakes llama.cpp conversion.
cat >"$S/py" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-c" ]; then echo "2 0.0-stub"; exit 0; fi
case "$1" in
  *convert_lora_to_gguf.py)
    while [ $# -gt 0 ]; do [ "$1" = "--outfile" ] && { echo GGUF >"$2"; exit 0; }; shift; done; exit 2 ;;
  train_lora.py)
    mkdir -p output/adapter
    echo "{'loss': 0.9, 'grad_norm': 1.0, 'learning_rate': 0.0001, 'epoch': 0.5}"
    echo "{'loss': 0.42, 'grad_norm': 1.0, 'learning_rate': 0.0001, 'epoch': 1.0}"
    echo "{'eval_loss': 0.61, 'epoch': 1.0}"
    exit 0 ;;
esac
exit 3
EOF
chmod +x "$S/py"
echo "# stub" >"$S/llama/convert_lora_to_gguf.py"

spec() {  # name backend method dataset [extra-json]
  jq -n --arg n "$1" --arg b "$2" --arg m "$3" --arg d "$4" --arg py "$S/py" --arg base "$S/base" \
     --arg ll "$S/llama" --argjson x "${5:-{\}}" \
     '{name:$n, backend:$b, base_model:"org/base", base_hf_path:$base, train_python:$py, llama_cpp_dir:$ll,
       tracks:[{name:"t1", method:$m, train:$d, gpu:0}], hyper:{epochs:1}, merge:{method:"none"}} * $x' \
     >"$S/$1.json"
  echo "$S/$1.json"
}
R() { env -u GEORGE_DIR GEORGE_DIR="$G" MODELS_DIR="$M" COLAB_BIN="$S/no-colab" timeout 60 \
        python3 "$LODGE_DIR/scripts/training/runs.py" "$@" 2>>"$S/err.log" | tail -1; }

describe "spec validation"
assert_contains "$(R plan "$(spec 'Bad Name' local sft exports:f1/sft_train.jsonl)")" "name" "bad run name rejected"
assert_contains "$(R plan "$(spec v1 local sft exports:../etc/passwd)")" "dataset" "dataset traversal rejected"
assert_contains "$(R plan "$(spec v2 local sft exports:f1/missing.jsonl)")" "not found" "missing dataset rejected"
assert_contains "$(R plan "$(spec v3 local rlhf exports:f1/sft_train.jsonl)")" "method" "unknown method rejected"
assert_contains "$(R plan "$(spec v4 local sft exports:f1/sft_train.jsonl '{"merge":{"method":"svd","weights":[-1]}}')")" \
  "weights" "negative merge weight rejected"
assert_contains "$(R plan "$(spec v5 local sft exports:f1/sft_train.jsonl '{"hyper":{"learning_rate":5}}')")" \
  "learning_rate" "out-of-range hyper rejected"
assert_contains "$(R status ../../etc)" "run name" "status name validated"

describe "preflight"
p=$(R plan "$(spec ok1 local sft exports:f1/sft_train.jsonl)")
assert_eq "$(jq -r '.valid' <<<"$p")" "true" "valid spec"
assert_eq "$(jq -r '.info.cuda_devices' <<<"$p")" "2" "probe reads training env"
assert_eq "$(jq -r '.errors | length' <<<"$p")" "0" "no preflight errors"
p=$(R plan "$(spec ok2 local dpo exports:f1/sft_train.jsonl)")
assert_contains "$(jq -r '.errors[]' <<<"$p")" "prompt/chosen/rejected" "DPO on SFT rows is an error"
p=$(R plan "$(spec ok3 local sft exports:f1/sft_train.jsonl '{"train_python":"/nonexistent/python"}')")
assert_contains "$(jq -r '.errors[]' <<<"$p")" "train_python" "missing training env is an error"
assert_contains "$(R start "$S/ok3.json")" "preflight failed" "local start blocked by preflight errors"

describe "local dry run"
d=$(R start "$(spec dry1 local sft exports:f1/sft_train.jsonl)" --dry-run)
assert_eq "$(jq -r '.state' <<<"$d")" "planned" "dry run only plans"
assert_file_exists "$G/training/runs/dry1/driver.sh" "driver written"
assert_file_exists "$G/training/runs/dry1/tracks/t1/config.json" "track config written"
assert_file_exists "$G/training/runs/dry1/tracks/t1/train_lora.py" "kit copied"
assert_contains "$(cat "$G/training/runs/dry1/driver.sh")" 'CUDA_VISIBLE_DEVICES="$g"' "track pinned to its GPU"
assert_contains "$(R start "$S/dry1.json" --dry-run)" "already exists" "run names are unique"

describe "local run end-to-end (stub trainer)"
s=$(R start "$(spec e2e local sft exports:f1/sft_train.jsonl)")
assert_eq "$(jq -r '.state' <<<"$s")" "running" "run launched"
for _ in $(seq 1 50); do
  [ "$(cat "$G/training/runs/e2e/state" 2>/dev/null)" = "done" ] && break; sleep 0.2
done
st=$(R status e2e)
assert_eq "$(jq -r '.state' <<<"$st")" "done" "run finished"
assert_eq "$(jq -r '.tracks.t1.state' <<<"$st")" "done" "track finished"
assert_eq "$(jq -r '.tracks.t1.loss' <<<"$st")" "0.42" "last training loss parsed"
assert_eq "$(jq -r '.tracks.t1.eval_loss' <<<"$st")" "0.61" "eval loss parsed"
m=$(R merge e2e)
assert_eq "$(jq -r '.outputs | length' <<<"$m")" "1" "adapter converted and published"
assert_contains "$(jq -r '.outputs[0]' <<<"$m")" "$M/adapters/e2e-t1-" "lands in MODELS_DIR/adapters"
assert_contains "$(jq -c '.' <<<"$(R list)")" '"name":"e2e"' "run listed"

describe "merge when conversion is impossible"
s=$(R start "$(spec noconv local sft exports:f1/sft_train.jsonl '{"base_hf_path":"/nonexistent"}')" --force)
for _ in $(seq 1 50); do
  [ "$(cat "$G/training/runs/noconv/state" 2>/dev/null)" = "done" ] && break; sleep 0.2
done
assert_contains "$(R merge noconv)" "cannot convert" "missing base/converter explained"

describe "colab planning (never executes without --execute)"
c=$(R start "$(spec col1 colab dpo exports:f1/dpo_train.jsonl)")
assert_eq "$(jq -r '.state' <<<"$c")" "planned" "colab start defaults to plan-only"
assert_file_exists "$G/training/runs/col1/tracks/t1/bundle.tar.gz" "per-track bundle built"
assert_contains "$(tar -tzf "$G/training/runs/col1/tracks/t1/bundle.tar.gz")" "train.jsonl" "dataset in bundle"
assert_eq "$(jq -r '.plan[0].steps | map(.do) | join(",")' <"$G/training/runs/col1/run.json")" \
  "new,upload,launch" "provision/upload/launch plan"

describe "cancel"
assert_eq "$(jq -r '.state' <<<"$(R cancel dry1)")" "cancelled" "cancel marks the run"
assert_eq "$(jq -r '.state' <<<"$(R status dry1)")" "cancelled" "status reflects cancel"

test_end
