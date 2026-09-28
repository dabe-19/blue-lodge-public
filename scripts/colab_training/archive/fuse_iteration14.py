#!/usr/bin/env python3
"""
fuse_iteration14.py:
Automated Clean Multi-LoRA Fusion Engine for Blue Lodge Iteration 14.

Merges the new Multi-Hop & Anti-Context-Pollution LoRA adapters:
1. Track 1: Context Discrimination & Anti-Pollution (25.0%)
2. Track 2: Multi-Hop Follow-ups & Surgical Execution (20.0%)
3. Track 3: Evaluator Resilience & Tool Error Recovery (15.0%)
4. Champion Anchor: Iteration 13 Fused SVD32 (40.0%)

Outputs:
- Blue-Llama-27B-Champion-v14-Fused-LoRA.gguf (High-Rank Composite)
- Blue-Llama-27B-Champion-v14-Fused-SVD32.gguf (Rank 32 SVD Distilled)
"""

import os
import sys
import subprocess
import argparse

MODELS_DIR = "/home/wsl-ops/models/frontier_qwen38"
FUSION_SCRIPT = "/home/wsl-ops/blue-lodge/scripts/colab_training/merge_frontier_loras.py"

def parse_args():
    parser = argparse.ArgumentParser(description="Fuse Iteration 14 Multi-Hop LoRA Adapters for Blue Lodge")
    parser.add_argument("--models_dir", type=str, default=MODELS_DIR)
    parser.add_argument("--output_concat", type=str,
                        default=os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v14-Fused-LoRA.gguf"))
    parser.add_argument("--output_svd", type=str,
                        default=os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v14-Fused-SVD32.gguf"))
    return parser.parse_args()

def main():
    args = parse_args()
    os.makedirs(args.models_dir, exist_ok=True)

    adapter_specs = [
        # (path, weight, label)
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v13-Fused-SVD32.gguf"), 0.40, "Iteration 13 Champion Anchor"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-MultiTurn-ContextDiscrimination.gguf"), 0.25, "Context Discrimination"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-MultiTurn-MultiHopFollowups.gguf"), 0.20, "Multi-Hop Follow-ups"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-MultiTurn-EvaluatorResilience.gguf"), 0.15, "Evaluator Resilience"),
    ]

    active_adapters = []
    active_weights = []

    print("=" * 80)
    print("  Iteration 14 Multi-LoRA Fusion Engine (Multi-Hop & Context Discrimination)")
    print("=" * 80)
    for path, weight, label in adapter_specs:
        if os.path.exists(path):
            active_adapters.append(path)
            active_weights.append(weight)
            print(f"  [+] {label:35s} | Weight: {weight*100:5.1f}% ({weight:.4f}) | {os.path.basename(path)}")
        else:
            print(f"  [-] MISSING: {label:35s} | {os.path.basename(path)}")

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
    res2 = subprocess.run(svd_cmd)
    if res2.returncode != 0:
        print("[!] Pass 2 failed!")
        sys.exit(res2.returncode)

    print("\n[✓] Iteration 14 Fusion Complete!")
    print(f"    - Concat Adapter: {args.output_concat} ({os.path.getsize(args.output_concat)/(1024**2):.1f} MB)")
    print(f"    - SVD32  Adapter: {args.output_svd} ({os.path.getsize(args.output_svd)/(1024**2):.1f} MB)")

if __name__ == "__main__":
    main()
