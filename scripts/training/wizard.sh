#!/usr/bin/env bash
# scripts/training/wizard.sh — Interactive JSON Playbook Wizard for runs.py
set -euo pipefail

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PY="$LODGE_DIR/.venv/bin/python3"
[ ! -x "$PY" ] && PY="python3"

echo "═══════════════════════════════════════════════════════════════"
echo "  BLUE LODGE // SOVEREIGN TRAINING & SVD-32 PLAYBOOK WIZARD"
echo "═══════════════════════════════════════════════════════════════"
read -rp "Run name [gemma4-sleep-v1]: " RUN_NAME
RUN_NAME="${RUN_NAME:-gemma4-sleep-v1}"
read -rp "Role [core-agent | sdr-p25 | code-ops]: " ROLE
ROLE="${ROLE:-core-agent}"
read -rp "Base HF model [google/gemma-4-31b-it]: " BASE_MODEL
BASE_MODEL="${BASE_MODEL:-google/gemma-4-31b-it}"
read -rp "Backend [colab | local]: " BACKEND
BACKEND="${BACKEND:-colab}"
read -rp "Prior active.gguf retention weight (0.0-0.95) [0.70]: " PRIOR_W
PRIOR_W="${PRIOR_W:-0.70}"

echo "[*] Forging fresh leak-guarded dataset from local transcripts (persistence + multi-hop + tool-syntax + error-recovery)..."
MANIFEST=$("$PY" "$LODGE_DIR/scripts/training/forge.py" build --focus persistence,multi-hop,tool-syntax,error-recovery,failure-modes --count 600 --include-journal | tail -n 1)
SFT_ID=$(printf '%s' "$MANIFEST" | jq -r '.ids.sft_train // empty')
SFT_VAL=$(printf '%s' "$MANIFEST" | jq -r '.ids.sft_val // empty')
DPO_ID=$(printf '%s' "$MANIFEST" | jq -r '.ids.dpo_train // empty')
DPO_VAL=$(printf '%s' "$MANIFEST" | jq -r '.ids.dpo_val // empty')

OUT_JSON="$LODGE_DIR/configs/playbooks/${RUN_NAME}.json"
mkdir -p "$(dirname "$OUT_JSON")"
jq -n \
  --arg name "$RUN_NAME" --arg role "$ROLE" --arg base "$BASE_MODEL" --arg backend "$BACKEND" \
  --arg sft "$SFT_ID" --arg sftv "$SFT_VAL" --arg dpo "$DPO_ID" --arg dpov "$DPO_VAL" \
  --argjson pw "$PRIOR_W" \
  '{
    name: $name, role: $role, backend: $backend, base_model: $base, base_source: "hf_direct",
    tracks: (
      (if $sft != "" then [{name:"sft-core", method:"sft", train:$sft, val:(if $sftv != "" then $sftv else null end), gpu:0}] else [] end) +
      (if $dpo != "" then [{name:"dpo-persistence", method:"dpo", train:$dpo, val:(if $dpov != "" then $dpov else null end), gpu:0}] else [] end)
    ),
    hyper: {epochs:2, learning_rate:0.0001, lora_r:32, lora_alpha:64, lora_dropout:0.05, max_seq_len:4096, batch_size:1, grad_accum:8, dpo_beta:0.1, save_steps:40, load_in_4bit:true, use_unsloth:true},
    merge: {method:"svd", target_rank:32, prior_adapter_weight:$pw, weights:null},
    colab: {auth:"adc", gpu:"A100", gpu_fallback:["H100","G4","A100","L4","T4"], min_gpu_vram_gb:24, high_mem:true, max_concurrent_sessions:3, min_cu_balance:150, max_runtime_min:180, drive_checkpoints:true, export_gguf_on_colab:true},
    local: {pause_inference:true}
  }' > "$OUT_JSON"

echo "[✓] Wrote JSON playbook -> $OUT_JSON"
echo "[*] Running preflight check..."
"$PY" "$LODGE_DIR/scripts/training/runs.py" plan "$OUT_JSON" | jq '{valid, errors, warnings, colab_gpu_fallback: .info.colab_gpu_fallback}'
echo "Launch when ready: lodge /train run $OUT_JSON --execute"
