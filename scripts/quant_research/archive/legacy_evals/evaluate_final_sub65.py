#!/usr/bin/env python3
"""
Comprehensive Final Verification Suite for Sub-6.5GB Frontier Model:
Evaluates:
1. WikiText-2 PPL (4 chunks, 512 ctx) -> Target: PPL < 10.0
2. Peak Total GPU 1 VRAM footprint during full active inference -> Target: <= 6.50 GB
3. Baseline Generation Decode Speed -> Target: >= 24.6 tok/s
4. MTP Speculative Decoding compatibility
5. Vision Tower Multimodal Image Analysis
6. Multi-domain Reasoning Capabilities (Math, Logic, Code)
"""

import os
import sys
sys.path.insert(0, '/home/wsl-ops/blue-lodge')
import time
import subprocess
import re
import json

BASE_MODEL_HOST = "/home/wsl-ops/models/frontier_qwen38/Qwen3.8-27B-SPTQ-Final-Sub65.gguf"
BASE_MODEL_DOCKER = "/models/frontier_qwen38/Qwen3.8-27B-SPTQ-Final-Sub65.gguf"
MTP_DOCKER = "/models/frontier_qwen38/MTP/mtp-Qwen3.8-27B-Q4_0.gguf"
VISION_DOCKER = "/models/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf"
IMAGE_DOCKER = "/workspace/.george/MooseFergie.jpg"

def get_gpu1_vram_mb():
    try:
        res = subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits", "-i", "1"],
            capture_output=True, text=True, check=True
        )
        return float(res.stdout.strip())
    except Exception:
        return 0.0

