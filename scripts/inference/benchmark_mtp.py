#!/usr/bin/env python3
import os
import sys
import time
import subprocess
import requests

SERVER_URL = "http://127.0.0.1:8080"
PROMPT = "Write a comprehensive Python class implementing a doubly linked list with insert, delete, reverse, and iterator methods."

def wait_for_server(timeout=45):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            r = requests.get(f"{SERVER_URL}/health", timeout=1)
            if r.status_code == 200 and "ok" in r.text.lower():
                return True
        except Exception:
            pass
        time.sleep(1)
    return False

def query_benchmark(n_tokens=200):
    payload = {
        "messages": [{"role": "user", "content": PROMPT}],
        "max_tokens": n_tokens,
        "temperature": 0.0,
        "stream": False
    }
    r = requests.post(f"{SERVER_URL}/v1/chat/completions", json=payload, timeout=90)
    data = r.json()
    timings = data.get("timings", {})
    return {
        "tok_s": timings.get("predicted_per_second", 0.0),
        "ms": timings.get("predicted_ms", 0.0),
        "n_tokens": timings.get("predicted_n", 0),
        "draft_n": timings.get("draft_n", 0),
        "draft_accepted": timings.get("draft_n_accepted", 0),
    }

def run_config(name, env_vars):
    print(f"\n[+] Applying configuration: {name}...")
    full_env = os.environ.copy()
    full_env.update(env_vars)
    subprocess.run(
        ["docker", "compose", "up", "-d", "prism-inference"],
        cwd=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        env=full_env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True
    )
    if not wait_for_server():
        print(f"[!] Server failed to boot for {name}")
        return None
    
    # Warmup query
    try:
        requests.post(f"{SERVER_URL}/v1/chat/completions", json={"messages": [{"role": "user", "content": "hello"}], "max_tokens": 5}, timeout=15)
    except Exception:
        pass
    
    # Benchmark query
    res = query_benchmark(200)
    draft_n = res["draft_n"]
    accepted = res["draft_accepted"]
    acc_pct = (accepted / draft_n * 100) if draft_n > 0 else 0.0
    print(f"    Speed: {res['tok_s']:.2f} tok/s | Time: {res['ms']:.1f}ms | Drafted: {draft_n} | Accepted: {accepted} ({acc_pct:.1f}%)")
    res["name"] = name
    res["acc_pct"] = acc_pct
    return res

if __name__ == "__main__":
    configs = [
        ("Baseline (No MTP)", {"ENABLE_MTP": "0"}),
        ("MTP (n_max=1)", {"ENABLE_MTP": "1", "LLAMA_ARG_SPEC_DRAFT_N_MAX": "1"}),
        ("MTP (n_max=2)", {"ENABLE_MTP": "1", "LLAMA_ARG_SPEC_DRAFT_N_MAX": "2"}),
        ("MTP (n_max=3)", {"ENABLE_MTP": "1", "LLAMA_ARG_SPEC_DRAFT_N_MAX": "3"}),
        ("MTP (n_max=4)", {"ENABLE_MTP": "1", "LLAMA_ARG_SPEC_DRAFT_N_MAX": "4"}),
    ]

    results = []
    for name, env_vars in configs:
        res = run_config(name, env_vars)
        if res:
            results.append(res)
    
    baseline_speed = results[0]["tok_s"] if results else 1.0

    print("\n" + "=" * 78)
    print(f"{'Configuration':<25} | {'Speed (tok/s)':<14} | {'Speedup':<10} | {'Draft Acc %':<12}")
    print("-" * 78)
    for r in results:
        speedup = r["tok_s"] / baseline_speed if baseline_speed > 0 else 1.0
        acc_str = f"{r['acc_pct']:.1f}%" if r["draft_n"] > 0 else "N/A"
        print(f"{r['name']:<25} | {r['tok_s']:<14.2f} | {speedup:<9.2f}x | {acc_str:<12}")
    print("=" * 78)

    # Restore optimal or default setting (n_max=2 or best)
    best = max(results, key=lambda x: x["tok_s"])
    print(f"\n[★] Best performing configuration: {best['name']} at {best['tok_s']:.2f} tok/s")
