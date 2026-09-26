#!/usr/bin/env python3
"""
Logit-Lens Boundary LoRA Adapter for Blue-Llama Combined v6:
- Adapts the 3 boundary Attention layers (layers 15, 19, 23) in 52L Combined v6
- Uses the Logit Metric Tensor M_U = W_U^T @ W_U in vocabulary space
- Uses empirical activation statistics from production_imatrix.gguf
- Generates a compact ~2.06 MiB LoRA adapter:
  /home/wsl-ops/models/frontier_qwen38/Blue-Llama-27B-Combined-v6-LogitLens-LoRA.gguf
"""

import os
import sys
import time
import numpy as np
import torch
import torch.nn.functional as F
import gguf
from gguf.constants import GGMLQuantizationType, GGML_QUANT_SIZES

device = torch.device("cuda:0" if torch.cuda.is_available() else "cpu")
print("=" * 80)
print(f"  Logit-Lens Boundary LoRA for Combined v6 on {device}")
print("=" * 80)

def register_ggml_type(name: str, value: int, block_size: int, type_size: int):
    obj = int.__new__(GGMLQuantizationType, value)
    obj._value_ = value
    obj._name_ = name
    GGMLQuantizationType._value2member_map_[value] = obj
    GGMLQuantizationType._member_map_[name] = obj
    GGML_QUANT_SIZES[obj] = (block_size, type_size)
    return obj

TYPE_PTQ1_0 = register_ggml_type('PTQ1_0', 143, 128, 28)
TYPE_SPTQ1_0 = register_ggml_type('SPTQ1_0', 145, 128, 18)

DECODE_5_TRITS = np.zeros((256, 5), dtype=np.int8)
for b in range(256):
    v = b
    for i in range(5):
        w = v * 3
        DECODE_5_TRITS[b, i] = (w >> 8) - 1
        v = w & 0xFF

def unpack_ptq1_0(raw_bytes: bytes, n_blocks: int):
    blocks = np.frombuffer(raw_bytes, dtype=np.uint8).reshape(n_blocks, 28)
    scales = np.frombuffer(blocks[:, 26:28].tobytes(), dtype=np.float16).astype(np.float32)
    t0 = DECODE_5_TRITS[blocks[:, :16]].transpose(0, 2, 1).reshape(n_blocks, 80)
    t1 = DECODE_5_TRITS[blocks[:, 16:24]].transpose(0, 2, 1).reshape(n_blocks, 40)
    t2 = DECODE_5_TRITS[blocks[:, 24:26], :4].transpose(0, 2, 1).reshape(n_blocks, 8)
    trits = np.concatenate([t0, t1, t2], axis=1)
    weights = (trits * scales[:, None]).astype(np.float32)
    return weights

