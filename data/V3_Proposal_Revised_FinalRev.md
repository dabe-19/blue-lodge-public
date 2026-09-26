# Parallel Orthogonal Filter-Bank Seeding with Dual-Track Information Auditing, Plant-Adaptive Subspace Clustering, and Block-Diagonal Gradient Preconditioning for Deep Reservoir Networks

**Applicant:** David McCabe, M.S.

**Target Program:** Ph.D. in Computer Sciences / Electrical and Computer Engineering

**Target Institution:** College of Computing and AI, University of Wisconsin–Madison

**Advisor:** [To Be Confirmed]

**Date:** May 2026

---

## Abstract

Echo State Networks (ESNs) offer a computationally efficient alternative to fully-trained recurrent architectures by fixing the recurrent weights and training only a linear readout layer. However, scaling ESNs to match the representational capacity of deep artificial neural networks (ANNs) introduces three open problems: (1) stochastic initialization of reservoir weights leads to inconsistent temporal memory capacity across runs, (2) dimensional lifting of compact reservoir matrices to match wider ANN layers distorts the eigenspectrum and violates the Echo State Property, and (3) fine-tuning the seeded ANN via backpropagation through time (BPTT) lacks curvature-aware optimization adapted to the block-diagonal structure inherited from the parallel filter bank.

This proposal presents a four-stage pipeline that addresses these problems. **Stage 1** replaces stochastic initialization with Haar-distributed random orthogonal matrices scaled to a prescribed spectral radius, guaranteeing uniform energy preservation across recurrent modes. **Stage 2** introduces a Dual-Track Normalized Mutual Information (NMI) auditing mechanism that compares unsupervised reservoir state clusterings against ground-truth physical labels using plant-adaptive Bayesian nonparametric clustering, enabling automated detection of latent dynamical structure. **Stage 3** applies Kronecker product expansions against identity matrices to lift compact reservoir weight matrices to arbitrary ANN dimensions while provably preserving the eigenspectrum. **Stage 4** exploits the inherited block-diagonal structure of the gradient tensor to perform localized empirical gradient preconditioning at $\mathcal{O}(N_l^3)$ per block, synchronized across blocks via a macro-covariance scaling mechanism derived from signed-momentum gradient projections.

We propose to validate this pipeline on three benchmark systems of increasing complexity: the Lorenz-63 chaotic attractor, a Wiener-Hammerstein nonlinear system identification task, and a non-autonomous nuclear point-reactor kinetics (PRKE) model with coupled thermal-hydraulic feedback. Cross-platform numerical reproducibility is verified through a Trajectory Alignment Metric (TAM) comparing hidden state activations across CPU and GPU execution backends.

---

## 1. Introduction and Motivation

### 1.1 Background

Reservoir computing (RC) is a recurrent neural network paradigm in which a high-dimensional, randomly initialized dynamical system—the *reservoir*—projects temporal input sequences into a rich nonlinear feature space, from which a simple linear readout is trained via least-squares regression [1, 2]. Echo State Networks (ESNs) [1] and Liquid State Machines [3] are the two canonical instantiations. The key computational advantage is that only the readout weights are trained, avoiding the expense and instability of backpropagation through time (BPTT) in the recurrent layer.

Despite this efficiency, ESNs face well-documented limitations when applied to complex, multi-timescale dynamical systems. The random initialization of the input weight matrix $\mathbf{W}_{\text{in}}$ and recurrent weight matrix $\mathbf{W}_{\text{res}}$ introduces significant run-to-run variance in the reservoir's temporal memory profile [4]. The spectral radius $\rho(\mathbf{W}_{\text{res}})$—the magnitude of the largest eigenvalue—must satisfy $\rho < 1$ to maintain the Echo State Property (ESP) [1], but random matrices drawn from standard distributions exhibit uncontrolled eigenvalue spread, with some modes decaying rapidly and others approaching instability.

Parallel or modular reservoir architectures [5, 6] address the multi-timescale problem by instantiating multiple independent reservoir blocks, each tuned to a different spectral radius and leaking rate, thereby capturing fast transients and slow trends simultaneously. However, this introduces a dimensional mismatch: each compact reservoir block ($N_l$ neurons) must be mapped into a shared ANN hidden layer ($N$ neurons) for downstream fine-tuning. Naive approaches—such as zero-padding or non-square semi-orthogonal projections—distort the eigenspectrum of the reservoir weights [7], breaking the carefully calibrated ESP.

### 1.2 Open Problems

This proposal identifies and addresses five specific open problems at the intersection of reservoir computing, information theory, and optimization geometry:

**Problem 1 — Stochastic Initialization Variance.** Initializing reservoir weight matrices with random uniform or Gaussian entries produces eigenspectra with uncontrolled spread, leading to mode-dependent energy decay that reduces the effective memory capacity of the reservoir during the pre-training evaluation ("scout") pass.

**Problem 2 — Spectral Deformation Under Dimensional Lifting.** Scaling a compact reservoir block to match a target ANN layer dimension via non-square projection matrices warps the eigenvalues, potentially violating the ESP ($\rho \geq 1$) and destroying the contractive dynamics essential for stable reservoir operation.

**Problem 3 — Fixed-Topology Clustering Bias.** Evaluating reservoir quality via clustering metrics (e.g., NMI) using a fixed number of Gaussian mixture components imposes an inductive bias that mismatches the true topological complexity of the state manifold. Continuous chaotic attractors (e.g., Lorenz) and discrete piecewise-switching systems (e.g., Wiener-Hammerstein) require fundamentally different distributional assumptions.

**Problem 4 — Inter-Block Gradient Interference.** In block-diagonal architectures, standard BPTT treats the full gradient matrix as a monolithic object, ignoring the structural independence of the blocks. During large plant-wide transients, gradient updates in one frequency block can destructively interfere with updates in another, leading to oscillatory training dynamics.

**Problem 5 — Cross-Platform Numerical Reproducibility.** Floating-point arithmetic varies across CPU instruction sets (e.g., AVX-512 fused multiply-add ordering) and GPU execution pipelines (e.g., Tensor Core reduced-precision accumulation). In chaotic systems with positive Lyapunov exponents, these microscopic variations can amplify exponentially through the recurrent dynamics, producing divergent training trajectories from identical seeds.

### 1.3 Contributions

This proposal makes the following contributions:

1. A **Haar-corrected orthogonal initialization** procedure for parallel ESN weight matrices that guarantees uniform eigenvalue placement on a circle of prescribed radius in the complex plane (Section 4.1).

2. A **Dual-Track NMI auditing framework** with plant-adaptive Bayesian nonparametric clustering that automatically infers the topological complexity of the reservoir state manifold and detects latent physical structure invisible to human-defined labels (Section 4.2).

3. A **Kronecker product expansion** scheme that provably preserves the eigenspectrum when lifting compact reservoir matrices to arbitrary ANN dimensions (Section 4.3).

4. A **block-diagonal gradient preconditioner** that exploits the inherited block structure to perform localized curvature-aware updates at reduced computational cost, synchronized across blocks via a signed-momentum macro-covariance scaling mechanism (Section 4.4).

5. A **Trajectory Alignment Metric (TAM)** for quantifying cross-platform numerical divergence in recurrent network training (Section 5.2).

---

## 2. Literature Review

### 2.1 Reservoir Computing and Echo State Networks

Echo State Networks were introduced by Jaeger [1] as a practical instantiation of reservoir computing, building on earlier work by Maass et al. on Liquid State Machines [3]. The Echo State Property—the requirement that the reservoir's response to an input sequence asymptotically loses dependence on initial conditions—was formalized by Yildiz et al. [8], who established sufficient conditions based on the spectral radius of the recurrent weight matrix.

Parallel and modular reservoir architectures were explored by Gallicchio et al. [5] (deep ESNs) and Rodan and Tiňo [6] (simple cycle reservoirs), demonstrating that structured topologies can outperform fully random reservoirs on multi-timescale tasks. The use of multiple independent reservoirs with heterogeneous spectral radii and leaking rates to capture different frequency bands was studied by Butcher et al. [9].

### 2.2 Orthogonal and Unitary Initialization

