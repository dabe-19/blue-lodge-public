#!/usr/bin/env python3
"""
scripts/stress_test_context.py
Hardware VRAM & Context Ladder Stress-Test for Dual RTX 3060 PRISM Inference Fabric.
Systematically tests increasing context token depths to measure VRAM saturation,
tensor split balance (GPU 0 vs GPU 1), and maximum stable context ceiling.
"""

import sys
import time
import json
import subprocess
import threading
import urllib.request
import urllib.error

ENDPOINT = "http://127.0.0.1:8080/v1/chat/completions"

def get_gpu_memory():
    """Returns (gpu0_used_mb, gpu1_used_mb) in MiB."""
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
            stderr=subprocess.DEVNULL
        ).decode().strip().splitlines()
        if len(out) >= 2:
            return int(out[0]), int(out[1])
        elif len(out) == 1:
            return int(out[0]), 0
    except Exception:
        pass
    return 0, 0

class VramSampler(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.running = True
        self.peak_gpu0 = 0
        self.peak_gpu1 = 0

    def run(self):
        while self.running:
            g0, g1 = get_gpu_memory()
            if g0 > self.peak_gpu0:
                self.peak_gpu0 = g0
            if g1 > self.peak_gpu1:
                self.peak_gpu1 = g1
            time.sleep(0.1)

    def stop(self):
        self.running = False

def run_context_step(target_tokens):
    # base_phrase is exactly 15 tokens
    base_phrase = "The craftsman meticulously shapes each sovereign boundary with precision and vigilance. "
    repeat_count = max(1, int(target_tokens / 15))
    prompt_body = f"Context payload start.\n{base_phrase * repeat_count}\nAnswer in one word: What did the craftsman shape?"

    payload = {
        "messages": [
            {"role": "system", "content": "You are a concise testing evaluator."},
            {"role": "user", "content": prompt_body}
        ],
        "max_tokens": 10,
        "temperature": 0.1,
        "stream": False
    }

    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(ENDPOINT, data=data, headers={"Content-Type": "application/json"})

    sampler = VramSampler()
    sampler.start()
    t0 = time.time()

    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            elapsed = time.time() - t0
            sampler.stop()
            sampler.join(timeout=0.5)

            body = json.loads(resp.read().decode())
            usage = body.get("usage", {})
            actual_prompt = usage.get("prompt_tokens", target_tokens)
            answer = body.get("choices", [{}])[0].get("message", {}).get("content", "").strip()
            tps = actual_prompt / elapsed if elapsed > 0 else 0

            return {
                "success": True,
                "actual_tokens": actual_prompt,
                "elapsed": elapsed,
                "tps": tps,
                "gpu0_peak": sampler.peak_gpu0,
                "gpu1_peak": sampler.peak_gpu1,
                "answer": answer
            }
    except Exception as e:
        elapsed = time.time() - t0
        sampler.stop()
        sampler.join(timeout=0.5)
        return {
            "success": False,
            "actual_tokens": target_tokens,
            "elapsed": elapsed,
            "tps": 0,
            "gpu0_peak": sampler.peak_gpu0,
            "gpu1_peak": sampler.peak_gpu1,
            "error": str(e)
        }

def main():
    print("=" * 82)
    print("🏛️  BLUE LODGE PRISM CONTEXT LADDER & TENSOR SPLIT STRESS TEST")
    print("Dual RTX 3060 (2x12GB) | Target Model: Ternary-Bonsai-27B (PTQ1_0 / MTP)")
    print("=" * 82)

    # Accurate token ladder pushing past 33k all the way up to 62k tokens!
    ladder = [16384, 28000, 33204, 45000, 55000, 62000]

    header = f"{'Target':>8} | {'Actual Tok':>10} | {'GPU 0 (MB)':>15} | {'GPU 1 (MB)':>15} | {'Prefill':>7} | {'Speed':>9} | {'Status':>8}"
    print(header)
    print("-" * len(header))

    for target in ladder:
        res = run_context_step(target)
        g0_str = f"{res['gpu0_peak']}/12288"
        g1_str = f"{res['gpu1_peak']}/12288"
        time_str = f"{res['elapsed']:.1f}s"
        tps_str = f"{res['tps']:.1f} t/s"

        if res["success"]:
            status = "✅ PASS"
            print(f"{target:>8} | {res['actual_tokens']:>10} | {g0_str:>15} | {g1_str:>15} | {time_str:>7} | {tps_str:>9} | {status:>8}")
        else:
            status = "❌ FAIL"
            print(f"{target:>8} | {res['actual_tokens']:>10} | {g0_str:>15} | {g1_str:>15} | {time_str:>7} | {'--':>9} | {status:>8}")
            print(f"   ↳ Error: {res.get('error', 'unknown')}")
            break

        # Settle memory between runs
        time.sleep(2)

    print("=" * 82)
    print("Stress test complete.")

if __name__ == "__main__":
    main()
