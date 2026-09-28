#!/usr/bin/env python3
"""
fuse_iteration10.py:
Automated Clean Multi-LoRA Fusion Engine for Champion-v5 Iteration 10.

Architectural Streamlining:
Instead of re-blending all 11 historical adapters from scratch, we build directly upon
our proven champion baseline (Iteration 9 Fused LoRA, 70% weight) and blend the 3 targeted
failure mode adapters produced by the 3x A100 Colab fleet:
1. Base Champion Anchor (70%):
   - Blue-Llama-27B-Champion-v5-Iteration9-Fused-LoRA.gguf (0.70)
2. DAG & Failure Mode Fleet Stack (30%):
   - LoRA-DAG-Parallel (0.10)       -> Track A: Parallel milestone execution & milestone_complete dispatch
   - LoRA-Recovery-SelfHeal (0.10)   -> Track B: Two-tier recovery cascade & in-place self-healing
   - LoRA-Memory-Synthesis (0.10)    -> Track C: mem:active_task distillation & synthesis under tool_choice=none

Outputs:
- Blue-Llama-27B-Champion-v10-Fused-LoRA.gguf (High-Rank Composite)
- Blue-Llama-27B-Champion-v10-Fused-SVD32.gguf (Rank 32 SVD Distilled)
"""

import os
import sys
import subprocess
import argparse

MODELS_DIR = "/home/wsl-ops/models/frontier_qwen38"
FUSION_SCRIPT = "/home/wsl-ops/blue-lodge/scripts/colab_training/merge_frontier_loras.py"

def parse_args():
    parser = argparse.ArgumentParser(description="Fuse Iteration 10 LoRA Adapters onto Iteration 9 Champion")
    parser.add_argument("--models_dir", type=str, default=MODELS_DIR)
    parser.add_argument("--output_concat", type=str,
                        default=os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v10-Fused-LoRA.gguf"))
    parser.add_argument("--output_svd", type=str,
                        default=os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v10-Fused-SVD32.gguf"))
    return parser.parse_args()

def main():
    args = parse_args()
    os.makedirs(args.models_dir, exist_ok=True)

    adapter_specs = [
        # (path, weight, label)
        # Proven Iteration 9 Baseline Anchor (70%)
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-Iteration9-Fused-LoRA.gguf"), 0.70, "Iteration 9 Champion Anchor"),
        # Multi-Track Failure Mode Fleet Adapters (30%)
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-DAG-Parallel.gguf"), 0.075, "Track A: DAG Parallel Execution"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Recovery-SelfHeal.gguf"), 0.075, "Track B: Two-Tier Recovery Cascade"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Memory-Synthesis.gguf"), 0.075, "Track C: Memory Distillation & Synthesis"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Strategist-DAG.gguf"), 0.075, "Track D: Honeydew DAG Strategist"),
    ]

    active_adapters = []
    active_weights = []

    print("=" * 80)
    print("  Iteration 10 Streamlined Multi-LoRA Fusion Engine")
    print("=" * 80)
    for path, weight, label in adapter_specs:
        if os.path.exists(path):
            active_adapters.append(path)
            active_weights.append(weight)
            print(f"  [+] {label:35s} | Weight: {weight*100:5.1f}% ({weight:.3f}) | {os.path.basename(path)}")
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
        print(f"    - {os.path.basename(path)}: {w:.4f} ({w*100:.1f}%)")

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
    print("  ✓ Iteration 10 Fusion Pipeline Complete!")
    print(f"    - High-Rank Composite: {args.output_concat} ({os.path.getsize(args.output_concat)/(1024**2):.1f} MB)")
    print(f"    - Rank 32 SVD Distilled: {args.output_svd} ({os.path.getsize(args.output_svd)/(1024**2):.1f} MB)")
    print("=" * 80)

if __name__ == "__main__":
    main()
