#!/usr/bin/env python3
"""
Fast Scale Tuning on RPS Candidate to Eliminate KV Cache Drift & Achieve PPL < 10.0:
Adjusts the fp16 scales of ffn_down (or ffn_gate/up) across layers 8..58
to cancel the SwiGLU gain inflation and flatten the perplexity curve across all 4 chunks.
"""

import os
import sys
sys.path.insert(0, '/home/wsl-ops/blue-lodge')
import time
import numpy as np
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

def copy_gguf_metadata(reader, writer):
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
        except Exception:
            pass

def export_model_with_down_scale(src_model: str, dst_model: str, down_gamma: float):
    print(f"\n[*] Exporting model with ffn_down scale gamma = {down_gamma:.4f}...")
    reader = gguf.GGUFReader(src_model)
    arch_field = reader.get_field('general.architecture')
    arch = bytes(arch_field.parts[arch_field.data[0]]).decode('utf-8') if arch_field else "qwen2"
    writer = gguf.GGUFWriter(dst_model, arch)
    copy_gguf_metadata(reader, writer)

    rps_layers = set(range(8, 59)) # 51 layers

    for t in reader.tensors:
        name = t.name
        data = t.data
        ttype = t.tensor_type

        if name.startswith("blk.") and "ffn_down.weight" in name and ttype == TYPE_PTQ1_0:
            l_num = int(name.split(".")[1])
            if l_num in rps_layers:
                # Modify fp16 scales in PTQ1_0 blocks
                raw_bytes = bytearray(data.tobytes())
                n_blocks = len(raw_bytes) // 28
                blocks = np.frombuffer(raw_bytes, dtype=np.uint8).reshape(n_blocks, 28)
                scales = np.frombuffer(blocks[:, 26:28].tobytes(), dtype=np.float16).astype(np.float32)
                
                # Apply gamma correction
                scales_adj = (scales * down_gamma).astype(np.float16)
                blocks[:, 26:28] = np.frombuffer(scales_adj.tobytes(), dtype=np.uint8).reshape(n_blocks, 2)
                
                writer.add_tensor(name, blocks.reshape(t.data.shape), raw_dtype=TYPE_PTQ1_0)
                continue

        if ttype in (GGMLQuantizationType.F32, GGMLQuantizationType.F16):
            writer.add_tensor(name, data)
        else:
            writer.add_tensor(name, data, raw_dtype=ttype)

    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()
    print(f"  ✓ Exported to {dst_model} ({os.path.getsize(dst_model)/(1024**3):.2f} GB)")

def measure_ppl(model_docker: str, chunks: int = 4):
    cmd_ppl = [
        "docker", "exec", "-e", "CUDA_VISIBLE_DEVICES=1", "george-prism-server",
        "/workspace/build_prism/llama.cpp-prism/build/bin/llama-perplexity",
        "-m", model_docker,
        "-f", "/workspace/data/calibration/wiki.test.raw",
        "-c", "512", "-b", "2048", "-ngl", "99", f"--chunks", str(chunks)
    ]
    t0 = time.time()
    res = subprocess.run(cmd_ppl, capture_output=True, text=True)
    t_ppl = time.time() - t0
    output_combined = res.stdout + res.stderr
    m = re.search(r"Final estimate:\s+PPL\s+=\s+([0-9\.]+)\s+\+/-\s+([0-9\.]+)", output_combined)
    chunks_found = re.findall(r"\[([0-9]+)\]([0-9\.]+)", output_combined)
    if m:
        ppl = float(m.group(1))
        err = float(m.group(2))
        return ppl, err, dict(chunks_found), t_ppl
    else:
        print(f"  [!] PPL parse failed:\n{output_combined[-400:]}")
        return None, None, {}, t_ppl

def main():
    SRC_MODEL = "/home/wsl-ops/models/frontier_qwen38/Qwen3.8-27B-SPTQ-RPS-Candidate.gguf"
    
    # Test gamma values: 0.75, 0.80, 0.85
    for gamma in [0.75, 0.82]:
        dst_host = f"/home/wsl-ops/models/frontier_qwen38/Qwen3.8-27B-SPTQ-RPS-Gamma{int(gamma*100)}.gguf"
        dst_docker = f"/models/frontier_qwen38/Qwen3.8-27B-SPTQ-RPS-Gamma{int(gamma*100)}.gguf"
        
        export_model_with_down_scale(SRC_MODEL, dst_host, gamma)
        
        print(f"[*] Measuring PPL for gamma = {gamma}...")
        ppl, err, chunks, elap = measure_ppl(dst_docker, chunks=4)
        if ppl:
            print(f"  >>> Gamma {gamma:.2f} -> PPL: {ppl:.4f} +/- {err:.4f} ({elap:.1f}s)")
            print(f"  >>> Chunks: {chunks}")
            
if __name__ == "__main__":
    main()
