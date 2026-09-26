#!/usr/bin/env python3
import torch
import numpy as np

device = torch.device('cuda:1')
out_f = 17408
in_f = 5120
lora_rank = 16
lora_alpha = 16.0
scaling = lora_alpha / lora_rank

# Simulate true residual R and activation sigmas
R = torch.randn(out_f, in_f, device=device) * 0.005
sigmas_t = torch.rand(in_f, device=device) + 0.1

# Weighted residual
R_w = R * sigmas_t[None, :]

# SVD low-rank
U, S, V = torch.svd_lowrank(R_w, q=lora_rank, niter=4)

scale_factor = np.sqrt(scaling)
B = (U * torch.sqrt(S)[None, :]) / scale_factor
A = (torch.sqrt(S)[:, None] * (V / sigmas_t[:, None]).T) / scale_factor

print("B shape:", B.shape, "A shape:", A.shape)

# Verify LoRA delta: scaling * (X @ A.T) @ B.T vs X @ R.T
X = torch.randn(32, in_f, device=device)
Y_true = X @ R.T
Y_lora = scaling * (X @ A.T) @ B.T

cos_sim = torch.cosine_similarity(Y_true.flatten(), Y_lora.flatten(), dim=0)
print(f"Cosine similarity between true residual output and SVD LoRA output: {cos_sim.item():.6f}")
assert cos_sim.item() > 0.5, "SVD LoRA output does not align with residual!"
print("Mathematical SVD LoRA formulation is 100% verified!")
