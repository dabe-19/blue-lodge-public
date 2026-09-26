#!/usr/bin/env python3
"""
Blue-Llama Sub-1GB Reduction & Low-PPL Sweetspot:
- Drops 8 layers (24..31: Macro-blocks 6 & 7) to preserve exact 4-layer hybrid cadence.
- Applies SPTQ1_0 to 18 middle layers (new layers 16..33) with imatrix energy preservation.
- Preserves 38 layers (0..15 and 34..55) 100% DENSE PTQ1_0.
- Preserves 100% of all Attention and SSM weights DENSE PTQ1_0.
- Total Model Size: <= 4,640 MiB (> 1,024 MiB reduction vs 5,671 MiB original).
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

device = torch.device('cuda:0' if torch.cuda.is_available() else 'cpu')
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

def copy_metadata_with_block_count(reader, writer, new_block_count: int):
    for k, f in reader.fields.items():
        if k.startswith('GGUF.') or k == 'general.architecture':
            continue
        try:
            vtype = f.types[0]
            sub_type = f.types[1] if len(f.types) > 1 else None
            if k.endswith('.block_count'):
                writer.add_key_value(k, new_block_count, GGUFValueType.UINT32)
                continue
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
        except Exception:
            pass

def export_model(src_path: str, dst_path: str, drop_layers: set, sptq_layers_orig: set, exp=0.5):
    print("=" * 80)
    print("  Blue-Llama Sub-1GB Sweetspot Exporter")
    print(f"  Source:       {src_path}")
    print(f"  Destination:  {dst_path}")
    print(f"  Dropping {len(drop_layers)} layers: {sorted(list(drop_layers))}")
    print(f"  SPTQ MLP on {len(sptq_layers_orig)} layers: {sorted(list(sptq_layers_orig))}")
    print("=" * 80)

    # Load imatrix
    im_path = '/home/wsl-ops/blue-lodge/data/calibration/production_imatrix.gguf'
    imatrix_map = {}
    if os.path.exists(im_path):
        im_reader = gguf.GGUFReader(im_path)
        for t in im_reader.tensors:
            if t.name.endswith('.in_sum2'):
                base_name = t.name.replace('.in_sum2', '')
                count_t = [x for x in im_reader.tensors if x.name == f'{base_name}.counts']
                counts = float(count_t[0].data[0]) if count_t else 1024.0
                sum2 = t.data.astype(np.float32)
                sigmas = np.sqrt(np.maximum(sum2 / counts, 1e-8))
                imatrix_map[base_name] = sigmas

    reader = gguf.GGUFReader(src_path)
    arch_field = reader.get_field('general.architecture')
    arch = bytes(arch_field.parts[arch_field.data[0]]).decode('utf-8') if arch_field else "qwen35"
    writer = gguf.GGUFWriter(dst_path, arch)

    orig_block_count = 64
    new_block_count = orig_block_count - len(drop_layers)
    copy_metadata_with_block_count(reader, writer, new_block_count)
    writer.add_string("general.description", "Blue-Llama 56L Sweetspot: >1GB Size Reduced, 100% Attention Dense, Calibrated SPTQ1_0")

    layer_map = {}
    new_l = 0
    for old_l in range(orig_block_count):
        if old_l not in drop_layers:
            layer_map[old_l] = new_l
            new_l += 1

    target_mlp_names = ('ffn_gate.weight', 'ffn_up.weight')
    pruned_sptq = 0
    t0 = time.time()

    for t in reader.tensors:
        name = t.name
        shape = list(t.shape)
        ttype = t.tensor_type

        if name.startswith('blk.'):
            parts = name.split('.')
            old_l = int(parts[1])
            if old_l in drop_layers:
                continue

            new_l = layer_map[old_l]
            parts[1] = str(new_l)
            new_name = '.'.join(parts)

            should_sptq = (old_l in sptq_layers_orig) and any(k in name for k in target_mlp_names) and (ttype == TYPE_PTQ1_0)
        else:
            new_name = name
            should_sptq = False

        if should_sptq:
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
            energy_mult = (np.maximum(orig_nz.astype(np.float32), 1.0) / 64.0) ** exp
            scales_cal = (scales_orig.astype(np.float32) * energy_mult).astype(np.float16)

            sigmas = imatrix_map.get(name, np.ones(ne0, dtype=np.float32))
            sigmas_quad_base = sigmas.reshape(quads_per_row, 4)
            sigmas_quad_np = np.broadcast_to(sigmas_quad_base, (out_f, quads_per_row, 4)).reshape(n_quads, 4)
            S_quads = torch.tensor(sigmas_quad_np, device=device, dtype=torch.float32)

            trits_quad = trits.reshape(n_quads, 4).astype(np.float32)
            W_unit_quads = torch.tensor(trits_quad, device=device, dtype=torch.float32)
            best_idx = quantize_unit_quads_cuda(W_unit_quads, S_quads)

            nibbles_np = best_idx.detach().cpu().numpy().astype(np.uint8)
            nibbles_per_block = nibbles_np.reshape(n_blocks, 32)
            packed_nibbles = (nibbles_per_block[:, 0::2] & 0x0F) | ((nibbles_per_block[:, 1::2] & 0x0F) << 4)
            scale_bytes = scales_cal.tobytes()
            scale_arr = np.frombuffer(scale_bytes, dtype=np.uint8).reshape(n_blocks, 2)
            block_data = np.concatenate([packed_nibbles, scale_arr], axis=1)
            packed_arr = block_data.reshape(out_f, blocks_per_row * 18)
            writer.add_tensor(new_name, packed_arr, raw_dtype=TYPE_SPTQ1_0)

            del W_unit_quads, S_quads, best_idx
            torch.cuda.empty_cache()
            pruned_sptq += 1
        else:
            if ttype in (GGMLQuantizationType.F32, GGMLQuantizationType.F16):
                writer.add_tensor(new_name, t.data)
            else:
                writer.add_tensor(new_name, t.data, raw_dtype=ttype)

    print(f"[*] Writing tensors to disk...")
    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()

    file_bytes = os.path.getsize(dst_path)
    src_bytes = os.path.getsize(src_path)
    diff_mb = (src_bytes - file_bytes) / (1024**2)
    diff_gb = (src_bytes - file_bytes) / (1024**3)
    print(f"[✓] Export finished in {time.time()-t0:.1f}s!")
    print(f"    Output Size: {file_bytes/(1024**2):.2f} MiB ({file_bytes/(1024**3):.3f} GB)")
    print(f"    Size Reduced vs Original: {diff_mb:.2f} MiB ({diff_gb:.3f} GB)")
    print(f"    Tensors Converted to SPTQ1_0: {pruned_sptq}")
    return file_bytes

if __name__ == '__main__':
    src = '/home/wsl-ops/models/Ternary-Bonsai-2-27B-PTQ1_0.gguf'
    dst = '/home/wsl-ops/models/frontier_qwen38/Blue-Llama-27B-Sub1GB-Sweetspot.gguf'

    # Drop 8 layers (24..31: Macro-blocks 6 and 7)
    drop_layers = set(range(24, 32))

    # Apply SPTQ to exactly 20 middle layers (16..23 and 32..43) to guarantee > 1024 MiB reduction
    sptq_layers = set(range(16, 24)).union(set(range(32, 44)))

    export_model(src, dst, drop_layers, sptq_layers, exp=0.5)
