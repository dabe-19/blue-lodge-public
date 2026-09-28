#!/usr/bin/env python3
"""
07_evaluate_multiturn_benchmark.py:
Comprehensive Blue Lodge Multi-Turn Sovereign Benchmark Suite (BlueLodgeMultiTurnBench).

Evaluates George's capability to execute complex multi-turn action chains where
each step's observation dynamically leads into subsequent objectives:

Pillars (30 Rigorous Multi-Stage Scenarios):
1. Multi-Turn Web Research & Fetch-to-Synthesis Chaining (5 scenarios)
2. Multi-Turn Code Inspection, Surgical Edit & Validation (5 scenarios)
3. Chained Multi-Objective Pipeline: Research -> Implement -> Test (5 scenarios)
4. Multi-File Project Scaffold & Test Execution (5 scenarios)
5. Sovereign GitOps Lifecycle: Status -> Branch -> Commit -> Push (5 scenarios)
6. Dependency Discovery, Pinned Install & Runtime Import (5 scenarios)

Each scenario runs 2 to 3 interactive turns against the endpoint, supplying real
observation payloads and evaluating whether the model maintains working memory,
executes the golden path action chain, and delivers the terminal objective.
"""

import os
import sys
import json
import time
import argparse
import urllib.request
from typing import List, Dict, Any, Tuple

RESULTS_DIR = "/home/wsl-ops/blue-lodge/benchmarks/results"
os.makedirs(RESULTS_DIR, exist_ok=True)

def parse_args():
    parser = argparse.ArgumentParser(description="Blue Lodge Multi-Turn Benchmark")
    parser.add_argument("--endpoint", type=str, default="http://127.0.0.1:8080", help="Model endpoint URL")
    parser.add_argument("--model_label", type=str, default="Champion-v12", help="Model label")
    parser.add_argument("--output", type=str, default=None, help="Output scorecard JSON path")
    return parser.parse_args()

def query_endpoint(endpoint_url: str, messages: list, tools: list = None, max_tokens: int = 4096) -> dict:
    url = f"{endpoint_url}/v1/chat/completions"
    payload = {
        "messages": messages,
        "temperature": 0.0,
        "top_p": 0.95,
        "top_k": 20,
        "min_p": 0.0,
        "repeat_penalty": 1.0,
        "frequency_penalty": 0.0,
        "presence_penalty": 0.0,
        "max_tokens": max_tokens,
        "reasoning_effort": "medium",
        "chat_template_kwargs": {"preserve_thinking": True},
        "stop": ["<|im_end|>", "</tool_call>", "<|endoftext|>"],
        "stream": False
    }
    if tools:
        payload["tools"] = tools
        payload["tool_choice"] = "auto"
    else:
        payload["tool_choice"] = "none"

    t0 = time.time()
    try:
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=240) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            elapsed = time.time() - t0
            choice = data.get("choices", [{}])[0]
            msg = choice.get("message", {})
            return {
                "success": True,
                "content": msg.get("content", ""),
                "reasoning": msg.get("reasoning_content", ""),
                "tool_calls": msg.get("tool_calls", []),
                "elapsed": elapsed
            }
    except Exception as e:
        return {"success": False, "error": str(e), "elapsed": time.time() - t0}

