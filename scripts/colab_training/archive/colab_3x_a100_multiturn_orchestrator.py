#!/usr/bin/env python3
"""
colab_3x_a100_multiturn_orchestrator.py:
Automated 3-Instance Colab A100 Fleet Orchestrator for Multi-Turn Golden Path Training.

Orchestrates 3 parallel sessions:
- blue-mt-webresearch: Track 1 (Web Search & Multi-Source Research Synthesis)
- blue-mt-codegitops:  Track 2 (Code Projects, Safe Edits & GitOps Lifecycle)
- blue-mt-toolspackages: Track 3 (Tools, Package Management & File/Image Analysis)

Workflow:
1. Provisions 3 A100 High-Mem Colab sessions via colab --auth=adc.
2. Uploads curriculum, tools manifest, Jinja template, and worker script.
3. Launches GRPO training with G=12 parallel rollouts concurrently across all 3 instances.
4. Monitors live training logs across all sessions.
5. Downloads the 3 exported GGUF adapters into /home/wsl-ops/models/frontier_qwen38/.
6. Cleanly terminates sessions to preserve compute units.
7. Executes fuse_iteration13.py with heavy weight on new multi-turn adapters.
"""

import os
import sys
import time
import subprocess
import argparse
from concurrent.futures import ThreadPoolExecutor

COLAB_BIN = "/home/wsl-ops/venv_research/bin/colab"
WORKSPACE_DIR = "/home/wsl-ops/blue-lodge"
MODELS_DIR = "/home/wsl-ops/models/frontier_qwen38"
os.makedirs(MODELS_DIR, exist_ok=True)

TRACKS = [
    {
        "session": "blue-mt-contextdiscrim",
        "name": "Track 1: Context Discrimination & Anti-Pollution",
        "curriculum": os.path.join(WORKSPACE_DIR, "data/training/curriculum_track1_composite_context_discrimination.jsonl"),
        "remote_output": "/content/output/Blue-Llama-27B-Champion-v5-LoRA-MultiTurn-ContextDiscrimination.gguf",
        "local_output": os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-LoRA-MultiTurn-ContextDiscrimination.gguf")
    },
    {
        "session": "blue-mt-multihop",
        "name": "Track 2: Multi-Hop Follow-ups & Surgical Execution",
        "curriculum": os.path.join(WORKSPACE_DIR, "data/training/curriculum_track2_composite_multihop_followups.jsonl"),
        "remote_output": "/content/output/Blue-Llama-27B-Champion-v5-LoRA-MultiTurn-MultiHopFollowups.gguf",
        "local_output": os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-LoRA-MultiTurn-MultiHopFollowups.gguf")
    },
    {
        "session": "blue-mt-resilience",
        "name": "Track 3: Evaluator Resilience & Tool Error Recovery",
        "curriculum": os.path.join(WORKSPACE_DIR, "data/training/curriculum_track3_composite_evaluator_resilience.jsonl"),
        "remote_output": "/content/output/Blue-Llama-27B-Champion-v5-LoRA-MultiTurn-EvaluatorResilience.gguf",
        "local_output": os.path.join(MODELS_DIR, "Blue-Llama-27B-Champion-v5-LoRA-MultiTurn-EvaluatorResilience.gguf")
    }
]

def run_colab_cmd(args_list, input_text=None, timeout=120):
    cmd = [COLAB_BIN, "--auth=adc"] + args_list
    try:
        res = subprocess.run(cmd, input=input_text, capture_output=True, text=True, timeout=timeout)
        return res.returncode, res.stdout, res.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "TimeoutExpired"
    except Exception as e:
        return -1, "", str(e)

def provision_instance(t, max_retries=4, retry_delay=12):
    s_name = t["session"]
    print(f"[*] Provisioning session '{s_name}' ({t['name']}) on A100 High-Mem...")
    sys.stdout.flush()
    # Check if session is already active
    code, out, err = run_colab_cmd(["sessions"])
    if s_name in (out + " " + err):
        print(f"  ✓ Session '{s_name}' is already active.")
        sys.stdout.flush()
        return True

    tiers = [
        (["new", "-s", s_name, "--gpu", "A100", "--high-mem"], "A100 High-Mem"),
        (["new", "-s", s_name, "--gpu", "A100"], "A100 Standard-Mem"),
        (["new", "-s", s_name, "--gpu", "L4"], "L4 Standard"),
        (["new", "-s", s_name, "--gpu", "T4", "--high-mem"], "T4 High-Mem"),
        (["new", "-s", s_name, "--gpu", "T4"], "T4 Standard-Mem"),
    ]

    for attempt in range(1, max_retries + 1):
        for cmd_args, tier_name in tiers:
            print(f"[*] Trying allocation on {tier_name} (attempt {attempt})...")
            code, out, err = run_colab_cmd(cmd_args)
            if code == 0:
                print(f"  ✓ Session '{s_name}' provisioned successfully on {tier_name}!")
                sys.stdout.flush()
                return True
            msg = err.strip() or out.strip()
            if "Service Unavailable" in msg or "412" in msg or "TooMany" in msg:
                print(f"  [-] {tier_name} unavailable: {msg.splitlines()[-1] if msg else 'Error'}")
                continue
            else:
                print(f"  [!] Attempt failed for '{s_name}' on {tier_name}: {msg}")
        if attempt < max_retries:
            print(f"      Waiting {retry_delay}s before retry cycle...")
            time.sleep(retry_delay)
    return False

