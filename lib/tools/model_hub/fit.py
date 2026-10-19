"""Deterministic memory-fit calculator for llama.cpp deployments.

need = weights + KV(ctx) + mmproj + draft + per-GPU (compute buffer + backend overhead)
KV/token = attn_layers * n_head_kv * (hd_k*b_k + hd_v*b_v)

Estimates are conservative upper bounds (sliding-window layers are counted as full attention
unless the GGUF exposes the pattern). Every result carries the inputs and assumptions used.
"""

from __future__ import annotations

import math
from typing import Any

MiB = 1 << 20
KV_BYTES = {"f32": 4.0, "f16": 2.0, "bf16": 2.0, "q8_0": 34 / 32, "q5_1": 24 / 32, "q5_0": 22 / 32,
            "q4_1": 20 / 32, "q4_0": 18 / 32, "iq4_nl": 18 / 32}
GPU_OVERHEAD_MB = {"cuda": 350, "rocm": 450, "metal": 0, "vulkan": 400, "cpu": 0}
RESERVE_MB = 256


def kv_bytes_per_token(d: dict[str, Any], kv_k: str = "f16", kv_v: str = "f16") -> tuple[float, list[str]]:
    notes = []
    n_layer = d.get("n_layer") or 0
    n_kv = d.get("n_head_kv") or d.get("n_head") or 0
    hk, hv = d.get("head_dim_k") or 0, d.get("head_dim_v") or d.get("head_dim_k") or 0
    if not (n_layer and n_kv and hk):
        raise ValueError("model dims incomplete (need n_layer, n_head_kv, head_dim)")
    attn_layers = n_layer
    if d.get("hybrid_ssm") and d.get("full_attention_interval"):
        attn_layers = math.ceil(n_layer / d["full_attention_interval"])
        notes.append(f"hybrid SSM: KV only on {attn_layers}/{n_layer} attention layers")
    elif d.get("sliding_window"):
        notes.append("sliding-window attention: KV counted as full for all layers (upper bound)")
    per = attn_layers * n_kv * (hk * KV_BYTES[kv_k] + hv * KV_BYTES[kv_v])
    return per, notes


def compute_buffer_mb(d: dict[str, Any], ubatch: int = 512) -> int:
    vocab = d.get("n_vocab") or 152_000
    embd = d.get("n_embd") or 4096
    return int(max(300, (vocab * ubatch * 4 + embd * ubatch * 4 * 16) / MiB))