def get_bedrock_tools():
    tools_path = "/home/wsl-ops/blue-lodge/data/training/native_core_tools.json"
    if os.path.exists(tools_path):
        try:
            with open(tools_path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    # Minimal fallback schema
    return [
        {
            "type": "function",
            "function": {
                "name": "bash_exec",
                "description": "Execute shell command in workspace",
                "parameters": {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}
            }
        },
        {
            "type": "function",
            "function": {
                "name": "web_search",
                "description": "Search the web for technical documentation",
                "parameters": {"type": "object", "properties": {"query": {"type": "string"}, "count": {"type": "integer"}}, "required": ["query"]}
            }
        },
        {
            "type": "function",
            "function": {
                "name": "web_fetch",
                "description": "Fetch markdown content of a URL",
                "parameters": {"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]}
            }
        },
        {
            "type": "function",
            "function": {
                "name": "file_read",
                "description": "Read contents of a file",
                "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}
            }
        },
        {
            "type": "function",
            "function": {
                "name": "file_edit",
                "description": "Surgically edit existing file using sed expression",
                "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "expression": {"type": "string"}}, "required": ["path", "expression"]}
            }
        },
        {
            "type": "function",
            "function": {
                "name": "file_write",
                "description": "Write a brand new file",
                "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]}
            }
        },
        {
            "type": "function",
            "function": {
                "name": "file_grep",
                "description": "Search for pattern inside files",
                "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "pattern": {"type": "string"}}, "required": ["path", "pattern"]}
            }
        }
    ]

# ─────────────────────────────────────────────────────────────────────────────
# 30 Multi-Turn Benchmark Scenarios
# ─────────────────────────────────────────────────────────────────────────────

def get_multiturn_scenarios():
    return {
        "Pillar 1: Multi-Turn Web Research & Fetch-to-Synthesis Chaining": [
            {
                "id": "web_01",
                "name": "EAGLE Speculative Decoding Research Chain",
                "turn1_prompt": "Research the EAGLE speculative decoding architecture. Search for technical benchmarks and identify the primary paper.",
                "turn1_expected_tool": "web_search",
                "turn1_obs": "[1] EAGLE: Speculative Sampling Requires Rethinking Feature Uncertainty\n    URL: https://arxiv.org/abs/2401.15077\n    Snippet: EAGLE demonstrates 2.5x speedup by drafting auto-regressively on top hidden states.",
                "turn2_prompt": "Fetch the primary paper at https://arxiv.org/abs/2401.15077 using web_fetch.",
                "turn2_expected_tool": "web_fetch",
                "turn2_expected_url_substr": "arxiv.org/abs/2401.15077",
                "turn2_obs": "# EAGLE Architecture Paper\nAuthors: Li et al.\nKey Result: 2.2x to 2.8x speedup on LLaMA-2/3 models without quality degradation.",
                "turn3_prompt": "Synthesize the benchmark speedups and key results from the EAGLE paper.",
                "turn3_completion_substr": ["2.2x", "2.8x", "speedup", "EAGLE"]
            },
            {
                "id": "web_02",
                "name": "vLLM Chunked Prefill Throughput Investigation",
                "turn1_prompt": "Search documentation for vLLM chunked prefill configuration and throughput impact.",
                "turn1_expected_tool": "web_search",
                "turn1_obs": "[1] Chunked Prefill in vLLM - Official Guide\n    URL: https://docs.vllm.ai/en/latest/models/chunked_prefill.html\n    Snippet: How chunked prefill enables concurrent prefill and decode while bounding TTFT.",
                "turn2_expected_tool": "web_fetch",
                "turn2_expected_url_substr": "docs.vllm.ai",
                "turn2_obs": "# vLLM Chunked Prefill\nEnable with --enable-chunked-prefill. Reduces inter-token latency spikes by chunking long prompt sequences.",
                "turn3_prompt": "Synthesize your findings regarding vLLM chunked prefill configuration and latency impact.",
                "turn3_completion_substr": ["enable-chunked-prefill", "prefill", "latency"]
            },
            {
                "id": "web_03",
                "name": "POSIX FIFO Atomic Buffer Limits Investigation",
                "turn1_prompt": "Search the web for Linux pipe buffer capacity and atomic write size guarantees.",
                "turn1_expected_tool": "web_search",
                "turn1_obs": "[1] pipe(7) - Linux Manual Page\n    URL: https://man7.org/linux/man-pages/man7/pipe.7.html\n    Snippet: POSIX.1 requires PIPE_BUF to be at least 512 bytes; on Linux PIPE_BUF is 4096 bytes.",
                "turn2_expected_tool": "web_fetch",
                "turn2_expected_url_substr": "man7.org",
                "turn2_obs": "PIPE_BUF: Writes of up to PIPE_BUF bytes must be atomic. On Linux, PIPE_BUF is 4096 bytes. The default pipe capacity is 65536 bytes.",
                "turn3_prompt": "Synthesize your findings on Linux pipe buffer capacity and PIPE_BUF atomic guarantees.",
                "turn3_completion_substr": ["4096", "PIPE_BUF", "atomic"]
            },
            {
                "id": "web_04",
                "name": "Mamba-2 State Space Model Benchmark Analysis",
                "turn1_prompt": "Search for Mamba-2 state space model architecture paper and memory complexity.",
                "turn1_expected_tool": "web_search",
                "turn1_obs": "[1] Transformers are SSMs: Generalized Models and Efficient Algorithms Through Structured State Space Duality\n    URL: https://arxiv.org/abs/2405.21060\n    Snippet: Mamba-2 connects SSMs with linear attention via SSD algorithm.",
                "turn2_prompt": "Fetch the Mamba-2 paper at https://arxiv.org/abs/2405.21060 using web_fetch.",
                "turn2_expected_tool": "web_fetch",
                "turn2_expected_url_substr": "arxiv.org",
                "turn2_obs": "Mamba-2 SSD introduces structured state space duality, achieving 2-8x faster training via matrix multiply primitives.",
                "turn3_prompt": "Synthesize the core findings on Mamba-2 SSD linear attention duality.",
                "turn3_completion_substr": ["SSD", "state space", "linear attention"]
            },
            {
                "id": "web_05",
                "name": "Gitea API Pull Request Merging Reference",
                "turn1_prompt": "Search the Gitea REST API reference for the endpoint to merge an existing pull request.",
                "turn1_expected_tool": "web_search",
                "turn1_obs": "[1] Gitea API Reference - Pull Requests\n    URL: https://docs.gitea.com/api/v1/pulls\n    Snippet: POST /api/v1/repos/{owner}/{repo}/pulls/{index}/merge performs automated pull request merge.",
                "turn2_prompt": "Fetch the Gitea PR API reference from https://docs.gitea.com/api/v1/pulls using web_fetch.",
                "turn2_expected_tool": "web_fetch",
                "turn2_expected_url_substr": "docs.gitea.com",
                "turn2_obs": "Endpoint: POST /repos/{owner}/{repo}/pulls/{index}/merge\nBody: {\"Do\": \"merge\", \"MergeTitleField\": \"...\", \"delete_branch_after_merge\": false}",
                "turn3_prompt": "Synthesize the REST endpoint and parameters required to merge a pull request in Gitea.",
                "turn3_completion_substr": ["/merge", "POST", "pulls"]
            }
        ],
        "Pillar 2: Multi-Turn Code Inspection, Surgical Edit & Validation": [
            {
                "id": "code_01",
                "name": "fifo_await Deadlock Safeguard Inspection & Patch",
                "turn1_prompt": "Search for the function `fifo_await` in `lib/fifo_ipc.sh` using file_grep.",
                "turn1_expected_tool": "file_grep",
                "turn1_obs": "lib/fifo_ipc.sh:406:fifo_await() {\nlib/fifo_ipc.sh:430:        st=$(jq -r '.status' \"$prom_file\")\nlib/fifo_ipc.sh:435:        return \"${ec:-0}\"",
                "turn2_prompt": "Apply deadlock safeguard patch to fifo_await in lib/fifo_ipc.sh using file_edit.",
                "turn2_expected_tool": "file_edit",
                "turn2_expected_file": "lib/fifo_ipc.sh",
                "turn2_obs": "Successfully applied expression to lib/fifo_ipc.sh.",
                "turn3_prompt": "Now validate the bash syntax of lib/fifo_ipc.sh using bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["bash -n lib/fifo_ipc.sh"]
            },
            {
                "id": "code_02",
                "name": "phytology_probe Telemetry Syntax Repair",
                "turn1_prompt": "Inspect `phytology_probe` in `lib/phytology.sh` using file_grep to locate syntax error.",
                "turn1_expected_tool": "file_grep",
                "turn1_obs": "lib/phytology.sh:120:phytology_probe() {\nlib/phytology.sh:125:    local status_json=$(jq -n ...)\nlib/phytology.sh:130:}",
                "turn2_prompt": "Apply syntax repair patch to phytology_probe in lib/phytology.sh using file_edit.",
                "turn2_expected_tool": "file_edit",
                "turn2_expected_file": "lib/phytology.sh",
                "turn2_obs": "Successfully applied expression to lib/phytology.sh.",
                "turn3_prompt": "Run the regression test suite tests/test_phytology.sh via bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["test_phytology.sh"]
            },
            {
                "id": "code_03",
                "name": "Circuit Breaker Stty Reset on Trip",
                "turn1_prompt": "Search for `_react_trip_circuit_breaker` in `lib/react.sh`.",
                "turn1_expected_tool": "file_grep",
                "turn1_obs": "lib/react.sh:85:_react_trip_circuit_breaker() {\nlib/react.sh:90:    echo '[CIRCUIT BREAKER] Tripped' >&2\nlib/react.sh:95:}",
                "turn2_prompt": "Update lib/react.sh to reset stty on circuit breaker trip using file_edit.",
                "turn2_expected_tool": "file_edit",
                "turn2_expected_file": "lib/react.sh",
                "turn2_obs": "Successfully applied sed expression to lib/react.sh.",
                "turn3_prompt": "Check bash syntax of lib/react.sh with bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["bash -n lib/react.sh"]
            },
            {
                "id": "code_04",
                "name": "FIFO Flow Control Auto-Recovery Patch",
                "turn1_prompt": "Inspect `fifo_flow_acquire` in `lib/fifo_ipc.sh` using file_grep.",
                "turn1_expected_tool": "file_grep",
                "turn1_obs": "lib/fifo_ipc.sh:125:fifo_flow_acquire() {\nlib/fifo_ipc.sh:155:        [ \"$elapsed\" -ge \"$timeout\" ] && return 110",
                "turn2_prompt": "Apply auto-recovery patch to fifo_flow_acquire in lib/fifo_ipc.sh using file_edit.",
                "turn2_expected_tool": "file_edit",
                "turn2_expected_file": "lib/fifo_ipc.sh",
                "turn2_obs": "Successfully updated lib/fifo_ipc.sh.",
                "turn3_prompt": "Run tests/test_fifo_ipc.sh using bash_exec to verify regression.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["tests/test_fifo_ipc.sh"]
            },
            {
                "id": "code_05",
                "name": "Subagent Await Worker PID Check",
                "turn1_prompt": "Search for `subagent_await` in `lib/native_tools.sh` using file_grep.",
                "turn1_expected_tool": "file_grep",
                "turn1_obs": "lib/native_tools.sh:210:subagent_await() {\nlib/native_tools.sh:225:    while [ ! -f \"$status_file\" ]; do sleep 0.1; done",
                "turn2_prompt": "Apply worker PID check patch to subagent_await in lib/native_tools.sh using file_edit.",
                "turn2_expected_tool": "file_edit",
                "turn2_expected_file": "lib/native_tools.sh",
                "turn2_obs": "Successfully modified lib/native_tools.sh.",
                "turn3_prompt": "Validate bash syntax of lib/native_tools.sh using bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["bash -n lib/native_tools.sh"]
            }
        ],
        "Pillar 3: Chained Multi-Objective: Research -> Implement -> Test": [
            {
                "id": "chain_01",
                "name": "Discord Webhook Rate Limits: Research -> Script -> Test",
                "turn1_prompt": "Step 1 of 3: Research Discord webhook rate limits per channel.",
                "turn1_expected_tool": "web_search",
                "turn1_obs": "[1] Discord API Rate Limits\n    URL: https://discord.com/developers/docs/topics/rate-limits\n    Snippet: Webhooks allow 5 requests per 2 seconds per channel. HTTP 429 returns retry_after.",
                "turn2_prompt": "Step 2 of 3: Create a concise helper script `scripts/discord_pacer.sh` with sleep pacing using file_write.",
                "turn2_expected_tool": "file_write",
                "turn2_expected_file": "scripts/discord_pacer.sh",
                "turn2_obs": "Successfully wrote 120 bytes to scripts/discord_pacer.sh.",
                "turn3_prompt": "Step 3 of 3: Execute bash -n on scripts/discord_pacer.sh using bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["bash -n scripts/discord_pacer.sh"]
            },
            {
                "id": "chain_02",
                "name": "Gitea API Token Auth: Research -> Script -> Verify",
                "turn1_prompt": "Step 1 of 3: Research Gitea API authorization header format.",
                "turn1_expected_tool": "web_search",
                "turn1_obs": "[1] Gitea Authentication Documentation\n    URL: https://docs.gitea.com/development/api-usage\n    Snippet: Authenticate via Authorization: token <YOUR_ACCESS_TOKEN> header.",
                "turn2_prompt": "Step 2 of 3: Create `scripts/gitea_whoami.sh` using file_write.",
                "turn2_expected_tool": "file_write",
                "turn2_expected_file": "scripts/gitea_whoami.sh",
                "turn2_obs": "Successfully created scripts/gitea_whoami.sh.",
                "turn3_prompt": "Step 3 of 3: Run bash -n on scripts/gitea_whoami.sh.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["bash -n scripts/gitea_whoami.sh"]
            },
            {
                "id": "chain_03",
                "name": "MTP Speculative Heads: Research -> Config -> Validate",
                "turn1_prompt": "Step 1 of 3: Search llama-server documentation for --spec-type draft-mtp flags.",
                "turn1_expected_tool": "web_search",
                "turn1_obs": "[1] llama.cpp Speculative Decoding\n    URL: https://github.com/ggerganov/llama.cpp\n    Snippet: Mount MTP draft model using --spec-type draft-mtp --draft-max 2.",
                "turn2_prompt": "Step 2 of 3: Write concise `configs/spec_config.json` with draft-mtp settings using file_write.",
                "turn2_expected_tool": "file_write",
                "turn2_expected_file": "configs/spec_config.json",
                "turn2_obs": "Wrote configs/spec_config.json successfully.",
                "turn3_prompt": "Step 3 of 3: Validate JSON formatting of configs/spec_config.json with jq using bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["jq . configs/spec_config.json"]
            },
            {
                "id": "chain_04",
                "name": "POSIX FIFO Flush: Research -> Patch -> Test",
                "turn1_prompt": "Step 1 of 3: Search how to drain a non-blocking FIFO in bash.",
                "turn1_expected_tool": "web_search",
                "turn1_obs": "[1] Non-blocking FIFO read in bash\n    URL: https://stackoverflow.com/questions/non-blocking-fifo\n    Snippet: Use read -t 0.05 -r line <> /path/to/fifo inside a while loop to drain pending data.",
                "turn2_prompt": "Step 2 of 3: Modify `lib/fifo_ipc.sh` to add fifo_channel_flush using file_edit.",
                "turn2_expected_tool": "file_edit",
                "turn2_expected_file": "lib/fifo_ipc.sh",
                "turn2_obs": "Applied expression to lib/fifo_ipc.sh successfully.",
                "turn3_prompt": "Step 3 of 3: Run ./tests/test_fifo_ipc.sh via bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["test_fifo_ipc.sh"]
            },
            {
                "id": "chain_05",
                "name": "Gitea Branch Protection Rules: Research -> Script -> Validate",
                "turn1_prompt": "Step 1 of 3: Search Gitea documentation for branch protection rule API payload.",
                "turn1_expected_tool": "web_search",
                "turn1_obs": "[1] Gitea Branch Protection API\n    URL: https://docs.gitea.com/api/v1/branch_protections\n    Snippet: POST /repos/{owner}/{repo}/branch_protections allows setting enable_push: false.",
                "turn2_prompt": "Step 2 of 3: Create `scripts/protect_develop.sh` using file_write.",
                "turn2_expected_tool": "file_write",
                "turn2_expected_file": "scripts/protect_develop.sh",
                "turn2_obs": "File scripts/protect_develop.sh written.",
                "turn3_prompt": "Step 3 of 3: Check syntax with bash -n via bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["bash -n scripts/protect_develop.sh"]
            }
        ],
        "Pillar 4: Multi-File Project Scaffold & Test Execution": [
            {
                "id": "scaffold_01",
                "name": "Scaffold Micro Benchmark Runner",
                "turn1_prompt": "Create directory structure `benchmarks/micro/src` and `benchmarks/micro/tests` using bash_exec.",
                "turn1_expected_tool": "bash_exec",
                "turn1_command_substr": ["benchmarks/micro/src"],
                "turn1_obs": "Directories created successfully.",
                "turn2_prompt": "Create a concise benchmark runner in `benchmarks/micro/src/runner.py` using file_write.",
                "turn2_expected_tool": "file_write",
                "turn2_expected_file": "benchmarks/micro/src/runner.py",
                "turn2_obs": "Wrote 240 bytes to benchmarks/micro/src/runner.py.",
                "turn3_prompt": "Execute python3 -m py_compile benchmarks/micro/src/runner.py via bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["py_compile benchmarks/micro/src/runner.py"]
            },
            {
                "id": "scaffold_02",
                "name": "Scaffold Log Rotator Module",
                "turn1_prompt": "Create directories `modules/rotator/bin` and `modules/rotator/conf` using bash_exec.",
                "turn1_expected_tool": "bash_exec",
                "turn1_command_substr": ["modules/rotator/bin"],
                "turn1_obs": "Created directory tree.",
                "turn2_prompt": "Write `modules/rotator/bin/rotator.sh` using file_write.",
                "turn2_expected_tool": "file_write",
                "turn2_expected_file": "modules/rotator/bin/rotator.sh",
                "turn2_obs": "File created.",
                "turn3_prompt": "Validate bash syntax of modules/rotator/bin/rotator.sh via bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["bash -n modules/rotator/bin/rotator.sh"]
            },
            {
                "id": "scaffold_03",
                "name": "Scaffold Phytology Health Sensor",
                "turn1_prompt": "Create directory `lib/sensors/phytology` using bash_exec.",
                "turn1_expected_tool": "bash_exec",
                "turn1_command_substr": ["mkdir -p lib/sensors/phytology"],
                "turn1_obs": "Directory ready.",
                "turn2_prompt": "Write `lib/sensors/phytology/sensor.sh` using file_write.",
                "turn2_expected_tool": "file_write",
                "turn2_expected_file": "lib/sensors/phytology/sensor.sh",
                "turn2_obs": "Wrote sensor.sh.",
                "turn3_prompt": "Check bash syntax of lib/sensors/phytology/sensor.sh via bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["bash -n lib/sensors/phytology/sensor.sh"]
            },
            {
                "id": "scaffold_04",
                "name": "Scaffold MQTT Telemetry Publisher",
                "turn1_prompt": "Create directory `services/telemetry/config` using bash_exec.",
                "turn1_expected_tool": "bash_exec",
                "turn1_command_substr": ["mkdir -p services/telemetry/config"],
                "turn1_obs": "Directory created.",
                "turn2_prompt": "Write a concise MQTT publisher in `services/telemetry/publisher.py` using file_write.",
                "turn2_expected_tool": "file_write",
                "turn2_expected_file": "services/telemetry/publisher.py",
                "turn2_obs": "Created publisher.py.",
                "turn3_prompt": "Run python3 -m py_compile services/telemetry/publisher.py via bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["py_compile services/telemetry/publisher.py"]
            },
            {
                "id": "scaffold_05",
                "name": "Scaffold Cron Job Health Checker",
                "turn1_prompt": "Create directory `.george/cron_jobs/health` using bash_exec.",
                "turn1_expected_tool": "bash_exec",
                "turn1_command_substr": ["mkdir -p .george/cron_jobs/health"],
                "turn1_obs": "Created health directory.",
                "turn2_prompt": "Write `.george/cron_jobs/health/check.sh` using file_write.",
                "turn2_expected_tool": "file_write",
                "turn2_expected_file": ".george/cron_jobs/health/check.sh",
                "turn2_obs": "check.sh written.",
                "turn3_prompt": "Check bash syntax of .george/cron_jobs/health/check.sh using bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["bash -n .george/cron_jobs/health/check.sh"]
            }
        ],
        "Pillar 5: Sovereign GitOps Lifecycle: Status -> Branch -> Commit -> Push": [
            {
                "id": "git_01",
                "name": "GitOps Feature Branching & Status Protocol",
                "turn1_prompt": "Check current git status in short porcelain format using bash_exec.",
                "turn1_expected_tool": "bash_exec",
                "turn1_command_substr": ["git status"],
                "turn1_obs": "## develop...origin/develop\n M lib/fifo_ipc.sh",
                "turn2_prompt": "Branch off develop to `feature/fifo-hardening` using bash_exec.",
                "turn2_expected_tool": "bash_exec",
                "turn2_command_substr": ["git checkout -b feature/fifo-hardening develop"],
                "turn2_obs": "Switched to a new branch 'feature/fifo-hardening'",
                "turn3_prompt": "Stage lib/fifo_ipc.sh and commit with conventional message 'feat(ipc): harden fifo flow control' using bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["git add lib/fifo_ipc.sh", "git commit -m"]
            },
            {
                "id": "git_02",
                "name": "GitOps Phytology Telemetry Commit",
                "turn1_prompt": "Check status of git repository with bash_exec.",
                "turn1_expected_tool": "bash_exec",
                "turn1_command_substr": ["git status"],
                "turn1_obs": "On branch develop\nChanges not staged: modified: lib/phytology.sh",
                "turn2_prompt": "Create feature branch `feature/phytology-telemetry` from develop using bash_exec.",
                "turn2_expected_tool": "bash_exec",
                "turn2_command_substr": ["git checkout -b feature/phytology-telemetry develop"],
                "turn2_obs": "Switched to branch feature/phytology-telemetry",
                "turn3_prompt": "Commit lib/phytology.sh with message 'feat(phytology): add health summary telemetry' using bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["git add lib/phytology.sh", "git commit -m"]
            },
            {
                "id": "git_03",
                "name": "GitOps Push to Sovereign Gitea Remote",
                "turn1_prompt": "Verify active git remotes using bash_exec.",
                "turn1_expected_tool": "bash_exec",
                "turn1_command_substr": ["git remote -v"],
                "turn1_obs": "gitea\thttp://127.0.0.1:3088/george/blue-lodge.git (fetch)\norigin\tgit@github.com:dabe-19/blue-lodge.git (fetch)",
                "turn2_prompt": "Push branch `feature/async-flow-control` to gitea using bash_exec.",
                "turn2_expected_tool": "bash_exec",
                "turn2_command_substr": ["git push gitea feature/async-flow-control"],
                "turn2_obs": "To http://127.0.0.1:3088/george/blue-lodge.git\n * [new branch] feature/async-flow-control -> feature/async-flow-control",
                "turn3_prompt": "Push the same branch to origin using bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["git push origin feature/async-flow-control"]
            },
            {
                "id": "git_04",
                "name": "GitOps Worktree Clean Reaping",
                "turn1_prompt": "List all active git worktrees using bash_exec.",
                "turn1_expected_tool": "bash_exec",
                "turn1_command_substr": ["git worktree list"],
                "turn1_obs": "/home/wsl-ops/blue-lodge 1a2b3c [develop]\n/home/wsl-ops/blue-lodge/.sandboxes/stale_sub 4d5e6f [sub/stale]",
                "turn2_prompt": "Remove the stale worktree `.sandboxes/stale_sub` using bash_exec.",
                "turn2_expected_tool": "bash_exec",
                "turn2_command_substr": ["git worktree remove", ".sandboxes/stale_sub"],
                "turn2_obs": "Worktree removed.",
                "turn3_prompt": "Prune git worktree administrative records with bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["git worktree prune"]
            },
            {
                "id": "git_05",
                "name": "GitOps Branch Deletion Post-Merge",
                "turn1_prompt": "List merged branches with bash_exec.",
                "turn1_expected_tool": "bash_exec",
                "turn1_command_substr": ["git branch --merged"],
                "turn1_obs": "* develop\n  feature/old-merged-feature",
                "turn2_prompt": "Delete the merged branch `feature/old-merged-feature` locally using bash_exec.",
                "turn2_expected_tool": "bash_exec",
                "turn2_command_substr": ["git branch -d feature/old-merged-feature"],
                "turn2_obs": "Deleted branch feature/old-merged-feature.",
                "turn3_prompt": "Verify branch deletion by listing active branches with bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["git branch"]
            }
        ],
        "Pillar 6: Dependency Discovery, Version Pinning & Runtime Import": [
            {
                "id": "dep_01",
                "name": "Discover, Pin and Validate `httpx`",
                "turn1_prompt": "Check if python package `httpx` is installed and get version using bash_exec.",
                "turn1_expected_tool": "bash_exec",
                "turn1_command_substr": ["python3 -c", "import httpx"],
                "turn1_obs": "ModuleNotFoundError: No module named 'httpx'",
                "turn2_prompt": "Install pinned version `httpx==0.27.0` quietly using bash_exec.",
                "turn2_expected_tool": "bash_exec",
                "turn2_command_substr": ["pip install", "httpx==0.27.0"],
                "turn2_obs": "Successfully installed httpx-0.27.0",
                "turn3_prompt": "Verify httpx import and print version using bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["import httpx", "httpx.__version__"]
            },
            {
                "id": "dep_02",
                "name": "Discover, Pin and Validate `pytest-asyncio`",
                "turn1_prompt": "Check if `pytest_asyncio` is installed via bash_exec.",
                "turn1_expected_tool": "bash_exec",
                "turn1_command_substr": ["python3 -c", "pytest_asyncio"],
                "turn1_obs": "ModuleNotFoundError: No module named 'pytest_asyncio'",
                "turn2_prompt": "Install `pytest-asyncio==0.23.5` using bash_exec.",
                "turn2_expected_tool": "bash_exec",
                "turn2_command_substr": ["pip install", "pytest-asyncio==0.23.5"],
                "turn2_obs": "Successfully installed pytest-asyncio-0.23.5",
                "turn3_prompt": "Verify pytest_asyncio import using bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["python3 -c", "import pytest_asyncio"]
            },
            {
                "id": "dep_03",
                "name": "Discover, Pin and Validate `pydantic`",
                "turn1_prompt": "Check if `pydantic` is installed and check version with bash_exec.",
                "turn1_expected_tool": "bash_exec",
                "turn1_command_substr": ["python3 -c", "import pydantic"],
                "turn1_obs": "pydantic 1.10.8",
                "turn2_prompt": "Upgrade pydantic to pinned version `pydantic==2.6.4` using bash_exec.",
                "turn2_expected_tool": "bash_exec",
                "turn2_command_substr": ["pip install", "pydantic==2.6.4"],
                "turn2_obs": "Successfully installed pydantic-2.6.4",
                "turn3_prompt": "Verify pydantic version 2 using bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["python3 -c", "pydantic.__version__"]
            },
            {
                "id": "dep_04",
                "name": "Discover, Pin and Validate `rich`",
                "turn1_prompt": "Check if terminal formatting library `rich` is installed via bash_exec.",
                "turn1_expected_tool": "bash_exec",
                "turn1_command_substr": ["python3 -c", "import rich"],
                "turn1_obs": "No module named 'rich'",
                "turn2_prompt": "Install `rich==13.7.1` using bash_exec.",
                "turn2_expected_tool": "bash_exec",
                "turn2_command_substr": ["pip install", "rich==13.7.1"],
                "turn2_obs": "Successfully installed rich-13.7.1",
                "turn3_prompt": "Verify rich import with bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["python3 -c", "import rich"]
            },
            {
                "id": "dep_05",
                "name": "Discover, Pin and Validate `pyyaml`",
                "turn1_prompt": "Check if python package pyyaml is installed with bash_exec.",
                "turn1_expected_tool": "bash_exec",
                "turn1_command_substr": ["yaml"],
                "turn1_obs": "No module named 'yaml'",
                "turn2_prompt": "Install `pyyaml==6.0.1` using bash_exec.",
                "turn2_expected_tool": "bash_exec",
                "turn2_command_substr": ["pip install", "pyyaml==6.0.1"],
                "turn2_obs": "Successfully installed pyyaml-6.0.1",
                "turn3_prompt": "Verify yaml import using bash_exec.",
                "turn3_expected_tool": "bash_exec",
                "turn3_command_substr": ["python3 -c", "import yaml"]
            }
        ]
    }

# ─────────────────────────────────────────────────────────────────────────────
# Evaluation Engine
# ─────────────────────────────────────────────────────────────────────────────

def evaluate_scenario(endpoint: str, tools: list, scenario: dict) -> Tuple[float, dict]:
    sid = scenario["id"]
    name = scenario["name"]
    messages = []
    score = 0.0
    diagnostics = {"turns": []}

    # Turn 1
    t1_prompt = scenario["turn1_prompt"]
    messages.append({"role": "user", "content": t1_prompt})
    res1 = query_endpoint(endpoint, messages, tools=tools)
    
    t1_passed = False
    if res1.get("success"):
        tc1 = res1.get("tool_calls", [])
        names1 = [t.get("function", {}).get("name") for t in tc1]
        exp_tool1 = scenario.get("turn1_expected_tool")
        req_sub1 = scenario.get("turn1_command_substr", [])
        
        if (exp_tool1 in names1) or (exp_tool1 == "file_grep" and "code_symbol_read" in names1):
            if req_sub1:
                # check command args
                args1_str = json.dumps([t.get("function", {}).get("arguments", "") for t in tc1])
                if any(sub in args1_str for sub in req_sub1):
                    t1_passed = True
            else:
                t1_passed = True

        diagnostics["turns"].append({
            "turn": 1,
            "passed": t1_passed,
            "tool_calls": names1,
            "expected_tool": exp_tool1
        })
        if t1_passed:
            score += 0.33

        # Add assistant message and observation to history
        if tc1:
            messages.append({"role": "assistant", "content": res1.get("content", ""), "tool_calls": tc1})
            for i, tc in enumerate(tc1):
                tid = tc.get("id") or f"call_1_{i}"
                obs = scenario.get("turn1_obs", "OK") if i == 0 else "OK"
                messages.append({"role": "tool", "tool_call_id": tid, "content": obs})
        else:
            messages.append({"role": "assistant", "content": res1.get("content", "")})
            messages.append({"role": "user", "content": scenario.get("turn2_prompt", "Continue with next step.")})
    else:
        diagnostics["turns"].append({"turn": 1, "passed": False, "error": res1.get("error")})
        return 0.0, diagnostics

    # Turn 2
    if scenario.get("turn2_prompt"):
        messages.append({"role": "user", "content": scenario["turn2_prompt"]})

    res2 = query_endpoint(endpoint, messages, tools=tools)
    t2_passed = False
    if res2.get("success"):
        tc2 = res2.get("tool_calls", [])
        names2 = [t.get("function", {}).get("name") for t in tc2]
        exp_tool2 = scenario.get("turn2_expected_tool")
        url_sub2 = scenario.get("turn2_expected_url_substr")
        file2 = scenario.get("turn2_expected_file")
        cmd_sub2 = scenario.get("turn2_command_substr", [])

        if exp_tool2 in names2:
            args2_str = json.dumps([t.get("function", {}).get("arguments", "") for t in tc2])
            match = True
            if url_sub2 and url_sub2 not in args2_str:
                match = False
            if file2 and file2 not in args2_str:
                match = False
            if cmd_sub2 and not any(sub in args2_str for sub in cmd_sub2):
                match = False
            if match:
                t2_passed = True

        diagnostics["turns"].append({
            "turn": 2,
            "passed": t2_passed,
            "tool_calls": names2,
            "expected_tool": exp_tool2
        })
        if t2_passed:
            score += 0.33

        if tc2:
            messages.append({"role": "assistant", "content": res2.get("content", ""), "tool_calls": tc2})
            for i, tc in enumerate(tc2):
                tid = tc.get("id") or f"call_2_{i}"
                obs = scenario.get("turn2_obs", "OK") if i == 0 else "OK"
                messages.append({"role": "tool", "tool_call_id": tid, "content": obs})
        else:
            messages.append({"role": "assistant", "content": res2.get("content", "")})
    else:
        diagnostics["turns"].append({"turn": 2, "passed": False, "error": res2.get("error")})
        return score, diagnostics

    # Turn 3
    if scenario.get("turn3_prompt"):
        messages.append({"role": "user", "content": scenario["turn3_prompt"]})

    res3 = query_endpoint(endpoint, messages, tools=tools)
    t3_passed = False
    if res3.get("success"):
        tc3 = res3.get("tool_calls", [])
        names3 = [t.get("function", {}).get("name") for t in tc3]
        exp_tool3 = scenario.get("turn3_expected_tool")
        comp_subs = scenario.get("turn3_completion_substr", [])
        cmd_sub3 = scenario.get("turn3_command_substr", [])

        if exp_tool3:
            if exp_tool3 in names3:
                args3_str = json.dumps([t.get("function", {}).get("arguments", "") for t in tc3])
                if cmd_sub3:
                    if any(sub in args3_str for sub in cmd_sub3):
                        t3_passed = True
                else:
                    t3_passed = True
        elif comp_subs:
            # check assistant content for synthesis
            content3 = (res3.get("content") or "") + " " + (res3.get("reasoning") or "")
            if any(s.lower() in content3.lower() for s in comp_subs):
                t3_passed = True

        diagnostics["turns"].append({
            "turn": 3,
            "passed": t3_passed,
            "tool_calls": names3,
            "expected_tool": exp_tool3
        })
        if t3_passed:
            score += 0.34
    else:
        diagnostics["turns"].append({"turn": 3, "passed": False, "error": res3.get("error")})

    return round(score, 2), diagnostics

def main():
    args = parse_args()
    tools = get_bedrock_tools()
    scenarios_by_pillar = get_multiturn_scenarios()

    total_scenarios = sum(len(v) for v in scenarios_by_pillar.values())
    total_score = 0.0

    print("=" * 80)
    print("  BLUE LODGE MULTI-TURN SOVEREIGN BENCHMARK (BlueLodgeMultiTurnBench)")
    print(f"  Model: {args.model_label} | Endpoint: {args.endpoint}")
    print(f"  Pillars: {len(scenarios_by_pillar)} | Scenarios: {total_scenarios}")
    print("=" * 80)

    pillar_results = {}

    for pillar, scenarios in scenarios_by_pillar.items():
        print(f"\n[*] Evaluating {pillar} ({len(scenarios)} scenarios)...")
        p_score = 0.0
        p_passed = 0
        p_total = len(scenarios)

        for idx, sc in enumerate(scenarios, 1):
            sc_score, diag = evaluate_scenario(args.endpoint, tools, sc)
            p_score += sc_score
            is_full_pass = (sc_score >= 0.95)
            if is_full_pass:
                p_passed += 1

            status_mark = "✓ FULL" if is_full_pass else ("~ PARTIAL" if sc_score > 0 else "✗ FAIL")
            print(f"  [{idx:02d}/{p_total:02d}] {status_mark:9s} | Score: {sc_score:4.2f} | {sc['name']}")

        pillar_pct = (p_score / p_total) * 100.0
        pillar_results[pillar] = {
            "score_pct": round(pillar_pct, 1),
            "points": round(p_score, 2),
            "total": p_total,
            "full_passes": p_passed
        }
        total_score += p_score

    overall_pct = (total_score / total_scenarios) * 100.0

    print("\n" + "=" * 80)
    print("  FINAL BLUELODGEMULTITURNBENCH SCORECARD")
    print("=" * 80)
    for p_name, res in pillar_results.items():
        p_clean = p_name.split(":")[1].strip() if ":" in p_name else p_name
        print(f"  • {p_clean:55s}: {res['score_pct']:5.1f}% ({res['points']:.2f}/{res['total']})")
    print("-" * 80)
    print(f"  ★ OVERALL COMPOSITE MULTI-TURN SCORE:            {overall_pct:5.1f}% ({total_score:.2f}/{total_scenarios})")
    print("=" * 80)

    ts_now = int(time.time())
    out_path = args.output or os.path.join(RESULTS_DIR, f"bluelodge_multiturn_benchmark_{ts_now}.json")
    scorecard = {
        "benchmark": "BlueLodgeMultiTurnBench",
        "model_label": args.model_label,
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "overall_score": round(overall_pct, 1),
        "total_points": round(total_score, 2),
        "max_points": total_scenarios,
        "pillars": pillar_results
    }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(scorecard, f, indent=2)
    print(f"\n[✓] Scorecard written to {out_path}")

if __name__ == "__main__":
    main()
