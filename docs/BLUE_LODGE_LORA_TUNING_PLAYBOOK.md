# Blue Lodge Sovereign LoRA Fine-Tuning Playbook

**Author:** Blue Lodge Sovereign Research Group  
**Target Architecture:** Blue-Llama-27B-Champion-v5 (52 Layers: 13 Attention Highway, 39 Mamba-2 SSM)  
**Target Adapters:** Rank-12 LoRA across 34 projection pairs (68 adapter tensors, zero phantom layers)  
**Dual Tracks:**  
1. **Cloud Track:** Google Colab A100-SXM4-80GB / H100 Fleet via `google-colab-cli`  
2. **Local Track:** Workstation Dual GPU (2x NVIDIA RTX 3060 12GB) & Local Distributed Inference Nodes  
**Date:** September 2026  

---

## Table of Contents
1. [Core Architectural & Mathematical Invariants](#1-core-architectural--mathematical-invariants)
2. [Track A: Google Colab Fleet Tuning (A100 / H100)](#2-track-a-google-colab-fleet-tuning-a100--h100)
   - [Authentication & Account Provisioning](#authentication--account-provisioning)
   - [Session Lifecycle & Automated Fleet Provisioning](#session-lifecycle--automated-fleet-provisioning)
   - [High-Throughput Parallel Rollouts ($G=12$, `-np 12`)](#high-throughput-parallel-rollouts-g12--np-12)
   - [Milestone Checkpointing & Checkpoint Synchronization](#milestone-checkpointing--checkpoint-synchronization)
   - [Clean Teardown to Conserve Compute Units](#clean-teardown-to-conserve-compute-units)
3. [Track B: Local Multi-Node Tuning (Dual RTX 3060 & Distributed LAN)](#3-track-b-local-multi-node-tuning-dual-rtx-3060--distributed-lan)
   - [Local Hardware Topography](#local-hardware-topography)
   - [Single-Slot Decode Invariant (`-np 1`)](#single-slot-decode-invariant--np-1)
   - [Multi-Node Endpoint Routing](#multi-node-endpoint-routing)
   - [Executing Local GRPO Validation](#executing-local-grpo-validation)
4. [Curriculum Partitioning & Synthetic Expansion](#4-curriculum-partitioning--synthetic-expansion)
   - [Track 1: Tool Syntax & Schema Integrity (5,700+ samples)](#track-1-tool-syntax--schema-integrity)
   - [Track 2: GitOps & Safe File Lifecycle (3,500+ samples)](#track-2-gitops--safe-file-lifecycle)
   - [Track 3: Software Phytology Protocol (3,500+ samples)](#track-3-software-phytology-protocol)
5. [Analytical Multi-LoRA Concatenation (Iteration 5 Fusion)](#5-analytical-multi-lora-concatenation-iteration-5-fusion)
   - [The Decoupled Multi-Adapter Invariant](#the-decoupled-multi-adapter-invariant)
   - [Exact Analytical Addition (`concat`)](#exact-analytical-addition-concat)
   - [Thin-QR Low-Rank SVD Truncation (`svd`)](#thin-qr-low-rank-svd-truncation-svd)
6. [Sovereign Benchmark (`BlueLodgeBench`) & Active Data Re-Engineering](#6-sovereign-benchmark-bluelodgebench--active-data-re-engineering)
   - [The 5 Sovereign Pillars](#the-5-sovereign-pillars)
   - [Empirical Baseline Findings](#empirical-baseline-findings)
   - [Automated Counter-Example Extraction Loop](#automated-counter-example-extraction-loop)
7. [Operational Command Reference & Cheatsheet](#7-operational-command-reference--cheatsheet)

---

## 1. Core Architectural & Mathematical Invariants

Every LoRA adapter trained for Blue Lodge must adhere strictly to the target hybrid architecture:

### 1.1 Layer Targeting (34 Projections, 68 Tensors)
Fine-tuning the 52-layer Champion-v5 model requires targeting exactly the Highway Attention layers and the Mamba-2 SSM layers:
- **Highway Attention Layers (8 layers):** `[15, 19, 23, 27, 31, 35, 47, 51]`
  - `blk.{l}.attn_output.weight`: In $6,144 \to$ Out $5,120$
  - `blk.{l}.ffn_down.weight`: In $17,408 \to$ Out $5,120$
- **Mamba-2 SSM Layers (6 layers):** `[16, 17, 18, 20, 21, 22]`
  - `blk.{l}.ffn_gate.weight`: In $5,120 \to$ Out $17,408$
  - `blk.{l}.ffn_up.weight`: In $5,120 \to$ Out $17,408$
  - `blk.{l}.ffn_down.weight`: In $17,408 \to$ Out $5,120$

$$\text{Total Tensors} = (8 \text{ layers} \times 2 \times 2) + (6 \text{ layers} \times 3 \times 2) = 32 + 36 = \mathbf{68\text{ adapter tensors}}$$

**Zero Phantom Layers Invariant:** Any adapter containing projections outside these 34 base names (such as unpruned attention layers or dense MLP layers) will cause runtime projection mismatches or silent degradation in `llama-server`.

### 1.2 Adapter Scaling & Rank
- **Individual Track Rank:** $r = 12$
- **Individual Track Alpha:** $\alpha = 16.0$
- **Base Adapter Size:** Exactly **$30.94\text{ MiB}$** per GGUF file.
- **AdamW Optimizer Learning Rate:** $\eta = 4 \times 10^{-4}$, weight decay $1 \times 10^{-4}$.

---

## 2. Track A: Google Colab Fleet Tuning (A100 / H100)

When Google Colab compute units are available (e.g. via Gemini Ultra subscriptions), training can be scaled across multiple high-performance cloud instances concurrently.

### 2.1 Authentication & Account Provisioning
The Colab CLI binary is installed at `/home/wsl-ops/venv_research/bin/colab`.
Verify credentials and compute unit balance:
```bash
/home/wsl-ops/venv_research/bin/colab --auth=adc usage
```

### 2.2 Session Lifecycle & Automated Fleet Provisioning
Colab Pro/Pro+ allows running up to 3 parallel GPU sessions. To provision 3 parallel A100 High-RAM sessions:
```bash
COLAB="/home/wsl-ops/venv_research/bin/colab --auth=adc"

# 1. Provision 3 parallel A100 sessions
$COLAB new -s blue-syntax --gpu A100 --high-mem
$COLAB new -s blue-gitops --gpu A100 --high-mem
$COLAB new -s blue-phytology --gpu A100 --high-mem

# 2. Verify all sessions are READY
$COLAB sessions
```

### 2.3 High-Throughput Parallel Rollouts ($G=12$, `-np 12`)
Because an A100-SXM4 has **80 GB of VRAM** and massive memory bandwidth ($2,039\text{ GB/s}$), `blue-llama-server` can run with `-np 12` parallel slots without degrading decode speed.

1. **Upload Payloads:**
   ```bash
   $COLAB upload -s blue-syntax data/training/curriculum_track1_syntax.jsonl /content/curriculum.jsonl
   $COLAB upload -s blue-syntax scripts/colab_training/train_blue_lodge_colab.py /content/train.py
   $COLAB upload -s blue-syntax data/training/native_core_tools.json /content/native_core_tools.json
   ```
2. **Dispatch Training:**
   ```bash
   echo 'import subprocess; p = subprocess.Popen(["python3", "/content/train.py", "--curriculum", "/content/curriculum.jsonl", "--steps", "40", "--group_size", "12", "--parallel", "12", "--output", "/content/output/Blue-Llama-27B-Champion-v5-LoRA-Syntax.gguf"], stdout=open("/content/train.log", "w"), stderr=subprocess.STDOUT); print(f"LAUNCHED PID: {p.pid}")' | $COLAB exec -s blue-syntax
   ```
3. **Rollout Concurrency:**
   For each prompt, `ThreadPoolExecutor(max_workers=12)` fires 12 simultaneous requests to `http://127.0.0.1:8088/v1/chat/completions`. On an A100, all 12 candidate completions return in **$< 12\text{ seconds}$**, enabling a full 40-step GRPO cycle in under 25 minutes.

### 2.4 Milestone Checkpointing & Checkpoint Synchronization
`train_blue_lodge_colab.py` saves milestone checkpoints to `/content/checkpoints/`:
- `step_010.gguf`, `step_020.gguf`, `step_030.gguf`, `step_040.gguf`
- `best_adapter.gguf` (dynamically updated whenever mean batch reward achieves a new peak)
- `optimizer_step_*.pt` and `optimizer.pt` (full AdamW moment vectors)

To monitor progress and download live checkpoints:
```bash
# Check remote status
echo 'import os; lines = open("/content/train.log").readlines() if os.path.exists("/content/train.log") else []; print("".join(lines[-5:]))' | $COLAB exec -s blue-syntax

# Download intermediate or best adapter
$COLAB download -s blue-syntax /content/checkpoints/best_adapter.gguf /home/wsl-ops/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-LoRA-Syntax.gguf
```

### 2.5 Clean Teardown to Conserve Compute Units
Immediately upon downloading the completed `.gguf` adapters, release the cloud VMs:
```bash
$COLAB stop -s blue-syntax
$COLAB stop -s blue-gitops
$COLAB stop -s blue-phytology
```

---

## 3. Track B: Local Multi-Node Tuning (Dual RTX 3060 & Distributed LAN)

When operating entirely on-premise without consuming cloud compute units, Blue Lodge uses workstation GPUs and local network endpoints.

### 3.1 Local Hardware Topography
Our primary workstation possesses **2x NVIDIA RTX 3060 12GB**:
- **GPU 1 (Tier 1 Inference Server):** Hosts `Blue-Llama-27B-Champion-v5-Internal-MTP-Calibrated.gguf` on port `8080`.
- **GPU 0 (Tier 2 Multimodal Server / Background Worker):** Hosts vision worker or secondary model on port `18080`.
- **Additional LAN Nodes:** Any host running an OpenAI-compatible completion server (e.g. `http://192.168.1.150:8080`).

### 3.2 Single-Slot Decode Invariant (`-np 1`)
On consumer GPUs with $360\text{ GB/s}$ memory bandwidth (RTX 3060 / 4060):
- Running `-np > 1` divides memory bandwidth across concurrent streams, slowing decode from $30\text{ tok/s}$ to $< 14\text{ tok/s}$.
- Therefore, local inference nodes run with **`-np 1`**.
- Local GRPO uses **$G=2$ to $G=4$** sequential rollouts per step. Each step takes $\sim 45\text{ seconds}$, completing a 40-step validation run in $\sim 30\text{ minutes}$.

### 3.3 Multi-Node Endpoint Routing
Because local training submits standard HTTP JSON requests, you can distribute training runs across multiple local nodes:

```bash
PYTHON="/home/wsl-ops/projects/research/unity_of_one/.venv/bin/python"

# Run 1: Bound to Local GPU 1 (Port 8080)
$PYTHON scripts/colab_training/train_blue_lodge_grpo.py \
  --curriculum data/training/curriculum_track1_syntax.jsonl \
  --steps 40 --group_size 2 --rank 12 --alpha 16.0 \
  --endpoint http://127.0.0.1:8080 \
  --output /home/wsl-ops/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-LoRA-Syntax.gguf &

# Run 2: Bound to Local GPU 0 (Port 18080) or Secondary Rig
$PYTHON scripts/colab_training/train_blue_lodge_grpo.py \
  --curriculum data/training/curriculum_track2_git_ops.jsonl \
  --steps 40 --group_size 2 --rank 12 --alpha 16.0 \
  --endpoint http://127.0.0.1:18080 \
  --output /home/wsl-ops/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-LoRA-GitOps.gguf &
```

---

## 4. Curriculum Partitioning & Synthetic Expansion

To train specialized adapters without catastrophic interference, datasets are cleanly partitioned into distinct operational tracks:

```
data/training/
├── curriculum_track1_syntax.jsonl     (5,730 samples)
├── curriculum_track2_git_ops.jsonl    (3,550 samples)
├── curriculum_track3_phytology.jsonl  (3,550 samples)
└── native_core_tools.json             (Bedrock tools schema)
```

### 4.1 Track 1: Tool Syntax & Schema Integrity
- **Focus:** 100% strict JSON schema compliance.
- **Negative Penalties:**
  - Leakage of `</parameter>`, `<function>`, `<tool_call>` inside string arguments: **$-5.0$ penalty**.
  - Nested stringified JSON (`"{\"action\": \"{\\\"action\\\": \\\"status\\\"}\"}"`): **$-5.0$ penalty**.
  - Type errors (passing integer `"100"` instead of `100` or boolean `"true"` instead of `true`).

### 4.2 Track 2: GitOps & Safe File Lifecycle
- **Focus:** Safe codebase modification and git repository management.
- **Rules:**
  - Branching must cleanly branch off `develop`: `git checkout -b <feature> develop`.
  - Check existing branches to prevent collisions: `git branch -a`.
  - Non-destructive edits: Enforce `file_edit` on existing files. Penalize `file_write` when editing existing codebase files (**$-4.0$ penalty**).
  - Atomic conventional commits: `feat(...)`, `fix(...)`, `test(...)`.

### 4.3 Track 3: Software Phytology Living Tissue Protocol
- **Focus:** Autonomic tissue inspection, AST validation, and self-healing.
- **Rules:**
  - Direct bedrock invocation: Call `phytology_manage` directly with clean parameters (`action="status"`, `action="audit", flags="--cached"`).
  - Anti-aliasing penalty: Penalize running `tool_search` or attempting to mount external tools for core mounted features (**$-3.0$ penalty**).

To expand or regenerate curricula:
```bash
python3 scripts/quant_research/04_build_multi_track_curriculum.py
```

---

## 5. Analytical Multi-LoRA Concatenation (Iteration 5 Fusion)

### 5.1 The Decoupled Multi-Adapter Invariant
Fine-tuning directly on top of pre-fused weights causes catastrophic forgetting of STEM reasoning (GPQA) and abstract pattern solving (ARC-AGI).

**The Sovereign Rule:** Always train discrete, decoupled Rank-12 adapters on isolated domain datasets. Merge adapters analytically after training.

### 5.2 Exact Analytical Addition (`concat`)
Given $K$ adapters with parameters $(A_k, B_k)$ and weights $w_k$:

$$W = W_0 + \sum_{k=1}^K w_k (B_k A_k) = W_0 + B_{\text{merged}} A_{\text{merged}}$$

Where:
$$A_{\text{merged}} = \begin{bmatrix} \sqrt{w_1} A_1 \\ \sqrt{w_2} A_2 \\ \vdots \\ \sqrt{w_K} A_K \end{bmatrix}, \quad B_{\text{merged}} = \begin{bmatrix} \sqrt{w_1} B_1 & \sqrt{w_2} B_2 & \cdots & \sqrt{w_K} B_K \end{bmatrix}$$

$$\text{Merged Rank} = \sum_{k=1}^K r_k, \quad \alpha_{\text{merged}} = \alpha \times K$$

Because this is an exact block-matrix identity, **numerical loss is precisely zero**.

### 5.3 Thin-QR Low-Rank SVD Truncation (`svd`)
If VRAM constraints require bounding the adapter rank to a fixed budget (e.g. Rank 16):
1. Compute concatenated matrices $A_{\text{cat}}$ and $B_{\text{cat}}$.
2. Compute thin QR factorizations: $B_{\text{cat}} = Q_B R_B$, $A_{\text{cat}}^T = Q_A R_A$.
3. Compute small SVD: $M = R_B R_A^T = U_M \Sigma_M V_M^T$.
4. Truncate to top $r_{\text{target}}$ singular values:
   $$B_{\text{svd}} = Q_B U_{M, :r} \sqrt{\Sigma_{M, :r}}, \quad A_{\text{svd}} = \left( V_{M, :r} \sqrt{\Sigma_{M, :r}} \right)^T Q_A^T$$

### 5.4 Executing Iteration 5 Fusion
Run [`scripts/colab_training/fuse_iteration5.py`](file:///home/wsl-ops/blue-lodge/scripts/colab_training/fuse_iteration5.py):
```bash
python3 scripts/colab_training/fuse_iteration5.py --models_dir /home/wsl-ops/models/frontier_qwen38
```
This merges 8 discrete adapters:
1. `Blue-Llama-27B-Champion-v5-LoRA-GPQA.gguf` (STEM Core)
2. `Blue-Llama-27B-Champion-v5-LoRA-ARC-v2.gguf` (ARC-AGI Abstraction)
3. `Blue-Llama-27B-Champion-v5-LoRA-Exploit.gguf` (Cyber Hardening)
4. `Blue-Llama-27B-Champion-v5-LoRA-AGENT.gguf` (General Agentic)
5. `Blue-Llama-27B-Champion-v5-LoRA-BlueLodgeTools.gguf` (Local Validation)
6. `Blue-Llama-27B-Champion-v5-LoRA-Syntax.gguf` (Colab Track 1)
7. `Blue-Llama-27B-Champion-v5-LoRA-GitOps.gguf` (Colab Track 2)
8. `Blue-Llama-27B-Champion-v5-LoRA-Phytology.gguf` (Colab Track 3)

**Outputs:**
- `Blue-Llama-27B-Champion-v5-Iteration5-Fused-LoRA.gguf` (Rank 96, $\alpha = 128.0$, **247.50 MiB**).
- `Blue-Llama-27B-Champion-v5-Iteration5-Fused-SVD16.gguf` (Rank 16, $\alpha = 16.0$, **41.25 MiB**).

---

## 6. Sovereign Benchmark (`BlueLodgeBench`) & Active Data Re-Engineering

### 6.1 The 5 Sovereign Pillars (50 Rigorous Cases)
[`scripts/quant_research/05_evaluate_blue_lodge_benchmark.py`](file:///home/wsl-ops/blue-lodge/scripts/quant_research/05_evaluate_blue_lodge_benchmark.py) evaluates 5 core operational pillars:
1. **Pillar 1: Tool Syntax & Typing (10 cases)** — Validates OpenAI JSON formatting, schema types, zero XML tags, zero nested stringified JSON.
2. **Pillar 2: Action Execution vs Monologue (10 cases)** — Tests direct tool call emission against runaway `<think>` monologues.
3. **Pillar 3: Safe File Operations (10 cases)** — Verifies `file_edit` is selected for modifying existing code; penalizes `file_write` clobbering.
4. **Pillar 4: Git Model Management (10 cases)** — Tests branching from `develop`, short porcelain status checks, atomic conventional commits, remote pushes.
5. **Pillar 5: Software Phytology Protocol (10 cases)** — Tests direct invocation of `phytology_manage` without `tool_search` aliasing.

### 6.2 Empirical Baseline Findings
Running the unaligned baseline model against `BlueLodgeBench` revealed concrete failure modes:
```
================================================================================
  FINAL BLUELODGEBENCH SCORECARD (Baseline Champion-v5)
================================================================================
  • Pillar 1: Tool Syntax & Typing            :  30.0% (3.0/10) -> 4 XML leaks
  • Pillar 2: Action Execution vs Monologue   :  80.0% (8.0/10)
  • Pillar 3: Safe File Operations (No Clobber):  10.0% (1.0/10) -> Fails to use file_edit
  • Pillar 4: Git Model Management            :  80.0% (8.0/10)
  • Pillar 5: Software Phytology Protocol     :  65.0% (6.5/10) -> Falls back to file_read
--------------------------------------------------------------------------------
  ★ OVERALL COMPOSITE SCORE:                    53.0% (26.5/50)
================================================================================
```

### 6.3 Automated Counter-Example Extraction Loop
Whenever `05_evaluate_blue_lodge_benchmark.py` runs with `--extract_failures`:
1. Every failure is analyzed, classified (`xml_leak`, `nested_json`, `monologue_loop`, `clobber_violation`), and appended to `data/training/reengineering_counterexamples.jsonl`.
2. When any pillar drops below $90\%$, run the re-engineering generator:
   ```bash
   python3 scripts/quant_research/04_build_multi_track_curriculum.py
   ```
   This folds the counter-examples into targeted negative prompts and produces an augmented curriculum.
3. Re-train the corresponding track adapter and re-fuse. Continue until composite score exceeds **$92.0\%$** across all 5 pillars.

---

## 7. Operational Command Reference & Cheatsheet

### 7.1 Cloud Track (Colab Fleet)
```bash
# Check compute balance
/home/wsl-ops/venv_research/bin/colab --auth=adc usage

# Run complete autonomous 3-track fleet (provision, train, sync, teardown, fuse)
python3 scripts/colab_training/colab_fleet_orchestrator.py --steps 40 --group_size 12
```

### 7.2 Local Track (Dual RTX 3060 Workstation)
```bash
# Verify GPU memory and temperature
watch -n 1 nvidia-smi

# Launch local validation run on GPU 1
/home/wsl-ops/projects/research/unity_of_one/.venv/bin/python \
  scripts/colab_training/train_blue_lodge_grpo.py \
  --curriculum data/training/blue_lodge_tool_curriculum.jsonl \
  --steps 40 --group_size 2 --rank 12 --alpha 16.0 \
  --endpoint http://127.0.0.1:8080 \
  --output /home/wsl-ops/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-LoRA-BlueLodgeTools.gguf
```

### 7.3 Multi-LoRA Fusion
```bash
python3 scripts/colab_training/fuse_iteration5.py \
  --models_dir /home/wsl-ops/models/frontier_qwen38
```

### 7.4 Benchmark Verification
```bash
python3 scripts/quant_research/05_evaluate_blue_lodge_benchmark.py \
  --endpoint http://127.0.0.1:8080 \
  --model_label "Champion-v5-Iteration5" \
  --extract_failures
```
