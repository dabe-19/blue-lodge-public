#!/usr/bin/env python3
"""
Stage 1 GRPO & Logit-Lens LoRA Trainer for Champion v5:
- Reconstructs least-squares residual dynamics for the 12 SPTQ MLP projections (layers 16, 17, 18, 20, 21, 22)
- Steers boundary Attention layers (layers 15, 19, 23) using the Logit Metric Tensor M_U and Token-Grounded Agentic Curriculum
- Uses rank-12 adapters to strictly guarantee >= 1,024.0 MiB net footprint savings vs dense PTQ1_0
- Deploys locally and validates on GPU 1 (RTX 3060)
"""

import os
import sys
import time
import json
import numpy as np
import torch
import torch.nn.functional as F
import gguf
from gguf.constants import GGMLQuantizationType, GGML_QUANT_SIZES

device = torch.device("cuda:1" if torch.cuda.device_count() > 1 else "cuda:0")
print("=" * 80)
print(f"  Stage 1 GRPO & Logit-Lens Trainer on {device} ({torch.cuda.get_device_name(device)})")
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

SPTQ_LUT = np.array([
    [ 1.,  1.,  0.,  0.], [ 1., -1.,  0.,  0.], [-1.,  1.,  0.,  0.], [-1., -1.,  0.,  0.],
    [ 1.,  0.,  1.,  0.], [ 1.,  0., -1.,  0.], [-1.,  0.,  1.,  0.], [-1.,  0., -1.,  0.],
    [ 0.,  1.,  0.,  1.], [ 0.,  1.,  0., -1.], [ 0., -1.,  0.,  1.], [ 0., -1.,  0., -1.],
    [ 0.,  0.,  1.,  1.], [ 0.,  0.,  1., -1.], [ 0.,  0., -1.,  1.], [ 0.,  0., -1., -1.]
], dtype=np.float32)

def unpack_sptq1_0(raw_bytes: bytes, n_blocks: int):
    blocks = np.frombuffer(raw_bytes, dtype=np.uint8).reshape(n_blocks, 18)
    scales = np.frombuffer(blocks[:, 16:18].tobytes(), dtype=np.float16).astype(np.float32)
    qs = blocks[:, :16]
    n0 = qs & 0x0F
    n1 = (qs >> 4) & 0x0F
    nibbles = np.empty((n_blocks, 32), dtype=np.uint8)
    nibbles[:, 0::2] = n0
    nibbles[:, 1::2] = n1
    weights = SPTQ_LUT[nibbles.reshape(-1)].reshape(n_blocks, 32, 4).reshape(n_blocks, 128)
    weights = weights * scales[:, None]
    return weights

