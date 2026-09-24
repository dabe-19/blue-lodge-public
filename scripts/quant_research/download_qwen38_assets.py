#!/usr/bin/env python3
"""
Production Asset Downloader for Frontier Qwen 3.8 27B Research:
Downloads:
  1. Real Refusal Dataset: slalberti/refusals-test (data.ndjson)
  2. Real Agentic Tool-Calling Dataset: NousResearch/hermes-function-calling-v1 (json-mode-agentic.json)
  3. MTP Drafter Module: unsloth/Qwen3.8-27B-GGUF (MTP/mtp-Qwen3.8-27B-Q4_0.gguf - 1.28 GB)
  4. Base Reference Model: unsloth/Qwen3.8-27B-GGUF (Qwen3.8-27B-Q8_0.gguf - 27.05 GB)
"""

import os
import sys
import time
from huggingface_hub import hf_hub_download

MODELS_DIR = "/home/wsl-ops/models/frontier_qwen38"
DATA_DIR = "/home/wsl-ops/blue-lodge/data"
os.makedirs(MODELS_DIR, exist_ok=True)
os.makedirs(f"{DATA_DIR}/refusal", exist_ok=True)
os.makedirs(f"{DATA_DIR}/agent_bench", exist_ok=True)

print("=" * 68)
print("  Acquiring Real Weights & Datasets for Qwen 3.8 Frontier Build")
print("=" * 68)

# ── 1. Acquire Real Contrastive Refusal Dataset ───────────────────────
print("\n[1/4] Downloading Real Refusal Dataset (slalberti/refusals-test)...")
refusal_file = hf_hub_download(
    repo_id="slalberti/refusals-test",
    filename="data.ndjson",
    repo_type="dataset",
    local_dir=f"{DATA_DIR}/refusal"
)
print(f"  ✓ Refusal dataset ready at {refusal_file} ({os.path.getsize(refusal_file)/1024:.1f} KB)")

# ── 2. Acquire Real Tool Calling / Agentic Dataset ─────────────────────
print("\n[2/4] Downloading Agentic Function Calling Dataset (NousResearch/hermes-function-calling-v1)...")
tool_file = hf_hub_download(
    repo_id="NousResearch/hermes-function-calling-v1",
    filename="json-mode-agentic.json",
    repo_type="dataset",
    local_dir=f"{DATA_DIR}/agent_bench"
)
print(f"  ✓ Agentic dataset ready at {tool_file} ({os.path.getsize(tool_file)/(1024**2):.2f} MB)")

# ── 3. Acquire Real MTP Layer GGUF (1.28 GB) ──────────────────────────
print("\n[3/4] Downloading Official MTP Drafter: unsloth/Qwen3.8-27B-GGUF (MTP/mtp-Qwen3.8-27B-Q4_0.gguf)...")
t0 = time.time()
mtp_file = hf_hub_download(
    repo_id="unsloth/Qwen3.8-27B-GGUF",
    filename="MTP/mtp-Qwen3.8-27B-Q4_0.gguf",
    local_dir=MODELS_DIR
)
print(f"  ✓ Downloaded MTP module in {time.time()-t0:.1f}s: {mtp_file} ({os.path.getsize(mtp_file)/(1024**2):.1f} MB)")

# ── 4. Acquire Real Base Reference Model: Qwen3.8-27B-Q8_0.gguf (27.05 GB) ─
print("\n[4/4] Starting Download of Base Qwen 3.8 Reference Model (27.05 GB)...")
print("  Source: unsloth/Qwen3.8-27B-GGUF / Qwen3.8-27B-Q8_0.gguf")
print("  Streaming file directly into /home/wsl-ops/models/frontier_qwen38/...")
t1 = time.time()
base_file = hf_hub_download(
    repo_id="unsloth/Qwen3.8-27B-GGUF",
    filename="Qwen3.8-27B-Q8_0.gguf",
    local_dir=MODELS_DIR
)
print(f"\n  ✓ BASE MODEL DOWNLOAD COMPLETED in {time.time()-t1:.1f}s!")
print(f"  File: {base_file}")
print(f"  Size: {os.path.getsize(base_file)/(1024**3):.2f} GB")
print("\n" + "=" * 68)
print("  ALL REAL WEIGHTS & DATASETS ACQUIRED SUCCESSFULLY!")
print("=" * 68)
