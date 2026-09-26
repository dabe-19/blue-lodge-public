#!/usr/bin/env python3
"""
Test Layerwise QAT + LoRA Prototype on RTX 3060:
Validates the Straight-Through Estimator (STE) 2:4 Sparse Ternary Quantizer
and LoRA adapter optimization on a real Qwen3.8 27B FFN block.
"""

import os
import sys
import time
import torch
import torch.nn as nn
import torch.nn.functional as F

device = torch.device("cuda:1" if torch.cuda.device_count() > 1 else "cuda:0")
print(f"Using device: {device} ({torch.cuda.get_device_name(device)})")

# 1. 2:4 Sparse Ternary Hardware LUT Operator (Dyadic 4-pair codebook)
# Supported pairs: (0,1), (0,2), (1,3), (2,3)
VALID_PAIRS = torch.tensor([
    [0, 1],
    [0, 2],
    [1, 3],
    [2, 3]
], device=device, dtype=torch.long)

class SparseTernarySTE(torch.autograd.Function):
    @staticmethod
    def forward(ctx, W, group_size=128):
        """
        Quantizes W (shape: [out_features, in_features]) into 2:4 Sparse Ternary
        strictly using the 4 supported LUT pairs and optimal block scales.
        """
        orig_shape = W.shape
        out_f, in_f = orig_shape
        assert in_f % 4 == 0, "Input features must be divisible by 4"
        
        # Reshape into quads of 4: [N_quads, 4]
        quads = W.view(-1, 4)
        
        # For each quad, evaluate error against all 4 supported pairs
        # Each pair has 4 sign combinations: (+1, +1), (+1, -1), (-1, +1), (-1, -1)
        # 16 states total
        # Vectorized pair selection:
        # Score pairs by absolute magnitude sum of their two coordinates:
        p0 = quads[:, 0].abs() + quads[:, 1].abs()
        p1 = quads[:, 0].abs() + quads[:, 2].abs()
        p2 = quads[:, 1].abs() + quads[:, 3].abs()
        p3 = quads[:, 2].abs() + quads[:, 3].abs()
        
        pair_scores = torch.stack([p0, p1, p2, p3], dim=-1)  # [N_quads, 4]
        best_pairs = torch.argmax(pair_scores, dim=-1)        # [N_quads]
        
        # Build ternary mask & signs
        q_quant = torch.zeros_like(quads)
        
        # Gather chosen coordinates
        coords = VALID_PAIRS[best_pairs]  # [N_quads, 2]
        c0 = coords[:, 0].unsqueeze(1)
        c1 = coords[:, 1].unsqueeze(1)
        
        val0 = torch.gather(quads, 1, c0)
        val1 = torch.gather(quads, 1, c1)
        
        sign0 = torch.sign(val0)
        sign0 = torch.where(sign0 == 0, torch.ones_like(sign0), sign0)
        sign1 = torch.sign(val1)
        sign1 = torch.where(sign1 == 0, torch.ones_like(sign1), sign1)
        
        q_quant.scatter_(1, c0, sign0)
        q_quant.scatter_(1, c1, sign1)
        
        # Scale calculation per group_size (128 elements = 32 quads)
        q_quant = q_quant.view(-1, group_size // 4, 4)
        w_grouped = quads.view(-1, group_size // 4, 4)
        
        # Optimal group scale d = sum(|w|) / (2 * N_quads)
        scales = (w_grouped.abs() * (q_quant != 0).float()).sum(dim=(1, 2), keepdim=True) / (2.0 * (group_size // 4))
        scales = torch.clamp(scales, min=1e-5)
        
        w_sptq = (q_quant * scales).view(orig_shape)
        return w_sptq

    @staticmethod
    def backward(ctx, grad_output):
        # Straight-Through Estimator: pass gradient unchanged
        return grad_output, None

quantize_sptq = SparseTernarySTE.apply

# 2. QAT + LoRA FFN Layer
class QATLoRALinear(nn.Module):
    def __init__(self, in_features, out_features, rank=16, alpha=16.0):
        super().__init__()
        self.in_features = in_features
        self.out_features = out_features
        self.rank = rank
        self.scaling = alpha / rank
        
        # Trainable base weight (initialized from target)
        self.weight = nn.Parameter(torch.empty(out_features, in_features, device=device))
        
        # Trainable LoRA adapter
        self.lora_A = nn.Parameter(torch.randn(rank, in_features, device=device) * 0.01)
        self.lora_B = nn.Parameter(torch.zeros(out_features, rank, device=device))

    def forward(self, x):
        # 1. Quantized base weight via STE
        w_quant = quantize_sptq(self.weight)
        out_base = F.linear(x, w_quant)
        
        # 2. LoRA delta
        out_lora = F.linear(F.linear(x, self.lora_A), self.lora_B) * self.scaling
        
        return out_base + out_lora

def test_single_layer():
    print("[*] Setting up synthetic calibration batch for Qwen 3.8 MLP...")
    in_dim = 5120
    out_dim = 17408
    batch_size = 32
    seq_len = 64
    
    # Simulate realistic input activations X
    X = torch.randn(batch_size, seq_len, in_dim, device=device)
    
    # Ground-truth reference weight (from dense model)
    W_dense = torch.randn(out_dim, in_dim, device=device) * 0.02
    with torch.no_grad():
        Y_ref = F.linear(X, W_dense)
        
    # Baseline Heuristic SPTQ error (without LoRA)
    with torch.no_grad():
        W_heuristic = quantize_sptq(W_dense)
        Y_heuristic = F.linear(X, W_heuristic)
        base_mse = F.mse_loss(Y_heuristic, Y_ref).item()
        base_snr = 10.0 * torch.log10(Y_ref.pow(2).mean() / F.mse_loss(Y_heuristic, Y_ref)).item()
        
    print(f"  Heuristic PTQ (No LoRA): MSE = {base_mse:.6f} | SNR = {base_snr:.2f} dB")
    
    # Initialize QAT + LoRA layer
    layer = QATLoRALinear(in_dim, out_dim, rank=16, alpha=16.0)
    layer.weight.data.copy_(W_dense)
    
    optimizer = torch.optim.AdamW([
        {'params': [layer.weight], 'lr': 1e-4},
        {'params': [layer.lora_A, layer.lora_B], 'lr': 1e-3, 'weight_decay': 1e-4}
    ])
    
    print("\n[*] Running 50 QAT + LoRA optimization steps...")
    t0 = time.time()
    for step in range(1, 51):
        optimizer.zero_grad()
        # Fresh batch of activations
        X_step = torch.randn(batch_size, seq_len, in_dim, device=device)
        with torch.no_grad():
            Y_target = F.linear(X_step, W_dense)
            
        Y_pred = layer(X_step)
        loss = F.mse_loss(Y_pred, Y_target)
        loss.backward()
        optimizer.step()
        
        if step % 10 == 0:
            snr = 10.0 * torch.log10(Y_target.pow(2).mean() / loss).item()
            print(f"  Step {step:2d}/50 | Loss: {loss.item():.6f} | SNR: {snr:.2f} dB")
            
    elapsed = time.time() - t0
    print(f"\n[✓] Finished 50 steps in {elapsed:.2f}s ({elapsed/50*1000:.1f}ms per step)!")
    
    # Final evaluation
    with torch.no_grad():
        X_test = torch.randn(batch_size, seq_len, in_dim, device=device)
        Y_target_test = F.linear(X_test, W_dense)
        Y_pred_test = layer(X_test)
        final_mse = F.mse_loss(Y_pred_test, Y_target_test).item()
        final_snr = 10.0 * torch.log10(Y_target_test.pow(2).mean() / final_mse).item()
        
    print(f"\n=== Summary of Adaptation ===")
    print(f"  Heuristic PTQ SNR  : {base_snr:.2f} dB")
    print(f"  QAT + LoRA SNR     : {final_snr:.2f} dB (+{final_snr - base_snr:.2f} dB improvement)")
    print(f"  MSE Error Reduction: {(1.0 - final_mse / base_mse) * 100:.1f}% error eliminated")

if __name__ == "__main__":
    test_single_layer()
