#!/usr/bin/env python3
"""
fuse_champion_v5_iteration9.py:
Automated Multi-LoRA Fusion Engine for Champion-v5 Iteration 9.

Fuses the Multi-Turn ReAct, Context Discrimination, and Surgical Resilience adapters
for the Experimental Champion-v5 architecture (PTQ1_0 / MTP):
1. Champion Anchor: Iteration 8 Fused LoRA (35.0%)
2. Track 1: Context Discrimination & Anti-Pollution (25.0%)
3. Track 2: Multi-Hop Follow-ups & Surgical Execution (20.0%)
4. Track 3: Evaluator Resilience & Tool Error Recovery (20.0%)

Outputs:
- Blue-Llama-27B-Champion-v5-Iteration9-Fused-LoRA.gguf
- Blue-Llama-27B-Champion-v5-Iteration9-Fused-SVD32.gguf
"""

import os
import sys
import subprocess
import argparse

MODELS_DIR = "/opt/blue-lodge/models/frontier_qwen38"
EXPERIMENTAL_ACTIVE_DIR = "/opt/blue-lodge/models/active/experimental"
FUSION_SCRIPT = "/opt/blue-lodge/scripts/colab_training/merge_frontier_loras.py"

def parse_args():
    parser = argparse.ArgumentParser(description="Fuse Iteration 9 LoRA Adapters for Champion-v5")
    parser.add_argument("--models_dir", type=str, default=MODELS_DIR)
    parser.add_argument("--output_concat", type=str,
                        default=os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-Iteration9-Fused-LoRA.gguf"))
    parser.add_argument("--output_svd", type=str,
                        default=os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-Iteration9-Fused-SVD32.gguf"))
    return parser.parse_args()

def main():
    args = parse_args()
    os.makedirs(args.models_dir, exist_ok=True)
    os.makedirs(EXPERIMENTAL_ACTIVE_DIR, exist_ok=True)

    adapter_specs = [
        # (path, weight, label)
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-Iteration8-Fused-LoRA.gguf"), 0.35, "Champion-v5 Iteration 8 Anchor"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-MultiTurn-Track1-ContextDiscrim.gguf"), 0.25, "Multi-Turn Context Discrimination"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-MultiTurn-Track2-MultiHop.gguf"), 0.20, "Multi-Turn Multi-Hop Followups"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-MultiTurn-Track3-Resilience.gguf"), 0.20, "Multi-Turn Resilience & Recovery"),
    ]

    active_adapters = []
    active_weights = []

    print("=" * 80)
    print("  Champion-v5 Iteration 9 Multi-LoRA Fusion Engine")
    print("=" * 80)
    for path, weight, label in adapter_specs:
        if os.path.exists(path):
            active_adapters.append(path)
            active_weights.append(weight)
            print(f"  [+] {label:35s} | Weight: {weight*100:5.1f}% ({weight:.4f}) | {os.path.basename(path)}")
        else:
            print(f"  [-] MISSING: {label:35s} | {os.path.basename(path)}")

    if not active_adapters:
        print("[!] Error: No candidate adapters found to fuse!")
        sys.exit(1)

    # Normalize weights
    total_w = sum(active_weights)
    norm_weights = [w / total_w for w in active_weights]
    print("-" * 80)
    print(f"[*] Normalized {len(active_adapters)} active adapter weights (sum: {sum(norm_weights):.4f})")

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
        "--output", args.output_concat,
        "--method", "concat"
    ]
    res = subprocess.run(concat_cmd)
    if res.returncode != 0:
        print("[!] Pass 1 concat merge failed!")
        sys.exit(res.returncode)
    print(f"  ✓ Created {args.output_concat} ({os.path.getsize(args.output_concat)/(1024**2):.1f} MB)")

    # Pass 2: SVD Low-Rank Distillation (Rank 32 Target)
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
        print("[!] Pass 2 SVD-32 distillation failed!")
        sys.exit(res2.returncode)
    print(f"  ✓ Created {args.output_svd} ({os.path.getsize(args.output_svd)/(1024**2):.1f} MB)")

    # 3. Update experimental champion symlink
    symlink_path = os.path.join(EXPERIMENTAL_ACTIVE_DIR, "champion.gguf")
    if os.path.islink(symlink_path) or os.path.exists(symlink_path):
        os.remove(symlink_path)
    os.symlink(args.output_svd, symlink_path)
    print(f"  ✓ Updated Experimental Champion symlink: {symlink_path} -> {args.output_svd}")

    print("\n" + "=" * 80)
    print("  [✓] Champion-v5 Iteration 9 Fusion & Deployment Succeeded!")
    print("=" * 80)

if __name__ == "__main__":
    main()
