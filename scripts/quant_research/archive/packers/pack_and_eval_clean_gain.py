#!/usr/bin/env python3
"""
Clean Unity-Gain Residual-Preserving Sparsity (RPS) Engine:
1. Zero Artificial Gain Inflation: scales_cal = scales_orig (preserves unity output gain in SwiGLU).
2. Pure Activation-Weighted Nearest-Neighbor: argmin sum(S_i^2 * (LUT_i - T_i)^2).
3. 100% DENSE PTQ1_0 on ffn_down across ALL 65 layers (zero residual stream corruption).
4. 100% DENSE PTQ1_0 on boundary layers (0..7 and 59..64).
5. Only ffn_gate and ffn_up in layers 8..58 (51 layers) pruned to SPTQ1_0.
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
        diff = lut_exp - w_chunk
        weighted_mse = torch.sum((diff * s_chunk)**2, dim=-1)
        best_idx[i:end] = torch.argmin(weighted_mse, dim=-1)

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

def pack_clean_gain(output_path):
    BASE_MODEL = "/home/wsl-ops/models/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf"
    IMATRIX_GGUF = "/home/wsl-ops/blue-lodge/data/calibration/production_imatrix.gguf"

    print("=" * 80)
    print("  Packing Clean Unity-Gain RPS Model")
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

            nibbles_np = best_idx.detach().cpu().numpy().astype(np.uint8)
            nibbles_per_block = nibbles_np.reshape(n_blocks, 32)
            packed_nibbles = (nibbles_per_block[:, 0::2] & 0x0F) | ((nibbles_per_block[:, 1::2] & 0x0F) << 4)

            # Unity gain: use scales_orig directly!
            scale_bytes = scales_orig.astype(np.float16).tobytes()
            scale_arr = np.frombuffer(scale_bytes, dtype=np.uint8).reshape(n_blocks, 2)

            block_data = np.concatenate([packed_nibbles, scale_arr], axis=1)
            packed_arr = block_data.reshape(out_f, blocks_per_row * 18)
            writer.add_tensor(name, packed_arr, raw_dtype=TYPE_SPTQ1_0)

            del W_unit_quads, S_quads, best_idx
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
    candidate_path = "/home/wsl-ops/models/frontier_qwen38/Qwen3.8-27B-SPTQ-RPS-UnityGain.gguf"
    container_path = "/models/frontier_qwen38/Qwen3.8-27B-SPTQ-RPS-UnityGain.gguf"
    if not os.path.exists(candidate_path):
        pack_clean_gain(candidate_path)
    else:
        print(f"Candidate already exists: {candidate_path} ({os.path.getsize(candidate_path)/(1024**3):.2f} GB)")

    print("\n[*] Measuring WikiText-2 PPL (4 chunks)...")
    cmd_ppl = [
        "docker", "exec", "-e", "CUDA_VISIBLE_DEVICES=1", "george-prism-server",
        "/workspace/build_prism/llama.cpp-prism/build/bin/llama-perplexity",
        "-m", container_path,
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
        print(f"  ✓ RPS Unity-Gain PPL: {ppl:.4f} +/- {err:.4f} ({t_ppl:.1f}s)")
        # Print chunk breakdown
        chunks = re.findall(r"\[([0-9]+)\]([0-9\.]+)", res.stdout + res.stderr)
        if chunks:
            print("  ✓ Per-chunk PPL: " + ", ".join([f"Chunk {c[0]}: {c[1]}" for c in chunks]))
    else:
        print(f"  [!] Perplexity output:\n{(res.stdout + res.stderr)[-500:]}")

if __name__ == "__main__":
    main()
