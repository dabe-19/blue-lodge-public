#!/usr/bin/env python3
"""
Residual-Preserving Sparsity (RPS) with Closed-Form LSQ Optimal Scales:
- Keeps ffn_down 100% DENSE PTQ1_0 across all 65 layers.
- Keeps boundary layers (0..7 and 59..64) 100% DENSE PTQ1_0.
- Applies 16-state codebook search + Closed-Form LSQ Optimal Block Scale (d*)
  to ffn_gate and ffn_up in layers 8..58 (51 layers, 102 matrices).
- Completely eliminates the +28.5% scale heuristic distortion.
"""

import os
import sys
sys.path.insert(0, '/home/wsl-ops/blue-lodge')
import time
import numpy as np
import torch
import gguf
from gguf.constants import GGMLQuantizationType, GGML_QUANT_SIZES, GGUFValueType
import subprocess
import re

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

device = torch.device('cuda:1' if torch.cuda.is_available() else 'cpu')
print(f"[*] Hardware Context on {device} ({torch.cuda.get_device_name(device)})")

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
    return trits, scales

SPTQ_LUT = torch.tensor([
    [ 1.,  1.,  0.,  0.], [ 1., -1.,  0.,  0.], [-1.,  1.,  0.,  0.], [-1., -1.,  0.,  0.],
    [ 1.,  0.,  1.,  0.], [ 1.,  0., -1.,  0.], [-1.,  0.,  1.,  0.], [-1.,  0., -1.,  0.],
    [ 0.,  1.,  0.,  1.], [ 0.,  1.,  0., -1.], [ 0., -1.,  0.,  1.], [ 0., -1.,  0., -1.],
    [ 0.,  0.,  1.,  1.], [ 0.,  0.,  1., -1.], [ 0.,  0., -1.,  1.], [ 0.,  0., -1., -1.]
], dtype=torch.float32, device=device)

@torch.no_grad()
def quantize_unit_quads_cuda(W_unit_quads: torch.Tensor, S_quads: torch.Tensor, chunk_size: int = 524288):
    N = len(W_unit_quads)
    best_idx = torch.empty(N, dtype=torch.long, device=device)
    lut_exp = SPTQ_LUT.unsqueeze(0)

    for i in range(0, N, chunk_size):
        end = min(i + chunk_size, N)
        w_chunk = W_unit_quads[i:end].unsqueeze(1)
        s_chunk = S_quads[i:end].unsqueeze(1)
        n_c = end - i

        diff = lut_exp - w_chunk
        weighted_mse = torch.sum((diff * s_chunk)**2, dim=-1)
        dc_drift = torch.abs(torch.sum(diff * s_chunk, dim=-1))
        jitter = torch.rand(n_c, 16, device=device) * 1e-5

        cost = weighted_mse + 0.6 * dc_drift + jitter
        best_idx[i:end] = torch.argmin(cost, dim=-1)

    return best_idx

def copy_gguf_metadata(reader, writer):
    copied = 0
    for k, f in reader.fields.items():
        if k.startswith('GGUF.') or k == 'general.architecture':
            continue
        try:
            vtype = f.types[0]
            sub_type = f.types[1] if len(f.types) > 1 else None
            if vtype == GGUFValueType.ARRAY:
                if sub_type == GGUFValueType.STRING:
                    val = [bytes(f.parts[idx]).decode('utf-8', errors='ignore') for idx in f.data]
                else:
                    val = [f.parts[idx].item() if hasattr(f.parts[idx], 'item') else f.parts[idx] for idx in f.data]
                writer.add_key_value(k, val, vtype, sub_type=sub_type)
            elif vtype == GGUFValueType.STRING:
                val = bytes(f.parts[f.data[0]]).decode('utf-8', errors='ignore')
                writer.add_key_value(k, val, vtype)
            else:
                val = f.parts[f.data[0]].item() if hasattr(f.parts[f.data[0]], 'item') else f.parts[f.data[0]]
                writer.add_key_value(k, val, vtype)
            copied += 1
        except Exception:
            pass

