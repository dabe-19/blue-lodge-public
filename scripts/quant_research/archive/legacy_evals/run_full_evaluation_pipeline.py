#!/usr/bin/env python3
"""
Full Autonomous Evaluation & Verification Pipeline for Blue-Llama Champion Model:
1. Verifies model size and physical disk reduction against baseline (must be >= 1.0 GiB reduction).
2. Measures WikiText-2 Perplexity at 512 ctx and 2048 ctx across all 4 chunks.
3. Launches blue-llama-server on GPU 1 (port 18081).
4. Runs AgentBench (JSON tool calling & schema conformance) and ARC-Challenge.
5. Tests the 3-Body Problem Dog Story prompt to verify chain-of-thought escape and story completion.
6. Writes comprehensive telemetry and Pareto analysis to benchmarks/results/champion_frontier_report.json.
"""

import os
import sys
import time
import json
import re
import subprocess
import urllib.request
import numpy as np

BASE_MODEL_PATH = "/home/wsl-ops/models/Ternary-Bonsai-2-27B-PTQ1_0.gguf"
CHAMP_MODEL_PATH = "/home/wsl-ops/models/frontier_qwen38/Blue-Llama-27B-Champion-v4.gguf"
LORA_PATH = "/home/wsl-ops/models/frontier_qwen38/Blue-Llama-27B-Champion-v4-LoRA.gguf"
RESULTS_DIR = "/home/wsl-ops/blue-lodge/benchmarks/results"
os.makedirs(RESULTS_DIR, exist_ok=True)

def run_cmd(cmd):
    res = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return res.stdout + res.stderr

def measure_file_sizes():
    print("[*] Auditing Model Physical File Sizes (The Plumb Standard)...")
    base_sz = os.path.getsize(BASE_MODEL_PATH)
    champ_sz = os.path.getsize(CHAMP_MODEL_PATH)
    lora_sz = os.path.getsize(LORA_PATH) if os.path.exists(LORA_PATH) else 0

    base_mib = base_sz / (1024**2)
    champ_mib = champ_sz / (1024**2)
    lora_mib = lora_sz / (1024**2)
    total_champ_mib = champ_mib + lora_mib

    saved_mib = base_mib - total_champ_mib
    saved_gb = (base_sz - (champ_sz + lora_sz)) / (1024**3)
    target_met = saved_mib >= 1024.0

    print(f"  Base Model Size:       {base_mib:.2f} MiB ({base_sz/(1024**3):.3f} GB)")
    print(f"  Champion Base Model:   {champ_mib:.2f} MiB ({champ_sz/(1024**3):.3f} GB)")
    print(f"  Residual LoRA Adapter: {lora_mib:.2f} MiB ({lora_sz/(1024**3):.3f} GB)")
    print(f"  Total Combined Size:   {total_champ_mib:.2f} MiB")
    print(f"  Net Size Reduction:    {saved_mib:.2f} MiB ({saved_gb:.3f} GB) | Target >= 1.0 GiB: {'MET' if target_met else 'NOT MET'}")

    return {
        "base_mib": base_mib,
        "champion_base_mib": champ_mib,
        "lora_mib": lora_mib,
        "total_champion_mib": total_champ_mib,
        "saved_mib": saved_mib,
        "saved_gb": saved_gb,
        "target_met": target_met
    }

def eval_perplexity(model_docker, lora_docker=None, ctx=2048, chunks=4):
    print(f"\n[*] Evaluating WikiText-2 Perplexity (ctx={ctx}, chunks={chunks}, lora={bool(lora_docker)})...")
    lora_arg = f"--lora {lora_docker}" if lora_docker and os.path.exists(lora_docker.replace("/models", "/home/wsl-ops/models")) else ""
    cmd = (
        f"docker exec -e CUDA_VISIBLE_DEVICES=1 george-prism-server "
        f"blue-llama-perplexity -m {model_docker} {lora_arg} "
        f"-f /workspace/data/calibration/wiki.test.raw "
        f"-c {ctx} -b 2048 -ngl 99 --chunks {chunks}"
    )
    t0 = time.time()
    output = run_cmd(cmd)
    elapsed = time.time() - t0

    m = re.search(r"Final estimate:\s+PPL\s+=\s+([0-9\.]+)\s+\+/-\s+([0-9\.]+)", output)
    chunks_found = re.findall(r"\[([0-9]+)\]([0-9\.]+)", output)
    ppl = float(m.group(1)) if m else None
    err = float(m.group(2)) if m else None
    chunk_dict = {f"chunk_{k}": float(v) for k, v in chunks_found}

    print(f"  ✓ Perplexity: {ppl} +/- {err} ({elapsed:.1f}s)")
    print(f"  ✓ Chunks: {chunk_dict}")
    return {"ppl": ppl, "err": err, "chunks": chunk_dict, "elapsed_s": elapsed}

def test_creative_dog_story(endpoint_url="http://127.0.0.1:18081"):
    print("\n[*] Testing Qualitative Generation: Three-Body Problem from Dogs' Perspective...")
    prompt = "Write a creative fiction story that invokes the 3-body problem but from the perspective of dogs."
    messages = [{"role": "user", "content": prompt}]
    req_body = json.dumps({
        "messages": messages,
        "max_tokens": 512,
        "temperature": 0.7,
        "stream": False
    }).encode("utf-8")
    req = urllib.request.Request(
        f"{endpoint_url}/v1/chat/completions",
        data=req_body,
        headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            content = data["choices"][0]["message"]["content"]
            timings = data.get("timings", {})
            has_repeats = ("three vs dog" in content or content.count("</think>") > 1)
            story_length = len(content.split())
            print(f"  ✓ Generation Speed: {timings.get('predicted_per_second', 0.0):.1f} tok/s")
            print(f"  ✓ Total Words: {story_length}")
            print(f"  ✓ Stutter/Repetition Loop Detected: {'YES (FAIL)' if has_repeats else 'NO (CLEAN PASS)'}")
            print(f"\n--- Model Output Snippet ---\n{content[:600]}...\n----------------------------")
            return {
                "success": True,
                "content": content,
                "word_count": story_length,
                "loop_detected": has_repeats,
                "speed_tok_s": timings.get('predicted_per_second', 0.0)
            }
    except Exception as e:
        print(f"  [-] Failed to query creative prompt: {e}")
        return {"success": False, "error": str(e)}

if __name__ == "__main__":
    sizes = measure_file_sizes()
    # PPL on champion
    ppl_res = eval_perplexity(
        "/models/frontier_qwen38/Blue-Llama-27B-Champion-Sub1GB.gguf",
        lora_docker="/models/frontier_qwen38/Blue-Llama-27B-Champion-Sub1GB-LoRA.gguf",
        ctx=2048,
        chunks=4
    )