The benefits of orthogonal weight initialization for recurrent networks were established by Saxe et al. [10], who showed that orthogonal matrices preserve gradient norms during backpropagation, mitigating the vanishing/exploding gradient problem. Henaff et al. [11] and Arjovsky et al. [12] extended this to unitary (complex-valued) recurrent networks, demonstrating improved long-term memory on synthetic benchmarks. The importance of sampling orthogonal matrices uniformly from the Haar measure was highlighted by Mezzadri [13], who showed that naive QR decomposition introduces distributional bias that can be corrected by a diagonal sign adjustment.

### 2.3 Information-Theoretic Evaluation of Reservoirs

Normalized Mutual Information (NMI) as a clustering evaluation metric was formalized by Strehl and Ghosh [14]. Its application to reservoir computing was explored by Verstraeten et al. [15], who used mutual information between reservoir states and target signals to characterize reservoir quality. The use of unsupervised clustering to detect latent dynamical regimes in time series data has been studied extensively in the dynamical systems literature [16], but its integration into an automated reservoir evaluation pipeline with dual-track (supervised vs. unsupervised) comparison is, to our knowledge, novel.

### 2.4 Bayesian Nonparametric Clustering

The Dirichlet Process Gaussian Mixture Model (DPGMM) was introduced by Rasmussen [17] and further developed by Blei and Jordan [18]. Variational inference for DPGMMs was established by Blei and Jordan [18] and implemented efficiently in scikit-learn [19]. The key advantage over finite mixture models is the ability to automatically infer the number of clusters from data, using the Dirichlet Process prior to suppress unnecessary components.

### 2.5 Natural Gradient and Second-Order Optimization

The natural gradient, introduced by Amari [20], replaces the Euclidean gradient with the gradient preconditioned by the inverse Fisher Information Matrix (FIM), yielding updates that are invariant to reparameterization of the model. Computing the full FIM is intractable for large networks ($\mathcal{O}(P^2)$ storage where $P$ is the parameter count), motivating block-diagonal approximations. Kronecker-Factored Approximate Curvature (K-FAC) [21] approximates the FIM using Kronecker products of layer-wise input and gradient covariance matrices, enabling efficient natural gradient updates. Extensions include EKFAC [22] for eigenvalue-corrected Kronecker factors and Shampoo [23] for structured preconditioners.

Our approach differs from K-FAC in a fundamental way: rather than *approximating* a full Fisher matrix with Kronecker structure, we exploit the *architecturally imposed* block-diagonal structure of the gradient to construct localized empirical covariance preconditioners. This is more closely related to block-diagonal preconditioning in the optimization literature [24] than to natural gradient methods, and we frame it accordingly.

### 2.6 Kronecker Products in Neural Networks

Kronecker products have been used extensively in neural network optimization (K-FAC [21]), weight compression [25], and structured linear algebra [26]. The spectral property of Kronecker products—that $\text{spec}(A \otimes B) = \{\lambda_i \mu_j : \lambda_i \in \text{spec}(A), \mu_j \in \text{spec}(B)\}$—is a standard result in matrix theory [27]. We exploit this property for *weight expansion* rather than compression, which is a less explored application direction.

---

## 3. Research Questions and Hypotheses

### 3.1 Research Questions

**RQ1:** Does replacing stochastic reservoir initialization with Haar-distributed random orthogonal matrices, scaled to a prescribed spectral radius, improve the temporal memory capacity and reduce run-to-run variance of parallel ESN filter banks?

**RQ2:** Can a dual-track NMI comparison between unsupervised reservoir state clusterings and ground-truth physical labels, using plant-adaptive Bayesian nonparametric clustering, detect latent dynamical transitions that are invisible to fixed-topology clustering approaches?

**RQ3:** Does Kronecker product expansion against identity matrices preserve the Echo State Property and downstream task performance when lifting compact reservoir weight matrices to match wider ANN hidden dimensions?

**RQ4:** Can block-diagonal gradient preconditioning, synchronized via signed-momentum macro-covariance scaling, improve convergence speed and stability during BPTT fine-tuning of block-structured reservoir-seeded ANNs, compared to standard first-order optimizers?

**RQ5:** Does the block-diagonal sparsity structure of the reservoir-seeded ANN reduce cross-platform numerical divergence (as measured by TAM) compared to fully-connected architectures?

### 3.2 Hypotheses

**H1 — Orthogonal Spectral Control.** Generating reservoir weight matrices as $\mathbf{W}_{\text{res}}^{(l)} = \rho_l \cdot \mathbf{Q}^{(l)}$, where $\mathbf{Q}^{(l)}$ is sampled uniformly from the orthogonal group $O(N_l)$ via the Haar measure, ensures that all eigenvalues of $\mathbf{W}_{\text{res}}^{(l)}$ lie exactly on the circle of radius $\rho_l$ in the complex plane. This eliminates eigenvalue spread as a source of mode-dependent energy decay in the recurrent dynamics. *Note:* This controls variance attributable to the recurrent weight eigenspectrum; the leaky integration parameter $\alpha_l$ introduces a separate, controlled exponential forgetting factor.

**H2 — Kronecker Spectral Preservation.** The dimensional mismatch between a compact reservoir layer ($N_l$) and a target ANN layer ($N_{\text{target}}$) can be resolved without violating the ESP by computing:
$$\mathbf{W}_{\text{ANN}}^{(l)} = \mathbf{W}_{\text{res}}^{(l)} \otimes \mathbf{I}_R, \quad R = \left\lfloor N_{\text{target}} / N_l \right\rfloor$$
Since $\text{spec}(\mathbf{A} \otimes \mathbf{I}_R) = \text{spec}(\mathbf{A})$ (each eigenvalue repeated $R$ times), we have $\rho(\mathbf{W}_{\text{ANN}}^{(l)}) = \rho_l$. When $N_l$ does not evenly divide $N_{\text{target}}$, the remaining $N_{\text{target}} - N_l \cdot R$ dimensions are initialized to zero, producing a zero-padded block that does not affect the spectral radius.

**H3 — Dual-Track NMI Divergence.** Computing the divergence $\Delta_{\text{NMI}}^{(l)} = |\text{NMI}_{\text{headless}}^{(l)} - \text{NMI}_{\text{physical}}^{(l)}|$ between unsupervised and supervised clustering tracks identifies reservoir blocks that capture latent physical structure not reflected in human-defined labels. Blocks exhibiting high $\Delta_{\text{NMI}}$ alongside high silhouette confidence signal the presence of physically coherent manifold structure that warrants further investigation.

**H4 — Plant-Adaptive Topological Inference.** Replacing finite Gaussian Mixture Models (GMMs) with Variational Bayesian Dirichlet Process GMMs (DPGMMs) allows the clustering engine to autonomously infer the number of active modes in the reservoir state manifold by suppressing unnecessary mixture components via the Dirichlet Process prior, eliminating the need for manual specification of cluster counts.

**H5 — Block-Diagonal Gradient Preconditioning.** The architecturally imposed block-diagonal structure of the hidden weight matrix induces a corresponding block-diagonal structure in the gradient tensor $\mathbf{G}_{hh}$. Constructing localized empirical covariance matrices from mini-batch gradient statistics within each block enables efficient curvature-aware preconditioning at $\mathcal{O}(N_l^3)$ per block, avoiding the $\mathcal{O}(N^3)$ cost of global preconditioning.

**H6 — Signed-Momentum Synchronization.** Projecting block-level gradient updates to signed scalar norms (Frobenius norm $\times$ sign of alignment with an exponential moving average momentum buffer) and constructing a $K \times K$ macro-covariance matrix from these scalars enables detection of destructive inter-block gradient interference. Applying multiplicative scaling factors derived from the inverse macro-covariance matrix synchronizes the effective learning rates across blocks during large transients.

---

## 4. Proposed Architecture

The proposed pipeline consists of four sequential stages: Orthogonal Initialization, Plant-Adaptive Information Auditing, Kronecker Basis Expansion, and Block-Diagonal Gradient Preconditioning.

