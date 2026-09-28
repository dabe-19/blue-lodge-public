#!/usr/bin/env python3
"""
colab_multiturn_orchestrator.py:
Automated Colab A100 Orchestrator for Multi-Turn ReAct, Working Memory & Advisory Alignment.

Lifecycle:
1. Provisions 1x Colab A100 SXM4 High-Mem instance ('multiturn-react').
2. Uploads specialized multi-turn train/val curricula, tools manifest, and worker script.
3. Launches GRPO/contrastive training for 40 steps (Rank 32, Alpha 64.0, lr=1.5e-4).
4. Telemetry polling and progress tracking.
5. Downloads the new GGUF adapter: Blue-Llama-27B-Champion-v5-LoRA-MultiTurn-ReAct.gguf.
6. Cleanly terminates Colab instance to conserve compute units.
7. Executes fuse_iteration9.py to produce the Iteration 9 champion adapters.
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

TRACK = {
    "session": "multiturn-react",
    "name": "Track 4: Multi-Turn ReAct, Working Memory & Advisory Alignment",
    "train_curriculum": os.path.join(WORKSPACE_DIR, "data/training/enhanced_multiturn_train.jsonl"),
    "val_curriculum": os.path.join(WORKSPACE_DIR, "data/training/enhanced_multiturn_val.jsonl"),
    "remote_output": "/content/output/Blue-Llama-27B-Champion-v5-LoRA-MultiTurn-ReAct.gguf",
    "local_output": os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-LoRA-MultiTurn-ReAct.gguf")
}

def run_colab_cmd(args_list, input_text=None, timeout=120):
    cmd = [COLAB_BIN, "--auth=adc"] + args_list
    try:
        res = subprocess.run(cmd, input=input_text, capture_output=True, text=True, timeout=timeout)
        return res.returncode, res.stdout, res.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "TimeoutExpired"
    except Exception as e:
        return -1, "", str(e)

def provision_instance():
    print("=" * 80)
    print(f"  Stage 1: Provisioning Colab A100 High-Mem Instance ('{TRACK['session']}')")
    print("=" * 80)
    code, out, err = run_colab_cmd(["sessions"])
    active_output = (out + " " + err).lower()
    if TRACK["session"] in active_output:
        print(f"  ✓ Session '{TRACK['session']}' is already active. Skipping creation.")
        return

    print(f"[*] Provisioning session '{TRACK['session']}' on A100 High-Mem...")
    code, out, err = run_colab_cmd(["new", "-s", TRACK["session"], "--gpu", "A100", "--high-mem"])
    if code != 0:
        print(f"[!] Warning on '{TRACK['session']}': {err.strip() or out.strip()}")
    else:
        print(f"  ✓ Session '{TRACK['session']}' provisioned successfully.")
    time.sleep(3)

def upload_payloads():
    print("\n" + "=" * 80)
    print("  Stage 2: Uploading Multi-Turn Curricula, Jinja Template & Worker Script")
    print("=" * 80)
    s_name = TRACK["session"]
    worker_script = os.path.join(WORKSPACE_DIR, "scripts/colab_training/train_multiturn_colab.py")
    jinja_template = os.path.join(WORKSPACE_DIR, "configs/blue_lodge_jinja_template.jinja")
    tools_manifest = os.path.join(WORKSPACE_DIR, "data/training/native_core_tools.json")

    print(f"[*] Uploading payloads to session '{s_name}'...", flush=True)
    run_colab_cmd(["upload", "-s", s_name, worker_script, "/content/train_multiturn_colab.py"])
    run_colab_cmd(["upload", "-s", s_name, jinja_template, "/content/blue_lodge_jinja_template.jinja"])
    if os.path.exists(tools_manifest):
        run_colab_cmd(["upload", "-s", s_name, tools_manifest, "/content/native_core_tools.json"])
    run_colab_cmd(["upload", "-s", s_name, TRACK["train_curriculum"], "/content/train.jsonl"])
    code, out, err = run_colab_cmd(["upload", "-s", s_name, TRACK["val_curriculum"], "/content/val.jsonl"])
    if code != 0:
        print(f"[!] Upload warning: {err.strip() or out.strip()}", flush=True)
    else:
        print(f"  ✓ Uploaded train/val datasets, Jinja template, and worker script to {s_name}", flush=True)

def launch_training(steps=40, group_size=12, rank=32, alpha=64.0, lr=1.5e-4):
    print("\n" + "=" * 80)
    print(f"  Stage 3: Launching Multi-Turn GRPO Training (Steps: {steps}, G={group_size}, Rank: {rank}, Alpha: {alpha})")
    print("=" * 80)
    s_name = TRACK["session"]
    remote_out = TRACK["remote_output"]
    launch_code = (
        f"import subprocess\n"
        f"cmd = 'nohup python3 /content/train_multiturn_colab.py "
        f"--train_curriculum /content/train.jsonl --val_curriculum /content/val.jsonl "
        f"--steps {steps} --group_size {group_size} --parallel {group_size} "
        f"--rank {rank} --alpha {alpha} --lr {lr} "
        f"--output {remote_out} > /content/train.log 2>&1 &'\n"
        f"subprocess.Popen(cmd, shell=True)\n"
        f"print('DISPATCHED')\n"
    )
    print(f"[*] Dispatching background training on '{s_name}'...")
    run_colab_cmd(["exec", "-s", s_name], input_text=launch_code)
    print(f"  ✓ Training dispatched on '{s_name}'.")

def monitor_and_sync(poll_interval=20, timeout=2400):
    print("\n" + "=" * 80)
    print("  Stage 4: Telemetry Monitoring & Adapter Synchronization")
    print("=" * 80)
    s_name = TRACK["session"]
    t0 = time.time()
    last_log_snippet = ""

    while time.time() - t0 < timeout:
        time.sleep(poll_interval)
        elapsed = time.time() - t0

        code, out, err = run_colab_cmd(["exec", "-s", s_name], input_text="!tail -n 6 /content/train.log 2>/dev/null")
        log_text = (out + "\n" + err).strip()

        if log_text and log_text != last_log_snippet:
            lines = [l for l in log_text.splitlines() if "Step" in l or "Reward" in l or "Complete" in l or "Downloading" in l or "Instantiating" in l or "Validation" in l]
            if lines:
                print(f"[{time.strftime('%H:%M:%S')}] (+{int(elapsed)}s) {lines[-1]}", flush=True)
            last_log_snippet = log_text

        if "Multi-Turn GRPO Worker Complete!" in log_text or "Written: /content/output" in log_text or "Adapter written to" in log_text:
            print(f"\n[✓] Training Complete for '{s_name}'!", flush=True)
            break

    # Download adapter
    print(f"\n[*] Downloading adapter: {TRACK['remote_output']} -> {TRACK['local_output']}...")
    code, out, err = run_colab_cmd(["download", "-s", s_name, TRACK["remote_output"], TRACK["local_output"]])
    if not (os.path.exists(TRACK["local_output"]) and os.path.getsize(TRACK["local_output"]) > 1000000):
        # Fallback to best_adapter.gguf if final write was interrupted
        print(f"[*] Attempting fallback download from /content/checkpoints/best_adapter.gguf...")
        run_colab_cmd(["download", "-s", s_name, "/content/checkpoints/best_adapter.gguf", TRACK["local_output"]])

    if os.path.exists(TRACK["local_output"]) and os.path.getsize(TRACK["local_output"]) > 1000000:
        sz_mb = os.path.getsize(TRACK["local_output"]) / (1024 * 1024)
        print(f"  ✓ Successfully downloaded: {TRACK['local_output']} ({sz_mb:.2f} MiB)")
    else:
        raise RuntimeError(f"Download failed: {out.strip()} {err.strip()}")

    # Terminate instance to conserve compute units
    print(f"\n[*] Terminating Colab instance '{s_name}' to conserve compute units...")
    run_colab_cmd(["stop", "-s", s_name])
    print(f"  ✓ Session '{s_name}' stopped cleanly.")

def main():
    parser = argparse.ArgumentParser(description="Multi-Turn ReAct Colab Orchestrator")
    parser.add_argument("--steps", type=int, default=40)
    parser.add_argument("--group_size", type=int, default=12)
    parser.add_argument("--rank", type=int, default=32)
    parser.add_argument("--alpha", type=float, default=64.0)
    parser.add_argument("--lr", type=float, default=1.5e-4)
    args = parser.parse_args()

    t_start = time.time()
    provision_instance()
    upload_payloads()
    launch_training(steps=args.steps, group_size=args.group_size, rank=args.rank, alpha=args.alpha, lr=args.lr)
    monitor_and_sync()

    # Automatic Fusion
    print("\n" + "=" * 80)
    print("  Stage 5: Executing Iteration 9 Domain-Weighted Multi-Adapter Fusion")
    print("=" * 80)
    fuse_script = os.path.join(WORKSPACE_DIR, "scripts/colab_training/fuse_iteration9.py")
    subprocess.run([sys.executable, fuse_script], check=True)

    total_time = time.time() - t_start
    print(f"\n[★] Master Workflow Complete in {total_time:.1f}s!")

if __name__ == "__main__":
    main()
