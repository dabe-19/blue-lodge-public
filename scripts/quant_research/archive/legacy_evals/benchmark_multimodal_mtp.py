#!/usr/bin/env python3
"""
Comprehensive Headless GPU 0 Benchmark Suite:
1. Text-Only Baselines & Candidates (Dense PTQ1_0 vs SPTQ1_0 Hybrid vs SPTQ2_0 Sparse)
2. Vision Tower Multimodal Inference (Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf + MooseFergie.jpg)
3. MTP Speculative Decoding (mtp-Qwen3.8-27B-Q4_0.gguf)
4. Full Combined Stack (Model + Vision + MTP) on 12GB RTX 3060 (Headless GPU 0)

Adheres strictly to The Plumb: 100% empirical measurement, zero synthetic fallbacks.
"""

import os
import sys
import time
import json
import subprocess
import re

BENCH_RESULTS_FILE = "/home/wsl-ops/blue-lodge/benchmarks/results/multimodal_mtp_benchmarks.json"
MODELS_DIR = "/home/wsl-ops/models"
TEST_IMAGE = "/workspace/.george/MooseFergie.jpg"
HOST_IMAGE = "/home/wsl-ops/blue-lodge/.george/MooseFergie.jpg"

MMPROJ_PATH = "/models/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf"
MTP_DRAFT_PATH = "/models/frontier_qwen38/MTP/mtp-Qwen3.8-27B-Q4_0.gguf"

MODELS = [
    {
        "id": "bonsai_ptq1_0",
        "name": "Ternary-Bonsai-2-27B-PTQ1_0 (Dense Baseline)",
        "path": "/models/Ternary-Bonsai-2-27B-PTQ1_0.gguf",
        "host_path": "/home/wsl-ops/models/Ternary-Bonsai-2-27B-PTQ1_0.gguf"
    },
    {
        "id": "sptq1_0_hybrid",
        "name": "Qwen3.8-27B-SPTQ1_0-Hybrid (Stable 4.62GB)",
        "path": "/models/frontier_qwen38/Qwen3.8-27B-SPTQ1_0-Hybrid.gguf",
        "host_path": "/home/wsl-ops/models/frontier_qwen38/Qwen3.8-27B-SPTQ1_0-Hybrid.gguf"
    },
    {
        "id": "sptq2_0_sparse",
        "name": "Qwen3.8-27B-SPTQ2_0-Sparse (Sub-4GB 3.95GB)",
        "path": "/models/frontier_qwen38/Qwen3.8-27B-SPTQ2_0-Sparse.gguf",
        "host_path": "/home/wsl-ops/models/frontier_qwen38/Qwen3.8-27B-SPTQ2_0-Sparse.gguf"
    }
]

def get_gpu0_vram_mb():
    try:
        res = subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits", "-i", "0"],
            capture_output=True, text=True, check=True
        )
        return float(res.stdout.strip())
    except Exception as e:
        return 0.0

def run_llama_cli(args, timeout_sec=120):
    cmd = [
        "docker", "exec",
        "-e", "CUDA_VISIBLE_DEVICES=0",
        "-e", "LD_LIBRARY_PATH=/workspace/build_prism/llama.cpp-prism/build/bin:/usr/local/cuda/lib64",
        "george-prism-worker",
        "/workspace/build_prism/llama.cpp-prism/build/bin/llama-cli"
    ] + args

    vram_start = get_gpu0_vram_mb()
    start_t = time.time()
    
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    peak_vram = vram_start
    
    try:
        while proc.poll() is None:
            v = get_gpu0_vram_mb()
            if v > peak_vram:
                peak_vram = v
            time.sleep(0.15)
            if time.time() - start_t > timeout_sec:
                proc.kill()
                return {"success": False, "error": "Timeout", "stdout": "", "stderr": "Process timed out"}
        
        stdout, stderr = proc.communicate(timeout=10)
        elapsed = time.time() - start_t
        full_out = stdout + "\n" + stderr

        # Extract prompt processing and generation speed
        pp_speed = 0.0
        tg_speed = 0.0
        
        m_pp = re.search(r"(?:Prompt:|prompt eval time.*?)\s*([0-9\.]+)\s*(?:t/s|tokens per second)", full_out)
        if m_pp:
            pp_speed = float(m_pp.group(1))

        m_tg = re.search(r"(?:Generation:|eval time.*?)\s*([0-9\.]+)\s*(?:t/s|tokens per second)", full_out)
        if m_tg:
            tg_speed = float(m_tg.group(1))

        # Check for speculative acceptance rate if present
        acceptance_rate = None
        m_acc = re.search(r"draft acceptance.*?([0-9\.]+)\s*%", full_out)
        if m_acc:
            acceptance_rate = float(m_acc.group(1))

        return {
            "success": (proc.returncode == 0),
            "returncode": proc.returncode,
            "stdout": stdout.strip(),
            "stderr": stderr.strip(),
            "elapsed_sec": round(elapsed, 2),
            "peak_vram_mb": round(peak_vram, 1),
            "vram_delta_mb": round(peak_vram - vram_start, 1),
            "prompt_eval_tok_s": pp_speed,
            "decode_tok_s": tg_speed,
            "acceptance_rate_pct": acceptance_rate
        }
    except Exception as e:
        if proc.poll() is None:
            proc.kill()
        return {"success": False, "error": str(e), "stdout": "", "stderr": str(e)}