```
┌──────────────────────────────────────────────────────────────────────┐
│ STAGE 1: ORTHOGONAL INITIALIZATION                                   │
│ Sample Q ~ Haar(O(N_l)) via QR + diagonal correction                │
│ Scale: W_res = ρ_l · Q    Instantiate parallel filter bank           │
├──────────────────────────────────────────────────────────────────────┤
│ STAGE 2: PLANT-ADAPTIVE DUAL-TRACK NMI AUDITING                     │
│ Stream input → Extract states X_l → Cluster via GMM/DPGMM/K-Means  │
│ Compute NMI_headless, NMI_physical → Log Δ_NMI, Silhouette         │
│ Cull blocks with NMI < threshold                                     │
├──────────────────────────────────────────────────────────────────────┤
│ STAGE 3: KRONECKER BASIS EXPANSION                                   │
│ For surviving blocks: W_ANN = W_res ⊗ I_R                           │
│ Assemble sparse block-diagonal prior → Seed target ANN              │
├──────────────────────────────────────────────────────────────────────┤
│ STAGE 4: BLOCK-DIAGONAL GRADIENT PRECONDITIONING                     │
│ BPTT backward pass → Extract block sub-gradients                    │
│ Compute local empirical covariance from mini-batch → Precondition   │
│ Compute signed-momentum scalars → Invert K×K macro-covariance      │
│ Apply multiplicative block scaling via structural mask               │
└──────────────────────────────────────────────────────────────────────┘
```

### 4.1 Stage 1: Haar-Corrected Orthogonal Reservoir Generation

For each parallel reservoir layer $l \in \{1, \ldots, K\}$, we generate the recurrent weight matrix $\mathbf{W}_{\text{res}}^{(l)} \in \mathbb{R}^{N_l \times N_l}$ using a Haar-distributed random orthogonal matrix.

**Procedure:**

1. Draw $\mathbf{M} \in \mathbb{R}^{N_l \times N_l}$ with entries $M_{ij} \sim \mathcal{N}(0, 1)$.
2. Compute the QR decomposition: $\mathbf{M} = \mathbf{Q}\mathbf{R}$.
3. Apply the diagonal correction of Stewart [28] and Mezzadri [13]:
$$\mathbf{Q}_{\text{Haar}} = \mathbf{Q} \cdot \text{diag}\left(\text{sign}(R_{11}), \text{sign}(R_{22}), \ldots, \text{sign}(R_{N_l N_l})\right)$$
4. Scale to the target spectral radius:
$$\mathbf{W}_{\text{res}}^{(l)} = \rho_l \cdot \mathbf{Q}_{\text{Haar}}$$

**Properties:**
- $\mathbf{Q}_{\text{Haar}}$ is uniformly distributed on $O(N_l)$ under the Haar measure [13].
- All eigenvalues of $\mathbf{W}_{\text{res}}^{(l)}$ lie on the circle $\{z \in \mathbb{C} : |z| = \rho_l\}$.
- The Echo State Property is satisfied for $\rho_l < 1$.
- The eigenvalue distribution is free of the bias that arises from uncorrected QR decomposition.

The input weight matrix $\mathbf{W}_{\text{in}}^{(l)} \in \mathbb{R}^{N_l \times d_{\text{in}}}$ is drawn from $\text{Uniform}(-0.5, 0.5)$, which is standard practice for ESNs [1].

### 4.2 Stage 2: Plant-Adaptive Dual-Track NMI Auditing

During the evaluation pass, raw input sequences $\mathbf{u}(t) \in \mathbb{R}^{d_{\text{in}}}$ for $t = 1, \ldots, T$ are driven through each reservoir block via the leaky-integrator update:

$$\mathbf{x}^{(l)}(t) = (1 - \alpha_l) \mathbf{x}^{(l)}(t-1) + \alpha_l \cdot \sigma_l\!\left(\mathbf{W}_{\text{in}}^{(l)} \mathbf{u}(t) + \mathbf{W}_{\text{res}}^{(l)} \mathbf{x}^{(l)}(t-1)\right)$$

where $\alpha_l \in (0, 1]$ is the leaking rate and $\sigma_l$ is the element-wise activation function (tanh, sin, or GELU) for layer $l$.

The collected state matrix $\mathbf{X}^{(l)} \in \mathbb{R}^{T \times N_l}$ is then clustered using a configurable plant-adaptive engine:

- **Finite GMM** ($M$ components, EM algorithm): Appropriate when the number of dynamical regimes is known a priori.
- **DPGMM** ($M$ as upper bound, Variational Dirichlet Process): Uses a stick-breaking prior to automatically suppress unnecessary components, appropriate for systems with unknown or continuously varying topological complexity.
- **K-Means** ($M$ clusters, Voronoi partitioning): Appropriate for piecewise-switching systems with crisp regime boundaries.

The clustering assigns tokens $U^{(l)}(t)$ to each time step. Two NMI scores are computed:

$$\text{NMI}_{\text{headless}}^{(l)} = \frac{I(U^{(l)};\, V_{\text{unsup}})}{\sqrt{H(U^{(l)}) \cdot H(V_{\text{unsup}})}}, \qquad \text{NMI}_{\text{physical}}^{(l)} = \frac{I(U^{(l)};\, V_{\text{phys}})}{\sqrt{H(U^{(l)}) \cdot H(V_{\text{phys}})}}$$

where $V_{\text{unsup}}(t)$ is a data-driven target token track generated by clustering the raw input and $V_{\text{phys}}(t)$ is the ground-truth physical label track (e.g., dynamical regime labels).

The **Information Delta** is defined as:
$$\Delta_{\text{NMI}}^{(l)} = \left|\text{NMI}_{\text{headless}}^{(l)} - \text{NMI}_{\text{physical}}^{(l)}\right|$$

**Statistical characterization.** To assess whether an observed $\Delta_{\text{NMI}}$ is significant, we apply a permutation test: the physical label vector $V_{\text{phys}}$ is randomly permuted $B$ times (default $B = 500$), the NMI is recomputed for each permutation, and a p-value is obtained as the fraction of permuted deltas exceeding the observed delta. This provides a non-parametric significance threshold without distributional assumptions.

A **Structural Anomaly Warning** is logged when $\Delta_{\text{NMI}}^{(l)}$ is significant (p < 0.05) and the Silhouette Confidence $S^{(l)}$ exceeds a minimum threshold (default 0.3), indicating that the reservoir block has captured a coherent manifold structure that diverges from human-defined labels.

Blocks with $\text{NMI}_{\text{headless}}^{(l)} < \tau_l$ are culled (marked inactive). Surviving blocks proceed to Stage 3.

### 4.3 Stage 3: Kronecker Basis Expansion

Surviving reservoir blocks represent isolated, spectrally calibrated timescale filters operating in compact $N_l$-dimensional spaces. To map these into a shared $N_{\text{target}}$-dimensional ANN hidden layer, we compute:

$$\mathbf{W}_{\text{ANN}}^{(l)} = \mathbf{W}_{\text{res}}^{(l)} \otimes \mathbf{I}_R, \quad R = \left\lfloor N_{\text{target}} / N_l \right\rfloor$$

**Spectral preservation proof.** By the mixed-product property of Kronecker products [27]:
$$\text{spec}\!\left(\mathbf{W}_{\text{res}}^{(l)} \otimes \mathbf{I}_R\right) = \left\{\lambda_i \cdot \mu_j : \lambda_i \in \text{spec}(\mathbf{W}_{\text{res}}^{(l)}),\; \mu_j \in \text{spec}(\mathbf{I}_R)\right\}$$
Since all eigenvalues of $\mathbf{I}_R$ equal 1, we have $\text{spec}(\mathbf{W}_{\text{ANN}}^{(l)}) = \text{spec}(\mathbf{W}_{\text{res}}^{(l)})$, each with multiplicity $R$. Therefore $\rho(\mathbf{W}_{\text{ANN}}^{(l)}) = \rho_l$.

**Handling non-divisible dimensions.** When $N_l \nmid N_{\text{target}}$, the Kronecker product yields a matrix of dimension $N_l R \times N_l R < N_{\text{target}} \times N_{\text{target}}$. The remaining $N_{\text{target}} - N_l R$ rows and columns are zero-initialized. Since appending zero rows/columns to a matrix does not change its nonzero eigenvalues, the spectral radius is preserved. The zero-initialized subspace provides additional learnable capacity during subsequent BPTT fine-tuning.

**Input weight expansion.** The input matrix is expanded via:
$$\mathbf{W}_{\text{in,ANN}}^{(l)} = \mathbf{W}_{\text{in}}^{(l)} \otimes \mathbf{1}_{R \times 1}$$
This replicates each input weight $R$ times. We note that this produces a rank-deficient input projection (rank at most $N_l \cdot d_{\text{in}}$), which constrains the initial expressiveness of the expanded network. The subsequent BPTT fine-tuning phase is expected to break this rank degeneracy by specializing the replicated weights.

