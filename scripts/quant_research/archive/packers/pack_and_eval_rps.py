#!/usr/bin/env python3
"""
Residual-Preserving Sparsity (RPS) Engine for Qwen 3.8 27B:
1. Keeps `ffn_down` 100% DENSE (PTQ1_0) across ALL 64 layers to preserve the residual stream.
2. Keeps boundary layers (0..7 and 59..63) 100% DENSE (PTQ1_0) for embedding & logit stability.
3. Applies Direct 16-State Codebook Search & Variance-Preserving Energy Scaling to `ffn_gate` and `ffn_up` in layers 8..58 (51 layers).
4. Model size targets ~5.14 GB, achieving Dedicated VRAM ~5.0 GB and Peak Total GPU 1 VRAM <= 6.46 GB.
"""

import os
import sys
import time
import numpy as np
import torch
import gguf
from gguf.constants import GGMLQuantizationType, GGML_QUANT_SIZES, GGUFValueType

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
print(f"[*] Initialized Hardware Context on {device} ({torch.cuda.get_device_name(device)})")

# 1. Base-3 Lookup Table for PTQ1_0 Unpacking
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
    trits = np.concatenate([t0, t1, t2], axis=1) # (n_blocks, 128)
    return trits, scales

# 2. Hardware LUT on CUDA
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
    print(f"  ✓ Copied {copied} metadata fields.")

def main():
    BASE_MODEL = "/home/wsl-ops/models/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf"
    OUTPUT_MODEL = "/home/wsl-ops/models/frontier_qwen38/Qwen3.8-27B-SPTQ-RPS-Candidate.gguf"
    IMATRIX_GGUF = "/home/wsl-ops/blue-lodge/data/calibration/production_imatrix.gguf"

    print("=" * 80)
    print("  Residual-Preserving Sparsity (RPS) Packer")
    print(f"  Base Model:   {BASE_MODEL}")
    print(f"  Output Model: {OUTPUT_MODEL}")
    print("=" * 80)

    # 1. Load imatrix
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
    print(f"  ✓ Loaded ground-truth activation variances for {len(imatrix_map)} tensors.")

    # 2. Setup GGUF Reader and Writer
    reader = gguf.GGUFReader(BASE_MODEL)
    arch_field = reader.get_field('general.architecture')
    arch = bytes(arch_field.parts[arch_field.data[0]]).decode('utf-8') if arch_field else "qwen2"
    writer = gguf.GGUFWriter(OUTPUT_MODEL, arch)
    copy_gguf_metadata(reader, writer)

    # Target layers for RPS: layers 8..58 (51 layers)
    # ONLY ffn_gate and ffn_up! ffn_down is 100% DENSE PTQ1_0!
    rps_layers = set(range(8, 59))
    target_names = ('ffn_gate.weight', 'ffn_up.weight')

    t0 = time.time()
    pruned_count = 0
    dense_count = 0

    print(f"[*] Processing {len(reader.tensors)} tensors with Residual-Preserving Sparsity...")
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
            orig_nz = np.sum(trits != 0, axis=1)
            energy_mult = np.sqrt(np.maximum(orig_nz.astype(np.float32), 1.0) / 64.0)
            scales_cal = (scales_orig.astype(np.float32) * energy_mult).astype(np.float16)

            sigmas = imatrix_map.get(name, np.ones(ne0, dtype=np.float32))
            sigmas_quad_base = sigmas.reshape(quads_per_row, 4)
            sigmas_quad_np = np.broadcast_to(sigmas_quad_base, (out_f, quads_per_row, 4)).reshape(n_quads, 4)
            S_quads = torch.tensor(sigmas_quad_np, device=device, dtype=torch.float32)

            trits_quad = trits.reshape(n_quads, 4).astype(np.float32)
            W_unit_quads = torch.tensor(trits_quad, device=device, dtype=torch.float32)

            best_idx = quantize_unit_quads_cuda(W_unit_quads, S_quads)

            # Pack
            nibbles_np = best_idx.detach().cpu().numpy().astype(np.uint8)
            nibbles_per_block = nibbles_np.reshape(n_blocks, 32)
            packed_nibbles = (nibbles_per_block[:, 0::2] & 0x0F) | ((nibbles_per_block[:, 1::2] & 0x0F) << 4)

            scale_bytes = scales_cal.tobytes()
            scale_arr = np.frombuffer(scale_bytes, dtype=np.uint8).reshape(n_blocks, 2)

            block_data = np.concatenate([packed_nibbles, scale_arr], axis=1)
            packed_arr = block_data.reshape(out_f, blocks_per_row * 18)
            writer.add_tensor(name, packed_arr, raw_dtype=TYPE_SPTQ1_0)

            del W_unit_quads, S_quads, best_idx
            torch.cuda.empty_cache()

            pruned_count += 1
            if pruned_count % 20 == 0 or pruned_count == len(rps_layers) * 2:
                print(f"  [Pruned {pruned_count:3d}/{len(rps_layers)*2}] {name}")
        else:
            if tensor_type in (GGMLQuantizationType.F32, GGMLQuantizationType.F16):
                writer.add_tensor(name, t.data)
            else:
                writer.add_tensor(name, t.data, raw_dtype=tensor_type)
            dense_count += 1

    print(f"\n[*] Writing model to disk...")
    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()

    elapsed = time.time() - t0
    final_size_gb = os.path.getsize(OUTPUT_MODEL) / (1024**3)
    print(f"[✓] Model packed in {elapsed:.1f}s!")
    print(f"  Total Tensors: {pruned_count + dense_count} ({pruned_count} SPTQ1_0, {dense_count} Dense)")
    print(f"  Output Model Size: {final_size_gb:.2f} GB ({os.path.getsize(OUTPUT_MODEL):,} bytes)")

if __name__ == "__main__":
    main()
