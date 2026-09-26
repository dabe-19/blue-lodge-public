#!/usr/bin/env python3
"""
sweep_speculative_params.py:
Performs an empirical sweep over speculative decoding parameters (p_min, n_max)
using Blue-Llama-27B-Champion-v5-Internal-MTP.gguf to find the optimal operating point
for maximum decode speedup on RTX 3060.
"""

import os
import sys
import time
import json
import subprocess
import requests

SERVER_PORT = 18089
SERVER_URL = f"http://127.0.0.1:{SERVER_PORT}"
MODEL_PATH = "/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Internal-MTP.gguf"
LORA_PATH = "/models/frontier_qwen38/Blue-Llama-27B-Champion-v5-Iteration4-Fused-LoRA.gguf"

TEST_PROMPT = "Write a comprehensive Python class implementing a doubly linked list with insert, delete, reverse, and iterator methods."

CONFIGS = [
    {"name": "Baseline (No MTP)", "mtp": False, "n_max": 0, "p_min": 0.0},
    {"name": "MTP (n_max=1, p_min=0.0)", "mtp": True, "n_max": 1, "p_min": 0.0},
    {"name": "MTP (n_max=1, p_min=0.3)", "mtp": True, "n_max": 1, "p_min": 0.3},
    {"name": "MTP (n_max=1, p_min=0.5)", "mtp": True, "n_max": 1, "p_min": 0.5},
    {"name": "MTP (n_max=1, p_min=0.7)", "mtp": True, "n_max": 1, "p_min": 0.7},
    {"name": "MTP (n_max=2, p_min=0.5)", "mtp": True, "n_max": 2, "p_min": 0.5},
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

def run_sweep():
    results = []
    print("=" * 80)
    print("  Empirical Speculative MTP Parameter Sweep (GPU 0)")
    print("=" * 80)

    for cfg in CONFIGS:
        print(f"\n[*] Testing Configuration: {cfg['name']}...")
        # Stop any existing test container
        subprocess.run(["docker", "rm", "-f", "test-sweep-srv"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        cmd = [
            "docker", "run", "-d", "--name", "test-sweep-srv",
            "--gpus", '"device=0"',
            "-v", "/home/wsl-ops/models:/models:ro",
            "-v", "/home/wsl-ops/blue-lodge:/workspace:ro",
            "-e", 'LD_LIBRARY_PATH=/workspace/build_prism/llama.cpp-prism/build/bin:/usr/local/cuda/lib64',
            "-p", f"{SERVER_PORT}:{SERVER_PORT}",
            "george-cuda-sandbox:latest",
            "/workspace/build_prism/llama.cpp-prism/build/bin/llama-server",
            "-m", MODEL_PATH,
            "--lora", LORA_PATH,
            "-ngl", "99",
            "--port", str(SERVER_PORT),
            "--host", "0.0.0.0",
            "-c", "32768",
            "-np", "1",
            "--flash-attn", "on",
            "-ctk", "q4_0",
            "-ctv", "q4_0",
            "--reasoning-effort", "medium"
        ]

        if cfg["mtp"]:
            cmd.extend([
                "--spec-type", "draft-mtp",
                "--spec-draft-n-max", str(cfg["n_max"]),
                "--spec-draft-p-min", str(cfg["p_min"])
            ])

        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if proc.returncode != 0:
            print(f"[!] Failed to launch container: {proc.stderr}")
            continue

        if not wait_for_server():
            print("[!] Server failed to become healthy.")
            subprocess.run(["docker", "logs", "test-sweep-srv"])
            continue

        # Warmup query
        try:
            requests.post(
                f"{SERVER_URL}/v1/chat/completions",
                json={"messages": [{"role": "user", "content": "Hi"}], "max_tokens": 10},
                timeout=30
            )
        except Exception:
            pass

        # Measurement query
        try:
            resp = requests.post(
                f"{SERVER_URL}/v1/chat/completions",
                json={
                    "messages": [{"role": "user", "content": TEST_PROMPT}],
                    "max_tokens": 150,
                    "temperature": 0.0
                },
                timeout=60
            )
            data = resp.json()
            timings = data.get("timings", {})
            decode_tok_s = timings.get("predicted_per_second", 0.0)
            draft_n = timings.get("draft_n", 0)
            accepted = timings.get("draft_n_accepted", 0)
            acc_rate = (accepted / draft_n * 100.0) if draft_n > 0 else 0.0

            res_entry = {
                "name": cfg["name"],
                "decode_tok_s": decode_tok_s,
                "draft_n": draft_n,
                "accepted": accepted,
                "acceptance_rate": acc_rate,
                "prompt_tok_s": timings.get("prompt_per_second", 0.0)
            }
            results.append(res_entry)
            print(f"  ✓ Decode Speed: {decode_tok_s:.2f} tok/s | Drafts: {accepted}/{draft_n} ({acc_rate:.1f}%) | Prompt: {timings.get('prompt_per_second', 0.0):.1f} tok/s")
        except Exception as e:
            print(f"[!] Request error: {e}")

    subprocess.run(["docker", "rm", "-f", "test-sweep-srv"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    print("\n" + "=" * 80)
    print("  FINAL SPECULATIVE MTP PARAMETER SWEEP SUMMARY")
    print("=" * 80)
    print(f"{'Configuration':<32} | {'Decode (t/s)':<12} | {'Draft Accept %':<14} | {'Drafts'}")
    print("-" * 80)
    for r in results:
        print(f"{r['name']:<32} | {r['decode_tok_s']:<12.2f} | {r['acceptance_rate']:<13.1f}% | {r['accepted']}/{r['draft_n']}")
    print("=" * 80)

if __name__ == '__main__':
    run_sweep()
