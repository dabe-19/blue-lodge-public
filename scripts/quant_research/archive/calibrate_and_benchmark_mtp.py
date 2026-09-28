#!/usr/bin/env python3
"""
calibrate_and_benchmark_mtp.py:
Empirical calibration and benchmark suite for Blue-Llama Native Internal MTP draft head.
Tests baseline vs MTP with varying p_min, n_max, and calibration scaling factors
to find the peak decode throughput on RTX 3060.
"""

import os
import sys
import time
import json
import subprocess
import requests
import numpy as np

SERVER_PORT = 18089
SERVER_URL = f"http://127.0.0.1:{SERVER_PORT}"
MODEL_PATH = "/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Internal-MTP-Calibrated.gguf"
LORA_PATH = "/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration4-Fused-LoRA.gguf"

BENCHMARK_PROMPTS = [
    {
        "category": "Code Generation",
        "prompt": "Write a clean Python function implementing binary search on a sorted list, returning the index or -1 if not found. Include docstring and type hints."
    },
    {
        "category": "Mathematical Reasoning",
        "prompt": "Solve this riddle step-by-step: If 5 machines take 5 minutes to make 5 widgets, how long would it take 100 machines to make 100 widgets?"
    },
    {
        "category": "Architecture Explanation",
        "prompt": "Explain why linear state-space models like Mamba-2 achieve constant O(1) memory footprint per sequence during autoregressive generation compared to standard attention."
    }
]

def wait_for_server(timeout=45):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            r = requests.get(f"{SERVER_URL}/health", timeout=1)
            if r.status_code == 200:
                return True
        except Exception:
            pass
        time.sleep(1)
    return False

def launch_server(enable_mtp=False, n_max=1, p_min=0.6, ctx_size=32768):
    subprocess.run(["docker", "rm", "-f", "test-mtp-bench-srv"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    
    cmd = [
        "docker", "run", "-d", "--name", "test-mtp-bench-srv",
        "--gpus", '"device=0"',
        "-v", "/home/wsl-ops/models:/models:ro",
        "-v", "/home/wsl-ops/blue-lodge:/workspace:ro",
        "-e", "LD_LIBRARY_PATH=/workspace/build_prism/llama.cpp-prism/build/bin:/usr/local/cuda/lib64",
        "-p", f"{SERVER_PORT}:{SERVER_PORT}",
        "george-cuda-sandbox:latest",
        "/workspace/build_prism/llama.cpp-prism/build/bin/llama-server",
        "-m", MODEL_PATH,
        "--lora", LORA_PATH,
        "-ngl", "99",
        "--port", str(SERVER_PORT),
        "--host", "0.0.0.0",
        "-c", str(ctx_size),
        "-np", "1",
        "--flash-attn", "on",
        "-ctk", "q4_0",
        "-ctv", "q4_0",
        "--reasoning-effort", "medium"
    ]
    
    if enable_mtp:
        cmd.extend([
            "--spec-type", "draft-mtp",
            "--spec-draft-n-max", str(n_max),
            "--spec-draft-p-min", str(p_min),
            "--spec-draft-ngl", "99"
        ])
        
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        print(f"[!] Server launch failed: {proc.stderr}")
        return False
        
    return wait_for_server()

def eval_prompt(prompt_text, max_tokens=100):
    try:
        t0 = time.time()
        resp = requests.post(
            f"{SERVER_URL}/v1/chat/completions",
            json={
                "messages": [{"role": "user", "content": prompt_text}],
                "max_tokens": max_tokens,
                "temperature": 0.0
            },
            timeout=90
        )
        data = resp.json()
        timings = data.get("timings", {})
        predicted_tps = timings.get("predicted_per_second", 0.0)
        prompt_tps = timings.get("prompt_per_second", 0.0)
        draft_n = timings.get("draft_n", 0)
        draft_accepted = timings.get("draft_n_accepted", 0)
        acc_pct = (draft_accepted / draft_n * 100.0) if draft_n > 0 else 0.0
        
        return {
            "predicted_tps": predicted_tps,
            "prompt_tps": prompt_tps,
            "draft_n": draft_n,
            "draft_accepted": draft_accepted,
            "acc_pct": acc_pct
        }
    except Exception as e:
        print(f"[!] Request failed: {e}")
        return None

def main():
    print("=" * 80)
    print("  Blue-Llama Native Internal MTP Calibration & Benchmarking Engine")
    print("  Target: RTX 3060 (12GB) | Model: Blue-Llama-27B-Champion-v5-Internal-MTP")
    print("=" * 80)
    
    configurations = [
        {"name": "1. Baseline (No MTP)", "mtp": False, "n_max": 0, "p_min": 0.0},
        {"name": "2. MTP (n_max=1, p_min=0.50)", "mtp": True, "n_max": 1, "p_min": 0.50},
        {"name": "3. MTP (n_max=1, p_min=0.65)", "mtp": True, "n_max": 1, "p_min": 0.65},
        {"name": "4. MTP (n_max=1, p_min=0.75)", "mtp": True, "n_max": 1, "p_min": 0.75},
        {"name": "5. MTP (n_max=1, p_min=0.85)", "mtp": True, "n_max": 1, "p_min": 0.85},
        {"name": "6. MTP (n_max=2, p_min=0.75)", "mtp": True, "n_max": 2, "p_min": 0.75},
    ]
    
    summary = []
    
    for cfg in configurations:
        print(f"\n[*] Deploying Configuration: {cfg['name']}...")
        if not launch_server(enable_mtp=cfg["mtp"], n_max=cfg["n_max"], p_min=cfg["p_min"]):
            print(f"[!] Could not launch server for {cfg['name']}")
            continue
            
        print("    Server healthy. Running benchmark prompts...")
        cfg_results = []
        for p in BENCHMARK_PROMPTS:
            res = eval_prompt(p["prompt"], max_tokens=100)
            if res:
                cfg_results.append(res)
                print(f"      - {p['category']:26s}: Decode = {res['predicted_tps']:.2f} t/s | Drafts: {res['draft_accepted']}/{res['draft_n']} ({res['acc_pct']:.1f}%)")
                
        if cfg_results:
            avg_tps = sum(r["predicted_tps"] for r in cfg_results) / len(cfg_results)
            total_drafts = sum(r["draft_n"] for r in cfg_results)
            total_accepted = sum(r["draft_accepted"] for r in cfg_results)
            overall_acc = (total_accepted / total_drafts * 100.0) if total_drafts > 0 else 0.0
            
            summary.append({
                "name": cfg["name"],
                "avg_tps": avg_tps,
                "overall_acc": overall_acc,
                "total_drafts": total_drafts,
                "total_accepted": total_accepted
            })
            print(f"    --> Average Decode Throughput: {avg_tps:.2f} tok/s (Acceptance: {overall_acc:.1f}%)")
            
    subprocess.run(["docker", "rm", "-f", "test-mtp-bench-srv"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    
    print("\n" + "=" * 80)
    print("  FINAL SPECULATIVE MTP BENCHMARK SUMMARY")
    print("=" * 80)
    print(f"{'Configuration':<34} | {'Decode (t/s)':<12} | {'Draft Accept %':<14} | {'Drafts (Acc/Tot)'}")
    print("-" * 80)
    for s in summary:
        print(f"{s['name']:<34} | {s['avg_tps']:<12.2f} | {s['overall_acc']:<13.1f}% | {s['total_accepted']}/{s['total_drafts']}")
    print("=" * 80)

if __name__ == '__main__':
    main()
