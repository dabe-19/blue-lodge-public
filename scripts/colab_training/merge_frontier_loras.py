#!/usr/bin/env python3
"""
Frontier LoRA Multi-Adapter Fusion Engine:
Merges N specialized LoRA adapters (e.g., ARC-AGI + ExploitBench + STEM Core + Agent)
into a unified, frontier-grade GGUF adapter.

Supported Fusion Modes:
1. 'concat' (Exact Analytical Addition, Rank = sum(r_k)):
   - A_merged = vstack([sqrt(w_k) * A_k for k in range(K)])
   - B_merged = hstack([sqrt(w_k) * B_k for k in range(K)])
   - B_merged @ A_merged == sum(w_k * (B_k @ A_k)) with ZERO numerical or approximation loss.
2. 'svd' (Low-Rank Truncation, Preserves Target Rank):
   - Delta W = sum(w_k * (B_k @ A_k))
   - SVD(Delta W) -> truncated to top target_rank singular values.
"""

import os
import sys
import argparse
import numpy as np
import gguf

def parse_args():
    parser = argparse.ArgumentParser(description="Frontier Multi-LoRA Fusion Engine")
    parser.add_argument("--adapters", nargs="+", required=True, help="List of LoRA adapter paths (GGUF)")
    parser.add_argument("--weights", nargs="+", type=float, default=None, help="Weights for each adapter")
    parser.add_argument("--output", type=str, required=True, help="Path to output merged LoRA adapter (GGUF)")
    parser.add_argument("--method", choices=["concat", "svd"], default="concat",
                        help="Fusion method ('concat' for exact zero-loss or 'svd' to preserve target rank)")
    parser.add_argument("--target_rank", type=int, default=16, help="Target rank if using SVD mode")
    parser.add_argument("--alpha", type=float, default=16.0, help="Merged LoRA alpha")
    return parser.parse_args()

def main():
    args = parse_args()
    num_adapters = len(args.adapters)
    
    if args.weights is None:
        weights = [1.0 / num_adapters] * num_adapters
    else:
        weights = args.weights
        if len(weights) != num_adapters:
            raise ValueError(f"Number of weights ({len(weights)}) does not match adapters ({num_adapters})")

    print("================================================================================")
    print(f"  Frontier Multi-LoRA Fusion Engine | Method: {args.method.upper()}")
    for i, (path, w) in enumerate(zip(args.adapters, weights)):
        print(f"  [{i+1}/{num_adapters}] Weight: {w:.3f} | Path: {path}")
    print(f"  Output: {args.output}")
    print("================================================================================")

    for p in args.adapters:
        if not os.path.exists(p):
            raise FileNotFoundError(f"Adapter not found: {p}")

    readers = [gguf.GGUFReader(p) for p in args.adapters]
    tensor_dicts = [{t.name: t.data for t in r.tensors} for r in readers]

    # Find union of all tensor keys
    all_keys = set()
    for td in tensor_dicts:
        all_keys.update(td.keys())
    
    base_names = sorted(list(set(k.replace(".lora_a", "").replace(".lora_b", "") for k in all_keys)))
    print(f"[*] Total unique projection bases to merge across {num_adapters} adapters: {len(base_names)}")

    if args.alpha is not None and args.alpha != 16.0:
        effective_alpha = args.alpha
    else:
        if args.method == "concat":
            effective_alpha = 16.0 * num_adapters
        else:
            effective_alpha = float(args.target_rank)

    print(f"[*] Setting adapter.lora.alpha = {effective_alpha} to preserve exact training scale ratio.")
    writer = gguf.GGUFWriter(args.output, arch="qwen35")
    writer.add_string("general.type", "adapter")
    writer.add_string("adapter.type", "lora")
    writer.add_float32("adapter.lora.alpha", effective_alpha)

    merged_tensors = 0

    for idx, base in enumerate(base_names):
        name_a = f"{base}.lora_a"
        name_b = f"{base}.lora_b"

        # Collect available components
        active_pairs = []
        for k in range(num_adapters):
            if name_a in tensor_dicts[k] and name_b in tensor_dicts[k]:
                active_pairs.append((weights[k], tensor_dicts[k][name_a], tensor_dicts[k][name_b]))

        if not active_pairs:
            continue

        if args.method == "concat":
            # Exact analytical low-rank concatenation
            A_list = [np.sqrt(w) * A for w, A, B in active_pairs]
            B_list = [np.sqrt(w) * B for w, A, B in active_pairs]
            A_merged = np.vstack(A_list).astype(np.float32)
            B_merged = np.hstack(B_list).astype(np.float32)
            rank_str = f"Rank {A_merged.shape[0]}"

        elif args.method == "svd":
            # Exact fast low-rank SVD via thin QR decomposition:
            # W = B_cat @ A_cat = (Q_B R_B) @ (R_A^T Q_A^T) = Q_B @ (R_B @ R_A^T) @ Q_A^T
            A_list = [np.sqrt(w) * A for w, A, B in active_pairs]
            B_list = [np.sqrt(w) * B for w, A, B in active_pairs]
            A_cat = np.vstack(A_list).astype(np.float32)
            B_cat = np.hstack(B_list).astype(np.float32)

            Q_B, R_B = np.linalg.qr(B_cat)
            Q_A, R_A = np.linalg.qr(A_cat.T)

            M = R_B @ R_A.T
            U_M, S_M, Vt_M = np.linalg.svd(M, full_matrices=False)

            target_r = min(args.target_rank, len(S_M))
            U_r = Q_B @ U_M[:, :target_r]
            S_r = S_M[:target_r]
            Vt_r = Vt_M[:target_r, :] @ Q_A.T

            sqrt_S = np.sqrt(S_r)
            B_merged = (U_r * sqrt_S).astype(np.float32)
            A_merged = (Vt_r.T * sqrt_S).T.astype(np.float32)
            rank_str = f"Rank {target_r} (SVD from {A_cat.shape[0]})"

        print(f"  [{idx+1:02d}/{len(base_names)}] Fused {base} -> {rank_str}")
        writer.add_tensor(name_a, A_merged)
        writer.add_tensor(name_b, B_merged)
        merged_tensors += 2

    print(f"[*] Writing {merged_tensors} merged tensors to header...")
    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()

    out_size = os.path.getsize(args.output) / (1024 * 1024)
    print(f"[✓] Multi-LoRA Fusion completed successfully! Output: {args.output} ({out_size:.2f} MiB)")

if __name__ == "__main__":
    main()
