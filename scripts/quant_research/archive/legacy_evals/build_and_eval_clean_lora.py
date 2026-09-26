#!/usr/bin/env python3
"""
Train Targeted Clean Residual SVD LoRA on RPS-UnityGain:
1. Uses Qwen3.8-27B-SPTQ-RPS-UnityGain.gguf as the base model.
2. Adapts ONLY the 102 pruned ffn_gate & ffn_up tensors in layers 8..58.
3. Zero adaptation on ffn_down (preserves native MMVQ decode speed).
4. Zero adaptation on attention or SSM.
5. Measures WikiText-2 PPL across 4 chunks.
"""

import os
import sys
import time
import numpy as np
import torch
import torch.nn.functional as F
import gguf
from gguf.constants import GGMLQuantizationType, GGML_QUANT_SIZES
import subprocess
import re

device = torch.device("cuda:1" if torch.cuda.is_available() else "cpu")
print("=" * 80)
print(f"  Targeted Clean SVD LoRA Trainer on {device} ({torch.cuda.get_device_name(device)})")
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

def train_and_eval():
    DENSE_MODEL = "/home/wsl-ops/models/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf"
    SPARSE_MODEL = "/home/wsl-ops/models/frontier_qwen38/Qwen3.8-27B-SPTQ-RPS-UnityGain.gguf"
    IMATRIX_GGUF = "/home/wsl-ops/blue-lodge/data/calibration/production_imatrix.gguf"
    OUTPUT_LORA = "/home/wsl-ops/models/frontier_qwen38/qwen38-sptq-clean-rps-lora.gguf"

    print(f"[*] Loading imatrix from {IMATRIX_GGUF}...")
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

    print(f"[*] Reading base models...")
    r_dense = gguf.GGUFReader(DENSE_MODEL)
    r_sparse = gguf.GGUFReader(SPARSE_MODEL)
    dense_tensors = {t.name: t for t in r_dense.tensors}
    sparse_tensors = {t.name: t for t in r_sparse.tensors}

    target_layers = list(range(8, 59)) # 51 layers
    lora_rank = 16
    lora_alpha = 16.0
    scaling = lora_alpha / lora_rank

    trained_adapters = {}
    t_start = time.time()
    total_tensors = len(target_layers) * 2
    count = 0

    print(f"[*] Training Clean SVD LoRA across {len(target_layers)} layers (ffn_gate & ffn_up only, rank={lora_rank})...")

    for l_idx, layer_idx in enumerate(target_layers):
        for ffn_type in ["ffn_gate", "ffn_up"]:
            tname = f"blk.{layer_idx}.{ffn_type}.weight"
            if tname not in dense_tensors or tname not in sparse_tensors:
                continue

            t_dense = dense_tensors[tname]
            t_sparse = sparse_tensors[tname]

            ne0 = t_dense.shape[0] # in_features (5120)
            ne1 = t_dense.shape[1] # out_features (17408)
            out_f = ne1
            in_f = ne0
            n_blocks = (ne0 * ne1) // 128

            w_dense = unpack_ptq1_0(t_dense.data.tobytes(), n_blocks).reshape(out_f, in_f)
            w_sptq = unpack_sptq1_0(t_sparse.data.tobytes(), n_blocks).reshape(out_f, in_f)

            delta_W = torch.tensor(w_dense - w_sptq, device=device, dtype=torch.float32)
            sigmas = imatrix_map.get(tname, np.ones(in_f, dtype=np.float32))
            sigmas_t = torch.tensor(sigmas, device=device, dtype=torch.float32)

            with torch.no_grad():
                weighted_delta = delta_W * sigmas_t[None, :]
                U, S, V = torch.svd_lowrank(weighted_delta, q=lora_rank, niter=2)
                init_scale = np.sqrt(lora_rank / lora_alpha)
                init_B = init_scale * U * torch.sqrt(S)[None, :]
                init_A = init_scale * (torch.sqrt(S)[:, None] * V.T) / torch.clamp(sigmas_t[None, :], min=1e-5)

            lora_A = init_A.clone().detach().requires_grad_(True)
            lora_B = init_B.clone().detach().requires_grad_(True)

            n_samples = 128
            X_calib = torch.randn(n_samples, in_f, device=device) * sigmas_t[None, :]
            Y_target = X_calib @ delta_W.T

            opt = torch.optim.AdamW([lora_A, lora_B], lr=1e-3, weight_decay=1e-4)
            for step in range(25):
                opt.zero_grad()
                pred = (X_calib @ lora_A.T) @ lora_B.T * scaling
                loss = F.mse_loss(pred, Y_target)
                loss.backward()
                opt.step()

            trained_adapters[f"{tname}.lora_a"] = lora_A.detach().cpu().numpy()
            trained_adapters[f"{tname}.lora_b"] = lora_B.detach().cpu().numpy()

            del delta_W, sigmas_t, weighted_delta, U, S, V, init_A, init_B, lora_A, lora_B, X_calib, Y_target
            torch.cuda.empty_cache()

            count += 1
            if count % 25 == 0 or count == total_tensors:
                elapsed = time.time() - t_start
                print(f"  [Progress {count:3d}/{total_tensors}] Trained {tname} ({elapsed:.1f}s)")
                sys.stdout.flush()

    total_train_time = time.time() - t_start
    print(f"\n[✓] Trained {total_tensors} tensors in {total_train_time:.1f}s ({total_train_time/60:.1f} min)!")

    print(f"\n[*] Exporting Clean GGUF LoRA Adapter to {OUTPUT_LORA}...")
    writer = gguf.GGUFWriter(OUTPUT_LORA, "qwen35")
    writer.add_string("general.type", "adapter")
    writer.add_string("adapter.type", "lora")
    writer.add_float32("adapter.lora.alpha", float(lora_alpha))

    for name, arr in trained_adapters.items():
        writer.add_tensor(name, arr.astype(np.float32))

    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()

    lora_size_mb = os.path.getsize(OUTPUT_LORA) / (1024 * 1024)
    print(f"  ✓ Clean GGUF LoRA Adapter exported: {OUTPUT_LORA} ({lora_size_mb:.2f} MB)")

    # Measure Perplexity
    print("\n[*] Measuring WikiText-2 PPL (4 chunks, 512 ctx)...")
    cmd_ppl = [
        "docker", "exec", "-e", "CUDA_VISIBLE_DEVICES=1", "george-prism-server",
        "/workspace/build_prism/llama.cpp-prism/build/bin/llama-perplexity",
        "-m", "/models/frontier_qwen38/Qwen3.8-27B-SPTQ-RPS-UnityGain.gguf",
        "--lora", "/models/frontier_qwen38/qwen38-sptq-clean-rps-lora.gguf",
        "-f", "/workspace/data/calibration/wiki.test.raw",
        "-c", "512", "-b", "2048", "-ngl", "99", "--chunks", "4"
    ]
    t0 = time.time()
    res = subprocess.run(cmd_ppl, capture_output=True, text=True)
    t_ppl = time.time() - t0
    m = re.search(r"Final estimate:\s+PPL\s+=\s+([0-9\.]+)\s+\+/-\s+([0-9\.]+)", res.stdout + res.stderr)
    chunks = re.findall(r"\[([0-9]+)\]([0-9\.]+)", res.stdout + res.stderr)
    if m:
        ppl = float(m.group(1))
        err = float(m.group(2))
        print(f"  ✓ Clean RPS + LoRA PPL: {ppl:.4f} +/- {err:.4f} ({t_ppl:.1f}s)")
        print("  ✓ Per-chunk PPL: " + ", ".join([f"Chunk {c[0]}: {c[1]}" for c in chunks]))
    else:
        print(f"  [!] Perplexity output:\n{(res.stdout + res.stderr)[-500:]}")

if __name__ == "__main__":
    train_and_eval()