def upload_track_payload(t):
    s_name = t["session"]
    print(f"[*] Packaging and uploading payloads to session '{s_name}'...")
    worker_script = os.path.join(WORKSPACE_DIR, "scripts/colab_training/train_multiturn_colab.py")
    jinja_template = os.path.join(WORKSPACE_DIR, "configs/blue_lodge_jinja_template.jinja")
    tools_manifest = os.path.join(WORKSPACE_DIR, "data/training/native_core_tools.json")

    import shutil
    payload_tar = f"/tmp/{s_name}_payload.tar.gz"
    staging_dir = f"/tmp/{s_name}_staging"
    os.makedirs(staging_dir, exist_ok=True)

    shutil.copy2(t["curriculum"], os.path.join(staging_dir, "curriculum.jsonl"))
    shutil.copy2(worker_script, os.path.join(staging_dir, "train.py"))
    shutil.copy2(jinja_template, os.path.join(staging_dir, "blue_lodge_jinja_template.jinja"))
    if os.path.exists(tools_manifest):
        shutil.copy2(tools_manifest, os.path.join(staging_dir, "native_core_tools.json"))

    subprocess.run(["tar", "-czf", payload_tar, "-C", staging_dir, "."], check=True)
    tar_sz = os.path.getsize(payload_tar) / (1024**2)
    print(f"  ✓ Packaged {tar_sz:.1f} MB payload tarball -> {payload_tar}")

    code, out, err = run_colab_cmd(["upload", "-s", s_name, payload_tar, f"/content/{s_name}_payload.tar.gz"], timeout=300)
    if code != 0:
        raise RuntimeError(f"Upload failed for {s_name}: {err or out}")

    # Extract on remote and verify
    extract_code = (
        f"import subprocess, os\n"
        f"subprocess.run(['tar', '-xzf', '/content/{s_name}_payload.tar.gz', '-C', '/content'], check=True)\n"
        f"has_curr = os.path.exists('/content/curriculum.jsonl') and os.path.getsize('/content/curriculum.jsonl') > 1000\n"
        f"has_train = os.path.exists('/content/train.py') and os.path.getsize('/content/train.py') > 1000\n"
        f"print(f'VERIFIED:{{has_curr}}:{{has_train}}')\n"
    )
    code, out, err = run_colab_cmd(["exec", "-s", s_name], input_text=extract_code, timeout=60)
    if "VERIFIED:True:True" not in out:
        raise RuntimeError(f"Extraction verification failed for {s_name}: {out or err}")

    print(f"  ✓ Uploaded, unpacked, and verified curriculum and dependencies on '{s_name}'.")
    shutil.rmtree(staging_dir, ignore_errors=True)
    if os.path.exists(payload_tar):
        os.remove(payload_tar)
    sys.stdout.flush()

def launch_track_training(t, steps=40, group_size=12, rank=32, alpha=64.0, lr=1.5e-4, standalone=False):
    s_name = t["session"]
    remote_out = t["remote_output"]
    mode_str = "standalone simulation" if standalone else "full inference server rollouts"
    standalone_flag = "--standalone " if standalone else ""
    print(f"[*] Launching training on '{s_name}' ({mode_str})...")
    launch_code = (
        f"import subprocess\n"
        f"cmd = 'pip install -q gguf requests numpy > /dev/null 2>&1 && "
        f"nohup python3 /content/train.py "
        f"--train_curriculum /content/curriculum.jsonl "
        f"--steps {steps} --group_size {group_size} --parallel {group_size} "
        f"--rank {rank} --alpha {alpha} --lr {lr} {standalone_flag}"
        f"--output {remote_out} > /content/train.log 2>&1 &'\n"
        f"subprocess.Popen(cmd, shell=True)\n"
        f"print('DISPATCHED')\n"
    )
    code, out, err = run_colab_cmd(["exec", "-s", s_name], input_text=launch_code)
    print(f"  ✓ Dispatched on '{s_name}': {out.strip() or err.strip()}")
    sys.stdout.flush()