### 4.4 Stage 4: Block-Diagonal Gradient Preconditioning with Signed-Momentum Synchronization

During BPTT fine-tuning of the reservoir-seeded ANN, the global gradient matrix $\mathbf{G}_{hh} \in \mathbb{R}^{N \times N}$ is intercepted via a custom backward hook. The block-diagonal structure inherited from the parallel filter bank is exploited in two passes.

#### Pass 1: Localized Empirical Covariance Preconditioning

For each active block $l$, the sub-block gradient $\mathbf{G}_{hh}^{(l)} \in \mathbb{R}^{N_l \times N_l}$ is extracted via the structural mask. To construct a meaningful empirical covariance estimate, we accumulate gradient statistics across a mini-batch of $B$ samples:

$$\bar{\mathbf{g}}^{(l)} = \frac{1}{B} \sum_{b=1}^{B} \text{vec}\!\left(\mathbf{G}_{hh,b}^{(l)}\right), \qquad \mathbf{C}^{(l)} = \frac{1}{B-1} \sum_{b=1}^{B} \left(\text{vec}(\mathbf{G}_{hh,b}^{(l)}) - \bar{\mathbf{g}}^{(l)}\right)\left(\text{vec}(\mathbf{G}_{hh,b}^{(l)}) - \bar{\mathbf{g}}^{(l)}\right)^\top$$

In practice, constructing the full $N_l^2 \times N_l^2$ covariance is prohibitive. We adopt a structured approximation: following the K-FAC intuition [21], we approximate the covariance using the *row-wise* covariance of the gradient matrix:

$$\mathbf{C}_{\text{row}}^{(l)} = \frac{1}{B \cdot N_l - 1} \sum_{b=1}^{B} \left(\mathbf{G}_{hh,b}^{(l)} - \bar{\mathbf{G}}_{hh}^{(l)}\right)\left(\mathbf{G}_{hh,b}^{(l)} - \bar{\mathbf{G}}_{hh}^{(l)}\right)^\top \in \mathbb{R}^{N_l \times N_l}$$

where $\bar{\mathbf{G}}_{hh}^{(l)} = \frac{1}{B} \sum_b \mathbf{G}_{hh,b}^{(l)}$ is the mean gradient matrix across the mini-batch.

The preconditioned gradient is then:
$$\tilde{\mathbf{G}}_{hh}^{(l)} = \left(\mathbf{C}_{\text{row}}^{(l)} + \epsilon \mathbf{I}\right)^{-1} \mathbf{G}_{hh}^{(l)}$$

where $\epsilon > 0$ is a damping parameter (default $10^{-4}$) ensuring invertibility.

> **Remark.** This is an *empirical gradient covariance preconditioner*, not a natural gradient update. The true natural gradient requires the Fisher Information Matrix $\mathbf{F} = \mathbb{E}[\nabla \log p \cdot \nabla \log p^\top]$, which involves expectations over the model's predictive distribution. Our preconditioner uses the empirical covariance of the loss gradients across mini-batch samples, which is a related but distinct quantity. We adopt the terminology "gradient preconditioning" throughout to avoid conflation with the information-geometric natural gradient of Amari [20].

**Computational cost.** For each block, the row-wise covariance is $\mathcal{O}(B \cdot N_l^2)$ and the matrix inversion (via Cholesky decomposition) is $\mathcal{O}(N_l^3)$. With $K$ blocks, the total cost is $\mathcal{O}(K \cdot (B \cdot N_l^2 + N_l^3))$, compared to $\mathcal{O}(N^3)$ for global preconditioning where $N = \sum_l N_l$.

#### Pass 2: Signed-Momentum Macro-Covariance Synchronization

While Pass 1 operates within each block independently, Pass 2 provides global coordination. For each active block $l$, a signed scalar summary is computed:

$$s^{(l)} = \left\|\mathbf{G}_{hh}^{(l)}\right\|_F \cdot \text{sign}\!\left(\left\langle \mathbf{G}_{hh}^{(l)},\, \mathbf{M}^{(l)} \right\rangle_F\right)$$

where $\langle \cdot, \cdot \rangle_F$ denotes the Frobenius inner product (i.e., $\text{Tr}(\mathbf{A}^\top \mathbf{B})$) and $\mathbf{M}^{(l)}$ is an exponential moving average (EMA) momentum buffer:

$$\mathbf{M}^{(l)} \leftarrow \beta \mathbf{M}^{(l)} + (1 - \beta) \mathbf{G}_{hh}^{(l)}, \quad \beta \in [0, 1)$$

The signed scalars $\mathbf{s} = [s^{(1)}, \ldots, s^{(K)}]^\top$ are accumulated over a sliding window of $W$ optimization steps (default $W = 20$). The macro-covariance matrix is computed from this history:

$$\boldsymbol{\Sigma}_{\text{macro}} = \frac{1}{W - 1} \sum_{w=1}^{W} (\mathbf{s}_w - \bar{\mathbf{s}})(\mathbf{s}_w - \bar{\mathbf{s}})^\top \in \mathbb{R}^{K \times K}$$

The scaling vector $\boldsymbol{\gamma}$ is computed as:
$$\boldsymbol{\gamma} = \frac{\boldsymbol{\Sigma}_{\text{macro}}^{-1} \mathbf{1}}{\mathbf{1}^\top \boldsymbol{\Sigma}_{\text{macro}}^{-1} \mathbf{1}}$$

This is the minimum-variance portfolio weighting [29], normalized to sum to 1. The intuition is that blocks whose gradient magnitudes are highly correlated with other blocks (indicating constructive alignment) receive standard weighting, while blocks exhibiting high independent volatility (indicating potential interference) are down-weighted.

The final gradient is assembled via **multiplicative** scaling:
$$\mathbf{G}_{hh}^{(l)} \leftarrow \gamma_l \cdot \tilde{\mathbf{G}}_{hh}^{(l)}$$

The scaled sub-blocks are written back into the global gradient tensor and passed through the binary structural mask $\mathbf{M}_{\text{block}}$ to enforce block-diagonal sparsity:

$$\mathbf{G}_{hh} \leftarrow \mathbf{G}_{hh} \odot \mathbf{M}_{\text{block}}$$

---

## 5. Evaluation Environment

### 5.1 Benchmark Systems

The proposed pipeline will be evaluated on three benchmark systems of increasing dynamical complexity:

**System A — Lorenz-63 Attractor.** A continuous chaotic system with three coupled ODEs:
$$\dot{x} = \sigma(y - x), \quad \dot{y} = x(\rho - z) - y, \quad \dot{z} = xy - \beta z$$
with standard parameters $\sigma = 10$, $\rho = 28$, $\beta = 8/3$. This system has a positive Lyapunov exponent ($\lambda_1 \approx 0.91$), making it sensitive to initial conditions and numerical precision. The task is multi-step ahead prediction of the three state variables.

**System B — Wiener-Hammerstein Benchmark.** A piecewise nonlinear system identification task from the nonlinear system identification benchmark repository [30]. This system has discrete operating regimes with abrupt transitions, representing the opposite end of the dynamical spectrum from the continuous Lorenz attractor.

**System C — Non-Autonomous Point-Reactor Kinetics with Thermal-Hydraulic Feedback.** We introduce a nuclear reactor simulation as a stress test for multi-timescale dynamical modeling. The system consists of three coupled differential equations governing reactor power $P(t)$, delayed neutron precursor concentration $C(t)$, and fuel temperature $T(t)$:

$$\frac{dP}{dt} = \frac{\rho(t) - \beta}{\Lambda} P(t) + \lambda C(t)$$

$$\frac{dC}{dt} = \frac{\beta}{\Lambda} P(t) - \lambda C(t)$$

$$\frac{dT}{dt} = \frac{P(t)}{m c_p} - \frac{h A}{m c_p}\left(T(t) - T_{\text{coolant}}\right)$$

where the total reactivity $\rho(t)$ includes a time-varying external reactivity insertion $\rho_0(t)$ and a negative temperature feedback term:

$$\rho(t) = \rho_0(t) + \alpha_T (T_{\text{ref}} - T(t))$$

