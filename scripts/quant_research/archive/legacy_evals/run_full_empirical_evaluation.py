#!/usr/bin/env python3
"""
Empirical Benchmark & Reasoning Evaluation Suite:
Measures WikiText-2 True Perplexity and tests Multi-Step Reasoning, Math, Coding,
and Agentic Tool-Calling across:
  1. Dense Baseline: Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf (5.85 GB)
  2. Hybrid Clean: Qwen3.8-27B-SPTQ1_0-Hybrid-Clean.gguf (4.72 GB)
  3. Sub-4GB Clean: Qwen3.8-27B-SPTQ2_0-Sub4GB-Clean.gguf (4.49 GB)
"""

import os
import sys
import time
import json
import subprocess
import urllib.request
import re

PERPLEXITY_BIN = "/workspace/build_prism/llama.cpp-prism/build/bin/llama-perplexity"
LLAMA_CLI = "/workspace/build_prism/llama.cpp-prism/build/bin/llama-cli"
TEST_DATA = "/workspace/data/calibration/wiki.test.raw"
RESULTS_DIR = "/home/wsl-ops/blue-lodge/benchmarks/results"
os.makedirs(RESULTS_DIR, exist_ok=True)

MODELS = [
    {
        "id": "baseline_bonsai",
        "name": "Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean",
        "path": "/models/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf",
        "type": "Dense PTQ1_0 (1.75 bpw)",
        "size_gb": 5.85
    },
    {
        "id": "hybrid_clean",
        "name": "Qwen3.8-27B-SPTQ1_0-Hybrid-Clean",
        "path": "/models/frontier_qwen38/Qwen3.8-27B-SPTQ1_0-Hybrid-Clean.gguf",
        "type": "2:4 Sparse Ternary Hybrid (1.35 bpw)",
        "size_gb": 4.72
    },
    {
        "id": "sub4gb_clean",
        "name": "Qwen3.8-27B-SPTQ2_0-Sub4GB-Clean",
        "path": "/models/frontier_qwen38/Qwen3.8-27B-SPTQ2_0-Sub4GB-Clean.gguf",
        "type": "2:4 Sparse Ternary Sub-4GB (1.06 bpw)",
        "size_gb": 4.49
    }
]

PROMPTS = [
    {
        "category": "Math / Multi-step Arithmetic",
        "prompt": "Solve step-by-step: If a store sells apples for $2 each and oranges for $3 each, and Alice buys 4 apples and 3 oranges with a $20 bill, how much change does she receive?",
        "max_tokens": 128
    },
    {
        "category": "Logic / Deductive Reasoning",
        "prompt": "A farmer has 17 sheep, and all but 9 die. How many sheep does the farmer have left? Explain in one sentence.",
        "max_tokens": 64
    },
    {
        "category": "Code Generation",
        "prompt": "Write a Python function `is_palindrome(s: str) -> bool` that checks if a string is a palindrome, ignoring non-alphanumeric characters and case. Return only the code.",
        "max_tokens": 128
    },
    {
        "category": "Scientific Factuality",
        "prompt": "In one concise sentence, explain why the sky appears blue on Earth.",
        "max_tokens": 64
    },
    {
        "category": "Agentic Tool Calling (JSON Mode)",
        "prompt": "You are a function calling agent. Call the function `search_database(table='users', filter={'status': 'active'}, limit=10)`. Return strictly valid JSON with keys 'name' and 'arguments'.",
        "max_tokens": 96
    }
]

def run_cmd(cmd):
    proc = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return proc.stdout, proc.stderr, proc.returncode

def measure_perplexity(model_path, chunks=4):
    print(f"[*] Measuring WikiText-2 Perplexity ({chunks} chunks) for {os.path.basename(model_path)}...")
    docker_cmd = (
        f"docker exec -e CUDA_VISIBLE_DEVICES=1 george-prism-server "
        f"{PERPLEXITY_BIN} -m {model_path} -f {TEST_DATA} -c 512 -b 2048 -ngl 99 --chunks {chunks}"
    )
    t0 = time.time()
    out, err, ret = run_cmd(docker_cmd)
    elapsed = time.time() - t0
    
    # Parse PPL from output
    # e.g.: Final estimate: PPL = 7.5856 +/- 0.654
    combined = out + "\n" + err
    ppl_match = re.search(r"Final estimate:\s+PPL\s+=\s+([0-9\.]+)\s+\+/-\s+([0-9\.]+)", combined)
    if ppl_match:
        ppl = float(ppl_match.group(1))
        stderr = float(ppl_match.group(2))
        print(f"    ✓ PPL = {ppl:.4f} +/- {stderr:.4f} (took {elapsed:.1f}s)")
        return {"ppl": ppl, "stderr": stderr, "elapsed_s": elapsed}
    else:
        # Fallback to chunk match
        chunk_matches = re.findall(r"\[\d+\]([0-9\.]+)", combined)
        if chunk_matches:
            ppl = float(chunk_matches[-1])
            print(f"    ✓ PPL = {ppl:.4f} (from last chunk, took {elapsed:.1f}s)")
            return {"ppl": ppl, "stderr": 0.0, "elapsed_s": elapsed}
        print(f"    [!] Failed to parse PPL. Output excerpt:\n{combined[-500:]}")
        return {"ppl": None, "stderr": None, "error": combined[-500:]}

