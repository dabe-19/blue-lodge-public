#!/usr/bin/env python3
"""
colab_jinja_orchestrator.py:
Automated 3-Instance Colab A100 Fleet Orchestrator for Native Jinja Tool Calling GRPO.

Dispatches 3 parallel targeted training runs on fresh Colab A100 instances:
- jinja-syntax: Track 1 (Native Jinja <tool_call>, zero XML parameter leak, 4,000 samples)
- safe-fileops: Track 2 (Pillar 3: Safe file_edit anti-clobber supremacy, 4,000 samples)
- phytology-gitops: Track 3 (Pillars 4 & 5: Phytology protocol & Git develop/conventional, 4,000 samples)

Lifecycle:
1. Provisions 3x Colab A100 SXM4 High-Mem instances.
2. Uploads specialized curricula, tools manifest, and updated GRPO worker script.
3. Launches GRPO training with G=12 parallel rollouts for 40 steps.
4. Telemetry polling and progress tracking.
5. Downloads the 3 new GGUF adapters.
6. Cleanly terminates Colab instances to conserve compute units.
7. Executes fuse_iteration7.py for domain-weighted multi-adapter fusion.
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
        "session": "jinja-syntax",
        "name": "Track 1: Native Jinja Syntax & Zero XML Leakage",
        "curriculum": os.path.join(WORKSPACE_DIR, "data/training/curriculum_jinja_syntax.jsonl"),
        "remote_output": "/content/output/Blue-Llama-27B-Champion-v5-LoRA-Jinja-Syntax.gguf",
        "local_output": os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-LoRA-Jinja-Syntax.gguf")
    },
    {
        "session": "safe-fileops",
        "name": "Track 2: Safe File Operations (file_edit Anti-Clobber)",
        "curriculum": os.path.join(WORKSPACE_DIR, "data/training/curriculum_anticlobber_fileops.jsonl"),
        "remote_output": "/content/output/Blue-Llama-27B-Champion-v5-LoRA-Safe-FileOps.gguf",
        "local_output": os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-LoRA-Safe-FileOps.gguf")
    },
    {
        "session": "phytology-gitops",
        "name": "Track 3: Phytology Protocol & Git Model Operations",
        "curriculum": os.path.join(WORKSPACE_DIR, "data/training/curriculum_phytology_gitops.jsonl"),
        "remote_output": "/content/output/Blue-Llama-27B-Champion-v5-LoRA-Phytology-GitOps.gguf",
        "local_output": os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-LoRA-Phytology-GitOps.gguf")
    }
]

def run_colab_cmd(args_list, input_text=None, timeout=90):
    cmd = [COLAB_BIN, "--auth=adc"] + args_list
    try:
        res = subprocess.run(cmd, input=input_text, capture_output=True, text=True, timeout=timeout)
        return res.returncode, res.stdout, res.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "TimeoutExpired"
    except Exception as e:
        return -1, "", str(e)

def provision_fleet(tracks):
    print("=" * 80)
    print("  Stage 1: Provisioning 3 Colab A100 High-Mem Instances")
    print("=" * 80)
    for t in tracks:
        s_name = t["session"]
        print(f"[*] Provisioning session '{s_name}' ({t['name']}) on A100 High-Mem...")
        code, out, err = run_colab_cmd(["new", "-s", s_name, "--gpu", "A100", "--high-mem"])
        if code != 0:
            print(f"[!] Info/Warning on '{s_name}': {err.strip() or out.strip()}")
        else:
            print(f"  ✓ Session '{s_name}' provisioned successfully.")
        time.sleep(2)

def upload_payloads(tracks):
    print("\n" + "=" * 80)
    print("  Stage 2: Uploading Curricula, Tools & Aligned GRPO Worker")
    print("=" * 80)
    worker_script = os.path.join(WORKSPACE_DIR, "scripts/colab_training/train_blue_lodge_colab.py")
    tools_manifest = os.path.join(WORKSPACE_DIR, "data/training/native_core_tools.json")

    for t in tracks:
        s_name = t["session"]
        print(f"[*] Uploading payloads to session '{s_name}' ({t['name']})...", flush=True)
        # 1. Upload worker script
        run_colab_cmd(["upload", "-s", s_name, worker_script, "/content/train_blue_lodge_colab.py"])
        # 2. Upload tools manifest
        if os.path.exists(tools_manifest):
            run_colab_cmd(["upload", "-s", s_name, tools_manifest, "/content/native_core_tools.json"])
        # 3. Upload curriculum
        code, out, err = run_colab_cmd(["upload", "-s", s_name, t["curriculum"], "/content/curriculum.jsonl"])
        if code != 0:
            print(f"[!] Upload failed for {s_name}: {err.strip() or out.strip()}", flush=True)
        else:
            print(f"  ✓ Uploaded curriculum and worker script for {t['name']}", flush=True)

def launch_training(tracks, steps=40, group_size=12):
    print("\n" + "=" * 80)
    print(f"  Stage 3: Launching Parallel Native Jinja GRPO Training (Steps: {steps}, G={group_size})")
    print("=" * 80)
    for t in tracks:
        s_name = t["session"]
        remote_out = t["remote_output"]
        launch_code = (
            f"import subprocess\n"
            f"cmd = 'nohup python3 /content/train_blue_lodge_colab.py --curriculum /content/curriculum.jsonl --steps {steps} --group_size {group_size} --parallel {group_size} --output {remote_out} > /content/train.log 2>&1 &'\n"
            f"subprocess.Popen(cmd, shell=True)\n"
            f"print('DISPATCHED')\n"
        )
        print(f"[*] Dispatching background training on '{s_name}'...")
        run_colab_cmd(["exec", "-s", s_name], input_text=launch_code)
        print(f"  ✓ Training dispatched on '{s_name}'.")

def monitor_and_sync(tracks, poll_interval=20):
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
                "    with open('/content/train.log') as f: log_tail = ''.join(f.readlines()[-2:])\n"
                "print(f'STATUS:{exists}:{size}\\n{log_tail}')\n"
            )
            code, out, err = run_colab_cmd(["exec", "-s", s_name, "--timeout", "30"], input_text=check_script, timeout=45)
            if code != 0:
                print(f"[{s_name}] Telemetry poll returned ({err.strip()[:40]}). Retrying next cycle...", flush=True)
                continue
            if code == 0:
                lines = [l.strip() for l in out.strip().split("\n") if l.strip()]
                status_idx = next((i for i, l in enumerate(lines) if l.startswith("STATUS:")), -1)
                if status_idx != -1:
                    status = lines[status_idx]
                    log = " | ".join(lines[status_idx + 1:])
                    parts = status.split(":")
                    is_done = parts[1] == "True"
                    file_size = int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else 0

                    step_info = log[:90] if log else "Initializing..."
                    print(f"[{s_name}] Size: {file_size/(1024**2):.1f}MB | Progress: {step_info}", flush=True)

                    if is_done and file_size > 10 * 1024 * 1024:
                        print(f"  ★ Download ready for {s_name}! Downloading to {t['local_output']}...", flush=True)
                        dl_code, dl_out, dl_err = run_colab_cmd(["download", "-s", s_name, t["remote_output"], t["local_output"]])
                        if dl_code == 0 and os.path.exists(t["local_output"]):
                            print(f"  ✓ Successfully downloaded {t['local_output']} ({os.path.getsize(t['local_output'])/(1024**2):.2f} MiB)", flush=True)
                            completed.add(s_name)

    print("\n[✓] All 3 Colab training tracks successfully finished and downloaded!", flush=True)

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
    parser = argparse.ArgumentParser(description="Colab A100 Jinja Fleet Orchestrator")
    parser.add_argument("--steps", type=int, default=40, help="GRPO steps per instance (default 40)")
    parser.add_argument("--group_size", type=int, default=12, help="Rollout group size (default 12)")
    parser.add_argument("--skip_provision", action="store_true", help="Skip provisioning if already active")
    parser.add_argument("--monitor_only", action="store_true", help="Skip upload and launch, monitor existing runs")
    parser.add_argument("--teardown", action="store_true", default=True, help="Stop sessions after download")
    args = parser.parse_args()

    if not args.monitor_only and not args.skip_provision:
        provision_fleet(TRACKS)

    if not args.monitor_only:
        upload_payloads(TRACKS)
        launch_training(TRACKS, steps=args.steps, group_size=args.group_size)

    monitor_and_sync(TRACKS)

    if args.teardown:
        teardown_fleet(TRACKS)

    print("\n" + "=" * 80)
    print("  Stage 6: Multi-LoRA Analytical Concatenation (Iteration 7)")
    print("=" * 80)
    subprocess.run([sys.executable, os.path.join(WORKSPACE_DIR, "scripts/colab_training/fuse_iteration7.py")], check=True)

if __name__ == "__main__":
    main()