| Symbol | Description | Typical Value |
|--------|-------------|---------------|
| $\beta$ | Delayed neutron fraction | $6.5 \times 10^{-3}$ |
| $\Lambda$ | Prompt neutron generation time | $10^{-4}$ s |
| $\lambda$ | Precursor decay constant | $0.077$ s$^{-1}$ |
| $\alpha_T$ | Temperature reactivity coefficient | $-3.0 \times 10^{-5}$ K$^{-1}$ |
| $m c_p$ | Fuel heat capacity | $5.0 \times 10^{4}$ J/K |
| $h A$ | Heat transfer coefficient × area | $2.0 \times 10^{3}$ W/K |
| $T_{\text{coolant}}$ | Coolant temperature | 573 K |
| $T_{\text{ref}}$ | Reference temperature | 573 K |

The external reactivity $\rho_0(t)$ is modeled as a slowly drifting sinusoidal with additive noise, simulating realistic operational transients:
$$\rho_0(t) = A \sin(2\pi f t) + \xi(t), \quad \xi(t) \sim \mathcal{N}(0, \sigma_\xi^2)$$

This system exhibits multiple timescales: fast prompt neutron dynamics ($\sim \Lambda$), intermediate precursor kinetics ($\sim 1/\lambda$), and slow thermal feedback ($\sim m c_p / hA$), making it an ideal stress test for the multi-timescale parallel filter bank architecture.

### 5.2 Trajectory Alignment Metric (TAM)

To quantify cross-platform numerical divergence, we define the Trajectory Alignment Metric:

$$\text{TAM}(t) = \frac{1}{N} \left\|\mathbf{h}_{\text{CPU}}(t) - \mathbf{h}_{\text{GPU}}(t)\right\|_2^2$$

where $\mathbf{h}_{\text{CPU}}(t)$ and $\mathbf{h}_{\text{GPU}}(t)$ are the hidden state vectors at time $t$ produced by identical seeds executed on CPU (with AVX-512) and GPU (CUDA Tensor Cores) respectively. We also report the cumulative TAM:

$$\overline{\text{TAM}} = \frac{1}{T} \sum_{t=1}^{T} \text{TAM}(t)$$

**Hypothesis.** The block-diagonal sparsity mask prevents cross-contamination of floating-point rounding errors between blocks, yielding strictly lower $\overline{\text{TAM}}$ compared to a fully-connected architecture of equal parameter count.

---

## 6. Experimental Design

### 6.1 Baselines

The following baseline configurations will be used for controlled comparison:

| ID | Configuration | Purpose |
|----|--------------|---------|
| B1 | Standard ESN (random Gaussian init, ridge regression readout) | Classical RC baseline |
| B2 | Orthogonal ESN (Haar-corrected init, ridge regression readout) | Ablation: Stage 1 only |
| B3 | LSTM (equivalent parameter count, Adam optimizer) | Fully-trained RNN baseline |
| B4 | GRU (equivalent parameter count, Adam optimizer) | Fully-trained RNN baseline |
| B5 | Proposed pipeline with Adam optimizer (no preconditioning) | Ablation: Stages 1-3 only |
| B6 | Proposed pipeline with K-FAC [21] | Comparison with established second-order method |
| B7 | Proposed pipeline with uncorrected QR (no Haar correction) | Ablation: Haar correction value |

### 6.2 Ablation Study Design

To isolate the contribution of each pipeline stage, we conduct a factorial ablation across four binary factors:

| Factor | On | Off |
|--------|-----|------|
| F1: Haar Orthogonal Init | Haar-corrected QR | Random Gaussian |
| F2: Plant-Adaptive Clustering | DPGMM | Fixed GMM (K=4) |
| F3: Kronecker Expansion | $\mathbf{W}_{\text{res}} \otimes \mathbf{I}_R$ | Zero-padded scaling |
| F4: Block Preconditioning | Empirical covariance + signed-momentum | Standard SGD |

This produces $2^4 = 16$ configurations. Each is evaluated on all three benchmark systems with 10 random seeds, yielding $16 \times 3 \times 10 = 480$ experimental runs. We report:

- **Prediction accuracy:** Normalized Root Mean Squared Error (NRMSE) on held-out test sequences.
- **Convergence speed:** Number of BPTT epochs to reach 95% of best-achieved NRMSE.
- **Run-to-run variance:** Standard deviation of NRMSE across random seeds.
- **NMI quality:** Dual-track NMI scores during the scout pass.
- **TAM:** Cross-platform divergence metric at epoch 0, 10, 50, and 100.

### 6.3 Statistical Analysis

All comparisons will use a paired Wilcoxon signed-rank test (non-parametric, appropriate for the expected sample sizes). Effect sizes will be reported using Cliff's delta. Significance is assessed at $\alpha = 0.05$ with Bonferroni correction for multiple comparisons.

### 6.4 Computational Resources

Experiments will be executed on:
- **CPU:** Intel Xeon with AVX-512 support (for TAM reference trajectory)
- **GPU:** NVIDIA A100 (40GB) with CUDA 12.x and cuDNN 8.x
- **Software:** Python 3.11, PyTorch 2.x, NumPy 1.26+, SciPy 1.12+, scikit-learn 1.4+

All experiments will use `torch.use_deterministic_algorithms(True)` with fixed random seeds for reproducibility within each platform.

---

## 7. Scope Boundaries

### 7.1 In Scope

- Haar-corrected orthogonal recurrent initialization via QR decomposition.
- Kronecker product basis expansions for spectral-preserving dimensional lifting.
- Plant-adaptive clustering (GMM, DPGMM, K-Means) within the scout pass.
- Integration of the PRKE benchmark system.
- Dual-track NMI auditing with permutation-based significance testing.
- Block-diagonal gradient preconditioning with signed-momentum synchronization.
- Multi-device execution with deterministic seeding (CPU and CUDA GPU).
- Namespace unification under a polymorphic inheritance tree rooted in `BaseReservoir(ABC)`.
- Full tensor vectorization of static input projections outside the time loop.

### 7.2 Out of Scope

- Non-square semi-orthogonal subspace projections (rejected due to eigenvalue deformation; see Problem 2).
- Full Fisher Information Matrix computation (intractable at scale; we use empirical gradient covariance instead).
- Complex-valued (unitary) reservoir weights (reserved for future work).
- Online/streaming learning (all experiments use batch training).

---

## 8. Reference Implementation

The core implementation class is provided below with all mathematical corrections applied.

