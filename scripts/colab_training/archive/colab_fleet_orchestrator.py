#!/usr/bin/env python3
"""
colab_fleet_orchestrator.py:
Automated 3-Instance Colab A100 Fleet Orchestrator via google-colab-cli.

Orchestrates 3 parallel sessions:
- blue-syntax: Track 1 (Syntax & Schema Integrity, 5,730 samples)
- blue-gitops: Track 2 (GitOps & Safe File Lifecycle, 3,550 samples)
- blue-phytology: Track 3 (Living Tissue Phytology Protocol, 3,550 samples)

Lifecycle:
1. Provisions 3 A100-highmem Colab sessions using colab --auth=adc.
2. Uploads curriculum, tools manifest, and autonomous worker script.
3. Launches GRPO training with G=12 and parallel rollout workers.
4. Monitors live training logs and streams status.
5. Downloads the 3 exported GGUF adapters into local storage.
6. Terminates sessions cleanly to preserve compute unit balance.
"""

import os
import sys
import time
import subprocess
import argparse

COLAB_BIN = "/home/wsl-ops/venv_research/bin/colab"
WORKSPACE_DIR = "/home/wsl-ops/blue-lodge"
MODELS_DIR = "/home/wsl-ops/models/frontier_qwen38"
os.makedirs(MODELS_DIR, exist_ok=True)

TRACKS = [
    {
        "session": "blue-syntax",
        "name": "Track 1: Syntax & Schema Integrity",
        "curriculum": os.path.join(WORKSPACE_DIR, "data/training/curriculum_track1_syntax.jsonl"),
        "remote_output": "/content/output/Blue-Llama-27B-Champion-v5-LoRA-Syntax.gguf",
        "local_output": os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-LoRA-Syntax.gguf")
    },
    {
        "session": "blue-gitops",
        "name": "Track 2: GitOps & Safe File Lifecycle",
        "curriculum": os.path.join(WORKSPACE_DIR, "data/training/curriculum_track2_git_ops.jsonl"),
        "remote_output": "/content/output/Blue-Llama-27B-Champion-v5-LoRA-GitOps.gguf",
        "local_output": os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-LoRA-GitOps.gguf")
    },
    {
        "session": "blue-phytology",
        "name": "Track 3: Software Phytology Protocol",
        "curriculum": os.path.join(WORKSPACE_DIR, "data/training/curriculum_track3_phytology.jsonl"),
        "remote_output": "/content/output/Blue-Llama-27B-Champion-v5-LoRA-Phytology.gguf",
        "local_output": os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-LoRA-Phytology.gguf")
    }
]

def run_colab_cmd(args_list, timeout=120):
    cmd = [COLAB_BIN, "--auth=adc"] + args_list
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return res.returncode, res.stdout, res.stderr

def provision_fleet(tracks):
    print("=" * 80)
    print("  Stage 1: Provisioning 3 Colab A100 High-Mem Instances")
    print("=" * 80)
    for t in tracks:
        s_name = t["session"]
        print(f"[*] Provisioning session '{s_name}' ({t['name']}) on A100...")
        code, out, err = run_colab_cmd(["new", "-s", s_name, "--gpu", "A100", "--high-mem"])
        if code != 0:
            print(f"[!] Warning on '{s_name}': {err.strip() or out.strip()}")
        else:
            print(f"  ✓ Session '{s_name}' provisioned successfully.")
        time.sleep(2)

def upload_payloads(tracks):
    print("\n" + "=" * 80)
    print("  Stage 2: Uploading Training Scripts & Curricula")
    print("=" * 80)
    worker_script = os.path.join(WORKSPACE_DIR, "scripts/colab_training/train_blue_lodge_colab.py")
    tools_manifest = os.path.join(WORKSPACE_DIR, "data/training/native_core_tools.json")

    for t in tracks:
        s_name = t["session"]
        print(f"[*] Uploading payloads to session '{s_name}'...")
        # 1. Upload curriculum
        run_colab_cmd(["upload", "-s", s_name, t["curriculum"], "/content/curriculum.jsonl"])
        # 2. Upload worker script
        run_colab_cmd(["upload", "-s", s_name, worker_script, "/content/train_blue_lodge_colab.py"])
        # 3. Upload tools manifest
        if os.path.exists(tools_manifest):
            run_colab_cmd(["upload", "-s", s_name, tools_manifest, "/content/native_core_tools.json"])
        print(f"  ✓ Uploaded curriculum and training fabric to '{s_name}'.")

