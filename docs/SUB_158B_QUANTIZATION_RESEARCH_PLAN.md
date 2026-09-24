# Sub-1.58b Quantization Research & Experimentation Plan

## 1. Executive Summary & Theoretical Foundations

Recent work by sudoingx and BitNet b1.58 demonstrated that large language models can be quantized to ternary weights $W \in \{-1, 0, 1\}$ with negligible perplexity degradation at 1.58 bits per parameter ($\log_2 3 \approx 1.58496$ bits).

However, **1.58 bits is an uncompressed information-theoretic upper bound for independent, uniformly distributed trits**. In real neural networks, weights are neither uniformly distributed nor independent:

1. **Empirical Distribution Skew**: In trained ternary networks (e.g. BitNet, Bonsai), the zero weight is typically over-represented:
   $$P(W = 0) \approx 0.50, \quad P(W = +1) \approx 0.25, \quad P(W = -1) \approx 0.25$$
   The Shannon entropy $H(W)$ is:
   $$H(W) = -\sum_{x \in \{-1, 0, 1\}} P(x) \log_2 P(x) = -(0.5 \log_2 0.5 + 2 \cdot 0.25 \log_2 0.25) = 0.5(1) + 0.5(2) = 1.50 \text{ bits/weight}$$
   By exploiting entropy coding, standard ternary models can immediately drop from 1.58 to $\le 1.50$ bpw.

2. **2:4 Structural Sparsity on Ampere/Ada Tensor Cores**:
   NVIDIA Ampere and Ada architectures support hardware-accelerated 2:4 sparse matrix multiplication (`mma.sp` PTX instructions).
   - In every group of 4 contiguous weights along the input channel, exactly 2 weights are zero, and 2 are non-zero.
   - For non-zero weights in ternary $\{-1, +1\}$, each non-zero element requires only **1 bit** (sign bit).
   - Choosing 2 non-zero positions out of 4 requires $\binom{4}{2} = 6$ states, which can be encoded in **2 bits** (or $\log_2 6 \approx 2.58$ bits with pair-packing).
   - **Storage cost**: $2 \text{ sign bits} + 2 \text{ index bits} = 4 \text{ bits}$ per 4 weights $\implies \mathbf{1.00 \text{ to } 1.14 \text{ bits per weight}}$!
   - **Compute benefit**: Tensor cores execute 2:4 sparse GEMM at **2x the mathematical throughput** and half the memory bandwidth.

3. **Delta Modulation & Booth Trit Recoding**:
   Instead of storing absolute ternary states, weights along adjacent channels or tokens exhibit strong local spatial correlation:
   - Storing a binary stream $b_i \in \{0, 1\}$ and generating ternary values via delta differentiation:
     $$w_i = b_i - b_{i-1} \in \{-1, 0, +1\}$$
   - This represents a continuous ternary stream using **exactly 1.0 bit per weight**, mapping high-frequency zero-crossings into ternary activations without dedicated trit storage.

4. **$E_8$ Gosset Lattice Vector Quantization**:
   The $E_8$ lattice in $\mathbb{R}^8$ achieves the densest sphere packing in 8 dimensions (kissing number 240). By quantizing 8-dimensional weight vectors directly to the nearest lattice point scaled by a per-vector gain, we achieve near-optimal rate-distortion performance, cutting bitrates to $\sim 1.125 - 1.25$ bpw while preserving gradient fidelity.

---

## 2. Mathematical Formulations & Encoding Schemes

### A. 2:4 Sparse Ternary (1.00 - 1.14 bpw)
Let matrix $W \in \mathbb{R}^{M \times K}$. For every row $i$ and 4-tuple of columns $k \in \{0, 4, 8, \dots, K-4\}$:
$$\text{Indices } (p_1, p_2) \in \binom{\{0,1,2,3\}}{2}, \quad s_1, s_2 \in \{-1, +1\}$$
- Compression format per 32-weight chunk:
  - 16 non-zero values $\times 1$ bit = 16 bits
  - 8 pairs of 2-bit indices = 16 bits
  - Total = 32 bits per 32 weights = **1.00 bpw** (plus FP16/BF16 scale factor per block of 256 weights $\approx +0.06$ bpw).

### B. UD Factorization & Residual Rotation
Applying a unitary-diagonal-unitary decomposition or pre-quantization orthogonal rotation (Hadamard / Randomized Kronecker product $R$):
$$W' = W \cdot R^T, \quad X' = X \cdot R$$
Since $R^T R = I$, $W X = W' X'$.
Rotating the weights flattens outliers across all channels, concentrating the distribution around zero and drastically improving the SNR of low-bit clipping into $\{-1, 0, +1\}$.

---

## 3. Hands-On Lab & Benchmarking Blueprint

To test these hypotheses on the actual **Ternary-Bonsai-2-27B** model running in this environment:

### Target Model & Artifacts
- **Model**: `Ternary-Bonsai-2-27B-PQ2_0.gguf`
- **Repo / Engine**: `/home/wsl-ops/models/llama.cpp-prism.git` (or the host llama.cpp engine)
- **Host GPU Sandbox**: RTX 3090 (Ampere architecture, full support for `mma.sp` and fast FP16/BF16 Tensor Cores).

### Step 1: Weight Distribution & Entropy Extraction
A Python script using `gguf` to inspect all tensor layers of `Ternary-Bonsai-2-27B`:
```python
import gguf
import numpy as np

reader = gguf.GGUFReader("Ternary-Bonsai-2-27B-PQ2_0.gguf")
for tensor in reader.tensors:
    if "weight" in tensor.name and tensor.data.ndim >= 2:
        weights = tensor.data
        p_neg = np.mean(weights == -1)
        p_zero = np.mean(weights == 0)
        p_pos = np.mean(weights == 1)
        entropy = -sum(p * np.log2(p) for p in [p_neg, p_zero, p_pos] if p > 0)
        print(f"{tensor.name}: P(0)={p_zero:.3f}, H={entropy:.3f} bpw")
```

### Step 2: 2:4 Sparsification & Retargeting
1. Identify layers with $P(0) \ge 0.50$ (typically MLP projection and down-projection layers).
2. Apply greedy 2:4 magnitude projection: for every block of 4 weights, keep the 2 largest magnitude weights and zero out the remaining 2.
3. Compute the reconstruction MSE across calibration activations (e.g. C4 or WikiText-2 subsets).

### Step 3: Custom CUDA / PTX Kernel
1. Implement a specialized CUDA kernel in `llama.cpp/ggml` using the inline assembly:
   ```ptx
   mma.sp.sync.aligned.m16n8k32.row.col ...
   ```
2. Unpack the compressed 2:4 ternary bitstream directly into registers without storing intermediate FP16 weights in shared memory.

### Step 4: Perplexity & Throughput Validation
- Measure perplexity via `llama-perplexity -m ... -f wikitext-2-raw-v1.test.raw`.
- Measure generation speed and memory bandwidth scaling: target is $1.3\times - 1.8\times$ faster decode tokens/second compared to uncompressed ternary.