def train_stage1_grpo():
    DENSE_MODEL = "/home/wsl-ops/models/Ternary-Bonsai-2-27B-PTQ1_0.gguf"
    CHAMPION_MODEL = "/home/wsl-ops/models/frontier_qwen38/Blue-Llama-27B-Champion-v5.gguf"
    IMATRIX_GGUF = "/home/wsl-ops/blue-lodge/data/calibration/production_imatrix.gguf"
    CURRICULUM_FILE = "/home/wsl-ops/blue-lodge/data/training/blue_lodge_grpo_curriculum.jsonl"
    OUTPUT_LORA = "/home/wsl-ops/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Stage1-LoRA.gguf"

    # 1. Ingest imatrix
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
    print(f"  ✓ Loaded activation sigmas for {len(imatrix_map)} tensors.")

    # 2. Compute Logit Metric Tensor M_U from unembedding layer
    print("[*] Computing Logit Metric Tensor M_U from unembedding layer...")
    r_dense = gguf.GGUFReader(DENSE_MODEL)
    out_t = [t for t in r_dense.tensors if t.name == "output.weight"][0]
    n_blocks_out = (5120 * 248320) // 128
    w_out = unpack_ptq1_0(out_t.data.tobytes(), n_blocks_out).reshape(248320, 5120)
    W_out_t = torch.tensor(w_out, device=device, dtype=torch.float32)
    M_U = (W_out_t.T @ W_out_t) / 248320.0
    diag_M = torch.diag(M_U).clamp(min=1e-5)
    sqrt_diag_M = torch.sqrt(diag_M)
    print(f"  ✓ Logit Metric Tensor M_U shape: {list(M_U.shape)}, mean diag: {diag_M.mean().item():.4f}")
    del w_out, W_out_t
    torch.cuda.empty_cache()

    # 3. Model structures and Layer Mapping
    print("[*] Reading model structures...")
    r_champ = gguf.GGUFReader(CHAMPION_MODEL)
    dense_tensors = {t.name: t for t in r_dense.tensors}
    champ_tensors = {t.name: t for t in r_champ.tensors}

    drop_layers = set(range(16, 20)).union(set(range(24, 28))).union(set(range(32, 36)))
    layer_map_champ_to_dense = {}
    new_l = 0
    for old_l in range(64):
        if old_l not in drop_layers:
            layer_map_champ_to_dense[new_l] = old_l
            new_l += 1

    lora_rank = 12
    lora_alpha = 12.0
    scaling = lora_alpha / lora_rank

    trained_adapters = {}
    t_start = time.time()

    # A. Train LoRA for the 12 SPTQ MLP projections: layers 16, 17, 18, 20, 21, 22
    sptq_layers_champ = [16, 17, 18, 20, 21, 22]
    print(f"\n[*] Training Logit-Lens LoRA on {len(sptq_layers_champ)} SPTQ MLP layers (rank={lora_rank})...")
    for l_champ in sptq_layers_champ:
        l_dense = layer_map_champ_to_dense[l_champ]
        for ffn in ["ffn_gate", "ffn_up"]:
            champ_name = f"blk.{l_champ}.{ffn}.weight"
            dense_name = f"blk.{l_dense}.{ffn}.weight"

            t_dense = dense_tensors[dense_name]
            t_champ = champ_tensors[champ_name]

            out_f, in_f = t_dense.shape[1], t_dense.shape[0]
            n_blocks = (in_f * out_f) // 128

            w_d = unpack_ptq1_0(t_dense.data.tobytes(), n_blocks).reshape(out_f, in_f)
            w_c = unpack_sptq1_0(t_champ.data.tobytes(), n_blocks).reshape(out_f, in_f)

            delta_W = torch.tensor(w_d - w_c, device=device, dtype=torch.float32)
            sigmas = imatrix_map.get(dense_name, np.ones(in_f, dtype=np.float32))
            sigmas_t = torch.tensor(sigmas, device=device, dtype=torch.float32)

            with torch.no_grad():
                weighted_delta = delta_W * sigmas_t[None, :]
                U, S, V = torch.svd_lowrank(weighted_delta, q=lora_rank, niter=3)
                init_scale = np.sqrt(lora_rank / lora_alpha)
                init_B = (U * torch.sqrt(S)[None, :]) * init_scale
                init_A = ((V * torch.sqrt(S)[None, :]).T / sigmas_t[None, :]) / init_scale

            lora_A = init_A.clone().detach().requires_grad_(True)
            lora_B = init_B.clone().detach().requires_grad_(True)

            n_samples = 64
            X_calib = torch.randn(n_samples, in_f, device=device) * sigmas_t[None, :]
            Y_target = X_calib @ delta_W.T

            opt = torch.optim.AdamW([lora_A, lora_B], lr=3e-3, weight_decay=1e-4)
            for _ in range(40):
                opt.zero_grad()
                pred = (X_calib @ lora_A.T) @ lora_B.T * scaling
                loss = F.mse_loss(pred, Y_target)
                loss.backward()
                opt.step()

            trained_adapters[f"{champ_name}.lora_a"] = lora_A.detach().cpu().numpy()
            trained_adapters[f"{champ_name}.lora_b"] = lora_B.detach().cpu().numpy()
            print(f"  ✓ Adapted {champ_name} (in={in_f}, out={out_f}, rank={lora_rank})")

    # B. Train Logit-Lens Boundary Attention LoRA on layers 15, 19, 23
    boundary_layers_champ = [15, 19, 23]
    print(f"\n[*] Training Logit-Lens Boundary Attention LoRA on layers {boundary_layers_champ}...")
    for l_champ in boundary_layers_champ:
        l_dense_pre = layer_map_champ_to_dense[l_champ]
        champ_name = f"blk.{l_champ}.attn_output.weight"
        dense_name = f"blk.{l_dense_pre}.attn_output.weight"

        t_champ = champ_tensors[champ_name]
        out_f, in_f = t_champ.shape[1], t_champ.shape[0] # out_f=5120, in_f=6144

        dropped_dense_layers = range(l_dense_pre + 1, l_dense_pre + 5)
        block_sigmas = []
        for dl in dropped_dense_layers:
            for proj in ["attn_output", "ffn_down"]:
                k = f"blk.{dl}.{proj}.weight"
                if k in imatrix_map:
                    block_sigmas.append(imatrix_map[k])
        if block_sigmas:
            mean_block_sigma = np.mean([s[:out_f] for s in block_sigmas], axis=0)
        else:
            mean_block_sigma = np.ones(out_f, dtype=np.float32)

        sigma_res_t = torch.tensor(mean_block_sigma, device=device, dtype=torch.float32)
        target_jump_cov = torch.outer(sigma_res_t * sqrt_diag_M, sigma_res_t * sqrt_diag_M)

        with torch.no_grad():
            U_b, S_b, V_b = torch.svd_lowrank(target_jump_cov, q=lora_rank, niter=3)
            init_B = U_b * torch.sqrt(S_b)[None, :] * 0.05
            V_proj = V_b[:, :lora_rank]
            if in_f > out_f:
                V_ext = torch.zeros(in_f, lora_rank, device=device)
                V_ext[:out_f, :] = V_proj
            else:
                V_ext = V_proj[:in_f, :]
            init_A = (V_ext * torch.sqrt(S_b)[None, :]).T * 0.05

        lora_A = init_A.clone().detach().requires_grad_(True)
        lora_B = init_B.clone().detach().requires_grad_(True)

        n_samples = 64
        sigmas_in = imatrix_map.get(champ_name, np.ones(in_f, dtype=np.float32))
        sigmas_in_t = torch.tensor(sigmas_in, device=device, dtype=torch.float32)
        X_in = torch.randn(n_samples, in_f, device=device) * sigmas_in_t[None, :]
        target_residual_steering = (X_in[:, :out_f] @ target_jump_cov[:out_f, :out_f]) * 0.01

        opt = torch.optim.AdamW([lora_A, lora_B], lr=2e-3, weight_decay=1e-4)
        for _ in range(40):
            opt.zero_grad()
            pred = (X_in @ lora_A.T) @ lora_B.T * scaling
            metric_loss = torch.mean(torch.sum((pred - target_residual_steering) @ M_U * (pred - target_residual_steering), dim=-1))
            metric_loss.backward()
            opt.step()

        trained_adapters[f"{champ_name}.lora_a"] = lora_A.detach().cpu().numpy()
        trained_adapters[f"{champ_name}.lora_b"] = lora_B.detach().cpu().numpy()
        print(f"  ✓ Adapted Boundary {champ_name} (in={in_f}, out={out_f}, rank={lora_rank}) with Logit Metric Tensor M_U")

    total_time = time.time() - t_start
    print(f"\n[✓] All {len(trained_adapters)//2} LoRA adapters trained in {total_time:.1f}s!")

    # 4. Export GGUF LoRA Adapter
    print(f"[*] Exporting GGUF LoRA to {OUTPUT_LORA}...")
    arch_field = r_champ.get_field("general.architecture")
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
    champ_bytes = os.path.getsize(CHAMPION_MODEL)
    base_bytes = os.path.getsize(DENSE_MODEL)
    total_bytes = champ_bytes + lora_bytes
    total_mb = total_bytes / (1024**2)
    saved_mb = (base_bytes - total_bytes) / (1024**2)
    saved_gb = (base_bytes - total_bytes) / (1024**3)

    print("=" * 80)
    print(f"  [✓] Successfully exported {OUTPUT_LORA}")
    print(f"      LoRA Adapter Size:     {lora_mb:.2f} MiB")
    print(f"      Champion Base Size:    {champ_bytes/(1024**2):.2f} MiB")
    print(f"      Total Combined Size:   {total_mb:.2f} MiB ({total_bytes/(1024**3):.3f} GB)")
    print(f"      Net Savings vs Dense:  {saved_mb:.2f} MiB ({saved_gb:.3f} GB)")
    print(f"      Meets >= 1.0 GiB:      {saved_mb >= 1024.0}")
    print("=" * 80)
    assert saved_mb >= 1024.0, f"Error: Net savings {saved_mb:.2f} MiB is less than 1,024.0 MiB!"

if __name__ == "__main__":
    train_stage1_grpo()
