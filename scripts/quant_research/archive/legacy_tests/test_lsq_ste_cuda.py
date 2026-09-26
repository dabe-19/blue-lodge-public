#!/usr/bin/env python3
import torch
import torch.nn as nn
import torch.nn.functional as F
import numpy as np
import time

device = torch.device('cuda:1' if torch.cuda.is_available() else 'cpu')
print(f"Testing on {device} ({torch.cuda.get_device_name(device)})")

# 16-state hardware LUT
SPTQ_LUT = torch.tensor([
    [ 1.,  1.,  0.,  0.], [ 1., -1.,  0.,  0.], [-1.,  1.,  0.,  0.], [-1., -1.,  0.,  0.],
    [ 1.,  0.,  1.,  0.], [ 1.,  0., -1.,  0.], [-1.,  0.,  1.,  0.], [-1.,  0., -1.,  0.],
    [ 0.,  1.,  0.,  1.], [ 0.,  1.,  0., -1.], [ 0., -1.,  0.,  1.], [ 0., -1.,  0., -1.],
    [ 0.,  0.,  1.,  1.], [ 0.,  0.,  1., -1.], [ 0.,  0., -1.,  1.], [ 0.,  0., -1., -1.]
], dtype=torch.float32, device=device)

def quantize_unit_quads_cuda(W_unit_quads, S_quads, chunk_size=524288):
    """
    Pure PyTorch CUDA vectorized 16-state codebook search.
    W_unit_quads: (N, 4) in unit space [-1.5, 1.5]
    S_quads: (N, 4) activation standard deviations
    Returns: W_q_unit (N, 4) and best_idx (N,)
    """
    N = len(W_unit_quads)
    best_idx = torch.empty(N, dtype=torch.long, device=device)
    
    lut_exp = SPTQ_LUT.unsqueeze(0) # (1, 16, 4)
    
    for i in range(0, N, chunk_size):
        end = min(i + chunk_size, N)
        w_chunk = W_unit_quads[i:end].unsqueeze(1) # (C, 1, 4)
        s_chunk = S_quads[i:end].unsqueeze(1)      # (C, 1, 4)
        
        diff = lut_exp - w_chunk                   # (C, 16, 4)
        weighted_mse = torch.sum((diff * s_chunk)**2, dim=-1) # (C, 16)
        dc_drift = torch.abs(torch.sum(diff * s_chunk, dim=-1)) # (C, 16)
        
        cost = weighted_mse + 0.6 * dc_drift
        best_idx[i:end] = torch.argmin(cost, dim=-1)
        
    W_q_unit = SPTQ_LUT[best_idx]
    return W_q_unit, best_idx

def test_full_tensor():
    in_f = 5120
    out_f = 17408
    n_weights = in_f * out_f
    n_quads = n_weights // 4
    n_blocks = n_weights // 128
    
    print(f"Allocating dummy MLP tensor: {out_f}x{in_f} ({n_weights/1e6:.1f}M weights, {n_quads/1e6:.1f}M quads)...")
    
    # Unit space latent weights
    W_unit = nn.Parameter(torch.randn(n_quads, 4, device=device).clamp(-1.0, 1.0))
    # Learnable block scales (LSQ)
    d_block = nn.Parameter(torch.full((n_blocks, 1), 0.015, dtype=torch.float32, device=device))
    # Imbalance sigmas
    S_quads = torch.rand(n_quads, 4, device=device) + 0.1
    
    # LoRA parameters
    lora_rank = 16
    lora_A = nn.Parameter(torch.randn(lora_rank, in_f, device=device) * 0.01)
    lora_B = nn.Parameter(torch.zeros(out_f, lora_rank, device=device))
    
    opt = torch.optim.AdamW([
        {'params': [W_unit], 'lr': 1e-3, 'weight_decay': 1e-4},
        {'params': [d_block], 'lr': 5e-4},
        {'params': [lora_A, lora_B], 'lr': 2e-3}
    ])
    
    X = torch.randn(32, in_f, device=device)
    Y_target = torch.randn(32, out_f, device=device)
    
    print("Testing 5 optimization steps with CUDA STE + LSQ...")
    t0 = time.time()
    for step in range(5):
        opt.zero_grad()
        
        # 1. Unit space codebook projection
        W_q_discrete, best_idx = quantize_unit_quads_cuda(W_unit, S_quads)
        # 2. STE: gradient flows into W_unit
        W_q_ste = W_unit + (W_q_discrete - W_unit).detach()
        
        # 3. Apply LSQ block scales: 32 quads per block
        d_expanded = d_block.repeat_interleave(32, dim=0) # (n_quads, 1)
        W_q = (W_q_ste * d_expanded).view(out_f, in_f)
        
        # 4. LoRA residual delta
        lora_delta = (X @ lora_A.T) @ lora_B.T
        Y_pred = (X @ W_q.T) + lora_delta
        
        loss = F.mse_loss(Y_pred, Y_target)
        loss.backward()
        opt.step()
        
        # 5. Clamp latent unit weights to [-1.5, 1.5] preventing drift
        with torch.no_grad():
            W_unit.clamp_(-1.5, 1.5)
            d_block.clamp_(min=1e-5)
            
        print(f"  Step {step+1}/5: Loss={loss.item():.6f}, VRAM={torch.cuda.memory_allocated(device)/1024**2:.1f} MB")
        
    t_tot = time.time() - t0
    print(f"✓ 5 steps completed in {t_tot:.2f}s ({t_tot/5:.3f}s per step)! Peak VRAM: {torch.cuda.max_memory_allocated(device)/1024**2:.1f} MB")

if __name__ == "__main__":
    test_full_tensor()
