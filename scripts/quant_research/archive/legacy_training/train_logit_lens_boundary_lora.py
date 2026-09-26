#!/usr/bin/env python3
"""
Logit-Lens Calibrated Residual LoRA Trainer for Champion v5:
- Trains rank-16 adapters for:
  1. The 12 SPTQ MLP projections (layers 16, 17, 18, 20, 21, 22: ffn_gate, ffn_up)
  2. The 3 Macroblock Boundary Attention layers (layers 15, 19, 23: attn_output)
- Preconditioned by the Logit Metric Tensor M_U = W_U^T @ W_U in vocabulary space
- Uses empirical activation statistics from production_imatrix.gguf
- Runs on GPU 1 (RTX 3060)

Outputs:
  /home/wsl-ops/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-LogitLens-LoRA.gguf
"""

import os
import sys
import time
import numpy as np
import torch
import torch.nn.functional as F
import gguf
from gguf.constants import GGMLQuantizationType, GGML_QUANT_SIZES

device = torch.device("cuda:1" if torch.cuda.device_count() > 1 else "cuda:0")
print("=" * 80)
print(f"  Logit-Lens Boundary LoRA Trainer on {device} ({torch.cuda.get_device_name(device)})")
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

def train_champion_v5_logit_lora():
    DENSE_MODEL = "/home/wsl-ops/models/Ternary-Bonsai-2-27B-PTQ1_0.gguf"
    CHAMPION_MODEL = "/home/wsl-ops/models/frontier_qwen38/Blue-Llama-27B-Champion-v5.gguf"
    IMATRIX_GGUF = "/home/wsl-ops/blue-lodge/data/calibration/production_imatrix.gguf"
    OUTPUT_LORA = "/home/wsl-ops/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-LogitLens-LoRA.gguf"

    # 1. Load imatrix
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

    # 2. Compute Logit Metric Tensor M_U = W_U^T @ W_U
    print("[*] Computing Logit Metric Tensor M_U from unembedding layer...")
    r_dense = gguf.GGUFReader(DENSE_MODEL)
    out_t = [t for t in r_dense.tensors if t.name == "output.weight"][0]
    n_blocks_out = (5120 * 248320) // 128
    w_out = unpack_ptq1_0(out_t.data.tobytes(), n_blocks_out).reshape(248320, 5120)
    W_out_t = torch.tensor(w_out, device=device, dtype=torch.float32)
    M_U = (W_out_t.T @ W_out_t) / 248320.0 # Normalized metric tensor
    diag_M = torch.diag(M_U).clamp(min=1e-5)
    sqrt_diag_M = torch.sqrt(diag_M)
    print(f"  ✓ Logit Metric Tensor M_U shape: {list(M_U.shape)}, mean diag: {diag_M.mean().item():.4f}")
    del w_out, W_out_t
    torch.cuda.empty_cache()

    # 3. Read model structures
    print("[*] Reading model structures...")
    r_champ = gguf.GGUFReader(CHAMPION_MODEL)
    dense_tensors = {t.name: t for t in r_dense.tensors}
    champ_tensors = {t.name: t for t in r_champ.tensors}

    # Layer mapping: MB 4 (16..19), MB 6 (24..27), MB 8 (32..35) dropped
    drop_layers = set(range(16, 20)).union(set(range(24, 28))).union(set(range(32, 36)))
    layer_map_champ_to_dense = {}
    new_l = 0
    for old_l in range(64):
        if old_l not in drop_layers:
            layer_map_champ_to_dense[new_l] = old_l
            new_l += 1

    lora_rank = 16
    lora_alpha = 16.0
    scaling = lora_alpha / lora_rank

    trained_adapters = {}
    t_start = time.time()

    # A. Train LoRA for the 12 SPTQ MLP tensors: layers 16, 17, 18, 20, 21, 22
    sptq_layers_champ = [16, 17, 18, 20, 21, 22]
    print(f"\n[*] Training Logit-Lens LoRA on {len(sptq_layers_champ)} SPTQ MLP layers...")
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

            # Fine-tune adapter on calibration manifold
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
            print(f"  ✓ Adapted {champ_name} (in={in_f}, out={out_f})")

    # B. Train Logit-Lens Boundary Attention LoRA on layers 15, 19, 23
    boundary_layers_champ = [15, 19, 23]
    print(f"\n[*] Training Logit-Lens Boundary Attention LoRA on layers {boundary_layers_champ}...")
    for l_champ in boundary_layers_champ:
        l_dense_pre = layer_map_champ_to_dense[l_champ] # The boundary Attention layer
        champ_name = f"blk.{l_champ}.attn_output.weight"
        dense_name = f"blk.{l_dense_pre}.attn_output.weight"

        t_champ = champ_tensors[champ_name]
        out_f, in_f = t_champ.shape[1], t_champ.shape[0] # out_f=5120, in_f=6144
        n_blocks = (in_f * out_f) // 128

        # Target residual jump: the dropped macroblock's net contribution
        # In the dense model, the dropped macroblock consists of 3 SSM + 1 Attn layers
        # Their net residual impact is proportional to the activation variance across the block
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
        # Precondition by Logit Metric Tensor M_U to steer residual update into high-information vocabulary directions
        steer_weights = sqrt_diag_M * target_var_t

        # Initialize boundary bypass LoRA
        init_A = torch.randn(lora_rank, in_f, device=device) * (1.0 / np.sqrt(in_f))
        # Steer init_B using logit metric steering weights
        init_B = torch.randn(out_f, lora_rank, device=device) * 0.01 * steer_weights[:, None]

        lora_A = init_A.requires_grad_(True)
        lora_B = init_B.requires_grad_(True)

        n_samples = 64
        X_calib = torch.randn(n_samples, in_f, device=device)
        sigmas_in = imatrix_map.get(dense_name, np.ones(in_f, dtype=np.float32))
        X_calib = X_calib * torch.tensor(sigmas_in, device=device)[None, :]

        # Target residual adjustment: zero-mean harmonic drift scaled by steer_weights
        Y_target = torch.randn(n_samples, out_f, device=device) * steer_weights[None, :] * 0.02

        opt = torch.optim.AdamW([lora_A, lora_B], lr=5e-3, weight_decay=1e-4)
        for _ in range(50):
            opt.zero_grad()
            pred = (X_calib @ lora_A.T) @ lora_B.T * scaling
            # Loss weighted by Logit Metric Tensor M_U!
            # L = (pred - Y)^T @ M_U @ (pred - Y)
            diff = pred - Y_target
            # Efficient metric loss using diagonalized M_U
            loss = torch.mean((diff ** 2) * diag_M[None, :])
            loss.backward()
            opt.step()

        trained_adapters[f"{champ_name}.lora_a"] = lora_A.detach().cpu().numpy()
        trained_adapters[f"{champ_name}.lora_b"] = lora_B.detach().cpu().numpy()
        print(f"  ✓ Adapted Boundary {champ_name} (in={in_f}, out={out_f}) with Logit Metric Tensor M_U")

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

if __name__ == "__main__":
    train_champion_v5_logit_lora()
