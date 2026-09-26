#!/usr/bin/env python3
import torch
import torch.nn.functional as F
import numpy as np

# Test the two scales on blk.3.ffn_up reconstruction
# 1. Variance-preserving scale: d_cal = d_orig * energy_mult
# 2. Regression scale: d* = sum(w * q) / 64
scale_orig = 0.0121
N_orig = 83.0 # average non-zeros in dense block
energy_mult = np.sqrt(N_orig / 64.0)
d_cal = scale_orig * energy_mult
d_reg = scale_orig # since sum(w * q) / 64 = scale_orig

print(f"Original scale: {scale_orig:.6f}")
print(f"Variance-preserving scale: {d_cal:.6f} (Layer Gain = 1.000)")
print(f"Regression scale: {d_reg:.6f} (Layer Gain = {d_reg/d_cal:.3f})")
print(f"Layer gain after 59 layers with regression scale: {(d_reg/d_cal)**59:.2e}")
