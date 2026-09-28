#!/usr/bin/env python3
"""
colab_3x_a100_orchestrator.py:
Automated 3-Instance Colab A100 Fleet Orchestrator for DAG ReAct & Failure Mode Training.

Orchestrates 3 parallel sessions:
- blue-dag-parallel: Track A (DAG Parallel Execution & milestone_complete)
- blue-dag-recovery: Track B (Two-Tier Recovery Cascade & Self-Healing)
- blue-dag-memory: Track C (Working Memory Distillation & Final Synthesis)

Workflow:
1. Provisions 3 A100-highmem Colab sessions using colab --auth=adc.
2. Uploads curriculum, tools manifest, and autonomous worker script.
3. Launches GRPO training with G=12 and parallel rollout workers in parallel.
4. Monitors live training logs across all 3 sessions.
5. Downloads the 3 exported GGUF adapters into local storage (/home/wsl-ops/models/frontier_qwen38/).
6. Executes fuse_iteration10.py blending the 3 new adapters directly onto Champion Iteration 9.
7. Terminates sessions cleanly to preserve compute units.
"""

import os
import sys
import time
import subprocess
import argparse
from concurrent.futures import ThreadPoolExecutor

COLAB_BIN = "/home/wsl-ops/venv_research/bin/colab"
PYTHON_BIN = "/home/wsl-ops/venv_research/bin/python"
WORKSPACE_DIR = "/home/wsl-ops/blue-lodge"
MODELS_DIR = "/home/wsl-ops/models/frontier_qwen38"
os.makedirs(MODELS_DIR, exist_ok=True)

TRACKS = [
    {
        "session": "blue-dag-parallel",
        "track": "dag_parallel",
        "name": "Track A: DAG Parallel Execution & Milestone Complete",
        "curriculum": os.path.join(WORKSPACE_DIR, "data/training/curriculum_trackA_dag_parallel.jsonl"),
        "remote_output": "/content/output/Blue-Llama-27B-Champion-v5-LoRA-DAG-Parallel.gguf",
        "local_output": os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-LoRA-DAG-Parallel.gguf")
    },
    {
        "session": "blue-dag-recovery",
        "track": "recovery_selfheal",
        "name": "Track B: Two-Tier Recovery Cascade & Self-Healing",
        "curriculum": os.path.join(WORKSPACE_DIR, "data/training/curriculum_trackB_recovery_selfheal.jsonl"),
        "remote_output": "/content/output/Blue-Llama-27B-Champion-v5-LoRA-Recovery-SelfHeal.gguf",
        "local_output": os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-LoRA-Recovery-SelfHeal.gguf")
    },
    {
        "session": "blue-dag-memory",
        "track": "memory_synthesis",
        "name": "Track C: Working Memory Distillation & Synthesis",
        "curriculum": os.path.join(WORKSPACE_DIR, "data/training/curriculum_trackC_memory_synthesis.jsonl"),
        "remote_output": "/content/output/Blue-Llama-27B-Champion-v5-LoRA-Memory-Synthesis.gguf",
        "local_output": os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-LoRA-Memory-Synthesis.gguf")
    },
    {
        "session": "blue-dag-strategist",
        "track": "strategist_dag",
        "name": "Track D (Option 6A): Honeydew DAG Strategist Decomposition",
        "curriculum": os.path.join(WORKSPACE_DIR, "data/training/curriculum_trackD_strategist_dag.jsonl"),
        "remote_output": "/content/output/Blue-Llama-27B-Champion-v5-LoRA-Strategist-DAG.gguf",
        "local_output": os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-LoRA-Strategist-DAG.gguf")
    }
]

def run_colab_cmd(args_list, timeout=120):
    cmd = [COLAB_BIN, "--auth=adc"] + args_list
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return res.returncode, res.stdout, res.stderr

def provision_instance(t):
    s_name = t["session"]
    print(f"[*] Provisioning session '{s_name}' ({t['name']}) on A100 High-Mem...")
    sys.stdout.flush()
    code, out, err = run_colab_cmd(["new", "-s", s_name, "--gpu", "A100", "--high-mem"])
    if code != 0:
        print(f"[!] Warning on '{s_name}': {err.strip() or out.strip()}")
    else:
        print(f"  ✓ Session '{s_name}' provisioned successfully.")
    sys.stdout.flush()

def upload_track_payload(t):
    s_name = t["session"]
    print(f"[*] Uploading payloads to session '{s_name}'...")
    worker_script = os.path.join(WORKSPACE_DIR, "scripts/colab_training/train_dag_colab.py")
    run_colab_cmd(["upload", "-s", s_name, t["curriculum"], "/content/curriculum.jsonl"])
    run_colab_cmd(["upload", "-s", s_name, worker_script, "/content/train_dag_colab.py"])
    print(f"  ✓ Uploaded curriculum and worker script to '{s_name}'.")
    sys.stdout.flush()

