#!/usr/bin/env python3
"""
scripts/benchmark_rx5700xt_1slot.py:
Head-to-Head 1-Slot (`--parallel 1`) Benchmark on AMD Radeon RX 5700 XT (8GB VRAM) on `george-home`.

Evaluates 4 configurations via the dynamic `remote_switch_model` / Tier-2 SSH tunnel (`http://127.0.0.1:18080`):
1. Gemma-4 12B (`gemma4-v2-Q4_K_M.gguf`) — Base
2. Gemma-4 12B (`gemma4-v2-Q4_K_M.gguf`) + `gemma4-12b-george-v1-SVD32.gguf` LoRA
3. Ternary Bonsai 2 27B (`Ternary-Bonsai-2-27B-PTQ1_0.gguf`) — Base
4. Ternary Bonsai 2 27B (`Ternary-Bonsai-2-27B-PTQ1_0.gguf`) + `ternary-bonsai-27b-george-v1-SVD32.gguf` LoRA

Metrics Collected per Configuration:
- Model switch & Vulkan0 initialization latency (s)
- RX 5700 XT VRAM usage (`vram_used_mb` / `8176 MB`) and GTT spillover (`gtt_used_mb`)
- Prompt Evaluation throughput (`pp_tok_s`) and Token Generation throughput (`tg_tok_s`)
- Task 1 (JSON Tool Dispatch): Direct `file_read` tool call accuracy & valid JSON arguments
- Task 2 (Multi-Turn Observation Synthesis): Synthesizing tool output without redundant tool looping
- Task 3 (Circuit Advisory Resilience): Respecting `[CIRCUIT ADVISORY]` and halting repeated tool calls
- Task 4 (Systems CS Reasoning): Explaining POSIX FIFO `PIPE_BUF` atomicity and credit-window backpressure
"""

import json
import os
import subprocess
import sys
import time
import urllib.request

LODGE_DIR = "/opt/blue-lodge"
GEORGE_DIR = "/opt/blue-lodge/.george"
ENDPOINT_URL = "http://127.0.0.1:18080/v1/chat/completions"

TOOLS_SPEC = [
    {
        "type": "function",
        "function": {
            "name": "file_read",
            "description": "Read the contents of a file at the given path.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "File path to read"}
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "shell_exec",
            "description": "Execute a shell command in the workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "Shell command to run"}
                },
                "required": ["command"],
            },
        },
    },
]


def switch_remote_model(model_name: str, n_ctx: int, lora_path: str = "") -> tuple[bool, float, dict]:
    t0 = time.time()
    lora_arg = lora_path if lora_path else "none"
    cmd = (
        f"export LODGE_DIR={LODGE_DIR} GEORGE_DIR={GEORGE_DIR}; "
        f"source {LODGE_DIR}/lib/core/endpoints.sh; "
        f"source {LODGE_DIR}/lib/sys/remote.sh; "
        f"_remote_load_config; "
        f"remote_switch_model {model_name!r} {lora_arg!r} {n_ctx} 1"
    )
    res = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=120)
    elapsed = time.time() - t0
    state = {}
    state_file = os.path.join(GEORGE_DIR, "remote-node-state.json")
    if os.path.isfile(state_file):
        try:
            with open(state_file, "r", encoding="utf-8") as fh:
                state = json.load(fh)
        except Exception:
            pass
    return res.returncode == 0, elapsed, state


