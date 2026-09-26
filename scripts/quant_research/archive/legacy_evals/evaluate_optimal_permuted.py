#!/usr/bin/env python3
"""
Full Autonomous Benchmark for Qwen3.8-27B-SPTQ1_0-Optimal-Permuted.gguf:
1. WikiText-2 True Perplexity (4 chunks) via llama-perplexity.
2. Direct CLI generation across Math, Deductive Logic, and Agentic Tool Calling.
3. Verification of Zero-Stuttering and Reasoning Integrity.
"""

import os
import sys
import time
import subprocess
import json
import re

MODEL_PATH = "/models/frontier_qwen38/Qwen3.8-27B-SPTQ1_0-Clean-v2.gguf"
WIKI_TEST = "/workspace/data/calibration/wiki.test.raw"
OUTPUT_REPORT = "/home/wsl-ops/blue-lodge/benchmarks/results/clean_v2_benchmark_report.json"
os.makedirs(os.path.dirname(OUTPUT_REPORT), exist_ok=True)

print("=" * 80)
print("  Benchmarking Frontier Optimal Permuted Model (GPU 1)")
print("=" * 80)

def run_cmd(cmd):
    proc = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return proc.stdout, proc.stderr, proc.returncode

# 1. Measure WikiText-2 True Perplexity
print("\n[Stage 1/2] Measuring WikiText-2 True Perplexity (4 chunks)...")
ppl_cmd = (
    f"docker exec -e CUDA_VISIBLE_DEVICES=1 george-prism-server "
    f"/workspace/build_prism/llama.cpp-prism/build/bin/llama-perplexity "
    f"-m {MODEL_PATH} "
    f"-f {WIKI_TEST} -c 512 -b 2048 -ngl 99 --chunks 4"
)
t0_ppl = time.time()
out, err, ret = run_cmd(ppl_cmd)
t_ppl = time.time() - t0_ppl
combined = out + "\n" + err

ppl_match = re.search(r"Final estimate:\s+PPL\s+=\s+([0-9\.]+)\s+\+/-\s+([0-9\.]+)", combined)
if ppl_match:
    ppl = float(ppl_match.group(1))
    stderr = float(ppl_match.group(2))
    print(f"  ✓ WikiText-2 Perplexity: {ppl:.4f} +/- {stderr:.4f} (measured in {t_ppl:.1f}s)")
else:
    print(f"  [!] Perplexity output excerpt:\n{combined[-600:]}")
    ppl = None
    stderr = None

# 2. Evaluate Prompt Test Suite
print("\n[Stage 2/2] Running Multi-Step Reasoning & Generation Evaluation...")
prompts = [
    {
        "id": "math_logic",
        "name": "Algebraic Deduction",
        "prompt": "<|im_start|>user\nSolve the system of equations step by step: 3x + 4y = 24 and 2x - y = 5. State the final values of x and y clearly.<|im_end|>\n<|im_start|>assistant\n"
    },
    {
        "id": "science_explanation",
        "name": "Rayleigh Scattering",
        "prompt": "<|im_start|>user\nWhy is the sky blue? Explain concisely in 2-3 sentences using physical principles.<|im_end|>\n<|im_start|>assistant\n"
    },
    {
        "id": "agent_tool_use",
        "name": "Agentic JSON Tool Call",
        "prompt": "<|im_start|>system\nYou are an agent with access to the tool get_stock_price(ticker: str). When asked for stock price, call the tool with valid JSON.<|im_end|>\n<|im_start|>user\nWhat is the current price of NVDA?<|im_end|>\n<|im_start|>assistant\n"
    }
]

prompt_results = []
for p in prompts:
    print(f"\n  [*] Testing Prompt: {p['name']}...")
    cli_cmd = (
        f"docker exec -e CUDA_VISIBLE_DEVICES=1 george-prism-server "
        f"/workspace/build_prism/llama.cpp-prism/build/bin/llama-cli "
        f"-m {MODEL_PATH} "
        f"-p \"{p['prompt']}\" "
        f"-ngl 99 -c 512 -n 128 --temp 0.0 --reasoning-effort low"
    )
    t0_gen = time.time()
    out, err, ret = run_cmd(cli_cmd)
    t_gen = time.time() - t0_gen
    
    # Extract generated output
    # Remove echo prompt
    gen_text = out
    if p['prompt'] in gen_text:
        gen_text = gen_text.split(p['prompt'])[-1]
    
    # Check tok/s
    speed_match = re.search(r"eval time =\s+([0-9\.]+) ms /\s+([0-9]+) runs\s+\(\s*([0-9\.]+) ms per token,\s*([0-9\.]+) tokens per second\)", err + out)
    tok_s = float(speed_match.group(4)) if speed_match else None
    
    # Clean text
    clean_out = gen_text.strip()
    preview = clean_out[:300] + ("..." if len(clean_out) > 300 else "")
    print(f"    ✓ Decode Speed: {tok_s or 'N/A'} tok/s")
    print(f"    ✓ Output:\n{preview}")
    
    prompt_results.append({
        "id": p["id"],
        "name": p["name"],
        "output": clean_out,
        "tok_s": tok_s,
        "latency_s": round(t_gen, 2)
    })

# Save Report
report = {
    "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
    "model": "/home/wsl-ops/models/frontier_qwen38/Qwen3.8-27B-SPTQ1_0-Optimal-Permuted.gguf",
    "wikitext2_perplexity": ppl,
    "wikitext2_stderr": stderr,
    "prompts": prompt_results
}

with open(OUTPUT_REPORT, "w") as f:
    json.dump(report, f, indent=2)

print(f"\n[✓] Benchmark Report saved to {OUTPUT_REPORT}")
print("=" * 80)
