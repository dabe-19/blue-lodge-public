#!/usr/bin/env python3
"""
graft_internal_mtp.py:
Grafts the native single-layer recurrent MTP draft head (blk.64 from Bonsai-2-27B-PTQ1_0-mtp-lean)
directly into Blue-Llama-27B-Champion-v5 as blk.52, enabling llama.cpp internal speculative
decoding (--spec-type draft-mtp --spec-draft-n-max 1) without requiring any external draft model file.
"""

import os
import sys
import time
import numpy as np
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

def main():
    champ_path = "/home/wsl-ops/models/frontier_qwen38/Blue-Llama-27B-Champion-v5.gguf"
    bonsai_path = "/home/wsl-ops/models/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf"
    output_path = "/home/wsl-ops/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Internal-MTP.gguf"

    print("=" * 80)
    print("  Blue-Llama Native Internal MTP Grafting Engine")
    print(f"  Base Model:       {champ_path}")
    print(f"  Donor MTP Model:  {bonsai_path}")
    print(f"  Output Model:     {output_path}")
    print("=" * 80)

    if not os.path.exists(champ_path):
        print(f"[!] Base model not found: {champ_path}")
        sys.exit(1)
    if not os.path.exists(bonsai_path):
        print(f"[!] Donor model not found: {bonsai_path}")
        sys.exit(1)

    t0 = time.time()
    print("[*] Reading Base Model Header & Metadata...")
    r_champ = gguf.GGUFReader(champ_path)
    arch_field = r_champ.get_field("general.architecture")
    arch = bytes(arch_field.parts[arch_field.data[0]]).decode("utf-8") if arch_field else "qwen35"

    print(f"[*] Base Architecture: {arch}")
    writer = gguf.GGUFWriter(output_path, arch)

    # Copy and update metadata
    print("[*] Updating Metadata for Internal MTP (nextn_predict_layers = 1, block_count = 53)...")
    for k, f in r_champ.fields.items():
        if k.startswith('GGUF.') or k == 'general.architecture':
            continue
        try:
            vtype = f.types[0]
            sub_type = f.types[1] if len(f.types) > 1 else None

            if k.endswith('.block_count'):
                writer.add_key_value(k, 53, GGUFValueType.UINT32)
                continue
            if k == 'general.version':
                writer.add_string("general.version", "v5-internal-mtp")
                continue
            if k == 'general.description':
                writer.add_string("general.description", "Blue-Llama Champion v5 with Native Internal MTP (52 Base + 1 MTP Draft)")
                continue

            if k.endswith('.attention.recurrent_layers'):
                # Append 0 for blk.52 (MTP attention layer)
                vals = [f.parts[idx].item() if hasattr(f.parts[idx], 'item') else f.parts[idx] for idx in f.data]
                vals.append(0)
                writer.add_key_value(k, vals, vtype, sub_type=sub_type)
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
        except Exception as e:
            print(f"  [!] Skipped field {k}: {e}")

    # Add MTP specific metadata
    writer.add_uint32(f"{arch}.nextn_predict_layers", 1)
    writer.add_string("graft.donor.name", os.path.basename(bonsai_path))
    writer.add_uint32("graft.head_blocks", 52)
    writer.add_uint32("graft.head_tensor_count", 15)

    # Process Base Model Tensors
    print(f"[*] Registering {len(r_champ.tensors)} Base Model Tensors...")
    for idx, t in enumerate(r_champ.tensors):
        ttype = t.tensor_type
        if ttype in (GGMLQuantizationType.F32, GGMLQuantizationType.F16):
            writer.add_tensor(t.name, t.data)
        else:
            writer.add_tensor(t.name, t.data, raw_dtype=ttype)
        if (idx + 1) % 150 == 0:
            print(f"    - Registered {idx + 1}/{len(r_champ.tensors)} base tensors...")

    # Read Donor Model and Extract blk.64 tensors
    print("[*] Extracting 15 MTP Tensors from Donor Model...")
    r_bonsai = gguf.GGUFReader(bonsai_path)
    mtp_tensors = [t for t in r_bonsai.tensors if t.name.startswith("blk.64.")]
    print(f"    - Found {len(mtp_tensors)} donor MTP tensors in blk.64:")

    for t in mtp_tensors:
        new_name = t.name.replace("blk.64.", "blk.52.")
        ttype = t.tensor_type
        print(f"      + Grafting: {t.name} -> {new_name} ({t.n_bytes / 1024 / 1024:.2f} MiB, type={ttype})")
        if ttype in (GGMLQuantizationType.F32, GGMLQuantizationType.F16):
            writer.add_tensor(new_name, t.data)
        else:
            writer.add_tensor(new_name, t.data, raw_dtype=ttype)

    print(f"[*] Total Tensors in Grafted Model: {len(writer.tensors)}")
    print(f"[*] Serializing GGUF Binary to {output_path}...")
    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()

    elapsed = time.time() - t0
    size_gb = os.path.getsize(output_path) / (1024**3)
    print("=" * 80)
    print(f"[✓] Successfully Built Native Internal MTP Model in {elapsed:.1f}s!")
    print(f"    Path: {output_path}")
    print(f"    Size: {size_gb:.2f} GiB")
    print("=" * 80)

if __name__ == '__main__':
    main()
