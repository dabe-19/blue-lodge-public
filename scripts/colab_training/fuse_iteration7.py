#!/usr/bin/env python3
"""
fuse_iteration7.py:
Automated Multi-LoRA Fusion Engine for Champion-v5 Iteration 7.

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
3. Fresh Native Jinja & Sovereign Remediation Stack (65%):
   - LoRA-Jinja-Syntax (0.20)       -> Solves XML leak & parameter bleeding
   - LoRA-Safe-FileOps (0.25)       -> Solves Pillar 3 clobbering (file_edit supremacy)
   - LoRA-Phytology-GitOps (0.20)   -> Solves Pillar 4 & 5 phytology/git protocols

Outputs:
- Blue-Llama-27B-Champion-v5-Iteration7-Fused-LoRA.gguf (Rank 120 Concat)
- Blue-Llama-27B-Champion-v5-Iteration7-Fused-SVD16.gguf (Rank 16 SVD)
"""

import os
import sys
import subprocess
import argparse

MODELS_DIR = "/home/wsl-ops/models/frontier_qwen38"
FUSION_SCRIPT = "/home/wsl-ops/blue-lodge/scripts/colab_training/merge_frontier_loras.py"

def parse_args():
    parser = argparse.ArgumentParser(description="Fuse Iteration 7 LoRA Adapters")
    parser.add_argument("--models_dir", type=str, default=MODELS_DIR)
    parser.add_argument("--output_concat", type=str,
                        default=os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-Iteration7-Fused-LoRA.gguf"))
    parser.add_argument("--output_svd", type=str,
                        default=os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-Iteration7-Fused-SVD16.gguf"))
    return parser.parse_args()

def main():
    args = parse_args()
    os.makedirs(args.models_dir, exist_ok=True)

    adapter_specs = [
        # (path, weight, label)
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-GPQA.gguf"), 0.05, "GPQA Reasoning"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-ARC-v2.gguf"), 0.05, "ARC-v2 Abstraction"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Exploit.gguf"), 0.05, "Cyber Hardening"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-AGENT.gguf"), 0.05, "Agentic Core"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-BlueLodgeTools.gguf"), 0.05, "BlueLodge Bedrock"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-GitOps.gguf"), 0.05, "GitOps Core"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Phytology.gguf"), 0.05, "Phytology Core"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Jinja-Syntax.gguf"), 0.20, "Jinja Syntax & Zero XML"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Safe-FileOps.gguf"), 0.25, "Anti-Clobber FileEdit"),
        (os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Phytology-GitOps.gguf"), 0.20, "Phytology & Git Protocol"),
    ]

    active_adapters = []
    active_weights = []

    print("=" * 80)
    print("  Iteration 7 Sovereign Multi-LoRA Fusion Engine")
    print("=" * 80)
    for path, weight, label in adapter_specs:
        if os.path.exists(path):
            active_adapters.append(path)
            active_weights.append(weight)
            print(f"  [+] {label:28s} | Weight: {weight:.2f} | {os.path.basename(path)}")
        else:
            print(f"  [-] MISSING: {label:20s} | {os.path.basename(path)}")

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

    # 2. SVD Rank-16
    cmd_svd = [
        sys.executable, FUSION_SCRIPT,
        "--method", "svd",
        "--target_rank", "16",
        "--output", args.output_svd,
        "--weights"
    ] + [str(w) for w in norm_weights] + ["--adapters"] + active_adapters

    print("\n[*] Fusing SVD Rank-16 Compression...")
    res2 = subprocess.run(cmd_svd)
    if res2.returncode != 0:
        print("[!] SVD fusion failed!")
        sys.exit(res2.returncode)

    print("\n[✓] Iteration 7 Fusion Complete!")
    print(f"  -> Concat LoRA: {args.output_concat} ({os.path.getsize(args.output_concat)/(1024**2):.2f} MiB)")
    print(f"  -> SVD16 LoRA:  {args.output_svd} ({os.path.getsize(args.output_svd)/(1024**2):.2f} MiB)")

if __name__ == "__main__":
    main()
