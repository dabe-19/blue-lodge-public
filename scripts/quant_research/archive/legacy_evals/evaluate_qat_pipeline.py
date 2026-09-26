#!/usr/bin/env python3
"""
Comprehensive Evaluation of Qwen3.8-27B-SPTQ1_0-QAT-Full:
1. WikiText-2 Perplexity (4 chunks) - Standalone QAT Base Model
2. WikiText-2 Perplexity (4 chunks) - QAT Base Model + Matching Residual LoRA
3. Reasoning & Instruction Generation (Algebraic deduction, science, agentic tool call)
"""

import os
import sys
import time
import subprocess
import json
import re

MODEL_PATH = "/models/frontier_qwen38/Qwen3.8-27B-SPTQ1_0-QAT-Full.gguf"
LORA_PATH = "/models/frontier_qwen38/qwen38-sptq-qat-residual-lora.gguf"
WIKI_TEST = "/workspace/data/calibration/wiki.test.raw"
OUTPUT_REPORT = "/home/wsl-ops/blue-lodge/benchmarks/results/qat_pipeline_eval_report.json"
os.makedirs(os.path.dirname(OUTPUT_REPORT), exist_ok=True)

def run_cmd(cmd):
    proc = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return proc.stdout, proc.stderr, proc.returncode

print("=" * 80)
print("  Comprehensive Evaluation: Qwen 3.8 27B True QAT + Residual LoRA")
print("=" * 80)

# Step 1: Standalone QAT Base Model Perplexity
print("\n[Stage 1/3] Measuring WikiText-2 PPL: QAT Base Model (Standalone)...")
sys.stdout.flush()

cmd_base_ppl = (
    f"docker exec -e CUDA_VISIBLE_DEVICES=1 george-prism-server "
    f"/workspace/build_prism/llama.cpp-prism/build/bin/llama-perplexity "
    f"-m {MODEL_PATH} "
    f"-f {WIKI_TEST} -c 512 -b 2048 -ngl 99 --chunks 4"
)
t0 = time.time()
out, err, ret = run_cmd(cmd_base_ppl)
t_base = time.time() - t0
combined_base = out + "\n" + err

base_match = re.search(r"Final estimate:\s+PPL\s+=\s+([0-9\.]+)\s+\+/-\s+([0-9\.]+)", combined_base)
if base_match:
    base_ppl = float(base_match.group(1))
    base_err = float(base_match.group(2))
    print(f"  ✓ Standalone QAT Base PPL: {base_ppl:.4f} +/- {base_err:.4f} ({t_base:.1f}s)")
else:
    print(f"  [!] Perplexity output excerpt:\n{combined_base[-600:]}")
    base_ppl, base_err = None, None
sys.stdout.flush()

# Step 2: QAT Base Model + Matching Residual LoRA Perplexity
print("\n[Stage 2/3] Measuring WikiText-2 PPL: QAT Base Model + QAT Residual LoRA...")
sys.stdout.flush()

cmd_lora_ppl = (
    f"docker exec -e CUDA_VISIBLE_DEVICES=1 george-prism-server "
    f"/workspace/build_prism/llama.cpp-prism/build/bin/llama-perplexity "
    f"-m {MODEL_PATH} "
    f"--lora {LORA_PATH} "
    f"-f {WIKI_TEST} -c 512 -b 2048 -ngl 99 --chunks 4"
)
t0 = time.time()
out, err, ret = run_cmd(cmd_lora_ppl)
t_lora = time.time() - t0
combined_lora = out + "\n" + err

lora_match = re.search(r"Final estimate:\s+PPL\s+=\s+([0-9\.]+)\s+\+/-\s+([0-9\.]+)", combined_lora)
if lora_match:
    lora_ppl = float(lora_match.group(1))
    lora_err = float(lora_match.group(2))
    print(f"  ✓ QAT Base + Residual LoRA PPL: {lora_ppl:.4f} +/- {lora_err:.4f} ({t_lora:.1f}s)")
else:
    print(f"  [!] Perplexity output excerpt:\n{combined_lora[-600:]}")
    lora_ppl, lora_err = None, None
sys.stdout.flush()

# Step 3: Multi-Step Reasoning & Instruction Following
print("\n[Stage 3/3] Evaluating Multi-Step Reasoning & Coherence on GPU 1...")
prompts = [
    {
        "id": "algebraic_deduction",
        "name": "Algebraic Deduction",
        "prompt": "<|im_start|>user\nSolve the system of equations step by step: 3x + 4y = 24 and 2x - y = 5. State the final values of x and y clearly.<|im_end|>\n<|im_start|>assistant\n<think>\n"
    },
    {
        "id": "scientific_explanation",
        "name": "Rayleigh Scattering",
        "prompt": "<|im_start|>user\nWhy is the sky blue? Explain concisely in 2-3 sentences using physical principles.<|im_end|>\n<|im_start|>assistant\n<think>\n"
    },
    {
        "id": "agent_tool_use",
        "name": "Agentic JSON Tool Call",
        "prompt": "<|im_start|>system\nYou are an agent with access to the tool get_stock_price(ticker: str). When asked for stock price, call the tool with valid JSON.<|im_end|>\n<|im_start|>user\nWhat is the current price of NVDA?<|im_end|>\n<|im_start|>assistant\n<think>\n"
    }
]

prompt_results = []
for p in prompts:
    print(f"\n  [*] Testing Prompt: {p['name']}...")
    cli_cmd = (
        f"docker exec -e CUDA_VISIBLE_DEVICES=1 george-prism-server "
        f"/workspace/build_prism/llama.cpp-prism/build/bin/llama-cli "
        f"-m {MODEL_PATH} "
        f"--lora {LORA_PATH} "
        f"-p \"{p['prompt']}\" "
        f"-ngl 99 -c 512 -n 128 --temp 0.6 --ignore-eos --single-turn -e"
    )
    t0_gen = time.time()
    out, err, ret = run_cmd(cli_cmd)
    t_gen = time.time() - t0_gen
    
    gen_text = out
    if "<think>" in gen_text:
        gen_text = gen_text.split("<think>")[-1]
    if "[ Prompt:" in gen_text:
        gen_text = gen_text.split("[ Prompt:")[0]
    
    speed_match = re.search(r"Generation:\s+([0-9\.]+)\s+t/s", out + err)
    tok_s = float(speed_match.group(1)) if speed_match else None
    
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

report = {
    "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
    "model": MODEL_PATH,
    "lora": LORA_PATH,
    "base_ppl": base_ppl,
    "base_err": base_err,
    "lora_ppl": lora_ppl,
    "lora_err": lora_err,
    "prompts": prompt_results
}

with open(OUTPUT_REPORT, "w") as f:
    json.dump(report, f, indent=2)

print(f"\n[✓] Evaluation completed. Report saved to {OUTPUT_REPORT}")
print("=" * 80)