```python
# Save as: src/unity_of_one/auto_ml/models/parallel_orthogonal_initializer.py

import numpy as np
import torch
from sklearn.base import BaseEstimator, TransformerMixin
from sklearn.mixture import GaussianMixture, BayesianGaussianMixture
from sklearn.cluster import KMeans
from sklearn.metrics import normalized_mutual_info_score, silhouette_score
from scipy.linalg import qr


class ParallelOrthogonalFilterBankPriorInitializer(BaseEstimator, TransformerMixin):
    """
    V4 Parallel Stateful Filter-Bank ESN Weight Prior Engine.

    Implements:
      - Haar-corrected random orthogonal matrices (Stage 1)
      - Plant-adaptive Dirichlet Process clustering with dual-track NMI (Stage 2)
      - Kronecker basis expansion with spectral preservation (Stage 3)
      - Block-diagonal gradient preconditioning with signed-momentum
        macro-covariance synchronization (Stage 4)

    Parameters
    ----------
    layer_neurons : tuple of int
        Number of neurons in each parallel reservoir block.
    layer_activations : tuple of str
        Activation function for each block ('tanh', 'sin', 'gelu').
    spectral_radii : tuple of float
        Target spectral radius for each block. Must satisfy rho < 1 for ESP.
    leaking_rates : tuple of float
        Leaky integrator rate for each block. alpha=1.0 gives no leaking.
    sparsities : tuple of float
        Reserved for future use (structured sparsity within blocks).
    gmm_components : tuple of int
        Number of mixture components (or upper bound for DPGMM) per block.
    nmi_thresholds : tuple of float
        Minimum NMI_headless required for a block to survive the scout pass.
    target_ann_dimension : int
        Target hidden dimension of the downstream ANN.
    device_target : str
        Compute backend: 'cuda' or 'cpu'.
    enforce_determinism : bool
        If True, enables deterministic execution flags in PyTorch.
    scout_distribution_mode : str
        Clustering algorithm: 'bgmm' (DPGMM), 'gmm', or 'kmeans'.
    eps : float
        Damping parameter for matrix inversion stability.
    momentum_beta : float
        EMA decay rate for the signed-momentum buffer.
    nmi_permutation_tests : int
        Number of permutations for the NMI delta significance test.
    random_state : int
        Random seed for reproducibility.
    """

    def __init__(
        self,
        layer_neurons: tuple = (128, 128, 128),
        layer_activations: tuple = ('sin', 'gelu', 'tanh'),
        spectral_radii: tuple = (0.35, 0.75, 0.98),
        leaking_rates: tuple = (1.0, 0.5, 0.02),
        sparsities: tuple = (0.0, 0.0, 0.0),
        gmm_components: tuple = (4, 4, 4),
        nmi_thresholds: tuple = (0.05, 0.05, 0.05),
        target_ann_dimension: int = 1024,
        device_target: str = 'cuda',
        enforce_determinism: bool = True,
        scout_distribution_mode: str = 'bgmm',
        eps: float = 1e-4,
        momentum_beta: float = 0.9,
        nmi_permutation_tests: int = 500,
        random_state: int = 42,
    ):
        self.layer_neurons = layer_neurons
        self.layer_activations = layer_activations
        self.spectral_radii = spectral_radii
        self.leaking_rates = leaking_rates
        self.sparsities = sparsities
        self.gmm_components = gmm_components
        self.nmi_thresholds = nmi_thresholds
        self.target_ann_dimension = target_ann_dimension
        self.device_target = device_target
        self.enforce_determinism = enforce_determinism
        self.scout_distribution_mode = scout_distribution_mode
        self.eps = eps
        self.momentum_beta = momentum_beta
        self.nmi_permutation_tests = nmi_permutation_tests
        self.random_state = random_state

        self.W_in_registry: list[np.ndarray] = []
        self.W_res_registry: list[np.ndarray] = []
        self.active_layers_mask: list[bool] = []
        self.dual_track_logs_: dict = {}

        # State trackers for the macro-covariance synchronization hook
        self.block_momenta: dict[int, torch.Tensor] = {}
        self.macro_gradient_history: list[list[float]] = []

    # ------------------------------------------------------------------
    # Hardware Configuration
    # ------------------------------------------------------------------

    def _configure_hardware_environment(self) -> None:
        """Configure deterministic execution across CPU and GPU backends."""
        if self.enforce_determinism:
            torch.manual_seed(self.random_state)
            torch.use_deterministic_algorithms(True)
            if torch.cuda.is_available():
                torch.cuda.manual_seed_all(self.random_state)
                torch.backends.cudnn.deterministic = True
                torch.backends.cudnn.benchmark = False

    # ------------------------------------------------------------------
    # Stage 1: Haar-Corrected Orthogonal Matrix Generation
    # ------------------------------------------------------------------

    @staticmethod
    def _generate_haar_orthogonal(n: int, rng: np.random.Generator) -> np.ndarray:
        """
        Generate a Haar-distributed random orthogonal matrix of size n x n.

        Applies the Stewart/Mezzadri diagonal correction to the Q factor
        of a QR decomposition of a random Gaussian matrix, ensuring uniform
        distribution on O(n) under the Haar measure.

        References
        ----------
        [13] F. Mezzadri, "How to Generate Random Matrices from the Classical
             Compact Groups," Notices of the AMS, 54(5), 592-604, 2007.
        """
        M = rng.normal(0.0, 1.0, (n, n))
        Q, R = qr(M)
        # Stewart/Mezzadri correction: multiply columns of Q by sign(diag(R))
        d = np.sign(np.diag(R))
        d[d == 0] = 1  # Handle exact zeros (probability zero, but defensive)
        Q_haar = Q * d  # Broadcasting: scales each column of Q
        return Q_haar

    # ------------------------------------------------------------------
    # Stage 2: Scout Decomposition with Dual-Track NMI
    # ------------------------------------------------------------------

    def fit_scout_decomposition(
        self,
        X_telemetry: np.ndarray,
        v_unsupervised: np.ndarray,
        v_physical: np.ndarray,
    ) -> "ParallelOrthogonalFilterBankPriorInitializer":
        """
        Execute the filter bank streaming pass and dual-track NMI auditing.

        Parameters
        ----------
        X_telemetry : ndarray of shape (T, d_in)
            Input time series data.
        v_unsupervised : ndarray of shape (T,)
            Data-driven unsupervised target token track.
        v_physical : ndarray of shape (T,)
            Ground-truth physical label track.

        Returns
        -------
        self
            Fitted instance with populated dual_track_logs_ and active_layers_mask.
        """
        self._configure_hardware_environment()
        rng = np.random.default_rng(self.random_state)
        T, d_in = X_telemetry.shape
        U_driver = X_telemetry

        device = torch.device(
            self.device_target
            if (self.device_target == 'cuda' and torch.cuda.is_available())
            else 'cpu'
        )

        K_layers = len(self.layer_neurons)
        self.W_in_registry = []
        self.W_res_registry = []
        self.active_layers_mask = []
        self.dual_track_logs_ = {}

        for l in range(K_layers):
            N_l = self.layer_neurons[l]
            rho_l = self.spectral_radii[l]
            alpha_l = self.leaking_rates[l]
            act_l = self.layer_activations[l]
            tau_l = self.nmi_thresholds[l]
            M_l = self.gmm_components[l]

            # Stage 1: Haar-corrected orthogonal initialization
            Q_haar = self._generate_haar_orthogonal(N_l, rng)
            W_res = Q_haar * rho_l
            W_in = rng.uniform(-0.5, 0.5, (N_l, d_in))

            self.W_in_registry.append(W_in)
            self.W_res_registry.append(W_res)

            # Transfer to compute device
            W_res_t = torch.tensor(W_res, dtype=torch.float32, device=device)
            U_driver_t = torch.tensor(U_driver, dtype=torch.float32, device=device)
            W_in_t = torch.tensor(W_in, dtype=torch.float32, device=device)

            # Vectorized input projection (computed once outside the time loop)
            U_proj_t = torch.mm(U_driver_t, W_in_t.T)

            # Reservoir state collection
            X_layer_t = torch.zeros((T, N_l), dtype=torch.float32, device=device)
            x_state_t = torch.zeros((1, N_l), dtype=torch.float32, device=device)

            for t in range(T):
                net_input = U_proj_t[t:t+1, :] + torch.mm(x_state_t, W_res_t.T)

                if act_l == 'tanh':
                    innovation = torch.tanh(net_input)
                elif act_l == 'sin':
                    innovation = torch.sin(net_input)
                else:
                    innovation = torch.nn.functional.gelu(net_input)

                x_state_t = (1.0 - alpha_l) * x_state_t + alpha_l * innovation
                X_layer_t[t:t+1, :] = x_state_t

            X_layer_cpu = X_layer_t.cpu().numpy()

            # Stage 2: Plant-adaptive clustering
            if self.scout_distribution_mode == 'bgmm':
                clusterer = BayesianGaussianMixture(
                    n_components=M_l,
                    covariance_type='diag',
                    weight_concentration_prior_type='dirichlet_process',
                    random_state=self.random_state,
                )
            elif self.scout_distribution_mode == 'kmeans':
                clusterer = KMeans(
                    n_clusters=M_l,
                    random_state=self.random_state,
                    n_init='auto',
                )
            else:
                clusterer = GaussianMixture(
                    n_components=M_l,
                    covariance_type='diag',
                    random_state=self.random_state,
                )

            u_clusters = clusterer.fit_predict(X_layer_cpu)
            n_unique = int(np.unique(u_clusters).size)

            # Silhouette score requires at least 2 clusters
            if n_unique > 1:
                s_confidence = silhouette_score(
                    X_layer_cpu, u_clusters, sample_size=min(T, 1000)
                )
            else:
                s_confidence = 0.0

            nmi_headless = normalized_mutual_info_score(u_clusters, v_unsupervised)
            nmi_physical = normalized_mutual_info_score(u_clusters, v_physical)
            delta_nmi = abs(nmi_headless - nmi_physical)

            # Permutation test for delta_NMI significance
            perm_rng = np.random.default_rng(self.random_state + l)
            perm_deltas = np.zeros(self.nmi_permutation_tests)
            for b in range(self.nmi_permutation_tests):
                v_phys_perm = perm_rng.permutation(v_physical)
                nmi_phys_perm = normalized_mutual_info_score(u_clusters, v_phys_perm)
                perm_deltas[b] = abs(nmi_headless - nmi_phys_perm)
            p_value = float(np.mean(perm_deltas >= delta_nmi))

            self.dual_track_logs_[f"layer_{l+1}"] = {
                "nmi_headless": nmi_headless,
                "nmi_physical": nmi_physical,
                "nmi_delta": delta_nmi,
                "nmi_delta_p_value": p_value,
                "silhouette_confidence": s_confidence,
                "components_found": n_unique,
                "structural_anomaly": (p_value < 0.05 and s_confidence > 0.3),
            }

            if nmi_headless < tau_l:
                self.active_layers_mask.append(False)
                continue

            self.active_layers_mask.append(True)

        return self

    # ------------------------------------------------------------------
    # Stage 4: Block-Diagonal Gradient Preconditioning
    # ------------------------------------------------------------------

    def condition_gradient_in_place(
        self,
        G_hh: torch.Tensor,
        block_masks: list[torch.Tensor],
        mini_batch_grads: list[torch.Tensor] | None = None,
    ) -> torch.Tensor:
        """
        Apply block-diagonal gradient preconditioning with signed-momentum
        macro-covariance synchronization.

        Parameters
        ----------
        G_hh : Tensor of shape (N, N)
            The global gradient matrix for the hidden-to-hidden weight.
        block_masks : list of Tensor
            Binary masks identifying each block's position in the global matrix.
        mini_batch_grads : list of Tensor or None
            If provided, a list of B gradient matrices from individual mini-batch
            samples, used to compute the empirical covariance preconditioner.
            If None, falls back to single-sample centering (less accurate).

        Returns
        -------
        G_hh : Tensor of shape (N, N)
            The preconditioned gradient matrix with block-diagonal sparsity enforced.
        """
        with torch.no_grad():
            signed_scalar_norms = []

            # Pass 1: Localized empirical covariance preconditioning
            for idx, mask in enumerate(block_masks):
                if idx >= len(self.active_layers_mask) or not self.active_layers_mask[idx]:
                    continue

                nz_rows = mask.any(dim=1)
                nz_cols = mask.any(dim=0)
                sub_block = G_hh[nz_rows][:, nz_cols]

                # --- Signed-momentum tracking ---
                if idx not in self.block_momenta:
                    self.block_momenta[idx] = torch.zeros_like(sub_block)

                M_historical = self.block_momenta[idx]

                # Frobenius inner product for directional alignment
                alignment_score = (sub_block * M_historical).sum()
                direction = torch.sign(alignment_score) if alignment_score != 0 else 1.0

                signed_norm = torch.norm(sub_block, p='fro') * direction
                signed_scalar_norms.append(signed_norm.item())

                # Update EMA momentum buffer
                self.block_momenta[idx] = (
                    self.momentum_beta * M_historical
                    + (1.0 - self.momentum_beta) * sub_block
                )

                # --- Empirical covariance preconditioning ---
                if mini_batch_grads is not None and len(mini_batch_grads) > 1:
                    # Extract sub-blocks from each mini-batch gradient
                    batch_sub_blocks = []
                    for g_b in mini_batch_grads:
                        batch_sub_blocks.append(g_b[nz_rows][:, nz_cols])
                    stacked = torch.stack(batch_sub_blocks, dim=0)  # (B, N_l, N_l)
                    mean_block = stacked.mean(dim=0)
                    centered = stacked - mean_block.unsqueeze(0)
                    # Row-wise covariance: (N_l, N_l)
                    C_row = torch.zeros(
                        sub_block.shape[0], sub_block.shape[0],
                        device=G_hh.device, dtype=G_hh.dtype
                    )
                    for b in range(len(mini_batch_grads)):
                        C_row += torch.mm(centered[b], centered[b].T)
                    C_row /= (len(mini_batch_grads) * sub_block.shape[1] - 1 + self.eps)
                else:
                    # Fallback: single-sample row covariance (less accurate)
                    centered_grads = sub_block - sub_block.mean(dim=1, keepdim=True)
                    C_row = torch.mm(centered_grads, centered_grads.T) / (
                        sub_block.shape[1] - 1 + self.eps
                    )

                # Precondition via Cholesky solve (more stable than explicit inverse)
                C_reg = C_row + torch.eye(
                    C_row.shape[0], device=G_hh.device
                ) * self.eps
                conditioned_sub_block = torch.linalg.solve(C_reg, sub_block)

                # Write back into the global gradient
                G_hh[nz_rows.unsqueeze(1) & nz_cols.unsqueeze(0)] = (
                    conditioned_sub_block.ravel()
                )

            # Pass 2: Macro-covariance synchronization
            if len(signed_scalar_norms) > 1:
                self.macro_gradient_history.append(signed_scalar_norms)
                if len(self.macro_gradient_history) > 20:
                    self.macro_gradient_history.pop(0)

                if len(self.macro_gradient_history) > 5:
                    history_tensor = torch.tensor(
                        self.macro_gradient_history,
                        dtype=torch.float32,
                        device=G_hh.device,
                    )
                    centered_history = history_tensor - history_tensor.mean(
                        dim=0, keepdim=True
                    )
                    Sigma_macro = torch.mm(centered_history.T, centered_history) / (
                        history_tensor.shape[0] - 1 + self.eps
                    )

                    Sigma_reg = Sigma_macro + torch.eye(
                        Sigma_macro.shape[0], device=G_hh.device
                    ) * self.eps
                    ones_vec = torch.ones(
                        Sigma_macro.shape[0], device=G_hh.device
                    )
                    raw_gamma = torch.linalg.solve(Sigma_reg, ones_vec)
                    # Normalize to sum to 1 (minimum-variance portfolio weights)
                    gamma_scalars = raw_gamma / (raw_gamma.sum() + self.eps)

                    # Multiplicative scaling of each active block
                    active_idx = 0
                    for idx, mask in enumerate(block_masks):
                        if idx >= len(self.active_layers_mask) or not self.active_layers_mask[idx]:
                            continue
                        nz_rows = mask.any(dim=1)
                        nz_cols = mask.any(dim=0)
                        sub = G_hh[nz_rows][:, nz_cols]
                        G_hh[nz_rows.unsqueeze(1) & nz_cols.unsqueeze(0)] = (
                            (sub * gamma_scalars[active_idx]).ravel()
                        )
                        active_idx += 1

        return G_hh

    # ------------------------------------------------------------------
    # Stage 3: Kronecker Basis Expansion
    # ------------------------------------------------------------------

    def generate_preserved_ann_priors(self) -> list[dict]:
        """
        Apply Kronecker product expansions to lift compact reservoir weights
        to the target ANN dimension while preserving the eigenspectrum.

        Returns
        -------
        list of dict
            Each dict contains 'layer_index', 'W_in_prior', 'W_res_prior',
            and 'effective_dimension' for a surviving block.
        """
        K_layers = len(self.layer_neurons)
        ann_initialization_blueprint = []

        for l in range(K_layers):
            if not self.active_layers_mask[l]:
                continue

            N_l = self.layer_neurons[l]
            W_res_source = self.W_res_registry[l]
            W_in_source = self.W_in_registry[l]

            R_ratio = self.target_ann_dimension // N_l
            if R_ratio < 1:
                R_ratio = 1

            effective_dim = N_l * R_ratio
            remainder = self.target_ann_dimension - effective_dim

            # Kronecker expansion: W_res ⊗ I_R
            W_res_lifted = np.kron(W_res_source, np.eye(R_ratio))

            # Zero-pad if N_l does not evenly divide target dimension
            if remainder > 0:
                padded = np.zeros(
                    (self.target_ann_dimension, self.target_ann_dimension)
                )
                padded[:effective_dim, :effective_dim] = W_res_lifted
                W_res_lifted = padded

            # Input expansion: W_in ⊗ 1_{R×1}
            W_in_lifted = np.kron(W_in_source, np.ones((R_ratio, 1)))
            if remainder > 0:
                padded_in = np.zeros(
                    (self.target_ann_dimension, W_in_source.shape[1])
                )
                padded_in[:effective_dim, :] = W_in_lifted
                W_in_lifted = padded_in

            ann_initialization_blueprint.append({
                "layer_index": l + 1,
                "W_in_prior": W_in_lifted,
                "W_res_prior": W_res_lifted,
                "effective_dimension": effective_dim,
                "zero_padded_dimensions": remainder,
            })

        return ann_initialization_blueprint
```