def estimate(dims: dict[str, Any], weights_bytes: int, hw: dict[str, Any], *, ctx: int | None = None,
             kv_type: str = "f16", ubatch: int = 512, mmproj_bytes: int = 0, draft_bytes: int = 0,
             use_total_vram: bool = True, gpus: list[int] | None = None) -> dict[str, Any]:
    """Return a fit verdict, tensor split, max context and the arithmetic behind it."""
    if kv_type not in KV_BYTES:
        raise ValueError(f"kv_type must be one of {sorted(KV_BYTES)}")
    notes: list[str] = []
    kv_tok, kv_notes = kv_bytes_per_token(dims, kv_type, kv_type)
    notes += kv_notes
    ctx_train = dims.get("ctx_train") or 32768
    want_ctx = min(ctx or min(ctx_train, 32768), ctx_train)
    if ctx and ctx > ctx_train:
        notes.append(f"requested ctx {ctx} exceeds trained context {ctx_train}; capped")

    all_gpus = hw.get("gpus") or []
    sel = [g for g in all_gpus if gpus is None or g["index"] in gpus]
    backend = hw.get("gpu_backend", "cpu") if sel else "cpu"
    comp = compute_buffer_mb(dims, ubatch)
    over = GPU_OVERHEAD_MB.get(backend, 350)
    per_gpu = []
    for i, g in enumerate(sel):
        base = g["vram_total_mb"] if use_total_vram else g["vram_free_mb"]
        c = comp if i == 0 else comp // 2
        per_gpu.append({"index": g["index"], "name": g.get("name"), "usable_mb": max(0, base - over - c - RESERVE_MB)})
    avail = sum(p["usable_mb"] for p in per_gpu) * MiB
    extras = mmproj_bytes + draft_bytes
    weights = weights_bytes
    kv_at = lambda c: kv_tok * c  # noqa: E731
    need_gpu = weights + extras + kv_at(want_ctx)
    ram_avail = (hw.get("ram_available_mb") or hw.get("ram_total_mb") or 0) * MiB

    res: dict[str, Any] = {
        "inputs": {"weights_mb": round(weights / MiB), "mmproj_mb": round(mmproj_bytes / MiB),
                   "draft_mb": round(draft_bytes / MiB), "kv_type": kv_type, "ubatch": ubatch, "ctx": want_ctx,
                   "ctx_train": ctx_train, "backend": backend, "basis": "total VRAM" if use_total_vram else "free VRAM"},
        "kv_mb_per_1k_tokens": round(kv_tok * 1024 / MiB, 1),
        "kv_mb_at_ctx": round(kv_at(want_ctx) / MiB),
        "compute_buffer_mb_per_gpu": comp,
        "gpu_overhead_mb_per_gpu": over,
        "gpus": per_gpu,
        "gpu_usable_mb": round(avail / MiB),
        "need_mb": round(need_gpu / MiB),
        "notes": notes,
    }

    if per_gpu and need_gpu <= avail:
        spare = avail - weights - extras
        max_ctx = int(min(ctx_train, spare / kv_tok)) // 1024 * 1024
        tot = sum(p["usable_mb"] for p in per_gpu) or 1
        best = max(per_gpu, key=lambda p: p["usable_mb"])
        single = len(per_gpu) > 1 and need_gpu <= best["usable_mb"] * MiB
        res.update(verdict="fits_gpu", n_gpu_layers=999, max_ctx=max_ctx,
                   tensor_split=[round(p["usable_mb"] / tot * 100) for p in per_gpu] if len(per_gpu) > 1 and not single else None,
                   headroom_mb=round((avail - need_gpu) / MiB))
        if single:
            res.update(split_mode="none", main_gpu=best["index"])
            notes.append(f"fits on one GPU (#{best['index']}); no split = faster. "
                         f"Max ctx across all GPUs would be {max_ctx}")
            res["max_ctx_single_gpu"] = int(min(ctx_train, (best["usable_mb"] * MiB - weights - extras) / kv_tok)) // 1024 * 1024
        return res

    n_layer = dims.get("n_layer") or 1
    per_layer = weights / n_layer + kv_at(want_ctx) / n_layer
    ngl = int(max(0, (avail - extras) // per_layer)) if per_gpu else 0
    ngl = min(ngl, n_layer)
    cpu_part = (n_layer - ngl) * per_layer
    if ngl > 0 and cpu_part <= ram_avail * 0.9:
        tot = sum(p["usable_mb"] for p in per_gpu) or 1
        res.update(verdict="partial_offload", n_gpu_layers=ngl, max_ctx=want_ctx,
                   tensor_split=[round(p["usable_mb"] / tot * 100) for p in per_gpu] if len(per_gpu) > 1 else None,
                   ram_needed_mb=round(cpu_part / MiB))
        notes.append(f"{n_layer - ngl}/{n_layer} layers on CPU — expect a large slowdown (memory-bandwidth bound)")
        return res
    if weights + extras + kv_at(want_ctx) <= ram_avail * 0.9:
        res.update(verdict="cpu_only", n_gpu_layers=0, max_ctx=want_ctx,
                   ram_needed_mb=round((weights + extras + kv_at(want_ctx)) / MiB))
        notes.append("runs on CPU only — usable for small models, slow for large ones")
        return res
    res.update(verdict="does_not_fit", n_gpu_layers=0, max_ctx=0)
    notes.append("not enough VRAM + RAM; choose a smaller quant, smaller model, quantized KV (q8_0/q4_0) or less context")
    return res