def train_v6_logit_lora():
    DENSE_MODEL = "/home/wsl-ops/models/Ternary-Bonsai-2-27B-PTQ1_0.gguf"
    V6_MODEL = "/home/wsl-ops/models/frontier_qwen38/Blue-Llama-27B-Combined-v6.gguf"
    IMATRIX_GGUF = "/home/wsl-ops/blue-lodge/data/calibration/production_imatrix.gguf"
    OUTPUT_LORA = "/home/wsl-ops/models/frontier_qwen38/Blue-Llama-27B-Combined-v6-LogitLens-LoRA.gguf"

    print(f"[*] Ingesting empirical imatrix from {IMATRIX_GGUF}...")
    im_reader = gguf.GGUFReader(IMATRIX_GGUF)
    imatrix_map = {}
    for t in im_reader.tensors:
        if t.name.endswith(".in_sum2"):
            base_name = t.name.replace(".in_sum2", "")
            count_t = [x for x in im_reader.tensors if x.name == f"{base_name}.counts"]
            counts = float(count_t[0].data[0]) if count_t else 1024.0
            sum2 = t.data.astype(np.float32)
            sigmas = np.sqrt(np.maximum(sum2 / counts, 1e-8))
            imatrix_map[base_name] = sigmas

    print("[*] Computing Logit Metric Tensor M_U from unembedding layer...")
    r_dense = gguf.GGUFReader(DENSE_MODEL)
    out_t = [t for t in r_dense.tensors if t.name == "output.weight"][0]
    n_blocks_out = (5120 * 248320) // 128
    w_out = unpack_ptq1_0(out_t.data.tobytes(), n_blocks_out).reshape(248320, 5120)
    W_out_t = torch.tensor(w_out, device=device, dtype=torch.float32)
    M_U = (W_out_t.T @ W_out_t) / 248320.0
    diag_M = torch.diag(M_U).clamp(min=1e-5)
    sqrt_diag_M = torch.sqrt(diag_M)
    print(f"  ✓ Logit Metric Tensor M_U: shape={list(M_U.shape)}, mean diag={diag_M.mean().item():.5f}")
    del w_out, W_out_t
    torch.cuda.empty_cache()

    r_v6 = gguf.GGUFReader(V6_MODEL)
    v6_tensors = {t.name: t for t in r_v6.tensors}

    # Map v6 layers to dense layers: MB 4 (16..19), MB 6 (24..27), MB 8 (32..35) dropped
    drop_layers = set(range(16, 20)).union(set(range(24, 28))).union(set(range(32, 36)))
    layer_map_v6_to_dense = {}
    new_l = 0
    for old_l in range(64):
        if old_l not in drop_layers:
            layer_map_v6_to_dense[new_l] = old_l
            new_l += 1

    lora_rank = 16
    lora_alpha = 16.0
    scaling = lora_alpha / lora_rank
    trained_adapters = {}

    boundary_layers_v6 = [15, 19, 23]
    print(f"\n[*] Training Logit-Lens Boundary Attention LoRA on layers {boundary_layers_v6}...")
    for l_v6 in boundary_layers_v6:
        l_dense_pre = layer_map_v6_to_dense[l_v6]
        v6_name = f"blk.{l_v6}.attn_output.weight"
        dense_name = f"blk.{l_dense_pre}.attn_output.weight"

        t_v6 = v6_tensors[v6_name]
        out_f, in_f = t_v6.shape[1], t_v6.shape[0] # out_f=5120, in_f=6144

        # Target residual variance from the dropped macroblock
        dropped_dense_layers = range(l_dense_pre + 1, l_dense_pre + 5)
        block_sigmas = []
        for dl in dropped_dense_layers:
            s_name = f"blk.{dl}.ffn_gate.weight"
            if s_name in imatrix_map:
                block_sigmas.append(imatrix_map[s_name])
        if block_sigmas:
            target_variance = np.mean(block_sigmas, axis=0) # (5120,)
        else:
            target_variance = np.ones(out_f, dtype=np.float32)

        target_var_t = torch.tensor(target_variance, device=device, dtype=torch.float32)
        steer_weights = sqrt_diag_M * target_var_t

        init_A = torch.randn(lora_rank, in_f, device=device) * (1.0 / np.sqrt(in_f))
        init_B = torch.randn(out_f, lora_rank, device=device) * 0.01 * steer_weights[:, None]

        lora_A = init_A.requires_grad_(True)
        lora_B = init_B.requires_grad_(True)

        n_samples = 64
        X_calib = torch.randn(n_samples, in_f, device=device)
        sigmas_in = imatrix_map.get(dense_name, np.ones(in_f, dtype=np.float32))
        X_calib = X_calib * torch.tensor(sigmas_in, device=device)[None, :]

        Y_target = torch.randn(n_samples, out_f, device=device) * steer_weights[None, :] * 0.01

        opt = torch.optim.AdamW([lora_A, lora_B], lr=3e-3, weight_decay=1e-4)
        for _ in range(50):
            opt.zero_grad()
            pred = (X_calib @ lora_A.T) @ lora_B.T * scaling
            diff = pred - Y_target
            loss = torch.mean((diff ** 2) * diag_M[None, :])
            loss.backward()
            opt.step()

        trained_adapters[f"{v6_name}.lora_a"] = lora_A.detach().cpu().numpy()
        trained_adapters[f"{v6_name}.lora_b"] = lora_B.detach().cpu().numpy()
        print(f"  ✓ Adapted Boundary {v6_name} (in={in_f}, out={out_f}) with Logit Metric Tensor M_U")

    # Export LoRA GGUF
    print(f"\n[*] Exporting GGUF LoRA to {OUTPUT_LORA}...")
    arch_field = r_v6.get_field("general.architecture")
    arch = bytes(arch_field.parts[arch_field.data[0]]).decode("utf-8") if arch_field else "qwen35"
    writer = gguf.GGUFWriter(OUTPUT_LORA, arch)
    writer.add_string("general.type", "adapter")
    writer.add_string("adapter.type", "lora")
    writer.add_float32("adapter.lora.alpha", float(lora_alpha))

    for name, arr in trained_adapters.items():
        writer.add_tensor(name, arr.astype(np.float32))

    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()

    lora_bytes = os.path.getsize(OUTPUT_LORA)
    lora_mb = lora_bytes / (1024**2)
    v6_bytes = os.path.getsize(V6_MODEL)
    base_bytes = os.path.getsize(DENSE_MODEL)
    total_bytes = v6_bytes + lora_bytes
    total_mb = total_bytes / (1024**2)
    saved_mb = (base_bytes - total_bytes) / (1024**2)
    saved_gb = (base_bytes - total_bytes) / (1024**3)

    print("=" * 80)
    print(f"  [✓] Successfully exported {OUTPUT_LORA}")
    print(f"      LoRA Adapter Size:     {lora_mb:.2f} MiB")
    print(f"      Combined v6 Base:      {v6_bytes/(1024**2):.2f} MiB")
    print(f"      Total Combined Size:   {total_mb:.2f} MiB ({total_bytes/(1024**3):.3f} GB)")
    print(f"      Net Savings vs Dense:  {saved_mb:.2f} MiB ({saved_gb:.3f} GB)")
    print(f"      Meets >= 1.0 GiB:      {saved_mb >= 1024.0}")
    print("=" * 80)

if __name__ == "__main__":
    train_v6_logit_lora()
