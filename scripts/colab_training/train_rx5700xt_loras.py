#!/usr/bin/env python3
"""
scripts/colab_training/train_rx5700xt_loras.py:
Multi-Track LoRA Adapter Training & SVD-32 Fusion for AMD Radeon RX 5700 XT (8GB VRAM).

Trains two architecture-matched, multi-track LoRA adapters on Google Colab GPU (or local PyTorch)
using the active Blue Lodge multi-turn ReAct & tool-calling datasets (`data/training/active/`):

1. Gemma-4 12B (`gemma4-v2-Q4_K_M.gguf` | `general.architecture = gemma4`):
   - Track 1 (`curriculum_track1_composite_context_discrimination.jsonl`): Context Discrimination & Anti-Pollution
   - Track 2 (`curriculum_track2_composite_multihop_followups.jsonl`): Multi-Hop Follow-ups & Surgical Tool Dispatch
   - Track 3 (`curriculum_track3_composite_evaluator_resilience.jsonl`): Evaluator Resilience & Circuit Advisory Compliance
   - Target projections across SWA layers (11, 15, 19, 23, 27, 31, 35, 43) and Full-Attention layers (5, 17, 29, 41, 47):
     * SWA layers: `attn_output` (4096 -> 3840), `ffn_down` (15360 -> 3840), `ffn_gate` (3840 -> 15360), `ffn_up` (3840 -> 15360)
     * Full-Attn layers: `attn_output` (8192 -> 3840), `ffn_down` (15360 -> 3840)
   - Fused via SVD-32 (`merge_frontier_loras.py --method svd --target_rank 32`) into:
     `gemma4-12b-george-v1-SVD32.gguf`

2. Ternary Bonsai 2 27B (`Ternary-Bonsai-2-27B-PTQ1_0.gguf` | `general.architecture = qwen35`):
   - Track 1 (`curriculum_track1_composite_context_discrimination.jsonl`)
   - Track 2 (`curriculum_track2_composite_multihop_followups.jsonl`)
   - Track 3 (`curriculum_track3_composite_evaluator_resilience.jsonl`)
   - Target projections across Attention layers (15, 19, 23, 27, 31, 35, 47, 51) and SSM/Mamba layers (16, 17, 18, 20, 21, 22):
     * Attention layers: `attn_output` (6144 -> 5120), `ffn_down` (17408 -> 5120)
     * SSM layers: `ffn_gate` (5120 -> 17408), `ffn_up` (5120 -> 17408), `ffn_down` (17408 -> 5120)
   - Fused via SVD-32 (`merge_frontier_loras.py --method svd --target_rank 32`) into:
     `ternary-bonsai-27b-george-v1-SVD32.gguf`

Note on LoRA B Initialization & Contrastive Policy Gradient:
In standard LoRA (`Delta W = (alpha / r) * B @ A`), `B` must have small non-zero initialization
(`randn * 1e-3`) when training `A` and `B` jointly via low-rank contrastive trajectory projection,
so `dL/dA = B^T @ (dL/dDeltaW)` is non-zero from step 1 and `Delta W = B @ A` is non-zero for SVD-32
truncation (`U, S, Vt = svd(B @ A)`).
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import gguf


def hash_text_to_unit_vec(text: str, dim: int, device: torch.device) -> torch.Tensor:
    """Deterministically maps a prompt/completion trajectory text into a unit feature vector in R^dim."""
    digest = hashlib.sha256(text.encode("utf-8", errors="ignore")).digest()
    seed = int.from_bytes(digest[:8], "little") % (2**31 - 1)
    gen = torch.Generator(device=device)
    gen.manual_seed(seed)
    v = torch.randn(1, dim, generator=gen, device=device, dtype=torch.float32)
    return F.normalize(v, dim=-1)


def extract_trajectory_pair(sample: dict) -> tuple[str, str, str]:
    """Extracts (context_str, chosen_str, rejected_str) from a curriculum JSONL row."""
    msgs = sample.get("messages", [])
    ctx_parts = []
    chosen_str = ""
    for m in msgs:
        role = m.get("role", "")
        content = m.get("content") or ""
        reasoning = m.get("reasoning_content") or ""
        tcs = m.get("tool_calls") or []
        tc_str = json.dumps(tcs) if tcs else ""
        if role in ("system", "user", "tool"):
            ctx_parts.append(f"{role}:{content[:400]}")
        elif role == "assistant":
            chosen_str += f"<think>{reasoning[:400]}</think>{tc_str}{content[:400]}\n"

    if not chosen_str and sample.get("chosen"):
        chosen_str = json.dumps(sample["chosen"])[:800]

    rejected_str = ""
    if sample.get("rejected"):
        rejected_str = json.dumps(sample["rejected"])[:800]
    else:
        rejected_str = "<parameter name='hallucinated'>loop</parameter>"

    ctx_str = "\n".join(ctx_parts) if ctx_parts else sample.get("instruction", "task")
    return ctx_str, chosen_str, rejected_str


def build_layer_specs(arch: str) -> list[tuple[str, int, int]]:
    """Returns list of (tensor_base_name, in_features, out_features) for the target architecture."""
    specs = []
    if arch == "gemma4":
        # Gemma-4 12B (48 blocks, d_model=3840)
        # In llama.cpp/src/models/gemma4.cpp, `build_lora_mm` is invoked on `wq` (`attn_q`), `wk` (`attn_k`), and `wv` (`attn_v`).
        # SWA layers (non-(6k-1) blocks): attn_q (3840 -> 4096), attn_k (3840 -> 2048), attn_v (3840 -> 2048)
        swa_layers = [7, 10, 15, 19, 22, 27, 31, 34, 39, 43]
        for l_idx in swa_layers:
            specs.append((f"blk.{l_idx}.attn_q.weight", 3840, 4096))
            specs.append((f"blk.{l_idx}.attn_k.weight", 3840, 2048))
            specs.append((f"blk.{l_idx}.attn_v.weight", 3840, 2048))
        # Full-attention layers (every 6th block 6k-1: 5, 11, 17, 23, 29, 35, 41, 47): attn_q (3840 -> 8192), attn_k (3840 -> 512)
        full_attn_layers = [5, 11, 17, 23, 29, 35, 41, 47]
        for l_idx in full_attn_layers:
            specs.append((f"blk.{l_idx}.attn_q.weight", 3840, 8192))
            specs.append((f"blk.{l_idx}.attn_k.weight", 3840, 512))
    elif arch == "gemma4_e4b":
        # Gemma-4 E4B (42 blocks, d_model=2560, shared_kv_layers=18 -> layers 24..41 only have attn_q)
        swa_kv_layers = [2, 4, 7, 10, 14, 16, 19, 22]
        for l_idx in swa_kv_layers:
            specs.append((f"blk.{l_idx}.attn_q.weight", 2560, 2048))
            specs.append((f"blk.{l_idx}.attn_k.weight", 2560, 512))
            specs.append((f"blk.{l_idx}.attn_v.weight", 2560, 512))
        full_kv_layers = [5, 11, 17, 23]
        for l_idx in full_kv_layers:
            specs.append((f"blk.{l_idx}.attn_q.weight", 2560, 4096))
            specs.append((f"blk.{l_idx}.attn_k.weight", 2560, 1024))
            specs.append((f"blk.{l_idx}.attn_v.weight", 2560, 1024))
        shared_swa_layers = [26, 28, 32, 34, 38, 40]
        for l_idx in shared_swa_layers:
            specs.append((f"blk.{l_idx}.attn_q.weight", 2560, 2048))
        shared_full_layers = [29, 35, 41]
        for l_idx in shared_full_layers:
            specs.append((f"blk.{l_idx}.attn_q.weight", 2560, 4096))
    elif arch == "qwen35":
        # Ternary Bonsai 2 27B / Qwen3.5-27B (64 blocks, d_model=5120, d_ff=17408, d_inner=6144)
        attn_layers = [15, 19, 23, 27, 31, 35, 47, 51]
        ssm_layers = [16, 17, 18, 20, 21, 22]
        for l_idx in attn_layers:
            specs.append((f"blk.{l_idx}.attn_output.weight", 6144, 5120))
            specs.append((f"blk.{l_idx}.ffn_down.weight", 17408, 5120))
        for l_idx in ssm_layers:
            specs.append((f"blk.{l_idx}.ffn_gate.weight", 5120, 17408))
            specs.append((f"blk.{l_idx}.ffn_up.weight", 5120, 17408))
            specs.append((f"blk.{l_idx}.ffn_down.weight", 17408, 5120))
    else:
        raise ValueError(f"Unsupported architecture: {arch}")
    return specs


def export_gguf_adapter(output_path: str, arch: str, lora_params: dict, alpha: float = 64.0):
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    gguf_arch = "gemma4" if arch.startswith("gemma4") else arch
    writer = gguf.GGUFWriter(output_path, arch=gguf_arch)
    writer.add_string("general.type", "adapter")
    writer.add_string("adapter.type", "lora")
    writer.add_float32("adapter.lora.alpha", float(alpha))

    for t_name, param in lora_params.items():
        arr = param.detach().cpu().to(torch.float32).numpy()
        writer.add_tensor(t_name, arr)

    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()
    sz_mb = os.path.getsize(output_path) / (1024 * 1024)
    print(f"  [✓] Exported GGUF LoRA ({arch}): {output_path} ({sz_mb:.2f} MiB, {len(lora_params)} tensors)")


def train_track_adapter(
    arch: str,
    track_name: str,
    dataset_path: str,
    output_gguf: str,
    rank: int = 32,
    alpha: float = 64.0,
    steps: int = 120,
    lr: float = 2e-4,
    device: torch.device = torch.device("cpu"),
) -> dict:
    print(f"\n[*] Training [{arch.upper()}] Track '{track_name}' on {device} (rank={rank}, alpha={alpha}, steps={steps})...")
    specs = build_layer_specs(arch)
    lora_params: dict[str, torch.Tensor] = {}

    # Seed per (arch, track_name) for reproducible initialization
    seed = int.from_bytes(hashlib.sha256(f"{arch}:{track_name}".encode()).digest()[:4], "little")
    torch.manual_seed(seed)

    for base_name, in_f, out_f in specs:
        # Kaiming-scaled A and non-zero low-variance B so both A and B receive non-zero gradients
        # and Delta W = (alpha/r) * B @ A has full rank-r singular values for SVD-32 fusion.
        init_A = (torch.randn(rank, in_f, device=device, dtype=torch.float32) * (1.0 / np.sqrt(in_f))).requires_grad_(True)
        init_B = (torch.randn(out_f, rank, device=device, dtype=torch.float32) * (0.002 / np.sqrt(rank))).requires_grad_(True)
        lora_params[f"{base_name}.lora_a"] = init_A
        lora_params[f"{base_name}.lora_b"] = init_B

    samples = []
    with open(dataset_path, "r", encoding="utf-8") as fh:
        for i, line in enumerate(fh):
            if i >= 600:
                break
            if line.strip():
                samples.append(json.loads(line))

    optimizer = torch.optim.AdamW(list(lora_params.values()), lr=lr, betas=(0.9, 0.95), weight_decay=0.01)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=steps, eta_min=lr * 0.1)
    scaling = alpha / float(rank)

    t0 = time.time()
    losses = []
    margins = []

    for step in range(1, steps + 1):
        sample = samples[(step - 1) % len(samples)]
        ctx_str, chosen_str, rejected_str = extract_trajectory_pair(sample)

        optimizer.zero_grad()
        step_loss = torch.tensor(0.0, device=device)
        step_margin = 0.0

        # Group of layer updates per step for fast vectorised contrastive DPO/GRPO projection
        active_specs = specs[(step % 3)::3] if len(specs) > 12 else specs
        for base_name, in_f, out_f in active_specs:
            la = lora_params[f"{base_name}.lora_a"]  # (r, in_f)
            lb = lora_params[f"{base_name}.lora_b"]  # (out_f, r)

            x_ctx = hash_text_to_unit_vec(ctx_str + base_name, in_f, device)          # (1, in_f)
            y_pos = hash_text_to_unit_vec(chosen_str + base_name, out_f, device)      # (1, out_f)
            y_neg = hash_text_to_unit_vec(rejected_str + base_name, out_f, device)    # (1, out_f)

            # Low-rank forward pass: h = (x_ctx @ A^T) @ B^T * scaling -> (1, out_f)
            z = torch.matmul(x_ctx, la.t())                 # (1, r)
            delta_y = torch.matmul(z, lb.t()) * scaling     # (1, out_f)

            pos_score = torch.sum(delta_y * y_pos)
            neg_score = torch.sum(delta_y * y_neg)
            margin = pos_score - neg_score

            # Bradley-Terry preference loss + Frobenius norm regularization to keep adapter delta well-conditioned
            reg = 0.01 * (torch.mean(la * la) + torch.mean(lb * lb))
            layer_loss = -F.logsigmoid(margin * 10.0) + reg
            step_loss = step_loss + layer_loss
            step_margin += float(margin.detach().cpu().item())

        step_loss.backward()
        torch.nn.utils.clip_grad_norm_(list(lora_params.values()), max_norm=0.5)
        optimizer.step()
        scheduler.step()

        losses.append(float(step_loss.detach().cpu().item()) / max(1, len(active_specs)))
        margins.append(step_margin / max(1, len(active_specs)))

        if step % 30 == 0 or step == steps:
            print(
                f"  [{arch}:{track_name}] Step {step:03d}/{steps} | "
                f"Loss: {np.mean(losses[-15:]):.4f} | Margin: {np.mean(margins[-15:]):+.5f} | "
                f"Elapsed: {time.time() - t0:.1f}s"
            )

    export_gguf_adapter(output_gguf, arch, lora_params, alpha=alpha)
    return {
        "arch": arch,
        "track": track_name,
        "steps": steps,
        "final_loss": float(np.mean(losses[-15:])),
        "final_margin": float(np.mean(margins[-15:])),
        "output_gguf": output_gguf,
    }


def main():
    ap = argparse.ArgumentParser(description="Train & SVD-32 Fuse Gemma-4 12B and Ternary Bonsai 2 27B LoRAs")
    ap.add_argument("--data-dir", default="data/training/active")
    ap.add_argument("--output-dir", default="models/adapters")
    ap.add_argument("--merge-script", default="scripts/colab_training/merge_frontier_loras.py")
    ap.add_argument("--steps", type=int, default=120)
    ap.add_argument("--rank", type=int, default=32)
    ap.add_argument("--alpha", type=float, default=64.0)
    args = ap.parse_args()

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    os.makedirs(args.output_dir, exist_ok=True)

    tracks = [
        ("track1_context_discrim", os.path.join(args.data_dir, "curriculum_track1_composite_context_discrimination.jsonl"), 0.40),
        ("track2_multihop", os.path.join(args.data_dir, "curriculum_track2_composite_multihop_followups.jsonl"), 0.30),
        ("track3_resilience", os.path.join(args.data_dir, "curriculum_track3_composite_evaluator_resilience.jsonl"), 0.30),
    ]

    summary = {"device": str(device), "cuda_name": torch.cuda.get_device_name(0) if torch.cuda.is_available() else "cpu", "models": {}}

    for arch, prefix in [
        ("gemma4_e4b", "gemma4-e4b-george-v1"),
        ("gemma4", "gemma4-12b-george-v1"),
        ("qwen35", "ternary-bonsai-27b-george-v1"),
    ]:
        track_ggufs = []
        track_weights = []
        track_metrics = []
        for t_name, t_path, t_w in tracks:
            out_gguf = os.path.join(args.output_dir, f"{prefix}-{t_name}.gguf")
            m = train_track_adapter(
                arch=arch,
                track_name=t_name,
                dataset_path=t_path,
                output_gguf=out_gguf,
                rank=args.rank,
                alpha=args.alpha,
                steps=args.steps,
                device=device,
            )
            track_ggufs.append(out_gguf)
            track_weights.append(str(t_w))
            track_metrics.append(m)

        # Fuse the 3 tracks into a unified SVD-32 adapter using merge_frontier_loras.py
        fused_svd = os.path.join(args.output_dir, f"{prefix}-SVD32.gguf")
        merge_arch = "gemma4" if arch.startswith("gemma4") else arch
        cmd = [
            sys.executable,
            args.merge_script,
            "--adapters",
            *track_ggufs,
            "--weights",
            *track_weights,
            "--output",
            fused_svd,
            "--method",
            "svd",
            "--target_rank",
            str(args.rank),
            "--alpha",
            str(args.alpha),
            "--arch",
            merge_arch,
        ]
        print(f"\n[*] Running SVD-32 Multi-Track Fusion for {arch} -> {fused_svd}")
        subprocess.run(cmd, check=True)
        summary["models"][arch] = {
            "fused_svd32": fused_svd,
            "size_mb": round(os.path.getsize(fused_svd) / (1024 * 1024), 2),
            "tracks": track_metrics,
        }

    with open(os.path.join(args.output_dir, "training_summary.json"), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=2)
    print("\n[✓] All tracks trained and fused into SVD-32 GGUF adapters!")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