def run_track_training(t, steps=30):
    s_name = t["session"]
    remote_out = t["remote_output"]
    track = t["track"]
    cmd_str = (
        f"python3 /content/train_dag_colab.py "
        f"--track {track} "
        f"--curriculum /content/curriculum.jsonl "
        f"--steps {steps} "
        f"--group_size 12 "
        f"--parallel 12 "
        f"--rank 32 "
        f"--alpha 64.0 "
        f"--output {remote_out} "
        f"> /content/training.log 2>&1"
    )
    print(f"[*] Dispatching GRPO training on '{s_name}' ({track})...")
    sys.stdout.flush()
    run_colab_cmd(["exec", "-s", s_name, "--", "bash", "-c", cmd_str], timeout=600)
    print(f"  ✓ Training completed on '{s_name}'.")
    sys.stdout.flush()

def download_and_cleanup(t):
    s_name = t["session"]
    print(f"[*] Downloading GGUF adapter from '{s_name}' -> {t['local_output']}...")
    sys.stdout.flush()
    run_colab_cmd(["download", "-s", s_name, t["remote_output"], t["local_output"]], timeout=300)
    if os.path.exists(t["local_output"]):
        print(f"  ✓ Downloaded {os.path.basename(t['local_output'])} ({os.path.getsize(t['local_output'])/(1024**2):.1f} MB)")
    else:
        print(f"  [!] Missing output {t['local_output']}")
    sys.stdout.flush()
    # Terminate session
    run_colab_cmd(["stop", "-s", s_name])
    print(f"  ✓ Session '{s_name}' stopped cleanly.")
    sys.stdout.flush()

def main():
    parser = argparse.ArgumentParser(description="Colab 3x A100 Parallel Fleet Orchestrator")
    parser.add_argument("--steps", type=int, default=30, help="GRPO steps per instance")
    parser.add_argument("--dry_run", action="store_true", help="Simulate without provisioning")
    args = parser.parse_args()

    print("=" * 80)
    print("  Blue Lodge 3x A100 Colab Fleet Training Orchestrator")
    print("=" * 80)

    if args.dry_run:
        print("[*] Running in dry-run mode: generating local adapter checkpoints directly.")
        # Execute train_dag_colab locally for each track to verify correctness
        for t in TRACKS:
            cmd = [
                PYTHON_BIN,
                os.path.join(WORKSPACE_DIR, "scripts/colab_training/train_dag_colab.py"),
                "--track", t["track"],
                "--curriculum", t["curriculum"],
                "--steps", "5",
                "--standalone",
                "--output", t["local_output"]
            ]
            print(f"\n[*] Training {t['name']} locally...")
            subprocess.run(cmd, check=True)
    else:
        # Step 1: Parallel Provisioning
        print("\n" + "=" * 80)
        print("  Stage 1: Parallel Provisioning of 3x A100 Instances")
        print("=" * 80)
        with ThreadPoolExecutor(max_workers=3) as executor:
            list(executor.map(provision_instance, TRACKS))

        # Step 2: Parallel Payload Upload
        print("\n" + "=" * 80)
        print("  Stage 2: Parallel Payload Upload")
        print("=" * 80)
        with ThreadPoolExecutor(max_workers=3) as executor:
            list(executor.map(upload_track_payload, TRACKS))

        # Step 3: Parallel Training Execution
        print("\n" + "=" * 80)
        print(f"  Stage 3: Launching 3 Parallel A100 GRPO Runs ({args.steps} steps each)")
        print("=" * 80)
        with ThreadPoolExecutor(max_workers=3) as executor:
            list(executor.map(lambda t: run_track_training(t, steps=args.steps), TRACKS))

        # Step 4: Parallel Download & Session Cleanup
        print("\n" + "=" * 80)
        print("  Stage 4: Downloading Adapters & Stopping Colab Sessions")
        print("=" * 80)
        with ThreadPoolExecutor(max_workers=3) as executor:
            list(executor.map(download_and_cleanup, TRACKS))

    # Step 5: Execute Iteration 10 Fusion
    print("\n" + "=" * 80)
    print("  Stage 5: Executing Iteration 10 Fusion onto Champion Baseline")
    print("=" * 80)
    fuse_cmd = [PYTHON_BIN, os.path.join(WORKSPACE_DIR, "scripts/colab_training/fuse_iteration10.py")]
    subprocess.run(fuse_cmd, check=True)

    print("\n" + "=" * 80)
    print("  ✓ Full 3x A100 Fleet Pipeline Successfully Concluded!")
    print("=" * 80)

if __name__ == "__main__":
    main()
