#!/usr/bin/env python3
"""
Fast Pack & Evaluation of 39-Layer Candidate (Layers 12..50)
Base: /home/wsl-ops/models/Ternary-Bonsai-2-27B-PTQ1_0.gguf
"""

import os
import sys
import time
import subprocess
import re
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

def pack_model(base_model, output_model, prune_layers, exp=0.5):
    print(f"\n[*] Packing model: {output_model}")
    print(f"[*] Prune layers: {min(prune_layers)}..{max(prune_layers)} ({len(prune_layers)} layers), exp={exp}")

    im_reader = gguf.GGUFReader('/home/wsl-ops/blue-lodge/data/calibration/production_imatrix.gguf')
    imatrix_map = {}
    for t in im_reader.tensors:
        if t.name.endswith('.in_sum2'):
            base_name = t.name.replace('.in_sum2', '')
            count_t = [x for x in im_reader.tensors if x.name == f'{base_name}.counts']
            counts = float(count_t[0].data[0]) if count_t else 1024.0
            sum2 = t.data.astype(np.float32)
            sigmas = np.sqrt(np.maximum(sum2 / counts, 1e-8))
            imatrix_map[base_name] = sigmas

    reader = gguf.GGUFReader(base_model)
    arch_field = reader.get_field('general.architecture')
    arch = bytes(arch_field.parts[arch_field.data[0]]).decode('utf-8') if arch_field else "qwen35"
    writer = gguf.GGUFWriter(output_model, arch)
    copy_gguf_metadata(reader, writer)

    target_names = ('ffn_gate.weight', 'ffn_up.weight')
    pruned = 0
    dense = 0
    t0 = time.time()

    for t in reader.tensors:
        name = t.name
        shape = list(t.shape)
        ttype = t.tensor_type

        should_prune = False
        if name.startswith('blk.') and ttype == TYPE_PTQ1_0:
            l_num = int(name.split('.')[1])
            if l_num in prune_layers and any(k in name for k in target_names):
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
            writer.add_tensor(name, packed_arr, raw_dtype=TYPE_SPTQ1_0)

            del W_unit_quads, S_quads, best_idx
            torch.cuda.empty_cache()
            pruned += 1
        else:
            if ttype in (GGMLQuantizationType.F32, GGMLQuantizationType.F16):
                writer.add_tensor(name, t.data)
            else:
                writer.add_tensor(name, t.data, raw_dtype=ttype)
            dense += 1

    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()
    elapsed = time.time() - t0
    f_size = os.path.getsize(output_model) / (1024**2)
    print(f"[✓] Model packed in {elapsed:.1f}s -> {f_size:.1f} MiB ({pruned} SPTQ1_0, {dense} Dense)")

def get_gpu1_vram():
    r = subprocess.run(['nvidia-smi', '--query-gpu=memory.used', '--format=csv,noheader,nounits', '-i', '1'], capture_output=True, text=True)
    return float(r.stdout.strip())

def eval_candidate(model_docker):
    print(f"\n[*] Evaluating WikiText-2 PPL on {model_docker}...")
    cmd_ppl = [
        "docker", "exec", "-e", "CUDA_VISIBLE_DEVICES=1", "george-prism-server",
        "/workspace/build_prism/llama.cpp-prism/build/bin/llama-perplexity",
        "-m", model_docker,
        "-f", "/workspace/data/calibration/wiki.test.raw",
        "-c", "512", "-b", "2048", "-ngl", "99", "--chunks", "4"
    ]
    t0 = time.time()
    res = subprocess.run(cmd_ppl, capture_output=True, text=True)
    output = res.stdout + res.stderr
    m = re.search(r"Final estimate:\s+PPL\s+=\s+([0-9\.]+)\s+\+/-\s+([0-9\.]+)", output)
    chunks = re.findall(r"\[([0-9]+)\]([0-9\.]+)", output)
    ppl_val = float(m.group(1)) if m else None
    ppl_err = float(m.group(2)) if m else None
    print(f"  ✓ PPL: {ppl_val} +/- {ppl_err} ({time.time()-t0:.1f}s)")
    print(f"  ✓ Chunks: {dict(chunks)}")

    print(f"\n[*] Evaluating VRAM & Speed on {model_docker}...")
    base_vram = get_gpu1_vram()
    proc = subprocess.Popen([
        "docker", "exec", "-e", "CUDA_VISIBLE_DEVICES=1", "george-prism-server",
        "/workspace/build_prism/llama.cpp-prism/build/bin/llama-cli",
        "-m", model_docker,
        "-ngl", "99", "-c", "512", "-n", "32",
        "-p", "Describe the mathematical importance of the constant Euler e.",
        "--single-turn"
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    peak_vram = base_vram
    while proc.poll() is None:
        c = get_gpu1_vram()
        if c > peak_vram:
            peak_vram = c
        time.sleep(0.05)

    out, err = proc.communicate()
    m_tg = re.search(r"Generation:\s+([0-9\.]+)\s+t/s", out + err)
    decode_spd = float(m_tg.group(1)) if m_tg else 0.0
    print(f"  ✓ Baseline VRAM: {base_vram:.1f} MiB")
    print(f"  ✓ Peak VRAM:     {peak_vram:.1f} MiB ({peak_vram/1024:.3f} GB)")
    print(f"  ✓ Model VRAM:    {peak_vram - base_vram:.1f} MiB")
    print(f"  ✓ Decode Speed:  {decode_spd:.1f} tok/s")

    return {
        "ppl": ppl_val,
        "ppl_err": ppl_err,
        "chunks": dict(chunks),
        "peak_vram_mb": peak_vram,
        "peak_vram_gb": peak_vram / 1024,
        "model_vram_mb": peak_vram - base_vram,
        "decode_tok_s": decode_spd
    }

if __name__ == '__main__':
    base = '/home/wsl-ops/models/Ternary-Bonsai-2-27B-PTQ1_0.gguf'
    out = '/home/wsl-ops/models/frontier_qwen38/Qwen3.8-27B-SPTQ-Final-Sub65.gguf'
    docker_model = '/models/frontier_qwen38/Qwen3.8-27B-SPTQ-Final-Sub65.gguf'

    # Prune 30 middle layers: layers 18 through 47
    # Preserving 34 Dense Anchor Layers: 0..17 and 48..63
    prune_layers = set(range(18, 48))
    pack_model(base, out, prune_layers, exp=0.5)

    torch.cuda.empty_cache()
    time.sleep(2)

    res = eval_candidate(docker_model)
    print("\n" + "=" * 80)
    print(f"RESULT: PPL={res['ppl']} | Peak VRAM={res['peak_vram_mb']:.1f} MiB ({res['peak_vram_gb']:.3f} GB) | Decode={res['decode_tok_s']} tok/s")
    print("=" * 80)