def run_prompt_llama_cli(model_path, prompt, max_tokens, temp=0.0):
    escaped_prompt = prompt.replace('"', '\\"').replace('$', '\\$').replace('`', '\\`')
    formatted = f"<|im_start|>user\\n{escaped_prompt}<|im_end|>\\n<|im_start|>assistant\\n"
    docker_cmd = (
        f"docker exec -e CUDA_VISIBLE_DEVICES=1 george-prism-server "
        f"{LLAMA_CLI} -m {model_path} -ngl 99 -c 512 -n {max_tokens} --temp {temp} "
        f"--ignore-eos -st -p \"{formatted}\" < /dev/null"
    )
    t0 = time.time()
    out, err, ret = run_cmd(docker_cmd)
    elapsed = time.time() - t0
    
    # Extract generated output
    # Everything after "<|im_start|>assistant" up to "[ Prompt:" or end
    combined = out + "\n" + err
    if "<|im_start|>assistant" in combined:
        after_ass = combined.split("<|im_start|>assistant", 1)[1]
        if "[ Prompt:" in after_ass:
            clean_output = after_ass.split("[ Prompt:", 1)[0].strip()
        else:
            clean_output = after_ass.strip()
    else:
        clean_output = combined.strip()
    
    # Speed parsing
    tok_s = 0.0
    speed_match = re.search(r"Generation:\s+([0-9\.]+)\s+t/s", combined)
    if speed_match:
        tok_s = float(speed_match.group(1))
        
    return {
        "output": clean_output,
        "tok_s": tok_s,
        "elapsed_s": elapsed
    }

def main():
    print("=" * 80)
    print("  EMPIRICAL REASONING AND TRUE PERPLEXITY EVALUATION")
    print("  Evaluating Baseline vs. 2:4 Sparse Ternary Models on RTX 3060")
    print("=" * 80)
    
    full_report = {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "hardware": "NVIDIA GeForce RTX 3060 12GB (GPU 1)",
        "perplexity_dataset": "WikiText-2 Test Set (data/calibration/wiki.test.raw)",
        "models": {}
    }
    
    for m in MODELS:
        print(f"\n=================================================================")
        print(f" Evaluating: {m['name']} ({m['size_gb']} GB, {m['type']})")
        print(f"=================================================================")
        
        m_res = {
            "metadata": m,
            "perplexity": None,
            "prompts": []
        }
        
        # 1. Perplexity
        ppl_res = measure_perplexity(m["path"], chunks=4)
        m_res["perplexity"] = ppl_res
        
        # 2. Prompts
        print(f"[*] Running Prompt Suite ({len(PROMPTS)} test cases)...")
        for p in PROMPTS:
            print(f"  - [{p['category']}]...")
            p_res = run_prompt_llama_cli(m["path"], p["prompt"], p["max_tokens"])
            print(f"    Speed: {p_res['tok_s']:.1f} t/s")
            preview = p_res['output'].replace('\n', ' ')
            print(f"    Output: {preview[:80]}...")
            m_res["prompts"].append({
                "category": p["category"],
                "prompt": p["prompt"],
                "output": p_res["output"],
                "tok_s": p_res["tok_s"],
                "elapsed_s": p_res["elapsed_s"]
            })
            
        full_report["models"][m["id"]] = m_res
        
    # Save Report
    out_file = os.path.join(RESULTS_DIR, "empirical_reasoning_and_perplexity_report.json")
    with open(out_file, "w") as f:
        json.dump(full_report, f, indent=2)
        
    print(f"\n[✓] Complete evaluation report saved to {out_file}")

if __name__ == "__main__":
    main()
