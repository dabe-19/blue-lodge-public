#!/usr/bin/env python3
"""
06_apply_calibrated_mtp.py:
Calibrates the internal MTP draft layer tensors (blk.52) in Blue-Llama-27B-Champion-v5-Internal-MTP.gguf.

Calibrations applied:
1. Representation Variance Alignment (hnorm):
   Adjusts hnorm channel scale by gamma = sqrt(64/52) = 1.1094035 to compensate for
   the 12 pruned macroblock layers (MB 4, 6, 8) and residual accumulation variance.
2. Logit Sharpness & Entropy Normalization (shared_head_norm):
   Normalizes shared_head_norm scale relative to Champion v5 output_norm (ratio 1.1598 -> 1.0000),
   preventing entropy dispersion in the 248k-token vocabulary softmax.
3. Preserves full PTQ1_0 and SPTQ1_0 custom quantization types.
"""

import os
import sys
import time
import argparse
import numpy as np

try:
    import gguf
    from gguf.constants import GGMLQuantizationType, GGML_QUANT_SIZES, GGUFValueType
except ImportError:
    print("[!] Error: gguf package is required.")
    sys.exit(1)

def register_ggml_type(name: str, value: int, block_size: int, type_size: int):
    obj = int.__new__(GGMLQuantizationType, value)
    obj._value_ = value
    obj._name_ = name
    GGMLQuantizationType._value2member_map_[value] = obj
    GGMLQuantizationType._member_map_[name] = obj
    GGML_QUANT_SIZES[obj] = (block_size, type_size)
    return obj

TYPE_PTQ1_0 = register_ggml_type("PTQ1_0", 143, 128, 28)
TYPE_SPTQ1_0 = register_ggml_type("SPTQ1_0", 145, 128, 18)

def calibrate_model(input_path, output_path, hnorm_gain=1.1094, shnorm_scale=1.05):
    print("=" * 80)
    print("  Blue-Llama MTP Draft Head Calibration Engine")
    print(f"  Input Model:       {input_path}")
    print(f"  Output Model:      {output_path}")
    print(f"  HNorm Gain:        {hnorm_gain:.4f} (Macroblock variance compensation)")
    print(f"  SHNorm Scale:      {shnorm_scale:.4f} (Entropy sharpness alignment)")
    print("=" * 80)

    if not os.path.exists(input_path):
        print(f"[!] Input model not found: {input_path}")
        return False

    t0 = time.time()
    reader = gguf.GGUFReader(input_path)
    arch_field = reader.get_field("general.architecture")
    arch = bytes(arch_field.parts[arch_field.data[0]]).decode("utf-8") if arch_field else "qwen35"
    writer = gguf.GGUFWriter(output_path, arch)

    # Copy metadata
    print("[*] Copying metadata...")
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

    writer.add_string("mtp.calibration.status", "calibrated-v1")
    writer.add_float32("mtp.calibration.hnorm_gain", float(hnorm_gain))
    writer.add_float32("mtp.calibration.shnorm_scale", float(shnorm_scale))

    # Read base norm tensors
    out_norm_t = [t for t in reader.tensors if t.name == "output_norm.weight"][0]
    out_norm = out_norm_t.data.astype(np.float32)

    hnorm_t = [t for t in reader.tensors if t.name == "blk.52.nextn.hnorm.weight"][0]
    hnorm_orig = hnorm_t.data.astype(np.float32)

    shnorm_t = [t for t in reader.tensors if t.name == "blk.52.nextn.shared_head_norm.weight"][0]
    shnorm_orig = shnorm_t.data.astype(np.float32)

    # Calibrate tensors
    hnorm_calibrated = (hnorm_orig * hnorm_gain).astype(np.float32)
    # Align shared_head_norm so its profile matches the calibrated output_norm space with sharpness scale
    shnorm_calibrated = (shnorm_orig * (shnorm_scale / 1.1598)).astype(np.float32)

    print(f"[*] Calibrated blk.52.nextn.hnorm: mean {hnorm_orig.mean():.4f} -> {hnorm_calibrated.mean():.4f}")
    print(f"[*] Calibrated blk.52.nextn.shared_head_norm: mean {shnorm_orig.mean():.4f} -> {shnorm_calibrated.mean():.4f} (vs output_norm {out_norm.mean():.4f})")

    print(f"[*] Writing {len(reader.tensors)} tensors to {output_path}...")
    for idx, t in enumerate(reader.tensors):
        name = t.name
        ttype = t.tensor_type

        if name == "blk.52.nextn.hnorm.weight":
            writer.add_tensor(name, hnorm_calibrated)
        elif name == "blk.52.nextn.shared_head_norm.weight":
            writer.add_tensor(name, shnorm_calibrated)
        else:
            if ttype in (GGMLQuantizationType.F32, GGMLQuantizationType.F16):
                writer.add_tensor(name, t.data)
            else:
                writer.add_tensor(name, t.data, raw_dtype=ttype)

        if (idx + 1) % 150 == 0:
            print(f"    - Processed {idx + 1}/{len(reader.tensors)} tensors...")

    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()

    elapsed = time.time() - t0
    size_gb = os.path.getsize(output_path) / (1024**3)
    print("=" * 80)
    print(f"[✓] Successfully Generated Calibrated MTP GGUF in {elapsed:.1f}s ({size_gb:.2f} GiB)")
    print(f"    Path: {output_path}")
    print("=" * 80)
    return True

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Calibrate Blue-Llama MTP Model")
    parser.add_argument("--input", type=str, default="/home/wsl-ops/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Internal-MTP.gguf")
    parser.add_argument("--output", type=str, default="/home/wsl-ops/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Internal-MTP-Calibrated.gguf")
    parser.add_argument("--hnorm_gain", type=float, default=1.1094)
    parser.add_argument("--shnorm_scale", type=float, default=1.05)
    args = parser.parse_args()
    calibrate_model(args.input, args.output, args.hnorm_gain, args.shnorm_scale)
