#!/usr/bin/env python3
import subprocess
import time
import re

def get_gpu1_vram_mb():
    try:
        res = subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits", "-i", "1"],
            capture_output=True, text=True, check=True
        )
        return float(res.stdout.strip())
    except Exception as e:
        return 0.0

def measure_run(cmd_args, label):
    vram_baseline = get_gpu1_vram_mb()
    print(f"\n=======================================================")
    print(f"Measuring VRAM: {label}")
    print(f"GPU 1 Baseline VRAM (idle/Xwayland): {vram_baseline:.1f} MiB ({vram_baseline/1024:.2f} GB)")
    
    cmd = [
        "docker", "exec",
        "-e", "CUDA_VISIBLE_DEVICES=1",
        "george-prism-server",
        "/workspace/build_prism/llama.cpp-prism/build/bin/llama-cli"
    ] + cmd_args

    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    peak_vram = vram_baseline
    
    t0 = time.time()
    while proc.poll() is None:
        curr = get_gpu1_vram_mb()
        if curr > peak_vram:
            peak_vram = curr
        time.sleep(0.05)
        if time.time() - t0 > 60:
            proc.kill()
            break
            
    out, err = proc.communicate()
    model_vram = peak_vram - vram_baseline
    print(f"Peak Total GPU 1 VRAM: {peak_vram:.1f} MiB ({peak_vram/1024:.2f} GB)")
    print(f"Dedicated Model VRAM:  {model_vram:.1f} MiB ({model_vram/1024:.2f} GB)")
    
    # speed
    m_tg = re.search(r"Generation:\s+([0-9\.]+)\s+t/s", out + err)
    tg_speed = float(m_tg.group(1)) if m_tg else 0.0
    print(f"Decode Speed:          {tg_speed:.1f} t/s")
    return {
        "label": label,
        "peak_vram_gb": round(peak_vram/1024, 2),
        "model_vram_gb": round(model_vram/1024, 2),
        "decode_tok_s": tg_speed
    }

def main():
    # 1. Base Dense PTQ1_0
    measure_run([
        "-m", "/models/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf",
        "-ngl", "99", "-c", "512", "-n", "16", "-p", "Hello world", "--single-turn"
    ], "Dense PTQ1_0 Lean Base")

    # 2. Base Dense PTQ1_0 + MTP Draft
    measure_run([
        "-m", "/models/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf",
        "-md", "/models/frontier_qwen38/MTP/mtp-Qwen3.8-27B-Q4_0.gguf",
        "--spec-type", "draft-mtp",
        "-ngl", "99", "-ngld", "99", "-c", "512", "-n", "16", "-p", "Hello world", "--single-turn"
    ], "Dense PTQ1_0 Base + MTP Draft")

    # 3. Base Dense PTQ1_0 + Vision Tower
    measure_run([
        "-m", "/models/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf",
        "--mmproj", "/models/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf",
        "--image", "/workspace/.george/MooseFergie.jpg",
        "-ngl", "99", "-c", "512", "-n", "16", "-p", "Describe", "--single-turn"
    ], "Dense PTQ1_0 Base + Vision Tower")

    # 4. Sparse QAT Full Base Model
    measure_run([
        "-m", "/models/frontier_qwen38/Qwen3.8-27B-SPTQ1_0-QAT-Full.gguf",
        "-ngl", "99", "-c", "512", "-n", "16", "-p", "Hello world", "--single-turn", "--ignore-eos"
    ], "Sparse SPTQ1_0 QAT-Full Base")

    # 5. Sparse QAT Full Base + MTP Draft
    measure_run([
        "-m", "/models/frontier_qwen38/Qwen3.8-27B-SPTQ1_0-QAT-Full.gguf",
        "-md", "/models/frontier_qwen38/MTP/mtp-Qwen3.8-27B-Q4_0.gguf",
        "--spec-type", "draft-mtp",
        "-ngl", "99", "-ngld", "99", "-c", "512", "-n", "16", "-p", "Hello world", "--single-turn", "--ignore-eos"
    ], "Sparse SPTQ1_0 QAT-Full + MTP Draft")

    # 6. Sparse QAT Full Base + Vision Tower
    measure_run([
        "-m", "/models/frontier_qwen38/Qwen3.8-27B-SPTQ1_0-QAT-Full.gguf",
        "--mmproj", "/models/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf",
        "--image", "/workspace/.george/MooseFergie.jpg",
        "-ngl", "99", "-c", "512", "-n", "16", "-p", "Describe", "--single-turn", "--ignore-eos"
    ], "Sparse SPTQ1_0 QAT-Full + Vision Tower")

if __name__ == "__main__":
    main()