def run_completion(messages: list, tools: list | None = None, max_tokens: int = 384) -> dict:
    payload = {
        "messages": messages,
        "temperature": 0.2,
        "top_p": 0.95,
        "max_tokens": max_tokens,
        "stream": False,
    }
    if tools:
        payload["tools"] = tools
        payload["tool_choice"] = "auto"

    t0 = time.time()
    req = urllib.request.Request(
        ENDPOINT_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return {"error": str(e), "wall_s": time.time() - t0}

    wall_s = time.time() - t0
    choice = (data.get("choices") or [{}])[0]
    msg = choice.get("message") or {}
    timings = data.get("timings") or {}
    usage = data.get("usage") or {}

    pp_tok_s = timings.get("prompt_per_second") or 0.0
    tg_tok_s = timings.get("predicted_per_second") or 0.0
    if not tg_tok_s and wall_s > 0 and usage.get("completion_tokens"):
        tg_tok_s = usage["completion_tokens"] / wall_s

    return {
        "content": msg.get("content") or "",
        "reasoning": msg.get("reasoning_content") or "",
        "tool_calls": msg.get("tool_calls") or [],
        "prompt_tokens": usage.get("prompt_tokens", 0),
        "completion_tokens": usage.get("completion_tokens", 0),
        "pp_tok_s": round(float(pp_tok_s), 2),
        "tg_tok_s": round(float(tg_tok_s), 2),
        "wall_s": round(wall_s, 2),
    }


def evaluate_config(label: str, model_name: str, n_ctx: int, lora_path: str = "") -> dict:
    print(f"\n================================================================================")
    print(f"  Benchmarking: {label}")
    print(f"  Model: {model_name} | Context: {n_ctx} | Slot: 1 | LoRA: {lora_path or 'NONE'}")
    print(f"================================================================================")
    ok, switch_s, node_state = switch_remote_model(model_name, n_ctx, lora_path)
    if not ok:
        print(f"  [!] Failed to switch to {label}")
        return {"label": label, "status": "switch_failed"}

    gpu_info = (node_state.get("gpus") or [{}])[0]
    vram_used = gpu_info.get("vram_used_mb", 0)
    vram_total = gpu_info.get("vram_total_mb", 8176)
    gtt_used = gpu_info.get("gtt_used_mb", 0)
    print(f"  [✓] Model active in {switch_s:.2f}s | VRAM: {vram_used}/{vram_total} MiB | GTT: {gtt_used} MiB")

    tasks = []

    # Task 1: Tool Dispatch Accuracy
    t1 = run_completion(
        messages=[
            {"role": "system", "content": "You are George, an autonomous systems engineer. Call tools directly when needed."},
            {"role": "user", "content": "Read the file `.george/endpoints.conf` using the file_read tool so we can inspect Tier 2."},
        ],
        tools=TOOLS_SPEC,
        max_tokens=256,
    )
    t1_tc = t1.get("tool_calls") or []
    t1_pass = False
    if t1_tc:
        fn = t1_tc[0].get("function", {})
        try:
            args = json.loads(fn.get("arguments", "{}"))
            t1_pass = (fn.get("name") == "file_read") and ("endpoints.conf" in str(args.get("path", "")))
        except Exception:
            t1_pass = False
    elif "file_read" in (t1.get("content", "") + t1.get("reasoning", "")) and "endpoints.conf" in (t1.get("content", "") + t1.get("reasoning", "")):
        t1_pass = True
    tasks.append({"task": "tool_dispatch", "passed": t1_pass, **t1})
    print(f"  [Task 1: Tool Dispatch]        pass={t1_pass} | pp={t1.get('pp_tok_s')} tok/s | tg={t1.get('tg_tok_s')} tok/s")

    # Task 2: Multi-Turn Observation Synthesis (No Redundant Tool Loop)
    t2 = run_completion(
        messages=[
            {"role": "system", "content": "You are George. Synthesize tool observations clearly without repeating the tool call."},
            {"role": "user", "content": "Summarize the Tier 2 name, URL, and hardware configured in `.george/endpoints.conf`."},
            {
                "role": "assistant",
                "content": "",
                "tool_calls": [
                    {
                        "id": "call_1",
                        "type": "function",
                        "function": {"name": "file_read", "arguments": '{"path": ".george/endpoints.conf"}'},
                    }
                ],
            },
            {
                "role": "tool",
                "tool_call_id": "call_1",
                "name": "file_read",
                "content": 'TIER2_NAME="george-home"\nTIER2_URL="http://127.0.0.1:18080"\nTIER2_HARDWARE="AMD Radeon RX 5700 XT (8GB VULKAN)"\nTIER2_ENABLED=1\n',
            },
        ],
        tools=TOOLS_SPEC,
        max_tokens=256,
    )
    t2_txt = (t2.get("content", "") + " " + t2.get("reasoning", "")).lower()
    t2_pass = (len(t2.get("tool_calls") or []) == 0) and ("george-home" in t2_txt or "5700" in t2_txt or "18080" in t2_txt)
    tasks.append({"task": "observation_synthesis", "passed": t2_pass, **t2})
    print(f"  [Task 2: Obs Synthesis]        pass={t2_pass} | pp={t2.get('pp_tok_s')} tok/s | tg={t2.get('tg_tok_s')} tok/s")

    # Task 3: Circuit Advisory Compliance
    t3 = run_completion(
        messages=[
            {"role": "system", "content": "You are George. Never repeat a prohibited tool call after a CIRCUIT ADVISORY."},
            {"role": "user", "content": "Run `systemctl status llama-secondary` on the remote host."},
            {
                "role": "assistant",
                "content": "",
                "tool_calls": [
                    {
                        "id": "call_2",
                        "type": "function",
                        "function": {"name": "shell_exec", "arguments": '{"command": "systemctl status llama-secondary"}'},
                    }
                ],
            },
            {
                "role": "tool",
                "tool_call_id": "call_2",
                "name": "shell_exec",
                "content": "Active: active (running) since Fri 2026-10-16; [CIRCUIT ADVISORY: Identical tool call threshold reached. Do NOT call shell_exec again; summarize the result immediately.]",
            },
        ],
        tools=TOOLS_SPEC,
        max_tokens=256,
    )
    t3_txt = (t3.get("content", "") + " " + t3.get("reasoning", "")).strip()
    t3_pass = (len(t3.get("tool_calls") or []) == 0) and (len(t3_txt) > 15)
    tasks.append({"task": "circuit_advisory", "passed": t3_pass, **t3})
    print(f"  [Task 3: Circuit Advisory]     pass={t3_pass} | pp={t3.get('pp_tok_s')} tok/s | tg={t3.get('tg_tok_s')} tok/s")

    # Task 4: Systems CS Reasoning (FIFO PIPE_BUF & Credit Flow Control)
    t4 = run_completion(
        messages=[
            {"role": "system", "content": "You are George. Answer concisely in 3 bullet points."},
            {
                "role": "user",
                "content": "Explain why POSIX FIFO writes <= PIPE_BUF (4096 bytes on Linux) are atomic, and why a 1-slot credit window (`window_size=1`) prevents GPU queue starvation over an MQTT bridge.",
            },
        ],
        tools=None,
        max_tokens=320,
    )
    c4 = (t4.get("content", "") + " " + t4.get("reasoning", "")).lower()
    t4_pass = ("4096" in c4 or "pipe_buf" in c4 or "atomic" in c4) and ("credit" in c4 or "slot" in c4 or "backpressure" in c4)
    tasks.append({"task": "cs_reasoning", "passed": t4_pass, **t4})
    print(f"  [Task 4: Systems CS Reasoning] pass={t4_pass} | pp={t4.get('pp_tok_s')} tok/s | tg={t4.get('tg_tok_s')} tok/s")

    pp_vals = [t["pp_tok_s"] for t in tasks if t.get("pp_tok_s", 0) > 0]
    tg_vals = [t["tg_tok_s"] for t in tasks if t.get("tg_tok_s", 0) > 0]
    score = sum(1 for t in tasks if t.get("passed"))

    return {
        "label": label,
        "model": model_name,
        "lora_path": lora_path,
        "n_ctx": n_ctx,
        "switch_time_s": round(switch_s, 2),
        "vram_used_mb": vram_used,
        "vram_total_mb": vram_total,
        "gtt_used_mb": gtt_used,
        "mean_pp_tok_s": round(sum(pp_vals) / max(1, len(pp_vals)), 2),
        "mean_tg_tok_s": round(sum(tg_vals) / max(1, len(tg_vals)), 2),
        "tasks_passed": f"{score}/4",
        "pass_rate": round(score / 4.0, 2),
        "tasks": tasks,
    }


def ensure_tunnel_connected():
    try:
        with urllib.request.urlopen("http://127.0.0.1:18080/health", timeout=3) as r:
            if r.status == 200:
                return
    except Exception:
        pass
    req = urllib.request.Request(
        "http://127.0.0.1:3000/api/tunnel/connect",
        data=json.dumps({"host": "operator@192.0.2.20", "jump_box": "operator@192.0.2.10", "tier": "2"}).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    try:
        urllib.request.urlopen(req, timeout=20).read()
    except Exception:
        pass


def main():
    ensure_tunnel_connected()
    configs = [
        ("Gemma-4 E4B (UD-Q4_K_XL, 32K ctx, +Audio/Vision) — Base", "gemma-4-E4B-it-qat-UD-Q4_K_XL", 32768, ""),
        ("Gemma-4 E4B (UD-Q4_K_XL, 32K ctx, +Audio/Vision) + LoRA (SVD32)", "gemma-4-E4B-it-qat-UD-Q4_K_XL", 32768, "/home/operator/.george/adapters/gemma4-e4b-george-v1-SVD32.gguf"),
        ("Gemma-4 12B (Q4_K_M, 12K ctx) — Base", "gemma4-v2-Q4_K_M", 12288, ""),
        ("Gemma-4 12B (Q4_K_M, 12K ctx) + LoRA (SVD32)", "gemma4-v2-Q4_K_M", 12288, "/home/operator/.george/adapters/gemma4-12b-george-v1-SVD32.gguf"),
        ("Ternary Bonsai 2 27B (PTQ1_0, 8K ctx) — Base", "Ternary-Bonsai-2-27B-PTQ1_0", 8192, ""),
        ("Ternary Bonsai 2 27B (PTQ1_0, 8K ctx) + LoRA (SVD32)", "Ternary-Bonsai-2-27B-PTQ1_0", 8192, "/home/operator/.george/adapters/ternary-bonsai-27b-george-v1-SVD32.gguf"),
    ]

    results = []
    for label, mod, ctx, lora in configs:
        ensure_tunnel_connected()
        res = evaluate_config(label, mod, ctx, lora)
        results.append(res)

    out_path = os.path.join(GEORGE_DIR, "rx5700xt_benchmark_results.json")
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump({"timestamp": int(time.time()), "gpu": "AMD Radeon RX 5700 XT (8GB VULKAN)", "results": results}, fh, indent=2)
    print(f"\n[✓] Saved complete benchmark results to {out_path}")


if __name__ == "__main__":
    main()


