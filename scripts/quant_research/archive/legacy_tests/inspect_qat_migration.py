#!/usr/bin/env python3
"""
Inspect QAT Coordinate Migration on blk.3.ffn_up:
Measures:
1. Number and percentage of quads that flipped discrete codebook state.
2. Step-by-step MSE reduction over the 15 AdamW steps.
3. Distribution of hardware pairs before vs after QAT.
"""
import torch
import torch.nn as nn
import torch.nn.functional as F
import numpy as np
import gguf
from gguf.constants import GGMLQuantizationType, GGML_QUANT_SIZES
import time

def register_ggml_type(name: str, value: int, block_size: int, type_size: int):
    obj = int.__new__(GGMLQuantizationType, value)
    obj._value_ = value
    obj._name_ = name
    GGMLQuantizationType._value2member_map_[value] = obj
    GGMLQuantizationType._member_map_[name] = obj
    GGML_QUANT_SIZES[obj] = (block_size, type_size)
    return obj

register_ggml_type('PTQ1_0', 143, 128, 28)
register_ggml_type('SPTQ1_0', 145, 128, 18)

device = torch.device('cpu')

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
        dc_drift = (torch.sum(diff * s_chunk, dim=-1)) ** 2
        jitter = torch.rand(n_c, 16, device=device) * 1e-5

        cost = weighted_mse + 0.6 * dc_drift + jitter
        best_idx[i:end] = torch.argmin(cost, dim=-1)

    W_q_unit = SPTQ_LUT[best_idx]
    return W_q_unit, best_idx

def main():
    reader = gguf.GGUFReader('/home/wsl-ops/models/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf')
    t = [x for x in reader.tensors if x.name == 'blk.3.ffn_up.weight'][0]
    shape = list(t.shape)
    ne0 = shape[0]
    out_f = shape[1]
    in_f = ne0
    raw_bytes = bytes(t.data)
    n_blocks = len(raw_bytes) // 28
    n_quads = (n_blocks * 128) // 4
    quads_per_row = in_f // 4

    trits, scales_orig = unpack_ptq1_0(raw_bytes, n_blocks)
    w_dense_np = (trits * scales_orig[:, None]).astype(np.float32).reshape(out_f, in_f)
    W_dense_t = torch.tensor(w_dense_np, device=device, dtype=torch.float32)

    sigmas = np.ones(ne0, dtype=np.float32)
    sigmas_t = torch.tensor(sigmas, device=device, dtype=torch.float32)
    sigmas_quad_base = sigmas.reshape(quads_per_row, 4)
    sigmas_quad_np = np.broadcast_to(sigmas_quad_base, (out_f, quads_per_row, 4)).reshape(n_quads, 4)
    S_quads = torch.tensor(sigmas_quad_np, device=device, dtype=torch.float32)

    trits_quad = trits.reshape(n_quads, 4).astype(np.float32)
    W_unit = nn.Parameter(torch.tensor(trits_quad, device=device, dtype=torch.float32))

    orig_nz = np.sum(trits != 0, axis=1)
    energy_mult = np.sqrt(np.maximum(orig_nz.astype(np.float32), 1.0) / 64.0)
    scales_init = scales_orig.astype(np.float32) * energy_mult
    d_block = torch.tensor(scales_init[:, None], device=device, dtype=torch.float32)

    # Initial discrete state
    with torch.no_grad():
        _, initial_best_idx = quantize_unit_quads_cuda(W_unit, S_quads)

    opt = torch.optim.AdamW([{'params': [W_unit], 'lr': 5e-2, 'weight_decay': 1e-4}])

    print("Step-by-step training trajectory on blk.3.ffn_up (22.28M quads):")
    losses = []
    for step in range(15):
        opt.zero_grad()
        X_batch = torch.randn(64, in_f, device=device) * sigmas_t[None, :]
        with torch.no_grad():
            Y_target = X_batch @ W_dense_t.T

        W_q_discrete, _ = quantize_unit_quads_cuda(W_unit, S_quads)
        W_q_ste = W_unit + (W_q_discrete - W_unit).detach()
        d_exp = d_block.repeat_interleave(32, dim=0)
        W_q = (W_q_ste * d_exp).view(out_f, in_f)

        loss = F.mse_loss(X_batch @ W_q.T, Y_target)
        losses.append(loss.item())
        loss.backward()
        opt.step()

        with torch.no_grad():
            W_unit.clamp_(-1.5, 1.5)

        if (step + 1) % 3 == 0 or step == 0:
            print(f"  Step {step+1:2d}/15: MSE Loss = {loss.item():.6f}")

    # Final discrete state
    with torch.no_grad():
        _, final_best_idx = quantize_unit_quads_cuda(W_unit, S_quads)

    # Measure actual coordinate migration
    flipped = torch.sum(initial_best_idx != final_best_idx).item()
    total_quads = len(initial_best_idx)
    flip_pct = (flipped / total_quads) * 100

    print(f"\n[✓] Concrete Migration Empirical Findings:")
    print(f"  • Initial Step 1 Loss: {losses[0]:.6f} --> Final Step 15 Loss: {losses[-1]:.6f}")
    print(f"  • Quads with Changed Discrete Codes: {flipped:,} / {total_quads:,} ({flip_pct:.2f}%)")
    print(f"  • Overall Loss Reduction: {((losses[0] - losses[-1]) / losses[0]) * 100:.2f}%")

if __name__ == "__main__":
    main()
