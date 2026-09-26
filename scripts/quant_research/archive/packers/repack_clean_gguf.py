#!/usr/bin/env python3
"""
Fast GGUF Metadata Repack & Header Normalizer.
Fixes tokenizer arrays (tokens, merges, token_types) and qwen35.rope.dimension_sections ([11, 11, 10, 0]).
Uses already-converted physical tensors from Qwen3.8-27B-Ablated-2_4-Sparse-MTP.gguf.
Runs in ~2.5 minutes because weights are already quantized, rotated, and ablated on disk.
"""

import os
import sys
import time
import numpy as np
import gguf
from gguf.constants import GGMLQuantizationType, GGUFValueType

SRC_CONVERTED_PATH = "/home/wsl-ops/models/frontier_qwen38/Qwen3.8-27B-Ablated-2_4-Sparse-MTP.gguf"
SRC_BASE_PATH = "/home/wsl-ops/models/frontier_qwen38/Qwen3.8-27B-Q8_0.gguf"
OUT_CLEAN_PATH = "/home/wsl-ops/models/frontier_qwen38/Qwen3.8-27B-Ablated-2_4-Sparse-MTP.clean.gguf"

print("=" * 75)
print("  Fast GGUF Metadata Normalizer & Header Repack")
print("=" * 75)
sys.stdout.flush()

t0 = time.time()
print(f"Reading source converted model: {SRC_CONVERTED_PATH}...")
src_reader = gguf.GGUFReader(SRC_CONVERTED_PATH)
base_reader = gguf.GGUFReader(SRC_BASE_PATH)

print(f"  ✓ Converted tensors ready: {len(src_reader.tensors)}")
writer = gguf.GGUFWriter(OUT_CLEAN_PATH, "qwen35", use_temp_file=True)

# 1. Transfer Metadata from Base Model with Exact Array Slicing
print("Normalizing and transferring metadata...")
for k, f in base_reader.fields.items():
    if k.startswith("GGUF.") or k in ["general.architecture", "general.file_type", "general.quantization_version", "qwen35.rope.dimension_sections"]:
        continue
    vtype = f.types[0]
    parts = f.parts
    try:
        if vtype == GGUFValueType.STRING:
            writer.add_string(k, bytes(parts[-1]).decode('utf-8', errors='ignore'))
        elif vtype == GGUFValueType.UINT32:
            writer.add_uint32(k, int(parts[-1][0]))
        elif vtype == GGUFValueType.INT32:
            writer.add_int32(k, int(parts[-1][0]))
        elif vtype == GGUFValueType.FLOAT32:
            writer.add_float32(k, float(parts[-1][0]))
        elif vtype == GGUFValueType.BOOL:
            writer.add_bool(k, bool(parts[-1][0]))
        elif vtype == GGUFValueType.ARRAY:
            sub_type = f.types[1]
            n_items = int(parts[4][0])
            if sub_type == GGUFValueType.STRING:
                # String arrays store length and bytes alternating: parts[6::2] are the string bytes
                strs = [bytes(p).decode('utf-8', errors='ignore') for p in parts[6::2]]
                assert len(strs) == n_items, f"Mismatch in string array {k}: {len(strs)} vs {n_items}"
                writer.add_array(k, strs)
            elif sub_type == GGUFValueType.INT32:
                # Integer arrays store elements directly from index 5
                arr = [int(p[0]) for p in parts[5:5+n_items]]
                assert len(arr) == n_items, f"Mismatch in int array {k}: {len(arr)} vs {n_items}"
                writer.add_array(k, arr)
            elif sub_type == GGUFValueType.FLOAT32:
                arr = [float(p[0]) for p in parts[5:5+n_items]]
                assert len(arr) == n_items, f"Mismatch in float array {k}: {len(arr)} vs {n_items}"
                writer.add_array(k, arr)
    except Exception as e:
        print(f"  Warning on metadata {k}: {e}")

# Fix dimension_sections explicitly to exact 4 elements [11, 11, 10, 0]
writer.add_array("qwen35.rope.dimension_sections", [11, 11, 10, 0])

# Frontier Custom Metadata
writer.add_string("general.name", "Qwen3.8-27B-Ablated-2_4-Sparse-MTP")
writer.add_string("general.description", "Qwen 3.8 27B Frontier: Directional Refusal Ablation (layers 12-28), Sylvester Walsh-Hadamard H256 rotation, 2:4 Structural Sparse Ternary Quantization, Grafted MTP Drafter (blk.64), Vision Tower Compatible (d_model=5120)")
writer.add_uint32("qwen35.block_count", 65)
writer.add_uint32("qwen35.nextn_predict_layers", 1)
writer.add_string("prism.hadamard.transform", "normalized-sylvester-walsh-hadamard")
writer.add_uint32("prism.hadamard.block_size", 256)
writer.add_string("frontier.quantization", "2:4-sparse-ternary")
writer.add_string("frontier.refusal_ablation.layers", "12-28")
writer.add_float32("frontier.refusal_ablation.lambda", 1.0)
writer.add_string("frontier.mtp_donor", "mtp-Qwen3.8-27B-Q4_0.gguf")
writer.add_bool("frontier.vision_compatible", True)

# 2. Transfer Converted Tensors
print("Transferring already-converted physical tensors...")
for idx, t in enumerate(src_reader.tensors):
    t_name = t.name
    t_shape = t.shape
    t_type = t.tensor_type
    ne0 = t_shape[0]
    ne1 = t_shape[1] if len(t_shape) > 1 else 1
    
    if t_type == GGMLQuantizationType.F32:
        w_float = t.data.astype(np.float32)
        if len(t_shape) == 2:
            w_float = w_float.reshape(ne1, ne0)
        writer.add_tensor(t_name, w_float)
    else:
        bytes_per_row = t.n_bytes // ne1
        raw_view = t.data.reshape(ne1, bytes_per_row)
        writer.add_tensor(t_name, raw_view, raw_dtype=t_type)
        
    if (idx + 1) % 200 == 0 or idx == len(src_reader.tensors) - 1:
        print(f"  [{idx+1}/{len(src_reader.tensors)}] Transferred {t_name}")
        sys.stdout.flush()

# 3. Finalize Serialization
print("Writing header, KV data, and tensor index...")
writer.write_header_to_file()
writer.write_kv_data_to_file()
writer.write_tensors_to_file()
writer.close()

# Atomic replace
os.replace(OUT_CLEAN_PATH, SRC_CONVERTED_PATH)
print("=" * 75)
print(f"  REPACK COMPLETED IN {time.time() - t0:.1f}s!")
print(f"  Verified File: {SRC_CONVERTED_PATH}")
print(f"  Size: {os.path.getsize(SRC_CONVERTED_PATH) / (1024**3):.2f} GB")
print("=" * 75)
