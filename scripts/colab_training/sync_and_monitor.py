#!/usr/bin/env python3
"""
Automated Session Keep-Alive and Checkpoint Sync Daemon for Colab Workers.
Continuously polls active Colab training sessions, displays progress, and immediately
downloads exported GGUF LoRA adapter checkpoints to local disk to prevent data loss.
"""

import os
import sys
import time
import subprocess
import argparse

COLAB_BIN = "/home/wsl-ops/venv_research/bin/colab"

def run_cmd(cmd_list, timeout=30):
    try:
        res = subprocess.run(cmd_list, capture_output=True, text=True, timeout=timeout)
        return res.returncode, res.stdout, res.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "Timeout expired"
    except Exception as e:
        return -1, "", str(e)

def main():
    parser = argparse.ArgumentParser(description="Colab Checkpoint Auto-Sync Daemon")
    parser.add_argument("--session", required=True, help="Colab session name")
    parser.add_argument("--remote-file", required=True, help="Remote .gguf path on Colab")
    parser.add_argument("--local-file", required=True, help="Local destination path")
    parser.add_argument("--poll-interval", type=int, default=25, help="Polling interval in seconds")
    args = parser.parse_args()

    session = args.session
    remote_file = args.remote_file
    local_file = args.local_file
    os.makedirs(os.path.dirname(os.path.abspath(local_file)), exist_ok=True)

    print(f"[*] Starting Auto-Sync Daemon for session '{session}'...")
    print(f"    Remote: {remote_file}")
    print(f"    Local:  {local_file}")
    sys.stdout.flush()

    last_download_time = 0
    consecutive_errors = 0

    while True:
        # 1. Keepalive & Progress Check
        # Send a brief python command or bash tail to the kernel to keep websocket alive
        keepalive_code = (
            "import os\n"
            "exists = os.path.exists('" + remote_file + "')\n"
            "size = os.path.getsize('" + remote_file + "') if exists else 0\n"
            "log_tail = ''\n"
            "if os.path.exists('/content/train.log'):\n"
            "    with open('/content/train.log', 'r') as f:\n"
            "        lines = f.readlines()\n"
            "        log_tail = ''.join(lines[-4:])\n"
            "print(f'STATUS:{exists}:{size}\\n{log_tail}')\n"
        )
        
        proc = subprocess.Popen(
            [COLAB_BIN, "--auth=adc", "exec", "-s", session, "--timeout", "20"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        try:
            stdout, stderr = proc.communicate(input=keepalive_code, timeout=25)
            ret = proc.returncode
        except subprocess.TimeoutExpired:
            proc.kill()
            ret = -1
            stdout, stderr = "", "Keepalive timed out"

        if ret != 0:
            consecutive_errors += 1
            print(f"[!] Warning ({consecutive_errors}/5): Exec on {session} failed: {stderr.strip()}")
            if "Session" in stderr and ("lost" in stderr or "not found" in stderr):
                print(f"[!] Session {session} is no longer available.")
                break
            if consecutive_errors >= 5:
                print(f"[!] Reached 5 consecutive errors for {session}. Exiting.")
                break
        else:
            consecutive_errors = 0
            lines = stdout.strip().split("\n")
            status_line = lines[0] if lines else ""
            tail_lines = "\n".join(lines[1:]) if len(lines) > 1 else ""

            if status_line.startswith("STATUS:"):
                parts = status_line.split(":")
                remote_exists = parts[1] == "True"
                remote_size = int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else 0

                if remote_exists and remote_size > 10 * 1024 * 1024:
                    # Check if local file exists or needs update
                    local_size = os.path.getsize(local_file) if os.path.exists(local_file) else 0
                    # Download every 60s or if new
                    if time.time() - last_download_time > 60 or local_size == 0:
                        tmp_local = local_file + ".tmp"
                        d_ret, d_out, d_err = run_cmd([COLAB_BIN, "--auth=adc", "download", "-s", session, remote_file, tmp_local], timeout=60)
                        if d_ret == 0 and os.path.exists(tmp_local) and os.path.getsize(tmp_local) > 10 * 1024 * 1024:
                            os.replace(tmp_local, local_file)
                            last_download_time = time.time()
                            print(f"[✓] Checkpoint synced: {local_file} ({os.path.getsize(local_file) / (1024*1024):.2f} MiB)")
                        else:
                            if os.path.exists(tmp_local): os.remove(tmp_local)

            if tail_lines:
                print(f"[{session}] {tail_lines.strip()}")
            
            if "Completed!" in tail_lines or "100%" in tail_lines:
                print(f"[✓] Detected training completion for {session}!")
                # Final pull
                time.sleep(2)
                run_cmd([COLAB_BIN, "--auth=adc", "download", "-s", session, remote_file, local_file], timeout=60)
                print(f"[✓] Final adapter synced successfully to {local_file}")
                break

        sys.stdout.flush()
        time.sleep(args.poll_interval)

if __name__ == "__main__":
    main()
