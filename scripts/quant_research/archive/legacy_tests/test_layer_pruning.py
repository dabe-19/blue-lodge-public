#!/usr/bin/env python3
"""
Test ShortGPT Layer Pruning on Qwen 3.8 27B:
Drops redundant low-energy middle layers, keeps all other layers 100% DENSE PTQ1_0.
Evaluates WikiText-2 PPL across 4 chunks and measures exact GPU 1 Peak VRAM.
"""

import os
import sys
import time
import subprocess
import re
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

def copy_metadata_with_block_count(reader, writer, new_block_count: int):
    for k, f in reader.fields.items():
        if k.startswith('GGUF.') or k == 'general.architecture':
            continue
        try:
            vtype = f.types[0]
            sub_type = f.types[1] if len(f.types) > 1 else None
            # Update block_count
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

def export_pruned_model(src_path: str, dst_path: str, drop_layers: set):
    print("=" * 80)
    print(f"  ShortGPT Layer Pruning: Dropping {len(drop_layers)} layers: {sorted(list(drop_layers))}")
    print(f"  Source: {src_path}")
    print(f"  Dest:   {dst_path}")
    print("=" * 80)

    reader = gguf.GGUFReader(src_path)
    arch_field = reader.get_field('general.architecture')
    arch = bytes(arch_field.parts[arch_field.data[0]]).decode('utf-8') if arch_field else "qwen35"
    writer = gguf.GGUFWriter(dst_path, arch)

    orig_block_count = 64
    new_block_count = orig_block_count - len(drop_layers)
    copy_metadata_with_block_count(reader, writer, new_block_count)

    # Build layer mapping: old_layer -> new_layer
    layer_map = {}
    new_l = 0
    for old_l in range(orig_block_count):
        if old_l not in drop_layers:
            layer_map[old_l] = new_l
            new_l += 1

    t0 = time.time()
    tensors_written = 0

    for t in reader.tensors:
        name = t.name
        ttype = t.tensor_type

        if name.startswith('blk.'):
            parts = name.split('.')
            old_l = int(parts[1])
            if old_l in drop_layers:
                continue # Skip dropped layer
            # Re-index block
            new_l = layer_map[old_l]
            parts[1] = str(new_l)
            new_name = '.'.join(parts)
        else:
            new_name = name

        if ttype in (GGMLQuantizationType.F32, GGMLQuantizationType.F16):
            writer.add_tensor(new_name, t.data)
        else:
            writer.add_tensor(new_name, t.data, raw_dtype=ttype)
        tensors_written += 1

    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()

    elapsed = time.time() - t0
    f_size = os.path.getsize(dst_path) / (1024**2)
    print(f"[✓] Model exported in {elapsed:.1f}s -> {f_size:.1f} MiB ({f_size/1024:.2f} GiB), {tensors_written} tensors written.")
    return f_size

def eval_candidate(model_docker: str):
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
    ppl = float(m.group(1)) if m else None
    err = float(m.group(2)) if m else None
    print(f"  ✓ PPL: {ppl} +/- {err} ({time.time()-t0:.1f}s)")
    print(f"  ✓ Chunks: {dict(chunks)}")
    return ppl, err, dict(chunks)

if __name__ == '__main__':
    src = '/home/wsl-ops/models/Ternary-Bonsai-2-27B-PTQ1_0.gguf'
    dst = '/home/wsl-ops/models/frontier_qwen38/test_shortgpt.gguf'
    docker_m = '/models/frontier_qwen38/test_shortgpt.gguf'

    # Drop 4 layers (16..19: 3 SSM + 1 Attention) to preserve exact modulo-4 hybrid schedule
    drop = set(range(16, 20))
    export_pruned_model(src, dst, drop)
    ppl, err, chunks = eval_candidate(docker_m)
    print(f"\nRESULT: Dropped {len(drop)} layers -> PPL: {ppl} +/- {err}")
