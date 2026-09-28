#!/usr/bin/env bash
# launch_3track_training.sh:
# Orchestrates 3 parallel or sequential GRPO runs (Track 1, Track 2, Track 3)
# Each runs 40 steps with -np 12 / G=12, produces its own GGUF adapter,
# and performs comprehensive milestone checkpointing.

set -euo pipefail

WORKSPACE_DIR="/home/wsl-ops/blue-lodge"
MODELS_DIR="/home/wsl-ops/models/frontier_qwen38"
PYTHON_BIN="/home/wsl-ops/venv_research/bin/python"
ENDPOINT="${1:-http://127.0.0.1:8080}"

echo "================================================================================"
echo "  Blue Lodge 3-Track Fleet GRPO Reinforcement Launcher"
echo "  Endpoint: ${ENDPOINT}"
echo "  Group Size: 12 (-np 12 / G=12) | Steps: 40 | Checkpoint Interval: 10"
echo "================================================================================"

# Track 1: Syntax & Strict Schema Integrity
echo ""
echo "[*] Launching Track 1: Tool Syntax & Schema Integrity (5,730 samples)..."
mkdir -p "${MODELS_DIR}/checkpoints_syntax"
"${PYTHON_BIN}" "${WORKSPACE_DIR}/scripts/colab_training/train_blue_lodge_grpo.py" \
  --curriculum "${WORKSPACE_DIR}/data/training/curriculum_track1_syntax.jsonl" \
  --steps 40 \
  --group_size 12 \
  --parallel 12 \
  --rank 12 \
  --alpha 16.0 \
  --endpoint "${ENDPOINT}" \
  --ckpt_dir "${MODELS_DIR}/checkpoints_syntax" \
  --output "${MODELS_DIR}/Blue-Llama-27B-Champion-v5-LoRA-Syntax.gguf"

# Track 2: GitOps & Safe File Lifecycle
echo ""
echo "[*] Launching Track 2: GitOps & Safe File Lifecycle (3,550 samples)..."
mkdir -p "${MODELS_DIR}/checkpoints_gitops"
"${PYTHON_BIN}" "${WORKSPACE_DIR}/scripts/colab_training/train_blue_lodge_grpo.py" \
  --curriculum "${WORKSPACE_DIR}/data/training/curriculum_track2_git_ops.jsonl" \
  --steps 40 \
  --group_size 12 \
  --parallel 12 \
  --rank 12 \
  --alpha 16.0 \
  --endpoint "${ENDPOINT}" \
  --ckpt_dir "${MODELS_DIR}/checkpoints_gitops" \
  --output "${MODELS_DIR}/Blue-Llama-27B-Champion-v5-LoRA-GitOps.gguf"

# Track 3: Software Phytology Protocol
echo ""
echo "[*] Launching Track 3: Software Phytology Protocol (3,550 samples)..."
mkdir -p "${MODELS_DIR}/checkpoints_phytology"
"${PYTHON_BIN}" "${WORKSPACE_DIR}/scripts/colab_training/train_blue_lodge_grpo.py" \
  --curriculum "${WORKSPACE_DIR}/data/training/curriculum_track3_phytology.jsonl" \
  --steps 40 \
  --group_size 12 \
  --parallel 12 \
  --rank 12 \
  --alpha 16.0 \
  --endpoint "${ENDPOINT}" \
  --ckpt_dir "${MODELS_DIR}/checkpoints_phytology" \
  --output "${MODELS_DIR}/Blue-Llama-27B-Champion-v5-LoRA-Phytology.gguf"

echo ""
echo "================================================================================"
echo "[✓] All 3 GRPO Training Tracks Completed Successfully!"
echo "    Track 1: ${MODELS_DIR}/Blue-Llama-27B-Champion-v5-LoRA-Syntax.gguf"
echo "    Track 2: ${MODELS_DIR}/Blue-Llama-27B-Champion-v5-LoRA-GitOps.gguf"
echo "    Track 3: ${MODELS_DIR}/Blue-Llama-27B-Champion-v5-LoRA-Phytology.gguf"
echo "================================================================================"

# Execute Iteration 5 Fusion
echo ""
echo "[*] Fusing Adapters into Blue-Llama-27B-Champion-v5-Iteration5-Fused-LoRA.gguf..."
"${PYTHON_BIN}" "${WORKSPACE_DIR}/scripts/colab_training/fuse_iteration5.py" \
  --models_dir "${MODELS_DIR}"

echo ""
echo "[✓] Pipeline fully concluded!"
