#!/usr/bin/env python3
"""
fuse_iteration5.py:
Automated Fusion Engine for Champion-v5 Iteration 5.

Analytically concatenates the frontier multi-domain LoRA adapters:
1. STEM Core (GPQA / Science reasoning)
2. Abstraction Reasoning (ARC-AGI-v2)
3. Cyber / Security Hardening (ExploitBench)
4. Base Agentic Core (AGENT)
5. Sovereign Blue Lodge Native Tool Calling (BlueLodgeTools / Syntax / GitOps / Phytology)

Outputs:
- Blue-Llama-27B-Champion-v5-Iteration5-Fused-LoRA.gguf (Exact zero-loss analytical concatenation)
- Blue-Llama-27B-Champion-v5-Iteration5-Fused-SVD16.gguf (Thin-QR truncated rank-16 compact adapter)
"""

import os
import sys
import subprocess
import argparse

MODELS_DIR = "/home/wsl-ops/models/frontier_qwen38"
FUSION_SCRIPT = "/home/wsl-ops/blue-lodge/scripts/colab_training/merge_frontier_loras.py"

def parse_args():
    parser = argparse.ArgumentParser(description="Fuse Iteration 5 LoRA Adapters")
    parser.add_argument("--models_dir", type=str, default=MODELS_DIR, help="Directory containing input adapters")
    parser.add_argument("--output_concat", type=str,
                        default=os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-Iteration5-Fused-LoRA.gguf"),
                        help="Path for exact concatenated GGUF")
    parser.add_argument("--output_svd", type=str,
                        default=os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-Iteration5-Fused-SVD16.gguf"),
                        help="Path for SVD rank-16 compact GGUF")
    return parser.parse_args()

def main():
    args = parse_args()
    os.makedirs(args.models_dir, exist_ok=True)

    # Core frontier pillars
    frontier_candidates = [
        os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-GPQA.gguf"),
        os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-ARC-v2.gguf"),
        os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Exploit.gguf"),
        os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-AGENT.gguf"),
    ]

    # Blue lodge specialized tool adapters
    tool_candidates = [
        os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-BlueLodgeTools.gguf"),
        os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Syntax.gguf"),
        os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-GitOps.gguf"),
        os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Phytology.gguf"),
    ]

    adapters_to_fuse = []
    for p in frontier_candidates:
        if os.path.exists(p):
            adapters_to_fuse.append(p)
            print(f"  [+] Frontier Pillar Added: {os.path.basename(p)}")
        else:
            print(f"  [-] Frontier Pillar Missing: {os.path.basename(p)}")

    for p in tool_candidates:
        if os.path.exists(p):
            adapters_to_fuse.append(p)
            print(f"  [+] Tool Adapter Added: {os.path.basename(p)}")

    if not adapters_to_fuse:
        print("[!] No adapters found to fuse! Aborting.")
        sys.exit(1)

    print("=" * 80)
    print(f"  Executing Analytical Multi-LoRA Fusion ({len(adapters_to_fuse)} Adapters)...")
    print(f"  Output Concat: {args.output_concat}")
    print(f"  Output SVD:    {args.output_svd}")
    print("=" * 80)

    # 1. Concat Fusion
    cmd_concat = [
        sys.executable, FUSION_SCRIPT,
        "--method", "concat",
        "--output", args.output_concat,
        "--adapters"
    ] + adapters_to_fuse
    print("\n[*] Running Exact Low-Rank Concatenation...")
    res = subprocess.run(cmd_concat)
    if res.returncode != 0:
        print("[!] Concat fusion failed!")
        sys.exit(res.returncode)

    # 2. SVD Fusion
    cmd_svd = [
        sys.executable, FUSION_SCRIPT,
        "--method", "svd",
        "--target_rank", "16",
        "--output", args.output_svd,
        "--adapters"
    ] + adapters_to_fuse
    print("\n[*] Running Thin-QR SVD Truncation (Rank 16)...")
    res_svd = subprocess.run(cmd_svd)
    if res_svd.returncode != 0:
        print("[!] SVD fusion failed!")
        sys.exit(res_svd.returncode)

    print("\n" + "=" * 80)
    print(f"[✓] Iteration 5 Fusion Pipeline Complete!")
    print(f"    Concatenated LoRA: {args.output_concat} ({os.path.getsize(args.output_concat)/(1024*1024):.2f} MiB)")
    print(f"    SVD-16 LoRA:       {args.output_svd} ({os.path.getsize(args.output_svd)/(1024*1024):.2f} MiB)")
    print("=" * 80)

if __name__ == "__main__":
    main()