def pack_lsq_rps(output_path):
    BASE_MODEL = "/home/wsl-ops/models/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf"
    IMATRIX_GGUF = "/home/wsl-ops/blue-lodge/data/calibration/production_imatrix.gguf"

    print("=" * 80)
    print("  Packing RPS Model with Closed-Form LSQ Optimal Scales")
    print(f"  Base Model:   {BASE_MODEL}")
    print(f"  Output Model: {output_path}")
    print("=" * 80)

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

    reader = gguf.GGUFReader(BASE_MODEL)
    arch_field = reader.get_field('general.architecture')
    arch = bytes(arch_field.parts[arch_field.data[0]]).decode('utf-8') if arch_field else "qwen2"
    writer = gguf.GGUFWriter(output_path, arch)
    copy_gguf_metadata(reader, writer)

    rps_layers = set(range(8, 59)) # 51 layers
    target_names = ('ffn_gate.weight', 'ffn_up.weight')

    pruned = 0
    dense = 0
    t0 = time.time()

    for idx, t in enumerate(reader.tensors):
        name = t.name
        shape = list(t.shape)
        tensor_type = t.tensor_type

        should_prune = False
        if name.startswith("blk.") and tensor_type == TYPE_PTQ1_0:
            l_num = int(name.split(".")[1])
            if l_num in rps_layers and any(k in name for k in target_names):
                should_prune = True

        if should_prune:
            ne0 = shape[0]
            out_f = shape[1]
            in_f = ne0
            raw_bytes = bytes(t.data)
            n_blocks = len(raw_bytes) // 28
            n_quads = (n_blocks * 128) // 4
            blocks_per_row = in_f // 128
            quads_per_row = in_f // 4

            trits, scales_orig = unpack_ptq1_0(raw_bytes, n_blocks)

            sigmas = imatrix_map.get(name, np.ones(ne0, dtype=np.float32))
            sigmas_quad_base = sigmas.reshape(quads_per_row, 4)
            sigmas_quad_np = np.broadcast_to(sigmas_quad_base, (out_f, quads_per_row, 4)).reshape(n_quads, 4)
            S_quads = torch.tensor(sigmas_quad_np, device=device, dtype=torch.float32)

            trits_quad = trits.reshape(n_quads, 4).astype(np.float32)
            W_unit_quads = torch.tensor(trits_quad, device=device, dtype=torch.float32)

            best_idx = quantize_unit_quads_cuda(W_unit_quads, S_quads)

            # Compute Closed-Form LSQ Optimal Scales per block:
            # d* = d_orig * (sum(S^2 * T * Q) / sum(S^2 * Q^2))
            with torch.no_grad():
                Q_quads = SPTQ_LUT[best_idx] # (n_quads, 4)
                Q_blocks = Q_quads.reshape(n_blocks, 128)
                T_blocks = W_unit_quads.reshape(n_blocks, 128)
                S_blocks = S_quads.reshape(n_blocks, 128)
                d_orig_t = torch.tensor(scales_orig, device=device, dtype=torch.float32)

                num = torch.sum((S_blocks**2) * T_blocks * Q_blocks, dim=1)
                den = torch.sum((S_blocks**2) * (Q_blocks**2), dim=1)
                d_lsq = d_orig_t * (num / torch.clamp(den, min=1e-8))
                scales_cal = d_lsq.detach().cpu().numpy().astype(np.float16)

            # Pack nibbles
            nibbles_np = best_idx.detach().cpu().numpy().astype(np.uint8)
            nibbles_per_block = nibbles_np.reshape(n_blocks, 32)
            packed_nibbles = (nibbles_per_block[:, 0::2] & 0x0F) | ((nibbles_per_block[:, 1::2] & 0x0F) << 4)

            scale_bytes = scales_cal.tobytes()
            scale_arr = np.frombuffer(scale_bytes, dtype=np.uint8).reshape(n_blocks, 2)

            block_data = np.concatenate([packed_nibbles, scale_arr], axis=1)
            packed_arr = block_data.reshape(out_f, blocks_per_row * 18)
            writer.add_tensor(name, packed_arr, raw_dtype=TYPE_SPTQ1_0)

            del W_unit_quads, S_quads, best_idx, Q_quads, Q_blocks, T_blocks, S_blocks, d_orig_t, num, den, d_lsq
            torch.cuda.empty_cache()

            pruned += 1
            if pruned % 25 == 0 or pruned == len(rps_layers) * 2:
                print(f"  [Pruned {pruned:3d}/{len(rps_layers)*2}] {name}")
        else:
            if tensor_type in (GGMLQuantizationType.F32, GGMLQuantizationType.F16):
                writer.add_tensor(name, t.data)
            else:
                writer.add_tensor(name, t.data, raw_dtype=tensor_type)
            dense += 1

    print("[*] Writing model to disk...")
    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()

    elapsed = time.time() - t0
    final_size_gb = os.path.getsize(output_path) / (1024**3)
    print(f"[✓] Model packed in {elapsed:.1f}s ({pruned} SPTQ1_0, {dense} Dense) -> Size: {final_size_gb:.2f} GB")
    return final_size_gb

def main():
    candidate_path = "/home/wsl-ops/models/frontier_qwen38/Qwen3.8-27B-SPTQ-RPS-LSQ.gguf"
    if not os.path.exists(candidate_path):
        pack_lsq_rps(candidate_path)
    else:
        print(f"Candidate already exists: {candidate_path} ({os.path.getsize(candidate_path)/(1024**3):.2f} GB)")

    print("\n[*] Measuring WikiText-2 PPL (4 chunks)...")
    cmd_ppl = [
        "docker", "exec", "-e", "CUDA_VISIBLE_DEVICES=1", "george-prism-server",
        "/workspace/build_prism/llama.cpp-prism/build/bin/llama-perplexity",
        "-m", "/models/frontier_qwen38/Qwen3.8-27B-SPTQ-RPS-LSQ.gguf",
        "-f", "/workspace/data/calibration/wiki.test.raw",
        "-c", "512", "-b", "2048", "-ngl", "99", "--chunks", "4"
    ]
    t0 = time.time()
    res = subprocess.run(cmd_ppl, capture_output=True, text=True)
    t_ppl = time.time() - t0
    m = re.search(r"Final estimate:\s+PPL\s+=\s+([0-9\.]+)\s+\+/-\s+([0-9\.]+)", res.stdout + res.stderr)
    if m:
        ppl = float(m.group(1))
        err = float(m.group(2))
        print(f"  ✓ RPS-LSQ PPL: {ppl:.4f} +/- {err:.4f} ({t_ppl:.1f}s)")
    else:
        print(f"  [!] Perplexity output:\n{(res.stdout + res.stderr)[-500:]}")

if __name__ == "__main__":
    main()