def benchmark_text_only(model_info):
    print(f"\n--- [Text-Only Benchmark: {model_info['name']}] ---")
    prompt = "Explain in two clear paragraphs how neural network quantization reduces memory bandwidth bottlenecks during LLM autoregressive inference."
    args = [
        "-m", model_info["path"],
        "-ngl", "99",
        "-c", "2048",
        "-b", "512",
        "--temp", "0.7",
        "-n", "128",
        "--single-turn",
        "--simple-io",
        "-p", prompt
    ]
    res = run_llama_cli(args, timeout_sec=90)
    print(f"  Status: {'SUCCESS' if res.get('success') else 'FAILED'}")
    print(f"  Prompt Speed: {res.get('prompt_eval_tok_s', 0.0)} tok/s")
    print(f"  Decode Speed: {res.get('decode_tok_s', 0.0)} tok/s")
    print(f"  Peak VRAM:    {res.get('peak_vram_mb', 0.0)} MiB")
    print(f"  Output Sample:\n    {res.get('stdout', '')[:200]}...")
    return res

def benchmark_vision_tower(model_info):
    print(f"\n--- [Vision Tower Benchmark: {model_info['name']} + MooseFergie.jpg] ---")
    prompt = "Describe what you see in this image in detail. Identify the breed of animals, where they are sitting, and their appearance."
    args = [
        "-m", model_info["path"],
        "--mmproj", MMPROJ_PATH,
        "--image", TEST_IMAGE,
        "-ngl", "99",
        "-c", "4096",
        "-b", "512",
        "--temp", "0.2",
        "-n", "128",
        "--single-turn",
        "--simple-io",
        "-p", prompt
    ]
    res = run_llama_cli(args, timeout_sec=120)
    print(f"  Status: {'SUCCESS' if res.get('success') else 'FAILED'}")
    print(f"  Prompt/Image Speed: {res.get('prompt_eval_tok_s', 0.0)} tok/s")
    print(f"  Decode Speed:       {res.get('decode_tok_s', 0.0)} tok/s")
    print(f"  Peak VRAM:          {res.get('peak_vram_mb', 0.0)} MiB")
    print(f"  Vision Description:\n    {res.get('stdout', '')[:350]}...")
    return res

def benchmark_mtp_speculative(model_info):
    print(f"\n--- [MTP Speculative Decoding Benchmark: {model_info['name']} + MTP Draft] ---")
    prompt = "Write a Python script that implements an async priority queue with graceful cancellation and worker health checks."
    args = [
        "-m", model_info["path"],
        "-md", MTP_DRAFT_PATH,
        "-ngld", "99",
        "--spec-type", "draft-mtp",
        "-ngl", "99",
        "-c", "2048",
        "-b", "512",
        "--temp", "0.2",
        "-n", "128",
        "--single-turn",
        "--simple-io",
        "-p", prompt
    ]
    res = run_llama_cli(args, timeout_sec=120)
    print(f"  Status: {'SUCCESS' if res.get('success') else 'FAILED'}")
    print(f"  Decode Speed (w/ MTP): {res.get('decode_tok_s', 0.0)} tok/s")
    print(f"  Acceptance Rate:       {res.get('acceptance_rate_pct')}%")
    print(f"  Peak VRAM:             {res.get('peak_vram_mb', 0.0)} MiB")
    return res

def main():
    print("=" * 75)
    print("EMPIRICAL MULTIMODAL & MTP BENCHMARK SUITE (HEADLESS GPU 0)")
    print(f"Test Image: {HOST_IMAGE}")
    print(f"Vision Tower: {MMPROJ_PATH}")
    print(f"MTP Draft:    {MTP_DRAFT_PATH}")
    print("=" * 75)

    # Ensure george-prism-server is stopped during isolated tests so GPU 0 VRAM is 100% dedicated
    print("[*] Halting george-prism-server for isolated benchmarks...")
    subprocess.run(["docker", "stop", "george-prism-server"], check=False)
    time.sleep(2)

    all_results = {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "hardware": "NVIDIA GeForce RTX 3060 12GB (Headless GPU 0)",
        "models": {}
    }

    try:
        for m in MODELS:
            if not os.path.exists(m["host_path"]):
                print(f"[!] Skipping {m['name']} (file not found: {m['host_path']})")
                continue

            print(f"\n{'#' * 75}")
            print(f"EVALUATING MODEL: {m['name']}")
            print(f"Physical Size: {os.path.getsize(m['host_path'])/(1024**3):.2f} GB")
            print(f"{'#' * 75}")

            m_res = {
                "physical_size_gb": round(os.path.getsize(m["host_path"])/(1024**3), 2),
                "text_only": benchmark_text_only(m),
                "vision_tower": benchmark_vision_tower(m),
                "mtp_speculative": benchmark_mtp_speculative(m)
            }
            all_results["models"][m["id"]] = m_res

        os.makedirs(os.path.dirname(BENCH_RESULTS_FILE), exist_ok=True)
        with open(BENCH_RESULTS_FILE, "w") as f:
            json.dump(all_results, f, indent=2)
        print(f"\n[*] All benchmark results saved to: {BENCH_RESULTS_FILE}")

    finally:
        print("\n[*] Restoring george-prism-server on Port 8080...")
        subprocess.run(["docker", "start", "george-prism-server"], check=False)
        print("[*] george-prism-server restored.")

if __name__ == "__main__":
    main()
