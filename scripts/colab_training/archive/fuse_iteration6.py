#!/usr/bin/env python3
"""
fuse_iteration6.py:
Automated Fusion Engine for Champion-v5 Iteration 6.

Analytically concatenates the frontier multi-domain LoRA adapters:
1. STEM Core (GPQA / Science reasoning)
2. Abstraction Reasoning (ARC-AGI-v2)
3. Cyber / Security Hardening (ExploitBench)
4. Base Agentic Core (AGENT)
5. Sovereign Blue Lodge Native Tool Calling Stack (6 Adapters):
   - Syntax & Schema Integrity
   - GitOps & Model Management
   - Software Phytology Protocol
   - Remediation Track A: Syntax & Anti-XML Leakage
   - Remediation Track B: Safe File Operations (file_edit & Anti-Clobber)
   - Remediation Track C: Phytology Protocol & Conventional Commits
   - BlueLodgeTools Core

Outputs:
- Blue-Llama-27B-Champion-v5-Iteration6-Fused-LoRA.gguf (Exact zero-loss analytical concatenation)
- Blue-Llama-27B-Champion-v5-Iteration6-Fused-SVD16.gguf (Thin-QR truncated rank-16 compact adapter)
"""

import os
import sys
import subprocess
import argparse

MODELS_DIR = "/home/wsl-ops/models/frontier_qwen38"
FUSION_SCRIPT = "/home/wsl-ops/blue-lodge/scripts/colab_training/merge_frontier_loras.py"

def parse_args():
    parser = argparse.ArgumentParser(description="Fuse Iteration 6 LoRA Adapters")
    parser.add_argument("--models_dir", type=str, default=MODELS_DIR, help="Directory containing input adapters")
    parser.add_argument("--output_concat", type=str,
                        default=os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-Iteration6-Fused-LoRA.gguf"),
                        help="Path for exact concatenated GGUF")
    parser.add_argument("--output_svd", type=str,
                        default=os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-Iteration6-Fused-SVD16.gguf"),
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
        os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Remediation-Syntax.gguf"),
        os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Remediation-FileOps.gguf"),
        os.path.join(args.models_dir, "Blue-Llama-27B-Champion-v5-LoRA-Remediation-Protocol.gguf"),
    ]

    adapters_to_fuse = []
    print("=" * 80)
    print("  Assembling Multi-LoRA Adapters for Iteration 6 Fusion")
    print("=" * 80)
    for p in frontier_candidates:
        if os.path.exists(p):
            adapters_to_fuse.append(p)
            print(f"  [+] Frontier Pillar: {os.path.basename(p)}")
        else:
            print(f"  [-] Frontier Pillar Missing: {os.path.basename(p)}")

    for p in tool_candidates:
        if os.path.exists(p):
            adapters_to_fuse.append(p)
            print(f"  [+] Tool Adapter: {os.path.basename(p)}")
        else:
            print(f"  [-] Tool Adapter Missing: {os.path.basename(p)}")

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
    print("\n[*] Running SVD Rank-16 Compression...")
    res = subprocess.run(cmd_svd)
    if res.returncode != 0:
        print("[!] SVD fusion failed!")
        sys.exit(res.returncode)

    print("\n[✓] Iteration 6 LoRA Fusion Complete!")
    print(f"  -> Concat LoRA: {args.output_concat} ({os.path.getsize(args.output_concat)/(1024**2):.2f} MiB)")
    print(f"  -> SVD16 LoRA:  {args.output_svd} ({os.path.getsize(args.output_svd)/(1024**2):.2f} MiB)")

if __name__ == "__main__":
    main()