def monitor_and_download(t, poll_interval=10):
    s_name = t["session"]
    remote_out = t["remote_output"]
    local_out = t["local_output"]

    check_code = (
        "import os\n"
        f"has_out = os.path.exists('{remote_out}')\n"
        "log_tail = ''\n"
        "if os.path.exists('/content/train.log'):\n"
        "    with open('/content/train.log') as f:\n"
        "        lines = f.readlines()\n"
        "        log_tail = ''.join(lines[-3:]).strip()\n"
        "print(f'{has_out} | {log_tail}')\n"
    )

    t0 = time.time()
    consecutive_not_found = 0
    while True:
        code, out, err = run_colab_cmd(["exec", "-s", s_name], input_text=check_code)
        resp = out.strip()
        elapsed = int(time.time() - t0)

        if "Session not found" in err or "Session not found" in out:
            consecutive_not_found += 1
            if consecutive_not_found > 6:
                print(f"[!] Session '{s_name}' died or was terminated. Stopping monitor.")
                return False
        else:
            consecutive_not_found = 0

        if "True |" in resp or resp.startswith("True"):
            print(f"\n[✓] Session '{s_name}' completed output generation! ({elapsed}s)")
            break

        tail = resp.split("|", 1)[-1].strip() if "|" in resp else resp
        tail_clean = tail.replace("\n", " ").strip()
        print(f"[{elapsed:4d}s] {s_name}: {tail_clean[:80]}")
        sys.stdout.flush()
        time.sleep(poll_interval)

    # Download output
    print(f"[*] Downloading {remote_out} from '{s_name}' -> {local_out}...")
    run_colab_cmd(["download", "-s", s_name, remote_out, local_out])
    if os.path.exists(local_out):
        print(f"  ✓ Successfully downloaded {os.path.basename(local_out)} ({os.path.getsize(local_out)/(1024**2):.1f} MB)")
    else:
        print(f"  [!] Download failed for {local_out}")

def teardown_instance(t):
    s_name = t["session"]
    print(f"[*] Stopping session '{s_name}' to conserve compute units...")
    run_colab_cmd(["stop", "-s", s_name])
    print(f"  ✓ Session '{s_name}' stopped.")

def main():
    parser = argparse.ArgumentParser(description="Colab 3x A100 Multi-Turn Fleet Orchestrator")
    parser.add_argument("--steps", type=int, default=40, help="Training steps per track")
    parser.add_argument("--group_size", type=int, default=12, help="Rollout group size G=12")
    parser.add_argument("--rank", type=int, default=32, help="LoRA rank")
    parser.add_argument("--alpha", type=float, default=64.0, help="LoRA alpha")
    parser.add_argument("--skip_provision", action="store_true", help="Skip session provisioning")
    parser.add_argument("--download_only", action="store_true", help="Only monitor and download")
    parser.add_argument("--standalone", action="store_true", help="Run policy optimization without launching local inference server on Colab")
    args = parser.parse_args()

    print("=" * 80)
    print("  COLAB 3x A100 FLEET ORCHESTRATOR: MULTI-TURN GOLDEN PATH ADAPTERS")
    print(f"  Tracks: {len(TRACKS)} | Steps: {args.steps} | Group Size: {args.group_size} | Mode: {'Standalone' if args.standalone else 'Full Rollouts'}")
    print("=" * 80)

    # Check active sessions
    code, out, err = run_colab_cmd(["sessions"])
    print(f"[*] Active Colab sessions:\n{out.strip() or 'None'}\n")

    if not args.download_only and not args.skip_provision:
        print("\n--- STAGE 1: PROVISIONING 3x A100 HIGH-MEM FLEET (SEQUENTIAL) ---")
        for t in TRACKS:
            provision_instance(t)
            time.sleep(6)

        print("\n--- STAGE 2: UPLOADING PAYLOADS ---")
        for t in TRACKS:
            upload_track_payload(t)
            time.sleep(2)

        print("\n--- STAGE 3: LAUNCHING TRAINING ---")
        for t in TRACKS:
            launch_track_training(t, steps=args.steps, group_size=args.group_size, rank=args.rank, alpha=args.alpha, standalone=args.standalone)

    print("\n--- STAGE 4: MONITORING & SYNCHRONIZING ADAPTERS ---")
    with ThreadPoolExecutor(max_workers=3) as executor:
        list(executor.map(monitor_and_download, TRACKS))

    print("\n--- STAGE 5: TEARDOWN TO CONSERVE COMPUTE UNITS ---")
    with ThreadPoolExecutor(max_workers=3) as executor:
        list(executor.map(teardown_instance, TRACKS))

    print("\n--- STAGE 6: EXECUTING ITERATION 14 FUSION ---")
    fusion_script = os.path.join(WORKSPACE_DIR, "scripts/colab_training/fuse_iteration14.py")
    if os.path.exists(fusion_script):
        subprocess.run([sys.executable, fusion_script], check=True)
    else:
        print(f"[!] Fusion script not found: {fusion_script}")

    print("\n[✓] 3x A100 Fleet Multi-Turn Pipeline Complete!")

if __name__ == "__main__":
    main()
