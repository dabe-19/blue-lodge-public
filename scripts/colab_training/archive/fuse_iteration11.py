#!/usr/bin/env python3
"""
fuse_iteration11.py:
Automated Clean Multi-LoRA Fusion Engine for Champion-v5 Iteration 11.

Architectural Streamlining:
Builds directly upon proven Iteration 10 champion anchor (75% anchor weight) to strictly
prevent catastrophic forgetting across existing skills (DAG parallel, self-healing, Jinja syntax,
memory synthesis, phytology, gitops), while blending the 3 new targeted research & cron adapters
produced by the 3x A100 Colab fleet (25% total weight, 8.33% each):
1. Base Champion Anchor (75%):
   - Blue-Llama-27B-Champion-v10-Fused-LoRA.gguf (0.75)
2. Autonomous Research & Cron Fleet Stack (25%):
   - LoRA-Cron-Architect (0.0833)      -> Track A: .george/cron_jobs/ authoring & deterministic sandbox wrapping
   - LoRA-Research-Sampler (0.0833)     -> Track B: Non-greedy semantic cross-sectional article retrieval
   - LoRA-Dossier-Delivery (0.0833)     -> Track C: Structured executive dossier formatting & Discord chunking

Outputs:
- Blue-Llama-27B-Champion-v11-Fused-LoRA.gguf (High-Rank Composite)
- Blue-Llama-27B-Champion-v11-Fused-SVD32.gguf (Rank 32 SVD Distilled)
"""

import os
import sys
import subprocess
import argparse

MODELS_DIR = "/home/wsl-ops/models/frontier_qwen38"
FUSION_SCRIPT = "/home/wsl-ops/blue-lodge/scripts/colab_training/merge_frontier_loras.py"

def parse_args():
    parser = argparse.ArgumentParser(description="Fuse Iteration 11 LoRA Adapters onto Iteration 10 Champion")
    parser.add_argument("--models_dir", type=str, default=MODELS_DIR)
    parser.add_argument("--output_concat", type=str,
                        default=os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v11-Fused-LoRA.gguf"))
    parser.add_argument("--output_svd", type=str,
                        default=os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v11-Fused-SVD32.gguf"))
    return parser.parse_args()

def main():
    args = parse_args()
    os.makedirs(args.models_dir, exist_ok=True)

    adapter_specs = [
        # (path, weight, label)
        # Proven Iteration 10 Baseline Anchor (75%)
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v10-Fused-LoRA.gguf"), 0.75, "Iteration 10 Champion Anchor"),
        # Multi-Track Research & Cron Fleet Adapters (25%)
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Cron-Architect.gguf"), 0.08333, "Track A: Cron Architect"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Research-Sampler.gguf"), 0.08333, "Track B: Semantic Cross-Section"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Dossier-Delivery.gguf"), 0.08334, "Track C: Dossier Delivery Wrap"),
    ]

    active_adapters = []
    active_weights = []

    print("=" * 80)
    print("  Iteration 11 Streamlined Multi-LoRA Fusion Engine")
    print("=" * 80)
    for path, weight, label in adapter_specs:
        if os.path.exists(path):
            active_adapters.append(path)
            active_weights.append(weight)
            print(f"  [+] {label:35s} | Weight: {weight*100:5.1f}% ({weight:.4f}) | {os.path.basename(path)}")
        else:
            print(f"  [-] PENDING: {label:35s} | {os.path.basename(path)}")

    if not active_adapters:
        print("[!] No adapters found to fuse!")
        sys.exit(1)

    # Normalize active weights
    w_sum = sum(active_weights)
    norm_weights = [w / w_sum for w in active_weights]

    print("\n[*] Normalized Fusion Weights:")
    for path, w in zip(active_adapters, norm_weights):
        print(f"    - {os.path.basename(path)}: {w:.4f} ({w*100:.2f}%)")

    # Pass 1: Direct Linear Concatenation
    print("\n" + "=" * 80)
    print("  Pass 1: Direct Linear Concatenation (High-Rank Composite)")
    print("=" * 80)
    concat_cmd = [
        sys.executable, FUSION_SCRIPT,
        "--adapters"
    ] + active_adapters + [
        "--weights"
    ] + [str(w) for w in norm_weights] + [
        "--output", args.output_concat
    ]
    res = subprocess.run(concat_cmd)
    if res.returncode != 0:
        print("[!] Pass 1 failed!")
        sys.exit(res.returncode)

    # Pass 2: SVD Low-Rank Distillation (Rank 32)
    print("\n" + "=" * 80)
    print("  Pass 2: SVD Low-Rank Distillation (Rank 32 Target)")
    print("=" * 80)
    svd_cmd = [
        sys.executable, FUSION_SCRIPT,
        "--adapters"
    ] + active_adapters + [
        "--weights"
    ] + [str(w) for w in norm_weights] + [
        "--output", args.output_svd,
        "--method", "svd",
        "--target_rank", "32"
    ]
    res_svd = subprocess.run(svd_cmd)
    if res_svd.returncode != 0:
        print("[!] Pass 2 SVD failed!")
        sys.exit(res_svd.returncode)

    print("\n" + "=" * 80)
    print(f"  ✓ Iteration 11 Multi-LoRA Fusion Complete!")
    print(f"  - High-Rank Composite: {args.output_concat} ({os.path.getsize(args.output_concat)/(1024**2):.1f} MB)")
    print(f"  - SVD Rank 32 Distilled: {args.output_svd} ({os.path.getsize(args.output_svd)/(1024**2):.1f} MB)")
    print("=" * 80)

if __name__ == "__main__":
    main()