def run_command_monitored(cmd_args, label, timeout_sec=120):
    baseline_vram = get_gpu1_vram_mb()
    print(f"\n=======================================================")
    print(f"Executing: {label}")
    print(f"GPU 1 Baseline VRAM: {baseline_vram:.1f} MiB ({baseline_vram/1024:.2f} GB)")

    proc = subprocess.Popen(cmd_args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    peak_vram = baseline_vram
    t0 = time.time()

    while proc.poll() is None:
        curr = get_gpu1_vram_mb()
        if curr > peak_vram:
            peak_vram = curr
        time.sleep(0.05)
        if time.time() - t0 > timeout_sec:
            proc.kill()
            break

    out, err = proc.communicate()
    model_vram = peak_vram - baseline_vram
    print(f"Peak Total GPU 1 VRAM: {peak_vram:.1f} MiB ({peak_vram/1024:.2f} GB)")
    print(f"Dedicated Model VRAM:  {model_vram:.1f} MiB ({model_vram/1024:.2f} GB)")

    # Extract speeds
    m_tg = re.search(r"Generation:\s+([0-9\.]+)\s+t/s", out + err)
    m_pp = re.search(r"Prompt:\s+([0-9\.]+)\s+t/s", out + err)
    tg_speed = float(m_tg.group(1)) if m_tg else 0.0
    pp_speed = float(m_pp.group(1)) if m_pp else 0.0
    if tg_speed > 0:
        print(f"Decode Speed:          {tg_speed:.1f} t/s (Prompt: {pp_speed:.1f} t/s)")

    return {
        "stdout": out,
        "stderr": err,
        "peak_vram_mb": peak_vram,
        "peak_vram_gb": round(peak_vram / 1024, 3),
        "model_vram_mb": model_vram,
        "model_vram_gb": round(model_vram / 1024, 3),
        "decode_tok_s": tg_speed,
        "prompt_tok_s": pp_speed
    }

def main():
    if not os.path.exists(BASE_MODEL_HOST):
        print(f"[!] Error: Model {BASE_MODEL_HOST} does not exist yet!")
        sys.exit(1)

    file_bytes = os.path.getsize(BASE_MODEL_HOST)
    report = {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "base_model": BASE_MODEL_HOST,
        "base_size_bytes": file_bytes,
        "base_size_gb": round(file_bytes / (1024**3), 3),
        "base_size_mb": round(file_bytes / (1024**2), 1)
    }

    print("=" * 80)
    print("  Sub-6.5GB Frontier Model Comprehensive Verification Suite")
    print(f"  Model:      {BASE_MODEL_HOST}")
    print(f"  Disk Size:  {report['base_size_mb']} MiB ({report['base_size_gb']} GB)")
    print("=" * 80)

    # 1. WikiText-2 Perplexity (4 chunks, 512 ctx)
    print("\n[Phase 1/5] Measuring WikiText-2 Perplexity (4 chunks, 512 ctx)...")
    cmd_ppl = [
        "docker", "exec", "-e", "CUDA_VISIBLE_DEVICES=1", "george-prism-server",
        "/workspace/build_prism/llama.cpp-prism/build/bin/llama-perplexity",
        "-m", BASE_MODEL_DOCKER,
        "-f", "/workspace/data/calibration/wiki.test.raw",
        "-c", "512", "-b", "2048", "-ngl", "99", "--chunks", "4"
    ]
    t0 = time.time()
    res_ppl = subprocess.run(cmd_ppl, capture_output=True, text=True)
    t_ppl = time.time() - t0
    output_combined = res_ppl.stdout + res_ppl.stderr
    m = re.search(r"Final estimate:\s+PPL\s+=\s+([0-9\.]+)\s+\+/-\s+([0-9\.]+)", output_combined)
    chunks = re.findall(r"\[([0-9]+)\]([0-9\.]+)", output_combined)

    if m:
        report["ppl"] = float(m.group(1))
        report["ppl_err"] = float(m.group(2))
        report["ppl_chunks"] = {f"chunk_{c[0]}": float(c[1]) for c in chunks}
        print(f"  ✓ WikiText-2 PPL: {report['ppl']:.4f} +/- {report['ppl_err']:.4f} ({t_ppl:.1f}s)")
        print(f"  ✓ Per-chunk: {report['ppl_chunks']}")
    else:
        print(f"  [!] Perplexity raw output:\n{output_combined[-500:]}")
        report["ppl"] = None

    # 2. VRAM & Base Decode Speed
    print("\n[Phase 2/5] Measuring VRAM & Standard Decode Speed...")
    res_vram = run_command_monitored([
        "docker", "exec", "-e", "CUDA_VISIBLE_DEVICES=1", "george-prism-server",
        "/workspace/build_prism/llama.cpp-prism/build/bin/llama-cli",
        "-m", BASE_MODEL_DOCKER,
        "-ngl", "99", "-c", "512", "-n", "32",
        "-p", "Describe the significance of the mathematical constant Euler's e.",
        "--single-turn"
    ], "Standard Inference")
    report["standard_inference"] = {
        "peak_vram_gb": res_vram["peak_vram_gb"],
        "peak_vram_mb": res_vram["peak_vram_mb"],
        "model_vram_gb": res_vram["model_vram_gb"],
        "model_vram_mb": res_vram["model_vram_mb"],
        "decode_tok_s": res_vram["decode_tok_s"],
        "prompt_tok_s": res_vram["prompt_tok_s"]
    }

    # 3. MTP Speculative Decoding Verification
    print("\n[Phase 3/5] Verifying MTP Speculative Decoding Acceleration...")
    res_mtp = run_command_monitored([
        "docker", "exec", "-e", "CUDA_VISIBLE_DEVICES=1", "george-prism-server",
        "/workspace/build_prism/llama.cpp-prism/build/bin/llama-cli",
        "-m", BASE_MODEL_DOCKER,
        "-md", MTP_DOCKER,
        "--spec-type", "draft-mtp",
        "-ngl", "99", "-c", "512", "-n", "32",
        "-p", "Write a python function to compute the Fibonacci sequence efficiently.",
        "--single-turn"
    ], "MTP Speculative Decoding Inference")
    report["mtp_inference"] = {
        "peak_vram_gb": res_mtp["peak_vram_gb"],
        "model_vram_gb": res_mtp["model_vram_gb"],
        "decode_tok_s": res_mtp["decode_tok_s"],
        "prompt_tok_s": res_mtp["prompt_tok_s"],
        "success": res_mtp["decode_tok_s"] > 0
    }

    def clean_gen(text):
        lines = [l.strip() for l in text.splitlines() if l.strip() and not any(x in l for x in ["\b", "▄", "█", "▀", "Loading model", "warn:", "llama_", "main:", "system_info"])]
        return "\n".join(lines[-6:]) if lines else ""

    # 4. Vision Tower Multimodal Image Analysis Verification
    print("\n[Phase 4/5] Verifying Vision Tower Multimodal Analysis...")
    res_vision = run_command_monitored([
        "docker", "exec", "-e", "CUDA_VISIBLE_DEVICES=1", "george-prism-server",
        "/workspace/build_prism/llama.cpp-prism/build/bin/llama-cli",
        "-m", BASE_MODEL_DOCKER,
        "--mmproj", VISION_DOCKER,
        "--image", IMAGE_DOCKER,
        "-ngl", "99", "-c", "2048", "-n", "32",
        "-p", "What animals are visible in this image and what are they doing?",
        "--single-turn"
    ], "Vision Tower Multimodal Inference")
    report["vision_inference"] = {
        "peak_vram_gb": res_vision["peak_vram_gb"],
        "model_vram_gb": res_vision["model_vram_gb"],
        "decode_tok_s": res_vision["decode_tok_s"],
        "prompt_tok_s": res_vision["prompt_tok_s"],
        "success": res_vision["decode_tok_s"] > 0,
        "sample_output": clean_gen(res_vision["stdout"])[:300]
    }

    # 5. Multi-Domain Reasoning Verification
    print("\n[Phase 5/5] Multi-Domain Reasoning Verification...")
    reasoning_prompts = [
        ("Math", "Solve for x: 5x - 15 = 45. Give the exact value of x."),
        ("Logic", "A bat and a ball cost $1.10 in total. The bat costs $1.00 more than the ball. How much does the ball cost?"),
        ("Code", "Write a Python one-liner function to check if a string is a palindrome.")
    ]
    report["reasoning"] = {}
    for domain, prompt in reasoning_prompts:
        res_r = run_command_monitored([
            "docker", "exec", "-e", "CUDA_VISIBLE_DEVICES=1", "george-prism-server",
            "/workspace/build_prism/llama.cpp-prism/build/bin/llama-cli",
            "-m", BASE_MODEL_DOCKER,
            "-ngl", "99", "-c", "512", "-n", "48",
            "-p", prompt,
            "--single-turn"
        ], f"Reasoning: {domain}")
        report["reasoning"][domain] = {
            "decode_tok_s": res_r["decode_tok_s"],
            "sample_output": clean_gen(res_r["stdout"])[:300]
        }

    # Save final report to disk
    out_json = "/home/wsl-ops/blue-lodge/benchmarks/results/sub65_frontier_final_report.json"
    os.makedirs(os.path.dirname(out_json), exist_ok=True)
    with open(out_json, "w") as f:
        json.dump(report, f, indent=2)

    print("\n" + "=" * 80)
    print("  FINAL BENCHMARK AUDIT SUMMARY")
    print("=" * 80)
    print(f"  Model File Size:         {report['base_size_gb']} GB ({report['base_size_mb']} MiB)")
    print(f"  WikiText-2 PPL:          {report.get('ppl', 'N/A')} +/- {report.get('ppl_err', 'N/A')} (Target < 10.0)")
    print(f"  Peak Total GPU 1 VRAM:   {report['standard_inference']['peak_vram_gb']} GB ({report['standard_inference']['peak_vram_mb']} MiB) (Target <= 6.50 GB)")
    print(f"  Dedicated Model VRAM:    {report['standard_inference']['model_vram_gb']} GB ({report['standard_inference']['model_vram_mb']} MiB)")
    print(f"  Standard Decode Speed:   {report['standard_inference']['decode_tok_s']} tok/s (Target >= 24.6 tok/s)")
    print(f"  MTP Speculative Decode:  {report['mtp_inference']['decode_tok_s']} tok/s (Functional: {report['mtp_inference']['success']})")
    print(f"  Vision Tower Generation: {report['vision_inference']['decode_tok_s']} tok/s (Functional: {report['vision_inference']['success']})")
    print(f"  Report saved:            {out_json}")
    print("=" * 80)

if __name__ == "__main__":
    main()
