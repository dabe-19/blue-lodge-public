#!/usr/bin/env python3
"""
fuse_iteration8.py:
Automated Multi-LoRA Fusion Engine for Champion-v5 Iteration 8.

Domain-Weighted Multi-Adapter Fusion:
1. Cognitive Reasoning Anchors (20%):
   - LoRA-GPQA (0.05)
   - LoRA-ARC-v2 (0.05)
   - LoRA-Exploit (0.05)
   - LoRA-AGENT (0.05)
2. Base Tool Calling Infrastructure (15%):
   - LoRA-BlueLodgeTools (0.05)
   - LoRA-GitOps (0.05)
   - LoRA-Phytology (0.05)
3. Fresh Enhanced Remediation Stack (65%):
   - LoRA-Enhanced-Syntax (0.20)         -> Solves Pillar 1 & 2 typing, trailing slashes, zero XML
   - LoRA-Enhanced-Safe-FileOps (0.25)   -> Solves Pillar 3 clobbering & file_edit supremacy
   - LoRA-Enhanced-Phytology-GitOps (0.20) -> Solves Pillar 4 & 5 phytology/git protocols

Outputs:
- Blue-Llama-27B-Champion-v5-Iteration8-Fused-LoRA.gguf (Rank 120 Concat)
- Blue-Llama-27B-Champion-v5-Iteration8-Fused-SVD32.gguf (Rank 32 SVD)
"""

import os
import sys
import subprocess
import argparse

MODELS_DIR = "/home/wsl-ops/models/frontier_qwen38"
FUSION_SCRIPT = "/home/wsl-ops/blue-lodge/scripts/colab_training/merge_frontier_loras.py"

def parse_args():
    parser = argparse.ArgumentParser(description="Fuse Iteration 8 LoRA Adapters")
    parser.add_argument("--models_dir", type=str, default=MODELS_DIR)
    parser.add_argument("--output_concat", type=str,
                        default=os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-Iteration8-Fused-LoRA.gguf"))
    parser.add_argument("--output_svd", type=str,
                        default=os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-Iteration8-Fused-SVD32.gguf"))
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
        # Fresh Robust Enhanced Remediation Stack (90% Total Steering Authority)
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Enhanced-Syntax.gguf"), 0.25, "Enhanced Syntax & Zero XML"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Enhanced-Safe-FileOps.gguf"), 0.40, "Anti-Clobber FileEdit Supremacy"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Enhanced-Phytology-GitOps.gguf"), 0.25, "Phytology & Git Protocol"),
    ]

    active_adapters = []
    active_weights = []

    print("=" * 80)
    print("  Iteration 8 Sovereign Multi-LoRA Fusion Engine")
    print("=" * 80)
    for path, weight, label in adapter_specs:
        if os.path.exists(path):
            active_adapters.append(path)
            active_weights.append(weight)
            print(f"  [+] {label:32s} | Weight: {weight*100:5.1f}% ({weight:.3f}) | {os.path.basename(path)}")
        else:
            print(f"  [-] MISSING: {label:32s} | {os.path.basename(path)}")

    if not active_adapters:
        print("[!] No active adapters found to merge!")
        sys.exit(1)

    # Re-normalize weights
    total_w = sum(active_weights)
    norm_weights = [w / total_w for w in active_weights]

    print("\n" + "=" * 80)
    print(f"  Executing Fusion ({len(active_adapters)} Adapters, Total Normalized Weight: 1.00)...")
    print("=" * 80)

    # 1. Exact Concat
    cmd_concat = [
        sys.executable, FUSION_SCRIPT,
        "--method", "concat",
        "--output", args.output_concat,
        "--weights"
    ] + [str(w) for w in norm_weights] + ["--adapters"] + active_adapters

    print("\n[*] Fusing Exact Low-Rank Concatenation...")
    res1 = subprocess.run(cmd_concat)
    if res1.returncode != 0:
        print("[!] Concat fusion failed!")
        sys.exit(res1.returncode)

    # 2. SVD Rank-32 Compression
    cmd_svd = [
        sys.executable, FUSION_SCRIPT,
        "--method", "svd",
        "--target_rank", "32",
        "--output", args.output_svd,
        "--weights"
    ] + [str(w) for w in norm_weights] + ["--adapters"] + active_adapters

    print("\n[*] Fusing SVD Rank-32 Compression...")
    res2 = subprocess.run(cmd_svd)
    if res2.returncode != 0:
        print("[!] SVD fusion failed!")
        sys.exit(res2.returncode)

    print("\n[✓] Iteration 8 Fusion Complete!")
    print(f"  -> Concat LoRA: {args.output_concat} ({os.path.getsize(args.output_concat)/(1024**2):.2f} MiB)")
    print(f"  -> SVD32 LoRA:  {args.output_svd} ({os.path.getsize(args.output_svd)/(1024**2):.2f} MiB)")

if __name__ == "__main__":
    main()