---

## 9. Timeline and Milestones

| Phase | Duration | Activities | Deliverables |
|-------|----------|------------|-------------|
| **Phase 1: Foundation** | Months 1-4 | Literature review finalization, codebase architecture, Stage 1 & 3 implementation with unit tests | Working orthogonal init + Kronecker expansion module; literature review chapter |
| **Phase 2: Auditing** | Months 5-8 | Stage 2 implementation (DPGMM, dual-track NMI, permutation tests), Lorenz-63 and Wiener-Hammerstein experiments | Dual-track NMI module; preliminary results on Systems A and B |
| **Phase 3: Optimization** | Months 9-14 | Stage 4 implementation (gradient preconditioning, signed-momentum), PRKE simulator, full ablation study | Complete pipeline; ablation results across all systems |
| **Phase 4: Analysis** | Months 15-18 | TAM cross-platform experiments, statistical analysis, comparison with baselines | TAM analysis; complete experimental results |
| **Phase 5: Writing** | Months 19-24 | Dissertation writing, revisions, defense preparation | Dissertation document; defense |

### Publication Plan

- **Conference Paper 1** (Month 8): Haar-corrected orthogonal ESN initialization with Kronecker spectral-preserving expansion (Stages 1 + 3). Target: ICML or NeurIPS workshop on reservoir computing.
- **Conference Paper 2** (Month 14): Dual-track NMI auditing with plant-adaptive clustering for automated reservoir evaluation (Stage 2). Target: IJCNN or ESANN.
- **Journal Paper** (Month 18): Full pipeline with block-diagonal gradient preconditioning and signed-momentum synchronization (complete system). Target: Neural Networks or IEEE TNNLS.

