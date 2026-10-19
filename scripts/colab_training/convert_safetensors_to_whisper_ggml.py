#!/usr/bin/env python3
"""
Convert a Hugging Face Whisper model.safetensors file directly into a whisper.cpp GGML .bin model
using the 586,235-byte header (magic + hparams + mel_80 filters + 50,257 BPE vocab) from ggml-small.en.bin.
"""

import json
import struct
import sys
from pathlib import Path
import numpy as np

CONV_MAP = {
    "self_attn.k_proj": "attn.key",
    "self_attn.q_proj": "attn.query",
    "self_attn.v_proj": "attn.value",
    "self_attn.out_proj": "attn.out",
    "self_attn_layer_norm": "attn_ln",
    "encoder_attn.q_proj": "cross_attn.query",
    "encoder_attn.v_proj": "cross_attn.value",
    "encoder_attn.out_proj": "cross_attn.out",
    "encoder_attn_layer_norm": "cross_attn_ln",
    "fc1": "mlp.0",
    "fc2": "mlp.2",
    "final_layer_norm": "mlp_ln",
    "encoder.layer_norm.bias": "encoder.ln_post.bias",
    "encoder.layer_norm.weight": "encoder.ln_post.weight",
    "encoder.embed_positions.weight": "encoder.positional_embedding",
    "decoder.layer_norm.bias": "decoder.ln.bias",
    "decoder.layer_norm.weight": "decoder.ln.weight",
    "decoder.embed_positions.weight": "decoder.positional_embedding",
    "decoder.embed_tokens.weight": "decoder.token_embedding.weight",
    "proj_out.weight": "decoder.proj.weight",
}


def map_tensor_name(src_name: str) -> str | None:
    if src_name in ("proj_out.weight", "model.proj_out.weight"):
        return None
    nn = src_name.split(".")
    if nn[0] == "model":
        nn = nn[1:]
    if len(nn) > 1 and nn[1] == "layers":
        nn[1] = "blocks"
        mid = ".".join(nn[3:-1])
        if mid == "encoder_attn.k_proj":
            mapped = "attn.key" if nn[0] == "encoder" else "cross_attn.key"
        else:
            mapped = CONV_MAP[mid]
        return ".".join(nn[:3] + [mapped] + nn[-1:])
    joined = ".".join(nn)
    return CONV_MAP.get(joined, joined)


def convert_safetensors_to_ggml(safetensors_path: Path, header_bin_path: Path, out_ggml_path: Path) -> None:
    header_bytes = header_bin_path.read_bytes()
    if len(header_bytes) != 586235:
        raise ValueError(f"Expected 586235-byte ggml-small.en header, got {len(header_bytes)} bytes")

    with safetensors_path.open("rb") as sf:
        hdr_len = struct.unpack("<Q", sf.read(8))[0]
        hdr = json.loads(sf.read(hdr_len).decode("utf-8"))
        data_base = 8 + hdr_len

        out_ggml_path.parent.mkdir(parents=True, exist_ok=True)
        with out_ggml_path.open("wb") as fout:
            fout.write(header_bytes)
            written = 0
            for src_name, meta in hdr.items():
                if src_name == "__metadata__":
                    continue
                ggml_name = map_tensor_name(src_name)
                if ggml_name is None:
                    continue

                dtype_str = meta["dtype"]
                shape = tuple(meta["shape"])
                start_off, end_off = meta["data_offsets"]
                sf.seek(data_base + start_off)
                raw = sf.read(end_off - start_off)

                if dtype_str == "F32":
                    arr = np.frombuffer(raw, dtype=np.float32).reshape(shape)
                elif dtype_str == "F16":
                    arr = np.frombuffer(raw, dtype=np.float16).reshape(shape)
                elif dtype_str == "BF16":
                    u16 = np.frombuffer(raw, dtype=np.uint16)
                    u32 = u16.astype(np.uint32) << 16
                    arr = u32.view(np.float32).reshape(shape)
                else:
                    raise ValueError(f"Unsupported dtype {dtype_str} for {src_name}")

                data = arr.squeeze().astype(np.float16)
                if ggml_name in ("encoder.conv1.bias", "encoder.conv2.bias"):
                    data = data.reshape(data.shape[0], 1)

                n_dims = len(data.shape)
                if (
                    n_dims < 2
                    or ggml_name == "encoder.conv1.bias"
                    or ggml_name == "encoder.conv2.bias"
                    or ggml_name == "encoder.positional_embedding"
                    or ggml_name == "decoder.positional_embedding"
                ):
                    data = data.astype(np.float32)
                    ftype = 0
                else:
                    ftype = 1

                name_bytes = ggml_name.encode("utf-8")
                fout.write(struct.pack("iii", n_dims, len(name_bytes), ftype))
                for i in range(n_dims):
                    fout.write(struct.pack("i", data.shape[n_dims - 1 - i]))
                fout.write(name_bytes)
                data.tofile(fout)
                written += 1

    sz_mb = out_ggml_path.stat().st_size / (1024 * 1024)
    print(f"[✓] Converted {written} tensors -> {out_ggml_path} ({sz_mb:.2f} MiB)")


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: convert_safetensors_to_whisper_ggml.py <model.safetensors> <ggml_header.bin> <out.bin>")
        sys.exit(1)
    convert_safetensors_to_ggml(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]))
