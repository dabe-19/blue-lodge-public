#!/usr/bin/env python3
"""
fuse_iteration9.py:
Automated Multi-LoRA Fusion Engine for Champion-v5 Iteration 9.

Domain-Weighted Multi-Adapter Fusion with Multi-Turn ReAct & Memory Alignment:
1. Cognitive Reasoning Anchors (10%):
   - LoRA-GPQA (0.015)
   - LoRA-ARC-v2 (0.015)
   - LoRA-Exploit (0.015)
   - LoRA-AGENT (0.015)
   - LoRA-BlueLodgeTools (0.015)
   - LoRA-GitOps (0.015)
   - LoRA-Phytology (0.010)
2. Bedrock Remediation Stack (55%):
   - LoRA-Enhanced-Syntax (0.15)         -> Pillar 1 & 2 typing, trailing slashes, zero XML
   - LoRA-Enhanced-Safe-FileOps (0.25)   -> Pillar 3 anti-clobber & file_edit supremacy
   - LoRA-Enhanced-Phytology-GitOps (0.15) -> Pillar 4 & 5 phytology/git protocols
3. Multi-Turn ReAct & Working Memory Stack (35%):
   - LoRA-MultiTurn-ReAct (0.35)         -> Observation synthesis, mem:active_task, circuit advisory alignment

Outputs:
- Blue-Llama-27B-Champion-v5-Iteration9-Fused-LoRA.gguf (Rank 152 Concat)
- Blue-Llama-27B-Champion-v5-Iteration9-Fused-SVD32.gguf (Rank 32 SVD)
"""

import os
import sys
import subprocess
import argparse

MODELS_DIR = "/home/wsl-ops/models/frontier_qwen38"
FUSION_SCRIPT = "/home/wsl-ops/blue-lodge/scripts/colab_training/merge_frontier_loras.py"

def parse_args():
    parser = argparse.ArgumentParser(description="Fuse Iteration 9 LoRA Adapters")
    parser.add_argument("--models_dir", type=str, default=MODELS_DIR)
    parser.add_argument("--output_concat", type=str,
                        default=os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-Iteration9-Fused-LoRA.gguf"))
    parser.add_argument("--output_svd", type=str,
                        default=os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-Iteration9-Fused-SVD32.gguf"))
    return parser.parse_args()

def main():
    args = parse_args()
    os.makedirs(args.models_dir, exist_ok=True)

    adapter_specs = [
        # (path, weight, label)
        # Legacy Cognitive & Domain Anchors (10% Total Regularization Baseline)
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-GPQA.gguf"), 0.015, "GPQA Reasoning"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-ARC-v2.gguf"), 0.015, "ARC-v2 Abstraction"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Exploit.gguf"), 0.015, "Cyber Hardening"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-AGENT.gguf"), 0.015, "Agentic Core"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-BlueLodgeTools.gguf"), 0.015, "BlueLodge Bedrock"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-GitOps.gguf"), 0.015, "GitOps Core"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Phytology.gguf"), 0.010, "Phytology Core"),
        # Enhanced Remediation Stack (55%)
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Enhanced-Syntax.gguf"), 0.15, "Enhanced Syntax & Zero XML"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Enhanced-Safe-FileOps.gguf"), 0.25, "Anti-Clobber FileEdit Supremacy"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Enhanced-Phytology-GitOps.gguf"), 0.15, "Phytology & Git Protocol"),
        # Multi-Turn ReAct & Memory Alignment Stack (35%)
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-MultiTurn-ReAct.gguf"), 0.35, "Multi-Turn ReAct & Memory Alignment"),
    ]

    active_adapters = []
    active_weights = []

    print("=" * 80)
    print("  Iteration 9 Sovereign Multi-LoRA Fusion Engine")
    print("=" * 80)
    for path, weight, label in adapter_specs:
        if os.path.exists(path):
            active_adapters.append(path)
            active_weights.append(weight)
            print(f"  [+] {label:35s} | Weight: {weight*100:5.1f}% ({weight:.3f}) | {os.path.basename(path)}")
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
        print(f"    - {os.path.basename(path)}: {w:.4f} ({w*100:.1f}%)")

    # Pass 1: Linear concatenation
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
    subprocess.run(concat_cmd, check=True)

    # Pass 2: Truncated SVD Rank-32 Compression
    print("\n" + "=" * 80)
    print("  Pass 2: Truncated SVD Rank-32 Dimensionality Re-compression")
    print("=" * 80)
    svd_cmd = [
        sys.executable, FUSION_SCRIPT,
        "--adapters"
    ] + active_adapters + [
        "--weights"
    ] + [str(w) for w in norm_weights] + [
        "--method", "svd",
        "--target_rank", "32",
        "--output", args.output_svd
    ]
    subprocess.run(svd_cmd, check=True)

    print("\n" + "=" * 80)
    print(f"  ✓ Iteration 9 Fusion Complete!")
    print(f"    - Composite High-Rank: {args.output_concat}")
    print(f"    - SVD-32 Distilled:     {args.output_svd}")
    print("=" * 80)

if __name__ == "__main__":
    main()