---

## 10. Expected Contributions and Broader Impact

### 10.1 Expected Contributions

1. A principled method for spectral-preserving dimensional lifting of reservoir weights via Kronecker products, with a formal proof of eigenvalue preservation.
2. A plant-adaptive reservoir evaluation framework that automatically infers topological complexity and detects latent dynamical structure via dual-track information-theoretic auditing.
3. A block-diagonal gradient preconditioner that exploits architectural sparsity for efficient curvature-aware optimization of reservoir-seeded neural networks.
4. A cross-platform numerical reproducibility metric (TAM) for recurrent architectures operating on chaotic systems.
5. Empirical validation on a challenging non-autonomous nuclear reactor kinetics benchmark with multi-timescale thermal-hydraulic coupling.

### 10.2 Broader Impact

The proposed framework addresses a fundamental challenge in transferring knowledge from efficient-but-limited reservoir computers to expressive-but-expensive deep networks. If successful, this work could:

- **Reduce the computational cost** of training recurrent networks on multi-timescale dynamical systems by providing physically meaningful weight initializations that reduce the number of BPTT epochs required for convergence.
- **Improve scientific reproducibility** by providing tools (TAM, deterministic execution protocols) to detect and quantify cross-platform numerical divergence in recurrent network training.
- **Enable automated dynamical system characterization** through the dual-track NMI framework, which could be applied beyond reservoir computing to any unsupervised dynamical regime detection task.
- **Support nuclear engineering applications** by demonstrating the viability of structured recurrent architectures for reactor kinetics modeling, potentially contributing to real-time digital twin systems for reactor monitoring.

---

## References

[1] H. Jaeger, "The 'echo state' approach to analysing and training recurrent neural networks," GMD Technical Report 148, German National Research Center for Information Technology, 2001.

[2] M. Lukoševičius and H. Jaeger, "Reservoir computing approaches to recurrent neural network training," *Computer Science Review*, vol. 3, no. 3, pp. 127-149, 2009.

[3] W. Maass, T. Natschläger, and H. Markram, "Real-time computing without stable states: A new framework for neural computation based on perturbations," *Neural Computation*, vol. 14, no. 11, pp. 2531-2560, 2002.

[4] B. Schrauwen, D. Verstraeten, and J. Van Campenhout, "An overview of reservoir computing: theory, applications and implementations," in *Proc. European Symposium on Artificial Neural Networks*, 2007.

[5] C. Gallicchio, A. Micheli, and L. Pedrelli, "Deep reservoir computing: A critical experimental analysis," *Neurocomputing*, vol. 268, pp. 87-99, 2017.

[6] A. Rodan and P. Tiňo, "Minimum complexity echo state network," *IEEE Transactions on Neural Networks*, vol. 22, no. 1, pp. 131-144, 2011.

[7] L. Grigoryeva and J.-P. Ortega, "Echo state networks are universal," *Neural Networks*, vol. 108, pp. 495-508, 2018.

[8] I. B. Yildiz, H. Jaeger, and S. J. Kiebel, "Re-visiting the echo state property," *Neural Networks*, vol. 35, pp. 1-9, 2012.

[9] J. B. Butcher, D. Verstraeten, B. Schrauwen, C. R. Day, and P. W. Haycock, "Reservoir computing and extreme learning machines for non-linear time-series data analysis," *Neural Networks*, vol. 38, pp. 76-89, 2013.

[10] A. M. Saxe, J. L. McClelland, and S. Ganguli, "Exact solutions to the nonlinear dynamics of learning in deep linear neural networks," in *Proc. ICLR*, 2014.

[11] M. Henaff, A. Szlam, and Y. LeCun, "Recurrent orthogonal networks and long-memory tasks," in *Proc. ICML*, 2016.

[12] M. Arjovsky, A. Shah, and Y. Bengio, "Unitary evolution recurrent neural networks," in *Proc. ICML*, 2016.

[13] F. Mezzadri, "How to generate random matrices from the classical compact groups," *Notices of the AMS*, vol. 54, no. 5, pp. 592-604, 2007.

[14] A. Strehl and J. Ghosh, "Cluster ensembles — A knowledge reuse framework for combining multiple partitions," *Journal of Machine Learning Research*, vol. 3, pp. 583-617, 2002.

[15] D. Verstraeten, B. Schrauwen, M. D'Haene, and D. Stroobandt, "An experimental unification of reservoir computing methods," *Neural Networks*, vol. 20, no. 3, pp. 391-403, 2007.

[16] E. B. Fox, E. B. Sudderth, M. I. Jordan, and A. S. Willsky, "An HDP-HMM for systems with state persistence," in *Proc. ICML*, 2008.

[17] C. E. Rasmussen, "The infinite Gaussian mixture model," in *Proc. NeurIPS*, 2000.

[18] D. M. Blei and M. I. Jordan, "Variational inference for Dirichlet process mixtures," *Bayesian Analysis*, vol. 1, no. 1, pp. 121-143, 2006.

[19] F. Pedregosa et al., "Scikit-learn: Machine learning in Python," *Journal of Machine Learning Research*, vol. 12, pp. 2825-2830, 2011.

[20] S. Amari, "Natural gradient works efficiently in learning," *Neural Computation*, vol. 10, no. 2, pp. 251-276, 1998.

[21] J. Martens and R. Grosse, "Optimizing neural networks with Kronecker-factored approximate curvature," in *Proc. ICML*, 2015.

[22] T. George, C. Laurent, X. Bouthillier, N. Ballas, and P. Vincent, "Fast approximate natural gradient descent in a Kronecker-factored eigenbasis," in *Proc. NeurIPS*, 2018.

[23] V. Gupta, T. Koren, and Y. Singer, "Shampoo: Preconditioned stochastic tensor optimization," in *Proc. ICML*, 2018.

[24] J. Nocedal and S. J. Wright, *Numerical Optimization*, 2nd ed. Springer, 2006.

[25] T. N. Sainath, B. Kingsbury, V. Sindhwani, E. Arisoy, and B. Ramabhadran, "Low-rank matrix factorization for deep neural network training with high-dimensional output targets," in *Proc. ICASSP*, 2013.

[26] C. F. Van Loan, "The ubiquitous Kronecker product," *Journal of Computational and Applied Mathematics*, vol. 123, no. 1-2, pp. 85-100, 2000.

[27] R. A. Horn and C. R. Johnson, *Topics in Matrix Analysis*. Cambridge University Press, 1991.

[28] G. W. Stewart, "The efficient generation of random orthogonal matrices with an application to condition estimators," *SIAM Journal on Numerical Analysis*, vol. 17, no. 3, pp. 403-409, 1980.

[29] H. Markowitz, "Portfolio selection," *Journal of Finance*, vol. 7, no. 1, pp. 77-91, 1952.

[30] J. Schoukens, J. Suykens, and L. Ljung, "Wiener-Hammerstein benchmark," in *Proc. 15th IFAC Symposium on System Identification*, 2009.