def launch_training(tracks, steps=40, group_size=12):
    print("\n" + "=" * 80)
    print(f"  Stage 3: Launching Parallel GRPO Training (Steps: {steps}, G={group_size})")
    print("=" * 80)
    for t in tracks:
        s_name = t["session"]
        remote_out = t["remote_output"]
        cmd_str = (
            f"nohup python3 /content/train_blue_lodge_colab.py "
            f"--curriculum /content/curriculum.jsonl "
            f"--steps {steps} "
            f"--group_size {group_size} "
            f"--parallel {group_size} "
            f"--output {remote_out} > /content/train.log 2>&1 &"
        )
        print(f"[*] Dispatching background training on '{s_name}'...")
        run_colab_cmd(["exec", "-s", s_name, "--", "bash", "-c", cmd_str])
        print(f"  ✓ Training dispatched on '{s_name}'.")

def monitor_and_sync(tracks, poll_interval=30):
    print("\n" + "=" * 80)
    print("  Stage 4: Fleet Telemetry & Adapter Synchronization")
    print("=" * 80)
    completed = set()

    while len(completed) < len(tracks):
        time.sleep(poll_interval)
        for t in tracks:
            s_name = t["session"]
            if s_name in completed:
                continue

            check_script = (
                "import os\n"
                f"exists = os.path.exists('{t['remote_output']}')\n"
                f"size = os.path.getsize('{t['remote_output']}') if exists else 0\n"
                "log_tail = ''\n"
                "if os.path.exists('/content/train.log'):\n"
                "    with open('/content/train.log') as f: log_tail = ''.join(f.readlines()[-3:])\n"
                "print(f'STATUS:{exists}:{size}\\n{log_tail}')\n"
            )
            code, out, err = run_colab_cmd(["exec", "-s", s_name, "--", "python3", "-c", check_script])
            if code == 0:
                lines = out.strip().split("\n")
                status = lines[0] if lines else ""
                log = " | ".join(l.strip() for l in lines[1:] if l.strip())

                if status.startswith("STATUS:"):
                    parts = status.split(":")
                    is_done = parts[1] == "True"
                    file_size = int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else 0

                    print(f"[{s_name}] Size: {file_size/(1024**2):.1f}MB | Progress: {log[:100]}")
                    if is_done and file_size > 10 * 1024 * 1024:
                        print(f"  ★ Download ready for {s_name}! Downloading to {t['local_output']}...")
                        dl_code, dl_out, dl_err = run_colab_cmd(["download", "-s", s_name, t["remote_output"], t["local_output"]])
                        if dl_code == 0 and os.path.exists(t["local_output"]):
                            print(f"  ✓ Successfully downloaded {t['local_output']} ({os.path.getsize(t['local_output'])/(1024**2):.2f} MiB)")
                            completed.add(s_name)

    print("\n[✓] All 3 Colab training tracks successfully finished and downloaded!")

def teardown_fleet(tracks):
    print("\n" + "=" * 80)
    print("  Stage 5: Clean Fleet Teardown (Preserving Compute Units)")
    print("=" * 80)
    for t in tracks:
        s_name = t["session"]
        print(f"[*] Stopping session '{s_name}'...")
        run_colab_cmd(["stop", "-s", s_name])
    print("[✓] All Colab sessions terminated cleanly.")

def main():
    parser = argparse.ArgumentParser(description="Colab A100 Fleet Orchestrator")
    parser.add_argument("--steps", type=int, default=40, help="GRPO steps per instance (default 40)")
    parser.add_argument("--group_size", type=int, default=12, help="Rollout group size (default 12)")
    parser.add_argument("--teardown", action="store_true", default=True, help="Teardown sessions when done")
    args = parser.parse_args()

    # Verify Colab balance
    code, out, err = run_colab_cmd(["usage"])
    print(out)

    provision_fleet(TRACKS)
    upload_payloads(TRACKS)
    launch_training(TRACKS, steps=args.steps, group_size=args.group_size)
    monitor_and_sync(TRACKS)

    if args.teardown:
        teardown_fleet(TRACKS)

    # Perform Iteration 5 Fusion
    print("\n" + "=" * 80)
    print("  Stage 6: Multi-LoRA Analytical Concatenation (4 New GGUFs + 4 Frontier)")
    print("=" * 80)
    subprocess.run([sys.executable, os.path.join(WORKSPACE_DIR, "scripts/colab_training/fuse_iteration5.py")])

if __name__ == "__main__":
    main()
